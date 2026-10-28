// Rune Weaver Tests — Settings save ordering for the live LLM swap.

import Foundation
import RuneWeaverCore
@testable import RuneWeaverServer
import Testing
import Vapor

/// Stub provider pinning one model identity so swap tests prove a switch without the network.
private struct LLMSwapStub: LLMProvider, Sendable {
    /// Fixed model identity served before the swap.
    let modelInfo: ModelInfo

    /// Pins the stub to one model identity.
    init(modelName: String, providerName: String) {
        self.modelInfo = ModelInfo(name: modelName, provider: providerName, contextLength: 8192)
    }

    /// Never runs a turn in these tests.
    func chat(messages _: [Message], tools _: [any Tool]) -> AsyncStream<LLMResponse> {
        AsyncStream { $0.finish() }
    }

    /// Unused embeddings stub.
    func embeddings(text _: [String]) async throws -> [[Float]] {
        []
    }
}

@Suite("Server Settings Live LLM Swap")
struct ServerSettingsTests {
    /// Builds a context whose serving provider is the stubbed "before" model, with engine
    /// databases isolated under the given directory.
    private func makeContext(base: URL) -> ServerContext {
        let conversations = ConversationManager()
        let gate = PermissionGate()
        let approvals = ApprovalQueue(permissionGate: gate)
        let bus = ToolBus(permissionGate: gate)
        let steering = SteeringQueue()
        let initial = LLMSwapStub(modelName: "swap-before", providerName: "before")
        let orchestrator = Orchestrator(
            conversations: conversations,
            toolBus: bus,
            llm: initial,
            steeringQueue: steering
        )
        let memory = MemoryEngine(
            episodesDBPath: base.appendingPathComponent("episodes.db").path,
            vectorDBPath: base.appendingPathComponent("vectors").path,
            profilePath: base.appendingPathComponent("profile.json").path
        )
        return ServerContext(
            conversations: conversations,
            toolBus: bus,
            orchestrator: orchestrator,
            memoryEngine: memory,
            permissionGate: gate,
            approvals: approvals,
            steeringQueue: steering,
            servingLLM: initial
        )
    }

    @Test
    func `PUT disabling every provider returns 400 and GET shows the previous llm section`() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("rw-llm-reject-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let fileURL = base.appendingPathComponent("config.toml")
        let context = makeContext(base: base)

        // Stored generation: one enabled provider serving as the default.
        var stored = RuneWeaverConfig.default
        stored.llm.providers = ["before": ProviderConfig(enabled: true, model: "swap-before")]
        stored.llm.defaultProvider = "before"
        stored.llm.fallbackProvider = nil
        try stored.save(to: fileURL)

        // The PUT body disables every provider, so the merged `[llm]` moves and must be refused
        // at the pre-save swap preparation the route runs beside its other probes.
        let patch = UpdateSettingsRequest(providers: ["before": ProviderConfig(enabled: false, model: "swap-before")])
        var merged = stored
        try patch.apply(to: &merged)
        try merged.validate()
        #expect(merged.llm != stored.llm)

        do {
            _ = try await prepareLiveLLMSwap(config: merged, context: context)
            Issue.record("Expected the all-disabled provider PUT to be rejected with 400")
        } catch let abort as Abort {
            #expect(abort.status == .badRequest)
        }
        // Live state never moved off the stored generation.
        #expect(await context.orchestrator.modelInfo.name == "swap-before")
        #expect(context.servingLLM?.modelInfo.name == "swap-before")

        // The durable file — and the GET it feeds — still carry the previous llm section.
        let reloaded = try RuneWeaverConfig.load(from: fileURL)
        let response = SettingsResponse(config: reloaded, configPath: fileURL.path)
        #expect(response.defaultProvider == "before")
        #expect(response.providers["before"]?.enabled == true)
    }

    @Test
    func `valid provider PUT persists the file and swaps the live engines`() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("rw-llm-swap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let fileURL = base.appendingPathComponent("config.toml")
        let context = makeContext(base: base)

        // Stored generation: the stub's model serves as the default over a second enabled entry.
        var stored = RuneWeaverConfig.default
        stored.llm.providers = [
            "before": ProviderConfig(enabled: true, model: "swap-before"),
            "after": ProviderConfig(enabled: true, model: "swap-after", serverURL: "http://127.0.0.1:9101")
        ]
        stored.llm.defaultProvider = "before"
        stored.llm.fallbackProvider = nil
        try stored.save(to: fileURL)

        // A valid PUT flips the default to the second enabled entry.
        let patch = UpdateSettingsRequest(defaultProvider: "after")
        var merged = stored
        try patch.apply(to: &merged)
        try merged.validate()
        #expect(merged.llm != stored.llm)

        // Route order: prepare before persist, apply only after the save lands.
        let swap = try await prepareLiveLLMSwap(config: merged, context: context)
        try merged.save(to: fileURL)
        await applyLiveLLMSwap(swap, context: context)

        // The accepted configuration persisted through the same save the route uses.
        let reloaded = try RuneWeaverConfig.load(from: fileURL)
        #expect(reloaded.llm.defaultProvider == "after")
        #expect(SettingsResponse(config: reloaded, configPath: fileURL.path).defaultProvider == "after")

        // The prepared swap moved every live consumer to the new provider.
        let live = await context.orchestrator.modelInfo
        #expect(live.name == "swap-after")
        #expect(live.provider == "after")
        #expect(context.servingLLM?.modelInfo.name == "swap-after")
        #expect(context.llmServerURLs == ["http://127.0.0.1:9101"])
    }
}

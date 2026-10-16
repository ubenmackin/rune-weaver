// Rune Weaver App Tests — Menu bar desktop activity refresh regression tests.

import Foundation
@testable import RuneWeaverApp
import RuneWeaverCore
import RuneWeaverServer
import RuneWeaverTools
import Testing

/// Stub LLM finishing every turn with no content so the fixture context
/// never dials a real provider.
private final class DesktopGateStubProvider: LLMProvider, Sendable {
    /// Canned model metadata.
    let modelInfo = ModelInfo(name: "desktop-gate-stub", provider: "stub", contextLength: 2048)

    /// Ends the turn immediately with an empty delta.
    func chat(messages _: [Message], tools _: [any Tool]) -> AsyncStream<LLMResponse> {
        AsyncStream { continuation in
            continuation.yield(LLMResponse(delta: "", isFinished: true))
            continuation.finish()
        }
    }

    /// Unused embeddings stub.
    func embeddings(text _: [String]) async throws -> [[Float]] {
        []
    }
}

/// Builds an in-memory server context on an isolated temp store so `refreshState()` runs against
/// fixture state instead of the user's real `~/.runeweaver` database paths or a live bind.
private func makeFixtureContext() throws -> (ServerContext, URL) {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let episodesPath = base.appendingPathComponent("episodes.db").path
    let engine = MemoryEngine(
        episodesDBPath: episodesPath,
        vectorDBPath: base.appendingPathComponent("vectors").path,
        profilePath: base.appendingPathComponent("profile.json").path
    )
    let conversations = ConversationManager()
    let gate = PermissionGate()
    let bus = ToolBus(permissionGate: gate)
    let orchestrator = Orchestrator(
        conversations: conversations,
        toolBus: bus,
        llm: DesktopGateStubProvider(),
        memoryEngine: engine
    )
    // Durable collaborators stay on the temp store so the fixture never
    // opens the default home-directory database paths.
    let context = ServerContext(
        conversations: conversations,
        toolBus: bus,
        orchestrator: orchestrator,
        memoryEngine: engine,
        permissionGate: gate,
        approvals: ApprovalQueue(permissionGate: gate),
        pluginStore: ToolRegistryStore(dbPath: episodesPath),
        toolStates: ToolStateStore(dbPath: episodesPath),
        desktopConfig: DesktopConfig()
    )
    return (context, base)
}

@Suite("AppModel desktop gate refresh")
@MainActor
struct AppModelDesktopGateRefreshTests {
    @Test
    func `desktop section follows live batch activity within one refresh tick`() async throws {
        let (context, base) = try makeFixtureContext()
        defer { try? FileManager.default.removeItem(at: base) }

        let model = AppModel()
        model.serverContext = context
        // A fresh model starts idle, so the Desktop Control section hides.
        #expect(model.isDesktopActive == false)

        // One poll tick while the shared monitor is idle keeps the section
        // hidden.
        await model.refreshState()
        #expect(model.isDesktopActive == false)

        // Enabling a desktop tool alone must not surface the section;
        // armed-but-idle stays hidden until a batch actually dispatches.
        await context.toolBus.register(tool: DesktopTools.makeTools()[0], isEnabled: true)
        await model.refreshState()
        #expect(model.isDesktopActive == false)

        // A running batch surfaces the section so the active indicator and
        // Emergency Stop are reachable mid-dispatch.
        await DesktopControlMonitor.shared.beginBatch()
        await model.refreshState()
        #expect(model.isDesktopActive == true)

        // Settling the batch hides the section on the next tick, so the menu
        // never advertises Desktop Control while nothing is running.
        await DesktopControlMonitor.shared.endBatch()
        await model.refreshState()
        #expect(model.isDesktopActive == false)
        // Balance any stray batch so the shared monitor stays idle for peers.
        await DesktopControlMonitor.shared.endBatch()
    }
}

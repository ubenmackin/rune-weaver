// Rune Weaver App Tests — Menu bar desktop gate refresh regression tests.
//
// Pins the emergency-stop invariant: the Desktop Control menu section is
// driven by the live `[desktop]` allow gates, not the boot snapshot, so a
// gate opened at runtime must surface within one refresh tick. Otherwise the
// active indicator and Emergency Stop stay hidden while a `desktop.action`
// batch dispatches.

import Foundation
@testable import RuneWeaverApp
import RuneWeaverCore
import RuneWeaverServer
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

/// Builds an in-memory server context on an isolated temp store so
/// `refreshState()` runs against fixture state instead of the user's real
/// `~/.runeweaver` database paths or a live bind.
/// - Returns: Wired context plus its base directory for cleanup.
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
    func `runtime desktop gate flip surfaces within one refresh tick`() async throws {
        let (context, base) = try makeFixtureContext()
        defer { try? FileManager.default.removeItem(at: base) }

        let model = AppModel()
        model.serverContext = context
        // A stock install boots with both allow boundaries closed, so the
        // Desktop Control section starts hidden.
        #expect(model.isDesktopEnabled == false)

        // One poll tick (the refresh loop's body) against closed gates keeps
        // the section hidden.
        await model.refreshState()
        #expect(model.isDesktopEnabled == false)

        // The settings live-reload pushes the fresh policy onto the live
        // context; opening a boundary must surface the menu section so the
        // active indicator and Emergency Stop are reachable mid-dispatch.
        context.desktopConfig.controlEnabled = true
        await model.refreshState()
        #expect(model.isDesktopEnabled == true)

        // Closing the boundary again hides the section on the next tick, so
        // the menu never advertises Desktop Control against a closed gate.
        context.desktopConfig.controlEnabled = false
        await model.refreshState()
        #expect(model.isDesktopEnabled == false)
    }
}

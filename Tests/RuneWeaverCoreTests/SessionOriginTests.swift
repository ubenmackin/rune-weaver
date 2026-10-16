// Rune Weaver Core Tests — Session origin metadata: title, source, parent link.

import Foundation
@testable import RuneWeaverCore
import Testing

/// Immediate provider serving one finished text chunk, mirroring the server
/// lifecycle fixture so a single turn completes without a tool round.
private struct SessionOriginLLM: LLMProvider, Sendable {
    /// Stable test model metadata.
    let modelInfo = ModelInfo(name: "session-origin-fixture", provider: "test", contextLength: 8192)
    /// Canned answer text.
    let answer: String

    /// Serves the canned answer as one finished stream.
    func chat(messages _: [Message], tools _: [any Tool]) -> AsyncStream<LLMResponse> {
        let text = answer
        return AsyncStream { continuation in
            continuation.yield(LLMResponse(delta: text, isFinished: true))
            continuation.finish()
        }
    }

    /// Unused embeddings stub.
    func embeddings(text _: [String]) async throws -> [[Float]] {
        []
    }
}

/// Builds an isolated memory engine on a fresh temporary directory so the
/// orchestrator runs its full recall path without touching engine data.
private func makeSessionOriginEngine() throws -> (MemoryEngine, URL) {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let engine = MemoryEngine(
        episodesDBPath: base.appendingPathComponent("episodes.db").path,
        vectorDBPath: base.appendingPathComponent("vectors").path,
        profilePath: base.appendingPathComponent("profile.json").path
    )
    return (engine, base)
}

@Suite("Session Origin Metadata")
struct SessionOriginTests {
    @Test
    func `ensureSession fills title, source, and parent when absent`() async {
        let manager = ConversationManager()
        let sessionID = UUID()
        let parentID = UUID()

        let created = await manager.ensureSession(
            id: sessionID,
            title: "Research A",
            source: FanOutEngine.workerSource,
            parentSessionID: parentID
        )

        #expect(created.title == "Research A")
        #expect(created.source == FanOutEngine.workerSource)
        #expect(created.parentSessionID == parentID)
    }

    @Test
    func `Fill-if-nil preserves a stored source and parent, and nil arguments change nothing`() async {
        let manager = ConversationManager()
        let sessionID = UUID()
        let parentID = UUID()
        // A background session first: its stored source must survive later
        // turns without a source so scheduler/goal classification never
        // regresses to a generic label.
        _ = await manager.ensureSession(id: sessionID, source: "scheduler")

        let filled = await manager.ensureSession(
            id: sessionID,
            title: "Late title",
            source: FanOutEngine.workerSource,
            parentSessionID: parentID
        )
        // Fill-if-nil adds the missing title and parent without clobbering the
        // stored scheduler source.
        #expect(filled.title == "Late title")
        #expect(filled.source == "scheduler")
        #expect(filled.parentSessionID == parentID)

        // A second call with nil arguments is a no-op: no field is cleared and
        // nothing is rewritten.
        let before = await manager.session(id: sessionID)
        _ = await manager.ensureSession(id: sessionID)
        let after = await manager.session(id: sessionID)
        #expect(after == before)
        #expect(after?.source == "scheduler")
        #expect(after?.parentSessionID == parentID)
    }

    @Test
    func `Overwrite replaces the parent link while a nil parent never clears it`() async {
        let manager = ConversationManager()
        let sessionID = UUID()
        let firstParent = UUID()
        let secondParent = UUID()
        _ = await manager.ensureSession(id: sessionID, parentSessionID: firstParent)

        // A nil incoming parent never clears the stored link, even under
        // overwrite: untagged turns cannot orphan a worker session.
        let nilParent = await manager.ensureSession(id: sessionID, overwrite: true, parentSessionID: nil)
        #expect(nilParent.parentSessionID == firstParent)

        // An explicit replacement parent wins under overwrite, mirroring the
        // source and goal fill semantics.
        let replaced = await manager.ensureSession(id: sessionID, overwrite: true, parentSessionID: secondParent)
        #expect(replaced.parentSessionID == secondParent)
    }

    @Test
    func `listSessions maps the parent link and omits it when nil`() async throws {
        let manager = ConversationManager()
        let parentID = UUID()
        let parent = await manager.ensureSession(id: UUID(), title: "Parent")
        let worker = await manager.ensureSession(
            id: UUID(),
            title: "Worker",
            source: FanOutEngine.workerSource,
            parentSessionID: parentID
        )

        let summaries = await manager.listSessions()
        let workerSummary = try #require(summaries.first { $0.id == worker.id })
        #expect(workerSummary.parentSessionID == parentID)
        #expect(workerSummary.source == FanOutEngine.workerSource)
        let parentSummary = try #require(summaries.first { $0.id == parent.id })
        #expect(parentSummary.parentSessionID == nil)

        // The listing payload carries the parent link on the wire when present...
        let workerWire = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(workerSummary)) as? [String: Any])
        let wireParent = (workerWire["parentSessionID"] as? String).flatMap { UUID(uuidString: $0) }
        #expect(wireParent == parentID)
        // ...and omits the key entirely when the session has no parent.
        let parentWire = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(parentSummary)) as? [String: Any])
        #expect(parentWire["parentSessionID"] == nil)
    }

    @Test
    func `Orchestrator process stamps the worker-shaped input on the session`() async throws {
        let (engine, base) = try makeSessionOriginEngine()
        defer { try? FileManager.default.removeItem(at: base) }
        let conversations = ConversationManager()
        let gate = PermissionGate()
        let bus = ToolBus(permissionGate: gate)
        let orchestrator = Orchestrator(
            conversations: conversations,
            toolBus: bus,
            llm: SessionOriginLLM(answer: "worker done"),
            toolResolver: { _, _ in [] },
            memoryEngine: engine
        )
        let originID = UUID()
        let workerSessionID = UUID()

        let response = try await orchestrator.process(input: UserInput(
            text: "Research the topic",
            sessionID: workerSessionID,
            source: FanOutEngine.workerSource,
            title: "Research A",
            parentSessionID: originID
        ))

        // The turn stamps the honest origin on the freshly created session so
        // history can classify the worker and nest it under its caller.
        #expect(response.text == "worker done")
        let session = try #require(await conversations.session(id: workerSessionID))
        #expect(session.source == FanOutEngine.workerSource)
        #expect(session.title == "Research A")
        #expect(session.parentSessionID == originID)
    }
}

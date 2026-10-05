// Rune Weaver Server Tests — Episodic cleanup REST surface.
//
// Purpose: pins the episodic deletion contract without a live network: bulk
// clear receipts, single-row deletes, session-scoped deletes, UUID validation,
// idempotent missing-row handling, and semantic isolation end to end through
// the registered routes.
// Scope: route status codes, DTO shapes, and episodic-vs-semantic isolation
// only; episodic compaction, vector ranking, and dashboard refetching stay with
// the engine and client suites.
// Architectural role: guards the thin adapter so future route edits cannot
// silently widen validation, touch semantic rows, or reorder the session
// literal behind the identifier parameter.

import Foundation
@testable import RuneWeaverCore
@testable import RuneWeaverServer
import Testing
import Vapor

/// Stub provider replaying one canned answer for turns constructed in the context.
private final class EpisodicStubLLM: LLMProvider, Sendable {
    /// Stable test model metadata.
    let modelInfo = ModelInfo(name: "episodic-route-fixture", provider: "test", contextLength: 8192)

    /// Replays the canned answer as a finished stream.
    func chat(messages _: [Message], tools _: [any Tool]) -> AsyncStream<LLMResponse> {
        AsyncStream { continuation in
            continuation.yield(LLMResponse(delta: "stub answer"))
            continuation.yield(LLMResponse(delta: "", isFinished: true, totalTokens: 5))
            continuation.finish()
        }
    }

    /// Unused embeddings stub.
    func embeddings(text _: [String]) async throws -> [[Float]] {
        []
    }
}

/// Builds a configured application sharing an isolated episodes database.
///
/// The temporary directory keeps episodic rows, vectors, and the profile off
/// the operator's live data directory; every caller-supplied store points at
/// the same `episodes.db` so goals and tool toggles observe the same file the
/// engine does without leaking into sibling tests.
/// - Parameter body: Test body receiving the app plus its context.
/// - Returns: Whatever `body` returns.
private func withEpisodesApp<T>(
    _ body: (Application, ServerContext) async throws -> T
) async throws -> T {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("runeweaver-episodes-routes-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let app = try await Application.make(.testing)
    do {
        let dbPath = base.appendingPathComponent("episodes.db").path
        let conversations = ConversationManager()
        let gate = PermissionGate()
        let approvals = ApprovalQueue(permissionGate: gate)
        let bus = ToolBus(permissionGate: gate)
        let memory = MemoryEngine(
            episodesDBPath: dbPath,
            vectorDBPath: base.appendingPathComponent("vectors").path,
            profilePath: base.appendingPathComponent("profile.json").path
        )
        let stub = EpisodicStubLLM()
        let orchestrator = Orchestrator(
            conversations: conversations,
            toolBus: bus,
            llm: stub,
            memoryEngine: memory
        )
        let store = GoalStore(dbPath: dbPath)
        var goalsConfig = GoalsConfig()
        goalsConfig.enabled = true
        let engine = GoalEngine(store: store, llm: stub, config: goalsConfig)
        let context = ServerContext(
            conversations: conversations,
            toolBus: bus,
            orchestrator: orchestrator,
            memoryEngine: memory,
            permissionGate: gate,
            approvals: approvals,
            scheduler: SchedulerStore(),
            runs: RunLogStore(),
            hub: WSHub(),
            pluginStore: ToolRegistryStore(dbPath: dbPath),
            toolStates: ToolStateStore(dbPath: dbPath),
            goals: store,
            goalEngine: engine,
            goalsConfig: goalsConfig
        )
        try configureRuneWeaver(app, context: context)
        let value = try await body(app, context)
        try await app.asyncShutdown()
        try? FileManager.default.removeItem(at: base)
        return value
    } catch {
        try? await app.asyncShutdown()
        try? FileManager.default.removeItem(at: base)
        throw error
    }
}

/// Sends one request through the full registered surface.
/// - Parameters:
///   - app: Configured application.
///   - method: HTTP method.
///   - path: Path plus optional query string.
/// - Returns: Route response.
private func episodeRequest(app: Application, method: HTTPMethod, path: String) async throws -> Response {
    let request = Request(
        application: app,
        method: method,
        url: URI(string: path),
        on: app.eventLoopGroup.next()
    )
    return try await app.responder.respond(to: request).get()
}

/// Seeds one episodic turn and returns its stored row identifier.
///
/// The engine surfaces the row id through recall metadata rather than the
/// store type, so tests read it the same way a dashboard would after a search.
/// - Parameters:
///   - context: Server context owning the memory engine.
///   - content: Unique turn text.
///   - sessionID: Owning session.
/// - Returns: Stored episode identifier.
private func seedEpisode(
    _ context: ServerContext,
    content: String,
    sessionID: UUID
) async throws -> UUID {
    let stored = try await context.memoryEngine.storeEpisodic(content: content, sessionID: sessionID)
    let raw = try #require(stored.metadata["id"])
    return try #require(UUID(uuidString: raw))
}

@Suite("Memory Episodic Routes")
struct MemoryEpisodesRouteTests {
    @Test
    func `Clear removes every turn and facts reflect zero`() async throws {
        try await withEpisodesApp { app, context in
            // Three turns across two sessions: the receipt must name all three
            // while the follow-up facts read proves no restart was needed.
            let first = UUID()
            let second = UUID()
            try await context.memoryEngine.storeEpisodic(content: "brass compass calibration one", sessionID: first)
            try await context.memoryEngine.storeEpisodic(content: "brass compass calibration two", sessionID: first)
            try await context.memoryEngine.storeEpisodic(content: "harbor lantern maintenance log", sessionID: second)
            #expect(await context.memoryEngine.episodeCount() == 3)

            let cleared = try await episodeRequest(app: app, method: .DELETE, path: "/memory/episodes")
            #expect(cleared.status == .ok)
            let receipt = try cleared.content.decode(EpisodicClearResponse.self)
            #expect(receipt.deletedCount == 3)
            #expect(receipt.episodeCount == 0)

            let facts = try await episodeRequest(app: app, method: .GET, path: "/memory/facts")
            #expect(facts.status == .ok)
            #expect(try facts.content.decode(FactsResponse.self).episodeCount == 0)
        }
    }

    @Test
    func `Single delete removes one turn and search misses it`() async throws {
        try await withEpisodesApp { app, context in
            // A unique token keeps the search assertion scoped to the deleted
            // row instead of matching the surviving turn by accident.
            let session = UUID()
            let target = try await seedEpisode(context, content: "zephyrquill brass compass calibration", sessionID: session)
            try await context.memoryEngine.storeEpisodic(content: "harbor lantern maintenance log", sessionID: session)
            #expect(await context.memoryEngine.episodeCount() == 2)

            let before = try await episodeRequest(app: app, method: .GET, path: "/memory/search?q=zephyrquill")
            #expect(before.status == .ok)
            #expect(try before.content.decode(MemorySearchResponse.self).memories.contains { $0.content.contains("zephyrquill") })

            let deleted = try await episodeRequest(app: app, method: .DELETE, path: "/memory/episodes/\(target.uuidString)")
            #expect(deleted.status == .noContent)
            #expect(await context.memoryEngine.episodeCount() == 1)

            // The surviving turn stays searchable by its own token, while the
            // deleted token no longer surfaces through recall.
            let after = try await episodeRequest(app: app, method: .GET, path: "/memory/search?q=zephyrquill")
            #expect(after.status == .ok)
            #expect(try after.content.decode(MemorySearchResponse.self).memories.contains { $0.content.contains("zephyrquill") } == false)
        }
    }

    @Test
    func `Missing identifier completes as a no-op`() async throws {
        try await withEpisodesApp { app, context in
            // Deletes stay idempotent so retries and stale dashboard rows
            // converge without surfacing a 404 for an already-gone row.
            let session = UUID()
            try await context.memoryEngine.storeEpisodic(content: "brass compass calibration notes", sessionID: session)
            #expect(await context.memoryEngine.episodeCount() == 1)

            let missing = try await episodeRequest(app: app, method: .DELETE, path: "/memory/episodes/\(UUID().uuidString)")
            #expect(missing.status == .noContent)
            #expect(await context.memoryEngine.episodeCount() == 1)
        }
    }

    @Test
    func `Session delete removes only that session`() async throws {
        try await withEpisodesApp { app, context in
            // Two sessions isolate the write: clearing one must leave the
            // other's rows addressable through the engine.
            let first = UUID()
            let second = UUID()
            try await context.memoryEngine.storeEpisodic(content: "alpha session first turn", sessionID: first)
            try await context.memoryEngine.storeEpisodic(content: "alpha session second turn", sessionID: first)
            try await context.memoryEngine.storeEpisodic(content: "beta session only turn", sessionID: second)
            #expect(await context.memoryEngine.episodeCount() == 3)

            let deleted = try await episodeRequest(app: app, method: .DELETE, path: "/memory/episodes/session/\(first.uuidString)")
            #expect(deleted.status == .noContent)
            #expect(await context.memoryEngine.episodeCount() == 1)
            #expect(try await context.memoryEngine.episodes(for: first).isEmpty)
            #expect(try await context.memoryEngine.episodes(for: second).count == 1)
        }
    }

    @Test
    func `Unknown session completes as a no-op`() async throws {
        try await withEpisodesApp { app, context in
            // An unknown session is the session-scoped twin of a missing id:
            // success with the count unchanged rather than a 404.
            let session = UUID()
            try await context.memoryEngine.storeEpisodic(content: "brass compass calibration notes", sessionID: session)
            #expect(await context.memoryEngine.episodeCount() == 1)

            let missing = try await episodeRequest(app: app, method: .DELETE, path: "/memory/episodes/session/\(UUID().uuidString)")
            #expect(missing.status == .noContent)
            #expect(await context.memoryEngine.episodeCount() == 1)
        }
    }

    @Test
    func `Non-UUID identifier is rejected`() async throws {
        try await withEpisodesApp { app, _ in
            // UUID shape is validated at the REST boundary so the engine keeps
            // its typed contract instead of branching on raw strings.
            let response = try await episodeRequest(app: app, method: .DELETE, path: "/memory/episodes/not-a-uuid")
            #expect(response.status == .badRequest)
            #expect((response.body.string ?? "").contains("id must be a UUID"))
        }
    }

    @Test
    func `Non-UUID session is rejected`() async throws {
        try await withEpisodesApp { app, _ in
            // The session literal must win over the identifier parameter here:
            // this path names the session validator, not the episode one.
            let response = try await episodeRequest(app: app, method: .DELETE, path: "/memory/episodes/session/not-a-uuid")
            #expect(response.status == .badRequest)
            #expect((response.body.string ?? "").contains("sessionID must be a UUID"))
        }
    }

    @Test
    func `Semantic facts survive the episodic clear`() async throws {
        try await withEpisodesApp { app, context in
            // The clear owns only the episodic tables: a durable profile fact
            // plus its vector row must still answer through facts afterwards.
            try await context.memoryEngine.storeProfileFact(content: "My lighthouse keeper alias is Zephyr", source: "api")
            let session = UUID()
            try await context.memoryEngine.storeEpisodic(content: "brass compass calibration notes", sessionID: session)
            try await context.memoryEngine.storeEpisodic(content: "harbor lantern maintenance log", sessionID: session)

            let cleared = try await episodeRequest(app: app, method: .DELETE, path: "/memory/episodes")
            #expect(cleared.status == .ok)
            let receipt = try cleared.content.decode(EpisodicClearResponse.self)
            #expect(receipt.deletedCount == 2)
            #expect(receipt.episodeCount == 0)

            let facts = try await episodeRequest(app: app, method: .GET, path: "/memory/facts")
            #expect(facts.status == .ok)
            let decoded = try facts.content.decode(FactsResponse.self)
            #expect(decoded.episodeCount == 0)
            #expect(decoded.semanticCount == 1)
            #expect(decoded.facts.contains { $0.content.contains("lighthouse") })
        }
    }

    @Test
    func `Empty store clears to zero without failure`() async throws {
        try await withEpisodesApp { app, _ in
            // An empty clear is a successful no-op receipt, not an error: the
            // measured count simply starts at zero.
            let cleared = try await episodeRequest(app: app, method: .DELETE, path: "/memory/episodes")
            #expect(cleared.status == .ok)
            let receipt = try cleared.content.decode(EpisodicClearResponse.self)
            #expect(receipt.deletedCount == 0)
            #expect(receipt.episodeCount == 0)
        }
    }
}

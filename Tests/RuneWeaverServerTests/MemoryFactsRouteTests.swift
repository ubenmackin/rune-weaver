// Rune Weaver Server Tests — Paged facts REST surface over the engine owner.
//
// Purpose: pins GET /memory/facts paging without a live network: filtered pages
// carry their total, an empty query reads the recent window, offset paging
// advances, tallies stay accurate, and malformed paging rejects before any
// store read.
// Scope: route status codes, paging DTO shape, and delegation to the engine
// owner only; fact persistence, episodic listing, and dashboard refetching stay
// with their own suites.
// Architectural role: guards the thin adapter so future route edits cannot
// bypass the engine owner, reorder memory routes, or silently clamp invalid
// paging into a valid window.

import Foundation
@testable import RuneWeaverCore
@testable import RuneWeaverServer
import Testing
import Vapor

/// Stub provider replaying one canned answer for turns constructed in the context.
private final class FactsRouteStubLLM: LLMProvider, Sendable {
    /// Stable test model metadata.
    let modelInfo = ModelInfo(name: "facts-route-fixture", provider: "test", contextLength: 8192)

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
/// The temporary directory keeps facts, vectors, and the profile off the
/// operator's live data directory; every caller-supplied store points at the
/// same `episodes.db` so the engine observes one file without leaking into
/// sibling tests.
/// - Parameter body: Test body receiving the app plus its context.
/// - Returns: Whatever `body` returns.
private func withFactsApp<T>(
    _ body: (Application, ServerContext) async throws -> T
) async throws -> T {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("runeweaver-facts-routes-\(UUID().uuidString)")
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
        let stub = FactsRouteStubLLM()
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
private func factsRequest(app: Application, method: HTTPMethod, path: String) async throws -> Response {
    let request = Request(
        application: app,
        method: method,
        url: URI(string: path),
        on: app.eventLoopGroup.next()
    )
    return try await app.responder.respond(to: request).get()
}

@Suite("Memory Facts Routes")
struct MemoryFactsRouteTests {
    @Test
    func `Filtered query returns matching page with total`() async throws {
        try await withFactsApp { app, context in
            // Distinct vocabularies keep the filter scoped to one row while
            // the second row proves the total counts matches, not stored rows.
            _ = try await context.memoryEngine.storeProfileFact(content: "Lighthouse keeper alias is Zephyr", source: "chat")
            _ = try await context.memoryEngine.storeProfileFact(content: "Harbor lantern maintenance log", source: "dashboard")

            let response = try await factsRequest(app: app, method: .GET, path: "/memory/facts?q=lighthouse&limit=20&offset=0")
            #expect(response.status == .ok)
            let page = try response.content.decode(FactsPageResponse.self)
            #expect(page.total == 1)
            #expect(page.facts.count == 1)
            #expect(page.facts.first?.content.contains("Lighthouse") == true)
            #expect(page.semanticCount == 2)
            #expect(page.limit == 20)
            #expect(page.offset == 0)
        }
    }

    @Test
    func `Empty query returns recent window with counts`() async throws {
        try await withFactsApp { app, context in
            // Two facts plus one episodic turn: the window carries facts only
            // while the episode tally still observes the episodic row.
            _ = try await context.memoryEngine.storeProfileFact(content: "Lighthouse keeper alias is Zephyr", source: "chat")
            _ = try await context.memoryEngine.storeProfileFact(content: "Harbor lantern maintenance log", source: "dashboard")
            try await context.memoryEngine.storeEpisodic(content: "harbor episodic turn", sessionID: UUID())

            let response = try await factsRequest(app: app, method: .GET, path: "/memory/facts")
            #expect(response.status == .ok)
            let page = try response.content.decode(FactsPageResponse.self)
            #expect(page.total == 2)
            #expect(page.facts.count == 2)
            #expect(page.semanticCount == 2)
            #expect(page.episodeCount == 1)

            // Older snapshots decoding as the legacy shape still find their
            // keys in the paged payload, so the episodic suite keeps passing
            // without a second transport.
            let legacy = try response.content.decode(FactsResponse.self)
            #expect(legacy.episodeCount == 1)
            #expect(legacy.semanticCount == 2)
        }
    }

    @Test
    func `Offset paging advances through the match set`() async throws {
        try await withFactsApp { app, context in
            // Five rows under one shared token give two full windows plus a
            // tail, so offsets walk without overlap.
            _ = try await context.memoryEngine.storeProfileFact(content: "Harbor alpha first marker", source: "chat")
            _ = try await context.memoryEngine.storeProfileFact(content: "Harbor beta second marker", source: "chat")
            _ = try await context.memoryEngine.storeProfileFact(content: "Harbor gamma third marker", source: "chat")
            _ = try await context.memoryEngine.storeProfileFact(content: "Harbor delta fourth marker", source: "chat")
            _ = try await context.memoryEngine.storeProfileFact(content: "Harbor epsilon fifth marker", source: "chat")

            let first = try await factsRequest(app: app, method: .GET, path: "/memory/facts?q=harbor&limit=2&offset=0")
            #expect(first.status == .ok)
            let firstPage = try first.content.decode(FactsPageResponse.self)
            #expect(firstPage.total == 5)
            #expect(firstPage.facts.count == 2)

            let second = try await factsRequest(app: app, method: .GET, path: "/memory/facts?q=harbor&limit=2&offset=2")
            #expect(second.status == .ok)
            let secondPage = try second.content.decode(FactsPageResponse.self)
            #expect(secondPage.total == 5)
            #expect(secondPage.facts.count == 2)
            #expect(Set(firstPage.facts.map(\.id)).isDisjoint(with: Set(secondPage.facts.map(\.id))))

            let tail = try await factsRequest(app: app, method: .GET, path: "/memory/facts?q=harbor&limit=2&offset=4")
            #expect(tail.status == .ok)
            let tailPage = try tail.content.decode(FactsPageResponse.self)
            #expect(tailPage.total == 5)
            #expect(tailPage.facts.count == 1)
        }
    }

    @Test
    func `Malformed limit rejects before any store read`() async throws {
        try await withFactsApp { app, _ in
            // A non-numeric limit never reaches the engine: the transport edge
            // rejects it so callers fix the query instead of paging blindly.
            let badLimit = try await factsRequest(app: app, method: .GET, path: "/memory/facts?limit=not-a-number")
            #expect(badLimit.status == .badRequest)

            let outOfRange = try await factsRequest(app: app, method: .GET, path: "/memory/facts?limit=101")
            #expect(outOfRange.status == .badRequest)
        }
    }

    @Test
    func `Malformed offset rejects before any store read`() async throws {
        try await withFactsApp { app, _ in
            // A negative cursor is a wire-shape error rather than a clamped
            // window, keeping limit and offset validation symmetric.
            let negative = try await factsRequest(app: app, method: .GET, path: "/memory/facts?offset=-1")
            #expect(negative.status == .badRequest)

            let nonNumeric = try await factsRequest(app: app, method: .GET, path: "/memory/facts?offset=abc")
            #expect(nonNumeric.status == .badRequest)
        }
    }
}

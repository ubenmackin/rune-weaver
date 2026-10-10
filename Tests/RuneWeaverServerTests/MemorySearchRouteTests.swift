// Rune Weaver Server Tests — Memory search route parity with chat auto-recall.
//
// Purpose: pins GET /memory/search without a live network: dated, future, and
// dateless queries each recall through the router window chat turns use, a
// forced live query hides document-index hits, and the response envelope stays
// the documented query/count/memories triple.
// Scope: route status codes, router window wiring, doc-index suppression, and
// response shape only; router inference, recall calibration, and index building
// stay with their own suites.
// Architectural role: guards the thin adapter so future route edits cannot drop
// the router window, resurrect suppressed index hits, or widen the envelope.

import Foundation
@testable import RuneWeaverCore
@testable import RuneWeaverServer
import Testing
import Vapor

/// Stub provider replaying one canned answer for turns constructed in the context.
private final class SearchRouteStubLLM: LLMProvider, Sendable {
    /// Stable test model metadata.
    let modelInfo = ModelInfo(name: "search-route-fixture", provider: "test", contextLength: 8192)

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

/// Isolated harness for one memory-search route test.
///
/// Holds the configured application plus the stores behind it so fixtures can
/// be written at explicit instants exactly the way a live store would hold them,
/// with every run confined to its own temporary directory.
private struct SearchRouteHarness {
    /// Configured application carrying the registered routes.
    let app: Application
    /// Shared engine collaborators behind the routes.
    let context: ServerContext
    /// Episodic store sharing the engine's database, for dated fixtures.
    let episodes: EpisodeStore
    /// Document index store sharing the engine's index database, or nil when unwired.
    let docIndex: DocIndexStore?
}

/// Builds a configured application over an isolated set of stores.
///
/// Bindings mirror the serving surface: loopback with no owner verifier, so
/// requests reach the handlers exactly as they do on a machine with no token
/// configured. When `docIndex` is set the engine opens the document index the
/// way `rune-weaver serve` does with indexing enabled, which is the only state
/// under which doc-index suppression is observable at all.
/// - Parameters:
///   - docIndex: True to wire a document index database for this run.
///   - body: Test body receiving the harness.
/// - Returns: Whatever `body` returns.
private func withSearchApp<T>(
    docIndex: Bool = false,
    _ body: (SearchRouteHarness) async throws -> T
) async throws -> T {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("runeweaver-search-routes-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let app = try await Application.make(.testing)
    do {
        let dbPath = base.appendingPathComponent("episodes.db").path
        let docIndexPath = base.appendingPathComponent("docindex.db").path
        let conversations = ConversationManager()
        let gate = PermissionGate()
        let approvals = ApprovalQueue(permissionGate: gate)
        let bus = ToolBus(permissionGate: gate)
        let memory = MemoryEngine(
            episodesDBPath: dbPath,
            vectorDBPath: base.appendingPathComponent("vectors").path,
            docIndexDBPath: docIndex ? docIndexPath : nil,
            profilePath: base.appendingPathComponent("profile.json").path
        )
        let stub = SearchRouteStubLLM()
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
        let harness = SearchRouteHarness(
            app: app,
            context: context,
            episodes: EpisodeStore(dbPath: dbPath),
            docIndex: docIndex ? DocIndexStore(dbPath: docIndexPath) : nil
        )
        let value = try await body(harness)
        try await app.asyncShutdown()
        try? FileManager.default.removeItem(at: base)
        return value
    } catch {
        try? await app.asyncShutdown()
        try? FileManager.default.removeItem(at: base)
        throw error
    }
}

/// Sends one body-less request through the full registered surface.
/// - Parameters:
///   - app: Configured application.
///   - path: Path plus optional query string.
/// - Returns: Route response.
private func searchRequest(app: Application, path: String) async throws -> Response {
    let request = Request(
        application: app,
        method: .GET,
        url: URI(string: path),
        on: app.eventLoopGroup.next()
    )
    return try await app.responder.respond(to: request).get()
}

/// Stores one episodic turn at an explicit instant.
///
/// The route recalls through the engine's episodic store, so the fixture writes
/// through a store bound to the same database the engine opened; the timestamp
/// rides on the episode so a dated window can be pinned instead of waiting for
/// the clock to move.
/// - Parameters:
///   - store: Episodic store sharing the engine's database.
///   - content: Unique turn text.
///   - timestamp: Instant the turn occurred at.
private func seedEpisode(
    in store: EpisodeStore,
    content: String,
    at timestamp: Date
) async throws {
    try await store.store(
        Episode(sessionID: UUID(), role: .user, content: content, timestamp: timestamp)
    )
}

/// Indexes one document carrying a single chunk at an explicit event time.
///
/// Keyword-only chunks keep the fixture on the FTS leg, which is the path a
/// fresh install without an embeddings backend takes.
/// - Parameters:
///   - store: Document index store sharing the engine's index database.
///   - externalID: Source-scoped identifier.
///   - text: Chunk body.
///   - mtime: Parent event time, or nil for undated.
private func seedIndexedDoc(
    in store: DocIndexStore,
    externalID: String,
    text: String,
    mtime: Date?
) async throws {
    let document = try await store.upsertDocument(IndexedDocument(
        source: .files,
        externalID: externalID,
        displayName: externalID,
        mtime: mtime,
        contentHash: "hash-\(externalID)",
        indexedAt: Date()
    ))
    _ = try await store.upsertChunks(
        documentID: document.id,
        chunks: [IndexedChunk(documentID: document.id, ordinal: 0, text: text)]
    )
}

/// Gregorian calendar pinned to the device zone, matching router day math.
/// - Returns: Calendar resolving days the way `MemoryQueryRouter` does.
private func routerCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    return calendar
}

/// Renders an instant as `YYYY-MM-DD` in the device zone.
/// - Parameters:
///   - date: Instant to render.
///   - calendar: Zone-carrying calendar used to pick the day parts.
/// - Returns: Calendar-day text the router recognizes.
private func dayString(from date: Date, calendar: Calendar) -> String {
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", components.year ?? 2000, components.month ?? 1, components.day ?? 1)
}

/// Percent-encodes one query value for a `q` parameter.
///
/// Query delimiters plus `+` are stripped from the allowed set so a space
/// survives the wire as an encoded byte rather than reaching the parser as a
/// separator or a space spelling.
/// - Parameter query: Raw query text.
/// - Returns: Encoded value for the `q` parameter.
private func encodedQueryValue(_ query: String) -> String {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "&=+?#/%")
    return query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
}

// Serialized because the forced-override test flips process-wide live-search
// state: a sibling test reading the release posture mid-flight would observe
// the flip and answer from the wrong tier set.
@Suite("Memory Search Route", .serialized)
struct MemorySearchRouteTests {
    @Test
    func `Dated query is windowed by the router`() async throws {
        try await withSearchApp { harness in
            // One turn inside the named day and one three days later: only the
            // dated turn is honestly inside the router window, so any leak of
            // the later row proves the route dropped the window.
            let token = "searchroutedated"
            let calendar = routerCalendar()
            let inWindowStart = calendar.startOfDay(for: Date().addingTimeInterval(-6 * 86400))
            let inWindowNoon = try #require(calendar.date(byAdding: .hour, value: 12, to: inWindowStart))
            let outsideWindow = try #require(calendar.date(byAdding: .day, value: 3, to: inWindowNoon))
            try await seedEpisode(in: harness.episodes, content: "\(token) harbor inwindow ledger", at: inWindowNoon)
            try await seedEpisode(in: harness.episodes, content: "\(token) harbor outwindow ledger", at: outsideWindow)

            let query = "\(token) \(dayString(from: inWindowStart, calendar: calendar))"
            // The route plans with the same router chat auto-recall uses, so the
            // dated text has to resolve to a since/until pair the route honors.
            let plan = MemoryQueryRouter.plan(for: query, currentDate: Date())
            #expect(plan.since != nil)
            #expect(plan.until != nil)
            #expect(plan.skipDocIndex == false)

            let response = try await searchRequest(app: harness.app, path: "/memory/search?q=\(encodedQueryValue(query))")
            #expect(response.status == .ok)
            #expect((response.headers.first(name: "Content-Type") ?? "").contains("application/json"))
            let decoded = try response.content.decode(MemorySearchResponse.self)
            #expect(decoded.query == query)
            #expect(decoded.count == decoded.memories.count)
            #expect(decoded.memories.contains { $0.content.contains("inwindow") })
            #expect(decoded.memories.allSatisfy { !$0.content.contains("outwindow") })
        }
    }

    @Test
    func `Future query receives the router future window`() async throws {
        try await withSearchApp { harness in
            // A bare future marker anchors the window at now, so the upcoming
            // turn is reachable while the older row is excluded: the route must
            // not widen into the past the way an unbounded read would.
            let token = "searchroutefuture"
            let now = Date()
            try await seedEpisode(
                in: harness.episodes,
                content: "\(token) upcoming harbor review",
                at: now.addingTimeInterval(3 * 86400)
            )
            try await seedEpisode(
                in: harness.episodes,
                content: "\(token) earlier harbor review",
                at: now.addingTimeInterval(-3 * 86400)
            )

            let query = "next \(token) harbor review"
            let plan = MemoryQueryRouter.plan(for: query, currentDate: now)
            #expect(plan.since != nil)
            #expect(plan.until != nil)
            #expect(try #require(plan.since) >= now)

            let response = try await searchRequest(app: harness.app, path: "/memory/search?q=\(encodedQueryValue(query))")
            #expect(response.status == .ok)
            let decoded = try response.content.decode(MemorySearchResponse.self)
            #expect(decoded.memories.contains { $0.content.contains("upcoming") })
            #expect(decoded.memories.allSatisfy { !$0.content.contains("earlier") })
        }
    }

    @Test
    func `Dateless query stays unbounded`() async throws {
        try await withSearchApp { harness in
            // With no temporal wording the router returns no bounds, so both a
            // future row and a past row must surface: this is the fallback that
            // keeps ordinary keyword search answering across all history.
            let token = "searchrouteunbounded"
            let now = Date()
            try await seedEpisode(
                in: harness.episodes,
                content: "\(token) harbor upcoming ledger",
                at: now.addingTimeInterval(3 * 86400)
            )
            try await seedEpisode(
                in: harness.episodes,
                content: "\(token) harbor earlier ledger",
                at: now.addingTimeInterval(-3 * 86400)
            )

            let query = "\(token) harbor ledger"
            let plan = MemoryQueryRouter.plan(for: query, currentDate: now)
            #expect(plan.since == nil)
            #expect(plan.until == nil)
            #expect(plan.skipDocIndex == false)
            // The route reads the orchestrator's live budgets rather than the
            // struct defaults, so this harness runs the same clamped values
            // chat turns inject with.
            #expect(await harness.context.orchestrator.budgets == RecallBudgets())

            let response = try await searchRequest(app: harness.app, path: "/memory/search?q=\(encodedQueryValue(query))")
            #expect(response.status == .ok)
            let decoded = try response.content.decode(MemorySearchResponse.self)
            #expect(decoded.count == 2)
            #expect(decoded.memories.contains { $0.content.contains("upcoming") })
            #expect(decoded.memories.contains { $0.content.contains("earlier") })
        }
    }

    @Test
    func `Blank query rejects before any store read`() async throws {
        try await withSearchApp { harness in
            // A missing or whitespace-only `q` is a caller mistake, not an
            // unbounded recall: the guard answers 400 with a naming reason so a
            // dashboard retry can fix the request instead of reading everything.
            for path in ["/memory/search", "/memory/search?q=%20%20"] {
                let response = try await searchRequest(app: harness.app, path: path)
                #expect(response.status == .badRequest)
                #expect((response.body.string ?? "").contains("q query parameter is required"))
            }
        }
    }

    @Test
    func `Response shape stays query count memories`() async throws {
        try await withSearchApp { harness in
            // The envelope is a wire contract: exactly the three documented
            // keys with no extras, so an older client never decodes a surprise
            // field and the count still mirrors the hit list.
            let token = "searchrouteshape"
            try await seedEpisode(in: harness.episodes, content: "\(token) harbor ledger", at: Date())

            let query = "\(token) harbor"
            let response = try await searchRequest(app: harness.app, path: "/memory/search?q=\(encodedQueryValue(query))")
            #expect(response.status == .ok)
            #expect((response.headers.first(name: "Content-Type") ?? "").contains("application/json"))
            let raw = try #require(response.body.string)
            let object = try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
            let expectedKeys = Set(["query", "count", "memories"])
            #expect(Set(object.keys) == expectedKeys)
            #expect(object["query"] as? String == query)
            #expect(object["count"] as? Int == 1)

            let decoded = try response.content.decode(MemorySearchResponse.self)
            #expect(decoded.query == query)
            #expect(decoded.count == decoded.memories.count)
            #expect(decoded.count == 1)
            #expect(decoded.memories.first?.content.contains(token) == true)
        }
    }

    @Test
    func `Freshness wording suppresses document index hits`() async throws {
        try await withSearchApp(docIndex: true) { harness in
            // The store carries an indexed chunk plus an episodic turn naming
            // the same token, so the plain read proves the index is reachable
            // before the freshness read is allowed to claim suppression.
            let store = try #require(harness.docIndex)
            let token = "searchroutefresh"
            try await seedIndexedDoc(
                in: store,
                externalID: "\(token)-doc",
                text: "\(token) harbor indexed ledger manifest",
                mtime: Date()
            )
            try await seedEpisode(in: harness.episodes, content: "\(token) harbor episodic turn", at: Date())

            let baseline = try await searchRequest(app: harness.app, path: "/memory/search?q=\(encodedQueryValue(token))")
            let baselineDecoded = try baseline.content.decode(MemorySearchResponse.self)
            #expect(baselineDecoded.memories.contains { $0.source == .docIndex })
            #expect(baselineDecoded.memories.contains { $0.source == .episodic })

            // Freshness wording is the plan-level skip: live tools cover state
            // the nightly index may not hold, so indexed chunks drop while the
            // episodic turn still answers.
            let query = "\(token) latest harbor"
            #expect(MemoryQueryRouter.plan(for: query, currentDate: Date()).skipDocIndex == true)

            let response = try await searchRequest(app: harness.app, path: "/memory/search?q=\(encodedQueryValue(query))")
            #expect(response.status == .ok)
            let decoded = try response.content.decode(MemorySearchResponse.self)
            #expect(decoded.memories.contains { $0.source == .episodic })
            #expect(decoded.memories.allSatisfy { $0.source != .docIndex })
        }
    }

    @Test
    func `Forced live override suppresses document index hits`() async throws {
        try await withSearchApp(docIndex: true) { harness in
            let store = try #require(harness.docIndex)
            let token = "searchrouteforced"
            try await seedIndexedDoc(
                in: store,
                externalID: "\(token)-doc",
                text: "\(token) harbor indexed ledger manifest",
                mtime: Date()
            )
            try await seedEpisode(in: harness.episodes, content: "\(token) harbor episodic turn", at: Date())
            let query = encodedQueryValue(token)

            // Released state keeps the index reachable, so the forced read is a
            // real suppression rather than an empty store.
            await LiveSearchOverride.shared.setForced(false)
            let released = try await searchRequest(app: harness.app, path: "/memory/search?q=\(query)")
            let releasedDecoded = try released.content.decode(MemorySearchResponse.self)
            #expect(releasedDecoded.memories.contains { $0.source == .docIndex })

            // Forcing live hides indexed chunks on both surfaces, so the route
            // post-filters doc-index hits while episodic recall still answers.
            await LiveSearchOverride.shared.setForced(true)
            let forced = try await searchRequest(app: harness.app, path: "/memory/search?q=\(query)")
            #expect(forced.status == .ok)
            let forcedDecoded = try forced.content.decode(MemorySearchResponse.self)
            #expect(forcedDecoded.memories.contains { $0.source == .episodic })
            #expect(forcedDecoded.memories.allSatisfy { $0.source != .docIndex })

            // Releasing restores the index so no later surface inherits the flip.
            await LiveSearchOverride.shared.setForced(false)
            let restored = try await searchRequest(app: harness.app, path: "/memory/search?q=\(query)")
            #expect(try restored.content.decode(MemorySearchResponse.self).memories.contains { $0.source == .docIndex })
        }
    }
}

// Rune Weaver Server Tests — Episodic cleanup REST surface.

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

/// Sends one request through the full registered surface. app: Configured
/// application.
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

    @Test
    func `Seeded store returns newest window with matching count as JSON`() async throws {
        try await withEpisodesApp { app, context in
            // Seven hundred rows prove the listing stays windowed: the default
            // read returns twenty newest first while the stored tally names all.
            let session = UUID()
            for index in 0 ..< 700 {
                try await context.memoryEngine.storeEpisodic(
                    content: "seed-turn-\(String(format: "%04d", index)) harbor lighthouse log",
                    sessionID: session
                )
            }
            #expect(await context.memoryEngine.episodeCount() == 700)

            let response = try await episodeRequest(app: app, method: .GET, path: "/memory/episodes/recent")
            #expect(response.status == .ok)
            let contentType = response.headers.first(name: "Content-Type") ?? ""
            #expect(contentType.contains("application/json"))
            #expect(!contentType.contains("text/html"))
            let decoded = try response.content.decode(EpisodicRecentResponse.self)
            #expect(decoded.episodes.count == 20)
            #expect(decoded.count == 20)
            #expect(decoded.count == decoded.episodes.count)
            // Newest first with no re-sort downstream: each clock reads at or
            // after the next one so the preview audits recency honestly.
            for pair in zip(decoded.episodes, decoded.episodes.dropFirst()) {
                #expect(pair.0.timestamp >= pair.1.timestamp)
            }
        }
    }

    @Test
    func `Unknown session reads as empty list with zero count as JSON`() async throws {
        try await withEpisodesApp { app, context in
            // A stored session proves the empty read is scoped, not a missing
            // store: the unknown identifier simply has no rows to preview.
            try await context.memoryEngine.storeEpisodic(content: "harbor lighthouse keeper log", sessionID: UUID())
            let unknown = UUID()
            let response = try await episodeRequest(
                app: app,
                method: .GET,
                path: "/memory/episodes/recent?sessionID=\(unknown.uuidString)"
            )
            #expect(response.status == .ok)
            #expect((response.headers.first(name: "Content-Type") ?? "").contains("application/json"))
            let decoded = try response.content.decode(EpisodicRecentResponse.self)
            #expect(decoded.episodes.isEmpty)
            #expect(decoded.count == 0)
            #expect(decoded.count == decoded.episodes.count)
        }
    }

    @Test
    func `Malformed sessionID is rejected as JSON bad request`() async throws {
        try await withEpisodesApp { app, _ in
            // UUID shape stays validated at the transport edge so the engine
            // keeps its typed contract instead of branching on raw strings.
            let response = try await episodeRequest(
                app: app,
                method: .GET,
                path: "/memory/episodes/recent?sessionID=not-a-uuid"
            )
            #expect(response.status == .badRequest)
            #expect((response.headers.first(name: "Content-Type") ?? "").contains("application/json"))
            #expect((response.body.string ?? "").contains("sessionID must be a UUID"))
        }
    }

    @Test
    func `Malformed limit is rejected as JSON bad request`() async throws {
        try await withEpisodesApp { app, _ in
            // The closed range stays single-sourced in the query helper: a
            // present value must parse inside 1 through 100 instead of clamping.
            for path in [
                "/memory/episodes/recent?limit=0",
                "/memory/episodes/recent?limit=101",
                "/memory/episodes/recent?limit=not-a-number"
            ] {
                let response = try await episodeRequest(app: app, method: .GET, path: path)
                #expect(response.status == .badRequest)
                #expect((response.headers.first(name: "Content-Type") ?? "").contains("application/json"))
                #expect((response.body.string ?? "").contains("limit must be"))
            }
            // The default window stays twenty when the query omits the limit.
            let fallback = try await episodeRequest(app: app, method: .GET, path: "/memory/episodes/recent")
            #expect(fallback.status == .ok)
            #expect((fallback.headers.first(name: "Content-Type") ?? "").contains("application/json"))
        }
    }

    @Test
    func `Unknown memory path never falls back to HTML`() async throws {
        try await withEpisodesApp { app, _ in
            // API routes register before the dashboard bundle so an unknown
            // memory path answers JSON 404 instead of the client HTML entry.
            let response = try await episodeRequest(app: app, method: .GET, path: "/memory/unknown-path")
            #expect(response.status == .notFound)
            let contentType = response.headers.first(name: "Content-Type") ?? ""
            #expect(contentType.contains("application/json"))
            #expect(!(response.body.string ?? "").lowercased().contains("<html"))
        }
    }

    @Test
    func `Tab counts and listing rows agree after clear`() async throws {
        try await withEpisodesApp { app, context in
            // Counts for tab labels come from facts while rows come from the
            // recent listing; after a clear both settle to zero on the next
            // read with no restart and no watcher.
            let session = UUID()
            try await context.memoryEngine.storeEpisodic(content: "harbor lighthouse alpha", sessionID: session)
            try await context.memoryEngine.storeEpisodic(content: "harbor manifest beta", sessionID: session)
            #expect(await context.memoryEngine.episodeCount() == 2)

            let cleared = try await episodeRequest(app: app, method: .DELETE, path: "/memory/episodes")
            #expect(cleared.status == .ok)

            let facts = try await episodeRequest(app: app, method: .GET, path: "/memory/facts")
            #expect(facts.status == .ok)
            #expect(try facts.content.decode(FactsPageResponse.self).episodeCount == 0)

            let recent = try await episodeRequest(app: app, method: .GET, path: "/memory/episodes/recent")
            #expect(recent.status == .ok)
            let listing = try recent.content.decode(EpisodicRecentResponse.self)
            #expect(listing.episodes.isEmpty)
            #expect(listing.count == 0)
        }
    }
}

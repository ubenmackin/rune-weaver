// Rune Weaver Core Tests — Engine-owned episodic deletion scope.

import Foundation
@testable import RuneWeaverCore
import Testing

/// Builds an isolated engine on a fresh temporary directory.
private func makeEpisodicClearEngine() -> (engine: MemoryEngine, base: URL) {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let engine = MemoryEngine(
        episodesDBPath: base.appendingPathComponent("episodes.db").path,
        vectorDBPath: base.appendingPathComponent("vectors").path,
        profilePath: base.appendingPathComponent("profile.json").path
    )
    return (engine, base)
}

@Suite("Memory Episodic Clear")
struct MemoryEpisodicClearTests {
    @Test
    func `Store three turns then clear returns measured count and empties store`() async throws {
        let (engine, base) = makeEpisodicClearEngine()
        defer { try? FileManager.default.removeItem(at: base) }
        let sessionID = UUID()

        // All three rows share one rare token so a single search proves the
        // whole set was present before the clear and absent after it.
        try await engine.storeEpisodic(content: "harbor lighthouse alpha first turn", sessionID: sessionID)
        try await engine.storeEpisodic(content: "harbor manifest beta second turn", sessionID: sessionID)
        try await engine.storeEpisodic(content: "harbor garden gamma third turn", sessionID: sessionID)
        #expect(await engine.episodeCount() == 3)
        let before = try await engine.searchEpisodes(query: "harbor", limit: 10)
        #expect(before.count == 3)

        // The returned count is measured before the delete, so callers can
        // report what was removed without a second read.
        let deleted = try await engine.clearEpisodic()
        #expect(deleted == 3)
        #expect(await engine.episodeCount() == 0)

        // Reads open SQLite on demand with no cached snapshot, so recall
        // observes the clear on the next read with no invalidation step.
        let after = try await engine.searchEpisodes(query: "harbor", limit: 10)
        #expect(after.isEmpty)
        let remaining = try await engine.episodes(for: sessionID)
        #expect(remaining.isEmpty)
    }

    @Test
    func `Clear on empty store returns zero`() async throws {
        let (engine, base) = makeEpisodicClearEngine()
        defer { try? FileManager.default.removeItem(at: base) }

        // An empty episodes table is a valid clear target, not an error:
        // the measured count is zero and the store stays empty.
        let deleted = try await engine.clearEpisodic()
        #expect(deleted == 0)
        #expect(await engine.episodeCount() == 0)
    }

    @Test
    func `Delete episode removes one row and keeps remaining searchable`() async throws {
        let (engine, base) = makeEpisodicClearEngine()
        defer { try? FileManager.default.removeItem(at: base) }
        let sessionID = UUID()

        // Distinct vocabularies per row keep FTS assertions isolated: no token
        // overlaps, so each query can only match its own row.
        try await engine.storeEpisodic(content: "lighthouse keeper northern beacon alpha", sessionID: sessionID)
        try await engine.storeEpisodic(content: "harbor manifest cargo crates beta", sessionID: sessionID)
        try await engine.storeEpisodic(content: "garden roses stone wall gamma", sessionID: sessionID)
        let stored = try await engine.episodes(for: sessionID)
        try #require(stored.count == 3)
        guard let target = stored.first(where: { $0.content.contains("lighthouse") }) else {
            Issue.record("Expected a lighthouse episode before delete")
            return
        }

        try await engine.deleteEpisode(id: target.id)
        #expect(await engine.episodeCount() == 2)

        // The deleted row no longer matches while both survivors stay
        // searchable through the same FTS path recall uses.
        let gone = try await engine.searchEpisodes(query: "lighthouse", limit: 10)
        #expect(gone.isEmpty)
        let keptHarbor = try await engine.searchEpisodes(query: "harbor manifest cargo", limit: 10)
        #expect(keptHarbor.count == 1)
        #expect(keptHarbor.first?.content.contains("harbor") == true)
        let keptGarden = try await engine.searchEpisodes(query: "garden roses stone", limit: 10)
        #expect(keptGarden.count == 1)
        let remaining = try await engine.episodes(for: sessionID)
        #expect(remaining.count == 2)
        #expect(!remaining.contains { $0.id == target.id })
    }

    @Test
    func `Delete missing id is a no-op`() async throws {
        let (engine, base) = makeEpisodicClearEngine()
        defer { try? FileManager.default.removeItem(at: base) }
        let sessionID = UUID()

        try await engine.storeEpisodic(content: "harbor lighthouse alpha first", sessionID: sessionID)
        try await engine.storeEpisodic(content: "harbor manifest beta second", sessionID: sessionID)
        #expect(await engine.episodeCount() == 2)

        // Unknown identifiers complete silently so retries and double-deletes
        // never surface as failures.
        try await engine.deleteEpisode(id: UUID())
        #expect(await engine.episodeCount() == 2)
        let hits = try await engine.searchEpisodes(query: "harbor", limit: 10)
        #expect(hits.count == 2)
    }

    @Test
    func `Delete session removes only that session`() async throws {
        let (engine, base) = makeEpisodicClearEngine()
        defer { try? FileManager.default.removeItem(at: base) }
        let firstSession = UUID()
        let secondSession = UUID()

        try await engine.storeEpisodic(content: "harbor lighthouse alpha first", sessionID: firstSession)
        try await engine.storeEpisodic(content: "harbor manifest beta second", sessionID: firstSession)
        try await engine.storeEpisodic(content: "garden roses stone wall gamma", sessionID: secondSession)
        #expect(await engine.episodeCount() == 3)

        // Session scope deletes one conversation without touching siblings.
        try await engine.deleteSession(firstSession)
        let firstRemaining = try await engine.episodes(for: firstSession)
        #expect(firstRemaining.isEmpty)
        let secondRemaining = try await engine.episodes(for: secondSession)
        #expect(secondRemaining.count == 1)
        #expect(secondRemaining.first?.content.contains("garden") == true)
        #expect(await engine.episodeCount() == 1)
    }

    @Test
    func `Semantic facts and profile survive episodic clear`() async throws {
        let (engine, base) = makeEpisodicClearEngine()
        defer { try? FileManager.default.removeItem(at: base) }
        let sessionID = UUID()

        // Seed one durable fact plus one preference before any episodic rows so
        // the clear has both a vector row and profile state to preserve.
        let fact = try await engine.storeProfileFact(content: "My dog is named Biscuit", source: "chat")
        await engine.setPreference(Preference(key: "name", value: "Ada"))
        try await engine.storeEpisodic(content: "harbor lighthouse alpha first", sessionID: sessionID)
        try await engine.storeEpisodic(content: "harbor manifest beta second", sessionID: sessionID)
        #expect(await engine.episodeCount() == 2)

        let deleted = try await engine.clearEpisodic()
        #expect(deleted == 2)
        #expect(await engine.episodeCount() == 0)

        // Episodic scope never reaches the semantic store or the profile file:
        // the fact row, its keyword recall, and the preference all survive.
        let stored = await engine.allSemanticFacts()
        #expect(stored.contains { $0.id == fact.id })
        let profile = await engine.getUserProfile()
        #expect(profile.facts.contains { $0.id == fact.id })
        #expect(profile.preferences.contains { $0.key == "name" && $0.value == "Ada" })
        let semanticHits = await engine.querySemantic(query: "Biscuit", embedding: [], limit: 5)
        #expect(semanticHits.contains { $0.content.contains("Biscuit") })
        let episodicHits = try await engine.searchEpisodes(query: "harbor", limit: 10)
        #expect(episodicHits.isEmpty)
    }

    @Test
    func `List recent returns newest first`() async throws {
        let (engine, base) = makeEpisodicClearEngine()
        defer { try? FileManager.default.removeItem(at: base) }
        let dbPath = base.appendingPathComponent("episodes.db").path
        let direct = EpisodeStore(dbPath: dbPath)
        let session = UUID()
        let clock = Date(timeIntervalSince1970: 1_700_000_000)

        // Distinct clocks keep the window deterministic without sleeping: each
        // later row names a later second so newest first is unambiguous.
        for offset in 0 ..< 5 {
            let episode = Episode(
                sessionID: session,
                role: .user,
                content: "ordered-turn-\(offset)",
                timestamp: clock.addingTimeInterval(Double(offset * 10)),
                metadata: [:]
            )
            try await direct.store(episode)
        }
        #expect(await engine.episodeCount() == 5)

        // The listing owns newest-first ordering so callers never re-sort.
        let listed = try await engine.listRecentEpisodes(limit: 5)
        #expect(listed.count == 5)
        #expect(listed.map(\.content) == [
            "ordered-turn-4",
            "ordered-turn-3",
            "ordered-turn-2",
            "ordered-turn-1",
            "ordered-turn-0"
        ])
        for pair in zip(listed, listed.dropFirst()) {
            #expect(pair.0.timestamp >= pair.1.timestamp)
        }
    }

    @Test
    func `List recent tie-break on identifier is stable`() async throws {
        let (engine, base) = makeEpisodicClearEngine()
        defer { try? FileManager.default.removeItem(at: base) }
        let dbPath = base.appendingPathComponent("episodes.db").path
        let direct = EpisodeStore(dbPath: dbPath)
        let session = UUID()
        let fixed = Date(timeIntervalSince1970: 1_700_000_100)

        // Equal clocks force the stable tie-break: the smaller identifier
        // sorts first so repeated reads order identically instead of leaving
        // the pair to sort chance.
        let smaller = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let larger = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        try await direct.store(Episode(
            id: larger,
            sessionID: session,
            role: .user,
            content: "tie larger",
            timestamp: fixed,
            metadata: [:]
        ))
        try await direct.store(Episode(
            id: smaller,
            sessionID: session,
            role: .user,
            content: "tie smaller",
            timestamp: fixed,
            metadata: [:]
        ))

        let listed = try await engine.listRecentEpisodes(limit: 10)
        #expect(listed.count == 2)
        #expect(listed.map(\.id) == [smaller, larger])
        #expect(listed.first?.content == "tie smaller")
    }

    @Test
    func `List recent respects limit window`() async throws {
        let (engine, base) = makeEpisodicClearEngine()
        defer { try? FileManager.default.removeItem(at: base) }
        let session = UUID()

        for index in 0 ..< 5 {
            try await engine.storeEpisodic(content: "window-turn-\(index)", sessionID: session)
        }
        #expect(await engine.episodeCount() == 5)

        // A non-positive window reads as empty rather than an error so stale
        // cursors degrade to no rows.
        #expect(try await engine.listRecentEpisodes(limit: 0).isEmpty)

        // A bounded window returns exactly the newest rows, newest first.
        let window = try await engine.listRecentEpisodes(limit: 2)
        #expect(window.count == 2)
        for pair in zip(window, window.dropFirst()) {
            #expect(pair.0.timestamp >= pair.1.timestamp)
        }

        // A window wider than the store returns every row, newest first.
        let wide = try await engine.listRecentEpisodes(limit: 100)
        #expect(wide.count == 5)
        for pair in zip(wide, wide.dropFirst()) {
            #expect(pair.0.timestamp >= pair.1.timestamp)
        }

        // A session preview stays scoped to its owner while sharing the same
        // newest-first contract.
        let scoped = try await engine.listRecentEpisodes(limit: 2, sessionID: session)
        #expect(scoped.count == 2)
        #expect(try await engine.listRecentEpisodes(limit: 10, sessionID: UUID()).isEmpty)
    }
}

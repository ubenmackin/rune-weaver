// Rune Weaver Core Tests — Engine-owned episodic deletion scope.
// Verifies the episodic clear and single-row delete owner: clearing or deleting
// episodes touches only the episodes tables while semantic facts, the profile
// snapshot, and other ledgers stay intact. Empty clears report zero and missing
// targets complete as no-ops, with reads observing the result immediately.

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
}

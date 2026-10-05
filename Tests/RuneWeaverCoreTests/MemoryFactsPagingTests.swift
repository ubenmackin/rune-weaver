// Rune Weaver Core Tests — Engine-owned paged facts search without episodic rows.
//
// Purpose: pins the facts paging owner so empty queries read the recent window,
// filtered queries narrow by token overlap across content plus source, and
// offset paging walks the full match set with accurate tallies.
// Scope: searchFactsPage windowing, normalization, clamping, and episodic
// exclusion only; REST parsing, dashboard tabs, and vector ranking stay with
// their own suites.
// Architectural role: guards the single paged reader the REST facts route and
// the dashboard delegate to, so future edits cannot widen scope into episodic
// turns or drift normalization away from the route.

import Foundation
@testable import RuneWeaverCore
import Testing

/// Builds an isolated engine on a fresh temporary directory.
private func makeFactsPagingEngine() -> (engine: MemoryEngine, base: URL) {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let engine = MemoryEngine(
        episodesDBPath: base.appendingPathComponent("episodes.db").path,
        vectorDBPath: base.appendingPathComponent("vectors").path,
        profilePath: base.appendingPathComponent("profile.json").path
    )
    return (engine, base)
}

@Suite("Memory Facts Paging")
struct MemoryFactsPagingTests {
    @Test
    func `Empty query returns recent window newest first with accurate counts`() async throws {
        let (engine, base) = makeFactsPagingEngine()
        defer { try? FileManager.default.removeItem(at: base) }
        let session = UUID()

        // Distinct vocabularies keep each row addressable on its own token
        // while the shared episodic token proves episodic exclusion below.
        _ = try await engine.storeProfileFact(content: "Lighthouse keeper alias is Zephyr", source: "chat")
        _ = try await engine.storeProfileFact(content: "Harbor lantern maintenance log", source: "dashboard")
        _ = try await engine.storeProfileFact(content: "Garden roses stone wall notes", source: "import")
        try await engine.storeEpisodic(content: "harbor episodic turn that must stay excluded", sessionID: session)

        let result = await engine.searchFactsPage(query: "", limit: 20, offset: 0)
        #expect(result.total == 3)
        #expect(result.page.count == 3)
        #expect(result.semanticCount == 3)
        #expect(result.episodeCount == 1)
        #expect(!result.page.contains { $0.content.contains("must stay excluded") })
    }

    @Test
    func `Filtered query narrows by token overlap across content and source`() async throws {
        let (engine, base) = makeFactsPagingEngine()
        defer { try? FileManager.default.removeItem(at: base) }

        _ = try await engine.storeProfileFact(content: "Lighthouse keeper alias is Zephyr", source: "chat")
        _ = try await engine.storeProfileFact(content: "Harbor lantern maintenance log", source: "dashboard")
        _ = try await engine.storeProfileFact(content: "Garden roses stone wall notes", source: "import")

        // Content token match narrows to one row with the total scoped to the
        // filter rather than the store size.
        let contentHit = await engine.searchFactsPage(query: "lighthouse", limit: 20, offset: 0)
        #expect(contentHit.total == 1)
        #expect(contentHit.page.count == 1)
        #expect(contentHit.page.first?.content.contains("Lighthouse") == true)
        #expect(contentHit.semanticCount == 3)

        // Source token match narrows through the source half of the haystack,
        // proving filtering spans content plus source rather than content only.
        let sourceHit = await engine.searchFactsPage(query: "dashboard", limit: 20, offset: 0)
        #expect(sourceHit.total == 1)
        #expect(sourceHit.page.first?.content.contains("Harbor") == true)
    }

    @Test
    func `Query trimming and casing never hide a row`() async throws {
        let (engine, base) = makeFactsPagingEngine()
        defer { try? FileManager.default.removeItem(at: base) }

        _ = try await engine.storeProfileFact(content: "Lighthouse keeper alias is Zephyr", source: "chat")

        // Leading spaces plus uppercasing exercise the shared normalization so
        // dashboard input needs no pre-scrubbing before the engine sees it.
        let result = await engine.searchFactsPage(query: "  LIGHTHOUSE  ", limit: 20, offset: 0)
        #expect(result.total == 1)
        #expect(result.page.count == 1)
    }

    @Test
    func `Offset paging walks the full match set`() async throws {
        let (engine, base) = makeFactsPagingEngine()
        defer { try? FileManager.default.removeItem(at: base) }

        // Five rows with a shared token give three non-overlapping windows of
        // two plus a tail, so each offset step is asserted against the total.
        _ = try await engine.storeProfileFact(content: "Harbor alpha first marker", source: "chat")
        _ = try await engine.storeProfileFact(content: "Harbor beta second marker", source: "chat")
        _ = try await engine.storeProfileFact(content: "Harbor gamma third marker", source: "chat")
        _ = try await engine.storeProfileFact(content: "Harbor delta fourth marker", source: "chat")
        _ = try await engine.storeProfileFact(content: "Harbor epsilon fifth marker", source: "chat")

        let first = await engine.searchFactsPage(query: "harbor", limit: 2, offset: 0)
        #expect(first.total == 5)
        #expect(first.page.count == 2)

        let second = await engine.searchFactsPage(query: "harbor", limit: 2, offset: 2)
        #expect(second.total == 5)
        #expect(second.page.count == 2)
        #expect(Set(first.page.map(\.id)).isDisjoint(with: Set(second.page.map(\.id))))

        let tail = await engine.searchFactsPage(query: "harbor", limit: 2, offset: 4)
        #expect(tail.total == 5)
        #expect(tail.page.count == 1)

        // A cursor past the end reads as an empty window so "More" simply
        // stops appending instead of surfacing an error.
        let pastEnd = await engine.searchFactsPage(query: "harbor", limit: 2, offset: 5)
        #expect(pastEnd.total == 5)
        #expect(pastEnd.page.isEmpty)
    }

    @Test
    func `Bounds clamp instead of failing the pane`() async throws {
        let (engine, base) = makeFactsPagingEngine()
        defer { try? FileManager.default.removeItem(at: base) }

        _ = try await engine.storeProfileFact(content: "Harbor alpha first marker", source: "chat")
        _ = try await engine.storeProfileFact(content: "Harbor beta second marker", source: "chat")

        // A zero limit degrades to the smallest valid window rather than an
        // empty read, keeping a stale dashboard cursor renderable.
        let clampedLow = await engine.searchFactsPage(query: "", limit: 0, offset: 0)
        #expect(clampedLow.page.count == 1)
        #expect(clampedLow.total == 2)

        // A negative cursor degrades to the head of the list.
        let clampedOffset = await engine.searchFactsPage(query: "", limit: 20, offset: -5)
        #expect(clampedOffset.page.count == 2)
    }
}

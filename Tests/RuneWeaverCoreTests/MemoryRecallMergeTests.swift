// Rune Weaver Core Tests — Merge-rank regression coverage for recall tiers.
import Foundation
@testable import RuneWeaverCore
import Testing

/// Builds an isolated engine on a fresh temporary directory.
private func makeRecallMergeEngine() -> (engine: MemoryEngine, base: URL) {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let engine = MemoryEngine(
        episodesDBPath: base.appendingPathComponent("episodes.db").path,
        vectorDBPath: base.appendingPathComponent("vectors").path,
        profilePath: base.appendingPathComponent("profile.json").path
    )
    return (engine, base)
}

/// Builds an isolated engine sharing one document index with the test.
private func makeKeywordCurveEngine() -> (engine: MemoryEngine, store: DocIndexStore, base: URL) {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let docIndexPath = base.appendingPathComponent("docindex.db").path
    let engine = MemoryEngine(
        episodesDBPath: base.appendingPathComponent("episodes.db").path,
        vectorDBPath: base.appendingPathComponent("vectors").path,
        docIndexDBPath: docIndexPath,
        profilePath: base.appendingPathComponent("profile.json").path
    )
    return (engine, DocIndexStore(dbPath: docIndexPath), base)
}

/// Stores one keyword-only document with a single chunk.
@discardableResult
private func storeKeywordCurveDoc(
    in store: DocIndexStore,
    externalID: String,
    text: String
) async throws -> IndexedDocument {
    let document = try await store.upsertDocument(IndexedDocument(
        source: .files,
        externalID: externalID,
        displayName: externalID,
        contentHash: "hash-\(externalID)",
        indexedAt: Date()
    ))
    _ = try await store.upsertChunks(
        documentID: document.id,
        chunks: [IndexedChunk(documentID: document.id, ordinal: 0, text: text)]
    )
    return document
}

/// Deterministic paraphrase stand-in for vector recall.
private struct MergeParaphraseStubBackend: EmbeddingsBackend, Sendable {
    /// Stable identifier marking vectors as test fixtures.
    let modelID = "merge-paraphrase-stub"
    /// Fixed width matching the two-element fixture vectors below.
    let dimension: Int? = 2

    /// Returns one vector per input, preserving order.
    /// - Parameter texts: Input texts, in order.
    /// - Returns: Near-identical vector for the paraphrase, orthogonal otherwise.
    func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        return texts.map { text in
            if text.lowercased().contains("animal companion") {
                return [1.0, 0.01]
            }
            return [0.0, 1.0]
        }
    }
}

@Suite("Memory Recall Merge")
struct MemoryRecallMergeTests {
    @Test
    func `Paraphrase semantic outranks episodic keyword matches`() async throws {
        let (engine, base) = makeRecallMergeEngine()
        defer { try? FileManager.default.removeItem(at: base) }

        // The stored fact shares no tokens with the paraphrase query, so the keyword fallback
        // cannot recall it: only vector similarity can. The episodic rows each carry one query
        // token, so FTS returns them and the merge must prefer meaning over literal overlap.
        _ = try await engine.storeSemantic(
            fact: "My cats are Miso and Soba",
            embedding: [1.0, 0.0],
            source: "user"
        )
        try await engine.storeEpisodic(content: "Saw an animal at the zoo yesterday")
        try await engine.storeEpisodic(content: "Companion planted roses in the garden")

        // Near-identical vectors model a confident paraphrase without hitting
        // exactly 1.0, so the assertion is sensitive to tier scaling rather
        // than passing on a tie-break alone.
        let results = try await engine.recall(
            query: "animal companion",
            embedding: [1.0, 0.01],
            limit: 10
        )
        guard let catsIndex = results.firstIndex(where: { $0.content.contains("Miso") }) else {
            Issue.record("Expected the cats fact in recall results")
            return
        }
        #expect(results[catsIndex].source == .semantic)
        #expect(results[catsIndex].score >= MemoryEngine.automaticRecallThreshold)
        let episodicIndices = results.indices.filter { results[$0].source == .episodic }
        #expect(!episodicIndices.isEmpty)
        for index in episodicIndices {
            #expect(catsIndex < index)
        }
    }

    @Test
    func `Keyword query keeps episodic first`() async throws {
        let (engine, base) = makeRecallMergeEngine()
        defer { try? FileManager.default.removeItem(at: base) }

        // Exact keyword queries must not flip when semantic scaling changes: the episodic turn
        // holds the literal address while the semantic row only shares common words like "my", so
        // episodic stays first even though both tiers match.
        try await engine.storeEpisodic(content: "My email address is ada@example.com")
        _ = try await engine.storeSemantic(
            fact: "My cats are Miso and Soba",
            embedding: [1.0, 0.0],
            source: "user"
        )

        let results = try await engine.recall(
            query: "what is my email address",
            embedding: nil,
            limit: 5
        )
        #expect(!results.isEmpty)
        #expect(results.first?.source == .episodic)
        #expect(results.first?.content.contains("ada@example.com") == true)
        // The distractor shares "my" so it does recall via the
        // keyword path; pin that it still ranks below the exact episodic hit.
        if let catsIndex = results.firstIndex(where: { $0.content.contains("Miso") }),
           let emailIndex = results.firstIndex(where: { $0.content.contains("ada@example.com") })
        {
            #expect(emailIndex < catsIndex)
        }
    }

    @Test
    func `Episodic volume does not evict relevant semantic`() async throws {
        let (engine, base) = makeRecallMergeEngine()
        defer { try? FileManager.default.removeItem(at: base) }

        // Five episodic rows all match the query through FTS, which is the volume that previously
        // buried the semantic tier. The semantic hit stays recallable through vectors despite zero
        // token overlap, so the merge must keep it inside the bounded top results.
        _ = try await engine.storeSemantic(
            fact: "My cats are Miso and Soba",
            embedding: [1.0, 0.0],
            source: "user"
        )
        try await engine.storeEpisodic(content: "Saw an animal at the zoo yesterday")
        try await engine.storeEpisodic(content: "Companion planted roses in the garden")
        try await engine.storeEpisodic(content: "The animal shelter needs volunteers")
        try await engine.storeEpisodic(content: "Hiking companion packed extra water")
        try await engine.storeEpisodic(content: "Animal tracks near the harbor trail")

        // A tight per-tier budget models the automatic-recall fan-out: even
        // when episodic fills its quota, the semantic hit must survive.
        let results = try await engine.recall(
            query: "animal companion",
            embedding: [1.0, 0.01],
            limit: 5
        )
        #expect(results.contains { $0.content.contains("Miso") })
        #expect(results.prefix(6).contains { $0.content.contains("Miso") })
    }

    @Test
    func `Automatic recall injects for semantic-only paraphrase`() async throws {
        let (engine, base) = makeRecallMergeEngine()
        defer { try? FileManager.default.removeItem(at: base) }

        // No episodic rows exist, so injection depends entirely on the vector
        // paraphrase clearing the shared threshold. This guards the
        // calibration against pushing true paraphrases below the cutoff.
        _ = try await engine.storeSemantic(
            fact: "My cats are Miso and Soba",
            embedding: [1.0, 0.0],
            source: "user"
        )
        let sessionID = UUID()
        let stub = MergeParaphraseStubBackend()
        let message = try await engine.recallMessage(
            for: "animal companion",
            sessionID: sessionID,
            embedder: stub
        )
        #expect(message != nil)
        #expect(message?.content.contains("Miso") == true)
        #expect(message?.content.contains(MemoryEngine.automaticRecallHeader) == true)

        // The static context helper must agree with the turn helper so both
        // entry points inject the same paraphrase hit.
        let results = try await engine.recall(
            query: "animal companion",
            embedding: [1.0, 0.01],
            limit: 10
        )
        let context = MemoryEngine.automaticRecallContext(for: results)
        #expect(context?.contains("Miso") == true)
    }

    @Test
    func `Automatic recall skips when nothing clears the threshold`() async throws {
        let (engine, base) = makeRecallMergeEngine()
        defer { try? FileManager.default.removeItem(at: base) }

        // The unrelated query shares no tokens with the stored fact and its
        // stub vector is orthogonal, so every tier scores 0 and the turn must
        // run with no injected context rather than smuggling in noise.
        _ = try await engine.storeSemantic(
            fact: "My cats are Miso and Soba",
            embedding: [1.0, 0.0],
            source: "user"
        )
        let stub = MergeParaphraseStubBackend()
        let message = try await engine.recallMessage(
            for: "quantum entanglement calibration",
            sessionID: UUID(),
            embedder: stub
        )
        #expect(message == nil)

        let results = try await engine.recall(
            query: "quantum entanglement calibration",
            embedding: nil,
            limit: 5
        )
        #expect(MemoryEngine.automaticRecallContext(for: results) == nil)
    }

    @Test
    func `Injected doc lines always carry a citation suffix outside truncation`() throws {
        // Long content forces per-hit truncation; the citation must survive it
        // because it is appended outside the perHitChars budget.
        let longBody = String(repeating: "harbor manifest line ", count: 40)
        let docHit = MemoryResult(
            content: longBody,
            score: 0.9,
            source: .docIndex,
            metadata: [
                "display_name": "bills.numbers",
                "path": "/Users/alice/Desktop/bills.numbers",
                "date": "2024-01-02T00:00:00Z",
                "document_id": UUID().uuidString,
                "ordinal": "0"
            ]
        )
        let budgets = RecallBudgets(perTierLimit: 5, autoLimit: 5, threshold: 0.1, maxChars: 2000, perHitChars: 100)
        let context = MemoryEngine.automaticRecallContext(for: [docHit], budgets: budgets)
        let unwrapped = try #require(context)
        #expect(unwrapped.contains(MemoryEngine.automaticRecallHeader))
        #expect(unwrapped.contains("[docIndex]"))
        // Single-line squash plus ellipsis on the content half.
        #expect(unwrapped.contains("…"))
        // One bracketed citation suffix from hit metadata, never truncated away.
        #expect(unwrapped.contains("[2024-01-02T00:00:00Z|/Users/alice/Desktop/bills.numbers|bills.numbers]"))
        #expect(unwrapped.contains("bills.numbers"))
        // The content half respects the per-hit cap: the first content line is
        // bounded while the trailing citation rides outside it.
        #expect(MemoryEngine.citationSuffix(for: docHit) != nil)

        // A doc hit without a parent lookup still carries a fallback suffix so
        // every injected doc line is attributable.
        let orphan = MemoryResult(
            content: "orphan chunk body",
            score: 0.9,
            source: .docIndex,
            metadata: ["document_id": UUID().uuidString, "ordinal": "0"]
        )
        let orphanContext = MemoryEngine.automaticRecallContext(for: [orphan], budgets: budgets)
        #expect(orphanContext?.contains("[") == true)
        #expect(orphanContext?.contains("]") == true)

        // Trusted tiers without citation metadata stay suffix-free.
        let profileHit = MemoryResult(content: "My dog is named Biscuit", score: 0.9, source: .profile)
        #expect(MemoryEngine.citationSuffix(for: profileHit) == nil)
    }

    @Test
    func `Citation block respects per-tier caps and total maxChars`() throws {
        var hits: [MemoryResult] = []
        for index in 0 ..< 6 {
            hits.append(MemoryResult(
                content: "harbor note number \(index) " + String(repeating: "x", count: 300),
                score: 0.9 - Double(index) * 0.01,
                source: .docIndex,
                metadata: [
                    "display_name": "note-\(index).md",
                    "path": "/tmp/note-\(index).md",
                    "document_id": UUID().uuidString,
                    "ordinal": "0"
                ]
            ))
        }
        // autoLimit 2 caps the injected hits with room for both citations.
        let roomy = RecallBudgets(perTierLimit: 5, autoLimit: 2, threshold: 0.1, maxChars: 4000, perHitChars: 100)
        let roomyContext = try #require(MemoryEngine.automaticRecallContext(for: hits, budgets: roomy))
        #expect(roomyContext.contains(MemoryEngine.automaticRecallHeader))
        // Only two doc lines inject despite six relevant hits.
        #expect(roomyContext.components(separatedBy: "[docIndex]").count - 1 == 2)
        // Every injected doc line carries its citation.
        #expect(roomyContext.contains("note-0.md"))
        #expect(roomyContext.contains("note-1.md"))
        #expect(!roomyContext.contains("note-5.md"))

        // Tight total budget truncates the block with an ellipsis.
        let tight = RecallBudgets(perTierLimit: 5, autoLimit: 5, threshold: 0.1, maxChars: 300, perHitChars: 100)
        let tightContext = try #require(MemoryEngine.automaticRecallContext(for: Array(hits.prefix(2)), budgets: tight))
        #expect(tightContext.count <= 300)
        #expect(tightContext.hasSuffix("…"))
        #expect(tightContext.contains(MemoryEngine.automaticRecallHeader))
    }

    @Test
    func `Deep two-token series reaches top five while birthday still ranks`() async throws {
        let (engine, store, base) = makeKeywordCurveEngine()
        defer { try? FileManager.default.removeItem(at: base) }

        // Long series body dilutes BM25 length normalization while short
        // high-TF chatter outranks it, burying the full-overlap hit deep in
        // keyword order despite matching both query tokens.
        let filler = (0 ..< 120).map { "filler\($0)" }.joined(separator: " ")
        try await storeKeywordCurveDoc(
            in: store,
            externalID: "series",
            text: "karate cobra kai finale showdown birthday celebration special retrospective \(filler)"
        )
        for index in 0 ..< 16 {
            try await storeKeywordCurveDoc(
                in: store,
                externalID: "chatter-\(index)",
                text: "karate karate karate drills session \(index) footwork kata"
            )
        }
        try await storeKeywordCurveDoc(
            in: store,
            externalID: "birthday",
            text: "karate birthday party cake candles celebration"
        )

        let keywordHits = try await store.searchKeyword(query: "karate birthday", limit: 30)
        #expect(keywordHits.count >= 17)

        let budgets = RecallBudgets(
            perTierLimit: 20,
            autoLimit: 10,
            threshold: 0.1,
            maxChars: 4000,
            perHitChars: 500,
            docPoolMultiplier: 4
        )
        let fused = await engine.recallDocuments(query: "karate birthday", limit: 10, budgets: budgets)
        #expect(fused.count >= 5)
        guard let seriesIndex = fused.firstIndex(where: { $0.content.contains("cobra kai finale") }) else {
            Issue.record("Expected the two-token series chunk in fused results")
            return
        }
        #expect(seriesIndex < 5)
        #expect(fused.contains { $0.content.contains("party cake") })
        for hit in fused {
            #expect(hit.score >= 0 && hit.score <= 1)
        }
    }

    @Test
    func `Reciprocal-rank curve stays bounded monotonic with soft deep gap`() async throws {
        let rankOne = 1.0 / (60.0 + 1.0)
        let rankFifteen = 1.0 / (60.0 + 15.0)
        let rankFifty = 1.0 / (60.0 + 50.0)
        #expect(rankOne > rankFifteen)
        #expect(rankFifteen > rankFifty)
        #expect(rankOne > 0 && rankFifty > 0)
        #expect(rankOne <= 1.0)
        #expect(rankOne - rankFifteen < 0.01)
        #expect(rankOne - rankFifty < 0.01)

        let (engine, store, base) = makeKeywordCurveEngine()
        defer { try? FileManager.default.removeItem(at: base) }
        for index in 0 ..< 5 {
            try await storeKeywordCurveDoc(
                in: store,
                externalID: "curve-\(index)",
                text: "identical curve body karate birthday"
            )
        }
        let budgets = RecallBudgets(
            perTierLimit: 20,
            autoLimit: 10,
            threshold: 0.1,
            maxChars: 4000,
            perHitChars: 500,
            docPoolMultiplier: 4
        )
        let results = await engine.recallDocuments(query: "karate birthday", limit: 10, budgets: budgets)
        #expect(results.count == 5)
        let first = try #require(results.first)
        let last = try #require(results.last)
        #expect(first.score >= last.score)
        #expect(first.score - last.score < 0.2)
        for hit in results {
            #expect(hit.score >= 0 && hit.score <= 1)
        }
        // Identical bodies tie on BM25, so newest-first rowid order decides.
        #expect(results.first?.metadata["display_name"] == "curve-4")
        #expect(results.last?.metadata["display_name"] == "curve-0")
    }

    @Test
    func `Rank-one exact match still outranks deep partial`() async throws {
        let (engine, store, base) = makeKeywordCurveEngine()
        defer { try? FileManager.default.removeItem(at: base) }
        for index in 0 ..< 50 {
            try await storeKeywordCurveDoc(
                in: store,
                externalID: "partial-\(index)",
                text: "quarterly summary chatter \(index) plan review"
            )
        }
        try await storeKeywordCurveDoc(
            in: store,
            externalID: "exact",
            text: "quarterly notes.md summary"
        )

        let budgets = RecallBudgets(
            perTierLimit: 20,
            autoLimit: 10,
            threshold: 0.1,
            maxChars: 4000,
            perHitChars: 500,
            docPoolMultiplier: 4
        )
        let results = await engine.recallDocuments(query: "quarterly notes.md", limit: 10, budgets: budgets)
        #expect(results.count >= 2)
        #expect(results.first?.content.contains("notes.md") == true)
        #expect(results.dropFirst().contains { $0.content.contains("chatter") })
    }

    @Test
    func `Recency overlap and exact bonuses still decide close ranks`() async throws {
        let budgets = RecallBudgets(
            perTierLimit: 20,
            autoLimit: 10,
            threshold: 0.1,
            maxChars: 4000,
            perHitChars: 500,
            docPoolMultiplier: 4
        )

        let (recencyEngine, recencyStore, recencyBase) = makeKeywordCurveEngine()
        defer { try? FileManager.default.removeItem(at: recencyBase) }
        try await storeKeywordCurveDoc(
            in: recencyStore,
            externalID: "recency-older",
            text: "identical recency body harbor voyage"
        )
        try await storeKeywordCurveDoc(
            in: recencyStore,
            externalID: "recency-newer",
            text: "identical recency body harbor voyage"
        )
        let recency = await recencyEngine.recallDocuments(query: "identical recency", limit: 10, budgets: budgets)
        #expect(recency.count == 2)
        #expect(recency.first?.metadata["display_name"] == "recency-newer")

        let (overlapEngine, overlapStore, overlapBase) = makeKeywordCurveEngine()
        defer { try? FileManager.default.removeItem(at: overlapBase) }
        try await storeKeywordCurveDoc(
            in: overlapStore,
            externalID: "overlap-partial",
            text: "harbor voyage ledger notes"
        )
        try await storeKeywordCurveDoc(
            in: overlapStore,
            externalID: "overlap-full",
            text: "harbor compassrose voyage manifest"
        )
        let overlap = await overlapEngine.recallDocuments(query: "harbor compassrose", limit: 10, budgets: budgets)
        #expect(overlap.count == 2)
        #expect(overlap.first?.content.contains("compassrose") == true)

        let (exactEngine, exactStore, exactBase) = makeKeywordCurveEngine()
        defer { try? FileManager.default.removeItem(at: exactBase) }
        try await storeKeywordCurveDoc(
            in: exactStore,
            externalID: "exact-topical",
            text: "quarterly summary plan review"
        )
        try await storeKeywordCurveDoc(
            in: exactStore,
            externalID: "exact-name",
            text: "quarterly notes.md summary"
        )
        let exact = await exactEngine.recallDocuments(query: "quarterly notes.md", limit: 10, budgets: budgets)
        #expect(exact.count == 2)
        #expect(exact.first?.content.contains("notes.md") == true)
    }

    @Test
    func `Entity display name and whole-phrase bonuses seat the karate series above the birthday partial`() async throws {
        let (engine, store, base) = makeKeywordCurveEngine()
        defer { try? FileManager.default.removeItem(at: base) }

        // The series parent is the named entity: its display name carries both
        // salient tokens and its body carries the whole salient phrase, so it
        // earns two structural bonuses on top of full overlap. The birthday doc
        // matches only one salient token and the sixteen chatter docs match a
        // single repeated token, so neither earns either bonus.
        let filler = (0 ..< 120).map { "filler\($0)" }.joined(separator: " ")
        try await storeKeywordCurveDoc(
            in: store,
            externalID: "karate-birthday-series",
            text: "karate birthday cobra kai finale showdown celebration special retrospective \(filler)"
        )
        for index in 0 ..< 16 {
            try await storeKeywordCurveDoc(
                in: store,
                externalID: "chatter-\(index)",
                text: "karate karate karate drills session \(index) footwork kata"
            )
        }
        try await storeKeywordCurveDoc(
            in: store,
            externalID: "birthday",
            text: "birthday party cake candles celebration"
        )

        let budgets = RecallBudgets(
            perTierLimit: 20,
            autoLimit: 10,
            threshold: 0.1,
            maxChars: 4000,
            perHitChars: 500,
            docPoolMultiplier: 4
        )
        let fused = await engine.recallDocuments(query: "karate birthday", limit: 10, budgets: budgets)
        #expect(fused.count >= 5)
        guard let seriesIndex = fused.firstIndex(where: { $0.metadata["display_name"] == "karate-birthday-series" }) else {
            Issue.record("Expected the karate-birthday series chunk in fused results")
            return
        }
        guard let birthdayIndex = fused.firstIndex(where: { $0.content.contains("party cake") }) else {
            Issue.record("Expected the partial birthday chunk in fused results")
            return
        }
        // The series carries the entity name plus the contiguous phrase, so it
        // outranks every partial match into the top five rather than only
        // surviving the widened pool.
        #expect(seriesIndex < 5)
        #expect(seriesIndex < birthdayIndex)
        for hit in fused {
            #expect(hit.score >= 0 && hit.score <= 1)
        }
    }

    @Test
    func `Whole-phrase bonus outranks the same-token scattered match`() async throws {
        let (engine, store, base) = makeKeywordCurveEngine()
        defer { try? FileManager.default.removeItem(at: base) }

        // Identical token counts and term frequencies keep the BM25 order equal
        // for both targets, so they sit adjacent in the union and only the
        // contiguous phrase separates them. Single-token decoys rank strictly
        // below the two-token targets, which holds the recency gap between the
        // targets small enough for the phrase bonus to decide.
        try await storeKeywordCurveDoc(
            in: store,
            externalID: "phrase-contiguous",
            text: "karate birthday cobra kai finale showdown celebration"
        )
        try await storeKeywordCurveDoc(
            in: store,
            externalID: "phrase-scattered",
            text: "karate cobra kai birthday finale showdown celebration"
        )
        for index in 0 ..< 16 {
            try await storeKeywordCurveDoc(
                in: store,
                externalID: "decoy-\(index)",
                text: "karate chatter drill \(index) footwork kata"
            )
        }

        let budgets = RecallBudgets(
            perTierLimit: 20,
            autoLimit: 10,
            threshold: 0.1,
            maxChars: 4000,
            perHitChars: 500,
            docPoolMultiplier: 4
        )
        let fused = await engine.recallDocuments(query: "karate birthday", limit: 10, budgets: budgets)
        #expect(fused.count == 10)
        guard let contiguousIndex = fused.firstIndex(where: { $0.metadata["display_name"] == "phrase-contiguous" }),
              let scatteredIndex = fused.firstIndex(where: { $0.metadata["display_name"] == "phrase-scattered" })
        else {
            Issue.record("Expected both phrase fixtures in fused results")
            return
        }
        // Neither display name is the queried entity, so the phrase bonus alone
        // must lift the contiguous run over the token-identical scattered body.
        #expect(contiguousIndex < scatteredIndex)
    }

    @Test
    func `Non-entity associative query keeps its pre-bonus ordering and bounded scores`() async throws {
        let (engine, store, base) = makeKeywordCurveEngine()
        defer { try? FileManager.default.removeItem(at: base) }

        // No display name holds both salient tokens, so the entity bonus is
        // silent; the scattered body holds both tokens non-adjacently, so the
        // phrase bonus is silent too. The ordering therefore rests on the
        // unchanged blend: overlap first, then the recency prior.
        try await storeKeywordCurveDoc(
            in: store,
            externalID: "series-scattered",
            text: "karate cobra kai birthday finale showdown celebration"
        )
        try await storeKeywordCurveDoc(
            in: store,
            externalID: "birthday-partial",
            text: "birthday party cake candles celebration"
        )

        let budgets = RecallBudgets(
            perTierLimit: 20,
            autoLimit: 10,
            threshold: 0.1,
            maxChars: 4000,
            perHitChars: 500,
            docPoolMultiplier: 4
        )
        let fused = await engine.recallDocuments(query: "karate birthday", limit: 10, budgets: budgets)
        #expect(fused.count == 2)
        #expect(fused.first?.metadata["display_name"] == "series-scattered")
        #expect(fused.last?.metadata["display_name"] == "birthday-partial")

        // With neither structural bonus firing, the two-doc field keeps the
        // exact blend score it carried before the bonuses existed: full
        // overlap for the scattered body, half overlap for the partial one.
        let first = try #require(fused.first?.score)
        let last = try #require(fused.last?.score)
        #expect(abs(first - (0.3 + 1.6 / 61.0)) < 1e-6)
        #expect(abs(last - (0.1 + 1.6 / 62.0)) < 1e-6)
    }
}

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
}

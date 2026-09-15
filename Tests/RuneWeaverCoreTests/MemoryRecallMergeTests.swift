// MemoryRecallMergeTests — merge-rank regression coverage for recall tiers.
//
// Pins how episodic, semantic, and profile hits interleave when recall merges
// them: paraphrased semantic facts must survive episodic keyword volume,
// exact keyword queries must stay episodic-first, and automatic injection must
// fire only when a hit clears the shared threshold. Scoped to the
// MemoryEngine recall merge so tier calibration cannot silently shift ranking
// or injection without a failing test.
import Foundation
@testable import RuneWeaverCore
import Testing

/// Builds an isolated engine on a fresh temporary directory.
///
/// Each test gets its own episodes database, vector directory, and profile
/// file so fixture writes never leak between tests.
/// - Returns: Engine plus the base directory owning its files.
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
///
/// Maps the paraphrase under test to a near-identical vector so cosine sits
/// just under 1.0: high enough to model a true paraphrase, low enough that an
/// unscaled episodic rank of 1.0 would still win without calibration.
/// Unrelated queries map to an orthogonal vector so cosine is 0 and the
/// store filters them, keeping the "no match" path honest.
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

        // The stored fact shares no tokens with the paraphrase query, so the
        // keyword fallback cannot recall it: only vector similarity can. The
        // episodic rows each carry one query token, so FTS returns them and
        // the merge must prefer meaning over literal overlap.
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

        // Exact keyword queries must not flip when semantic scaling changes:
        // the episodic turn holds the literal address while the semantic row
        // only shares common words like "my", so episodic stays first even
        // though both tiers match.
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

        // Five episodic rows all match the query through FTS, which is the
        // volume that previously buried the semantic tier. The semantic hit
        // stays recallable through vectors despite zero token overlap, so the
        // merge must keep it inside the bounded top results.
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
}

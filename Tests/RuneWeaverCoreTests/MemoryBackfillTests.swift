// Rune Weaver Core Tests — Embedding backfill with dimension discipline.

import Foundation
@testable import RuneWeaverCore
import Testing

/// Deterministic vector producer with a separately advertised width.
private struct BackfillStubBackend: EmbeddingsBackend, Sendable {
    /// Stable identifier marking rows as test-embedded.
    let modelID = "test-backfill"
    /// Advertised backend width, or nil when unknown until output.
    let dimension: Int?
    /// Actual width of every produced vector.
    let width: Int

    /// Creates a stub backend.
    init(dimension: Int?, width: Int) {
        self.dimension = dimension
        self.width = width
    }

    /// Returns one uniform vector per input, preserving order.
    /// - Parameter texts: Input texts, in order.
    /// - Returns: Vectors of `width` ones; empty for empty input.
    func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        return texts.map { _ in Array(repeating: 1.0, count: width) }
    }
}

/// Vector producer whose width varies by input text.
private struct VaryingWidthBackfillBackend: EmbeddingsBackend, Sendable {
    /// Stable identifier marking rows as test-embedded.
    let modelID = "test-backfill-varying"
    /// Advertised width, always nil so the precheck cannot short-circuit the
    /// per-row path under test.
    let dimension: Int? = nil
    /// Width to produce for each input text, defaulting to three when absent.
    let widthsByText: [String: Int]

    /// Returns one vector per input, sized per the text map.
    /// - Parameter texts: Input texts, in order.
    /// - Returns: Vectors matching each text's configured width.
    func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        return texts.map { text in
            Array(repeating: 1.0, count: widthsByText[text] ?? 3)
        }
    }
}

/// Builds an isolated engine on a fresh temporary directory.
private func makeBackfillEngine() -> (engine: MemoryEngine, base: URL) {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let engine = MemoryEngine(
        episodesDBPath: base.appendingPathComponent("episodes.db").path,
        vectorDBPath: base.appendingPathComponent("vectors").path,
        profilePath: base.appendingPathComponent("profile.json").path
    )
    return (engine, base)
}

@Suite("Memory Backfill")
struct MemoryBackfillTests {
    @Test
    func `Backfill embeds keyword-only rows with preserved ids`() async throws {
        let (engine, base) = makeBackfillEngine()
        defer { try? FileManager.default.removeItem(at: base) }

        // Keyword-only rows carry no vectors yet but already own stable
        // identifiers, source metadata, and creation dates that later
        // recall and profile mirrors depend on.
        _ = try await engine.storeProfileFact(content: "My dog is named Biscuit", source: "chat")
        _ = try await engine.storeProfileFact(content: "I live in Portland", source: "chat")
        let before = await engine.allSemanticFacts()
        #expect(before.count == 2)
        #expect(before.filter { !$0.embedding.isEmpty }.isEmpty)
        let idsBefore = Set(before.map(\.id))
        let metadataBefore = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0.metadata) })
        let createdBefore = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0.createdAt) })

        // A single-text batch exercises the batching loop boundary while
        // keeping the geometry trivial: every row should gain a width-3 vector.
        let stub = BackfillStubBackend(dimension: 3, width: 3)
        let result = try await engine.backfillEmbeddings(embedder: stub, batchSize: 1)
        #expect(result.embedded == 2)
        #expect(result.skipped == 0)
        #expect(result.failed == 0)

        // Identity must survive the rewrite: the same ids come back with
        // vectors, the original metadata travels with each row, and creation
        // dates are unchanged so chronological ordering never shifts.
        let after = await engine.allSemanticFacts()
        #expect(after.count == 2)
        #expect(after.allSatisfy { $0.embedding.count == 3 })
        #expect(Set(after.map(\.id)) == idsBefore)
        for fact in after {
            #expect(fact.metadata == metadataBefore[fact.id])
            #expect(fact.createdAt == createdBefore[fact.id])
        }
        let profile = await engine.getUserProfile()
        #expect(Set(profile.facts.map(\.id)).isSuperset(of: idsBefore))
        #expect(await engine.semanticDimension() == 3)
    }

    @Test
    func `Already-embedded rows are left untouched`() async throws {
        let (engine, base) = makeBackfillEngine()
        defer { try? FileManager.default.removeItem(at: base) }

        // One vector-backed row plus one keyword-only row isolates the
        // backfill scope: only the empty row should gain a vector.
        let originalVector: [Float] = [1.0, 2.0, 3.0]
        let seeded = try await engine.storeSemantic(
            fact: "My dog is named Biscuit",
            embedding: originalVector,
            metadata: ["source": "user"],
            source: "user"
        )
        _ = try await engine.storeProfileFact(content: "I live in Portland", source: "chat")

        let stub = BackfillStubBackend(dimension: 3, width: 3)
        let result = try await engine.backfillEmbeddings(embedder: stub)
        #expect(result.embedded == 1)
        #expect(result.skipped == 0)
        #expect(result.failed == 0)

        // The seeded vector must keep its exact floats rather than being
        // overwritten with the stub output, proving embedded rows are never
        // re-embedded.
        let after = await engine.allSemanticFacts()
        #expect(after.count == 2)
        let seededAfter = after.first { $0.id == seeded.id }
        #expect(seededAfter?.embedding == originalVector)
        #expect(after.filter { $0.id != seeded.id }.allSatisfy { $0.embedding.count == 3 })
    }

    @Test
    func `Dimension conflict aborts with guidance`() async throws {
        let (engine, base) = makeBackfillEngine()
        defer { try? FileManager.default.removeItem(at: base) }

        // A width-2 store row fixes the store dimension, so a width-3
        // backend must refuse to mix widths instead of corrupting similarity.
        _ = try await engine.storeSemantic(
            fact: "My dog is named Biscuit",
            embedding: [1.0, 2.0],
            source: "user"
        )
        _ = try await engine.storeProfileFact(content: "I live in Portland", source: "chat")

        let stub = BackfillStubBackend(dimension: 3, width: 3)
        do {
            _ = try await engine.backfillEmbeddings(embedder: stub)
            Issue.record("Expected a dimension mismatch to throw")
        } catch {
            // Guidance must name both widths and require an explicit reset
            // so operators know exactly why the abort happened and how to proceed.
            let message = String(describing: error).lowercased()
            #expect(message.contains("2"))
            #expect(message.contains("3"))
            #expect(message.contains("reset"))
        }

        // The abort happens before any work, so the keyword-only row stays
        // empty rather than partially backfilling.
        let after = await engine.allSemanticFacts()
        #expect(after.contains { $0.content.contains("Portland") && $0.embedding.isEmpty })
    }

    @Test
    func `Per-row mismatch is skipped while matching rows embed`() async throws {
        let (engine, base) = makeBackfillEngine()
        defer { try? FileManager.default.removeItem(at: base) }

        // The store holds a width-2 vector while the backend advertises no width and produces per-
        // text widths. A width-3 row mismatches at upsert time and must skip, while a width-2 row
        // still embeds, so the pass mixes both outcomes without aborting.
        let seeded = try await engine.storeSemantic(
            fact: "My dog is named Biscuit",
            embedding: [1.0, 2.0],
            source: "user"
        )
        _ = try await engine.storeProfileFact(content: "I live in Portland", source: "chat")
        _ = try await engine.storeProfileFact(content: "I drink tea", source: "chat")

        let stub = VaryingWidthBackfillBackend(widthsByText: ["I live in Portland": 3, "I drink tea": 2])
        let result = try await engine.backfillEmbeddings(embedder: stub)
        #expect(result.embedded == 1)
        #expect(result.skipped == 1)
        #expect(result.failed == 0)

        // The mismatched row stays keyword-only, the matching row gains its
        // vector, and the seeded row keeps its original vector — proving
        // per-row rejection never mutates either side.
        let after = await engine.allSemanticFacts()
        #expect(after.first { $0.content.contains("Portland") }?.embedding.isEmpty == true)
        #expect(after.first { $0.content.contains("tea") }?.embedding.count == 2)
        #expect(after.first { $0.id == seeded.id }?.embedding == [1.0, 2.0])
    }

    @Test
    func `All rows skipped throws reset guidance`() async throws {
        let (engine, base) = makeBackfillEngine()
        defer { try? FileManager.default.removeItem(at: base) }

        // The backend advertises no width, so the upfront guard cannot fire, yet every pending row
        // mismatches the store's width-2 vector. That is a systematic disagreement, not per-row
        // noise, so it must surface the reset guidance instead of a silent all-skip.
        _ = try await engine.storeSemantic(
            fact: "My dog is named Biscuit",
            embedding: [1.0, 2.0],
            source: "user"
        )
        _ = try await engine.storeProfileFact(content: "I live in Portland", source: "chat")

        let stub = BackfillStubBackend(dimension: nil, width: 3)
        do {
            _ = try await engine.backfillEmbeddings(embedder: stub)
            Issue.record("Expected an all-skipped pass to throw reset guidance")
        } catch {
            let message = String(describing: error).lowercased()
            #expect(message.contains("2"))
            #expect(message.contains("3"))
            #expect(message.contains("reset"))
        }

        // The abort leaves the keyword-only row empty and the seeded row's
        // vector untouched.
        let after = await engine.allSemanticFacts()
        #expect(after.contains { $0.content.contains("Portland") && $0.embedding.isEmpty })
        #expect(after.first { $0.content.contains("Biscuit") }?.embedding == [1.0, 2.0])
    }

    @Test
    func `Removing the last sized row clears the derived width`() async throws {
        let (engine, base) = makeBackfillEngine()
        defer { try? FileManager.default.removeItem(at: base) }

        // A single sized row fixes the derived width; removing it must clear
        // the width so an empty store never rejects the next backend's first
        // vector with a stale expectation.
        let seeded = try await engine.storeSemantic(
            fact: "My dog is named Biscuit",
            embedding: [1.0, 2.0],
            source: "user"
        )
        #expect(await engine.semanticDimension() == 2)

        try await engine.removeFactThrowing(id: seeded.id)
        #expect(await engine.semanticDimension() == nil)
    }
}

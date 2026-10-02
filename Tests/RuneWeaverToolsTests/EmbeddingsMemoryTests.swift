// Rune Weaver Tools Tests — Embeddings-backed memory recall tests.

import Foundation
@testable import RuneWeaverCore
@testable import RuneWeaverTools
import Testing

/// Embeddings producer with scripted vectors for deterministic recall.
private struct ControlledEmbeddingsBackend: EmbeddingsBackend, Sendable {
    /// Stable identifier marking rows as test-embedded.
    let modelID: String = "test-controlled"
    /// Width of every scripted vector.
    let dimension: Int? = 2
    /// Canned vectors keyed by exact input text.
    let vectorsByText: [String: [Float]]
    /// Vector for unscripted texts (kept orthogonal to scripted rows).
    let fallback: [Float] = [0.0, 0.0]

    /// Returns scripted vectors in input order.
    /// - Parameter texts: Texts to embed.
    /// - Returns: One vector per input, scripted or fallback.
    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { vectorsByText[$0] ?? fallback }
    }
}

/// Embeddings producer that always fails, exercising the keyword fallback.
private struct FailingEmbeddingsBackend: EmbeddingsBackend, Sendable {
    /// Stable identifier marking rows as never-embedded.
    let modelID: String = "test-failing"
    /// No width to advertise: nothing ever embeds successfully.
    let dimension: Int? = nil

    /// Rejects every batch so callers must use keyword storage and recall.
    /// - Parameter texts: Ignored input texts.
    /// - Returns: Never returns.
    func embed(_ _: [String]) async throws -> [[Float]] {
        throw NSError(domain: "TestEmbeddings", code: -1, userInfo: [NSLocalizedDescriptionKey: "stub embedding failure"])
    }
}

@Suite("Embeddings Memory Wiring")
struct EmbeddingsMemoryTests {
    @Test
    func `Paraphrase with zero token overlap recalls the nearby fact`() async throws {
        let (engine, base) = try ToolsTestSupport.makeIsolatedMemoryEngine()
        defer { ToolsTestSupport.cleanupIsolatedEngineBase(base) }

        // Geometry is fully controlled: the dog fact and its paraphrase share one direction while
        // the physics fact sits orthogonal, so a cosine query for the paraphrase must prefer the
        // dog fact even though neither fact shares a token with the query.
        let dogFact = "My dog is named Biscuit"
        let physicsFact = "Quantum field theory is fascinating"
        let paraphrase = "canine companion"
        let stub = ControlledEmbeddingsBackend(vectorsByText: [
            dogFact: [1.0, 0.0],
            physicsFact: [0.0, 1.0],
            paraphrase: [1.0, 0.0]
        ])

        // Writes go through the tool seam so the test covers the same path
        // the model drives, including the vector-first with keyword
        // fallback policy.
        let remember = RememberFactTool(engine: engine, audit: { _ in }, embedder: stub)
        let first = try await remember.execute(
            input: ToolInput(toolName: "memories.store", argumentsJSON: #"{"text":"\#(dogFact)"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(first.isError == false)
        let second = try await remember.execute(
            input: ToolInput(toolName: "memories.store", argumentsJSON: #"{"text":"\#(physicsFact)"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(second.isError == false)

        // Stored rows must carry vectors: an empty embedding here would mean
        // the tool silently kept the keyword path despite a healthy producer.
        let stored = await engine.allSemanticFacts()
        #expect(stored.count == 2)
        #expect(stored.allSatisfy { !$0.embedding.isEmpty })

        // Keyword-only recall proves the test premise: with no shared tokens
        // the paraphrase finds nothing, so any hit below must come from
        // vectors rather than accidental overlap.
        let keywordOnly = try await engine.recall(query: paraphrase, embedding: nil, limit: 5)
        #expect(keywordOnly.isEmpty)

        // Vector recall through the tool seam must surface the nearby fact
        // first despite the zero-overlap query.
        let recall = RecallMemoriesTool(engine: engine, embedder: stub)
        let output = try await recall.execute(
            input: ToolInput(toolName: "memories.recall", argumentsJSON: #"{"query":"\#(paraphrase)","limit":5}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == false)
        #expect(output.content.contains("Biscuit"))
    }

    @Test
    func `Embedder failure still stores and recalls via keywords`() async throws {
        let (engine, base) = try ToolsTestSupport.makeIsolatedMemoryEngine()
        defer { ToolsTestSupport.cleanupIsolatedEngineBase(base) }

        // A failing producer must never lose the write: the tool keeps the
        // keyword-only row so later recall still works without vectors.
        let failing = FailingEmbeddingsBackend()
        let remember = RememberFactTool(engine: engine, audit: { _ in }, embedder: failing)
        let factText = "The lighthouse keeper collects brass compasses"
        let stored = try await remember.execute(
            input: ToolInput(toolName: "memories.store", argumentsJSON: #"{"text":"\#(factText)"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(stored.isError == false)

        // The fallback row is keyword-only by construction (empty embedding)
        // yet still mirrored into the profile for display commands.
        let profile = await engine.getUserProfile()
        #expect(profile.facts.contains { $0.content.contains("lighthouse keeper") })
        let facts = await engine.allSemanticFacts()
        #expect(facts.contains { $0.content.contains("lighthouse keeper") && $0.embedding.isEmpty })

        // Recall with the same failing producer must degrade to keyword
        // overlap rather than erroring: the shared-token query finds the
        // fact even though no vector was ever produced.
        let recall = RecallMemoriesTool(engine: engine, embedder: failing)
        let output = try await recall.execute(
            input: ToolInput(toolName: "memories.recall", argumentsJSON: #"{"query":"lighthouse compasses","limit":5}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == false)
        #expect(output.content.contains("lighthouse keeper"))
    }
}

// Rune Weaver Core Tests — Contract tests for the embeddings seam.

import Foundation
@testable import RuneWeaverCore
import Testing

/// Deterministic stub returning position-tagged vectors in input order.
private struct StubEmbeddingsBackend: EmbeddingsBackend, Sendable {
    /// Stable stub identifier for diagnostics.
    let modelID = "stub-embeddings"
    /// Fixed stub width asserted by consumers.
    let dimension: Int? = 2

    /// Returns one position-tagged vector per input, preserving order.
    /// - Parameter texts: Input texts, in order.
    /// - Returns: Vectors in input order; empty for empty input.
    func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        return texts.enumerated().map { index, text in [Float(index), Float(text.count)] }
    }
}

@Suite("Embeddings Backend")
struct EmbeddingsBackendTests {
    @Test
    func `Disabled backend throws unavailable for non-empty input`() async {
        let backend = DisabledEmbeddingsBackend()
        do {
            _ = try await backend.embed(["hello"])
            Issue.record("Expected EmbeddingsError.unavailable")
        } catch let error as EmbeddingsError {
            #expect(error == .unavailable)
        } catch {
            Issue.record("Expected EmbeddingsError, got \(error)")
        }
    }

    @Test
    func `Embeddings errors compare by case`() {
        #expect(EmbeddingsError.unavailable == EmbeddingsError.unavailable)
        #expect(EmbeddingsError.invalidInput == EmbeddingsError.invalidInput)
        #expect(EmbeddingsError.embeddingFailed == EmbeddingsError.embeddingFailed)
        #expect(EmbeddingsError.unavailable != EmbeddingsError.invalidInput)
        #expect(EmbeddingsError.unavailable != EmbeddingsError.embeddingFailed)
        #expect(EmbeddingsError.invalidInput != EmbeddingsError.embeddingFailed)
    }

    @Test
    func `Empty input returns empty output`() async throws {
        let stub = StubEmbeddingsBackend()
        let stubVectors = try await stub.embed([])
        #expect(stubVectors.isEmpty)

        // The batch contract holds for every backend: even the disabled
        // backend treats an empty batch as a no-op rather than a failure.
        let disabledVectors = try await DisabledEmbeddingsBackend().embed([])
        #expect(disabledVectors.isEmpty)
    }

    @Test
    func `Stub preserves input order`() async throws {
        let stub = StubEmbeddingsBackend()
        let inputs = ["alpha", "beta gamma", "delta"]
        let vectors = try await stub.embed(inputs)
        #expect(vectors.count == inputs.count)
        for (index, vector) in vectors.enumerated() {
            #expect(vector == [Float(index), Float(inputs[index].count)])
        }
    }
}

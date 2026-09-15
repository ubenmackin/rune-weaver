// RuneWeaver - Tests - Apple NaturalLanguage embeddings backend
//
// Exercises the local-first sentence backend through injected lookups so
// outcomes stay deterministic without loading the on-device model or
// asserting on its exact floats. Scopes to contract edges: vector shape,
// dimension learning, ordering with arity preservation and blank rejection,
// and error mapping that lets recall choose its keyword fallback.

import Foundation
@testable import RuneWeaverCore
import Testing

@Suite("Apple NL Embeddings Backend")
struct AppleNLEmbeddingsTests {
    @Test
    func `Model identifier is the Apple sentence model`() {
        let backend = AppleNLEmbeddingsBackend(lookup: { _ in [1.0, 2.0] })
        #expect(backend.modelID == "apple-nl-sentence")
    }

    @Test
    func `Embed produces non-empty vectors and learns dimension`() async throws {
        let backend = AppleNLEmbeddingsBackend(lookup: { _ in [0.5, -0.25, 0.75] })
        #expect(await backend.dimension == nil)
        let vectors = try await backend.embed(["hello world"])
        #expect(vectors.count == 1)
        #expect(vectors[0].count == 3)
        for value in vectors[0] {
            #expect(value.isFinite)
        }
        #expect(await backend.dimension == 3)
    }

    @Test
    func `Dimension stays stable across calls`() async throws {
        let backend = AppleNLEmbeddingsBackend(lookup: { text in [Double(text.count), 2.0] })
        let first = try await backend.embed(["alpha"])
        #expect(await backend.dimension == 2)
        let second = try await backend.embed(["a much longer sentence here"])
        #expect(second[0].count == 2)
        #expect(await backend.dimension == 2)
        #expect(first[0].count == second[0].count)
    }

    @Test
    func `Order is preserved across batch inputs`() async throws {
        // Length-encoded stub vectors make order observable without
        // depending on live model floats.
        let backend = AppleNLEmbeddingsBackend(lookup: { text in [Double(text.count), 1.0, 2.0] })
        let vectors = try await backend.embed(["a", "abc", "ab"])
        #expect(vectors.count == 3)
        #expect(vectors[0][0] == 1.0)
        #expect(vectors[1][0] == 3.0)
        #expect(vectors[2][0] == 2.0)
    }

    @Test
    func `Blank strings reject the batch to preserve arity`() async {
        // The batch contract promises one vector per input in order, so a
        // blank anywhere rejects the whole batch instead of silently
        // filtering; callers filter blanks before this call.
        let backend = AppleNLEmbeddingsBackend(lookup: { text in [Double(text.count), 7.0] })
        for batch in [["hello", "", "world"], ["a", "  ", "abc"], ["   "]] {
            do {
                _ = try await backend.embed(batch)
                Issue.record("Expected invalidInput for a batch containing a blank string")
            } catch let error as EmbeddingsError {
                guard case .invalidInput = error else {
                    Issue.record("Expected invalidInput, got \(error)")
                    return
                }
            } catch {
                Issue.record("Expected EmbeddingsError, got \(error)")
            }
        }
    }

    @Test
    func `Same text yields the same vector`() async throws {
        let backend = AppleNLEmbeddingsBackend(lookup: { text in [Double(text.count), 0.5, -0.5] })
        let first = try await backend.embed(["deterministic sentence"])
        let second = try await backend.embed(["deterministic sentence"])
        #expect(first == second)
    }

    @Test
    func `Empty batch returns empty output without a model round-trip`() async throws {
        // A nil-returning lookup proves no round-trip happened: any model
        // call would surface as `unavailable` instead of empty output.
        let backend = AppleNLEmbeddingsBackend(lookup: { _ in nil })
        let vectors = try await backend.embed([])
        #expect(vectors.isEmpty)
    }

    @Test
    func `Blank-only batch throws invalidInput`() async {
        let backend = AppleNLEmbeddingsBackend(lookup: { _ in [1.0] })
        do {
            _ = try await backend.embed(["", "   ", "\n\t "])
            Issue.record("Expected invalidInput for a blank-only batch")
        } catch let error as EmbeddingsError {
            guard case .invalidInput = error else {
                Issue.record("Expected invalidInput, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected EmbeddingsError, got \(error)")
        }
    }

    @Test
    func `Missing vector maps to unavailable without crashing`() async {
        let backend = AppleNLEmbeddingsBackend(lookup: { text in
            text == "missing model text" ? nil : [1.0, 2.0]
        })
        do {
            _ = try await backend.embed(["missing model text"])
            Issue.record("Expected unavailable when lookup returns nil")
        } catch let error as EmbeddingsError {
            guard case .unavailable = error else {
                Issue.record("Expected unavailable, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected EmbeddingsError, got \(error)")
        }
    }

    @Test
    func `Empty lookup vector maps to unavailable`() async {
        let backend = AppleNLEmbeddingsBackend(lookup: { _ -> [Double]? in [] })
        do {
            _ = try await backend.embed(["hello"])
            Issue.record("Expected unavailable for an empty vector")
        } catch let error as EmbeddingsError {
            guard case .unavailable = error else {
                Issue.record("Expected unavailable, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected EmbeddingsError, got \(error)")
        }
    }
}

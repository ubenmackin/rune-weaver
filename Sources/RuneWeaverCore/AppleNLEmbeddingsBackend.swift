// RuneWeaver - Core - Apple NaturalLanguage sentence embeddings
//
// Local-first default vector producer with zero third-party dependencies.
// Bridges semantic recall to the on-device English sentence model so facts
// embed without network access, while recall degrades to keyword overlap
// whenever the model is missing or a text cannot be vectorized.

import Foundation

#if canImport(NaturalLanguage)
    import NaturalLanguage
#endif

/// On-device sentence embeddings backed by Apple NaturalLanguage.
///
/// Zero-dependency default: encapsulates the English sentence embedding model
/// inside an actor so model access is fully isolated and data-race free under
/// Swift 6 strict concurrency without requiring unsafe annotations or locks.
public actor AppleNLEmbeddingsBackend: EmbeddingsBackend {
    /// Stable model identifier reported to stores and diagnostics.
    public nonisolated let modelID: String = "apple-nl-sentence"

    /// Width of produced vectors once observed; nil until the first success.
    public private(set) var dimension: Int?

    /// Injected vector lookup, defaulting to the live NaturalLanguage model.
    private let lookup: (@Sendable (String) -> [Double]?)?

    #if canImport(NaturalLanguage)
        private let handle: NLEmbedding?
    #endif

    /// Creates a backend.
    /// - Parameter lookup: Vector lookup per text, returning nil when the
    ///   text cannot be vectorized. Defaults to the live on-device English
    ///   sentence model; tests inject a stub.
    public init(lookup: (@Sendable (String) -> [Double]?)? = nil) {
        self.lookup = lookup
        #if canImport(NaturalLanguage)
            self.handle = NLEmbedding.sentenceEmbedding(for: .english)
        #endif
    }

    /// Embeds texts in order, one vector per input.
    ///
    /// Upholds the batch contract without changing arity: empty input
    /// returns empty output with no model round-trip, and any blank string
    /// (empty or whitespace-only) rejects the whole batch as `invalidInput`
    /// instead of being silently filtered, so callers can always zip inputs
    /// to outputs positionally.
    /// - Parameter texts: Texts to embed.
    /// - Returns: One non-empty vector per input, in order; empty for empty input.
    /// - Throws: `EmbeddingsError.invalidInput` when any input is blank;
    ///   `EmbeddingsError.unavailable` when the model cannot vectorize a
    ///   text (missing model, unsupported language).
    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        guard !texts.contains(where: Self.isBlank) else {
            throw EmbeddingsError.invalidInput
        }

        var produced: [[Float]] = []
        produced.reserveCapacity(texts.count)
        for text in texts {
            let raw: [Double]?
            if let customLookup = lookup {
                raw = customLookup(text)
            } else {
                #if canImport(NaturalLanguage)
                    raw = handle?.vector(for: text)
                #else
                    raw = nil
                #endif
            }
            guard let raw, !raw.isEmpty else {
                throw EmbeddingsError.unavailable
            }
            produced.append(raw.map { Float($0) })
        }

        if let first = produced.first, dimension == nil {
            dimension = first.count
        }

        return produced
    }

    /// Whether text holds no embeddable content.
    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

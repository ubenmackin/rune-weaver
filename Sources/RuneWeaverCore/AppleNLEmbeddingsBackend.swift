// Rune Weaver Core — Apple NaturalLanguage sentence embeddings.

import Foundation

#if canImport(NaturalLanguage)
    import NaturalLanguage
#endif

/// On-device sentence embeddings backed by Apple NaturalLanguage.
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
    public init(lookup: (@Sendable (String) -> [Double]?)? = nil) {
        self.lookup = lookup
        #if canImport(NaturalLanguage)
            self.handle = NLEmbedding.sentenceEmbedding(for: .english)
        #endif
    }

    /// Embeds texts in order, one vector per input.
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

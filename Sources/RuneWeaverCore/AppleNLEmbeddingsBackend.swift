// RuneWeaver - Core - Apple NaturalLanguage sentence embeddings
//
// Local-first default vector producer with zero third-party dependencies.
// Bridges semantic recall to the on-device English sentence model so facts
// embed without network access, while recall degrades to keyword overlap
// whenever the model is missing or a text cannot be vectorized.

import Foundation

#if canImport(NaturalLanguage)
    @preconcurrency import NaturalLanguage
#endif

/// On-device sentence embeddings backed by Apple NaturalLanguage.
///
/// Zero-dependency default: wraps the cached English
/// `NLEmbedding.sentenceEmbedding` handle and converts its `Double`
/// vectors to `Float` rows for the vector store. The handle is cached per
/// process because fetching it touches model loading; per-string work is
/// dispatched off the caller's executor so `MemoryEngine` actor mutations
/// never block on model inference. A missing handle or a nil vector never
/// crashes — it surfaces as `EmbeddingsError.unavailable` so recall can
/// use its keyword path. Repeated embeddings of the same text are
/// deterministic because the underlying model is.
public struct AppleNLEmbeddingsBackend: EmbeddingsBackend, Sendable {
    /// Stable model identifier reported to stores and diagnostics.
    public let modelID: String = "apple-nl-sentence"

    /// Width of produced vectors once observed; nil until the first success.
    ///
    /// Read through the shared cache so `let` backends still observe the
    /// learned width after `embed` completes.
    public var dimension: Int? {
        storage.dimension
    }

    /// Injected vector lookup, defaulting to the live NaturalLanguage model.
    ///
    /// Separated so tests can substitute deterministic vectors without
    /// loading the on-device model or asserting on its exact floats.
    private let lookup: @Sendable (String) -> [Double]?

    /// Shared mutable cache for the learned dimension.
    ///
    /// A reference box lets `embed` stay non-mutating so callers holding a
    /// `let` backend (including actor-isolated recall paths) still observe
    /// the learned width; copies of one backend share the observation,
    /// while independently constructed backends start unobserved.
    private let storage: Storage

    /// Creates a backend.
    /// - Parameter lookup: Vector lookup per text, returning nil when the
    ///   text cannot be vectorized. Defaults to the live on-device English
    ///   sentence model; tests inject a stub.
    public init(lookup: (@Sendable (String) -> [Double]?)? = nil) {
        self.lookup = lookup ?? Self.liveLookup
        self.storage = Storage()
    }

    /// Embeds texts in order, one vector per input.
    ///
    /// Upholds the batch contract without changing arity: empty input
    /// returns empty output with no model round-trip, and any blank string
    /// (empty or whitespace-only) rejects the whole batch as `invalidInput`
    /// instead of being silently filtered, so callers can always zip inputs
    /// to outputs positionally. Callers filter blanks before this call.
    /// Blocking model work runs on a background queue via the shared
    /// store-I/O hop so awaiting from `MemoryEngine` never executes model
    /// inference synchronously on the actor executor.
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
        let lookup = self.lookup
        let storage = self.storage
        let vectors: [[Float]] = try await runStoreIO {
            var produced: [[Float]] = []
            produced.reserveCapacity(texts.count)
            for text in texts {
                guard let raw = lookup(text), !raw.isEmpty else {
                    throw EmbeddingsError.unavailable
                }
                produced.append(raw.map { Float($0) })
            }
            return produced
        }
        // The sentence model has a fixed width per install; learning it from
        // the first success keeps the backend honest without hardcoding a
        // constant that could drift across OS releases. Later widths are
        // intentionally ignored so the reported width stays stable.
        if let first = vectors.first {
            storage.note(width: first.count)
        }
        return vectors
    }

    /// Whether text holds no embeddable content.
    ///
    /// Whitespace-only strings carry no sentence meaning and would waste
    /// model time or return degenerate vectors, so they are treated as
    /// blanks alongside the empty string.
    /// - Parameter text: Candidate text.
    /// - Returns: True when trimmed text is empty.
    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Live lookup against the cached English sentence handle.
    private static let liveLookup: @Sendable (String) -> [Double]? = { text in
        liveVector(for: text)
    }

    /// Single vector from the on-device English sentence model.
    ///
    /// Returns nil — never crashes — when the framework is absent, the OS
    /// predates the model, the handle is missing, or the text has no
    /// sentence embedding (for example non-English input), letting the
    /// caller fall back to keyword recall. Lookups serialize on the shared
    /// handle lock because `NLEmbedding` documents no concurrent-use
    /// guarantee and vectors resolve off the caller via the shared
    /// concurrent store-I/O queue.
    /// - Parameter text: Text to vectorize.
    /// - Returns: Model vector, or nil when unavailable.
    private static func liveVector(for text: String) -> [Double]? {
        #if canImport(NaturalLanguage)
            if #available(macOS 14, *) {
                guard let handle = cachedEnglishHandle else { return nil }
                handleLock.lock()
                defer { handleLock.unlock() }
                return handle.vector(for: text)
            } else {
                return nil
            }
        #else
            return nil
        #endif
    }

    #if canImport(NaturalLanguage)
        /// Serializes concurrent `NLEmbedding.vector(for:)` lookups.
        ///
        /// The shared English handle is resolved once and never mutated, but
        /// the framework documents no thread-safety guarantee for concurrent
        /// vectors, and lookups run on the shared concurrent store-I/O queue.
        /// Every live lookup holds this lock so vectors never race.
        private static let handleLock = NSLock()

        /// Cached English sentence handle shared per process.
        ///
        /// Fetching the handle can load model data, so it is resolved once
        /// rather than per string. A nil handle means the model is absent on
        /// this machine; every lookup then maps to `unavailable`. The handle is
        /// initialized once and never mutated afterwards, and all reads run off
        /// the caller's executor through the shared store-I/O hop while holding
        /// the handle lock, so sharing it without actor isolation never observes
        /// shared mutable state and never blocks `MemoryEngine` mutations.
        @available(macOS 14, *)
        private nonisolated(unsafe) static let cachedEnglishHandle: NLEmbedding? = NLEmbedding.sentenceEmbedding(for: .english)
    #endif

    /// Thread-safe box for the learned embedding width.
    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private var cached: Int?

        /// Currently learned width, if any.
        var dimension: Int? {
            lock.lock()
            defer { lock.unlock() }
            return cached
        }

        /// Records the width from the first success, ignoring later widths.
        ///
        /// First-wins keeps `dimension` stable across calls even if a stub
        /// or future model ever varies widths mid-process.
        /// - Parameter width: Observed vector count.
        func note(width: Int) {
            lock.lock()
            defer { lock.unlock() }
            if cached == nil {
                cached = width
            }
        }
    }
}

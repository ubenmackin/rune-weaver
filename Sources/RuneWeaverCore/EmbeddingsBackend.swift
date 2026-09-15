// Rune Weaver Core — Pluggable vector-embedding seam for semantic memory.
// Defines the EmbeddingsBackend protocol and the EmbeddingsError taxonomy.
// Production code stays keyword-only via a nil backend from the factory;
// the disabled backend below exists for explicit injection and tests.
// This is the foundation every local and hosted embeddings provider builds on.

/// Failures raised by an ``EmbeddingsBackend``.
public enum EmbeddingsError: Error, Sendable, Equatable {
    /// No embeddings model is configured or reachable.
    ///
    /// Thrown by the disabled backend and by providers with no usable
    /// endpoint so callers keep today's keyword-only recall path.
    case unavailable
    /// An input batch was rejected before any embedding work.
    ///
    /// Reserved for malformed requests (for example, provider limits
    /// callers failed to enforce), distinct from per-text model
    /// failures reported as `embeddingFailed`.
    case invalidInput
    /// The model failed to embed an otherwise valid batch.
    ///
    /// Covers transport errors, server errors, and undecodable
    /// responses. Callers treat the whole batch as failed and
    /// isolate retries themselves to preserve output ordering.
    case embeddingFailed
}

/// Abstraction over a vector-embedding backend.
///
/// The seam everything embedding-dependent builds on: semantic-memory
/// writes, query encoding, and future local or hosted providers all
/// program against this protocol rather than concrete clients, so a
/// new model lands by adding a conformance without touching callers.
public protocol EmbeddingsBackend: Sendable {
    /// Stable model identifier (e.g. `"all-MiniLM-L6-v2"`, `"disabled"`).
    ///
    /// Surfaced in diagnostics and stored alongside vectors so mixed-model
    /// rows can be detected rather than silently compared.
    var modelID: String { get }

    /// Embedding width, or nil when unknown until the first output.
    ///
    /// Provider endpoints often advertise no width up front, so nil
    /// means "discover from the first result" rather than "variable
    /// width": once known, every vector from the backend shares it.
    var dimension: Int? { get async }

    /// Embeds a batch of texts.
    ///
    /// Returns one vector per input in the same order, so callers can
    /// zip inputs to outputs positionally. The batch contract keeps
    /// that guarantee cheap to uphold: empty input returns empty
    /// output without a model round-trip, blank strings are filtered
    /// by callers before this call (endpoints disagree on blank
    /// handling), and any per-text failure fails the whole batch
    /// (callers isolate with smaller or single-text batches).
    /// Callers isolating failures must still rethrow cancellation via
    /// `catch let error as CancellationError { throw error }` (bare
    /// `throw` is invalid Swift) so a cancelled task never degrades
    /// to keyword fallback.
    /// - Parameter texts: Texts to embed, in order.
    /// - Returns: One embedding vector per input text, in order.
    func embed(_ texts: [String]) async throws -> [[Float]]
}

public extension EmbeddingsBackend {
    /// Embeds one query best-effort, preserving cancellation.
    ///
    /// Single-sources the best-effort single-query pattern shared by recall
    /// and write paths: one `embed([text])` round-trip, first-vector
    /// selection with empty-output tolerance, and failure isolation that
    /// keeps keyword-only behavior on any model or transport failure.
    /// Only cancellation propagates so callers never mask a cancelled task
    /// as a keyword fallback.
    /// - Parameter text: Query or fact text to embed.
    /// - Returns: Query vector, or nil when unavailable or empty.
    /// - Throws: `CancellationError` when the enclosing task is cancelled.
    func embedQuery(_ text: String) async throws -> [Float]? {
        do {
            let vectors = try await embed([text])
            guard let vector = vectors.first, !vector.isEmpty else { return nil }
            return vector
        } catch let error as CancellationError {
            throw error
        } catch {
            return nil
        }
    }
}

/// Disabled backend preserving keyword-only recall by construction.
///
/// Explicit injection for tests and call sites that need a non-nil backend
/// without vectors: every non-empty batch throws
/// ``EmbeddingsError/unavailable``, so call sites keep today's
/// keyword-overlap behavior without optional backends. Production factory
/// paths use nil for `none`/unknown (keyword-only) rather than this type;
/// empty batches still return empty output per the batch contract, avoiding
/// a throw for a no-op call.
public struct DisabledEmbeddingsBackend: EmbeddingsBackend, Sendable {
    /// Stable identifier marking vectors as never-embedded.
    public let modelID: String
    /// Always nil: a disabled backend has no width to advertise.
    public let dimension: Int? = nil

    /// Creates a disabled backend.
    /// - Parameter modelID: Identifier reported in diagnostics.
    ///   Defaults to `"disabled"`.
    public init(modelID: String = "disabled") {
        self.modelID = modelID
    }

    /// Rejects non-empty batches as unavailable.
    ///
    /// The empty short-circuit honors the batch contract (no work, no
    /// model, no error) while every real request fails fast so callers
    /// fall back to keyword-only recall.
    /// - Parameter texts: Texts to embed, in order.
    /// - Returns: Empty output for empty input.
    /// - Throws: ``EmbeddingsError/unavailable`` for any non-empty batch.
    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        throw EmbeddingsError.unavailable
    }
}

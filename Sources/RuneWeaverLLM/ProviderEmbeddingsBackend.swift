// Rune Weaver LLM — Provider-backed embeddings adapter for semantic memory.
//
// Exposes the existing OpenAI-compatible `/v1/embeddings` path as an opt-in
// semantic-memory backend. The adapter wraps the shared `LLMRouter` so chat
// provider priority, health skipping, and error fallthrough stay single-sourced
// instead of being reimplemented for embeddings. The `provider` selection keeps
// vectors server-dictated (dimension unknown until the server answers), while
// `none` stays keyword-only and `apple` keeps vectors on-device by default.

import RuneWeaverCore

/// Embeddings backend that reuses the configured LLM providers.
///
/// The router already knows provider priority: it skips unreachable providers
/// and falls through to the next one when an embeddings request fails. This
/// adapter delegates verbatim so embeddings never drift from chat routing —
/// adding or reordering providers in config automatically applies here.
public struct ProviderEmbeddingsBackend: EmbeddingsBackend, Sendable {
    /// Router holding the priority-ordered providers.
    private let router: LLMRouter

    /// Stable identifier reported for display and diagnostics.
    public var modelID: String {
        "provider-embeddings"
    }

    /// Embedding width, unknown until the server answers.
    ///
    /// Server-dictated widths vary by model (and by endpoint), so fixing a
    /// width here would falsely reject valid responses. Callers that need a
    /// fixed width should read it from the first returned vector instead.
    public var dimension: Int? {
        nil
    }

    /// Creates an adapter around the shared router.
    /// - Parameter router: Priority-ordered providers serving embeddings.
    public init(router: LLMRouter) {
        self.router = router
    }

    /// Embeds texts via the router's fallthrough chain.
    ///
    /// Routing (priority order, availability skipping, per-provider fallthrough)
    /// lives in `LLMRouter` and is reused here rather than duplicated, so a
    /// failing first provider transparently yields to the next. Backend-level
    /// failures surface as `EmbeddingsError`: endpoint-absent conditions stay
    /// retryable as `unavailable`, while transport and decoding failures become
    /// `embeddingFailed` so callers can distinguish "no embeddings here" from
    /// "embeddings failed". Cancellation is rethrown untouched so a cancelled
    /// task never degrades to keyword fallback; remapping it to a backend
    /// failure would let callers swallow the cancellation. Empty input
    /// short-circuits to empty output per the batch contract without a model
    /// round-trip.
    /// - Parameter texts: Texts to embed, in order.
    /// - Returns: One vector per input text, in order.
    /// - Throws: `CancellationError` when the enclosing task is cancelled.
    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        do {
            return try await router.embeddings(text: texts)
        } catch let error as CancellationError {
            // Bound rethrow preserves the original cancellation error; the
            // mapping catches below would otherwise disguise it as a backend
            // failure callers treat as keyword-fallback material.
            throw error
        } catch let error as LLMProviderError {
            switch error {
            case .embeddingsUnsupported, .unavailable:
                // Missing endpoint and unreachable server both mean no vectors
                // are obtainable right now; callers fall back to keyword recall.
                throw EmbeddingsError.unavailable
            default:
                throw EmbeddingsError.embeddingFailed
            }
        } catch {
            throw EmbeddingsError.embeddingFailed
        }
    }
}

/// Selects the semantic-memory embeddings backend from config.
///
/// The configured `memory.embedding_backend` string is the single selector:
/// `none` disables vectors (keyword-only recall), `apple` keeps vectors
/// on-device, and `provider` reuses the LLM embeddings endpoint. The selector
/// spellings come from `MemoryConfig`'s named constants rather than local
/// literals so this factory, config validation, and the Settings API cannot
/// drift apart on what each selector means. Unknown values degrade to nil
/// (keyword-only) so a typo never crashes recall; config load validation still
/// rejects unknown values with a field error. Nil means keyword-only in
/// production; `DisabledEmbeddingsBackend` exists for explicit injection and
/// tests needing a non-nil backend without vectors.
public enum EmbeddingsBackendFactory: Sendable {
    /// Builds the backend for the configured selector.
    /// - Parameters:
    ///   - memoryEmbeddingBackend: Configured `memory.embedding_backend` value.
    ///   - router: Router serving the `provider` backend.
    /// - Returns: Backend for the selector, or nil for `none`/unknown (keyword-only).
    public static func makeBackend(
        memoryEmbeddingBackend: String,
        router: LLMRouter
    ) -> (any EmbeddingsBackend)? {
        switch memoryEmbeddingBackend {
        case MemoryConfig.embeddingBackendNone:
            nil
        case MemoryConfig.embeddingBackendApple:
            AppleNLEmbeddingsBackend()
        case MemoryConfig.embeddingBackendProvider:
            ProviderEmbeddingsBackend(router: router)
        default:
            nil
        }
    }
}

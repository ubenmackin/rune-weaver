// Rune Weaver LLM — Provider-backed embeddings adapter for semantic memory.

import RuneWeaverCore

/// Embeddings backend that reuses the configured LLM providers.
public struct ProviderEmbeddingsBackend: EmbeddingsBackend, Sendable {
    /// Router holding the priority-ordered providers.
    private let router: LLMRouter

    /// Stable identifier reported for display and diagnostics.
    public var modelID: String {
        "provider-embeddings"
    }

    /// Embedding width, unknown until the server answers.
    public var dimension: Int? {
        nil
    }

    /// Creates an adapter around the shared router.
    /// - Parameter router: Priority-ordered providers serving embeddings.
    public init(router: LLMRouter) {
        self.router = router
    }

    /// Embeds texts via the router's fallthrough chain.
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
public enum EmbeddingsBackendFactory: Sendable {
    /// Builds the backend for the configured selector.
    public static func makeBackend(
        memoryEmbeddingBackend: String,
        router: LLMRouter
    ) -> (any EmbeddingsBackend)? {
        switch memoryEmbeddingBackend {
        case MemoryConfig.embeddingBackendNone:
            nil
        case MemoryConfig.embeddingBackendLocal:
            LlamaCppEmbeddingsBackend(supervisor: LlamaEmbeddingSupervisor.shared)
        case MemoryConfig.embeddingBackendProvider:
            ProviderEmbeddingsBackend(router: router)
        default:
            nil
        }
    }

    /// Builds a per-slot backend factory for the files indexing pool.
    ///
    /// Each invocation mints one distinct backend from the same memory backend
    /// name so parallel embedding never serializes on the shared recall
    /// embedder; the shared instance stays out of the pool.
    /// - Parameters:
    ///   - memoryEmbeddingBackend: Configured `embedding_backend` selector.
    ///   - providers: Providers in priority order backing each minted backend.
    /// - Returns: Sendable factory minting one backend per files worker.
    public static func makePoolFactory(
        memoryEmbeddingBackend: String,
        providers: [any LLMProvider]
    ) -> (@Sendable () -> (any EmbeddingsBackend)?) {
        {
            makeBackend(
                memoryEmbeddingBackend: memoryEmbeddingBackend,
                router: LLMRouter(providers: providers)
            )
        }
    }
}

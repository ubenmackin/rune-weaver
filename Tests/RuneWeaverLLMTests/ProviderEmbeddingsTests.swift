// Provider-backed embeddings adapter tests.
//
// Covers the opt-in `provider` embeddings path that reuses the chat router's
// priority order and fallthrough: a failing first provider yields to the next,
// total failure surfaces as a backend error, and endpoint-absent conditions
// stay retryable as unavailable so callers can fall back to keyword recall.

import Foundation
@testable import RuneWeaverCore
@testable import RuneWeaverLLM
import Testing

/// Stub provider with scripted embeddings behavior and no network.
private struct StubEmbeddingsProvider: LLMProvider, Sendable {
    /// Router-visible provider name.
    let providerName: String
    /// Scripted embeddings outcome.
    let result: Result<[[Float]], LLMProviderError>

    /// Canned model metadata for the stub.
    var modelInfo: ModelInfo {
        ModelInfo(name: providerName, provider: providerName, contextLength: 4096)
    }

    /// Creates a stub.
    /// - Parameters:
    ///   - providerName: Router-visible name.
    ///   - result: Embeddings outcome to replay.
    init(_ providerName: String, result: Result<[[Float]], LLMProviderError>) {
        self.providerName = providerName
        self.result = result
    }

    /// Unused chat path; embeddings tests never drive chat.
    /// - Parameters:
    ///   - messages: Ignored history.
    ///   - tools: Ignored tools.
    /// - Returns: Immediately finished stream.
    func chat(messages _: [Message], tools _: [any Tool]) -> AsyncStream<LLMResponse> {
        AsyncStream { $0.finish() }
    }

    /// Replays the scripted embeddings outcome.
    /// - Parameter text: Ignored input texts.
    /// - Returns: Scripted vectors on success.
    func embeddings(text _: [String]) async throws -> [[Float]] {
        switch result {
        case let .success(vectors):
            return vectors
        case let .failure(error):
            throw error
        }
    }
}

/// Stub provider that always reports cancellation.
///
/// Models an in-flight cancellation surfacing through a provider so the router
/// and adapter cancellation carve-outs can be verified without a real task or
/// network call.
private struct CancellingEmbeddingsProvider: LLMProvider, Sendable {
    /// Router-visible provider name.
    let providerName: String

    /// Canned model metadata for the stub.
    var modelInfo: ModelInfo {
        ModelInfo(name: providerName, provider: providerName, contextLength: 4096)
    }

    /// Unused chat path; cancellation tests never drive chat.
    /// - Parameters:
    ///   - messages: Ignored history.
    ///   - tools: Ignored tools.
    /// - Returns: Immediately finished stream.
    func chat(messages _: [Message], tools _: [any Tool]) -> AsyncStream<LLMResponse> {
        AsyncStream { $0.finish() }
    }

    /// Always reports cancellation.
    /// - Parameter text: Ignored input texts.
    /// - Throws: `CancellationError` unconditionally.
    func embeddings(text _: [String]) async throws -> [[Float]] {
        throw CancellationError()
    }
}

@Suite("Provider Embeddings Backend")
struct ProviderEmbeddingsTests {
    @Test
    func `Falls through from failing first provider to succeeding second`() async throws {
        let failing = StubEmbeddingsProvider(
            "first",
            result: .failure(LLMProviderError.requestFailed(statusCode: 500, message: "boom"))
        )
        let succeeding = StubEmbeddingsProvider("second", result: .success([[1.0, 2.0]]))
        let router = LLMRouter(providers: [failing, succeeding])
        let backend = ProviderEmbeddingsBackend(router: router)

        let vectors = try await backend.embed(["hello"])
        #expect(vectors == [[1.0, 2.0]])
    }

    @Test
    func `All providers failing throws backend error`() async {
        let first = StubEmbeddingsProvider(
            "first",
            result: .failure(LLMProviderError.requestFailed(statusCode: 500, message: "boom"))
        )
        let second = StubEmbeddingsProvider(
            "second",
            result: .failure(LLMProviderError.requestFailed(statusCode: 503, message: "down"))
        )
        let router = LLMRouter(providers: [first, second])
        let backend = ProviderEmbeddingsBackend(router: router)

        do {
            _ = try await backend.embed(["hello"])
            Issue.record("Expected a backend error when every provider fails")
        } catch let error as EmbeddingsError {
            // Total failure must surface; the exact case stays an
            // implementation detail here so transport versus decoding
            // remapping can evolve without breaking fallthrough coverage.
            _ = error
        } catch {
            Issue.record("Expected EmbeddingsError, got \(type(of: error))")
        }
    }

    @Test
    func `Embeddings unsupported surfaces as unavailable`() async {
        let stub = StubEmbeddingsProvider(
            "first",
            result: .failure(LLMProviderError.embeddingsUnsupported("no endpoint"))
        )
        let router = LLMRouter(providers: [stub])
        let backend = ProviderEmbeddingsBackend(router: router)

        do {
            _ = try await backend.embed(["hello"])
            Issue.record("Expected unavailable when the endpoint is absent")
        } catch let error as EmbeddingsError {
            guard case .unavailable = error else {
                Issue.record("Expected .unavailable, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected EmbeddingsError, got \(type(of: error))")
        }
    }

    @Test
    func `Backend reports server-dictated identity`() {
        let router = LLMRouter()
        let backend = ProviderEmbeddingsBackend(router: router)
        #expect(backend.modelID == "provider-embeddings")
        // Width varies by server model, so the adapter leaves it unset
        // instead of constraining valid responses.
        #expect(backend.dimension == nil)
    }

    @Test
    func `Factory maps configured strings to backends`() {
        let router = LLMRouter()

        #expect(EmbeddingsBackendFactory.makeBackend(memoryEmbeddingBackend: "none", router: router) == nil)
        #expect(EmbeddingsBackendFactory.makeBackend(memoryEmbeddingBackend: "carrier-pigeon", router: router) == nil)

        let provider = EmbeddingsBackendFactory.makeBackend(memoryEmbeddingBackend: "provider", router: router)
        guard let provider, provider is ProviderEmbeddingsBackend else {
            Issue.record("Expected a ProviderEmbeddingsBackend for 'provider'")
            return
        }

        let apple = EmbeddingsBackendFactory.makeBackend(memoryEmbeddingBackend: "apple", router: router)
        guard let apple, apple is AppleNLEmbeddingsBackend else {
            Issue.record("Expected an AppleNLEmbeddingsBackend for 'apple'")
            return
        }
    }

    @Test
    func `Cancellation aborts instead of falling through or remapping`() async {
        let cancelling = CancellingEmbeddingsProvider(providerName: "first")
        let succeeding = StubEmbeddingsProvider("second", result: .success([[1.0, 2.0]]))
        let router = LLMRouter(providers: [cancelling, succeeding])
        let backend = ProviderEmbeddingsBackend(router: router)

        do {
            _ = try await backend.embed(["hello"])
            Issue.record("Expected cancellation to propagate through router and adapter")
        } catch let error as CancellationError {
            // Cancellation must abort rather than fall through to the next
            // provider or surface as a keyword-fallback EmbeddingsError.
            _ = error
        } catch {
            Issue.record("Expected CancellationError, got \(type(of: error))")
        }
    }
}

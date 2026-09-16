// Rune Weaver LLM — Local llama.cpp inference server provider adapter.

import Foundation
import RuneWeaverCore

/// Local provider for models served by a llama.cpp server.
public struct LlamaCppProvider: ChunkStreamingProvider, Sendable {
    /// Default local llama.cpp server URL.
    public static var defaultServerURL: String {
        "http://localhost:8081"
    }

    /// Default model label sent with requests.
    public static var defaultModel: String {
        "local-model"
    }

    /// Default context window in tokens.
    public static var defaultContextLength: Int {
        4096
    }

    /// Base server URL (with or without a `/v1` suffix).
    public let serverURL: String
    /// Model label sent with every request.
    public let model: String
    /// Maximum context window in tokens.
    public let contextLength: Int
    /// Whether the fronted model accepts vision input.
    public let supportsVision: Bool

    /// Stable provider identifier used by the router and config keys.
    public var name: String {
        "llamacpp"
    }

    /// Metadata for the active model.
    public var modelInfo: ModelInfo {
        ModelInfo(
            name: model,
            provider: "llamacpp",
            contextLength: contextLength,
            supportsTools: true,
            supportsEmbeddings: false,
            supportsVision: supportsVision
        )
    }

    /// Creates a llama.cpp provider.
    public init(
        serverURL: String = LlamaCppProvider.defaultServerURL,
        model: String = LlamaCppProvider.defaultModel,
        contextLength: Int = LlamaCppProvider.defaultContextLength,
        supportsVision: Bool = false
    ) {
        self.serverURL = serverURL
        self.model = model
        self.contextLength = contextLength
        self.supportsVision = supportsVision
    }

    /// Shared HTTP client for this provider.
    var client: OpenAICompatibleHTTPClient {
        OpenAICompatibleHTTPClient(baseURL: serverURL, model: model)
    }

    /// Whether the llama.cpp server answers `GET <base>/models` right now.
    /// - Returns: True when the server responds with 2xx.
    public func isAvailable() async -> Bool {
        await client.ping()
    }

    /// Streams chunk-level events from the llama.cpp server.
    public func chatChunks(messages: [Message], tools: [ToolDefinition]) -> AsyncStream<LLMResponseChunk> {
        client.streamChunks(messages: messages, tools: tools)
    }

    /// Embeds texts via the server's embeddings endpoint.
    public func embeddings(text: [String]) async throws -> [[Float]] {
        try await client.requestEmbeddings(texts: text)
    }
}

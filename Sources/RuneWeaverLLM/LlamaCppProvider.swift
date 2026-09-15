// Rune Weaver LLM — Local llama.cpp inference server provider adapter.
//
// Bridges llama.cpp OpenAI-compatible server instances (default port 8081)
// into the LLMProvider interface with streaming token and tool-call support.

import Foundation
import RuneWeaverCore

/// Local provider for models served by a llama.cpp server.
///
/// Connects to a llama.cpp server exposing an OpenAI-compatible API
/// (default `http://localhost:8081`). The llama.cpp server ignores
/// the `model` field, but one is still sent because the shared
/// OpenAI-compatible client requires it.
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
            supportsEmbeddings: false
        )
    }

    /// Creates a llama.cpp provider.
    /// - Parameters:
    ///   - serverURL: llama.cpp server URL. Defaults to `http://localhost:8081`.
    ///   - model: Model label. Defaults to `"local-model"`.
    ///   - contextLength: Context window. Defaults to 4096 tokens.
    public init(
        serverURL: String = LlamaCppProvider.defaultServerURL,
        model: String = LlamaCppProvider.defaultModel,
        contextLength: Int = LlamaCppProvider.defaultContextLength
    ) {
        self.serverURL = serverURL
        self.model = model
        self.contextLength = contextLength
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
    /// - Parameters:
    ///   - messages: Conversation history.
    ///   - tools: Tool definitions the model may call.
    /// - Returns: Stream ending in `done` or `error`.
    public func chatChunks(messages: [Message], tools: [ToolDefinition]) -> AsyncStream<LLMResponseChunk> {
        client.streamChunks(messages: messages, tools: tools)
    }

    /// Embeds texts via the server's embeddings endpoint.
    ///
    /// Older llama.cpp servers expose `/embedding` (singular) instead
    /// of the OpenAI-compatible `/v1/embeddings`; those servers surface
    /// ``LLMProviderError/embeddingsUnsupported(_:)``.
    /// - Parameter text: Texts to embed.
    /// - Returns: One embedding vector per input text.
    public func embeddings(text: [String]) async throws -> [[Float]] {
        try await client.requestEmbeddings(texts: text)
    }
}

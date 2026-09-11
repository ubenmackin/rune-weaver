import Foundation
import RuneWeaverCore

/// Local provider for Apple Silicon models served over MLX.
///
/// Connects to a local MLX server exposing an OpenAI-compatible API
/// (default `http://localhost:8080`). Text streams over
/// `/v1/chat/completions` as server-sent events; embeddings use
/// `/v1/embeddings` when the server enables them.
public struct MLXProvider: ChunkStreamingProvider, Sendable {
    /// Default local MLX server URL.
    public static var defaultServerURL: String {
        "http://localhost:8080"
    }

    /// Default model identifier served by the MLX server.
    public static var defaultModel: String {
        "gemma-4-9b"
    }

    /// Default context window in tokens.
    public static var defaultContextLength: Int {
        8192
    }

    /// Base server URL (with or without a `/v1` suffix).
    public let serverURL: String
    /// Model identifier sent with every request.
    public let model: String
    /// Maximum context window in tokens.
    public let contextLength: Int

    /// Stable provider identifier used by the router and config keys.
    public var name: String {
        "mlx"
    }

    /// Metadata for the active model.
    public var modelInfo: ModelInfo {
        ModelInfo(
            name: model,
            provider: "mlx",
            contextLength: contextLength,
            supportsTools: true,
            supportsEmbeddings: false
        )
    }

    /// Creates an MLX provider.
    /// - Parameters:
    ///   - serverURL: MLX server URL. Defaults to `http://localhost:8080`.
    ///   - model: Model identifier. Defaults to `"gemma-4-9b"`.
    ///   - contextLength: Context window. Defaults to 8192 tokens.
    public init(
        serverURL: String = MLXProvider.defaultServerURL,
        model: String = MLXProvider.defaultModel,
        contextLength: Int = MLXProvider.defaultContextLength
    ) {
        self.serverURL = serverURL
        self.model = model
        self.contextLength = contextLength
    }

    /// Shared HTTP client for this provider.
    var client: OpenAICompatibleHTTPClient {
        OpenAICompatibleHTTPClient(baseURL: serverURL, model: model)
    }

    /// Whether the MLX server answers `GET <base>/models` right now.
    /// - Returns: True when the server responds with 2xx.
    public func isAvailable() async -> Bool {
        await client.ping()
    }

    /// Streams chunk-level events from the MLX server.
    /// - Parameters:
    ///   - messages: Conversation history.
    ///   - tools: Tool definitions the model may call.
    /// - Returns: Stream ending in `done` or `error`.
    public func chatChunks(messages: [Message], tools: [ToolDefinition]) -> AsyncStream<LLMResponseChunk> {
        client.streamChunks(messages: messages, tools: tools)
    }

    /// Embeds texts via the MLX server's embeddings endpoint.
    ///
    /// Many MLX chat servers leave embeddings disabled; the thrown
    /// ``LLMProviderError`` distinguishes an unreachable server from a
    /// missing endpoint.
    /// - Parameter text: Texts to embed.
    /// - Returns: One embedding vector per input text.
    public func embeddings(text: [String]) async throws -> [[Float]] {
        try await client.requestEmbeddings(texts: text)
    }
}

// Rune Weaver LLM — Apple Silicon MLX local inference provider adapter.

import Foundation
import RuneWeaverCore

/// Local provider for Apple Silicon models served over MLX.
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
    /// Whether the fronted model accepts vision input.
    public let supportsVision: Bool

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
            supportsEmbeddings: false,
            supportsVision: supportsVision
        )
    }

    /// Creates an MLX provider.
    public init(
        serverURL: String = MLXProvider.defaultServerURL,
        model: String = MLXProvider.defaultModel,
        contextLength: Int = MLXProvider.defaultContextLength,
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

    /// Whether the MLX server answers `GET <base>/models` right now.
    /// - Returns: True when the server responds with 2xx.
    public func isAvailable() async -> Bool {
        await client.ping()
    }

    /// Streams chunk-level events from the MLX server.
    public func chatChunks(messages: [Message], tools: [ToolDefinition]) -> AsyncStream<LLMResponseChunk> {
        client.streamChunks(messages: messages, tools: tools)
    }

    /// Streams chunk-level events for one chat session.
    public func chatChunks(messages: [Message], tools: [ToolDefinition], sessionID: String?) -> AsyncStream<LLMResponseChunk> {
        let perTurn = OpenAICompatibleHTTPClient(
            baseURL: serverURL,
            model: model,
            sessionID: sessionID
        )
        return perTurn.streamChunks(messages: messages, tools: tools)
    }

    /// Streams chunk-level events for one chat session UUID.
    public func chatChunks(messages: [Message], tools: [ToolDefinition], session: UUID?) -> AsyncStream<LLMResponseChunk> {
        chatChunks(messages: messages, tools: tools, sessionID: session?.uuidString)
    }

    /// Embeds texts via the MLX server's embeddings endpoint.
    public func embeddings(text: [String]) async throws -> [[Float]] {
        try await client.requestEmbeddings(texts: text)
    }
}

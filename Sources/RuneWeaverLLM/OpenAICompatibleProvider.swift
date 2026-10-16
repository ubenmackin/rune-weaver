// Rune Weaver LLM — Generic OpenAI-compatible API endpoint provider.

import Foundation
import RuneWeaverCore

/// Generic provider for any OpenAI-compatible endpoint.
public struct OpenAICompatibleProvider: ChunkStreamingProvider, Sendable {
    /// Default base URL (OpenRouter).
    public static var defaultBaseURL: String {
        "https://openrouter.ai/api/v1"
    }

    /// Default model identifier.
    public static var defaultModel: String {
        "gpt-4o-mini"
    }

    /// Default context window in tokens.
    public static var defaultContextLength: Int {
        128_000
    }

    /// API root (with or without a `/v1` suffix).
    public let baseURL: String
    /// Bearer token, if the endpoint requires auth.
    public let apiKey: String?
    /// Model identifier sent with every request.
    public let model: String
    /// Maximum context window in tokens.
    public let contextLength: Int
    /// Provider identifier used by the router and config keys.
    public let providerID: String
    /// Whether this endpoint serves embeddings.
    public let embeddingsEnabled: Bool
    /// Request style selecting the wire endpoint and SSE shape.
    public let apiStyle: APIStyle
    /// Chat session identifier sent as `x-opencode-session`, when set.
    public var sessionID: String?
    /// Whether the model accepts vision input (screenshots, images).
    public let supportsVision: Bool

    /// Stable provider identifier used by the router and config keys.
    public var name: String {
        providerID
    }

    /// Metadata for the active model.
    public var modelInfo: ModelInfo {
        ModelInfo(
            name: model,
            provider: providerID,
            contextLength: contextLength,
            supportsTools: true,
            supportsEmbeddings: embeddingsEnabled,
            supportsVision: supportsVision
        )
    }

    /// Creates a generic OpenAI-compatible provider.
    public init(
        baseURL: String = OpenAICompatibleProvider.defaultBaseURL,
        apiKey: String? = nil,
        model: String = OpenAICompatibleProvider.defaultModel,
        contextLength: Int = OpenAICompatibleProvider.defaultContextLength,
        providerID: String = "openrouter",
        embeddingsEnabled: Bool = true,
        apiStyle: APIStyle = .chatCompletions,
        sessionID: String? = nil,
        supportsVision: Bool = true
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.contextLength = contextLength
        self.providerID = providerID
        self.embeddingsEnabled = embeddingsEnabled
        self.apiStyle = apiStyle
        self.sessionID = sessionID
        self.supportsVision = supportsVision
    }

    /// Shared HTTP client for this provider.
    var client: OpenAICompatibleHTTPClient {
        OpenAICompatibleHTTPClient(baseURL: baseURL, apiKey: apiKey, model: model, apiStyle: apiStyle, sessionID: sessionID)
    }

    /// Whether the endpoint answers `GET <base>/models` right now.
    /// - Returns: True when the endpoint responds with 2xx.
    public func isAvailable() async -> Bool {
        await client.ping()
    }

    /// Streams chunk-level events from the endpoint.
    public func chatChunks(messages: [Message], tools: [ToolDefinition]) -> AsyncStream<LLMResponseChunk> {
        client.streamChunks(messages: messages, tools: tools)
    }

    /// Streams chunk-level events for one chat session.
    public func chatChunks(messages: [Message], tools: [ToolDefinition], sessionID: String?) -> AsyncStream<LLMResponseChunk> {
        let resolved: String? = if let sessionID, !sessionID.isEmpty {
            sessionID
        } else {
            self.sessionID
        }
        let perTurn = OpenAICompatibleHTTPClient(
            baseURL: baseURL,
            apiKey: apiKey,
            model: model,
            apiStyle: apiStyle,
            sessionID: resolved
        )
        return perTurn.streamChunks(messages: messages, tools: tools)
    }

    /// Streams chunk-level events for one chat session UUID.
    /// Normalizes to the string form so header hashing sees one shape.
    public func chatChunks(messages: [Message], tools: [ToolDefinition], session: UUID?) -> AsyncStream<LLMResponseChunk> {
        chatChunks(messages: messages, tools: tools, sessionID: session?.uuidString)
    }

    /// Embeds texts via the endpoint's embeddings API.
    /// - Parameter text: Texts to embed.
    /// - Returns: One embedding vector per input text.
    public func embeddings(text: [String]) async throws -> [[Float]] {
        try await client.requestEmbeddings(texts: text)
    }
}

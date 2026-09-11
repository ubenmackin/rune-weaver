import Foundation
import RuneWeaverCore

/// Generic provider for any OpenAI-compatible endpoint.
///
/// Covers cloud hosts (OpenRouter, OpenAI, custom gateways) and any
/// self-hosted OpenAI-compatible server. The base URL and API key are
/// fully configurable; the key is held in memory only and never
/// logged. Resolve it via `SecretsManager` (env first, Keychain
/// fallback) before constructing this provider.
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
            supportsEmbeddings: embeddingsEnabled
        )
    }

    /// Creates a generic OpenAI-compatible provider.
    /// - Parameters:
    ///   - baseURL: API root. Defaults to OpenRouter.
    ///   - apiKey: Bearer token, if required. Never logged or persisted.
    ///   - model: Model identifier.
    ///   - contextLength: Context window. Defaults to 128k tokens.
    ///   - providerID: Router identifier. Defaults to `"openrouter"`.
    ///   - embeddingsEnabled: Whether to advertise embeddings support.
    public init(
        baseURL: String = OpenAICompatibleProvider.defaultBaseURL,
        apiKey: String? = nil,
        model: String = OpenAICompatibleProvider.defaultModel,
        contextLength: Int = OpenAICompatibleProvider.defaultContextLength,
        providerID: String = "openrouter",
        embeddingsEnabled: Bool = true
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.contextLength = contextLength
        self.providerID = providerID
        self.embeddingsEnabled = embeddingsEnabled
    }

    /// Shared HTTP client for this provider.
    var client: OpenAICompatibleHTTPClient {
        OpenAICompatibleHTTPClient(baseURL: baseURL, apiKey: apiKey, model: model)
    }

    /// Whether the endpoint answers `GET <base>/models` right now.
    /// - Returns: True when the endpoint responds with 2xx.
    public func isAvailable() async -> Bool {
        await client.ping()
    }

    /// Streams chunk-level events from the endpoint.
    /// - Parameters:
    ///   - messages: Conversation history.
    ///   - tools: Tool definitions the model may call.
    /// - Returns: Stream ending in `done` or `error`.
    public func chatChunks(messages: [Message], tools: [ToolDefinition]) -> AsyncStream<LLMResponseChunk> {
        client.streamChunks(messages: messages, tools: tools)
    }

    /// Embeds texts via the endpoint's embeddings API.
    /// - Parameter text: Texts to embed.
    /// - Returns: One embedding vector per input text.
    public func embeddings(text: [String]) async throws -> [[Float]] {
        try await client.requestEmbeddings(texts: text)
    }
}

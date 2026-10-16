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
    /// Slot pool size used to derive the sticky `id_slot` for a chat session.
    public let slotCount: Int?
    /// Prefix-cache hint sent as `cache_prompt`; nil omits the key.
    public let cachePrompt: Bool?

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

    /// Creates a llama.cpp provider. Stays session-agnostic on purpose: one provider value serves
    /// many concurrent chats, so a stored session would pin every turn to one slot.
    public init(
        serverURL: String = LlamaCppProvider.defaultServerURL,
        model: String = LlamaCppProvider.defaultModel,
        contextLength: Int = LlamaCppProvider.defaultContextLength,
        supportsVision: Bool = false,
        slotCount: Int? = nil,
        cachePrompt: Bool? = LlamaPrefixReuse.effectiveCachePromptWhenUnset
    ) {
        self.serverURL = serverURL
        self.model = model
        self.contextLength = contextLength
        self.supportsVision = supportsVision
        self.slotCount = slotCount
        self.cachePrompt = cachePrompt
    }

    /// Shared HTTP client for this provider. Sends only the `cache_prompt` prefix hint so the
    /// server may reuse the cached system prompt and tool prefix across rounds; the slot stays unset
    /// so the server auto-assigns.
    var client: OpenAICompatibleHTTPClient {
        OpenAICompatibleHTTPClient(
            baseURL: serverURL,
            model: model,
            cachePrompt: cachePrompt,
            slotID: nil
        )
    }

    /// Whether the llama.cpp server answers `GET <base>/models` right now.
    /// - Returns: True when the server responds with 2xx.
    public func isAvailable() async -> Bool {
        await client.ping()
    }

    /// Streams chunk-level events from the llama.cpp server. Session-agnostic path used when the
    /// caller holds no chat identifier; leaves slot assignment to the server.
    public func chatChunks(messages: [Message], tools: [ToolDefinition]) -> AsyncStream<LLMResponseChunk> {
        client.streamChunks(messages: messages, tools: tools)
    }

    /// Streams chunk-level events for one chat session. Builds a per-turn client so the sticky
    /// `id_slot` follows the turn's session instead of a shared stored value.
    public func chatChunks(messages: [Message], tools: [ToolDefinition], sessionID: String?) -> AsyncStream<LLMResponseChunk> {
        let perTurn = OpenAICompatibleHTTPClient(
            baseURL: serverURL,
            model: model,
            sessionID: sessionID,
            cachePrompt: cachePrompt,
            slotID: resolvedSlotID(for: sessionID)
        )
        return perTurn.streamChunks(messages: messages, tools: tools)
    }

    /// Streams chunk-level events for one chat session UUID.
    /// Same per-turn pinning as above for callers holding the chat identifier directly.
    public func chatChunks(messages: [Message], tools: [ToolDefinition], session: UUID?) -> AsyncStream<LLMResponseChunk> {
        chatChunks(messages: messages, tools: tools, sessionID: session?.uuidString)
    }

    /// Resolves the sticky slot for one chat session under the configured pool.
    /// Nil when no pool is configured or the session is absent so the server
    /// auto-assigns instead of risking an out-of-range rejection.
    func resolvedSlotID(for sessionID: String?) -> Int? {
        guard let slotCount, slotCount > 0 else { return nil }
        return LlamaCppSlot.slotID(forSessionID: sessionID, slotCount: slotCount)
    }

    /// Embeds texts via the server's embeddings endpoint.
    public func embeddings(text: [String]) async throws -> [[Float]] {
        try await client.requestEmbeddings(texts: text)
    }
}

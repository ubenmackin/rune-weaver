/// Describes a model behind an ``LLMProvider``.
public struct ModelInfo: Sendable, Codable, Equatable {
    /// Display name of the model (e.g. `"gemma-4-9b"`).
    public let name: String
    /// Provider identifier (e.g. `"mlx"`, `"openrouter"`).
    public let provider: String
    /// Maximum context window in tokens.
    public let contextLength: Int
    /// Whether the model supports function/tool calling.
    public let supportsTools: Bool
    /// Whether the provider can serve embeddings.
    public let supportsEmbeddings: Bool

    /// Creates model metadata.
    /// - Parameters:
    ///   - name: Display name of the model.
    ///   - provider: Provider identifier.
    ///   - contextLength: Maximum context window in tokens.
    ///   - supportsTools: Whether tool calling is supported.
    ///   - supportsEmbeddings: Whether embeddings are supported.
    public init(
        name: String,
        provider: String,
        contextLength: Int,
        supportsTools: Bool = true,
        supportsEmbeddings: Bool = false
    ) {
        self.name = name
        self.provider = provider
        self.contextLength = contextLength
        self.supportsTools = supportsTools
        self.supportsEmbeddings = supportsEmbeddings
    }
}

/// A single streamed chunk of an LLM chat response.
public struct LLMResponse: Sendable, Equatable {
    /// Incremental text for this chunk.
    public let delta: String
    /// Whether this chunk ends the response.
    public let isFinished: Bool
    /// Failure detail when the stream terminated with an error. Nil on success.
    public let errorMessage: String?

    /// Creates a response chunk.
    /// - Parameters:
    ///   - delta: Incremental text.
    ///   - isFinished: Whether the response is complete.
    ///   - errorMessage: Failure detail, if the stream failed. Defaults to nil.
    public init(delta: String, isFinished: Bool = false, errorMessage: String? = nil) {
        self.delta = delta
        self.isFinished = isFinished
        self.errorMessage = errorMessage
    }

    /// Whether this chunk reports a stream failure.
    public var isError: Bool {
        errorMessage != nil
    }
}

/// Abstraction over an LLM backend.
///
/// The router holds a priority-ordered list of providers and falls
/// through on failure. Implementations cover local backends
/// (MLX, llama.cpp, vLLM) and cloud APIs (OpenAI-compatible,
/// Anthropic, custom endpoints).
public protocol LLMProvider: Sendable {
    /// Metadata for the active model.
    var modelInfo: ModelInfo { get }

    /// Streams a chat completion for the given history and tools.
    /// - Parameters:
    ///   - messages: Conversation history.
    ///   - tools: Tools the model may call.
    /// - Returns: Stream of response chunks.
    func chat(messages: [Message], tools: [any Tool]) -> AsyncStream<LLMResponse>

    /// Embeds texts for semantic-memory indexing and retrieval.
    /// - Parameter text: Texts to embed.
    /// - Returns: One embedding vector per input text.
    func embeddings(text: [String]) async throws -> [[Float]]
}

import RuneWeaverCore

/// Selects the active LLM provider and falls through on failure.
///
/// The router maintains a priority-ordered list of providers
/// (local-first, cloud fallback) configured via `config.toml` or
/// the dashboard. Concrete providers (MLX, llama.cpp, vLLM,
/// OpenAI-compatible, Anthropic, custom) conform to
/// ``LLMProvider`` and register here in priority order.
public actor LLMRouter {
    /// Providers in priority order.
    public let providers: [any LLMProvider]

    /// Creates a router with the given provider priority.
    /// - Parameter providers: Providers in priority order.
    public init(providers: [any LLMProvider] = []) {
        self.providers = providers
    }

    /// Streams a chat completion via the first healthy provider.
    ///
    /// Providers are tried in priority order: unreachable providers
    /// (failing `isAvailable()`) are skipped, and a provider whose
    /// chunk stream reports `.error` before yielding any text falls
    /// through to the next provider. Once a provider has streamed
    /// text, its turn is kept and the stream terminates normally. An
    /// empty provider list (or no healthy provider) terminates the
    /// stream immediately so `for await` consumers never hang.
    /// - Parameters:
    ///   - messages: Conversation history.
    ///   - tools: Tools the model may call.
    /// - Returns: Stream of response chunks.
    public func chat(messages: [Message], tools: [any Tool]) -> AsyncStream<LLMResponse> {
        let providers = self.providers
        return AsyncStream { continuation in
            let task = Task {
                for provider in providers {
                    if Task.isCancelled {
                        break
                    }
                    guard await provider.isAvailable() else { continue }
                    if let chunked = provider as? any ChunkStreamingProvider {
                        let definitions = chunked.toolDefinitions(for: tools)
                        var yieldedText = false
                        var failed = false
                        chunkLoop: for await chunk in chunked.chatChunks(messages: messages, tools: definitions) {
                            if Task.isCancelled {
                                break
                            }
                            switch chunk {
                            case let .textDelta(text):
                                yieldedText = true
                                continuation.yield(LLMResponse(delta: text))
                            case .toolCall:
                                continue
                            case .done:
                                break chunkLoop
                            case .error:
                                failed = true
                                break chunkLoop
                            }
                        }
                        if failed, !yieldedText {
                            continue
                        }
                        if !Task.isCancelled {
                            continuation.yield(LLMResponse(delta: "", isFinished: true))
                        }
                        break
                    } else {
                        for await part in provider.chat(messages: messages, tools: tools) {
                            if Task.isCancelled {
                                break
                            }
                            continuation.yield(part)
                            if part.isFinished {
                                break
                            }
                        }
                        break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// Embeds texts via the first healthy provider, falling through on failure.
    ///
    /// Providers are tried in priority order, skipping unreachable ones;
    /// per-provider errors fall through to the next provider. Throws the
    /// last provider error when every provider fails, or an
    /// `unavailable` error when no provider can serve the request.
    /// - Parameter text: Texts to embed.
    /// - Returns: One embedding vector per input text.
    public func embeddings(text: [String]) async throws -> [[Float]] {
        var lastError: (any Error)?
        for provider in providers {
            guard await provider.isAvailable() else { continue }
            do {
                return try await provider.embeddings(text: text)
            } catch {
                lastError = error
                continue
            }
        }
        if let lastError {
            throw lastError
        }
        throw LLMProviderError.unavailable("No embedding providers are available")
    }
}

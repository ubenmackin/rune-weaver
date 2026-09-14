import RuneWeaverCore

/// Selects the active LLM provider and falls through on failure.
///
/// The router maintains a priority-ordered list of providers
/// (local-first, cloud fallback) configured via `config.toml` or
/// the dashboard. Concrete providers (MLX, llama.cpp, vLLM,
/// OpenAI-compatible, Anthropic, custom) conform to
/// ``LLMProvider`` and register here in priority order.
public actor LLMRouter {
    /// Outcome of draining one chunk-streaming provider.
    ///
    /// Replaces a three-member tuple so `drainChunkedProvider` stays within
    /// the `large_tuple` lint budget while preserving error propagation.
    private struct ChunkedDrainResult: Sendable {
        /// Whether the turn finished and the stream should terminate.
        let didFinish: Bool
        /// Last failure message, if any.
        let lastError: String?
        /// Whether the caller should try the next provider.
        let shouldContinue: Bool
    }

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
    /// through to the next provider. A mid-stream `.error` after text
    /// was already yielded terminates with an `isError` response so
    /// callers never mistake a truncated turn for success. When every
    /// provider fails before yielding text, the stream terminates with
    /// the last failure. An empty provider list terminates the stream
    /// immediately so `for await` consumers never hang.
    /// - Parameters:
    ///   - messages: Conversation history.
    ///   - tools: Tools the model may call.
    /// - Returns: Stream of response chunks.
    public func chat(messages: [Message], tools: [any Tool]) -> AsyncStream<LLMResponse> {
        let providers = self.providers
        return AsyncStream { continuation in
            let task = Task {
                var lastError: String?
                var didFinish = false
                for provider in providers {
                    if Task.isCancelled {
                        break
                    }
                    guard await provider.isAvailable() else { continue }
                    if let chunked = provider as? any ChunkStreamingProvider {
                        let definitions = chunked.toolDefinitions(for: tools)
                        let step = await Self.drainChunkedProvider(
                            chunked,
                            messages: messages,
                            tools: definitions,
                            continuation: continuation
                        )
                        if let message = step.lastError {
                            lastError = message
                        }
                        if step.shouldContinue {
                            continue
                        }
                        didFinish = step.didFinish
                        break
                    }
                    let step = await Self.drainStandardProvider(
                        provider,
                        messages: messages,
                        tools: tools,
                        continuation: continuation
                    )
                    if let message = step.lastError {
                        lastError = message
                    }
                    didFinish = step.didFinish
                    break
                }
                if !didFinish, let lastError, !Task.isCancelled {
                    continuation.yield(LLMResponse(delta: "", isFinished: true, errorMessage: lastError))
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// Drains one chunk-streaming provider, preserving mid-stream error propagation.
    ///
    /// Yields text deltas verbatim and ignores tool calls. A `.error`
    /// before any text returns `shouldContinue` so the caller falls
    /// through to the next provider; a `.error` after text was yielded
    /// emits an `isError` response so callers never mistake a truncated
    /// turn for success. Empty error messages become `"unknown error"`.
    /// - Parameters:
    ///   - provider: Chunk-streaming provider to drain.
    ///   - messages: Conversation history.
    ///   - tools: Tool definitions the model may call.
    ///   - continuation: Stream receiving text and terminal chunks.
    /// - Returns: Outcome describing whether the turn finished, the last
    ///   failure, and whether the caller should try the next provider.
    private static func drainChunkedProvider(
        _ provider: any ChunkStreamingProvider,
        messages: [Message],
        tools: [ToolDefinition],
        continuation: AsyncStream<LLMResponse>.Continuation
    ) async -> ChunkedDrainResult {
        var yieldedText = false
        var failureMessage: String?
        var lastUsage: Int?
        chunkLoop: for await chunk in provider.chatChunks(messages: messages, tools: tools) {
            if Task.isCancelled {
                break
            }
            switch chunk {
            case let .textDelta(text):
                yieldedText = yieldedText || !text.isEmpty
                continuation.yield(LLMResponse(delta: text))
            case let .toolCall(call):
                yieldedText = true
                let input = ToolInput(toolName: call.name, argumentsJSON: call.argumentsJSON, callID: call.id)
                continuation.yield(LLMResponse(delta: "", toolCalls: [input]))
            case let .done(meta):
                lastUsage = meta.usage?.totalTokens
                break chunkLoop
            case let .error(message):
                failureMessage = message.isEmpty ? "unknown error" : message
                break chunkLoop
            }
        }
        if let failureMessage {
            if !yieldedText {
                return ChunkedDrainResult(didFinish: false, lastError: failureMessage, shouldContinue: true)
            }
            if !Task.isCancelled {
                continuation.yield(LLMResponse(delta: "", isFinished: true, errorMessage: failureMessage))
                return ChunkedDrainResult(didFinish: true, lastError: failureMessage, shouldContinue: false)
            }
            return ChunkedDrainResult(didFinish: false, lastError: failureMessage, shouldContinue: false)
        }
        if !Task.isCancelled {
            continuation.yield(LLMResponse(delta: "", isFinished: true, totalTokens: lastUsage))
            return ChunkedDrainResult(didFinish: true, lastError: nil, shouldContinue: false)
        }
        return ChunkedDrainResult(didFinish: false, lastError: nil, shouldContinue: false)
    }

    /// Drains one text-streaming provider, preserving error propagation.
    ///
    /// Yields each `LLMResponse` verbatim including `isError` parts so
    /// failures cannot leak into history as success. The stream always
    /// terminates after the first available provider; only cancellation
    /// leaves `didFinish` false without a failure.
    /// - Parameters:
    ///   - provider: Text-streaming provider to drain.
    ///   - messages: Conversation history.
    ///   - tools: Tools the model may call.
    ///   - continuation: Stream receiving response parts.
    /// - Returns: Whether the turn finished and the last failure, if any.
    private static func drainStandardProvider(
        _ provider: any LLMProvider,
        messages: [Message],
        tools: [any Tool],
        continuation: AsyncStream<LLMResponse>.Continuation
    ) async -> (didFinish: Bool, lastError: String?) {
        var failureMessage: String?
        for await part in provider.chat(messages: messages, tools: tools) {
            if Task.isCancelled {
                break
            }
            if part.isError {
                failureMessage = part.errorMessage ?? "unknown error"
                continuation.yield(part)
                break
            }
            continuation.yield(part)
            if part.isFinished {
                break
            }
        }
        if let failureMessage {
            return (true, failureMessage)
        }
        if Task.isCancelled {
            return (false, nil)
        }
        return (true, nil)
    }

    /// Embeds texts via the first healthy provider, falling through on failure.
    ///
    /// Providers are tried in priority order, skipping unreachable ones;
    /// per-provider errors fall through to the next provider. Cancellation is
    /// never treated as a provider failure: a cancelled task aborts before the
    /// next provider is consulted instead of silently trying another endpoint.
    /// Throws the last provider error when every provider fails, or an
    /// `unavailable` error when no provider can serve the request.
    /// - Parameter text: Texts to embed.
    /// - Returns: One embedding vector per input text.
    /// - Throws: `CancellationError` when the enclosing task is cancelled.
    public func embeddings(text: [String]) async throws -> [[Float]] {
        var lastError: (any Error)?
        for provider in providers {
            if Task.isCancelled {
                // Abort before consulting a fallback provider so cancellation
                // never masquerades as provider exhaustion.
                throw CancellationError()
            }
            guard await provider.isAvailable() else { continue }
            do {
                return try await provider.embeddings(text: text)
            } catch let error as CancellationError {
                // Bound rethrow preserves the original cancellation error
                // instead of recording it for fallthrough.
                throw error
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

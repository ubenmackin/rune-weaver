// Rune Weaver LLM — Priority-ordered provider router and failover orchestrator.

import Foundation
import RuneWeaverCore

/// Selects the active LLM provider and falls through on failure.
public actor LLMRouter {
    /// Outcome of draining one chunk-streaming provider.
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
    /// Circuit breaker guarding against repeated calls to failing or rate-limited providers.
    public let circuitBreaker: ProviderCircuitBreaker

    /// Creates a router with the given provider priority and optional circuit breaker.
    /// - Parameter providers: Providers in priority order.
    /// - Parameter circuitBreaker: Circuit breaker tracking provider outages and cooldowns.
    public init(providers: [any LLMProvider] = [], circuitBreaker: ProviderCircuitBreaker? = nil) {
        self.providers = providers
        self.circuitBreaker = circuitBreaker ?? ProviderCircuitBreaker()
    }

    /// Whether the priority provider accepts vision input.
    public func activeSupportsVision() -> Bool {
        providers.first?.modelInfo.supportsVision ?? false
    }

    /// Whether any registered provider accepts vision input.
    /// - Returns: True when at least one provider is vision-capable.
    public func anySupportsVision() -> Bool {
        providers.contains { $0.modelInfo.supportsVision }
    }

    /// History safe for one provider's capability.
    public static func strippedMessages(_ messages: [Message], for provider: any LLMProvider) -> [Message] {
        VisionGate.stripMessages(messages, supportsVision: provider.modelInfo.supportsVision)
    }

    /// Tool definitions safe for one provider's capability.
    public static func visionFilteredDefinitions(_ tools: [ToolDefinition], supportsVision: Bool) -> [ToolDefinition] {
        // Silent prefilter and re-validation keep one wire log site per turn: the request body
        // builders log each skip, so router filtering stays quiet to avoid 2x per invalid tool.
        let prefiltered = validatedDefinitions(tools, logSkips: false)
        guard !supportsVision else { return prefiltered.valid }
        let stripped = prefiltered.valid.map { definition in
            guard definition.name == BrowserScreenshotPolicy.navigateToolName else { return definition }
            let strippedSchema = VisionSchemaFilter.strippedNavigateSchema(definition.parameters)
            return ToolDefinition(name: definition.name, description: definition.description, parameters: strippedSchema)
        }
        // Re-validate after the vision transform in case stripping produced an invalid shape.
        return validatedDefinitions(stripped, logSkips: false).valid
    }

    /// Streams a chat completion via the first healthy provider.
    /// Carries the chat identifier to session-aware chunk providers so sticky
    /// slots follow the turn; nil preserves the session-agnostic path.
    public func chat(messages: [Message], tools: [any Tool], sessionID: String? = nil) -> AsyncStream<LLMResponse> {
        let providers = self.providers
        let circuitBreaker = self.circuitBreaker
        return AsyncStream { continuation in
            let task = Task {
                var lastError: String?
                var didFinish = false
                for provider in providers {
                    if Task.isCancelled {
                        break
                    }
                    guard await circuitBreaker.isAvailable(provider: provider) else {
                        continue
                    }
                    guard await provider.isAvailable() else { continue }
                    // Per-provider vision gate: text-only backends never see
                    // image bytes even when an earlier turn captured them for
                    // a vision-capable fallback on the same priority list.
                    let outboundMessages = Self.strippedMessages(messages, for: provider)
                    let supportsVision = provider.modelInfo.supportsVision
                    if let chunked = provider as? any ChunkStreamingProvider {
                        let base = chunked.toolDefinitions(for: tools)
                        let definitions = Self.visionFilteredDefinitions(base, supportsVision: supportsVision)
                        let step = await Self.drainChunkedProvider(
                            chunked,
                            messages: outboundMessages,
                            tools: definitions,
                            sessionID: sessionID,
                            continuation: continuation
                        )
                        if let message = step.lastError {
                            lastError = message
                            await circuitBreaker.recordFailure(provider: provider, error: message)
                        } else if step.didFinish {
                            await circuitBreaker.recordSuccess(provider: provider)
                        }
                        if step.shouldContinue {
                            continue
                        }
                        didFinish = step.didFinish
                        break
                    }
                    let step = await Self.drainStandardProvider(
                        provider,
                        messages: outboundMessages,
                        tools: Self.visionGatedTools(tools, supportsVision: supportsVision),
                        sessionID: sessionID,
                        continuation: continuation
                    )
                    if let message = step.lastError {
                        lastError = message
                        await circuitBreaker.recordFailure(provider: provider, error: message)
                    } else if step.didFinish {
                        await circuitBreaker.recordSuccess(provider: provider)
                    }
                    // A clean failure before any content streams falls through
                    // to the next provider exactly like the chunked path, so a
                    // failing primary never pins the turn while it still cools.
                    if step.shouldContinue {
                        continue
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

    /// Streams a chat completion for callers holding the chat UUID directly.
    /// Normalizes to the string form so sticky-slot hashing sees one shape.
    public func chat(messages: [Message], tools: [any Tool], session: UUID?) -> AsyncStream<LLMResponse> {
        chat(messages: messages, tools: tools, sessionID: session?.uuidString)
    }

    /// Drains one chunk-streaming provider, preserving mid-stream error propagation.
    /// Threads the chat identifier so sticky-slot backends pin the turn instead
    /// of always falling back to server auto-assignment.
    private static func drainChunkedProvider(
        _ provider: any ChunkStreamingProvider,
        messages: [Message],
        tools: [ToolDefinition],
        sessionID: String? = nil,
        continuation: AsyncStream<LLMResponse>.Continuation
    ) async -> ChunkedDrainResult {
        var yieldedText = false
        var failureMessage: String?
        var lastUsage: Int?
        chunkLoop: for await chunk in provider.chatChunks(messages: messages, tools: tools, sessionID: sessionID) {
            if Task.isCancelled {
                break
            }
            switch chunk {
            case let .textDelta(text):
                yieldedText = yieldedText || !text.isEmpty
                continuation.yield(LLMResponse(delta: text))
            case let .reasoningDelta(thought):
                continuation.yield(LLMResponse(delta: "", reasoningDelta: thought))
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
    /// Threads the chat identifier so backends with per-turn session handling
    /// pin the turn; backends without sticky state fall back to the
    /// session-agnostic path via the base default, so only sticky backends pin.
    private static func drainStandardProvider(
        _ provider: any LLMProvider,
        messages: [Message],
        tools: [any Tool],
        sessionID: String? = nil,
        continuation: AsyncStream<LLMResponse>.Continuation
    ) async -> ChunkedDrainResult {
        var yieldedContent = false
        var failureMessage: String?
        for await part in provider.chat(messages: messages, tools: tools, sessionID: sessionID) {
            if Task.isCancelled {
                break
            }
            if part.isError {
                failureMessage = part.errorMessage ?? "unknown error"
                // Suppress the error chunk when nothing streamed yet so the
                // caller can fail over without leaking a terminal error
                // mid-stream; once content is out the turn must settle here.
                if yieldedContent {
                    continuation.yield(part)
                }
                break
            }
            if !part.delta.isEmpty || !part.reasoningDelta.isEmpty || !part.toolCalls.isEmpty {
                yieldedContent = true
            }
            continuation.yield(part)
            if part.isFinished {
                break
            }
        }
        if let failureMessage {
            if !yieldedContent {
                return ChunkedDrainResult(didFinish: false, lastError: failureMessage, shouldContinue: true)
            }
            if !Task.isCancelled {
                return ChunkedDrainResult(didFinish: true, lastError: failureMessage, shouldContinue: false)
            }
            return ChunkedDrainResult(didFinish: false, lastError: failureMessage, shouldContinue: false)
        }
        if Task.isCancelled {
            return ChunkedDrainResult(didFinish: false, lastError: nil, shouldContinue: false)
        }
        return ChunkedDrainResult(didFinish: true, lastError: nil, shouldContinue: false)
    }

    /// Tools safe for one provider's capability on the text-streaming path.
    public static func visionGatedTools(_ tools: [any Tool], supportsVision: Bool) -> [any Tool] {
        // Silent prefilter and re-validation keep one wire log site per turn: the request body
        // builders log each skip, so router filtering stays quiet to avoid 2x per invalid tool.
        let prefiltered = VisionSchemaFilter.validatedTools(tools, logSkips: false)
        guard !supportsVision else { return prefiltered.valid }
        return prefiltered.valid.compactMap { tool -> (any Tool)? in
            guard tool.name == BrowserScreenshotPolicy.navigateToolName else { return tool }
            let stripped = VisionSchemaFilter.strippedNavigateSchema(tool.inputSchema)
            // Stripping only removes optional keys, but omit defensively if it broke validity.
            // Silent check keeps the single wire log site; the builder logs if this ever withholds.
            let rechecked = VisionSchemaFilter.partitionValidSchemas(
                entries: [stripped.rawValue],
                name: { _ in tool.name },
                rawSchema: { $0 },
                logSkips: false
            )
            guard !rechecked.valid.isEmpty else {
                return nil
            }
            return VisionGatedTool(wrapping: tool, inputSchema: stripped)
        }
    }

    /// Embeds texts via the first healthy provider, falling through on failure.
    /// Consults the circuit breaker exactly like chat so a cooled provider
    /// stays rested for embeddings too instead of bypassing its cooldown.
    public func embeddings(text: [String]) async throws -> [[Float]] {
        var lastError: (any Error)?
        for provider in providers {
            if Task.isCancelled {
                // Abort before consulting a fallback provider so cancellation
                // never masquerades as provider exhaustion.
                throw CancellationError()
            }
            // Breaker first so cooling providers rest for embeddings as well
            // as chat; provider health second for backends that self-report
            // downtime. Both skips fail closed to the next fallback.
            guard await circuitBreaker.isAvailable(provider: provider) else { continue }
            guard await provider.isAvailable() else { continue }
            do {
                let vectors = try await provider.embeddings(text: text)
                await circuitBreaker.recordSuccess(provider: provider)
                return vectors
            } catch let error as CancellationError {
                // Bound rethrow preserves the original cancellation error
                // instead of recording it for fallthrough.
                throw error
            } catch {
                lastError = error
                // String form carries the status code (for example 429/503)
                // so the breaker classifies embeddings failures like chat
                // failures instead of treating every error as generic.
                await circuitBreaker.recordFailure(provider: provider, error: String(describing: error))
                continue
            }
        }
        if let lastError {
            throw lastError
        }
        throw LLMProviderError.unavailable("No embedding providers are available")
    }
}

/// Tool wrapper hiding the screenshot opt-in from text-only models.
private struct VisionGatedTool: Tool, Sendable {
    /// Wrapped tool providing identity and execution.
    let wrapped: any Tool
    /// Advertised schema, possibly without the screenshot opt-in.
    let advertisedSchema: JSONSchema

    /// Creates a gated view over a registered tool.
    init(wrapping: any Tool, inputSchema: JSONSchema) {
        self.wrapped = wrapping
        self.advertisedSchema = inputSchema
    }

    /// Stable identifier from the wrapped tool.
    var name: String {
        wrapped.name
    }

    /// Description from the wrapped tool.
    var description: String {
        wrapped.description
    }

    /// Stripped schema for text-only prompts.
    var inputSchema: JSONSchema {
        advertisedSchema
    }

    /// Trust level from the wrapped tool.
    var permissionLevel: PermissionLevel {
        wrapped.permissionLevel
    }

    /// Runs the wrapped tool unchanged.
    func execute(input: ToolInput, context: ToolContext) async throws -> ToolOutput {
        try await wrapped.execute(input: input, context: context)
    }
}

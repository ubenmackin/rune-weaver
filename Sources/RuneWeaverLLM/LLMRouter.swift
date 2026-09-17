// Rune Weaver LLM — Priority-ordered provider router and failover orchestrator.

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

    /// Creates a router with the given provider priority.
    /// - Parameter providers: Providers in priority order.
    public init(providers: [any LLMProvider] = []) {
        self.providers = providers
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
                        messages: outboundMessages,
                        tools: Self.visionGatedTools(tools, supportsVision: supportsVision),
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

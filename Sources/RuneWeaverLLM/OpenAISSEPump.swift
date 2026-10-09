// Rune Weaver LLM — Server-sent event pumps for chat completions and responses.

import Foundation
import RuneWeaverCore

/// Pumps SSE byte streams into chunk events.
enum OpenAISSEPump {
    /// Reads a short error preview from an errored byte stream.
    /// - Parameter bytes: Response byte stream.
    /// - Returns: Decoded preview, or a placeholder.
    static func responseDetail(from bytes: URLSession.AsyncBytes) async -> String {
        var preview = ""
        do {
            for try await line in bytes.lines {
                preview += line
                if preview.count > 500 {
                    break
                }
            }
        } catch {
            return "unreadable error body"
        }
        let trimmed = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "empty error body" : String(trimmed.prefix(500))
    }

    /// Applies one decoded chat SSE chunk to streaming state.
    static func ingestChatChunk(
        _ chunk: OpenAIStreamChunkDTO,
        lastModel: inout String,
        lastUsage: inout TokenUsage?,
        lastFinishReason: inout String?,
        toolAccumulator: inout OpenAIToolCallAccumulator
    ) -> (text: String?, reasoning: String?) {
        if let reported = chunk.model, !reported.isEmpty {
            lastModel = reported
        }
        if let usage = chunk.usage {
            let prompt = usage.promptTokens ?? 0
            let completion = usage.completionTokens ?? 0
            let total = usage.totalTokens ?? (prompt + completion)
            let cached = usage.effectiveCachedTokens
            lastUsage = TokenUsage(
                promptTokens: prompt,
                completionTokens: completion,
                totalTokens: total,
                cachedTokens: cached
            )
            // Surface prefix reuse where the server reports it: a growing cached
            // count beside a stable prompt count proves the leading bytes (system
            // prompt plus tools plus early history) hit the KV cache instead of
            // re-evaluating. Missing fields stay silent to preserve current behavior.
            if let cached {
                RuneWeaverLog.server.info("Chat usage: prompt \(prompt) tokens (\(cached) cached)")
            }
        }
        guard let choice = chunk.choices?.first else { return (nil, nil) }
        if let reason = choice.finishReason {
            lastFinishReason = reason
        }
        let delta = choice.delta ?? choice.message
        for toolDelta in delta?.toolCalls ?? [] {
            toolAccumulator.apply(toolDelta)
        }
        let reasoning = delta?.effectiveReasoning
        let text = (delta?.content?.isEmpty == false) ? delta?.content : nil
        return (text: text, reasoning: reasoning)
    }

    /// Emits deltas from an ingested chunk payload.
    /// - Returns: True if streaming should continue; false if cancelled or terminated.
    @discardableResult
    static func emitIngestedChunk(
        data: Data,
        lastModel: inout String,
        lastUsage: inout TokenUsage?,
        lastFinishReason: inout String?,
        toolAccumulator: inout OpenAIToolCallAccumulator,
        continuation: AsyncStream<LLMResponseChunk>.Continuation
    ) -> Bool {
        guard let chunk = try? JSONDecoder().decode(OpenAIStreamChunkDTO.self, from: data) else {
            return true
        }
        let ingested = ingestChatChunk(
            chunk,
            lastModel: &lastModel,
            lastUsage: &lastUsage,
            lastFinishReason: &lastFinishReason,
            toolAccumulator: &toolAccumulator
        )
        if let reasoning = ingested.reasoning, !reasoning.isEmpty {
            if Task.isCancelled || isYieldTerminated(continuation.yield(.reasoningDelta(reasoning))) {
                return false
            }
        }
        if let text = ingested.text, !text.isEmpty {
            if Task.isCancelled || isYieldTerminated(continuation.yield(.textDelta(text))) {
                return false
            }
        }
        return true
    }

    /// Emits accumulated finished tool calls.
    /// - Returns: True if streaming should continue; false if cancelled or terminated.
    @discardableResult
    static func emitFinishedToolCalls(
        from accumulator: OpenAIToolCallAccumulator,
        continuation: AsyncStream<LLMResponseChunk>.Continuation
    ) -> Bool {
        for call in accumulator.finishedCalls() {
            if Task.isCancelled || isYieldTerminated(continuation.yield(.toolCall(call))) {
                return false
            }
        }
        return true
    }

    /// Pumps SSE lines into chunk events.
    static func pumpSSE(
        bytes: URLSession.AsyncBytes,
        fallbackModel: String,
        continuation: AsyncStream<LLMResponseChunk>.Continuation
    ) async {
        var accumulator = OpenAIToolCallAccumulator()
        var sawSSE = false
        var bufferedJSON = ""
        var lastModel = fallbackModel
        var lastUsage: TokenUsage?
        var lastFinishReason: String?
        do {
            for try await line in bytes.lines {
                if Task.isCancelled {
                    continuation.finish()
                    return
                }
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty || trimmed.hasPrefix(":") {
                    continue
                }
                guard trimmed.hasPrefix("data:") else {
                    bufferedJSON += line + "\n"
                    continue
                }
                sawSSE = true
                let payload = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" {
                    break
                }
                guard let data = payload.data(using: .utf8) else { continue }
                let ok = emitIngestedChunk(
                    data: data,
                    lastModel: &lastModel,
                    lastUsage: &lastUsage,
                    lastFinishReason: &lastFinishReason,
                    toolAccumulator: &accumulator,
                    continuation: continuation
                )
                if !ok {
                    continuation.finish()
                    return
                }
            }
            if Task.isCancelled {
                continuation.finish()
                return
            }
            if !sawSSE, !bufferedJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let data = bufferedJSON.data(using: .utf8)
            {
                let ok = emitIngestedChunk(
                    data: data,
                    lastModel: &lastModel,
                    lastUsage: &lastUsage,
                    lastFinishReason: &lastFinishReason,
                    toolAccumulator: &accumulator,
                    continuation: continuation
                )
                if !ok {
                    continuation.finish()
                    return
                }
            }
        } catch is CancellationError {
            continuation.finish()
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            continuation.finish()
            return
        } catch {
            continuation.yield(.error("Chat stream failed: \(error.localizedDescription)"))
            continuation.finish()
            return
        }
        guard !Task.isCancelled, emitFinishedToolCalls(from: accumulator, continuation: continuation) else {
            continuation.finish()
            return
        }
        continuation.yield(.done(ResponseMetadata(model: lastModel, usage: lastUsage, finishReason: lastFinishReason)))
        continuation.finish()
    }
}

// MARK: - Responses API pump

extension OpenAISSEPump {
    /// One outcome of a Responses stream event.
    enum ResponsesEventEffect {
        /// Emit incremental text.
        case textDelta(String)
        /// Record completion details.
        case completed(model: String?, usage: TokenUsage?)
        /// Fail the stream with a message.
        case error(String)
        /// Buffer a tool call for the end of the stream.
        case toolCall(ToolCall)
        /// No observable effect.
        case ignored
    }

    /// Maps one Responses event to its stream effect.
    static func effect(for event: OpenAIResponsesStreamEventDTO, nextIndex: Int) -> ResponsesEventEffect {
        guard let type = event.type else {
            if let message = event.errorMessage {
                return .error(message)
            }
            return .ignored
        }
        switch type {
        case "response.output_text.delta":
            guard let delta = event.delta, !delta.isEmpty else {
                return .ignored
            }
            return .textDelta(delta)
        case "response.completed":
            let model = event.response?.model.flatMap { $0.isEmpty ? nil : $0 }
            return .completed(model: model, usage: responsesUsage(from: event.response?.usage))
        case "error", "response.failed", "response.error":
            return .error(event.errorMessage ?? "unknown error")
        default:
            if let call = responsesToolCall(from: event, nextIndex: nextIndex) {
                return .toolCall(call)
            }
            return .ignored
        }
    }

    /// Extracts a tool call from a function-call event.
    static func responsesToolCall(from event: OpenAIResponsesStreamEventDTO, nextIndex: Int) -> ToolCall? {
        guard let type = event.type else {
            return nil
        }
        if let item = event.item, item.type == "function_call" {
            let name = item.name ?? event.name ?? ""
            guard !name.isEmpty else {
                return nil
            }
            let rawArguments = item.arguments ?? event.arguments ?? ""
            let callId = item.callId ?? item.id ?? event.callId ?? "call_\(nextIndex)"
            return ToolCall(id: callId, name: name, argumentsJSON: rawArguments.isEmpty ? "{}" : rawArguments)
        }
        if type.contains("function_call") {
            guard let name = event.name, !name.isEmpty else {
                return nil
            }
            let rawArguments = event.arguments ?? ""
            let callId = event.callId ?? "call_\(nextIndex)"
            return ToolCall(id: callId, name: name, argumentsJSON: rawArguments.isEmpty ? "{}" : rawArguments)
        }
        return nil
    }

    /// Converts a Responses usage block to token accounting.
    static func responsesUsage(from dto: OpenAIResponsesUsageDTO?) -> TokenUsage? {
        guard let dto else {
            return nil
        }
        let prompt = dto.inputTokens ?? 0
        let completion = dto.outputTokens ?? 0
        let cached = dto.effectiveCachedTokens
        let usage = TokenUsage(
            promptTokens: prompt,
            completionTokens: completion,
            totalTokens: dto.totalTokens ?? (prompt + completion),
            cachedTokens: cached
        )
        // Same prefix-reuse signal as the chat wire: log only when the server
        // reports a cache count so absent fields degrade to current behavior.
        if let cached {
            RuneWeaverLog.server.info("Responses usage: prompt \(prompt) tokens (\(cached) cached)")
        }
        return usage
    }

    /// Applies one stream effect to state and continuation.
    /// - Returns: True if streaming should continue; false if cancelled, errored, or terminated.
    @discardableResult
    static func applyResponsesEffect(
        _ effect: ResponsesEventEffect,
        lastModel: inout String,
        lastUsage: inout TokenUsage?,
        continuation: AsyncStream<LLMResponseChunk>.Continuation
    ) -> Bool {
        switch effect {
        case let .textDelta(delta):
            if Task.isCancelled || isYieldTerminated(continuation.yield(.textDelta(delta))) {
                return false
            }
        case let .completed(model, usage):
            if let model {
                lastModel = model
            }
            if let usage {
                lastUsage = usage
            }
        case let .error(message):
            continuation.yield(.error(message))
            return false
        case .toolCall, .ignored:
            break
        }
        return true
    }

    /// Emits accumulated finished Responses tool calls.
    /// - Returns: True if streaming should continue; false if cancelled or terminated.
    @discardableResult
    static func emitFinishedResponsesToolCalls(
        from accumulator: OpenAIResponsesToolCallAccumulator,
        continuation: AsyncStream<LLMResponseChunk>.Continuation
    ) -> Bool {
        for call in accumulator.finishedCalls() {
            if Task.isCancelled || isYieldTerminated(continuation.yield(.toolCall(call))) {
                return false
            }
        }
        return true
    }

    /// Pumps Responses SSE lines into chunk events.
    static func pumpResponsesSSE(
        bytes: URLSession.AsyncBytes,
        fallbackModel: String,
        continuation: AsyncStream<LLMResponseChunk>.Continuation
    ) async {
        var lastModel = fallbackModel
        var lastUsage: TokenUsage?
        var accumulator = OpenAIResponsesToolCallAccumulator()
        do {
            for try await line in bytes.lines {
                if Task.isCancelled {
                    continuation.finish()
                    return
                }
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty || trimmed.hasPrefix(":") {
                    continue
                }
                guard trimmed.hasPrefix("data:") else {
                    continue
                }
                let payload = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" {
                    break
                }
                guard let data = payload.data(using: .utf8),
                      let event = try? JSONDecoder().decode(OpenAIResponsesStreamEventDTO.self, from: data)
                else {
                    continue
                }
                let nextIndex = accumulator.count
                accumulator.ingest(event, nextIndex: nextIndex)
                let streamEffect = effect(for: event, nextIndex: nextIndex)
                let ok = applyResponsesEffect(
                    streamEffect,
                    lastModel: &lastModel,
                    lastUsage: &lastUsage,
                    continuation: continuation
                )
                if !ok {
                    continuation.finish()
                    return
                }
            }
        } catch is CancellationError {
            continuation.finish()
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            continuation.finish()
            return
        } catch {
            continuation.yield(.error("Responses stream failed: \(error.localizedDescription)"))
            continuation.finish()
            return
        }
        guard !Task.isCancelled, emitFinishedResponsesToolCalls(from: accumulator, continuation: continuation) else {
            continuation.finish()
            return
        }
        continuation.yield(.done(ResponseMetadata(model: lastModel, usage: lastUsage, finishReason: nil)))
        continuation.finish()
    }
}

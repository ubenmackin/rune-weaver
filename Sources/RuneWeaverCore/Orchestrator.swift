// Rune Weaver Core — Turn orchestration and tool execution loop.

import Foundation

/// Convenience alias for the conversation role.
public typealias Role = Message.Role

/// User input received by the orchestrator.
public struct UserInput: Sendable, Codable, Equatable {
    /// Raw user text (or voice transcription).
    public let text: String
    /// Owning session identifier.
    public let sessionID: UUID
    /// Input origin (e.g. `"text"`, `"voice"`, `"dashboard"`).
    public let source: String
    /// Optional turn-specific system prompt override.
    public let systemPrompt: String?

    /// Creates user input.
    public init(text: String, sessionID: UUID = UUID(), source: String = "text", systemPrompt: String? = nil) {
        self.text = text
        self.sessionID = sessionID
        self.source = source
        self.systemPrompt = systemPrompt
    }
}

/// One tool invocation performed while answering.
public struct ToolAction: Sendable, Codable, Equatable {
    /// Name of the tool that ran.
    public let toolName: String
    /// Correlation identifier of the call.
    public let callID: String
    /// Raw JSON arguments sent to the tool.
    public let argumentsJSON: String
    /// Result returned by the bus, if the call ran.
    public let result: ToolResult?
    /// Whether the call succeeded.
    public var didSucceed: Bool {
        result?.isError == false
    }

    /// Creates a tool action.
    public init(toolName: String, callID: String, argumentsJSON: String, result: ToolResult? = nil) {
        self.toolName = toolName
        self.callID = callID
        self.argumentsJSON = argumentsJSON
        self.result = result
    }
}

/// Response returned by the orchestrator.
public struct OrchestratorResponse: Sendable, Codable, Equatable {
    /// Final assistant text.
    public let text: String
    /// Owning session identifier.
    public let sessionID: UUID
    /// Tool invocations performed while answering.
    public let toolActions: [ToolAction]
    /// Session-billed tokens accumulated across every LLM round in this turn (each round's
    /// `totalTokens`, summed). Nil when no round reported usage, mirroring the CLI
    /// `runChunkedTurn`/`runTextTurn` session total for the API path.
    public let totalTokens: Int?
    /// Serving model name.
    public let modelName: String?
    /// Context window limit in tokens.
    public let contextLength: Int?
    /// Cumulative billed tokens for this session, if tracked.
    public let sessionTokens: Int?
    /// Whether this turn parked waiting on approval.
    public let isParked: Bool
    /// Degraded-tool notices for tools omitted this turn. Carries only tool names
    /// plus a static reason so no secrets or schema payloads reach the wire.
    public let warnings: [String]

    /// Coding keys matching the JSON wire shape.
    private enum CodingKeys: String, CodingKey {
        /// Final assistant text.
        case text
        /// Owning session identifier.
        case sessionID
        /// Tool invocations performed.
        case toolActions
        /// Session-billed tokens.
        case totalTokens
        /// Serving model name.
        case modelName
        /// Context window limit.
        case contextLength
        /// Cumulative billed tokens.
        case sessionTokens
        /// Whether the turn parked waiting on approval.
        case isParked
        /// Degraded-tool notices.
        case warnings
    }

    /// Creates a response.
    public init(
        text: String,
        sessionID: UUID,
        toolActions: [ToolAction] = [],
        totalTokens: Int? = nil,
        modelName: String? = nil,
        contextLength: Int? = nil,
        sessionTokens: Int? = nil,
        isParked: Bool = false,
        warnings: [String] = []
    ) {
        self.text = text
        self.sessionID = sessionID
        self.toolActions = toolActions
        self.totalTokens = totalTokens
        self.modelName = modelName
        self.contextLength = contextLength
        self.sessionTokens = sessionTokens
        self.isParked = isParked
        self.warnings = warnings
    }

    /// Decodes a response, defaulting missing parked flags to not parked and missing warnings to empty.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.text = try container.decode(String.self, forKey: .text)
        self.sessionID = try container.decode(UUID.self, forKey: .sessionID)
        self.toolActions = try container.decodeIfPresent([ToolAction].self, forKey: .toolActions) ?? []
        self.totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens)
        self.modelName = try container.decodeIfPresent(String.self, forKey: .modelName)
        self.contextLength = try container.decodeIfPresent(Int.self, forKey: .contextLength)
        self.sessionTokens = try container.decodeIfPresent(Int.self, forKey: .sessionTokens)
        self.isParked = try container.decodeIfPresent(Bool.self, forKey: .isParked) ?? false
        self.warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
    }

    /// Encodes a response.
    /// - Parameter encoder: Destination encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(toolActions, forKey: .toolActions)
        try container.encodeIfPresent(totalTokens, forKey: .totalTokens)
        try container.encodeIfPresent(modelName, forKey: .modelName)
        try container.encodeIfPresent(contextLength, forKey: .contextLength)
        try container.encodeIfPresent(sessionTokens, forKey: .sessionTokens)
        try container.encode(isParked, forKey: .isParked)
        // Omit empty warnings so older decoders see an absent key and degrade to no banner,
        // mirroring WSStreamDone which nils empty lists for back-compat.
        if !warnings.isEmpty {
            try container.encode(warnings, forKey: .warnings)
        }
    }
}

/// Failures raised by ``Orchestrator``.
public enum OrchestratorError: Error, Sendable, Equatable {
    /// The input text was empty or whitespace-only.
    case emptyInput
    /// The tool loop still requested tool calls after `maxToolIterations`
    /// tool rounds plus the final synthesis turn.
    case toolLoopExceeded(iterations: Int)
    /// The LLM stream reported a mid-stream failure, even when partial
    /// text was already yielded. Surfaced instead of finishing the turn
    /// as a silent success.
    case llmFailed(String)
}

extension OrchestratorError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyInput:
            "Input text was empty or whitespace-only."
        case let .toolLoopExceeded(iterations):
            "Tool loop exceeded \(iterations) rounds."
        case let .llmFailed(detail):
            detail
        }
    }
}

/// Real-time progress event emitted during turn orchestration.
public enum OrchestratorEvent: Sendable, Codable, Equatable {
    /// Tool execution is about to begin.
    case toolStarted(toolName: String, callID: String, argumentsJSON: String)
    /// Tool execution has completed.
    case toolCompleted(toolName: String, callID: String, result: ToolResult)
    /// Incremental assistant text delta generated by the model.
    case textDelta(String)
    /// Filed narrated approval awaiting an inbox decision.
    case approval(PermissionRequest)
    /// Degraded-tool notice for a tool omitted this turn. Carries only the
    /// preformatted warning line so no schema payloads reach subscribers.
    case warning(String)
}

/// Parked narrated approval awaiting a later decision.
public struct ParkedNarratedApproval: Sendable, Equatable {
    /// Owning session the narration parked in.
    public let sessionID: UUID
    /// Gated invocation filed for approval.
    public let toolCall: ToolInput
    /// Effective system prompt active when the turn parked.
    public let systemPrompt: String?
    /// Per-turn batch identifier shared by siblings parked together.
    public let batchID: UUID

    /// Creates a parked approval.
    public init(sessionID: UUID, toolCall: ToolInput, systemPrompt: String? = nil, batchID: UUID = UUID()) {
        self.sessionID = sessionID
        self.toolCall = toolCall
        self.systemPrompt = systemPrompt
        self.batchID = batchID
    }
}

/// Context grouping the inputs for one parked-approval filing path.
private struct ParkGatedCallsContext {
    let gated: [ToolInput]
    let narratedText: String
    let tools: [any Tool]
    let sessionID: UUID
    let priorActions: [ToolAction]
    let billedTokens: Int?
    let systemPrompt: String?
    let onEvent: (@Sendable (OrchestratorEvent) async -> Void)?
}

/// Inputs for one bounded tool-loop run.
private struct TurnLoopRequest {
    let workingMessages: [Message]
    let tools: [any Tool]
    let recall: Message?
    let sessionID: UUID
    let systemPrompt: String?
    let onEvent: (@Sendable (OrchestratorEvent) async -> Void)?
}

/// Outcome of one bounded tool-loop run.
private enum TurnLoopOutcome {
    case finished(finalText: String, toolActions: [ToolAction], billedTokens: Int?)
    case parked(OrchestratorResponse)
}

/// Intermediate result of an LLM round.
private struct TurnDraft: Sendable {
    let text: String
    let billedTokens: Int?
    let toolCalls: [ToolInput]
}

/// Core orchestration loop: input, context, LLM, tools, response.
public actor Orchestrator {
    /// Session and history owner.
    private let conversations: ConversationManager
    /// Tool registry and permission gate.
    private let toolBus: ToolBus
    /// LLM backend serving completions.
    private let llm: any LLMProvider
    /// Developer instructions prepended to every turn.
    private let systemPrompt: String?
    /// Maximum tool-call rounds per response, plus one final synthesis turn.
    private let maxToolIterations: Int
    /// Optional resolver mapping an assistant turn to tool calls.
    private let toolResolver: OrchestratorToolResolver?
    /// Episodic mirror for every turn, when configured.
    private let memoryEngine: MemoryEngine?
    /// Optional embeddings producer for vector-ranked automatic recall.
    private let embedder: (any EmbeddingsBackend)?
    /// Queue receiving narrated gated calls, when configured.
    private let approvalQueue: ApprovalQueue?
    /// Parked gated narrations indexed by approval request identifier.
    private var parkedNarratedApprovals: [UUID: ParkedNarratedApproval] = [:]
    /// Executed gated actions buffered per parked batch while siblings stay pending.
    private var parkedBatchExecutedActions: [UUID: [ToolAction]] = [:]
    /// Cumulative billed tokens tracked per session.
    private var sessionTokensBySession: [UUID: Int] = [:]
    /// Access order for token totals, oldest first.
    private var sessionTokenOrder: [UUID] = []
    /// Bounds token totals so deleted sessions never leak memory.
    private static let maxTrackedSessions = 500

    /// Creates an orchestrator.
    public init(
        conversations: ConversationManager,
        toolBus: ToolBus,
        llm: any LLMProvider,
        systemPrompt: String? = nil,
        maxToolIterations: Int = 8,
        toolResolver: OrchestratorToolResolver? = nil,
        memoryEngine: MemoryEngine? = nil,
        approvalQueue: ApprovalQueue? = nil,
        embedder: (any EmbeddingsBackend)? = nil
    ) {
        self.conversations = conversations
        self.toolBus = toolBus
        self.llm = llm
        self.systemPrompt = systemPrompt
        self.maxToolIterations = max(1, maxToolIterations)
        self.toolResolver = toolResolver
        self.memoryEngine = memoryEngine
        self.approvalQueue = approvalQueue
        self.embedder = embedder
    }

    /// Processes one user input through the full loop.
    public func process(input: UserInput) async throws -> OrchestratorResponse {
        try await process(input: input, onEvent: nil)
    }

    /// Processes one user input with real-time progress notifications.
    public func process(
        input: UserInput,
        onEvent: (@Sendable (OrchestratorEvent) async -> Void)? = nil
    ) async throws -> OrchestratorResponse {
        try Task.checkCancellation()
        let text = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw OrchestratorError.emptyInput
        }
        let sessionID = input.sessionID
        _ = await conversations.ensureSession(id: sessionID)
        // Raw pre-turn copy (messages plus rolling summary, never the
        // synthetic summary-prefix view) so cancellation restores both
        // without duplicating the summary or keeping truncated growth.
        let preTurnSnapshot = await conversations.rollbackSnapshot(for: sessionID)
        // Episodic mirrors buffer until commit: user text, compact tool records, and final text
        // flush on success or on failures that keep working partials.
        var pendingEpisodic: [(content: String, role: Message.Role)] = []

        do {
            await conversations.append(Message(role: .user, content: text), to: sessionID)
            pendingEpisodic.append((text, .user))

            if let earlyResponse = try await rememberEarlyResponse(
                text: text,
                source: input.source,
                sessionID: sessionID,
                pendingEpisodic: &pendingEpisodic,
                onEvent: onEvent
            ) {
                try Task.checkCancellation()
                await flushEpisodic(pendingEpisodic, sessionID: sessionID)
                return earlyResponse
            }

            let effectiveSystemPrompt: String? = if let custom = input.systemPrompt {
                custom
            } else if input.source == "scheduler" {
                await SystemPromptComposer.composeScheduled(tools: toolBus.availableTools())
            } else {
                systemPrompt
            }
            let recall: Message? = if let memoryEngine {
                try await memoryEngine.recallMessage(for: text, sessionID: sessionID, embedder: embedder)
            } else {
                nil
            }
            let workingMessages = await MemoryEngine.historyWithRecall(
                conversations.workingHistory(for: sessionID, systemPrompt: effectiveSystemPrompt),
                recall: recall
            )
            let tools = await toolBus.availableTools()
            // Degraded tools stay out of the model request but must not fail the turn:
            // surface one static warning per skipped tool name mid-turn and again
            // on the terminal response so streaming and polling clients agree.
            let turnWarnings = OrchestratorToolLoop.degradedToolWarnings(for: tools)
            for warning in turnWarnings {
                await onEvent?(.warning(warning))
            }
            let request = TurnLoopRequest(
                workingMessages: workingMessages,
                tools: tools,
                recall: recall,
                sessionID: sessionID,
                systemPrompt: effectiveSystemPrompt,
                onEvent: onEvent
            )
            let outcome = try await runTurnLoop(request, pendingEpisodic: &pendingEpisodic)
            switch outcome {
            case let .parked(parkedResponse):
                return parkedResponse
            case let .finished(finalText, toolActions, loopBilled):
                await storeFinalAssistantText(finalText, sessionID: sessionID, pendingEpisodic: &pendingEpisodic)
                try Task.checkCancellation()
                await flushEpisodic(pendingEpisodic, sessionID: sessionID)
                let cumulativeTokens = accumulateSessionTokens(loopBilled, for: sessionID)
                return OrchestratorResponse(
                    text: finalText,
                    sessionID: sessionID,
                    toolActions: toolActions,
                    totalTokens: loopBilled,
                    modelName: llm.modelInfo.name,
                    contextLength: llm.modelInfo.contextLength,
                    sessionTokens: cumulativeTokens,
                    warnings: turnWarnings
                )
            }
        } catch let error as CancellationError {
            // Executed tools already changed the world: keep working-memory
            // partials and mirror them so the audit trail survives the
            // cancel instead of being rolled back as if nothing ran.
            let hasExecutedTools = pendingEpisodic.contains { $0.role == .tool }
            if hasExecutedTools {
                await flushEpisodicUncancellable(pendingEpisodic, sessionID: sessionID)
            } else if let preTurnSnapshot {
                await conversations.restoreRollbackSnapshot(preTurnSnapshot)
            }
            throw error
        } catch {
            // Non-cancellation failures keep working-memory partials, so
            // flush the buffered mirror to match instead of diverging.
            await flushEpisodic(pendingEpisodic, sessionID: sessionID)
            throw error
        }
    }

    /// Serving model info (model name and context length limit).
    public var modelInfo: ModelInfo {
        llm.modelInfo
    }

    /// Whether a session owns a parked narrated turn awaiting approval.
    public func isSessionParked(_ sessionID: UUID) -> Bool {
        for parked in parkedNarratedApprovals.values where parked.sessionID == sessionID {
            return true
        }
        return false
    }
}

// MARK: - Parked approvals and turn loop execution

/// Holds the resume path plus the extracted tool-loop helpers so the main
/// actor body stays within the length budget while sharing file-private state.
extension Orchestrator {
    /// Resumes a parked narrated approval after its inbox decision.
    public func resumeNarratedApproval(
        id: UUID,
        approved: Bool,
        onEvent: (@Sendable (OrchestratorEvent) async -> Void)? = nil
    ) async throws -> OrchestratorResponse? {
        try Task.checkCancellation()
        guard let parked = parkedNarratedApprovals.removeValue(forKey: id) else {
            return nil
        }
        if let queue = approvalQueue {
            _ = await queue.takeEarlyDecision(id: id)
        }
        _ = await conversations.ensureSession(id: parked.sessionID)
        if approved {
            return try await resumeAllowedParked(parked, onEvent: onEvent)
        } else {
            return try await resumeDeniedParked(parked, onEvent: onEvent)
        }
    }

    /// Resumes a denied parked approval, deferring synthesis while siblings remain.
    private func resumeDeniedParked(
        _ parked: ParkedNarratedApproval,
        onEvent: (@Sendable (OrchestratorEvent) async -> Void)? = nil
    ) async throws -> OrchestratorResponse {
        let denial = await recordParkedDenial(parked.toolCall, sessionID: parked.sessionID, onEvent: onEvent)
        return try await finishParkedBatch(
            parked: parked,
            baseText: denial,
            newAction: nil,
            approved: false,
            onEvent: onEvent
        )
    }

    /// Resumes an allowed parked approval, executing then synthesizing once all siblings land.
    private func resumeAllowedParked(
        _ parked: ParkedNarratedApproval,
        onEvent: (@Sendable (OrchestratorEvent) async -> Void)? = nil
    ) async throws -> OrchestratorResponse {
        let sessionID = parked.sessionID
        let call = parked.toolCall
        guard let tool = await toolBus.tool(named: call.toolName) else {
            let missing = await recordParkedMissingTool(call.toolName, sessionID: sessionID, onEvent: onEvent)
            return try await finishParkedBatch(
                parked: parked,
                baseText: missing,
                newAction: nil,
                approved: true,
                onEvent: onEvent
            )
        }
        let action = await executeParkedCall(call, tool: tool, sessionID: sessionID, onEvent: onEvent)
        return try await finishParkedBatch(
            parked: parked,
            baseText: "",
            newAction: action,
            approved: true,
            onEvent: onEvent
        )
    }

    /// Completes one parked batch decision, deferring synthesis until the last sibling lands.
    private func finishParkedBatch(
        parked: ParkedNarratedApproval,
        baseText: String,
        newAction: ToolAction?,
        approved: Bool,
        onEvent: (@Sendable (OrchestratorEvent) async -> Void)?
    ) async throws -> OrchestratorResponse {
        let sessionID = parked.sessionID
        let batchID = parked.batchID
        if let newAction {
            appendBufferedParkedAction(newAction, forBatch: batchID)
        }
        // Resumed turns advertise the current registry, so recompute degraded notices
        // here rather than reusing the parked turn's snapshot.
        let resumeWarnings = await OrchestratorToolLoop.degradedToolWarnings(for: toolBus.availableTools())
        // Mirror the fresh-turn path so streaming and polling clients agree:
        // surface each skip live before the terminal response repeats it.
        for warning in resumeWarnings {
            await onEvent?(.warning(warning))
        }
        let remaining = remainingPendingActions(inBatch: batchID)
        if !remaining.isEmpty {
            let buffered = bufferedParkedActions(forBatch: batchID)
            let noun = if remaining.count == 1 {
                "approval"
            } else {
                "approvals"
            }
            let progress: String = if newAction != nil {
                parkedBatchProgressMessage(
                    toolName: parked.toolCall.toolName,
                    remainingCount: remaining.count,
                    approved: approved
                )
            } else {
                "\(baseText) Waiting for \(remaining.count) more \(noun)."
            }
            await onEvent?(.textDelta(progress))
            return OrchestratorResponse(
                text: progress,
                sessionID: sessionID,
                toolActions: buffered + remaining,
                modelName: llm.modelInfo.name,
                contextLength: llm.modelInfo.contextLength,
                sessionTokens: sessionTokensBySession[sessionID],
                isParked: true,
                warnings: resumeWarnings
            )
        }
        let buffered = takeBufferedParkedActions(forBatch: batchID)
        if buffered.isEmpty {
            return OrchestratorResponse(
                text: baseText,
                sessionID: sessionID,
                toolActions: [],
                modelName: llm.modelInfo.name,
                contextLength: llm.modelInfo.contextLength,
                sessionTokens: sessionTokensBySession[sessionID],
                isParked: false,
                warnings: resumeWarnings
            )
        }
        let prompt = await resolveParkedSynthesisPrompt(parked)
        let synthesis = try await synthesizeParkedTurn(sessionID: sessionID, prompt: prompt, onEvent: onEvent)
        let cumulative = accumulateSessionTokens(synthesis.billedTokens, for: sessionID)
        return OrchestratorResponse(
            text: synthesis.text,
            sessionID: sessionID,
            toolActions: buffered,
            totalTokens: synthesis.billedTokens,
            modelName: llm.modelInfo.name,
            contextLength: llm.modelInfo.contextLength,
            sessionTokens: cumulative,
            isParked: false,
            warnings: resumeWarnings
        )
    }

    /// Resolves the synthesis prompt for a parked turn.
    private func resolveParkedSynthesisPrompt(_ parked: ParkedNarratedApproval) async -> String? {
        if let stored = parked.systemPrompt {
            return stored
        }
        let source = await conversations.session(id: parked.sessionID)?.source
        if source == "scheduler" {
            let tools = await toolBus.availableTools()
            return SystemPromptComposer.composeScheduled(tools: tools)
        }
        return systemPrompt
    }

    /// Pending actions for siblings still awaiting inbox decisions.
    private func remainingPendingActions(inBatch batchID: UUID) -> [ToolAction] {
        parkedNarratedApprovals.values
            .filter { $0.batchID == batchID }
            .map {
                ToolAction(
                    toolName: $0.toolCall.toolName,
                    callID: $0.toolCall.callID,
                    argumentsJSON: $0.toolCall.argumentsJSON,
                    result: nil
                )
            }
            .sorted {
                if $0.toolName != $1.toolName {
                    return $0.toolName < $1.toolName
                }
                return $0.callID < $1.callID
            }
    }

    /// Buffered executed actions for one parked batch.
    /// - Parameter batchID: Per-turn batch identifier.
    /// - Returns: Executed gated actions decided so far, in decision order.
    private func bufferedParkedActions(forBatch batchID: UUID) -> [ToolAction] {
        parkedBatchExecutedActions[batchID] ?? []
    }

    /// Buffers one executed gated action for a parked batch.
    private func appendBufferedParkedAction(_ action: ToolAction, forBatch batchID: UUID) {
        parkedBatchExecutedActions[batchID, default: []].append(action)
    }

    /// Takes and clears buffered executed actions for a parked batch.
    /// - Parameter batchID: Per-turn batch identifier.
    /// - Returns: Executed actions in decision order, possibly empty.
    private func takeBufferedParkedActions(forBatch batchID: UUID) -> [ToolAction] {
        let buffered = parkedBatchExecutedActions[batchID] ?? []
        parkedBatchExecutedActions.removeValue(forKey: batchID)
        return buffered
    }

    /// Progress text for a parked batch still awaiting sibling decisions.
    private func parkedBatchProgressMessage(toolName: String, remainingCount: Int, approved: Bool) -> String {
        let trimmed = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name: String = if trimmed.isEmpty {
            "the requested tool"
        } else {
            trimmed
        }
        let verb = if approved {
            "Approved"
        } else {
            "Denied"
        }
        if remainingCount <= 0 {
            return "\(verb) \(name)."
        }
        let noun = if remainingCount == 1 {
            "approval"
        } else {
            "approvals"
        }
        return "\(verb) \(name); waiting for \(remainingCount) more \(noun)."
    }

    /// Records a denied parked call in its session.
    private func recordParkedDenial(
        _ call: ToolInput,
        sessionID: UUID,
        onEvent: (@Sendable (OrchestratorEvent) async -> Void)?
    ) async -> String {
        let denial = OrchestratorToolLoop.deniedApprovalMessage(for: call.toolName)
        await conversations.append(Message(role: .assistant, content: denial), to: sessionID)
        await onEvent?(.textDelta(denial))
        await flushEpisodic([(denial, .assistant)], sessionID: sessionID)
        return denial
    }

    /// Records a missing-tool notice for an allowed parked call.
    private func recordParkedMissingTool(
        _ toolName: String,
        sessionID: UUID,
        onEvent: (@Sendable (OrchestratorEvent) async -> Void)?
    ) async -> String {
        let missing = "Approval allowed for \(toolName), but the tool is no longer available."
        await conversations.append(Message(role: .assistant, content: missing), to: sessionID)
        await onEvent?(.textDelta(missing))
        await flushEpisodic([(missing, .assistant)], sessionID: sessionID)
        return missing
    }

    /// Executes one allowed parked call without re-entering the gate.
    private func executeParkedCall(
        _ call: ToolInput,
        tool: any Tool,
        sessionID: UUID,
        onEvent: (@Sendable (OrchestratorEvent) async -> Void)?
    ) async -> ToolAction {
        await onEvent?(.toolStarted(
            toolName: call.toolName,
            callID: call.callID,
            argumentsJSON: call.argumentsJSON
        ))
        let result: ToolResult
        do {
            let output = try await tool.execute(
                input: call,
                context: ToolContext(conversationID: sessionID)
            )
            result = ToolResult(output, toolCallID: call.callID)
        } catch {
            result = .failure(
                toolCallID: call.callID,
                content: "Tool '\(call.toolName)' failed: \(error.localizedDescription)"
            )
        }
        let action = ToolAction(
            toolName: call.toolName,
            callID: call.callID,
            argumentsJSON: call.argumentsJSON,
            result: result
        )
        await onEvent?(.toolCompleted(
            toolName: call.toolName,
            callID: call.callID,
            result: result
        ))
        await conversations.append(result.asMessage(), to: sessionID)
        var pending: [(content: String, role: Message.Role)] = []
        if let record = OrchestratorToolLoop.episodicToolRecord(toolName: call.toolName, result: result) {
            pending.append((record, .tool))
        }
        await flushEpisodic(pending, sessionID: sessionID)
        return action
    }

    /// Runs one synthesis turn for a parked batch in its session.
    private func synthesizeParkedTurn(
        sessionID: UUID,
        prompt: String?,
        onEvent: (@Sendable (OrchestratorEvent) async -> Void)?
    ) async throws -> (text: String, billedTokens: Int?) {
        try Task.checkCancellation()
        let tools = await toolBus.availableTools()
        // Live degraded notices already streamed once by the resume caller, so synthesis stays
        // quiet to keep one warning frame per skipped tool instead of doubling the bell badge.
        // Invalid schemas still stay out of the model request via the provider filter.
        let workingMessages = await conversations.workingHistory(for: sessionID, systemPrompt: prompt)
        let collected = try await collectTurn(messages: workingMessages, tools: tools, onDelta: { delta in
            await onEvent?(.textDelta(delta))
        })
        var pending: [(content: String, role: Message.Role)] = []
        await storeFinalAssistantText(collected.text, sessionID: sessionID, pendingEpisodic: &pending)
        await flushEpisodic(pending, sessionID: sessionID)
        return (collected.text, collected.billedTokens)
    }

    // MARK: - Private helpers

    /// Runs the bounded tool loop for one turn until final text or parking.
    private func runTurnLoop(
        _ request: TurnLoopRequest,
        pendingEpisodic: inout [(content: String, role: Message.Role)]
    ) async throws -> TurnLoopOutcome {
        var workingMessages = request.workingMessages
        let tools = request.tools
        let recall = request.recall
        let sessionID = request.sessionID
        let onEvent = request.onEvent
        var toolActions: [ToolAction] = []
        var finalText = ""
        var toolRounds = 0
        var billedTokens: Int?
        // Fail-closed names for structured calls: hallucinated names for omitted schemas never execute.
        // Silent partition keeps the prompt and wire filters as the single logging sites per turn.
        let validToolNames = Set(VisionSchemaFilter.partitionValidSchemas(
            entries: tools,
            name: { $0.name },
            rawSchema: { $0.inputSchema.rawValue },
            logSkips: false
        ).valid.map(\.name))
        while true {
            try Task.checkCancellation()
            let collected = try await collectTurn(messages: workingMessages, tools: tools, onDelta: { delta in
                await onEvent?(.textDelta(delta))
            })
            if let billed = collected.billedTokens {
                billedTokens = (billedTokens ?? 0) + billed
            }
            finalText = collected.text
            // Withheld schemas leave no executable call: fall through to the fail-closed narrated
            // fallback rather than running hallucinated names.
            var calls = collected.toolCalls.filter { validToolNames.contains($0.toolName) }
            if calls.isEmpty {
                calls = try await resolveToolCalls(messages: workingMessages, assistantText: finalText, tools: tools)
                // Custom resolvers see the full registry, so withhold invalid schemas here as well.
                calls = calls.filter { validToolNames.contains($0.toolName) }
            }
            // Narrated gated calls are always collected so mixed turns that
            // pair structured calls with gated narration file approvals
            // instead of dropping them.
            let gated = OrchestratorToolLoop.narratedGatedCalls(from: finalText, tools: tools)
            if calls.isEmpty, gated.isEmpty {
                break
            }
            if !calls.isEmpty {
                toolRounds += 1
                if OrchestratorToolLoop.isLimitExceeded(rounds: toolRounds, max: maxToolIterations) {
                    throw OrchestratorError.toolLoopExceeded(iterations: maxToolIterations)
                }
                let assistantNote = assistantNoteMessage(text: finalText, calls: calls)
                await conversations.append(assistantNote, to: sessionID)
                let executed = try await executeToolCalls(calls, sessionID: sessionID, onEvent: onEvent, pendingEpisodic: &pendingEpisodic)
                toolActions.append(contentsOf: executed)
                if !gated.isEmpty, approvalQueue != nil {
                    let context = ParkGatedCallsContext(
                        gated: gated,
                        narratedText: finalText,
                        tools: tools,
                        sessionID: sessionID,
                        priorActions: toolActions,
                        billedTokens: billedTokens,
                        systemPrompt: request.systemPrompt,
                        onEvent: onEvent
                    )
                    let parked = await parkGatedCalls(context, pendingEpisodic: &pendingEpisodic)
                    return .parked(parked)
                }
                workingMessages = await refreshedWorkingMessages(sessionID: sessionID, recall: recall, systemPrompt: request.systemPrompt)
                finalText = ""
                continue
            }
            if !gated.isEmpty {
                if approvalQueue != nil {
                    let context = ParkGatedCallsContext(
                        gated: gated,
                        narratedText: finalText,
                        tools: tools,
                        sessionID: sessionID,
                        priorActions: toolActions,
                        billedTokens: billedTokens,
                        systemPrompt: request.systemPrompt,
                        onEvent: onEvent
                    )
                    let parked = await parkGatedCalls(context, pendingEpisodic: &pendingEpisodic)
                    return .parked(parked)
                }
                break
            }
        }
        return .finished(finalText: finalText, toolActions: toolActions, billedTokens: billedTokens)
    }

    /// Builds the working-memory note recording one tool round's intent.
    private func assistantNoteMessage(text: String, calls: [ToolInput]) -> Message {
        Message(
            role: .assistant,
            content: OrchestratorToolLoop.assistantNoteContent(text: text, calls: calls)
        )
    }

    /// Refreshes recall-augmented history after one tool round.
    private func refreshedWorkingMessages(sessionID: UUID, recall: Message?, systemPrompt: String? = nil) async -> [Message] {
        await MemoryEngine.historyWithRecall(
            conversations.workingHistory(for: sessionID, systemPrompt: systemPrompt ?? self.systemPrompt),
            recall: recall
        )
    }

    /// Stores the final assistant text when it carries user-visible content.
    private func storeFinalAssistantText(
        _ finalText: String,
        sessionID: UUID,
        pendingEpisodic: inout [(content: String, role: Message.Role)]
    ) async {
        guard OrchestratorToolLoop.shouldStoreAssistantText(finalText) else { return }
        await conversations.append(Message(role: .assistant, content: finalText), to: sessionID)
        pendingEpisodic.append((finalText, .assistant))
    }

    /// Executes tool calls in sequence, publishing real-time events and recording outcomes.
    private func executeToolCalls(
        _ calls: [ToolInput],
        sessionID: UUID,
        onEvent: (@Sendable (OrchestratorEvent) async -> Void)?,
        pendingEpisodic: inout [(content: String, role: Message.Role)]
    ) async throws -> [ToolAction] {
        var actions: [ToolAction] = []
        let context = ToolContext(conversationID: sessionID)
        for call in calls {
            try Task.checkCancellation()
            await onEvent?(.toolStarted(
                toolName: call.toolName,
                callID: call.callID,
                argumentsJSON: call.argumentsJSON
            ))
            let result = await toolBus.execute(toolCall: call, context: context)
            let action = ToolAction(
                toolName: call.toolName,
                callID: call.callID,
                argumentsJSON: call.argumentsJSON,
                result: result
            )
            actions.append(action)
            await onEvent?(.toolCompleted(
                toolName: call.toolName,
                callID: call.callID,
                result: result
            ))
            await conversations.append(result.asMessage(), to: sessionID)
            if let record = OrchestratorToolLoop.episodicToolRecord(toolName: call.toolName, result: result) {
                pendingEpisodic.append((record, .tool))
            }
            try Task.checkCancellation()
        }
        return actions
    }

    /// Files gated narrations and ends the turn parked waiting on approval.
    private func parkGatedCalls(
        _ context: ParkGatedCallsContext,
        pendingEpisodic: inout [(content: String, role: Message.Role)]
    ) async -> OrchestratorResponse {
        // Withhold invalid schemas fail-closed: gated narrations for omitted tools never file.
        // Silent partition keeps the prompt and wire filters as the single logging sites.
        let validParkTools = VisionSchemaFilter.partitionValidSchemas(
            entries: context.tools,
            name: { $0.name },
            rawSchema: { $0.inputSchema.rawValue },
            logSkips: false
        ).valid
        let byName = Dictionary(validParkTools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let batchID = UUID()
        if let queue = approvalQueue {
            for call in context.gated {
                guard let tool = byName[call.toolName] else { continue }
                let request = await queue.fileRequest(tool: tool, call: call, sessionID: context.sessionID)
                parkedNarratedApprovals[request.id] = ParkedNarratedApproval(
                    sessionID: context.sessionID,
                    toolCall: call,
                    systemPrompt: context.systemPrompt,
                    batchID: batchID
                )
                await context.onEvent?(.approval(request))
            }
        }
        let waiting = OrchestratorToolLoop.waitingOnApprovalMessage(for: context.gated)
        await conversations.append(assistantNoteMessage(text: context.narratedText, calls: context.gated), to: context.sessionID)
        await conversations.append(Message(role: .assistant, content: waiting), to: context.sessionID)
        pendingEpisodic.append((waiting, .assistant))
        await context.onEvent?(.textDelta(waiting))
        await flushEpisodic(pendingEpisodic, sessionID: context.sessionID)
        let cumulativeTokens = accumulateSessionTokens(context.billedTokens, for: context.sessionID)
        // Parked gated calls stay pending with no result so the awaiting
        // approval run entry keeps their names and call identifiers for
        // detail views and call-ID fallback.
        let pendingGatedActions = context.gated.map {
            ToolAction(toolName: $0.toolName, callID: $0.callID, argumentsJSON: $0.argumentsJSON, result: nil)
        }
        // Degraded tools share the turn's registry snapshot so parked and finished
        // responses agree even when the model never saw the omitted entries.
        let parkedWarnings = OrchestratorToolLoop.degradedToolWarnings(for: context.tools)
        return OrchestratorResponse(
            text: waiting,
            sessionID: context.sessionID,
            toolActions: context.priorActions + pendingGatedActions,
            totalTokens: context.billedTokens,
            modelName: llm.modelInfo.name,
            contextLength: llm.modelInfo.contextLength,
            sessionTokens: cumulativeTokens,
            isParked: true,
            warnings: parkedWarnings
        )
    }
}

// MARK: - Session tokens and memory mirroring

/// Holds episodic flushing, remember handling, token totals, and LLM
/// collection helpers so no single type body exceeds the length budget.
extension Orchestrator {
    /// Flushes buffered episodic mirrors without throwing.
    private func flushEpisodic(_ pending: [(content: String, role: Message.Role)], sessionID: UUID) async {
        guard let memoryEngine else { return }
        for entry in pending {
            await memoryEngine.mirrorTurn(content: entry.content, sessionID: sessionID, role: entry.role, failurePolicy: .silent)
        }
    }

    /// Flushes buffered episodic mirrors without observing cancellation.
    private func flushEpisodicUncancellable(
        _ pending: [(content: String, role: Message.Role)],
        sessionID: UUID
    ) async {
        guard let memoryEngine else { return }
        for entry in pending {
            await memoryEngine.mirrorTurnUncancellable(
                content: entry.content,
                sessionID: sessionID,
                role: entry.role
            )
        }
    }

    /// Returns an acknowledgement response for explicit remember requests, if applicable.
    private func rememberEarlyResponse(
        text: String,
        source: String,
        sessionID: UUID,
        pendingEpisodic: inout [(content: String, role: Message.Role)],
        onEvent: (@Sendable (OrchestratorEvent) async -> Void)?
    ) async throws -> OrchestratorResponse? {
        guard let factText = MemoryEngine.rememberFactText(from: text) else {
            return nil
        }
        let acknowledgement = try await rememberAcknowledgement(factText: factText, source: source)
        await conversations.append(Message(role: .assistant, content: acknowledgement), to: sessionID)
        pendingEpisodic.append((acknowledgement, .assistant))
        await onEvent?(.textDelta(acknowledgement))
        // Remember turns bypass the model but must stay honest: surface the same degraded-tool
        // notices live and on the terminal response so skips never go silent.
        let rememberWarnings = await OrchestratorToolLoop.degradedToolWarnings(for: toolBus.availableTools())
        for warning in rememberWarnings {
            await onEvent?(.warning(warning))
        }
        return OrchestratorResponse(
            text: acknowledgement,
            sessionID: sessionID,
            toolActions: [],
            sessionTokens: sessionTokensBySession[sessionID],
            warnings: rememberWarnings
        )
    }

    /// Folds this turn's billed tokens into the session total.
    private func accumulateSessionTokens(_ billedTokens: Int?, for sessionID: UUID) -> Int? {
        guard let billedTokens else {
            return sessionTokensBySession[sessionID]
        }
        let updated = (sessionTokensBySession[sessionID] ?? 0) + billedTokens
        sessionTokensBySession[sessionID] = updated
        // Keep recency behind the map so overflow evicts deterministically.
        if let prior = sessionTokenOrder.firstIndex(of: sessionID) {
            sessionTokenOrder.remove(at: prior)
        }
        sessionTokenOrder.append(sessionID)
        // Bound the map so removed or evicted sessions cannot leak totals forever; drops the least-
        // recently-billed session rather than the just-updated one.
        if sessionTokensBySession.count > Self.maxTrackedSessions {
            let victim = sessionTokenOrder.first(where: { $0 != sessionID })
                ?? sessionTokensBySession.keys.first(where: { $0 != sessionID })
                ?? sessionTokenOrder.first
            if let victim {
                sessionTokensBySession.removeValue(forKey: victim)
                sessionTokenOrder.removeAll(where: { $0 == victim })
            }
        }
        return updated
    }

    /// Drops the cached token total for one session.
    public func forgetSession(id: UUID) {
        sessionTokensBySession.removeValue(forKey: id)
        sessionTokenOrder.removeAll(where: { $0 == id })
        let removedBatchIDs = Set(parkedNarratedApprovals.values.filter { $0.sessionID == id }.map(\.batchID))
        parkedNarratedApprovals = parkedNarratedApprovals.filter { $0.value.sessionID != id }
        for batchID in removedBatchIDs {
            parkedBatchExecutedActions.removeValue(forKey: batchID)
        }
    }

    /// Removes one session from history and drops its billed total together.
    public func removeSession(id: UUID) async {
        await conversations.removeSession(id: id)
        forgetSession(id: id)
    }

    /// Removes every session and drops every billed total together.
    public func removeAllSessions() async {
        await conversations.removeAllSessions()
        clearSessionTokens()
        parkedNarratedApprovals.removeAll()
        parkedBatchExecutedActions.removeAll()
    }

    /// Clears one session's history and drops its billed total together.
    public func clearSession(_ sessionID: UUID) async {
        await conversations.clear(sessionID: sessionID)
        forgetSession(id: sessionID)
    }

    /// Drops every cached session token total.
    public func clearSessionTokens() {
        sessionTokensBySession.removeAll()
        sessionTokenOrder.removeAll()
    }

    /// Stores an explicit remember request and builds its acknowledgement.
    private func rememberAcknowledgement(factText: String, source: String) async throws -> String {
        guard MemoryEngine.isStorableFact(factText) else {
            return MemoryEngine.rememberAcknowledgementText(for: factText, stored: false)
        }
        guard let memoryEngine else {
            return MemoryEngine.rememberAcknowledgementText(for: factText, stored: false)
        }
        let stored = try await memoryEngine.storeRememberedFact(
            content: factText,
            source: OrchestratorToolLoop.resolvedSource(source),
            embedder: embedder
        )
        return MemoryEngine.rememberAcknowledgementText(for: factText, stored: stored)
    }

    /// Collects a full text turn from the streaming chat API.
    private func collectTurn(
        messages: [Message],
        tools: [any Tool],
        onDelta: (@Sendable (String) async -> Void)? = nil
    ) async throws -> TurnDraft {
        var text = ""
        var billed: Int?
        var toolCalls: [ToolInput] = []
        let stream = llm.chat(messages: messages, tools: tools)
        for await chunk in stream {
            try Task.checkCancellation()
            if let message = chunk.errorMessage {
                throw OrchestratorError.llmFailed(message.isEmpty ? "unknown error" : message)
            }
            text += chunk.delta
            if !chunk.toolCalls.isEmpty {
                toolCalls.append(contentsOf: chunk.toolCalls)
            }
            // Deltas stream even when a chunk also carries tool calls:
            // suppressing them breaks streaming fidelity for models that
            // narrate alongside function calls.
            if !chunk.delta.isEmpty {
                await onDelta?(chunk.delta)
            }
            if chunk.isFinished {
                billed = chunk.totalTokens
                break
            }
        }
        return TurnDraft(text: text, billedTokens: billed, toolCalls: toolCalls)
    }

    /// Resolves tool calls for the latest assistant turn.
    private func resolveToolCalls(messages: [Message], assistantText: String, tools: [any Tool]) async throws -> [ToolInput] {
        guard let toolResolver else {
            return OrchestratorToolLoop.narratedToolCalls(from: assistantText, tools: tools)
        }
        var context = messages
        if !assistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let last = context.last {
                if last.role != .assistant || last.content != assistantText {
                    context.append(Message(role: .assistant, content: assistantText))
                }
            } else {
                context.append(Message(role: .assistant, content: assistantText))
            }
        }
        let calls = try await toolResolver(context, tools)
        if !calls.isEmpty {
            return calls
        }
        return OrchestratorToolLoop.narratedToolCalls(from: assistantText, tools: tools)
    }
}

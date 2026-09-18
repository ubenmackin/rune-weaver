// Rune Weaver Core — Turn orchestration and tool execution loop.

import Foundation

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
    /// Context window compaction threshold percentage (10-100).
    private let compactionThresholdPercent: Int
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
        embedder: (any EmbeddingsBackend)? = nil,
        compactionThresholdPercent: Int = 80
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
        self.compactionThresholdPercent = max(10, min(100, compactionThresholdPercent))
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

            // Single registry snapshot shared by the prompt and the wire so both omit the
            // same disabled tools; sorted order mirrors the prompt so leading bytes stay
            // identical for server prefix caching. Both branches recompose from this snapshot
            // (vision-aware) so a mid-run tool toggle reaches the next turn's prompt as well
            // as its wire; mid-loop rounds reuse the snapshot, so a toggle takes effect on
            // the next user message. An explicit operator override bypasses composition verbatim.
            let tools = await VisionSchemaFilter.sortedByName(toolBus.availableTools(), name: { $0.name })
            let supportsVision = llm.modelInfo.supportsVision
            let includeToolSchemas = !llm.modelInfo.supportsTools
            let effectiveSystemPrompt: String? = if let custom = input.systemPrompt, !custom.isEmpty {
                // Custom override bypasses composition and its cache verbatim.
                custom
            } else if let stored = systemPrompt, !stored.isEmpty, !SystemPromptComposer.isComposedPrompt(stored) {
                // Explicit stored override wins over scheduler composition so live turns
                // and parked resumes honor the same custom prompt instead of diverging.
                stored
            } else if input.source == "scheduler" {
                SystemPromptComposer.composeScheduled(tools: tools, supportsVision: supportsVision, includeToolSchemas: includeToolSchemas)
            } else {
                SystemPromptComposer.compose(tools: tools, supportsVision: supportsVision, includeToolSchemas: includeToolSchemas)
            }
            let recall: Message? = if let memoryEngine {
                try await memoryEngine.recallMessage(for: text, sessionID: sessionID, embedder: embedder)
            } else {
                nil
            }
            await conversations.compactHistoryIfNeeded(
                for: sessionID,
                contextLength: llm.modelInfo.contextLength,
                thresholdPercent: compactionThresholdPercent
            )
            let workingMessages = await Self.stableHistoryWithRecall(
                conversations.workingHistory(for: sessionID, systemPrompt: effectiveSystemPrompt),
                recall: recall
            )
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
                let finalNote = await storeFinalAssistantText(finalText, sessionID: sessionID, pendingEpisodic: &pendingEpisodic)
                try Task.checkCancellation()
                await flushEpisodic(pendingEpisodic, sessionID: sessionID)
                let cumulativeTokens = accumulateSessionTokens(loopBilled, for: sessionID)
                // Nil when suppressed text persisted no note so equality stays deterministic
                // and clients fall back to receipt time instead of a wall-clock sample.
                return OrchestratorResponse(
                    text: finalText,
                    sessionID: sessionID,
                    toolActions: toolActions,
                    totalTokens: loopBilled,
                    modelName: llm.modelInfo.name,
                    contextLength: llm.modelInfo.contextLength,
                    sessionTokens: cumulativeTokens,
                    warnings: turnWarnings,
                    completedAt: finalNote?.createdAt.timeIntervalSince1970
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
        let denialNote = await recordParkedDenial(parked.toolCall, sessionID: parked.sessionID, onEvent: onEvent)
        return try await finishParkedBatch(
            parked: parked,
            baseText: denialNote.content,
            baseCompletedAt: denialNote.createdAt.timeIntervalSince1970,
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
            let missingNote = await recordParkedMissingTool(call.toolName, sessionID: sessionID, onEvent: onEvent)
            return try await finishParkedBatch(
                parked: parked,
                baseText: missingNote.content,
                baseCompletedAt: missingNote.createdAt.timeIntervalSince1970,
                newAction: nil,
                approved: true,
                onEvent: onEvent
            )
        }
        let action = await executeParkedCall(call, tool: tool, sessionID: sessionID, roundIndex: parked.roundIndex, onEvent: onEvent)
        return try await finishParkedBatch(
            parked: parked,
            baseText: "",
            baseCompletedAt: nil,
            newAction: action,
            approved: true,
            onEvent: onEvent
        )
    }

    /// Completes one parked batch decision, deferring synthesis until the last sibling lands.
    private func finishParkedBatch(
        parked: ParkedNarratedApproval,
        baseText: String,
        baseCompletedAt: Double? = nil,
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
        for warning in resumeWarnings {
            await onEvent?(.warning(warning))
        }
        let remaining = remainingPendingActions(inBatch: batchID)
        if !remaining.isEmpty {
            return await pendingParkedResponse(
                PendingParkedContext(
                    parked: parked,
                    remaining: remaining,
                    newAction: newAction,
                    baseText: baseText,
                    approved: approved,
                    warnings: resumeWarnings,
                    onEvent: onEvent
                )
            )
        }
        let buffered = takeBufferedParkedActions(forBatch: batchID)
        if buffered.isEmpty {
            return OrchestratorResponse(
                text: baseText,
                sessionID: sessionID,
                toolActions: parked.priorActions,
                modelName: llm.modelInfo.name,
                contextLength: llm.modelInfo.contextLength,
                sessionTokens: sessionTokensBySession[sessionID],
                isParked: false,
                warnings: resumeWarnings,
                completedAt: baseCompletedAt
            )
        }
        let prompt = await resolveParkedSynthesisPrompt(parked)
        let tools = await VisionSchemaFilter.sortedByName(toolBus.availableTools(), name: { $0.name })
        await conversations.compactHistoryIfNeeded(
            for: sessionID,
            contextLength: llm.modelInfo.contextLength,
            thresholdPercent: compactionThresholdPercent
        )
        let workingMessages = await refreshedWorkingMessages(
            sessionID: sessionID,
            recall: parked.recall,
            systemPrompt: prompt
        )
        var pendingEpisodic: [(content: String, role: Message.Role)] = []
        let combinedActions = parked.priorActions + buffered
        let request = TurnLoopRequest(
            workingMessages: workingMessages,
            tools: tools,
            recall: parked.recall,
            sessionID: sessionID,
            systemPrompt: prompt,
            onEvent: onEvent,
            initialToolActions: combinedActions,
            priorBilledTokens: parked.billedTokens,
            initialToolRounds: parked.toolRounds,
            initialLlmRoundIndex: parked.synthesisRoundIndex
        )
        do {
            let outcome = try await runTurnLoop(request, pendingEpisodic: &pendingEpisodic)
            switch outcome {
            case let .parked(parkedResponse):
                return parkedResponse
            case let .finished(finalText, toolActions, loopBilled):
                return try await finishResumedTurn(
                    finalText: finalText,
                    toolActions: toolActions,
                    loopBilled: loopBilled,
                    parked: parked,
                    resumeWarnings: resumeWarnings,
                    pendingEpisodic: &pendingEpisodic
                )
            }
        } catch let error as CancellationError {
            await flushEpisodicUncancellable(pendingEpisodic, sessionID: sessionID)
            throw error
        } catch {
            await flushEpisodic(pendingEpisodic, sessionID: sessionID)
            throw error
        }
    }

    private func pendingParkedResponse(_ context: PendingParkedContext) async -> OrchestratorResponse {
        let parked = context.parked
        let buffered = bufferedParkedActions(forBatch: parked.batchID)
        let noun = context.remaining.count == 1 ? "approval" : "approvals"
        let progress: String = if context.newAction != nil {
            parkedBatchProgressMessage(
                toolName: parked.toolCall.toolName,
                remainingCount: context.remaining.count,
                approved: context.approved
            )
        } else {
            "\(context.baseText) Waiting for \(context.remaining.count) more \(noun)."
        }
        await context.onEvent?(.textDelta(progress))
        return OrchestratorResponse(
            text: progress,
            sessionID: parked.sessionID,
            toolActions: buffered + context.remaining,
            modelName: llm.modelInfo.name,
            contextLength: llm.modelInfo.contextLength,
            sessionTokens: sessionTokensBySession[parked.sessionID],
            isParked: true,
            warnings: context.warnings,
            completedAt: nil
        )
    }

    private func finishResumedTurn(
        finalText: String,
        toolActions: [ToolAction],
        loopBilled: Int?,
        parked: ParkedNarratedApproval,
        resumeWarnings: [String],
        pendingEpisodic: inout [(content: String, role: Message.Role)]
    ) async throws -> OrchestratorResponse {
        let sessionID = parked.sessionID
        let finalNote = await storeFinalAssistantText(finalText, sessionID: sessionID, pendingEpisodic: &pendingEpisodic)
        try Task.checkCancellation()
        await flushEpisodic(pendingEpisodic, sessionID: sessionID)
        let cumulative = accumulateSessionTokens(loopBilled, for: sessionID)
        return OrchestratorResponse(
            text: finalText,
            sessionID: sessionID,
            toolActions: toolActions,
            totalTokens: Self.combinedTurnTokens(parked.billedTokens, loopBilled),
            modelName: llm.modelInfo.name,
            contextLength: llm.modelInfo.contextLength,
            sessionTokens: cumulative,
            isParked: false,
            warnings: resumeWarnings,
            completedAt: finalNote?.createdAt.timeIntervalSince1970
        )
    }

    /// Resolves the synthesis prompt for a parked turn.
    /// Reuses an explicit operator override verbatim, otherwise recomposes from the live
    /// registry with the model's vision branch so resumed synthesis advertises the same
    /// tools as its wire even when toggles landed while parked.
    private func resolveParkedSynthesisPrompt(_ parked: ParkedNarratedApproval) async -> String? {
        // Explicit overrides win over scheduler composition in the same order as the
        // live turn, so a scheduler run with a stored custom prompt resumes with the
        // same prompt instead of diverging to the scheduled template.
        if let stored = parked.systemPrompt, !stored.isEmpty, !SystemPromptComposer.isComposedPrompt(stored) {
            return stored
        }
        if let stored = systemPrompt, !stored.isEmpty, !SystemPromptComposer.isComposedPrompt(stored) {
            return stored
        }
        // Anything else (composed snapshot or absent) recomposes live so tool toggles
        // while parked reach synthesis; scheduler sessions keep the background template.
        let tools = await VisionSchemaFilter.sortedByName(toolBus.availableTools(), name: { $0.name })
        let source = await conversations.session(id: parked.sessionID)?.source
        let supportsVision = llm.modelInfo.supportsVision
        let includeToolSchemas = !llm.modelInfo.supportsTools
        if source == "scheduler" {
            return SystemPromptComposer.composeScheduled(tools: tools, supportsVision: supportsVision, includeToolSchemas: includeToolSchemas)
        }
        return SystemPromptComposer.compose(tools: tools, supportsVision: supportsVision, includeToolSchemas: includeToolSchemas)
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
                    result: nil,
                    roundIndex: $0.roundIndex
                )
            }
            .sorted {
                // Chronological round first so resumed timelines rejoin in turn order;
                // untracked rounds stay last in stored order rather than interleaving.
                let leftRound = $0.roundIndex ?? Int.max
                let rightRound = $1.roundIndex ?? Int.max
                if leftRound != rightRound {
                    return leftRound < rightRound
                }
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
    /// Returns the persisted note so the terminal response can share its creation instant.
    private func recordParkedDenial(
        _ call: ToolInput,
        sessionID: UUID,
        onEvent: (@Sendable (OrchestratorEvent) async -> Void)?
    ) async -> Message {
        let denial = OrchestratorToolLoop.deniedApprovalMessage(for: call.toolName)
        let note = Message(role: .assistant, content: denial)
        // Stamp from the stored instant so the live response and the history reload share one time.
        let persisted = await conversations.append(note, to: sessionID)
        await onEvent?(.textDelta(denial))
        await flushEpisodic([(denial, .assistant)], sessionID: sessionID)
        return persisted
    }

    /// Records a missing-tool notice for an allowed parked call.
    /// Returns the persisted note so the terminal response can share its creation instant.
    private func recordParkedMissingTool(
        _ toolName: String,
        sessionID: UUID,
        onEvent: (@Sendable (OrchestratorEvent) async -> Void)?
    ) async -> Message {
        let missing = "Approval allowed for \(toolName), but the tool is no longer available."
        let note = Message(role: .assistant, content: missing)
        // Stamp from the stored instant so the live response and the history reload share one time.
        let persisted = await conversations.append(note, to: sessionID)
        await onEvent?(.textDelta(missing))
        await flushEpisodic([(missing, .assistant)], sessionID: sessionID)
        return persisted
    }

    /// Executes one allowed parked call without re-entering the gate.
    private func executeParkedCall(
        _ call: ToolInput,
        tool: any Tool,
        sessionID: UUID,
        roundIndex: Int? = nil,
        onEvent: (@Sendable (OrchestratorEvent) async -> Void)? = nil
    ) async -> ToolAction {
        await onEvent?(.toolStarted(
            toolName: call.toolName,
            callID: call.callID,
            argumentsJSON: call.argumentsJSON,
            roundIndex: roundIndex
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
            result: result,
            roundIndex: roundIndex
        )
        await onEvent?(.toolCompleted(
            toolName: call.toolName,
            callID: call.callID,
            result: result,
            roundIndex: roundIndex
        ))
        await conversations.append(result.asMessage(), to: sessionID)
        var pending: [(content: String, role: Message.Role)] = []
        if let record = OrchestratorToolLoop.episodicToolRecord(toolName: call.toolName, result: result) {
            pending.append((record, .tool))
        }
        await flushEpisodic(pending, sessionID: sessionID)
        return action
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
        var toolActions: [ToolAction] = request.initialToolActions
        var finalText = ""
        var toolRounds = request.initialToolRounds
        var billedTokens: Int?
        // Zero-based LLM round counter for live usage progress.
        var llmRoundIndex = request.initialLlmRoundIndex
        let validToolNames = Set(VisionSchemaFilter.partitionValidSchemas(
            entries: tools,
            name: { $0.name },
            rawSchema: { $0.inputSchema.rawValue },
            logSkips: false
        ).valid.map(\.name))
        while true {
            try Task.checkCancellation()
            let collected = try await collectTurn(messages: workingMessages, tools: tools, sessionID: sessionID, onDelta: { delta in
                await onEvent?(.textDelta(delta))
            })
            await emitTurnTokens(
                billed: collected.billedTokens,
                billedTokens: &billedTokens,
                roundIndex: llmRoundIndex,
                request: request
            )
            llmRoundIndex += 1
            finalText = collected.text
            var calls = collected.toolCalls.filter { validToolNames.contains($0.toolName) }
            if calls.isEmpty {
                calls = try await resolveToolCalls(messages: workingMessages, assistantText: finalText, tools: tools)
                calls = calls.filter { validToolNames.contains($0.toolName) }
            }
            let gated = OrchestratorToolLoop.narratedGatedCalls(from: finalText, tools: tools)
            if calls.isEmpty, gated.isEmpty {
                break
            }
            if !calls.isEmpty {
                toolRounds += 1
                if OrchestratorToolLoop.isLimitExceeded(rounds: toolRounds, max: maxToolIterations) {
                    throw OrchestratorError.toolLoopExceeded(iterations: maxToolIterations)
                }
                let roundIndex = toolRounds - 1
                let assistantNote = assistantNoteMessage(text: finalText, calls: calls)
                await conversations.append(assistantNote, to: sessionID)
                let executed = try await executeToolCalls(
                    calls,
                    sessionID: sessionID,
                    roundIndex: roundIndex,
                    onEvent: onEvent,
                    pendingEpisodic: &pendingEpisodic
                )
                toolActions.append(contentsOf: executed)
                if !gated.isEmpty, approvalQueue != nil {
                    return await parkTurn(
                        ParkTurnContext(
                            gated: gated,
                            narratedText: finalText,
                            toolActions: toolActions,
                            billedTokens: billedTokens,
                            toolRounds: toolRounds
                        ),
                        request: request,
                        pendingEpisodic: &pendingEpisodic
                    )
                }
                workingMessages = await refreshedWorkingMessages(sessionID: sessionID, recall: recall, systemPrompt: request.systemPrompt)
                finalText = ""
                continue
            }
            if !gated.isEmpty {
                if approvalQueue != nil {
                    return await parkTurn(
                        ParkTurnContext(
                            gated: gated,
                            narratedText: finalText,
                            toolActions: toolActions,
                            billedTokens: billedTokens,
                            toolRounds: toolRounds
                        ),
                        request: request,
                        pendingEpisodic: &pendingEpisodic
                    )
                }
                break
            }
        }
        return .finished(finalText: finalText, toolActions: toolActions, billedTokens: billedTokens)
    }

    private func emitTurnTokens(
        billed: Int?,
        billedTokens: inout Int?,
        roundIndex: Int,
        request: TurnLoopRequest
    ) async {
        guard let billed, billed >= 0 else { return }
        billedTokens = (billedTokens ?? 0) + billed
        if let turnTotal = billedTokens {
            let cumulativeTurnTotal = if let prior = request.priorBilledTokens, prior >= 0 {
                prior + turnTotal
            } else {
                turnTotal
            }
            await request.onEvent?(.turnTokens(
                roundIndex: roundIndex,
                roundTokens: billed,
                turnTotalTokens: cumulativeTurnTotal
            ))
        }
    }

    private func parkTurn(
        _ turn: ParkTurnContext,
        request: TurnLoopRequest,
        pendingEpisodic: inout [(content: String, role: Message.Role)]
    ) async -> TurnLoopOutcome {
        let context = ParkGatedCallsContext(
            gated: turn.gated,
            narratedText: turn.narratedText,
            tools: request.tools,
            sessionID: request.sessionID,
            priorActions: turn.toolActions,
            billedTokens: turn.billedTokens,
            priorBilledTokens: request.priorBilledTokens,
            systemPrompt: request.systemPrompt,
            recall: request.recall,
            onEvent: request.onEvent,
            gatedRoundIndex: turn.toolRounds
        )
        let parked = await parkGatedCalls(context, pendingEpisodic: &pendingEpisodic)
        return .parked(parked)
    }

    /// Builds the working-memory note recording one tool round's intent.
    private func assistantNoteMessage(text: String, calls: [ToolInput]) -> Message {
        Message(
            role: .assistant,
            content: OrchestratorToolLoop.assistantNoteContent(text: text, calls: calls)
        )
    }

    /// Stable recall slot keeping the prefix identical across rounds.
    /// Single-sources the slot through the shared memory helper so CLI and service turns
    /// agree; recall sits after every leading system so a summary arriving mid-turn
    /// shifts history after recall instead of shifting recall itself.
    public static func stableHistoryWithRecall(_ history: [Message], recall: Message?) -> [Message] {
        MemoryEngine.historyWithRecall(history, recall: recall)
    }

    /// Refreshes recall-augmented history after one tool round.
    /// Reuses the turn's system string verbatim (never recomposes from the live
    /// registry mid-loop) and the turn's recall at its stable slot. The caller
    /// passes the turn's effective prompt explicitly so mid-loop history keeps
    /// the composed vision-aware prompt instead of the raw stored value.
    private func refreshedWorkingMessages(sessionID: UUID, recall: Message?, systemPrompt: String?) async -> [Message] {
        await Self.stableHistoryWithRecall(
            conversations.workingHistory(for: sessionID, systemPrompt: systemPrompt ?? self.systemPrompt),
            recall: recall
        )
    }

    /// Stores the final assistant text when it carries user-visible content.
    /// Returns the persisted note so callers can stamp the response completion from the same
    /// creation instant the history reload path reads, keeping live and reload in agreement.
    @discardableResult
    private func storeFinalAssistantText(
        _ finalText: String,
        sessionID: UUID,
        pendingEpisodic: inout [(content: String, role: Message.Role)]
    ) async -> Message? {
        guard OrchestratorToolLoop.shouldStoreAssistantText(finalText) else { return nil }
        let note = Message(role: .assistant, content: finalText)
        // Stamp from the stored instant so the live response and the history reload share one time.
        let persisted = await conversations.append(note, to: sessionID)
        pendingEpisodic.append((finalText, .assistant))
        return persisted
    }

    /// Executes tool calls in sequence, publishing real-time events and recording outcomes.
    private func executeToolCalls(
        _ calls: [ToolInput],
        sessionID: UUID,
        roundIndex: Int,
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
                argumentsJSON: call.argumentsJSON,
                roundIndex: roundIndex
            ))
            let result = await toolBus.execute(toolCall: call, context: context)
            let action = ToolAction(
                toolName: call.toolName,
                callID: call.callID,
                argumentsJSON: call.argumentsJSON,
                result: result,
                roundIndex: roundIndex
            )
            actions.append(action)
            await onEvent?(.toolCompleted(
                toolName: call.toolName,
                callID: call.callID,
                result: result,
                roundIndex: roundIndex
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
        // The caller already resolved the chronological round: one past the structured
        // batch in mixed turns, otherwise one past all prior tool rounds so reloads
        // interleave identically to live.
        let effectiveGatedRound = context.gatedRoundIndex
        let turnTotalTokens = Self.combinedTurnTokens(context.priorBilledTokens, context.billedTokens)
        if let queue = approvalQueue {
            for call in context.gated {
                guard let tool = byName[call.toolName] else { continue }
                let request = await queue.fileRequest(tool: tool, call: call, sessionID: context.sessionID)
                parkedNarratedApprovals[request.id] = ParkedNarratedApproval(
                    sessionID: context.sessionID,
                    toolCall: call,
                    systemPrompt: context.systemPrompt,
                    recall: context.recall,
                    batchID: batchID,
                    roundIndex: effectiveGatedRound,
                    billedTokens: turnTotalTokens,
                    synthesisRoundIndex: effectiveGatedRound + 1,
                    priorActions: context.priorActions,
                    toolRounds: effectiveGatedRound
                )
                await context.onEvent?(.approval(request))
            }
        }
        let waiting = OrchestratorToolLoop.waitingOnApprovalMessage(for: context.gated)
        await conversations.append(assistantNoteMessage(text: context.narratedText, calls: context.gated), to: context.sessionID)
        let waitingNote = Message(role: .assistant, content: waiting)
        // Stamp from the stored instant so the live parked response and the history reload share one time.
        let persistedWaiting = await conversations.append(waitingNote, to: context.sessionID)
        pendingEpisodic.append((waiting, .assistant))
        await context.onEvent?(.textDelta(waiting))
        await flushEpisodic(pendingEpisodic, sessionID: context.sessionID)
        let cumulativeTokens = accumulateSessionTokens(context.billedTokens, for: context.sessionID)
        // Parked gated calls stay pending with no result so the awaiting
        // approval run entry keeps their names and call identifiers for
        // detail views and call-ID fallback.
        let pendingGatedActions = context.gated.map {
            ToolAction(toolName: $0.toolName, callID: $0.callID, argumentsJSON: $0.argumentsJSON, result: nil, roundIndex: effectiveGatedRound)
        }
        // Degraded tools share the turn's registry snapshot so parked and finished
        // responses agree even when the model never saw the omitted entries.
        let parkedWarnings = OrchestratorToolLoop.degradedToolWarnings(for: context.tools)
        return OrchestratorResponse(
            text: waiting,
            sessionID: context.sessionID,
            toolActions: context.priorActions + pendingGatedActions,
            totalTokens: turnTotalTokens,
            modelName: llm.modelInfo.name,
            contextLength: llm.modelInfo.contextLength,
            sessionTokens: cumulativeTokens,
            isParked: true,
            warnings: parkedWarnings,
            completedAt: persistedWaiting.createdAt.timeIntervalSince1970
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
        let acknowledgementNote = Message(role: .assistant, content: acknowledgement)
        // Stamp from the stored instant so the live response and the history reload share one time.
        let persistedAcknowledgement = await conversations.append(acknowledgementNote, to: sessionID)
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
            warnings: rememberWarnings,
            completedAt: persistedAcknowledgement.createdAt.timeIntervalSince1970
        )
    }

    /// Folds this turn's billed tokens into the session total.
    /// Drops malformed negative usage like the dashboard so a drifted backend
    /// cannot decrement the stored total or leak negatives into done frames.
    private func accumulateSessionTokens(_ billedTokens: Int?, for sessionID: UUID) -> Int? {
        guard let billedTokens else {
            return sessionTokensBySession[sessionID]
        }
        guard billedTokens >= 0 else {
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

    /// Sums pre-park and synthesis usage into one turn total for a resumed user message.
    /// Stored session totals already hold the pre-park share from park time, so this shapes
    /// only the terminal turn total: nil when neither round reported usage, otherwise the
    /// sum with absent sides treated as zero. Negatives drop like the dashboard.
    private static func combinedTurnTokens(_ prior: Int?, _ synthesis: Int?) -> Int? {
        let validPrior: Int? = if let prior, prior >= 0 {
            prior
        } else {
            nil
        }
        let validSynthesis: Int? = if let synthesis, synthesis >= 0 {
            synthesis
        } else {
            nil
        }
        switch (validPrior, validSynthesis) {
        case (nil, nil):
            return nil
        case (let priorValue?, nil):
            return priorValue
        case (nil, let synthesisValue?):
            return synthesisValue
        case let (priorValue?, synthesisValue?):
            return priorValue + synthesisValue
        }
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
    /// Carries the chat identifier end to end so sticky-slot backends reuse the
    /// cached prefix instead of falling back to server auto-assignment every turn.
    private func collectTurn(
        messages: [Message],
        tools: [any Tool],
        sessionID: UUID? = nil,
        onDelta: (@Sendable (String) async -> Void)? = nil
    ) async throws -> TurnDraft {
        var text = ""
        var billed: Int?
        var toolCalls: [ToolInput] = []
        let stream = llm.chat(messages: messages, tools: tools, session: sessionID)
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
                // Drop malformed negative usage like the dashboard so a drifted
                // backend cannot decrement session totals or emit negative progress.
                if let total = chunk.totalTokens {
                    billed = total >= 0 ? total : nil
                }
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

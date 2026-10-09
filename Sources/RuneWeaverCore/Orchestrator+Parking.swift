// Rune Weaver Core — Parked approvals and resume execution for Orchestrator.

import Foundation

// MARK: - Parked approvals and turn resumption

extension Orchestrator {
    /// Whether a session owns a parked narrated turn awaiting approval.
    public func isSessionParked(_ sessionID: UUID) -> Bool {
        for parked in parkedNarratedApprovals.values where parked.sessionID == sessionID {
            return true
        }
        return false
    }

    /// Resumes a parked approval after its inbox decision.
    /// Structured gated calls reuse this identical entry as narrated ones, so a
    /// late decide resumes against the current history with the same take, session
    /// ensure, and waiting-note removal instead of a second resume shape.
    public func resumeNarratedApproval(
        id: UUID,
        approved: Bool,
        answer: String? = nil,
        onEvent: (@Sendable (OrchestratorEvent) async -> Void)? = nil
    ) async throws -> OrchestratorResponse? {
        try Task.checkCancellation()
        guard let parked = takeParkedNarratedApproval(id: id) else {
            return nil
        }
        if let queue = approvalQueue {
            _ = await queue.takeEarlyDecision(id: id)
        }
        _ = await conversations.ensureSession(id: parked.sessionID)
        await conversations.removeWaitingMessages(from: parked.sessionID)
        if approved {
            return try await resumeAllowedParked(parked, answer: answer, onEvent: onEvent)
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
        answer: String? = nil,
        onEvent: (@Sendable (OrchestratorEvent) async -> Void)? = nil
    ) async throws -> OrchestratorResponse {
        let sessionID = parked.sessionID
        let call = parked.toolCall
        if call.toolName == "engine.continue" {
            return try await resumeAllowedContinue(parked, call: call, sessionID: sessionID, onEvent: onEvent)
        }
        if call.toolName == "desktop.resume" {
            return try await resumeAllowedDesktopResume(parked, call: call, sessionID: sessionID, onEvent: onEvent)
        }
        if call.toolName == "question.ask" {
            return try await resumeAllowedQuestionAsk(parked, call: call, sessionID: sessionID, answer: answer, onEvent: onEvent)
        }
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

    /// Resumes an allowed `engine.continue` parked approval with a granted continuation.
    private func resumeAllowedContinue(
        _ parked: ParkedNarratedApproval,
        call: ToolInput,
        sessionID: UUID,
        onEvent: (@Sendable (OrchestratorEvent) async -> Void)? = nil
    ) async throws -> OrchestratorResponse {
        let result = ToolResult.success(toolCallID: call.callID, content: "Continuation granted by user.")
        let action = ToolAction(
            toolName: "engine.continue",
            callID: call.callID,
            argumentsJSON: call.argumentsJSON,
            result: result,
            roundIndex: parked.roundIndex
        )
        await onEvent?(.toolCompleted(
            toolName: call.toolName,
            callID: call.callID,
            result: result,
            roundIndex: parked.roundIndex
        ))
        await OrchestratorToolLoop.appendLabeledResult(
            for: nil,
            result: result,
            to: conversations,
            sessionID: sessionID,
            labelingEnabled: labelingEnabled
        )
        return try await finishParkedBatch(
            parked: parked,
            baseText: "",
            baseCompletedAt: nil,
            newAction: action,
            approved: true,
            resetToolRounds: true,
            onEvent: onEvent
        )
    }

    /// Resumes an allowed `question.ask` parked approval with the operator's choice.
    private func resumeAllowedQuestionAsk(
        _ parked: ParkedNarratedApproval,
        call: ToolInput,
        sessionID: UUID,
        answer: String?,
        onEvent: (@Sendable (OrchestratorEvent) async -> Void)? = nil
    ) async throws -> OrchestratorResponse {
        let trimmedAnswer = answer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Defense in depth: the REST boundary already caps answers, so truncate
        // here rather than failing when another resume path supplies long text.
        let chosenAnswer = trimmedAnswer.count > 2000 ? String(trimmedAnswer.prefix(2000)) : trimmedAnswer
        let content = chosenAnswer.isEmpty ? "Operator acknowledged question." : chosenAnswer
        let result = ToolResult.success(toolCallID: call.callID, content: content)
        let action = ToolAction(
            toolName: "question.ask",
            callID: call.callID,
            argumentsJSON: call.argumentsJSON,
            result: result,
            roundIndex: parked.roundIndex
        )
        await onEvent?(.toolCompleted(
            toolName: call.toolName,
            callID: call.callID,
            result: result,
            roundIndex: parked.roundIndex
        ))
        await OrchestratorToolLoop.appendLabeledResult(
            for: nil,
            result: result,
            to: conversations,
            sessionID: sessionID,
            labelingEnabled: labelingEnabled
        )
        return try await finishParkedBatch(
            parked: parked,
            baseText: "",
            baseCompletedAt: nil,
            newAction: action,
            approved: true,
            resetToolRounds: true,
            onEvent: onEvent
        )
    }

    /// Resumes an allowed `desktop.resume` parked approval with a fresh capture.
    ///
    /// Fail-closed fresh capture: automation never resumes on a stale display.
    /// A missing screenshot tool, a thrown capture, an error output, or empty
    /// pixels ends the turn here with an honest refusal instead of synthesizing
    /// follow-up desktop actions on old observation.
    private func resumeAllowedDesktopResume(
        _ parked: ParkedNarratedApproval,
        call: ToolInput,
        sessionID: UUID,
        onEvent: (@Sendable (OrchestratorEvent) async -> Void)? = nil
    ) async throws -> OrchestratorResponse {
        let freshDisplay = await freshDesktopDisplaySection(sessionID: sessionID)
        guard let freshSection = freshDisplay else {
            return try await resumeDeniedDesktopResume(parked, call: call, sessionID: sessionID, onEvent: onEvent)
        }
        let resumeContent =
            "Continuation granted: Desktop automation resumed after operator takeover."
                + freshSection
        let result = ToolResult.success(toolCallID: call.callID, content: resumeContent)
        let action = ToolAction(
            toolName: "desktop.resume",
            callID: call.callID,
            argumentsJSON: call.argumentsJSON,
            result: result,
            roundIndex: parked.roundIndex
        )
        await onEvent?(.toolCompleted(
            toolName: call.toolName,
            callID: call.callID,
            result: result,
            roundIndex: parked.roundIndex
        ))
        await OrchestratorToolLoop.appendLabeledResult(
            for: nil,
            result: result,
            to: conversations,
            sessionID: sessionID,
            labelingEnabled: labelingEnabled
        )
        return try await finishParkedBatch(
            parked: parked,
            baseText: "",
            baseCompletedAt: nil,
            newAction: action,
            approved: true,
            resetToolRounds: true,
            onEvent: onEvent
        )
    }

    /// Captures a fresh display section for desktop resume, or nil when unavailable.
    private func freshDesktopDisplaySection(sessionID: UUID) async -> String? {
        let captureContext = ToolContext(conversationID: sessionID, approved: true)
        guard let screenshotTool = await toolBus.tool(named: "desktop.screenshot") else {
            return nil
        }
        do {
            let output = try await screenshotTool.execute(
                input: ToolInput(toolName: "desktop.screenshot", argumentsJSON: "{}"),
                context: captureContext
            )
            let pixels = output.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !output.isError, !pixels.isEmpty else {
                return nil
            }
            return "\n\n[Fresh Display State]:\n\(output.content)\n\nInspect the updated screen layout before taking further action."
        } catch {
            return nil
        }
    }

    /// Finishes a desktop resume refused for lack of a fresh screenshot.
    private func resumeDeniedDesktopResume(
        _ parked: ParkedNarratedApproval,
        call: ToolInput,
        sessionID: UUID,
        onEvent: (@Sendable (OrchestratorEvent) async -> Void)? = nil
    ) async throws -> OrchestratorResponse {
        let refusal =
            "Desktop resume refused: fresh screenshot unavailable, so automation remains paused on a stale display. "
                + "No further desktop actions were taken. Capture a fresh screenshot, then re-approve resume."
        let refusalResult = ToolResult.failure(toolCallID: call.callID, content: refusal)
        await onEvent?(.toolCompleted(
            toolName: call.toolName,
            callID: call.callID,
            result: refusalResult,
            roundIndex: parked.roundIndex
        ))
        await OrchestratorToolLoop.appendLabeledResult(
            for: nil,
            result: refusalResult,
            to: conversations,
            sessionID: sessionID,
            labelingEnabled: labelingEnabled
        )
        return try await finishParkedBatch(
            parked: parked,
            baseText: refusal,
            baseCompletedAt: nil,
            newAction: nil,
            approved: false,
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
        resetToolRounds: Bool = false,
        onEvent: (@Sendable (OrchestratorEvent) async -> Void)?
    ) async throws -> OrchestratorResponse {
        let sessionID = parked.sessionID
        let batchID = parked.batchID
        if let newAction {
            bufferParkedExecutedAction(newAction, forBatch: batchID)
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
        let buffered = takeParkedExecutedActions(forBatch: batchID)
        if buffered.isEmpty {
            return OrchestratorResponse(
                text: baseText,
                sessionID: sessionID,
                toolActions: parked.priorActions,
                modelName: llm.modelInfo.name,
                contextLength: llm.modelInfo.contextLength,
                sessionTokens: sessionTokensBySession[sessionID],
                contextTokens: parked.contextTokens,
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
        await conversations.removeWaitingMessages(from: sessionID)
        let workingMessages = await refreshedWorkingMessages(
            sessionID: sessionID,
            recall: parked.recall,
            starterPack: parked.starterPack,
            systemPrompt: prompt
        )
        var pendingEpisodic: [(content: String, role: Message.Role)] = []
        let combinedActions = parked.priorActions + buffered
        let initialRounds = resetToolRounds ? 0 : parked.toolRounds
        let resumedBashConfig = await admissionGate?.bashConfigSnapshot()
        let resumedWorkspaceRoot = await admissionGate?.workspaceRootSnapshot()
        let request = TurnLoopRequest(
            workingMessages: workingMessages,
            tools: tools,
            recall: parked.recall,
            starterPack: parked.starterPack,
            sessionID: sessionID,
            systemPrompt: prompt,
            onEvent: onEvent,
            initialToolActions: combinedActions,
            priorBilledTokens: parked.billedTokens,
            initialToolRounds: initialRounds,
            initialLlmRoundIndex: parked.synthesisRoundIndex,
            bashConfig: resumedBashConfig,
            workspaceRoot: resumedWorkspaceRoot,
            strictRegistry: strictContainerRegistry
        )
        do {
            let outcome = try await runTurnLoop(request, pendingEpisodic: &pendingEpisodic)
            switch outcome {
            case let .parked(parkedResponse):
                return parkedResponse
            case let .finished(finalText, toolActions, loopBilled, contextTokens, isBudgetExceeded, reasoning):
                return try await finishResumedTurn(
                    finalText: finalText,
                    reasoning: reasoning,
                    toolActions: toolActions,
                    loopBilled: loopBilled,
                    contextTokens: contextTokens,
                    parked: parked,
                    resumeWarnings: resumeWarnings,
                    pendingEpisodic: &pendingEpisodic,
                    isBudgetExceeded: isBudgetExceeded
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
        let buffered = parkedExecutedActions(forBatch: parked.batchID)
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
            contextTokens: parked.contextTokens,
            isParked: true,
            warnings: context.warnings,
            completedAt: nil
        )
    }

    private func finishResumedTurn(
        finalText: String,
        reasoning: String? = nil,
        toolActions: [ToolAction],
        loopBilled: Int?,
        contextTokens: Int? = nil,
        parked: ParkedNarratedApproval,
        resumeWarnings: [String],
        pendingEpisodic: inout [(content: String, role: Message.Role)],
        isBudgetExceeded: Bool = false
    ) async throws -> OrchestratorResponse {
        let sessionID = parked.sessionID
        let finalNote = await storeFinalAssistantText(finalText, reasoning: reasoning, sessionID: sessionID, pendingEpisodic: &pendingEpisodic)
        try Task.checkCancellation()
        await flushEpisodic(pendingEpisodic, sessionID: sessionID)
        let cumulative = accumulateSessionTokens(loopBilled, for: sessionID)
        await admissionGate?.clearTaskGrants(for: sessionID)
        // A zero occupancy report carries no pressure signal, so the resumed
        // turn keeps the parked estimate instead of dropping the gauge to 0%.
        let resumedContextTokens: Int? =
            if (contextTokens ?? 0) > 0 {
                contextTokens
            } else if (parked.contextTokens ?? 0) > 0 {
                parked.contextTokens
            } else {
                nil
            }
        return OrchestratorResponse(
            text: finalText,
            sessionID: sessionID,
            toolActions: toolActions,
            totalTokens: Self.combinedTurnTokens(parked.billedTokens, loopBilled),
            modelName: llm.modelInfo.name,
            contextLength: llm.modelInfo.contextLength,
            sessionTokens: cumulative,
            contextTokens: resumedContextTokens,
            isParked: false,
            warnings: resumeWarnings,
            completedAt: finalNote?.createdAt.timeIntervalSince1970,
            isBudgetExceeded: isBudgetExceeded
        )
    }

    /// Resolves the synthesis prompt for a parked turn.
    /// Reuses an explicit operator override verbatim, otherwise recomposes from the live
    /// registry with the model's vision branch so resumed synthesis advertises the same
    /// tools as its wire even when toggles landed while parked.
    private func resolveParkedSynthesisPrompt(_ parked: ParkedNarratedApproval) async -> String? {
        if let stored = parked.systemPrompt, !stored.isEmpty, !SystemPromptComposer.isComposedPrompt(stored) {
            return stored
        }
        if let stored = systemPrompt, !stored.isEmpty, !SystemPromptComposer.isComposedPrompt(stored) {
            return stored
        }
        let tools = await VisionSchemaFilter.sortedByName(toolBus.availableTools(), name: { $0.name })
        let source = await conversations.session(id: parked.sessionID)?.source
        let supportsVision = llm.modelInfo.supportsVision
        if Orchestrator.isBackgroundSource(source) {
            return SystemPromptComposer.composeScheduled(tools: tools, supportsVision: supportsVision, persona: persona)
        }
        return SystemPromptComposer.compose(tools: tools, supportsVision: supportsVision, persona: persona)
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
    ) async -> Message {
        await conversations.removeWaitingMessages(from: sessionID)
        let denial = OrchestratorToolLoop.deniedApprovalMessage(for: call.toolName)
        let note = Message(role: .assistant, content: denial)
        let persisted = await conversations.append(note, to: sessionID)
        await onEvent?(.textDelta(denial))
        await flushEpisodic([(denial, .assistant)], sessionID: sessionID)
        return persisted
    }

    /// Records a missing-tool notice for an allowed parked call.
    private func recordParkedMissingTool(
        _ toolName: String,
        sessionID: UUID,
        onEvent: (@Sendable (OrchestratorEvent) async -> Void)?
    ) async -> Message {
        let missing = "Approval allowed for \(toolName), but the tool is no longer available."
        let note = Message(role: .assistant, content: missing)
        let persisted = await conversations.append(note, to: sessionID)
        await onEvent?(.textDelta(missing))
        await flushEpisodic([(missing, .assistant)], sessionID: sessionID)
        return persisted
    }

    /// Executes one allowed parked call without re-entering the gate.
    /// The recorded decide is the authorization, so the call runs through direct
    /// tool execution bypassing the bus handler, still emitting started plus
    /// completed events and appending the labeled result for synthesis.
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
            // Parked calls bypass the bus, so the call identity the bus would have
            // stamped is applied here before the report becomes an event; a report
            // is advisory and never affects the turn's outcome.
            let context = ToolContext(conversationID: sessionID, approved: true) { progress in
                await onEvent?(.toolProgress(progress.attributed(callID: call.callID, toolName: call.toolName)))
            }
            let output = try await tool.execute(
                input: call,
                context: context
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
        await OrchestratorToolLoop.appendLabeledResult(
            for: tool,
            result: result,
            to: conversations,
            sessionID: sessionID,
            labelingEnabled: labelingEnabled
        )
        var pending: [(content: String, role: Message.Role)] = []
        if let record = OrchestratorToolLoop.episodicToolRecord(
            toolName: call.toolName,
            result: result,
            for: tool,
            labelingEnabled: labelingEnabled
        ) {
            pending.append((record, .tool))
        }
        await flushEpisodic(pending, sessionID: sessionID)
        return action
    }

    /// Parks a turn due to operator mouse takeover during desktop control.
    func parkForOperatorTakeover(
        context: ParkTurnContext,
        request: TurnLoopRequest,
        pendingEpisodic: inout [(content: String, role: Message.Role)]
    ) async -> TurnLoopOutcome {
        let resumeCall = ToolInput(
            toolName: "desktop.resume",
            argumentsJSON: "{}"
        )
        let text = context.narratedText.isEmpty
            ? "Desktop automation paused: operator took over control."
            : context.narratedText
        return await parkTurn(
            ParkTurnContext(
                gated: [resumeCall],
                narratedText: text,
                toolActions: context.toolActions,
                billedTokens: context.billedTokens,
                toolRounds: context.toolRounds,
                contextTokens: context.contextTokens,
                narrationAlreadyPersisted: context.narrationAlreadyPersisted,
                bashConfig: context.bashConfig ?? request.bashConfig,
                workspaceRoot: context.workspaceRoot ?? request.workspaceRoot
            ),
            request: request,
            pendingEpisodic: &pendingEpisodic
        )
    }

    /// Parks the turn when tool iterations exceed the allowed limit and an approval queue is present.
    ///
    /// A caller that already persisted the continuation call's placeholder (the
    /// boundary-refusal path) passes the identical prebuilt call so the park
    /// files it against that placeholder instead of minting a second identifier.
    /// The narration-persisted flag travels through so the filing path never
    /// repeats a note the caller already wrote.
    func parkForContinuation(
        toolRounds: Int,
        context: ParkTurnContext,
        continuationCall: ToolInput? = nil,
        request: TurnLoopRequest,
        pendingEpisodic: inout [(content: String, role: Message.Role)]
    ) async throws -> TurnLoopOutcome {
        guard approvalQueue != nil else {
            throw OrchestratorError.toolLoopExceeded(iterations: maxToolIterations)
        }
        // The refused attempt bumped the counter without executing, so the honest
        // completed count is one behind the refused round.
        let completedRounds = max(0, toolRounds - 1)
        let continueCall = continuationCall ?? ToolInput(
            toolName: "engine.continue",
            argumentsJSON: "{\"rounds\":\(completedRounds)}"
        )
        let text = context.narratedText.isEmpty
            ? "The agent has completed \(completedRounds) tool rounds and is requesting continuation."
            : context.narratedText
        return await parkTurn(
            ParkTurnContext(
                gated: [continueCall],
                narratedText: text,
                toolActions: context.toolActions,
                billedTokens: context.billedTokens,
                toolRounds: completedRounds,
                contextTokens: context.contextTokens,
                narrationAlreadyPersisted: context.narrationAlreadyPersisted,
                bashConfig: context.bashConfig ?? request.bashConfig,
                workspaceRoot: context.workspaceRoot ?? request.workspaceRoot
            ),
            request: request,
            pendingEpisodic: &pendingEpisodic
        )
    }

    /// Parks a turn waiting on narrated gated calls or tool loop continuation.
    func parkTurn(
        _ turn: ParkTurnContext,
        request: TurnLoopRequest,
        pendingEpisodic: inout [(content: String, role: Message.Role)]
    ) async -> TurnLoopOutcome {
        var liveBashConfig = turn.bashConfig ?? request.bashConfig
        if liveBashConfig == nil {
            liveBashConfig = await admissionGate?.bashConfigSnapshot()
        }
        var liveWorkspaceRoot = turn.workspaceRoot ?? request.workspaceRoot
        if liveWorkspaceRoot == nil {
            liveWorkspaceRoot = await admissionGate?.workspaceRootSnapshot()
        }
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
            starterPack: request.starterPack,
            onEvent: request.onEvent,
            gatedRoundIndex: turn.toolRounds,
            contextTokens: turn.contextTokens,
            narrationAlreadyPersisted: turn.narrationAlreadyPersisted,
            bashConfig: liveBashConfig,
            workspaceRoot: liveWorkspaceRoot
        )
        let parked = await parkGatedCalls(context, pendingEpisodic: &pendingEpisodic)
        return .parked(parked)
    }

    /// Files one approval request for a gated call into the approval queue.
    private func enqueueParkedRequest(
        for call: ToolInput,
        context: ParkGatedCallsContext,
        toolsByName: [String: any Tool],
        queue: ApprovalQueue,
        parkOnEvent: (@Sendable (OrchestratorEvent) async -> Void)?
    ) async -> PermissionRequest? {
        if call.toolName == "engine.continue" {
            let continuationAssessment = ImpactAssessment(
                severity: .moderate,
                outcome: "Allows the agent to proceed with additional tool execution rounds.",
                warnings: []
            )
            let continuationRequest = PermissionRequest(
                toolName: "engine.continue",
                description: "The agent has completed \(context.gatedRoundIndex) tool rounds and is requesting continuation.",
                input: call,
                suggestedDurations: [.thisTime],
                sessionID: context.sessionID,
                intent: context.narratedText.isEmpty ? nil : context.narratedText,
                assessment: continuationAssessment
            )
            await queue.enqueue(continuationRequest)
            return continuationRequest
        } else if call.toolName == "desktop.resume" {
            let resumeAssessment = ImpactAssessment(
                severity: .moderate,
                outcome: "Resumes desktop automation with a fresh display observation.",
                warnings: []
            )
            // Mouse-only copy is honest about production sensing: automatic
            // takeover is cursor displacement, with keyboard abort arriving
            // only as an explicit monitor latch rather than a live sensor.
            let resumeDesc = "Desktop automation paused because you moved the mouse. "
                + "Resume agent control to capture a fresh screenshot and continue."
            let resumeRequest = PermissionRequest(
                toolName: "desktop.resume",
                description: resumeDesc,
                input: call,
                suggestedDurations: [.thisTime],
                sessionID: context.sessionID,
                intent: context.narratedText.isEmpty ? nil : context.narratedText,
                assessment: resumeAssessment
            )
            await queue.enqueue(resumeRequest)
            return resumeRequest
        } else if let tool = toolsByName[call.toolName] {
            let intent = context.narratedText.isEmpty ? nil : context.narratedText
            return await queue.fileRequest(
                tool: tool,
                call: call,
                sessionID: context.sessionID,
                intent: intent,
                onEnriched: { updated in
                    await parkOnEvent?(.approval(updated))
                },
                bashConfig: context.bashConfig,
                workspaceRoot: context.workspaceRoot
            )
        }
        return nil
    }

    /// Files gated narrations and ends the turn parked waiting on approval.
    private func parkGatedCalls(
        _ context: ParkGatedCallsContext,
        pendingEpisodic: inout [(content: String, role: Message.Role)]
    ) async -> OrchestratorResponse {
        let validParkTools = VisionSchemaFilter.partitionValidSchemas(
            entries: context.tools,
            name: { $0.name },
            rawSchema: { $0.inputSchema.rawValue },
            logSkips: false
        ).valid
        let byName = Dictionary(validParkTools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let batchID = UUID()
        let effectiveGatedRound = context.gatedRoundIndex
        let turnTotalTokens = Self.combinedTurnTokens(context.priorBilledTokens, context.billedTokens)
        // Captured ahead of the filing loop so the enrichment rebroadcast
        // closure only captures a Sendable event sink, never the whole turn
        // context, and the enriched request travels the same approval channel.
        let parkOnEvent = context.onEvent
        if let queue = approvalQueue {
            for call in context.gated {
                guard let request = await enqueueParkedRequest(
                    for: call,
                    context: context,
                    toolsByName: byName,
                    queue: queue,
                    parkOnEvent: parkOnEvent
                ) else {
                    continue
                }
                let parkedApproval = ParkedNarratedApproval(
                    sessionID: context.sessionID,
                    toolCall: call,
                    systemPrompt: context.systemPrompt,
                    recall: context.recall,
                    starterPack: context.starterPack,
                    batchID: batchID,
                    roundIndex: effectiveGatedRound,
                    billedTokens: turnTotalTokens,
                    synthesisRoundIndex: effectiveGatedRound + 1,
                    priorActions: context.priorActions,
                    toolRounds: effectiveGatedRound,
                    contextTokens: context.contextTokens
                )
                storeParkedNarratedApproval(parkedApproval, id: request.id)
                await context.onEvent?(.approval(request))
            }
        }
        let waiting = OrchestratorToolLoop.waitingOnApprovalMessage(for: context.gated)
        // Mixed turns persisted the narration before executing their structured
        // calls, so only pure park turns (and limit continuations) own this write.
        // Appending again would duplicate the note and its call-ID placeholders.
        if !context.narrationAlreadyPersisted {
            await conversations.append(assistantNoteMessage(text: context.narratedText, calls: context.gated), to: context.sessionID)
        }
        let waitingNote = OrchestratorToolLoop.waitingNoteMessage(text: waiting)
        let persistedWaiting = await conversations.append(waitingNote, to: context.sessionID)
        pendingEpisodic.append((waiting, .assistant))
        await context.onEvent?(.textDelta(waiting))
        await flushEpisodic(pendingEpisodic, sessionID: context.sessionID)
        let cumulativeTokens = accumulateSessionTokens(context.billedTokens, for: context.sessionID)
        let pendingGatedActions = context.gated.map {
            ToolAction(toolName: $0.toolName, callID: $0.callID, argumentsJSON: $0.argumentsJSON, result: nil, roundIndex: effectiveGatedRound)
        }
        let parkedWarnings = OrchestratorToolLoop.degradedToolWarnings(for: context.tools)
        return OrchestratorResponse(
            text: waiting,
            sessionID: context.sessionID,
            toolActions: context.priorActions + pendingGatedActions,
            totalTokens: turnTotalTokens,
            modelName: llm.modelInfo.name,
            contextLength: llm.modelInfo.contextLength,
            sessionTokens: cumulativeTokens,
            contextTokens: context.contextTokens,
            isParked: true,
            warnings: parkedWarnings,
            completedAt: persistedWaiting.createdAt.timeIntervalSince1970
        )
    }
}

// Rune Weaver Core — Tool loop execution for Orchestrator.

import Foundation

/// One structured call refused before admission, with its actionable reason.
struct RefusedAdmission {
    /// The refused invocation.
    let call: ToolInput
    /// Caller-facing refusal content surfaced to the model as a failure result.
    let reason: String
}

/// Admission buckets for one round of resolved structured calls.
struct StructuredCallPartition {
    /// Calls admitted to run immediately.
    var allowed: [ToolInput] = []
    /// Calls parked for approval.
    var needsPark: [ToolInput] = []
    /// Calls refused before admission with their actionable reasons.
    var refused: [RefusedAdmission] = []
}

// MARK: - Tool loop execution

extension Orchestrator {
    // MARK: - Private helpers

    /// Ingests any user steering message submitted mid-turn before LLM round.
    private func ingestSteeringMessage(
        sessionID: UUID,
        workingMessages: inout [Message],
        pendingEpisodic: inout [(content: String, role: Message.Role)]
    ) async -> Bool {
        guard let steerText = await sharedSteeringQueue?.dequeue(for: sessionID) else { return false }
        let steerMsg = Message(role: .user, content: steerText)
        await conversations.append(steerMsg, to: sessionID)
        workingMessages.append(steerMsg)
        pendingEpisodic.append((steerText, .user))
        return true
    }

    /// Handles steering arrived mid-generation that interrupted the stream.
    private func handleMidGenerationSteering(
        sessionID: UUID,
        finalText: inout String,
        workingMessages: inout [Message],
        pendingEpisodic: inout [(content: String, role: Message.Role)]
    ) async -> Bool {
        guard await ingestSteeringMessage(
            sessionID: sessionID,
            workingMessages: &workingMessages,
            pendingEpisodic: &pendingEpisodic
        ) else { return false }
        if !finalText.isEmpty {
            let partialNote = Message(role: .assistant, content: finalText)
            await conversations.append(partialNote, to: sessionID)
            workingMessages.append(partialNote)
            pendingEpisodic.append((finalText, .assistant))
            finalText = ""
        }
        return true
    }

    /// Resolves valid tool calls for the latest assistant turn.
    /// Fail-closed on schema-degraded registered tools: a native call naming a tool whose
    /// schema was omitted for this turn must not execute. Unknown or unregistered names pass
    /// through to `ToolBus.execute`, which answers `invalid_tool` with available-tool names
    /// for self-correction; the shared denylist keeps this identical to the CLI and to the
    /// narration path.
    private func resolveCallsForTurn(
        collected: TurnDraft,
        workingMessages: [Message],
        finalText: String,
        tools: [any Tool]
    ) async throws -> [ToolInput] {
        if !collected.toolCalls.isEmpty {
            let degradedNames = OrchestratorToolLoop.degradedSchemaNames(for: tools)
            return collected.toolCalls.filter { !degradedNames.contains($0.toolName) }
        }
        return try await resolveToolCalls(messages: workingMessages, assistantText: finalText, tools: tools)
    }

    /// Collects one turn from the LLM, emits live token progress, and increments the round counter.
    private func collectAndEmitTurn(
        messages: [Message],
        llmRoundIndex: inout Int,
        billedTokens: inout Int?,
        lastRoundContextTokens: inout Int?,
        request: TurnLoopRequest
    ) async throws -> TurnDraft {
        let collected = try await collectTurn(
            messages: messages,
            tools: request.tools,
            sessionID: request.sessionID,
            onDelta: { delta in
                await request.onEvent?(.textDelta(delta))
            },
            onReasoningDelta: { reasoning in
                await request.onEvent?(.reasoningDelta(reasoning))
            }
        )
        // A zero usage report carries no occupancy signal, so it falls back to
        // the history estimate below instead of pinning the pressure gauge at 0%.
        if let billed = collected.billedTokens, billed > 0 {
            lastRoundContextTokens = billed
        }
        let roundContext = lastRoundContextTokens ?? Self.estimatedContextTokens(
            for: messages,
            tools: request.tools,
            finalText: collected.text
        )
        await emitTurnTokens(
            billed: collected.billedTokens,
            billedTokens: &billedTokens,
            roundIndex: llmRoundIndex,
            request: request,
            contextTokens: roundContext
        )
        llmRoundIndex += 1
        return collected
    }

    /// Records the assistant tool intent note and executes the resolved tool calls.
    /// When structured admission parks siblings, the note covers the full round
    /// (allowed plus needs-park) so the persisted placeholders stay paired with
    /// their filed approvals, while execution still runs only allowed-now.
    private func recordAndExecuteCalls(
        calls: [ToolInput],
        finalText: String,
        toolRounds: Int,
        request: TurnLoopRequest,
        pendingEpisodic: inout [(content: String, role: Message.Role)],
        noteCalls: [ToolInput]? = nil
    ) async throws -> [ToolAction] {
        let noteInputs = noteCalls ?? calls
        let assistantNote = assistantNoteMessage(text: finalText, calls: noteInputs)
        await conversations.append(assistantNote, to: request.sessionID)
        return try await executeToolCalls(
            calls,
            sessionID: request.sessionID,
            roundIndex: toolRounds - 1,
            onEvent: request.onEvent,
            pendingEpisodic: &pendingEpisodic,
            isDryRun: request.isDryRun
        )
    }

    /// Splits resolved structured calls into immediately runnable, needs-park,
    /// and refused-before-admission buckets.
    /// Every enabled tool with a resolvable definition is evaluated through the
    /// permission gate: a call whose verdict is requiresApproval parks when the turn
    /// is live (inbox present, not a dry run), whether approval is demanded by the
    /// tool level or by an unlisted egress host reported for a read-only network
    /// tool. A tool declaring pre-admission validation is consulted before the
    /// gate, so an invalid target (a name-shaped `messages.send`) is refused with
    /// actionable candidates and never reaches the approvals inbox or a durable
    /// trust grant. Everything else stays allowed-now so unknown, disabled,
    /// denied, covering-grant, and preview paths keep their existing ToolBus
    /// behavior.
    /// Fail-closed: a missing gate or inbox never parks.
    private func partitionStructuredCalls(
        _ calls: [ToolInput],
        isDryRun: Bool,
        sessionID: UUID?
    ) async -> StructuredCallPartition {
        guard !isDryRun, approvalQueue != nil, let gate = admissionGate else {
            return StructuredCallPartition(allowed: calls)
        }
        var partition = StructuredCallPartition()
        for call in calls {
            guard let tool = await toolBus.tool(named: call.toolName) else {
                partition.allowed.append(call)
                continue
            }
            guard await toolBus.isToolEnabled(named: call.toolName) else {
                partition.allowed.append(call)
                continue
            }
            // Pre-admission validation runs before the gate verdict so an invalid
            // target is answered directly instead of parking: no approval row is
            // filed and no durable grant can be keyed on it.
            if let validator = tool as? any ToolAdmissionValidating,
               case let .refuse(reason) = await validator.admissionVerdict(for: call)
            {
                partition.refused.append(RefusedAdmission(call: call, reason: reason))
                continue
            }
            let verdict = await gate.checkPermission(toolCall: call, tool: tool, sessionID: sessionID)
            if case .requiresApproval = verdict {
                partition.needsPark.append(call)
            } else {
                partition.allowed.append(call)
            }
        }
        return partition
    }

    /// Preflights narrated calls demanding approval before admission.
    ///
    /// Narrated tool calls that demand approval must validate before filing:
    /// an invalid target (e.g. name-shaped `messages.send`) is refused with
    /// candidates directly without polluting the approvals inbox or waiting
    /// on human review. Calls for tools without pre-admission validation, or
    /// whose validation succeeds, pass through admitted for parking.
    private func preflightNarratedGatedCalls(_ calls: [ToolInput]) async -> (admitted: [ToolInput], refused: [RefusedAdmission]) {
        var admitted: [ToolInput] = []
        var refused: [RefusedAdmission] = []
        for call in calls {
            guard let tool = await toolBus.tool(named: call.toolName),
                  let validator = tool as? any ToolAdmissionValidating
            else {
                admitted.append(call)
                continue
            }
            if case let .refuse(reason) = await validator.admissionVerdict(for: call) {
                refused.append(RefusedAdmission(call: call, reason: reason))
            } else {
                admitted.append(call)
            }
        }
        return (admitted, refused)
    }

    /// Builds a park context from the current loop state.
    private func makeParkContext(
        gated: [ToolInput],
        text: String,
        actions: [ToolAction],
        toolRounds: Int,
        tokens: (Int?, Int?),
        narrationAlreadyPersisted: Bool = false
    ) -> ParkTurnContext {
        ParkTurnContext(
            gated: gated,
            narratedText: text,
            toolActions: actions,
            billedTokens: tokens.0,
            toolRounds: toolRounds,
            contextTokens: tokens.1,
            narrationAlreadyPersisted: narrationAlreadyPersisted
        )
    }

    /// Estimates active window occupancy for status reporting from the working
    /// history, registered tools, plus the pending completion. Reuses the history compaction
    /// heuristic so the status-bar percent reflects window pressure, kept
    /// separate from cumulative billed totals and per-round provider usage.
    private static func estimatedContextTokens(
        for workingMessages: [Message],
        tools: [any Tool] = [],
        finalText: String
    ) -> Int {
        var sizing = workingMessages
        if !finalText.isEmpty {
            sizing.append(Message(role: .assistant, content: finalText))
        }
        var tokens = ConversationManager.estimateTokens(in: sizing)
        if !tools.isEmpty {
            tokens += ConversationManager.estimateToolTokens(in: tools)
        }
        return tokens
    }

    /// Parks the turn when gated narrations require approval.
    ///
    /// Dry-run previews never park: they render would-act envelopes through
    /// the bus instead of filing approvals.
    private func parkTurnIfGated(
        context: ParkTurnContext,
        request: TurnLoopRequest,
        pendingEpisodic: inout [(content: String, role: Message.Role)]
    ) async -> TurnLoopOutcome? {
        guard !request.isDryRun, !context.gated.isEmpty, approvalQueue != nil else { return nil }
        return await parkTurn(context, request: request, pendingEpisodic: &pendingEpisodic)
    }

    /// Parks the turn if tool iterations exceed the allowed limit.
    ///
    /// A boundary round can also refuse calls before admission. Those refusals
    /// must not be lost to the park: the round note and its refusal results are
    /// persisted and folded into the park context before returning, so history,
    /// the response actions, and the resumed model all see the actionable
    /// candidates instead of retrying a call the tool already rejected. The
    /// continuation call is built here so its placeholder rides the same single
    /// round note, mirroring a non-boundary refusals round.
    private func checkLimitAndPark(
        toolRounds: Int,
        parkContext: ParkTurnContext,
        refusedCalls: [RefusedAdmission],
        request: TurnLoopRequest,
        pendingEpisodic: inout [(content: String, role: Message.Role)]
    ) async throws -> TurnLoopOutcome? {
        let maxLimit = request.effectiveMaxToolIterations ?? maxToolIterations
        guard OrchestratorToolLoop.isLimitExceeded(rounds: toolRounds, max: maxLimit) else { return nil }
        if request.toolLimitPolicy == .forceSynthesis {
            return try await forceSynthesisForBudgetLimit(
                toolRounds: toolRounds,
                maxLimit: maxLimit,
                parkContext: parkContext,
                refusedCalls: refusedCalls,
                request: request,
                pendingEpisodic: &pendingEpisodic
            )
        }
        guard !refusedCalls.isEmpty else {
            return try await parkForContinuation(
                toolRounds: toolRounds,
                context: parkContext,
                request: request,
                pendingEpisodic: &pendingEpisodic
            )
        }
        // The refused attempt bumped the counter without executing, so the honest
        // completed count is one behind the refused round.
        let completedRounds = max(0, toolRounds - 1)
        let continueCall = ToolInput(
            toolName: "engine.continue",
            argumentsJSON: "{\"rounds\":\(completedRounds)}"
        )
        // Narration plus every recorded placeholder lands in one assistant note;
        // narrated refusals already carry their placeholder line in the text and
        // are not duplicated, while structured refusals and the continuation call
        // get theirs appended, so each result below has a preceding placeholder.
        let refusalNote = assistantNoteMessage(
            text: parkContext.narratedText,
            calls: refusedCalls.map(\.call) + [continueCall]
        )
        await conversations.append(refusalNote, to: request.sessionID)
        let refusedActions = try await recordRefusedAdmissions(
            refusedCalls,
            roundIndex: toolRounds - 1,
            request: request,
            pendingEpisodic: &pendingEpisodic
        )
        let refusalsContext = ParkTurnContext(
            gated: parkContext.gated,
            narratedText: parkContext.narratedText,
            toolActions: parkContext.toolActions + refusedActions,
            billedTokens: parkContext.billedTokens,
            toolRounds: parkContext.toolRounds,
            contextTokens: parkContext.contextTokens,
            narrationAlreadyPersisted: true
        )
        return try await parkForContinuation(
            toolRounds: toolRounds,
            context: refusalsContext,
            continuationCall: continueCall,
            request: request,
            pendingEpisodic: &pendingEpisodic
        )
    }

    /// Injects diagnostic synthesis instruction when budget limit is reached, suppresses further tool execution,
    /// and completes the turn marked with `isBudgetExceeded: true`.
    private func forceSynthesisForBudgetLimit(
        toolRounds: Int,
        maxLimit: Int,
        parkContext: ParkTurnContext,
        refusedCalls: [RefusedAdmission],
        request: TurnLoopRequest,
        pendingEpisodic: inout [(content: String, role: Message.Role)]
    ) async throws -> TurnLoopOutcome {
        let completedRounds = max(0, toolRounds - 1)
        var updatedActions = parkContext.toolActions
        if !refusedCalls.isEmpty {
            let refusalNote = assistantNoteMessage(
                text: parkContext.narratedText,
                calls: refusedCalls.map(\.call)
            )
            await conversations.append(refusalNote, to: request.sessionID)
            let refusedActions = try await recordRefusedAdmissions(
                refusedCalls,
                roundIndex: toolRounds - 1,
                request: request,
                pendingEpisodic: &pendingEpisodic
            )
            updatedActions.append(contentsOf: refusedActions)
        }

        var workingMessages = await refreshedWorkingMessages(
            sessionID: request.sessionID,
            recall: request.recall,
            starterPack: request.starterPack,
            systemPrompt: request.systemPrompt
        )

        let notice = Message(
            role: .system,
            content: """
            [System Notice]: Maximum tool iteration budget reached (\(completedRounds)/\(maxLimit) rounds). Tool execution is terminated for this turn.
            1. Explicitly identify which requested actions were completed and which were NOT completed (e.g. unsent messages, incomplete exports).
            2. Present the full draft or compiled data collected so far so the user can inspect or manually deliver it.
            """
        )
        workingMessages.append(notice)

        let synthesisDraft = try await collectTurn(
            messages: workingMessages,
            tools: [],
            sessionID: request.sessionID,
            onDelta: { delta in
                await request.onEvent?(.textDelta(delta))
            },
            onReasoningDelta: { reasoning in
                await request.onEvent?(.reasoningDelta(reasoning))
            }
        )

        let totalBilled = (parkContext.billedTokens ?? 0) + (synthesisDraft.billedTokens ?? 0)
        let effectiveBilled = totalBilled > 0 ? totalBilled : nil
        let contextTokens = parkContext.contextTokens ?? Self.estimatedContextTokens(
            for: workingMessages,
            tools: [],
            finalText: synthesisDraft.text
        )

        return .finished(
            finalText: synthesisDraft.text,
            toolActions: updatedActions,
            billedTokens: effectiveBilled,
            contextTokens: contextTokens,
            isBudgetExceeded: true
        )
    }

    /// Handles an empty assistant round following tool execution, attempting a synthesis prompt
    /// or falling back to a generic completion notice.
    /// Reasoning is intentionally never promoted to final text so chain-of-thought
    /// stays out of the user-visible answer, episodic memory, and audit trail.
    /// - Returns: True if an empty-round synthesis prompt was queued and the loop should continue.
    private func handleEmptyRoundAfterTools(
        toolActions: [ToolAction],
        finalText: inout String,
        attemptedEmptyRoundSynthesis: inout Bool,
        workingMessages: inout [Message],
        onEvent: (@Sendable (OrchestratorEvent) async -> Void)?
    ) async -> Bool {
        guard !toolActions.isEmpty, finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        if !attemptedEmptyRoundSynthesis {
            attemptedEmptyRoundSynthesis = true
            workingMessages.append(Message(
                role: .system,
                content: "[System Notice]: Tool execution finished. Please summarize the results or provide your final response to the user."
            ))
            return true
        }
        finalText = "Tool execution completed."
        await onEvent?(.textDelta(finalText))
        return false
    }

    private struct RoundAdmissions {
        let allowed: [ToolInput]
        let combinedGated: [ToolInput]
        let refusedCalls: [RefusedAdmission]
    }

    private func evaluateRoundAdmissions(
        calls: [ToolInput],
        narratedGated: [ToolInput],
        isDryRun: Bool,
        sessionID: UUID?
    ) async -> RoundAdmissions {
        let partition = await partitionStructuredCalls(
            calls,
            isDryRun: isDryRun,
            sessionID: sessionID
        )
        var admittedNarrated = narratedGated
        var refusedNarrated: [RefusedAdmission] = []
        if !isDryRun {
            let narratedPreflight = await preflightNarratedGatedCalls(narratedGated)
            admittedNarrated = narratedPreflight.admitted
            refusedNarrated = narratedPreflight.refused
        }
        let refusedCalls = partition.refused + refusedNarrated
        let combinedGated = isDryRun ? [] : partition.needsPark + admittedNarrated
        return RoundAdmissions(
            allowed: partition.allowed,
            combinedGated: combinedGated,
            refusedCalls: refusedCalls
        )
    }

    private func parkTurnOrHandleLimit(
        admissions: RoundAdmissions,
        parkContext: ParkTurnContext,
        toolRounds: inout Int,
        request: TurnLoopRequest,
        pendingEpisodic: inout [(content: String, role: Message.Role)]
    ) async throws -> (outcome: TurnLoopOutcome?, shouldStop: Bool) {
        if admissions.allowed.isEmpty, admissions.refusedCalls.isEmpty {
            if !admissions.combinedGated.isEmpty {
                if let parked = await parkTurnIfGated(context: parkContext, request: request, pendingEpisodic: &pendingEpisodic) {
                    return (parked, true)
                }
            }
            return (nil, true)
        }
        toolRounds += 1
        let activeContext = ParkTurnContext(
            gated: parkContext.gated,
            narratedText: parkContext.narratedText,
            toolActions: parkContext.toolActions,
            billedTokens: parkContext.billedTokens,
            toolRounds: toolRounds,
            contextTokens: parkContext.contextTokens,
            narrationAlreadyPersisted: parkContext.narrationAlreadyPersisted
        )
        if let outcome = try await checkLimitAndPark(
            toolRounds: toolRounds,
            parkContext: activeContext,
            refusedCalls: admissions.refusedCalls,
            request: request,
            pendingEpisodic: &pendingEpisodic
        ) {
            return (outcome, true)
        }
        return (nil, false)
    }

    private func executeAndRecordRoundCalls(
        admissions: RoundAdmissions,
        noteCalls: [ToolInput],
        finalText: String,
        toolRounds: Int,
        request: TurnLoopRequest,
        pendingEpisodic: inout [(content: String, role: Message.Role)]
    ) async throws -> [ToolAction] {
        let executed = try await recordAndExecuteCalls(
            calls: admissions.allowed,
            finalText: finalText,
            toolRounds: toolRounds,
            request: request,
            pendingEpisodic: &pendingEpisodic,
            noteCalls: noteCalls
        )
        let recordedRefused = try await recordRefusedAdmissions(
            admissions.refusedCalls,
            roundIndex: toolRounds - 1,
            request: request,
            pendingEpisodic: &pendingEpisodic
        )
        return executed + recordedRefused
    }

    /// Runs the bounded tool loop for one turn until final text or parking.
    func runTurnLoop(
        _ request: TurnLoopRequest,
        pendingEpisodic: inout [(content: String, role: Message.Role)]
    ) async throws -> TurnLoopOutcome {
        var workingMessages = request.workingMessages
        var toolActions = request.initialToolActions
        var finalText = ""
        var toolRounds = request.initialToolRounds
        var billedTokens: Int?
        var lastRoundContextTokens: Int?
        var llmRoundIndex = request.initialLlmRoundIndex
        var attemptedEmptyRoundSynthesis = false

        while true {
            let (collected, shouldRetry) = try await stepTurnGeneration(
                request: request,
                workingMessages: &workingMessages,
                pendingEpisodic: &pendingEpisodic,
                llmRoundIndex: &llmRoundIndex,
                billedTokens: &billedTokens,
                lastRoundContextTokens: &lastRoundContextTokens
            )
            finalText = collected.text
            if shouldRetry {
                continue
            }

            let calls = try await resolveCallsForTurn(
                collected: collected,
                workingMessages: workingMessages,
                finalText: finalText,
                tools: request.tools
            )
            let narratedGated = OrchestratorToolLoop.narratedGatedCalls(from: finalText, tools: request.tools)
            if calls.isEmpty, narratedGated.isEmpty {
                // Collected reasoning stays out of the empty-round path by design.
                let shouldContinue = await handleEmptyRoundAfterTools(
                    toolActions: toolActions,
                    finalText: &finalText,
                    attemptedEmptyRoundSynthesis: &attemptedEmptyRoundSynthesis,
                    workingMessages: &workingMessages,
                    onEvent: request.onEvent
                )
                if shouldContinue {
                    continue
                }
                break
            }
            // Parked frames carry the latest round's context tokens (or fallback estimate)
            // so approval pauses report window pressure instead of cumulative cost.
            let currentContextTokens = lastRoundContextTokens ?? Self.estimatedContextTokens(
                for: workingMessages, tools: request.tools, finalText: finalText
            )
            let tokens = (billedTokens, currentContextTokens)
            let admissions = await evaluateRoundAdmissions(
                calls: calls,
                narratedGated: narratedGated,
                isDryRun: request.isDryRun,
                sessionID: request.sessionID
            )
            let parkContext = makeParkContext(
                gated: admissions.combinedGated, text: finalText, actions: toolActions, toolRounds: toolRounds, tokens: tokens
            )
            let (dispositionOutcome, shouldStop) = try await parkTurnOrHandleLimit(
                admissions: admissions,
                parkContext: parkContext,
                toolRounds: &toolRounds,
                request: request,
                pendingEpisodic: &pendingEpisodic
            )
            if let dispositionOutcome {
                return dispositionOutcome
            }
            if shouldStop {
                break
            }
            let roundActions = try await executeAndRecordRoundCalls(
                admissions: admissions,
                noteCalls: calls,
                finalText: finalText,
                toolRounds: toolRounds,
                request: request,
                pendingEpisodic: &pendingEpisodic
            )
            toolActions.append(contentsOf: roundActions)
            // The executed call already wrote this turn's narration note, so the
            // sibling gated calls must park without persisting it a second time.
            let updatedContext = makeParkContext(
                gated: admissions.combinedGated, text: finalText, actions: toolActions, toolRounds: toolRounds, tokens: tokens,
                narrationAlreadyPersisted: true
            )
            if let parked = await parkTurnIfGated(context: updatedContext, request: request, pendingEpisodic: &pendingEpisodic) {
                return parked
            }
            workingMessages = await refreshedWorkingMessages(
                sessionID: request.sessionID,
                recall: request.recall,
                starterPack: request.starterPack,
                systemPrompt: request.systemPrompt
            )
            finalText = ""
            continue
        }
        // Finished turns advertise the latest round's active context window occupancy
        // (falling back to working-history + tools estimate when provider usage is absent)
        // so contextTokens divided by the model limit reflects window pressure, kept
        // separate from the cumulative billed total carried alongside it.
        let contextTokens = lastRoundContextTokens ?? Self.estimatedContextTokens(
            for: workingMessages, tools: request.tools, finalText: finalText
        )
        return .finished(finalText: finalText, toolActions: toolActions, billedTokens: billedTokens, contextTokens: contextTokens)
    }

    private func stepTurnGeneration(
        request: TurnLoopRequest,
        workingMessages: inout [Message],
        pendingEpisodic: inout [(content: String, role: Message.Role)],
        llmRoundIndex: inout Int,
        billedTokens: inout Int?,
        lastRoundContextTokens: inout Int?
    ) async throws -> (collected: TurnDraft, shouldRetrySteer: Bool) {
        try Task.checkCancellation()
        _ = await ingestSteeringMessage(
            sessionID: request.sessionID,
            workingMessages: &workingMessages,
            pendingEpisodic: &pendingEpisodic
        )
        let collected = try await collectAndEmitTurn(
            messages: workingMessages,
            llmRoundIndex: &llmRoundIndex,
            billedTokens: &billedTokens,
            lastRoundContextTokens: &lastRoundContextTokens,
            request: request
        )
        var text = collected.text
        let shouldRetry = await handleMidGenerationSteering(
            sessionID: request.sessionID,
            finalText: &text,
            workingMessages: &workingMessages,
            pendingEpisodic: &pendingEpisodic
        )
        let draft = TurnDraft(text: text, billedTokens: collected.billedTokens, toolCalls: collected.toolCalls)
        return (draft, shouldRetry)
    }

    /// Executes tool calls in sequence, publishing real-time events and recording outcomes.
    /// Dry-run turns preview through the same bus path so gated calls keep their
    /// would-act envelopes instead of filing approvals.
    private func executeToolCalls(
        _ calls: [ToolInput],
        sessionID: UUID,
        roundIndex: Int,
        onEvent: (@Sendable (OrchestratorEvent) async -> Void)?,
        pendingEpisodic: inout [(content: String, role: Message.Role)],
        isDryRun: Bool = false
    ) async throws -> [ToolAction] {
        var actions: [ToolAction] = []
        var executedCallIDs = Set<String>()
        // Forward advisory progress as a session-tagged event so the dashboard can
        // show a slow tool still working. The bus stamps each report with the
        // authoritative call identity before it reaches this sink, so the closure
        // only relays; a report never affects the turn's outcome.
        let context = ToolContext(conversationID: sessionID, dryRun: isDryRun) { progress in
            await onEvent?(.toolProgress(progress))
        }
        do {
            for call in calls {
                try Task.checkCancellation()
                await onEvent?(.toolStarted(
                    toolName: call.toolName,
                    callID: call.callID,
                    argumentsJSON: call.argumentsJSON,
                    roundIndex: roundIndex
                ))
                // A per-call cancellation surfaces from the bus as an ordinary failure
                // result, so the loop records it and keeps going; only turn-level
                // cancellation throws past the check below and aborts the turn.
                let result = await toolBus.execute(toolCall: call, context: context)
                let action = ToolAction(
                    toolName: call.toolName,
                    callID: call.callID,
                    argumentsJSON: call.argumentsJSON,
                    result: result,
                    roundIndex: roundIndex
                )
                actions.append(action)
                executedCallIDs.insert(call.callID)
                await onEvent?(.toolCompleted(
                    toolName: call.toolName,
                    callID: call.callID,
                    result: result,
                    roundIndex: roundIndex
                ))
                // Declaration-driven labeling: untrusted web/browser/mail/api bytes
                // enter model context delimited as data while trusted bytes pass
                // through byte-identical, honoring `[security] untrusted_labeling`.
                let tool = await OrchestratorToolLoop.appendLabeledResult(
                    on: toolBus,
                    to: conversations,
                    toolName: call.toolName,
                    result: result,
                    sessionID: sessionID,
                    labelingEnabled: labelingEnabled
                )
                if let record = OrchestratorToolLoop.episodicToolRecord(
                    toolName: call.toolName,
                    result: result,
                    for: tool,
                    labelingEnabled: labelingEnabled
                ) {
                    pendingEpisodic.append((record, .tool))
                }
                try Task.checkCancellation()
            }
            return actions
        } catch {
            // Synthesize cancelled tool results for any unexecuted calls in the batch
            // so an assistant message announcing multiple tool calls is never left with
            // missing tool responses in persistent history.
            for call in calls where !executedCallIDs.contains(call.callID) {
                let cancelledResult = ToolResult(
                    toolCallID: call.callID,
                    content: "Tool execution cancelled",
                    isError: true
                )
                await OrchestratorToolLoop.appendLabeledResult(
                    on: toolBus,
                    to: conversations,
                    toolName: call.toolName,
                    result: cancelledResult,
                    sessionID: sessionID,
                    labelingEnabled: labelingEnabled
                )
            }
            throw error
        }
    }

    /// Records pre-admission refusals as immediate failure results.
    ///
    /// A refused call never enters the approvals inbox and never executes, so
    /// the loop answers it directly: the model receives the actionable reason
    /// as a normal tool result and can retry with a valid target. Events mirror
    /// a bus execution (started then completed failure) so live clients render
    /// the call like any other terminal tool failure, and the result rides the
    /// producing tool's declared trust level so candidate-bearing refusals stay
    /// labeled data in model context.
    /// - Parameters:
    ///   - refusals: Calls refused by their tool's pre-admission verdict.
    ///   - roundIndex: Zero-based LLM round that produced the calls.
    ///   - request: Owning turn request carrying the event sink and session.
    ///   - pendingEpisodic: Buffered episodic records receiving the refusal mirror.
    /// - Returns: Recorded refusal actions in call order.
    private func recordRefusedAdmissions(
        _ refusals: [RefusedAdmission],
        roundIndex: Int,
        request: TurnLoopRequest,
        pendingEpisodic: inout [(content: String, role: Message.Role)]
    ) async throws -> [ToolAction] {
        var actions: [ToolAction] = []
        for refusal in refusals {
            try Task.checkCancellation()
            let call = refusal.call
            await request.onEvent?(.toolStarted(
                toolName: call.toolName,
                callID: call.callID,
                argumentsJSON: call.argumentsJSON,
                roundIndex: roundIndex
            ))
            let result = ToolResult(toolCallID: call.callID, content: refusal.reason, isError: true)
            actions.append(ToolAction(
                toolName: call.toolName,
                callID: call.callID,
                argumentsJSON: call.argumentsJSON,
                result: result,
                roundIndex: roundIndex
            ))
            await request.onEvent?(.toolCompleted(
                toolName: call.toolName,
                callID: call.callID,
                result: result,
                roundIndex: roundIndex
            ))
            let tool = await OrchestratorToolLoop.appendLabeledResult(
                on: toolBus,
                to: conversations,
                toolName: call.toolName,
                result: result,
                sessionID: request.sessionID,
                labelingEnabled: labelingEnabled
            )
            if let record = OrchestratorToolLoop.episodicToolRecord(
                toolName: call.toolName,
                result: result,
                for: tool,
                labelingEnabled: labelingEnabled
            ) {
                pendingEpisodic.append((record, .tool))
            }
        }
        return actions
    }
}

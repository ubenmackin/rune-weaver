// Rune Weaver Core — Turn orchestration and tool execution loop.

import Foundation
import os

/// Core orchestration loop: input, context, LLM, tools, response.
public actor Orchestrator {
    /// Session and history owner.
    private let conversationManager: ConversationManager
    /// Tool registry and permission gate.
    private let toolRegistry: ToolBus
    /// LLM backend serving completions.
    private let languageProvider: any LLMProvider
    /// Developer instructions prepended to every turn.
    private let storedSystemPrompt: String?
    /// Maximum tool-call rounds per response, plus one final synthesis turn.
    /// Readable module-wide for progress reporting but writable only through
    /// ``updateMaxToolIterations(_:)`` so no caller can park an out-of-range
    /// budget and bypass the shared clamp.
    private(set) var maxToolIterations: Int
    /// Optional resolver mapping an assistant turn to tool calls.
    private let toolResolver: OrchestratorToolResolver?
    /// Episodic mirror for every turn, when configured.
    private let memoryEngine: MemoryEngine?
    /// Optional embeddings producer for vector-ranked automatic recall.
    private let embedder: (any EmbeddingsBackend)?
    /// Context window compaction threshold percentage (10-100).
    /// Mutable so persisted settings changes apply to the live engine without
    /// requiring a restart; writes go through the updater below to keep the
    /// validated range invariant.
    private var compactionPercent: Int
    /// Queue receiving narrated gated calls, when configured.
    private let approvalInbox: ApprovalQueue?
    /// Parked gated narrations indexed by approval request identifier.
    /// Mutated only through `takeParkedNarratedApproval(id:)` and
    /// `storeParkedNarratedApproval(_:id:)` so resume decisions cannot drop or
    /// duplicate a sibling approval filed in the same batch.
    private(set) var parkedNarratedApprovals: [UUID: ParkedNarratedApproval] = [:]
    /// Executed gated actions buffered per parked batch while siblings stay pending.
    /// Mutated only through the buffer/take helpers so a batch never half-clears.
    private(set) var parkedBatchExecutedActions: [UUID: [ToolAction]] = [:]
    /// Cumulative billed tokens tracked per session.
    /// Mutated only through `accumulateSessionTokens(_:for:)` and the session
    /// removal helpers so eviction order and non-negative invariants hold.
    private(set) var sessionTokensBySession: [UUID: Int] = [:]
    /// Access order for token totals, oldest first.
    private var sessionTokenOrder: [UUID] = []
    /// Bounds token totals so deleted sessions never leak memory.
    private static let maxTrackedSessions = 500
    /// Mid-turn steering queue for injecting user guidance into running loops.
    /// Held nonisolated so the service layer can verify identity synchronously
    /// at context construction; safe because the reference never mutates after
    /// init and the queue actor guards its own mutable state.
    private nonisolated let steeringQueue: SteeringQueue?
    /// Defense policy carrying the `[security] untrusted_labeling` off-switch.
    /// Stored so every tool-result message conversion honors the configured
    /// labeling posture instead of a hardcoded default.
    private let securityConfig: SecurityConfig
    /// Graduated-trust gate consulted for structured admission.
    /// Held alongside the bus so the turn loop can partition requiresApproval calls
    /// before execution; callers pass the same instance the bus consults so covering
    /// grants agree. Nil keeps the legacy execute path with zero parking.
    private let permissionGate: PermissionGate?

    /// Creates an orchestrator.
    public init(
        conversations: ConversationManager,
        toolBus: ToolBus,
        llm: any LLMProvider,
        systemPrompt: String? = nil,
        maxToolIterations: Int = 10,
        toolResolver: OrchestratorToolResolver? = nil,
        memoryEngine: MemoryEngine? = nil,
        approvalQueue: ApprovalQueue? = nil,
        embedder: (any EmbeddingsBackend)? = nil,
        compactionThresholdPercent: Int = 80,
        steeringQueue: SteeringQueue? = nil,
        securityConfig: SecurityConfig = SecurityConfig(),
        permissionGate: PermissionGate? = nil
    ) {
        self.conversationManager = conversations
        self.toolRegistry = toolBus
        self.languageProvider = llm
        self.storedSystemPrompt = systemPrompt
        self.maxToolIterations = max(1, min(100, maxToolIterations))
        self.toolResolver = toolResolver
        self.memoryEngine = memoryEngine
        self.approvalInbox = approvalQueue
        self.embedder = embedder
        self.compactionPercent = max(10, min(100, compactionThresholdPercent))
        self.steeringQueue = steeringQueue
        self.securityConfig = securityConfig
        self.permissionGate = permissionGate
    }

    /// Dynamically updates the maximum tool iterations allowed per turn.
    public func updateMaxToolIterations(_ iterations: Int) {
        self.maxToolIterations = max(1, min(100, iterations))
    }

    /// Dynamically updates the context compaction threshold without a restart.
    /// Clamps into the validated 10-100 range so the live engine mirrors the
    /// persisted settings contract even if a caller passes an edge value.
    public func updateCompactionPercent(_ percent: Int) {
        self.compactionPercent = max(10, min(100, percent))
    }

    // MARK: - Shared dependency views

    /// Read-only conversation owner for the parking extension.
    /// The stored reference stays private so module code cannot swap the owner
    /// mid-flight; the parking file still reaches the same instance.
    var conversations: ConversationManager {
        conversationManager
    }

    /// Read-only tool registry for the parking extension.
    var toolBus: ToolBus {
        toolRegistry
    }

    /// Read-only serving provider for the parking extension.
    var llm: any LLMProvider {
        languageProvider
    }

    /// Read-only stored developer prompt for the parking extension.
    var systemPrompt: String? {
        storedSystemPrompt
    }

    /// Read-only context compaction threshold for the parking extension.
    var compactionThresholdPercent: Int {
        compactionPercent
    }

    /// Read-only approvals inbox for the parking extension.
    var approvalQueue: ApprovalQueue? {
        approvalInbox
    }

    /// Read-only admission gate for the parking extension.
    /// The stored reference stays private so module code cannot swap the gate
    /// mid-flight; the turn loop still reaches the same instance the bus checks.
    var admissionGate: PermissionGate? {
        permissionGate
    }

    /// Shared mid-turn steering queue draining user guidance into running loops.
    /// Public so the service layer can verify it holds the identical instance
    /// it enqueues through; a mismatched pair enqueues honestly yet never
    /// dequeues, silently dropping guidance behind an optimistic bubble.
    /// Nonisolated so context construction can precondition identity without
    /// hopping; the immutable reference stays safe to share synchronously.
    public nonisolated var sharedSteeringQueue: SteeringQueue? {
        steeringQueue
    }

    /// Whether untrusted external tool output is wrapped before model context.
    /// Reads `[security] untrusted_labeling` so the debugging off-switch is honored.
    var labelingEnabled: Bool {
        securityConfig.untrustedLabeling
    }

    // MARK: - Parked state mutation

    /// Removes and returns one parked approval so a resume decision owns that
    /// request exactly once instead of racing a second decision.
    func takeParkedNarratedApproval(id: UUID) -> ParkedNarratedApproval? {
        parkedNarratedApprovals.removeValue(forKey: id)
    }

    /// Files one parked approval under its request identifier.
    func storeParkedNarratedApproval(_ parked: ParkedNarratedApproval, id: UUID) {
        parkedNarratedApprovals[id] = parked
    }

    /// Buffers one already-executed gated action while its batch siblings stay pending.
    func bufferParkedExecutedAction(_ action: ToolAction, forBatch batchID: UUID) {
        parkedBatchExecutedActions[batchID, default: []].append(action)
    }

    /// Buffered executed actions for one parked batch, empty when none landed yet.
    func parkedExecutedActions(forBatch batchID: UUID) -> [ToolAction] {
        parkedBatchExecutedActions[batchID] ?? []
    }

    /// Takes and clears buffered executed actions for one parked batch.
    func takeParkedExecutedActions(forBatch batchID: UUID) -> [ToolAction] {
        let buffered = parkedBatchExecutedActions[batchID] ?? []
        parkedBatchExecutedActions.removeValue(forKey: batchID)
        return buffered
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
        // Goal-tagged turns overwrite the session link so an explicit tag wins
        // over a stale link and runs stay joinable; a nil tag never clears, so
        // plain chat turns keep a link set by an earlier tagged turn.
        _ = await conversations.ensureSession(id: sessionID, overwrite: input.goalID != nil, goalID: input.goalID)
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
            let effectiveSystemPrompt = resolveEffectiveSystemPrompt(input: input, tools: tools)
            let recall: Message? = if let memoryEngine {
                try await memoryEngine.recallMessage(
                    for: text,
                    sessionID: sessionID,
                    embedder: embedder,
                    labelingEnabled: securityConfig.untrustedLabeling
                )
            } else {
                nil
            }
            let reservedToolTokens = ConversationManager.estimateToolTokens(in: tools)
            await conversations.compactHistoryIfNeeded(
                for: sessionID,
                contextLength: llm.modelInfo.contextLength,
                thresholdPercent: compactionThresholdPercent,
                reservedTokens: reservedToolTokens
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
            case let .finished(finalText, toolActions, loopBilled, contextTokens):
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
                    contextTokens: contextTokens,
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
        guard let steerText = await steeringQueue?.dequeue(for: sessionID) else { return false }
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

    /// Whether a turn source runs detached from interactive chat.
    /// Scheduler and goal turns share the background system prompt and the
    /// parked-resume background branch so future detached sources extend in
    /// one place instead of scattering string matches across the loop.
    /// - Parameter source: Turn or session source label, nil when untagged.
    /// - Returns: True for known background sources.
    public static func isBackgroundSource(_ source: String?) -> Bool {
        source == "scheduler" || source == "goal"
    }

    /// Resolves the effective system prompt for one turn.
    /// Custom overrides bypass composition verbatim so live turns and parked
    /// resumes honor the same prompt instead of diverging; background turns
    /// recompose on the background branch with the vision-aware snapshot.
    private func resolveEffectiveSystemPrompt(input: UserInput, tools: [any Tool]) -> String? {
        if let custom = input.systemPrompt, !custom.isEmpty {
            // Custom override bypasses composition and its cache verbatim.
            return custom
        }
        if let stored = systemPrompt, !stored.isEmpty, !SystemPromptComposer.isComposedPrompt(stored) {
            // Explicit stored override wins over scheduler composition so live turns
            // and parked resumes honor the same custom prompt instead of diverging.
            return stored
        }
        let supportsVision = llm.modelInfo.supportsVision
        let includeToolSchemas = !llm.modelInfo.supportsTools
        if Self.isBackgroundSource(input.source) {
            return SystemPromptComposer.composeScheduled(tools: tools, supportsVision: supportsVision, includeToolSchemas: includeToolSchemas)
        }
        return SystemPromptComposer.compose(tools: tools, supportsVision: supportsVision, includeToolSchemas: includeToolSchemas)
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

    /// Splits resolved structured calls into immediately runnable versus needs-park.
    /// Needs-park holds only calls whose tool lookup succeeds, whose level is
    /// requiresApproval, whose gate verdict is requiresApproval, and whose turn is
    /// live (inbox present, not a dry run). Everything else stays allowed-now so
    /// unknown, disabled, denied, readOnly, trusted, covering-grant, and preview
    /// paths keep their existing ToolBus behavior. Fail-closed: a missing gate or
    /// inbox never parks.
    private func partitionStructuredCalls(
        _ calls: [ToolInput],
        isDryRun: Bool
    ) async -> (allowed: [ToolInput], needsPark: [ToolInput]) {
        guard !isDryRun, approvalQueue != nil, let gate = permissionGate else {
            return (calls, [])
        }
        var allowed: [ToolInput] = []
        var needsPark: [ToolInput] = []
        for call in calls {
            guard let tool = await toolBus.tool(named: call.toolName) else {
                allowed.append(call)
                continue
            }
            guard await toolBus.isToolEnabled(named: call.toolName) else {
                allowed.append(call)
                continue
            }
            guard tool.permissionLevel == .requiresApproval else {
                allowed.append(call)
                continue
            }
            let verdict = await gate.checkPermission(toolCall: call, tool: tool)
            if case .requiresApproval = verdict {
                needsPark.append(call)
            } else {
                allowed.append(call)
            }
        }
        return (allowed, needsPark)
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
    private func checkLimitAndPark(
        toolRounds: Int,
        parkContext: ParkTurnContext,
        request: TurnLoopRequest,
        pendingEpisodic: inout [(content: String, role: Message.Role)]
    ) async throws -> TurnLoopOutcome? {
        guard OrchestratorToolLoop.isLimitExceeded(rounds: toolRounds, max: maxToolIterations) else { return nil }
        return try await parkForContinuation(
            toolRounds: toolRounds,
            context: parkContext,
            request: request,
            pendingEpisodic: &pendingEpisodic
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
            finalText = collected.text

            if await handleMidGenerationSteering(
                sessionID: request.sessionID,
                finalText: &finalText,
                workingMessages: &workingMessages,
                pendingEpisodic: &pendingEpisodic
            ) {
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
            // Structured admission: gated writes park before the suspending bus
            // handler, while every other call keeps its existing execute path.
            // The combined batch files structured needs-park plus narrated siblings
            // under one identifier so mixed rounds park once.
            let partition = await partitionStructuredCalls(calls, isDryRun: request.isDryRun)
            // Dry runs never park: structured needs-park is already empty via
            // the partition, and narrated siblings are dropped here so a dry
            // run with narration cannot file through the combined batch.
            let combinedGated = request.isDryRun ? [] : partition.needsPark + narratedGated
            if partition.allowed.isEmpty {
                // Gated-only round skips execution and parks immediately; an empty
                // combined batch falls through to the break below like today.
                if !combinedGated.isEmpty {
                    let gatedContext = makeParkContext(
                        gated: combinedGated, text: finalText, actions: toolActions, toolRounds: toolRounds, tokens: tokens
                    )
                    if let parked = await parkTurnIfGated(context: gatedContext, request: request, pendingEpisodic: &pendingEpisodic) {
                        return parked
                    }
                }
                break
            }
            toolRounds += 1
            let parkContext = makeParkContext(
                gated: combinedGated, text: finalText, actions: toolActions, toolRounds: toolRounds, tokens: tokens
            )
            if let outcome = try await checkLimitAndPark(
                toolRounds: toolRounds, parkContext: parkContext, request: request, pendingEpisodic: &pendingEpisodic
            ) {
                return outcome
            }
            let executed = try await recordAndExecuteCalls(
                calls: partition.allowed, finalText: finalText, toolRounds: toolRounds, request: request, pendingEpisodic: &pendingEpisodic,
                noteCalls: calls
            )
            toolActions.append(contentsOf: executed)
            // The executed call already wrote this turn's narration note, so the
            // sibling gated calls must park without persisting it a second time.
            let updatedContext = makeParkContext(
                gated: combinedGated, text: finalText, actions: toolActions, toolRounds: toolRounds, tokens: tokens,
                narrationAlreadyPersisted: true
            )
            if let parked = await parkTurnIfGated(context: updatedContext, request: request, pendingEpisodic: &pendingEpisodic) {
                return parked
            }
            workingMessages = await refreshedWorkingMessages(
                sessionID: request.sessionID, recall: request.recall, systemPrompt: request.systemPrompt
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

    private func emitTurnTokens(
        billed: Int?,
        billedTokens: inout Int?,
        roundIndex: Int,
        request: TurnLoopRequest,
        contextTokens: Int?
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
                turnTotalTokens: cumulativeTurnTotal,
                contextTokens: contextTokens
            ))
        }
    }

    /// Builds the working-memory note recording one tool round's intent.
    func assistantNoteMessage(text: String, calls: [ToolInput]) -> Message {
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
    func refreshedWorkingMessages(sessionID: UUID, recall: Message?, systemPrompt: String?) async -> [Message] {
        await Self.stableHistoryWithRecall(
            conversations.workingHistory(for: sessionID, systemPrompt: systemPrompt ?? self.systemPrompt),
            recall: recall
        )
    }

    /// Stores the final assistant text when it carries user-visible content.
    /// Returns the persisted note so callers can stamp the response completion from the same
    /// creation instant the history reload path reads, keeping live and reload in agreement.
    @discardableResult
    func storeFinalAssistantText(
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
                    labelingEnabled: securityConfig.untrustedLabeling
                )
                if let record = OrchestratorToolLoop.episodicToolRecord(
                    toolName: call.toolName,
                    result: result,
                    for: tool,
                    labelingEnabled: securityConfig.untrustedLabeling
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
                    labelingEnabled: securityConfig.untrustedLabeling
                )
            }
            throw error
        }
    }
}

// MARK: - Session tokens and memory mirroring

/// Holds episodic flushing, remember handling, token totals, and LLM
/// collection helpers so no single type body exceeds the length budget.
extension Orchestrator {
    /// Flushes buffered episodic mirrors without throwing.
    func flushEpisodic(_ pending: [(content: String, role: Message.Role)], sessionID: UUID) async {
        guard let memoryEngine else { return }
        for entry in pending {
            await memoryEngine.mirrorTurn(content: entry.content, sessionID: sessionID, role: entry.role, failurePolicy: .silent)
        }
    }

    /// Flushes buffered episodic mirrors without observing cancellation.
    func flushEpisodicUncancellable(
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
    func accumulateSessionTokens(_ billedTokens: Int?, for sessionID: UUID) -> Int? {
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
    static func combinedTurnTokens(_ prior: Int?, _ synthesis: Int?) -> Int? {
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
        onDelta: (@Sendable (String) async -> Void)? = nil,
        onReasoningDelta: (@Sendable (String) async -> Void)? = nil
    ) async throws -> TurnDraft {
        var text = ""
        var billed: Int?
        var toolCalls: [ToolInput] = []
        // Steering callbacks arrive off this executor while the stream is
        // consumed here, so the interrupt flag stays behind a lock to keep
        // mid-turn pivots visible without a race.
        let interrupted = OSAllocatedUnfairLock(initialState: false)
        let interruptToken: UUID? = if let sessionID, let queue = steeringQueue {
            await queue.registerInterrupt(sessionID: sessionID) {
                interrupted.withLock { $0 = true }
            }
        } else {
            nil
        }
        let effectiveMessages = VisionGate.stripMessages(messages, supportsVision: llm.modelInfo.supportsVision)
        let stream = llm.chat(messages: effectiveMessages, tools: tools, session: sessionID)
        do {
            for await chunk in stream {
                try Task.checkCancellation()
                if interrupted.withLock({ $0 }) {
                    break
                }
                if let message = chunk.errorMessage {
                    throw OrchestratorError.llmFailed(message.isEmpty ? "unknown error" : message)
                }
                if !chunk.reasoningDelta.isEmpty {
                    // Reasoning streams live via the callback below but stays out
                    // of the final text by design: it is never accumulated or
                    // promoted into the draft, so no unused per-turn state remains.
                    await onReasoningDelta?(chunk.reasoningDelta)
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
        } catch {
            // Release the registration before propagating so a late steer cannot
            // trip the next round's interrupt flag.
            if let interruptToken, let sessionID, let queue = steeringQueue {
                await queue.unregisterInterrupt(sessionID: sessionID, token: interruptToken)
            }
            throw error
        }
        // Keep the registration scoped to this stream so the success path leaves
        // no stale token behind for the next round.
        if let interruptToken, let sessionID, let queue = steeringQueue {
            await queue.unregisterInterrupt(sessionID: sessionID, token: interruptToken)
        }
        return TurnDraft(
            text: text,
            billedTokens: billed,
            toolCalls: toolCalls
        )
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

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
    /// Recall budgets bounding automatic recall fan-out.
    /// Stored so every turn injects with the same clamped limits the config
    /// file carries instead of hardcoded per-tier caps.
    private var recallBudgets: RecallBudgets
    /// Assistant persona configured for this orchestrator.
    public nonisolated let persona: PersonaConfig
    /// Strict container registry executed turns run against.
    /// Nil means the shared live registry; an injected registry keeps
    /// hermetic turns reaping the same registry execution used.
    private var strictRegistry: StrictTurnRegistry?

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
        permissionGate: PermissionGate? = nil,
        recallBudgets: RecallBudgets = RecallBudgets(),
        persona: PersonaConfig = PersonaConfig(),
        strictRegistry: StrictTurnRegistry? = nil
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
        self.recallBudgets = recallBudgets.clamped()
        self.persona = persona
        self.strictRegistry = strictRegistry
    }

    /// Updates the strict container registry reaped at terminal turn end.
    public func updateStrictRegistry(_ registry: StrictTurnRegistry?) {
        self.strictRegistry = registry
    }

    /// Dynamically updates the maximum tool iterations allowed per turn.
    public func updateMaxToolIterations(_ iterations: Int) {
        self.maxToolIterations = max(1, min(100, iterations))
    }

    /// Dynamically updates the recall budgets without a restart.
    /// Clamps into the documented ranges so the live engine mirrors the
    /// persisted settings contract even if a caller passes an edge value.
    public func updateRecallBudgets(_ budgets: RecallBudgets) {
        self.recallBudgets = budgets.clamped()
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

    /// Read-only memory engine for tool-loop extensions.
    var memory: MemoryEngine? {
        memoryEngine
    }

    /// Read-only recall budgets for tool-loop extensions.
    var budgets: RecallBudgets {
        recallBudgets
    }

    /// Strict registry executed turns run against for the turn-loop extension.
    var strictContainerRegistry: StrictTurnRegistry? {
        strictRegistry
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
        // The session record also keeps the turn's honest origin — title,
        // source, and parent link — so history can classify worker sessions
        // and nest them under the session that spawned them.
        _ = await conversations.ensureSession(
            id: sessionID,
            title: input.title,
            source: OrchestratorToolLoop.resolvedSource(input.source),
            overwrite: input.goalID != nil,
            goalID: input.goalID,
            parentSessionID: input.parentSessionID
        )
        // Raw pre-turn copy (messages plus rolling summary, never the
        // synthetic summary-prefix view) so cancellation restores both
        // without duplicating the summary or keeping truncated growth.
        let preTurnSnapshot = await conversations.rollbackSnapshot(for: sessionID)
        // Episodic mirrors buffer until commit: user text, compact tool records, and final text
        // flush on success or on failures that keep working partials.
        var pendingEpisodic: [(content: String, role: Message.Role)] = []
        // Tracks recall observability so every turn emits exactly one line,
        // including turns that cancel before the recall slot is reached.
        var didEmitRecallDiagnostics = false

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
                // Remember turns bypass recall but still emit one zero-hit line
                // so every turn carries exactly one diagnostics entry. The skip
                // flag mirrors the recall path (freshness plus store presence)
                // so a freshness query logs the same flag here as on a full turn.
                RuneWeaverLog.memory.info("\(Self.recallDiagnosticsLogLine(RecallDiagnostics.zero(skippedDocIndex: earlyRecallSkip(for: text))))")
                didEmitRecallDiagnostics = true
                try Task.checkCancellation()
                await flushEpisodic(pendingEpisodic, sessionID: sessionID)
                await permissionGate?.clearTaskGrants(for: sessionID)
                return earlyResponse
            }

            let (request, turnWarnings) = try await prepareTurnLoopRequest(
                input: input,
                text: text,
                didEmitRecallDiagnostics: &didEmitRecallDiagnostics,
                onEvent: onEvent
            )
            let outcome = try await runTurnLoop(request, pendingEpisodic: &pendingEpisodic)
            switch outcome {
            case let .parked(parkedResponse):
                return parkedResponse
            case let .finished(finalText, toolActions, loopBilled, contextTokens, isBudgetExceeded):
                let finalNote = await storeFinalAssistantText(finalText, sessionID: sessionID, pendingEpisodic: &pendingEpisodic)
                try Task.checkCancellation()
                await flushEpisodic(pendingEpisodic, sessionID: sessionID)
                let cumulativeTokens = accumulateSessionTokens(loopBilled, for: sessionID)
                await permissionGate?.clearTaskGrants(for: sessionID)
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
                    completedAt: finalNote?.createdAt.timeIntervalSince1970,
                    isBudgetExceeded: isBudgetExceeded
                )
            }
        } catch let error as CancellationError {
            await permissionGate?.clearTaskGrants(for: sessionID)
            await handleProcessCancellation(
                didEmitRecallDiagnostics: didEmitRecallDiagnostics,
                text: text,
                pendingEpisodic: pendingEpisodic,
                sessionID: sessionID,
                preTurnSnapshot: preTurnSnapshot
            )
            throw error
        } catch {
            await permissionGate?.clearTaskGrants(for: sessionID)
            await handleProcessError(
                didEmitRecallDiagnostics: didEmitRecallDiagnostics,
                text: text,
                pendingEpisodic: pendingEpisodic,
                sessionID: sessionID
            )
            throw error
        }
    }

    private func resolveTurnRecall(
        text: String,
        sessionID: UUID,
        didEmitRecallDiagnostics: inout Bool
    ) async throws -> (recall: Message?, starterPack: Message?) {
        do {
            if let memoryEngine {
                let wired = try await Self.resolveTurnRecallAndStarter(
                    engine: memoryEngine,
                    query: text,
                    sessionID: sessionID,
                    embedder: embedder,
                    labelingEnabled: securityConfig.untrustedLabeling,
                    budgets: recallBudgets,
                    currentDate: Date()
                )
                // One diagnostics line per turn with counts plus scores plus
                // skip flag, never content; silent-nil recalls still emit a
                // zero-hit line via the diagnostics payload above.
                RuneWeaverLog.memory.info("\(Self.recallDiagnosticsLogLine(wired.diagnostics))")
                didEmitRecallDiagnostics = true
                return (wired.recall, wired.starterPack)
            } else {
                // No engine means no doc index: derive the freshness flag
                // so a freshness query logs skipped here as on every path.
                RuneWeaverLog.memory.info("\(Self.recallDiagnosticsLogLine(RecallDiagnostics.zero(skippedDocIndex: earlyRecallSkip(for: text))))")
                didEmitRecallDiagnostics = true
                return (nil, nil)
            }
        } catch let recallError as CancellationError {
            // Cancelled recall still emits one zero-hit line before the
            // outer handler restores history and propagates. The skip flag
            // mirrors the recall path (freshness plus store presence) since
            // the shared wiring threw before returning its plan.
            let fallbackSkip = earlyRecallSkip(for: text)
            RuneWeaverLog.memory.info("\(Self.recallDiagnosticsLogLine(RecallDiagnostics.zero(skippedDocIndex: fallbackSkip)))")
            didEmitRecallDiagnostics = true
            throw recallError
        }
    }

    private func handleProcessCancellation(
        didEmitRecallDiagnostics: Bool,
        text: String,
        pendingEpisodic: [(content: String, role: Message.Role)],
        sessionID: UUID,
        preTurnSnapshot: ConversationSession?
    ) async {
        // Guarantee one diagnostics line even when cancellation lands
        // before the recall slot; turns that already emitted keep exactly
        // one and do not double-log here. The fallback derives the same
        // freshness-plus-store skip flag so pre-recall cancels agree.
        if !didEmitRecallDiagnostics {
            RuneWeaverLog.memory.info("\(Self.recallDiagnosticsLogLine(RecallDiagnostics.zero(skippedDocIndex: earlyRecallSkip(for: text))))")
        }
        // Executed tools already changed the world: keep working-memory
        // partials and mirror them so the audit trail survives the
        // cancel instead of being rolled back as if nothing ran.
        let hasExecutedTools = pendingEpisodic.contains { $0.role == .tool }
        if hasExecutedTools {
            await flushEpisodicUncancellable(pendingEpisodic, sessionID: sessionID)
        } else if let preTurnSnapshot {
            await conversations.restoreRollbackSnapshot(preTurnSnapshot)
        }
    }

    private func handleProcessError(
        didEmitRecallDiagnostics: Bool,
        text: String,
        pendingEpisodic: [(content: String, role: Message.Role)],
        sessionID: UUID
    ) async {
        // Guarantee one diagnostics line on non-cancellation failures that
        // bypassed recall; turns that already emitted keep exactly one.
        // The fallback derives the same freshness-plus-store skip flag.
        if !didEmitRecallDiagnostics {
            RuneWeaverLog.memory.info("\(Self.recallDiagnosticsLogLine(RecallDiagnostics.zero(skippedDocIndex: earlyRecallSkip(for: text))))")
        }
        // Non-cancellation failures keep working-memory partials, so
        // flush the buffered mirror to match instead of diverging.
        await flushEpisodic(pendingEpisodic, sessionID: sessionID)
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

// MARK: - Turn request preparation

extension Orchestrator {
    /// Early-turn doc-index skip flag for zero-hit diagnostics.
    ///
    /// Mirrors `recallMessageWithDiagnostics` (`plan.skipDocIndex ||
    /// store == nil`) so remember-bypass, nil-engine, and pre-recall
    /// cancellation turns log the same honest flag as a full recall turn
    /// for the same query. Freshness comes from the router plan; a missing
    /// engine reads as a missing store.
    private func earlyRecallSkip(for query: String) -> Bool {
        let freshnessSkip = MemoryQueryRouter.plan(for: query, currentDate: Date(), budgets: recallBudgets).skipDocIndex
        let store = memoryEngine?.docIndexStore
        return freshnessSkip || store == nil
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

    /// Prepares the tool-loop request and degraded-tool warnings for one turn.
    ///
    /// Resolves the tool snapshot filtered by caller permissions, the effective
    /// system prompt, turn recall and starter pack, history compaction, and
    /// degraded tool warnings before dispatching into the tool loop.
    /// - Parameters:
    ///   - input: User input driving this turn.
    ///   - text: Trimmed prompt text.
    ///   - didEmitRecallDiagnostics: Whether recall diagnostics were emitted.
    ///   - onEvent: Stream event callback.
    /// - Returns: Prepared turn loop request and degraded-tool warnings.
    private func prepareTurnLoopRequest(
        input: UserInput,
        text: String,
        didEmitRecallDiagnostics: inout Bool,
        onEvent: (@Sendable (OrchestratorEvent) async -> Void)?
    ) async throws -> (request: TurnLoopRequest, warnings: [String]) {
        // Single registry snapshot shared by the prompt and the wire so both omit the
        // same disabled tools; sorted order mirrors the prompt so leading bytes stay
        // identical for server prefix caching. Both branches recompose from this snapshot
        // (vision-aware) so a mid-run tool toggle reaches the next turn's prompt as well
        // as its wire; mid-loop rounds reuse the snapshot, so a toggle takes effect on
        // the next user message. An explicit operator override bypasses composition verbatim.
        // A turn carrying an explicit allowedTools subset filters the snapshot here,
        // before the loop, so the prompt and the wire advertise only the callable subset
        // and a worker can never narrate or call outside it; nil keeps the full registry
        // so plain turns pay nothing.
        let availableTools = await toolBus.availableTools()
        let sortedTools = VisionSchemaFilter.sortedByName(availableTools, name: { $0.name })
        let tools = UserInput.filteredTools(
            sortedTools,
            allowed: input.allowedTools
        )
        let effectiveSystemPrompt = resolveEffectiveSystemPrompt(input: input, tools: tools)
        // Temporal plus freshness-aware auto-recall through the shared
        // turn wiring: one plan plus recall plus starter so service and
        // CLI turns cannot drift. No date math here; the router owns every
        // calendar derivation inside the shared helper.
        let (recall, starterPack) = try await resolveTurnRecall(
            text: text,
            sessionID: input.sessionID,
            didEmitRecallDiagnostics: &didEmitRecallDiagnostics
        )
        let reservedToolTokens = ConversationManager.estimateToolTokens(in: tools)
        await conversations.compactHistoryIfNeeded(
            for: input.sessionID,
            contextLength: llm.modelInfo.contextLength,
            thresholdPercent: compactionThresholdPercent,
            reservedTokens: reservedToolTokens
        )
        let workingMessages = await Self.stableHistoryWithRecallAndStarter(
            conversations.workingHistory(for: input.sessionID, systemPrompt: effectiveSystemPrompt),
            recall: recall,
            starterPack: starterPack
        )
        // Degraded tools stay out of the model request but must not fail the turn:
        // surface one static warning per skipped tool name mid-turn and again
        // on the terminal response so streaming and polling clients agree.
        let turnWarnings = OrchestratorToolLoop.degradedToolWarnings(for: tools)
        for warning in turnWarnings {
            await onEvent?(.warning(warning))
        }
        let effectivePolicy = input.toolLimitPolicy ?? (input.source == "scheduler" || input.source == "goal" ? .forceSynthesis : .park)
        // Turn-level overrides arrive over the service boundary, so bound them
        // at use: the stored default is already clamped, but a direct caller
        // could otherwise stretch one turn into an unbounded tool loop.
        let requestedIterations = input.maxToolIterations ?? self.maxToolIterations
        let effectiveMaxIterations = max(1, min(100, requestedIterations))
        let bashSnapshot = await permissionGate?.bashConfigSnapshot()
        let workspaceSnapshot = await permissionGate?.workspaceRootSnapshot()
        let request = TurnLoopRequest(
            workingMessages: workingMessages,
            tools: tools,
            recall: recall,
            starterPack: starterPack,
            sessionID: input.sessionID,
            systemPrompt: effectiveSystemPrompt,
            onEvent: onEvent,
            toolLimitPolicy: effectivePolicy,
            effectiveMaxToolIterations: effectiveMaxIterations,
            bashConfig: bashSnapshot,
            workspaceRoot: workspaceSnapshot,
            strictRegistry: strictRegistry
        )
        return (request, turnWarnings)
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
        if Self.isBackgroundSource(input.source) {
            return SystemPromptComposer.composeScheduled(tools: tools, supportsVision: supportsVision, persona: persona)
        }
        return SystemPromptComposer.compose(tools: tools, supportsVision: supportsVision, persona: persona)
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
    func collectTurn(
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
    func resolveToolCalls(messages: [Message], assistantText: String, tools: [any Tool]) async throws -> [ToolInput] {
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

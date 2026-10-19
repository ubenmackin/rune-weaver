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
    private var languageProvider: any LLMProvider
    /// Developer instructions prepended to every turn.
    private let storedSystemPrompt: String?
    /// Maximum tool-call rounds per response, plus one final synthesis turn.
    private(set) var maxToolIterations: Int
    /// Optional resolver mapping an assistant turn to tool calls.
    private let toolResolver: OrchestratorToolResolver?
    /// Episodic mirror for every turn, when configured.
    private let memoryEngine: MemoryEngine?
    /// Optional embeddings producer for vector-ranked automatic recall.
    private let embedder: any EmbeddingsBackend?
    /// Context window compaction threshold percentage (10-100).
    private var compactionPercent: Int
    /// Queue receiving narrated gated calls, when configured.
    private let approvalInbox: ApprovalQueue?
    /// Parked gated narrations indexed by approval request identifier.
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
    private nonisolated let steeringQueue: SteeringQueue?
    /// Defense policy carrying the `[security] untrusted_labeling` off-switch.
    /// Stored so every tool-result message conversion honors the configured
    /// labeling posture instead of a hardcoded default.
    private let securityConfig: SecurityConfig
    /// Graduated-trust gate consulted for structured admission.
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
        embedder: any EmbeddingsBackend? = nil,
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

    /// Dynamically updates the serving LLM provider without a restart.
    public func updateLanguageProvider(_ provider: any LLMProvider) {
        self.languageProvider = provider
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

    /// Read-only recall budgets for tool-loop extensions and the dashboard search route.
    /// Public so the server module reads the same clamped `[memory] recall_*`
    /// values chat turns inject with instead of default budgets.
    public var budgets: RecallBudgets {
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
        // Goal-tagged turns overwrite the session link so an explicit tag wins over a stale link
        // and runs stay joinable; a nil tag never clears, so plain chat turns keep a link set by an
        // earlier tagged turn.
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

            // Turns that answer before the model loop — an explicit remember
            // request, then a repeated pure question served from the semantic
            // answer cache — share one resolution plus one epilogue below.
            if let earlyResponse = try await earlyTurnResponse(
                text: text,
                source: input.source,
                sessionID: sessionID,
                pendingEpisodic: &pendingEpisodic,
                onEvent: onEvent,
                didEmitRecallDiagnostics: &didEmitRecallDiagnostics
            ) {
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
                return Self.responseWithRecall(parkedResponse, summary: request.recallDiagnostics)
            case let .finished(finalText, toolActions, loopBilled, contextTokens, isBudgetExceeded, reasoning):
                let finalNote = await storeFinalAssistantText(finalText, reasoning: reasoning, sessionID: sessionID, pendingEpisodic: &pendingEpisodic)
                try Task.checkCancellation()
                await flushEpisodic(pendingEpisodic, sessionID: sessionID)
                // A finished turn that ran no tools is pure Q&A, so its answer
                // files for the next identical question. The parked branch
                // returned earlier, which is what keeps approvals out.
                await storeAnswerCacheIfPure(
                    query: text,
                    source: input.source,
                    finalText: finalText,
                    executedToolCalls: toolActions.count
                )
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
                    isBudgetExceeded: isBudgetExceeded,
                    recallDiagnostics: request.recallDiagnostics
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

    /// Resolves a turn that answers before the model loop, if one applies.
    private func earlyTurnResponse(
        text: String,
        source: String,
        sessionID: UUID,
        pendingEpisodic: inout [(content: String, role: Message.Role)],
        onEvent: (@Sendable (OrchestratorEvent) async -> Void)?,
        didEmitRecallDiagnostics: inout Bool
    ) async throws -> OrchestratorResponse? {
        let earlyResponse: OrchestratorResponse? = if let remembered = try await rememberEarlyResponse(
            text: text,
            source: source,
            sessionID: sessionID,
            pendingEpisodic: &pendingEpisodic,
            onEvent: onEvent
        ) {
            remembered
        } else {
            await answerCacheEarlyResponse(
                text: text,
                source: source,
                sessionID: sessionID,
                pendingEpisodic: &pendingEpisodic,
                onEvent: onEvent
            )
        }
        guard let earlyResponse else { return nil }
        let diagnostics = RecallDiagnostics.zero(skippedDocIndex: earlyRecallSkip(for: text))
        RuneWeaverLog.memory.info("\(Self.recallDiagnosticsLogLine(diagnostics))")
        didEmitRecallDiagnostics = true
        try Task.checkCancellation()
        await flushEpisodic(pendingEpisodic, sessionID: sessionID)
        await permissionGate?.clearTaskGrants(for: sessionID)
        return Self.responseWithRecall(earlyResponse, diagnostics: diagnostics)
    }

    private func resolveTurnRecall(
        text: String,
        sessionID: UUID,
        didEmitRecallDiagnostics: inout Bool
    ) async throws -> TurnRecallResolution {
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
                return TurnRecallResolution(recall: wired.recall, starterPack: wired.starterPack, summary: RecallSummary(from: wired.diagnostics))
            } else {
                // No engine means no doc index: derive the freshness flag
                // so a freshness query logs skipped here as on every path.
                let zero = RecallDiagnostics.zero(skippedDocIndex: earlyRecallSkip(for: text))
                RuneWeaverLog.memory.info("\(Self.recallDiagnosticsLogLine(zero))")
                didEmitRecallDiagnostics = true
                return TurnRecallResolution(recall: nil, starterPack: nil, summary: RecallSummary(from: zero))
            }
        } catch let recallError as CancellationError {
            // Cancelled recall still emits one zero-hit line before the outer handler restores
            // history and propagates.
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
        // Guarantee one diagnostics line even when cancellation lands before the recall slot; turns
        // that already emitted keep exactly one and do not double-log here.
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
    private func earlyRecallSkip(for query: String) -> Bool {
        let freshnessSkip = MemoryQueryRouter.plan(for: query, currentDate: Date(), budgets: recallBudgets).skipDocIndex
        let store = memoryEngine?.docIndexStore
        return freshnessSkip || store == nil
    }

    /// Whether a turn source runs detached from interactive chat.
    public static func isBackgroundSource(_ source: String?) -> Bool {
        source == "scheduler" || source == "goal" || source == "fanout" || source == "fanout_worker"
    }

    /// Returns a copy of a turn response carrying the content-free recall summary.
    static func responseWithRecall(_ response: OrchestratorResponse, summary: RecallSummary?) -> OrchestratorResponse {
        guard let summary, response.recallDiagnostics == nil else { return response }
        return OrchestratorResponse(
            text: response.text,
            sessionID: response.sessionID,
            toolActions: response.toolActions,
            totalTokens: response.totalTokens,
            modelName: response.modelName,
            contextLength: response.contextLength,
            sessionTokens: response.sessionTokens,
            contextTokens: response.contextTokens,
            isParked: response.isParked,
            warnings: response.warnings,
            completedAt: response.completedAt,
            isBudgetExceeded: response.isBudgetExceeded,
            recallDiagnostics: summary
        )
    }

    /// Returns a copy of a turn response carrying projected diagnostics.
    static func responseWithRecall(_ response: OrchestratorResponse, diagnostics: RecallDiagnostics) -> OrchestratorResponse {
        responseWithRecall(response, summary: RecallSummary(from: diagnostics))
    }

    /// Prepares the tool-loop request and degraded-tool warnings for one turn.
    private func prepareTurnLoopRequest(
        input: UserInput,
        text: String,
        didEmitRecallDiagnostics: inout Bool,
        onEvent: (@Sendable (OrchestratorEvent) async -> Void)?
    ) async throws -> (request: TurnLoopRequest, warnings: [String]) {
        // Single registry snapshot shared by the prompt and the wire so both omit the same disabled
        // tools; sorted order mirrors the prompt so leading bytes stay identical for server prefix
        // caching.
        let availableTools = await toolBus.availableTools()
        let sortedTools = VisionSchemaFilter.sortedByName(availableTools, name: { $0.name })
        let tools = UserInput.filteredTools(
            sortedTools,
            allowed: input.allowedTools
        )
        let effectiveSystemPrompt = resolveEffectiveSystemPrompt(input: input, tools: tools)
        // Temporal plus freshness-aware auto-recall through the shared turn wiring: one plan plus
        // recall plus starter so service and CLI turns cannot drift.
        let resolvedRecall = try await resolveTurnRecall(
            text: text,
            sessionID: input.sessionID,
            didEmitRecallDiagnostics: &didEmitRecallDiagnostics
        )
        let recall = resolvedRecall.recall
        let starterPack = resolvedRecall.starterPack
        let recallSummary = resolvedRecall.summary
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
            strictRegistry: strictRegistry,
            recallDiagnostics: recallSummary
        )
        return (request, turnWarnings)
    }

    /// Resolves the effective system prompt for one turn.
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
    /// Episodic attribution for background goal work: a background session
    /// linked to a goal stamps that link so the trigger bridge can reject the
    /// goal's own mirrored episodes instead of re-arming its triggers.
    private func goalAttributionMetadata(for sessionID: UUID) async -> [String: String] {
        guard let session = await conversations.session(id: sessionID),
              let goalID = session.goalID,
              Self.isBackgroundSource(session.source)
        else { return [:] }
        return [GoalTriggerBridge.goalAttributionKey: goalID.uuidString]
    }

    /// Flushes buffered episodic mirrors without throwing.
    func flushEpisodic(_ pending: [(content: String, role: Message.Role)], sessionID: UUID) async {
        guard let memoryEngine else { return }
        let attribution = await goalAttributionMetadata(for: sessionID)
        for entry in pending {
            await memoryEngine.mirrorTurn(
                content: entry.content,
                sessionID: sessionID,
                role: entry.role,
                metadata: attribution,
                failurePolicy: .silent
            )
        }
    }

    /// Flushes buffered episodic mirrors without observing cancellation.
    func flushEpisodicUncancellable(
        _ pending: [(content: String, role: Message.Role)],
        sessionID: UUID
    ) async {
        guard let memoryEngine else { return }
        let attribution = await goalAttributionMetadata(for: sessionID)
        for entry in pending {
            await memoryEngine.mirrorTurnUncancellable(
                content: entry.content,
                sessionID: sessionID,
                role: entry.role,
                metadata: attribution
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

    /// Returns a cached answer response for a repeated pure question, if one hits.
    private func answerCacheEarlyResponse(
        text: String,
        source: String,
        sessionID: UUID,
        pendingEpisodic: inout [(content: String, role: Message.Role)],
        onEvent: (@Sendable (OrchestratorEvent) async -> Void)?
    ) async -> OrchestratorResponse? {
        let isParked = isSessionParked(sessionID)
        guard !SemanticAnswerCache.isExcludedTurn(source: source, executedToolCalls: 0, isParked: isParked) else { return nil }
        // A cached pure answer must never preempt recall or live freshness: the lookup runs before
        // the recall slot, so a freshness query would otherwise hit a stale pure answer and skip the
        // live tools the router plan would have required.
        guard !MemoryQueryRouter.plan(for: text, currentDate: Date()).skipDocIndex else {
            return nil
        }
        if await LiveSearchOverride.shared.shouldUseLiveSearch(for: text) {
            return nil
        }
        guard let cached = await memoryEngine?.cachedAnswer(
            for: SemanticAnswerCache.normalizedQuery(text),
            persona: persona.canonicalCacheString,
            modelID: llm.modelInfo.name
        ) else {
            return nil
        }
        let note = Message(role: .assistant, content: cached.text)
        // Stamp from the stored instant so the live response and the history reload share one time.
        let persisted = await conversations.append(note, to: sessionID)
        pendingEpisodic.append((cached.text, .assistant))
        await onEvent?(.textDelta(cached.text))
        return OrchestratorResponse(
            text: cached.text,
            sessionID: sessionID,
            toolActions: [],
            sessionTokens: sessionTokensBySession[sessionID],
            completedAt: persisted.createdAt.timeIntervalSince1970
        )
    }

    /// Files one pure Q&A answer so the next identical question hits the cache.
    private func storeAnswerCacheIfPure(query: String, source: String, finalText: String, executedToolCalls: Int, isParked: Bool = false) async {
        guard !SemanticAnswerCache.isExcludedTurn(source: source, executedToolCalls: executedToolCalls, isParked: isParked),
              OrchestratorToolLoop.shouldStoreAssistantText(finalText) else { return }
        await memoryEngine?.cacheAnswer(
            finalText,
            for: SemanticAnswerCache.normalizedQuery(query),
            persona: persona.canonicalCacheString,
            modelID: llm.modelInfo.name
        )
    }

    /// Folds this turn's billed tokens into the session total.
    /// Drops malformed negative usage like the dashboard so a drifted backend
    /// cannot decrement the stored total or leak negatives into done frames.
    func accumulateSessionTokens(_ billedTokens: Int?, for sessionID: UUID) -> Int? {
        guard let billedTokens, billedTokens >= 0 else {
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
        guard MemoryEngine.isStorableFact(factText), let memoryEngine else {
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
        var reasoning = ""
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
        do {
            // Cancelled turns never open a new stream so a late cancel between
            // tool rounds cannot start another HTTP request.
            try Task.checkCancellation()
            let effectiveMessages = VisionGate.stripMessages(messages, supportsVision: llm.modelInfo.supportsVision)
            let stream = llm.chat(messages: effectiveMessages, tools: tools, session: sessionID)
            try await withTaskCancellationHandler {
                for await chunk in stream {
                    try Task.checkCancellation()
                    if interrupted.withLock({ $0 }) {
                        break
                    }
                    if let message = chunk.errorMessage {
                        throw OrchestratorError.llmFailed(message.isEmpty ? "unknown error" : message)
                    }
                    if !chunk.reasoningDelta.isEmpty {
                        reasoning += chunk.reasoningDelta
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
                // A cancelled stream settles as cancellation even after partial
                // content when the provider suppresses its terminal marker.
                try Task.checkCancellation()
            } onCancel: {
                if let sessionID {
                    LLMCancelRegistry.shared.cancel(sessionID: sessionID)
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
            reasoning: reasoning.isEmpty ? nil : reasoning,
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

private struct TurnRecallResolution: Sendable {
    let recall: Message?
    let starterPack: Message?
    let summary: RecallSummary
}

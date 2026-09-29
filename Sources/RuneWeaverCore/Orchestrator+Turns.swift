// Rune Weaver Core — Turn helpers, token emission, and recall history for Orchestrator.

import Foundation

extension Orchestrator {
    /// Emits turn-token progress to the request event sink.
    func emitTurnTokens(
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

    /// Safe single-line recall observability, never content.
    ///
    /// Carries hit counts plus injected chars plus skip flag plus hit IDs plus
    /// sources plus scores so each turn emits exactly one diagnostics line.
    /// IDs, sources, and scores are safe to log; hit content and queries never
    /// enter this line.
    public static func recallDiagnosticsLogLine(_ diagnostics: RecallDiagnostics) -> String {
        "Orchestrator: recall \(diagnostics.logLine)"
    }

    /// Stable two-slot history keeping the prefix identical across rounds.
    /// Auto-recall lands first and the trusted starter pack lands directly
    /// before the active user turn as the second system message, so the lead
    /// system prompt plus earlier turns keep their prefix-cache tokens.
    public static func stableHistoryWithRecallAndStarter(
        _ history: [Message],
        recall: Message?,
        starterPack: Message?
    ) -> [Message] {
        let withRecall = MemoryEngine.historyWithRecall(history, recall: recall)
        return MemoryEngine.historyWithRecall(withRecall, recall: starterPack)
    }

    /// Shared turn wiring for automatic recall plus starter footing.
    ///
    /// Single source for `process` and CLI turns: one `MemoryQueryRouter.plan`
    /// plus `recallMessageWithDiagnostics` plus `RecallStarterPack.build` so
    /// terminal turns honor the same budgets and placement instead of
    /// duplicating the wiring. `Orchestrator` owns this wiring; CLI routes
    /// through here rather than rebuilding the plan plus recall plus starter.
    public static func resolveTurnRecallAndStarter(
        engine: MemoryEngine,
        query: String,
        sessionID: UUID,
        embedder: (any EmbeddingsBackend)?,
        labelingEnabled: Bool,
        budgets: RecallBudgets,
        currentDate: Date = Date()
    ) async throws -> TurnRecallAndStarter {
        let effectiveBudgets = budgets.clamped()
        let plan = MemoryQueryRouter.plan(for: query, currentDate: currentDate, budgets: effectiveBudgets)
        let (recall, diagnostics) = try await engine.recallMessageWithDiagnostics(
            for: query,
            sessionID: sessionID,
            embedder: embedder,
            labelingEnabled: labelingEnabled,
            budgets: effectiveBudgets,
            plan: plan
        )
        let starterPack = await RecallStarterPack.build(for: engine, goalLine: nil, budgets: effectiveBudgets)
        return TurnRecallAndStarter(recall: recall, starterPack: starterPack, diagnostics: diagnostics, plan: plan)
    }

    /// Refreshes recall-augmented history after one tool round.
    /// Reuses the turn's system string verbatim (never recomposes from the live
    /// registry mid-loop), the turn's recall at its stable slot, and the turn's
    /// starter pack at its stable slot. The caller passes the turn's effective
    /// prompt plus the turn's recall and starter explicitly so mid-loop history
    /// keeps the composed vision-aware prompt and the turn-start footing
    /// instead of rebuilding the starter from the live engine every round,
    /// which would shift prefix bytes when the profile or index changes mid-turn.
    func refreshedWorkingMessages(
        sessionID: UUID,
        recall: Message?,
        starterPack: Message?,
        systemPrompt: String?
    ) async -> [Message] {
        let base = await conversations.workingHistory(for: sessionID, systemPrompt: systemPrompt ?? self.systemPrompt)
        return Self.stableHistoryWithRecallAndStarter(base, recall: recall, starterPack: starterPack)
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
}

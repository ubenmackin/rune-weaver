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
    func assistantNoteMessage(text: String, calls: [ToolInput], reasoning: String? = nil) -> Message {
        Message(
            role: .assistant,
            content: OrchestratorToolLoop.assistantNoteContent(text: text, calls: calls),
            reasoning: reasoning
        )
    }

    /// Stable recall slot keeping the prefix identical across rounds.
    public static func stableHistoryWithRecall(_ history: [Message], recall: Message?) -> [Message] {
        MemoryEngine.historyWithRecall(history, recall: recall)
    }

    /// Safe single-line recall observability, never content. IDs, sources, and scores are safe to
    /// log; hit content and queries never enter this line.
    public static func recallDiagnosticsLogLine(_ diagnostics: RecallDiagnostics) -> String {
        "Orchestrator: recall \(diagnostics.logLine)"
    }

    /// Stable two-slot history keeping the prefix identical across rounds.
    public static func stableHistoryWithRecallAndStarter(
        _ history: [Message],
        recall: Message?,
        starterPack: Message?
    ) -> [Message] {
        let withRecall = MemoryEngine.historyWithRecall(history, recall: recall)
        return MemoryEngine.historyWithRecall(withRecall, recall: starterPack)
    }

    /// Shared turn wiring for automatic recall plus starter footing.
    public static func resolveTurnRecallAndStarter(
        engine: MemoryEngine,
        query: String,
        sessionID: UUID,
        embedder: any EmbeddingsBackend?,
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
        reasoning: String? = nil,
        sessionID: UUID,
        pendingEpisodic: inout [(content: String, role: Message.Role)]
    ) async -> Message? {
        guard OrchestratorToolLoop.shouldStoreAssistantText(finalText) else { return nil }
        let note = Message(role: .assistant, content: finalText, reasoning: reasoning)
        // Stamp from the stored instant so the live response and the history reload share one time.
        let persisted = await conversations.append(note, to: sessionID)
        pendingEpisodic.append((finalText, .assistant))
        return persisted
    }
}

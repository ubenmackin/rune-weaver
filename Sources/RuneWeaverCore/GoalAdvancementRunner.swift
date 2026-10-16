// Rune Weaver Core — Shared goal advancement runner for service and CLI loops.

import Foundation

/// Outcome of one advancement turn, preserving the parked signal for due handling.
public struct GoalAdvancementTurn: Sendable, Equatable {
    /// Final assistant text for the turn.
    public let text: String
    /// Whether the turn parked awaiting approval instead of finishing.
    public let isParked: Bool
    /// Whether the turn ended via forced synthesis because tool iteration budget was exceeded.
    public let isBudgetExceeded: Bool
    /// Tool invocations performed while answering, for run audit rows.
    public let toolActions: [ToolAction]
    /// Session-billed tokens for the turn, when reported.
    public let totalTokens: Int?
    /// Proactive suggestions generated because this turn achieved its goal.
    public let ideas: [Idea]

    /// Creates a turn outcome.
    public init(
        text: String,
        isParked: Bool,
        isBudgetExceeded: Bool = false,
        toolActions: [ToolAction] = [],
        totalTokens: Int? = nil,
        ideas: [Idea] = []
    ) {
        self.text = text
        self.isParked = isParked
        self.isBudgetExceeded = isBudgetExceeded
        self.toolActions = toolActions
        self.totalTokens = totalTokens
        self.ideas = ideas
    }
}

/// Single advancement implementation shared by the service worker and the CLI loop.
public enum GoalAdvancementRunner {
    /// Bounded audit rows read per tick. Single-sourced from the engine's quoted
    /// tail so the read never fans wider than the prompt consumes.
    public static let recentEventLimit = GoalEngine.eventTailLimit

    /// Composes the advancement prompt with bounded reads. Steps travel whole because plans stay
    /// small by config bound; events travel bounded because audit trails grow without bound over a
    /// goal's lifetime.
    public static func advancementPrompt(goal: Goal, store: GoalStore, engine: GoalEngine) async throws -> String {
        let steps = try await store.steps(goalID: goal.id)
        let events = try await store.events(goalID: goal.id, limit: recentEventLimit)
        return engine.advancePrompt(goal: goal, steps: steps, events: events)
    }

    /// Records a finished turn, skipping the due bump while parked.
    @discardableResult
    public static func completeAfterTurn(
        goalID: UUID,
        engine: GoalEngine,
        runID: UUID,
        isParked: Bool,
        isBudgetExceeded: Bool = false
    ) async throws -> [Idea] {
        guard !isParked else { return [] }
        if isBudgetExceeded {
            return try await engine.postBudgetExceeded(goalID: goalID, runID: runID)
        }
        return try await engine.postAdvance(goalID: goalID, runID: runID)
    }

    /// Records a failed turn by bumping the due date. One bad turn never pins the goal due forever;
    /// the next tick retries on the regular cadence instead of wedging behind the failure.
    @discardableResult
    public static func completeAfterFailure(goalID: UUID, engine: GoalEngine, runID: UUID) async throws -> [Idea] {
        try await engine.postAdvance(goalID: goalID, runID: runID)
    }

    /// Runs one advancement turn with parked-aware due handling.
    public static func advance(
        goal: Goal,
        store: GoalStore,
        engine: GoalEngine,
        runID: UUID,
        turn: @Sendable (String) async throws -> GoalAdvancementTurn,
        onPostAdvanceFailure: (@Sendable (any Error & Sendable) async -> Void)? = nil
    ) async throws -> GoalAdvancementTurn {
        // Pre-flight check: ensure the goal is active before spending a model turn.
        guard let current = try await store.goal(id: goal.id), current.status == .active else {
            return GoalAdvancementTurn(
                text: "Goal is not active.",
                isParked: false,
                isBudgetExceeded: false,
                toolActions: [],
                totalTokens: 0,
                ideas: []
            )
        }
        // Pre-flight completion: if all actionable steps are already done, achieve immediately
        // without calling the model.
        if let ideas = try await engine.checkCompletionWithIdeas(goalID: goal.id) {
            return GoalAdvancementTurn(
                text: "Goal '\(goal.title)' has completed all steps and is achieved.",
                isParked: false,
                isBudgetExceeded: false,
                toolActions: [],
                totalTokens: 0,
                ideas: ideas
            )
        }

        let prompt = try await advancementPrompt(goal: goal, store: store, engine: engine)
        let outcome: GoalAdvancementTurn
        do {
            outcome = try await turn(prompt)
        } catch is CancellationError {
            // Cancelled turns did not advance, so they stay due for the next
            // tick instead of bumping the due date underneath the cancel.
            throw CancellationError()
        } catch {
            do {
                try await completeAfterFailure(goalID: goal.id, engine: engine, runID: runID)
            } catch {
                // Erased through Any so the Sendable check stays conditional
                // instead of folding as always-succeeds; only Sendable
                // failures cross the handler boundary.
                if let onPostAdvanceFailure, let sendableError = (error as Any) as? (any Error & Sendable) {
                    await onPostAdvanceFailure(sendableError)
                }
            }
            throw error
        }
        guard !outcome.isParked else { return outcome }
        let ideas: [Idea]
        do {
            ideas = try await completeAfterTurn(
                goalID: goal.id,
                engine: engine,
                runID: runID,
                isParked: outcome.isParked,
                isBudgetExceeded: outcome.isBudgetExceeded
            )
        } catch {
            // Same Sendable-only forwarding as above: erase to Any so the
            // conditional check survives without an always-succeeds warning.
            if let onPostAdvanceFailure, let sendableError = (error as Any) as? (any Error & Sendable) {
                await onPostAdvanceFailure(sendableError)
            }
            ideas = []
        }
        // Rebuild the outcome with the achievement-born suggestions so the
        // caller can surface them; the turn closure cannot know them because
        // they are produced by the due-bookkeeping step that follows it.
        return GoalAdvancementTurn(
            text: outcome.text,
            isParked: outcome.isParked,
            isBudgetExceeded: outcome.isBudgetExceeded,
            toolActions: outcome.toolActions,
            totalTokens: outcome.totalTokens,
            ideas: ideas
        )
    }
}

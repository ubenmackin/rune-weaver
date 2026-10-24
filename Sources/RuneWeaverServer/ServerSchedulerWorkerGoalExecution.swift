// Rune Weaver Server — Scheduler worker goal execution.

import Foundation
import RuneWeaverCore

// MARK: - Goal Advancement Execution

/// Dedicated goal advancement execution methods.
extension ServerSchedulerWorker {
    /// Records an audit run entry for a goal that skipped firing because it is already running.
    func recordGoalSkipped(goal: Goal, startTime: Date) async -> SchedulerRunResult {
        if let dueAt = goal.nextDueAt {
            lastSkippedGoalDueAt[goal.id] = dueAt
        }
        let skipMsg = "Skipped goal '\(goal.title)': already running"
        await logger?(skipMsg)
        // Skipped goals create no conversation, so the audit entry stays
        // untagged with a nil session while still carrying the goal link
        // for filtering.
        let entry = await runs.append(
            kind: "goal",
            status: "skipped",
            message: skipMsg,
            sessionID: nil,
            goalID: goal.id,
            durationMs: 0
        )
        await hub.broadcastRun(entry)
        // The ephemeral result still needs a session-shaped identifier for
        // filtering, so it carries a fresh placeholder that is never
        // persisted.
        return SchedulerRunResult(
            jobName: goal.title,
            sessionID: UUID(),
            fired: false,
            skippedReason: "already running",
            fireReason: nil,
            startedAt: startTime,
            finishedAt: Date(),
            goalID: goal.id
        )
    }

    /// Records an audit run entry and broadcasts results for a successfully advanced or parked goal.
    func recordGoalSuccess(
        goal: Goal,
        sessionID: UUID,
        runID: UUID,
        outcome: GoalAdvancementTurn,
        startTime: Date,
        eventKind: ProactiveEventKind = .goalStepDone
    ) async -> SchedulerRunResult {
        let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
        // Parked goal turns remain as awaiting_approval like scheduler turns, resolving through the
        // same inbox resume path in their session.
        let runStatus = outcome.isParked ? "awaiting_approval" : (outcome.isBudgetExceeded ? "budget_exceeded" : "ok")
        let entry = await runs.update(
            id: runID,
            status: runStatus,
            response: outcome.text,
            toolActions: outcome.toolActions,
            totalTokens: outcome.totalTokens,
            durationMs: durationMs
        )
        if let entry {
            await hub.broadcastRun(entry)
        }
        if outcome.isParked, let approvals {
            let pending = await approvals.requests(for: sessionID)
            let callIDs = Set(outcome.toolActions.map(\.callID))
            for request in pending where callIDs.isEmpty || callIDs.contains(request.input.callID) {
                await hub.broadcastApproval(request)
            }
        }
        let short = ProactiveEvent.makePreview(outcome.text)
        if outcome.isParked {
            await logger?("Goal '\(goal.title)' parked awaiting approval.")
        } else if outcome.isBudgetExceeded {
            await logger?("Goal '\(goal.title)' iteration budget exceeded: \(short)")
        } else {
            await logger?("Goal fired '\(goal.title)': \(short)")
        }
        // The gate filters interruptions only; the goal row and its run
        // broadcast above always record so suppressed steps stay auditable.
        let outcomeText = outcome.text.isEmpty ? goal.title : outcome.text
        let decision = await outcomeGate.decide(event: ProactiveEvent(kind: eventKind, title: goal.title, outcome: outcomeText))
        if decision.surface {
            if let notifier {
                let title = outcome.isBudgetExceeded ? "Rune Weaver: \(goal.title) (Budget Exceeded)" : "Rune Weaver: \(goal.title)"
                await notifier.notify(
                    title: title,
                    body: short.isEmpty ? goal.title : short,
                    identifier: NotifyID.normalize(nil)
                )
            }
            await broadcastProactive(kind: eventKind, title: goal.title, headline: decision.headline, sessionID: sessionID, goalID: goal.id)
        }
        // Suggestions born from the achievement ride their own proactive frames.
        for idea in outcome.ideas {
            await broadcastIdeaProposed(idea)
        }
        return SchedulerRunResult(
            jobName: goal.title,
            sessionID: sessionID,
            fired: true,
            responseText: outcome.text,
            fireReason: nil,
            startedAt: startTime,
            finishedAt: Date(),
            goalID: goal.id
        )
    }

    /// Records an audit run entry and broadcasts error details for a failed goal advancement.
    func recordGoalFailure(
        goal: Goal,
        sessionID: UUID,
        runID: UUID,
        error: any Error,
        startTime: Date
    ) async -> SchedulerRunResult {
        let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
        let detail = error.localizedDescription
        let entry = await runs.update(
            id: runID,
            status: "error",
            response: detail,
            durationMs: durationMs
        )
        if let entry {
            await hub.broadcastRun(entry)
        }
        await logger?("Goal failed '\(goal.title)': \(detail)")
        // Failures break through under every surfacing mode except off; the
        // error row above always records so the gate never hides a failure
        // from history.
        let errorDecision = await outcomeGate.decide(event: ProactiveEvent(kind: .schedulerError, title: goal.title, outcome: detail))
        if errorDecision.surface {
            let errorPreview = ProactiveEvent.makePreview(detail)
            if let notifier {
                await notifier.notify(
                    title: "Rune Weaver: \(goal.title)",
                    body: errorPreview.isEmpty ? goal.title : errorPreview,
                    identifier: NotifyID.normalize(nil)
                )
            }
            await broadcastProactive(kind: .schedulerError, title: goal.title, headline: errorDecision.headline, sessionID: sessionID, goalID: goal.id)
        }
        return SchedulerRunResult(
            jobName: goal.title,
            sessionID: sessionID,
            fired: true,
            errorMessage: detail,
            fireReason: nil,
            startedAt: startTime,
            finishedAt: Date(),
            goalID: goal.id
        )
    }

    /// Executes one due goal under the dedicated goal single-flight lock.
    func checkCompletedPreflight(
        goal: Goal,
        store: GoalStore,
        engine: GoalEngine,
        startTime: Date
    ) async throws -> SchedulerRunResult? {
        guard let ideas = try await engine.checkCompletionWithIdeas(goalID: goal.id) else { return nil }
        await broadcastGoalSnapshot(goalID: goal.id, store: store)
        for idea in ideas {
            await broadcastIdeaProposed(idea)
        }
        let skipMsg = "Skipped goal '\(goal.title)': already achieved"
        await logger?(skipMsg)
        let entry = await runs.append(
            kind: "goal",
            status: "skipped",
            message: skipMsg,
            sessionID: nil,
            goalID: goal.id,
            response: "Goal achieved; all actionable steps completed.",
            durationMs: 0
        )
        await hub.broadcastRun(entry)
        return SchedulerRunResult(
            jobName: goal.title,
            sessionID: UUID(),
            fired: false,
            skippedReason: "already achieved",
            responseText: "Goal achieved; all actionable steps completed.",
            fireReason: nil,
            startedAt: startTime,
            finishedAt: Date(),
            goalID: goal.id
        )
    }

    /// Returns true if a goal is currently being evaluated, parked awaiting approval,
    /// or executing an active turn in an associated session.
    func isGoalBusy(id: UUID) async -> Bool {
        if await goalRunLock.isRunning(id: id) {
            return true
        }
        if await runs.hasActiveRun(goalID: id) {
            return true
        }
        if let activeTurns {
            let runningSIDs = await activeTurns.runningSessionIDs()
            for sid in runningSIDs {
                if let sess = await conversations.session(id: sid), sess.goalID == id {
                    return true
                }
            }
        }
        return false
    }

    /// Drops skip-suppression entries whose goal was deleted or reached a terminal state, keeping
    /// the in-memory high-water mark bounded. Goals already known active-and-due skip the store
    /// read, and a failed lookup keeps its entry so transient store errors never clear suppression.
    func pruneStaleGoalSkips(store: GoalStore, liveActiveDueIDs: Set<UUID>) async {
        guard !lastSkippedGoalDueAt.isEmpty else { return }
        let staleIDs = lastSkippedGoalDueAt.keys.filter { !liveActiveDueIDs.contains($0) }
        for goalID in staleIDs {
            let snapshot: Goal?
            do {
                snapshot = try await store.goal(id: goalID)
            } catch is CancellationError {
                return
            } catch {
                // Fail-open: an unreadable lookup must not clear live suppression.
                continue
            }
            guard let snapshot else {
                lastSkippedGoalDueAt.removeValue(forKey: goalID)
                continue
            }
            if snapshot.status == .achieved || snapshot.status == .abandoned {
                lastSkippedGoalDueAt.removeValue(forKey: goalID)
            }
        }
    }

    func advanceGoalTurn(
        goal: Goal,
        store: GoalStore,
        engine: GoalEngine,
        sessionID: UUID,
        runID: UUID,
        taskBox: TurnTaskBox
    ) async throws -> GoalAdvancementTurn {
        let turnOrchestrator = orchestrator
        let turnSessionID = sessionID
        let turnGoalID = goal.id
        let bumpLogger = logger
        let bumpTitle = goal.title
        let turnHub = hub
        let maxIterations = goalsConfig.maxToolIterations
        return try await GoalAdvancementRunner.advance(
            goal: goal,
            store: store,
            engine: engine,
            runID: runID,
            turn: { prompt in
                let runTask: Task<OrchestratorResponse, any Error> = Task {
                    try await turnOrchestrator.process(
                        input: UserInput(
                            text: prompt,
                            sessionID: turnSessionID,
                            source: "goal",
                            goalID: turnGoalID,
                            toolLimitPolicy: .forceSynthesis,
                            maxToolIterations: maxIterations
                        ),
                        onEvent: { event in
                            await broadcastWSEventFrame(event, sessionID: turnSessionID, hub: turnHub)
                        }
                    )
                }
                taskBox.set(runTask)
                let response = try await runTask.value
                await broadcastStreamDone(for: response, sessionID: turnSessionID, hub: turnHub)
                return GoalAdvancementTurn(
                    text: response.text,
                    isParked: response.isParked,
                    isBudgetExceeded: response.isBudgetExceeded,
                    toolActions: response.toolActions,
                    totalTokens: response.totalTokens
                )
            },
            onPostAdvanceFailure: { error in
                await bumpLogger?("Goal '\(bumpTitle)' post-advance failed: \(error.localizedDescription)")
            }
        )
    }

    func executeGoal(_ goal: Goal, store: GoalStore, engine: GoalEngine) async throws -> SchedulerRunResult {
        let startTime = Date()

        // Pre-flight check: if all actionable steps are already completed, achieve immediately
        // without acquiring a run lock, creating a session, or dispatching an LLM turn.
        if let completed = try await checkCompletedPreflight(goal: goal, store: store, engine: engine, startTime: startTime) {
            return completed
        }

        guard await !isGoalBusy(id: goal.id), await goalRunLock.tryAcquire(id: goal.id, name: goal.title) else {
            return await recordGoalSkipped(goal: goal, startTime: startTime)
        }
        lastSkippedGoalDueAt.removeValue(forKey: goal.id)
        let claimedNextDue = startTime.addingTimeInterval(TimeInterval(goal.stepIntervalMinutes * 60))
        try? await store.markAdvanced(goalID: goal.id, nextDueAt: claimedNextDue)

        let sessionID = await makeGoalRunSession(goal: goal, conversations: conversations)

        let initialEntry = await runs.append(
            kind: "goal",
            status: "running",
            message: goal.title,
            sessionID: sessionID,
            goalID: goal.id,
            durationMs: 0
        )
        await hub.broadcastRun(initialEntry)

        // The goal lock is held for the whole turn and released with a
        // structured await before returning, so the next tick never observes
        // a stale held lock from a detached release racing the return.
        let taskBox = TurnTaskBox()
        let registration = await activeTurns?.register(sessionID: sessionID, onCancel: { taskBox.cancel() })
        let result: SchedulerRunResult
        do {
            let outcome = try await advanceGoalTurn(
                goal: goal,
                store: store,
                engine: engine,
                sessionID: sessionID,
                runID: initialEntry.id,
                taskBox: taskBox
            )
            if let registration {
                await activeTurns?.unregister(sessionID: sessionID, token: registration.token)
            }
            let eventKind = await resolveGoalEventKind(goal: goal, store: store, outcome: outcome)
            result = await recordGoalSuccess(
                goal: goal,
                sessionID: sessionID,
                runID: initialEntry.id,
                outcome: outcome,
                startTime: startTime,
                eventKind: eventKind
            )
            // The turn may have moved steps or flipped lifecycle state through
            // `goal.progress`, so push the fresh row for live dashboards; the
            // run broadcast above already carried the audit entry.
            await broadcastGoalSnapshot(goalID: goal.id, store: store)
        } catch is CancellationError {
            if let registration {
                await activeTurns?.unregister(sessionID: sessionID, token: registration.token)
            }
            // Cancelled turns did not advance, so they stay due: restore the
            // pre-claim due date, mark the run cancelled (never error), release
            // the lock, then propagate.
            try? await store.markAdvanced(goalID: goal.id, nextDueAt: goal.nextDueAt)
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            if let entry = await runs.update(
                id: initialEntry.id,
                status: "cancelled",
                durationMs: durationMs
            ) {
                await hub.broadcastRun(entry)
            }
            await goalRunLock.release(id: goal.id, name: goal.title)
            throw CancellationError()
        } catch {
            if let registration {
                await activeTurns?.unregister(sessionID: sessionID, token: registration.token)
            }
            result = await recordGoalFailure(
                goal: goal,
                sessionID: sessionID,
                runID: initialEntry.id,
                error: error,
                startTime: startTime
            )
            // Even a failed turn bumps the due date (never pins due), so the
            // row refresh keeps the new due instant visible without a refetch.
            await broadcastGoalSnapshot(goalID: goal.id, store: store)
        }

        await goalRunLock.release(id: goal.id, name: goal.title)
        return result
    }

    /// Contention signal for manual goal advancement when the goal is already running.
    public struct GoalBusyError: Error, Sendable {
        /// Creates a busy signal.
        public init() {}
    }

    /// Advances one goal immediately, bypassing its due cadence.
    public func advanceGoalNow(goalID: UUID) async throws -> (runID: UUID, sessionID: UUID) {
        guard let store = goalStore, let engine = goalEngine, await engine.isEnabled else {
            throw GoalEngineError.disabled
        }
        guard let goal = try await store.goal(id: goalID) else {
            throw GoalStoreError.notFound("No goal \(goalID)")
        }
        guard goal.status == .active else { throw GoalEngineError.notActive(status: goal.status.rawValue) }
        let startTime = Date()
        guard await !isGoalBusy(id: goal.id), await goalRunLock.tryAcquire(id: goal.id, name: goal.title) else {
            _ = await recordGoalSkipped(goal: goal, startTime: startTime)
            throw GoalBusyError()
        }
        lastSkippedGoalDueAt.removeValue(forKey: goal.id)
        let claimedNextDue = startTime.addingTimeInterval(TimeInterval(goal.stepIntervalMinutes * 60))
        try? await store.markAdvanced(goalID: goal.id, nextDueAt: claimedNextDue)
        let sessionID = await makeGoalRunSession(goal: goal, conversations: conversations)
        let initialEntry = await runs.append(
            kind: "goal",
            status: "running",
            message: goal.title,
            sessionID: sessionID,
            goalID: goal.id,
            durationMs: 0
        )
        await hub.broadcastRun(initialEntry)
        let taskBox = TurnTaskBox()
        let registration = await activeTurns?.register(sessionID: sessionID, onCancel: { taskBox.cancel() })
        do {
            let outcome = try await advanceGoalTurn(
                goal: goal,
                store: store,
                engine: engine,
                sessionID: sessionID,
                runID: initialEntry.id,
                taskBox: taskBox
            )
            if let registration {
                await activeTurns?.unregister(sessionID: sessionID, token: registration.token)
            }
            let eventKind = await resolveGoalEventKind(goal: goal, store: store, outcome: outcome)
            _ = await recordGoalSuccess(
                goal: goal,
                sessionID: sessionID,
                runID: initialEntry.id,
                outcome: outcome,
                startTime: startTime,
                eventKind: eventKind
            )
            await broadcastGoalSnapshot(goalID: goal.id, store: store)
            await goalRunLock.release(id: goal.id, name: goal.title)
            return (runID: initialEntry.id, sessionID: sessionID)
        } catch is CancellationError {
            if let registration {
                await activeTurns?.unregister(sessionID: sessionID, token: registration.token)
            }
            try? await store.markAdvanced(goalID: goal.id, nextDueAt: goal.nextDueAt)
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            if let entry = await runs.update(
                id: initialEntry.id,
                status: "cancelled",
                durationMs: durationMs
            ) {
                await hub.broadcastRun(entry)
            }
            await goalRunLock.release(id: goal.id, name: goal.title)
            throw CancellationError()
        } catch {
            if let registration {
                await activeTurns?.unregister(sessionID: sessionID, token: registration.token)
            }
            _ = await recordGoalFailure(
                goal: goal,
                sessionID: sessionID,
                runID: initialEntry.id,
                error: error,
                startTime: startTime
            )
            await broadcastGoalSnapshot(goalID: goal.id, store: store)
            await goalRunLock.release(id: goal.id, name: goal.title)
            throw error
        }
    }

    /// Pushes the current goal row to live sockets after an advancement turn. Best-effort refresh
    /// so dashboards patch one row instead of refetching; failures only log because the run row and
    /// its broadcast already landed.
    func broadcastGoalSnapshot(goalID: UUID, store: GoalStore) async {
        do {
            if let goal = try await store.goal(id: goalID) {
                let steps: [GoalStep]
                do {
                    steps = try await store.steps(goalID: goalID)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    await logger?("Goal snapshot steps lookup failed for \(goalID): \(error.localizedDescription)")
                    steps = []
                }
                await hub.broadcastGoal(GoalDTO(goal: goal, steps: steps))
            }
        } catch is CancellationError {
            return
        } catch {
            await logger?("Goal snapshot broadcast failed: \(error.localizedDescription)")
        }
    }
}

/// Creates an isolated per-run goal session for one advancement fire.
func makeGoalRunSession(goal: Goal, conversations: ConversationManager) async -> UUID {
    let sessionID = UUID()
    await conversations.ensureSession(id: sessionID, title: goal.title, source: "goal", overwrite: true, goalID: goal.id)
    return sessionID
}

// Rune Weaver Core — Long-horizon goal pursuit engine.
//
// Owns the lifecycle around durable goals: opt-in creation with an active-goal
// cap, single-call plan decomposition settling to `unplanned` with empty steps
// plus an audit note when planning is cancelled or unusable, per-run
// advancement prompts composed as user text for composer cache stability, and
// due-date bookkeeping after each run.
// Persistence lives in GoalStore; the language provider is injected from the
// same instance that serves chat turns so planning and execution share one
// model posture. This engine never mints its own provider.

import Foundation

/// Failures raised by ``GoalEngine``.
public enum GoalEngineError: Error, Sendable, Equatable {
    /// Goal pursuit is disabled by configuration.
    case disabled
    /// The active-goal cap is reached.
    case capReached(limit: Int)
    /// The referenced goal does not exist.
    case notFound(UUID)
}

extension GoalEngineError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .disabled:
            "Goal pursuit is disabled. Enable [goals] to create goals."
        case let .capReached(limit):
            "Active goal cap \(limit) reached. Pause or complete a goal first."
        case let .notFound(id):
            "No goal \(id)."
        }
    }
}

/// Steady pursuit of long-horizon goals with LLM-assisted decomposition.
public actor GoalEngine {
    /// Bounded audit rows quoted in the advancement prompt.
    /// Single-sources the tail bound so the runner's read limit and the
    /// prompt's quoted suffix cannot drift apart.
    public static let eventTailLimit = 5
    /// Durable goal, step, and event persistence.
    private let store: GoalStore
    /// Injected language provider shared with chat turns; never self-built so
    /// planning observes the same model, routing, and fallback posture.
    private var llm: any LLMProvider
    /// Pursuit policy clamped at init so hand-built configs degrade to the
    /// nearest sane bound instead of refusing to run.
    private let config: GoalsConfig
    /// In-flight background decomposition tasks keyed by goal.
    ///
    /// Stored instead of fire-and-forget so creation hands back trackable work:
    /// callers needing determinism await `waitForPendingPlan`, and shutdown
    /// paths can cancel through `cancelPendingPlans` instead of leaking a
    /// detached task past the engine's lifetime. Each entry carries its run ID
    /// so a duplicate plan request returns the in-flight run instead of
    /// overwriting and leaking the prior handle.
    private var planTasks: [UUID: (runID: UUID, task: Task<Void, Never>)] = [:]
    /// Optional ideas engine refreshed when a goal reaches achieved.
    ///
    /// The natural "what next" moment is the completion of a goal, so the
    /// engine is injected rather than discovered; when absent, achievement
    /// simply records its events as before and no suggestion call is spent.
    private let ideasEngine: IdeasEngine?
    /// Seam reporting planning lifecycle events to the audit log and socket hub.
    private let reporter: any GoalPlanReporting
    /// Shared semantic answer cache cleared on every goal mutation, so a pure
    /// answer cached before a plan, status, or trigger change never replays
    /// stale text. Nil keeps the engine standalone for direct-core callers.
    private var answerCache: SemanticAnswerCache?

    /// Creates a goal engine over shared collaborators.
    /// - Parameters:
    ///   - store: Durable goal persistence.
    ///   - llm: Injected provider shared with chat turns.
    ///   - config: Pursuit policy.
    ///   - ideasEngine: Optional ideas engine refreshed on achievement.
    ///   - reporter: Reporting seam for plan runs.
    public init(
        store: GoalStore,
        llm: any LLMProvider,
        config: GoalsConfig,
        ideasEngine: IdeasEngine? = nil,
        reporter: any GoalPlanReporting = NullGoalPlanReporter()
    ) {
        self.store = store
        self.llm = llm
        self.config = config.clamped()
        self.ideasEngine = ideasEngine
        self.reporter = reporter
    }

    /// Wires the shared semantic answer cache for goal-change invalidation.
    /// - Parameter cache: Cache cleared on every goal mutation, or nil to detach.
    public func setAnswerCache(_ cache: SemanticAnswerCache?) {
        answerCache = cache
    }

    /// Clears the shared semantic answer cache because a goal change can
    /// rewrite future pure answers.
    private func invalidateAnswerCache() async {
        await answerCache?.invalidateOnMemoryWrite()
    }

    /// Dynamically updates the serving LLM provider without a restart.
    public func updateLLM(_ provider: any LLMProvider) {
        self.llm = provider
    }

    /// Whether steady goal pursuit is enabled by configuration.
    /// The scheduler worker consults this before scanning due goals so a
    /// disabled install never spends advancement turns on pre-existing rows.
    public var isEnabled: Bool {
        config.enabled
    }

    /// Maximum event triggers armed on one goal, clamped at boot.
    ///
    /// Exposed so REST trigger replacement can enforce the same per-goal budget
    /// `create` already applies instead of reaching for the absolute bound.
    public var maxTriggersPerGoal: Int {
        config.maxTriggersPerGoal
    }

    /// Creates a goal in `unplanned` with empty steps and plans in the background.
    ///
    /// The goal starts with no steps so the later decomposition fills the plan
    /// without touching finished history. The background plan is best-effort
    /// and idempotent: its task handle is tracked per goal, so callers needing
    /// determinism await `waitForPendingPlan` (or `decompose` explicitly)
    /// instead of sleeping on an unstructured fire-and-forget.
    /// - Parameters:
    ///   - title: Short human-readable title stored verbatim.
    ///   - statement: Fuller intent shown to the owner and model.
    ///   - cadence: Cadence hint in minutes; defaults to the configured interval
    ///     and clamps into the validated range so a typo never stalls dues.
    ///   - originSessionID: Session that originated the goal, when known.
    ///   - triggers: Event wake-ups to arm alongside the goal; clamped to the
    ///     configured per-goal budget and persisted after the goal row.
    /// - Returns: The persisted goal snapshot.
    public func create(
        title: String,
        statement: String,
        cadence: Int? = nil,
        originSessionID: UUID? = nil,
        triggers: [GoalTriggerDraft] = []
    ) async throws -> Goal {
        guard config.enabled else {
            throw GoalEngineError.disabled
        }
        let cap = config.maxActiveGoals
        let activeCount = try await store.activeGoalCount()
        guard activeCount < cap else {
            throw GoalEngineError.capReached(limit: cap)
        }
        let interval: Int = if let cadence {
            min(max(cadence, GoalsConfig.minStepIntervalMinutes), GoalsConfig.maxStepIntervalMinutes)
        } else {
            config.stepIntervalMinutes
        }
        let now = Date()
        let goal = Goal(
            title: title,
            statement: statement,
            status: .unplanned,
            stepIntervalMinutes: interval,
            nextDueAt: now.addingTimeInterval(TimeInterval(interval * 60)),
            originSessionID: originSessionID,
            createdAt: now,
            updatedAt: now
        )
        try await store.create(goal: goal, steps: [])
        // A new goal rewrites future pure answers, so cached text from before
        // it must not survive the mutation.
        await invalidateAnswerCache()
        // Triggers are secondary to the goal itself: a store failure arming one
        // is logged rather than thrown, so a created goal is never reported as a
        // failure because an event wake-up could not be persisted. Blank kinds
        // drop and the per-goal budget caps the fan-out.
        let triggerBudget = config.maxTriggersPerGoal
        if triggerBudget > 0 {
            for draft in triggers.prefix(triggerBudget) {
                let kind = draft.eventKind.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !kind.isEmpty else { continue }
                let cooldown = max(
                    GoalsConfig.minTriggerCooldownMinutes,
                    draft.cooldownMinutes ?? GoalsConfig.defaultTriggerCooldownMinutes
                )
                do {
                    _ = try await store.addTrigger(
                        goalID: goal.id,
                        eventKind: kind,
                        pattern: draft.pattern,
                        cooldownMinutes: cooldown
                    )
                } catch {
                    RuneWeaverLog.scheduler.warning("GoalEngine: failed to arm trigger for goal \(goal.id): \(error.localizedDescription)")
                }
            }
        }
        let captured = goal
        let runID = UUID()
        // Tracked, not detached: the handle lets deterministic callers await the
        // plan and shutdown paths cancel it, while creation still returns the
        // snapshot immediately. Guarded so a duplicate never overwrites the
        // in-flight handle.
        if planTasks[goal.id] == nil {
            let planTask = Task {
                await self.decompose(goal: captured, runID: runID)
                await self.finishPlanTask(for: captured.id)
            }
            planTasks[goal.id] = (runID: runID, task: planTask)
        }
        return goal
    }

    /// Removes a finished background plan task from tracking.
    ///
    /// Async so the awaiting task has an async operation to await while
    /// hopping back to the actor to mutate tracked plans.
    /// - Parameter goalID: Goal whose plan completed.
    private func finishPlanTask(for goalID: UUID) async {
        planTasks.removeValue(forKey: goalID)
    }

    /// Reports whether a background planning task is currently in flight for the given goal.
    /// - Parameter goalID: Goal identifier.
    /// - Returns: True if decomposition is running right now.
    public func isPlanning(goalID: UUID) -> Bool {
        planTasks[goalID] != nil
    }

    /// Cancels the in-flight background plan task for one specific goal.
    /// - Parameter goalID: Goal whose plan to cancel.
    public func cancelPlan(goalID: UUID) {
        if let entry = planTasks.removeValue(forKey: goalID) {
            entry.task.cancel()
        }
    }

    /// Launches a background decomposition task for an unplanned goal and returns its run ID.
    ///
    /// Single-flight inside the actor: when a plan is already in flight for the
    /// goal, the existing run ID returns and no new task is created, so
    /// concurrent `isPlanning` checks cannot overwrite and leak the prior
    /// handle. Callers still check `isPlanning` first for the honest `409`;
    /// this guard closes the check-then-act race.
    /// - Parameter goal: Goal to plan for.
    /// - Returns: Unique run ID for the planning turn, or the in-flight run ID when already planning.
    @discardableResult
    public func startPlanTask(for goal: Goal) -> UUID {
        if let existing = planTasks[goal.id] {
            return existing.runID
        }
        let runID = UUID()
        let captured = goal
        let planTask = Task {
            await self.decompose(goal: captured, runID: runID)
            await self.finishPlanTask(for: captured.id)
        }
        planTasks[goal.id] = (runID: runID, task: planTask)
        return runID
    }

    /// Awaits the background decomposition for one goal, when one is in flight.
    ///
    /// Creation returns immediately while planning lands shortly after; tests and
    /// other deterministic callers await this instead of sleeping. A goal with
    /// no in-flight plan returns immediately, and cancellation of the tracked
    /// task surfaces here as an early return once the task observes it.
    /// - Parameter goalID: Goal whose plan to await.
    public func waitForPendingPlan(goalID: UUID) async {
        if let entry = planTasks[goalID] {
            await entry.task.value
        }
    }

    /// Cancels every in-flight background plan.
    public func cancelPendingPlans() {
        for entry in planTasks.values {
            entry.task.cancel()
        }
        planTasks.removeAll()
    }

    /// Decomposes one goal into a bounded plan with a single model call.
    ///
    /// When planning succeeds, the steps are stored and the goal transitions
    /// from `unplanned` to `active`. When cancelled or unusable, the goal
    /// transitions into `unplanned` without dummy fallback steps so it remains
    /// clear that no plan exists yet.
    /// - Parameters:
    ///   - goal: Goal snapshot to plan for.
    ///   - runID: Run identifier for audit logging and broadcast.
    public func decompose(goal: Goal, runID: UUID = UUID()) async {
        let start = Date()
        let runEvent = GoalPlanRunEvent(
            id: runID,
            goalID: goal.id,
            goalTitle: goal.title,
            status: "running",
            message: "Drafting plan for \"\(goal.title)\"",
            timestamp: start
        )
        await reporter.planStarted(runEvent)

        let maxSteps = config.maxStepsPerGoal
        let prompt = Self.decomposePrompt(for: goal, maxSteps: maxSteps)
        let rawText: String?
        do {
            rawText = try await collectPlanText(prompt: prompt)
        } catch is CancellationError {
            await handlePlanningCancelled(goal: goal, runID: runID, start: start)
            return
        } catch {
            if Task.isCancelled {
                await handlePlanningCancelled(goal: goal, runID: runID, start: start)
                return
            }
            await handlePlanningFailed(goal: goal, runID: runID, start: start, errorMsg: error.localizedDescription)
            return
        }
        if Task.isCancelled {
            await handlePlanningCancelled(goal: goal, runID: runID, start: start)
            return
        }
        guard let rawText, !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let titles = Self.extractPlanTitles(from: rawText, maxSteps: maxSteps),
              !titles.isEmpty
        else {
            if Task.isCancelled {
                await handlePlanningCancelled(goal: goal, runID: runID, start: start)
                return
            }
            await handlePlanningFailed(goal: goal, runID: runID, start: start, errorMsg: "Unusable model output")
            return
        }
        let steps = titles.enumerated().map { index, title in
            GoalStep(goalID: goal.id, ordinal: index, title: title, status: .pending)
        }
        do {
            try await store.replacePlan(goalID: goal.id, steps: steps)
            try await store.setStatus(goalID: goal.id, status: .active)
            await invalidateAnswerCache()
        } catch {
            RuneWeaverLog.scheduler.error("GoalEngine: failed to persist plan for goal \(goal.id): \(error.localizedDescription)")
        }
        let durationMs = Int(Date().timeIntervalSince(start) * 1000)
        await reporter.planCompleted(GoalPlanRunEvent(
            id: runID,
            goalID: goal.id,
            goalTitle: goal.title,
            status: "ok",
            message: "Drafting plan for \"\(goal.title)\"",
            response: "Drafted plan with \(steps.count) steps.",
            durationMs: durationMs,
            timestamp: Date()
        ))
    }

    private func handlePlanningCancelled(goal: Goal, runID: UUID, start: Date) async {
        let durationMs = Int(Date().timeIntervalSince(start) * 1000)
        try? await store.setStatus(goalID: goal.id, status: .unplanned)
        _ = try? await store.appendEvent(
            goalID: goal.id,
            kind: .note,
            message: "Planning cancelled by user."
        )
        await reporter.planCompleted(GoalPlanRunEvent(
            id: runID,
            goalID: goal.id,
            goalTitle: goal.title,
            status: "cancelled",
            message: "Drafting plan for \"\(goal.title)\"",
            response: "Planning cancelled.",
            durationMs: durationMs,
            timestamp: Date()
        ))
    }

    private func handlePlanningFailed(goal: Goal, runID: UUID, start: Date, errorMsg: String) async {
        let durationMs = Int(Date().timeIntervalSince(start) * 1000)
        try? await store.setStatus(goalID: goal.id, status: .unplanned)
        _ = try? await store.appendEvent(
            goalID: goal.id,
            kind: .note,
            message: "Planning could not extract valid steps from model output. Goal marked unplanned."
        )
        await reporter.planCompleted(GoalPlanRunEvent(
            id: runID,
            goalID: goal.id,
            goalTitle: goal.title,
            status: "error",
            message: "Drafting plan for \"\(goal.title)\"",
            response: "Planning failed: \(errorMsg)",
            durationMs: durationMs,
            timestamp: Date()
        ))
    }

    /// Decomposes one goal looked up by identifier.
    ///
    /// Convenience for callers holding only the identifier; unknown goals are
    /// a quiet no-op so scheduled retries never throw on a deleted goal.
    /// - Parameters:
    ///   - goalID: Identifier of the goal to plan for.
    ///   - runID: Optional run identifier.
    public func decompose(goalID: UUID, runID: UUID = UUID()) async {
        let goal: Goal?
        do {
            goal = try await store.goal(id: goalID)
        } catch is CancellationError {
            return
        } catch {
            RuneWeaverLog.stores.error("GoalEngine: failed to load goal \(goalID): \(error.localizedDescription)")
            return
        }
        guard let goal else { return }
        await decompose(goal: goal, runID: runID)
    }

    /// Composes the per-run advancement prompt as user text.
    ///
    /// Kept out of the system prompt so the composer's cached prefix stays
    /// stable across goals and runs. The numbered plan carries statuses so the
    /// model sees what is done without re-reading history, and only the tail
    /// events travel so long audit trails do not crowd execution.
    /// - Parameters:
    ///   - goal: Goal being advanced.
    ///   - steps: Full plan ordered by ordinal.
    ///   - events: Audit trail oldest first; only the tail is quoted.
    /// - Returns: Prompt text for the advancement turn.
    public nonisolated func advancePrompt(goal: Goal, steps: [GoalStep], events: [GoalEvent]) -> String {
        let ordered = steps.sorted { $0.ordinal < $1.ordinal }
        var lines: [String] = []
        lines.append("Goal: \(goal.title)")
        lines.append("Statement: \(goal.statement)")
        lines.append("")
        lines.append("Plan:")
        if ordered.isEmpty {
            lines.append("No steps yet.")
        } else {
            for step in ordered {
                lines.append("\(step.ordinal + 1). [\(step.status.rawValue)] \(step.title)")
            }
        }
        lines.append("")
        lines.append("Recent events:")
        let tail = Array(events.suffix(Self.eventTailLimit))
        if tail.isEmpty {
            lines.append("None yet.")
        } else {
            for event in tail {
                lines.append("- \(event.kind.rawValue): \(event.message)")
            }
        }
        lines.append("")
        lines.append("Advance exactly the next actionable step and no further.")
        lines.append("When you complete a step, call goal.progress on completion with its outcome.")
        lines.append("Record blockers honestly instead of marking blocked work done.")
        lines.append("Do not rush later steps; leave them pending until their turn.")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Planning Internals

extension GoalEngine {
    /// Builds the single-shot decomposition instruction.
    ///
    /// The JSON-array demand is explicit and the step bound repeats in words
    /// and digits so even a terse local model returns a parseable list.
    static func decomposePrompt(for goal: Goal, maxSteps: Int) -> String {
        [
            "Break the following goal into at most \(maxSteps) concrete steps.",
            "Goal: \(goal.title)",
            "Statement: \(goal.statement)",
            "Reply with ONLY a JSON array of objects like [{\"title\": \"First step\"}, {\"title\": \"Second step\"}].",
            "Each object must carry a \"title\" string. At most \(maxSteps) steps. Be direct and concise. "
                + "No commentary or markdown formatting outside the JSON array."
        ].joined(separator: "\n")
    }

    /// Extracts bounded step titles from chatty model output.
    ///
    /// Fences are removed before scanning so ```json blocks decode, and the
    /// outermost brackets win so leading prose and trailing sign-offs survive.
    /// Bare string arrays degrade gracefully, and blank titles drop rather
    /// than becoming empty steps.
    /// - Parameters:
    ///   - raw: Raw model text.
    ///   - maxSteps: Upper bound on returned titles.
    ///   - Returns: Titles, or nil when nothing parseable remains.
    static func extractPlanTitles(from raw: String, maxSteps: Int) -> [String]? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.contains("```") {
            // Fence-tolerant: drop markers rather than trying to pair them, so
            // unclosed or language-tagged fences still expose the array. The
            // first replace is case-insensitive and already covers every
            // casing, so no second pass is needed.
            text = text.replacingOccurrences(of: "```json", with: "", options: .caseInsensitive)
            text = text.replacingOccurrences(of: "```", with: "")
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let open = text.firstIndex(of: "["),
              let close = text.lastIndex(of: "]"),
              open < close
        else { return nil }
        let candidate = String(text[open ... close])
        guard let data = candidate.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data, options: []),
              let array = parsed as? [Any]
        else { return nil }
        var titles: [String] = []
        for element in array {
            if let object = element as? [String: Any],
               let title = object["title"] as? String
            {
                let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    titles.append(trimmed)
                }
            } else if let bare = element as? String {
                let trimmed = bare.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    titles.append(trimmed)
                }
            }
        }
        guard !titles.isEmpty else { return nil }
        let bound = max(1, maxSteps)
        return Array(titles.prefix(bound))
    }

    /// Collects one planning reply under the configured timeout.
    ///
    /// If planTimeoutSeconds is 0, planning runs with no artificial timeout,
    /// relying instead on cooperative Task cancellation (e.g. user cancellation).
    /// The timeout clamps to `0...maxPlanTimeoutSeconds` so an unvalidated
    /// hand-built config never holds planning beyond the shared upper bound.
    private func collectPlanText(prompt: String) async throws -> String? {
        let timeoutSeconds = min(max(config.planTimeoutSeconds, GoalsConfig.unlimitedPlanTimeoutSeconds), GoalsConfig.maxPlanTimeoutSeconds)
        if timeoutSeconds == 0 {
            return try await collectOnce(prompt: prompt)
        }
        let timeoutNS = UInt64(timeoutSeconds) * 1_000_000_000
        return try await withThrowingTaskGroup(of: String?.self, returning: String?.self) { group in
            group.addTask {
                try await self.collectOnce(prompt: prompt)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNS)
                return nil
            }
            guard let first = try await group.next() else { return nil }
            group.cancelAll()
            try Task.checkCancellation()
            return first
        }
    }

    /// Runs the single planning chat call and folds its stream to text.
    ///
    /// No tools travel because planning is pure text in, JSON out; a mid-
    /// stream provider error degrades to nil so the caller settles to
    /// `unplanned` instead of planning from a truncated fragment.
    /// Cancellation rethrows so the caller preserves the `unplanned` empty
    /// steps instead of storing a partial plan.
    private func collectOnce(prompt: String) async throws -> String? {
        let messages = [Message(role: .user, content: prompt)]
        let stream = llm.chat(messages: messages, tools: [])
        var text = ""
        do {
            for await chunk in stream {
                try Task.checkCancellation()
                if chunk.errorMessage != nil {
                    return nil
                }
                text += chunk.delta
                if chunk.isFinished {
                    break
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
        try Task.checkCancellation()
        return text
    }
}

// MARK: - Goal Lifecycle & Status Management

extension GoalEngine {
    /// Records the aftermath of one advancement run.
    ///
    /// Steps already moved through `goal.progress` during the turn, so this
    /// re-reads them: an empty actionable scan on an active goal means the
    /// plan is finished and flips to achieved with its completion event. The
    /// due date always bumps by the goal's own cadence so the next run keeps
    /// its rhythm. The run identifier lands as an audit event so scheduler
    /// runs stay correlatable to the advancement they caused.
    /// - Parameters:
    ///   - goalID: Goal that just ran.
    ///   - runID: Opaque correlation for the audit event.
    /// - Returns: Suggestions generated because this turn achieved the goal.
    @discardableResult
    public func postAdvance(goalID: UUID, runID: UUID) async throws -> [Idea] {
        guard let goal = try await store.goal(id: goalID) else {
            throw GoalEngineError.notFound(goalID)
        }
        let generated = try await checkCompletionWithIdeas(goalID: goalID) ?? []
        let bumped = Date().addingTimeInterval(TimeInterval(goal.stepIntervalMinutes * 60))
        try await store.markAdvanced(goalID: goalID, nextDueAt: bumped)
        try await store.appendEvent(goalID: goalID, kind: .note, message: "Advanced by run \(runID.uuidString).")
        await invalidateAnswerCache()
        return generated
    }

    /// Evaluates whether an active goal has completed all actionable steps,
    /// flipping it to achieved if no actionable steps remain and returning generated ideas.
    /// - Parameter goalID: Goal to check.
    /// - Returns: Generated ideas if goal transitioned to achieved, nil otherwise.
    @discardableResult
    public func checkCompletionWithIdeas(goalID: UUID) async throws -> [Idea]? {
        guard let goal = try await store.goal(id: goalID), goal.status == .active else {
            return nil
        }
        let next = try await store.nextActionableStep(goalID: goalID)
        if next == nil {
            try await store.setStatus(goalID: goalID, status: .achieved)
            await invalidateAnswerCache()
            return await ideasEngine?.generate() ?? []
        }
        return nil
    }

    /// Evaluates whether an active goal has completed all actionable steps,
    /// flipping it to achieved if no actionable steps remain.
    /// - Parameter goalID: Goal to check.
    /// - Returns: True if the goal was flipped to achieved, false otherwise.
    @discardableResult
    public func checkCompletion(goalID: UUID) async throws -> Bool {
        let ideas = try await checkCompletionWithIdeas(goalID: goalID)
        return ideas != nil
    }

    /// Reconciles all active goals that have completed all actionable steps, flipping them to achieved.
    /// - Returns: List of goal IDs that transitioned to achieved.
    @discardableResult
    public func reconcileActiveGoalsCompletion() async throws -> [UUID] {
        let activeGoals = try await store.list(status: .active)
        var completed: [UUID] = []
        for goal in activeGoals where try await checkCompletion(goalID: goal.id) {
            completed.append(goal.id)
        }
        return completed
    }

    /// Records a budget-exceeded turn outcome, bumping due date or escalating to needs_input.
    @discardableResult
    public func postBudgetExceeded(goalID: UUID, runID: UUID) async throws -> [Idea] {
        guard let goal = try await store.goal(id: goalID) else {
            throw GoalEngineError.notFound(goalID)
        }
        _ = try await store.appendEvent(
            goalID: goalID,
            kind: .stepBudgetExceeded,
            message: "Step iteration budget exceeded by run \(runID.uuidString)."
        )
        let recentEvents = try await store.events(goalID: goalID, limit: config.maxStepBudgetExceededRetries)
        let consecutiveCount = recentEvents.reversed().prefix(while: { $0.kind == .stepBudgetExceeded }).count
        if consecutiveCount >= config.maxStepBudgetExceededRetries {
            try await needsInput(
                goalID: goalID,
                reason: "Goal step stalled after \(consecutiveCount) budget-exceeded turns; escalating to needs_input."
            )
            return []
        } else {
            let bumped = Date().addingTimeInterval(TimeInterval(goal.stepIntervalMinutes * 60))
            try await store.markAdvanced(goalID: goalID, nextDueAt: bumped)
            return []
        }
    }

    /// Parks a goal awaiting owner input, keeping the reason visible.
    public func needsInput(goalID: UUID, reason: String) async throws {
        try await store.setStatus(goalID: goalID, status: .needsInput)
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            try await store.appendEvent(goalID: goalID, kind: .needsInput, message: trimmed)
        }
        await invalidateAnswerCache()
    }

    /// Pauses pursuit of a goal.
    public func pause(goalID: UUID) async throws {
        try await store.setStatus(goalID: goalID, status: .paused)
        await invalidateAnswerCache()
    }

    /// Resumes a paused or parked goal back to active.
    public func resume(goalID: UUID) async throws {
        try await store.setStatus(goalID: goalID, status: .active)
        await invalidateAnswerCache()
    }

    /// Abandons a goal; the terminal note preserves why it was dropped.
    public func abandon(goalID: UUID) async throws {
        try await store.setStatus(goalID: goalID, status: .abandoned)
        await invalidateAnswerCache()
    }

    /// Deletes a goal with its steps and events.
    public func delete(goalID: UUID) async throws {
        try await store.delete(goalID: goalID)
        await invalidateAnswerCache()
    }
}

// MARK: - Event-trigger bridge

/// Polls the shared event stream and arms due goals from armed triggers.
///
/// The bridge adds no firing machinery of its own: it reads recent goal audit
/// events plus mirrored episodes, then hands them to the store, which pulls the
/// due date of any goal whose trigger matched. The ordinary `advanceDue` path
/// fires that goal on the next tick, so single-flight locking, run rows, session
/// linkage, and parked resumes all stay exactly as they were.
///
/// Downtime and debounce semantics:
/// - No catch-up stacking. Each trigger settles at most once per poll and its
///   debounce window suppresses repeats, so a burst of matching events never
///   queues a burst of firings.
/// - Skipped-while-down firings are not replayed. The lookback bounds how far
///   back a poll reads; events older than the window are ignored, and the goal
///   still fires on its regular cadence instead.
/// - Event kinds stay open. The bridge classifies episodes into the shared
///   vocabulary and forwards goal audit kinds verbatim, but it never switches on
///   the kind itself, so a new source only needs to publish events to extend it.
public struct GoalTriggerBridge: Sendable {
    /// Default bounded lookback for a single poll.
    public static let defaultLookback: TimeInterval = 15 * 60
    /// Upper bound on events read from each source per poll, so one noisy
    /// stream cannot fan the settle work out without bound.
    public static let maxEventsPerPoll = 200

    /// Maximum age of an event a poll may still consider.
    public let lookback: TimeInterval

    /// Creates a bridge.
    /// - Parameter lookback: Bounded lookback window in seconds.
    public init(lookback: TimeInterval = GoalTriggerBridge.defaultLookback) {
        self.lookback = lookback
    }

    /// Reads recent events and settles matching triggers, returning the fires.
    ///
    /// `since` is the caller's high-water mark; it is clamped to the lookback so
    /// a long gap or restart never replays an unbounded backlog. Failures in
    /// either read degrade to no events rather than failing the tick, matching
    /// the scheduler's best-effort posture for background work.
    /// - Parameters:
    ///   - store: Goal store owning triggers and due dates.
    ///   - episodeStore: Episodic store over the same database file.
    ///   - now: Evaluation instant.
    ///   - since: High-water mark of the previous poll.
    /// - Returns: Triggers that matched and pulled their goals forward.
    public func poll(
        store: GoalStore,
        episodeStore: EpisodeStore,
        now: Date,
        since: Date
    ) async -> [GoalTriggerFire] {
        let effectiveSince = max(since, now.addingTimeInterval(-max(0, lookback)))
        var events: [GoalObservedEvent] = []
        do {
            let goalEvents = try await store.observedEvents(since: effectiveSince, limit: Self.maxEventsPerPoll)
            events.append(contentsOf: goalEvents)
        } catch is CancellationError {
            return []
        } catch {
            RuneWeaverLog.stores.error("GoalEngine: failed to load observed events: \(error.localizedDescription)")
        }
        do {
            let episodes = try await episodeStore.recent(limit: Self.maxEventsPerPoll)
            events.append(contentsOf: episodes
                .filter { $0.timestamp > effectiveSince }
                .map(Self.observedEvent))
        } catch is CancellationError {
            return []
        } catch {
            RuneWeaverLog.stores.error("GoalEngine: failed to load recent episodes: \(error.localizedDescription)")
        }
        guard !events.isEmpty else { return [] }
        do {
            return try await store.fireMatchingTriggers(events: events, now: now)
        } catch is CancellationError {
            return []
        } catch {
            RuneWeaverLog.stores.error("GoalEngine: failed to fire matching triggers: \(error.localizedDescription)")
            return []
        }
    }

    /// Classifies one mirrored episode into the trigger event vocabulary.
    ///
    /// A tool outcome is an episode carrying a tool-call identifier; a mail
    /// arrival is an episode the mail reader annotates with the arrival kind.
    /// Everything else is a plain conversation turn. Classification lives here,
    /// not in the matcher, so a new annotation only widens this mapping.
    /// - Parameter episode: Mirrored episode to classify.
    /// - Returns: Observed event for the trigger matcher.
    public static func observedEvent(for episode: Episode) -> GoalObservedEvent {
        let kind = if episode.metadata["tool_call_id"] != nil {
            GoalTriggerEventKind.tool
        } else if episode.metadata["source"] == GoalTriggerEventKind.mailArrival
            || episode.metadata["mail_arrival"] == "true"
        {
            GoalTriggerEventKind.mailArrival
        } else {
            GoalTriggerEventKind.episode
        }
        return GoalObservedEvent(kind: kind, message: episode.content, occurredAt: episode.timestamp)
    }
}

// Rune Weaver Core — Long-horizon goal pursuit engine.
//
// Owns the lifecycle around durable goals: opt-in creation with an active-goal
// cap, single-call plan decomposition with a resilient fallback so a goal is
// never lost to flaky planning, per-run advancement prompts composed as user
// text for composer cache stability, and due-date bookkeeping after each run.
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
    private let llm: any LLMProvider
    /// Pursuit policy clamped at init so hand-built configs degrade to the
    /// nearest sane bound instead of refusing to run.
    private let config: GoalsConfig
    /// In-flight background decomposition tasks keyed by goal.
    ///
    /// Stored instead of fire-and-forget so creation hands back trackable work:
    /// callers needing determinism await `waitForPendingPlan`, and shutdown
    /// paths can cancel through `cancelPendingPlans` instead of leaking a
    /// detached task past the engine's lifetime.
    private var planTasks: [UUID: Task<Void, Never>] = [:]
    /// Optional ideas engine refreshed when a goal reaches achieved.
    ///
    /// The natural "what next" moment is the completion of a goal, so the
    /// engine is injected rather than discovered; when absent, achievement
    /// simply records its events as before and no suggestion call is spent.
    private let ideasEngine: IdeasEngine?

    /// Creates a goal engine over shared collaborators.
    /// - Parameters:
    ///   - store: Durable goal persistence.
    ///   - llm: Injected provider shared with chat turns.
    ///   - config: Pursuit policy.
    ///   - ideasEngine: Optional ideas engine refreshed on achievement.
    public init(store: GoalStore, llm: any LLMProvider, config: GoalsConfig, ideasEngine: IdeasEngine? = nil) {
        self.store = store
        self.llm = llm
        self.config = config.clamped()
        self.ideasEngine = ideasEngine
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

    /// Creates a goal with a placeholder step and plans in the background.
    ///
    /// The placeholder stays pending so the later decomposition swaps it out
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
            status: .active,
            stepIntervalMinutes: interval,
            nextDueAt: now.addingTimeInterval(TimeInterval(interval * 60)),
            originSessionID: originSessionID,
            createdAt: now,
            updatedAt: now
        )
        // Pending on purpose: the decomposer replaces only pending rows, so
        // this marker disappears on first plan without disturbing later edits.
        let placeholder = GoalStep(
            goalID: goal.id,
            ordinal: 0,
            title: "Planning in progress",
            status: .pending,
            notes: "Decomposition pending"
        )
        try await store.create(goal: goal, steps: [placeholder])
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
        // Tracked, not detached: the handle lets deterministic callers await the
        // plan and shutdown paths cancel it, while creation still returns the
        // snapshot without paying the planning timeout.
        let planTask = Task {
            await self.decompose(goal: captured)
            await self.finishPlanTask(for: captured.id)
        }
        planTasks[goal.id] = planTask
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

    /// Awaits the background decomposition for one goal, when one is in flight.
    ///
    /// Creation returns immediately while planning lands shortly after; tests and
    /// other deterministic callers await this instead of sleeping. A goal with
    /// no in-flight plan returns immediately, and cancellation of the tracked
    /// task surfaces here as an early return once the task observes it.
    /// - Parameter goalID: Goal whose plan to await.
    public func waitForPendingPlan(goalID: UUID) async {
        if let task = planTasks[goalID] {
            await task.value
        }
    }

    /// Cancels every in-flight background plan.
    ///
    /// Placeholders stay in place for an explicit `decompose` retry, so a
    /// cancelled plan never loses the goal — it only delays the plan.
    public func cancelPendingPlans() {
        for task in planTasks.values {
            task.cancel()
        }
        planTasks.removeAll()
    }

    /// Decomposes one goal into a bounded plan with a single model call.
    ///
    /// Parsing tolerates chatty wrappers: fences are stripped and the
    /// outermost array wins, so prefixed prose or a trailing sign-off still
    /// yields steps. Anything unusable falls back to one actionable step plus
    /// a note, keeping the goal alive through local-model flakiness. Store
    /// failures leave the placeholder in place for a later retry instead of
    /// throwing the goal away.
    /// - Parameter goal: Goal snapshot to plan for.
    public func decompose(goal: Goal) async {
        let maxSteps = config.maxStepsPerGoal
        let prompt = Self.decomposePrompt(for: goal, maxSteps: maxSteps)
        let rawText: String?
        do {
            rawText = try await collectPlanText(prompt: prompt)
        } catch is CancellationError {
            // Preserve the placeholder for an explicit retry, so a cancelled
            // plan only delays instead of losing the goal to the fallback.
            return
        } catch {
            // Non-cancellation collection failures still degrade to the
            // fallback below; a concurrent cancellation preserves the
            // placeholder instead.
            if Task.isCancelled {
                return
            }
            await storeFallback(for: goal)
            return
        }
        // A nil or unusable reply after cancellation preserves the placeholder;
        // only a genuine timeout or unusable output stores the fallback.
        if Task.isCancelled {
            return
        }
        guard let rawText, !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let titles = Self.extractPlanTitles(from: rawText, maxSteps: maxSteps),
              !titles.isEmpty
        else {
            if Task.isCancelled {
                return
            }
            await storeFallback(for: goal)
            return
        }
        let steps = titles.enumerated().map { index, title in
            GoalStep(goalID: goal.id, ordinal: index, title: title, status: .pending)
        }
        // replacePlan only swaps pending rows, so in-flight and finished work
        // survives a replan while the creation placeholder disappears.
        do {
            try await store.replacePlan(goalID: goal.id, steps: steps)
        } catch {
            RuneWeaverLog.scheduler.error("GoalEngine: failed to persist plan for goal \(goal.id): \(error.localizedDescription)")
        }
    }

    /// Decomposes one goal looked up by identifier.
    ///
    /// Convenience for callers holding only the identifier; unknown goals are
    /// a quiet no-op so scheduled retries never throw on a deleted goal.
    /// - Parameter goalID: Identifier of the goal to plan for.
    public func decompose(goalID: UUID) async {
        guard let goal = try? await store.goal(id: goalID) else { return }
        await decompose(goal: goal)
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

    /// Records the aftermath of one advancement run.
    ///
    /// Steps already moved through `goal.progress` during the turn, so this
    /// re-reads them: an empty actionable scan on an active goal means the
    /// plan is finished and flips to achieved with its completion event. The
    /// due date always bumps by the goal's own cadence so the next run keeps
    /// its rhythm. The run identifier lands as an audit event so scheduler
    /// runs stay correlatable to the advancement they caused. The identifier
    /// is opaque correlation: the service passes its run-log row while the
    /// headless loop passes its per-run session, because the CLI keeps no
    /// durable run log to link.
    /// - Parameters:
    ///   - goalID: Goal that just ran.
    ///   - runID: Opaque correlation for the audit event (run-log ID in the
    ///     service, per-run session ID headless).
    /// - Returns: Suggestions generated because this turn achieved the goal,
    ///   empty when the goal is still active or the ideas engine is unwired.
    @discardableResult
    public func postAdvance(goalID: UUID, runID: UUID) async throws -> [Idea] {
        guard let goal = try await store.goal(id: goalID) else {
            throw GoalEngineError.notFound(goalID)
        }
        let next = try await store.nextActionableStep(goalID: goalID)
        var generated: [Idea] = []
        if next == nil, goal.status == .active {
            // setStatus logs the completion event alongside the transition.
            try await store.setStatus(goalID: goalID, status: .achieved)
            // The natural "what next" moment: refresh proactive suggestions
            // now that a goal just finished. Best-effort only — generate()
            // self-guards on the ideas config and returns an empty batch on
            // failure, so a quiet model never fails the advancement that
            // triggered it. The batch is returned so the caller can surface it
            // on the proactive frame despite the store's title dedup.
            generated = await ideasEngine?.generate() ?? []
        }
        let bumped = Date().addingTimeInterval(TimeInterval(goal.stepIntervalMinutes * 60))
        try await store.markAdvanced(goalID: goalID, nextDueAt: bumped)
        try await store.appendEvent(goalID: goalID, kind: .note, message: "Advanced by run \(runID.uuidString).")
        return generated
    }

    /// Evaluates whether an active goal has completed all actionable steps,
    /// flipping it to achieved if no actionable steps remain.
    /// - Parameter goalID: Goal to check.
    /// - Returns: True if the goal was flipped to achieved, false otherwise.
    @discardableResult
    public func checkCompletion(goalID: UUID) async throws -> Bool {
        guard let goal = try await store.goal(id: goalID), goal.status == .active else {
            return false
        }
        let next = try await store.nextActionableStep(goalID: goalID)
        if next == nil {
            try await store.setStatus(goalID: goalID, status: .achieved)
            _ = await ideasEngine?.generate()
            return true
        }
        return false
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
    ///
    /// The status transition logs generically, so the reason travels as its
    /// own event rather than being folded into the transition message.
    /// - Parameters:
    ///   - goalID: Goal to park.
    ///   - reason: Owner-visible explanation of what is needed.
    public func needsInput(goalID: UUID, reason: String) async throws {
        try await store.setStatus(goalID: goalID, status: .needsInput)
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            try await store.appendEvent(goalID: goalID, kind: .needsInput, message: trimmed)
        }
    }

    /// Pauses pursuit of a goal.
    /// - Parameter goalID: Goal to pause.
    public func pause(goalID: UUID) async throws {
        try await store.setStatus(goalID: goalID, status: .paused)
    }

    /// Resumes a paused or parked goal back to active.
    /// - Parameter goalID: Goal to resume.
    public func resume(goalID: UUID) async throws {
        try await store.setStatus(goalID: goalID, status: .active)
    }

    /// Abandons a goal; the terminal note preserves why it was dropped.
    /// - Parameter goalID: Goal to abandon.
    public func abandon(goalID: UUID) async throws {
        try await store.setStatus(goalID: goalID, status: .abandoned)
    }

    /// Deletes a goal with its steps and events.
    /// - Parameter goalID: Goal to delete.
    public func delete(goalID: UUID) async throws {
        try await store.delete(goalID: goalID)
    }

    // MARK: - Planning internals

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
            "Each object must carry a \"title\" string. At most \(maxSteps) steps. No prose outside the array."
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
    /// - Returns: Titles, or nil when nothing parseable remains.
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
    /// Exactly one chat call runs; the timeout wins the race and cancels the
    /// collector so a hung backend cannot stall creation. Cancellation
    /// propagates instead of degrading to the fallback, so a cancelled plan
    /// keeps its placeholder for an explicit retry while timeouts still fall
    /// back.
    private func collectPlanText(prompt: String) async throws -> String? {
        let timeoutSeconds = max(1, config.planTimeoutSeconds)
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
            // A timeout win racing a cancellation must not store the fallback:
            // surface cancellation so the placeholder survives for a retry.
            try Task.checkCancellation()
            return first
        }
    }

    /// Runs the single planning chat call and folds its stream to text.
    ///
    /// No tools travel because planning is pure text in, JSON out; a mid-
    /// stream provider error degrades to nil so the caller falls back instead
    /// of planning from a truncated fragment. Cancellation rethrows so the
    /// caller preserves the placeholder instead of storing the fallback.
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
        // The stream may finish just as cancellation lands; prefer the
        // placeholder over a fallback built from a cancelled turn.
        try Task.checkCancellation()
        return text
    }

    /// Stores the resilient single-step fallback with its explanatory note.
    ///
    /// The step title names the goal so the fallback stays actionable in
    /// listings, and the note records that planning output was unusable rather
    /// than leaving future runs to guess why the plan is one step long.
    private func storeFallback(for goal: Goal) async {
        let step = GoalStep(
            goalID: goal.id,
            ordinal: 0,
            title: "Work toward \(goal.title)",
            status: .pending,
            notes: "Planning fallback"
        )
        // Best-effort fallback persistence: failures leave the placeholder for
        // a later retry, so results are logged on error.
        do {
            _ = try await store.replacePlan(goalID: goal.id, steps: [step])
            _ = try await store.appendEvent(
                goalID: goal.id,
                kind: .note,
                message: "Planning fell back to a single step after unusable model output."
            )
        } catch {
            RuneWeaverLog.scheduler.warning("GoalEngine: failed to persist fallback plan for goal \(goal.id): \(error.localizedDescription)")
        }
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
        if let goalEvents = try? await store.observedEvents(since: effectiveSince, limit: Self.maxEventsPerPoll) {
            events.append(contentsOf: goalEvents)
        }
        if let episodes = try? await episodeStore.recent(limit: Self.maxEventsPerPoll) {
            // `recent` returns newest-first across sessions, so the filter keeps
            // only events inside the window; the read bound already caps the
            // downstream settle work.
            events.append(contentsOf: episodes
                .filter { $0.timestamp > effectiveSince }
                .map(Self.observedEvent))
        }
        guard !events.isEmpty else { return [] }
        return await (try? store.fireMatchingTriggers(events: events, now: now)) ?? []
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

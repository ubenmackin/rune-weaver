// Rune Weaver Server — In-process background scheduler worker.
//
// Fires cron and poll jobs plus steady goal advancements inside the service
// process. Jobs drive on cron windows while goals drive on `next_due_at`;
// both share the per-process single-flight spirit so overlapping fires skip
// instead of stacking. Downtime carries no catch-up: a firing missed while
// down simply becomes due and advances once on the next tick, then re-dueues
// on its regular interval rather than replaying every missed slot.

import Foundation
import Logging
import RuneWeaverCore

// swiftformat:disable docComments

/// Internal decode envelope for `email.search` tool outputs.
private struct EmailSearchResponseEnvelope: Decodable {
    struct MessageItem: Decodable {
        let id: String
    }

    let messages: [MessageItem]
}

/// ServerSchedulerWorker keeps cron, poll, and goal firing behind one single-flight worker so overlapping ticks skip together.
///
/// In-process scheduler worker executing scheduled jobs inside `RuneWeaverServer`.
public actor ServerSchedulerWorker {
    private let scheduler: SchedulerStore
    private let runs: RunLogStore
    private let hub: WSHub
    private let runLock: SchedulerRunLock
    private let orchestrator: Orchestrator
    private let conversations: ConversationManager
    private let toolBus: ToolBus
    private let approvals: ApprovalQueue?
    private let notifier: (any SchedulerNotifier)?
    private let logger: (@Sendable (String) async -> Void)?
    private let pollChecker: (@Sendable (EmailPollRule) async -> [String])?
    private let indexCoordinator: IndexCoordinator?
    /// Durable goal registry backing due advancement, nil when goals are unwired.
    private let goalStore: GoalStore?
    /// Pursuit engine composing advancement prompts and bumping due dates.
    private let goalEngine: GoalEngine?
    /// Optional ideas engine refreshed on a nightly cadence so suggestions
    /// stay fresh even when no goal reaches achieved.
    private let ideasEngine: IdeasEngine?

    /// Cadence window between nightly idea refresh passes.
    public static let ideasRefreshInterval: TimeInterval = 24 * 60 * 60
    /// Episodic store the trigger bridge polls for mirrored events, nil when
    /// goals are unwired or no database path was available.
    private let triggerEpisodeStore: EpisodeStore?
    /// Bridge polling recent events into armed goal triggers.
    private let goalTriggerBridge: GoalTriggerBridge
    /// High-water mark for the trigger poll so a long gap is bounded, never replayed.
    private var lastTriggerCheck: Date
    /// High-water mark for the nightly ideas refresh.
    private var lastIdeasRefresh: Date
    /// Dedicated single-flight lock for goal fires so a slow goal turn never
    /// blocks job fires sharing the job lock, and vice versa.
    private let goalRunLock: SchedulerRunLock
    /// Interruption gate for background notifications and dashboard frames.
    ///
    /// Filters macOS notifications and `proactive_message` frames only; run
    /// history, run broadcasts, and the approvals inbox always record so the
    /// audit trail never loses a turn the gate suppresses.
    private let outcomeGate: OutcomeGate
    private let schedulerConfig: SchedulerConfig
    private let goalsConfig: GoalsConfig

    private let intervalSeconds: TimeInterval
    private var lastCheck: Date
    private var runningTask: Task<Void, Never>?
    private var seenPollIDs: [UUID: Set<String>] = [:]
    private var lastPollCheck: [UUID: Date] = [:]
    private var isStarted = false

    /// Creates a server scheduler worker.
    public init(
        scheduler: SchedulerStore,
        runs: RunLogStore,
        hub: WSHub,
        runLock: SchedulerRunLock,
        orchestrator: Orchestrator,
        conversations: ConversationManager,
        toolBus: ToolBus,
        approvals: ApprovalQueue? = nil,
        intervalSeconds: TimeInterval = 60,
        notifier: (any SchedulerNotifier)? = nil,
        logger: (@Sendable (String) async -> Void)? = nil,
        pollChecker: (@Sendable (EmailPollRule) async -> [String])? = nil,
        indexCoordinator: IndexCoordinator? = nil,
        goalStore: GoalStore? = nil,
        goalEngine: GoalEngine? = nil,
        ideasEngine: IdeasEngine? = nil,
        goalRunLock: SchedulerRunLock? = nil,
        triggerEpisodeStore: EpisodeStore? = nil,
        goalTriggerBridge: GoalTriggerBridge = GoalTriggerBridge(),
        outcomeGate: OutcomeGate? = nil,
        proactiveConfig: ProactiveConfig = ProactiveConfig(),
        judgeLLM: (any LLMProvider)? = nil,
        schedulerConfig: SchedulerConfig = .empty,
        goalsConfig: GoalsConfig = GoalsConfig()
    ) {
        self.scheduler = scheduler
        self.runs = runs
        self.hub = hub
        self.runLock = runLock
        self.orchestrator = orchestrator
        self.conversations = conversations
        self.toolBus = toolBus
        self.approvals = approvals
        self.intervalSeconds = max(1, intervalSeconds)
        self.lastCheck = Date().addingTimeInterval(-max(1, intervalSeconds))
        self.notifier = notifier
        self.logger = logger
        self.pollChecker = pollChecker
        self.indexCoordinator = indexCoordinator
        self.schedulerConfig = schedulerConfig
        self.goalsConfig = goalsConfig
        self.goalStore = goalStore
        self.goalEngine = goalEngine
        self.ideasEngine = ideasEngine
        self.goalRunLock = goalRunLock ?? SchedulerRunLock()
        // The trigger bridge shares the goals database file, so an unwired
        // episodic store falls back to one over the same path; a nil path
        // leaves the bridge inert rather than polling a phantom store.
        self.triggerEpisodeStore = triggerEpisodeStore ?? goalStore.map { EpisodeStore(dbPath: $0.dbPath) }
        self.goalTriggerBridge = goalTriggerBridge
        // High-water mark starts at construction so the first tick never
        // replays pre-boot history; the bounded lookback still guards a gap.
        self.lastTriggerCheck = Date()
        // Ideas refresh starts its cadence at construction so a restart never
        // immediately spends a review call; the interval high-water mark makes
        // the cadence independent of tick frequency.
        self.lastIdeasRefresh = Date()
        if let outcomeGate {
            self.outcomeGate = outcomeGate
        } else if let judgeLLM, proactiveConfig.mode == .guarded {
            self.outcomeGate = OutcomeGate(
                mode: proactiveConfig.mode,
                judgeTimeoutSeconds: proactiveConfig.judgeTimeoutSeconds,
                judge: Self.makeProactiveJudge(llm: judgeLLM)
            )
        } else {
            self.outcomeGate = OutcomeGate(
                mode: proactiveConfig.mode,
                judgeTimeoutSeconds: proactiveConfig.judgeTimeoutSeconds
            )
        }
    }

    // Explicit stop() ends the background loop; actor-isolated loop state
    // cannot be touched from non-isolated deinit, so callers pair start() with stop().

    /// Whether the background loop is actively running.
    public var running: Bool {
        isStarted
    }

    /// Starts the background scheduling loop.
    public func start() {
        guard !isStarted else { return }
        isStarted = true
        // Capture the fixed cadence while still isolated so the detached loop
        // never hops back to the actor just to read an immutable interval.
        let interval = intervalSeconds
        runningTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                await self.tick()
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    break
                }
            }
        }
    }

    /// Stops the background scheduling loop.
    public func stop() {
        guard isStarted else { return }
        isStarted = false
        runningTask?.cancel()
        runningTask = nil
    }

    /// Computes the earliest next fire date across all enabled cron jobs.
    /// - Parameter after: Reference date. Defaults to now.
    /// - Returns: Earliest matching job name and date, or nil if none scheduled.
    public func nextFireDate(after date: Date = Date()) async -> (jobName: String, date: Date)? {
        let jobs = await scheduler.list()
        var earliest: (jobName: String, date: Date)?
        for job in jobs where job.enabled && job.hasCronTrigger {
            guard let schedule = try? CronSchedule.parse(job.schedule),
                  let fire = schedule.nextFire(after: date)
            else { continue }
            if let current = earliest {
                if fire < current.date {
                    earliest = (job.name, fire)
                }
            } else {
                earliest = (job.name, fire)
            }
        }
        return earliest
    }

    /// Executes one check tick, firing all due cron and poll jobs.
    /// - Parameter now: Evaluation time. Defaults to now.
    /// - Returns: List of run execution results.
    @discardableResult
    public func tick(now: Date = Date()) async -> [SchedulerRunResult] {
        let windowStart = lastCheck
        lastCheck = now
        let jobs = await scheduler.list()
        var results: [SchedulerRunResult] = []

        // Deleted jobs would otherwise pin poll state forever in this
        // long-lived worker, so drop entries with no matching job each tick.
        let liveIDs = Set(jobs.map(\.id))
        seenPollIDs = seenPollIDs.filter { liveIDs.contains($0.key) }
        lastPollCheck = lastPollCheck.filter { liveIDs.contains($0.key) }

        for job in jobs where job.enabled {
            var isDue = false
            var reason = SchedulerFireReason.cron

            // 1. Evaluate Cron trigger
            if job.hasCronTrigger, let cron = try? CronSchedule.parse(job.schedule) {
                if cron.isDue(at: now, lastCheck: windowStart) {
                    isDue = true
                    reason = .cron
                }
            }

            // 2. Evaluate Email Poll trigger if not already due
            if !isDue, let rule = job.pollRule {
                let pollDue = await evaluatePollRule(jobID: job.id, rule: rule, now: now)
                if let arrivalCount = pollDue {
                    isDue = true
                    reason = .emailArrived(account: rule.trimmedAccount, count: arrivalCount)
                }
            }

            guard isDue else { continue }

            let outcome = await executeJob(job, reason: reason)
            results.append(outcome)
        }

        // The nightly-or-catch-up index trigger rides the same tick: the
        // coordinator selects `.nightly` at the nightly hour and `.catchUp`
        // for a later same-day launch, while a disabled or already-run
        // coordinator returns immediately, so this is a no-op for the default
        // configuration.
        if let goalStore, let goalEngine {
            // Disabled installs never spend advancement turns even when stale
            // rows linger from an earlier enabled period.
            if await goalEngine.isEnabled {
                let dueGoals: [Goal]
                do {
                    dueGoals = try await goalStore.advanceDue(now: now)
                } catch {
                    await logger?("Goals due scan failed: \(error.localizedDescription)")
                    dueGoals = []
                }
                for goal in dueGoals {
                    do {
                        let outcome = try await executeGoal(goal, store: goalStore, engine: goalEngine)
                        results.append(outcome)
                    } catch is CancellationError {
                        // Cancelled turns stay due with no error result; halt
                        // further fires in this tick and preserve cancellation
                        // (the outer task remains cancelled and exits on sleep).
                        break
                    } catch {
                        // Defensive: advancement records its own failures, so an
                        // escape here is unexpected; continue to the next due goal
                        // so one throw never starves the rest of the tick.
                        await logger?("Goal fire failed: \(error.localizedDescription)")
                        continue
                    }
                }
                // Event wake-ups settle after the due scan: a matched trigger
                // pulls its goal due for the NEXT tick, so the ordinary firing
                // path runs unchanged rather than a second in-tick path.
                if let triggerEpisodeStore {
                    let since = lastTriggerCheck
                    lastTriggerCheck = now
                    let fires = await goalTriggerBridge.poll(
                        store: goalStore,
                        episodeStore: triggerEpisodeStore,
                        now: now,
                        since: since
                    )
                    for fire in fires {
                        await logger?("Goal trigger '\(fire.eventKind)' armed goal \(fire.goalID) for the next tick.")
                    }
                }
            }
        }
        _ = await indexCoordinator?.fireNightly(now: now)
        // Ideas ride the same nightly tick so suggestions refresh even when no
        // goal reaches achieved; the cadence check keeps the refresh from
        // running on every tick.
        await refreshIdeasIfDue(now: now)

        return results
    }

    /// Refreshes proactive ideas at most once per cadence window.
    ///
    /// Rides the tick that already owns nightly maintenance so no separate
    /// timer is needed. The interval high-water mark makes the cadence
    /// independent of tick frequency, and `generate()` self-guards on the
    /// `[ideas]` enabled flag so a disabled install spends nothing.
    private func refreshIdeasIfDue(now: Date) async {
        guard let ideasEngine else { return }
        guard now.timeIntervalSince(lastIdeasRefresh) >= Self.ideasRefreshInterval else { return }
        lastIdeasRefresh = now
        let generated = await ideasEngine.generate()
        // Each fresh suggestion rides the existing proactive frame so the
        // dashboard raises the goals attention badge; generation itself is
        // best-effort and returns an empty batch on failure.
        for idea in generated {
            await broadcastIdeaProposed(idea)
        }
    }

    /// Broadcasts one freshly proposed idea on the existing proactive frame.
    ///
    /// Reuses `WSProactiveMessageFrame` rather than adding a transport: the
    /// kind names the idea family and the title plus a one-line body headline
    /// carry the card. The linked goal rides along so the dashboard can
    /// deep-link without a second lookup. The frame passes through the same
    /// interruption gate as every other proactive push, so `off`,
    /// `milestones`, and `guarded` installs stay silent (the guarded judge
    /// only weighs scheduler successes) while `all` surfaces it as before.
    /// - Parameter idea: Newly persisted suggestion to surface.
    private func broadcastIdeaProposed(_ idea: Idea) async {
        // The frame decoder rejects blank card text, and a directly-seeded row
        // can carry a whitespace-only body, so trim before choosing the
        // fallback; a blank title falls back too rather than emitting a frame
        // the dashboard would drop.
        let body = idea.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = idea.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = title.isEmpty ? "New suggestion" : title
        let outcomeText = body.isEmpty ? fallbackTitle : body
        // A suggestion is a volunteered nudge, not a goal milestone: routing it
        // through the gate keeps the same suppression contract as a routine
        // step completion instead of bypassing the `[proactive]` policy.
        let decision = await outcomeGate.decide(
            event: ProactiveEvent(kind: .ideaProposed, title: fallbackTitle, outcome: outcomeText)
        )
        guard decision.surface else { return }
        let frame = WSProactiveMessageFrame(
            kind: WSProactiveMessageFrame.ideaProposedKind,
            title: fallbackTitle,
            headline: decision.headline,
            goalID: idea.goalID
        )
        await hub.broadcastProactiveMessage(frame)
    }
}

// MARK: - Email Poll Evaluation

/// Email poll rule evaluation helpers, extracted from the actor body to keep
/// the type body length within lint bounds.
extension ServerSchedulerWorker {
    /// Evaluates a poll rule for a job, returning fresh unseen email count if due.
    private func evaluatePollRule(jobID: UUID, rule: EmailPollRule, now: Date) async -> Int? {
        if let last = lastPollCheck[jobID] {
            let elapsed = now.timeIntervalSince(last)
            if elapsed < Double(max(1, rule.pollIntervalSeconds)) {
                return nil
            }
        }
        lastPollCheck[jobID] = now

        let messageIDs: [String] = if let customChecker = pollChecker {
            await customChecker(rule)
        } else {
            await performToolBusPoll(rule: rule)
        }

        let currentSet = Set(messageIDs.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })

        // Initial observation establishes baseline without firing
        guard let seen = seenPollIDs[jobID] else {
            seenPollIDs[jobID] = currentSet
            return nil
        }

        let fresh = currentSet.subtracting(seen)
        seenPollIDs[jobID] = seen.union(currentSet)

        return fresh.isEmpty ? nil : fresh.count
    }

    /// Performs `email.search` via `ToolBus` to check current message IDs.
    private func performToolBusPoll(rule: EmailPollRule) async -> [String] {
        var args: [String: Any] = [
            "account": rule.trimmedAccount,
            "query": rule.query,
            "limit": rule.limit
        ]
        if let mailbox = rule.trimmedMailbox {
            args["mailbox"] = mailbox
        }
        guard let data = try? JSONSerialization.data(withJSONObject: args),
              let json = String(data: data, encoding: .utf8)
        else { return [] }

        let result = await toolBus.execute(
            toolCall: ToolInput(toolName: "email.search", argumentsJSON: json),
            context: ToolContext(conversationID: UUID())
        )
        guard !result.isError,
              let contentData = result.content.data(using: .utf8)
        else { return [] }

        let envelope: EmailSearchResponseEnvelope
        do {
            envelope = try JSONDecoder().decode(EmailSearchResponseEnvelope.self, from: contentData)
        } catch {
            RuneWeaverLog.scheduler.warning("ServerSchedulerWorker: failed to decode EmailSearchResponseEnvelope: \(error.localizedDescription)")
            return []
        }

        return envelope.messages.map(\.id)
    }
}

// MARK: - Job Execution

/// Job execution, skip, and failure helpers, extracted from the actor body to keep
/// the type body length within lint bounds.
extension ServerSchedulerWorker {
    /// Executes one scheduled job under single-flight locking, logging outcomes.
    private func executeJob(_ job: SchedulerJob, reason: SchedulerFireReason) async -> SchedulerRunResult {
        let startTime = Date()

        guard await runLock.tryAcquire(id: job.id, name: job.name) else {
            return await recordJobSkipped(job: job, startTime: startTime)
        }

        let sessionID = await makeSchedulerRunSession(job: job, startTime: startTime, conversations: conversations)

        let initialEntry = await runs.append(
            kind: "scheduler",
            status: "running",
            message: job.prompt,
            jobID: job.id,
            sessionID: sessionID,
            durationMs: 0
        )
        await hub.broadcastRun(initialEntry)

        // The single-flight lock is held for the whole turn and released with a
        // structured await before returning, so the next tick never observes a
        // stale held lock from a detached release racing the return.
        let result: SchedulerRunResult
        do {
            let maxIterations = job.maxToolIterations ?? schedulerConfig.defaultMaxToolIterations
            let policy: ToolLimitPolicy = job.onToolLimit == "park" ? .park : .forceSynthesis
            let response = try await orchestrator.process(
                input: UserInput(
                    text: job.prompt,
                    sessionID: sessionID,
                    source: "scheduler",
                    toolLimitPolicy: policy,
                    maxToolIterations: maxIterations
                ),
                onEvent: { [hub] event in
                    await broadcastWSEventFrame(event, sessionID: sessionID, hub: hub)
                }
            )
            await broadcastStreamDone(for: response, sessionID: sessionID, hub: hub)
            if response.isParked, let approvals {
                await broadcastParkedApprovals(for: response, approvals: approvals, hub: hub)
            }
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            // Parked scheduler turns remain as awaiting_approval like chat turns, resolving through
            // the same inbox resume path in their session. Budget exceeded turns finish with
            // forced diagnostic synthesis and budget_exceeded status.
            let runStatus = if response.isParked {
                "awaiting_approval"
            } else if response.isBudgetExceeded {
                "budget_exceeded"
            } else {
                "ok"
            }
            let entry = await runs.update(
                id: initialEntry.id,
                status: runStatus,
                response: response.text,
                toolActions: response.toolActions,
                totalTokens: response.totalTokens,
                durationMs: durationMs
            ) ?? initialEntry
            await hub.broadcastRun(entry)

            let short = ProactiveEvent.makePreview(response.text)
            await logger?("Scheduler fired '\(job.name)' (\(reason.displayName)): \(short)")
            // The gate filters interruptions only; the run row and its run
            // broadcast above always record so suppressed turns stay auditable.
            let eventKind: ProactiveEventKind = if response.isParked {
                .runParked
            } else if response.isBudgetExceeded {
                .runBudgetExceeded
            } else {
                .schedulerOk
            }
            let outcomeText = response.text.isEmpty ? job.prompt : response.text
            let decision = await outcomeGate.decide(event: ProactiveEvent(kind: eventKind, title: job.name, outcome: outcomeText))
            if decision.surface {
                if let notifier {
                    let title = response.isBudgetExceeded ? "Rune Weaver: \(job.name) (Budget Exceeded)" : "Rune Weaver: \(job.name)"
                    await notifier.notify(title: title, body: short.isEmpty ? job.prompt : short)
                }
                await broadcastProactive(kind: eventKind, title: job.name, headline: decision.headline, sessionID: sessionID)
            }

            result = SchedulerRunResult(
                jobName: job.name,
                sessionID: sessionID,
                fired: true,
                responseText: response.text,
                fireReason: reason,
                startedAt: startTime,
                finishedAt: Date()
            )
        } catch {
            result = await handleJobFailure(
                job: job,
                sessionID: sessionID,
                initialEntry: initialEntry,
                startTime: startTime,
                reason: reason,
                error: error
            )
        }

        await runLock.release(id: job.id, name: job.name)
        return result
    }

    /// Records an audit run entry for a scheduled job that skipped firing because it is already running.
    private func recordJobSkipped(job: SchedulerJob, startTime: Date) async -> SchedulerRunResult {
        let skipMsg = "Skipped '\(job.name)': already running"
        await logger?(skipMsg)
        // Skipped runs create no conversation, so the audit entry stays
        // untagged and the result reuses the job identifier as a stable
        // placeholder instead of inventing an orphan session for filtering.
        let entry = await runs.append(
            kind: "scheduler",
            status: "skipped",
            message: skipMsg,
            jobID: job.id,
            sessionID: nil,
            durationMs: 0
        )
        await hub.broadcastRun(entry)
        return SchedulerRunResult(
            jobName: job.name,
            sessionID: job.id,
            fired: false,
            skippedReason: "already running",
            fireReason: nil,
            startedAt: startTime,
            finishedAt: Date()
        )
    }

    private func handleJobFailure(
        job: SchedulerJob,
        sessionID: UUID,
        initialEntry: RunLogEntry,
        startTime: Date,
        reason: SchedulerFireReason,
        error: any Error
    ) async -> SchedulerRunResult {
        let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
        let detail = error.localizedDescription
        let entry = await runs.update(
            id: initialEntry.id,
            status: "error",
            response: detail,
            durationMs: durationMs
        ) ?? initialEntry
        await hub.broadcastRun(entry)
        await logger?("Scheduler failed '\(job.name)': \(detail)")
        // Errors break through under every surfacing mode except off; the
        // error row above always records so the gate never hides a failure
        // from history.
        let errorDecision = await outcomeGate.decide(event: ProactiveEvent(kind: .schedulerError, title: job.name, outcome: detail))
        if errorDecision.surface {
            let errorPreview = ProactiveEvent.makePreview(detail)
            if let notifier {
                await notifier.notify(title: "Rune Weaver: \(job.name)", body: errorPreview.isEmpty ? job.prompt : errorPreview)
            }
            await broadcastProactive(kind: .schedulerError, title: job.name, headline: errorDecision.headline, sessionID: sessionID)
        }

        return SchedulerRunResult(
            jobName: job.name,
            sessionID: sessionID,
            fired: true,
            errorMessage: detail,
            fireReason: reason,
            startedAt: startTime,
            finishedAt: Date()
        )
    }
}

// MARK: - Goal Advancement Execution

/// Dedicated goal advancement execution methods.
extension ServerSchedulerWorker {
    /// Records an audit run entry for a goal that skipped firing because it is already running.
    private func recordGoalSkipped(goal: Goal, startTime: Date) async -> SchedulerRunResult {
        let skipMsg = "Skipped goal '\(goal.title)': already running"
        await logger?(skipMsg)
        // Skipped goals create no conversation, so the audit entry stays
        // untagged like the job skip path instead of inventing an orphan
        // session, while still carrying the goal link for filtering.
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
        // persisted: the audit entry above stays untagged (nil session)
        // plus the goal link, mirroring the job skip path's untagged row.
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
    private func recordGoalSuccess(
        goal: Goal,
        sessionID: UUID,
        runID: UUID,
        outcome: GoalAdvancementTurn,
        startTime: Date,
        eventKind: ProactiveEventKind = .goalStepDone
    ) async -> SchedulerRunResult {
        let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
        // Parked goal turns remain as awaiting_approval like scheduler
        // turns, resolving through the same inbox resume path in their
        // session. Budget exceeded turns finish with forced diagnostic
        // synthesis and budget_exceeded status.
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
                await notifier.notify(title: title, body: short.isEmpty ? goal.title : short)
            }
            await broadcastProactive(kind: eventKind, title: goal.title, headline: decision.headline, sessionID: sessionID, goalID: goal.id)
        }
        // Suggestions born from the achievement ride their own proactive frames.
        // They are surfaced here rather than only on the nightly pass because
        // `generate()` returns just the newly inserted rows and the store dedups
        // their titles, so the next nightly batch would never announce them. Each
        // frame is gated independently so a suppressed goal outcome never hides a
        // fresh suggestion.
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
    private func recordGoalFailure(
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
                await notifier.notify(title: "Rune Weaver: \(goal.title)", body: errorPreview.isEmpty ? goal.title : errorPreview)
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
    /// Mirrors `executeJob` exactly: a fresh per-run session linked to the
    /// goal, a `goal` run row cycling running to ok, awaiting_approval, or
    /// error, then a due-date bump so the next firing keeps its rhythm.
    /// Parked goal turns stay in their session for the inbox resume path.
    /// Cancelled turns stay due with a `cancelled` row and rethrow instead of
    /// recording an error, so cooperative cancellation always propagates.
    private func executeGoal(_ goal: Goal, store: GoalStore, engine: GoalEngine) async throws -> SchedulerRunResult {
        let startTime = Date()

        guard await goalRunLock.tryAcquire(id: goal.id, name: goal.title) else {
            return await recordGoalSkipped(goal: goal, startTime: startTime)
        }

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
        let result: SchedulerRunResult
        do {
            // One shared advancement path keeps the service and CLI loops from
            // drifting: bounded audit reads feed the prompt, a parked turn
            // skips its due bump until the inbox resume completes, and the
            // run-log row supplies the audit correlation.
            let turnOrchestrator = orchestrator
            let turnSessionID = sessionID
            let turnGoalID = goal.id
            let bumpLogger = logger
            let bumpTitle = goal.title
            let turnHub = hub
            let outcome = try await GoalAdvancementRunner.advance(
                goal: goal,
                store: store,
                engine: engine,
                runID: initialEntry.id,
                turn: { prompt in
                    let response = try await turnOrchestrator.process(
                        input: UserInput(
                            text: prompt,
                            sessionID: turnSessionID,
                            source: "goal",
                            goalID: turnGoalID,
                            toolLimitPolicy: .forceSynthesis,
                            maxToolIterations: goalsConfig.maxToolIterations
                        ),
                        onEvent: { event in
                            await broadcastWSEventFrame(event, sessionID: turnSessionID, hub: turnHub)
                        }
                    )
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
            // Cancelled turns did not advance, so they stay due: mark the run
            // cancelled (never error), release the lock, then propagate.
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
    ///
    /// Thrown after recording the honest skipped audit row so the route can
    /// answer 409 like the manual job run without inventing a second lock.
    public struct GoalBusyError: Error, Sendable {
        /// Creates a busy signal.
        public init() {}
    }

    /// Advances one goal immediately, bypassing its due cadence.
    ///
    /// Shares the single-flight lock, per-run session, run-row lifecycle, and
    /// proactive gating with the background tick so manual and automatic fires
    /// cannot stack or drift. The returned identifiers let the route answer
    /// with both the durable run row and its session without a second lookup.
    /// - Parameter goalID: Goal to advance.
    /// - Returns: Run-log identifier plus the per-run session identifier.
    public func advanceGoalNow(goalID: UUID) async throws -> (runID: UUID, sessionID: UUID) {
        guard let store = goalStore, let engine = goalEngine else {
            throw GoalEngineError.disabled
        }
        guard await engine.isEnabled else {
            throw GoalEngineError.disabled
        }
        guard let goal = try await store.goal(id: goalID) else {
            throw GoalStoreError.notFound("No goal \(goalID)")
        }
        let startTime = Date()
        guard await goalRunLock.tryAcquire(id: goal.id, name: goal.title) else {
            _ = await recordGoalSkipped(goal: goal, startTime: startTime)
            throw GoalBusyError()
        }
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
        do {
            let turnOrchestrator = orchestrator
            let turnSessionID = sessionID
            let turnGoalID = goal.id
            let bumpLogger = logger
            let bumpTitle = goal.title
            let turnHub = hub
            let outcome = try await GoalAdvancementRunner.advance(
                goal: goal,
                store: store,
                engine: engine,
                runID: initialEntry.id,
                turn: { prompt in
                    let response = try await turnOrchestrator.process(
                        input: UserInput(
                            text: prompt,
                            sessionID: turnSessionID,
                            source: "goal",
                            goalID: turnGoalID,
                            toolLimitPolicy: .forceSynthesis,
                            maxToolIterations: goalsConfig.maxToolIterations
                        ),
                        onEvent: { event in
                            await broadcastWSEventFrame(event, sessionID: turnSessionID, hub: turnHub)
                        }
                    )
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

    /// Pushes the current goal row to live sockets after an advancement turn.
    ///
    /// Best-effort refresh so dashboards patch one row instead of refetching;
    /// failures only log because the run row and its broadcast already landed.
    private func broadcastGoalSnapshot(goalID: UUID, store: GoalStore) async {
        do {
            if let goal = try await store.goal(id: goalID) {
                let steps = await (try? store.steps(goalID: goalID)) ?? []
                await hub.broadcastGoal(GoalDTO(goal: goal, steps: steps))
            }
        } catch {
            await logger?("Goal snapshot broadcast failed: \(error.localizedDescription)")
        }
    }
}

/// Creates an isolated per-run goal session for one advancement fire.
/// Mirrors `makeSchedulerRunSession`: a fresh identifier keeps background
/// runs isolated from chat and from each other, while the goal link keeps
/// runs and sessions joinable without a second lookup.
func makeGoalRunSession(goal: Goal, conversations: ConversationManager) async -> UUID {
    let sessionID = UUID()
    await conversations.ensureSession(id: sessionID, title: goal.title, source: "goal", overwrite: true, goalID: goal.id)
    return sessionID
}

// MARK: - Proactive surfacing helpers

/// Judge failures mapped to throws so the gate fails open to surfacing.
private enum ProactiveJudgeError: Error, Sendable {
    /// The model returned no text to parse.
    case emptyResponse
    /// The model reply was not the demanded JSON shape.
    case unparseable(String)
    /// The stream reported a provider failure mid-judge.
    case providerError(String)
}

extension ServerSchedulerWorker {
    /// Broadcasts one surfaced interruption frame for dashboard badges.
    ///
    /// Called only when the gate surfaces so suppressed modes stay silent;
    /// the run row broadcast already happened unconditionally, so this frame
    /// carries the interruption alone and never duplicates audit history. The
    /// shared `WSProactiveMessageFrame` shape carries kind, title, and
    /// headline plus session and goal links so the dashboard can raise a Web
    /// Notification or badge and deep-link without a second lookup, even with
    /// no macOS notifier.
    private func broadcastProactive(kind: ProactiveEventKind, title: String, headline: String, sessionID: UUID? = nil, goalID: UUID? = nil) async {
        // The hub owns the single encoding for this wire shape, so build the
        // frame and reuse it instead of duplicating the encode here.
        let frame = WSProactiveMessageFrame(kind: kind.rawValue, title: title, headline: headline, sessionID: sessionID, goalID: goalID)
        await hub.broadcastProactiveMessage(frame)
    }

    /// Classifies a finished goal turn into its proactive kind.
    ///
    /// Parked turns map to the parked kind without touching the store; fresh
    /// terminal states (achieved, needs input) win next, then any blocked
    /// step, with routine step completion as the fallback. Best-effort: store
    /// failures degrade to the routine kind rather than failing the turn, and
    /// the gate still surfaces errors and parked turns from their own paths.
    private func resolveGoalEventKind(goal: Goal, store: GoalStore, outcome: GoalAdvancementTurn) async -> ProactiveEventKind {
        if outcome.isParked {
            return .runParked
        }
        if outcome.isBudgetExceeded {
            return .runBudgetExceeded
        }
        do {
            if let fresh = try await store.goal(id: goal.id) {
                switch fresh.status {
                case .achieved:
                    return .goalAchieved
                case .needsInput:
                    return .goalNeedsInput
                case .active, .paused, .abandoned:
                    break
                }
            }
            let steps = try await store.steps(goalID: goal.id)
            if steps.contains(where: { $0.status == .blocked }) {
                return .goalBlocked
            }
        } catch {
            // Classification never fails a turn; routine is the quiet fallback.
            RuneWeaverLog.scheduler.debug("ServerSchedulerWorker: failed to evaluate steps for goal \(goal.id): \(error.localizedDescription)")
        }
        return .goalStepDone
    }

    /// Builds the single-exchange judge prompt for a routine scheduler success.
    ///
    /// Sets a high interruption bar (worth the owner's attention right now?)
    /// and demands JSON only so the parser can fail closed to a throw, which
    /// the gate then fails open to surfacing. The title is clamped to the
    /// headline budget so an unbounded goal title cannot bloat the judge
    /// exchange; the preview already carries the shared 160-character bound.
    /// - Parameter event: Routine outcome awaiting a verdict.
    /// - Returns: User prompt for the judge model.
    public static func proactiveJudgePrompt(for event: ProactiveEvent) -> String {
        let title = ProactiveEvent.clampHeadline(event.title)
        return """
        You are the interruption judge for Rune Weaver background runs. \
        Decide whether this routine scheduler outcome is worth interrupting the owner right now. \
        The bar is high: surface only when the owner must see it immediately; routine completions stay quiet. \
        Respond with JSON only, no other text: {"surface": bool, "headline": string}. \
        The headline must be at most 90 characters and summarize why this matters. \
        Event kind: \(event.kind.rawValue). Title: \(title). Outcome preview: \(event.preview)
        """
    }

    /// Parses one judge reply into a verdict, throwing on any drift.
    ///
    /// Strips fenced code wrappers before decoding so a helpful model that
    /// wraps its JSON still parses; anything else (empty, non-JSON, missing
    /// keys) throws so the gate fails open instead of silently swallowing the
    /// outcome.
    /// - Parameter text: Raw judge reply text.
    /// - Returns: Decoded verdict.
    public static func parseProactiveJudgeResponse(_ text: String) throws -> SurfacingVerdict {
        struct Payload: Decodable {
            let surface: Bool
            let headline: String
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProactiveJudgeError.emptyResponse
        }
        let jsonText = stripJudgeFences(trimmed)
        guard let start = jsonText.firstIndex(of: "{"),
              let end = jsonText.lastIndex(of: "}"),
              start <= end
        else {
            throw ProactiveJudgeError.unparseable(trimmed)
        }
        let slice = String(jsonText[start ... end])
        guard let data = slice.data(using: .utf8) else {
            throw ProactiveJudgeError.unparseable(trimmed)
        }
        do {
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            return SurfacingVerdict(surface: payload.surface, headline: payload.headline)
        } catch {
            throw ProactiveJudgeError.unparseable(trimmed)
        }
    }

    /// Strips a single fenced code wrapper from a judge reply.
    private static func stripJudgeFences(_ text: String) -> String {
        var working = text
        if working.hasPrefix("```") {
            if let firstNewline = working.firstIndex(of: "\n") {
                working = String(working[working.index(after: firstNewline)...])
            } else {
                working = String(working.dropFirst(3))
            }
            if let fenceRange = working.range(of: "```", options: .backwards) {
                working = String(working[..<fenceRange.lowerBound])
            }
        }
        return working.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Builds a judge closure around one LLM provider.
    ///
    /// Runs one short text-in/JSON-out exchange with no tools; provider errors
    /// and unparseable replies throw so the gate fails open to surfacing. The
    /// gate itself enforces the judge timeout, so this closure never sleeps.
    /// - Parameter llm: Provider serving the single judge exchange.
    /// - Returns: Judge closure for a guarded gate.
    public static func makeProactiveJudge(llm: any LLMProvider) -> ProactiveJudge {
        let captured = llm
        return { @Sendable event in
            let prompt = proactiveJudgePrompt(for: event)
            let messages = [Message(role: .user, content: prompt)]
            var text = ""
            let stream = captured.chat(messages: messages, tools: [])
            for await chunk in stream {
                if let failure = chunk.errorMessage, !failure.isEmpty {
                    throw ProactiveJudgeError.providerError(failure)
                }
                text += chunk.delta
                if chunk.isFinished {
                    break
                }
            }
            return try parseProactiveJudgeResponse(text)
        }
    }
}

/// Adapter delivering index run lifecycle events onto the server's durable run
/// log and live WebSocket hub.
///
/// A run's start event is appended as a `running` row and broadcast as
/// `run_started`; its completion event updates that same row and broadcasts
/// `run_completed`. Both events carry the coordinator's per-run session
/// identifier, so index runs are filterable in run history exactly like
/// scheduler turns.
public struct ServerIndexRunReporter: IndexRunReporting {
    /// Kind tag applied to index run log rows.
    public static let kind = "index"

    /// Durable run audit trail.
    private let runs: RunLogStore
    /// Live sockets receiving run broadcasts.
    private let hub: WSHub

    /// Creates a reporter.
    /// - Parameters:
    ///   - runs: Run audit trail to persist into.
    ///   - hub: Socket hub to broadcast through.
    public init(runs: RunLogStore, hub: WSHub) {
        self.runs = runs
        self.hub = hub
    }

    /// Persists and broadcasts a run start.
    /// - Parameter event: The start event.
    public func runStarted(_ event: IndexRunEvent) async {
        let entry = RunLogEntry(
            id: event.id,
            sessionID: event.sessionID,
            kind: Self.kind,
            status: event.status.rawValue,
            message: event.message,
            timestamp: event.timestamp,
            response: event.response,
            durationMs: event.durationMs
        )
        await runs.append(entry)
        await hub.broadcastRun(entry)
    }

    /// Persists and broadcasts a run completion.
    ///
    /// The completion event already carries the end instant, so the update
    /// stamps it onto the start row: the finished time then reads as seconds
    /// ago at completion instead of the run's duration ago. The start row keeps
    /// nothing of the start except message order. Falls back to appending the
    /// completed entry when the start row is not present, so a completion never
    /// disappears because its start was pruned.
    /// - Parameter event: The completion event.
    public func runCompleted(_ event: IndexRunEvent) async {
        if let updated = await runs.update(
            id: event.id,
            status: event.status.rawValue,
            response: event.response,
            durationMs: event.durationMs,
            timestamp: event.timestamp
        ) {
            await hub.broadcastRun(updated)
            return
        }
        let entry = RunLogEntry(
            id: event.id,
            sessionID: event.sessionID,
            kind: Self.kind,
            status: event.status.rawValue,
            message: event.message,
            timestamp: event.timestamp,
            response: event.response,
            durationMs: event.durationMs
        )
        await runs.append(entry)
        await hub.broadcastRun(entry)
    }
}

// swiftformat:enable docComments

// Rune Weaver Server — In-process background scheduler worker.

import Foundation
import Logging
import RuneWeaverCore

// swiftformat:disable docComments

// Whether a finished scheduler turn should advance the cursor.
extension OrchestratorResponse {
    var shouldAdvanceSchedulerCursor: Bool {
        !isParked && !isBudgetExceeded
    }
}

/// ServerSchedulerWorker keeps cron, poll, and goal firing behind one single-flight worker so overlapping ticks skip together.
///
/// In-process scheduler worker executing scheduled jobs inside `RuneWeaverServer`.
public actor ServerSchedulerWorker {
    let scheduler: SchedulerStore
    let runs: RunLogStore
    let hub: WSHub
    let runLock: SchedulerRunLock
    let orchestrator: Orchestrator
    let conversations: ConversationManager
    let toolBus: ToolBus
    let approvals: ApprovalQueue?
    let notifier: any SchedulerNotifier?
    let logger: (@Sendable (String) async -> Void)?
    let pollChecker: (@Sendable (EmailPollRule) async -> [String])?
    private let indexCoordinator: IndexCoordinator?
    /// Durable goal registry backing due advancement, nil when goals are unwired.
    let goalStore: GoalStore?
    /// Pursuit engine composing advancement prompts and bumping due dates.
    let goalEngine: GoalEngine?
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
    let goalRunLock: SchedulerRunLock
    let activeTurns: ActiveTurnTracker?
    /// Interruption gate for background notifications and dashboard frames.
    let outcomeGate: OutcomeGate
    private let schedulerConfig: SchedulerConfig
    let goalsConfig: GoalsConfig
    /// Live per-type preferences shared with the combined notifier.
    let notificationsBox: NotificationsConfigBox

    private let intervalSeconds: TimeInterval
    private var lastCheck: Date
    private var runningTask: Task<Void, Never>?
    var seenPollIDs: [UUID: Set<String>] = [:]
    var lastPollCheck: [UUID: Date] = [:]
    var lastSkippedGoalDueAt: [UUID: Date] = [:]
    private var isStarted = false

    /// Creates a server scheduler worker.
    public init(scheduler: SchedulerStore, runs: RunLogStore, hub: WSHub, runLock: SchedulerRunLock, orchestrator: Orchestrator,
                conversations: ConversationManager, toolBus: ToolBus, approvals: ApprovalQueue? = nil, intervalSeconds: TimeInterval = 60,
                notifier: any SchedulerNotifier? = nil, logger: (@Sendable (String) async -> Void)? = nil,
                pollChecker: (@Sendable (EmailPollRule) async -> [String])? = nil, indexCoordinator: IndexCoordinator? = nil,
                goalStore: GoalStore? = nil, goalEngine: GoalEngine? = nil, ideasEngine: IdeasEngine? = nil,
                goalRunLock: SchedulerRunLock? = nil, activeTurns: ActiveTurnTracker? = nil, triggerEpisodeStore: EpisodeStore? = nil,
                goalTriggerBridge: GoalTriggerBridge = GoalTriggerBridge(), outcomeGate: OutcomeGate? = nil,
                proactiveConfig: ProactiveConfig = ProactiveConfig(), judgeLLM: any LLMProvider? = nil,
                schedulerConfig: SchedulerConfig = .empty, goalsConfig: GoalsConfig = GoalsConfig(),
                notificationsBox: NotificationsConfigBox? = nil)
    {
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
        self.activeTurns = activeTurns
        if let notificationsBox {
            self.notificationsBox = notificationsBox
        } else if let composite = notifier as? CompositeSchedulerNotifier {
            self.notificationsBox = composite.notificationsBox
        } else {
            self.notificationsBox = NotificationsConfigBox()
        }
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

    /// Current per-type preferences snapshot.
    public var currentNotifications: NotificationsConfig {
        notificationsBox.current
    }

    /// Replaces the live per-type preferences without a restart.
    public func updateNotifications(_ config: NotificationsConfig) {
        notificationsBox.update(config)
    }

    /// Whether this kind interrupts under the live preferences.
    func shouldSurfaceNotifications(_ kind: NotificationKind) -> Bool {
        NotificationsFilter.shouldSurface(kind, config: notificationsBox.current)
    }

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
            // 1. Evaluate Event Watcher trigger (Email, Messages, Calendar)
            if job.isEventWatcher, let watcherResults = await evaluateEventWatcherJob(job: job, now: now) {
                results.append(contentsOf: watcherResults)
                continue
            }

            // 2. Evaluate Cron trigger
            if job.hasCronTrigger, let cron = try? CronSchedule.parse(job.schedule), cron.isDue(at: now, lastCheck: windowStart) {
                let outcome = await executeJob(job, reason: .cron)
                results.append(outcome)
            }
        }

        // A settled job fire rewrote scheduler rows, so open dashboards refetch
        // the job list; evaluations that fired nothing changed no rows.
        if results.contains(where: \.fired) {
            await hub.broadcastSchedulerJobsChanged()
        }

        // Scheduled sends ride the same tick but take no orchestrator turn:
        // each due send claims exactly once and replays the approved bytes, so
        // a slow fire never stacks a second replay on the next tick.
        let didSettleSends: Bool
        do {
            didSettleSends = try await fireDueScheduledSends(now: now)
        } catch is CancellationError {
            // Cancellation stops further scheduled sends this tick and is preserved for the outer
            // loop; the claimed row stays `sending` until its replay settles or a later boot
            // reconciles it, so nothing double-sends.
            await logger?("Scheduled send fire cancelled.")
            didSettleSends = true
        } catch {
            await logger?("Scheduled send fire failed: \(error.localizedDescription)")
            didSettleSends = false
        }
        // A settled send rewrote send rows, so open dashboards refetch the send
        // list; a tick that settled nothing leaves panels untouched.
        if didSettleSends {
            await hub.broadcastScheduledSendsChanged()
        }

        // The nightly-or-catch-up index trigger rides the same tick: the coordinator selects
        // `.nightly` at the nightly hour and `.catchUp` for a later same-day launch, while a
        // disabled or already-run coordinator returns immediately, so this is a no-op for the default configuration.
        if let goalStore, let goalEngine,
           // Disabled installs never spend advancement turns even when stale
           // rows linger from an earlier enabled period.
           await goalEngine.isEnabled
        {
            let dueGoals: [Goal]
            do {
                dueGoals = try await goalStore.advanceDue(now: now)
            } catch {
                await logger?("Goals due scan failed: \(error.localizedDescription)")
                dueGoals = []
            }
            // Deleted or settled goals would otherwise pin skip-suppression
            // entries here forever, so prune before firing; goals still
            // active and due skip the store read and keep suppression.
            await pruneStaleGoalSkips(store: goalStore, liveActiveDueIDs: Set(dueGoals.map(\.id)))
            for goal in dueGoals {
                if let dueAt = goal.nextDueAt,
                   lastSkippedGoalDueAt[goal.id] == dueAt,
                   await isGoalBusy(id: goal.id)
                {
                    continue
                }
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
        _ = await indexCoordinator?.fireNightly(now: now)
        // Ideas ride the same nightly tick so suggestions refresh even when no
        // goal reaches achieved; the cadence check keeps the refresh from
        // running on every tick.
        await refreshIdeasIfDue(now: now)

        return results
    }

    /// Refreshes proactive ideas at most once per cadence window.
    private func refreshIdeasIfDue(now: Date) async {
        guard let ideasEngine, now.timeIntervalSince(lastIdeasRefresh) >= Self.ideasRefreshInterval else { return }
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
    func broadcastIdeaProposed(_ idea: Idea) async {
        // The frame decoder rejects blank card text, and a directly-seeded row can carry a
        // whitespace-only body, so trim before choosing the fallback; a blank title falls back too
        // rather than emitting a frame the dashboard would drop.
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
        guard decision.surface, shouldSurfaceNotifications(.ideaProposed) else { return }
        let frame = WSProactiveMessageFrame(
            kind: WSProactiveMessageFrame.ideaProposedKind,
            title: fallbackTitle,
            headline: decision.headline,
            goalID: idea.goalID
        )
        await hub.broadcastProactiveMessage(frame)
        await notifyKindAware(
            notifier,
            kind: .ideaProposed,
            config: notificationsBox.current,
            title: "Rune Weaver: \(fallbackTitle)",
            body: decision.headline.isEmpty ? outcomeText : decision.headline,
            identifier: "idea-\(idea.id)"
        )
    }
}

// MARK: - Email Poll Evaluation

// MARK: - Job Execution

/// Job execution, skip, and failure helpers, extracted from the actor body to keep
/// the type body length within lint bounds.
extension ServerSchedulerWorker {
    /// Executes one scheduled job under single-flight locking, logging outcomes.
    func executeJob(
        _ job: SchedulerJob,
        reason: SchedulerFireReason,
        promptOverride: String? = nil,
        ruleName: String? = nil
    ) async -> SchedulerRunResult {
        let startTime = Date()

        guard await runLock.tryAcquire(id: job.id, name: job.name) else {
            return await recordJobSkipped(job: job, startTime: startTime)
        }

        let sessionID = await makeSchedulerRunSession(job: job, startTime: startTime, conversations: conversations)

        let initialMessage = if let ruleName {
            "[\(ruleName)] \(promptOverride ?? job.prompt)"
        } else {
            promptOverride ?? job.prompt
        }
        let initialEntry = await runs.append(
            kind: "scheduler",
            status: "running",
            message: initialMessage,
            jobID: job.id,
            sessionID: sessionID,
            durationMs: 0
        )
        await hub.broadcastRun(initialEntry)

        // The single-flight lock is held for the whole turn and released with a
        // structured await before returning, so the next tick never observes a
        // stale held lock from a detached release racing the return.
        let taskBox = TurnTaskBox()
        let registration = await activeTurns?.register(sessionID: sessionID, onCancel: { taskBox.cancel() })
        let result: SchedulerRunResult
        do {
            // Persisted rows may predate REST validation, so bound the budget at
            // use: only exact "park" parks, every other stored value synthesizes
            // as a budget-exceeded turn rather than branching on open-ended input.
            let requestedIterations = job.maxToolIterations ?? schedulerConfig.defaultMaxToolIterations
            let maxIterations = min(max(requestedIterations, 1), 100)
            let policy: ToolLimitPolicy = job.onToolLimit == "park" ? .park : .forceSynthesis
            let effectivePrompt = if let promptOverride {
                promptOverride + "\n\n" + Self.schedulerCursorRuleLine
            } else {
                await freshSchedulerRunPrompt(for: job)
            }
            let runTask: Task<OrchestratorResponse, any Error> = Task {
                try await orchestrator.process(
                    input: UserInput(
                        text: effectivePrompt,
                        sessionID: sessionID,
                        source: "scheduler",
                        toolLimitPolicy: policy,
                        maxToolIterations: maxIterations
                    ),
                    onEvent: { [hub] event in
                        await broadcastWSEventFrame(event, sessionID: sessionID, hub: hub)
                    }
                )
            }
            taskBox.set(runTask)
            let response = try await runTask.value
            if let registration {
                await activeTurns?.unregister(sessionID: sessionID, token: registration.token)
            }
            await broadcastStreamDone(for: response, sessionID: sessionID, hub: hub)
            if response.isParked, let approvals {
                await broadcastParkedApprovals(for: response, approvals: approvals, hub: hub)
            }
            result = await recordJobSuccess(
                job: job,
                sessionID: sessionID,
                runID: initialEntry.id,
                response: response,
                startTime: startTime,
                reason: reason
            )
        } catch {
            if let registration {
                await activeTurns?.unregister(sessionID: sessionID, token: registration.token)
            }
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

    private func recordJobSuccess(
        job: SchedulerJob,
        sessionID: UUID,
        runID: UUID,
        response: OrchestratorResponse,
        startTime: Date,
        reason: SchedulerFireReason
    ) async -> SchedulerRunResult {
        let finishedAt = Date()
        let durationMs = Int(finishedAt.timeIntervalSince(startTime) * 1000)
        let runStatus = if response.isParked {
            "awaiting_approval"
        } else if response.isBudgetExceeded {
            "budget_exceeded"
        } else {
            "ok"
        }
        if let entry = await runs.update(
            id: runID,
            status: runStatus,
            response: response.text,
            toolActions: response.toolActions,
            totalTokens: response.totalTokens,
            durationMs: durationMs
        ) {
            await hub.broadcastRun(entry)
        }
        if response.shouldAdvanceSchedulerCursor {
            await scheduler.recordSuccessfulRun(id: job.id, endedAt: finishedAt)
        }

        let short = ProactiveEvent.makePreview(response.text)
        await logger?("Scheduler fired '\(job.name)' (\(reason.displayName)): \(short)")
        let eventKind: ProactiveEventKind = if response.isParked {
            .runParked
        } else if response.isBudgetExceeded {
            .runBudgetExceeded
        } else {
            .schedulerOk
        }
        let outcomeText = response.text.isEmpty ? job.prompt : response.text
        let decision = await outcomeGate.decide(event: ProactiveEvent(kind: eventKind, title: job.name, outcome: outcomeText))
        if decision.surface, shouldSurfaceNotifications(.schedulerRun) {
            let title = response.isBudgetExceeded ? "Rune Weaver: \(job.name) (Budget Exceeded)" : "Rune Weaver: \(job.name)"
            await notifyKindAware(
                notifier,
                kind: .schedulerRun,
                config: notificationsBox.current,
                title: title,
                body: short.isEmpty ? job.prompt : short,
                identifier: NotifyID.normalize(nil)
            )
            await broadcastProactive(kind: eventKind, title: job.name, headline: decision.headline, sessionID: sessionID)
        } else if eventKind == .schedulerOk {
            await conversations.setSessionArchived(id: sessionID, isArchived: true)
        }

        return SchedulerRunResult(
            jobName: job.name,
            sessionID: sessionID,
            fired: true,
            responseText: response.text,
            fireReason: reason,
            startedAt: startTime,
            finishedAt: finishedAt
        )
    }

    /// Records an audit run entry for a scheduled job that skipped firing because it is already running.
    func recordJobSkipped(job: SchedulerJob, startTime: Date) async -> SchedulerRunResult {
        let skipMsg = "Skipped '\(job.name)': already running"
        await logger?(skipMsg)
        // Skipped runs create no conversation, so the audit entry stays untagged
        // with a nil session while the ephemeral result reuses the job
        // identifier as a stable placeholder for filtering.
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
        // Cancelled and failed turns keep the prior cursor by returning without recording.
        if error is CancellationError {
            let entry = await runs.update(
                id: initialEntry.id,
                status: "cancelled",
                durationMs: durationMs
            ) ?? initialEntry
            await hub.broadcastRun(entry)
            await logger?("Scheduler job '\(job.name)' cancelled.")
            return SchedulerRunResult(
                jobName: job.name,
                sessionID: sessionID,
                fired: true,
                errorMessage: "cancelled",
                fireReason: reason,
                startedAt: startTime,
                finishedAt: Date()
            )
        }
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
        if errorDecision.surface, shouldSurfaceNotifications(.schedulerRun) {
            let errorPreview = ProactiveEvent.makePreview(detail)
            await notifyKindAware(
                notifier,
                kind: .schedulerRun,
                config: notificationsBox.current,
                title: "Rune Weaver: \(job.name)",
                body: errorPreview.isEmpty ? job.prompt : errorPreview,
                identifier: NotifyID.normalize(nil)
            )
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

// MARK: - Scheduler run cursor prompt

extension ServerSchedulerWorker {
    /// Framework-owned rule carried on every run prompt, cursor or not.
    static let schedulerCursorRuleLine =
        "Scan windows come from this cursor; never store run bookkeeping with memories.store."

    /// Default-lookback sentence carried when no cursor exists yet.
    static let schedulerCursorlessLookbackLine =
        "No prior successful run; scan the default lookback window."

    /// Verbatim configured window for cursorless first runs, so the agent
    /// never has to guess the default lookback duration.
    static func schedulerCursorlessWindowDetail(for job: SchedulerJob) -> String {
        var parts: [String] = []
        let schedule = job.schedule.trimmingCharacters(in: .whitespacesAndNewlines)
        if !schedule.isEmpty {
            parts.append("schedule '\(schedule)'")
        }
        if let rule = job.pollRule {
            parts.append("poll every \(rule.pollIntervalSeconds)s (account '\(rule.trimmedAccount)')")
        }
        guard !parts.isEmpty else {
            return "Configured window: default lookback."
        }
        return "Configured window: \(parts.joined(separator: "; "))."
    }

    /// Verbatim timestamp shape injected alongside the cursor.
    static func schedulerCursorTimestampString(from date: Date) -> String {
        SchedulerRunBookkeeping.schedulerCursorTimestampString(from: date)
    }

    /// Builds the effective run prompt, always carrying the cursor rule.
    static func schedulerRunPrompt(for job: SchedulerJob) -> String {
        guard let cursor = job.lastSuccessfulRunEndedAt else {
            return job.prompt + "\n\n\(schedulerCursorlessLookbackLine)\n\(schedulerCursorlessWindowDetail(for: job))\n\(schedulerCursorRuleLine)"
        }
        let stamp = schedulerCursorTimestampString(from: cursor)
        return job.prompt + "\n\nLast successful run ended: \(stamp)\n\(schedulerCursorRuleLine)"
    }

    /// Builds the effective prompt with the freshest stored cursor.
    func freshSchedulerRunPrompt(for job: SchedulerJob) async -> String {
        guard let fresh = await scheduler.job(id: job.id) else {
            return Self.schedulerRunPrompt(for: job)
        }
        return Self.schedulerRunPrompt(for: fresh)
    }
}

// MARK: - Goal Advancement Execution

// Goal advancement execution lives in ServerSchedulerWorkerGoalExecution so
// this worker stays within the file-length budget; the tick and manual
// advance reach it through the same actor extension.

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
    func broadcastProactive(kind: ProactiveEventKind, title: String, headline: String, sessionID: UUID? = nil, goalID: UUID? = nil) async {
        // The hub owns the single encoding for this wire shape, so build the
        // frame and reuse it instead of duplicating the encode here.
        let frame = WSProactiveMessageFrame(kind: kind.rawValue, title: title, headline: headline, sessionID: sessionID, goalID: goalID)
        await hub.broadcastProactiveMessage(frame)
    }

    /// Classifies a finished goal turn into its proactive kind.
    func resolveGoalEventKind(goal: Goal, store: GoalStore, outcome: GoalAdvancementTurn) async -> ProactiveEventKind {
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
                case .active, .paused, .abandoned, .unplanned:
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
    static func proactiveJudgePrompt(for event: ProactiveEvent) -> String {
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
    static func parseProactiveJudgeResponse(_ text: String) throws -> SurfacingVerdict {
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

    /// Builds a judge closure around one LLM provider. Runs one short text-in/JSON-out exchange
    /// with no tools; provider errors and unparseable replies throw so the gate fails open to
    /// surfacing.
    static func makeProactiveJudge(llm: any LLMProvider) -> ProactiveJudge {
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

// swiftformat:enable docComments

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
    private let notifier: (any SchedulerNotifier)?
    private let logger: (@Sendable (String) async -> Void)?
    private let pollChecker: (@Sendable (EmailPollRule) async -> [String])?
    private let indexCoordinator: IndexCoordinator?
    /// Durable goal registry backing due advancement, nil when goals are unwired.
    private let goalStore: GoalStore?
    /// Pursuit engine composing advancement prompts and bumping due dates.
    private let goalEngine: GoalEngine?
    /// Dedicated single-flight lock for goal fires so a slow goal turn never
    /// blocks job fires sharing the job lock, and vice versa.
    private let goalRunLock: SchedulerRunLock

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
        intervalSeconds: TimeInterval = 60,
        notifier: (any SchedulerNotifier)? = nil,
        logger: (@Sendable (String) async -> Void)? = nil,
        pollChecker: (@Sendable (EmailPollRule) async -> [String])? = nil,
        indexCoordinator: IndexCoordinator? = nil,
        goalStore: GoalStore? = nil,
        goalEngine: GoalEngine? = nil,
        goalRunLock: SchedulerRunLock? = nil
    ) {
        self.scheduler = scheduler
        self.runs = runs
        self.hub = hub
        self.runLock = runLock
        self.orchestrator = orchestrator
        self.conversations = conversations
        self.toolBus = toolBus
        self.intervalSeconds = max(1, intervalSeconds)
        self.lastCheck = Date().addingTimeInterval(-max(1, intervalSeconds))
        self.notifier = notifier
        self.logger = logger
        self.pollChecker = pollChecker
        self.indexCoordinator = indexCoordinator
        self.goalStore = goalStore
        self.goalEngine = goalEngine
        self.goalRunLock = goalRunLock ?? SchedulerRunLock()
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
            }
        }
        _ = await indexCoordinator?.fireNightly(now: now)

        return results
    }

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
              let contentData = result.content.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(EmailSearchResponseEnvelope.self, from: contentData)
        else { return [] }

        return envelope.messages.map(\.id)
    }

    /// Executes one scheduled job under single-flight locking, logging outcomes.
    private func executeJob(_ job: SchedulerJob, reason: SchedulerFireReason) async -> SchedulerRunResult {
        let startTime = Date()

        guard await runLock.tryAcquire(id: job.id, name: job.name) else {
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
            let response = try await orchestrator.process(input: UserInput(
                text: job.prompt,
                sessionID: sessionID,
                source: "scheduler"
            ))
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            // Parked scheduler turns remain as awaiting_approval like chat turns, resolving through
            // the same inbox resume path in their session. The per-turn parked flag keeps a stale
            // prior park in this session from mis-marking a fresh normal turn.
            let parkedStatus = if response.isParked {
                "awaiting_approval"
            } else {
                "ok"
            }
            let entry = await runs.update(
                id: initialEntry.id,
                status: parkedStatus,
                response: response.text,
                toolActions: response.toolActions,
                totalTokens: response.totalTokens,
                durationMs: durationMs
            ) ?? initialEntry
            await hub.broadcastRun(entry)

            let short = schedulerRunPreview(response.text)
            await logger?("Scheduler fired '\(job.name)' (\(reason.displayName)): \(short)")
            await notifier?.notify(title: "Rune Weaver: \(job.name)", body: short.isEmpty ? job.prompt : short)

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

            result = SchedulerRunResult(
                jobName: job.name,
                sessionID: sessionID,
                fired: true,
                errorMessage: detail,
                fireReason: reason,
                startedAt: startTime,
                finishedAt: Date()
            )
        }

        await runLock.release(id: job.id, name: job.name)
        return result
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
        startTime: Date
    ) async -> SchedulerRunResult {
        let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
        // Parked goal turns remain as awaiting_approval like scheduler
        // turns, resolving through the same inbox resume path in their
        // session. The per-turn parked flag keeps a stale prior park in
        // this session from mis-marking a fresh normal turn.
        let parkedStatus = outcome.isParked ? "awaiting_approval" : "ok"
        let entry = await runs.update(
            id: runID,
            status: parkedStatus,
            response: outcome.text,
            toolActions: outcome.toolActions,
            totalTokens: outcome.totalTokens,
            durationMs: durationMs
        )
        if let entry {
            await hub.broadcastRun(entry)
        }
        let short = schedulerRunPreview(outcome.text)
        if outcome.isParked {
            await logger?("Goal '\(goal.title)' parked awaiting approval.")
        } else {
            await logger?("Goal fired '\(goal.title)': \(short)")
        }
        await notifier?.notify(title: "Rune Weaver: \(goal.title)", body: short.isEmpty ? goal.title : short)
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
            let outcome = try await GoalAdvancementRunner.advance(
                goal: goal,
                store: store,
                engine: engine,
                runID: initialEntry.id,
                turn: { prompt in
                    let response = try await turnOrchestrator.process(input: UserInput(
                        text: prompt,
                        sessionID: turnSessionID,
                        source: "goal",
                        goalID: turnGoalID
                    ))
                    return GoalAdvancementTurn(
                        text: response.text,
                        isParked: response.isParked,
                        toolActions: response.toolActions,
                        totalTokens: response.totalTokens
                    )
                },
                onPostAdvanceFailure: { error in
                    await bumpLogger?("Goal '\(bumpTitle)' post-advance failed: \(error.localizedDescription)")
                }
            )
            result = await recordGoalSuccess(
                goal: goal,
                sessionID: sessionID,
                runID: initialEntry.id,
                outcome: outcome,
                startTime: startTime
            )
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
        }

        await goalRunLock.release(id: goal.id, name: goal.title)
        return result
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

/// Truncates a run response for log and notification previews.
///
/// Shared by job and goal fires so both surfaces quote the same bounded
/// prefix instead of each reimplementing the trim logic.
/// - Parameter text: Full response text.
/// - Returns: Trimmed prefix capped at 160 characters.
func schedulerRunPreview(_ text: String) -> String {
    let preview = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return preview.count > 160 ? String(preview.prefix(160)) + "…" : preview
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
    /// Falls back to appending the completed entry when the start row is not
    /// present, so a completion never disappears because its start was pruned.
    /// - Parameter event: The completion event.
    public func runCompleted(_ event: IndexRunEvent) async {
        if let updated = await runs.update(
            id: event.id,
            status: event.status.rawValue,
            response: event.response,
            durationMs: event.durationMs
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

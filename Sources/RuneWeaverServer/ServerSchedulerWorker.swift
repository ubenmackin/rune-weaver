// Rune Weaver Server — In-process background scheduler worker.
//
// Automatically evaluates cron schedules and email poll triggers on a
// recurring cadence, executing due jobs headless through Orchestrator with
// single-flight locking, run audit logging, WebSocket broadcast, and native
// notifications.

import Foundation
import Logging
import RuneWeaverCore

/// Internal decode envelope for `email.search` tool outputs.
private struct EmailSearchResponseEnvelope: Decodable {
    struct MessageItem: Decodable {
        let id: String
    }

    let messages: [MessageItem]
}

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

    private let intervalSeconds: TimeInterval
    private var lastCheck: Date
    private var runningTask: Task<Void, Never>?
    private var seenPollIDs: [UUID: Set<String>] = [:]
    private var lastPollCheck: [UUID: Date] = [:]
    private var isStarted = false

    /// Creates a server scheduler worker.
    /// - Parameters:
    ///   - scheduler: Scheduler jobs store.
    ///   - runs: Run execution log store.
    ///   - hub: WebSocket broadcast hub.
    ///   - runLock: Shared single-flight lock.
    ///   - orchestrator: Orchestrator for turn execution.
    ///   - conversations: Conversation history owner.
    ///   - toolBus: Tool bus for poll checks.
    ///   - intervalSeconds: Seconds between check ticks. Defaults to 60.
    ///   - notifier: Notifier for fired jobs. Defaults to nil.
    ///   - logger: Log output sink. Defaults to nil.
    ///   - pollChecker: Custom poll observer override. Defaults to nil.
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
        pollChecker: (@Sendable (EmailPollRule) async -> [String])? = nil
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
            // Parked scheduler turns remain as awaiting_approval like chat turns,
            // resolving through the same inbox resume path in their session.
            // The per-turn parked flag keeps a stale prior park in this
            // session from mis-marking a fresh normal turn.
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

            let preview = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let short = preview.count > 160 ? String(preview.prefix(160)) + "…" : preview
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

// Rune Weaver Core — Scheduler expressions, poll triggers, and engine.

import Foundation
#if canImport(SQLite3)
    import SQLite3
#endif

/// A poll-based email-arrival rule for scheduled jobs.
public struct EmailPollRule: Sendable, Codable, Equatable {
    /// Default seconds between polls when no interval is supplied.
    public static let defaultPollIntervalSeconds = 300
    /// Minimum seconds between polls. Shared bound for every poll-interval validation and clamp site.
    public static let minPollIntervalSeconds = 60
    /// Maximum seconds between polls. Shared bound for every poll-interval validation and clamp site.
    public static let maxPollIntervalSeconds = 86400
    /// Default maximum hits fetched per poll when no limit is supplied.
    public static let defaultLimit = 10
    /// Minimum hits fetched per poll. Shared bound for every poll-limit clamp site.
    public static let minLimit = 1
    /// Maximum hits fetched per poll. Shared bound for every poll-limit clamp site.
    public static let maxLimit = 50
    /// Account nickname matching an `[email.accounts]` entry.
    public var account: String
    /// Free-text query for `email.search` (blank means most-recent).
    public var query: String
    /// Mailbox to search (nil means every selectable mailbox).
    public var mailbox: String?
    /// Seconds between polls (60...86400).
    public var pollIntervalSeconds: Int
    /// Maximum hits fetched per poll (clamped `minLimit...maxLimit`).
    public var limit: Int

    /// Creates an email poll rule.
    public init(
        account: String,
        query: String = "",
        mailbox: String? = nil,
        pollIntervalSeconds: Int = EmailPollRule.defaultPollIntervalSeconds,
        limit: Int = EmailPollRule.defaultLimit
    ) {
        self.account = account
        self.query = query
        self.mailbox = mailbox
        self.pollIntervalSeconds = pollIntervalSeconds
        self.limit = Self.clampedLimit(limit)
    }

    /// Clamps a poll limit to the shared `minLimit...maxLimit` bounds.
    public static func clampedLimit(_ value: Int) -> Int {
        min(max(value, minLimit), maxLimit)
    }

    /// Clamps a poll interval to the shared `minPollIntervalSeconds...maxPollIntervalSeconds` bounds.
    public static func clampedPollIntervalSeconds(_ value: Int) -> Int {
        min(max(value, minPollIntervalSeconds), maxPollIntervalSeconds)
    }

    /// Trimmed account nickname.
    public var trimmedAccount: String {
        account.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Trimmed mailbox, or nil when omitted or blank.
    public var trimmedMailbox: String? {
        guard let mailbox else { return nil }
        let trimmed = mailbox.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Builds the poll rule for stored job fields, when an account is set.
    public static func ruleForStoredFields(
        pollAccount: String?,
        pollQuery: String?,
        pollMailbox: String?,
        pollIntervalSeconds: Int?,
        pollLimit: Int?
    ) -> EmailPollRule? {
        let trimmedAccount = pollAccount?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedAccount.isEmpty else { return nil }
        return EmailPollRule(
            account: trimmedAccount,
            query: pollQuery ?? "",
            mailbox: pollMailbox,
            pollIntervalSeconds: pollIntervalSeconds ?? EmailPollRule.defaultPollIntervalSeconds,
            limit: pollLimit ?? EmailPollRule.defaultLimit
        )
    }

    /// Maps a stored schedule to its config form, folding blank to nil.
    public static func configSchedule(from storedSchedule: String) -> String? {
        let trimmed = storedSchedule.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Maps a config schedule to its stored form, folding nil/blank to `""`.
    public static func storedSchedule(from configSchedule: String?) -> String {
        configSchedule?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

/// Failures raised while validating scheduler job tables.
public enum SchedulerConfigError: Error, Sendable, Equatable {
    /// A job name is blank.
    case emptyName
    /// A job name is duplicated.
    case duplicateName(job: String)
    /// A job prompt is blank.
    case emptyPrompt(job: String)
    /// A job has neither a cron schedule nor an event/poll trigger.
    case missingTrigger(job: String)
    /// A cron expression does not parse.
    case invalidCron(job: String, expression: String, detail: String)
    /// A poll rule is malformed.
    case invalidPoll(job: String, detail: String)
    /// An event rule is malformed.
    case invalidRule(job: String, rule: String, detail: String)
}

extension SchedulerConfigError {
    /// Owning job name, if the failure is scoped to one job.
    /// - Returns: Job name, or nil for job-agnostic failures.
    public var jobName: String? {
        switch self {
        case .emptyName:
            nil
        case let .duplicateName(job):
            job
        case let .emptyPrompt(job):
            job
        case let .missingTrigger(job):
            job
        case let .invalidCron(job, _, _):
            job
        case let .invalidPoll(job, _):
            job
        case let .invalidRule(job, _, _):
            job
        }
    }

    /// Single-sourced human-readable detail shared by every
    /// `SchedulerConfigError` mapping site so message drift is impossible.
    /// - Returns: Detail message for the failure.
    public var displayDetail: String {
        switch self {
        case .emptyName:
            "name must not be empty"
        case let .duplicateName(job):
            "job name '\(job)' already exists"
        case .emptyPrompt:
            "prompt must not be empty"
        case .missingTrigger:
            "job must have a cron schedule or poll trigger"
        case let .invalidCron(_, expression, detail):
            "schedule is not a valid cron expression: \(expression): \(detail)"
        case let .invalidPoll(_, detail):
            detail
        case let .invalidRule(job, rule, detail):
            "job '\(job)' rule '\(rule)' is invalid: \(detail)"
        }
    }

    /// Single-sourced field suffix shared by every mapping site so field
    /// drift is impossible. Nil means the failure is job-scoped.
    /// - Returns: Dotted field suffix, or nil for job-level failures.
    public var fieldSuffix: String? {
        switch self {
        case .emptyName:
            "name"
        case .duplicateName:
            "name"
        case .emptyPrompt:
            "prompt"
        case .missingTrigger:
            nil
        case .invalidCron:
            "schedule"
        case let .invalidPoll(_, detail):
            if detail.contains("poll_interval_seconds") {
                "poll_interval_seconds"
            } else if detail.contains("poll_limit") {
                "poll_limit"
            } else if detail.contains("calendar_lead_time_minutes") {
                "calendar_lead_time_minutes"
            } else if detail.contains("poll account") {
                "poll_account"
            } else {
                nil
            }
        case .invalidRule:
            "rules"
        }
    }
}

/// One `[[scheduler.jobs]]` entry: a named prompt plus its triggers.
public struct SchedulerJobConfig: Sendable, Codable, Equatable {
    /// Minimum calendar lead time in minutes. Shared bound for every lead-time validation and clamp site.
    public static let minCalendarLeadTimeMinutes = 1
    /// Maximum calendar lead time in minutes. Shared bound for every lead-time validation and clamp site.
    public static let maxCalendarLeadTimeMinutes = 1440
    /// Default calendar lead time when the stored job carries none.
    public static let defaultCalendarLeadTimeMinutes = 15
    /// Additive watcher columns for `scheduler_jobs`. Single owner of the
    /// watcher migration text so direct-core reads and server persistence
    /// cannot drift; both sites delegate through `applyWatcherColumnMigrations`.
    public static let watcherColumnMigrationStatements: [String] = [
        "ALTER TABLE scheduler_jobs ADD COLUMN watcher_source TEXT;",
        "ALTER TABLE scheduler_jobs ADD COLUMN rules TEXT;",
        "ALTER TABLE scheduler_jobs ADD COLUMN calendar_lead_time_minutes INTEGER;",
        "ALTER TABLE scheduler_jobs ADD COLUMN calendar_names TEXT;"
    ]

    /// Human-readable job name (e.g. `"morning digest"`).
    public var name: String
    /// Prompt executed when the job fires.
    public var prompt: String
    /// Whether the job fires. Disabled jobs are kept but never run.
    public var enabled: Bool
    /// Cron-like schedule expression, if the job has a time trigger.
    public var schedule: String?
    /// Email-arrival poll rule, if the job has a mail trigger.
    public var poll: EmailPollRule?
    /// Maximum tool iterations before limit policy triggers, or nil to inherit section default.
    public var maxToolIterations: Int?
    /// Action when tool limit is reached: "fail" (synthesize & budget_exceeded) or "park". Defaults to "fail".
    public var onToolLimit: String?
    /// Event watcher source (email, messages, or calendar), if the job has an event trigger.
    public var watcherSource: EventWatcherSource?
    /// Ordered event rules executed on incoming events.
    public var rules: [EventRule]?
    /// Lead time in minutes for calendar upcoming event trigger (1...1440). Defaults to 15.
    public var calendarLeadTimeMinutes: Int?
    /// Calendar names to watch for calendar upcoming event trigger.
    public var calendarNames: [String]?

    private enum CodingKeys: String, CodingKey {
        case name
        case prompt
        case enabled
        case schedule
        case poll
        case maxToolIterations = "max_tool_iterations"
        case onToolLimit = "on_tool_limit"
        case watcherSource = "watcher_source"
        case rules
        case calendarLeadTimeMinutes = "calendar_lead_time_minutes"
        case calendarNames = "calendar_names"
    }

    /// Creates a job config.
    public init(
        name: String,
        prompt: String,
        enabled: Bool = true,
        schedule: String? = nil,
        poll: EmailPollRule? = nil,
        maxToolIterations: Int? = nil,
        onToolLimit: String? = nil,
        watcherSource: EventWatcherSource? = nil,
        rules: [EventRule]? = nil,
        calendarLeadTimeMinutes: Int? = nil,
        calendarNames: [String]? = nil
    ) {
        self.name = name
        self.prompt = prompt
        self.enabled = enabled
        self.schedule = schedule
        self.poll = poll
        self.maxToolIterations = maxToolIterations
        self.onToolLimit = onToolLimit
        self.watcherSource = watcherSource
        self.rules = rules
        self.calendarLeadTimeMinutes = calendarLeadTimeMinutes
        self.calendarNames = calendarNames
    }

    /// Clamps a calendar lead time to the shared `minCalendarLeadTimeMinutes...maxCalendarLeadTimeMinutes` bounds.
    public static func clampedCalendarLeadTimeMinutes(_ value: Int) -> Int {
        min(max(value, minCalendarLeadTimeMinutes), maxCalendarLeadTimeMinutes)
    }

    /// Applies the additive watcher migrations through a caller-supplied exec.
    ///
    /// Each statement is best-effort idempotent (`ADD COLUMN` fails when the
    /// column already exists), so callers ignore per-statement failures and
    /// keep the shared text as the single source of truth.
    public static func applyWatcherColumnMigrations(_ exec: (String) -> Void) {
        for statement in watcherColumnMigrationStatements {
            exec(statement)
        }
    }

    /// Whether the job has a cron trigger.
    public var hasCronTrigger: Bool {
        guard let schedule else { return false }
        return !schedule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether the job has a poll trigger.
    public var hasPollTrigger: Bool {
        poll != nil
    }

    /// Whether the job has an event watcher trigger.
    public var hasWatcherTrigger: Bool {
        watcherSource != nil
    }

    /// Parses the cron trigger, when present.
    /// - Returns: Parsed schedule, or nil for poll-only jobs.
    /// - Throws: ``SchedulerConfigError/invalidCron(job:expression:detail:)`` when malformed.
    public func cronSchedule() throws -> CronSchedule? {
        guard let schedule else { return nil }
        let trimmed = schedule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            return try CronSchedule.parse(trimmed)
        } catch let error as CronScheduleError {
            throw SchedulerConfigError.invalidCron(job: name, expression: schedule, detail: String(describing: error))
        }
    }

    /// Validates the job entry.
    /// - Throws: ``SchedulerConfigError`` when the entry is malformed.
    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SchedulerConfigError.emptyName
        }
        let hasRules = !(rules ?? []).isEmpty
        if !hasRules {
            guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SchedulerConfigError.emptyPrompt(job: name)
            }
        }
        let hasCron = hasCronTrigger
        let hasPoll = hasPollTrigger
        let hasWatcher = hasWatcherTrigger
        guard hasCron || hasPoll || hasWatcher else {
            throw SchedulerConfigError.missingTrigger(job: name)
        }
        if hasCron {
            _ = try cronSchedule()
        }
        if let poll {
            guard !poll.trimmedAccount.isEmpty else {
                throw SchedulerConfigError.invalidPoll(job: name, detail: "poll account must not be empty")
            }
            // Fail-closed polling cadence: faster than once a minute would
            // turn every mailbox into a hot loop, while slower than a day
            // starves arrival detection, so both edges reject.
            let minInterval = EmailPollRule.minPollIntervalSeconds
            let maxInterval = EmailPollRule.maxPollIntervalSeconds
            guard (minInterval ... maxInterval).contains(poll.pollIntervalSeconds) else {
                throw SchedulerConfigError.invalidPoll(
                    job: name,
                    detail: "poll_interval_seconds must be between \(minInterval) and \(maxInterval) (got \(poll.pollIntervalSeconds))"
                )
            }
            guard (EmailPollRule.minLimit ... EmailPollRule.maxLimit).contains(poll.limit) else {
                throw SchedulerConfigError.invalidPoll(
                    job: name,
                    detail: "poll_limit must be between \(EmailPollRule.minLimit) and \(EmailPollRule.maxLimit)"
                )
            }
        }
        // A collapsed or far-future calendar window either always fires or
        // sweeps months of meetings, so the lead time rejects outside 1...1440.
        if let leadTime = calendarLeadTimeMinutes {
            let minLeadTime = Self.minCalendarLeadTimeMinutes
            let maxLeadTime = Self.maxCalendarLeadTimeMinutes
            guard (minLeadTime ... maxLeadTime).contains(leadTime) else {
                throw SchedulerConfigError.invalidPoll(
                    job: name,
                    detail: "calendar_lead_time_minutes must be between \(minLeadTime) and \(maxLeadTime) (got \(leadTime))"
                )
            }
        }
        if let rules {
            for rule in rules {
                guard !rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw SchedulerConfigError.invalidRule(job: name, rule: rule.name, detail: "rule name must not be empty")
                }
                switch rule.action {
                case let .agentPrompt(promptText):
                    guard !promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw SchedulerConfigError.invalidRule(job: name, rule: rule.name, detail: "prompt must not be empty")
                    }
                case let .directTool(toolName, _):
                    let trimmedTool = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedTool.isEmpty else {
                        throw SchedulerConfigError.invalidRule(job: name, rule: rule.name, detail: "tool_name must not be empty")
                    }
                    // The zero-token path bypasses inference, so only the
                    // narrowly-scoped mailbox and calendar mutations stay
                    // eligible; anything else must run as a scoped agent turn.
                    guard EventRuleAction.isAllowedDirectTool(trimmedTool) else {
                        let allowedTools = EventRuleAction.allowedDirectToolNames.sorted().joined(separator: ", ")
                        throw SchedulerConfigError.invalidRule(
                            job: name,
                            rule: rule.name,
                            detail: "tool_name '\(trimmedTool)' is not allowed (must be one of \(allowedTools))"
                        )
                    }
                }
            }
        }
    }
}

/// The `[scheduler]` section: every `[[scheduler.jobs]]` entry.
public struct SchedulerConfig: Sendable, Codable, Equatable {
    /// Configured jobs in file order.
    public var jobs: [SchedulerJobConfig]
    /// Default tool iterations for scheduled jobs before triggering limit policy (1-100). Defaults to 25.
    public var defaultMaxToolIterations: Int

    /// Creates a scheduler config.
    /// - Parameters:
    ///   - jobs: Configured jobs. Defaults to empty.
    ///   - defaultMaxToolIterations: Default tool iterations (1-100). Defaults to 25.
    public init(jobs: [SchedulerJobConfig] = [], defaultMaxToolIterations: Int = 25) {
        self.jobs = jobs
        self.defaultMaxToolIterations = defaultMaxToolIterations
    }

    private enum CodingKeys: String, CodingKey {
        case jobs
        case defaultMaxToolIterations = "maxToolIterations"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.jobs = try container.decodeIfPresent([SchedulerJobConfig].self, forKey: .jobs) ?? []
        self.defaultMaxToolIterations = try container.decodeIfPresent(Int.self, forKey: .defaultMaxToolIterations) ?? 25
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jobs, forKey: .jobs)
        try container.encode(defaultMaxToolIterations, forKey: .defaultMaxToolIterations)
    }

    /// Empty config with no jobs.
    public static var empty: SchedulerConfig {
        SchedulerConfig()
    }

    /// Enabled jobs only, in file order.
    public var enabledJobs: [SchedulerJobConfig] {
        jobs.filter(\.enabled)
    }

    /// Looks up a job by name.
    /// - Parameter name: Job name.
    /// - Returns: Matching job, or nil when absent.
    public func job(named name: String) -> SchedulerJobConfig? {
        let wanted = normalizedSchedulerJobName(name)
        return jobs.first { normalizedSchedulerJobName($0.name) == wanted }
    }

    /// Validates every job entry.
    public func validate() throws {
        var seen: Set<String> = []
        for job in jobs {
            let trimmedName = normalizedSchedulerJobName(job.name)
            if !trimmedName.isEmpty {
                if seen.contains(trimmedName) {
                    throw SchedulerConfigError.duplicateName(job: trimmedName)
                }
                seen.insert(trimmedName)
            }
            try job.validate()
        }
    }
}

/// Why a scheduler job fired.
public enum SchedulerFireReason: Sendable, Equatable {
    /// A cron fire time fell in the check window.
    case cron
    /// Previously unseen mail arrived.
    case emailArrived(account: String, count: Int)
    /// Previously unseen message arrived.
    case messagesArrived(count: Int)
    /// Upcoming calendar event reached lead time window.
    case calendarUpcoming(title: String, eventID: String)

    /// Human-readable reason for run logs.
    public var displayName: String {
        switch self {
        case .cron:
            "cron"
        case let .emailArrived(account, count):
            "email(\(account),+\(count))"
        case let .messagesArrived(count):
            "messages(+\(count))"
        case let .calendarUpcoming(title, _):
            "calendar(\(title))"
        }
    }
}

/// One due job plus why it is due.
public struct SchedulerDueJob: Sendable, Equatable {
    /// Job that should fire.
    public let job: SchedulerJobConfig
    /// Why the job is due.
    public let reason: SchedulerFireReason

    /// Creates a due job.
    public init(job: SchedulerJobConfig, reason: SchedulerFireReason) {
        self.job = job
        self.reason = reason
    }
}

/// Current message ids observed by a poll check.
public struct SchedulerPollCheck: Sendable, Equatable {
    /// Message ids observed newest-first (may be empty on errors).
    public let ids: [String]

    /// Creates a poll check result.
    /// - Parameter ids: Observed message ids.
    public init(ids: [String]) {
        self.ids = ids
    }

    /// Empty observation (network failure or no mail).
    public static var empty: SchedulerPollCheck {
        SchedulerPollCheck(ids: [])
    }
}

/// Runs one headless turn: prompt plus job session yields response text.
public typealias SchedulerTurnRunner = @Sendable (String, UUID, String) async throws -> String

/// Observes current message ids for a poll rule.
public typealias SchedulerPollChecker = @Sendable (EmailPollRule) async -> SchedulerPollCheck

/// Receives scheduler log lines (fires, skips, failures).
public typealias SchedulerLogHandler = @Sendable (String) async -> Void

/// Posts a user-visible notification when a job fires.
public protocol SchedulerNotifier: Sendable {
    /// Posts a notification, best-effort and never throwing.
    func notify(title: String, body: String) async
}

/// macOS notification via `osascript`, best-effort.
public struct MacOSSchedulerNotifier: SchedulerNotifier {
    /// Creates a macOS notifier.
    public init() {}

    /// Posts a macOS notification without blocking the caller.
    public func notify(title: String, body: String) async {
        let capturedTitle = title
        let capturedBody = body
        DispatchQueue.global(qos: .utility).async {
            MacOSSchedulerNotifier.post(title: capturedTitle, body: capturedBody)
        }
    }

    /// Posts a macOS notification synchronously, best-effort.
    public static func post(title: String, body: String) {
        let executable = "/usr/bin/osascript"
        guard FileManager.default.isExecutableFile(atPath: executable) else { return }
        // Use osascript on run argv to pass title and body as positional
        // arguments so that shell metacharacters and AppleScript syntax cannot
        // escape or inject into the script.
        let preview = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let truncated = preview.count > 300 ? String(preview.prefix(300)) + "…" : preview
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [
            "-e", "on run argv",
            "-e", "display notification (item 2 of argv) with title (item 1 of argv)",
            "-e", "end run",
            title,
            truncated
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return
        }
        process.waitUntilExit()
    }
}

/// No-op notifier for tests and headless CI.
public struct NoOpSchedulerNotifier: SchedulerNotifier {
    /// Creates a no-op notifier.
    public init() {}

    /// Discards the notification.
    public func notify(title _: String, body _: String) async {}
}

/// Outcome of one scheduler job execution.
public struct SchedulerRunResult: Sendable, Equatable {
    /// Job name that was attempted.
    public let jobName: String
    /// Stable job session the turn ran under.
    public let sessionID: UUID
    /// Whether the turn executed (false for skips).
    public let fired: Bool
    /// Skip reason when `fired` is false (already-running or disabled).
    public let skippedReason: String?
    /// Final assistant text when the turn executed.
    public let responseText: String?
    /// Failure detail when the turn threw.
    public let errorMessage: String?
    /// Why the job fired (nil for skips).
    public let fireReason: SchedulerFireReason?
    /// When the attempt started.
    public let startedAt: Date
    /// When the attempt finished.
    public let finishedAt: Date
    /// Goal this run advanced, when the turn was a goal fire rather than a job
    /// fire. Skipped goal fires carry a fresh placeholder `sessionID` plus this
    /// link, so consumers joining `sessionID` to `sessions` never meet a goal
    /// identifier masquerading as a session.
    public let goalID: UUID?

    /// Creates a run result.
    public init(
        jobName: String,
        sessionID: UUID,
        fired: Bool,
        skippedReason: String? = nil,
        responseText: String? = nil,
        errorMessage: String? = nil,
        fireReason: SchedulerFireReason? = nil,
        startedAt: Date = Date(),
        finishedAt: Date = Date(),
        goalID: UUID? = nil
    ) {
        self.jobName = jobName
        self.sessionID = sessionID
        self.fired = fired
        self.skippedReason = skippedReason
        self.responseText = responseText
        self.errorMessage = errorMessage
        self.fireReason = fireReason
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.goalID = goalID
    }

    /// Whether the run was skipped without executing.
    public var didSkip: Bool {
        !fired
    }

    /// Whether the turn executed without throwing.
    public var didSucceed: Bool {
        fired && errorMessage == nil
    }
}

/// Normalizes a scheduler job name for registry keys and session identity.
public func normalizedSchedulerJobName(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Foreground scheduler engine: due detection plus single-flight runs.
public actor SchedulerEngine {
    /// Jobs indexed by name.
    private var jobs: [String: SchedulerJobConfig] = [:]
    /// Job names with an in-flight turn.
    private var running: Set<String> = []
    /// Last fire date per job name.
    private var lastFire: [String: Date] = [:]
    /// Seen message ids per poll job name.
    private var pollSeen: [String: Set<String>] = [:]
    /// Last poll attempt per poll job name.
    private var pollLastCheck: [String: Date] = [:]
    /// Headless turn runner (nil means dry-run with empty text).
    private let turnRunner: SchedulerTurnRunner?
    /// Poll observer (nil means poll jobs never fire).
    private let pollChecker: SchedulerPollChecker?
    /// Log sink for fires, skips, and failures.
    private let logger: SchedulerLogHandler?
    /// User-visible notifier for fired jobs.
    private let notifier: (any SchedulerNotifier)?

    /// Creates a scheduler engine.
    public init(
        jobs: [SchedulerJobConfig] = [],
        turnRunner: SchedulerTurnRunner? = nil,
        pollChecker: SchedulerPollChecker? = nil,
        logger: SchedulerLogHandler? = nil,
        notifier: (any SchedulerNotifier)? = nil
    ) {
        for job in jobs {
            let key = normalizedSchedulerJobName(job.name)
            if self.jobs[key] == nil {
                self.jobs[key] = job
            }
        }
        self.turnRunner = turnRunner
        self.pollChecker = pollChecker
        self.logger = logger
        self.notifier = notifier
    }

    /// Replaces the job set.
    public func setJobs(_ jobs: [SchedulerJobConfig]) {
        var merged: [String: SchedulerJobConfig] = [:]
        for job in jobs {
            let key = normalizedSchedulerJobName(job.name)
            if merged[key] == nil {
                merged[key] = job
            }
        }
        self.jobs = merged
    }

    /// Inserts or replaces one job.
    /// - Parameter job: Job to store.
    public func upsert(_ job: SchedulerJobConfig) {
        jobs[normalizedSchedulerJobName(job.name)] = job
    }

    /// Removes one job and its poll state. Unknown names are a no-op.
    /// - Parameter name: Job name to remove.
    public func remove(named name: String) {
        let key = normalizedSchedulerJobName(name)
        jobs.removeValue(forKey: key)
        pollSeen.removeValue(forKey: key)
        pollLastCheck.removeValue(forKey: key)
    }

    /// Removes every job and all poll state.
    public func clear() {
        jobs.removeAll()
        pollSeen.removeAll()
        pollLastCheck.removeAll()
    }

    /// Lists every job sorted by name.
    /// - Returns: All jobs.
    public func list() -> [SchedulerJobConfig] {
        jobs.values.sorted { $0.name < $1.name }
    }

    /// Number of stored jobs.
    /// - Returns: Job count.
    public func count() -> Int {
        jobs.count
    }

    /// Looks up one job.
    /// - Parameter name: Job name.
    /// - Returns: The job, or nil when unknown.
    public func job(named name: String) -> SchedulerJobConfig? {
        jobs[normalizedSchedulerJobName(name)]
    }

    /// Whether a job has an in-flight turn.
    /// - Parameter name: Job name.
    /// - Returns: True while the job is running.
    public func isRunning(named name: String) -> Bool {
        running.contains(normalizedSchedulerJobName(name))
    }

    /// Acquires the single-flight slot for a job.
    @discardableResult
    public func tryBegin(named name: String) -> Bool {
        let key = normalizedSchedulerJobName(name)
        if running.contains(key) {
            return false
        }
        running.insert(key)
        return true
    }

    /// Releases the single-flight slot for a job.
    /// - Parameter name: Job name.
    public func end(named name: String) {
        running.remove(normalizedSchedulerJobName(name))
    }

    /// Stable job session identifier for episodic memory.
    public nonisolated func sessionID(forJobNamed name: String) -> UUID {
        Self.deterministicSessionID(forJobNamed: name)
    }

    /// Deterministic UUID for a job name.
    public static func deterministicSessionID(forJobNamed name: String) -> UUID {
        let trimmed = normalizedSchedulerJobName(name)
        let first = fnv1a(trimmed, offset: 14_695_981_039_346_656_037, prime: 1_099_511_628_211)
        let second = fnv1a("scheduler:" + trimmed, offset: 7_553_070_159_641_209_101, prime: 1_099_511_628_211)
        let firstHex = String(format: "%016llx", first)
        let secondHex = String(format: "%016llx", second)
        let combined = firstHex + secondHex
        let head = combined.prefix(8)
        let midFirst = combined.dropFirst(8).prefix(4)
        let midSecond = combined.dropFirst(12).prefix(4)
        let midThird = combined.dropFirst(16).prefix(4)
        let tail = combined.dropFirst(20).prefix(12)
        let uuidString = "\(head)-\(midFirst)-\(midSecond)-\(midThird)-\(tail)"
        return UUID(uuidString: String(uuidString)) ?? UUID()
    }

    /// FNV-1a hash for deterministic session ids.
    private static func fnv1a(_ string: String, offset: UInt64, prime: UInt64) -> UInt64 {
        var hash = offset
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return hash
    }

    /// Cron jobs due in `(lastCheck, now]`.
    public func cronDueJobs(at now: Date, lastCheck: Date, calendar: Calendar = .current) -> [SchedulerDueJob] {
        var due: [SchedulerDueJob] = []
        for job in jobs.values where job.enabled {
            guard let expression = job.schedule?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !expression.isEmpty,
                  let schedule = try? CronSchedule.parse(expression)
            else { continue }
            if schedule.isDue(at: now, lastCheck: lastCheck, calendar: calendar) {
                due.append(SchedulerDueJob(job: job, reason: .cron))
            }
        }
        return due.sorted { $0.job.name < $1.job.name }
    }

    /// Poll jobs with previously unseen mail.
    public func pollDueJobs(at now: Date = Date()) async -> [SchedulerDueJob] {
        guard let pollChecker else { return [] }
        var due: [SchedulerDueJob] = []
        let ordered = jobs.values.filter { $0.enabled && $0.poll != nil }.sorted { $0.name < $1.name }
        for job in ordered {
            guard let rule = job.poll else { continue }
            let key = normalizedSchedulerJobName(job.name)
            if let last = pollLastCheck[key] {
                let elapsed = now.timeIntervalSince(last)
                // Defensive clamp keeps hand-built configs that bypass
                // validation from hot-looping the mailbox.
                if elapsed < Double(EmailPollRule.clampedPollIntervalSeconds(rule.pollIntervalSeconds)) {
                    continue
                }
            }
            pollLastCheck[key] = now
            let check = await pollChecker(rule)
            let current = Set(check.ids.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            if pollSeen[key] == nil {
                pollSeen[key] = current
                continue
            }
            let seen = pollSeen[key] ?? []
            let fresh = current.subtracting(seen)
            pollSeen[key] = seen.union(current)
            if !fresh.isEmpty {
                due.append(SchedulerDueJob(job: job, reason: .emailArrived(account: rule.trimmedAccount, count: fresh.count)))
            }
        }
        return due
    }

    /// Every due job (cron plus poll) for a check window.
    public func dueJobs(at now: Date, lastCheck: Date, calendar: Calendar = .current) async -> [SchedulerDueJob] {
        let cron = cronDueJobs(at: now, lastCheck: lastCheck, calendar: calendar)
        let poll = await pollDueJobs(at: now)
        var merged: [String: SchedulerDueJob] = [:]
        for entry in cron + poll {
            merged[normalizedSchedulerJobName(entry.job.name)] = entry
        }
        return merged.values.sorted { $0.job.name < $1.job.name }
    }

    /// Runs one job single-flight, logging and notifying.
    @discardableResult
    public func run(
        job: SchedulerJobConfig,
        sessionID: UUID? = nil,
        source: String = "scheduler",
        reason: SchedulerFireReason = .cron
    ) async -> SchedulerRunResult {
        let resolvedSession = sessionID ?? self.sessionID(forJobNamed: job.name)
        let started = Date()
        let key = normalizedSchedulerJobName(job.name)
        guard job.enabled else {
            let line = "Scheduler skipped '\(job.name)': disabled"
            await logger?(line)
            return SchedulerRunResult(
                jobName: job.name,
                sessionID: resolvedSession,
                fired: false,
                skippedReason: "disabled",
                fireReason: nil,
                startedAt: started,
                finishedAt: Date()
            )
        }
        guard tryBegin(named: key) else {
            let line = "Scheduler skipped '\(job.name)': already running"
            await logger?(line)
            return SchedulerRunResult(
                jobName: job.name,
                sessionID: resolvedSession,
                fired: false,
                skippedReason: "already running",
                fireReason: nil,
                startedAt: started,
                finishedAt: Date()
            )
        }
        defer { running.remove(key) }
        lastFire[key] = started
        do {
            let text: String = if let turnRunner {
                try await turnRunner(job.prompt, resolvedSession, source)
            } else {
                ""
            }
            let preview = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let short = preview.count > 160 ? String(preview.prefix(160)) + "…" : preview
            await logger?("Scheduler fired '\(job.name)' (\(reason.displayName)): \(short)")
            await notifier?.notify(title: "Rune Weaver: \(job.name)", body: short.isEmpty ? job.prompt : short)
            return SchedulerRunResult(
                jobName: job.name,
                sessionID: resolvedSession,
                fired: true,
                responseText: text,
                fireReason: reason,
                startedAt: started,
                finishedAt: Date()
            )
        } catch {
            let detail = error.localizedDescription
            await logger?("Scheduler failed '\(job.name)': \(detail)")
            return SchedulerRunResult(
                jobName: job.name,
                sessionID: resolvedSession,
                fired: true,
                errorMessage: detail,
                fireReason: reason,
                startedAt: started,
                finishedAt: Date()
            )
        }
    }

    /// Runs one job by name.
    @discardableResult
    public func run(named name: String, source: String = "scheduler", reason: SchedulerFireReason = .cron) async -> SchedulerRunResult? {
        guard let job = jobs[normalizedSchedulerJobName(name)] else { return nil }
        return await run(job: job, source: source, reason: reason)
    }

    /// Runs every due job for a check window, skipping overlap with logs.
    public func runAllDue(at now: Date, lastCheck: Date, calendar: Calendar = .current) async -> [SchedulerRunResult] {
        let due = await dueJobs(at: now, lastCheck: lastCheck, calendar: calendar)
        var results: [SchedulerRunResult] = []
        for entry in due {
            await results.append(run(job: entry.job, reason: entry.reason))
        }
        return results
    }

    /// Last fire date for a job, if it ever fired in this process.
    /// - Parameter name: Job name.
    /// - Returns: Last fire date, or nil when never fired.
    public func lastFireDate(named name: String) -> Date? {
        lastFire[normalizedSchedulerJobName(name)]
    }
}

#if canImport(SQLite3)
    /// Single shared decoder for `scheduler_jobs` rows.
    package struct SchedulerJobRow: Sendable {
        /// Job name as stored.
        package let name: String
        /// Cron expression as stored (empty for poll-only jobs).
        package let schedule: String
        /// Prompt as stored.
        package let prompt: String
        /// Whether the job fires.
        package let enabled: Bool
        /// Poll account nickname, when the job watches email arrival.
        package let pollAccount: String?
        /// Poll query, when set.
        package let pollQuery: String?
        /// Poll mailbox, when set.
        package let pollMailbox: String?
        /// Seconds between poll checks, when set.
        package let pollIntervalSeconds: Int?
        /// Maximum hits fetched per poll, when set.
        package let pollLimit: Int?
        /// Maximum tool iterations before limit policy triggers, when set.
        package let maxToolIterations: Int?
        /// Action when tool limit is reached ("fail" or "park"), when set.
        package let onToolLimit: String?

        /// Decodes the shared columns starting at an offset.
        package static func decode(_ statement: OpaquePointer?, base: Int32) -> Self? {
            guard let name = SQLiteHelpers.columnText(statement, index: base),
                  let schedule = SQLiteHelpers.columnText(statement, index: base + 1),
                  let prompt = SQLiteHelpers.columnText(statement, index: base + 2)
            else { return nil }
            let enabled = (SQLiteHelpers.columnInt64(statement, index: base + 3) ?? 1) != 0
            return Self(
                name: name,
                schedule: schedule,
                prompt: prompt,
                enabled: enabled,
                pollAccount: SQLiteHelpers.columnText(statement, index: base + 4),
                pollQuery: SQLiteHelpers.columnText(statement, index: base + 5),
                pollMailbox: SQLiteHelpers.columnText(statement, index: base + 6),
                pollIntervalSeconds: SQLiteHelpers.columnInt64(statement, index: base + 7).map { Int($0) },
                pollLimit: SQLiteHelpers.columnInt64(statement, index: base + 8).map { Int($0) },
                maxToolIterations: SQLiteHelpers.columnInt64(statement, index: base + 9).map { Int($0) },
                onToolLimit: SQLiteHelpers.columnText(statement, index: base + 10)
            )
        }

        /// Builds the poll rule for this row, when an account is set.
        package func makePollRule() -> EmailPollRule? {
            EmailPollRule.ruleForStoredFields(
                pollAccount: pollAccount,
                pollQuery: pollQuery,
                pollMailbox: pollMailbox,
                pollIntervalSeconds: pollIntervalSeconds,
                pollLimit: pollLimit
            )
        }

        /// Cron expression for config readers, with blank folded to nil.
        package var configSchedule: String? {
            EmailPollRule.configSchedule(from: schedule)
        }
    }
#endif

extension SchedulerJobConfig {
    /// Loads durable scheduler configs for direct-core entry points.
    public static func persistedConfigs(from dbPath: String) async -> [SchedulerJobConfig] {
        #if canImport(SQLite3)
            do {
                return try await SQLiteSerialIO.run {
                    persistedConfigsBlocking(from: dbPath)
                }
            } catch {
                RuneWeaverLog.stores.warning(
                    "SchedulerJobConfig: Failed reading scheduler configs from SQLite: \(error.localizedDescription); falling back to config seed."
                )
                return []
            }
        #else
            return []
        #endif
    }

    #if canImport(SQLite3)
        /// Blocking SQLite read behind `persistedConfigs(from:)`.
        private static func persistedConfigsBlocking(from dbPath: String) -> [SchedulerJobConfig] {
            struct LoadError: Error {}
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return [] }
            let handle: OpaquePointer
            do {
                guard let opened = try SQLiteHelpers.openHandle(dbPath: dbPath, unavailable: { _ in LoadError() }) else {
                    return []
                }
                handle = opened
            } catch {
                RuneWeaverLog.stores.warning(
                    "SchedulerJobConfig: Failed opening scheduler store at \(dbPath): \(error.localizedDescription); falling back to config seed."
                )
                return []
            }
            defer { sqlite3_close(handle) }
            _ = try? SQLiteHelpers.exec(
                handle: handle,
                sql: "ALTER TABLE scheduler_jobs ADD COLUMN max_tool_iterations INTEGER;",
                failure: { _ in LoadError() }
            )
            _ = try? SQLiteHelpers.exec(
                handle: handle,
                sql: "ALTER TABLE scheduler_jobs ADD COLUMN on_tool_limit TEXT;",
                failure: { _ in LoadError() }
            )
            // Watcher columns delegate to the single shared statement owner so
            // server persistence and direct-core reads add identical columns.
            SchedulerJobConfig.applyWatcherColumnMigrations { statement in
                _ = try? SQLiteHelpers.exec(
                    handle: handle,
                    sql: statement,
                    failure: { _ in LoadError() }
                )
            }
            let sql = """
            SELECT name, schedule, prompt, enabled, poll_account, poll_query, poll_mailbox,
                   poll_interval_seconds, poll_limit, max_tool_iterations, on_tool_limit,
                   watcher_source, rules, calendar_lead_time_minutes, calendar_names
            FROM scheduler_jobs
            ORDER BY created_at ASC;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                let code = sqlite3_errcode(handle)
                RuneWeaverLog.stores.warning("SchedulerJobConfig: Failed preparing scheduler read (code \(code)); falling back to config seed.")
                return []
            }
            defer { sqlite3_finalize(statement) }
            var loaded: [SchedulerJobConfig] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let row = SchedulerJobRow.decode(statement, base: 0) else { continue }
                let watcherRaw = SQLiteHelpers.columnText(statement, index: 11)
                let watcherSource = watcherRaw.flatMap { EventWatcherSource(rawValue: $0) }
                let rulesRaw = SQLiteHelpers.columnText(statement, index: 12)
                let rules: [EventRule]? = rulesRaw.flatMap { json in
                    guard let data = json.data(using: .utf8) else { return nil }
                    return try? JSONDecoder().decode([EventRule].self, from: data)
                }
                let leadTime = SQLiteHelpers.columnInt64(statement, index: 13).map { Int($0) }
                let calNamesRaw = SQLiteHelpers.columnText(statement, index: 14)
                let calendarNames: [String]? = calNamesRaw.flatMap { json in
                    guard let data = json.data(using: .utf8) else { return nil }
                    return try? JSONDecoder().decode([String].self, from: data)
                }
                loaded.append(SchedulerJobConfig(
                    name: row.name,
                    prompt: row.prompt,
                    enabled: row.enabled,
                    schedule: row.configSchedule,
                    poll: row.makePollRule(),
                    maxToolIterations: row.maxToolIterations,
                    onToolLimit: row.onToolLimit,
                    watcherSource: watcherSource,
                    rules: rules,
                    calendarLeadTimeMinutes: leadTime,
                    calendarNames: calendarNames
                ))
            }
            return loaded
        }
    #endif
}

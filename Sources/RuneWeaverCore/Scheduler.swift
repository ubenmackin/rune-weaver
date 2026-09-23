// Rune Weaver Core — Scheduler expressions, poll triggers, and engine.

import Foundation
#if canImport(SQLite3)
    import SQLite3
#endif

/// Failures raised while parsing a cron-like schedule expression.
public enum CronScheduleError: Error, Sendable, Equatable {
    /// The expression has the wrong shape (not five fields or unknown shortcut).
    case invalidExpression(String)
    /// One field could not be parsed.
    case invalidField(field: String, value: String)
    /// A numeric value falls outside its allowed range.
    case outOfRange(field: String, value: Int, range: String)
}

/// A five-field cron schedule (`minute hour day month weekday`).
public struct CronSchedule: Sendable, Codable, Equatable {
    /// Allowed minutes (`0-59`).
    public let minutes: Set<Int>
    /// Allowed hours (`0-23`).
    public let hours: Set<Int>
    /// Allowed days of month (`1-31`).
    public let days: Set<Int>
    /// Allowed months (`1-12`).
    public let months: Set<Int>
    /// Allowed weekdays (`0-6`, `0` is Sunday).
    public let weekdays: Set<Int>

    /// Creates a schedule from pre-validated sets.
    public init(minutes: Set<Int>, hours: Set<Int>, days: Set<Int>, months: Set<Int>, weekdays: Set<Int>) {
        self.minutes = minutes
        self.hours = hours
        self.days = days
        self.months = months
        self.weekdays = weekdays
    }

    /// Creates a schedule by parsing an expression.
    /// - Parameter expression: Five-field cron text or `@` shortcut.
    /// - Throws: ``CronScheduleError`` when the text is malformed.
    public init(parsing expression: String) throws {
        self = try Self.parse(expression)
    }

    /// Parses an expression into a schedule.
    public static func parse(_ expression: String) throws -> CronSchedule {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CronScheduleError.invalidExpression("schedule must not be empty")
        }
        if trimmed.hasPrefix("@") {
            return try parseShortcut(trimmed)
        }
        let fields = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard fields.count == 5 else {
            throw CronScheduleError.invalidExpression(
                "expected five fields 'minute hour day month weekday' (got \(fields.count) in '\(trimmed)')"
            )
        }
        let minutes = try parseField(fields[0], range: 0 ... 59, field: "minute")
        let hours = try parseField(fields[1], range: 0 ... 23, field: "hour")
        let days = try parseField(fields[2], range: 1 ... 31, field: "day")
        let months = try parseField(fields[3], range: 1 ... 12, field: "month")
        let rawWeekdays = try parseField(fields[4], range: 0 ... 7, field: "weekday")
        var weekdays = rawWeekdays
        if weekdays.contains(7) {
            weekdays.remove(7)
            weekdays.insert(0)
        }
        return CronSchedule(minutes: minutes, hours: hours, days: days, months: months, weekdays: weekdays)
    }

    /// Whether an expression parses without throwing.
    /// - Parameter expression: Candidate cron text or shortcut.
    /// - Returns: True when parsing succeeds.
    public static func isValid(_ expression: String) -> Bool {
        (try? parse(expression)) != nil
    }

    /// Whether a date matches this schedule.
    public func matches(_ date: Date, calendar: Calendar = .current) -> Bool {
        let components = calendar.dateComponents([.minute, .hour, .day, .month, .weekday], from: date)
        guard let minute = components.minute,
              let hour = components.hour,
              let day = components.day,
              let month = components.month,
              let weekday = components.weekday
        else { return false }
        let cronWeekday = (weekday - 1) % 7
        guard minutes.contains(minute), hours.contains(hour), months.contains(month) else { return false }
        let domUnrestricted = days == Set(1 ... 31)
        let dowUnrestricted = weekdays == Set(0 ... 6)
        if domUnrestricted, dowUnrestricted {
            return true
        }
        if domUnrestricted {
            return weekdays.contains(cronWeekday)
        }
        if dowUnrestricted {
            return days.contains(day)
        }
        return days.contains(day) || weekdays.contains(cronWeekday)
    }

    /// Computes the next fire time strictly after a date.
    public func nextFire(after date: Date, calendar: Calendar = .current) -> Date? {
        let working = calendar
        guard let secondZeroed = working.date(bySetting: .second, value: 0, of: date) else { return nil }
        let nanoZeroed = working.date(bySetting: .nanosecond, value: 0, of: secondZeroed) ?? secondZeroed
        let candidate: Date
        if nanoZeroed <= date {
            guard let advanced = working.date(byAdding: .minute, value: 1, to: nanoZeroed) else { return nil }
            candidate = advanced
        } else {
            candidate = nanoZeroed
        }
        var cursor = candidate
        for _ in 0 ..< 527_040 {
            if matches(cursor, calendar: working) {
                return cursor
            }
            guard let next = working.date(byAdding: .minute, value: 1, to: cursor) else { return nil }
            cursor = next
        }
        return nil
    }

    /// Whether the schedule fires in a half-open check window.
    public func isDue(at now: Date, lastCheck: Date, calendar: Calendar = .current) -> Bool {
        guard let next = nextFire(after: lastCheck, calendar: calendar) else { return false }
        return next <= now
    }

    /// Canonical display of the schedule (sorted lists, `*` for full ranges).
    public var canonicalExpression: String {
        let minute = Self.formatField(minutes, full: Set(0 ... 59))
        let hour = Self.formatField(hours, full: Set(0 ... 23))
        let day = Self.formatField(days, full: Set(1 ... 31))
        let month = Self.formatField(months, full: Set(1 ... 12))
        let weekday = Self.formatField(weekdays, full: Set(0 ... 6))
        return "\(minute) \(hour) \(day) \(month) \(weekday)"
    }

    // MARK: - Private parsing

    /// Parses an `@` shortcut into a schedule.
    private static func parseShortcut(_ text: String) throws -> CronSchedule {
        let lowered = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let expanded: String
        switch lowered {
        case "@yearly", "@annually":
            expanded = "0 0 1 1 *"
        case "@monthly":
            expanded = "0 0 1 * *"
        case "@weekly":
            expanded = "0 0 * * 0"
        case "@daily", "@midnight":
            expanded = "0 0 * * *"
        case "@hourly":
            expanded = "0 * * * *"
        case "@minutely", "@every_minute":
            expanded = "* * * * *"
        default:
            throw CronScheduleError.invalidExpression("unknown schedule shortcut '\(text)'")
        }
        return try parse(expanded)
    }

    /// Parses one cron field into its allowed values.
    private static func parseField(_ text: String, range: ClosedRange<Int>, field: String) throws -> Set<Int> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CronScheduleError.invalidField(field: field, value: text)
        }
        if trimmed == "*" {
            return Set(range)
        }
        var values = Set<Int>()
        let parts = trimmed.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty else {
            throw CronScheduleError.invalidField(field: field, value: text)
        }
        for part in parts {
            let expanded = try parseListPart(part, range: range, field: field)
            values.formUnion(expanded)
        }
        guard !values.isEmpty else {
            throw CronScheduleError.invalidField(field: field, value: text)
        }
        return values
    }

    /// Parses one comma-separated list element.
    private static func parseListPart(_ part: String, range: ClosedRange<Int>, field: String) throws -> Set<Int> {
        let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CronScheduleError.invalidField(field: field, value: part)
        }
        if trimmed.contains("/") {
            let sides = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard sides.count == 2 else {
                throw CronScheduleError.invalidField(field: field, value: part)
            }
            guard let step = Int(sides[1].trimmingCharacters(in: .whitespaces)), step > 0 else {
                throw CronScheduleError.invalidField(field: field, value: part)
            }
            let base = sides[0].trimmingCharacters(in: .whitespaces)
            if base == "*" {
                return Set(stride(from: range.lowerBound, through: range.upperBound, by: step))
            }
            if base.contains("-") {
                let bounds = try parseRangeBounds(base, range: range, field: field)
                return Set(stride(from: bounds.0, through: bounds.1, by: step))
            }
            guard let start = Int(base) else {
                throw CronScheduleError.invalidField(field: field, value: part)
            }
            try checkRange(start, range: range, field: field)
            return Set(stride(from: start, through: range.upperBound, by: step))
        }
        if trimmed.contains("-") {
            let bounds = try parseRangeBounds(trimmed, range: range, field: field)
            return Set(bounds.0 ... bounds.1)
        }
        guard let single = Int(trimmed) else {
            throw CronScheduleError.invalidField(field: field, value: part)
        }
        try checkRange(single, range: range, field: field)
        return [single]
    }

    /// Parses `low-high` range bounds.
    private static func parseRangeBounds(_ text: String, range: ClosedRange<Int>, field: String) throws -> (Int, Int) {
        let sides = text.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard sides.count == 2,
              let low = Int(sides[0].trimmingCharacters(in: .whitespaces)),
              let high = Int(sides[1].trimmingCharacters(in: .whitespaces))
        else {
            throw CronScheduleError.invalidField(field: field, value: text)
        }
        try checkRange(low, range: range, field: field)
        try checkRange(high, range: range, field: field)
        guard low <= high else {
            throw CronScheduleError.invalidField(field: field, value: text)
        }
        return (low, high)
    }

    /// Validates one numeric value against its range.
    private static func checkRange(_ value: Int, range: ClosedRange<Int>, field: String) throws {
        guard range.contains(value) else {
            throw CronScheduleError.outOfRange(field: field, value: value, range: "\(range.lowerBound)-\(range.upperBound)")
        }
    }

    /// Formats one field set for display.
    private static func formatField(_ values: Set<Int>, full: Set<Int>) -> String {
        if values == full {
            return "*"
        }
        return values.sorted().map(String.init).joined(separator: ",")
    }
}

/// A poll-based email-arrival rule for scheduled jobs.
public struct EmailPollRule: Sendable, Codable, Equatable {
    /// Default seconds between polls when no interval is supplied.
    public static let defaultPollIntervalSeconds = 300
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
    /// Seconds between polls. Must be positive.
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
    /// A job has neither a cron schedule nor a poll rule.
    case missingTrigger(job: String)
    /// A cron expression does not parse.
    case invalidCron(job: String, expression: String, detail: String)
    /// A poll rule is malformed.
    case invalidPoll(job: String, detail: String)
}

public extension SchedulerConfigError {
    /// Owning job name, if the failure is scoped to one job.
    /// - Returns: Job name, or nil for job-agnostic failures.
    var jobName: String? {
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
        }
    }

    /// Single-sourced human-readable detail shared by every
    /// `SchedulerConfigError` mapping site so message drift is impossible.
    /// - Returns: Detail message for the failure.
    var displayDetail: String {
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
        }
    }

    /// Single-sourced field suffix shared by every mapping site so field
    /// drift is impossible. Nil means the failure is job-scoped.
    /// - Returns: Dotted field suffix, or nil for job-level failures.
    var fieldSuffix: String? {
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
            } else if detail.contains("poll account") {
                "poll_account"
            } else {
                nil
            }
        }
    }
}

/// One `[[scheduler.jobs]]` entry: a named prompt plus its triggers.
public struct SchedulerJobConfig: Sendable, Codable, Equatable {
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

    /// Creates a job config.
    public init(
        name: String,
        prompt: String,
        enabled: Bool = true,
        schedule: String? = nil,
        poll: EmailPollRule? = nil
    ) {
        self.name = name
        self.prompt = prompt
        self.enabled = enabled
        self.schedule = schedule
        self.poll = poll
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
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SchedulerConfigError.emptyPrompt(job: name)
        }
        let hasCron = hasCronTrigger
        let hasPoll = hasPollTrigger
        guard hasCron || hasPoll else {
            throw SchedulerConfigError.missingTrigger(job: name)
        }
        if hasCron {
            _ = try cronSchedule()
        }
        if let poll {
            guard !poll.trimmedAccount.isEmpty else {
                throw SchedulerConfigError.invalidPoll(job: name, detail: "poll account must not be empty")
            }
            guard poll.pollIntervalSeconds > 0 else {
                throw SchedulerConfigError.invalidPoll(job: name, detail: "poll_interval_seconds must be positive")
            }
            guard (EmailPollRule.minLimit ... EmailPollRule.maxLimit).contains(poll.limit) else {
                throw SchedulerConfigError.invalidPoll(
                    job: name,
                    detail: "poll_limit must be between \(EmailPollRule.minLimit) and \(EmailPollRule.maxLimit)"
                )
            }
        }
    }
}

/// The `[scheduler]` section: every `[[scheduler.jobs]]` entry.
public struct SchedulerConfig: Sendable, Codable, Equatable {
    /// Configured jobs in file order.
    public var jobs: [SchedulerJobConfig]

    /// Creates a scheduler config.
    /// - Parameter jobs: Configured jobs. Defaults to empty.
    public init(jobs: [SchedulerJobConfig] = []) {
        self.jobs = jobs
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

    /// Human-readable reason for run logs.
    public var displayName: String {
        switch self {
        case .cron:
            "cron"
        case let .emailArrived(account, count):
            "email(\(account),+\(count))"
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
                if elapsed < Double(max(1, rule.pollIntervalSeconds)) {
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
                pollLimit: SQLiteHelpers.columnInt64(statement, index: base + 8).map { Int($0) }
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

public extension SchedulerJobConfig {
    /// Loads durable scheduler configs for direct-core entry points.
    static func persistedConfigs(from dbPath: String) async -> [SchedulerJobConfig] {
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
            let sql = """
            SELECT name, schedule, prompt, enabled, poll_account, poll_query, poll_mailbox, poll_interval_seconds, poll_limit
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
                loaded.append(SchedulerJobConfig(
                    name: row.name,
                    prompt: row.prompt,
                    enabled: row.enabled,
                    schedule: row.configSchedule,
                    poll: row.makePollRule()
                ))
            }
            return loaded
        }
    #endif
}

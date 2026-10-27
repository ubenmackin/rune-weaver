// Rune Weaver Server — Scheduler REST payloads for job creation and updates.

import Foundation
import RuneWeaverCore

/// Payload for `POST /scheduler/jobs`.
public struct NewSchedulerJob: Sendable, Codable, Equatable {
    /// Human-readable job name.
    public let name: String
    /// Cron-like schedule expression (empty for poll-only jobs).
    public let schedule: String
    /// Prompt executed when the job fires.
    public let prompt: String
    /// Whether the job fires. Defaults to true when omitted.
    public var enabled: Bool?
    /// Poll account nickname, when the job watches email arrival.
    public var pollAccount: String?
    /// Poll query for `email.search`.
    public var pollQuery: String?
    /// Contains alias for `pollQuery` from the dashboard editor.
    public var pollContains: String?
    /// Poll mailbox (nil means every selectable mailbox).
    public var pollMailbox: String?
    /// Seconds between poll checks.
    public var pollIntervalSeconds: Int?
    /// Maximum hits fetched per poll.
    public var pollLimit: Int?
    /// Sender filter for structured polling (nil means no sender scoping).
    public var pollFrom: String?
    /// Subject filter for structured polling (nil means no subject scoping).
    public var pollSubject: String?
    /// Whether to restrict the poll to unread mail only.
    public var pollUnreadOnly: Bool?
    /// Lookback days for `SINCE` scoping (nil means no date bound).
    public var pollSinceDays: Int?
    /// Owner-set flag marking this job as the owner of an email-report run
    /// cursor. Never inferred from job text.
    public var emailReportJob: Bool?
    /// Maximum tool iterations before limit policy triggers, or nil to inherit default.
    public var maxToolIterations: Int?
    /// Action when tool limit is reached: "fail" (synthesize & budget_exceeded) or "park". Defaults to "fail".
    public var onToolLimit: String?
    /// Event watcher source (email, messages, or calendar).
    public var watcherSource: EventWatcherSource?
    /// Ordered event rules executed on incoming events.
    public var rules: [EventRule]?
    /// Lead time in minutes for calendar upcoming event trigger. Defaults to 15.
    public var calendarLeadTimeMinutes: Int?
    /// Calendar names to watch for calendar upcoming event trigger.
    public var calendarNames: [String]?

    private enum CodingKeys: String, CodingKey {
        case name
        case schedule
        case prompt
        case enabled
        case pollAccount
        case pollQuery
        case pollContains
        case pollContainsSnake = "poll_contains"
        case pollQuerySnake = "poll_query"
        case pollMailbox
        case pollIntervalSeconds
        case pollLimit
        case pollFrom
        case pollSubject
        case pollUnreadOnly
        case pollSinceDays
        case emailReportJob
        case maxToolIterations
        case onToolLimit
        case watcherSource
        case rules
        case calendarLeadTimeMinutes
        case calendarNames
    }

    /// Creates a new-job payload.
    public init(
        name: String,
        schedule: String,
        prompt: String,
        enabled: Bool? = nil,
        pollAccount: String? = nil,
        pollQuery: String? = nil,
        pollContains: String? = nil,
        pollMailbox: String? = nil,
        pollIntervalSeconds: Int? = nil,
        pollLimit: Int? = nil,
        pollFrom: String? = nil,
        pollSubject: String? = nil,
        pollUnreadOnly: Bool? = nil,
        pollSinceDays: Int? = nil,
        emailReportJob: Bool? = nil,
        maxToolIterations: Int? = nil,
        onToolLimit: String? = nil,
        watcherSource: EventWatcherSource? = nil,
        rules: [EventRule]? = nil,
        calendarLeadTimeMinutes: Int? = nil,
        calendarNames: [String]? = nil
    ) {
        self.name = name
        self.schedule = schedule
        self.prompt = prompt
        self.enabled = enabled
        self.pollAccount = pollAccount
        self.pollQuery = pollQuery
        self.pollContains = pollContains
        self.pollMailbox = pollMailbox
        self.pollIntervalSeconds = pollIntervalSeconds
        self.pollLimit = pollLimit
        self.pollFrom = pollFrom
        self.pollSubject = pollSubject
        self.pollUnreadOnly = pollUnreadOnly
        self.pollSinceDays = pollSinceDays
        self.emailReportJob = emailReportJob
        self.maxToolIterations = maxToolIterations
        self.onToolLimit = onToolLimit
        self.watcherSource = watcherSource
        self.rules = rules
        self.calendarLeadTimeMinutes = calendarLeadTimeMinutes
        self.calendarNames = calendarNames
    }

    /// Decodes the payload accepting `pollContains`/`poll_contains` as aliases for `pollQuery`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        schedule = try container.decode(String.self, forKey: .schedule)
        prompt = try container.decode(String.self, forKey: .prompt)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
        pollAccount = try container.decodeIfPresent(String.self, forKey: .pollAccount)
        let directQuery = try container.decodeIfPresent(String.self, forKey: .pollQuery)
            ?? container.decodeIfPresent(String.self, forKey: .pollQuerySnake)
        let aliasContains = try container.decodeIfPresent(String.self, forKey: .pollContains)
            ?? container.decodeIfPresent(String.self, forKey: .pollContainsSnake)
        pollQuery = directQuery ?? aliasContains
        pollContains = aliasContains ?? directQuery
        pollMailbox = try container.decodeIfPresent(String.self, forKey: .pollMailbox)
        pollIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .pollIntervalSeconds)
        pollLimit = try container.decodeIfPresent(Int.self, forKey: .pollLimit)
        pollFrom = try container.decodeIfPresent(String.self, forKey: .pollFrom)
        pollSubject = try container.decodeIfPresent(String.self, forKey: .pollSubject)
        pollUnreadOnly = try container.decodeIfPresent(Bool.self, forKey: .pollUnreadOnly)
        pollSinceDays = try container.decodeIfPresent(Int.self, forKey: .pollSinceDays)
        emailReportJob = try container.decodeIfPresent(Bool.self, forKey: .emailReportJob)
        maxToolIterations = try container.decodeIfPresent(Int.self, forKey: .maxToolIterations)
        onToolLimit = try container.decodeIfPresent(String.self, forKey: .onToolLimit)
        watcherSource = try container.decodeIfPresent(EventWatcherSource.self, forKey: .watcherSource)
        rules = try container.decodeIfPresent([EventRule].self, forKey: .rules)
        calendarLeadTimeMinutes = try container.decodeIfPresent(Int.self, forKey: .calendarLeadTimeMinutes)
        calendarNames = try container.decodeIfPresent([String].self, forKey: .calendarNames)
    }

    /// Encodes the payload mirroring `pollQuery` into `pollContains` for older readers.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(schedule, forKey: .schedule)
        try container.encode(prompt, forKey: .prompt)
        try container.encodeIfPresent(enabled, forKey: .enabled)
        try container.encodeIfPresent(pollAccount, forKey: .pollAccount)
        try container.encodeIfPresent(pollQuery, forKey: .pollQuery)
        try container.encodeIfPresent(pollContains ?? pollQuery, forKey: .pollContains)
        try container.encodeIfPresent(pollMailbox, forKey: .pollMailbox)
        try container.encodeIfPresent(pollIntervalSeconds, forKey: .pollIntervalSeconds)
        try container.encodeIfPresent(pollLimit, forKey: .pollLimit)
        try container.encodeIfPresent(pollFrom, forKey: .pollFrom)
        try container.encodeIfPresent(pollSubject, forKey: .pollSubject)
        try container.encodeIfPresent(pollUnreadOnly, forKey: .pollUnreadOnly)
        try container.encodeIfPresent(pollSinceDays, forKey: .pollSinceDays)
        try container.encodeIfPresent(emailReportJob, forKey: .emailReportJob)
        try container.encodeIfPresent(maxToolIterations, forKey: .maxToolIterations)
        try container.encodeIfPresent(onToolLimit, forKey: .onToolLimit)
        try container.encodeIfPresent(watcherSource, forKey: .watcherSource)
        try container.encodeIfPresent(rules, forKey: .rules)
        try container.encodeIfPresent(calendarLeadTimeMinutes, forKey: .calendarLeadTimeMinutes)
        try container.encodeIfPresent(calendarNames, forKey: .calendarNames)
    }
}

/// Payload for `PUT /scheduler/jobs/:id`. Every field is optional.
public struct UpdateSchedulerJob: Sendable, Codable, Equatable {
    /// New name, if renamed.
    public var name: String?
    /// New schedule, if rescheduled.
    public var schedule: String?
    /// New prompt, if changed.
    public var prompt: String?
    /// New enabled flag, if toggled.
    public var enabled: Bool?
    /// New poll account, if changed (`""` clears to nil).
    public var pollAccount: String?
    /// New poll query, if changed (`""` clears to nil).
    public var pollQuery: String?
    /// Contains alias for `pollQuery` from the dashboard editor.
    public var pollContains: String?
    /// New poll mailbox, if changed (`""` clears to nil).
    public var pollMailbox: String?
    /// New poll interval, if changed. Omitted (nil) leaves the interval
    /// alone; use `clearPoll: true` to clear it.
    public var pollIntervalSeconds: Int?
    /// New poll limit, if changed. Omitted (nil) leaves the limit
    /// alone; use `clearPoll: true` to clear it.
    public var pollLimit: Int?
    /// New sender filter, if changed (`""` clears to nil).
    public var pollFrom: String?
    /// New subject filter, if changed (`""` clears to nil).
    public var pollSubject: String?
    /// New unread-only flag, if changed. Omitted (nil) leaves it alone.
    public var pollUnreadOnly: Bool?
    /// New lookback days, if changed. Omitted (nil) leaves it alone.
    public var pollSinceDays: Int?
    /// New email-report flag, if changed. Omitted (nil) leaves the flag alone.
    public var emailReportJob: Bool?
    /// When true, clears the whole poll trigger to nil before applying
    /// any non-nil poll fields in the same payload.
    public var clearPoll: Bool?
    /// New maximum tool iterations, if changed. Omitted (nil) leaves the
    /// budget alone; use `clearToolBudget: true` to clear it to inherit (nil).
    public var maxToolIterations: Int?
    /// New action on tool limit ("fail" or "park"), if changed. Omitted (nil)
    /// leaves the policy alone; `""` clears to nil, or use
    /// `clearToolBudget: true` to clear it to inherit (nil).
    public var onToolLimit: String?
    /// When true, clears the whole tool budget to nil (inherit) before applying
    /// any non-nil budget fields in the same payload.
    public var clearToolBudget: Bool?
    /// New event watcher source, if changed.
    public var watcherSource: EventWatcherSource?
    /// New event rules, if changed.
    public var rules: [EventRule]?
    /// New lead time in minutes for calendar watcher.
    public var calendarLeadTimeMinutes: Int?
    /// New calendar names for calendar watcher.
    public var calendarNames: [String]?
    /// When true, clears the event watcher source and settings.
    public var clearWatcher: Bool?
    /// When true, clears event rules.
    public var clearRules: Bool?

    private enum CodingKeys: String, CodingKey {
        case name
        case schedule
        case prompt
        case enabled
        case pollAccount
        case pollQuery
        case pollContains
        case pollContainsSnake = "poll_contains"
        case pollQuerySnake = "poll_query"
        case pollMailbox
        case pollIntervalSeconds
        case pollLimit
        case pollFrom
        case pollSubject
        case pollUnreadOnly
        case pollSinceDays
        case clearPoll
        case emailReportJob
        case maxToolIterations
        case onToolLimit
        case clearToolBudget
        case watcherSource
        case rules
        case calendarLeadTimeMinutes
        case calendarNames
        case clearWatcher
        case clearRules
    }

    /// Creates an update payload.
    public init(
        name: String? = nil,
        schedule: String? = nil,
        prompt: String? = nil,
        enabled: Bool? = nil,
        pollAccount: String? = nil,
        pollQuery: String? = nil,
        pollContains: String? = nil,
        pollMailbox: String? = nil,
        pollIntervalSeconds: Int? = nil,
        pollLimit: Int? = nil,
        pollFrom: String? = nil,
        pollSubject: String? = nil,
        pollUnreadOnly: Bool? = nil,
        pollSinceDays: Int? = nil,
        clearPoll: Bool? = nil,
        emailReportJob: Bool? = nil,
        maxToolIterations: Int? = nil,
        onToolLimit: String? = nil,
        clearToolBudget: Bool? = nil,
        watcherSource: EventWatcherSource? = nil,
        rules: [EventRule]? = nil,
        calendarLeadTimeMinutes: Int? = nil,
        calendarNames: [String]? = nil,
        clearWatcher: Bool? = nil,
        clearRules: Bool? = nil
    ) {
        self.name = name
        self.schedule = schedule
        self.prompt = prompt
        self.enabled = enabled
        self.pollAccount = pollAccount
        self.pollQuery = pollQuery
        self.pollContains = pollContains
        self.pollMailbox = pollMailbox
        self.pollIntervalSeconds = pollIntervalSeconds
        self.pollLimit = pollLimit
        self.pollFrom = pollFrom
        self.pollSubject = pollSubject
        self.pollUnreadOnly = pollUnreadOnly
        self.pollSinceDays = pollSinceDays
        self.clearPoll = clearPoll
        self.emailReportJob = emailReportJob
        self.maxToolIterations = maxToolIterations
        self.onToolLimit = onToolLimit
        self.clearToolBudget = clearToolBudget
        self.watcherSource = watcherSource
        self.rules = rules
        self.calendarLeadTimeMinutes = calendarLeadTimeMinutes
        self.calendarNames = calendarNames
        self.clearWatcher = clearWatcher
        self.clearRules = clearRules
    }

    /// Decodes the payload accepting `pollContains`/`poll_contains` as aliases for `pollQuery`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        schedule = try container.decodeIfPresent(String.self, forKey: .schedule)
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
        pollAccount = try container.decodeIfPresent(String.self, forKey: .pollAccount)
        let directQuery = try container.decodeIfPresent(String.self, forKey: .pollQuery)
            ?? container.decodeIfPresent(String.self, forKey: .pollQuerySnake)
        let aliasContains = try container.decodeIfPresent(String.self, forKey: .pollContains)
            ?? container.decodeIfPresent(String.self, forKey: .pollContainsSnake)
        if directQuery != nil || aliasContains != nil {
            pollQuery = directQuery ?? aliasContains
            pollContains = aliasContains ?? directQuery
        } else {
            pollQuery = nil
            pollContains = nil
        }
        pollMailbox = try container.decodeIfPresent(String.self, forKey: .pollMailbox)
        pollIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .pollIntervalSeconds)
        pollLimit = try container.decodeIfPresent(Int.self, forKey: .pollLimit)
        pollFrom = try container.decodeIfPresent(String.self, forKey: .pollFrom)
        pollSubject = try container.decodeIfPresent(String.self, forKey: .pollSubject)
        pollUnreadOnly = try container.decodeIfPresent(Bool.self, forKey: .pollUnreadOnly)
        pollSinceDays = try container.decodeIfPresent(Int.self, forKey: .pollSinceDays)
        clearPoll = try container.decodeIfPresent(Bool.self, forKey: .clearPoll)
        emailReportJob = try container.decodeIfPresent(Bool.self, forKey: .emailReportJob)
        maxToolIterations = try container.decodeIfPresent(Int.self, forKey: .maxToolIterations)
        onToolLimit = try container.decodeIfPresent(String.self, forKey: .onToolLimit)
        clearToolBudget = try container.decodeIfPresent(Bool.self, forKey: .clearToolBudget)
        watcherSource = try container.decodeIfPresent(EventWatcherSource.self, forKey: .watcherSource)
        rules = try container.decodeIfPresent([EventRule].self, forKey: .rules)
        calendarLeadTimeMinutes = try container.decodeIfPresent(Int.self, forKey: .calendarLeadTimeMinutes)
        calendarNames = try container.decodeIfPresent([String].self, forKey: .calendarNames)
        clearWatcher = try container.decodeIfPresent(Bool.self, forKey: .clearWatcher)
        clearRules = try container.decodeIfPresent(Bool.self, forKey: .clearRules)
    }

    /// Encodes the payload mirroring `pollQuery` into `pollContains` for older readers.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(schedule, forKey: .schedule)
        try container.encodeIfPresent(prompt, forKey: .prompt)
        try container.encodeIfPresent(enabled, forKey: .enabled)
        try container.encodeIfPresent(pollAccount, forKey: .pollAccount)
        try container.encodeIfPresent(pollQuery, forKey: .pollQuery)
        let mirrored = pollContains ?? pollQuery
        try container.encodeIfPresent(mirrored, forKey: .pollContains)
        try container.encodeIfPresent(pollMailbox, forKey: .pollMailbox)
        try container.encodeIfPresent(pollIntervalSeconds, forKey: .pollIntervalSeconds)
        try container.encodeIfPresent(pollLimit, forKey: .pollLimit)
        try container.encodeIfPresent(pollFrom, forKey: .pollFrom)
        try container.encodeIfPresent(pollSubject, forKey: .pollSubject)
        try container.encodeIfPresent(pollUnreadOnly, forKey: .pollUnreadOnly)
        try container.encodeIfPresent(pollSinceDays, forKey: .pollSinceDays)
        try container.encodeIfPresent(clearPoll, forKey: .clearPoll)
        try container.encodeIfPresent(emailReportJob, forKey: .emailReportJob)
        try container.encodeIfPresent(maxToolIterations, forKey: .maxToolIterations)
        try container.encodeIfPresent(onToolLimit, forKey: .onToolLimit)
        try container.encodeIfPresent(clearToolBudget, forKey: .clearToolBudget)
        try container.encodeIfPresent(watcherSource, forKey: .watcherSource)
        try container.encodeIfPresent(rules, forKey: .rules)
        try container.encodeIfPresent(calendarLeadTimeMinutes, forKey: .calendarLeadTimeMinutes)
        try container.encodeIfPresent(calendarNames, forKey: .calendarNames)
        try container.encodeIfPresent(clearWatcher, forKey: .clearWatcher)
        try container.encodeIfPresent(clearRules, forKey: .clearRules)
    }
}

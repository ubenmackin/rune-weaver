// Rune Weaver Server — In-memory scheduler job registry and CRUD store.

import Foundation
import RuneWeaverCore

/// One scheduled job: a cron-like trigger and/or an email-arrival poll rule plus the prompt to run.
public struct SchedulerJob: Sendable, Codable, Equatable, Identifiable {
    /// Stable job identifier.
    public let id: UUID
    /// Human-readable job name (e.g. `"morning digest"`).
    public var name: String
    /// Cron-like schedule expression (empty for poll-only jobs).
    public var schedule: String
    /// Prompt executed when the job fires.
    public var prompt: String
    /// Whether the job fires. Disabled jobs are kept but never run.
    public var enabled: Bool
    /// Poll account nickname, when the job watches email arrival.
    public var pollAccount: String?
    /// Poll query for `email.search` (blank means most-recent).
    public var pollQuery: String?
    /// Contains alias mirroring `pollQuery` for the dashboard editor.
    public var pollContains: String?
    /// Poll mailbox (nil means every selectable mailbox).
    public var pollMailbox: String?
    /// Seconds between poll checks.
    public var pollIntervalSeconds: Int?
    /// Maximum hits fetched per poll (nil means `EmailPollRule/defaultLimit`).
    public var pollLimit: Int?
    /// Sender filter for `email.search` (nil means no sender scoping).
    public var pollFrom: String?
    /// Subject filter for `email.search` (nil means no subject scoping).
    public var pollSubject: String?
    /// Whether to restrict the poll to unread mail only.
    public var pollUnreadOnly: Bool = false
    /// Lookback days for `SINCE` scoping (nil means no date bound).
    public var pollSinceDays: Int?
    /// Owner-set flag marking this job as the owner of an email-report run cursor.
    public var emailReportJob: Bool
    /// Maximum tool iterations before limit policy triggers, or nil to inherit default.
    public var maxToolIterations: Int?
    /// Action when tool limit is reached: "fail" (synthesize & budget_exceeded) or "park". Defaults to "fail".
    public var onToolLimit: String?
    /// When the job was created.
    public var createdAt: Date
    /// When the job was last updated.
    public var updatedAt: Date
    /// Framework-owned end of the last successful run, if any.
    public var lastSuccessfulRunEndedAt: Date?
    /// Event watcher source (email, messages, or calendar), if configured.
    public var watcherSource: EventWatcherSource?
    /// Ordered event rules executed on incoming events.
    public var rules: [EventRule]?
    /// Lead time in minutes for calendar upcoming event trigger. Defaults to 15.
    public var calendarLeadTimeMinutes: Int?
    /// Calendar names to watch for calendar upcoming event trigger.
    public var calendarNames: [String]?
    /// Missed-schedule policy when a cron slot was missed while asleep or offline.
    public var misfirePolicy: SchedulerMisfirePolicy
    /// Most recent cron slot instant started for this job (prevents catch-up retries).
    public var lastScheduledSlotAt: Date?
    /// Earliest baseline instant considered for catch-up on creation or re-enable/schedule edit.
    public var scheduleAnchorAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id
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
        case createdAt
        case updatedAt
        case lastSuccessfulRunEndedAt
        case watcherSource
        case rules
        case calendarLeadTimeMinutes
        case calendarNames
        case misfirePolicy
        case misfirePolicySnake = "misfire_policy"
        case lastScheduledSlotAt
        case scheduleAnchorAt
    }

    /// Creates a scheduler job.
    public init(
        id: UUID = UUID(),
        name: String,
        schedule: String,
        prompt: String,
        enabled: Bool = true,
        pollAccount: String? = nil,
        pollQuery: String? = nil,
        pollContains: String? = nil,
        pollMailbox: String? = nil,
        pollIntervalSeconds: Int? = nil,
        pollLimit: Int? = nil,
        pollFrom: String? = nil,
        pollSubject: String? = nil,
        pollUnreadOnly: Bool = false,
        pollSinceDays: Int? = nil,
        emailReportJob: Bool = false,
        maxToolIterations: Int? = nil,
        onToolLimit: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastSuccessfulRunEndedAt: Date? = nil,
        watcherSource: EventWatcherSource? = nil,
        rules: [EventRule]? = nil,
        calendarLeadTimeMinutes: Int? = nil,
        calendarNames: [String]? = nil,
        misfirePolicy: SchedulerMisfirePolicy = .strict,
        lastScheduledSlotAt: Date? = nil,
        scheduleAnchorAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.schedule = schedule
        self.prompt = prompt
        self.enabled = enabled
        self.pollAccount = pollAccount
        let resolvedQuery = pollQuery ?? pollContains
        self.pollQuery = resolvedQuery
        self.pollContains = pollContains ?? pollQuery
        self.pollMailbox = pollMailbox
        self.pollIntervalSeconds = pollIntervalSeconds
        self.pollLimit = pollLimit.map(EmailPollRule.clampedLimit)
        self.pollFrom = pollFrom
        self.pollSubject = pollSubject
        self.pollUnreadOnly = pollUnreadOnly
        self.pollSinceDays = pollSinceDays
        self.emailReportJob = emailReportJob
        self.maxToolIterations = maxToolIterations
        self.onToolLimit = onToolLimit
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastSuccessfulRunEndedAt = lastSuccessfulRunEndedAt
        self.watcherSource = watcherSource
        self.rules = rules
        self.calendarLeadTimeMinutes = calendarLeadTimeMinutes
        self.calendarNames = calendarNames
        self.misfirePolicy = misfirePolicy
        self.lastScheduledSlotAt = lastScheduledSlotAt
        self.scheduleAnchorAt = scheduleAnchorAt
    }

    /// Decodes a job accepting `pollContains`/`poll_contains` as aliases for `pollQuery`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        schedule = try container.decode(String.self, forKey: .schedule)
        prompt = try container.decode(String.self, forKey: .prompt)
        enabled = try container.decode(Bool.self, forKey: .enabled)
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
        pollUnreadOnly = try container.decodeIfPresent(Bool.self, forKey: .pollUnreadOnly) ?? false
        pollSinceDays = try container.decodeIfPresent(Int.self, forKey: .pollSinceDays)
        emailReportJob = try container.decodeIfPresent(Bool.self, forKey: .emailReportJob) ?? false
        maxToolIterations = try container.decodeIfPresent(Int.self, forKey: .maxToolIterations)
        onToolLimit = try container.decodeIfPresent(String.self, forKey: .onToolLimit)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        lastSuccessfulRunEndedAt = try container.decodeIfPresent(Date.self, forKey: .lastSuccessfulRunEndedAt)
        watcherSource = try container.decodeIfPresent(EventWatcherSource.self, forKey: .watcherSource)
        rules = try container.decodeIfPresent([EventRule].self, forKey: .rules)
        calendarLeadTimeMinutes = try container.decodeIfPresent(Int.self, forKey: .calendarLeadTimeMinutes)
        calendarNames = try container.decodeIfPresent([String].self, forKey: .calendarNames)
        let rawMisfire = try container.decodeIfPresent(String.self, forKey: .misfirePolicy)
            ?? container.decodeIfPresent(String.self, forKey: .misfirePolicySnake)
        misfirePolicy = rawMisfire.flatMap { SchedulerMisfirePolicy.parseStrict($0) } ?? .strict
        lastScheduledSlotAt = try container.decodeIfPresent(Date.self, forKey: .lastScheduledSlotAt)
        scheduleAnchorAt = try container.decodeIfPresent(Date.self, forKey: .scheduleAnchorAt)
    }

    /// Encodes a job mirroring `pollQuery` into `pollContains` for older readers.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(schedule, forKey: .schedule)
        try container.encode(prompt, forKey: .prompt)
        try container.encode(enabled, forKey: .enabled)
        try container.encodeIfPresent(pollAccount, forKey: .pollAccount)
        try container.encodeIfPresent(pollQuery, forKey: .pollQuery)
        try container.encodeIfPresent(pollContains ?? pollQuery, forKey: .pollContains)
        try container.encodeIfPresent(pollMailbox, forKey: .pollMailbox)
        try container.encodeIfPresent(pollIntervalSeconds, forKey: .pollIntervalSeconds)
        try container.encodeIfPresent(pollLimit, forKey: .pollLimit)
        try container.encodeIfPresent(pollFrom, forKey: .pollFrom)
        try container.encodeIfPresent(pollSubject, forKey: .pollSubject)
        try container.encode(pollUnreadOnly, forKey: .pollUnreadOnly)
        try container.encodeIfPresent(pollSinceDays, forKey: .pollSinceDays)
        try container.encode(emailReportJob, forKey: .emailReportJob)
        try container.encodeIfPresent(maxToolIterations, forKey: .maxToolIterations)
        try container.encodeIfPresent(onToolLimit, forKey: .onToolLimit)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(lastSuccessfulRunEndedAt, forKey: .lastSuccessfulRunEndedAt)
        try container.encodeIfPresent(watcherSource, forKey: .watcherSource)
        try container.encodeIfPresent(rules, forKey: .rules)
        try container.encodeIfPresent(calendarLeadTimeMinutes, forKey: .calendarLeadTimeMinutes)
        try container.encodeIfPresent(calendarNames, forKey: .calendarNames)
        try container.encode(misfirePolicy, forKey: .misfirePolicy)
        try container.encodeIfPresent(lastScheduledSlotAt, forKey: .lastScheduledSlotAt)
        try container.encodeIfPresent(scheduleAnchorAt, forKey: .scheduleAnchorAt)
    }

    /// Whether the job has a cron trigger.
    public var hasCronTrigger: Bool {
        !schedule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether the job has a poll trigger.
    public var hasPollTrigger: Bool {
        guard let account = pollAccount else { return false }
        return !account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether the job is an event watcher.
    public var isEventWatcher: Bool {
        watcherSource != nil || hasPollTrigger
    }

    /// Email poll rule for this job, when configured.
    public var pollRule: EmailPollRule? {
        EmailPollRule.ruleForStoredFields(
            pollAccount: pollAccount,
            pollQuery: pollQuery ?? pollContains,
            pollMailbox: pollMailbox,
            pollIntervalSeconds: pollIntervalSeconds,
            pollLimit: pollLimit,
            pollFrom: pollFrom,
            pollSubject: pollSubject,
            pollUnreadOnly: pollUnreadOnly,
            pollSinceDays: pollSinceDays
        )
    }
}

// Scheduler job payloads live in `SchedulerJobPayloads.swift` beside this store.

/// Failures raised by ``SchedulerStore`` validation.
public enum SchedulerStoreError: Error, Sendable, Equatable {
    /// A required field was blank.
    case invalidField(String)
    /// No job exists with the given identifier.
    case unknownJob(String)
}

/// In-memory CRUD store for scheduler jobs backed by SQLite persistence.
public actor SchedulerStore {
    /// Maximum jobs kept in the store to bound memory and avoid unbounded resource consumption.
    public static let maxJobs = 100
    /// Maximum scheduled sends kept pending (queued or sending) at once.
    public static let maxPendingSends = 200

    /// Jobs indexed by identifier.
    var jobs: [UUID: SchedulerJob] = [:]
    /// Approved scheduled sends awaiting deterministic replay, indexed by
    /// identifier; owned by `SchedulerStoreScheduledSends.swift` beside the
    /// job registry so one actor holds both.
    var scheduledSends: [UUID: ScheduledSend] = [:]
    /// Optional filesystem path for SQLite persistence.
    public let dbPath: String?

    /// Creates an empty store.
    /// - Parameter dbPath: Optional SQLite path for durable persistence.
    public init(dbPath: String? = nil) {
        self.init(from: .empty, dbPath: dbPath)
    }

    /// Creates a job from a REST payload.
    @discardableResult
    public func create(_ input: NewSchedulerJob) async throws -> SchedulerJob {
        guard jobs.count < Self.maxJobs else {
            throw SchedulerStoreError.invalidField("Job limit reached (\(Self.maxJobs)). Delete existing jobs before creating new ones.")
        }
        let normalizedAccount = Self.normalizedOptional(input.pollAccount)
        let normalizedQuery = Self.normalizedOptional(input.pollQuery) ?? Self.normalizedOptional(input.pollContains)
        let normalizedMailbox = Self.normalizedOptional(input.pollMailbox)
        let normalizedOnToolLimit = Self.normalizedOptional(input.onToolLimit)
        let normalizedFrom = Self.normalizedOptional(input.pollFrom)
        let normalizedSubject = Self.normalizedOptional(input.pollSubject)
        try Self.validated(
            name: input.name,
            schedule: input.schedule,
            prompt: input.prompt,
            pollAccount: normalizedAccount,
            pollQuery: normalizedQuery,
            pollContains: Self.normalizedOptional(input.pollContains),
            pollMailbox: normalizedMailbox,
            pollIntervalSeconds: input.pollIntervalSeconds,
            pollLimit: input.pollLimit,
            pollFrom: input.pollFrom,
            pollSubject: input.pollSubject,
            pollUnreadOnly: input.pollUnreadOnly,
            pollSinceDays: input.pollSinceDays,
            maxToolIterations: input.maxToolIterations,
            onToolLimit: normalizedOnToolLimit,
            watcherSource: input.watcherSource,
            rules: input.rules,
            calendarLeadTimeMinutes: input.calendarLeadTimeMinutes,
            calendarNames: input.calendarNames,
            misfirePolicy: input.misfirePolicy
        )
        let resolvedMisfirePolicy = input.misfirePolicy.flatMap { SchedulerMisfirePolicy.parseStrict($0) } ?? .strict
        let trimmedName = normalizedSchedulerJobName(input.name)
        if jobs.values.contains(where: { $0.name == trimmedName }) {
            throw SchedulerStoreError.invalidField("job name '\(trimmedName)' already exists")
        }
        let now = Date()
        let job = SchedulerJob(
            name: trimmedName,
            schedule: input.schedule.trimmingCharacters(in: .whitespacesAndNewlines),
            prompt: input.prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            enabled: input.enabled ?? true,
            pollAccount: normalizedAccount,
            pollQuery: normalizedQuery,
            pollMailbox: normalizedMailbox,
            pollIntervalSeconds: input.pollIntervalSeconds,
            pollLimit: input.pollLimit.map(EmailPollRule.clampedLimit),
            pollFrom: normalizedFrom,
            pollSubject: normalizedSubject,
            pollUnreadOnly: input.pollUnreadOnly ?? false,
            pollSinceDays: input.pollSinceDays,
            emailReportJob: input.emailReportJob ?? false,
            maxToolIterations: input.maxToolIterations,
            onToolLimit: normalizedOnToolLimit,
            createdAt: now,
            updatedAt: now,
            watcherSource: input.watcherSource,
            rules: input.rules,
            calendarLeadTimeMinutes: input.calendarLeadTimeMinutes,
            calendarNames: input.calendarNames,
            misfirePolicy: resolvedMisfirePolicy,
            scheduleAnchorAt: now
        )
        jobs[job.id] = job
        if let dbPath {
            #if canImport(SQLite3)
                await SQLiteSerialIO.runUncancellable {
                    SQLiteSchedulerJobStore.write(job: job, dbPath: dbPath)
                }
            #endif
        }
        return job
    }

    /// Lists every job, oldest first.
    public func list() async -> [SchedulerJob] {
        jobs.values.sorted { $0.createdAt < $1.createdAt }
    }

    /// Looks up one job.
    public func job(id: UUID) async -> SchedulerJob? {
        jobs[id]
    }

    /// Updates one job, touching `updatedAt` on change.
    @discardableResult
    public func update(id: UUID, _ input: UpdateSchedulerJob) async throws -> SchedulerJob {
        guard var existing = jobs[id] else {
            throw SchedulerStoreError.unknownJob(id.uuidString)
        }
        if let name = input.name {
            guard !normalizedSchedulerJobName(name).isEmpty else {
                throw SchedulerStoreError.invalidField("name must not be empty")
            }
            let trimmedName = normalizedSchedulerJobName(name)
            if trimmedName != existing.name,
               jobs.values.contains(where: { $0.id != id && $0.name == trimmedName })
            {
                throw SchedulerStoreError.invalidField("job name '\(trimmedName)' already exists")
            }
            existing.name = trimmedName
        }
        let wasEnabled = existing.enabled
        let previousSchedule = existing.schedule
        let previousPolicy = existing.misfirePolicy
        let resolvedUpdateMisfireRaw: String? = input.misfirePolicy.map { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? SchedulerMisfirePolicy.strict.rawValue : trimmed
        }
        Self.applyUpdates(to: &existing, from: input)
        try Self.validated(
            name: existing.name,
            schedule: existing.schedule,
            prompt: existing.prompt,
            pollAccount: existing.pollAccount,
            pollQuery: existing.pollQuery,
            pollContains: existing.pollContains,
            pollMailbox: existing.pollMailbox,
            pollIntervalSeconds: existing.pollIntervalSeconds,
            pollLimit: existing.pollLimit,
            pollFrom: existing.pollFrom,
            pollSubject: existing.pollSubject,
            pollUnreadOnly: existing.pollUnreadOnly,
            pollSinceDays: existing.pollSinceDays,
            maxToolIterations: existing.maxToolIterations,
            onToolLimit: existing.onToolLimit,
            watcherSource: existing.watcherSource,
            rules: existing.rules,
            calendarLeadTimeMinutes: existing.calendarLeadTimeMinutes,
            calendarNames: existing.calendarNames,
            misfirePolicy: resolvedUpdateMisfireRaw ?? existing.misfirePolicy.rawValue
        )
        if let resolvedUpdateMisfireRaw,
           let parsedPolicy = SchedulerMisfirePolicy.parseStrict(resolvedUpdateMisfireRaw)
        {
            existing.misfirePolicy = parsedPolicy
        }
        let now = Date()
        if (!wasEnabled && existing.enabled)
            || existing.schedule != previousSchedule
            || (previousPolicy != .catchUp && existing.misfirePolicy == .catchUp)
        {
            existing.scheduleAnchorAt = now
        }
        existing.updatedAt = now
        let updatedJob = existing
        jobs[id] = updatedJob
        if let dbPath {
            #if canImport(SQLite3)
                await SQLiteSerialIO.runUncancellable {
                    SQLiteSchedulerJobStore.write(job: updatedJob, dbPath: dbPath)
                }
            #endif
        }
        return updatedJob
    }

    private static func applyUpdates(to existing: inout SchedulerJob, from input: UpdateSchedulerJob) {
        applyCoreFields(to: &existing, from: input)
        applyPollFields(to: &existing, from: input)
        applyBudgetFields(to: &existing, from: input)
        applyWatcherFields(to: &existing, from: input)
    }

    /// Schedule plus prompt plus enabled state.
    private static func applyCoreFields(to existing: inout SchedulerJob, from input: UpdateSchedulerJob) {
        if let schedule = input.schedule {
            existing.schedule = schedule.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let prompt = input.prompt {
            existing.prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let enabled = input.enabled {
            existing.enabled = enabled
        }
        if let emailReportJob = input.emailReportJob {
            existing.emailReportJob = emailReportJob
        }
    }

    /// Poll trigger fields plus the clear-poll reset.
    private static func applyPollFields(to existing: inout SchedulerJob, from input: UpdateSchedulerJob) {
        if input.clearPoll == true {
            existing.pollAccount = nil
            existing.pollQuery = nil
            existing.pollContains = nil
            existing.pollMailbox = nil
            existing.pollIntervalSeconds = nil
            existing.pollLimit = nil
            existing.pollFrom = nil
            existing.pollSubject = nil
            existing.pollUnreadOnly = false
            existing.pollSinceDays = nil
        }
        if let pollAccount = input.pollAccount {
            existing.pollAccount = normalizedOptional(pollAccount)
        }
        // `pollContains` aliases `pollQuery` so dashboard saves stay filtering
        // on the same text even when only one spelling arrives.
        if let pollQuery = input.pollQuery ?? input.pollContains {
            let normalized = normalizedOptional(pollQuery)
            existing.pollQuery = normalized
            existing.pollContains = normalized
        } else if input.pollQuery != nil || input.pollContains != nil {
            existing.pollQuery = nil
            existing.pollContains = nil
        }
        if let pollMailbox = input.pollMailbox {
            existing.pollMailbox = normalizedOptional(pollMailbox)
        }
        if let interval = input.pollIntervalSeconds {
            existing.pollIntervalSeconds = interval
        }
        if let limit = input.pollLimit {
            existing.pollLimit = EmailPollRule.clampedLimit(limit)
        }
        applyPollTextFields(to: &existing, from: input)
    }

    /// Sender plus subject plus flags for poll filters.
    private static func applyPollTextFields(to existing: inout SchedulerJob, from input: UpdateSchedulerJob) {
        if let pollFrom = input.pollFrom {
            existing.pollFrom = normalizedOptional(pollFrom)
        }
        if let pollSubject = input.pollSubject {
            existing.pollSubject = normalizedOptional(pollSubject)
        }
        if let pollUnreadOnly = input.pollUnreadOnly {
            existing.pollUnreadOnly = pollUnreadOnly
        }
        if let pollSinceDays = input.pollSinceDays {
            existing.pollSinceDays = pollSinceDays
        }
    }

    /// Tool budget fields plus the clear-budget reset.
    private static func applyBudgetFields(to existing: inout SchedulerJob, from input: UpdateSchedulerJob) {
        if input.clearToolBudget == true {
            existing.maxToolIterations = nil
            existing.onToolLimit = nil
        }
        if let maxToolIterations = input.maxToolIterations {
            existing.maxToolIterations = maxToolIterations
        }
        if let onToolLimit = input.onToolLimit {
            existing.onToolLimit = normalizedOptional(onToolLimit)
        }
    }

    /// Watcher source plus rules plus calendar details.
    private static func applyWatcherFields(to existing: inout SchedulerJob, from input: UpdateSchedulerJob) {
        if input.clearWatcher == true {
            existing.watcherSource = nil
            existing.calendarLeadTimeMinutes = nil
            existing.calendarNames = nil
        }
        if input.clearRules == true {
            existing.rules = nil
        }
        if let watcherSource = input.watcherSource {
            existing.watcherSource = watcherSource
        }
        if let rules = input.rules {
            existing.rules = rules
        }
        if let calendarLeadTime = input.calendarLeadTimeMinutes {
            existing.calendarLeadTimeMinutes = calendarLeadTime
        }
        if let calendarNames = input.calendarNames {
            existing.calendarNames = calendarNames
        }
    }

    /// Deletes one job. Unknown identifiers are a no-op.
    /// - Parameter id: Job identifier.
    /// - Returns: True when a job was removed.
    @discardableResult
    public func delete(id: UUID) async -> Bool {
        let removed = jobs.removeValue(forKey: id) != nil
        if removed, let dbPath {
            #if canImport(SQLite3)
                await SQLiteSerialIO.runUncancellable {
                    SQLiteSchedulerJobStore.delete(id: id, dbPath: dbPath)
                }
            #endif
        }
        return removed
    }

    /// Removes every job.
    public func clear() async {
        jobs.removeAll()
        if let dbPath {
            #if canImport(SQLite3)
                await SQLiteSerialIO.runUncancellable {
                    SQLiteSchedulerJobStore.clear(dbPath: dbPath)
                }
            #endif
        }
    }

    /// Number of stored jobs.
    public func count() async -> Int {
        jobs.count
    }

    /// Records the end of a successful run, advancing the framework-owned cursor.
    public func recordSuccessfulRun(id: UUID, endedAt: Date = Date()) async {
        guard var existing = jobs[id] else { return }
        existing.lastSuccessfulRunEndedAt = endedAt
        existing.updatedAt = endedAt
        jobs[id] = existing
        if let dbPath {
            #if canImport(SQLite3)
                let jobToWrite = existing
                await SQLiteSerialIO.runUncancellable {
                    SQLiteSchedulerJobStore.write(job: jobToWrite, dbPath: dbPath)
                }
            #endif
        }
    }

    /// Creates a store seeded from configuration without touching disk.
    public init(from config: SchedulerConfig = .empty, dbPath: String? = nil) {
        self.dbPath = dbPath
        self.jobs = Self.seedInMemory(from: config)
    }

    /// Loads a store hydrated from durable SQLite state.
    public static func load(from config: SchedulerConfig = .empty, dbPath: String? = nil) async -> SchedulerStore {
        let store = SchedulerStore(dbPath: dbPath)
        await store.bootstrap(from: config)
        return store
    }

    /// Hydrates runtime state from durable SQLite state.
    public func bootstrap(from config: SchedulerConfig) async {
        guard let dbPath else {
            jobs = Self.seedInMemory(from: config)
            return
        }
        #if canImport(SQLite3)
            // Sends reload first so a boot that fails reading jobs still
            // reports the whole persisted picture.
            await bootstrapScheduledSends()
            let existing: [SchedulerJob]
            do {
                existing = try await SQLiteSerialIO.run {
                    SQLiteSchedulerJobStore.read(dbPath: dbPath)
                }
            } catch {
                RuneWeaverLog.stores.error("SchedulerStore: failed reading jobs from SQLite: \(error.localizedDescription)")
                existing = []
            }
            if !existing.isEmpty {
                // Durable state wins over the config seed: replace the registry
                // so a store seeded in memory plus a later bootstrap never
                // reports a seed-plus-database union.
                jobs = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
                return
            }
            let seeded = Self.seedInMemory(from: config)
            jobs = seeded
            for job in seeded.values {
                await SQLiteSerialIO.runUncancellable {
                    SQLiteSchedulerJobStore.write(job: job, dbPath: dbPath)
                }
            }
        #else
            jobs = Self.seedInMemory(from: config)
        #endif
    }
}

extension SchedulerJob {
    /// Creates a runtime job from a `config.toml` entry.
    public init(from config: SchedulerJobConfig, id: UUID = UUID(), createdAt: Date = Date(), updatedAt: Date = Date()) {
        let trimmedName = normalizedSchedulerJobName(config.name)
        let schedule = EmailPollRule.storedSchedule(from: config.schedule)
        let rawQuery = config.poll?.query.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawFrom = config.poll?.from.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawSubject = config.poll?.subject.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.init(
            id: id,
            name: trimmedName,
            schedule: schedule,
            prompt: config.prompt,
            enabled: config.enabled,
            pollAccount: config.poll?.trimmedAccount.isEmpty == false ? config.poll?.trimmedAccount : nil,
            pollQuery: rawQuery.isEmpty ? nil : config.poll?.query.trimmingCharacters(in: .whitespacesAndNewlines),
            pollMailbox: config.poll?.trimmedMailbox,
            pollIntervalSeconds: config.poll?.pollIntervalSeconds,
            pollLimit: config.poll?.limit,
            pollFrom: rawFrom.isEmpty ? nil : rawFrom,
            pollSubject: rawSubject.isEmpty ? nil : rawSubject,
            pollUnreadOnly: config.poll?.unreadOnly ?? false,
            pollSinceDays: config.poll?.sinceDays,
            maxToolIterations: config.maxToolIterations,
            onToolLimit: config.onToolLimit,
            createdAt: createdAt,
            updatedAt: updatedAt,
            watcherSource: config.watcherSource,
            rules: config.rules,
            calendarLeadTimeMinutes: config.calendarLeadTimeMinutes,
            calendarNames: config.calendarNames,
            misfirePolicy: config.misfirePolicy ?? .strict,
            scheduleAnchorAt: createdAt
        )
    }
}

// SQLite persistence and cron-slot tracking live in `SchedulerStoreCronTracking.swift`.

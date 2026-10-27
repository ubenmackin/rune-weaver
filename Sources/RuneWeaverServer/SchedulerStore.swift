// Rune Weaver Server — In-memory scheduler job registry and CRUD store.

import Foundation
import RuneWeaverCore
#if canImport(SQLite3)
    import SQLite3
#endif

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
        calendarNames: [String]? = nil
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
            calendarNames: input.calendarNames
        )
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
            calendarNames: input.calendarNames
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
            calendarNames: existing.calendarNames
        )
        existing.updatedAt = Date()
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

    /// Replaces the runtime registry with `config.toml [[scheduler.jobs]]`.
    public func sync(from config: SchedulerConfig) {
        var byName: [String: SchedulerJob] = [:]
        for job in jobs.values {
            let key = normalizedSchedulerJobName(job.name)
            if byName[key] == nil {
                byName[key] = job
            }
        }
        var seen: Set<String> = []
        var fresh: [UUID: SchedulerJob] = [:]
        for entry in config.jobs {
            let trimmedName = normalizedSchedulerJobName(entry.name)
            guard !seen.contains(trimmedName) else { continue }
            seen.insert(trimmedName)
            if let existing = byName[trimmedName] {
                var kept = SchedulerJob(from: entry, id: existing.id, createdAt: existing.createdAt)
                kept.updatedAt = Date()
                kept.lastSuccessfulRunEndedAt = existing.lastSuccessfulRunEndedAt
                // The email-report flag is owner state with no config spelling,
                // so a resync carries it forward like the run cursor.
                kept.emailReportJob = existing.emailReportJob
                fresh[kept.id] = kept
            } else {
                let job = SchedulerJob(from: entry)
                fresh[job.id] = job
            }
        }
        jobs = fresh
    }

    /// Exports the runtime registry as a config section for persistence.
    public func toSchedulerConfig() async -> SchedulerConfig {
        await SchedulerConfig(jobs: list().map { $0.toJobConfig() })
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
            calendarNames: config.calendarNames
        )
    }

    /// Converts this runtime job to a `config.toml` entry.
    public func toJobConfig() -> SchedulerJobConfig {
        let scheduleValue: String? = EmailPollRule.configSchedule(from: schedule)
        let pollValue: EmailPollRule? = pollRule
        return SchedulerJobConfig(
            name: name,
            prompt: prompt,
            enabled: enabled,
            schedule: scheduleValue,
            poll: pollValue,
            maxToolIterations: maxToolIterations,
            onToolLimit: onToolLimit,
            watcherSource: watcherSource,
            rules: rules,
            calendarLeadTimeMinutes: calendarLeadTimeMinutes,
            calendarNames: calendarNames
        )
    }
}

extension SchedulerJobConfig {
    /// Creates a config entry from a runtime job.
    public init(from job: SchedulerJob) {
        self = job.toJobConfig()
    }
}

#if canImport(SQLite3)
    /// Internal SQLite helper for durable scheduler job persistence.
    enum SQLiteSchedulerJobStore {
        private struct SchedulerDBError: Error {
            let message: String
        }

        private static func open(dbPath: String) throws -> OpaquePointer? {
            // Shared busy_timeout/WAL policy lives in `SQLiteHelpers.openHandle`.
            let handle = try SQLiteHelpers.openHandle(dbPath: dbPath, unavailable: { SchedulerDBError(message: $0) })
            try SQLiteHelpers.exec(
                handle: handle,
                sql: """
                CREATE TABLE IF NOT EXISTS scheduler_jobs(
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL UNIQUE,
                    schedule TEXT NOT NULL,
                    prompt TEXT NOT NULL,
                    enabled INTEGER NOT NULL,
                    poll_account TEXT,
                    poll_query TEXT,
                    poll_mailbox TEXT,
                    poll_interval_seconds INTEGER,
                    poll_limit INTEGER,
                    poll_from TEXT,
                    poll_subject TEXT,
                    poll_unread_only INTEGER,
                    poll_since_days INTEGER,
                    max_tool_iterations INTEGER,
                    on_tool_limit TEXT,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    last_successful_run_ended_at REAL,
                    email_report_job INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX IF NOT EXISTS idx_scheduler_jobs_name ON scheduler_jobs(name);
                """,
                failure: { SchedulerDBError(message: $0) }
            )
            _ = try? SQLiteHelpers.exec(
                handle: handle,
                sql: "ALTER TABLE scheduler_jobs ADD COLUMN max_tool_iterations INTEGER;",
                failure: { SchedulerDBError(message: $0) }
            )
            _ = try? SQLiteHelpers.exec(
                handle: handle,
                sql: "ALTER TABLE scheduler_jobs ADD COLUMN on_tool_limit TEXT;",
                failure: { SchedulerDBError(message: $0) }
            )
            _ = try? SQLiteHelpers.exec(
                handle: handle,
                sql: "ALTER TABLE scheduler_jobs ADD COLUMN last_successful_run_ended_at REAL;",
                failure: { SchedulerDBError(message: $0) }
            )
            _ = try? SQLiteHelpers.exec(
                handle: handle,
                sql: "ALTER TABLE scheduler_jobs ADD COLUMN email_report_job INTEGER NOT NULL DEFAULT 0;",
                failure: { SchedulerDBError(message: $0) }
            )
            _ = try? SQLiteHelpers.exec(
                handle: handle,
                sql: "ALTER TABLE scheduler_jobs ADD COLUMN poll_from TEXT;",
                failure: { SchedulerDBError(message: $0) }
            )
            _ = try? SQLiteHelpers.exec(
                handle: handle,
                sql: "ALTER TABLE scheduler_jobs ADD COLUMN poll_subject TEXT;",
                failure: { SchedulerDBError(message: $0) }
            )
            _ = try? SQLiteHelpers.exec(
                handle: handle,
                sql: "ALTER TABLE scheduler_jobs ADD COLUMN poll_unread_only INTEGER;",
                failure: { SchedulerDBError(message: $0) }
            )
            _ = try? SQLiteHelpers.exec(
                handle: handle,
                sql: "ALTER TABLE scheduler_jobs ADD COLUMN poll_since_days INTEGER;",
                failure: { SchedulerDBError(message: $0) }
            )
            // Watcher columns delegate to the Core-owned statement list so the
            // additive migrations stay identical across persistence sites.
            SchedulerJobConfig.applyWatcherColumnMigrations { statement in
                _ = try? SQLiteHelpers.exec(
                    handle: handle,
                    sql: statement,
                    failure: { SchedulerDBError(message: $0) }
                )
            }
            return handle
        }

        static func read(dbPath: String) -> [SchedulerJob] {
            guard let handle = SQLiteOpenHelper.openLogged(
                dbPath: dbPath,
                storeName: "SQLiteSchedulerJobStore",
                fallbackNote: "read returning in-memory state only",
                open: { try open(dbPath: dbPath) }
            ) else {
                return []
            }
            defer { sqlite3_close(handle) }

            let sql = """
            SELECT id, name, schedule, prompt, enabled, poll_account, poll_query, poll_mailbox,
                   poll_interval_seconds, poll_limit, max_tool_iterations, on_tool_limit,
                   created_at, updated_at, last_successful_run_ended_at, email_report_job,
                   watcher_source, rules, calendar_lead_time_minutes, calendar_names,
                   poll_from, poll_subject, poll_unread_only, poll_since_days
            FROM scheduler_jobs
            ORDER BY created_at ASC;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                return []
            }
            defer { sqlite3_finalize(statement) }

            var loaded: [SchedulerJob] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let idStr = SQLiteHelpers.columnText(statement, index: 0),
                      let id = UUID(uuidString: idStr),
                      let row = SchedulerJobRow.decode(statement, base: 1)
                else { continue }

                let createdAt = Date(timeIntervalSince1970: SQLiteHelpers.columnDouble(statement, index: 12))
                let updatedAt = Date(timeIntervalSince1970: SQLiteHelpers.columnDouble(statement, index: 13))
                let cursor: Date?
                if sqlite3_column_type(statement, 14) == SQLITE_NULL {
                    cursor = nil
                } else {
                    let value = SQLiteHelpers.columnDouble(statement, index: 14)
                    cursor = value == 0 ? nil : Date(timeIntervalSince1970: value)
                }
                // Rows written before the email-report flag existed decode as
                // false, matching the column default.
                let emailReportJob = (SQLiteHelpers.columnInt64(statement, index: 15) ?? 0) != 0
                let watcherRaw = SQLiteHelpers.columnText(statement, index: 16)
                let watcherSource = watcherRaw.flatMap { EventWatcherSource(rawValue: $0) }
                let rulesRaw = SQLiteHelpers.columnText(statement, index: 17)
                let rules: [EventRule]? = rulesRaw.flatMap { json in
                    guard let data = json.data(using: .utf8) else { return nil }
                    return try? JSONDecoder().decode([EventRule].self, from: data)
                }
                let leadTime = SQLiteHelpers.columnInt64(statement, index: 18).map { Int($0) }
                let calNamesRaw = SQLiteHelpers.columnText(statement, index: 19)
                let calendarNames: [String]? = calNamesRaw.flatMap { json in
                    guard let data = json.data(using: .utf8) else { return nil }
                    return try? JSONDecoder().decode([String].self, from: data)
                }
                // Blank strings predate normalization; folding them keeps
                // legacy rows equivalent to omitted structured filters.
                let rawFrom = SQLiteHelpers.columnText(statement, index: 20)
                let rawSubject = SQLiteHelpers.columnText(statement, index: 21)
                let normalizedFrom: String? = {
                    guard let raw = rawFrom else { return nil }
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }()
                let normalizedSubject: String? = {
                    guard let raw = rawSubject else { return nil }
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }()
                let unreadOnly = (SQLiteHelpers.columnInt64(statement, index: 22) ?? 0) != 0
                let sinceDays = SQLiteHelpers.columnInt64(statement, index: 23).map { Int($0) }

                loaded.append(SchedulerJob(
                    id: id,
                    name: row.name,
                    schedule: row.schedule,
                    prompt: row.prompt,
                    enabled: row.enabled,
                    pollAccount: row.pollAccount,
                    pollQuery: row.pollQuery,
                    pollMailbox: row.pollMailbox,
                    pollIntervalSeconds: row.pollIntervalSeconds,
                    pollLimit: row.pollLimit,
                    pollFrom: normalizedFrom,
                    pollSubject: normalizedSubject,
                    pollUnreadOnly: unreadOnly,
                    pollSinceDays: sinceDays,
                    emailReportJob: emailReportJob,
                    maxToolIterations: row.maxToolIterations,
                    onToolLimit: row.onToolLimit,
                    createdAt: createdAt,
                    updatedAt: updatedAt,
                    lastSuccessfulRunEndedAt: cursor,
                    watcherSource: watcherSource,
                    rules: rules,
                    calendarLeadTimeMinutes: leadTime,
                    calendarNames: calendarNames
                ))
            }
            return loaded
        }

        static func write(job: SchedulerJob, dbPath: String) {
            guard let handle = SQLiteOpenHelper.openLogged(
                dbPath: dbPath,
                storeName: "SQLiteSchedulerJobStore",
                fallbackNote: "job \(job.id) kept in memory only and will not survive restart",
                open: { try open(dbPath: dbPath) }
            ) else {
                return
            }
            defer { sqlite3_close(handle) }

            let sql = """
            INSERT INTO scheduler_jobs(
                id, name, schedule, prompt, enabled, poll_account, poll_query,
                poll_mailbox, poll_interval_seconds, poll_limit, max_tool_iterations, on_tool_limit, created_at, updated_at,
                last_successful_run_ended_at, email_report_job, watcher_source, rules, calendar_lead_time_minutes, calendar_names,
                poll_from, poll_subject, poll_unread_only, poll_since_days
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                schedule = excluded.schedule,
                prompt = excluded.prompt,
                enabled = excluded.enabled,
                poll_account = excluded.poll_account,
                poll_query = excluded.poll_query,
                poll_mailbox = excluded.poll_mailbox,
                poll_interval_seconds = excluded.poll_interval_seconds,
                poll_limit = excluded.poll_limit,
                max_tool_iterations = excluded.max_tool_iterations,
                on_tool_limit = excluded.on_tool_limit,
                updated_at = excluded.updated_at,
                last_successful_run_ended_at = excluded.last_successful_run_ended_at,
                email_report_job = excluded.email_report_job,
                watcher_source = excluded.watcher_source,
                rules = excluded.rules,
                calendar_lead_time_minutes = excluded.calendar_lead_time_minutes,
                calendar_names = excluded.calendar_names,
                poll_from = excluded.poll_from,
                poll_subject = excluded.poll_subject,
                poll_unread_only = excluded.poll_unread_only,
                poll_since_days = excluded.poll_since_days;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                let code = sqlite3_errcode(handle)
                RuneWeaverLog.stores.error("SQLiteSchedulerJobStore: failed preparing job write (code \(code)); job \(job.id) kept in memory only.")
                return
            }
            defer { sqlite3_finalize(statement) }

            SQLiteHelpers.bindText(statement, index: 1, value: job.id.uuidString)
            SQLiteHelpers.bindText(statement, index: 2, value: job.name)
            SQLiteHelpers.bindText(statement, index: 3, value: job.schedule)
            SQLiteHelpers.bindText(statement, index: 4, value: job.prompt)
            SQLiteHelpers.bindInt64(statement, index: 5, value: job.enabled ? 1 : 0)
            SQLiteHelpers.bindText(statement, index: 6, value: job.pollAccount)
            SQLiteHelpers.bindText(statement, index: 7, value: job.pollQuery)
            SQLiteHelpers.bindText(statement, index: 8, value: job.pollMailbox)
            SQLiteHelpers.bindInt64(statement, index: 9, value: job.pollIntervalSeconds.map { Int64($0) })
            SQLiteHelpers.bindInt64(statement, index: 10, value: job.pollLimit.map { Int64($0) })
            SQLiteHelpers.bindInt64(statement, index: 11, value: job.maxToolIterations.map { Int64($0) })
            SQLiteHelpers.bindText(statement, index: 12, value: job.onToolLimit)
            SQLiteHelpers.bindDouble(statement, index: 13, value: job.createdAt.timeIntervalSince1970)
            SQLiteHelpers.bindDouble(statement, index: 14, value: job.updatedAt.timeIntervalSince1970)
            if let cursor = job.lastSuccessfulRunEndedAt {
                SQLiteHelpers.bindDouble(statement, index: 15, value: cursor.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(statement, 15)
            }
            SQLiteHelpers.bindInt64(statement, index: 16, value: job.emailReportJob ? 1 : 0)
            SQLiteHelpers.bindText(statement, index: 17, value: job.watcherSource?.rawValue)
            let rulesJSON = job.rules.flatMap { rules -> String? in
                guard let data = try? JSONEncoder().encode(rules) else { return nil }
                return String(data: data, encoding: .utf8)
            }
            SQLiteHelpers.bindText(statement, index: 18, value: rulesJSON)
            SQLiteHelpers.bindInt64(statement, index: 19, value: job.calendarLeadTimeMinutes.map { Int64($0) })
            let calNamesJSON = job.calendarNames.flatMap { names -> String? in
                guard let data = try? JSONEncoder().encode(names) else { return nil }
                return String(data: data, encoding: .utf8)
            }
            SQLiteHelpers.bindText(statement, index: 20, value: calNamesJSON)
            SQLiteHelpers.bindText(statement, index: 21, value: job.pollFrom)
            SQLiteHelpers.bindText(statement, index: 22, value: job.pollSubject)
            SQLiteHelpers.bindInt64(statement, index: 23, value: job.pollUnreadOnly ? 1 : 0)
            SQLiteHelpers.bindInt64(statement, index: 24, value: job.pollSinceDays.map { Int64($0) })

            guard sqlite3_step(statement) == SQLITE_DONE else {
                let code = sqlite3_errcode(handle)
                RuneWeaverLog.stores.error("SQLiteSchedulerJobStore: failed writing job \(job.id) (code \(code)); in-memory state is ahead of disk.")
                return
            }
        }

        static func delete(id: UUID, dbPath: String) {
            guard let handle = SQLiteOpenHelper.openLogged(
                dbPath: dbPath,
                storeName: "SQLiteSchedulerJobStore",
                fallbackNote: "delete of \(id) kept in memory only",
                open: { try open(dbPath: dbPath) }
            ) else {
                return
            }
            defer { sqlite3_close(handle) }

            let sql = "DELETE FROM scheduler_jobs WHERE id = ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                let code = sqlite3_errcode(handle)
                RuneWeaverLog.stores.error("SQLiteSchedulerJobStore: failed preparing job delete (code \(code)) for \(id).")
                return
            }
            defer { sqlite3_finalize(statement) }

            SQLiteHelpers.bindText(statement, index: 1, value: id.uuidString)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                let code = sqlite3_errcode(handle)
                RuneWeaverLog.stores.error("SQLiteSchedulerJobStore: failed deleting job \(id) (code \(code)); in-memory state is ahead of disk.")
                return
            }
        }

        static func clear(dbPath: String) {
            guard let handle = SQLiteOpenHelper.openLogged(
                dbPath: dbPath,
                storeName: "SQLiteSchedulerJobStore",
                fallbackNote: "clear kept in memory only",
                open: { try open(dbPath: dbPath) }
            ) else {
                return
            }
            defer { sqlite3_close(handle) }
            do {
                try SQLiteHelpers.exec(handle: handle, sql: "DELETE FROM scheduler_jobs;", failure: { SchedulerDBError(message: $0) })
            } catch {
                RuneWeaverLog.stores.error("SQLiteSchedulerJobStore: failed clearing jobs: \(error)")
            }
        }
    }
#endif

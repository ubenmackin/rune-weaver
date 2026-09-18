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
    /// Poll mailbox (nil means every selectable mailbox).
    public var pollMailbox: String?
    /// Seconds between poll checks.
    public var pollIntervalSeconds: Int?
    /// Maximum hits fetched per poll (nil means `EmailPollRule/defaultLimit`).
    public var pollLimit: Int?
    /// When the job was created.
    public var createdAt: Date
    /// When the job was last updated.
    public var updatedAt: Date

    /// Creates a scheduler job.
    public init(
        id: UUID = UUID(),
        name: String,
        schedule: String,
        prompt: String,
        enabled: Bool = true,
        pollAccount: String? = nil,
        pollQuery: String? = nil,
        pollMailbox: String? = nil,
        pollIntervalSeconds: Int? = nil,
        pollLimit: Int? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.schedule = schedule
        self.prompt = prompt
        self.enabled = enabled
        self.pollAccount = pollAccount
        self.pollQuery = pollQuery
        self.pollMailbox = pollMailbox
        self.pollIntervalSeconds = pollIntervalSeconds
        self.pollLimit = pollLimit.map(EmailPollRule.clampedLimit)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
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

    /// Email poll rule for this job, when configured.
    public var pollRule: EmailPollRule? {
        EmailPollRule.ruleForStoredFields(
            pollAccount: pollAccount,
            pollQuery: pollQuery,
            pollMailbox: pollMailbox,
            pollIntervalSeconds: pollIntervalSeconds,
            pollLimit: pollLimit
        )
    }
}

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
    /// Poll mailbox (nil means every selectable mailbox).
    public var pollMailbox: String?
    /// Seconds between poll checks.
    public var pollIntervalSeconds: Int?
    /// Maximum hits fetched per poll.
    public var pollLimit: Int?

    /// Creates a new-job payload.
    public init(
        name: String,
        schedule: String,
        prompt: String,
        enabled: Bool? = nil,
        pollAccount: String? = nil,
        pollQuery: String? = nil,
        pollMailbox: String? = nil,
        pollIntervalSeconds: Int? = nil,
        pollLimit: Int? = nil
    ) {
        self.name = name
        self.schedule = schedule
        self.prompt = prompt
        self.enabled = enabled
        self.pollAccount = pollAccount
        self.pollQuery = pollQuery
        self.pollMailbox = pollMailbox
        self.pollIntervalSeconds = pollIntervalSeconds
        self.pollLimit = pollLimit
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
    /// New poll mailbox, if changed (`""` clears to nil).
    public var pollMailbox: String?
    /// New poll interval, if changed. Omitted (nil) leaves the interval
    /// alone; use `clearPoll: true` to clear it.
    public var pollIntervalSeconds: Int?
    /// New poll limit, if changed. Omitted (nil) leaves the limit
    /// alone; use `clearPoll: true` to clear it.
    public var pollLimit: Int?
    /// When true, clears the whole poll trigger to nil before applying
    /// any non-nil poll fields in the same payload.
    public var clearPoll: Bool?

    /// Creates an update payload.
    public init(
        name: String? = nil,
        schedule: String? = nil,
        prompt: String? = nil,
        enabled: Bool? = nil,
        pollAccount: String? = nil,
        pollQuery: String? = nil,
        pollMailbox: String? = nil,
        pollIntervalSeconds: Int? = nil,
        pollLimit: Int? = nil,
        clearPoll: Bool? = nil
    ) {
        self.name = name
        self.schedule = schedule
        self.prompt = prompt
        self.enabled = enabled
        self.pollAccount = pollAccount
        self.pollQuery = pollQuery
        self.pollMailbox = pollMailbox
        self.pollIntervalSeconds = pollIntervalSeconds
        self.pollLimit = pollLimit
        self.clearPoll = clearPoll
    }
}

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

    /// Jobs indexed by identifier.
    private var jobs: [UUID: SchedulerJob] = [:]
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
        let normalizedQuery = Self.normalizedOptional(input.pollQuery)
        let normalizedMailbox = Self.normalizedOptional(input.pollMailbox)
        try Self.validated(
            name: input.name,
            schedule: input.schedule,
            prompt: input.prompt,
            pollAccount: normalizedAccount,
            pollQuery: normalizedQuery,
            pollMailbox: normalizedMailbox,
            pollIntervalSeconds: input.pollIntervalSeconds,
            pollLimit: input.pollLimit
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
            createdAt: now,
            updatedAt: now
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
        if let schedule = input.schedule {
            existing.schedule = schedule.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let prompt = input.prompt {
            guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SchedulerStoreError.invalidField("prompt must not be empty")
            }
            existing.prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let enabled = input.enabled {
            existing.enabled = enabled
        }
        if input.clearPoll == true {
            existing.pollAccount = nil
            existing.pollQuery = nil
            existing.pollMailbox = nil
            existing.pollIntervalSeconds = nil
            existing.pollLimit = nil
        }
        if let pollAccount = input.pollAccount {
            existing.pollAccount = Self.normalizedOptional(pollAccount)
        }
        if let pollQuery = input.pollQuery {
            existing.pollQuery = Self.normalizedOptional(pollQuery)
        }
        if let pollMailbox = input.pollMailbox {
            existing.pollMailbox = Self.normalizedOptional(pollMailbox)
        }
        if let interval = input.pollIntervalSeconds {
            existing.pollIntervalSeconds = interval
        }
        if let limit = input.pollLimit {
            existing.pollLimit = EmailPollRule.clampedLimit(limit)
        }
        try Self.validated(
            name: existing.name,
            schedule: existing.schedule,
            prompt: existing.prompt,
            pollAccount: existing.pollAccount,
            pollQuery: existing.pollQuery,
            pollMailbox: existing.pollMailbox,
            pollIntervalSeconds: existing.pollIntervalSeconds,
            pollLimit: existing.pollLimit
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

    /// Validates required job fields plus trigger shape.
    private static func validated(
        name: String,
        schedule: String,
        prompt: String,
        pollAccount: String? = nil,
        pollQuery: String? = nil,
        pollMailbox: String? = nil,
        pollIntervalSeconds: Int? = nil,
        pollLimit: Int? = nil
    ) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SchedulerStoreError.invalidField("name must not be empty")
        }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SchedulerStoreError.invalidField("prompt must not be empty")
        }
        let trimmedAccount = pollAccount?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedAccount.isEmpty {
            if pollQuery != nil {
                throw SchedulerStoreError.invalidField("poll_query requires poll_account")
            }
            if pollMailbox != nil {
                throw SchedulerStoreError.invalidField("poll_mailbox requires poll_account")
            }
            if pollIntervalSeconds != nil {
                throw SchedulerStoreError.invalidField("poll_interval_seconds requires poll_account")
            }
            if pollLimit != nil {
                throw SchedulerStoreError.invalidField("poll_limit requires poll_account")
            }
        }
        let scheduleValue: String? = EmailPollRule.configSchedule(from: schedule)
        let pollValue: EmailPollRule? = EmailPollRule.ruleForStoredFields(
            pollAccount: pollAccount,
            pollQuery: pollQuery,
            pollMailbox: pollMailbox,
            pollIntervalSeconds: pollIntervalSeconds,
            pollLimit: pollLimit
        )
        let synthetic = SchedulerJobConfig(
            name: name,
            prompt: prompt,
            enabled: true,
            schedule: scheduleValue,
            poll: pollValue
        )
        do {
            try synthetic.validate()
        } catch let error as SchedulerConfigError {
            throw Self.mapSchedulerConfigError(error)
        }
    }

    /// Maps shared scheduler validation to store errors.
    private static func mapSchedulerConfigError(_ error: SchedulerConfigError) -> SchedulerStoreError {
        .invalidField(error.displayDetail)
    }

    /// Normalizes an optional poll string (blank becomes nil).
    /// - Parameter value: Raw value, if any.
    /// - Returns: Trimmed value, or nil when blank.
    private static func normalizedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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

    /// Seeds in-memory state from configuration.
    private static func seedInMemory(from config: SchedulerConfig) -> [UUID: SchedulerJob] {
        var seeded: [UUID: SchedulerJob] = [:]
        var seen: Set<String> = []
        for entry in config.jobs {
            let trimmedName = normalizedSchedulerJobName(entry.name)
            guard !seen.contains(trimmedName) else { continue }
            seen.insert(trimmedName)
            let job = SchedulerJob(from: entry)
            seeded[job.id] = job
        }
        return seeded
    }

    /// Loads persisted jobs from the given SQLite database path.
    public static func persistedJobs(from dbPath: String) async -> [SchedulerJob] {
        #if canImport(SQLite3)
            do {
                return try await SQLiteSerialIO.run {
                    SQLiteSchedulerJobStore.read(dbPath: dbPath)
                }
            } catch {
                RuneWeaverLog.stores.error("SchedulerStore: persistedJobs failed reading from SQLite: \(error.localizedDescription)")
                return []
            }
        #else
            return []
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

public extension SchedulerJob {
    /// Creates a runtime job from a `config.toml` entry.
    init(from config: SchedulerJobConfig, id: UUID = UUID(), createdAt: Date = Date(), updatedAt: Date = Date()) {
        let trimmedName = normalizedSchedulerJobName(config.name)
        let schedule = EmailPollRule.storedSchedule(from: config.schedule)
        let rawQuery = config.poll?.query.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    /// Converts this runtime job to a `config.toml` entry.
    func toJobConfig() -> SchedulerJobConfig {
        let scheduleValue: String? = EmailPollRule.configSchedule(from: schedule)
        let pollValue: EmailPollRule? = pollRule
        return SchedulerJobConfig(
            name: name,
            prompt: prompt,
            enabled: enabled,
            schedule: scheduleValue,
            poll: pollValue
        )
    }
}

public extension SchedulerJobConfig {
    /// Creates a config entry from a runtime job.
    init(from job: SchedulerJob) {
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
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_scheduler_jobs_name ON scheduler_jobs(name);
                """,
                failure: { SchedulerDBError(message: $0) }
            )
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
            SELECT id, name, schedule, prompt, enabled, poll_account, poll_query, poll_mailbox, poll_interval_seconds, poll_limit, created_at, updated_at
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

                let createdAt = Date(timeIntervalSince1970: SQLiteHelpers.columnDouble(statement, index: 10))
                let updatedAt = Date(timeIntervalSince1970: SQLiteHelpers.columnDouble(statement, index: 11))

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
                    createdAt: createdAt,
                    updatedAt: updatedAt
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
                poll_mailbox, poll_interval_seconds, poll_limit, created_at, updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                updated_at = excluded.updated_at;
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
            SQLiteHelpers.bindDouble(statement, index: 11, value: job.createdAt.timeIntervalSince1970)
            SQLiteHelpers.bindDouble(statement, index: 12, value: job.updatedAt.timeIntervalSince1970)

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

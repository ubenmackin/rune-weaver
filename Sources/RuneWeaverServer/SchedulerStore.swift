// Rune Weaver Server — In-memory scheduler job registry and CRUD store.
//
// Manages runtime scheduler job definitions, bridging to and from durable
// `config.toml` representations. Enforces job name uniqueness, trigger validation,
// and bounded job capacity while exposing CRUD operations for REST clients.

import Foundation
import RuneWeaverCore

/// One scheduled job: a cron-like trigger and/or an email-arrival poll rule plus the prompt to run.
///
/// `config.toml [[scheduler.jobs]]` (``SchedulerJobConfig``) is the durable
/// source of truth; ``SchedulerStore`` is the REST runtime registry bridging
/// to and from that config (see `init(from:)` / `sync(from:)` /
/// `toSchedulerConfig()`). Cron-like triggers use a five-field expression
/// (`minute hour day month weekday`, e.g. `"0 8 * * *"` for daily at 08:00)
/// or a named shortcut (`@hourly`, `@daily`, `@weekly`). Poll triggers watch
/// one `[email.accounts]` entry for previously unseen arrivals
/// (`pollAccount` plus optional `pollQuery`/`pollMailbox`, polled every
/// `pollIntervalSeconds`). A job fires on either trigger when both are set;
/// disabled jobs are kept but never run. Headless fires run under the stable
/// job session (`SchedulerEngine/deterministicSessionID(forJobNamed:)` of
/// the job name with `source "scheduler"`) so CLI, engine, and manual REST
/// runs share one episodic session per job name instead of forking history
/// per entry point.
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
    /// - Parameters:
    ///   - id: Job identifier. Defaults to a new UUID.
    ///   - name: Human-readable name.
    ///   - schedule: Cron-like expression. Empty for poll-only jobs.
    ///   - prompt: Prompt executed on fire.
    ///   - enabled: Whether the job fires. Defaults to true.
    ///   - pollAccount: Poll account nickname. Defaults to nil (cron-only).
    ///   - pollQuery: Poll query. Defaults to nil.
    ///   - pollMailbox: Poll mailbox. Defaults to nil.
    ///   - pollIntervalSeconds: Seconds between polls. Defaults to nil.
    ///   - pollLimit: Maximum hits per poll. Defaults to nil (`defaultLimit`).
    ///   - createdAt: Creation date. Defaults to now.
    ///   - updatedAt: Update date. Defaults to now.
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
    /// - Returns: Poll rule, or nil for cron-only jobs.
    public var pollRule: EmailPollRule? {
        guard let account = pollAccount?.trimmingCharacters(in: .whitespacesAndNewlines), !account.isEmpty else {
            return nil
        }
        return EmailPollRule(
            account: account,
            query: pollQuery ?? "",
            mailbox: pollMailbox,
            pollIntervalSeconds: pollIntervalSeconds ?? EmailPollRule.defaultPollIntervalSeconds,
            limit: pollLimit ?? EmailPollRule.defaultLimit
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
    /// - Parameters:
    ///   - name: Human-readable name.
    ///   - schedule: Cron-like expression. Empty for poll-only jobs.
    ///   - prompt: Prompt executed on fire.
    ///   - enabled: Whether the job fires. Defaults to nil (treated as true).
    ///   - pollAccount: Poll account nickname. Defaults to nil.
    ///   - pollQuery: Poll query. Defaults to nil.
    ///   - pollMailbox: Poll mailbox. Defaults to nil.
    ///   - pollIntervalSeconds: Seconds between polls. Defaults to nil.
    ///   - pollLimit: Maximum hits per poll. Defaults to nil.
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
///
/// Poll clear-vs-omit contract: `nil` leaves the field alone (omit =
/// no-change). A blank string (`""` or whitespace) clears that poll string
/// to `nil` (blank → nil normalization, so `""` never persists as a dead
/// `pollQuery=""` row on cron-only jobs). `pollIntervalSeconds` has no
/// blank form, so `clearPoll: true` clears the whole poll trigger
/// (account, query, mailbox, and interval) to `nil`; when `clearPoll` is
/// true any non-nil poll fields in the same payload are applied after the
/// clear so callers can atomically replace the trigger.
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
    /// - Parameters:
    ///   - name: New name, if renamed.
    ///   - schedule: New schedule, if rescheduled.
    ///   - prompt: New prompt, if changed.
    ///   - enabled: New enabled flag, if toggled.
    ///   - pollAccount: New poll account, if changed (`""` clears).
    ///   - pollQuery: New poll query, if changed (`""` clears).
    ///   - pollMailbox: New poll mailbox, if changed (`""` clears).
    ///   - pollIntervalSeconds: New poll interval, if changed.
    ///   - pollLimit: New poll limit, if changed.
    ///   - clearPoll: When true, clears the poll trigger first.
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

/// In-memory CRUD store for scheduler jobs.
///
/// Runtime owner of job state for the service surface (REST CRUD plus
/// manual `POST .../run`). The service never auto-fires cron or poll
/// triggers; the CLI `scheduler run` foreground loop is the sole auto-fire
/// runner. Durable state lives in `config.toml
/// [[scheduler.jobs]]`: seed with `init(from:)`, refresh with
/// `sync(from:)`, and export with `toSchedulerConfig()` so REST edits can
/// be persisted back to config and survive restart.
public actor SchedulerStore {
    /// Maximum jobs kept in the store to bound memory and avoid unbounded resource consumption.
    public static let maxJobs = 100

    /// Jobs indexed by identifier.
    private var jobs: [UUID: SchedulerJob] = [:]

    /// Creates an empty store.
    public init() {}

    /// Creates a job from a REST payload.
    /// - Parameter input: New-job payload.
    /// - Returns: The stored job.
    /// - Throws: `SchedulerStoreError/invalidField(_:)` when a required
    ///   field is blank, a trigger is malformed, or the trimmed name is
    ///   already taken by another job.
    @discardableResult
    public func create(_ input: NewSchedulerJob) throws -> SchedulerJob {
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
        return job
    }

    /// Lists every job, oldest first.
    /// - Returns: All jobs sorted by creation date.
    public func list() -> [SchedulerJob] {
        jobs.values.sorted { $0.createdAt < $1.createdAt }
    }

    /// Looks up one job.
    /// - Parameter id: Job identifier.
    /// - Returns: The job, or nil when unknown.
    public func job(id: UUID) -> SchedulerJob? {
        jobs[id]
    }

    /// Updates one job, touching `updatedAt` on change.
    ///
    /// Poll fields follow the clear-vs-omit contract documented on
    /// ``UpdateSchedulerJob``: nil leaves the field alone, `""` clears
    /// that poll string to nil, and `clearPoll: true` clears the whole
    /// poll trigger before applying any non-nil poll fields in the same
    /// payload.
    /// - Parameters:
    ///   - id: Job identifier.
    ///   - input: Fields to change; nil fields are left alone.
    /// - Returns: The updated job.
    /// - Throws: `SchedulerStoreError/unknownJob(_:)` when the job is
    ///   unknown, or `invalidField` when a supplied field is blank, a
    ///   trigger is malformed, or the new name is already taken.
    @discardableResult
    public func update(id: UUID, _ input: UpdateSchedulerJob) throws -> SchedulerJob {
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
        jobs[id] = existing
        return existing
    }

    /// Deletes one job. Unknown identifiers are a no-op.
    /// - Parameter id: Job identifier.
    /// - Returns: True when a job was removed.
    @discardableResult
    public func delete(id: UUID) -> Bool {
        jobs.removeValue(forKey: id) != nil
    }

    /// Removes every job.
    public func clear() {
        jobs.removeAll()
    }

    /// Number of stored jobs.
    /// - Returns: Job count.
    public func count() -> Int {
        jobs.count
    }

    /// Validates required job fields plus trigger shape.
    ///
    /// REST-specific checks (non-blank name and prompt) stay local;
    /// trigger shape (cron parsing, poll presence, poll interval) delegates
    /// to the single shared `SchedulerJobConfig.validate()` so the store
    /// and `config.toml` validation cannot drift. Poll state is atomic:
    /// when the normalized account is nil/blank, a non-nil query, mailbox,
    /// interval, or limit is rejected instead of persisting as dead state on
    /// cron-only jobs (which `pollRule`/`toSchedulerConfig()` would
    /// otherwise silently drop on export).
    /// - Parameters:
    ///   - name: Job name candidate.
    ///   - schedule: Schedule candidate (empty for poll-only jobs).
    ///   - prompt: Prompt candidate.
    ///   - pollAccount: Poll account candidate, if any.
    ///   - pollQuery: Poll query candidate, if any.
    ///   - pollMailbox: Poll mailbox candidate, if any.
    ///   - pollIntervalSeconds: Poll interval candidate, if any.
    ///   - pollLimit: Poll limit candidate, if any.
    /// - Throws: `SchedulerStoreError/invalidField(_:)` when blank or malformed.
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
        let trimmedSchedule = schedule.trimmingCharacters(in: .whitespacesAndNewlines)
        let scheduleValue: String? = trimmedSchedule.isEmpty ? nil : trimmedSchedule
        let pollValue: EmailPollRule? = trimmedAccount.isEmpty ? nil : EmailPollRule(
            account: trimmedAccount,
            query: pollQuery ?? "",
            mailbox: pollMailbox,
            pollIntervalSeconds: pollIntervalSeconds ?? EmailPollRule.defaultPollIntervalSeconds,
            limit: pollLimit ?? EmailPollRule.defaultLimit
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
    ///
    /// Single-sourced via `SchedulerConfigError/displayDetail` so the
    /// store and config messages cannot drift.
    /// - Parameter error: Shared config validation failure.
    /// - Returns: Equivalent store field error.
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

    /// Creates a store seeded from `config.toml [[scheduler.jobs]]`.
    ///
    /// The config is the durable source of truth; the store is the REST
    /// runtime view. Config entries are already validated by
    /// `RuneWeaverConfig/validate()`, so seeding maps them directly
    /// without re-throwing. Names are compared trimmed (same as
    /// `create`); duplicate trimmed names are ignored keep-first so a
    /// duplicated `config.toml` cannot fork the runtime registry
    /// (duplicates are rejected at validation time; this is
    /// defense-in-depth).
    /// - Parameter config: Scheduler section to seed from.
    public init(from config: SchedulerConfig) {
        var seen: Set<String> = []
        for entry in config.jobs {
            let trimmedName = normalizedSchedulerJobName(entry.name)
            guard !seen.contains(trimmedName) else { continue }
            seen.insert(trimmedName)
            let job = SchedulerJob(from: entry)
            jobs[job.id] = job
        }
    }

    /// Replaces the runtime registry with `config.toml [[scheduler.jobs]]`.
    ///
    /// Jobs sharing a trimmed name with an existing entry keep their runtime `id`
    /// and `createdAt` so in-flight REST references stay stable across a
    /// config reload; renamed or new entries get fresh identifiers.
    /// Duplicate config names are ignored keep-first on the trimmed name
    /// so a duplicated `config.toml` cannot fork the runtime registry
    /// (duplicates are rejected at validation time; this is
    /// defense-in-depth).
    /// - Parameter config: Scheduler section to sync from.
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
    ///
    /// Use the result to write `[[scheduler.jobs]]` back to `config.toml`
    /// so REST-created jobs survive restart.
    /// - Returns: Scheduler config mirroring the stored jobs.
    public func toSchedulerConfig() -> SchedulerConfig {
        SchedulerConfig(jobs: list().map { $0.toJobConfig() })
    }

    /// Stable episodic session for one stored job.
    ///
    /// Shared single-flight identity with `SchedulerEngine`: deterministic
    /// per job name so manual REST runs and CLI/engine fires append to the
    /// same session instead of forking history per entry point.
    /// - Parameter id: Job identifier.
    /// - Returns: Stable session, or nil when the job is unknown.
    public func stableSessionID(for id: UUID) -> UUID? {
        guard let job = jobs[id] else { return nil }
        return job.stableSessionID()
    }
}

public extension SchedulerJob {
    /// Creates a runtime job from a `config.toml` entry.
    ///
    /// Bridges the name-keyed config model to the UUID-keyed REST model:
    /// a nil or blank config `schedule` becomes `""` (poll-only), and a
    /// nil poll rule leaves every poll field nil (cron-only). The config
    /// name is trimmed (same as `create`) so `" foo "` and `"foo"` map to
    /// one runtime name instead of forking the registry.
    /// - Parameters:
    ///   - config: Config entry to bridge.
    ///   - id: Runtime identifier. Defaults to a new UUID.
    ///   - createdAt: Creation date. Defaults to now.
    ///   - updatedAt: Update date. Defaults to now.
    init(from config: SchedulerJobConfig, id: UUID = UUID(), createdAt: Date = Date(), updatedAt: Date = Date()) {
        let trimmedName = normalizedSchedulerJobName(config.name)
        let schedule = config.schedule?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
    ///
    /// A blank `schedule` becomes nil (poll-only); a missing poll account
    /// becomes a nil poll rule (cron-only).
    /// - Returns: Equivalent config entry.
    func toJobConfig() -> SchedulerJobConfig {
        let trimmedSchedule = schedule.trimmingCharacters(in: .whitespacesAndNewlines)
        let scheduleValue: String? = trimmedSchedule.isEmpty ? nil : trimmedSchedule
        let pollValue: EmailPollRule? = pollRule
        return SchedulerJobConfig(
            name: name,
            prompt: prompt,
            enabled: enabled,
            schedule: scheduleValue,
            poll: pollValue
        )
    }

    /// Stable episodic session shared with the scheduler engine.
    ///
    /// Deterministic per job name so every entry point (CLI foreground
    /// loop, engine fires, manual REST runs) appends to one session.
    /// - Returns: Stable session identifier.
    func stableSessionID() -> UUID {
        SchedulerEngine.deterministicSessionID(forJobNamed: name)
    }
}

public extension SchedulerJobConfig {
    /// Creates a config entry from a runtime job.
    ///
    /// Bridges the UUID-keyed REST model back to the name-keyed config
    /// model for persistence.
    /// - Parameter job: Runtime job to bridge.
    init(from job: SchedulerJob) {
        self = job.toJobConfig()
    }
}

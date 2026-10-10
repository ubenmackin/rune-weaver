// Rune Weaver Server — Scheduler job validation and seeding helpers split from the store actor body.

import Foundation
import RuneWeaverCore

// MARK: - Validation Helpers

/// Field and trigger validation split from the actor body.
///
/// These operate on values only, so keeping them here leaves the isolated
/// job state and mutation paths scannable in one place. Members stay on
/// `SchedulerStore` itself, so no caller changes.
extension SchedulerStore {
    /// Validates required job fields plus trigger shape.
    static func validated(
        name: String,
        schedule: String,
        prompt: String,
        pollAccount: String? = nil,
        pollQuery: String? = nil,
        pollMailbox: String? = nil,
        pollIntervalSeconds: Int? = nil,
        pollLimit: Int? = nil,
        maxToolIterations: Int? = nil,
        onToolLimit: String? = nil
    ) throws {
        try validateToolBudget(maxToolIterations: maxToolIterations, onToolLimit: onToolLimit)
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

    /// Validates the per-job tool budget carried on the REST path.
    ///
    /// The dashboard clamps these fields client-side, but direct REST callers
    /// bypass it, so the store rejects out-of-range budgets here before they
    /// persist or reach the worker. Nil inherits the section default.
    static func validateToolBudget(maxToolIterations: Int?, onToolLimit: String?) throws {
        if let maxToolIterations, !(1 ... 100).contains(maxToolIterations) {
            throw SchedulerStoreError.invalidField("max_tool_iterations must be between 1 and 100 (got \(maxToolIterations))")
        }
        if let onToolLimit, !["fail", "park"].contains(onToolLimit) {
            throw SchedulerStoreError.invalidField("on_tool_limit must be 'fail' or 'park' (got '\(onToolLimit)')")
        }
    }

    /// Maps shared scheduler validation to store errors.
    static func mapSchedulerConfigError(_ error: SchedulerConfigError) -> SchedulerStoreError {
        .invalidField(error.displayDetail)
    }

    /// Normalizes an optional poll string (blank becomes nil).
    /// - Parameter value: Raw value, if any.
    /// - Returns: Trimmed value, or nil when blank.
    static func normalizedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Seeding Helpers

/// Config-seed construction split from the actor body.
///
/// Builds the in-memory registry from configuration without touching disk
/// or isolated state, so the bootstrap path stays scannable in one place.
/// Members stay on `SchedulerStore` itself, so no caller changes.
extension SchedulerStore {
    /// Seeds in-memory state from configuration.
    static func seedInMemory(from config: SchedulerConfig) -> [UUID: SchedulerJob] {
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
}

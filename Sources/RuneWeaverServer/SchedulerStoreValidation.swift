// Rune Weaver Server — Scheduler job validation and seeding helpers split from the store actor body.

import Foundation
import RuneWeaverCore

// MARK: - Validation Helpers

/// Field and trigger validation split from the actor body. These operate on values only, so keeping
/// them here leaves the isolated job state and mutation paths scannable in one place.
extension SchedulerStore {
    /// Bundled validation inputs so helpers stay small.
    fileprivate struct ValidationRequest {
        let name: String
        let schedule: String
        let prompt: String
        let pollAccount: String?
        let pollQuery: String?
        let pollContains: String?
        let pollMailbox: String?
        let pollIntervalSeconds: Int?
        let pollLimit: Int?
        let pollFrom: String?
        let pollSubject: String?
        let pollUnreadOnly: Bool?
        let pollSinceDays: Int?
        let maxToolIterations: Int?
        let onToolLimit: String?
        let watcherSource: EventWatcherSource?
        let rules: [EventRule]?
        let calendarLeadTimeMinutes: Int?
        let calendarNames: [String]?
    }

    /// Validates required job fields plus trigger shape.
    static func validated(
        name: String,
        schedule: String,
        prompt: String,
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
        maxToolIterations: Int? = nil,
        onToolLimit: String? = nil,
        watcherSource: EventWatcherSource? = nil,
        rules: [EventRule]? = nil,
        calendarLeadTimeMinutes: Int? = nil,
        calendarNames: [String]? = nil
    ) throws {
        let request = ValidationRequest(
            name: name, schedule: schedule, prompt: prompt,
            pollAccount: pollAccount, pollQuery: pollQuery, pollContains: pollContains, pollMailbox: pollMailbox,
            pollIntervalSeconds: pollIntervalSeconds, pollLimit: pollLimit,
            pollFrom: pollFrom, pollSubject: pollSubject,
            pollUnreadOnly: pollUnreadOnly, pollSinceDays: pollSinceDays,
            maxToolIterations: maxToolIterations, onToolLimit: onToolLimit,
            watcherSource: watcherSource, rules: rules,
            calendarLeadTimeMinutes: calendarLeadTimeMinutes, calendarNames: calendarNames
        )
        try validateToolBudget(maxToolIterations: maxToolIterations, onToolLimit: onToolLimit)
        try validateNameAndPrompt(request)
        try validatePollAccountRequirements(request)
        try validatePollFieldValues(request)
        try validateDirectTools(request)
        try validateViaSynthetic(request)
    }

    /// Name plus prompt presence for rule-less jobs.
    private static func validateNameAndPrompt(_ request: ValidationRequest) throws {
        guard !request.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SchedulerStoreError.invalidField("name must not be empty")
        }
        let hasRules = !(request.rules ?? []).isEmpty
        if !hasRules {
            guard !request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SchedulerStoreError.invalidField("prompt must not be empty")
            }
        }
    }

    /// Poll fields requiring an account.
    private static func validatePollAccountRequirements(_ request: ValidationRequest) throws {
        let trimmedAccount = request.pollAccount?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmedAccount.isEmpty else { return }
        try requirePollAccountAbsent(request.pollQuery, field: "poll_query")
        try requirePollAccountAbsent(request.pollContains, field: "poll_contains")
        try requirePollAccountAbsent(request.pollMailbox, field: "poll_mailbox")
        try requirePollAccountAbsent(request.pollLimit, field: "poll_limit")
        try requirePollAccountAbsent(request.pollFrom, field: "poll_from")
        try requirePollAccountAbsent(request.pollSubject, field: "poll_subject")
        try requirePollAccountAbsent(request.pollSinceDays, field: "poll_since_days")
        if let unread = request.pollUnreadOnly, unread {
            throw SchedulerStoreError.invalidField("poll_unread_only requires poll_account")
        }
        if request.pollIntervalSeconds != nil, request.watcherSource == nil {
            throw SchedulerStoreError.invalidField("poll_interval_seconds requires poll_account")
        }
    }

    /// Single optional poll field requiring an account.
    private static func requirePollAccountAbsent(_ value: some Any?, field: String) throws {
        if value != nil {
            throw SchedulerStoreError.invalidField("\(field) requires poll_account")
        }
    }

    /// Bounds for poll text plus interval and calendar window.
    private static func validatePollFieldValues(_ request: ValidationRequest) throws {
        try validateNonEmpty(request.pollQuery, field: "poll_query")
        try validateNonEmpty(request.pollContains, field: "poll_contains")
        try validateNonEmpty(request.pollFrom, field: "poll_from")
        try validateNonEmpty(request.pollSubject, field: "poll_subject")
        if let days = request.pollSinceDays {
            let minDays = EmailPollRule.minSinceDays
            let maxDays = EmailPollRule.maxSinceDays
            guard (minDays ... maxDays).contains(days) else {
                throw SchedulerStoreError.invalidField(
                    "poll_since_days must be between \(minDays) and \(maxDays) (got \(days))"
                )
            }
        }
        // REST path rejects out-of-range cadence without depending
        // on whether a watcher tick carries a poll account.
        if let interval = request.pollIntervalSeconds {
            let minInterval = EmailPollRule.minPollIntervalSeconds
            let maxInterval = EmailPollRule.maxPollIntervalSeconds
            guard (minInterval ... maxInterval).contains(interval) else {
                throw SchedulerStoreError.invalidField(
                    "poll_interval_seconds must be between \(minInterval) and \(maxInterval) (got \(interval))"
                )
            }
        }
        if let leadTime = request.calendarLeadTimeMinutes {
            let minLeadTime = SchedulerJobConfig.minCalendarLeadTimeMinutes
            let maxLeadTime = SchedulerJobConfig.maxCalendarLeadTimeMinutes
            guard (minLeadTime ... maxLeadTime).contains(leadTime) else {
                throw SchedulerStoreError.invalidField(
                    "calendar_lead_time_minutes must be between \(minLeadTime) and \(maxLeadTime) (got \(leadTime))"
                )
            }
        }
    }

    /// Optional text that must not be blank when present.
    private static func validateNonEmpty(_ value: String?, field: String) throws {
        if let value {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SchedulerStoreError.invalidField("\(field) must not be empty")
            }
        }
    }

    /// Direct-tool allowlist check for event rules.
    private static func validateDirectTools(_ request: ValidationRequest) throws {
        guard let rules = request.rules else { return }
        for rule in rules {
            try validateDirectTool(rule, jobName: request.name)
        }
    }

    /// Single rule direct-tool check.
    private static func validateDirectTool(_ rule: EventRule, jobName: String) throws {
        guard case let .directTool(toolName, _) = rule.action else { return }
        let trimmedTool = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTool.isEmpty else {
            throw SchedulerStoreError.invalidField(
                "job '\(jobName)' rule '\(rule.name)' is invalid: tool_name must not be empty"
            )
        }
        // Store rejects unknown tools alongside shared config
        // validation; both gates share one allowlist owner.
        guard EventRuleAction.isAllowedDirectTool(trimmedTool) else {
            let allowedTools = EventRuleAction.allowedDirectToolNames.sorted().joined(separator: ", ")
            throw SchedulerStoreError.invalidField(
                "job '\(jobName)' rule '\(rule.name)' is invalid: "
                    + "tool_name '\(trimmedTool)' is not allowed (must be one of \(allowedTools))"
            )
        }
    }

    /// Cross-checks through the shared config validator.
    private static func validateViaSynthetic(_ request: ValidationRequest) throws {
        let scheduleValue: String? = EmailPollRule.configSchedule(from: request.schedule)
        let pollValue: EmailPollRule? = EmailPollRule.ruleForStoredFields(
            pollAccount: request.pollAccount,
            pollQuery: request.pollQuery ?? request.pollContains,
            pollMailbox: request.pollMailbox,
            pollIntervalSeconds: request.pollIntervalSeconds,
            pollLimit: request.pollLimit,
            pollFrom: request.pollFrom,
            pollSubject: request.pollSubject,
            pollUnreadOnly: request.pollUnreadOnly,
            pollSinceDays: request.pollSinceDays
        )
        let synthetic = SchedulerJobConfig(
            name: request.name,
            prompt: request.prompt,
            enabled: true,
            schedule: scheduleValue,
            poll: pollValue,
            maxToolIterations: request.maxToolIterations,
            onToolLimit: request.onToolLimit,
            watcherSource: request.watcherSource,
            rules: request.rules,
            calendarLeadTimeMinutes: request.calendarLeadTimeMinutes,
            calendarNames: request.calendarNames
        )
        do {
            try synthetic.validate()
        } catch let error as SchedulerConfigError {
            throw Self.mapSchedulerConfigError(error)
        }
    }

    /// Validates the per-job tool budget carried on the REST path.
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

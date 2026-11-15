// Rune Weaver Core — Missed-schedule policy and SQLite schema migration constants.

import Foundation

/// How a recurring cron job behaves when a scheduled fire time passed while the host slept or was offline.
public enum SchedulerMisfirePolicy: String, Sendable, Codable, Equatable, CaseIterable {
    /// Only run within the strict grace window of the scheduled time; skip stale slots.
    case strict
    /// Run once as soon as possible on wake or launch when the latest scheduled slot never started.
    case catchUp = "catch_up"

    /// Parses a persisted or user-supplied policy token, trimming surrounding whitespace.
    /// Returns `nil` when non-empty and unrecognized.
    public static func parseStrict(_ raw: String) -> SchedulerMisfirePolicy? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return SchedulerMisfirePolicy(rawValue: trimmed)
    }
}

extension SchedulerJobConfig {
    /// Additive columns tracking cron misfire policy and per-slot execution state.
    public static let cronTrackingColumnMigrationStatements: [String] = [
        "ALTER TABLE scheduler_jobs ADD COLUMN misfire_policy TEXT NOT NULL DEFAULT 'strict';",
        "ALTER TABLE scheduler_jobs ADD COLUMN last_scheduled_slot_at REAL;",
        "ALTER TABLE scheduler_jobs ADD COLUMN schedule_anchor_at REAL;"
    ]

    /// Applies the additive cron misfire migrations through a caller-supplied executor.
    public static func applyCronTrackingColumnMigrations(_ exec: (String) -> Void) {
        for statement in cronTrackingColumnMigrationStatements {
            exec(statement)
        }
    }
}

// Rune Weaver Server — Cron slot tracking and SQLite persistence for scheduler jobs.

import Foundation
import RuneWeaverCore
#if canImport(SQLite3)
    import SQLite3
#endif

extension SchedulerStore {
    /// Records that a scheduled cron slot attempt started so missed-slot catch-up never retries it.
    public func recordScheduledSlotAttempt(id: UUID, slotAt: Date) async {
        guard var existing = jobs[id] else { return }
        if let recorded = existing.lastScheduledSlotAt, recorded >= slotAt {
            return
        }
        existing.lastScheduledSlotAt = slotAt
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

    /// Replaces or inserts a job record in memory and SQLite (used by scheduler timing tests).
    func upsertJob(_ job: SchedulerJob) async {
        jobs[job.id] = job
        if let dbPath {
            #if canImport(SQLite3)
                await SQLiteSerialIO.runUncancellable {
                    SQLiteSchedulerJobStore.write(job: job, dbPath: dbPath)
                }
            #endif
        }
    }
}

#if canImport(SQLite3)
    /// Internal SQLite helper for durable scheduler job persistence.
    enum SQLiteSchedulerJobStore {
        private struct SchedulerDBError: Error {
            let message: String
        }

        private static let legacyAlterStatements = [
            "ALTER TABLE scheduler_jobs ADD COLUMN poll_account TEXT;",
            "ALTER TABLE scheduler_jobs ADD COLUMN poll_query TEXT;",
            "ALTER TABLE scheduler_jobs ADD COLUMN poll_mailbox TEXT;",
            "ALTER TABLE scheduler_jobs ADD COLUMN poll_interval_seconds INTEGER;",
            "ALTER TABLE scheduler_jobs ADD COLUMN poll_limit INTEGER;",
            "ALTER TABLE scheduler_jobs ADD COLUMN max_tool_iterations INTEGER;",
            "ALTER TABLE scheduler_jobs ADD COLUMN on_tool_limit TEXT;",
            "ALTER TABLE scheduler_jobs ADD COLUMN last_successful_run_ended_at REAL;",
            "ALTER TABLE scheduler_jobs ADD COLUMN email_report_job INTEGER NOT NULL DEFAULT 0;",
            "ALTER TABLE scheduler_jobs ADD COLUMN poll_from TEXT;",
            "ALTER TABLE scheduler_jobs ADD COLUMN poll_subject TEXT;",
            "ALTER TABLE scheduler_jobs ADD COLUMN poll_unread_only INTEGER;",
            "ALTER TABLE scheduler_jobs ADD COLUMN poll_since_days INTEGER;"
        ]

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
                    email_report_job INTEGER NOT NULL DEFAULT 0,
                    misfire_policy TEXT NOT NULL DEFAULT 'strict',
                    last_scheduled_slot_at REAL,
                    schedule_anchor_at REAL
                );
                CREATE INDEX IF NOT EXISTS idx_scheduler_jobs_name ON scheduler_jobs(name);
                """,
                failure: { SchedulerDBError(message: $0) }
            )
            migrateColumns(handle: handle)
            return handle
        }

        private static func migrateColumns(handle: OpaquePointer?) {
            for sql in legacyAlterStatements {
                _ = try? SQLiteHelpers.exec(handle: handle, sql: sql, failure: { SchedulerDBError(message: $0) })
            }
            // Watcher and cron-tracking columns delegate to Core-owned statement lists so
            // additive migrations stay identical across persistence sites.
            SchedulerJobConfig.applyWatcherColumnMigrations { statement in
                _ = try? SQLiteHelpers.exec(handle: handle, sql: statement, failure: { SchedulerDBError(message: $0) })
            }
            SchedulerJobConfig.applyCronTrackingColumnMigrations { statement in
                _ = try? SQLiteHelpers.exec(handle: handle, sql: statement, failure: { SchedulerDBError(message: $0) })
            }
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
                   poll_from, poll_subject, poll_unread_only, poll_since_days,
                   misfire_policy, last_scheduled_slot_at, schedule_anchor_at
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
                if let job = decodeJob(from: statement) {
                    loaded.append(job)
                }
            }
            return loaded
        }

        private static func decodeJob(from statement: OpaquePointer?) -> SchedulerJob? {
            guard let idStr = SQLiteHelpers.columnText(statement, index: 0),
                  let id = UUID(uuidString: idStr),
                  let row = SchedulerJobRow.decode(statement, base: 1)
            else {
                return nil
            }

            let createdAt = Date(timeIntervalSince1970: SQLiteHelpers.columnDouble(statement, index: 12))
            let updatedAt = Date(timeIntervalSince1970: SQLiteHelpers.columnDouble(statement, index: 13))
            let cursor = decodeOptionalDate(statement, index: 14)
            // Rows written before the email-report flag existed decode as false, matching column default.
            let emailReportJob = (SQLiteHelpers.columnInt64(statement, index: 15) ?? 0) != 0
            let watcherSource = SQLiteHelpers.columnText(statement, index: 16).flatMap { EventWatcherSource(rawValue: $0) }
            let rules: [EventRule]? = decodeJSONColumn(statement, index: 17)
            let leadTime = SQLiteHelpers.columnInt64(statement, index: 18).map { Int($0) }
            let calendarNames: [String]? = decodeJSONColumn(statement, index: 19)
            // Blank strings predate normalization; folding keeps legacy rows equivalent to omitted filters.
            let normalizedFrom = normalizedNonEmpty(SQLiteHelpers.columnText(statement, index: 20))
            let normalizedSubject = normalizedNonEmpty(SQLiteHelpers.columnText(statement, index: 21))
            let unreadOnly = (SQLiteHelpers.columnInt64(statement, index: 22) ?? 0) != 0
            let sinceDays = SQLiteHelpers.columnInt64(statement, index: 23).map { Int($0) }
            let misfirePolicy = SQLiteHelpers.columnText(statement, index: 24)
                .flatMap { SchedulerMisfirePolicy.parseStrict($0) } ?? .strict
            let lastScheduledSlotAt = decodeOptionalDate(statement, index: 25)
            let scheduleAnchorAt = decodeOptionalDate(statement, index: 26)

            return SchedulerJob(
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
                calendarNames: calendarNames,
                misfirePolicy: misfirePolicy,
                lastScheduledSlotAt: lastScheduledSlotAt,
                scheduleAnchorAt: scheduleAnchorAt
            )
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
                poll_from, poll_subject, poll_unread_only, poll_since_days,
                misfire_policy, last_scheduled_slot_at, schedule_anchor_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                poll_since_days = excluded.poll_since_days,
                misfire_policy = excluded.misfire_policy,
                last_scheduled_slot_at = excluded.last_scheduled_slot_at,
                schedule_anchor_at = excluded.schedule_anchor_at;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                let code = sqlite3_errcode(handle)
                RuneWeaverLog.stores.error("SQLiteSchedulerJobStore: failed preparing job write (code \(code)); job \(job.id) kept in memory only.")
                return
            }
            defer { sqlite3_finalize(statement) }

            bindWriteParameters(statement: statement, job: job)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                let code = sqlite3_errcode(handle)
                RuneWeaverLog.stores.error("SQLiteSchedulerJobStore: failed writing job \(job.id) (code \(code)); in-memory state is ahead of disk.")
                return
            }
        }

        private static func bindWriteParameters(statement: OpaquePointer?, job: SchedulerJob) {
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
            bindOptionalDate(statement, index: 15, value: job.lastSuccessfulRunEndedAt)
            SQLiteHelpers.bindInt64(statement, index: 16, value: job.emailReportJob ? 1 : 0)
            SQLiteHelpers.bindText(statement, index: 17, value: job.watcherSource?.rawValue)
            SQLiteHelpers.bindText(statement, index: 18, value: encodeJSONColumn(job.rules))
            SQLiteHelpers.bindInt64(statement, index: 19, value: job.calendarLeadTimeMinutes.map { Int64($0) })
            SQLiteHelpers.bindText(statement, index: 20, value: encodeJSONColumn(job.calendarNames))
            SQLiteHelpers.bindText(statement, index: 21, value: job.pollFrom)
            SQLiteHelpers.bindText(statement, index: 22, value: job.pollSubject)
            SQLiteHelpers.bindInt64(statement, index: 23, value: job.pollUnreadOnly ? 1 : 0)
            SQLiteHelpers.bindInt64(statement, index: 24, value: job.pollSinceDays.map { Int64($0) })
            SQLiteHelpers.bindText(statement, index: 25, value: job.misfirePolicy.rawValue)
            bindOptionalDate(statement, index: 26, value: job.lastScheduledSlotAt)
            bindOptionalDate(statement, index: 27, value: job.scheduleAnchorAt)
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

        private static func decodeOptionalDate(_ statement: OpaquePointer?, index: Int32) -> Date? {
            guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
            let value = SQLiteHelpers.columnDouble(statement, index: index)
            return value == 0 ? nil : Date(timeIntervalSince1970: value)
        }

        private static func bindOptionalDate(_ statement: OpaquePointer?, index: Int32, value: Date?) {
            if let value {
                SQLiteHelpers.bindDouble(statement, index: index, value: value.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(statement, index)
            }
        }

        private static func decodeJSONColumn<T: Decodable>(_ statement: OpaquePointer?, index: Int32) -> T? {
            guard let raw = SQLiteHelpers.columnText(statement, index: index),
                  let data = raw.data(using: .utf8)
            else {
                return nil
            }
            return try? JSONDecoder().decode(T.self, from: data)
        }

        private static func encodeJSONColumn(_ value: some Encodable?) -> String? {
            guard let value, let data = try? JSONEncoder().encode(value) else { return nil }
            return String(data: data, encoding: .utf8)
        }

        private static func normalizedNonEmpty(_ raw: String?) -> String? {
            guard let raw else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
#endif

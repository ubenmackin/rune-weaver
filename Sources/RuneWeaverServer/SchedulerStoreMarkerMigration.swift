// Rune Weaver Server — One-shot migration of legacy email-report markers into job cursors.

import Foundation
import RuneWeaverCore
#if canImport(SQLite3)
    import SQLite3
#endif

/// One job cursor seeded by the legacy email-report marker migration.
public struct SchedulerMarkerSeed: Sendable, Equatable {
    /// Job whose run cursor advanced.
    public let jobID: UUID
    /// Instant the consumed marker carried, bounded by the boot instant.
    public let seededAt: Date

    /// Creates one seeded-cursor record.
    public init(jobID: UUID, seededAt: Date) {
        self.jobID = jobID
        self.seededAt = seededAt
    }
}

/// Outcome of the one-shot legacy email-report marker migration.
///
/// The report is the audit record for a seeded cursor jump: consumed markers
/// are deleted, so without it the only trace of the jump would be the cursor
/// itself.
public struct SchedulerMarkerMigrationReport: Sendable, Equatable {
    /// Cursors seeded from the newest admissible marker date, oldest job first.
    public let seeds: [SchedulerMarkerSeed]
    /// Markers deleted once a durable cursor covered them.
    public let deletedMarkerCount: Int
    /// True when a previously recorded latch short-circuited this boot, so the
    /// report describes a sweep that never ran rather than one that found
    /// nothing.
    public let alreadyConsumed: Bool

    /// Creates a migration report.
    public init(
        seeds: [SchedulerMarkerSeed] = [],
        deletedMarkerCount: Int = 0,
        alreadyConsumed: Bool = false
    ) {
        self.seeds = seeds
        self.deletedMarkerCount = deletedMarkerCount
        self.alreadyConsumed = alreadyConsumed
    }

    /// Report for a boot that migrated nothing.
    public static let none = SchedulerMarkerMigrationReport()

    /// Report for a boot whose sweep the durable latch already consumed.
    public static let skipped = SchedulerMarkerMigrationReport(alreadyConsumed: true)

    /// Number of cursors the migration advanced.
    public var seededCount: Int {
        seeds.count
    }

    /// One-line audit summary carrying job identifiers plus seeded instants,
    /// never marker fact content.
    public var auditSummary: String {
        if alreadyConsumed {
            return "sweep already consumed by an earlier boot; no cursors seeded"
        }
        guard !seeds.isEmpty || deletedMarkerCount > 0 else {
            return "no legacy email-report markers consumed"
        }
        guard !seeds.isEmpty else {
            // Reachable once an unparseable marker-shaped fact is swept under a
            // cursor a real run already produced, so the line must not claim a
            // cursor moved when only recall was cleaned.
            return "deleted \(deletedMarkerCount) marker(s) behind an existing cursor; no cursors seeded"
        }
        let seeded = seeds
            .map { "\($0.jobID.uuidString)@\(SchedulerRunBookkeeping.schedulerCursorTimestampString(from: $0.seededAt))" }
            .joined(separator: ", ")
        return "seeded \(seeds.count) cursor(s): \(seeded); deleted \(deletedMarkerCount) marker(s)"
    }
}

extension SchedulerStore {
    /// Seeds owning job cursors from legacy email-report marker facts, once.
    ///
    /// The sweep is strictly one-shot: a durable flag row in the same episodes
    /// database records consumption, so a fact written after the migration can
    /// never move a cursor again, and memory-only stores fall back to a
    /// per-process latch. Seeding is bounded to the boot instant, so a marker
    /// dated in the future never advances a cursor, and targets are real poll
    /// jobs or the owner-set email-report flag — never prompt text.
    ///
    /// An empty email target set seeds no cursors and deletes no markers, so
    /// deleting markers with no cursor to seed can never discard the window and
    /// force a full rescan; the latch stays unset so a later boot retries once
    /// such a job exists.
    ///
    /// Marker-shaped facts are the deletable unit, not the parseable subset: a
    /// reserved-shape fact whose text carries no readable date is still run
    /// bookkeeping the agent left in memory, so a durable cursor retires it with
    /// the dated markers instead of leaving it behind to compete in recall.
    ///
    /// A delete that fails keeps the latch unset: the sweep returns its report
    /// without recording consumption, so a later boot retries instead of
    /// leaving a survivor to pollute recall under a latch that claims the
    /// sweep already finished.
    @discardableResult
    public func migrateEmailReportMarkers(memoryEngine: MemoryEngine) async -> SchedulerMarkerMigrationReport {
        guard !markerMigrationConsumed else { return .skipped }
        if await markerMigrationFlagRecorded() {
            markerMigrationConsumed = true
            return .skipped
        }
        let bootInstant = Date()
        let facts = await memoryEngine.allSemanticFacts()
        // Every marker-shaped fact with its parsed instant, if the text carries
        // one: the whole shape set is the sweep's unit of work, not the subset
        // that happens to parse.
        let markers = facts
            .filter { Self.isEmailReportMarker($0.content) }
            .map { fact -> (id: UUID, instant: Date?) in
                (fact.id, Self.embeddedRunDate(in: fact.content))
            }
        guard !markers.isEmpty else {
            // No marker-shaped fact survives anywhere, so the sweep is finished
            // and the durable latch keeps every later boot out of semantic
            // memory.
            await recordMarkerMigrationConsumed(seeds: [], deletedMarkerCount: 0)
            return .none
        }
        let targets = jobs.values.filter { Self.isEmailJob($0) }
        guard !targets.isEmpty else { return .none }
        let dated = markers.compactMap { marker -> (UUID, Date)? in
            guard let instant = marker.instant else { return nil }
            return (marker.id, instant)
        }
        let admissible = dated.filter { $0.1 <= bootInstant }
        if admissible.count < dated.count {
            // A marker dated after this boot cannot record a real run, so it is
            // neither seeded nor consumed: refusing it keeps the evidence.
            RuneWeaverLog.scheduler.warning(
                "Scheduler marker migration: ignored \(dated.count - admissible.count) marker(s) dated after the boot instant."
            )
        }
        var seeds: [SchedulerMarkerSeed] = []
        if let newest = admissible.map(\.1).max() {
            for target in targets.sorted(by: { $0.createdAt < $1.createdAt }) {
                guard let current = jobs[target.id] else { continue }
                // A cursor at or past the newest marker is already current, so only
                // a missing or older cursor advances to the seeding below.
                let needsCursorUpdate = current.lastSuccessfulRunEndedAt.map { $0 < newest } ?? true
                guard needsCursorUpdate else { continue }
                var updated = current
                updated.lastSuccessfulRunEndedAt = newest
                updated.updatedAt = Date()
                jobs[target.id] = updated
                if let dbPath {
                    #if canImport(SQLite3)
                        let jobToWrite = updated
                        await SQLiteSerialIO.runUncancellable {
                            SQLiteSchedulerJobStore.write(job: jobToWrite, dbPath: dbPath)
                        }
                    #endif
                }
                seeds.append(SchedulerMarkerSeed(jobID: target.id, seededAt: newest))
            }
        }
        // Only delete markers covered by a durable cursor: the newly seeded
        // date or an already-newer cursor. Anything beyond coverage stays.
        let coverage = jobs.values.filter { Self.isEmailJob($0) }.compactMap(\.lastSuccessfulRunEndedAt).max()
        guard let coverage else {
            return SchedulerMarkerMigrationReport(seeds: seeds)
        }
        var deleted = 0
        for marker in markers {
            // A marker shaped like reserved bookkeeping is agent-written evidence
            // of a run window, so a covering cursor retires it whether or not its
            // text happened to parse; a marker dated beyond the cursor stays.
            if let instant = marker.instant, instant > coverage {
                continue
            }
            do {
                try await memoryEngine.removeFactThrowing(id: marker.id)
            } catch {
                // `removeFactThrowing` reports a cancelled vector-store write as
                // a semantic failure, so the task flag is the only honest reading
                // of cancellation at this boundary: a cancelled boot stops the
                // sweep where it stands and the cancellation propagates instead
                // of masquerading as a delete failure.
                guard !Task.isCancelled else {
                    return SchedulerMarkerMigrationReport(seeds: seeds, deletedMarkerCount: deleted)
                }
                // A remove that threw left the marker in semantic memory, so it
                // never counts: the latch stays unset and a later boot retries
                // rather than being consumed while a survivor pollutes recall.
                RuneWeaverLog.scheduler.warning(
                    "Scheduler marker migration: failed deleting marker fact \(marker.id): \(error.localizedDescription)"
                )
                return SchedulerMarkerMigrationReport(seeds: seeds, deletedMarkerCount: deleted)
            }
            deleted += 1
        }
        guard deleted == markers.count else {
            // A marker-shaped fact outlived coverage — a date the durable cursor
            // has yet to reach — so consuming the latch now would strand it in
            // recall forever. Leaving the latch unset retries on a later boot.
            return SchedulerMarkerMigrationReport(seeds: seeds, deletedMarkerCount: deleted)
        }
        // Only a verifiably empty sweep latches: reaching here means every
        // marker-shaped fact is confirmed gone, because a delete failure or a
        // cancelled boot returned above without touching the latch.
        await recordMarkerMigrationConsumed(seeds: seeds, deletedMarkerCount: deleted)
        return SchedulerMarkerMigrationReport(seeds: seeds, deletedMarkerCount: deleted)
    }

    /// Whether the durable marker-migration latch records a completed sweep.
    private func markerMigrationFlagRecorded() async -> Bool {
        guard let dbPath else { return false }
        #if canImport(SQLite3)
            return await SQLiteSerialIO.runUncancellable {
                SQLiteSchedulerMarkerMigration.hasConsumed(dbPath: dbPath)
            }
        #else
            return false
        #endif
    }

    /// Latches the marker migration in process and persists its audit record.
    ///
    /// A store without a durable path still latches in memory so a single boot
    /// never reseeds cursors from semantic facts twice.
    private func recordMarkerMigrationConsumed(seeds: [SchedulerMarkerSeed], deletedMarkerCount: Int) async {
        markerMigrationConsumed = true
        guard let dbPath else { return }
        #if canImport(SQLite3)
            let recordedSeeds = seeds
            let recordedDeleted = deletedMarkerCount
            let completedAt = Date()
            await SQLiteSerialIO.runUncancellable {
                SQLiteSchedulerMarkerMigration.recordConsumed(
                    dbPath: dbPath,
                    completedAt: completedAt,
                    seeds: recordedSeeds,
                    deletedMarkerCount: recordedDeleted
                )
            }
        #endif
    }
}

#if canImport(SQLite3)
    /// Durable one-shot latch plus audit row for the legacy marker migration.
    ///
    /// The single row is the framework's proof that the sweep already ran, so a
    /// later boot never re-derives a run cursor from agent-writable semantic
    /// memory. Seeded job identifiers and instants ride beside the latch because
    /// the consumed markers themselves are deleted, leaving this row the only
    /// surviving trace of a seeded cursor. The job and timestamp lists are
    /// index-aligned: position `i` in one names position `i` in the other.
    enum SQLiteSchedulerMarkerMigration {
        private struct MigrationError: Error {
            let message: String
        }

        /// Fixed row identifier for the single latch row.
        private static let latchID: Int64 = 1

        /// Opens the marker-migration database, creating the latch table.
        private static func open(dbPath: String) throws -> OpaquePointer? {
            // Shared busy_timeout/WAL policy lives in `SQLiteHelpers.openHandle`.
            let handle = try SQLiteHelpers.openHandle(dbPath: dbPath, unavailable: { MigrationError(message: $0) })
            try SQLiteHelpers.exec(
                handle: handle,
                sql: """
                CREATE TABLE IF NOT EXISTS scheduler_marker_migrations(
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    completed_at REAL NOT NULL,
                    seeded_count INTEGER NOT NULL,
                    deleted_marker_count INTEGER NOT NULL,
                    seeded_job_ids TEXT NOT NULL,
                    seeded_timestamps TEXT NOT NULL
                );
                """,
                failure: { MigrationError(message: $0) }
            )
            return handle
        }

        /// Whether the durable latch records a completed sweep.
        ///
        /// An unreadable database fails open to "not yet migrated" so a broken
        /// file can never strand legacy markers; markers written after this
        /// change are rejected at every write boundary regardless.
        static func hasConsumed(dbPath: String) -> Bool {
            guard let handle = SQLiteOpenHelper.openLogged(
                dbPath: dbPath,
                storeName: "SQLiteSchedulerMarkerMigration",
                fallbackNote: "marker migration latch treated as unset",
                open: { try open(dbPath: dbPath) }
            ) else {
                return false
            }
            defer { sqlite3_close(handle) }

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "SELECT completed_at FROM scheduler_marker_migrations WHERE id = ?;", -1, &statement, nil) == SQLITE_OK else {
                return false
            }
            defer { sqlite3_finalize(statement) }
            SQLiteHelpers.bindInt64(statement, index: 1, value: latchID)
            return sqlite3_step(statement) == SQLITE_ROW
        }

        /// Persists the latch plus the seeded-cursor audit detail.
        static func recordConsumed(dbPath: String, completedAt: Date, seeds: [SchedulerMarkerSeed], deletedMarkerCount: Int) {
            guard let handle = SQLiteOpenHelper.openLogged(
                dbPath: dbPath,
                storeName: "SQLiteSchedulerMarkerMigration",
                fallbackNote: "marker migration latch kept in memory only and will not survive restart",
                open: { try open(dbPath: dbPath) }
            ) else {
                return
            }
            defer { sqlite3_close(handle) }

            let sql = """
            INSERT INTO scheduler_marker_migrations(
                id, completed_at, seeded_count, deleted_marker_count, seeded_job_ids, seeded_timestamps
            )
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                completed_at = excluded.completed_at,
                seeded_count = excluded.seeded_count,
                deleted_marker_count = excluded.deleted_marker_count,
                seeded_job_ids = excluded.seeded_job_ids,
                seeded_timestamps = excluded.seeded_timestamps;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                let code = sqlite3_errcode(handle)
                RuneWeaverLog.stores.error("SQLiteSchedulerMarkerMigration: failed preparing latch write (code \(code)); latch kept in memory only.")
                return
            }
            defer { sqlite3_finalize(statement) }

            SQLiteHelpers.bindInt64(statement, index: 1, value: latchID)
            SQLiteHelpers.bindDouble(statement, index: 2, value: completedAt.timeIntervalSince1970)
            SQLiteHelpers.bindInt64(statement, index: 3, value: Int64(seeds.count))
            SQLiteHelpers.bindInt64(statement, index: 4, value: Int64(deletedMarkerCount))
            SQLiteHelpers.bindText(statement, index: 5, value: seeds.map(\.jobID.uuidString).joined(separator: ","))
            SQLiteHelpers.bindText(
                statement,
                index: 6,
                value: seeds.map { String($0.seededAt.timeIntervalSince1970) }.joined(separator: ",")
            )
            guard sqlite3_step(statement) == SQLITE_DONE else {
                let code = sqlite3_errcode(handle)
                RuneWeaverLog.stores.error("SQLiteSchedulerMarkerMigration: failed writing latch (code \(code)); latch kept in memory only.")
                return
            }
        }
    }
#endif

// Rune Weaver Core — SQLite-backed durable store for long-horizon goals.
//
// Persists goals, their ordered steps, and the append-only audit events in
// the shared `episodes.db` file alongside sessions, episodes, trust grants,
// and run logs. Tables are created additively (`CREATE TABLE IF NOT EXISTS`)
// so opening a database that already carries conversations never disturbs
// existing rows. Blocking SQLite work runs off the actor executor through
// the shared serial store queue, mirroring the episodic store, and every
// multi-row mutation commits in one transaction so a crash can never leave
// a goal without its steps or its audit trail.

import Foundation

#if canImport(SQLite3)
    import SQLite3
#endif

/// Failures raised by ``GoalStore``.
public enum GoalStoreError: Error, Sendable, Equatable {
    /// The SQLite store could not be opened or migrated.
    case storeUnavailable(String)
    /// A read or write against the store failed.
    case persistenceFailed(String)
    /// The referenced goal or step does not exist.
    case notFound(String)
}

/// Protocol seam for goal persistence, so engines can substitute fakes.
///
/// The actor below is the production implementation; the protocol exists so
/// schedulers and future engines depend on behavior rather than SQLite.
public protocol GoalStoring: Sendable {
    /// Persists a goal plus its ordered steps and a creation audit event.
    func create(goal: Goal, steps: [GoalStep]) async throws
    /// Reads one goal by identifier.
    func goal(id: UUID) async throws -> Goal?
    /// Lists goals, optionally filtered by lifecycle state and bounded by `limit`.
    /// A nil limit reads all matching rows; callers listing for display must
    /// pass a bound so the SQL carries the LIMIT instead of slicing in memory.
    func list(status: GoalStatus?, limit: Int?) async throws -> [Goal]
    /// Replaces the unstarted portion of a plan and records a plan event.
    func replacePlan(goalID: UUID, steps: [GoalStep]) async throws
    /// Moves one step to a new state and records the matching audit event.
    func setStepStatus(
        goalID: UUID,
        stepID: UUID,
        status: StepStatus,
        notes: String?,
        lastRunID: UUID?
    ) async throws
    /// Returns active goals whose due time has arrived, inclusive of the boundary.
    func advanceDue(now: Date) async throws -> [Goal]
    /// Pushes a goal's next due time forward.
    func markAdvanced(goalID: UUID, nextDueAt: Date?) async throws
    /// Moves a goal to a new lifecycle state and records the matching event.
    func setStatus(goalID: UUID, status: GoalStatus) async throws
    /// Edits a goal's title, statement, and cadence in place, returning the updated row.
    func updateDetails(
        goalID: UUID,
        title: String?,
        statement: String?,
        stepIntervalMinutes: Int?
    ) async throws -> Goal
    /// Appends a freeform or typed audit entry.
    @discardableResult
    func appendEvent(goalID: UUID, kind: GoalEventKind, message: String) async throws -> GoalEvent
    /// Reads the most-recent audit trail, returned oldest first, bounded by `limit`.
    func events(goalID: UUID, limit: Int?) async throws -> [GoalEvent]
    /// Counts goals currently in the active state.
    func activeGoalCount() async throws -> Int
    /// Reads a goal's steps ordered by ordinal.
    func steps(goalID: UUID) async throws -> [GoalStep]
    /// Deletes a goal plus its steps and events.
    func delete(goalID: UUID) async throws
    /// Returns the lowest-ordinal pending or in-progress step, if any.
    func nextActionableStep(goalID: UUID) async throws -> GoalStep?
    /// Arms one event trigger on a goal.
    func addTrigger(goalID: UUID, eventKind: String, pattern: String?, cooldownMinutes: Int) async throws -> GoalTrigger
    /// Removes every trigger armed on a goal.
    func removeTriggers(goalID: UUID) async throws
    /// Replaces a goal's entire trigger set in one transaction.
    ///
    /// The delete and the inserts commit together, so a mid-replacement failure
    /// never leaves the goal with zero or partial triggers the way a separate
    /// remove-then-add sequence would. The set is capped at the absolute
    /// per-goal bound so direct store callers stay within the same ceiling the
    /// route layer enforces.
    func replaceTriggers(goalID: UUID, drafts: [GoalTriggerDraft]) async throws
    /// Reads a goal's triggers, oldest first.
    func triggers(for goalID: UUID) async throws -> [GoalTrigger]
    /// Settles observed events against every active goal's triggers.
    func fireMatchingTriggers(events: [GoalObservedEvent], now: Date) async throws -> [GoalTriggerFire]
    /// Reads goal audit events created after `since`, newest first, bounded by `limit`.
    func observedEvents(since: Date, limit: Int?) async throws -> [GoalObservedEvent]
}

/// Convenience overloads so callers can omit the bound without a protocol-level
/// default argument. The full two-parameter form stays the single requirement
/// so unbounded reads still spell `nil` explicitly and ride the same SQL path.
extension GoalStoring {
    /// Lists goals filtered by state with no row bound.
    public func list(status: GoalStatus?) async throws -> [Goal] {
        try await list(status: status, limit: nil)
    }

    /// Lists every goal with no filter and no row bound.
    public func list() async throws -> [Goal] {
        try await list(status: nil, limit: nil)
    }
}

/// Actor-isolated SQLite store for goals, steps, and audit events.
public actor GoalStore: GoalStoring {
    /// Filesystem path of the shared SQLite database.
    ///
    /// Held `nonisolated` so paired stores over the same file can be built
    /// synchronously without an actor hop for an immutable path; the value
    /// never mutates after initialization, so no isolation protects it.
    public nonisolated let dbPath: String
    /// Maximum rows returned per bounded read.
    private static let maxResults = 1000

    /// Creates a store over the shared database file.
    /// - Parameter dbPath: SQLite file path (the same `episodes.db` used by sessions and run logs).
    public init(dbPath: String) {
        self.dbPath = dbPath
    }

    /// Persists a goal, its ordered steps, and a creation event atomically.
    public func create(goal: Goal, steps: [GoalStep]) async throws {
        let dbPath = self.dbPath
        try await SQLiteSerialIO.run {
            try SQLiteGoalStore.create(goal: goal, steps: steps, dbPath: dbPath)
        }
    }

    /// Reads one goal by identifier, or nil when absent.
    public func goal(id: UUID) async throws -> Goal? {
        let dbPath = self.dbPath
        return try await SQLiteSerialIO.run {
            try SQLiteGoalStore.goal(id: id, dbPath: dbPath)
        }
    }

    /// Lists goals oldest first, optionally filtered by lifecycle state and bounded by `limit`.
    /// The bound rides the SQL `LIMIT` so wide listings never materialize every row.
    public func list(status: GoalStatus? = nil, limit: Int? = nil) async throws -> [Goal] {
        if let limit, limit <= 0 {
            return []
        }
        let clamped = limit.map { min($0, Self.maxResults) }
        let dbPath = self.dbPath
        return try await SQLiteSerialIO.run {
            try SQLiteGoalStore.list(status: status, limit: clamped, dbPath: dbPath)
        }
    }

    /// Swaps the unstarted pending rows for a fresh step list.
    ///
    /// Started and finished work is never rewritten: only `pending` rows are
    /// removed, so in-flight and completed history survives a replan.
    public func replacePlan(goalID: UUID, steps: [GoalStep]) async throws {
        let dbPath = self.dbPath
        try await SQLiteSerialIO.run {
            try SQLiteGoalStore.replacePlan(goalID: goalID, steps: steps, dbPath: dbPath)
        }
    }

    /// Moves one step to a new state, stamps both step and goal, and logs the move.
    public func setStepStatus(
        goalID: UUID,
        stepID: UUID,
        status: StepStatus,
        notes: String? = nil,
        lastRunID: UUID? = nil
    ) async throws {
        let dbPath = self.dbPath
        try await SQLiteSerialIO.run {
            try SQLiteGoalStore.setStepStatus(
                goalID: goalID,
                stepID: stepID,
                status: status,
                notes: notes,
                lastRunID: lastRunID,
                dbPath: dbPath
            )
        }
    }

    /// Returns active goals whose due time is at or before `now`.
    ///
    /// The comparison is inclusive so a goal due exactly now fires instead of
    /// slipping a full interval when the scheduler ticks on the boundary.
    public func advanceDue(now: Date) async throws -> [Goal] {
        let dbPath = self.dbPath
        return try await SQLiteSerialIO.run {
            try SQLiteGoalStore.advanceDue(now: now, dbPath: dbPath)
        }
    }

    /// Pushes a goal's next due time forward and refreshes its stamp.
    public func markAdvanced(goalID: UUID, nextDueAt: Date?) async throws {
        let dbPath = self.dbPath
        try await SQLiteSerialIO.run {
            try SQLiteGoalStore.markAdvanced(goalID: goalID, nextDueAt: nextDueAt, dbPath: dbPath)
        }
    }

    /// Moves a goal to a new lifecycle state and records the matching audit event.
    public func setStatus(goalID: UUID, status: GoalStatus) async throws {
        let dbPath = self.dbPath
        try await SQLiteSerialIO.run {
            try SQLiteGoalStore.setStatus(goalID: goalID, status: status, dbPath: dbPath)
        }
    }

    /// Edits a goal's title, statement, and cadence in place.
    ///
    /// Nil leaves its column untouched so partial patches never wipe a field
    /// with an absent key; the stamp always refreshes so list ordering observes
    /// the edit. Unknown goals throw `notFound` instead of silently inserting.
    /// A present cadence outside the steady range fails instead of truncating
    /// so direct store callers get the same bound the routes enforce.
    /// - Parameters:
    ///   - goalID: Goal to edit.
    ///   - title: New title, or nil to keep the stored one.
    ///   - statement: New statement, or nil to keep the stored one.
    ///   - stepIntervalMinutes: New cadence hint, or nil to keep the stored one.
    /// - Returns: Updated goal snapshot.
    public func updateDetails(
        goalID: UUID,
        title: String?,
        statement: String?,
        stepIntervalMinutes: Int?
    ) async throws -> Goal {
        if let stepIntervalMinutes,
           stepIntervalMinutes < GoalsConfig.minStepIntervalMinutes
           || stepIntervalMinutes > GoalsConfig.maxStepIntervalMinutes
        {
            let minCadence = GoalsConfig.minStepIntervalMinutes
            let maxCadence = GoalsConfig.maxStepIntervalMinutes
            throw GoalStoreError.persistenceFailed(
                "stepIntervalMinutes must be between \(minCadence) and \(maxCadence) (got \(stepIntervalMinutes))"
            )
        }
        let dbPath = self.dbPath
        return try await SQLiteSerialIO.run {
            try SQLiteGoalStore.updateDetails(
                goalID: goalID,
                title: title,
                statement: statement,
                stepIntervalMinutes: stepIntervalMinutes,
                dbPath: dbPath
            )
        }
    }

    /// Appends one audit entry and returns it with its assigned rowid.
    @discardableResult
    public func appendEvent(goalID: UUID, kind: GoalEventKind, message: String) async throws -> GoalEvent {
        let dbPath = self.dbPath
        return try await SQLiteSerialIO.run {
            try SQLiteGoalStore.appendEvent(goalID: goalID, kind: kind, message: message, dbPath: dbPath)
        }
    }

    /// Reads the most-recent audit trail, returned oldest first, bounded by `limit`.
    public func events(goalID: UUID, limit: Int? = nil) async throws -> [GoalEvent] {
        if let limit, limit <= 0 {
            return []
        }
        let clamped = limit.map { min($0, Self.maxResults) }
        let dbPath = self.dbPath
        return try await SQLiteSerialIO.run {
            try SQLiteGoalStore.events(goalID: goalID, limit: clamped, dbPath: dbPath)
        }
    }

    /// Counts goals currently in the active state.
    public func activeGoalCount() async throws -> Int {
        let dbPath = self.dbPath
        return try await SQLiteSerialIO.run {
            try SQLiteGoalStore.activeGoalCount(dbPath: dbPath)
        }
    }

    /// Reads a goal's steps ordered by ordinal.
    public func steps(goalID: UUID) async throws -> [GoalStep] {
        let dbPath = self.dbPath
        return try await SQLiteSerialIO.run {
            try SQLiteGoalStore.steps(goalID: goalID, dbPath: dbPath)
        }
    }

    /// Deletes a goal plus its steps and events. Unknown goals are a no-op.
    public func delete(goalID: UUID) async throws {
        let dbPath = self.dbPath
        try await SQLiteSerialIO.run {
            try SQLiteGoalStore.delete(goalID: goalID, dbPath: dbPath)
        }
    }

    /// Returns the lowest-ordinal pending or in-progress step.
    ///
    /// Blocked, done, and skipped rows are looked past so one stalled step
    /// never wedges the whole goal; nil means nothing remains actionable, and
    /// the engine derives achievement from that emptiness.
    public func nextActionableStep(goalID: UUID) async throws -> GoalStep? {
        let dbPath = self.dbPath
        return try await SQLiteSerialIO.run {
            try SQLiteGoalStore.nextActionableStep(goalID: goalID, dbPath: dbPath)
        }
    }

    /// Arms one event trigger on a goal, rejecting unknown or blank targets.
    ///
    /// The cooldown floors at the configured minimum so a direct store caller
    /// cannot arm a tight re-fire loop the engine and route layers would refuse.
    public func addTrigger(goalID: UUID, eventKind: String, pattern: String?, cooldownMinutes: Int) async throws -> GoalTrigger {
        let trimmedKind = eventKind.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKind.isEmpty else {
            throw GoalStoreError.persistenceFailed("eventKind must not be empty")
        }
        let dbPath = self.dbPath
        return try await SQLiteSerialIO.run {
            try SQLiteGoalStore.addTrigger(
                goalID: goalID,
                eventKind: trimmedKind,
                pattern: pattern,
                cooldownMinutes: max(GoalsConfig.minTriggerCooldownMinutes, cooldownMinutes),
                dbPath: dbPath
            )
        }
    }

    /// Removes every trigger armed on a goal. Unknown goals are a no-op.
    public func removeTriggers(goalID: UUID) async throws {
        let dbPath = self.dbPath
        try await SQLiteSerialIO.run {
            try SQLiteGoalStore.removeTriggers(goalID: goalID, dbPath: dbPath)
        }
    }

    /// Replaces a goal's entire trigger set atomically.
    ///
    /// Blank kinds drop and nil cooldowns inherit the configured default before
    /// the single transaction runs, so the store never arms an unmatchable or
    /// immediately-repeating trigger; every cooldown floors at the configured
    /// minimum so a direct store caller cannot bypass the re-fire guard the
    /// engine and route layers enforce. The surviving set is capped at the
    /// absolute per-goal bound so direct store callers cannot arm more triggers
    /// than any route would send.
    public func replaceTriggers(goalID: UUID, drafts: [GoalTriggerDraft]) async throws {
        let normalized = drafts.compactMap { draft -> GoalTriggerDraft? in
            let kind = draft.eventKind.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !kind.isEmpty else { return nil }
            let cooldown = max(GoalsConfig.minTriggerCooldownMinutes, draft.cooldownMinutes ?? GoalsConfig.defaultTriggerCooldownMinutes)
            return GoalTriggerDraft(eventKind: kind, pattern: draft.pattern, cooldownMinutes: cooldown)
        }
        // Fail-closed on the absolute bound: the route layer still applies its
        // tighter configured budget first, but a direct store caller bypasses
        // that prefix cap, so the store enforces the bound itself.
        let capped = Array(normalized.prefix(GoalsConfig.maxTriggersPerGoalBound))
        let dbPath = self.dbPath
        try await SQLiteSerialIO.run {
            try SQLiteGoalStore.replaceTriggers(goalID: goalID, drafts: capped, dbPath: dbPath)
        }
    }

    /// Reads a goal's triggers, oldest first.
    public func triggers(for goalID: UUID) async throws -> [GoalTrigger] {
        let dbPath = self.dbPath
        return try await SQLiteSerialIO.run {
            try SQLiteGoalStore.triggers(for: goalID, dbPath: dbPath)
        }
    }

    /// Settles observed events against active goals' triggers, pulling each
    /// matched goal's due date forward to `now`.
    public func fireMatchingTriggers(events: [GoalObservedEvent], now: Date) async throws -> [GoalTriggerFire] {
        let dbPath = self.dbPath
        return try await SQLiteSerialIO.run {
            try SQLiteGoalStore.fireMatchingTriggers(events: events, now: now, dbPath: dbPath)
        }
    }

    /// Reads goal audit events created after `since`, newest first.
    public func observedEvents(since: Date, limit: Int? = nil) async throws -> [GoalObservedEvent] {
        if let limit, limit <= 0 {
            return []
        }
        let clamped = limit.map { min($0, Self.maxResults) }
        let dbPath = self.dbPath
        return try await SQLiteSerialIO.run {
            try SQLiteGoalStore.observedEvents(since: since, limit: clamped, dbPath: dbPath)
        }
    }
}

#if canImport(SQLite3)
    // SQLiteGoalStore keeps every goal row statement in one place so the shared episodes.db schema stays auditable together.

    /// Blocking SQLite implementation behind ``GoalStore``.
    enum SQLiteGoalStore {
        /// Opens (creating parent directories) and migrates the database.
        ///
        /// Tables are additive only: existing session, message, episode,
        /// trust-grant, scheduler, and run-log tables are never altered or
        /// dropped, so a shared `episodes.db` keeps its history intact.
        /// - Parameter dbPath: SQLite file path. `~` is expanded.
        /// - Returns: Open database handle. Caller must close it.
        static func open(dbPath: String) throws -> OpaquePointer? {
            // Shared busy_timeout/WAL policy lives in `SQLiteHelpers.openHandle`.
            let handle = try SQLiteHelpers.openHandle(dbPath: dbPath, unavailable: GoalStoreError.storeUnavailable)
            try SQLiteHelpers.exec(
                handle: handle,
                sql: """
                CREATE TABLE IF NOT EXISTS goals(
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    statement TEXT NOT NULL,
                    status TEXT NOT NULL,
                    step_interval_minutes INTEGER NOT NULL,
                    next_due_at REAL,
                    origin_session_id TEXT,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS goal_steps(
                    id TEXT PRIMARY KEY,
                    goal_id TEXT NOT NULL,
                    ordinal INTEGER NOT NULL,
                    title TEXT NOT NULL,
                    status TEXT NOT NULL,
                    notes TEXT,
                    last_run_id TEXT,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS goal_events(
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    goal_id TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    message TEXT NOT NULL,
                    created_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS goal_triggers(
                    id TEXT PRIMARY KEY,
                    goal_id TEXT NOT NULL,
                    event_kind TEXT NOT NULL,
                    pattern TEXT,
                    cooldown_minutes INTEGER NOT NULL,
                    last_fired_at REAL,
                    created_at REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_goal_steps_goal_ordinal ON goal_steps(goal_id, ordinal);
                CREATE INDEX IF NOT EXISTS idx_goal_events_goal ON goal_events(goal_id);
                CREATE INDEX IF NOT EXISTS idx_goal_triggers_goal ON goal_triggers(goal_id);
                CREATE INDEX IF NOT EXISTS idx_goals_status_due ON goals(status, next_due_at);
                """,
                failure: GoalStoreError.persistenceFailed
            )
            return handle
        }

        /// Executes a multi-statement SQL string.
        static func exec(handle: OpaquePointer?, sql: String) throws {
            try SQLiteHelpers.exec(handle: handle, sql: sql, failure: GoalStoreError.persistenceFailed)
        }

        /// Binds optional text, mapping nil to NULL.
        static func bindText(_ statement: OpaquePointer?, index: Int32, value: String?) {
            SQLiteHelpers.bindText(statement, index: index, value: value)
        }

        /// Column-text helper returning nil for NULL columns.
        static func columnText(_ statement: OpaquePointer?, index: Int32) -> String? {
            SQLiteHelpers.columnText(statement, index: index)
        }

        /// Reads the goal at the statement's current row.
        static func readGoal(_ statement: OpaquePointer?) -> Goal? {
            guard let idText = columnText(statement, index: 0),
                  let id = UUID(uuidString: idText),
                  let title = columnText(statement, index: 1),
                  let statementText = columnText(statement, index: 2),
                  let statusRaw = columnText(statement, index: 3),
                  let status = GoalStatus(rawValue: statusRaw)
            else { return nil }
            let interval = Int(sqlite3_column_int(statement, 4))
            var nextDueAt: Date?
            if sqlite3_column_type(statement, 5) != SQLITE_NULL {
                nextDueAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
            }
            var originSessionID: UUID?
            if let originText = columnText(statement, index: 6), !originText.isEmpty {
                originSessionID = UUID(uuidString: originText)
            }
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
            let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 8))
            return Goal(
                id: id,
                title: title,
                statement: statementText,
                status: status,
                stepIntervalMinutes: interval,
                nextDueAt: nextDueAt,
                originSessionID: originSessionID,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        }

        /// Inserts or replaces one goal row.
        static func insertGoal(_ goal: Goal, handle: OpaquePointer?) throws {
            let sql = "INSERT INTO goals(id, title, statement, status, step_interval_minutes, next_due_at, origin_session_id, created_at, updated_at) "
                + "VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?) "
                + "ON CONFLICT(id) DO UPDATE SET title=excluded.title, statement=excluded.statement, status=excluded.status, "
                + "step_interval_minutes=excluded.step_interval_minutes, next_due_at=excluded.next_due_at, "
                + "origin_session_id=excluded.origin_session_id, updated_at=excluded.updated_at;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw GoalStoreError.persistenceFailed("Could not prepare goal upsert")
            }
            defer { sqlite3_finalize(statement) }
            bindText(statement, index: 1, value: goal.id.uuidString)
            bindText(statement, index: 2, value: goal.title)
            bindText(statement, index: 3, value: goal.statement)
            bindText(statement, index: 4, value: goal.status.rawValue)
            sqlite3_bind_int(statement, 5, Int32(clamping: goal.stepIntervalMinutes))
            if let due = goal.nextDueAt {
                sqlite3_bind_double(statement, 6, due.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(statement, 6)
            }
            bindText(statement, index: 7, value: goal.originSessionID?.uuidString)
            sqlite3_bind_double(statement, 8, goal.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(statement, 9, goal.updatedAt.timeIntervalSince1970)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw GoalStoreError.persistenceFailed("Could not write goal \(goal.id)")
            }
        }

        /// Whether a goal row exists on an open handle.
        static func goalExists(_ goalID: UUID, handle: OpaquePointer?) throws -> Bool {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "SELECT 1 FROM goals WHERE id = ?;", -1, &statement, nil) == SQLITE_OK else {
                throw GoalStoreError.persistenceFailed("Could not probe goal \(goalID)")
            }
            defer { sqlite3_finalize(statement) }
            bindText(statement, index: 1, value: goalID.uuidString)
            return sqlite3_step(statement) == SQLITE_ROW
        }

        /// Persists a goal, its steps, and a creation event in one transaction.
        static func create(goal: Goal, steps: [GoalStep], dbPath: String) throws {
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            try exec(handle: handle, sql: "BEGIN IMMEDIATE;")
            do {
                try insertGoal(goal, handle: handle)
                for step in steps {
                    // Re-anchor caller-built steps to the goal so a mismatched
                    // `goalID` can never orphan a row outside the new plan.
                    let anchored = GoalStep(
                        id: step.id,
                        goalID: goal.id,
                        ordinal: step.ordinal,
                        title: step.title,
                        status: step.status,
                        notes: step.notes,
                        lastRunID: step.lastRunID,
                        createdAt: step.createdAt,
                        updatedAt: step.updatedAt
                    )
                    try insertStep(anchored, handle: handle)
                }
                _ = try insertEvent(
                    goalID: goal.id,
                    kind: .created,
                    message: "Goal created with \(steps.count) steps.",
                    createdAt: Date(),
                    handle: handle
                )
                try exec(handle: handle, sql: "COMMIT;")
            } catch {
                try? exec(handle: handle, sql: "ROLLBACK;")
                throw error
            }
        }

        /// Reads one goal by identifier.
        static func goal(id: UUID, dbPath: String) throws -> Goal? {
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return nil }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            var statement: OpaquePointer?
            let sql = "SELECT id, title, statement, status, step_interval_minutes, next_due_at, origin_session_id, created_at, updated_at "
                + "FROM goals WHERE id = ?;"
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw GoalStoreError.persistenceFailed("Could not prepare goal read")
            }
            defer { sqlite3_finalize(statement) }
            bindText(statement, index: 1, value: id.uuidString)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return readGoal(statement)
        }

        /// Lists goals oldest first, optionally filtered by lifecycle state and bounded by `limit`.
        /// The bound rides the SQL `LIMIT` so wide listings never materialize every row.
        static func list(status: GoalStatus?, limit: Int?, dbPath: String) throws -> [Goal] {
            if let limit, limit <= 0 {
                return []
            }
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return [] }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            let base = "SELECT id, title, statement, status, step_interval_minutes, next_due_at, origin_session_id, created_at, updated_at FROM goals"
            let filtered = status != nil ? base + " WHERE status = ?" : base
            let ordered = filtered + " ORDER BY created_at ASC, rowid ASC"
            let sql = limit != nil ? ordered + " LIMIT ?;" : ordered + ";"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw GoalStoreError.persistenceFailed("Could not prepare goal list")
            }
            defer { sqlite3_finalize(statement) }
            var bindIndex: Int32 = 1
            if let status {
                bindText(statement, index: bindIndex, value: status.rawValue)
                bindIndex += 1
            }
            if let limit {
                sqlite3_bind_int(statement, bindIndex, SQLiteHelpers.sqliteLimit(limit))
            }
            var results: [Goal] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let goal = readGoal(statement) {
                    results.append(goal)
                }
            }
            return results
        }
    }

    // MARK: - Goal Lifecycle & Updates

    extension SQLiteGoalStore {
        /// Returns active goals due at or before `now`, earliest due first.
        static func advanceDue(now: Date, dbPath: String) throws -> [Goal] {
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return [] }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            var statement: OpaquePointer?
            let sql = "SELECT id, title, statement, status, step_interval_minutes, next_due_at, origin_session_id, created_at, updated_at "
                + "FROM goals WHERE status = ? AND next_due_at IS NOT NULL AND next_due_at <= ? "
                + "ORDER BY next_due_at ASC, created_at ASC, rowid ASC;"
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw GoalStoreError.persistenceFailed("Could not prepare due scan")
            }
            defer { sqlite3_finalize(statement) }
            bindText(statement, index: 1, value: GoalStatus.active.rawValue)
            sqlite3_bind_double(statement, 2, now.timeIntervalSince1970)
            var results: [Goal] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let goal = readGoal(statement) {
                    results.append(goal)
                }
            }
            return results
        }

        /// Pushes a goal's next due time forward.
        static func markAdvanced(goalID: UUID, nextDueAt: Date?, dbPath: String) throws {
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "UPDATE goals SET next_due_at = ?, updated_at = ? WHERE id = ?;", -1, &statement, nil) == SQLITE_OK else {
                throw GoalStoreError.persistenceFailed("Could not prepare due update")
            }
            defer { sqlite3_finalize(statement) }
            if let nextDueAt {
                sqlite3_bind_double(statement, 1, nextDueAt.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(statement, 1)
            }
            sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
            bindText(statement, index: 3, value: goalID.uuidString)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw GoalStoreError.persistenceFailed("Could not mark goal \(goalID) advanced")
            }
            guard sqlite3_changes(handle) > 0 else {
                throw GoalStoreError.notFound("No goal \(goalID)")
            }
        }

        /// Moves a goal to a new lifecycle state and logs the matching event.
        static func setStatus(goalID: UUID, status: GoalStatus, dbPath: String) throws {
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            try exec(handle: handle, sql: "BEGIN IMMEDIATE;")
            do {
                var updateStatement: OpaquePointer?
                guard sqlite3_prepare_v2(handle, "UPDATE goals SET status = ?, updated_at = ? WHERE id = ?;", -1, &updateStatement, nil) == SQLITE_OK else {
                    throw GoalStoreError.persistenceFailed("Could not prepare status update")
                }
                defer { sqlite3_finalize(updateStatement) }
                let now = Date()
                bindText(updateStatement, index: 1, value: status.rawValue)
                sqlite3_bind_double(updateStatement, 2, now.timeIntervalSince1970)
                bindText(updateStatement, index: 3, value: goalID.uuidString)
                guard sqlite3_step(updateStatement) == SQLITE_DONE else {
                    throw GoalStoreError.persistenceFailed("Could not update status for \(goalID)")
                }
                guard sqlite3_changes(handle) > 0 else {
                    throw GoalStoreError.notFound("No goal \(goalID)")
                }
                _ = try insertEvent(
                    goalID: goalID,
                    kind: eventKind(for: status),
                    message: "Status changed to \(status.rawValue).",
                    createdAt: now,
                    handle: handle
                )
                try exec(handle: handle, sql: "COMMIT;")
            } catch {
                try? exec(handle: handle, sql: "ROLLBACK;")
                throw error
            }
        }

        /// Edits title, statement, and cadence columns in place.
        ///
        /// Nil preserves its column via `COALESCE` so partial patches never wipe
        /// a field; at least one non-nil column is expected from the route layer,
        /// which validates blanks before reaching storage. A present cadence
        /// outside the steady range throws instead of truncating through the
        /// integer bind so the store boundary enforces the same bound as routes.
        static func updateDetails(
            goalID: UUID,
            title: String?,
            statement: String?,
            stepIntervalMinutes: Int?,
            dbPath: String
        ) throws -> Goal {
            if let stepIntervalMinutes,
               stepIntervalMinutes < GoalsConfig.minStepIntervalMinutes
               || stepIntervalMinutes > GoalsConfig.maxStepIntervalMinutes
            {
                let minCadence = GoalsConfig.minStepIntervalMinutes
                let maxCadence = GoalsConfig.maxStepIntervalMinutes
                throw GoalStoreError.persistenceFailed(
                    "stepIntervalMinutes must be between \(minCadence) and \(maxCadence) (got \(stepIntervalMinutes))"
                )
            }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            var updateStatement: OpaquePointer?
            guard sqlite3_prepare_v2(
                handle,
                "UPDATE goals SET title = COALESCE(?, title), statement = COALESCE(?, statement), "
                    + "step_interval_minutes = COALESCE(?, step_interval_minutes), updated_at = ? WHERE id = ?;",
                -1,
                &updateStatement,
                nil
            ) == SQLITE_OK else {
                throw GoalStoreError.persistenceFailed("Could not prepare goal edit")
            }
            defer { sqlite3_finalize(updateStatement) }
            bindText(updateStatement, index: 1, value: title)
            bindText(updateStatement, index: 2, value: statement)
            if let stepIntervalMinutes {
                sqlite3_bind_int(updateStatement, 3, Int32(stepIntervalMinutes))
            } else {
                sqlite3_bind_null(updateStatement, 3)
            }
            let now = Date()
            sqlite3_bind_double(updateStatement, 4, now.timeIntervalSince1970)
            bindText(updateStatement, index: 5, value: goalID.uuidString)
            guard sqlite3_step(updateStatement) == SQLITE_DONE else {
                throw GoalStoreError.persistenceFailed("Could not edit goal \(goalID)")
            }
            guard sqlite3_changes(handle) > 0 else {
                throw GoalStoreError.notFound("No goal \(goalID)")
            }
            var readStatement: OpaquePointer?
            let sql = "SELECT id, title, statement, status, step_interval_minutes, next_due_at, origin_session_id, created_at, updated_at "
                + "FROM goals WHERE id = ?;"
            guard sqlite3_prepare_v2(handle, sql, -1, &readStatement, nil) == SQLITE_OK else {
                throw GoalStoreError.persistenceFailed("Could not prepare edited goal read")
            }
            defer { sqlite3_finalize(readStatement) }
            bindText(readStatement, index: 1, value: goalID.uuidString)
            guard sqlite3_step(readStatement) == SQLITE_ROW, let updated = readGoal(readStatement) else {
                throw GoalStoreError.notFound("No goal \(goalID)")
            }
            return updated
        }

        /// Counts goals currently in the active or unplanned state.
        static func activeGoalCount(dbPath: String) throws -> Int {
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return 0 }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM goals WHERE status IN (?, ?);", -1, &statement, nil) == SQLITE_OK else {
                throw GoalStoreError.persistenceFailed("Could not count active goals")
            }
            defer { sqlite3_finalize(statement) }
            bindText(statement, index: 1, value: GoalStatus.active.rawValue)
            bindText(statement, index: 2, value: GoalStatus.unplanned.rawValue)
            guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int(statement, 0))
        }

        /// Deletes a goal plus its steps and events in one transaction.
        ///
        /// Each table gets its own prepared statement because finalizers bound
        /// to a loop iteration would otherwise live until the function returns
        /// and hold three statements open across the commit.
        static func delete(goalID: UUID, dbPath: String) throws {
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            try exec(handle: handle, sql: "BEGIN IMMEDIATE;")
            do {
                var triggerStatement: OpaquePointer?
                guard sqlite3_prepare_v2(handle, "DELETE FROM goal_triggers WHERE goal_id = ?;", -1, &triggerStatement, nil) == SQLITE_OK else {
                    throw GoalStoreError.persistenceFailed("Could not prepare trigger delete")
                }
                bindText(triggerStatement, index: 1, value: goalID.uuidString)
                let triggerDone = sqlite3_step(triggerStatement) == SQLITE_DONE
                sqlite3_finalize(triggerStatement)
                guard triggerDone else {
                    throw GoalStoreError.persistenceFailed("Could not delete triggers for \(goalID)")
                }
                var eventStatement: OpaquePointer?
                guard sqlite3_prepare_v2(handle, "DELETE FROM goal_events WHERE goal_id = ?;", -1, &eventStatement, nil) == SQLITE_OK else {
                    throw GoalStoreError.persistenceFailed("Could not prepare event delete")
                }
                bindText(eventStatement, index: 1, value: goalID.uuidString)
                let eventDone = sqlite3_step(eventStatement) == SQLITE_DONE
                sqlite3_finalize(eventStatement)
                guard eventDone else {
                    throw GoalStoreError.persistenceFailed("Could not delete events for \(goalID)")
                }
                var stepStatement: OpaquePointer?
                guard sqlite3_prepare_v2(handle, "DELETE FROM goal_steps WHERE goal_id = ?;", -1, &stepStatement, nil) == SQLITE_OK else {
                    throw GoalStoreError.persistenceFailed("Could not prepare step delete")
                }
                bindText(stepStatement, index: 1, value: goalID.uuidString)
                let stepDone = sqlite3_step(stepStatement) == SQLITE_DONE
                sqlite3_finalize(stepStatement)
                guard stepDone else {
                    throw GoalStoreError.persistenceFailed("Could not delete steps for \(goalID)")
                }
                var goalStatement: OpaquePointer?
                guard sqlite3_prepare_v2(handle, "DELETE FROM goals WHERE id = ?;", -1, &goalStatement, nil) == SQLITE_OK else {
                    throw GoalStoreError.persistenceFailed("Could not prepare goal delete")
                }
                bindText(goalStatement, index: 1, value: goalID.uuidString)
                let goalDone = sqlite3_step(goalStatement) == SQLITE_DONE
                sqlite3_finalize(goalStatement)
                guard goalDone else {
                    throw GoalStoreError.persistenceFailed("Could not delete goal \(goalID)")
                }
                try exec(handle: handle, sql: "COMMIT;")
            } catch {
                try? exec(handle: handle, sql: "ROLLBACK;")
                throw error
            }
        }
    }

    // MARK: - Goal Triggers

    /// Trigger persistence and matching for the goal store.
    extension SQLiteGoalStore {
        /// Decodes one `goal_triggers` row.
        static func readTrigger(_ statement: OpaquePointer?) -> GoalTrigger? {
            guard let idText = columnText(statement, index: 0),
                  let id = UUID(uuidString: idText),
                  let goalText = columnText(statement, index: 1),
                  let goalID = UUID(uuidString: goalText),
                  let eventKind = columnText(statement, index: 2)
            else { return nil }
            var lastFiredAt: Date?
            if sqlite3_column_type(statement, 5) != SQLITE_NULL {
                lastFiredAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
            }
            return GoalTrigger(
                id: id,
                goalID: goalID,
                eventKind: eventKind,
                pattern: columnText(statement, index: 3),
                cooldownMinutes: Int(sqlite3_column_int(statement, 4)),
                lastFiredAt: lastFiredAt,
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
            )
        }

        /// Inserts one trigger row.
        static func insertTrigger(_ trigger: GoalTrigger, handle: OpaquePointer?) throws {
            let sql = "INSERT INTO goal_triggers(id, goal_id, event_kind, pattern, cooldown_minutes, last_fired_at, created_at) "
                + "VALUES(?, ?, ?, ?, ?, ?, ?);"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw GoalStoreError.persistenceFailed("Could not prepare trigger insert")
            }
            defer { sqlite3_finalize(statement) }
            bindText(statement, index: 1, value: trigger.id.uuidString)
            bindText(statement, index: 2, value: trigger.goalID.uuidString)
            bindText(statement, index: 3, value: trigger.eventKind)
            bindText(statement, index: 4, value: trigger.pattern)
            sqlite3_bind_int(statement, 5, Int32(clamping: trigger.cooldownMinutes))
            if let lastFiredAt = trigger.lastFiredAt {
                sqlite3_bind_double(statement, 6, lastFiredAt.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(statement, 6)
            }
            sqlite3_bind_double(statement, 7, trigger.createdAt.timeIntervalSince1970)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw GoalStoreError.persistenceFailed("Could not write trigger for goal \(trigger.goalID)")
            }
        }

        /// Arms one trigger, rejecting orphan rows for unknown goals.
        ///
        /// The cooldown floors at the configured minimum so even a caller that
        /// reaches this layer directly cannot persist a tight re-fire loop.
        static func addTrigger(
            goalID: UUID,
            eventKind: String,
            pattern: String?,
            cooldownMinutes: Int,
            dbPath: String
        ) throws -> GoalTrigger {
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            guard try goalExists(goalID, handle: handle) else {
                throw GoalStoreError.notFound("No goal \(goalID)")
            }
            let now = Date()
            let trigger = GoalTrigger(
                goalID: goalID,
                eventKind: eventKind,
                pattern: pattern,
                cooldownMinutes: max(GoalsConfig.minTriggerCooldownMinutes, cooldownMinutes),
                lastFiredAt: nil,
                createdAt: now
            )
            try insertTrigger(trigger, handle: handle)
            return trigger
        }

        /// Replaces a goal's entire trigger set in one transaction.
        ///
        /// The goal existence check, the delete, and every insert share one
        /// `BEGIN IMMEDIATE` transaction, so a failure or crash can never leave
        /// the goal with a partial set while the caller sees an error. Unknown
        /// goals throw before any row is touched. The inserts stop at the
        /// absolute per-goal bound so a caller that bypasses the actor wrapper
        /// still cannot arm an unbounded set.
        static func replaceTriggers(goalID: UUID, drafts: [GoalTriggerDraft], dbPath: String) throws {
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            try exec(handle: handle, sql: "BEGIN IMMEDIATE;")
            do {
                guard try goalExists(goalID, handle: handle) else {
                    throw GoalStoreError.notFound("No goal \(goalID)")
                }
                var deleteStatement: OpaquePointer?
                guard sqlite3_prepare_v2(handle, "DELETE FROM goal_triggers WHERE goal_id = ?;", -1, &deleteStatement, nil) == SQLITE_OK else {
                    throw GoalStoreError.persistenceFailed("Could not prepare trigger delete")
                }
                bindText(deleteStatement, index: 1, value: goalID.uuidString)
                let deleted = sqlite3_step(deleteStatement) == SQLITE_DONE
                sqlite3_finalize(deleteStatement)
                guard deleted else {
                    throw GoalStoreError.persistenceFailed("Could not delete triggers for \(goalID)")
                }
                let now = Date()
                for draft in drafts.prefix(GoalsConfig.maxTriggersPerGoalBound) {
                    let trigger = GoalTrigger(
                        goalID: goalID,
                        eventKind: draft.eventKind,
                        pattern: draft.pattern,
                        cooldownMinutes: max(GoalsConfig.minTriggerCooldownMinutes, draft.cooldownMinutes ?? GoalsConfig.defaultTriggerCooldownMinutes),
                        lastFiredAt: nil,
                        createdAt: now
                    )
                    try insertTrigger(trigger, handle: handle)
                }
                try exec(handle: handle, sql: "COMMIT;")
            } catch {
                try? exec(handle: handle, sql: "ROLLBACK;")
                throw error
            }
        }

        /// Removes every trigger armed on a goal. Missing goals are a no-op.
        static func removeTriggers(goalID: UUID, dbPath: String) throws {
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "DELETE FROM goal_triggers WHERE goal_id = ?;", -1, &statement, nil) == SQLITE_OK else {
                throw GoalStoreError.persistenceFailed("Could not prepare trigger delete")
            }
            defer { sqlite3_finalize(statement) }
            bindText(statement, index: 1, value: goalID.uuidString)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw GoalStoreError.persistenceFailed("Could not delete triggers for \(goalID)")
            }
        }

        /// Reads a goal's triggers, oldest first.
        static func triggers(for goalID: UUID, dbPath: String) throws -> [GoalTrigger] {
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return [] }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            let sql = "SELECT id, goal_id, event_kind, pattern, cooldown_minutes, last_fired_at, created_at "
                + "FROM goal_triggers WHERE goal_id = ? ORDER BY created_at ASC, rowid ASC;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw GoalStoreError.persistenceFailed("Could not prepare trigger read")
            }
            defer { sqlite3_finalize(statement) }
            bindText(statement, index: 1, value: goalID.uuidString)
            var results: [GoalTrigger] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let trigger = readTrigger(statement) {
                    results.append(trigger)
                }
            }
            return results
        }

        /// Reads every trigger belonging to an active goal.
        ///
        /// Only active goals are eligible for a wake-up: a paused or parked goal
        /// must not silently acquire a due date while it is not running.
        static func activeTriggers(handle: OpaquePointer?) throws -> [GoalTrigger] {
            let sql = "SELECT t.id, t.goal_id, t.event_kind, t.pattern, t.cooldown_minutes, t.last_fired_at, t.created_at "
                + "FROM goal_triggers t JOIN goals g ON g.id = t.goal_id "
                + "WHERE g.status = ? ORDER BY t.created_at ASC, t.rowid ASC;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw GoalStoreError.persistenceFailed("Could not prepare active trigger read")
            }
            defer { sqlite3_finalize(statement) }
            bindText(statement, index: 1, value: GoalStatus.active.rawValue)
            var results: [GoalTrigger] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let trigger = readTrigger(statement) {
                    results.append(trigger)
                }
            }
            return results
        }

        /// Settles observed events against active triggers in one transaction.
        ///
        /// Each trigger settles at most once per call: the first matching event
        /// wins and the debounce stamp moves immediately, so a burst of matching
        /// events inside one poll cannot stack repeat firings. Pulling the due
        /// date to `now` leaves the ordinary due scan to fire the goal next tick.
        static func fireMatchingTriggers(events: [GoalObservedEvent], now: Date, dbPath: String) throws -> [GoalTriggerFire] {
            guard !events.isEmpty else { return [] }
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return [] }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            try exec(handle: handle, sql: "BEGIN IMMEDIATE;")
            do {
                let candidates = try activeTriggers(handle: handle)
                var fires: [GoalTriggerFire] = []
                for trigger in candidates {
                    guard let event = events.first(where: { trigger.matches(event: $0, now: now) }) else { continue }
                    var stampStatement: OpaquePointer?
                    guard sqlite3_prepare_v2(handle, "UPDATE goal_triggers SET last_fired_at = ? WHERE id = ?;", -1, &stampStatement, nil) == SQLITE_OK else {
                        throw GoalStoreError.persistenceFailed("Could not prepare trigger stamp")
                    }
                    sqlite3_bind_double(stampStatement, 1, now.timeIntervalSince1970)
                    bindText(stampStatement, index: 2, value: trigger.id.uuidString)
                    let stamped = sqlite3_step(stampStatement) == SQLITE_DONE
                    sqlite3_finalize(stampStatement)
                    guard stamped else {
                        throw GoalStoreError.persistenceFailed("Could not stamp trigger \(trigger.id)")
                    }
                    var dueStatement: OpaquePointer?
                    guard sqlite3_prepare_v2(
                        handle,
                        "UPDATE goals SET next_due_at = ?, updated_at = ? WHERE id = ?;",
                        -1,
                        &dueStatement,
                        nil
                    ) == SQLITE_OK else {
                        throw GoalStoreError.persistenceFailed("Could not prepare trigger due update")
                    }
                    sqlite3_bind_double(dueStatement, 1, now.timeIntervalSince1970)
                    sqlite3_bind_double(dueStatement, 2, now.timeIntervalSince1970)
                    bindText(dueStatement, index: 3, value: trigger.goalID.uuidString)
                    let pulled = sqlite3_step(dueStatement) == SQLITE_DONE
                    sqlite3_finalize(dueStatement)
                    guard pulled else {
                        throw GoalStoreError.persistenceFailed("Could not pull goal \(trigger.goalID) due")
                    }
                    fires.append(GoalTriggerFire(
                        triggerID: trigger.id,
                        goalID: trigger.goalID,
                        eventKind: event.kind,
                        message: event.message,
                        firedAt: now
                    ))
                }
                try exec(handle: handle, sql: "COMMIT;")
                return fires
            } catch {
                try? exec(handle: handle, sql: "ROLLBACK;")
                throw error
            }
        }

        /// Reads goal audit events created after `since`, newest first.
        static func observedEvents(since: Date, limit: Int?, dbPath: String) throws -> [GoalObservedEvent] {
            if let limit, limit <= 0 {
                return []
            }
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return [] }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            var sql = "SELECT kind, message, created_at, goal_id FROM goal_events WHERE created_at > ? "
                + "ORDER BY created_at DESC, id DESC"
            if limit != nil {
                sql += " LIMIT ?"
            }
            sql += ";"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw GoalStoreError.persistenceFailed("Could not prepare observed event read")
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, since.timeIntervalSince1970)
            if let limit {
                sqlite3_bind_int(statement, 2, SQLiteHelpers.sqliteLimit(limit))
            }
            var results: [GoalObservedEvent] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let kind = columnText(statement, index: 0),
                      let message = columnText(statement, index: 1)
                else { continue }
                let occurredAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
                // The goal link is carried so a consumer can attribute the
                // outcome to its source goal without a second lookup; a
                // malformed link degrades to nil rather than dropping the row.
                let goalID = columnText(statement, index: 3).flatMap(UUID.init(uuidString:))
                results.append(GoalObservedEvent(kind: kind, message: message, occurredAt: occurredAt, goalID: goalID))
            }
            return results
        }
    }
#endif

// Rune Weaver Core — Goal step statements for the SQLite goal store.

import Foundation

#if canImport(SQLite3)
    import SQLite3
#endif

#if canImport(SQLite3)
    /// Step persistence and retrieval for the goal store.
    extension SQLiteGoalStore {
        /// Maps a step state to its audit counterpart.
        static func eventKind(forStep status: StepStatus) -> GoalEventKind {
            switch status {
            case .inProgress: .stepStarted
            case .done: .stepDone
            case .blocked: .stepBlocked
            case .pending: .note
            case .skipped: .note
            }
        }

        /// Reads the step at the statement's current row.
        static func readStep(_ statement: OpaquePointer?) -> GoalStep? {
            guard let idText = columnText(statement, index: 0),
                  let id = UUID(uuidString: idText),
                  let goalText = columnText(statement, index: 1),
                  let goalID = UUID(uuidString: goalText),
                  let title = columnText(statement, index: 3),
                  let statusRaw = columnText(statement, index: 4),
                  let status = StepStatus(rawValue: statusRaw)
            else { return nil }
            let ordinal = Int(sqlite3_column_int(statement, 2))
            let notes = columnText(statement, index: 5)
            var lastRunID: UUID?
            if let lastRunText = columnText(statement, index: 6), !lastRunText.isEmpty {
                lastRunID = UUID(uuidString: lastRunText)
            }
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
            let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 8))
            return GoalStep(
                id: id,
                goalID: goalID,
                ordinal: ordinal,
                title: title,
                status: status,
                notes: notes,
                lastRunID: lastRunID,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        }

        /// Inserts or replaces one step row.
        static func insertStep(_ step: GoalStep, handle: OpaquePointer?) throws {
            let sql = "INSERT INTO goal_steps(id, goal_id, ordinal, title, status, notes, last_run_id, created_at, updated_at) "
                + "VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?) "
                + "ON CONFLICT(id) DO UPDATE SET goal_id=excluded.goal_id, ordinal=excluded.ordinal, title=excluded.title, "
                + "status=excluded.status, notes=excluded.notes, last_run_id=excluded.last_run_id, updated_at=excluded.updated_at;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw GoalStoreError.persistenceFailed("Could not prepare step upsert")
            }
            defer { sqlite3_finalize(statement) }
            bindText(statement, index: 1, value: step.id.uuidString)
            bindText(statement, index: 2, value: step.goalID.uuidString)
            sqlite3_bind_int(statement, 3, Int32(clamping: step.ordinal))
            bindText(statement, index: 4, value: step.title)
            bindText(statement, index: 5, value: step.status.rawValue)
            bindText(statement, index: 6, value: step.notes)
            bindText(statement, index: 7, value: step.lastRunID?.uuidString)
            sqlite3_bind_double(statement, 8, step.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(statement, 9, step.updatedAt.timeIntervalSince1970)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw GoalStoreError.persistenceFailed("Could not write step \(step.id)")
            }
        }

        /// Replaces pending steps, refreshes the goal stamp, and logs the replan.
        static func replacePlan(goalID: UUID, steps: [GoalStep], dbPath: String) throws {
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            try exec(handle: handle, sql: "BEGIN IMMEDIATE;")
            do {
                guard try goalExists(goalID, handle: handle) else {
                    throw GoalStoreError.notFound("No goal \(goalID)")
                }
                // Only unstarted rows go: in-progress, blocked, done, and
                // skipped history stays so a replan never rewrites the past.
                var deleteStatement: OpaquePointer?
                guard sqlite3_prepare_v2(
                    handle,
                    "DELETE FROM goal_steps WHERE goal_id = ? AND status = ?;",
                    -1,
                    &deleteStatement,
                    nil
                ) == SQLITE_OK else {
                    throw GoalStoreError.persistenceFailed("Could not prepare plan cleanup")
                }
                defer { sqlite3_finalize(deleteStatement) }
                bindText(deleteStatement, index: 1, value: goalID.uuidString)
                bindText(deleteStatement, index: 2, value: StepStatus.pending.rawValue)
                guard sqlite3_step(deleteStatement) == SQLITE_DONE else {
                    throw GoalStoreError.persistenceFailed("Could not clear pending steps for \(goalID)")
                }
                for step in steps {
                    let anchored = GoalStep(
                        id: step.id,
                        goalID: goalID,
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
                var stampStatement: OpaquePointer?
                guard sqlite3_prepare_v2(handle, "UPDATE goals SET updated_at = ? WHERE id = ?;", -1, &stampStatement, nil) == SQLITE_OK else {
                    throw GoalStoreError.persistenceFailed("Could not prepare goal stamp")
                }
                defer { sqlite3_finalize(stampStatement) }
                sqlite3_bind_double(stampStatement, 1, Date().timeIntervalSince1970)
                bindText(stampStatement, index: 2, value: goalID.uuidString)
                guard sqlite3_step(stampStatement) == SQLITE_DONE else {
                    throw GoalStoreError.persistenceFailed("Could not stamp goal \(goalID)")
                }
                _ = try insertEvent(
                    goalID: goalID,
                    kind: .planReady,
                    message: "Plan replaced with \(steps.count) steps.",
                    createdAt: Date(),
                    handle: handle
                )
                try exec(handle: handle, sql: "COMMIT;")
            } catch {
                try? exec(handle: handle, sql: "ROLLBACK;")
                throw error
            }
        }

        /// Moves one step, stamps step and goal, and logs the matching event.
        static func setStepStatus(
            goalID: UUID,
            stepID: UUID,
            status: StepStatus,
            notes: String?,
            lastRunID: UUID?,
            dbPath: String
        ) throws {
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            try exec(handle: handle, sql: "BEGIN IMMEDIATE;")
            do {
                // Capture the title inside the transaction so the audit message
                // names the step even when the caller only knows its identifier.
                var titleProbe: OpaquePointer?
                guard sqlite3_prepare_v2(
                    handle,
                    "SELECT title FROM goal_steps WHERE id = ? AND goal_id = ?;",
                    -1,
                    &titleProbe,
                    nil
                ) == SQLITE_OK else {
                    throw GoalStoreError.persistenceFailed("Could not probe step \(stepID)")
                }
                defer { sqlite3_finalize(titleProbe) }
                bindText(titleProbe, index: 1, value: stepID.uuidString)
                bindText(titleProbe, index: 2, value: goalID.uuidString)
                guard sqlite3_step(titleProbe) == SQLITE_ROW,
                      let title = columnText(titleProbe, index: 0)
                else {
                    throw GoalStoreError.notFound("No step \(stepID) for goal \(goalID)")
                }
                var updateStatement: OpaquePointer?
                // A nil note preserves history: COALESCE keeps the stored notes
                // so note-less progress moves status without wiping prior text.
                guard sqlite3_prepare_v2(
                    handle,
                    "UPDATE goal_steps SET status = ?, notes = COALESCE(?, notes), last_run_id = ?, updated_at = ? WHERE id = ? AND goal_id = ?;",
                    -1,
                    &updateStatement,
                    nil
                ) == SQLITE_OK else {
                    throw GoalStoreError.persistenceFailed("Could not prepare step update")
                }
                defer { sqlite3_finalize(updateStatement) }
                let now = Date()
                bindText(updateStatement, index: 1, value: status.rawValue)
                bindText(updateStatement, index: 2, value: notes)
                bindText(updateStatement, index: 3, value: lastRunID?.uuidString)
                sqlite3_bind_double(updateStatement, 4, now.timeIntervalSince1970)
                bindText(updateStatement, index: 5, value: stepID.uuidString)
                bindText(updateStatement, index: 6, value: goalID.uuidString)
                guard sqlite3_step(updateStatement) == SQLITE_DONE else {
                    throw GoalStoreError.persistenceFailed("Could not update step \(stepID)")
                }
                var stampStatement: OpaquePointer?
                guard sqlite3_prepare_v2(handle, "UPDATE goals SET updated_at = ? WHERE id = ?;", -1, &stampStatement, nil) == SQLITE_OK else {
                    throw GoalStoreError.persistenceFailed("Could not prepare goal stamp")
                }
                defer { sqlite3_finalize(stampStatement) }
                sqlite3_bind_double(stampStatement, 1, now.timeIntervalSince1970)
                bindText(stampStatement, index: 2, value: goalID.uuidString)
                guard sqlite3_step(stampStatement) == SQLITE_DONE else {
                    throw GoalStoreError.persistenceFailed("Could not stamp goal \(goalID)")
                }
                _ = try insertEvent(
                    goalID: goalID,
                    kind: eventKind(forStep: status),
                    message: "Step '\(title)' moved to \(status.rawValue).",
                    createdAt: now,
                    handle: handle
                )
                try exec(handle: handle, sql: "COMMIT;")
            } catch {
                try? exec(handle: handle, sql: "ROLLBACK;")
                throw error
            }
        }

        /// Reads a goal's steps ordered by ordinal.
        static func steps(goalID: UUID, dbPath: String) throws -> [GoalStep] {
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return [] }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            var statement: OpaquePointer?
            let sql = "SELECT id, goal_id, ordinal, title, status, notes, last_run_id, created_at, updated_at "
                + "FROM goal_steps WHERE goal_id = ? ORDER BY ordinal ASC, rowid ASC;"
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw GoalStoreError.persistenceFailed("Could not prepare step read")
            }
            defer { sqlite3_finalize(statement) }
            bindText(statement, index: 1, value: goalID.uuidString)
            var results: [GoalStep] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let step = readStep(statement) {
                    results.append(step)
                }
            }
            return results
        }

        /// Returns the lowest-ordinal pending or in-progress step, if any.
        static func nextActionableStep(goalID: UUID, dbPath: String) throws -> GoalStep? {
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return nil }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            var statement: OpaquePointer?
            let sql = "SELECT id, goal_id, ordinal, title, status, notes, last_run_id, created_at, updated_at "
                + "FROM goal_steps WHERE goal_id = ? AND status IN (?, ?) ORDER BY ordinal ASC, rowid ASC LIMIT 1;"
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw GoalStoreError.persistenceFailed("Could not prepare actionable scan")
            }
            defer { sqlite3_finalize(statement) }
            bindText(statement, index: 1, value: goalID.uuidString)
            bindText(statement, index: 2, value: StepStatus.pending.rawValue)
            bindText(statement, index: 3, value: StepStatus.inProgress.rawValue)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return readStep(statement)
        }
    }
#endif

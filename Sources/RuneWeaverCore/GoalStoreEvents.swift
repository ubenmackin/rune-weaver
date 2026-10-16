// Rune Weaver Core — Goal audit events for the SQLite goal store.

import Foundation

#if canImport(SQLite3)
    import SQLite3
#endif

#if canImport(SQLite3)
    /// Audit-trail persistence and retrieval for the goal store.
    extension SQLiteGoalStore {
        /// Maps a goal lifecycle state to its audit counterpart.
        static func eventKind(for status: GoalStatus) -> GoalEventKind {
            switch status {
            case .active: .resumed
            case .paused: .paused
            case .needsInput: .needsInput
            case .achieved: .completed
            case .abandoned, .unplanned: .note
            }
        }

        /// Reads the event at the statement's current row.
        static func readEvent(_ statement: OpaquePointer?) -> GoalEvent? {
            let id = sqlite3_column_int64(statement, 0)
            guard let goalText = columnText(statement, index: 1),
                  let goalID = UUID(uuidString: goalText),
                  let kindRaw = columnText(statement, index: 2),
                  let kind = GoalEventKind(rawValue: kindRaw),
                  let message = columnText(statement, index: 3)
            else { return nil }
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
            return GoalEvent(id: id, goalID: goalID, kind: kind, message: message, createdAt: createdAt)
        }

        /// Inserts one audit entry and returns its assigned rowid.
        static func insertEvent(
            goalID: UUID,
            kind: GoalEventKind,
            message: String,
            createdAt: Date,
            handle: OpaquePointer?
        ) throws -> Int64 {
            let sql = "INSERT INTO goal_events(goal_id, kind, message, created_at) VALUES(?, ?, ?, ?);"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw GoalStoreError.persistenceFailed("Could not prepare event insert")
            }
            defer { sqlite3_finalize(statement) }
            bindText(statement, index: 1, value: goalID.uuidString)
            bindText(statement, index: 2, value: kind.rawValue)
            bindText(statement, index: 3, value: message)
            sqlite3_bind_double(statement, 4, createdAt.timeIntervalSince1970)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw GoalStoreError.persistenceFailed("Could not write event for goal \(goalID)")
            }
            return sqlite3_last_insert_rowid(handle)
        }

        /// Appends one audit entry, rejecting orphan events for unknown goals.
        static func appendEvent(goalID: UUID, kind: GoalEventKind, message: String, dbPath: String) throws -> GoalEvent {
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            guard try goalExists(goalID, handle: handle) else {
                throw GoalStoreError.notFound("No goal \(goalID)")
            }
            let now = Date()
            let rowID = try insertEvent(goalID: goalID, kind: kind, message: message, createdAt: now, handle: handle)
            return GoalEvent(id: rowID, goalID: goalID, kind: kind, message: message, createdAt: now)
        }

        /// Reads the most-recent audit trail, returned oldest first, bounded by `limit`.
        static func events(goalID: UUID, limit: Int?, dbPath: String) throws -> [GoalEvent] {
            if let limit, limit <= 0 {
                return []
            }
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return [] }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            // A bounded tail quotes recent progress, not creation-era history:
            // the inner query takes the most-recent N rows while the outer
            // query restores oldest-first order for prompt and status readers.
            let sql = if limit != nil {
                "SELECT id, goal_id, kind, message, created_at FROM "
                    + "(SELECT id, goal_id, kind, message, created_at FROM goal_events WHERE goal_id = ? ORDER BY id DESC LIMIT ?) ORDER BY id ASC;"
            } else {
                "SELECT id, goal_id, kind, message, created_at FROM goal_events WHERE goal_id = ? ORDER BY id ASC;"
            }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw GoalStoreError.persistenceFailed("Could not prepare event read")
            }
            defer { sqlite3_finalize(statement) }
            bindText(statement, index: 1, value: goalID.uuidString)
            if let limit {
                sqlite3_bind_int(statement, 2, SQLiteHelpers.sqliteLimit(limit))
            }
            var results: [GoalEvent] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let event = readEvent(statement) {
                    results.append(event)
                }
            }
            return results
        }
    }
#endif

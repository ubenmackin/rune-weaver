// Rune Weaver Core — SQLite-backed durable store for proactive Wayfinder ideas.

import Foundation

#if canImport(SQLite3)
    import SQLite3
#endif

/// Failures raised by ``IdeasStore``.
public enum IdeasStoreError: Error, Sendable, Equatable {
    /// The SQLite store could not be opened or migrated.
    case storeUnavailable(String)
    /// A read or write against the store failed.
    case persistenceFailed(String)
    /// The referenced idea does not exist.
    case notFound(String)
    /// The idea exists but is not in the state a guarded transition required.
    case conflict(String)
}

/// Protocol seam for idea persistence, so callers can substitute fakes.
public protocol IdeasStoring: Sendable {
    /// Persists a batch of ideas, skipping blank titles and titles that duplicate a non-dismissed
    /// existing idea (case-insensitive).
    /// - Parameter ideas: Candidate ideas to persist.
    func append(ideas: [Idea]) async throws -> [Idea]
    /// Lists ideas newest first, optionally filtered by status and bounded by `limit`.
    /// A nil limit reads all matching rows; callers listing for display must
    /// pass a bound so the SQL carries the LIMIT instead of slicing in memory.
    func list(status: IdeaStatus?, limit: Int?) async throws -> [Idea]
    /// Reads one idea by identifier, or nil when absent.
    func idea(id: UUID) async throws -> Idea?
    /// Moves one idea to a new lifecycle state and returns the updated row.
    func setStatus(id: UUID, status: IdeaStatus) async throws -> Idea
    /// Atomically transitions one idea from `from` to `to`, returning the row.
    func claim(id: UUID, from: IdeaStatus, to: IdeaStatus) async throws -> Idea
    /// Returns the lowercased titles of every dismissed idea.
    func dismissedTitles() async throws -> [String]
    /// Counts persisted ideas grouped by status, optionally filtered to one.
    func counts(status: IdeaStatus?) async throws -> [IdeaStatus: Int]
}

/// Convenience overloads so callers can omit the bound without a protocol-level
/// default argument. The full two-parameter form stays the single requirement
/// so unbounded reads still spell `nil` explicitly and ride the same SQL path.
extension IdeasStoring {
    /// Lists ideas filtered by status with no row bound.
    public func list(status: IdeaStatus?) async throws -> [Idea] {
        try await list(status: status, limit: nil)
    }

    /// Lists every idea with no filter and no row bound.
    public func list() async throws -> [Idea] {
        try await list(status: nil, limit: nil)
    }

    /// Counts every idea grouped by status.
    public func counts() async throws -> [IdeaStatus: Int] {
        try await counts(status: nil)
    }
}

/// Actor-isolated SQLite store for proactive ideas.
public actor IdeasStore: IdeasStoring {
    /// Filesystem path of the shared SQLite database.
    public let dbPath: String
    /// Maximum rows returned per bounded read.
    private static let maxResults = 1000

    /// Creates a store over the shared database file.
    /// - Parameter dbPath: SQLite file path (the same `episodes.db` used by sessions and goals).
    public init(dbPath: String) {
        self.dbPath = dbPath
    }

    /// Persists a batch of ideas, skipping blank titles and duplicate non-dismissed titles.
    public func append(ideas: [Idea]) async throws -> [Idea] {
        guard !ideas.isEmpty else { return [] }
        let dbPath = self.dbPath
        return try await SQLiteSerialIO.run {
            try SQLiteIdeasStore.append(ideas: ideas, dbPath: dbPath)
        }
    }

    /// Lists ideas newest first, optionally filtered by status and bounded by `limit`.
    public func list(status: IdeaStatus? = nil, limit: Int? = nil) async throws -> [Idea] {
        if let limit, limit <= 0 {
            return []
        }
        let clamped = limit.map { min($0, Self.maxResults) }
        let dbPath = self.dbPath
        return try await SQLiteSerialIO.run {
            try SQLiteIdeasStore.list(status: status, limit: clamped, dbPath: dbPath)
        }
    }

    /// Reads one idea by identifier, or nil when absent.
    public func idea(id: UUID) async throws -> Idea? {
        let dbPath = self.dbPath
        return try await SQLiteSerialIO.run {
            try SQLiteIdeasStore.idea(id: id, dbPath: dbPath)
        }
    }

    /// Moves one idea to a new lifecycle state, throwing when it is unknown.
    @discardableResult
    public func setStatus(id: UUID, status: IdeaStatus) async throws -> Idea {
        let dbPath = self.dbPath
        return try await SQLiteSerialIO.run {
            try SQLiteIdeasStore.setStatus(id: id, status: status, dbPath: dbPath)
        }
    }

    /// Atomically transitions one idea from `from` to `to`, throwing on a race.
    public func claim(id: UUID, from: IdeaStatus, to: IdeaStatus) async throws -> Idea {
        let dbPath = self.dbPath
        return try await SQLiteSerialIO.run {
            try SQLiteIdeasStore.claim(id: id, from: from, to: to, dbPath: dbPath)
        }
    }

    /// Returns the lowercased titles of every dismissed idea.
    public func dismissedTitles() async throws -> [String] {
        let dbPath = self.dbPath
        return try await SQLiteSerialIO.run {
            try SQLiteIdeasStore.dismissedTitles(dbPath: dbPath)
        }
    }

    /// Counts persisted ideas grouped by status, optionally filtered to one.
    public func counts(status: IdeaStatus? = nil) async throws -> [IdeaStatus: Int] {
        let dbPath = self.dbPath
        return try await SQLiteSerialIO.run {
            try SQLiteIdeasStore.counts(status: status, dbPath: dbPath)
        }
    }
}

#if canImport(SQLite3)
    // SQLiteIdeasStore keeps every idea row statement in one place so the shared episodes.db schema stays auditable together.

    /// Blocking SQLite implementation behind ``IdeasStore``.
    enum SQLiteIdeasStore {
        /// Opens (creating parent directories) and migrates the database.
        static func open(dbPath: String) throws -> OpaquePointer? {
            // Shared busy_timeout/WAL policy lives in `SQLiteHelpers.openHandle`.
            let handle = try SQLiteHelpers.openHandle(dbPath: dbPath, unavailable: IdeasStoreError.storeUnavailable)
            try SQLiteHelpers.exec(
                handle: handle,
                sql: """
                CREATE TABLE IF NOT EXISTS ideas(
                    id TEXT PRIMARY KEY,
                    kind TEXT NOT NULL,
                    title TEXT NOT NULL,
                    body TEXT NOT NULL,
                    goal_id TEXT,
                    status TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_ideas_status_created ON ideas(status, created_at);
                """,
                failure: IdeasStoreError.persistenceFailed
            )
            return handle
        }

        /// Executes a multi-statement SQL string.
        static func exec(handle: OpaquePointer?, sql: String) throws {
            try SQLiteHelpers.exec(handle: handle, sql: sql, failure: IdeasStoreError.persistenceFailed)
        }

        /// Binds optional text, mapping nil to NULL.
        static func bindText(_ statement: OpaquePointer?, index: Int32, value: String?) {
            SQLiteHelpers.bindText(statement, index: index, value: value)
        }

        /// Column-text helper returning nil for NULL columns.
        static func columnText(_ statement: OpaquePointer?, index: Int32) -> String? {
            SQLiteHelpers.columnText(statement, index: index)
        }

        /// Reads the idea at the statement's current row. statement: Prepared
        /// statement positioned on a row.
        static func readIdea(_ statement: OpaquePointer?, offset: Int32 = 0) -> Idea? {
            guard let idText = columnText(statement, index: offset),
                  let id = UUID(uuidString: idText),
                  let kindRaw = columnText(statement, index: offset + 1),
                  let kind = IdeaKind(rawValue: kindRaw),
                  let title = columnText(statement, index: offset + 2),
                  let body = columnText(statement, index: offset + 3),
                  let statusRaw = columnText(statement, index: offset + 5),
                  let status = IdeaStatus(rawValue: statusRaw)
            else { return nil }
            var goalID: UUID?
            if let goalText = columnText(statement, index: offset + 4), !goalText.isEmpty {
                goalID = UUID(uuidString: goalText)
            }
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, offset + 6))
            let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, offset + 7))
            return Idea(
                id: id,
                kind: kind,
                title: title,
                body: body,
                goalID: goalID,
                status: status,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        }

        /// Inserts one idea row.
        static func insertIdea(_ idea: Idea, handle: OpaquePointer?) throws {
            let sql = "INSERT INTO ideas(id, kind, title, body, goal_id, status, created_at, updated_at) "
                + "VALUES(?, ?, ?, ?, ?, ?, ?, ?);"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw IdeasStoreError.persistenceFailed("Could not prepare idea insert")
            }
            defer { sqlite3_finalize(statement) }
            bindText(statement, index: 1, value: idea.id.uuidString)
            bindText(statement, index: 2, value: idea.kind.rawValue)
            bindText(statement, index: 3, value: idea.title)
            bindText(statement, index: 4, value: idea.body)
            bindText(statement, index: 5, value: idea.goalID?.uuidString)
            bindText(statement, index: 6, value: idea.status.rawValue)
            sqlite3_bind_double(statement, 7, idea.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(statement, 8, idea.updatedAt.timeIntervalSince1970)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw IdeasStoreError.persistenceFailed("Could not write idea \(idea.id)")
            }
        }

        /// Reads the lowercased titles of every idea that is not dismissed.
        static func nonDismissedTitles(handle: OpaquePointer?) throws -> Set<String> {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "SELECT title FROM ideas WHERE status <> ?;", -1, &statement, nil) == SQLITE_OK else {
                throw IdeasStoreError.persistenceFailed("Could not prepare existing idea title read")
            }
            defer { sqlite3_finalize(statement) }
            bindText(statement, index: 1, value: IdeaStatus.dismissed.rawValue)
            var titles: Set<String> = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let title = columnText(statement, index: 0) {
                    titles.insert(normalizedTitle(title))
                }
            }
            return titles
        }

        /// Dedup key for one title: whitespace-trimmed and case-folded.
        static func normalizedTitle(_ title: String) -> String {
            title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        /// Persists a batch of ideas and a dedup pass in one transaction.
        static func append(ideas: [Idea], dbPath: String) throws -> [Idea] {
            guard !ideas.isEmpty else { return [] }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            try exec(handle: handle, sql: "BEGIN IMMEDIATE;")
            do {
                var existing = try nonDismissedTitles(handle: handle)
                var inserted: [Idea] = []
                for idea in ideas {
                    let key = normalizedTitle(idea.title)
                    guard !key.isEmpty else { continue }
                    guard !existing.contains(key) else { continue }
                    try insertIdea(idea, handle: handle)
                    existing.insert(key)
                    inserted.append(idea)
                }
                try exec(handle: handle, sql: "COMMIT;")
                return inserted
            } catch {
                try? exec(handle: handle, sql: "ROLLBACK;")
                throw error
            }
        }

        /// Lists ideas newest first, optionally filtered by status and bounded by `limit`.
        static func list(status: IdeaStatus?, limit: Int?, dbPath: String) throws -> [Idea] {
            if let limit, limit <= 0 {
                return []
            }
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return [] }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            let base = "SELECT id, kind, title, body, goal_id, status, created_at, updated_at FROM ideas"
            let filtered = status != nil ? base + " WHERE status = ?" : base
            let ordered = filtered + " ORDER BY created_at DESC, rowid DESC"
            let sql = limit != nil ? ordered + " LIMIT ?;" : ordered + ";"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw IdeasStoreError.persistenceFailed("Could not prepare idea list")
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
            var results: [Idea] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let idea = readIdea(statement) {
                    results.append(idea)
                }
            }
            return results
        }

        /// Reads one idea by identifier.
        static func idea(id: UUID, dbPath: String) throws -> Idea? {
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return nil }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            var statement: OpaquePointer?
            let sql = "SELECT id, kind, title, body, goal_id, status, created_at, updated_at FROM ideas WHERE id = ?;"
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw IdeasStoreError.persistenceFailed("Could not prepare idea read")
            }
            defer { sqlite3_finalize(statement) }
            bindText(statement, index: 1, value: id.uuidString)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return readIdea(statement)
        }

        /// Atomically transitions one idea from `from` to `to`.
        static func claim(id: UUID, from: IdeaStatus, to: IdeaStatus, dbPath: String) throws -> Idea {
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            var statement: OpaquePointer?
            let claimSQL = "UPDATE ideas SET status = ?, updated_at = ? WHERE id = ? AND status = ?;"
            guard sqlite3_prepare_v2(handle, claimSQL, -1, &statement, nil) == SQLITE_OK else {
                throw IdeasStoreError.persistenceFailed("Could not prepare idea claim")
            }
            defer { sqlite3_finalize(statement) }
            let now = Date()
            bindText(statement, index: 1, value: to.rawValue)
            sqlite3_bind_double(statement, 2, now.timeIntervalSince1970)
            bindText(statement, index: 3, value: id.uuidString)
            bindText(statement, index: 4, value: from.rawValue)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw IdeasStoreError.persistenceFailed("Could not claim idea \(id)")
            }
            guard sqlite3_changes(handle) > 0 else {
                guard try idea(id: id, dbPath: dbPath) != nil else {
                    throw IdeasStoreError.notFound("No idea \(id)")
                }
                throw IdeasStoreError.conflict("Idea \(id) is no longer \(from.rawValue)")
            }
            guard let claimed = try idea(id: id, dbPath: dbPath) else {
                throw IdeasStoreError.notFound("No idea \(id)")
            }
            return claimed
        }

        /// Moves one idea to a new lifecycle state.
        static func setStatus(id: UUID, status: IdeaStatus, dbPath: String) throws -> Idea {
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "UPDATE ideas SET status = ?, updated_at = ? WHERE id = ?;", -1, &statement, nil) == SQLITE_OK else {
                throw IdeasStoreError.persistenceFailed("Could not prepare idea status update")
            }
            defer { sqlite3_finalize(statement) }
            let now = Date()
            bindText(statement, index: 1, value: status.rawValue)
            sqlite3_bind_double(statement, 2, now.timeIntervalSince1970)
            bindText(statement, index: 3, value: id.uuidString)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw IdeasStoreError.persistenceFailed("Could not update idea \(id)")
            }
            guard sqlite3_changes(handle) > 0 else {
                throw IdeasStoreError.notFound("No idea \(id)")
            }
            var readStatement: OpaquePointer?
            let sql = "SELECT id, kind, title, body, goal_id, status, created_at, updated_at FROM ideas WHERE id = ?;"
            guard sqlite3_prepare_v2(handle, sql, -1, &readStatement, nil) == SQLITE_OK else {
                throw IdeasStoreError.persistenceFailed("Could not prepare updated idea read")
            }
            defer { sqlite3_finalize(readStatement) }
            bindText(readStatement, index: 1, value: id.uuidString)
            guard sqlite3_step(readStatement) == SQLITE_ROW, let updated = readIdea(readStatement) else {
                throw IdeasStoreError.notFound("No idea \(id)")
            }
            return updated
        }

        /// Returns the lowercased titles of every dismissed idea.
        static func dismissedTitles(dbPath: String) throws -> [String] {
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return [] }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "SELECT DISTINCT title FROM ideas WHERE status = ?;", -1, &statement, nil) == SQLITE_OK else {
                throw IdeasStoreError.persistenceFailed("Could not prepare dismissed title read")
            }
            defer { sqlite3_finalize(statement) }
            bindText(statement, index: 1, value: IdeaStatus.dismissed.rawValue)
            var titles: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let title = columnText(statement, index: 0) {
                    titles.append(normalizedTitle(title))
                }
            }
            return titles
        }

        /// Counts ideas grouped by status, optionally filtered to one.
        static func counts(status: IdeaStatus?, dbPath: String) throws -> [IdeaStatus: Int] {
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return [:] }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            let base = "SELECT status, COUNT(*) FROM ideas"
            let filtered = status != nil ? base + " WHERE status = ?" : base
            let sql = filtered + " GROUP BY status;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw IdeasStoreError.persistenceFailed("Could not prepare idea count")
            }
            defer { sqlite3_finalize(statement) }
            if let status {
                bindText(statement, index: 1, value: status.rawValue)
            }
            var results: [IdeaStatus: Int] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let raw = columnText(statement, index: 0),
                      let parsed = IdeaStatus(rawValue: raw)
                else { continue }
                results[parsed] = Int(sqlite3_column_int(statement, 1))
            }
            return results
        }
    }
#endif

// Rune Weaver Core — Persistence contract and storage implementations for trust grants.
//
// Purpose: defines the durability seam behind the permission gate's graduated-trust
// model, so an approval ("this time", 5m, 1h, 1d, or forever) survives restarts
// instead of degrading to a fresh prompt. The gate owns the live grant list and
// mirrors changes here best-effort; this file owns what persists.
// Scope: the `TrustStore` protocol plus in-memory, JSON-file, and SQLite
// (`episodes.db`, table `trust_grants`) implementations. The SQLite path migrates
// legacy tables additively for usage counters — a failed migration surfaces instead
// of masquerading as migrated — and replaces the grant set inside a transaction so a
// partial write never discards live trust. Expiry and approval semantics stay with
// the permission gate and `TrustGrant`.
// Architectural role: storage adapter beside the permission gate, following the
// shared Core store idiom (serialized SQLite access via `SQLiteSerialIO`) so serve,
// CLI, and the menu-bar app share one persistence path.

import Foundation
#if canImport(SQLite3)
    import SQLite3
#endif

/// Persistence contract for ``TrustGrant`` records.
public protocol TrustStore: Sendable {
    /// Loads all stored active grants.
    /// - Returns: Persisted grants, possibly empty.
    func load() async throws -> [TrustGrant]
    /// Replaces the stored grants.
    /// - Parameter grants: Current grants to persist.
    func save(_ grants: [TrustGrant]) async throws
    /// Deletes expired grants from storage.
    /// - Parameter date: Threshold date.
    func pruneExpired(at date: Date) async throws
}

/// In-memory ``TrustStore`` for tests and ephemeral sessions.
public actor InMemoryTrustStore: TrustStore {
    private var grants: [TrustGrant]

    /// Creates an empty in-memory store.
    /// - Parameter grants: Seed grants. Defaults to empty.
    public init(grants: [TrustGrant] = []) {
        self.grants = grants
    }

    /// Returns the in-memory grants.
    /// - Returns: Current grants.
    public func load() async throws -> [TrustGrant] {
        grants
    }

    /// Replaces the in-memory grants.
    /// - Parameter grants: Grants to keep.
    public func save(_ grants: [TrustGrant]) async throws {
        self.grants = grants
    }

    /// Prunes expired in-memory grants.
    /// - Parameter date: Expiry threshold. Defaults to now.
    public func pruneExpired(at date: Date = Date()) async throws {
        grants.removeAll { $0.isExpired(at: date) }
    }
}

/// JSON-file ``TrustStore`` persisted under `~/.runeweaver/`.
public struct FileTrustStore: TrustStore, Sendable {
    /// File URL of the JSON grant list.
    public let fileURL: URL

    /// Creates a file store.
    /// - Parameter fileURL: Destination JSON file.
    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Loads grants from disk, returning empty when absent.
    /// - Returns: Persisted grants.
    public func load() async throws -> [TrustGrant] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else { return [] }
        return try JSONDecoder().decode([TrustGrant].self, from: data)
    }

    /// Persists grants to disk atomically.
    /// - Parameter grants: Grants to persist.
    public func save(_ grants: [TrustGrant]) async throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(grants)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Prunes expired grants from disk.
    /// - Parameter date: Expiry threshold.
    public func pruneExpired(at date: Date = Date()) async throws {
        var current: [TrustGrant]
        do {
            current = try await load()
        } catch {
            current = []
        }
        current.removeAll { $0.isExpired(at: date) }
        try await save(current)
    }
}

#if canImport(SQLite3)
    /// Internal SQLite helper for durable trust grant persistence in `episodes.db`.
    enum SQLiteTrustStorage {
        private struct TrustStorageError: Error {
            let message: String
        }

        private static func open(dbPath: String) throws -> OpaquePointer? {
            let handle = try SQLiteHelpers.openHandle(dbPath: dbPath, unavailable: { TrustStorageError(message: $0) })
            try SQLiteHelpers.exec(
                handle: handle,
                sql: """
                CREATE TABLE IF NOT EXISTS trust_grants (
                    id TEXT PRIMARY KEY,
                    tool_name TEXT NOT NULL,
                    target TEXT NOT NULL,
                    granted_at REAL NOT NULL,
                    expires_at REAL,
                    duration TEXT NOT NULL,
                    use_count INTEGER NOT NULL DEFAULT 0,
                    last_used_at REAL
                );
                CREATE INDEX IF NOT EXISTS idx_trust_grants_tool_target ON trust_grants(tool_name, target);
                CREATE INDEX IF NOT EXISTS idx_trust_grants_expires_at ON trust_grants(expires_at);
                """,
                failure: { TrustStorageError(message: $0) }
            )
            // Databases created before usage counters gain the new columns
            // once; the probe keeps later opens a no-op instead of erroring
            // on duplicate `ALTER` statements.
            let existing = SQLiteHelpers.columnNames(handle: handle, table: .trustGrants)
            let pendingMigrations: [(column: String, sql: String)] = [
                ("use_count", "ALTER TABLE trust_grants ADD COLUMN use_count INTEGER NOT NULL DEFAULT 0;"),
                ("last_used_at", "ALTER TABLE trust_grants ADD COLUMN last_used_at REAL;")
            ]
            for migration in pendingMigrations where !existing.contains(migration.column) {
                do {
                    try SQLiteHelpers.exec(
                        handle: handle,
                        sql: migration.sql,
                        failure: { TrustStorageError(message: $0) }
                    )
                } catch {
                    // Concurrent opens can race the probe onto the same
                    // `ALTER`; only that duplicate-column case is safe to
                    // ignore. Any other failure (readonly, disk-full, syntax)
                    // must surface instead of masquerading as migrated.
                    var engineDetail = ""
                    if let message = sqlite3_errmsg(handle) {
                        engineDetail = String(cString: message)
                    }
                    let combined = (engineDetail + " " + String(describing: error)).lowercased()
                    if combined.contains("duplicate column") {
                        continue
                    }
                    let code = sqlite3_errcode(handle)
                    RuneWeaverLog.stores.warning(
                        "SQLiteTrustStorage: migration failed for column '\(migration.column)' (code \(code)): \(error)"
                    )
                    throw error
                }
            }
            return handle
        }

        static func load(dbPath: String) -> [TrustGrant] {
            let handle: OpaquePointer?
            do {
                handle = try open(dbPath: dbPath)
            } catch {
                RuneWeaverLog.stores.error("SQLiteTrustStorage: failed opening store at \(dbPath): \(error)")
                return []
            }
            guard let handle else {
                // `open` should either throw or return a handle; a nil handle
                // without an error would otherwise read as empty trust.
                RuneWeaverLog.stores.error("SQLiteTrustStorage: failed opening store at \(dbPath): unexpected nil handle")
                return []
            }
            defer { sqlite3_close(handle) }
            let now = Date().timeIntervalSince1970
            // Counter columns can arrive independently when one `ALTER`
            // succeeds and the other fails, so project each surviving
            // column instead of discarding both on a partial migration.
            let columns = SQLiteHelpers.columnNames(handle: handle, table: .trustGrants)
            let hasUseCount = columns.contains("use_count")
            let hasLastUsedAt = columns.contains("last_used_at")
            var selectColumns = "id, tool_name, target, granted_at, expires_at, duration"
            if hasUseCount {
                selectColumns += ", use_count"
            }
            if hasLastUsedAt {
                selectColumns += ", last_used_at"
            }
            let sql = "SELECT \(selectColumns) FROM trust_grants WHERE expires_at IS NULL OR expires_at > ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                let code = sqlite3_errcode(handle)
                RuneWeaverLog.stores.error("SQLiteTrustStorage: failed preparing trust load (code \(code)).")
                return []
            }
            defer { sqlite3_finalize(statement) }
            SQLiteHelpers.bindDouble(statement, index: 1, value: now)
            // Counter positions shift when only one column survived, so
            // resolve them from the same probe that built the projection.
            let useCountIndex: Int32? = hasUseCount ? 6 : nil
            let lastUsedIndex: Int32? = hasLastUsedAt ? (hasUseCount ? 7 : 6) : nil
            var results: [TrustGrant] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let idString = SQLiteHelpers.columnText(statement, index: 0),
                      let id = UUID(uuidString: idString),
                      let toolName = SQLiteHelpers.columnText(statement, index: 1),
                      let durationRaw = SQLiteHelpers.columnText(statement, index: 5),
                      let duration = TrustDuration(rawValue: durationRaw)
                else { continue }
                let target = SQLiteHelpers.columnText(statement, index: 2) ?? ""
                let grantedAtSeconds = SQLiteHelpers.columnDouble(statement, index: 3)
                let grantedAt = Date(timeIntervalSince1970: grantedAtSeconds)
                var expiresAt: Date?
                if sqlite3_column_type(statement, 4) != SQLITE_NULL {
                    expiresAt = Date(timeIntervalSince1970: SQLiteHelpers.columnDouble(statement, index: 4))
                }
                // Legacy rows predate counters, so missing or NULL values
                // mean the grant has never been observed in use.
                var useCount = 0
                var lastUsedAt: Date?
                if let useCountIndex {
                    if let rawCount = SQLiteHelpers.columnInt64(statement, index: useCountIndex) {
                        useCount = max(0, Int(rawCount))
                    }
                }
                if let lastUsedIndex {
                    if sqlite3_column_type(statement, lastUsedIndex) != SQLITE_NULL {
                        let stamp = SQLiteHelpers.columnDouble(statement, index: lastUsedIndex)
                        lastUsedAt = Date(timeIntervalSince1970: stamp)
                    }
                }
                results.append(TrustGrant(
                    id: id,
                    actionDescriptor: ActionDescriptor(toolName: toolName, target: target),
                    grantedAt: grantedAt,
                    expiresAt: expiresAt,
                    duration: duration,
                    useCount: useCount,
                    lastUsedAt: lastUsedAt
                ))
            }
            return results
        }

        static func pruneExpired(at date: Date, dbPath: String) {
            let handle: OpaquePointer?
            do {
                handle = try open(dbPath: dbPath)
            } catch {
                RuneWeaverLog.stores.error("SQLiteTrustStorage: failed opening store at \(dbPath): \(error)")
                return
            }
            guard let handle else {
                // A nil handle without an error would otherwise skip the
                // prune silently, leaving expired trust visible.
                RuneWeaverLog.stores.error("SQLiteTrustStorage: failed opening store at \(dbPath): unexpected nil handle")
                return
            }
            defer { sqlite3_close(handle) }
            let sql = "DELETE FROM trust_grants WHERE expires_at IS NOT NULL AND expires_at <= ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                let code = sqlite3_errcode(handle)
                RuneWeaverLog.stores.error("SQLiteTrustStorage: failed preparing trust prune (code \(code)).")
                return
            }
            defer { sqlite3_finalize(statement) }
            SQLiteHelpers.bindDouble(statement, index: 1, value: date.timeIntervalSince1970)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                let code = sqlite3_errcode(handle)
                RuneWeaverLog.stores.error("SQLiteTrustStorage: failed pruning expired trust grants (code \(code)).")
                return
            }
        }

        static func save(grants: [TrustGrant], dbPath: String) {
            let handle: OpaquePointer?
            do {
                handle = try open(dbPath: dbPath)
            } catch {
                RuneWeaverLog.stores.error("SQLiteTrustStorage: failed opening store at \(dbPath): \(error)")
                return
            }
            guard let handle else {
                // A nil handle without an error would otherwise drop the
                // save silently, discarding live trust updates.
                RuneWeaverLog.stores.error("SQLiteTrustStorage: failed opening store at \(dbPath): unexpected nil handle")
                return
            }
            defer { sqlite3_close(handle) }
            // Replace the table atomically: any prepare/step failure rolls
            // back to the pre-save contents instead of committing an
            // empty or partial grant set that would wipe live trust.
            guard sqlite3_exec(handle, "BEGIN IMMEDIATE TRANSACTION;", nil, nil, nil) == SQLITE_OK else {
                let code = sqlite3_errcode(handle)
                RuneWeaverLog.stores.error("SQLiteTrustStorage: failed beginning trust save (code \(code)).")
                return
            }
            guard sqlite3_exec(handle, "DELETE FROM trust_grants;", nil, nil, nil) == SQLITE_OK else {
                let code = sqlite3_errcode(handle)
                RuneWeaverLog.stores.error("SQLiteTrustStorage: failed clearing trust grants (code \(code)).")
                _ = sqlite3_exec(handle, "ROLLBACK;", nil, nil, nil)
                return
            }
            // Probe after migration so a table missing one counter still
            // persists the surviving columns instead of failing an
            // eight-column write and rolling back the whole save.
            let columns = SQLiteHelpers.columnNames(handle: handle, table: .trustGrants)
            let hasUseCount = columns.contains("use_count")
            let hasLastUsedAt = columns.contains("last_used_at")
            var insertColumns = "id, tool_name, target, granted_at, expires_at, duration"
            var placeholders = "?, ?, ?, ?, ?, ?"
            if hasUseCount {
                insertColumns += ", use_count"
                placeholders += ", ?"
            }
            if hasLastUsedAt {
                insertColumns += ", last_used_at"
                placeholders += ", ?"
            }
            let insertSQL = "INSERT INTO trust_grants (\(insertColumns)) VALUES (\(placeholders));"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
                let code = sqlite3_errcode(handle)
                RuneWeaverLog.stores.error("SQLiteTrustStorage: failed preparing trust save (code \(code)).")
                _ = sqlite3_exec(handle, "ROLLBACK;", nil, nil, nil)
                return
            }
            var succeeded = true
            for grant in grants {
                sqlite3_reset(stmt)
                // Bind positions shift with the surviving counter columns,
                // so advance one slot at a time instead of fixed indices.
                var nextIndex: Int32 = 1
                SQLiteHelpers.bindText(stmt, index: nextIndex, value: grant.id.uuidString)
                nextIndex += 1
                SQLiteHelpers.bindText(stmt, index: nextIndex, value: grant.actionDescriptor.toolName)
                nextIndex += 1
                SQLiteHelpers.bindText(stmt, index: nextIndex, value: grant.actionDescriptor.target)
                nextIndex += 1
                SQLiteHelpers.bindDouble(stmt, index: nextIndex, value: grant.grantedAt.timeIntervalSince1970)
                nextIndex += 1
                if let exp = grant.expiresAt {
                    SQLiteHelpers.bindDouble(stmt, index: nextIndex, value: exp.timeIntervalSince1970)
                } else {
                    sqlite3_bind_null(stmt, nextIndex)
                }
                nextIndex += 1
                SQLiteHelpers.bindText(stmt, index: nextIndex, value: grant.duration.rawValue)
                nextIndex += 1
                if hasUseCount {
                    SQLiteHelpers.bindInt64(stmt, index: nextIndex, value: Int64(max(0, grant.useCount)))
                    nextIndex += 1
                }
                if hasLastUsedAt {
                    if let lastUsed = grant.lastUsedAt {
                        SQLiteHelpers.bindDouble(stmt, index: nextIndex, value: lastUsed.timeIntervalSince1970)
                    } else {
                        sqlite3_bind_null(stmt, nextIndex)
                    }
                    nextIndex += 1
                }
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    let code = sqlite3_errcode(handle)
                    RuneWeaverLog.stores.error("SQLiteTrustStorage: failed writing trust grant (code \(code)).")
                    succeeded = false
                    break
                }
            }
            sqlite3_finalize(stmt)
            if succeeded {
                if sqlite3_exec(handle, "COMMIT;", nil, nil, nil) != SQLITE_OK {
                    let code = sqlite3_errcode(handle)
                    RuneWeaverLog.stores.error("SQLiteTrustStorage: failed committing trust save (code \(code)).")
                    _ = sqlite3_exec(handle, "ROLLBACK;", nil, nil, nil)
                }
            } else {
                _ = sqlite3_exec(handle, "ROLLBACK;", nil, nil, nil)
            }
        }
    }
#endif

/// SQLite-backed ``TrustStore`` persisted under `episodes.db` in table `trust_grants`.
public struct SQLiteTrustStore: TrustStore, Sendable {
    /// Filesystem path of the SQLite database (`episodes.db`).
    public let dbPath: String

    /// Creates an SQLite trust store.
    /// - Parameter dbPath: SQLite database file path.
    public init(dbPath: String) {
        self.dbPath = dbPath
    }

    /// Loads active non-expired grants from SQLite.
    public func load() async throws -> [TrustGrant] {
        #if canImport(SQLite3)
            return await SQLiteSerialIO.runUncancellable {
                SQLiteTrustStorage.load(dbPath: dbPath)
            }
        #else
            return []
        #endif
    }

    /// Replaces the persisted grants in SQLite.
    public func save(_ grants: [TrustGrant]) async throws {
        #if canImport(SQLite3)
            await SQLiteSerialIO.runUncancellable {
                SQLiteTrustStorage.save(grants: grants, dbPath: dbPath)
            }
        #endif
    }

    /// Deletes expired grants from SQLite.
    public func pruneExpired(at date: Date = Date()) async throws {
        #if canImport(SQLite3)
            await SQLiteSerialIO.runUncancellable {
                SQLiteTrustStorage.pruneExpired(at: date, dbPath: dbPath)
            }
        #endif
    }
}

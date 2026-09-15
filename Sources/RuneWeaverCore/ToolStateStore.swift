// Rune Weaver Core — Durable per-tool enable/disable states for builtin and plugin tools.
//
// Persists operator toggles for any registered tool name in `episodes.db`
// (`tool_states` table) so restarts restore the live `ToolBus` enablement
// without re-prompting. The bus stays the runtime source of truth while
// SQLite stays the durable one; stored rows apply on boot through the
// existing enable/disable calls, including memory tools with no exemptions.

import Foundation
#if canImport(SQLite3)
    import SQLite3
#endif

/// Durable enable/disable snapshot for one tool.
public struct ToolState: Sendable, Codable, Equatable {
    /// Registered tool name (e.g. `"email.search"`, `"remember_fact"`).
    public let toolName: String
    /// Whether the tool should be enabled on the live bus.
    public var enabled: Bool
    /// When the toggle was last persisted.
    public var updatedAt: Date

    /// Creates a tool state.
    public init(toolName: String, enabled: Bool, updatedAt: Date = Date()) {
        self.toolName = toolName
        self.enabled = enabled
        self.updatedAt = updatedAt
    }
}

/// Actor managing durable per-tool enable/disable states in SQLite.
///
/// Backed by `episodes.db` (`tool_states` table) and funneled through the
/// shared serial store queue so concurrent toggles never race. An absent row
/// means no operator override exists, so callers keep the bus default
/// (enabled) instead of inventing a stored value.
public actor ToolStateStore {
    private let dbPath: String
    private var cached: [String: Bool] = [:]
    private var isLoaded = false

    /// Creates a tool state store pointing to a SQLite database.
    /// - Parameter dbPath: SQLite database file path (e.g. `episodes.db`).
    public init(dbPath: String) {
        self.dbPath = dbPath
    }

    /// Loads every stored toggle into memory, initializing tables if needed.
    /// - Parameter forceReload: If true, clears the in-memory cache and re-reads from SQLite.
    /// - Returns: Mapping of tool name to stored enabled flag.
    public func loadAll(forceReload: Bool = false) async -> [String: Bool] {
        if isLoaded, !forceReload {
            return cached
        }
        if forceReload {
            cached.removeAll()
        }

        let loaded = await SQLiteSerialIO.runUncancellable {
            SQLiteToolStateStore.read(dbPath: self.dbPath)
        }

        for state in loaded {
            cached[state.toolName] = state.enabled
        }
        isLoaded = true
        return cached
    }

    /// Reloads every stored toggle from SQLite, refreshing external mutations.
    /// - Returns: Mapping of tool name to stored enabled flag.
    public func reload() async -> [String: Bool] {
        await loadAll(forceReload: true)
    }

    /// Returns the stored flag for one tool, if an operator ever toggled it.
    ///
    /// A nil result means no row exists, so the caller should keep the bus
    /// default rather than treating the tool as disabled.
    /// - Parameter toolName: Registered tool name.
    /// - Returns: Stored flag, or nil when no override exists.
    public func isEnabled(toolName: String) async -> Bool? {
        let trimmed = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        _ = await loadAll()
        return cached[trimmed]
    }

    /// Persists the enabled flag for any registered tool name.
    ///
    /// Accepts every tool name including memory tools; unknown names persist
    /// harmlessly and simply never match a bus registration on restore.
    /// Empty names are ignored so blank route input never creates dead rows.
    /// - Parameters:
    ///   - toolName: Registered tool name.
    ///   - enabled: Whether the tool should be enabled.
    public func setEnabled(toolName: String, enabled: Bool) async {
        let trimmed = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = await loadAll()
        cached[trimmed] = enabled
        let state = ToolState(toolName: trimmed, enabled: enabled, updatedAt: Date())
        await SQLiteSerialIO.runUncancellable {
            SQLiteToolStateStore.upsert(state: state, dbPath: self.dbPath)
        }
    }
}

// MARK: - SQLite Helpers

private struct ToolStateStoreDBError: Error {
    let message: String
}

private enum SQLiteToolStateStore {
    static func open(dbPath: String) throws -> OpaquePointer? {
        #if canImport(SQLite3)
            let handle = try SQLiteHelpers.openHandle(dbPath: dbPath, unavailable: { ToolStateStoreDBError(message: $0) })
            try SQLiteHelpers.exec(
                handle: handle,
                sql: """
                CREATE TABLE IF NOT EXISTS tool_states(
                    tool_name TEXT PRIMARY KEY,
                    enabled INTEGER NOT NULL,
                    updated_at REAL NOT NULL
                );
                """,
                failure: { ToolStateStoreDBError(message: $0) }
            )
            return handle
        #else
            throw ToolStateStoreDBError(message: "SQLite unavailable")
        #endif
    }

    static func read(dbPath: String) -> [ToolState] {
        #if canImport(SQLite3)
            guard let handle = try? open(dbPath: dbPath) else { return [] }
            defer { sqlite3_close(handle) }

            let sql = """
            SELECT tool_name, enabled, updated_at
            FROM tool_states
            ORDER BY tool_name ASC;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                return []
            }
            defer { sqlite3_finalize(statement) }

            var states: [ToolState] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let name = SQLiteHelpers.columnText(statement, index: 0) else { continue }
                let enabledValue = SQLiteHelpers.columnInt64(statement, index: 1) ?? 1
                let updatedAt = Date(timeIntervalSince1970: SQLiteHelpers.columnDouble(statement, index: 2))
                states.append(ToolState(toolName: name, enabled: enabledValue != 0, updatedAt: updatedAt))
            }
            return states
        #else
            return []
        #endif
    }

    static func upsert(state: ToolState, dbPath: String) {
        #if canImport(SQLite3)
            let handle: OpaquePointer?
            do {
                handle = try open(dbPath: dbPath)
            } catch {
                fputs("[ERROR] ToolStateStore: failed opening store at \(dbPath): \(error)\n", stderr)
                return
            }
            guard let handle else { return }
            defer { sqlite3_close(handle) }

            let sql = """
            INSERT INTO tool_states(tool_name, enabled, updated_at)
            VALUES(?, ?, ?)
            ON CONFLICT(tool_name) DO UPDATE SET
                enabled = excluded.enabled,
                updated_at = excluded.updated_at;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(statement) }

            SQLiteHelpers.bindText(statement, index: 1, value: state.toolName)
            sqlite3_bind_int64(statement, 2, state.enabled ? 1 : 0)
            sqlite3_bind_double(statement, 3, state.updatedAt.timeIntervalSince1970)

            _ = sqlite3_step(statement)
        #endif
    }
}

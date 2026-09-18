// Rune Weaver Server — In-memory run log and execution audit store.

import Foundation
import RuneWeaverCore

/// One recorded run: a chat turn or a scheduler job execution.
public struct RunLogEntry: Sendable, Codable, Equatable, Identifiable {
    /// Stable entry identifier.
    public let id: UUID
    /// Owning scheduler job, when this run came from a job.
    public let jobID: UUID?
    /// Owning chat session, when the run came from an interactive turn or a deterministic scheduler session.
    public let sessionID: UUID?
    /// Run kind (`"chat"`, `"scheduler"`, or `"tool"`).
    public let kind: String
    /// Outcome (`"ok"`, `"error"`, `"skipped"`, `"running"`, `"interrupted"`,
    /// `"cancelled"`, `"awaiting_approval"`, or `"denied"`).
    public let status: String
    /// Human-readable summary (user text or job prompt).
    public let message: String
    /// When the run finished.
    public let timestamp: Date
    /// Assistant response or execution output.
    public let response: String?
    /// Tools executed during this run.
    public let toolActions: [ToolAction]
    /// Total tokens billed for this run.
    public let totalTokens: Int?
    /// Execution duration in milliseconds.
    public let durationMs: Int?

    /// Coding keys matching the JSON wire shape.
    private enum CodingKeys: String, CodingKey {
        /// Stable entry identifier.
        case id
        /// Owning scheduler job, when present.
        case jobID
        /// Owning session, when tagged.
        case sessionID
        /// Run kind.
        case kind
        /// Outcome status.
        case status
        /// Human-readable summary.
        case message
        /// Finish date.
        case timestamp
        /// Assistant response or job output.
        case response
        /// Tools invoked during the run.
        case toolActions
        /// Billed tokens.
        case totalTokens
        /// Execution duration in milliseconds.
        case durationMs
    }

    /// Creates a run log entry.
    public init(
        id: UUID = UUID(),
        jobID: UUID? = nil,
        sessionID: UUID? = nil,
        kind: String,
        status: String,
        message: String,
        timestamp: Date = Date(),
        response: String? = nil,
        toolActions: [ToolAction] = [],
        totalTokens: Int? = nil,
        durationMs: Int? = nil
    ) {
        self.id = id
        self.jobID = jobID
        self.sessionID = sessionID
        self.kind = kind
        self.status = status
        self.message = message
        self.timestamp = timestamp
        self.response = response
        self.toolActions = toolActions
        self.totalTokens = totalTokens
        self.durationMs = durationMs
    }

    /// Decodes an entry, tolerating payloads written before session tagging.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.jobID = try container.decodeIfPresent(UUID.self, forKey: .jobID)
        self.sessionID = try container.decodeIfPresent(UUID.self, forKey: .sessionID)
        self.kind = try container.decode(String.self, forKey: .kind)
        self.status = try container.decode(String.self, forKey: .status)
        self.message = try container.decode(String.self, forKey: .message)
        self.timestamp = try container.decode(Date.self, forKey: .timestamp)
        self.response = try container.decodeIfPresent(String.self, forKey: .response)
        self.toolActions = try container.decodeIfPresent([ToolAction].self, forKey: .toolActions) ?? []
        self.totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens)
        self.durationMs = try container.decodeIfPresent(Int.self, forKey: .durationMs)
    }

    /// Encodes an entry, omitting the session tag when untagged.
    /// - Parameter encoder: Destination encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(jobID, forKey: .jobID)
        try container.encodeIfPresent(sessionID, forKey: .sessionID)
        try container.encode(kind, forKey: .kind)
        try container.encode(status, forKey: .status)
        try container.encode(message, forKey: .message)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(response, forKey: .response)
        try container.encode(toolActions, forKey: .toolActions)
        try container.encodeIfPresent(totalTokens, forKey: .totalTokens)
        try container.encodeIfPresent(durationMs, forKey: .durationMs)
    }
}

#if canImport(SQLite3)
    import SQLite3
#endif

/// In-memory and SQLite-persisted append-only store for run log entries.
public actor RunLogStore {
    /// Maximum characters kept per entry message; longer messages are
    /// truncated with a trailing `…`.
    public static let maxMessageLength = 1000
    /// Maximum characters kept per response output.
    public static let maxResponseLength = 50000
    /// Maximum entries kept; oldest entries drop first.
    public let capacity: Int
    /// Optional filesystem path for SQLite persistence.
    public let dbPath: String?
    /// Entries in append order.
    private var entries: [RunLogEntry] = []

    /// Creates a run log store.
    public init(capacity: Int = 500, dbPath: String? = nil) {
        self.capacity = max(1, capacity)
        self.dbPath = dbPath
    }

    /// Loads a store hydrated from durable SQLite state.
    public static func load(capacity: Int = 500, dbPath: String? = nil) async -> RunLogStore {
        let store = RunLogStore(capacity: capacity, dbPath: dbPath)
        await store.bootstrap()
        return store
    }

    /// Hydrates entries from durable SQLite state.
    public func bootstrap() async {
        guard let dbPath else { return }
        #if canImport(SQLite3)
            let pruneCap = capacity
            var loaded: [RunLogEntry]
            do {
                loaded = try await SQLiteSerialIO.run {
                    SQLiteRunLogStore.read(dbPath: dbPath, limit: pruneCap)
                }
            } catch {
                RuneWeaverLog.stores.error("RunLogStore: failed reading entries from SQLite: \(error.localizedDescription)")
                loaded = []
            }
            for index in loaded.indices where loaded[index].status == "running" {
                let reconciled = RunLogEntry(
                    id: loaded[index].id,
                    jobID: loaded[index].jobID,
                    sessionID: loaded[index].sessionID,
                    kind: loaded[index].kind,
                    status: "interrupted",
                    message: loaded[index].message,
                    timestamp: loaded[index].timestamp,
                    response: loaded[index].response ?? "Process restarted while run was in progress",
                    toolActions: loaded[index].toolActions,
                    totalTokens: loaded[index].totalTokens,
                    durationMs: loaded[index].durationMs
                )
                loaded[index] = reconciled
                await SQLiteSerialIO.runUncancellable {
                    SQLiteRunLogStore.write(entry: reconciled, dbPath: dbPath, pruneCapacity: pruneCap)
                }
            }
            entries = loaded
        #endif
    }

    /// Appends one entry, evicting the oldest when over capacity.
    @discardableResult
    public func append(
        kind: String,
        status: String,
        message: String,
        jobID: UUID? = nil,
        sessionID: UUID? = nil,
        response: String? = nil,
        toolActions: [ToolAction] = [],
        totalTokens: Int? = nil,
        durationMs: Int? = nil
    ) async -> RunLogEntry {
        let entry = RunLogEntry(
            jobID: jobID,
            sessionID: sessionID,
            kind: kind,
            status: status,
            message: Self.truncated(message),
            response: response.map(Self.truncatedResponse),
            toolActions: toolActions,
            totalTokens: totalTokens,
            durationMs: durationMs
        )
        await append(entry)
        return entry
    }

    /// Appends a prebuilt entry, evicting the oldest when over capacity.
    public func append(_ entry: RunLogEntry) async {
        let stored = RunLogEntry(
            id: entry.id,
            jobID: entry.jobID,
            sessionID: entry.sessionID,
            kind: entry.kind,
            status: entry.status,
            message: Self.truncated(entry.message),
            timestamp: entry.timestamp,
            response: entry.response.map(Self.truncatedResponse),
            toolActions: entry.toolActions,
            totalTokens: entry.totalTokens,
            durationMs: entry.durationMs
        )
        entries.append(stored)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        if let dbPath {
            #if canImport(SQLite3)
                let pruneCap = capacity
                await SQLiteSerialIO.runUncancellable {
                    SQLiteRunLogStore.write(entry: stored, dbPath: dbPath, pruneCapacity: pruneCap)
                }
            #endif
        }
    }

    /// Updates an existing run entry by identifier.
    @discardableResult
    public func update(
        id: UUID,
        status: String,
        response: String? = nil,
        toolActions: [ToolAction]? = nil,
        totalTokens: Int? = nil,
        durationMs: Int? = nil
    ) async -> RunLogEntry? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        let existing = entries[index]
        let updated = RunLogEntry(
            id: existing.id,
            jobID: existing.jobID,
            sessionID: existing.sessionID,
            kind: existing.kind,
            status: status,
            message: existing.message,
            timestamp: existing.timestamp,
            response: response.map(Self.truncatedResponse) ?? existing.response,
            toolActions: toolActions ?? existing.toolActions,
            totalTokens: totalTokens ?? existing.totalTokens,
            durationMs: durationMs ?? existing.durationMs
        )
        entries[index] = updated
        if let dbPath {
            #if canImport(SQLite3)
                let pruneCap = capacity
                await SQLiteSerialIO.runUncancellable {
                    SQLiteRunLogStore.write(entry: updated, dbPath: dbPath, pruneCapacity: pruneCap)
                }
            #endif
        }
        return updated
    }

    /// Truncates a run-log message to the fixed bound.
    /// - Parameter message: Raw message.
    /// - Returns: Message capped at `maxMessageLength` characters.
    public static func truncated(_ message: String) -> String {
        guard message.count > maxMessageLength else { return message }
        return String(message.prefix(maxMessageLength)) + "…"
    }

    /// Truncates a response output to the fixed bound.
    /// - Parameter response: Raw response.
    /// - Returns: Response capped at `maxResponseLength` characters.
    public static func truncatedResponse(_ response: String) -> String {
        guard response.count > maxResponseLength else { return response }
        return String(response.prefix(maxResponseLength)) + "…"
    }

    /// Lists entries, newest first.
    public func list(limit: Int = 50, jobID: UUID? = nil, sessionID: UUID? = nil) async -> [RunLogEntry] {
        guard limit > 0 else { return [] }
        let matching = entries.filter { entry in
            if let jobID, entry.jobID != jobID {
                return false
            }
            if let sessionID, entry.sessionID != sessionID {
                return false
            }
            return true
        }
        return Array(matching.suffix(limit).reversed())
    }

    /// Looks up one entry.
    public func entry(id: UUID) async -> RunLogEntry? {
        entries.first { $0.id == id }
    }

    /// Number of stored entries.
    public func count() async -> Int {
        entries.count
    }

    /// Removes every entry.
    public func clear() async {
        entries.removeAll()
        if let dbPath {
            #if canImport(SQLite3)
                await SQLiteSerialIO.runUncancellable {
                    SQLiteRunLogStore.clear(dbPath: dbPath)
                }
            #endif
        }
    }

    /// Removes a specific run entry by identifier.
    /// - Parameter id: Entry identifier.
    public func delete(id: UUID) async {
        entries.removeAll { $0.id == id }
        if let dbPath {
            #if canImport(SQLite3)
                await SQLiteSerialIO.runUncancellable {
                    SQLiteRunLogStore.delete(id: id, dbPath: dbPath)
                }
            #endif
        }
    }
}

/// Shared SQLite open helper for the server stores.
/// Centralizes the open-plus-log fallback so every read/write/clear/delete
/// degrades to in-memory state with one consistent log line instead of each
/// call site repeating its own do/catch; callers keep their domain fallback
/// note so the log still says what was preserved.
enum SQLiteOpenHelper {
    /// Opens a handle, logging once when the database is unavailable.
    /// - Parameters:
    ///   - dbPath: SQLite file path being opened.
    ///   - storeName: Owning store for the log prefix.
    ///   - fallbackNote: What the caller preserves in memory when open fails.
    ///   - open: Database-specific open plus migrate closure.
    /// - Returns: Open handle, or nil when unavailable (already logged).
    static func openLogged(
        dbPath: String,
        storeName: String,
        fallbackNote: String,
        open: () throws -> OpaquePointer?
    ) -> OpaquePointer? {
        do {
            guard let handle = try open() else {
                RuneWeaverLog.stores.error("\(storeName): failed opening store at \(dbPath): nil handle; \(fallbackNote).")
                return nil
            }
            return handle
        } catch {
            RuneWeaverLog.stores.error("\(storeName): failed opening store at \(dbPath): \(error.localizedDescription); \(fallbackNote).")
            return nil
        }
    }
}

#if canImport(SQLite3)
    /// Internal SQLite helper for durable run-log persistence.
    enum SQLiteRunLogStore {
        private struct RunLogError: Error {
            let message: String
        }

        private static func open(dbPath: String) throws -> OpaquePointer? {
            // Shared busy_timeout/WAL policy lives in `SQLiteHelpers.openHandle`.
            let handle = try SQLiteHelpers.openHandle(dbPath: dbPath, unavailable: { RunLogError(message: $0) })
            try SQLiteHelpers.exec(
                handle: handle,
                sql: """
                CREATE TABLE IF NOT EXISTS run_logs(
                    id TEXT PRIMARY KEY,
                    job_id TEXT,
                    session_id TEXT,
                    kind TEXT NOT NULL,
                    status TEXT NOT NULL,
                    message TEXT NOT NULL,
                    timestamp REAL NOT NULL,
                    response TEXT,
                    tool_actions TEXT,
                    total_tokens INTEGER,
                    duration_ms INTEGER
                );
                CREATE INDEX IF NOT EXISTS idx_run_logs_job_id ON run_logs(job_id);
                CREATE INDEX IF NOT EXISTS idx_run_logs_timestamp ON run_logs(timestamp);
                """,
                failure: { RunLogError(message: $0) }
            )
            // Best-effort migration for databases created before session linkage:
            // existing tables gain the column once, later opens no-op on duplicate.
            do {
                try SQLiteHelpers.exec(
                    handle: handle,
                    sql: "ALTER TABLE run_logs ADD COLUMN session_id TEXT;",
                    failure: { RunLogError(message: $0) }
                )
            } catch {
                RuneWeaverLog.stores.debug("SQLiteRunLogStore: session_id column migration note: \(error.localizedDescription)")
            }
            do {
                try SQLiteHelpers.exec(
                    handle: handle,
                    sql: "CREATE INDEX IF NOT EXISTS idx_run_logs_session_id ON run_logs(session_id);",
                    failure: { RunLogError(message: $0) }
                )
            } catch {
                RuneWeaverLog.stores.warning("SQLiteRunLogStore: failed creating session_id index: \(error.localizedDescription)")
            }
            return handle
        }

        static func read(dbPath: String, limit: Int) -> [RunLogEntry] {
            guard limit > 0 else { return [] }
            guard let handle = SQLiteOpenHelper.openLogged(
                dbPath: dbPath,
                storeName: "SQLiteRunLogStore",
                fallbackNote: "read returning in-memory state only",
                open: { try open(dbPath: dbPath) }
            ) else {
                return []
            }
            defer { sqlite3_close(handle) }

            let sql = """
            SELECT id, job_id, session_id, kind, status, message, timestamp, response, tool_actions, total_tokens, duration_ms
            FROM (
                SELECT rowid, id, job_id, session_id, kind, status, message, timestamp, response, tool_actions, total_tokens, duration_ms
                FROM run_logs
                ORDER BY timestamp DESC, rowid DESC
                LIMIT ?
            ) ORDER BY timestamp ASC, rowid ASC;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                return []
            }
            defer { sqlite3_finalize(statement) }

            // Clamp to the 32-bit bind range and fail closed when the bind
            // itself is rejected, so an oversized caller limit can never wrap
            // into a negative LIMIT and silently return the wrong rows.
            guard sqlite3_bind_int(statement, 1, SQLiteHelpers.sqliteLimit(limit)) == SQLITE_OK else {
                let code = sqlite3_errcode(handle)
                RuneWeaverLog.stores.error("SQLiteRunLogStore: failed binding run read limit (code \(code)).")
                return []
            }

            var loaded: [RunLogEntry] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let idStr = SQLiteHelpers.columnText(statement, index: 0),
                      let id = UUID(uuidString: idStr),
                      let kind = SQLiteHelpers.columnText(statement, index: 3),
                      let status = SQLiteHelpers.columnText(statement, index: 4),
                      let message = SQLiteHelpers.columnText(statement, index: 5)
                else { continue }

                let jobID = SQLiteHelpers.columnText(statement, index: 1).flatMap { UUID(uuidString: $0) }
                let sessionID = SQLiteHelpers.columnText(statement, index: 2).flatMap { UUID(uuidString: $0) }
                let timestamp = Date(timeIntervalSince1970: SQLiteHelpers.columnDouble(statement, index: 6))
                let response = SQLiteHelpers.columnText(statement, index: 7)
                let toolActionsText = SQLiteHelpers.columnText(statement, index: 8)
                let toolActions = toolActionsText.flatMap { raw in
                    raw.data(using: .utf8).flatMap { try? JSONDecoder().decode([ToolAction].self, from: $0) }
                } ?? []
                let totalTokens = SQLiteHelpers.columnInt64(statement, index: 9).map { Int($0) }
                let durationMs = SQLiteHelpers.columnInt64(statement, index: 10).map { Int($0) }

                loaded.append(RunLogEntry(
                    id: id,
                    jobID: jobID,
                    sessionID: sessionID,
                    kind: kind,
                    status: status,
                    message: message,
                    timestamp: timestamp,
                    response: response,
                    toolActions: toolActions,
                    totalTokens: totalTokens,
                    durationMs: durationMs
                ))
            }
            return loaded
        }

        static func write(entry: RunLogEntry, dbPath: String, pruneCapacity: Int) {
            guard let handle = SQLiteOpenHelper.openLogged(
                dbPath: dbPath,
                storeName: "SQLiteRunLogStore",
                fallbackNote: "run \(entry.id) kept in memory only and will not survive restart",
                open: { try open(dbPath: dbPath) }
            ) else {
                return
            }
            defer { sqlite3_close(handle) }

            let sql = """
            INSERT OR REPLACE INTO run_logs(id, job_id, session_id, kind, status, message, timestamp, response, tool_actions, total_tokens, duration_ms)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                let code = sqlite3_errcode(handle)
                RuneWeaverLog.stores.error("SQLiteRunLogStore: failed preparing run write (code \(code)); run \(entry.id) kept in memory only.")
                return
            }
            defer { sqlite3_finalize(statement) }

            SQLiteHelpers.bindText(statement, index: 1, value: entry.id.uuidString)
            SQLiteHelpers.bindText(statement, index: 2, value: entry.jobID?.uuidString)
            SQLiteHelpers.bindText(statement, index: 3, value: entry.sessionID?.uuidString)
            SQLiteHelpers.bindText(statement, index: 4, value: entry.kind)
            SQLiteHelpers.bindText(statement, index: 5, value: entry.status)
            SQLiteHelpers.bindText(statement, index: 6, value: entry.message)
            SQLiteHelpers.bindDouble(statement, index: 7, value: entry.timestamp.timeIntervalSince1970)
            SQLiteHelpers.bindText(statement, index: 8, value: entry.response)
            let toolActionsJSON = (try? JSONEncoder().encode(entry.toolActions)).flatMap { String(data: $0, encoding: .utf8) }
            SQLiteHelpers.bindText(statement, index: 9, value: toolActionsJSON)
            SQLiteHelpers.bindInt64(statement, index: 10, value: entry.totalTokens.map { Int64($0) })
            SQLiteHelpers.bindInt64(statement, index: 11, value: entry.durationMs.map { Int64($0) })

            guard sqlite3_step(statement) == SQLITE_DONE else {
                let code = sqlite3_errcode(handle)
                RuneWeaverLog.stores.error("SQLiteRunLogStore: failed writing run \(entry.id) (code \(code)); in-memory state is ahead of disk.")
                return
            }

            // Prune excess rows beyond capacity with a bound limit so the
            // capacity value never interpolates into SQL text.
            if pruneCapacity > 0 {
                let pruneSQL = """
                DELETE FROM run_logs WHERE id NOT IN (
                    SELECT id FROM run_logs ORDER BY timestamp DESC, rowid DESC LIMIT ?
                );
                """
                var pruneStatement: OpaquePointer?
                guard sqlite3_prepare_v2(handle, pruneSQL, -1, &pruneStatement, nil) == SQLITE_OK else {
                    let code = sqlite3_errcode(handle)
                    RuneWeaverLog.stores.error("SQLiteRunLogStore: failed preparing run prune (code \(code)).")
                    return
                }
                defer { sqlite3_finalize(pruneStatement) }
                sqlite3_bind_int64(pruneStatement, 1, Int64(max(1, pruneCapacity)))
                guard sqlite3_step(pruneStatement) == SQLITE_DONE else {
                    let code = sqlite3_errcode(handle)
                    RuneWeaverLog.stores.error("SQLiteRunLogStore: failed pruning runs (code \(code)).")
                    return
                }
            }
        }

        static func clear(dbPath: String) {
            guard let handle = SQLiteOpenHelper.openLogged(
                dbPath: dbPath,
                storeName: "SQLiteRunLogStore",
                fallbackNote: "clear kept in memory only",
                open: { try open(dbPath: dbPath) }
            ) else {
                return
            }
            defer { sqlite3_close(handle) }
            let sql = "DELETE FROM run_logs;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                let code = sqlite3_errcode(handle)
                RuneWeaverLog.stores.error("SQLiteRunLogStore: failed preparing run clear (code \(code)).")
                return
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_DONE else {
                let code = sqlite3_errcode(handle)
                RuneWeaverLog.stores.error("SQLiteRunLogStore: failed clearing runs (code \(code)).")
                return
            }
        }

        static func delete(id: UUID, dbPath: String) {
            guard let handle = SQLiteOpenHelper.openLogged(
                dbPath: dbPath,
                storeName: "SQLiteRunLogStore",
                fallbackNote: "delete of \(id) kept in memory only",
                open: { try open(dbPath: dbPath) }
            ) else {
                return
            }
            defer { sqlite3_close(handle) }
            let sql = "DELETE FROM run_logs WHERE id = ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                let code = sqlite3_errcode(handle)
                RuneWeaverLog.stores.error("SQLiteRunLogStore: failed preparing run delete (code \(code)); run \(id) kept in memory only.")
                return
            }
            defer { sqlite3_finalize(statement) }
            let idStr = id.uuidString
            SQLiteHelpers.bindText(statement, index: 1, value: idStr)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                let code = sqlite3_errcode(handle)
                RuneWeaverLog.stores.error("SQLiteRunLogStore: failed deleting run \(id) (code \(code)); in-memory state is ahead of disk.")
                return
            }
        }
    }
#endif

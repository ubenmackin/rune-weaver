// Rune Weaver Server — In-memory run log and execution audit store.
//
// Maintains an audit trail of chat turns and scheduled job firings for API
// consumers. Provides bounded in-memory FIFO retention with lock-free actor
// isolation, query limits, and job-specific history filtering.

import Foundation
import RuneWeaverCore

/// One recorded run: a chat turn or a scheduler job execution.
///
/// The run log is the audit trail for the API surface: every `POST /chat`
/// turn and every scheduler firing appends one entry so clients can review
/// what the engine did without reopening conversation history.
public struct RunLogEntry: Sendable, Codable, Equatable, Identifiable {
    /// Stable entry identifier.
    public let id: UUID
    /// Owning scheduler job, when this run came from a job.
    public let jobID: UUID?
    /// Run kind (`"chat"` or `"scheduler"`).
    public let kind: String
    /// Outcome (`"ok"`, `"error"`, or `"skipped"` for already-running jobs).
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

    /// Creates a run log entry.
    /// - Parameters:
    ///   - id: Entry identifier. Defaults to a new UUID.
    ///   - jobID: Owning scheduler job, if any.
    ///   - kind: Run kind (`"chat"` or `"scheduler"`).
    ///   - status: Outcome (`"ok"`, `"error"`, or `"skipped"`).
    ///   - message: Human-readable summary.
    ///   - timestamp: Finish date. Defaults to now.
    ///   - response: Assistant response or job output. Defaults to nil.
    ///   - toolActions: Tools invoked during the run. Defaults to empty.
    ///   - totalTokens: Billed tokens. Defaults to nil.
    ///   - durationMs: Execution duration in milliseconds. Defaults to nil.
    public init(
        id: UUID = UUID(),
        jobID: UUID? = nil,
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
        self.kind = kind
        self.status = status
        self.message = message
        self.timestamp = timestamp
        self.response = response
        self.toolActions = toolActions
        self.totalTokens = totalTokens
        self.durationMs = durationMs
    }
}

#if canImport(SQLite3)
    import SQLite3
#endif

/// In-memory and SQLite-persisted append-only store for run log entries.
///
/// Single owner of run history so REST (`GET /runs`), the chat path, and
/// the scheduler firing path share one audit trail. When configured with
/// `dbPath` (e.g. `episodes.db`), entries persist across server restarts.
/// Stored messages are truncated to `maxMessageLength` characters so one
/// huge `POST /chat` body cannot exhaust storage.
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
    ///
    /// Memory only and never touches disk: actor initializers cannot
    /// suspend, so synchronous SQLite reads here would block the
    /// cooperative pool at startup. Disk hydration (including
    /// `running` reconciliation) lives in `bootstrap()`; prefer
    /// `load(capacity:dbPath:)` whenever durable state matters.
    /// - Parameters:
    ///   - capacity: Maximum entries kept. Defaults to 500.
    ///   - dbPath: SQLite database file path. Defaults to nil (in-memory only).
    public init(capacity: Int = 500, dbPath: String? = nil) {
        self.capacity = max(1, capacity)
        self.dbPath = dbPath
    }

    /// Loads a store hydrated from durable SQLite state.
    ///
    /// Creates the store, then suspends on the shared serial store queue
    /// to adopt persisted entries and reconcile stale `running` rows to
    /// `interrupted`, so startup disk I/O never blocks the cooperative
    /// pool.
    /// - Parameters:
    ///   - capacity: Maximum entries kept. Defaults to 500.
    ///   - dbPath: SQLite database file path. Defaults to nil (in-memory only).
    /// - Returns: Store reflecting durable state.
    public static func load(capacity: Int = 500, dbPath: String? = nil) async -> RunLogStore {
        let store = RunLogStore(capacity: capacity, dbPath: dbPath)
        await store.bootstrap()
        return store
    }

    /// Hydrates entries from durable SQLite state.
    ///
    /// Adopts persisted entries and reconciles stale `running` rows left
    /// by abnormal termination to `interrupted`, writing each
    /// reconciliation back. No-op without a `dbPath`. Durable reads
    /// observe cancellation so shutdown never blocks on disk I/O;
    /// reconciliation writes run to completion so the audit trail lands.
    public func bootstrap() async {
        guard let dbPath else { return }
        #if canImport(SQLite3)
            let pruneCap = capacity
            var loaded: [RunLogEntry] = await (try? SQLiteSerialIO.run {
                SQLiteRunLogStore.read(dbPath: dbPath, limit: pruneCap)
            }) ?? []
            for index in loaded.indices where loaded[index].status == "running" {
                let reconciled = RunLogEntry(
                    id: loaded[index].id,
                    jobID: loaded[index].jobID,
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
    ///
    /// The message is truncated to `maxMessageLength` characters (with a
    /// trailing `…`) so capacity bounds bytes as well as entry count.
    /// - Parameters:
    ///   - kind: Run kind (`"chat"` or `"scheduler"`).
    ///   - status: Outcome (`"ok"`, `"error"`, or `"skipped"`).
    ///   - message: Human-readable summary.
    ///   - jobID: Owning scheduler job, if any.
    ///   - response: Assistant response text, if any.
    ///   - toolActions: Tools invoked during the run.
    ///   - totalTokens: Billed tokens.
    ///   - durationMs: Execution duration in milliseconds.
    /// - Returns: The stored entry.
    @discardableResult
    public func append(
        kind: String,
        status: String,
        message: String,
        jobID: UUID? = nil,
        response: String? = nil,
        toolActions: [ToolAction] = [],
        totalTokens: Int? = nil,
        durationMs: Int? = nil
    ) async -> RunLogEntry {
        let entry = RunLogEntry(
            jobID: jobID,
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
    ///
    /// The entry message is truncated to `maxMessageLength` characters
    /// before storage.
    /// - Parameter entry: Entry to store.
    public func append(_ entry: RunLogEntry) async {
        let stored = RunLogEntry(
            id: entry.id,
            jobID: entry.jobID,
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
    /// - Parameters:
    ///   - id: Target entry identifier.
    ///   - status: New status (e.g. "ok", "error", "cancelled").
    ///   - response: Final assistant response, if any.
    ///   - toolActions: Tool actions executed, if any.
    ///   - totalTokens: Billed tokens, if any.
    ///   - durationMs: Total duration in milliseconds, if any.
    /// - Returns: The updated entry, or nil if not found.
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
    ///
    /// Memory-only snapshot of the bounded audit trail; durable rows are
    /// adopted via `bootstrap()` and `load(capacity:dbPath:)`.
    /// - Parameters:
    ///   - limit: Maximum entries. Defaults to 50. Non-positive limits return an empty list.
    ///   - jobID: Optional scheduler job filter.
    /// - Returns: Entries newest first.
    public func list(limit: Int = 50, jobID: UUID? = nil) async -> [RunLogEntry] {
        guard limit > 0 else { return [] }
        let matching = entries.filter { entry in
            if let jobID {
                return entry.jobID == jobID
            }
            return true
        }
        return Array(matching.suffix(limit).reversed())
    }

    /// Looks up one entry.
    ///
    /// Memory-only read of the bounded audit trail.
    /// - Parameter id: Entry identifier.
    /// - Returns: The entry, or nil when unknown.
    public func entry(id: UUID) async -> RunLogEntry? {
        entries.first { $0.id == id }
    }

    /// Number of stored entries.
    ///
    /// Memory-only count of the bounded audit trail.
    /// - Returns: Entry count.
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
            return handle
        }

        static func read(dbPath: String, limit: Int) -> [RunLogEntry] {
            guard limit > 0 else { return [] }
            guard let handle = try? open(dbPath: dbPath) else { return [] }
            defer { sqlite3_close(handle) }

            let sql = """
            SELECT id, job_id, kind, status, message, timestamp, response, tool_actions, total_tokens, duration_ms
            FROM run_logs
            ORDER BY timestamp ASC, rowid ASC;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                return []
            }
            defer { sqlite3_finalize(statement) }

            var loaded: [RunLogEntry] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let idStr = SQLiteHelpers.columnText(statement, index: 0),
                      let id = UUID(uuidString: idStr),
                      let kind = SQLiteHelpers.columnText(statement, index: 2),
                      let status = SQLiteHelpers.columnText(statement, index: 3),
                      let message = SQLiteHelpers.columnText(statement, index: 4)
                else { continue }

                let jobID = SQLiteHelpers.columnText(statement, index: 1).flatMap { UUID(uuidString: $0) }
                let timestamp = Date(timeIntervalSince1970: SQLiteHelpers.columnDouble(statement, index: 5))
                let response = SQLiteHelpers.columnText(statement, index: 6)
                let toolActionsText = SQLiteHelpers.columnText(statement, index: 7)
                let toolActions = toolActionsText.flatMap { raw in
                    raw.data(using: .utf8).flatMap { try? JSONDecoder().decode([ToolAction].self, from: $0) }
                } ?? []
                let totalTokens = SQLiteHelpers.columnInt64(statement, index: 8).map { Int($0) }
                let durationMs = SQLiteHelpers.columnInt64(statement, index: 9).map { Int($0) }

                loaded.append(RunLogEntry(
                    id: id,
                    jobID: jobID,
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
            if loaded.count > limit {
                return Array(loaded.suffix(limit))
            }
            return loaded
        }

        static func write(entry: RunLogEntry, dbPath: String, pruneCapacity: Int) {
            guard let handle = try? open(dbPath: dbPath) else {
                fputs(
                    "[ERROR] SQLiteRunLogStore: failed opening store"
                        + " at \(dbPath); run \(entry.id) kept"
                        + " in memory only and will not survive restart.\n",
                    stderr
                )
                return
            }
            defer { sqlite3_close(handle) }

            let sql = """
            INSERT OR REPLACE INTO run_logs(id, job_id, kind, status, message, timestamp, response, tool_actions, total_tokens, duration_ms)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                let code = sqlite3_errcode(handle)
                fputs("[ERROR] SQLiteRunLogStore: failed preparing run write (code \(code)); run \(entry.id) kept in memory only.\n", stderr)
                return
            }
            defer { sqlite3_finalize(statement) }

            SQLiteHelpers.bindText(statement, index: 1, value: entry.id.uuidString)
            SQLiteHelpers.bindText(statement, index: 2, value: entry.jobID?.uuidString)
            SQLiteHelpers.bindText(statement, index: 3, value: entry.kind)
            SQLiteHelpers.bindText(statement, index: 4, value: entry.status)
            SQLiteHelpers.bindText(statement, index: 5, value: entry.message)
            SQLiteHelpers.bindDouble(statement, index: 6, value: entry.timestamp.timeIntervalSince1970)
            SQLiteHelpers.bindText(statement, index: 7, value: entry.response)
            let toolActionsJSON = (try? JSONEncoder().encode(entry.toolActions)).flatMap { String(data: $0, encoding: .utf8) }
            SQLiteHelpers.bindText(statement, index: 8, value: toolActionsJSON)
            SQLiteHelpers.bindInt64(statement, index: 9, value: entry.totalTokens.map { Int64($0) })
            SQLiteHelpers.bindInt64(statement, index: 10, value: entry.durationMs.map { Int64($0) })

            guard sqlite3_step(statement) == SQLITE_DONE else {
                let code = sqlite3_errcode(handle)
                fputs("[ERROR] SQLiteRunLogStore: failed writing run \(entry.id) (code \(code)); in-memory state is ahead of disk.\n", stderr)
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
                    fputs("[ERROR] SQLiteRunLogStore: failed preparing run prune (code \(code)).\n", stderr)
                    return
                }
                defer { sqlite3_finalize(pruneStatement) }
                sqlite3_bind_int64(pruneStatement, 1, Int64(max(1, pruneCapacity)))
                guard sqlite3_step(pruneStatement) == SQLITE_DONE else {
                    let code = sqlite3_errcode(handle)
                    fputs("[ERROR] SQLiteRunLogStore: failed pruning runs (code \(code)).\n", stderr)
                    return
                }
            }
        }

        static func clear(dbPath: String) {
            guard let handle = try? open(dbPath: dbPath) else {
                fputs("[ERROR] SQLiteRunLogStore: failed opening store at \(dbPath); clear kept in memory only.\n", stderr)
                return
            }
            defer { sqlite3_close(handle) }
            do {
                try SQLiteHelpers.exec(handle: handle, sql: "DELETE FROM run_logs;", failure: { RunLogError(message: $0) })
            } catch {
                fputs("[ERROR] SQLiteRunLogStore: failed clearing runs: \(error)\n", stderr)
            }
        }
    }
#endif

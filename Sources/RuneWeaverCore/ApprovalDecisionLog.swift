// Rune Weaver Core — Approval decision log persistence for the audit trail.
//
// Purpose: own the durable record of every resolved approval decision — tool,
// scope, allow or deny, duration, surface, and when it was decided — so run
// history and the approvals inbox can answer what the owner chose without
// re-asking. The decision path records best-effort; this file owns the copy
// beside it, including oldest-first eviction past the row cap.
// Scope: the `ApprovalDecisionRecording` protocol plus an in-memory store and
// a SQLite (`episodes.db`, table `approval_decisions`) store. Scope comparison
// is never this file's job — `AccessScope.matches` is the single matcher — so
// rows store only the canonical single-value rendering of the resolved scope.
// An unreadable store yields empty reads and drops writes, never throwing
// into the decision path.
// Architectural role: storage adapter beside the permission gate, following
// the shared Core store idiom (serialized SQLite access via `SQLiteSerialIO`)
// so serve, CLI, and the menu-bar app share one persistence path. Free-form
// row fields are bounded at the entry boundary so neither store can persist
// an oversized string.

import Foundation
#if canImport(SQLite3)
    import SQLite3
#endif

/// One recorded approval decision.
public struct ApprovalDecisionEntry: Sendable, Codable, Equatable {
    /// Stable entry identifier.
    public let id: UUID
    /// Tool the decision covers.
    public let toolName: String
    /// Resolved scope kind tag, when a scope was resolved.
    public let scopeKind: String?
    /// Canonical single-value rendering of the resolved scope.
    public let scopeData: String?
    /// Whether the action was allowed.
    public let allowed: Bool
    /// Duration tier raw value carried at decision time.
    public let duration: String
    /// Surface tag (`chat`, `inbox`, `dashboard`, `websocket`, `question`, or `unknown`).
    public let surface: String
    /// Owning session identifier when tagged.
    public let sessionID: String?
    /// Display target when derivable.
    public let displayTarget: String?
    /// When the decision was made.
    public let decidedAt: Date

    /// Creates a decision entry.
    ///
    /// Free-form fields are bounded here — the one boundary both stores share —
    /// so an oversized tool name, scope rendering, duration, session id, or
    /// display target can never reach either persistence path unbounded. Truncation
    /// keeps the audit prefix rather than dropping the row: a bounded entry
    /// still answers who decided what, fail-open, exactly like the log itself.
    public init(
        id: UUID = UUID(),
        toolName: String,
        scopeKind: String? = nil,
        scopeData: String? = nil,
        allowed: Bool,
        duration: String,
        surface: String,
        sessionID: String? = nil,
        displayTarget: String? = nil,
        decidedAt: Date = Date()
    ) {
        self.id = id
        self.toolName = ApprovalDecisionLog.bounded(toolName, limit: ApprovalDecisionLog.maxToolNameChars) ?? ""
        self.scopeKind = ApprovalDecisionLog.bounded(scopeKind, limit: ApprovalDecisionLog.maxScopeKindChars)
        self.scopeData = ApprovalDecisionLog.bounded(scopeData, limit: ApprovalDecisionLog.maxScopeDataChars)
        self.allowed = allowed
        // The duration rides client-supplied decide bodies, so it is bounded
        // like the other free-form fields even though the tier vocabulary
        // (`thisTime`…`forever`) keeps real values short.
        self.duration = ApprovalDecisionLog.bounded(duration, limit: ApprovalDecisionLog.maxDurationChars) ?? ""
        // The surface tag rides client-supplied decide bodies, so it is
        // bounded like the other free-form fields even though the closed
        // vocabulary (`chat`…`unknown`) keeps real values short.
        self.surface = ApprovalDecisionLog.bounded(surface, limit: ApprovalDecisionLog.maxSurfaceChars) ?? ""
        self.sessionID = ApprovalDecisionLog.bounded(sessionID, limit: ApprovalDecisionLog.maxSessionIDChars)
        self.displayTarget = ApprovalDecisionLog.bounded(displayTarget, limit: ApprovalDecisionLog.maxDisplayTargetChars)
        self.decidedAt = decidedAt
    }

    /// Creates a decision entry from a resolved scope.
    public init(
        id: UUID = UUID(),
        toolName: String,
        scope: AccessScope?,
        allowed: Bool,
        duration: String,
        surface: String,
        sessionID: String? = nil,
        displayTarget: String? = nil,
        decidedAt: Date = Date()
    ) {
        let fields = scope.map { ApprovalDecisionLog.scopeFields(for: $0) }
        self.init(
            id: id,
            toolName: toolName,
            scopeKind: fields?.kind,
            scopeData: fields?.data,
            allowed: allowed,
            duration: duration,
            surface: surface,
            sessionID: sessionID,
            displayTarget: displayTarget,
            decidedAt: decidedAt
        )
    }
}

/// Namespace for the approval decision log cap and scope rendering.
public enum ApprovalDecisionLog {
    /// Maximum retained decision rows; appends evict oldest past this bound.
    public static let maxRows = 10000

    /// Persisted-string bounds for the audit row, mirroring how the access
    /// rule store bounds its fields through the scope canonicalizers. Tool
    /// names, surface tags, and duration tiers are short by construction;
    /// scope data and display targets mirror the rule store's path-prefix
    /// cap, and a session id is a UUID string with headroom.
    public static let maxToolNameChars = 128
    public static let maxScopeKindChars = 32
    public static let maxScopeDataChars = 1024
    public static let maxSurfaceChars = 32
    public static let maxDurationChars = 32
    public static let maxSessionIDChars = 64
    public static let maxDisplayTargetChars = 1024

    /// Bounds one persisted string to `limit` characters.
    ///
    /// Truncation preserves the identifying prefix rather than dropping or
    /// blanking the value: an over-bound audit field still answers what was
    /// decided without letting an oversized string reach the store. Nil and
    /// within-bound values pass through untouched so bounded entries compare
    /// equal to their inputs.
    public static func bounded(_ value: String?, limit: Int) -> String? {
        guard let value, value.count > limit else { return value }
        return String(value.prefix(limit))
    }

    /// Canonical single-value rendering of a resolved scope.
    public static func scopeFields(for scope: AccessScope) -> (kind: String, data: String) {
        switch scope {
        case .toolWide:
            ("toolWide", "tool")
        case let .exactTarget(target):
            ("exactTarget", target)
        case let .recipientSet(members):
            ("recipientSet", AccessScope.normalizeRecipients(members).joined(separator: ","))
        case let .domain(host, _):
            ("domain", host)
        case let .pathPrefix(path):
            ("pathPrefix", path)
        case let .glob(pattern):
            ("glob", pattern)
        }
    }
}

/// Persistence contract for approval decision entries.
public protocol ApprovalDecisionRecording: Sendable {
    /// Records one decision; never throws so the audit trail cannot block decisions.
    func append(_ entry: ApprovalDecisionEntry) async
    /// Lists decisions newest first, optionally narrowed to one exact tool
    /// name and/or one polarity. Filters are part of the store contract so
    /// callers page over the filtered set directly — a SQLite-backed store
    /// turns them into `WHERE` clauses instead of a post-fetch slice, which
    /// keeps both the page and the paired count honest for any history size.
    func list(limit: Int, offset: Int, toolName: String?, allowed: Bool?) async throws -> [ApprovalDecisionEntry]
    /// Counts stored decisions under the same optional tool/polarity narrowing.
    func count(toolName: String?, allowed: Bool?) async throws -> Int
    /// Clears all stored decisions; never throws.
    func clearAll() async
}

extension ApprovalDecisionRecording {
    /// Lists decisions newest first with no tool or polarity narrowing.
    public func list(limit: Int, offset: Int) async throws -> [ApprovalDecisionEntry] {
        try await list(limit: limit, offset: offset, toolName: nil, allowed: nil)
    }

    /// Counts every stored decision.
    public func count() async throws -> Int {
        try await count(toolName: nil, allowed: nil)
    }
}

/// In-memory decision log for tests and ephemeral sessions.
public actor InMemoryApprovalDecisionLog: ApprovalDecisionRecording {
    private var entries: [ApprovalDecisionEntry] = []
    private var sequenceByID: [UUID: Int] = [:]
    private var nextSequence = 0

    /// Creates an in-memory log.
    public init() {}

    /// Records one decision, evicting oldest past the row cap.
    public func append(_ entry: ApprovalDecisionEntry) async {
        if let existing = entries.firstIndex(where: { $0.id == entry.id }) {
            sequenceByID.removeValue(forKey: entries[existing].id)
            entries.remove(at: existing)
        }
        entries.append(entry)
        sequenceByID[entry.id] = nextSequence
        nextSequence += 1
        while entries.count > ApprovalDecisionLog.maxRows {
            guard let oldest = oldestIndex() else { break }
            sequenceByID.removeValue(forKey: entries[oldest].id)
            entries.remove(at: oldest)
        }
    }

    /// Lists decisions newest first, narrowed by the optional tool/polarity
    /// predicates before the window slices.
    public func list(limit: Int, offset: Int, toolName: String?, allowed: Bool?) async throws -> [ApprovalDecisionEntry] {
        if limit <= 0 {
            return []
        }
        let filtered = orderedNewestFirst().filter { entry in
            matches(entry, toolName: toolName, allowed: allowed)
        }
        let clampedOffset = max(0, offset)
        guard clampedOffset < filtered.count else {
            return []
        }
        return Array(filtered.dropFirst(clampedOffset).prefix(limit))
    }

    /// Counts stored decisions under the optional tool/polarity narrowing.
    public func count(toolName: String?, allowed: Bool?) async throws -> Int {
        entries.filter { matches($0, toolName: toolName, allowed: allowed) }.count
    }

    /// Clears all stored decisions.
    public func clearAll() async {
        entries.removeAll()
        sequenceByID.removeAll()
    }

    /// Single predicate read shared by the list and count paths so both
    /// answer exactly the same narrowed set.
    private func matches(_ entry: ApprovalDecisionEntry, toolName: String?, allowed: Bool?) -> Bool {
        if let toolName, entry.toolName != toolName {
            return false
        }
        if let allowed, entry.allowed != allowed {
            return false
        }
        return true
    }

    private func orderedNewestFirst() -> [ApprovalDecisionEntry] {
        entries.sorted { lhs, rhs in
            if lhs.decidedAt != rhs.decidedAt {
                return lhs.decidedAt > rhs.decidedAt
            }
            return (sequenceByID[lhs.id] ?? 0) > (sequenceByID[rhs.id] ?? 0)
        }
    }

    /// Oldest by decided-at, breaking ties by insertion order so equal
    /// timestamps evict the earliest append first.
    private func oldestIndex() -> Int? {
        guard !entries.isEmpty else {
            return nil
        }
        var best = 0
        for index in entries.indices.dropFirst() {
            let candidate = entries[index]
            let current = entries[best]
            if candidate.decidedAt < current.decidedAt {
                best = index
            } else if candidate.decidedAt == current.decidedAt,
                      (sequenceByID[candidate.id] ?? 0) < (sequenceByID[current.id] ?? 0)
            {
                best = index
            }
        }
        return best
    }
}

#if canImport(SQLite3)
    private struct ApprovalDecisionStoreError: Error {
        let message: String
    }

    private enum SQLiteApprovalDecisionStorage {
        static let insertSQL = """
        INSERT OR REPLACE INTO approval_decisions (id, tool_name, scope_kind, scope_data, allowed, duration, surface, session_id, display_target, decided_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """

        static func open(dbPath: String) throws -> OpaquePointer? {
            let handle = try SQLiteHelpers.openHandle(dbPath: dbPath, unavailable: { ApprovalDecisionStoreError(message: $0) })
            do {
                try SQLiteHelpers.exec(
                    handle: handle,
                    sql: """
                    CREATE TABLE IF NOT EXISTS approval_decisions (
                        id TEXT PRIMARY KEY,
                        tool_name TEXT NOT NULL,
                        scope_kind TEXT,
                        scope_data TEXT,
                        allowed INTEGER NOT NULL,
                        duration TEXT NOT NULL,
                        surface TEXT NOT NULL,
                        session_id TEXT,
                        display_target TEXT,
                        decided_at REAL NOT NULL
                    );
                    CREATE INDEX IF NOT EXISTS idx_approval_decisions_decided_at ON approval_decisions(decided_at DESC);
                    CREATE INDEX IF NOT EXISTS idx_approval_decisions_tool_allowed ON approval_decisions(tool_name, allowed);
                    """,
                    failure: { ApprovalDecisionStoreError(message: $0) }
                )
            } catch {
                sqlite3_close(handle)
                throw error
            }
            return handle
        }

        static func append(entry: ApprovalDecisionEntry, dbPath: String) {
            let handle: OpaquePointer?
            do {
                handle = try open(dbPath: dbPath)
            } catch {
                RuneWeaverLog.stores.error("ApprovalDecisionLog: failed opening store at \(dbPath): \(error)")
                return
            }
            guard let handle else {
                RuneWeaverLog.stores.error("ApprovalDecisionLog: failed opening store at \(dbPath): unexpected nil handle")
                return
            }
            defer { sqlite3_close(handle) }
            guard sqlite3_exec(handle, "BEGIN IMMEDIATE TRANSACTION;", nil, nil, nil) == SQLITE_OK else {
                RuneWeaverLog.stores.error("ApprovalDecisionLog: could not begin decision append")
                return
            }
            var succeeded = false
            defer {
                if succeeded {
                    if sqlite3_exec(handle, "COMMIT;", nil, nil, nil) != SQLITE_OK {
                        _ = sqlite3_exec(handle, "ROLLBACK;", nil, nil, nil)
                        RuneWeaverLog.stores.error("ApprovalDecisionLog: could not commit decision append")
                    }
                } else {
                    _ = sqlite3_exec(handle, "ROLLBACK;", nil, nil, nil)
                }
            }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, insertSQL, -1, &statement, nil) == SQLITE_OK else {
                RuneWeaverLog.stores.error("ApprovalDecisionLog: could not prepare decision insert")
                return
            }
            defer { sqlite3_finalize(statement) }
            SQLiteHelpers.bindText(statement, index: 1, value: entry.id.uuidString)
            SQLiteHelpers.bindText(statement, index: 2, value: entry.toolName)
            SQLiteHelpers.bindText(statement, index: 3, value: entry.scopeKind)
            SQLiteHelpers.bindText(statement, index: 4, value: entry.scopeData)
            SQLiteHelpers.bindInt64(statement, index: 5, value: entry.allowed ? 1 : 0)
            SQLiteHelpers.bindText(statement, index: 6, value: entry.duration)
            SQLiteHelpers.bindText(statement, index: 7, value: entry.surface)
            SQLiteHelpers.bindText(statement, index: 8, value: entry.sessionID)
            SQLiteHelpers.bindText(statement, index: 9, value: entry.displayTarget)
            SQLiteHelpers.bindDouble(statement, index: 10, value: entry.decidedAt.timeIntervalSince1970)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                RuneWeaverLog.stores.error("ApprovalDecisionLog: could not write decision row")
                return
            }
            // Same-transaction cap: newest rows survive, oldest fall off.
            let evictSQL =
                "DELETE FROM approval_decisions WHERE id NOT IN " +
                "(SELECT id FROM approval_decisions ORDER BY decided_at DESC, rowid DESC LIMIT \(ApprovalDecisionLog.maxRows));"
            var evictMessage: UnsafeMutablePointer<CChar>?
            let evictStatus = evictSQL.withCString { sqlite3_exec(handle, $0, nil, nil, &evictMessage) }
            defer { sqlite3_free(evictMessage) }
            guard evictStatus == SQLITE_OK else {
                RuneWeaverLog.stores.error("ApprovalDecisionLog: could not evict old decision rows")
                return
            }
            succeeded = true
        }

        static func list(
            limit: Int,
            offset: Int,
            toolName: String?,
            allowed: Bool?,
            dbPath: String
        ) -> [ApprovalDecisionEntry] {
            if limit <= 0 {
                return []
            }
            let handle: OpaquePointer?
            do {
                handle = try open(dbPath: dbPath)
            } catch {
                RuneWeaverLog.stores.error("ApprovalDecisionLog: failed opening store at \(dbPath): \(error)")
                return []
            }
            guard let handle else {
                RuneWeaverLog.stores.error("ApprovalDecisionLog: failed opening store at \(dbPath): unexpected nil handle")
                return []
            }
            defer { sqlite3_close(handle) }
            // The filters ride the SELECT as WHERE clauses so the page and the
            // paired filtered count both reflect the query, whatever the
            // unfiltered history size is.
            var predicates: [String] = []
            if toolName != nil {
                predicates.append("tool_name = ?")
            }
            if allowed != nil {
                predicates.append("allowed = ?")
            }
            let whereSQL = predicates.isEmpty ? "" : " WHERE " + predicates.joined(separator: " AND ")
            let sql = """
            SELECT id, tool_name, scope_kind, scope_data, allowed, duration, surface, session_id, display_target, decided_at
            FROM approval_decisions\(whereSQL) ORDER BY decided_at DESC, rowid DESC LIMIT ? OFFSET ?;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                RuneWeaverLog.stores.error("ApprovalDecisionLog: failed preparing decision list.")
                return []
            }
            defer { sqlite3_finalize(statement) }
            var bindIndex: Int32 = 1
            if let toolName {
                SQLiteHelpers.bindText(statement, index: bindIndex, value: toolName)
                bindIndex += 1
            }
            if let allowed {
                SQLiteHelpers.bindInt64(statement, index: bindIndex, value: allowed ? 1 : 0)
                bindIndex += 1
            }
            sqlite3_bind_int(statement, bindIndex, SQLiteHelpers.sqliteLimit(limit))
            sqlite3_bind_int(statement, bindIndex + 1, SQLiteHelpers.sqliteLimit(max(0, offset)))
            var results: [ApprovalDecisionEntry] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                // A poison row skips itself rather than aborting the audit read.
                guard let entry = entry(from: statement) else { continue }
                results.append(entry)
            }
            return results
        }

        static func count(toolName: String?, allowed: Bool?, dbPath: String) -> Int {
            let handle: OpaquePointer?
            do {
                handle = try open(dbPath: dbPath)
            } catch {
                RuneWeaverLog.stores.error("ApprovalDecisionLog: failed opening store at \(dbPath): \(error)")
                return 0
            }
            guard let handle else {
                RuneWeaverLog.stores.error("ApprovalDecisionLog: failed opening store at \(dbPath): unexpected nil handle")
                return 0
            }
            defer { sqlite3_close(handle) }
            // The count applies the same predicates as the list so a filtered
            // page always reports its true total, not the unfiltered size.
            var predicates: [String] = []
            if toolName != nil {
                predicates.append("tool_name = ?")
            }
            if allowed != nil {
                predicates.append("allowed = ?")
            }
            let whereSQL = predicates.isEmpty ? "" : " WHERE " + predicates.joined(separator: " AND ")
            let sql = "SELECT COUNT(*) FROM approval_decisions\(whereSQL);"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                RuneWeaverLog.stores.error("ApprovalDecisionLog: failed preparing decision count.")
                return 0
            }
            defer { sqlite3_finalize(statement) }
            var bindIndex: Int32 = 1
            if let toolName {
                SQLiteHelpers.bindText(statement, index: bindIndex, value: toolName)
                bindIndex += 1
            }
            if let allowed {
                SQLiteHelpers.bindInt64(statement, index: bindIndex, value: allowed ? 1 : 0)
                bindIndex += 1
            }
            guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(statement, 0))
        }

        static func clearAll(dbPath: String) {
            let handle: OpaquePointer?
            do {
                handle = try open(dbPath: dbPath)
            } catch {
                RuneWeaverLog.stores.error("ApprovalDecisionLog: failed opening store at \(dbPath): \(error)")
                return
            }
            guard let handle else {
                RuneWeaverLog.stores.error("ApprovalDecisionLog: failed opening store at \(dbPath): unexpected nil handle")
                return
            }
            defer { sqlite3_close(handle) }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "DELETE FROM approval_decisions;", -1, &statement, nil) == SQLITE_OK else {
                RuneWeaverLog.stores.error("ApprovalDecisionLog: failed preparing decision clear.")
                return
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_DONE else {
                RuneWeaverLog.stores.error("ApprovalDecisionLog: could not clear decision rows")
                return
            }
        }

        private static func entry(from statement: OpaquePointer?) -> ApprovalDecisionEntry? {
            guard let idText = SQLiteHelpers.columnText(statement, index: 0),
                  let id = UUID(uuidString: idText),
                  let toolName = SQLiteHelpers.columnText(statement, index: 1),
                  let allowedRaw = SQLiteHelpers.columnInt64(statement, index: 4),
                  let duration = SQLiteHelpers.columnText(statement, index: 5),
                  let surface = SQLiteHelpers.columnText(statement, index: 6)
            else { return nil }
            return ApprovalDecisionEntry(
                id: id,
                toolName: toolName,
                scopeKind: SQLiteHelpers.columnText(statement, index: 2),
                scopeData: SQLiteHelpers.columnText(statement, index: 3),
                allowed: allowedRaw != 0,
                duration: duration,
                surface: surface,
                sessionID: SQLiteHelpers.columnText(statement, index: 7),
                displayTarget: SQLiteHelpers.columnText(statement, index: 8),
                decidedAt: Date(timeIntervalSince1970: SQLiteHelpers.columnDouble(statement, index: 9))
            )
        }
    }
#endif

/// SQLite-backed decision log persisted in `episodes.db` under `approval_decisions`.
///
/// Reads return newest first. An unreadable database yields empty reads and
/// drops writes with a stores log, never throwing into the decision path.
public actor ApprovalDecisionLogStore: ApprovalDecisionRecording {
    /// Filesystem path of the SQLite database (`episodes.db`).
    public let dbPath: String

    /// Creates a SQLite decision log store.
    public init(dbPath: String) {
        self.dbPath = dbPath
    }

    /// Records one decision, evicting oldest past the row cap.
    public func append(_ entry: ApprovalDecisionEntry) async {
        #if canImport(SQLite3)
            await SQLiteSerialIO.runUncancellable {
                SQLiteApprovalDecisionStorage.append(entry: entry, dbPath: self.dbPath)
            }
        #endif
    }

    /// Lists decisions newest first, narrowed by the optional tool/polarity
    /// predicates that ride the SELECT.
    public func list(limit: Int, offset: Int, toolName: String?, allowed: Bool?) async throws -> [ApprovalDecisionEntry] {
        #if canImport(SQLite3)
            return await SQLiteSerialIO.runUncancellable {
                SQLiteApprovalDecisionStorage.list(
                    limit: limit,
                    offset: offset,
                    toolName: toolName,
                    allowed: allowed,
                    dbPath: self.dbPath
                )
            }
        #else
            return []
        #endif
    }

    /// Counts stored decisions under the optional tool/polarity narrowing.
    public func count(toolName: String?, allowed: Bool?) async throws -> Int {
        #if canImport(SQLite3)
            return await SQLiteSerialIO.runUncancellable {
                SQLiteApprovalDecisionStorage.count(toolName: toolName, allowed: allowed, dbPath: self.dbPath)
            }
        #else
            return 0
        #endif
    }

    /// Clears all stored decisions.
    public func clearAll() async {
        #if canImport(SQLite3)
            await SQLiteSerialIO.runUncancellable {
                SQLiteApprovalDecisionStorage.clearAll(dbPath: self.dbPath)
            }
        #endif
    }
}

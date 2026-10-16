// Rune Weaver Core — Persistence contract and storage implementations for access rules.

import Foundation
#if canImport(SQLite3)
    import SQLite3
#endif

/// Persistence contract for ``AccessRule`` records.
public protocol AccessRuleStoring: Sendable {
    /// Loads all stored rules.
    /// - Returns: Persisted rules, possibly empty.
    func load() async throws -> [AccessRule]
    /// Replaces the stored rules.
    /// - Parameter rules: Current rules to persist.
    func save(_ rules: [AccessRule]) async throws
    /// Deletes expired allow rules; deny rules never expire.
    /// - Parameter date: Threshold date.
    func pruneExpired(at date: Date) async throws
    /// Copies legacy `trust_grants` rows forward once, idempotently. The legacy table is read here
    /// and only here: after the migration flag is set it is never read again, and it is never
    /// deleted.
    func migrateLegacyIfNeeded() async throws
}

/// In-memory ``AccessRuleStoring`` for tests and ephemeral sessions.
public actor InMemoryAccessRuleStore: AccessRuleStoring {
    private var rules: [AccessRule]

    /// Creates an in-memory store.
    /// - Parameter rules: Seed rules. Defaults to empty.
    public init(rules: [AccessRule] = []) {
        self.rules = rules
    }

    /// Returns the in-memory rules.
    /// - Returns: Current rules.
    public func load() async throws -> [AccessRule] {
        rules
    }

    /// Replaces the in-memory rules.
    /// - Parameter rules: Rules to keep.
    public func save(_ rules: [AccessRule]) async throws {
        self.rules = rules
    }

    /// Prunes expired in-memory rules, keeping every deny rule.
    /// - Parameter date: Expiry threshold. Defaults to now.
    public func pruneExpired(at date: Date = Date()) async throws {
        // A deny rule is a refusal, not trust, so it never ages out.
        rules.removeAll { $0.action == .allow && $0.isExpired(at: date) }
    }

    /// No-op: an in-memory store has no legacy database to copy forward.
    public func migrateLegacyIfNeeded() async throws {}
}

#if canImport(SQLite3)
    /// Internal SQLite helper for durable access-rule persistence in `episodes.db`.
    enum SQLiteAccessRuleStorage {
        private struct AccessRuleStorageError: Error {
            let message: String
        }

        /// Scope envelope tags for the `scope_kind` column.
        private enum ScopeKind: String {
            case toolWide
            case exactTarget
            case recipientSet
            case domain
            case pathPrefix
            case glob
        }

        /// Fixed insert projection shared by `save` and the legacy migration so
        /// one row shape cannot drift between the two writers.
        static let insertSQL = """
        INSERT INTO access_rules (id, tool_name, scope_kind, scope_data, action, granted_at, expires_at, duration, use_count, last_used_at, reason)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """

        static func open(dbPath: String) throws -> OpaquePointer? {
            let handle = try SQLiteHelpers.openHandle(dbPath: dbPath, unavailable: { AccessRuleStorageError(message: $0) })
            do {
                try migrateColumnsIfNeeded(handle: handle)
                try SQLiteHelpers.exec(
                    handle: handle,
                    sql: """
                    CREATE TABLE IF NOT EXISTS access_rules (
                        id TEXT PRIMARY KEY,
                        tool_name TEXT NOT NULL,
                        scope_kind TEXT NOT NULL,
                        scope_data TEXT NOT NULL,
                        action TEXT NOT NULL,
                        granted_at REAL NOT NULL,
                        expires_at REAL,
                        duration TEXT,
                        use_count INTEGER NOT NULL DEFAULT 0,
                        last_used_at REAL,
                        reason TEXT
                    );
                    CREATE INDEX IF NOT EXISTS idx_access_rules_tool_scope ON access_rules(tool_name, scope_kind);
                    CREATE INDEX IF NOT EXISTS idx_access_rules_expires_at ON access_rules(expires_at);
                    CREATE TABLE IF NOT EXISTS access_rule_meta (
                        key TEXT PRIMARY KEY,
                        value TEXT NOT NULL
                    );
                    """,
                    failure: { AccessRuleStorageError(message: $0) }
                )
            } catch {
                sqlite3_close(handle)
                throw error
            }
            return handle
        }

        /// Adds the rule columns that arrived additively to older `access_rules` schemas, mirroring
        /// the session-store migration idiom.
        private static func migrateColumnsIfNeeded(handle: OpaquePointer?) throws {
            let existing = SQLiteHelpers.columnNames(handle: handle, table: .accessRules)
            guard !existing.isEmpty else { return }
            let columnsToAdd: [(name: String, sql: String)] = [
                ("use_count", "ALTER TABLE access_rules ADD COLUMN use_count INTEGER NOT NULL DEFAULT 0;"),
                ("last_used_at", "ALTER TABLE access_rules ADD COLUMN last_used_at REAL;"),
                ("reason", "ALTER TABLE access_rules ADD COLUMN reason TEXT;")
            ]
            for (col, alterSQL) in columnsToAdd where !existing.contains(col) {
                do {
                    try SQLiteHelpers.exec(
                        handle: handle,
                        sql: alterSQL,
                        failure: { AccessRuleStorageError(message: $0) }
                    )
                } catch {
                    // Concurrent opens can race the probe onto the same `ALTER`; only that
                    // duplicate-column case is safe to ignore, every other failure surfaces so a
                    // broken migration cannot masquerade as migrated.
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
                        "SQLiteAccessRuleStorage: migration failed for column '\(col)' (code \(code)): \(error)"
                    )
                    throw error
                }
            }
        }

        static func load(dbPath: String) -> [AccessRule] {
            let handle: OpaquePointer?
            do {
                handle = try open(dbPath: dbPath)
            } catch {
                RuneWeaverLog.stores.error("SQLiteAccessRuleStorage: failed opening store at \(dbPath): \(error)")
                // An unreadable store must never read as trusted: the caller
                // re-prompts from an empty rule set instead of granting what it
                // could not verify.
                return []
            }
            guard let handle else {
                RuneWeaverLog.stores.error("SQLiteAccessRuleStorage: failed opening store at \(dbPath): unexpected nil handle")
                return []
            }
            defer { sqlite3_close(handle) }
            let sql = """
            SELECT id, tool_name, scope_kind, scope_data, action, granted_at, expires_at, duration, use_count, last_used_at, reason
            FROM access_rules;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                let code = sqlite3_errcode(handle)
                RuneWeaverLog.stores.error("SQLiteAccessRuleStorage: failed preparing rule load (code \(code)).")
                return []
            }
            defer { sqlite3_finalize(statement) }
            var results: [AccessRule] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                // A poison row skips itself: a half-written rule set is better
                // than aborting every rule behind it.
                guard let rule = rule(from: statement) else { continue }
                results.append(rule)
            }
            return results
        }

        /// Projects one stored row into a rule, or nil when the row is unusable.
        private static func rule(from statement: OpaquePointer?) -> AccessRule? {
            guard let idText = SQLiteHelpers.columnText(statement, index: 0),
                  let id = UUID(uuidString: idText),
                  let toolName = SQLiteHelpers.columnText(statement, index: 1),
                  let kindText = SQLiteHelpers.columnText(statement, index: 2),
                  let kind = ScopeKind(rawValue: kindText),
                  let actionText = SQLiteHelpers.columnText(statement, index: 4),
                  let action = AccessAction(rawValue: actionText)
            else { return nil }
            guard let scope = decodeScope(kind: kind, data: SQLiteHelpers.columnText(statement, index: 3) ?? "") else {
                return nil
            }
            let grantedAt = Date(timeIntervalSince1970: SQLiteHelpers.columnDouble(statement, index: 5))
            let expiresAt: Date? = sqlite3_column_type(statement, 6) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSince1970: SQLiteHelpers.columnDouble(statement, index: 6))
            let duration = SQLiteHelpers.columnText(statement, index: 7).flatMap(TrustDuration.init(rawValue:))
            let reason = SQLiteHelpers.columnText(statement, index: 10)
            guard var rule = AccessRule(
                id: id,
                toolName: toolName,
                scope: scope,
                action: action,
                grantedAt: grantedAt,
                duration: duration,
                expiresAt: expiresAt,
                reason: reason
            ) else { return nil }
            // Counters survive the round trip; a missing or negative value means
            // the row was never observed in use rather than a broken baseline.
            let decodedCount = SQLiteHelpers.columnInt64(statement, index: 8) ?? 0
            rule.useCount = max(0, Int(decodedCount))
            if sqlite3_column_type(statement, 9) != SQLITE_NULL {
                rule.lastUsedAt = Date(timeIntervalSince1970: SQLiteHelpers.columnDouble(statement, index: 9))
            }
            return rule
        }

        /// Rebuilds a scope from its stored column pair.
        private static func decodeScope(kind: ScopeKind, data: String) -> AccessScope? {
            switch kind {
            case .toolWide:
                return .toolWide
            case .exactTarget:
                return AccessScope.canonicalized(.exactTarget(data))
            case .pathPrefix:
                return AccessScope.canonicalized(.pathPrefix(data))
            case .glob:
                return AccessScope.canonicalized(.glob(data))
            case .recipientSet:
                guard let json = data.data(using: .utf8),
                      let members = try? JSONDecoder().decode([String].self, from: json)
                else { return nil }
                return AccessScope.canonicalized(.recipientSet(members))
            case .domain:
                guard let json = data.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: json, options: []) as? [String: Any],
                      let host = object["host"] as? String
                else { return nil }
                return AccessScope.canonicalized(.domain(host: host, subdomains: object["subdomains"] as? Bool ?? false))
            }
        }

        /// Encodes a scope into its stored column pair. The envelope owns shape here — this
        /// function never compares or re-canonicalizes anything.
        private static func encodeScope(_ scope: AccessScope) -> (kind: ScopeKind, data: String) {
            switch scope {
            case .toolWide:
                return (.toolWide, "")
            case let .exactTarget(target):
                return (.exactTarget, target)
            case let .pathPrefix(path):
                return (.pathPrefix, path)
            case let .glob(pattern):
                return (.glob, pattern)
            case let .recipientSet(members):
                let data = (try? JSONEncoder().encode(members)).flatMap { String(data: $0, encoding: .utf8) }
                return (.recipientSet, data ?? "[]")
            case let .domain(host, subdomains):
                let payload: [String: Any] = ["host": host, "subdomains": subdomains]
                let data = (try? JSONSerialization.data(withJSONObject: payload)).flatMap { String(data: $0, encoding: .utf8) }
                // An unencodable payload reads as an empty object, which the
                // decoder refuses rather than storing a scope nobody approved.
                return (.domain, data ?? "{}")
            }
        }

        /// Inserts one rule through a prepared statement.
        static func insert(rule: AccessRule, statement: OpaquePointer?) -> Bool {
            sqlite3_reset(statement)
            let (kind, data) = encodeScope(rule.scope)
            SQLiteHelpers.bindText(statement, index: 1, value: rule.id.uuidString)
            SQLiteHelpers.bindText(statement, index: 2, value: rule.toolName)
            SQLiteHelpers.bindText(statement, index: 3, value: kind.rawValue)
            SQLiteHelpers.bindText(statement, index: 4, value: data)
            SQLiteHelpers.bindText(statement, index: 5, value: rule.action.rawValue)
            SQLiteHelpers.bindDouble(statement, index: 6, value: rule.grantedAt.timeIntervalSince1970)
            if let expiresAt = rule.expiresAt {
                SQLiteHelpers.bindDouble(statement, index: 7, value: expiresAt.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(statement, 7)
            }
            SQLiteHelpers.bindText(statement, index: 8, value: rule.duration?.rawValue)
            SQLiteHelpers.bindInt64(statement, index: 9, value: Int64(max(0, rule.useCount)))
            if let lastUsedAt = rule.lastUsedAt {
                SQLiteHelpers.bindDouble(statement, index: 10, value: lastUsedAt.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(statement, 10)
            }
            SQLiteHelpers.bindText(statement, index: 11, value: rule.reason)
            return sqlite3_step(statement) == SQLITE_DONE
        }

        static func save(rules: [AccessRule], dbPath: String) throws {
            let handle = try open(dbPath: dbPath)
            guard let handle else {
                throw AccessRuleStorageError(message: "unexpected nil handle opening \(dbPath)")
            }
            defer { sqlite3_close(handle) }
            // Replace the table atomically: any prepare or insert failure rolls
            // back to the pre-save contents instead of committing an empty or
            // partial rule set that would wipe live trust.
            guard sqlite3_exec(handle, "BEGIN IMMEDIATE TRANSACTION;", nil, nil, nil) == SQLITE_OK else {
                throw AccessRuleStorageError(message: "could not begin access-rule save")
            }
            guard sqlite3_exec(handle, "DELETE FROM access_rules;", nil, nil, nil) == SQLITE_OK else {
                _ = sqlite3_exec(handle, "ROLLBACK;", nil, nil, nil)
                throw AccessRuleStorageError(message: "could not clear access rules for save")
            }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, insertSQL, -1, &statement, nil) == SQLITE_OK else {
                _ = sqlite3_exec(handle, "ROLLBACK;", nil, nil, nil)
                throw AccessRuleStorageError(message: "could not prepare access-rule save")
            }
            var succeeded = true
            for rule in rules where succeeded {
                succeeded = insert(rule: rule, statement: statement)
            }
            sqlite3_finalize(statement)
            if succeeded {
                if sqlite3_exec(handle, "COMMIT;", nil, nil, nil) != SQLITE_OK {
                    _ = sqlite3_exec(handle, "ROLLBACK;", nil, nil, nil)
                    throw AccessRuleStorageError(message: "could not commit access-rule save")
                }
            } else {
                _ = sqlite3_exec(handle, "ROLLBACK;", nil, nil, nil)
                throw AccessRuleStorageError(message: "could not write an access rule")
            }
        }

        static func pruneExpired(at date: Date, dbPath: String) throws {
            let handle = try open(dbPath: dbPath)
            guard let handle else {
                throw AccessRuleStorageError(message: "unexpected nil handle opening \(dbPath)")
            }
            defer { sqlite3_close(handle) }
            // Only expired allow rows are swept: a deny row is a standing
            // refusal, and a rule with no expiry never ages out at all.
            let sql = "DELETE FROM access_rules WHERE action = 'allow' AND expires_at IS NOT NULL AND expires_at <= ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw AccessRuleStorageError(message: "could not prepare access-rule prune")
            }
            defer { sqlite3_finalize(statement) }
            SQLiteHelpers.bindDouble(statement, index: 1, value: date.timeIntervalSince1970)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw AccessRuleStorageError(message: "could not prune expired access rules")
            }
        }
    }

    /// Internal SQLite helper for the one-time legacy trust-grant carry-forward.
    enum SQLiteAccessRuleMigration {
        private struct MigrationError: Error {
            let message: String
        }

        /// Meta key whose value marks the carry-forward complete.
        private static let flagKey = "legacy_trust_grants_migrated"

        /// Raw fields of one legacy trust-grant row.
        private struct LegacyTrustGrantRow {
            let id: UUID
            let toolName: String
            let target: String
            let grantedAt: Date
            let expiresAt: Date?
            let duration: TrustDuration
            let useCount: Int
            let lastUsedAt: Date?
        }

        static func migrateLegacyIfNeeded(dbPath: String) throws {
            let handle = try SQLiteAccessRuleStorage.open(dbPath: dbPath)
            guard let handle else {
                throw MigrationError(message: "unexpected nil handle opening \(dbPath)")
            }
            defer { sqlite3_close(handle) }
            if migrationFlag(handle: handle) == "1" {
                return
            }
            let legacyRows = readLegacyTrustGrants(handle: handle)
            // One transaction for the whole copy: the rows and the flag commit
            // together, so a failure anywhere rolls the flag back with the rows
            // and a later retry re-reads the legacy table.
            guard sqlite3_exec(handle, "BEGIN IMMEDIATE TRANSACTION;", nil, nil, nil) == SQLITE_OK else {
                throw MigrationError(message: "could not begin legacy access-rule migration")
            }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, SQLiteAccessRuleStorage.insertSQL, -1, &statement, nil) == SQLITE_OK else {
                _ = sqlite3_exec(handle, "ROLLBACK;", nil, nil, nil)
                throw MigrationError(message: "could not prepare legacy access-rule insert")
            }
            var succeeded = true
            for row in legacyRows {
                // A non-durable duration or a blank target shapes no durable
                // rule, so that row is skipped instead of aborting the copy.
                guard let rule = rule(from: row) else { continue }
                if !SQLiteAccessRuleStorage.insert(rule: rule, statement: statement) {
                    succeeded = false
                    break
                }
            }
            sqlite3_finalize(statement)
            if !succeeded {
                _ = sqlite3_exec(handle, "ROLLBACK;", nil, nil, nil)
                throw MigrationError(message: "could not copy a legacy trust grant row")
            }
            var failure: Error?
            do {
                try writeMigrationFlag(handle: handle)
                if sqlite3_exec(handle, "COMMIT;", nil, nil, nil) != SQLITE_OK {
                    failure = MigrationError(message: "could not commit the legacy access-rule migration")
                }
            } catch {
                failure = error
            }
            if let failure {
                _ = sqlite3_exec(handle, "ROLLBACK;", nil, nil, nil)
                throw failure
            }
        }

        /// Maps one legacy grant row to a rule, or nil when it cannot survive.
        private static func rule(from row: LegacyTrustGrantRow) -> AccessRule? {
            guard var rule = AccessRule(
                id: row.id,
                toolName: row.toolName,
                scope: .exactTarget(row.target),
                action: .allow,
                grantedAt: row.grantedAt,
                duration: row.duration,
                expiresAt: row.expiresAt,
                reason: nil
            ) else { return nil }
            rule.useCount = row.useCount
            rule.lastUsedAt = row.lastUsedAt
            return rule
        }

        /// Reads every legacy trust-grant row; an absent table reads empty.
        private static func readLegacyTrustGrants(handle: OpaquePointer?) -> [LegacyTrustGrantRow] {
            let columns = SQLiteHelpers.columnNames(handle: handle, table: .trustGrants)
            // An absent (or unusable) legacy table means there is nothing to
            // copy forward, not a failure to surface.
            guard columns.contains("id"), columns.contains("tool_name"), columns.contains("target") else { return [] }
            // Counter columns arrived additively in the legacy schema, so
            // project whichever survived instead of failing the whole read.
            var projection = "id, tool_name, target, granted_at, expires_at, duration"
            if columns.contains("use_count") {
                projection += ", use_count"
            }
            if columns.contains("last_used_at") {
                projection += ", last_used_at"
            }
            let hasUseCount = columns.contains("use_count")
            let hasLastUsedAt = columns.contains("last_used_at")
            // Counter positions shift with the projection, so resolve them from
            // the same probe that built it.
            let useCountIndex: Int32? = hasUseCount ? 6 : nil
            let lastUsedIndex: Int32? = hasLastUsedAt ? (hasUseCount ? 7 : 6) : nil
            let sql = "SELECT \(projection) FROM trust_grants;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            var rows: [LegacyTrustGrantRow] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let idText = SQLiteHelpers.columnText(statement, index: 0),
                      let id = UUID(uuidString: idText),
                      let toolName = SQLiteHelpers.columnText(statement, index: 1),
                      let target = SQLiteHelpers.columnText(statement, index: 2),
                      let durationText = SQLiteHelpers.columnText(statement, index: 5),
                      let duration = TrustDuration(rawValue: durationText)
                else { continue }
                let grantedAt = Date(timeIntervalSince1970: SQLiteHelpers.columnDouble(statement, index: 3))
                let expiresAt: Date? = sqlite3_column_type(statement, 4) == SQLITE_NULL
                    ? nil
                    : Date(timeIntervalSince1970: SQLiteHelpers.columnDouble(statement, index: 4))
                var useCount = 0
                if let useCountIndex, let rawCount = SQLiteHelpers.columnInt64(statement, index: useCountIndex) {
                    useCount = max(0, Int(rawCount))
                }
                var lastUsedAt: Date?
                if let lastUsedIndex, sqlite3_column_type(statement, lastUsedIndex) != SQLITE_NULL {
                    lastUsedAt = Date(timeIntervalSince1970: SQLiteHelpers.columnDouble(statement, index: lastUsedIndex))
                }
                rows.append(LegacyTrustGrantRow(
                    id: id,
                    toolName: toolName,
                    target: target,
                    grantedAt: grantedAt,
                    expiresAt: expiresAt,
                    duration: duration,
                    useCount: useCount,
                    lastUsedAt: lastUsedAt
                ))
            }
            return rows
        }

        /// Reads the migration flag; nil when the row is absent or unreadable.
        private static func migrationFlag(handle: OpaquePointer?) -> String? {
            let sql = "SELECT value FROM access_rule_meta WHERE key = ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(statement) }
            SQLiteHelpers.bindText(statement, index: 1, value: flagKey)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return SQLiteHelpers.columnText(statement, index: 0)
        }

        private static func writeMigrationFlag(handle: OpaquePointer?) throws {
            let sql = """
            INSERT INTO access_rule_meta(key, value) VALUES(?, '1')
            ON CONFLICT(key) DO UPDATE SET value = excluded.value;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw MigrationError(message: "could not prepare the migration flag write")
            }
            defer { sqlite3_finalize(statement) }
            SQLiteHelpers.bindText(statement, index: 1, value: flagKey)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw MigrationError(message: "could not write the migration flag")
            }
        }
    }
#endif

/// SQLite-backed ``AccessRuleStoring`` persisted in `episodes.db` under `access_rules`.
public struct SQLiteAccessRuleStore: AccessRuleStoring, Sendable {
    /// Filesystem path of the SQLite database (`episodes.db`).
    public let dbPath: String

    /// Creates an SQLite access-rule store.
    /// - Parameter dbPath: SQLite database file path.
    public init(dbPath: String) {
        self.dbPath = dbPath
    }

    /// Loads stored rules from SQLite. A store failure folds to an empty rule set rather than
    /// throwing: an unreadable database must re-prompt everything, never fabricate trust.
    public func load() async throws -> [AccessRule] {
        #if canImport(SQLite3)
            return await SQLiteSerialIO.runUncancellable {
                SQLiteAccessRuleStorage.load(dbPath: dbPath)
            }
        #else
            return []
        #endif
    }

    /// Replaces the persisted rules in SQLite.
    /// - Parameter rules: Rules to persist.
    public func save(_ rules: [AccessRule]) async throws {
        #if canImport(SQLite3)
            try await SQLiteSerialIO.run {
                try SQLiteAccessRuleStorage.save(rules: rules, dbPath: dbPath)
            }
        #endif
    }

    /// Deletes expired allow rules from SQLite; deny rules never expire.
    /// - Parameter date: Expiry threshold. Defaults to now.
    public func pruneExpired(at date: Date = Date()) async throws {
        #if canImport(SQLite3)
            try await SQLiteSerialIO.run {
                try SQLiteAccessRuleStorage.pruneExpired(at: date, dbPath: dbPath)
            }
        #endif
    }

    /// Copies legacy `trust_grants` rows forward once; a no-op thereafter.
    /// - Throws: When the copy cannot be completed, leaving the migration flag
    ///   unset so a later call retries.
    public func migrateLegacyIfNeeded() async throws {
        #if canImport(SQLite3)
            try await SQLiteSerialIO.run {
                try SQLiteAccessRuleMigration.migrateLegacyIfNeeded(dbPath: dbPath)
            }
        #endif
    }
}

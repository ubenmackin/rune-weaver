// Rune Weaver Core Tests — Access rule store persistence and the legacy trust-grant migration.

import Foundation
@testable import RuneWeaverCore
import Testing
#if canImport(SQLite3)
    import SQLite3
#endif

private enum AccessRuleStoreTestSupport {
    static func makeTempWorkspace() throws -> (base: URL, dbURL: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("runeweaver-accessrulestore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let dbURL = base.appendingPathComponent("test_episodes.db")
        return (base, dbURL)
    }

    static func cleanup(_ base: URL) {
        try? FileManager.default.removeItem(at: base)
    }

    /// Executes one raw statement so fixture tables genuinely predate the
    /// store instead of being created by the code under test.
    @discardableResult
    static func execRaw(dbPath: String, sql: String) -> Bool {
        #if canImport(SQLite3)
            let expanded = (dbPath as NSString).expandingTildeInPath
            var handle: OpaquePointer?
            guard expanded.withCString({ sqlite3_open($0, &handle) }) == SQLITE_OK, let handle else { return false }
            defer { sqlite3_close(handle) }
            return sql.withCString { sqlite3_exec(handle, $0, nil, nil, nil) } == SQLITE_OK
        #else
            return false
        #endif
    }

    /// Counts rows in a fixture table so the copy-forward check can prove the
    /// legacy table was left untouched. The table name is a fixed literal.
    static func rawRowCount(dbPath: String, table: String) -> Int {
        #if canImport(SQLite3)
            let expanded = (dbPath as NSString).expandingTildeInPath
            var handle: OpaquePointer?
            guard expanded.withCString({ sqlite3_open($0, &handle) }) == SQLITE_OK, let handle else { return -1 }
            defer { sqlite3_close(handle) }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM \(table);", -1, &statement, nil) == SQLITE_OK,
                  let statement
            else { return -1 }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return -1 }
            return Int(sqlite3_column_int64(statement, 0))
        #else
            return -1
        #endif
    }

    /// Builds a fixed identifier so round-trip assertions can name a rule.
    static func identifier(_ suffix: Int) -> UUID {
        UUID(uuidString: "AAAAAAAA-0000-0000-0000-\(String(format: "%012d", suffix))") ?? UUID()
    }
}

@Suite("Access Rule Store")
struct AccessRuleStoreTests {
    private func makeRule(
        id: Int,
        toolName: String = "email.send",
        scope: AccessScope,
        action: AccessAction = .allow,
        grantedAt: Date = Date(timeIntervalSince1970: 1000),
        duration: TrustDuration? = nil,
        expiresAt: Date? = nil,
        useCount: Int = 0,
        lastUsedAt: Date? = nil,
        reason: String? = nil
    ) throws -> AccessRule {
        var rule = try #require(AccessRule(
            id: AccessRuleStoreTestSupport.identifier(id),
            toolName: toolName,
            scope: scope,
            action: action,
            grantedAt: grantedAt,
            duration: duration,
            expiresAt: expiresAt,
            reason: reason
        ))
        rule.useCount = useCount
        rule.lastUsedAt = lastUsedAt
        return rule
    }

    // MARK: - SQLite round trip

    @Test
    func `a second store sees denies and allows with counters`() async throws {
        let (base, dbURL) = try AccessRuleStoreTestSupport.makeTempWorkspace()
        defer { AccessRuleStoreTestSupport.cleanup(base) }

        let store = SQLiteAccessRuleStore(dbPath: dbURL.path)
        let rules = try [
            makeRule(id: 1, scope: .toolWide),
            makeRule(
                id: 2,
                scope: .recipientSet(["a@x.com", "b@x.com"]),
                duration: .forever,
                useCount: 3,
                lastUsedAt: Date(timeIntervalSince1970: 1500),
                reason: "owner allowed this batch"
            ),
            makeRule(
                id: 3,
                toolName: "api.request",
                scope: .domain(host: "example.com", subdomains: true),
                action: .deny,
                duration: .oneHour,
                reason: "owner refused this host"
            ),
            makeRule(id: 4, toolName: "files.write", scope: .pathPrefix(base.path), duration: .oneDay),
            makeRule(id: 5, toolName: "bash.exec", scope: .glob("git status")),
            makeRule(
                id: 6,
                scope: .exactTarget("a@x.com"),
                duration: .fiveMinutes
            )
        ]
        try await store.save(rules)

        // A second store over the same file reads exactly what the first wrote:
        // every scope shape, the deny row, and the usage counters survive.
        let second = SQLiteAccessRuleStore(dbPath: dbURL.path)
        let loaded = try await second.load()
        #expect(loaded.sorted { $0.id.uuidString < $1.id.uuidString } == rules.sorted { $0.id.uuidString < $1.id.uuidString })

        let migratedTarget = try #require(loaded.first { $0.id == AccessRuleStoreTestSupport.identifier(2) })
        #expect(migratedTarget.action == .allow)
        #expect(migratedTarget.useCount == 3)
        #expect(migratedTarget.lastUsedAt == Date(timeIntervalSince1970: 1500))
        #expect(migratedTarget.reason == "owner allowed this batch")
        #expect(migratedTarget.duration == .forever)

        let deny = try #require(loaded.first { $0.id == AccessRuleStoreTestSupport.identifier(3) })
        #expect(deny.action == .deny)
        #expect(deny.scope == .domain(host: "example.com", subdomains: true))
        #expect(deny.duration == .oneHour)
        #expect(deny.reason == "owner refused this host")
    }

    // MARK: - Legacy migration

    @Test
    func `legacy trust_grants rows survive migration with identical matching and the copy is idempotent`() async throws {
        let (base, dbURL) = try AccessRuleStoreTestSupport.makeTempWorkspace()
        defer { AccessRuleStoreTestSupport.cleanup(base) }

        // A database from before the access-rule model existed: the legacy
        // grant table plus five rows, two of which cannot become rules.
        let legacyTable = """
        CREATE TABLE trust_grants (
            id TEXT PRIMARY KEY,
            tool_name TEXT NOT NULL,
            target TEXT NOT NULL,
            granted_at REAL NOT NULL,
            expires_at REAL,
            duration TEXT NOT NULL,
            use_count INTEGER NOT NULL DEFAULT 0,
            last_used_at REAL
        );
        INSERT INTO trust_grants VALUES
            ('AAAAAAAA-0000-0000-0000-000000000001', 'email.send', 'a@x.com', 1000, NULL, 'forever', 2, 1500),
            ('AAAAAAAA-0000-0000-0000-000000000002', 'bash.exec', 'git status', 2000, 2000 + 86400, 'oneDay', 0, NULL),
            ('AAAAAAAA-0000-0000-0000-000000000003', 'email.send', 'b@x.com', 3000, NULL, 'forTask', 0, NULL),
            ('AAAAAAAA-0000-0000-0000-000000000004', 'email.send', '   ', 4000, NULL, 'forever', 0, NULL),
            ('AAAAAAAA-0000-0000-0000-000000000005', 'messages.send', '+15551234567', 5000, NULL, 'forever', 0, NULL);
        """
        #expect(AccessRuleStoreTestSupport.execRaw(dbPath: dbURL.path, sql: legacyTable))

        let store = SQLiteAccessRuleStore(dbPath: dbURL.path)
        try await store.migrateLegacyIfNeeded()
        let migrated = try await store.load()

        // The durable rows carried forward; the non-durable duration and the
        // blank target shaped no rule and were skipped.
        #expect(migrated.count == 3)
        let email = try #require(migrated.first { $0.id.uuidString == "AAAAAAAA-0000-0000-0000-000000000001" })
        #expect(email.toolName == "email.send")
        #expect(email.action == .allow)
        #expect(email.scope == .exactTarget("a@x.com"))
        #expect(email.duration == .forever)
        #expect(email.grantedAt == Date(timeIntervalSince1970: 1000))
        #expect(email.expiresAt == nil)
        #expect(email.useCount == 2)
        #expect(email.lastUsedAt == Date(timeIntervalSince1970: 1500))

        let bash = try #require(migrated.first { $0.id.uuidString == "AAAAAAAA-0000-0000-0000-000000000002" })
        #expect(bash.scope == .exactTarget("git status"))
        #expect(bash.duration == .oneDay)
        #expect(bash.expiresAt == Date(timeIntervalSince1970: 2000 + 86400))

        let messages = try #require(migrated.first { $0.id.uuidString == "AAAAAAAA-0000-0000-0000-000000000005" })
        #expect(messages.scope == .exactTarget("+15551234567"))

        // Identical matching: the exactTarget scope reproduces the legacy
        // target derivation, so the call the owner approved stays covered and a
        // near-miss still prompts.
        let sendCall = ToolInput(toolName: "email.send", argumentsJSON: #"{"to":"a@x.com"}"#)
        let legacyTarget = ActionDescriptor.descriptor(for: sendCall, toolName: "email.send").target
        #expect(legacyTarget == "a@x.com")
        #expect(email.scope == .exactTarget(legacyTarget))
        #expect(email.covers(toolName: "email.send", argumentsJSON: sendCall.argumentsJSON))
        #expect(!email.covers(toolName: "email.send", argumentsJSON: #"{"to":"b@x.com"}"#))
        #expect(!email.covers(toolName: "messages.send", argumentsJSON: sendCall.argumentsJSON))

        // Copy-forward only: the legacy table survives with every row, and a
        // second store reads the same migrated rules.
        #expect(AccessRuleStoreTestSupport.rawRowCount(dbPath: dbURL.path, table: "trust_grants") == 5)
        let second = SQLiteAccessRuleStore(dbPath: dbURL.path)
        #expect(try await second.load().count == 3)

        // Idempotent: a second migration run copies nothing new.
        try await store.migrateLegacyIfNeeded()
        #expect(try await store.load().count == 3)
        #expect(AccessRuleStoreTestSupport.rawRowCount(dbPath: dbURL.path, table: "trust_grants") == 5)
    }

    @Test
    func `migration sets the flag when the legacy table is absent`() async throws {
        let (base, dbURL) = try AccessRuleStoreTestSupport.makeTempWorkspace()
        defer { AccessRuleStoreTestSupport.cleanup(base) }

        let store = SQLiteAccessRuleStore(dbPath: dbURL.path)
        try await store.migrateLegacyIfNeeded()
        #expect(try await store.load().isEmpty)

        // A rule saved afterwards survives the already-completed migration.
        let rule = try makeRule(id: 11, scope: .toolWide)
        try await store.save([rule])
        try await store.migrateLegacyIfNeeded()
        #expect(try await store.load() == [rule])
    }

    @Test
    func `an upgraded narrow access_rules table gains its additive columns and keeps its durable rules`() async throws {
        let (base, dbURL) = try AccessRuleStoreTestSupport.makeTempWorkspace()
        defer { AccessRuleStoreTestSupport.cleanup(base) }

        // A database from before the additive rule columns existed: the narrow
        // `access_rules` shape plus one permanent deny row and one allow row,
        // written raw so the schema genuinely predates the store's widening.
        let narrowSchema = """
        CREATE TABLE access_rules (
            id TEXT PRIMARY KEY,
            tool_name TEXT NOT NULL,
            scope_kind TEXT NOT NULL,
            scope_data TEXT NOT NULL,
            action TEXT NOT NULL,
            granted_at REAL NOT NULL,
            expires_at REAL,
            duration TEXT
        );
        INSERT INTO access_rules VALUES
            ('AAAAAAAA-0000-0000-0000-000000000060', 'bash.exec', 'glob', 'rm *', 'deny', 1000, NULL, 'forever'),
            ('AAAAAAAA-0000-0000-0000-000000000061', 'email.send', 'exactTarget', 'a@x.com', 'allow', 1000, NULL, 'forever');
        """
        #expect(AccessRuleStoreTestSupport.execRaw(dbPath: dbURL.path, sql: narrowSchema))

        let store = SQLiteAccessRuleStore(dbPath: dbURL.path)

        // The migrated rows read back through the widened schema: the permanent
        // deny survives with no expiry, exactly as the owner left it.
        let loaded = try await store.load()
        #expect(loaded.count == 2)
        let deny = try #require(loaded.first { $0.id.uuidString == "AAAAAAAA-0000-0000-0000-000000000060" })
        #expect(deny.action == .deny)
        #expect(deny.toolName == "bash.exec")
        #expect(deny.scope == .glob("rm *"))
        #expect(deny.duration == .forever)
        #expect(deny.expiresAt == nil)
        #expect(deny.useCount == 0)
        #expect(deny.lastUsedAt == nil)

        // A save carrying a reason and counters now prepares and commits, and
        // a second store reads the same durable copy back.
        let noted = try makeRule(
            id: 62,
            toolName: "api.request",
            scope: .domain(host: "example.com", subdomains: true),
            action: .deny,
            duration: .forever,
            useCount: 2,
            lastUsedAt: Date(timeIntervalSince1970: 1500),
            reason: "owner refused this host"
        )
        try await store.save(loaded + [noted])
        let second = SQLiteAccessRuleStore(dbPath: dbURL.path)
        let reloaded = try await second.load()
        #expect(
            reloaded.sorted { $0.id.uuidString < $1.id.uuidString }
                == (loaded + [noted]).sorted { $0.id.uuidString < $1.id.uuidString }
        )
        let persisted = try #require(reloaded.first { $0.id == AccessRuleStoreTestSupport.identifier(62) })
        #expect(persisted.reason == "owner refused this host")
    }

    // MARK: - Poison rows

    @Test
    func `poison rows skip without aborting the rule set`() async throws {
        let (base, dbURL) = try AccessRuleStoreTestSupport.makeTempWorkspace()
        defer { AccessRuleStoreTestSupport.cleanup(base) }

        let store = SQLiteAccessRuleStore(dbPath: dbURL.path)
        let good = try makeRule(id: 20, scope: .recipientSet(["a@x.com"]))
        try await store.save([good])

        // Rows whose scope tag, scope payload, action, or duration the store
        // cannot trust: each skips itself instead of poisoning the whole read.
        let poisonRows = """
        INSERT INTO access_rules (id, tool_name, scope_kind, scope_data, action, granted_at, expires_at, duration, use_count, last_used_at, reason) VALUES
            ('BBBBBBBB-0000-0000-0000-000000000001', 'email.send', 'futureKind', 'a@x.com', 'allow', 1000, NULL, NULL, 0, NULL, NULL),
            ('BBBBBBBB-0000-0000-0000-000000000002', 'email.send', 'recipientSet', 'not json', 'allow', 1000, NULL, NULL, 0, NULL, NULL),
            ('BBBBBBBB-0000-0000-0000-000000000003', 'email.send', 'toolWide', '', 'maybe', 1000, NULL, NULL, 0, NULL, NULL),
            ('BBBBBBBB-0000-0000-0000-000000000004', 'email.send', 'toolWide', '', 'allow', 1000, NULL, 'forSession', 0, NULL, NULL),
            ('BBBBBBBB-0000-0000-0000-000000000005', 'email.send', 'exactTarget', '   ', 'allow', 1000, NULL, 'forever', 0, NULL, NULL);
        """
        #expect(AccessRuleStoreTestSupport.execRaw(dbPath: dbURL.path, sql: poisonRows))

        let loaded = try await store.load()
        #expect(loaded == [good])
    }

    // MARK: - Prune

    @Test
    func `pruneExpired deletes expired allow rows and keeps deny rows`() async throws {
        let (base, dbURL) = try AccessRuleStoreTestSupport.makeTempWorkspace()
        defer { AccessRuleStoreTestSupport.cleanup(base) }

        let store = SQLiteAccessRuleStore(dbPath: dbURL.path)
        let expiredAllow = try makeRule(id: 30, scope: .toolWide, duration: .oneHour)
        let expiredDeny = try makeRule(id: 31, scope: .toolWide, action: .deny, duration: .oneHour)
        let validAllow = try makeRule(id: 32, scope: .toolWide, duration: .oneDay)
        try await store.save([expiredAllow, expiredDeny, validAllow])

        #expect(expiredAllow.expiresAt == Date(timeIntervalSince1970: 4600))
        #expect(validAllow.expiresAt == Date(timeIntervalSince1970: 87400))
        try await store.pruneExpired(at: Date(timeIntervalSince1970: 5000))

        let loaded = try await store.load()
        #expect(loaded.count == 2)
        #expect(!loaded.contains { $0.id == AccessRuleStoreTestSupport.identifier(30) })
        #expect(loaded.contains { $0.id == AccessRuleStoreTestSupport.identifier(31) })
        #expect(loaded.contains { $0.id == AccessRuleStoreTestSupport.identifier(32) })

        // A standing rule never expires, so a prune far in the future keeps it.
        let standing = try makeRule(id: 33, scope: .toolWide)
        try await store.save([standing])
        try await store.pruneExpired(at: Date(timeIntervalSince1970: 100_000_000))
        #expect(try await store.load() == [standing])
    }

    // MARK: - Save rollback

    @Test
    func `a failed save rolls back to the pre-save contents`() async throws {
        let (base, dbURL) = try AccessRuleStoreTestSupport.makeTempWorkspace()
        defer { AccessRuleStoreTestSupport.cleanup(base) }

        let store = SQLiteAccessRuleStore(dbPath: dbURL.path)
        let original = try makeRule(id: 40, scope: .toolWide)
        try await store.save([original])

        // A BEFORE INSERT trigger makes every row write fail while the ledger
        // stays readable, so the save must roll back instead of leaving the
        // table cleared.
        let triggerSQL = """
        CREATE TRIGGER refuse_access_rule_insert BEFORE INSERT ON access_rules
        BEGIN
            SELECT RAISE(ABORT, 'insert refused');
        END;
        """
        #expect(AccessRuleStoreTestSupport.execRaw(dbPath: dbURL.path, sql: triggerSQL))

        let replacement = try makeRule(id: 41, scope: .toolWide)
        await #expect(throws: (any Error).self) {
            try await store.save([replacement])
        }
        #expect(try await store.load() == [original])
    }

    // MARK: - In-memory store

    @Test
    func `the in-memory store round-trips seeded rules and prunes only expired allows`() async throws {
        let standing = try makeRule(id: 50, scope: .toolWide)
        let expiredAllow = try makeRule(id: 51, toolName: "bash.exec", scope: .glob("git status"), duration: .oneHour)
        let expiredDeny = try makeRule(id: 52, toolName: "bash.exec", scope: .glob("rm *"), action: .deny, duration: .oneHour)

        let store = InMemoryAccessRuleStore(rules: [standing, expiredAllow, expiredDeny])
        #expect(try await store.load() == [standing, expiredAllow, expiredDeny])

        try await store.save([expiredDeny])
        #expect(try await store.load() == [expiredDeny])

        try await store.pruneExpired(at: Date(timeIntervalSince1970: 5000))
        #expect(try await store.load() == [expiredDeny])

        // Migration is a no-op for an in-memory store.
        try await store.migrateLegacyIfNeeded()
        #expect(try await store.load() == [expiredDeny])
    }
}

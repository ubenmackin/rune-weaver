// Rune Weaver Core Tests — Approval decision log persistence and cap.
//
// Pins the durable audit contract: appends round-trip through episodes.db,
// reads return newest first, the 10,000-row cap evicts oldest in the same
// write, clearAll empties the table, scope renderings cover every AccessScope
// kind, and an unreadable store degrades to empty reads without throwing.
// The in-memory log pins the same matrix without a database.

import Foundation
@testable import RuneWeaverCore
import Testing
#if canImport(SQLite3)
    import SQLite3
#endif

private enum ApprovalDecisionLogTestSupport {
    static func makeTempWorkspace() throws -> (base: URL, dbURL: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("runeweaver-approvallog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return (base, base.appendingPathComponent("test_episodes.db"))
    }

    static func cleanup(_ base: URL) {
        try? FileManager.default.removeItem(at: base)
    }

    static func makeEntry(
        id: UUID = UUID(),
        toolName: String = "email.send",
        scope: AccessScope? = nil,
        allowed: Bool = true,
        duration: String = "forever",
        surface: String = "chat",
        decidedAt: Date = Date(timeIntervalSince1970: 1000)
    ) -> ApprovalDecisionEntry {
        ApprovalDecisionEntry(
            id: id,
            toolName: toolName,
            scope: scope,
            allowed: allowed,
            duration: duration,
            surface: surface,
            decidedAt: decidedAt
        )
    }

    /// Seeds rows in one transaction so cap tests need not issue 10k serial appends.
    @discardableResult
    static func seedRaw(count: Int, dbPath: String, baseDate: Date = Date(timeIntervalSince1970: 1000)) -> Bool {
        #if canImport(SQLite3)
            let expanded = (dbPath as NSString).expandingTildeInPath
            if let dir = (expanded as NSString).deletingLastPathComponent as String?, !dir.isEmpty {
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
            var handle: OpaquePointer?
            guard expanded.withCString({ sqlite3_open($0, &handle) }) == SQLITE_OK, let handle else { return false }
            defer { sqlite3_close(handle) }
            let createSQL = """
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
            """
            guard sqlite3_exec(handle, createSQL, nil, nil, nil) == SQLITE_OK else { return false }
            guard sqlite3_exec(handle, "BEGIN IMMEDIATE TRANSACTION;", nil, nil, nil) == SQLITE_OK else { return false }
            let sql = "INSERT INTO approval_decisions (id, tool_name, scope_kind, scope_data, allowed, duration, surface, session_id, display_target, decided_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                _ = sqlite3_exec(handle, "ROLLBACK;", nil, nil, nil)
                return false
            }
            defer { sqlite3_finalize(statement) }
            for index in 0 ..< count {
                let id = UUID().uuidString
                let at = baseDate.addingTimeInterval(Double(index))
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                _ = id.withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
                _ = "tool".withCString { sqlite3_bind_text(statement, 2, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
                sqlite3_bind_null(statement, 3)
                sqlite3_bind_null(statement, 4)
                sqlite3_bind_int64(statement, 5, 1)
                _ = "forever".withCString { sqlite3_bind_text(statement, 6, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
                _ = "chat".withCString { sqlite3_bind_text(statement, 7, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
                sqlite3_bind_null(statement, 8)
                sqlite3_bind_null(statement, 9)
                sqlite3_bind_double(statement, 10, at.timeIntervalSince1970)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    _ = sqlite3_exec(handle, "ROLLBACK;", nil, nil, nil)
                    return false
                }
            }
            return sqlite3_exec(handle, "COMMIT;", nil, nil, nil) == SQLITE_OK
        #else
            return false
        #endif
    }
}

@Suite("Approval Decision Log")
struct ApprovalDecisionLogTests {
    @Test
    func `append and list round-trip every field`() async throws {
        let (base, dbURL) = try ApprovalDecisionLogTestSupport.makeTempWorkspace()
        defer { ApprovalDecisionLogTestSupport.cleanup(base) }
        let store = ApprovalDecisionLogStore(dbPath: dbURL.path)
        let entry = ApprovalDecisionEntry(
            toolName: "api.request",
            scopeKind: "domain",
            scopeData: "example.com",
            allowed: false,
            duration: "forever",
            surface: "inbox",
            sessionID: "session-1",
            displayTarget: "GET https://example.com/",
            decidedAt: Date(timeIntervalSince1970: 2000)
        )
        await store.append(entry)
        #expect(try await store.count() == 1)
        let listed = try await store.list(limit: 10, offset: 0)
        #expect(listed == [entry])
    }

    @Test
    func `reads return newest first with limit and offset`() async throws {
        let (base, dbURL) = try ApprovalDecisionLogTestSupport.makeTempWorkspace()
        defer { ApprovalDecisionLogTestSupport.cleanup(base) }
        let store = ApprovalDecisionLogStore(dbPath: dbURL.path)
        let first = ApprovalDecisionLogTestSupport.makeEntry(decidedAt: Date(timeIntervalSince1970: 1000))
        let second = ApprovalDecisionLogTestSupport.makeEntry(decidedAt: Date(timeIntervalSince1970: 2000))
        let third = ApprovalDecisionLogTestSupport.makeEntry(decidedAt: Date(timeIntervalSince1970: 3000))
        await store.append(first)
        await store.append(second)
        await store.append(third)
        #expect(try await store.list(limit: 10, offset: 0) == [third, second, first])
        #expect(try await store.list(limit: 1, offset: 1) == [second])
        #expect(try await store.list(limit: 10, offset: 5).isEmpty)
    }

    @Test
    func `entry creation bounds over-long persisted fields`() {
        let entry = ApprovalDecisionEntry(
            toolName: String(repeating: "t", count: 500),
            scopeKind: String(repeating: "k", count: 100),
            scopeData: String(repeating: "d", count: 3000),
            allowed: true,
            duration: String(repeating: "u", count: 100),
            surface: String(repeating: "s", count: 100),
            sessionID: String(repeating: "S", count: 200),
            displayTarget: String(repeating: "/", count: 3000)
        )
        #expect(entry.toolName == String(repeating: "t", count: ApprovalDecisionLog.maxToolNameChars))
        #expect(entry.scopeKind == String(repeating: "k", count: ApprovalDecisionLog.maxScopeKindChars))
        #expect(entry.scopeData == String(repeating: "d", count: ApprovalDecisionLog.maxScopeDataChars))
        #expect(entry.duration == String(repeating: "u", count: ApprovalDecisionLog.maxDurationChars))
        #expect(entry.surface == String(repeating: "s", count: ApprovalDecisionLog.maxSurfaceChars))
        #expect(entry.sessionID == String(repeating: "S", count: ApprovalDecisionLog.maxSessionIDChars))
        #expect(entry.displayTarget == String(repeating: "/", count: ApprovalDecisionLog.maxDisplayTargetChars))
    }

    @Test
    func `within-bound fields pass through untouched`() {
        let entry = ApprovalDecisionEntry(
            toolName: "files.write",
            scopeKind: "exactTarget",
            scopeData: "/tmp/notes.md",
            allowed: false,
            duration: "thisTime",
            surface: "chat",
            sessionID: UUID().uuidString,
            displayTarget: "/tmp/notes.md"
        )
        #expect(entry.toolName == "files.write")
        #expect(entry.scopeData == "/tmp/notes.md")
        #expect(entry.surface == "chat")
    }

    @Test
    func `bounded fields round-trip through the store`() async throws {
        let (base, dbURL) = try ApprovalDecisionLogTestSupport.makeTempWorkspace()
        defer { ApprovalDecisionLogTestSupport.cleanup(base) }
        let store = ApprovalDecisionLogStore(dbPath: dbURL.path)
        // The entry bounds itself at creation, so the stored row carries the
        // capped rendering and reads back equal to what was appended.
        let oversized = ApprovalDecisionEntry(
            toolName: String(repeating: "x", count: 2000),
            scopeKind: "exactTarget",
            scopeData: String(repeating: "y", count: 5000),
            allowed: false,
            duration: "thisTime",
            surface: String(repeating: "z", count: 200),
            sessionID: String(repeating: "9", count: 300),
            displayTarget: String(repeating: "w", count: 4000),
            decidedAt: Date(timeIntervalSince1970: 1000)
        )
        await store.append(oversized)
        let listed = try await store.list(limit: 10, offset: 0)
        #expect(listed == [oversized])
        #expect(listed.first?.toolName.count == ApprovalDecisionLog.maxToolNameChars)
        #expect(listed.first?.scopeData?.count == ApprovalDecisionLog.maxScopeDataChars)
        #expect(listed.first?.surface.count == ApprovalDecisionLog.maxSurfaceChars)
        #expect(listed.first?.displayTarget?.count == ApprovalDecisionLog.maxDisplayTargetChars)
    }

    @Test
    func `the row cap evicts oldest in the same write`() async throws {
        let (base, dbURL) = try ApprovalDecisionLogTestSupport.makeTempWorkspace()
        defer { ApprovalDecisionLogTestSupport.cleanup(base) }
        #expect(ApprovalDecisionLog.maxRows == 10000)
        #expect(ApprovalDecisionLogTestSupport.seedRaw(count: ApprovalDecisionLog.maxRows, dbPath: dbURL.path))
        let store = ApprovalDecisionLogStore(dbPath: dbURL.path)
        #expect(try await store.count() == ApprovalDecisionLog.maxRows)
        let newest = ApprovalDecisionLogTestSupport.makeEntry(decidedAt: Date(timeIntervalSince1970: 1_000_000))
        await store.append(newest)
        #expect(try await store.count() == ApprovalDecisionLog.maxRows)
        let listed = try await store.list(limit: 1, offset: 0)
        #expect(listed == [newest])
    }

    @Test
    func `clearAll empties the table`() async throws {
        let (base, dbURL) = try ApprovalDecisionLogTestSupport.makeTempWorkspace()
        defer { ApprovalDecisionLogTestSupport.cleanup(base) }
        let store = ApprovalDecisionLogStore(dbPath: dbURL.path)
        await store.append(ApprovalDecisionLogTestSupport.makeEntry())
        await store.append(ApprovalDecisionLogTestSupport.makeEntry())
        #expect(try await store.count() == 2)
        await store.clearAll()
        #expect(try await store.count() == 0)
        #expect(try await store.list(limit: 10, offset: 0).isEmpty)
    }

    @Test
    func `scope renderings cover every AccessScope kind`() throws {
        let toolWide = ApprovalDecisionLog.scopeFields(for: .toolWide)
        #expect(toolWide.kind == "toolWide")
        #expect(toolWide.data == "tool")
        let exact = ApprovalDecisionLog.scopeFields(for: .exactTarget("a@x.com"))
        #expect(exact.kind == "exactTarget")
        #expect(exact.data == "a@x.com")
        let recipients = ApprovalDecisionLog.scopeFields(for: .recipientSet(["B@x.com", "a@x.com"]))
        #expect(recipients.kind == "recipientSet")
        #expect(recipients.data == "a@x.com,b@x.com")
        let domain = ApprovalDecisionLog.scopeFields(for: .domain(host: "example.com", subdomains: true))
        #expect(domain.kind == "domain")
        #expect(domain.data == "example.com")
        let prefix = try #require(AccessScope.canonicalPathPrefix("/tmp"))
        let path = ApprovalDecisionLog.scopeFields(for: .pathPrefix(prefix))
        #expect(path.kind == "pathPrefix")
        #expect(path.data == prefix)
        let glob = ApprovalDecisionLog.scopeFields(for: .glob("git status"))
        #expect(glob.kind == "glob")
        #expect(glob.data == "git status")
    }

    @Test
    func `an unreadable store degrades to empty reads without throwing`() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("runeweaver-approvallog-blocked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        // A regular file where the store needs a directory makes every open
        // fail before SQLite is reached, modelling an unreadable store.
        let blocker = base.appendingPathComponent("blocker")
        try Data("not a directory".utf8).write(to: blocker)
        let store = ApprovalDecisionLogStore(dbPath: blocker.appendingPathComponent("episodes.db").path)
        await store.append(ApprovalDecisionLogTestSupport.makeEntry())
        #expect(try await store.list(limit: 10, offset: 0).isEmpty)
        #expect(try await store.count() == 0)
        await store.clearAll()
        #expect(try await store.count() == 0)
    }

    @Test
    func `the in-memory log matches SQLite on the same matrix`() async throws {
        let memory = InMemoryApprovalDecisionLog()
        let first = ApprovalDecisionLogTestSupport.makeEntry(decidedAt: Date(timeIntervalSince1970: 1000))
        let second = ApprovalDecisionLogTestSupport.makeEntry(decidedAt: Date(timeIntervalSince1970: 2000))
        await memory.append(first)
        await memory.append(second)
        #expect(try await memory.count() == 2)
        #expect(try await memory.list(limit: 10, offset: 0) == [second, first])
        #expect(try await memory.list(limit: 1, offset: 1) == [first])
        await memory.clearAll()
        #expect(try await memory.count() == 0)
        #expect(try await memory.list(limit: 10, offset: 0).isEmpty)
    }

    @Test
    func `the in-memory log evicts oldest past the cap`() async throws {
        let memory = InMemoryApprovalDecisionLog()
        for index in 0 ..< (ApprovalDecisionLog.maxRows + 5) {
            await memory.append(ApprovalDecisionLogTestSupport.makeEntry(
                decidedAt: Date(timeIntervalSince1970: Double(1000 + index))
            ))
        }
        #expect(try await memory.count() == ApprovalDecisionLog.maxRows)
        let newest = try await memory.list(limit: 1, offset: 0)
        #expect(newest.count == 1)
        #expect(newest[0].decidedAt == Date(timeIntervalSince1970: Double(1000 + ApprovalDecisionLog.maxRows + 4)))
    }
}

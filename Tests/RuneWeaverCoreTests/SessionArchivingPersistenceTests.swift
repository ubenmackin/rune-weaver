// Rune Weaver Core Tests — Session archiving persistence and migration tests.
//
// Covers the additive `sessions.is_archived` column end to end:
// 1. Archiving flag survives SQLite write and read cycle.
// 2. setSessionArchived toggles the state and persists immediately.
// 3. Legacy databases lacking `is_archived` migrate smoothly and decode as unarchived.

import Foundation
@testable import RuneWeaverCore
import Testing
#if canImport(SQLite3)
    import SQLite3
#endif

@Suite("Session Archiving Persistence")
struct SessionArchivingPersistenceTests {
    private func temporaryDBPath() -> (base: URL, dbPath: String) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("session-archive-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return (base, base.appendingPathComponent("episodes.db").path)
    }

    private func buildLegacyFixture(dbPath: String, sessionID: UUID) -> Bool {
        #if canImport(SQLite3)
            let expanded = (dbPath as NSString).expandingTildeInPath
            var handle: OpaquePointer?
            guard expanded.withCString({ sqlite3_open($0, &handle) }) == SQLITE_OK, let handle else { return false }
            defer { sqlite3_close(handle) }
            let now = Date().timeIntervalSince1970
            let fixtureSQL = """
            CREATE TABLE sessions(
                id TEXT PRIMARY KEY,
                title TEXT,
                summary TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                source TEXT,
                goal_id TEXT,
                parent_session_id TEXT
            );
            CREATE TABLE messages(
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                role TEXT NOT NULL,
                content TEXT NOT NULL,
                tool_call_id TEXT,
                is_error INTEGER,
                created_at REAL NOT NULL,
                error_kind TEXT
            );
            INSERT INTO sessions(id, title, summary, created_at, updated_at, source, goal_id, parent_session_id)
            VALUES('\(sessionID.uuidString)', 'Legacy Session', NULL, \(now), \(now), 'chat', NULL, NULL);
            INSERT INTO messages(id, session_id, role, content, created_at)
            VALUES('\(UUID().uuidString)', '\(sessionID.uuidString)', 'user', 'hello', \(now));
            """
            return fixtureSQL.withCString { sqlite3_exec(handle, $0, nil, nil, nil) } == SQLITE_OK
        #else
            return false
        #endif
    }

    @Test
    func `Archived flag persists and round-trips via SQLite`() async {
        let (base, dbPath) = temporaryDBPath()
        defer { try? FileManager.default.removeItem(at: base) }

        let manager = ConversationManager(episodesDBPath: dbPath)
        let sessionID = UUID()
        await manager.ensureSession(id: sessionID, title: "Test Archive")
        _ = await manager.append(Message(role: .user, content: "Ping"), to: sessionID)

        let initial = await manager.session(id: sessionID)
        #expect(initial?.isArchived == false)

        await manager.setSessionArchived(id: sessionID, isArchived: true)

        let reloadedManager = ConversationManager(episodesDBPath: dbPath)
        let reloaded = await reloadedManager.session(id: sessionID)
        #expect(reloaded?.isArchived == true)

        let summaries = await reloadedManager.listSessions()
        let summary = summaries.first(where: { $0.id == sessionID })
        #expect(summary?.isArchived == true)

        await reloadedManager.setSessionArchived(id: sessionID, isArchived: false)
        let unarchived = await reloadedManager.session(id: sessionID)
        #expect(unarchived?.isArchived == false)
    }

    @Test
    func `Legacy database without is_archived migrates and defaults to unarchived`() async {
        let (base, dbPath) = temporaryDBPath()
        defer { try? FileManager.default.removeItem(at: base) }

        let sessionID = UUID()
        #expect(buildLegacyFixture(dbPath: dbPath, sessionID: sessionID))

        let manager = ConversationManager(episodesDBPath: dbPath)
        let loaded = await manager.session(id: sessionID)
        #expect(loaded != nil)
        #expect(loaded?.isArchived == false)

        let summaries = await manager.listSessions()
        let summary = summaries.first(where: { $0.id == sessionID })
        #expect(summary != nil)
        #expect(summary?.isArchived == false)

        await manager.setSessionArchived(id: sessionID, isArchived: true)
        let updated = await manager.session(id: sessionID)
        #expect(updated?.isArchived == true)
    }
}

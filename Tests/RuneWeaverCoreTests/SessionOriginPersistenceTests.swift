// Rune Weaver Core Tests — Durable parent-session origin persistence.
//
// Covers the additive `sessions.parent_session_id` column end to end: a parent
// link survives a persist/reload cycle through episodes.db and rides the
// listing payload, a database created before the column existed still reads
// with an unparented session and no error, and malformed stored text degrades
// to nil instead of failing the history load. Fixture setup writes raw SQLite
// so legacy tables genuinely predate the migration instead of being produced
// by the code under test, mirroring the goal-linkage migration harness.

import Foundation
@testable import RuneWeaverCore
import Testing
#if canImport(SQLite3)
    import SQLite3
#endif

@Suite("Session Origin Persistence")
struct SessionOriginPersistenceTests {
    /// Fresh temporary directory plus the episodes database path inside it.
    private func temporaryDBPath() -> (base: URL, dbPath: String) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("session-origin-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return (base, base.appendingPathComponent("episodes.db").path)
    }

    /// Executes one raw statement against the fixture database.
    /// Fixture setup and corruption bypass the stores on purpose so the tables
    /// and values under test are not produced by the writer path.
    @discardableResult
    private func execRaw(dbPath: String, sql: String) -> Bool {
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

    /// Declared columns for a table, lowercased for case-tolerant checks.
    private func rawColumnNames(dbPath: String, table: String) -> Set<String> {
        #if canImport(SQLite3)
            var names: Set<String> = []
            let expanded = (dbPath as NSString).expandingTildeInPath
            var handle: OpaquePointer?
            guard expanded.withCString({ sqlite3_open($0, &handle) }) == SQLITE_OK, let handle else { return names }
            defer { sqlite3_close(handle) }
            // The table name is a fixed literal from the test body, never user input.
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "PRAGMA table_info(\(table));", -1, &statement, nil) == SQLITE_OK,
                  let statement
            else { return names }
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                if let text = sqlite3_column_text(statement, 1) {
                    names.insert(String(cString: text).lowercased())
                }
            }
            return names
        #else
            return []
        #endif
    }

    /// Builds a database as it looked before either session link existed: a
    /// sessions table without `goal_id` or `parent_session_id` holding one
    /// legacy row plus one message.
    private func buildPreLinkFixture(dbPath: String, sessionID: UUID) -> Bool {
        let now = Date().timeIntervalSince1970
        let fixtureSQL = """
        CREATE TABLE sessions(
            id TEXT PRIMARY KEY,
            title TEXT,
            summary TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            source TEXT
        );
        CREATE TABLE messages(
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            role TEXT NOT NULL,
            content TEXT NOT NULL,
            tool_call_id TEXT,
            is_error INTEGER,
            created_at REAL NOT NULL,
            error_kind TEXT,
            FOREIGN KEY(session_id) REFERENCES sessions(id) ON DELETE CASCADE
        );
        INSERT INTO sessions(id, title, summary, created_at, updated_at, source)
        VALUES('\(sessionID.uuidString)', 'Legacy session', NULL, \(now), \(now), 'chat');
        INSERT INTO messages(id, session_id, role, content, tool_call_id, is_error, created_at, error_kind)
        VALUES('\(UUID().uuidString)', '\(sessionID.uuidString)', 'user', 'legacy hello', NULL, NULL, \(now), NULL);
        """
        return execRaw(dbPath: dbPath, sql: fixtureSQL)
    }

    @Test
    func `Parent link survives a persist and reload cycle`() async throws {
        #if canImport(SQLite3)
            let (base, dbPath) = temporaryDBPath()
            defer { try? FileManager.default.removeItem(at: base) }
            let parentID = UUID()
            let sessionID = UUID()

            let manager = ConversationManager(episodesDBPath: dbPath)
            _ = await manager.ensureSession(
                id: sessionID,
                source: FanOutEngine.workerSource,
                parentSessionID: parentID
            )
            // New sessions stay in memory until their first message, so the
            // append is what materializes the row and must carry the link with
            // it.
            await manager.append(Message(role: .user, content: "worker hello"), to: sessionID)

            // A fresh manager over the same path sees the same link, proving
            // the value reached episodes.db instead of only memory.
            let reopened = ConversationManager(episodesDBPath: dbPath)
            let reloaded = try #require(await reopened.session(id: sessionID))
            #expect(reloaded.parentSessionID == parentID)
            #expect(reloaded.source == FanOutEngine.workerSource)

            // The listing payload carries the link so clients can nest a
            // session without a second query against the store.
            let summaries = await reopened.listSessions()
            let summary = try #require(summaries.first { $0.id == sessionID })
            #expect(summary.parentSessionID == parentID)
        #endif
    }

    @Test
    func `Pre-link database reads with nil links and no error`() throws {
        #if canImport(SQLite3)
            let (base, dbPath) = temporaryDBPath()
            defer { try? FileManager.default.removeItem(at: base) }
            let sessionID = UUID()
            #expect(buildPreLinkFixture(dbPath: dbPath, sessionID: sessionID) == true)

            // The legacy row survives the read with both links nil: an absent
            // parent column must degrade to unparented, never fail the load.
            let sessions = try SessionStoreIO.read(dbPath: dbPath)
            let legacy = try #require(sessions.first { $0.id == sessionID })
            #expect(legacy.parentSessionID == nil)
            #expect(legacy.goalID == nil)
            #expect(legacy.title == "Legacy session")
            #expect(legacy.messages.map(\.content) == ["legacy hello"])

            // The store's own open ran the additive migration, so the column
            // now exists alongside the pre-existing ones.
            let columns = rawColumnNames(dbPath: dbPath, table: "sessions")
            #expect(columns.contains("parent_session_id") == true)
            #expect(columns.contains("goal_id") == true)
        #endif
    }

    @Test
    func `Malformed parent text degrades to nil`() async throws {
        #if canImport(SQLite3)
            let (base, dbPath) = temporaryDBPath()
            defer { try? FileManager.default.removeItem(at: base) }
            let sessionID = UUID()

            let manager = ConversationManager(episodesDBPath: dbPath)
            _ = await manager.ensureSession(
                id: sessionID,
                source: FanOutEngine.workerSource,
                parentSessionID: UUID()
            )
            await manager.append(Message(role: .user, content: "worker hello"), to: sessionID)

            // Corrupt the stored link behind the store's back; one bad cell
            // must not fail the history load for that row or any other.
            #expect(execRaw(
                dbPath: dbPath,
                sql: "UPDATE sessions SET parent_session_id = 'not-a-uuid' WHERE id = '\(sessionID.uuidString)';"
            ) == true)

            let reopened = ConversationManager(episodesDBPath: dbPath)
            let reloaded = try #require(await reopened.session(id: sessionID))
            #expect(reloaded.parentSessionID == nil)
            let sessions = try SessionStoreIO.read(dbPath: dbPath)
            #expect(sessions.first { $0.id == sessionID }?.parentSessionID == nil)
        #endif
    }
}

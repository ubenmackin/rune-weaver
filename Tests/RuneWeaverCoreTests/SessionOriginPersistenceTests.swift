// Rune Weaver Core Tests — Durable parent-session origin persistence.

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

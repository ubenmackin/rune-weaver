// Rune Weaver Tests — Goal linkage migration for sessions and run history.
//
// Covers the additive goal_id migrations on the shared episodes database:
// pre-migration tables gain the column on reopen, legacy rows survive with a
// nil link, session linking round-trips through persistence, and goal-scoped
// listing keeps working. The run-history half pins the exact fixture shape and
// filter SQL both the session and run stores agree on, since they share one
// SQLite file but migrate their own tables.

import Foundation
@testable import RuneWeaverCore
import Testing
#if canImport(SQLite3)
    import SQLite3
#endif

@Suite("Goal Linkage Migration")
struct GoalLinkageMigrationTests {
    private func temporaryDBPath() -> (base: URL, dbPath: String) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("goal-link-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return (base, base.appendingPathComponent("episodes.db").path)
    }

    /// Executes one raw statement against the fixture database.
    /// Fixture setup bypasses the stores on purpose so the tables genuinely
    /// predate the migration instead of being created by the code under test.
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

    /// Builds a database as it looked before goal linkage existed: session and
    /// run tables without the link column, each holding one legacy row.
    private func buildPreMigrationFixture(dbPath: String, sessionID: UUID, runID: UUID) -> Bool {
        let now = Date().timeIntervalSince1970
        let sessionSQL = """
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
        CREATE TABLE run_logs(
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
        INSERT INTO sessions(id, title, summary, created_at, updated_at, source)
        VALUES('\(sessionID.uuidString)', 'Legacy session', NULL, \(now), \(now), 'chat');
        INSERT INTO messages(id, session_id, role, content, tool_call_id, is_error, created_at, error_kind)
        VALUES('\(UUID().uuidString)', '\(sessionID.uuidString)', 'user', 'legacy hello', NULL, NULL, \(now), NULL);
        INSERT INTO run_logs(id, job_id, session_id, kind, status, message, timestamp, response, tool_actions, total_tokens, duration_ms)
        VALUES('\(runID.uuidString)', NULL, '\(sessionID.uuidString)', 'chat', 'ok', 'legacy turn', \(now), 'legacy reply', '[]', NULL, NULL);
        """
        return execRaw(dbPath: dbPath, sql: sessionSQL)
    }

    /// Raw goal value for one row, distinguishing NULL from a stored link.
    private func rawGoalValue(dbPath: String, table: String, idColumn: String, id: UUID) -> String?? {
        #if canImport(SQLite3)
            let expanded = (dbPath as NSString).expandingTildeInPath
            var handle: OpaquePointer?
            guard expanded.withCString({ sqlite3_open($0, &handle) }) == SQLITE_OK, let handle else { return nil }
            defer { sqlite3_close(handle) }
            var statement: OpaquePointer?
            // Table and column names are fixed literals from the test body.
            guard sqlite3_prepare_v2(handle, "SELECT goal_id FROM \(table) WHERE \(idColumn) = ?;", -1, &statement, nil) == SQLITE_OK,
                  let statement
            else { return nil }
            defer { sqlite3_finalize(statement) }
            _ = id.uuidString.withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            guard sqlite3_column_type(statement, 0) != SQLITE_NULL else { return .some(nil) }
            guard let text = sqlite3_column_text(statement, 0) else { return nil }
            return .some(String(cString: text))
        #else
            return nil
        #endif
    }

    @Test
    func `Pre-migration sessions gain goal_id with legacy rows intact`() async {
        #if canImport(SQLite3)
            let (base, dbPath) = temporaryDBPath()
            defer { try? FileManager.default.removeItem(at: base) }
            let sessionID = UUID()
            let runID = UUID()
            #expect(buildPreMigrationFixture(dbPath: dbPath, sessionID: sessionID, runID: runID) == true)

            // Reopening through the manager runs the additive migration.
            let manager = ConversationManager(episodesDBPath: dbPath)
            _ = await manager.listSessions()

            // The link column exists now, alongside the pre-existing columns.
            let columns = rawColumnNames(dbPath: dbPath, table: "sessions")
            #expect(columns.contains("goal_id") == true)
            #expect(columns.contains("source") == true)

            // The legacy session survives with its history and no link.
            let loaded = await manager.session(id: sessionID)
            #expect(loaded?.title == "Legacy session")
            #expect(loaded?.source == "chat")
            #expect(loaded?.messages.count == 1)
            #expect(loaded?.messages.first?.content == "legacy hello")
            #expect(loaded?.goalID == nil)

            // The listing surface exposes the absent link as nil rather than dropping the row.
            let summaries = await manager.listSessions()
            #expect(summaries.contains { $0.id == sessionID && $0.goalID == nil } == true)
        #endif
    }

    @Test
    func `Linking a session to a goal persists across reloads`() async throws {
        #if canImport(SQLite3)
            let (base, dbPath) = temporaryDBPath()
            defer { try? FileManager.default.removeItem(at: base) }
            let sessionID = UUID()
            #expect(buildPreMigrationFixture(dbPath: dbPath, sessionID: sessionID, runID: UUID()) == true)

            let goalID = UUID()
            let manager = ConversationManager(episodesDBPath: dbPath)
            await manager.linkSession(sessionID, toGoal: goalID)
            #expect(await manager.session(id: sessionID)?.goalID == goalID)

            // The listing payload carries the link so clients can badge the
            // session without a second query against run history.
            let summaries = await manager.listSessions()
            #expect(summaries.first { $0.id == sessionID }?.goalID == goalID)

            // The detail payload exposes the shared wire spelling.
            let detail = try #require(await manager.session(id: sessionID))
            let encoded = try JSONEncoder().encode(detail)
            let wire = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            #expect(wire["goalId"] as? String == goalID.uuidString)

            // A fresh manager sees the same link: it reached disk, not just memory.
            let reopened = ConversationManager(episodesDBPath: dbPath)
            #expect(await reopened.session(id: sessionID)?.goalID == goalID)

            // Unlinking clears the column back to NULL.
            await reopened.linkSession(sessionID, toGoal: nil)
            #expect(await reopened.session(id: sessionID)?.goalID == nil)
            let cleared = try #require(rawGoalValue(dbPath: dbPath, table: "sessions", idColumn: "id", id: sessionID))
            #expect(cleared == nil)

            // Linking an unknown session stays a no-op instead of conjuring a row.
            await reopened.linkSession(UUID(), toGoal: UUID())
            #expect(await reopened.listSessions().count == 1)
        #endif
    }

    @Test
    func `Session summaries filter by goal without querying runs`() async {
        let (base, dbPath) = temporaryDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let manager = ConversationManager(episodesDBPath: dbPath)
        let goalA = UUID()
        let goalB = UUID()
        let first = await manager.createSession(goalID: goalA)
        let second = await manager.createSession(goalID: goalA)
        let third = await manager.createSession(goalID: goalB)
        _ = await manager.createSession()

        // The dashboard resolves its session-to-goal chip from the listing
        // alone, so filtering the listed summaries by link must be exact.
        let summaries = await manager.listSessions()
        let filtered = summaries.filter { $0.goalID == goalA }.map(\.id).sorted(by: { $0.uuidString < $1.uuidString })
        let expected = [first.id, second.id].sorted(by: { $0.uuidString < $1.uuidString })
        #expect(filtered == expected)
        #expect(summaries.filter { $0.goalID == goalB }.map(\.id) == [third.id])
        #expect(summaries.filter { $0.goalID == nil }.count == 1)
    }

    @Test
    func `Legacy payloads decode without a goal tag`() throws {
        // Rows and inputs written before goal linkage carry no link key; the
        // absence must mean unlinked rather than corrupt.
        let sessionData = """
        {"id":"\(UUID().uuidString)","title":"Old","messages":[],"createdAt":0,"updatedAt":0}
        """.data(using: .utf8)!
        #expect(try JSONDecoder().decode(ConversationSession.self, from: sessionData).goalID == nil)

        let summaryData = """
        {"id":"\(UUID().uuidString)","title":"Old","messageCount":0,"createdAt":0,"updatedAt":0}
        """.data(using: .utf8)!
        #expect(try JSONDecoder().decode(SessionSummary.self, from: summaryData).goalID == nil)

        let inputData = """
        {"text":"hello","sessionID":"\(UUID().uuidString)","source":"text"}
        """.data(using: .utf8)!
        #expect(try JSONDecoder().decode(UserInput.self, from: inputData).goalID == nil)

        // Tagged inputs round-trip with the link intact.
        let tagged = UserInput(text: "hello", sessionID: UUID(), source: "text", goalID: UUID())
        let decoded = try JSONDecoder().decode(UserInput.self, from: JSONEncoder().encode(tagged))
        #expect(decoded == tagged)
        #expect(decoded.goalID == tagged.goalID)
    }

    @Test
    func `Pre-migration run rows survive with nil goal and goal filtering works`() async throws {
        #if canImport(SQLite3)
            let (base, dbPath) = temporaryDBPath()
            defer { try? FileManager.default.removeItem(at: base) }
            let sessionID = UUID()
            let legacyRunID = UUID()
            #expect(buildPreMigrationFixture(dbPath: dbPath, sessionID: sessionID, runID: legacyRunID) == true)

            // The session migration must leave run history untouched.
            let manager = ConversationManager(episodesDBPath: dbPath)
            _ = await manager.listSessions()
            #expect(rawColumnNames(dbPath: dbPath, table: "run_logs").contains("goal_id") == false)

            // The run store's additive migration uses this exact statement on
            // open; applying it here pins the shared-table contract both sides
            // rely on: old rows gain a NULL link, new rows store one.
            #expect(execRaw(dbPath: dbPath, sql: "ALTER TABLE run_logs ADD COLUMN goal_id TEXT;") == true)
            #expect(rawColumnNames(dbPath: dbPath, table: "run_logs").contains("goal_id") == true)

            let legacyGoal = try #require(rawGoalValue(dbPath: dbPath, table: "run_logs", idColumn: "id", id: legacyRunID))
            #expect(legacyGoal == nil)

            let goalID = UUID()
            let taggedRunID = UUID()
            let now = Date().timeIntervalSince1970
            #expect(execRaw(
                dbPath: dbPath,
                sql: "INSERT INTO run_logs(id, job_id, session_id, goal_id, kind, status, message, timestamp) "
                    + "VALUES('\(taggedRunID.uuidString)', NULL, '\(sessionID.uuidString)', '\(goalID.uuidString)', 'chat', 'ok', 'tagged turn', \(now));"
            ) == true)

            // Goal-scoped history reads back exactly the tagged row.
            let taggedGoal = try #require(rawGoalValue(dbPath: dbPath, table: "run_logs", idColumn: "id", id: taggedRunID))
            #expect(taggedGoal == goalID.uuidString)
            let legacyGoalAfter = try #require(rawGoalValue(dbPath: dbPath, table: "run_logs", idColumn: "id", id: legacyRunID))
            #expect(legacyGoalAfter == nil)
        #endif
    }
}

// Rune Weaver Tests — Goal linkage persistence for sessions.

import Foundation
@testable import RuneWeaverCore
import Testing
#if canImport(SQLite3)
    import SQLite3
#endif

@Suite("Goal Linkage Persistence")
struct GoalLinkageMigrationTests {
    private func temporaryDBPath() -> (base: URL, dbPath: String) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("goal-link-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return (base, base.appendingPathComponent("episodes.db").path)
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
    func `Linking a session to a goal persists across reloads`() async throws {
        #if canImport(SQLite3)
            let (base, dbPath) = temporaryDBPath()
            defer { try? FileManager.default.removeItem(at: base) }
            let manager = ConversationManager(episodesDBPath: dbPath)
            let session = await manager.createSession()
            let sessionID = session.id

            let goalID = UUID()
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
        let sessionData = try #require("""
        {"id":"\(UUID().uuidString)","title":"Old","messages":[],"createdAt":0,"updatedAt":0}
        """.data(using: .utf8))
        #expect(try JSONDecoder().decode(ConversationSession.self, from: sessionData).goalID == nil)

        let summaryData = try #require("""
        {"id":"\(UUID().uuidString)","title":"Old","messageCount":0,"createdAt":0,"updatedAt":0}
        """.data(using: .utf8))
        #expect(try JSONDecoder().decode(SessionSummary.self, from: summaryData).goalID == nil)

        let inputData = try #require("""
        {"text":"hello","sessionID":"\(UUID().uuidString)","source":"text"}
        """.data(using: .utf8))
        #expect(try JSONDecoder().decode(UserInput.self, from: inputData).goalID == nil)

        // Tagged inputs round-trip with the link intact.
        let tagged = UserInput(text: "hello", sessionID: UUID(), source: "text", goalID: UUID())
        let decoded = try JSONDecoder().decode(UserInput.self, from: JSONEncoder().encode(tagged))
        #expect(decoded == tagged)
        #expect(decoded.goalID == tagged.goalID)
    }
}

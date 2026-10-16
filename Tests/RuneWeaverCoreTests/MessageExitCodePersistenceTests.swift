// Rune Weaver Core Tests — Message exitCode persistence and migration tests.

import Foundation
@testable import RuneWeaverCore
import Testing
#if canImport(SQLite3)
    import SQLite3
#endif

@Suite("Message Exit Code Persistence")
struct MessageExitCodePersistenceTests {
    private func temporaryDBPath() -> (base: URL, dbPath: String) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("message-exitcode-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return (base, base.appendingPathComponent("episodes.db").path)
    }

    private func buildLegacyFixture(dbPath: String, sessionID: UUID, messageID: UUID) -> Bool {
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
                parent_session_id TEXT,
                is_archived INTEGER NOT NULL DEFAULT 0
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
                reasoning TEXT
            );
            INSERT INTO sessions(id, title, summary, created_at, updated_at, source, goal_id, parent_session_id, is_archived)
            VALUES('\(sessionID.uuidString)', 'Test Session', NULL, \(now), \(now), 'chat', NULL, NULL, 0);
            INSERT INTO messages(id, session_id, role, content, created_at)
            VALUES('\(messageID.uuidString)', '\(sessionID.uuidString)', 'assistant', 'Legacy reply without exitCode', \(now));
            """
            return fixtureSQL.withCString { sqlite3_exec(handle, $0, nil, nil, nil) } == SQLITE_OK
        #else
            return false
        #endif
    }

    @Test
    func `Message exitCode persists and reloads cycle`() async {
        let (base, dbPath) = temporaryDBPath()
        defer { try? FileManager.default.removeItem(at: base) }

        let manager = ConversationManager(episodesDBPath: dbPath)
        let sessionID = UUID()
        await manager.ensureSession(id: sessionID, title: "ExitCode Test")

        let narrated = ToolInput.placeholderContent(for: [
            ToolInput(toolName: "bash.exec", argumentsJSON: "{}", callID: "call_exit2")
        ])
        let assistantMsg = Message(
            role: .assistant,
            content: narrated
        )
        _ = await manager.append(assistantMsg, to: sessionID)

        let toolMsg = Message(
            role: .tool,
            content: "ls: cannot access '/Users': No such file or directory",
            toolCallID: "call_exit2",
            isError: true,
            exitCode: 2
        )
        let appended = await manager.append(toolMsg, to: sessionID)
        #expect(appended.exitCode == 2)

        let reloaded = await manager.session(id: sessionID)
        #expect(reloaded != nil)
        let toolResultMsg = reloaded?.messages.first { $0.toolCallID == "call_exit2" }
        #expect(toolResultMsg?.exitCode == 2)
        #expect(toolResultMsg?.isError == true)

        let toolActionsMap = await manager.toolActionsByMessage(for: sessionID)
        let actions = toolActionsMap.values.flatMap(\.self)
        let matchedResult = actions.first { $0.callID == "call_exit2" }?.result
        #expect(matchedResult?.exitCode == 2)
        #expect(matchedResult?.isError == true)
    }

    @Test
    func `Legacy database migrates and supports exitCode`() async {
        let (base, dbPath) = temporaryDBPath()
        defer { try? FileManager.default.removeItem(at: base) }

        let sessionID = UUID()
        let legacyMsgID = UUID()
        #expect(buildLegacyFixture(dbPath: dbPath, sessionID: sessionID, messageID: legacyMsgID))

        // Opening the database must run the column migration adding `exit_code`
        let manager = ConversationManager(episodesDBPath: dbPath)
        let session = await manager.session(id: sessionID)
        #expect(session != nil)
        let legacyMsg = session?.messages.first { $0.id == legacyMsgID }
        #expect(legacyMsg?.content == "Legacy reply without exitCode")
        #expect(legacyMsg?.exitCode == nil)

        // Appending a new tool message with exitCode to the migrated database
        let newToolMsg = Message(
            role: .tool,
            content: "exit 2 failure",
            toolCallID: "call_migrated",
            isError: true,
            exitCode: 2
        )
        _ = await manager.append(newToolMsg, to: sessionID)

        let reloaded = await manager.session(id: sessionID)
        let migratedMsg = reloaded?.messages.first { $0.toolCallID == "call_migrated" }
        #expect(migratedMsg?.exitCode == 2)
    }
}

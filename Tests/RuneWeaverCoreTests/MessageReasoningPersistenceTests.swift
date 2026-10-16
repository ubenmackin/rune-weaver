// Rune Weaver Core Tests — Message reasoning persistence and migration tests.

import Foundation
@testable import RuneWeaverCore
import Testing
#if canImport(SQLite3)
    import SQLite3
#endif

@Suite("Message Reasoning Persistence")
struct MessageReasoningPersistenceTests {
    private func temporaryDBPath() -> (base: URL, dbPath: String) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("message-reasoning-\(UUID().uuidString)")
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
                error_kind TEXT
            );
            INSERT INTO sessions(id, title, summary, created_at, updated_at, source, goal_id, parent_session_id, is_archived)
            VALUES('\(sessionID.uuidString)', 'Test Session', NULL, \(now), \(now), 'chat', NULL, NULL, 0);
            INSERT INTO messages(id, session_id, role, content, created_at)
            VALUES('\(messageID.uuidString)', '\(sessionID.uuidString)', 'assistant', 'Legacy reply without reasoning', \(now));
            """
            return fixtureSQL.withCString { sqlite3_exec(handle, $0, nil, nil, nil) } == SQLITE_OK
        #else
            return false
        #endif
    }

    @Test
    func `Message reasoning persists and reloads cycle`() async {
        let (base, dbPath) = temporaryDBPath()
        defer { try? FileManager.default.removeItem(at: base) }

        let manager = ConversationManager(episodesDBPath: dbPath)
        let sessionID = UUID()
        await manager.ensureSession(id: sessionID, title: "Reasoning Test")
        let note = Message(
            role: .assistant,
            content: "Calculated response",
            reasoning: "Step 1: Analyzed inputs. Step 2: Derived result."
        )
        let appended = await manager.append(note, to: sessionID)
        #expect(appended.reasoning == "Step 1: Analyzed inputs. Step 2: Derived result.")

        let reloaded = await manager.session(id: sessionID)
        #expect(reloaded != nil)
        let assistantMsg = reloaded?.messages.first { $0.role == Message.Role.assistant }
        #expect(assistantMsg?.content == "Calculated response")
        #expect(assistantMsg?.reasoning == "Step 1: Analyzed inputs. Step 2: Derived result.")
    }

    @Test
    func `Legacy database migrates and supports reasoning`() async {
        let (base, dbPath) = temporaryDBPath()
        defer { try? FileManager.default.removeItem(at: base) }

        let sessionID = UUID()
        let legacyMsgID = UUID()
        #expect(buildLegacyFixture(dbPath: dbPath, sessionID: sessionID, messageID: legacyMsgID))

        // Opening the database must run the column migration adding `reasoning`
        let manager = ConversationManager(episodesDBPath: dbPath)
        let session = await manager.session(id: sessionID)
        #expect(session != nil)
        let legacyMsg = session?.messages.first { $0.id == legacyMsgID }
        #expect(legacyMsg?.content == "Legacy reply without reasoning")
        #expect(legacyMsg?.reasoning == nil)

        // Appending a new message with reasoning to the migrated database
        let newNote = Message(
            role: .assistant,
            content: "Modern reply with reasoning",
            reasoning: "Thinking about the legacy migration."
        )
        _ = await manager.append(newNote, to: sessionID)

        let reloaded = await manager.session(id: sessionID)
        let modernMsg = reloaded?.messages.first { $0.content == "Modern reply with reasoning" }
        #expect(modernMsg?.reasoning == "Thinking about the legacy migration.")
    }
}

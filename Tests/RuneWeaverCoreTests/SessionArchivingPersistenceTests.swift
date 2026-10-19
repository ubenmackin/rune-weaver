// Rune Weaver Core Tests — Session archiving persistence and migration tests.

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
}

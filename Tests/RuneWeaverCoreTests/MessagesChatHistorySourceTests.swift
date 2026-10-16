// Rune Weaver Core Tests — Direct-chat handle history from a fixture chat.db.

import Foundation
@testable import RuneWeaverCore
@testable import RuneWeaverTools
import Testing

#if canImport(SQLite3)
    import SQLite3
#endif

/// Error raised when a raw fixture statement cannot run.
private enum ChatHistoryFixtureError: Error {
    /// The statement failed with a SQLite detail string.
    case failed(String)
}

/// Creates isolated filesystem paths for one history test.
/// - Returns: Base directory plus the fixture database path.
private func makeChatHistoryPaths() -> (base: URL, database: String) {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("runeweaver-messages-history-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return (base, base.appendingPathComponent("chat.db").path)
}

/// Opens or creates a chat-history fixture database.
/// - Parameter path: SQLite file path.
/// - Returns: Open handle owned by the caller.
private func openChatHistoryFixture(at path: String) throws -> OpaquePointer {
    #if canImport(SQLite3)
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let handle else {
            if let handle {
                sqlite3_close(handle)
            }
            throw ChatHistoryFixtureError.failed("Could not open chat-history fixture database")
        }
        return handle
    #else
        throw ChatHistoryFixtureError.failed("SQLite3 unavailable")
    #endif
}

/// Executes a multi-statement SQL string against a chat-history fixture. handle:
/// Open fixture handle.
private func execChatHistoryFixture(_ handle: OpaquePointer?, _ sql: String) throws {
    #if canImport(SQLite3)
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &message) == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(message)
            throw ChatHistoryFixtureError.failed(detail)
        }
    #endif
}

/// Creates the chat-history tables and seeds two direct chats plus one group chat.
private func seedChatHistoryFixture(at path: String) throws {
    let handle = try openChatHistoryFixture(at: path)
    defer { sqlite3_close(handle) }
    try execChatHistoryFixture(
        handle,
        """
        CREATE TABLE message(ROWID INTEGER PRIMARY KEY, guid TEXT, text TEXT, date INTEGER);
        CREATE TABLE handle(ROWID INTEGER PRIMARY KEY, id TEXT, service TEXT);
        CREATE TABLE chat(ROWID INTEGER PRIMARY KEY, guid TEXT, display_name TEXT, chat_identifier TEXT, style INTEGER);
        CREATE TABLE chat_message_join(chat_id INTEGER, message_id INTEGER);
        CREATE TABLE chat_handle_join(chat_id INTEGER, handle_id INTEGER);
        INSERT INTO handle(ROWID, id, service) VALUES
            (1, '+15551234567', 'iMessage'),
            (2, 'bob@example.com', 'iMessage'),
            (3, 'carol@example.com', 'SMS');
        INSERT INTO chat(ROWID, guid, display_name, chat_identifier, style) VALUES
            (1, 'iMessage;-;+15551234567', 'Alice', '+15551234567', 45),
            (2, 'iMessage;-;bob@example.com', 'Bob', 'bob@example.com', 45),
            (3, 'iMessage;+;group-1', 'Project', 'group-1', 43);
        INSERT INTO chat_handle_join(chat_id, handle_id) VALUES
            (1, 1),
            (2, 2),
            (3, 1),
            (3, 3);
        INSERT INTO message(ROWID, guid, text, date) VALUES
            (1, 'guid-alice-old', 'old alice', 100),
            (2, 'guid-alice-new', 'new alice', 300),
            (3, 'guid-bob', 'bob hello', 500),
            (4, 'guid-group-old', 'group old', 9000),
            (5, 'guid-group-new', 'group new', 9500);
        INSERT INTO chat_message_join(chat_id, message_id) VALUES
            (1, 1),
            (1, 2),
            (2, 3),
            (3, 4),
            (3, 5);
        """
    )
}

/// Creates the minimal outgoing-evidence schema used by confirmation tests.
private func createOutgoingFixture(at path: String) throws {
    let handle = try openChatHistoryFixture(at: path)
    defer { sqlite3_close(handle) }
    try execChatHistoryFixture(
        handle,
        """
        CREATE TABLE message(ROWID INTEGER PRIMARY KEY, handle_id INTEGER, is_from_me INTEGER, date INTEGER);
        CREATE TABLE handle(ROWID INTEGER PRIMARY KEY, id TEXT);
        INSERT INTO handle(ROWID, id) VALUES
            (1, '+15551234567'),
            (2, 'bob@example.com');
        """
    )
}

/// Inserts outgoing-evidence rows with raw Mac-epoch ticks at either scale. handle:
/// Open fixture handle.
private func insertOutgoingFixtureRows(
    _ handle: OpaquePointer?,
    _ rows: [(rowID: Int64, handleID: Int64, isFromMe: Bool, macEpoch: Int64)]
) throws {
    let values = rows
        .map { "(\($0.rowID), \($0.handleID), \($0.isFromMe ? 1 : 0), \($0.macEpoch))" }
        .joined(separator: ",")
    try execChatHistoryFixture(handle, "INSERT INTO message(ROWID, handle_id, is_from_me, date) VALUES \(values);")
}

@Suite("Messages Chat History Source")
struct MessagesChatHistorySourceTests {
    @Test
    func `Only one-to-one chats contribute handles`() throws {
        let paths = makeChatHistoryPaths()
        defer { try? FileManager.default.removeItem(at: paths.base) }
        try seedChatHistoryFixture(at: paths.database)
        let handle = try openChatHistoryFixture(at: paths.database)
        defer { sqlite3_close(handle) }

        let stats = try MessagesDatabaseIO.recentDirectHandleStats(handle: handle, limit: 10)

        #expect(stats.map(\.handle) == ["bob@example.com", "+15551234567"])
        #expect(!stats.map(\.handle).contains("carol@example.com"))
        // Alice's group chat holds the newest messages; only her direct messages
        // may shape her aggregate, so the group must not lift her count or date.
        let alice = try #require(stats.first { $0.handle == "+15551234567" })
        #expect(alice.messageCount == 2)
        #expect(alice.lastMessageAt == TemporalFilter.date(fromMacEpoch: 300))
    }

    @Test
    func `Ordering is newest first and service labels are carried`() throws {
        let paths = makeChatHistoryPaths()
        defer { try? FileManager.default.removeItem(at: paths.base) }
        try seedChatHistoryFixture(at: paths.database)
        let handle = try openChatHistoryFixture(at: paths.database)
        defer { sqlite3_close(handle) }

        let stats = try MessagesDatabaseIO.recentDirectHandleStats(handle: handle, limit: 10)

        let newest = try #require(stats.first)
        let second = try #require(stats.dropFirst().first)
        #expect(newest.handle == "bob@example.com")
        #expect(newest.service == "iMessage")
        #expect(newest.lastMessageAt == TemporalFilter.date(fromMacEpoch: 500))
        #expect(newest.messageCount == 1)
        #expect(second.handle == "+15551234567")
        #expect(second.service == "iMessage")
        #expect(second.lastMessageAt == TemporalFilter.date(fromMacEpoch: 300))
        #expect(second.messageCount == 2)
    }

    @Test
    func `Limit returns only the most recent handles`() throws {
        let paths = makeChatHistoryPaths()
        defer { try? FileManager.default.removeItem(at: paths.base) }
        try seedChatHistoryFixture(at: paths.database)
        let handle = try openChatHistoryFixture(at: paths.database)
        defer { sqlite3_close(handle) }

        let limited = try MessagesDatabaseIO.recentDirectHandleStats(handle: handle, limit: 1)

        #expect(limited.map(\.handle) == ["bob@example.com"])
        #expect(limited.first?.messageCount == 1)
    }

    @Test
    func `Source snapshots the database and returns the same aggregates`() async throws {
        let paths = makeChatHistoryPaths()
        defer { try? FileManager.default.removeItem(at: paths.base) }
        try seedChatHistoryFixture(at: paths.database)

        let source = MessagesChatHistorySource(chatDatabasePath: paths.database)
        let stats = try await source.recentDirectHandleStats(limit: 10)

        #expect(stats.map(\.handle) == ["bob@example.com", "+15551234567"])
        #expect(stats.first?.messageCount == 1)
        #expect(stats.dropFirst().first?.messageCount == 2)
        #expect(!stats.map(\.handle).contains("carol@example.com"))
    }

    @Test
    func `Missing database surfaces databaseUnavailable`() async throws {
        let paths = makeChatHistoryPaths()
        defer { try? FileManager.default.removeItem(at: paths.base) }
        let source = MessagesChatHistorySource(chatDatabasePath: paths.database)

        do {
            _ = try await source.recentDirectHandleStats(limit: 10)
            Issue.record("Expected databaseUnavailable for an absent chat database")
        } catch let error as MessagesIndexError {
            guard case .databaseUnavailable = error else {
                Issue.record("Expected databaseUnavailable, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected MessagesIndexError, got \(error)")
        }
    }

    @Test
    func `recentOutgoingHandles filters direction and the since bound`() throws {
        let paths = makeChatHistoryPaths()
        defer { try? FileManager.default.removeItem(at: paths.base) }
        try createOutgoingFixture(at: paths.database)
        let handle = try openChatHistoryFixture(at: paths.database)
        defer { sqlite3_close(handle) }
        let now = Date()
        let nowTick = Int64(TemporalFilter.macEpochValue(for: now))
        try insertOutgoingFixtureRows(handle, [
            (1, 1, true, nowTick),
            // Incoming rows are never evidence of a send, and this one is newer
            // than the outgoing row so a leaked direction would top the result.
            (2, 1, false, nowTick + 1),
            // A stale outgoing row proves the since bound is applied, not just
            // the handle filter.
            (3, 2, true, nowTick - 3600)
        ])

        let rows = try MessagesDatabaseIO.recentOutgoingHandles(
            handle: handle,
            since: now.addingTimeInterval(-60),
            limit: 20
        )

        #expect(rows.count == 1)
        #expect(rows.first?.handle == "+15551234567")
        #expect(rows.first?.sentAt == TemporalFilter.date(fromMacEpoch: nowTick))
    }

    @Test
    func `recentOutgoingHandles orders newest first and honors the limit`() throws {
        let paths = makeChatHistoryPaths()
        defer { try? FileManager.default.removeItem(at: paths.base) }
        try createOutgoingFixture(at: paths.database)
        let handle = try openChatHistoryFixture(at: paths.database)
        defer { sqlite3_close(handle) }
        let now = Date()
        let nowTick = Int64(TemporalFilter.macEpochValue(for: now))
        try insertOutgoingFixtureRows(handle, [
            (1, 1, true, nowTick - 300),
            (2, 2, true, nowTick - 200),
            (3, 1, true, nowTick - 100)
        ])

        let rows = try MessagesDatabaseIO.recentOutgoingHandles(
            handle: handle,
            since: now.addingTimeInterval(-3600),
            limit: 2
        )

        #expect(rows.map(\.handle) == ["+15551234567", "bob@example.com"])
        #expect(rows.first?.sentAt == TemporalFilter.date(fromMacEpoch: nowTick - 100))
    }

    @Test
    func `recentOutgoingHandles filters nanosecond-scale dates through the seconds expression`() throws {
        let paths = makeChatHistoryPaths()
        defer { try? FileManager.default.removeItem(at: paths.base) }
        try createOutgoingFixture(at: paths.database)
        let handle = try openChatHistoryFixture(at: paths.database)
        defer { sqlite3_close(handle) }
        let now = Date()
        let nowNanos = Int64(TemporalFilter.macEpochNanosValue(for: now))
        try insertOutgoingFixtureRows(handle, [
            // The stale row shares the recipient but sits an hour before the
            // window; its raw nanoseconds dwarf any seconds bound, so a raw
            // `m.date >= ?` comparison would wrongly return it.
            (1, 1, true, nowNanos - 3600 * 1_000_000_000),
            // The in-window row must survive the normalized comparison.
            (2, 1, true, nowNanos - 1_000_000_000)
        ])

        let rows = try MessagesDatabaseIO.recentOutgoingHandles(
            handle: handle,
            since: now.addingTimeInterval(-60),
            limit: 20
        )

        #expect(rows.count == 1)
        #expect(rows.first?.handle == "+15551234567")
        #expect(rows.first?.sentAt == TemporalFilter.date(fromMacEpoch: nowNanos - 1_000_000_000))
    }

    @Test
    func `recentOutgoingHandles returns empty for a non-positive limit`() throws {
        let paths = makeChatHistoryPaths()
        defer { try? FileManager.default.removeItem(at: paths.base) }
        try createOutgoingFixture(at: paths.database)
        let handle = try openChatHistoryFixture(at: paths.database)
        defer { sqlite3_close(handle) }

        let zeroLimit = try MessagesDatabaseIO.recentOutgoingHandles(handle: handle, since: Date(), limit: 0)

        #expect(zeroLimit.isEmpty)
    }

    @Test
    func `recentOutgoingHandles surfaces a missing schema as databaseUnavailable`() throws {
        let paths = makeChatHistoryPaths()
        defer { try? FileManager.default.removeItem(at: paths.base) }
        // An empty database has no `message`/`handle` tables, so the statement
        // cannot prepare and the read must fail loudly rather than report that
        // no outgoing messages exist.
        let handle = try openChatHistoryFixture(at: paths.database)
        defer { sqlite3_close(handle) }

        do {
            _ = try MessagesDatabaseIO.recentOutgoingHandles(handle: handle, since: Date(), limit: 10)
            Issue.record("Expected databaseUnavailable for a missing outgoing schema")
        } catch let error as MessagesIndexError {
            guard case .databaseUnavailable = error else {
                Issue.record("Expected databaseUnavailable, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected MessagesIndexError, got \(error)")
        }
    }

    @Test
    func `Send confirmation matches an outgoing row by handle key`() async throws {
        let paths = makeChatHistoryPaths()
        defer { try? FileManager.default.removeItem(at: paths.base) }
        try createOutgoingFixture(at: paths.database)
        let handle = try openChatHistoryFixture(at: paths.database)
        let now = Date()
        try insertOutgoingFixtureRows(handle, [(1, 1, true, Int64(TemporalFilter.macEpochValue(for: now)))])
        // Close before confirming so the confirmation reads the committed file,
        // not a connection the fixture still holds open.
        sqlite3_close(handle)

        let confirmed = await MessagesSendConfirmation.confirm(
            chatDatabasePath: paths.database,
            recipient: "+1 (555) 123-4567",
            attempts: 1,
            intervalSeconds: 0.01
        )

        #expect(confirmed == true)
    }

    @Test
    func `Send confirmation matches an in-window nanosecond-scale outgoing row`() async throws {
        let paths = makeChatHistoryPaths()
        defer { try? FileManager.default.removeItem(at: paths.base) }
        try createOutgoingFixture(at: paths.database)
        let handle = try openChatHistoryFixture(at: paths.database)
        let now = Date()
        let freshNanos = Int64(TemporalFilter.macEpochNanosValue(for: now))
        try insertOutgoingFixtureRows(handle, [(1, 1, true, freshNanos)])
        sqlite3_close(handle)

        let confirmed = await MessagesSendConfirmation.confirm(
            chatDatabasePath: paths.database,
            recipient: "+1 (555) 123-4567",
            attempts: 1,
            intervalSeconds: 0.01
        )

        #expect(confirmed == true)
    }

    @Test
    func `Send confirmation reports false when no matching outgoing row exists`() async throws {
        let paths = makeChatHistoryPaths()
        defer { try? FileManager.default.removeItem(at: paths.base) }
        try createOutgoingFixture(at: paths.database)
        let handle = try openChatHistoryFixture(at: paths.database)
        let now = Date()
        try insertOutgoingFixtureRows(handle, [
            // Same handle, but outside the confirmation lookback window.
            (1, 1, true, Int64(TemporalFilter.macEpochValue(for: now.addingTimeInterval(-3600)))),
            // Inside the window, but addressed to someone else.
            (2, 2, true, Int64(TemporalFilter.macEpochValue(for: now)))
        ])
        sqlite3_close(handle)

        // Two attempts exercise the retry interval before the false verdict.
        let confirmed = await MessagesSendConfirmation.confirm(
            chatDatabasePath: paths.database,
            recipient: "+15551234567",
            attempts: 2,
            intervalSeconds: 0.01
        )

        #expect(confirmed == false)
    }

    @Test
    func `Send confirmation ignores a stale nanosecond-scale outgoing row`() async throws {
        let paths = makeChatHistoryPaths()
        defer { try? FileManager.default.removeItem(at: paths.base) }
        try createOutgoingFixture(at: paths.database)
        let handle = try openChatHistoryFixture(at: paths.database)
        let staleNanos = Int64(TemporalFilter.macEpochNanosValue(for: Date().addingTimeInterval(-3600)))
        // Same handle as the recipient, but an hour before the lookback window.
        // Its raw nanoseconds exceed any seconds bound, so only the normalized
        // comparison keeps this stale row from reporting a false delivery.
        try insertOutgoingFixtureRows(handle, [(1, 1, true, staleNanos)])
        sqlite3_close(handle)

        let confirmed = await MessagesSendConfirmation.confirm(
            chatDatabasePath: paths.database,
            recipient: "+15551234567",
            attempts: 2,
            intervalSeconds: 0.01
        )

        #expect(confirmed == false)
    }

    @Test
    func `Send confirmation reports unknown when the database is unreadable`() async {
        let paths = makeChatHistoryPaths()
        defer { try? FileManager.default.removeItem(at: paths.base) }

        let confirmed = await MessagesSendConfirmation.confirm(
            chatDatabasePath: paths.database,
            recipient: "+15551234567",
            attempts: 2,
            intervalSeconds: 0.01
        )

        #expect(confirmed == nil)
    }

    @Test
    func `Send confirmation reports unknown when the snapshot cannot answer`() async throws {
        let paths = makeChatHistoryPaths()
        defer { try? FileManager.default.removeItem(at: paths.base) }
        // The file snapshots and opens cleanly, but the outgoing statement
        // cannot prepare, so confirmation must report unknown rather than false.
        // An unrelated table forces a real database file with a written header.
        let handle = try openChatHistoryFixture(at: paths.database)
        try execChatHistoryFixture(handle, "CREATE TABLE unrelated(ROWID INTEGER PRIMARY KEY);")
        sqlite3_close(handle)

        let confirmed = await MessagesSendConfirmation.confirm(
            chatDatabasePath: paths.database,
            recipient: "+15551234567",
            attempts: 1,
            intervalSeconds: 0.01
        )

        #expect(confirmed == nil)
    }
}

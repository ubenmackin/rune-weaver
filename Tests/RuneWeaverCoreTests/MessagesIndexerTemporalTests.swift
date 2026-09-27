// Rune Weaver Core Tests — Messages temporal window tests.
//
// Purpose: pin the `since` / `until` window for `messages.search` and
// `messages.read` so day slices, edge instants, and undated rows behave like
// every other dated search surface.
// Scope: args decoding with blank-as-omitted, tool-to-gateway date
// forwarding, SQL bound filtering with inclusive-since and exclusive-until
// edges, NULL-date exclusion when bounded, ordering plus limit preservation,
// and fail-closed rejection for malformed or inverted bounds.
// Architectural role: guards the Messages half of the shared temporal
// contract owned by TemporalFilter; SQL stays the single filter so
// unbounded queries remain byte-identical to the legacy shape.

import Foundation
import os
@testable import RuneWeaverCore
@testable import RuneWeaverTools
import Testing

#if canImport(SQLite3)
    import SQLite3
#endif

/// Failure raised when a temporal fixture statement cannot run.
private enum TemporalMessagesFixtureError: Error {
    case failed(String)
}

/// Creates isolated filesystem paths for one temporal test.
private func makeTemporalMessagesPaths() -> (base: URL, database: String) {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("runeweaver-messages-temporal-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return (base, base.appendingPathComponent("chat.db").path)
}

/// Opens or creates a temporal fixture database.
private func openTemporalFixture(at path: String) throws -> OpaquePointer {
    #if canImport(SQLite3)
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let handle else {
            if let handle {
                sqlite3_close(handle)
            }
            throw TemporalMessagesFixtureError.failed("Could not open temporal fixture database")
        }
        return handle
    #else
        throw TemporalMessagesFixtureError.failed("SQLite3 unavailable")
    #endif
}

/// Executes a multi-statement SQL string against a temporal fixture.
private func execTemporalFixture(_ handle: OpaquePointer?, _ sql: String) throws {
    #if canImport(SQLite3)
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &message) == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(message)
            throw TemporalMessagesFixtureError.failed(detail)
        }
    #endif
}

/// Creates the Messages tables plus one handle and one chat for temporal tests.
private func createTemporalFixture(at path: String) throws {
    let handle = try openTemporalFixture(at: path)
    defer { sqlite3_close(handle) }
    try execTemporalFixture(
        handle,
        """
        CREATE TABLE message(
            ROWID INTEGER PRIMARY KEY,
            guid TEXT,
            text TEXT,
            attributedBody BLOB,
            handle_id INTEGER,
            date INTEGER,
            is_from_me INTEGER,
            associated_message_type INTEGER,
            associated_message_guid TEXT,
            thread_originator_guid TEXT,
            cache_has_attachments INTEGER
        );
        CREATE TABLE handle(ROWID INTEGER PRIMARY KEY, id TEXT, service TEXT);
        CREATE TABLE chat(ROWID INTEGER PRIMARY KEY, guid TEXT, display_name TEXT, chat_identifier TEXT, style INTEGER);
        CREATE TABLE chat_message_join(chat_id INTEGER, message_id INTEGER);
        CREATE TABLE attachment(ROWID INTEGER PRIMARY KEY, filename TEXT, transfer_name TEXT, mime_type TEXT, total_bytes INTEGER);
        CREATE TABLE message_attachment_join(message_id INTEGER, attachment_id INTEGER);
        INSERT INTO handle(ROWID, id, service) VALUES(1, '+15551234567', 'iMessage');
        INSERT INTO chat(ROWID, guid, display_name, chat_identifier, style)
            VALUES(1, 'iMessage;-;+15551234567', 'Alice', '+15551234567', 45);
        """
    )
}

/// Binds optional text for temporal fixtures, mapping nil to NULL.
private func bindTemporalFixtureText(_ statement: OpaquePointer?, index: Int32, value: String?) {
    #if canImport(SQLite3)
        if let value {
            _ = value.withCString {
                sqlite3_bind_text(statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
        } else {
            sqlite3_bind_null(statement, index)
        }
    #endif
}

/// Inserts one temporal message row, allowing a nil date for undated coverage.
private func insertTemporalMessage(
    into handle: OpaquePointer?,
    rowID: Int64,
    guid: String,
    text: String?,
    date: Int64?,
    isFromMe: Bool = false
) throws {
    #if canImport(SQLite3)
        let sql = """
        INSERT INTO message(ROWID, guid, text, attributedBody, handle_id, date, is_from_me, associated_message_type, thread_originator_guid)
        VALUES(?, ?, ?, NULL, 1, ?, ?, NULL, NULL);
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw TemporalMessagesFixtureError.failed("Could not prepare temporal message insert")
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, rowID)
        bindTemporalFixtureText(statement, index: 2, value: guid)
        bindTemporalFixtureText(statement, index: 3, value: text)
        if let date {
            sqlite3_bind_int64(statement, 4, date)
        } else {
            sqlite3_bind_null(statement, 4)
        }
        sqlite3_bind_int(statement, 5, isFromMe ? 1 : 0)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw TemporalMessagesFixtureError.failed("Could not insert temporal message")
        }
    #endif
}

/// Links one temporal message to the fixture chat.
private func joinTemporalChat(into handle: OpaquePointer?, messageID: Int64) throws {
    try execTemporalFixture(handle, "INSERT INTO chat_message_join(chat_id, message_id) VALUES(1, \(messageID));")
}

/// Converts a resolved bound to the seconds-scale Mac-epoch tick used by fixtures.
///
/// Fixtures default to seconds since 2001-01-01; the reader normalizes both
/// scales through `TemporalFilter`, so nanosecond rows share the same window.
private func temporalMacEpochTick(for date: Date) -> Int64 {
    Int64(TemporalFilter.macEpochValue(for: date))
}

/// Converts a resolved bound to the nanoseconds-scale Mac-epoch tick stored
/// by current Messages databases.
private func temporalMacEpochNanosTick(for date: Date) -> Int64 {
    temporalMacEpochTick(for: date) * 1_000_000_000
}

/// Recording gateway proving tools forward resolved dates instead of raw strings.
private final class TemporalRecordingMessagesGateway: MessagesGateway, Sendable {
    private struct State: Sendable {
        var searchSince: Date?
        var searchUntil: Date?
        var readSince: Date?
        var readUntil: Date?
        var searchResults: [MessagesMessageItem] = []
        var readResults: [MessagesMessageItem] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var searchSince: Date? {
        state.withLock { $0.searchSince }
    }

    var searchUntil: Date? {
        state.withLock { $0.searchUntil }
    }

    var readSince: Date? {
        state.withLock { $0.readSince }
    }

    var readUntil: Date? {
        state.withLock { $0.readUntil }
    }

    var searchResults: [MessagesMessageItem] {
        get { state.withLock { $0.searchResults } }
        set { state.withLock { $0.searchResults = newValue } }
    }

    var readResults: [MessagesMessageItem] {
        get { state.withLock { $0.readResults } }
        set { state.withLock { $0.readResults = newValue } }
    }

    func search(query _: String?, recipient _: String?, limit _: Int, since: Date?, until: Date?) async throws -> [MessagesMessageItem] {
        state.withLock { s in
            s.searchSince = since
            s.searchUntil = until
            return s.searchResults
        }
    }

    func read(chatID _: String?, recipient _: String?, limit _: Int, since: Date?, until: Date?) async throws -> [MessagesMessageItem] {
        state.withLock { s in
            s.readSince = since
            s.readUntil = until
            return s.readResults
        }
    }

    func send(recipient: String, text: String) async throws -> MessagesSendResult {
        MessagesSendResult(success: true, recipient: recipient, text: text)
    }
}

@Suite("Messages Temporal Window")
struct MessagesIndexerTemporalTests {
    @Test
    func `Search args decode since and until with blank as omitted`() throws {
        let args = try JSONDecoder().decode(
            MessagesSearchArgs.self,
            from: Data(#"{"query":"hi","since":"2026-09-26","until":"2026-09-27"}"#.utf8)
        )
        #expect(args.since == "2026-09-26")
        #expect(args.until == "2026-09-27")

        let blank = try JSONDecoder().decode(
            MessagesSearchArgs.self,
            from: Data(#"{"query":"hi","since":"   ","until":""}"#.utf8)
        )
        #expect(blank.since == nil)
        #expect(blank.until == nil)

        let omitted = try JSONDecoder().decode(MessagesSearchArgs.self, from: Data(#"{}"#.utf8))
        #expect(omitted.since == nil)
        #expect(omitted.until == nil)
        #expect(omitted.limit == MessagesSearchArgs.defaultLimit)
    }

    @Test
    func `Read args decode since and until with blank as omitted`() throws {
        let args = try JSONDecoder().decode(
            MessagesReadArgs.self,
            from: Data(#"{"chatId":"chat123","since":"2026-07-01","until":"2026-08-01"}"#.utf8)
        )
        #expect(args.chatID == "chat123")
        #expect(args.since == "2026-07-01")
        #expect(args.until == "2026-08-01")

        let blank = try JSONDecoder().decode(
            MessagesReadArgs.self,
            from: Data(#"{"chatId":"chat123","since":"","until":"  "}"#.utf8)
        )
        #expect(blank.since == nil)
        #expect(blank.until == nil)
    }

    @Test
    func `Search schema advertises since and until`() {
        let tool = MessagesSearchTool(gateway: TemporalRecordingMessagesGateway())
        #expect(tool.inputSchema.rawValue.contains("\"since\""))
        #expect(tool.inputSchema.rawValue.contains("\"until\""))
        #expect(tool.inputSchema.rawValue.contains("YYYY-MM-DD"))
        #expect(tool.inputSchema.rawValue.contains("ISO8601"))
    }

    @Test
    func `Read schema advertises since and until`() {
        let tool = MessagesReadTool(gateway: TemporalRecordingMessagesGateway())
        #expect(tool.inputSchema.rawValue.contains("\"since\""))
        #expect(tool.inputSchema.rawValue.contains("\"until\""))
        #expect(tool.inputSchema.rawValue.contains("YYYY-MM-DD"))
        #expect(tool.inputSchema.rawValue.contains("ISO8601"))
    }

    @Test
    func `Search tool forwards resolved dates to gateway`() async throws {
        let gateway = TemporalRecordingMessagesGateway()
        let tool = MessagesSearchTool(gateway: gateway)
        let output = try await tool.execute(
            input: ToolInput(toolName: "messages.search", argumentsJSON: #"{"query":"*","since":"2026-09-26","until":"2026-09-27"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == false)
        let expected = try TemporalFilter.parse(since: "2026-09-26", until: "2026-09-27")
        #expect(gateway.searchSince == expected.since)
        #expect(gateway.searchUntil == expected.until)
    }

    @Test
    func `Read tool forwards resolved dates to gateway`() async throws {
        let gateway = TemporalRecordingMessagesGateway()
        let tool = MessagesReadTool(gateway: gateway)
        let output = try await tool.execute(
            input: ToolInput(toolName: "messages.read", argumentsJSON: #"{"chatId":"chat123","since":"2026-07-01","until":"2026-08-01"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == false)
        let expected = try TemporalFilter.parse(since: "2026-07-01", until: "2026-08-01")
        #expect(gateway.readSince == expected.since)
        #expect(gateway.readUntil == expected.until)
    }

    @Test
    func `Blank bounds forward as unbounded`() async throws {
        let gateway = TemporalRecordingMessagesGateway()
        let search = MessagesSearchTool(gateway: gateway)
        let searchOutput = try await search.execute(
            input: ToolInput(toolName: "messages.search", argumentsJSON: #"{"query":"*","since":"  ","until":""}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(searchOutput.isError == false)
        #expect(gateway.searchSince == nil)
        #expect(gateway.searchUntil == nil)

        let read = MessagesReadTool(gateway: gateway)
        let readOutput = try await read.execute(
            input: ToolInput(toolName: "messages.read", argumentsJSON: #"{"chatId":"chat123","since":"","until":"   "}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(readOutput.isError == false)
        #expect(gateway.readSince == nil)
        #expect(gateway.readUntil == nil)
    }

    @Test
    func `Malformed bounds fail naming the field`() async throws {
        let search = MessagesSearchTool(gateway: TemporalRecordingMessagesGateway())
        let badSince = try await search.execute(
            input: ToolInput(toolName: "messages.search", argumentsJSON: #"{"query":"*","since":"not-a-date"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(badSince.isError == true)
        #expect(badSince.content.contains("since"))

        let read = MessagesReadTool(gateway: TemporalRecordingMessagesGateway())
        let badUntil = try await read.execute(
            input: ToolInput(toolName: "messages.read", argumentsJSON: #"{"chatId":"chat123","until":"yesterday"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(badUntil.isError == true)
        #expect(badUntil.content.contains("until"))
    }

    @Test
    func `Inverted range rejects at the tool boundary`() async throws {
        let search = MessagesSearchTool(gateway: TemporalRecordingMessagesGateway())
        let searchOutput = try await search.execute(
            input: ToolInput(toolName: "messages.search", argumentsJSON: #"{"query":"*","since":"2026-09-27","until":"2026-09-26"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(searchOutput.isError == true)
        #expect(searchOutput.content.contains("since") && searchOutput.content.contains("until"))

        let read = MessagesReadTool(gateway: TemporalRecordingMessagesGateway())
        let readOutput = try await read.execute(
            input: ToolInput(toolName: "messages.read", argumentsJSON: #"{"chatId":"chat123","since":"2026-08-01","until":"2026-07-01"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(readOutput.isError == true)
        #expect(readOutput.content.contains("since") && readOutput.content.contains("until"))
    }

    @Test
    func `Search window returns yesterday only with inclusive since and exclusive until`() throws {
        let paths = makeTemporalMessagesPaths()
        defer { try? FileManager.default.removeItem(at: paths.base) }
        try createTemporalFixture(at: paths.database)
        let range = try TemporalFilter.parse(since: "2026-09-26", until: "2026-09-27")
        let lower = try #require(range.since)
        let upper = try #require(range.until)

        let handle = try openTemporalFixture(at: paths.database)
        // Day before, window start exactly, midday, window end exactly, day after.
        let stamps: [(Int64, String, String)] = [
            (1, "guid-before", "before"),
            (2, "guid-start", "window start"),
            (3, "guid-mid", "window mid"),
            (4, "guid-end", "window end"),
            (5, "guid-after", "after")
        ]
        let dates: [Int64] = [
            temporalMacEpochTick(for: lower.addingTimeInterval(-43200)),
            temporalMacEpochTick(for: lower),
            temporalMacEpochTick(for: lower.addingTimeInterval(43200)),
            temporalMacEpochTick(for: upper),
            temporalMacEpochTick(for: upper.addingTimeInterval(43200))
        ]
        for (index, entry) in stamps.enumerated() {
            try insertTemporalMessage(into: handle, rowID: entry.0, guid: entry.1, text: entry.2, date: dates[index])
            try joinTemporalChat(into: handle, messageID: entry.0)
        }
        let rows = try MessagesDatabaseIO.searchMessages(handle: handle, query: "window", limit: 20, since: lower, until: upper)
        sqlite3_close(handle)

        // Inclusive lower edge stays, exclusive upper edge leaves, neighbors stay out.
        #expect(rows.count == 2)
        #expect(rows.map(\.guid).contains("guid-start"))
        #expect(rows.map(\.guid).contains("guid-mid"))
        #expect(!rows.map(\.guid).contains("guid-end"))
        // Newest first: midday outranks midnight.
        #expect(rows.first?.guid == "guid-mid")
        #expect(rows.last?.guid == "guid-start")
    }

    @Test
    func `Nanoscale rows honor the same window as seconds rows`() throws {
        let paths = makeTemporalMessagesPaths()
        defer { try? FileManager.default.removeItem(at: paths.base) }
        try createTemporalFixture(at: paths.database)
        let range = try TemporalFilter.parse(since: "2026-09-26", until: "2026-09-27")
        let lower = try #require(range.since)
        let upper = try #require(range.until)

        let handle = try openTemporalFixture(at: paths.database)
        // One window row per scale, plus out-of-window nanos rows on each side.
        try insertTemporalMessage(into: handle, rowID: 1, guid: "guid-seconds", text: "window ping", date: temporalMacEpochTick(for: lower.addingTimeInterval(3600)))
        try joinTemporalChat(into: handle, messageID: 1)
        try insertTemporalMessage(into: handle, rowID: 2, guid: "guid-nanos", text: "window ping", date: temporalMacEpochNanosTick(for: lower.addingTimeInterval(7200)))
        try joinTemporalChat(into: handle, messageID: 2)
        try insertTemporalMessage(into: handle, rowID: 3, guid: "guid-nanos-before", text: "window ping", date: temporalMacEpochNanosTick(for: lower.addingTimeInterval(-3600)))
        try joinTemporalChat(into: handle, messageID: 3)
        try insertTemporalMessage(into: handle, rowID: 4, guid: "guid-nanos-after", text: "window ping", date: temporalMacEpochNanosTick(for: upper.addingTimeInterval(3600)))
        try joinTemporalChat(into: handle, messageID: 4)
        let rows = try MessagesDatabaseIO.searchMessages(handle: handle, query: "ping", limit: 20, since: lower, until: upper)
        sqlite3_close(handle)

        // Both scales land inside [since, until): neighbors on either scale stay out.
        #expect(rows.count == 2)
        #expect(rows.map(\.guid).contains("guid-seconds"))
        #expect(rows.map(\.guid).contains("guid-nanos"))
        #expect(!rows.map(\.guid).contains("guid-nanos-before"))
        #expect(!rows.map(\.guid).contains("guid-nanos-after"))
    }

    @Test
    func `Read July window pages the thread slice`() throws {
        let paths = makeTemporalMessagesPaths()
        defer { try? FileManager.default.removeItem(at: paths.base) }
        try createTemporalFixture(at: paths.database)
        let range = try TemporalFilter.parse(since: "2026-07-01", until: "2026-08-01")
        let lower = try #require(range.since)
        let upper = try #require(range.until)

        let handle = try openTemporalFixture(at: paths.database)
        let june = lower.addingTimeInterval(-3600)
        let julyMid = lower.addingTimeInterval(14 * 86400 + 43200)
        let julyEnd = upper.addingTimeInterval(-1)
        let entries: [(Int64, String, String, Date)] = [
            (1, "guid-june", "june message", june),
            (2, "guid-july-start", "july start", lower),
            (3, "guid-july-mid", "july mid", julyMid),
            (4, "guid-july-end", "july end", julyEnd),
            (5, "guid-august", "august message", upper)
        ]
        for entry in entries {
            try insertTemporalMessage(into: handle, rowID: entry.0, guid: entry.1, text: entry.2, date: temporalMacEpochTick(for: entry.3))
            try joinTemporalChat(into: handle, messageID: entry.0)
        }
        let rows = try MessagesDatabaseIO.conversationMessages(handle: handle, chatID: "+15551234567", limit: 20, since: lower, until: upper)
        sqlite3_close(handle)

        #expect(rows.count == 3)
        #expect(rows.map(\.guid).contains("guid-july-start"))
        #expect(rows.map(\.guid).contains("guid-july-mid"))
        #expect(rows.map(\.guid).contains("guid-july-end"))
        #expect(!rows.map(\.guid).contains("guid-june"))
        #expect(!rows.map(\.guid).contains("guid-august"))
        #expect(rows.first?.guid == "guid-july-end")
        #expect(rows.last?.guid == "guid-july-start")
    }

    @Test
    func `Null dates are excluded when bounded and included when unbounded`() throws {
        let paths = makeTemporalMessagesPaths()
        defer { try? FileManager.default.removeItem(at: paths.base) }
        try createTemporalFixture(at: paths.database)
        let range = try TemporalFilter.parse(since: "2026-09-26", until: "2026-09-27")
        let lower = try #require(range.since)
        let upper = try #require(range.until)

        let handle = try openTemporalFixture(at: paths.database)
        try insertTemporalMessage(into: handle, rowID: 1, guid: "guid-dated", text: "dated hello", date: temporalMacEpochTick(for: lower.addingTimeInterval(3600)))
        try joinTemporalChat(into: handle, messageID: 1)
        try insertTemporalMessage(into: handle, rowID: 2, guid: "guid-undated", text: "undated hello", date: nil)
        try joinTemporalChat(into: handle, messageID: 2)

        // Unbounded keeps the undated row alongside the dated one.
        let unbounded = try MessagesDatabaseIO.searchMessages(handle: handle, query: "hello", limit: 20)
        #expect(unbounded.count == 2)

        // Any bound drops the NULL row: SQLite comparisons never match NULL.
        let boundedSince = try MessagesDatabaseIO.searchMessages(handle: handle, query: "hello", limit: 20, since: lower, until: nil)
        #expect(boundedSince.map(\.guid) == ["guid-dated"])
        let boundedWindow = try MessagesDatabaseIO.searchMessages(handle: handle, query: "hello", limit: 20, since: lower, until: upper)
        #expect(boundedWindow.map(\.guid) == ["guid-dated"])
        let boundedRead = try MessagesDatabaseIO.conversationMessages(handle: handle, chatID: "+15551234567", limit: 20, since: lower, until: upper)
        #expect(!boundedRead.map(\.guid).contains("guid-undated"))

        // Lifting the bounds restores the undated row for reads too.
        let unboundedRead = try MessagesDatabaseIO.conversationMessages(handle: handle, chatID: "+15551234567", limit: 20)
        #expect(unboundedRead.count == 2)
        sqlite3_close(handle)
    }

    @Test
    func `Ordering stays newest first and limit is honored`() throws {
        let paths = makeTemporalMessagesPaths()
        defer { try? FileManager.default.removeItem(at: paths.base) }
        try createTemporalFixture(at: paths.database)
        let range = try TemporalFilter.parse(since: "2026-09-01", until: "2026-10-01")
        let lower = try #require(range.since)

        let handle = try openTemporalFixture(at: paths.database)
        for rowID in 1 ... 5 {
            let instant = lower.addingTimeInterval(Double(rowID) * 3600)
            try insertTemporalMessage(into: handle, rowID: Int64(rowID), guid: "guid-order-\(rowID)", text: "order \(rowID)", date: temporalMacEpochTick(for: instant))
            try joinTemporalChat(into: handle, messageID: Int64(rowID))
        }
        let limited = try MessagesDatabaseIO.searchMessages(handle: handle, limit: 2, since: lower)
        #expect(limited.count == 2)
        #expect(limited[0].guid == "guid-order-5")
        #expect(limited[1].guid == "guid-order-4")

        let readLimited = try MessagesDatabaseIO.conversationMessages(handle: handle, chatID: "+15551234567", limit: 3, since: lower)
        #expect(readLimited.count == 3)
        #expect(readLimited.map(\.guid) == ["guid-order-5", "guid-order-4", "guid-order-3"])
        sqlite3_close(handle)
    }

    @Test
    func `Single-sided bounds filter only their side`() throws {
        let paths = makeTemporalMessagesPaths()
        defer { try? FileManager.default.removeItem(at: paths.base) }
        try createTemporalFixture(at: paths.database)
        let lower = try #require(TemporalFilter.parse(since: "2026-09-26", until: nil).since)
        let upper = try #require(TemporalFilter.parse(since: nil, until: "2026-09-27").until)

        let handle = try openTemporalFixture(at: paths.database)
        try insertTemporalMessage(into: handle, rowID: 1, guid: "guid-early", text: "early ping", date: temporalMacEpochTick(for: lower.addingTimeInterval(-3600)))
        try joinTemporalChat(into: handle, messageID: 1)
        try insertTemporalMessage(into: handle, rowID: 2, guid: "guid-late", text: "late ping", date: temporalMacEpochTick(for: upper.addingTimeInterval(-3600)))
        try joinTemporalChat(into: handle, messageID: 2)
        try insertTemporalMessage(into: handle, rowID: 3, guid: "guid-after", text: "after ping", date: temporalMacEpochTick(for: upper.addingTimeInterval(3600)))
        try joinTemporalChat(into: handle, messageID: 3)

        let sinceOnly = try MessagesDatabaseIO.searchMessages(handle: handle, query: "ping", limit: 20, since: lower, until: nil)
        #expect(sinceOnly.map(\.guid).contains("guid-late"))
        #expect(sinceOnly.map(\.guid).contains("guid-after"))
        #expect(!sinceOnly.map(\.guid).contains("guid-early"))

        let untilOnly = try MessagesDatabaseIO.searchMessages(handle: handle, query: "ping", limit: 20, since: nil, until: upper)
        #expect(untilOnly.map(\.guid).contains("guid-early"))
        #expect(untilOnly.map(\.guid).contains("guid-late"))
        #expect(!untilOnly.map(\.guid).contains("guid-after"))
        sqlite3_close(handle)
    }
}

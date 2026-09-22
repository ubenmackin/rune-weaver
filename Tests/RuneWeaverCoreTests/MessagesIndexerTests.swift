// Rune Weaver Core Tests — Apple Messages indexer snapshot, decoding, watermark, and permissions.
//
// Exercises the Messages reader against isolated fixture databases that mimic
// the `chat.db` shape: snapshot isolation, attributed-body decoding, incremental
// ROWID watermarking across fresh indexer instances, tapback interpretation,
// attachment text extraction, and the missing-permission open path. No test
// touches the real `~/Library/Messages` store.

import Foundation
@testable import RuneWeaverCore
import Testing

#if canImport(SQLite3)
    import SQLite3
#endif

/// Error raised when a raw fixture statement cannot run.
private enum MessagesFixtureError: Error {
    /// The statement failed with a SQLite detail string.
    case failed(String)
}

/// Creates isolated filesystem paths for one test.
/// - Returns: Base directory plus the fixture, index, and state paths.
private func makeMessagesPaths() -> (base: URL, database: String, store: String, state: String) {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("runeweaver-messages-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return (
        base,
        base.appendingPathComponent("chat.db").path,
        base.appendingPathComponent("index.db").path,
        base.appendingPathComponent("messages-state.json").path
    )
}

/// Opens or creates a fixture database.
/// - Parameter path: SQLite file path.
/// - Returns: Open handle owned by the caller.
private func openMessagesFixture(at path: String) throws -> OpaquePointer {
    #if canImport(SQLite3)
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let handle else {
            if let handle {
                sqlite3_close(handle)
            }
            throw MessagesFixtureError.failed("Could not open fixture database")
        }
        return handle
    #else
        throw MessagesFixtureError.failed("SQLite3 unavailable")
    #endif
}

/// Executes a multi-statement SQL string against a fixture.
/// - Parameters:
///   - handle: Open fixture handle.
///   - sql: SQL to execute.
private func execMessagesFixture(_ handle: OpaquePointer?, _ sql: String) throws {
    #if canImport(SQLite3)
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &message) == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(message)
            throw MessagesFixtureError.failed(detail)
        }
    #endif
}

/// Creates the standard Messages tables plus one handle and one chat.
/// - Parameter path: Fixture database path.
private func createMessagesFixture(at path: String) throws {
    let handle = try openMessagesFixture(at: path)
    defer { sqlite3_close(handle) }
    try execMessagesFixture(
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

/// Binds optional text, mapping nil to NULL.
/// - Parameters:
///   - statement: Statement being built.
///   - index: Bind index.
///   - value: Text value.
private func bindMessagesFixtureText(_ statement: OpaquePointer?, index: Int32, value: String?) {
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

/// Inserts one message row.
/// - Parameters:
///   - handle: Open fixture handle.
///   - rowID: Message ROWID.
///   - guid: Message GUID.
///   - text: Plain body text.
///   - attributedBody: Serialized body bytes.
///   - date: Mac-epoch tick.
///   - isFromMe: Direction flag.
///   - associatedType: Tapback code.
///   - threadOriginator: Reply target GUID.
private func insertMessagesFixtureMessage(
    into handle: OpaquePointer?,
    rowID: Int64,
    guid: String,
    text: String?,
    attributedBody: Data? = nil,
    date: Int64,
    isFromMe: Bool,
    associatedType: Int? = nil,
    threadOriginator: String? = nil
) throws {
    #if canImport(SQLite3)
        let sql = """
        INSERT INTO message(ROWID, guid, text, attributedBody, handle_id, date, is_from_me, associated_message_type, thread_originator_guid)
        VALUES(?, ?, ?, ?, 1, ?, ?, ?, ?);
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw MessagesFixtureError.failed("Could not prepare message insert")
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, rowID)
        bindMessagesFixtureText(statement, index: 2, value: guid)
        bindMessagesFixtureText(statement, index: 3, value: text)
        if let attributedBody, !attributedBody.isEmpty {
            attributedBody.withUnsafeBytes { buffer in
                _ = sqlite3_bind_blob(
                    statement,
                    4,
                    buffer.baseAddress,
                    Int32(attributedBody.count),
                    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                )
            }
        } else {
            sqlite3_bind_null(statement, 4)
        }
        sqlite3_bind_int64(statement, 5, date)
        sqlite3_bind_int(statement, 6, isFromMe ? 1 : 0)
        if let associatedType {
            sqlite3_bind_int(statement, 7, Int32(associatedType))
        } else {
            sqlite3_bind_null(statement, 7)
        }
        bindMessagesFixtureText(statement, index: 8, value: threadOriginator)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw MessagesFixtureError.failed("Could not insert message")
        }
    #endif
}

/// Links one message to the fixture chat.
/// - Parameters:
///   - handle: Open fixture handle.
///   - chatID: Chat ROWID.
///   - messageID: Message ROWID.
private func joinMessagesFixtureChat(into handle: OpaquePointer?, chatID: Int64, messageID: Int64) throws {
    try execMessagesFixture(handle, "INSERT INTO chat_message_join(chat_id, message_id) VALUES(\(chatID), \(messageID));")
}

/// Builds a legacy typedstream body carrying one string payload.
///
/// The layout mirrors the bytes Messages writes: class metadata followed by an
/// object reference, a class reference, the `0x84` data-block indicator, the `+`
/// string type tag, a length byte, and the UTF-8 payload.
/// - Parameter text: Body text to embed.
/// - Returns: Serialized body blob.
private func typedStreamBody(_ text: String) -> Data {
    var data = Data()
    data.append(contentsOf: Array("streamtyped".utf8))
    data.append(contentsOf: [0x84, 0x84, 0x12])
    data.append(contentsOf: Array("NSAttributedString".utf8))
    data.append(contentsOf: [0x84, 0x19])
    data.append(contentsOf: Array("NSMutableAttributedString".utf8))
    data.append(contentsOf: [0x84, 0x0F])
    data.append(contentsOf: Array("NSMutableString".utf8))
    data.append(contentsOf: [0x84, 0x08])
    data.append(contentsOf: Array("NSString".utf8))
    data.append(contentsOf: [0x01, 0x94, 0x84, 0x01, 0x2B])
    let bytes = Array(text.utf8)
    data.append(UInt8(bytes.count))
    data.append(contentsOf: bytes)
    data.append(0x86)
    return data
}

@Suite("Messages Indexer")
struct MessagesIndexerTests {
    @Test
    func `Snapshot copies the database into an isolated temporary directory`() async throws {
        let paths = makeMessagesPaths()
        defer { try? FileManager.default.removeItem(at: paths.base) }
        try createMessagesFixture(at: paths.database)
        let store = DocIndexStore(dbPath: paths.store)
        let indexer = MessagesIndexer(
            chatDatabasePath: paths.database,
            store: store,
            statePath: paths.state
        )

        let snapshot = try await indexer.snapshotDatabase()
        defer { try? FileManager.default.removeItem(at: snapshot) }
        let copiedPath = snapshot.appendingPathComponent("chat.db").path
        #expect(FileManager.default.fileExists(atPath: copiedPath))
        #expect(copiedPath != paths.database)
        let original = try Data(contentsOf: URL(fileURLWithPath: paths.database))
        let copied = try Data(contentsOf: URL(fileURLWithPath: copiedPath))
        #expect(original == copied)
    }

    @Test
    func `Message text is indexed with chat and handle provenance`() async throws {
        let paths = makeMessagesPaths()
        defer { try? FileManager.default.removeItem(at: paths.base) }
        try createMessagesFixture(at: paths.database)
        let handle = try openMessagesFixture(at: paths.database)
        try insertMessagesFixtureMessage(
            into: handle,
            rowID: 1,
            guid: "guid-plain",
            text: "Hello from Alice",
            date: 700_000_000_000_000_000,
            isFromMe: false
        )
        try joinMessagesFixtureChat(into: handle, chatID: 1, messageID: 1)
        sqlite3_close(handle)

        let store = DocIndexStore(dbPath: paths.store)
        let indexer = MessagesIndexer(
            chatDatabasePath: paths.database,
            store: store,
            statePath: paths.state
        )
        let result = try await indexer.indexNewMessages()
        #expect(result.scanned == 1)
        #expect(result.indexed == 1)
        #expect(result.lastRowID == 1)
        #expect(result.hasMore == false)

        let document = try await store.document(source: .messages, externalID: "guid-plain")
        #expect(document?.metadata["chatID"] == "1")
        #expect(document?.metadata["handle"] == "+15551234567")
        #expect(document?.metadata["isFromMe"] == "false")
        #expect(document?.metadata["date"] == "700000000000000000")
        #expect(document?.mailbox == "1")
        #expect(document?.extractStatus == .extracted)

        let hits = try await store.searchKeyword(query: "Alice", limit: 5)
        #expect(hits.contains { $0.text.contains("Hello from Alice") })
    }

    @Test
    func `Attributed body decoding extracts typedstream payloads`() {
        #expect(AttributedBodyTextDecoder.text(from: typedStreamBody("Tahoe body text")) == "Tahoe body text")
        #expect(AttributedBodyTextDecoder.text(from: Data([0x00, 0x01, 0x02])) == nil)
        #expect(AttributedBodyTextDecoder.text(from: Data()) == nil)
    }

    @Test
    func `Attributed body message is indexed when the text column is null`() async throws {
        let paths = makeMessagesPaths()
        defer { try? FileManager.default.removeItem(at: paths.base) }
        try createMessagesFixture(at: paths.database)
        let handle = try openMessagesFixture(at: paths.database)
        try insertMessagesFixtureMessage(
            into: handle,
            rowID: 1,
            guid: "guid-body",
            text: nil,
            attributedBody: typedStreamBody("Tahoe body text"),
            date: 700_000_000_000_001_000,
            isFromMe: false
        )
        try joinMessagesFixtureChat(into: handle, chatID: 1, messageID: 1)
        sqlite3_close(handle)

        let store = DocIndexStore(dbPath: paths.store)
        let indexer = MessagesIndexer(
            chatDatabasePath: paths.database,
            store: store,
            statePath: paths.state
        )
        let result = try await indexer.indexNewMessages()
        #expect(result.indexed == 1)

        let document = try await store.document(source: .messages, externalID: "guid-body")
        #expect(document?.extractStatus == .extracted)
        let hits = try await store.searchKeyword(query: "Tahoe", limit: 5)
        #expect(hits.contains { $0.text.contains("Tahoe body text") })
    }

    @Test
    func `Tapback rows synthesize searchable reaction text`() async throws {
        let paths = makeMessagesPaths()
        defer { try? FileManager.default.removeItem(at: paths.base) }
        try createMessagesFixture(at: paths.database)
        let handle = try openMessagesFixture(at: paths.database)
        try insertMessagesFixtureMessage(
            into: handle,
            rowID: 1,
            guid: "guid-tapback",
            text: nil,
            date: 700_000_000_000_002_000,
            isFromMe: false,
            associatedType: 2001
        )
        try joinMessagesFixtureChat(into: handle, chatID: 1, messageID: 1)
        sqlite3_close(handle)

        let store = DocIndexStore(dbPath: paths.store)
        let indexer = MessagesIndexer(
            chatDatabasePath: paths.database,
            store: store,
            statePath: paths.state
        )
        let result = try await indexer.indexNewMessages()
        #expect(result.indexed == 1)

        let document = try await store.document(source: .messages, externalID: "guid-tapback")
        #expect(document?.metadata["associatedMessageType"] == "2001")
        let hits = try await store.searchKeyword(query: "Liked", limit: 5)
        #expect(hits.contains { $0.text.contains("Liked a message") })
    }

    @Test
    func `Reply provenance is carried in metadata`() async throws {
        let paths = makeMessagesPaths()
        defer { try? FileManager.default.removeItem(at: paths.base) }
        try createMessagesFixture(at: paths.database)
        let handle = try openMessagesFixture(at: paths.database)
        try insertMessagesFixtureMessage(
            into: handle,
            rowID: 1,
            guid: "guid-reply",
            text: "This is a reply",
            date: 700_000_000_000_003_000,
            isFromMe: true,
            threadOriginator: "guid-origin"
        )
        try joinMessagesFixtureChat(into: handle, chatID: 1, messageID: 1)
        sqlite3_close(handle)

        let store = DocIndexStore(dbPath: paths.store)
        let indexer = MessagesIndexer(
            chatDatabasePath: paths.database,
            store: store,
            statePath: paths.state
        )
        _ = try await indexer.indexNewMessages()
        let document = try await store.document(source: .messages, externalID: "guid-reply")
        #expect(document?.metadata["threadOriginatorGUID"] == "guid-origin")
        #expect(document?.metadata["isFromMe"] == "true")
    }

    @Test
    func `Watermark advances incrementally and survives a new indexer`() async throws {
        let paths = makeMessagesPaths()
        defer { try? FileManager.default.removeItem(at: paths.base) }
        try createMessagesFixture(at: paths.database)
        let firstHandle = try openMessagesFixture(at: paths.database)
        try insertMessagesFixtureMessage(
            into: firstHandle,
            rowID: 1,
            guid: "guid-1",
            text: "First message",
            date: 700_000_000_000_010_000,
            isFromMe: false
        )
        try joinMessagesFixtureChat(into: firstHandle, chatID: 1, messageID: 1)
        sqlite3_close(firstHandle)

        let store = DocIndexStore(dbPath: paths.store)
        let first = MessagesIndexer(
            chatDatabasePath: paths.database,
            store: store,
            statePath: paths.state
        )
        let firstResult = try await first.indexNewMessages()
        #expect(firstResult.scanned == 1)
        #expect(firstResult.indexed == 1)
        #expect(firstResult.lastRowID == 1)

        // A second message arrives after the first pass; a fresh indexer over the
        // same state file must read only the new row.
        let secondHandle = try openMessagesFixture(at: paths.database)
        try insertMessagesFixtureMessage(
            into: secondHandle,
            rowID: 2,
            guid: "guid-2",
            text: "Second message",
            date: 700_000_000_000_020_000,
            isFromMe: true
        )
        try joinMessagesFixtureChat(into: secondHandle, chatID: 1, messageID: 2)
        sqlite3_close(secondHandle)

        let second = MessagesIndexer(
            chatDatabasePath: paths.database,
            store: store,
            statePath: paths.state
        )
        let secondResult = try await second.indexNewMessages()
        #expect(secondResult.scanned == 1)
        #expect(secondResult.indexed == 1)
        #expect(secondResult.lastRowID == 2)

        let third = MessagesIndexer(
            chatDatabasePath: paths.database,
            store: store,
            statePath: paths.state
        )
        let thirdResult = try await third.indexNewMessages()
        #expect(thirdResult.scanned == 0)
        #expect(thirdResult.indexed == 0)
        #expect(thirdResult.lastRowID == 2)

        let watermark = try await third.currentRowIDWatermark()
        #expect(watermark == 2)
        let stats = try await store.stats()
        #expect(stats.documents == 2)
    }

    @Test
    func `Attachment placeholders resolve and attachment text is indexed`() async throws {
        let paths = makeMessagesPaths()
        defer { try? FileManager.default.removeItem(at: paths.base) }
        let attachmentURL = paths.base.appendingPathComponent("note.txt")
        try "attachment secret text".write(to: attachmentURL, atomically: true, encoding: .utf8)
        try createMessagesFixture(at: paths.database)
        let handle = try openMessagesFixture(at: paths.database)
        try insertMessagesFixtureMessage(
            into: handle,
            rowID: 1,
            guid: "guid-attachment",
            text: "See \u{FFFC}",
            date: 700_000_000_000_030_000,
            isFromMe: false
        )
        try joinMessagesFixtureChat(into: handle, chatID: 1, messageID: 1)
        try execMessagesFixture(
            handle,
            "INSERT INTO attachment(ROWID, filename, transfer_name, mime_type, total_bytes) "
                + "VALUES(1, '\(attachmentURL.path)', 'note.txt', 'text/plain', 21);"
        )
        try execMessagesFixture(handle, "INSERT INTO message_attachment_join(message_id, attachment_id) VALUES(1, 1);")
        sqlite3_close(handle)

        let store = DocIndexStore(dbPath: paths.store)
        let indexer = MessagesIndexer(
            chatDatabasePath: paths.database,
            store: store,
            statePath: paths.state
        )
        let result = try await indexer.indexNewMessages()
        #expect(result.indexed == 1)

        let hits = try await store.searchKeyword(query: "attachment", limit: 5)
        #expect(hits.contains { $0.text.contains("attachment secret text") })
        #expect(hits.contains { $0.text.contains("[note.txt]") })
    }

    @Test
    func `Missing snapshot database surfaces permission denial`() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("runeweaver-missing-\(UUID().uuidString).db").path
        do {
            _ = try MessagesIndexer.openHandle(snapshotPath: missing)
            Issue.record("Expected a permission failure for a missing snapshot")
        } catch let error as MessagesIndexError {
            guard case .permissionDenied = error else {
                Issue.record("Expected permissionDenied, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected MessagesIndexError, got \(error)")
        }
    }

    @Test
    func `Missing source database reports unavailable`() async {
        let paths = makeMessagesPaths()
        defer { try? FileManager.default.removeItem(at: paths.base) }
        let store = DocIndexStore(dbPath: paths.store)
        let indexer = MessagesIndexer(
            chatDatabasePath: paths.base.appendingPathComponent("absent.db").path,
            store: store,
            statePath: paths.state
        )
        do {
            _ = try await indexer.indexNewMessages()
            Issue.record("Expected a databaseUnavailable failure")
        } catch let error as MessagesIndexError {
            guard case .databaseUnavailable = error else {
                Issue.record("Expected databaseUnavailable, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected MessagesIndexError, got \(error)")
        }
    }
}

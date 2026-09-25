// Rune Weaver Core — Apple Messages indexer for the local retrieval corpus.
//
// The Messages chat database is TCC-protected and actively written by the
// Messages app, so it is never opened in place. A run copies the database plus
// its write-ahead log and shared-memory sidecars into an isolated temporary
// snapshot and reads only that copy, which keeps the live store from ever being
// locked or held open across a long index pass. Messages are consumed in
// ascending ROWID order from a persisted watermark so repeated runs only touch
// rows that arrived since the last pass. Body text is resolved from the plain
// `text` column or, when Messages stores only a serialized attributed string,
// from the `attributedBody` blob. Tapbacks and replies are interpreted from
// `associated_message_type` and `thread_originator_guid`, chat and participant
// provenance is joined from `chat`, `handle`, and `chat_message_join`, and
// attachments are routed through the shared document text-or-vision extractor.
// A TCC or Full Disk Access denial is surfaced as an explicit missing-permission
// error instead of crashing the caller.

import CryptoKit
import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

#if canImport(SQLite3)
    import SQLite3
#endif

#if canImport(Contacts)
    import Contacts
#endif

// MARK: - Errors

/// Failures raised by ``MessagesIndexer``.
public enum MessagesIndexError: Error, Sendable, Equatable {
    /// The Messages database, or its snapshot, could not be located or opened.
    case databaseUnavailable(String)
    /// Full Disk Access (or TCC) consent is missing, so the database is unreadable.
    case permissionDenied(String)
    /// The live database could not be copied into an isolated snapshot.
    case snapshotFailed(String)
    /// A read or write against the snapshot failed after it was opened.
    case persistenceFailed(String)
}

// MARK: - Tapbacks

/// Interprets the `associated_message_type` column into a readable reaction.
public enum MessagesTapback: Sendable {
    /// Human-readable description of an add or remove reaction, or nil for a
    /// normal message (`0`) or an unrecognized code.
    /// - Parameter associatedMessageType: Raw `associated_message_type` value.
    /// - Returns: Reaction copy, or nil when the row is not an interpreted tapback.
    public static func description(for associatedMessageType: Int?) -> String? {
        guard let type = associatedMessageType else { return nil }
        switch type {
        case 2000: return "Loved a message"
        case 2001: return "Liked a message"
        case 2002: return "Disliked a message"
        case 2003: return "Laughed at a message"
        case 2004: return "Emphasized a message"
        case 2005: return "Questioned a message"
        case 3000: return "Removed a heart reaction"
        case 3001: return "Removed a like reaction"
        case 3002: return "Removed a dislike reaction"
        case 3003: return "Removed a laugh reaction"
        case 3004: return "Removed an emphasis reaction"
        case 3005: return "Removed a question reaction"
        default: return nil
        }
    }
}

// MARK: - Contact resolution

/// Seam for resolving a handle to a friendly display name.
///
/// Resolution is opportunistic by design: the indexer never prompts for
/// Contacts access, so an implementation returns only names it can already read
/// and degrades to an empty map when consent or the address book is unavailable.
public protocol MessagesContactResolving: Sendable {
    /// Maps a normalized handle (digits and letters only, lowercased) to a name.
    /// - Returns: Resolved display names, or an empty map when unavailable.
    func displayNames() -> [String: String]
}

/// Address-book-backed name resolver that reads only when access is already granted.
///
/// The engine never asks for Contacts permission on its own: reading the address
/// book is a side effect the operator may not expect from a background index
/// pass. An already-authorized address book yields phone- and email-keyed names;
/// any other authorization state yields nothing so indexing proceeds without names.
public struct MessagesContactNameResolver: MessagesContactResolving {
    /// Creates an address-book resolver.
    public init() {}

    /// Resolves handle-to-name pairs when the address book is already readable.
    /// - Returns: Normalized-handle to display-name pairs, or an empty map.
    public func displayNames() -> [String: String] {
        #if canImport(Contacts)
            guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
                return [:]
            }
            // `CNContactFormatter` reads every name component it may render
            // (prefix, given, middle, family, suffix, nickname, organization),
            // so the fetch must request the formatter's required-keys
            // descriptor. Requesting only given/family names leaves `middleName`
            // unfetched, and the formatter raises `CNPropertyNotFetchedException`
            // (an Objective-C exception Swift cannot catch) when it reads it.
            let keys: [any CNKeyDescriptor] = [
                CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
                CNContactPhoneNumbersKey as NSString,
                CNContactEmailAddressesKey as NSString
            ]
            let request = CNContactFetchRequest(keysToFetch: keys)
            let store = CNContactStore()
            var names: [String: String] = [:]
            do {
                try store.enumerateContacts(with: request) { contact, _ in
                    guard let display = NormalizedText.value(
                        CNContactFormatter.string(from: contact, style: .fullName)
                    ) else { return }
                    for phone in contact.phoneNumbers {
                        if let key = Self.normalizedHandle(phone.value.stringValue) {
                            names[key] = display
                        }
                    }
                    for email in contact.emailAddresses {
                        if let key = Self.normalizedHandle(email.value as String) {
                            names[key] = display
                        }
                    }
                }
            } catch {
                // A partially readable address book is still useful; the caller
                // simply proceeds with whatever names survived.
                return names
            }
            return names
        #else
            return [:]
        #endif
    }

    /// Normalizes a phone number or email handle for case- and punctuation-insensitive matching.
    /// - Parameter raw: Raw handle from `handle.id` or a contact field.
    /// - Returns: Lowercased alphanumeric key, or nil when nothing remains.
    static func normalizedHandle(_ raw: String) -> String? {
        let scalars = raw.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        guard !scalars.isEmpty else { return nil }
        return String(scalars.map { Character($0) })
    }
}

// MARK: - Attributed body decoding

/// Extracts plain text from a Messages `attributedBody` blob.
///
/// Messages serializes its body as an `NSAttributedString` using Apple's legacy
/// `typedstream` encoding, which `NSKeyedUnarchiver` does not read. The decoder
/// therefore walks the stream to its `NSString` payload and reads the
/// length-prefixed UTF-8 bytes. Every bound is checked so a truncated or
/// malformed blob returns nil instead of reading past the buffer.
public enum AttributedBodyTextDecoder: Sendable {
    /// Decodes the first string payload found in an attributed-body blob.
    /// - Parameter data: Raw `attributedBody` bytes.
    /// - Returns: Extracted text, or nil when no readable payload is present.
    public static func text(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        return typedStreamText(from: data)
    }

    /// Walks a legacy typedstream blob to its first string payload.
    /// - Parameter data: Raw blob bytes.
    /// - Returns: UTF-8 string payload, or nil when none can be read safely.
    private static func typedStreamText(from data: Data) -> String? {
        let bytes = [UInt8](data)
        guard let markerEnd = stringClassMarkerEnd(in: bytes) else { return nil }
        var cursor = markerEnd
        while cursor + 5 <= bytes.count {
            // The string field is introduced by an object reference followed by a
            // class reference and the `0x84` data-block indicator; the literal
            // `+` type tag may follow directly or after a one-byte count.
            if bytes[cursor] == 0x01, bytes[cursor + 2] == 0x84 {
                if let payload = readPayload(bytes, lengthIndex: cursor + 5) {
                    return payload
                }
            }
            if bytes[cursor] == 0x84, bytes[cursor + 1] == 0x01, bytes[cursor + 2] == 0x2B {
                if let payload = readPayload(bytes, lengthIndex: cursor + 3) {
                    return payload
                }
            }
            cursor += 1
        }
        return nil
    }

    /// Reads a length-prefixed UTF-8 payload starting at a length byte.
    /// - Parameters:
    ///   - bytes: Full blob.
    ///   - lengthIndex: Offset of the length encoding.
    /// - Returns: Decoded string, or nil when the prefix or payload is out of bounds.
    private static func readPayload(_ bytes: [UInt8], lengthIndex: Int) -> String? {
        guard let (length, start) = readLength(bytes, at: lengthIndex), length > 0 else { return nil }
        let end = start + length
        guard end <= bytes.count else { return nil }
        return String(data: Data(bytes[start ..< end]), encoding: .utf8)
    }

    /// Reads a typedstream length encoding.
    ///
    /// Values below `0x80` are inline; `0x81`, `0x82`, and `0x83` introduce a
    /// little-endian 16-, 24-, or 32-bit length respectively.
    /// - Parameters:
    ///   - bytes: Full blob.
    ///   - index: Offset of the length encoding.
    /// - Returns: The decoded length plus the offset of the first payload byte.
    private static func readLength(_ bytes: [UInt8], at index: Int) -> (length: Int, start: Int)? {
        guard index < bytes.count else { return nil }
        let first = bytes[index]
        if first < 0x80 {
            return (Int(first), index + 1)
        }
        switch first {
        case 0x81:
            guard index + 2 < bytes.count else { return nil }
            let value = Int(bytes[index + 1]) | (Int(bytes[index + 2]) << 8)
            return (value, index + 3)
        case 0x82:
            guard index + 3 < bytes.count else { return nil }
            let value = Int(bytes[index + 1]) | (Int(bytes[index + 2]) << 8) | (Int(bytes[index + 3]) << 16)
            return (value, index + 4)
        case 0x83:
            guard index + 4 < bytes.count else { return nil }
            let value = Int(bytes[index + 1]) | (Int(bytes[index + 2]) << 8) | (Int(bytes[index + 3]) << 16) | (Int(bytes[index + 4]) << 24)
            return (value, index + 5)
        default:
            return nil
        }
    }

    /// Finds the end of the first string class marker in a typedstream blob.
    /// - Parameter bytes: Full blob.
    /// - Returns: Offset just past the matched marker, or nil when absent.
    private static func stringClassMarkerEnd(in bytes: [UInt8]) -> Int? {
        for marker in stringClassLiterals {
            if let offset = firstIndex(of: marker, in: bytes) {
                return offset + marker.count
            }
        }
        return nil
    }

    /// Byte offset of the first occurrence of a needle.
    /// - Parameters:
    ///   - needle: Bytes to find.
    ///   - bytes: Buffer to search.
    /// - Returns: Offset of the match, or nil when absent.
    private static func firstIndex(of needle: [UInt8], in bytes: [UInt8]) -> Int? {
        guard !needle.isEmpty, needle.count <= bytes.count else { return nil }
        let lastStart = bytes.count - needle.count
        var start = 0
        while start <= lastStart {
            if bytes[start] == needle[0] {
                var match = true
                for offset in 1 ..< needle.count where bytes[start + offset] != needle[offset] {
                    match = false
                    break
                }
                if match {
                    return start
                }
            }
            start += 1
        }
        return nil
    }

    /// Class literals searched in order; mutable strings are the fallback shape.
    private static let stringClassLiterals: [[UInt8]] = [
        Array("NSString".utf8),
        Array("NSMutableString".utf8)
    ]
}

// MARK: - Index state

/// Persisted incremental cursor for the Messages indexer.
///
/// The watermark is the highest `message.ROWID` that has been examined, which is
/// monotonic because Messages assigns ROWIDs in insertion order. Persisting it
/// outside the retrieval store keeps the indexer idempotent across restarts
/// without adding a table to the shared document index schema.
public struct MessagesIndexState: Sendable, Codable, Equatable {
    /// Highest examined message ROWID; zero for a store that has never run.
    public var lastRowID: Int64

    /// Creates an index state.
    /// - Parameter lastRowID: Highest examined message ROWID.
    public init(lastRowID: Int64 = 0) {
        self.lastRowID = lastRowID
    }
}

/// Outcome of one Messages index pass.
public struct MessagesIndexResult: Sendable, Equatable {
    /// Messages read from the snapshot in this pass.
    public let scanned: Int
    /// Messages persisted with searchable content.
    public let indexed: Int
    /// Highest ROWID examined, persisted as the next watermark.
    public let lastRowID: Int64
    /// Whether the snapshot may hold more rows past the batch bound.
    public let hasMore: Bool

    /// Creates an index result.
    /// - Parameters:
    ///   - scanned: Messages read in this pass.
    ///   - indexed: Messages persisted.
    ///   - lastRowID: Highest ROWID examined.
    ///   - hasMore: Whether more rows remain past the batch bound.
    public init(scanned: Int, indexed: Int, lastRowID: Int64, hasMore: Bool) {
        self.scanned = scanned
        self.indexed = indexed
        self.lastRowID = lastRowID
        self.hasMore = hasMore
    }
}

// MARK: - Indexer

/// Reads Apple Messages from an isolated snapshot and persists them to the index.
///
/// The indexer is an actor so a scheduled pass and an on-demand pass cannot
/// interleave their watermark reads and writes. Every dependency that touches
/// the outside world — the document store, the attachment extractor, the contact
/// resolver, and the state file — is injected, so the reader is exercised against
/// fixtures without a live Messages database.
public actor MessagesIndexer {
    /// Default location of the Messages chat database.
    public static let defaultChatDatabasePath = "~/Library/Messages/chat.db"
    /// Default location of the persisted watermark file.
    public static let defaultStatePath = "~/.runeweaver/index/messages-state.json"
    /// Default number of messages read per pass.
    public static let defaultBatchLimit = 500
    /// Default per-attachment byte bound for text extraction.
    public static let defaultMaxAttachmentBytes = 25 * 1024 * 1024

    /// Upper bound on any caller-supplied batch, keeping one pass bounded.
    static let maxBatchLimit = 5000

    /// Cheap read-only probe for Full Disk Access, intended for status use.
    ///
    /// There is no prompt API for Full Disk Access, so the first denial would
    /// otherwise surface only after a wasted Rebuild or nightly pass. The probe
    /// opens the live database read-only and closes it immediately, never
    /// copying or locking the live store, so the status poll can call it on
    /// every tick. A read-only `open` exercises the same permission gate as the
    /// copy the run performs, while `isReadableFile` consults only the
    /// directory entry and can disagree with `open` under TCC.
    /// - Parameter chatDatabasePath: Live database path; `~` is expanded.
    /// - Returns: True when the chat database file opens read-only.
    public static func hasMessagesDatabaseAccess(chatDatabasePath: String = defaultChatDatabasePath) -> Bool {
        let expanded = (chatDatabasePath as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else { return false }
        let descriptor: Int32 = expanded.withCString { cString in
            open(cString, O_RDONLY)
        }
        guard descriptor >= 0 else { return false }
        _ = close(descriptor)
        return true
    }

    /// Cheap read-only probe against this indexer's configured database path.
    ///
    /// Callers that already hold an indexer must probe through the instance so
    /// the warning reflects the same path the next run will copy; a custom
    /// path probed through the static default would disagree with the run
    /// outcome. The static variant stays primary for callers with no instance.
    /// Nonisolated so a status poll reads it synchronously without hopping;
    /// safe because the path never mutates after initialization.
    /// - Returns: True when the configured chat database file opens read-only.
    public nonisolated func hasMessagesDatabaseAccess() -> Bool {
        Self.hasMessagesDatabaseAccess(chatDatabasePath: chatDatabasePath)
    }

    /// Source database path, expanded on first use.
    ///
    /// Held nonisolated so the synchronous probe can read it without hopping;
    /// safe because the value never mutates after initialization.
    private nonisolated let chatDatabasePath: String
    /// Durable retrieval store receiving documents and chunks.
    private let store: DocIndexStore
    /// Shared text-or-vision extractor used for attachment bodies.
    private let extractor: any DocumentTextExtracting
    /// Opportunistic handle-to-name resolver.
    private let contacts: any MessagesContactResolving
    /// Persisted watermark location.
    private let stateURL: URL
    /// Messages read per pass.
    private let batchLimit: Int
    /// Largest attachment handed to the extractor.
    private let maxAttachmentBytes: Int

    /// Creates a Messages indexer.
    /// - Parameters:
    ///   - chatDatabasePath: Live chat database path; `~` is expanded.
    ///   - store: Durable document index receiving indexed messages.
    ///   - extractor: Text-or-vision extractor for attachment bodies.
    ///   - contacts: Opportunistic handle-to-name resolver.
    ///   - statePath: Persisted watermark file; `~` is expanded.
    ///   - batchLimit: Maximum messages read per pass.
    ///   - maxAttachmentBytes: Largest attachment read for text extraction.
    public init(
        chatDatabasePath: String = MessagesIndexer.defaultChatDatabasePath,
        store: DocIndexStore,
        extractor: any DocumentTextExtracting = DocumentTextExtractor(),
        contacts: any MessagesContactResolving = MessagesContactNameResolver(),
        statePath: String = MessagesIndexer.defaultStatePath,
        batchLimit: Int = MessagesIndexer.defaultBatchLimit,
        maxAttachmentBytes: Int = MessagesIndexer.defaultMaxAttachmentBytes
    ) {
        self.chatDatabasePath = chatDatabasePath
        self.store = store
        self.extractor = extractor
        self.contacts = contacts
        self.stateURL = URL(fileURLWithPath: (statePath as NSString).expandingTildeInPath)
        self.batchLimit = min(max(1, batchLimit), Self.maxBatchLimit)
        self.maxAttachmentBytes = max(1, maxAttachmentBytes)
    }

    /// Copies the live database and its sidecars into an isolated snapshot.
    ///
    /// The write-ahead log and shared-memory file travel with the database so a
    /// snapshot is internally consistent even when the live connection has not
    /// checkpointed. The returned directory is owned by the caller and must be
    /// removed; ``indexNewMessages(limit:)`` does so automatically.
    /// - Returns: Temporary directory holding the copied database.
    /// - Throws: ``MessagesIndexError`` when the source is missing or unreadable.
    public func snapshotDatabase() throws -> URL {
        let source = (chatDatabasePath as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw MessagesIndexError.databaseUnavailable("The Messages database is not available.")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("runeweaver-messages-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.copySnapshotItem(
                atPath: source,
                to: directory.appendingPathComponent("chat.db")
            )
            for suffix in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: source + suffix) {
                try Self.copySnapshotItem(
                    atPath: source + suffix,
                    to: directory.appendingPathComponent("chat.db" + suffix)
                )
            }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return directory
    }

    /// The persisted ROWID watermark, or zero when no pass has run.
    /// - Returns: Highest examined message ROWID.
    public func currentRowIDWatermark() throws -> Int64 {
        try readWatermark()
    }

    /// Clears the persisted watermark so the next pass starts from the beginning.
    public func resetWatermark() throws {
        try writeWatermark(0)
    }

    #if canImport(SQLite3)
        /// Indexes messages newer than the persisted ROWID watermark.
        ///
        /// The live database is snapshotted first, then read in ascending ROWID
        /// order up to `limit`. Each indexed message upserts its document and a
        /// single searchable chunk; the watermark advances only across rows the
        /// pass actually examined, so a failure mid-pass replays the unread tail
        /// on the next run rather than skipping it.
        /// - Parameter limit: Maximum messages to read; defaults to the batch bound.
        /// - Returns: Counts plus the new watermark.
        /// - Throws: ``MessagesIndexError`` on a missing permission or snapshot failure.
        public func indexNewMessages(limit: Int? = nil) async throws -> MessagesIndexResult {
            let directory = try snapshotDatabase()
            defer { try? FileManager.default.removeItem(at: directory) }
            let snapshotPath = directory.appendingPathComponent("chat.db").path
            let handle = try Self.openHandle(snapshotPath: snapshotPath)
            defer { sqlite3_close(handle) }

            let watermark = try readWatermark()
            let names = contacts.displayNames()
            let effectiveLimit = min(max(limit ?? batchLimit, 1), Self.maxBatchLimit)
            let batch = try await indexBatch(
                handle: handle,
                from: watermark,
                limit: effectiveLimit,
                names: names
            )
            try writeWatermark(batch.lastRowID)
            return batch
        }

        /// Indexes every pending message by paging one snapshot to exhaustion.
        ///
        /// One snapshot keeps a long backlog consistent while pages advance
        /// strictly by ROWID in batches of the configured bound, so per-batch
        /// memory stays flat no matter how deep the backlog runs. The watermark
        /// is persisted after every finished batch, so a run cancelled
        /// mid-backlog resumes at the first unfinished batch instead of
        /// replaying rows whose documents are already committed.
        /// - Returns: Accumulated counts plus the final watermark; `hasMore` is
        ///   always false because the loop only returns once the snapshot is drained.
        /// - Throws: ``MessagesIndexError`` on a missing permission or snapshot
        ///   failure; cancellation propagates with finished batches already committed.
        public func indexAllNewMessages() async throws -> MessagesIndexResult {
            let directory = try snapshotDatabase()
            defer { try? FileManager.default.removeItem(at: directory) }
            let snapshotPath = directory.appendingPathComponent("chat.db").path
            let handle = try Self.openHandle(snapshotPath: snapshotPath)
            defer { sqlite3_close(handle) }

            var watermark = try readWatermark()
            let names = contacts.displayNames()
            let effectiveLimit = min(max(batchLimit, 1), Self.maxBatchLimit)
            var totalScanned = 0
            var totalIndexed = 0
            var lastRowID = watermark
            while true {
                let batch = try await indexBatch(
                    handle: handle,
                    from: watermark,
                    limit: effectiveLimit,
                    names: names
                )
                totalScanned += batch.scanned
                totalIndexed += batch.indexed
                lastRowID = batch.lastRowID
                watermark = batch.lastRowID
                try writeWatermark(watermark)
                if !batch.hasMore {
                    break
                }
            }
            return MessagesIndexResult(
                scanned: totalScanned,
                indexed: totalIndexed,
                lastRowID: lastRowID,
                hasMore: false
            )
        }

        /// Indexes one ROWID-ordered batch from an already-open snapshot.
        ///
        /// The caller owns snapshot lifetime and watermark persistence, so the
        /// single-batch entry and the converging loop share identical row
        /// handling without duplicating the cancellation or upsert shape.
        /// - Parameters:
        ///   - handle: Open snapshot handle owned by the caller.
        ///   - watermark: Exclusive lower bound on `message.ROWID`.
        ///   - limit: Maximum rows read in this batch.
        ///   - names: Resolved contact names keyed by normalized handle.
        /// - Returns: Counts plus the highest ROWID examined in this batch.
        private func indexBatch(
            handle: OpaquePointer?,
            from watermark: Int64,
            limit: Int,
            names: [String: String]
        ) async throws -> MessagesIndexResult {
            let rows = try MessagesDatabaseIO.messages(
                handle: handle,
                afterRowID: watermark,
                limit: limit
            )

            var indexed = 0
            var lastRowID = watermark
            for row in rows {
                // Honor cancellation per message so a large batch stops within
                // one item instead of draining the whole batch bound.
                try Task.checkCancellation()
                let attachments = try MessagesDatabaseIO.attachments(handle: handle, messageID: row.rowID)
                let payload = makePayload(from: row, attachments: attachments, names: names)
                if !payload.combinedText.isEmpty {
                    let stored = try await store.upsertDocument(payload.document)
                    _ = try await store.upsertChunks(
                        documentID: stored.id,
                        chunks: payload.chunks(documentID: stored.id)
                    )
                    indexed += 1
                }
                lastRowID = max(lastRowID, row.rowID)
            }
            return MessagesIndexResult(
                scanned: rows.count,
                indexed: indexed,
                lastRowID: lastRowID,
                hasMore: rows.count == limit
            )
        }
    #endif

    /// Opens a snapshot database handle, mapping open failures to the honest cause.
    ///
    /// SQLite reports both a missing file and an unreadable one as
    /// `SQLITE_CANTOPEN`, which is the shape a TCC or Full Disk Access denial
    /// takes, so that code is surfaced as a missing-permission state.
    /// - Parameter snapshotPath: Snapshot database path.
    /// - Returns: Open handle; the caller closes it.
    /// - Throws: ``MessagesIndexError`` when the handle cannot be opened.
    static func openHandle(snapshotPath: String) throws -> OpaquePointer {
        #if canImport(SQLite3)
            var handle: OpaquePointer?
            let status = snapshotPath.withCString { sqlite3_open_v2($0, &handle, SQLITE_OPEN_READWRITE, nil) }
            guard status == SQLITE_OK, let handle else {
                if let handle {
                    sqlite3_close(handle)
                }
                if status == SQLITE_CANTOPEN || status == SQLITE_PERM {
                    throw MessagesIndexError.permissionDenied(
                        "Full Disk Access is required to read the Messages database."
                    )
                }
                throw MessagesIndexError.databaseUnavailable("The Messages snapshot could not be opened.")
            }
            do {
                try SQLiteHelpers.exec(
                    handle: handle,
                    sql: "PRAGMA busy_timeout = 5000;",
                    failure: MessagesIndexError.persistenceFailed
                )
            } catch {
                sqlite3_close(handle)
                throw error
            }
            return handle
        #else
            throw MessagesIndexError.databaseUnavailable("SQLite3 is unavailable on this platform.")
        #endif
    }

    /// Copies one snapshot member, translating permission errors into a clear denial.
    /// - Parameters:
    ///   - source: Live sidecar path.
    ///   - destination: Snapshot destination URL.
    /// - Throws: ``MessagesIndexError.permissionDenied`` when the file is not readable.
    static func copySnapshotItem(atPath source: String, to destination: URL) throws {
        do {
            try FileManager.default.copyItem(atPath: source, toPath: destination.path)
        } catch {
            if isPermissionError(error) {
                throw MessagesIndexError.permissionDenied(
                    "Full Disk Access is required to read the Messages database."
                )
            }
            throw MessagesIndexError.snapshotFailed("Could not snapshot the Messages database.")
        }
    }

    /// Whether an error represents a denied read or write.
    /// - Parameter error: Error raised by a copy.
    /// - Returns: True when the failure is a permission denial.
    static func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            return nsError.code == CocoaError.Code.fileReadNoPermission.rawValue || nsError.code == CocoaError.Code.fileWriteNoPermission.rawValue
        }
        if nsError.domain == NSPOSIXErrorDomain {
            return nsError.code == Int(EACCES) || nsError.code == Int(EPERM)
        }
        return false
    }
}

// MARK: - Payload Assembly and Helpers

extension MessagesIndexer {
    /// Document plus resolved body text for one message.
    struct MessagesPayload: Sendable {
        /// Document written to the retrieval store.
        let document: IndexedDocument
        /// Searchable body: message text with attachment placeholders resolved
        /// plus extracted attachment text.
        let combinedText: String

        /// Builds the single searchable chunk for this message.
        /// - Parameter documentID: Identifier returned by the store on upsert.
        /// - Returns: One chunk, or an empty list when there is nothing to index.
        func chunks(documentID: UUID) -> [IndexedChunk] {
            guard !combinedText.isEmpty else { return [] }
            return [IndexedChunk(documentID: documentID, ordinal: 0, text: combinedText)]
        }
    }

    /// Assembles the indexable payload for one message row.
    /// - Parameters:
    ///   - row: Message read from the snapshot.
    ///   - attachments: Attachments joined to the message.
    ///   - names: Resolved contact names keyed by normalized handle.
    /// - Returns: The document and its resolved searchable text.
    func makePayload(
        from row: MessagesDatabaseRow,
        attachments: [MessagesAttachmentRow],
        names: [String: String]
    ) -> MessagesPayload {
        let resolved = Self.resolveText(for: row)
        let attachmentResults = attachmentResults(for: attachments)
        let attachmentNames = attachmentResults.map(\.name)

        var parts: [String] = []
        if let text = resolved.text {
            parts.append(Self.replacingPlaceholders(in: text, with: attachmentNames))
        }
        for attachment in attachmentResults {
            if let extracted = attachment.text {
                parts.append("[\(attachment.name)]\n\(extracted)")
            } else {
                parts.append("[\(attachment.name)]")
            }
        }
        let combined = NormalizedText.value(parts.joined(separator: "\n\n")) ?? ""

        let metadata = Self.metadata(for: row, names: names)
        let document = IndexedDocument(
            source: .messages,
            externalID: row.externalID,
            displayName: Self.displayName(for: row, names: names),
            path: nil,
            messageID: NormalizedText.value(row.guid),
            mailbox: row.chatID.map { String($0) },
            mtime: row.date.map(Self.date(fromMacEpoch:)),
            sizeBytes: nil,
            contentHash: Self.contentHash(for: combined),
            mime: "text/plain",
            extractStatus: combined.isEmpty ? .metadataOnly : .extracted,
            metadata: metadata
        )
        return MessagesPayload(document: document, combinedText: combined)
    }

    /// Resolves a message body from its plain text, attributed body, or reaction.
    /// - Parameter row: Message read from the snapshot.
    /// - Returns: Resolved body text plus an honest extraction status.
    static func resolveText(for row: MessagesDatabaseRow) -> (text: String?, status: ExtractStatus) {
        if let plain = NormalizedText.value(row.text) {
            return (plain, .extracted)
        }
        if let body = row.attributedBody,
           let decoded = AttributedBodyTextDecoder.text(from: body),
           let value = NormalizedText.value(decoded)
        {
            return (value, .extracted)
        }
        if let reaction = MessagesTapback.description(for: row.associatedMessageType) {
            return (reaction, .metadataOnly)
        }
        return (nil, .metadataOnly)
    }

    /// Extracts searchable text from each attachment through the shared extractor.
    /// - Parameter attachments: Attachments joined to the message.
    /// - Returns: Display name plus extracted text per attachment (text nil when
    ///   the file is missing, oversized, or carries no extractable text).
    func attachmentResults(for attachments: [MessagesAttachmentRow]) -> [(name: String, text: String?)] {
        var results: [(name: String, text: String?)] = []
        for attachment in attachments {
            let name = Self.attachmentName(for: attachment)
            guard let path = NormalizedText.value(attachment.fileName) else {
                results.append((name: name, text: nil))
                continue
            }
            let expanded = (path as NSString).expandingTildeInPath
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: expanded),
                  let size = (attributes[.size] as? NSNumber)?.intValue,
                  size > 0,
                  size <= maxAttachmentBytes,
                  let data = try? Data(contentsOf: URL(fileURLWithPath: expanded), options: [.mappedIfSafe])
            else {
                results.append((name: name, text: nil))
                continue
            }
            let extraction = extractor.extract(
                data: data,
                fileName: (expanded as NSString).lastPathComponent,
                contentType: attachment.mimeType
            )
            results.append((name: name, text: NormalizedText.value(extraction.text)))
        }
        return results
    }

    /// Replaces attachment placeholders with names in attachment order.
    ///
    /// Messages writes one `U+FFFC` object-replacement character per attachment
    /// directly in the body, so consuming placeholders left to right against the
    /// `ROWID`-ordered attachment list lines them up.
    /// - Parameters:
    ///   - text: Message body carrying placeholders.
    ///   - names: Attachment display names in join order.
    /// - Returns: Body with each placeholder replaced by `[name]`.
    static func replacingPlaceholders(in text: String, with names: [String]) -> String {
        var result = text
        var index = 0
        while let range = result.range(of: "\u{FFFC}") {
            let replacement = names.indices.contains(index) ? "[\(names[index])]" : "[attachment]"
            result.replaceSubrange(range, with: replacement)
            index += 1
        }
        return result
    }

    /// Builds the source-scoped metadata carried on every indexed message.
    /// - Parameters:
    ///   - row: Message read from the snapshot.
    ///   - names: Resolved contact names keyed by normalized handle.
    /// - Returns: Chat, handle, Mac-epoch date, direction, and provenance keys.
    static func metadata(for row: MessagesDatabaseRow, names: [String: String]) -> [String: String] {
        var metadata: [String: String] = [:]
        if let chatID = row.chatID {
            metadata["chatID"] = String(chatID)
        }
        if let handle = NormalizedText.value(row.handle) {
            metadata["handle"] = handle
            if let friendly = friendlyName(for: handle, names: names) {
                metadata["handleName"] = friendly
            }
        }
        if let date = row.date {
            // Retained as the raw Mac-epoch tick so callers can order without
            // re-deriving it from the converted `mtime`.
            metadata["date"] = String(date)
        }
        metadata["isFromMe"] = row.isFromMe ? "true" : "false"
        if let type = row.associatedMessageType, type != 0 {
            metadata["associatedMessageType"] = String(type)
        }
        if let originator = NormalizedText.value(row.threadOriginatorGUID) {
            metadata["threadOriginatorGUID"] = originator
        }
        if let chatGUID = NormalizedText.value(row.chatGUID) {
            metadata["chatGUID"] = chatGUID
        }
        return metadata
    }

    /// Chooses a display name for a message from chat, participant, and message identity.
    /// - Parameters:
    ///   - row: Message read from the snapshot.
    ///   - names: Resolved contact names keyed by normalized handle.
    /// - Returns: Best available label; never empty.
    static func displayName(for row: MessagesDatabaseRow, names: [String: String]) -> String {
        NormalizedText.value(row.chatDisplayName)
            ?? NormalizedText.value(row.chatIdentifier)
            ?? friendlyName(for: row.handle, names: names)
            ?? NormalizedText.value(row.handle)
            ?? NormalizedText.value(row.guid)
            ?? "Message \(row.rowID)"
    }

    /// Resolves a handle to a friendly name when the resolver knew it.
    /// - Parameters:
    ///   - handle: Raw handle from the message.
    ///   - names: Resolved contact names keyed by normalized handle.
    /// - Returns: Friendly name, or nil when the handle is unknown.
    static func friendlyName(for handle: String?, names: [String: String]) -> String? {
        guard let handle = NormalizedText.value(handle),
              let key = MessagesContactNameResolver.normalizedHandle(handle)
        else { return nil }
        return names[key]
    }

    /// Picks the display name for an attachment.
    /// - Parameter attachment: Attachment read from the snapshot.
    /// - Returns: Transfer name, else the file's last path component.
    static func attachmentName(for attachment: MessagesAttachmentRow) -> String {
        if let transfer = NormalizedText.value(attachment.transferName) {
            return transfer
        }
        if let file = NormalizedText.value(attachment.fileName) {
            return (file as NSString).lastPathComponent
        }
        return "attachment"
    }

    /// Converts a Mac-epoch tick to a wall-clock date.
    ///
    /// Messages stores seconds on older databases and nanoseconds on current
    /// ones; the magnitude distinguishes them because a seconds value cannot
    /// reach the nanosecond lower bound within any realistic date range.
    /// - Parameter raw: Raw `message.date` value relative to 2001-01-01.
    /// - Returns: Converted date.
    static func date(fromMacEpoch raw: Int64) -> Date {
        let seconds = raw > 1_000_000_000_000 ? Double(raw) / 1_000_000_000 : Double(raw)
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    /// Stable content hash gating re-indexing of an unchanged body.
    /// - Parameter text: Resolved searchable text.
    /// - Returns: Lowercase SHA-256 digest.
    static func contentHash(for text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Watermark

    /// Reads the persisted watermark, defaulting to zero when absent or unreadable.
    /// - Returns: Highest examined message ROWID.
    private func readWatermark() throws -> Int64 {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return 0 }
        let data = try Data(contentsOf: stateURL)
        do {
            return try JSONDecoder().decode(MessagesIndexState.self, from: data).lastRowID
        } catch {
            RuneWeaverLog.stores.warning("MessagesIndexer: failed to decode watermark from '\(stateURL.path)': \(error.localizedDescription)")
            return 0
        }
    }

    /// Persists the watermark atomically.
    /// - Parameter rowID: Highest examined message ROWID.
    private func writeWatermark(_ rowID: Int64) throws {
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(MessagesIndexState(lastRowID: rowID))
        try data.write(to: stateURL, options: .atomic)
    }
}

// MARK: - Snapshot rows

/// One `message` row joined to its chat and handle provenance.
struct MessagesDatabaseRow: Sendable, Equatable {
    /// `message.ROWID`, the incremental watermark key.
    let rowID: Int64
    /// Message GUID used as the source-scoped external identifier.
    let guid: String?
    /// Plain body text, when Messages populated it.
    let text: String?
    /// Serialized attributed body, when the plain column is empty.
    let attributedBody: Data?
    /// Raw Mac-epoch tick from `message.date`.
    let date: Int64?
    /// Whether the signed-in account sent the message.
    let isFromMe: Bool
    /// Raw `associated_message_type`, zero for a normal message.
    let associatedMessageType: Int?
    /// Reply target GUID from `thread_originator_guid`.
    let threadOriginatorGUID: String?
    /// Sending or receiving handle identifier.
    let handle: String?
    /// Owning `chat.ROWID`.
    let chatID: Int64?
    /// Owning chat GUID.
    let chatGUID: String?
    /// Group chat display name, when set.
    let chatDisplayName: String?
    /// Chat identifier (the other participant or group id).
    let chatIdentifier: String?

    /// Source-scoped identifier: the GUID, or the ROWID when a GUID is absent.
    var externalID: String {
        NormalizedText.value(guid) ?? "rowid:\(rowID)"
    }
}

/// One `attachment` row joined to a message.
struct MessagesAttachmentRow: Sendable, Equatable {
    /// On-disk filename as stored by Messages (may be `~`-relative).
    let fileName: String?
    /// User-facing transfer name.
    let transferName: String?
    /// Declared MIME type.
    let mimeType: String?
    /// Declared total byte count.
    let totalBytes: Int64?
}

#if canImport(SQLite3)

    // MARK: - Snapshot reads

    /// Read-only queries against an opened Messages snapshot.
    enum MessagesDatabaseIO {
        /// Reads messages past a ROWID watermark in ascending order.
        /// - Parameters:
        ///   - handle: Open snapshot handle.
        ///   - afterRowID: Exclusive lower bound on `message.ROWID`.
        ///   - limit: Maximum rows returned.
        /// - Returns: Joined message rows.
        /// - Throws: ``MessagesIndexError`` when the statement cannot be prepared.
        static func messages(handle: OpaquePointer?, afterRowID: Int64, limit: Int) throws -> [MessagesDatabaseRow] {
            guard limit > 0 else { return [] }
            let sql = """
            SELECT m.ROWID, m.guid, m.text, m.attributedBody, m.date, m.is_from_me,
                   m.associated_message_type, m.thread_originator_guid,
                   h.id,
                   c.ROWID, c.guid, c.display_name, c.chat_identifier
            FROM message m
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            LEFT JOIN chat c ON c.ROWID = cmj.chat_id
            WHERE m.ROWID > ?
            ORDER BY m.ROWID ASC
            LIMIT ?;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw MessagesIndexError.databaseUnavailable("Could not read the Messages snapshot.")
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, afterRowID)
            sqlite3_bind_int(statement, 2, SQLiteHelpers.sqliteLimit(limit))
            var rows: [MessagesDatabaseRow] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(readRow(statement))
            }
            return rows
        }

        /// Reads attachments joined to one message, in attachment order.
        /// - Parameters:
        ///   - handle: Open snapshot handle.
        ///   - messageID: Owning `message.ROWID`.
        /// - Returns: Attachment rows; empty when the statement cannot be prepared.
        static func attachments(handle: OpaquePointer?, messageID: Int64) throws -> [MessagesAttachmentRow] {
            let sql = """
            SELECT a.filename, a.transfer_name, a.mime_type, a.total_bytes
            FROM message_attachment_join maj
            JOIN attachment a ON a.ROWID = maj.attachment_id
            WHERE maj.message_id = ?
            ORDER BY a.ROWID ASC;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                return []
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, messageID)
            var rows: [MessagesAttachmentRow] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(
                    MessagesAttachmentRow(
                        fileName: SQLiteHelpers.columnText(statement, index: 0),
                        transferName: SQLiteHelpers.columnText(statement, index: 1),
                        mimeType: SQLiteHelpers.columnText(statement, index: 2),
                        totalBytes: SQLiteHelpers.columnInt64(statement, index: 3)
                    )
                )
            }
            return rows
        }

        /// Decodes the message row at the statement's current position.
        /// - Parameter statement: Statement positioned on a row.
        /// - Returns: Decoded message row.
        private static func readRow(_ statement: OpaquePointer?) -> MessagesDatabaseRow {
            MessagesDatabaseRow(
                rowID: sqlite3_column_int64(statement, 0),
                guid: SQLiteHelpers.columnText(statement, index: 1),
                text: SQLiteHelpers.columnText(statement, index: 2),
                attributedBody: columnBlob(statement, index: 3),
                date: SQLiteHelpers.columnInt64(statement, index: 4),
                isFromMe: sqlite3_column_int(statement, 5) != 0,
                associatedMessageType: optionalInt(statement, index: 6),
                threadOriginatorGUID: SQLiteHelpers.columnText(statement, index: 7),
                handle: SQLiteHelpers.columnText(statement, index: 8),
                chatID: SQLiteHelpers.columnInt64(statement, index: 9),
                chatGUID: SQLiteHelpers.columnText(statement, index: 10),
                chatDisplayName: SQLiteHelpers.columnText(statement, index: 11),
                chatIdentifier: SQLiteHelpers.columnText(statement, index: 12)
            )
        }

        /// Reads an optional integer, preserving NULL as nil.
        /// - Parameters:
        ///   - statement: Statement positioned on a row.
        ///   - index: Column index.
        /// - Returns: Integer value, or nil for NULL.
        private static func optionalInt(_ statement: OpaquePointer?, index: Int32) -> Int? {
            guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
            return Int(sqlite3_column_int(statement, index))
        }

        /// Copies a BLOB column into `Data`.
        /// - Parameters:
        ///   - statement: Statement positioned on a row.
        ///   - index: Column index.
        /// - Returns: Blob bytes, or nil for NULL or empty columns.
        private static func columnBlob(_ statement: OpaquePointer?, index: Int32) -> Data? {
            guard sqlite3_column_type(statement, index) == SQLITE_BLOB,
                  let pointer = sqlite3_column_blob(statement, index)
            else { return nil }
            let count = Int(sqlite3_column_bytes(statement, index))
            guard count > 0 else { return nil }
            return Data(bytes: pointer, count: count)
        }
    }
#endif

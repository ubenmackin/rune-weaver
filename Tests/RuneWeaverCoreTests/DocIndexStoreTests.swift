// Rune Weaver Core Tests — Document index store schema, hashing, search, and maintenance.
//
// Exercises the SQLite-backed document index end to end against isolated
// temporary databases: schema creation and additive migration, content-hash
// skip behavior, FTS5 keyword retrieval, vector chunk accounting, pruning
// with vacuum, deletion, and reset. Tests never touch the real
// `~/.runeweaver/memory` store.

import Foundation
@testable import RuneWeaverCore
import Testing

#if canImport(SQLite3)
    import SQLite3
#endif

/// Creates an isolated temporary database path and its parent directory.
/// - Returns: The database path plus the base directory to remove on teardown.
private func makeIndexPath() -> (path: String, base: URL) {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("runeweaver-docindex-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return (base.appendingPathComponent("docindex.db").path, base)
}

/// Builds a document with sane defaults for tests.
private func makeDocument(
    source: IndexSource = .files,
    externalID: String,
    displayName: String = "Sample",
    contentHash: String,
    extractStatus: ExtractStatus = .extracted,
    indexedAt: Date = Date(),
    path: String? = nil,
    messageID: String? = nil,
    mailbox: String? = nil,
    sizeBytes: Int64? = nil,
    metadata: [String: String] = [:]
) -> IndexedDocument {
    IndexedDocument(
        source: source,
        externalID: externalID,
        displayName: displayName,
        path: path,
        messageID: messageID,
        mailbox: mailbox,
        mtime: nil,
        sizeBytes: sizeBytes,
        contentHash: contentHash,
        mime: nil,
        extractStatus: extractStatus,
        indexedAt: indexedAt,
        metadata: metadata
    )
}

/// Error raised when the raw legacy-database helper cannot run.
private enum LegacyIndexError: Error {
    /// The raw statement failed with a SQLite detail string.
    case failed(String)
}

/// Creates a database with the pre-metadata document schema to exercise the
/// additive column migration.
/// - Parameter path: Database file path.
private func createLegacyIndex(atPath path: String) throws {
    #if canImport(SQLite3)
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let handle else {
            throw LegacyIndexError.failed("Could not open legacy database")
        }
        defer { sqlite3_close(handle) }
        let sql = """
        CREATE TABLE indexed_documents(
            id TEXT PRIMARY KEY,
            source TEXT NOT NULL,
            external_id TEXT NOT NULL,
            display_name TEXT NOT NULL,
            path TEXT,
            message_id TEXT,
            mailbox TEXT,
            mtime REAL,
            size_bytes INTEGER,
            content_hash TEXT NOT NULL,
            mime TEXT,
            extract_status TEXT NOT NULL,
            indexed_at REAL NOT NULL
        );
        CREATE TABLE indexed_chunks(
            id TEXT PRIMARY KEY,
            document_id TEXT NOT NULL,
            ordinal INTEGER NOT NULL,
            chunk_text TEXT NOT NULL,
            embedding BLOB
        );
        """
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &message) == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(message)
            throw LegacyIndexError.failed(detail)
        }
    #endif
}

@Suite("Document Index Store")
struct DocIndexStoreTests {
    @Test
    func `Empty store reports zeroed statistics`() async throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: path)

        let stats = try await store.stats()
        #expect(stats.documents == 0)
        #expect(stats.chunks == 0)
        #expect(stats.vectorChunks == 0)
        #expect(stats.keywordChunks == 0)
        #expect(stats.bytes == 0)
        // An empty store has no writes, so the watermark must be the epoch
        // rather than a synthesized read time.
        #expect(stats.indexAsOf == Date(timeIntervalSince1970: 0))
    }

    @Test
    func `Default path aliases the canonical index default`() {
        // The store and the index config share one on-disk location so a
        // default-constructed store and a default config never diverge.
        #expect(DocIndexStore.defaultDBPath == IndexConfig.defaultDBPath)
        #expect(DocIndexStore.defaultDBPath == "~/.runeweaver/index.db")
    }

    @Test
    func `Stats watermark reflects the newest indexed date`() async throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: path)
        _ = try await store.upsertDocument(makeDocument(
            externalID: "old",
            contentHash: "hash-old",
            indexedAt: Date(timeIntervalSince1970: 1000)
        ))
        _ = try await store.upsertDocument(makeDocument(
            externalID: "new",
            contentHash: "hash-new",
            indexedAt: Date(timeIntervalSince1970: 5000)
        ))

        // The watermark reports the last write, not the time of the read.
        let stats = try await store.stats()
        #expect(stats.documents == 2)
        #expect(stats.indexAsOf == Date(timeIntervalSince1970: 5000))
    }

    @Test
    func `Vector pool returns the newest chunks first`() async throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: path)
        let older = try await store.upsertDocument(makeDocument(externalID: "older", contentHash: "hash-older"))
        _ = try await store.upsertChunks(
            documentID: older.id,
            chunks: [IndexedChunk(documentID: older.id, ordinal: 0, text: "older vector", embedding: [1.0, 0.0])]
        )
        let newer = try await store.upsertDocument(makeDocument(externalID: "newer", contentHash: "hash-newer"))
        _ = try await store.upsertChunks(
            documentID: newer.id,
            chunks: [IndexedChunk(documentID: newer.id, ordinal: 0, text: "newer vector", embedding: [0.0, 1.0])]
        )

        // The bounded pool favors recent writes so the semantic path keeps
        // seeing new documents at scale instead of the oldest rows.
        let newestOnly = try await store.chunkVectors(limit: 1)
        #expect(newestOnly.count == 1)
        #expect(newestOnly.first?.documentID == newer.id)
        let both = try await store.chunkVectors(limit: 10)
        #expect(both.count == 2)
        #expect(both.first?.documentID == newer.id)
        #expect(both.last?.documentID == older.id)
    }

    @Test
    func `Reopening the same database preserves documents`() async throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }

        let first = DocIndexStore(dbPath: path)
        _ = try await first.upsertDocument(makeDocument(externalID: "notes", contentHash: "hash-a"))

        // A second store over the same path replays the idempotent schema
        // without dropping the prior row.
        let second = DocIndexStore(dbPath: path)
        let loaded = try await second.document(source: .files, externalID: "notes")
        #expect(loaded?.externalID == "notes")
        let stats = try await second.stats()
        #expect(stats.documents == 1)
    }

    @Test
    func `Legacy database gains additive columns on first open`() async throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }
        try createLegacyIndex(atPath: path)

        let store = DocIndexStore(dbPath: path)
        let stored = try await store.upsertDocument(
            makeDocument(externalID: "legacy-1", contentHash: "hash-legacy", metadata: ["origin": "test"])
        )
        #expect(stored.metadata["origin"] == "test")

        let chunk = IndexedChunk(documentID: stored.id, ordinal: 0, text: "legacy body", embedding: [0.5, 0.25])
        _ = try await store.upsertChunks(documentID: stored.id, chunks: [chunk])

        let stats = try await store.stats()
        #expect(stats.documents == 1)
        #expect(stats.vectorChunks == 1)
    }

    @Test
    func `Unchanged content skips the rewrite and keeps the original row`() async throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: path)
        let originalDate = Date(timeIntervalSince1970: 1000)
        let original = makeDocument(
            externalID: "doc",
            displayName: "Original",
            contentHash: "hash-1",
            indexedAt: originalDate
        )
        let first = try await store.upsertDocument(original)
        _ = try await store.upsertChunks(
            documentID: first.id,
            chunks: [IndexedChunk(documentID: first.id, ordinal: 0, text: "kept chunk")]
        )

        // Same body hash with a different display name and timestamp: the
        // store must report unchanged so callers can skip re-extraction.
        let unchanged = makeDocument(
            externalID: "doc",
            displayName: "Changed label",
            contentHash: "hash-1",
            indexedAt: Date(timeIntervalSince1970: 2000)
        )
        let second = try await store.upsertDocument(unchanged)
        #expect(second.id == first.id)
        #expect(second.displayName == "Original")
        #expect(second.indexedAt == originalDate)

        let needsReindex = try await store.needsReindex(source: .files, externalID: "doc", contentHash: "hash-1")
        #expect(needsReindex == false)
        let stats = try await store.stats()
        #expect(stats.documents == 1)
        #expect(stats.chunks == 1)
    }

    @Test
    func `Changed content replaces the row and drops stale chunks`() async throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: path)
        let first = try await store.upsertDocument(makeDocument(externalID: "doc", contentHash: "hash-1"))
        _ = try await store.upsertChunks(
            documentID: first.id,
            chunks: [IndexedChunk(documentID: first.id, ordinal: 0, text: "stale chunk")]
        )

        let changed = try await store.upsertDocument(makeDocument(externalID: "doc", contentHash: "hash-2"))
        #expect(changed.id == first.id)
        let needsReindex = try await store.needsReindex(source: .files, externalID: "doc", contentHash: "hash-2")
        #expect(needsReindex == false)
        let unknownHash = try await store.needsReindex(source: .files, externalID: "doc", contentHash: "hash-3")
        #expect(unknownHash == true)

        let stats = try await store.stats()
        #expect(stats.documents == 1)
        #expect(stats.chunks == 0)
    }

    @Test
    func `Failed extraction is retried even when the body hash matches`() async throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: path)
        _ = try await store.upsertDocument(
            makeDocument(externalID: "doc", contentHash: "hash-1", extractStatus: .failed)
        )

        let failedNeedsReindex = try await store.needsReindex(source: .files, externalID: "doc", contentHash: "hash-1")
        #expect(failedNeedsReindex == true)

        let retried = try await store.upsertDocument(
            makeDocument(externalID: "doc", contentHash: "hash-1", extractStatus: .extracted)
        )
        #expect(retried.extractStatus == .extracted)
    }

    @Test
    func `Unknown source always needs indexing`() async throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: path)

        let needsReindex = try await store.needsReindex(source: .mail, externalID: "missing", contentHash: "hash-x")
        #expect(needsReindex == true)
        let loaded = try await store.document(source: .mail, externalID: "missing")
        #expect(loaded == nil)
    }

    @Test
    func `Keyword search retrieves matching chunks`() async throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: path)
        let document = try await store.upsertDocument(makeDocument(externalID: "notes", contentHash: "hash-f"))
        let chunks = [
            IndexedChunk(documentID: document.id, ordinal: 0, text: "The biscuit recipe uses butter"),
            IndexedChunk(documentID: document.id, ordinal: 1, text: "Sourdough starter needs feeding")
        ]
        _ = try await store.upsertChunks(documentID: document.id, chunks: chunks)

        let hits = try await store.searchKeyword(query: "biscuit", limit: 10)
        #expect(hits.count == 1)
        #expect(hits.first?.documentID == document.id)
        #expect(hits.first?.text.contains("biscuit") == true)

        let miss = try await store.searchKeyword(query: "telescope", limit: 10)
        #expect(miss.isEmpty)

        let blank = try await store.searchKeyword(query: "   ", limit: 10)
        #expect(blank.isEmpty)
    }

    @Test
    func `Vector and keyword chunks are counted separately`() async throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: path)
        let document = try await store.upsertDocument(makeDocument(externalID: "doc", contentHash: "hash-v"))
        let vectorChunk = IndexedChunk(
            documentID: document.id,
            ordinal: 0,
            text: "vector chunk",
            embedding: [0.1, 0.2, 0.3]
        )
        let keywordChunk = IndexedChunk(documentID: document.id, ordinal: 1, text: "keyword chunk")
        #expect(vectorChunk.isVector == true)
        #expect(keywordChunk.isVector == false)
        _ = try await store.upsertChunks(documentID: document.id, chunks: [vectorChunk, keywordChunk])

        let stats = try await store.stats()
        #expect(stats.documents == 1)
        #expect(stats.chunks == 2)
        #expect(stats.vectorChunks == 1)
        #expect(stats.keywordChunks == 1)
        #expect(stats.bytes > 0)

        let vectors = try await store.chunkVectors(limit: 10)
        #expect(vectors.count == 1)
        #expect(vectors.first?.embedding == [0.1, 0.2, 0.3])
    }

    @Test
    func `Delete removes a document and its chunks`() async throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: path)
        let document = try await store.upsertDocument(makeDocument(externalID: "doc", contentHash: "hash-d"))
        _ = try await store.upsertChunks(
            documentID: document.id,
            chunks: [IndexedChunk(documentID: document.id, ordinal: 0, text: "deletable body")]
        )

        let removed = try await store.deleteDocument(id: document.id)
        #expect(removed == true)
        let removedAgain = try await store.deleteDocument(id: document.id)
        #expect(removedAgain == false)

        let stats = try await store.stats()
        #expect(stats.documents == 0)
        #expect(stats.chunks == 0)
        let hits = try await store.searchKeyword(query: "deletable", limit: 10)
        #expect(hits.isEmpty)
    }

    @Test
    func `Prune removes documents older than the cutoff`() async throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: path)
        let old = try await store.upsertDocument(
            makeDocument(externalID: "old", contentHash: "hash-old", indexedAt: Date(timeIntervalSince1970: 1000))
        )
        _ = try await store.upsertChunks(
            documentID: old.id,
            chunks: [IndexedChunk(documentID: old.id, ordinal: 0, text: "expired body")]
        )
        let recent = try await store.upsertDocument(
            makeDocument(externalID: "recent", contentHash: "hash-new", indexedAt: Date(timeIntervalSince1970: 5000))
        )
        _ = try await store.upsertChunks(
            documentID: recent.id,
            chunks: [IndexedChunk(documentID: recent.id, ordinal: 0, text: "fresh body")]
        )

        let removed = try await store.prune(before: Date(timeIntervalSince1970: 3000))
        #expect(removed == 1)

        let stats = try await store.stats()
        #expect(stats.documents == 1)
        #expect(stats.chunks == 1)
        let pruned = try await store.document(source: .files, externalID: "old")
        #expect(pruned == nil)
        let kept = try await store.document(source: .files, externalID: "recent")
        #expect(kept?.externalID == "recent")
        let hits = try await store.searchKeyword(query: "expired", limit: 10)
        #expect(hits.isEmpty)
    }

    @Test
    func `Reset clears documents, chunks, and the search index`() async throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: path)
        let document = try await store.upsertDocument(makeDocument(externalID: "doc", contentHash: "hash-r"))
        _ = try await store.upsertChunks(
            documentID: document.id,
            chunks: [IndexedChunk(documentID: document.id, ordinal: 0, text: "resettable body")]
        )

        try await store.reset()

        let stats = try await store.stats()
        #expect(stats.documents == 0)
        #expect(stats.chunks == 0)
        #expect(stats.bytes == 0)
        let hits = try await store.searchKeyword(query: "resettable", limit: 10)
        #expect(hits.isEmpty)
    }

    @Test
    func `Per-source and extract-status aggregates group real counts`() async throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: path)
        let firstFiles = try await store.upsertDocument(makeDocument(
            externalID: "files-a",
            contentHash: "hash-files-a",
            extractStatus: .extracted
        ))
        _ = try await store.upsertChunks(
            documentID: firstFiles.id,
            chunks: [
                IndexedChunk(documentID: firstFiles.id, ordinal: 0, text: "first files chunk one"),
                IndexedChunk(documentID: firstFiles.id, ordinal: 1, text: "first files chunk two")
            ]
        )
        let secondFiles = try await store.upsertDocument(makeDocument(
            externalID: "files-b",
            contentHash: "hash-files-b",
            extractStatus: .partial
        ))
        _ = try await store.upsertChunks(
            documentID: secondFiles.id,
            chunks: [IndexedChunk(documentID: secondFiles.id, ordinal: 0, text: "second files chunk")]
        )
        let mail = try await store.upsertDocument(makeDocument(
            source: .mail,
            externalID: "mail-a",
            contentHash: "hash-mail-a",
            extractStatus: .failed
        ))
        _ = try await store.upsertChunks(
            documentID: mail.id,
            chunks: [
                IndexedChunk(documentID: mail.id, ordinal: 0, text: "mail chunk one"),
                IndexedChunk(documentID: mail.id, ordinal: 1, text: "mail chunk two"),
                IndexedChunk(documentID: mail.id, ordinal: 2, text: "mail chunk three")
            ]
        )
        _ = try await store.upsertDocument(makeDocument(
            source: .messages,
            externalID: "messages-a",
            contentHash: "hash-messages-a",
            extractStatus: .metadataOnly
        ))

        let stats = try await store.stats()
        #expect(stats.documents == 4)
        #expect(stats.chunks == 6)

        // Per-source aggregates group documents, chunks, and bytes by origin.
        let bySource = Dictionary(uniqueKeysWithValues: stats.bySource.map { ($0.source, $0) })
        #expect(stats.bySource.map(\.source) == [.files, .mail, .messages])
        #expect(bySource[.files]?.documents == 2)
        #expect(bySource[.files]?.chunks == 3)
        #expect((bySource[.files]?.bytes ?? 0) > 0)
        #expect(bySource[.mail]?.documents == 1)
        #expect(bySource[.mail]?.chunks == 3)
        #expect((bySource[.mail]?.bytes ?? 0) > 0)
        // A document without chunks still contributes its document row with
        // zero chunks and bytes.
        #expect(bySource[.messages]?.documents == 1)
        #expect(bySource[.messages]?.chunks == 0)
        #expect(bySource[.messages]?.bytes == 0)
        #expect(stats.bySource.reduce(0) { $0 + $1.documents } == stats.documents)
        #expect(stats.bySource.reduce(0) { $0 + $1.chunks } == stats.chunks)
        #expect(stats.bySource.reduce(0) { $0 + $1.bytes } == stats.bytes)

        // Extraction outcomes group document counts by status.
        let byStatus = Dictionary(uniqueKeysWithValues: stats.byExtractStatus.map { ($0.status, $0) })
        #expect(stats.byExtractStatus.map(\.status) == [.extracted, .partial, .metadataOnly, .failed])
        #expect(byStatus[.extracted]?.documents == 1)
        #expect(byStatus[.partial]?.documents == 1)
        #expect(byStatus[.metadataOnly]?.documents == 1)
        #expect(byStatus[.failed]?.documents == 1)
        #expect(stats.byExtractStatus.reduce(0) { $0 + $1.documents } == stats.documents)
    }

    @Test
    func `Mail documents round-trip source-specific fields`() async throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: path)
        let message = IndexedDocument(
            source: .mail,
            externalID: "uid-42",
            displayName: "Invoice",
            path: nil,
            messageID: "uid-42",
            mailbox: "INBOX",
            mtime: nil,
            sizeBytes: 2048,
            contentHash: "hash-mail",
            mime: "message/rfc822",
            extractStatus: .partial,
            indexedAt: Date(timeIntervalSince1970: 4000),
            metadata: ["account": "icloud"]
        )
        _ = try await store.upsertDocument(message)

        let loaded = try await store.document(source: .mail, externalID: "uid-42")
        #expect(loaded?.messageID == "uid-42")
        #expect(loaded?.mailbox == "INBOX")
        #expect(loaded?.sizeBytes == 2048)
        #expect(loaded?.mime == "message/rfc822")
        #expect(loaded?.extractStatus == .partial)
        #expect(loaded?.metadata["account"] == "icloud")
    }
}

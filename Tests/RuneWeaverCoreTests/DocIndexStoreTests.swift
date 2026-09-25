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

/// Creates a database with the v1 full-text schema to exercise the
/// contentless migration: a porter-tokenized FTS table that stores a second
/// copy of every chunk plus plain rowid triggers.
/// - Parameter path: Database file path.
/// - Returns: Seeded document and chunk identifiers.
private func createV1Index(atPath path: String) throws -> (documentID: UUID, chunkIDs: [UUID]) {
    let documentID = UUID()
    let firstChunkID = UUID()
    let secondChunkID = UUID()
    #if canImport(SQLite3)
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let handle else {
            throw LegacyIndexError.failed("Could not open v1 database")
        }
        defer { sqlite3_close(handle) }
        let schema = """
        CREATE TABLE IF NOT EXISTS schema_meta(
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS indexed_documents(
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
            indexed_at REAL NOT NULL,
            metadata TEXT
        );
        CREATE TABLE IF NOT EXISTS indexed_chunks(
            id TEXT PRIMARY KEY,
            document_id TEXT NOT NULL,
            ordinal INTEGER NOT NULL,
            chunk_text TEXT NOT NULL,
            embedding BLOB,
            is_vector INTEGER NOT NULL DEFAULT 0,
            FOREIGN KEY(document_id) REFERENCES indexed_documents(id) ON DELETE CASCADE
        );
        CREATE VIRTUAL TABLE IF NOT EXISTS indexed_chunks_fts USING fts5(chunk_text, tokenize='porter');
        CREATE TRIGGER IF NOT EXISTS indexed_chunks_ai AFTER INSERT ON indexed_chunks BEGIN
            INSERT INTO indexed_chunks_fts(rowid, chunk_text) VALUES(new.rowid, new.chunk_text);
        END;
        CREATE TRIGGER IF NOT EXISTS indexed_chunks_ad AFTER DELETE ON indexed_chunks BEGIN
            DELETE FROM indexed_chunks_fts WHERE rowid = old.rowid;
        END;
        CREATE TRIGGER IF NOT EXISTS indexed_chunks_au AFTER UPDATE ON indexed_chunks BEGIN
            DELETE FROM indexed_chunks_fts WHERE rowid = old.rowid;
            INSERT INTO indexed_chunks_fts(rowid, chunk_text) VALUES(new.rowid, new.chunk_text);
        END;
        CREATE UNIQUE INDEX IF NOT EXISTS idx_indexed_documents_source_external
            ON indexed_documents(source, external_id);
        """
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, schema, nil, nil, &message) == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(message)
            throw LegacyIndexError.failed(detail)
        }
        let seed = """
        INSERT INTO schema_meta(key, value) VALUES('schema_version', '1');
        INSERT INTO indexed_documents(id, source, external_id, display_name, content_hash, extract_status, indexed_at)
            VALUES('\(documentID.uuidString)', 'files', 'v1-notes', 'Sample', 'hash-v1', 'extracted', 1000);
        INSERT INTO indexed_chunks(id, document_id, ordinal, chunk_text, is_vector)
            VALUES('\(firstChunkID.uuidString)', '\(documentID.uuidString)', 0, 'The biscuit recipe uses butter', 0);
        INSERT INTO indexed_chunks(id, document_id, ordinal, chunk_text, is_vector)
            VALUES('\(secondChunkID.uuidString)', '\(documentID.uuidString)', 1, 'Sourdough starter needs feeding', 0);
        """
        var seedMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, seed, nil, nil, &seedMessage) == SQLITE_OK else {
            let detail = seedMessage.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(seedMessage)
            throw LegacyIndexError.failed(detail)
        }
    #endif
    return (documentID, [firstChunkID, secondChunkID])
}

/// Reads the recorded schema revision for a raw index database.
/// - Parameter path: Database file path.
/// - Returns: Stored revision, or nil when absent.
private func readIndexSchemaVersion(atPath path: String) throws -> Int? {
    #if canImport(SQLite3)
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let handle else {
            throw LegacyIndexError.failed("Could not open database")
        }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT value FROM schema_meta WHERE key = 'schema_version';", -1, &statement, nil) == SQLITE_OK else {
            throw LegacyIndexError.failed("Could not prepare schema version read")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard let text = sqlite3_column_text(statement, 0).map({ String(cString: $0) }) else { return nil }
        return Int(text)
    #else
        return nil
    #endif
}

/// Reports whether a table exists in a raw index database.
/// - Parameters:
///   - path: Database file path.
///   - name: Table name to probe.
/// - Returns: True when a table with that name exists.
private func indexTableExists(atPath path: String, name: String) throws -> Bool {
    #if canImport(SQLite3)
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let handle else {
            throw LegacyIndexError.failed("Could not open database")
        }
        defer { sqlite3_close(handle) }
        let escaped = name.replacingOccurrences(of: "'", with: "''")
        let sql = "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = '\(escaped)';"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw LegacyIndexError.failed("Could not prepare table probe")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return false }
        return sqlite3_column_int(statement, 0) > 0
    #else
        return false
    #endif
}

/// Reads the stored `CREATE` statement for the chunk full-text table.
/// - Parameter path: Database file path.
/// - Returns: The `sqlite_master` definition, or nil when absent.
private func indexFTSDefinition(atPath path: String) throws -> String? {
    #if canImport(SQLite3)
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let handle else {
            throw LegacyIndexError.failed("Could not open database")
        }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        let sql = "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'indexed_chunks_fts';"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw LegacyIndexError.failed("Could not prepare FTS definition read")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_text(statement, 0).map { String(cString: $0) }
    #else
        return nil
    #endif
}

/// Counts direct FTS matches, bypassing the LIKE fallback so trigger sync is
/// observable instead of being masked by the content-table scan.
/// - Parameters:
///   - path: Database file path.
///   - query: Bare FTS query text without surrounding quotes.
/// - Returns: Number of FTS rows matching the query.
private func ftsMatchCount(atPath path: String, query: String) throws -> Int {
    #if canImport(SQLite3)
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let handle else {
            throw LegacyIndexError.failed("Could not open database")
        }
        defer { sqlite3_close(handle) }
        let escaped = query.replacingOccurrences(of: "'", with: "''")
        let sql = "SELECT COUNT(*) FROM indexed_chunks_fts WHERE indexed_chunks_fts MATCH '\(escaped)';"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw LegacyIndexError.failed("Could not prepare FTS count")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    #else
        return 0
    #endif
}

/// Fetches FTS rank values in `ORDER BY rank` order for a query.
/// - Parameters:
///   - path: Database file path.
///   - query: Bare FTS query text without surrounding quotes.
/// - Returns: Rank values in the order SQLite returned them.
private func ftsRanks(atPath path: String, query: String) throws -> [Double] {
    #if canImport(SQLite3)
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let handle else {
            throw LegacyIndexError.failed("Could not open database")
        }
        defer { sqlite3_close(handle) }
        let escaped = query.replacingOccurrences(of: "'", with: "''")
        let sql = "SELECT rank FROM indexed_chunks_fts WHERE indexed_chunks_fts MATCH '\(escaped)' ORDER BY rank;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw LegacyIndexError.failed("Could not prepare rank read")
        }
        defer { sqlite3_finalize(statement) }
        var ranks: [Double] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            ranks.append(sqlite3_column_double(statement, 0))
        }
        return ranks
    #else
        return []
    #endif
}

/// Rewrites a chunk body through raw SQL so the `AFTER UPDATE` trigger fires.
/// - Parameters:
///   - path: Database file path.
///   - chunkID: Chunk row to rewrite.
///   - text: Replacement body without single quotes.
private func updateIndexedChunkText(atPath path: String, chunkID: UUID, text: String) throws {
    #if canImport(SQLite3)
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let handle else {
            throw LegacyIndexError.failed("Could not open database")
        }
        defer { sqlite3_close(handle) }
        let escaped = text.replacingOccurrences(of: "'", with: "''")
        let sql = "UPDATE indexed_chunks SET chunk_text = '\(escaped)' WHERE id = '\(chunkID.uuidString)';"
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &message) == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(message)
            throw LegacyIndexError.failed(detail)
        }
    #endif
}

/// Path guard allowing every candidate, so atomic-commit tests exercise the
/// store without policy interference.
private struct AtomicAllowGuard: FilesIndexAccessGuard {
    func evaluate(path: String, homeDirectoryURL _: URL?) -> FilesIndexAccessDecision {
        FilesIndexAccessDecision(allowed: true, resolvedPath: path)
    }
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

    @Test
    func `V1 database migrates to contentless FTS with preserved hits`() async throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let (documentID, _) = try createV1Index(atPath: path)

        // A v1 index stores chunk text twice: once in the content table and
        // once in the FTS shadow content table.
        #expect(try indexTableExists(atPath: path, name: "indexed_chunks_fts_content") == true)

        // Opening migrates to v2 before the first read.
        let store = DocIndexStore(dbPath: path)
        let hits = try await store.searchKeyword(query: "biscuit", limit: 10)
        #expect(hits.count == 1)
        #expect(hits.first?.documentID == documentID)
        #expect(hits.first?.text.contains("biscuit") == true)

        let second = try await store.searchKeyword(query: "sourdough", limit: 10)
        #expect(second.count == 1)
        #expect(second.first?.documentID == documentID)

        // The migration records v2, drops the shadow content table while
        // keeping the live index, and rebuilds the definition contentless.
        #expect(try readIndexSchemaVersion(atPath: path) == 2)
        #expect(try indexTableExists(atPath: path, name: "indexed_chunks_fts_content") == false)
        let definition = try indexFTSDefinition(atPath: path)
        #expect(definition?.contains("contentless_delete") == true)
    }

    @Test
    func `Chunk triggers stay in sync on insert delete and update`() async throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: path)
        let document = try await store.upsertDocument(makeDocument(externalID: "trigger-doc", contentHash: "hash-trigger"))
        let chunkID = UUID()
        _ = try await store.upsertChunks(
            documentID: document.id,
            chunks: [IndexedChunk(id: chunkID, documentID: document.id, ordinal: 0, text: "trigger sync biscuit alpha")]
        )

        // The insert trigger mirrors the content row into FTS directly, so
        // the count probes FTS instead of the LIKE fallback.
        #expect(try ftsMatchCount(atPath: path, query: "alpha") == 1)
        let inserted = try await store.searchKeyword(query: "alpha", limit: 10)
        #expect(inserted.count == 1)

        // The update trigger swaps the FTS entry by rowid without the delete command.
        try updateIndexedChunkText(atPath: path, chunkID: chunkID, text: "trigger sync biscuit beta")
        #expect(try ftsMatchCount(atPath: path, query: "beta") == 1)
        #expect(try ftsMatchCount(atPath: path, query: "alpha") == 0)

        // The delete trigger removes the FTS entry alongside the content row.
        let removed = try await store.deleteDocument(id: document.id)
        #expect(removed == true)
        #expect(try ftsMatchCount(atPath: path, query: "beta") == 0)
        let afterDelete = try await store.searchKeyword(query: "beta", limit: 10)
        #expect(afterDelete.isEmpty)
    }

    @Test
    func `Contentless FTS keeps rank ordering monotonic`() async throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: path)
        let document = try await store.upsertDocument(makeDocument(externalID: "rank-doc", contentHash: "hash-rank"))
        _ = try await store.upsertChunks(documentID: document.id, chunks: [
            IndexedChunk(documentID: document.id, ordinal: 0, text: "biscuit"),
            IndexedChunk(documentID: document.id, ordinal: 1, text: "biscuit biscuit biscuit"),
            IndexedChunk(documentID: document.id, ordinal: 2, text: "biscuit recipe with butter and honey and jam for breakfast table")
        ])

        // Rank still orders contentless matches: numeric rank arrives in
        // ascending order (non-decreasing) so relevance is non-increasing.
        let ranks = try ftsRanks(atPath: path, query: "biscuit")
        #expect(ranks.count == 3)
        for index in 1 ..< ranks.count {
            #expect(ranks[index] >= ranks[index - 1])
        }

        let hits = try await store.searchKeyword(query: "biscuit", limit: 10)
        #expect(hits.count == 3)
    }

    @Test
    func `Stats reports true on-disk size`() async throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: path)
        let document = try await store.upsertDocument(makeDocument(externalID: "sized-doc", contentHash: "hash-sized"))
        _ = try await store.upsertChunks(documentID: document.id, chunks: [
            IndexedChunk(documentID: document.id, ordinal: 0, text: "sized vector chunk", embedding: [0.1, 0.2, 0.3]),
            IndexedChunk(documentID: document.id, ordinal: 1, text: "sized keyword chunk")
        ])

        // File bytes ride the shared on-disk helper so the status surface tracks
        // the database file instead of the logical text total. Content is text
        // plus vectors through the single shared definition.
        let stats = try await store.stats()
        #expect(stats.dbFileBytes > 0)
        #expect(stats.freeBytes >= 0)
        #expect(stats.walBytes >= 0)
        #expect(stats.dbFileBytes >= stats.contentBytes)
        #expect(stats.contentBytes == IndexContentBytes.contentBytes(textBytes: stats.bytes, vectorBytes: stats.vectorBytes ?? 0))
        #expect(stats.bytes > 0)
        #if canImport(SQLite3)
            #expect(stats.textBytes != nil)
            #expect(stats.vectorBytes != nil)
            #expect(stats.ftsBytes != nil)
            let split = (stats.textBytes ?? 0) + (stats.vectorBytes ?? 0) + (stats.ftsBytes ?? 0)
            #expect(split <= stats.dbFileBytes)
        #endif
    }

    @Test
    func `Stats still reports file size when dbstat is unavailable`() async throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: path)
        let document = try await store.upsertDocument(makeDocument(externalID: "nodstat-doc", contentHash: "hash-nodbstat"))
        _ = try await store.upsertChunks(
            documentID: document.id,
            chunks: [IndexedChunk(documentID: document.id, ordinal: 0, text: "durable chunk")]
        )

        // A missing size table degrades to file sizes with a null split
        // instead of failing the probe. The probe is injected directly so
        // parallel tests never share global size state.
        #if canImport(SQLite3)
            let stats = try SQLiteDocIndexStore.stats(dbPath: path, dbstatProbe: { _ in nil })
            #expect(stats.dbFileBytes > 0)
            #expect(stats.freeBytes >= 0)
            #expect(stats.dbFileBytes >= stats.contentBytes)
            #expect(stats.textBytes == nil)
            #expect(stats.vectorBytes == nil)
            #expect(stats.ftsBytes == nil)
            let breakdown = try SQLiteDocIndexStore.storageBreakdown(dbPath: path, dbstatProbe: { _ in nil })
            #expect(breakdown.dbFileBytes > 0)
        #else
            let stats = try await store.stats()
            #expect(stats.dbFileBytes > 0)
            #expect(stats.freeBytes >= 0)
            #expect(stats.dbFileBytes >= stats.contentBytes)
        #endif
    }

    @Test
    func `Atomic commit lands document chunks and stamp together`() async throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: path)
        let document = makeDocument(externalID: "atomic-doc", contentHash: "hash-atomic")
        let chunks = [
            IndexedChunk(documentID: document.id, ordinal: 0, text: "atomic biscuit body"),
            IndexedChunk(documentID: document.id, ordinal: 1, text: "second atomic chunk", embedding: [0.1, 0.2])
        ]
        let runID = "run-atomic-\(UUID().uuidString)"

        // One call carries the document row, both chunk rows, and the stamp.
        let stored = try await store.upsertDocumentWithChunks(document: document, chunks: chunks, runID: runID)
        #expect(stored.id == document.id)

        let loaded = try await store.document(source: .files, externalID: "atomic-doc")
        #expect(loaded?.contentHash == "hash-atomic")
        let stats = try await store.stats()
        #expect(stats.documents == 1)
        #expect(stats.chunks == 2)
        #expect(stats.vectorChunks == 1)
        let hits = try await store.searchKeyword(query: "biscuit", limit: 10)
        #expect(hits.count == 1)
        #expect(hits.first?.documentID == stored.id)

        // The stamp rode the same commit, so the reconcile keeps the row for
        // this run yet retires it for any other run.
        let kept = try await store.retireUnseenFiles(runID: runID)
        #expect(kept == 0)
        let keptStats = try await store.stats()
        #expect(keptStats.documents == 1)
        let retired = try await store.retireUnseenFiles(runID: "run-atomic-other-\(UUID().uuidString)")
        #expect(retired == 1)
        let retiredStats = try await store.stats()
        #expect(retiredStats.documents == 0)
    }

    @Test
    func `Atomic commit rolls back document and stamp on chunk failure`() async throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: path)

        // A duplicated chunk identifier violates the primary key, aborting the
        // whole commit before anything becomes visible.
        let fresh = makeDocument(externalID: "rollback-new", contentHash: "hash-rollback-new")
        let collidingID = UUID()
        let badChunks = [
            IndexedChunk(id: collidingID, documentID: fresh.id, ordinal: 0, text: "first rollback chunk"),
            IndexedChunk(id: collidingID, documentID: fresh.id, ordinal: 1, text: "second rollback chunk")
        ]
        do {
            _ = try await store.upsertDocumentWithChunks(
                document: fresh,
                chunks: badChunks,
                runID: "run-rollback-\(UUID().uuidString)"
            )
            #expect(Bool(false), "Expected the colliding chunk identifiers to throw")
        } catch {
            // The colliding primary key aborts the commit; nothing may survive.
        }
        let missing = try await store.document(source: .files, externalID: "rollback-new")
        #expect(missing == nil)
        let emptyStats = try await store.stats()
        #expect(emptyStats.documents == 0)
        #expect(emptyStats.chunks == 0)
        let emptyHits = try await store.searchKeyword(query: "rollback", limit: 10)
        #expect(emptyHits.isEmpty)

        // A later failed rewrite must leave the seeded row, its chunks, and
        // its stamp untouched rather than stranding the new stamp.
        let seededDoc = makeDocument(externalID: "rollback-existing", contentHash: "hash-old")
        let seedRun = "run-seed-\(UUID().uuidString)"
        let seeded = try await store.upsertDocumentWithChunks(
            document: seededDoc,
            chunks: [IndexedChunk(documentID: seededDoc.id, ordinal: 0, text: "seeded rollback body")],
            runID: seedRun
        )
        let rewrite = makeDocument(externalID: "rollback-existing", contentHash: "hash-new")
        let failedRun = "run-rewrite-\(UUID().uuidString)"
        let rewriteChunks = [
            IndexedChunk(id: collidingID, documentID: rewrite.id, ordinal: 0, text: "rewrite first"),
            IndexedChunk(id: collidingID, documentID: rewrite.id, ordinal: 1, text: "rewrite second")
        ]
        do {
            _ = try await store.upsertDocumentWithChunks(document: rewrite, chunks: rewriteChunks, runID: failedRun)
            #expect(Bool(false), "Expected the rewrite collision to throw")
        } catch {
            // A failed rewrite rolls back to the seeded revision.
        }
        let kept = try await store.document(source: .files, externalID: "rollback-existing")
        #expect(kept?.contentHash == "hash-old")
        #expect(kept?.id == seeded.id)
        let keptHits = try await store.searchKeyword(query: "seeded", limit: 10)
        #expect(keptHits.count == 1)
        let keptRetire = try await store.retireUnseenFiles(runID: seedRun)
        #expect(keptRetire == 0)
        let staleRetire = try await store.retireUnseenFiles(runID: failedRun)
        #expect(staleRetire == 1)
    }

    @Test
    func `Candidate write failure still stamps the pre-existing row`() async throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: path)
        let canonicalPath = base.appendingPathComponent("note.txt").path

        // Seed a live row so the failed rewrite has a prior revision to keep.
        let seedRun = "run-candidate-seed-\(UUID().uuidString)"
        let seedDoc = makeDocument(
            externalID: canonicalPath,
            displayName: "note.txt",
            contentHash: "hash-old",
            path: canonicalPath
        )
        _ = try await store.upsertDocumentWithChunks(
            document: seedDoc,
            chunks: [IndexedChunk(documentID: seedDoc.id, ordinal: 0, text: "seeded candidate body")],
            runID: seedRun
        )

        // Fail only the new body so parallel stores writing other text stay green.
        let marker = "candidate-fallback-\(UUID().uuidString)"
        #if canImport(SQLite3)
            SQLiteDocIndexStore.chunkInsertFailureHook = { $0.text.contains(marker) }
            defer { SQLiteDocIndexStore.chunkInsertFailureHook = nil }
        #endif
        let runID = "run-candidate-\(UUID().uuidString)"
        let identity = FilesIndexer.CandidateIdentity(
            fileURL: URL(fileURLWithPath: canonicalPath),
            root: base,
            runID: runID
        )
        let services = FilesIndexer.CandidateServices(
            store: store,
            extractor: DocumentTextExtractor(),
            embedder: nil,
            embeddingsPool: nil,
            accessGuard: AtomicAllowGuard(),
            vectorPolicy: FilesVectorPolicy()
        )
        let policy = FilesIndexer.CandidatePolicy(
            config: IndexConfig(enabled: true, files: true, roots: [base.path]),
            homeDirectoryURL: base,
            evictedCheck: nil,
            downloadStarter: nil,
            fileReader: nil
        )
        let state = FilesIndexer.CandidateRunState(
            budget: FilesIndexer.FileIndexBudget(limit: 0),
            cancellation: IndexCancellationFlag()
        )
        let resolved = FilesIndexer.ResolvedCandidate(
            canonicalURL: URL(fileURLWithPath: canonicalPath),
            canonicalPath: canonicalPath,
            relative: "note.txt",
            filename: "note.txt",
            maxBytes: 20 * 1024 * 1024
        )
        let payload = FilesIndexer.CandidatePayload(
            modificationDate: nil,
            data: Data("new body".utf8),
            contentHash: "hash-new",
            extraction: DocumentExtraction(
                status: .extracted,
                format: .plainText,
                chunks: [DocumentChunk(index: 0, text: "\(marker) new body", estimatedTokens: 1)],
                reason: nil,
                byteCount: 8,
                truncated: false
            ),
            vectors: nil
        )
        let outcome = await FilesIndexer.commitCandidateDocument(
            identity: identity,
            services: services,
            policy: policy,
            state: state,
            resolved: resolved,
            payload: payload
        )
        switch outcome.kind {
        case .error:
            break
        default:
            #expect(Bool(false), "Expected an error outcome for the failed write")
        }

        // The fallback stamp kept the prior revision live for this run.
        let stored = try await store.document(source: .files, externalID: canonicalPath)
        #expect(stored != nil)
        #expect(stored?.contentHash == "hash-old")
        let retired = try await store.retireUnseenFiles(runID: runID)
        #expect(retired == 0)
    }
}

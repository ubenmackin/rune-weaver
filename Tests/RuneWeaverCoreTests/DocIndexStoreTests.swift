// Rune Weaver Core Tests — Document index store schema, hashing, search, and maintenance.

import Foundation
import os
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

/// Names the isolated sidecar targets a store reset must take so the test never deletes the
/// operator's real mail checkpoint or Messages watermark. - Parameter base: Test-owned scratch
/// directory.
private func makeIndexResetSidecars(base: URL) -> (mailCheckpointPath: String, messagesStatePath: String) {
    (
        mailCheckpointPath: base.appendingPathComponent("mail-index-checkpoint.json").path,
        messagesStatePath: base.appendingPathComponent("messages-state.json").path
    )
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

#if canImport(SQLite3)
    /// Opens a raw probe handle with the production busy-timeout. Mirrors
    /// `SQLiteHelpers.openHandle`'s `busy_timeout = 5000` so a probe racing a parallel aggregate
    /// refresh waits instead of failing with `SQLITE_BUSY`.
    private func openIndexProbe(atPath path: String) throws -> OpaquePointer {
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let opened = handle else {
            throw LegacyIndexError.failed("Could not open database")
        }
        _ = sqlite3_busy_timeout(opened, 5000)
        return opened
    }
#endif

/// Creates a database with the pre-metadata document schema to exercise the
/// additive column migration.
/// - Parameter path: Database file path.
private func createLegacyIndex(atPath path: String) throws {
    #if canImport(SQLite3)
        let handle = try openIndexProbe(atPath: path)
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

/// Creates a database with the v1 full-text schema to exercise the contentless migration: a
/// porter-tokenized FTS table that stores a second copy of every chunk plus plain rowid triggers.
private func createV1Index(atPath path: String) throws -> (documentID: UUID, chunkIDs: [UUID]) {
    let documentID = UUID()
    let firstChunkID = UUID()
    let secondChunkID = UUID()
    #if canImport(SQLite3)
        let handle = try openIndexProbe(atPath: path)
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
        let handle = try openIndexProbe(atPath: path)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT value FROM schema_meta WHERE key = 'schema_version';", -1, &statement, nil) == SQLITE_OK else {
            throw LegacyIndexError.failed("Could not prepare schema version read")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0).map({ String(cString: $0) }) else { return nil }
        return Int(text)
    #else
        return nil
    #endif
}

/// Reports whether a table exists in a raw index database. path: Database file
/// path.
private func indexTableExists(atPath path: String, name: String) throws -> Bool {
    #if canImport(SQLite3)
        let handle = try openIndexProbe(atPath: path)
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
        let handle = try openIndexProbe(atPath: path)
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

/// Counts direct FTS matches, bypassing the LIKE fallback so trigger sync is observable instead of
/// being masked by the content-table scan. path: Database file path.
private func ftsMatchCount(atPath path: String, query: String) throws -> Int {
    #if canImport(SQLite3)
        let handle = try openIndexProbe(atPath: path)
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

/// Fetches FTS rank values in `ORDER BY rank` order for a query. path: Database
/// file path.
private func ftsRanks(atPath path: String, query: String) throws -> [Double] {
    #if canImport(SQLite3)
        let handle = try openIndexProbe(atPath: path)
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

/// Rewrites a chunk body through raw SQL so the `AFTER UPDATE` trigger fires. path:
/// Database file path.
private func updateIndexedChunkText(atPath path: String, chunkID: UUID, text: String) throws {
    #if canImport(SQLite3)
        let handle = try openIndexProbe(atPath: path)
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

/// Removes one document row through raw SQL, leaving its chunks orphaned.
private func deleteIndexedDocumentRow(atPath path: String, documentID: UUID) throws {
    #if canImport(SQLite3)
        let handle = try openIndexProbe(atPath: path)
        defer { sqlite3_close(handle) }
        let sql = "DELETE FROM indexed_documents WHERE id = '\(documentID.uuidString)';"
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &message) == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(message)
            throw LegacyIndexError.failed(detail)
        }
    #endif
}

/// Reads the schema-change counter without running any store ensure.
private func readIndexDataVersion(atPath path: String) throws -> Int {
    #if canImport(SQLite3)
        let handle = try openIndexProbe(atPath: path)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA data_version;", -1, &statement, nil) == SQLITE_OK else {
            throw LegacyIndexError.failed("Could not prepare data version read")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw LegacyIndexError.failed("Could not step data version read")
        }
        return Int(sqlite3_column_int64(statement, 0))
    #else
        return 0
    #endif
}

/// Persisted single-row aggregate read back through raw SQL.
private struct AggregateSingleRow: Equatable {
    var documents: Int
    var chunks: Int
    var vectorChunks: Int
    var textBytes: Int64
    var vectorBytes: Int64
    var ftsBytes: Int64?
    var indexAsOf: Double
    var producingRunID: String?
}

/// Reads the single `index_aggregates` row through raw SQL.
private func readAggregateSingle(atPath path: String) throws -> AggregateSingleRow? {
    #if canImport(SQLite3)
        let handle = try openIndexProbe(atPath: path)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        let sql = "SELECT documents, chunks, vector_chunks, text_bytes, vector_bytes, fts_bytes, index_as_of, producing_run_id FROM index_aggregates WHERE id = 0;"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw LegacyIndexError.failed("Could not prepare aggregate read")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let ftsBytes: Int64? = sqlite3_column_type(statement, 5) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 5)
        let producing: String? = sqlite3_column_text(statement, 7).map { String(cString: $0) }
        return AggregateSingleRow(
            documents: Int(sqlite3_column_int64(statement, 0)),
            chunks: Int(sqlite3_column_int64(statement, 1)),
            vectorChunks: Int(sqlite3_column_int64(statement, 2)),
            textBytes: sqlite3_column_int64(statement, 3),
            vectorBytes: sqlite3_column_int64(statement, 4),
            ftsBytes: ftsBytes,
            indexAsOf: sqlite3_column_double(statement, 6),
            producingRunID: producing
        )
    #else
        return nil
    #endif
}

/// Reads per-source aggregate rows through raw SQL.
/// - Parameter path: Database file path.
/// - Returns: Mapping from source string to stored counts.
private func readAggregateBySource(atPath path: String) throws -> [String: (documents: Int, chunks: Int, bytes: Int64)] {
    #if canImport(SQLite3)
        let handle = try openIndexProbe(atPath: path)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT source, documents, chunks, bytes FROM index_aggregate_by_source;", -1, &statement, nil) == SQLITE_OK else {
            throw LegacyIndexError.failed("Could not prepare source aggregate read")
        }
        defer { sqlite3_finalize(statement) }
        var rows: [String: (documents: Int, chunks: Int, bytes: Int64)] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let source = sqlite3_column_text(statement, 0).map({ String(cString: $0) }) else { continue }
            rows[source] = (
                documents: Int(sqlite3_column_int64(statement, 1)),
                chunks: Int(sqlite3_column_int64(statement, 2)),
                bytes: sqlite3_column_int64(statement, 3)
            )
        }
        return rows
    #else
        return [:]
    #endif
}

/// Reads per-status aggregate rows through raw SQL.
/// - Parameter path: Database file path.
/// - Returns: Mapping from status string to stored document counts.
private func readAggregateByStatus(atPath path: String) throws -> [String: Int] {
    #if canImport(SQLite3)
        let handle = try openIndexProbe(atPath: path)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT status, documents FROM index_aggregate_by_extract_status;", -1, &statement, nil) == SQLITE_OK else {
            throw LegacyIndexError.failed("Could not prepare status aggregate read")
        }
        defer { sqlite3_finalize(statement) }
        var rows: [String: Int] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let status = sqlite3_column_text(statement, 0).map({ String(cString: $0) }) else { continue }
            rows[status] = Int(sqlite3_column_int64(statement, 1))
        }
        return rows
    #else
        return [:]
    #endif
}

/// Clears the persisted aggregate rows without touching actor state.
private func clearAggregateRows(atPath path: String) throws {
    #if canImport(SQLite3)
        let handle = try openIndexProbe(atPath: path)
        defer { sqlite3_close(handle) }
        var message: UnsafeMutablePointer<CChar>?
        let sql = "DELETE FROM index_aggregates; DELETE FROM index_aggregate_by_source; DELETE FROM index_aggregate_by_extract_status;"
        guard sqlite3_exec(handle, sql, nil, nil, &message) == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(message)
            throw LegacyIndexError.failed(detail)
        }
    #endif
}

/// Seeds one document per extraction outcome across all three sources.
private func seedAggregateFixture(store: DocIndexStore) async throws {
    let extractedFiles = try await store.upsertDocument(makeDocument(externalID: "agg-files-extracted", contentHash: "hash-agg-extracted", extractStatus: .extracted))
    _ = try await store.upsertChunks(documentID: extractedFiles.id, chunks: [
        IndexedChunk(documentID: extractedFiles.id, ordinal: 0, text: "aggregate vector body", embedding: [0.1, 0.2]),
        IndexedChunk(documentID: extractedFiles.id, ordinal: 1, text: "aggregate keyword body")
    ])
    let partialFiles = try await store.upsertDocument(makeDocument(externalID: "agg-files-partial", contentHash: "hash-agg-partial", extractStatus: .partial))
    _ = try await store.upsertChunks(documentID: partialFiles.id, chunks: [
        IndexedChunk(documentID: partialFiles.id, ordinal: 0, text: "aggregate partial body")
    ])
    let metadataMail = try await store.upsertDocument(makeDocument(source: .mail, externalID: "agg-mail-metadata", contentHash: "hash-agg-metadata", extractStatus: .metadataOnly))
    _ = try await store.upsertChunks(documentID: metadataMail.id, chunks: [
        IndexedChunk(documentID: metadataMail.id, ordinal: 0, text: "aggregate mail body")
    ])
    _ = try await store.upsertDocument(makeDocument(source: .mail, externalID: "agg-mail-unsupported", contentHash: "hash-agg-unsupported", extractStatus: .unsupported))
    let skippedMessages = try await store.upsertDocument(makeDocument(
        source: .messages,
        externalID: "agg-messages-skipped",
        contentHash: "hash-agg-skipped",
        extractStatus: .skippedEvicted
    ))
    _ = try await store.upsertChunks(documentID: skippedMessages.id, chunks: [
        IndexedChunk(documentID: skippedMessages.id, ordinal: 0, text: "aggregate skipped body")
    ])
    let failedMessages = try await store.upsertDocument(makeDocument(source: .messages, externalID: "agg-messages-failed", contentHash: "hash-agg-failed", extractStatus: .failed))
    _ = try await store.upsertChunks(documentID: failedMessages.id, chunks: [
        IndexedChunk(documentID: failedMessages.id, ordinal: 0, text: "aggregate failed body")
    ])
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
    func `Vector pool orders by event time with a rowid tie-break`() async throws {
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

        // Pool order is event time — the parent `mtime` descending with NULL parents last — so the
        // bounded semantic pool favors recently happening documents at scale instead of recently
        // written rows.
        let newestOnly = try await store.chunkVectors(limit: 1)
        #expect(newestOnly.count == 1)
        #expect(newestOnly.first?.documentID == newer.id)
        let both = try await store.chunkVectors(limit: 10)
        #expect(both.count == 2)
        #expect(both.first?.documentID == newer.id)
        #expect(both.last?.documentID == older.id)
    }

    @Test
    func `Orphan chunks stay semantic candidates in the unbounded vector read`() async throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: path)
        let recent = try await store.upsertDocument(IndexedDocument(
            source: .files,
            externalID: "orphan-recent",
            displayName: "Recent",
            mtime: Date(timeIntervalSince1970: 9000),
            contentHash: "hash-orphan-recent"
        ))
        _ = try await store.upsertChunks(
            documentID: recent.id,
            chunks: [IndexedChunk(documentID: recent.id, ordinal: 0, text: "recent vector", embedding: [1.0, 0.0])]
        )
        let stale = try await store.upsertDocument(IndexedDocument(
            source: .files,
            externalID: "orphan-stale",
            displayName: "Stale",
            mtime: Date(timeIntervalSince1970: 1000),
            contentHash: "hash-orphan-stale"
        ))
        _ = try await store.upsertChunks(
            documentID: stale.id,
            chunks: [IndexedChunk(documentID: stale.id, ordinal: 0, text: "stale vector", embedding: [0.0, 1.0])]
        )
        let doomed = try await store.upsertDocument(IndexedDocument(
            source: .files,
            externalID: "orphan-doomed",
            displayName: "Doomed",
            mtime: Date(timeIntervalSince1970: 5000),
            contentHash: "hash-orphan-doomed"
        ))
        let orphanChunk = IndexedChunk(documentID: doomed.id, ordinal: 0, text: "orphan vector", embedding: [1.0, 1.0])
        _ = try await store.upsertChunks(documentID: doomed.id, chunks: [orphanChunk])

        // Dropping the parent row without the cascade strands its chunk, so the
        // recall path must still treat that chunk as a candidate.
        try deleteIndexedDocumentRow(atPath: path, documentID: doomed.id)

        // The unbounded read left-joins the parent to reach `mtime`, so a chunk whose document row
        // is missing stays a semantic candidate; its NULL event time sorts last behind every dated
        // parent, so undated rows never crowd out recently happening documents.
        let pool = try await store.chunkVectors(limit: 10)
        #expect(pool.count == 3)
        #expect(pool.first?.documentID == recent.id)
        #expect(pool[1].documentID == stale.id)
        #expect(pool.last?.id == orphanChunk.id)
        #expect(pool.last?.documentID == doomed.id)
        #expect(pool.last?.text == "orphan vector")
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

        // Sidecar targets are required and name this test's scratch files, so
        // the reset never clears the operator's live state.
        let sidecars = makeIndexResetSidecars(base: base)
        try await store.reset(mailCheckpointPath: sidecars.mailCheckpointPath, messagesStatePath: sidecars.messagesStatePath)

        let stats = try await store.stats()
        #expect(stats.documents == 0)
        #expect(stats.chunks == 0)
        #expect(stats.bytes == 0)
        let hits = try await store.searchKeyword(query: "resettable", limit: 10)
        #expect(hits.isEmpty)
    }

    @Test
    func `Clear source purges only target source and leaves other sources intact`() async throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: path)

        let msgDoc = try await store.upsertDocument(makeDocument(
            source: .messages,
            externalID: "msg-1",
            contentHash: "hash-msg"
        ))
        _ = try await store.upsertChunks(
            documentID: msgDoc.id,
            chunks: [IndexedChunk(documentID: msgDoc.id, ordinal: 0, text: "message text")]
        )

        let mailDoc = try await store.upsertDocument(makeDocument(
            source: .mail,
            externalID: "mail-1",
            contentHash: "hash-mail"
        ))
        _ = try await store.upsertChunks(
            documentID: mailDoc.id,
            chunks: [IndexedChunk(documentID: mailDoc.id, ordinal: 0, text: "mail text")]
        )

        let sidecars = makeIndexResetSidecars(base: base)
        try JSONEncoder().encode(MessagesIndexState(lastRowID: 99)).write(
            to: URL(fileURLWithPath: sidecars.messagesStatePath),
            options: .atomic
        )
        #expect(FileManager.default.fileExists(atPath: sidecars.messagesStatePath))

        // Clear only .messages
        try await store.clearSource(.messages, messagesStatePath: sidecars.messagesStatePath)

        // Watermark file should be removed
        #expect(!FileManager.default.fileExists(atPath: sidecars.messagesStatePath))

        // Messages document and chunk should be gone
        let foundMsg = try await store.document(source: .messages, externalID: "msg-1")
        #expect(foundMsg == nil)
        let msgHits = try await store.searchKeyword(query: "message", limit: 5)
        #expect(msgHits.isEmpty)

        // Mail document and chunk should still exist
        let foundMail = try await store.document(source: .mail, externalID: "mail-1")
        #expect(foundMail != nil)
        let mailHits = try await store.searchKeyword(query: "mail", limit: 5)
        #expect(mailHits.count == 1)
    }

    @Test
    func `Clear mail source resets the mail checkpoint and leaves the messages watermark intact`() async throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: path)

        let mailDoc = try await store.upsertDocument(makeDocument(
            source: .mail,
            externalID: "mail-ckpt-1",
            contentHash: "hash-mail-ckpt"
        ))
        _ = try await store.upsertChunks(
            documentID: mailDoc.id,
            chunks: [IndexedChunk(documentID: mailDoc.id, ordinal: 0, text: "mail checkpoint text")]
        )

        let sidecars = makeIndexResetSidecars(base: base)
        try Data("{}".utf8).write(
            to: URL(fileURLWithPath: sidecars.mailCheckpointPath),
            options: .atomic
        )
        try Data("{}".utf8).write(
            to: URL(fileURLWithPath: sidecars.messagesStatePath),
            options: .atomic
        )
        #expect(FileManager.default.fileExists(atPath: sidecars.mailCheckpointPath))
        #expect(FileManager.default.fileExists(atPath: sidecars.messagesStatePath))

        // Clear only .mail
        try await store.clearSource(
            .mail,
            mailCheckpointPath: sidecars.mailCheckpointPath,
            messagesStatePath: sidecars.messagesStatePath
        )

        // Mail checkpoint file should be removed so purged mail re-indexes
        #expect(!FileManager.default.fileExists(atPath: sidecars.mailCheckpointPath))
        // Messages watermark file should remain intact
        #expect(FileManager.default.fileExists(atPath: sidecars.messagesStatePath))

        // Mail document and chunk should be gone
        let foundMail = try await store.document(source: .mail, externalID: "mail-ckpt-1")
        #expect(foundMail == nil)
        let mailHits = try await store.searchKeyword(query: "mail", limit: 5)
        #expect(mailHits.isEmpty)
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
        // this run yet retires it for any other run. Fresh stores bypass the
        // TTL cache so the checks observe the writes instead of a stale poll.
        let kept = try await store.retireUnseenFiles(runID: runID)
        #expect(kept == 0)
        let keptStats = try await DocIndexStore(dbPath: path).stats()
        #expect(keptStats.documents == 1)
        let retired = try await store.retireUnseenFiles(runID: "run-atomic-other-\(UUID().uuidString)")
        #expect(retired == 1)
        let retiredStats = try await DocIndexStore(dbPath: path).stats()
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
            #expect(!error.localizedDescription.isEmpty)
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
            #expect(!error.localizedDescription.isEmpty)
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
    func `Status cache returns identical snapshot inside TTL without new writes`() async throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }
        #if canImport(SQLite3)
            SQLiteDocIndexStore.removeEnsuredPath(path)
            SQLiteDocIndexStore.resetStatusSnapshotComputeCountForTesting(for: path)
        #endif
        let frozen = Date(timeIntervalSince1970: 9000)
        let store = DocIndexStore(dbPath: path, clock: { frozen })
        let document = try await store.upsertDocument(makeDocument(externalID: "cached-doc", contentHash: "hash-cached"))
        _ = try await store.upsertChunks(
            documentID: document.id,
            chunks: [IndexedChunk(documentID: document.id, ordinal: 0, text: "cached body")]
        )

        #if canImport(SQLite3)
            SQLiteDocIndexStore.resetStatusSnapshotComputeCountForTesting(for: path)
        #endif
        // The first poll fills the cache with one aggregate pass.
        let first = try await store.stats()
        #expect(first.documents == 1)
        #expect(first.chunks == 1)
        #if canImport(SQLite3)
            #expect(SQLiteDocIndexStore.statusSnapshotComputeCount(for: path) == 1)
        #endif

        // A repeat poll without time passing reuses the snapshot, so it
        // returns identical values with zero fresh aggregate queries.
        let second = try await store.stats()
        #expect(second == first)
        #if canImport(SQLite3)
            #expect(SQLiteDocIndexStore.statusSnapshotComputeCount(for: path) == 1)
        #endif

        // Freeze-then-jump: writes invalidate the memory snapshot, so the next poll serves the
        // persisted row frozen with zero aggregate passes.
        _ = try await store.upsertDocument(makeDocument(externalID: "cached-doc-2", contentHash: "hash-cached-2"))
        let fresh = try await store.stats()
        #expect(fresh == first)
        #expect(fresh.documents == 1)
        #if canImport(SQLite3)
            #expect(SQLiteDocIndexStore.statusSnapshotComputeCount(for: path) == 1)
        #endif

        // An explicit refresh jumps the persisted row forward, revealing the
        // previously frozen write with one aggregate pass.
        _ = try await store.refreshAggregates()
        let jumped = try await store.stats()
        #expect(jumped != first)
        #expect(jumped.documents == 2)
        #if canImport(SQLite3)
            #expect(SQLiteDocIndexStore.statusSnapshotComputeCount(for: path) == 2)
        #endif
    }

    @Test
    func `Status cache recomputes after TTL using injectable clock`() async throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }
        #if canImport(SQLite3)
            SQLiteDocIndexStore.removeEnsuredPath(path)
            SQLiteDocIndexStore.resetStatusSnapshotComputeCountForTesting(for: path)
        #endif
        let timeLock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 20000))
        let store = DocIndexStore(dbPath: path, clock: { timeLock.withLock { $0 } })
        _ = try await store.upsertDocument(makeDocument(externalID: "ttl-doc-1", contentHash: "hash-ttl-1"))

        let first = try await store.stats()
        #expect(first.documents == 1)

        // Freeze-then-jump: a write invalidates the memory snapshot, so the
        // next poll serves the persisted row frozen with zero aggregate
        // passes even though the TTL has not lapsed.
        _ = try await store.upsertDocument(makeDocument(externalID: "ttl-doc-2", contentHash: "hash-ttl-2"))
        let invalidated = try await store.stats()
        #expect(invalidated.documents == 1)
        #expect(invalidated == first)

        // Advancing the injectable clock past the TTL still serves the
        // persisted row frozen: the TTL gates the memory snapshot only, and
        // a cold poll serves single-row reads without a content scan.
        timeLock.withLock { $0 = $0.addingTimeInterval(DocIndexStore.statsCacheTTLSeconds + 1) }
        let refreshed = try await store.stats()
        #expect(refreshed.documents == 1)
        #expect(refreshed == first)

        // An explicit refresh jumps the persisted row forward, revealing the
        // previously frozen write.
        _ = try await store.refreshAggregates()
        let jumped = try await store.stats()
        #expect(jumped.documents == 2)
        #expect(jumped != first)
    }

    @Test
    func `Repeated opens leave schema version counter unchanged`() async throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }
        #if canImport(SQLite3)
            SQLiteDocIndexStore.removeEnsuredPath(path)
        #endif
        let store = DocIndexStore(dbPath: path)
        _ = try await store.upsertDocument(makeDocument(externalID: "ensure-doc", contentHash: "hash-ensure"))

        // The first ensure has landed; the counter now reflects a migrated schema.
        let before = try readIndexDataVersion(atPath: path)

        // A second store over the same canonical path must take the fast path:
        // open plus the foreign-key pragma only, with zero DDL writes.
        let second = DocIndexStore(dbPath: path)
        _ = try await second.document(source: .files, externalID: "ensure-doc")
        let afterRead = try readIndexDataVersion(atPath: path)
        #expect(afterRead == before)

        _ = try await second.stats()
        let afterStats = try readIndexDataVersion(atPath: path)
        #expect(afterStats == before)
    }

    @Test
    func `Stats and breakdown agree field for field on one fixture`() async throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: path)
        // One fixture exercising every aggregate leg: per-source GROUP BYs,
        // the extract-status GROUP BY, both SUM(LENGTH) legs, and the dbstat walk.
        let firstFiles = try await store.upsertDocument(makeDocument(externalID: "agree-files-a", contentHash: "hash-agree-a"))
        _ = try await store.upsertChunks(documentID: firstFiles.id, chunks: [
            IndexedChunk(documentID: firstFiles.id, ordinal: 0, text: "agree vector chunk", embedding: [0.1, 0.2]),
            IndexedChunk(documentID: firstFiles.id, ordinal: 1, text: "agree keyword chunk")
        ])
        let mail = try await store.upsertDocument(makeDocument(
            source: .mail,
            externalID: "agree-mail-a",
            contentHash: "hash-agree-mail",
            extractStatus: .partial
        ))
        _ = try await store.upsertChunks(
            documentID: mail.id,
            chunks: [IndexedChunk(documentID: mail.id, ordinal: 0, text: "agree mail body")]
        )

        // Both projections share one cached snapshot, so they agree exactly.
        let stats = try await store.stats()
        let breakdown = try await store.storageBreakdown()
        #expect(breakdown.dbFileBytes == stats.dbFileBytes)
        #expect(breakdown.walBytes == stats.walBytes)
        #expect(breakdown.textBytes == stats.bytes)
        #expect(breakdown.freeBytes == stats.freeBytes)
        #expect(breakdown.contentBytes == stats.contentBytes)
        #expect(breakdown.contentBytes == IndexContentBytes.contentBytes(
            textBytes: stats.bytes,
            vectorBytes: stats.vectorBytes ?? 0
        ))
        #if canImport(SQLite3)
            #expect(stats.textBytes != nil)
            #expect(stats.vectorBytes != nil)
            #expect(stats.ftsBytes != nil)
            #expect(breakdown.textBytes == (stats.textBytes ?? -1))
            #expect(breakdown.vectorBytes == (stats.vectorBytes ?? -1))
            #expect(breakdown.ftsBytes == (stats.ftsBytes ?? -1))
        #endif

        // A cold store over the same file recomputes from scratch yet matches
        // the cached values exactly, proving the cache never drifts.
        let cold = DocIndexStore(dbPath: path)
        let freshStats = try await cold.stats()
        #expect(freshStats == stats)
        let freshBreakdown = try await cold.storageBreakdown()
        #expect(freshBreakdown == breakdown)
    }

    @Test
    func `Status projections share one aggregate pass inside TTL`() async throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }
        #if canImport(SQLite3)
            SQLiteDocIndexStore.removeEnsuredPath(path)
            SQLiteDocIndexStore.resetStatusSnapshotComputeCountForTesting(for: path)
        #endif
        let frozen = Date(timeIntervalSince1970: 31000)
        let store = DocIndexStore(dbPath: path, clock: { frozen })
        let document = try await store.upsertDocument(makeDocument(externalID: "shared-doc", contentHash: "hash-shared"))
        _ = try await store.upsertChunks(
            documentID: document.id,
            chunks: [IndexedChunk(documentID: document.id, ordinal: 0, text: "shared body")]
        )

        #if canImport(SQLite3)
            SQLiteDocIndexStore.resetStatusSnapshotComputeCountForTesting(for: path)
        #endif
        // Both projections read from one cached snapshot, so one cold poll
        // costs exactly one aggregate pass no matter which view runs first.
        let stats = try await store.stats()
        let breakdown = try await store.storageBreakdown()
        #expect(breakdown.dbFileBytes == stats.dbFileBytes)
        #expect(breakdown.textBytes == stats.bytes)
        #if canImport(SQLite3)
            #expect(SQLiteDocIndexStore.statusSnapshotComputeCount(for: path) == 1)
        #endif

        // A repeat poll inside the TTL reuses the snapshot with zero passes.
        let again = try await store.stats()
        #expect(again == stats)
        #if canImport(SQLite3)
            #expect(SQLiteDocIndexStore.statusSnapshotComputeCount(for: path) == 1)
        #endif
    }

    @Test
    func `Deleted database file re-ensures on next open`() async throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }
        #if canImport(SQLite3)
            SQLiteDocIndexStore.removeEnsuredPath(path)
        #endif
        let store = DocIndexStore(dbPath: path)
        _ = try await store.upsertDocument(makeDocument(externalID: "doomed-doc", contentHash: "hash-doomed"))
        let seeded = try await store.stats()
        #expect(seeded.documents == 1)

        // An external delete after the gate filled must not strand later
        // opens on the fast path with an empty schema.
        try FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
        // The required sidecar targets stay inside the scratch directory.
        let sidecars = makeIndexResetSidecars(base: base)
        try await store.reset(mailCheckpointPath: sidecars.mailCheckpointPath, messagesStatePath: sidecars.messagesStatePath)

        // Opening recreates an empty store instead of throwing a missing-table error.
        let empty = try await store.stats()
        #expect(empty.documents == 0)
        #expect(empty.chunks == 0)

        _ = try await store.upsertDocument(makeDocument(externalID: "reborn-doc", contentHash: "hash-reborn"))
        // Freeze-then-jump: the content write invalidates memory but the
        // persisted row still holds the emptied aggregates, so the next poll
        // serves frozen empty with zero passes until an explicit refresh jumps.
        let frozenRevived = try await store.stats()
        #expect(frozenRevived.documents == 0)
        _ = try await store.refreshAggregates()
        let revived = try await store.stats()
        #expect(revived.documents == 1)
    }

    @Test
    func `Symlink spellings resolve to one canonical gate key`() throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }
        #if canImport(SQLite3)
            let linkPath = base.appendingPathComponent("docindex-link.db").path
            try? FileManager.default.removeItem(atPath: linkPath)
            try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: path)
            // Both spellings name the same file, so the ensure gate must see one entry instead of
            // ensuring twice.
            #expect(SQLiteDocIndexStore.canonicalDBPath(linkPath) == SQLiteDocIndexStore.canonicalDBPath(path))
            SQLiteDocIndexStore.removeEnsuredPath(path)
            SQLiteDocIndexStore.removeEnsuredPath(linkPath)
        #endif
    }

    @Test
    func `Refresh persists exact aggregate rows matching the live snapshot`() async throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: path)
        try await seedAggregateFixture(store: store)

        // One refresh call with zero HTTP involved must materialize all three tables.
        let refreshed = try await store.refreshAggregates()
        #if canImport(SQLite3)
            let live = try SQLiteDocIndexStore.statusSnapshot(dbPath: path)
            // The persisted snapshot is the computed one, so logical legs agree exactly.
            #expect(refreshed.documents == live.documents)
            #expect(refreshed.chunks == live.chunks)
            #expect(refreshed.vectorChunks == live.vectorChunks)
            #expect(refreshed.textBytes == live.textBytes)
            #expect(refreshed.vectorBytes == live.vectorBytes)
            #expect(refreshed.ftsBytes == live.ftsBytes)
            #expect(refreshed.indexAsOf == live.indexAsOf)
            #expect(refreshed.bySource == live.bySource)
            #expect(refreshed.byExtractStatus == live.byExtractStatus)

            // The durable rows project the same values the live query reports.
            let single = try readAggregateSingle(atPath: path)
            #expect(single?.documents == live.documents)
            #expect(single?.chunks == live.chunks)
            #expect(single?.vectorChunks == live.vectorChunks)
            #expect(single?.textBytes == live.textBytes)
            #expect(single?.vectorBytes == live.vectorBytes)
            #expect(single?.ftsBytes == live.ftsBytes)
            #expect(single?.indexAsOf == live.indexAsOf.timeIntervalSince1970)
            #expect(single?.producingRunID == nil)

            // Multi-source fan-out: one row per source holding documents.
            let bySource = try readAggregateBySource(atPath: path)
            #expect(bySource.count == 3)
            let liveBySource = Dictionary(uniqueKeysWithValues: live.bySource.map { ($0.source.rawValue, $0) })
            for (key, row) in bySource {
                #expect(row.documents == liveBySource[key]?.documents)
                #expect(row.chunks == liveBySource[key]?.chunks)
                #expect(row.bytes == liveBySource[key]?.bytes)
            }
            #expect(bySource["files"]?.documents == 2)
            #expect(bySource["mail"]?.documents == 2)
            #expect(bySource["messages"]?.documents == 2)

            // Every extraction outcome holds exactly one seeded document.
            let byStatus = try readAggregateByStatus(atPath: path)
            #expect(byStatus.count == ExtractStatus.allCases.count)
            for status in ExtractStatus.allCases {
                #expect(byStatus[status.rawValue] == 1)
            }
            let liveByStatus = Dictionary(uniqueKeysWithValues: live.byExtractStatus.map { ($0.status.rawValue, $0.documents) })
            #expect(byStatus == liveByStatus)

            // A run identity rides the single row when the caller supplies one.
            let runID = "run-agg-\(UUID().uuidString)"
            _ = try await store.refreshAggregates(producingRunID: runID)
            let withRun = try readAggregateSingle(atPath: path)
            #expect(withRun?.producingRunID == runID)
            #expect(withRun?.documents == live.documents)
        #endif
    }

    @Test
    func `Consecutive refreshes are idempotent and warm the status cache`() async throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }
        #if canImport(SQLite3)
            SQLiteDocIndexStore.removeEnsuredPath(path)
            SQLiteDocIndexStore.resetStatusSnapshotComputeCountForTesting(for: path)
        #endif
        let frozen = Date(timeIntervalSince1970: 77000)
        let store = DocIndexStore(dbPath: path, clock: { frozen })
        try await seedAggregateFixture(store: store)

        // Two refreshes over unchanged content must land identical durable rows.
        let first = try await store.refreshAggregates()
        #if canImport(SQLite3)
            let firstSingle = try readAggregateSingle(atPath: path)
            let firstBySource = try readAggregateBySource(atPath: path)
            let firstByStatus = try readAggregateByStatus(atPath: path)
            SQLiteDocIndexStore.resetStatusSnapshotComputeCountForTesting(for: path)
        #endif
        let second = try await store.refreshAggregates()
        #expect(second == first)
        #if canImport(SQLite3)
            let secondSingle = try readAggregateSingle(atPath: path)
            let secondBySource = try readAggregateBySource(atPath: path)
            let secondByStatus = try readAggregateByStatus(atPath: path)
            #expect(secondSingle == firstSingle)
            #expect(secondBySource.count == firstBySource.count)
            for (key, row) in secondBySource {
                #expect(row.documents == firstBySource[key]?.documents)
                #expect(row.chunks == firstBySource[key]?.chunks)
                #expect(row.bytes == firstBySource[key]?.bytes)
            }
            #expect(secondByStatus == firstByStatus)

            // The refresh warmed the cache, so the next poll is a memory hit.
            SQLiteDocIndexStore.resetStatusSnapshotComputeCountForTesting(for: path)
            let stats = try await store.stats()
            #expect(stats.documents == first.documents)
            #expect(stats.chunks == first.chunks)
            #expect(SQLiteDocIndexStore.statusSnapshotComputeCount(for: path) == 0)
        #endif
    }

    @Test
    func `Failed refresh keeps the prior aggregate row`() async throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: path)
        try await seedAggregateFixture(store: store)
        _ = try await store.refreshAggregates()
        #if canImport(SQLite3)
            let beforeSingle = try readAggregateSingle(atPath: path)
            let beforeBySource = try readAggregateBySource(atPath: path)
            let beforeByStatus = try readAggregateByStatus(atPath: path)
            #expect(beforeSingle?.documents == 6)

            // Force the replacement transaction to throw after the compute so the rollback path is
            // exercised instead of a pre-compute open failure.
            SQLiteDocIndexStore.setAggregateWriteFailureHook({ true }, for: path)
            defer { SQLiteDocIndexStore.clearAggregateWriteFailureHook(for: path) }
            do {
                _ = try await store.refreshAggregates()
                #expect(Bool(false), "Expected the injected aggregate failure to throw")
            } catch {
                #expect(!error.localizedDescription.isEmpty)
            }
            SQLiteDocIndexStore.clearAggregateWriteFailureHook(for: path)

            // The prior row survives the failed refresh instead of clearing.
            let keptSingle = try readAggregateSingle(atPath: path)
            let keptBySource = try readAggregateBySource(atPath: path)
            let keptByStatus = try readAggregateByStatus(atPath: path)
            #expect(keptSingle?.documents == beforeSingle?.documents)
            #expect(keptSingle?.chunks == beforeSingle?.chunks)
            #expect(keptSingle?.textBytes == beforeSingle?.textBytes)
            #expect(keptBySource.count == beforeBySource.count)
            #expect(keptByStatus == beforeByStatus)

            // A retry after clearing the hook persists again without duplication.
            _ = try await store.refreshAggregates()
            let retriedSingle = try readAggregateSingle(atPath: path)
            #expect(retriedSingle?.documents == beforeSingle?.documents)
            let retriedByStatus = try readAggregateByStatus(atPath: path)
            #expect(retriedByStatus == beforeByStatus)
        #endif
    }

    @Test
    func `Prune then read serves fresh aggregates with no intervening run`() async throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: path)
        let old = try await store.upsertDocument(makeDocument(
            externalID: "prune-old",
            contentHash: "hash-prune-old",
            indexedAt: Date(timeIntervalSince1970: 1000)
        ))
        _ = try await store.upsertChunks(
            documentID: old.id,
            chunks: [IndexedChunk(documentID: old.id, ordinal: 0, text: "prune expired body")]
        )
        let recent = try await store.upsertDocument(makeDocument(
            externalID: "prune-recent",
            contentHash: "hash-prune-recent",
            indexedAt: Date(timeIntervalSince1970: 5000)
        ))
        _ = try await store.upsertChunks(
            documentID: recent.id,
            chunks: [IndexedChunk(documentID: recent.id, ordinal: 0, text: "prune fresh body")]
        )

        // The route deletes without starting a run, so the store must persist
        // fresh aggregates inline for the next status poll to observe.
        let removed = try await store.prune(before: Date(timeIntervalSince1970: 3000))
        #expect(removed == 1)
        #if canImport(SQLite3)
            let live = try SQLiteDocIndexStore.statusSnapshot(dbPath: path)
            #expect(live.documents == 1)
            #expect(live.chunks == 1)
            let single = try readAggregateSingle(atPath: path)
            #expect(single?.documents == live.documents)
            #expect(single?.chunks == live.chunks)
            #expect(single?.vectorChunks == live.vectorChunks)
            #expect(single?.textBytes == live.textBytes)
            #expect(single?.vectorBytes == live.vectorBytes)
            #expect(single?.ftsBytes == live.ftsBytes)
            let bySource = try readAggregateBySource(atPath: path)
            let liveBySource = Dictionary(uniqueKeysWithValues: live.bySource.map { ($0.source.rawValue, $0) })
            #expect(bySource.count == live.bySource.count)
            for (key, row) in bySource {
                #expect(row.documents == liveBySource[key]?.documents)
                #expect(row.chunks == liveBySource[key]?.chunks)
                #expect(row.bytes == liveBySource[key]?.bytes)
            }
            let byStatus = try readAggregateByStatus(atPath: path)
            let liveByStatus = Dictionary(uniqueKeysWithValues: live.byExtractStatus.map { ($0.status.rawValue, $0.documents) })
            #expect(byStatus == liveByStatus)
            let stats = try await store.stats()
            #expect(stats.documents == live.documents)
            #expect(stats.chunks == live.chunks)
        #endif
    }

    @Test
    func `Reset then read serves fresh aggregates with no intervening run`() async throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: path)
        let first = try await store.upsertDocument(makeDocument(externalID: "reset-a", contentHash: "hash-reset-a"))
        _ = try await store.upsertChunks(
            documentID: first.id,
            chunks: [IndexedChunk(documentID: first.id, ordinal: 0, text: "reset first body")]
        )
        let second = try await store.upsertDocument(makeDocument(
            source: .mail,
            externalID: "reset-b",
            contentHash: "hash-reset-b"
        ))
        _ = try await store.upsertChunks(
            documentID: second.id,
            chunks: [IndexedChunk(documentID: second.id, ordinal: 0, text: "reset second body")]
        )

        // A full clear must leave the persisted rows emptied so a status poll
        // with no later run still reports an empty index.
        let sidecars = makeIndexResetSidecars(base: base)
        try await store.reset(mailCheckpointPath: sidecars.mailCheckpointPath, messagesStatePath: sidecars.messagesStatePath)
        #if canImport(SQLite3)
            let live = try SQLiteDocIndexStore.statusSnapshot(dbPath: path)
            #expect(live.documents == 0)
            #expect(live.chunks == 0)
            let single = try readAggregateSingle(atPath: path)
            #expect(single?.documents == 0)
            #expect(single?.chunks == 0)
            #expect(single?.textBytes == live.textBytes)
            #expect(single?.vectorBytes == live.vectorBytes)
            #expect(single?.ftsBytes == live.ftsBytes)
            let bySource = try readAggregateBySource(atPath: path)
            #expect(bySource.isEmpty)
            let byStatus = try readAggregateByStatus(atPath: path)
            #expect(byStatus.isEmpty)
            let stats = try await store.stats()
            #expect(stats.documents == 0)
            #expect(stats.chunks == 0)
        #endif
    }

    @Test
    func `ClearSource then read serves fresh aggregates with no intervening run`() async throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: path)
        let filesDoc = try await store.upsertDocument(makeDocument(externalID: "clear-files", contentHash: "hash-clear-files"))
        _ = try await store.upsertChunks(
            documentID: filesDoc.id,
            chunks: [IndexedChunk(documentID: filesDoc.id, ordinal: 0, text: "clear files body")]
        )
        let mailDoc = try await store.upsertDocument(makeDocument(
            source: .mail,
            externalID: "clear-mail",
            contentHash: "hash-clear-mail"
        ))
        _ = try await store.upsertChunks(
            documentID: mailDoc.id,
            chunks: [IndexedChunk(documentID: mailDoc.id, ordinal: 0, text: "clear mail body")]
        )

        // Clearing one source must drop only its persisted rows while the
        // surviving source stays counted, all without a later run.
        let sidecars = makeIndexResetSidecars(base: base)
        let removed = try await store.clearSource(
            .mail,
            mailCheckpointPath: sidecars.mailCheckpointPath,
            messagesStatePath: sidecars.messagesStatePath
        )
        #expect(removed == 1)
        #if canImport(SQLite3)
            let live = try SQLiteDocIndexStore.statusSnapshot(dbPath: path)
            #expect(live.documents == 1)
            #expect(live.chunks == 1)
            let single = try readAggregateSingle(atPath: path)
            #expect(single?.documents == live.documents)
            #expect(single?.chunks == live.chunks)
            #expect(single?.textBytes == live.textBytes)
            #expect(single?.vectorBytes == live.vectorBytes)
            #expect(single?.ftsBytes == live.ftsBytes)
            let bySource = try readAggregateBySource(atPath: path)
            #expect(bySource.count == 1)
            #expect(bySource["files"]?.documents == 1)
            #expect(bySource["mail"] == nil)
            let byStatus = try readAggregateByStatus(atPath: path)
            let liveByStatus = Dictionary(uniqueKeysWithValues: live.byExtractStatus.map { ($0.status.rawValue, $0.documents) })
            #expect(byStatus == liveByStatus)
            let stats = try await store.stats()
            #expect(stats.documents == live.documents)
            #expect(stats.chunks == live.chunks)
        #endif
    }

    @Test
    func `RetireUnseenFiles then read serves fresh aggregates with no intervening run`() async throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: path)
        let keepRun = "run-retire-keep-\(UUID().uuidString)"
        let keepDoc = makeDocument(externalID: "retire-keep", contentHash: "hash-retire-keep")
        _ = try await store.upsertDocumentWithChunks(
            document: keepDoc,
            chunks: [IndexedChunk(documentID: keepDoc.id, ordinal: 0, text: "retire keep body")],
            runID: keepRun
        )
        let staleDoc = makeDocument(externalID: "retire-stale", contentHash: "hash-retire-stale")
        _ = try await store.upsertDocumentWithChunks(
            document: staleDoc,
            chunks: [IndexedChunk(documentID: staleDoc.id, ordinal: 0, text: "retire stale body")],
            runID: "run-retire-stale-\(UUID().uuidString)"
        )
        let mailDoc = try await store.upsertDocument(makeDocument(
            source: .mail,
            externalID: "retire-mail",
            contentHash: "hash-retire-mail"
        ))
        _ = try await store.upsertChunks(
            documentID: mailDoc.id,
            chunks: [IndexedChunk(documentID: mailDoc.id, ordinal: 0, text: "retire mail body")]
        )

        // Reconcile removes only the unstamped files row; mail survives, and the
        // persisted rows must reflect that split without a later run.
        let retired = try await store.retireUnseenFiles(runID: keepRun)
        #expect(retired == 1)
        #if canImport(SQLite3)
            let live = try SQLiteDocIndexStore.statusSnapshot(dbPath: path)
            #expect(live.documents == 2)
            let single = try readAggregateSingle(atPath: path)
            #expect(single?.documents == live.documents)
            #expect(single?.chunks == live.chunks)
            #expect(single?.textBytes == live.textBytes)
            #expect(single?.vectorBytes == live.vectorBytes)
            #expect(single?.ftsBytes == live.ftsBytes)
            let bySource = try readAggregateBySource(atPath: path)
            #expect(bySource["files"]?.documents == 1)
            #expect(bySource["mail"]?.documents == 1)
            let liveBySource = Dictionary(uniqueKeysWithValues: live.bySource.map { ($0.source.rawValue, $0) })
            for (key, row) in bySource {
                #expect(row.documents == liveBySource[key]?.documents)
                #expect(row.chunks == liveBySource[key]?.chunks)
                #expect(row.bytes == liveBySource[key]?.bytes)
            }
            let byStatus = try readAggregateByStatus(atPath: path)
            let liveByStatus = Dictionary(uniqueKeysWithValues: live.byExtractStatus.map { ($0.status.rawValue, $0.documents) })
            #expect(byStatus == liveByStatus)
            let stats = try await store.stats()
            #expect(stats.documents == live.documents)
            #expect(stats.chunks == live.chunks)
        #endif
    }

    @Test
    func `RetireMailboxes then read serves fresh aggregates with no intervening run`() async throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: path)
        let deniedMailbox = "INBOX-denied-\(UUID().uuidString)"
        let allowedMailbox = "INBOX-allowed-\(UUID().uuidString)"
        let deniedDoc = makeDocument(
            source: .mail,
            externalID: "retire-denied",
            contentHash: "hash-retire-denied",
            mailbox: deniedMailbox
        )
        let storedDenied = try await store.upsertDocument(deniedDoc)
        _ = try await store.upsertChunks(
            documentID: storedDenied.id,
            chunks: [IndexedChunk(documentID: storedDenied.id, ordinal: 0, text: "retire denied body")]
        )
        let allowedDoc = makeDocument(
            source: .mail,
            externalID: "retire-allowed",
            contentHash: "hash-retire-allowed",
            mailbox: allowedMailbox
        )
        let storedAllowed = try await store.upsertDocument(allowedDoc)
        _ = try await store.upsertChunks(
            documentID: storedAllowed.id,
            chunks: [IndexedChunk(documentID: storedAllowed.id, ordinal: 0, text: "retire allowed body")]
        )
        let filesDoc = try await store.upsertDocument(makeDocument(externalID: "retire-files", contentHash: "hash-retire-files"))
        _ = try await store.upsertChunks(
            documentID: filesDoc.id,
            chunks: [IndexedChunk(documentID: filesDoc.id, ordinal: 0, text: "retire files body")]
        )

        // Denying one mailbox must drop only its rows while the allowed mailbox
        // and files rows stay counted, all without a later run.
        let retired = try await store.retireMailboxes([deniedMailbox])
        #expect(retired == 1)
        #if canImport(SQLite3)
            let live = try SQLiteDocIndexStore.statusSnapshot(dbPath: path)
            #expect(live.documents == 2)
            let single = try readAggregateSingle(atPath: path)
            #expect(single?.documents == live.documents)
            #expect(single?.chunks == live.chunks)
            #expect(single?.textBytes == live.textBytes)
            #expect(single?.vectorBytes == live.vectorBytes)
            #expect(single?.ftsBytes == live.ftsBytes)
            let bySource = try readAggregateBySource(atPath: path)
            #expect(bySource["files"]?.documents == 1)
            #expect(bySource["mail"]?.documents == 1)
            let liveBySource = Dictionary(uniqueKeysWithValues: live.bySource.map { ($0.source.rawValue, $0) })
            for (key, row) in bySource {
                #expect(row.documents == liveBySource[key]?.documents)
                #expect(row.chunks == liveBySource[key]?.chunks)
                #expect(row.bytes == liveBySource[key]?.bytes)
            }
            let byStatus = try readAggregateByStatus(atPath: path)
            let liveByStatus = Dictionary(uniqueKeysWithValues: live.byExtractStatus.map { ($0.status.rawValue, $0.documents) })
            #expect(byStatus == liveByStatus)
            let stats = try await store.stats()
            #expect(stats.documents == live.documents)
            #expect(stats.chunks == live.chunks)
        #endif
    }

    @Test
    func `Reclaim then read serves fresh aggregates with no intervening run`() async throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: path)
        let document = try await store.upsertDocument(makeDocument(externalID: "reclaim-doc", contentHash: "hash-reclaim"))
        _ = try await store.upsertChunks(documentID: document.id, chunks: [
            IndexedChunk(documentID: document.id, ordinal: 0, text: "reclaim vector body", embedding: [0.1, 0.2]),
            IndexedChunk(documentID: document.id, ordinal: 1, text: "reclaim keyword body")
        ])

        // VACUUM rewrites page layout so the full-text size shifts even though
        // counts do not; the persisted rows must match a fresh pass afterwards.
        _ = try await store.reclaim()
        #if canImport(SQLite3)
            let live = try SQLiteDocIndexStore.statusSnapshot(dbPath: path)
            #expect(live.documents == 1)
            #expect(live.chunks == 2)
            let single = try readAggregateSingle(atPath: path)
            #expect(single?.documents == live.documents)
            #expect(single?.chunks == live.chunks)
            #expect(single?.vectorChunks == live.vectorChunks)
            #expect(single?.textBytes == live.textBytes)
            #expect(single?.vectorBytes == live.vectorBytes)
            #expect(single?.ftsBytes == live.ftsBytes)
            let bySource = try readAggregateBySource(atPath: path)
            #expect(bySource["files"]?.documents == 1)
            #expect(bySource["files"]?.chunks == 2)
            let liveBySource = Dictionary(uniqueKeysWithValues: live.bySource.map { ($0.source.rawValue, $0) })
            for (key, row) in bySource {
                #expect(row.documents == liveBySource[key]?.documents)
                #expect(row.chunks == liveBySource[key]?.chunks)
                #expect(row.bytes == liveBySource[key]?.bytes)
            }
            let byStatus = try readAggregateByStatus(atPath: path)
            let liveByStatus = Dictionary(uniqueKeysWithValues: live.byExtractStatus.map { ($0.status.rawValue, $0.documents) })
            #expect(byStatus == liveByStatus)
            let stats = try await store.stats()
            #expect(stats.documents == live.documents)
            #expect(stats.chunks == live.chunks)
        #endif
    }

    @Test
    func `Warm aggregate reads perform zero passes per method`() async throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }
        #if canImport(SQLite3)
            SQLiteDocIndexStore.removeEnsuredPath(path)
            SQLiteDocIndexStore.resetStatusSnapshotComputeCountForTesting(for: path)
        #endif
        let frozen = Date(timeIntervalSince1970: 91000)
        let store = DocIndexStore(dbPath: path, clock: { frozen })
        try await seedAggregateFixture(store: store)
        _ = try await store.refreshAggregates()
        #if canImport(SQLite3)
            SQLiteDocIndexStore.resetStatusSnapshotComputeCountForTesting(for: path)
        #endif

        // Same-store warm reads ride the memory snapshot plus the persisted rows with no content
        // scan, so every projection stays at zero passes.
        let stats = try await store.stats()
        #expect(stats.documents == 6)
        let breakdown = try await store.storageBreakdown()
        #expect(breakdown.textBytes == stats.bytes)
        let fast = try await store.fastStats()
        #expect(fast.documents == 6)
        #expect(fast.bytes == stats.bytes)
        #expect(fast.textBytes == stats.textBytes)
        #expect(fast.vectorBytes == stats.vectorBytes)
        #expect(fast.ftsBytes == stats.ftsBytes)
        #expect(fast.contentBytes == stats.contentBytes)
        #expect(fast.bySource == stats.bySource)
        #expect(fast == stats)
        #if canImport(SQLite3)
            #expect(SQLiteDocIndexStore.statusSnapshotComputeCount(for: path) == 0)
        #endif

        // A cold store over the same file holds no memory snapshot, so its
        // warm reads prove the persisted tables alone serve with zero passes.
        let cold = DocIndexStore(dbPath: path, clock: { frozen })
        #if canImport(SQLite3)
            SQLiteDocIndexStore.resetStatusSnapshotComputeCountForTesting(for: path)
        #endif
        let coldFast = try await cold.fastStats()
        #expect(coldFast.documents == 6)
        #expect(coldFast.chunks == fast.chunks)
        #expect(coldFast.vectorChunks == fast.vectorChunks)
        #expect(coldFast.bySource == fast.bySource)
        #expect(coldFast.byExtractStatus == fast.byExtractStatus)
        #expect(coldFast.dbFileBytes == fast.dbFileBytes)
        #expect(coldFast.walBytes == fast.walBytes)
        let coldStats = try await cold.stats()
        #expect(coldStats == stats)
        let coldBreakdown = try await cold.storageBreakdown()
        #expect(coldBreakdown == breakdown)
        #if canImport(SQLite3)
            #expect(SQLiteDocIndexStore.statusSnapshotComputeCount(for: path) == 0)
        #endif
    }

    @Test
    func `Absent aggregate row repairs once per cold reader`() async throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: path)
        try await seedAggregateFixture(store: store)
        _ = try await store.refreshAggregates()
        #if canImport(SQLite3)
            let live = try SQLiteDocIndexStore.statusSnapshot(dbPath: path)
            #expect(live.documents == 6)

            // Remove the persisted rows without touching actor state, then read
            // through a cold store holding no memory snapshot: the absent row
            // must repair exactly once and serve correct numbers.
            try clearAggregateRows(atPath: path)
            #expect(try readAggregateSingle(atPath: path) == nil)
            SQLiteDocIndexStore.resetStatusSnapshotComputeCountForTesting(for: path)
            let coldStats = DocIndexStore(dbPath: path)
            let repairedStats = try await coldStats.stats()
            #expect(SQLiteDocIndexStore.statusSnapshotComputeCount(for: path) == 1)
            #expect(repairedStats.documents == live.documents)
            #expect(repairedStats.chunks == live.chunks)
            #expect(repairedStats.bytes == live.textBytes)
            #expect(try readAggregateSingle(atPath: path)?.documents == live.documents)

            try clearAggregateRows(atPath: path)
            SQLiteDocIndexStore.resetStatusSnapshotComputeCountForTesting(for: path)
            let coldBreakdown = DocIndexStore(dbPath: path)
            let repairedBreakdown = try await coldBreakdown.storageBreakdown()
            #expect(SQLiteDocIndexStore.statusSnapshotComputeCount(for: path) == 1)
            #expect(repairedBreakdown.textBytes == live.textBytes)
            #expect(repairedBreakdown.vectorBytes == live.vectorBytes)
            #expect(repairedBreakdown.ftsBytes == (live.ftsBytes ?? 0))
            #expect(try readAggregateSingle(atPath: path)?.documents == live.documents)

            try clearAggregateRows(atPath: path)
            SQLiteDocIndexStore.resetStatusSnapshotComputeCountForTesting(for: path)
            let coldFast = DocIndexStore(dbPath: path)
            let repairedFast = try await coldFast.fastStats()
            #expect(SQLiteDocIndexStore.statusSnapshotComputeCount(for: path) == 1)
            #expect(repairedFast.documents == live.documents)
            #expect(repairedFast.chunks == live.chunks)
            // Freeze-then-jump: the repaired persisted row carries true sizes,
            // so the fast projection serves them, not pending zeros.
            #expect(repairedFast.bytes == live.textBytes)
            #expect(repairedFast.textBytes == live.textBytes)
            #expect(try readAggregateSingle(atPath: path)?.documents == live.documents)
        #endif
    }

    @Test
    func `Aggregate projections equal the live single-pass snapshot`() async throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: path)
        try await seedAggregateFixture(store: store)
        _ = try await store.refreshAggregates()
        #if canImport(SQLite3)
            let live = try SQLiteDocIndexStore.statusSnapshot(dbPath: path)
            let stats = try await store.stats()
            #expect(stats == live.makeStats())
            let breakdown = try await store.storageBreakdown()
            #expect(breakdown == live.makeBreakdown())
            let fast = try await store.fastStats()
            // Freeze-then-jump: the persisted snapshot now correctly carries true sizes, so the
            // fast projection equals the live snapshot's stats projection, not the fail-closed
            // pending-zero shape from the cheap COUNT path used only when no row exists.
            let liveFast = live.makeStats()
            #expect(fast == liveFast)
            #expect(fast.documents == live.documents)
            #expect(fast.chunks == live.chunks)
            #expect(fast.vectorChunks == live.vectorChunks)
            #expect(fast.indexAsOf == live.indexAsOf)
        #endif
    }

    @Test
    func `Legacy database without aggregate tables repairs on first read`() async throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }
        #if canImport(SQLite3)
            SQLiteDocIndexStore.removeEnsuredPath(path)
            SQLiteDocIndexStore.resetStatusSnapshotComputeCountForTesting(for: path)
            try createLegacyIndex(atPath: path)
            // The legacy file holds content tables but no aggregate tables;
            // opening ensures the schema while the first reader persists them.
            SQLiteDocIndexStore.removeEnsuredPath(path)
        #endif
        let store = DocIndexStore(dbPath: path)
        _ = try await store.upsertDocument(makeDocument(externalID: "legacy-doc", contentHash: "hash-legacy"))
        #if canImport(SQLite3)
            SQLiteDocIndexStore.resetStatusSnapshotComputeCountForTesting(for: path)
            let stats = try await store.stats()
            #expect(stats.documents == 1)
            #expect(SQLiteDocIndexStore.statusSnapshotComputeCount(for: path) == 1)
            #expect(try readAggregateSingle(atPath: path)?.documents == 1)
            SQLiteDocIndexStore.resetStatusSnapshotComputeCountForTesting(for: path)
            let fast = try await store.fastStats()
            #expect(fast.documents == 1)
            #expect(SQLiteDocIndexStore.statusSnapshotComputeCount(for: path) == 0)
            let breakdown = try await store.storageBreakdown()
            #expect(breakdown.textBytes == stats.bytes)
            #expect(SQLiteDocIndexStore.statusSnapshotComputeCount(for: path) == 0)
        #endif
    }

    @Test
    func `Bulk upsertDocumentsWithChunks, storedFingerprints, and markSeenBatch operate in single transactions`() async throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: path)

        let docA = IndexedDocument(
            source: .files,
            externalID: "/tmp/doc-a.md",
            displayName: "doc-a.md",
            path: "/tmp/doc-a.md",
            mtime: Date(timeIntervalSince1970: 1_700_000_000),
            sizeBytes: 120,
            contentHash: "hash-a"
        )
        let docB = IndexedDocument(
            source: .files,
            externalID: "/tmp/doc-b.md",
            displayName: "doc-b.md",
            path: "/tmp/doc-b.md",
            mtime: Date(timeIntervalSince1970: 1_700_000_500),
            sizeBytes: 240,
            contentHash: "hash-b"
        )
        let entries = [
            DocBatchUpsertEntry(
                document: docA,
                chunks: [IndexedChunk(documentID: docA.id, ordinal: 0, text: "bulkbatchalpha", embedding: [1.0, 0.0])],
                runID: "run-1"
            ),
            DocBatchUpsertEntry(
                document: docB,
                chunks: [IndexedChunk(documentID: docB.id, ordinal: 0, text: "bulkbatchbeta")],
                runID: "run-1"
            )
        ]

        let saved = try await store.upsertDocumentsWithChunks(entries)
        #expect(saved.count == 2)

        let fingerprints = try await store.storedFingerprints(source: .files)
        #expect(fingerprints["/tmp/doc-a.md"]?.contentHash == "hash-a")
        #expect(fingerprints["/tmp/doc-a.md"]?.sizeBytes == 120)
        #expect(fingerprints["/tmp/doc-b.md"]?.contentHash == "hash-b")
        #expect(fingerprints["/tmp/doc-b.md"]?.sizeBytes == 240)

        let alphaHits = try await store.searchKeyword(query: "bulkbatchalpha", limit: 5)
        #expect(alphaHits.count == 1)
        #expect(alphaHits[0].isVector == true)

        // Advance run-2 seen stamp only on doc-a.md via markSeenBatch; retireUnseenFiles should retire doc-b.md only.
        try await store.markSeenBatch(source: .files, externalIDs: ["/tmp/doc-a.md"], runID: "run-2")
        let retired = try await store.retireUnseenFiles(runID: "run-2")
        #expect(retired == 1)

        let remainingFingerprints = try await store.storedFingerprints(source: .files)
        #expect(remainingFingerprints.keys.sorted() == ["/tmp/doc-a.md"])
    }
}

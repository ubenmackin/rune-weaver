// Rune Weaver Core — SQLite-backed local document index for keyword and vector search.
//
// Persists one row per indexed document plus its text chunks in a sidecar
// SQLite database, with an FTS5 virtual table over chunk text for keyword
// search and a stored-embedding column for the semantic path. Content hashes
// gate re-indexing so unchanged sources skip writes, and schema versioning
// plus additive column probes keep older databases forward-migratable.
// Blocking SQLite work is dispatched off the actor executor through
// `SQLiteSerialIO`, mirroring the episodic store.
// Document rows live in `DocIndexStoreDocuments.swift`, chunks and search in
// `DocIndexStoreChunks.swift`, and deletion plus statistics in
// `DocIndexStoreMaintenance.swift`.

import Foundation

#if canImport(SQLite3)
    import SQLite3
#endif

/// Actor-isolated SQLite store for the local document index.
public actor DocIndexStore {
    /// Filesystem path of the sidecar SQLite database.
    public let dbPath: String
    /// Default SQLite path for the index database, aliasing the canonical
    /// index default so configuration and the store never diverge.
    public static var defaultDBPath: String {
        IndexConfig.defaultDBPath
    }

    /// Creates a store over a sidecar database.
    /// - Parameter dbPath: SQLite file path. `~` is expanded on first use.
    public init(dbPath: String = DocIndexStore.defaultDBPath) {
        self.dbPath = dbPath
    }

    /// Inserts or updates a document, skipping the write when the content hash
    /// is unchanged and the prior extraction did not fail.
    /// - Parameter document: Document to persist.
    /// - Returns: The persisted document, including the row's stable identifier.
    @discardableResult
    public func upsertDocument(_ document: IndexedDocument) async throws -> IndexedDocument {
        let dbPath = self.dbPath
        return try await SQLiteSerialIO.run(lane: .indexing) {
            try DocIndexStoreIO.upsertDocument(document, dbPath: dbPath)
        }
    }

    /// Replaces all chunks for a document.
    /// - Parameters:
    ///   - documentID: Document owning the chunks.
    ///   - chunks: Chunks to store; an empty list clears the document's chunks.
    /// - Returns: Number of chunks written.
    @discardableResult
    public func upsertChunks(documentID: UUID, chunks: [IndexedChunk]) async throws -> Int {
        let dbPath = self.dbPath
        return try await SQLiteSerialIO.run(lane: .indexing) {
            try DocIndexStoreIO.upsertChunks(documentID: documentID, chunks: chunks, dbPath: dbPath)
        }
    }

    /// Deletes a document and its chunks. Missing rows are a no-op.
    /// - Parameter id: Document identifier.
    /// - Returns: True when a document row was removed.
    public func deleteDocument(id: UUID) async throws -> Bool {
        let dbPath = self.dbPath
        return try await SQLiteSerialIO.run(lane: .indexing) {
            try DocIndexStoreIO.deleteDocument(id: id, dbPath: dbPath)
        }
    }

    /// Looks up a document by its source-scoped identifier.
    /// - Parameters:
    ///   - source: Origin corpus.
    ///   - externalID: Source-scoped identifier.
    /// - Returns: The stored document, or nil when absent.
    public func document(source: IndexSource, externalID: String) async throws -> IndexedDocument? {
        let dbPath = self.dbPath
        return try await SQLiteSerialIO.run(lane: .indexing) {
            try DocIndexStoreIO.document(source: source, externalID: externalID, dbPath: dbPath)
        }
    }

    /// Reports whether a source must be re-extracted.
    ///
    /// True when the document is unknown, its content hash changed, or a prior
    /// extraction failed; false when the stored body is current.
    /// - Parameters:
    ///   - source: Origin corpus.
    ///   - externalID: Source-scoped identifier.
    ///   - contentHash: Hash of the current source content.
    /// - Returns: True when the document should be re-indexed.
    public func needsReindex(source: IndexSource, externalID: String, contentHash: String) async throws -> Bool {
        let dbPath = self.dbPath
        return try await SQLiteSerialIO.run(lane: .indexing) {
            try DocIndexStoreIO.needsReindex(
                source: source,
                externalID: externalID,
                contentHash: contentHash,
                dbPath: dbPath
            )
        }
    }

    /// Full-text search over chunk text.
    /// - Parameters:
    ///   - query: Raw search text.
    ///   - limit: Maximum chunks returned.
    /// - Returns: Matching chunks, best-ranked first.
    public func searchKeyword(query: String, limit: Int = 10) async throws -> [IndexedChunk] {
        let dbPath = self.dbPath
        return try await SQLiteSerialIO.run(lane: .indexing) {
            try DocIndexStoreIO.searchKeyword(query: query, limit: limit, dbPath: dbPath)
        }
    }

    /// Reads chunks that carry an embedding for the semantic path.
    /// The store returns the newest vector chunks first, bounded by `limit`,
    /// so a capped pool favors recent writes over the oldest rows.
    /// - Parameter limit: Maximum chunks returned.
    /// - Returns: Vector chunks, newest first.
    public func chunkVectors(limit: Int = 100) async throws -> [IndexedChunk] {
        let dbPath = self.dbPath
        return try await SQLiteSerialIO.run(lane: .indexing) {
            try DocIndexStoreIO.chunkVectors(limit: limit, dbPath: dbPath)
        }
    }

    /// Current document, chunk, vector, and byte counts.
    /// - Returns: An index statistics snapshot.
    public func stats() async throws -> IndexStats {
        let dbPath = self.dbPath
        return try await SQLiteSerialIO.run(lane: .indexing) {
            try DocIndexStoreIO.stats(dbPath: dbPath)
        }
    }

    /// Deletes documents indexed before a cutoff, then reclaims file space.
    /// - Parameter cutoff: Documents with an earlier `indexedAt` are removed.
    /// - Returns: Number of documents removed.
    @discardableResult
    public func prune(before cutoff: Date) async throws -> Int {
        let dbPath = self.dbPath
        return try await SQLiteSerialIO.run(lane: .indexing) {
            try DocIndexStoreIO.prune(before: cutoff, dbPath: dbPath)
        }
    }

    /// Clears every document, chunk, and search-index entry.
    public func reset() async throws {
        let dbPath = self.dbPath
        try await SQLiteSerialIO.run(lane: .indexing) {
            try DocIndexStoreIO.reset(dbPath: dbPath)
        }
    }
}

// MARK: - Store I/O

/// SQLite I/O for the document index, falling back to an unavailable error
/// where the SQLite3 module cannot be imported.
enum DocIndexStoreIO {
    /// Inserts or updates a document, skipping unchanged content.
    static func upsertDocument(_ document: IndexedDocument, dbPath: String) throws -> IndexedDocument {
        #if canImport(SQLite3)
            return try SQLiteDocIndexStore.upsertDocument(document, dbPath: dbPath)
        #else
            throw DocIndexError.storeUnavailable("SQLite3 is unavailable on this platform")
        #endif
    }

    /// Replaces all chunks for a document.
    static func upsertChunks(documentID: UUID, chunks: [IndexedChunk], dbPath: String) throws -> Int {
        #if canImport(SQLite3)
            return try SQLiteDocIndexStore.upsertChunks(documentID: documentID, chunks: chunks, dbPath: dbPath)
        #else
            throw DocIndexError.storeUnavailable("SQLite3 is unavailable on this platform")
        #endif
    }

    /// Deletes a document and its chunks.
    static func deleteDocument(id: UUID, dbPath: String) throws -> Bool {
        #if canImport(SQLite3)
            return try SQLiteDocIndexStore.deleteDocument(id: id, dbPath: dbPath)
        #else
            throw DocIndexError.storeUnavailable("SQLite3 is unavailable on this platform")
        #endif
    }

    /// Reads a document by source-scoped identifier.
    static func document(source: IndexSource, externalID: String, dbPath: String) throws -> IndexedDocument? {
        #if canImport(SQLite3)
            return try SQLiteDocIndexStore.document(source: source, externalID: externalID, dbPath: dbPath)
        #else
            throw DocIndexError.storeUnavailable("SQLite3 is unavailable on this platform")
        #endif
    }

    /// Reports whether a source must be re-extracted.
    static func needsReindex(source: IndexSource, externalID: String, contentHash: String, dbPath: String) throws -> Bool {
        #if canImport(SQLite3)
            return try SQLiteDocIndexStore.needsReindex(
                source: source,
                externalID: externalID,
                contentHash: contentHash,
                dbPath: dbPath
            )
        #else
            throw DocIndexError.storeUnavailable("SQLite3 is unavailable on this platform")
        #endif
    }

    /// Full-text search over chunk text.
    static func searchKeyword(query: String, limit: Int, dbPath: String) throws -> [IndexedChunk] {
        #if canImport(SQLite3)
            return try SQLiteDocIndexStore.searchKeyword(query: query, limit: limit, dbPath: dbPath)
        #else
            throw DocIndexError.storeUnavailable("SQLite3 is unavailable on this platform")
        #endif
    }

    /// Reads the newest chunks that carry an embedding, bounded by `limit`.
    static func chunkVectors(limit: Int, dbPath: String) throws -> [IndexedChunk] {
        #if canImport(SQLite3)
            return try SQLiteDocIndexStore.chunkVectors(limit: limit, dbPath: dbPath)
        #else
            throw DocIndexError.storeUnavailable("SQLite3 is unavailable on this platform")
        #endif
    }

    /// Aggregates current index statistics.
    static func stats(dbPath: String) throws -> IndexStats {
        #if canImport(SQLite3)
            return try SQLiteDocIndexStore.stats(dbPath: dbPath)
        #else
            throw DocIndexError.storeUnavailable("SQLite3 is unavailable on this platform")
        #endif
    }

    /// Deletes documents indexed before a cutoff and vacuums.
    static func prune(before cutoff: Date, dbPath: String) throws -> Int {
        #if canImport(SQLite3)
            return try SQLiteDocIndexStore.prune(before: cutoff, dbPath: dbPath)
        #else
            throw DocIndexError.storeUnavailable("SQLite3 is unavailable on this platform")
        #endif
    }

    /// Clears every document, chunk, and index entry.
    static func reset(dbPath: String) throws {
        #if canImport(SQLite3)
            try SQLiteDocIndexStore.reset(dbPath: dbPath)
        #else
            throw DocIndexError.storeUnavailable("SQLite3 is unavailable on this platform")
        #endif
    }
}

#if canImport(SQLite3)
    /// Schema and open path for the document index.
    ///
    /// Holds the on-disk revision, table plus trigger definitions, additive
    /// column probes, and the shared open helper. Document rows, chunks, and
    /// maintenance live in their own files under the same namespace.
    enum SQLiteDocIndexStore {
        /// Current on-disk schema revision.
        static let schemaVersion = 1

        /// Maximum rows returned per read when a caller passes an oversized limit.
        static let maxResults = 1000

        /// Column projection shared by every document read.
        static let documentColumnList =
            "id, source, external_id, display_name, path, message_id, mailbox, mtime, "
                + "size_bytes, content_hash, mime, extract_status, indexed_at, metadata"

        /// Table and trigger schema, applied before additive column probes.
        ///
        /// Only columns present since the first revision are referenced here so
        /// a legacy database that predates an additive column still executes
        /// this block cleanly; the indexes that depend on later columns live in
        /// ``indexesSQL``.
        private static let tablesSQL = """
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
        """

        /// Indexes applied after additive columns exist, so a column introduced
        /// by migration is indexable on the same open.
        private static let indexesSQL = """
        CREATE UNIQUE INDEX IF NOT EXISTS idx_indexed_documents_source_external
            ON indexed_documents(source, external_id);
        CREATE INDEX IF NOT EXISTS idx_indexed_documents_indexed_at ON indexed_documents(indexed_at);
        CREATE INDEX IF NOT EXISTS idx_indexed_chunks_document ON indexed_chunks(document_id);
        CREATE INDEX IF NOT EXISTS idx_indexed_chunks_vector ON indexed_chunks(is_vector);
        """

        /// Additive `indexed_documents` columns introduced after the first schema revision.
        private static let documentAdditions: [(name: String, sql: String)] = [
            ("metadata", "ALTER TABLE indexed_documents ADD COLUMN metadata TEXT;")
        ]

        /// Additive `indexed_chunks` columns introduced after the first schema revision.
        private static let chunkAdditions: [(name: String, sql: String)] = [
            ("is_vector", "ALTER TABLE indexed_chunks ADD COLUMN is_vector INTEGER NOT NULL DEFAULT 0;")
        ]

        /// Key/value row identifying an existing document without loading it.
        struct DocumentRowKey {
            /// Stable row identifier whose chunks must survive a rewrite.
            let id: UUID
            /// Stored body hash used for the skip check.
            let contentHash: String
            /// Prior extraction outcome; failures are always retried.
            let extractStatus: ExtractStatus
        }

        /// Opens (creating parent directories) and migrates the database.
        /// - Parameter dbPath: SQLite file path. `~` is expanded.
        /// - Returns: Open database handle. Caller must close it.
        static func open(dbPath: String) throws -> OpaquePointer? {
            // Shared busy_timeout/WAL policy lives in `SQLiteHelpers.openHandle`.
            let handle = try SQLiteHelpers.openHandle(dbPath: dbPath, unavailable: DocIndexError.storeUnavailable)
            do {
                try exec(handle: handle, sql: tablesSQL)
                try ensureColumns(handle: handle)
                try exec(handle: handle, sql: indexesSQL)
                try ensureSchemaVersion(handle: handle)
                try migrateFTSTriggers(handle: handle)
                try SQLiteHelpers.exec(
                    handle: handle,
                    sql: "PRAGMA foreign_keys = ON;",
                    failure: DocIndexError.persistenceFailed
                )
                return handle
            } catch {
                sqlite3_close(handle)
                throw error
            }
        }

        /// Executes a multi-statement SQL string.
        static func exec(handle: OpaquePointer?, sql: String) throws {
            try SQLiteHelpers.exec(handle: handle, sql: sql, failure: DocIndexError.persistenceFailed)
        }

        /// Applies additive column migrations, mirroring the session-store pattern.
        ///
        /// Probes each table's declared columns and runs only the missing
        /// `ALTER`s, so replaying against an already-current database is a
        /// no-op and concurrent opens stay safe.
        private static func ensureColumns(handle: OpaquePointer?) throws {
            try addMissingColumns(
                handle: handle,
                pragma: "PRAGMA table_info(indexed_documents);",
                additions: documentAdditions
            )
            try addMissingColumns(
                handle: handle,
                pragma: "PRAGMA table_info(indexed_chunks);",
                additions: chunkAdditions
            )
        }

        /// Adds columns absent from a table's current declaration.
        private static func addMissingColumns(
            handle: OpaquePointer?,
            pragma: String,
            additions: [(name: String, sql: String)]
        ) throws {
            let existing = columnNames(handle: handle, pragma: pragma)
            for addition in additions where !existing.contains(addition.name) {
                do {
                    try exec(handle: handle, sql: addition.sql)
                } catch {
                    // A duplicate addition from a concurrent open surfaces here;
                    // the probe plus conditional `ALTER` is idempotent, so log
                    // and continue rather than failing the open.
                    let code = sqlite3_errcode(handle)
                    RuneWeaverLog.stores.warning(
                        "DocIndexStore: Migration failed for column '\(addition.name)' (code \(code)): \(error)"
                    )
                }
            }
        }

        /// Drops and recreates the FTS5 sync triggers so they use direct
        /// `DELETE FROM` instead of the FTS5 "delete" command (`INSERT INTO
        /// fts(fts, ...) VALUES('delete', ...)`), which is broken on
        /// SQLite ≥ 3.54.0 shipped with macOS Tahoe.
        ///
        /// The migration is idempotent: `DROP TRIGGER IF EXISTS` is a no-op
        /// when the trigger is already gone, and the `CREATE TRIGGER` block
        /// replaces the definition unconditionally.
        private static func migrateFTSTriggers(handle: OpaquePointer?) throws {
            try exec(handle: handle, sql: """
            DROP TRIGGER IF EXISTS indexed_chunks_ad;
            CREATE TRIGGER indexed_chunks_ad AFTER DELETE ON indexed_chunks BEGIN
                DELETE FROM indexed_chunks_fts WHERE rowid = old.rowid;
            END;
            DROP TRIGGER IF EXISTS indexed_chunks_au;
            CREATE TRIGGER indexed_chunks_au AFTER UPDATE ON indexed_chunks BEGIN
                DELETE FROM indexed_chunks_fts WHERE rowid = old.rowid;
                INSERT INTO indexed_chunks_fts(rowid, chunk_text) VALUES(new.rowid, new.chunk_text);
            END;
            """)
        }

        /// Lists declared columns for a table, lowercased for case-tolerant probes.
        private static func columnNames(handle: OpaquePointer?, pragma: String) -> Set<String> {
            var names: Set<String> = []
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, pragma, -1, &statement, nil) == SQLITE_OK else {
                return names
            }
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                if let name = SQLiteHelpers.columnText(statement, index: 1) {
                    names.insert(name.lowercased())
                }
            }
            return names
        }

        /// Records the schema revision, migrating older databases first.
        private static func ensureSchemaVersion(handle: OpaquePointer?) throws {
            let stored = try readSchemaVersion(handle: handle)
            if let stored, stored > schemaVersion {
                RuneWeaverLog.stores.warning(
                    "DocIndexStore: database schema v\(stored) is newer than supported v\(schemaVersion); leaving it unchanged"
                )
                return
            }
            if let stored, stored < schemaVersion {
                try migrate(handle: handle, from: stored)
            }
            try writeSchemaVersion(handle: handle, version: schemaVersion)
        }

        /// Reads the recorded schema revision, or nil for a fresh database.
        private static func readSchemaVersion(handle: OpaquePointer?) throws -> Int? {
            var statement: OpaquePointer?
            let sql = "SELECT value FROM schema_meta WHERE key = 'schema_version';"
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DocIndexError.persistenceFailed("Could not read schema version")
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW, let text = SQLiteHelpers.columnText(statement, index: 0) else {
                return nil
            }
            return Int(text)
        }

        /// Persists the schema revision.
        private static func writeSchemaVersion(handle: OpaquePointer?, version: Int) throws {
            var statement: OpaquePointer?
            let sql = "INSERT INTO schema_meta(key, value) VALUES('schema_version', ?) "
                + "ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DocIndexError.persistenceFailed("Could not prepare schema version write")
            }
            defer { sqlite3_finalize(statement) }
            SQLiteHelpers.bindText(statement, index: 1, value: String(version))
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DocIndexError.persistenceFailed("Could not persist schema version")
            }
        }

        /// Applies stepwise migrations for databases older than ``schemaVersion``.
        ///
        /// The first revision has no predecessors; future revisions branch on
        /// `stored` and replay additive steps here.
        private static func migrate(handle _: OpaquePointer?, from _: Int) throws {}
    }
#endif

// Rune Weaver Core — Document rows for the local document index.

import Foundation

#if canImport(SQLite3)
    import SQLite3
#endif

#if canImport(SQLite3)
    /// Document persistence for the document index.
    extension SQLiteDocIndexStore {
        /// Inserts or updates a document, skipping unchanged content.
        static func upsertDocument(_ document: IndexedDocument, dbPath: String) throws -> IndexedDocument {
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            try exec(handle: handle, sql: "BEGIN IMMEDIATE;")
            do {
                let existing = try existingRow(
                    handle: handle,
                    source: document.source,
                    externalID: document.externalID
                )
                if let existing, existing.contentHash == document.contentHash, existing.extractStatus != .failed {
                    // Unchanged content: leave the row and its chunks untouched
                    // so a re-scan of an unchanged source is a cheap no-op.
                    try exec(handle: handle, sql: "COMMIT;")
                    return try loadDocument(
                        handle: handle,
                        source: document.source,
                        externalID: document.externalID
                    ) ?? document
                }
                if let existing {
                    try updateDocument(document, id: existing.id, handle: handle)
                    // Body changed: prior chunks describe stale text.
                    try deleteChunks(documentID: existing.id, handle: handle)
                    try exec(handle: handle, sql: "COMMIT;")
                    return replacingID(of: document, with: existing.id)
                }
                try insertDocument(document, handle: handle)
                try exec(handle: handle, sql: "COMMIT;")
                return document
            } catch {
                try? exec(handle: handle, sql: "ROLLBACK;")
                throw error
            }
        }

        /// Commits one document with its chunks and run stamp in a single transaction.
        static func upsertDocumentWithChunks(
            document: IndexedDocument,
            chunks: [IndexedChunk],
            runID: String,
            dbPath: String
        ) throws -> IndexedDocument {
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            try exec(handle: handle, sql: "BEGIN IMMEDIATE;")
            do {
                let existing = try existingRow(
                    handle: handle,
                    source: document.source,
                    externalID: document.externalID
                )
                if let existing, existing.contentHash == document.contentHash, existing.extractStatus != .failed {
                    // Unchanged body keeps its chunks; only the stamp refreshes
                    // in the same commit so the reconcile still sees the file.
                    try stampDocument(handle: handle, documentID: existing.id, runID: runID)
                    try exec(handle: handle, sql: "COMMIT;")
                    return try loadDocument(
                        handle: handle,
                        source: document.source,
                        externalID: document.externalID
                    ) ?? replacingID(of: document, with: existing.id)
                }
                let resolvedID: UUID
                if let existing {
                    try updateDocument(document, id: existing.id, handle: handle)
                    // Body changed: prior chunks describe stale text.
                    try deleteChunks(documentID: existing.id, handle: handle)
                    resolvedID = existing.id
                } else {
                    // A new path keeps the caller's identifier so chunk foreign
                    // keys line up without a second lookup.
                    try insertDocument(document, handle: handle)
                    resolvedID = document.id
                }
                try insertChunkRows(documentID: resolvedID, chunks: chunks, handle: handle)
                try stampDocument(handle: handle, documentID: resolvedID, runID: runID)
                try exec(handle: handle, sql: "COMMIT;")
                if resolvedID == document.id {
                    return document
                }
                return replacingID(of: document, with: resolvedID)
            } catch {
                try? exec(handle: handle, sql: "ROLLBACK;")
                throw error
            }
        }

        /// Records the run stamp for one document inside an open transaction.
        private static func stampDocument(handle: OpaquePointer?, documentID: UUID, runID: String) throws {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "UPDATE indexed_documents SET last_seen_run = ? WHERE id = ?;", -1, &statement, nil) == SQLITE_OK else {
                throw DocIndexError.persistenceFailed("Could not prepare seen stamp")
            }
            defer { sqlite3_finalize(statement) }
            SQLiteHelpers.bindText(statement, index: 1, value: runID)
            SQLiteHelpers.bindText(statement, index: 2, value: documentID.uuidString)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DocIndexError.persistenceFailed("Could not stamp document \(documentID)")
            }
        }

        /// Returns a copy of a document carrying a different stable identifier.
        private static func replacingID(of document: IndexedDocument, with id: UUID) -> IndexedDocument {
            IndexedDocument(
                id: id,
                source: document.source,
                externalID: document.externalID,
                displayName: document.displayName,
                path: document.path,
                messageID: document.messageID,
                mailbox: document.mailbox,
                mtime: document.mtime,
                sizeBytes: document.sizeBytes,
                contentHash: document.contentHash,
                mime: document.mime,
                extractStatus: document.extractStatus,
                indexedAt: document.indexedAt,
                metadata: document.metadata
            )
        }

        /// Reads the identity and hash of an existing document.
        private static func existingRow(
            handle: OpaquePointer?,
            source: IndexSource,
            externalID: String
        ) throws -> DocumentRowKey? {
            var statement: OpaquePointer?
            let sql = "SELECT id, content_hash, extract_status FROM indexed_documents "
                + "WHERE source = ? AND external_id = ?;"
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DocIndexError.persistenceFailed("Could not prepare document lookup")
            }
            defer { sqlite3_finalize(statement) }
            SQLiteHelpers.bindText(statement, index: 1, value: source.rawValue)
            SQLiteHelpers.bindText(statement, index: 2, value: externalID)
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let idText = SQLiteHelpers.columnText(statement, index: 0),
                  let id = UUID(uuidString: idText),
                  let hash = SQLiteHelpers.columnText(statement, index: 1),
                  let statusText = SQLiteHelpers.columnText(statement, index: 2),
                  let status = ExtractStatus(rawValue: statusText)
            else { return nil }
            return DocumentRowKey(id: id, contentHash: hash, extractStatus: status)
        }

        /// Inserts a new document row.
        private static func insertDocument(_ document: IndexedDocument, handle: OpaquePointer?) throws {
            var statement: OpaquePointer?
            let sql = "INSERT INTO indexed_documents(" + documentColumnList + ") "
                + "VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);"
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DocIndexError.persistenceFailed("Could not prepare document insert")
            }
            defer { sqlite3_finalize(statement) }
            bindDocument(document, statement: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DocIndexError.persistenceFailed("Could not write document \(document.externalID)")
            }
        }

        /// Updates an existing document row, preserving its identifier.
        private static func updateDocument(_ document: IndexedDocument, id: UUID, handle: OpaquePointer?) throws {
            var statement: OpaquePointer?
            let sql = "UPDATE indexed_documents SET display_name = ?, path = ?, message_id = ?, mailbox = ?, "
                + "mtime = ?, size_bytes = ?, content_hash = ?, mime = ?, extract_status = ?, indexed_at = ?, "
                + "metadata = ? WHERE id = ?;"
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DocIndexError.persistenceFailed("Could not prepare document update")
            }
            defer { sqlite3_finalize(statement) }
            SQLiteHelpers.bindText(statement, index: 1, value: document.displayName)
            SQLiteHelpers.bindText(statement, index: 2, value: document.path)
            SQLiteHelpers.bindText(statement, index: 3, value: document.messageID)
            SQLiteHelpers.bindText(statement, index: 4, value: document.mailbox)
            bindOptionalDouble(statement, index: 5, value: document.mtime?.timeIntervalSince1970)
            SQLiteHelpers.bindInt64(statement, index: 6, value: document.sizeBytes)
            SQLiteHelpers.bindText(statement, index: 7, value: document.contentHash)
            SQLiteHelpers.bindText(statement, index: 8, value: document.mime)
            SQLiteHelpers.bindText(statement, index: 9, value: document.extractStatus.rawValue)
            sqlite3_bind_double(statement, 10, document.indexedAt.timeIntervalSince1970)
            SQLiteHelpers.bindText(statement, index: 11, value: encodeMetadata(document.metadata))
            SQLiteHelpers.bindText(statement, index: 12, value: id.uuidString)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DocIndexError.persistenceFailed("Could not update document \(id)")
            }
        }

        /// Binds a document's columns in declaration order.
        private static func bindDocument(_ document: IndexedDocument, statement: OpaquePointer?) {
            SQLiteHelpers.bindText(statement, index: 1, value: document.id.uuidString)
            SQLiteHelpers.bindText(statement, index: 2, value: document.source.rawValue)
            SQLiteHelpers.bindText(statement, index: 3, value: document.externalID)
            SQLiteHelpers.bindText(statement, index: 4, value: document.displayName)
            SQLiteHelpers.bindText(statement, index: 5, value: document.path)
            SQLiteHelpers.bindText(statement, index: 6, value: document.messageID)
            SQLiteHelpers.bindText(statement, index: 7, value: document.mailbox)
            bindOptionalDouble(statement, index: 8, value: document.mtime?.timeIntervalSince1970)
            SQLiteHelpers.bindInt64(statement, index: 9, value: document.sizeBytes)
            SQLiteHelpers.bindText(statement, index: 10, value: document.contentHash)
            SQLiteHelpers.bindText(statement, index: 11, value: document.mime)
            SQLiteHelpers.bindText(statement, index: 12, value: document.extractStatus.rawValue)
            sqlite3_bind_double(statement, 13, document.indexedAt.timeIntervalSince1970)
            SQLiteHelpers.bindText(statement, index: 14, value: encodeMetadata(document.metadata))
        }

        /// Reads a document by source-scoped identifier.
        static func document(source: IndexSource, externalID: String, dbPath: String) throws -> IndexedDocument? {
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return nil }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            return try loadDocument(handle: handle, source: source, externalID: externalID)
        }

        /// Reads multiple documents by their identifiers.
        static func documents(ids: Set<UUID>, dbPath: String) throws -> [UUID: IndexedDocument] {
            guard !ids.isEmpty else { return [:] }
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return [:] }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            var result: [UUID: IndexedDocument] = [:]
            for id in ids {
                if let doc = try loadDocument(handle: handle, id: id) {
                    result[id] = doc
                }
            }
            return result
        }

        /// Loads a document row by primary UUID inside an open handle.
        private static func loadDocument(
            handle: OpaquePointer?,
            id: UUID
        ) throws -> IndexedDocument? {
            var statement: OpaquePointer?
            let sql = "SELECT " + documentColumnList + " FROM indexed_documents WHERE id = ?;"
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DocIndexError.persistenceFailed("Could not prepare document read by id")
            }
            defer { sqlite3_finalize(statement) }
            SQLiteHelpers.bindText(statement, index: 1, value: id.uuidString)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return readDocument(statement)
        }

        /// Loads a document row inside an open handle.
        private static func loadDocument(
            handle: OpaquePointer?,
            source: IndexSource,
            externalID: String
        ) throws -> IndexedDocument? {
            var statement: OpaquePointer?
            let sql = "SELECT " + documentColumnList + " FROM indexed_documents "
                + "WHERE source = ? AND external_id = ?;"
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DocIndexError.persistenceFailed("Could not prepare document read")
            }
            defer { sqlite3_finalize(statement) }
            SQLiteHelpers.bindText(statement, index: 1, value: source.rawValue)
            SQLiteHelpers.bindText(statement, index: 2, value: externalID)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return readDocument(statement)
        }

        /// Decodes the document at the statement's current row.
        private static func readDocument(_ statement: OpaquePointer?) -> IndexedDocument? {
            guard let idText = SQLiteHelpers.columnText(statement, index: 0),
                  let id = UUID(uuidString: idText),
                  let sourceText = SQLiteHelpers.columnText(statement, index: 1),
                  let source = IndexSource(rawValue: sourceText),
                  let externalID = SQLiteHelpers.columnText(statement, index: 2),
                  let displayName = SQLiteHelpers.columnText(statement, index: 3),
                  let contentHash = SQLiteHelpers.columnText(statement, index: 9),
                  let statusText = SQLiteHelpers.columnText(statement, index: 11),
                  let extractStatus = ExtractStatus(rawValue: statusText)
            else { return nil }
            let mtime = optionalDouble(statement, index: 7).map { Date(timeIntervalSince1970: $0) }
            let sizeBytes = SQLiteHelpers.columnInt64(statement, index: 8)
            let indexedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 12))
            return IndexedDocument(
                id: id,
                source: source,
                externalID: externalID,
                displayName: displayName,
                path: SQLiteHelpers.columnText(statement, index: 4),
                messageID: SQLiteHelpers.columnText(statement, index: 5),
                mailbox: SQLiteHelpers.columnText(statement, index: 6),
                mtime: mtime,
                sizeBytes: sizeBytes,
                contentHash: contentHash,
                mime: SQLiteHelpers.columnText(statement, index: 10),
                extractStatus: extractStatus,
                indexedAt: indexedAt,
                metadata: decodeMetadata(SQLiteHelpers.columnText(statement, index: 13))
            )
        }

        /// Reports whether a source must be re-extracted.
        static func needsReindex(
            source: IndexSource,
            externalID: String,
            contentHash: String,
            dbPath: String
        ) throws -> Bool {
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return true }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            guard let row = try existingRow(handle: handle, source: source, externalID: externalID) else {
                return true
            }
            if row.contentHash != contentHash {
                return true
            }
            // A prior extraction failure is retried even when the body is unchanged.
            return row.extractStatus == .failed
        }

        /// Reads the stored size, modification time, content hash, and extraction outcome.
        static func storedFingerprint(
            source: IndexSource,
            externalID: String,
            dbPath: String
        ) throws -> DocStoredFingerprint? {
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return nil }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            var statement: OpaquePointer?
            let sql = "SELECT mtime, size_bytes, extract_status, content_hash FROM indexed_documents "
                + "WHERE source = ? AND external_id = ?;"
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DocIndexError.persistenceFailed("Could not prepare fingerprint read")
            }
            defer { sqlite3_finalize(statement) }
            SQLiteHelpers.bindText(statement, index: 1, value: source.rawValue)
            SQLiteHelpers.bindText(statement, index: 2, value: externalID)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            let mtime = optionalDouble(statement, index: 0).map { Date(timeIntervalSince1970: $0) }
            let sizeBytes = SQLiteHelpers.columnInt64(statement, index: 1)
            guard let statusText = SQLiteHelpers.columnText(statement, index: 2),
                  let extractStatus = ExtractStatus(rawValue: statusText)
            else { return nil }
            let contentHash = SQLiteHelpers.columnText(statement, index: 3)
            return DocStoredFingerprint(
                mtime: mtime,
                sizeBytes: sizeBytes,
                extractStatus: extractStatus,
                contentHash: contentHash
            )
        }

        /// Loads all stored fingerprints for a source in a single query.
        static func storedFingerprints(
            source: IndexSource,
            dbPath: String
        ) throws -> [String: DocStoredFingerprint] {
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return [:] }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            var statement: OpaquePointer?
            let sql = "SELECT external_id, mtime, size_bytes, extract_status, content_hash "
                + "FROM indexed_documents WHERE source = ?;"
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DocIndexError.persistenceFailed("Could not prepare bulk fingerprint read")
            }
            defer { sqlite3_finalize(statement) }
            SQLiteHelpers.bindText(statement, index: 1, value: source.rawValue)
            var result: [String: DocStoredFingerprint] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let externalID = SQLiteHelpers.columnText(statement, index: 0),
                      let statusText = SQLiteHelpers.columnText(statement, index: 3),
                      let extractStatus = ExtractStatus(rawValue: statusText)
                else { continue }
                let mtime = optionalDouble(statement, index: 1).map { Date(timeIntervalSince1970: $0) }
                let sizeBytes = SQLiteHelpers.columnInt64(statement, index: 2)
                let contentHash = SQLiteHelpers.columnText(statement, index: 4)
                result[externalID] = DocStoredFingerprint(
                    mtime: mtime,
                    sizeBytes: sizeBytes,
                    extractStatus: extractStatus,
                    contentHash: contentHash
                )
            }
            return result
        }

        /// Stamps a batch of documents as seen by the current run in a single transaction.
        static func markSeenBatch(
            source: IndexSource,
            externalIDs: [String],
            runID: String,
            dbPath: String
        ) throws {
            guard !externalIDs.isEmpty else { return }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            try exec(handle: handle, sql: "BEGIN IMMEDIATE;")
            do {
                var statement: OpaquePointer?
                let sql = "UPDATE indexed_documents SET last_seen_run = ? WHERE source = ? AND external_id = ?;"
                guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                    throw DocIndexError.persistenceFailed("Could not prepare batch seen stamp")
                }
                defer { sqlite3_finalize(statement) }
                for externalID in externalIDs {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    SQLiteHelpers.bindText(statement, index: 1, value: runID)
                    SQLiteHelpers.bindText(statement, index: 2, value: source.rawValue)
                    SQLiteHelpers.bindText(statement, index: 3, value: externalID)
                    guard sqlite3_step(statement) == SQLITE_DONE else {
                        throw DocIndexError.persistenceFailed("Could not stamp seen for \(externalID)")
                    }
                }
                try exec(handle: handle, sql: "COMMIT;")
            } catch {
                try? exec(handle: handle, sql: "ROLLBACK;")
                throw error
            }
        }

        /// Commits a batch of documents and their chunks inside a single SQLite transaction.
        static func upsertDocumentsWithChunks(
            _ entries: [DocBatchUpsertEntry],
            dbPath: String
        ) throws -> [IndexedDocument] {
            guard !entries.isEmpty else { return [] }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            try exec(handle: handle, sql: "BEGIN IMMEDIATE;")
            do {
                var results: [IndexedDocument] = []
                results.reserveCapacity(entries.count)
                for entry in entries {
                    let stored = try commitEntryInTransaction(entry, handle: handle)
                    results.append(stored)
                }
                try exec(handle: handle, sql: "COMMIT;")
                return results
            } catch {
                try? exec(handle: handle, sql: "ROLLBACK;")
                throw error
            }
        }

        /// Commits one document-and-chunks entry inside an already-open transaction.
        private static func commitEntryInTransaction(
            _ entry: DocBatchUpsertEntry,
            handle: OpaquePointer?
        ) throws -> IndexedDocument {
            let document = entry.document
            let existing = try existingRow(
                handle: handle,
                source: document.source,
                externalID: document.externalID
            )
            if let existing, existing.contentHash == document.contentHash, existing.extractStatus != .failed {
                if entry.replaceChunksWhenUnchanged {
                    try deleteChunks(documentID: existing.id, handle: handle)
                    try insertChunkRows(documentID: existing.id, chunks: entry.chunks, handle: handle)
                }
                if let runID = entry.runID, !runID.isEmpty {
                    try stampDocument(handle: handle, documentID: existing.id, runID: runID)
                }
                return try loadDocument(
                    handle: handle,
                    source: document.source,
                    externalID: document.externalID
                ) ?? replacingID(of: document, with: existing.id)
            }
            let resolvedID: UUID
            if let existing {
                try updateDocument(document, id: existing.id, handle: handle)
                try deleteChunks(documentID: existing.id, handle: handle)
                resolvedID = existing.id
            } else {
                try insertDocument(document, handle: handle)
                resolvedID = document.id
            }
            try insertChunkRows(documentID: resolvedID, chunks: entry.chunks, handle: handle)
            if let runID = entry.runID, !runID.isEmpty {
                try stampDocument(handle: handle, documentID: resolvedID, runID: runID)
            }
            return resolvedID == document.id ? document : replacingID(of: document, with: resolvedID)
        }

        /// Encodes metadata as a JSON object string.
        private static func encodeMetadata(_ metadata: [String: String]) -> String? {
            guard !metadata.isEmpty else { return nil }
            do {
                let data = try JSONEncoder().encode(metadata)
                return String(data: data, encoding: .utf8)
            } catch {
                RuneWeaverLog.stores.error("DocIndexStore: failed to encode metadata: \(error.localizedDescription)")
                return nil
            }
        }

        /// Decodes a JSON metadata string back to a dictionary.
        private static func decodeMetadata(_ text: String?) -> [String: String] {
            guard let text, !text.isEmpty, let data = text.data(using: .utf8) else { return [:] }
            do {
                return try JSONDecoder().decode([String: String].self, from: data)
            } catch {
                RuneWeaverLog.stores.warning("DocIndexStore: failed to decode metadata: \(error.localizedDescription)")
                return [:]
            }
        }

        /// Binds an optional double, mapping nil to NULL.
        private static func bindOptionalDouble(_ statement: OpaquePointer?, index: Int32, value: Double?) {
            if let value {
                sqlite3_bind_double(statement, index, value)
            } else {
                sqlite3_bind_null(statement, index)
            }
        }

        /// Reads an optional double, returning nil for NULL columns.
        private static func optionalDouble(_ statement: OpaquePointer?, index: Int32) -> Double? {
            guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
            return sqlite3_column_double(statement, index)
        }
    }
#endif

// MARK: - Batch Document Operations

extension DocIndexStore {
    /// Loads all stored fingerprints for a source in a single query so indexers can preflight
    /// unchanged items in memory without per-item SQLite round-trips.
    public func storedFingerprints(source: IndexSource) async throws -> [String: DocStoredFingerprint] {
        let dbPath = self.dbPath
        return try await SQLiteSerialIO.run(lane: .indexing) {
            try DocIndexStoreIO.storedFingerprints(source: source, dbPath: dbPath)
        }
    }

    /// Stamps a batch of documents as seen by the current run in a single transaction.
    public func markSeenBatch(source: IndexSource, externalIDs: [String], runID: String) async throws {
        guard !externalIDs.isEmpty else { return }
        let dbPath = self.dbPath
        try await SQLiteSerialIO.run(lane: .indexing) {
            try DocIndexStoreIO.markSeenBatch(source: source, externalIDs: externalIDs, runID: runID, dbPath: dbPath)
        }
    }

    /// Commits a batch of documents and their chunks inside a single SQLite transaction.
    @discardableResult
    public func upsertDocumentsWithChunks(_ entries: [DocBatchUpsertEntry]) async throws -> [IndexedDocument] {
        guard !entries.isEmpty else { return [] }
        let dbPath = self.dbPath
        let result = try await SQLiteSerialIO.run(lane: .indexing) {
            try DocIndexStoreIO.upsertDocumentsWithChunks(entries, dbPath: dbPath)
        }
        await invalidateStatusCache()
        return result
    }
}

extension DocIndexStoreIO {
    /// Loads all stored fingerprints for a source in a single query.
    static func storedFingerprints(source: IndexSource, dbPath: String) throws -> [String: DocStoredFingerprint] {
        #if canImport(SQLite3)
            return try SQLiteDocIndexStore.storedFingerprints(source: source, dbPath: dbPath)
        #else
            throw DocIndexError.storeUnavailable("SQLite3 is unavailable on this platform")
        #endif
    }

    /// Stamps a batch of documents as seen by the current run in a single transaction.
    static func markSeenBatch(source: IndexSource, externalIDs: [String], runID: String, dbPath: String) throws {
        #if canImport(SQLite3)
            try SQLiteDocIndexStore.markSeenBatch(source: source, externalIDs: externalIDs, runID: runID, dbPath: dbPath)
        #else
            throw DocIndexError.storeUnavailable("SQLite3 is unavailable on this platform")
        #endif
    }

    /// Commits a batch of documents and their chunks inside a single SQLite transaction.
    static func upsertDocumentsWithChunks(_ entries: [DocBatchUpsertEntry], dbPath: String) throws -> [IndexedDocument] {
        #if canImport(SQLite3)
            return try SQLiteDocIndexStore.upsertDocumentsWithChunks(entries, dbPath: dbPath)
        #else
            throw DocIndexError.storeUnavailable("SQLite3 is unavailable on this platform")
        #endif
    }
}

// Rune Weaver Core — Document rows for the local document index.
//
// Holds the document write and read path for `SQLiteDocIndexStore`: content-hash
// gated upserts that preserve the stable identifier, row binding in declaration
// order, source-scoped reads, reindex checks that retry failed extractions, and
// JSON metadata plus optional-double codecs. Chunk lifecycle stays in
// `DocIndexStoreChunks.swift` and schema plus maintenance live beside it.

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

        /// Reads the stored size, modification time, and extraction outcome.
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
            let sql = "SELECT mtime, size_bytes, extract_status FROM indexed_documents "
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
            return DocStoredFingerprint(mtime: mtime, sizeBytes: sizeBytes, extractStatus: extractStatus)
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

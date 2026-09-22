// Rune Weaver Core — Deletion and aggregation for the document index.
//
// Holds the maintenance path for `SQLiteDocIndexStore`: document deletion with
// chunk cleanup, aggregate statistics with the newest `indexed_at` watermark,
// cutoff pruning plus vacuum, full reset, and the scalar plus parameterized
// statement helpers behind them. Document and chunk rows live beside it.

import Foundation

#if canImport(SQLite3)
    import SQLite3
#endif

#if canImport(SQLite3)
    /// Deletion, aggregation, and reset for the document index.
    extension SQLiteDocIndexStore {
        /// Deletes a document and its chunks.
        static func deleteDocument(id: UUID, dbPath: String) throws -> Bool {
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return false }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            try exec(handle: handle, sql: "BEGIN IMMEDIATE;")
            do {
                try deleteChunks(documentID: id, handle: handle)
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(handle, "DELETE FROM indexed_documents WHERE id = ?;", -1, &statement, nil) == SQLITE_OK else {
                    throw DocIndexError.persistenceFailed("Could not prepare document delete")
                }
                SQLiteHelpers.bindText(statement, index: 1, value: id.uuidString)
                let step = sqlite3_step(statement)
                sqlite3_finalize(statement)
                guard step == SQLITE_DONE else {
                    throw DocIndexError.persistenceFailed("Could not delete document \(id)")
                }
                let removed = sqlite3_changes(handle) > 0
                try exec(handle: handle, sql: "COMMIT;")
                return removed
            } catch {
                try? exec(handle: handle, sql: "ROLLBACK;")
                throw error
            }
        }

        /// Aggregates current index statistics.
        /// The watermark is the newest `indexed_at` in the store, so recall
        /// and status surfaces report the last write rather than the read
        /// time; an empty or missing store reports the epoch.
        static func stats(dbPath: String) throws -> IndexStats {
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else {
                return IndexStats(
                    documents: 0,
                    chunks: 0,
                    vectorChunks: 0,
                    keywordChunks: 0,
                    bytes: 0,
                    indexAsOf: Date(timeIntervalSince1970: 0)
                )
            }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            let documents = try scalarInt(handle: handle, sql: "SELECT COUNT(*) FROM indexed_documents;")
            let chunks = try scalarInt(handle: handle, sql: "SELECT COUNT(*) FROM indexed_chunks;")
            let vectorChunks = try scalarInt(
                handle: handle,
                sql: "SELECT COUNT(*) FROM indexed_chunks WHERE is_vector = 1;"
            )
            let bytes = try scalarInt64(
                handle: handle,
                sql: "SELECT COALESCE(SUM(LENGTH(CAST(chunk_text AS BLOB))), 0) FROM indexed_chunks;"
            )
            let indexAsOf = try scalarMaxIndexedAt(handle: handle)
            return IndexStats(
                documents: documents,
                chunks: chunks,
                vectorChunks: vectorChunks,
                keywordChunks: max(chunks - vectorChunks, 0),
                bytes: bytes,
                indexAsOf: indexAsOf
            )
        }

        /// Deletes documents indexed before a cutoff, then reclaims file space.
        static func prune(before cutoff: Date, dbPath: String) throws -> Int {
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return 0 }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            try exec(handle: handle, sql: "BEGIN IMMEDIATE;")
            let removed: Int
            do {
                try exec(
                    handle: handle,
                    sql: "DELETE FROM indexed_chunks WHERE document_id IN "
                        + "(SELECT id FROM indexed_documents WHERE indexed_at < ?);",
                    parameters: [.double(cutoff.timeIntervalSince1970)]
                )
                try exec(
                    handle: handle,
                    sql: "DELETE FROM indexed_documents WHERE indexed_at < ?;",
                    parameters: [.double(cutoff.timeIntervalSince1970)]
                )
                removed = Int(sqlite3_changes(handle))
                try exec(handle: handle, sql: "COMMIT;")
            } catch {
                try? exec(handle: handle, sql: "ROLLBACK;")
                throw error
            }
            // VACUUM cannot run inside a transaction, so it follows the committed
            // delete batch and reclaims the space the removed rows held.
            try exec(handle: handle, sql: "VACUUM;")
            return removed
        }

        /// Clears every document, chunk, and search-index entry.
        static func reset(dbPath: String) throws {
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            try exec(handle: handle, sql: "BEGIN IMMEDIATE;")
            do {
                // Chunk deletes fire the FTS delete triggers, so the search
                // index empties alongside the content in the same transaction.
                try exec(handle: handle, sql: "DELETE FROM indexed_chunks; DELETE FROM indexed_documents;")
                try exec(handle: handle, sql: "COMMIT;")
            } catch {
                try? exec(handle: handle, sql: "ROLLBACK;")
                throw error
            }
            try exec(handle: handle, sql: "VACUUM;")
        }

        /// Executes a parameterized SQL statement.
        private static func exec(handle: OpaquePointer?, sql: String, parameters: [SQLiteValue]) throws {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DocIndexError.persistenceFailed("Could not prepare statement")
            }
            defer { sqlite3_finalize(statement) }
            for (offset, value) in parameters.enumerated() {
                let index = Int32(offset + 1)
                switch value {
                case let .double(number):
                    sqlite3_bind_double(statement, index, number)
                case let .text(string):
                    SQLiteHelpers.bindText(statement, index: index, value: string)
                }
            }
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DocIndexError.persistenceFailed("Could not execute statement")
            }
        }

        /// Reads a single integer aggregate.
        private static func scalarInt(handle: OpaquePointer?, sql: String) throws -> Int {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DocIndexError.persistenceFailed("Could not prepare count")
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(statement, 0))
        }

        /// Reads a single 64-bit aggregate.
        private static func scalarInt64(handle: OpaquePointer?, sql: String) throws -> Int64 {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DocIndexError.persistenceFailed("Could not prepare sum")
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return sqlite3_column_int64(statement, 0)
        }

        /// Reads the newest `indexed_at` watermark, falling back to the epoch
        /// when the store holds no documents so callers never mistake an
        /// empty index for a freshly written one.
        private static func scalarMaxIndexedAt(handle: OpaquePointer?) throws -> Date {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "SELECT MAX(indexed_at) FROM indexed_documents;", -1, &statement, nil) == SQLITE_OK else {
                throw DocIndexError.persistenceFailed("Could not prepare watermark")
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return Date(timeIntervalSince1970: 0) }
            guard sqlite3_column_type(statement, 0) != SQLITE_NULL else { return Date(timeIntervalSince1970: 0) }
            return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
        }
    }

    /// Bound values accepted by the maintenance statement helper.
    enum SQLiteValue {
        /// A double bound to a REAL column.
        case double(Double)
        /// A string bound to a TEXT column.
        case text(String)
    }
#endif

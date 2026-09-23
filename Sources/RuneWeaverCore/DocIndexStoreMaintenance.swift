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
                    indexAsOf: Date(timeIntervalSince1970: 0),
                    bySource: [],
                    byExtractStatus: []
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
            let bySource = try sourceAggregates(handle: handle)
            let byExtractStatus = try extractStatusAggregates(handle: handle)
            return IndexStats(
                documents: documents,
                chunks: chunks,
                vectorChunks: vectorChunks,
                keywordChunks: max(chunks - vectorChunks, 0),
                bytes: bytes,
                indexAsOf: indexAsOf,
                bySource: bySource,
                byExtractStatus: byExtractStatus
            )
        }

        /// Aggregates per-source document, chunk, and byte counts.
        ///
        /// Document counts group the `indexed_documents` table directly while
        /// chunk and byte counts join through `indexed_chunks`, so a document
        /// without chunks still contributes its document row with zero chunks
        /// and bytes. Only sources holding at least one document are returned,
        /// in canonical `IndexSource` order.
        private static func sourceAggregates(handle: OpaquePointer?) throws -> [IndexSourceStats] {
            let documentCounts = try groupedCounts(
                handle: handle,
                sql: "SELECT source, COUNT(*) FROM indexed_documents GROUP BY source;"
            )
            let chunkCounts = try groupedCounts(
                handle: handle,
                sql: "SELECT d.source, COUNT(c.id) FROM indexed_chunks c "
                    + "JOIN indexed_documents d ON d.id = c.document_id GROUP BY d.source;"
            )
            let byteSums = try groupedSums(
                handle: handle,
                sql: "SELECT d.source, COALESCE(SUM(LENGTH(CAST(c.chunk_text AS BLOB))), 0) "
                    + "FROM indexed_chunks c JOIN indexed_documents d ON d.id = c.document_id GROUP BY d.source;"
            )
            var aggregates: [IndexSourceStats] = []
            for source in IndexSource.allCases {
                guard let documents = documentCounts[source.rawValue] else { continue }
                let chunks = chunkCounts[source.rawValue] ?? 0
                let bytes = byteSums[source.rawValue] ?? 0
                aggregates.append(IndexSourceStats(
                    source: source,
                    documents: documents,
                    chunks: chunks,
                    bytes: bytes
                ))
            }
            return aggregates
        }

        /// Aggregates document counts grouped by extraction outcome.
        ///
        /// Only statuses holding at least one document are returned, in
        /// canonical `ExtractStatus` order, so a fresh store reports an empty
        /// breakdown instead of a row of zeros.
        private static func extractStatusAggregates(handle: OpaquePointer?) throws -> [IndexExtractStatusStats] {
            let counts = try groupedCounts(
                handle: handle,
                sql: "SELECT extract_status, COUNT(*) FROM indexed_documents GROUP BY extract_status;"
            )
            var aggregates: [IndexExtractStatusStats] = []
            for status in ExtractStatus.allCases {
                guard let documents = counts[status.rawValue] else { continue }
                aggregates.append(IndexExtractStatusStats(status: status, documents: documents))
            }
            return aggregates
        }

        /// Reads a two-column `GROUP BY` mapping into text keys, sharing one
        /// prepare/step/finalize loop across count and sum queries. The caller
        /// supplies how the second column becomes a value, so the two
        /// aggregates differ only in that accessor while rows without a text
        /// key are skipped rather than recorded under an empty key.
        private static func groupedValues<Value>(handle: OpaquePointer?, sql: String, prepareError: String, extract: (OpaquePointer?) -> Value) throws -> [String: Value] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DocIndexError.persistenceFailed(prepareError)
            }
            defer { sqlite3_finalize(statement) }
            var values: [String: Value] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let key = SQLiteHelpers.columnText(statement, index: 0) else { continue }
                values[key] = extract(statement)
            }
            return values
        }

        /// Reads a two-column `GROUP BY` count mapping into text keys.
        private static func groupedCounts(handle: OpaquePointer?, sql: String) throws -> [String: Int] {
            try groupedValues(handle: handle, sql: sql, prepareError: "Could not prepare grouped count") {
                Int(sqlite3_column_int64($0, 1))
            }
        }

        /// Reads a two-column `GROUP BY` byte-sum mapping into text keys.
        private static func groupedSums(handle: OpaquePointer?, sql: String) throws -> [String: Int64] {
            try groupedValues(handle: handle, sql: sql, prepareError: "Could not prepare grouped sum") {
                sqlite3_column_int64($0, 1)
            }
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

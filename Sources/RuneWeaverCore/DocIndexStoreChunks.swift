// Rune Weaver Core — Chunk rows and keyword search for the document index.

import Foundation
import os

#if canImport(SQLite3)
    import SQLite3
#endif

#if canImport(SQLite3)
    /// Decides whether a chunk write should fail, letting tests prove the
    /// atomic commit rolls back instead of leaving a half-written document.
    public typealias DocIndexChunkFailureHook = @Sendable (IndexedChunk) -> Bool

    /// Lock guarding the injectable chunk-write failure hook so parallel
    /// index workers and tests never race on the override.
    private let docIndexChunkFailureLock = OSAllocatedUnfairLock(initialState: DocIndexChunkFailureHook?.none)

    /// Chunk persistence and keyword retrieval for the document index.
    extension SQLiteDocIndexStore {
        /// Injectable hook forcing chunk writes to fail.
        static var chunkInsertFailureHook: DocIndexChunkFailureHook? {
            get { docIndexChunkFailureLock.withLock { $0 } }
            set { docIndexChunkFailureLock.withLock { $0 = newValue } }
        }

        /// Inserts chunk rows inside the caller's transaction.
        static func insertChunkRows(documentID: UUID, chunks: [IndexedChunk], handle: OpaquePointer?) throws {
            guard !chunks.isEmpty else { return }
            let hook = chunkInsertFailureHook
            var statement: OpaquePointer?
            let sql = "INSERT INTO indexed_chunks(id, document_id, ordinal, chunk_text, embedding, is_vector) "
                + "VALUES(?, ?, ?, ?, ?, ?);"
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DocIndexError.persistenceFailed("Could not prepare chunk insert")
            }
            defer { sqlite3_finalize(statement) }
            var effectiveDim = (try? readEmbeddingMeta(handle: handle))?.dimension
            if effectiveDim == nil,
               let firstWidth = chunks.first(where: { $0.isVector && !$0.embedding.isEmpty })?.embedding.count,
               firstWidth > 0
            {
                for chunk in chunks where chunk.isVector && !chunk.embedding.isEmpty {
                    guard chunk.embedding.count == firstWidth else {
                        throw DocIndexError.persistenceFailed(
                            "Vector dimension mismatch: chunk has \(chunk.embedding.count), store requires \(firstWidth)"
                        )
                    }
                }
                var pinStatement: OpaquePointer?
                let pinSQL = "INSERT INTO schema_meta(key, value) VALUES('embedding_dimension', ?) "
                    + "ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
                if sqlite3_prepare_v2(handle, pinSQL, -1, &pinStatement, nil) == SQLITE_OK {
                    SQLiteHelpers.bindText(pinStatement, index: 1, value: String(firstWidth))
                    _ = sqlite3_step(pinStatement)
                    sqlite3_finalize(pinStatement)
                } else if pinStatement != nil {
                    sqlite3_finalize(pinStatement)
                }
                effectiveDim = firstWidth
            }
            for chunk in chunks {
                if chunk.isVector, !chunk.embedding.isEmpty, let expected = effectiveDim {
                    guard chunk.embedding.count == expected else {
                        throw DocIndexError.persistenceFailed(
                            "Vector dimension mismatch: chunk has \(chunk.embedding.count), store requires \(expected)"
                        )
                    }
                }
                // The hook fires inside the transaction so a failure after an
                // earlier row proves the whole commit rolls back together.
                if let hook, hook(chunk) {
                    throw DocIndexError.persistenceFailed("Could not write chunk \(chunk.id)")
                }
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                SQLiteHelpers.bindText(statement, index: 1, value: chunk.id.uuidString)
                SQLiteHelpers.bindText(statement, index: 2, value: documentID.uuidString)
                sqlite3_bind_int(statement, 3, SQLiteHelpers.sqliteLimit(chunk.ordinal))
                SQLiteHelpers.bindText(statement, index: 4, value: chunk.text)
                bindEmbedding(statement, index: 5, value: chunk.embedding)
                sqlite3_bind_int(statement, 6, chunk.isVector ? 1 : 0)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw DocIndexError.persistenceFailed("Could not write chunk \(chunk.id)")
                }
            }
        }

        /// Replaces all chunks for a document.
        static func upsertChunks(documentID: UUID, chunks: [IndexedChunk], dbPath: String) throws -> Int {
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            try exec(handle: handle, sql: "BEGIN IMMEDIATE;")
            do {
                try deleteChunks(documentID: documentID, handle: handle)
                try insertChunkRows(documentID: documentID, chunks: chunks, handle: handle)
                try exec(handle: handle, sql: "COMMIT;")
                return chunks.count
            } catch {
                try? exec(handle: handle, sql: "ROLLBACK;")
                throw error
            }
        }

        /// Deletes every chunk for a document.
        static func deleteChunks(documentID: UUID, handle: OpaquePointer?) throws {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "DELETE FROM indexed_chunks WHERE document_id = ?;", -1, &statement, nil) == SQLITE_OK else {
                throw DocIndexError.persistenceFailed("Could not prepare chunk delete")
            }
            defer { sqlite3_finalize(statement) }
            SQLiteHelpers.bindText(statement, index: 1, value: documentID.uuidString)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DocIndexError.persistenceFailed("Could not delete chunks for \(documentID)")
            }
        }

        /// Full-text search over chunk text with a LIKE fallback.
        static func searchKeyword(query: String, limit: Int, dbPath: String, since: Date? = nil, until: Date? = nil) throws -> [IndexedChunk] {
            guard limit > 0 else { return [] }
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return [] }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            // Windowed reads share the vector pool's windowed ceiling so the
            // keyword leg and the vector leg widen together; unbounded reads
            // keep the plain per-read cap.
            let maxLimit = (since != nil || until != nil) ? maxVectorWindowResults : maxResults
            let clamped = SQLiteHelpers.sqliteLimit(min(limit, maxLimit))
            if since == nil, until == nil {
                var statement: OpaquePointer?
                let sql = """
                SELECT c.id, c.document_id, c.ordinal, c.chunk_text, c.embedding, c.is_vector
                FROM indexed_chunks_fts JOIN indexed_chunks c ON c.rowid = indexed_chunks_fts.rowid
                WHERE indexed_chunks_fts MATCH ? ORDER BY rank, c.rowid DESC LIMIT ?;
                """
                if sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK {
                    SQLiteHelpers.bindText(statement, index: 1, value: ftsEscaped(trimmed))
                    sqlite3_bind_int(statement, 2, clamped)
                    var results: [IndexedChunk] = []
                    var step = sqlite3_step(statement)
                    while step == SQLITE_ROW {
                        if let chunk = readChunk(statement) {
                            results.append(chunk)
                        }
                        step = sqlite3_step(statement)
                    }
                    let succeeded = (step == SQLITE_DONE)
                    sqlite3_finalize(statement)
                    if succeeded, !results.isEmpty {
                        return results
                    }
                    // Fall through to the LIKE scan when FTS succeeds empty or errors
                    // after prepare, so stemming gaps and token mismatches still recall
                    // literal matches.
                } else if statement != nil {
                    sqlite3_finalize(statement)
                }
                return try likeSearch(query: trimmed, limit: clamped, handle: handle)
            }
            var statement: OpaquePointer?
            var sql = "SELECT c.id, c.document_id, c.ordinal, c.chunk_text, c.embedding, c.is_vector "
                + "FROM indexed_chunks_fts JOIN indexed_chunks c ON c.rowid = indexed_chunks_fts.rowid "
                + "JOIN indexed_documents d ON d.id = c.document_id "
                + "WHERE indexed_chunks_fts MATCH ?"
            if since != nil {
                sql += " AND d.mtime >= ?"
            }
            if until != nil {
                sql += " AND d.mtime < ?"
            }
            sql += " ORDER BY rank, c.rowid DESC LIMIT ?;"
            if sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK {
                var bindIndex: Int32 = 1
                SQLiteHelpers.bindText(statement, index: bindIndex, value: ftsEscaped(trimmed))
                bindIndex += 1
                let range = TemporalRange(since: since, until: until)
                let bounds = TemporalFilter.unixBounds(for: range)
                if let lower = bounds.since {
                    sqlite3_bind_double(statement, bindIndex, lower)
                    bindIndex += 1
                }
                if let upper = bounds.until {
                    sqlite3_bind_double(statement, bindIndex, upper)
                    bindIndex += 1
                }
                sqlite3_bind_int(statement, bindIndex, clamped)
                var results: [IndexedChunk] = []
                var step = sqlite3_step(statement)
                while step == SQLITE_ROW {
                    if let chunk = readChunk(statement) {
                        results.append(chunk)
                    }
                    step = sqlite3_step(statement)
                }
                let succeeded = (step == SQLITE_DONE)
                sqlite3_finalize(statement)
                if succeeded, !results.isEmpty {
                    return results
                }
                // Fall through to the bounded LIKE scan when FTS succeeds empty
                // or errors after prepare, so the dated window still applies to
                // literal matches.
            } else if statement != nil {
                sqlite3_finalize(statement)
            }
            return try likeSearch(query: trimmed, limit: clamped, handle: handle, since: since, until: until)
        }

        /// Token-overlap LIKE scan used when FTS returns nothing.
        private static func likeSearch(query: String, limit: Int32, handle: OpaquePointer?, since: Date? = nil, until: Date? = nil) throws -> [IndexedChunk] {
            let maxLikePatterns = 50
            let salient = Tokenization.salientTokens(from: query)
            let tokens = Array(salient.prefix(maxLikePatterns - 1))
            guard !tokens.isEmpty else { return [] }
            var patterns = ["%\(likeEscaped(query))%"]
            for token in tokens {
                let pattern = "%\(likeEscaped(token))%"
                if !patterns.contains(where: { $0.caseInsensitiveCompare(pattern) == .orderedSame }) {
                    patterns.append(pattern)
                }
                if patterns.count >= maxLikePatterns {
                    break
                }
            }
            let conditions = patterns.map { _ in "chunk_text LIKE ? ESCAPE '\\'" }.joined(separator: " OR ")
            if since == nil, until == nil {
                let sql = "SELECT id, document_id, ordinal, chunk_text, embedding, is_vector FROM indexed_chunks "
                    + "WHERE (\(conditions)) ORDER BY rowid DESC LIMIT ?;"
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                    throw DocIndexError.persistenceFailed("Could not prepare keyword search")
                }
                defer { sqlite3_finalize(statement) }
                for (index, pattern) in patterns.enumerated() {
                    SQLiteHelpers.bindText(statement, index: Int32(index + 1), value: pattern)
                }
                sqlite3_bind_int(statement, Int32(patterns.count + 1), limit)
                var results: [IndexedChunk] = []
                while sqlite3_step(statement) == SQLITE_ROW {
                    if let chunk = readChunk(statement) {
                        results.append(chunk)
                    }
                }
                return results
            }
            let boundedConditions = patterns.map { _ in "c.chunk_text LIKE ? ESCAPE '\\'" }.joined(separator: " OR ")
            var sql = "SELECT c.id, c.document_id, c.ordinal, c.chunk_text, c.embedding, c.is_vector FROM indexed_chunks c "
                + "JOIN indexed_documents d ON d.id = c.document_id "
                + "WHERE (\(boundedConditions))"
            if since != nil {
                sql += " AND d.mtime >= ?"
            }
            if until != nil {
                sql += " AND d.mtime < ?"
            }
            sql += " ORDER BY c.rowid DESC LIMIT ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DocIndexError.persistenceFailed("Could not prepare keyword search")
            }
            defer { sqlite3_finalize(statement) }
            var bindIndex: Int32 = 1
            for pattern in patterns {
                SQLiteHelpers.bindText(statement, index: bindIndex, value: pattern)
                bindIndex += 1
            }
            let likeRange = TemporalRange(since: since, until: until)
            let likeBounds = TemporalFilter.unixBounds(for: likeRange)
            if let lower = likeBounds.since {
                sqlite3_bind_double(statement, bindIndex, lower)
                bindIndex += 1
            }
            if let upper = likeBounds.until {
                sqlite3_bind_double(statement, bindIndex, upper)
                bindIndex += 1
            }
            sqlite3_bind_int(statement, bindIndex, limit)
            var results: [IndexedChunk] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let chunk = readChunk(statement) {
                    results.append(chunk)
                }
            }
            return results
        }

        /// Reads chunks carrying an embedding, bounded by `limit`.
        static func chunkVectors(limit: Int, dbPath: String, since: Date? = nil, until: Date? = nil) throws -> [IndexedChunk] {
            guard limit > 0 else { return [] }
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return [] }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            let maxLimit = (since != nil || until != nil) ? maxVectorWindowResults : maxResults
            let clamped = SQLiteHelpers.sqliteLimit(min(limit, maxLimit))
            if since == nil, until == nil {
                // The dated leg leads with `indexed_documents` so the `mtime` index supplies
                // event-time order and stops after `limit` rows instead of sorting every vector
                // chunk with its embedding payload.
                let datedSQL = "SELECT c.id, c.document_id, c.ordinal, c.chunk_text, c.embedding, c.is_vector FROM indexed_documents d "
                    + "JOIN indexed_chunks c ON c.document_id = d.id "
                    + "WHERE c.is_vector = 1 AND d.mtime IS NOT NULL ORDER BY d.mtime DESC, c.rowid DESC LIMIT ?;"
                var datedStatement: OpaquePointer?
                guard sqlite3_prepare_v2(handle, datedSQL, -1, &datedStatement, nil) == SQLITE_OK else {
                    throw DocIndexError.persistenceFailed("Could not prepare vector read")
                }
                defer { sqlite3_finalize(datedStatement) }
                sqlite3_bind_int(datedStatement, 1, clamped)
                var results: [IndexedChunk] = []
                while sqlite3_step(datedStatement) == SQLITE_ROW {
                    if let chunk = readChunk(datedStatement) {
                        results.append(chunk)
                    }
                }
                // A full dated leg already decides the caller's window, so the
                // tail cannot change the returned rows.
                let need = Int(clamped) - results.count
                guard need > 0 else { return results }
                // The tail covers only chunks no dated scan could see — a missing parent row or a
                // NULL parent event time — in newest insertion order, so undated documents never
                // crowd out dated ones yet stay candidates like the keyword path's table-only read.
                let tailSQL = "SELECT c.id, c.document_id, c.ordinal, c.chunk_text, c.embedding, c.is_vector FROM indexed_chunks c "
                    + "LEFT JOIN indexed_documents d ON d.id = c.document_id "
                    + "WHERE c.is_vector = 1 AND (d.id IS NULL OR d.mtime IS NULL) ORDER BY c.rowid DESC LIMIT ?;"
                var tailStatement: OpaquePointer?
                guard sqlite3_prepare_v2(handle, tailSQL, -1, &tailStatement, nil) == SQLITE_OK else {
                    throw DocIndexError.persistenceFailed("Could not prepare vector read")
                }
                defer { sqlite3_finalize(tailStatement) }
                sqlite3_bind_int(tailStatement, 1, SQLiteHelpers.sqliteLimit(need))
                while sqlite3_step(tailStatement) == SQLITE_ROW {
                    if let chunk = readChunk(tailStatement) {
                        results.append(chunk)
                    }
                }
                return results
            }
            var sql = "SELECT c.id, c.document_id, c.ordinal, c.chunk_text, c.embedding, c.is_vector FROM indexed_documents d "
                + "JOIN indexed_chunks c ON c.document_id = d.id "
                + "WHERE c.is_vector = 1"
            if since != nil {
                sql += " AND d.mtime >= ?"
            }
            if until != nil {
                sql += " AND d.mtime < ?"
            }
            // Windowed reads keep their bounds; only the pool order changes to event time so recent
            // happenings outrank recent writes.
            sql += " ORDER BY d.mtime DESC, c.rowid DESC LIMIT ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DocIndexError.persistenceFailed("Could not prepare vector read")
            }
            defer { sqlite3_finalize(statement) }
            var bindIndex: Int32 = 1
            let vectorRange = TemporalRange(since: since, until: until)
            let vectorBounds = TemporalFilter.unixBounds(for: vectorRange)
            if let lower = vectorBounds.since {
                sqlite3_bind_double(statement, bindIndex, lower)
                bindIndex += 1
            }
            if let upper = vectorBounds.until {
                sqlite3_bind_double(statement, bindIndex, upper)
                bindIndex += 1
            }
            sqlite3_bind_int(statement, bindIndex, clamped)
            var results: [IndexedChunk] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let chunk = readChunk(statement) {
                    results.append(chunk)
                }
            }
            return results
        }

        /// Decodes the chunk at the statement's current row.
        private static func readChunk(_ statement: OpaquePointer?) -> IndexedChunk? {
            guard let idText = SQLiteHelpers.columnText(statement, index: 0),
                  let id = UUID(uuidString: idText),
                  let documentText = SQLiteHelpers.columnText(statement, index: 1),
                  let documentID = UUID(uuidString: documentText),
                  let text = SQLiteHelpers.columnText(statement, index: 3)
            else { return nil }
            let ordinal = Int(sqlite3_column_int(statement, 2))
            let embedding = decodeEmbedding(statement, index: 4)
            let isVector = sqlite3_column_int(statement, 5) != 0
            return IndexedChunk(
                id: id,
                documentID: documentID,
                ordinal: ordinal,
                text: text,
                embedding: embedding,
                isVector: isVector
            )
        }

        /// Escapes LIKE metacharacters so literal text never acts as a wildcard.
        private static func likeEscaped(_ query: String) -> String {
            var escaped = query.replacingOccurrences(of: "\\", with: "\\\\")
            escaped = escaped.replacingOccurrences(of: "%", with: "\\%")
            escaped = escaped.replacingOccurrences(of: "_", with: "\\_")
            return escaped
        }

        /// Escapes user text into a safe FTS5 phrase query.
        private static func ftsEscaped(_ query: String) -> String {
            let tokens = Tokenization.salientTokens(from: query)
            guard !tokens.isEmpty else { return "\"\"" }
            let phrases = tokens.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            return phrases.joined(separator: " OR ")
        }

        /// Binds an embedding as a little-endian Float32 blob, or NULL when empty.
        private static func bindEmbedding(_ statement: OpaquePointer?, index: Int32, value: [Float]) {
            guard !value.isEmpty else {
                sqlite3_bind_null(statement, index)
                return
            }
            var data = Data(capacity: value.count * MemoryLayout<Float>.size)
            for element in value {
                var bits = element.bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
            }
            data.withUnsafeBytes { buffer in
                _ = sqlite3_bind_blob(
                    statement,
                    index,
                    buffer.baseAddress,
                    Int32(data.count),
                    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                )
            }
        }

        /// Decodes a little-endian Float32 embedding blob.
        private static func decodeEmbedding(_ statement: OpaquePointer?, index: Int32) -> [Float] {
            guard sqlite3_column_type(statement, index) != SQLITE_NULL,
                  let pointer = sqlite3_column_blob(statement, index)
            else { return [] }
            let byteCount = Int(sqlite3_column_bytes(statement, index))
            let width = MemoryLayout<Float>.size
            guard byteCount > 0, byteCount % width == 0 else { return [] }
            let raw = UnsafeRawBufferPointer(start: pointer, count: byteCount)
            var embedding: [Float] = []
            embedding.reserveCapacity(byteCount / width)
            for offset in Swift.stride(from: 0, to: byteCount, by: width) {
                let bits = raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                embedding.append(Float(bitPattern: UInt32(littleEndian: bits)))
            }
            return embedding
        }
    }
#endif

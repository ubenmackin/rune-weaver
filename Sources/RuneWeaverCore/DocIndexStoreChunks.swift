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

        /// Batched ID lookup width so large hit sets never build one giant IN clause.
        private static let chunkFetchBatchSize = 500

        /// Cap on LIKE patterns so long queries cannot fan out into unbounded scans.
        private static let maxLikePatterns = 50

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

        /// Full-text search over chunk text with prefix matching on salient tokens.
        /// Bounded reads gate every source on parent event time with NULLs excluded.
        static func searchKeyword(query: String, limit: Int, dbPath: String, since: Date? = nil, until: Date? = nil) throws -> [IndexedChunk] {
            guard limit > 0 else { return [] }
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return [] }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            let maxLimit = (since != nil || until != nil) ? maxVectorWindowResults : maxResults
            let clamped = SQLiteHelpers.sqliteLimit(min(limit, maxLimit))
            guard clamped > 0 else { return [] }
            let ftsQuery = ftsEscaped(trimmed)
            if !ftsQuery.isEmpty {
                do {
                    let ftsHits = try searchFTSChunks(handle: handle, ftsQuery: ftsQuery, limit: clamped, since: since, until: until)
                    if !ftsHits.isEmpty {
                        return ftsHits
                    }
                } catch let error as CancellationError {
                    throw error
                } catch let error as DocIndexError {
                    // Persistence failures fail closed so corruption never masquerades as a syntax miss.
                    RuneWeaverLog.stores.warning("DocIndexStore: FTS search failed: \(error)")
                    throw error
                } catch {
                    // Syntax-only fallback keeps one bad token from failing the read.
                    RuneWeaverLog.stores.warning("DocIndexStore: FTS query failed, falling back to LIKE: \(error)")
                }
            }
            return try searchLIKEChunks(handle: handle, query: trimmed, limit: clamped, since: since, until: until)
        }

        /// FTS5 keyword scan. Unbounded reads hit the porter table only; dated reads
        /// join the parent so every source honors `mtime` with NULLs excluded.
        private static func searchFTSChunks(handle: OpaquePointer?, ftsQuery: String, limit: Int32, since: Date?, until: Date?) throws -> [IndexedChunk] {
            var statement: OpaquePointer?
            let bounded = since != nil || until != nil
            var sql = "SELECT c.id, c.document_id, c.ordinal, c.chunk_text, c.embedding, c.is_vector "
                + "FROM indexed_chunks_fts JOIN indexed_chunks c ON c.rowid = indexed_chunks_fts.rowid "
            if bounded {
                sql += "JOIN indexed_documents d ON d.id = c.document_id "
            }
            sql += "WHERE indexed_chunks_fts MATCH ?"
            if bounded {
                // Explicit NULL guard so undated rows never slip into a dated window.
                sql += " AND d.mtime IS NOT NULL"
            }
            if since != nil {
                sql += " AND d.mtime >= ?"
            }
            if until != nil {
                sql += " AND d.mtime < ?"
            }
            sql += " ORDER BY rank, c.rowid DESC LIMIT ?;"
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                if statement != nil {
                    sqlite3_finalize(statement)
                }
                throw DocIndexError.persistenceFailed("Could not prepare keyword search")
            }
            defer { sqlite3_finalize(statement) }
            var bindIndex: Int32 = 1
            SQLiteHelpers.bindText(statement, index: bindIndex, value: ftsQuery)
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
            sqlite3_bind_int(statement, bindIndex, limit)
            var results: [IndexedChunk] = []
            var step = sqlite3_step(statement)
            while step == SQLITE_ROW {
                if let chunk = readChunk(statement) {
                    results.append(chunk)
                }
                step = sqlite3_step(statement)
            }
            guard step == SQLITE_DONE else {
                // SQLITE_ERROR here means the MATCH query itself was rejected;
                // other codes signal corruption and must fail closed.
                if let handle, sqlite3_errcode(handle) == SQLITE_ERROR {
                    let message = sqlite3_errmsg(handle).map { String(cString: $0) } ?? "unknown FTS error"
                    RuneWeaverLog.stores.warning("DocIndexStore: FTS syntax failed, falling back to LIKE: \(message)")
                    return []
                }
                throw DocIndexError.persistenceFailed("Could not read keyword results")
            }
            return results
        }

        /// Fetches chunks by their UUIDs in batched lookups.
        static func chunks(ids: Set<UUID>, dbPath: String) throws -> [UUID: IndexedChunk] {
            guard !ids.isEmpty else { return [:] }
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return [:] }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }

            var results: [UUID: IndexedChunk] = [:]
            results.reserveCapacity(ids.count)

            let idArray = Array(ids)
            for start in stride(from: 0, to: idArray.count, by: chunkFetchBatchSize) {
                let end = min(start + chunkFetchBatchSize, idArray.count)
                let batch = Array(idArray[start ..< end])
                let fetched = try fetchChunkBatch(batch, handle: handle)
                for chunk in fetched {
                    results[chunk.id] = chunk
                }
            }
            return results
        }

        /// Fetches one ID batch with per-batch finalization.
        private static func fetchChunkBatch(_ batch: [UUID], handle: OpaquePointer?) throws -> [IndexedChunk] {
            let placeholders = batch.map { _ in "?" }.joined(separator: ",")
            let sql = """
            SELECT id, document_id, ordinal, chunk_text, embedding, is_vector
            FROM indexed_chunks WHERE id IN (\(placeholders));
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                if statement != nil {
                    sqlite3_finalize(statement)
                }
                throw DocIndexError.persistenceFailed("Could not prepare chunk fetch by IDs")
            }
            defer { sqlite3_finalize(statement) }
            for (offset, id) in batch.enumerated() {
                SQLiteHelpers.bindText(statement, index: Int32(offset + 1), value: id.uuidString)
            }
            var rows: [IndexedChunk] = []
            var step = sqlite3_step(statement)
            while step == SQLITE_ROW {
                if let chunk = readChunk(statement) {
                    rows.append(chunk)
                }
                step = sqlite3_step(statement)
            }
            guard step == SQLITE_DONE else {
                throw DocIndexError.persistenceFailed("Could not read chunk fetch by IDs")
            }
            return rows
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

        /// Escapes LIKE wildcards so literal fragments never act as patterns.
        private static func likeEscaped(_ query: String) -> String {
            var escaped = query.replacingOccurrences(of: "\\", with: "\\\\")
            escaped = escaped.replacingOccurrences(of: "%", with: "\\%")
            escaped = escaped.replacingOccurrences(of: "_", with: "\\_")
            return escaped
        }

        /// Builds LIKE patterns with the full query first so exact phrases stay contiguous.
        private static func likePatterns(for query: String) -> [String] {
            var patterns = ["%\(likeEscaped(query))%"]
            // Bound upfront so duplicate-heavy queries never scan the full token list.
            let salient = Array(Tokenization.salientTokens(from: query).prefix(maxLikePatterns - 1))
            for token in salient {
                let pattern = "%\(likeEscaped(token))%"
                let duplicated = patterns.contains { $0.caseInsensitiveCompare(pattern) == .orderedSame }
                if !duplicated {
                    patterns.append(pattern)
                }
                guard patterns.count < maxLikePatterns else { break }
            }
            return patterns
        }

        /// LIKE fragment scan carrying sub-token queries with every-source gating.
        private static func searchLIKEChunks(handle: OpaquePointer?, query: String, limit: Int32, since: Date?, until: Date?) throws -> [IndexedChunk] {
            let patterns = likePatterns(for: query)
            guard !patterns.isEmpty else { return [] }
            let bounded = since != nil || until != nil
            var sql = "SELECT c.id, c.document_id, c.ordinal, c.chunk_text, c.embedding, c.is_vector FROM indexed_chunks c "
            if bounded {
                sql += "JOIN indexed_documents d ON d.id = c.document_id "
            }
            let conditions = patterns.map { _ in "c.chunk_text LIKE ? ESCAPE '\\'" }.joined(separator: " OR ")
            sql += "WHERE (\(conditions))"
            if bounded {
                // Explicit NULL guard so undated rows never slip into a dated window.
                sql += " AND d.mtime IS NOT NULL"
            }
            if since != nil {
                sql += " AND d.mtime >= ?"
            }
            if until != nil {
                sql += " AND d.mtime < ?"
            }
            sql += " ORDER BY c.rowid DESC LIMIT ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                if statement != nil {
                    sqlite3_finalize(statement)
                }
                throw DocIndexError.persistenceFailed("Could not prepare keyword search")
            }
            defer { sqlite3_finalize(statement) }
            var bindIndex: Int32 = 1
            for pattern in patterns {
                SQLiteHelpers.bindText(statement, index: bindIndex, value: pattern)
                bindIndex += 1
            }
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
            sqlite3_bind_int(statement, bindIndex, limit)
            var results: [IndexedChunk] = []
            var step = sqlite3_step(statement)
            while step == SQLITE_ROW {
                if let chunk = readChunk(statement) {
                    results.append(chunk)
                }
                step = sqlite3_step(statement)
            }
            guard step == SQLITE_DONE else {
                throw DocIndexError.persistenceFailed("Could not read keyword results")
            }
            return results
        }

        /// Escapes user text into a safe FTS5 query with prefix matching for salient terms.
        /// Star stays outside the quotes so quoted terms keep valid prefix syntax.
        private static func ftsEscaped(_ query: String) -> String {
            // Cap MATCH terms like LIKE patterns so pasted documents cannot blow up the parser.
            let tokens = Array(Tokenization.salientTokens(from: query).prefix(maxLikePatterns))
            guard !tokens.isEmpty else { return "" }
            let phrases = tokens.map { token in
                let sanitized = token.replacingOccurrences(of: "\"", with: "\"\"")
                if token.count >= 3 {
                    return "\"\(sanitized)\"*"
                }
                return "\"\(sanitized)\""
            }
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

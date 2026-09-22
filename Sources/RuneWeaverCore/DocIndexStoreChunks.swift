// Rune Weaver Core — Chunk rows and keyword search for the document index.
//
// Holds the chunk write path plus retrieval: chunk replacement per document,
// FTS5 keyword search with a LIKE fallback for stemming gaps, newest-first
// vector reads for the capped semantic pool, row decoding, FTS and LIKE
// escaping, and little-endian Float32 embedding codecs. Document rows live in
// `DocIndexStoreDocuments.swift` and schema plus maintenance live beside it.

import Foundation

#if canImport(SQLite3)
    import SQLite3
#endif

#if canImport(SQLite3)
    /// Chunk persistence and keyword retrieval for the document index.
    extension SQLiteDocIndexStore {
        /// Replaces all chunks for a document.
        static func upsertChunks(documentID: UUID, chunks: [IndexedChunk], dbPath: String) throws -> Int {
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            try exec(handle: handle, sql: "BEGIN IMMEDIATE;")
            do {
                try deleteChunks(documentID: documentID, handle: handle)
                guard !chunks.isEmpty else {
                    try exec(handle: handle, sql: "COMMIT;")
                    return 0
                }
                var statement: OpaquePointer?
                let sql = "INSERT INTO indexed_chunks(id, document_id, ordinal, chunk_text, embedding, is_vector) "
                    + "VALUES(?, ?, ?, ?, ?, ?);"
                guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                    throw DocIndexError.persistenceFailed("Could not prepare chunk insert")
                }
                defer { sqlite3_finalize(statement) }
                for chunk in chunks {
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
        static func searchKeyword(query: String, limit: Int, dbPath: String) throws -> [IndexedChunk] {
            guard limit > 0 else { return [] }
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return [] }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            let clamped = SQLiteHelpers.sqliteLimit(min(limit, maxResults))
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

        /// Token-overlap LIKE scan used when FTS returns nothing.
        private static func likeSearch(query: String, limit: Int32, handle: OpaquePointer?) throws -> [IndexedChunk] {
            let maxLikePatterns = 50
            let tokens = Array(Tokenization.tokenize(query).sorted().prefix(maxLikePatterns - 1))
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

        /// Reads the newest chunks carrying an embedding, bounded by `limit`.
        /// Newest-first ordering keeps the capped semantic pool over recent
        /// writes; callers needing full-corpus recall must page the bound.
        static func chunkVectors(limit: Int, dbPath: String) throws -> [IndexedChunk] {
            guard limit > 0 else { return [] }
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return [] }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            let sql = "SELECT id, document_id, ordinal, chunk_text, embedding, is_vector FROM indexed_chunks "
                + "WHERE is_vector = 1 ORDER BY rowid DESC LIMIT ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DocIndexError.persistenceFailed("Could not prepare vector read")
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, SQLiteHelpers.sqliteLimit(min(limit, maxResults)))
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
            let tokens = query.split { $0.isWhitespace || $0.isNewline }.map { String($0) }.filter { !$0.isEmpty }
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

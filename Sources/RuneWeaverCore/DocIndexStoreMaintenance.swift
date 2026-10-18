// Rune Weaver Core — Deletion and aggregation for the document index.

import Foundation
import os

#if canImport(SQLite3)
    import SQLite3
#endif

#if canImport(SQLite3)
    /// Per-object page-byte reader for the document index size split.
    public typealias DocIndexDbstatProbe = @Sendable (OpaquePointer?) -> [String: Int64]?

    /// Lock guarding the injectable size probe so test overrides stay race-free.
    private let docIndexDbstatProbeLock = OSAllocatedUnfairLock(initialState: DocIndexDbstatProbe?.none)

    /// Decides whether an aggregate refresh should fail, letting tests prove
    /// a failed refresh keeps the prior row instead of clearing the tables.
    public typealias DocIndexAggregateFailureHook = @Sendable () -> Bool

    /// Lock guarding the injectable aggregate-write failure hook so parallel
    /// refreshes and tests never race on the override.
    private let docIndexAggregateFailureLock = OSAllocatedUnfairLock(initialState: DocIndexAggregateFailureHook?.none)

    /// Lock guarding per-database aggregate-write failure hooks so parallel tests over isolated
    /// temporary files stay isolated from each other.
    private let docIndexAggregateFailurePerPathLock = OSAllocatedUnfairLock(initialState: [String: DocIndexAggregateFailureHook]())

    /// Raw grouped chunk/text aggregates from the single chunk/text pass.
    private struct GroupedChunkAggregates {
        /// Chunk counts and text bytes keyed by observed source string.
        var bySource: [String: (count: Int, bytes: Int64)]
        /// Chunks on the NULL-source row without a parent document row.
        var orphanChunks: Int
        /// Text bytes on the NULL-source row without a parent document row.
        var orphanBytes: Int64
    }

    /// Per-source breakdown plus exact snapshot totals from the same pass.
    private struct SourceAggregateResult {
        /// Per-source aggregates in canonical `IndexSource` order.
        var bySource: [IndexSourceStats]
        /// Exact chunk total including unknown sources and orphan chunks.
        var totalChunks: Int
        /// Exact text-byte total including unknown sources and orphan bytes.
        var totalBytes: Int64
    }
#endif

/// Lock guarding per-database aggregate-pass counters so parallel status polls stay race-free.
private let docIndexStatusSnapshotCounterLock = OSAllocatedUnfairLock(initialState: [String: Int]())

/// Shared aggregate snapshot backing both status projections.
struct DocIndexStatusSnapshot: Sendable, Equatable {
    /// Indexed document count.
    var documents: Int
    /// Stored chunk count.
    var chunks: Int
    /// Chunks carrying an embedding.
    var vectorChunks: Int
    /// Logical chunk text bytes.
    var textBytes: Int64
    /// Logical embedding bytes over vector chunks.
    var vectorBytes: Int64
    /// Newest `indexed_at` watermark, epoch when empty.
    var indexAsOf: Date
    /// Per-source aggregates in canonical order.
    var bySource: [IndexSourceStats]
    /// Extraction-outcome aggregates in canonical order.
    var byExtractStatus: [IndexExtractStatusStats]
    /// On-disk database file size in bytes.
    var dbFileBytes: Int64
    /// Write-ahead log size in bytes.
    var walBytes: Int64
    /// Full-text page bytes, or nil when the `dbstat` table is unavailable.
    var ftsBytes: Int64?
    /// Freelist bytes reclaimable by `VACUUM`.
    var freeBytes: Int64

    /// Projects the statistics view from the shared snapshot.
    func makeStats() -> IndexStats {
        let keywordChunks = max(chunks - vectorChunks, 0)
        let textSplit: Int64?
        let vectorSplit: Int64?
        let ftsSplit: Int64?
        if let ftsBytes {
            textSplit = textBytes
            vectorSplit = vectorBytes
            ftsSplit = ftsBytes
        } else {
            textSplit = nil
            vectorSplit = nil
            ftsSplit = nil
        }
        return IndexStats(
            documents: documents,
            chunks: chunks,
            vectorChunks: vectorChunks,
            keywordChunks: keywordChunks,
            bytes: textBytes,
            indexAsOf: indexAsOf,
            bySource: bySource,
            byExtractStatus: byExtractStatus,
            dbFileBytes: dbFileBytes,
            walBytes: walBytes,
            textBytes: textSplit,
            vectorBytes: vectorSplit,
            ftsBytes: ftsSplit,
            freeBytes: freeBytes,
            contentBytes: IndexContentBytes.contentBytes(textBytes: textBytes, vectorBytes: vectorBytes)
        )
    }

    /// Projects the storage view from the shared snapshot.
    func makeBreakdown() -> IndexStorageBreakdown {
        IndexStorageBreakdown(
            dbFileBytes: dbFileBytes,
            walBytes: walBytes,
            textBytes: textBytes,
            vectorBytes: vectorBytes,
            ftsBytes: ftsBytes ?? 0,
            freeBytes: freeBytes,
            contentBytes: IndexContentBytes.contentBytes(textBytes: textBytes, vectorBytes: vectorBytes)
        )
    }

    /// Projects the fast status view from the shared snapshot. Pending-zero slow legs apply only
    /// when no persisted row exists (fail-closed zeros from the cheap COUNT path), never when a
    /// snapshot is in hand.
    func makeFastStats() -> IndexStats {
        makeStats()
    }
}

#if canImport(SQLite3)
    /// Deletion, aggregation, and reset for the document index.
    extension SQLiteDocIndexStore {
        /// Injectable `dbstat` probe overriding the grouped page-byte read.
        public static var dbstatProbeOverride: DocIndexDbstatProbe? {
            get { docIndexDbstatProbeLock.withLock { $0 } }
            set { docIndexDbstatProbeLock.withLock { $0 = newValue } }
        }

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

        /// Stamps one document as seen by the current run.
        static func markSeen(source: IndexSource, externalID: String, runID: String, dbPath: String) throws {
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            try exec(
                handle: handle,
                sql: "UPDATE indexed_documents SET last_seen_run = ? WHERE source = ? AND external_id = ?;",
                parameters: [.text(runID), .text(source.rawValue), .text(externalID)]
            )
        }

        /// Deletes `files` documents not seen by the given run.
        static func retireUnseenFiles(runID: String, dbPath: String) throws -> Int {
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
                        + "(SELECT id FROM indexed_documents WHERE source = ? "
                        + "AND (last_seen_run IS NULL OR last_seen_run != ?));",
                    parameters: [.text(IndexSource.files.rawValue), .text(runID)]
                )
                try exec(
                    handle: handle,
                    sql: "DELETE FROM indexed_documents WHERE source = ? "
                        + "AND (last_seen_run IS NULL OR last_seen_run != ?);",
                    parameters: [.text(IndexSource.files.rawValue), .text(runID)]
                )
                removed = Int(sqlite3_changes(handle))
                try exec(handle: handle, sql: "COMMIT;")
            } catch {
                try? exec(handle: handle, sql: "ROLLBACK;")
                throw error
            }
            return removed
        }

        /// Deletes `mail` documents whose mailbox sits in the denied set.
        static func retireMailboxes(mailboxes: Set<String>, dbPath: String) throws -> Int {
            let trimmed = mailboxes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard !trimmed.isEmpty else { return 0 }
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return 0 }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            let placeholders = Array(repeating: "?", count: trimmed.count).joined(separator: ", ")
            let chunkSQL = "DELETE FROM indexed_chunks WHERE document_id IN "
                + "(SELECT id FROM indexed_documents WHERE source = ? AND mailbox IN (\(placeholders)));"
            let docSQL = "DELETE FROM indexed_documents WHERE source = ? AND mailbox IN (\(placeholders));"
            var parameters: [SQLiteValue] = [.text(IndexSource.mail.rawValue)]
            parameters.append(contentsOf: trimmed.map { SQLiteValue.text($0) })
            try exec(handle: handle, sql: "BEGIN IMMEDIATE;")
            let removed: Int
            do {
                try exec(handle: handle, sql: chunkSQL, parameters: parameters)
                try exec(handle: handle, sql: docSQL, parameters: parameters)
                removed = Int(sqlite3_changes(handle))
                try exec(handle: handle, sql: "COMMIT;")
            } catch {
                try? exec(handle: handle, sql: "ROLLBACK;")
                throw error
            }
            return removed
        }

        /// Reads distinct content hashes for `mail` documents in the denied set.
        static func mailContentHashes(mailboxes: Set<String>, dbPath: String) throws -> Set<String> {
            let trimmed = mailboxes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard !trimmed.isEmpty else { return [] }
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return [] }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            let placeholders = Array(repeating: "?", count: trimmed.count).joined(separator: ", ")
            let sql = "SELECT DISTINCT content_hash FROM indexed_documents WHERE source = ? AND mailbox IN (\(placeholders));"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DocIndexError.persistenceFailed("Could not prepare mailbox hash read")
            }
            defer { sqlite3_finalize(statement) }
            SQLiteHelpers.bindText(statement, index: 1, value: IndexSource.mail.rawValue)
            for (offset, mailbox) in trimmed.enumerated() {
                SQLiteHelpers.bindText(statement, index: Int32(offset + 2), value: mailbox)
            }
            var hashes = Set<String>()
            while sqlite3_step(statement) == SQLITE_ROW {
                if let hash = SQLiteHelpers.columnText(statement, index: 0) {
                    hashes.insert(hash)
                }
            }
            return hashes
        }

        /// Number of aggregate passes performed in this process across all databases.
        static var statusSnapshotComputeCount: Int {
            docIndexStatusSnapshotCounterLock.withLock { $0.values.reduce(0, +) }
        }

        /// Reads the aggregate-pass count for one database file.
        static func statusSnapshotComputeCount(for dbPath: String) -> Int {
            let key = canonicalDBPath(dbPath)
            return docIndexStatusSnapshotCounterLock.withLock { $0[key] ?? 0 }
        }

        /// Resets the aggregate-pass counter so isolated tests start from zero.
        static func resetStatusSnapshotComputeCountForTesting() {
            docIndexStatusSnapshotCounterLock.withLock { $0.removeAll() }
        }

        /// Resets the aggregate-pass count for one database file. Clears only the caller's
        /// canonical entry so parallel tests over other files keep their counts.
        static func resetStatusSnapshotComputeCountForTesting(for dbPath: String) {
            let key = canonicalDBPath(dbPath)
            _ = docIndexStatusSnapshotCounterLock.withLock { $0.removeValue(forKey: key) }
        }

        /// Reads the shared status snapshot with the live size probe.
        /// - Parameter dbPath: SQLite file path. `~` is expanded.
        /// - Returns: The shared aggregate snapshot.
        static func statusSnapshot(dbPath: String) throws -> DocIndexStatusSnapshot {
            try statusSnapshot(dbPath: dbPath, dbstatProbe: dbstatProbeOverride)
        }

        /// Reads the shared status snapshot with an injectable size probe. dbPath:
        /// SQLite file path.
        static func statusSnapshot(dbPath: String, dbstatProbe: DocIndexDbstatProbe?) throws -> DocIndexStatusSnapshot {
            try computeStatusSnapshot(dbPath: dbPath, dbstatProbe: dbstatProbe)
        }

        /// Injectable hook forcing aggregate refresh writes to fail. Tests use it to prove a failed
        /// refresh keeps the prior aggregate row instead of leaving empty tables behind.
        static var aggregateWriteFailureHook: DocIndexAggregateFailureHook? {
            get { docIndexAggregateFailureLock.withLock { $0 } }
            set { docIndexAggregateFailureLock.withLock { $0 = newValue } }
        }

        /// Registers a per-database hook forcing aggregate refresh writes to fail.
        static func setAggregateWriteFailureHook(_ hook: DocIndexAggregateFailureHook?, for dbPath: String) {
            let key = canonicalDBPath(dbPath)
            docIndexAggregateFailurePerPathLock.withLock { hooks in
                if let hook {
                    hooks[key] = hook
                } else {
                    hooks.removeValue(forKey: key)
                }
            }
        }

        /// Clears the per-database aggregate-write failure hook for one file.
        /// - Parameter dbPath: SQLite file path whose hook is removed.
        static func clearAggregateWriteFailureHook(for dbPath: String) {
            let key = canonicalDBPath(dbPath)
            _ = docIndexAggregateFailurePerPathLock.withLock { $0.removeValue(forKey: key) }
        }

        /// Recomputes the aggregate tables from a fresh single-pass snapshot.
        static func refreshAggregates(
            dbPath: String,
            producingRunID: String? = nil,
            updatedAt: Date = Date()
        ) throws -> DocIndexStatusSnapshot {
            let snapshot = try computeStatusSnapshot(dbPath: dbPath, dbstatProbe: dbstatProbeOverride)
            // `open(dbPath:)` canonicalizes through the shared ensure gate internally, so the write
            // needs no separate resolution here; only the failure-hook lookup keys on the canonical
            // path so parallel tests over isolated files stay isolated from each other.
            let hookKey = canonicalDBPath(dbPath)
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            try exec(handle: handle, sql: "BEGIN IMMEDIATE;")
            do {
                // Per-path hooks are checked before the process-wide hook so a
                // parallel test's injected failure on another file never fails
                // this refresh; either hook throwing rolls back this path only.
                let perPathHook: DocIndexAggregateFailureHook? = docIndexAggregateFailurePerPathLock.withLock { $0[hookKey] }
                if let perPathHook, perPathHook() {
                    throw DocIndexError.persistenceFailed("Could not refresh aggregates (injected failure)")
                }
                if let hook = aggregateWriteFailureHook, hook() {
                    throw DocIndexError.persistenceFailed("Could not refresh aggregates (injected failure)")
                }
                try writeAggregates(handle: handle, snapshot: snapshot, producingRunID: producingRunID, updatedAt: updatedAt)
                try exec(handle: handle, sql: "COMMIT;")
            } catch {
                try? exec(handle: handle, sql: "ROLLBACK;")
                throw error
            }
            return snapshot
        }

        /// Replaces all three aggregate tables inside the caller's transaction.
        private static func writeAggregates(
            handle: OpaquePointer?,
            snapshot: DocIndexStatusSnapshot,
            producingRunID: String?,
            updatedAt: Date
        ) throws {
            try exec(handle: handle, sql: "DELETE FROM index_aggregates; DELETE FROM index_aggregate_by_source; DELETE FROM index_aggregate_by_extract_status;")
            var single: OpaquePointer?
            let singleSQL =
                "INSERT INTO index_aggregates(id, documents, chunks, vector_chunks, text_bytes, vector_bytes, "
                    + "fts_bytes, index_as_of, updated_at, producing_run_id) VALUES(0, ?, ?, ?, ?, ?, ?, ?, ?, ?);"
            guard sqlite3_prepare_v2(handle, singleSQL, -1, &single, nil) == SQLITE_OK else {
                throw DocIndexError.persistenceFailed("Could not prepare aggregate write")
            }
            defer { sqlite3_finalize(single) }
            sqlite3_bind_int64(single, 1, Int64(snapshot.documents))
            sqlite3_bind_int64(single, 2, Int64(snapshot.chunks))
            sqlite3_bind_int64(single, 3, Int64(snapshot.vectorChunks))
            sqlite3_bind_int64(single, 4, snapshot.textBytes)
            sqlite3_bind_int64(single, 5, snapshot.vectorBytes)
            SQLiteHelpers.bindInt64(single, index: 6, value: snapshot.ftsBytes)
            sqlite3_bind_double(single, 7, snapshot.indexAsOf.timeIntervalSince1970)
            sqlite3_bind_double(single, 8, updatedAt.timeIntervalSince1970)
            SQLiteHelpers.bindText(single, index: 9, value: producingRunID)
            guard sqlite3_step(single) == SQLITE_DONE else {
                throw DocIndexError.persistenceFailed("Could not write aggregates")
            }
            for entry in snapshot.bySource {
                var statement: OpaquePointer?
                let sql = "INSERT INTO index_aggregate_by_source(source, documents, chunks, bytes) VALUES(?, ?, ?, ?);"
                guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                    throw DocIndexError.persistenceFailed("Could not prepare source aggregate write")
                }
                SQLiteHelpers.bindText(statement, index: 1, value: entry.source.rawValue)
                sqlite3_bind_int64(statement, 2, Int64(entry.documents))
                sqlite3_bind_int64(statement, 3, Int64(entry.chunks))
                sqlite3_bind_int64(statement, 4, entry.bytes)
                let step = sqlite3_step(statement)
                sqlite3_finalize(statement)
                guard step == SQLITE_DONE else {
                    throw DocIndexError.persistenceFailed("Could not write source aggregates")
                }
            }
            for entry in snapshot.byExtractStatus {
                var statement: OpaquePointer?
                let sql = "INSERT INTO index_aggregate_by_extract_status(status, documents) VALUES(?, ?);"
                guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                    throw DocIndexError.persistenceFailed("Could not prepare status aggregate write")
                }
                SQLiteHelpers.bindText(statement, index: 1, value: entry.status.rawValue)
                sqlite3_bind_int64(statement, 2, Int64(entry.documents))
                let step = sqlite3_step(statement)
                sqlite3_finalize(statement)
                guard step == SQLITE_DONE else {
                    throw DocIndexError.persistenceFailed("Could not write status aggregates")
                }
            }
        }

        /// Reads the persisted aggregate snapshot without running any content scan.
        static func readAggregateSnapshot(dbPath: String) throws -> DocIndexStatusSnapshot? {
            let expanded = (dbPath as NSString).expandingTildeInPath
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            var single: OpaquePointer?
            let singleSQL = "SELECT documents, chunks, vector_chunks, text_bytes, vector_bytes, fts_bytes, index_as_of FROM index_aggregates WHERE id = 0;"
            guard sqlite3_prepare_v2(handle, singleSQL, -1, &single, nil) == SQLITE_OK else {
                sqlite3_finalize(single)
                return nil
            }
            defer { sqlite3_finalize(single) }
            guard sqlite3_step(single) == SQLITE_ROW else { return nil }
            let documents = Int(sqlite3_column_int64(single, 0))
            let chunks = Int(sqlite3_column_int64(single, 1))
            let vectorChunks = Int(sqlite3_column_int64(single, 2))
            let textBytes = sqlite3_column_int64(single, 3)
            let vectorBytes = sqlite3_column_int64(single, 4)
            let ftsBytes: Int64? = sqlite3_column_type(single, 5) == SQLITE_NULL ? nil : sqlite3_column_int64(single, 5)
            let indexAsOf = Date(timeIntervalSince1970: sqlite3_column_double(single, 6))
            guard let bySource = readAggregateBySource(handle: handle),
                  let byExtractStatus = readAggregateByExtractStatus(handle: handle)
            else {
                return nil
            }
            // Page-counter probes ride fail-closed zeros: a throwing PRAGMA must not fail a warm
            // poll that already holds a valid aggregate row.
            let pageCount: Int
            do {
                pageCount = try scalarInt(handle: handle, sql: "PRAGMA page_count;")
            } catch {
                RuneWeaverLog.stores.debug("DocIndexStore: failed to query PRAGMA page_count: \(error.localizedDescription)")
                pageCount = 0
            }
            let pageSize: Int
            do {
                pageSize = try scalarInt(handle: handle, sql: "PRAGMA page_size;")
            } catch {
                RuneWeaverLog.stores.debug("DocIndexStore: failed to query PRAGMA page_size: \(error.localizedDescription)")
                pageSize = 0
            }
            let freelistCount: Int
            do {
                freelistCount = try scalarInt(handle: handle, sql: "PRAGMA freelist_count;")
            } catch {
                RuneWeaverLog.stores.debug("DocIndexStore: failed to query PRAGMA freelist_count: \(error.localizedDescription)")
                freelistCount = 0
            }
            let pageSizeBytes = Int64(max(pageSize, 0))
            let dbFileBytes = resolvedDbFileBytes(pageCount: pageCount, pageSizeBytes: pageSizeBytes, expandedPath: expanded)
            let freeBytes = Int64(max(freelistCount, 0)) * pageSizeBytes
            let walBytes = onDiskBytes(at: expanded + "-wal")
            return DocIndexStatusSnapshot(
                documents: documents,
                chunks: chunks,
                vectorChunks: vectorChunks,
                textBytes: textBytes,
                vectorBytes: vectorBytes,
                indexAsOf: indexAsOf,
                bySource: bySource,
                byExtractStatus: byExtractStatus,
                dbFileBytes: dbFileBytes,
                walBytes: walBytes,
                ftsBytes: ftsBytes,
                freeBytes: freeBytes
            )
        }

        private static func readAggregateBySource(handle: OpaquePointer?) -> [IndexSourceStats]? {
            var sourceStatement: OpaquePointer?
            guard sqlite3_prepare_v2(
                handle,
                "SELECT source, documents, chunks, bytes FROM index_aggregate_by_source;",
                -1,
                &sourceStatement,
                nil
            ) == SQLITE_OK else {
                sqlite3_finalize(sourceStatement)
                return nil
            }
            defer { sqlite3_finalize(sourceStatement) }
            var sourceRows: [String: IndexSourceStats] = [:]
            while sqlite3_step(sourceStatement) == SQLITE_ROW {
                guard let key = SQLiteHelpers.columnText(sourceStatement, index: 0) else { continue }
                // Unknown source keys (manual SQL or a future source value) never enter the typed
                // breakdown — the child tables stay keyed by source strings with a fixed wire shape
                // — but their counts already ride the single-row totals above, so log the skip.
                guard let source = IndexSource(rawValue: key) else {
                    RuneWeaverLog.stores.warning("DocIndexStore: ignoring unknown aggregate source '\(key)'")
                    continue
                }
                sourceRows[key] = IndexSourceStats(
                    source: source,
                    documents: Int(sqlite3_column_int64(sourceStatement, 1)),
                    chunks: Int(sqlite3_column_int64(sourceStatement, 2)),
                    bytes: sqlite3_column_int64(sourceStatement, 3)
                )
            }
            var bySource: [IndexSourceStats] = []
            for source in IndexSource.allCases {
                guard let row = sourceRows[source.rawValue] else { continue }
                bySource.append(row)
            }
            return bySource
        }

        private static func readAggregateByExtractStatus(handle: OpaquePointer?) -> [IndexExtractStatusStats]? {
            var statusStatement: OpaquePointer?
            guard sqlite3_prepare_v2(
                handle,
                "SELECT status, documents FROM index_aggregate_by_extract_status;",
                -1,
                &statusStatement,
                nil
            ) == SQLITE_OK else {
                sqlite3_finalize(statusStatement)
                return nil
            }
            defer { sqlite3_finalize(statusStatement) }
            var statusCounts: [String: Int] = [:]
            while sqlite3_step(statusStatement) == SQLITE_ROW {
                guard let key = SQLiteHelpers.columnText(statusStatement, index: 0) else { continue }
                statusCounts[key] = Int(sqlite3_column_int64(statusStatement, 1))
            }
            var byExtractStatus: [IndexExtractStatusStats] = []
            for status in ExtractStatus.allCases {
                guard let row = statusCounts[status.rawValue] else { continue }
                byExtractStatus.append(IndexExtractStatusStats(status: status, documents: row))
            }
            // Unknown status keys stay out of the fixed wire shape like unknown
            // sources above, with their counts preserved in the single-row
            // totals; log them so a future status value cannot vanish silently.
            let knownStatuses = Set(ExtractStatus.allCases.map(\.rawValue))
            for key in statusCounts.keys where !knownStatuses.contains(key) {
                RuneWeaverLog.stores.warning("DocIndexStore: ignoring unknown aggregate extract status '\(key)'")
            }
            return byExtractStatus
        }

        /// Computes every status aggregate in one pass over a single open handle.
        private static func computeStatusSnapshot(dbPath: String, dbstatProbe: DocIndexDbstatProbe?) throws -> DocIndexStatusSnapshot {
            let expanded = (dbPath as NSString).expandingTildeInPath
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            let documents = try scalarInt(handle: handle, sql: "SELECT COUNT(*) FROM indexed_documents;")
            let indexAsOf = try scalarMaxIndexedAt(handle: handle)
            let sourceResult = try sourceAggregates(handle: handle)
            let bySource = sourceResult.bySource
            // Totals sum the raw grouped mapping plus the orphan bucket from the same grouped pass
            // so no full-table COUNT or SUM scans the chunks table a second time yet chunks with
            // unknown sources or without a parent row still count toward the snapshot.
            let chunks = sourceResult.totalChunks
            let textLogical: Int64 = sourceResult.totalBytes
            let byExtractStatus = try extractStatusAggregates(handle: handle)
            let pageCount = try scalarInt(handle: handle, sql: "PRAGMA page_count;")
            let pageSize = try scalarInt(handle: handle, sql: "PRAGMA page_size;")
            let freelistCount = try scalarInt(handle: handle, sql: "PRAGMA freelist_count;")
            let pageSizeBytes = Int64(max(pageSize, 0))
            let dbFileBytes = resolvedDbFileBytes(
                pageCount: pageCount,
                pageSizeBytes: pageSizeBytes,
                expandedPath: expanded
            )
            let freeBytes = Int64(max(freelistCount, 0)) * pageSizeBytes
            let walBytes = onDiskBytes(at: expanded + "-wal")
            let vector = try vectorCountAndBytes(handle: handle)
            let grouped: [String: Int64]?
            do {
                grouped = try dbstatGroupedPageBytes(handle: handle, probe: dbstatProbe)
            } catch {
                RuneWeaverLog.stores.debug("DocIndexStore: failed to query dbstat: \(error.localizedDescription)")
                grouped = nil
            }
            // Logical content bytes, not page bytes: only the FTS leg is
            // attributed via the grouped `dbstat` split.
            let ftsBytes: Int64? = if let grouped {
                ftsPageBytes(from: grouped)
            } else {
                nil
            }
            let snapshot = DocIndexStatusSnapshot(
                documents: documents,
                chunks: chunks,
                vectorChunks: vector.count,
                textBytes: textLogical,
                vectorBytes: vector.bytes,
                indexAsOf: indexAsOf,
                bySource: bySource,
                byExtractStatus: byExtractStatus,
                dbFileBytes: dbFileBytes,
                walBytes: walBytes,
                ftsBytes: ftsBytes,
                freeBytes: freeBytes
            )
            // Count only successful passes so a throwing open or query never
            // reads as a completed aggregate in the single-pass proofs.
            let counterKey = canonicalDBPath(dbPath)
            docIndexStatusSnapshotCounterLock.withLock { $0[counterKey, default: 0] += 1 }
            return snapshot
        }

        /// Aggregates current index statistics.
        static func stats(dbPath: String) throws -> IndexStats {
            try stats(dbPath: dbPath, dbstatProbe: dbstatProbeOverride)
        }

        /// Aggregates current index statistics with an injectable size probe. A nil probe result
        /// still reports file sizes with a null breakdown instead of failing.
        static func stats(dbPath: String, dbstatProbe: DocIndexDbstatProbe?) throws -> IndexStats {
            try computeStatusSnapshot(dbPath: dbPath, dbstatProbe: dbstatProbe).makeStats()
        }

        /// Reads fast index counts without measuring content bytes.
        static func fastStats(dbPath: String) throws -> IndexStats {
            let expanded = (dbPath as NSString).expandingTildeInPath
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            let documents = try scalarInt(handle: handle, sql: "SELECT COUNT(*) FROM indexed_documents;")
            let chunks = try scalarInt(handle: handle, sql: "SELECT COUNT(*) FROM indexed_chunks;")
            let vectorChunks = try scalarInt(handle: handle, sql: "SELECT COUNT(*) FROM indexed_chunks WHERE is_vector = 1;")
            let indexAsOf = try scalarMaxIndexedAt(handle: handle)
            let documentCounts = try groupedCounts(
                handle: handle,
                sql: "SELECT source, COUNT(*) FROM indexed_documents GROUP BY source;"
            )
            // Inner join keeps only chunks with a live parent row; totals stay
            // exact via the full-table COUNT above while per-source rows cover
            // joined sources in canonical order with pending zero bytes.
            let chunkCounts = try groupedCounts(
                handle: handle,
                sql: "SELECT d.source, COUNT(c.id) FROM indexed_chunks c JOIN indexed_documents d ON d.id = c.document_id GROUP BY d.source;"
            )
            let extractCounts = try groupedCounts(
                handle: handle,
                sql: "SELECT extract_status, COUNT(*) FROM indexed_documents GROUP BY extract_status;"
            )
            var bySource: [IndexSourceStats] = []
            for source in IndexSource.allCases {
                guard let sourceDocuments = documentCounts[source.rawValue] else { continue }
                let sourceChunks = chunkCounts[source.rawValue] ?? 0
                bySource.append(IndexSourceStats(
                    source: source,
                    documents: sourceDocuments,
                    chunks: sourceChunks,
                    bytes: 0
                ))
            }
            var byExtractStatus: [IndexExtractStatusStats] = []
            for status in ExtractStatus.allCases {
                guard let statusDocuments = extractCounts[status.rawValue] else { continue }
                byExtractStatus.append(IndexExtractStatusStats(status: status, documents: statusDocuments))
            }
            let dbFileBytes = onDiskBytes(at: expanded)
            let walBytes = onDiskBytes(at: expanded + "-wal")
            let keywordChunks = max(chunks - vectorChunks, 0)
            return IndexStats(
                documents: documents,
                chunks: chunks,
                vectorChunks: vectorChunks,
                keywordChunks: keywordChunks,
                bytes: 0,
                indexAsOf: indexAsOf,
                bySource: bySource,
                byExtractStatus: byExtractStatus,
                dbFileBytes: dbFileBytes,
                walBytes: walBytes,
                textBytes: nil,
                vectorBytes: nil,
                ftsBytes: nil,
                freeBytes: 0,
                contentBytes: 0
            )
        }

        /// Reads the on-disk and logical size breakdown.
        static func storageBreakdown(dbPath: String) throws -> IndexStorageBreakdown {
            try storageBreakdown(dbPath: dbPath, dbstatProbe: dbstatProbeOverride)
        }

        /// Reads the on-disk and logical size breakdown with an injectable size probe. A nil probe
        /// result degrades the full-text leg to zero instead of failing the probe.
        static func storageBreakdown(dbPath: String, dbstatProbe: DocIndexDbstatProbe?) throws -> IndexStorageBreakdown {
            try computeStatusSnapshot(dbPath: dbPath, dbstatProbe: dbstatProbe).makeBreakdown()
        }

        /// Reads per-object page bytes via one grouped `dbstat` query. An injected test probe
        /// overrides the live table; a nil probe result or a failed prepare reports unavailability
        /// instead of an empty map.
        private static func dbstatGroupedPageBytes(handle: OpaquePointer?) throws -> [String: Int64] {
            try dbstatGroupedPageBytes(handle: handle, probe: dbstatProbeOverride)
        }

        /// Reads per-object page bytes via one grouped `dbstat` query with an injectable probe.
        private static func dbstatGroupedPageBytes(handle: OpaquePointer?, probe: DocIndexDbstatProbe?) throws -> [String: Int64] {
            if let probe {
                guard let mapping = probe(handle) else {
                    throw DocIndexError.persistenceFailed("dbstat is unavailable")
                }
                return mapping
            }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                handle,
                "SELECT name, SUM(pgsize) FROM dbstat WHERE name IN (SELECT name FROM sqlite_schema WHERE name LIKE 'indexed_chunks_fts%') GROUP BY name;",
                -1,
                &statement,
                nil
            ) == SQLITE_OK else {
                throw DocIndexError.persistenceFailed("Could not prepare dbstat probe")
            }
            defer { sqlite3_finalize(statement) }
            var values: [String: Int64] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let name = SQLiteHelpers.columnText(statement, index: 0) else { continue }
                values[name] = sqlite3_column_int64(statement, 1)
            }
            return values
        }

        /// Sums full-text page bytes across the `dbstat` split.
        private static func ftsPageBytes(from grouped: [String: Int64]) -> Int64 {
            var total: Int64 = 0
            for (name, bytes) in grouped where name.hasPrefix("indexed_chunks_fts") {
                total += max(bytes, 0)
            }
            return max(total, 0)
        }

        /// Runs `VACUUM` and reports the reclaimed bytes.
        static func reclaim(dbPath: String) throws -> IndexReclaimResult {
            let expanded = (dbPath as NSString).expandingTildeInPath
            if !FileManager.default.fileExists(atPath: expanded) {
                let created = try open(dbPath: dbPath)
                sqlite3_close(created)
            }
            let beforeBytes = onDiskBytes(at: expanded) + onDiskBytes(at: expanded + "-wal")
            let handle = try open(dbPath: dbPath)
            do {
                try exec(handle: handle, sql: "VACUUM;")
            } catch {
                sqlite3_close(handle)
                throw error
            }
            sqlite3_close(handle)
            let afterBytes = onDiskBytes(at: expanded) + onDiskBytes(at: expanded + "-wal")
            return IndexReclaimResult(
                beforeBytes: beforeBytes,
                afterBytes: afterBytes,
                reclaimedBytes: max(beforeBytes - afterBytes, 0)
            )
        }

        /// Reads one file's size, reporting zero when absent or unreadable. Keeps the breakdown and
        /// reclaim probes honest without throwing: a transiently missing WAL reads as zero rather
        /// than failing the poll.
        private static func onDiskBytes(at path: String) -> Int64 {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attributes[.size] as? NSNumber
            else {
                return 0
            }
            return max(size.int64Value, 0)
        }

        /// Resolves the on-disk database size shared by stats and the breakdown.
        static func resolvedDbFileBytes(pageCount: Int, pageSizeBytes: Int64, expandedPath: String) -> Int64 {
            let pageDerivedBytes = Int64(max(pageCount, 0)) * max(pageSizeBytes, 0)
            let fileObservedBytes = onDiskBytes(at: expandedPath)
            if fileObservedBytes > 0 {
                return fileObservedBytes
            }
            if pageDerivedBytes > 0 {
                return pageDerivedBytes
            }
            return onDiskBytes(at: expandedPath)
        }

        /// Aggregates per-source document, chunk, and byte counts plus snapshot totals. 0` fallback
        /// for chunk-less documents, so a document without chunks still contributes its document row
        /// with zero chunks and bytes.
        private static func sourceAggregates(handle: OpaquePointer?) throws -> SourceAggregateResult {
            let documentCounts = try groupedCounts(
                handle: handle,
                sql: "SELECT source, COUNT(*) FROM indexed_documents GROUP BY source;"
            )
            let chunkAggregates = try groupedChunkAggregates(
                handle: handle,
                sql: "SELECT d.source, COUNT(c.id), COALESCE(SUM(LENGTH(CAST(c.chunk_text AS BLOB))), 0) "
                    + "FROM indexed_chunks c LEFT JOIN indexed_documents d ON d.id = c.document_id GROUP BY d.source;"
            )
            var aggregates: [IndexSourceStats] = []
            for source in IndexSource.allCases {
                guard let documents = documentCounts[source.rawValue] else { continue }
                let chunks = chunkAggregates.bySource[source.rawValue]?.count ?? 0
                let bytes = chunkAggregates.bySource[source.rawValue]?.bytes ?? 0
                aggregates.append(IndexSourceStats(
                    source: source,
                    documents: documents,
                    chunks: chunks,
                    bytes: bytes
                ))
            }
            // Totals cover the raw grouped mapping plus the orphan row from
            // the same pass, so unknown or empty source strings that never
            // enter the filtered breakdown still count toward the snapshot.
            let totalChunks = chunkAggregates.bySource.values.reduce(0) { $0 + $1.count } + chunkAggregates.orphanChunks
            let totalBytes = chunkAggregates.bySource.values.reduce(Int64(0)) { $0 + $1.bytes } + chunkAggregates.orphanBytes
            return SourceAggregateResult(bySource: aggregates, totalChunks: totalChunks, totalBytes: totalBytes)
        }

        /// Reads the single grouped chunk/text pass into per-source counts and byte sums plus
        /// orphan totals.
        private static func groupedChunkAggregates(
            handle: OpaquePointer?,
            sql: String
        ) throws -> GroupedChunkAggregates {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DocIndexError.persistenceFailed("Could not prepare grouped count")
            }
            defer { sqlite3_finalize(statement) }
            var values: [String: (count: Int, bytes: Int64)] = [:]
            var orphanChunks = 0
            var orphanBytes: Int64 = 0
            while sqlite3_step(statement) == SQLITE_ROW {
                // Both aggregates come from the same row so one walk serves
                // the chunk-count and text-bytes families together.
                let count = Int(sqlite3_column_int64(statement, 1))
                let bytes = sqlite3_column_int64(statement, 2)
                guard let key = SQLiteHelpers.columnText(statement, index: 0) else {
                    orphanChunks += count
                    orphanBytes += bytes
                    continue
                }
                values[key] = (count: count, bytes: bytes)
            }
            return GroupedChunkAggregates(bySource: values, orphanChunks: orphanChunks, orphanBytes: orphanBytes)
        }

        /// Reads the vector chunk count and embedding byte total in one pass. The `COALESCE` keeps
        /// an empty index on the single `(0, 0)` row, so callers never treat absence as failure.
        private static func vectorCountAndBytes(handle: OpaquePointer?) throws -> (count: Int, bytes: Int64) {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                handle,
                "SELECT COUNT(*), COALESCE(SUM(LENGTH(embedding)), 0) FROM indexed_chunks WHERE is_vector = 1;",
                -1,
                &statement,
                nil
            ) == SQLITE_OK else {
                throw DocIndexError.persistenceFailed("Could not prepare vector count")
            }
            defer { sqlite3_finalize(statement) }
            // An aggregate without GROUP BY always yields exactly one row;
            // a missing row degrades to zeros rather than failing the poll.
            guard sqlite3_step(statement) == SQLITE_ROW else { return (count: 0, bytes: 0) }
            let count = Int(sqlite3_column_int64(statement, 0))
            let bytes = sqlite3_column_int64(statement, 1)
            return (count: count, bytes: bytes)
        }

        /// Aggregates document counts grouped by extraction outcome.
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

        /// Reads a two-column `GROUP BY` mapping into text keys, sharing one prepare/step/finalize
        /// loop across count and sum queries.
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
            guard FileManager.default.fileExists(atPath: expanded) else {
                removeEnsuredPath(dbPath)
                return
            }
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

        /// Clears documents, chunks, and FTS entries for a single source.
        static func clearSource(source: String, dbPath: String) throws -> Int {
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return 0 }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            try exec(handle: handle, sql: "BEGIN IMMEDIATE;")
            let removed: Int
            do {
                try exec(
                    handle: handle,
                    sql: "DELETE FROM indexed_chunks WHERE document_id IN (SELECT id FROM indexed_documents WHERE source = ?);",
                    parameters: [.text(source)]
                )
                try exec(
                    handle: handle,
                    sql: "DELETE FROM indexed_documents WHERE source = ?;",
                    parameters: [.text(source)]
                )
                removed = Int(sqlite3_changes(handle))
                try exec(handle: handle, sql: "COMMIT;")
            } catch {
                try? exec(handle: handle, sql: "ROLLBACK;")
                throw error
            }
            try exec(handle: handle, sql: "VACUUM;")
            return removed
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

        /// Reads the newest `indexed_at` watermark, falling back to the epoch
        /// when the store holds no documents so callers never mistake an
        /// empty index for a freshly written one.
        private static func scalarMaxIndexedAt(handle: OpaquePointer?) throws -> Date {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "SELECT MAX(indexed_at) FROM indexed_documents;", -1, &statement, nil) == SQLITE_OK else {
                throw DocIndexError.persistenceFailed("Could not prepare watermark")
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) != SQLITE_NULL else { return Date(timeIntervalSince1970: 0) }
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

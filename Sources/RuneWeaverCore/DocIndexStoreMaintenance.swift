// Rune Weaver Core — Deletion and aggregation for the document index.
//
// Holds the maintenance path for `SQLiteDocIndexStore`: document deletion with
// chunk cleanup, aggregate statistics with the newest `indexed_at` watermark,
// cutoff pruning plus vacuum, full reset, and the scalar plus parameterized
// statement helpers behind them. Document and chunk rows live beside it.

import Foundation
import os

#if canImport(SQLite3)
    import SQLite3
#endif

#if canImport(SQLite3)
    /// Per-object page-byte reader for the document index size split.
    ///
    /// Maps `dbstat` object names to summed `pgsize` bytes so the caller
    /// attributes file pages to content and search structures. Returning nil
    /// simulates a SQLite build without the `dbstat` virtual table so the
    /// size probe degrades to file sizes with a null breakdown.
    public typealias DocIndexDbstatProbe = @Sendable (OpaquePointer?) -> [String: Int64]?

    /// Lock guarding the injectable size probe so test overrides stay race-free.
    private let docIndexDbstatProbeLock = OSAllocatedUnfairLock(initialState: DocIndexDbstatProbe?.none)

    /// Decides whether an aggregate refresh should fail, letting tests prove
    /// a failed refresh keeps the prior row instead of clearing the tables.
    public typealias DocIndexAggregateFailureHook = @Sendable () -> Bool

    /// Lock guarding the injectable aggregate-write failure hook so parallel
    /// refreshes and tests never race on the override.
    private let docIndexAggregateFailureLock = OSAllocatedUnfairLock(initialState: DocIndexAggregateFailureHook?.none)

    /// Lock guarding per-database aggregate-write failure hooks so parallel
    /// tests over isolated temporary files stay isolated from each other.
    ///
    /// Keyed by canonical database path, mirroring the aggregate-pass
    /// counters below: a hook registered for one file never fails a refresh
    /// on another file sharing the process-wide store.
    private let docIndexAggregateFailurePerPathLock = OSAllocatedUnfairLock(initialState: [String: DocIndexAggregateFailureHook]())

    /// Raw grouped chunk/text aggregates from the single chunk/text pass.
    ///
    /// `bySource` holds every non-NULL source key from the grouped query,
    /// including unknown or empty strings that never enter the filtered
    /// breakdown; the orphan fields hold the NULL-source row for chunks
    /// whose parent document row is missing. Snapshot totals sum both, so
    /// manual SQL or a future source value cannot silently undercount.
    private struct GroupedChunkAggregates {
        /// Chunk counts and text bytes keyed by observed source string.
        var bySource: [String: (count: Int, bytes: Int64)]
        /// Chunks on the NULL-source row without a parent document row.
        var orphanChunks: Int
        /// Text bytes on the NULL-source row without a parent document row.
        var orphanBytes: Int64
    }

    /// Per-source breakdown plus exact snapshot totals from the same pass.
    ///
    /// `bySource` carries only known sources holding at least one document,
    /// in canonical order, while the totals cover the raw grouped mapping
    /// plus the orphan row so unknown-source rows still count toward the
    /// snapshot without a second table scan.
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
///
/// Counts are keyed by canonical database path, so tests over isolated
/// temporary files never observe passes from parallel suites sharing the
/// process-wide store.
private let docIndexStatusSnapshotCounterLock = OSAllocatedUnfairLock(initialState: [String: Int]())

/// Shared aggregate snapshot backing both status projections.
///
/// Owned by `DocIndexStore`: the actor holds one of these plus its timestamp
/// and both `stats()` and `storageBreakdown()` project from it, so a single
/// status poll performs at most one aggregate pass.
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
    ///
    /// The text, vector, and FTS legs ride the `dbstat` availability flag:
    /// an unavailable size table reports file sizes with a null split
    /// instead of failing, matching the historical stats behavior.
    /// - Returns: An index statistics snapshot with true on-disk sizes.
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
    ///
    /// Logical legs always report content bytes; only the full-text leg
    /// degrades to zero when the `dbstat` table is unavailable, matching
    /// the historical breakdown behavior.
    /// - Returns: The storage breakdown.
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

    /// Projects the fast status view from the shared snapshot.
    ///
    /// Freeze-then-jump: projects true sizes from the persisted single row
    /// via the shared snapshot so one row carries every leg and status needs
    /// no second storage fetch. Pending-zero slow legs apply only when no
    /// persisted row exists (fail-closed zeros from the cheap COUNT path),
    /// never when a snapshot is in hand.
    /// - Returns: An index statistics snapshot with true sizes from the persisted row.
    func makeFastStats() -> IndexStats {
        makeStats()
    }
}

#if canImport(SQLite3)
    /// Deletion, aggregation, and reset for the document index.
    extension SQLiteDocIndexStore {
        /// Injectable `dbstat` probe overriding the grouped page-byte read.
        ///
        /// Nil uses the live `dbstat` virtual table; a probe returning nil
        /// simulates a SQLite build without `dbstat` so the statistics path
        /// still reports file sizes with a null breakdown instead of failing.
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
        ///
        /// Records `runID` in `last_seen_run` so the end-of-run reconcile can
        /// tell a live document from one that left policy. Missing rows are a
        /// no-op so stamping a brand-new path before its first upsert stays
        /// safe; opening the database first runs the additive migration, so a
        /// legacy file without the column gains it before the update.
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
        ///
        /// Removes every `files` row whose `last_seen_run` differs from `runID`
        /// (including rows never stamped) together with their chunks, so chunk
        /// deletes fire the FTS triggers and retired text stops surfacing in
        /// keyword search. Mail and Messages rows are untouched. Space reclaim
        /// stays with the caller, which vacuums only on a non-zero return.
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
        ///
        /// The mail run gate owns matching while this call owns deletion:
        /// mailbox comparison is exact on the observed names the gate
        /// collected, so a pattern never deletes a mailbox it did not observe.
        /// Chunk deletes fire the FTS triggers and retired text stops
        /// surfacing in keyword search. Space reclaim stays with the caller,
        /// which vacuums only on a non-zero return.
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
        ///
        /// Lets the mail gate forget exactly the retired bodies so a re-allowed
        /// mailbox re-indexes instead of deduplicating against deleted rows.
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
        ///
        /// Incremented once per `computeStatusSnapshot` so tests can prove a
        /// cold poll performs exactly one pass and a TTL hit performs zero.
        /// Prefer the per-path overload in new tests: the total observes every
        /// parallel suite, while the per-path count isolates one file.
        static var statusSnapshotComputeCount: Int {
            docIndexStatusSnapshotCounterLock.withLock { $0.values.reduce(0, +) }
        }

        /// Reads the aggregate-pass count for one database file.
        ///
        /// Keyed by the canonical gate path so parallel tests over distinct
        /// temporary files stay isolated from each other.
        /// - Parameter dbPath: SQLite file path.
        /// - Returns: Passes recorded for that canonical path.
        static func statusSnapshotComputeCount(for dbPath: String) -> Int {
            let key = canonicalDBPath(dbPath)
            return docIndexStatusSnapshotCounterLock.withLock { $0[key] ?? 0 }
        }

        /// Resets the aggregate-pass counter so isolated tests start from zero.
        static func resetStatusSnapshotComputeCountForTesting() {
            docIndexStatusSnapshotCounterLock.withLock { $0.removeAll() }
        }

        /// Resets the aggregate-pass count for one database file.
        ///
        /// Clears only the caller's canonical entry so parallel tests over
        /// other files keep their counts.
        /// - Parameter dbPath: SQLite file path.
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

        /// Reads the shared status snapshot with an injectable size probe.
        /// - Parameters:
        ///   - dbPath: SQLite file path. `~` is expanded.
        ///   - dbstatProbe: Per-object page-byte reader, or nil for the live table.
        /// - Returns: The shared aggregate snapshot.
        static func statusSnapshot(dbPath: String, dbstatProbe: DocIndexDbstatProbe?) throws -> DocIndexStatusSnapshot {
            try computeStatusSnapshot(dbPath: dbPath, dbstatProbe: dbstatProbe)
        }

        /// Injectable hook forcing aggregate refresh writes to fail.
        ///
        /// Nil performs every refresh; a hook returning true throws inside the
        /// replacement transaction so the whole refresh rolls back. Tests use
        /// it to prove a failed refresh keeps the prior aggregate row instead
        /// of leaving empty tables behind.
        static var aggregateWriteFailureHook: DocIndexAggregateFailureHook? {
            get { docIndexAggregateFailureLock.withLock { $0 } }
            set { docIndexAggregateFailureLock.withLock { $0 = newValue } }
        }

        /// Registers a per-database hook forcing aggregate refresh writes to fail.
        ///
        /// Scoped by canonical database path so parallel tests over isolated
        /// temporary files never observe each other's injected failure; prefer
        /// this over the process-wide `aggregateWriteFailureHook` in new tests.
        /// A nil hook removes the entry for the path.
        /// - Parameters:
        ///   - hook: Hook forcing failure for this database, or nil to clear.
        ///   - dbPath: SQLite file path the hook applies to.
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
        ///
        /// Reuses the shared `computeStatusSnapshot` pass so the persisted
        /// rows match a live status poll field-for-field without a second
        /// table scan, then replaces all three aggregate tables inside one
        /// transaction: a crash between deletes can never strand a half-filled
        /// set. `open(dbPath:)` canonicalizes through the shared ensure gate
        /// internally, so symlink spellings share one schema with the compute
        /// above. A throwing write rolls back, preserving the previous row
        /// for readers.
        /// - Parameters:
        ///   - dbPath: SQLite file path. `~` is expanded.
        ///   - producingRunID: Opaque run identity recorded alongside the row, or nil for route-driven refreshes.
        ///   - updatedAt: Refresh instant recorded in `updated_at`.
        /// - Returns: The snapshot that was persisted.
        static func refreshAggregates(
            dbPath: String,
            producingRunID: String? = nil,
            updatedAt: Date = Date()
        ) throws -> DocIndexStatusSnapshot {
            let snapshot = try computeStatusSnapshot(dbPath: dbPath, dbstatProbe: dbstatProbeOverride)
            // `open(dbPath:)` canonicalizes through the shared ensure gate
            // internally, so the write needs no separate resolution here; only
            // the failure-hook lookup keys on the canonical path so parallel
            // tests over isolated files stay isolated from each other.
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
        ///
        /// Deletes first so a source or status that no longer holds documents
        /// disappears instead of lingering as a stale row, then inserts the
        /// single pinned row plus one row per observed source and status. Only
        /// sources and statuses holding at least one document are stored, so
        /// the tables project exactly what the live snapshot reports.
        /// - Parameters:
        ///   - handle: Open database handle owning the transaction.
        ///   - snapshot: Fresh single-pass snapshot to persist.
        ///   - producingRunID: Opaque run identity, or nil when the caller carries none.
        ///   - updatedAt: Refresh instant for `updated_at`.
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
        ///
        /// Serves warm status and storage polls from the three aggregate tables
        /// plus live file-size probes, so a poll with no intervening writes
        /// performs zero aggregate passes. The content legs (counts, text and
        /// vector bytes, watermark, per-source and per-status rows) ride the
        /// stored rows including the nullable full-text leg; only the on-disk
        /// pair and the freelist ride live filesystem and PRAGMA probes so the
        /// projection matches what a live pass would report at this instant.
        /// A missing single row or a missing aggregate table reads as absent
        /// rather than failing, letting the caller repair once through the
        /// single writer. Never touches the aggregate-pass counter, `dbstat`,
        /// or `LENGTH`, so warm-read proofs observe zero passes here.
        /// - Parameter dbPath: SQLite file path. `~` is expanded.
        /// - Returns: The persisted snapshot, or nil when no refresh has run.
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
                // Unknown source keys (manual SQL or a future source value)
                // never enter the typed breakdown — the child tables stay keyed
                // by source strings with a fixed wire shape — but their counts
                // already ride the single-row totals above, so log the skip
                // instead of dropping silently.
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
            var statusStatement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "SELECT status, documents FROM index_aggregate_by_extract_status;", -1, &statusStatement, nil) == SQLITE_OK else {
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
            // Page-counter probes ride fail-closed zeros: a throwing PRAGMA
            // must not fail a warm poll that already holds a valid aggregate
            // row. File sizes then fall back to the filesystem probe while the
            // reclaimable-bytes leg reports zero instead of a 500.
            let pageCount = (try? scalarInt(handle: handle, sql: "PRAGMA page_count;")) ?? 0
            let pageSize = (try? scalarInt(handle: handle, sql: "PRAGMA page_size;")) ?? 0
            let freelistCount = (try? scalarInt(handle: handle, sql: "PRAGMA freelist_count;")) ?? 0
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

        /// Computes every status aggregate in one pass over a single open handle.
        ///
        /// Opens once, then runs the document COUNT, the MAX watermark, one
        /// grouped chunk/text query owned by `sourceAggregates(handle:)`, one
        /// vector query owned by `vectorCountAndBytes(handle:)`, one scoped
        /// `dbstat` walk owned by `dbstatGroupedPageBytes(handle:probe:)`,
        /// each GROUP BY, and each PRAGMA exactly once. Both public
        /// projections read from the returned snapshot with no second pass,
        /// so one status poll never fans out into duplicate COUNTs or double
        /// `dbstat` walks. Chunk and text totals sum the raw grouped mapping
        /// plus the orphan bucket from that same grouped pass: the chunk/text
        /// query keeps chunks whose parent document row is missing (legacy
        /// file, pragma-off write, manual SQL) on a NULL-source row instead
        /// of dropping them through an inner join, and rows under unknown or
        /// empty source strings stay in the raw totals, so snapshot totals
        /// stay exact while the per-source breakdown attributes only joined
        /// rows for known sources.
        /// - Parameters:
        ///   - dbPath: SQLite file path. `~` is expanded.
        ///   - dbstatProbe: Per-object page-byte reader, or nil for the live table.
        /// - Returns: The shared aggregate snapshot.
        private static func computeStatusSnapshot(dbPath: String, dbstatProbe: DocIndexDbstatProbe?) throws -> DocIndexStatusSnapshot {
            let expanded = (dbPath as NSString).expandingTildeInPath
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            let documents = try scalarInt(handle: handle, sql: "SELECT COUNT(*) FROM indexed_documents;")
            let indexAsOf = try scalarMaxIndexedAt(handle: handle)
            let sourceResult = try sourceAggregates(handle: handle)
            let bySource = sourceResult.bySource
            // Totals sum the raw grouped mapping plus the orphan bucket from
            // the same grouped pass so no full-table COUNT or SUM scans the
            // chunks table a second time yet chunks with unknown sources or
            // without a parent row still count toward the snapshot.
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
            let grouped = try? dbstatGroupedPageBytes(handle: handle, probe: dbstatProbe)
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
        ///
        /// The watermark is the newest `indexed_at` in the store, so recall
        /// and status surfaces report the last write rather than the read
        /// time; an empty or missing store reports the epoch. On-disk sizes
        /// ride the shared `resolvedDbFileBytes` helper (filesystem size with
        /// a page-counter fallback) so stats and the breakdown agree, while
        /// text/vector report logical content bytes (`SUM(LENGTH(chunk_text))`
        /// and `SUM(LENGTH(embedding))`) and only the FTS leg rides the grouped
        /// `dbstat` query for on-disk page bytes. `dbstat` availability gates
        /// whether the split is reported at all. A SQLite build without `dbstat`
        /// still reports file sizes with a null breakdown instead of failing.
        static func stats(dbPath: String) throws -> IndexStats {
            try stats(dbPath: dbPath, dbstatProbe: dbstatProbeOverride)
        }

        /// Aggregates current index statistics with an injectable size probe.
        ///
        /// Mirrors ``stats(dbPath:)`` while letting tests simulate a SQLite
        /// build without the `dbstat` virtual table by passing a probe that
        /// returns nil. A nil probe result still reports file sizes with a
        /// null breakdown instead of failing. Opening creates an empty store
        /// when absent so a fresh path reports zero counts with true file
        /// sizes instead of missing-file zeros. Projects from the shared
        /// snapshot with no second aggregate pass.
        /// - Parameters:
        ///   - dbPath: SQLite file path. `~` is expanded.
        ///   - dbstatProbe: Per-object page-byte reader, or nil for the live table.
        /// - Returns: An index statistics snapshot with true on-disk sizes.
        static func stats(dbPath: String, dbstatProbe: DocIndexDbstatProbe?) throws -> IndexStats {
            try computeStatusSnapshot(dbPath: dbPath, dbstatProbe: dbstatProbe).makeStats()
        }

        /// Reads fast index counts without measuring content bytes.
        ///
        /// Owned by `SQLiteDocIndexStore`: opens once and runs only count
        /// aggregates plus the watermark, so a genuinely absent aggregate row
        /// still reports true document, chunk, vector, per-source, and
        /// extraction counts fail-closed with pending-zero slow legs well
        /// under the dashboard budget. Per-source byte totals stay zero to
        /// signal pending slow storage rather than an estimate; text, vector,
        /// and full-text legs stay nil, free and content bytes stay zero, and
        /// file sizes ride `onDiskBytes` so the probe reports what the
        /// filesystem holds. The actor fast path no longer uses this when a
        /// persisted row exists — it projects frozen true sizes via the
        /// shared snapshot instead — so this stays only the fail-closed
        /// pending-zero shape for a genuinely absent row. Never touches the
        /// aggregate-pass counter, never touches `dbstat`, and never measures
        /// `LENGTH`, so slow-pass proofs observe exactly one pass per cold
        /// storage poll and zero for fast polls. An empty store reports the
        /// epoch watermark.
        /// - Parameter dbPath: SQLite file path. `~` is expanded.
        /// - Returns: An index statistics snapshot with true counts, true file sizes, and pending slow size fields.
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
        ///
        /// File sizes ride the shared `resolvedDbFileBytes` helper (filesystem
        /// size with a page-counter fallback) so the breakdown matches what
        /// callers observe with file attributes and agrees with stats;
        /// logical bytes aggregate the content tables via `IndexContentBytes`.
        /// A missing database reports zeros so status probes stay honest
        /// without failing. The grouped `dbstat` lookup degrades to zero when
        /// the virtual table is unavailable rather than failing the probe.
        static func storageBreakdown(dbPath: String) throws -> IndexStorageBreakdown {
            try storageBreakdown(dbPath: dbPath, dbstatProbe: dbstatProbeOverride)
        }

        /// Reads the on-disk and logical size breakdown with an injectable size probe.
        ///
        /// Mirrors ``storageBreakdown(dbPath:)`` while letting tests simulate
        /// a SQLite build without the `dbstat` virtual table by passing a
        /// probe that returns nil. A nil probe result degrades the full-text
        /// leg to zero instead of failing the probe. Opening creates an empty
        /// store when absent so a fresh path reports true file sizes instead
        /// of missing-file zeros. Projects from the shared snapshot with no
        /// second aggregate pass.
        /// - Parameters:
        ///   - dbPath: SQLite file path. `~` is expanded.
        ///   - dbstatProbe: Per-object page-byte reader, or nil for the live table.
        /// - Returns: The storage breakdown.
        static func storageBreakdown(dbPath: String, dbstatProbe: DocIndexDbstatProbe?) throws -> IndexStorageBreakdown {
            try computeStatusSnapshot(dbPath: dbPath, dbstatProbe: dbstatProbe).makeBreakdown()
        }

        /// Reads per-object page bytes via one grouped `dbstat` query.
        ///
        /// Groups `SUM(pgsize)` by object name so the caller attributes file
        /// pages to content and search structures without one query per table.
        /// An injected test probe overrides the live table; a nil probe result
        /// or a failed prepare reports unavailability instead of an empty map.
        private static func dbstatGroupedPageBytes(handle: OpaquePointer?) throws -> [String: Int64] {
            try dbstatGroupedPageBytes(handle: handle, probe: dbstatProbeOverride)
        }

        /// Reads per-object page bytes via one grouped `dbstat` query with an injectable probe.
        ///
        /// Owns the scoped `dbstat` pass: an injected probe keeps its exact
        /// current behavior (a nil mapping reports unavailability while a
        /// mapping returns as-is), and a nil probe scopes the live table to
        /// the chunk full-text objects through a `sqlite_schema` name filter
        /// so content pages never enter the split. The `ftsPageBytes(from:)`
        /// prefix filter stays on top as defense-in-depth. A nil probe result
        /// or a failed prepare reports unavailability instead of an empty map.
        /// - Parameters:
        ///   - handle: Open database handle.
        ///   - probe: Per-object page-byte reader, or nil for the live table.
        /// - Returns: Mapping from object name to page bytes.
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
        ///
        /// Adds every object whose name carries the chunk FTS prefix so the
        /// contentless shadow tables (`_data`, `_idx`, and siblings) count
        /// alongside the virtual table instead of reporting only the empty
        /// outer name.
        private static func ftsPageBytes(from grouped: [String: Int64]) -> Int64 {
            var total: Int64 = 0
            for (name, bytes) in grouped where name.hasPrefix("indexed_chunks_fts") {
                total += max(bytes, 0)
            }
            return max(total, 0)
        }

        /// Runs `VACUUM` and reports the reclaimed bytes.
        ///
        /// Totals cover the main file plus the write-ahead log so a
        /// checkpointed WAL cannot hide space. A missing database is created
        /// as an empty store first so the probe reports true file sizes
        /// instead of missing-file zeros. `VACUUM` runs outside any
        /// transaction on its own handle which is closed before the
        /// after-measurement so the rewritten size is visible.
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

        /// Reads one file's size, reporting zero when absent or unreadable.
        ///
        /// Keeps the breakdown and reclaim probes honest without throwing: a
        /// transiently missing WAL reads as zero rather than failing the poll.
        private static func onDiskBytes(at path: String) -> Int64 {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attributes[.size] as? NSNumber
            else {
                return 0
            }
            return max(size.int64Value, 0)
        }

        /// Resolves the on-disk database size shared by stats and the breakdown.
        ///
        /// Prefers the filesystem size so the figure matches what callers
        /// observe with file attributes; falls back to page counters when the
        /// file probe reads zero. Single-sourced so both aggregates report the
        /// same `dbFileBytes` instead of each deriving it differently.
        /// - Parameters:
        ///   - pageCount: `PRAGMA page_count` value.
        ///   - pageSizeBytes: `PRAGMA page_size` value in bytes.
        ///   - expandedPath: Expanded database file path.
        /// - Returns: On-disk file size in bytes.
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

        /// Aggregates per-source document, chunk, and byte counts plus snapshot totals.
        ///
        /// Owns the single grouped chunk/text pass: one three-column
        /// source/count/bytes query returns both per-source chunk counts and
        /// text byte sums in a single prepare/step/finalize walk, so the
        /// chunks table is scanned once instead of once per column family.
        /// Document counts group `indexed_documents` directly with a `?? 0`
        /// fallback for chunk-less documents, so a document without chunks
        /// still contributes its document row with zero chunks and bytes.
        /// Only sources holding at least one document are returned, in
        /// canonical `IndexSource` order. The chunk/text query runs
        /// `FROM indexed_chunks LEFT JOIN indexed_documents`, which preserves
        /// orphan chunks whose parent document row is missing on a NULL-source
        /// row; snapshot totals sum the raw grouped mapping plus that orphan
        /// row so unknown or empty source strings stay exact while the
        /// per-source breakdown attributes only known sources.
        /// - Parameter handle: Open database handle.
        /// - Returns: Per-source aggregates in canonical order with exact chunk and byte totals.
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

        /// Reads the single grouped chunk/text pass into per-source counts and byte sums plus orphan totals.
        ///
        /// Mirrors the `groupedValues` prepare/step/finalize shape but reads
        /// both value columns from each row in one walk, so the three-column
        /// source/count/bytes query executes exactly once. Rows without a
        /// source key carry orphan chunks whose parent document row is
        /// missing; they fold into the orphan totals rather than a per-source
        /// bucket, so snapshot totals stay exact while the breakdown keeps
        /// only joined sources.
        /// - Parameters:
        ///   - handle: Open database handle.
        ///   - sql: Three-column grouped chunk/text query.
        /// - Returns: Mapping from source name to chunk count and text bytes with orphan chunk and byte totals.
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

        /// Reads the vector chunk count and embedding byte total in one pass.
        ///
        /// Owns the single vector aggregate: one two-column COUNT/SUM query
        /// returns both values from its single result row, so the chunks
        /// table is scanned once instead of once per aggregate. The
        /// `COALESCE` keeps an empty index on the single `(0, 0)` row, so
        /// callers never treat absence as failure.
        /// - Parameter handle: Open database handle.
        /// - Returns: Vector chunk count paired with logical embedding bytes.
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
        ///
        /// A missing file drops its stale ensure-gate entry so the next open
        /// re-runs DDL instead of reusing the fast path on an empty schema.
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

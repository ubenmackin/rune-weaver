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

        /// Computes every status aggregate in one pass over a single open handle.
        ///
        /// Opens once, then runs each COUNT, the MAX watermark, each GROUP BY,
        /// both `SUM(LENGTH)` queries, one grouped `dbstat` walk, and each
        /// PRAGMA exactly once. Both public projections read from the returned
        /// snapshot with no second pass, so one status poll never fans out into
        /// duplicate COUNTs or double `dbstat` walks.
        /// - Parameters:
        ///   - dbPath: SQLite file path. `~` is expanded.
        ///   - dbstatProbe: Per-object page-byte reader, or nil for the live table.
        /// - Returns: The shared aggregate snapshot.
        private static func computeStatusSnapshot(dbPath: String, dbstatProbe: DocIndexDbstatProbe?) throws -> DocIndexStatusSnapshot {
            let expanded = (dbPath as NSString).expandingTildeInPath
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            let documents = try scalarInt(handle: handle, sql: "SELECT COUNT(*) FROM indexed_documents;")
            let chunks = try scalarInt(handle: handle, sql: "SELECT COUNT(*) FROM indexed_chunks;")
            let vectorChunks = try scalarInt(
                handle: handle,
                sql: "SELECT COUNT(*) FROM indexed_chunks WHERE is_vector = 1;"
            )
            let textLogical = try scalarInt64(
                handle: handle,
                sql: "SELECT COALESCE(SUM(LENGTH(CAST(chunk_text AS BLOB))), 0) FROM indexed_chunks;"
            )
            let indexAsOf = try scalarMaxIndexedAt(handle: handle)
            let bySource = try sourceAggregates(handle: handle)
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
            let vectorLogical = try scalarInt64(
                handle: handle,
                sql: "SELECT COALESCE(SUM(LENGTH(embedding)), 0) FROM indexed_chunks WHERE is_vector = 1;"
            )
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
                vectorChunks: vectorChunks,
                textBytes: textLogical,
                vectorBytes: vectorLogical,
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
        /// Groups `SUM(pgsize)` by object name so the caller attributes file
        /// pages to content and search structures without one query per table.
        /// A nil probe result or a failed prepare reports unavailability
        /// instead of an empty map.
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
            guard sqlite3_prepare_v2(handle, "SELECT name, SUM(pgsize) FROM dbstat GROUP BY name;", -1, &statement, nil) == SQLITE_OK else {
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

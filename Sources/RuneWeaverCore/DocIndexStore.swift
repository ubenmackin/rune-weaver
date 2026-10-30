// Rune Weaver Core — SQLite-backed local document index for keyword and vector search.

import Foundation
import os

#if canImport(SQLite3)
    import SQLite3
#endif

/// Actor-isolated SQLite store for the local document index.
public actor DocIndexStore {
    /// Filesystem path of the sidecar SQLite database.
    public let dbPath: String
    /// Default SQLite path for the index database, aliasing the canonical
    /// index default so configuration and the store never diverge.
    public static var defaultDBPath: String {
        IndexConfig.defaultDBPath
    }

    /// Maximum results returned when vector scans are bounded by a temporal window.
    public static let maxVectorWindowResults = 10000

    /// How long a status snapshot stays reusable before the next poll re-reads the persisted row.
    public static let statsCacheTTLSeconds: TimeInterval = 60

    /// Canonical calendars sidecar path, mirroring the Tools indexer default.
    public static let defaultCalendarsStatePath = "~/.runeweaver/index/calendars-state.json"
    /// Canonical reminders sidecar path, mirroring the Tools indexer default.
    public static let defaultRemindersStatePath = "~/.runeweaver/index/reminders-state.json"

    /// Cached aggregate snapshot plus when it was taken, in clock time.
    private var cachedStatus: (snapshot: DocIndexStatusSnapshot, at: Date)?

    /// Write generation guarding the status cache against stale resurrection.
    private var statusGeneration: UInt64 = 0

    /// Tracks whether the persisted aggregate tables lag behind content writes.
    private var aggregatesDirty = false

    /// Wall-clock seam for the status cache, injectable so expiry is deterministic under test.
    private let clock: @Sendable () -> Date

    /// Creates a store over a sidecar database. dbPath: SQLite file path.
    public init(dbPath: String = DocIndexStore.defaultDBPath, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.dbPath = dbPath
        self.clock = clock
    }

    /// Returns the cached status snapshot when it is still fresh, recomputing once otherwise.
    /// Aggregate passes run on the interactive lane so status polls never queue behind
    /// utility-throttled indexing work.
    private func cachedStatusSnapshot() async throws -> DocIndexStatusSnapshot {
        if let cached = cachedStatus, clock().timeIntervalSince(cached.at) < Self.statsCacheTTLSeconds {
            return cached.snapshot
        }
        let dbPath = self.dbPath
        let generationBefore = statusGeneration
        let snapshot = try await SQLiteSerialIO.run(lane: .interactive) {
            try DocIndexStoreIO.statusSnapshot(dbPath: dbPath)
        }
        // A concurrent write invalidated while suspended, so this snapshot may predate it.
        if generationBefore != statusGeneration {
            let now = clock()
            if let refilled = cachedStatus, now.timeIntervalSince(refilled.at) < Self.statsCacheTTLSeconds {
                return refilled.snapshot
            }
            let retryGenerationBefore = statusGeneration
            let retrySnapshot = try await SQLiteSerialIO.run(lane: .interactive) {
                try DocIndexStoreIO.statusSnapshot(dbPath: dbPath)
            }
            // Stay bounded: even when another write landed during the retry,
            // return what was just computed instead of recursing, so one poll
            // performs at most two aggregate passes.
            let retryNow = clock()
            if let refilled = cachedStatus, retryNow.timeIntervalSince(refilled.at) < Self.statsCacheTTLSeconds {
                return refilled.snapshot
            }
            if retryGenerationBefore != statusGeneration {
                return retrySnapshot
            }
            cachedStatus = (retrySnapshot, retryNow)
            return retrySnapshot
        }
        // A concurrent caller may have filled the cache while suspended, so prefer that fresh fill
        // over overwriting with a duplicate pass.
        let now = clock()
        if let refilled = cachedStatus, now.timeIntervalSince(refilled.at) < Self.statsCacheTTLSeconds {
            return refilled.snapshot
        }
        cachedStatus = (snapshot, now)
        return snapshot
    }

    /// Clears the status cache and advances the write generation, then awaits vector
    /// invalidation so the next search reloads fresh vectors instead of racing a Task.
    func invalidateStatusCache() async {
        cachedStatus = nil
        statusGeneration &+= 1
        aggregatesDirty = true
        await AcceleratedVectorIndex.shared.invalidate()
    }

    // Sidecar reset helpers live in `DocIndexStoreReset` so this file stays
    // within the file-length and type-body budgets with no behavior change.

    /// Reads the persisted aggregate snapshot without running any content scan. Runs on the
    /// interactive lane so warm polls never queue behind indexing work.
    private func readPersistedSnapshot() async throws -> DocIndexStatusSnapshot? {
        let dbPath = self.dbPath
        return try await SQLiteSerialIO.run(lane: .interactive) {
            try DocIndexStoreIO.readAggregateSnapshot(dbPath: dbPath)
        }
    }

    /// Inserts or updates a document, skipping the write when the content hash is unchanged and the
    /// prior extraction did not fail.
    /// - Parameter document: Document to persist.
    @discardableResult
    public func upsertDocument(_ document: IndexedDocument) async throws -> IndexedDocument {
        let dbPath = self.dbPath
        let result = try await SQLiteSerialIO.run(lane: .indexing) {
            try DocIndexStoreIO.upsertDocument(document, dbPath: dbPath)
        }
        await invalidateStatusCache()
        return result
    }

    /// Replaces all chunks for a document. documentID: Document owning the chunks.
    @discardableResult
    public func upsertChunks(documentID: UUID, chunks: [IndexedChunk]) async throws -> Int {
        let dbPath = self.dbPath
        let result = try await SQLiteSerialIO.run(lane: .indexing) {
            try DocIndexStoreIO.upsertChunks(documentID: documentID, chunks: chunks, dbPath: dbPath)
        }
        await invalidateStatusCache()
        return result
    }

    /// Commits one document with its chunks and run stamp in a single transaction.
    @discardableResult
    public func upsertDocumentWithChunks(
        document: IndexedDocument,
        chunks: [IndexedChunk],
        runID: String
    ) async throws -> IndexedDocument {
        let dbPath = self.dbPath
        let result = try await SQLiteSerialIO.run(lane: .indexing) {
            try DocIndexStoreIO.upsertDocumentWithChunks(document: document, chunks: chunks, runID: runID, dbPath: dbPath)
        }
        await invalidateStatusCache()
        return result
    }

    /// Deletes a document and its chunks. Missing rows are a no-op.
    /// - Parameter id: Document identifier.
    /// - Returns: True when a document row was removed.
    public func deleteDocument(id: UUID) async throws -> Bool {
        let dbPath = self.dbPath
        let result = try await SQLiteSerialIO.run(lane: .indexing) {
            try DocIndexStoreIO.deleteDocument(id: id, dbPath: dbPath)
        }
        await invalidateStatusCache()
        return result
    }

    /// Looks up a document by its source-scoped identifier. source: Origin corpus.
    public func document(source: IndexSource, externalID: String) async throws -> IndexedDocument? {
        let dbPath = self.dbPath
        return try await SQLiteSerialIO.run(lane: .indexing) {
            try DocIndexStoreIO.document(source: source, externalID: externalID, dbPath: dbPath)
        }
    }

    /// Looks up multiple documents by their identifiers.
    /// - Parameter ids: Document identifiers to resolve.
    /// - Returns: Map from document ID to stored document.
    public func documents(ids: Set<UUID>) async throws -> [UUID: IndexedDocument] {
        guard !ids.isEmpty else { return [:] }
        let dbPath = self.dbPath
        return try await SQLiteSerialIO.run(lane: .indexing) {
            try DocIndexStoreIO.documents(ids: ids, dbPath: dbPath)
        }
    }

    /// Reports whether a source must be re-extracted. True when the document is unknown, its
    /// content hash changed, or a prior extraction failed; false when the stored body is current.
    public func needsReindex(source: IndexSource, externalID: String, contentHash: String) async throws -> Bool {
        let dbPath = self.dbPath
        return try await SQLiteSerialIO.run(lane: .indexing) {
            try DocIndexStoreIO.needsReindex(
                source: source,
                externalID: externalID,
                contentHash: contentHash,
                dbPath: dbPath
            )
        }
    }

    /// Reads the stored size, modification time, and extraction outcome.
    public func storedFingerprint(source: IndexSource, externalID: String) async throws -> DocStoredFingerprint? {
        let dbPath = self.dbPath
        return try await SQLiteSerialIO.run(lane: .indexing) {
            try DocIndexStoreIO.storedFingerprint(source: source, externalID: externalID, dbPath: dbPath)
        }
    }

    /// Stamps one document as seen by the current run. Missing rows are a no-op so stamping a
    /// brand-new path before its first upsert stays safe.
    public func markSeen(source: IndexSource, externalID: String, runID: String) async throws {
        let dbPath = self.dbPath
        try await SQLiteSerialIO.run(lane: .indexing) {
            try DocIndexStoreIO.markSeen(source: source, externalID: externalID, runID: runID, dbPath: dbPath)
        }
    }

    /// Serves a frozen aggregate projection from the persisted single row, repairing only when
    /// absent.
    private func persistedSnapshotOrRefresh<T>(make: (DocIndexStatusSnapshot) -> T) async throws -> T {
        if let cached = cachedStatus, clock().timeIntervalSince(cached.at) < Self.statsCacheTTLSeconds {
            return make(cached.snapshot)
        }
        let generationBefore = statusGeneration
        if let stored = try await readPersistedSnapshot() {
            if generationBefore != statusGeneration {
                let now = clock()
                if let refilled = cachedStatus, now.timeIntervalSince(refilled.at) < Self.statsCacheTTLSeconds {
                    return make(refilled.snapshot)
                }
            }
            let now = clock()
            if let refilled = cachedStatus, now.timeIntervalSince(refilled.at) < Self.statsCacheTTLSeconds {
                return make(refilled.snapshot)
            }
            cachedStatus = (stored, now)
            return make(stored)
        }
        return try await make(refreshAggregates())
    }

    /// Refreshes the persisted aggregates, keeping the prior row on failure. Internal so the
    /// reset extension in its own file can persist route-driven clears with no run-end refresh.
    func refreshAggregatesIgnoringFailure() async {
        do {
            _ = try await refreshAggregates()
        } catch {
            RuneWeaverLog.stores.debug("DocIndexStore: refreshAggregates inline refresh ignored failure: \(error.localizedDescription)")
        }
    }

    /// Current document, chunk, vector, and byte counts.
    public func stats() async throws -> IndexStats {
        try await persistedSnapshotOrRefresh { $0.makeStats() }
    }

    /// Reads fast index counts with true sizes from the persisted single row.
    public func fastStats() async throws -> IndexStats {
        if let stored = try await readPersistedSnapshot() {
            // Freeze-then-jump: serve the persisted row frozen even when dirty
            // mid-run, projecting true sizes via the shared snapshot so one
            // row carries every leg and no second storage fetch is needed.
            return stored.makeStats()
        }
        let snapshot = try await refreshAggregates()
        return snapshot.makeStats()
    }

    /// Returns the persisted storage breakdown, serving single-row reads forever.
    public func cachedStorageIfFresh() async -> IndexStorageBreakdown? {
        if let cached = cachedStatus, clock().timeIntervalSince(cached.at) < Self.statsCacheTTLSeconds {
            return cached.snapshot.makeBreakdown()
        }
        do {
            if let stored = try await readPersistedSnapshot() {
                return stored.makeBreakdown()
            }
        } catch is CancellationError {
            return nil
        } catch {
            RuneWeaverLog.stores.debug("DocIndexStore: failed to read persisted snapshot for storage breakdown: \(error.localizedDescription)")
        }
        return nil
    }

    /// Deletes documents indexed before a cutoff, then reclaims file space.
    /// - Parameter cutoff: Documents with an earlier `indexedAt` are removed.
    /// - Returns: Number of documents removed.
    @discardableResult
    public func prune(before cutoff: Date) async throws -> Int {
        let dbPath = self.dbPath
        let result = try await SQLiteSerialIO.run(lane: .indexing) {
            try DocIndexStoreIO.prune(before: cutoff, dbPath: dbPath)
        }
        await invalidateStatusCache()
        // Route-driven deletes leave no run to refresh the persisted rows, so
        // refresh here to keep dashboard reads fresh without waiting for the
        // next indexing pass. A failed refresh keeps the previous row.
        await refreshAggregatesIgnoringFailure()
        return result
    }

    /// Deletes `files` documents not seen by the given run.
    @discardableResult
    public func retireUnseenFiles(runID: String) async throws -> Int {
        let dbPath = self.dbPath
        let result = try await SQLiteSerialIO.run(lane: .indexing) {
            try DocIndexStoreIO.retireUnseenFiles(runID: runID, dbPath: dbPath)
        }
        await invalidateStatusCache()
        // Retired files change the persisted counts with no run-end refresh to
        // follow, so persist fresh aggregates now. A failure keeps prior rows.
        await refreshAggregatesIgnoringFailure()
        return result
    }

    /// Deletes `mail` documents whose mailbox sits in the denied set.
    @discardableResult
    public func retireMailboxes(_ mailboxes: Set<String>) async throws -> Int {
        guard !mailboxes.isEmpty else { return 0 }
        let dbPath = self.dbPath
        let result = try await SQLiteSerialIO.run(lane: .indexing) {
            try DocIndexStoreIO.retireMailboxes(mailboxes: mailboxes, dbPath: dbPath)
        }
        await invalidateStatusCache()
        // Retired mailboxes change the persisted counts with no run-end refresh
        // to follow, so persist fresh aggregates now. A failure keeps prior rows.
        await refreshAggregatesIgnoringFailure()
        return result
    }

    /// Reads distinct content hashes for `mail` documents in the given mailboxes.
    public func mailContentHashes(mailboxes: Set<String>) async throws -> Set<String> {
        guard !mailboxes.isEmpty else { return [] }
        let dbPath = self.dbPath
        return try await SQLiteSerialIO.run(lane: .indexing) {
            try DocIndexStoreIO.mailContentHashes(mailboxes: mailboxes, dbPath: dbPath)
        }
    }

    /// Current on-disk and logical size breakdown.
    public func storageBreakdown() async throws -> IndexStorageBreakdown {
        try await persistedSnapshotOrRefresh { $0.makeBreakdown() }
    }

    /// Recomputes the persisted aggregate tables from a fresh snapshot. A failure logs and
    /// preserves both the previous database row (via transaction rollback) and the previous cached
    /// snapshot.
    func refreshAggregates(producingRunID: String? = nil) async throws -> DocIndexStatusSnapshot {
        let dbPath = self.dbPath
        let updatedAt = clock()
        let snapshot: DocIndexStatusSnapshot
        do {
            snapshot = try await SQLiteSerialIO.runIgnoringCancellation(lane: .indexing) {
                try DocIndexStoreIO.refreshAggregates(dbPath: dbPath, producingRunID: producingRunID, updatedAt: updatedAt)
            }
        } catch {
            RuneWeaverLog.stores.error("DocIndexStore: failed to refresh aggregates: \(error.localizedDescription)")
            throw error
        }
        // Warm the cache from the persisted value rather than invalidating: the snapshot is already
        // post-write, so the next poll must not pay for another aggregate pass.
        cachedStatus = (snapshot, clock())
        statusGeneration &+= 1
        aggregatesDirty = false
        return snapshot
    }

    /// Reclaims index file space with `VACUUM`. A missing database is a zeroed no-op rather than a
    /// failure.
    public func reclaim() async throws -> IndexReclaimResult {
        let dbPath = self.dbPath
        let result = try await SQLiteSerialIO.run(lane: .indexing) {
            try DocIndexStoreIO.reclaim(dbPath: dbPath)
        }
        await invalidateStatusCache()
        // VACUUM rewrites page layout so the persisted full-text size shifts
        // even when document counts do not; persist fresh aggregates now.
        // A failure keeps the previous row.
        await refreshAggregatesIgnoringFailure()
        return result
    }
}

// MARK: - Search & Vector Retrieval

extension DocIndexStore {
    /// Full-text search over chunk text, optionally restricted to a dated window on the parent
    /// document event time. query: Raw search text.
    public func searchKeyword(query: String, limit: Int = 10, since: Date? = nil, until: Date? = nil) async throws -> [IndexedChunk] {
        let dbPath = self.dbPath
        // Canonicalize the dated window through the shared temporal type so
        // since stays inclusive and until stays exclusive by construction.
        let range = TemporalRange(since: since, until: until)
        return try await SQLiteSerialIO.run(lane: .indexing) {
            try DocIndexStoreIO.searchKeyword(query: query, limit: limit, dbPath: dbPath, since: range.since, until: range.until)
        }
    }

    /// Reads chunks that carry an embedding for the semantic path, optionally restricted to a dated
    /// window.
    public func chunkVectors(limit: Int = 100, since: Date? = nil, until: Date? = nil) async throws -> [IndexedChunk] {
        let dbPath = self.dbPath
        // Canonicalize the dated window through the shared temporal type so
        // since stays inclusive and until stays exclusive by construction.
        let range = TemporalRange(since: since, until: until)
        return try await SQLiteSerialIO.run(lane: .indexing) {
            try DocIndexStoreIO.chunkVectors(limit: limit, dbPath: dbPath, since: range.since, until: range.until)
        }
    }

    /// Reads chunks by their unique identifiers.
    public func chunks(ids: Set<UUID>) async throws -> [UUID: IndexedChunk] {
        guard !ids.isEmpty else { return [:] }
        let dbPath = self.dbPath
        return try await SQLiteSerialIO.run(lane: .indexing) {
            try DocIndexStoreIO.chunks(ids: ids, dbPath: dbPath)
        }
    }

    /// Evaluates `queryVector` against all loaded vectors using hardware acceleration.
    public func searchAcceleratedVectors(
        queryVector: [Float],
        zGate: Double = AcceleratedVectorMath.defaultZGate,
        limit: Int = AcceleratedVectorIndex.defaultSearchLimit,
        since: Date? = nil,
        until: Date? = nil
    ) async throws -> [AcceleratedVectorIndex.ScoredVectorHit] {
        try await AcceleratedVectorIndex.shared.ensureLoaded(dbPath: dbPath)
        return try await AcceleratedVectorIndex.shared.search(
            queryVector: queryVector,
            zGate: zGate,
            limit: limit,
            since: since,
            until: until
        )
    }
}

// MARK: - Embedding Metadata

extension DocIndexStore {
    /// Reads the recorded embedding model and dimension from the store's schema_meta table.
    public func readEmbeddingMeta() async throws -> (modelID: String?, dimension: Int?) {
        let dbPath = self.dbPath
        return try await SQLiteSerialIO.run(lane: .interactive) {
            let handle = try SQLiteDocIndexStore.open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            return try SQLiteDocIndexStore.readEmbeddingMeta(handle: handle)
        }
    }

    /// Records the embedding model and dimension into the store's schema_meta table.
    public func writeEmbeddingMeta(modelID: String, dimension: Int) async throws {
        let dbPath = self.dbPath
        try await SQLiteSerialIO.run(lane: .indexing) {
            let handle = try SQLiteDocIndexStore.open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            try SQLiteDocIndexStore.writeEmbeddingMeta(handle: handle, modelID: modelID, dimension: dimension)
        }
    }
}

// MARK: - Store I/O

/// SQLite I/O for the document index, falling back to an unavailable error
/// where the SQLite3 module cannot be imported.
enum DocIndexStoreIO {
    /// Inserts or updates a document, skipping unchanged content.
    static func upsertDocument(_ document: IndexedDocument, dbPath: String) throws -> IndexedDocument {
        #if canImport(SQLite3)
            return try SQLiteDocIndexStore.upsertDocument(document, dbPath: dbPath)
        #else
            throw DocIndexError.storeUnavailable("SQLite3 is unavailable on this platform")
        #endif
    }

    /// Replaces all chunks for a document.
    static func upsertChunks(documentID: UUID, chunks: [IndexedChunk], dbPath: String) throws -> Int {
        #if canImport(SQLite3)
            return try SQLiteDocIndexStore.upsertChunks(documentID: documentID, chunks: chunks, dbPath: dbPath)
        #else
            throw DocIndexError.storeUnavailable("SQLite3 is unavailable on this platform")
        #endif
    }

    /// Commits one document with its chunks and run stamp atomically.
    static func upsertDocumentWithChunks(
        document: IndexedDocument,
        chunks: [IndexedChunk],
        runID: String,
        dbPath: String
    ) throws -> IndexedDocument {
        #if canImport(SQLite3)
            return try SQLiteDocIndexStore.upsertDocumentWithChunks(
                document: document,
                chunks: chunks,
                runID: runID,
                dbPath: dbPath
            )
        #else
            throw DocIndexError.storeUnavailable("SQLite3 is unavailable on this platform")
        #endif
    }

    /// Deletes a document and its chunks.
    static func deleteDocument(id: UUID, dbPath: String) throws -> Bool {
        #if canImport(SQLite3)
            return try SQLiteDocIndexStore.deleteDocument(id: id, dbPath: dbPath)
        #else
            throw DocIndexError.storeUnavailable("SQLite3 is unavailable on this platform")
        #endif
    }

    /// Reads a document by source-scoped identifier.
    static func document(source: IndexSource, externalID: String, dbPath: String) throws -> IndexedDocument? {
        #if canImport(SQLite3)
            return try SQLiteDocIndexStore.document(source: source, externalID: externalID, dbPath: dbPath)
        #else
            throw DocIndexError.storeUnavailable("SQLite3 is unavailable on this platform")
        #endif
    }

    /// Reads multiple documents by their identifiers.
    static func documents(ids: Set<UUID>, dbPath: String) throws -> [UUID: IndexedDocument] {
        #if canImport(SQLite3)
            return try SQLiteDocIndexStore.documents(ids: ids, dbPath: dbPath)
        #else
            throw DocIndexError.storeUnavailable("SQLite3 is unavailable on this platform")
        #endif
    }

    /// Reports whether a source must be re-extracted.
    static func needsReindex(source: IndexSource, externalID: String, contentHash: String, dbPath: String) throws -> Bool {
        #if canImport(SQLite3)
            return try SQLiteDocIndexStore.needsReindex(
                source: source,
                externalID: externalID,
                contentHash: contentHash,
                dbPath: dbPath
            )
        #else
            throw DocIndexError.storeUnavailable("SQLite3 is unavailable on this platform")
        #endif
    }

    /// Reads the stored fingerprint for a source-scoped identifier.
    static func storedFingerprint(source: IndexSource, externalID: String, dbPath: String) throws -> DocStoredFingerprint? {
        #if canImport(SQLite3)
            return try SQLiteDocIndexStore.storedFingerprint(source: source, externalID: externalID, dbPath: dbPath)
        #else
            throw DocIndexError.storeUnavailable("SQLite3 is unavailable on this platform")
        #endif
    }

    /// Stamps one document as seen by the current run.
    static func markSeen(source: IndexSource, externalID: String, runID: String, dbPath: String) throws {
        #if canImport(SQLite3)
            return try SQLiteDocIndexStore.markSeen(source: source, externalID: externalID, runID: runID, dbPath: dbPath)
        #else
            throw DocIndexError.storeUnavailable("SQLite3 is unavailable on this platform")
        #endif
    }

    /// Full-text search over chunk text.
    static func searchKeyword(query: String, limit: Int, dbPath: String, since: Date? = nil, until: Date? = nil) throws -> [IndexedChunk] {
        #if canImport(SQLite3)
            let range = TemporalRange(since: since, until: until)
            return try SQLiteDocIndexStore.searchKeyword(query: query, limit: limit, dbPath: dbPath, since: range.since, until: range.until)
        #else
            throw DocIndexError.storeUnavailable("SQLite3 is unavailable on this platform")
        #endif
    }

    /// Reads the chunks that carry an embedding with the most recent parent event time — `mtime`
    /// descending with NULLs last — bounded by `limit`.
    static func chunkVectors(limit: Int, dbPath: String, since: Date? = nil, until: Date? = nil) throws -> [IndexedChunk] {
        #if canImport(SQLite3)
            let range = TemporalRange(since: since, until: until)
            return try SQLiteDocIndexStore.chunkVectors(limit: limit, dbPath: dbPath, since: range.since, until: range.until)
        #else
            throw DocIndexError.storeUnavailable("SQLite3 is unavailable on this platform")
        #endif
    }

    /// Reads chunks by their unique identifiers.
    static func chunks(ids: Set<UUID>, dbPath: String) throws -> [UUID: IndexedChunk] {
        #if canImport(SQLite3)
            return try SQLiteDocIndexStore.chunks(ids: ids, dbPath: dbPath)
        #else
            throw DocIndexError.storeUnavailable("SQLite3 is unavailable on this platform")
        #endif
    }

    /// Aggregates current index statistics.
    static func stats(dbPath: String) throws -> IndexStats {
        #if canImport(SQLite3)
            return try SQLiteDocIndexStore.stats(dbPath: dbPath)
        #else
            throw DocIndexError.storeUnavailable("SQLite3 is unavailable on this platform")
        #endif
    }

    /// Reads fast index counts without measuring content bytes. Never touches the slow snapshot
    /// counter.
    static func fastStats(dbPath: String) throws -> IndexStats {
        #if canImport(SQLite3)
            return try SQLiteDocIndexStore.fastStats(dbPath: dbPath)
        #else
            throw DocIndexError.storeUnavailable("SQLite3 is unavailable on this platform")
        #endif
    }

    /// Computes the shared status snapshot backing both aggregate projections.
    static func statusSnapshot(dbPath: String) throws -> DocIndexStatusSnapshot {
        #if canImport(SQLite3)
            return try SQLiteDocIndexStore.statusSnapshot(dbPath: dbPath)
        #else
            throw DocIndexError.storeUnavailable("SQLite3 is unavailable on this platform")
        #endif
    }

    /// Reads the persisted aggregate snapshot without running any content scan. A missing row reads
    /// as nil so the caller can repair once through the single writer; never touches the
    /// aggregate-pass counter.
    static func readAggregateSnapshot(dbPath: String) throws -> DocIndexStatusSnapshot? {
        #if canImport(SQLite3)
            return try SQLiteDocIndexStore.readAggregateSnapshot(dbPath: dbPath)
        #else
            throw DocIndexError.storeUnavailable("SQLite3 is unavailable on this platform")
        #endif
    }

    /// Recomputes the persisted aggregate tables from a fresh snapshot.
    static func refreshAggregates(dbPath: String, producingRunID: String? = nil, updatedAt: Date = Date()) throws -> DocIndexStatusSnapshot {
        #if canImport(SQLite3)
            return try SQLiteDocIndexStore.refreshAggregates(dbPath: dbPath, producingRunID: producingRunID, updatedAt: updatedAt)
        #else
            throw DocIndexError.storeUnavailable("SQLite3 is unavailable on this platform")
        #endif
    }

    /// Deletes documents indexed before a cutoff and vacuums.
    static func prune(before cutoff: Date, dbPath: String) throws -> Int {
        #if canImport(SQLite3)
            return try SQLiteDocIndexStore.prune(before: cutoff, dbPath: dbPath)
        #else
            throw DocIndexError.storeUnavailable("SQLite3 is unavailable on this platform")
        #endif
    }

    /// Deletes `files` documents not seen by the given run.
    static func retireUnseenFiles(runID: String, dbPath: String) throws -> Int {
        #if canImport(SQLite3)
            return try SQLiteDocIndexStore.retireUnseenFiles(runID: runID, dbPath: dbPath)
        #else
            throw DocIndexError.storeUnavailable("SQLite3 is unavailable on this platform")
        #endif
    }

    /// Deletes `mail` documents whose mailbox sits in the denied set.
    static func retireMailboxes(mailboxes: Set<String>, dbPath: String) throws -> Int {
        #if canImport(SQLite3)
            return try SQLiteDocIndexStore.retireMailboxes(mailboxes: mailboxes, dbPath: dbPath)
        #else
            throw DocIndexError.storeUnavailable("SQLite3 is unavailable on this platform")
        #endif
    }

    /// Reads distinct content hashes for `mail` documents in the denied set.
    static func mailContentHashes(mailboxes: Set<String>, dbPath: String) throws -> Set<String> {
        #if canImport(SQLite3)
            return try SQLiteDocIndexStore.mailContentHashes(mailboxes: mailboxes, dbPath: dbPath)
        #else
            throw DocIndexError.storeUnavailable("SQLite3 is unavailable on this platform")
        #endif
    }

    /// Clears every document, chunk, and index entry.
    static func reset(dbPath: String) throws {
        #if canImport(SQLite3)
            try SQLiteDocIndexStore.reset(dbPath: dbPath)
        #else
            throw DocIndexError.storeUnavailable("SQLite3 is unavailable on this platform")
        #endif
    }

    /// Clears documents, chunks, and FTS entries for a single source.
    static func clearSource(source: String, dbPath: String) throws -> Int {
        #if canImport(SQLite3)
            return try SQLiteDocIndexStore.clearSource(source: source, dbPath: dbPath)
        #else
            throw DocIndexError.storeUnavailable("SQLite3 is unavailable on this platform")
        #endif
    }

    /// Reads the on-disk and logical size breakdown.
    static func storageBreakdown(dbPath: String) throws -> IndexStorageBreakdown {
        #if canImport(SQLite3)
            return try SQLiteDocIndexStore.storageBreakdown(dbPath: dbPath)
        #else
            throw DocIndexError.storeUnavailable("SQLite3 is unavailable on this platform")
        #endif
    }

    /// Runs `VACUUM` and reports the reclaimed bytes.
    static func reclaim(dbPath: String) throws -> IndexReclaimResult {
        #if canImport(SQLite3)
            return try SQLiteDocIndexStore.reclaim(dbPath: dbPath)
        #else
            throw DocIndexError.storeUnavailable("SQLite3 is unavailable on this platform")
        #endif
    }
}

#if canImport(SQLite3)
    /// Schema and open path for the document index.
    enum SQLiteDocIndexStore {
        /// Current on-disk schema revision.
        static let schemaVersion = 2

        /// Maximum rows returned per read when a caller passes an oversized limit.
        static let maxResults = 1000

        /// Maximum results returned when vector scans are bounded by a temporal window.
        static let maxVectorWindowResults = DocIndexStore.maxVectorWindowResults

        /// Column projection shared by every document read.
        static let documentColumnList =
            "id, source, external_id, display_name, path, message_id, mailbox, mtime, "
                + "size_bytes, content_hash, mime, extract_status, indexed_at, metadata"

        /// Shared chunk full-text trigger definitions.
        static let ftsTriggersSQL = """
        CREATE TRIGGER IF NOT EXISTS indexed_chunks_ai AFTER INSERT ON indexed_chunks BEGIN
            INSERT INTO indexed_chunks_fts(rowid, chunk_text) VALUES(new.rowid, new.chunk_text);
        END;
        CREATE TRIGGER IF NOT EXISTS indexed_chunks_ad AFTER DELETE ON indexed_chunks BEGIN
            DELETE FROM indexed_chunks_fts WHERE rowid = old.rowid;
        END;
        CREATE TRIGGER IF NOT EXISTS indexed_chunks_au AFTER UPDATE ON indexed_chunks BEGIN
            DELETE FROM indexed_chunks_fts WHERE rowid = old.rowid;
            INSERT INTO indexed_chunks_fts(rowid, chunk_text) VALUES(new.rowid, new.chunk_text);
        END;
        """

        /// Table and trigger schema, applied before additive column probes.
        private static let tablesSQL = """
        CREATE TABLE IF NOT EXISTS schema_meta(
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS indexed_documents(
            id TEXT PRIMARY KEY,
            source TEXT NOT NULL,
            external_id TEXT NOT NULL,
            display_name TEXT NOT NULL,
            path TEXT,
            message_id TEXT,
            mailbox TEXT,
            mtime REAL,
            size_bytes INTEGER,
            content_hash TEXT NOT NULL,
            mime TEXT,
            extract_status TEXT NOT NULL,
            indexed_at REAL NOT NULL,
            metadata TEXT,
            last_seen_run TEXT
        );
        CREATE TABLE IF NOT EXISTS indexed_chunks(
            id TEXT PRIMARY KEY,
            document_id TEXT NOT NULL,
            ordinal INTEGER NOT NULL,
            chunk_text TEXT NOT NULL,
            embedding BLOB,
            is_vector INTEGER NOT NULL DEFAULT 0,
            FOREIGN KEY(document_id) REFERENCES indexed_documents(id) ON DELETE CASCADE
        );
        CREATE VIRTUAL TABLE IF NOT EXISTS indexed_chunks_fts USING fts5(chunk_text, content='', contentless_delete=1, tokenize='porter');
        \(ftsTriggersSQL)
        """

        /// Indexes applied after additive columns exist, so a column introduced
        /// by migration is indexable on the same open.
        private static let indexesSQL = """
        CREATE UNIQUE INDEX IF NOT EXISTS idx_indexed_documents_source_external
            ON indexed_documents(source, external_id);
        CREATE INDEX IF NOT EXISTS idx_indexed_documents_indexed_at ON indexed_documents(indexed_at);
        CREATE INDEX IF NOT EXISTS idx_indexed_documents_mtime ON indexed_documents(mtime);
        CREATE INDEX IF NOT EXISTS idx_indexed_documents_last_seen ON indexed_documents(last_seen_run);
        CREATE INDEX IF NOT EXISTS idx_indexed_chunks_document ON indexed_chunks(document_id);
        CREATE INDEX IF NOT EXISTS idx_indexed_chunks_vector ON indexed_chunks(is_vector);
        """

        /// Precomputed aggregate tables backing the index status cache.
        private static let aggregatesSQL = """
        CREATE TABLE IF NOT EXISTS index_aggregates(
            id INTEGER PRIMARY KEY CHECK (id = 0),
            documents INTEGER NOT NULL,
            chunks INTEGER NOT NULL,
            vector_chunks INTEGER NOT NULL,
            text_bytes INTEGER NOT NULL,
            vector_bytes INTEGER NOT NULL,
            fts_bytes INTEGER,
            index_as_of REAL NOT NULL,
            updated_at REAL NOT NULL,
            producing_run_id TEXT
        );
        CREATE TABLE IF NOT EXISTS index_aggregate_by_source(
            source TEXT PRIMARY KEY,
            documents INTEGER NOT NULL,
            chunks INTEGER NOT NULL,
            bytes INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS index_aggregate_by_extract_status(
            status TEXT PRIMARY KEY,
            documents INTEGER NOT NULL
        );
        """

        /// Additive `indexed_documents` columns introduced after the first schema revision.
        private static let documentAdditions: [(name: String, sql: String)] = [
            ("metadata", "ALTER TABLE indexed_documents ADD COLUMN metadata TEXT;"),
            ("last_seen_run", "ALTER TABLE indexed_documents ADD COLUMN last_seen_run TEXT;")
        ]

        /// Additive `indexed_chunks` columns introduced after the first schema revision.
        private static let chunkAdditions: [(name: String, sql: String)] = [
            ("is_vector", "ALTER TABLE indexed_chunks ADD COLUMN is_vector INTEGER NOT NULL DEFAULT 0;")
        ]

        /// Key/value row identifying an existing document without loading it.
        struct DocumentRowKey {
            /// Stable row identifier whose chunks must survive a rewrite.
            let id: UUID
            /// Stored body hash used for the skip check.
            let contentHash: String
            /// Prior extraction outcome; failures are always retried.
            let extractStatus: ExtractStatus
        }

        /// Process-wide guard for the schema ensure gate owned by `SQLiteDocIndexStore.open`.
        private static let ensuredPathsLock = OSAllocatedUnfairLock(initialState: Set<String>())

        /// Bounds the ensure gate so distinct database paths never grow memory without bound.
        private static let maxEnsuredPaths = 500

        /// Canonical cache key for a database path.
        static func canonicalDBPath(_ dbPath: String) -> String {
            let expanded = (dbPath as NSString).expandingTildeInPath
            let leafResolved = resolveLeafSymlink(expanded)
            return URL(fileURLWithPath: leafResolved).resolvingSymlinksInPath().standardizedFileURL.path
        }

        /// Resolves a leaf symlink chain without requiring the target to exist.
        private static func resolveLeafSymlink(_ path: String) -> String {
            var current = path
            var seen = Set<String>()
            for _ in 0 ..< 32 {
                if !seen.insert(current).inserted {
                    break
                }
                guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: current) else {
                    break
                }
                if (destination as NSString).isAbsolutePath {
                    current = (destination as NSString).standardizingPath
                } else {
                    let parent = (current as NSString).deletingLastPathComponent
                    current = ((parent as NSString).appendingPathComponent(destination) as NSString).standardizingPath
                }
            }
            return current
        }

        /// Records a path as ensured, evicting deterministically at capacity.
        /// - Parameter key: Canonical database path.
        private static func noteEnsured(_ key: String) {
            ensuredPathsLock.withLock { set in
                if set.count >= maxEnsuredPaths, let victim = set.sorted().first {
                    set.remove(victim)
                }
                set.insert(key)
            }
        }

        /// Clears the ensure gate so tests can prove a cold open migrates again.
        static func resetEnsuredPathsForTesting() {
            ensuredPathsLock.withLock { $0.removeAll() }
        }

        /// Drops one path from the ensure gate so the next open re-runs DDL.
        static func removeEnsuredPath(_ dbPath: String) {
            let key = canonicalDBPath(dbPath)
            _ = ensuredPathsLock.withLock { $0.remove(key) }
        }

        /// Reports whether the document table exists on an open handle.
        private static func hasDocumentTable(handle: OpaquePointer?) -> Bool {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                handle,
                "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'indexed_documents';",
                -1,
                &statement,
                nil
            ) == SQLITE_OK else {
                return false
            }
            defer { sqlite3_finalize(statement) }
            return sqlite3_step(statement) == SQLITE_ROW
        }

        /// Opens (creating parent directories) and migrates the database.
        static func open(dbPath: String) throws -> OpaquePointer? {
            let canonical = canonicalDBPath(dbPath)
            let alreadyEnsured = ensuredPathsLock.withLock { $0.contains(canonical) }
            if alreadyEnsured {
                // Fast path: schema is already ensured in this process, so only
                // open plus the per-connection foreign-key pragma plus a
                // read-only table-exists probe; no DDL writes issue here.
                let handle = try SQLiteHelpers.openHandle(dbPath: dbPath, unavailable: DocIndexError.storeUnavailable)
                do {
                    try SQLiteHelpers.exec(
                        handle: handle,
                        sql: "PRAGMA foreign_keys = ON;",
                        failure: DocIndexError.persistenceFailed
                    )
                } catch {
                    sqlite3_close(handle)
                    throw error
                }
                // A deleted or replaced file opens cleanly yet holds no tables;
                // drop the stale gate entry and fall through to the full ensure.
                if hasDocumentTable(handle: handle) {
                    return handle
                }
                sqlite3_close(handle)
                _ = ensuredPathsLock.withLock { $0.remove(canonical) }
            }
            // Shared busy_timeout/WAL policy lives in `SQLiteHelpers.openHandle`.
            let handle = try SQLiteHelpers.openHandle(dbPath: dbPath, unavailable: DocIndexError.storeUnavailable)
            do {
                try exec(handle: handle, sql: tablesSQL)
                try ensureColumns(handle: handle)
                try exec(handle: handle, sql: indexesSQL)
                try exec(handle: handle, sql: aggregatesSQL)
                try migrateFTSTriggers(handle: handle)
                try ensureSchemaVersion(handle: handle)
                try SQLiteHelpers.exec(
                    handle: handle,
                    sql: "PRAGMA foreign_keys = ON;",
                    failure: DocIndexError.persistenceFailed
                )
                noteEnsured(canonical)
                return handle
            } catch {
                sqlite3_close(handle)
                throw error
            }
        }

        /// Executes a multi-statement SQL string.
        static func exec(handle: OpaquePointer?, sql: String) throws {
            try SQLiteHelpers.exec(handle: handle, sql: sql, failure: DocIndexError.persistenceFailed)
        }

        /// Applies additive column migrations, mirroring the session-store pattern.
        private static func ensureColumns(handle: OpaquePointer?) throws {
            try addMissingColumns(
                handle: handle,
                pragma: "PRAGMA table_info(indexed_documents);",
                additions: documentAdditions
            )
            try addMissingColumns(
                handle: handle,
                pragma: "PRAGMA table_info(indexed_chunks);",
                additions: chunkAdditions
            )
        }

        /// Adds columns absent from a table's current declaration.
        private static func addMissingColumns(
            handle: OpaquePointer?,
            pragma: String,
            additions: [(name: String, sql: String)]
        ) throws {
            let existing = columnNames(handle: handle, pragma: pragma)
            for addition in additions where !existing.contains(addition.name) {
                do {
                    try exec(handle: handle, sql: addition.sql)
                } catch {
                    // A duplicate addition from a concurrent open surfaces here;
                    // the probe plus conditional `ALTER` is idempotent, so log
                    // and continue rather than failing the open.
                    let code = sqlite3_errcode(handle)
                    RuneWeaverLog.stores.warning(
                        "DocIndexStore: Migration failed for column '\(addition.name)' (code \(code)): \(error)"
                    )
                }
            }
        }

        /// Lists declared columns for a table, lowercased for case-tolerant probes.
        private static func columnNames(handle: OpaquePointer?, pragma: String) -> Set<String> {
            var names: Set<String> = []
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, pragma, -1, &statement, nil) == SQLITE_OK else {
                return names
            }
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                if let name = SQLiteHelpers.columnText(statement, index: 1) {
                    names.insert(name.lowercased())
                }
            }
            return names
        }

        /// Ensures the chunk full-text triggers exist without touching data.
        private static func migrateFTSTriggers(handle: OpaquePointer?) throws {
            try exec(handle: handle, sql: ftsTriggersSQL)
        }

        /// Records the schema revision, migrating older databases first.
        private static func ensureSchemaVersion(handle: OpaquePointer?) throws {
            let stored = try readSchemaVersion(handle: handle)
            if let stored, stored > schemaVersion {
                RuneWeaverLog.stores.warning(
                    "DocIndexStore: database schema v\(stored) is newer than supported v\(schemaVersion); leaving it unchanged"
                )
                return
            }
            if let stored, stored < schemaVersion {
                try migrate(handle: handle, from: stored)
            }
            try writeSchemaVersion(handle: handle, version: schemaVersion)
        }

        /// Reads the recorded schema revision, or nil for a fresh database.
        private static func readSchemaVersion(handle: OpaquePointer?) throws -> Int? {
            var statement: OpaquePointer?
            let sql = "SELECT value FROM schema_meta WHERE key = 'schema_version';"
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DocIndexError.persistenceFailed("Could not read schema version")
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW, let text = SQLiteHelpers.columnText(statement, index: 0) else {
                return nil
            }
            return Int(text)
        }

        /// Persists the schema revision.
        private static func writeSchemaVersion(handle: OpaquePointer?, version: Int) throws {
            var statement: OpaquePointer?
            let sql = "INSERT INTO schema_meta(key, value) VALUES('schema_version', ?) "
                + "ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DocIndexError.persistenceFailed("Could not prepare schema version write")
            }
            defer { sqlite3_finalize(statement) }
            SQLiteHelpers.bindText(statement, index: 1, value: String(version))
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DocIndexError.persistenceFailed("Could not persist schema version")
            }
        }

        /// Reads recorded embedding model and dimension metadata.
        static func readEmbeddingMeta(handle: OpaquePointer?) throws -> (modelID: String?, dimension: Int?) {
            var modelID: String?
            var dimension: Int?
            var statement: OpaquePointer?
            let sql = "SELECT key, value FROM schema_meta WHERE key IN ('embedding_model_id', 'embedding_dimension');"
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DocIndexError.persistenceFailed("Could not read embedding metadata")
            }
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                if let key = SQLiteHelpers.columnText(statement, index: 0),
                   let val = SQLiteHelpers.columnText(statement, index: 1)
                {
                    if key == "embedding_model_id" {
                        modelID = val
                    } else if key == "embedding_dimension" {
                        dimension = Int(val)
                    }
                }
            }
            return (modelID, dimension)
        }

        /// Writes recorded embedding model and dimension metadata.
        static func writeEmbeddingMeta(handle: OpaquePointer?, modelID: String, dimension: Int) throws {
            var statement1: OpaquePointer?
            let write1 = "INSERT INTO schema_meta(key, value) VALUES('embedding_model_id', ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
            guard sqlite3_prepare_v2(handle, write1, -1, &statement1, nil) == SQLITE_OK else {
                throw DocIndexError.persistenceFailed("Could not prepare embedding model write")
            }
            defer { sqlite3_finalize(statement1) }
            SQLiteHelpers.bindText(statement1, index: 1, value: modelID)
            guard sqlite3_step(statement1) == SQLITE_DONE else {
                throw DocIndexError.persistenceFailed("Could not persist embedding model")
            }

            var statement2: OpaquePointer?
            let write2 = "INSERT INTO schema_meta(key, value) VALUES('embedding_dimension', ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
            guard sqlite3_prepare_v2(handle, write2, -1, &statement2, nil) == SQLITE_OK else {
                throw DocIndexError.persistenceFailed("Could not prepare embedding dimension write")
            }
            defer { sqlite3_finalize(statement2) }
            SQLiteHelpers.bindText(statement2, index: 1, value: String(dimension))
            guard sqlite3_step(statement2) == SQLITE_DONE else {
                throw DocIndexError.persistenceFailed("Could not persist embedding dimension")
            }
        }

        /// Applies stepwise migrations for databases older than ``schemaVersion``.
        private static func migrate(handle: OpaquePointer?, from stored: Int) throws {
            guard stored < 2 else { return }
            try exec(handle: handle, sql: """
            DROP TABLE IF EXISTS indexed_chunks_fts;
            CREATE VIRTUAL TABLE indexed_chunks_fts USING fts5(chunk_text, content='', contentless_delete=1, tokenize='porter');
            DROP TRIGGER IF EXISTS indexed_chunks_ai;
            CREATE TRIGGER indexed_chunks_ai AFTER INSERT ON indexed_chunks BEGIN
                INSERT INTO indexed_chunks_fts(rowid, chunk_text) VALUES(new.rowid, new.chunk_text);
            END;
            DROP TRIGGER IF EXISTS indexed_chunks_ad;
            CREATE TRIGGER indexed_chunks_ad AFTER DELETE ON indexed_chunks BEGIN
                DELETE FROM indexed_chunks_fts WHERE rowid = old.rowid;
            END;
            DROP TRIGGER IF EXISTS indexed_chunks_au;
            CREATE TRIGGER indexed_chunks_au AFTER UPDATE ON indexed_chunks BEGIN
                DELETE FROM indexed_chunks_fts WHERE rowid = old.rowid;
                INSERT INTO indexed_chunks_fts(rowid, chunk_text) VALUES(new.rowid, new.chunk_text);
            END;
            INSERT INTO indexed_chunks_fts(rowid, chunk_text) SELECT rowid, chunk_text FROM indexed_chunks;
            """)
            try exec(handle: handle, sql: "VACUUM;")
        }
    }
#endif

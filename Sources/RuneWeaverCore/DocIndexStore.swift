// Rune Weaver Core — SQLite-backed local document index for keyword and vector search.
//
// Persists one row per indexed document plus its text chunks in a sidecar
// SQLite database, with an FTS5 virtual table over chunk text for keyword
// search and a stored-embedding column for the semantic path. Content hashes
// gate re-indexing so unchanged sources skip writes, and schema versioning
// plus additive column probes keep older databases forward-migratable.
// Blocking SQLite work is dispatched off the actor executor through
// `SQLiteSerialIO`, mirroring the episodic store.
// Document rows live in `DocIndexStoreDocuments.swift`, chunks and search in
// `DocIndexStoreChunks.swift`, and deletion plus statistics in
// `DocIndexStoreMaintenance.swift`.

import Foundation
import os

#if canImport(SQLite3)
    import SQLite3
#endif

/// Actor-isolated SQLite store for the local document index.
///
/// The status snapshot cache below is owned by this actor: one aggregate pass
/// fills it, and both status projections read from it until the TTL lapses.
public actor DocIndexStore {
    /// Filesystem path of the sidecar SQLite database.
    public let dbPath: String
    /// Default SQLite path for the index database, aliasing the canonical
    /// index default so configuration and the store never diverge.
    public static var defaultDBPath: String {
        IndexConfig.defaultDBPath
    }

    /// How long a status snapshot stays reusable before the next poll recomputes it.
    ///
    /// The snapshot is reused for 60 seconds of idle reads, so repeated
    /// dashboard polls within the window issue no SQLite work; any content
    /// write invalidates the cache, so a status poll after a write
    /// recomputes on the next read while keeping staleness predictable.
    /// `markSeen` stamps are excluded because no snapshot field
    /// projects `last_seen_run`.
    public static let statsCacheTTLSeconds: TimeInterval = 60

    /// Cached aggregate snapshot plus when it was taken, in clock time.
    private var cachedStatus: (snapshot: DocIndexStatusSnapshot, at: Date)?

    /// Write generation guarding the status cache against stale resurrection.
    ///
    /// Incremented on every write that invalidates the cache. The snapshot
    /// reader captures it before suspending and discards its pass when it
    /// changed, so a concurrent write's invalidation is never overwritten
    /// by a pre-write aggregate.
    private var statusGeneration: UInt64 = 0

    /// Wall-clock seam for the status cache, injectable so expiry is deterministic under test.
    private let clock: @Sendable () -> Date

    /// Creates a store over a sidecar database.
    /// - Parameters:
    ///   - dbPath: SQLite file path. `~` is expanded on first use.
    ///   - clock: Wall-clock seam for the status cache.
    public init(dbPath: String = DocIndexStore.defaultDBPath, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.dbPath = dbPath
        self.clock = clock
    }

    /// Returns the cached status snapshot when it is still fresh, recomputing once otherwise.
    ///
    /// A hit performs no SQLite work at all, so a repeated poll inside the TTL
    /// issues zero aggregate queries; a miss performs exactly one aggregate
    /// pass through the shared snapshot helper and then projects from it.
    /// Aggregate passes run on the interactive lane so status polls never
    /// queue behind utility-throttled indexing work. The write generation
    /// captured before suspending guards against a
    /// concurrent invalidation: when it changed, this pass may predate the
    /// write, so it is discarded in favor of a fresh refill or a single
    /// bounded post-write retry (at most two passes per call) instead of
    /// caching stale aggregates.
    private func cachedStatusSnapshot() async throws -> DocIndexStatusSnapshot {
        if let cached = cachedStatus, clock().timeIntervalSince(cached.at) < Self.statsCacheTTLSeconds {
            return cached.snapshot
        }
        let dbPath = self.dbPath
        let generationBefore = statusGeneration
        let snapshot = try await SQLiteSerialIO.run(lane: .interactive) {
            try DocIndexStoreIO.statusSnapshot(dbPath: dbPath)
        }
        // A concurrent write invalidated while suspended, so this snapshot
        // may predate it. Never resurrect it over the invalidation: prefer
        // a refill that landed after the write, otherwise retry once for
        // post-write aggregates. The retry is bounded to a single extra pass
        // so sustained writes cannot livelock the poll.
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
        // A concurrent caller may have filled the cache while suspended, so
        // prefer that fresh fill over overwriting with a duplicate pass.
        // A single clock read stamps the entry so an advancing injectable
        // clock cannot extend the TTL beyond the snapshot instant.
        let now = clock()
        if let refilled = cachedStatus, now.timeIntervalSince(refilled.at) < Self.statsCacheTTLSeconds {
            return refilled.snapshot
        }
        cachedStatus = (snapshot, now)
        return snapshot
    }

    /// Clears the status cache and advances the write generation.
    ///
    /// Every mutating method except `markSeen` funnels through here so a
    /// snapshot pass suspended across the write detects the invalidation
    /// and discards its pre-write aggregates instead of caching them.
    private func invalidateStatusCache() {
        cachedStatus = nil
        statusGeneration &+= 1
    }

    /// Inserts or updates a document, skipping the write when the content hash
    /// is unchanged and the prior extraction did not fail.
    /// - Parameter document: Document to persist.
    /// - Returns: The persisted document, including the row's stable identifier.
    @discardableResult
    public func upsertDocument(_ document: IndexedDocument) async throws -> IndexedDocument {
        let dbPath = self.dbPath
        let result = try await SQLiteSerialIO.run(lane: .indexing) {
            try DocIndexStoreIO.upsertDocument(document, dbPath: dbPath)
        }
        invalidateStatusCache()
        return result
    }

    /// Replaces all chunks for a document.
    /// - Parameters:
    ///   - documentID: Document owning the chunks.
    ///   - chunks: Chunks to store; an empty list clears the document's chunks.
    /// - Returns: Number of chunks written.
    @discardableResult
    public func upsertChunks(documentID: UUID, chunks: [IndexedChunk]) async throws -> Int {
        let dbPath = self.dbPath
        let result = try await SQLiteSerialIO.run(lane: .indexing) {
            try DocIndexStoreIO.upsertChunks(documentID: documentID, chunks: chunks, dbPath: dbPath)
        }
        invalidateStatusCache()
        return result
    }

    /// Commits one document with its chunks and run stamp in a single transaction.
    ///
    /// The document row, its replacement chunks (and their FTS entries via
    /// triggers), and the `last_seen_run` stamp land or roll back together,
    /// so an interrupted file never leaves a half-indexed document. Exactly
    /// one document is handled per call to keep cancel, resume, and retire
    /// accounting per-file.
    /// - Parameters:
    ///   - document: Document to persist; a stored row keeps its identifier.
    ///   - chunks: Replacement chunks bound to the document.
    ///   - runID: Opaque stamp recorded alongside the rows for reconcile.
    /// - Returns: The persisted document carrying the stable identifier.
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
        invalidateStatusCache()
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
        invalidateStatusCache()
        return result
    }

    /// Looks up a document by its source-scoped identifier.
    /// - Parameters:
    ///   - source: Origin corpus.
    ///   - externalID: Source-scoped identifier.
    /// - Returns: The stored document, or nil when absent.
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

    /// Reports whether a source must be re-extracted.
    ///
    /// True when the document is unknown, its content hash changed, or a prior
    /// extraction failed; false when the stored body is current.
    /// - Parameters:
    ///   - source: Origin corpus.
    ///   - externalID: Source-scoped identifier.
    ///   - contentHash: Hash of the current source content.
    /// - Returns: True when the document should be re-indexed.
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
    ///
    /// The fingerprint powers the pre-read fast path: callers compare it
    /// against live filesystem metadata to skip unchanged sources without
    /// reading or hashing any bytes.
    /// - Parameters:
    ///   - source: Origin corpus.
    ///   - externalID: Source-scoped identifier.
    /// - Returns: The stored fingerprint, or nil when absent.
    public func storedFingerprint(source: IndexSource, externalID: String) async throws -> DocStoredFingerprint? {
        let dbPath = self.dbPath
        return try await SQLiteSerialIO.run(lane: .indexing) {
            try DocIndexStoreIO.storedFingerprint(source: source, externalID: externalID, dbPath: dbPath)
        }
    }

    /// Stamps one document as seen by the current run.
    ///
    /// Records `runID` in `last_seen_run` so a later reconcile can tell a live
    /// document from one that no longer matches policy. Missing rows are a
    /// no-op so stamping a brand-new path before its first upsert stays safe.
    /// The stamp intentionally leaves the status cache intact: no snapshot
    /// field projects `last_seen_run`, so in-run `markSeen` calls never force
    /// a status poll to miss and re-run the aggregate pass.
    /// - Parameters:
    ///   - source: Origin corpus.
    ///   - externalID: Source-scoped identifier.
    ///   - runID: Opaque identifier for the run in flight.
    public func markSeen(source: IndexSource, externalID: String, runID: String) async throws {
        let dbPath = self.dbPath
        try await SQLiteSerialIO.run(lane: .indexing) {
            try DocIndexStoreIO.markSeen(source: source, externalID: externalID, runID: runID, dbPath: dbPath)
        }
    }

    /// Full-text search over chunk text, optionally restricted to a dated window on the parent document event time.
    /// - Parameters:
    ///   - query: Raw search text.
    ///   - limit: Maximum chunks returned.
    ///   - since: Inclusive lower bound on `indexed_documents.mtime`, or nil for unbounded.
    ///   - until: Exclusive upper bound on `indexed_documents.mtime`, or nil for unbounded.
    /// - Returns: Matching chunks, best-ranked first.
    public func searchKeyword(query: String, limit: Int = 10, since: Date? = nil, until: Date? = nil) async throws -> [IndexedChunk] {
        let dbPath = self.dbPath
        // Canonicalize the dated window through the shared temporal type so
        // since stays inclusive and until stays exclusive by construction.
        let range = TemporalRange(since: since, until: until)
        return try await SQLiteSerialIO.run(lane: .indexing) {
            try DocIndexStoreIO.searchKeyword(query: query, limit: limit, dbPath: dbPath, since: range.since, until: range.until)
        }
    }

    /// Reads chunks that carry an embedding for the semantic path, optionally restricted to a dated window.
    /// The store returns the newest vector chunks first, bounded by `limit`,
    /// so a capped pool favors recent writes over the oldest rows.
    /// - Parameters:
    ///   - limit: Maximum chunks returned.
    ///   - since: Inclusive lower bound on `indexed_documents.mtime`, or nil for unbounded.
    ///   - until: Exclusive upper bound on `indexed_documents.mtime`, or nil for unbounded.
    /// - Returns: Vector chunks, newest first.
    public func chunkVectors(limit: Int = 100, since: Date? = nil, until: Date? = nil) async throws -> [IndexedChunk] {
        let dbPath = self.dbPath
        // Canonicalize the dated window through the shared temporal type so
        // since stays inclusive and until stays exclusive by construction.
        let range = TemporalRange(since: since, until: until)
        return try await SQLiteSerialIO.run(lane: .indexing) {
            try DocIndexStoreIO.chunkVectors(limit: limit, dbPath: dbPath, since: range.since, until: range.until)
        }
    }

    /// Current document, chunk, vector, and byte counts.
    ///
    /// Projects from the cached status snapshot, so a poll inside the TTL
    /// shares one aggregate pass with the storage breakdown instead of
    /// issuing a second round of COUNTs and SUMs.
    /// - Returns: An index statistics snapshot.
    public func stats() async throws -> IndexStats {
        let snapshot = try await cachedStatusSnapshot()
        return snapshot.makeStats()
    }

    /// Reads fast index counts without measuring content bytes.
    ///
    /// Owned by `DocIndexStore`: runs the static fast aggregate on the
    /// interactive lane with zero cache interaction, so a cold status poll
    /// returns true counts and the watermark without touching the slow-pass
    /// counter, `dbstat`, or `LENGTH`. Never reads or writes `cachedStatus`,
    /// so repeated fast polls issue only cheap COUNT work and never extend or
    /// invalidate the slow snapshot TTL.
    /// - Returns: An index statistics snapshot with true counts, true file sizes, and pending slow size fields.
    public func fastStats() async throws -> IndexStats {
        let dbPath = self.dbPath
        return try await SQLiteSerialIO.run(lane: .interactive) {
            try DocIndexStoreIO.fastStats(dbPath: dbPath)
        }
    }

    /// Returns the cached storage breakdown when the slow snapshot is still fresh.
    ///
    /// Owned by `DocIndexStore`: inspects `cachedStatus` against
    /// `statsCacheTTLSeconds` with zero SQLite work, so a warm status poll
    /// can attach true sizes opportunistically while a cold poll degrades to
    /// nil and leaves slow size fields pending. A TTL miss returns nil rather
    /// than recomputing, so callers never trigger a slow pass from this path.
    /// - Returns: The cached storage breakdown, or nil when cold or expired.
    public func cachedStorageIfFresh() async -> IndexStorageBreakdown? {
        if let cached = cachedStatus, clock().timeIntervalSince(cached.at) < Self.statsCacheTTLSeconds {
            return cached.snapshot.makeBreakdown()
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
        invalidateStatusCache()
        return result
    }

    /// Deletes `files` documents not seen by the given run.
    ///
    /// Removes every `files` row whose `last_seen_run` differs from `runID`
    /// (including rows never stamped) together with their chunks, so material
    /// that left policy — deleted files, newly excluded trees, newly denied
    /// paths — stops surfacing in recall. Mail and Messages rows are untouched.
    /// The caller reclaims file space with `reclaim()` after a non-zero return.
    /// - Parameter runID: Opaque identifier of the just-finished walk.
    /// - Returns: Number of `files` documents removed.
    @discardableResult
    public func retireUnseenFiles(runID: String) async throws -> Int {
        let dbPath = self.dbPath
        let result = try await SQLiteSerialIO.run(lane: .indexing) {
            try DocIndexStoreIO.retireUnseenFiles(runID: runID, dbPath: dbPath)
        }
        invalidateStatusCache()
        return result
    }

    /// Deletes `mail` documents whose mailbox sits in the denied set.
    ///
    /// The mail run gate owns matching while this call owns deletion: every
    /// `mail` row whose `mailbox` matches an observed denied name goes with
    /// its chunks, so chunk deletes fire the FTS triggers and retired text
    /// stops surfacing in keyword search. Files and Messages rows are
    /// untouched. The caller reclaims file space after a non-zero return.
    /// - Parameter mailboxes: Observed denied mailbox names.
    /// - Returns: Number of `mail` documents removed.
    @discardableResult
    public func retireMailboxes(_ mailboxes: Set<String>) async throws -> Int {
        guard !mailboxes.isEmpty else { return 0 }
        let dbPath = self.dbPath
        let result = try await SQLiteSerialIO.run(lane: .indexing) {
            try DocIndexStoreIO.retireMailboxes(mailboxes: mailboxes, dbPath: dbPath)
        }
        invalidateStatusCache()
        return result
    }

    /// Reads distinct content hashes for `mail` documents in the given mailboxes.
    ///
    /// The mail gate reads these before retiring so the checkpoint can forget
    /// exactly the retired bodies: re-allowing a mailbox then re-indexes from
    /// scratch instead of deduplicating against its own deleted rows.
    /// - Parameter mailboxes: Observed denied mailbox names.
    /// - Returns: Content hashes of the matching mail documents.
    public func mailContentHashes(mailboxes: Set<String>) async throws -> Set<String> {
        guard !mailboxes.isEmpty else { return [] }
        let dbPath = self.dbPath
        return try await SQLiteSerialIO.run(lane: .indexing) {
            try DocIndexStoreIO.mailContentHashes(mailboxes: mailboxes, dbPath: dbPath)
        }
    }

    /// Clears every document, chunk, and search-index entry, plus incremental mail checkpoints and messages watermarks.
    ///
    /// The sidecar targets are required rather than defaulted so no caller can
    /// silently clear an operator's live checkpoint or watermark: the server
    /// route supplies its context-owned paths, and a production context seeds
    /// the real defaults.
    /// - Parameters:
    ///   - mailCheckpointPath: Persisted mail checkpoint to clear.
    ///   - messagesStatePath: Persisted Messages watermark to clear.
    public func reset(
        mailCheckpointPath: String,
        messagesStatePath: String
    ) async throws {
        let dbPath = self.dbPath
        try await SQLiteSerialIO.run(lane: .indexing) {
            try DocIndexStoreIO.reset(dbPath: dbPath)
        }
        do {
            try MailIndexCheckpointStore.reset(path: mailCheckpointPath)
        } catch {
            RuneWeaverLog.stores.error("DocIndexStore: failed to reset MailIndexCheckpointStore: \(error.localizedDescription)")
        }
        do {
            try MessagesIndexer.resetWatermark(statePath: messagesStatePath)
        } catch {
            RuneWeaverLog.stores.error("DocIndexStore: failed to reset MessagesIndexer watermark: \(error.localizedDescription)")
        }
        invalidateStatusCache()
    }

    /// Current on-disk and logical size breakdown.
    ///
    /// Projects from the same cached snapshot as stats, so one status poll
    /// performs at most one aggregate pass no matter which projection runs
    /// first. File sizes are read from the filesystem so the caller reports what the
    /// disk holds; logical bytes are aggregated from the content tables. A
    /// missing database reports zeros rather than throwing so status probes
    /// render an honest empty state.
    /// - Returns: The storage breakdown.
    public func storageBreakdown() async throws -> IndexStorageBreakdown {
        let snapshot = try await cachedStatusSnapshot()
        return snapshot.makeBreakdown()
    }

    /// Reclaims index file space with `VACUUM`.
    ///
    /// Measures the on-disk total before and after so the caller reports the
    /// saved bytes without recomputing them. A missing database is a zeroed
    /// no-op rather than a failure.
    /// - Returns: The reclaim outcome.
    public func reclaim() async throws -> IndexReclaimResult {
        let dbPath = self.dbPath
        let result = try await SQLiteSerialIO.run(lane: .indexing) {
            try DocIndexStoreIO.reclaim(dbPath: dbPath)
        }
        invalidateStatusCache()
        return result
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
    ///
    /// The dated window rides the shared temporal type so since stays
    /// inclusive and until stays exclusive by construction.
    static func searchKeyword(query: String, limit: Int, dbPath: String, since: Date? = nil, until: Date? = nil) throws -> [IndexedChunk] {
        #if canImport(SQLite3)
            let range = TemporalRange(since: since, until: until)
            return try SQLiteDocIndexStore.searchKeyword(query: query, limit: limit, dbPath: dbPath, since: range.since, until: range.until)
        #else
            throw DocIndexError.storeUnavailable("SQLite3 is unavailable on this platform")
        #endif
    }

    /// Reads the newest chunks that carry an embedding, bounded by `limit`.
    ///
    /// The dated window rides the shared temporal type so since stays
    /// inclusive and until stays exclusive by construction.
    static func chunkVectors(limit: Int, dbPath: String, since: Date? = nil, until: Date? = nil) throws -> [IndexedChunk] {
        #if canImport(SQLite3)
            let range = TemporalRange(since: since, until: until)
            return try SQLiteDocIndexStore.chunkVectors(limit: limit, dbPath: dbPath, since: range.since, until: range.until)
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

    /// Reads fast index counts without measuring content bytes.
    ///
    /// Owned by `DocIndexStoreIO`: thin passthrough to the static fast
    /// aggregate, so the actor stays off blocking SQLite work while tests can
    /// still prove zero `LENGTH`/`dbstat` work at the static layer. Never
    /// touches the slow snapshot counter.
    /// - Parameter dbPath: SQLite file path.
    /// - Returns: An index statistics snapshot with true counts and pending slow size fields.
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
    ///
    /// Holds the on-disk revision, table plus trigger definitions, additive
    /// column probes, and the shared open helper. Document rows, chunks, and
    /// maintenance live in their own files under the same namespace.
    enum SQLiteDocIndexStore {
        /// Current on-disk schema revision.
        static let schemaVersion = 2

        /// Maximum rows returned per read when a caller passes an oversized limit.
        static let maxResults = 1000

        /// Column projection shared by every document read.
        static let documentColumnList =
            "id, source, external_id, display_name, path, message_id, mailbox, mtime, "
                + "size_bytes, content_hash, mime, extract_status, indexed_at, metadata"

        /// Shared chunk full-text trigger definitions.
        ///
        /// Single-sourced so `tablesSQL` and `migrateFTSTriggers` cannot drift;
        /// both execute the same `CREATE TRIGGER IF NOT EXISTS` block.
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
        ///
        /// Only columns present since the first revision are referenced here so
        /// a legacy database that predates an additive column still executes
        /// this block cleanly; the indexes that depend on later columns live in
        /// ``indexesSQL``. Full-text triggers ride the shared ``ftsTriggersSQL``.
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
        CREATE INDEX IF NOT EXISTS idx_indexed_documents_last_seen ON indexed_documents(last_seen_run);
        CREATE INDEX IF NOT EXISTS idx_indexed_chunks_document ON indexed_chunks(document_id);
        CREATE INDEX IF NOT EXISTS idx_indexed_chunks_vector ON indexed_chunks(is_vector);
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
        ///
        /// Holds canonical database paths already ensured in this process so
        /// later opens skip every DDL write. Only the path insertion is
        /// serialized; the DDL itself runs unlocked because concurrent first
        /// opens are idempotent through `IF NOT EXISTS` plus conditional ALTERs.
        private static let ensuredPathsLock = OSAllocatedUnfairLock(initialState: Set<String>())

        /// Bounds the ensure gate so distinct database paths never grow memory without bound.
        private static let maxEnsuredPaths = 500

        /// Canonical cache key for a database path.
        ///
        /// Expands `~` and resolves symlinks so two spellings of the same
        /// file share one gate entry instead of ensuring twice.
        /// - Parameter dbPath: SQLite file path.
        /// - Returns: Symlink-resolved filesystem path.
        static func canonicalDBPath(_ dbPath: String) -> String {
            let expanded = (dbPath as NSString).expandingTildeInPath
            let leafResolved = resolveLeafSymlink(expanded)
            return URL(fileURLWithPath: leafResolved).resolvingSymlinksInPath().standardizedFileURL.path
        }

        /// Resolves a leaf symlink chain without requiring the target to exist.
        ///
        /// `resolvingSymlinksInPath` leaves a dangling leaf spelling unresolved,
        /// so a symlink pointing at a not-yet-created database would keep its
        /// link spelling and miss the shared gate entry. Walking the leaf with
        /// `destinationOfSymbolicLink` handles that case, including relative
        /// destinations and chained links, before the URL pass resolves parents.
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
        ///
        /// Keeps a reset or a replaced database from reusing a stale gate entry.
        /// - Parameter dbPath: SQLite file path.
        static func removeEnsuredPath(_ dbPath: String) {
            let key = canonicalDBPath(dbPath)
            _ = ensuredPathsLock.withLock { $0.remove(key) }
        }

        /// Reports whether the document table exists on an open handle.
        ///
        /// Detects a database file deleted or replaced after the gate filled,
        /// so the fast path can fall back to the full ensure instead of
        /// handing out an empty file with no tables.
        /// - Parameter handle: Open database handle.
        /// - Returns: True when `indexed_documents` exists.
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
        ///
        /// Ensure gate owned by `SQLiteDocIndexStore.open`: the first open per
        /// canonical path in this process runs `tablesSQL`, `indexesSQL`,
        /// `ensureColumns`, `ensureSchemaVersion`, and `migrateFTSTriggers`;
        /// later opens perform `sqlite3_open` plus `PRAGMA foreign_keys` plus a
        /// read-only `sqlite_master` table-exists probe.
        /// The shared busy-timeout and WAL policy stays in
        /// `SQLiteHelpers.openHandle`, which both paths call, so the fast path
        /// keeps the same durability posture while issuing zero DDL writes
        /// (the probe is a read-only `SELECT`, never a schema write).
        /// When the file was deleted or replaced after the gate filled, the
        /// fast path falls back to the full ensure so a fresh file regains its
        /// tables instead of serving an empty schema.
        /// - Parameter dbPath: SQLite file path. `~` is expanded.
        /// - Returns: Open database handle. Caller must close it.
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
        ///
        /// Probes each table's declared columns and runs only the missing
        /// `ALTER`s, so replaying against an already-current database is a
        /// no-op and concurrent opens stay safe.
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
        ///
        /// Runs only `CREATE TRIGGER IF NOT EXISTS` so replaying against an
        /// already-current database is a schema no-op; gated with the rest of
        /// the ensure path so later opens skip it entirely. Shares
        /// ``ftsTriggersSQL`` with `tablesSQL` so the two paths cannot drift.
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

        /// Applies stepwise migrations for databases older than ``schemaVersion``.
        ///
        /// Revision 2 converts the chunk full-text index to a contentless
        /// table so chunk text is stored once in `indexed_chunks`. Dropping
        /// the virtual table removes its `fts_content`, `fts_data`,
        /// `fts_idx`, and `fts_docsize` shadow tables; the rebuild then
        /// repopulates the index from the content rows before reclaiming
        /// space. Triggers stay as plain `INSERT` and `DELETE` by rowid,
        /// avoiding the FTS5 delete command broken on recent macOS SQLite.
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

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

    /// Maximum results returned when vector scans are bounded by a temporal window.
    public static let maxVectorWindowResults = 10000

    /// How long a status snapshot stays reusable before the next poll re-reads the persisted row.
    ///
    /// The snapshot is reused for 60 seconds of idle reads, so repeated
    /// dashboard polls within the window issue no SQLite work; any content
    /// write invalidates the memory cache, so the next poll re-reads the
    /// frozen persisted row with zero aggregate passes while keeping staleness
    /// predictable. The TTL never gates correctness — a cold poll still serves
    /// single-row reads forever. `markSeen` stamps are excluded because no
    /// snapshot field projects `last_seen_run`.
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

    /// Tracks whether the persisted aggregate tables lag behind content writes.
    ///
    /// Set on every cache invalidation (content writes without an inline
    /// refresh) and cleared by the single writer once it persists fresh rows.
    /// Freeze-then-jump readers serve the persisted row frozen regardless of
    /// this flag and repair only when absent, so warm and mid-run polls never
    /// pay for a content scan; in-run freshness rides `liveTotals` only.
    private var aggregatesDirty = false

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
    /// and discards its pre-write aggregates instead of caching them. The
    /// persisted tables lag until the next terminal or route-driven refresh,
    /// so mid-run readers stay frozen on the last persisted row and only an
    /// absent row repairs with one pass.
    private func invalidateStatusCache() {
        cachedStatus = nil
        statusGeneration &+= 1
        aggregatesDirty = true
    }

    /// Reads the persisted aggregate snapshot without running any content scan.
    ///
    /// Runs on the interactive lane so warm polls never queue behind indexing
    /// work. A missing row or table returns nil rather than failing so the
    /// caller can repair once through the single writer; only a genuine open
    /// failure throws. Never touches the aggregate-pass counter.
    /// - Returns: The persisted snapshot, or nil when no refresh has run.
    private func readPersistedSnapshot() async throws -> DocIndexStatusSnapshot? {
        let dbPath = self.dbPath
        return try await SQLiteSerialIO.run(lane: .interactive) {
            try DocIndexStoreIO.readAggregateSnapshot(dbPath: dbPath)
        }
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
    /// Event-time ordering keeps the capped pool over recently happening
    /// documents — parent `mtime` descending with NULLs last — never recently
    /// written rows, so a bounded pool favors recent event time over the oldest
    /// rows.
    /// - Parameters:
    ///   - limit: Maximum chunks returned.
    ///   - since: Inclusive lower bound on `indexed_documents.mtime`, or nil for unbounded.
    ///   - until: Exclusive upper bound on `indexed_documents.mtime`, or nil for unbounded.
    /// - Returns: Vector chunks, parent event time (`mtime`) descending with NULLs last.
    public func chunkVectors(limit: Int = 100, since: Date? = nil, until: Date? = nil) async throws -> [IndexedChunk] {
        let dbPath = self.dbPath
        // Canonicalize the dated window through the shared temporal type so
        // since stays inclusive and until stays exclusive by construction.
        let range = TemporalRange(since: since, until: until)
        return try await SQLiteSerialIO.run(lane: .indexing) {
            try DocIndexStoreIO.chunkVectors(limit: limit, dbPath: dbPath, since: range.since, until: range.until)
        }
    }

    /// Serves a frozen aggregate projection from the persisted single row, repairing only when absent.
    ///
    /// Freeze-then-jump: a memory hit inside the TTL returns with no I/O, a
    /// persisted row projects frozen with zero aggregate passes on the
    /// interactive lane regardless of `aggregatesDirty`, and only an absent
    /// row pays for one repairing refresh that also warms the cache and
    /// persists. In-run freshness rides `liveTotals` only, never a mid-run
    /// content scan, so 2s status/storage polls stay single-row reads forever
    /// and the write-path aggregate refreshed on the `.indexing` lane at run
    /// end is the single jump. File sizes ride live probes while content and
    /// full-text legs ride the stored rows, so the shape matches a live pass
    /// field-for-field. A write racing this read never resurrects pre-write
    /// aggregates: on a generation mismatch a concurrent refill that landed
    /// after the write wins first, and only when no refill exists is the
    /// frozen persisted row served, so concurrent readers never pay for a
    /// full content scan.
    /// - Parameter make: Projection from the shared snapshot to the caller's view.
    /// - Returns: The projected view.
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

    /// Refreshes the persisted aggregates, keeping the prior row on failure.
    ///
    /// Route-driven mutations have no run-end refresh to follow, so they persist
    /// fresh aggregates inline; a failed refresh keeps the previous row (logged
    /// inside `refreshAggregates`) instead of failing the mutation.
    private func refreshAggregatesIgnoringFailure() async {
        do {
            _ = try await refreshAggregates()
        } catch {
            RuneWeaverLog.stores.debug("DocIndexStore: refreshAggregates inline refresh ignored failure: \(error.localizedDescription)")
        }
    }

    /// Current document, chunk, vector, and byte counts.
    ///
    /// Freeze-then-jump: a memory hit inside the TTL returns with no I/O, a
    /// persisted row projects frozen with zero aggregate passes on the
    /// interactive lane regardless of `aggregatesDirty`, and only an absent
    /// row pays for one repairing refresh that also warms the cache and
    /// persists. File sizes ride live probes while content and full-text legs
    /// ride the stored rows, so the shape matches a live pass field-for-field.
    /// In-run freshness rides `liveTotals` only; mid-run polls never trigger
    /// a content scan here.
    /// - Returns: An index statistics snapshot.
    public func stats() async throws -> IndexStats {
        try await persistedSnapshotOrRefresh { $0.makeStats() }
    }

    /// Reads fast index counts with true sizes from the persisted single row.
    ///
    /// Freeze-then-jump: a persisted row projects frozen with true counts,
    /// the watermark, and true sizes with zero aggregate passes on the
    /// interactive lane regardless of `aggregatesDirty`; in-run freshness
    /// rides `liveTotals` only, never a mid-run COUNT here. Only an absent
    /// row pays for one repairing refresh that also persists. Never reads or
    /// writes `cachedStatus`, so fast polls never extend or invalidate the
    /// slow snapshot TTL.
    /// - Returns: An index statistics snapshot with true counts and true sizes from the persisted row.
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
    ///
    /// Owned by `DocIndexStore`: a memory hit inside the TTL returns with
    /// zero SQLite work, otherwise projects the persisted single row frozen
    /// with zero aggregate passes on the interactive lane regardless of
    /// `aggregatesDirty`. The TTL never gates correctness — a cold poll still
    /// serves true sizes from the persisted row — and only an absent row
    /// returns nil so the caller falls back to fail-closed zeros. Callers
    /// never trigger a slow pass from this path.
    /// - Returns: The persisted storage breakdown, or nil when no refresh has run.
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
        invalidateStatusCache()
        // Route-driven deletes leave no run to refresh the persisted rows, so
        // refresh here to keep dashboard reads fresh without waiting for the
        // next indexing pass. A failed refresh keeps the previous row.
        await refreshAggregatesIgnoringFailure()
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
        // Retired files change the persisted counts with no run-end refresh to
        // follow, so persist fresh aggregates now. A failure keeps prior rows.
        await refreshAggregatesIgnoringFailure()
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
        // Retired mailboxes change the persisted counts with no run-end refresh
        // to follow, so persist fresh aggregates now. A failure keeps prior rows.
        await refreshAggregatesIgnoringFailure()
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
        // A full clear leaves no run to refresh the persisted rows, so persist
        // the emptied aggregates now. A failure keeps the previous row.
        await refreshAggregatesIgnoringFailure()
    }

    /// Clears documents and chunks for a specific source (e.g. `.mail`),
    /// preserving all other indexed sources. The `.mail` branch also resets
    /// the mail checkpoint so purged messages re-index from the lowest UID;
    /// `.messages` resets the messages watermark the same way.
    /// - Parameters:
    ///   - source: Source to clear.
    ///   - mailCheckpointPath: Optional mail checkpoint path to reset when source is `.mail`.
    ///   - messagesStatePath: Optional Messages watermark path to clear when source is `.messages`.
    /// - Returns: Count of removed documents.
    @discardableResult
    public func clearSource(
        _ source: IndexSource,
        mailCheckpointPath: String? = nil,
        messagesStatePath: String? = nil
    ) async throws -> Int {
        let dbPath = self.dbPath
        let removed = try await SQLiteSerialIO.run(lane: .indexing) {
            try DocIndexStoreIO.clearSource(source: source.rawValue, dbPath: dbPath)
        }
        if source == .mail {
            do {
                try MailIndexCheckpointStore.reset(path: mailCheckpointPath ?? MailIndexCheckpointStore.defaultPath)
            } catch {
                RuneWeaverLog.stores.error("DocIndexStore: failed to reset MailIndexCheckpointStore: \(error.localizedDescription)")
            }
        }
        if source == .messages {
            do {
                try MessagesIndexer.resetWatermark(statePath: messagesStatePath ?? MessagesIndexer.defaultStatePath)
            } catch {
                RuneWeaverLog.stores.error("DocIndexStore: failed to reset MessagesIndexer watermark: \(error.localizedDescription)")
            }
        }
        invalidateStatusCache()
        // A source clear changes the persisted counts with no run-end refresh to
        // follow, so persist fresh aggregates now. A failure keeps prior rows.
        await refreshAggregatesIgnoringFailure()
        return removed
    }

    /// Current on-disk and logical size breakdown.
    ///
    /// Freeze-then-jump like `stats()`: a memory hit returns with no I/O, a
    /// persisted row projects the full breakdown including the stored
    /// full-text leg frozen with zero aggregate passes regardless of
    /// `aggregatesDirty`, and only an absent row pays for one repairing
    /// refresh. A missing database repairs to an honest empty state rather
    /// than throwing; mid-run polls never trigger a content scan here.
    /// - Returns: The storage breakdown.
    public func storageBreakdown() async throws -> IndexStorageBreakdown {
        try await persistedSnapshotOrRefresh { $0.makeBreakdown() }
    }

    /// Recomputes the persisted aggregate tables from a fresh snapshot.
    ///
    /// The single writer for the three aggregate tables: runs the shared
    /// single-pass compute plus the single-transaction replace on the
    /// indexing lane, then warms the status cache from the computed value so
    /// the next poll is a memory hit instead of a second aggregate pass. A
    /// failure logs and preserves both the previous database row (via
    /// transaction rollback) and the previous cached snapshot. Runs ignoring
    /// outer cancellation so a cancelled run still persists its partial
    /// aggregates instead of surfacing `CancellationError` with no row.
    /// - Parameter producingRunID: Opaque run identity recorded alongside the row, or nil for route-driven refreshes.
    /// - Returns: The snapshot that was persisted.
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
        // Warm the cache from the persisted value rather than invalidating:
        // the snapshot is already post-write, so the next poll must not pay
        // for another aggregate pass. The generation still advances so a
        // status pass suspended across this write discards its pre-write
        // aggregates instead of resurrecting them over the fresh row. The
        // persisted tables are fresh again, so later readers serve them with
        // zero passes until the next content write dirties them.
        cachedStatus = (snapshot, clock())
        statusGeneration &+= 1
        aggregatesDirty = false
        return snapshot
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
        // VACUUM rewrites page layout so the persisted full-text size shifts
        // even when document counts do not; persist fresh aggregates now.
        // A failure keeps the previous row.
        await refreshAggregatesIgnoringFailure()
        return result
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

    /// Verifies that the store's embedded vectors match the active embedder's dimension.
    /// If there is an existing dimension recorded that differs from activeDimension,
    /// a full reset is performed so all documents are cleanly re-embedded.
    /// - Returns: True if a reset occurred due to dimension mismatch.
    public func ensureEmbeddingDimensionMatch(
        activeModelID: String,
        activeDimension: Int,
        mailCheckpointPath: String,
        messagesStatePath: String
    ) async throws -> Bool {
        let meta = try await readEmbeddingMeta()
        if let storedDimension = meta.dimension, storedDimension != activeDimension {
            RuneWeaverLog.stores.warning(
                "DocIndexStore: embedding dimension mismatch (stored: \(storedDimension), active: \(activeDimension)); triggering re-index reset."
            )
            try await reset(mailCheckpointPath: mailCheckpointPath, messagesStatePath: messagesStatePath)
            try await writeEmbeddingMeta(modelID: activeModelID, dimension: activeDimension)
            return true
        }
        if meta.dimension == nil {
            let stats = try await SQLiteSerialIO.run(lane: .indexing) {
                try DocIndexStoreIO.fastStats(dbPath: self.dbPath)
            }
            if stats.vectorChunks > 0 {
                RuneWeaverLog.stores.warning(
                    "DocIndexStore: unversioned vector chunks detected without dimension metadata; resetting to dimension \(activeDimension)."
                )
                try await reset(mailCheckpointPath: mailCheckpointPath, messagesStatePath: messagesStatePath)
                try await writeEmbeddingMeta(modelID: activeModelID, dimension: activeDimension)
                return true
            }
            try await writeEmbeddingMeta(modelID: activeModelID, dimension: activeDimension)
        }
        return false
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

    /// Reads the chunks that carry an embedding with the most recent parent
    /// event time — `mtime` descending with NULLs last — bounded by `limit`.
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

    /// Reads the persisted aggregate snapshot without running any content scan.
    ///
    /// Thin passthrough so the actor stays off blocking SQLite work while the
    /// static layer owns the aggregate-table reads plus live file-size probes.
    /// A missing row reads as nil so the caller can repair once through the
    /// single writer; never touches the aggregate-pass counter.
    /// - Parameter dbPath: SQLite file path.
    /// - Returns: The persisted snapshot, or nil when no refresh has run.
    static func readAggregateSnapshot(dbPath: String) throws -> DocIndexStatusSnapshot? {
        #if canImport(SQLite3)
            return try SQLiteDocIndexStore.readAggregateSnapshot(dbPath: dbPath)
        #else
            throw DocIndexError.storeUnavailable("SQLite3 is unavailable on this platform")
        #endif
    }

    /// Recomputes the persisted aggregate tables from a fresh snapshot.
    ///
    /// Thin passthrough so the actor stays off blocking SQLite work while the
    /// static layer owns the single-pass compute plus the single-transaction
    /// replace. Callers observe the persisted snapshot for cache warming.
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
    ///
    /// Holds the on-disk revision, table plus trigger definitions, additive
    /// column probes, and the shared open helper. Document rows, chunks, and
    /// maintenance live in their own files under the same namespace.
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
        CREATE INDEX IF NOT EXISTS idx_indexed_documents_mtime ON indexed_documents(mtime);
        CREATE INDEX IF NOT EXISTS idx_indexed_documents_last_seen ON indexed_documents(last_seen_run);
        CREATE INDEX IF NOT EXISTS idx_indexed_chunks_document ON indexed_chunks(document_id);
        CREATE INDEX IF NOT EXISTS idx_indexed_chunks_vector ON indexed_chunks(is_vector);
        """

        /// Precomputed aggregate tables backing the index status cache.
        ///
        /// The single-row `index_aggregates` table pins its row to `id = 0` so
        /// every refresh overwrites the same row instead of appending history;
        /// per-source and per-status tables fan out by their string keys so
        /// readers can serve the dashboard without scanning content tables.
        /// `fts_bytes` stays nullable to preserve the unavailable-`dbstat`
        /// distinction instead of collapsing it to zero, while
        /// `producing_run_id` stays nullable because route-driven refreshes
        /// carry no run identity. Created beside the indexes so legacy files
        /// gain the tables on their first ensured open.
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
        /// `aggregatesSQL`, `ensureColumns`, `ensureSchemaVersion`, and `migrateFTSTriggers`;
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

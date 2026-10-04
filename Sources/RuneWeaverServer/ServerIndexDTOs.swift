// Rune Weaver Server — Local index status, control, and settings DTOs.
//
// Purpose: carries the `/index` status plus run, cancel, prune, and reset
// request/response shapes and the partial `[index]` patch for `PUT /settings`,
// so the dashboard can read counts, per-source enablement, and recent failures
// while edits preserve every field the request omits.
// Scope: REST bodies only; run coordination stays with `IndexCoordinator`,
// persistence with `DocIndexStore`, and range/closed-set checks with the config
// validation layer.
// Architectural role: keeps the Vapor index adapters decoupled from the engine
// core by mirroring the engine's index shapes in version-tolerant Codable
// contracts, so a dashboard built against an older engine still decodes.

import Foundation
import RuneWeaverCore
import Vapor

/// One source's enablement row on `GET /index/status`.
public struct IndexSourceStatus: Content, Equatable {
    /// Source kind (`"files"`, `"mail"`, or `"messages"`).
    public let kind: String
    /// Whether the source is enabled under the active policy. Global
    /// enablement gates every source, matching the coordinator's stage
    /// eligibility so the dashboard never shows a source as live while the
    /// indexer as a whole is off.
    public let enabled: Bool

    /// Creates a source enablement row.
    /// - Parameters:
    ///   - kind: Source kind token.
    ///   - enabled: Whether the source is effectively enabled.
    public init(kind: String, enabled: Bool) {
        self.kind = kind
        self.enabled = enabled
    }
}

/// Per-source content counts on `GET /index/status`.
public struct IndexSourceCounts: Content, Equatable {
    /// Source kind (`"files"`, `"mail"`, or `"messages"`).
    public let kind: String
    /// Number of indexed documents from this source.
    public let documents: Int
    /// Number of stored chunks belonging to this source.
    public let chunks: Int
    /// Total chunk text bytes belonging to this source. Zero is the explicit
    /// pending sentinel from the fast pass, not an estimate; the true slow
    /// total is filled by `GET /index/storage`.
    public let bytes: Int64

    /// Creates a per-source content row.
    /// - Parameters:
    ///   - kind: Source kind token.
    ///   - documents: Indexed document count.
    ///   - chunks: Stored chunk count.
    ///   - bytes: Total chunk text bytes; zero is the fast-pass pending sentinel filled by `GET /index/storage`.
    public init(kind: String, documents: Int = 0, chunks: Int = 0, bytes: Int64 = 0) {
        self.kind = kind
        self.documents = documents
        self.chunks = chunks
        self.bytes = bytes
    }
}

/// Extraction-outcome breakdown row on `GET /index/status`.
public struct IndexExtractStatusCounts: Content, Equatable {
    /// Extraction outcome token (`"extracted"`, `"partial"`, and so on).
    public let status: String
    /// Number of indexed documents with this outcome.
    public let documents: Int

    /// Creates an extraction-outcome row.
    /// - Parameters:
    ///   - status: Extraction outcome token.
    ///   - documents: Indexed document count.
    public init(status: String, documents: Int = 0) {
        self.status = status
        self.documents = documents
    }
}

/// Latest index run outcome on `GET /index/status`, distilled from the newest
/// `index`-kind `run_logs` row.
public struct IndexLastRunStatus: Content, Equatable {
    /// Terminal (or in-flight) state token.
    public let status: String
    /// Documents written by the run, when the summary line carried a count.
    public let indexed: Int?
    /// Items examined by the run, when the summary line carried a count.
    public let scanned: Int?
    /// Items that could not be processed, when the summary line carried a count.
    public let errors: Int?
    /// Instant the run finished (the run log timestamp).
    public let finishedAt: Date?
    /// What caused the run (`"nightly"`, `"catchUp"`, or `"onDemand"`), when
    /// the run message or response carried a trigger token. Nil for rows whose
    /// wording predates trigger tracking so older engines still decode.
    public let trigger: String?
    /// Why the run did not execute, when the completion response carried a
    /// `Skipped:` detail line. Nil for executed runs and for rows whose
    /// wording predates skip-reason tracking so older engines still decode.
    public let skippedReason: String?
    /// Documents retired by the run. Optional for back-compat; absent degrades
    /// to no retired count instead of failing.
    public let retiredCount: Int?
    /// Documents where the vector cap left tail chunks keyword-only. Optional
    /// for back-compat; absent degrades to no truncated count instead of
    /// failing.
    public let truncatedCount: Int?

    /// Creates a last-run row.
    /// - Parameters:
    ///   - status: Run state token.
    ///   - indexed: Documents written.
    ///   - scanned: Items examined.
    ///   - errors: Items that could not be processed.
    ///   - finishedAt: Instant the run finished.
    ///   - trigger: What caused the run, when known.
    ///   - skippedReason: Why the run did not execute, when known.
    ///   - retiredCount: Documents retired, when known.
    ///   - truncatedCount: Documents truncated by the vector cap, when known.
    public init(
        status: String,
        indexed: Int? = nil,
        scanned: Int? = nil,
        errors: Int? = nil,
        finishedAt: Date? = nil,
        trigger: String? = nil,
        skippedReason: String? = nil,
        retiredCount: Int? = nil,
        truncatedCount: Int? = nil
    ) {
        self.status = status
        self.indexed = indexed
        self.scanned = scanned
        self.errors = errors
        self.finishedAt = finishedAt
        self.trigger = trigger
        self.skippedReason = skippedReason
        self.retiredCount = retiredCount
        self.truncatedCount = truncatedCount
    }

    /// Coding keys for the version-tolerant last-run contract.
    private enum CodingKeys: String, CodingKey {
        case status
        case indexed
        case scanned
        case errors
        case finishedAt
        case trigger
        case skippedReason
        case retiredCount
        case retired
        case truncatedCount
        case truncated
    }

    /// Decodes a last-run row, defaulting absent counts and the skip reason to
    /// nil so payloads built against an older engine still decode. Accepts the
    /// `retired`/`truncated` aliases some engines emit; the canonical
    /// `retiredCount`/`truncatedCount` keys win when both are present.
    /// - Parameter decoder: Decoder carrying the row.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(String.self, forKey: .status)
        indexed = try container.decodeIfPresent(Int.self, forKey: .indexed)
        scanned = try container.decodeIfPresent(Int.self, forKey: .scanned)
        errors = try container.decodeIfPresent(Int.self, forKey: .errors)
        finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
        trigger = try container.decodeIfPresent(String.self, forKey: .trigger)
        skippedReason = try container.decodeIfPresent(String.self, forKey: .skippedReason)
        let canonicalRetired = try container.decodeIfPresent(Int.self, forKey: .retiredCount)
        let aliasRetired = try container.decodeIfPresent(Int.self, forKey: .retired)
        retiredCount = canonicalRetired ?? aliasRetired
        let canonicalTruncated = try container.decodeIfPresent(Int.self, forKey: .truncatedCount)
        let aliasTruncated = try container.decodeIfPresent(Int.self, forKey: .truncated)
        truncatedCount = canonicalTruncated ?? aliasTruncated
    }

    /// Encodes a last-run row, omitting absent counts and the skip reason.
    /// retired and truncated counts ride the canonical keys so current
    /// dashboards render from one fetch; the aliases are not re-emitted.
    /// - Parameter encoder: Encoder receiving the row.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(indexed, forKey: .indexed)
        try container.encodeIfPresent(scanned, forKey: .scanned)
        try container.encodeIfPresent(errors, forKey: .errors)
        try container.encodeIfPresent(finishedAt, forKey: .finishedAt)
        try container.encodeIfPresent(trigger, forKey: .trigger)
        try container.encodeIfPresent(skippedReason, forKey: .skippedReason)
        try container.encodeIfPresent(retiredCount, forKey: .retiredCount)
        try container.encodeIfPresent(truncatedCount, forKey: .truncatedCount)
    }
}

/// Live in-flight index run snapshot on `GET /index/status`, derived from the
/// coordinator's `liveTotals`. Null when idle so polling surfaces unmount the
/// live strip without persisting any post-run summary.
public struct IndexLiveStatus: Content, Equatable {
    /// What caused the run (`"nightly"`, `"catchUp"`, or `"onDemand"`).
    public let trigger: String
    /// Active phase (`"discovering"`, `"extracting"`, `"embedding"`, `"committing"`).
    public let phase: String
    /// Active source stage (`"files"`, `"mail"`, `"messages"`, `"vision"`), or nil.
    public let stage: String?
    /// Items examined across completed work plus observed in-flight progress.
    public let scanned: Int
    /// Documents written across completed work plus observed in-flight progress.
    public let indexed: Int
    /// Items deliberately skipped across completed stages.
    public let skipped: Int
    /// Items that could not be processed across completed stages.
    public let errors: Int
    /// Documents per second derived from indexed over elapsed time.
    public let rate: Double
    /// Milliseconds elapsed since the run began.
    public let elapsedMs: Int
    /// Last relative item reported, for the display `current` field.
    public let current: String?

    /// Creates a live snapshot row.
    /// - Parameters:
    ///   - trigger: What caused the run.
    ///   - phase: Active phase token.
    ///   - stage: Active source stage token, or nil.
    ///   - scanned: Items examined.
    ///   - indexed: Documents written.
    ///   - skipped: Items deliberately skipped.
    ///   - errors: Items that could not be processed.
    ///   - rate: Documents per second.
    ///   - elapsedMs: Milliseconds elapsed since the run began.
    ///   - current: Last relative item reported.
    public init(
        trigger: String,
        phase: String,
        stage: String? = nil,
        scanned: Int = 0,
        indexed: Int = 0,
        skipped: Int = 0,
        errors: Int = 0,
        rate: Double = 0,
        elapsedMs: Int = 0,
        current: String? = nil
    ) {
        self.trigger = trigger
        self.phase = phase
        self.stage = stage
        self.scanned = scanned
        self.indexed = indexed
        self.skipped = skipped
        self.errors = errors
        self.rate = rate
        self.elapsedMs = elapsedMs
        self.current = current
    }

    /// Maps coordinator live totals onto the wire shape.
    /// - Parameter totals: In-flight snapshot from `IndexCoordinator.liveTotals`.
    public init(_ totals: IndexLiveTotals) {
        self.trigger = totals.trigger.rawValue
        self.phase = totals.phase.rawValue
        self.stage = totals.stage?.rawValue
        self.scanned = totals.scanned
        self.indexed = totals.indexed
        self.skipped = totals.skipped
        self.errors = totals.errors
        self.rate = totals.rate
        self.elapsedMs = totals.elapsedMs
        self.current = totals.current
    }
}

/// Effort block on `GET /index/status`, resolving the stored preset to the
/// worker count the next run will use on this machine.
public struct IndexEffortStatus: Content, Equatable {
    /// Stored effort preset (`"light"`, `"balanced"`, `"performance"`, `"custom"`).
    public let preset: String
    /// Worker count resolved from the preset on this machine.
    public let resolvedWorkers: Int
    /// Logical core count observed when the snapshot was built.
    public let activeProcessors: Int

    /// Creates an effort row.
    /// - Parameters:
    ///   - preset: Stored effort preset.
    ///   - resolvedWorkers: Worker count the next run will use.
    ///   - activeProcessors: Logical core count observed.
    public init(preset: String, resolvedWorkers: Int, activeProcessors: Int) {
        self.preset = preset
        self.resolvedWorkers = resolvedWorkers
        self.activeProcessors = activeProcessors
    }
}

/// Status snapshot for `GET /index/status`.
public struct IndexStatusResponse: Content, Equatable {
    /// Whether the background indexer runs at all.
    public let enabled: Bool
    /// Whether an index run is currently in flight.
    public let running: Bool
    /// Number of indexed documents.
    public let documents: Int
    /// Number of stored chunks.
    public let chunks: Int
    /// Number of chunks carrying an embedding.
    public let vectorChunks: Int
    /// Number of chunks searchable by keyword only.
    public let keywordChunks: Int
    /// Total chunk text bytes held by the index.
    public let bytes: Int64
    /// Main SQLite file size in bytes, read from the filesystem.
    public let dbFileBytes: Int64
    /// Write-ahead log size in bytes, zero when checkpointed.
    public let walBytes: Int64
    /// Total chunk text bytes held by the index.
    public let textBytes: Int64
    /// Total embedding BLOB bytes held by vector chunks.
    public let vectorBytes: Int64
    /// Full-text index bytes, zero when the size probe is unavailable.
    public let ftsBytes: Int64
    /// Unused freelist bytes reclaimable by `POST /index/reclaim`.
    public let freeBytes: Int64
    /// Logical content bytes (`textBytes` plus `vectorBytes`).
    public let contentBytes: Int64
    /// Watermark of the last successful snapshot, nil when never indexed.
    public let indexAsOf: Date?
    /// Per-source enablement rows in canonical run order.
    public let sources: [IndexSourceStatus]
    /// Most recent index run failures, newest first, with no content or secrets.
    public let lastErrors: [String]
    /// Per-source document/chunk/byte aggregates, one row per origin corpus.
    public let bySource: [IndexSourceCounts]
    /// Document counts grouped by extraction outcome.
    public let byExtractStatus: [IndexExtractStatusCounts]
    /// Latest index run outcome, or nil when no run has been recorded.
    public let lastRun: IndexLastRunStatus?
    /// Live in-flight snapshot, or nil when idle. Additive and optional so
    /// payloads built against an older engine still decode.
    public let live: IndexLiveStatus?
    /// Resolved effort block, always present so the dashboard renders workers
    /// without a second fetch. Additive so older payloads decode to the stock
    /// preset.
    public let effort: IndexEffortStatus?

    /// Creates an index status snapshot.
    /// - Parameters:
    ///   - enabled: Whether the background indexer runs at all.
    ///   - running: Whether a run is in flight.
    ///   - documents: Indexed document count.
    ///   - chunks: Stored chunk count.
    ///   - vectorChunks: Chunks carrying an embedding.
    ///   - keywordChunks: Keyword-only chunks.
    ///   - bytes: Total chunk text bytes.
    ///   - dbFileBytes: Main file size.
    ///   - walBytes: Write-ahead log size.
    ///   - textBytes: Chunk text bytes.
    ///   - vectorBytes: Embedding bytes.
    ///   - ftsBytes: Full-text index bytes.
    ///   - freeBytes: Freelist bytes.
    ///   - contentBytes: Logical content bytes.
    ///   - indexAsOf: Last successful watermark, or nil.
    ///   - sources: Per-source enablement rows.
    ///   - lastErrors: Recent run failures, newest first.
    ///   - bySource: Per-source content aggregates.
    ///   - byExtractStatus: Extraction-outcome breakdown.
    ///   - lastRun: Latest run outcome, or nil.
    ///   - live: Live in-flight snapshot, or nil when idle.
    ///   - effort: Resolved effort block, or nil for payloads predating it.
    public init(
        enabled: Bool = false,
        running: Bool = false,
        documents: Int = 0,
        chunks: Int = 0,
        vectorChunks: Int = 0,
        keywordChunks: Int = 0,
        bytes: Int64 = 0,
        dbFileBytes: Int64 = 0,
        walBytes: Int64 = 0,
        textBytes: Int64 = 0,
        vectorBytes: Int64 = 0,
        ftsBytes: Int64 = 0,
        freeBytes: Int64 = 0,
        contentBytes: Int64 = 0,
        indexAsOf: Date? = nil,
        sources: [IndexSourceStatus] = [],
        lastErrors: [String] = [],
        bySource: [IndexSourceCounts] = [],
        byExtractStatus: [IndexExtractStatusCounts] = [],
        lastRun: IndexLastRunStatus? = nil,
        live: IndexLiveStatus? = nil,
        effort: IndexEffortStatus? = nil
    ) {
        self.enabled = enabled
        self.running = running
        self.documents = documents
        self.chunks = chunks
        self.vectorChunks = vectorChunks
        self.keywordChunks = keywordChunks
        self.bytes = bytes
        self.dbFileBytes = dbFileBytes
        self.walBytes = walBytes
        self.textBytes = textBytes
        self.vectorBytes = vectorBytes
        self.ftsBytes = ftsBytes
        self.freeBytes = freeBytes
        self.contentBytes = contentBytes
        self.indexAsOf = indexAsOf
        self.sources = sources
        self.lastErrors = lastErrors
        self.bySource = bySource
        self.byExtractStatus = byExtractStatus
        self.lastRun = lastRun
        self.live = live
        self.effort = effort
    }

    /// Coding keys for the version-tolerant status contract.
    private enum CodingKeys: String, CodingKey {
        case enabled
        case running
        case documents
        case chunks
        case vectorChunks
        case keywordChunks
        case bytes
        case dbFileBytes
        case walBytes
        case textBytes
        case vectorBytes
        case ftsBytes
        case freeBytes
        case contentBytes
        case indexAsOf
        case sources
        case lastErrors
        case bySource
        case byExtractStatus
        case lastRun
        case live
        case effort
    }

    /// Decodes a status snapshot, defaulting additive size and effort fields
    /// so payloads built against an older engine still decode.
    /// - Parameter decoder: Decoder carrying the snapshot.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        running = try container.decodeIfPresent(Bool.self, forKey: .running) ?? false
        documents = try container.decodeIfPresent(Int.self, forKey: .documents) ?? 0
        chunks = try container.decodeIfPresent(Int.self, forKey: .chunks) ?? 0
        vectorChunks = try container.decodeIfPresent(Int.self, forKey: .vectorChunks) ?? 0
        keywordChunks = try container.decodeIfPresent(Int.self, forKey: .keywordChunks) ?? 0
        bytes = try container.decodeIfPresent(Int64.self, forKey: .bytes) ?? 0
        dbFileBytes = try container.decodeIfPresent(Int64.self, forKey: .dbFileBytes) ?? 0
        walBytes = try container.decodeIfPresent(Int64.self, forKey: .walBytes) ?? 0
        textBytes = try container.decodeIfPresent(Int64.self, forKey: .textBytes) ?? 0
        vectorBytes = try container.decodeIfPresent(Int64.self, forKey: .vectorBytes) ?? 0
        ftsBytes = try container.decodeIfPresent(Int64.self, forKey: .ftsBytes) ?? 0
        freeBytes = try container.decodeIfPresent(Int64.self, forKey: .freeBytes) ?? 0
        contentBytes = try container.decodeIfPresent(Int64.self, forKey: .contentBytes) ?? 0
        indexAsOf = try container.decodeIfPresent(Date.self, forKey: .indexAsOf)
        sources = try container.decodeIfPresent([IndexSourceStatus].self, forKey: .sources) ?? []
        lastErrors = try container.decodeIfPresent([String].self, forKey: .lastErrors) ?? []
        bySource = try container.decodeIfPresent([IndexSourceCounts].self, forKey: .bySource) ?? []
        byExtractStatus = try container.decodeIfPresent([IndexExtractStatusCounts].self, forKey: .byExtractStatus) ?? []
        lastRun = try container.decodeIfPresent(IndexLastRunStatus.self, forKey: .lastRun)
        live = try container.decodeIfPresent(IndexLiveStatus.self, forKey: .live)
        effort = try container.decodeIfPresent(IndexEffortStatus.self, forKey: .effort)
    }

    /// Encodes a status snapshot including the additive size and nested effort.
    /// - Parameter encoder: Encoder receiving the snapshot.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(running, forKey: .running)
        try container.encode(documents, forKey: .documents)
        try container.encode(chunks, forKey: .chunks)
        try container.encode(vectorChunks, forKey: .vectorChunks)
        try container.encode(keywordChunks, forKey: .keywordChunks)
        try container.encode(bytes, forKey: .bytes)
        try container.encode(dbFileBytes, forKey: .dbFileBytes)
        try container.encode(walBytes, forKey: .walBytes)
        try container.encode(textBytes, forKey: .textBytes)
        try container.encode(vectorBytes, forKey: .vectorBytes)
        try container.encode(ftsBytes, forKey: .ftsBytes)
        try container.encode(freeBytes, forKey: .freeBytes)
        try container.encode(contentBytes, forKey: .contentBytes)
        try container.encodeIfPresent(indexAsOf, forKey: .indexAsOf)
        try container.encode(sources, forKey: .sources)
        try container.encode(lastErrors, forKey: .lastErrors)
        try container.encode(bySource, forKey: .bySource)
        try container.encode(byExtractStatus, forKey: .byExtractStatus)
        try container.encodeIfPresent(lastRun, forKey: .lastRun)
        try container.encodeIfPresent(live, forKey: .live)
        try container.encodeIfPresent(effort, forKey: .effort)
    }
}

/// Storage breakdown for `GET /index/storage`.
///
/// Owned by the index routes: carries byte-exact totals plus per-source
/// document, chunk, and byte rows from the slow aggregate pass, so the
/// dashboard merges slow sizes over the fast status snapshot. Every size is
/// non-optional with a zero default so a missing store reports an honest
/// zeroed payload rather than failing, and decoding stays tolerant via
/// `decodeIfPresent` so older dashboards keep decoding.
public struct IndexStorageResponse: Content, Equatable {
    /// Total chunk text bytes held by the index.
    public let bytes: Int64
    /// Total chunk text bytes held by the index.
    public let textBytes: Int64
    /// Total embedding BLOB bytes held by vector chunks.
    public let vectorBytes: Int64
    /// Full-text index bytes, zero when the size probe is unavailable.
    public let ftsBytes: Int64
    /// Unused freelist bytes reclaimable by `POST /index/reclaim`.
    public let freeBytes: Int64
    /// Main SQLite file size in bytes, read from the filesystem.
    public let dbFileBytes: Int64
    /// Write-ahead log size in bytes, zero when checkpointed.
    public let walBytes: Int64
    /// Logical content bytes (`textBytes` plus `vectorBytes`).
    public let contentBytes: Int64
    /// Per-source document/chunk/byte aggregates, one row per origin corpus.
    public let bySource: [IndexSourceCounts]

    /// Creates a storage breakdown snapshot.
    /// - Parameters:
    ///   - bytes: Total chunk text bytes.
    ///   - textBytes: Chunk text bytes.
    ///   - vectorBytes: Embedding bytes.
    ///   - ftsBytes: Full-text index bytes.
    ///   - freeBytes: Freelist bytes.
    ///   - dbFileBytes: Main file size.
    ///   - walBytes: Write-ahead log size.
    ///   - contentBytes: Logical content bytes.
    ///   - bySource: Per-source content aggregates.
    public init(
        bytes: Int64 = 0,
        textBytes: Int64 = 0,
        vectorBytes: Int64 = 0,
        ftsBytes: Int64 = 0,
        freeBytes: Int64 = 0,
        dbFileBytes: Int64 = 0,
        walBytes: Int64 = 0,
        contentBytes: Int64 = 0,
        bySource: [IndexSourceCounts] = []
    ) {
        self.bytes = bytes
        self.textBytes = textBytes
        self.vectorBytes = vectorBytes
        self.ftsBytes = ftsBytes
        self.freeBytes = freeBytes
        self.dbFileBytes = dbFileBytes
        self.walBytes = walBytes
        self.contentBytes = contentBytes
        self.bySource = bySource
    }

    /// Coding keys for the version-tolerant storage contract.
    private enum CodingKeys: String, CodingKey {
        case bytes
        case textBytes
        case vectorBytes
        case ftsBytes
        case freeBytes
        case dbFileBytes
        case walBytes
        case contentBytes
        case bySource
    }

    /// Decodes a storage snapshot, defaulting absent sizes and sources so
    /// payloads built against an older engine still decode.
    /// - Parameter decoder: Decoder carrying the snapshot.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bytes = try container.decodeIfPresent(Int64.self, forKey: .bytes) ?? 0
        textBytes = try container.decodeIfPresent(Int64.self, forKey: .textBytes) ?? 0
        vectorBytes = try container.decodeIfPresent(Int64.self, forKey: .vectorBytes) ?? 0
        ftsBytes = try container.decodeIfPresent(Int64.self, forKey: .ftsBytes) ?? 0
        freeBytes = try container.decodeIfPresent(Int64.self, forKey: .freeBytes) ?? 0
        dbFileBytes = try container.decodeIfPresent(Int64.self, forKey: .dbFileBytes) ?? 0
        walBytes = try container.decodeIfPresent(Int64.self, forKey: .walBytes) ?? 0
        contentBytes = try container.decodeIfPresent(Int64.self, forKey: .contentBytes) ?? 0
        bySource = try container.decodeIfPresent([IndexSourceCounts].self, forKey: .bySource) ?? []
    }

    /// Encodes a storage snapshot including every size and source row.
    /// - Parameter encoder: Encoder receiving the snapshot.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bytes, forKey: .bytes)
        try container.encode(textBytes, forKey: .textBytes)
        try container.encode(vectorBytes, forKey: .vectorBytes)
        try container.encode(ftsBytes, forKey: .ftsBytes)
        try container.encode(freeBytes, forKey: .freeBytes)
        try container.encode(dbFileBytes, forKey: .dbFileBytes)
        try container.encode(walBytes, forKey: .walBytes)
        try container.encode(contentBytes, forKey: .contentBytes)
        try container.encode(bySource, forKey: .bySource)
    }
}

/// Builds the `/index/status` shape from engine policy, aggregate stats, live
/// run state, and recent failures.
///
/// Kept as a free function so the shape has one definition independent of the
/// transport: the route only gathers inputs, and callers without a document
/// store or coordinator report an honest empty/stopped snapshot instead of
/// failing. The `live` snapshot is additive: existing callers omit it and
/// report an idle strip, while the route passes the coordinator's live totals
/// through when a run is in flight. Fast stats flow through the existing
/// `stats` parameter with true counts, watermark, and file sizes while slow
/// size legs stay nil or zero; sizes prefer the optional `storage` breakdown
/// when warm and fall back to `stats` file sizes when cold, so a cold poll
/// reports pending zeros for slow legs instead of failing. Effort resolves
/// from the stored preset on this machine so the dashboard renders workers
/// without a second fetch.
///
/// - Parameters:
///   - config: Active index policy driving enablement and effort.
///   - stats: Fast or slow aggregate stats, or nil when no store is wired.
///   - running: Whether a run is in flight.
///   - lastErrors: Recent run failures, newest first.
///   - lastRun: Latest run outcome, or nil when no run has been recorded.
///   - live: Live in-flight snapshot, or nil when idle.
///   - storage: Cached slow breakdown when fresh, or nil for pending slow legs.
/// - Returns: The status snapshot.
func makeIndexStatusResponse(
    config: IndexConfig,
    stats: IndexStats?,
    running: Bool,
    lastErrors: [String],
    lastRun: IndexLastRunStatus? = nil,
    live: IndexLiveStatus? = nil,
    storage: IndexStorageBreakdown? = nil
) -> IndexStatusResponse {
    let sources = [
        IndexSourceStatus(kind: IndexSourceKind.files.rawValue, enabled: config.enabled && config.files),
        IndexSourceStatus(kind: IndexSourceKind.mail.rawValue, enabled: config.enabled && config.mail),
        IndexSourceStatus(kind: IndexSourceKind.messages.rawValue, enabled: config.enabled && config.messages)
    ]
    let bySource = (stats?.bySource ?? []).map { row in
        IndexSourceCounts(kind: row.source.rawValue, documents: row.documents, chunks: row.chunks, bytes: row.bytes)
    }
    let byExtractStatus = (stats?.byExtractStatus ?? []).map { row in
        IndexExtractStatusCounts(status: row.status.rawValue, documents: row.documents)
    }
    // Slow legs prefer the cached breakdown when warm; cold polls fall back
    // to fast file sizes for the on-disk pair and pending zeros for the rest,
    // so fast counts stay visible while slow bytes merge in later.
    let activeProcessors = max(1, ProcessInfo.processInfo.activeProcessorCount)
    let effort = IndexEffortStatus(
        preset: config.effort,
        resolvedWorkers: config.resolvedWorkerCount(cores: activeProcessors),
        activeProcessors: activeProcessors
    )
    return IndexStatusResponse(
        enabled: config.enabled,
        running: running,
        documents: stats?.documents ?? 0,
        chunks: stats?.chunks ?? 0,
        vectorChunks: stats?.vectorChunks ?? 0,
        keywordChunks: stats?.keywordChunks ?? 0,
        bytes: storage?.textBytes ?? stats?.bytes ?? 0,
        dbFileBytes: storage?.dbFileBytes ?? stats?.dbFileBytes ?? 0,
        walBytes: storage?.walBytes ?? stats?.walBytes ?? 0,
        textBytes: storage?.textBytes ?? stats?.textBytes ?? 0,
        vectorBytes: storage?.vectorBytes ?? stats?.vectorBytes ?? 0,
        ftsBytes: storage?.ftsBytes ?? stats?.ftsBytes ?? 0,
        freeBytes: storage?.freeBytes ?? stats?.freeBytes ?? 0,
        contentBytes: storage?.contentBytes ?? stats?.contentBytes ?? 0,
        indexAsOf: stats?.indexAsOf,
        sources: sources,
        lastErrors: lastErrors,
        bySource: bySource,
        byExtractStatus: byExtractStatus,
        lastRun: lastRun,
        live: live,
        effort: effort
    )
}

/// Outcome of `POST /index/run`.
public struct IndexRunResponse: Content, Equatable {
    /// Per-run session identifier used to tag the run log row.
    public let sessionID: UUID
    /// What caused the run (`"nightly"`, `"catchUp"`, or `"onDemand"`).
    public let trigger: String
    /// Terminal (or in-flight) state token.
    public let status: String
    /// Documents written across every source.
    public let documentsIndexed: Int
    /// Chunks written carrying an embedding.
    public let vectorChunks: Int
    /// Chunks written without an embedding.
    public let keywordChunks: Int
    /// Items examined.
    public let scanned: Int
    /// Items deliberately skipped.
    public let skipped: Int
    /// Items that could not be processed.
    public let errors: Int
    /// Documents retired (deleted as unseen) across every source.
    public let retiredCount: Int
    /// Documents where the vector cap left tail chunks keyword-only.
    public let truncatedCount: Int
    /// Non-fatal problems, without any content or secret.
    public let warnings: [String]
    /// Instant the run began.
    public let startedAt: Date
    /// Instant the run finished.
    public let finishedAt: Date
    /// Recorded watermark on success, or nil when the run did not succeed.
    public let indexAsOf: Date?
    /// Why the run did not execute, when it was skipped.
    public let skippedReason: String?

    /// Coding keys for the version-tolerant run contract.
    private enum CodingKeys: String, CodingKey {
        case sessionID
        case trigger
        case status
        case documentsIndexed
        case vectorChunks
        case keywordChunks
        case scanned
        case skipped
        case errors
        case retiredCount
        case retired
        case truncatedCount
        case truncated
        case warnings
        case startedAt
        case finishedAt
        case indexAsOf
        case skippedReason
    }

    /// Maps a coordinator summary onto the wire shape.
    /// - Parameter summary: Completed run summary.
    public init(_ summary: IndexRunSummary) {
        self.sessionID = summary.sessionID
        self.trigger = summary.trigger.rawValue
        self.status = summary.status.rawValue
        self.documentsIndexed = summary.documentsIndexed
        self.vectorChunks = summary.vectorChunks
        self.keywordChunks = summary.keywordChunks
        self.scanned = summary.scanned
        self.skipped = summary.skipped
        self.errors = summary.errors
        self.retiredCount = summary.retired
        self.truncatedCount = summary.truncated
        self.warnings = summary.warnings
        self.startedAt = summary.startedAt
        self.finishedAt = summary.finishedAt
        self.indexAsOf = summary.indexAsOf
        self.skippedReason = summary.skippedReason
    }

    /// Decodes a run response, defaulting retired and truncated counts to zero
    /// so payloads built against an older engine still decode. Accepts the
    /// `retired`/`truncated` aliases; the canonical keys win when both are
    /// present.
    /// - Parameter decoder: Decoder carrying the response.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(UUID.self, forKey: .sessionID)
        trigger = try container.decode(String.self, forKey: .trigger)
        status = try container.decode(String.self, forKey: .status)
        documentsIndexed = try container.decode(Int.self, forKey: .documentsIndexed)
        vectorChunks = try container.decode(Int.self, forKey: .vectorChunks)
        keywordChunks = try container.decode(Int.self, forKey: .keywordChunks)
        scanned = try container.decode(Int.self, forKey: .scanned)
        skipped = try container.decode(Int.self, forKey: .skipped)
        errors = try container.decode(Int.self, forKey: .errors)
        let canonicalRetired = try container.decodeIfPresent(Int.self, forKey: .retiredCount)
        let aliasRetired = try container.decodeIfPresent(Int.self, forKey: .retired)
        retiredCount = canonicalRetired ?? aliasRetired ?? 0
        let canonicalTruncated = try container.decodeIfPresent(Int.self, forKey: .truncatedCount)
        let aliasTruncated = try container.decodeIfPresent(Int.self, forKey: .truncated)
        truncatedCount = canonicalTruncated ?? aliasTruncated ?? 0
        warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        finishedAt = try container.decode(Date.self, forKey: .finishedAt)
        indexAsOf = try container.decodeIfPresent(Date.self, forKey: .indexAsOf)
        skippedReason = try container.decodeIfPresent(String.self, forKey: .skippedReason)
    }

    /// Encodes a run response on the canonical keys so current dashboards
    /// render from one fetch; the aliases are not re-emitted.
    /// - Parameter encoder: Encoder receiving the response.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(trigger, forKey: .trigger)
        try container.encode(status, forKey: .status)
        try container.encode(documentsIndexed, forKey: .documentsIndexed)
        try container.encode(vectorChunks, forKey: .vectorChunks)
        try container.encode(keywordChunks, forKey: .keywordChunks)
        try container.encode(scanned, forKey: .scanned)
        try container.encode(skipped, forKey: .skipped)
        try container.encode(errors, forKey: .errors)
        try container.encode(retiredCount, forKey: .retiredCount)
        try container.encode(truncatedCount, forKey: .truncatedCount)
        try container.encode(warnings, forKey: .warnings)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(finishedAt, forKey: .finishedAt)
        try container.encodeIfPresent(indexAsOf, forKey: .indexAsOf)
        try container.encodeIfPresent(skippedReason, forKey: .skippedReason)
    }
}

/// Outcome of `POST /index/cancel`.
public struct IndexCancelResponse: Content, Equatable {
    /// Whether a run was in flight when cancellation was requested.
    public let cancelled: Bool

    /// Creates a cancellation response.
    /// - Parameter cancelled: Whether a run was in flight.
    public init(cancelled: Bool) {
        self.cancelled = cancelled
    }
}

/// Request body for `POST /index/prune`.
public struct IndexPruneRequest: Content, Equatable {
    /// Cutoff instant; documents indexed before it are removed. Nil is rejected
    /// with 400; the cutoff is required.
    public let before: Date?

    /// Creates a prune request with the required cutoff.
    /// - Parameter before: Required cutoff instant.
    public init(before: Date) {
        self.before = before
    }
}

/// Outcome of `POST /index/prune`.
public struct IndexPruneResponse: Content, Equatable {
    /// Number of documents removed.
    public let removed: Int
    /// Cutoff instant that was applied.
    public let before: Date

    /// Creates a prune response.
    /// - Parameters:
    ///   - removed: Documents removed.
    ///   - before: Applied cutoff.
    public init(removed: Int, before: Date) {
        self.removed = removed
        self.before = before
    }
}

/// Outcome of `POST /index/reset`.
public struct IndexResetResponse: Content, Equatable {
    /// Always true on success; the route fails instead of claiming a partial clear.
    public let reset: Bool

    /// Creates a reset response.
    /// - Parameter reset: Whether the clear completed.
    public init(reset: Bool) {
        self.reset = reset
    }
}

/// Outcome of `POST /index/reclaim`.
///
/// Carries the on-disk total before and after `VACUUM` plus the reclaimed
/// delta so the dashboard renders the saved bytes without recomputing them.
public struct IndexReclaimResponse: Content, Equatable {
    /// On-disk total before `VACUUM`, in bytes.
    public let beforeBytes: Int64
    /// On-disk total after `VACUUM`, in bytes.
    public let afterBytes: Int64
    /// Bytes reclaimed (`beforeBytes` minus `afterBytes`, floored at zero).
    public let reclaimedBytes: Int64

    /// Creates a reclaim response.
    /// - Parameters:
    ///   - beforeBytes: On-disk total before.
    ///   - afterBytes: On-disk total after.
    ///   - reclaimedBytes: Bytes reclaimed.
    public init(beforeBytes: Int64, afterBytes: Int64, reclaimedBytes: Int64) {
        self.beforeBytes = beforeBytes
        self.afterBytes = afterBytes
        self.reclaimedBytes = reclaimedBytes
    }

    /// Maps a store reclaim outcome onto the wire shape.
    /// - Parameter result: Store reclaim outcome.
    public init(_ result: IndexReclaimResult) {
        self.beforeBytes = result.beforeBytes
        self.afterBytes = result.afterBytes
        self.reclaimedBytes = result.reclaimedBytes
    }
}

/// Partial index patch for `PUT /settings`.
///
/// Every field is optional so a request carrying only one key leaves the rest
/// of the stored `[index]` section untouched instead of resetting it. Covers the
/// same field set as the full ``IndexConfig`` snapshot, so a caller holding a
/// complete policy can build the patch through `init(_:)` and reuse the merge
/// path without hand-mapping fields.
public struct IndexSettingsUpdate: Content, Equatable {
    /// Whether the background indexer runs at all.
    public var enabled: Bool?
    /// Whether local files are indexed.
    public var files: Bool?
    /// Whether mail is indexed.
    public var mail: Bool?
    /// Whether Apple Messages are indexed.
    public var messages: Bool?
    /// Root directories scanned for files.
    public var roots: [String]?
    /// Glob patterns skipped during a file scan.
    public var exclude: [String]?
    /// Largest file the indexer will read, in megabytes.
    public var maxFileMB: Int?
    /// How far back mail is vectorized.
    public var mailVectorWindow: String?
    /// Policy for iCloud files whose bytes are evicted.
    public var iCloudEvicted: String?
    /// Whether image files are described with the configured LLM.
    public var describeImagesWithLLM: Bool?
    /// Maximum items processed per nightly run; `0` means unlimited.
    public var nightlyBudget: Int?
    /// SQLite path for the index database.
    public var dbPath: String?
    /// Indexing effort preset (`light`, `balanced`, `performance`, `custom`).
    public var effort: String?
    /// Explicit worker count for the `custom` preset; `0` means derive.
    public var workers: Int?
    /// Whether indexing backs off under thermal pressure.
    public var thermalBackoff: Bool?
    /// Whether indexing pauses while on battery power.
    public var pauseOnBattery: Bool?
    /// Maximum vector chunks stored per document, bounding per-document
    /// embedding work; chunks beyond the cap stay keyword-only.
    public var maxVectorChunksPerDocument: Int?
    /// Trash-class mailbox denylist skipped without dialing.
    public var mailboxDeny: [String]?
    /// Directory and file names the walker always skips, even when absent from
    /// `exclude`. Read-only: populated from the walker's prune list when a patch
    /// is built from a snapshot and ignored when a patch is applied, so the
    /// dashboard copy cannot drift. The `[files]` deny patterns stay out of this
    /// list and are described generically in the UI.
    public var alwaysSkipped: [String]?

    /// Creates a partial index patch.
    /// - Parameters:
    ///   - enabled: Whether the indexer runs.
    ///   - files: Files source toggle.
    ///   - mail: Mail source toggle.
    ///   - messages: Messages source toggle.
    ///   - roots: File roots.
    ///   - exclude: File exclude patterns.
    ///   - maxFileMB: Per-file size cap in megabytes.
    ///   - mailVectorWindow: Mail vectorization window.
    ///   - iCloudEvicted: Evicted-iCloud-file policy.
    ///   - describeImagesWithLLM: Image description toggle.
    ///   - nightlyBudget: Nightly item budget.
    ///   - dbPath: Index database path.
    ///   - effort: Effort preset.
    ///   - workers: Explicit worker count for `custom`.
    ///   - thermalBackoff: Thermal backoff toggle.
    ///   - pauseOnBattery: Pause-on-battery toggle.
    ///   - maxVectorChunksPerDocument: Per-document vector chunk cap.
    ///   - mailboxDeny: Trash-class mailbox denylist.
    ///   - alwaysSkipped: Read-only walker prune names, ignored on apply.
    public init(
        enabled: Bool? = nil,
        files: Bool? = nil,
        mail: Bool? = nil,
        messages: Bool? = nil,
        roots: [String]? = nil,
        exclude: [String]? = nil,
        maxFileMB: Int? = nil,
        mailVectorWindow: String? = nil,
        iCloudEvicted: String? = nil,
        describeImagesWithLLM: Bool? = nil,
        nightlyBudget: Int? = nil,
        dbPath: String? = nil,
        effort: String? = nil,
        workers: Int? = nil,
        thermalBackoff: Bool? = nil,
        pauseOnBattery: Bool? = nil,
        maxVectorChunksPerDocument: Int? = nil,
        mailboxDeny: [String]? = nil,
        alwaysSkipped: [String]? = nil
    ) {
        self.enabled = enabled
        self.files = files
        self.mail = mail
        self.messages = messages
        self.roots = roots
        self.exclude = exclude
        self.maxFileMB = maxFileMB
        self.mailVectorWindow = mailVectorWindow
        self.iCloudEvicted = iCloudEvicted
        self.describeImagesWithLLM = describeImagesWithLLM
        self.nightlyBudget = nightlyBudget
        self.dbPath = dbPath
        self.effort = effort
        self.workers = workers
        self.thermalBackoff = thermalBackoff
        self.pauseOnBattery = pauseOnBattery
        self.maxVectorChunksPerDocument = maxVectorChunksPerDocument
        self.mailboxDeny = mailboxDeny
        self.alwaysSkipped = alwaysSkipped
    }

    /// Populates a patch from a full snapshot so programmatic callers holding a
    /// complete `IndexConfig` reuse the same merge path.
    /// - Parameter config: Complete index policy.
    public init(_ config: IndexConfig) {
        self.enabled = config.enabled
        self.files = config.files
        self.mail = config.mail
        self.messages = config.messages
        self.roots = config.roots
        self.exclude = config.exclude
        self.maxFileMB = config.maxFileMB
        self.mailVectorWindow = config.mailVectorWindow
        self.iCloudEvicted = config.iCloudEvicted
        self.describeImagesWithLLM = config.describeImagesWithLLM
        self.nightlyBudget = config.nightlyBudget
        self.dbPath = config.dbPath
        self.effort = config.effort
        self.workers = config.workers
        self.thermalBackoff = config.thermalBackoff
        self.pauseOnBattery = config.pauseOnBattery
        self.maxVectorChunksPerDocument = config.maxVectorChunksPerDocument
        self.mailboxDeny = config.mailboxDeny
        self.alwaysSkipped = indexAlwaysSkippedPatterns()
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case files
        case mail
        case messages
        case roots
        case exclude
        case maxFileMB = "max_file_mb"
        case mailVectorWindow = "mail_vector_window"
        case iCloudEvicted = "icloud_evicted"
        case describeImagesWithLLM = "describe_images_with_llm"
        case nightlyBudget = "nightly_budget"
        case dbPath = "db_path"
        case effort
        case workers
        case thermalBackoff = "thermal_backoff"
        case pauseOnBattery = "pause_on_battery"
        case maxVectorChunksPerDocument = "max_vector_chunks_per_document"
        case mailboxDeny = "mailbox_deny"
        case alwaysSkipped = "always_skipped"
    }

    /// Decodes a partial patch.
    /// - Parameter decoder: Decoder carrying the patch.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
        files = try container.decodeIfPresent(Bool.self, forKey: .files)
        mail = try container.decodeIfPresent(Bool.self, forKey: .mail)
        messages = try container.decodeIfPresent(Bool.self, forKey: .messages)
        roots = try container.decodeIfPresent([String].self, forKey: .roots)
        exclude = try container.decodeIfPresent([String].self, forKey: .exclude)
        maxFileMB = try container.decodeIfPresent(Int.self, forKey: .maxFileMB)
        mailVectorWindow = try container.decodeIfPresent(String.self, forKey: .mailVectorWindow)
        iCloudEvicted = try container.decodeIfPresent(String.self, forKey: .iCloudEvicted)
        describeImagesWithLLM = try container.decodeIfPresent(Bool.self, forKey: .describeImagesWithLLM)
        nightlyBudget = try container.decodeIfPresent(Int.self, forKey: .nightlyBudget)
        dbPath = try container.decodeIfPresent(String.self, forKey: .dbPath)
        effort = try container.decodeIfPresent(String.self, forKey: .effort)
        workers = try container.decodeIfPresent(Int.self, forKey: .workers)
        thermalBackoff = try container.decodeIfPresent(Bool.self, forKey: .thermalBackoff)
        pauseOnBattery = try container.decodeIfPresent(Bool.self, forKey: .pauseOnBattery)
        maxVectorChunksPerDocument = try container.decodeIfPresent(Int.self, forKey: .maxVectorChunksPerDocument)
        mailboxDeny = try container.decodeIfPresent([String].self, forKey: .mailboxDeny)
        alwaysSkipped = try container.decodeIfPresent([String].self, forKey: .alwaysSkipped)
    }

    /// Encodes a partial patch using the canonical `workers` key.
    /// - Parameter encoder: Encoder receiving the patch.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(enabled, forKey: .enabled)
        try container.encodeIfPresent(files, forKey: .files)
        try container.encodeIfPresent(mail, forKey: .mail)
        try container.encodeIfPresent(messages, forKey: .messages)
        try container.encodeIfPresent(roots, forKey: .roots)
        try container.encodeIfPresent(exclude, forKey: .exclude)
        try container.encodeIfPresent(maxFileMB, forKey: .maxFileMB)
        try container.encodeIfPresent(mailVectorWindow, forKey: .mailVectorWindow)
        try container.encodeIfPresent(iCloudEvicted, forKey: .iCloudEvicted)
        try container.encodeIfPresent(describeImagesWithLLM, forKey: .describeImagesWithLLM)
        try container.encodeIfPresent(nightlyBudget, forKey: .nightlyBudget)
        try container.encodeIfPresent(dbPath, forKey: .dbPath)
        try container.encodeIfPresent(effort, forKey: .effort)
        try container.encodeIfPresent(workers, forKey: .workers)
        try container.encodeIfPresent(thermalBackoff, forKey: .thermalBackoff)
        try container.encodeIfPresent(pauseOnBattery, forKey: .pauseOnBattery)
        try container.encodeIfPresent(maxVectorChunksPerDocument, forKey: .maxVectorChunksPerDocument)
        try container.encodeIfPresent(mailboxDeny, forKey: .mailboxDeny)
        try container.encodeIfPresent(alwaysSkipped, forKey: .alwaysSkipped)
    }
}

extension UpdateSettingsRequest {
    /// Builds a request from a full index snapshot, routing through the same
    /// merge path so snapshot callers keep working without hand-mapping fields.
    /// - Parameter index: Complete index policy.
    public init(index: IndexConfig) {
        self.init(index: IndexSettingsUpdate(index))
    }
}

// MARK: - Index Route Paths

extension ServerPaths {
    /// Local document index group serving status and control.
    public static let index = "index"
    /// Index status subpath under `/index`.
    public static let indexStatus = "status"
    /// Index on-demand run subpath under `/index`.
    public static let indexRun = "run"
    /// Index cancellation subpath under `/index`.
    public static let indexCancel = "cancel"
    /// Index prune subpath under `/index`.
    public static let indexPrune = "prune"
    /// Index reset subpath under `/index`.
    public static let indexReset = "reset"
    /// Index reclaim subpath under `/index`.
    public static let indexReclaim = "reclaim"
    /// Index storage subpath under `/index`.
    public static let indexStorage = "storage"
}

// MARK: - Index Settings Merge

extension UpdateSettingsRequest {
    /// Merges a partial index patch onto the stored policy, preserving every
    /// field the request omits. A nil patch is a no-op, so a dashboard edit to
    /// one knob never resets the rest of the `[index]` section. Values land
    /// verbatim because range and closed-set checks stay single-sourced in
    /// `RuneWeaverConfig.validate`, which runs before the merged config persists.
    ///
    /// Internal so the shared settings `apply(to:)` keeps one merge path while
    /// the index-specific logic lives beside its DTOs.
    func applyIndex(to index: inout IndexConfig) {
        guard let update = self.index else { return }
        if let enabled = update.enabled {
            index.enabled = enabled
        }
        if let files = update.files {
            index.files = files
        }
        if let mail = update.mail {
            index.mail = mail
        }
        if let messages = update.messages {
            index.messages = messages
        }
        if let roots = update.roots {
            index.roots = roots
        }
        if let exclude = update.exclude {
            index.exclude = exclude
        }
        if let maxFileMB = update.maxFileMB {
            index.maxFileMB = maxFileMB
        }
        if let mailVectorWindow = update.mailVectorWindow {
            index.mailVectorWindow = mailVectorWindow
        }
        if let iCloudEvicted = update.iCloudEvicted {
            index.iCloudEvicted = iCloudEvicted
        }
        if let describeImagesWithLLM = update.describeImagesWithLLM {
            index.describeImagesWithLLM = describeImagesWithLLM
        }
        if let nightlyBudget = update.nightlyBudget {
            index.nightlyBudget = nightlyBudget
        }
        if let dbPath = update.dbPath {
            index.dbPath = dbPath
        }
        if let effort = update.effort {
            index.effort = effort
        }
        if let workers = update.workers {
            index.workers = workers
        }
        if let thermalBackoff = update.thermalBackoff {
            index.thermalBackoff = thermalBackoff
        }
        if let pauseOnBattery = update.pauseOnBattery {
            index.pauseOnBattery = pauseOnBattery
        }
        if let maxVectorChunksPerDocument = update.maxVectorChunksPerDocument {
            index.maxVectorChunksPerDocument = maxVectorChunksPerDocument
        }
        if let mailboxDeny = update.mailboxDeny {
            index.mailboxDeny = mailboxDeny
        }
        // Read-only: `always_skipped` is never merged so a client echo cannot
        // drift the stored policy; the walker list stays single-sourced.
    }
}

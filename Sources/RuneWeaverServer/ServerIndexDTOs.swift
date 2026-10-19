// Rune Weaver Server — Local index status, control, and settings DTOs.

import Foundation
import RuneWeaverCore
import Vapor

/// One source's enablement row on `GET /index/status`.
public struct IndexSourceStatus: Content, Equatable {
    /// Source kind (`"files"`, `"mail"`, `"messages"`, `"calendars"`, or `"reminders"`).
    public let kind: String
    /// Whether the source is enabled under the active policy.
    public let enabled: Bool
    /// Access posture observed with silent reads at status build time (`"granted"`, `"denied"`,
    /// `"notDetermined"`, or `"unavailable"`).
    public let access: String

    /// Creates a source enablement row. kind: Source kind token.
    public init(kind: String, enabled: Bool, access: String = "granted") {
        self.kind = kind
        self.enabled = enabled
        self.access = access
    }

    /// Coding keys for the version-tolerant source contract.
    private enum CodingKeys: String, CodingKey {
        case kind
        case enabled
        case access
    }

    /// Decodes a source row, defaulting absent access to granted so payloads
    /// built against an older engine still decode.
    /// - Parameter decoder: Decoder carrying the row.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(String.self, forKey: .kind)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        access = try container.decodeIfPresent(String.self, forKey: .access) ?? "granted"
    }

    /// Encodes a source row including its access posture.
    /// - Parameter encoder: Encoder receiving the row.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(access, forKey: .access)
    }
}

/// Per-source content counts on `GET /index/status`.
public struct IndexSourceCounts: Content, Equatable {
    /// Source kind (`"files"`, `"mail"`, `"messages"`, `"calendars"`, or `"reminders"`).
    public let kind: String
    /// Number of indexed documents from this source.
    public let documents: Int
    /// Number of stored chunks belonging to this source.
    public let chunks: Int
    /// Total chunk text bytes belonging to this source from the persisted
    /// single row; zero only when the row is genuinely absent (fail-closed),
    /// never a mid-run pending sentinel.
    public let bytes: Int64

    /// Creates a per-source content row. kind: Source kind token.
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

    /// Creates an extraction-outcome row. status: Extraction outcome token.
    public init(status: String, documents: Int = 0) {
        self.status = status
        self.documents = documents
    }
}

/// Per-source outcome on run-status payloads.
public struct IndexSourceRunOutcome: Content, Equatable {
    /// Source kind (`"files"`, `"mail"`, `"messages"`, `"calendars"`, or `"reminders"`).
    public let kind: String
    /// Whether the source stage ran.
    public let didRun: Bool
    /// Items examined by the source.
    public let scanned: Int
    /// Documents written by the source.
    public let indexed: Int
    /// Why the source did not run, when it was skipped.
    public let skippedReason: String?

    /// Creates a per-source outcome row. kind: Source kind token.
    public init(
        kind: String,
        didRun: Bool = true,
        scanned: Int = 0,
        indexed: Int = 0,
        skippedReason: String? = nil
    ) {
        self.kind = kind
        self.didRun = didRun
        self.scanned = scanned
        self.indexed = indexed
        self.skippedReason = skippedReason
    }

    /// Maps a coordinator report onto the wire shape.
    /// - Parameter report: Stage contribution to expose.
    public init(_ report: IndexSourceRunReport) {
        self.kind = report.kind.rawValue
        self.didRun = report.didRun
        self.scanned = report.scanned
        self.indexed = report.indexed
        self.skippedReason = report.skippedReason
    }

    /// Coding keys for the outcome contract.
    private enum CodingKeys: String, CodingKey {
        case kind
        case didRun
        case scanned
        case indexed
        case skippedReason
    }

    /// Decodes an outcome row, defaulting absent counts so older engines still decode.
    /// - Parameter decoder: Decoder carrying the row.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(String.self, forKey: .kind)
        skippedReason = try container.decodeIfPresent(String.self, forKey: .skippedReason)
        if let resolved = try container.decodeIfPresent(Bool.self, forKey: .didRun) {
            didRun = resolved
        } else {
            didRun = skippedReason == nil
        }
        scanned = try container.decodeIfPresent(Int.self, forKey: .scanned) ?? 0
        indexed = try container.decodeIfPresent(Int.self, forKey: .indexed) ?? 0
    }

    /// Encodes an outcome row on the canonical keys.
    /// - Parameter encoder: Encoder receiving the row.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(didRun, forKey: .didRun)
        try container.encode(scanned, forKey: .scanned)
        try container.encode(indexed, forKey: .indexed)
        try container.encodeIfPresent(skippedReason, forKey: .skippedReason)
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
    /// Per-source outcomes in canonical run order. Optional for back-compat;
    /// absent degrades to no per-source notes instead of failing.
    public let sources: [IndexSourceRunOutcome]?

    /// Creates a last-run row. status: Run state token.
    public init(
        status: String,
        indexed: Int? = nil,
        scanned: Int? = nil,
        errors: Int? = nil,
        finishedAt: Date? = nil,
        trigger: String? = nil,
        skippedReason: String? = nil,
        retiredCount: Int? = nil,
        truncatedCount: Int? = nil,
        sources: [IndexSourceRunOutcome]? = nil
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
        self.sources = sources
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
        case sources
    }

    /// Decodes a last-run row, defaulting absent counts and the skip reason to nil so payloads
    /// built against an older engine still decode.
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
        sources = try container.decodeIfPresent([IndexSourceRunOutcome].self, forKey: .sources)
    }

    /// Encodes a last-run row, omitting absent counts and the skip reason. retired and truncated
    /// counts ride the canonical keys so current dashboards render from one fetch; the aliases are
    /// not re-emitted.
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
        try container.encodeIfPresent(sources, forKey: .sources)
    }
}

/// Live per-source progress row on `GET /index/status`.
public struct IndexLiveSourceDTO: Content, Equatable {
    /// Canonical source identifier (`"files"`, `"mail"`, `"messages"`, `"calendars"`, `"reminders"`).
    public let kind: String
    /// Execution state (`"running"` or `"completed"`).
    public let state: String
    /// Items examined so far by this source.
    public let scanned: Int
    /// Documents indexed so far by this source.
    public let indexed: Int
    /// Relative display path or identifier of the latest item in this source.
    public let current: String?

    /// Creates a live source row.
    public init(kind: String, state: String, scanned: Int = 0, indexed: Int = 0, current: String? = nil) {
        self.kind = kind
        self.state = state
        self.scanned = scanned
        self.indexed = indexed
        self.current = current
    }

    /// Maps a coordinator live source progress snapshot onto the wire shape.
    public init(_ source: IndexLiveSourceProgress) {
        self.kind = source.kind.rawValue
        self.state = source.state
        self.scanned = source.scanned
        self.indexed = source.indexed
        self.current = source.current
    }
}

extension IndexQueueLaneProgress: Content {}

/// Live in-flight index run snapshot on `GET /index/status`, derived from the
/// coordinator's `liveTotals`. Null when idle so polling surfaces unmount the
/// live strip without persisting any post-run summary.
public struct IndexLiveStatus: Content, Equatable {
    /// What caused the run (`"nightly"`, `"catchUp"`, or `"onDemand"`).
    public let trigger: String
    /// Active phase (`"discovering"`, `"extracting"`, `"embedding"`, `"committing"`).
    public let phase: String
    /// Active source stage (`"files"`, `"mail"`, `"messages"`, `"calendars"`, `"reminders"`), or nil.
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
    /// Chunks written carrying an embedding so far in this run.
    public let vectorChunks: Int?
    /// Chunks written without an embedding so far in this run.
    public let keywordChunks: Int?
    /// Per-source live progress across active and completed stages in this run.
    public let sources: [IndexLiveSourceDTO]?
    /// Per-lane modality queue progress emitted by the files indexer.
    public let queues: [IndexQueueLaneProgress]?

    /// Creates a live snapshot row. trigger: What caused the run.
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
        current: String? = nil,
        vectorChunks: Int? = nil,
        keywordChunks: Int? = nil,
        sources: [IndexLiveSourceDTO]? = nil,
        queues: [IndexQueueLaneProgress]? = nil
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
        self.vectorChunks = vectorChunks
        self.keywordChunks = keywordChunks
        self.sources = sources
        self.queues = queues
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
        self.vectorChunks = totals.vectorChunks
        self.keywordChunks = totals.keywordChunks
        self.sources = totals.sources.isEmpty ? nil : totals.sources.map(IndexLiveSourceDTO.init)
        self.queues = totals.queues.isEmpty ? nil : totals.queues
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

    /// Creates an effort row. preset: Stored effort preset.
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

    /// Creates an index status snapshot. enabled: Whether the background indexer
    /// runs at all.
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

    /// Creates a storage breakdown snapshot. bytes: Total chunk text bytes.
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

/// Builds the `/index/status` shape from engine policy, aggregate stats, live run state, and recent
/// failures.
func makeIndexStatusResponse(
    config: IndexConfig,
    stats: IndexStats?,
    running: Bool,
    lastErrors: [String],
    lastRun: IndexLastRunStatus? = nil,
    live: IndexLiveStatus? = nil,
    storage: IndexStorageBreakdown? = nil,
    calendarAccess: String = "granted",
    remindersAccess: String = "granted",
    messagesAccess: String = "granted"
) -> IndexStatusResponse {
    let sources = [
        IndexSourceStatus(kind: IndexSourceKind.files.rawValue, enabled: IndexSourceKind.files.isEnabled(in: config), access: "granted"),
        IndexSourceStatus(kind: IndexSourceKind.mail.rawValue, enabled: IndexSourceKind.mail.isEnabled(in: config), access: "granted"),
        IndexSourceStatus(kind: IndexSourceKind.messages.rawValue, enabled: IndexSourceKind.messages.isEnabled(in: config), access: messagesAccess),
        IndexSourceStatus(kind: IndexSourceKind.calendars.rawValue, enabled: IndexSourceKind.calendars.isEnabled(in: config), access: calendarAccess),
        IndexSourceStatus(kind: IndexSourceKind.reminders.rawValue, enabled: IndexSourceKind.reminders.isEnabled(in: config), access: remindersAccess)
    ]
    let bySource = (stats?.bySource ?? []).map { row in
        IndexSourceCounts(kind: row.source.rawValue, documents: row.documents, chunks: row.chunks, bytes: row.bytes)
    }
    let byExtractStatus = (stats?.byExtractStatus ?? []).map { row in
        IndexExtractStatusCounts(status: row.status.rawValue, documents: row.documents)
    }
    // Slow legs prefer the persisted breakdown and fall back to the persisted
    // stats true sizes, so every poll serves single-row reads forever with no
    // TTL gate and no pending-zero cold; only an absent row renders zeros.
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

/// Partial index patch for `PUT /settings`. Every field is optional so a request carrying only one
/// key leaves the rest of the stored `[index]` section untouched instead of resetting it.
public struct IndexSettingsUpdate: Content, Equatable {
    /// Whether the background indexer runs at all.
    public var enabled: Bool?
    /// Whether local files are indexed.
    public var files: Bool?
    /// Whether mail is indexed.
    public var mail: Bool?
    /// Whether Apple Messages are indexed.
    public var messages: Bool?
    /// Whether calendar events are indexed.
    public var calendars: Bool?
    /// Whether reminders are indexed.
    public var reminders: Bool?
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
    /// Directory and file names the walker always skips, even when absent from `exclude`.
    public var alwaysSkipped: [String]?

    /// Creates a partial index patch. enabled: Whether the indexer runs.
    public init(
        enabled: Bool? = nil,
        files: Bool? = nil,
        mail: Bool? = nil,
        messages: Bool? = nil,
        calendars: Bool? = nil,
        reminders: Bool? = nil,
        roots: [String]? = nil,
        exclude: [String]? = nil,
        maxFileMB: Int? = nil,
        mailVectorWindow: String? = nil,
        iCloudEvicted: String? = nil,
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
        self.calendars = calendars
        self.reminders = reminders
        self.roots = roots
        self.exclude = exclude
        self.maxFileMB = maxFileMB
        self.mailVectorWindow = mailVectorWindow
        self.iCloudEvicted = iCloudEvicted
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
        self.calendars = config.calendars
        self.reminders = config.reminders
        self.roots = config.roots
        self.exclude = config.exclude
        self.maxFileMB = config.maxFileMB
        self.mailVectorWindow = config.mailVectorWindow
        self.iCloudEvicted = config.iCloudEvicted
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
        case calendars
        case reminders
        case roots
        case exclude
        case maxFileMB
        case mailVectorWindow
        case iCloudEvicted
        case nightlyBudget
        case dbPath
        case effort
        case workers
        case thermalBackoff
        case pauseOnBattery
        case maxVectorChunksPerDocument
        case mailboxDeny
        case alwaysSkipped
    }

    /// Decodes a partial patch.
    /// - Parameter decoder: Decoder carrying the patch.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
        files = try container.decodeIfPresent(Bool.self, forKey: .files)
        mail = try container.decodeIfPresent(Bool.self, forKey: .mail)
        messages = try container.decodeIfPresent(Bool.self, forKey: .messages)
        calendars = try container.decodeIfPresent(Bool.self, forKey: .calendars)
        reminders = try container.decodeIfPresent(Bool.self, forKey: .reminders)
        roots = try container.decodeIfPresent([String].self, forKey: .roots)
        exclude = try container.decodeIfPresent([String].self, forKey: .exclude)
        maxFileMB = try container.decodeIfPresent(Int.self, forKey: .maxFileMB)
        mailVectorWindow = try container.decodeIfPresent(String.self, forKey: .mailVectorWindow)
        iCloudEvicted = try container.decodeIfPresent(String.self, forKey: .iCloudEvicted)
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
        try container.encodeIfPresent(calendars, forKey: .calendars)
        try container.encodeIfPresent(reminders, forKey: .reminders)
        try container.encodeIfPresent(roots, forKey: .roots)
        try container.encodeIfPresent(exclude, forKey: .exclude)
        try container.encodeIfPresent(maxFileMB, forKey: .maxFileMB)
        try container.encodeIfPresent(mailVectorWindow, forKey: .mailVectorWindow)
        try container.encodeIfPresent(iCloudEvicted, forKey: .iCloudEvicted)
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
    /// Merges a partial index patch onto the stored policy, preserving every field the request
    /// omits. A nil patch is a no-op, so a dashboard edit to one knob never resets the rest of the
    /// `[index]` section.
    func applyIndex(to index: inout IndexConfig) {
        guard let update = self.index else { return }
        applyIndexSources(update, to: &index)
        applyIndexFileScope(update, to: &index)
        applyIndexRuntime(update, to: &index)
        // Read-only: `always_skipped` is never merged so a client echo cannot
        // drift the stored policy; the walker list stays single-sourced.
    }

    /// Merges the global plus per-source enablement toggles.
    private func applyIndexSources(_ update: IndexSettingsUpdate, to index: inout IndexConfig) {
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
        if let calendars = update.calendars {
            index.calendars = calendars
        }
        if let reminders = update.reminders {
            index.reminders = reminders
        }
    }

    /// Merges file-scan scope plus content policy knobs.
    private func applyIndexFileScope(_ update: IndexSettingsUpdate, to index: inout IndexConfig) {
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
        if let nightlyBudget = update.nightlyBudget {
            index.nightlyBudget = nightlyBudget
        }
    }

    /// Merges storage, effort, and runtime behavior knobs.
    private func applyIndexRuntime(_ update: IndexSettingsUpdate, to index: inout IndexConfig) {
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
    }
}

/// Embedding engine status response for `GET /embeddings/status`.
public struct EmbeddingsStatusResponse: Content, Equatable {
    /// Active embedding backend (`"local"`, `"provider"`, or `"none"`).
    public let backend: String
    /// Supervisor status (`"idle"`, `"downloading_binary"`, `"downloading_model"`, `"starting"`, `"ready"`, or `"error"`).
    public let status: String
    /// Human-readable active stage message.
    public let stage: String?
    /// Configured GGUF model file name.
    public let model: String
    /// Embedding vector dimensionality (768 for EmbeddingGemma 2).
    public let dimensions: Int
    /// Hardware acceleration type (`"Apple Silicon Metal GPU"`).
    public let acceleration: String
    /// Socket path or host endpoint.
    public let endpoint: String
    /// Whether the supervisor process is currently alive.
    public let isRunning: Bool
    /// Last error encountered during provisioning or launch.
    public let error: String?

    public init(
        backend: String,
        status: String,
        stage: String? = nil,
        model: String,
        dimensions: Int = 768,
        acceleration: String = "Apple Silicon Metal GPU",
        endpoint: String,
        isRunning: Bool,
        error: String? = nil
    ) {
        self.backend = backend
        self.status = status
        self.stage = stage
        self.model = model
        self.dimensions = dimensions
        self.acceleration = acceleration
        self.endpoint = endpoint
        self.isRunning = isRunning
        self.error = error
    }
}

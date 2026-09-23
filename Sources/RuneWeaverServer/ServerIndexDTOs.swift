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
    /// Total chunk text bytes belonging to this source.
    public let bytes: Int64

    /// Creates a per-source content row.
    /// - Parameters:
    ///   - kind: Source kind token.
    ///   - documents: Indexed document count.
    ///   - chunks: Stored chunk count.
    ///   - bytes: Total chunk text bytes.
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

    /// Creates a last-run row.
    /// - Parameters:
    ///   - status: Run state token.
    ///   - indexed: Documents written.
    ///   - scanned: Items examined.
    ///   - errors: Items that could not be processed.
    ///   - finishedAt: Instant the run finished.
    public init(status: String, indexed: Int? = nil, scanned: Int? = nil, errors: Int? = nil, finishedAt: Date? = nil) {
        self.status = status
        self.indexed = indexed
        self.scanned = scanned
        self.errors = errors
        self.finishedAt = finishedAt
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

    /// Creates an index status snapshot.
    /// - Parameters:
    ///   - enabled: Whether the background indexer runs at all.
    ///   - running: Whether a run is in flight.
    ///   - documents: Indexed document count.
    ///   - chunks: Stored chunk count.
    ///   - vectorChunks: Chunks carrying an embedding.
    ///   - keywordChunks: Keyword-only chunks.
    ///   - bytes: Total chunk text bytes.
    ///   - indexAsOf: Last successful watermark, or nil.
    ///   - sources: Per-source enablement rows.
    ///   - lastErrors: Recent run failures, newest first.
    ///   - bySource: Per-source content aggregates.
    ///   - byExtractStatus: Extraction-outcome breakdown.
    ///   - lastRun: Latest run outcome, or nil.
    public init(
        enabled: Bool = false,
        running: Bool = false,
        documents: Int = 0,
        chunks: Int = 0,
        vectorChunks: Int = 0,
        keywordChunks: Int = 0,
        bytes: Int64 = 0,
        indexAsOf: Date? = nil,
        sources: [IndexSourceStatus] = [],
        lastErrors: [String] = [],
        bySource: [IndexSourceCounts] = [],
        byExtractStatus: [IndexExtractStatusCounts] = [],
        lastRun: IndexLastRunStatus? = nil
    ) {
        self.enabled = enabled
        self.running = running
        self.documents = documents
        self.chunks = chunks
        self.vectorChunks = vectorChunks
        self.keywordChunks = keywordChunks
        self.bytes = bytes
        self.indexAsOf = indexAsOf
        self.sources = sources
        self.lastErrors = lastErrors
        self.bySource = bySource
        self.byExtractStatus = byExtractStatus
        self.lastRun = lastRun
    }
}

/// Builds the `/index/status` shape from engine policy, aggregate stats, live
/// run state, and recent failures.
///
/// Kept as a free function so the shape has one definition independent of the
/// transport: the route only gathers inputs, and callers without a document
/// store or coordinator report an honest empty/stopped snapshot instead of
/// failing.
/// - Parameters:
///   - config: Active index policy driving enablement.
///   - stats: Aggregate store stats, or nil when no store is wired.
///   - running: Whether a run is in flight.
///   - lastErrors: Recent run failures, newest first.
///   - lastRun: Latest run outcome, or nil when no run has been recorded.
/// - Returns: The status snapshot.
func makeIndexStatusResponse(
    config: IndexConfig,
    stats: IndexStats?,
    running: Bool,
    lastErrors: [String],
    lastRun: IndexLastRunStatus? = nil
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
    return IndexStatusResponse(
        enabled: config.enabled,
        running: running,
        documents: stats?.documents ?? 0,
        chunks: stats?.chunks ?? 0,
        vectorChunks: stats?.vectorChunks ?? 0,
        keywordChunks: stats?.keywordChunks ?? 0,
        bytes: stats?.bytes ?? 0,
        indexAsOf: stats?.indexAsOf,
        sources: sources,
        lastErrors: lastErrors,
        bySource: bySource,
        byExtractStatus: byExtractStatus,
        lastRun: lastRun
    )
}

/// Outcome of `POST /index/run`.
public struct IndexRunResponse: Content, Equatable {
    /// Per-run session identifier used to tag the run log row.
    public let sessionID: UUID
    /// What caused the run (`"nightly"` or `"onDemand"`).
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
        self.warnings = summary.warnings
        self.startedAt = summary.startedAt
        self.finishedAt = summary.finishedAt
        self.indexAsOf = summary.indexAsOf
        self.skippedReason = summary.skippedReason
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
        dbPath: String? = nil
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
    }
}

public extension UpdateSettingsRequest {
    /// Builds a request from a full index snapshot, routing through the same
    /// merge path so snapshot callers keep working without hand-mapping fields.
    /// - Parameter index: Complete index policy.
    init(index: IndexConfig) {
        self.init(index: IndexSettingsUpdate(index))
    }
}

// MARK: - Index Route Paths

public extension ServerPaths {
    /// Local document index group serving status and control.
    static let index = "index"
    /// Index status subpath under `/index`.
    static let indexStatus = "status"
    /// Index on-demand run subpath under `/index`.
    static let indexRun = "run"
    /// Index cancellation subpath under `/index`.
    static let indexCancel = "cancel"
    /// Index prune subpath under `/index`.
    static let indexPrune = "prune"
    /// Index reset subpath under `/index`.
    static let indexReset = "reset"
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
    }
}

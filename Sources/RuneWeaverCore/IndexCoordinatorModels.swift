// Rune Weaver Core — Index coordinator shared models and stage seam.
//
// Holds the run phases, source kinds, per-source and per-run reports, live
// snapshot, reporting seam, and closure-backed stage so the coordinator actor
// stays focused on sequencing and the file budgets stay within the lint gate.
// Selection re-derives every run from the live policy snapshot via the single
// kind-to-flag mapping, so saved toggles apply on the next run with no
// rebuild; per-run values flow through the snapshot the coordinator hands
// each body.

import Foundation

// MARK: - Phases and sources

/// Ordered phases an index run moves through, surfaced on progress frames.
public enum IndexPhase: String, Sendable, Equatable, CaseIterable {
    /// Enumerating candidate items before any body work.
    case discovering
    /// Reading and extracting candidate bodies.
    case extracting
    /// Producing embeddings for vector-eligible chunks.
    case embedding
    /// Writing documents, chunks, and watermarks durably.
    case committing
}

/// Indexable corpora the coordinator sequences, in canonical run order.
///
/// Declared separately from ``IndexSource`` because the vision describe pass is
/// not a document origin — it enriches documents already written by another
/// source — yet it still needs a stable position in the run order.
public enum IndexSourceKind: String, Sendable, Hashable, CaseIterable {
    /// Local filesystem documents.
    case files
    /// Mail messages read from a configured mailbox.
    case mail
    /// Apple Messages transcripts.
    case messages
    /// Calendar event occurrences.
    case calendars
    /// Reminder rows.
    case reminders

    /// Canonical order sources run in, so every pass is deterministic.
    public static let runOrder: [IndexSourceKind] = [.files, .mail, .messages, .calendars, .reminders]
}

extension IndexSourceKind {
    /// Whether the kind is selected for a run under the live policy snapshot.
    ///
    /// Single kind-to-flag mapping owning selection, so a save applied via
    /// `updateConfig` takes effect on the next run with no rebuilt stages; the
    /// in-flight snapshot stays fixed for the whole run.
    /// - Parameter policy: Per-run policy snapshot fixed at run entry.
    /// - Returns: True when the global switch plus the kind's toggle enable it.
    public func isEnabled(in policy: IndexConfig) -> Bool {
        guard policy.enabled else { return false }
        switch self {
        case .files:
            return policy.files
        case .mail:
            return policy.mail
        case .messages:
            return policy.messages
        case .calendars:
            return policy.calendars
        case .reminders:
            return policy.reminders
        }
    }
}

/// What caused an index run.
public enum IndexRunTrigger: String, Sendable, Equatable {
    /// The nightly scheduler trigger, fired at the configured nightly hour.
    case nightly
    /// A late launch after the nightly hour catching up a missed nightly window.
    case catchUp
    /// A caller-requested run.
    case onDemand
}

/// Terminal (or in-flight) state of an index run.
public enum IndexRunStatus: String, Sendable, Equatable {
    /// The run is in progress.
    case running
    /// The run finished with no fatal failure.
    case ok
    /// The run failed before any source produced work.
    case error
    /// The run stopped cooperatively between batches.
    case cancelled
    /// The run did not execute, with a reason.
    case skipped
}

// MARK: - Reports

/// Counts one source stage contributed to a run.
public struct IndexSourceRunReport: Sendable, Equatable {
    /// Source the counts belong to.
    public let kind: IndexSourceKind
    /// Items examined, including those later skipped.
    public var scanned: Int
    /// Documents written during the stage.
    public var indexed: Int
    /// Chunks written carrying an embedding.
    public var vectorChunks: Int
    /// Chunks written without an embedding (keyword-only).
    public var keywordChunks: Int
    /// Items deliberately skipped (excluded, denied, unchanged, deduplicated).
    public var skipped: Int
    /// Items that could not be processed.
    public var errors: Int
    /// Documents retired (deleted as unseen) by the stage.
    public var retired: Int
    /// Documents where chunks beyond the vector cap stayed keyword-only.
    public var truncated: Int
    /// Whether the stage actually ran.
    public var didRun: Bool
    /// Set when the stage did not execute because its source is disabled.
    public var skippedReason: String?
    /// Non-fatal problems, without any content or secret.
    public var warnings: [String]
    /// Last relative item processed, for the display `current` field.
    public var lastItem: String?

    /// Creates a source run report.
    /// - Parameters:
    ///   - kind: Source the counts belong to.
    ///   - scanned: Items examined.
    ///   - indexed: Documents written.
    ///   - vectorChunks: Chunks written with an embedding.
    ///   - keywordChunks: Chunks written without an embedding.
    ///   - skipped: Items deliberately skipped.
    ///   - errors: Items that could not be processed.
    ///   - retired: Documents retired by the stage.
    ///   - truncated: Documents where the vector cap left tail chunks keyword-only.
    ///   - didRun: Whether the stage ran.
    ///   - skippedReason: Why a stage did not run.
    ///   - warnings: Non-fatal problems.
    ///   - lastItem: Last relative item processed.
    public init(
        kind: IndexSourceKind,
        scanned: Int = 0,
        indexed: Int = 0,
        vectorChunks: Int = 0,
        keywordChunks: Int = 0,
        skipped: Int = 0,
        errors: Int = 0,
        retired: Int = 0,
        truncated: Int = 0,
        didRun: Bool = true,
        skippedReason: String? = nil,
        warnings: [String] = [],
        lastItem: String? = nil
    ) {
        self.kind = kind
        self.scanned = scanned
        self.indexed = indexed
        self.vectorChunks = vectorChunks
        self.keywordChunks = keywordChunks
        self.skipped = skipped
        self.errors = errors
        self.retired = retired
        self.truncated = truncated
        self.didRun = didRun
        self.skippedReason = skippedReason
        self.warnings = warnings
        self.lastItem = lastItem
    }
}

/// Aggregate outcome of one index run.
public struct IndexRunSummary: Sendable, Equatable {
    /// Per-run session identifier used to tag the run log row.
    public let sessionID: UUID
    /// What caused the run.
    public let trigger: IndexRunTrigger
    /// Final run state.
    public let status: IndexRunStatus
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
    public let retired: Int
    /// Documents where chunks beyond the vector cap stayed keyword-only.
    public let truncated: Int
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
    /// Per-source outcomes in canonical run order, so every source reports
    /// did-run plus reason even when the aggregate counts hide a skip.
    public let sources: [IndexSourceRunReport]

    /// Creates a run summary.
    /// - Parameters:
    ///   - sessionID: Per-run session identifier.
    ///   - trigger: What caused the run.
    ///   - status: Final run state.
    ///   - documentsIndexed: Documents written.
    ///   - vectorChunks: Chunks written with an embedding.
    ///   - keywordChunks: Chunks written without an embedding.
    ///   - scanned: Items examined.
    ///   - skipped: Items deliberately skipped.
    ///   - errors: Items that could not be processed.
    ///   - retired: Documents retired across every source.
    ///   - truncated: Documents where the vector cap left tail chunks keyword-only.
    ///   - warnings: Non-fatal problems.
    ///   - startedAt: Instant the run began.
    ///   - finishedAt: Instant the run finished.
    ///   - indexAsOf: Recorded watermark on success.
    ///   - skippedReason: Why the run did not execute.
    ///   - sources: Per-source outcomes in canonical run order.
    public init(
        sessionID: UUID,
        trigger: IndexRunTrigger,
        status: IndexRunStatus,
        documentsIndexed: Int,
        vectorChunks: Int,
        keywordChunks: Int,
        scanned: Int,
        skipped: Int,
        errors: Int,
        retired: Int = 0,
        truncated: Int = 0,
        warnings: [String],
        startedAt: Date,
        finishedAt: Date,
        indexAsOf: Date?,
        skippedReason: String?,
        sources: [IndexSourceRunReport] = []
    ) {
        self.sessionID = sessionID
        self.trigger = trigger
        self.status = status
        self.documentsIndexed = documentsIndexed
        self.vectorChunks = vectorChunks
        self.keywordChunks = keywordChunks
        self.scanned = scanned
        self.skipped = skipped
        self.errors = errors
        self.retired = retired
        self.truncated = truncated
        self.warnings = warnings
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.indexAsOf = indexAsOf
        self.skippedReason = skippedReason
        self.sources = sources
    }
}

/// Lightweight snapshot of an in-flight index run for polling surfaces.
///
/// Returned by ``IndexCoordinator/liveTotals``; nil when no run is in flight.
/// Carries cumulative counts plus the active phase and stage tokens so a
/// menu-bar or dashboard poll can render liveness without touching run state.
public struct IndexLiveTotals: Sendable, Equatable {
    /// What caused the run.
    public let trigger: IndexRunTrigger
    /// Active phase.
    public let phase: IndexPhase
    /// Active source stage, or nil for discovering and committing frames.
    public let stage: IndexSourceKind?
    /// Items examined across completed work plus observed in-flight progress.
    public let scanned: Int
    /// Documents written across completed stages plus observed in-flight progress.
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
    /// Instant the run began.
    public let startedAt: Date

    /// Creates a live snapshot.
    /// - Parameters:
    ///   - trigger: What caused the run.
    ///   - phase: Active phase.
    ///   - stage: Active source stage, or nil.
    ///   - scanned: Items examined.
    ///   - indexed: Documents written.
    ///   - skipped: Items deliberately skipped.
    ///   - errors: Items that could not be processed.
    ///   - rate: Documents per second.
    ///   - elapsedMs: Milliseconds elapsed since the run began.
    ///   - current: Last relative item reported.
    ///   - startedAt: Instant the run began.
    public init(
        trigger: IndexRunTrigger,
        phase: IndexPhase,
        stage: IndexSourceKind?,
        scanned: Int,
        indexed: Int,
        skipped: Int = 0,
        errors: Int = 0,
        rate: Double = 0,
        elapsedMs: Int,
        current: String?,
        startedAt: Date
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
        self.startedAt = startedAt
    }
}

/// One run lifecycle event delivered to the reporting seam.
///
/// Carries the per-run session identifier and stable event identifier so an
/// adapter can append a `run_logs` row on start and update the same row on
/// completion, then broadcast the matching `run_started`/`run_completed` frame.
public struct IndexRunEvent: Sendable, Equatable {
    /// Stable event identifier, reused for the start and completion events.
    public let id: UUID
    /// Per-run session identifier linking the run to its log row.
    public let sessionID: UUID
    /// What caused the run.
    public let trigger: IndexRunTrigger
    /// Event state (`running` at start, terminal at completion).
    public let status: IndexRunStatus
    /// Human-readable summary, safe to display verbatim.
    public let message: String
    /// Instant the event was produced.
    public let timestamp: Date
    /// Detailed outcome text, when this is a completion event.
    public let response: String?
    /// Execution duration in milliseconds, when this is a completion event.
    public let durationMs: Int?

    /// Creates a run event.
    /// - Parameters:
    ///   - id: Stable event identifier.
    ///   - sessionID: Per-run session identifier.
    ///   - trigger: What caused the run.
    ///   - status: Event state.
    ///   - message: Human-readable summary.
    ///   - timestamp: Instant the event was produced.
    ///   - response: Detailed outcome text.
    ///   - durationMs: Execution duration in milliseconds.
    public init(
        id: UUID,
        sessionID: UUID,
        trigger: IndexRunTrigger,
        status: IndexRunStatus,
        message: String,
        timestamp: Date,
        response: String? = nil,
        durationMs: Int? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.trigger = trigger
        self.status = status
        self.message = message
        self.timestamp = timestamp
        self.response = response
        self.durationMs = durationMs
    }
}

/// Seam the coordinator reports run lifecycle through.
///
/// The server adapts this to `RunLogStore` plus `WSHub`; a test or a
/// transport-free caller can leave every method as a no-op.
public protocol IndexRunReporting: Sendable {
    /// Reports that a run started.
    /// - Parameter event: The start event, carrying the per-run session id.
    func runStarted(_ event: IndexRunEvent) async

    /// Reports that a run reached a terminal state.
    /// - Parameter event: The completion event.
    func runCompleted(_ event: IndexRunEvent) async
}

extension IndexRunReporting {
    /// Default no-op start report.
    /// - Parameter event: The start event.
    public func runStarted(_: IndexRunEvent) async {}

    /// Default no-op completion report.
    /// - Parameter event: The completion event.
    public func runCompleted(_: IndexRunEvent) async {}
}

/// Reporter that discards every event, used when no transport is wired.
public struct NullIndexRunReporter: IndexRunReporting {
    /// Creates a null reporter.
    public init() {}
}

// MARK: - Stage seam

/// One sequenced source stage the coordinator runs.
///
/// Implementations wrap a concrete indexer and translate its report into an
/// ``IndexSourceRunReport``. The coordinator passes its progress sink, a
/// cooperative cancellation probe, and the per-run policy snapshot so a stage
/// can report liveness and stop between batches without the core target
/// reaching into the server. The run-start snapshot is the single source for
/// live stage selection (via the kind-to-flag mapping) plus effort, workers,
/// caps, excludes, roots, and windows.
public protocol IndexSourceStage: Sendable {
    /// Source this stage indexes.
    var kind: IndexSourceKind { get }

    /// Boot-time enablement captured when stages are built, retained for
    /// diagnostics and compatibility only; live selection ignores it and
    /// re-derives from the run policy snapshot instead.
    var isEnabled: Bool { get }

    /// Runs the stage against one per-run policy snapshot.
    /// - Parameters:
    ///   - reporter: Sink for liveness frames.
    ///   - isCancelled: Probe that reports whether the run was cancelled.
    ///   - policy: Live index policy snapshot for this run; the only source
    ///     for effort, workers, caps, excludes, roots, and windows.
    /// - Returns: The stage's contribution to the run.
    func run(
        reporter: @escaping ToolProgressReporter,
        isCancelled: @escaping @Sendable () -> Bool,
        policy: IndexConfig
    ) async throws -> IndexSourceRunReport

    /// Requests that a run in flight stop at its next safe point.
    func cancel() async
}

extension IndexSourceStage {
    /// Default no-op cancellation for stages that own no cancellable handle.
    public func cancel() async {}
}

/// Closure-backed source stage, used to adapt the concrete indexers and to
/// drive the coordinator against deterministic stubs in tests.
///
/// The body receives the coordinator's per-run policy snapshot as its leading
/// argument so selection plus every value it builds from (effort, workers,
/// caps, excludes, roots, windows) tracks the saved policy on the next run
/// without a restart. An in-flight body keeps the snapshot it was invoked
/// with, ignoring saves that land mid-run.
public struct IndexClosureStage: IndexSourceStage {
    /// Source this stage indexes.
    public let kind: IndexSourceKind
    /// Boot-time enablement captured when stages are built, retained for
    /// diagnostics and compatibility only; live selection ignores it.
    public let isEnabled: Bool
    /// Body performing the work against one per-run policy snapshot.
    private let body: @Sendable (IndexConfig, @escaping ToolProgressReporter, @Sendable () -> Bool) async throws -> IndexSourceRunReport
    /// Hook invoked when the coordinator cancels a run.
    private let onCancel: @Sendable () async -> Void

    /// Creates a closure-backed stage.
    /// - Parameters:
    ///   - kind: Source this stage indexes.
    ///   - isEnabled: Boot-time enablement retained for compatibility; live
    ///     selection re-derives from the run policy snapshot instead.
    ///   - onCancel: Cancellation hook; defaults to a no-op.
    ///   - body: Work performed by the stage against the per-run policy.
    public init(
        kind: IndexSourceKind,
        isEnabled: Bool = true,
        onCancel: @escaping @Sendable () async -> Void = {},
        body: @escaping @Sendable (IndexConfig, @escaping ToolProgressReporter, @Sendable () -> Bool) async throws -> IndexSourceRunReport
    ) {
        self.kind = kind
        self.isEnabled = isEnabled
        self.onCancel = onCancel
        self.body = body
    }

    /// Runs the closure-backed body against one per-run policy snapshot.
    /// - Parameters:
    ///   - reporter: Sink for liveness frames.
    ///   - isCancelled: Cooperative cancellation probe.
    ///   - policy: Live index policy snapshot for this run.
    /// - Returns: The stage's contribution to the run.
    public func run(
        reporter: @escaping ToolProgressReporter,
        isCancelled: @escaping @Sendable () -> Bool,
        policy: IndexConfig
    ) async throws -> IndexSourceRunReport {
        try await body(policy, reporter, isCancelled)
    }

    /// Invokes the cancellation hook.
    public func cancel() async {
        await onCancel()
    }
}

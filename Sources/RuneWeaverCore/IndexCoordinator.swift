// Rune Weaver Core — Coordinator owning nightly and on-demand index runs.
//
// One actor sequences the per-source indexers (files, mail, Messages, and the
// opt-in vision describe pass) into a single run, exposes the single live
// source as the `liveTotals` poll snapshot (nil when idle) that the menu and
// page read via `GET /index/status` `live` on about a 2s in-run poll, reports
// run lifecycle through an injected seam so the server can broadcast
// `run_started`/`run_completed` and persist the run to `run_logs`, and records
// an `indexAsOf` watermark on success. `ToolProgress` liveness frames plus the
// `run_started`/`run_completed` broadcasts are poll-now wake-up triggers only,
// never the data carrier. Each source stage commits its own work as it goes,
// so a cancelled run stops between batches and leaves already-committed
// documents in place for the next run to resume from.
//
// The coordinator is transport-agnostic on purpose: the core target cannot see
// the server's `WSHub` or `RunLogStore`, so those are reached through the
// ``IndexRunReporting`` seam and adapted at the application boundary. Progress
// frames carry only counts and display copy — never file contents or secrets.

import Foundation
import os

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
    /// Opt-in LLM descriptions for bodyless documents.
    case vision

    /// Canonical order sources run in, so every pass is deterministic.
    public static let runOrder: [IndexSourceKind] = [.files, .mail, .messages, .vision]
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
        skippedReason: String?
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

public extension IndexRunReporting {
    /// Default no-op start report.
    /// - Parameter event: The start event.
    func runStarted(_: IndexRunEvent) async {}

    /// Default no-op completion report.
    /// - Parameter event: The completion event.
    func runCompleted(_: IndexRunEvent) async {}
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
/// reaching into the server. The snapshot is the single source for effort,
/// workers, caps, excludes, roots, and windows; selection still consults the
/// boot-time `isEnabled` flag.
public protocol IndexSourceStage: Sendable {
    /// Source this stage indexes.
    var kind: IndexSourceKind { get }

    /// Whether the stage was selected at boot for the active configuration.
    ///
    /// Captured when stages are built, so enabling a source later needs
    /// rebuilt stages while disabling is honored through the per-run policy.
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

public extension IndexSourceStage {
    /// Default no-op cancellation for stages that own no cancellable handle.
    func cancel() async {}
}

/// Closure-backed source stage, used to adapt the concrete indexers and to
/// drive the coordinator against deterministic stubs in tests.
///
/// The body receives the coordinator's per-run policy snapshot as its leading
/// argument so every value it builds from (effort, workers, caps, excludes,
/// roots, windows) tracks the saved policy without a restart. An in-flight
/// body keeps the snapshot it was invoked with, ignoring saves that land
/// mid-run.
public struct IndexClosureStage: IndexSourceStage {
    /// Source this stage indexes.
    public let kind: IndexSourceKind
    /// Whether the stage was selected at boot for the active configuration.
    public let isEnabled: Bool
    /// Body performing the work against one per-run policy snapshot.
    private let body: @Sendable (IndexConfig, @escaping ToolProgressReporter, @Sendable () -> Bool) async throws -> IndexSourceRunReport
    /// Hook invoked when the coordinator cancels a run.
    private let onCancel: @Sendable () async -> Void

    /// Creates a closure-backed stage.
    /// - Parameters:
    ///   - kind: Source this stage indexes.
    ///   - isEnabled: Whether the stage was selected at boot.
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

// MARK: - Watermark state

/// Persisted coordinator state: the last successful watermark and trigger times.
public struct IndexRunState: Sendable, Codable, Equatable {
    /// Instant of the last successful run, used as the index watermark.
    public var indexAsOf: Date?
    /// Instant the last successful run completed.
    public var lastCompletedAt: Date?
    /// Instant the nightly trigger last started a run.
    public var lastNightlyStart: Date?

    /// Creates run state.
    /// - Parameters:
    ///   - indexAsOf: Last successful watermark.
    ///   - lastCompletedAt: Last successful completion instant.
    ///   - lastNightlyStart: Last nightly trigger instant.
    public init(indexAsOf: Date? = nil, lastCompletedAt: Date? = nil, lastNightlyStart: Date? = nil) {
        self.indexAsOf = indexAsOf
        self.lastCompletedAt = lastCompletedAt
        self.lastNightlyStart = lastNightlyStart
    }
}

/// JSON-backed store for the coordinator watermark and trigger times.
///
/// The state is tiny and read on demand, so a JSON sidecar keeps the watermark
/// independent of the document store schema and survives restarts.
public actor IndexRunStateStore {
    /// Default state path, kept beside the other durable memory stores.
    public static let defaultPath = "~/.runeweaver/index/coordinator-state.json"

    /// Filesystem path of the JSON sidecar.
    public let path: String

    /// Whether the sidecar has been read into memory.
    private var loaded = false
    /// In-memory state snapshot.
    private var state = IndexRunState()

    /// Creates a state store.
    /// - Parameter path: JSON sidecar path. `~` is expanded on first load.
    public init(path: String = IndexRunStateStore.defaultPath) {
        self.path = path
    }

    /// Returns the current state snapshot.
    /// - Returns: The in-memory state.
    public func snapshot() -> IndexRunState {
        loadIfNeeded()
        return state
    }

    /// Records a successful run, advancing the watermark and completion time.
    /// - Parameter date: Completion instant.
    public func recordCompleted(at date: Date) throws {
        loadIfNeeded()
        state.indexAsOf = date
        state.lastCompletedAt = date
        try persist()
    }

    /// Records that the nightly trigger started a run.
    /// - Parameter date: Trigger instant.
    public func recordNightlyStart(at date: Date) throws {
        loadIfNeeded()
        state.lastNightlyStart = date
        try persist()
    }

    /// Clears every recorded field.
    public func reset() throws {
        loadIfNeeded()
        state = IndexRunState()
        try persist()
    }

    /// Reads the sidecar once, ignoring unreadable or corrupt state.
    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let expanded = (path as NSString).expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: expanded)) else { return }
        do {
            state = try JSONDecoder().decode(IndexRunState.self, from: data)
        } catch {
            RuneWeaverLog.scheduler.warning("IndexRunStateStore: failed to decode index run state from '\(expanded)': \(error.localizedDescription)")
        }
    }

    /// Writes the state to disk atomically.
    private func persist() throws {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(state)
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - Coordinator

/// Actor owning nightly and on-demand local index runs.
///
/// One coordinator sequences its enabled source stages in ``IndexSourceKind/runOrder``,
/// emits liveness frames at the shared 2 Hz cadence, and reports run lifecycle
/// through ``IndexRunReporting``. A run is cancellable between stages and each
/// stage commits as it goes, so cancellation never discards committed work and a
/// later run resumes from the first unfinished item.
public actor IndexCoordinator {
    /// Minimum spacing between progress frames (2 Hz), shared with `ToolProgress`.
    static let minimumFrameInterval: TimeInterval = Double(ToolProgress.minimumReportIntervalNanoseconds) / 1_000_000_000
    /// Heartbeat cadence for stalled runs, bypassing the frame floor.
    ///
    /// A run that makes no progress still emits a liveness frame on this
    /// cadence so a slow IMAP fetch, embedding batch, or vision turn never
    /// looks wedged. Heartbeats reuse the coordinator emit path, so they carry
    /// the same elapsed, rate, cumulative counts, and phase/stage tokens.
    /// The nanosecond form below derives from this single value so the two
    /// can never drift apart.
    static let heartbeatInterval: TimeInterval = 2.0
    /// Heartbeat cadence in nanoseconds, derived for `Task.sleep`.
    static var heartbeatIntervalNanoseconds: UInt64 {
        UInt64(heartbeatInterval * 1_000_000_000)
    }

    /// Index policy gating sources and budgets. Mutable so a settings save can
    /// hot-reload the next run without rebuilding stages or restarting.
    private var config: IndexConfig
    /// Source stages, sequenced into run order at execution time.
    private let stages: [any IndexSourceStage]
    /// Optional document store used to read final aggregate stats.
    private let store: DocIndexStore?
    /// Durable watermark and trigger state.
    private let stateStore: IndexRunStateStore
    /// Run lifecycle reporting seam.
    private let reporter: any IndexRunReporting
    /// Wall-clock seam, injectable so nightly gating is deterministic under test.
    private let now: @Sendable () -> Date
    /// Hour of day (0-23) at or after which the nightly trigger may fire.
    private let nightlyHour: Int
    /// Advisory progress sink; defaults to a no-op.
    private let progress: ToolProgressReporter

    /// Lock-guarded cancellation flag shared with non-isolated stage closures.
    private let cancelFlag = IndexCancellationFlag()
    /// Stages currently running, for cancellation propagation.
    ///
    /// Holds one entry during sequential passes and up to three during the files plus
    /// mail plus messages overlap so cancellation reaches every in-flight stage. Each stage
    /// keeps its own budget, thermal, and battery gates, so sharing this list
    /// never shares effort accounting.
    private var activeStages: [any IndexSourceStage] = []
    /// Completed scanned count observed when the overlap began, anchoring the summed live frame.
    private var overlapBaseScanned = 0
    /// Completed indexed count observed when the overlap began.
    private var overlapBaseIndexed = 0
    /// Per-stage scanned high-water marks feeding the single cumulative live frame.
    ///
    /// Keyed by the stage's index in the overlap batch, not by kind, so two
    /// stages sharing one kind never overwrite each other's marks.
    private var overlapScanned: [Int: Int] = [:]
    /// Per-stage indexed high-water marks feeding the single cumulative live frame.
    ///
    /// Keyed by the stage's index in the overlap batch, not by kind.
    private var overlapIndexed: [Int: Int] = [:]
    /// Handle for the run task in flight, so cancellation aborts in-flight awaits.
    ///
    /// Stored at run start and cleared alongside `running` so `cancel()` can
    /// abort awaits (IMAP, embedding batch, vision turn) via `Task` cancellation
    /// in addition to the cooperative flag; the awaits then throw at their next
    /// checkpoint instead of running to stage end.
    private var activeRunTask: Task<IndexRunSummary, Never>?
    /// Whether a run is in flight.
    private var running = false
    /// Instant of the last emitted liveness frame.
    private var lastFrameAt: Date?
    /// Trigger of the run in flight, for the live snapshot and heartbeats.
    private var liveTrigger: IndexRunTrigger?
    /// Instant the run in flight began, for elapsed and rate math.
    private var liveStartedAt: Date?
    /// Active phase of the run in flight.
    private var livePhase: IndexPhase?
    /// Active source stage, or nil for discovering and committing frames.
    private var liveStage: IndexSourceKind?
    /// Cumulative items examined, including observed in-flight stage progress.
    private var liveScanned = 0
    /// Cumulative documents written across completed stages.
    private var liveIndexed = 0
    /// Cumulative items deliberately skipped across completed stages.
    private var liveSkipped = 0
    /// Cumulative items that could not be processed across completed stages.
    private var liveErrors = 0
    /// Cumulative chunks written with an embedding across completed stages.
    private var liveVectorChunks = 0
    /// Cumulative chunks written without an embedding across completed stages.
    private var liveKeywordChunks = 0
    /// Last relative item reported, for the display `current` field.
    private var liveCurrent: String?

    /// Creates an index coordinator.
    /// - Parameters:
    ///   - config: Index policy; `enabled` gates every run.
    ///   - stages: Source stages, sequenced by ``IndexSourceKind/runOrder``.
    ///   - store: Optional document store for final aggregate stats.
    ///   - stateStore: Durable watermark and trigger state.
    ///   - reporter: Run lifecycle reporting seam; defaults to a null reporter.
    ///   - now: Wall-clock seam.
    ///   - nightlyHour: Hour the nightly trigger may fire; defaults to 3 AM.
    ///   - progress: Advisory progress sink; defaults to a no-op.
    public init(
        config: IndexConfig,
        stages: [any IndexSourceStage],
        store: DocIndexStore? = nil,
        stateStore: IndexRunStateStore = IndexRunStateStore(),
        reporter: any IndexRunReporting = NullIndexRunReporter(),
        now: @escaping @Sendable () -> Date = { Date() },
        nightlyHour: Int = 3,
        progress: @escaping ToolProgressReporter = ToolContext.noProgress
    ) {
        self.config = config
        self.stages = stages
        self.store = store
        self.stateStore = stateStore
        self.reporter = reporter
        self.now = now
        self.nightlyHour = min(max(nightlyHour, 0), 23)
        self.progress = progress
    }

    /// Whether a run is currently in flight.
    public var isRunning: Bool {
        running
    }

    /// Lightweight snapshot of the run in flight, or nil when idle.
    ///
    /// Reads only the cached live counters so menu-bar and dashboard polling
    /// never touches run state, the document store, or the watermark. Nil once
    /// the run settles.
    /// - Returns: The live snapshot, or nil when no run is in flight.
    public var liveTotals: IndexLiveTotals? {
        guard running,
              let trigger = liveTrigger,
              let startedAt = liveStartedAt,
              let phase = livePhase
        else { return nil }
        let timestamp = now()
        let elapsedMs = max(0, Int(timestamp.timeIntervalSince(startedAt) * 1000))
        let seconds = max(timestamp.timeIntervalSince(startedAt), 0)
        // Honest rate: sub-half-second windows magnify one document into a
        // triple-digit spike, so the snapshot reports zero until 500ms elapse.
        let rate = (elapsedMs >= 500 && seconds > 0) ? Double(liveIndexed) / seconds : 0
        return IndexLiveTotals(
            trigger: trigger,
            phase: phase,
            stage: liveStage,
            scanned: liveScanned,
            indexed: liveIndexed,
            skipped: liveSkipped,
            errors: liveErrors,
            rate: rate,
            elapsedMs: elapsedMs,
            current: liveCurrent,
            startedAt: startedAt
        )
    }

    /// Updates the live index policy so saved `[index]` values take effect without a restart.
    ///
    /// The next run builds every indexer from the saved snapshot, so effort,
    /// workers, caps, excludes, roots, and windows apply with no rebuilt
    /// stages; a run already in flight keeps the snapshot it started with. A
    /// source turned off after boot reports skipped on the next pass through
    /// its policy guard, while a source turned on after boot stays parked
    /// until stages are rebuilt because selection still consults the boot-time
    /// flag.
    /// - Parameter newConfig: Persisted policy from the settings save.
    public func updateConfig(_ newConfig: IndexConfig) {
        config = newConfig
    }

    /// Runs the nightly trigger when it is due.
    ///
    /// A disabled coordinator is a no-op, as is a trigger already run on the
    /// current calendar day or one that arrives before ``nightlyHour``. The
    /// trigger is `.nightly` when the calendar hour equals ``nightlyHour`` and
    /// `.catchUp` for a later same-day launch that missed the nightly window;
    /// the same-day guard applies to both so at most one automatic run fires
    /// per calendar day. The nightly start is recorded only when the run
    /// proceeds past the single-flight check, so a tick racing a manual run
    /// returns skipped without suppressing the nightly retry for that day.
    /// - Parameter date: Evaluation instant.
    /// - Returns: The run summary when a run fired, or nil when nothing happened.
    @discardableResult
    public func fireNightly(now date: Date = Date()) async -> IndexRunSummary? {
        guard config.enabled else { return nil }
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: date)
        guard hour >= nightlyHour else { return nil }
        let snapshot = await stateStore.snapshot()
        if let last = snapshot.lastNightlyStart, calendar.isDate(last, inSameDayAs: date) {
            return nil
        }
        let trigger: IndexRunTrigger = (hour == nightlyHour) ? .nightly : .catchUp
        let summary = await run(trigger: trigger)
        if summary.status != .skipped {
            try? await stateStore.recordNightlyStart(at: date)
        }
        return summary
    }

    /// Runs one index pass over every enabled source.
    ///
    /// The run never throws: a failing stage is counted and the pass continues,
    /// because a background index should make progress on the remaining sources
    /// rather than abort on one bad gateway. Cancellation stops the pass within
    /// one batch, leaving committed work for the next run.
    /// - Parameter trigger: What caused the run.
    /// - Returns: A summary describing the pass.
    @discardableResult
    public func run(trigger: IndexRunTrigger = .onDemand) async -> IndexRunSummary {
        guard config.enabled else {
            return await reportSkipped(trigger: trigger, reason: "Indexing is disabled in [index].")
        }
        guard !running else {
            return await reportSkipped(trigger: trigger, reason: "An index run is already in progress.")
        }
        running = true
        defer {
            running = false
            activeRunTask = nil
        }

        cancelFlag.reset()
        activeStages = []
        lastFrameAt = nil
        let startedAt = now()
        let sessionID = UUID()
        let eventID = UUID()
        let flag = cancelFlag
        // Own the stage loop in a child task so cancel() can abort in-flight
        // awaits via Task cancellation in addition to the cooperative flag.
        // The child runs its actor work in the child's task context, so every
        // per-batch Task probe inside the stages observes the cancel within one
        // batch instead of running to stage end.
        let child = Task<IndexRunSummary, Never> {
            await self.performRun(
                trigger: trigger,
                sessionID: sessionID,
                eventID: eventID,
                startedAt: startedAt
            )
        }
        activeRunTask = child
        // Forward outer cancellation (for example a dropped request task) to
        // the run task; cancel() itself never awaits the run, so the cancel
        // route keeps returning immediately while the run settles via broadcast.
        return await withTaskCancellationHandler {
            await child.value
        } onCancel: {
            flag.set()
            child.cancel()
        }
    }

    /// Executes the stage loop for one run.
    ///
    /// Runs in the run task's context so Task cancellation from `cancel()` is
    /// observed at the next per-batch checkpoint. A failing stage is counted
    /// and the pass continues; cancellation stops between batches, leaving
    /// committed work for the next run. A heartbeat task re-emits the current
    /// cumulative totals on ``heartbeatInterval`` so a stalled stage never
    /// looks wedged, and the live snapshot stays fresh for polling surfaces.
    /// - Parameters:
    ///   - trigger: What caused the run.
    ///   - sessionID: Per-run session identifier for the log row.
    ///   - eventID: Stable event identifier for start and completion events.
    ///   - startedAt: Instant the run began.
    /// - Returns: A summary describing the pass.
    private func performRun(
        trigger: IndexRunTrigger,
        sessionID: UUID,
        eventID: UUID,
        startedAt: Date
    ) async -> IndexRunSummary {
        var totals = Totals()
        // One snapshot for the whole run so a save landing mid-run cannot
        // split stages across policies; the next run picks it up instead.
        let runPolicy = config
        resetLiveState(trigger: trigger, startedAt: startedAt)
        await reporter.runStarted(IndexRunEvent(
            id: eventID,
            sessionID: sessionID,
            trigger: trigger,
            status: .running,
            message: "Index run started (\(trigger.rawValue))",
            timestamp: startedAt
        ))
        await emit(phase: .discovering, totals: totals, startedAt: startedAt, force: true)
        let heartbeat = startHeartbeat(startedAt: startedAt)
        let ranAny = await runEnabledStages(totals: &totals, startedAt: startedAt, policy: runPolicy)
        activeStages = []
        // Join the heartbeat before the committing frame so a stale wake
        // between the committing emit and clearLiveState cannot re-emit the
        // prior phase after it (phase regression/out-of-order frame). No defer
        // here: the explicit cancel plus join below is the single teardown
        // path, and a deferred cancel would only fire as a no-op after it.
        heartbeat.cancel()
        await heartbeat.value
        return await finishRun(
            trigger: trigger,
            sessionID: sessionID,
            eventID: eventID,
            startedAt: startedAt,
            totals: totals,
            ranAny: ranAny
        )
    }

    /// Resets the cached live counters for a fresh run.
    ///
    /// Centralized so the run entry and the live snapshot read from one place;
    /// polling surfaces observe these fields without touching run state.
    /// - Parameters:
    ///   - trigger: What caused the run.
    ///   - startedAt: Instant the run began.
    private func resetLiveState(trigger: IndexRunTrigger, startedAt: Date) {
        liveTrigger = trigger
        liveStartedAt = startedAt
        livePhase = .discovering
        liveStage = nil
        liveScanned = 0
        liveIndexed = 0
        liveSkipped = 0
        liveErrors = 0
        liveVectorChunks = 0
        liveKeywordChunks = 0
        liveCurrent = nil
        overlapBaseScanned = 0
        overlapBaseIndexed = 0
        overlapScanned = [:]
        overlapIndexed = [:]
    }

    /// Finalizes a run into its summary, watermark, and completion broadcast.
    ///
    /// Committing progress, the durable watermark, and the terminal frame all
    /// derive here so the stage loop stays focused on sequencing alone.
    /// - Parameters:
    ///   - trigger: What caused the run.
    ///   - sessionID: Per-run session identifier for the log row.
    ///   - eventID: Stable event identifier for start and completion events.
    ///   - startedAt: Instant the run began.
    ///   - totals: Accumulated counts across stages.
    ///   - ranAny: Whether any stage produced work or a counted failure.
    /// - Returns: A summary describing the pass.
    private func finishRun(
        trigger: IndexRunTrigger,
        sessionID: UUID,
        eventID: UUID,
        startedAt: Date,
        totals: Totals,
        ranAny: Bool
    ) async -> IndexRunSummary {
        let finishedAt = now()
        let cancelled = cancelFlag.isSet || Task.isCancelled
        // A cancelled run keeps partial progress observed on the live counters:
        // an in-flight stage cancelled before returning its report has already
        // contributed scanned/indexed frames via `observeStageProgress`, so fold
        // the live high-water marks into the terminal totals instead of dropping
        // them. The persisted `cancelled` row therefore always carries the work
        // done so far for the last-run strip.
        var resolved = totals
        if cancelled {
            resolved.scanned = max(resolved.scanned, liveScanned)
            resolved.indexed = max(resolved.indexed, liveIndexed)
            resolved.skipped = max(resolved.skipped, liveSkipped)
            resolved.errors = max(resolved.errors, liveErrors)
            if resolved.lastItem == nil, let current = liveCurrent {
                resolved.lastItem = current
            }
        }
        let status: IndexRunStatus = if cancelled {
            .cancelled
        } else if !ranAny, resolved.errors > 0 {
            .error
        } else {
            .ok
        }
        if !cancelled {
            livePhase = .committing
            liveStage = nil
            await emit(phase: .committing, totals: resolved, startedAt: startedAt, force: true)
        }
        let stats = try? await store?.stats()
        let recordedAsOf = stats?.indexAsOf ?? finishedAt
        if status == .ok {
            try? await stateStore.recordCompleted(at: recordedAsOf)
        }
        let durationMs = max(0, Int(finishedAt.timeIntervalSince(startedAt) * 1000))
        let summary = IndexRunSummary(
            sessionID: sessionID,
            trigger: trigger,
            status: status,
            documentsIndexed: resolved.indexed,
            vectorChunks: resolved.vectorChunks,
            keywordChunks: resolved.keywordChunks,
            scanned: resolved.scanned,
            skipped: resolved.skipped,
            errors: resolved.errors,
            retired: resolved.retired,
            truncated: resolved.truncated,
            warnings: resolved.warnings,
            startedAt: startedAt,
            finishedAt: finishedAt,
            indexAsOf: status == .ok ? recordedAsOf : nil,
            skippedReason: nil
        )
        await emitFinal(summary: summary, startedAt: startedAt)
        await reporter.runCompleted(IndexRunEvent(
            id: eventID,
            sessionID: sessionID,
            trigger: trigger,
            status: status,
            message: Self.summaryLine(summary),
            timestamp: finishedAt,
            response: Self.detailLine(summary),
            durationMs: durationMs
        ))
        clearLiveState()
        return summary
    }

    /// Clears the cached live counters once a run settles.
    ///
    /// Polling surfaces read nil as idle, so clearing here unmounts the live
    /// strip without persisting any post-run summary.
    private func clearLiveState() {
        liveTrigger = nil
        liveStartedAt = nil
        livePhase = nil
        liveStage = nil
        liveScanned = 0
        liveIndexed = 0
        liveSkipped = 0
        liveErrors = 0
        liveVectorChunks = 0
        liveKeywordChunks = 0
        liveCurrent = nil
        overlapBaseScanned = 0
        overlapBaseIndexed = 0
        overlapScanned = [:]
        overlapIndexed = [:]
    }

    /// Requests cancellation of the run in flight.
    ///
    /// The flag is set immediately, every active stage is asked to stop at its
    /// next safe point, and the stored run task is cancelled so in-flight
    /// awaits throw at their next checkpoint instead of running to stage end.
    /// Joining happens in the stage loop, so this stays immediate while the
    /// run settles via broadcast. Work already committed by prior batches
    /// stays in place. Returns immediately without awaiting the run;
    /// completion is observed via the `run_completed` broadcast or the status probe.
    public func cancel() async {
        cancelFlag.set()
        for stage in activeStages {
            await stage.cancel()
        }
        activeRunTask?.cancel()
    }

    /// Clears the durable run state store.
    public func reset() async throws {
        try await stateStore.reset()
    }
}

// MARK: - Sequencing

private extension IndexCoordinator {
    /// Stages sorted into the canonical run order.
    var orderedStages: [any IndexSourceStage] {
        stages.enumerated().sorted { lhs, rhs in
            let left = IndexSourceKind.runOrder.firstIndex(of: lhs.element.kind) ?? Int.max
            let right = IndexSourceKind.runOrder.firstIndex(of: rhs.element.kind) ?? Int.max
            if left != right {
                return left < right
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// Runs every enabled stage, overlapping files plus mail plus messages and sequencing the rest.
    ///
    /// CPU-bound files, network-bound mail, and light local messages wait on
    /// different resources, so the trio runs together in a task group and
    /// finishes near the slowest peer instead of the serial sum. Vision plus
    /// any later stage follows sequentially in canonical order to keep
    /// enrichment deterministic, and peers join in canonical order regardless
    /// of completion order so watermarks match the serial pass exactly. One
    /// totals per concurrent peer feeds a single cumulative live frame under
    /// the generic extracting phase so polling surfaces stay monotonic;
    /// warnings plus errors stay attributed per source. A failing peer is
    /// counted and the pass continues, and cancellation joins every active
    /// peer within one batch with committed work kept for resume. Budgets stay
    /// per source because each peer builds its own indexer from the shared run
    /// policy snapshot, and thermal plus battery gates stay inside those
    /// indexers untouched.
    /// - Parameters:
    ///   - totals: Running counts folded across stages.
    ///   - startedAt: Instant the run began.
    ///   - policy: Per-run policy snapshot fixed at run entry; every stage
    ///     builds from this snapshot so a save landing mid-run never splits
    ///     one run across policies.
    /// - Returns: Whether any stage produced work or a counted failure.
    func runEnabledStages(totals: inout Totals, startedAt: Date, policy: IndexConfig) async -> Bool {
        let enabled = orderedStages.filter(\.isEnabled)
        let overlapStages = enabled.filter { $0.kind == .files || $0.kind == .mail || $0.kind == .messages }
        let remainder = enabled.filter { $0.kind != .files && $0.kind != .mail && $0.kind != .messages }
        guard overlapStages.count >= 2 else {
            var ranAny = false
            for stage in enabled {
                if cancelFlag.isSet || Task.isCancelled {
                    break
                }
                let didRun = await executeStage(stage, totals: &totals, startedAt: startedAt, policy: policy)
                ranAny = ranAny || didRun
                if cancelFlag.isSet || Task.isCancelled {
                    break
                }
            }
            return ranAny
        }
        var ranAny = false
        // The shared snapshot arrives as `policy` from the run entry, so a
        // save landing mid-overlap cannot split the trio across policies;
        // the next run picks it up instead.
        let runPolicy = policy
        let baseScanned = totals.scanned
        let baseIndexed = totals.indexed
        overlapBaseScanned = baseScanned
        overlapBaseIndexed = baseIndexed
        overlapScanned = [:]
        overlapIndexed = [:]
        for index in overlapStages.indices {
            overlapScanned[index] = 0
            overlapIndexed[index] = 0
        }
        // Register every peer upfront so a cancel racing stage start still reaches
        // each peer; removal below pops exactly the appended slice so two
        // stages sharing one kind never remove each other.
        let overlapBaseCount = activeStages.count
        activeStages.append(contentsOf: overlapStages)
        livePhase = .extracting
        // Nil stage marks the mixed trio: the single cumulative frame carries
        // summed counts rather than attributing to one peer.
        liveStage = nil
        await emit(phase: .extracting, totals: totals, startedAt: startedAt, force: true)
        let collected = await withTaskGroup(
            of: OverlapStageOutcome.self,
            returning: [Int: (Bool, Totals)].self
        ) { group in
            for (index, stage) in overlapStages.enumerated() {
                group.addTask {
                    let outcome = await self.executeStage(stage, index: index, policy: runPolicy, startedAt: startedAt)
                    return OverlapStageOutcome(index: index, didRun: outcome.didRun, stageTotals: outcome.stageTotals)
                }
            }
            var gathered: [Int: (Bool, Totals)] = [:]
            for await outcome in group {
                gathered[outcome.index] = (outcome.didRun, outcome.stageTotals)
            }
            return gathered
        }
        // Join plus summation in canonical order so watermarks and last-item
        // match the serial pass exactly regardless of completion order.
        // Pops exactly the appended slice by count so duplicate kinds cannot
        // remove each other.
        let expectedOverlapEnd = overlapBaseCount + overlapStages.count
        if activeStages.count >= expectedOverlapEnd {
            activeStages.removeSubrange(overlapBaseCount ..< expectedOverlapEnd)
        }
        for index in overlapStages.indices {
            if let entry = collected[index] {
                totals.add(entry.1)
                ranAny = ranAny || entry.0
            }
        }
        liveScanned = max(liveScanned, totals.scanned)
        liveIndexed = max(liveIndexed, totals.indexed)
        liveSkipped = totals.skipped
        liveErrors = totals.errors
        liveVectorChunks = totals.vectorChunks
        liveKeywordChunks = totals.keywordChunks
        if let item = totals.lastItem {
            liveCurrent = item
        }
        if cancelFlag.isSet || Task.isCancelled {
            return ranAny
        }
        for stage in remainder {
            if cancelFlag.isSet || Task.isCancelled {
                break
            }
            let didRun = await executeStage(stage, totals: &totals, startedAt: startedAt, policy: runPolicy)
            ranAny = ranAny || didRun
            if cancelFlag.isSet || Task.isCancelled {
                break
            }
        }
        return ranAny
    }

    /// Executes one source stage and folds its report into the running totals.
    ///
    /// Stage frames carry per-stage counts, so progress is offset by the totals
    /// at stage start to keep the live snapshot cumulative and monotonic. The
    /// policy arrives threaded from the run entry, never re-read here, so a
    /// body keeps the snapshot it started with even when a settings save lands
    /// mid-run, while the next run picks up the saved policy without rebuilt
    /// stages.
    /// - Parameters:
    ///   - stage: Source stage to run.
    ///   - totals: Running counts to fold the report into.
    ///   - startedAt: Instant the run began.
    ///   - policy: Per-run policy snapshot fixed at run entry.
    /// - Returns: Whether the stage contributed work or a counted failure.
    func executeStage(
        _ stage: any IndexSourceStage,
        totals: inout Totals,
        startedAt: Date,
        policy: IndexConfig
    ) async -> Bool {
        let activeBaseCount = activeStages.count
        activeStages.append(stage)
        let phase: IndexPhase = stage.kind == .vision ? .embedding : .extracting
        livePhase = phase
        liveStage = stage.kind
        await emit(phase: phase, stage: stage.kind, totals: totals, startedAt: startedAt, force: true)
        let flag = cancelFlag
        let cancellationProbe: @Sendable () -> Bool = { flag.isSet || Task.isCancelled }
        let sink = progress
        let baseScanned = totals.scanned
        let baseIndexed = totals.indexed
        let stageReporter: ToolProgressReporter = { frame in
            await self.observeStageProgress(frame, baseScanned: baseScanned, baseIndexed: baseIndexed)
            await sink(frame)
        }
        // Removes exactly the appended entry by position so two stages
        // sharing one kind never remove each other.
        defer {
            if activeStages.count > activeBaseCount {
                activeStages.remove(at: activeBaseCount)
            }
        }
        do {
            // Per-run policy seam: every stage builds from the run-entry
            // snapshot, never from a config captured at boot or re-read here,
            // so saved effort, workers, caps, excludes, roots, and windows
            // apply on the next run.
            let report = try await stage.run(
                reporter: stageReporter,
                isCancelled: cancellationProbe,
                policy: policy
            )
            totals.add(report)
            liveScanned = max(liveScanned, totals.scanned)
            liveIndexed = max(liveIndexed, totals.indexed)
            liveSkipped = totals.skipped
            liveErrors = totals.errors
            liveVectorChunks = totals.vectorChunks
            liveKeywordChunks = totals.keywordChunks
            if let item = report.lastItem {
                liveCurrent = item
            }
            return true
        } catch is CancellationError {
            cancelFlag.set()
            return false
        } catch {
            totals.errors += 1
            totals.warnings.append("\(stage.kind.rawValue): \(error.localizedDescription)")
            liveErrors = totals.errors
            return true
        }
    }

    /// Executes one overlapped stage against a shared run snapshot.
    ///
    /// Owns exactly one stage's totals so peers never share a counter:
    /// files, mail, and messages budgets stay isolated because each indexer
    /// enforces its own cap from the same snapshot. Progress funnels through the summed
    /// observer keyed by the stage's index in the overlap batch, so duplicate
    /// kinds never overwrite each other's high-water marks. The caller in
    /// `runEnabledStages` is the only place that merges peers. Active-stage
    /// registration stays with the caller so a cancel racing stage start
    /// still reaches every peer.
    /// - Parameters:
    ///   - stage: Overlapped source stage to run.
    ///   - index: Position in the overlap batch, owning the high-water slot.
    ///   - policy: Shared run snapshot for the overlap batch.
    ///   - startedAt: Instant the run began.
    /// - Returns: Whether the stage contributed work plus its per-stage totals.
    func executeStage(
        _ stage: any IndexSourceStage,
        index: Int,
        policy: IndexConfig,
        startedAt: Date
    ) async -> (didRun: Bool, stageTotals: Totals) {
        var stageTotals = Totals()
        let flag = cancelFlag
        let cancellationProbe: @Sendable () -> Bool = { flag.isSet || Task.isCancelled }
        let stageReporter: ToolProgressReporter = { frame in
            await self.observeConcurrentProgress(index: index, frame: frame, startedAt: startedAt)
        }
        do {
            let report = try await stage.run(
                reporter: stageReporter,
                isCancelled: cancellationProbe,
                policy: policy
            )
            stageTotals.add(report)
            await self.finalizeConcurrentProgress(index: index, report: report)
            return (true, stageTotals)
        } catch is CancellationError {
            flag.set()
            return (false, stageTotals)
        } catch {
            stageTotals.errors += 1
            stageTotals.warnings.append("\(stage.kind.rawValue): \(error.localizedDescription)")
            return (true, stageTotals)
        }
    }

    /// Folds one overlapped frame into the single cumulative live snapshot.
    ///
    /// Each peer reports its own cumulative counts, so the per-stage
    /// high-water mark absorbs late or duplicate frames and the sum of peers
    /// plus the overlap base stays monotonic. Only the summed frame is
    /// emitted, never the raw peer frame, so polling surfaces observe one
    /// stream that matches serial watermark math.
    /// - Parameters:
    ///   - index: Overlap-batch position owning the high-water slot.
    ///   - frame: Peer progress frame.
    ///   - startedAt: Instant the run began.
    func observeConcurrentProgress(index: Int, frame: ToolProgress, startedAt: Date) async {
        let priorScanned = overlapScanned[index] ?? 0
        let priorIndexed = overlapIndexed[index] ?? 0
        overlapScanned[index] = max(priorScanned, frame.scanned)
        overlapIndexed[index] = max(priorIndexed, frame.matched)
        if let current = frame.current {
            liveCurrent = current
        }
        let summedScanned = overlapBaseScanned + overlapScanned.values.reduce(0, +)
        let summedIndexed = overlapBaseIndexed + overlapIndexed.values.reduce(0, +)
        if summedScanned > liveScanned {
            liveScanned = summedScanned
        }
        if summedIndexed > liveIndexed {
            liveIndexed = summedIndexed
        }
        await emit(phase: .extracting, stage: nil, totals: liveSnapshot(), startedAt: startedAt, force: false)
    }

    /// Converges one peer's final report into the summed live marks.
    ///
    /// Interim frames can lag the committed report, so the final counts join
    /// the high-water marks here; the caller merges full totals after the
    /// group joins, keeping watermark order canonical.
    /// - Parameters:
    ///   - index: Overlap-batch position owning the high-water slot.
    ///   - report: Final stage contribution.
    func finalizeConcurrentProgress(index: Int, report: IndexSourceRunReport) async {
        overlapScanned[index] = max(overlapScanned[index] ?? 0, report.scanned)
        overlapIndexed[index] = max(overlapIndexed[index] ?? 0, report.indexed)
        if let item = report.lastItem {
            liveCurrent = item
        }
        let summedScanned = overlapBaseScanned + overlapScanned.values.reduce(0, +)
        let summedIndexed = overlapBaseIndexed + overlapIndexed.values.reduce(0, +)
        if summedScanned > liveScanned {
            liveScanned = summedScanned
        }
        if summedIndexed > liveIndexed {
            liveIndexed = summedIndexed
        }
    }

    /// Builds a skipped summary for reporting through `reportSkipped`.
    ///
    /// Pure builder only; the caller persists and broadcasts it via the
    /// reporting seam so every skipped run lands in `run_logs` and the
    /// kind-filtered latest-run lookup observes it.
    /// - Parameters:
    ///   - trigger: What would have caused the run.
    ///   - reason: Why the run did not execute.
    /// - Returns: A summary carrying the skip state.
    func skippedSummary(trigger: IndexRunTrigger, reason: String) -> IndexRunSummary {
        let stamp = now()
        return IndexRunSummary(
            sessionID: UUID(),
            trigger: trigger,
            status: .skipped,
            documentsIndexed: 0,
            vectorChunks: 0,
            keywordChunks: 0,
            scanned: 0,
            skipped: 0,
            errors: 0,
            warnings: [],
            startedAt: stamp,
            finishedAt: stamp,
            indexAsOf: nil,
            skippedReason: reason
        )
    }

    /// Reports a skipped run through the reporting seam so it lands in `run_logs`.
    ///
    /// Skipped runs never touch stage state, but they still persist one
    /// `run_logs` row (a start event plus a terminal `skipped` completion
    /// sharing one event id) and broadcast the matching frames, so the
    /// kind-filtered latest-run lookup observes every run and the status strip
    /// agrees with the run notice on the skip reason carried by `detailLine`'s
    /// `Skipped:` line.
    /// - Parameters:
    ///   - trigger: What would have caused the run.
    ///   - reason: Why the run did not execute.
    /// - Returns: A summary carrying the skip state.
    func reportSkipped(trigger: IndexRunTrigger, reason: String) async -> IndexRunSummary {
        let summary = skippedSummary(trigger: trigger, reason: reason)
        let eventID = UUID()
        await reporter.runStarted(IndexRunEvent(
            id: eventID,
            sessionID: summary.sessionID,
            trigger: trigger,
            status: .running,
            message: "Index run started (\(trigger.rawValue))",
            timestamp: summary.startedAt
        ))
        await reporter.runCompleted(IndexRunEvent(
            id: eventID,
            sessionID: summary.sessionID,
            trigger: trigger,
            status: .skipped,
            message: Self.summaryLine(summary),
            timestamp: summary.finishedAt,
            response: Self.detailLine(summary),
            durationMs: 0
        ))
        return summary
    }
}

// MARK: - Progress

private extension IndexCoordinator {
    /// Running totals accumulated across source stages.
    struct Totals: Sendable {
        /// Items examined.
        var scanned = 0
        /// Documents written.
        var indexed = 0
        /// Chunks written with an embedding.
        var vectorChunks = 0
        /// Chunks written without an embedding.
        var keywordChunks = 0
        /// Items deliberately skipped.
        var skipped = 0
        /// Items that could not be processed.
        var errors = 0
        /// Documents retired (deleted as unseen).
        var retired = 0
        /// Documents where the vector cap left tail chunks keyword-only.
        var truncated = 0
        /// Non-fatal problems.
        var warnings: [String] = []
        /// Last relative item reported by a stage.
        var lastItem: String?

        /// Adds one stage report into the running totals.
        /// - Parameter report: Stage contribution to fold in.
        mutating func add(_ report: IndexSourceRunReport) {
            merge(Totals(
                scanned: report.scanned,
                indexed: report.indexed,
                vectorChunks: report.vectorChunks,
                keywordChunks: report.keywordChunks,
                skipped: report.skipped,
                errors: report.errors,
                retired: report.retired,
                truncated: report.truncated,
                warnings: report.warnings,
                lastItem: report.lastItem
            ))
        }

        /// Merges one stage's accumulated totals into the running totals.
        /// - Parameter other: Per-stage totals to fold in.
        mutating func add(_ other: Totals) {
            merge(other)
        }

        /// Folds counted fields shared by reports and accumulated totals.
        ///
        /// Keeps warning attribution intact by appending in canonical order, so
        /// a files warning never masks a mail warning and the watermark math
        /// matches the serial pass exactly.
        /// - Parameter other: Counted contribution to fold in.
        private mutating func merge(_ other: Totals) {
            scanned += other.scanned
            indexed += other.indexed
            vectorChunks += other.vectorChunks
            keywordChunks += other.keywordChunks
            skipped += other.skipped
            errors += other.errors
            retired += other.retired
            truncated += other.truncated
            warnings.append(contentsOf: other.warnings)
            if let item = other.lastItem {
                lastItem = item
            }
        }
    }

    /// One overlapped peer's outcome for the task-group join.
    ///
    /// Carries the peer's overlap-batch index so the join folds peers in
    /// canonical order no matter which finishes first, keeping watermarks
    /// identical to serial even when two stages share one kind.
    struct OverlapStageOutcome: Sendable {
        /// Overlap-batch position owning the high-water slot.
        let index: Int
        /// Whether the peer contributed work or a counted failure.
        let didRun: Bool
        /// Per-stage totals owned by `executeStage`.
        let stageTotals: Totals
    }

    /// Builds the live totals snapshot from the cached counters.
    ///
    /// Single owner for the snapshot shape so the concurrent observer and
    /// the heartbeat cannot drift apart.
    /// - Returns: Totals carrying the current live counters.
    func liveSnapshot() -> Totals {
        var snapshot = Totals()
        snapshot.scanned = liveScanned
        snapshot.indexed = liveIndexed
        snapshot.skipped = liveSkipped
        snapshot.errors = liveErrors
        snapshot.vectorChunks = liveVectorChunks
        snapshot.keywordChunks = liveKeywordChunks
        snapshot.lastItem = liveCurrent
        return snapshot
    }

    /// Starts the stalled-run heartbeat re-emitting current totals.
    ///
    /// A slow fetch or embedding batch still proves liveness on this cadence
    /// by reusing the coordinator emit path with identical tokens and counts.
    /// - Parameter startedAt: Instant the run began.
    /// - Returns: The heartbeat task, cancelled when the run settles.
    func startHeartbeat(startedAt: Date) -> Task<Void, Never> {
        Task<Void, Never> {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.heartbeatIntervalNanoseconds)
                if Task.isCancelled {
                    break
                }
                await self.emitHeartbeat(startedAt: startedAt)
            }
        }
    }

    /// Emits one heartbeat frame, bypassing the cadence floor.
    ///
    /// Reuses the coordinator emit path so the heartbeat carries the same
    /// elapsed, rate, cumulative counts, current item, and phase/stage tokens
    /// as any other frame. No-ops when no run is in flight.
    /// - Parameter startedAt: Instant the run began.
    func emitHeartbeat(startedAt: Date) async {
        guard running, let phase = livePhase else { return }
        await emit(phase: phase, stage: liveStage, totals: liveSnapshot(), startedAt: startedAt, force: true)
    }

    /// Folds one stage progress frame into the cached live counters.
    ///
    /// Stage frames carry per-stage counts, so they are offset by the completed
    /// totals at stage start to keep the live snapshot cumulative. The cached
    /// values only move forward so a late or duplicate frame never rewinds the
    /// snapshot or a heartbeat derived from it.
    /// - Parameters:
    ///   - frame: Frame reported by the active stage.
    ///   - baseScanned: Completed scanned total when the stage started.
    ///   - baseIndexed: Completed indexed total when the stage started.
    func observeStageProgress(_ frame: ToolProgress, baseScanned: Int, baseIndexed: Int) {
        let cumulativeScanned = baseScanned + frame.scanned
        let cumulativeIndexed = baseIndexed + frame.matched
        if cumulativeScanned > liveScanned {
            liveScanned = cumulativeScanned
        }
        if cumulativeIndexed > liveIndexed {
            liveIndexed = cumulativeIndexed
        }
        if let current = frame.current {
            liveCurrent = current
        }
    }

    /// Emits a phase frame, honoring the shared 2 Hz cadence unless forced.
    /// - Parameters:
    ///   - phase: Phase being reported.
    ///   - stage: Active source stage, or nil for discovering and committing frames.
    ///   - totals: Running totals so far.
    ///   - startedAt: Instant the run began.
    ///   - force: Whether to bypass the cadence floor.
    func emit(phase: IndexPhase, stage: IndexSourceKind? = nil, totals: Totals, startedAt: Date, force: Bool) async {
        let timestamp = now()
        if !force, let lastFrameAt, timestamp.timeIntervalSince(lastFrameAt) < Self.minimumFrameInterval {
            return
        }
        lastFrameAt = timestamp
        let elapsedMs = max(0, Int(timestamp.timeIntervalSince(startedAt) * 1000))
        let seconds = max(timestamp.timeIntervalSince(startedAt), 0)
        // Honest rate: sub-half-second windows magnify one document into a
        // triple-digit spike, so frames report zero until 500ms elapse.
        let rate = (elapsedMs >= 500 && seconds > 0) ? Double(totals.indexed) / seconds : 0
        let prefix = if let stage {
            "Indexing \(phase.rawValue) \(stage.rawValue):"
        } else {
            "Indexing \(phase.rawValue):"
        }
        let message = "\(prefix) \(totals.indexed) indexed "
            + "(\(totals.vectorChunks) vectors, \(totals.keywordChunks) keyword-only), "
            + "\(totals.scanned) scanned, \(totals.skipped) skipped, \(totals.errors) errors, "
            + String(format: "%.1f docs/s", rate)
        await progress(ToolProgress(
            message: message,
            scanned: totals.scanned,
            matched: totals.indexed,
            elapsedMs: elapsedMs,
            current: totals.lastItem
        ))
    }

    /// Emits the terminal progress frame for a finished run.
    /// - Parameters:
    ///   - summary: Completed run summary.
    ///   - startedAt: Instant the run began.
    func emitFinal(summary: IndexRunSummary, startedAt: Date) async {
        let elapsedMs = max(0, Int(summary.finishedAt.timeIntervalSince(startedAt) * 1000))
        await progress(ToolProgress(
            message: "Index run \(summary.status.rawValue): \(summary.documentsIndexed) indexed, "
                + "\(summary.scanned) scanned, \(summary.errors) errors",
            scanned: summary.scanned,
            matched: summary.documentsIndexed,
            elapsedMs: elapsedMs,
            current: nil
        ))
    }

    /// Single-line summary for the run event message.
    ///
    /// Carries retired and truncated counts inline so the durable message alone
    /// lights the dashboard badges even when the detail response is pruned.
    /// - Parameter summary: Completed run summary.
    /// - Returns: A display-safe one-liner.
    static func summaryLine(_ summary: IndexRunSummary) -> String {
        "Index run \(summary.status.rawValue): \(summary.documentsIndexed) indexed, "
            + "\(summary.vectorChunks) vectors, \(summary.keywordChunks) keyword-only, "
            + "\(summary.scanned) scanned, \(summary.errors) errors, "
            + "\(summary.retired) retired, \(summary.truncated) truncated"
    }

    /// Detailed outcome text for the completion event response.
    ///
    /// Repeats retired and truncated as `Retired:`/`Truncated:` detail lines so
    /// the status probe parses them like the trigger and skip lines without
    /// depending on summary wording.
    /// - Parameter summary: Completed run summary.
    /// - Returns: A multi-line, content-free summary.
    static func detailLine(_ summary: IndexRunSummary) -> String {
        var lines = [summaryLine(summary)]
        lines.append("Trigger: \(summary.trigger.rawValue)")
        lines.append("Retired: \(summary.retired)")
        lines.append("Truncated: \(summary.truncated)")
        if let indexAsOf = summary.indexAsOf {
            lines.append("Index as of: \(ISO8601DateFormatter().string(from: indexAsOf))")
        }
        if let reason = summary.skippedReason {
            lines.append("Skipped: \(reason)")
        }
        lines.append(contentsOf: summary.warnings.map { "Warning: \($0)" })
        return lines.joined(separator: "\n")
    }
}

// MARK: - Cancellation flag

/// Lock-guarded cancellation flag shared with non-isolated stage closures.
final class IndexCancellationFlag: Sendable {
    /// Thread-safe flag state.
    private let state = OSAllocatedUnfairLock(initialState: false)

    /// Whether cancellation has been requested.
    var isSet: Bool {
        state.withLock { $0 }
    }

    /// Requests cancellation.
    func set() {
        state.withLock { $0 = true }
    }

    /// Clears the flag for a fresh run.
    func reset() {
        state.withLock { $0 = false }
    }
}

// Stage factories live in IndexCoordinatorStages.swift.

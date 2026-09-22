// Rune Weaver Core — Coordinator owning nightly and on-demand index runs.
//
// One actor sequences the per-source indexers (files, mail, Messages, and the
// opt-in vision describe pass) into a single run, emits liveness frames over the
// shared `ToolProgress` path, reports run lifecycle through an injected seam so
// the server can broadcast `run_started`/`run_completed` and persist the run to
// `run_logs`, and records an `indexAsOf` watermark on success. Each source stage
// commits its own work as it goes, so a cancelled run stops between batches and
// leaves already-committed documents in place for the next run to resume from.
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
public enum IndexSourceKind: String, Sendable, Equatable, CaseIterable {
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
    /// The nightly scheduler trigger.
    case nightly
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
        self.warnings = warnings
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.indexAsOf = indexAsOf
        self.skippedReason = skippedReason
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
/// ``IndexSourceRunReport``. The coordinator passes its progress sink and a
/// cooperative cancellation probe so a stage can report liveness and stop
/// between batches without the core target reaching into the server.
public protocol IndexSourceStage: Sendable {
    /// Source this stage indexes.
    var kind: IndexSourceKind { get }

    /// Whether the stage should run for the active configuration.
    var isEnabled: Bool { get }

    /// Runs the stage.
    /// - Parameters:
    ///   - reporter: Sink for liveness frames.
    ///   - isCancelled: Probe that reports whether the run was cancelled.
    /// - Returns: The stage's contribution to the run.
    func run(
        reporter: @escaping ToolProgressReporter,
        isCancelled: @escaping @Sendable () -> Bool
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
public struct IndexClosureStage: IndexSourceStage {
    /// Source this stage indexes.
    public let kind: IndexSourceKind
    /// Whether the stage should run for the active configuration.
    public let isEnabled: Bool
    /// Body performing the work.
    private let body: @Sendable (@escaping ToolProgressReporter, @Sendable () -> Bool) async throws -> IndexSourceRunReport
    /// Hook invoked when the coordinator cancels a run.
    private let onCancel: @Sendable () async -> Void

    /// Creates a closure-backed stage.
    /// - Parameters:
    ///   - kind: Source this stage indexes.
    ///   - isEnabled: Whether the stage should run.
    ///   - onCancel: Cancellation hook; defaults to a no-op.
    ///   - body: Work performed by the stage.
    public init(
        kind: IndexSourceKind,
        isEnabled: Bool = true,
        onCancel: @escaping @Sendable () async -> Void = {},
        body: @escaping @Sendable (@escaping ToolProgressReporter, @Sendable () -> Bool) async throws -> IndexSourceRunReport
    ) {
        self.kind = kind
        self.isEnabled = isEnabled
        self.onCancel = onCancel
        self.body = body
    }

    /// Runs the closure-backed body.
    /// - Parameters:
    ///   - reporter: Sink for liveness frames.
    ///   - isCancelled: Cooperative cancellation probe.
    /// - Returns: The stage's contribution to the run.
    public func run(
        reporter: @escaping ToolProgressReporter,
        isCancelled: @escaping @Sendable () -> Bool
    ) async throws -> IndexSourceRunReport {
        try await body(reporter, isCancelled)
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
        if let decoded = try? JSONDecoder().decode(IndexRunState.self, from: data) {
            state = decoded
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

    /// Index policy gating sources and budgets.
    private let config: IndexConfig
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
    /// Stage currently running, for cancellation propagation.
    private var activeStage: (any IndexSourceStage)?
    /// Whether a run is in flight.
    private var running = false
    /// Instant of the last emitted liveness frame.
    private var lastFrameAt: Date?

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

    /// Runs the nightly trigger when it is due.
    ///
    /// A disabled coordinator is a no-op, as is a trigger already run on the
    /// current calendar day or one that arrives before ``nightlyHour``.
    /// - Parameter date: Evaluation instant.
    /// - Returns: The run summary when a run fired, or nil when nothing happened.
    @discardableResult
    public func fireNightly(now date: Date = Date()) async -> IndexRunSummary? {
        guard config.enabled else { return nil }
        let calendar = Calendar.current
        guard calendar.component(.hour, from: date) >= nightlyHour else { return nil }
        let snapshot = await stateStore.snapshot()
        if let last = snapshot.lastNightlyStart, calendar.isDate(last, inSameDayAs: date) {
            return nil
        }
        try? await stateStore.recordNightlyStart(at: date)
        return await run(trigger: .nightly)
    }

    /// Runs one index pass over every enabled source.
    ///
    /// The run never throws: a failing stage is counted and the pass continues,
    /// because a background index should make progress on the remaining sources
    /// rather than abort on one bad gateway. Cancellation stops the pass between
    /// stages, leaving committed work for the next run.
    /// - Parameter trigger: What caused the run.
    /// - Returns: A summary describing the pass.
    @discardableResult
    public func run(trigger: IndexRunTrigger = .onDemand) async -> IndexRunSummary {
        guard config.enabled else {
            return skippedSummary(trigger: trigger, reason: "Indexing is disabled in [index].")
        }
        guard !running else {
            return skippedSummary(trigger: trigger, reason: "An index run is already in progress.")
        }
        running = true
        defer { running = false }

        cancelFlag.reset()
        activeStage = nil
        lastFrameAt = nil
        let startedAt = now()
        let sessionID = UUID()
        let eventID = UUID()
        var totals = Totals()

        await reporter.runStarted(IndexRunEvent(
            id: eventID,
            sessionID: sessionID,
            trigger: trigger,
            status: .running,
            message: "Index run started (\(trigger.rawValue))",
            timestamp: startedAt
        ))
        await emit(phase: .discovering, totals: totals, startedAt: startedAt, force: true)

        var ranAny = false
        for stage in orderedStages where stage.isEnabled {
            if cancelFlag.isSet || Task.isCancelled {
                break
            }
            activeStage = stage
            let phase: IndexPhase = stage.kind == .vision ? .embedding : .extracting
            await emit(phase: phase, totals: totals, startedAt: startedAt, force: true)
            let flag = cancelFlag
            let cancellationProbe: @Sendable () -> Bool = { flag.isSet || Task.isCancelled }
            do {
                let report = try await stage.run(reporter: progress, isCancelled: cancellationProbe)
                ranAny = true
                totals.add(report)
                if cancelFlag.isSet {
                    break
                }
            } catch is CancellationError {
                cancelFlag.set()
                break
            } catch {
                ranAny = true
                totals.errors += 1
                totals.warnings.append("\(stage.kind.rawValue): \(error.localizedDescription)")
            }
            activeStage = nil
        }
        activeStage = nil

        let finishedAt = now()
        let cancelled = cancelFlag.isSet || Task.isCancelled
        let status: IndexRunStatus = if cancelled {
            .cancelled
        } else if !ranAny, totals.errors > 0 {
            .error
        } else {
            .ok
        }

        await emit(phase: .committing, totals: totals, startedAt: startedAt, force: true)
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
            documentsIndexed: totals.indexed,
            vectorChunks: totals.vectorChunks,
            keywordChunks: totals.keywordChunks,
            scanned: totals.scanned,
            skipped: totals.skipped,
            errors: totals.errors,
            warnings: totals.warnings,
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
        return summary
    }

    /// Requests cancellation of the run in flight.
    ///
    /// The flag is set immediately and the active stage is asked to stop at its
    /// next safe point; work already committed by prior batches stays in place.
    public func cancel() async {
        cancelFlag.set()
        if let activeStage {
            await activeStage.cancel()
        }
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

    /// Builds a skipped summary without touching the reporter.
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
}

// MARK: - Progress

private extension IndexCoordinator {
    /// Running totals accumulated across source stages.
    struct Totals {
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
        /// Non-fatal problems.
        var warnings: [String] = []
        /// Last relative item reported by a stage.
        var lastItem: String?

        /// Adds one stage report into the running totals.
        /// - Parameter report: Stage contribution to fold in.
        mutating func add(_ report: IndexSourceRunReport) {
            scanned += report.scanned
            indexed += report.indexed
            vectorChunks += report.vectorChunks
            keywordChunks += report.keywordChunks
            skipped += report.skipped
            errors += report.errors
            warnings.append(contentsOf: report.warnings)
            if let item = report.lastItem {
                lastItem = item
            }
        }
    }

    /// Emits a phase frame, honoring the shared 2 Hz cadence unless forced.
    /// - Parameters:
    ///   - phase: Phase being reported.
    ///   - totals: Running totals so far.
    ///   - startedAt: Instant the run began.
    ///   - force: Whether to bypass the cadence floor.
    func emit(phase: IndexPhase, totals: Totals, startedAt: Date, force: Bool) async {
        let timestamp = now()
        if !force, let lastFrameAt, timestamp.timeIntervalSince(lastFrameAt) < Self.minimumFrameInterval {
            return
        }
        lastFrameAt = timestamp
        let elapsedMs = max(0, Int(timestamp.timeIntervalSince(startedAt) * 1000))
        let seconds = max(timestamp.timeIntervalSince(startedAt), 0)
        let rate = seconds > 0 ? Double(totals.indexed) / seconds : 0
        let message = "Indexing \(phase.rawValue): \(totals.indexed) indexed "
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
    /// - Parameter summary: Completed run summary.
    /// - Returns: A display-safe one-liner.
    static func summaryLine(_ summary: IndexRunSummary) -> String {
        "Index run \(summary.status.rawValue): \(summary.documentsIndexed) indexed, "
            + "\(summary.vectorChunks) vectors, \(summary.keywordChunks) keyword-only, "
            + "\(summary.scanned) scanned, \(summary.errors) errors"
    }

    /// Detailed outcome text for the completion event response.
    /// - Parameter summary: Completed run summary.
    /// - Returns: A multi-line, content-free summary.
    static func detailLine(_ summary: IndexRunSummary) -> String {
        var lines = [summaryLine(summary)]
        lines.append("Trigger: \(summary.trigger.rawValue)")
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

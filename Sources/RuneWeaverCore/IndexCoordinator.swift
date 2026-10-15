// Rune Weaver Core — Coordinator owning nightly and on-demand index runs.
//
// One actor sequences the per-source indexers (files, mail, messages, calendars,
// and reminders) into a single run, exposes the single live
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

// Shared models live in IndexCoordinatorModels.swift; run totals, reporting
// helpers, and the cancellation flag live in IndexCoordinatorSupport.swift.

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
    /// cadence so a slow IMAP fetch or embedding batch never
    /// looks wedged. Heartbeats reuse the coordinator emit path, so they carry
    /// the same elapsed, rate, cumulative counts, and phase/stage tokens.
    /// The nanosecond form below derives from this single value so the two
    /// can never drift apart.
    public static let heartbeatInterval: TimeInterval = 2.0
    /// Heartbeat cadence in nanoseconds, derived for `Task.sleep`.
    static var heartbeatIntervalNanoseconds: UInt64 {
        UInt64(heartbeatInterval * 1_000_000_000)
    }

    /// Heartbeat cadence configured for this coordinator.
    private let heartbeatInterval: TimeInterval
    /// Heartbeat cadence in nanoseconds, derived for `Task.sleep`.
    private var instanceHeartbeatIntervalNanoseconds: UInt64 {
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
    /// abort awaits (IMAP, embedding batch) via `Task` cancellation
    /// in addition to the cooperative flag; the awaits then throw at their next
    /// checkpoint instead of running to stage end.
    private var activeRunTask: Task<IndexRunSummary, Never>?
    /// Whether a run is in flight.
    private var running = false
    /// Whether catch-up indexing was already attempted for this launch session.
    private var didAttemptLaunchCatchUp = false
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
    /// Per-source reports completed in the run in flight, in completion order.
    private var currentSourceReports: [IndexSourceRunReport] = []

    /// Creates an index coordinator.
    /// - Parameters:
    ///   - config: Index policy; `enabled` gates every run.
    ///   - stages: Source stages, sequenced by ``IndexSourceKind/runOrder``.
    ///   - store: Optional document store for final aggregate stats.
    ///   - stateStore: Durable watermark and trigger state.
    ///   - reporter: Run lifecycle reporting seam; defaults to a null reporter.
    ///   - now: Wall-clock seam.
    ///   - nightlyHour: Hour the nightly trigger may fire; defaults to 3 AM.
    ///   - heartbeatInterval: Cadence for stalled-run heartbeats; defaults to 2.0s.
    ///   - progress: Advisory progress sink; defaults to a no-op.
    public init(
        config: IndexConfig,
        stages: [any IndexSourceStage],
        store: DocIndexStore? = nil,
        stateStore: IndexRunStateStore = IndexRunStateStore(),
        reporter: any IndexRunReporting = NullIndexRunReporter(),
        now: @escaping @Sendable () -> Date = { Date() },
        nightlyHour: Int = 3,
        heartbeatInterval: TimeInterval = IndexCoordinator.heartbeatInterval,
        progress: @escaping ToolProgressReporter = ToolContext.noProgress
    ) {
        self.config = config
        self.stages = stages
        self.store = store
        self.stateStore = stateStore
        self.reporter = reporter
        self.now = now
        self.nightlyHour = min(max(nightlyHour, 0), 23)
        self.heartbeatInterval = max(heartbeatInterval, 0.01)
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
    /// The next run re-derives selection from the saved snapshot via the
    /// single kind-to-flag mapping and builds every indexer from that
    /// snapshot with no rebuilt stages; a run already in flight keeps the
    /// snapshot it started with.
    /// - Parameter newConfig: Persisted policy from the settings save.
    public func updateConfig(_ newConfig: IndexConfig) {
        config = newConfig
    }

    /// Runs the nightly trigger when it is due.
    ///
    /// A disabled coordinator is a no-op, as is a trigger already run on the
    /// current calendar day or one that arrives before ``nightlyHour``. The
    /// trigger is `.nightly` when the calendar hour equals ``nightlyHour``.
    /// Outside the nightly hour, a missed prior nightly run is evaluated
    /// as a `.catchUp` trigger at most once per launch session. When an index
    /// run is already in flight, background triggers quietly return nil
    /// instead of broadcasting skipped run noise.
    /// - Parameter date: Evaluation instant.
    /// - Returns: The run summary when a run fired, or nil when nothing happened.
    @discardableResult
    public func fireNightly(now date: Date = Date()) async -> IndexRunSummary? {
        guard config.enabled else { return nil }

        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: date)
        let isNightlyHour = (hour == nightlyHour)

        if isNightlyHour {
            guard !running else { return nil }
            let snapshot = await stateStore.snapshot()
            if let last = snapshot.lastNightlyStart, calendar.isDate(last, inSameDayAs: date) {
                return nil
            }
            do {
                try await stateStore.recordNightlyStart(at: date)
            } catch {
                RuneWeaverLog.stores.error("IndexCoordinator: failed to record nightly start: \(error.localizedDescription)")
            }
            return await run(trigger: .nightly)
        } else {
            guard !didAttemptLaunchCatchUp else { return nil }
            didAttemptLaunchCatchUp = true
            guard !running else { return nil }

            guard hour > nightlyHour else { return nil }
            let snapshot = await stateStore.snapshot()
            // Catch-up only fires if at least 1 index run has previously completed.
            guard snapshot.lastCompletedAt != nil else { return nil }

            // If a document store is wired, ensure the database file exists and is non-empty.
            if let store {
                let expanded = (store.dbPath as NSString).expandingTildeInPath
                guard FileManager.default.fileExists(atPath: expanded) else { return nil }
                if let stats = try? await store.fastStats(), stats.documents == 0 {
                    return nil
                }
            }

            if let last = snapshot.lastNightlyStart, calendar.isDate(last, inSameDayAs: date) {
                return nil
            }
            do {
                try await stateStore.recordNightlyStart(at: date)
            } catch {
                RuneWeaverLog.stores.error("IndexCoordinator: failed to record nightly start: \(error.localizedDescription)")
            }
            return await run(trigger: .catchUp)
        }
    }

    /// Starts an index pass in the background without awaiting its completion.
    ///
    /// Returns immediately (~5ms) with ``IndexStartOutcome`` so callers never
    /// hold an idle network connection open across long-running index passes.
    /// The spawned run task rides the ``IndexStartOutcome/started`` payload so
    /// an awaiter joins the exact pass it started instead of re-reading
    /// coordinator state across an actor hop, where a fast settle could clear
    /// the stored handle first. Progress streams via WebSocket frames, and
    /// terminal summary is emitted on completion.
    /// - Parameter trigger: What caused the run.
    /// - Returns: Immediate start outcome.
    @discardableResult
    public func start(trigger: IndexRunTrigger = .onDemand) async -> IndexStartOutcome {
        guard config.enabled else {
            return .disabled(reason: "Indexing is disabled in [index].")
        }
        guard !running else {
            return .alreadyRunning
        }
        running = true
        cancelFlag.reset()
        activeStages = []
        lastFrameAt = nil
        let startedAt = now()
        let sessionID = UUID()
        let eventID = UUID()

        // The child holds the coordinator strongly: a started run must settle
        // (clear `running` and `activeRunTask`, emit the completion broadcast)
        // even when every caller drops the coordinator first. The only cycle —
        // the stored handle below reaching back to this closure — breaks when
        // the actor-isolated `performRun` clears it via `markRunFinished`
        // before the task returns. Cleanup lives inside `performRun` (same-actor
        // context, so no cross-isolation hop) rather than in this closure, where
        // a sync actor-state mutation would rely on closure isolation
        // inheritance to prove correct. The single `await` below is for the
        // `async` `performRun` itself, which requires `await` in every context.
        let child = Task<IndexRunSummary, Never> {
            await self.performRun(
                trigger: trigger,
                sessionID: sessionID,
                eventID: eventID,
                startedAt: startedAt
            )
        }
        activeRunTask = child
        return .started(sessionID: sessionID, startedAt: startedAt, task: child)
    }

    /// Cleans up internal running state when a background run task finishes.
    private func markRunFinished() {
        running = false
        activeRunTask = nil
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
        let outcome = await start(trigger: trigger)
        switch outcome {
        case let .disabled(reason):
            return await reportSkipped(trigger: trigger, reason: reason)
        case .alreadyRunning:
            return await reportSkipped(trigger: trigger, reason: "An index run is already in progress.")
        case let .started(_, _, child):
            // Join the exact child returned in the outcome: reading the stored
            // handle here instead would race a fast settle that clears it on
            // an interleaved actor hop.
            let flag = cancelFlag
            return await withTaskCancellationHandler {
                await child.value
            } onCancel: {
                flag.set()
                child.cancel()
            }
        }
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

    /// Clears the durable run state store and resets the launch catch-up attempt flag.
    public func reset() async throws {
        didAttemptLaunchCatchUp = false
        try await stateStore.reset()
    }
}

// MARK: - Run Execution

extension IndexCoordinator {
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
        // Settle single-flight state on every exit path while still on the
        // actor: `performRun` executes on the coordinator's executor (reached
        // via `await self.performRun`), so this sync mutation needs no hop and
        // runs even for fire-and-forget `start` callers that never join the task.
        defer { markRunFinished() }
        var totals = Totals()
        // One snapshot for the whole run so a save landing mid-run cannot
        // split stages across policies; the next run picks it up instead.
        let runPolicy = config
        resetLiveState(trigger: trigger, startedAt: startedAt)
        currentSourceReports = []
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
            context: FinishRunContext(
                trigger: trigger,
                sessionID: sessionID,
                eventID: eventID,
                startedAt: startedAt,
                policy: runPolicy
            ),
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
    /// Per-source gaps synthesize from the same run policy snapshot that
    /// selected stages, so saved toggles stay honest in the summary.
    /// - Parameters:
    ///   - context: Run identity plus per-run policy snapshot fixed at entry.
    ///   - totals: Accumulated counts across stages.
    ///   - ranAny: Whether any stage produced work or a counted failure.
    /// - Returns: A summary describing the pass.
    private func finishRun(
        context: FinishRunContext,
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
            await emit(phase: .committing, totals: resolved, startedAt: context.startedAt, force: true)
        }
        let recordedAsOf: Date
        // Terminal aggregates stay searchable for every mutating run because cancelled
        // passes keep their committed documents; a failed refresh keeps the prior row
        // rather than failing the run, and the single refresh pass replaces the old
        // stats warm read so run end performs exactly one aggregate pass. The refresh
        // runs first so the durable watermark below rides the persisted snapshot's
        // content watermark (MAX(indexed_at)) rather than the wall-clock finish;
        // the value comes from the same single pass, so no extra scan is added.
        // `IndexRunStateStore.recordCompleted` persists whatever instant it is given,
        // so it tolerates either leg; when there is no store or the refresh fails,
        // the wall-clock finish stands in.
        do {
            if let snapshot = try await store?.refreshAggregates(producingRunID: context.sessionID.uuidString) {
                recordedAsOf = snapshot.indexAsOf
            } else {
                recordedAsOf = finishedAt
            }
        } catch {
            RuneWeaverLog.stores.error("IndexCoordinator: failed to refresh aggregates: \(error.localizedDescription)")
            recordedAsOf = finishedAt
        }
        if status == .ok {
            do {
                try await stateStore.recordCompleted(at: recordedAsOf)
            } catch {
                RuneWeaverLog.stores.error("IndexCoordinator: failed to record completion state: \(error.localizedDescription)")
            }
        }
        let durationMs = max(0, Int(finishedAt.timeIntervalSince(context.startedAt) * 1000))
        let orderedSources = Self.orderedSourceReports(currentSourceReports, cancelled: cancelled, policy: context.policy)
        let summary = IndexRunSummary(
            sessionID: context.sessionID,
            trigger: context.trigger,
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
            startedAt: context.startedAt,
            finishedAt: finishedAt,
            indexAsOf: status == .ok ? recordedAsOf : nil,
            skippedReason: nil,
            sources: orderedSources
        )
        await emitFinal(summary: summary, startedAt: context.startedAt)
        await reporter.runCompleted(IndexRunEvent(
            id: context.eventID,
            sessionID: context.sessionID,
            trigger: context.trigger,
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
}

// MARK: - Sequencing

extension IndexCoordinator {
    /// Stages sorted into the canonical run order.
    private var orderedStages: [any IndexSourceStage] {
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
    private func runEnabledStages(totals: inout Totals, startedAt: Date, policy: IndexConfig) async -> Bool {
        // Selection re-derives every run from the live `policy` snapshot via
        // the single kind-to-flag mapping, so a save applied via
        // `updateConfig` takes effect on the next run with no rebuild; the
        // in-flight snapshot stays fixed for the whole run.
        let enabled = orderedStages.filter { $0.kind.isEnabled(in: policy) }
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
    private func executeStage(
        _ stage: any IndexSourceStage,
        totals: inout Totals,
        startedAt: Date,
        policy: IndexConfig
    ) async -> Bool {
        let activeBaseCount = activeStages.count
        activeStages.append(stage)
        let phase: IndexPhase = .extracting
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
            currentSourceReports.append(report)
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
            currentSourceReports.append(IndexSourceRunReport(
                kind: stage.kind,
                scanned: 0,
                indexed: 0,
                errors: 1,
                didRun: true,
                warnings: ["\(stage.kind.rawValue): \(error.localizedDescription)"]
            ))
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
    private func executeStage(
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
            self.recordSourceReport(report)
            return (true, stageTotals)
        } catch is CancellationError {
            flag.set()
            return (false, stageTotals)
        } catch {
            stageTotals.errors += 1
            stageTotals.warnings.append("\(stage.kind.rawValue): \(error.localizedDescription)")
            self.recordSourceReport(IndexSourceRunReport(
                kind: stage.kind,
                scanned: 0,
                indexed: 0,
                errors: 1,
                didRun: true,
                warnings: ["\(stage.kind.rawValue): \(error.localizedDescription)"]
            ))
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
    private func observeConcurrentProgress(index: Int, frame: ToolProgress, startedAt: Date) async {
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
    private func finalizeConcurrentProgress(index: Int, report: IndexSourceRunReport) async {
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

    /// Records one completed source report for the run in flight.
    /// - Parameter report: Stage contribution to retain for the summary.
    private func recordSourceReport(_ report: IndexSourceRunReport) {
        currentSourceReports.append(report)
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
    private func skippedSummary(trigger: IndexRunTrigger, reason: String) -> IndexRunSummary {
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
    private func reportSkipped(trigger: IndexRunTrigger, reason: String) async -> IndexRunSummary {
        // Skipped runs mutate no data, so aggregates stay untouched.
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

extension IndexCoordinator {
    /// Builds the live totals snapshot from the cached counters.
    ///
    /// Single owner for the snapshot shape so the concurrent observer and
    /// the heartbeat cannot drift apart.
    /// - Returns: Totals carrying the current live counters.
    private func liveSnapshot() -> Totals {
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
    private func startHeartbeat(startedAt: Date) -> Task<Void, Never> {
        let intervalNanoseconds = instanceHeartbeatIntervalNanoseconds
        return Task<Void, Never> {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: intervalNanoseconds)
                } catch {
                    break
                }
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
    private func emitHeartbeat(startedAt: Date) async {
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
    private func observeStageProgress(_ frame: ToolProgress, baseScanned: Int, baseIndexed: Int) {
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
    private func emit(phase: IndexPhase, stage: IndexSourceKind? = nil, totals: Totals, startedAt: Date, force: Bool) async {
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
    private func emitFinal(summary: IndexRunSummary, startedAt: Date) async {
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
}

// Run totals, reporting helpers, and the cancellation flag live in IndexCoordinatorSupport.swift.
// Stage factories live in IndexCoordinatorStages.swift.

// Rune Weaver Core — Coordinator owning nightly and on-demand index runs.

import Foundation
import os

// Shared models live in IndexCoordinatorModels.swift; run totals, reporting
// helpers, and the cancellation flag live in IndexCoordinatorSupport.swift.

// MARK: - Coordinator

/// Actor owning nightly and on-demand local index runs.
public actor IndexCoordinator {
    /// Minimum spacing between progress frames (2 Hz), shared with `ToolProgress`.
    static let minimumFrameInterval: TimeInterval = Double(ToolProgress.minimumReportIntervalNanoseconds) / 1_000_000_000
    /// Heartbeat cadence for stalled runs, bypassing the frame floor. A run that makes no progress
    /// still emits a liveness frame on this cadence so a slow IMAP fetch or embedding batch never
    /// looks wedged.
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
    /// Stages currently running, for cancellation propagation. Each stage keeps its own budget,
    /// thermal, and battery gates, so sharing this list never shares effort accounting.
    private var activeStages: [any IndexSourceStage] = []
    /// Completed scanned count observed when the overlap began, anchoring the summed live frame.
    private var overlapBaseScanned = 0
    /// Completed indexed count observed when the overlap began.
    private var overlapBaseIndexed = 0
    /// Per-stage scanned high-water marks feeding the single cumulative live frame. Keyed by the
    /// stage's index in the overlap batch, not by kind, so two stages sharing one kind never
    /// overwrite each other's marks.
    private var overlapScanned: [Int: Int] = [:]
    /// Per-stage indexed high-water marks feeding the single cumulative live frame.
    ///
    /// Keyed by the stage's index in the overlap batch, not by kind.
    private var overlapIndexed: [Int: Int] = [:]
    /// Source kinds in the active overlap batch, in canonical run order.
    private var overlapKinds: [IndexSourceKind] = []
    /// Per-stage vector-chunk high-water marks in the overlap batch.
    private var overlapVectorChunks: [Int: Int] = [:]
    /// Per-stage keyword-chunk high-water marks in the overlap batch.
    private var overlapKeywordChunks: [Int: Int] = [:]
    /// Per-stage latest relative item in the overlap batch.
    private var overlapCurrent: [Int: String] = [:]
    /// Indices of stages in the overlap batch that have finished.
    private var overlapCompleted: Set<Int> = []
    /// Latest per-lane modality queue progress emitted by the files indexer.
    private var liveQueues: [IndexQueueLaneProgress] = []
    /// Handle for the run task in flight, so cancellation aborts in-flight awaits.
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

    /// Creates an index coordinator. config: Index policy; `enabled` gates every
    /// run.
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

    /// Lightweight snapshot of the run in flight, or nil when idle. Reads only the cached live
    /// counters so menu-bar and dashboard polling never touches run state, the document store, or
    /// the watermark.
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
            startedAt: startedAt,
            vectorChunks: liveVectorChunks,
            keywordChunks: liveKeywordChunks,
            sources: currentLiveSources(),
            queues: liveQueues
        )
    }

    /// Updates the live index policy so saved `[index]` values take effect without a restart.
    public func updateConfig(_ newConfig: IndexConfig) {
        config = newConfig
    }

    /// Runs the nightly trigger when it is due.
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
            guard !running, hour > nightlyHour else { return nil }
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

    /// Starts an index pass in the background without awaiting its completion. Returns immediately
    /// (~5ms) with ``IndexStartOutcome`` so callers never hold an idle network connection open
    /// across long-running index passes.
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

        // The child holds the coordinator strongly: a started run must settle (clear `running` and
        // `activeRunTask`, emit the completion broadcast) even when every caller drops the
        // coordinator first.
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
    /// Executes the stage loop for one run. A failing stage is counted and the pass continues;
    /// cancellation stops between batches, leaving committed work for the next run.
    private func performRun(
        trigger: IndexRunTrigger,
        sessionID: UUID,
        eventID: UUID,
        startedAt: Date
    ) async -> IndexRunSummary {
        // Settle single-flight state on every exit path while still on the actor: `performRun`
        // executes on the coordinator's executor (reached via `await self.performRun`), so this sync
        // mutation needs no hop and runs even for fire-and-forget `start` callers that never join.
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
        // Join the heartbeat before the committing frame so a stale wake between the committing
        // emit and clearLiveState cannot re-emit the prior phase after it (phase
        // regression/out-of-order frame).
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
        overlapKinds = []
        overlapVectorChunks = [:]
        overlapKeywordChunks = [:]
        overlapCurrent = [:]
        overlapCompleted = []
        liveQueues = []
    }

    /// Finalizes a run into its summary, watermark, and completion broadcast. - ranAny: Whether any
    /// stage produced work or a counted failure.
    private func finishRun(
        context: FinishRunContext,
        totals: Totals,
        ranAny: Bool
    ) async -> IndexRunSummary {
        let finishedAt = now()
        let cancelled = cancelFlag.isSet || Task.isCancelled
        // Cancelled runs retain partial progress from live counters: in-flight stages cancelled
        // before reporting have contributed frames via `observeStageProgress`, so live high-water
        // marks are folded into terminal totals instead of being dropped.
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
        // Terminal aggregates stay searchable for every mutating run because cancelled passes keep
        // their committed documents; a failed refresh keeps the prior row rather than failing the
        // run, and the single refresh pass replaces the old stats warm read so run end performs.
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
        overlapKinds = []
        overlapVectorChunks = [:]
        overlapKeywordChunks = [:]
        overlapCurrent = [:]
        overlapCompleted = []
        liveQueues = []
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

    /// Runs every enabled stage concurrently when multiple sources are active and merges reports in canonical order.
    private func runEnabledStages(totals: inout Totals, startedAt: Date, policy: IndexConfig) async -> Bool {
        // Selection re-derives every run from the live `policy` snapshot via the single
        // kind-to-flag mapping, so a save applied via `updateConfig` takes effect on the next run
        // with no rebuild; the in-flight snapshot stays fixed for the whole run.
        let enabled = orderedStages.filter { $0.kind.isEnabled(in: policy) }
        let overlapStages = enabled
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
        // save landing mid-overlap cannot split the peers across policies;
        // the next run picks it up instead.
        let runPolicy = policy
        let baseScanned = totals.scanned
        let baseIndexed = totals.indexed
        overlapBaseScanned = baseScanned
        overlapBaseIndexed = baseIndexed
        overlapScanned = [:]
        overlapIndexed = [:]
        overlapKinds = overlapStages.map(\.kind)
        overlapVectorChunks = [:]
        overlapKeywordChunks = [:]
        overlapCurrent = [:]
        overlapCompleted = []
        for index in overlapStages.indices {
            overlapScanned[index] = 0
            overlapIndexed[index] = 0
            overlapVectorChunks[index] = 0
            overlapKeywordChunks[index] = 0
        }
        // Register every peer upfront so a cancel racing stage start still reaches
        // each peer; removal below pops exactly the appended slice so two
        // stages sharing one kind never remove each other.
        let overlapBaseCount = activeStages.count
        activeStages.append(contentsOf: overlapStages)
        livePhase = .extracting
        // Nil stage marks the overlapped group: the single cumulative frame carries
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
        // Join plus summation in canonical order so watermarks and last-item match the serial pass
        // exactly regardless of completion order.
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
        return ranAny
    }

    /// Executes one source stage and folds its report into the running totals.
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
            // Per-run policy seam: every stage builds from the run-entry snapshot, never from a
            // config captured at boot or re-read here, so saved effort, workers, caps, excludes,
            // roots, and windows apply on the next run.
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
            overlapCompleted.insert(index)
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

    /// Folds one overlapped frame into the single cumulative live snapshot. Only the summed frame
    /// is emitted, never the raw peer frame, so polling surfaces observe one stream that matches
    /// serial watermark math.
    private func observeConcurrentProgress(index: Int, frame: ToolProgress, startedAt: Date) async {
        let priorScanned = overlapScanned[index] ?? 0
        let priorIndexed = overlapIndexed[index] ?? 0
        overlapScanned[index] = max(priorScanned, frame.scanned)
        overlapIndexed[index] = max(priorIndexed, frame.matched)
        if let vectorChunks = frame.vectorChunks {
            overlapVectorChunks[index] = max(overlapVectorChunks[index] ?? 0, vectorChunks)
        }
        if let keywordChunks = frame.keywordChunks {
            overlapKeywordChunks[index] = max(overlapKeywordChunks[index] ?? 0, keywordChunks)
        }
        if let queues = frame.queues, !queues.isEmpty {
            liveQueues = queues
        }
        if let current = frame.current {
            liveCurrent = current
            overlapCurrent[index] = current
        }
        let summedScanned = overlapBaseScanned + overlapScanned.values.reduce(0, +)
        let summedIndexed = overlapBaseIndexed + overlapIndexed.values.reduce(0, +)
        let summedVectors = overlapVectorChunks.values.reduce(0, +)
        let summedKeywords = overlapKeywordChunks.values.reduce(0, +)
        if summedScanned > liveScanned {
            liveScanned = summedScanned
        }
        if summedIndexed > liveIndexed {
            liveIndexed = summedIndexed
        }
        if summedVectors > liveVectorChunks {
            liveVectorChunks = summedVectors
        }
        if summedKeywords > liveKeywordChunks {
            liveKeywordChunks = summedKeywords
        }
        await emit(phase: .extracting, stage: nil, totals: liveSnapshot(), startedAt: startedAt, force: false)
    }

    /// Converges one peer's final report into the summed live marks.
    private func finalizeConcurrentProgress(index: Int, report: IndexSourceRunReport) async {
        overlapScanned[index] = max(overlapScanned[index] ?? 0, report.scanned)
        overlapIndexed[index] = max(overlapIndexed[index] ?? 0, report.indexed)
        overlapVectorChunks[index] = max(overlapVectorChunks[index] ?? 0, report.vectorChunks)
        overlapKeywordChunks[index] = max(overlapKeywordChunks[index] ?? 0, report.keywordChunks)
        overlapCompleted.insert(index)
        if let item = report.lastItem {
            liveCurrent = item
            overlapCurrent[index] = item
        }
        let summedScanned = overlapBaseScanned + overlapScanned.values.reduce(0, +)
        let summedIndexed = overlapBaseIndexed + overlapIndexed.values.reduce(0, +)
        let summedVectors = overlapVectorChunks.values.reduce(0, +)
        let summedKeywords = overlapKeywordChunks.values.reduce(0, +)
        if summedScanned > liveScanned {
            liveScanned = summedScanned
        }
        if summedIndexed > liveIndexed {
            liveIndexed = summedIndexed
        }
        if summedVectors > liveVectorChunks {
            liveVectorChunks = summedVectors
        }
        if summedKeywords > liveKeywordChunks {
            liveKeywordChunks = summedKeywords
        }
    }

    /// Records one completed source report for the run in flight.
    /// - Parameter report: Stage contribution to retain for the summary.
    private func recordSourceReport(_ report: IndexSourceRunReport) {
        currentSourceReports.append(report)
    }

    /// Builds a skipped summary for reporting through `reportSkipped`.
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
    /// Builds per-source live progress rows for the active run.
    private func currentLiveSources() -> [IndexLiveSourceProgress] {
        if !overlapKinds.isEmpty {
            return overlapKinds.enumerated().map { index, kind in
                IndexLiveSourceProgress(
                    kind: kind,
                    state: overlapCompleted.contains(index) ? "completed" : "running",
                    scanned: overlapScanned[index] ?? 0,
                    indexed: overlapIndexed[index] ?? 0,
                    current: overlapCurrent[index]
                )
            }
        }
        var rows: [IndexLiveSourceProgress] = currentSourceReports.map { report in
            IndexLiveSourceProgress(
                kind: report.kind,
                state: "completed",
                scanned: report.scanned,
                indexed: report.indexed,
                current: report.lastItem
            )
        }
        if let stage = liveStage, !rows.contains(where: { $0.kind == stage }) {
            let completedScanned = currentSourceReports.reduce(0) { $0 + $1.scanned }
            let completedIndexed = currentSourceReports.reduce(0) { $0 + $1.indexed }
            rows.append(IndexLiveSourceProgress(
                kind: stage,
                state: "running",
                scanned: max(0, liveScanned - completedScanned),
                indexed: max(0, liveIndexed - completedIndexed),
                current: liveCurrent
            ))
        }
        return rows
    }

    /// Builds the live totals snapshot from the cached counters.
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
    private func emitHeartbeat(startedAt: Date) async {
        guard running, let phase = livePhase else { return }
        await emit(phase: phase, stage: liveStage, totals: liveSnapshot(), startedAt: startedAt, force: true)
    }

    /// Folds one stage progress frame into the cached live counters. The cached values only move
    /// forward so a late or duplicate frame never rewinds the snapshot or a heartbeat derived from
    /// it.
    private func observeStageProgress(_ frame: ToolProgress, baseScanned: Int, baseIndexed: Int) {
        let cumulativeScanned = baseScanned + frame.scanned
        let cumulativeIndexed = baseIndexed + frame.matched
        if cumulativeScanned > liveScanned {
            liveScanned = cumulativeScanned
        }
        if cumulativeIndexed > liveIndexed {
            liveIndexed = cumulativeIndexed
        }
        if let vectorChunks = frame.vectorChunks, vectorChunks > liveVectorChunks {
            liveVectorChunks = vectorChunks
        }
        if let keywordChunks = frame.keywordChunks, keywordChunks > liveKeywordChunks {
            liveKeywordChunks = keywordChunks
        }
        if let queues = frame.queues, !queues.isEmpty {
            liveQueues = queues
        }
        if let current = frame.current {
            liveCurrent = current
        }
    }

    /// Emits a phase frame, honoring the shared 2 Hz cadence unless forced. phase:
    /// Phase being reported.
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

    /// Emits the terminal progress frame for a finished run. summary: Completed run
    /// summary.
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

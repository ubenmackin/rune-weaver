// Rune Weaver Core Tests — Index coordinator sequencing, cancellation, and watermark behavior.
//
// Drives the coordinator against deterministic closure-backed source stages so
// the tests observe ordering, liveness frames, run lifecycle reporting, and the
// persisted watermark without touching a mailbox, the Messages database, or a
// real home directory. Cancel-and-resume proves that committed work survives an
// interrupted pass and the next run picks up where it stopped.

import Foundation
@testable import RuneWeaverCore
import Testing

// MARK: - Fixtures

/// Records the source order stages are invoked in.
private actor IndexStageCallRecorder {
    /// Kinds observed in call order.
    private var kinds: [IndexSourceKind] = []

    /// Records one invoked stage.
    /// - Parameter kind: Source kind that ran.
    func record(_ kind: IndexSourceKind) {
        kinds.append(kind)
    }

    /// Returns the observed kinds.
    /// - Returns: Kinds in call order.
    func snapshot() -> [IndexSourceKind] {
        kinds
    }
}

/// Records run lifecycle events delivered through the reporting seam.
private actor IndexRunEventRecorder: IndexRunReporting {
    /// Start events observed.
    private var started: [IndexRunEvent] = []
    /// Completion events observed.
    private var completed: [IndexRunEvent] = []

    /// Records a start event.
    /// - Parameter event: Start event.
    func runStarted(_ event: IndexRunEvent) async {
        started.append(event)
    }

    /// Records a completion event.
    /// - Parameter event: Completion event.
    func runCompleted(_ event: IndexRunEvent) async {
        completed.append(event)
    }

    /// Returns observed start events.
    /// - Returns: Start events in call order.
    func startedEvents() -> [IndexRunEvent] {
        started
    }

    /// Returns observed completion events.
    /// - Returns: Completion events in call order.
    func completedEvents() -> [IndexRunEvent] {
        completed
    }
}

/// Records liveness frames emitted over the progress path.
private actor IndexProgressRecorder {
    /// Frames observed in emission order.
    private var reports: [ToolProgress] = []

    /// Records one frame.
    /// - Parameter progress: Frame emitted by the coordinator.
    func record(_ progress: ToolProgress) {
        reports.append(progress)
    }

    /// Returns the observed frames.
    /// - Returns: Frames in emission order.
    func snapshot() -> [ToolProgress] {
        reports
    }
}

/// Tracks committed item identifiers so a resume can prove nothing replayed.
private actor IndexResumeLedger {
    /// Item identifiers already committed.
    private var committed: Set<Int> = []

    /// Commits one item.
    /// - Parameter item: Item identifier.
    /// - Returns: True when the item had not been committed before.
    func commit(_ item: Int) -> Bool {
        committed.insert(item).inserted
    }

    /// Number of committed items.
    /// - Returns: Committed count.
    func committedCount() -> Int {
        committed.count
    }
}

/// Records the per-run policy snapshots stage bodies observe.
private actor IndexPolicyRecorder {
    /// Effort tokens observed in invocation order.
    private var efforts: [String] = []
    /// Source flags observed in invocation order.
    private var filesFlags: [Bool] = []
    /// Whether the in-flight body has started.
    private var started = false

    /// Records one observed effort token.
    /// - Parameter effort: Effort preset from the per-run snapshot.
    func recordEffort(_ effort: String) {
        efforts.append(effort)
    }

    /// Records one observed files flag.
    /// - Parameter enabled: Files toggle from the per-run snapshot.
    func recordFilesFlag(_ enabled: Bool) {
        filesFlags.append(enabled)
    }

    /// Marks the in-flight body as started.
    func markStarted() {
        started = true
    }

    /// Whether the body has started.
    /// - Returns: True once the body marked start.
    func isStarted() -> Bool {
        started
    }

    /// Returns observed efforts.
    /// - Returns: Efforts in invocation order.
    func effortSnapshot() -> [String] {
        efforts
    }

    /// Returns observed files flags.
    /// - Returns: Flags in invocation order.
    func filesFlagSnapshot() -> [Bool] {
        filesFlags
    }
}

/// Holds the coordinator so a running stage can request its own cancellation.
private actor IndexCoordinatorHolder {
    /// Coordinator under test.
    private var coordinator: IndexCoordinator?
    /// Whether cancellation has already been requested once.
    private var didRequestCancel = false

    /// Publishes the coordinator.
    /// - Parameter coordinator: Coordinator to hold.
    func set(_ coordinator: IndexCoordinator) {
        self.coordinator = coordinator
    }

    /// Requests cancellation of the held coordinator at most once.
    func requestCancelOnce() async {
        guard !didRequestCancel else { return }
        didRequestCancel = true
        await coordinator?.cancel()
    }
}

/// Tracks simultaneous stage entries to prove files plus mail overlap.
///
/// Each overlapped body holds the window open with a short sleep while
/// registered as active; a serial pass never exceeds one entrant while an
/// overlapped pass observes two, without relying on wall-clock bounds that
/// flake on loaded runners.
private actor IndexOverlapProbe {
    /// Currently entered stages.
    private var active = 0
    /// Highest simultaneous entry observed.
    private var maxSeen = 0

    /// Marks one stage entered.
    func enter() {
        active += 1
        maxSeen = max(maxSeen, active)
    }

    /// Marks one stage exited.
    func exit() {
        active -= 1
    }

    /// Returns the highest simultaneous entry observed.
    /// - Returns: Maximum concurrent entrants.
    func maxObserved() -> Int {
        maxSeen
    }
}

/// Records per-run budget snapshots to prove peers stay isolated.
///
/// Both overlapped peers receive the same policy snapshot and enforce their
/// own caps from it; sharing would halve or serialize the counts, so
/// observing the full value in both bodies proves isolation.
private actor IndexBudgetRecorder {
    /// Budgets observed in invocation order.
    private var budgets: [Int] = []

    /// Records one observed budget.
    /// - Parameter budget: Nightly budget from the per-run snapshot.
    func record(_ budget: Int) {
        budgets.append(budget)
    }

    /// Returns the observed budgets.
    /// - Returns: Budgets in invocation order.
    func snapshot() -> [Int] {
        budgets
    }
}

/// Creates an isolated temporary directory.
/// - Returns: The created directory.
private func makeIndexTemporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("runeweaver-indexcoordinator-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("Index Coordinator")
struct IndexCoordinatorTests {
    @Test
    func `Disabled indexer is a no-op`() async {
        let calls = IndexStageCallRecorder()
        let events = IndexRunEventRecorder()
        let stage = IndexClosureStage(kind: .files, isEnabled: true) { _, _, _ in
            await calls.record(.files)
            return IndexSourceRunReport(kind: .files, indexed: 1)
        }
        let coordinator = IndexCoordinator(
            config: IndexConfig(enabled: false, files: true, roots: []),
            stages: [stage],
            reporter: events
        )

        let summary = await coordinator.run()

        #expect(summary.status == .skipped)
        #expect(summary.skippedReason != nil)
        let recorded = await calls.snapshot()
        #expect(recorded.isEmpty)
        // Skipped runs still persist one `run_logs` row (start plus terminal
        // `skipped` completion) so the kind-filtered latest-run lookup
        // observes every run and the strip agrees with the run notice.
        let started = await events.startedEvents()
        let completed = await events.completedEvents()
        #expect(started.count == 1)
        #expect(completed.count == 1)
        #expect(completed.first?.status == .skipped)
        #expect(completed.first?.sessionID == summary.sessionID)
        #expect(completed.first?.response?.contains("Skipped:") == true)

        let nightly = await coordinator.fireNightly(now: Date())
        #expect(nightly == nil)
    }

    @Test
    func `Sources run in canonical order regardless of declaration order`() async {
        let directory = makeIndexTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let calls = IndexStageCallRecorder()
        let stateStore = IndexRunStateStore(path: directory.appendingPathComponent("state.json").path)

        func staged(_ kind: IndexSourceKind) -> IndexClosureStage {
            IndexClosureStage(kind: kind, isEnabled: true) { _, _, _ in
                await calls.record(kind)
                return IndexSourceRunReport(kind: kind)
            }
        }

        let coordinator = IndexCoordinator(
            config: IndexConfig(
                enabled: true,
                files: true,
                mail: true,
                messages: true,
                roots: [],
                describeImagesWithLLM: true
            ),
            stages: [staged(.messages), staged(.vision), staged(.files), staged(.mail)],
            stateStore: stateStore
        )

        let summary = await coordinator.run()

        #expect(summary.status == .ok)
        let recorded = await calls.snapshot()
        // Files plus mail overlap, so their start order races while trailing
        // stages stay sequential after the join in canonical order.
        #expect(recorded.count == 4)
        #expect(Set(recorded.prefix(2)) == [.files, .mail])
        #expect(Array(recorded.suffix(2)) == [.messages, .vision])
    }

    @Test
    func `Cancel stops between batches and a resume completes the run`() async {
        let directory = makeIndexTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let total = 5
        let ledger = IndexResumeLedger()
        let holder = IndexCoordinatorHolder()
        let progressRecorder = IndexProgressRecorder()
        let stateStore = IndexRunStateStore(path: directory.appendingPathComponent("state.json").path)
        let stage = IndexClosureStage(kind: .files, isEnabled: true) { _, reporter, isCancelled in
            var committed = 0
            for item in 0 ..< total {
                if isCancelled() {
                    break
                }
                if await ledger.commit(item) {
                    committed += 1
                }
                await reporter(ToolProgress(
                    message: "Indexing files",
                    scanned: item + 1,
                    matched: committed
                ))
                // Stop deterministically once the first item is committed, so the
                // resume below proves committed work was never replayed.
                if committed == 1 {
                    await holder.requestCancelOnce()
                }
            }
            return IndexSourceRunReport(kind: .files, scanned: total, indexed: committed)
        }
        let coordinator = IndexCoordinator(
            config: IndexConfig(enabled: true, files: true, roots: []),
            stages: [stage],
            stateStore: stateStore,
            progress: { await progressRecorder.record($0) }
        )
        await holder.set(coordinator)

        let first = await coordinator.run()

        #expect(first.status == .cancelled)
        #expect(first.documentsIndexed == 1)
        #expect(first.indexAsOf == nil)

        let second = await coordinator.run()

        #expect(second.status == .ok)
        #expect(first.documentsIndexed + second.documentsIndexed == total)
        let committed = await ledger.committedCount()
        #expect(committed == total)
        let frames = await progressRecorder.snapshot()
        #expect(!frames.isEmpty)
    }

    @Test
    func `Cancel interrupts a slow batch within one batch`() async {
        // Staged double with a slow cancellable batch per item, standing in for
        // an IMAP fetch, an embedding batch, or a vision turn: each batch awaits
        // a cancellable sleep so task cancellation throws at the next checkpoint
        // instead of running to stage end.
        let stage = IndexClosureStage(kind: .files, isEnabled: true) { _, _, isCancelled in
            var report = IndexSourceRunReport(kind: .files)
            for _ in 0 ..< 5 {
                if isCancelled() {
                    break
                }
                // Cancellable work: the run task cancel aborts this sleep
                // immediately, bounding overrun to the batch in flight.
                try await Task.sleep(nanoseconds: 500_000_000)
                report.scanned += 1
                report.indexed += 1
            }
            return report
        }
        let coordinator = IndexCoordinator(
            config: IndexConfig(enabled: true, files: true, roots: []),
            stages: [stage]
        )
        let runTask = Task { await coordinator.run() }
        // Let the first batch start, then cancel mid-run.
        try? await Task.sleep(nanoseconds: 100_000_000)
        await coordinator.cancel()
        let summary = await runTask.value

        #expect(summary.status == .cancelled)
        #expect(summary.documentsIndexed < 5)
        #expect(summary.indexAsOf == nil)
        // No wall-clock bound: task cancellation already bounds the overrun to
        // the batch in flight, and elapsed assertions false-fail on slow CI.
        // Partial progress plus the cancelled status is the deterministic proof
        // the run stopped early instead of draining every batch.
    }

    @Test
    func `Nightly trigger selects nightly at the hour and catch-up later the same day`() async {
        let calendar = Calendar.current
        let nightlyHour = 3
        let startOfDay = calendar.startOfDay(for: Date())
        let nightlyDate = startOfDay.addingTimeInterval(TimeInterval(nightlyHour * 3600 + 5 * 60))
        let catchUpDate = startOfDay.addingTimeInterval(TimeInterval((nightlyHour + 2) * 3600 + 7 * 60))
        // A fire before the nightly hour never runs, independent of the same-day guard.
        let beforeDate = startOfDay.addingTimeInterval(TimeInterval(max(0, nightlyHour - 1) * 3600))

        func makeCoordinator(statePath: String, events: IndexRunEventRecorder) -> IndexCoordinator {
            let stage = IndexClosureStage(kind: .files, isEnabled: true) { _, _, _ in
                IndexSourceRunReport(kind: .files)
            }
            return IndexCoordinator(
                config: IndexConfig(enabled: true, files: true, roots: []),
                stages: [stage],
                stateStore: IndexRunStateStore(path: statePath),
                reporter: events,
                nightlyHour: nightlyHour
            )
        }

        // Firing at the nightly hour selects the nightly trigger.
        let nightlyDirectory = makeIndexTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: nightlyDirectory) }
        let nightlyEvents = IndexRunEventRecorder()
        let nightlyCoordinator = makeCoordinator(
            statePath: nightlyDirectory.appendingPathComponent("state.json").path,
            events: nightlyEvents
        )
        #expect(await nightlyCoordinator.fireNightly(now: beforeDate) == nil)
        let nightlySummary = await nightlyCoordinator.fireNightly(now: nightlyDate)
        #expect(nightlySummary?.trigger == .nightly)
        #expect(IndexRunTrigger.catchUp.rawValue == "catchUp")
        let nightlyStarted = await nightlyEvents.startedEvents()
        #expect(nightlyStarted.first?.trigger == .nightly)

        // A later same-day launch with fresh state selects the catch-up trigger,
        // and a second same-day fire is a no-op under the same-day guard.
        let catchUpDirectory = makeIndexTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: catchUpDirectory) }
        let catchUpEvents = IndexRunEventRecorder()
        let catchUpCoordinator = makeCoordinator(
            statePath: catchUpDirectory.appendingPathComponent("state.json").path,
            events: catchUpEvents
        )
        let catchUpSummary = await catchUpCoordinator.fireNightly(now: catchUpDate)
        #expect(catchUpSummary?.trigger == .catchUp)
        let catchUpStarted = await catchUpEvents.startedEvents()
        #expect(catchUpStarted.first?.trigger == .catchUp)
        #expect(catchUpStarted.first?.message.contains(IndexRunTrigger.catchUp.rawValue) == true)
        let second = await catchUpCoordinator.fireNightly(now: catchUpDate.addingTimeInterval(60))
        #expect(second == nil)
    }

    @Test
    func `Successful run records stats, events, and the index watermark`() async throws {
        let directory = makeIndexTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DocIndexStore(dbPath: directory.appendingPathComponent("docindex.db").path)
        let stateStore = IndexRunStateStore(path: directory.appendingPathComponent("state.json").path)
        let events = IndexRunEventRecorder()
        let progressRecorder = IndexProgressRecorder()

        let stage = IndexClosureStage(kind: .files, isEnabled: true) { _, _, _ in
            for index in 0 ..< 2 {
                let document = IndexedDocument(
                    source: .files,
                    externalID: "file-\(index)",
                    displayName: "file-\(index)",
                    contentHash: "hash-\(index)"
                )
                let stored = try await store.upsertDocument(document)
                _ = try await store.upsertChunks(
                    documentID: stored.id,
                    chunks: [IndexedChunk(documentID: stored.id, ordinal: 0, text: "body \(index)")]
                )
            }
            return IndexSourceRunReport(kind: .files, scanned: 2, indexed: 2, vectorChunks: 1, keywordChunks: 1)
        }
        let coordinator = IndexCoordinator(
            config: IndexConfig(enabled: true, files: true, roots: []),
            stages: [stage],
            store: store,
            stateStore: stateStore,
            reporter: events,
            progress: { await progressRecorder.record($0) }
        )

        let summary = await coordinator.run()

        #expect(summary.status == .ok)
        #expect(summary.documentsIndexed == 2)
        #expect(summary.vectorChunks == 1)
        #expect(summary.keywordChunks == 1)
        #expect(summary.indexAsOf != nil)

        let stats = try await store.stats()
        #expect(stats.documents == 2)

        let state = await stateStore.snapshot()
        #expect(state.indexAsOf != nil)
        #expect(state.lastCompletedAt != nil)

        let started = await events.startedEvents()
        let completed = await events.completedEvents()
        #expect(started.count == 1)
        #expect(completed.count == 1)
        #expect(started.first?.status == .running)
        #expect(completed.first?.status == .ok)
        #expect(started.first?.sessionID == completed.first?.sessionID)

        let messages = await progressRecorder.snapshot().map(\.message)
        #expect(messages.contains { $0.contains("discovering") })
        #expect(messages.contains { $0.contains("extracting") })
        #expect(messages.contains { $0.contains("committing") })
        #expect(messages.contains { $0.contains("docs/s") })
    }

    @Test
    func `Heartbeat arrives on stalled stage and totals stay monotonic`() async {
        // Stalled double: one interim frame carrying a relative current item,
        // then a stall just past the 2s heartbeat cadence with no further
        // stage frames. The coordinator heartbeat must still emit with the
        // same cumulative totals, current item, and phase/stage tokens. The
        // stall stays just over one heartbeat interval so the suite stays fast,
        // and the elapsed window stays wide so loaded CI never flakes on a
        // late wake.
        let progressRecorder = IndexProgressRecorder()
        let stage = IndexClosureStage(kind: .files, isEnabled: true) { _, reporter, _ in
            await reporter(ToolProgress(
                message: "Indexing files",
                scanned: 1,
                matched: 0,
                current: "notes/report.md"
            ))
            try await Task.sleep(nanoseconds: 2_500_000_000)
            return IndexSourceRunReport(kind: .files, scanned: 2, indexed: 1, lastItem: "notes/report.md")
        }
        let coordinator = IndexCoordinator(
            config: IndexConfig(enabled: true, files: true, roots: []),
            stages: [stage],
            progress: { await progressRecorder.record($0) }
        )

        let summary = await coordinator.run()

        #expect(summary.status == .ok)
        #expect(summary.scanned == 2)
        #expect(summary.documentsIndexed == 1)
        let frames = await progressRecorder.snapshot()
        // Discovering, extracting, interim, heartbeat, committing, final.
        #expect(frames.count >= 5)
        // Totals never rewind, including the repeated heartbeat totals.
        // Elapsed is intentionally unchecked here: stage frames carry their
        // own per-stage clock while coordinator frames carry run elapsed.
        for index in 1 ..< frames.count {
            #expect(frames[index].scanned >= frames[index - 1].scanned)
            #expect(frames[index].matched >= frames[index - 1].matched)
        }
        // The heartbeat reuses the coordinator emit path: phase plus stage
        // tokens, docs/s rate, cumulative counts, and the relative current
        // item, bypassing the floor despite unchanged totals.
        let heartbeats = frames.filter { frame in
            frame.message.contains("extracting")
                && frame.message.contains("files")
                && frame.message.contains("docs/s")
                && frame.current == "notes/report.md"
                && frame.scanned == 1
                && frame.matched == 0
                && frame.elapsedMs >= 1000
                && frame.elapsedMs < 6000
        }
        #expect(!heartbeats.isEmpty)
    }

    @Test
    func `Live snapshot reflects in-flight run and clears on settle`() async {
        let progressRecorder = IndexProgressRecorder()
        let stage = IndexClosureStage(kind: .files, isEnabled: true) { _, _, _ in
            try await Task.sleep(nanoseconds: 1_500_000_000)
            return IndexSourceRunReport(kind: .files, scanned: 1, indexed: 1, lastItem: "notes/report.md")
        }
        let coordinator = IndexCoordinator(
            config: IndexConfig(enabled: true, files: true, roots: []),
            stages: [stage],
            progress: { await progressRecorder.record($0) }
        )

        #expect(await coordinator.liveTotals == nil)
        let runTask = Task { await coordinator.run(trigger: .onDemand) }
        try? await Task.sleep(nanoseconds: 400_000_000)
        let snapshot = await coordinator.liveTotals
        #expect(await coordinator.isRunning == true)
        #expect(snapshot != nil)
        #expect(snapshot?.trigger == .onDemand)
        #expect(snapshot?.phase == .extracting)
        #expect(snapshot?.stage == .files)
        #expect((snapshot?.elapsedMs ?? 0) > 0)
        #expect(snapshot?.startedAt != nil)
        let summary = await runTask.value
        #expect(summary.status == .ok)
        #expect(summary.trigger == .onDemand)
        #expect(snapshot?.startedAt == summary.startedAt)
        #expect(await coordinator.isRunning == false)
        #expect(await coordinator.liveTotals == nil)
    }

    @Test
    func `Stage body observes saved effort on the next run without rebuilt stages`() async {
        // Saving a new effort preset must change the workers the next run
        // resolves without rebuilding stages: the body reads only the
        // coordinator-supplied snapshot, never a boot-captured config.
        let recorder = IndexPolicyRecorder()
        let stage = IndexClosureStage(kind: .files, isEnabled: true) { policy, _, _ in
            await recorder.recordEffort(policy.effort)
            // Resolved workers prove the preset actually changed the
            // execution shape, not just the stored string.
            let workers = policy.resolvedWorkerCount(cores: 8)
            return IndexSourceRunReport(kind: .files, scanned: 1, indexed: 1, vectorChunks: workers)
        }
        let coordinator = IndexCoordinator(
            config: IndexConfig(enabled: true, files: true, roots: [], effort: "light"),
            stages: [stage]
        )

        let first = await coordinator.run()
        #expect(first.status == .ok)
        #expect(first.vectorChunks == IndexConfig(effort: "light").resolvedWorkerCount(cores: 8))

        await coordinator.updateConfig(IndexConfig(enabled: true, files: true, roots: [], effort: "performance"))

        let second = await coordinator.run()
        #expect(second.status == .ok)
        #expect(second.vectorChunks == IndexConfig(effort: "performance").resolvedWorkerCount(cores: 8))
        #expect(first.vectorChunks != second.vectorChunks)

        let efforts = await recorder.effortSnapshot()
        #expect(efforts == ["light", "performance"])
    }

    @Test
    func `In-flight run keeps its snapshot across a mid-run save`() async {
        // A save landing while a stage is in flight must not rewrite the
        // snapshot the body was invoked with; the fresh policy applies only
        // to the following run.
        let recorder = IndexPolicyRecorder()
        let stage = IndexClosureStage(kind: .files, isEnabled: true) { policy, _, _ in
            await recorder.markStarted()
            // Hold the run open long enough for the save below to land
            // mid-flight, then record the invocation snapshot.
            try? await Task.sleep(nanoseconds: 600_000_000)
            await recorder.recordEffort(policy.effort)
            return IndexSourceRunReport(kind: .files, scanned: 1, indexed: 1)
        }
        let coordinator = IndexCoordinator(
            config: IndexConfig(enabled: true, files: true, roots: [], effort: "light"),
            stages: [stage]
        )

        let runTask = Task { await coordinator.run(trigger: .onDemand) }
        // Wait for the body to start rather than sleeping a fixed window, so
        // the save below always lands mid-flight even on loaded CI.
        for _ in 0 ..< 100 {
            if await recorder.isStarted() {
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(await recorder.isStarted())
        await coordinator.updateConfig(IndexConfig(enabled: true, files: true, roots: [], effort: "performance"))
        let inFlight = await runTask.value
        #expect(inFlight.status == .ok)

        // The in-flight body kept the light snapshot despite the mid-run save.
        let during = await recorder.effortSnapshot()
        #expect(during == ["light"])

        // The very next run picks up the saved preset with no rebuilt stages.
        let next = await coordinator.run()
        #expect(next.status == .ok)
        let after = await recorder.effortSnapshot()
        #expect(after == ["light", "performance"])
    }

    @Test
    func `Disabled source skips while enabled source needs rebuilt stages`() async {
        // Disabling after boot reports skipped through the per-run policy
        // guard, while enabling after boot stays parked because selection was
        // frozen at boot and only a rebuild introduces the new stage.
        let recorder = IndexPolicyRecorder()
        let calls = IndexStageCallRecorder()
        let filesStage = IndexClosureStage(kind: .files, isEnabled: true) { policy, _, _ in
            await recorder.recordFilesFlag(policy.files)
            guard policy.enabled, policy.files else {
                return IndexSourceRunReport(
                    kind: .files,
                    didRun: false,
                    skippedReason: "File indexing is disabled in [index]."
                )
            }
            return IndexSourceRunReport(kind: .files, scanned: 1, indexed: 1)
        }
        // Boot-disabled: simulates a source turned on after boot without a
        // rebuild, so the coordinator never executes it.
        let mailStage = IndexClosureStage(kind: .mail, isEnabled: false) { _, _, _ in
            await calls.record(.mail)
            return IndexSourceRunReport(kind: .mail, scanned: 1, indexed: 1)
        }
        let coordinator = IndexCoordinator(
            config: IndexConfig(enabled: true, files: true, mail: false, roots: []),
            stages: [filesStage, mailStage]
        )

        await coordinator.updateConfig(IndexConfig(enabled: true, files: false, mail: true, roots: []))
        let summary = await coordinator.run()

        #expect(summary.status == .ok)
        // The files body ran but honored the live disable as a skip.
        let flags = await recorder.filesFlagSnapshot()
        #expect(flags == [false])
        #expect(summary.scanned == 0)
        #expect(summary.documentsIndexed == 0)
        // The mail body never ran despite the live enable: rebuilt stages
        // are still required to introduce a newly enabled source.
        let observed = await calls.snapshot()
        #expect(observed.isEmpty)
    }

    @Test
    func `Files plus mail overlap concurrently`() async {
        // Disk-bound files and network-bound mail finish near the slower peer
        // instead of the serial sum; simultaneous entry proves the overlap
        // without wall-clock bounds that flake on loaded runners.
        let probe = IndexOverlapProbe()
        func staged(_ kind: IndexSourceKind) -> IndexClosureStage {
            IndexClosureStage(kind: kind, isEnabled: true) { _, _, _ in
                await probe.enter()
                // Hold the window open so the peer can arrive before either exits.
                try? await Task.sleep(nanoseconds: 300_000_000)
                await probe.exit()
                return IndexSourceRunReport(kind: kind, scanned: 1, indexed: 1)
            }
        }
        let coordinator = IndexCoordinator(
            config: IndexConfig(enabled: true, files: true, mail: true, roots: []),
            stages: [staged(.files), staged(.mail)]
        )

        let summary = await coordinator.run()

        #expect(summary.status == .ok)
        #expect(summary.scanned == 2)
        #expect(summary.documentsIndexed == 2)
        #expect(await probe.maxObserved() == 2)
    }

    @Test
    func `Overlap sums totals and keeps live frames monotonic`() async {
        // Each peer reports its own cumulative counts; the coordinator emits
        // one summed stream so polling surfaces never rewind when frames
        // interleave, and the terminal totals match the serial watermark math.
        let progressRecorder = IndexProgressRecorder()
        let filesStage = IndexClosureStage(kind: .files, isEnabled: true) { _, reporter, _ in
            await reporter(ToolProgress(message: "Indexing files", scanned: 2, matched: 1, current: "a.md"))
            try? await Task.sleep(nanoseconds: 100_000_000)
            await reporter(ToolProgress(message: "Indexing files", scanned: 3, matched: 2, current: "b.md"))
            return IndexSourceRunReport(kind: .files, scanned: 3, indexed: 2, lastItem: "b.md")
        }
        let mailStage = IndexClosureStage(kind: .mail, isEnabled: true) { _, reporter, _ in
            await reporter(ToolProgress(message: "Indexing mail", scanned: 4, matched: 3, current: "inbox/1"))
            try? await Task.sleep(nanoseconds: 150_000_000)
            await reporter(ToolProgress(message: "Indexing mail", scanned: 5, matched: 4, current: "inbox/2"))
            return IndexSourceRunReport(kind: .mail, scanned: 5, indexed: 4, lastItem: "inbox/2")
        }
        let coordinator = IndexCoordinator(
            config: IndexConfig(enabled: true, files: true, mail: true, roots: []),
            stages: [filesStage, mailStage],
            progress: { await progressRecorder.record($0) }
        )

        let summary = await coordinator.run()

        #expect(summary.status == .ok)
        #expect(summary.scanned == 8)
        #expect(summary.documentsIndexed == 6)
        let frames = await progressRecorder.snapshot()
        #expect(!frames.isEmpty)
        for index in 1 ..< frames.count {
            #expect(frames[index].scanned >= frames[index - 1].scanned)
            #expect(frames[index].matched >= frames[index - 1].matched)
        }
        #expect(frames.last?.scanned == 8)
        #expect(frames.last?.matched == 6)
    }

    @Test
    func `Cancel reaches both overlapped stages`() async {
        // A cancel racing the overlap must stop each peer within its current
        // batch; pre-registering both peers keeps a start race from hiding one.
        let started = IndexStageCallRecorder()
        let cancelled = IndexStageCallRecorder()
        func staged(_ kind: IndexSourceKind) -> IndexClosureStage {
            IndexClosureStage(
                kind: kind,
                isEnabled: true,
                onCancel: { await cancelled.record(kind) }
            ) { _, _, isCancelled in
                await started.record(kind)
                var done = 0
                for _ in 0 ..< 10 {
                    if isCancelled() {
                        break
                    }
                    // Cancellable batch: the run-task cancel aborts this sleep
                    // inside the batch instead of draining every iteration.
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    if isCancelled() {
                        break
                    }
                    done += 1
                }
                return IndexSourceRunReport(kind: kind, scanned: done, indexed: done)
            }
        }
        let coordinator = IndexCoordinator(
            config: IndexConfig(enabled: true, files: true, mail: true, roots: []),
            stages: [staged(.files), staged(.mail)]
        )
        let runTask = Task { await coordinator.run() }
        // Wait for both peers to enter rather than a fixed window, so the
        // cancel below always lands mid-overlap even on loaded CI.
        for _ in 0 ..< 200 {
            let seen = await started.snapshot()
            if seen.contains(.files), seen.contains(.mail) {
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let seen = await started.snapshot()
        #expect(seen.contains(.files))
        #expect(seen.contains(.mail))
        await coordinator.cancel()
        let summary = await runTask.value

        #expect(summary.status == .cancelled)
        let stopped = await cancelled.snapshot()
        #expect(stopped.contains(.files))
        #expect(stopped.contains(.mail))
        #expect(summary.documentsIndexed < 20)
    }

    @Test
    func `Overlapped stages observe isolated per-source budgets`() async {
        // Both peers read the same snapshot yet enforce their own caps; a
        // shared counter would halve the work, so summed full caps prove
        // isolation while keeping thermal plus battery gates inside indexers.
        let budgets = IndexBudgetRecorder()
        func staged(_ kind: IndexSourceKind) -> IndexClosureStage {
            IndexClosureStage(kind: kind, isEnabled: true) { policy, _, _ in
                await budgets.record(policy.nightlyBudget)
                return IndexSourceRunReport(kind: kind, scanned: policy.nightlyBudget, indexed: policy.nightlyBudget)
            }
        }
        let coordinator = IndexCoordinator(
            config: IndexConfig(enabled: true, files: true, mail: true, roots: [], nightlyBudget: 7),
            stages: [staged(.files), staged(.mail)]
        )

        let summary = await coordinator.run()

        #expect(summary.status == .ok)
        #expect(summary.scanned == 14)
        #expect(summary.documentsIndexed == 14)
        let observed = await budgets.snapshot()
        #expect(observed.count == 2)
        #expect(observed.allSatisfy { $0 == 7 })
    }
}

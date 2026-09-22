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
        let stage = IndexClosureStage(kind: .files, isEnabled: true) { _, _ in
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
        let started = await events.startedEvents()
        let completed = await events.completedEvents()
        #expect(started.isEmpty)
        #expect(completed.isEmpty)

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
            IndexClosureStage(kind: kind, isEnabled: true) { _, _ in
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
        #expect(recorded == [.files, .mail, .messages, .vision])
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
        let stage = IndexClosureStage(kind: .files, isEnabled: true) { reporter, isCancelled in
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
    func `Successful run records stats, events, and the index watermark`() async throws {
        let directory = makeIndexTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DocIndexStore(dbPath: directory.appendingPathComponent("docindex.db").path)
        let stateStore = IndexRunStateStore(path: directory.appendingPathComponent("state.json").path)
        let events = IndexRunEventRecorder()
        let progressRecorder = IndexProgressRecorder()

        let stage = IndexClosureStage(kind: .files, isEnabled: true) { _, _ in
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
}

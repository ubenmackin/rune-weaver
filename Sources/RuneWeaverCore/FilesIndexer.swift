// Rune Weaver Core — Local files indexer feeding the document index.
//
// Walks the configured roots once per run, prunes excluded trees (media
// libraries, VCS and dependency output, caches, and the app's own state), and
// refuses symlinked entries so a link loop or a link out of policy can never be
// traversed. Evicted iCloud files honor `IndexConfig.iCloudEvicted`: skipped by
// default and downloaded only under the `download` policy.
// A stored size-plus-mtime fingerprint skips unchanged files before any bytes
// are read; the remaining candidates are hashed, skipped when `DocIndexStore`
// reports the stored body is current, then extracted and written as one
// document plus its chunks, with vectors attached only while the document stays
// inside the vector policy.
//
// The indexer owns no path policy of its own beyond the walk shape: deny/allow
// decisions arrive through the `FilesIndexAccessGuard` seam (the shared
// `[files]` guard is adapted to it in the tools layer), and the embeddings
// backend is injected so a keyword-only run and a vector run share one code
// path. A run is cancellable between files and each file commits its document
// and chunks before the next begins, so a cancelled run resumes from the first
// unfinished file instead of replaying the whole tree. `nightly_budget` bounds
// newly written documents per run. File contents are never logged and never
// leave the machine through anything but the configured embeddings backend.
//
// Higher effort presets fan per-file bodies out over a bounded task group of
// at most the resolved worker count: discovery stays sequential so pruning
// and skip totals match the single-worker walk, while reads, extraction,
// embedding, and store commits overlap with one pooled embeddings backend per
// worker at utility quality of service. The document store remains an actor
// so concurrent commits serialize naturally, the nightly budget lives in an
// actor-isolated counter so parallel finishers cannot overshoot it, and
// per-file commits still preserve cancel and resume. Gains are sublinear by
// design because the underlying Accelerate engine is already internally
// threaded; extra workers mainly overlap I/O, extraction, and writes.

import CryptoKit
import Foundation

// MARK: - Indexer

/// Actor that walks configured roots and maintains the local files index.
///
/// One actor owns a run so cancellation and counters stay serialized. Every
/// dependency that touches the outside world — the document store, the text
/// extractor, the path policy, and the embeddings backend — is injected, so the
/// walker is exercised against fixtures without a real home directory.
public actor FilesIndexer {
    /// Directory and file names the files walker always skips, before `IndexConfig.exclude`.
    ///
    /// Media libraries are excluded because the index is for documents, not
    /// media; VCS, dependency, and cache trees are excluded because their
    /// contents are machine output; and `.runeweaver` is excluded so the index
    /// never indexes its own database or logs. Agent scratch stays excluded
    /// through a scoped `.runeweaver/workspace` path-prefix check in
    /// `isExcluded` (plus `walkDisposition`), not through a bare `workspace`
    /// entry here, so user trees like `~/projects/workspace/` and files named
    /// `workspace` stay indexable while scratch never enters recall.
    /// Named distinctly from
    /// `IndexConfig.defaultExcludePatterns` (the editable exclude-editor seed)
    /// so the unconditional prune list cannot be confused with user configuration.
    public static let alwaysSkippedPatterns = [
        "Music",
        "Pictures",
        "Movies",
        "Library",
        ".Trash",
        ".runeweaver",
        ".git",
        "node_modules",
        "DerivedData",
        "__pycache__",
        ".venv"
    ]

    /// Longest relative path retained on a progress frame, bounding frame size.
    static let maxCurrentLength = 240

    /// Modification-time tolerance for the pre-read fingerprint fast path.
    ///
    /// Stored and live mtimes within one second count as a match so filesystem
    /// rounding and double round-tripping never force a re-read of an
    /// otherwise unchanged file.
    static let fingerprintMtimeTolerance: TimeInterval = 1.0

    /// Document index the run writes into.
    let store: DocIndexStore
    /// Text extractor injected so a test can stub extraction without real files.
    let extractor: any DocumentTextExtracting
    /// Embeddings backend consulted inside the vector policy; nil stays keyword-only.
    let embedder: (any EmbeddingsBackend)?
    /// Pooled embeddings backends consulted by parallel workers; nil shares `embedder`.
    let embeddingsPool: EmbeddingsBackendPool?
    /// Override for the resolved worker count; nil derives from `config`.
    let workerCountOverride: Int?
    /// Thermal state source, injectable so a test drives backoff deterministically.
    let thermalStateProvider: @Sendable () -> ProcessInfo.ThermalState
    /// Low Power Mode source, injectable so a test drives battery pause deterministically.
    let lowPowerModeProvider: @Sendable () -> Bool
    /// Path policy consulted before any candidate is opened.
    let accessGuard: any FilesIndexAccessGuard
    /// Which extracted documents get vectors.
    let vectorPolicy: FilesVectorPolicy
    /// Roots, excludes, size cap, and budget for the walk.
    let config: IndexConfig
    /// Home boundary override for tests; nil means the real home.
    let homeDirectoryURL: URL?
    /// Override resolving evicted iCloud files; nil uses the live ubiquity check. Test seam only.
    let evictedCheck: (@Sendable (URL) -> Bool)?
    /// Starts an iCloud download for an evicted file; nil uses `FileManager`. Test seam only.
    let downloadStarter: (@Sendable (URL) -> Void)?
    /// Reads file bytes; nil uses memory-mapped `Data` reads. Test seam only.
    let fileReader: (@Sendable (URL) throws -> Data)?
    /// Monotonic instant source, injectable so a test advances time deterministically.
    let nowProvider: @Sendable () -> ContinuousClock.Instant
    /// Advisory progress sink mirroring the tool progress reporter contract.
    let progress: ToolProgressReporter
    /// Cooperative cancellation flag set by ``cancel()``.
    var isCancelled = false
    /// Lock-guarded cancellation mirror for parallel workers that cannot hop onto the indexer per file.
    let cancelBox = IndexCancellationFlag()
    /// Built-in plus configured exclude patterns, deduplicated at construction.
    let excludePatterns: [String]
    /// Whether a work frame has been emitted for the run in flight.
    var hasReportedWork = false
    /// Instant of the last work frame, for the shared report cadence.
    var lastReportInstant: ContinuousClock.Instant?

    /// Creates a files indexer.
    /// - Parameters:
    ///   - store: Document index to write into.
    ///   - extractor: Text extractor for candidate files.
    ///   - embedder: Embeddings backend, or nil for keyword-only indexing.
    ///   - embeddingsPool: Pooled backends for parallel workers, or nil to share `embedder`.
    ///   - workerCountOverride: Files in flight when set; nil resolves from `config`.
    ///   - thermalStateProvider: Thermal state source; nil observes the live system state.
    ///   - lowPowerModeProvider: Low Power Mode source; nil observes the live system state.
    ///   - accessGuard: Path policy consulted before opening a candidate.
    ///   - vectorPolicy: Which extracted documents are vectorized.
    ///   - config: Walk roots, excludes, size cap, and budget.
    ///   - homeDirectoryURL: Home boundary override, or nil for the real home.
    ///   - evictedCheck: Override resolving evicted iCloud files, or nil for the live check.
    ///   - downloadStarter: Download trigger for the `download` policy, or nil for `FileManager`.
    ///   - fileReader: Override reading file bytes, or nil for memory-mapped reads.
    ///   - nowProvider: Monotonic instant source.
    ///   - progress: Advisory progress sink; defaults to a no-op.
    public init(
        store: DocIndexStore,
        extractor: any DocumentTextExtracting = DocumentTextExtractor(),
        embedder: (any EmbeddingsBackend)? = nil,
        embeddingsPool: EmbeddingsBackendPool? = nil,
        workerCountOverride: Int? = nil,
        thermalStateProvider: (@Sendable () -> ProcessInfo.ThermalState)? = nil,
        lowPowerModeProvider: (@Sendable () -> Bool)? = nil,
        accessGuard: any FilesIndexAccessGuard,
        vectorPolicy: FilesVectorPolicy = FilesVectorPolicy(),
        config: IndexConfig,
        homeDirectoryURL: URL? = nil,
        evictedCheck: (@Sendable (URL) -> Bool)? = nil,
        downloadStarter: (@Sendable (URL) -> Void)? = nil,
        fileReader: (@Sendable (URL) throws -> Data)? = nil,
        nowProvider: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now },
        progress: @escaping ToolProgressReporter = ToolContext.noProgress
    ) {
        self.store = store
        self.extractor = extractor
        self.embedder = embedder
        self.embeddingsPool = embeddingsPool
        self.workerCountOverride = workerCountOverride
        self.thermalStateProvider = thermalStateProvider ?? { ProcessInfo.processInfo.thermalState }
        self.lowPowerModeProvider = lowPowerModeProvider ?? { ProcessInfo.processInfo.isLowPowerModeEnabled }
        self.accessGuard = accessGuard
        self.vectorPolicy = vectorPolicy
        self.config = config
        self.homeDirectoryURL = homeDirectoryURL
        self.evictedCheck = evictedCheck
        self.downloadStarter = downloadStarter
        self.fileReader = fileReader
        self.nowProvider = nowProvider
        self.progress = progress
        self.excludePatterns = Self.deduplicated(Self.alwaysSkippedPatterns + config.exclude)
    }

    /// Requests cancellation of the run in flight.
    ///
    /// Cancellation is cooperative and observed between files, so a file already
    /// being written finishes its document and chunks before the run stops;
    /// nothing is left half-written for the next run to misread as current.
    /// Parallel workers observe the same request through a lock-guarded mirror
    /// and stop launching new files within one batch.
    public func cancel() {
        isCancelled = true
        cancelBox.set()
    }

    /// Runs one pass over every configured root.
    ///
    /// A single worker keeps the historical sequential walk so a light install
    /// behaves exactly as before; higher presets fan per-file bodies out over
    /// a bounded task group of at most the resolved worker count.
    /// - Returns: Counts describing the run.
    public func run() async -> FilesIndexRunReport {
        guard config.enabled, config.files else {
            return FilesIndexRunReport(skippedReason: "File indexing is disabled in [index].")
        }
        let workers = resolvedWorkerCount()
        guard workers > 1 else {
            return await runSequential()
        }
        return await runParallel(workers: workers)
    }

    /// Cumulative counters for one run.
    struct Counters: Sendable {
        /// Files examined, including those later skipped.
        var scanned = 0
        /// Documents written.
        var indexed = 0
        /// Files whose stored body hash was already current.
        var unchanged = 0
        /// Files deliberately skipped.
        var skipped = 0
        /// Files that could not be processed.
        var errors = 0
        /// Chunks written.
        var chunks = 0
        /// Chunks carrying an embedding.
        var vectors = 0
        /// Documents where chunks beyond the vector cap stayed keyword-only.
        var truncated = 0
        /// Newly written documents still permitted this run.
        var budgetRemaining = Int.max
        /// Non-fatal per-file problems.
        var warnings: [String] = []
        /// Opaque stamp written to `last_seen_run` for every visited file.
        var runID = ""
        /// Documents retired by the end-of-run reconcile.
        var retired = 0
        /// Whether any configured root was missing or could not be enumerated.
        var hasUnreadableRoot = false
        /// Whether `nightly_budget` stopped the walk before every file was visited.
        var budgetStoppedEarly = false
        /// Whether thermal pressure or Low Power Mode halted new work before every file was visited.
        var thermalStoppedEarly = false
        /// Whether any `last_seen_run` stamp failed, forcing the reconcile to stay skipped.
        var stampFailed = false
    }

    /// Runs one sequential pass over every configured root.
    ///
    /// The run never throws: an unreadable file or a store failure is counted
    /// as an error and the walk continues, because a background index should
    /// make progress on the rest of the tree rather than abort on one bad entry.
    /// Cancellation stops the walk between files and is reported on the result.
    /// Thermal `.critical` and Low Power Mode halt new work through the same
    /// `currentWorkerLimit` gate as the parallel path so a `light` run blocks
    /// the retire reconcile instead of deleting against a partial view.
    /// - Returns: Counts describing the run.
    func runSequential() async -> FilesIndexRunReport {
        isCancelled = false
        cancelBox.reset()
        hasReportedWork = false
        lastReportInstant = nil
        let start = nowProvider()
        // Opaque stamp for this walk: every visited files row carries it in
        // `last_seen_run`, so the reconcile can tell live rows from rows that
        // left policy without comparing paths in memory.
        let runID = UUID().uuidString
        var counters = Counters()
        counters.budgetRemaining = config.nightlyBudget > 0 ? config.nightlyBudget : Int.max
        counters.runID = runID
        await emit(message: Self.startMessage, counters: counters, current: nil, start: start)
        for root in config.roots {
            if isSequentialThermalHaltRequested() {
                // Thermal `.critical` or Low Power Mode halts the sequential
                // walk like the parallel path so a `light` run never retires
                // against a partial view.
                noteSequentialThermalHalt(counters: &counters)
                break
            }
            if shouldStop(counters) {
                // Reaching here means the walk stopped before every root was
                // entered; a budget stop must never retire, so it is recorded
                // distinctly from cancellation (which is reported separately).
                if !isCancelled, !cancelBox.isSet, !Task.isCancelled, counters.budgetRemaining <= 0 {
                    counters.budgetStoppedEarly = true
                }
                break
            }
            await indexRoot(root, start: start, counters: &counters)
        }
        let retiredCount = await retireUnseenFiles(runID: runID, counters: &counters)
        let settledCancelled = isCancelled || cancelBox.isSet || Task.isCancelled
        await emit(message: Self.finishMessage(report: counters, cancelled: settledCancelled), counters: counters, current: nil, start: start)
        return buildReport(from: counters, retiredCount: retiredCount, cancelled: settledCancelled)
    }

    /// Retires files not seen in this run and reclaims space if needed.
    private func retireUnseenFiles(runID: String, counters: inout Counters) async -> Int {
        let cancelled = isCancelled || cancelBox.isSet || Task.isCancelled
        guard !cancelled, !counters.hasUnreadableRoot, !counters.budgetStoppedEarly,
              !counters.thermalStoppedEarly, !counters.stampFailed
        else {
            return 0
        }
        do {
            let retiredCount = try await store.retireUnseenFiles(runID: runID)
            counters.retired = retiredCount
            if retiredCount > 0 {
                do {
                    _ = try await store.reclaim()
                } catch {
                    counters.warnings.append("Reclaim after retire failed: \(error.localizedDescription)")
                }
            }
            return retiredCount
        } catch is CancellationError {
            isCancelled = true
            cancelBox.set()
            return 0
        } catch {
            counters.errors += 1
            counters.warnings.append("Retire unseen files failed: \(error.localizedDescription)")
            counters.retired = 0
            return 0
        }
    }

    /// Assembles the final run report from counters.
    private func buildReport(from counters: Counters, retiredCount: Int, cancelled: Bool) -> FilesIndexRunReport {
        var report = FilesIndexRunReport()
        report.filesScanned = counters.scanned
        report.filesIndexed = counters.indexed
        report.filesUnchanged = counters.unchanged
        report.filesSkipped = counters.skipped
        report.errors = counters.errors
        report.chunksWritten = counters.chunks
        report.vectorsWritten = counters.vectors
        report.truncatedVectorDocuments = counters.truncated
        report.retiredCount = retiredCount
        report.warnings = counters.warnings
        report.cancelled = cancelled
        return report
    }
}

// MARK: - Bounded parallel run

extension FilesIndexer {
    /// Resolves how many files may be in flight on this run.
    /// - Returns: The override when set, otherwise the effort preset resolved from `config`.
    func resolvedWorkerCount() -> Int {
        if let workerCountOverride {
            return max(1, workerCountOverride)
        }
        return max(1, config.resolvedWorkerCount())
    }

    /// Resolves how many files may be in flight right now.
    ///
    /// `.serious` thermal pressure halves the workers while `.critical` halts
    /// new work (zero) so in-flight files drain; Low Power Mode halts new work
    /// only when `pause_on_battery` opted in. Thermal gates apply only when
    /// `thermal_backoff` is on.
    /// - Parameter base: Files in flight absent any pressure.
    /// - Returns: Files that may be in flight now, or zero to halt new work.
    func currentWorkerLimit(base: Int) -> Int {
        if config.pauseOnBattery, lowPowerModeProvider() {
            return 0
        }
        guard config.thermalBackoff else { return base }
        switch thermalStateProvider() {
        case .nominal, .fair:
            return base
        case .serious:
            return max(1, base / 2)
        case .critical:
            return 0
        @unknown default:
            return base
        }
    }

    /// Reports whether the sequential walk must halt for thermal or battery pressure.
    ///
    /// Mirrors the parallel gate so the single-worker (`light`) walk honors the
    /// same `thermalBackoff`/`pauseOnBattery` contract: `.critical` or Low Power
    /// Mode halts new work, the walk is marked incomplete, and the reconcile
    /// stays skipped. `.serious` still permits one worker, matching the
    /// parallel halving for a base of one.
    /// - Returns: True when no new file should launch.
    func isSequentialThermalHaltRequested() -> Bool {
        currentWorkerLimit(base: max(1, resolvedWorkerCount())) <= 0
    }

    /// Records a sequential thermal/battery halt with the parallel copy.
    ///
    /// Marks the walk incomplete so the end-of-run reconcile stays skipped,
    /// matching `runParallelGroup` instead of retiring against a partial view.
    /// - Parameter counters: Cumulative run counters.
    func noteSequentialThermalHalt(counters: inout Counters) {
        counters.thermalStoppedEarly = true
        if config.pauseOnBattery, lowPowerModeProvider() {
            counters.warnings.append("Paused new work: Low Power Mode is on")
        } else {
            counters.warnings.append("Paused new work: thermal state is critical")
        }
    }

    /// Runs one pass over every configured root with at most `workers` files in flight.
    ///
    /// Discovery stays sequential on the indexer so directory pruning and skip
    /// totals match the single-worker walk; only per-file bodies fan out, each
    /// at utility quality of service through a bounded task group. The
    /// document store remains an actor so concurrent commits serialize
    /// naturally, and every file still commits its document and chunks
    /// atomically, so a cancelled run resumes from the first unfinished file.
    /// Discovery yields cooperatively and honors budget and thermal gates as
    /// it enumerates, so a stop truncates the walk like the sequential path
    /// instead of counting a full-tree prune set.
    /// - Parameter workers: Maximum files in flight; always greater than one here.
    /// - Returns: Counts describing the run.
    func runParallel(workers: Int) async -> FilesIndexRunReport {
        isCancelled = false
        cancelBox.reset()
        hasReportedWork = false
        lastReportInstant = nil
        let start = nowProvider()
        // Opaque stamp shared with the sequential path: every visited files
        // row carries it in `last_seen_run` for the end-of-run reconcile.
        let runID = UUID().uuidString
        var counters = Counters()
        counters.budgetRemaining = config.nightlyBudget > 0 ? config.nightlyBudget : Int.max
        counters.runID = runID
        await emit(message: Self.startMessage, counters: counters, current: nil, start: start)

        let budget = FileIndexBudget(limit: config.nightlyBudget)
        let candidates = await collectAllCandidates(workers: workers, budget: budget, counters: &counters)

        await runParallelGroup(
            candidates: candidates,
            workers: workers,
            budget: budget,
            runID: runID,
            start: start,
            counters: &counters
        )

        let retiredCount = await retireUnseenFiles(runID: runID, counters: &counters)
        let settledCancelled = isCancelled || cancelBox.isSet || Task.isCancelled
        await emit(message: Self.finishMessage(report: counters, cancelled: settledCancelled), counters: counters, current: nil, start: start)
        return buildReport(from: counters, retiredCount: retiredCount, cancelled: settledCancelled)
    }

    /// Collects candidate files across all configured roots.
    ///
    /// Async so a large tree never pins the indexer while `cancel()` waits
    /// for the actor: yields let the cancellation request land, and the
    /// lock-guarded mirror plus the task flag stop the walk without needing
    /// actor state in the hot loop. Budget and thermal gates apply between
    /// roots so a truncated discovery matches the sequential partial walk
    /// instead of counting full-tree excludes.
    private func collectAllCandidates(workers: Int, budget: FileIndexBudget, counters: inout Counters) async -> [(file: URL, root: URL)] {
        var candidates: [(file: URL, root: URL)] = []
        for root in config.roots {
            if cancelBox.isSet || Task.isCancelled || isCancelled {
                break
            }
            if await budget.isExhausted {
                if !cancelBox.isSet, !Task.isCancelled, !isCancelled {
                    counters.budgetStoppedEarly = true
                }
                break
            }
            if currentWorkerLimit(base: workers) <= 0 {
                counters.thermalStoppedEarly = true
                if config.pauseOnBattery, lowPowerModeProvider() {
                    counters.warnings.append("Paused new work: Low Power Mode is on")
                } else {
                    counters.warnings.append("Paused new work: thermal state is critical")
                }
                break
            }
            let rootURL = resolvedRootURL(root)
            await candidates.append(contentsOf: collectCandidates(rootURL: rootURL, workers: workers, budget: budget, counters: &counters))
        }
        return candidates
    }

    /// Dispatches candidate processing to a bounded task group.
    private func runParallelGroup(
        candidates: [(file: URL, root: URL)],
        workers: Int,
        budget: FileIndexBudget,
        runID: String,
        start: ContinuousClock.Instant,
        counters: inout Counters
    ) async {
        let store = self.store
        let extractor = self.extractor
        let embedder = self.embedder
        let embeddingsPool = self.embeddingsPool
        let accessGuard = self.accessGuard
        let vectorPolicy = self.vectorPolicy
        let config = self.config
        let homeDirectoryURL = self.homeDirectoryURL
        let evictedCheck = self.evictedCheck
        let downloadStarter = self.downloadStarter
        let fileReader = self.fileReader
        let cancellation = self.cancelBox
        await withTaskGroup(of: FileOutcome.self) { group in
            var next = 0
            var inFlight = 0
            while next < candidates.count {
                if isCancelled || cancelBox.isSet || Task.isCancelled {
                    break
                }
                if await budget.isExhausted {
                    // Reaching here means the walk stopped before every file
                    // was visited; recorded distinctly like the sequential
                    // path so a budget stop never retires.
                    if !isCancelled, !cancelBox.isSet, !Task.isCancelled {
                        counters.budgetStoppedEarly = true
                    }
                    break
                }
                let allowed = currentWorkerLimit(base: workers)
                if allowed <= 0 {
                    // Thermal `.critical` or Low Power Mode: in-flight files
                    // finish their current file while no new work launches, so
                    // cancellation-style overrun stays within one batch. The
                    // walk is incomplete, so the reconcile stays skipped.
                    counters.thermalStoppedEarly = true
                    if config.pauseOnBattery, lowPowerModeProvider() {
                        counters.warnings.append("Paused new work: Low Power Mode is on")
                    } else {
                        counters.warnings.append("Paused new work: thermal state is critical")
                    }
                    break
                }
                if inFlight >= allowed {
                    guard let outcome = await group.next() else { break }
                    inFlight -= 1
                    await foldOutcome(outcome, counters: &counters, start: start)
                    continue
                }
                let candidate = candidates[next]
                next += 1
                group.addTask(priority: .utility) {
                    await FilesIndexer.processCandidate(
                        identity: CandidateIdentity(
                            fileURL: candidate.file,
                            root: candidate.root,
                            runID: runID
                        ),
                        services: CandidateServices(
                            store: store,
                            extractor: extractor,
                            embedder: embedder,
                            embeddingsPool: embeddingsPool,
                            accessGuard: accessGuard,
                            vectorPolicy: vectorPolicy
                        ),
                        policy: CandidatePolicy(
                            config: config,
                            homeDirectoryURL: homeDirectoryURL,
                            evictedCheck: evictedCheck,
                            downloadStarter: downloadStarter,
                            fileReader: fileReader
                        ),
                        state: CandidateRunState(budget: budget, cancellation: cancellation)
                    )
                }
                inFlight += 1
            }
            for await outcome in group {
                inFlight -= 1
                await foldOutcome(outcome, counters: &counters, start: start)
            }
        }
    }

    /// Enumerates one root sequentially, collecting committable file candidates.
    ///
    /// Directory pruning, symlink handling, and skip counting flow through the
    /// shared classification with `indexRoot`; per-file bodies are left for
    /// parallel workers so totals agree with a sequential run over the same
    /// tree. The loop yields cooperatively and honors cancellation plus budget
    /// and thermal gates as it enumerates, so a stop truncates discovery like
    /// the sequential walk instead of counting a full-tree prune set.
    /// - Parameters:
    ///   - rootURL: Resolved root to walk.
    ///   - workers: Files in flight absent any pressure, for the thermal gate.
    ///   - budget: Shared nightly budget; exhaustion stops discovery.
    ///   - counters: Cumulative run counters.
    /// - Returns: Candidate files with the root they were discovered under.
    func collectCandidates(rootURL: URL, workers: Int, budget: FileIndexBudget, counters: inout Counters) async -> [(file: URL, root: URL)] {
        var collected: [(file: URL, root: URL)] = []
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory)
        // A missing root marks the run unreadable like the sequential path so
        // the reconcile stays skipped instead of deleting live documents.
        guard exists else {
            counters.hasUnreadableRoot = true
            return collected
        }
        guard isDirectory.boolValue else {
            collected.append((rootURL, rootURL))
            return collected
        }
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Self.entryKeys,
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            counters.hasUnreadableRoot = true
            return collected
        }
        var sinceYield = 0
        while let element = enumerator.nextObject() {
            // Cooperative pause so `cancel()` reaches the actor on huge trees:
            // the lock-guarded mirror and the task flag stop the walk without
            // waiting on actor state, and each pause also lets a pending
            // cancellation request land.
            sinceYield += 1
            if sinceYield >= 64 {
                sinceYield = 0
                await Task.yield()
            }
            if cancelBox.isSet || Task.isCancelled || isCancelled {
                return collected
            }
            if await budget.isExhausted {
                if !cancelBox.isSet, !Task.isCancelled, !isCancelled {
                    counters.budgetStoppedEarly = true
                }
                return collected
            }
            if currentWorkerLimit(base: workers) <= 0 {
                counters.thermalStoppedEarly = true
                if config.pauseOnBattery, lowPowerModeProvider() {
                    counters.warnings.append("Paused new work: Low Power Mode is on")
                } else {
                    counters.warnings.append("Paused new work: thermal state is critical")
                }
                return collected
            }
            guard let url = element as? URL else { continue }
            let values = try? url.resourceValues(forKeys: Self.entryKeySet)
            let isItemDirectory = values?.isDirectory ?? false
            if isItemDirectory {
                if let prune = shouldPruneDirectory(url: url, values: values, rootURL: rootURL) {
                    if prune.prune {
                        enumerator.skipDescendants()
                    }
                    if prune.countSkipped {
                        counters.skipped += 1
                    }
                    continue
                }
                continue
            }
            guard let resolved = shouldCollectFile(url: url, values: values, rootURL: rootURL) else {
                counters.skipped += 1
                continue
            }
            collected.append((resolved, rootURL))
        }
        return collected
    }

    /// Folds one worker outcome into the run counters and emits a throttled frame.
    ///
    /// Cancelled outcomes set the shared flag without reporting, matching the
    /// sequential early returns; every other outcome reports through the same
    /// cadence so per-item progress frames are preserved.
    /// - Parameters:
    ///   - outcome: Worker outcome to fold in.
    ///   - counters: Cumulative run counters.
    ///   - start: Instant the run began.
    func foldOutcome(_ outcome: FileOutcome, counters: inout Counters, start: ContinuousClock.Instant) async {
        if outcome.propagateCancel {
            isCancelled = true
            cancelBox.set()
        }
        counters.scanned += 1
        switch outcome.kind {
        case let .indexed(chunks, vectors, truncated):
            counters.indexed += 1
            counters.chunks += chunks
            counters.vectors += vectors
            if truncated {
                counters.truncated += 1
            }
        case .unchanged:
            counters.unchanged += 1
            counters.skipped += 1
        case .skipped:
            counters.skipped += 1
        case let .error(warning):
            counters.errors += 1
            counters.warnings.append(warning)
        case .overBudget:
            counters.budgetStoppedEarly = true
        case .cancelled:
            isCancelled = true
            cancelBox.set()
            if outcome.stampFailed {
                counters.stampFailed = true
            }
            return
        }
        if outcome.stampFailed {
            counters.stampFailed = true
        }
        await reportWork(outcome.relative, counters: counters, start: start)
    }
}

// MARK: - Progress

extension FilesIndexer {
    /// Copy on the opening frame.
    static let startMessage = "Scanning files"
    /// Cadence floor shared with `ToolProgress` so frames never exceed the wire rate.
    static let minimumReportSpacing = Duration.nanoseconds(Int64(ToolProgress.minimumReportIntervalNanoseconds))

    /// Reports whether the run should stop before the next item.
    /// - Parameter counters: Cumulative run counters.
    /// - Returns: True when cancelled or the nightly budget is spent.
    func shouldStop(_ counters: Counters) -> Bool {
        isCancelled || cancelBox.isSet || Task.isCancelled || counters.budgetRemaining <= 0
    }

    /// Emits a work frame for the item just processed, honoring the shared cadence.
    ///
    /// The first work frame always reports so a fast run is visible immediately;
    /// later frames wait out the `ToolProgress` spacing floor so a huge first
    /// index cannot flood the transport.
    /// - Parameters:
    ///   - relative: Root-relative item path.
    ///   - counters: Cumulative run counters.
    ///   - start: Instant the run began.
    func reportWork(_ relative: String, counters: Counters, start: ContinuousClock.Instant) async {
        let now = nowProvider()
        let due: Bool = if !hasReportedWork {
            true
        } else if let last = lastReportInstant {
            now - last >= Self.minimumReportSpacing
        } else {
            true
        }
        guard due else { return }
        hasReportedWork = true
        lastReportInstant = now
        await emit(
            message: Self.workMessage(counters: counters),
            counters: counters,
            current: Self.safeRelative(relative),
            start: start
        )
    }

    /// Emits one progress frame.
    /// - Parameters:
    ///   - message: Human-readable status line, safe to display verbatim.
    ///   - counters: Cumulative run counters.
    ///   - current: Relative display path, or nil.
    ///   - start: Instant the run began.
    func emit(message: String, counters: Counters, current: String?, start: ContinuousClock.Instant) async {
        await progress(ToolProgress(
            message: message,
            scanned: counters.scanned,
            matched: counters.indexed,
            elapsedMs: elapsedMs(since: start),
            current: current
        ))
    }

    /// Work-frame status line.
    /// - Parameter counters: Cumulative run counters.
    /// - Returns: `Indexing files: N indexed, M scanned, K skipped, E errors`.
    static func workMessage(counters: Counters) -> String {
        "Indexing files: \(counters.indexed) indexed, \(counters.scanned) scanned, \(counters.skipped) skipped, \(counters.errors) errors"
    }

    /// Final-frame status line.
    /// - Parameters:
    ///   - report: Counters accumulated by the run.
    ///   - cancelled: Whether the run stopped on cancellation.
    /// - Returns: A finished or cancelled summary.
    static func finishMessage(report: Counters, cancelled: Bool) -> String {
        let verb = cancelled ? "cancelled" : "finished"
        return "Files indexing \(verb): \(report.indexed) indexed, \(report.scanned) scanned, \(report.errors) errors"
    }

    /// Reports whether a candidate is excluded by built-in or configured patterns.
    /// - Parameters:
    ///   - relativePath: Path relative to the walk root.
    ///   - filename: Final path component.
    /// - Returns: True when the candidate is skipped.
    func isExcluded(relativePath: String, filename: String) -> Bool {
        Self.isExcluded(relativePath: relativePath, filename: filename, patterns: excludePatterns)
    }

    /// Disposition of one enumerated entry, shared by the sequential walk and parallel discovery.
    ///
    /// A single classification keeps skip totals from drifting when the two
    /// walks cover the same tree: symlinks, aliases, and AppleDouble sidecars are never
    /// followed, excluded trees prune without descending, denied entries stay
    /// out of policy, allowed directories descend, and allowed files collect
    /// with the guard-resolved URL.
    enum WalkEntryDisposition: Sendable {
        /// Entry is skipped; `prune` requests `skipDescendants` for directories.
        case skip(countSkipped: Bool, prune: Bool)
        /// Allowed directory that the walk descends into.
        case descend
        /// Allowed file with the guard-resolved URL to collect or index.
        case collect(URL)
    }

    /// Policy and boundary parameters governing entry classification during a walk.
    struct WalkPolicy: Sendable {
        /// Walk root for relative paths.
        let rootURL: URL
        /// Built-in plus configured exclude patterns.
        let excludePatterns: [String]
        /// Path policy consulted before opening a candidate.
        let accessGuard: any FilesIndexAccessGuard
        /// Home boundary override, or nil for the real home.
        let homeDirectoryURL: URL?
    }

    /// Builds the walk policy for a given root.
    func walkPolicy(rootURL: URL) -> WalkPolicy {
        WalkPolicy(
            rootURL: rootURL,
            excludePatterns: excludePatterns,
            accessGuard: accessGuard,
            homeDirectoryURL: homeDirectoryURL
        )
    }

    /// Classifies one enumerated entry without touching actor state.
    ///
    /// Static so parallel discovery can share the exact pruning rules without
    /// hopping onto the indexer: patterns, guard, and home boundary travel as
    /// parameters while the symlink, alias, AppleDouble, exclude, and policy checks
    /// stay single-sourced.
    /// - Parameters:
    ///   - url: Enumerated entry.
    ///   - values: Pre-fetched resource values, when available.
    ///   - isItemDirectory: Whether the entry is a directory.
    ///   - policy: Walk policy carrying root URL, exclude patterns, access guard, and home directory URL.
    /// - Returns: How the caller should handle the entry.
    static func walkDisposition(
        url: URL,
        values: URLResourceValues?,
        isItemDirectory: Bool,
        policy: WalkPolicy
    ) -> WalkEntryDisposition {
        // A symlink is never followed: a link loop cannot form and a link
        // cannot redirect the walk to an out-of-policy target.
        if values?.isSymbolicLink == true {
            return .skip(countSkipped: true, prune: isItemDirectory)
        }
        // Aliases are pointer files with the same threat shape as symlinks and are never followed.
        if values?.isAliasFile == true {
            return .skip(countSkipped: true, prune: isItemDirectory)
        }
        let filename = url.lastPathComponent
        // AppleDouble resource forks are metadata, not documents.
        if filename.hasPrefix("._") {
            return .skip(countSkipped: true, prune: isItemDirectory)
        }
        // Scoped scratch prune on the absolute path: covers walks rooted
        // inside `.runeweaver/workspace` itself, where the relative path no
        // longer carries the prefix but the absolute path still does.
        if Self.isWorkspaceScratchURL(url) {
            if isItemDirectory {
                return .skip(countSkipped: false, prune: true)
            }
            return .skip(countSkipped: true, prune: false)
        }
        let relative = Self.relativePath(of: url, root: policy.rootURL)
        if Self.isExcluded(relativePath: relative, filename: filename, patterns: policy.excludePatterns) {
            // Excluded trees prune without walking them, so only a top-level
            // excluded file counts as skipped; descendants never enumerate.
            if isItemDirectory {
                return .skip(countSkipped: false, prune: true)
            }
            return .skip(countSkipped: true, prune: false)
        }
        let decision = policy.accessGuard.evaluate(
            path: url.resolvingSymlinksInPath().standardizedFileURL.path,
            homeDirectoryURL: policy.homeDirectoryURL
        )
        guard decision.allowed else {
            return .skip(countSkipped: true, prune: isItemDirectory)
        }
        if isItemDirectory {
            return .descend
        }
        return .collect(URL(fileURLWithPath: decision.resolvedPath))
    }

    /// Reports whether an enumerated directory must be pruned, shared by both walks.
    ///
    /// Thin wrapper over the shared classification so sequential and parallel
    /// discovery prune excluded, symlinked, alias, AppleDouble, and denied
    /// directories identically.
    /// - Parameters:
    ///   - url: Enumerated directory entry.
    ///   - values: Pre-fetched resource values, when available.
    ///   - rootURL: Walk root for relative paths.
    /// - Returns: Prune and count flags, or nil when the walk should descend.
    func shouldPruneDirectory(url: URL, values: URLResourceValues?, rootURL: URL) -> (prune: Bool, countSkipped: Bool)? {
        switch Self.walkDisposition(
            url: url,
            values: values,
            isItemDirectory: true,
            policy: walkPolicy(rootURL: rootURL)
        ) {
        case let .skip(countSkipped, prune):
            (prune, countSkipped)
        case .descend:
            nil
        case .collect:
            nil
        }
    }

    /// Reports whether an enumerated file must be collected, shared by both walks.
    ///
    /// Thin wrapper over the shared classification so sequential and parallel
    /// discovery skip symlinked, alias, AppleDouble, excluded, and denied files
    /// identically and collect allowed files with the guard-resolved URL.
    /// - Parameters:
    ///   - url: Enumerated file entry.
    ///   - values: Pre-fetched resource values, when available.
    ///   - rootURL: Walk root for relative paths.
    /// - Returns: Resolved URL to collect or index, or nil when skipped.
    func shouldCollectFile(url: URL, values: URLResourceValues?, rootURL: URL) -> URL? {
        switch Self.walkDisposition(
            url: url,
            values: values,
            isItemDirectory: false,
            policy: walkPolicy(rootURL: rootURL)
        ) {
        case .skip:
            nil
        case .descend:
            nil
        case let .collect(resolved):
            resolved
        }
    }

    /// Whether evicted iCloud files are downloaded instead of skipped.
    /// - Returns: True only for the `download` policy; any other value fails closed to skip.
    var shouldDownloadEvicted: Bool {
        Self.isDownloadPolicy(config.iCloudEvicted)
    }

    /// Reports whether a file's bytes are evicted in iCloud.
    /// - Parameters:
    ///   - url: Canonical file URL.
    ///   - values: Pre-fetched resource values, when available.
    /// - Returns: True when the file is ubiquitous and not downloaded.
    func isEvictedForPolicy(at url: URL, values: URLResourceValues? = nil) -> Bool {
        if let check = evictedCheck {
            return check(url)
        }
        return Self.isLiveEvicted(at: url, values: values)
    }

    /// Starts an iCloud download for an evicted file, never throwing.
    /// - Parameter url: Canonical file URL.
    func startEvictedDownload(at url: URL) {
        if let starter = downloadStarter {
            starter(url)
            return
        }
        Self.startLiveDownload(at: url)
    }

    /// Byte cap for one candidate file, from `max_file_mb`.
    var maxFileBytes: Int {
        max(1, config.maxFileMB) * 1024 * 1024
    }

    /// Resolves a configured root, honoring the injected home override for `~`.
    /// - Parameter root: Raw configured root.
    /// - Returns: Canonical root URL.
    func resolvedRootURL(_ root: String) -> URL {
        let trimmed = root.trimmingCharacters(in: .whitespacesAndNewlines)
        let home = homeDirectoryURL ?? FileManager.default.homeDirectoryForCurrentUser
        if trimmed == "~" {
            return home.resolvingSymlinksInPath().standardizedFileURL
        }
        if trimmed.hasPrefix("~/") {
            return home.appendingPathComponent(String(trimmed.dropFirst(2))).resolvingSymlinksInPath().standardizedFileURL
        }
        let expanded = (trimmed as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).resolvingSymlinksInPath().standardizedFileURL
        }
        return home.appendingPathComponent(expanded).resolvingSymlinksInPath().standardizedFileURL
    }

    /// Monotonic elapsed whole milliseconds for a run.
    /// - Parameter start: Instant the run began.
    /// - Returns: Non-negative whole milliseconds.
    func elapsedMs(since start: ContinuousClock.Instant) -> Int {
        let duration = nowProvider() - start
        let components = duration.components
        let milliseconds = Double(components.seconds) * 1000
            + Double(components.attoseconds) / 1_000_000_000_000_000
        return max(0, Int(milliseconds))
    }
}

// MARK: - Helpers

extension FilesIndexer {
    /// Resource keys prefetched for every enumerated entry.
    static let entryKeys: [URLResourceKey] = [
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .isAliasFileKey,
        .fileSizeKey,
        .contentModificationDateKey,
        .isUbiquitousItemKey,
        .ubiquitousItemDownloadingStatusKey
    ]

    /// Set form of ``entryKeys`` for `resourceValues(forKeys:)`.
    static let entryKeySet: Set<URLResourceKey> = Set(entryKeys)

    /// SHA-256 content hash that gates re-indexing.
    /// - Parameter data: File bytes.
    /// - Returns: Lowercase hexadecimal digest.
    static func contentHash(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Reports whether a file is an iCloud item whose bytes are evicted.
    ///
    /// Only a positive `.notDownloaded` status counts as evicted: a missing
    /// status or a non-ubiquitous file proceeds, so an undetermined download
    /// state never hides a locally readable file from the index.
    /// - Parameters:
    ///   - url: File URL to inspect.
    ///   - values: Pre-fetched resource values, when available.
    /// - Returns: True when the file is ubiquitous and not downloaded.
    static func isLiveEvicted(at url: URL, values: URLResourceValues? = nil) -> Bool {
        let resolved: URLResourceValues? = if let values {
            values
        } else {
            try? url.resourceValues(forKeys: Set([.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]))
        }
        guard resolved?.isUbiquitousItem == true else { return false }
        guard let status = resolved?.ubiquitousItemDownloadingStatus else { return false }
        return status == URLUbiquitousItemDownloadingStatus.notDownloaded
    }

    /// Best-effort trigger for an evicted iCloud download; failures are ignored.
    /// - Parameter url: File URL to download.
    static func startLiveDownload(at url: URL) {
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    /// Maps extraction chunks to indexed chunks, attaching vectors when present.
    /// - Parameters:
    ///   - extraction: Extracted document body.
    ///   - documentID: Owning document identifier.
    ///   - vectors: One vector per chunk, or nil for keyword-only.
    /// - Returns: Indexed chunks in extraction order.
    static func makeChunks(extraction: DocumentExtraction, documentID: UUID, vectors: [[Float]]?) -> [IndexedChunk] {
        extraction.chunks.enumerated().map { position, chunk in
            let vector: [Float] = if let vectors, position < vectors.count {
                vectors[position]
            } else {
                []
            }
            return IndexedChunk(documentID: documentID, ordinal: chunk.index, text: chunk.text, embedding: vector)
        }
    }

    /// Reports whether the iCloud evicted policy requests a download.
    ///
    /// Single-sourced so the sequential walk and the parallel worker agree on
    /// the spelling: only the `download` token downloads, any other value
    /// fails closed to skip.
    /// - Parameter rawValue: Raw `icloud_evicted` policy value.
    /// - Returns: True only for the `download` policy.
    static func isDownloadPolicy(_ rawValue: String) -> Bool {
        rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "download"
    }

    /// Builds the content-free warning line for one skipped file.
    ///
    /// Single-sourced so sequential and parallel paths report the same copy
    /// for the same failure; only the reason travels into the warning, file
    /// bytes never do.
    /// - Parameters:
    ///   - relative: Root-relative display path.
    ///   - reason: Short failure reason, never file content.
    /// - Returns: Warning line for the run.
    static func skipWarningText(relative: String, reason: String) -> String {
        "Skipped '\(safeRelative(relative) ?? "item")': \(reason)"
    }

    /// Reports whether a stored fingerprint proves the file is unchanged.
    ///
    /// Single-sourced so the sequential fast path and the parallel worker
    /// agree: a non-failed prior extraction plus a matching size and an mtime
    /// within tolerance means the body is current without reading any bytes.
    /// - Parameters:
    ///   - fingerprint: Stored fingerprint for the file.
    ///   - size: Live file size in bytes.
    ///   - currentMtime: Live modification time, when known.
    /// - Returns: True when the file can be skipped without a read.
    static func fingerprintMatchesStored(
        _ fingerprint: DocStoredFingerprint,
        size: Int,
        currentMtime: Date?
    ) -> Bool {
        guard fingerprint.extractStatus != .failed,
              fingerprint.sizeBytes == Int64(size),
              let storedMtime = fingerprint.mtime,
              let currentMtime
        else {
            return false
        }
        return abs(storedMtime.timeIntervalSince(currentMtime)) <= Self.fingerprintMtimeTolerance
    }

    /// Reports whether a document's tail chunks stayed keyword-only under the cap.
    ///
    /// Single-sourced so sequential and parallel commits count truncation the
    /// same way: vectors present plus more chunks than the cap means the tail
    /// was left keyword-only.
    /// - Parameters:
    ///   - vectors: Embedded vectors, or nil when the document stayed keyword-only.
    ///   - chunkCount: Total chunks in the extraction.
    ///   - cap: Maximum vectors for the document; values at or below zero mean unlimited.
    /// - Returns: True when the document was truncated by the cap.
    static func isVectorTruncated(vectors: [[Float]]?, chunkCount: Int, cap: Int) -> Bool {
        vectors != nil && cap > 0 && chunkCount > cap
    }

    /// Validates one embedding batch against the texts sent.
    ///
    /// Single-sourced so sequential and parallel embedding agree: a width or
    /// count mismatch degrades to keyword-only instead of pairing a wrong
    /// vector with a chunk.
    /// - Parameters:
    ///   - vectors: Vectors returned by the backend.
    ///   - expectedCount: Number of texts sent for embedding.
    /// - Returns: Vectors when the count matches, or nil to stay keyword-only.
    static func validatedEmbedVectors(_ vectors: [[Float]], expectedCount: Int) -> [[Float]]? {
        vectors.count == expectedCount ? vectors : nil
    }

    /// Reports whether components hold the scoped scratch prefix.
    ///
    /// Single-sourced so relative-path and absolute-URL checks agree: only a
    /// consecutive `.runeweaver`/`workspace` pair counts, never a bare
    /// `workspace` component or a file named `workspace` elsewhere.
    /// - Parameter components: Lowercased `/`-separated path components.
    /// - Returns: True when the path lies inside `.runeweaver/workspace`.
    static func isWorkspaceScratchComponents(_ components: [String]) -> Bool {
        guard components.count >= 2 else { return false }
        for index in 0 ..< (components.count - 1) {
            if components[index] == ".runeweaver", components[index + 1] == "workspace" {
                return true
            }
        }
        return false
    }

    /// Reports whether a root-relative path lies inside agent scratch.
    /// - Parameter relativePath: Path relative to the walk root.
    /// - Returns: True only for the `.runeweaver/workspace` subtree.
    static func isWorkspaceScratchRelativePath(_ relativePath: String) -> Bool {
        let components = relativePath.lowercased().split(separator: "/").map(String.init)
        return isWorkspaceScratchComponents(components)
    }

    /// Reports whether an absolute file URL lies inside agent scratch.
    ///
    /// Covers walks rooted inside the scratch tree itself, where the
    /// root-relative path no longer carries the `.runeweaver` prefix but the
    /// absolute path still does.
    /// - Parameter url: Candidate file or directory URL.
    /// - Returns: True only for the `.runeweaver/workspace` subtree.
    static func isWorkspaceScratchURL(_ url: URL) -> Bool {
        let components = url.standardizedFileURL.path.lowercased().split(separator: "/").map(String.init)
        return isWorkspaceScratchComponents(components)
    }

    /// Reports whether a candidate is excluded by the given patterns.
    ///
    /// Static so the shared walk classification stays off the actor: the
    /// matcher itself is case-sensitive, so both sides lower to agree with
    /// the case-insensitive filesystem. Plain directory names (no slash or
    /// glob syntax) match any path component so an excluded tree stays
    /// excluded for files nested beneath it even when the walker would have
    /// pruned the parent. Agent scratch is scoped separately: only the
    /// `.runeweaver/workspace` prefix counts, never a bare `workspace`
    /// component or a file named `workspace`, so a stale `workspace` pattern
    /// in configuration stays inert outside scratch.
    /// - Parameters:
    ///   - relativePath: Path relative to the walk root.
    ///   - filename: Final path component.
    ///   - patterns: Built-in plus configured exclude patterns.
    /// - Returns: True when the candidate is skipped.
    static func isExcluded(relativePath: String, filename: String, patterns: [String]) -> Bool {
        let loweredRelative = relativePath.lowercased()
        let loweredFilename = filename.lowercased()
        let components = loweredRelative.split(separator: "/").map(String.init)
        // Scoped scratch exclusion first: unconditional, independent of
        // whether any pattern still names `workspace`.
        if isWorkspaceScratchComponents(components) {
            return true
        }
        return patterns.contains { raw in
            let pattern = raw.lowercased()
            // A bare `workspace` pattern never matches by component: only the
            // scoped prefix above excludes scratch, so user trees like
            // `~/projects/workspace/notes.md` stay indexable.
            if raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "workspace" {
                return false
            }
            // Bare directory names guard the whole subtree: any component
            // match excludes nested files without requiring a glob.
            if !pattern.contains("/"), !pattern.contains("*"), !pattern.contains("?"), !pattern.contains("[") {
                if loweredFilename == pattern {
                    return true
                }
                if components.contains(pattern) {
                    return true
                }
            }
            return SharedGlobMatching.matchesPath(
                pattern: pattern,
                relativePath: loweredRelative,
                filename: loweredFilename
            )
        }
    }

    /// Expresses a file relative to the walk root for display.
    /// - Parameters:
    ///   - url: Candidate file URL.
    ///   - root: Walk root.
    /// - Returns: Relative path, or the final path component when outside the root.
    static func relativePath(of url: URL, root: URL) -> String {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        if url.path.hasPrefix(prefix) {
            let relative = String(url.path.dropFirst(prefix.count))
            if !relative.isEmpty {
                return relative
            }
        }
        return url.lastPathComponent
    }

    /// Normalizes a relative display path, dropping anything that could reveal
    /// an absolute location or climb outside its root.
    /// - Parameter path: Candidate relative path.
    /// - Returns: A trimmed relative path capped for display, or nil when unsafe.
    static func safeRelative(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~") else { return nil }
        guard !trimmed.split(separator: "/").contains("..") else { return nil }
        return String(trimmed.prefix(maxCurrentLength))
    }

    /// Deduplicates patterns while preserving first-seen order.
    /// - Parameter patterns: Raw patterns in priority order.
    /// - Returns: Unique patterns.
    static func deduplicated(_ patterns: [String]) -> [String] {
        var seen: Set<String> = []
        var unique: [String] = []
        for pattern in patterns {
            let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { continue }
            unique.append(trimmed)
        }
        return unique
    }
}

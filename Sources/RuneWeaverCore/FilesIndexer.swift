// Rune Weaver Core — Local files indexer feeding the document index.

import CryptoKit
import Foundation

// MARK: - Indexer

/// Actor that walks configured roots and maintains the local files index.
public actor FilesIndexer {
    /// Directory and file names the files walker always skips, before `IndexConfig.exclude`.
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
        ".venv",
        "site-packages",
        "dist",
        "build",
        ".build",
        ".next",
        ".turbo",
        ".fastlane"
    ]

    /// Longest relative path retained on a progress frame, bounding frame size.
    static let maxCurrentLength = 240

    /// Modification-time tolerance for the pre-read fingerprint fast path.
    static let fingerprintMtimeTolerance: TimeInterval = 1.0

    /// Document index the run writes into.
    let store: DocIndexStore
    /// Text extractor injected so a test can stub extraction without real files.
    let extractor: any DocumentTextExtracting
    /// Embeddings backend consulted inside the vector policy; nil stays keyword-only.
    let embedder: any EmbeddingsBackend?
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

    /// Creates a files indexer. store: Document index to write into.
    public init(
        store: DocIndexStore,
        extractor: any DocumentTextExtracting = DocumentTextExtractor(),
        embedder: any EmbeddingsBackend? = nil,
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

    /// Requests cancellation of the run in flight. Parallel workers observe the same request
    /// through a lock-guarded mirror and stop launching new files within one batch.
    public func cancel() {
        isCancelled = true
        cancelBox.set()
    }

    /// Runs one pass over every configured root.
    public func run() async -> FilesIndexRunReport {
        guard config.enabled, config.files else {
            return FilesIndexRunReport(skippedReason: "File indexing is disabled in [index].")
        }
        if let embedder, let dim = await embedder.dimension {
            _ = try? await store.ensureEmbeddingDimensionMatch(
                activeModelID: embedder.modelID,
                activeDimension: dim,
                mailCheckpointPath: MailIndexCheckpointStore.defaultPath,
                messagesStatePath: MessagesIndexer.defaultStatePath
            )
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
        /// Live modality queue progress across the 4 file processing lanes.
        var queueLanes: [IndexQueueLaneProgress] = []
    }

    /// Runs one sequential pass over every configured root.
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
    func isSequentialThermalHaltRequested() -> Bool {
        currentWorkerLimit(base: max(1, resolvedWorkerCount())) <= 0
    }

    /// Records a sequential thermal/battery halt with the parallel copy.
    func noteSequentialThermalHalt(counters: inout Counters) {
        counters.thermalStoppedEarly = true
        if config.pauseOnBattery, lowPowerModeProvider() {
            counters.warnings.append("Paused new work: Low Power Mode is on")
        } else {
            counters.warnings.append("Paused new work: thermal state is critical")
        }
    }

    /// Runs one pass over every configured root with at most `workers` files in flight.
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
        let preloadedFingerprints = try? await store.storedFingerprints(source: .files)
        let candidates = await collectAllCandidates(
            workers: workers,
            budget: budget,
            start: start,
            preloadedFingerprints: preloadedFingerprints,
            counters: &counters
        )

        await runQueuedModalityPipeline(
            candidates: candidates,
            workers: workers,
            budget: budget,
            start: start,
            preloadedFingerprints: preloadedFingerprints,
            counters: &counters
        )

        let retiredCount = await retireUnseenFiles(runID: runID, counters: &counters)
        let settledCancelled = isCancelled || cancelBox.isSet || Task.isCancelled
        await emit(message: Self.finishMessage(report: counters, cancelled: settledCancelled), counters: counters, current: nil, start: start)
        return buildReport(from: counters, retiredCount: retiredCount, cancelled: settledCancelled)
    }

    /// Collects candidate files across all configured roots and partitions them into modality queues.
    private func collectAllCandidates(
        workers: Int,
        budget: FileIndexBudget,
        start: ContinuousClock.Instant,
        preloadedFingerprints: [String: DocStoredFingerprint]?,
        counters: inout Counters
    ) async -> [(file: URL, root: URL)] {
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
            await candidates.append(contentsOf: collectCandidates(rootURL: rootURL, rawRoot: root, workers: workers, budget: budget, counters: &counters))
        }
        return await preflightAndPartitionCandidates(
            discovered: candidates,
            budget: budget,
            start: start,
            preloadedFingerprints: preloadedFingerprints,
            counters: &counters
        )
    }

    /// Enumerates one root sequentially, collecting committable file candidates.
    func collectCandidates(rootURL: URL, rawRoot: String = "", workers: Int, budget: FileIndexBudget, counters: inout Counters) async -> [(file: URL, root: URL)] {
        var collected: [(file: URL, root: URL)] = []
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory)
        // A missing root marks the run unreadable like the sequential path so
        // the reconcile stays skipped instead of deleting live documents.
        guard exists else {
            if Self.isOptionalCloudRoot(rootURL: rootURL, rawRoot: rawRoot) {
                return collected
            }
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
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            counters.hasUnreadableRoot = true
            return collected
        }
        var sinceYield = 0
        while let element = enumerator.nextObject() {
            // Cooperative pause so `cancel()` reaches the actor on huge trees: the lock-guarded
            // mirror and the task flag stop the walk without waiting on actor state, and each pause
            // also lets a pending cancellation request land.
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
    func foldOutcome(_ outcome: FileOutcome, counters: inout Counters, start: ContinuousClock.Instant) async {
        if outcome.propagateCancel {
            isCancelled = true
            cancelBox.set()
        }
        if !outcome.preScanned {
            counters.scanned += 1
        }
        Self.recordQueueLaneOutcome(outcome, lanes: &counters.queueLanes)
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
        await Task.yield()
    }

    /// Emits one progress frame. message: Human-readable status line, safe to
    /// display verbatim.
    func emit(message: String, counters: Counters, current: String?, start: ContinuousClock.Instant) async {
        await progress(ToolProgress(
            message: message,
            scanned: counters.scanned,
            matched: counters.indexed,
            elapsedMs: elapsedMs(since: start),
            current: current,
            vectorChunks: counters.vectors,
            keywordChunks: max(0, counters.chunks - counters.vectors),
            queues: counters.queueLanes.isEmpty ? nil : counters.queueLanes
        ))
    }

    /// Work-frame status line.
    /// - Parameter counters: Cumulative run counters.
    /// - Returns: `Indexing files: N indexed, M scanned, K skipped, E errors`.
    static func workMessage(counters: Counters) -> String {
        "Indexing files: \(counters.indexed) indexed, \(counters.scanned) scanned, \(counters.skipped) skipped, \(counters.errors) errors"
    }

    /// Final-frame status line. report: Counters accumulated by the run.
    static func finishMessage(report: Counters, cancelled: Bool) -> String {
        let verb = cancelled ? "cancelled" : "finished"
        return "Files indexing \(verb): \(report.indexed) indexed, \(report.scanned) scanned, \(report.errors) errors"
    }

    /// Reports whether a candidate is excluded by built-in or configured patterns.
    /// relativePath: Path relative to the walk root.
    func isExcluded(relativePath: String, filename: String) -> Bool {
        Self.isExcluded(relativePath: relativePath, filename: filename, patterns: excludePatterns)
    }

    /// Disposition of one enumerated entry, shared by the sequential walk and parallel discovery.
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

    /// Reports whether a file's bytes are evicted in iCloud. url: Canonical file
    /// URL.
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
    static func isLiveEvicted(at url: URL, values: URLResourceValues? = nil) -> Bool {
        let resolved: URLResourceValues? = if let values {
            values
        } else {
            try? url.resourceValues(forKeys: Set([.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]))
        }
        guard resolved?.isUbiquitousItem == true, let status = resolved?.ubiquitousItemDownloadingStatus else { return false }
        return status == URLUbiquitousItemDownloadingStatus.notDownloaded
    }

    /// Best-effort trigger for an evicted iCloud download; failures are ignored.
    static func startLiveDownload(at url: URL) {
        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        } catch {
            RuneWeaverLog.stores.debug("FilesIndexer: failed to trigger download for ubiquitous item at \(url.path): \(error.localizedDescription)")
        }
    }

    /// Maps extraction chunks to indexed chunks, attaching vectors when present.
    /// extraction: Extracted document body.
    static func makeChunks(
        extraction: DocumentExtraction,
        documentID: UUID,
        vectors: [[Float]]?,
        fallbackDisplayName: String? = nil,
        fallbackPath: String? = nil
    ) -> [IndexedChunk] {
        if extraction.chunks.isEmpty {
            if let displayName = fallbackDisplayName {
                // Single-sourced fallback body so the indexer and the office
                // extraction layer never drift on labels or format tokens.
                let path = (fallbackPath?.isEmpty == false ? fallbackPath : nil) ?? displayName
                let text = DocumentTextExtractor.fallbackMetadataText(
                    displayName: displayName,
                    formatToken: extraction.format.rawValue,
                    path: path
                )
                let vector = vectors?.first ?? []
                return [IndexedChunk(documentID: documentID, ordinal: 0, text: text, embedding: vector)]
            }
            return []
        }
        return extraction.chunks.enumerated().map { position, chunk in
            let vector = vectors.flatMap { $0.indices.contains(position) ? $0[position] : nil } ?? []
            return IndexedChunk(documentID: documentID, ordinal: chunk.index, text: chunk.text, embedding: vector)
        }
    }

    /// Reports whether the iCloud evicted policy requests a download.
    static func isDownloadPolicy(_ rawValue: String) -> Bool {
        rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "download"
    }

    /// Builds the content-free warning line for one skipped file. Single-sourced so sequential and
    /// parallel paths report the same copy for the same failure; only the reason travels into the
    /// warning, file bytes never do.
    static func skipWarningText(relative: String, reason: String) -> String {
        "Skipped '\(safeRelative(relative) ?? "item")': \(reason)"
    }

    /// Reports whether a stored fingerprint proves the file is unchanged.
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
    static func isVectorTruncated(vectors: [[Float]]?, chunkCount: Int, cap: Int) -> Bool {
        vectors != nil && cap > 0 && chunkCount > cap
    }

    /// Validates one embedding batch against the texts sent. Single-sourced so sequential and
    /// parallel embedding agree: a width or count mismatch degrades to keyword-only instead of
    /// pairing a wrong vector with a chunk.
    static func validatedEmbedVectors(
        _ vectors: [[Float]],
        expectedCount: Int,
        expectedDimension: Int? = nil
    ) -> [[Float]]? {
        guard vectors.count == expectedCount else { return nil }
        guard !vectors.isEmpty else { return vectors }
        guard let firstWidth = vectors.first?.count, firstWidth > 0, vectors.allSatisfy({ $0.count == firstWidth }) else { return nil }
        if let expected = expectedDimension, firstWidth != expected {
            return nil
        }
        return vectors
    }

    /// Reports the stored status for an image after the visual-embedding attempt.
    static func effectiveImageStatus(extraction: DocumentExtraction, visualSucceeded: Bool) -> ExtractStatus {
        guard extraction.format == .image else { return extraction.status }
        return visualSucceeded ? .extracted : extraction.status
    }

    /// Embeds a single image file via visual multimodal embedding, verifying vector width against
    /// expected dimension. fileURL: Location of the image file on disk.
    static func embedImageVisualVector(
        fileURL _: URL,
        fileName: String,
        expectedDimension: Int?,
        embedImage: () async throws -> [Float]
    ) async throws -> [[Float]]? {
        do {
            let vector = try await embedImage()
            let targetDim = expectedDimension ?? 768
            if vector.count == targetDim {
                return [vector]
            }
            RuneWeaverLog.stores.warning(
                "FilesIndexer: Visual embedding dimension mismatch for \(fileName): got \(vector.count), expected \(targetDim)."
            )
            return nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            RuneWeaverLog.stores.info(
                "FilesIndexer: Visual embedding unavailable for \(fileName), falling back to text OCR: \(error.localizedDescription)"
            )
            return nil
        }
    }

    /// Reports whether components hold the scoped scratch prefix.
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

    /// Reports whether an absolute file URL lies inside agent scratch. - Returns: True only for the
    /// `.runeweaver/workspace` subtree.
    static func isWorkspaceScratchURL(_ url: URL) -> Bool {
        let components = url.standardizedFileURL.path.lowercased().split(separator: "/").map(String.init)
        return isWorkspaceScratchComponents(components)
    }

    /// Reports whether a path relative to the walk root is an allowed cloud storage path within
    /// Library.
    static func isAllowedLibraryCloudPath(components: [String]) -> Bool {
        guard !components.isEmpty, components[0] == "library" else { return false }
        if components.count == 1 {
            // Exactly "library": allow descending so CloudStorage and Mobile Documents are reached
            return true
        }
        let second = components[1]
        return second == "cloudstorage" || second == "mobile documents"
    }

    /// Reports whether a root path is an optional cloud storage root.
    static func isOptionalCloudRoot(rootURL: URL, rawRoot: String? = nil) -> Bool {
        // Component-anchored so a coincidental substring never clears the
        // unreadable-root flag: only an exact cloud component or a Library
        // cloud-storage prefix counts, never `~/Documents/icloud drive backup`.
        if isCloudRootComponents(pathComponents(of: rootURL.path)) {
            return true
        }
        if let rawRoot, !rawRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if isCloudRootComponents(pathComponents(of: rawRoot)) {
                return true
            }
        }
        return false
    }

    /// Splits a raw path into lowercased components for cloud-root matching.
    /// - Parameter rawPath: File path or configured root string.
    /// - Returns: Non-empty lowercased components.
    private static func pathComponents(of rawPath: String) -> [String] {
        rawPath.lowercased().split(separator: "/").map(String.init).filter { !$0.isEmpty }
    }

    /// Reports whether anchored components name an optional cloud root.
    private static func isCloudRootComponents(_ components: [String]) -> Bool {
        guard !components.isEmpty else { return false }
        for index in 0 ..< components.count {
            if components[index] == "library", index + 1 < components.count {
                let next = components[index + 1]
                if next == "cloudstorage" || next == "mobile documents" {
                    return true
                }
            }
            if components[index] == "icloud drive" || components[index] == "com~apple~clouddocs" {
                return true
            }
        }
        return false
    }

    /// Reports whether a candidate is excluded by the given patterns.
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
            // A Library prune still descends into the two allowed cloud
            // subtrees; configured spellings of the same root honor it too.
            var libraryPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            if libraryPattern.hasPrefix("~/") {
                libraryPattern = String(libraryPattern.dropFirst(2))
            }
            if libraryPattern.hasSuffix("/*") {
                libraryPattern = String(libraryPattern.dropLast(2))
            } else if libraryPattern.hasSuffix("/") {
                libraryPattern = String(libraryPattern.dropLast(1))
            }
            if libraryPattern == "library", isAllowedLibraryCloudPath(components: components) {
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

    /// Expresses a file relative to the walk root for display. url: Candidate file
    /// URL.
    static func relativePath(of url: URL, root: URL) -> String {
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let canonicalURL = url.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = canonicalRoot.hasSuffix("/") ? canonicalRoot : canonicalRoot + "/"
        if canonicalURL.hasPrefix(prefix) {
            let relative = String(canonicalURL.dropFirst(prefix.count))
            if !relative.isEmpty {
                return relative
            }
        }
        let fallbackPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        if url.path.hasPrefix(fallbackPrefix) {
            let relative = String(url.path.dropFirst(fallbackPrefix.count))
            if !relative.isEmpty {
                return relative
            }
        }
        return url.lastPathComponent
    }

    /// Normalizes a relative display path, dropping anything that could reveal an absolute location
    /// or climb outside its root.
    /// - Parameter path: Candidate relative path.
    static func safeRelative(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~"), !trimmed.split(separator: "/").contains("..") else { return nil }
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

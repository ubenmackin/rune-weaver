// Rune Weaver Core — Local files indexer feeding the document index.
//
// Walks the configured roots once per run, prunes excluded trees (media
// libraries, VCS and dependency output, caches, and the app's own state), and
// refuses symlinked entries so a link loop or a link out of policy can never be
// traversed. Evicted iCloud files honor `IndexConfig.iCloudEvicted`: skipped by
// default and downloaded only under the `download` policy.
// Every accepted file is hashed, skipped when `DocIndexStore`
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

import CryptoKit
import Foundation

// MARK: - Report

/// Outcome of one files indexing run.
public struct FilesIndexRunReport: Sendable, Equatable {
    /// Files examined, including those later skipped.
    public var filesScanned = 0
    /// Documents written during the run.
    public var filesIndexed = 0
    /// Files skipped because their stored body hash was already current.
    public var filesUnchanged = 0
    /// Files deliberately skipped (excluded, denied, symlinked, oversized, or unsupported).
    public var filesSkipped = 0
    /// Files that could not be read, extracted, or written.
    public var errors = 0
    /// Text chunks written during the run.
    public var chunksWritten = 0
    /// Chunks written carrying an embedding during the run.
    public var vectorsWritten = 0
    /// Non-fatal per-file problems, without any file content.
    public var warnings: [String] = []
    /// Set when the run did not execute because file indexing is disabled.
    public var skippedReason: String?
    /// Set when the run stopped early on cancellation.
    public var cancelled = false

    /// Creates a run report.
    /// - Parameter skippedReason: Set when the run was skipped.
    public init(skippedReason: String? = nil) {
        self.skippedReason = skippedReason
    }

    /// Whether the indexer actually ran.
    public var didRun: Bool {
        skippedReason == nil
    }
}

// MARK: - Access seam

/// Outcome of evaluating one path against the file access policy.
public struct FilesIndexAccessDecision: Sendable, Equatable {
    /// Whether the path may be read without escalation.
    public let allowed: Bool
    /// Whether the caller should surface an approval escalation hint.
    public let requiresApproval: Bool
    /// Human-readable policy reason (never file content).
    public let reason: String?
    /// Canonical path the decision was made against.
    public let resolvedPath: String

    /// Creates a decision.
    public init(allowed: Bool, requiresApproval: Bool = false, reason: String? = nil, resolvedPath: String) {
        self.allowed = allowed
        self.requiresApproval = requiresApproval
        self.reason = reason
        self.resolvedPath = resolvedPath
    }
}

/// Protocol seam over the shared file access policy.
///
/// The concrete guard lives in the tools layer beside the file tools; the
/// indexer depends only on this seam so a policy change never reaches into the
/// core, and a test can deny one path without touching the real filesystem
/// policy. Implementations must never resolve or read a denied path.
public protocol FilesIndexAccessGuard: Sendable {
    /// Evaluates one candidate path.
    /// - Parameters:
    ///   - path: Raw candidate path.
    ///   - homeDirectoryURL: Home boundary override, or nil for the real home.
    /// - Returns: The policy decision for the path.
    func evaluate(path: String, homeDirectoryURL: URL?) -> FilesIndexAccessDecision
}

// MARK: - Vector policy

/// Decides whether an extracted document's chunks are vectorized.
///
/// A vector is a semantic claim about the whole document, so a truncated body
/// is keyword-only by default: surfacing half a document as a nearest neighbour
/// would mislead recall more than it helps. The byte bound keeps a large source
/// that is technically extractable from fanning an outsized embedding batch.
public struct FilesVectorPolicy: Sendable, Equatable {
    /// Whether an injected embeddings backend is consulted at all.
    public var enabled: Bool
    /// Whether partially extracted documents are also vectorized.
    public var includePartial: Bool
    /// Largest document, in bytes, that is vectorized.
    public var maxBytes: Int

    /// Default byte bound for vectorized documents (2 MB).
    public static let defaultMaxBytes = 2 * 1024 * 1024

    /// Creates a vector policy.
    public init(enabled: Bool = true, includePartial: Bool = false, maxBytes: Int = defaultMaxBytes) {
        self.enabled = enabled
        self.includePartial = includePartial
        self.maxBytes = max(0, maxBytes)
    }

    /// Reports whether a document is inside the vector policy.
    /// - Parameters:
    ///   - status: Extraction outcome.
    ///   - byteCount: Bytes considered for the document.
    /// - Returns: True when the document's chunks should be vectorized.
    public func shouldEmbed(status: ExtractStatus, byteCount: Int) -> Bool {
        guard enabled, byteCount <= maxBytes else { return false }
        switch status {
        case .extracted:
            return true
        case .partial:
            return includePartial
        default:
            return false
        }
    }
}

// MARK: - Indexer

/// Actor that walks configured roots and maintains the local files index.
///
/// One actor owns a run so cancellation and counters stay serialized. Every
/// dependency that touches the outside world — the document store, the text
/// extractor, the path policy, and the embeddings backend — is injected, so the
/// walker is exercised against fixtures without a real home directory.
public actor FilesIndexer {
    /// Directory and file names skipped on every walk, before `IndexConfig.exclude`.
    ///
    /// Media libraries are excluded because the index is for documents, not
    /// media; VCS, dependency, and cache trees are excluded because their
    /// contents are machine output; and `.runeweaver` is excluded so the index
    /// never indexes its own database or logs.
    public static let defaultExcludePatterns = [
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

    /// Document index the run writes into.
    private let store: DocIndexStore
    /// Text extractor injected so a test can stub extraction without real files.
    private let extractor: any DocumentTextExtracting
    /// Embeddings backend consulted inside the vector policy; nil stays keyword-only.
    private let embedder: (any EmbeddingsBackend)?
    /// Path policy consulted before any candidate is opened.
    private let accessGuard: any FilesIndexAccessGuard
    /// Which extracted documents get vectors.
    private let vectorPolicy: FilesVectorPolicy
    /// Roots, excludes, size cap, and budget for the walk.
    private let config: IndexConfig
    /// Home boundary override for tests; nil means the real home.
    private let homeDirectoryURL: URL?
    /// Override resolving evicted iCloud files; nil uses the live ubiquity check. Test seam only.
    private let evictedCheck: (@Sendable (URL) -> Bool)?
    /// Starts an iCloud download for an evicted file; nil uses `FileManager`. Test seam only.
    private let downloadStarter: (@Sendable (URL) -> Void)?
    /// Monotonic instant source, injectable so a test advances time deterministically.
    private let nowProvider: @Sendable () -> ContinuousClock.Instant
    /// Advisory progress sink mirroring the tool progress reporter contract.
    private let progress: ToolProgressReporter
    /// Cooperative cancellation flag set by ``cancel()``.
    private var isCancelled = false
    /// Built-in plus configured exclude patterns, deduplicated at construction.
    private let excludePatterns: [String]
    /// Whether a work frame has been emitted for the run in flight.
    private var hasReportedWork = false
    /// Instant of the last work frame, for the shared report cadence.
    private var lastReportInstant: ContinuousClock.Instant?

    /// Creates a files indexer.
    /// - Parameters:
    ///   - store: Document index to write into.
    ///   - extractor: Text extractor for candidate files.
    ///   - embedder: Embeddings backend, or nil for keyword-only indexing.
    ///   - accessGuard: Path policy consulted before opening a candidate.
    ///   - vectorPolicy: Which extracted documents are vectorized.
    ///   - config: Walk roots, excludes, size cap, and budget.
    ///   - homeDirectoryURL: Home boundary override, or nil for the real home.
    ///   - evictedCheck: Override resolving evicted iCloud files, or nil for the live check.
    ///   - downloadStarter: Download trigger for the `download` policy, or nil for `FileManager`.
    ///   - nowProvider: Monotonic instant source.
    ///   - progress: Advisory progress sink; defaults to a no-op.
    public init(
        store: DocIndexStore,
        extractor: any DocumentTextExtracting = DocumentTextExtractor(),
        embedder: (any EmbeddingsBackend)? = nil,
        accessGuard: any FilesIndexAccessGuard,
        vectorPolicy: FilesVectorPolicy = FilesVectorPolicy(),
        config: IndexConfig,
        homeDirectoryURL: URL? = nil,
        evictedCheck: (@Sendable (URL) -> Bool)? = nil,
        downloadStarter: (@Sendable (URL) -> Void)? = nil,
        nowProvider: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now },
        progress: @escaping ToolProgressReporter = ToolContext.noProgress
    ) {
        self.store = store
        self.extractor = extractor
        self.embedder = embedder
        self.accessGuard = accessGuard
        self.vectorPolicy = vectorPolicy
        self.config = config
        self.homeDirectoryURL = homeDirectoryURL
        self.evictedCheck = evictedCheck
        self.downloadStarter = downloadStarter
        self.nowProvider = nowProvider
        self.progress = progress
        self.excludePatterns = Self.deduplicated(Self.defaultExcludePatterns + config.exclude)
    }

    /// Requests cancellation of the run in flight.
    ///
    /// Cancellation is cooperative and observed between files, so a file already
    /// being written finishes its document and chunks before the run stops;
    /// nothing is left half-written for the next run to misread as current.
    public func cancel() {
        isCancelled = true
    }

    /// Runs one pass over every configured root.
    ///
    /// The run never throws: an unreadable file or a store failure is counted
    /// as an error and the walk continues, because a background index should
    /// make progress on the rest of the tree rather than abort on one bad entry.
    /// Cancellation stops the walk between files and is reported on the result.
    /// - Returns: Counts describing the run.
    public func run() async -> FilesIndexRunReport {
        guard config.enabled, config.files else {
            return FilesIndexRunReport(skippedReason: "File indexing is disabled in [index].")
        }
        isCancelled = false
        hasReportedWork = false
        lastReportInstant = nil
        let start = nowProvider()
        var counters = Counters()
        counters.budgetRemaining = config.nightlyBudget > 0 ? config.nightlyBudget : Int.max
        await emit(message: Self.startMessage, counters: counters, current: nil, start: start)
        for root in config.roots {
            if shouldStop(counters) {
                break
            }
            await indexRoot(root, start: start, counters: &counters)
        }
        let cancelled = isCancelled || Task.isCancelled
        await emit(message: Self.finishMessage(report: counters, cancelled: cancelled), counters: counters, current: nil, start: start)
        var report = FilesIndexRunReport()
        report.filesScanned = counters.scanned
        report.filesIndexed = counters.indexed
        report.filesUnchanged = counters.unchanged
        report.filesSkipped = counters.skipped
        report.errors = counters.errors
        report.chunksWritten = counters.chunks
        report.vectorsWritten = counters.vectors
        report.warnings = counters.warnings
        report.cancelled = cancelled
        return report
    }
}

// MARK: - Walk

private extension FilesIndexer {
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
        /// Newly written documents still permitted this run.
        var budgetRemaining = Int.max
        /// Non-fatal per-file problems.
        var warnings: [String] = []
    }

    /// Walks one root, pruning excluded and symlinked directories in place.
    /// - Parameters:
    ///   - root: Raw configured root.
    ///   - start: Instant the run began.
    ///   - counters: Cumulative run counters.
    func indexRoot(_ root: String, start: ContinuousClock.Instant, counters: inout Counters) async {
        let rootURL = resolvedRootURL(root)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory)
        guard exists else { return }
        guard isDirectory.boolValue else {
            await indexFile(rootURL, root: rootURL, start: start, counters: &counters)
            return
        }
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Self.entryKeys,
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return
        }
        while let element = enumerator.nextObject() {
            if shouldStop(counters) {
                return
            }
            guard let url = element as? URL else { continue }
            let values = try? url.resourceValues(forKeys: Self.entryKeySet)
            let isItemDirectory = values?.isDirectory ?? false
            // A symlink is never followed: a link loop cannot form and a link
            // cannot redirect the walk to an out-of-policy target.
            if values?.isSymbolicLink == true {
                if isItemDirectory {
                    enumerator.skipDescendants()
                }
                counters.skipped += 1
                continue
            }
            let filename = url.lastPathComponent
            // AppleDouble resource forks are metadata, not documents.
            if filename.hasPrefix("._") {
                if isItemDirectory {
                    enumerator.skipDescendants()
                }
                counters.skipped += 1
                continue
            }
            let relative = Self.relativePath(of: url, root: rootURL)
            if isExcluded(relativePath: relative, filename: filename) {
                // Excluded trees are pruned without walking them, so only a
                // top-level excluded file is counted as skipped; the descendants
                // of an excluded directory are never enumerated at all.
                if isItemDirectory {
                    enumerator.skipDescendants()
                } else {
                    counters.skipped += 1
                }
                continue
            }
            let decision = accessGuard.evaluate(path: url.resolvingSymlinksInPath().standardizedFileURL.path, homeDirectoryURL: homeDirectoryURL)
            guard decision.allowed else {
                if isItemDirectory {
                    enumerator.skipDescendants()
                }
                counters.skipped += 1
                continue
            }
            if isItemDirectory {
                continue
            }
            await indexFile(URL(fileURLWithPath: decision.resolvedPath), root: rootURL, start: start, counters: &counters)
        }
    }

    /// Indexes one regular file, counting it as scanned before any skip decision.
    /// Evicted iCloud files honor `IndexConfig.iCloudEvicted`: skipped by
    /// default and downloaded only under the `download` policy.
    /// - Parameters:
    ///   - fileURL: Canonical file URL the guard allowed.
    ///   - root: Root the file was discovered under, for display paths.
    ///   - start: Instant the run began.
    ///   - counters: Cumulative run counters.
    func indexFile(_ fileURL: URL, root: URL, start: ContinuousClock.Instant, counters: inout Counters) async {
        counters.scanned += 1
        // Canonicalize for a stable external identifier: temporary roots
        // resolve differently (`/var` vs `/private/var`) between the walk
        // and the caller, so the stored key must not depend on which
        // spelling the enumerator happened to return.
        let canonicalURL = fileURL.resolvingSymlinksInPath().standardizedFileURL
        let canonicalPath = canonicalURL.path
        let relative = Self.relativePath(of: canonicalURL, root: root)
        let filename = canonicalURL.lastPathComponent
        guard let values = try? canonicalURL.resourceValues(forKeys: Self.entryKeySet) else {
            await fail(relative, counters: &counters, start: start, reason: "unreadable")
            return
        }
        if values.isSymbolicLink == true || filename.hasPrefix("._") {
            counters.skipped += 1
            await reportWork(relative, counters: counters, start: start)
            return
        }
        // An evicted iCloud file has no local bytes to hash or extract: skip
        // it under `skip`, and trigger its download under `download` while
        // still skipping this run (the bytes arrive after the walk).
        if isEvictedForPolicy(at: canonicalURL, values: values) {
            if shouldDownloadEvicted {
                startEvictedDownload(at: canonicalURL)
            }
            counters.skipped += 1
            await reportWork(relative, counters: counters, start: start)
            return
        }
        let size = values.fileSize ?? 0
        guard size <= maxFileBytes else {
            counters.skipped += 1
            await reportWork(relative, counters: counters, start: start)
            return
        }
        let decision = accessGuard.evaluate(path: canonicalPath, homeDirectoryURL: homeDirectoryURL)
        guard decision.allowed else {
            counters.skipped += 1
            await reportWork(relative, counters: counters, start: start)
            return
        }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: decision.resolvedPath), options: [.mappedIfSafe])
        } catch {
            await fail(relative, counters: &counters, start: start, reason: "unreadable")
            return
        }
        guard data.count <= maxFileBytes else {
            counters.skipped += 1
            await reportWork(relative, counters: counters, start: start)
            return
        }

        let hash = Self.contentHash(for: data)
        do {
            let needsReindex = try await store.needsReindex(source: .files, externalID: canonicalPath, contentHash: hash)
            guard needsReindex else {
                counters.unchanged += 1
                counters.skipped += 1
                await reportWork(relative, counters: counters, start: start)
                return
            }
        } catch is CancellationError {
            isCancelled = true
            return
        } catch {
            await fail(relative, counters: &counters, start: start, reason: "store lookup failed")
            return
        }

        let extraction = extractor.extract(data: data, fileName: filename, contentType: nil)
        switch extraction.status {
        case .unsupported:
            counters.skipped += 1
            await reportWork(relative, counters: counters, start: start)
            return
        case .failed:
            await fail(relative, counters: &counters, start: start, reason: "extraction failed")
            return
        default:
            break
        }

        await persistExtraction(
            pending: PendingExtraction(
                extraction: extraction,
                canonicalPath: canonicalPath,
                contentHash: hash,
                modificationDate: values.contentModificationDate,
                byteCount: data.count
            ),
            relative: relative,
            start: start,
            counters: &counters
        )
    }

    /// Pending extraction plus its stable identity for persistence.
    struct PendingExtraction: Sendable {
        /// Extracted document body.
        let extraction: DocumentExtraction
        /// Stable external identifier and path.
        let canonicalPath: String
        /// Content hash gating re-indexing.
        let contentHash: String
        /// Source modification time, when known.
        let modificationDate: Date?
        /// Source size in bytes.
        let byteCount: Int
    }

    /// Persists one extraction as a document plus chunks, updating counters.
    /// - Parameters:
    ///   - pending: Extraction plus its stable identity.
    ///   - relative: Root-relative display path.
    ///   - start: Instant the run began.
    ///   - counters: Cumulative run counters.
    func persistExtraction(
        pending: PendingExtraction,
        relative: String,
        start: ContinuousClock.Instant,
        counters: inout Counters
    ) async {
        let filename = (pending.canonicalPath as NSString).lastPathComponent
        let vectors: [[Float]]?
        if vectorPolicy.shouldEmbed(status: pending.extraction.status, byteCount: pending.byteCount), let embedder {
            vectors = await embedChunks(of: pending.extraction, embedder: embedder)
            // Honor cancellation per embedding batch: a cancelled batch stops
            // before its document commits, bounding overrun to one file.
            if isCancelled || Task.isCancelled {
                isCancelled = true
                return
            }
        } else {
            vectors = nil
        }

        let document = IndexedDocument(
            source: .files,
            externalID: pending.canonicalPath,
            displayName: filename,
            path: pending.canonicalPath,
            mtime: pending.modificationDate,
            sizeBytes: Int64(pending.byteCount),
            contentHash: pending.contentHash,
            mime: nil,
            extractStatus: pending.extraction.status,
            indexedAt: Date()
        )
        let written: [IndexedChunk]
        do {
            let stored = try await store.upsertDocument(document)
            let chunks = Self.makeChunks(extraction: pending.extraction, documentID: stored.id, vectors: vectors)
            _ = try await store.upsertChunks(documentID: stored.id, chunks: chunks)
            written = chunks
        } catch is CancellationError {
            isCancelled = true
            return
        } catch {
            await fail(relative, counters: &counters, start: start, reason: "store write failed")
            return
        }
        counters.indexed += 1
        counters.chunks += written.count
        counters.vectors += written.reduce(0) { $0 + ($1.isVector ? 1 : 0) }
        counters.budgetRemaining -= 1
        await reportWork(relative, counters: counters, start: start)
    }

    /// Counts one failed file and records a content-free warning.
    /// - Parameters:
    ///   - relative: Root-relative item path.
    ///   - counters: Cumulative run counters.
    ///   - start: Instant the run began.
    ///   - reason: Short failure reason, never file content.
    func fail(_ relative: String, counters: inout Counters, start: ContinuousClock.Instant, reason: String) async {
        counters.errors += 1
        counters.warnings.append("Skipped '\(Self.safeRelative(relative) ?? "item")': \(reason)")
        await reportWork(relative, counters: counters, start: start)
    }

    /// Embeds a document's chunks, degrading to keyword-only on any failure.
    ///
    /// Cancellation propagates instead of degrading: a cancelled run should
    /// stop rather than silently keep spending embedding work. A width or count
    /// mismatch is treated as a backend failure so a partial vector list never
    /// pairs the wrong vector with a chunk. The probe runs before the batch so
    /// a cancel observed between files never starts another embedding batch.
    /// - Parameters:
    ///   - extraction: Extracted document body.
    ///   - embedder: Backend to consult.
    /// - Returns: One vector per chunk, or nil when the document stays keyword-only.
    func embedChunks(of extraction: DocumentExtraction, embedder: any EmbeddingsBackend) async -> [[Float]]? {
        guard !extraction.chunks.isEmpty else { return nil }
        if isCancelled || Task.isCancelled {
            isCancelled = true
            return nil
        }
        do {
            let vectors = try await embedder.embed(extraction.chunks.map(\.text))
            // A cancel arriving mid-batch still stops before commit.
            if isCancelled || Task.isCancelled {
                isCancelled = true
                return nil
            }
            return vectors.count == extraction.chunks.count ? vectors : nil
        } catch is CancellationError {
            isCancelled = true
            return nil
        } catch {
            return nil
        }
    }
}

// MARK: - Progress

private extension FilesIndexer {
    /// Copy on the opening frame.
    static let startMessage = "Scanning files"
    /// Cadence floor shared with `ToolProgress` so frames never exceed the wire rate.
    static let minimumReportSpacing = Duration.nanoseconds(Int64(ToolProgress.minimumReportIntervalNanoseconds))

    /// Reports whether the run should stop before the next item.
    /// - Parameter counters: Cumulative run counters.
    /// - Returns: True when cancelled or the nightly budget is spent.
    func shouldStop(_ counters: Counters) -> Bool {
        isCancelled || Task.isCancelled || counters.budgetRemaining <= 0
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
        // The shared matcher is case-sensitive; both sides are lowered so
        // excludes agree with the case-insensitive macOS filesystem.
        excludePatterns.contains {
            SharedGlobMatching.matchesPath(
                pattern: $0.lowercased(),
                relativePath: relativePath.lowercased(),
                filename: filename.lowercased()
            )
        }
    }

    /// Whether evicted iCloud files are downloaded instead of skipped.
    /// - Returns: True only for the `download` policy; any other value fails closed to skip.
    var shouldDownloadEvicted: Bool {
        config.iCloudEvicted.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "download"
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

private extension FilesIndexer {
    /// Resource keys prefetched for every enumerated entry.
    static let entryKeys: [URLResourceKey] = [
        .isDirectoryKey,
        .isSymbolicLinkKey,
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

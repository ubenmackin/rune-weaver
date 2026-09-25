// Rune Weaver Core Tests — Files indexer walk, skip, guard, and cancellation behavior.
//
// Exercises one index run against isolated temporary trees: built-in and
// configured excludes prune whole directories, AppleDouble sidecars and
// symlinks are never indexed, an unchanged body is skipped by content hash, a
// denied path never reaches the index, a cancelled run stops between files and
// a resume finishes the tree, and the vector policy keeps partial documents
// keyword-only. The document store is created outside every walked root so the
// index database is never itself a candidate.

import Foundation
import os
@testable import RuneWeaverCore
import Testing

/// Deterministic extractor: blank bodies are metadata-only, `.part` bodies are
/// partial, `.unsupported` names are unsupported, and everything else extracts.
private struct FilesIndexerStubExtractor: DocumentTextExtracting {
    /// Extracts a trivial body so tests never depend on real document parsing.
    func extract(data: Data, fileName: String, contentType _: String?) -> DocumentExtraction {
        if fileName.hasSuffix(".unsupported") {
            return DocumentExtraction(
                status: .unsupported,
                format: .unsupported,
                chunks: [],
                reason: nil,
                byteCount: data.count,
                truncated: false
            )
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        guard !text.isEmpty else {
            return DocumentExtraction(
                status: .metadataOnly,
                format: .plainText,
                chunks: [],
                reason: "empty",
                byteCount: data.count,
                truncated: false
            )
        }
        let status: ExtractStatus = fileName.hasSuffix(".part") ? .partial : .extracted
        return DocumentExtraction(
            status: status,
            format: .plainText,
            chunks: [DocumentChunk(index: 0, text: text, estimatedTokens: 1)],
            reason: nil,
            byteCount: data.count,
            truncated: false
        )
    }
}

/// Guard that denies any path containing one of its markers and allows the rest.
private struct FilesIndexerStubGuard: FilesIndexAccessGuard {
    /// Substrings whose presence denies a candidate path.
    var deniedMarkers: [String] = []

    /// Denies marked paths; allows everything else.
    func evaluate(path: String, homeDirectoryURL _: URL?) -> FilesIndexAccessDecision {
        if deniedMarkers.contains(where: { path.contains($0) }) {
            return FilesIndexAccessDecision(
                allowed: false,
                requiresApproval: true,
                reason: "denied in test",
                resolvedPath: path
            )
        }
        return FilesIndexAccessDecision(allowed: true, resolvedPath: path)
    }
}

/// Deterministic embeddings backend returning one position-tagged vector per input.
private struct FilesIndexerStubEmbedder: EmbeddingsBackend {
    /// Stable stub identifier for diagnostics.
    let modelID = "stub-embeddings"
    /// Fixed stub width.
    let dimension: Int? = 2

    /// Returns one vector per input, preserving order.
    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.enumerated().map { index, _ in [Float(index), 1] }
    }
}

/// Embeddings backend stamping each vector with its instance identifier so pool vending is observable.
private struct FilesIndexerIDEmbedder: EmbeddingsBackend {
    /// Instance identifier assigned by the pool factory.
    let id: Int
    /// Stable stub identifier for diagnostics.
    let modelID = "id-embeddings"
    /// Fixed stub width.
    let dimension: Int? = 1

    /// Returns one identifying vector per input.
    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { _ in [Float(id)] }
    }
}

/// Extractor returning a fixed multi-chunk body so the per-document vector cap is proven.
private struct FilesIndexerMultiChunkExtractor: DocumentTextExtracting {
    /// Number of chunks to return for every file.
    var chunkCount: Int = 5

    /// Returns a fixed multi-chunk extraction regardless of file bytes.
    func extract(data: Data, fileName _: String, contentType _: String?) -> DocumentExtraction {
        let chunks = (0 ..< chunkCount).map { index in
            DocumentChunk(index: index, text: "cap-chunk-\(index) body", estimatedTokens: 2)
        }
        return DocumentExtraction(
            status: .extracted,
            format: .plainText,
            chunks: chunks,
            reason: nil,
            byteCount: data.count,
            truncated: false
        )
    }
}

/// One-shot async signal so a progress report can cancel a run deterministically.
private actor FilesIndexerCancelSignal {
    /// Whether the signal has already fired.
    private var fired = false
    /// Continuations awaiting the signal.
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Fires the signal, resuming every waiter.
    func fire() {
        fired = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }

    /// Suspends until the signal fires.
    func wait() async {
        if fired {
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// Thread-safe recorder for iCloud download triggers.
private final class FilesIndexerDownloadStarts: Sendable {
    /// Guarded canonical paths, in trigger order.
    private let paths = OSAllocatedUnfairLock<[String]>(initialState: [])

    /// Records one download trigger.
    func record(_ path: String) {
        paths.withLock { $0.append(path) }
    }

    /// Recorded canonical paths, in trigger order.
    var all: [String] {
        paths.withLock { $0 }
    }
}

/// Thread-safe counter for file-byte reads so the pre-read fast path is observable.
private final class FilesIndexerCountingReads: Sendable {
    /// Guarded read count.
    private let countLock = OSAllocatedUnfairLock(initialState: 0)

    /// Number of reads observed.
    var count: Int {
        countLock.withLock { $0 }
    }

    /// Reads file bytes while counting the call.
    /// - Parameter url: File URL to read.
    /// - Returns: File bytes.
    func read(_ url: URL) throws -> Data {
        countLock.withLock { $0 += 1 }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }
}

/// Thread-safe in-flight tracker recording current and peak concurrency.
private final class FilesIndexerInFlightTracker: Sendable {
    /// Guarded concurrency state.
    private let state = OSAllocatedUnfairLock(initialState: (current: 0, peak: 0))

    /// Records one unit of work starting.
    func enter() {
        state.withLock { value in
            value.current += 1
            value.peak = max(value.peak, value.current)
        }
    }

    /// Records one unit of work finishing.
    func exit() {
        state.withLock { value in
            value.current -= 1
        }
    }

    /// Highest concurrency observed so far.
    var peak: Int {
        state.withLock { $0.peak }
    }
}

/// Creates an isolated temporary directory.
/// - Returns: The created directory, canonicalized so walk and lookup keys agree.
private func makeTemporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("runeweaver-filesindexer-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    // Resolve the temporary symlink (`/var` vs `/private/var`) so the
    // fixture paths match the enumerator's canonical spelling.
    return url.resolvingSymlinksInPath().standardizedFileURL
}

/// Writes UTF-8 contents, creating intermediate directories.
/// - Parameters:
///   - contents: Text to write.
///   - url: Destination file URL.
private func writeFile(_ contents: String, at url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? Data(contents.utf8).write(to: url)
}

/// Creates a document store outside any walked root.
/// - Returns: The store plus its directory to remove on teardown.
private func makeStore() -> (store: DocIndexStore, directory: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("runeweaver-filesindexer-store-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let canonical = directory.resolvingSymlinksInPath().standardizedFileURL
    return (DocIndexStore(dbPath: canonical.appendingPathComponent("docindex.db").path), canonical)
}

/// Builds an indexer over one temporary root with the test stubs.
/// - Parameters:
///   - store: Document store to write into.
///   - root: Directory to walk.
///   - accessGuard: Path policy stub.
///   - exclude: User-configured exclude patterns.
///   - embedder: Optional embeddings backend.
///   - embeddingsPool: Optional pooled backends for parallel workers.
///   - workerCountOverride: Files in flight when set; nil resolves from config.
///   - thermalStateProvider: Thermal state source; nil observes the live state.
///   - lowPowerModeProvider: Low Power Mode source; nil observes the live state.
///   - vectorPolicy: Vector policy for the run.
///   - nightlyBudget: Maximum newly written documents per run; 0 is unlimited.
///   - iCloudEvicted: Evicted-iCloud policy (`skip` or `download`).
///   - evictedCheck: Override resolving evicted files, or nil for the live check.
///   - downloadStarter: Download trigger for the `download` policy, or nil for `FileManager`.
///   - fileReader: Override reading file bytes, or nil for memory-mapped reads.
///   - maxVectorChunks: Per-document vector cap.
///   - progress: Advisory progress sink.
/// - Returns: A configured indexer.
private func makeIndexer(
    store: DocIndexStore,
    root: URL,
    accessGuard: any FilesIndexAccessGuard,
    exclude: [String] = [],
    embedder: (any EmbeddingsBackend)? = nil,
    embeddingsPool: EmbeddingsBackendPool? = nil,
    workerCountOverride: Int? = nil,
    thermalStateProvider: (@Sendable () -> ProcessInfo.ThermalState)? = nil,
    lowPowerModeProvider: (@Sendable () -> Bool)? = nil,
    vectorPolicy: FilesVectorPolicy = FilesVectorPolicy(),
    nightlyBudget: Int = 0,
    iCloudEvicted: String = IndexConfig.defaultICloudEvicted,
    evictedCheck: (@Sendable (URL) -> Bool)? = nil,
    downloadStarter: (@Sendable (URL) -> Void)? = nil,
    fileReader: (@Sendable (URL) throws -> Data)? = nil,
    maxVectorChunks: Int = IndexConfig.defaultMaxVectorChunksPerDocument,
    progress: @escaping ToolProgressReporter = ToolContext.noProgress
) -> FilesIndexer {
    FilesIndexer(
        store: store,
        extractor: FilesIndexerStubExtractor(),
        embedder: embedder,
        embeddingsPool: embeddingsPool,
        workerCountOverride: workerCountOverride,
        thermalStateProvider: thermalStateProvider,
        lowPowerModeProvider: lowPowerModeProvider,
        accessGuard: accessGuard,
        vectorPolicy: vectorPolicy,
        config: IndexConfig(
            enabled: true,
            files: true,
            roots: [root.path],
            exclude: exclude,
            iCloudEvicted: iCloudEvicted,
            nightlyBudget: nightlyBudget,
            maxVectorChunksPerDocument: maxVectorChunks
        ),
        homeDirectoryURL: root,
        evictedCheck: evictedCheck,
        downloadStarter: downloadStarter,
        fileReader: fileReader,
        progress: progress
    )
}

@Suite("Files Indexer")
struct FilesIndexerTests {
    @Test
    func `Excluded trees and AppleDouble sidecars are never indexed`() async throws {
        let base = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let (store, storeDirectory) = makeStore()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }

        let keep = base.appendingPathComponent("keep.txt")
        writeFile("keep me", at: keep)
        // Every built-in excluded tree is populated with a readable file so a
        // missing prune would show up as an extra indexed document.
        for directory in [
            "Music", "Pictures", "Movies", "Library", ".Trash",
            ".runeweaver", ".git", "node_modules", "DerivedData", "__pycache__", ".venv"
        ] {
            writeFile("ignored", at: base.appendingPathComponent(directory).appendingPathComponent("ignored.txt"))
        }
        writeFile("sidecar", at: base.appendingPathComponent("._keep.txt"))
        let userExcluded = base.appendingPathComponent("debug.log")
        writeFile("log line", at: userExcluded)

        let indexer = makeIndexer(store: store, root: base, accessGuard: FilesIndexerStubGuard(), exclude: ["*.log"])
        let report = await indexer.run()

        #expect(report.filesIndexed == 1)
        #expect(report.errors == 0)
        let stats = try await store.stats()
        #expect(stats.documents == 1)
        let storedKeep = try await store.document(source: .files, externalID: keep.path)
        #expect(storedKeep != nil)
        let storedLog = try await store.document(source: .files, externalID: userExcluded.path)
        #expect(storedLog == nil)
        let excluded = base.appendingPathComponent("Music/ignored.txt").path
        let storedExcluded = try await store.document(source: .files, externalID: excluded)
        #expect(storedExcluded == nil)
    }

    @Test
    func `Default excludes skip machine output and tool caches`() async throws {
        let base = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let (store, storeDirectory) = makeStore()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }

        let kept = base.appendingPathComponent("real.md")
        writeFile("real document", at: kept)
        let reportLog = base.appendingPathComponent("report.log")
        writeFile("log line", at: reportLog)
        let upperLog = base.appendingPathComponent("notes.LOG")
        writeFile("upper log line", at: upperLog)
        let scratchTmp = base.appendingPathComponent("scratch.tmp")
        writeFile("tmp body", at: scratchTmp)
        let finderSidecar = base.appendingPathComponent(".DS_Store")
        writeFile("finder state", at: finderSidecar)
        let cachedFile = base.appendingPathComponent(".nvm/versions/node/v20/cached.txt")
        writeFile("cached body", at: cachedFile)

        let indexer = makeIndexer(
            store: store,
            root: base,
            accessGuard: FilesIndexerStubGuard(),
            exclude: IndexConfig.defaultExcludePatterns
        )
        let report = await indexer.run()

        #expect(report.filesIndexed == 1)
        #expect(report.errors == 0)
        let stats = try await store.stats()
        #expect(stats.documents == 1)
        let storedKept = try await store.document(source: .files, externalID: kept.path)
        #expect(storedKept != nil)
        let storedReportLog = try await store.document(source: .files, externalID: reportLog.path)
        #expect(storedReportLog == nil)
        let storedUpperLog = try await store.document(source: .files, externalID: upperLog.path)
        #expect(storedUpperLog == nil)
        let storedTmp = try await store.document(source: .files, externalID: scratchTmp.path)
        #expect(storedTmp == nil)
        let storedSidecar = try await store.document(source: .files, externalID: finderSidecar.path)
        #expect(storedSidecar == nil)
        let storedCached = try await store.document(source: .files, externalID: cachedFile.path)
        #expect(storedCached == nil)
    }

    @Test
    func `A second run skips unchanged files by content hash`() async throws {
        let base = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let (store, storeDirectory) = makeStore()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        writeFile("stable body", at: base.appendingPathComponent("note.txt"))

        let indexer = makeIndexer(store: store, root: base, accessGuard: FilesIndexerStubGuard())
        let first = await indexer.run()
        #expect(first.filesIndexed == 1)
        #expect(first.filesSkipped == 0)

        let second = await indexer.run()
        #expect(second.filesScanned == 1)
        #expect(second.filesIndexed == 0)
        #expect(second.filesUnchanged == 1)

        let stats = try await store.stats()
        #expect(stats.documents == 1)
    }

    @Test
    func `Guard denial keeps a file out of the index`() async throws {
        let base = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let (store, storeDirectory) = makeStore()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let publicFile = base.appendingPathComponent("public.txt")
        let secretFile = base.appendingPathComponent("secret.txt")
        writeFile("public body", at: publicFile)
        writeFile("secret body", at: secretFile)

        let indexer = makeIndexer(
            store: store,
            root: base,
            accessGuard: FilesIndexerStubGuard(deniedMarkers: ["secret"])
        )
        let report = await indexer.run()

        #expect(report.filesIndexed == 1)
        #expect(report.filesSkipped == 1)
        let storedPublic = try await store.document(source: .files, externalID: publicFile.path)
        #expect(storedPublic != nil)
        let storedSecret = try await store.document(source: .files, externalID: secretFile.path)
        #expect(storedSecret == nil)
    }

    @Test
    func `Symlinked entries are never followed or indexed`() async throws {
        let base = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let (store, storeDirectory) = makeStore()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let real = base.appendingPathComponent("real.txt")
        writeFile("real body", at: real)
        let link = base.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let indexer = makeIndexer(store: store, root: base, accessGuard: FilesIndexerStubGuard())
        let report = await indexer.run()

        #expect(report.filesIndexed == 1)
        let storedReal = try await store.document(source: .files, externalID: real.path)
        #expect(storedReal != nil)
        let storedLink = try await store.document(source: .files, externalID: link.path)
        #expect(storedLink == nil)
    }

    @Test
    func `Finder aliases are detected and skipped without traversal (sequential)`() async throws {
        let base = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let (store, storeDirectory) = makeStore()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let real = base.appendingPathComponent("real.txt")
        writeFile("real body", at: real)
        let alias = base.appendingPathComponent("alias-file")
        let bookmark = try real.bookmarkData(
            options: .suitableForBookmarkFile,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        try URL.writeBookmarkData(bookmark, to: alias)
        // The fixture must read as an alias so the skip below proves
        // classification rather than a missing file.
        let aliasValues = try alias.resourceValues(forKeys: [.isAliasFileKey])
        #if os(macOS)
            #expect(aliasValues.isAliasFile == true)
        #else
            // Finder aliases exist only on macOS; bookmark files written elsewhere
            // do not report isAliasFile, so skip where the fixture cannot apply.
            guard aliasValues.isAliasFile == true else { return }
        #endif

        let indexer = makeIndexer(
            store: store,
            root: base,
            accessGuard: FilesIndexerStubGuard(),
            workerCountOverride: 1
        )
        let report = await indexer.run()

        #expect(report.filesIndexed == 1)
        #expect(report.filesSkipped == 1)
        #expect(report.errors == 0)
        #expect(report.warnings.isEmpty)
        let stats = try await store.stats()
        #expect(stats.documents == 1)
        let storedReal = try await store.document(source: .files, externalID: real.path)
        #expect(storedReal != nil)
        let storedAlias = try await store.document(source: .files, externalID: alias.path)
        #expect(storedAlias == nil)
    }

    @Test
    func `Finder aliases are detected and skipped without traversal (parallel)`() async throws {
        let base = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let (store, storeDirectory) = makeStore()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let real = base.appendingPathComponent("real.txt")
        writeFile("real body", at: real)
        let alias = base.appendingPathComponent("alias-file")
        let bookmark = try real.bookmarkData(
            options: .suitableForBookmarkFile,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        try URL.writeBookmarkData(bookmark, to: alias)
        // The fixture must read as an alias so the skip below proves
        // classification rather than a missing file.
        let aliasValues = try alias.resourceValues(forKeys: [.isAliasFileKey])
        #if os(macOS)
            #expect(aliasValues.isAliasFile == true)
        #else
            // Finder aliases exist only on macOS; bookmark files written elsewhere
            // do not report isAliasFile, so skip where the fixture cannot apply.
            guard aliasValues.isAliasFile == true else { return }
        #endif

        let indexer = makeIndexer(
            store: store,
            root: base,
            accessGuard: FilesIndexerStubGuard(),
            workerCountOverride: 3
        )
        let report = await indexer.run()

        #expect(report.filesIndexed == 1)
        #expect(report.filesSkipped == 1)
        #expect(report.errors == 0)
        #expect(report.warnings.isEmpty)
        let stats = try await store.stats()
        #expect(stats.documents == 1)
        let storedReal = try await store.document(source: .files, externalID: real.path)
        #expect(storedReal != nil)
        let storedAlias = try await store.document(source: .files, externalID: alias.path)
        #expect(storedAlias == nil)
    }

    @Test
    func `Vector policy embeds complete documents and leaves partial ones keyword-only`() async throws {
        let base = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let (store, storeDirectory) = makeStore()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        writeFile("complete body", at: base.appendingPathComponent("complete.txt"))
        writeFile("partial body", at: base.appendingPathComponent("partial.part"))

        let indexer = makeIndexer(
            store: store,
            root: base,
            accessGuard: FilesIndexerStubGuard(),
            embedder: FilesIndexerStubEmbedder()
        )
        let report = await indexer.run()

        #expect(report.filesIndexed == 2)
        let stats = try await store.stats()
        #expect(stats.documents == 2)
        #expect(stats.chunks == 2)
        // The partial document stays keyword-only, so exactly one chunk carries
        // a vector even though both bodies were extractable.
        #expect(stats.vectorChunks == 1)
    }

    @Test
    func `Disabling file indexing skips the run`() async throws {
        let base = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let (store, storeDirectory) = makeStore()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        writeFile("body", at: base.appendingPathComponent("note.txt"))

        let indexer = FilesIndexer(
            store: store,
            extractor: FilesIndexerStubExtractor(),
            accessGuard: FilesIndexerStubGuard(),
            config: IndexConfig(enabled: false, files: false, roots: [base.path]),
            homeDirectoryURL: base
        )
        let report = await indexer.run()

        #expect(report.didRun == false)
        #expect(report.skippedReason != nil)
        let stats = try await store.stats()
        #expect(stats.documents == 0)
    }

    @Test
    func `Nightly budget bounds newly written documents per run`() async throws {
        let base = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let (store, storeDirectory) = makeStore()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let total = 3
        for index in 0 ..< total {
            writeFile("body \(index)", at: base.appendingPathComponent("note-\(index).txt"))
        }

        let indexer = makeIndexer(
            store: store,
            root: base,
            accessGuard: FilesIndexerStubGuard(),
            nightlyBudget: 1
        )
        var indexed = 0
        for _ in 0 ..< total {
            let report = await indexer.run()
            indexed += report.filesIndexed
        }

        #expect(indexed == total)
        let stats = try await store.stats()
        #expect(stats.documents == total)
    }

    @Test
    func `Cancellation stops between files and a resume finishes the tree`() async throws {
        let base = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let (store, storeDirectory) = makeStore()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let total = 6
        for index in 0 ..< total {
            writeFile("body \(index)", at: base.appendingPathComponent("note-\(index).txt"))
        }

        let signal = FilesIndexerCancelSignal()
        let indexer = makeIndexer(
            store: store,
            root: base,
            accessGuard: FilesIndexerStubGuard(),
            progress: { progress in
                // Cancel only after at least one document landed, so the resume
                // assertion below always has real committed work to skip.
                if progress.matched >= 1 {
                    await signal.fire()
                }
            }
        )
        let canceller = Task {
            await signal.wait()
            await indexer.cancel()
        }
        let first = await indexer.run()
        await canceller.value

        #expect(first.cancelled)
        #expect(first.filesIndexed >= 1)
        #expect(first.filesIndexed < total)

        let second = await indexer.run()
        #expect(second.cancelled == false)
        #expect(first.filesIndexed + second.filesIndexed == total)

        let stats = try await store.stats()
        #expect(stats.documents == total)
    }

    @Test
    func `Evicted iCloud files are skipped when policy is skip`() async throws {
        let base = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let (store, storeDirectory) = makeStore()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let evicted = base.appendingPathComponent("evicted.txt")
        writeFile("evicted body", at: evicted)
        let local = base.appendingPathComponent("local.txt")
        writeFile("local body", at: local)
        let evictedPath = evicted.path

        let indexer = makeIndexer(
            store: store,
            root: base,
            accessGuard: FilesIndexerStubGuard(),
            iCloudEvicted: "skip",
            evictedCheck: { $0.path == evictedPath }
        )
        let report = await indexer.run()

        #expect(report.filesScanned == 2)
        #expect(report.filesIndexed == 1)
        #expect(report.filesSkipped == 1)
        #expect(report.errors == 0)
        let storedLocal = try await store.document(source: .files, externalID: local.path)
        #expect(storedLocal != nil)
        let storedEvicted = try await store.document(source: .files, externalID: evictedPath)
        #expect(storedEvicted == nil)
    }

    @Test
    func `Evicted iCloud files trigger a download when policy is download`() async throws {
        let base = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let (store, storeDirectory) = makeStore()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let evicted = base.appendingPathComponent("evicted.txt")
        writeFile("evicted body", at: evicted)
        let local = base.appendingPathComponent("local.txt")
        writeFile("local body", at: local)
        let evictedPath = evicted.path
        let starts = FilesIndexerDownloadStarts()

        let indexer = makeIndexer(
            store: store,
            root: base,
            accessGuard: FilesIndexerStubGuard(),
            iCloudEvicted: "download",
            evictedCheck: { $0.path == evictedPath },
            downloadStarter: { starts.record($0.path) }
        )
        let report = await indexer.run()

        // The download is triggered but the file still skips this run: its
        // bytes arrive after the walk.
        #expect(report.filesScanned == 2)
        #expect(report.filesIndexed == 1)
        #expect(report.filesSkipped == 1)
        #expect(report.errors == 0)
        #expect(starts.all == [evictedPath])
        let storedLocal = try await store.document(source: .files, externalID: local.path)
        #expect(storedLocal != nil)
        let storedEvicted = try await store.document(source: .files, externalID: evictedPath)
        #expect(storedEvicted == nil)
    }

    @Test
    func `Shared glob matcher covers exclude shapes`() {
        #expect(SharedGlobMatching.matchesPath(pattern: "*.log", relativePath: "debug.log", filename: "debug.log"))
        #expect(SharedGlobMatching.matchesPath(pattern: "node_modules", relativePath: "app/node_modules", filename: "node_modules"))
        #expect(SharedGlobMatching.matchesPath(pattern: "**/*.log", relativePath: "app/debug.log", filename: "debug.log"))
        #expect(SharedGlobMatching.matchesPath(pattern: "other/*.md", relativePath: "harness/CONFIG.md", filename: "CONFIG.md") == false)
        #expect(SharedGlobMatching.containsDotDot("../escape"))
        #expect(SharedGlobMatching.containsDotDot("app/*.log") == false)
    }

    @Test
    func `Vector cap stores N vectors and leaves k chunks keyword-only`() async throws {
        let base = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let (store, storeDirectory) = makeStore()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let file = base.appendingPathComponent("large.txt")
        writeFile("large body", at: file)

        let indexer = FilesIndexer(
            store: store,
            extractor: FilesIndexerMultiChunkExtractor(chunkCount: 5),
            embedder: FilesIndexerStubEmbedder(),
            accessGuard: FilesIndexerStubGuard(),
            config: IndexConfig(
                enabled: true,
                files: true,
                roots: [base.path],
                maxVectorChunksPerDocument: 3
            ),
            homeDirectoryURL: base
        )
        let report = await indexer.run()

        #expect(report.filesIndexed == 1)
        #expect(report.chunksWritten == 5)
        #expect(report.vectorsWritten == 3)
        #expect(report.truncatedVectorDocuments == 1)
        let stats = try await store.stats()
        #expect(stats.chunks == 5)
        #expect(stats.vectorChunks == 3)
        #expect(stats.keywordChunks == 2)
        // The tail chunks stay keyword-only but remain searchable.
        let tail = try await store.searchKeyword(query: "cap-chunk-4", limit: 10)
        #expect(tail.contains(where: { $0.text.contains("cap-chunk-4") && $0.embedding.isEmpty && !$0.isVector }))
        let head = try await store.searchKeyword(query: "cap-chunk-0", limit: 10)
        #expect(head.contains(where: { $0.text.contains("cap-chunk-0") && !$0.embedding.isEmpty && $0.isVector }))
    }

    @Test
    func `Vector cap of one yields a single vector`() async throws {
        let base = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let (store, storeDirectory) = makeStore()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        writeFile("large body", at: base.appendingPathComponent("large.txt"))

        let indexer = FilesIndexer(
            store: store,
            extractor: FilesIndexerMultiChunkExtractor(chunkCount: 4),
            embedder: FilesIndexerStubEmbedder(),
            accessGuard: FilesIndexerStubGuard(),
            config: IndexConfig(
                enabled: true,
                files: true,
                roots: [base.path],
                maxVectorChunksPerDocument: 1
            ),
            homeDirectoryURL: base
        )
        let report = await indexer.run()

        #expect(report.filesIndexed == 1)
        #expect(report.chunksWritten == 4)
        #expect(report.vectorsWritten == 1)
        #expect(report.truncatedVectorDocuments == 1)
        let stats = try await store.stats()
        #expect(stats.vectorChunks == 1)
        #expect(stats.keywordChunks == 3)
    }

    @Test
    func `Unchanged files perform no reads on a second run`() async {
        let base = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let (store, storeDirectory) = makeStore()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        writeFile("stable body", at: base.appendingPathComponent("note.txt"))
        let reads = FilesIndexerCountingReads()

        let indexer = makeIndexer(
            store: store,
            root: base,
            accessGuard: FilesIndexerStubGuard(),
            fileReader: { try reads.read($0) }
        )
        let first = await indexer.run()
        #expect(first.filesIndexed == 1)
        #expect(reads.count == 1)

        let second = await indexer.run()
        #expect(second.filesScanned == 1)
        #expect(second.filesIndexed == 0)
        #expect(second.filesUnchanged == 1)
        // The fingerprint matched, so no bytes were read the second time.
        #expect(reads.count == 1)
    }

    @Test
    func `Size change forces a re-read even when mtime matches`() async throws {
        let base = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let (store, storeDirectory) = makeStore()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let file = base.appendingPathComponent("note.txt")
        writeFile("short", at: file)
        let reads = FilesIndexerCountingReads()

        let indexer = makeIndexer(
            store: store,
            root: base,
            accessGuard: FilesIndexerStubGuard(),
            fileReader: { try reads.read($0) }
        )
        let first = await indexer.run()
        #expect(first.filesIndexed == 1)
        #expect(reads.count == 1)
        let canonical = file.resolvingSymlinksInPath().standardizedFileURL.path
        let fingerprint = try await store.storedFingerprint(source: .files, externalID: canonical)
        #expect(fingerprint != nil)

        // Grow the body but restore the stored mtime, isolating the size leg:
        // a size-only change must still force a read.
        writeFile("a much longer body with a different size", at: file)
        if let storedMtime = fingerprint?.mtime {
            try FileManager.default.setAttributes([.modificationDate: storedMtime], ofItemAtPath: file.path)
        }

        let second = await indexer.run()
        #expect(second.filesIndexed == 1)
        #expect(reads.count == 2)
    }

    @Test
    func `Mtime drift beyond tolerance forces a re-read`() async throws {
        let base = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let (store, storeDirectory) = makeStore()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let file = base.appendingPathComponent("note.txt")
        writeFile("stable body", at: file)
        let reads = FilesIndexerCountingReads()

        let indexer = makeIndexer(
            store: store,
            root: base,
            accessGuard: FilesIndexerStubGuard(),
            fileReader: { try reads.read($0) }
        )
        let first = await indexer.run()
        #expect(first.filesIndexed == 1)
        #expect(reads.count == 1)

        let second = await indexer.run()
        #expect(second.filesUnchanged == 1)
        #expect(reads.count == 1)

        // Same bytes, but the modification time moved well outside the
        // one-second tolerance, so the fast path must miss and re-hash.
        let canonical = file.resolvingSymlinksInPath().standardizedFileURL.path
        let fingerprint = try await store.storedFingerprint(source: .files, externalID: canonical)
        #expect(fingerprint?.mtime != nil)
        if let storedMtime = fingerprint?.mtime {
            try FileManager.default.setAttributes(
                [.modificationDate: storedMtime.addingTimeInterval(10)],
                ofItemAtPath: file.path
            )
        }

        let third = await indexer.run()
        #expect(third.filesScanned == 1)
        #expect(reads.count == 2)
        // The body hash is unchanged, so the hashed lookup still reports it
        // as unchanged even though the bytes were re-read.
        #expect(third.filesUnchanged == 1)
        #expect(third.filesIndexed == 0)
    }

    @Test
    func `Failed fingerprint always retries`() async throws {
        let base = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let (store, storeDirectory) = makeStore()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let file = base.appendingPathComponent("note.txt")
        writeFile("retry body", at: file)
        let canonical = file.resolvingSymlinksInPath().standardizedFileURL.path
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = Int64(values.fileSize ?? 0)

        // Seed a failed row with matching size and mtime: the fast path must
        // not skip it even though the fingerprint otherwise matches.
        _ = try await store.upsertDocument(IndexedDocument(
            source: .files,
            externalID: canonical,
            displayName: "note.txt",
            path: canonical,
            mtime: values.contentModificationDate,
            sizeBytes: size,
            contentHash: "stale-hash",
            extractStatus: .failed
        ))
        let seeded = try await store.storedFingerprint(source: .files, externalID: canonical)
        #expect(seeded?.extractStatus == .failed)
        #expect(seeded?.sizeBytes == size)

        let reads = FilesIndexerCountingReads()
        let indexer = makeIndexer(
            store: store,
            root: base,
            accessGuard: FilesIndexerStubGuard(),
            fileReader: { try reads.read($0) }
        )
        let report = await indexer.run()
        #expect(reads.count == 1)
        #expect(report.filesIndexed == 1)
        let stored = try await store.document(source: .files, externalID: canonical)
        #expect(stored?.extractStatus != .failed)
    }

    @Test
    func `Newly excluded documents are retired with their chunks`() async throws {
        let base = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let (store, storeDirectory) = makeStore()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let keep = base.appendingPathComponent("keep.txt")
        let excluded = base.appendingPathComponent("old.log")
        writeFile("keepmarker alpha body", at: keep)
        writeFile("retiremarker beta body", at: excluded)

        let first = makeIndexer(store: store, root: base, accessGuard: FilesIndexerStubGuard())
        let firstReport = await first.run()
        #expect(firstReport.filesIndexed == 2)
        #expect(firstReport.retiredCount == 0)
        let before = try await store.searchKeyword(query: "retiremarker", limit: 10)
        #expect(!before.isEmpty)

        // Excluding *.log after the first run must retire the already-indexed
        // log on the next complete pass, including its chunks.
        let second = makeIndexer(
            store: store,
            root: base,
            accessGuard: FilesIndexerStubGuard(),
            exclude: ["*.log"]
        )
        let secondReport = await second.run()
        #expect(secondReport.errors == 0)
        #expect(secondReport.retiredCount == 1)
        let stats = try await store.stats()
        #expect(stats.documents == 1)
        #expect(stats.chunks == 1)
        let storedKeep = try await store.document(source: .files, externalID: keep.path)
        #expect(storedKeep != nil)
        let storedExcluded = try await store.document(source: .files, externalID: excluded.path)
        #expect(storedExcluded == nil)
        let after = try await store.searchKeyword(query: "retiremarker", limit: 10)
        #expect(after.isEmpty)
        let keepHits = try await store.searchKeyword(query: "keepmarker", limit: 10)
        #expect(!keepHits.isEmpty)
    }

    @Test
    func `Cancelled runs retire nothing`() async throws {
        let base = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let (store, storeDirectory) = makeStore()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let total = 6
        for index in 0 ..< total {
            writeFile("body \(index)", at: base.appendingPathComponent("note-\(index).txt"))
        }
        let first = makeIndexer(store: store, root: base, accessGuard: FilesIndexerStubGuard())
        let firstReport = await first.run()
        #expect(firstReport.filesIndexed == total)

        // A partial walk must never delete: cancelling before every file is
        // visited leaves the newly excluded row in place.
        let signal = FilesIndexerCancelSignal()
        let second = makeIndexer(
            store: store,
            root: base,
            accessGuard: FilesIndexerStubGuard(),
            exclude: ["note-5.txt"],
            progress: { progress in
                if progress.scanned >= 1 {
                    await signal.fire()
                }
            }
        )
        let canceller = Task {
            await signal.wait()
            await second.cancel()
        }
        let secondReport = await second.run()
        await canceller.value
        #expect(secondReport.cancelled)
        #expect(secondReport.retiredCount == 0)
        let excludedPath = base.appendingPathComponent("note-5.txt").path
        let storedExcluded = try await store.document(source: .files, externalID: excludedPath)
        #expect(storedExcluded != nil)
        let stats = try await store.stats()
        #expect(stats.documents == total)
    }

    @Test
    func `Budget-exhausted runs retire nothing`() async throws {
        let base = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let (store, storeDirectory) = makeStore()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let fileA = base.appendingPathComponent("a.txt")
        let fileB = base.appendingPathComponent("b.txt")
        writeFile("alpha body", at: fileA)
        writeFile("beta body", at: fileB)
        let first = makeIndexer(store: store, root: base, accessGuard: FilesIndexerStubGuard())
        let firstReport = await first.run()
        #expect(firstReport.filesIndexed == 2)

        // Two brand-new files with a budget of one guarantees the walk stops
        // with work still unvisited, so the newly excluded row must survive.
        writeFile("gamma body", at: base.appendingPathComponent("c.txt"))
        writeFile("delta body", at: base.appendingPathComponent("d.txt"))
        let second = makeIndexer(
            store: store,
            root: base,
            accessGuard: FilesIndexerStubGuard(),
            exclude: ["b.txt"],
            nightlyBudget: 1
        )
        let secondReport = await second.run()
        #expect(secondReport.filesIndexed == 1)
        #expect(secondReport.retiredCount == 0)
        let storedExcluded = try await store.document(source: .files, externalID: fileB.path)
        #expect(storedExcluded != nil)
        let storedKept = try await store.document(source: .files, externalID: fileA.path)
        #expect(storedKept != nil)
    }

    @Test
    func `Errored but visited files are kept`() async throws {
        let base = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let (store, storeDirectory) = makeStore()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let keep = base.appendingPathComponent("keep.txt")
        let flaky = base.appendingPathComponent("flaky.txt")
        writeFile("keepmarker steady body", at: keep)
        writeFile("original flakymarker body", at: flaky)
        let first = makeIndexer(store: store, root: base, accessGuard: FilesIndexerStubGuard())
        let firstReport = await first.run()
        #expect(firstReport.filesIndexed == 2)

        // Grow the body so the fingerprint misses and the run must read it;
        // the read then fails, but the visit still stamps the prior row.
        writeFile("changed flakymarker body with a much longer size to force a re-read", at: flaky)
        let second = makeIndexer(
            store: store,
            root: base,
            accessGuard: FilesIndexerStubGuard(),
            fileReader: { url in
                if url.lastPathComponent == "flaky.txt" {
                    throw NSError(domain: "FilesIndexerTests", code: 1)
                }
                return try Data(contentsOf: url, options: [.mappedIfSafe])
            }
        )
        let secondReport = await second.run()
        #expect(secondReport.errors == 1)
        #expect(secondReport.retiredCount == 0)
        let storedFlaky = try await store.document(source: .files, externalID: flaky.path)
        #expect(storedFlaky != nil)
        let storedKeep = try await store.document(source: .files, externalID: keep.path)
        #expect(storedKeep != nil)
        // The prior chunks survive the failed re-read, so the old text stays searchable.
        let hits = try await store.searchKeyword(query: "flakymarker", limit: 10)
        #expect(!hits.isEmpty)
    }

    @Test
    func `In-flight files never exceed the worker count`() async {
        let base = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let (store, storeDirectory) = makeStore()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let total = 9
        for index in 0 ..< total {
            writeFile("parallel body \(index)", at: base.appendingPathComponent("note-\(index).txt"))
        }
        let tracker = FilesIndexerInFlightTracker()
        let indexer = makeIndexer(
            store: store,
            root: base,
            accessGuard: FilesIndexerStubGuard(),
            workerCountOverride: 3,
            fileReader: { url in
                tracker.enter()
                defer { tracker.exit() }
                // Widen the overlap window so all three workers are provably
                // inside the read at once.
                Thread.sleep(forTimeInterval: 0.05)
                return try Data(contentsOf: url, options: [.mappedIfSafe])
            }
        )
        let report = await indexer.run()

        #expect(report.filesIndexed == total)
        #expect(report.errors == 0)
        #expect(tracker.peak == 3)
    }

    @Test
    func `A single worker stays strictly sequential`() async {
        let base = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let (store, storeDirectory) = makeStore()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let total = 4
        for index in 0 ..< total {
            writeFile("sequential body \(index)", at: base.appendingPathComponent("note-\(index).txt"))
        }
        let tracker = FilesIndexerInFlightTracker()
        let indexer = makeIndexer(
            store: store,
            root: base,
            accessGuard: FilesIndexerStubGuard(),
            workerCountOverride: 1,
            fileReader: { url in
                tracker.enter()
                defer { tracker.exit() }
                Thread.sleep(forTimeInterval: 0.02)
                return try Data(contentsOf: url, options: [.mappedIfSafe])
            }
        )
        let report = await indexer.run()

        #expect(report.filesIndexed == total)
        #expect(tracker.peak == 1)
    }

    @Test
    func `Parallel workers never exceed the nightly budget`() async throws {
        let base = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let (store, storeDirectory) = makeStore()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let total = 6
        for index in 0 ..< total {
            writeFile("budget body \(index)", at: base.appendingPathComponent("note-\(index).txt"))
        }

        let first = makeIndexer(
            store: store,
            root: base,
            accessGuard: FilesIndexerStubGuard(),
            workerCountOverride: 3,
            nightlyBudget: 2
        )
        let firstReport = await first.run()
        #expect(firstReport.filesIndexed == 2)

        // Unclaimed files retry on later runs until the whole tree lands.
        let second = makeIndexer(
            store: store,
            root: base,
            accessGuard: FilesIndexerStubGuard(),
            workerCountOverride: 3,
            nightlyBudget: 2
        )
        let secondReport = await second.run()
        #expect(secondReport.filesIndexed == 2)

        let third = makeIndexer(
            store: store,
            root: base,
            accessGuard: FilesIndexerStubGuard(),
            workerCountOverride: 3,
            nightlyBudget: 2
        )
        let thirdReport = await third.run()
        #expect(thirdReport.filesIndexed == 2)

        let stats = try await store.stats()
        #expect(stats.documents == total)
    }

    @Test
    func `Thermal critical halts new work`() async throws {
        let base = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let (store, storeDirectory) = makeStore()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        writeFile("hot body", at: base.appendingPathComponent("note.txt"))

        let indexer = makeIndexer(
            store: store,
            root: base,
            accessGuard: FilesIndexerStubGuard(),
            workerCountOverride: 3,
            thermalStateProvider: { .critical }
        )
        let report = await indexer.run()

        #expect(report.filesIndexed == 0)
        #expect(report.filesScanned == 0)
        #expect(report.retiredCount == 0)
        #expect(report.warnings.contains(where: { $0.contains("thermal") }))
        let stats = try await store.stats()
        #expect(stats.documents == 0)
    }

    @Test
    func `Cancellation stops parallel workers within one batch`() async throws {
        let base = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let (store, storeDirectory) = makeStore()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let total = 12
        for index in 0 ..< total {
            writeFile("cancel body \(index)", at: base.appendingPathComponent("note-\(index).txt"))
        }

        let signal = FilesIndexerCancelSignal()
        let indexer = makeIndexer(
            store: store,
            root: base,
            accessGuard: FilesIndexerStubGuard(),
            workerCountOverride: 3,
            fileReader: { url in
                // Slow reads widen each batch so cancellation lands mid-flight
                // instead of racing a microsecond run to completion.
                Thread.sleep(forTimeInterval: 0.05)
                return try Data(contentsOf: url, options: [.mappedIfSafe])
            },
            progress: { progress in
                // Cancel only after at least one document landed, so the resume
                // assertion below always has real committed work to skip.
                if progress.matched >= 1 {
                    await signal.fire()
                }
            }
        )
        let canceller = Task {
            await signal.wait()
            await indexer.cancel()
        }
        let first = await indexer.run()
        await canceller.value

        #expect(first.cancelled)
        #expect(first.filesIndexed >= 1)
        #expect(first.filesIndexed < total)
        #expect(first.retiredCount == 0)

        let second = makeIndexer(
            store: store,
            root: base,
            accessGuard: FilesIndexerStubGuard(),
            workerCountOverride: 3
        )
        let secondReport = await second.run()
        #expect(secondReport.cancelled == false)
        #expect(first.filesIndexed + secondReport.filesIndexed == total)

        let stats = try await store.stats()
        #expect(stats.documents == total)
    }

    @Test
    func `Embeddings pool vends one backend per worker`() async {
        final class IDSource: Sendable {
            private let lock = OSAllocatedUnfairLock(initialState: 0)

            func next() -> Int {
                lock.withLock { value in
                    value += 1
                    return value
                }
            }
        }
        final class SeenIDs: Sendable {
            private let lock = OSAllocatedUnfairLock(initialState: [Int]())

            func record(_ id: Int) {
                lock.withLock { $0.append(id) }
            }

            var all: [Int] {
                lock.withLock { $0 }
            }
        }
        let source = IDSource()
        let seen = SeenIDs()
        let tracker = FilesIndexerInFlightTracker()
        let pool = EmbeddingsBackendPool(count: 2) { FilesIndexerIDEmbedder(id: source.next()) }

        await withTaskGroup(of: Int.self) { group in
            for _ in 0 ..< 4 {
                group.addTask {
                    await (try? pool.withBackend { backend -> Int in
                        tracker.enter()
                        defer { tracker.exit() }
                        try? await Task.sleep(nanoseconds: 20_000_000)
                        return (backend as? FilesIndexerIDEmbedder)?.id ?? -1
                    }) ?? -1
                }
            }
            for await id in group {
                seen.record(id)
            }
        }

        // Both slots were exercised across the four checkouts, at most two at
        // once, and every slot returned to the pool.
        #expect(Set(seen.all) == [1, 2])
        #expect(tracker.peak == 2)
        #expect(await pool.availableCount == 2)
    }
}

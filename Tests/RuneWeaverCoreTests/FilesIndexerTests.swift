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
///   - vectorPolicy: Vector policy for the run.
///   - nightlyBudget: Maximum newly written documents per run; 0 is unlimited.
///   - iCloudEvicted: Evicted-iCloud policy (`skip` or `download`).
///   - evictedCheck: Override resolving evicted files, or nil for the live check.
///   - downloadStarter: Download trigger for the `download` policy, or nil for `FileManager`.
///   - progress: Advisory progress sink.
/// - Returns: A configured indexer.
private func makeIndexer(
    store: DocIndexStore,
    root: URL,
    accessGuard: any FilesIndexAccessGuard,
    exclude: [String] = [],
    embedder: (any EmbeddingsBackend)? = nil,
    vectorPolicy: FilesVectorPolicy = FilesVectorPolicy(),
    nightlyBudget: Int = 0,
    iCloudEvicted: String = IndexConfig.defaultICloudEvicted,
    evictedCheck: (@Sendable (URL) -> Bool)? = nil,
    downloadStarter: (@Sendable (URL) -> Void)? = nil,
    progress: @escaping ToolProgressReporter = ToolContext.noProgress
) -> FilesIndexer {
    FilesIndexer(
        store: store,
        extractor: FilesIndexerStubExtractor(),
        embedder: embedder,
        accessGuard: accessGuard,
        vectorPolicy: vectorPolicy,
        config: IndexConfig(
            enabled: true,
            files: true,
            roots: [root.path],
            exclude: exclude,
            iCloudEvicted: iCloudEvicted,
            nightlyBudget: nightlyBudget
        ),
        homeDirectoryURL: root,
        evictedCheck: evictedCheck,
        downloadStarter: downloadStarter,
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
}

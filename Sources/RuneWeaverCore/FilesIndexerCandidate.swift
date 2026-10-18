// Rune Weaver Core — Parallel files candidate processing for the document index.

import Foundation

extension FilesIndexer {
    /// How one candidate file resolved on a parallel worker.
    enum FileOutcomeKind: Sendable {
        /// Document plus chunks committed; carries chunks written, vectors written, and whether the vector cap truncated the document.
        case indexed(chunks: Int, vectors: Int, truncated: Bool)
        /// Stored body was already current.
        case unchanged
        /// Deliberately skipped (excluded, denied, symlinked, alias, oversized, unsupported, or evicted).
        case skipped
        /// Could not be read, extracted, or written; carries the content-free warning line.
        case error(warning: String)
        /// Nightly budget was spent before this file could commit, so the run halts new work.
        case overBudget
        /// Cancellation arrived before the file committed.
        case cancelled
    }

    /// Outcome of processing one candidate file on a parallel worker.
    struct FileOutcome: Sendable {
        /// How the file resolved.
        var kind: FileOutcomeKind
        /// Root-relative display path for progress frames.
        var relative: String
        /// Whether the worker's `markSeen` stamp failed, forcing the reconcile to stay skipped.
        var stampFailed = false
        /// Whether the worker observed cancellation that the run must propagate
        /// even though the outcome otherwise counts normally.
        var propagateCancel = false
        /// Canonical path to stamp in the batched `markSeenBatch` queue when resolved via preloaded fingerprints.
        var pendingSeenPath: String?
        /// Modality queue lane this candidate was scheduled in, when known.
        var lane: FilesModalityLane?
    }

    /// Result of stamping one visited file as seen by the current run.
    enum StampResult: Sendable {
        /// The stamp landed.
        case ok
        /// The store threw, so the end-of-run reconcile must stay skipped.
        case failed
        /// Cancellation arrived during the stamp.
        case cancelled
    }

    /// Actor-isolated nightly budget counter shared by parallel workers.
    actor FileIndexBudget {
        /// Newly written documents still permitted this run.
        private var remaining: Int

        /// Creates a budget counter.
        /// - Parameter limit: Maximum newly written documents; values at or below zero mean unlimited.
        init(limit: Int) {
            remaining = limit > 0 ? limit : Int.max
        }

        /// Claims one document slot when any remains.
        /// - Returns: True when the caller may commit; false when the budget is spent.
        func tryClaim() -> Bool {
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }

        /// Returns a claimed slot after a failed or cancelled commit.
        func release() {
            if remaining < Int.max {
                remaining += 1
            }
        }

        /// Whether no document slot remains.
        var isExhausted: Bool {
            remaining <= 0
        }
    }

    /// Identity of one parallel candidate file.
    struct CandidateIdentity: Sendable {
        /// Canonical file URL the guard allowed.
        let fileURL: URL
        /// Root the file was discovered under, for display paths.
        let root: URL
        /// Opaque stamp for the run in flight.
        let runID: String
        /// Modality queue lane this candidate was scheduled in.
        var lane: FilesModalityLane = .fastText
    }

    /// Shared services consulted while processing one candidate.
    struct CandidateServices: Sendable {
        /// Document index the run writes into.
        let store: DocIndexStore
        /// Text extractor for the candidate file.
        let extractor: any DocumentTextExtracting
        /// Shared embeddings backend, or nil for keyword-only indexing.
        let embedder: any EmbeddingsBackend?
        /// Pooled backends preferred for parallel embedding, or nil to share `embedder`.
        let embeddingsPool: EmbeddingsBackendPool?
        /// Path policy consulted before opening the candidate.
        let accessGuard: any FilesIndexAccessGuard
        /// Which extracted documents are vectorized.
        let vectorPolicy: FilesVectorPolicy
        /// Bulk-preloaded stored fingerprints for `.files`, eliminating per-file SQLite queries.
        var preloadedFingerprints: [String: DocStoredFingerprint]?
    }

    /// Per-run policy and test seams for one candidate. Keeps walk caps, home boundary, and
    /// injectable I/O overrides together so helpers that only need policy never observe the store or
    /// budget.
    struct CandidatePolicy: Sendable {
        /// Walk size cap, evicted policy, and vector cap.
        let config: IndexConfig
        /// Home boundary override, or nil for the real home.
        let homeDirectoryURL: URL?
        /// Override resolving evicted iCloud files, or nil for the live check.
        let evictedCheck: (@Sendable (URL) -> Bool)?
        /// Download trigger for the `download` policy, or nil for `FileManager`.
        let downloadStarter: (@Sendable (URL) -> Void)?
        /// Override reading file bytes, or nil for memory-mapped reads.
        let fileReader: (@Sendable (URL) throws -> Data)?
    }

    /// Mutable run coordination shared by all workers. Pairs the atomic nightly budget with the
    /// lock-guarded cancellation mirror so commit helpers observe both without extra parameters.
    struct CandidateRunState: Sendable {
        /// Actor-isolated nightly budget shared by all workers.
        let budget: FileIndexBudget
        /// Lock-guarded cancellation mirror set by `cancel()`.
        let cancellation: IndexCancellationFlag
    }

    /// Canonical identity derived once per candidate.
    struct ResolvedCandidate: Sendable {
        /// Canonical file URL with symlinks resolved.
        let canonicalURL: URL
        /// Stable external identifier for the store.
        let canonicalPath: String
        /// Root-relative display path for progress frames.
        let relative: String
        /// Final path component for extraction.
        let filename: String
        /// Byte cap for one candidate file, from `max_file_mb`.
        let maxBytes: Int
    }

    /// Prerequisites resolved during preflight for candidate reading and extraction.
    struct CandidatePreflight: Sendable {
        /// Source modification time, when known.
        let modificationDate: Date?
        /// Path the access guard permitted for reading.
        let resolvedPath: String
    }

    /// Outcome of preflighting one candidate file before reading bytes.
    enum CandidatePreflightOutcome: Sendable {
        /// Candidate is permitted and ready for reading and extraction.
        case ready(CandidatePreflight)
        /// Candidate processing resolved early (skipped, unchanged, unreadable, or cancelled).
        case finished(FileOutcome)
    }
}

// MARK: - Candidate worker

extension FilesIndexer {
    /// Evaluates pre-read metadata and policies for a candidate.
    static func preflightCandidate(
        identity: CandidateIdentity,
        services: CandidateServices,
        policy: CandidatePolicy,
        state: CandidateRunState,
        resolved: ResolvedCandidate
    ) async -> CandidatePreflightOutcome {
        if state.cancellation.isSet || Task.isCancelled {
            return .finished(FileOutcome(kind: .cancelled, relative: resolved.relative))
        }
        guard let values = try? resolved.canonicalURL.resourceValues(forKeys: entryKeySet) else {
            if state.cancellation.isSet || Task.isCancelled {
                return .finished(FileOutcome(kind: .cancelled, relative: resolved.relative))
            }
            return .finished(failedOutcome(relative: resolved.relative, reason: "unreadable"))
        }
        if values.isSymbolicLink == true || values.isAliasFile == true || resolved.filename.hasPrefix("._") {
            return .finished(skippedOutcome(relative: resolved.relative))
        }
        if isEvictedCandidate(policy: policy, canonicalURL: resolved.canonicalURL, values: values) {
            let outcome = await handleEvictedCandidate(
                identity: identity,
                services: services,
                policy: policy,
                resolved: resolved
            )
            return .finished(outcome)
        }
        let size = values.fileSize ?? 0
        let candidateFormat = DocumentTextExtractor.detectFormat(fileName: resolved.filename, contentType: nil)
        let isMediaCandidate = candidateFormat == .audio || candidateFormat == .video
        guard isMediaCandidate || size <= resolved.maxBytes else {
            return .finished(skippedOutcome(relative: resolved.relative))
        }
        let decision = services.accessGuard.evaluate(
            path: resolved.canonicalPath,
            homeDirectoryURL: policy.homeDirectoryURL
        )
        guard decision.allowed else {
            return .finished(skippedOutcome(relative: resolved.relative))
        }
        if let unchanged = await checkFingerprintUnchanged(
            identity: identity,
            services: services,
            resolved: resolved,
            values: values
        ) {
            if state.cancellation.isSet || Task.isCancelled {
                return .finished(FileOutcome(kind: .cancelled, relative: resolved.relative))
            }
            return .finished(unchanged)
        }
        return .ready(CandidatePreflight(
            modificationDate: values.contentModificationDate,
            resolvedPath: decision.resolvedPath
        ))
    }

    /// Derives one stable identity for a candidate before any I/O.
    static func resolveCandidate(identity: CandidateIdentity, policy: CandidatePolicy) -> ResolvedCandidate {
        let canonicalURL = identity.fileURL.resolvingSymlinksInPath().standardizedFileURL
        let canonicalPath = canonicalURL.path
        let relative = Self.relativePath(of: canonicalURL, root: identity.root)
        let filename = canonicalURL.lastPathComponent
        let maxBytes = max(1, policy.config.maxFileMB) * 1024 * 1024
        return ResolvedCandidate(
            canonicalURL: canonicalURL,
            canonicalPath: canonicalPath,
            relative: relative,
            filename: filename,
            maxBytes: maxBytes
        )
    }

    /// Builds a deliberately skipped outcome for one candidate.
    /// - Parameter relative: Root-relative display path.
    /// - Returns: A skipped outcome.
    static func skippedOutcome(relative: String) -> FileOutcome {
        FileOutcome(kind: .skipped, relative: relative)
    }

    /// Builds a content-free error outcome for one candidate. Only the reason travels into the
    /// warning; file bytes never do.
    static func failedOutcome(relative: String, reason: String) -> FileOutcome {
        FileOutcome(
            kind: .error(warning: FilesIndexer.skipWarningText(relative: relative, reason: reason)),
            relative: relative
        )
    }

    /// Folds a stamp result into a worker outcome. A failed stamp forces the reconcile to stay
    /// skipped; a cancelled stamp still counts the file but propagates cancellation to the run.
    static func stamped(_ stamp: StampResult, onto outcome: FileOutcome) -> FileOutcome {
        var resolved = outcome
        switch stamp {
        case .ok:
            break
        case .failed:
            resolved.stampFailed = true
        case .cancelled:
            resolved.propagateCancel = true
        }
        return resolved
    }
}

// MARK: - Candidate stages

extension FilesIndexer {
    /// Reports whether a candidate has no local bytes to read. An injected override wins in tests;
    /// the live ubiquity check runs otherwise so an undetermined download state never hides a
    /// readable file.
    static func isEvictedCandidate(
        policy: CandidatePolicy,
        canonicalURL: URL,
        values: URLResourceValues
    ) -> Bool {
        if let evictedCheck = policy.evictedCheck {
            return evictedCheck(canonicalURL)
        }
        return Self.isLiveEvicted(at: canonicalURL, values: values)
    }

    /// Handles an evicted file under the configured iCloud policy. Stamping keeps a previously
    /// indexed row alive so eviction alone never retires it.
    static func handleEvictedCandidate(
        identity: CandidateIdentity,
        services: CandidateServices,
        policy: CandidatePolicy,
        resolved: ResolvedCandidate
    ) async -> FileOutcome {
        if FilesIndexer.isDownloadPolicy(policy.config.iCloudEvicted) {
            if let downloadStarter = policy.downloadStarter {
                downloadStarter(resolved.canonicalURL)
            } else {
                Self.startLiveDownload(at: resolved.canonicalURL)
            }
        }
        let stamp = await stampCandidate(
            store: services.store,
            canonicalPath: resolved.canonicalPath,
            runID: identity.runID
        )
        return stamped(stamp, onto: skippedOutcome(relative: resolved.relative))
    }

    /// Probes the pre-read fingerprint for an unchanged file. A matching size plus an mtime within
    /// tolerance and a non-failed prior extraction means the body is current without reading any
    /// bytes.
    static func checkFingerprintUnchanged(
        identity: CandidateIdentity,
        services: CandidateServices,
        resolved: ResolvedCandidate,
        values: URLResourceValues
    ) async -> FileOutcome? {
        // A Task-level stop between files wins before any store I/O; the
        // mirror check lives with the caller so grouped helpers stay small.
        if Task.isCancelled {
            return FileOutcome(kind: .cancelled, relative: resolved.relative)
        }
        let size = values.fileSize ?? 0
        if let preloaded = services.preloadedFingerprints {
            if let fingerprint = preloaded[resolved.canonicalPath],
               FilesIndexer.fingerprintMatchesStored(
                   fingerprint,
                   size: size,
                   currentMtime: values.contentModificationDate
               )
            {
                return FileOutcome(
                    kind: .unchanged,
                    relative: resolved.relative,
                    pendingSeenPath: resolved.canonicalPath
                )
            }
            return nil
        }
        do {
            if let fingerprint = try await services.store.storedFingerprint(
                source: .files,
                externalID: resolved.canonicalPath
            ),
                FilesIndexer.fingerprintMatchesStored(
                    fingerprint,
                    size: size,
                    currentMtime: values.contentModificationDate
                )
            {
                if Task.isCancelled {
                    return FileOutcome(kind: .cancelled, relative: resolved.relative)
                }
                let stamp = await stampCandidate(
                    store: services.store,
                    canonicalPath: resolved.canonicalPath,
                    runID: identity.runID
                )
                let unchanged = FileOutcome(kind: .unchanged, relative: resolved.relative)
                return stamped(stamp, onto: unchanged)
            }
        } catch is CancellationError {
            return FileOutcome(kind: .cancelled, relative: resolved.relative)
        } catch {
            // A transient store failure still reaches the hashed lookup below
            // with its normal error handling instead of failing the file here.
            return nil
        }
        return nil
    }

    /// Reads one candidate's bytes through the injected override or a mapped read.
    /// policy: Override reading file bytes, or nil for memory-mapped reads.
    static func readCandidateBytes(policy: CandidatePolicy, resolvedPath: String) throws -> Data {
        if let fileReader = policy.fileReader {
            return try fileReader(URL(fileURLWithPath: resolvedPath))
        }
        return try Data(contentsOf: URL(fileURLWithPath: resolvedPath), options: [.mappedIfSafe])
    }

    /// Gates re-indexing on the stored content hash. identity: Per-file URLs plus
    /// the run stamp.
    static func checkContentCurrent(
        identity: CandidateIdentity,
        services: CandidateServices,
        resolved: ResolvedCandidate,
        hash: String
    ) async -> FileOutcome? {
        if Task.isCancelled {
            return FileOutcome(kind: .cancelled, relative: resolved.relative)
        }
        if let preloaded = services.preloadedFingerprints {
            if let existing = preloaded[resolved.canonicalPath],
               existing.contentHash == hash,
               existing.extractStatus != .failed
            {
                return FileOutcome(
                    kind: .unchanged,
                    relative: resolved.relative,
                    pendingSeenPath: resolved.canonicalPath
                )
            }
            return nil
        }
        do {
            let needsReindex = try await services.store.needsReindex(
                source: .files,
                externalID: resolved.canonicalPath,
                contentHash: hash
            )
            guard needsReindex else {
                if Task.isCancelled {
                    return FileOutcome(kind: .cancelled, relative: resolved.relative)
                }
                let stamp = await stampCandidate(
                    store: services.store,
                    canonicalPath: resolved.canonicalPath,
                    runID: identity.runID
                )
                let unchanged = FileOutcome(kind: .unchanged, relative: resolved.relative)
                return stamped(stamp, onto: unchanged)
            }
        } catch is CancellationError {
            return FileOutcome(kind: .cancelled, relative: resolved.relative)
        } catch {
            let stamp = await stampCandidate(
                store: services.store,
                canonicalPath: resolved.canonicalPath,
                runID: identity.runID
            )
            return stamped(stamp, onto: failedOutcome(relative: resolved.relative, reason: "store lookup failed"))
        }
        return nil
    }

    /// Applies extraction gating for one candidate. Unsupported files are skipped without a stamp
    /// because they were never committable; failed extractions stamp first so a prior row survives.
    static func checkExtractionTerminal(
        identity: CandidateIdentity,
        services: CandidateServices,
        resolved: ResolvedCandidate,
        extraction: DocumentExtraction
    ) async -> FileOutcome? {
        switch extraction.status {
        case .unsupported:
            return skippedOutcome(relative: resolved.relative)
        case .failed:
            let stamp = await stampCandidate(
                store: services.store,
                canonicalPath: resolved.canonicalPath,
                runID: identity.runID
            )
            return stamped(stamp, onto: failedOutcome(relative: resolved.relative, reason: "extraction failed"))
        default:
            return nil
        }
    }

    /// Stamps one visited file as seen by the current run without touching indexer state. -
    /// Parameters: - store: Document index the run writes into.
    static func stampCandidate(store: DocIndexStore, canonicalPath: String, runID: String) async -> StampResult {
        do {
            try await store.markSeen(source: .files, externalID: canonicalPath, runID: runID)
            return .ok
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed
        }
    }

    /// Embeds a document's chunks for a parallel worker, degrading to keyword-only on any failure.
    static func embedCandidate(
        extraction: DocumentExtraction,
        fileURL: URL,
        fileName: String,
        config: IndexConfig,
        embedder: any EmbeddingsBackend?,
        embeddingsPool: EmbeddingsBackendPool?
    ) async throws -> [[Float]]? {
        let embedded = try await embedCandidateWithVisual(
            extraction: extraction,
            fileURL: fileURL,
            fileName: fileName,
            config: config,
            embedder: embedder,
            embeddingsPool: embeddingsPool
        )
        return embedded.vectors
    }

    /// Embeds a document's chunks while reporting whether the visual path produced them.
    static func embedCandidateWithVisual(
        extraction: DocumentExtraction,
        fileURL: URL,
        fileName: String,
        config: IndexConfig,
        embedder: any EmbeddingsBackend?,
        embeddingsPool: EmbeddingsBackendPool?
    ) async throws -> (vectors: [[Float]]?, visualSucceeded: Bool) {
        guard !extraction.chunks.isEmpty else { return (nil, false) }

        // Multimodal image path: if format is image, attempt visual embedding
        if extraction.format == .image {
            if let embeddingsPool {
                let dim = try? await embeddingsPool.withBackend { await $0.dimension }
                if let visual = try await FilesIndexer.embedImageVisualVector(
                    fileURL: fileURL,
                    fileName: fileName,
                    expectedDimension: dim,
                    embedImage: { try await embeddingsPool.embedImage(at: fileURL) }
                ) {
                    return (visual, true)
                }
            } else if let embedder {
                let dim = await embedder.dimension
                if let visual = try await FilesIndexer.embedImageVisualVector(
                    fileURL: fileURL,
                    fileName: fileName,
                    expectedDimension: dim,
                    embedImage: { try await embedder.embedImage(at: fileURL) }
                ) {
                    return (visual, true)
                }
            }
        }

        let texts = FilesVectorPolicy.cappedEmbeddingTexts(
            extraction.chunks.map { chunk in
                EmbeddingGemmaPrompts.document(title: fileName, text: chunk.text)
            },
            cap: config.maxVectorChunksPerDocument
        )
        do {
            if let embeddingsPool {
                let dim = try? await embeddingsPool.withBackend { await $0.dimension }
                let vectors = try await embeddingsPool.withBackend { backend in
                    try await backend.embed(texts)
                }
                return (FilesIndexer.validatedEmbedVectors(vectors, expectedCount: texts.count, expectedDimension: dim), false)
            }
            if let embedder {
                let vectors = try await embedder.embed(texts)
                let dim = await embedder.dimension
                return (FilesIndexer.validatedEmbedVectors(vectors, expectedCount: texts.count, expectedDimension: dim), false)
            }
            return (nil, false)
        } catch {
            if error is CancellationError {
                throw error
            }
            RuneWeaverLog.stores.error("FilesIndexer: Failed to generate embeddings for candidate: \(error.localizedDescription)")
            return (nil, false)
        }
    }
}

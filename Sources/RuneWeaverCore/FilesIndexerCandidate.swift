// Rune Weaver Core — Parallel files candidate processing for the document index.
//
// Hosts the per-file worker path shared by parallel runs: grouped inputs,
// staged helpers, and the commit sequence mirror the sequential walk so
// parallel and sequential runs agree on counts for identical trees. Staging
// lives here so the walk file stays within lint budgets while the store,
// policy, and budget seams remain injected and behavior stays unchanged.

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
    ///
    /// Workers claim one slot just before committing a document and release it
    /// when the commit fails, so concurrent finishers can never write past the
    /// configured budget even though they extract concurrently.
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
    ///
    /// Carries only the per-file values that vary within a run, so the worker
    /// entry point groups the shared dependencies separately instead of
    /// threading sixteen positional arguments through every helper.
    struct CandidateIdentity: Sendable {
        /// Canonical file URL the guard allowed.
        let fileURL: URL
        /// Root the file was discovered under, for display paths.
        let root: URL
        /// Opaque stamp for the run in flight.
        let runID: String
    }

    /// Shared services consulted while processing one candidate.
    ///
    /// Groups the store, extraction, embedding, and policy seams so parallel
    /// workers share one value instead of repeating six dependencies on every
    /// helper signature.
    struct CandidateServices: Sendable {
        /// Document index the run writes into.
        let store: DocIndexStore
        /// Text extractor for the candidate file.
        let extractor: any DocumentTextExtracting
        /// Shared embeddings backend, or nil for keyword-only indexing.
        let embedder: (any EmbeddingsBackend)?
        /// Pooled backends preferred for parallel embedding, or nil to share `embedder`.
        let embeddingsPool: EmbeddingsBackendPool?
        /// Path policy consulted before opening the candidate.
        let accessGuard: any FilesIndexAccessGuard
        /// Which extracted documents are vectorized.
        let vectorPolicy: FilesVectorPolicy
    }

    /// Per-run policy and test seams for one candidate.
    ///
    /// Keeps walk caps, home boundary, and injectable I/O overrides together
    /// so helpers that only need policy never observe the store or budget.
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

    /// Mutable run coordination shared by all workers.
    ///
    /// Pairs the atomic nightly budget with the lock-guarded cancellation
    /// mirror so commit helpers observe both without extra parameters.
    struct CandidateRunState: Sendable {
        /// Actor-isolated nightly budget shared by all workers.
        let budget: FileIndexBudget
        /// Lock-guarded cancellation mirror set by `cancel()`.
        let cancellation: IndexCancellationFlag
    }

    /// Canonical identity derived once per candidate.
    ///
    /// Resolved up front so later stages reuse one stable external identifier
    /// instead of re-canonicalizing the URL on every branch.
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

    /// Extracted body plus the values needed to commit it.
    ///
    /// Bundles the read bytes, hash, and extraction so the commit stage takes
    /// one payload instead of repeating five positional arguments.
    struct CandidatePayload: Sendable {
        /// Source modification time, when known.
        let modificationDate: Date?
        /// File bytes that were hashed and extracted.
        let data: Data
        /// Content hash gating re-indexing.
        let contentHash: String
        /// Extracted document body.
        let extraction: DocumentExtraction
        /// One vector per embedded chunk, or nil when keyword-only.
        let vectors: [[Float]]?
        /// Whether the visual multimodal path produced the vectors.
        let visualSucceeded: Bool

        /// Creates a committable payload, defaulting visual success to false
        /// so keyword-only and text-embedded rows keep the interim image
        /// outcome unless the visual path explicitly succeeded.
        init(
            modificationDate: Date?,
            data: Data,
            contentHash: String,
            extraction: DocumentExtraction,
            vectors: [[Float]]?,
            visualSucceeded: Bool = false
        ) {
            self.modificationDate = modificationDate
            self.data = data
            self.contentHash = contentHash
            self.extraction = extraction
            self.vectors = vectors
            self.visualSucceeded = visualSucceeded
        }
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

    /// Outcome of preparing an extracted candidate payload.
    enum CandidatePayloadOutcome: Sendable {
        /// Extracted candidate payload ready for commit.
        case ready(CandidatePayload)
        /// Candidate processing resolved early.
        case finished(FileOutcome)
    }
}

// MARK: - Candidate worker

extension FilesIndexer {
    /// Processes one candidate file on a parallel worker, mirroring `indexFile` plus `persistExtraction`.
    ///
    /// Every branch matches the sequential path — fast-path skips, evicted
    /// handling, hashing, extraction gating, embedding with cancel checks, and
    /// actor-serialized store commits — so parallel and sequential runs agree
    /// on counts for identical trees. The nightly budget is claimed atomically
    /// just before the commit and released when the commit fails or cancels,
    /// so concurrent finishers can never overshoot it.
    /// - Parameters:
    ///   - identity: Per-file URLs plus the opaque stamp for the run in flight.
    ///   - services: Store, extractor, embeddings, guard, and vector policy.
    ///   - policy: Walk caps, home boundary, and injectable I/O overrides.
    ///   - state: Shared budget plus the lock-guarded cancellation mirror.
    /// - Returns: The outcome for the run to fold into its counters.
    static func processCandidate(
        identity: CandidateIdentity,
        services: CandidateServices,
        policy: CandidatePolicy,
        state: CandidateRunState
    ) async -> FileOutcome {
        let resolved = resolveCandidate(identity: identity, policy: policy)
        let preflight: CandidatePreflight
        switch await preflightCandidate(
            identity: identity,
            services: services,
            policy: policy,
            state: state,
            resolved: resolved
        ) {
        case let .ready(ready):
            preflight = ready
        case let .finished(outcome):
            return outcome
        }

        let payload: CandidatePayload
        switch await prepareCandidatePayload(
            identity: identity,
            services: services,
            policy: policy,
            state: state,
            resolved: resolved,
            preflight: preflight
        ) {
        case let .ready(ready):
            payload = ready
        case let .finished(outcome):
            return outcome
        }

        if state.cancellation.isSet || Task.isCancelled {
            return FileOutcome(kind: .cancelled, relative: resolved.relative)
        }
        return await commitCandidateDocument(
            identity: identity,
            services: services,
            policy: policy,
            state: state,
            resolved: resolved,
            payload: payload
        )
    }

    /// Evaluates pre-read metadata and policies for a candidate.
    ///
    /// Probes cancellation, unreadable resource values, symlinks, aliases, AppleDouble
    /// sidecars, iCloud eviction, max file size, access guard policy, and the
    /// stored fingerprint fast path.
    /// - Parameters:
    ///   - identity: Per-file URLs plus the run stamp.
    ///   - services: Store, extractor, embeddings, and access guard.
    ///   - policy: Walk caps, home boundary, and injectable I/O overrides.
    ///   - state: Shared budget plus the cancellation mirror.
    ///   - resolved: Canonical identity for the candidate.
    /// - Returns: A preflight bundle ready for reading, or an outcome when processing finishes early.
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
        guard size <= resolved.maxBytes else {
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

    /// Reads, hashes, extracts, and vectorizes candidate bytes into a committable payload.
    /// - Parameters:
    ///   - identity: Per-file URLs plus the run stamp.
    ///   - services: Store, extractor, embeddings, and access guard.
    ///   - policy: Walk caps, home boundary, and injectable I/O overrides.
    ///   - state: Shared budget plus the cancellation mirror.
    ///   - resolved: Canonical identity for the candidate.
    ///   - preflight: Resource values and guard-resolved read path.
    /// - Returns: Extracted candidate payload ready for commit, or an early outcome.
    static func prepareCandidatePayload(
        identity: CandidateIdentity,
        services: CandidateServices,
        policy: CandidatePolicy,
        state: CandidateRunState,
        resolved: ResolvedCandidate,
        preflight: CandidatePreflight
    ) async -> CandidatePayloadOutcome {
        if state.cancellation.isSet || Task.isCancelled {
            return .finished(FileOutcome(kind: .cancelled, relative: resolved.relative))
        }
        let data: Data
        do {
            data = try readCandidateBytes(policy: policy, resolvedPath: preflight.resolvedPath)
        } catch {
            if state.cancellation.isSet || Task.isCancelled {
                return .finished(FileOutcome(kind: .cancelled, relative: resolved.relative))
            }
            let stamp = await stampCandidate(
                store: services.store,
                canonicalPath: resolved.canonicalPath,
                runID: identity.runID
            )
            return .finished(stamped(stamp, onto: failedOutcome(relative: resolved.relative, reason: "unreadable")))
        }
        if state.cancellation.isSet || Task.isCancelled {
            return .finished(FileOutcome(kind: .cancelled, relative: resolved.relative))
        }
        guard data.count <= resolved.maxBytes else {
            return .finished(skippedOutcome(relative: resolved.relative))
        }
        let hash = Self.contentHash(for: data)
        if let settled = await checkContentCurrent(
            identity: identity,
            services: services,
            resolved: resolved,
            hash: hash
        ) {
            if state.cancellation.isSet || Task.isCancelled {
                return .finished(FileOutcome(kind: .cancelled, relative: resolved.relative))
            }
            return .finished(settled)
        }
        if state.cancellation.isSet || Task.isCancelled {
            return .finished(FileOutcome(kind: .cancelled, relative: resolved.relative))
        }
        let extraction = await services.extractor.extract(
            fileURL: identity.fileURL,
            contentType: nil
        )
        if let terminal = await checkExtractionTerminal(
            identity: identity,
            services: services,
            resolved: resolved,
            extraction: extraction
        ) {
            if state.cancellation.isSet || Task.isCancelled {
                return .finished(FileOutcome(kind: .cancelled, relative: resolved.relative))
            }
            return .finished(terminal)
        }
        if state.cancellation.isSet || Task.isCancelled {
            return .finished(FileOutcome(kind: .cancelled, relative: resolved.relative))
        }
        let vectors: [[Float]]?
        let visualSucceeded: Bool
        do {
            let embedded = try await resolveCandidateVectors(
                services: services,
                policy: policy,
                extraction: extraction,
                fileURL: identity.fileURL,
                fileName: resolved.filename,
                byteCount: data.count
            )
            vectors = embedded.vectors
            visualSucceeded = embedded.visualSucceeded
        } catch is CancellationError {
            return .finished(FileOutcome(kind: .cancelled, relative: resolved.relative))
        } catch {
            vectors = nil
            visualSucceeded = false
        }
        let payload = CandidatePayload(
            modificationDate: preflight.modificationDate,
            data: data,
            contentHash: hash,
            extraction: extraction,
            vectors: vectors,
            visualSucceeded: visualSucceeded
        )
        return .ready(payload)
    }

    /// Derives one stable identity for a candidate before any I/O.
    ///
    /// Canonicalization matches the sequential walk so stored keys agree
    /// across effort presets even when the enumerator returns different
    /// spellings of the same path.
    /// - Parameters:
    ///   - identity: Per-file URLs plus the run stamp.
    ///   - policy: Walk caps carrying `max_file_mb`.
    /// - Returns: Canonical URL, store key, display path, and byte cap.
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

    /// Builds a content-free error outcome for one candidate.
    ///
    /// Only the reason travels into the warning; file bytes never do.
    /// - Parameters:
    ///   - relative: Root-relative display path.
    ///   - reason: Short failure reason, never file content.
    /// - Returns: An error outcome carrying the warning line.
    static func failedOutcome(relative: String, reason: String) -> FileOutcome {
        FileOutcome(
            kind: .error(warning: FilesIndexer.skipWarningText(relative: relative, reason: reason)),
            relative: relative
        )
    }

    /// Folds a stamp result into a worker outcome.
    ///
    /// A failed stamp forces the reconcile to stay skipped; a cancelled stamp
    /// still counts the file but propagates cancellation to the run.
    /// - Parameters:
    ///   - stamp: Whether the `last_seen_run` write landed.
    ///   - outcome: Worker outcome to annotate.
    /// - Returns: The annotated outcome.
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
    /// Reports whether a candidate has no local bytes to read.
    ///
    /// An injected override wins in tests; the live ubiquity check runs
    /// otherwise so an undetermined download state never hides a readable file.
    /// - Parameters:
    ///   - policy: Override resolving evicted iCloud files, or nil for live.
    ///   - canonicalURL: Canonical file URL.
    ///   - values: Pre-fetched resource values.
    /// - Returns: True when the file is evicted.
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

    /// Handles an evicted file under the configured iCloud policy.
    ///
    /// The file is always skipped this run; under `download` its bytes are
    /// requested for a later run. Stamping keeps a previously indexed row
    /// alive so eviction alone never retires it.
    /// - Parameters:
    ///   - identity: Per-file URLs plus the run stamp.
    ///   - services: Document index the run writes into.
    ///   - policy: Evicted policy plus the download trigger.
    ///   - resolved: Canonical identity for the candidate.
    /// - Returns: A skipped outcome with the stamp folded in.
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

    /// Probes the pre-read fingerprint for an unchanged file.
    ///
    /// A matching size plus an mtime within tolerance and a non-failed prior
    /// extraction means the body is current without reading any bytes.
    /// - Parameters:
    ///   - identity: Per-file URLs plus the run stamp.
    ///   - services: Document index holding the stored fingerprint.
    ///   - resolved: Canonical identity for the candidate.
    ///   - values: Pre-fetched resource values with size and mtime.
    /// - Returns: An outcome when the file resolves here, or nil to keep reading.
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
    /// - Parameters:
    ///   - policy: Override reading file bytes, or nil for memory-mapped reads.
    ///   - resolvedPath: Canonical path the guard allowed.
    /// - Returns: File bytes.
    static func readCandidateBytes(policy: CandidatePolicy, resolvedPath: String) throws -> Data {
        if let fileReader = policy.fileReader {
            return try fileReader(URL(fileURLWithPath: resolvedPath))
        }
        return try Data(contentsOf: URL(fileURLWithPath: resolvedPath), options: [.mappedIfSafe])
    }

    /// Gates re-indexing on the stored content hash.
    /// - Parameters:
    ///   - identity: Per-file URLs plus the run stamp.
    ///   - services: Document index holding the stored hash.
    ///   - resolved: Canonical identity for the candidate.
    ///   - hash: Fresh content hash for the bytes just read.
    /// - Returns: An outcome when the file resolves here, or nil to keep extracting.
    static func checkContentCurrent(
        identity: CandidateIdentity,
        services: CandidateServices,
        resolved: ResolvedCandidate,
        hash: String
    ) async -> FileOutcome? {
        if Task.isCancelled {
            return FileOutcome(kind: .cancelled, relative: resolved.relative)
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

    /// Applies extraction gating for one candidate.
    ///
    /// Unsupported files are skipped without a stamp because they were never
    /// committable; failed extractions stamp first so a prior row survives.
    /// - Parameters:
    ///   - identity: Per-file URLs plus the run stamp.
    ///   - services: Store and extractor for the candidate.
    ///   - resolved: Canonical identity for the candidate.
    ///   - extraction: Extracted document body.
    /// - Returns: An outcome when extraction is terminal, or nil to keep embedding.
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

    /// Embeds one candidate's chunks inside the vector policy.
    ///
    /// A policy miss or missing backend stays keyword-only; embedding
    /// failures degrade the same way through the shared helper instead of
    /// failing the file. OCR-empty images bypass the status gate (keeping the
    /// byte bound) so the visual path is still attempted from its interim
    /// outcome. Cancellation is never degraded: it escapes as an
    /// error so the worker returns `.cancelled` before claiming budget or
    /// committing a keyword-only row.
    /// - Parameters:
    ///   - services: Embedding backends plus the vector policy.
    ///   - policy: Index policy carrying the per-document vector cap.
    ///   - extraction: Extracted document body.
    ///   - byteCount: Bytes considered for the document.
    /// - Returns: Vectors plus whether the visual path produced them.
    static func resolveCandidateVectors(
        services: CandidateServices,
        policy: CandidatePolicy,
        extraction: DocumentExtraction,
        fileURL: URL,
        fileName: String,
        byteCount: Int
    ) async throws -> (vectors: [[Float]]?, visualSucceeded: Bool) {
        let shouldAttempt: Bool = if extraction.format == .image {
            services.vectorPolicy.enabled && byteCount <= services.vectorPolicy.maxBytes
        } else {
            services.vectorPolicy.shouldEmbed(status: extraction.status, byteCount: byteCount)
        }
        guard shouldAttempt else {
            return (nil, false)
        }
        guard services.embedder != nil || services.embeddingsPool != nil else {
            return (nil, false)
        }
        return try await embedCandidateWithVisual(
            extraction: extraction,
            fileURL: fileURL,
            fileName: fileName,
            config: policy.config,
            embedder: services.embedder,
            embeddingsPool: services.embeddingsPool
        )
    }

    /// Commits one extracted candidate under the atomic nightly budget.
    ///
    /// The budget is claimed just before the write so concurrent finishers can
    /// never overshoot it, and released when the commit fails or cancels.
    /// The document row, its chunk rows (and their FTS entries via triggers),
    /// and the `last_seen_run` stamp land in one transaction, so a crash
    /// between writes can never strand a half-indexed document. A failed
    /// write still attempts a standalone stamp so a live row never retires
    /// for a transient failure.
    /// - Parameters:
    ///   - identity: Per-file URLs plus the run stamp.
    ///   - services: Document index the run writes into.
    ///   - policy: Index policy carrying the vector cap.
    ///   - state: Shared budget plus the cancellation mirror.
    ///   - resolved: Canonical identity for the candidate.
    ///   - payload: Bytes, hash, extraction, and vectors to write.
    /// - Returns: The indexed, over-budget, cancelled, or error outcome.
    static func commitCandidateDocument(
        identity: CandidateIdentity,
        services: CandidateServices,
        policy: CandidatePolicy,
        state: CandidateRunState,
        resolved: ResolvedCandidate,
        payload: CandidatePayload
    ) async -> FileOutcome {
        guard await state.budget.tryClaim() else {
            return FileOutcome(kind: .overBudget, relative: resolved.relative)
        }
        if state.cancellation.isSet || Task.isCancelled {
            await state.budget.release()
            return FileOutcome(kind: .cancelled, relative: resolved.relative)
        }
        let document = IndexedDocument(
            source: .files,
            externalID: resolved.canonicalPath,
            displayName: resolved.filename,
            path: resolved.canonicalPath,
            mtime: payload.modificationDate,
            sizeBytes: Int64(payload.data.count),
            contentHash: payload.contentHash,
            mime: nil,
            extractStatus: FilesIndexer.effectiveImageStatus(
                extraction: payload.extraction,
                visualSucceeded: payload.visualSucceeded
            ),
            indexedAt: Date()
        )
        // Chunks bind the fresh identifier up front; the atomic commit remaps
        // them onto the stable row when the path was already indexed.
        let chunks = Self.makeChunks(
            extraction: payload.extraction,
            documentID: document.id,
            vectors: payload.vectors,
            fallbackDisplayName: resolved.filename,
            fallbackPath: resolved.relative
        )
        do {
            _ = try await services.store.upsertDocumentWithChunks(
                document: document,
                chunks: chunks,
                runID: identity.runID
            )
        } catch is CancellationError {
            await state.budget.release()
            return FileOutcome(kind: .cancelled, relative: resolved.relative)
        } catch {
            await state.budget.release()
            let stamp = await stampCandidate(
                store: services.store,
                canonicalPath: resolved.canonicalPath,
                runID: identity.runID
            )
            return stamped(stamp, onto: failedOutcome(relative: resolved.relative, reason: "store write failed"))
        }
        let truncated = FilesIndexer.isVectorTruncated(
            vectors: payload.vectors,
            chunkCount: payload.extraction.chunks.count,
            cap: policy.config.maxVectorChunksPerDocument
        )
        var outcome = FileOutcome(
            kind: .indexed(
                chunks: chunks.count,
                vectors: chunks.reduce(0) { $0 + ($1.isVector ? 1 : 0) },
                truncated: truncated
            ),
            relative: resolved.relative
        )
        // A stop landing during the commit still marks the run so parallel
        // workers within one batch observe cancel without dropping the row.
        if state.cancellation.isSet || Task.isCancelled {
            outcome.propagateCancel = true
        }
        return outcome
    }

    /// Stamps one visited file as seen by the current run without touching indexer state.
    /// - Parameters:
    ///   - store: Document index the run writes into.
    ///   - canonicalPath: Stable external identifier.
    ///   - runID: Opaque stamp for the run in flight.
    /// - Returns: Whether the stamp landed, failed, or observed cancellation.
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
    ///
    /// A pooled backend is preferred when one is configured so concurrent
    /// workers never serialize on a single backend actor; a shared backend
    /// stays correct but may serialize actor-backed implementations. A width
    /// or count mismatch is treated as a backend failure so a partial vector
    /// list never pairs the wrong vector with a chunk. Cancellation escapes
    /// instead of degrading so the worker stops before claiming budget: the
    /// caller converts it to a `.cancelled` outcome without committing.
    /// - Parameters:
    ///   - extraction: Extracted document body.
    ///   - config: Index policy carrying the per-document vector cap.
    ///   - embedder: Shared backend, or nil when only the pool is configured.
    ///   - embeddingsPool: Pooled backends, or nil to share `embedder`.
    /// - Returns: One vector per embedded chunk, or nil when the document stays keyword-only.
    static func embedCandidate(
        extraction: DocumentExtraction,
        fileURL: URL,
        fileName: String,
        config: IndexConfig,
        embedder: (any EmbeddingsBackend)?,
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
    ///
    /// Shares the same visual-first then text-fallback sequence as
    /// `embedCandidate` so the commit can promote an interim image row to
    /// `.extracted` only after a visual vector lands; text-only vectors keep
    /// the interim outcome.
    /// - Parameters:
    ///   - extraction: Extracted document body.
    ///   - config: Index policy carrying the per-document vector cap.
    ///   - embedder: Shared backend, or nil when only the pool is configured.
    ///   - embeddingsPool: Pooled backends, or nil to share `embedder`.
    /// - Returns: Vectors plus whether the visual multimodal path produced them.
    static func embedCandidateWithVisual(
        extraction: DocumentExtraction,
        fileURL: URL,
        fileName: String,
        config: IndexConfig,
        embedder: (any EmbeddingsBackend)?,
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

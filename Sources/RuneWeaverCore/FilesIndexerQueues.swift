// Rune Weaver Core — Multi-queue modality scheduling and cross-file batching for the files indexer.

import Foundation

extension FilesIndexer {
    /// Maximum number of extracted candidates accumulated before flushing a batch commit.
    static let maxStagedCandidatesPerBatch = 64

    /// Maximum number of text chunks sent in a single `/v1/embeddings` request.
    static let maxEmbeddingChunksPerRequest = 32

    /// Maximum UTF-8 bytes sent in a single `/v1/embeddings` request (~3,000–3,500 tokens),
    /// keeping every request comfortably below `llama-server`'s slot context window.
    static let maxEmbeddingSubBatchBytes = 12000

    /// Maximum number of pending prompt chunks accumulated before triggering a parallel batch flush.
    /// With 4 parallel slots and 32 chunks per sub-batch, 128 prompts saturates all 4 slots.
    static let maxStagedPromptsPerBatch = 128

    /// Maximum number of parallel embedding sub-batch requests dispatched concurrently.
    static let maxConcurrentEmbeddingRequests = 4

    /// Maximum number of unchanged file paths accumulated before a `markSeenBatch` SQLite transaction.
    static let maxPendingSeenBatchSize = 256

    /// Extracted file candidate waiting for cross-file batched vectorization and bulk SQLite commit.
    struct StagedCandidate: Sendable {
        /// Canonical identity and paths for the candidate.
        let identity: CandidateIdentity
        /// Resolved paths and size limits for the candidate.
        let resolved: ResolvedCandidate
        /// Source modification timestamp, when known.
        let modificationDate: Date?
        /// Raw byte count of the candidate.
        let byteCount: Int
        /// Content hash gating re-indexing.
        let contentHash: String
        /// Extracted document chunks and status.
        let extraction: DocumentExtraction
        /// Vectors already resolved during staging (e.g. multimodal image visual vectors).
        let precomputedVectors: [[Float]]?
        /// Whether the multimodal visual embedding path produced `precomputedVectors`.
        let visualSucceeded: Bool
        /// Prompt-formatted chunk texts to embed in a cross-file batch when `precomputedVectors == nil`.
        let pendingPromptTexts: [String]
    }

    /// Result of running parallel worker extraction on one candidate file.
    enum StagedCandidateResult: Sendable {
        /// Candidate resolved during preflight/extraction (unchanged, skipped, error, or cancelled).
        case outcome(FileOutcome)
        /// Candidate extracted cleanly and is ready for batched embedding and SQLite commit.
        case staged(StagedCandidate)
    }

    private struct QueuedCandidateEntry {
        let file: URL
        let root: URL
        let mtime: TimeInterval
        let order: Int
    }

    /// Partitions discovered candidates into the 4 modality queues (`.keywordData`, `.fastText`,
    /// `.imageOCR`, `.mediaSpeech`) and orders each queue newest-mtime first so slow media or OCR
    /// files never head-of-line block fast text files.
    static func partitionIntoModalityQueues(
        candidates: [(file: URL, root: URL)],
        maxVectorBytes: Int
    ) -> [(file: URL, root: URL)] {
        partitionCandidatesWithLanes(candidates: candidates, maxVectorBytes: maxVectorBytes).candidates
    }

    /// Partitions discovered candidates into the 4 modality queues and returns both the ordered
    /// candidate list and initial per-lane queue counts for live dashboard telemetry.
    static func partitionCandidatesWithLanes(
        candidates: [(file: URL, root: URL)],
        maxVectorBytes: Int
    ) -> (candidates: [(file: URL, root: URL)], lanes: [IndexQueueLaneProgress]) {
        var buckets: [[QueuedCandidateEntry]] = Array(
            repeating: [],
            count: FilesModalityLane.allCases.count
        )
        for (index, item) in candidates.enumerated() {
            let values = try? item.file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values?.fileSize ?? 0
            let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            let lane = FilesVectorPolicy.modalityLane(
                fileName: item.file.lastPathComponent,
                byteCount: size,
                maxVectorBytes: maxVectorBytes
            )
            buckets[lane.rawValue].append(QueuedCandidateEntry(
                file: item.file,
                root: item.root,
                mtime: mtime,
                order: index
            ))
        }
        let lanes: [IndexQueueLaneProgress] = FilesModalityLane.allCases.map { lane in
            IndexQueueLaneProgress(
                lane: lane.key,
                label: lane.label,
                queued: buckets[lane.rawValue].count,
                processed: 0,
                indexed: 0
            )
        }
        guard candidates.count > 1 else {
            return (candidates: candidates, lanes: lanes)
        }
        var ordered: [(file: URL, root: URL)] = []
        ordered.reserveCapacity(candidates.count)
        for lane in FilesModalityLane.allCases {
            var bucket = buckets[lane.rawValue]
            bucket.sort { lhs, rhs in
                if lhs.mtime != rhs.mtime {
                    return lhs.mtime > rhs.mtime
                }
                return lhs.order < rhs.order
            }
            for entry in bucket {
                ordered.append((entry.file, entry.root))
            }
        }
        return (candidates: ordered, lanes: lanes)
    }

    /// Resolves the modality lane for a candidate at `orderedIndex` inside the partitioned queue.
    static func laneForOrderedIndex(_ orderedIndex: Int, in lanes: [IndexQueueLaneProgress]) -> FilesModalityLane {
        var cursor = 0
        for lane in FilesModalityLane.allCases where lanes.indices.contains(lane.rawValue) {
            let nextCursor = cursor + lanes[lane.rawValue].queued
            if orderedIndex < nextCursor {
                return lane
            }
            cursor = nextCursor
        }
        return .fastText
    }

    /// Updates per-lane processed and indexed counters when a candidate finishes.
    static func recordQueueLaneOutcome(_ outcome: FileOutcome, lanes: inout [IndexQueueLaneProgress]) {
        guard let lane = outcome.lane, lanes.indices.contains(lane.rawValue) else { return }
        switch outcome.kind {
        case .indexed:
            lanes[lane.rawValue].processed += 1
            lanes[lane.rawValue].indexed += 1
        case .unchanged, .skipped, .error:
            lanes[lane.rawValue].processed += 1
        case .overBudget, .cancelled:
            break
        }
    }

    /// Filters discovered candidates against preloaded fingerprints and walk policies so only
    /// new or modified files enter the 4 modality queues, while `counters.scanned` advances
    /// across all inspected files during the walk.
    func preflightAndPartitionCandidates(
        discovered: [(file: URL, root: URL)],
        budget: FileIndexBudget,
        start: ContinuousClock.Instant,
        preloadedFingerprints: [String: DocStoredFingerprint]?,
        counters: inout Counters
    ) async -> [(file: URL, root: URL)] {
        let services = CandidateServices(
            store: store,
            extractor: extractor,
            embedder: embedder,
            embeddingsPool: embeddingsPool,
            accessGuard: accessGuard,
            vectorPolicy: vectorPolicy,
            preloadedFingerprints: preloadedFingerprints
        )
        let policy = CandidatePolicy(
            config: config,
            homeDirectoryURL: homeDirectoryURL,
            evictedCheck: evictedCheck,
            downloadStarter: downloadStarter,
            fileReader: fileReader
        )
        let state = CandidateRunState(budget: budget, cancellation: cancelBox)
        var readyCandidates: [(file: URL, root: URL)] = []
        readyCandidates.reserveCapacity(discovered.count)
        var pendingSeenPaths: [String] = []
        var sinceYield = 0

        for item in discovered {
            sinceYield += 1
            if sinceYield >= 64 {
                sinceYield = 0
                await Task.yield()
            }
            if isCancelled || cancelBox.isSet || Task.isCancelled {
                break
            }
            let identity = CandidateIdentity(
                fileURL: item.file,
                root: item.root,
                runID: counters.runID
            )
            let resolved = Self.resolveCandidate(identity: identity, policy: policy)
            switch await Self.preflightCandidate(
                identity: identity,
                services: services,
                policy: policy,
                state: state,
                resolved: resolved
            ) {
            case .ready:
                counters.scanned += 1
                readyCandidates.append(item)
                await reportWork(resolved.relative, counters: counters, start: start)
            case let .finished(outcome):
                if let seenPath = outcome.pendingSeenPath {
                    pendingSeenPaths.append(seenPath)
                    if pendingSeenPaths.count >= Self.maxPendingSeenBatchSize {
                        await flushPendingSeenPaths(
                            &pendingSeenPaths,
                            runID: counters.runID,
                            counters: &counters
                        )
                    }
                }
                await foldOutcome(outcome, counters: &counters, start: start)
            }
        }
        if !isCancelled, !cancelBox.isSet, !Task.isCancelled {
            await flushPendingSeenPaths(&pendingSeenPaths, runID: counters.runID, counters: &counters)
        }
        let partitioned = Self.partitionCandidatesWithLanes(
            candidates: readyCandidates,
            maxVectorBytes: vectorPolicy.maxBytes
        )
        counters.queueLanes = partitioned.lanes
        return partitioned.candidates
    }

    /// Mutable batch accumulation state for the multi-queue modality pipeline.
    private struct ModalityPipelineBatchState {
        let totalCandidates: Int
        var workers: Int
        let budget: FileIndexBudget
        let runID: String
        let start: ContinuousClock.Instant
        var stagedBatch: [StagedCandidate] = []
        var pendingSeenPaths: [String] = []
    }

    /// Runs the multi-queue producer-consumer pipeline across discovered candidates.
    func runQueuedModalityPipeline(
        candidates: [(file: URL, root: URL)],
        workers: Int,
        budget: FileIndexBudget,
        start: ContinuousClock.Instant,
        preloadedFingerprints: [String: DocStoredFingerprint]?,
        counters: inout Counters
    ) async {
        guard !candidates.isEmpty, !isCancelled, !cancelBox.isSet, !Task.isCancelled else { return }
        let runID = counters.runID
        lastReportInstant = nil
        await emit(message: Self.workMessage(counters: counters), counters: counters, current: nil, start: start)
        let services = CandidateServices(
            store: store,
            extractor: extractor,
            embedder: embedder,
            embeddingsPool: embeddingsPool,
            accessGuard: accessGuard,
            vectorPolicy: vectorPolicy,
            preloadedFingerprints: preloadedFingerprints
        )
        let policy = CandidatePolicy(
            config: config,
            homeDirectoryURL: homeDirectoryURL,
            evictedCheck: evictedCheck,
            downloadStarter: downloadStarter,
            fileReader: fileReader
        )
        let state = CandidateRunState(budget: budget, cancellation: cancelBox)
        let initialLanes = counters.queueLanes
        var batchState = ModalityPipelineBatchState(
            totalCandidates: candidates.count,
            workers: max(1, workers),
            budget: budget,
            runID: runID,
            start: start
        )

        await withTaskGroup(of: StagedCandidateResult.self) { group in
            var next = 0
            var inFlight = 0
            while next < candidates.count {
                if isCancelled || cancelBox.isSet || Task.isCancelled {
                    break
                }
                if await budget.isExhausted {
                    if !isCancelled, !cancelBox.isSet, !Task.isCancelled {
                        counters.budgetStoppedEarly = true
                    }
                    break
                }
                let allowed = currentWorkerLimit(base: workers)
                if allowed <= 0 {
                    counters.thermalStoppedEarly = true
                    if config.pauseOnBattery, lowPowerModeProvider() {
                        counters.warnings.append("Paused new work: Low Power Mode is on")
                    } else {
                        counters.warnings.append("Paused new work: thermal state is critical")
                    }
                    break
                }
                if inFlight >= allowed {
                    guard let result = await group.next() else { break }
                    inFlight -= 1
                    batchState.workers = allowed
                    await handleStagedWorkerResult(result, batchState: &batchState, counters: &counters)
                    continue
                }
                let candidateIndex = next
                let candidate = candidates[candidateIndex]
                let lane = Self.laneForOrderedIndex(candidateIndex, in: initialLanes)
                next += 1
                group.addTask(priority: .utility) {
                    await FilesIndexer.stageCandidateWithLane(
                        identity: CandidateIdentity(
                            fileURL: candidate.file,
                            root: candidate.root,
                            runID: runID,
                            lane: lane
                        ),
                        services: services,
                        policy: policy,
                        state: state
                    )
                }
                inFlight += 1
            }
            batchState.workers = max(1, workers)
            for await result in group {
                inFlight -= 1
                await handleStagedWorkerResult(result, batchState: &batchState, counters: &counters)
            }
        }
        await flushStagedBatch(&batchState.stagedBatch, budget: budget, start: start, counters: &counters)
        await flushPendingSeenPaths(&batchState.pendingSeenPaths, runID: runID, counters: &counters)
    }

    /// Processes one worker result, batching unchanged seen-stamps and cross-file staged candidates.
    private func handleStagedWorkerResult(
        _ result: StagedCandidateResult,
        batchState: inout ModalityPipelineBatchState,
        counters: inout Counters
    ) async {
        switch result {
        case var .outcome(outcome):
            outcome.preScanned = true
            if let seenPath = outcome.pendingSeenPath {
                batchState.pendingSeenPaths.append(seenPath)
                if batchState.pendingSeenPaths.count >= Self.maxPendingSeenBatchSize {
                    await flushPendingSeenPaths(
                        &batchState.pendingSeenPaths,
                        runID: batchState.runID,
                        counters: &counters
                    )
                }
            }
            await foldOutcome(outcome, counters: &counters, start: batchState.start)
        case let .staged(candidate):
            if isCancelled || cancelBox.isSet || Task.isCancelled {
                return
            }
            guard await batchState.budget.tryClaim() else {
                let overBudget = FileOutcome(
                    kind: .overBudget,
                    relative: candidate.resolved.relative,
                    lane: candidate.identity.lane,
                    preScanned: true
                )
                await foldOutcome(overBudget, counters: &counters, start: batchState.start)
                return
            }
            batchState.stagedBatch.append(candidate)
            let batchLimit: Int = if counters.indexed == 0 {
                1
            } else if config.nightlyBudget > 0 {
                max(1, min(Self.maxStagedCandidatesPerBatch, config.nightlyBudget - counters.indexed))
            } else if batchState.totalCandidates <= 16 {
                max(1, min(batchState.workers, 4))
            } else {
                Self.maxStagedCandidatesPerBatch
            }
            let pendingPrompts = batchState.stagedBatch.reduce(0) { $0 + $1.pendingPromptTexts.count }
            let pendingPromptBytes = batchState.stagedBatch.reduce(0) { total, item in
                total + item.pendingPromptTexts.reduce(0) { $0 + $1.utf8.count }
            }
            if batchState.stagedBatch.count >= batchLimit
                || pendingPrompts >= Self.maxStagedPromptsPerBatch
                || pendingPromptBytes >= (Self.maxEmbeddingSubBatchBytes * Self.maxConcurrentEmbeddingRequests)
            {
                await flushStagedBatch(
                    &batchState.stagedBatch,
                    budget: batchState.budget,
                    start: batchState.start,
                    counters: &counters
                )
            }
        }
    }

    /// Runs `stageCandidate` and stamps `identity.lane` and `preScanned` onto any immediate `FileOutcome`.
    static func stageCandidateWithLane(
        identity: CandidateIdentity,
        services: CandidateServices,
        policy: CandidatePolicy,
        state: CandidateRunState
    ) async -> StagedCandidateResult {
        switch await stageCandidate(identity: identity, services: services, policy: policy, state: state) {
        case var .outcome(outcome):
            outcome.lane = identity.lane
            outcome.preScanned = true
            return .outcome(outcome)
        case let .staged(candidate):
            return .staged(candidate)
        }
    }

    /// Performs preflight, byte read, hashing, and text/OCR/speech extraction on a worker task.
    /// Text candidates return `.staged` so their chunks can be embedded and committed in batches.
    static func stageCandidate(
        identity: CandidateIdentity,
        services: CandidateServices,
        policy: CandidatePolicy,
        state: CandidateRunState
    ) async -> StagedCandidateResult {
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
            return .outcome(outcome)
        }

        if state.cancellation.isSet || Task.isCancelled {
            return .outcome(FileOutcome(kind: .cancelled, relative: resolved.relative))
        }
        let data: Data
        do {
            data = try readCandidateBytes(policy: policy, resolvedPath: preflight.resolvedPath)
        } catch {
            if state.cancellation.isSet || Task.isCancelled {
                return .outcome(FileOutcome(kind: .cancelled, relative: resolved.relative))
            }
            let stamp = await stampCandidate(
                store: services.store,
                canonicalPath: resolved.canonicalPath,
                runID: identity.runID
            )
            return .outcome(stamped(stamp, onto: failedOutcome(relative: resolved.relative, reason: "unreadable")))
        }
        if state.cancellation.isSet || Task.isCancelled {
            return .outcome(FileOutcome(kind: .cancelled, relative: resolved.relative))
        }
        let payloadFormat = DocumentTextExtractor.detectFormat(fileName: resolved.filename, contentType: nil)
        let isMediaPayload = payloadFormat == .audio || payloadFormat == .video
        guard isMediaPayload || data.count <= resolved.maxBytes else {
            return .outcome(skippedOutcome(relative: resolved.relative))
        }
        let hash = Self.contentHash(for: data)
        if let settled = await checkContentCurrent(
            identity: identity,
            services: services,
            resolved: resolved,
            hash: hash
        ) {
            if state.cancellation.isSet || Task.isCancelled {
                return .outcome(FileOutcome(kind: .cancelled, relative: resolved.relative))
            }
            return .outcome(settled)
        }
        if state.cancellation.isSet || Task.isCancelled {
            return .outcome(FileOutcome(kind: .cancelled, relative: resolved.relative))
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
                return .outcome(FileOutcome(kind: .cancelled, relative: resolved.relative))
            }
            return .outcome(terminal)
        }
        if state.cancellation.isSet || Task.isCancelled {
            return .outcome(FileOutcome(kind: .cancelled, relative: resolved.relative))
        }
        return await buildStagedCandidate(
            context: ExtractedCandidateContext(
                identity: identity,
                resolved: resolved,
                modificationDate: preflight.modificationDate,
                byteCount: data.count,
                contentHash: hash,
                extraction: extraction
            ),
            services: services,
            policy: policy
        )
    }

    /// Context for an extracted candidate prior to vector resolution.
    private struct ExtractedCandidateContext {
        let identity: CandidateIdentity
        let resolved: ResolvedCandidate
        let modificationDate: Date?
        let byteCount: Int
        let contentHash: String
        let extraction: DocumentExtraction
    }

    /// Resolves whether a candidate needs visual embedding immediately or cross-file batched text embedding.
    private static func buildStagedCandidate(
        context: ExtractedCandidateContext,
        services: CandidateServices,
        policy: CandidatePolicy
    ) async -> StagedCandidateResult {
        let shouldEmbed = shouldAttemptCandidateEmbedding(
            services: services,
            extraction: context.extraction,
            fileName: context.resolved.filename,
            byteCount: context.byteCount
        )
        guard shouldEmbed, !context.extraction.chunks.isEmpty else {
            return .staged(StagedCandidate(
                identity: context.identity,
                resolved: context.resolved,
                modificationDate: context.modificationDate,
                byteCount: context.byteCount,
                contentHash: context.contentHash,
                extraction: context.extraction,
                precomputedVectors: nil,
                visualSucceeded: false,
                pendingPromptTexts: []
            ))
        }
        if context.extraction.format == .image {
            do {
                let embedded = try await embedCandidateWithVisual(
                    extraction: context.extraction,
                    fileURL: context.identity.fileURL,
                    fileName: context.resolved.filename,
                    config: policy.config,
                    embedder: services.embedder,
                    embeddingsPool: services.embeddingsPool
                )
                return .staged(StagedCandidate(
                    identity: context.identity,
                    resolved: context.resolved,
                    modificationDate: context.modificationDate,
                    byteCount: context.byteCount,
                    contentHash: context.contentHash,
                    extraction: context.extraction,
                    precomputedVectors: embedded.vectors,
                    visualSucceeded: embedded.visualSucceeded,
                    pendingPromptTexts: []
                ))
            } catch is CancellationError {
                return .outcome(FileOutcome(kind: .cancelled, relative: context.resolved.relative))
            } catch {
                return .staged(StagedCandidate(
                    identity: context.identity,
                    resolved: context.resolved,
                    modificationDate: context.modificationDate,
                    byteCount: context.byteCount,
                    contentHash: context.contentHash,
                    extraction: context.extraction,
                    precomputedVectors: nil,
                    visualSucceeded: false,
                    pendingPromptTexts: []
                ))
            }
        }
        let prompts = FilesVectorPolicy.cappedEmbeddingTexts(
            context.extraction.chunks.map { chunk in
                EmbeddingGemmaPrompts.document(title: context.resolved.filename, text: chunk.text)
            },
            cap: policy.config.maxVectorChunksPerDocument
        )
        return .staged(StagedCandidate(
            identity: context.identity,
            resolved: context.resolved,
            modificationDate: context.modificationDate,
            byteCount: context.byteCount,
            contentHash: context.contentHash,
            extraction: context.extraction,
            precomputedVectors: nil,
            visualSucceeded: false,
            pendingPromptTexts: prompts
        ))
    }

    /// Evaluates whether a candidate should be vectorized under the active vector policy.
    private static func shouldAttemptCandidateEmbedding(
        services: CandidateServices,
        extraction: DocumentExtraction,
        fileName: String,
        byteCount: Int
    ) -> Bool {
        guard services.embedder != nil || services.embeddingsPool != nil else {
            return false
        }
        if FilesVectorPolicy.isKeywordOnlyFile(fileName: fileName) {
            return false
        }
        let imageMaxBytes = services.vectorPolicy.maxBytes == FilesVectorPolicy.defaultMaxBytes
            ? 30 * 1024 * 1024
            : services.vectorPolicy.maxBytes
        let transcriptBytes = extraction.chunks.reduce(0) { $0 + $1.text.utf8.count }
        switch extraction.format {
        case .image:
            return services.vectorPolicy.enabled && byteCount <= imageMaxBytes
        case .audio, .video:
            return services.vectorPolicy.shouldEmbed(status: extraction.status, byteCount: transcriptBytes)
        default:
            return services.vectorPolicy.shouldEmbed(status: extraction.status, byteCount: byteCount)
        }
    }

    /// Flushes a batch of staged candidates by cross-file batching their embeddings and committing
    /// all documents and chunks in a single SQLite transaction.
    func flushStagedBatch(
        _ batch: inout [StagedCandidate],
        budget: FileIndexBudget,
        start: ContinuousClock.Instant,
        counters: inout Counters
    ) async {
        guard !batch.isEmpty else { return }
        let currentBatch = batch
        batch.removeAll(keepingCapacity: true)

        if isCancelled || cancelBox.isSet || Task.isCancelled {
            for _ in currentBatch {
                await budget.release()
            }
            isCancelled = true
            cancelBox.set()
            return
        }

        let resolvedVectorsByIndex = await embedStagedBatchTexts(currentBatch)
        if isCancelled || cancelBox.isSet || Task.isCancelled {
            for _ in currentBatch {
                await budget.release()
            }
            isCancelled = true
            cancelBox.set()
            return
        }

        var entries: [DocBatchUpsertEntry] = []
        entries.reserveCapacity(currentBatch.count)

        let indexedAt = Date()
        for (index, item) in currentBatch.enumerated() {
            let vectors = item.precomputedVectors ?? resolvedVectorsByIndex[index]
            let document = IndexedDocument(
                source: .files,
                externalID: item.resolved.canonicalPath,
                displayName: item.resolved.filename,
                path: item.resolved.canonicalPath,
                mtime: item.modificationDate,
                sizeBytes: Int64(item.byteCount),
                contentHash: item.contentHash,
                mime: nil,
                extractStatus: Self.effectiveImageStatus(
                    extraction: item.extraction,
                    visualSucceeded: item.visualSucceeded
                ),
                indexedAt: indexedAt
            )
            let chunks = Self.makeChunks(
                extraction: item.extraction,
                documentID: document.id,
                vectors: vectors,
                fallbackDisplayName: item.resolved.filename,
                fallbackPath: item.resolved.relative
            )
            entries.append(DocBatchUpsertEntry(
                document: document,
                chunks: chunks,
                runID: item.identity.runID
            ))
        }

        do {
            _ = try await store.upsertDocumentsWithChunks(entries)
            for (index, item) in currentBatch.enumerated() {
                let chunks = entries[index].chunks
                let vectors = item.precomputedVectors ?? resolvedVectorsByIndex[index]
                let truncated = Self.isVectorTruncated(
                    vectors: vectors,
                    chunkCount: item.extraction.chunks.count,
                    cap: config.maxVectorChunksPerDocument
                )
                var outcome = FileOutcome(
                    kind: .indexed(
                        chunks: chunks.count,
                        vectors: chunks.reduce(0) { $0 + ($1.isVector ? 1 : 0) },
                        truncated: truncated
                    ),
                    relative: item.resolved.relative,
                    lane: item.identity.lane,
                    preScanned: true
                )
                if cancelBox.isSet || Task.isCancelled {
                    outcome.propagateCancel = true
                }
                await foldOutcome(outcome, counters: &counters, start: start)
            }
        } catch is CancellationError {
            for _ in currentBatch {
                await budget.release()
            }
            isCancelled = true
            cancelBox.set()
        } catch {
            await commitStagedBatchIndividually(
                currentBatch,
                entries: entries,
                resolvedVectorsByIndex: resolvedVectorsByIndex,
                budget: budget,
                start: start,
                counters: &counters
            )
        }
        await Task.yield()
    }

    private struct StagedPromptSlice {
        let candidateIndex: Int
        let start: Int
        let count: Int
    }

    /// Computes the upper bound index for the next `/v1/embeddings` sub-batch, bounded by both
    /// `maxEmbeddingChunksPerRequest` (32) and `maxEmbeddingSubBatchBytes` (12,000 UTF-8 bytes).
    /// Always advances by at least 1 chunk even if a single chunk exceeds the byte threshold.
    static func nextEmbeddingSubBatchEnd(in texts: [String], from start: Int) -> Int {
        guard start < texts.count else { return texts.count }
        let maxEnd = min(start + maxEmbeddingChunksPerRequest, texts.count)
        var end = start
        var accumulatedBytes = 0
        while end < maxEnd {
            let chunkBytes = texts[end].utf8.count
            if end > start, accumulatedBytes + chunkBytes > maxEmbeddingSubBatchBytes {
                break
            }
            accumulatedBytes += chunkBytes
            end += 1
        }
        return max(start + 1, end)
    }

    /// Embeds all pending prompt texts across a staged batch in character- and chunk-bounded sub-batches.
    private func embedStagedBatchTexts(_ batch: [StagedCandidate]) async -> [Int: [[Float]]] {
        var flatTexts: [String] = []
        var slices: [StagedPromptSlice] = []
        for (index, item) in batch.enumerated() where item.precomputedVectors == nil && !item.pendingPromptTexts.isEmpty {
            let startOffset = flatTexts.count
            flatTexts.append(contentsOf: item.pendingPromptTexts)
            slices.append(StagedPromptSlice(
                candidateIndex: index,
                start: startOffset,
                count: item.pendingPromptTexts.count
            ))
        }
        guard !flatTexts.isEmpty else { return [:] }

        var expectedDim: Int?
        if let embeddingsPool {
            expectedDim = try? await embeddingsPool.withBackend { await $0.dimension }
        } else if let embedder {
            expectedDim = await embedder.dimension
        }

        var subBatchRanges: [Range<Int>] = []
        var offset = 0
        while offset < flatTexts.count {
            let end = Self.nextEmbeddingSubBatchEnd(in: flatTexts, from: offset)
            subBatchRanges.append(offset ..< end)
            offset = end
        }

        let allVectors = await Self.embedSubBatchesConcurrently(
            flatTexts: flatTexts,
            subBatchRanges: subBatchRanges,
            embeddingsPool: embeddingsPool,
            embedder: embedder,
            cancelBox: cancelBox,
            expectedDimension: expectedDim
        )

        if isCancelled || cancelBox.isSet || Task.isCancelled {
            return [:]
        }

        var result: [Int: [[Float]]] = [:]
        for slice in slices {
            // Preserve per-index empties so one failed chunk stays keyword-only
            // without dropping later successes in the same candidate.
            result[slice.candidateIndex] = Array(allVectors[slice.start ..< (slice.start + slice.count)])
        }
        return result
    }

    /// Concurrently embeds partitioned sub-batches across available slots.
    private static func embedSubBatchesConcurrently(
        flatTexts: [String],
        subBatchRanges: [Range<Int>],
        embeddingsPool: EmbeddingsBackendPool?,
        embedder: any EmbeddingsBackend?,
        cancelBox: IndexCancellationFlag,
        expectedDimension: Int?
    ) async -> [[Float]] {
        var allVectors: [[Float]] = Array(repeating: [], count: flatTexts.count)
        let pool = embeddingsPool
        let singleEmbedder = embedder
        let flag = cancelBox
        let dim = expectedDimension
        let concurrencyLimit = Self.maxConcurrentEmbeddingRequests

        await withTaskGroup(of: (Range<Int>, [[Float]]).self) { group in
            var subBatchIndex = 0
            var inFlight = 0
            while subBatchIndex < subBatchRanges.count {
                if flag.isSet || Task.isCancelled {
                    break
                }
                if inFlight >= concurrencyLimit {
                    if let (range, vectors) = await group.next() {
                        inFlight -= 1
                        for (idx, vec) in zip(range, vectors) {
                            allVectors[idx] = vec
                        }
                    } else {
                        break
                    }
                }
                let range = subBatchRanges[subBatchIndex]
                subBatchIndex += 1
                let subBatch = Array(flatTexts[range])
                inFlight += 1
                group.addTask {
                    let vectors = await Self.embedSubBatchWithFallback(
                        subBatch,
                        embeddingsPool: pool,
                        embedder: singleEmbedder,
                        cancelBox: flag,
                        expectedDimension: dim
                    )
                    return (range, vectors)
                }
            }
            while let (range, vectors) = await group.next() {
                for (idx, vec) in zip(range, vectors) {
                    allVectors[idx] = vec
                }
            }
        }
        return allVectors
    }

    /// Embeds a single sub-batch, falling back to per-chunk embedding if the multi-chunk request fails.
    private static func embedSubBatchWithFallback(
        _ subBatch: [String],
        embeddingsPool: EmbeddingsBackendPool?,
        embedder: any EmbeddingsBackend?,
        cancelBox: IndexCancellationFlag,
        expectedDimension: Int?
    ) async -> [[Float]] {
        if let validated = await embedSingleSubBatch(
            subBatch,
            embeddingsPool: embeddingsPool,
            embedder: embedder,
            cancelBox: cancelBox,
            expectedDimension: expectedDimension
        ) {
            return validated
        }
        if cancelBox.isSet || Task.isCancelled {
            return Array(repeating: [], count: subBatch.count)
        }
        if subBatch.count > 1 {
            var singleVectors: [[Float]] = []
            singleVectors.reserveCapacity(subBatch.count)
            for singleText in subBatch {
                if cancelBox.isSet || Task.isCancelled {
                    singleVectors.append([])
                    continue
                }
                if let singleVec = await embedSingleSubBatch(
                    [singleText],
                    embeddingsPool: embeddingsPool,
                    embedder: embedder,
                    cancelBox: cancelBox,
                    expectedDimension: expectedDimension
                ), let first = singleVec.first {
                    singleVectors.append(first)
                } else {
                    singleVectors.append([])
                }
            }
            return singleVectors
        }
        return Array(repeating: [], count: subBatch.count)
    }

    /// Invokes the embeddings pool or backend for a single sub-batch of texts.
    private static func embedSingleSubBatch(
        _ subBatch: [String],
        embeddingsPool: EmbeddingsBackendPool?,
        embedder: any EmbeddingsBackend?,
        cancelBox: IndexCancellationFlag,
        expectedDimension: Int?
    ) async -> [[Float]]? {
        do {
            let rawVectors: [[Float]]
            if let embeddingsPool {
                rawVectors = try await embeddingsPool.withBackend { backend in
                    try await backend.embed(subBatch)
                }
            } else if let embedder {
                rawVectors = try await embedder.embed(subBatch)
            } else {
                return nil
            }
            return validatedEmbedVectors(
                rawVectors,
                expectedCount: subBatch.count,
                expectedDimension: expectedDimension
            )
        } catch is CancellationError {
            cancelBox.set()
            return nil
        } catch {
            RuneWeaverLog.stores.error("FilesIndexer: Batched embedding failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Fallback per-document commit used only if a batched SQLite transaction fails, isolating the
    /// failing document without losing the rest of the batch.
    private func commitStagedBatchIndividually(
        _ currentBatch: [StagedCandidate],
        entries: [DocBatchUpsertEntry],
        resolvedVectorsByIndex: [Int: [[Float]]],
        budget: FileIndexBudget,
        start: ContinuousClock.Instant,
        counters: inout Counters
    ) async {
        for (index, item) in currentBatch.enumerated() {
            let entry = entries[index]
            let chunks = entry.chunks
            let vectors = item.precomputedVectors ?? resolvedVectorsByIndex[index]
            do {
                _ = try await store.upsertDocumentWithChunks(
                    document: entry.document,
                    chunks: chunks,
                    runID: item.identity.runID
                )
                let truncated = Self.isVectorTruncated(
                    vectors: vectors,
                    chunkCount: item.extraction.chunks.count,
                    cap: config.maxVectorChunksPerDocument
                )
                let outcome = FileOutcome(
                    kind: .indexed(
                        chunks: chunks.count,
                        vectors: chunks.reduce(0) { $0 + ($1.isVector ? 1 : 0) },
                        truncated: truncated
                    ),
                    relative: item.resolved.relative,
                    lane: item.identity.lane,
                    preScanned: true
                )
                await foldOutcome(outcome, counters: &counters, start: start)
            } catch is CancellationError {
                await budget.release()
                isCancelled = true
                cancelBox.set()
            } catch {
                await budget.release()
                let stamp = await Self.stampCandidate(
                    store: store,
                    canonicalPath: item.resolved.canonicalPath,
                    runID: item.identity.runID
                )
                var failed = Self.stamped(
                    stamp,
                    onto: Self.failedOutcome(relative: item.resolved.relative, reason: "store write failed")
                )
                failed.lane = item.identity.lane
                failed.preScanned = true
                await foldOutcome(failed, counters: &counters, start: start)
            }
        }
    }

    /// Flushes buffered unchanged file paths in a single `markSeenBatch` SQLite transaction.
    func flushPendingSeenPaths(
        _ paths: inout [String],
        runID: String,
        counters: inout Counters
    ) async {
        guard !paths.isEmpty else { return }
        let batch = paths
        paths.removeAll(keepingCapacity: true)
        do {
            try await store.markSeenBatch(source: .files, externalIDs: batch, runID: runID)
        } catch is CancellationError {
            isCancelled = true
            cancelBox.set()
        } catch {
            counters.stampFailed = true
        }
    }
}

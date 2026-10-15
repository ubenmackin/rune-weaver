// Rune Weaver Core — Sequential file walk and indexing for the document index.
//
// Enumerates roots sequentially, evaluates pruning rules and iCloud eviction,
// checks fingerprints and content hashes, extracts text, embeds chunks, and
// persists document records to the store.

import Foundation

extension FilesIndexer {
    /// Walks one root, pruning excluded and symlinked directories in place.
    /// - Parameters:
    ///   - root: Raw configured root.
    ///   - start: Instant the run began.
    ///   - counters: Cumulative run counters.
    func indexRoot(_ root: String, start: ContinuousClock.Instant, counters: inout Counters) async {
        let rootURL = resolvedRootURL(root)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory)
        // A missing root means the walk never saw part of the corpus: retiring
        // against that partial view would delete live documents, so the run is
        // marked unreadable and the reconcile stays skipped.
        guard exists else {
            if Self.isOptionalCloudRoot(rootURL: rootURL, rawRoot: root) {
                return
            }
            counters.hasUnreadableRoot = true
            return
        }
        guard isDirectory.boolValue else {
            if isSequentialThermalHaltRequested() {
                noteSequentialThermalHalt(counters: &counters)
                return
            }
            await indexFile(rootURL, root: rootURL, start: start, counters: &counters)
            return
        }
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Self.entryKeys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            counters.hasUnreadableRoot = true
            return
        }
        while let element = enumerator.nextObject() {
            if isSequentialThermalHaltRequested() {
                // Halt before the next file so in-flight work drains within
                // one file and the reconcile stays skipped.
                noteSequentialThermalHalt(counters: &counters)
                return
            }
            if shouldStop(counters) {
                // Cancellation is reported separately; only a spent budget
                // marks the walk as stopped early so the reconcile can tell a
                // complete walk from a truncated one.
                if !isCancelled, !cancelBox.isSet, !Task.isCancelled, counters.budgetRemaining <= 0 {
                    counters.budgetStoppedEarly = true
                }
                return
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
            await indexFile(resolved, root: rootURL, start: start, counters: &counters)
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
        // Cooperative stop between files: a cancel arriving while the
        // previous file committed must not start another file's I/O.
        if isCancelled || cancelBox.isSet || Task.isCancelled {
            isCancelled = true
            cancelBox.set()
            return
        }
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
        if values.isSymbolicLink == true || values.isAliasFile == true || filename.hasPrefix("._") {
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
            // The file exists and is in policy; stamping keeps a previously
            // indexed row alive so eviction alone never retires it.
            await stampSeen(canonicalPath, counters: &counters)
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
        if await checkFingerprintCurrent(
            canonicalPath: canonicalPath,
            size: size,
            values: values,
            relative: relative,
            start: start,
            counters: &counters
        ) {
            return
        }
        guard let data = await readCandidateData(
            resolvedPath: decision.resolvedPath,
            canonicalPath: canonicalPath,
            relative: relative,
            start: start,
            counters: &counters
        ) else {
            return
        }
        guard data.count <= maxFileBytes else {
            counters.skipped += 1
            await reportWork(relative, counters: counters, start: start)
            return
        }

        let hash = Self.contentHash(for: data)
        guard await checkContentNeedsReindex(
            canonicalPath: canonicalPath,
            hash: hash,
            relative: relative,
            start: start,
            counters: &counters
        ) else {
            return
        }

        let extraction = await extractor.extract(fileURL: canonicalURL, contentType: nil)
        switch extraction.status {
        case .unsupported:
            counters.skipped += 1
            await reportWork(relative, counters: counters, start: start)
            return
        case .failed:
            await stampSeen(canonicalPath, counters: &counters)
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

    /// Fast-path check: probes whether a file's fingerprint matches what is already stored.
    private func checkFingerprintCurrent(
        canonicalPath: String,
        size: Int,
        values: URLResourceValues,
        relative: String,
        start: ContinuousClock.Instant,
        counters: inout Counters
    ) async -> Bool {
        // A cancel observed between files must win over the fast path so a
        // fingerprint hit never masks a pending stop.
        if isCancelled || cancelBox.isSet || Task.isCancelled {
            isCancelled = true
            cancelBox.set()
            return true
        }
        do {
            if let fingerprint = try await store.storedFingerprint(source: .files, externalID: canonicalPath),
               Self.fingerprintMatchesStored(fingerprint, size: size, currentMtime: values.contentModificationDate)
            {
                // A cancel landing during the lookup still stops before the
                // file counts as unchanged, bounding overrun to one file.
                if isCancelled || cancelBox.isSet || Task.isCancelled {
                    isCancelled = true
                    cancelBox.set()
                    return true
                }
                await stampSeen(canonicalPath, counters: &counters)
                if isCancelled || cancelBox.isSet || Task.isCancelled {
                    isCancelled = true
                    cancelBox.set()
                    return true
                }
                counters.unchanged += 1
                counters.skipped += 1
                await reportWork(relative, counters: counters, start: start)
                return true
            }
        } catch is CancellationError {
            isCancelled = true
            cancelBox.set()
            return true
        } catch {
            // Fall through to the read path so a transient store failure
            // still reaches the hashed lookup and its normal error handling.
            RuneWeaverLog.stores.debug("FilesIndexerSequential: store lookup error, falling through: \(error.localizedDescription)")
        }
        return false
    }

    /// Reads candidate file bytes, stamping and failing on read error.
    private func readCandidateData(
        resolvedPath: String,
        canonicalPath: String,
        relative: String,
        start: ContinuousClock.Instant,
        counters: inout Counters
    ) async -> Data? {
        let data: Data
        do {
            if let fileReader {
                data = try fileReader(URL(fileURLWithPath: resolvedPath))
            } else {
                data = try Data(contentsOf: URL(fileURLWithPath: resolvedPath), options: [.mappedIfSafe])
            }
        } catch is CancellationError {
            isCancelled = true
            cancelBox.set()
            return nil
        } catch {
            // The file was visited in policy but its bytes could not be read:
            // stamp first so the prior row (when any) survives the reconcile.
            await stampSeen(canonicalPath, counters: &counters)
            await fail(relative, counters: &counters, start: start, reason: "unreadable")
            return nil
        }
        return data
    }

    /// Checks whether the file's content hash requires re-indexing.
    private func checkContentNeedsReindex(
        canonicalPath: String,
        hash: String,
        relative: String,
        start: ContinuousClock.Instant,
        counters: inout Counters
    ) async -> Bool {
        if isCancelled || cancelBox.isSet || Task.isCancelled {
            isCancelled = true
            cancelBox.set()
            return false
        }
        do {
            let needsReindex = try await store.needsReindex(source: .files, externalID: canonicalPath, contentHash: hash)
            guard needsReindex else {
                if isCancelled || cancelBox.isSet || Task.isCancelled {
                    isCancelled = true
                    cancelBox.set()
                    return false
                }
                await stampSeen(canonicalPath, counters: &counters)
                if isCancelled || cancelBox.isSet || Task.isCancelled {
                    isCancelled = true
                    cancelBox.set()
                    return false
                }
                counters.unchanged += 1
                counters.skipped += 1
                await reportWork(relative, counters: counters, start: start)
                return false
            }
            if isCancelled || cancelBox.isSet || Task.isCancelled {
                isCancelled = true
                cancelBox.set()
                return false
            }
            return true
        } catch is CancellationError {
            isCancelled = true
            cancelBox.set()
            return false
        } catch {
            await stampSeen(canonicalPath, counters: &counters)
            await fail(relative, counters: &counters, start: start, reason: "store lookup failed")
            return false
        }
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
        let visualSucceeded: Bool
        // OCR-empty images stay interim (`.partial`, visual pending) yet must
        // still reach the visual path, so images bypass the status gate while
        // keeping the byte bound; other formats follow the shared policy.
        let shouldAttemptVectors: Bool = if pending.extraction.format == .image {
            vectorPolicy.enabled && pending.byteCount <= vectorPolicy.maxBytes
        } else {
            vectorPolicy.shouldEmbed(status: pending.extraction.status, byteCount: pending.byteCount)
        }
        if shouldAttemptVectors,
           embedder != nil || embeddingsPool != nil
        {
            let fileURL = URL(fileURLWithPath: pending.canonicalPath)
            let embedded = await embedChunksResolvingPool(of: pending.extraction, fileURL: fileURL, fileName: filename)
            vectors = embedded.vectors
            visualSucceeded = embedded.visualSucceeded
            // Honor cancellation per embedding batch: a cancelled batch stops
            // before its document commits, bounding overrun to one file.
            if isCancelled || cancelBox.isSet || Task.isCancelled {
                isCancelled = true
                cancelBox.set()
                return
            }
        } else {
            vectors = nil
            visualSucceeded = false
        }
        // Keyword-only files still honor a stop between files so a cancel
        // arriving during hashing or extraction never commits another row.
        if isCancelled || cancelBox.isSet || Task.isCancelled {
            isCancelled = true
            cancelBox.set()
            return
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
            extractStatus: Self.effectiveImageStatus(extraction: pending.extraction, visualSucceeded: visualSucceeded),
            indexedAt: Date()
        )
        let written: [IndexedChunk]
        // Chunks bind the fresh identifier up front; the atomic commit remaps
        // them onto the stable row when the path was already indexed.
        let chunks = Self.makeChunks(
            extraction: pending.extraction,
            documentID: document.id,
            vectors: vectors,
            fallbackDisplayName: filename,
            fallbackPath: relative
        )
        do {
            _ = try await store.upsertDocumentWithChunks(
                document: document,
                chunks: chunks,
                runID: counters.runID
            )
            written = chunks
        } catch is CancellationError {
            isCancelled = true
            cancelBox.set()
            return
        } catch {
            // The write failed but the file was visited in policy: stamp the
            // prior row (when any) so a transient failure never retires it.
            await stampSeen(pending.canonicalPath, counters: &counters)
            await fail(relative, counters: &counters, start: start, reason: "store write failed")
            return
        }
        counters.indexed += 1
        counters.chunks += written.count
        counters.vectors += written.reduce(0) { $0 + ($1.isVector ? 1 : 0) }
        if Self.isVectorTruncated(
            vectors: vectors,
            chunkCount: pending.extraction.chunks.count,
            cap: config.maxVectorChunksPerDocument
        ) {
            counters.truncated += 1
        }
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
        counters.warnings.append(Self.skipWarningText(relative: relative, reason: reason))
        await reportWork(relative, counters: counters, start: start)
    }

    /// Stamps one visited file as seen by the current run.
    ///
    /// Best-effort: a store failure marks the run so the end-of-run reconcile
    /// stays skipped rather than retiring live rows against a partial stamp
    /// set. Cancellation propagates through the shared flag.
    /// - Parameters:
    ///   - canonicalPath: Stable external identifier.
    ///   - counters: Cumulative run counters.
    func stampSeen(_ canonicalPath: String, counters: inout Counters) async {
        do {
            try await store.markSeen(source: .files, externalID: canonicalPath, runID: counters.runID)
        } catch is CancellationError {
            isCancelled = true
            cancelBox.set()
        } catch {
            counters.stampFailed = true
        }
    }

    /// Embeds a document's chunks, degrading to keyword-only on any failure.
    ///
    /// Cancellation propagates instead of degrading: a cancelled run should
    /// stop rather than silently keep spending embedding work. A width or count
    /// mismatch is treated as a backend failure so a partial vector list never
    /// pairs the wrong vector with a chunk. The probe runs before the batch so
    /// a cancel observed between files never starts another embedding batch.
    /// Only the first `max_vector_chunks_per_document` chunks are sent for
    /// embedding; the remainder keep an empty embedding through `makeChunks`
    /// so they stay fully keyword-searchable.
    /// - Parameters:
    ///   - extraction: Extracted document body.
    ///   - embedder: Backend to consult.
    /// - Returns: Vectors plus whether the visual multimodal path produced them.
    func embedChunks(
        of extraction: DocumentExtraction,
        fileURL: URL,
        fileName: String,
        embedder: any EmbeddingsBackend
    ) async -> (vectors: [[Float]]?, visualSucceeded: Bool) {
        guard !extraction.chunks.isEmpty else { return (nil, false) }
        if isCancelled || cancelBox.isSet || Task.isCancelled {
            isCancelled = true
            cancelBox.set()
            return (nil, false)
        }

        if extraction.format == .image {
            let dim = await embedder.dimension
            do {
                if let visual = try await Self.embedImageVisualVector(
                    fileURL: fileURL,
                    fileName: fileName,
                    expectedDimension: dim,
                    embedImage: { try await embedder.embedImage(at: fileURL) }
                ) {
                    return (visual, true)
                }
            } catch is CancellationError {
                isCancelled = true
                cancelBox.set()
                return (nil, false)
            } catch {
                // Handled in embedImageVisualVector
            }
        }

        do {
            let texts = FilesVectorPolicy.cappedEmbeddingTexts(
                extraction.chunks.map { chunk in
                    EmbeddingGemmaPrompts.document(title: fileName, text: chunk.text)
                },
                cap: config.maxVectorChunksPerDocument
            )
            let vectors = try await embedder.embed(texts)
            // A cancel arriving mid-batch still stops before commit.
            if isCancelled || cancelBox.isSet || Task.isCancelled {
                isCancelled = true
                cancelBox.set()
                return (nil, false)
            }
            let dim = await embedder.dimension
            return (Self.validatedEmbedVectors(vectors, expectedCount: texts.count, expectedDimension: dim), false)
        } catch is CancellationError {
            isCancelled = true
            cancelBox.set()
            return (nil, false)
        } catch {
            RuneWeaverLog.stores.error("FilesIndexer: Failed to generate embeddings: \(error.localizedDescription)")
            return (nil, false)
        }
    }

    /// Embeds a document's chunks preferring the pooled backend when present.
    func embedChunksResolvingPool(
        of extraction: DocumentExtraction,
        fileURL: URL,
        fileName: String
    ) async -> (vectors: [[Float]]?, visualSucceeded: Bool) {
        if let pool = embeddingsPool {
            guard !extraction.chunks.isEmpty else { return (nil, false) }
            if isCancelled || cancelBox.isSet || Task.isCancelled {
                isCancelled = true
                cancelBox.set()
                return (nil, false)
            }

            if extraction.format == .image {
                let dim = try? await pool.withBackend { await $0.dimension }
                do {
                    if let visual = try await Self.embedImageVisualVector(
                        fileURL: fileURL,
                        fileName: fileName,
                        expectedDimension: dim,
                        embedImage: { try await pool.embedImage(at: fileURL) }
                    ) {
                        return (visual, true)
                    }
                } catch is CancellationError {
                    isCancelled = true
                    cancelBox.set()
                    return (nil, false)
                } catch {
                    // Handled in embedImageVisualVector
                }
            }

            do {
                let texts = FilesVectorPolicy.cappedEmbeddingTexts(
                    extraction.chunks.map { chunk in
                        EmbeddingGemmaPrompts.document(title: fileName, text: chunk.text)
                    },
                    cap: config.maxVectorChunksPerDocument
                )
                let dim = try? await pool.withBackend { await $0.dimension }
                let vectors = try await pool.withBackend { backend in
                    try await backend.embed(texts)
                }
                if isCancelled || cancelBox.isSet || Task.isCancelled {
                    isCancelled = true
                    cancelBox.set()
                    return (nil, false)
                }
                return (Self.validatedEmbedVectors(vectors, expectedCount: texts.count, expectedDimension: dim), false)
            } catch is CancellationError {
                isCancelled = true
                cancelBox.set()
                return (nil, false)
            } catch {
                RuneWeaverLog.stores.error("FilesIndexer: Failed to generate embeddings from pool: \(error.localizedDescription)")
                return (nil, false)
            }
        }
        guard let embedder else { return (nil, false) }
        return await embedChunks(of: extraction, fileURL: fileURL, fileName: fileName, embedder: embedder)
    }
}

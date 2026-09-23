// Rune Weaver Core — Concrete index source stages for the coordinator.
//
// Builds the files, mail, Messages, and vision stages the `IndexCoordinator`
// sequences in canonical run order. Each factory adapts its concrete indexer
// into an `IndexClosureStage` so the coordinator stays transport-agnostic and
// cancellation reaches the in-flight files indexer through a small actor box.

import Foundation

public extension IndexClosureStage {
    /// Builds the files stage over the shared document store.
    ///
    /// The `FilesIndexer` binds its progress sink at construction, so a fresh
    /// indexer is built per run against the coordinator's reporter and kept in a
    /// small actor box so cancellation can reach it.
    /// - Parameters:
    ///   - config: Index policy for the file walk.
    ///   - store: Document store the run writes into.
    ///   - extractor: Text extractor for candidate files.
    ///   - embedder: Embeddings backend, or nil for keyword-only.
    ///   - accessGuard: Path policy consulted before opening a candidate.
    ///   - vectorPolicy: Which extracted documents are vectorized.
    ///   - homeDirectoryURL: Home boundary override, or nil for the real home.
    ///   - nowProvider: Monotonic instant source for the walk.
    /// - Returns: A files source stage.
    static func files(
        config: IndexConfig,
        store: DocIndexStore,
        extractor: any DocumentTextExtracting = DocumentTextExtractor(),
        embedder: (any EmbeddingsBackend)? = nil,
        accessGuard: any FilesIndexAccessGuard,
        vectorPolicy: FilesVectorPolicy = FilesVectorPolicy(),
        homeDirectoryURL: URL? = nil,
        nowProvider: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now }
    ) -> IndexClosureStage {
        let box = FilesIndexerCancelBox()
        return IndexClosureStage(
            kind: .files,
            isEnabled: config.enabled && config.files,
            onCancel: { await box.cancel() },
            body: { reporter, _ in
                let indexer = FilesIndexer(
                    store: store,
                    extractor: extractor,
                    embedder: embedder,
                    accessGuard: accessGuard,
                    vectorPolicy: vectorPolicy,
                    config: config,
                    homeDirectoryURL: homeDirectoryURL,
                    nowProvider: nowProvider,
                    progress: reporter
                )
                await box.set(indexer)
                let report = await indexer.run()
                await box.clear()
                return IndexSourceRunReport(
                    kind: .files,
                    scanned: report.filesScanned,
                    indexed: report.filesIndexed,
                    vectorChunks: report.vectorsWritten,
                    keywordChunks: max(report.chunksWritten - report.vectorsWritten, 0),
                    skipped: report.filesSkipped + report.filesUnchanged,
                    errors: report.errors,
                    didRun: report.didRun,
                    skippedReason: report.skippedReason,
                    warnings: report.warnings
                )
            }
        )
    }

    /// Builds the mail stage over the shared document store.
    /// - Parameters:
    ///   - config: Index policy for mail.
    ///   - emailConfig: Configured mail accounts.
    ///   - gateway: Read-only IMAP gateway seam.
    ///   - store: Document store the run writes into.
    ///   - embedder: Optional embeddings backend for vector-eligible mail.
    ///   - extractor: Text extractor shared with the rest of the pipeline.
    ///   - checkpoints: Incremental watermark and dedupe store.
    ///   - stagingRoot: Test-injectable staging root; nil uses confined temp.
    ///   - secrets: Secrets manager resolving account passwords.
    ///   - now: Clock seam for the vector window.
    /// - Returns: A mail source stage.
    static func mail(
        config: IndexConfig,
        emailConfig: EmailConfig,
        gateway: any MailIndexGateway,
        store: DocIndexStore,
        embedder: (any EmbeddingsBackend)? = nil,
        extractor: any DocumentTextExtracting = DocumentTextExtractor(),
        checkpoints: MailIndexCheckpointStore = MailIndexCheckpointStore(),
        stagingRoot: URL? = nil,
        secrets: SecretsManager = SecretsManager(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> IndexClosureStage {
        IndexClosureStage(kind: .mail, isEnabled: config.enabled && config.mail) { reporter, _ in
            let indexer = MailIndexer(
                emailConfig: emailConfig,
                indexConfig: config,
                gateway: gateway,
                store: store,
                embedder: embedder,
                extractor: extractor,
                checkpoints: checkpoints,
                stagingRoot: stagingRoot,
                now: now,
                secrets: secrets
            )
            let report = try await indexer.run(reporter: reporter)
            return IndexSourceRunReport(
                kind: .mail,
                scanned: report.messagesSeen,
                indexed: report.messagesIndexed,
                vectorChunks: report.vectorsWritten,
                keywordChunks: max(report.chunksWritten - report.vectorsWritten, 0),
                skipped: report.messagesUnchanged + report.messagesDeduplicated,
                errors: report.warnings.count,
                didRun: report.didRun,
                skippedReason: report.skippedReason,
                warnings: report.warnings
            )
        }
    }

    /// Builds the Apple Messages stage over the shared document store.
    /// - Parameters:
    ///   - config: Index policy for Messages.
    ///   - store: Document store the run writes into.
    ///   - chatDatabasePath: Live chat database path.
    ///   - extractor: Text extractor for attachment bodies.
    ///   - contacts: Opportunistic handle-to-name resolver.
    ///   - statePath: Persisted watermark file.
    ///   - batchLimit: Maximum messages read per pass.
    /// - Returns: A Messages source stage.
    static func messages(
        config: IndexConfig,
        store: DocIndexStore,
        chatDatabasePath: String = MessagesIndexer.defaultChatDatabasePath,
        extractor: any DocumentTextExtracting = DocumentTextExtractor(),
        contacts: any MessagesContactResolving = MessagesContactNameResolver(),
        statePath: String = MessagesIndexer.defaultStatePath,
        batchLimit: Int = MessagesIndexer.defaultBatchLimit
    ) -> IndexClosureStage {
        IndexClosureStage(kind: .messages, isEnabled: config.enabled && config.messages) { _, _ in
            #if canImport(SQLite3)
                let indexer = MessagesIndexer(
                    chatDatabasePath: chatDatabasePath,
                    store: store,
                    extractor: extractor,
                    contacts: contacts,
                    statePath: statePath,
                    batchLimit: batchLimit
                )
                let result = try await indexer.indexNewMessages()
                return IndexSourceRunReport(
                    kind: .messages,
                    scanned: result.scanned,
                    indexed: result.indexed,
                    skipped: max(result.scanned - result.indexed, 0),
                    lastItem: result.hasMore ? "rowid:\(result.lastRowID)" : nil
                )
            #else
                return IndexSourceRunReport(
                    kind: .messages,
                    didRun: false,
                    skippedReason: "SQLite3 is unavailable on this platform."
                )
            #endif
        }
    }

    /// Builds the opt-in vision describe stage.
    ///
    /// The document store exposes no "pending" listing, so the caller supplies
    /// the candidate documents and their image bytes; the stage runs each through
    /// ``VisionDescribeIndexer`` and folds the outcomes into a report.
    /// - Parameters:
    ///   - config: Index policy; `describeImagesWithLLM` gates the stage.
    ///   - store: Document store the descriptions are written to.
    ///   - provider: Multimodal provider that answers description requests.
    ///   - maxImageBytes: Per-file byte cap; defaults to the configured file cap.
    ///   - now: Clock seam for budget windows and provenance.
    ///   - pendingDocuments: Supplies documents eligible for description.
    ///   - imageData: Supplies original image bytes for one document.
    /// - Returns: A vision source stage.
    static func vision(
        config: IndexConfig,
        store: DocIndexStore,
        provider: any VisionDescribeProvider,
        maxImageBytes: Int? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        pendingDocuments: @escaping @Sendable () async -> [IndexedDocument],
        imageData: @escaping @Sendable (IndexedDocument) async -> Data?
    ) -> IndexClosureStage {
        IndexClosureStage(kind: .vision, isEnabled: config.enabled && config.describeImagesWithLLM) { reporter, isCancelled in
            let indexer = VisionDescribeIndexer(
                config: config,
                store: store,
                provider: provider,
                maxImageBytes: maxImageBytes,
                now: now,
                progress: reporter
            )
            var report = IndexSourceRunReport(kind: .vision)
            let documents = await pendingDocuments()
            report.scanned = documents.count
            for document in documents {
                // Honor cancellation per document so the vision pass stops
                // within one LLM turn instead of draining the pending list.
                if isCancelled() {
                    break
                }
                guard let data = await imageData(document) else {
                    report.skipped += 1
                    continue
                }
                do {
                    switch try await indexer.enrich(document: document, imageData: data) {
                    case .described:
                        report.indexed += 1
                        report.keywordChunks += 1
                    case .skipped:
                        report.skipped += 1
                    }
                } catch is CancellationError {
                    break
                } catch {
                    report.errors += 1
                    report.warnings.append("vision: \(error.localizedDescription)")
                }
                report.lastItem = document.displayName
            }
            return report
        }
    }
}

/// Actor box holding the files indexer for the current run so cancellation can
/// reach it without making the indexer itself part of the stage's value.
private actor FilesIndexerCancelBox {
    /// Files indexer for the run in flight.
    private var indexer: FilesIndexer?

    /// Publishes the indexer for the current run.
    /// - Parameter indexer: Indexer that is about to run.
    func set(_ indexer: FilesIndexer) {
        self.indexer = indexer
    }

    /// Clears the indexer once the run returns.
    func clear() {
        indexer = nil
    }

    /// Requests cancellation of the in-flight indexer.
    func cancel() async {
        await indexer?.cancel()
    }
}

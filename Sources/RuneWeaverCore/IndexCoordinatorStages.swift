// Rune Weaver Core — Concrete index source stages for the coordinator.

import Foundation

extension IndexClosureStage {
    /// Builds the files stage over the shared document store. The `isEnabled` flag captured at
    /// build time is diagnostics only and never gates a run.
    public static func files(
        config: IndexConfig,
        store: DocIndexStore,
        extractor: any DocumentTextExtracting = DocumentTextExtractor(),
        embedder: (any EmbeddingsBackend)? = nil,
        makeEmbeddingsBackend: (@Sendable () -> (any EmbeddingsBackend)?)? = nil,
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
            body: { policy, reporter, _ in
                // Pool sizing tracks the live run snapshot so a settings save between boots still
                // fans the next pass correctly; the shared recall embedder stays out of the pool and
                // remains the keyword fallback when the factory yields nothing.
                let workerCount = policy.resolvedWorkerCount()
                var embeddingsPool: EmbeddingsBackendPool?
                // Single-worker runs stay sequential and never consult the
                // pool, so skip minting backends to avoid paying a model-load
                // per install for an unused pool.
                if workerCount > 1, let makeEmbeddingsBackend {
                    var backends: [any EmbeddingsBackend] = []
                    backends.reserveCapacity(workerCount)
                    for _ in 0 ..< workerCount {
                        if let backend = makeEmbeddingsBackend() {
                            backends.append(backend)
                        }
                    }
                    if !backends.isEmpty {
                        embeddingsPool = EmbeddingsBackendPool(backends: backends)
                    }
                }
                let indexer = FilesIndexer(
                    store: store,
                    extractor: extractor,
                    embedder: embedder,
                    embeddingsPool: embeddingsPool,
                    accessGuard: accessGuard,
                    vectorPolicy: vectorPolicy,
                    config: policy,
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
                    retired: report.retiredCount,
                    truncated: report.truncatedVectorDocuments,
                    didRun: report.didRun,
                    skippedReason: report.skippedReason,
                    warnings: report.warnings
                )
            }
        )
    }

    /// Builds the mail stage over the shared document store. config: Index policy
    /// snapshot used only for boot-time selection.
    public static func mail(
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
        IndexClosureStage(kind: .mail, isEnabled: config.enabled && config.mail) { policy, reporter, _ in
            let indexer = MailIndexer(
                emailConfig: emailConfig,
                indexConfig: policy,
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
                skipped: report.messagesUnchanged + report.messagesDeduplicated + report.mailboxesSkipped,
                errors: report.warnings.count,
                retired: report.retiredCount,
                didRun: report.didRun,
                skippedReason: report.skippedReason,
                warnings: report.warnings
            )
        }
    }

    /// Builds the Apple Messages stage over the shared document store. The body guard below remains
    /// only as defense for direct indexer use outside the coordinator.
    public static func messages(
        config: IndexConfig,
        store: DocIndexStore,
        chatDatabasePath: String = MessagesIndexer.defaultChatDatabasePath,
        extractor: any DocumentTextExtracting = DocumentTextExtractor(),
        contacts: any MessagesContactResolving = MessagesContactNameResolver(),
        embedder: (any EmbeddingsBackend)? = nil,
        statePath: String = MessagesIndexer.defaultStatePath,
        batchLimit: Int = MessagesIndexer.defaultBatchLimit
    ) -> IndexClosureStage {
        IndexClosureStage(kind: .messages, isEnabled: config.enabled && config.messages) { policy, reporter, _ in
            // Live selection is filtered by the coordinator before the body runs, so a live enable
            // runs on the next pass and a live disable never reaches here; the guard below remains
            // only as defense for direct indexer use outside the coordinator.
            guard policy.enabled, policy.messages else {
                return IndexSourceRunReport(
                    kind: .messages,
                    didRun: false,
                    skippedReason: "Messages indexing is disabled in [index]."
                )
            }
            #if canImport(SQLite3)
                let indexer = MessagesIndexer(
                    chatDatabasePath: chatDatabasePath,
                    store: store,
                    extractor: extractor,
                    contacts: contacts,
                    embedder: embedder,
                    statePath: statePath,
                    batchLimit: batchLimit
                )
                // The looping entry snapshots once and drains every pending batch, so the stage
                // folds its accumulated totals straight into the report while per-batch memory stays
                // bounded.
                let result = try await indexer.indexAllNewMessages(reporter: reporter)
                return IndexSourceRunReport(
                    kind: .messages,
                    scanned: result.scanned,
                    indexed: result.indexed,
                    vectorChunks: result.vectorChunks,
                    keywordChunks: max(result.indexed - result.vectorChunks, 0),
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

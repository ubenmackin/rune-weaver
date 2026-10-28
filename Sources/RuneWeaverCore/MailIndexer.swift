// Rune Weaver Core — Incremental mail indexer feeding the local document index.

import CryptoKit
import Dispatch
import Foundation

// MARK: - Indexer

/// Actor-isolated mail indexer over an injected read-only gateway seam.
public actor MailIndexer {
    /// Newest-message page size fetched per gateway call. One call stays bounded by the bridge page
    /// cap while fixed UID windows tile downward until they reach the watermark.
    public static let pageLimit = 50

    /// Maximum fetch attempts per mailbox before skipping with a warning. The first failure of a
    /// retryable transport error backs off and retries; the terminal failure warns once with an
    /// attempt suffix.
    public static let maxFetchAttempts = 3

    /// Backoff delays in seconds between fetch attempts.
    public static let fetchRetryDelaysSeconds: [TimeInterval] = [2, 8]

    /// Steady pause in seconds between gateway page calls.
    public static let interPagePauseSeconds: TimeInterval = 1.0

    /// Configured mail accounts.
    let emailConfig: EmailConfig
    /// Index policy: enablement, source toggles, caps, budget, and vector window.
    let indexConfig: IndexConfig
    /// Read-only gateway seam.
    let gateway: any MailIndexGateway
    /// Document store the index writes into.
    let store: DocIndexStore
    /// Optional embeddings backend for vector-eligible chunks.
    let embedder: any EmbeddingsBackend?
    /// Text extractor shared with the rest of the index pipeline.
    let extractor: any DocumentTextExtracting
    /// Incremental watermark and dedupe checkpoint store.
    let checkpoints: MailIndexCheckpointStore
    /// Test-injectable staging root; nil uses Seatbelt-confined temp.
    let stagingRoot: URL?
    /// Clock seam so tests can pin the vector-window reference time.
    let now: @Sendable () -> Date
    /// Secrets manager used to resolve account passwords at execution time.
    let secrets: SecretsManager

    /// Creates a mail indexer. emailConfig: Configured mail accounts.
    public init(
        emailConfig: EmailConfig,
        indexConfig: IndexConfig,
        gateway: any MailIndexGateway,
        store: DocIndexStore,
        embedder: any EmbeddingsBackend? = nil,
        extractor: any DocumentTextExtracting = DocumentTextExtractor(),
        checkpoints: MailIndexCheckpointStore = MailIndexCheckpointStore(),
        stagingRoot: URL? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        secrets: SecretsManager = SecretsManager()
    ) {
        self.emailConfig = emailConfig
        self.indexConfig = indexConfig
        self.gateway = gateway
        self.store = store
        self.embedder = embedder
        self.extractor = extractor
        self.checkpoints = checkpoints
        self.stagingRoot = stagingRoot
        self.now = now
        self.secrets = secrets
    }

    /// Runs one incremental indexing pass.
    /// - Parameter reporter: Sink for advisory progress; defaults to a no-op.
    public func run(reporter: ToolProgressReporter = ToolContext.noProgress) async throws -> MailIndexRunReport {
        guard indexConfig.enabled, indexConfig.mail else {
            return MailIndexRunReport(skippedReason: "Mail indexing is disabled in [index].")
        }
        if let embedder, let dim = await embedder.dimension {
            _ = try? await store.ensureEmbeddingDimensionMatch(
                activeModelID: embedder.modelID,
                activeDimension: dim,
                mailCheckpointPath: MailIndexCheckpointStore.defaultPath,
                messagesStatePath: MessagesIndexer.defaultStatePath
            )
        }
        let runDate = now()
        let window = MailVectorWindow(token: indexConfig.mailVectorWindow)
        let attachmentCap = max(1, indexConfig.maxFileMB) * 1_048_576
        var cursor = MailRunCursor(
            report: MailIndexRunReport(),
            budget: indexConfig.nightlyBudget > 0 ? indexConfig.nightlyBudget : Int.max,
            lastReport: DispatchTime.now().uptimeNanoseconds
        )

        var deniedObserved = Set<String>()
        for account in emailConfig.accounts {
            try Task.checkCancellation()
            guard cursor.budget > 0 else { break }
            guard let credentials = await resolvedCredentials(for: account) else {
                cursor.report.warnings.append(
                    "Skipped account '\(account.name)': no password resolved from the environment or Keychain."
                )
                continue
            }
            cursor.report.accountsScanned += 1
            let mailboxes: [String]
            do {
                mailboxes = try await gateway.mailboxes(credentials: credentials)
            } catch let cancel as CancellationError {
                throw cancel
            } catch {
                cursor.report.warnings.append("Skipped account '\(account.name)': \(error.localizedDescription)")
                continue
            }
            for mailbox in mailboxes {
                try Task.checkCancellation()
                guard cursor.budget > 0 else { break }
                // The mail run gate owns Trash-class matching: a denied mailbox skips before any
                // STATUS or fetch dial so transient deletes never cost a round trip, counting only
                // as skipped with no warning.
                if Self.isMailboxDenied(mailbox, patterns: indexConfig.mailboxDeny) {
                    cursor.report.mailboxesScanned += 1
                    cursor.report.mailboxesSkipped += 1
                    deniedObserved.insert(mailbox)
                    continue
                }
                // The context stores the trimmed spelling so the pooled session, checkpoint
                // watermark, stored document mailbox, and document identity all agree; the shared
                // mailbox key and document identity both trim, so trimming once here keeps one.
                let context = MailboxContext(
                    account: account,
                    mailbox: mailbox.trimmingCharacters(in: .whitespacesAndNewlines),
                    credentials: credentials,
                    window: window,
                    runDate: runDate,
                    attachmentCap: attachmentCap
                )
                do {
                    try await indexMailbox(context: context, cursor: &cursor, reporter: reporter)
                } catch let cancel as CancellationError {
                    throw cancel
                } catch {
                    // One broken mailbox must not abort the pass: the fresh path never
                    // advanced its watermark, so the next run retries the failed page.
                    cursor.report.warnings.append(
                        "Skipped mailbox '\(context.account.name)/\(context.mailbox)': \(error.localizedDescription)"
                    )
                    continue
                }
            }
        }
        // Retire on complete runs only: a cancelled pass, a budget-capped pass, or a halted pass
        // never deletes what it never examined.
        if !deniedObserved.isEmpty, !Task.isCancelled {
            let budgetExhausted = indexConfig.nightlyBudget > 0 && cursor.budget <= 0
            if !budgetExhausted {
                let retired = await retireDeniedMailboxes(deniedObserved)
                cursor.report.retiredCount += retired
            }
        }
        await reporter(ToolProgress(
            message: "Mail indexing finished: \(cursor.report.messagesIndexed) indexed, \(cursor.report.messagesSeen) scanned",
            scanned: cursor.report.messagesSeen,
            matched: cursor.report.messagesIndexed
        ))
        return cursor.report
    }

    /// Mutable per-run budget, progress throttle, and report bundle.
    struct MailRunCursor: Sendable {
        /// Counts accumulated across mailboxes.
        var report: MailIndexRunReport
        /// Remaining items before the nightly cap stops the run.
        var budget: Int
        /// Last progress emission for throttling.
        var lastReport: UInt64
    }

    /// One mailbox window ready for per-message indexing.
    struct MailboxBatch: Sendable {
        /// Per-mailbox indexing context.
        var context: MailboxContext
        /// Sorted messages above the watermark.
        var fresh: [MailIndexMessage]
        /// Watermark observed before the fetch.
        var watermark: Int
        /// Whether the watermark is held over an unfetched gap.
        var holdsWatermark: Bool
    }

    /// Indexes one mailbox window, advancing the watermark only past considered messages.
    private func indexMailbox(
        context: MailboxContext,
        cursor: inout MailRunCursor,
        reporter: ToolProgressReporter
    ) async throws {
        cursor.report.mailboxesScanned += 1
        var watermark = await checkpoints.watermark(account: context.account.name, mailbox: context.mailbox)
        // The mailbox loop owns fetch-phase liveness: an entering frame keeps
        // a long IMAP stretch visible before the first page returns. Only the
        // account-qualified mailbox enters the frame; no subject or body ever does.
        await reporter(ToolProgress(
            message: "Indexing mail: \(cursor.report.messagesIndexed) indexed, \(cursor.report.messagesSeen) scanned",
            scanned: cursor.report.messagesSeen,
            matched: cursor.report.messagesIndexed,
            current: "\(context.account.name) - \(context.mailbox)"
        ))
        // The named owner for the open-close bracket is this method: the STATUS probe plus every
        // fetch page ride one pooled connection, with cancel, skip, plus throw all terminating it.
        do {
            try await gateway.openMailboxSession(credentials: context.credentials, mailbox: context.mailbox)
        } catch let cancel as CancellationError {
            throw cancel
        } catch {
            cursor.report.warnings.append("Skipped mailbox '\(context.account.name)/\(context.mailbox)': \(error.localizedDescription)")
            return
        }
        do {
            try await indexMailboxOpened(context: context, watermark: &watermark, cursor: &cursor, reporter: reporter)
        } catch {
            await Self.closeMailboxSessionAssumingOpen(
                gateway: gateway,
                credentials: context.credentials,
                mailbox: context.mailbox
            )
            throw error
        }
        await Self.closeMailboxSessionAssumingOpen(
            gateway: gateway,
            credentials: context.credentials,
            mailbox: context.mailbox
        )
    }

    /// Indexes one mailbox over its already-open pooled session.
    private func indexMailboxOpened(
        context: MailboxContext,
        watermark: inout Int,
        cursor: inout MailRunCursor,
        reporter: ToolProgressReporter
    ) async throws {
        // Reconcile the server validity token before paging: a mismatch means UIDs were reassigned,
        // so restart from zero while retained hashes dedupe refetches. Unknown tokens skip the check
        // without failing.
        var probedStatus: MailIndexMailboxStatus?
        do {
            probedStatus = try await gateway.mailboxStatus(credentials: context.credentials, mailbox: context.mailbox)
        } catch let cancel as CancellationError {
            throw cancel
        } catch {
            // Status is advisory; a failing probe must not skip the mailbox when the message path
            // could still succeed.
            if Self.isSkippableStatusError(error) {
                cursor.report.warnings.append("Skipped mailbox '\(context.account.name)/\(context.mailbox)': \(error.localizedDescription)")
                return
            }
            if Self.isRetryableMailError(error) {
                do {
                    try await gateway.openMailboxSession(credentials: context.credentials, mailbox: context.mailbox)
                } catch let cancel as CancellationError {
                    throw cancel
                } catch {
                    cursor.report.warnings.append("Skipped mailbox '\(context.account.name)/\(context.mailbox)': \(error.localizedDescription)")
                    return
                }
            }
            probedStatus = nil
        }
        // The checkpoint sync persists to disk, so its failure is a local store problem rather than
        // a session problem: it warns and skips without redialing, keeping a sidecar IO fault from
        // masquerading as an advisory STATUS failure.
        if let probedStatus {
            do {
                let didReset = try await checkpoints.synchronizeValidity(
                    account: context.account.name,
                    mailbox: context.mailbox,
                    uidValidity: probedStatus.uidValidity
                )
                if didReset {
                    watermark = 0
                    cursor.report.warnings.append(
                        "Mailbox '\(context.mailbox)' UIDVALIDITY changed; restarted from zero and deduplicating by content hash."
                    )
                }
            } catch let cancel as CancellationError {
                throw cancel
            } catch {
                cursor.report.warnings.append("Skipped mailbox '\(context.account.name)/\(context.mailbox)': \(error.localizedDescription)")
                return
            }
        }
        // Phase 1: Forward catch-up for new messages above the watermark.
        // Runs whenever watermark > 0 to pull only new arrivals since the previous run.
        if watermark > 0 {
            guard let (fetched, windowComplete) = try await fetchFreshWindowWithRetry(
                context: context,
                watermark: watermark,
                anchoredUidNext: probedStatus?.uidNext,
                cursor: &cursor
            ) else {
                return
            }
            let fresh = Self.freshSortedMessages(fetched, watermark: watermark)
            await reporter(ToolProgress(
                message: "Indexing mail: \(cursor.report.messagesIndexed) indexed, \(cursor.report.messagesSeen) scanned",
                scanned: cursor.report.messagesSeen,
                matched: cursor.report.messagesIndexed,
                current: "\(context.account.name) - \(context.mailbox) (\(fresh.count) new)"
            ))
            let holdsWatermark = Self.holdsWatermark(windowComplete: windowComplete, fresh: fresh, watermark: watermark)
            if holdsWatermark {
                cursor.report.warnings.append(
                    "Mailbox '\(context.mailbox)' has more new messages than the gateway's widest page; "
                        + "indexed the newest \(fresh.count) and held the watermark at \(watermark) "
                        + "so older arrivals stay pending instead of being skipped."
                )
            }
            let batch = MailboxBatch(
                context: context,
                fresh: fresh,
                watermark: watermark,
                holdsWatermark: holdsWatermark
            )
            try await indexFreshMessages(batch: batch, cursor: &cursor, reporter: reporter)
            watermark = await checkpoints.watermark(account: context.account.name, mailbox: context.mailbox)
        }

        // Phase 2: Streaming historical backfill downward below backfillFloor (or from top if watermark == 0).
        let pendingBackfillFloor = await checkpoints.backfillFloor(
            account: context.account.name,
            mailbox: context.mailbox
        )
        let needsBackfill = watermark == 0 || (pendingBackfillFloor.map { $0 > 1 } ?? false)
        if needsBackfill, cursor.budget > 0 {
            try await streamBackfill(
                context: context,
                watermark: &watermark,
                initialFloor: pendingBackfillFloor,
                anchoredUidNext: probedStatus?.uidNext,
                cursor: &cursor,
                reporter: reporter
            )
        }
    }

    /// Retries fetching fresh window up to `maxFetchAttempts`, backing off on retryable errors.
    private func fetchFreshWindowWithRetry(
        context: MailboxContext,
        watermark: Int,
        anchoredUidNext: Int?,
        cursor: inout MailRunCursor
    ) async throws -> (messages: [MailIndexMessage], complete: Bool)? {
        var attempt = 0
        var terminalTransportError: Error?
        var currentAnchor = anchoredUidNext
        while attempt < Self.maxFetchAttempts {
            attempt += 1
            do {
                return try await fetchFreshWindow(
                    credentials: context.credentials,
                    mailbox: context.mailbox,
                    watermark: watermark,
                    anchoredUidNext: currentAnchor
                )
            } catch let cancel as CancellationError {
                throw cancel
            } catch {
                guard Self.isRetryableMailError(error) else {
                    cursor.report.warnings.append("Skipped mailbox '\(context.account.name)/\(context.mailbox)': \(error.localizedDescription)")
                    return nil
                }
                if attempt >= Self.maxFetchAttempts {
                    terminalTransportError = error
                    break
                }
                let delayIndex = min(attempt - 1, Self.fetchRetryDelaysSeconds.count - 1)
                let delaySeconds = Self.fetchRetryDelaysSeconds[delayIndex]
                try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                do {
                    try await gateway.openMailboxSession(credentials: context.credentials, mailbox: context.mailbox)
                    currentAnchor = nil
                } catch let cancel as CancellationError {
                    throw cancel
                } catch {
                    cursor.report.warnings.append("Skipped mailbox '\(context.account.name)/\(context.mailbox)': \(error.localizedDescription)")
                    return nil
                }
                continue
            }
        }
        if let terminalTransportError {
            let message = "Skipped mailbox '\(context.account.name)/\(context.mailbox)': \(terminalTransportError.localizedDescription) "
                + "(after \(Self.maxFetchAttempts) attempts)"
            cursor.report.warnings.append(message)
        }
        return nil
    }

    /// Indexes one sorted mailbox window in page-sized batches, recording watermarks and progress.
    private func indexFreshMessages(
        batch: MailboxBatch,
        cursor: inout MailRunCursor,
        reporter: ToolProgressReporter
    ) async throws {
        var offset = 0
        while offset < batch.fresh.count, cursor.budget > 0 {
            try Task.checkCancellation()
            let end = min(offset + Self.pageLimit, batch.fresh.count)
            let pageSlice = Array(batch.fresh[offset ..< end])
            try await indexMailPageBatch(
                page: pageSlice,
                context: batch.context,
                watermarkMode: batch.holdsWatermark ? .fixedFresh(batch.watermark) : .advancePerUID,
                cursor: &cursor,
                reporter: reporter
            )
            offset = end
        }
    }

    /// Degrades a failed checkpoint persistence to a logged warning so one unwritable sidecar
    /// file never aborts the run; in-memory watermarks stay authoritative until the next flush.
    /// Cancellation still propagates so cooperative shutdown stays immediate.
    func degradeCheckpointWrite(_ operation: () async throws -> Void) async throws {
        do {
            try await operation()
        } catch let cancel as CancellationError {
            throw cancel
        } catch {
            RuneWeaverLog.stores.warning(
                "MailIndexer: checkpoint persist failed; run continues and the next flush retries: \(error.localizedDescription)"
            )
        }
    }
}

// MARK: - Streaming backfill

extension MailIndexer {
    /// Deletes index rows for newly denied mailboxes and drops their checkpoints. Failures degrade
    /// to a warning so a retire problem never fails an otherwise complete run.
    private func retireDeniedMailboxes(_ denied: Set<String>) async -> Int {
        do {
            let hashes: Set<String>
            do {
                hashes = try await store.mailContentHashes(mailboxes: denied)
            } catch is CancellationError {
                return 0
            } catch {
                RuneWeaverLog.stores.error("MailIndexer: failed to read content hashes for denied mailboxes: \(error.localizedDescription)")
                hashes = []
            }
            let retired = try await store.retireMailboxes(denied)
            if retired > 0 {
                do {
                    _ = try await store.reclaim()
                } catch is CancellationError {
                    return retired
                } catch {
                    RuneWeaverLog.stores.error("MailIndexer: failed to reclaim store: \(error.localizedDescription)")
                }
            }
            for account in emailConfig.accounts {
                for mailbox in denied {
                    do {
                        try await checkpoints.dropMailbox(account: account.name, mailbox: mailbox)
                    } catch is CancellationError {
                        return retired
                    } catch {
                        RuneWeaverLog.stores.error("MailIndexer: failed to drop checkpoint for \(account.name)/\(mailbox): \(error.localizedDescription)")
                    }
                }
            }
            if !hashes.isEmpty {
                do {
                    try await checkpoints.removeContentHashes(hashes)
                } catch is CancellationError {
                    return retired
                } catch {
                    RuneWeaverLog.stores.error("MailIndexer: failed to remove content hashes: \(error.localizedDescription)")
                }
            }
            return retired
        } catch is CancellationError {
            return 0
        } catch {
            RuneWeaverLog.stores.error("MailIndexer: failed to retire denied mailboxes: \(error.localizedDescription)")
            return 0
        }
    }

    /// Streams historical backfill downward page-by-page, indexing each batch immediately.
    private func streamBackfill(
        context: MailboxContext,
        watermark: inout Int,
        initialFloor: Int?,
        anchoredUidNext: Int?,
        cursor: inout MailRunCursor,
        reporter: ToolProgressReporter
    ) async throws {
        let initialWatermark = watermark
        var currentBeforeUID: Int? = initialFloor ?? anchoredUidNext
        var isFirstIteration = true
        var isInitialWindow = (initialWatermark == 0 && initialFloor == nil)
        var seenIDs = Set<String>()

        while cursor.budget > 0 {
            try Task.checkCancellation()
            if !isFirstIteration {
                try await Task.sleep(nanoseconds: UInt64(Self.interPagePauseSeconds * 1_000_000_000))
            }
            isFirstIteration = false

            guard let page = try await fetchSinglePageWithRetry(
                context: context,
                limit: Self.pageLimit,
                beforeUID: currentBeforeUID,
                cursor: &cursor
            ) else {
                return
            }

            if page.isEmpty {
                guard let next = try await handleEmptyBackfillWindow(
                    account: context.account.name,
                    mailbox: context.mailbox,
                    currentBeforeUID: currentBeforeUID
                ) else {
                    break
                }
                currentBeforeUID = next
                continue
            }

            if isInitialWindow {
                isInitialWindow = false
                await reporter(ToolProgress(
                    message: "Indexing mail: \(cursor.report.messagesIndexed) indexed, \(cursor.report.messagesSeen) scanned",
                    scanned: cursor.report.messagesSeen,
                    matched: cursor.report.messagesIndexed,
                    current: "\(context.account.name) - \(context.mailbox) (\(page.count) new)"
                ))
            }

            var advanced = false
            for message in page where seenIDs.insert(message.id).inserted {
                advanced = true
            }

            let numericUIDs = page.map { Self.uid(of: $0.id) }.filter { $0 > 0 }
            guard let lowest = numericUIDs.min() else {
                break
            }

            let isClamped = !advanced || (currentBeforeUID.map { lowest >= $0 } ?? false)
            if isClamped {
                await handleClampedGateway(
                    context: context,
                    pageCount: page.count,
                    initialWatermark: initialWatermark,
                    watermark: &watermark,
                    cursor: &cursor
                )
                break
            }

            if watermark == 0, let highest = numericUIDs.max() {
                watermark = highest
                try await degradeCheckpointWrite {
                    try await checkpoints.record(
                        account: context.account.name,
                        mailbox: context.mailbox,
                        watermark: highest,
                        contentHash: nil
                    )
                }
            }

            let sortedPage = page.sorted { Self.uid(of: $0.id) < Self.uid(of: $1.id) }
            try await indexBackfillBatch(
                page: sortedPage,
                context: context,
                watermark: watermark,
                cursor: &cursor,
                reporter: reporter
            )

            if lowest <= 1 || (page.count < Self.pageLimit && lowest <= 1) {
                try await degradeCheckpointWrite {
                    try await checkpoints.recordBackfillFloor(
                        account: context.account.name,
                        mailbox: context.mailbox,
                        floor: nil
                    )
                }
                break
            }

            currentBeforeUID = lowest
            try await degradeCheckpointWrite {
                try await checkpoints.recordBackfillFloor(
                    account: context.account.name,
                    mailbox: context.mailbox,
                    floor: lowest
                )
            }
        }
    }

    /// Handles an empty backfill window by stepping downward or completing at the mailbox start.
    private func handleEmptyBackfillWindow(
        account: String,
        mailbox: String,
        currentBeforeUID: Int?
    ) async throws -> Int? {
        guard let current = currentBeforeUID,
              let window = MailIndexTiling.window(beforeUID: current),
              window.lower > 1
        else {
            try await degradeCheckpointWrite {
                try await checkpoints.recordBackfillFloor(account: account, mailbox: mailbox, floor: nil)
            }
            return nil
        }
        try await degradeCheckpointWrite {
            try await checkpoints.recordBackfillFloor(account: account, mailbox: mailbox, floor: window.lower)
        }
        return window.lower
    }

    /// Handles a clamped gateway by reverting zero watermark and emitting an advisory warning.
    private func handleClampedGateway(
        context: MailboxContext,
        pageCount: Int,
        initialWatermark: Int,
        watermark: inout Int,
        cursor: inout MailRunCursor
    ) async {
        if initialWatermark == 0 {
            do {
                try await checkpoints.record(
                    account: context.account.name,
                    mailbox: context.mailbox,
                    watermark: initialWatermark,
                    contentHash: nil
                )
            } catch {
                RuneWeaverLog.stores.error("MailIndexer: failed to record initial checkpoint: \(error.localizedDescription)")
            }
            watermark = initialWatermark
        }
        cursor.report.warnings.append(
            "Mailbox '\(context.mailbox)' has more new messages than the gateway's widest page; "
                + "indexed the newest \(pageCount) and held the watermark at \(watermark) "
                + "so older arrivals stay pending instead of being skipped."
        )
    }

    /// Indexes all messages in one backfill page, recording outcomes and hashes.
    private func indexBackfillBatch(
        page: [MailIndexMessage],
        context: MailboxContext,
        watermark: Int,
        cursor: inout MailRunCursor,
        reporter: ToolProgressReporter
    ) async throws {
        try await indexMailPageBatch(
            page: page,
            context: context,
            watermarkMode: .backfill(watermark),
            cursor: &cursor,
            reporter: reporter
        )
    }

    /// Fetches one page with retry up to `maxFetchAttempts`, backing off on retryable errors.
    private func fetchSinglePageWithRetry(
        context: MailboxContext,
        limit: Int,
        beforeUID: Int?,
        cursor: inout MailRunCursor
    ) async throws -> [MailIndexMessage]? {
        var attempt = 0
        var terminalTransportError: Error?
        while attempt < Self.maxFetchAttempts {
            attempt += 1
            do {
                return try await gateway.messages(
                    credentials: context.credentials,
                    mailbox: context.mailbox,
                    limit: limit,
                    mode: .peek,
                    beforeUID: beforeUID
                )
            } catch let cancel as CancellationError {
                throw cancel
            } catch {
                guard Self.isRetryableMailError(error) else {
                    cursor.report.warnings.append("Skipped mailbox '\(context.account.name)/\(context.mailbox)': \(error.localizedDescription)")
                    return nil
                }
                if attempt >= Self.maxFetchAttempts {
                    terminalTransportError = error
                    break
                }
                let delayIndex = min(attempt - 1, Self.fetchRetryDelaysSeconds.count - 1)
                let delaySeconds = Self.fetchRetryDelaysSeconds[delayIndex]
                try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                do {
                    try await gateway.openMailboxSession(credentials: context.credentials, mailbox: context.mailbox)
                } catch let cancel as CancellationError {
                    throw cancel
                } catch {
                    cursor.report.warnings.append("Skipped mailbox '\(context.account.name)/\(context.mailbox)': \(error.localizedDescription)")
                    return nil
                }
            }
        }
        if let terminalTransportError {
            let message = "Skipped mailbox '\(context.account.name)/\(context.mailbox)': \(terminalTransportError.localizedDescription) "
                + "(after \(Self.maxFetchAttempts) attempts)"
            cursor.report.warnings.append(message)
        }
        return nil
    }
}

// MARK: - Indexing

extension MailIndexer {
    /// Per-mailbox indexing context, bundling the run-scoped policy.
    struct MailboxContext: Sendable {
        /// Account being walked.
        let account: EmailAccount
        /// Mailbox being walked, stored trimmed so pool, watermark, and document identity agree.
        let mailbox: String
        /// Resolved credentials for the account.
        let credentials: MailIndexCredentials
        /// Vector window policy.
        let window: MailVectorWindow
        /// Reference time for the run.
        let runDate: Date
        /// Largest attachment the run will stage.
        let attachmentCap: Int
    }

    /// Counts produced while indexing one message.
    struct MessageOutcome: Sendable {
        /// Whether the message was written.
        var indexed = false
        /// Whether the stored body hash was already current.
        var unchanged = false
        /// Whether the content hash matched an earlier message.
        var deduplicated = false
        /// Attachments staged and extracted.
        var staged = 0
        /// Attachments skipped for exceeding the size cap.
        var oversize = 0
        /// Attachments marked for the vision path.
        var metadataOnly = 0
        /// Chunks written.
        var chunks = 0
        /// Chunks carrying an embedding.
        var vectors = 0
        /// Content hash of the message body.
        var contentHash = ""
    }

    /// Mutable attachment accumulation for one message.
    struct AttachmentStaging {
        /// Body plus attachment chunks.
        var chunks: [DocumentChunk]
        /// Precomputed vectors for multimodal attachments (e.g., visual image vectors).
        var precomputedVectors: [Int: [Float]]
        /// Document metadata to annotate.
        var metadata: [String: String]
        /// Counts for staged, oversize, and vision parts.
        var outcome: MessageOutcome
        /// Whether any part degraded.
        var degraded: Bool
    }

    /// Fetches the newest window covering every UID above the watermark by paging downward.
    func fetchFreshWindow(
        credentials: MailIndexCredentials,
        mailbox: String,
        watermark: Int,
        anchoredUidNext: Int? = nil,
        sleeper: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) async throws -> (messages: [MailIndexMessage], complete: Bool) {
        var collected: [MailIndexMessage] = []
        var seenIDs = Set<String>()
        var beforeUID: Int? = anchoredUidNext
        var isFirstPage = true
        while true {
            try Task.checkCancellation()
            if !isFirstPage {
                try await sleeper(UInt64(Self.interPagePauseSeconds * 1_000_000_000))
            }
            isFirstPage = false
            let page = try await gateway.messages(
                credentials: credentials,
                mailbox: mailbox,
                limit: Self.pageLimit,
                mode: .peek,
                beforeUID: beforeUID
            )
            if page.isEmpty {
                // Empty fixed windows step downward instead of completing so a UID gap cannot
                // strand older mail below it.
                guard let current = beforeUID, let window = MailIndexTiling.window(beforeUID: current), window.lower > 1 else {
                    return (collected, true)
                }
                beforeUID = window.lower
                continue
            }
            // Dedupe by identifier so a repeated clamped page contributes no
            // duplicates; the empty-delta below then ends the loop.
            var advanced = false
            for message in page where seenIDs.insert(message.id).inserted {
                collected.append(message)
                advanced = true
            }
            // Numeric UIDs decide coverage; non-numeric identifiers carry no
            // watermark order and must not fake a reached boundary.
            let reachedWatermark = page.contains {
                let uid = Self.uid(of: $0.id)
                return uid > 0 && uid <= watermark
            }
            if reachedWatermark {
                return (collected, true)
            }
            // A repeated page means the gateway ignores the downward bound and clamps to one newest
            // window, so stop and let the caller hold the watermark over the gap.
            if !advanced {
                return (collected, false)
            }
            if page.count < Self.pageLimit {
                // A short page proves exhaustion only at the mailbox start;
                // otherwise step downward so a sparse window cannot strand
                // older mail below a UID gap.
                let shortFloor = collected.map { Self.uid(of: $0.id) }.filter { $0 > 0 }.min()
                guard let shortLowest = shortFloor else {
                    return (collected, false)
                }
                if shortLowest <= 1 {
                    return (collected, true)
                }
                beforeUID = shortLowest
                continue
            }
            // The next bound is strictly below every UID already fetched, so
            // pages never overlap and never skip. A missing numeric floor means
            // there is no order to page from; holding keeps the run safe.
            let numericFloor = collected.map { Self.uid(of: $0.id) }.filter { $0 > 0 }.min()
            guard let lowest = numericFloor else {
                return (collected, false)
            }
            if lowest <= 1 {
                return (collected, true)
            }
            beforeUID = lowest
        }
    }

    /// Resolves account credentials at execution time. The password is read from the environment or
    /// Keychain and never logged.
    func resolvedCredentials(for account: EmailAccount) async -> MailIndexCredentials? {
        let envVar = account.passwordEnvVar
        let password: String?
        do {
            password = try await secrets.retrieve(key: envVar)
        } catch is CancellationError {
            return nil
        } catch {
            RuneWeaverLog.tools.error("MailIndexer: failed to retrieve secret for \(envVar): \(error.localizedDescription)")
            return nil
        }
        guard let password, !password.isEmpty else {
            return nil
        }
        return MailIndexCredentials(
            accountName: account.name,
            host: account.host,
            port: account.port,
            username: account.username,
            password: password
        )
    }

    /// Builds an advisory progress line for a message.
    static func progress(report: MailIndexRunReport, account: String, mailbox: String, messageID: String) -> ToolProgress {
        ToolProgress(
            message: "Indexing mail: \(report.messagesIndexed) indexed, \(report.messagesSeen) scanned",
            scanned: report.messagesSeen,
            matched: report.messagesIndexed,
            current: "\(account) - \(mailbox)/\(messageID)"
        )
    }
}

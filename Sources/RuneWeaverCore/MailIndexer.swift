// Rune Weaver Core — Incremental mail indexer feeding the local document index.
//
// Walks configured mail accounts mailbox by mailbox, resuming from a persisted
// per-mailbox IMAP UID watermark so each run only touches newly arrived mail.
// Message bodies are indexed as plain text through the shared document
// extractor (which strips HTML), and attachments discovered from the message
// body structure are fetched read-only through `BODY.PEEK`, staged into
// Seatbelt-confined temp, extracted to text, then deleted so only text chunks
// and metadata persist. A per-attachment size cap, a per-run item budget, a
// content-hash dedupe set for forwarded duplicates, and a configurable vector
// window keep the local store bounded: mail older than the window stays
// keyword-only for the shared embedding backfill path. Credentials resolve at
// execution time through ``SecretsManager`` and are never logged or persisted.
//
// The gateway is a protocol seam so this file stays free of the tool layer;
// the live `SubprocessIMAPGateway` is adapted to it in `RuneWeaverTools`, and
// tests inject a stub that never touches the network.

import CryptoKit
import Dispatch
import Foundation

// MARK: - Indexer

/// Actor-isolated mail indexer over an injected read-only gateway seam.
///
/// One `run` enumerates every configured account and mailbox, indexes the
/// messages newer than each mailbox's UID watermark, and advances the
/// watermark as it goes. Malformed mail and unreachable mailboxes degrade to
/// warnings rather than aborting the run, while cancellation propagates.
public actor MailIndexer {
    /// Newest-message page size fetched per gateway call.
    ///
    /// One call stays bounded by the bridge page cap while fixed UID windows
    /// tile downward until they reach the watermark. The limit never widens;
    /// backfill converges by paging, not by growing the page.
    public static let pageLimit = 50

    /// Maximum fetch attempts per mailbox before skipping with a warning.
    ///
    /// The first failure of a retryable transport error backs off and retries;
    /// the terminal failure warns once with an attempt suffix.
    public static let maxFetchAttempts = 3

    /// Backoff delays in seconds between fetch attempts.
    ///
    /// The first retry waits the first entry and the second retry waits the
    /// second entry; the delays are cancellable so backoff aborts promptly.
    public static let fetchRetryDelaysSeconds: [TimeInterval] = [2, 8]

    /// Steady pause in seconds between gateway page calls.
    ///
    /// The fetch loop sleeps this long before every page except the first so
    /// backfill paces uniformly across hosts; the pause is injectable for tests
    /// and cancellable so a stop aborts the pause promptly.
    public static let interPagePauseSeconds: TimeInterval = 1.0

    /// Configured mail accounts.
    private let emailConfig: EmailConfig
    /// Index policy: enablement, source toggles, caps, budget, and vector window.
    private let indexConfig: IndexConfig
    /// Read-only gateway seam.
    private let gateway: any MailIndexGateway
    /// Document store the index writes into.
    private let store: DocIndexStore
    /// Optional embeddings backend for vector-eligible chunks.
    private let embedder: (any EmbeddingsBackend)?
    /// Text extractor shared with the rest of the index pipeline.
    private let extractor: any DocumentTextExtracting
    /// Incremental watermark and dedupe checkpoint store.
    private let checkpoints: MailIndexCheckpointStore
    /// Test-injectable staging root; nil uses Seatbelt-confined temp.
    private let stagingRoot: URL?
    /// Clock seam so tests can pin the vector-window reference time.
    private let now: @Sendable () -> Date
    /// Secrets manager used to resolve account passwords at execution time.
    private let secrets: SecretsManager

    /// Creates a mail indexer.
    /// - Parameters:
    ///   - emailConfig: Configured mail accounts.
    ///   - indexConfig: Index policy.
    ///   - gateway: Read-only gateway seam.
    ///   - store: Document store to index into.
    ///   - embedder: Optional embeddings backend for vector-eligible chunks.
    ///   - extractor: Text extractor; defaults to the shared document extractor.
    ///   - checkpoints: Incremental watermark and dedupe store.
    ///   - stagingRoot: Test-injectable staging root; nil uses confined temp.
    ///   - now: Clock seam for the vector window.
    ///   - secrets: Secrets manager used to resolve passwords at execution time.
    public init(
        emailConfig: EmailConfig,
        indexConfig: IndexConfig,
        gateway: any MailIndexGateway,
        store: DocIndexStore,
        embedder: (any EmbeddingsBackend)? = nil,
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
    /// - Returns: Counts describing the run.
    /// - Throws: Cancellation, or a store write failure; per-account and
    ///   per-mailbox problems degrade to warnings.
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
                // The mail run gate owns Trash-class matching: a denied
                // mailbox skips before any STATUS or fetch dial so transient
                // deletes never cost a round trip, counting only as skipped
                // with no warning. The name is remembered for the end-of-run
                // retire below.
                if Self.isMailboxDenied(mailbox, patterns: indexConfig.mailboxDeny) {
                    cursor.report.mailboxesScanned += 1
                    cursor.report.mailboxesSkipped += 1
                    deniedObserved.insert(mailbox)
                    continue
                }
                // The context stores the trimmed spelling so the pooled session, checkpoint
                // watermark, stored document mailbox, and document identity all agree; the shared
                // mailbox key and document identity both trim, so trimming once here keeps one
                // mailbox from forking pool and watermark from document identity.
                let context = MailboxContext(
                    account: account,
                    mailbox: mailbox.trimmingCharacters(in: .whitespacesAndNewlines),
                    credentials: credentials,
                    window: window,
                    runDate: runDate,
                    attachmentCap: attachmentCap
                )
                try await indexMailbox(context: context, cursor: &cursor, reporter: reporter)
            }
        }
        // Retire on complete runs only: a cancelled pass, a budget-capped
        // pass, or a halted pass never deletes what it never examined. Mail
        // carries no thermal gate, so completeness is cancellation plus an
        // unexhausted budget. Retired docs fold into the report so coordinator
        // totals stay honest, and dropped checkpoints let a re-allowed mailbox
        // backfill from scratch.
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
    ///
    /// Grouped so mailbox helpers stay under the parameter budget without
    /// changing the incremental watermark or budget semantics.
    private struct MailRunCursor: Sendable {
        /// Counts accumulated across mailboxes.
        var report: MailIndexRunReport
        /// Remaining items before the nightly cap stops the run.
        var budget: Int
        /// Last progress emission for throttling.
        var lastReport: UInt64
    }

    /// One mailbox window ready for per-message indexing.
    ///
    /// Bundles the sorted fresh set with its watermark decision so the
    /// message loop carries three arguments instead of a long parameter list.
    private struct MailboxBatch: Sendable {
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
    ///
    /// Newest-first pages are re-sorted ascending so the watermark never jumps
    /// over an unfetched gap; a burst wider than the gateway page holds the
    /// watermark while still recording hashes for dedupe on revisit.
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
        // The named owner for the open-close bracket is this method: the STATUS
        // probe plus every fetch page ride one pooled connection, with cancel,
        // skip, plus throw all terminating it. An open failure skips with no
        // one-shot fallback. Cleanup is explicit on every exit because an
        // async close cannot suspend inside a synchronous defer. Each close
        // runs through a detached-but-awaited helper so a cancel on the way
        // into the close still evicts the pool entry instead of leaking it,
        // and the evict completes before this method returns so callers
        // observe it synchronously. Closes are idempotent no-ops when absent.
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
    ///
    /// The caller owns the open-close bracket and guarantees the close on both
    /// return and throw, so this body uses plain returns for skips and plain
    /// throws for cancellation without its own cleanup.
    private func indexMailboxOpened(
        context: MailboxContext,
        watermark: inout Int,
        cursor: inout MailRunCursor,
        reporter: ToolProgressReporter
    ) async throws {
        // Reconcile the server validity token before paging: a mismatch means
        // UIDs were reassigned, so restart from zero while retained hashes
        // dedupe refetches. Unknown tokens skip the check without failing.
        // The probe rides the pooled session opened above.
        var probedStatus: MailIndexMailboxStatus?
        do {
            probedStatus = try await gateway.mailboxStatus(credentials: context.credentials, mailbox: context.mailbox)
        } catch let cancel as CancellationError {
            throw cancel
        } catch {
            // Status is advisory; a failing probe must not skip the mailbox
            // when the message path could still succeed. Only auth,
            // validation, and unknown-account failures skip at once without
            // a reopen so a bad credential or bad argument never pays for an
            // extra handshake. A retryable session failure already evicted,
            // so reopen fresh before paging instead of falling back to
            // one-shot mid-bracket. Any other probe failure (for example a
            // STATUS-unsupported server reporting a generic bridge failure)
            // falls back to the unanchored path with a nil probe, matching
            // the one-shot empty-query fallback, so session coverage never
            // diverges. A reopen failure skips at once with no fallback
            // so a dead session never pays for a fresh handshake it cannot
            // reuse.
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
        // The checkpoint sync persists to disk, so its failure is a local
        // store problem rather than a session problem: it warns and skips
        // without redialing, keeping a sidecar IO fault from masquerading as
        // an advisory STATUS failure.
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

    /// Indexes one sorted mailbox window, recording watermarks and progress.
    ///
    /// Budget is decremented per message so a capped run stops mid-mailbox;
    /// the watermark records each UID unless the window is held over a gap.
    private func indexFreshMessages(
        batch: MailboxBatch,
        cursor: inout MailRunCursor,
        reporter: ToolProgressReporter
    ) async throws {
        for message in batch.fresh {
            try Task.checkCancellation()
            guard cursor.budget > 0 else { break }
            cursor.budget -= 1
            cursor.report.messagesSeen += 1
            let outcome = try await index(message: message, context: batch.context)
            cursor.report.messagesIndexed += outcome.indexed ? 1 : 0
            cursor.report.messagesUnchanged += outcome.unchanged ? 1 : 0
            cursor.report.messagesDeduplicated += outcome.deduplicated ? 1 : 0
            cursor.report.attachmentsStaged += outcome.staged
            cursor.report.attachmentsSkippedOversize += outcome.oversize
            cursor.report.attachmentsMetadataOnly += outcome.metadataOnly
            cursor.report.chunksWritten += outcome.chunks
            cursor.report.vectorsWritten += outcome.vectors
            let uid = Self.uid(of: message.id)
            if uid > 0 {
                try await checkpoints.record(
                    account: batch.context.account.name,
                    mailbox: batch.context.mailbox,
                    watermark: batch.holdsWatermark ? batch.watermark : uid,
                    contentHash: outcome.contentHash
                )
            }
            let stamp = DispatchTime.now().uptimeNanoseconds
            if stamp &- cursor.lastReport >= ToolProgress.minimumReportIntervalNanoseconds {
                cursor.lastReport = stamp
                await reporter(Self.progress(report: cursor.report, account: batch.context.account.name, mailbox: batch.context.mailbox, messageID: message.id))
            }
        }
    }
}

// MARK: - Streaming backfill

extension MailIndexer {
    /// Deletes index rows for newly denied mailboxes and drops their checkpoints.
    ///
    /// The store owns deletion while this gate owns the observed set: hashes
    /// for the retired rows are read first so the checkpoint can forget them,
    /// otherwise a re-allowed mailbox would dedupe against its own deleted
    /// bodies instead of re-indexing. Failures degrade to a warning so a
    /// retire problem never fails an otherwise complete run.
    /// - Parameter denied: Mailbox names skipped this run.
    /// - Returns: Number of mail documents retired.
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
    ///
    /// Watermark is established on the first page if zero; the backfill floor advances
    /// downward as pages arrive and is cleared when the start of the mailbox is reached.
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
                try await checkpoints.record(
                    account: context.account.name,
                    mailbox: context.mailbox,
                    watermark: watermark,
                    contentHash: nil
                )
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
                try await checkpoints.recordBackfillFloor(
                    account: context.account.name,
                    mailbox: context.mailbox,
                    floor: nil
                )
                break
            }

            currentBeforeUID = lowest
            try await checkpoints.recordBackfillFloor(
                account: context.account.name,
                mailbox: context.mailbox,
                floor: lowest
            )
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
            try await checkpoints.recordBackfillFloor(account: account, mailbox: mailbox, floor: nil)
            return nil
        }
        try await checkpoints.recordBackfillFloor(account: account, mailbox: mailbox, floor: window.lower)
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
        for message in page {
            try Task.checkCancellation()
            guard cursor.budget > 0 else { break }
            cursor.budget -= 1
            cursor.report.messagesSeen += 1
            let outcome = try await index(message: message, context: context)
            cursor.report.messagesIndexed += outcome.indexed ? 1 : 0
            cursor.report.messagesUnchanged += outcome.unchanged ? 1 : 0
            cursor.report.messagesDeduplicated += outcome.deduplicated ? 1 : 0
            cursor.report.attachmentsStaged += outcome.staged
            cursor.report.attachmentsSkippedOversize += outcome.oversize
            cursor.report.attachmentsMetadataOnly += outcome.metadataOnly
            cursor.report.chunksWritten += outcome.chunks
            cursor.report.vectorsWritten += outcome.vectors

            if let hash = outcome.contentHash.isEmpty ? nil : outcome.contentHash {
                try await checkpoints.record(
                    account: context.account.name,
                    mailbox: context.mailbox,
                    watermark: watermark,
                    contentHash: hash
                )
            }
            let stamp = DispatchTime.now().uptimeNanoseconds
            if stamp &- cursor.lastReport >= ToolProgress.minimumReportIntervalNanoseconds {
                cursor.lastReport = stamp
                await reporter(Self.progress(
                    report: cursor.report,
                    account: context.account.name,
                    mailbox: context.mailbox,
                    messageID: message.id
                ))
            }
        }
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
    private struct MailboxContext: Sendable {
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
    private struct MessageOutcome {
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

    /// Fetches the newest window covering every UID above the watermark by paging downward.
    ///
    /// The named owner for tiling plus completion is this method: it owns the
    /// downward UID loop while the adapter owns the `UID lo:hi` criterion
    /// shape. The first page fetches the newest fixed window anchored from the
    /// threaded STATUS `uidNext` when the caller probed, otherwise from the
    /// gateway's own anchor; each later page passes `beforeUID` strictly below the
    /// lowest numeric UID already fetched, so the gateway returns only UIDs
    /// below that bound inside a window at most `MailIndexTiling.uidWindowWidth` wide. The
    /// loop stops when a page reaches the watermark (steady state still costs
    /// exactly one newest page), when a short page or a bound at the mailbox
    /// start proves exhaustion, or when a repeated page proves the gateway
    /// clamps to one newest window. An empty window steps downward to the next
    /// fixed window instead of completing so UID gaps from deletions cannot
    /// strand older mail. A clamped gateway therefore returns an incomplete
    /// window and the caller holds its watermark, so huge mailboxes degrade to
    /// multi-run backfill instead of stalling. Cancellation is honored at the
    /// top of each page so the loop stops at the next checkpoint. The named
    /// owner for pacing is this page loop: it pauses `interPagePauseSeconds`
    /// before every gateway page call except the first, uniformly for every
    /// host with no per-account branching.
    /// - Parameters:
    ///   - credentials: Resolved connection fields plus password.
    ///   - mailbox: Mailbox to read.
    ///   - watermark: Highest indexed UID; paging stops once a page reaches it.
    ///   - anchoredUidNext: Threaded STATUS `uidNext` for the first page, when
    ///     the caller already probed. A present value seeds the first
    ///     `beforeUID` so the gateway skips its own anchor STATUS on the same
    ///     connection; nil falls back to an unanchored newest page.
    ///   - sleeper: Pause hook sleeping the given nanoseconds; defaults to
    ///     `Task.sleep` so production paces while tests inject a recorder. The
    ///     hook throws so cancellation aborts the pause.
    /// - Returns: Unique messages in newest-first order, plus whether the window
    ///   reaches the watermark or the mailbox start.
    /// - Throws: Cancellation, the sleeper error, or the gateway error for the mailbox.
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
                // Empty fixed windows step downward instead of completing so a
                // UID gap cannot strand older mail below it. The next top is
                // the current window bottom minus one, derived from the shared
                // tiling helper the adapter criterion builds from. The mailbox
                // start still completes.
                guard let current = beforeUID else {
                    return (collected, true)
                }
                guard let window = MailIndexTiling.window(beforeUID: current) else {
                    return (collected, true)
                }
                guard window.lower > 1 else {
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
            // A repeated page means the gateway ignores the downward bound and
            // clamps to one newest window, so stop and let the caller hold the
            // watermark over the gap. This check precedes the short-page check
            // because a clamped page is also shorter than a full window only
            // when the mailbox itself is small.
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

    /// Resolves account credentials at execution time.
    ///
    /// The password is read from the environment or Keychain and never logged.
    /// - Parameter account: Configured account.
    /// - Returns: Resolved credentials, or nil when no password is available.
    private func resolvedCredentials(for account: EmailAccount) async -> MailIndexCredentials? {
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
    ///
    /// The current names the owning account so concurrent mailboxes stay
    /// distinguishable while the message copy and counts match the entering
    /// plus window frames exactly.
    /// - Parameters:
    ///   - report: Counts accumulated so far.
    ///   - account: Account nickname owning the mailbox.
    ///   - mailbox: Mailbox being walked.
    ///   - messageID: Message being indexed.
    /// - Returns: A progress value with no secret content.
    private static func progress(report: MailIndexRunReport, account: String, mailbox: String, messageID: String) -> ToolProgress {
        ToolProgress(
            message: "Indexing mail: \(report.messagesIndexed) indexed, \(report.messagesSeen) scanned",
            scanned: report.messagesSeen,
            matched: report.messagesIndexed,
            current: "\(account) - \(mailbox)/\(messageID)"
        )
    }

    /// Indexes one message and its stageable attachments.
    /// - Parameters:
    ///   - message: Message to index.
    ///   - context: Per-mailbox indexing context.
    /// - Returns: Counts describing the message outcome.
    /// - Throws: Cancellation, or a document-store write failure.
    private func index(message: MailIndexMessage, context: MailboxContext) async throws -> MessageOutcome {
        var outcome = MessageOutcome()
        let bodyText = Self.messageText(subject: message.subject, body: message.body)
        let contentHash = Self.contentHash(bodyText)
        outcome.contentHash = contentHash

        // Forwarded duplicates share a body hash even though their UIDs differ,
        // so the dedupe check runs before the per-document reindex check.
        if await checkpoints.containsContentHash(contentHash) {
            outcome.deduplicated = true
            return outcome
        }
        let externalID = Self.documentExternalID(
            account: context.account.name,
            mailbox: context.mailbox,
            messageID: message.id
        )
        if try await !(store.needsReindex(source: .mail, externalID: externalID, contentHash: contentHash)) {
            outcome.unchanged = true
            return outcome
        }

        let bodyExtraction = extractor.extract(
            data: Data(bodyText.utf8),
            fileName: "message.txt",
            contentType: "text/plain"
        )
        var chunks = bodyExtraction.chunks
        var metadata = ["account": context.account.name]
        var degraded = bodyExtraction.status != .extracted

        let eligible = context.window.includes(date: message.date, now: context.runDate)
        var staging = AttachmentStaging(
            chunks: chunks,
            precomputedVectors: [:],
            metadata: metadata,
            outcome: outcome,
            degraded: degraded
        )
        try await collectAttachmentChunks(
            message: message,
            context: context,
            eligible: eligible,
            staging: &staging
        )
        chunks = staging.chunks
        metadata = staging.metadata
        outcome = staging.outcome
        degraded = staging.degraded

        let embeddings = try await embeddings(
            for: chunks,
            title: message.subject,
            eligible: eligible,
            precomputed: staging.precomputedVectors
        )
        let document = IndexedDocument(
            source: .mail,
            externalID: externalID,
            displayName: Self.displayName(subject: message.subject),
            messageID: message.id,
            mailbox: context.mailbox,
            mtime: message.date,
            sizeBytes: message.sizeBytes.map { Int64($0) },
            contentHash: contentHash,
            mime: "message/rfc822",
            extractStatus: Self.extractStatus(hasText: !chunks.isEmpty, degraded: degraded),
            indexedAt: context.runDate,
            metadata: metadata
        )
        let stored = try await store.upsertDocument(document)
        let indexedChunks = chunks.enumerated().map { index, chunk in
            IndexedChunk(documentID: stored.id, ordinal: index, text: chunk.text, embedding: embeddings[index])
        }
        _ = try await store.upsertChunks(documentID: stored.id, chunks: indexedChunks)
        outcome.indexed = true
        outcome.chunks = indexedChunks.count
        outcome.vectors = indexedChunks.reduce(0) { $0 + ($1.isVector ? 1 : 0) }
        return outcome
    }

    /// Mutable attachment accumulation for one message.
    private struct AttachmentStaging {
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

    /// Stages and extracts attachment bodies into shared chunks.
    /// - Parameters:
    ///   - message: Message whose attachments are processed.
    ///   - context: Per-mailbox indexing context.
    ///   - eligible: Whether the message falls inside the vector window.
    ///   - staging: Chunks, metadata, outcome, and degraded flag updated in place.
    /// - Throws: Cancellation.
    private func collectAttachmentChunks(
        message: MailIndexMessage,
        context: MailboxContext,
        eligible: Bool,
        staging: inout AttachmentStaging
    ) async throws {
        for (index, info) in message.attachments.enumerated() {
            // Honor cancellation per attachment so a large attachment list
            // stops within one fetch instead of draining the whole message.
            try Task.checkCancellation()
            // The body structure reports a size before any bytes move, so an
            // oversized part is skipped without a fetch.
            if (info.sizeBytes ?? 0) > context.attachmentCap {
                staging.outcome.oversize += 1
                staging.metadata["attachment.\(index).skipped"] = "oversize"
                staging.degraded = true
                continue
            }
            let attachmentData: MailIndexAttachmentData
            do {
                attachmentData = try await gateway.attachment(
                    credentials: context.credentials,
                    mailbox: context.mailbox,
                    messageID: message.id,
                    attachmentIndex: index,
                    mode: .peek
                )
            } catch let cancel as CancellationError {
                throw cancel
            } catch {
                staging.degraded = true
                continue
            }
            guard attachmentData.data.count <= context.attachmentCap else {
                staging.outcome.oversize += 1
                staging.metadata["attachment.\(index).skipped"] = "oversize"
                staging.degraded = true
                continue
            }
            let filename = NormalizedText.value(info.filename) ?? attachmentData.filename
            let staged: (directory: URL, file: URL)
            do {
                staged = try stage(bytes: attachmentData.data, filename: filename)
            } catch {
                staging.degraded = true
                continue
            }
            defer { discardStaged(at: staged.directory) }

            let contentType = NormalizedText.value(info.contentType) ?? attachmentData.contentType
            let extraction = await extractor.extract(
                fileURL: staged.file,
                contentType: contentType
            )
            staging.outcome.staged += 1

            // Multimodal image path: if format is image, attempt visual embedding before discarding staged file
            if extraction.format == .image, eligible, let embedder {
                let dim = await embedder.dimension
                if let visual = try? await FilesIndexer.embedImageVisualVector(
                    fileURL: staged.file,
                    fileName: filename,
                    expectedDimension: dim,
                    embedImage: { try await embedder.embedImage(at: staged.file) }
                ), let vector = visual.first {
                    let chunkIndex = staging.chunks.count
                    let chunkText = extraction.chunks.first?.text ?? filename
                    let chunk = DocumentChunk(
                        index: chunkIndex,
                        text: chunkText,
                        estimatedTokens: max(1, chunkText.count / 4)
                    )
                    staging.chunks.append(chunk)
                    staging.precomputedVectors[chunkIndex] = vector
                    continue
                }
            }

            // An empty text layer (scanned or password-protected PDF) yields
            // metadata only, so the original bytes are flagged for the vision path.
            if extraction.status == .metadataOnly || extraction.status == .failed || extraction.status == .unsupported {
                staging.outcome.metadataOnly += 1
                staging.metadata["attachment.\(index).vision"] = extraction.status.rawValue
                staging.degraded = true
                continue
            }
            if extraction.status == .partial {
                staging.degraded = true
            }
            for chunk in extraction.chunks {
                staging.chunks.append(DocumentChunk(index: staging.chunks.count, text: chunk.text, estimatedTokens: chunk.estimatedTokens))
            }
        }
    }

    /// Embeds chunk text when the message is inside the vector window.
    ///
    /// Embedding failure degrades the affected chunks to keyword-only, matching
    /// the shared fallback contract; cancellation still propagates. The probe
    /// runs before the batch so a cancel observed between messages never starts
    /// another embedding batch, bounding overrun to one message. Only the first
    /// `max_vector_chunks_per_document` chunks are sent for embedding; the
    /// remainder keep an empty embedding so they stay fully keyword-searchable.
    /// - Parameters:
    ///   - chunks: Chunks to embed.
    ///   - title: Subject or title of the mail message for task prompt steering.
    ///   - eligible: Whether the message falls inside the vector window.
    ///   - precomputed: Precomputed multimodal vectors by chunk index.
    /// - Returns: One vector per chunk, empty for keyword-only chunks.
    private func embeddings(
        for chunks: [DocumentChunk],
        title: String? = nil,
        eligible: Bool,
        precomputed: [Int: [Float]] = [:]
    ) async throws -> [[Float]] {
        guard !chunks.isEmpty else { return [] }
        guard eligible, let embedder else {
            var result: [[Float]] = Array(repeating: [], count: chunks.count)
            for (idx, vec) in precomputed where idx < chunks.count {
                result[idx] = vec
            }
            return result
        }
        try Task.checkCancellation()
        var expanded: [[Float]] = Array(repeating: [], count: chunks.count)
        for (idx, vec) in precomputed where idx < chunks.count {
            expanded[idx] = vec
        }

        let maxChunks = indexConfig.maxVectorChunksPerDocument
        var indicesToEmbed: [Int] = []
        var textsToEmbed: [String] = []

        for index in 0 ..< min(chunks.count, maxChunks) where expanded[index].isEmpty {
            indicesToEmbed.append(index)
            textsToEmbed.append(EmbeddingGemmaPrompts.document(title: title, text: chunks[index].text))
        }

        if !textsToEmbed.isEmpty {
            do {
                let vectors = try await embedder.embed(textsToEmbed)
                if vectors.count == textsToEmbed.count {
                    for (pos, chunkIndex) in indicesToEmbed.enumerated() {
                        expanded[chunkIndex] = vectors[pos].isEmpty ? [] : vectors[pos]
                    }
                }
            } catch let cancel as CancellationError {
                throw cancel
            } catch {
                RuneWeaverLog.stores.info("MailIndexer: embedding failed for message: \(error.localizedDescription)")
            }
        }
        return expanded
    }

    /// Writes attachment bytes into Seatbelt-confined temp.
    /// - Parameters:
    ///   - bytes: Attachment bytes.
    ///   - filename: Original filename, sanitized before use.
    /// - Returns: The staging directory plus the staged file URL.
    /// - Throws: `MailIndexError.stagingFailed` when confinement cannot be proven.
    private func stage(bytes: Data, filename: String) throws -> (directory: URL, file: URL) {
        let directory: URL
        if let stagingRoot {
            let candidate = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(
                at: candidate,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            directory = candidate
        } else {
            directory = try SeatbeltProfileBuilder.makeConfinedTempDirectory(prefix: "runeweaver-mail-index-")
        }
        try requireConfinedTempAllow(directory)
        let file = directory.appendingPathComponent(Self.sanitizedFilename(filename, fallback: "attachment"))
        try bytes.write(to: file, options: .atomic)
        return (directory, file)
    }

    /// Fails closed unless the Seatbelt profile permits the staging temp.
    /// - Parameter directory: Confined temp directory.
    /// - Throws: `MailIndexError.stagingFailed` when the profile omits it.
    private func requireConfinedTempAllow(_ directory: URL) throws {
        let profile = SeatbeltProfileBuilder(allowedTempPaths: [directory.path]).buildProfile()
        guard profile.contains(directory.path) else {
            throw MailIndexError.stagingFailed("Attachment staging confined temp rejected by the Seatbelt profile")
        }
    }

    /// Deletes a staging directory and its staged binary.
    /// - Parameter directory: Confined temp directory to remove.
    private func discardStaged(at directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }
}

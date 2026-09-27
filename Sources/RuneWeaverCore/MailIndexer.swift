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

// MARK: - Checkpoint store

/// JSON-backed store for per-mailbox UID watermarks and seen content hashes.
///
/// The checkpoint is small and read on demand, so a JSON sidecar keeps the
/// incremental cursor independent of the document store schema.
public actor MailIndexCheckpointStore {
    /// Default checkpoint path, kept beside the other durable memory stores.
    public static let defaultPath = "~/.runeweaver/memory/mail-index-checkpoint.json"
    /// Upper bound on retained content hashes so the sidecar stays bounded.
    public static let maxTrackedHashes = 5000

    /// Filesystem path of the JSON checkpoint.
    public let path: String

    /// Whether the sidecar has been read into memory.
    private var loaded = false
    /// In-memory checkpoint snapshot.
    private var checkpoint = MailIndexCheckpoint()

    /// Creates a checkpoint store.
    /// - Parameter path: JSON sidecar path. `~` is expanded on first load.
    public init(path: String = MailIndexCheckpointStore.defaultPath) {
        self.path = path
    }

    /// Composes the mailbox key used for watermarks.
    ///
    /// Delegates to the shared `mailboxKey` so padded spellings share one
    /// watermark with the pooled session instead of forking pool vs checkpoint.
    /// - Parameters:
    ///   - account: Account nickname.
    ///   - mailbox: Mailbox name.
    /// - Returns: A stable opaque key.
    public static func key(account: String, mailbox: String) -> String {
        mailboxKey(account: account, mailbox: mailbox)
    }

    /// Highest indexed UID for one mailbox.
    /// - Parameters:
    ///   - account: Account nickname.
    ///   - mailbox: Mailbox name.
    /// - Returns: The watermark, or zero when none has been recorded.
    public func watermark(account: String, mailbox: String) -> Int {
        loadIfNeeded()
        return checkpoint.watermarks[Self.key(account: account, mailbox: mailbox)] ?? 0
    }

    /// Whether a content hash has already been indexed.
    /// - Parameter hash: Content hash under test.
    /// - Returns: True when the hash is already tracked.
    public func containsContentHash(_ hash: String) -> Bool {
        loadIfNeeded()
        return checkpoint.contentHashes.contains(hash)
    }

    /// Last observed validity token for one mailbox.
    /// - Parameters:
    ///   - account: Account nickname.
    ///   - mailbox: Mailbox name.
    /// - Returns: Stored token, or nil when never observed.
    public func uidValidity(account: String, mailbox: String) -> Int? {
        loadIfNeeded()
        return checkpoint.uidValidities[Self.key(account: account, mailbox: mailbox)]
    }

    /// Reconciles the stored validity token, resetting the watermark on mismatch.
    ///
    /// A changed token means the server reassigned UIDs, so the mailbox
    /// restarts from zero while retained hashes dedupe refetches instead of
    /// duplicating. A first observation only records without resetting.
    /// - Parameters:
    ///   - account: Account nickname.
    ///   - mailbox: Mailbox name.
    ///   - uidValidity: Current server token, or nil when unknown.
    /// - Returns: True when the watermark was reset.
    @discardableResult
    public func synchronizeValidity(account: String, mailbox: String, uidValidity: Int?) throws -> Bool {
        loadIfNeeded()
        guard let uidValidity else { return false }
        let mailboxKey = Self.key(account: account, mailbox: mailbox)
        if let stored = checkpoint.uidValidities[mailboxKey] {
            guard stored != uidValidity else { return false }
            checkpoint.watermarks[mailboxKey] = 0
            checkpoint.uidValidities[mailboxKey] = uidValidity
            try persist()
            return true
        }
        checkpoint.uidValidities[mailboxKey] = uidValidity
        try persist()
        return false
    }

    /// Records progress for one mailbox, persisting immediately.
    /// - Parameters:
    ///   - account: Account nickname.
    ///   - mailbox: Mailbox name.
    ///   - watermark: Highest indexed UID, which may only advance.
    ///   - contentHash: Content hash to remember, when one was computed.
    public func record(account: String, mailbox: String, watermark: Int, contentHash: String?) throws {
        loadIfNeeded()
        let mailboxKey = Self.key(account: account, mailbox: mailbox)
        if watermark > (checkpoint.watermarks[mailboxKey] ?? 0) {
            checkpoint.watermarks[mailboxKey] = watermark
        }
        if let contentHash, !checkpoint.contentHashes.contains(contentHash) {
            checkpoint.contentHashes.append(contentHash)
            if checkpoint.contentHashes.count > Self.maxTrackedHashes {
                checkpoint.contentHashes.removeFirst(checkpoint.contentHashes.count - Self.maxTrackedHashes)
            }
        }
        try persist()
    }

    /// Returns the current checkpoint snapshot.
    /// - Returns: The in-memory checkpoint.
    public func snapshot() -> MailIndexCheckpoint {
        loadIfNeeded()
        return checkpoint
    }

    /// Drops the watermark and validity token for one mailbox.
    ///
    /// Called after a denied mailbox retires so re-allowing it backfills from
    /// zero instead of resuming past mail it never indexed while denied.
    /// - Parameters:
    ///   - account: Account nickname.
    ///   - mailbox: Denied mailbox name.
    public func dropMailbox(account: String, mailbox: String) throws {
        loadIfNeeded()
        let key = Self.key(account: account, mailbox: mailbox)
        var changed = false
        if checkpoint.watermarks.removeValue(forKey: key) != nil {
            changed = true
        }
        if checkpoint.uidValidities.removeValue(forKey: key) != nil {
            changed = true
        }
        if changed {
            try persist()
        }
    }

    /// Forgets content hashes for retired mail so a re-allowed mailbox re-indexes.
    ///
    /// Hashes are global dedupe keys, so only the retired rows' hashes leave:
    /// every other mailbox keeps its dedupe memory while the denied bodies
    /// become indexable again.
    /// - Parameter hashes: Content hashes of the retired documents.
    public func removeContentHashes(_ hashes: Set<String>) throws {
        loadIfNeeded()
        guard !hashes.isEmpty else { return }
        let before = checkpoint.contentHashes.count
        checkpoint.contentHashes.removeAll { hashes.contains($0) }
        if checkpoint.contentHashes.count != before {
            try persist()
        }
    }

    /// Reads the sidecar once, ignoring unreadable or corrupt state.
    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let expanded = (path as NSString).expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: expanded)) else { return }
        do {
            checkpoint = try JSONDecoder().decode(MailIndexCheckpoint.self, from: data)
        } catch {
            RuneWeaverLog.stores.warning("MailIndexCheckpointStore: failed to decode checkpoint from '\(expanded)': \(error.localizedDescription)")
        }
    }

    /// Writes the checkpoint to disk atomically.
    private func persist() throws {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(checkpoint)
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - Report

/// Outcome of one mail indexing run.
public struct MailIndexRunReport: Sendable, Equatable {
    /// Accounts whose credentials resolved and whose mailbox listing succeeded.
    public var accountsScanned = 0
    /// Mailboxes enumerated across all accounts.
    public var mailboxesScanned = 0
    /// Denied mailboxes skipped without dialing.
    public var mailboxesSkipped = 0
    /// New messages considered after the UID watermark filter.
    public var messagesSeen = 0
    /// Messages written to the index.
    public var messagesIndexed = 0
    /// Messages skipped because their stored body hash was already current.
    public var messagesUnchanged = 0
    /// Messages skipped because their content hash matched an earlier message.
    public var messagesDeduplicated = 0
    /// Attachments staged, extracted, and deleted this run.
    public var attachmentsStaged = 0
    /// Attachments skipped for exceeding the per-attachment size cap.
    public var attachmentsSkippedOversize = 0
    /// Attachments whose text layer was unavailable, marked for the vision path.
    public var attachmentsMetadataOnly = 0
    /// Text chunks written this run.
    public var chunksWritten = 0
    /// Chunks written carrying an embedding this run.
    public var vectorsWritten = 0
    /// Mail documents retired because their mailbox joined the denylist.
    public var retiredCount = 0
    /// Non-fatal account- or mailbox-level problems, without any secret value.
    public var warnings: [String] = []
    /// Set when the run did not execute because mail indexing is disabled.
    public var skippedReason: String?

    /// Creates a run report.
    /// - Parameter skippedReason: Set when the run was skipped.
    public init(skippedReason: String? = nil) {
        self.skippedReason = skippedReason
    }

    /// Whether the indexer actually ran.
    public var didRun: Bool {
        skippedReason == nil
    }
}

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
            let hashes = await (try? store.mailContentHashes(mailboxes: denied)) ?? []
            let retired = try await store.retireMailboxes(denied)
            if retired > 0 {
                _ = try? await store.reclaim()
            }
            for account in emailConfig.accounts {
                for mailbox in denied {
                    try? await checkpoints.dropMailbox(account: account.name, mailbox: mailbox)
                }
            }
            if !hashes.isEmpty {
                try? await checkpoints.removeContentHashes(hashes)
            }
            return retired
        } catch {
            return 0
        }
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
        // mailbox name enters the frame; no subject or body ever does.
        await reporter(ToolProgress(
            message: "Indexing mail: \(cursor.report.messagesIndexed) indexed, \(cursor.report.messagesSeen) scanned",
            scanned: cursor.report.messagesSeen,
            matched: cursor.report.messagesIndexed,
            current: context.mailbox
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
            cursor.report.warnings.append("Skipped mailbox '\(context.mailbox)': \(error.localizedDescription)")
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
                cursor.report.warnings.append("Skipped mailbox '\(context.mailbox)': \(error.localizedDescription)")
                return
            }
            if Self.isRetryableMailError(error) {
                do {
                    try await gateway.openMailboxSession(credentials: context.credentials, mailbox: context.mailbox)
                } catch let cancel as CancellationError {
                    throw cancel
                } catch {
                    cursor.report.warnings.append("Skipped mailbox '\(context.mailbox)': \(error.localizedDescription)")
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
                cursor.report.warnings.append("Skipped mailbox '\(context.mailbox)': \(error.localizedDescription)")
                return
            }
        }
        guard let (fetched, windowComplete) = try await fetchFreshWindowWithRetry(
            context: context,
            watermark: watermark,
            anchoredUidNext: probedStatus?.uidNext,
            cursor: &cursor
        ) else {
            return
        }
        let fresh = Self.freshSortedMessages(fetched, watermark: watermark)
        // Window-fetched frame from the same owner, carrying the fresh count
        // so a paged backfill stays visible between the fetch return and the
        // first per-message emit. Same copy shape as the per-message frames.
        await reporter(ToolProgress(
            message: "Indexing mail: \(cursor.report.messagesIndexed) indexed, \(cursor.report.messagesSeen) scanned",
            scanned: cursor.report.messagesSeen,
            matched: cursor.report.messagesIndexed,
            current: "\(context.mailbox) (\(fresh.count) new)"
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
                    cursor.report.warnings.append("Skipped mailbox '\(context.mailbox)': \(error.localizedDescription)")
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
                    cursor.report.warnings.append("Skipped mailbox '\(context.mailbox)': \(error.localizedDescription)")
                    return nil
                }
                continue
            }
        }
        if let terminalTransportError {
            let message = "Skipped mailbox '\(context.mailbox)': \(terminalTransportError.localizedDescription) "
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
                await reporter(Self.progress(report: cursor.report, mailbox: batch.context.mailbox, messageID: message.id))
            }
        }
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
        guard let password = try? await secrets.retrieve(key: envVar), !password.isEmpty else {
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
    /// - Parameters:
    ///   - report: Counts accumulated so far.
    ///   - mailbox: Mailbox being walked.
    ///   - messageID: Message being indexed.
    /// - Returns: A progress value with no secret content.
    private static func progress(report: MailIndexRunReport, mailbox: String, messageID: String) -> ToolProgress {
        ToolProgress(
            message: "Indexing mail: \(report.messagesIndexed) indexed, \(report.messagesSeen) scanned",
            scanned: report.messagesSeen,
            matched: report.messagesIndexed,
            current: "\(mailbox)/\(messageID)"
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

        var staging = AttachmentStaging(chunks: chunks, metadata: metadata, outcome: outcome, degraded: degraded)
        try await collectAttachmentChunks(message: message, context: context, staging: &staging)
        chunks = staging.chunks
        metadata = staging.metadata
        outcome = staging.outcome
        degraded = staging.degraded

        let eligible = context.window.includes(date: message.date, now: context.runDate)
        let embeddings = try await embeddings(for: chunks, eligible: eligible)
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
    ///   - staging: Chunks, metadata, outcome, and degraded flag updated in place.
    /// - Throws: Cancellation.
    private func collectAttachmentChunks(
        message: MailIndexMessage,
        context: MailboxContext,
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
            let stagedBytes = (try? Data(contentsOf: staged.file)) ?? attachmentData.data
            let extraction = extractor.extract(
                data: stagedBytes,
                fileName: staged.file.lastPathComponent,
                contentType: NormalizedText.value(info.contentType) ?? attachmentData.contentType
            )
            staging.outcome.staged += 1
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
    ///   - eligible: Whether the message falls inside the vector window.
    /// - Returns: One vector per chunk, empty for keyword-only chunks.
    private func embeddings(for chunks: [DocumentChunk], eligible: Bool) async throws -> [[Float]] {
        guard !chunks.isEmpty else { return [] }
        guard eligible, let embedder else {
            return Array(repeating: [], count: chunks.count)
        }
        try Task.checkCancellation()
        do {
            let texts = FilesVectorPolicy.cappedEmbeddingTexts(
                chunks.map(\.text),
                cap: indexConfig.maxVectorChunksPerDocument
            )
            let vectors = try await embedder.embed(texts)
            guard vectors.count == texts.count else {
                return Array(repeating: [], count: chunks.count)
            }
            var expanded: [[Float]] = Array(repeating: [], count: chunks.count)
            for position in vectors.indices {
                expanded[position] = vectors[position].isEmpty ? [] : vectors[position]
            }
            return expanded
        } catch let cancel as CancellationError {
            throw cancel
        } catch {
            return Array(repeating: [], count: chunks.count)
        }
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

// MARK: - Value helpers

extension MailIndexer {
    /// Reports whether a mailbox joins the Trash-class denylist.
    ///
    /// The mail run gate owns this match: every pattern and every candidate
    /// lowercases first to mirror the files walker, and the full mailbox name
    /// plus each slash-separated hierarchy segment is tested so `Trash`
    /// covers both `Trash` and `INBOX/Trash` while `Deleted*` still spans the
    /// space in `Deleted Messages`.
    /// - Parameters:
    ///   - mailbox: Mailbox name from the gateway.
    ///   - patterns: Raw denylist globs from `IndexConfig.mailboxDeny`.
    /// - Returns: True when any pattern matches the mailbox or a segment.
    public static func isMailboxDenied(_ mailbox: String, patterns: [String]) -> Bool {
        let trimmedMailbox = mailbox.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMailbox.isEmpty else { return false }
        let loweredMailbox = trimmedMailbox.lowercased()
        let segments = loweredMailbox.split(separator: "/").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var candidates = [loweredMailbox]
        candidates.append(contentsOf: segments)
        for rawPattern in patterns {
            let pattern = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !pattern.isEmpty else { continue }
            for candidate in candidates where SharedGlobMatching.matches(pattern: pattern, relativePath: candidate) {
                return true
            }
        }
        return false
    }

    /// Whether a mail fetch error is worth retrying.
    ///
    /// The wording owner is `MailErrorClassification`: cancellation never
    /// retries, authentication failures never retry, transient transport
    /// phrases retry, and everything else skips at once. Authentication wins
    /// over transport so a message carrying both signals still skips.
    /// - Parameter error: Fetch failure under test.
    /// - Returns: True for retryable transport failures, false otherwise.
    public static func isRetryableMailError(_ error: Error) -> Bool {
        if error is CancellationError {
            return false
        }
        let described: String = if let localized = (error as? LocalizedError)?.errorDescription {
            localized + " " + String(describing: error)
        } else {
            error.localizedDescription + " " + String(describing: error)
        }
        if MailErrorClassification.isAuthFailureDetail(described) {
            return false
        }
        return MailErrorClassification.isTransportFailureDetail(described)
    }

    /// Whether a STATUS probe failure must skip the mailbox without paging.
    ///
    /// Only authentication, fail-closed validation, and unknown-account
    /// failures skip: a bad credential or bad argument cannot succeed on the
    /// message path. Every other probe failure falls back to the unanchored
    /// path with a nil probe, matching the one-shot empty-query fallback.
    /// Auth wording stays owned by `MailErrorClassification`; validation plus
    /// unknown-account arrive as Core-owned `MailIndexError` cases mapped by
    /// the gateway adapter so this layer matches by type without importing
    /// the tool layer.
    /// - Parameter error: STATUS probe failure under test.
    /// - Returns: True when the mailbox must be skipped, false to page unanchored.
    private static func isSkippableStatusError(_ error: Error) -> Bool {
        if let indexError = error as? MailIndexError {
            switch indexError {
            case .validationFailed, .unknownAccount:
                return true
            case .stagingFailed:
                return false
            }
        }
        let described: String = if let localized = (error as? LocalizedError)?.errorDescription {
            localized + " " + String(describing: error)
        } else {
            error.localizedDescription + " " + String(describing: error)
        }
        return MailErrorClassification.isAuthFailureDetail(described)
    }

    /// Closes a pooled mailbox session without inheriting cancellation.
    ///
    /// The mailbox bracket owns this close: the evict runs detached so a
    /// cancelled caller still releases the pooled connection instead of
    /// leaking it, and the detached task is awaited so the close lands before
    /// the mailbox returns and stays observable to callers. The adapter close
    /// is an idempotent no-op when absent.
    /// - Parameters:
    ///   - gateway: Gateway owning the pooled session.
    ///   - credentials: Resolved connection fields plus password.
    ///   - mailbox: Mailbox whose session ends.
    private static func closeMailboxSessionAssumingOpen(
        gateway: any MailIndexGateway,
        credentials: MailIndexCredentials,
        mailbox: String
    ) async {
        await Task.detached { [gateway, credentials, mailbox] in
            await gateway.closeMailboxSession(credentials: credentials, mailbox: mailbox)
        }.value
    }

    /// Parses an IMAP UID, returning zero for anything non-numeric.
    /// - Parameter id: Message identifier from the gateway.
    /// - Returns: The UID, or zero when the identifier is not numeric.
    static func uid(of id: String) -> Int {
        Int(id.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// Filters to UIDs above the watermark and sorts ascending for contiguous advance.
    ///
    /// Newest-first pages are re-sorted so the watermark only advances past
    /// messages that were actually considered, never jumping a gap.
    static func freshSortedMessages(_ fetched: [MailIndexMessage], watermark: Int) -> [MailIndexMessage] {
        fetched
            .filter { Self.uid(of: $0.id) > watermark }
            .sorted { Self.uid(of: $0.id) < Self.uid(of: $1.id) }
    }

    /// Whether the watermark must be held over an unfetched gap.
    ///
    /// A burst larger than the gateway's widest page leaves IDs between the
    /// watermark and the fetched middle; holding keeps them eligible while
    /// hashes still dedupe on revisit.
    static func holdsWatermark(windowComplete: Bool, fresh: [MailIndexMessage], watermark: Int) -> Bool {
        let minFreshUID = fresh.map { Self.uid(of: $0.id) }.filter { $0 > 0 }.min()
        return !windowComplete && (minFreshUID ?? watermark + 1) > watermark + 1
    }

    /// Composes the source-scoped identifier for one message.
    /// The mailbox is trimmed so padded spellings share one document identity with the pooled
    /// session and checkpoint watermark, which already normalize through the shared mailbox key;
    /// otherwise one mailbox would fork pool and watermark from document identity.
    /// - Parameters:
    ///   - account: Account nickname.
    ///   - mailbox: Mailbox name.
    ///   - messageID: IMAP UID.
    /// - Returns: A stable document identifier.
    static func documentExternalID(account: String, mailbox: String, messageID: String) -> String {
        let trimmedMailbox = mailbox.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(account)/\(trimmedMailbox)/\(messageID)"
    }

    /// Joins a subject and body into the indexed message text.
    /// - Parameters:
    ///   - subject: Decoded subject header.
    ///   - body: Decoded plain-text body.
    /// - Returns: Subject plus body, each trimmed, separated by a blank line.
    static func messageText(subject: String, body: String) -> String {
        let trimmedSubject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedSubject.isEmpty {
            return trimmedBody
        }
        if trimmedBody.isEmpty {
            return trimmedSubject
        }
        return "\(trimmedSubject)\n\n\(trimmedBody)"
    }

    /// Hashes message text for change detection and duplicate suppression.
    /// - Parameter text: Normalized message text.
    /// - Returns: Lowercase SHA-256 hex digest.
    static func contentHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Human-readable name for a message document.
    /// - Parameter subject: Decoded subject header.
    /// - Returns: The trimmed subject, or a placeholder when blank.
    static func displayName(subject: String) -> String {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "(no subject)" : trimmed
    }

    /// Classifies how completely a message was extracted.
    /// - Parameters:
    ///   - hasText: Whether any chunk text was produced.
    ///   - degraded: Whether any part was partial, oversized, or unreadable.
    /// - Returns: The extraction status to persist.
    static func extractStatus(hasText: Bool, degraded: Bool) -> ExtractStatus {
        guard hasText else { return .metadataOnly }
        return degraded ? .partial : .extracted
    }

    /// Reduces an attachment filename to a safe base name.
    ///
    /// The staged binary is only ever read back for extraction and then deleted,
    /// so this only needs to prevent path traversal and control characters.
    /// - Parameters:
    ///   - filename: Original filename.
    ///   - fallback: Name used when nothing safe remains.
    /// - Returns: A sanitized base name.
    static func sanitizedFilename(_ filename: String, fallback: String) -> String {
        let base = (filename as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        var cleaned = base
            .replacingOccurrences(of: "\0", with: "_")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        cleaned = cleaned.unicodeScalars.map { scalar -> String in
            let value = scalar.value
            if value < 32 || value == 127 {
                return "_"
            }
            return String(scalar)
        }.joined()
        while cleaned.hasPrefix(".") || cleaned.hasPrefix("-") {
            cleaned.removeFirst()
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count > 255 {
            cleaned = String(cleaned.prefix(255))
        }
        guard !cleaned.isEmpty, cleaned != ".", cleaned != ".." else {
            return fallback
        }
        return cleaned
    }
}

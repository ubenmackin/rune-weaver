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

// MARK: - Gateway seam

/// Resolved credentials for one mail indexing run.
///
/// The password exists only between execution-time resolution and the gateway
/// call. ``description`` and ``debugDescription`` are redacted so the value is
/// safe to log or reflect.
public struct MailIndexCredentials: Sendable, Equatable {
    /// Account nickname the credentials belong to.
    public let accountName: String
    /// IMAP hostname.
    public let host: String
    /// IMAP port.
    public let port: Int
    /// Login username.
    public let username: String
    /// Runtime-resolved password. Never log, print, or persist.
    public let password: String

    /// Creates resolved credentials.
    /// - Parameters:
    ///   - accountName: Account nickname the credentials belong to.
    ///   - host: IMAP hostname.
    ///   - port: IMAP port.
    ///   - username: Login username.
    ///   - password: Runtime-resolved password, never logged.
    public init(accountName: String, host: String, port: Int, username: String, password: String) {
        self.accountName = accountName
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }
}

extension MailIndexCredentials: CustomStringConvertible, CustomDebugStringConvertible {
    /// Redacted summary naming only the account, user, and host.
    public var description: String {
        "MailCredentials(\(accountName): \(username)@\(host):\(port))"
    }

    /// Redacted debug summary mirroring ``description``.
    public var debugDescription: String {
        description
    }
}

/// One attachment part discovered from a message body structure.
public struct MailIndexAttachmentInfo: Sendable, Equatable {
    /// Original filename reported by the body structure.
    public let filename: String
    /// MIME type reported by the body structure.
    public let contentType: String
    /// Decoded part size in bytes when the structure reports it.
    public let sizeBytes: Int?

    /// Creates attachment metadata.
    /// - Parameters:
    ///   - filename: Original filename reported by the body structure.
    ///   - contentType: MIME type reported by the body structure.
    ///   - sizeBytes: Decoded part size in bytes when known.
    public init(filename: String, contentType: String, sizeBytes: Int? = nil) {
        self.filename = filename
        self.contentType = contentType
        self.sizeBytes = sizeBytes
    }
}

/// Attachment bytes fetched for one staging pass.
public struct MailIndexAttachmentData: Sendable, Equatable {
    /// Original filename.
    public let filename: String
    /// MIME type.
    public let contentType: String
    /// Decoded byte size.
    public let sizeBytes: Int
    /// Decoded attachment bytes.
    public let data: Data

    /// Creates fetched attachment bytes.
    /// - Parameters:
    ///   - filename: Original filename.
    ///   - contentType: MIME type.
    ///   - sizeBytes: Decoded byte size.
    ///   - data: Decoded attachment bytes.
    public init(filename: String, contentType: String, sizeBytes: Int, data: Data) {
        self.filename = filename
        self.contentType = contentType
        self.sizeBytes = sizeBytes
        self.data = data
    }
}

/// One message fetched for indexing.
public struct MailIndexMessage: Sendable, Equatable {
    /// IMAP UID (the incremental watermark cursor).
    public let id: String
    /// Decoded `Subject` header.
    public let subject: String
    /// Decoded `From` header.
    public let from: String
    /// Parsed message date, used for the vector window.
    public let date: Date?
    /// Decoded plain-text body.
    public let body: String
    /// Attachment parts reported by the body structure.
    public let attachments: [MailIndexAttachmentInfo]
    /// Whole-message size in bytes when known.
    public let sizeBytes: Int?

    /// Creates a message for indexing.
    /// - Parameters:
    ///   - id: IMAP UID.
    ///   - subject: Decoded subject header.
    ///   - from: Decoded from header.
    ///   - date: Parsed message date.
    ///   - body: Decoded plain-text body.
    ///   - attachments: Attachment parts from the body structure.
    ///   - sizeBytes: Whole-message size when known.
    public init(
        id: String,
        subject: String,
        from: String,
        date: Date?,
        body: String,
        attachments: [MailIndexAttachmentInfo] = [],
        sizeBytes: Int? = nil
    ) {
        self.id = id
        self.subject = subject
        self.from = from
        self.date = date
        self.body = body
        self.attachments = attachments
        self.sizeBytes = sizeBytes
    }
}

/// Fetch mode for a read-only IMAP request.
///
/// Only `.peek` is defined: the indexer must never set `\Seen`, so the seam
/// cannot express a mutating fetch.
public enum MailFetchMode: String, Sendable, Equatable {
    /// `BODY.PEEK` — reads the part without setting the `\Seen` flag.
    case peek
}

/// Read-only IMAP gateway seam the indexer enumerates through.
///
/// Implementations are expected to use `BODY.PEEK` for every fetch so an index
/// run never marks mail as read. The live adapter wraps the shared IMAP bridge.
public protocol MailIndexGateway: Sendable {
    /// Lists selectable mailboxes for an account.
    /// - Parameter credentials: Resolved connection fields plus password.
    /// - Returns: Selectable mailbox names in server order.
    func mailboxes(credentials: MailIndexCredentials) async throws -> [String]

    /// Returns the newest messages in a mailbox, newest first.
    ///
    /// The indexer widens `limit` across calls until the window reaches its UID
    /// watermark, so implementations should honor larger limits with prefix
    /// semantics (the `limit` newest) when able. Implementations that clamp to a
    /// single newest page keep working; the indexer then holds its watermark
    /// instead of jumping the unfetched gap.
    /// - Parameters:
    ///   - credentials: Resolved connection fields plus password.
    ///   - mailbox: Mailbox to read.
    ///   - limit: Maximum messages to return.
    ///   - mode: Fetch mode; always `.peek` from the indexer.
    /// - Returns: Messages in newest-first order.
    func messages(
        credentials: MailIndexCredentials,
        mailbox: String,
        limit: Int,
        mode: MailFetchMode
    ) async throws -> [MailIndexMessage]

    /// Fetches one attachment part read-only.
    /// - Parameters:
    ///   - credentials: Resolved connection fields plus password.
    ///   - mailbox: Mailbox holding the message.
    ///   - messageID: IMAP UID of the message.
    ///   - attachmentIndex: Zero-based position in the message's attachment list.
    ///   - mode: Fetch mode; always `.peek` from the indexer.
    /// - Returns: Decoded attachment bytes.
    func attachment(
        credentials: MailIndexCredentials,
        mailbox: String,
        messageID: String,
        attachmentIndex: Int,
        mode: MailFetchMode
    ) async throws -> MailIndexAttachmentData
}

// MARK: - Errors

/// Failures raised while indexing mail.
public enum MailIndexError: Error, Sendable, Equatable {
    /// Attachment staging could not be confined to the Seatbelt temp policy.
    case stagingFailed(String)
}

extension MailIndexError: LocalizedError {
    /// Human-readable message without any secret value.
    public var errorDescription: String? {
        switch self {
        case let .stagingFailed(detail):
            detail
        }
    }
}

// MARK: - Vector window

/// How far back mail is vectorized.
///
/// Older mail is still indexed and keyword-searchable; it simply carries no
/// embedding so the shared backfill path can pick it up later.
public enum MailVectorWindow: Sendable, Equatable {
    /// Every message is vector-eligible regardless of age.
    case all
    /// Only messages newer than a trailing day window are vector-eligible.
    case trailing(days: Int)

    /// Trailing day count for the two-year window.
    ///
    /// Shared by the explicit `"2y"` token and the unknown-token fallback so
    /// the closed set and the parser cannot drift apart.
    public static let twoYearTrailingDays = 730

    /// Parses a configured window token.
    ///
    /// Unknown tokens fall back to the engine default (two years) so a bad
    /// value can only narrow the window, never open it unbounded.
    /// - Parameter token: One of `30d`, `6m`, `1y`, `2y`, or `all`.
    public init(token: String) {
        switch token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "all":
            self = .all
        case "30d":
            self = .trailing(days: 30)
        case "6m":
            self = .trailing(days: 183)
        case "1y":
            self = .trailing(days: 365)
        case "2y":
            self = .trailing(days: Self.twoYearTrailingDays)
        default:
            self = .trailing(days: Self.twoYearTrailingDays)
        }
    }

    /// Oldest date still eligible for an embedding.
    /// - Parameter now: Reference time for the window.
    /// - Returns: The cutoff date, or nil when the window is unbounded.
    public func cutoff(now: Date) -> Date? {
        switch self {
        case .all:
            nil
        case let .trailing(days):
            now.addingTimeInterval(-Double(days) * 86400)
        }
    }

    /// Whether a message date falls inside the window.
    ///
    /// A missing date is treated as eligible so mail with unparseable headers
    /// is not silently excluded from the semantic path.
    /// - Parameters:
    ///   - date: Message date, when known.
    ///   - now: Reference time for the window.
    /// - Returns: True when the message may carry an embedding.
    public func includes(date: Date?, now: Date) -> Bool {
        guard let cutoff = cutoff(now: now) else { return true }
        guard let date else { return true }
        return date >= cutoff
    }
}

// MARK: - Checkpoints

/// Persisted indexer progress: per-mailbox UID watermarks plus content hashes.
public struct MailIndexCheckpoint: Sendable, Equatable, Codable {
    /// Highest indexed IMAP UID per `account\u{1F}mailbox` key.
    public var watermarks: [String: Int]
    /// Content hashes already indexed, oldest first, for forwarded-duplicate dedupe.
    public var contentHashes: [String]

    /// Creates a checkpoint.
    /// - Parameters:
    ///   - watermarks: Highest indexed UID per mailbox key.
    ///   - contentHashes: Content hashes already indexed.
    public init(watermarks: [String: Int] = [:], contentHashes: [String] = []) {
        self.watermarks = watermarks
        self.contentHashes = contentHashes
    }
}

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
    /// - Parameters:
    ///   - account: Account nickname.
    ///   - mailbox: Mailbox name.
    /// - Returns: A stable opaque key.
    public static func key(account: String, mailbox: String) -> String {
        "\(account)\u{1F}\(mailbox)"
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

    /// Reads the sidecar once, ignoring unreadable or corrupt state.
    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let expanded = (path as NSString).expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: expanded)) else { return }
        if let decoded = try? JSONDecoder().decode(MailIndexCheckpoint.self, from: data) {
            checkpoint = decoded
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
    /// One call stays bounded by the IMAP bridge's own 50-hit search cap; the
    /// run widens the window across calls until it reaches the UID watermark.
    public static let pageLimit = 50

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
                let context = MailboxContext(
                    account: account,
                    mailbox: mailbox,
                    credentials: credentials,
                    window: window,
                    runDate: runDate,
                    attachmentCap: attachmentCap
                )
                try await indexMailbox(context: context, cursor: &cursor, reporter: reporter)
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
        let watermark = await checkpoints.watermark(account: context.account.name, mailbox: context.mailbox)
        let fetched: [MailIndexMessage]
        let windowComplete: Bool
        do {
            (fetched, windowComplete) = try await fetchFreshWindow(
                credentials: context.credentials,
                mailbox: context.mailbox,
                watermark: watermark
            )
        } catch let cancel as CancellationError {
            throw cancel
        } catch {
            cursor.report.warnings.append("Skipped mailbox '\(context.mailbox)': \(error.localizedDescription)")
            return
        }
        let fresh = Self.freshSortedMessages(fetched, watermark: watermark)
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

private extension MailIndexer {
    /// Per-mailbox indexing context, bundling the run-scoped policy.
    struct MailboxContext: Sendable {
        /// Account being walked.
        let account: EmailAccount
        /// Mailbox being walked.
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
    struct MessageOutcome {
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

    /// Fetches the newest window covering every UID above the watermark when the gateway widens.
    ///
    /// The gateway only promises the newest page, so a burst of arrivals larger
    /// than one page would leave the middle permanently skipped if the watermark
    /// jumped straight to the newest UID. The window therefore widens by one
    /// page until it reaches the watermark (or the mailbox start), and reports
    /// whether it got there so the caller can hold the watermark over any
    /// remaining gap instead of jumping it. A gateway that clamps every call to
    /// one newest page surfaces no new IDs on the widened call, which ends the
    /// loop without further cost.
    /// - Parameters:
    ///   - credentials: Resolved connection fields plus password.
    ///   - mailbox: Mailbox to read.
    ///   - watermark: Highest indexed UID; widening stops once a page reaches it.
    /// - Returns: Unique messages in newest-first order, plus whether the window
    ///   reaches the watermark or the mailbox start.
    /// - Throws: Cancellation, or the gateway error for the mailbox.
    func fetchFreshWindow(
        credentials: MailIndexCredentials,
        mailbox: String,
        watermark: Int
    ) async throws -> (messages: [MailIndexMessage], complete: Bool) {
        var limit = Self.pageLimit
        var collected: [MailIndexMessage] = []
        var seenIDs = Set<String>()
        while true {
            try Task.checkCancellation()
            let page = try await gateway.messages(
                credentials: credentials,
                mailbox: mailbox,
                limit: limit,
                mode: .peek
            )
            var widened = false
            for message in page where seenIDs.insert(message.id).inserted {
                collected.append(message)
                widened = true
            }
            if page.isEmpty {
                return (collected, true)
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
            // A repeated page means the gateway clamps the window (the live
            // bridge caps at one page), so stop widening and let the caller
            // hold the watermark over the gap. This check precedes the short
            // page check because a clamped page is also shorter than the
            // widened limit without reaching the mailbox start.
            if !widened {
                return (collected, false)
            }
            if page.count < limit {
                return (collected, true)
            }
            limit += Self.pageLimit
        }
    }

    /// Resolves account credentials at execution time.
    ///
    /// The password is read from the environment or Keychain and never logged.
    /// - Parameter account: Configured account.
    /// - Returns: Resolved credentials, or nil when no password is available.
    func resolvedCredentials(for account: EmailAccount) async -> MailIndexCredentials? {
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
    static func progress(report: MailIndexRunReport, mailbox: String, messageID: String) -> ToolProgress {
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
    func index(message: MailIndexMessage, context: MailboxContext) async throws -> MessageOutcome {
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
    struct AttachmentStaging {
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
    func collectAttachmentChunks(
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
    /// another embedding batch, bounding overrun to one message.
    /// - Parameters:
    ///   - chunks: Chunks to embed.
    ///   - eligible: Whether the message falls inside the vector window.
    /// - Returns: One vector per chunk, empty for keyword-only chunks.
    func embeddings(for chunks: [DocumentChunk], eligible: Bool) async throws -> [[Float]] {
        guard !chunks.isEmpty else { return [] }
        guard eligible, let embedder else {
            return Array(repeating: [], count: chunks.count)
        }
        try Task.checkCancellation()
        do {
            let vectors = try await embedder.embed(chunks.map(\.text))
            guard vectors.count == chunks.count else {
                return Array(repeating: [], count: chunks.count)
            }
            return vectors.map { $0.isEmpty ? [] : $0 }
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
    func stage(bytes: Data, filename: String) throws -> (directory: URL, file: URL) {
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
    func requireConfinedTempAllow(_ directory: URL) throws {
        let profile = SeatbeltProfileBuilder(allowedTempPaths: [directory.path]).buildProfile()
        guard profile.contains(directory.path) else {
            throw MailIndexError.stagingFailed("Attachment staging confined temp rejected by the Seatbelt profile")
        }
    }

    /// Deletes a staging directory and its staged binary.
    /// - Parameter directory: Confined temp directory to remove.
    func discardStaged(at directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }
}

// MARK: - Value helpers

extension MailIndexer {
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
    /// - Parameters:
    ///   - account: Account nickname.
    ///   - mailbox: Mailbox name.
    ///   - messageID: IMAP UID.
    /// - Returns: A stable document identifier.
    static func documentExternalID(account: String, mailbox: String, messageID: String) -> String {
        "\(account)/\(mailbox)/\(messageID)"
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

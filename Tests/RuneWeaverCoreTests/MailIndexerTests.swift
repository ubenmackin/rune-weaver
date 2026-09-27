// Rune Weaver Core Tests — Incremental mail indexer pipeline.
//
// Drives the mail indexer end to end against an in-memory stub gateway and an
// isolated temporary document store: per-mailbox UID watermark increments
// across runs, the read-only PEEK fetch mode, per-attachment size caps,
// content-hash dedupe for forwarded duplicates, the vector window, confined
// staging cleanup, and the vision fallback for unreadable attachments. No test
// touches the network, the real Keychain, or `~/.runeweaver`.

import Foundation
@testable import RuneWeaverCore
@testable import RuneWeaverTools
import Testing

// MARK: - Fixtures

/// Test account whose password resolves through the environment.
private let testAccount = EmailAccount(
    name: "mailtest",
    type: "imap",
    host: "imap.example.com",
    port: 993,
    username: "user@example.com"
)

/// Records the fetch modes the indexer asks the gateway for.
private actor ModeRecorder {
    /// Modes observed in call order.
    private var modes: [MailFetchMode] = []

    /// Records one mode.
    /// - Parameter mode: Mode passed to the gateway.
    func record(_ mode: MailFetchMode) {
        modes.append(mode)
    }

    /// Returns the observed modes.
    /// - Returns: Modes in call order.
    func snapshot() -> [MailFetchMode] {
        modes
    }
}

/// Counts attachment fetches so size caps can be proven before a fetch.
private actor CallRecorder {
    /// Number of calls observed.
    private var count = 0

    /// Records one call.
    func bump() {
        count += 1
    }

    /// Returns the observed call count.
    /// - Returns: Number of calls.
    func value() -> Int {
        count
    }
}

/// Collects advisory progress reports from an injected reporter.
private actor ProgressRecorder {
    /// Reports observed in emission order.
    private var reports: [ToolProgress] = []

    /// Records one report.
    /// - Parameter progress: Report emitted by the indexer.
    func record(_ progress: ToolProgress) {
        reports.append(progress)
    }

    /// Returns the observed reports.
    /// - Returns: Reports in emission order.
    func snapshot() -> [ToolProgress] {
        reports
    }
}

/// Records the exclusive upper bound of every message page in call order.
///
/// A nil entry is the newest window; a non-nil entry is a downward backfill
/// page requesting only UIDs below the bound. The count doubles as the page
/// count for steady-state and repeated-page assertions.
private actor BoundRecorder {
    /// Bounds observed in call order.
    private var bounds: [Int?] = []

    /// Records one page bound.
    /// - Parameter bound: Exclusive upper bound, or nil for the newest window.
    func record(_ bound: Int?) {
        bounds.append(bound)
    }

    /// Returns the observed bounds.
    /// - Returns: Bounds in call order.
    func snapshot() -> [Int?] {
        bounds
    }

    /// Returns the number of pages fetched.
    /// - Returns: Page count.
    func count() -> Int {
        bounds.count
    }
}

/// Records inter-page pauses requested by the fetch loop.
///
/// Each entry is the requested pause in nanoseconds, in call order. The count
/// proves the loop pauses once per additional page while the values prove the
/// steady one-second pacing.
private actor SleepRecorder {
    /// Pauses observed in call order.
    private var sleeps: [UInt64] = []

    /// Records one pause.
    /// - Parameter nanoseconds: Requested pause in nanoseconds.
    func record(_ nanoseconds: UInt64) {
        sleeps.append(nanoseconds)
    }

    /// Returns the observed pauses.
    /// - Returns: Pauses in call order.
    func snapshot() -> [UInt64] {
        sleeps
    }

    /// Returns the number of pauses observed.
    /// - Returns: Pause count.
    func count() -> Int {
        sleeps.count
    }
}

/// Records search queries and limits seen by the adapter double.
///
/// Capturing the verbatim query proves the adapter emits the exact `UID lo:hi`
/// fixed-window shape without free text, while the limit proves the 50-per-page clamp.
private actor SearchCapture {
    /// Queries observed in call order.
    private var queries: [String] = []
    /// Limits observed in call order.
    private var limits: [Int] = []

    /// Records one search.
    /// - Parameters:
    ///   - query: Verbatim query passed to the bridge.
    ///   - limit: Limit passed to the bridge.
    func record(query: String, limit: Int) {
        queries.append(query)
        limits.append(limit)
    }

    /// Returns the observed queries.
    /// - Returns: Queries in call order.
    func queriesSnapshot() -> [String] {
        queries
    }

    /// Returns the observed limits.
    /// - Returns: Limits in call order.
    func limitsSnapshot() -> [Int] {
        limits
    }
}

/// Error raised when a stub attachment index has no canned part.
private enum StubGatewayError: Error {
    /// No attachment is configured for the requested index.
    case missingAttachment
}

/// Read-only gateway stub returning canned mail without touching IMAP.
private struct StubMailGateway: MailIndexGateway {
    /// Mailboxes reported by `mailboxes`.
    let mailboxNames: [String]
    /// Messages returned by `messages`, already newest-first.
    let messages: [MailIndexMessage]
    /// Attachment bytes returned by `attachment`.
    let attachments: [MailIndexAttachmentData]
    /// Mode recorder shared with the test.
    let recorder: ModeRecorder
    /// Attachment-call counter shared with the test.
    let attachmentCalls: CallRecorder
    /// Page-bound recorder shared with the test.
    let bounds: BoundRecorder
    /// Status snapshot returned by `mailboxStatus`, when set.
    let statusValue: MailIndexMailboxStatus?

    /// Creates a stub gateway.
    /// - Parameters:
    ///   - mailboxNames: Mailboxes reported by the stub.
    ///   - messages: Canned messages in newest-first order.
    ///   - attachments: Canned attachment bytes.
    ///   - recorder: Mode recorder shared with the test.
    ///   - attachmentCalls: Attachment-call counter shared with the test.
    ///   - bounds: Page-bound recorder shared with the test.
    ///   - statusValue: Status snapshot for validity tests, nil means unknown.
    init(
        mailboxNames: [String] = ["INBOX"],
        messages: [MailIndexMessage],
        attachments: [MailIndexAttachmentData] = [],
        recorder: ModeRecorder = ModeRecorder(),
        attachmentCalls: CallRecorder = CallRecorder(),
        bounds: BoundRecorder = BoundRecorder(),
        statusValue: MailIndexMailboxStatus? = nil
    ) {
        self.mailboxNames = mailboxNames
        self.messages = messages
        self.attachments = attachments
        self.recorder = recorder
        self.attachmentCalls = attachmentCalls
        self.bounds = bounds
        self.statusValue = statusValue
    }

    /// Returns the canned mailbox list.
    func mailboxes(credentials _: MailIndexCredentials) async throws -> [String] {
        mailboxNames
    }

    /// Returns the canned status snapshot, defaulting to unknown tokens.
    func mailboxStatus(credentials _: MailIndexCredentials, mailbox _: String) async throws -> MailIndexMailboxStatus {
        statusValue ?? MailIndexMailboxStatus(uidNext: nil, uidValidity: nil)
    }

    /// Returns the canned page for one downward bound and records the fetch mode.
    ///
    /// A nil bound returns the newest window; a present bound returns only
    /// numeric UIDs inside the fixed `UID lo:hi` window derived from the bound,
    /// preserving newest-first order, so the stub models a bridge that honors
    /// bounded-window paging clamped to the requested limit. A bound at the
    /// mailbox start is already exhausted.
    func messages(
        credentials _: MailIndexCredentials,
        mailbox _: String,
        limit: Int,
        mode: MailFetchMode,
        beforeUID: Int? = nil
    ) async throws -> [MailIndexMessage] {
        await recorder.record(mode)
        await bounds.record(beforeUID)
        if let beforeUID {
            let upper = beforeUID - 1
            guard upper >= 1 else { return [] }
            let lower = max(1, upper - EmailIMAPMailIndexGateway.uidWindowWidth + 1)
            let filtered = messages.filter {
                let uid = MailIndexer.uid(of: $0.id)
                return uid > 0 && uid >= lower && uid <= upper
            }
            return Array(filtered.prefix(limit))
        }
        return Array(messages.prefix(limit))
    }

    /// Returns canned attachment bytes and records the fetch mode.
    func attachment(
        credentials _: MailIndexCredentials,
        mailbox _: String,
        messageID _: String,
        attachmentIndex: Int,
        mode: MailFetchMode
    ) async throws -> MailIndexAttachmentData {
        await recorder.record(mode)
        await attachmentCalls.bump()
        guard attachments.indices.contains(attachmentIndex) else {
            throw StubGatewayError.missingAttachment
        }
        return attachments[attachmentIndex]
    }
}

/// Gateway stub modelling a bridge that ignores the downward bound and clamps to one newest window.
///
/// Regardless of the requested `limit` or `beforeUID`, at most `cap` newest
/// messages surface, so a burst larger than the cap leaves an unfetched middle
/// the indexer must hold its watermark over instead of jumping. The ignored
/// bound is what makes the second page repeat the first, exercising the
/// repeated-page stop without duplicate indexing.
private struct ClampedMailGateway: MailIndexGateway {
    /// Canned messages in newest-first order.
    let messages: [MailIndexMessage]
    /// Widest page ever surfaced, regardless of `limit`.
    let cap: Int
    /// Page-bound recorder shared with the test.
    let bounds: BoundRecorder

    /// Creates a clamped gateway.
    /// - Parameters:
    ///   - messages: Canned messages in newest-first order.
    ///   - cap: Widest page ever surfaced.
    ///   - bounds: Page-bound recorder shared with the test.
    init(messages: [MailIndexMessage], cap: Int, bounds: BoundRecorder = BoundRecorder()) {
        self.messages = messages
        self.cap = cap
        self.bounds = bounds
    }

    /// Returns at most `cap` newest canned messages.
    func mailboxes(credentials _: MailIndexCredentials) async throws -> [String] {
        ["INBOX"]
    }

    /// Returns the clamped newest window, ignoring the downward bound.
    func messages(
        credentials _: MailIndexCredentials,
        mailbox _: String,
        limit: Int,
        mode _: MailFetchMode,
        beforeUID: Int? = nil
    ) async throws -> [MailIndexMessage] {
        await bounds.record(beforeUID)
        return Array(messages.prefix(min(limit, cap)))
    }

    /// Never serves attachment bytes; the hold test uses attachment-free mail.
    func attachment(
        credentials _: MailIndexCredentials,
        mailbox _: String,
        messageID _: String,
        attachmentIndex _: Int,
        mode _: MailFetchMode
    ) async throws -> MailIndexAttachmentData {
        throw StubGatewayError.missingAttachment
    }
}

/// Gateway double capturing the verbatim search query the adapter emits.
///
/// Proves the adapter's `UID lo:hi` fixed-window shape reaches the bridge
/// without free text while still clamping to one page. Hits are canned
/// newest-first; the fetch path returns a synthesized body so the adapter can
/// complete the page.
private struct CapturingIMAPGateway: EmailIMAPGateway, Sendable {
    /// Hits returned by `search`, already newest-first.
    let hits: [EmailSearchHit]
    /// Capture box for queries and limits.
    let capture: SearchCapture
    /// Status snapshot returned for the newest-window anchor.
    let statusValue: EmailMailboxStatus

    /// Creates a capturing gateway.
    /// - Parameters:
    ///   - hits: Canned hits in newest-first order.
    ///   - capture: Box receiving queries and limits.
    ///   - statusValue: Status snapshot anchoring the first window.
    init(
        hits: [EmailSearchHit] = [],
        capture: SearchCapture,
        statusValue: EmailMailboxStatus = EmailMailboxStatus(mailbox: "INBOX", uidNext: 1001, uidValidity: 1)
    ) {
        self.hits = hits
        self.capture = capture
        self.statusValue = statusValue
    }

    /// Lists one mailbox without touching the network.
    func mailboxListing(credentials _: ResolvedEmailCredentials) async throws -> EmailMailboxListing {
        EmailMailboxListing(mailboxes: ["INBOX"], delimiter: "/")
    }

    /// Returns the canned STATUS snapshot anchoring the first fixed window.
    func status(credentials _: ResolvedEmailCredentials, mailbox _: String) async throws -> EmailMailboxStatus {
        statusValue
    }

    /// Records the verbatim query and returns the clamped newest slice.
    func search(
        credentials _: ResolvedEmailCredentials,
        mailbox: String,
        query: String,
        limit: Int
    ) async throws -> [EmailSearchHit] {
        await capture.record(query: query, limit: limit)
        return Array(hits.prefix(limit)).map {
            EmailSearchHit(
                id: $0.id,
                subject: $0.subject,
                from: $0.from,
                date: $0.date,
                snippet: $0.snippet,
                mailbox: mailbox,
                hasAttachments: $0.hasAttachments,
                attachmentCount: $0.attachmentCount
            )
        }
    }

    /// Records the verbatim query for the filtered overload as well.
    func search(
        credentials _: ResolvedEmailCredentials,
        mailbox: String,
        query: String,
        limit: Int,
        hasAttachment: Bool?
    ) async throws -> [EmailSearchHit] {
        await capture.record(query: query, limit: limit)
        let filtered = hits.filter { $0.matches(hasAttachment: hasAttachment) }
        return Array(filtered.prefix(limit)).map {
            EmailSearchHit(
                id: $0.id,
                subject: $0.subject,
                from: $0.from,
                date: $0.date,
                snippet: $0.snippet,
                mailbox: mailbox,
                hasAttachments: $0.hasAttachments,
                attachmentCount: $0.attachmentCount
            )
        }
    }

    /// Returns a synthesized body for every hit so the adapter completes.
    func fetch(credentials _: ResolvedEmailCredentials, mailbox _: String, messageID: String) async throws -> EmailFullMessage {
        EmailFullMessage(
            id: messageID,
            subject: "Subject \(messageID)",
            from: "sender@example.com",
            to: "you@example.com",
            date: "Mon, 01 Sep 2025 09:00:00 +0000",
            body: "Body \(messageID)"
        )
    }

    /// Never serves attachment bytes; the criterion tests use attachment-free mail.
    func attachment(
        credentials _: ResolvedEmailCredentials,
        mailbox _: String,
        messageID _: String,
        attachmentIndex _: Int
    ) async throws -> EmailAttachmentData {
        throw EmailIMAPError.bridgeFailed("no attachment")
    }

    /// Append stub satisfying the gateway contract; the adapter tests never append.
    func append(credentials _: ResolvedEmailCredentials, mailbox _: String, rawMessage _: Data) async throws {}
}

/// Paging gateway whose second page sleeps cancellably so a mid-backfill cancel lands deterministically.
///
/// The first page returns immediately; the second page parks in a cancellable
/// sleep that the test aborts, proving the downward loop stops at the next
/// checkpoint instead of draining the mailbox.
private struct CancellablePagingGateway: MailIndexGateway {
    /// Messages backing every page, already newest-first.
    let messages: [MailIndexMessage]

    /// Returns the first page immediately and parks cancellably on later pages.
    func mailboxes(credentials _: MailIndexCredentials) async throws -> [String] {
        ["INBOX"]
    }

    /// Serves the downward fixed-window page, sleeping cancellably past the first window.
    func messages(
        credentials _: MailIndexCredentials,
        mailbox _: String,
        limit: Int,
        mode _: MailFetchMode,
        beforeUID: Int? = nil
    ) async throws -> [MailIndexMessage] {
        if beforeUID != nil {
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
        if let beforeUID {
            let upper = beforeUID - 1
            guard upper >= 1 else { return [] }
            let lower = max(1, upper - EmailIMAPMailIndexGateway.uidWindowWidth + 1)
            let filtered = messages.filter {
                let uid = MailIndexer.uid(of: $0.id)
                return uid > 0 && uid >= lower && uid <= upper
            }
            return Array(filtered.prefix(limit))
        }
        return Array(messages.prefix(limit))
    }

    /// Never serves attachment bytes; the cancellation test uses attachment-free mail.
    func attachment(
        credentials _: MailIndexCredentials,
        mailbox _: String,
        messageID _: String,
        attachmentIndex _: Int,
        mode _: MailFetchMode
    ) async throws -> MailIndexAttachmentData {
        throw StubGatewayError.missingAttachment
    }
}

/// Probe error carrying a fixed message for retry classification checks.
///
/// The message surfaces as the localized description so the classifier sees
/// the same text a live transport or authentication failure would carry.
private struct RetryProbeError: LocalizedError {
    /// Message surfaced as the localized description.
    let message: String

    /// Creates a probe error.
    /// - Parameter message: Localized description for the probe.
    init(message: String) {
        self.message = message
    }

    /// Human-readable message without any secret value.
    var errorDescription: String? {
        message
    }
}

/// Gateway double failing a fixed number of fetches before succeeding.
///
/// Leading `messages` calls throw a probe error with the configured message;
/// later calls serve the canned newest window. The attempt counter doubles as
/// the fetch count for retry assertions.
private struct RetryProbeGateway: MailIndexGateway {
    /// Messages returned once the configured failures are exhausted.
    let probeMessages: [MailIndexMessage]
    /// Number of leading fetches that throw before succeeding.
    let failuresBeforeSuccess: Int
    /// Message for the thrown probe error.
    let failureMessage: String
    /// Counter for message fetch calls.
    let attempts: CallRecorder

    /// Creates a retry probe gateway.
    /// - Parameters:
    ///   - probeMessages: Canned messages in newest-first order.
    ///   - failuresBeforeSuccess: Leading fetches that throw.
    ///   - failureMessage: Message for the thrown probe error.
    ///   - attempts: Counter shared with the test.
    init(
        probeMessages: [MailIndexMessage],
        failuresBeforeSuccess: Int,
        failureMessage: String,
        attempts: CallRecorder = CallRecorder()
    ) {
        self.probeMessages = probeMessages
        self.failuresBeforeSuccess = failuresBeforeSuccess
        self.failureMessage = failureMessage
        self.attempts = attempts
    }

    /// Returns the canned mailbox list.
    func mailboxes(credentials _: MailIndexCredentials) async throws -> [String] {
        ["INBOX"]
    }

    /// Throws for the configured leading fetches, then serves the canned window.
    func messages(
        credentials _: MailIndexCredentials,
        mailbox _: String,
        limit: Int,
        mode _: MailFetchMode,
        beforeUID: Int? = nil
    ) async throws -> [MailIndexMessage] {
        await attempts.bump()
        let count = await attempts.value()
        if count <= failuresBeforeSuccess {
            throw RetryProbeError(message: failureMessage)
        }
        if let beforeUID {
            let upper = beforeUID - 1
            guard upper >= 1 else { return [] }
            let lower = max(1, upper - EmailIMAPMailIndexGateway.uidWindowWidth + 1)
            let filtered = probeMessages.filter {
                let uid = MailIndexer.uid(of: $0.id)
                return uid > 0 && uid >= lower && uid <= upper
            }
            return Array(filtered.prefix(limit))
        }
        return Array(probeMessages.prefix(limit))
    }

    /// Never serves attachment bytes; the retry tests use attachment-free mail.
    func attachment(
        credentials _: MailIndexCredentials,
        mailbox _: String,
        messageID _: String,
        attachmentIndex _: Int,
        mode _: MailFetchMode
    ) async throws -> MailIndexAttachmentData {
        throw StubGatewayError.missingAttachment
    }
}

/// Deterministic embeddings backend for the vector-window tests.
private struct StubEmbeddings: EmbeddingsBackend {
    /// Stable model identifier.
    let modelID = "stub"
    /// Fixed embedding width.
    let dimension: Int? = 3

    /// Returns one fixed vector per input.
    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { _ in [0.1, 0.2, 0.3] }
    }
}

/// Records pooled session open plus close calls per mailbox.
///
/// Each entry is `account/mailbox` so the bracket count asserts without
/// touching the network. The inbox never leaks: every open pairs with a close
/// except an open failure, which never reaches the close.
private actor SessionOpenCloseRecorder {
    /// Opens observed in call order.
    private var opens: [String] = []
    /// Closes observed in call order.
    private var closes: [String] = []

    /// Records one open.
    /// - Parameter key: Account plus mailbox key.
    func recordOpen(_ key: String) {
        opens.append(key)
    }

    /// Records one close.
    /// - Parameter key: Account plus mailbox key.
    func recordClose(_ key: String) {
        closes.append(key)
    }

    /// Returns the observed opens.
    /// - Returns: Opens in call order.
    func opensSnapshot() -> [String] {
        opens
    }

    /// Returns the observed closes.
    /// - Returns: Closes in call order.
    func closesSnapshot() -> [String] {
        closes
    }
}

/// Gateway double recording the session bracket the indexer owns.
///
/// Messages serve canned per-mailbox windows; an injected open or message
/// failure message exercises the skip path while the recorder proves the
/// bracket still opened plus closed exactly once.
private struct RecordingSessionGateway: MailIndexGateway {
    /// Mailboxes reported by `mailboxes`.
    let mailboxNames: [String]
    /// Canned messages per mailbox, already newest-first.
    let perMailbox: [String: [MailIndexMessage]]
    /// Bracket recorder shared with the test.
    let recorder: SessionOpenCloseRecorder
    /// Failure message thrown by `openMailboxSession` when set.
    let openFailureMessage: String?
    /// Failure message thrown by `messages` when set.
    let messagesFailureMessage: String?
    /// Counter for message page calls.
    let messageCalls: CallRecorder

    /// Creates a recording gateway.
    /// - Parameters:
    ///   - mailboxNames: Mailboxes reported by the stub.
    ///   - perMailbox: Canned messages per mailbox.
    ///   - recorder: Bracket recorder shared with the test.
    ///   - openFailureMessage: Failure message thrown by open when set.
    ///   - messagesFailureMessage: Failure message thrown by messages when set.
    ///   - messageCalls: Counter shared with the test.
    init(
        mailboxNames: [String] = ["INBOX"],
        perMailbox: [String: [MailIndexMessage]] = [:],
        recorder: SessionOpenCloseRecorder,
        openFailureMessage: String? = nil,
        messagesFailureMessage: String? = nil,
        messageCalls: CallRecorder = CallRecorder()
    ) {
        self.mailboxNames = mailboxNames
        self.perMailbox = perMailbox
        self.recorder = recorder
        self.openFailureMessage = openFailureMessage
        self.messagesFailureMessage = messagesFailureMessage
        self.messageCalls = messageCalls
    }

    /// Returns the canned mailbox list.
    func mailboxes(credentials _: MailIndexCredentials) async throws -> [String] {
        mailboxNames
    }

    /// Records the open and optionally throws the injected failure.
    func openMailboxSession(credentials: MailIndexCredentials, mailbox: String) async throws {
        await recorder.recordOpen("\(credentials.accountName)/\(mailbox)")
        if let openFailureMessage {
            throw RetryProbeError(message: openFailureMessage)
        }
    }

    /// Records the close, no-op when absent by construction.
    func closeMailboxSession(credentials: MailIndexCredentials, mailbox: String) async {
        await recorder.recordClose("\(credentials.accountName)/\(mailbox)")
    }

    /// Serves the canned window or throws the injected failure.
    func messages(
        credentials _: MailIndexCredentials,
        mailbox: String,
        limit: Int,
        mode _: MailFetchMode,
        beforeUID _: Int? = nil
    ) async throws -> [MailIndexMessage] {
        await messageCalls.bump()
        if let messagesFailureMessage {
            throw RetryProbeError(message: messagesFailureMessage)
        }
        return Array((perMailbox[mailbox] ?? []).prefix(limit))
    }

    /// Never serves attachment bytes; the bracket tests use attachment-free mail.
    func attachment(
        credentials _: MailIndexCredentials,
        mailbox _: String,
        messageID _: String,
        attachmentIndex _: Int,
        mode _: MailFetchMode
    ) async throws -> MailIndexAttachmentData {
        throw StubGatewayError.missingAttachment
    }
}

/// Gateway double parking cancellably on later pages while recording the bracket.
///
/// The first page returns immediately; later pages sleep so a mid-backfill
/// cancel lands deterministically with the session still closed once.
private struct CancellableSessionGateway: MailIndexGateway {
    /// Messages backing every page, already newest-first.
    let messages: [MailIndexMessage]
    /// Bracket recorder shared with the test.
    let recorder: SessionOpenCloseRecorder

    /// Creates a cancellable gateway.
    /// - Parameters:
    ///   - messages: Canned messages in newest-first order.
    ///   - recorder: Bracket recorder shared with the test.
    init(messages: [MailIndexMessage], recorder: SessionOpenCloseRecorder) {
        self.messages = messages
        self.recorder = recorder
    }

    /// Returns one mailbox without touching the network.
    func mailboxes(credentials _: MailIndexCredentials) async throws -> [String] {
        ["INBOX"]
    }

    /// Records the open.
    func openMailboxSession(credentials: MailIndexCredentials, mailbox: String) async throws {
        await recorder.recordOpen("\(credentials.accountName)/\(mailbox)")
    }

    /// Records the close.
    func closeMailboxSession(credentials: MailIndexCredentials, mailbox: String) async {
        await recorder.recordClose("\(credentials.accountName)/\(mailbox)")
    }

    /// Serves the first page at once and parks cancellably past it.
    func messages(
        credentials _: MailIndexCredentials,
        mailbox _: String,
        limit: Int,
        mode _: MailFetchMode,
        beforeUID: Int? = nil
    ) async throws -> [MailIndexMessage] {
        if beforeUID != nil {
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
        if let beforeUID {
            let upper = beforeUID - 1
            guard upper >= 1 else { return [] }
            let lower = max(1, upper - EmailIMAPMailIndexGateway.uidWindowWidth + 1)
            let filtered = messages.filter {
                let uid = MailIndexer.uid(of: $0.id)
                return uid > 0 && uid >= lower && uid <= upper
            }
            return Array(filtered.prefix(limit))
        }
        return Array(messages.prefix(limit))
    }

    /// Never serves attachment bytes; the cancellation test uses attachment-free mail.
    func attachment(
        credentials _: MailIndexCredentials,
        mailbox _: String,
        messageID _: String,
        attachmentIndex _: Int,
        mode _: MailFetchMode
    ) async throws -> MailIndexAttachmentData {
        throw StubGatewayError.missingAttachment
    }
}

// MARK: - Helpers

/// Creates an isolated temporary base directory.
/// - Returns: A fresh directory URL.
private func makeTempBase() -> URL {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("runeweaver-mailindex-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
}

/// Builds a canned message for the stub gateway.
private func makeMessage(
    id: String,
    subject: String = "Subject",
    body: String,
    date: Date? = Date(timeIntervalSince1970: 1_700_000_000),
    attachments: [MailIndexAttachmentInfo] = [],
    sizeBytes: Int? = nil
) -> MailIndexMessage {
    MailIndexMessage(
        id: id,
        subject: subject,
        from: "sender@example.com",
        date: date,
        body: body,
        attachments: attachments,
        sizeBytes: sizeBytes
    )
}

/// Builds an indexer over the shared test account and index policy.
private func makeIndexer(
    gateway: any MailIndexGateway,
    store: DocIndexStore,
    checkpoints: MailIndexCheckpointStore,
    window: String = "2y",
    budget: Int = 0,
    maxFileMB: Int = 20,
    embedder: (any EmbeddingsBackend)? = nil,
    stagingRoot: URL? = nil,
    now: @escaping @Sendable () -> Date = { Date() }
) -> MailIndexer {
    MailIndexer(
        emailConfig: EmailConfig(accounts: [testAccount]),
        indexConfig: IndexConfig(
            enabled: true,
            mail: true,
            maxFileMB: maxFileMB,
            mailVectorWindow: window,
            nightlyBudget: budget
        ),
        gateway: gateway,
        store: store,
        embedder: embedder,
        checkpoints: checkpoints,
        stagingRoot: stagingRoot,
        now: now
    )
}

/// Installs the test account password in the environment for the duration of `body`.
private func withTestPassword(_ body: () async throws -> Void) async rethrows {
    let key = testAccount.passwordEnvVar
    let saved = getenv(key).map { String(cString: $0) }
    setenv(key, "test-secret-value", 1)
    defer {
        if let saved {
            setenv(key, saved, 1)
        } else {
            unsetenv(key)
        }
    }
    try await body()
}

// MARK: - Suite

@Suite("Mail Indexer", .serialized)
struct MailIndexerTests {
    @Test
    func `Disabled mail indexing skips the run without dialing the gateway`() async throws {
        let base = makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let recorder = ModeRecorder()
        let indexer = MailIndexer(
            emailConfig: EmailConfig(accounts: [testAccount]),
            indexConfig: IndexConfig(enabled: false, mail: true),
            gateway: StubMailGateway(messages: [makeMessage(id: "1", body: "hello")], recorder: recorder),
            store: DocIndexStore(dbPath: base.appendingPathComponent("index.db").path),
            checkpoints: MailIndexCheckpointStore(path: base.appendingPathComponent("cp.json").path)
        )

        let report = try await indexer.run()

        #expect(report.didRun == false)
        let modes = await recorder.snapshot()
        #expect(modes.isEmpty)
    }

    @Test
    func `Watermark advances so a later run indexes only new mail`() async throws {
        let base = makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: base.appendingPathComponent("index.db").path)
        let checkpoints = MailIndexCheckpointStore(path: base.appendingPathComponent("cp.json").path)

        try await withTestPassword {
            let first = makeIndexer(
                gateway: StubMailGateway(messages: [
                    makeMessage(id: "1", body: "one"),
                    makeMessage(id: "2", body: "two")
                ]),
                store: store,
                checkpoints: checkpoints
            )
            let firstReport = try await first.run()
            #expect(firstReport.messagesIndexed == 2)
            let firstWatermark = await checkpoints.watermark(account: testAccount.name, mailbox: "INBOX")
            #expect(firstWatermark == 2)

            // The second run offers the same newest page; the persisted
            // watermark means only the newly arrived UID is considered.
            let second = makeIndexer(
                gateway: StubMailGateway(messages: [
                    makeMessage(id: "1", body: "one"),
                    makeMessage(id: "2", body: "two"),
                    makeMessage(id: "3", body: "three")
                ]),
                store: store,
                checkpoints: checkpoints
            )
            let secondReport = try await second.run()
            #expect(secondReport.messagesSeen == 1)
            #expect(secondReport.messagesIndexed == 1)
            let secondWatermark = await checkpoints.watermark(account: testAccount.name, mailbox: "INBOX")
            #expect(secondWatermark == 3)
        }
    }

    @Test
    func `Burst larger than one page indexes every new message without skipping the middle`() async throws {
        let base = makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: base.appendingPathComponent("index.db").path)
        let checkpoints = MailIndexCheckpointStore(path: base.appendingPathComponent("cp.json").path)

        try await withTestPassword {
            let seed = makeIndexer(
                gateway: StubMailGateway(messages: Array((1 ... 10).map {
                    makeMessage(id: "\($0)", body: "seed body \($0)")
                }.reversed())),
                store: store,
                checkpoints: checkpoints
            )
            let seedReport = try await seed.run()
            #expect(seedReport.messagesIndexed == 10)

            // Seventy arrivals exceed the 50-message page; the fixed windows
            // tile downward to the watermark so the middle is indexed too.
            let burst = makeIndexer(
                gateway: StubMailGateway(messages: Array((11 ... 80).map {
                    makeMessage(id: "\($0)", body: "burst body \($0)")
                }.reversed())),
                store: store,
                checkpoints: checkpoints
            )
            let burstReport = try await burst.run()
            #expect(burstReport.messagesSeen == 70)
            #expect(burstReport.messagesIndexed == 70)
            let watermark = await checkpoints.watermark(account: testAccount.name, mailbox: "INBOX")
            #expect(watermark == 80)
            let stats = try await store.stats()
            #expect(stats.documents == 80)
            // A middle UID jumped over by the old newest-page-only fetch stays indexed.
            let middleID = MailIndexer.documentExternalID(
                account: testAccount.name,
                mailbox: "INBOX",
                messageID: "15"
            )
            let middle = try await store.document(source: .mail, externalID: middleID)
            #expect(middle != nil)
        }
    }

    @Test
    func `Clamped gateway holds the watermark instead of jumping the unfetched middle`() async throws {
        let base = makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: base.appendingPathComponent("index.db").path)
        let checkpoints = MailIndexCheckpointStore(path: base.appendingPathComponent("cp.json").path)

        try await withTestPassword {
            let seed = makeIndexer(
                gateway: StubMailGateway(messages: Array((1 ... 40).map {
                    makeMessage(id: "\($0)", body: "seed body \($0)")
                }.reversed())),
                store: store,
                checkpoints: checkpoints
            )
            _ = try await seed.run()

            // Sixty newer UIDs arrive but the gateway only ever surfaces the
            // newest fifty, leaving UIDs 41-50 unfetched. The watermark must
            // hold at 40 so they stay eligible instead of being skipped.
            let clamped = makeIndexer(
                gateway: ClampedMailGateway(
                    messages: Array((41 ... 100).map {
                        makeMessage(id: "\($0)", body: "clamped body \($0)")
                    }.reversed()),
                    cap: MailIndexer.pageLimit
                ),
                store: store,
                checkpoints: checkpoints
            )
            let report = try await clamped.run()
            #expect(report.messagesSeen == 50)
            #expect(report.messagesIndexed == 50)
            let watermark = await checkpoints.watermark(account: testAccount.name, mailbox: "INBOX")
            #expect(watermark == 40)
            #expect(!report.warnings.isEmpty)
            #expect(report.warnings.contains(
                "Mailbox 'INBOX' has more new messages than the gateway's widest page; "
                    + "indexed the newest 50 and held the watermark at 40 "
                    + "so older arrivals stay pending instead of being skipped."
            ))
        }
    }

    @Test
    func `Every gateway fetch requests PEEK so mail is never marked seen`() async throws {
        let base = makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let recorder = ModeRecorder()
        let info = MailIndexAttachmentInfo(filename: "notes.txt", contentType: "text/plain")
        let attachment = MailIndexAttachmentData(
            filename: "notes.txt",
            contentType: "text/plain",
            sizeBytes: 9,
            data: Data("peek body".utf8)
        )

        try await withTestPassword {
            let indexer = makeIndexer(
                gateway: StubMailGateway(
                    messages: [makeMessage(id: "1", body: "body", attachments: [info])],
                    attachments: [attachment],
                    recorder: recorder
                ),
                store: DocIndexStore(dbPath: base.appendingPathComponent("index.db").path),
                checkpoints: MailIndexCheckpointStore(path: base.appendingPathComponent("cp.json").path)
            )
            _ = try await indexer.run()
        }

        let modes = await recorder.snapshot()
        #expect(!modes.isEmpty)
        #expect(modes.allSatisfy { $0 == .peek })
    }

    @Test
    func `Oversized attachments are skipped without a fetch`() async throws {
        let base = makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let calls = CallRecorder()
        let oversized = MailIndexAttachmentInfo(
            filename: "big.bin",
            contentType: "application/octet-stream",
            sizeBytes: 21 * 1024 * 1024
        )

        try await withTestPassword {
            let indexer = makeIndexer(
                gateway: StubMailGateway(
                    messages: [makeMessage(id: "1", body: "body", attachments: [oversized])],
                    recorder: ModeRecorder(),
                    attachmentCalls: calls
                ),
                store: DocIndexStore(dbPath: base.appendingPathComponent("index.db").path),
                checkpoints: MailIndexCheckpointStore(path: base.appendingPathComponent("cp.json").path)
            )
            let report = try await indexer.run()
            #expect(report.attachmentsSkippedOversize == 1)
            #expect(report.attachmentsStaged == 0)
        }

        let callCount = await calls.value()
        #expect(callCount == 0)
    }

    @Test
    func `Forwarded duplicates are deduplicated by content hash`() async throws {
        let base = makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: base.appendingPathComponent("index.db").path)
        let sharedBody = "same forwarded body text"

        try await withTestPassword {
            let indexer = makeIndexer(
                gateway: StubMailGateway(messages: [
                    makeMessage(id: "1", body: sharedBody),
                    makeMessage(id: "2", body: sharedBody)
                ]),
                store: store,
                checkpoints: MailIndexCheckpointStore(path: base.appendingPathComponent("cp.json").path)
            )
            let report = try await indexer.run()
            #expect(report.messagesIndexed == 1)
            #expect(report.messagesDeduplicated == 1)
            let stats = try await store.stats()
            #expect(stats.documents == 1)
        }
    }

    @Test
    func `Mail older than the vector window stays keyword-only`() async throws {
        let base = makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: base.appendingPathComponent("index.db").path)
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let recent = makeMessage(id: "1", body: "recentmailtoken unique", date: fixedNow)
        let old = makeMessage(
            id: "2",
            body: "oldmailtoken unique",
            date: fixedNow.addingTimeInterval(-400 * 86400)
        )

        try await withTestPassword {
            let indexer = makeIndexer(
                gateway: StubMailGateway(messages: [recent, old]),
                store: store,
                checkpoints: MailIndexCheckpointStore(path: base.appendingPathComponent("cp.json").path),
                window: "30d",
                embedder: StubEmbeddings(),
                now: { fixedNow }
            )
            let report = try await indexer.run()
            #expect(report.vectorsWritten >= 1)
        }

        let recentChunks = try await store.searchKeyword(query: "recentmailtoken", limit: 10)
        let oldChunks = try await store.searchKeyword(query: "oldmailtoken", limit: 10)
        #expect(!recentChunks.isEmpty)
        let recentAllVector = recentChunks.allSatisfy(\.isVector)
        #expect(recentAllVector)
        #expect(!oldChunks.isEmpty)
        #expect(oldChunks.allSatisfy { !$0.isVector })
    }

    @Test
    func `Staged attachment bytes are deleted after extraction`() async throws {
        let base = makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let staging = base.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let store = DocIndexStore(dbPath: base.appendingPathComponent("index.db").path)
        let info = MailIndexAttachmentInfo(filename: "notes.txt", contentType: "text/plain")
        let bytes = Data("attachmenttexttoken unique body".utf8)
        let attachment = MailIndexAttachmentData(
            filename: "notes.txt",
            contentType: "text/plain",
            sizeBytes: bytes.count,
            data: bytes
        )

        try await withTestPassword {
            let indexer = makeIndexer(
                gateway: StubMailGateway(
                    messages: [makeMessage(id: "1", body: "body", attachments: [info])],
                    attachments: [attachment]
                ),
                store: store,
                checkpoints: MailIndexCheckpointStore(path: base.appendingPathComponent("cp.json").path),
                stagingRoot: staging
            )
            let report = try await indexer.run()
            #expect(report.attachmentsStaged == 1)
            let leftover = try FileManager.default.contentsOfDirectory(atPath: staging.path)
            #expect(leftover.isEmpty)
            let chunks = try await store.searchKeyword(query: "attachmenttexttoken", limit: 10)
            #expect(!chunks.isEmpty)
        }
    }

    @Test
    func `Unreadable PDF attachments are marked for the vision path`() async throws {
        let base = makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: base.appendingPathComponent("index.db").path)
        let info = MailIndexAttachmentInfo(filename: "scan.pdf", contentType: "application/pdf", sizeBytes: 30)
        let bytes = Data("this is not a real pdf document".utf8)
        let attachment = MailIndexAttachmentData(
            filename: "scan.pdf",
            contentType: "application/pdf",
            sizeBytes: bytes.count,
            data: bytes
        )

        try await withTestPassword {
            let indexer = makeIndexer(
                gateway: StubMailGateway(
                    messages: [makeMessage(id: "1", body: "body text", attachments: [info])],
                    attachments: [attachment]
                ),
                store: store,
                checkpoints: MailIndexCheckpointStore(path: base.appendingPathComponent("cp.json").path)
            )
            let report = try await indexer.run()
            #expect(report.attachmentsMetadataOnly == 1)
            let externalID = MailIndexer.documentExternalID(
                account: testAccount.name,
                mailbox: "INBOX",
                messageID: "1"
            )
            let document = try await store.document(source: .mail, externalID: externalID)
            #expect(document?.metadata["attachment.0.vision"] != nil)
        }
    }

    @Test
    func `Progress is reported through the injected reporter`() async throws {
        let base = makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let recorder = ProgressRecorder()

        try await withTestPassword {
            let indexer = makeIndexer(
                gateway: StubMailGateway(messages: [makeMessage(id: "1", body: "progress body")]),
                store: DocIndexStore(dbPath: base.appendingPathComponent("index.db").path),
                checkpoints: MailIndexCheckpointStore(path: base.appendingPathComponent("cp.json").path)
            )
            _ = try await indexer.run(reporter: { progress in await recorder.record(progress) })
        }

        let reports = await recorder.snapshot()
        #expect(!reports.isEmpty)
    }

    @Test
    func `Vector window parsing maps tokens to cutoffs`() {
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(MailVectorWindow(token: "all").cutoff(now: fixedNow) == nil)
        let window = MailVectorWindow(token: "30d")
        #expect(window.cutoff(now: fixedNow) != nil)
        #expect(window.includes(date: fixedNow, now: fixedNow))
        #expect(!window.includes(date: fixedNow.addingTimeInterval(-31 * 86400), now: fixedNow))
        // An unknown token falls back to the bounded default rather than opening the window.
        #expect(MailVectorWindow(token: "carrier-pigeon").cutoff(now: fixedNow) != nil)
        // The two-year token is the documented default; pin it explicitly so
        // the closed set and the parser cannot drift apart.
        #expect(MailVectorWindow(token: "2y") == .trailing(days: 730))
        #expect(MailVectorWindow(token: IndexConfig.defaultMailVectorWindow) == .trailing(days: 730))
        #expect(
            MailVectorWindow(token: "2y").cutoff(now: fixedNow)
                == fixedNow.addingTimeInterval(-730 * 86400)
        )
    }

    @Test
    func `Adapter builds fixed UID window from integers only`() {
        #expect(EmailIMAPMailIndexGateway.uidWindowWidth == 1000)
        // Small tops clamp to the mailbox start.
        #expect(EmailIMAPMailIndexGateway.uidRangeCriterion(beforeUID: 51) == "UID 1:50")
        #expect(EmailIMAPMailIndexGateway.uidRangeCriterion(beforeUID: 2) == "UID 1:1")
        // Large tops slide a fixed 1000-wide window, never an open-ended range.
        #expect(EmailIMAPMailIndexGateway.uidRangeCriterion(beforeUID: 2001) == "UID 1001:2000")
        #expect(EmailIMAPMailIndexGateway.uidRangeCriterion(beforeUID: 1501) == "UID 501:1500")
        // Bottom clamping keeps the first window inside the mailbox.
        #expect(EmailIMAPMailIndexGateway.uidRangeCriterion(beforeUID: 1001) == "UID 1:1000")
        #expect(EmailIMAPMailIndexGateway.uidRangeCriterion(beforeUID: 500) == "UID 1:499")
        // Integer-only construction: no caller text can reach the wire.
        let windowed = EmailIMAPMailIndexGateway.uidRangeCriterion(beforeUID: 2001) ?? ""
        #expect(windowed.hasPrefix("UID "))
        let range = windowed.dropFirst(4)
        let parts = range.split(separator: ":")
        #expect(parts.count == 2)
        #expect(Int(parts[0]) != nil)
        #expect(Int(parts[1]) != nil)
        #expect((Int(parts[1]) ?? 0) - (Int(parts[0]) ?? 0) + 1 <= EmailIMAPMailIndexGateway.uidWindowWidth)
        // A bound at the mailbox start holds no UIDs, so there is no criterion to issue.
        #expect(EmailIMAPMailIndexGateway.uidRangeCriterion(beforeUID: 1) == nil)
        #expect(EmailIMAPMailIndexGateway.uidRangeCriterion(beforeUID: 0) == nil)
        #expect(EmailIMAPMailIndexGateway.uidRangeCriterion(beforeUID: -4) == nil)
    }

    @Test
    func `Adapter issues verbatim UID window with clamped page`() async throws {
        let capture = SearchCapture()
        let hits = (1 ... 5).map {
            EmailSearchHit(
                id: "\($0)",
                subject: "Subject",
                from: "sender@example.com",
                date: "Mon, 01 Sep 2025 09:00:00 +0000",
                snippet: "snippet"
            )
        }
        let gateway = CapturingIMAPGateway(hits: hits, capture: capture)
        let adapter = EmailIMAPMailIndexGateway(gateway: gateway)
        let credentials = MailIndexCredentials(
            accountName: "mailtest",
            host: "imap.example.com",
            port: 993,
            username: "user@example.com",
            password: "test-secret"
        )
        // A present bound must reach the bridge as the exact window shape with
        // no free text, still clamped to one newest page.
        _ = try await adapter.messages(
            credentials: credentials,
            mailbox: "INBOX",
            limit: 50,
            mode: .peek,
            beforeUID: 51
        )
        let queries = await capture.queriesSnapshot()
        let limits = await capture.limitsSnapshot()
        #expect(queries == ["UID 1:50"])
        #expect(limits == [50])
        // An oversized limit stays clamped to the bridge page cap.
        _ = try await adapter.messages(
            credentials: credentials,
            mailbox: "INBOX",
            limit: 500,
            mode: .peek,
            beforeUID: 11
        )
        let queriesAfter = await capture.queriesSnapshot()
        let limitsAfter = await capture.limitsSnapshot()
        #expect(queriesAfter.count == 2)
        #expect(queriesAfter[1] == "UID 1:10")
        #expect(limitsAfter[1] == EmailSearchArgs.maxLimit)
        // A large bound slides a fixed 1000-wide window, proving the shape is
        // bounded instead of open-ended.
        _ = try await adapter.messages(
            credentials: credentials,
            mailbox: "INBOX",
            limit: 50,
            mode: .peek,
            beforeUID: 2001
        )
        let queriesWindowed = await capture.queriesSnapshot()
        #expect(queriesWindowed.count == 3)
        #expect(queriesWindowed[2] == "UID 1001:2000")
    }

    @Test
    func `Adapter anchors newest window from STATUS without open SEARCH`() async throws {
        let capture = SearchCapture()
        let status = EmailMailboxStatus(mailbox: "INBOX", uidNext: 2001, uidValidity: 7)
        let gateway = CapturingIMAPGateway(hits: [], capture: capture, statusValue: status)
        let adapter = EmailIMAPMailIndexGateway(gateway: gateway)
        let credentials = MailIndexCredentials(
            accountName: "mailtest",
            host: "imap.example.com",
            port: 993,
            username: "user@example.com",
            password: "test-secret"
        )
        _ = try await adapter.messages(
            credentials: credentials,
            mailbox: "INBOX",
            limit: 10,
            mode: .peek,
            beforeUID: nil
        )
        let queries = await capture.queriesSnapshot()
        // UIDNEXT 2001 anchors hi 2000 with a fixed 1000-wide window, never "".
        #expect(queries == ["UID 1001:2000"])
        #expect(!queries.contains(""))
        // An empty mailbox anchors below the start and returns without dialing.
        let emptyCapture = SearchCapture()
        let emptyGateway = CapturingIMAPGateway(
            hits: [],
            capture: emptyCapture,
            statusValue: EmailMailboxStatus(mailbox: "INBOX", uidNext: 1, uidValidity: 7)
        )
        let emptyAdapter = EmailIMAPMailIndexGateway(gateway: emptyGateway)
        let empty = try await emptyAdapter.messages(
            credentials: credentials,
            mailbox: "INBOX",
            limit: 10,
            mode: .peek,
            beforeUID: nil
        )
        #expect(empty.isEmpty)
        #expect(await emptyCapture.queriesSnapshot().isEmpty)
    }

    @Test
    func `Adapter returns empty without dialing at mailbox start`() async throws {
        let capture = SearchCapture()
        let gateway = CapturingIMAPGateway(hits: [], capture: capture)
        let adapter = EmailIMAPMailIndexGateway(gateway: gateway)
        let credentials = MailIndexCredentials(
            accountName: "mailtest",
            host: "imap.example.com",
            port: 993,
            username: "user@example.com",
            password: "test-secret"
        )
        // A bound at the mailbox start holds no window; the adapter short-circuits instead.
        let messages = try await adapter.messages(
            credentials: credentials,
            mailbox: "INBOX",
            limit: 50,
            mode: .peek,
            beforeUID: 1
        )
        #expect(messages.isEmpty)
        let queries = await capture.queriesSnapshot()
        #expect(queries.isEmpty)
    }

    @Test
    func `Backfill over 200 messages converges with watermark at maximum`() async throws {
        let base = makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: base.appendingPathComponent("index.db").path)
        let checkpoints = MailIndexCheckpointStore(path: base.appendingPathComponent("cp.json").path)
        let bounds = BoundRecorder()
        let all = Array((1 ... 200).map {
            makeMessage(id: "\($0)", body: "backfill body \($0)")
        }.reversed())

        try await withTestPassword {
            let indexer = makeIndexer(
                gateway: StubMailGateway(messages: all, bounds: bounds),
                store: store,
                checkpoints: checkpoints
            )
            let report = try await indexer.run()
            #expect(report.messagesSeen == 200)
            #expect(report.messagesIndexed == 200)
            let watermark = await checkpoints.watermark(account: testAccount.name, mailbox: "INBOX")
            #expect(watermark == 200)
            let stats = try await store.stats()
            #expect(stats.documents == 200)
            // Four fixed pages cover the mailbox: each bound is strictly below
            // the lowest UID already fetched, so pages never overlap and never
            // skip, and every window stays within the 1000-wide bound.
            let observed = await bounds.snapshot()
            #expect(observed.count == 4)
            #expect(observed[0] == nil)
            #expect(observed[1] == 151)
            #expect(observed[2] == 101)
            #expect(observed[3] == 51)
            for bound in observed.compactMap(\.self) {
                let upper = bound - 1
                let lower = max(1, upper - EmailIMAPMailIndexGateway.uidWindowWidth + 1)
                #expect(upper - lower + 1 <= EmailIMAPMailIndexGateway.uidWindowWidth)
            }
        }
    }

    @Test
    func `Steady state with no new mail fetches exactly one page`() async throws {
        let base = makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: base.appendingPathComponent("index.db").path)
        let checkpoints = MailIndexCheckpointStore(path: base.appendingPathComponent("cp.json").path)
        let all = Array((1 ... 200).map {
            makeMessage(id: "\($0)", body: "steady body \($0)")
        }.reversed())

        try await withTestPassword {
            let first = makeIndexer(
                gateway: StubMailGateway(messages: all),
                store: store,
                checkpoints: checkpoints
            )
            _ = try await first.run()
            let watermark = await checkpoints.watermark(account: testAccount.name, mailbox: "INBOX")
            #expect(watermark == 200)

            // No arrivals: the newest page already reaches the watermark, so
            // the run stops after one page with nothing to index.
            let steadyBounds = BoundRecorder()
            let steady = makeIndexer(
                gateway: StubMailGateway(messages: all, bounds: steadyBounds),
                store: store,
                checkpoints: checkpoints
            )
            let report = try await steady.run()
            #expect(report.messagesSeen == 0)
            #expect(report.messagesIndexed == 0)
            let pages = await steadyBounds.count()
            #expect(pages == 1)
            let observed = await steadyBounds.snapshot()
            #expect(observed.count == 1)
            #expect(observed[0] == nil)
        }
    }

    @Test
    func `Repeated page stops without duplicate indexing`() async throws {
        let base = makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: base.appendingPathComponent("index.db").path)
        let checkpoints = MailIndexCheckpointStore(path: base.appendingPathComponent("cp.json").path)
        let bounds = BoundRecorder()
        let all = Array((1 ... 60).map {
            makeMessage(id: "\($0)", body: "repeat body \($0)")
        }.reversed())

        try await withTestPassword {
            // The double ignores the downward bound, so the second page repeats
            // the first. The loop must stop there with one page of unique mail.
            let indexer = makeIndexer(
                gateway: ClampedMailGateway(messages: all, cap: MailIndexer.pageLimit, bounds: bounds),
                store: store,
                checkpoints: checkpoints
            )
            let report = try await indexer.run()
            #expect(report.messagesSeen == 50)
            #expect(report.messagesIndexed == 50)
            let stats = try await store.stats()
            #expect(stats.documents == 50)
            let pages = await bounds.count()
            #expect(pages == 2)
            let observed = await bounds.snapshot()
            #expect(observed.count == 2)
            #expect(observed[0] == nil)
            // The second bound is the lowest UID of the first page, proving
            // the loop lowered the bound before observing the repeat.
            #expect(observed[1] == 11)
        }
    }

    @Test
    func `Mailbox entry and window fetch emit liveness frames`() async throws {
        let base = makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: base.appendingPathComponent("index.db").path)
        let checkpoints = MailIndexCheckpointStore(path: base.appendingPathComponent("cp.json").path)
        let recorder = ProgressRecorder()
        let bodyMarker = "mailbox-liveness-body-token"

        try await withTestPassword {
            let indexer = makeIndexer(
                gateway: StubMailGateway(messages: [
                    makeMessage(id: "2", body: "\(bodyMarker) two"),
                    makeMessage(id: "1", body: "\(bodyMarker) one")
                ]),
                store: store,
                checkpoints: checkpoints
            )
            _ = try await indexer.run(reporter: { progress in await recorder.record(progress) })
        }

        let frames = await recorder.snapshot()
        // Entering, window-fetched, and finished frames surround the fetch so
        // a long IMAP stretch never reads stuck; per-message frames stay
        // throttled and may not appear on a fast run.
        #expect(frames.count >= 3)
        #expect(frames[0].message == "Indexing mail: 0 indexed, 0 scanned")
        #expect(frames[0].scanned == 0)
        #expect(frames[0].matched == 0)
        #expect(frames[0].current == "INBOX")
        #expect(frames[1].message == "Indexing mail: 0 indexed, 0 scanned")
        #expect(frames[1].scanned == 0)
        #expect(frames[1].matched == 0)
        #expect((frames[1].current ?? "").contains("INBOX"))
        #expect((frames[1].current ?? "").contains("2"))
        #expect(frames.last?.message.contains("Mail indexing finished") == true)
        for index in 1 ..< frames.count {
            #expect(frames[index].scanned >= frames[index - 1].scanned)
            #expect(frames[index].matched >= frames[index - 1].matched)
        }
        // No subject or body text ever enters a frame; only the mailbox name does.
        #expect(!frames.contains { $0.message.contains(bodyMarker) })
        #expect(!frames.contains { ($0.current ?? "").contains(bodyMarker) })
        #expect(!frames.contains { $0.message.contains("Subject") })
    }

    @Test
    func `Cancellation mid-backfill stops at the next checkpoint`() async throws {
        let base = makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: base.appendingPathComponent("index.db").path)
        let checkpoints = MailIndexCheckpointStore(path: base.appendingPathComponent("cp.json").path)
        let all = Array((1 ... 200).map {
            makeMessage(id: "\($0)", body: "cancel body \($0)")
        }.reversed())

        try await withTestPassword {
            let indexer = makeIndexer(
                gateway: CancellablePagingGateway(messages: all),
                store: store,
                checkpoints: checkpoints
            )
            let runTask = Task { try await indexer.run() }
            // Let the first page return, then cancel while the second page
            // parks in its cancellable sleep.
            try await Task.sleep(nanoseconds: 200_000_000)
            runTask.cancel()
            do {
                _ = try await runTask.value
                Issue.record("Expected CancellationError from mid-backfill cancel")
            } catch is CancellationError {
                // The downward loop stopped at the next checkpoint as required.
            } catch {
                Issue.record("Expected CancellationError, got \(error)")
            }
        }
    }

    @Test
    func `Validity change resets watermark without duplicating documents`() async throws {
        let base = makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: base.appendingPathComponent("index.db").path)
        let checkpoints = MailIndexCheckpointStore(path: base.appendingPathComponent("cp.json").path)
        let all = Array((1 ... 10).map {
            makeMessage(id: "\($0)", body: "validity body \($0)")
        }.reversed())

        try await withTestPassword {
            let first = makeIndexer(
                gateway: StubMailGateway(
                    messages: all,
                    statusValue: MailIndexMailboxStatus(uidNext: 11, uidValidity: 1)
                ),
                store: store,
                checkpoints: checkpoints
            )
            let firstReport = try await first.run()
            #expect(firstReport.messagesIndexed == 10)
            #expect(await checkpoints.watermark(account: testAccount.name, mailbox: "INBOX") == 10)
            #expect(await checkpoints.uidValidity(account: testAccount.name, mailbox: "INBOX") == 1)

            // Server reset reassigns UIDs with a new token; the watermark must
            // restart from zero while retained hashes dedupe the refetch.
            let second = makeIndexer(
                gateway: StubMailGateway(
                    messages: all,
                    statusValue: MailIndexMailboxStatus(uidNext: 11, uidValidity: 2)
                ),
                store: store,
                checkpoints: checkpoints
            )
            let secondReport = try await second.run()
            #expect(secondReport.messagesDeduplicated == 10)
            #expect(secondReport.messagesIndexed == 0)
            #expect(secondReport.warnings.contains("Mailbox 'INBOX' UIDVALIDITY changed; restarted from zero and deduplicating by content hash."))
            let stats = try await store.stats()
            #expect(stats.documents == 10)
            #expect(await checkpoints.watermark(account: testAccount.name, mailbox: "INBOX") == 10)
            #expect(await checkpoints.uidValidity(account: testAccount.name, mailbox: "INBOX") == 2)
        }
    }

    @Test
    func `Empty window steps downward instead of stranding older mail`() async throws {
        let base = makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: base.appendingPathComponent("index.db").path)
        let checkpoints = MailIndexCheckpointStore(path: base.appendingPathComponent("cp.json").path)
        // Gap from 101..1999 deleted: newest window holds 2000..2009, an empty
        // middle window must be skipped to reach 1..100 below it.
        let gapped = Array((2000 ... 2009).map {
            makeMessage(id: "\($0)", body: "gap top \($0)")
        }.reversed()) + Array((1 ... 100).map {
            makeMessage(id: "\($0)", body: "gap bottom \($0)")
        }.reversed())
        // Window-aware stub honoring fixed lo:hi bounds so the gap surfaces as
        // an empty page the indexer must step past.
        struct GapGateway: MailIndexGateway {
            /// Messages backing every page, already newest-first.
            let messages: [MailIndexMessage]
            /// Page-bound recorder shared with the test.
            let bounds: BoundRecorder

            /// Creates a gap gateway.
            init(messages: [MailIndexMessage], bounds: BoundRecorder = BoundRecorder()) {
                self.messages = messages
                self.bounds = bounds
            }

            /// Returns the canned mailbox list.
            func mailboxes(credentials _: MailIndexCredentials) async throws -> [String] {
                ["INBOX"]
            }

            /// Returns the bounded window slice, preserving newest-first order.
            func messages(
                credentials _: MailIndexCredentials,
                mailbox _: String,
                limit: Int,
                mode _: MailFetchMode,
                beforeUID: Int? = nil
            ) async throws -> [MailIndexMessage] {
                await bounds.record(beforeUID)
                if let beforeUID {
                    let upper = beforeUID - 1
                    guard upper >= 1 else { return [] }
                    let lower = max(1, upper - EmailIMAPMailIndexGateway.uidWindowWidth + 1)
                    let filtered = messages.filter {
                        let uid = MailIndexer.uid(of: $0.id)
                        return uid >= lower && uid <= upper
                    }
                    return Array(filtered.prefix(limit))
                }
                // First window anchors from the newest UID like STATUS would.
                let top = messages.map { MailIndexer.uid(of: $0.id) }.max() ?? 0
                let lower = max(1, top - EmailIMAPMailIndexGateway.uidWindowWidth + 1)
                let filtered = messages.filter {
                    let uid = MailIndexer.uid(of: $0.id)
                    return uid >= lower && uid <= top
                }
                return Array(filtered.prefix(limit))
            }

            /// Never serves attachment bytes; the gap test uses attachment-free mail.
            func attachment(
                credentials _: MailIndexCredentials,
                mailbox _: String,
                messageID _: String,
                attachmentIndex _: Int,
                mode _: MailFetchMode
            ) async throws -> MailIndexAttachmentData {
                throw StubGatewayError.missingAttachment
            }
        }
        let bounds = BoundRecorder()
        try await withTestPassword {
            let indexer = makeIndexer(
                gateway: GapGateway(messages: gapped, bounds: bounds),
                store: store,
                checkpoints: checkpoints
            )
            let report = try await indexer.run()
            #expect(report.messagesIndexed == 110)
            let watermark = await checkpoints.watermark(account: testAccount.name, mailbox: "INBOX")
            #expect(watermark == 2009)
            let stats = try await store.stats()
            #expect(stats.documents == 110)
            // The bottom message below the empty middle window stays indexed.
            let bottomID = MailIndexer.documentExternalID(
                account: testAccount.name,
                mailbox: "INBOX",
                messageID: "1"
            )
            #expect(try await store.document(source: .mail, externalID: bottomID) != nil)
        }
    }

    @Test
    func `Mailbox deny matches case-insensitively across segments and globs`() {
        let patterns = ["Trash", "Junk", "Spam", "Deleted*"]
        #expect(MailIndexer.isMailboxDenied("Trash", patterns: patterns))
        #expect(MailIndexer.isMailboxDenied("trash", patterns: patterns))
        #expect(MailIndexer.isMailboxDenied("TRASH", patterns: patterns))
        #expect(MailIndexer.isMailboxDenied("Junk", patterns: patterns))
        #expect(MailIndexer.isMailboxDenied("junk", patterns: patterns))
        #expect(MailIndexer.isMailboxDenied("Deleted Messages", patterns: patterns))
        #expect(MailIndexer.isMailboxDenied("deleted messages", patterns: patterns))
        #expect(MailIndexer.isMailboxDenied("DELETED ARCHIVE", patterns: patterns))
        // Hierarchy segments match at any depth, mirroring the files walker.
        #expect(MailIndexer.isMailboxDenied("INBOX/Trash", patterns: patterns))
        #expect(MailIndexer.isMailboxDenied("INBOX/trash", patterns: patterns))
        #expect(MailIndexer.isMailboxDenied("[Gmail]/Trash", patterns: patterns))
        #expect(MailIndexer.isMailboxDenied("INBOX/Deleted Items", patterns: ["Deleted*"]))
        // Archive and every other mailbox index exactly as today.
        #expect(!MailIndexer.isMailboxDenied("INBOX", patterns: patterns))
        #expect(!MailIndexer.isMailboxDenied("Archive", patterns: patterns))
        #expect(!MailIndexer.isMailboxDenied("Sent", patterns: patterns))
        #expect(!MailIndexer.isMailboxDenied("INBOX/Archive", patterns: patterns))
        #expect(!MailIndexer.isMailboxDenied("INBOX", patterns: []))
        #expect(!MailIndexer.isMailboxDenied("Trash", patterns: []))
    }

    @Test
    func `Denied mailboxes skip silently with skipped counts and no warnings`() async throws {
        let base = makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: base.appendingPathComponent("index.db").path)
        let checkpoints = MailIndexCheckpointStore(path: base.appendingPathComponent("cp.json").path)
        struct MultiGateway: MailIndexGateway {
            let perMailbox: [String: [MailIndexMessage]]

            func mailboxes(credentials _: MailIndexCredentials) async throws -> [String] {
                Array(perMailbox.keys).sorted()
            }

            func messages(
                credentials _: MailIndexCredentials,
                mailbox: String,
                limit: Int,
                mode _: MailFetchMode,
                beforeUID _: Int?
            ) async throws -> [MailIndexMessage] {
                Array((perMailbox[mailbox] ?? []).prefix(limit))
            }

            func attachment(
                credentials _: MailIndexCredentials,
                mailbox _: String,
                messageID _: String,
                attachmentIndex _: Int,
                mode _: MailFetchMode
            ) async throws -> MailIndexAttachmentData {
                throw StubGatewayError.missingAttachment
            }
        }
        let gateway = MultiGateway(perMailbox: [
            "INBOX": [makeMessage(id: "1", body: "inbox body unique")],
            "Trash": [makeMessage(id: "1", body: "trash body unique")],
            "Junk": [makeMessage(id: "1", body: "junk body unique")],
            "Deleted Messages": [makeMessage(id: "1", body: "deleted body unique")],
            "Archive": [makeMessage(id: "1", body: "archive body unique")]
        ])
        try await withTestPassword {
            let indexer = MailIndexer(
                emailConfig: EmailConfig(accounts: [testAccount]),
                indexConfig: IndexConfig(enabled: true, mail: true),
                gateway: gateway,
                store: store,
                checkpoints: checkpoints
            )
            let report = try await indexer.run()
            // Trash, Junk, and Deleted Messages skip; INBOX and Archive index.
            #expect(report.messagesIndexed == 2)
            #expect(report.mailboxesSkipped == 3)
            #expect(report.warnings.isEmpty)
            let stats = try await store.stats()
            #expect(stats.documents == 2)
            let trashID = MailIndexer.documentExternalID(account: testAccount.name, mailbox: "Trash", messageID: "1")
            #expect(try await store.document(source: .mail, externalID: trashID) == nil)
            let inboxID = MailIndexer.documentExternalID(account: testAccount.name, mailbox: "INBOX", messageID: "1")
            #expect(try await store.document(source: .mail, externalID: inboxID) != nil)
            let archiveID = MailIndexer.documentExternalID(account: testAccount.name, mailbox: "Archive", messageID: "1")
            #expect(try await store.document(source: .mail, externalID: archiveID) != nil)
        }
    }

    @Test
    func `Newly denied mail retires on the next complete run and drops checkpoints`() async throws {
        let base = makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: base.appendingPathComponent("index.db").path)
        let checkpoints = MailIndexCheckpointStore(path: base.appendingPathComponent("cp.json").path)
        struct PerMailboxGateway: MailIndexGateway {
            let perMailbox: [String: [MailIndexMessage]]

            func mailboxes(credentials _: MailIndexCredentials) async throws -> [String] {
                Array(perMailbox.keys).sorted()
            }

            func messages(
                credentials _: MailIndexCredentials,
                mailbox: String,
                limit: Int,
                mode _: MailFetchMode,
                beforeUID _: Int?
            ) async throws -> [MailIndexMessage] {
                Array((perMailbox[mailbox] ?? []).prefix(limit))
            }

            func attachment(
                credentials _: MailIndexCredentials,
                mailbox _: String,
                messageID _: String,
                attachmentIndex _: Int,
                mode _: MailFetchMode
            ) async throws -> MailIndexAttachmentData {
                throw StubGatewayError.missingAttachment
            }
        }
        try await withTestPassword {
            // Seed with an empty denylist so Trash and Junk index.
            let seed = MailIndexer(
                emailConfig: EmailConfig(accounts: [testAccount]),
                indexConfig: IndexConfig(enabled: true, mail: true, mailboxDeny: []),
                gateway: PerMailboxGateway(perMailbox: [
                    "INBOX": [makeMessage(id: "1", body: "inbox seed unique")],
                    "Trash": [makeMessage(id: "1", body: "trash seed unique")],
                    "Junk": [makeMessage(id: "1", body: "junk seed unique")]
                ]),
                store: store,
                checkpoints: checkpoints
            )
            let seedReport = try await seed.run()
            #expect(seedReport.messagesIndexed == 3)
            #expect(await checkpoints.watermark(account: testAccount.name, mailbox: "Trash") == 1)
            // Newly denied Trash and Junk retire on the next complete run.
            let denied = MailIndexer(
                emailConfig: EmailConfig(accounts: [testAccount]),
                indexConfig: IndexConfig(enabled: true, mail: true),
                gateway: PerMailboxGateway(perMailbox: [
                    "INBOX": [makeMessage(id: "1", body: "inbox seed unique"), makeMessage(id: "2", body: "inbox second unique")],
                    "Trash": [makeMessage(id: "2", body: "trash unseen unique")],
                    "Junk": [makeMessage(id: "2", body: "junk unseen unique")]
                ]),
                store: store,
                checkpoints: checkpoints
            )
            let deniedReport = try await denied.run()
            #expect(deniedReport.mailboxesSkipped == 2)
            #expect(deniedReport.warnings.isEmpty)
            #expect(deniedReport.retiredCount == 2)
            let stats = try await store.stats()
            // INBOX keeps its row plus the new arrival; Trash and Junk are gone.
            #expect(stats.documents == 2)
            let trashID = MailIndexer.documentExternalID(account: testAccount.name, mailbox: "Trash", messageID: "1")
            #expect(try await store.document(source: .mail, externalID: trashID) == nil)
            // Checkpoints drop so re-allowing backfills from scratch.
            #expect(await checkpoints.watermark(account: testAccount.name, mailbox: "Trash") == 0)
            #expect(await checkpoints.watermark(account: testAccount.name, mailbox: "Junk") == 0)
            // Re-allowing re-indexes from scratch.
            let reallowed = MailIndexer(
                emailConfig: EmailConfig(accounts: [testAccount]),
                indexConfig: IndexConfig(enabled: true, mail: true, mailboxDeny: []),
                gateway: PerMailboxGateway(perMailbox: [
                    "Trash": [makeMessage(id: "1", body: "trash seed unique")]
                ]),
                store: store,
                checkpoints: checkpoints
            )
            let reallowedReport = try await reallowed.run()
            #expect(reallowedReport.messagesIndexed == 1)
            #expect(try await store.document(source: .mail, externalID: trashID) != nil)
        }
    }

    @Test
    func `Budget-capped run never retires denied mail`() async throws {
        let base = makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: base.appendingPathComponent("index.db").path)
        let checkpoints = MailIndexCheckpointStore(path: base.appendingPathComponent("cp.json").path)
        struct SingleGateway: MailIndexGateway {
            let perMailbox: [String: [MailIndexMessage]]

            func mailboxes(credentials _: MailIndexCredentials) async throws -> [String] {
                Array(perMailbox.keys).sorted()
            }

            func messages(
                credentials _: MailIndexCredentials,
                mailbox: String,
                limit: Int,
                mode _: MailFetchMode,
                beforeUID _: Int?
            ) async throws -> [MailIndexMessage] {
                Array((perMailbox[mailbox] ?? []).prefix(limit))
            }

            func attachment(
                credentials _: MailIndexCredentials,
                mailbox _: String,
                messageID _: String,
                attachmentIndex _: Int,
                mode _: MailFetchMode
            ) async throws -> MailIndexAttachmentData {
                throw StubGatewayError.missingAttachment
            }
        }
        try await withTestPassword {
            let seed = MailIndexer(
                emailConfig: EmailConfig(accounts: [testAccount]),
                indexConfig: IndexConfig(enabled: true, mail: true, mailboxDeny: []),
                gateway: SingleGateway(perMailbox: ["Deleted Messages": [makeMessage(id: "1", body: "capped deleted unique")]]),
                store: store,
                checkpoints: checkpoints
            )
            _ = try await seed.run()
            let deniedID = MailIndexer.documentExternalID(account: testAccount.name, mailbox: "Deleted Messages", messageID: "1")
            #expect(try await store.document(source: .mail, externalID: deniedID) != nil)
            // Deleted Messages sorts before INBOX, so it is observed as denied
            // before the budget exhausts on INBOX; retire must still stay
            // skipped because the run stopped early.
            let capped = MailIndexer(
                emailConfig: EmailConfig(accounts: [testAccount]),
                indexConfig: IndexConfig(enabled: true, mail: true, nightlyBudget: 1),
                gateway: SingleGateway(perMailbox: [
                    "Deleted Messages": [makeMessage(id: "2", body: "capped deleted two")],
                    "INBOX": [makeMessage(id: "1", body: "capped inbox one"), makeMessage(id: "2", body: "capped inbox two")]
                ]),
                store: store,
                checkpoints: checkpoints
            )
            let report = try await capped.run()
            #expect(report.mailboxesSkipped == 1)
            #expect(report.retiredCount == 0)
            #expect(try await store.document(source: .mail, externalID: deniedID) != nil)
        }
    }

    @Test
    func `Store retire deletes mail chunks alongside documents`() async throws {
        let base = makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: base.appendingPathComponent("index.db").path)
        let checkpoints = MailIndexCheckpointStore(path: base.appendingPathComponent("cp.json").path)
        try await withTestPassword {
            // Seed Trash with an empty denylist so it indexes.
            let allowedSeed = MailIndexer(
                emailConfig: EmailConfig(accounts: [testAccount]),
                indexConfig: IndexConfig(enabled: true, mail: true, mailboxDeny: []),
                gateway: StubMailGateway(mailboxNames: ["Trash"], messages: [makeMessage(id: "1", body: "retire chunk body unique")]),
                store: store,
                checkpoints: checkpoints
            )
            _ = try await allowedSeed.run()
            let seeded = try await store.searchKeyword(query: "retire", limit: 10)
            #expect(!seeded.isEmpty)
            let retired = try await store.retireMailboxes(["Trash"])
            #expect(retired == 1)
            let after = try await store.searchKeyword(query: "retire", limit: 10)
            #expect(after.isEmpty)
            let stats = try await store.stats()
            #expect(stats.documents == 0)
            #expect(stats.chunks == 0)
        }
    }

    @Test
    func `Transient reset then success indexes with no warning`() async throws {
        let base = makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: base.appendingPathComponent("index.db").path)
        let checkpoints = MailIndexCheckpointStore(path: base.appendingPathComponent("cp.json").path)
        let attempts = CallRecorder()
        let progress = ProgressRecorder()

        try await withTestPassword {
            let indexer = makeIndexer(
                gateway: RetryProbeGateway(
                    probeMessages: [makeMessage(id: "1", body: "retry success body unique")],
                    failuresBeforeSuccess: 2,
                    failureMessage: "connection reset by peer",
                    attempts: attempts
                ),
                store: store,
                checkpoints: checkpoints
            )
            let report = try await indexer.run(reporter: { update in await progress.record(update) })
            #expect(report.messagesIndexed == 1)
            #expect(report.messagesSeen == 1)
            #expect(report.warnings.isEmpty)
        }

        let fetchCount = await attempts.value()
        #expect(fetchCount == 3)
        // Retries emit no progress frames: the entering and window-fetched
        // frames each appear exactly once despite two retries.
        let frames = await progress.snapshot()
        #expect(frames.count >= 3)
        #expect(frames[0].current == "INBOX")
        #expect((frames[1].current ?? "").contains("INBOX"))
        #expect(frames.last?.message.contains("Mail indexing finished") == true)
        let enteringFrames = frames.filter { $0.current == "INBOX" }
        #expect(enteringFrames.count == 1)
        let windowFrames = frames.filter { ($0.current ?? "").contains("new)") }
        #expect(windowFrames.count == 1)
    }

    @Test
    func `Permanent reset warns once with attempt suffix after exactly three fetches`() async throws {
        let base = makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: base.appendingPathComponent("index.db").path)
        let checkpoints = MailIndexCheckpointStore(path: base.appendingPathComponent("cp.json").path)
        let attempts = CallRecorder()

        try await withTestPassword {
            let indexer = makeIndexer(
                gateway: RetryProbeGateway(
                    probeMessages: [makeMessage(id: "1", body: "retry terminal body unique")],
                    failuresBeforeSuccess: Int.max,
                    failureMessage: "connection reset by peer",
                    attempts: attempts
                ),
                store: store,
                checkpoints: checkpoints
            )
            let report = try await indexer.run()
            #expect(report.messagesIndexed == 0)
            #expect(report.messagesSeen == 0)
            #expect(report.warnings.count == 1)
            #expect(report.warnings[0].contains("Skipped mailbox 'mailtest/INBOX'"))
            #expect(report.warnings[0].contains("connection reset by peer"))
            #expect(report.warnings[0].contains("(after 3 attempts)"))
        }

        let fetchCount = await attempts.value()
        #expect(fetchCount == MailIndexer.maxFetchAttempts)
        #expect(fetchCount == 3)
    }

    @Test
    func `Auth failure warns once after a single fetch with unsuffixed copy`() async throws {
        let base = makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: base.appendingPathComponent("index.db").path)
        let checkpoints = MailIndexCheckpointStore(path: base.appendingPathComponent("cp.json").path)
        let attempts = CallRecorder()
        let failureMessage = "AUTH failed: invalid credentials"

        try await withTestPassword {
            let indexer = makeIndexer(
                gateway: RetryProbeGateway(
                    probeMessages: [makeMessage(id: "1", body: "auth body unique")],
                    failuresBeforeSuccess: Int.max,
                    failureMessage: failureMessage,
                    attempts: attempts
                ),
                store: store,
                checkpoints: checkpoints
            )
            let report = try await indexer.run()
            #expect(report.messagesIndexed == 0)
            #expect(report.warnings.count == 1)
            #expect(report.warnings[0] == "Skipped mailbox 'mailtest/INBOX': \(failureMessage)")
            #expect(!report.warnings[0].contains("after"))
        }

        let fetchCount = await attempts.value()
        #expect(fetchCount == 1)
    }

    @Test
    func `Cancellation during backoff rethrows with no warning`() async throws {
        let base = makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: base.appendingPathComponent("index.db").path)
        let checkpoints = MailIndexCheckpointStore(path: base.appendingPathComponent("cp.json").path)
        let attempts = CallRecorder()

        try await withTestPassword {
            let indexer = makeIndexer(
                gateway: RetryProbeGateway(
                    probeMessages: [makeMessage(id: "1", body: "cancel backoff body unique")],
                    failuresBeforeSuccess: Int.max,
                    failureMessage: "connection reset by peer",
                    attempts: attempts
                ),
                store: store,
                checkpoints: checkpoints
            )
            let runTask = Task { try await indexer.run() }
            // The first fetch fails at once, so the run parks in the first
            // backoff sleep; cancelling there must abort the sleep promptly.
            try await Task.sleep(nanoseconds: 200_000_000)
            runTask.cancel()
            do {
                _ = try await runTask.value
                Issue.record("Expected CancellationError from backoff cancel")
            } catch is CancellationError {
                // Cancellation wins with no warning recorded.
            } catch {
                Issue.record("Expected CancellationError, got \(error)")
            }
        }

        let fetchCount = await attempts.value()
        #expect(fetchCount == 1)
    }

    @Test
    func `Retry classifier distinguishes transport, auth, and unknown errors`() {
        #expect(MailIndexer.maxFetchAttempts == 3)
        #expect(MailIndexer.fetchRetryDelaysSeconds == [2, 8])
        // Cancellation never retries.
        #expect(!MailIndexer.isRetryableMailError(CancellationError()))
        // Each transport phrase retries.
        let transportMessages = [
            "connection reset by peer",
            "Connection abort by host",
            "Broken pipe while reading",
            "operation timed out",
            "request timeout exceeded",
            "unexpected EOF from server",
            "connection refused by host",
            "network is unreachable",
            "service unavailable, try later"
        ]
        for message in transportMessages {
            #expect(
                MailIndexer.isRetryableMailError(RetryProbeError(message: message)),
                "Expected retryable for: \(message)"
            )
        }
        // Each auth phrase never retries.
        let authMessages = [
            "AUTH failed: invalid credentials",
            "invalid credential rejected",
            "wrong password supplied",
            "LOGIN failed for user"
        ]
        for message in authMessages {
            #expect(
                !MailIndexer.isRetryableMailError(RetryProbeError(message: message)),
                "Expected non-retryable for: \(message)"
            )
        }
        // Authentication wins over transport when both signals appear.
        #expect(!MailIndexer.isRetryableMailError(RetryProbeError(message: "auth failed: connection reset by peer")))
        #expect(!MailIndexer.isRetryableMailError(RetryProbeError(message: "login failed: connection reset by peer")))
        #expect(!MailIndexer.isRetryableMailError(RetryProbeError(message: "password error: timeout while connecting")))
        // Unknown and protocol errors never retry.
        #expect(!MailIndexer.isRetryableMailError(RetryProbeError(message: "BAD Parse Error: invalid mailbox name")))
        #expect(!MailIndexer.isRetryableMailError(RetryProbeError(message: "something went wrong")))
    }

    @Test
    func `Three-page mailbox pauses twice with steady one-second pacing`() async throws {
        let base = makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: base.appendingPathComponent("index.db").path)
        let checkpoints = MailIndexCheckpointStore(path: base.appendingPathComponent("cp.json").path)
        let bounds = BoundRecorder()
        let sleeps = SleepRecorder()
        // One hundred twenty arrivals tile into exactly three fifty-capped
        // pages, so the loop must pause twice.
        let all = Array((1 ... 120).map {
            makeMessage(id: "\($0)", body: "pacing body \($0)")
        }.reversed())
        let indexer = makeIndexer(
            gateway: StubMailGateway(messages: all, bounds: bounds),
            store: store,
            checkpoints: checkpoints
        )
        let credentials = MailIndexCredentials(
            accountName: "mailtest",
            host: "imap.example.com",
            port: 993,
            username: "user@example.com",
            password: "test-secret"
        )

        #expect(MailIndexer.interPagePauseSeconds == 1.0)
        let result = try await indexer.fetchFreshWindow(
            credentials: credentials,
            mailbox: "INBOX",
            watermark: 0,
            sleeper: { nanoseconds in await sleeps.record(nanoseconds) }
        )
        #expect(result.messages.count == 120)
        #expect(result.complete == true)
        let pages = await bounds.count()
        #expect(pages == 3)
        let observed = await sleeps.snapshot()
        #expect(observed.count == pages - 1)
        #expect(observed.count == 2)
        let expected = UInt64(MailIndexer.interPagePauseSeconds * 1_000_000_000)
        #expect(expected == 1_000_000_000)
        #expect(observed.allSatisfy { $0 == expected })
        #expect(observed.allSatisfy { $0 == 1_000_000_000 })
    }

    @Test
    func `Single-page mailbox never pauses`() async throws {
        let base = makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: base.appendingPathComponent("index.db").path)
        let checkpoints = MailIndexCheckpointStore(path: base.appendingPathComponent("cp.json").path)
        let bounds = BoundRecorder()
        let sleeps = SleepRecorder()
        let indexer = makeIndexer(
            gateway: StubMailGateway(
                messages: [makeMessage(id: "1", body: "single page body unique")],
                bounds: bounds
            ),
            store: store,
            checkpoints: checkpoints
        )
        let credentials = MailIndexCredentials(
            accountName: "mailtest",
            host: "imap.example.com",
            port: 993,
            username: "user@example.com",
            password: "test-secret"
        )

        let result = try await indexer.fetchFreshWindow(
            credentials: credentials,
            mailbox: "INBOX",
            watermark: 0,
            sleeper: { nanoseconds in await sleeps.record(nanoseconds) }
        )
        #expect(result.messages.count == 1)
        #expect(result.complete == true)
        #expect(await bounds.count() == 1)
        #expect(await sleeps.count() == 0)
        #expect(await sleeps.snapshot().isEmpty)
    }

    @Test
    func `Throwing sleeper aborts the fetch before the next page`() async throws {
        let base = makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: base.appendingPathComponent("index.db").path)
        let checkpoints = MailIndexCheckpointStore(path: base.appendingPathComponent("cp.json").path)
        let bounds = BoundRecorder()
        let all = Array((1 ... 120).map {
            makeMessage(id: "\($0)", body: "abort body \($0)")
        }.reversed())
        let indexer = makeIndexer(
            gateway: StubMailGateway(messages: all, bounds: bounds),
            store: store,
            checkpoints: checkpoints
        )
        let credentials = MailIndexCredentials(
            accountName: "mailtest",
            host: "imap.example.com",
            port: 993,
            username: "user@example.com",
            password: "test-secret"
        )
        struct PauseAborted: Error {}

        do {
            _ = try await indexer.fetchFreshWindow(
                credentials: credentials,
                mailbox: "INBOX",
                watermark: 0,
                sleeper: { _ in throw PauseAborted() }
            )
            Issue.record("Expected PauseAborted from throwing sleeper")
        } catch is PauseAborted {
            // The pause aborts the fetch with the error propagating to the caller,
            // where the mailbox loop degrades it to the existing skip path.
            #expect(Bool(true))
        } catch {
            Issue.record("Expected PauseAborted, got \(error)")
        }
        // Only the first page fetched before the pause threw.
        #expect(await bounds.count() == 1)
    }

    @Test
    func `Session bracket opens once plus closes once per mailbox on success`() async throws {
        let base = makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: base.appendingPathComponent("index.db").path)
        let checkpoints = MailIndexCheckpointStore(path: base.appendingPathComponent("cp.json").path)
        let recorder = SessionOpenCloseRecorder()
        let perMailbox: [String: [MailIndexMessage]] = [
            "INBOX": [makeMessage(id: "1", body: "inbox session body unique")],
            "Archive": [makeMessage(id: "1", body: "archive session body unique")]
        ]
        try await withTestPassword {
            let indexer = makeIndexer(
                gateway: RecordingSessionGateway(
                    mailboxNames: ["INBOX", "Archive"],
                    perMailbox: perMailbox,
                    recorder: recorder
                ),
                store: store,
                checkpoints: checkpoints
            )
            let report = try await indexer.run()
            #expect(report.messagesIndexed == 2)
        }
        let opens = await recorder.opensSnapshot()
        let closes = await recorder.closesSnapshot()
        #expect(opens.sorted() == ["INBOX", "Archive"].sorted().map { "mailtest/\($0)" })
        #expect(closes.sorted() == opens.sorted())
        #expect(opens.count == 2)
        #expect(closes.count == 2)
    }

    @Test
    func `Session bracket still closes once when the mailbox skips`() async throws {
        let base = makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: base.appendingPathComponent("index.db").path)
        let checkpoints = MailIndexCheckpointStore(path: base.appendingPathComponent("cp.json").path)
        let recorder = SessionOpenCloseRecorder()
        try await withTestPassword {
            let indexer = makeIndexer(
                gateway: RecordingSessionGateway(
                    mailboxNames: ["INBOX"],
                    perMailbox: [:],
                    recorder: recorder,
                    messagesFailureMessage: "BAD Parse Error: invalid mailbox name"
                ),
                store: store,
                checkpoints: checkpoints
            )
            let report = try await indexer.run()
            #expect(report.messagesIndexed == 0)
            #expect(report.warnings.count == 1)
            #expect(report.warnings[0].contains("Skipped mailbox 'mailtest/INBOX'"))
        }
        #expect(await recorder.opensSnapshot() == ["mailtest/INBOX"])
        #expect(await recorder.closesSnapshot() == ["mailtest/INBOX"])
    }

    @Test
    func `Session bracket closes on cancel with no leak`() async throws {
        let base = makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: base.appendingPathComponent("index.db").path)
        let checkpoints = MailIndexCheckpointStore(path: base.appendingPathComponent("cp.json").path)
        let recorder = SessionOpenCloseRecorder()
        let all = Array((1 ... 200).map {
            makeMessage(id: "\($0)", body: "session cancel body \($0)")
        }.reversed())
        try await withTestPassword {
            let indexer = makeIndexer(
                gateway: CancellableSessionGateway(messages: all, recorder: recorder),
                store: store,
                checkpoints: checkpoints
            )
            let runTask = Task { try await indexer.run() }
            try await Task.sleep(nanoseconds: 200_000_000)
            runTask.cancel()
            do {
                _ = try await runTask.value
                Issue.record("Expected CancellationError from session cancel")
            } catch is CancellationError {
            } catch {
                Issue.record("Expected CancellationError, got \(error)")
            }
        }
        #expect(await recorder.opensSnapshot() == ["mailtest/INBOX"])
        #expect(await recorder.closesSnapshot() == ["mailtest/INBOX"])
    }

    @Test
    func `Open failure skips with no one-shot fallback`() async throws {
        let base = makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: base.appendingPathComponent("index.db").path)
        let checkpoints = MailIndexCheckpointStore(path: base.appendingPathComponent("cp.json").path)
        let recorder = SessionOpenCloseRecorder()
        let messageCalls = CallRecorder()
        try await withTestPassword {
            let indexer = makeIndexer(
                gateway: RecordingSessionGateway(
                    mailboxNames: ["INBOX"],
                    perMailbox: ["INBOX": [makeMessage(id: "1", body: "openfail body unique")]],
                    recorder: recorder,
                    openFailureMessage: "connection reset by peer",
                    messageCalls: messageCalls
                ),
                store: store,
                checkpoints: checkpoints
            )
            let report = try await indexer.run()
            #expect(report.messagesIndexed == 0)
            #expect(report.warnings.count == 1)
            #expect(report.warnings[0].contains("Skipped mailbox 'mailtest/INBOX'"))
            #expect(report.warnings[0].contains("connection reset by peer"))
        }
        #expect(await recorder.opensSnapshot() == ["mailtest/INBOX"])
        #expect(await recorder.closesSnapshot() == [])
        #expect(await messageCalls.value() == 0)
    }
}

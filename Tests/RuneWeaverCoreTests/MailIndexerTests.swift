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

/// Records search queries and limits seen by the adapter double.
///
/// Capturing the verbatim query proves the adapter emits the exact `UID 1:N`
/// shape without free text, while the limit proves the 50-per-page clamp.
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

    /// Creates a stub gateway.
    /// - Parameters:
    ///   - mailboxNames: Mailboxes reported by the stub.
    ///   - messages: Canned messages in newest-first order.
    ///   - attachments: Canned attachment bytes.
    ///   - recorder: Mode recorder shared with the test.
    ///   - attachmentCalls: Attachment-call counter shared with the test.
    ///   - bounds: Page-bound recorder shared with the test.
    init(
        mailboxNames: [String] = ["INBOX"],
        messages: [MailIndexMessage],
        attachments: [MailIndexAttachmentData] = [],
        recorder: ModeRecorder = ModeRecorder(),
        attachmentCalls: CallRecorder = CallRecorder(),
        bounds: BoundRecorder = BoundRecorder()
    ) {
        self.mailboxNames = mailboxNames
        self.messages = messages
        self.attachments = attachments
        self.recorder = recorder
        self.attachmentCalls = attachmentCalls
        self.bounds = bounds
    }

    /// Returns the canned mailbox list.
    func mailboxes(credentials _: MailIndexCredentials) async throws -> [String] {
        mailboxNames
    }

    /// Returns the canned page for one downward bound and records the fetch mode.
    ///
    /// A nil bound returns the newest window; a present bound returns only
    /// numeric UIDs at or below bound minus one, preserving newest-first order,
    /// so the stub models a bridge that honors `UID 1:N` paging clamped to the
    /// requested limit. A bound at the mailbox start is already exhausted.
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
            let filtered = messages.filter {
                let uid = MailIndexer.uid(of: $0.id)
                return uid > 0 && uid <= upper
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
/// Proves the adapter's `UID 1:N` shape reaches the bridge without free text
/// while still clamping to one page. Hits are canned newest-first; the fetch
/// path returns a synthesized body so the adapter can complete the page.
private struct CapturingIMAPGateway: EmailIMAPGateway, Sendable {
    /// Hits returned by `search`, already newest-first.
    let hits: [EmailSearchHit]
    /// Capture box for queries and limits.
    let capture: SearchCapture

    /// Creates a capturing gateway.
    /// - Parameters:
    ///   - hits: Canned hits in newest-first order.
    ///   - capture: Box receiving queries and limits.
    init(hits: [EmailSearchHit] = [], capture: SearchCapture) {
        self.hits = hits
        self.capture = capture
    }

    /// Lists one mailbox without touching the network.
    func mailboxListing(credentials _: ResolvedEmailCredentials) async throws -> EmailMailboxListing {
        EmailMailboxListing(mailboxes: ["INBOX"], delimiter: "/")
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

    /// Serves the downward page, sleeping cancellably past the first window.
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
            let filtered = messages.filter {
                let uid = MailIndexer.uid(of: $0.id)
                return uid > 0 && uid <= upper
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

            // Seventy arrivals exceed the 50-message page; the widened window
            // must reach back to the watermark so the middle is indexed too.
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
    func `Adapter builds UID 1:N from integers only`() {
        #expect(EmailIMAPMailIndexGateway.uidRangeCriterion(beforeUID: 51) == "UID 1:50")
        #expect(EmailIMAPMailIndexGateway.uidRangeCriterion(beforeUID: 2) == "UID 1:1")
        // A bound at the mailbox start holds no UIDs, so there is no criterion to issue.
        #expect(EmailIMAPMailIndexGateway.uidRangeCriterion(beforeUID: 1) == nil)
        #expect(EmailIMAPMailIndexGateway.uidRangeCriterion(beforeUID: 0) == nil)
        #expect(EmailIMAPMailIndexGateway.uidRangeCriterion(beforeUID: -4) == nil)
    }

    @Test
    func `Adapter issues verbatim UID range with clamped page`() async throws {
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
        // A present bound must reach the bridge as the exact range shape with
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
    }

    @Test
    func `Adapter fetches newest window when no bound is given`() async throws {
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
        _ = try await adapter.messages(
            credentials: credentials,
            mailbox: "INBOX",
            limit: 10,
            mode: .peek,
            beforeUID: nil
        )
        let queries = await capture.queriesSnapshot()
        #expect(queries == [""])
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
        // UID 1:0 is not a valid range; the adapter short-circuits instead.
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
            // Four clamped pages cover the mailbox: each bound is the lowest
            // UID already fetched, so pages never overlap and never skip.
            let observed = await bounds.snapshot()
            #expect(observed.count == 4)
            #expect(observed[0] == nil)
            #expect(observed[1] == 151)
            #expect(observed[2] == 101)
            #expect(observed[3] == 51)
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
}

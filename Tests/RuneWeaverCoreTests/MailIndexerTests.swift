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

    /// Creates a stub gateway.
    /// - Parameters:
    ///   - mailboxNames: Mailboxes reported by the stub.
    ///   - messages: Canned messages in newest-first order.
    ///   - attachments: Canned attachment bytes.
    ///   - recorder: Mode recorder shared with the test.
    ///   - attachmentCalls: Attachment-call counter shared with the test.
    init(
        mailboxNames: [String] = ["INBOX"],
        messages: [MailIndexMessage],
        attachments: [MailIndexAttachmentData] = [],
        recorder: ModeRecorder = ModeRecorder(),
        attachmentCalls: CallRecorder = CallRecorder()
    ) {
        self.mailboxNames = mailboxNames
        self.messages = messages
        self.attachments = attachments
        self.recorder = recorder
        self.attachmentCalls = attachmentCalls
    }

    /// Returns the canned mailbox list.
    func mailboxes(credentials _: MailIndexCredentials) async throws -> [String] {
        mailboxNames
    }

    /// Returns the canned newest message page and records the fetch mode.
    func messages(
        credentials _: MailIndexCredentials,
        mailbox _: String,
        limit: Int,
        mode: MailFetchMode
    ) async throws -> [MailIndexMessage] {
        await recorder.record(mode)
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

/// Gateway stub modelling a live bridge that clamps every page to one newest window.
///
/// Regardless of the requested `limit`, at most `cap` newest messages surface,
/// so a burst larger than the cap leaves an unfetched middle the indexer must
/// hold its watermark over instead of jumping.
private struct ClampedMailGateway: MailIndexGateway {
    /// Canned messages in newest-first order.
    let messages: [MailIndexMessage]
    /// Widest page ever surfaced, regardless of `limit`.
    let cap: Int

    /// Returns at most `cap` newest canned messages.
    func mailboxes(credentials _: MailIndexCredentials) async throws -> [String] {
        ["INBOX"]
    }

    /// Returns the clamped newest window.
    func messages(
        credentials _: MailIndexCredentials,
        mailbox _: String,
        limit: Int,
        mode _: MailFetchMode
    ) async throws -> [MailIndexMessage] {
        Array(messages.prefix(min(limit, cap)))
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
}

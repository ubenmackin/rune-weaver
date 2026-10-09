// Rune Weaver Tools Tests — Email bridge and tool behavior coverage.

import Foundation
import os
@testable import RuneWeaverCore
@testable import RuneWeaverTools
import Testing

/// Fetch bridge stdout fixture with one listed attachment including byte size.
private let fetchFixtureWithAttachment = """
{"ok": true, "message": {
  "id": "42",
  "subject": "Quarterly report",
  "from": "boss@example.com",
  "to": "you@yourdomain.com",
  "date": "Mon, 01 Sep 2025 09:00:00 +0000",
  "body": "Please review the quarterly numbers attached.",
  "attachments": [{"filename": "report.pdf", "contentType": "application/pdf", "sizeBytes": 11}],
  "attachmentsDeferred": true,
  "attachmentsNote": "1 attachment listed; use email.attachment to download."
}}
"""

/// Fetch payload without `sizeBytes`, decoding as unknown size.
private let fetchFixtureMinimalAttachment = """
{"ok": true, "message": {
  "id": "42",
  "subject": "Quarterly report",
  "from": "boss@example.com",
  "to": "you@yourdomain.com",
  "date": "Mon, 01 Sep 2025 09:00:00 +0000",
  "body": "Please review the quarterly numbers attached.",
  "attachments": [{"filename": "report.pdf", "contentType": "application/pdf"}],
  "attachmentsDeferred": true,
  "attachmentsNote": "1 attachment listed; use email.attachment to download."
}}
"""

/// Attachment bridge stdout fixture with base64 bytes.
private let attachmentFixture = """
{"ok": true, "attachment": {
  "filename": "report.pdf",
  "contentType": "application/pdf",
  "sizeBytes": 11,
  "contentBase64": "aGVsbG8gd29ybGQ="
}}
"""

/// Fetch bridge stdout fixture with no attachments.
private let fetchFixturePlain = """
{"ok": true, "message": {
  "id": "7",
  "subject": "Hello",
  "from": "friend@example.com",
  "to": "you@yourdomain.com",
  "date": "Sun, 31 Aug 2025 12:00:00 +0000",
  "body": "Just saying hi.",
  "attachments": [],
  "attachmentsDeferred": false,
  "attachmentsNote": null
}}
"""

/// Test email config with the iCloud account over `imap.mail.me.com:993`.
private func testICloudEmailConfig(username: String = "user@icloud.com") -> EmailConfig {
    EmailConfig(accounts: [EmailICloud.account(username: username)])
}

/// Stub archive detonator returning canned manifests without a container runtime.
private struct StubArchiveDetonator: EmailArchiveDetonator, Sendable {
    /// Entries returned in the manifest.
    let manifest: [EmailArchiveEntry]
    /// Raw bytes returned for an inspected subpath entry.
    let entryData: Data?
    /// Bridge failure thrown instead of returning, when set.
    let failure: String?

    /// Creates a stub detonator.
    init(manifest: [EmailArchiveEntry] = [], entryData: Data? = nil, failure: String? = nil) {
        self.manifest = manifest
        self.entryData = entryData
        self.failure = failure
    }

    /// Returns the canned manifest and optional entry bytes.
    func detonate(filename _: String, contentType _: String, data _: Data, subpath: String?) async throws -> EmailArchiveDetonationResult {
        if let failure {
            throw EmailIMAPError.bridgeFailed(failure)
        }
        return EmailArchiveDetonationResult(
            sessionId: "runeweaver-session-test0001",
            manifest: manifest,
            manifestTruncated: false,
            entryData: subpath == nil ? nil : entryData
        )
    }
}

/// Two-account config for multi-account fan-out coverage. Each account carries a
/// distinct username, which is the key the recording gateway uses to serve
/// per-account responses and to prove which account was actually dialed.
private func twoAccountTestConfig() -> EmailConfig {
    EmailConfig(accounts: [
        EmailAccount(name: "personal", type: "imap", host: "mail.yourdomain.com", port: 993, username: "you@yourdomain.com"),
        EmailAccount(name: "work", type: "imap", host: "imap.work.example.com", port: 993, username: "worker@work.example.com")
    ])
}

/// Personal and work usernames as configured by `twoAccountTestConfig()`.
private let personalTestUsername = "you@yourdomain.com"
private let workTestUsername = "worker@work.example.com"

/// Installs passwords for both accounts in `twoAccountTestConfig()` for the
/// duration of `body` and restores any pre-existing values afterwards. The
/// work variable is set directly inside the shared credential gate because
/// that gate is single-flight: nesting a second scoped credential helper
/// inside it would deadlock, so the save/restore idiom from
/// `withTestCredential` is mirrored here instead.
private func withTwoAccountPasswords(_ body: @Sendable () async throws -> Void) async rethrows {
    try await ToolsTestSupport.withTestCredential(envVar: "EMAIL_PERSONAL_PASSWORD", value: "test-secret") {
        let saved: String? = "EMAIL_WORK_PASSWORD".withCString { keyPtr in
            getenv(keyPtr).map { String(cString: $0) }
        }
        setenv("EMAIL_WORK_PASSWORD", "test-work-secret", 1)
        defer {
            if let saved {
                setenv("EMAIL_WORK_PASSWORD", saved, 1)
            } else {
                unsetenv("EMAIL_WORK_PASSWORD")
            }
        }
        try await body()
    }
}

/// Builds a canned hit carrying a valid RFC 2822 date inside September 2025 so
/// the newest-first merge parses it deterministically; weekday names line up
/// with the real calendar so strict formatters never reject the fixture.
private func cannedHit(id: String, day: Int, hour: Int = 9, mailbox: String = "INBOX") -> EmailSearchHit {
    let weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    let date = "\(weekdays[(day - 1) % 7]), \(String(format: "%02d", day)) Sep 2025 \(String(format: "%02d", hour)):00:00 +0000"
    return EmailSearchHit(
        id: id,
        subject: "Thread \(id)",
        from: "sender@example.com",
        date: date,
        snippet: "canned body for \(id)",
        mailbox: mailbox
    )
}

/// Gateway that records every searched username and serves canned per-username
/// hits keyed by `ResolvedEmailCredentials.username`, so multi-account fan-out
/// is pinned without a network.
///
/// Usernames are unique per configured account, which makes the recording the
/// only observable proof that every account was actually dialed for
/// omitted/blank/star selectors. Served hits deliberately carry no account
/// label: the tool layer owns routing labels, and these tests must catch it if
/// labeling ever leaks into (or away from) the gateway boundary.
///
/// Concurrency: accounts are searched inside a task group, so the recording
/// lives behind the same unfair-lock box the shared test support uses; every
/// other field is immutable, which keeps the gateway safely `Sendable`.
private final class RecordingAccountGateway: EmailIMAPGateway, Sendable {
    /// Canned newest-first pool served per username (nil pool means no hits).
    let hitsByUsername: [String: [EmailSearchHit]]
    /// Gateway failure text keyed by username; a present key makes that
    /// account's search fail while still recording the dial attempt.
    let failuresByUsername: [String: String]
    /// Per-username mailbox listing override; every account reports `["INBOX"]`
    /// unless overridden, mirroring a minimal real server.
    let mailboxesByUsername: [String: [String]]
    /// Username whose searches are interrupted by a synchronous
    /// `CancellationError`, simulating a cancellation landing mid-dial. The
    /// throw is synchronous so the abort is deterministic regardless of
    /// task-group scheduling.
    let cancellingUsername: String?

    /// Box guarding the username recording across the concurrent account fan-out.
    private let recorded = OSAllocatedUnfairLock<[String]>(initialState: [])

    /// Creates a recording gateway with canned per-username behavior.
    init(
        hitsByUsername: [String: [EmailSearchHit]] = [:],
        failuresByUsername: [String: String] = [:],
        mailboxesByUsername: [String: [String]] = [:],
        cancellingUsername: String? = nil
    ) {
        self.hitsByUsername = hitsByUsername
        self.failuresByUsername = failuresByUsername
        self.mailboxesByUsername = mailboxesByUsername
        self.cancellingUsername = cancellingUsername
    }

    /// Usernames recorded so far, in call order.
    var searchedUsernames: [String] {
        recorded.withLock { $0 }
    }

    /// Returns `["INBOX"]` for every account unless an override is configured.
    func mailboxListing(credentials: ResolvedEmailCredentials) async throws -> EmailMailboxListing {
        EmailMailboxListing(mailboxes: mailboxesByUsername[credentials.username] ?? ["INBOX"], delimiter: "/")
    }

    /// Records the dialed username, then serves that account's canned pool
    /// capped to `limit`, or throws the configured gateway failure. The
    /// cancelling username's search throws `CancellationError` after the dial
    /// is recorded so cancellation tests still prove the account was reached.
    func search(credentials: ResolvedEmailCredentials, mailbox _: String, query _: String, limit: Int) async throws -> [EmailSearchHit] {
        recorded.withLock { $0.append(credentials.username) }
        if credentials.username == cancellingUsername {
            throw CancellationError()
        }
        if let failure = failuresByUsername[credentials.username] {
            throw EmailIMAPError.bridgeFailed(failure)
        }
        return Array((hitsByUsername[credentials.username] ?? []).prefix(max(1, limit)))
    }

    /// Search-only double: reads are out of scope and fail closed if reached.
    func fetch(credentials _: ResolvedEmailCredentials, mailbox _: String, messageID: String) async throws -> EmailFullMessage {
        throw EmailIMAPError.bridgeFailed("Recording gateway does not fetch message \(messageID)")
    }

    /// Search-only double: attachment downloads fail closed if reached.
    func attachment(credentials _: ResolvedEmailCredentials, mailbox _: String, messageID: String, attachmentIndex: Int) async throws -> EmailAttachmentData {
        throw EmailIMAPError.bridgeFailed("Recording gateway does not fetch attachment \(attachmentIndex) of \(messageID)")
    }

    /// Search-only double: appends fail closed if reached.
    func append(credentials _: ResolvedEmailCredentials, mailbox _: String, rawMessage _: Data) async throws {
        throw EmailIMAPError.bridgeFailed("Recording gateway is read-only")
    }
}

/// Serialized plus `testCredentialEnvLock`: `ToolsTestSupport.withTestPassword` and
/// `ToolsTestSupport.withICloudTestPassword` (see `ToolsTestSupport.swift`) mutate the process
/// environment via `setenv`, which is process-global and POSIX-unsafe under concurrency.
@Suite("Email Tools", .serialized)
struct EmailToolsTests {
    @Test
    func `Search bridge payload decodes hits`() throws {
        let hits = try EmailBridgeParsing.parseSearchPayload(Data(ToolsTestSupport.searchFixture.utf8))
        #expect(hits.count == 2)
        #expect(hits[0].id == "42")
        #expect(hits[0].subject == "Quarterly report")
        #expect(hits[0].from == "boss@example.com")
        #expect(hits[0].snippet.contains("quarterly"))
    }

    @Test
    func `Fetch bridge payload decodes body and lists attachments`() throws {
        let message = try EmailBridgeParsing.parseFetchPayload(Data(fetchFixtureWithAttachment.utf8))
        #expect(message.id == "42")
        #expect(message.subject == "Quarterly report")
        #expect(message.body.contains("quarterly numbers"))
        #expect(message.attachments.count == 1)
        #expect(message.attachments[0].filename == "report.pdf")
        #expect(message.attachments[0].contentType == "application/pdf")
        #expect(message.attachments[0].sizeBytes == 11)
        #expect(message.attachmentsDeferred == true)
        #expect((message.attachmentsNote ?? "").contains("email.attachment"))
    }

    @Test
    func `Fetch bridge payload without size decodes as unknown size`() throws {
        let message = try EmailBridgeParsing.parseFetchPayload(Data(fetchFixtureMinimalAttachment.utf8))
        #expect(message.attachments.count == 1)
        #expect(message.attachments[0].filename == "report.pdf")
        #expect(message.attachments[0].sizeBytes == nil)
    }

    @Test
    func `Attachment bridge payload decodes bytes`() throws {
        let fetched = try EmailBridgeParsing.parseAttachmentPayload(Data(attachmentFixture.utf8))
        #expect(fetched.filename == "report.pdf")
        #expect(fetched.contentType == "application/pdf")
        #expect(fetched.sizeBytes == 11)
        #expect(fetched.data == Data("hello world".utf8))
    }

    @Test
    func `Attachment bridge error payload throws`() {
        let payload = Data(#"{"ok": false, "error": "Invalid attachment index 5 (message has 1 attachments)"}"#.utf8)
        do {
            _ = try EmailBridgeParsing.parseAttachmentPayload(payload)
            Issue.record("Expected bridge failure")
        } catch {
            #expect(error.localizedDescription.contains("Invalid attachment index"))
        }
    }

    @Test
    func `Attachment args accept id and index aliases`() throws {
        let direct = try JSONDecoder().decode(EmailAttachmentArgs.self, from: Data(#"{"account":"personal","id":"42","index":0,"mailbox":"INBOX"}"#.utf8))
        #expect(direct.messageID == "42")
        #expect(direct.attachmentIndex == 0)
        #expect(direct.trimmedMailbox == "INBOX")
        let camel = try JSONDecoder().decode(EmailAttachmentArgs.self, from: Data(#"{"account":"personal","messageId":"43","attachmentIndex":1,"folder":"Archive"}"#.utf8))
        #expect(camel.messageID == "43")
        #expect(camel.attachmentIndex == 1)
        #expect(camel.trimmedMailbox == "Archive")
        let snake = try JSONDecoder().decode(EmailAttachmentArgs.self, from: Data(#"{"account":"personal","message_id":"44","attachment_index":2,"mailbox":"INBOX"}"#.utf8))
        #expect(snake.messageID == "44")
        #expect(snake.attachmentIndex == 2)
        let uid = try JSONDecoder().decode(EmailAttachmentArgs.self, from: Data(#"{"account":"personal","uid":"45","index":3,"mailbox":"INBOX"}"#.utf8))
        #expect(uid.messageID == "45")
        #expect(uid.attachmentIndex == 3)
    }

    @Test
    func `Attachment args require mailbox`() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(EmailAttachmentArgs.self, from: Data(#"{"account":"personal","id":"42","index":0}"#.utf8))
        }
    }

    @Test
    func `Fetch bridge payload without attachments is not deferred`() throws {
        let message = try EmailBridgeParsing.parseFetchPayload(Data(fetchFixturePlain.utf8))
        #expect(message.attachments.isEmpty)
        #expect(message.attachmentsDeferred == false)
        #expect(message.body == "Just saying hi.")
    }

    @Test
    func `Bridge error payload throws`() {
        let payload = Data(#"{"ok": false, "error": "IMAP login failed"}"#.utf8)
        do {
            _ = try EmailBridgeParsing.parseSearchPayload(payload)
            Issue.record("Expected bridge failure")
        } catch {
            #expect(error.localizedDescription.contains("IMAP login failed"))
        }
    }

    @Test
    func `Search args clamp limit`() throws {
        let low = try JSONDecoder().decode(EmailSearchArgs.self, from: Data(#"{"account":"personal","query":"hi","limit":0}"#.utf8))
        #expect(low.limit == 1)
        let high = try JSONDecoder().decode(EmailSearchArgs.self, from: Data(#"{"account":"personal","query":"hi","limit":500}"#.utf8))
        #expect(high.limit == 50)
        let omitted = try JSONDecoder().decode(EmailSearchArgs.self, from: Data(#"{"account":"personal","query":"hi"}"#.utf8))
        #expect(omitted.limit == 10)
    }

    @Test
    func `Read args accept id aliases`() throws {
        let direct = try JSONDecoder().decode(EmailReadArgs.self, from: Data(#"{"account":"personal","id":"42","mailbox":"INBOX"}"#.utf8))
        #expect(direct.messageID == "42")
        #expect(direct.trimmedMailbox == "INBOX")
        let camel = try JSONDecoder().decode(EmailReadArgs.self, from: Data(#"{"account":"personal","messageId":"43","folder":"Archive"}"#.utf8))
        #expect(camel.messageID == "43")
        #expect(camel.trimmedMailbox == "Archive")
        let snake = try JSONDecoder().decode(EmailReadArgs.self, from: Data(#"{"account":"personal","message_id":"44","mailbox":"INBOX"}"#.utf8))
        #expect(snake.messageID == "44")
        let uid = try JSONDecoder().decode(EmailReadArgs.self, from: Data(#"{"account":"personal","uid":"45","mailbox":"INBOX"}"#.utf8))
        #expect(uid.messageID == "45")
    }

    @Test
    func `Read args require mailbox`() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(EmailReadArgs.self, from: Data(#"{"account":"personal","id":"42"}"#.utf8))
        }
    }

    @Test
    func `Email tools expose six-tool set with search read and gated attachment`() {
        let config = ToolsTestSupport.testEmailConfig()
        let tools = EmailTools.makeTools(emailConfig: config, gateway: ToolsTestSupport.StubEmailGateway())
        #expect(tools.count == 6)
        #expect(Set(tools.map(\.name)) == Set(["email.search", "email.read", "email.attachment", "email.send", "email.listMailboxes", "email.move"]))
        let levels = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0.permissionLevel) })
        #expect(levels["email.search"] == .readOnly)
        #expect(levels["email.read"] == .readOnly)
        #expect(levels["email.listMailboxes"] == .readOnly)
        #expect(levels["email.attachment"] == .requiresApproval)
        #expect(levels["email.send"] == .requiresApproval)
        #expect(levels["email.move"] == .requiresApproval)
    }

    @Test
    func `Search tool returns envelope through ToolBus`() async throws {
        let hits = try EmailBridgeParsing.parseSearchPayload(Data(ToolsTestSupport.searchFixture.utf8))
        let gateway = ToolsTestSupport.StubEmailGateway(hits: hits)
        let config = ToolsTestSupport.testEmailConfig()
        let bus = ToolBus()
        for tool in EmailTools.makeTools(emailConfig: config, gateway: gateway) {
            await bus.register(tool: tool)
        }
        let names = await bus.toolNames()
        #expect(names.sorted() == ["email.attachment", "email.listMailboxes", "email.move", "email.read", "email.search", "email.send"])
        await ToolsTestSupport.withTestPassword {
            let input = ToolInput(toolName: "email.search", argumentsJSON: #"{"account":"personal","query":"quarterly","limit":10}"#)
            let result = await bus.execute(toolCall: input, context: ToolContext(conversationID: UUID()))
            #expect(result.isError == false)
            #expect(result.content.contains("Quarterly report"))
            #expect(result.content.contains("\"count\""))
        }
    }

    @Test
    func `Search tool passes through permission gate without approval prompts`() async throws {
        let hits = try EmailBridgeParsing.parseSearchPayload(Data(ToolsTestSupport.searchFixture.utf8))
        let gateway = ToolsTestSupport.StubEmailGateway(hits: hits)
        let config = ToolsTestSupport.testEmailConfig()
        // Chat configuration: gate attached, no approval handler. Read-only
        // email tools must still succeed without prompting.
        let bus = ToolBus(permissionGate: PermissionGate())
        for tool in EmailTools.makeTools(emailConfig: config, gateway: gateway) {
            await bus.register(tool: tool)
        }
        await ToolsTestSupport.withTestPassword {
            let input = ToolInput(toolName: "email.search", argumentsJSON: #"{"account":"personal","query":"quarterly","limit":5}"#)
            let result = await bus.execute(toolCall: input, context: ToolContext(conversationID: UUID()))
            #expect(result.isError == false)
            #expect(result.content.contains("Quarterly report"))
        }
    }

    @Test
    func `Read tool returns headers body and attachment metadata`() async throws {
        let message = try EmailBridgeParsing.parseFetchPayload(Data(fetchFixtureWithAttachment.utf8))
        let gateway = ToolsTestSupport.StubEmailGateway(message: message)
        let config = ToolsTestSupport.testEmailConfig()
        let tool = EmailReadTool(emailConfig: config, gateway: gateway)
        try await ToolsTestSupport.withTestPassword {
            let output = try await tool.execute(
                input: ToolInput(toolName: "email.read", argumentsJSON: #"{"account":"personal","id":"42","mailbox":"INBOX"}"#),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == false)
            #expect(output.content.contains("Quarterly report"))
            #expect(output.content.contains("quarterly numbers"))
            #expect(output.content.contains("report.pdf"))
            #expect(output.content.contains("application/pdf") || output.content.contains("application\\/pdf"))
            #expect(output.content.contains("sizeBytes"))
            #expect(output.content.contains("email.attachment"))
        }
    }

    @Test
    func `Search validation maps wildcard and empty to ALL`() {
        #expect(EmailIMAPValidation.isAllQuery("") == true)
        #expect(EmailIMAPValidation.isAllQuery("   ") == true)
        #expect(EmailIMAPValidation.isAllQuery("*") == true)
        #expect(EmailIMAPValidation.isAllQuery(" * ") == true)
        #expect(EmailIMAPValidation.isAllQuery("quarterly") == false)
        #expect(EmailIMAPValidation.isAllQuery("**") == false)
    }

    @Test
    func `Search tool maps empty query to most-recent`() async throws {
        let hits = try EmailBridgeParsing.parseSearchPayload(Data(ToolsTestSupport.searchFixture.utf8))
        let capture = ToolsTestSupport.QueryCapture()
        let tool = EmailSearchTool(emailConfig: ToolsTestSupport.testEmailConfig(), gateway: ToolsTestSupport.StubEmailGateway(hits: hits, capture: capture))
        try await ToolsTestSupport.withTestPassword {
            let output = try await tool.execute(
                input: ToolInput(toolName: "email.search", argumentsJSON: #"{"account":"personal","query":"  "}"#),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == false)
            #expect(capture.value == "")
            #expect(output.content.contains("Quarterly report"))
        }
    }

    @Test
    func `Search tool maps wildcard star to most-recent`() async throws {
        let hits = try EmailBridgeParsing.parseSearchPayload(Data(ToolsTestSupport.searchFixture.utf8))
        let capture = ToolsTestSupport.QueryCapture()
        let tool = EmailSearchTool(emailConfig: ToolsTestSupport.testEmailConfig(), gateway: ToolsTestSupport.StubEmailGateway(hits: hits, capture: capture))
        try await ToolsTestSupport.withTestPassword {
            let output = try await tool.execute(
                input: ToolInput(toolName: "email.search", argumentsJSON: #"{"account":"personal","query":"*","limit":1}"#),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == false)
            #expect(capture.value == "")
            struct Envelope: Decodable { let query: String; let count: Int; let messages: [EmailSearchHit] }
            let envelope = try JSONDecoder().decode(Envelope.self, from: Data(output.content.utf8))
            #expect(envelope.count == 1)
            #expect(envelope.messages.count == 1)
            #expect(envelope.messages[0].id == "42")
            #expect(envelope.messages[0].subject == "Quarterly report")
            #expect(envelope.messages[0].from == "boss@example.com")
            #expect(!envelope.messages[0].date.isEmpty)
        }
    }

    @Test
    func `Search tool respects limit returning newest first`() async throws {
        let hits = try EmailBridgeParsing.parseSearchPayload(Data(ToolsTestSupport.searchFixture.utf8))
        let config = ToolsTestSupport.testEmailConfig()
        let tool = EmailSearchTool(emailConfig: config, gateway: ToolsTestSupport.StubEmailGateway(hits: hits))
        try await ToolsTestSupport.withTestPassword {
            let output = try await tool.execute(
                input: ToolInput(toolName: "email.search", argumentsJSON: #"{"account":"personal","query":"*","limit":1}"#),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == false)
            struct Envelope: Decodable { let count: Int; let messages: [EmailSearchHit] }
            let envelope = try JSONDecoder().decode(Envelope.self, from: Data(output.content.utf8))
            #expect(envelope.count == 1)
            #expect(envelope.messages[0].id == "42")
            let full = try await tool.execute(
                input: ToolInput(toolName: "email.search", argumentsJSON: #"{"account":"personal","query":"*","limit":2}"#),
                context: ToolContext(conversationID: UUID())
            )
            let fullEnvelope = try JSONDecoder().decode(Envelope.self, from: Data(full.content.utf8))
            #expect(fullEnvelope.count == 2)
            #expect(fullEnvelope.messages.map(\.id) == ["42", "41"])
        }
    }

    @Test
    func `Wildcard icloud search returns most-recent with headers`() async throws {
        let hits = try EmailBridgeParsing.parseSearchPayload(Data(ToolsTestSupport.searchFixture.utf8))
        let capture = ToolsTestSupport.QueryCapture()
        let tool = EmailSearchTool(emailConfig: testICloudEmailConfig(), gateway: ToolsTestSupport.StubEmailGateway(hits: hits, capture: capture))
        try await ToolsTestSupport.withICloudTestPassword {
            let output = try await tool.execute(
                input: ToolInput(toolName: "email.search", argumentsJSON: #"{"account":"icloud","query":"*","limit":1}"#),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == false)
            #expect(capture.value == "")
            #expect(output.content.contains("Quarterly report"))
            #expect(output.content.contains("boss@example.com"))
            #expect(!output.content.contains("test-icloud-secret"))
        }
    }

    @Test
    func `Bridge script maps wildcard star to ALL newest first`() {
        let source = EmailIMAPBridgeScript.source
        #expect(source.contains("query == \"*\""))
        #expect(source.contains("\"ALL\""))
        #expect(source.contains("[-limit:]"))
        #expect(source.contains("reverse()"))
        #expect(source.contains("(BODY.PEEK[])"))
        #expect(source.contains("readonly=True"))
    }

    @Test
    func `Bridge script reports mailbox in message not found errors`() {
        let source = EmailIMAPBridgeScript.source
        #expect(source.contains("Message %s not found in mailbox '%s'"))
    }

    @Test
    func `Bridge script includes attachment info in search op`() {
        let source = EmailIMAPBridgeScript.source
        #expect(source.contains("atts_info = attachments_of(msg)"))
        #expect(source.contains("\"attachments\": atts_info"))
    }

    @Test
    func `Search hits decode and expose attachment metadata`() async throws {
        let json = """
        {"ok": true, "messages": [
          {
            "id": "42",
            "subject": "Quarterly report",
            "from": "boss@example.com",
            "date": "Mon, 01 Sep 2025 09:00:00 +0000",
            "snippet": "Please review the quarterly numbers",
            "mailbox": "INBOX",
            "attachmentCount": 1,
            "attachments": [
              {"index": 0, "filename": "q3_report.pdf", "contentType": "application/pdf", "sizeBytes": 102400}
            ]
          }
        ]}
        """
        let hits = try EmailBridgeParsing.parseSearchPayload(Data(json.utf8))
        #expect(hits.count == 1)
        #expect(hits[0].attachmentCount == 1)
        let atts = try #require(hits[0].attachments)
        #expect(atts.count == 1)
        #expect(atts[0].filename == "q3_report.pdf")
        #expect(atts[0].contentType == "application/pdf")
        #expect(atts[0].sizeBytes == 102_400)

        let tool = EmailSearchTool(emailConfig: ToolsTestSupport.testEmailConfig(), gateway: ToolsTestSupport.StubEmailGateway(hits: hits))
        try await ToolsTestSupport.withTestPassword {
            let output = try await tool.execute(
                input: ToolInput(toolName: "email.search", argumentsJSON: #"{"account":"personal","query":"report"}"#),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == false)
            #expect(output.content.contains("q3_report.pdf"))
            struct Envelope: Decodable { let messages: [EmailSearchHit] }
            let envelope = try JSONDecoder().decode(Envelope.self, from: Data(output.content.utf8))
            #expect(envelope.messages.first?.attachments?.first?.contentType == "application/pdf")
        }
    }

    @Test
    func `Read tool rejects unknown account without secrets`() async throws {
        let config = ToolsTestSupport.testEmailConfig()
        let tool = EmailReadTool(emailConfig: config, gateway: ToolsTestSupport.StubEmailGateway())
        let output = try await tool.execute(
            input: ToolInput(toolName: "email.read", argumentsJSON: #"{"account":"missing","id":"1","mailbox":"INBOX"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == true)
        #expect(output.content.contains("missing"))
        #expect(!output.content.contains("test-secret"))
    }

    @Test
    func `Malformed arguments fail cleanly`() async throws {
        let config = ToolsTestSupport.testEmailConfig()
        let search = EmailSearchTool(emailConfig: config, gateway: ToolsTestSupport.StubEmailGateway())
        let badSearch = try await search.execute(
            input: ToolInput(toolName: "email.search", argumentsJSON: #"{"account":"personal"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(badSearch.isError == true)
        let read = EmailReadTool(emailConfig: config, gateway: ToolsTestSupport.StubEmailGateway())
        let badRead = try await read.execute(
            input: ToolInput(toolName: "email.read", argumentsJSON: "not-json"),
            context: ToolContext(conversationID: UUID())
        )
        #expect(badRead.isError == true)
        let attachment = EmailAttachmentTool(emailConfig: config, gateway: ToolsTestSupport.StubEmailGateway())
        let badAttachment = try await attachment.execute(
            input: ToolInput(toolName: "email.attachment", argumentsJSON: #"{"account":"personal","id":"42"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(badAttachment.isError == true)
    }

    @Test
    func `Search tool rejects CR LF query`() async throws {
        let config = ToolsTestSupport.testEmailConfig()
        let tool = EmailSearchTool(emailConfig: config, gateway: ToolsTestSupport.StubEmailGateway())
        let payloads = [
            #"{"account":"personal","query":"hello\r\nworld"}"#,
            #"{"account":"personal","query":"hello\nworld"}"#,
            #"{"account":"personal","query":"hello\rworld"}"#,
            #"{"account":"personal","query":"x\")\r\nUID FETCH 1:* (RFC822)"}"#
        ]
        for payload in payloads {
            let output = try await tool.execute(
                input: ToolInput(toolName: "email.search", argumentsJSON: payload),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == true)
            #expect(output.content.contains("Invalid search query"))
        }
    }

    @Test
    func `Search validation accepts valid query`() throws {
        try EmailIMAPValidation.validateSearchQuery("quarterly report")
        try EmailIMAPValidation.validateSearchQuery("subject with \"quotes\" and \\ backslash")
    }

    @Test
    func `Read tool rejects non-UID message id`() async throws {
        let config = ToolsTestSupport.testEmailConfig()
        let message = try EmailBridgeParsing.parseFetchPayload(Data(fetchFixturePlain.utf8))
        let tool = EmailReadTool(emailConfig: config, gateway: ToolsTestSupport.StubEmailGateway(message: message))
        let badIDs = [
            "1) UID FETCH 1:* (RFC822)",
            "1\r\nFETCH 2 (RFC822)",
            "42; SELECT INBOX",
            "\"42\"",
            "abc",
            "1 2 3",
            "1*",
            "*",
            "UIDVALIDITY"
        ]
        for bad in badIDs {
            let escaped = bad.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n")
            let payload = "{\"account\":\"personal\",\"id\":\"\(escaped)\",\"mailbox\":\"INBOX\"}"
            let output = try await tool.execute(
                input: ToolInput(toolName: "email.read", argumentsJSON: payload),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == true)
            #expect(output.content.contains("Invalid message id"))
        }
    }

    @Test
    func `UID allowlist accepts valid and rejects injection`() throws {
        #expect(EmailIMAPValidation.isValidMessageID("42") == true)
        #expect(EmailIMAPValidation.isValidMessageID("1") == true)
        #expect(EmailIMAPValidation.isValidMessageID("1,2,3") == true)
        #expect(EmailIMAPValidation.isValidMessageID("1:10") == true)
        #expect(EmailIMAPValidation.isValidMessageID("1,2:5,7") == true)
        try EmailIMAPValidation.validateMessageID("42")
        try EmailIMAPValidation.validateMessageID("1:10")
        let badIDs = ["", "abc", "1 2", "1) FETCH", "\"42\"", "1\r\n2", "1;DROP", "*", "-1"]
        for bad in badIDs {
            #expect(EmailIMAPValidation.isValidMessageID(bad) == false)
        }
    }

    @Test
    func `Read tool accepts valid UID`() async throws {
        let message = try EmailBridgeParsing.parseFetchPayload(Data(fetchFixturePlain.utf8))
        let config = ToolsTestSupport.testEmailConfig()
        let tool = EmailReadTool(emailConfig: config, gateway: ToolsTestSupport.StubEmailGateway(message: message))
        try await ToolsTestSupport.withTestPassword {
            for valid in ["7", "1,2", "1:10"] {
                let output = try await tool.execute(
                    input: ToolInput(toolName: "email.read", argumentsJSON: "{\"account\":\"personal\",\"id\":\"\(valid)\",\"mailbox\":\"INBOX\"}"),
                    context: ToolContext(conversationID: UUID())
                )
                #expect(output.isError == false)
            }
        }
    }

    @Test
    func `Bridge script uses verified TLS context`() {
        let source = EmailIMAPBridgeScript.source
        #expect(source.contains("import sys, json, imaplib, email, re, ssl") || source.contains("import ssl"))
        #expect(source.contains("ssl.create_default_context()"))
        #expect(source.contains("ssl_context=ctx"))
        #expect(!source.contains("_create_unverified_context"))
        #expect(!source.contains("CERT_NONE"))
    }

    @Test
    func `Bridge script rejects CR LF and allowlists UID`() {
        let source = EmailIMAPBridgeScript.source
        #expect(source.contains("\\r") && source.contains("\\n"))
        #expect(source.contains("Invalid search query"))
        #expect(source.contains("re.fullmatch"))
        #expect(source.contains("[0-9][0-9:,]*"))
        #expect(source.contains("Invalid message id"))
        #expect(source.contains("Invalid attachment index"))
    }

    @Test
    func `Bridge script lists sizes and fetches one attachment`() {
        let source = EmailIMAPBridgeScript.source
        #expect(source.contains("sizeBytes"))
        #expect(source.contains("contentBase64"))
        #expect(source.contains("attachment_parts"))
        #expect(source.contains("\"attachment\""))
        #expect(source.contains("base64.b64encode"))
    }

    @Test
    func `Bridge script stays read-only with peek fetches`() {
        let source = EmailIMAPBridgeScript.source
        #expect(source.contains("(BODY.PEEK[])"))
        #expect(!source.contains("\"(RFC822)\""))
        #expect(source.contains("readonly=True"))
    }

    @Test
    func `Bridge script times out connects and prefers UTF-8 search`() {
        let source = EmailIMAPBridgeScript.source
        #expect(source.contains("timeout=30"))
        #expect(source.contains("CHARSET"))
        #expect(source.contains("UTF-8"))
    }

    @Test
    func `Volcrypt account maps to expected password variable`() {
        let account = EmailAccount(name: "volcrypt", type: "imap", host: "mail.volcrypt.com", port: 993, username: "you@volcrypt.com")
        #expect(account.passwordEnvVar == "EMAIL_VOLCRYPT_PASSWORD")
        #expect(EmailCredentialResolver.passwordEnvVar(for: account) == "EMAIL_VOLCRYPT_PASSWORD")
    }

    @Test
    func `Search tool resolves account name case-insensitively`() async throws {
        let hits = try EmailBridgeParsing.parseSearchPayload(Data(ToolsTestSupport.searchFixture.utf8))
        let gateway = ToolsTestSupport.StubEmailGateway(hits: hits)
        let config = ToolsTestSupport.testEmailConfig()
        let tool = EmailSearchTool(emailConfig: config, gateway: gateway)
        try await ToolsTestSupport.withTestPassword {
            let output = try await tool.execute(
                input: ToolInput(toolName: "email.search", argumentsJSON: #"{"account":"Personal","query":"quarterly","limit":10}"#),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == false)
            #expect(output.content.contains("Quarterly report"))
        }
    }

    @Test
    func `Read tool resolves account name case-insensitively`() async throws {
        let message = try EmailBridgeParsing.parseFetchPayload(Data(fetchFixturePlain.utf8))
        let config = ToolsTestSupport.testEmailConfig()
        let tool = EmailReadTool(emailConfig: config, gateway: ToolsTestSupport.StubEmailGateway(message: message))
        try await ToolsTestSupport.withTestPassword {
            let output = try await tool.execute(
                input: ToolInput(toolName: "email.read", argumentsJSON: #"{"account":"PERSONAL","id":"7","mailbox":"INBOX"}"#),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == false)
            #expect(output.content.contains("Just saying hi."))
        }
    }

    @Test
    func `ICloud well-known details match IMAP convention`() {
        #expect(EmailICloud.accountName == "icloud")
        #expect(EmailICloud.host == "imap.mail.me.com")
        #expect(EmailICloud.port == 993)
        #expect(EmailICloud.passwordEnvVar == "EMAIL_ICLOUD_PASSWORD")
        let built = EmailICloud.account(username: "user@icloud.com")
        #expect(built.name == "icloud")
        #expect(built.host == "imap.mail.me.com")
        #expect(built.port == 993)
        #expect(built.username == "user@icloud.com")
        #expect(built.passwordEnvVar == "EMAIL_ICLOUD_PASSWORD")
        #expect(EmailICloud.matches(built) == true)
        let other = EmailAccount(name: "personal", type: "imap", host: "mail.yourdomain.com", port: 993, username: "you@yourdomain.com")
        #expect(EmailICloud.matches(other) == false)
    }

    @Test
    func `ICloud account maps to expected password variable`() {
        let account = EmailICloud.account(username: "user@icloud.com")
        #expect(account.passwordEnvVar == "EMAIL_ICLOUD_PASSWORD")
        #expect(EmailCredentialResolver.passwordEnvVar(for: account) == "EMAIL_ICLOUD_PASSWORD")
    }

    @Test
    func `Search tool returns envelope for icloud account`() async throws {
        let hits = try EmailBridgeParsing.parseSearchPayload(Data(ToolsTestSupport.searchFixture.utf8))
        let gateway = ToolsTestSupport.StubEmailGateway(hits: hits)
        let config = testICloudEmailConfig()
        let tool = EmailSearchTool(emailConfig: config, gateway: gateway)
        try await ToolsTestSupport.withICloudTestPassword {
            let output = try await tool.execute(
                input: ToolInput(toolName: "email.search", argumentsJSON: #"{"account":"icloud","query":"quarterly","limit":10}"#),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == false)
            #expect(output.content.contains("Quarterly report"))
            #expect(output.content.contains("\"count\""))
            #expect(!output.content.contains("test-icloud-secret"))
        }
    }

    @Test
    func `Read tool returns body for icloud account without secrets`() async throws {
        let message = try EmailBridgeParsing.parseFetchPayload(Data(fetchFixturePlain.utf8))
        let config = testICloudEmailConfig()
        let tool = EmailReadTool(emailConfig: config, gateway: ToolsTestSupport.StubEmailGateway(message: message))
        try await ToolsTestSupport.withICloudTestPassword {
            let output = try await tool.execute(
                input: ToolInput(toolName: "email.read", argumentsJSON: #"{"account":"ICLOUD","id":"7","mailbox":"INBOX"}"#),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == false)
            #expect(output.content.contains("Just saying hi."))
            #expect(!output.content.contains("test-icloud-secret"))
        }
    }

    @Test
    func `Attachment index validation rejects negative positions`() {
        do {
            try EmailIMAPValidation.validateAttachmentIndex(-1)
            Issue.record("Expected invalid index")
        } catch {
            #expect(error.localizedDescription.contains("Invalid attachment index"))
        }
    }

    @Test
    func `Attachment tool stages bytes under sandbox staging area only`() async throws {
        let bytes = Data("hello world".utf8)
        let gateway = ToolsTestSupport.StubEmailGateway(attachment: EmailAttachmentData(
            filename: "report.pdf",
            contentType: "application/pdf",
            sizeBytes: bytes.count,
            data: bytes
        ))
        let config = ToolsTestSupport.testEmailConfig()
        let sandbox = ContainersConfig()
        let tool = EmailAttachmentTool(emailConfig: config, gateway: gateway, containersConfig: sandbox)
        try await ToolsTestSupport.withTestPassword {
            let output = try await tool.execute(
                input: ToolInput(toolName: "email.attachment", argumentsJSON: #"{"account":"personal","id":"42","index":0,"mailbox":"INBOX"}"#),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == false)
            #expect(output.content.contains("report.pdf"))
            #expect(output.content.contains("application/pdf") || output.content.contains("application\\/pdf"))
            struct Staged: Decodable { let path: String?; let skipped: Bool }
            let staged = try JSONDecoder().decode(Staged.self, from: Data(output.content.utf8))
            #expect(staged.skipped == false)
            let path = try #require(staged.path)
            #expect(path.contains("runeweaver-attachments"))
            #expect(path.contains("attachments"))
            let onDisk = try Data(contentsOf: URL(fileURLWithPath: path))
            #expect(onDisk == bytes)
            #expect(!output.content.contains("test-secret"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: path))
        }
    }

    @Test
    func `Attachment tool sanitizes traversal filenames inside staging`() async throws {
        let bytes = Data("evil".utf8)
        let gateway = ToolsTestSupport.StubEmailGateway(attachment: EmailAttachmentData(
            filename: "../../evil.txt",
            contentType: "text/plain",
            sizeBytes: bytes.count,
            data: bytes
        ))
        let config = ToolsTestSupport.testEmailConfig()
        let tool = EmailAttachmentTool(
            emailConfig: config,
            gateway: gateway,
            containersConfig: ContainersConfig()
        )
        try await ToolsTestSupport.withTestPassword {
            let output = try await tool.execute(
                input: ToolInput(toolName: "email.attachment", argumentsJSON: #"{"account":"personal","id":"42","index":0,"mailbox":"INBOX"}"#),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == false)
            struct Staged: Decodable { let path: String? }
            let staged = try JSONDecoder().decode(Staged.self, from: Data(output.content.utf8))
            let path = try #require(staged.path)
            #expect(path.contains("runeweaver-attachments"))
            #expect(!path.contains(".."))
            #expect(URL(fileURLWithPath: path).lastPathComponent.contains("evil.txt"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: path))
        }
    }

    @Test
    func `Attachment tool skips oversized parts with a note`() async throws {
        let oversize = EmailAttachmentTool.maxAttachmentBytes + 1
        let gateway = ToolsTestSupport.StubEmailGateway(attachment: EmailAttachmentData(
            filename: "big.bin",
            contentType: "application/octet-stream",
            sizeBytes: oversize,
            data: Data(repeating: 0, count: 8)
        ))
        let config = ToolsTestSupport.testEmailConfig()
        let tool = EmailAttachmentTool(
            emailConfig: config,
            gateway: gateway,
            containersConfig: ContainersConfig()
        )
        try await ToolsTestSupport.withTestPassword {
            let output = try await tool.execute(
                input: ToolInput(toolName: "email.attachment", argumentsJSON: #"{"account":"personal","id":"42","index":0,"mailbox":"INBOX"}"#),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == false)
            struct Skipped: Decodable { let path: String?; let skipped: Bool; let note: String? }
            let decoded = try JSONDecoder().decode(Skipped.self, from: Data(output.content.utf8))
            #expect(decoded.skipped == true)
            #expect(decoded.path == nil)
            #expect((decoded.note ?? "").contains("10 MB"))
        }
    }

    @Test
    func `Attachment tool dry run fetches without writing`() async throws {
        let bytes = Data("hello world".utf8)
        let gateway = ToolsTestSupport.StubEmailGateway(attachment: EmailAttachmentData(
            filename: "report.pdf",
            contentType: "application/pdf",
            sizeBytes: bytes.count,
            data: bytes
        ))
        let config = ToolsTestSupport.testEmailConfig()
        let tool = EmailAttachmentTool(
            emailConfig: config,
            gateway: gateway,
            containersConfig: ContainersConfig()
        )
        try await ToolsTestSupport.withTestPassword {
            let output = try await tool.execute(
                input: ToolInput(toolName: "email.attachment", argumentsJSON: #"{"account":"personal","id":"42","index":0,"mailbox":"INBOX"}"#),
                context: ToolContext(conversationID: UUID(), dryRun: true)
            )
            #expect(output.isError == false)
            #expect(output.content.contains("Dry run"))
        }
    }

    @Test
    func `Attachment tool rejects negative index and bad id`() async throws {
        let bytes = Data("hello world".utf8)
        let gateway = ToolsTestSupport.StubEmailGateway(attachment: EmailAttachmentData(
            filename: "report.pdf",
            contentType: "application/pdf",
            sizeBytes: bytes.count,
            data: bytes
        ))
        let config = ToolsTestSupport.testEmailConfig()
        let tool = EmailAttachmentTool(emailConfig: config, gateway: gateway)
        let negative = try await tool.execute(
            input: ToolInput(toolName: "email.attachment", argumentsJSON: #"{"account":"personal","id":"42","index":-1,"mailbox":"INBOX"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(negative.isError == true)
        #expect(negative.content.contains("Invalid attachment index"))
        let badID = try await tool.execute(
            input: ToolInput(toolName: "email.attachment", argumentsJSON: #"{"account":"personal","id":"1;DROP","index":0,"mailbox":"INBOX"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(badID.isError == true)
        #expect(badID.content.contains("Invalid message id"))
    }

    @Test
    func `Attachment tool rejects unknown account without secrets`() async throws {
        let config = ToolsTestSupport.testEmailConfig()
        let tool = EmailAttachmentTool(emailConfig: config, gateway: ToolsTestSupport.StubEmailGateway())
        let output = try await tool.execute(
            input: ToolInput(toolName: "email.attachment", argumentsJSON: #"{"account":"missing","id":"1","index":0,"mailbox":"INBOX"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == true)
        #expect(output.content.contains("missing"))
        #expect(!output.content.contains("test-secret"))
    }

    @Test
    func `Attachment tool requires approval without a handler`() async {
        let bytes = Data("hello world".utf8)
        let gateway = ToolsTestSupport.StubEmailGateway(attachment: EmailAttachmentData(
            filename: "report.pdf",
            contentType: "application/pdf",
            sizeBytes: bytes.count,
            data: bytes
        ))
        let config = ToolsTestSupport.testEmailConfig()
        let bus = ToolBus(permissionGate: PermissionGate())
        for tool in EmailTools.makeTools(
            emailConfig: config,
            gateway: gateway,
            containersConfig: ContainersConfig()
        ) {
            await bus.register(tool: tool)
        }
        await ToolsTestSupport.withTestPassword {
            let input = ToolInput(toolName: "email.attachment", argumentsJSON: #"{"account":"personal","id":"42","index":0,"mailbox":"INBOX"}"#)
            let result = await bus.execute(toolCall: input, context: ToolContext(conversationID: UUID()))
            #expect(result.isError == true)
            #expect(result.content.contains("requires approval"))
        }
    }

    @Test
    func `Staged destination stays under the staging area`() throws {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("runeweaver-attachment-\(UUID().uuidString)").path
        let destination = try EmailAttachmentTool.stagedDestination(
            stagingPath: staging,
            account: "personal",
            messageID: "42",
            index: 0,
            filename: "report.pdf"
        )
        #expect(destination.path.hasPrefix(URL(fileURLWithPath: staging).standardized.path + "/"))
        #expect(destination.lastPathComponent.contains("report.pdf"))
        #expect(EmailAttachmentTool.sanitizedFilename("../../evil.txt", fallback: "attachment-0") == "evil.txt")
        #expect(EmailAttachmentTool.sanitizedFilename("   ", fallback: "attachment-0") == "attachment-0")
        #expect(EmailAttachmentTool.oversizeNote(sizeBytes: 1).contains("10 MB"))
    }

    @Test
    func `Search fans out across selectable mailboxes merging newest-first labeled with mailbox`() async throws {
        let inboxHit = EmailSearchHit(
            id: "42",
            subject: "Quarterly report",
            from: "boss@example.com",
            date: "Mon, 01 Sep 2025 09:00:00 +0000",
            snippet: "Please review the quarterly numbers",
            mailbox: "INBOX"
        )
        let archiveHit = EmailSearchHit(
            id: "7",
            subject: "Archive note",
            from: "archive@example.com",
            date: "Tue, 02 Sep 2025 09:00:00 +0000",
            snippet: "Older archive body",
            mailbox: "Archive"
        )
        let gateway = ToolsTestSupport.StubEmailGateway(
            listedMailboxes: ["INBOX", "Archive"],
            hitsByMailbox: ["INBOX": [inboxHit], "Archive": [archiveHit]]
        )
        let tool = EmailSearchTool(emailConfig: ToolsTestSupport.testEmailConfig(), gateway: gateway)
        try await ToolsTestSupport.withTestPassword {
            let output = try await tool.execute(
                input: ToolInput(toolName: "email.search", argumentsJSON: #"{"account":"personal","query":"*","limit":2}"#),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == false)
            let envelope = try JSONDecoder().decode(EmailSearchEnvelope.self, from: Data(output.content.utf8))
            #expect(envelope.count == 2)
            #expect(envelope.messages.count == 2)
            // Newest-first across folders: the newer Archive hit sorts before the INBOX hit.
            #expect(envelope.messages[0].mailbox == "Archive")
            #expect(envelope.messages[0].id == "7")
            #expect(envelope.messages[1].mailbox == "INBOX")
            #expect(envelope.messages[1].id == "42")
            #expect(envelope.mailbox == nil)
            #expect(envelope.mailboxes == ["INBOX", "Archive"])
            let capped = try await tool.execute(
                input: ToolInput(toolName: "email.search", argumentsJSON: #"{"account":"personal","query":"*","limit":1}"#),
                context: ToolContext(conversationID: UUID())
            )
            let single = try JSONDecoder().decode(EmailSearchEnvelope.self, from: Data(capped.content.utf8))
            #expect(single.count == 1)
            #expect(single.messages[0].mailbox == "Archive")
        }
    }

    @Test
    func `Search with explicit mailbox narrows to one folder`() async throws {
        let inboxHit = EmailSearchHit(
            id: "42",
            subject: "Quarterly report",
            from: "boss@example.com",
            date: "Mon, 01 Sep 2025 09:00:00 +0000",
            snippet: "Please review the quarterly numbers",
            mailbox: "INBOX"
        )
        let archiveHit = EmailSearchHit(
            id: "7",
            subject: "Archive note",
            from: "archive@example.com",
            date: "Tue, 02 Sep 2025 09:00:00 +0000",
            snippet: "Archive body",
            mailbox: "Archive"
        )
        let mailboxCapture = ToolsTestSupport.QueryCapture()
        let gateway = ToolsTestSupport.StubEmailGateway(
            listedMailboxes: ["INBOX", "Archive"],
            hitsByMailbox: ["INBOX": [inboxHit], "Archive": [archiveHit]],
            mailboxCapture: mailboxCapture
        )
        let tool = EmailSearchTool(emailConfig: ToolsTestSupport.testEmailConfig(), gateway: gateway)
        try await ToolsTestSupport.withTestPassword {
            let output = try await tool.execute(
                input: ToolInput(toolName: "email.search", argumentsJSON: #"{"account":"personal","query":"*","mailbox":"Archive"}"#),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == false)
            #expect(mailboxCapture.value == "Archive")
            let envelope = try JSONDecoder().decode(EmailSearchEnvelope.self, from: Data(output.content.utf8))
            #expect(envelope.mailbox == "Archive")
            #expect(envelope.mailboxes == ["Archive"])
            #expect(envelope.messages.count == 1)
            #expect(envelope.messages[0].mailbox == "Archive")
            #expect(envelope.messages[0].id == "7")
        }
    }

    @Test
    func `Search with unknown mailbox reports available folders`() async throws {
        let gateway = ToolsTestSupport.StubEmailGateway(
            listedMailboxes: ["INBOX", "Archive"],
            hitsByMailbox: ["INBOX": [], "Archive": []]
        )
        let tool = EmailSearchTool(emailConfig: ToolsTestSupport.testEmailConfig(), gateway: gateway)
        try await ToolsTestSupport.withTestPassword {
            let output = try await tool.execute(
                input: ToolInput(toolName: "email.search", argumentsJSON: #"{"account":"personal","query":"*","mailbox":"Missing"}"#),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == true)
            #expect(output.content.contains("Unknown mailbox"))
            #expect(output.content.contains("Missing"))
            #expect(output.content.contains("INBOX"))
            #expect(output.content.contains("Archive"))
            #expect(!output.content.contains("test-secret"))
        }
    }

    @Test
    func `Search decodes and supports hasAttachment parameter and hit fields`() async throws {
        let hits = [
            EmailSearchHit(
                id: "101",
                subject: "Invoice attached",
                from: "billing@example.com",
                date: "Mon, 18 Sep 2026 12:00:00 +0000",
                snippet: "Please find your invoice attached.",
                mailbox: "INBOX",
                hasAttachments: true,
                attachmentCount: 1
            )
        ]
        let tool = EmailSearchTool(emailConfig: ToolsTestSupport.testEmailConfig(), gateway: ToolsTestSupport.StubEmailGateway(hits: hits))
        try await ToolsTestSupport.withTestPassword {
            let output = try await tool.execute(
                input: ToolInput(toolName: "email.search", argumentsJSON: #"{"account":"personal","query":"invoice","hasAttachment":true}"#),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == false)
            #expect(output.content.contains("hasAttachments"))
            #expect(output.content.contains("attachmentCount"))
            #expect(output.content.contains("Invoice attached"))
        }
    }

    @Test
    func `List excludes non-selectable flags`() throws {
        let selectable = EmailBridgeParsing.selectableMailboxes(from: [
            (flags: "\\HasNoChildren", mailbox: "INBOX"),
            (flags: "\\Noselect \\HasChildren", mailbox: "[Gmail]"),
            (flags: "\\NonExistent", mailbox: "Ghost"),
            (flags: "\\noselect", mailbox: "Lower"),
            (flags: "", mailbox: "Archive")
        ])
        #expect(selectable == ["INBOX", "Archive"])
        let payload = Data(#"{"ok": true, "mailboxes": ["INBOX", "Archive"]}"#.utf8)
        #expect(try EmailBridgeParsing.parseListPayload(payload) == ["INBOX", "Archive"])
        let source = EmailIMAPBridgeScript.source
        #expect(source.contains("is_selectable") || source.contains("noselect"))
        #expect(source.lowercased().contains("noselect"))
        #expect(source.lowercased().contains("nonexistent"))
        #expect(source.contains("\"list\"") || source.contains("'list'") || source.contains("op == \"list\""))
    }

    @Test
    func `Read reuses the found mailbox so fan-out hits stay openable`() async throws {
        let message = try EmailBridgeParsing.parseFetchPayload(Data(fetchFixtureWithAttachment.utf8))
        let mailboxCapture = ToolsTestSupport.QueryCapture()
        let gateway = ToolsTestSupport.StubEmailGateway(
            message: message,
            listedMailboxes: ["INBOX", "Archive"],
            mailboxCapture: mailboxCapture
        )
        let config = ToolsTestSupport.testEmailConfig()
        let tool = EmailReadTool(emailConfig: config, gateway: gateway)
        try await ToolsTestSupport.withTestPassword {
            let output = try await tool.execute(
                input: ToolInput(toolName: "email.read", argumentsJSON: #"{"account":"personal","id":"42","mailbox":"Archive"}"#),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == false)
            #expect(mailboxCapture.value == "Archive")
            struct ReadEnvelope: Decodable { let mailbox: String }
            let envelope = try JSONDecoder().decode(ReadEnvelope.self, from: Data(output.content.utf8))
            #expect(envelope.mailbox == "Archive")
            #expect(output.content.contains("Quarterly report"))
        }
    }

    @Test
    func `Read with unknown mailbox reports available folders`() async throws {
        let message = try EmailBridgeParsing.parseFetchPayload(Data(fetchFixturePlain.utf8))
        let gateway = ToolsTestSupport.StubEmailGateway(
            message: message,
            listedMailboxes: ["INBOX", "Archive"]
        )
        let tool = EmailReadTool(emailConfig: ToolsTestSupport.testEmailConfig(), gateway: gateway)
        try await ToolsTestSupport.withTestPassword {
            let output = try await tool.execute(
                input: ToolInput(toolName: "email.read", argumentsJSON: #"{"account":"personal","id":"7","mailbox":"Missing"}"#),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == true)
            #expect(output.content.contains("Unknown mailbox"))
            #expect(output.content.contains("INBOX"))
        }
    }

    @Test
    func `Attachment reuses the found mailbox`() async throws {
        let bytes = Data("hello world".utf8)
        let mailboxCapture = ToolsTestSupport.QueryCapture()
        let gateway = ToolsTestSupport.StubEmailGateway(
            attachment: EmailAttachmentData(
                filename: "report.pdf",
                contentType: "application/pdf",
                sizeBytes: bytes.count,
                data: bytes
            ),
            listedMailboxes: ["INBOX", "Archive"],
            mailboxCapture: mailboxCapture
        )
        let config = ToolsTestSupport.testEmailConfig()
        let tool = EmailAttachmentTool(
            emailConfig: config,
            gateway: gateway,
            containersConfig: ContainersConfig()
        )
        try await ToolsTestSupport.withTestPassword {
            let output = try await tool.execute(
                input: ToolInput(toolName: "email.attachment", argumentsJSON: #"{"account":"personal","id":"42","index":0,"mailbox":"Archive"}"#),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == false)
            #expect(mailboxCapture.value == "Archive")
            struct Staged: Decodable { let mailbox: String; let path: String? }
            let staged = try JSONDecoder().decode(Staged.self, from: Data(output.content.utf8))
            #expect(staged.mailbox == "Archive")
            #expect((staged.path ?? "").contains("runeweaver-attachments"))
            if let path = staged.path {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: path))
            }
        }
    }

    @Test
    func `Mailbox validation rejects CR LF`() throws {
        do {
            try EmailIMAPValidation.validateMailbox("INBOX\r\nSELECT")
            Issue.record("Expected invalid mailbox")
        } catch {
            #expect(error.localizedDescription.contains("Invalid mailbox"))
        }
        do {
            try EmailIMAPValidation.validateMailbox("   ")
            Issue.record("Expected invalid mailbox")
        } catch {
            #expect(error.localizedDescription.contains("Invalid mailbox"))
        }
        try EmailIMAPValidation.validateMailbox("INBOX")
        try EmailIMAPValidation.validateMailbox("Archive")
    }

    @Test
    func `Search args decode optional mailbox and folder alias`() throws {
        let omitted = try JSONDecoder().decode(EmailSearchArgs.self, from: Data(#"{"account":"personal","query":"hi"}"#.utf8))
        #expect(omitted.mailbox == nil)
        #expect(omitted.trimmedMailbox == nil)
        let direct = try JSONDecoder().decode(EmailSearchArgs.self, from: Data(#"{"account":"personal","query":"hi","mailbox":"Archive"}"#.utf8))
        #expect(direct.mailbox == "Archive")
        #expect(direct.trimmedMailbox == "Archive")
        let alias = try JSONDecoder().decode(EmailSearchArgs.self, from: Data(#"{"account":"personal","query":"hi","folder":"Sent"}"#.utf8))
        #expect(alias.trimmedMailbox == "Sent")
        let blank = try JSONDecoder().decode(EmailSearchArgs.self, from: Data(#"{"account":"personal","query":"hi","mailbox":"   "}"#.utf8))
        #expect(blank.trimmedMailbox == nil)
    }

    @Test
    func `Assembled bridge source parses as Python without executing`() throws {
        let source = EmailIMAPBridgeScript.source
        #expect(source.contains("op == \"list\""))
        #expect(source.contains("op == \"status\""))
        #expect(source.contains("op == \"search\""))
        #expect(source.contains("op == \"fetch\""))
        #expect(source.contains("op == \"attachment\""))
        try ToolsTestSupport.assertBridgeSourceParses(source)
    }

    @Test
    func `Resolved credentials redact password under description and debugDescription`() {
        let creds = ResolvedEmailCredentials(
            accountName: "work",
            host: "imap.example.com",
            port: 993,
            username: "user@example.com",
            password: "super-secret-password-123"
        )
        let desc = String(describing: creds)
        let debugDesc = String(reflecting: creds)
        #expect(!desc.contains("super-secret-password-123"))
        #expect(!debugDesc.contains("super-secret-password-123"))
        #expect(desc == "Email(work: user@example.com@imap.example.com:993)")
        #expect(debugDesc == "Email(work: user@example.com@imap.example.com:993)")
    }

    @Test
    func `Attachment args default preview to false when omitted`() throws {
        // When callers omit the flag, decoding defaults to false.
        let omitted = try JSONDecoder().decode(EmailAttachmentArgs.self, from: Data(#"{"account":"personal","id":"42","index":0,"mailbox":"INBOX"}"#.utf8))
        #expect(omitted.preview == false)
        let requested = try JSONDecoder().decode(EmailAttachmentArgs.self, from: Data(#"{"account":"personal","id":"42","index":0,"mailbox":"INBOX","preview":true}"#.utf8))
        #expect(requested.preview == true)
    }

    @Test
    func `Attachment mime buckets stay coarse and predictable`() {
        // Coarse buckets keep follow-up hints stable without an exhaustive type table.
        #expect(EmailAttachmentLifecycle.mimeCategory(for: "application/pdf") == "pdf")
        #expect(EmailAttachmentLifecycle.mimeCategory(for: "Application/PDF; charset=utf-8") == "pdf")
        #expect(EmailAttachmentLifecycle.mimeCategory(for: "image/png") == "image")
        #expect(EmailAttachmentLifecycle.mimeCategory(for: "IMAGE/JPEG; name=\"a.jpg\"") == "image")
        #expect(EmailAttachmentLifecycle.mimeCategory(for: "text/plain") == "text")
        #expect(EmailAttachmentLifecycle.mimeCategory(for: "text/csv") == "text")
        #expect(EmailAttachmentLifecycle.mimeCategory(for: "application/json") == "text")
        #expect(EmailAttachmentLifecycle.mimeCategory(for: "application/json; charset=utf-8") == "text")
        #expect(EmailAttachmentLifecycle.mimeCategory(for: "application/octet-stream") == "other")
        // Archives detonate in isolation, so their bucket must route away from host staging.
        #expect(EmailAttachmentLifecycle.mimeCategory(for: "application/zip") == "archive")
        #expect(EmailAttachmentLifecycle.mimeCategory(for: "application/x-zip-compressed") == "archive")
        #expect(EmailAttachmentLifecycle.mimeCategory(for: "application/x-tar") == "archive")
        #expect(EmailAttachmentLifecycle.mimeCategory(for: "application/gzip") == "archive")
        // Mislabeled archives still detonate via the filename fallback.
        #expect(EmailAttachmentLifecycle.isArchive(contentType: "application/octet-stream", filename: "backup.zip") == true)
        #expect(EmailAttachmentLifecycle.isArchive(contentType: "application/octet-stream", filename: "backup.tar.gz") == true)
        #expect(EmailAttachmentLifecycle.isArchive(contentType: "application/octet-stream", filename: "report.pdf") == false)
        #expect(EmailAttachmentLifecycle.isArchive(contentType: "application/pdf", filename: "report.pdf") == false)
    }

    @Test
    func `Archive subpath validation rejects traversal and absolute paths`() throws {
        for bad in ["../escape.txt", "a/../../b", "/absolute.txt", "", "   ", "a\r\nb"] {
            do {
                _ = try EmailAttachmentLifecycle.validateArchiveSubpath(bad)
                Issue.record("Expected invalid subpath for '\(bad)'")
            } catch {
                #expect(error.localizedDescription.contains("Invalid subpath"))
            }
        }
        #expect(try EmailAttachmentLifecycle.validateArchiveSubpath("docs/report.txt") == "docs/report.txt")
    }

    @Test
    func `Archive listing parser reads unzip and tar rows`() {
        let unzip = """
        Archive:  /tmp/payload.bin
          Length      Date    Time    Name
        ---------  ---------- -----   ----
               11  2025-09-01 09:00   hello.txt
              100  2025-09-01 09:00   photos/pic.png
        ---------                     -------
              111                     2 files
        """
        let zipped = EmailArchiveListingParser.parseUnzipListing(unzip)
        #expect(zipped.count == 2)
        #expect(zipped[0].path == "hello.txt")
        #expect(zipped[0].sizeBytes == 11)
        #expect(zipped[0].category == "text")
        #expect(zipped[1].category == "image")
        let tar = "-rw-r--r-- user/group    11 2025-09-01 09:00 hello.txt\n-rw-r--r-- user/group   100 2025-09-01 09:00 docs/report.pdf\n"
        let tarred = EmailArchiveListingParser.parseTarListing(tar)
        #expect(tarred.count == 2)
        #expect(tarred[0].path == "hello.txt")
        #expect(tarred[1].category == "pdf")
        #expect(EmailArchiveListingParser.parseListOutput("not a listing", filename: "a.zip").isEmpty)
    }

    @Test
    func `Attachment expiry math follows the retention window exactly`() {
        // Pure date math keeps the envelope deterministic without touching the clock in tests.
        let anchor = Date(timeIntervalSince1970: 1_700_000_000)
        let week = EmailAttachmentLifecycle.expiryDate(from: anchor, retentionDays: 7)
        #expect(week.timeIntervalSince(anchor) == 7 * 86400)
        let single = EmailAttachmentLifecycle.expiryDate(from: anchor, retentionDays: 1)
        #expect(single.timeIntervalSince(anchor) == 86400)
        let roundTripped = EmailAttachmentLifecycle.expiryString(from: week)
        let parsed = ISO8601DateFormatter().date(from: roundTripped)
        #expect(parsed != nil)
        #expect(abs((parsed ?? Date()).timeIntervalSince(week)) < 1.0)
    }

    @Test
    func `Attachment success envelope carries expiry category and follow-up hint`() async throws {
        // The lifecycle turns a blind download into an actionable staged file with a known lifetime.
        let bytes = Data("hello world".utf8)
        let gateway = ToolsTestSupport.StubEmailGateway(attachment: EmailAttachmentData(
            filename: "notes.txt",
            contentType: "text/plain",
            sizeBytes: bytes.count,
            data: bytes
        ))
        let tool = EmailAttachmentTool(
            emailConfig: ToolsTestSupport.testEmailConfig(),
            gateway: gateway,
            containersConfig: ContainersConfig()
        )
        try await ToolsTestSupport.withTestPassword {
            let output = try await tool.execute(
                input: ToolInput(toolName: "email.attachment", argumentsJSON: #"{"account":"personal","id":"42","index":0,"mailbox":"INBOX"}"#),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == false)
            let envelope = try JSONDecoder().decode(EmailAttachmentEnvelope.self, from: Data(output.content.utf8))
            #expect(envelope.skipped == false)
            #expect((envelope.path ?? "").contains("runeweaver-attachments"))
            #expect(envelope.mimeCategory == "text")
            let expiry = try #require(envelope.expiresAt)
            let parsed = ISO8601DateFormatter().date(from: expiry)
            #expect(parsed != nil)
            // Default retention with clock skew tolerance for the download round trip.
            let remaining = (parsed ?? Date()).timeIntervalSince(Date())
            #expect(remaining > 13 * 86400 && remaining <= 14 * 86400 + 60)
            #expect((envelope.nextSteps ?? "").contains("files.read"))
            #expect((envelope.nextSteps ?? "").contains(envelope.path ?? ""))
            // No preview was requested, so text stays out of the envelope by default.
            #expect(envelope.preview == nil)
            if let path = envelope.path {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: path))
            }
        }
    }

    @Test
    func `Attachment preview truncates long text at two thousand chars`() async throws {
        // Bounding inline text keeps tool output small while still showing the leading slice.
        let long = String(repeating: "a", count: 5000)
        let bytes = Data(long.utf8)
        let gateway = ToolsTestSupport.StubEmailGateway(attachment: EmailAttachmentData(
            filename: "long.txt",
            contentType: "text/plain",
            sizeBytes: bytes.count,
            data: bytes
        ))
        let tool = EmailAttachmentTool(
            emailConfig: ToolsTestSupport.testEmailConfig(),
            gateway: gateway,
            containersConfig: ContainersConfig()
        )
        try await ToolsTestSupport.withTestPassword {
            let output = try await tool.execute(
                input: ToolInput(toolName: "email.attachment", argumentsJSON: #"{"account":"personal","id":"42","index":0,"mailbox":"INBOX","preview":true}"#),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == false)
            let envelope = try JSONDecoder().decode(EmailAttachmentEnvelope.self, from: Data(output.content.utf8))
            let preview = try #require(envelope.preview)
            #expect(preview.count == 2000)
            #expect(preview == String(long.prefix(2000)))
            #expect(envelope.previewTruncated == true)
            #expect((envelope.nextSteps ?? "").contains("files.read"))
            if let path = envelope.path {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: path))
            }
        }
    }

    @Test
    func `Attachment preview inlines small JSON and CSV`() async throws {
        // JSON and CSV are machine-readable text, so they preview like text/plain under the byte cap.
        for contentType in ["application/json", "text/csv"] {
            let bytes = Data("{\"hello\": \"world\"}".utf8)
            let gateway = ToolsTestSupport.StubEmailGateway(attachment: EmailAttachmentData(
                filename: "data",
                contentType: contentType,
                sizeBytes: bytes.count,
                data: bytes
            ))
            let tool = EmailAttachmentTool(
                emailConfig: ToolsTestSupport.testEmailConfig(),
                gateway: gateway,
                containersConfig: ContainersConfig()
            )
            try await ToolsTestSupport.withTestPassword {
                let output = try await tool.execute(
                    input: ToolInput(toolName: "email.attachment", argumentsJSON: #"{"account":"personal","id":"42","index":0,"mailbox":"INBOX","preview":true}"#),
                    context: ToolContext(conversationID: UUID())
                )
                #expect(output.isError == false)
                let envelope = try JSONDecoder().decode(EmailAttachmentEnvelope.self, from: Data(output.content.utf8))
                #expect(envelope.mimeCategory == "text")
                #expect((envelope.preview ?? "").contains("hello"))
                #expect(envelope.previewTruncated == false)
                if let path = envelope.path {
                    try? FileManager.default.removeItem(at: URL(fileURLWithPath: path))
                }
            }
        }
    }

    @Test
    func `Attachment preview never inlines binaries even when tiny`() async throws {
        // Binary bytes must never enter the model context, even when the caller asks for a preview.
        for contentType in ["application/pdf", "image/png", "application/octet-stream"] {
            let bytes = Data("hello world".utf8)
            let gateway = ToolsTestSupport.StubEmailGateway(attachment: EmailAttachmentData(
                filename: "report.pdf",
                contentType: contentType,
                sizeBytes: bytes.count,
                data: bytes
            ))
            let tool = EmailAttachmentTool(
                emailConfig: ToolsTestSupport.testEmailConfig(),
                gateway: gateway,
                containersConfig: ContainersConfig()
            )
            try await ToolsTestSupport.withTestPassword {
                let output = try await tool.execute(
                    input: ToolInput(toolName: "email.attachment", argumentsJSON: #"{"account":"personal","id":"42","index":0,"mailbox":"INBOX","preview":true}"#),
                    context: ToolContext(conversationID: UUID())
                )
                #expect(output.isError == false)
                let envelope = try JSONDecoder().decode(EmailAttachmentEnvelope.self, from: Data(output.content.utf8))
                #expect(envelope.preview == nil)
                #expect(envelope.previewTruncated == nil)
                #expect(envelope.mimeCategory != "text")
                #expect((envelope.nextSteps ?? "").contains("files.read"))
                if let path = envelope.path {
                    try? FileManager.default.removeItem(at: URL(fileURLWithPath: path))
                }
            }
        }
    }

    @Test
    func `Attachment preview stays out over the byte cap`() async throws {
        // Large text stays staged-only so a preview request cannot balloon the tool output.
        let bytes = Data(repeating: 65, count: EmailAttachmentLifecycle.maxPreviewBytes + 1)
        let gateway = ToolsTestSupport.StubEmailGateway(attachment: EmailAttachmentData(
            filename: "big.txt",
            contentType: "text/plain",
            sizeBytes: bytes.count,
            data: bytes
        ))
        let tool = EmailAttachmentTool(
            emailConfig: ToolsTestSupport.testEmailConfig(),
            gateway: gateway,
            containersConfig: ContainersConfig()
        )
        try await ToolsTestSupport.withTestPassword {
            let output = try await tool.execute(
                input: ToolInput(toolName: "email.attachment", argumentsJSON: #"{"account":"personal","id":"42","index":0,"mailbox":"INBOX","preview":true}"#),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == false)
            let envelope = try JSONDecoder().decode(EmailAttachmentEnvelope.self, from: Data(output.content.utf8))
            #expect(envelope.preview == nil)
            #expect(envelope.previewTruncated == nil)
            #expect(envelope.mimeCategory == "text")
            if let path = envelope.path {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: path))
            }
        }
    }

    @Test
    func `Attachment skip envelopes omit lifecycle keys`() async throws {
        // Oversized and dry-run outcomes must not gain lifecycle keys.
        let oversize = EmailAttachmentTool.maxAttachmentBytes + 1
        let gateway = ToolsTestSupport.StubEmailGateway(attachment: EmailAttachmentData(
            filename: "big.bin",
            contentType: "application/octet-stream",
            sizeBytes: oversize,
            data: Data(repeating: 0, count: 8)
        ))
        let tool = EmailAttachmentTool(
            emailConfig: ToolsTestSupport.testEmailConfig(),
            gateway: gateway,
            containersConfig: ContainersConfig()
        )
        try await ToolsTestSupport.withTestPassword {
            let output = try await tool.execute(
                input: ToolInput(toolName: "email.attachment", argumentsJSON: #"{"account":"personal","id":"42","index":0,"mailbox":"INBOX","preview":true}"#),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == false)
            let envelope = try JSONDecoder().decode(EmailAttachmentEnvelope.self, from: Data(output.content.utf8))
            #expect(envelope.skipped == true)
            #expect(envelope.path == nil)
            #expect(envelope.expiresAt == nil)
            #expect(envelope.mimeCategory == nil)
            #expect(envelope.nextSteps == nil)
            #expect(envelope.preview == nil)
            #expect(!output.content.contains("expiresAt"))
            #expect(!output.content.contains("mimeCategory"))
            #expect(!output.content.contains("nextSteps"))
        }
    }

    @Test
    func `Attachment minimal envelopes decode without lifecycle keys`() throws {
        // Minimal envelopes decode with omitted lifecycle fields as nil.
        let minimal = #"{"account":"personal","id":"42","index":0,"filename":"report.pdf","contentType":"application/pdf","sizeBytes":11,"path":"/tmp/report.pdf","skipped":false,"mailbox":"INBOX"}"#
        let envelope = try JSONDecoder().decode(EmailAttachmentEnvelope.self, from: Data(minimal.utf8))
        #expect(envelope.path == "/tmp/report.pdf")
        #expect(envelope.expiresAt == nil)
        #expect(envelope.mimeCategory == nil)
        #expect(envelope.nextSteps == nil)
        #expect(envelope.preview == nil)
        #expect(envelope.previewTruncated == nil)
        let encoded = try EmailBridgeParsing.encodeAttachmentEnvelope(envelope)
        #expect(encoded.contains("report.pdf"))
    }

    @Test
    func `Archive detonates to manifest only without host staging`() async throws {
        // Untrusted archive bytes must never land on the host; only the manifest crosses back.
        let bytes = Data("fake-zip-bytes".utf8)
        let gateway = ToolsTestSupport.StubEmailGateway(attachment: EmailAttachmentData(
            filename: "bundle.zip",
            contentType: "application/zip",
            sizeBytes: bytes.count,
            data: bytes
        ))
        let detonator = StubArchiveDetonator(manifest: [
            EmailArchiveEntry(path: "hello.txt", sizeBytes: 11, category: "text"),
            EmailArchiveEntry(path: "photos/pic.png", sizeBytes: 100, category: "image")
        ])
        let tool = EmailAttachmentTool(
            emailConfig: ToolsTestSupport.testEmailConfig(),
            gateway: gateway,
            containersConfig: ContainersConfig(),
            archiveDetonator: detonator
        )
        try await ToolsTestSupport.withTestPassword {
            let output = try await tool.execute(
                input: ToolInput(toolName: "email.attachment", argumentsJSON: #"{"account":"personal","id":"42","index":0,"mailbox":"INBOX"}"#),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == false)
            let envelope = try JSONDecoder().decode(EmailAttachmentEnvelope.self, from: Data(output.content.utf8))
            #expect(envelope.mimeCategory == "archive")
            #expect(envelope.skipped == false)
            #expect(envelope.path == nil)
            #expect(envelope.expiresAt == nil)
            let session = try #require(envelope.archiveSessionId)
            #expect(session.hasPrefix("runeweaver-session-"))
            #expect((envelope.archiveManifest ?? []).count == 2)
            #expect((envelope.nextSteps ?? "").contains(session))
            #expect(!output.content.contains("test-secret"))
        }
    }

    @Test
    func `Archive subpath inspection returns entry text without host staging`() async throws {
        let bytes = Data("fake-zip-bytes".utf8)
        let gateway = ToolsTestSupport.StubEmailGateway(attachment: EmailAttachmentData(
            filename: "bundle.zip",
            contentType: "application/zip",
            sizeBytes: bytes.count,
            data: bytes
        ))
        let detonator = StubArchiveDetonator(
            manifest: [EmailArchiveEntry(path: "hello.txt", sizeBytes: 11, category: "text")],
            entryData: Data("inner hello".utf8)
        )
        let tool = EmailAttachmentTool(
            emailConfig: ToolsTestSupport.testEmailConfig(),
            gateway: gateway,
            containersConfig: ContainersConfig(),
            archiveDetonator: detonator
        )
        try await ToolsTestSupport.withTestPassword {
            let output = try await tool.execute(
                input: ToolInput(toolName: "email.attachment", argumentsJSON: #"{"account":"personal","id":"42","index":0,"mailbox":"INBOX","subpath":"hello.txt"}"#),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == false)
            let envelope = try JSONDecoder().decode(EmailAttachmentEnvelope.self, from: Data(output.content.utf8))
            #expect(envelope.subpath == "hello.txt")
            #expect(envelope.extractedText == "inner hello")
            #expect(envelope.path == nil)
        }
    }

    @Test
    func `Archive saveToPath exports entry through the workspace guard`() async throws {
        let bytes = Data("fake-zip-bytes".utf8)
        let gateway = ToolsTestSupport.StubEmailGateway(attachment: EmailAttachmentData(
            filename: "bundle.zip",
            contentType: "application/zip",
            sizeBytes: bytes.count,
            data: bytes
        ))
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("runeweaver-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let destination = home.appendingPathComponent("workspace").appendingPathComponent("hello.txt")
        let detonator = StubArchiveDetonator(
            manifest: [EmailArchiveEntry(path: "hello.txt", sizeBytes: 11, category: "text")],
            entryData: Data("inner hello".utf8)
        )
        let tool = EmailAttachmentTool(
            emailConfig: ToolsTestSupport.testEmailConfig(),
            gateway: gateway,
            containersConfig: ContainersConfig(),
            homeDirectoryURL: home,
            archiveDetonator: detonator
        )
        try await ToolsTestSupport.withTestPassword {
            let payload = "{\"account\":\"personal\",\"id\":\"42\",\"index\":0,\"mailbox\":\"INBOX\",\"subpath\":\"hello.txt\",\"saveToPath\":\"\(destination.path)\"}"
            let output = try await tool.execute(
                input: ToolInput(toolName: "email.attachment", argumentsJSON: payload),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == false)
            let envelope = try JSONDecoder().decode(EmailAttachmentEnvelope.self, from: Data(output.content.utf8))
            #expect(envelope.path == destination.path)
            #expect(envelope.subpath == "hello.txt")
            let onDisk = try Data(contentsOf: destination)
            #expect(onDisk == Data("inner hello".utf8))
        }
    }

    @Test
    func `Archive saveToPath outside the workspace fails closed`() async throws {
        let bytes = Data("fake-zip-bytes".utf8)
        let gateway = ToolsTestSupport.StubEmailGateway(attachment: EmailAttachmentData(
            filename: "bundle.zip",
            contentType: "application/zip",
            sizeBytes: bytes.count,
            data: bytes
        ))
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("runeweaver-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let tool = EmailAttachmentTool(
            emailConfig: ToolsTestSupport.testEmailConfig(),
            gateway: gateway,
            containersConfig: ContainersConfig(),
            homeDirectoryURL: home,
            archiveDetonator: StubArchiveDetonator(manifest: [
                EmailArchiveEntry(path: "hello.txt", sizeBytes: 11, category: "text")
            ])
        )
        // No stub password needed: the workspace guard must win before credential resolution.
        let output = try await tool.execute(
            input: ToolInput(
                toolName: "email.attachment",
                argumentsJSON: #"{"account":"personal","id":"42","index":0,"mailbox":"INBOX","saveToPath":"/tmp/evil-outside-roots.txt"}"#
            ),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == true)
        #expect(output.content.contains("permitted workspace") || output.content.contains("outside"))
        #expect(FileManager.default.fileExists(atPath: "/tmp/evil-outside-roots.txt") == false)
    }

    @Test
    func `Non-archive rejects subpath and saveToPath`() async throws {
        let bytes = Data("hello world".utf8)
        let gateway = ToolsTestSupport.StubEmailGateway(attachment: EmailAttachmentData(
            filename: "notes.txt",
            contentType: "text/plain",
            sizeBytes: bytes.count,
            data: bytes
        ))
        let tool = EmailAttachmentTool(
            emailConfig: ToolsTestSupport.testEmailConfig(),
            gateway: gateway,
            containersConfig: ContainersConfig(),
            archiveDetonator: StubArchiveDetonator(failure: "detonator must not run for documents")
        )
        try await ToolsTestSupport.withTestPassword {
            let subpathOutput = try await tool.execute(
                input: ToolInput(toolName: "email.attachment", argumentsJSON: #"{"account":"personal","id":"42","index":0,"mailbox":"INBOX","subpath":"hello.txt"}"#),
                context: ToolContext(conversationID: UUID())
            )
            #expect(subpathOutput.isError == true)
            #expect(subpathOutput.content.contains("only valid for archives"))
        }
    }

    @Test
    func `Archive dry run spawns no machine and stages nothing`() async throws {
        let bytes = Data("fake-zip-bytes".utf8)
        let gateway = ToolsTestSupport.StubEmailGateway(attachment: EmailAttachmentData(
            filename: "bundle.zip",
            contentType: "application/zip",
            sizeBytes: bytes.count,
            data: bytes
        ))
        let tool = EmailAttachmentTool(
            emailConfig: ToolsTestSupport.testEmailConfig(),
            gateway: gateway,
            containersConfig: ContainersConfig(),
            archiveDetonator: StubArchiveDetonator(failure: "detonator must not run on dry run")
        )
        try await ToolsTestSupport.withTestPassword {
            let output = try await tool.execute(
                input: ToolInput(toolName: "email.attachment", argumentsJSON: #"{"account":"personal","id":"42","index":0,"mailbox":"INBOX"}"#),
                context: ToolContext(conversationID: UUID(), dryRun: true)
            )
            #expect(output.isError == false)
            #expect(output.content.contains("Dry run"))
        }
    }

    @Test
    func `Archive attachment args decode subpath and saveToPath`() throws {
        let minimal = try JSONDecoder().decode(EmailAttachmentArgs.self, from: Data(#"{"account":"personal","id":"42","index":0,"mailbox":"INBOX"}"#.utf8))
        #expect(minimal.trimmedSubpath == nil)
        #expect(minimal.trimmedSaveToPath == nil)
        let followUp = try JSONDecoder().decode(
            EmailAttachmentArgs.self,
            from: Data(#"{"account":"personal","id":"42","index":0,"mailbox":"INBOX","subpath":"hello.txt","saveToPath":"~/workspace/hello.txt"}"#.utf8)
        )
        #expect(followUp.trimmedSubpath == "hello.txt")
        #expect(followUp.trimmedSaveToPath == "~/workspace/hello.txt")
    }

    @Test
    func `Stub mailboxListing reports delimiters and honors failure`() async throws {
        // Direct gateway coverage keeps hierarchy-separator regressions visible without network use.
        let creds = ResolvedEmailCredentials(
            accountName: "personal",
            host: "mail.yourdomain.com",
            port: 993,
            username: "you@yourdomain.com",
            password: "test-secret"
        )
        let gateway = ToolsTestSupport.StubEmailGateway(listedMailboxes: ["INBOX", "Archive"], delimiter: ".")
        let listing = try await gateway.mailboxListing(credentials: creds)
        #expect(listing.mailboxes.count == 2)
        #expect(listing.mailboxes == ["INBOX", "Archive"])
        #expect(listing.delimiter == ".")
        let failing = ToolsTestSupport.StubEmailGateway(failure: "listing boom")
        do {
            _ = try await failing.mailboxListing(credentials: creds)
            Issue.record("Expected listing failure")
        } catch {
            #expect(error.localizedDescription.contains("listing boom"))
        }
    }

    @Test
    func `Stub move captures routing and honors failure`() async throws {
        // Move capture proves which folders the tool asked for without touching IMAP.
        let creds = ResolvedEmailCredentials(
            accountName: "personal",
            host: "mail.yourdomain.com",
            port: 993,
            username: "you@yourdomain.com",
            password: "test-secret"
        )
        let mailboxCapture = ToolsTestSupport.QueryCapture()
        let moveCapture = ToolsTestSupport.QueryCapture()
        let gateway = ToolsTestSupport.StubEmailGateway(
            listedMailboxes: ["INBOX", "Archive"],
            mailboxCapture: mailboxCapture,
            moveCapture: moveCapture
        )
        let moved = try await gateway.move(credentials: creds, mailbox: "INBOX", messageID: "42", destination: "Archive", markAsRead: false)
        #expect(moved.moved == true)
        #expect(moved.mailbox == "INBOX")
        #expect(moved.destination == "Archive")
        #expect(mailboxCapture.value == "INBOX")
        #expect(moveCapture.value == "Archive")
        let failing = ToolsTestSupport.StubEmailGateway(failure: "move boom")
        do {
            _ = try await failing.move(credentials: creds, mailbox: "INBOX", messageID: "42", destination: "Archive", markAsRead: false)
            Issue.record("Expected move failure")
        } catch {
            #expect(error.localizedDescription.contains("move boom"))
        }
    }

    @Test
    func `ListMailboxes shim delegates to mailboxListing for old callers`() async throws {
        // Old search/read paths still call listMailboxes, so the shim must stay equivalent to the listing.
        let creds = ResolvedEmailCredentials(
            accountName: "personal",
            host: "mail.yourdomain.com",
            port: 993,
            username: "you@yourdomain.com",
            password: "test-secret"
        )
        let gateway = ToolsTestSupport.StubEmailGateway(listedMailboxes: ["INBOX", "Archive"], delimiter: "/")
        let names = try await gateway.listMailboxes(credentials: creds)
        #expect(names == ["INBOX", "Archive"])
        let listing = try await gateway.mailboxListing(credentials: creds)
        #expect(listing.mailboxes == names)
    }

    @Test
    func `List tool returns envelope with delimiters through ToolBus`() async {
        let gateway = ToolsTestSupport.StubEmailGateway(listedMailboxes: ["INBOX", "Archive"], delimiter: "/")
        let config = ToolsTestSupport.testEmailConfig()
        let bus = ToolBus()
        for tool in EmailTools.makeTools(emailConfig: config, gateway: gateway) {
            await bus.register(tool: tool)
        }
        await ToolsTestSupport.withTestPassword {
            let input = ToolInput(toolName: "email.listMailboxes", argumentsJSON: #"{"account":"personal"}"#)
            let result = await bus.execute(toolCall: input, context: ToolContext(conversationID: UUID()))
            #expect(result.isError == false)
            #expect(result.content.contains("INBOX"))
            #expect(result.content.contains("Archive"))
            #expect(result.content.contains("\"count\""))
            #expect(result.content.contains("/"))
            struct ListCount: Decodable { let count: Int }
            if let data = result.content.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(ListCount.self, from: data)
            {
                #expect(decoded.count == 2)
            }
            #expect(!result.content.contains("test-secret"))
        }
    }

    @Test
    func `List and move reject unknown account without secrets`() async {
        // Unknown accounts must fail before credential resolution so no secret can leak.
        let gateway = ToolsTestSupport.StubEmailGateway(listedMailboxes: ["INBOX"])
        let config = ToolsTestSupport.testEmailConfig()
        let bus = ToolBus()
        for tool in EmailTools.makeTools(emailConfig: config, gateway: gateway) {
            await bus.register(tool: tool)
        }
        await bus.setLegacyApprovalHandler { _, _ in true }
        let listInput = ToolInput(toolName: "email.listMailboxes", argumentsJSON: #"{"account":"missing"}"#)
        let listResult = await bus.execute(toolCall: listInput, context: ToolContext(conversationID: UUID()))
        #expect(listResult.isError == true)
        #expect(listResult.content.contains("missing"))
        #expect(!listResult.content.contains("test-secret"))
        let moveInput = ToolInput(
            toolName: "email.move",
            argumentsJSON: #"{"account":"missing","id":"42","mailbox":"INBOX","destinationMailbox":"Archive"}"#
        )
        let moveResult = await bus.execute(toolCall: moveInput, context: ToolContext(conversationID: UUID()))
        #expect(moveResult.isError == true)
        #expect(moveResult.content.contains("missing"))
        #expect(!moveResult.content.contains("test-secret"))
    }

    @Test
    func `Move accepts folder alias and defaults source to INBOX`() async {
        // Folder alias plus omitted-source default keep move consistent with search/read routing.
        let mailboxCapture = ToolsTestSupport.QueryCapture()
        let moveCapture = ToolsTestSupport.QueryCapture()
        let gateway = ToolsTestSupport.StubEmailGateway(
            listedMailboxes: ["INBOX", "Archive"],
            mailboxCapture: mailboxCapture,
            moveCapture: moveCapture
        )
        let config = ToolsTestSupport.testEmailConfig()
        let bus = ToolBus()
        for tool in EmailTools.makeTools(emailConfig: config, gateway: gateway) {
            await bus.register(tool: tool)
        }
        await bus.setLegacyApprovalHandler { _, _ in true }
        await ToolsTestSupport.withTestPassword {
            let aliased = ToolInput(
                toolName: "email.move",
                argumentsJSON: #"{"account":"personal","uid":"42","folder":"INBOX","destination":"Archive"}"#
            )
            let aliasedResult = await bus.execute(toolCall: aliased, context: ToolContext(conversationID: UUID()))
            #expect(aliasedResult.isError == false)
            #expect(mailboxCapture.value == "INBOX")
            #expect(moveCapture.value == "Archive")
            let defaulted = ToolInput(
                toolName: "email.move",
                argumentsJSON: #"{"account":"personal","id":"42","destinationMailbox":"Archive"}"#
            )
            let defaultedResult = await bus.execute(toolCall: defaulted, context: ToolContext(conversationID: UUID()))
            #expect(defaultedResult.isError == false)
            #expect(mailboxCapture.value == "INBOX")
            #expect(moveCapture.value == "Archive")
        }
    }

    @Test
    func `Move rejects bad id CR-LF and empty destination`() async {
        // Fail-closed validation must win before any mailbox lookup or credential use.
        let gateway = ToolsTestSupport.StubEmailGateway(listedMailboxes: ["INBOX", "Archive"])
        let config = ToolsTestSupport.testEmailConfig()
        let bus = ToolBus()
        for tool in EmailTools.makeTools(emailConfig: config, gateway: gateway) {
            await bus.register(tool: tool)
        }
        await bus.setLegacyApprovalHandler { _, _ in true }
        let payloads = [
            #"{"account":"personal","id":"1;DROP","mailbox":"INBOX","destinationMailbox":"Archive"}"#,
            #"{"account":"personal","id":"abc","mailbox":"INBOX","destinationMailbox":"Archive"}"#,
            "{\"account\":\"personal\",\"id\":\"42\",\"mailbox\":\"INBOX\r\nSELECT\",\"destinationMailbox\":\"Archive\"}",
            "{\"account\":\"personal\",\"id\":\"42\",\"mailbox\":\"INBOX\",\"destinationMailbox\":\"Archive\r\nSELECT\"}",
            #"{"account":"personal","id":"42","mailbox":"INBOX","destinationMailbox":"   "}"#,
            #"{"account":"personal","id":"42","mailbox":"INBOX"}"#
        ]
        for payload in payloads {
            let input = ToolInput(toolName: "email.move", argumentsJSON: payload)
            let result = await bus.execute(toolCall: input, context: ToolContext(conversationID: UUID()))
            #expect(result.isError == true)
            #expect(result.content.contains("Invalid"))
        }
    }

    @Test
    func `Move with unknown destination reports available folders`() async {
        let gateway = ToolsTestSupport.StubEmailGateway(listedMailboxes: ["INBOX", "Archive"])
        let config = ToolsTestSupport.testEmailConfig()
        let bus = ToolBus()
        for tool in EmailTools.makeTools(emailConfig: config, gateway: gateway) {
            await bus.register(tool: tool)
        }
        await bus.setLegacyApprovalHandler { _, _ in true }
        await ToolsTestSupport.withTestPassword {
            let input = ToolInput(
                toolName: "email.move",
                argumentsJSON: #"{"account":"personal","id":"42","mailbox":"INBOX","destinationMailbox":"Missing"}"#
            )
            let result = await bus.execute(toolCall: input, context: ToolContext(conversationID: UUID()))
            #expect(result.isError == true)
            #expect(result.content.contains("Unknown mailbox"))
            #expect(result.content.contains("Missing"))
            #expect(result.content.contains("INBOX"))
            #expect(result.content.contains("Archive"))
            #expect(!result.content.contains("test-secret"))
        }
    }

    @Test
    func `Move to same folder reports moved false without gateway call`() async {
        // Same-folder moves are no-ops by contract, so the gateway must never be dialed.
        let moveCapture = ToolsTestSupport.QueryCapture()
        let gateway = ToolsTestSupport.StubEmailGateway(
            listedMailboxes: ["INBOX", "Archive"],
            moveCapture: moveCapture
        )
        let config = ToolsTestSupport.testEmailConfig()
        let bus = ToolBus()
        for tool in EmailTools.makeTools(emailConfig: config, gateway: gateway) {
            await bus.register(tool: tool)
        }
        await bus.setLegacyApprovalHandler { _, _ in true }
        await ToolsTestSupport.withTestPassword {
            let input = ToolInput(
                toolName: "email.move",
                argumentsJSON: #"{"account":"personal","id":"42","mailbox":"INBOX","destinationMailbox":"inbox"}"#
            )
            let result = await bus.execute(toolCall: input, context: ToolContext(conversationID: UUID()))
            #expect(result.isError == false)
            #expect(result.content.lowercased().contains("moved"))
            #expect(moveCapture.value == nil)
            struct MoveFlag: Decodable { let moved: Bool? }
            if let data = result.content.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(MoveFlag.self, from: data)
            {
                #expect(decoded.moved == false)
            }
        }
    }

    @Test
    func `Move dry run previews without network use`() async {
        // Dry runs validate routing and report the would-be move without mutating any mailbox.
        let moveCapture = ToolsTestSupport.QueryCapture()
        let gateway = ToolsTestSupport.StubEmailGateway(
            listedMailboxes: ["INBOX", "Archive"],
            moveCapture: moveCapture
        )
        let config = ToolsTestSupport.testEmailConfig()
        let bus = ToolBus()
        for tool in EmailTools.makeTools(emailConfig: config, gateway: gateway) {
            await bus.register(tool: tool)
        }
        await bus.setLegacyApprovalHandler { _, _ in true }
        await ToolsTestSupport.withTestPassword {
            let input = ToolInput(
                toolName: "email.move",
                argumentsJSON: #"{"account":"personal","id":"42","mailbox":"INBOX","destinationMailbox":"Archive"}"#
            )
            let result = await bus.execute(toolCall: input, context: ToolContext(conversationID: UUID(), dryRun: true))
            #expect(result.isError == false)
            #expect(moveCapture.value == nil)
            #expect(result.content.contains("Dry run"))
            #expect(result.content.contains("INBOX"))
            #expect(result.content.contains("Archive"))
            #expect(!result.content.contains("test-secret"))
        }
    }

    @Test
    func `Move requires approval without a handler`() async {
        // Mutating moves must park in the approvals inbox when no handler is installed.
        let moveCapture = ToolsTestSupport.QueryCapture()
        let gateway = ToolsTestSupport.StubEmailGateway(
            listedMailboxes: ["INBOX", "Archive"],
            moveCapture: moveCapture
        )
        let config = ToolsTestSupport.testEmailConfig()
        let bus = ToolBus(permissionGate: PermissionGate())
        for tool in EmailTools.makeTools(emailConfig: config, gateway: gateway) {
            await bus.register(tool: tool)
        }
        await ToolsTestSupport.withTestPassword {
            let input = ToolInput(
                toolName: "email.move",
                argumentsJSON: #"{"account":"personal","id":"42","mailbox":"INBOX","destinationMailbox":"Archive"}"#
            )
            let result = await bus.execute(toolCall: input, context: ToolContext(conversationID: UUID()))
            #expect(result.isError == true)
            #expect(result.content.contains("requires approval"))
            #expect(moveCapture.value == nil)
        }
    }

    @Test
    func `Email tools expose six tools including list and move`() {
        // Registration order stays stable so prompts and dashboards can rely on it.
        let config = ToolsTestSupport.testEmailConfig()
        let tools = EmailTools.makeTools(emailConfig: config, gateway: ToolsTestSupport.StubEmailGateway())
        #expect(tools.count == 6)
        #expect(Set(tools.map(\.name)) == Set(["email.search", "email.read", "email.attachment", "email.send", "email.listMailboxes", "email.move"]))
        #expect(EmailTools.toolNames == ["email.search", "email.read", "email.attachment", "email.send", "email.listMailboxes", "email.move"])
        let levels = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0.permissionLevel) })
        #expect(levels["email.listMailboxes"] == .readOnly)
        #expect(levels["email.move"] == .requiresApproval)
    }

    @Test
    func `Bridge script supports list and move with verified TLS`() throws {
        // The embedded helper must stay parseable while covering every list/move op the tools dial.
        let source = EmailIMAPBridgeScript.source
        #expect(source.contains("op == \"list\""))
        #expect(source.contains("op == \"status\""))
        #expect(source.contains("op == \"move\""))
        #expect(source.contains("ssl.create_default_context()"))
        #expect(!source.contains("_create_unverified_context"))
        #expect(!source.contains("CERT_NONE"))
        try ToolsTestSupport.assertBridgeSourceParses(source)
    }

    @Test
    func `Bridge script quotes every mailbox select with shared quoter`() throws {
        // Spaced folders must reach the wire as one quoted atom on every select path.
        let source = EmailIMAPBridgeScript.source
        #expect(source.contains("def quote_mailbox"))
        // A single shared owner keeps read plus move selects from drifting apart.
        #expect(source.components(separatedBy: "def quote_mailbox").count == 2)
        // Shared definition sits above the op dispatch so all paths reach it.
        if let quoter = source.range(of: "def quote_mailbox"),
           let listOp = source.range(of: "op == \"list\"")
        {
            #expect(quoter.lowerBound < listOp.lowerBound)
        } else {
            Issue.record("Expected shared quoter above list dispatch")
        }
        // Backslash plus quote escaping stays inside the shared quoter.
        #expect(source.contains(#"name.replace("\\", "\\\\")"#))
        #expect(source.contains(#"'"%s"' % esc"#))
        // Read, move-source, plus move-destination selects all quote.
        #expect(source.contains("conn.select(quote_mailbox(mailbox)"))
        #expect(source.contains("conn.select(quote_mailbox(src_box)"))
        #expect(source.contains("conn.select(quote_mailbox(dest_box)"))
        // STATUS also quotes through the shared owner so spaced names survive.
        #expect(source.contains("conn.status(quote_mailbox(status_box)"))
        // CR/LF rejection stays ahead of every quoted select to block injection.
        #expect(source.contains("Invalid mailbox"))
        #expect(source.contains("Invalid destination"))
        #expect(source.contains("\\r") && source.contains("\\n"))
        try ToolsTestSupport.assertBridgeSourceParses(source)
    }

    @Test
    func `Bridge STATUS op reports UIDNEXT plus UIDVALIDITY`() throws {
        // The STATUS probe anchors the first fixed window without an open SEARCH.
        let source = EmailIMAPBridgeScript.source
        #expect(source.contains("op == \"status\""))
        #expect(source.contains("UIDNEXT"))
        #expect(source.contains("UIDVALIDITY"))
        #expect(source.contains("conn.status(quote_mailbox(status_box)"))
        #expect(source.contains("\"uidNext\"") || source.contains("\"uid_next\"") || source.contains("uidNext"))
        #expect(source.contains("\"uidValidity\"") || source.contains("\"uid_validity\"") || source.contains("uidValidity"))
        #expect(source.contains("Invalid mailbox"))
        try ToolsTestSupport.assertBridgeSourceParses(source)
        // Request document plus parser stay paired with the script op.
        let creds = ResolvedEmailCredentials(
            accountName: "personal",
            host: "mail.yourdomain.com",
            port: 993,
            username: "you@yourdomain.com",
            password: "test-secret"
        )
        let payload = Data(#"{"ok": true, "mailbox": "INBOX", "uidNext": 2001, "uidValidity": 7}"#.utf8)
        let status = try EmailBridgeParsing.parseStatusPayload(payload)
        #expect(status.mailbox == "INBOX")
        #expect(status.uidNext == 2001)
        #expect(status.uidValidity == 7)
        let snake = Data(#"{"ok": true, "mailbox": "INBOX", "uid_next": 2001, "uid_validity": 7}"#.utf8)
        let snakeStatus = try EmailBridgeParsing.parseStatusPayload(snake)
        #expect(snakeStatus.uidNext == 2001)
        #expect(snakeStatus.uidValidity == 7)
        // Partial payloads fail closed instead of anchoring from a guess.
        for bad in [
            #"{"ok": false, "error": "IMAP status failed"}"#,
            #"{"ok": true, "mailbox": "INBOX"}"#,
            #"{"ok": true, "mailbox": "INBOX", "uidNext": 5}"#,
            #"{"ok": true, "uidNext": 5, "uidValidity": 1}"#
        ] {
            do {
                _ = try EmailBridgeParsing.parseStatusPayload(Data(bad.utf8))
                Issue.record("Expected status failure for \(bad)")
            } catch {
                #expect(!error.localizedDescription.isEmpty)
            }
        }
        _ = creds
    }

    @Test
    func `Bridge script issues bounded UID window as quoted range search`() throws {
        // Every backfill SEARCH carries an explicit fixed window, never an open query.
        let source = EmailIMAPBridgeScript.source
        #expect(source.contains(#"UID \d+:\d+"#) || source.contains("UID "))
        #expect(!source.contains(#"UID 1:\d+"#) || source.contains(#"UID \d+:\d+"#))
        #expect(source.contains("conn.uid(\"search\", None, query)"))
        // The mailbox select ahead of the range stays quoted through the shared owner.
        #expect(source.contains("conn.select(quote_mailbox(mailbox)"))
        #expect(source.contains("readonly=True"))
        // Windowed shape is integers-only from the adapter builder.
        #expect(EmailIMAPMailIndexGateway.uidWindowWidth == 1000)
        #expect(EmailIMAPMailIndexGateway.uidRangeCriterion(beforeUID: 2001) == "UID 1001:2000")
        #expect(EmailIMAPMailIndexGateway.uidRangeCriterion(beforeUID: 51) == "UID 1:50")
        try ToolsTestSupport.assertBridgeSourceParses(source)
    }

    @Test
    func `Bridge source orders IPv4 first before connecting`() throws {
        // Dual-stack hosts stall on IPv6 while IPv4 stays reachable, so the
        // one-shot program reorders once at startup without changing
        // single-family behavior.
        let source = EmailIMAPBridgeScript.source
        #expect(source.contains("def prefer_ipv4"))
        #expect(source.contains("getaddrinfo"))
        #expect(source.contains("AF_INET"))
        #expect(source.contains("prefer_ipv4()"))
        if let call = source.range(of: "prefer_ipv4()"),
           let connect = source.range(of: "IMAP4_SSL")
        {
            #expect(call.lowerBound < connect.lowerBound)
        } else {
            Issue.record("Expected prefer_ipv4 call before IMAP4_SSL")
        }
        if let definition = source.range(of: "def prefer_ipv4"),
           let connect = source.range(of: "IMAP4_SSL")
        {
            #expect(definition.lowerBound < connect.lowerBound)
        } else {
            Issue.record("Expected prefer_ipv4 definition before IMAP4_SSL")
        }
        try ToolsTestSupport.assertBridgeSourceParses(source)
    }

    @Test
    func `Shared prelude prefers IPv4 with fallback over stub socket`() throws {
        // Hermetic ordering proof: a stub getaddrinfo returning IPv6 first
        // must dial IPv4 first, a refused IPv4 must fall through to IPv6,
        // IPv6-only hosts must connect unchanged, and mixed lists must keep
        // relative order inside each family.
        let probe = #"""
        AF4 = socket.AF_INET
        AF6 = socket.AF_INET6
        def v4(addr):
            return (AF4, socket.SOCK_STREAM, 6, "", (addr, 993))
        def v6(addr):
            return (AF6, socket.SOCK_STREAM, 6, "", (addr, 993, 0, 0))
        out = {}
        socket.getaddrinfo = lambda *a, **k: [v6("2001:db8::1"), v4("192.0.2.1")]
        prefer_ipv4()
        ordered = socket.getaddrinfo("mail.example.com", 993)
        out["firstIsV4"] = (ordered[0][0] == AF4)
        dialed = []
        connected = None
        for fam, typ, proto, canon, sa in ordered:
            dialed.append("v4" if fam == AF4 else "v6")
            try:
                if fam == AF4:
                    raise OSError("refused")
                connected = sa
                break
            except OSError:
                continue
        out["dialed"] = dialed
        out["fellThrough"] = (connected is not None and dialed == ["v4", "v6"])
        socket.getaddrinfo = lambda *a, **k: [v6("2001:db8::2")]
        prefer_ipv4()
        only = socket.getaddrinfo("mail.example.com", 993)
        out["v6Only"] = (len(only) == 1 and only[0][0] == AF6)
        socket.getaddrinfo = lambda *a, **k: [v6("2001:db8::a"), v4("192.0.2.10"), v6("2001:db8::b"), v4("192.0.2.11")]
        prefer_ipv4()
        stable = socket.getaddrinfo("mail.example.com", 993)
        out["stable"] = ([s[4][0] for s in stable] == ["192.0.2.10", "192.0.2.11", "2001:db8::a", "2001:db8::b"])
        sys.stdout.write(json.dumps(out))
        """#
        let fullSource = "import sys, json, socket, re\nfrom email.header import decode_header\n"
            + EmailIMAPSharedPrelude.text + "\n" + probe
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", fullSource]
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let stdoutData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        struct ProbeResult: Decodable {
            /// Whether the first entry dials IPv4.
            let firstIsV4: Bool
            /// Families dialed in order.
            let dialed: [String]
            /// Whether a refused IPv4 fell through to IPv6.
            let fellThrough: Bool
            /// Whether an IPv6-only stub connects unchanged.
            let v6Only: Bool
            /// Whether mixed lists keep relative order per family.
            let stable: Bool
        }
        let result = try JSONDecoder().decode(ProbeResult.self, from: stdoutData)
        #expect(result.firstIsV4)
        #expect(result.dialed == ["v4", "v6"])
        #expect(result.fellThrough)
        #expect(result.v6Only)
        #expect(result.stable)
    }

    @Test
    func `Multi-account search with omitted account merges newest-first across accounts`() async throws {
        let gateway = RecordingAccountGateway(hitsByUsername: [
            personalTestUsername: [
                cannedHit(id: "p2", day: 5),
                cannedHit(id: "p0", day: 1)
            ],
            workTestUsername: [
                cannedHit(id: "w1", day: 3),
                cannedHit(id: "w0", day: 2)
            ]
        ])
        let tool = EmailSearchTool(emailConfig: twoAccountTestConfig(), gateway: gateway)
        try await withTwoAccountPasswords {
            let output = try await tool.execute(
                input: ToolInput(toolName: "email.search", argumentsJSON: #"{"query":"canned","limit":2}"#),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == false)
            let envelope = try JSONDecoder().decode(EmailSearchEnvelope.self, from: Data(output.content.utf8))
            #expect(envelope.account == "all")
            #expect(envelope.accounts == ["personal", "work"])
            #expect((envelope.failedAccounts ?? []).isEmpty)
            #expect(envelope.count == 2)
            #expect(envelope.messages.count == envelope.count)
            // Global newest-first merge across accounts, capped to the requested limit.
            #expect(envelope.messages.map(\.id) == ["p2", "w1"])
            // Every hit carries the owning account so follow-up reads stay routable.
            #expect(envelope.messages.map(\.account) == ["personal", "work"])
            for hit in envelope.messages {
                #expect(!hit.account.isEmpty)
                #expect(!hit.mailbox.isEmpty)
            }
            // The recording proves every configured account was actually dialed.
            #expect(Set(gateway.searchedUsernames) == Set([personalTestUsername, workTestUsername]))
        }
    }

    @Test
    func `Multi-account search treats blank and star account spellings as all accounts`() async throws {
        // Omitted, blank-after-trim, and the literal star must all select every
        // configured account with byte-identical envelope semantics.
        let payloads: [(String, String)] = [
            ("omitted", #"{"query":"canned","limit":2}"#),
            ("blank", #"{"account":"   ","query":"canned","limit":2}"#),
            ("star", #"{"account":"*","query":"canned","limit":2}"#)
        ]
        for (spelling, payload) in payloads {
            let gateway = RecordingAccountGateway(hitsByUsername: [
                personalTestUsername: [cannedHit(id: "p2", day: 5), cannedHit(id: "p0", day: 1)],
                workTestUsername: [cannedHit(id: "w1", day: 3)]
            ])
            let tool = EmailSearchTool(emailConfig: twoAccountTestConfig(), gateway: gateway)
            try await withTwoAccountPasswords {
                let output = try await tool.execute(
                    input: ToolInput(toolName: "email.search", argumentsJSON: payload),
                    context: ToolContext(conversationID: UUID())
                )
                #expect(output.isError == false, "spelling: \(spelling)")
                let envelope = try JSONDecoder().decode(EmailSearchEnvelope.self, from: Data(output.content.utf8))
                #expect(envelope.account == "all", "spelling: \(spelling)")
                #expect(envelope.accounts == ["personal", "work"], "spelling: \(spelling)")
                #expect(envelope.messages.map(\.id) == ["p2", "w1"], "spelling: \(spelling)")
                #expect(
                    Set(gateway.searchedUsernames) == Set([personalTestUsername, workTestUsername]),
                    "spelling: \(spelling)"
                )
            }
        }
    }

    @Test
    func `Multi-account search is fail-soft and names the failed account`() async throws {
        let gateway = RecordingAccountGateway(
            hitsByUsername: [personalTestUsername: [cannedHit(id: "p2", day: 5), cannedHit(id: "p0", day: 1)]],
            failuresByUsername: [workTestUsername: "work server offline"]
        )
        let tool = EmailSearchTool(emailConfig: twoAccountTestConfig(), gateway: gateway)
        try await withTwoAccountPasswords {
            let output = try await tool.execute(
                input: ToolInput(toolName: "email.search", argumentsJSON: #"{"query":"canned","limit":5}"#),
                context: ToolContext(conversationID: UUID())
            )
            // At least one success keeps the call successful; coverage gaps are
            // reported on the envelope instead of failing the whole search.
            #expect(output.isError == false)
            let envelope = try JSONDecoder().decode(EmailSearchEnvelope.self, from: Data(output.content.utf8))
            #expect(envelope.account == "all")
            #expect(envelope.messages.map(\.id) == ["p2", "p0"])
            #expect(envelope.messages.allSatisfy { $0.account == "personal" })
            #expect(envelope.accounts == ["personal"])
            #expect(envelope.failedAccounts == ["work"])
            // The failing account was still dialed — its failure is a runtime outcome.
            #expect(Set(gateway.searchedUsernames) == Set([personalTestUsername, workTestUsername]))
            #expect(!output.content.contains("test-secret"))
        }
    }

    @Test
    func `Multi-account search with mailbox only runs accounts holding the folder`() async throws {
        let archiveHit = EmailSearchHit(
            id: "a7",
            subject: "Archive note",
            from: "archive@example.com",
            date: "Thu, 04 Sep 2025 10:00:00 +0000",
            snippet: "Older archive body",
            mailbox: "Archive"
        )
        let gateway = RecordingAccountGateway(
            hitsByUsername: [
                personalTestUsername: [cannedHit(id: "p2", day: 5)],
                workTestUsername: [archiveHit]
            ],
            mailboxesByUsername: [workTestUsername: ["INBOX", "Archive"]]
        )
        let tool = EmailSearchTool(emailConfig: twoAccountTestConfig(), gateway: gateway)
        try await withTwoAccountPasswords {
            let output = try await tool.execute(
                input: ToolInput(toolName: "email.search", argumentsJSON: #"{"query":"canned","mailbox":"Archive","limit":5}"#),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == false)
            let envelope = try JSONDecoder().decode(EmailSearchEnvelope.self, from: Data(output.content.utf8))
            // An account lacking the requested folder is skipped silently: never
            // searched, never listed as searched, and never listed as failed.
            #expect(envelope.messages.map(\.id) == ["a7"])
            #expect(envelope.messages[0].mailbox == "Archive")
            #expect(envelope.messages[0].account == "work")
            #expect(envelope.accounts == ["work"])
            #expect((envelope.failedAccounts ?? []).isEmpty)
            #expect(gateway.searchedUsernames == [workTestUsername])
            // Zero accounts holding the requested folder fails the call naming what is available.
            let missing = try await tool.execute(
                input: ToolInput(toolName: "email.search", argumentsJSON: #"{"query":"canned","mailbox":"Missing","limit":5}"#),
                context: ToolContext(conversationID: UUID())
            )
            #expect(missing.isError == true)
            #expect(missing.content.contains("Missing"))
            #expect(missing.content.contains("INBOX"))
        }
    }

    @Test
    func `Explicit single account search keeps single-account shape with one accounts entry`() async throws {
        let gateway = RecordingAccountGateway(hitsByUsername: [
            personalTestUsername: [cannedHit(id: "p2", day: 5), cannedHit(id: "p0", day: 1)]
        ])
        let tool = EmailSearchTool(emailConfig: twoAccountTestConfig(), gateway: gateway)
        try await withTwoAccountPasswords {
            let output = try await tool.execute(
                input: ToolInput(toolName: "email.search", argumentsJSON: #"{"account":"personal","query":"canned","limit":2}"#),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == false)
            let envelope = try JSONDecoder().decode(EmailSearchEnvelope.self, from: Data(output.content.utf8))
            // Single-account calls echo the account name, never the all-accounts marker.
            #expect(envelope.account == "personal")
            #expect(envelope.accounts == ["personal"])
            #expect((envelope.failedAccounts ?? []).isEmpty)
            #expect(envelope.messages.map(\.account) == ["personal", "personal"])
            #expect(Set(gateway.searchedUsernames) == Set([personalTestUsername]))
        }
    }

    @Test
    func `Multi-account search fails when every account fails surfacing the failure text`() async throws {
        // Shared failure text across both accounts keeps the assertion about
        // failure-text surfacing (not task-group arrival order) deterministic.
        let gateway = RecordingAccountGateway(
            failuresByUsername: [
                personalTestUsername: "email gateway exploded",
                workTestUsername: "email gateway exploded"
            ]
        )
        let tool = EmailSearchTool(emailConfig: twoAccountTestConfig(), gateway: gateway)
        try await withTwoAccountPasswords {
            let output = try await tool.execute(
                input: ToolInput(toolName: "email.search", argumentsJSON: #"{"query":"canned","limit":5}"#),
                context: ToolContext(conversationID: UUID())
            )
            // Zero successes fails the whole call rather than returning an empty success.
            #expect(output.isError == true)
            #expect(output.content.contains("email gateway exploded"))
            #expect(Set(gateway.searchedUsernames) == Set([personalTestUsername, workTestUsername]))
            #expect(!output.content.contains("test-secret"))
        }
    }

    @Test
    func `Multi-account search aborts the whole call when a gateway child is cancelled`() async throws {
        // The fan-out is fail-soft for ordinary gateway failures but fail-closed
        // for cancellation: one cancelled child must abort the entire call rather
        // than let a healthy sibling's hits degrade the result into a partial
        // envelope. The gateway throws the cancellation synchronously during the
        // personal account's search while work holds hits that would otherwise
        // produce a successful partial, so whichever child finishes first, the
        // only possible outcome is the aborted call.
        let gateway = RecordingAccountGateway(
            hitsByUsername: [workTestUsername: [cannedHit(id: "w1", day: 3)]],
            cancellingUsername: personalTestUsername
        )
        let tool = EmailSearchTool(emailConfig: twoAccountTestConfig(), gateway: gateway)
        try await withTwoAccountPasswords {
            let output = try await tool.execute(
                input: ToolInput(toolName: "email.search", argumentsJSON: #"{"query":"canned","limit":5}"#),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == true)
            // No envelope comes back at all — not even one covering the healthy account.
            let envelope = try? JSONDecoder().decode(EmailSearchEnvelope.self, from: Data(output.content.utf8))
            #expect(envelope == nil)
            #expect(!output.content.contains("w1"))
            // The surfaced failure is the cancellation itself, not failure-soft copy.
            #expect(output.content == CancellationError().localizedDescription)
        }
    }

    @Test
    func `Multi-account search with no configured accounts fails before any search`() async throws {
        // Nothing to fan out to: the call must fail closed without dialing anything.
        let gateway = RecordingAccountGateway()
        let tool = EmailSearchTool(emailConfig: EmailConfig(accounts: []), gateway: gateway)
        let output = try await tool.execute(
            input: ToolInput(toolName: "email.search", argumentsJSON: #"{"query":"canned"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == true)
        #expect(gateway.searchedUsernames.isEmpty)
    }

    @Test
    func `Multi-account search caps merged hits across oversized per-account pools`() async throws {
        var personalPool: [EmailSearchHit] = []
        var workPool: [EmailSearchHit] = []
        // Pools stay newest-first like a real bridge response. Disjoint date
        // ranges keep the merged order unambiguous: work owns the eight newest dates.
        for index in stride(from: 7, through: 0, by: -1) {
            personalPool.append(cannedHit(id: "p\(index)", day: 1 + index))
            workPool.append(cannedHit(id: "w\(index)", day: 10 + index))
        }
        let gateway = RecordingAccountGateway(hitsByUsername: [
            personalTestUsername: personalPool,
            workTestUsername: workPool
        ])
        let tool = EmailSearchTool(emailConfig: twoAccountTestConfig(), gateway: gateway)
        try await withTwoAccountPasswords {
            let output = try await tool.execute(
                input: ToolInput(toolName: "email.search", argumentsJSON: #"{"query":"canned","limit":3}"#),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == false)
            let envelope = try JSONDecoder().decode(EmailSearchEnvelope.self, from: Data(output.content.utf8))
            // `limit` is a global total cap, not a per-account or per-mailbox budget.
            #expect(envelope.count == 3)
            #expect(envelope.messages.count == 3)
            #expect(envelope.messages.map(\.id) == ["w7", "w6", "w5"])
            #expect(envelope.messages.allSatisfy { $0.account == "work" })
        }
    }

    @Test
    func `Unknown explicit account fails naming available accounts without searching`() async throws {
        let gateway = RecordingAccountGateway()
        let tool = EmailSearchTool(emailConfig: twoAccountTestConfig(), gateway: gateway)
        let output = try await tool.execute(
            input: ToolInput(toolName: "email.search", argumentsJSON: #"{"account":"missing","query":"canned"}"#),
            context: ToolContext(conversationID: UUID())
        )
        // An explicit unknown name fails before any account is dialed and names
        // the configured alternatives without echoing any secret.
        #expect(output.isError == true)
        #expect(output.content.contains("missing"))
        #expect(output.content.contains("personal"))
        #expect(output.content.contains("work"))
        #expect(gateway.searchedUsernames.isEmpty)
        #expect(!output.content.contains("test-secret"))
    }

    @Test
    func `Search args decode omitted blank and star account as all-accounts requests`() throws {
        // The selector collapses at the model boundary so the tool layer only
        // ever sees nil (all) or a concrete trimmed name.
        let omitted = try JSONDecoder().decode(EmailSearchArgs.self, from: Data(#"{"query":"hi"}"#.utf8))
        #expect(omitted.account == nil)
        #expect(omitted.trimmedAccount == nil)
        #expect(omitted.isAllAccountsRequest == true)
        let blank = try JSONDecoder().decode(EmailSearchArgs.self, from: Data(#"{"account":"   ","query":"hi"}"#.utf8))
        #expect(blank.trimmedAccount == nil)
        #expect(blank.isAllAccountsRequest == true)
        let star = try JSONDecoder().decode(EmailSearchArgs.self, from: Data(#"{"account":"*","query":"hi"}"#.utf8))
        #expect(star.trimmedAccount == nil)
        #expect(star.isAllAccountsRequest == true)
        let padded = try JSONDecoder().decode(EmailSearchArgs.self, from: Data(#"{"account":" personal ","query":"hi"}"#.utf8))
        #expect(padded.account == " personal ")
        #expect(padded.trimmedAccount == "personal")
        #expect(padded.isAllAccountsRequest == false)
    }

    @Test
    func `Legacy search hit without account decodes with empty account`() throws {
        // Bridge payloads from before per-hit account labeling must still decode.
        let legacy = Data(
            #"{"id":"42","subject":"Old wire","from":"boss@example.com","date":"Mon, 01 Sep 2025 09:00:00 +0000","snippet":"pre-account payload"}"#
                .utf8
        )
        let hit = try JSONDecoder().decode(EmailSearchHit.self, from: legacy)
        #expect(hit.account == "")
        #expect(hit.mailbox == "INBOX")
        let encoded = try JSONEncoder().encode(hit)
        let roundTripped = try JSONDecoder().decode(EmailSearchHit.self, from: encoded)
        #expect(roundTripped == hit)
    }

    @Test
    func `Legacy search envelope without multi-account keys decodes tolerantly`() throws {
        let legacy = Data(
            #"{"account":"personal","query":"hi","count":1,"messages":[{"id":"42","subject":"Old wire","from":"boss@example.com","date":"Mon, 01 Sep 2025 09:00:00 +0000","snippet":"pre-multi-account payload"}]}"#
                .utf8
        )
        let envelope = try JSONDecoder().decode(EmailSearchEnvelope.self, from: legacy)
        #expect(envelope.account == "personal")
        #expect(envelope.accounts == nil)
        #expect(envelope.failedAccounts == nil)
        // Count always derives from the messages, never from the wire value.
        #expect(envelope.count == envelope.messages.count)
        #expect(envelope.messages[0].account == "")
        // Real tool output carries the multi-account keys even for one account:
        // the search tool always passes `accounts:[name]` and `failedAccounts:[]`,
        // so a decoded legacy envelope re-encoded like current tool output gains
        // them rather than keeping the pre-multi-account byte shape.
        let encoded = try EmailBridgeParsing.encodeSearchEnvelope(
            account: "personal",
            query: "hi",
            messages: envelope.messages,
            accounts: ["personal"],
            failedAccounts: []
        )
        #expect(encoded.contains("\"accounts\""))
        #expect(encoded.contains("\"failedAccounts\""))
        let decoded = try JSONDecoder().decode(EmailSearchEnvelope.self, from: Data(encoded.utf8))
        #expect(decoded.account == "personal")
        #expect(decoded.accounts == ["personal"])
        #expect(decoded.failedAccounts == [])
        #expect(decoded.messages == envelope.messages)
        // Omission stays reserved for callers that pass nil keys, which the
        // search tool no longer does.
        let withoutKeys = try EmailBridgeParsing.encodeSearchEnvelope(
            account: "personal",
            query: "hi",
            messages: envelope.messages
        )
        #expect(!withoutKeys.contains("\"accounts\""))
        #expect(!withoutKeys.contains("\"failedAccounts\""))
    }

    @Test
    func `Multi-account envelope preserves account routing fields through agentVisible and round-trip`() throws {
        let personalHit = EmailSearchHit(
            id: "p1",
            subject: "Roadmap thread",
            from: "boss@example.com",
            date: "Mon, 01 Sep 2025 09:00:00 +0000",
            snippet: "plain planning notes",
            mailbox: "INBOX",
            account: "personal"
        )
        let workHit = EmailSearchHit(
            id: "w1",
            subject: "Vendor thread",
            from: "vendor@example.com",
            date: "Tue, 02 Sep 2025 09:00:00 +0000",
            snippet: "plain vendor notes",
            mailbox: "INBOX",
            account: "work"
        )
        let envelope = EmailSearchEnvelope(
            account: "all",
            query: "roadmap",
            messages: [workHit, personalHit],
            accounts: ["personal", "work"],
            failedAccounts: ["work"]
        )
        // The credential filter may rewrite subject/snippet text but must never
        // touch the account-routing trio or the per-hit account labels.
        let visible = envelope.agentVisible()
        #expect(visible.account == "all")
        #expect(visible.accounts == ["personal", "work"])
        #expect(visible.failedAccounts == ["work"])
        #expect(visible.messages.map(\.account) == ["work", "personal"])
        #expect(visible.count == 2)
        let encoded = try EmailBridgeParsing.encodeSearchEnvelope(
            account: visible.account,
            query: visible.query,
            messages: visible.messages,
            accounts: visible.accounts,
            failedAccounts: visible.failedAccounts
        )
        let decoded = try JSONDecoder().decode(EmailSearchEnvelope.self, from: Data(encoded.utf8))
        #expect(decoded == visible)
        #expect(decoded.account == "all")
        #expect(decoded.accounts == ["personal", "work"])
        #expect(decoded.failedAccounts == ["work"])
        #expect(decoded.messages.map(\.account) == ["work", "personal"])
    }
}

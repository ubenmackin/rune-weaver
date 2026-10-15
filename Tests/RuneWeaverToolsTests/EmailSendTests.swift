// Rune Weaver Tools Tests — Approval-gated email.send over SMTP.
import Foundation
import os
@testable import RuneWeaverCore
@testable import RuneWeaverTools
import Testing

/// Locked box recording stub SMTP sends without touching the network.
private final class SendBox: Sendable {
    private struct State: Sendable {
        var calls = 0
        var lastTo: [String] = []
        var lastMessage: EmailSMTPMessage?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var calls: Int {
        state.withLock { $0.calls }
    }

    var lastTo: [String] {
        state.withLock { $0.lastTo }
    }

    var lastMessage: EmailSMTPMessage? {
        state.withLock { $0.lastMessage }
    }

    /// Records one send call.
    /// - Parameter message: Message passed to the gateway.
    func record(message: EmailSMTPMessage) {
        state.withLock {
            $0.calls += 1
            $0.lastTo = message.to
            $0.lastMessage = message
        }
    }

    /// Records one send call.
    /// - Parameter to: Recipients passed to the gateway.
    func record(to: [String]) {
        state.withLock {
            $0.calls += 1
            $0.lastTo = to
        }
    }
}

/// Stub SMTP gateway returning success or a canned failure.
private struct StubSMTPGateway: EmailSMTPGateway, Sendable {
    /// Bridge failure to throw, when set.
    let failure: String?
    /// Box receiving send calls, when set.
    let box: SendBox?

    /// Creates a stub gateway.
    init(failure: String? = nil, box: SendBox? = nil) {
        self.failure = failure
        self.box = box
    }

    /// Records the send or throws the canned failure.
    func send(
        credentials _: ResolvedEmailCredentials,
        message: EmailSMTPMessage
    ) async throws {
        if let failure {
            throw EmailIMAPError.bridgeFailed(failure)
        }
        box?.record(message: message)
    }
}

/// Locked box recording stub IMAP calls for threading and Sent tests.
private final class IMAPBox: Sendable {
    private struct State: Sendable {
        var fetchCalls = 0
        var appendCalls = 0
        var listCalls = 0
        var lastAppendMailbox: String?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var fetchCalls: Int {
        state.withLock { $0.fetchCalls }
    }

    var appendCalls: Int {
        state.withLock { $0.appendCalls }
    }

    var listCalls: Int {
        state.withLock { $0.listCalls }
    }

    var lastAppendMailbox: String? {
        state.withLock { $0.lastAppendMailbox }
    }

    /// Records a fetch call.
    func recordFetch() {
        state.withLock { $0.fetchCalls += 1 }
    }

    /// Records a list call.
    func recordList() {
        state.withLock { $0.listCalls += 1 }
    }

    /// Records an append call.
    /// - Parameter mailbox: Destination mailbox.
    func recordAppend(mailbox: String) {
        state.withLock {
            $0.appendCalls += 1
            $0.lastAppendMailbox = mailbox
        }
    }
}

/// Stub IMAP gateway for threading fetches and Sent appends.
private struct StubSendIMAPGateway: EmailIMAPGateway, Sendable {
    /// Message returned by `fetch`.
    let message: EmailFullMessage?
    /// Mailboxes returned by `listMailboxes`.
    let mailboxes: [String]
    /// Failure thrown by `append`, when set (fetch/list still succeed).
    let appendFailure: String?
    /// Box receiving call counts.
    let box: IMAPBox?

    /// Creates a stub gateway.
    init(message: EmailFullMessage? = nil, mailboxes: [String] = ["INBOX"], appendFailure: String? = nil, box: IMAPBox? = nil) {
        self.message = message
        self.mailboxes = mailboxes
        self.appendFailure = appendFailure
        self.box = box
    }

    /// Returns empty hits (unused by send tests).
    func search(credentials _: ResolvedEmailCredentials, mailbox _: String, query _: String, limit _: Int) async throws -> [EmailSearchHit] {
        []
    }

    /// Returns canned attachment bytes (unused by send tests).
    func attachment(credentials _: ResolvedEmailCredentials, mailbox _: String, messageID _: String, attachmentIndex _: Int) async throws -> EmailAttachmentData {
        throw EmailIMAPError.bridgeFailed("No attachments in send stub")
    }

    /// Returns canned mailboxes with hierarchy separators for list coverage.
    func mailboxListing(credentials _: ResolvedEmailCredentials) async throws -> EmailMailboxListing {
        box?.recordList()
        return EmailMailboxListing(mailboxes: mailboxes, delimiter: "/")
    }

    /// Canned move supporting list/move registration without touching the network.
    func move(
        credentials _: ResolvedEmailCredentials,
        mailbox sourceMailbox: String,
        messageID _: String,
        destination: String,
        markAsRead: Bool
    ) async throws -> EmailMoveResult {
        // Same-folder moves are no-ops by contract, so report them without pretending to copy.
        if sourceMailbox.lowercased() == destination.lowercased() {
            return EmailMoveResult(mailbox: sourceMailbox, destination: destination, moved: false, markedAsRead: markAsRead)
        }
        return EmailMoveResult(mailbox: sourceMailbox, destination: destination, moved: true, markedAsRead: markAsRead)
    }

    /// Shim for old callers delegating to the richer listing.
    func listMailboxes(credentials: ResolvedEmailCredentials) async throws -> [String] {
        try await mailboxListing(credentials: credentials).mailboxes
    }

    /// Returns the canned message for one mailbox.
    func fetch(credentials _: ResolvedEmailCredentials, mailbox _: String, messageID: String) async throws -> EmailFullMessage {
        box?.recordFetch()
        guard let message else {
            throw EmailIMAPError.bridgeFailed("Message \(messageID) not found")
        }
        return message
    }

    /// Records the append or throws the canned failure.
    func append(credentials _: ResolvedEmailCredentials, mailbox: String, rawMessage _: Data) async throws {
        box?.recordAppend(mailbox: mailbox)
        if let appendFailure {
            throw EmailIMAPError.bridgeFailed(appendFailure)
        }
    }
}

/// Builds a send payload with explicit fields for injection tests.
private func sendPayload(
    account: String = "personal",
    to: [String] = ["friend@example.com"],
    cc: [String]? = nil,
    bcc: [String]? = nil,
    subject: String = "Hello",
    bodyText: String? = "Hi there",
    bodyHtml: String? = nil,
    attachmentPaths: [String]? = nil,
    replyToId: String? = nil,
    mailbox: String? = nil,
    scheduleAt: Any? = nil
) throws -> String {
    var doc: [String: Any] = [
        "account": account,
        "to": to,
        "subject": subject
    ]
    if let bodyText {
        doc["bodyText"] = bodyText
    }
    if let cc {
        doc["cc"] = cc
    }
    if let bcc {
        doc["bcc"] = bcc
    }
    if let bodyHtml {
        doc["bodyHtml"] = bodyHtml
    }
    if let attachmentPaths {
        doc["attachmentPaths"] = attachmentPaths
    }
    if let replyToId {
        doc["replyToId"] = replyToId
    }
    if let mailbox {
        doc["mailbox"] = mailbox
    }
    if let scheduleAt {
        doc["scheduleAt"] = scheduleAt
    }
    let data = try JSONSerialization.data(withJSONObject: doc)
    return String(bytes: data, encoding: .utf8) ?? "{}"
}

/// Minute-aligned future fire time so the stored instant equals the requested one.
private func minuteAlignedFutureFireAt(hoursAhead: Double = 1) -> Date {
    let raw = Date().addingTimeInterval(hoursAhead * 3600)
    let epoch = raw.timeIntervalSince1970
    return Date(timeIntervalSince1970: epoch - epoch.truncatingRemainder(dividingBy: 60))
}

/// Locked box recording booking drafts without touching a store.
private final class BookingBox: Sendable {
    private struct State: Sendable {
        var drafts: [ScheduledSendDraft] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var count: Int {
        state.withLock { $0.drafts.count }
    }

    var drafts: [ScheduledSendDraft] {
        state.withLock { $0.drafts }
    }

    /// Records one booking draft.
    /// - Parameter draft: Draft passed to the seam.
    func record(_ draft: ScheduledSendDraft) {
        state.withLock { $0.drafts.append(draft) }
    }
}

/// Stub booking seam recording drafts or throwing a canned failure.
private struct StubBooking: ScheduledSendBooking, Sendable {
    /// Box receiving drafts, when set.
    let box: BookingBox?
    /// Failure thrown by `book`, when set.
    let failure: String?

    /// Creates a stub booking.
    init(box: BookingBox? = nil, failure: String? = nil) {
        self.box = box
        self.failure = failure
    }

    /// Records the draft and returns a receipt, or throws the canned failure.
    func book(_ draft: ScheduledSendDraft) async throws -> BookedScheduledSend {
        if let failure {
            throw EmailIMAPError.bridgeFailed(failure)
        }
        box?.record(draft)
        return BookedScheduledSend(id: UUID(), fireAt: draft.fireAt)
    }
}

/// Serialized plus `testCredentialEnvLock`: send tests install the stub account password via
/// `setenv`, which is process-global, so this suite serializes internally and shares the cross-
/// suite gate with the IMAP and smoke suites. `HOME` is never mutated.
@Suite("Email Send", .serialized)
struct EmailSendTests {
    @Test
    func `Send address validation accepts bare mailboxes and rejects shapes`() throws {
        #expect(EmailSendValidation.isValidEmail("friend@example.com") == true)
        #expect(EmailSendValidation.isValidEmail("first.last+tag@sub.example.co") == true)
        #expect(EmailSendValidation.isValidEmail("USER@EXAMPLE.COM") == true)
        #expect(EmailSendValidation.isValidEmail("not-an-email") == false)
        #expect(EmailSendValidation.isValidEmail("a@b.c") == false)
        #expect(EmailSendValidation.isValidEmail("Bob <bob@example.com>") == false)
        #expect(EmailSendValidation.isValidEmail("a@example.com\r\nBcc: evil@example.com") == false)
        #expect(EmailSendValidation.isValidEmail("") == false)
        #expect(EmailSendValidation.isValidEmail("   ") == false)
        try EmailSendValidation.validateAddress("friend@example.com", field: "to")
    }

    @Test
    func `Send tool rejects invalid addresses before credentials`() async throws {
        let config = ToolsTestSupport.testEmailConfig()
        let tool = EmailSendTool(emailConfig: config, smtpGateway: StubSMTPGateway())
        // No stub password installed: validation must win over the
        // missing-credential path so bad input reports the field error.
        let output = try await tool.execute(
            input: ToolInput(toolName: "email.send", argumentsJSON: sendPayload(to: ["not-an-email"])),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == true)
        #expect(output.content.contains("Invalid recipient"))
        #expect(!output.content.contains("Missing password"))
    }

    @Test
    func `Send tool rejects CR LF header injection in subject and addresses`() async throws {
        let config = ToolsTestSupport.testEmailConfig()
        let tool = EmailSendTool(emailConfig: config, smtpGateway: StubSMTPGateway())
        let subjectInjection = #"{"account":"personal","to":["friend@example.com"],"subject":"hi\r\nBcc: evil@example.com","bodyText":"hello"}"#
        let subjectOutput = try await tool.execute(
            input: ToolInput(toolName: "email.send", argumentsJSON: subjectInjection),
            context: ToolContext(conversationID: UUID())
        )
        #expect(subjectOutput.isError == true)
        #expect(subjectOutput.content.contains("Invalid subject"))
        let toInjection = #"{"account":"personal","to":["friend@example.com\r\nBcc: evil@example.com"],"subject":"Hello","bodyText":"hello"}"#
        let toOutput = try await tool.execute(
            input: ToolInput(toolName: "email.send", argumentsJSON: toInjection),
            context: ToolContext(conversationID: UUID())
        )
        #expect(toOutput.isError == true)
        #expect(toOutput.content.contains("Invalid recipient"))
    }

    @Test
    func `Send tool enforces subject and body caps`() async throws {
        let config = ToolsTestSupport.testEmailConfig()
        let tool = EmailSendTool(emailConfig: config, smtpGateway: StubSMTPGateway())
        let longSubject = String(repeating: "a", count: EmailSendValidation.maxSubjectChars + 1)
        let subjectOutput = try await tool.execute(
            input: ToolInput(toolName: "email.send", argumentsJSON: sendPayload(subject: longSubject)),
            context: ToolContext(conversationID: UUID())
        )
        #expect(subjectOutput.isError == true)
        #expect(subjectOutput.content.contains("Invalid subject"))
        let bigBody = String(repeating: "a", count: EmailSendValidation.maxBodyBytes + 1)
        let bodyOutput = try await tool.execute(
            input: ToolInput(toolName: "email.send", argumentsJSON: sendPayload(bodyText: bigBody)),
            context: ToolContext(conversationID: UUID())
        )
        #expect(bodyOutput.isError == true)
        #expect(bodyOutput.content.contains("1 MB"))
        let okSubject = String(repeating: "s", count: EmailSendValidation.maxSubjectChars)
        try EmailSendValidation.validateBody("hello", field: "bodyText")
        #expect(EmailSendValidation.isValidEmail("a@example.com") == true)
        _ = try EmailSendValidation.validateSubject(okSubject)
    }

    @Test
    func `Send tool enforces recipient count caps`() async throws {
        let config = ToolsTestSupport.testEmailConfig()
        let tool = EmailSendTool(emailConfig: config, smtpGateway: StubSMTPGateway())
        let empty = try await tool.execute(
            input: ToolInput(toolName: "email.send", argumentsJSON: sendPayload(to: [])),
            context: ToolContext(conversationID: UUID())
        )
        #expect(empty.isError == true)
        #expect(empty.content.contains("Invalid recipients"))
        let many = Array(repeating: "friend@example.com", count: EmailSendValidation.maxRecipientsPerField + 1)
        let crowded = try await tool.execute(
            input: ToolInput(toolName: "email.send", argumentsJSON: sendPayload(to: many)),
            context: ToolContext(conversationID: UUID())
        )
        #expect(crowded.isError == true)
        #expect(crowded.content.contains("at most 20"))
    }

    @Test
    func `Send tool dry run validates without network use`() async throws {
        let box = SendBox()
        let tool = EmailSendTool(emailConfig: ToolsTestSupport.testEmailConfig(), smtpGateway: StubSMTPGateway(box: box))
        try await ToolsTestSupport.withTestPassword {
            let output = try await tool.execute(
                input: ToolInput(toolName: "email.send", argumentsJSON: sendPayload()),
                context: ToolContext(conversationID: UUID(), dryRun: true)
            )
            #expect(output.isError == false)
            #expect(box.calls == 0)
            let envelope = try JSONDecoder().decode(EmailSendEnvelope.self, from: Data(output.content.utf8))
            #expect(envelope.dryRun == true)
            #expect(envelope.account == "personal")
            #expect(envelope.from == "you@yourdomain.com")
            #expect(envelope.to == ["friend@example.com"])
            #expect(envelope.subject == "Hello")
            #expect((envelope.note ?? "").contains("Dry run"))
            #expect(!output.content.contains("test-secret"))
        }
    }

    @Test
    func `Send tool sends through stubbed gateway with sender default`() async throws {
        let box = SendBox()
        let tool = EmailSendTool(
            emailConfig: ToolsTestSupport.testEmailConfig(),
            smtpGateway: StubSMTPGateway(box: box),
            gateway: StubSendIMAPGateway(mailboxes: ["INBOX", "Sent"])
        )
        try await ToolsTestSupport.withTestPassword {
            let output = try await tool.execute(
                input: ToolInput(
                    toolName: "email.send",
                    argumentsJSON: sendPayload(
                        to: ["a@example.com", "b@example.com"],
                        cc: ["c@example.com"],
                        subject: "Meeting",
                        bodyText: "See you at noon",
                        bodyHtml: "<p>See you at noon</p>"
                    )
                ),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == false)
            #expect(box.calls == 1)
            #expect(box.lastTo == ["a@example.com", "b@example.com"])
            let envelope = try JSONDecoder().decode(EmailSendEnvelope.self, from: Data(output.content.utf8))
            #expect(envelope.dryRun == false)
            #expect(envelope.from == "you@yourdomain.com")
            #expect(envelope.to == ["a@example.com", "b@example.com"])
            #expect(envelope.cc == ["c@example.com"])
            #expect(envelope.bcc == [])
            #expect(envelope.subject == "Meeting")
            #expect(envelope.bodyHtmlBytes != nil)
            #expect(!output.content.contains("test-secret"))
        }
    }

    @Test
    func `Send tool surfaces gateway failure without secrets`() async throws {
        let tool = EmailSendTool(
            emailConfig: ToolsTestSupport.testEmailConfig(),
            smtpGateway: StubSMTPGateway(failure: "SMTP send failed: mailbox unavailable")
        )
        try await ToolsTestSupport.withTestPassword {
            let output = try await tool.execute(
                input: ToolInput(toolName: "email.send", argumentsJSON: sendPayload()),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == true)
            #expect(output.content.contains("SMTP send failed"))
            #expect(!output.content.contains("test-secret"))
        }
    }

    @Test
    func `Send tool rejects unknown account without secrets`() async throws {
        let tool = EmailSendTool(emailConfig: ToolsTestSupport.testEmailConfig(), smtpGateway: StubSMTPGateway())
        let output = try await tool.execute(
            input: ToolInput(toolName: "email.send", argumentsJSON: sendPayload(account: "missing")),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == true)
        #expect(output.content.contains("missing"))
        #expect(!output.content.contains("test-secret"))
    }

    @Test
    func `Send tool requires approval without a handler`() async {
        let box = SendBox()
        let config = ToolsTestSupport.testEmailConfig()
        let bus = ToolBus(permissionGate: PermissionGate())
        for tool in EmailTools.makeTools(emailConfig: config, smtpGateway: StubSMTPGateway(box: box)) {
            await bus.register(tool: tool)
        }
        await ToolsTestSupport.withTestPassword {
            let input = ToolInput(toolName: "email.send", argumentsJSON: (try? sendPayload()) ?? "{}")
            let result = await bus.execute(toolCall: input, context: ToolContext(conversationID: UUID()))
            #expect(result.isError == true)
            #expect(result.content.contains("requires approval"))
            #expect(box.calls == 0)
        }
    }

    @Test
    func `Email tools expose gated send as sixth tool in six-tool set`() {
        let config = ToolsTestSupport.testEmailConfig()
        let tools = EmailTools.makeTools(emailConfig: config, smtpGateway: StubSMTPGateway())
        #expect(tools.count == 6)
        #expect(Set(tools.map(\.name)) == Set(["email.search", "email.read", "email.attachment", "email.send", "email.listMailboxes", "email.move"]))
        #expect(EmailTools.toolNames == ["email.search", "email.read", "email.attachment", "email.send", "email.listMailboxes", "email.move"])
        let levels = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0.permissionLevel) })
        #expect(levels["email.send"] == .requiresApproval)
        #expect(levels["email.listMailboxes"] == .readOnly)
        #expect(levels["email.move"] == .requiresApproval)
    }

    @Test
    func `Send args decode cc bcc and html`() throws {
        let args = try JSONDecoder().decode(
            EmailSendArgs.self,
            from: Data(
                #"{"account":"personal","to":["a@example.com"],"cc":["c@example.com"],"bcc":["d@example.com"],"subject":"Hi","bodyText":"hello","bodyHtml":"<b>hello</b>"}"#.utf8
            )
        )
        #expect(args.account == "personal")
        #expect(args.to == ["a@example.com"])
        #expect(args.cc == ["c@example.com"])
        #expect(args.bcc == ["d@example.com"])
        #expect(args.bodyHtml == "<b>hello</b>")
        let minimal = try JSONDecoder().decode(
            EmailSendArgs.self,
            from: Data(#"{"account":"personal","to":["a@example.com"],"subject":"Hi","bodyText":"hello"}"#.utf8)
        )
        #expect(minimal.cc == nil)
        #expect(minimal.bcc == nil)
        #expect(minimal.bodyHtml == nil)
    }

    @Test
    func `SMTP host and port derivation matches account host`() {
        let personal = ResolvedEmailCredentials(
            accountName: "personal",
            host: "mail.yourdomain.com",
            port: 993,
            username: "you@yourdomain.com",
            password: "test-secret"
        )
        #expect(EmailSMTPBridge.smtpHost(for: personal) == "mail.yourdomain.com")
        #expect(EmailSMTPBridge.smtpPort(for: personal) == 587)
        let icloud = ResolvedEmailCredentials(
            accountName: "icloud",
            host: "imap.mail.me.com",
            port: 993,
            username: "user@icloud.com",
            password: "test-secret"
        )
        #expect(EmailSMTPBridge.smtpHost(for: icloud) == "smtp.mail.me.com")
        #expect(EmailSMTPBridge.smtpPort(for: icloud) == 587)
        let explicit = ResolvedEmailCredentials(
            accountName: "custom",
            host: "mail.example.com",
            port: 465,
            username: "you@example.com",
            password: "test-secret"
        )
        #expect(EmailSMTPBridge.smtpPort(for: explicit) == 465)
        #expect(EmailSMTPBridge.usesImplicitTLS(port: 465) == true)
        #expect(EmailSMTPBridge.usesImplicitTLS(port: 587) == false)
    }

    @Test
    func `SMTP bridge script uses verified TLS with STARTTLS and SSL`() {
        let source = EmailSMTPBridgeScript.source
        #expect(source.contains("smtplib"))
        #expect(source.contains("SMTP_SSL"))
        #expect(source.contains("starttls"))
        #expect(source.contains("ssl.create_default_context()"))
        #expect(source.contains("timeout=30"))
        #expect(source.contains("op != \"send\"") || source.contains("op =="))
        #expect(source.contains("\"send\"") || source.contains("'send'"))
        #expect(!source.contains("CERT_NONE"))
        #expect(!source.contains("_create_unverified_context"))
        #expect(source.contains("send_message"))
        #expect(source.contains("BCC") || source.contains("bcc") || source.contains("envelope"))
    }

    @Test
    func `Assembled SMTP bridge source parses as Python without executing`() throws {
        try ToolsTestSupport.assertBridgeSourceParses(EmailSMTPBridgeScript.source)
    }

    @Test
    func `Malformed send arguments fail cleanly`() async throws {
        let tool = EmailSendTool(emailConfig: ToolsTestSupport.testEmailConfig(), smtpGateway: StubSMTPGateway())
        let missing = try await tool.execute(
            input: ToolInput(toolName: "email.send", argumentsJSON: #"{"account":"personal"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(missing.isError == true)
        let badJSON = try await tool.execute(
            input: ToolInput(toolName: "email.send", argumentsJSON: "not-json"),
            context: ToolContext(conversationID: UUID())
        )
        #expect(badJSON.isError == true)
    }

    @Test
    func `SMTP explicit fields win and auto falls back to 587 then 465`() {
        let base = ResolvedEmailCredentials(
            accountName: "personal",
            host: "mail.yourdomain.com",
            port: 993,
            username: "you@yourdomain.com",
            password: "test-secret"
        )
        // Absent overrides try STARTTLS then implicit TLS on the derived host.
        let fallback = EmailSMTPBridge.endpoints(for: base)
        #expect(fallback.count == 2)
        #expect(fallback[0].host == "mail.yourdomain.com")
        #expect(fallback[0].port == 587)
        #expect(fallback[0].useImplicitTLS == false)
        #expect(fallback[1].port == 465)
        #expect(fallback[1].useImplicitTLS == true)
        // Explicit host and port collapse to one pinned attempt.
        let explicit = ResolvedEmailCredentials(
            accountName: "custom",
            host: "mail.yourdomain.com",
            port: 993,
            username: "you@yourdomain.com",
            password: "test-secret",
            smtpHost: "smtp.custom.com",
            smtpPort: 2525,
            smtpSecurity: .starttls
        )
        #expect(EmailSMTPBridge.smtpHost(for: explicit) == "smtp.custom.com")
        #expect(EmailSMTPBridge.smtpPort(for: explicit) == 2525)
        let pinned = EmailSMTPBridge.endpoints(for: explicit)
        #expect(pinned.count == 1)
        #expect(pinned[0].host == "smtp.custom.com")
        #expect(pinned[0].port == 2525)
        // Pinned SSL maps to implicit TLS on 465 by default.
        let ssl = ResolvedEmailCredentials(
            accountName: "secure",
            host: "mail.example.com",
            port: 993,
            username: "you@example.com",
            password: "test-secret",
            smtpHost: nil,
            smtpPort: nil,
            smtpSecurity: .ssl
        )
        let sslEndpoints = EmailSMTPBridge.endpoints(for: ssl)
        #expect(sslEndpoints.count == 1)
        #expect(sslEndpoints[0].port == 465)
        #expect(sslEndpoints[0].useImplicitTLS == true)
        // Account defaults keep payloads on auto without overrides.
        let account = EmailAccount(name: "personal", type: "imap", host: "mail.yourdomain.com", port: 993, username: "you@yourdomain.com")
        #expect(account.smtpHost == nil)
        #expect(account.smtpPort == nil)
        #expect(account.smtpSecurity == .auto)
    }

    @Test
    func `HTML-only send derives text fallback`() async throws {
        let box = SendBox()
        let imapBox = IMAPBox()
        let tool = EmailSendTool(
            emailConfig: ToolsTestSupport.testEmailConfig(),
            smtpGateway: StubSMTPGateway(box: box),
            gateway: StubSendIMAPGateway(mailboxes: ["INBOX", "Sent"], box: imapBox)
        )
        try await ToolsTestSupport.withTestPassword {
            let output = try await tool.execute(
                input: ToolInput(
                    toolName: "email.send",
                    argumentsJSON: sendPayload(bodyText: nil, bodyHtml: "<p>Hello <b>world</b></p>")
                ),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == false)
            #expect(box.calls == 1)
            // Unwrap the stub send first and bind the derived text to a
            // local so the Testing macro expands a plain Bool expression;
            // leading `!` over optional-chaining plus `??` mis-expands.
            let sent = try #require(box.lastMessage)
            #expect(sent.bodyHtml == "<p>Hello <b>world</b></p>")
            let text = sent.bodyText
            #expect(text.contains("Hello"))
            #expect(text.contains("world"))
            #expect(text.contains("<p>") == false)
            let envelope = try JSONDecoder().decode(EmailSendEnvelope.self, from: Data(output.content.utf8))
            #expect(envelope.bodyHtmlBytes != nil)
            #expect(envelope.bodyTextBytes > 0)
            #expect(!output.content.contains("test-secret"))
        }
    }

    @Test
    func `Send rejects combined body over 1 MB`() async throws {
        let tool = EmailSendTool(emailConfig: ToolsTestSupport.testEmailConfig(), smtpGateway: StubSMTPGateway())
        let half = String(repeating: "a", count: 600 * 1024)
        let output = try await tool.execute(
            input: ToolInput(
                toolName: "email.send",
                argumentsJSON: sendPayload(bodyText: half, bodyHtml: half)
            ),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == true)
        #expect(output.content.contains("combined body"))
    }

    @Test
    func `Send enforces 20 total recipients across fields`() async throws {
        let tool = EmailSendTool(emailConfig: ToolsTestSupport.testEmailConfig(), smtpGateway: StubSMTPGateway())
        let ten = Array(repeating: "friend@example.com", count: 10)
        let eleven = Array(repeating: "other@example.com", count: 11)
        let output = try await tool.execute(
            input: ToolInput(
                toolName: "email.send",
                argumentsJSON: sendPayload(to: ten, cc: eleven)
            ),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == true)
        #expect(output.content.contains("total"))
    }

    @Test
    func `Send refuses sandbox-escape attachment paths`() async throws {
        // Attachment inputs are judged by the workspace guard, so host
        // staging is gone and outside-roots plus relative paths fail closed.
        let config = ToolsTestSupport.testEmailConfig()
        let tool = EmailSendTool(
            emailConfig: config,
            smtpGateway: StubSMTPGateway(),
            gateway: StubSendIMAPGateway()
        )
        try await ToolsTestSupport.withTestPassword {
            let outside = try await tool.execute(
                input: ToolInput(
                    toolName: "email.send",
                    argumentsJSON: sendPayload(attachmentPaths: ["/tmp/evil.txt"])
                ),
                context: ToolContext(conversationID: UUID())
            )
            #expect(outside.isError == true)
            #expect(outside.content.contains("outside") || outside.content.contains("permitted workspace"))
            let relative = try await tool.execute(
                input: ToolInput(
                    toolName: "email.send",
                    argumentsJSON: sendPayload(attachmentPaths: ["relative/note.txt"])
                ),
                context: ToolContext(conversationID: UUID())
            )
            #expect(relative.isError == true)
            #expect(relative.content.contains("absolute"))
        }
    }

    @Test
    func `Send stages sandbox-confined attachments`() async throws {
        // Send inputs live under the workspace guard, so the fixture sits in
        // an isolated home subdirectory with no host staging directory.
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("runeweaver-send-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("report.txt")
        try Data("report bytes".utf8).write(to: file)
        let box = SendBox()
        let tool = EmailSendTool(
            emailConfig: ToolsTestSupport.testEmailConfig(),
            smtpGateway: StubSMTPGateway(box: box),
            gateway: StubSendIMAPGateway(mailboxes: ["INBOX", "Sent"])
        )
        try await ToolsTestSupport.withTestPassword {
            let output = try await tool.execute(
                input: ToolInput(
                    toolName: "email.send",
                    argumentsJSON: sendPayload(attachmentPaths: [file.path])
                ),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == false)
            #expect(box.calls == 1)
            #expect(box.lastMessage?.attachments.count == 1)
            #expect(box.lastMessage?.attachments.first?.filename == "report.txt")
            let envelope = try JSONDecoder().decode(EmailSendEnvelope.self, from: Data(output.content.utf8))
            #expect(envelope.attachmentPaths == [file.path])
            #expect(envelope.attachmentBytes == Data("report bytes".utf8).count)
        }
    }

    @Test
    func `Threaded reply prefixes Re and quotes original with headers`() async throws {
        let original = EmailFullMessage(
            id: "42",
            subject: "Quarterly report",
            from: "boss@example.com",
            to: "you@yourdomain.com",
            date: "Mon, 01 Sep 2025 09:00:00 +0000",
            body: "Please review the numbers."
        )
        let box = SendBox()
        let tool = EmailSendTool(
            emailConfig: ToolsTestSupport.testEmailConfig(),
            smtpGateway: StubSMTPGateway(box: box),
            gateway: StubSendIMAPGateway(message: original, mailboxes: ["INBOX", "Sent"])
        )
        try await ToolsTestSupport.withTestPassword {
            let output = try await tool.execute(
                input: ToolInput(
                    toolName: "email.send",
                    argumentsJSON: sendPayload(subject: "Quarterly report", bodyText: "Will do.", replyToId: "42")
                ),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == false)
            let envelope = try JSONDecoder().decode(EmailSendEnvelope.self, from: Data(output.content.utf8))
            #expect(envelope.subject == "Re: Quarterly report")
            #expect(envelope.inReplyTo == "42")
            #expect(envelope.references == "42")
            #expect(box.lastMessage?.inReplyTo == "42")
            #expect(box.lastMessage?.references == "42")
            #expect(box.lastMessage?.subject.hasPrefix("Re:") == true)
            #expect(box.lastMessage?.bodyText.contains("Will do.") == true)
            #expect(box.lastMessage?.bodyText.contains("> Please review the numbers.") == true)
            let reparsed = try JSONDecoder().decode(EmailSendEnvelope.self, from: Data(output.content.utf8))
            #expect(reparsed.bodyPreview?.contains("Will do.") == true)
        }
    }

    @Test
    func `Per-recipient trust target lowercases and joins addresses`() async {
        let first = ToolInput(toolName: "email.send", argumentsJSON: #"{"account":"personal","to":["Dr.Smith@Clinic.COM"],"subject":"Hi","bodyText":"hello"}"#)
        #expect(ActionDescriptor.target(from: first) == "dr.smith@clinic.com")
        let array = ToolInput(toolName: "email.send", argumentsJSON: #"{"account":"personal","to":["B@EXAMPLE.COM","a@example.com"],"subject":"Hi","bodyText":"hello"}"#)
        #expect(ActionDescriptor.target(from: array) == "b@example.com,a@example.com")
        let alias = ToolInput(toolName: "email.send", argumentsJSON: #"{"account":"personal","recipient":"Alias@Example.com","subject":"Hi","bodyText":"hello"}"#)
        #expect(ActionDescriptor.target(from: alias) == "alias@example.com")
        // A grant for one recipient bypasses only that recipient.
        let gate = PermissionGate()
        let tool = EmailSendTool(emailConfig: ToolsTestSupport.testEmailConfig(), smtpGateway: StubSMTPGateway())
        await gate.grantTrust(for: ActionDescriptor(toolName: "email.send", target: "dr.smith@clinic.com"), duration: .oneDay)
        let allowed = await gate.checkPermission(toolCall: first, tool: tool)
        guard case .allowed = allowed else {
            Issue.record("Expected allowed for granted recipient")
            return
        }
        let other = ToolInput(toolName: "email.send", argumentsJSON: #"{"account":"personal","to":["other@example.com"],"subject":"Hi","bodyText":"hello"}"#)
        let prompted = await gate.checkPermission(toolCall: other, tool: tool)
        guard case .requiresApproval = prompted else {
            Issue.record("Expected approval for a different recipient")
            return
        }
    }

    @Test
    func `Sent append miss warns without failing the send`() async throws {
        let box = SendBox()
        let imapBox = IMAPBox()
        let tool = EmailSendTool(
            emailConfig: ToolsTestSupport.testEmailConfig(),
            smtpGateway: StubSMTPGateway(box: box),
            gateway: StubSendIMAPGateway(mailboxes: ["INBOX"], box: imapBox)
        )
        try await ToolsTestSupport.withTestPassword {
            let output = try await tool.execute(
                input: ToolInput(toolName: "email.send", argumentsJSON: sendPayload()),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == false)
            #expect(box.calls == 1)
            let envelope = try JSONDecoder().decode(EmailSendEnvelope.self, from: Data(output.content.utf8))
            #expect((envelope.appendWarning ?? "").contains("Sent"))
            #expect((envelope.note ?? "").contains("Sent copy skipped"))
        }
    }

    @Test
    func `Sent append failure warns without failing the send`() async throws {
        let box = SendBox()
        let tool = EmailSendTool(
            emailConfig: ToolsTestSupport.testEmailConfig(),
            smtpGateway: StubSMTPGateway(box: box),
            gateway: StubSendIMAPGateway(mailboxes: ["INBOX", "Sent"], appendFailure: "IMAP append failed: quota exceeded")
        )
        try await ToolsTestSupport.withTestPassword {
            let output = try await tool.execute(
                input: ToolInput(toolName: "email.send", argumentsJSON: sendPayload()),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == false)
            #expect(box.calls == 1)
            let envelope = try JSONDecoder().decode(EmailSendEnvelope.self, from: Data(output.content.utf8))
            #expect((envelope.appendWarning ?? "").contains("quota"))
        }
    }

    @Test
    func `Dry run previews without network use`() async throws {
        let smtpBox = SendBox()
        let imapBox = IMAPBox()
        // Dry-run validation still reads through the workspace guard, so the
        // preview fixture lives under an isolated home subdirectory.
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("runeweaver-send-dry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("dry.txt")
        try Data("dry bytes".utf8).write(to: file)
        let tool = EmailSendTool(
            emailConfig: ToolsTestSupport.testEmailConfig(),
            smtpGateway: StubSMTPGateway(box: smtpBox),
            gateway: StubSendIMAPGateway(
                message: EmailFullMessage(id: "9", subject: "Orig", from: "a@example.com", to: "you@yourdomain.com", date: "Mon, 01 Sep 2025 09:00:00 +0000", body: "orig body"),
                mailboxes: ["INBOX", "Sent"],
                box: imapBox
            )
        )
        try await ToolsTestSupport.withTestPassword {
            let output = try await tool.execute(
                input: ToolInput(
                    toolName: "email.send",
                    argumentsJSON: sendPayload(bodyText: "Preview me please", attachmentPaths: [file.path], replyToId: "9")
                ),
                context: ToolContext(conversationID: UUID(), dryRun: true)
            )
            #expect(output.isError == false)
            #expect(smtpBox.calls == 0)
            #expect(imapBox.fetchCalls == 0)
            #expect(imapBox.appendCalls == 0)
            let envelope = try JSONDecoder().decode(EmailSendEnvelope.self, from: Data(output.content.utf8))
            #expect(envelope.dryRun == true)
            #expect(envelope.from == "you@yourdomain.com")
            #expect(envelope.to == ["friend@example.com"])
            #expect(envelope.bodyPreview?.contains("Preview me") == true)
            #expect((envelope.bodyPreview ?? "").count <= 2000)
            #expect(envelope.attachmentPaths == [file.path])
            #expect(envelope.inReplyTo == "9")
            #expect(envelope.references == "9")
            #expect(!output.content.contains("test-secret"))
        }
    }

    @Test
    func `SMTP bridge script encodes attachments and threading headers`() {
        let source = EmailSMTPBridgeScript.source
        #expect(source.contains("add_attachment"))
        #expect(source.contains("In-Reply-To"))
        #expect(source.contains("References"))
        #expect(source.contains("contentBase64"))
    }

    @Test
    func `IMAP bridge script supports append with verified TLS`() throws {
        try ToolsTestSupport.assertBridgeSourceParses(EmailIMAPBridgeScript.source)
        #expect(EmailIMAPBridgeScript.source.contains("append"))
        #expect(EmailIMAPBridgeScript.source.contains("rawMessageBase64"))
        let sent = EmailSentMailbox.resolve(among: ["INBOX", "Sent Items"])
        #expect(sent == "Sent Items")
        #expect(EmailSentMailbox.resolve(among: ["INBOX"]) == nil)
        #expect(EmailSentMailbox.resolve(among: ["inbox", "sent"]) == "sent")
    }

    @Test
    func `Send automatically converts markdown bodyText to styled HTML alternative`() async throws {
        let box = SendBox()
        let tool = EmailSendTool(
            emailConfig: ToolsTestSupport.testEmailConfig(),
            smtpGateway: StubSMTPGateway(box: box),
            gateway: StubSendIMAPGateway(mailboxes: ["INBOX", "Sent"])
        )
        let markdownBody = """
        # Project Update

        Here is the latest progress with **bold** text and a [dashboard link](https://example.com).

        - Milestone A complete
        - Milestone B in progress
        """
        try await ToolsTestSupport.withTestPassword {
            let output = try await tool.execute(
                input: ToolInput(
                    toolName: "email.send",
                    argumentsJSON: sendPayload(bodyText: markdownBody, bodyHtml: nil)
                ),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == false)
            #expect(box.calls == 1)
            let sent = try #require(box.lastMessage)
            #expect(sent.bodyText == markdownBody)
            let html = try #require(sent.bodyHtml)
            #expect(html.contains("<!DOCTYPE html>"))
            #expect(html.contains("<h1>Project Update</h1>"))
            #expect(html.contains("<strong>bold</strong>"))
            #expect(html.contains("<a href=\"https://example.com\">dashboard link</a>"))
            #expect(html.contains("<li>Milestone A complete</li>"))
            let envelope = try JSONDecoder().decode(EmailSendEnvelope.self, from: Data(output.content.utf8))
            #expect(envelope.bodyHtmlBytes != nil)
            #expect(envelope.bodyTextBytes > 0)
        }
    }

    @Test
    func `Send accepts body as alias for bodyText`() async throws {
        let box = SendBox()
        let tool = EmailSendTool(
            emailConfig: ToolsTestSupport.testEmailConfig(),
            smtpGateway: StubSMTPGateway(box: box),
            gateway: StubSendIMAPGateway(mailboxes: ["INBOX", "Sent"])
        )
        let payload = """
        {
            "account": "personal",
            "to": ["friend@example.com"],
            "subject": "Using body alias",
            "body": "Hello via **body** field"
        }
        """
        try await ToolsTestSupport.withTestPassword {
            let output = try await tool.execute(
                input: ToolInput(toolName: "email.send", argumentsJSON: payload),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == false)
            #expect(box.calls == 1)
            let sent = try #require(box.lastMessage)
            #expect(sent.bodyText == "Hello via **body** field")
            let html = try #require(sent.bodyHtml)
            #expect(html.contains("<strong>body</strong>"))
        }
    }

    @Test
    func `Send preserves explicit bodyHtml override without running markdown parser`() async throws {
        let box = SendBox()
        let tool = EmailSendTool(
            emailConfig: ToolsTestSupport.testEmailConfig(),
            smtpGateway: StubSMTPGateway(box: box),
            gateway: StubSendIMAPGateway(mailboxes: ["INBOX", "Sent"])
        )
        let customHtml = "<div class=\"custom\">Custom <em>HTML</em> override</div>"
        try await ToolsTestSupport.withTestPassword {
            let output = try await tool.execute(
                input: ToolInput(
                    toolName: "email.send",
                    argumentsJSON: sendPayload(bodyText: "Plain text", bodyHtml: customHtml)
                ),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == false)
            #expect(box.calls == 1)
            let sent = try #require(box.lastMessage)
            #expect(sent.bodyHtml == customHtml)
        }
    }

    @Test
    func `Scheduled send books exactly one send without SMTP use`() async throws {
        let smtpBox = SendBox()
        let bookingBox = BookingBox()
        let tool = EmailSendTool(
            emailConfig: ToolsTestSupport.testEmailConfig(),
            smtpGateway: StubSMTPGateway(box: smtpBox),
            gateway: StubSendIMAPGateway(mailboxes: ["INBOX", "Sent"]),
            booking: StubBooking(box: bookingBox)
        )
        let fireAt = minuteAlignedFutureFireAt()
        let output = try await tool.execute(
            input: ToolInput(
                toolName: "email.send",
                argumentsJSON: sendPayload(scheduleAt: fireAt.timeIntervalSince1970)
            ),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == false)
        #expect(smtpBox.calls == 0)
        #expect(bookingBox.count == 1)
        let draft = try #require(bookingBox.drafts.first)
        #expect(draft.channel == .email)
        #expect(draft.recipient == "friend@example.com")
        #expect(draft.subject == "Hello")
        #expect(draft.text == "Hi there")
        #expect(draft.account == "personal")
        #expect(draft.fireAt == fireAt)
        #expect(output.content.contains("Booked"))
        #expect(output.content.contains("friend@example.com"))
        #expect(output.content.contains(SharedDateFormatters.isoInternetTimeUTCString(from: fireAt)))
        let body = try #require(JSONSerialization.jsonObject(with: Data(output.content.utf8)) as? [String: Any])
        let bookedID = try #require(body["id"] as? String)
        #expect(!bookedID.isEmpty)
        #expect(output.content.contains(bookedID))
    }

    @Test
    func `Scheduled send rejects past fire time with its reason`() async throws {
        let smtpBox = SendBox()
        let bookingBox = BookingBox()
        let tool = EmailSendTool(
            emailConfig: ToolsTestSupport.testEmailConfig(),
            smtpGateway: StubSMTPGateway(box: smtpBox),
            booking: StubBooking(box: bookingBox)
        )
        let output = try await tool.execute(
            input: ToolInput(
                toolName: "email.send",
                argumentsJSON: sendPayload(scheduleAt: Date().addingTimeInterval(-60).timeIntervalSince1970)
            ),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == true)
        #expect(output.content.contains("at least 5 minutes"))
        #expect(bookingBox.count == 0)
        #expect(smtpBox.calls == 0)
    }

    @Test
    func `Scheduled send rejects far-future fire time with its reason`() async throws {
        let smtpBox = SendBox()
        let bookingBox = BookingBox()
        let tool = EmailSendTool(
            emailConfig: ToolsTestSupport.testEmailConfig(),
            smtpGateway: StubSMTPGateway(box: smtpBox),
            booking: StubBooking(box: bookingBox)
        )
        let output = try await tool.execute(
            input: ToolInput(
                toolName: "email.send",
                argumentsJSON: sendPayload(scheduleAt: Date().addingTimeInterval(400 * 24 * 3600).timeIntervalSince1970)
            ),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == true)
        #expect(output.content.contains("at most 365 days"))
        #expect(bookingBox.count == 0)
        #expect(smtpBox.calls == 0)
    }

    @Test
    func `Scheduled send rejects malformed fire time without booking`() async throws {
        let smtpBox = SendBox()
        let bookingBox = BookingBox()
        let tool = EmailSendTool(
            emailConfig: ToolsTestSupport.testEmailConfig(),
            smtpGateway: StubSMTPGateway(box: smtpBox),
            booking: StubBooking(box: bookingBox)
        )
        let output = try await tool.execute(
            input: ToolInput(
                toolName: "email.send",
                argumentsJSON: sendPayload(scheduleAt: "not-a-date")
            ),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == true)
        #expect(bookingBox.count == 0)
        #expect(smtpBox.calls == 0)
    }

    @Test
    func `Scheduled send without wired booking refuses with guidance`() async throws {
        let smtpBox = SendBox()
        let tool = EmailSendTool(
            emailConfig: ToolsTestSupport.testEmailConfig(),
            smtpGateway: StubSMTPGateway(box: smtpBox),
            gateway: StubSendIMAPGateway(mailboxes: ["INBOX", "Sent"])
        )
        let output = try await tool.execute(
            input: ToolInput(
                toolName: "email.send",
                argumentsJSON: sendPayload(scheduleAt: minuteAlignedFutureFireAt().timeIntervalSince1970)
            ),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == true)
        #expect(output.content.contains("Schedules surface"))
        #expect(smtpBox.calls == 0)
    }

    @Test
    func `Scheduled dry run previews booking without writing`() async throws {
        let smtpBox = SendBox()
        let bookingBox = BookingBox()
        let tool = EmailSendTool(
            emailConfig: ToolsTestSupport.testEmailConfig(),
            smtpGateway: StubSMTPGateway(box: smtpBox),
            gateway: StubSendIMAPGateway(mailboxes: ["INBOX", "Sent"]),
            booking: StubBooking(box: bookingBox)
        )
        let fireAt = minuteAlignedFutureFireAt()
        let output = try await tool.execute(
            input: ToolInput(
                toolName: "email.send",
                argumentsJSON: sendPayload(scheduleAt: fireAt.timeIntervalSince1970)
            ),
            context: ToolContext(conversationID: UUID(), dryRun: true)
        )
        #expect(output.isError == false)
        #expect(bookingBox.count == 0)
        #expect(smtpBox.calls == 0)
        #expect(output.content.contains("Dry run"))
        #expect(output.content.contains("book"))
        #expect(output.content.contains(SharedDateFormatters.isoInternetTimeUTCString(from: fireAt)))
    }

    @Test
    func `Scheduled send through bus parks for approval without booking`() async {
        let smtpBox = SendBox()
        let bookingBox = BookingBox()
        let config = ToolsTestSupport.testEmailConfig()
        let bus = ToolBus(permissionGate: PermissionGate())
        for tool in EmailTools.makeTools(
            emailConfig: config,
            smtpGateway: StubSMTPGateway(box: smtpBox),
            booking: StubBooking(box: bookingBox)
        ) {
            await bus.register(tool: tool)
        }
        await ToolsTestSupport.withTestPassword {
            let input = ToolInput(toolName: "email.send", argumentsJSON: (try? sendPayload(scheduleAt: minuteAlignedFutureFireAt().timeIntervalSince1970)) ?? "{}")
            let result = await bus.execute(toolCall: input, context: ToolContext(conversationID: UUID()))
            #expect(result.isError == true)
            #expect(result.content.contains("requires approval"))
            #expect(bookingBox.count == 0)
            #expect(smtpBox.calls == 0)
        }
    }

    @Test
    func `Scheduled booking failure stays caller-visible`() async throws {
        let smtpBox = SendBox()
        let tool = EmailSendTool(
            emailConfig: ToolsTestSupport.testEmailConfig(),
            smtpGateway: StubSMTPGateway(box: smtpBox),
            booking: StubBooking(failure: "store unavailable: disk full")
        )
        let output = try await tool.execute(
            input: ToolInput(
                toolName: "email.send",
                argumentsJSON: sendPayload(scheduleAt: minuteAlignedFutureFireAt().timeIntervalSince1970)
            ),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == true)
        #expect(output.content.contains("store unavailable"))
        #expect(smtpBox.calls == 0)
    }

    @Test
    func `Scheduled send rejects multiple to recipients without booking`() async throws {
        let smtpBox = SendBox()
        let bookingBox = BookingBox()
        let tool = EmailSendTool(
            emailConfig: ToolsTestSupport.testEmailConfig(),
            smtpGateway: StubSMTPGateway(box: smtpBox),
            gateway: StubSendIMAPGateway(mailboxes: ["INBOX", "Sent"]),
            booking: StubBooking(box: bookingBox)
        )
        let output = try await tool.execute(
            input: ToolInput(
                toolName: "email.send",
                argumentsJSON: sendPayload(
                    to: ["a@example.com", "b@example.com"],
                    scheduleAt: minuteAlignedFutureFireAt().timeIntervalSince1970
                )
            ),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == true)
        #expect(output.content.contains("single to recipient"))
        #expect(bookingBox.count == 0)
        #expect(smtpBox.calls == 0)
    }

    @Test
    func `Threaded reply formats quoted blockquote in generated HTML`() async throws {
        let original = EmailFullMessage(
            id: "99",
            subject: "Budget discussion",
            from: "finance@example.com",
            to: "you@yourdomain.com",
            date: "Mon, 01 Sep 2025 09:00:00 +0000",
            body: "Approved the Q3 figures."
        )
        let box = SendBox()
        let tool = EmailSendTool(
            emailConfig: ToolsTestSupport.testEmailConfig(),
            smtpGateway: StubSMTPGateway(box: box),
            gateway: StubSendIMAPGateway(message: original, mailboxes: ["INBOX", "Sent"])
        )
        try await ToolsTestSupport.withTestPassword {
            let output = try await tool.execute(
                input: ToolInput(
                    toolName: "email.send",
                    argumentsJSON: sendPayload(subject: "Budget discussion", bodyText: "Sounds good, proceeding.", replyToId: "99")
                ),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == false)
            let sent = try #require(box.lastMessage)
            let html = try #require(sent.bodyHtml)
            #expect(html.contains("<blockquote>"))
            #expect(html.contains("Approved the Q3 figures."))
        }
    }
}

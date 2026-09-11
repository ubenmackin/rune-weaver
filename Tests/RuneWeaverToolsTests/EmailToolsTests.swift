import Foundation
@testable import RuneWeaverCore
@testable import RuneWeaverTools
import Testing

/// Stub gateway returning canned results without touching the network.
private struct StubEmailGateway: EmailIMAPGateway, Sendable {
    /// Hits returned by `search`.
    var hits: [EmailSearchHit] = []
    /// Message returned by `fetch`.
    var message: EmailFullMessage?
    /// Error thrown instead of returning, when set.
    var failure: String?

    func search(credentials _: ResolvedEmailCredentials, query _: String, limit: Int) async throws -> [EmailSearchHit] {
        if let failure {
            throw EmailIMAPError.bridgeFailed(failure)
        }
        return Array(hits.prefix(limit))
    }

    func fetch(credentials _: ResolvedEmailCredentials, messageID: String) async throws -> EmailFullMessage {
        if let failure {
            throw EmailIMAPError.bridgeFailed(failure)
        }
        guard let message else {
            throw EmailIMAPError.bridgeFailed("Message \(messageID) not found")
        }
        return message
    }
}

/// Search bridge stdout fixture with two hits.
private let searchFixture = """
{"ok": true, "messages": [
  {"id": "42", "subject": "Quarterly report", "from": "boss@example.com", "date": "Mon, 01 Sep 2025 09:00:00 +0000", "snippet": "Please review the quarterly numbers"},
  {"id": "41", "subject": "Lunch?", "from": "friend@example.com", "date": "Sun, 31 Aug 2025 12:00:00 +0000", "snippet": "Want to grab lunch tomorrow"}
]}
"""

/// Fetch bridge stdout fixture with one skipped attachment.
private let fetchFixtureWithAttachment = """
{"ok": true, "message": {
  "id": "42",
  "subject": "Quarterly report",
  "from": "boss@example.com",
  "to": "you@yourdomain.com",
  "date": "Mon, 01 Sep 2025 09:00:00 +0000",
  "body": "Please review the quarterly numbers attached.",
  "attachments": [{"filename": "report.pdf", "contentType": "application/pdf"}],
  "attachmentsDeferred": true,
  "attachmentsNote": "1 attachment skipped; attachment download is deferred to phase two."
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

/// Test email config with one self-hosted account.
private func testEmailConfig() -> EmailConfig {
    EmailConfig(accounts: [
        EmailAccount(name: "personal", type: "imap", host: "mail.yourdomain.com", port: 993, username: "you@yourdomain.com")
    ])
}

/// Sets the stub account password in the environment for credential resolution.
private func withTestPassword(_ body: () async throws -> Void) async rethrows {
    setenv("EMAIL_PERSONAL_PASSWORD", "test-secret", 1)
    defer { unsetenv("EMAIL_PERSONAL_PASSWORD") }
    try await body()
}

// Serialized: `withTestPassword` mutates the process environment via
// `setenv`/`unsetenv`, which is process-global and races when tests run
// in parallel. Serial execution keeps credential setup deterministic.
@Suite("Email Tools", .serialized)
struct EmailToolsTests {
    @Test
    func `Search bridge payload decodes hits`() throws {
        let hits = try EmailBridgeParsing.parseSearchPayload(Data(searchFixture.utf8))
        #expect(hits.count == 2)
        #expect(hits[0].id == "42")
        #expect(hits[0].subject == "Quarterly report")
        #expect(hits[0].from == "boss@example.com")
        #expect(hits[0].snippet.contains("quarterly"))
    }

    @Test
    func `Fetch bridge payload decodes body and defers attachments`() throws {
        let message = try EmailBridgeParsing.parseFetchPayload(Data(fetchFixtureWithAttachment.utf8))
        #expect(message.id == "42")
        #expect(message.subject == "Quarterly report")
        #expect(message.body.contains("quarterly numbers"))
        #expect(message.attachments.count == 1)
        #expect(message.attachments[0].filename == "report.pdf")
        #expect(message.attachmentsDeferred == true)
        #expect((message.attachmentsNote ?? "").contains("phase two"))
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
        let direct = try JSONDecoder().decode(EmailReadArgs.self, from: Data(#"{"account":"personal","id":"42"}"#.utf8))
        #expect(direct.messageID == "42")
        let camel = try JSONDecoder().decode(EmailReadArgs.self, from: Data(#"{"account":"personal","messageId":"43"}"#.utf8))
        #expect(camel.messageID == "43")
        let snake = try JSONDecoder().decode(EmailReadArgs.self, from: Data(#"{"account":"personal","message_id":"44"}"#.utf8))
        #expect(snake.messageID == "44")
        let uid = try JSONDecoder().decode(EmailReadArgs.self, from: Data(#"{"account":"personal","uid":"45"}"#.utf8))
        #expect(uid.messageID == "45")
    }

    @Test
    func `Email tools are readOnly`() {
        let config = testEmailConfig()
        let tools = EmailTools.makeTools(emailConfig: config, gateway: StubEmailGateway())
        #expect(tools.count == 2)
        for tool in tools {
            #expect(tool.permissionLevel == .readOnly)
        }
        #expect(Set(tools.map(\.name)) == Set(["email.search", "email.read"]))
    }

    @Test
    func `Search tool returns envelope through ToolBus`() async throws {
        let hits = try EmailBridgeParsing.parseSearchPayload(Data(searchFixture.utf8))
        let gateway = StubEmailGateway(hits: hits)
        let config = testEmailConfig()
        let bus = ToolBus()
        for tool in EmailTools.makeTools(emailConfig: config, gateway: gateway) {
            await bus.register(tool: tool)
        }
        let names = await bus.toolNames()
        #expect(names.sorted() == ["email.read", "email.search"])
        try await withTestPassword {
            let input = ToolInput(toolName: "email.search", argumentsJSON: #"{"account":"personal","query":"quarterly","limit":10}"#)
            let result = await bus.execute(toolCall: input, context: ToolContext(conversationID: UUID()))
            #expect(result.isError == false)
            #expect(result.content.contains("Quarterly report"))
            #expect(result.content.contains("\"count\""))
        }
    }

    @Test
    func `Search tool passes through permission gate without approval prompts`() async throws {
        let hits = try EmailBridgeParsing.parseSearchPayload(Data(searchFixture.utf8))
        let gateway = StubEmailGateway(hits: hits)
        let config = testEmailConfig()
        // Chat configuration: gate attached, no approval handler. Read-only
        // email tools must still succeed without prompting.
        let bus = ToolBus(permissionGate: PermissionGate())
        for tool in EmailTools.makeTools(emailConfig: config, gateway: gateway) {
            await bus.register(tool: tool)
        }
        try await withTestPassword {
            let input = ToolInput(toolName: "email.search", argumentsJSON: #"{"account":"personal","query":"quarterly","limit":5}"#)
            let result = await bus.execute(toolCall: input, context: ToolContext(conversationID: UUID()))
            #expect(result.isError == false)
            #expect(result.content.contains("Quarterly report"))
        }
    }

    @Test
    func `Read tool returns headers body and deferral note`() async throws {
        let message = try EmailBridgeParsing.parseFetchPayload(Data(fetchFixtureWithAttachment.utf8))
        let gateway = StubEmailGateway(message: message)
        let config = testEmailConfig()
        let tool = EmailReadTool(emailConfig: config, gateway: gateway)
        try await withTestPassword {
            let output = try await tool.execute(
                input: ToolInput(toolName: "email.read", argumentsJSON: #"{"account":"personal","id":"42"}"#),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == false)
            #expect(output.content.contains("Quarterly report"))
            #expect(output.content.contains("quarterly numbers"))
            #expect(output.content.contains("report.pdf"))
            #expect(output.content.contains("phase two"))
        }
    }

    @Test
    func `Search tool rejects empty query`() async throws {
        let config = testEmailConfig()
        let tool = EmailSearchTool(emailConfig: config, gateway: StubEmailGateway())
        let output = try await tool.execute(
            input: ToolInput(toolName: "email.search", argumentsJSON: #"{"account":"personal","query":"  "}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == true)
    }

    @Test
    func `Read tool rejects unknown account without secrets`() async throws {
        let config = testEmailConfig()
        let tool = EmailReadTool(emailConfig: config, gateway: StubEmailGateway())
        let output = try await tool.execute(
            input: ToolInput(toolName: "email.read", argumentsJSON: #"{"account":"missing","id":"1"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == true)
        #expect(output.content.contains("missing"))
        #expect(!output.content.contains("test-secret"))
    }

    @Test
    func `Malformed arguments fail cleanly`() async throws {
        let config = testEmailConfig()
        let search = EmailSearchTool(emailConfig: config, gateway: StubEmailGateway())
        let badSearch = try await search.execute(
            input: ToolInput(toolName: "email.search", argumentsJSON: #"{"account":"personal"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(badSearch.isError == true)
        let read = EmailReadTool(emailConfig: config, gateway: StubEmailGateway())
        let badRead = try await read.execute(
            input: ToolInput(toolName: "email.read", argumentsJSON: "not-json"),
            context: ToolContext(conversationID: UUID())
        )
        #expect(badRead.isError == true)
    }

    @Test
    func `Search tool rejects CR LF query`() async throws {
        let config = testEmailConfig()
        let tool = EmailSearchTool(emailConfig: config, gateway: StubEmailGateway())
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
        let config = testEmailConfig()
        let message = try EmailBridgeParsing.parseFetchPayload(Data(fetchFixturePlain.utf8))
        let tool = EmailReadTool(emailConfig: config, gateway: StubEmailGateway(message: message))
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
            let payload = "{\"account\":\"personal\",\"id\":\"\(escaped)\"}"
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
        let config = testEmailConfig()
        let tool = EmailReadTool(emailConfig: config, gateway: StubEmailGateway(message: message))
        try await withTestPassword {
            for valid in ["7", "1,2", "1:10"] {
                let output = try await tool.execute(
                    input: ToolInput(toolName: "email.read", argumentsJSON: "{\"account\":\"personal\",\"id\":\"\(valid)\"}"),
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
    }
}

// Rune Weaver Tools Tests — Email bridge and tool behavior coverage.
//
// Exercises the email IMAP/SMTP bridge parsing, validation gates, and tool
// envelopes with fixture payloads and stub gateways, so wire-format drift
// and fail-closed validation surface without a live mailbox.

import Foundation
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

/// Legacy fetch payload without `sizeBytes`, decoding as unknown size.
private let fetchFixtureLegacyAttachment = """
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

/// Serialized plus `testCredentialEnvLock`: `ToolsTestSupport.withTestPassword` and
/// `ToolsTestSupport.withICloudTestPassword` (see `ToolsTestSupport.swift`) mutate the process
/// environment via `setenv`, which is process-global and POSIX-unsafe under
/// concurrency. `.serialized` only serializes within this suite, so the
/// shared lock provides cross-suite exclusion with `Smoke Harness`, and each
/// helper saves/restores the prior value instead of blind `unsetenv`.
/// `HOME` is never mutated.
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
        let message = try EmailBridgeParsing.parseFetchPayload(Data(fetchFixtureLegacyAttachment.utf8))
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
        let direct = try JSONDecoder().decode(EmailAttachmentArgs.self, from: Data(#"{"account":"personal","id":"42","index":0}"#.utf8))
        #expect(direct.messageID == "42")
        #expect(direct.attachmentIndex == 0)
        let camel = try JSONDecoder().decode(EmailAttachmentArgs.self, from: Data(#"{"account":"personal","messageId":"43","attachmentIndex":1}"#.utf8))
        #expect(camel.messageID == "43")
        #expect(camel.attachmentIndex == 1)
        let snake = try JSONDecoder().decode(EmailAttachmentArgs.self, from: Data(#"{"account":"personal","message_id":"44","attachment_index":2}"#.utf8))
        #expect(snake.messageID == "44")
        #expect(snake.attachmentIndex == 2)
        let uid = try JSONDecoder().decode(EmailAttachmentArgs.self, from: Data(#"{"account":"personal","uid":"45","index":3}"#.utf8))
        #expect(uid.messageID == "45")
        #expect(uid.attachmentIndex == 3)
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
    func `Email tools expose search read and gated attachment`() {
        let config = ToolsTestSupport.testEmailConfig()
        let tools = EmailTools.makeTools(emailConfig: config, gateway: ToolsTestSupport.StubEmailGateway())
        #expect(tools.count == 4)
        #expect(Set(tools.map(\.name)) == Set(["email.search", "email.read", "email.attachment", "email.send"]))
        let levels = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0.permissionLevel) })
        #expect(levels["email.search"] == .readOnly)
        #expect(levels["email.read"] == .readOnly)
        #expect(levels["email.attachment"] == .requiresApproval)
        #expect(levels["email.send"] == .requiresApproval)
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
        #expect(names.sorted() == ["email.attachment", "email.read", "email.search", "email.send"])
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
                input: ToolInput(toolName: "email.read", argumentsJSON: #"{"account":"personal","id":"42"}"#),
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
    func `Read tool rejects unknown account without secrets`() async throws {
        let config = ToolsTestSupport.testEmailConfig()
        let tool = EmailReadTool(emailConfig: config, gateway: ToolsTestSupport.StubEmailGateway())
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
        let config = ToolsTestSupport.testEmailConfig()
        let tool = EmailReadTool(emailConfig: config, gateway: ToolsTestSupport.StubEmailGateway(message: message))
        try await ToolsTestSupport.withTestPassword {
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
                input: ToolInput(toolName: "email.read", argumentsJSON: #"{"account":"PERSONAL","id":"7"}"#),
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
                input: ToolInput(toolName: "email.read", argumentsJSON: #"{"account":"ICLOUD","id":"7"}"#),
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
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("runeweaver-attachment-\(UUID().uuidString)")
        let sandbox = SandboxConfig(stagingPath: staging.path)
        let tool = EmailAttachmentTool(emailConfig: config, gateway: gateway, sandboxConfig: sandbox)
        try await ToolsTestSupport.withTestPassword {
            let output = try await tool.execute(
                input: ToolInput(toolName: "email.attachment", argumentsJSON: #"{"account":"personal","id":"42","index":0}"#),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == false)
            #expect(output.content.contains("report.pdf"))
            #expect(output.content.contains("application/pdf") || output.content.contains("application\\/pdf"))
            struct Staged: Decodable { let path: String?; let skipped: Bool }
            let staged = try JSONDecoder().decode(Staged.self, from: Data(output.content.utf8))
            #expect(staged.skipped == false)
            let path = try #require(staged.path)
            #expect(path.hasPrefix(staging.path))
            #expect(path.contains("attachments"))
            let onDisk = try Data(contentsOf: URL(fileURLWithPath: path))
            #expect(onDisk == bytes)
            #expect(!output.content.contains("test-secret"))
        }
        try? FileManager.default.removeItem(at: staging)
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
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("runeweaver-attachment-\(UUID().uuidString)")
        let tool = EmailAttachmentTool(
            emailConfig: config,
            gateway: gateway,
            sandboxConfig: SandboxConfig(stagingPath: staging.path)
        )
        try await ToolsTestSupport.withTestPassword {
            let output = try await tool.execute(
                input: ToolInput(toolName: "email.attachment", argumentsJSON: #"{"account":"personal","id":"42","index":0}"#),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == false)
            struct Staged: Decodable { let path: String? }
            let staged = try JSONDecoder().decode(Staged.self, from: Data(output.content.utf8))
            let path = try #require(staged.path)
            #expect(path.hasPrefix(staging.path))
            #expect(!path.contains(".."))
            #expect(URL(fileURLWithPath: path).lastPathComponent.contains("evil.txt"))
        }
        try? FileManager.default.removeItem(at: staging)
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
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("runeweaver-attachment-\(UUID().uuidString)")
        let tool = EmailAttachmentTool(
            emailConfig: config,
            gateway: gateway,
            sandboxConfig: SandboxConfig(stagingPath: staging.path)
        )
        try await ToolsTestSupport.withTestPassword {
            let output = try await tool.execute(
                input: ToolInput(toolName: "email.attachment", argumentsJSON: #"{"account":"personal","id":"42","index":0}"#),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == false)
            struct Skipped: Decodable { let path: String?; let skipped: Bool; let note: String? }
            let decoded = try JSONDecoder().decode(Skipped.self, from: Data(output.content.utf8))
            #expect(decoded.skipped == true)
            #expect(decoded.path == nil)
            #expect((decoded.note ?? "").contains("10 MB"))
            #expect(FileManager.default.fileExists(atPath: staging.path) == false)
        }
        try? FileManager.default.removeItem(at: staging)
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
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("runeweaver-attachment-\(UUID().uuidString)")
        let tool = EmailAttachmentTool(
            emailConfig: config,
            gateway: gateway,
            sandboxConfig: SandboxConfig(stagingPath: staging.path)
        )
        try await ToolsTestSupport.withTestPassword {
            let output = try await tool.execute(
                input: ToolInput(toolName: "email.attachment", argumentsJSON: #"{"account":"personal","id":"42","index":0}"#),
                context: ToolContext(conversationID: UUID(), dryRun: true)
            )
            #expect(output.isError == false)
            #expect(output.content.contains("Dry run"))
            #expect(FileManager.default.fileExists(atPath: staging.path) == false)
        }
        try? FileManager.default.removeItem(at: staging)
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
            input: ToolInput(toolName: "email.attachment", argumentsJSON: #"{"account":"personal","id":"42","index":-1}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(negative.isError == true)
        #expect(negative.content.contains("Invalid attachment index"))
        let badID = try await tool.execute(
            input: ToolInput(toolName: "email.attachment", argumentsJSON: #"{"account":"personal","id":"1;DROP","index":0}"#),
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
            input: ToolInput(toolName: "email.attachment", argumentsJSON: #"{"account":"missing","id":"1","index":0}"#),
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
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("runeweaver-attachment-\(UUID().uuidString)")
        let bus = ToolBus(permissionGate: PermissionGate())
        for tool in EmailTools.makeTools(
            emailConfig: config,
            gateway: gateway,
            sandboxConfig: SandboxConfig(stagingPath: staging.path)
        ) {
            await bus.register(tool: tool)
        }
        await ToolsTestSupport.withTestPassword {
            let input = ToolInput(toolName: "email.attachment", argumentsJSON: #"{"account":"personal","id":"42","index":0}"#)
            let result = await bus.execute(toolCall: input, context: ToolContext(conversationID: UUID()))
            #expect(result.isError == true)
            #expect(result.content.contains("requires approval"))
            #expect(FileManager.default.fileExists(atPath: staging.path) == false)
        }
        try? FileManager.default.removeItem(at: staging)
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
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("runeweaver-attachment-\(UUID().uuidString)")
        let tool = EmailAttachmentTool(
            emailConfig: config,
            gateway: gateway,
            sandboxConfig: SandboxConfig(stagingPath: staging.path)
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
            #expect((staged.path ?? "").hasPrefix(staging.path))
        }
        try? FileManager.default.removeItem(at: staging)
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
    func `Attachment args default preview to false for legacy calls`() throws {
        // Legacy callers omit the flag, so decoding must stay opt-in rather than inlining by surprise.
        let legacy = try JSONDecoder().decode(EmailAttachmentArgs.self, from: Data(#"{"account":"personal","id":"42","index":0}"#.utf8))
        #expect(legacy.preview == false)
        let requested = try JSONDecoder().decode(EmailAttachmentArgs.self, from: Data(#"{"account":"personal","id":"42","index":0,"preview":true}"#.utf8))
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
        #expect(EmailAttachmentLifecycle.mimeCategory(for: "application/zip") == "other")
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
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("runeweaver-attachment-\(UUID().uuidString)")
        let tool = EmailAttachmentTool(
            emailConfig: ToolsTestSupport.testEmailConfig(),
            gateway: gateway,
            sandboxConfig: SandboxConfig(stagingPath: staging.path, retentionDays: 7)
        )
        try await ToolsTestSupport.withTestPassword {
            let output = try await tool.execute(
                input: ToolInput(toolName: "email.attachment", argumentsJSON: #"{"account":"personal","id":"42","index":0}"#),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == false)
            let envelope = try JSONDecoder().decode(EmailAttachmentEnvelope.self, from: Data(output.content.utf8))
            #expect(envelope.skipped == false)
            #expect((envelope.path ?? "").hasPrefix(staging.path))
            #expect(envelope.mimeCategory == "text")
            let expiry = try #require(envelope.expiresAt)
            let parsed = ISO8601DateFormatter().date(from: expiry)
            #expect(parsed != nil)
            // A week of retention with clock skew tolerance for the download round trip.
            let remaining = (parsed ?? Date()).timeIntervalSince(Date())
            #expect(remaining > 6 * 86400 && remaining <= 7 * 86400 + 60)
            #expect((envelope.nextSteps ?? "").contains("files.read"))
            #expect((envelope.nextSteps ?? "").contains(envelope.path ?? ""))
            // No preview was requested, so text stays out of the envelope by default.
            #expect(envelope.preview == nil)
        }
        try? FileManager.default.removeItem(at: staging)
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
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("runeweaver-attachment-\(UUID().uuidString)")
        let tool = EmailAttachmentTool(
            emailConfig: ToolsTestSupport.testEmailConfig(),
            gateway: gateway,
            sandboxConfig: SandboxConfig(stagingPath: staging.path, retentionDays: 7)
        )
        try await ToolsTestSupport.withTestPassword {
            let output = try await tool.execute(
                input: ToolInput(toolName: "email.attachment", argumentsJSON: #"{"account":"personal","id":"42","index":0,"preview":true}"#),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == false)
            let envelope = try JSONDecoder().decode(EmailAttachmentEnvelope.self, from: Data(output.content.utf8))
            let preview = try #require(envelope.preview)
            #expect(preview.count == 2000)
            #expect(preview == String(long.prefix(2000)))
            #expect(envelope.previewTruncated == true)
            #expect((envelope.nextSteps ?? "").contains("files.read"))
        }
        try? FileManager.default.removeItem(at: staging)
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
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("runeweaver-attachment-\(UUID().uuidString)")
            let tool = EmailAttachmentTool(
                emailConfig: ToolsTestSupport.testEmailConfig(),
                gateway: gateway,
                sandboxConfig: SandboxConfig(stagingPath: staging.path)
            )
            try await ToolsTestSupport.withTestPassword {
                let output = try await tool.execute(
                    input: ToolInput(toolName: "email.attachment", argumentsJSON: #"{"account":"personal","id":"42","index":0,"preview":true}"#),
                    context: ToolContext(conversationID: UUID())
                )
                #expect(output.isError == false)
                let envelope = try JSONDecoder().decode(EmailAttachmentEnvelope.self, from: Data(output.content.utf8))
                #expect(envelope.mimeCategory == "text")
                #expect((envelope.preview ?? "").contains("hello"))
                #expect(envelope.previewTruncated == false)
            }
            try? FileManager.default.removeItem(at: staging)
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
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("runeweaver-attachment-\(UUID().uuidString)")
            let tool = EmailAttachmentTool(
                emailConfig: ToolsTestSupport.testEmailConfig(),
                gateway: gateway,
                sandboxConfig: SandboxConfig(stagingPath: staging.path)
            )
            try await ToolsTestSupport.withTestPassword {
                let output = try await tool.execute(
                    input: ToolInput(toolName: "email.attachment", argumentsJSON: #"{"account":"personal","id":"42","index":0,"preview":true}"#),
                    context: ToolContext(conversationID: UUID())
                )
                #expect(output.isError == false)
                let envelope = try JSONDecoder().decode(EmailAttachmentEnvelope.self, from: Data(output.content.utf8))
                #expect(envelope.preview == nil)
                #expect(envelope.previewTruncated == nil)
                #expect(envelope.mimeCategory != "text")
                #expect((envelope.nextSteps ?? "").contains("files.read"))
            }
            try? FileManager.default.removeItem(at: staging)
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
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("runeweaver-attachment-\(UUID().uuidString)")
        let tool = EmailAttachmentTool(
            emailConfig: ToolsTestSupport.testEmailConfig(),
            gateway: gateway,
            sandboxConfig: SandboxConfig(stagingPath: staging.path)
        )
        try await ToolsTestSupport.withTestPassword {
            let output = try await tool.execute(
                input: ToolInput(toolName: "email.attachment", argumentsJSON: #"{"account":"personal","id":"42","index":0,"preview":true}"#),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == false)
            let envelope = try JSONDecoder().decode(EmailAttachmentEnvelope.self, from: Data(output.content.utf8))
            #expect(envelope.preview == nil)
            #expect(envelope.previewTruncated == nil)
            #expect(envelope.mimeCategory == "text")
        }
        try? FileManager.default.removeItem(at: staging)
    }

    @Test
    func `Attachment skip envelopes keep the legacy shape with no lifecycle keys`() async throws {
        // Oversized and dry-run outcomes must not gain lifecycle keys, so old readers keep working.
        let oversize = EmailAttachmentTool.maxAttachmentBytes + 1
        let gateway = ToolsTestSupport.StubEmailGateway(attachment: EmailAttachmentData(
            filename: "big.bin",
            contentType: "application/octet-stream",
            sizeBytes: oversize,
            data: Data(repeating: 0, count: 8)
        ))
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("runeweaver-attachment-\(UUID().uuidString)")
        let tool = EmailAttachmentTool(
            emailConfig: ToolsTestSupport.testEmailConfig(),
            gateway: gateway,
            sandboxConfig: SandboxConfig(stagingPath: staging.path)
        )
        try await ToolsTestSupport.withTestPassword {
            let output = try await tool.execute(
                input: ToolInput(toolName: "email.attachment", argumentsJSON: #"{"account":"personal","id":"42","index":0,"preview":true}"#),
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
        try? FileManager.default.removeItem(at: staging)
    }

    @Test
    func `Attachment legacy envelopes decode without lifecycle keys`() throws {
        // Envelopes written before the lifecycle landed must still decode with lifecycle fields as nil.
        let legacy = #"{"account":"personal","id":"42","index":0,"filename":"report.pdf","contentType":"application/pdf","sizeBytes":11,"path":"/tmp/report.pdf","skipped":false,"mailbox":"INBOX"}"#
        let envelope = try JSONDecoder().decode(EmailAttachmentEnvelope.self, from: Data(legacy.utf8))
        #expect(envelope.path == "/tmp/report.pdf")
        #expect(envelope.expiresAt == nil)
        #expect(envelope.mimeCategory == nil)
        #expect(envelope.nextSteps == nil)
        #expect(envelope.preview == nil)
        #expect(envelope.previewTruncated == nil)
        let encoded = try EmailBridgeParsing.encodeAttachmentEnvelope(envelope)
        #expect(encoded.contains("report.pdf"))
    }
}

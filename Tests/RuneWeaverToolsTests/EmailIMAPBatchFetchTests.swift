// Rune Weaver Tools Tests — Batched IMAP message fetch coverage.

import Foundation
@testable import RuneWeaverCore
@testable import RuneWeaverTools
import Testing

struct EmailIMAPBatchFetchTests {
    @Test
    func `Bridge script compiles as valid Python 3 with batch_fetch`() throws {
        let source = EmailIMAPBridgeScript.source
        #expect(source.contains("op == \"batch_fetch\""))
        try ToolsTestSupport.assertBridgeSourceParses(source)
    }

    @Test
    func `Batch fetch request encodes expected JSON fields`() throws {
        let credentials = ResolvedEmailCredentials(
            accountName: "work",
            host: "mail.example.com",
            port: 993,
            username: "worker@example.com",
            password: "supersecretpassword"
        )
        let request = EmailIMAPBridgeRequest.batchFetch(
            credentials: credentials,
            mailbox: "INBOX",
            query: "UID 1000:2000",
            limit: 50
        )
        let data = try JSONEncoder().encode(request)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((json["op"] as? String) == "batch_fetch")
        #expect((json["host"] as? String) == "mail.example.com")
        #expect((json["port"] as? Int) == 993)
        #expect((json["username"] as? String) == "worker@example.com")
        #expect((json["password"] as? String) == "supersecretpassword")
        #expect((json["mailbox"] as? String) == "INBOX")
        #expect((json["query"] as? String) == "UID 1000:2000")
        #expect((json["limit"] as? Int) == 50)
    }

    @Test
    func `Batch fetch payload decodes full messages successfully`() throws {
        let payload = #"""
        {
            "ok": true,
            "messages": [
                {
                    "id": "101",
                    "subject": "Status Report",
                    "from": "alice@example.com",
                    "to": "bob@example.com",
                    "date": "Mon, 01 Sep 2025 10:00:00 +0000",
                    "body": "Here is the weekly update.",
                    "attachments": [
                        {
                            "filename": "report.pdf",
                            "contentType": "application/pdf",
                            "sizeBytes": 1024
                        }
                    ],
                    "attachmentsDeferred": true,
                    "attachmentsNote": "1 attachment available"
                }
            ]
        }
        """#
        let messages = try EmailBridgeParsing.parseBatchFetchPayload(Data(payload.utf8))
        #expect(messages.count == 1)
        let first = messages[0]
        #expect(first.id == "101")
        #expect(first.subject == "Status Report")
        #expect(first.from == "alice@example.com")
        #expect(first.to == "bob@example.com")
        #expect(first.body == "Here is the weekly update.")
        #expect(first.attachments.count == 1)
        #expect(first.attachments[0].filename == "report.pdf")
    }

    @Test
    func `Batch fetch payload throws bridgeFailed on failure envelope`() {
        let payload = #"{"ok": false, "error": "IMAP mailbox not found"}"#
        #expect(throws: EmailIMAPError.self) {
            try EmailBridgeParsing.parseBatchFetchPayload(Data(payload.utf8))
        }
    }

    @Test
    func `Adapter maps batch fetch directly into indexed messages with redaction`() async throws {
        let message = EmailFullMessage(
            id: "205",
            subject: "Your OTP is 987654",
            from: "security@service.com",
            to: "user@example.com",
            date: "Tue, 02 Sep 2025 12:00:00 +0000",
            body: "Your confirmation code is 987654. Click https://service.com/verify?code=abc to confirm."
        )
        let stub = ToolsTestSupport.StubEmailGateway(message: message)
        let adapter = EmailIMAPMailIndexGateway(gateway: stub, credentialFilterEnabled: true)
        let credentials = MailIndexCredentials(
            accountName: "personal",
            host: "imap.example.com",
            port: 993,
            username: "user@example.com",
            password: "password"
        )
        let messages = try await adapter.messages(
            credentials: credentials,
            mailbox: "INBOX",
            limit: 10,
            mode: .peek
        )
        #expect(messages.count == 1)
        let indexed = messages[0]
        #expect(indexed.id == "205")
        #expect(!indexed.body.contains("987654"))
        #expect(!indexed.body.contains("abc"))
        #expect(indexed.body.contains(EmailCredentialFilter.redactedCodePlaceholder))
        #expect(indexed.body.contains(EmailCredentialFilter.redactedLinkPlaceholder))
    }

    @Test
    func `Live event log detects test environment and remains silent`() {
        #expect(MailSessionEventLog.isRunningInTestEnvironment)
        MailSessionEventLog.live.emit(
            event: "test.event",
            account: "test-account",
            pid: nil,
            fields: ["probe": true]
        )
    }
}

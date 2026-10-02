// Rune Weaver Tools Tests — Service-aware send transport and send payloads.
//
// Purpose: pin the send details that are easy to get silently wrong — the
// AppleScript must target the service history observed (and keep the recovery
// fallback when it did not), `osascript` failures must map to typed
// owner-actionable errors, the result and envelope payloads must carry service
// and confirmation fields without breaking older JSON, and the tool must
// surface an unconfirmed delivery as a caveat rather than a silent success.
//
// Scope: pure helpers, codable payloads, and gateway stubs. No test invokes
// `osascript` or touches the real Messages database; the production gateway
// paths exercised are rejections that fail before any process launch or
// database read.
//
// Architectural role: guards `MessagesSendTransport` and the send payload
// types, so a transport regression surfaces here instead of in a live send.

import Foundation
@testable import RuneWeaverCore
@testable import RuneWeaverTools
import Testing

/// Gateway stub returning one canned send result without touching Messages.
private struct CannedSendGateway: MessagesGateway {
    let result: MessagesSendResult

    func search(query _: String?, recipient _: String?, limit _: Int, since _: Date?, until _: Date?) async throws -> [MessagesMessageItem] {
        []
    }

    func read(chatID _: String?, recipient _: String?, limit _: Int, since _: Date?, until _: Date?) async throws -> [MessagesMessageItem] {
        []
    }

    func send(recipient _: String, text _: String) async throws -> MessagesSendResult {
        result
    }
}

/// Gateway stub that fails the send the way an `osascript` failure would.
private struct FailingSendGateway: MessagesGateway {
    func search(query _: String?, recipient _: String?, limit _: Int, since _: Date?, until _: Date?) async throws -> [MessagesMessageItem] {
        []
    }

    func read(chatID _: String?, recipient _: String?, limit _: Int, since _: Date?, until _: Date?) async throws -> [MessagesMessageItem] {
        []
    }

    func send(recipient _: String, text _: String) async throws -> MessagesSendResult {
        throw MessagesToolError.scriptFailed("boom")
    }
}

@Suite("Messages Send Transport")
struct MessagesSendTransportTests {
    // MARK: - Script builder

    @Test
    func `SMS service builds a targeted script without the recovery fallback`() {
        let script = MessagesAppleScriptSend.script(handle: "+15551234567", text: "On my way", service: "SMS")

        #expect(script.contains("set targetService to 1st account whose service type = SMS"))
        #expect(script.contains("participant \"+15551234567\" of targetService"))
        #expect(script.contains("send \"On my way\" to targetBuddy"))
        #expect(!script.contains("on error"))
        #expect(!script.contains("service type = iMessage"))
    }

    @Test
    func `iMessage service builds a targeted script without the recovery fallback`() {
        let script = MessagesAppleScriptSend.script(handle: "alice@example.com", text: "Lunch?", service: "iMessage")

        #expect(script.contains("set targetService to 1st account whose service type = iMessage"))
        #expect(script.contains("participant \"alice@example.com\" of targetService"))
        #expect(script.contains("send \"Lunch?\" to targetBuddy"))
        #expect(!script.contains("on error"))
    }

    @Test
    func `Nil service keeps the legacy recovery script verbatim`() {
        let script = MessagesAppleScriptSend.script(handle: "+15551234567", text: "Hi", service: nil)

        #expect(script == """
        tell application "Messages"
            set targetService to 1st account whose service type = iMessage
            try
                set targetBuddy to participant "+15551234567" of targetService
                send "Hi" to targetBuddy
            on error
                send "Hi" to participant "+15551234567"
            end try
        end tell
        """)
    }

    @Test
    func `Unknown service keeps the recovery fallback instead of guessing`() {
        let unknown = MessagesAppleScriptSend.script(handle: "+15551234567", text: "Hi", service: "RCS")
        let legacy = MessagesAppleScriptSend.script(handle: "+15551234567", text: "Hi", service: nil)

        #expect(unknown == legacy)
    }

    @Test
    func `Script builder escapes quotes, backslashes, and control characters`() {
        let script = MessagesAppleScriptSend.script(
            handle: "a\"b\\c@example.com",
            text: "Line1\nLine2\t\"quoted\"",
            service: "iMessage"
        )

        #expect(script.contains("participant \"a\\\"b\\\\c@example.com\" of targetService"))
        #expect(script.contains("send \"Line1\\nLine2\\t\\\"quoted\\\"\" to targetBuddy"))
    }

    // MARK: - Error mapping

    @Test
    func `Automation denial maps to automationDenied`() {
        let mapped = MessagesAppleScriptErrorMapping.map(
            exitCode: 1,
            stderr: "execution error: Not authorized to send Apple events to Messages. (-1743)\n"
        )

        #expect(mapped == .automationDenied(
            "Automation permission for Messages is required; grant it in System Settings -> Privacy & Security -> Automation."
        ))
        #expect(mapped.errorDescription?.contains("Privacy & Security -> Automation") == true)
    }

    @Test
    func `Automation denial maps on prose alone when the code is absent`() {
        let mapped = MessagesAppleScriptErrorMapping.map(
            exitCode: 1,
            stderr: "Messages is not authorized to do that."
        )

        #expect(mapped == .automationDenied(
            "Automation permission for Messages is required; grant it in System Settings -> Privacy & Security -> Automation."
        ))
    }

    @Test
    func `Recipient resolution failure maps to recipientUnresolved`() {
        let mapped = MessagesAppleScriptErrorMapping.map(
            exitCode: 1,
            stderr: "execution error: Messages got an error: Can't get participant \"nobody@example.com\". (-1728)"
        )

        #expect(mapped == .recipientUnresolved("Messages could not resolve the recipient handle."))
    }

    @Test
    func `Automation denial wins when stderr carries both codes`() {
        let mapped = MessagesAppleScriptErrorMapping.map(exitCode: 1, stderr: "-1743 then -1728")

        #expect(mapped == .automationDenied(
            "Automation permission for Messages is required; grant it in System Settings -> Privacy & Security -> Automation."
        ))
    }

    @Test
    func `Unrecognized stderr maps to scriptFailed with the trimmed detail`() {
        let mapped = MessagesAppleScriptErrorMapping.map(exitCode: 2, stderr: "  something broke\n")

        #expect(mapped == .scriptFailed("something broke"))
    }

    @Test
    func `Empty stderr maps to scriptFailed naming the exit code`() {
        let mapped = MessagesAppleScriptErrorMapping.map(exitCode: 70, stderr: " \n ")

        #expect(mapped == .scriptFailed("Exit code 70"))
    }

    // MARK: - Payload compatibility

    @Test
    func `Send result and envelope decode legacy JSON without the new fields`() throws {
        let legacyResult = Data(#"{"success":true,"recipient":"alice@example.com","text":"hi"}"#.utf8)
        let result = try JSONDecoder().decode(MessagesSendResult.self, from: legacyResult)
        #expect(result.service == nil)
        #expect(result.confirmed == nil)

        let legacyEnvelope = Data(#"{"success":true,"recipient":"alice@example.com","text":"hi","note":"ok"}"#.utf8)
        let envelope = try JSONDecoder().decode(MessagesSendEnvelope.self, from: legacyEnvelope)
        #expect(envelope.note == "ok")
        #expect(envelope.service == nil)
        #expect(envelope.confirmed == nil)
    }

    @Test
    func `Send result and envelope round-trip service and confirmation`() throws {
        let result = MessagesSendResult(
            success: true,
            recipient: "alice@example.com",
            text: "hi",
            details: "Handed to Messages.",
            service: "SMS",
            confirmed: false
        )
        let decodedResult = try JSONDecoder().decode(MessagesSendResult.self, from: JSONEncoder().encode(result))
        #expect(decodedResult == result)

        let envelope = MessagesSendEnvelope(
            success: true,
            recipient: "alice@example.com",
            text: "hi",
            note: "Handed to Messages.",
            service: "iMessage",
            confirmed: true
        )
        let decodedEnvelope = try JSONDecoder().decode(MessagesSendEnvelope.self, from: JSONEncoder().encode(envelope))
        #expect(decodedEnvelope == envelope)
    }

    // MARK: - Gateway validation

    @Test
    func `Gateway rejects name-shaped recipients before any process launch`() async {
        let gateway = ProductionMessagesGateway(chatDatabasePath: "/nonexistent/chat.db")

        do {
            _ = try await gateway.send(recipient: "Rebecca", text: "on my way")
            Issue.record("Expected invalidInput for a name-shaped recipient")
        } catch let error as MessagesToolError {
            #expect(error == .invalidInput("Recipient must be a phone number or email handle."))
        } catch {
            Issue.record("Expected MessagesToolError, got \(error)")
        }
    }

    @Test
    func `Gateway keeps empty and null-byte validation unchanged`() async {
        let gateway = ProductionMessagesGateway(chatDatabasePath: "/nonexistent/chat.db")

        do {
            _ = try await gateway.send(recipient: "  ", text: "hi")
            Issue.record("Expected emptyRecipient")
        } catch let error as MessagesToolError {
            #expect(error == .emptyRecipient)
        } catch {
            Issue.record("Expected MessagesToolError, got \(error)")
        }

        do {
            _ = try await gateway.send(recipient: "+15551234567", text: "   ")
            Issue.record("Expected emptyMessage")
        } catch let error as MessagesToolError {
            #expect(error == .emptyMessage)
        } catch {
            Issue.record("Expected MessagesToolError, got \(error)")
        }

        do {
            _ = try await gateway.send(recipient: "+15551234567", text: "hi\0there")
            Issue.record("Expected invalidInput for an embedded null byte")
        } catch let error as MessagesToolError {
            #expect(error == .invalidInput("Message text must not contain null bytes."))
        } catch {
            Issue.record("Expected MessagesToolError, got \(error)")
        }
    }

    // MARK: - Envelope note composition

    @Test
    func `Unconfirmed send appends the delivery caveat to the envelope note`() async throws {
        let tool = MessagesSendTool(gateway: CannedSendGateway(
            result: MessagesSendResult(
                success: true,
                recipient: "alice@example.com",
                text: "hi",
                service: "SMS",
                confirmed: false
            )
        ))
        let output = try await tool.execute(
            input: ToolInput(toolName: "messages.send", argumentsJSON: #"{"recipient":"alice@example.com","text":"hi"}"#),
            context: ToolContext(conversationID: UUID())
        )

        #expect(output.isError == false)
        let envelope = try JSONDecoder().decode(MessagesSendEnvelope.self, from: Data(output.content.utf8))
        #expect(envelope.success == true)
        #expect(envelope.confirmed == false)
        #expect(envelope.service == "SMS")
        #expect(envelope.note == "Sent; delivery not yet visible in Messages history.")
    }

    @Test
    func `Unconfirmed send keeps the gateway note ahead of the caveat`() async throws {
        let tool = MessagesSendTool(gateway: CannedSendGateway(
            result: MessagesSendResult(
                success: true,
                recipient: "alice@example.com",
                text: "hi",
                details: "Handed to Messages.",
                confirmed: false
            )
        ))
        let output = try await tool.execute(
            input: ToolInput(toolName: "messages.send", argumentsJSON: #"{"recipient":"alice@example.com","text":"hi"}"#),
            context: ToolContext(conversationID: UUID())
        )

        let envelope = try JSONDecoder().decode(MessagesSendEnvelope.self, from: Data(output.content.utf8))
        #expect(envelope.note == "Handed to Messages. Sent; delivery not yet visible in Messages history.")
    }

    @Test
    func `Confirmed send leaves a nil note untouched`() async throws {
        let tool = MessagesSendTool(gateway: CannedSendGateway(
            result: MessagesSendResult(success: true, recipient: "alice@example.com", text: "hi", confirmed: true)
        ))
        let output = try await tool.execute(
            input: ToolInput(toolName: "messages.send", argumentsJSON: #"{"recipient":"alice@example.com","text":"hi"}"#),
            context: ToolContext(conversationID: UUID())
        )

        let envelope = try JSONDecoder().decode(MessagesSendEnvelope.self, from: Data(output.content.utf8))
        #expect(envelope.confirmed == true)
        #expect(envelope.note == nil)
    }

    @Test
    func `Failed send never reports success`() async throws {
        let tool = MessagesSendTool(gateway: FailingSendGateway())
        let output = try await tool.execute(
            input: ToolInput(toolName: "messages.send", argumentsJSON: #"{"recipient":"alice@example.com","text":"hi"}"#),
            context: ToolContext(conversationID: UUID())
        )

        #expect(output.isError == true)
        #expect(output.content.contains("messages.send failed"))
        #expect(!output.content.contains("\"success\""))
    }
}

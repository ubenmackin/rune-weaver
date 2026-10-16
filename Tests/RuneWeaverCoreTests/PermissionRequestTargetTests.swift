// Rune Weaver Core Tests — PermissionRequestTarget derivation matrix and displayTarget codable contract.

import Foundation
@testable import RuneWeaverCore
import Testing

@Suite("PermissionRequestTarget derivation")
struct PermissionRequestTargetTests {
    @Test
    func `egress host wins over arguments`() {
        let target = PermissionRequestTarget.derive(
            toolName: "web.fetch",
            argumentsJSON: #"{"url":"https://example.com"}"#,
            egressHost: "example.com"
        )
        #expect(target == "example.com")
    }

    @Test
    func `empty egress host is treated as absent`() {
        let target = PermissionRequestTarget.derive(
            toolName: "web.fetch",
            argumentsJSON: #"{"url":"https://example.com"}"#,
            egressHost: "   "
        )
        #expect(target == "https://example.com")
    }

    @Test
    func `email send with string to`() {
        let target = PermissionRequestTarget.derive(
            toolName: "email.send",
            argumentsJSON: #"{"to":"a@example.com"}"#,
            egressHost: nil
        )
        #expect(target == "a@example.com")
    }

    @Test
    func `email send with array to joins with comma`() {
        let target = PermissionRequestTarget.derive(
            toolName: "email.send",
            argumentsJSON: #"{"to":["a@example.com","b@example.com"]}"#,
            egressHost: nil
        )
        #expect(target == "a@example.com, b@example.com")
    }

    @Test
    func `email send missing to yields nil`() {
        let target = PermissionRequestTarget.derive(
            toolName: "email.send",
            argumentsJSON: #"{"subject":"hi"}"#,
            egressHost: nil
        )
        #expect(target == nil)
    }

    @Test
    func `messages send uses recipient`() {
        let target = PermissionRequestTarget.derive(
            toolName: "messages.send",
            argumentsJSON: #"{"recipient":"+15551234567"}"#,
            egressHost: nil
        )
        #expect(target == "+15551234567")
    }

    @Test
    func `bash exec uses command`() {
        let target = PermissionRequestTarget.derive(
            toolName: "bash.exec",
            argumentsJSON: #"{"command":"ls -la"}"#,
            egressHost: nil
        )
        #expect(target == "ls -la")
    }

    @Test
    func `files write uses path`() {
        let target = PermissionRequestTarget.derive(
            toolName: "files.write",
            argumentsJSON: #"{"path":"/tmp/notes.txt"}"#,
            egressHost: nil
        )
        #expect(target == "/tmp/notes.txt")
    }

    @Test
    func `generic tool prefers target over url`() {
        let target = PermissionRequestTarget.derive(
            toolName: "custom.tool",
            argumentsJSON: #"{"target":"primary","url":"https://example.com"}"#,
            egressHost: nil
        )
        #expect(target == "primary")
    }

    @Test
    func `generic tool falls back to url`() {
        let target = PermissionRequestTarget.derive(
            toolName: "custom.tool",
            argumentsJSON: #"{"url":"https://example.com"}"#,
            egressHost: nil
        )
        #expect(target == "https://example.com")
    }

    @Test
    func `malformed JSON yields nil`() {
        let target = PermissionRequestTarget.derive(
            toolName: "custom.tool",
            argumentsJSON: "not-json",
            egressHost: nil
        )
        #expect(target == nil)
    }

    @Test
    func `non-object JSON yields nil`() {
        let target = PermissionRequestTarget.derive(
            toolName: "custom.tool",
            argumentsJSON: "[1,2,3]",
            egressHost: nil
        )
        #expect(target == nil)
    }

    @Test
    func `request init populates displayTarget`() {
        let request = PermissionRequest(
            toolName: "bash.exec",
            input: ToolInput(toolName: "bash.exec", argumentsJSON: #"{"command":"ls"}"#)
        )
        #expect(request.displayTarget == "ls")
    }

    @Test
    func `request without derivable target carries nil`() {
        let request = PermissionRequest(
            toolName: "custom.tool",
            input: ToolInput(toolName: "custom.tool", argumentsJSON: #"{"other":"value"}"#)
        )
        #expect(request.displayTarget == nil)
    }

    @Test
    func `codable round trip preserves displayTarget`() throws {
        let request = PermissionRequest(
            toolName: "email.send",
            input: ToolInput(toolName: "email.send", argumentsJSON: #"{"to":"a@example.com"}"#)
        )
        let encoded = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(PermissionRequest.self, from: encoded)
        #expect(decoded.displayTarget == "a@example.com")
        #expect(decoded == request)
    }

    @Test
    func `legacy payload without field decodes to nil`() throws {
        let legacyJSON = """
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "toolName": "bash.exec",
            "description": "",
            "input": {
                "toolName": "bash.exec",
                "argumentsJSON": "{\\"command\\":\\"ls\\"}",
                "callID": "call-1"
            },
            "suggestedDurations": ["thisTime"]
        }
        """
        let data = try #require(legacyJSON.data(using: .utf8))
        let decoded = try JSONDecoder().decode(PermissionRequest.self, from: data)
        #expect(decoded.displayTarget == nil)
    }
}

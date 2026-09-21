// Rune Weaver Tests — Tool placeholder arguments fidelity and round-trip parsing.

import Foundation
@testable import RuneWeaverCore
import Testing

@Suite("Tool Placeholder Truncation & Round-Trip")
struct ToolPlaceholderTruncationTests {
    @Test
    func `placeholderContent does not truncate long argumentsJSON`() throws {
        let longBody = String(repeating: "This is a detailed report paragraph with lots of content. ", count: 10)
        let payload: [String: Any] = [
            "to": ["user@example.com", "admin@example.com"],
            "subject": "Tool Smoke Test Report (2026-09-21)",
            "bodyText": "## Tool Smoke Test Report (2026-09-21)\n\n### Summary:\n" + longBody
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let jsonString = try #require(String(bytes: data, encoding: .utf8))
        #expect(jsonString.count > 160, "Test payload must exceed the legacy 160-character limit")

        let callID = "call_test_123"
        let input = ToolInput(toolName: "email.send", argumentsJSON: jsonString, callID: callID)
        let placeholder = ToolInput.placeholderContent(for: [input])

        // Verify the line does not end with a truncated ellipsis before the call ID
        #expect(!placeholder.contains("… [\(callID)]"))
        #expect(!placeholder.contains("\n"))

        // Verify round-trip parsing parses the full, intact JSON back out
        let parsed = try #require(ToolInput.parsePlaceholderLine(placeholder))
        #expect(parsed.toolName == "email.send")
        #expect(parsed.callID == callID)

        // Verify the parsed arguments are valid JSON and decode back to identical keys/values
        let parsedData = try #require(parsed.argumentsJSON.data(using: .utf8))
        let parsedJSON = try #require(try JSONSerialization.jsonObject(with: parsedData) as? [String: Any])
        #expect(parsedJSON["subject"] as? String == "Tool Smoke Test Report (2026-09-21)")
        #expect((parsedJSON["to"] as? [String]) == ["user@example.com", "admin@example.com"])
        #expect(parsedJSON["bodyText"] as? String == "## Tool Smoke Test Report (2026-09-21)\n\n### Summary:\n" + longBody)
    }

    @Test
    func `inline helper respects explicit limit when given and does not truncate when omitted`() {
        let text = "Hello world this is a test string that is definitely longer than twenty characters."
        let truncated = ToolInput.inline(text, limit: 20)
        #expect(truncated.hasSuffix("…"))
        #expect(truncated.count == 21) // 20 chars prefix + 1 char unicode ellipsis

        let untruncated = ToolInput.inline(text)
        #expect(!untruncated.contains("…"))
        #expect(untruncated == text)
    }

    @Test
    func `placeholderContent collapses newlines and tabs into single spaces`() {
        let multiLineJSON = """
        {
          "account": "personal",
          "subject": "Hello\\nWorld",
          "body": "Line 1\\nLine 2"
        }
        """
        let input = ToolInput(toolName: "email.send", argumentsJSON: multiLineJSON, callID: "call_abc")
        let placeholder = ToolInput.placeholderContent(for: [input])
        #expect(!placeholder.contains("\n"))
        #expect(!placeholder.contains("\t"))

        let parsed = ToolInput.parsePlaceholderLine(placeholder)
        #expect(parsed != nil)
        #expect(parsed?.toolName == "email.send")
        #expect(parsed?.callID == "call_abc")
    }
}

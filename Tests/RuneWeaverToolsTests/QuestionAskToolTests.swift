// Rune Weaver Tools Tests — QuestionAskTool behavior and schema coverage.

import Foundation
@testable import RuneWeaverCore
@testable import RuneWeaverTools
import Testing

@Suite("QuestionAskTool Tests")
struct QuestionAskToolTests {
    @Test
    func `Tool metadata and permissions match expectations`() {
        let tool = QuestionAskTool()
        #expect(tool.name == "question.ask")
        #expect(tool.permissionLevel == .requiresApproval)
        #expect(tool.description.contains("multiple-choice question"))
    }

    @Test
    func `Valid arguments execute successfully`() async throws {
        let tool = QuestionAskTool()
        let input = ToolInput(
            toolName: "question.ask",
            argumentsJSON: """
            {
                "question": "Which movie would you like to queue up?",
                "options": ["The Matrix (1999)", "The Matrix Reloaded (2003)"]
            }
            """,
            callID: "call_123"
        )
        let context = ToolContext(conversationID: UUID())
        let output = try await tool.execute(input: input, context: context)
        #expect(!output.isError)
        #expect(output.content.contains("Which movie would you like to queue up?"))
    }

    @Test
    func `Invalid JSON arguments fail`() async throws {
        let tool = QuestionAskTool()
        let input = ToolInput(
            toolName: "question.ask",
            argumentsJSON: "{ invalid json }",
            callID: "call_bad_json"
        )
        let output = try await tool.execute(input: input, context: ToolContext(conversationID: UUID()))
        #expect(output.isError)
    }

    @Test
    func `Fewer than 2 options fails validation`() async throws {
        let tool = QuestionAskTool()
        let input = ToolInput(
            toolName: "question.ask",
            argumentsJSON: """
            {
                "question": "Which movie?",
                "options": ["Single Option"]
            }
            """,
            callID: "call_too_few"
        )
        let output = try await tool.execute(input: input, context: ToolContext(conversationID: UUID()))
        #expect(output.isError)
        #expect(output.content.contains("between 2 and 4 options"))
    }

    @Test
    func `More than 4 options fails validation`() async throws {
        let tool = QuestionAskTool()
        let input = ToolInput(
            toolName: "question.ask",
            argumentsJSON: """
            {
                "question": "Which movie?",
                "options": ["Opt 1", "Opt 2", "Opt 3", "Opt 4", "Opt 5"]
            }
            """,
            callID: "call_too_many"
        )
        let output = try await tool.execute(input: input, context: ToolContext(conversationID: UUID()))
        #expect(output.isError)
        #expect(output.content.contains("between 2 and 4 options"))
    }

    @Test
    func `Empty question string fails validation`() async throws {
        let tool = QuestionAskTool()
        let input = ToolInput(
            toolName: "question.ask",
            argumentsJSON: """
            {
                "question": "   ",
                "options": ["Opt 1", "Opt 2"]
            }
            """,
            callID: "call_empty_q"
        )
        let output = try await tool.execute(input: input, context: ToolContext(conversationID: UUID()))
        #expect(output.isError)
        #expect(output.content.contains("non-empty question string"))
    }
}

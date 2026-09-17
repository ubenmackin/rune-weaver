// Rune Weaver LLM Tests — Responses request body generation and formatting.
import Foundation
@testable import RuneWeaverCore
@testable import RuneWeaverLLM
import Testing

@Suite("Responses Request Body")
struct ResponsesRequestBodyTests {
    @Test
    func `Single tool turn maps to function_call and output`() throws {
        let callID = "call_123"
        let args = #"{"query":"hello"}"#
        let placeholder = ToolInput.placeholderContent(for: [
            ToolInput(toolName: "email.search", argumentsJSON: args, callID: callID)
        ])
        let messages = [
            Message(role: .user, content: "Find emails about hello"),
            Message(role: .assistant, content: placeholder),
            Message(role: .tool, content: #"{"results":[]}"#, toolCallID: callID),
            Message(role: .assistant, content: "I found nothing.")
        ]
        let tools = [
            ToolDefinition(
                name: "email.search",
                description: "Search email",
                parameters: JSONSchema(rawValue: #"{"type":"object"}"#)
            )
        ]
        let body = try openAIResponsesRequestBody(model: "gpt-4o-mini", messages: messages, tools: tools, stream: true)
        let input = try responsesInputItems(from: body)
        try #require(input.count == 4)

        let userItem = input[0]
        #expect((userItem["role"] as? String) == "user")
        let userContent = try #require(userItem["content"] as? [[String: Any]])
        try #require(userContent.count == 1)
        #expect((userContent[0]["type"] as? String) == "input_text")

        let callItem = input[1]
        #expect((callItem["type"] as? String) == "function_call")
        #expect((callItem["call_id"] as? String) == callID)
        #expect((callItem["name"] as? String) == "email.search")
        #expect((callItem["arguments"] as? String) == args)

        let outputItem = input[2]
        #expect((outputItem["type"] as? String) == "function_call_output")
        #expect((outputItem["call_id"] as? String) == callID)
        #expect((outputItem["output"] as? String) == #"{"results":[]}"#)

        let finalItem = input[3]
        #expect((finalItem["role"] as? String) == "assistant")
        let finalContent = try #require(finalItem["content"] as? [[String: Any]])
        try #require(finalContent.count == 1)
        #expect((finalContent[0]["type"] as? String) == "output_text")
        #expect((finalContent[0]["text"] as? String) == "I found nothing.")

        assertNoInputTextOnAssistantOrToolItems(input)
    }

    @Test
    func `Multi-call turn maps to two function_calls and both outputs`() throws {
        let firstID = "call_111"
        let secondID = "call_222"
        let firstArgs = #"{"query":"hello"}"#
        let secondArgs = #"{"date":"tomorrow"}"#
        let placeholder = ToolInput.placeholderContent(for: [
            ToolInput(toolName: "email.search", argumentsJSON: firstArgs, callID: firstID),
            ToolInput(toolName: "calendar.list", argumentsJSON: secondArgs, callID: secondID)
        ])
        let messages = [
            Message(role: .user, content: "Check email and calendar"),
            Message(role: .assistant, content: placeholder),
            Message(role: .tool, content: #"{"results":[]}"#, toolCallID: firstID),
            Message(role: .tool, content: #"{"events":[]}"#, toolCallID: secondID),
            Message(role: .assistant, content: "Done.")
        ]
        let tools = [
            ToolDefinition(
                name: "email.search",
                description: "Search email",
                parameters: JSONSchema(rawValue: #"{"type":"object"}"#)
            ),
            ToolDefinition(
                name: "calendar.list",
                description: "List events",
                parameters: JSONSchema(rawValue: #"{"type":"object"}"#)
            )
        ]
        let body = try openAIResponsesRequestBody(model: "gpt-4o-mini", messages: messages, tools: tools, stream: true)
        let input = try responsesInputItems(from: body)
        try #require(input.count == 6)

        let firstCall = input[1]
        #expect((firstCall["type"] as? String) == "function_call")
        #expect((firstCall["call_id"] as? String) == firstID)
        #expect((firstCall["name"] as? String) == "email.search")
        #expect((firstCall["arguments"] as? String) == firstArgs)

        let secondCall = input[2]
        #expect((secondCall["type"] as? String) == "function_call")
        #expect((secondCall["call_id"] as? String) == secondID)
        #expect((secondCall["name"] as? String) == "calendar.list")
        #expect((secondCall["arguments"] as? String) == secondArgs)

        let firstOutput = input[3]
        #expect((firstOutput["type"] as? String) == "function_call_output")
        #expect((firstOutput["call_id"] as? String) == firstID)

        let secondOutput = input[4]
        #expect((secondOutput["type"] as? String) == "function_call_output")
        #expect((secondOutput["call_id"] as? String) == secondID)

        let finalItem = input[5]
        #expect((finalItem["role"] as? String) == "assistant")
        let finalContent = try #require(finalItem["content"] as? [[String: Any]])
        try #require(!finalContent.isEmpty)
        #expect((finalContent[0]["type"] as? String) == "output_text")

        assertNoInputTextOnAssistantOrToolItems(input)
    }

    @Test
    func `Real provider call ID round-trips with hex suffix`() throws {
        let callID = "call_01a09249e1177af390085e651e9bd8c6"
        let args = #"{"limit":5,"query":"email address"}"#
        let placeholder = ToolInput.placeholderContent(for: [
            ToolInput(toolName: "recall_memories", argumentsJSON: args, callID: callID)
        ])
        let messages = [
            Message(role: .user, content: "What is my email address?"),
            Message(role: .assistant, content: placeholder),
            Message(role: .tool, content: #"{"facts":[]}"#, toolCallID: callID),
            Message(role: .assistant, content: "I found nothing.")
        ]
        let tools = [
            ToolDefinition(
                name: "recall_memories",
                description: "Recall memories",
                parameters: JSONSchema(rawValue: #"{"type":"object"}"#)
            )
        ]
        let body = try openAIResponsesRequestBody(model: "gpt-4o-mini", messages: messages, tools: tools, stream: true)
        let input = try responsesInputItems(from: body)
        try #require(input.count == 4)

        let callItem = input[1]
        #expect((callItem["type"] as? String) == "function_call")
        #expect((callItem["call_id"] as? String) == callID)
        #expect((callItem["name"] as? String) == "recall_memories")
        #expect((callItem["arguments"] as? String) == args)

        let outputItem = input[2]
        #expect((outputItem["type"] as? String) == "function_call_output")
        #expect((outputItem["call_id"] as? String) == callID)

        assertNoInputTextOnAssistantOrToolItems(input)
    }

    @Test
    func `Mixed text and placeholder emits call plus output text`() throws {
        let callID = "call_123"
        let args = #"{"query":"hello"}"#
        let placeholder = ToolInput.placeholderContent(for: [
            ToolInput(toolName: "email.search", argumentsJSON: args, callID: callID)
        ])
        let mixed = "I'll check your email.\n" + placeholder
        let messages = [
            Message(role: .system, content: "You are helpful."),
            Message(role: .user, content: "Find emails about hello"),
            Message(role: .assistant, content: mixed),
            Message(role: .tool, content: #"{"results":[]}"#, toolCallID: callID),
            Message(role: .assistant, content: "Done.")
        ]
        let tools = [
            ToolDefinition(
                name: "email.search",
                description: "Search email",
                parameters: JSONSchema(rawValue: #"{"type":"object"}"#)
            )
        ]
        let body = try openAIResponsesRequestBody(model: "gpt-4o-mini", messages: messages, tools: tools, stream: true)
        let input = try responsesInputItems(from: body)
        try #require(input.count == 6)

        let systemItem = input[0]
        #expect((systemItem["role"] as? String) == "system")
        let systemContent = try #require(systemItem["content"] as? [[String: Any]])
        try #require(!systemContent.isEmpty)
        #expect((systemContent[0]["type"] as? String) == "input_text")

        let callItem = input[2]
        #expect((callItem["type"] as? String) == "function_call")
        #expect((callItem["call_id"] as? String) == callID)
        #expect((callItem["name"] as? String) == "email.search")
        #expect((callItem["arguments"] as? String) == args)

        let textItem = input[3]
        #expect((textItem["role"] as? String) == "assistant")
        let textContent = try #require(textItem["content"] as? [[String: Any]])
        try #require(!textContent.isEmpty)
        #expect((textContent[0]["type"] as? String) == "output_text")
        #expect((textContent[0]["text"] as? String) == "I'll check your email.")

        let outputItem = input[4]
        #expect((outputItem["type"] as? String) == "function_call_output")
        #expect((outputItem["call_id"] as? String) == callID)

        assertNoInputTextOnAssistantOrToolItems(input)
    }

    @Test
    func `Degraded definitions skip broken schemas on both wires`() throws {
        // One corrupt plugin must not fail the turn: bulk builders omit it
        // while direct encoding stays loud for isolated callers.
        let valid = ToolDefinition(
            name: "email.search",
            description: "Search email",
            parameters: JSONSchema(rawValue: #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"],"additionalProperties":false}"#)
        )
        let broken = ToolDefinition(
            name: "broken.tool",
            description: "Corrupt schema",
            parameters: JSONSchema(rawValue: "not-json")
        )
        do {
            _ = try encodeToolParameters(broken)
            Issue.record("encodeToolParameters should throw for corrupt schemas")
        } catch {
            #expect(error is LLMProviderError)
        }
        let filtered = validatedDefinitions([valid, broken])
        #expect(filtered.valid.count == 1)
        #expect(filtered.skipped == ["broken.tool"])
        let messages = [Message(role: .user, content: "Degraded wire check")]
        let chatBody = try openAIChatRequestBody(model: "gpt-4o-mini", messages: messages, tools: [valid, broken], stream: true)
        let chatJSON = try #require(try JSONSerialization.jsonObject(with: chatBody) as? [String: Any])
        let chatTools = try #require(chatJSON["tools"] as? [[String: Any]])
        #expect(chatTools.count == 1)
        let chatName = try #require((chatTools[0]["function"] as? [String: Any])?["name"] as? String)
        #expect(chatName == "email.search")
        let responsesBody = try openAIResponsesRequestBody(model: "gpt-4o-mini", messages: messages, tools: [valid, broken], stream: true)
        let responsesJSON = try #require(try JSONSerialization.jsonObject(with: responsesBody) as? [String: Any])
        let responsesTools = try #require(responsesJSON["tools"] as? [[String: Any]])
        #expect(responsesTools.count == 1)
        #expect((responsesTools[0]["name"] as? String) == "email.search")
        let parameters = try #require(responsesTools[0]["parameters"] as? [String: Any])
        #expect(parameters["type"] as? String == "object")
        #expect(parameters["additionalProperties"] as? Bool == false)
    }

    private func responsesInputItems(from body: Data) throws -> [[String: Any]] {
        let object = try JSONSerialization.jsonObject(with: body)
        let json = try #require(object as? [String: Any])
        return try #require(json["input"] as? [[String: Any]])
    }

    private func assertNoInputTextOnAssistantOrToolItems(_ input: [[String: Any]]) {
        for item in input {
            if (item["role"] as? String) == "assistant",
               let content = item["content"] as? [[String: Any]]
            {
                for part in content {
                    #expect((part["type"] as? String) != "input_text")
                }
            }
            if let type = item["type"] as? String,
               type == "function_call" || type == "function_call_output",
               let content = item["content"] as? [[String: Any]]
            {
                for part in content {
                    #expect((part["type"] as? String) != "input_text")
                }
            }
        }
    }
}

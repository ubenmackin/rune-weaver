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
    func `Chat request body maps assistant placeholder to tool_calls and scrubs content`() throws {
        let callID = "call_abc123"
        let args = #"{"query":"test"}"#
        let placeholder = ToolInput.placeholderContent(for: [
            ToolInput(toolName: "files.glob", argumentsJSON: args, callID: callID)
        ])
        let assistantMessageContent = "Now let me test the files tools.\n\n" + placeholder
        let messages = [
            Message(role: .user, content: "Find files"),
            Message(role: .assistant, content: assistantMessageContent),
            Message(role: .tool, content: #"{"matches":[]}"#, toolCallID: callID)
        ]
        let tools = [
            ToolDefinition(
                name: "files.glob",
                description: "Glob files",
                parameters: JSONSchema(rawValue: #"{"type":"object"}"#)
            )
        ]
        let body = try openAIChatRequestBody(model: "gpt-4o-mini", messages: messages, tools: tools, stream: true)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let wireMessages = try #require(json["messages"] as? [[String: Any]])
        try #require(wireMessages.count == 3)

        let assistantWire = wireMessages[1]
        #expect((assistantWire["role"] as? String) == "assistant")
        #expect((assistantWire["content"] as? String) == "Now let me test the files tools.")

        let toolCalls = try #require(assistantWire["tool_calls"] as? [[String: Any]])
        try #require(toolCalls.count == 1)
        #expect((toolCalls[0]["id"] as? String) == callID)
        #expect((toolCalls[0]["type"] as? String) == "function")
        let function = try #require(toolCalls[0]["function"] as? [String: Any])
        #expect((function["name"] as? String) == "files.glob")
        #expect((function["arguments"] as? String) == args)
    }

    @Test
    func `Chat wire scrubs parked placeholder without tool_calls`() throws {
        // A parked/approval-gated turn persists an assistant note but no tool result
        // until the approval resumes; promoting it to tool_calls would reach the wire
        // as an unmatched call and be rejected. The plumbing line must be scrubbed
        // entirely rather than re-emitted as raw `Calling …` request content.
        let callID = "call_parked_1"
        let args = #"{"action":"send"}"#
        let placeholder = ToolInput.placeholderContent(for: [
            ToolInput(toolName: "email.send", argumentsJSON: args, callID: callID)
        ])
        let messages = [
            Message(role: .user, content: "Send the draft"),
            Message(role: .assistant, content: placeholder),
            Message(role: .assistant, content: "Waiting on your approval.")
        ]
        let tools = [
            ToolDefinition(
                name: "email.send",
                description: "Send email",
                parameters: JSONSchema(rawValue: #"{"type":"object"}"#)
            )
        ]
        let body = try openAIChatRequestBody(model: "gpt-4o-mini", messages: messages, tools: tools, stream: true)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let wireMessages = try #require(json["messages"] as? [[String: Any]])
        try #require(wireMessages.count == 3)

        let parkedWire = wireMessages[1]
        #expect(parkedWire["tool_calls"] == nil)
        #expect((parkedWire["content"] as? String) == "")
        #expect((parkedWire["content"] as? String)?.contains("Calling ") != true)
        // Genuine prose on its own note survives verbatim.
        #expect((wireMessages[2]["content"] as? String) == "Waiting on your approval.")
    }

    @Test
    func `Chat wire promotes answerable calls and scrubs dangling placeholder`() throws {
        // One assistant note can carry several placeholders; only the call whose
        // result is present may become tool_calls, and the dangling line is scrubbed
        // rather than leaking back onto the wire as raw `Calling …` text.
        let answeredID = "call_answered"
        let danglingID = "call_parked"
        let placeholder = ToolInput.placeholderContent(for: [
            ToolInput(toolName: "email.search", argumentsJSON: #"{"query":"hello"}"#, callID: answeredID),
            ToolInput(toolName: "email.send", argumentsJSON: #"{"to":"a@b.c"}"#, callID: danglingID)
        ])
        let messages = [
            Message(role: .user, content: "Search then send"),
            Message(role: .assistant, content: placeholder),
            Message(role: .tool, content: #"{"results":[]}"#, toolCallID: answeredID)
        ]
        let tools = [
            ToolDefinition(
                name: "email.search",
                description: "Search email",
                parameters: JSONSchema(rawValue: #"{"type":"object"}"#)
            ),
            ToolDefinition(
                name: "email.send",
                description: "Send email",
                parameters: JSONSchema(rawValue: #"{"type":"object"}"#)
            )
        ]
        let body = try openAIChatRequestBody(model: "gpt-4o-mini", messages: messages, tools: tools, stream: true)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let wireMessages = try #require(json["messages"] as? [[String: Any]])
        try #require(wireMessages.count == 3)

        let assistantWire = wireMessages[1]
        let toolCalls = try #require(assistantWire["tool_calls"] as? [[String: Any]])
        try #require(toolCalls.count == 1)
        #expect((toolCalls[0]["id"] as? String) == answeredID)
        let content = try #require(assistantWire["content"] as? String)
        #expect(!content.contains(danglingID))
        #expect(!content.contains("Calling "))
        #expect(!content.contains(answeredID))
    }

    @Test
    func `Responses wire scrubs parked placeholder without function_call`() throws {
        // Same parked hazard on the responses wire: an unpaired function_call item is
        // rejected, so the plumbing line is scrubbed entirely and never re-emitted as
        // assistant output text.
        let callID = "call_parked_2"
        let args = #"{"action":"send"}"#
        let placeholder = ToolInput.placeholderContent(for: [
            ToolInput(toolName: "email.send", argumentsJSON: args, callID: callID)
        ])
        let messages = [
            Message(role: .user, content: "Send the draft"),
            Message(role: .assistant, content: placeholder)
        ]
        let tools = [
            ToolDefinition(
                name: "email.send",
                description: "Send email",
                parameters: JSONSchema(rawValue: #"{"type":"object"}"#)
            )
        ]
        let body = try openAIResponsesRequestBody(model: "gpt-4o-mini", messages: messages, tools: tools, stream: true)
        let input = try responsesInputItems(from: body)
        // An all-plumbing note contributes nothing beyond the user turn.
        try #require(input.count == 1)
        #expect((input[0]["role"] as? String) == "user")
        #expect(input.allSatisfy { ($0["type"] as? String) != "function_call" })
        assertNoCallingText(input)
    }

    @Test
    func `Mixed prose and dangling placeholder keeps only real prose on both wires`() throws {
        // A parked note can mix genuine prose with a gated placeholder. The prose
        // survives verbatim on both wires while the plumbing line is scrubbed.
        let danglingID = "call_parked_mixed"
        let placeholder = ToolInput.placeholderContent(for: [
            ToolInput(toolName: "email.send", argumentsJSON: #"{"action":"send"}"#, callID: danglingID)
        ])
        let prose = "I'll send that once you approve."
        let mixed = prose + "\n" + placeholder
        let messages = [
            Message(role: .user, content: "Send the draft"),
            Message(role: .assistant, content: mixed)
        ]
        let tools = [
            ToolDefinition(
                name: "email.send",
                description: "Send email",
                parameters: JSONSchema(rawValue: #"{"type":"object"}"#)
            )
        ]

        let chatBody = try openAIChatRequestBody(model: "gpt-4o-mini", messages: messages, tools: tools, stream: true)
        let chatJSON = try #require(try JSONSerialization.jsonObject(with: chatBody) as? [String: Any])
        let chatMessages = try #require(chatJSON["messages"] as? [[String: Any]])
        let assistantWire = try #require(chatMessages.first { ($0["role"] as? String) == "assistant" })
        #expect(assistantWire["tool_calls"] == nil)
        #expect((assistantWire["content"] as? String) == prose)

        let responsesBody = try openAIResponsesRequestBody(model: "gpt-4o-mini", messages: messages, tools: tools, stream: true)
        let input = try responsesInputItems(from: responsesBody)
        let assistantItem = try #require(input.first { ($0["role"] as? String) == "assistant" })
        let assistantContent = try #require(assistantItem["content"] as? [[String: Any]])
        try #require(!assistantContent.isEmpty)
        #expect((assistantContent[0]["text"] as? String) == prose)
        #expect(input.allSatisfy { ($0["type"] as? String) != "function_call" })
        assertNoCallingText(input)
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

    @Test
    func `Sorted keys serialization is byte identical and deterministic`() throws {
        let messages = [
            Message(role: .system, content: "System instructions"),
            Message(role: .user, content: "Hello world")
        ]
        let tool = ToolDefinition(
            name: "sample.tool",
            description: "Sample tool for deterministic sorting check",
            parameters: JSONSchema(rawValue: """
            {
                "type": "object",
                "properties": {
                    "zebra": { "type": "string", "description": "Zebra param" },
                    "alpha": { "type": "number", "description": "Alpha param" },
                    "beta": { "type": "boolean", "description": "Beta param" }
                },
                "required": ["alpha", "beta"],
                "additionalProperties": false
            }
            """)
        )
        // Repeat multiple times to ensure Swift hash randomization across invocations never changes wire bytes
        let chatBytes1 = try openAIChatRequestBody(model: "local-model", messages: messages, tools: [tool], stream: true, cachePrompt: true, slotID: 2)
        let chatBytes2 = try openAIChatRequestBody(model: "local-model", messages: messages, tools: [tool], stream: true, cachePrompt: true, slotID: 2)
        #expect(chatBytes1 == chatBytes2)

        let chatString = try #require(String(data: chatBytes1, encoding: .utf8))
        // Verify key ordering in wire JSON: "alpha" must appear before "beta", which must appear before "zebra"
        let alphaRange = try #require(chatString.range(of: "\"alpha\""))
        let betaRange = try #require(chatString.range(of: "\"beta\""))
        let zebraRange = try #require(chatString.range(of: "\"zebra\""))
        #expect(alphaRange.lowerBound < betaRange.lowerBound)
        #expect(betaRange.lowerBound < zebraRange.lowerBound)

        let responsesBytes1 = try openAIResponsesRequestBody(model: "local-model", messages: messages, tools: [tool], stream: true)
        let responsesBytes2 = try openAIResponsesRequestBody(model: "local-model", messages: messages, tools: [tool], stream: true)
        #expect(responsesBytes1 == responsesBytes2)
    }

    @Test
    func `Duplicate placeholder lines collapse to one wire call on both wires`() throws {
        // Narration persisted the placeholder line beside its generated twin; neither
        // wire may emit two calls for one identifier or leak the twin back as text.
        let callID = "call_twin_1"
        let args = #"{"query":"hello"}"#
        let line = ToolInput.placeholderContent(for: [
            ToolInput(toolName: "email.search", argumentsJSON: args, callID: callID)
        ])
        let duplicated = line + "\n" + line
        let messages = [
            Message(role: .user, content: "Find emails"),
            Message(role: .assistant, content: duplicated),
            Message(role: .tool, content: #"{"results":[]}"#, toolCallID: callID)
        ]
        let tools = [
            ToolDefinition(
                name: "email.search",
                description: "Search email",
                parameters: JSONSchema(rawValue: #"{"type":"object"}"#)
            )
        ]

        let chatBody = try openAIChatRequestBody(model: "gpt-4o-mini", messages: messages, tools: tools, stream: true)
        let chatJSON = try #require(try JSONSerialization.jsonObject(with: chatBody) as? [String: Any])
        let chatMessages = try #require(chatJSON["messages"] as? [[String: Any]])
        let chatCalls = chatMessages.flatMap { ($0["tool_calls"] as? [[String: Any]]) ?? [] }
        #expect(chatCalls.count == 1)
        #expect((chatCalls[0]["id"] as? String) == callID)
        let chatToolEntries = chatMessages.filter { ($0["role"] as? String) == "tool" }
        #expect(chatToolEntries.count == 1)
        #expect((chatToolEntries[0]["tool_call_id"] as? String) == callID)
        let assistantEntry = try #require(chatMessages.first { ($0["role"] as? String) == "assistant" })
        #expect((assistantEntry["content"] as? String) == "")

        let responsesBody = try openAIResponsesRequestBody(model: "gpt-4o-mini", messages: messages, tools: tools, stream: true)
        let input = try responsesInputItems(from: responsesBody)
        let calls = input.filter { ($0["type"] as? String) == "function_call" }
        let outputs = input.filter { ($0["type"] as? String) == "function_call_output" }
        #expect(calls.count == 1)
        #expect((calls[0]["call_id"] as? String) == callID)
        #expect(outputs.count == 1)
        #expect((outputs[0]["call_id"] as? String) == callID)
    }

    @Test
    func `Call ID repeated across assistant notes emits once per wire`() throws {
        // A call identifier answers exactly one invocation, so a re-persisted note
        // must not reach the wire twice beside its single result.
        let callID = "call_repeat_1"
        let line = ToolInput.placeholderContent(for: [
            ToolInput(toolName: "email.search", argumentsJSON: #"{"query":"hello"}"#, callID: callID)
        ])
        let messages = [
            Message(role: .user, content: "Find emails"),
            Message(role: .assistant, content: line),
            Message(role: .assistant, content: line),
            Message(role: .tool, content: #"{"results":[]}"#, toolCallID: callID)
        ]
        let tools = [
            ToolDefinition(
                name: "email.search",
                description: "Search email",
                parameters: JSONSchema(rawValue: #"{"type":"object"}"#)
            )
        ]

        let chatBody = try openAIChatRequestBody(model: "gpt-4o-mini", messages: messages, tools: tools, stream: true)
        let chatJSON = try #require(try JSONSerialization.jsonObject(with: chatBody) as? [String: Any])
        let chatMessages = try #require(chatJSON["messages"] as? [[String: Any]])
        let chatCallIDs = chatMessages
            .flatMap { ($0["tool_calls"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["id"] as? String }
        #expect(chatCallIDs == [callID])
        let chatToolIDs = chatMessages
            .filter { ($0["role"] as? String) == "tool" }
            .compactMap { $0["tool_call_id"] as? String }
        #expect(chatToolIDs == [callID])

        let responsesBody = try openAIResponsesRequestBody(model: "gpt-4o-mini", messages: messages, tools: tools, stream: true)
        let input = try responsesInputItems(from: responsesBody)
        let callIDs = input
            .filter { ($0["type"] as? String) == "function_call" }
            .compactMap { $0["call_id"] as? String }
        let outputIDs = input
            .filter { ($0["type"] as? String) == "function_call_output" }
            .compactMap { $0["call_id"] as? String }
        #expect(callIDs == [callID])
        #expect(outputIDs == [callID])
        // The second assistant note contributes no leaked `Calling …` text item.
        for item in input where (item["role"] as? String) == "assistant" {
            let content = (item["content"] as? [[String: Any]]) ?? []
            for part in content {
                #expect((part["text"] as? String)?.contains("Calling ") != true)
            }
        }
    }

    private func responsesInputItems(from body: Data) throws -> [[String: Any]] {
        let object = try JSONSerialization.jsonObject(with: body)
        let json = try #require(object as? [String: Any])
        return try #require(json["input"] as? [[String: Any]])
    }

    /// Asserts no emitted item carries raw `Calling …` placeholder plumbing as text.
    private func assertNoCallingText(_ input: [[String: Any]]) {
        for item in input {
            let content = (item["content"] as? [[String: Any]]) ?? []
            for part in content {
                #expect((part["text"] as? String)?.contains("Calling ") != true)
            }
            if let text = item["output"] as? String {
                #expect(!text.contains("Calling "))
            }
        }
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

// Rune Weaver Core Tests — Context token tracking and occupancy reporting.

import Foundation
import os
@testable import RuneWeaverCore
import Testing

/// Fixture tool with a defined name, description, and schema.
private struct FixtureTrackingTool: Tool, Sendable {
    let name: String
    let description: String
    let schemaJSON: String
    let permissionLevel = PermissionLevel.readOnly

    var inputSchema: JSONSchema {
        JSONSchema(rawValue: schemaJSON)
    }

    func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        .success("Executed \(input.toolName)", callID: input.callID)
    }
}

/// Scripted turn for mock LLM.
private struct TrackingScriptedTurn: Sendable {
    let text: String
    let toolCalls: [ToolInput]
    let totalTokens: Int?

    init(text: String, toolCalls: [ToolInput] = [], totalTokens: Int? = nil) {
        self.text = text
        self.toolCalls = toolCalls
        self.totalTokens = totalTokens
    }
}

/// Scripted mock LLM provider.
private final class TrackingScriptedLLM: LLMProvider, Sendable {
    let modelInfo = ModelInfo(
        name: "test-llm",
        provider: "mock",
        contextLength: 128_000,
        supportsTools: true,
        supportsEmbeddings: false,
        supportsVision: false
    )

    private struct State {
        var turns: [TrackingScriptedTurn]
        var index: Int
    }

    private let state: OSAllocatedUnfairLock<State>

    init(turns: [TrackingScriptedTurn]) {
        self.state = OSAllocatedUnfairLock(initialState: State(turns: turns, index: 0))
    }

    func chat(messages _: [Message], tools _: [any Tool]) -> AsyncStream<LLMResponse> {
        let turn: TrackingScriptedTurn? = state.withLock { s in
            guard s.index < s.turns.count else { return nil }
            let next = s.turns[s.index]
            s.index += 1
            return next
        }
        guard let turn else {
            return AsyncStream { continuation in
                continuation.yield(LLMResponse(delta: "", isFinished: true))
                continuation.finish()
            }
        }
        return AsyncStream { continuation in
            continuation.yield(LLMResponse(
                delta: turn.text,
                isFinished: true,
                totalTokens: turn.totalTokens,
                toolCalls: turn.toolCalls
            ))
            continuation.finish()
        }
    }

    func embeddings(text: [String]) async throws -> [[Float]] {
        Array(repeating: [Float](), count: text.count)
    }
}

@Suite("Context Token Tracking")
struct ContextTokenTrackingTests {
    @Test
    func `estimateToolTokens calculates token overhead from tool definitions`() {
        let empty = ConversationManager.estimateToolTokens(in: [])
        #expect(empty == 0)

        let tool1 = FixtureTrackingTool(
            name: "email.search",
            description: "Search user inbox",
            schemaJSON: #"{"type":"object","properties":{"query":{"type":"string"}}}"#
        )
        // name (12) + desc (17) + schema (58) + 50 = 137 chars.
        // 137 / 4.0 = 34.25 -> 35 tokens.
        let tokens = ConversationManager.estimateToolTokens(in: [tool1])
        #expect(tokens > 0)
        #expect(tokens == 35)
    }

    @Test
    func `compactHistoryIfNeeded respects reserved tool tokens`() async {
        let manager = ConversationManager()
        let sessionID = UUID()

        for i in 1 ... 4 {
            await manager.append(Message(role: .user, content: "Request \(i) with some padding text to fill bytes."), to: sessionID)
            await manager.append(Message(role: .assistant, content: "Reply \(i) with additional padding text for budget."), to: sessionID)
        }

        // Without reserved tokens, contextLength 500 @ 80% = 400 max allowed tokens.
        // Total chars ~400 => ~100 tokens, which is well within 400.
        let compactedWithoutReserve = await manager.compactHistoryIfNeeded(
            for: sessionID,
            contextLength: 500,
            thresholdPercent: 80,
            reservedTokens: 0
        )
        #expect(!compactedWithoutReserve)

        // With 400 reserved tokens, effective contextLength = max(100, 500 - 400) = 100.
        // 100 @ 80% = max 100 allowed tokens.
        // Add more messages so tokens exceed 100.
        for i in 5 ... 8 {
            await manager.append(Message(role: .user, content: "Extra Request \(i) with even more padding text for bytes."), to: sessionID)
            await manager.append(Message(role: .assistant, content: "Extra Reply \(i) with even more padding text for budget."), to: sessionID)
        }

        let compactedWithReserve = await manager.compactHistoryIfNeeded(
            for: sessionID,
            contextLength: 500,
            thresholdPercent: 80,
            reservedTokens: 400
        )
        #expect(compactedWithReserve)
    }

    @Test
    func `Multi-round turn emits actual round tokens as contextTokens and accumulates turnTotalTokens`() async throws {
        let tool = FixtureTrackingTool(
            name: "email.search",
            description: "Search email",
            schemaJSON: #"{"type":"object"}"#
        )
        let toolBus = ToolBus()
        await toolBus.register(tool: tool)

        // Scripted: Round 1 requests tool (9,012 tokens), Round 2 finishes with final text (11,709 tokens).
        let provider = TrackingScriptedLLM(turns: [
            TrackingScriptedTurn(
                text: "Searching...",
                toolCalls: [ToolInput(toolName: "email.search", argumentsJSON: "{}")],
                totalTokens: 9012
            ),
            TrackingScriptedTurn(
                text: "Here is your summary.",
                totalTokens: 11709
            )
        ])

        let conversations = ConversationManager()
        let sessionID = UUID()
        let orchestrator = Orchestrator(
            conversations: conversations,
            toolBus: toolBus,
            llm: provider,
            systemPrompt: "You are a helpful assistant."
        )

        let capturedEvents = OSAllocatedUnfairLock(initialState: [(roundIndex: Int, roundTokens: Int, turnTotalTokens: Int, contextTokens: Int?)]())

        let response = try await orchestrator.process(
            input: UserInput(text: "Find my emails", sessionID: sessionID),
            onEvent: { event in
                if case let .turnTokens(roundIndex, roundTokens, turnTotalTokens, contextTokens) = event {
                    capturedEvents.withLock {
                        $0.append((roundIndex, roundTokens, turnTotalTokens, contextTokens))
                    }
                }
            }
        )

        let events = capturedEvents.withLock { $0 }
        #expect(events.count == 2)

        // Round 1 event: roundTokens == 9012, turnTotalTokens == 9012, contextTokens == 9012
        #expect(events[0].roundIndex == 0)
        #expect(events[0].roundTokens == 9012)
        #expect(events[0].turnTotalTokens == 9012)
        #expect(events[0].contextTokens == 9012)

        // Round 2 event: roundTokens == 11709, turnTotalTokens == 9012 + 11709 = 20721, contextTokens == 11709
        #expect(events[1].roundIndex == 1)
        #expect(events[1].roundTokens == 11709)
        #expect(events[1].turnTotalTokens == 20721)
        #expect(events[1].contextTokens == 11709)

        // Final response carries cumulative totalTokens (20721) and latest active contextTokens (11709)
        #expect(response.totalTokens == 20721)
        #expect(response.contextTokens == 11709)
        #expect(response.text == "Here is your summary.")
    }

    @Test
    func `Fallback context estimation includes registered tool overhead when LLM omits usage`() async throws {
        let tool = FixtureTrackingTool(
            name: "email.search",
            description: "Search email with detailed instructions and documentation",
            schemaJSON: #"{"type":"object","properties":{"folder":{"type":"string"}}}"#
        )
        let toolBus = ToolBus()
        await toolBus.register(tool: tool)

        // Provider yields text but omits totalTokens (nil usage)
        let provider = TrackingScriptedLLM(turns: [
            TrackingScriptedTurn(text: "Done without usage reporting.", totalTokens: nil)
        ])

        let conversations = ConversationManager()
        let sessionID = UUID()
        let orchestrator = Orchestrator(
            conversations: conversations,
            toolBus: toolBus,
            llm: provider,
            systemPrompt: "You are a helpful assistant."
        )

        let response = try await orchestrator.process(
            input: UserInput(text: "Hello", sessionID: sessionID)
        )

        // Provider reported nil tokens, so totalTokens is nil
        #expect(response.totalTokens == nil)
        // contextTokens must have fallen back to estimated tokens including tools
        let contextTokens = try #require(response.contextTokens)
        let toolTokens = ConversationManager.estimateToolTokens(in: [tool])
        #expect(toolTokens > 0)
        // Context tokens must exceed the tool tokens alone because of messages
        #expect(contextTokens > toolTokens)
    }

    @Test
    func `First user message automatically sets session title in ConversationManager`() async throws {
        let manager = ConversationManager()
        let sessionID = UUID()

        await manager.append(Message(role: .user, content: "Summarize the financial quarterly reports for Q3"), to: sessionID)

        let session = await manager.session(id: sessionID)
        let title = try #require(session?.title)
        #expect(title == "Summarize the financial quarterly report…")
        #expect(session?.displayTitle == title)
    }
}

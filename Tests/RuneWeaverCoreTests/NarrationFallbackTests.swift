// RuneWeaver - Tests - Narration fallback
import Foundation
@testable import RuneWeaverCore
import Testing

/// Fixture tool with a configurable permission level for fallback tests.
///
/// Read-only instances prove narrated placeholders execute, while
/// approval-gated instances prove the fallback leaves them unexecuted
/// even when the bus would otherwise allow them.
private struct FixtureNarrationTool: Tool, Sendable {
    /// Registered tool name.
    let name: String
    /// Canned outcome text.
    let output: String
    /// Permission level under test.
    let permissionLevel: PermissionLevel
    /// Human-readable description.
    var description: String {
        "Fixture stub for \(name)."
    }

    /// Empty-object schema.
    let inputSchema = JSONSchema(rawValue: #"{"type":"object"}"#)

    /// Returns the canned outcome.
    /// - Parameters:
    ///   - input: Invocation arguments.
    ///   - context: Ambient execution context.
    /// - Returns: Canned success output echoing the call identifier.
    func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        .success(output, callID: input.callID)
    }
}

/// Scripted provider replaying canned texts in call order.
///
/// Each `chat` call consumes the next entry so the orchestrator observes
/// a narrated turn followed by a final synthesis turn without inference.
/// Access is lock-guarded for Swift 6 data-race safety.
private final class ScriptedNarrationLLM: LLMProvider, @unchecked Sendable {
    /// Stable test model metadata.
    let modelInfo = ModelInfo(name: "fixture", provider: "test", contextLength: 8192)
    /// Guards script state below.
    private let lock = NSLock()
    /// Canned texts in call order.
    private var texts: [String]
    /// Next script index.
    private var index = 0

    /// Creates a scripted provider.
    /// - Parameter texts: Canned texts in call order.
    init(texts: [String]) {
        self.texts = texts
    }

    /// Replays the next canned text as a finished stream.
    /// - Parameters:
    ///   - messages: Ignored conversation history.
    ///   - tools: Ignored available tools.
    /// - Returns: Stream yielding one finished chunk.
    func chat(messages _: [Message], tools _: [any Tool]) -> AsyncStream<LLMResponse> {
        let text: String = {
            lock.lock()
            defer { lock.unlock() }
            let next = index < texts.count ? texts[index] : texts.last ?? ""
            index += 1
            return next
        }()
        return AsyncStream { continuation in
            continuation.yield(LLMResponse(delta: text, isFinished: true))
            continuation.finish()
        }
    }

    /// Unused embeddings stub.
    /// - Parameter text: Ignored texts.
    /// - Returns: Empty vectors.
    func embeddings(text _: [String]) async throws -> [[Float]] {
        []
    }
}

/// Builds a read-only fixture tool.
/// - Parameters:
///   - name: Registered tool name.
///   - output: Canned outcome text.
/// - Returns: Read-only stub tool.
private func makeNarrationReadTool(name: String, output: String) -> FixtureNarrationTool {
    FixtureNarrationTool(name: name, output: output, permissionLevel: .readOnly)
}

@Suite("Narration Fallback")
struct NarrationFallbackTests {
    @Test
    func `Single narrated placeholder converts with fresh call ID`() {
        let tool = makeNarrationReadTool(name: "email.search", output: "ok")
        let args = #"{"query":"lighthouse"}"#
        let narratedID = "call_narrated_001"
        let text = ToolInput.placeholderContent(for: [
            ToolInput(toolName: "email.search", argumentsJSON: args, callID: narratedID)
        ])
        let calls = OrchestratorToolLoop.narratedToolCalls(from: text, tools: [tool])
        #expect(calls.count == 1)
        #expect(calls.first?.toolName == "email.search")
        #expect(calls.first?.argumentsJSON == args)
        let freshID = calls.first?.callID ?? ""
        #expect(!freshID.isEmpty)
        #expect(freshID != narratedID)
    }

    @Test
    func `Multiple narrated placeholders convert in order`() {
        let search = makeNarrationReadTool(name: "email.search", output: "found")
        let calendar = makeNarrationReadTool(name: "calendar.list", output: "empty")
        let searchArgs = #"{"query":"lighthouse"}"#
        let calendarArgs = #"{"date":"tomorrow"}"#
        let text = ToolInput.placeholderContent(for: [
            ToolInput(toolName: "email.search", argumentsJSON: searchArgs, callID: "call_narrated_aaa"),
            ToolInput(toolName: "calendar.list", argumentsJSON: calendarArgs, callID: "call_narrated_bbb")
        ])
        let calls = OrchestratorToolLoop.narratedToolCalls(from: text, tools: [search, calendar])
        #expect(calls.count == 2)
        #expect(calls.map(\.toolName) == ["email.search", "calendar.list"])
        #expect(calls[0].argumentsJSON == searchArgs)
        #expect(calls[1].argumentsJSON == calendarArgs)
        #expect(calls[0].callID != "call_narrated_aaa")
        #expect(calls[1].callID != "call_narrated_bbb")
        #expect(calls[0].callID != calls[1].callID)
    }

    @Test
    func `Hallucinated argument JSON never converts`() {
        let tool = makeNarrationReadTool(name: "email.search", output: "ok")
        let badLines = [
            "Calling email.search {not json} [call_bad_001]",
            "Calling email.search {\"query\":} [call_bad_002]",
            "Calling email.search truncated… [call_bad_004]",
            "I will check email.search tomorrow."
        ]
        for line in badLines {
            #expect(
                OrchestratorToolLoop.narratedToolCalls(from: line, tools: [tool]).isEmpty,
                "Line must not convert: \(line)"
            )
        }
        let mixed = "Let me look.\nCalling email.search {oops} [call_bad_005]\nDone."
        #expect(OrchestratorToolLoop.narratedToolCalls(from: mixed, tools: [tool]).isEmpty)
    }

    @Test
    func `Approval-gated tools never convert`() {
        let read = makeNarrationReadTool(name: "email.search", output: "ok")
        let approval = FixtureNarrationTool(
            name: "stub.write",
            output: "wrote",
            permissionLevel: .requiresApproval
        )
        let trusted = FixtureNarrationTool(
            name: "memory.write",
            output: "stored",
            permissionLevel: .trusted
        )
        let tools: [any Tool] = [read, approval, trusted]
        let approvalText = ToolInput.placeholderContent(for: [
            ToolInput(toolName: "stub.write", argumentsJSON: #"{"text":"hi"}"#, callID: "call_narrated_write")
        ])
        #expect(OrchestratorToolLoop.narratedToolCalls(from: approvalText, tools: tools).isEmpty)
        let trustedText = ToolInput.placeholderContent(for: [
            ToolInput(toolName: "memory.write", argumentsJSON: #"{"text":"hi"}"#, callID: "call_narrated_trusted")
        ])
        #expect(OrchestratorToolLoop.narratedToolCalls(from: trustedText, tools: tools).isEmpty)
        let unknownText = ToolInput.placeholderContent(for: [
            ToolInput(toolName: "missing.tool", argumentsJSON: #"{"query":"x"}"#, callID: "call_narrated_missing")
        ])
        #expect(OrchestratorToolLoop.narratedToolCalls(from: unknownText, tools: tools).isEmpty)
    }

    @Test
    func `Orchestrator executes single narrated read-only call`() async throws {
        let conversations = ConversationManager()
        let bus = ToolBus()
        await bus.register(tool: makeNarrationReadTool(
            name: "email.search",
            output: "Found 2 emails about the lighthouse"
        ))
        let args = #"{"query":"lighthouse"}"#
        let narratedID = "call_narrated_single"
        let narrated = ToolInput.placeholderContent(for: [
            ToolInput(toolName: "email.search", argumentsJSON: args, callID: narratedID)
        ])
        let finalText = "Done: found your lighthouse emails."
        let llm = ScriptedNarrationLLM(texts: [narrated, finalText])
        let resolver: OrchestratorToolResolver = { _, _ in [] }
        let orchestrator = Orchestrator(
            conversations: conversations,
            toolBus: bus,
            llm: llm,
            toolResolver: resolver
        )
        let sessionID = UUID()
        let response = try await orchestrator.process(input: UserInput(text: "Find lighthouse email", sessionID: sessionID))
        #expect(response.text == finalText)
        #expect(response.toolActions.count == 1)
        #expect(response.toolActions.first?.toolName == "email.search")
        #expect(response.toolActions.first?.argumentsJSON == args)
        #expect(response.toolActions.first?.result?.isError == false)
        #expect(response.toolActions.first?.result?.content.contains("lighthouse") == true)
        let executedID = response.toolActions.first?.callID ?? ""
        #expect(!executedID.isEmpty)
        #expect(executedID != narratedID)
        let history = await conversations.history(for: sessionID)
        #expect(history.contains { $0.role == .tool && $0.toolCallID == executedID })
        #expect(!history.contains { $0.role == .tool && $0.toolCallID == narratedID })
    }

    @Test
    func `Orchestrator executes multiple narrated calls in one turn`() async throws {
        let conversations = ConversationManager()
        let bus = ToolBus()
        await bus.register(tool: makeNarrationReadTool(
            name: "email.search",
            output: "Found lighthouse email"
        ))
        await bus.register(tool: makeNarrationReadTool(
            name: "calendar.list",
            output: "No events tomorrow"
        ))
        let narrated = ToolInput.placeholderContent(for: [
            ToolInput(toolName: "email.search", argumentsJSON: #"{"query":"lighthouse"}"#, callID: "call_narrated_one"),
            ToolInput(toolName: "calendar.list", argumentsJSON: #"{"date":"tomorrow"}"#, callID: "call_narrated_two")
        ])
        let finalText = "Done: checked both sources."
        let llm = ScriptedNarrationLLM(texts: [narrated, finalText])
        let resolver: OrchestratorToolResolver = { _, _ in [] }
        let orchestrator = Orchestrator(
            conversations: conversations,
            toolBus: bus,
            llm: llm,
            toolResolver: resolver
        )
        let response = try await orchestrator.process(input: UserInput(text: "Check both", sessionID: UUID()))
        #expect(response.text == finalText)
        #expect(response.toolActions.count == 2)
        #expect(response.toolActions.map(\.toolName) == ["email.search", "calendar.list"])
        #expect(!response.toolActions.map(\.callID).contains("call_narrated_one"))
        #expect(!response.toolActions.map(\.callID).contains("call_narrated_two"))
    }

    @Test
    func `Orchestrator leaves hallucinated JSON unexecuted`() async throws {
        let conversations = ConversationManager()
        let bus = ToolBus()
        await bus.register(tool: makeNarrationReadTool(
            name: "email.search",
            output: "Found lighthouse email"
        ))
        let narrated = "Calling email.search {not json} [call_bad_json]"
        let llm = ScriptedNarrationLLM(texts: [narrated])
        let resolver: OrchestratorToolResolver = { _, _ in [] }
        let orchestrator = Orchestrator(
            conversations: conversations,
            toolBus: bus,
            llm: llm,
            toolResolver: resolver
        )
        let response = try await orchestrator.process(input: UserInput(text: "Find it", sessionID: UUID()))
        #expect(response.toolActions.isEmpty)
        #expect(response.text == narrated)
    }

    @Test
    func `Orchestrator leaves approval-gated narration unexecuted`() async throws {
        let conversations = ConversationManager()
        let bus = ToolBus(permissionGate: PermissionGate())
        await bus.register(tool: makeNarrationReadTool(
            name: "email.search",
            output: "Found lighthouse email"
        ))
        await bus.register(tool: FixtureNarrationTool(
            name: "stub.write",
            output: "wrote",
            permissionLevel: .requiresApproval
        ))
        // An allowing handler proves the fallback filter, not the bus denial,
        // is what keeps the approval-gated narration unexecuted.
        await bus.setApprovalHandler { _, _ in true }
        let narrated = ToolInput.placeholderContent(for: [
            ToolInput(toolName: "stub.write", argumentsJSON: #"{"text":"hi"}"#, callID: "call_narrated_gated")
        ])
        let llm = ScriptedNarrationLLM(texts: [narrated])
        let resolver: OrchestratorToolResolver = { _, _ in [] }
        let orchestrator = Orchestrator(
            conversations: conversations,
            toolBus: bus,
            llm: llm,
            toolResolver: resolver
        )
        let sessionID = UUID()
        let response = try await orchestrator.process(input: UserInput(text: "Write it", sessionID: sessionID))
        #expect(response.toolActions.isEmpty)
        #expect(response.text == narrated)
        let history = await conversations.history(for: sessionID)
        #expect(!history.contains { $0.role == .tool })
    }
}

// Rune Weaver Tests — Narrated gated approvals with resume continuation.
//
// Covers the parked-approval contract for local-model narration: gated
// `Calling ... [...]` lines file a session-tagged queue request and end
// parked waiting on approval, an allow resumes by executing the filed call
// plus a synthesis turn in the same session, a deny notifies that session
// without executing, and read-only narration still runs directly.

import Foundation
@testable import RuneWeaverCore
import Testing

/// Fixture tool with a configurable permission level for parked-approval tests.
///
/// Read-only instances prove direct execution still holds with a queue
/// configured, while approval-gated instances prove filing plus resume
/// without ever running inline.
private struct ParkedApprovalTool: Tool, Sendable {
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
/// Each `chat` call consumes the next entry so the orchestrator observes a
/// narrated turn followed by a synthesis turn without inference. Lock-guarded
/// for Swift 6 data-race safety across the parked turn and its resume.
private final class ParkedApprovalLLM: LLMProvider, @unchecked Sendable {
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
private func makeParkedReadTool(name: String, output: String) -> ParkedApprovalTool {
    ParkedApprovalTool(name: name, output: output, permissionLevel: .readOnly)
}

/// Builds an approval-gated fixture tool.
/// - Parameters:
///   - name: Registered tool name.
///   - output: Canned outcome text.
/// - Returns: Gated stub tool.
private func makeParkedGatedTool(name: String, output: String) -> ParkedApprovalTool {
    ParkedApprovalTool(name: name, output: output, permissionLevel: .requiresApproval)
}

@Suite("Narrated Gated Approvals")
struct NarratedApprovalTests {
    @Test
    func `Narrated gated call files a session-tagged approval and parks`() async throws {
        let conversations = ConversationManager()
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let bus = ToolBus(permissionGate: gate)
        await bus.register(tool: makeParkedGatedTool(name: "stub.write", output: "write-ok"))
        let args = #"{"text":"hi"}"#
        let narrated = ToolInput.placeholderContent(for: [
            ToolInput(toolName: "stub.write", argumentsJSON: args, callID: "call_narrated_gated")
        ])
        let llm = ParkedApprovalLLM(texts: [narrated])
        let orchestrator = Orchestrator(
            conversations: conversations,
            toolBus: bus,
            llm: llm,
            toolResolver: { _, _ in [] },
            approvalQueue: queue
        )
        let sessionID = UUID()
        let response = try await orchestrator.process(input: UserInput(text: "Write it", sessionID: sessionID))
        #expect(await queue.count() == 1)
        let pending = await queue.list().first
        #expect(pending?.toolName == "stub.write")
        #expect(pending?.input.argumentsJSON == args)
        #expect(pending?.sessionID == sessionID)
        #expect(response.sessionID == sessionID)
        #expect(response.toolActions.count == 1)
        #expect(response.toolActions.first?.toolName == "stub.write")
        #expect(response.toolActions.first?.result == nil)
        #expect(response.text.lowercased().contains("approval"))
        #expect(response.text.contains("stub.write"))
        let history = await conversations.history(for: sessionID)
        #expect(history.contains { $0.role == .assistant && $0.content.lowercased().contains("waiting") })
        #expect(!history.contains { $0.role == .tool })
    }

    @Test
    func `Allowed gated narration resumes with execution plus synthesis`() async throws {
        let conversations = ConversationManager()
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let bus = ToolBus(permissionGate: gate)
        await bus.register(tool: makeParkedGatedTool(name: "stub.write", output: "write-ok done"))
        let args = #"{"text":"hello"}"#
        let narrated = ToolInput.placeholderContent(for: [
            ToolInput(toolName: "stub.write", argumentsJSON: args, callID: "call_narrated_allow")
        ])
        let synthesis = "Done: wrote your note."
        let llm = ParkedApprovalLLM(texts: [narrated, synthesis])
        let orchestrator = Orchestrator(
            conversations: conversations,
            toolBus: bus,
            llm: llm,
            toolResolver: { _, _ in [] },
            approvalQueue: queue
        )
        let sessionID = UUID()
        let parked = try await orchestrator.process(input: UserInput(text: "Write it", sessionID: sessionID))
        #expect(parked.text.lowercased().contains("approval"))
        let pending = await queue.list().first
        #expect(pending != nil)
        guard let approvalID = pending?.id else {
            Issue.record("Expected a filed gated approval")
            return
        }
        #expect(await queue.decide(id: approvalID, approved: true) == true)
        let resumed = try await orchestrator.resumeNarratedApproval(id: approvalID, approved: true)
        #expect(resumed?.sessionID == sessionID)
        #expect(resumed?.text == synthesis)
        #expect(resumed?.toolActions.count == 1)
        #expect(resumed?.toolActions.first?.toolName == "stub.write")
        #expect(resumed?.toolActions.first?.argumentsJSON == args)
        #expect(resumed?.toolActions.first?.result?.isError == false)
        #expect(resumed?.toolActions.first?.result?.content.contains("write-ok") == true)
        let history = await conversations.history(for: sessionID)
        let filedCallID = resumed?.toolActions.first?.callID ?? ""
        #expect(!filedCallID.isEmpty)
        #expect(history.contains { $0.role == .tool && $0.toolCallID == filedCallID })
        #expect(history.contains { $0.role == .assistant && $0.content == synthesis })
    }

    @Test
    func `Denied gated narration notifies the session without executing`() async throws {
        let conversations = ConversationManager()
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let bus = ToolBus(permissionGate: gate)
        await bus.register(tool: makeParkedGatedTool(name: "stub.write", output: "must not run"))
        let narrated = ToolInput.placeholderContent(for: [
            ToolInput(toolName: "stub.write", argumentsJSON: #"{"text":"hi"}"#, callID: "call_narrated_deny")
        ])
        let llm = ParkedApprovalLLM(texts: [narrated])
        let orchestrator = Orchestrator(
            conversations: conversations,
            toolBus: bus,
            llm: llm,
            toolResolver: { _, _ in [] },
            approvalQueue: queue
        )
        let sessionID = UUID()
        _ = try await orchestrator.process(input: UserInput(text: "Write it", sessionID: sessionID))
        let pending = await queue.list().first
        guard let approvalID = pending?.id else {
            Issue.record("Expected a filed gated approval")
            return
        }
        #expect(await queue.decide(id: approvalID, approved: false) == true)
        let resumed = try await orchestrator.resumeNarratedApproval(id: approvalID, approved: false)
        #expect(resumed?.sessionID == sessionID)
        #expect(resumed?.toolActions.isEmpty == true)
        #expect(resumed?.text.lowercased().contains("denied") == true)
        #expect(resumed?.text.contains("stub.write") == true)
        let history = await conversations.history(for: sessionID)
        #expect(!history.contains { $0.role == .tool })
        #expect(history.contains { $0.role == .assistant && $0.content.lowercased().contains("denied") })
    }

    @Test
    func `Narrated read-only call still executes directly with a queue configured`() async throws {
        let conversations = ConversationManager()
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let bus = ToolBus(permissionGate: gate)
        await bus.register(tool: makeParkedReadTool(name: "email.search", output: "Found lighthouse email"))
        await bus.register(tool: makeParkedGatedTool(name: "stub.write", output: "must not run"))
        let args = #"{"query":"lighthouse"}"#
        let narrated = ToolInput.placeholderContent(for: [
            ToolInput(toolName: "email.search", argumentsJSON: args, callID: "call_narrated_read")
        ])
        let synthesis = "Done: found your lighthouse email."
        let llm = ParkedApprovalLLM(texts: [narrated, synthesis])
        let orchestrator = Orchestrator(
            conversations: conversations,
            toolBus: bus,
            llm: llm,
            toolResolver: { _, _ in [] },
            approvalQueue: queue
        )
        let sessionID = UUID()
        let response = try await orchestrator.process(input: UserInput(text: "Find it", sessionID: sessionID))
        #expect(await queue.count() == 0)
        #expect(response.text == synthesis)
        #expect(response.toolActions.count == 1)
        #expect(response.toolActions.first?.toolName == "email.search")
        #expect(response.toolActions.first?.result?.isError == false)
    }
}

// Rune Weaver Tests — Narrated gated approvals with resume continuation.

import Foundation
import os
@testable import RuneWeaverCore
import Testing

/// Fixture tool with a configurable permission level for parked-approval tests.
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
    func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        .success(output, callID: input.callID)
    }
}

/// Scripted provider replaying canned texts in call order.
private final class ParkedApprovalLLM: LLMProvider, Sendable {
    /// Stable test model metadata.
    let modelInfo = ModelInfo(name: "fixture", provider: "test", contextLength: 8192)
    private struct ScriptState: Sendable {
        var texts: [String]
        var index: Int
    }

    /// Guards script state below.
    private let state: OSAllocatedUnfairLock<ScriptState>

    /// Creates a scripted provider.
    /// - Parameter texts: Canned texts in call order.
    init(texts: [String]) {
        self.state = OSAllocatedUnfairLock(initialState: ScriptState(texts: texts, index: 0))
    }

    /// Replays the next canned text as a finished stream.
    func chat(messages _: [Message], tools _: [any Tool]) -> AsyncStream<LLMResponse> {
        let text: String = state.withLock { s in
            let next = s.index < s.texts.count ? s.texts[s.index] : s.texts.last ?? ""
            s.index += 1
            return next
        }
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
private func makeParkedReadTool(name: String, output: String) -> ParkedApprovalTool {
    ParkedApprovalTool(name: name, output: output, permissionLevel: .readOnly)
}

/// Builds an approval-gated fixture tool.
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

    @Test
    func `Allowed gated approval resumes loop and chains subsequent tool call`() async throws {
        let conversations = ConversationManager()
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let bus = ToolBus(permissionGate: gate)
        await bus.register(tool: makeParkedGatedTool(name: "stub.write", output: "write-ok"))
        await bus.register(tool: makeParkedReadTool(name: "stub.read", output: "read-ok"))
        let args1 = #"{"text":"gated"}"#
        let narrated1 = ToolInput.placeholderContent(for: [
            ToolInput(toolName: "stub.write", argumentsJSON: args1, callID: "call_gated")
        ])
        let args2 = #"{"query":"item"}"#
        let narrated2 = ToolInput.placeholderContent(for: [
            ToolInput(toolName: "stub.read", argumentsJSON: args2, callID: "call_read")
        ])
        let synthesis = "All steps complete."
        let llm = ParkedApprovalLLM(texts: [narrated1, narrated2, synthesis])
        let orchestrator = Orchestrator(
            conversations: conversations,
            toolBus: bus,
            llm: llm,
            toolResolver: { _, _ in [] },
            approvalQueue: queue
        )
        let sessionID = UUID()
        let parked = try await orchestrator.process(input: UserInput(text: "Run test", sessionID: sessionID))
        #expect(parked.isParked == true)
        #expect(await queue.count() == 1)
        guard let approvalID = await queue.list().first?.id else {
            Issue.record("Expected a filed gated approval")
            return
        }
        #expect(await queue.decide(id: approvalID, approved: true) == true)
        let resumed = try await orchestrator.resumeNarratedApproval(id: approvalID, approved: true)
        #expect(resumed?.sessionID == sessionID)
        #expect(resumed?.isParked == false)
        #expect(resumed?.text == synthesis)
        #expect(resumed?.toolActions.count == 2)
        #expect(resumed?.toolActions[0].toolName == "stub.write")
        #expect(resumed?.toolActions[0].result?.content.contains("write-ok") == true)
        #expect(resumed?.toolActions[1].toolName == "stub.read")
        #expect(resumed?.toolActions[1].result?.content.contains("read-ok") == true)
        let history = await conversations.history(for: sessionID)
        #expect(history.contains { $0.role == .tool && $0.toolCallID == "call_gated" })
        #expect(history.contains { $0.role == .tool && $0.toolCallID == "call_read" })
        #expect(history.contains { $0.role == .assistant && $0.content == synthesis })
    }

    @Test
    func `Mixed narrated turn persists its assistant narration exactly once`() async throws {
        let conversations = ConversationManager()
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let bus = ToolBus(permissionGate: gate)
        await bus.register(tool: makeParkedReadTool(name: "email.search", output: "Found lighthouse email"))
        await bus.register(tool: makeParkedGatedTool(name: "stub.write", output: "must not run"))
        let narrated = "Checking and writing.\n" + ToolInput.placeholderContent(for: [
            ToolInput(toolName: "email.search", argumentsJSON: #"{"query":"lighthouse"}"#, callID: "call_mixed_read"),
            ToolInput(toolName: "stub.write", argumentsJSON: #"{"text":"hi"}"#, callID: "call_mixed_gated")
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
        let parked = try await orchestrator.process(input: UserInput(text: "Run both", sessionID: sessionID))
        #expect(parked.isParked == true)
        #expect(parked.toolActions.contains { $0.toolName == "email.search" && $0.result != nil })
        #expect(parked.toolActions.contains { $0.toolName == "stub.write" && $0.result == nil })
        #expect(await queue.count() == 1)

        let history = await conversations.history(for: sessionID)
        // One assistant note must carry both call-ID placeholders; a second note
        // duplicates the pairing and corrupts the next model round.
        let narrationNotes = history.filter { message in
            guard message.role == .assistant else { return false }
            return NormalizedText.splitLines(message.content)
                .contains { ToolInput.parsePlaceholderLine($0) != nil }
        }
        #expect(narrationNotes.count == 1)
        let persistedCallIDs = NormalizedText.splitLines(narrationNotes.first?.content ?? "")
            .compactMap { ToolInput.parsePlaceholderLine($0)?.callID }
        #expect(persistedCallIDs.filter { $0 == "call_mixed_read" }.count == 1)
        #expect(persistedCallIDs.filter { $0 == "call_mixed_gated" }.count == 1)
        #expect(history.contains { $0.role == .tool && $0.toolCallID == "call_mixed_read" })
        #expect(!history.contains { $0.role == .tool && $0.toolCallID == "call_mixed_gated" })
    }
}

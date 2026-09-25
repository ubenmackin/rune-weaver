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
        var recordedCalls: [[Message]] = []
    }

    /// Guards script state below.
    private let state: OSAllocatedUnfairLock<ScriptState>

    /// Creates a scripted provider.
    /// - Parameter texts: Canned texts in call order.
    init(texts: [String]) {
        self.state = OSAllocatedUnfairLock(initialState: ScriptState(texts: texts, index: 0, recordedCalls: []))
    }

    /// Replays the next canned text as a finished stream.
    func chat(messages: [Message], tools _: [any Tool]) -> AsyncStream<LLMResponse> {
        let text: String = state.withLock { s in
            s.recordedCalls.append(messages)
            let next = s.index < s.texts.count ? s.texts[s.index] : s.texts.last ?? ""
            s.index += 1
            return next
        }
        return AsyncStream { continuation in
            continuation.yield(LLMResponse(delta: text, isFinished: true))
            continuation.finish()
        }
    }

    /// Snapshot of all message histories received by chat in call order.
    func recordedMessages() -> [[Message]] {
        state.withLock { $0.recordedCalls }
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

    @Test
    func `Tool loop continuation approval resumes with completed tool and valid LLM wire history`() async throws {
        let conversations = ConversationManager()
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let bus = ToolBus(permissionGate: gate)
        await bus.register(tool: makeParkedReadTool(name: "stub.read", output: "read-ok"))
        let round1 = ToolInput.placeholderContent(for: [
            ToolInput(toolName: "stub.read", argumentsJSON: #"{"q":"1"}"#, callID: "call_r1")
        ])
        let round2 = ToolInput.placeholderContent(for: [
            ToolInput(toolName: "stub.read", argumentsJSON: #"{"q":"2"}"#, callID: "call_r2")
        ])
        let postContinuationSynthesis = "Continuing: here is the final answer."
        let llm = ParkedApprovalLLM(texts: [round1, round2, postContinuationSynthesis])
        let orchestrator = Orchestrator(
            conversations: conversations,
            toolBus: bus,
            llm: llm,
            maxToolIterations: 1,
            toolResolver: { _, _ in [] },
            approvalQueue: queue
        )
        let sessionID = UUID()
        let parked = try await orchestrator.process(input: UserInput(text: "Do work", sessionID: sessionID))
        #expect(parked.isParked == true)
        #expect(await queue.count() == 1)
        guard let request = await queue.list().first else {
            Issue.record("Expected an engine.continue approval request")
            return
        }
        #expect(request.toolName == "engine.continue")
        let historyWhileParked = await conversations.history(for: sessionID)
        #expect(historyWhileParked.contains { $0.role == .assistant && $0.content.contains("Awaiting continuation approval") })

        // Lock-guarded collector keeps concurrent event delivery race-free under Swift 6.
        final class CompletedCollector: Sendable {
            private let box = OSAllocatedUnfairLock<[(name: String, callID: String, content: String)]>(initialState: [])
            func append(_ item: (name: String, callID: String, content: String)) {
                box.withLock { $0.append(item) }
            }

            func contains(where predicate: @Sendable (String, String, String) -> Bool) -> Bool {
                box.withLock { items in items.contains { predicate($0.name, $0.callID, $0.content) } }
            }
        }
        let collector = CompletedCollector()

        #expect(await queue.decide(id: request.id, approved: true) == true)
        let resumed = try await orchestrator.resumeNarratedApproval(
            id: request.id,
            approved: true,
            onEvent: { event in
                if case let .toolCompleted(name, callID, result, _) = event {
                    collector.append((name, callID, result.content))
                }
            }
        )
        #expect(resumed?.isParked == false)
        #expect(resumed?.text == postContinuationSynthesis)
        #expect(collector.contains { $0 == "engine.continue" && $1 == request.input.callID && $2.contains("Continuation granted") })

        let historyAfterResume = await conversations.history(for: sessionID)
        #expect(!historyAfterResume.contains { $0.content.contains("Awaiting continuation approval") })
        #expect(historyAfterResume.contains { $0.role == .tool && $0.toolCallID == request.input.callID && $0.content.contains("Continuation granted") })

        // Verify the LLM chat call during synthesis received a clean message sequence without consecutive assistant messages
        let recorded = llm.recordedMessages()
        guard let synthesisMessages = recorded.last else {
            Issue.record("Expected recorded messages from synthesis call")
            return
        }
        // Verify no waiting notes reached the LLM
        #expect(!synthesisMessages.contains { $0.content.contains("Awaiting continuation approval") })
        // Verify no two consecutive assistant messages anywhere in the synthesis prompt
        for i in 1 ..< synthesisMessages.count {
            let prev = synthesisMessages[i - 1]
            let curr = synthesisMessages[i]
            #expect(!(prev.role == .assistant && curr.role == .assistant), "Found consecutive assistant messages at index \(i - 1) and \(i)")
        }
        // The last message before model generation must be the tool result for continuation
        #expect(synthesisMessages.last?.role == .tool)
        #expect(synthesisMessages.last?.toolCallID == request.input.callID)
    }

    @Test
    func `Tool loop continuation denial notifies session with stopped notice and clears waiting note`() async throws {
        let conversations = ConversationManager()
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let bus = ToolBus(permissionGate: gate)
        await bus.register(tool: makeParkedReadTool(name: "stub.read", output: "read-ok"))
        let round1 = ToolInput.placeholderContent(for: [
            ToolInput(toolName: "stub.read", argumentsJSON: #"{"q":"1"}"#, callID: "call_deny_r1")
        ])
        let round2 = ToolInput.placeholderContent(for: [
            ToolInput(toolName: "stub.read", argumentsJSON: #"{"q":"2"}"#, callID: "call_deny_r2")
        ])
        let llm = ParkedApprovalLLM(texts: [round1, round2])
        let orchestrator = Orchestrator(
            conversations: conversations,
            toolBus: bus,
            llm: llm,
            maxToolIterations: 1,
            toolResolver: { _, _ in [] },
            approvalQueue: queue
        )
        let sessionID = UUID()
        let parked = try await orchestrator.process(input: UserInput(text: "Do work", sessionID: sessionID))
        #expect(parked.isParked == true)
        guard let request = await queue.list().first else {
            Issue.record("Expected an engine.continue approval request")
            return
        }
        #expect(await queue.decide(id: request.id, approved: false) == true)
        let resumed = try await orchestrator.resumeNarratedApproval(id: request.id, approved: false)
        #expect(resumed?.isParked == false)
        #expect(resumed?.text.contains("Continuation stopped by user") == true)

        let history = await conversations.history(for: sessionID)
        #expect(!history.contains { $0.content.contains("Awaiting continuation approval") })
        #expect(history.contains { $0.role == .assistant && $0.content.contains("Continuation stopped by user") })
    }
}

/// One scripted LLM round pairing narration text with native structured calls.
private struct StructuredResumeRound: Sendable {
    /// Narration text for the round.
    let text: String
    /// Native calls emitted alongside the text.
    let calls: [ToolInput]

    /// Creates a round.
    init(_ text: String, _ calls: [ToolInput] = []) {
        self.text = text
        self.calls = calls
    }
}

/// Scripted provider replaying native structured rounds in call order.
private final class StructuredResumeLLM: LLMProvider, Sendable {
    /// Stable test model metadata.
    let modelInfo = ModelInfo(name: "fixture", provider: "test", contextLength: 8192)
    private struct ScriptState: Sendable {
        var rounds: [StructuredResumeRound]
        var index: Int
    }

    /// Guards script state below.
    private let state: OSAllocatedUnfairLock<ScriptState>

    /// Creates a scripted provider.
    /// - Parameter rounds: Canned rounds in call order.
    init(rounds: [StructuredResumeRound]) {
        self.state = OSAllocatedUnfairLock(initialState: ScriptState(rounds: rounds, index: 0))
    }

    /// Replays the next canned round as a finished stream.
    func chat(messages _: [Message], tools _: [any Tool]) -> AsyncStream<LLMResponse> {
        let round: StructuredResumeRound = state.withLock { s in
            let next = s.index < s.rounds.count ? s.rounds[s.index] : s.rounds.last ?? StructuredResumeRound("")
            s.index += 1
            return next
        }
        return AsyncStream { continuation in
            continuation.yield(LLMResponse(delta: round.text, isFinished: true, toolCalls: round.calls))
            continuation.finish()
        }
    }

    /// Number of chat calls served so far.
    func chatCallCount() -> Int {
        state.withLock { $0.index }
    }

    /// Unused embeddings stub.
    /// - Parameter text: Ignored texts.
    /// - Returns: Empty vectors.
    func embeddings(text _: [String]) async throws -> [[Float]] {
        []
    }
}

@Suite("Structured Resume")
struct StructuredResumeTests {
    @Test
    func `Late approve on a parked structured call executes plus synthesizes without retry`() async throws {
        let conversations = ConversationManager()
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let bus = ToolBus(permissionGate: gate)
        await bus.register(tool: makeParkedGatedTool(name: "stub.write", output: "write-ok done"))
        let gated = ToolInput(toolName: "stub.write", argumentsJSON: #"{"text":"hello"}"#, callID: "call_struct_allow")
        let synthesis = "Done: wrote your note."
        let llm = StructuredResumeLLM(rounds: [
            StructuredResumeRound("", [gated]),
            StructuredResumeRound(synthesis)
        ])
        let orchestrator = Orchestrator(
            conversations: conversations,
            toolBus: bus,
            llm: llm,
            toolResolver: { _, _ in [] },
            approvalQueue: queue,
            permissionGate: gate
        )
        let sessionID = UUID()
        let parked = try await orchestrator.process(input: UserInput(text: "Write it", sessionID: sessionID))
        #expect(parked.isParked == true)
        #expect(await queue.count() == 1)
        guard let approvalID = await queue.list().first?.id else {
            Issue.record("Expected a filed structured approval")
            return
        }
        final class EventCollector: Sendable {
            private let box = OSAllocatedUnfairLock<(started: Int, completed: Int)>(initialState: (0, 0))
            func noteStarted() {
                box.withLock { $0.started += 1 }
            }

            func noteCompleted() {
                box.withLock { $0.completed += 1 }
            }

            func snapshot() -> (Int, Int) {
                box.withLock { ($0.started, $0.completed) }
            }
        }
        let collector = EventCollector()
        #expect(await queue.decide(id: approvalID, approved: true) == true)
        let resumed = try await orchestrator.resumeNarratedApproval(
            id: approvalID,
            approved: true,
            onEvent: { event in
                switch event {
                case .toolStarted:
                    collector.noteStarted()
                case .toolCompleted:
                    collector.noteCompleted()
                default:
                    break
                }
            }
        )
        let (startedCount, completedCount) = collector.snapshot()
        #expect(startedCount == 1)
        #expect(completedCount == 1)
        #expect(resumed?.sessionID == sessionID)
        #expect(resumed?.isParked == false)
        #expect(resumed?.text == synthesis)
        #expect(resumed?.toolActions.count == 1)
        #expect(resumed?.toolActions.first?.toolName == "stub.write")
        #expect(resumed?.toolActions.first?.result?.isError == false)
        #expect(resumed?.toolActions.first?.result?.content.contains("write-ok") == true)
        let history = await conversations.history(for: sessionID)
        let filedCallID = resumed?.toolActions.first?.callID ?? ""
        #expect(!filedCallID.isEmpty)
        #expect(history.contains { $0.role == .tool && $0.toolCallID == filedCallID })
        #expect(history.contains { $0.role == .assistant && $0.content == synthesis })
        #expect(!history.contains { $0.content.lowercased().contains("waiting") })
    }

    @Test
    func `Denied structured call records denial without execution`() async throws {
        let conversations = ConversationManager()
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let bus = ToolBus(permissionGate: gate)
        await bus.register(tool: makeParkedGatedTool(name: "stub.write", output: "must not run"))
        let gated = ToolInput(toolName: "stub.write", argumentsJSON: #"{"text":"hi"}"#, callID: "call_struct_deny")
        let llm = StructuredResumeLLM(rounds: [StructuredResumeRound("", [gated])])
        let orchestrator = Orchestrator(
            conversations: conversations,
            toolBus: bus,
            llm: llm,
            toolResolver: { _, _ in [] },
            approvalQueue: queue,
            permissionGate: gate
        )
        let sessionID = UUID()
        _ = try await orchestrator.process(input: UserInput(text: "Write it", sessionID: sessionID))
        guard let approvalID = await queue.list().first?.id else {
            Issue.record("Expected a filed structured approval")
            return
        }
        #expect(await queue.decide(id: approvalID, approved: false) == true)
        let resumed = try await orchestrator.resumeNarratedApproval(id: approvalID, approved: false)
        #expect(resumed?.sessionID == sessionID)
        #expect(resumed?.isParked == false)
        #expect(resumed?.toolActions.isEmpty == true)
        #expect(resumed?.text.lowercased().contains("denied") == true)
        #expect(resumed?.text.contains("stub.write") == true)
        let history = await conversations.history(for: sessionID)
        #expect(!history.contains { $0.role == .tool })
        #expect(history.contains { $0.role == .assistant && $0.content.lowercased().contains("denied") })
    }

    @Test
    func `Approved structured call with missing tool records notice without execution`() async throws {
        let conversations = ConversationManager()
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let bus = ToolBus(permissionGate: gate)
        await bus.register(tool: makeParkedGatedTool(name: "stub.write", output: "must not run"))
        let gated = ToolInput(toolName: "stub.write", argumentsJSON: #"{"text":"hi"}"#, callID: "call_struct_missing")
        let llm = StructuredResumeLLM(rounds: [StructuredResumeRound("", [gated])])
        let orchestrator = Orchestrator(
            conversations: conversations,
            toolBus: bus,
            llm: llm,
            toolResolver: { _, _ in [] },
            approvalQueue: queue,
            permissionGate: gate
        )
        let sessionID = UUID()
        _ = try await orchestrator.process(input: UserInput(text: "Write it", sessionID: sessionID))
        guard let approvalID = await queue.list().first?.id else {
            Issue.record("Expected a filed structured approval")
            return
        }
        await bus.unregister(toolNamed: "stub.write")
        #expect(await queue.decide(id: approvalID, approved: true) == true)
        let resumed = try await orchestrator.resumeNarratedApproval(id: approvalID, approved: true)
        #expect(resumed?.sessionID == sessionID)
        #expect(resumed?.isParked == false)
        #expect(resumed?.toolActions.isEmpty == true)
        #expect(resumed?.text.contains("stub.write") == true)
        #expect(resumed?.text.contains("no longer available") == true)
        let history = await conversations.history(for: sessionID)
        #expect(!history.contains { $0.role == .tool })
    }

    @Test
    func `Batch siblings defer synthesis until the last decision then synthesize once`() async throws {
        let conversations = ConversationManager()
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let bus = ToolBus(permissionGate: gate)
        await bus.register(tool: makeParkedGatedTool(name: "stub.write", output: "write-ok"))
        let gated1 = ToolInput(toolName: "stub.write", argumentsJSON: #"{"path":"/tmp/a"}"#, callID: "call_struct_batch1")
        let gated2 = ToolInput(toolName: "stub.write", argumentsJSON: #"{"path":"/tmp/b"}"#, callID: "call_struct_batch2")
        let synthesis = "Both writes complete."
        let llm = StructuredResumeLLM(rounds: [
            StructuredResumeRound("", [gated1, gated2]),
            StructuredResumeRound(synthesis)
        ])
        let orchestrator = Orchestrator(
            conversations: conversations,
            toolBus: bus,
            llm: llm,
            toolResolver: { _, _ in [] },
            approvalQueue: queue,
            permissionGate: gate
        )
        let sessionID = UUID()
        let parked = try await orchestrator.process(input: UserInput(text: "Write both", sessionID: sessionID))
        #expect(parked.isParked == true)
        #expect(await queue.count() == 2)
        let pending = await queue.list()
        guard pending.count == 2 else {
            Issue.record("Expected two filed structured approvals")
            return
        }
        let firstID = pending[0].id
        let secondID = pending[1].id
        let callsBeforeResume = llm.chatCallCount()
        #expect(await queue.decide(id: firstID, approved: true) == true)
        let firstResumed = try await orchestrator.resumeNarratedApproval(id: firstID, approved: true)
        #expect(firstResumed?.isParked == true)
        #expect(firstResumed?.text.contains("waiting for 1 more approval") == true)
        #expect(llm.chatCallCount() == callsBeforeResume)
        #expect(await queue.decide(id: secondID, approved: true) == true)
        let secondResumed = try await orchestrator.resumeNarratedApproval(id: secondID, approved: true)
        #expect(secondResumed?.sessionID == sessionID)
        #expect(secondResumed?.isParked == false)
        #expect(secondResumed?.text == synthesis)
        #expect(secondResumed?.toolActions.count == 2)
        #expect(secondResumed?.toolActions.allSatisfy { $0.result?.isError == false } == true)
        #expect(secondResumed?.toolActions.allSatisfy { $0.result?.content.contains("write-ok") == true } == true)
        let history = await conversations.history(for: sessionID)
        #expect(history.contains { $0.role == .tool && $0.toolCallID == "call_struct_batch1" })
        #expect(history.contains { $0.role == .tool && $0.toolCallID == "call_struct_batch2" })
        let syntheses = history.filter { $0.role == .assistant && $0.content == synthesis }
        #expect(syntheses.count == 1)
    }

    @Test
    func `Superseded session resumes against current history and clears waiting notes`() async throws {
        let conversations = ConversationManager()
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let bus = ToolBus(permissionGate: gate)
        await bus.register(tool: makeParkedGatedTool(name: "stub.write", output: "write-ok done"))
        let gated = ToolInput(toolName: "stub.write", argumentsJSON: #"{"text":"hello"}"#, callID: "call_struct_superseded")
        let synthesis = "Done after supersede."
        let llm = StructuredResumeLLM(rounds: [
            StructuredResumeRound("", [gated]),
            StructuredResumeRound(synthesis)
        ])
        let orchestrator = Orchestrator(
            conversations: conversations,
            toolBus: bus,
            llm: llm,
            toolResolver: { _, _ in [] },
            approvalQueue: queue,
            permissionGate: gate
        )
        let sessionID = UUID()
        _ = try await orchestrator.process(input: UserInput(text: "Write it", sessionID: sessionID))
        guard let approvalID = await queue.list().first?.id else {
            Issue.record("Expected a filed structured approval")
            return
        }
        await conversations.removeSession(id: sessionID)
        #expect(await queue.decide(id: approvalID, approved: true) == true)
        let resumed = try await orchestrator.resumeNarratedApproval(id: approvalID, approved: true)
        #expect(resumed?.sessionID == sessionID)
        #expect(resumed?.isParked == false)
        #expect(resumed?.text == synthesis)
        #expect(resumed?.toolActions.count == 1)
        #expect(resumed?.toolActions.first?.result?.isError == false)
        let history = await conversations.history(for: sessionID)
        #expect(!history.contains { $0.content.lowercased().contains("waiting") })
        #expect(history.contains { $0.role == .tool && $0.toolCallID == "call_struct_superseded" })
        #expect(history.contains { $0.role == .assistant && $0.content == synthesis })
    }

    @Test
    func `Decision backstop stays at 300 seconds and denies escaping waits`() async {
        #expect(ApprovalQueue.defaultDecisionTimeoutSeconds == 300)
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let request = await queue.enqueue(
            toolName: "stub.write",
            description: "Backstop probe",
            input: ToolInput(toolName: "stub.write", argumentsJSON: "{}", callID: "call_backstop")
        )
        let decision = await queue.waitForDecision(id: request.id, timeoutSeconds: 0.05)
        #expect(decision.approved == false)
        #expect(decision.timedOut == true)
        #expect(await queue.request(id: request.id) != nil)
        #expect(await queue.decide(id: request.id, approved: true) == true)
    }

    @Test
    func `Headless structured turn files plus denies with zero parking`() async throws {
        let conversations = ConversationManager()
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let bus = ToolBus(permissionGate: gate)
        await bus.register(tool: makeParkedGatedTool(name: "stub.write", output: "must not run"))
        let headlessHandler = await queue.headlessApprovalHandler()
        await bus.setApprovalHandler(headlessHandler)
        let gated = ToolInput(toolName: "stub.write", argumentsJSON: #"{"path":"/tmp/a"}"#, callID: "call_struct_headless")
        let llm = StructuredResumeLLM(rounds: [
            StructuredResumeRound("", [gated]),
            StructuredResumeRound("Headless noted.")
        ])
        let orchestrator = Orchestrator(
            conversations: conversations,
            toolBus: bus,
            llm: llm,
            toolResolver: { _, _ in [] },
            approvalQueue: nil,
            permissionGate: gate
        )
        let sessionID = UUID()
        let response = try await orchestrator.process(input: UserInput(text: "Write it", sessionID: sessionID))
        #expect(response.isParked == false)
        #expect(await orchestrator.parkedNarratedApprovals.isEmpty)
        #expect(await orchestrator.isSessionParked(sessionID) == false)
        #expect(await queue.count() == 1)
        #expect(response.toolActions.first?.result?.isError == true)
        let unknownResume = try await orchestrator.resumeNarratedApproval(id: UUID(), approved: true)
        #expect(unknownResume == nil)
    }
}

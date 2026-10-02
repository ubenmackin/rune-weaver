// Rune Weaver Tests — Structured park admission in the turn loop.
//
// Verifies that natively requested (structured) tool calls requiring approval park
// before execution instead of entering the suspending bus handler. Scope is admission
// partitioning only: allowed-now execution, single-batch filing with narrated siblings,
// and fail-closed preservation of denial, unknown, headless, and dry-run paths.
// Architecturally, the turn loop remains the single admission point, reusing the
// narrated park record and batch so structured and narrated approvals resume identically.

import Foundation
import os
@testable import RuneWeaverCore
import Testing

/// Fixture tool with a configurable permission level for structured park tests.
private struct StructuredParkTool: Tool, Sendable {
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

/// One scripted LLM round pairing narration text with native tool calls.
private struct StructuredParkRound: Sendable {
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

/// Scripted provider replaying canned rounds in call order.
private final class StructuredParkLLM: LLMProvider, Sendable {
    /// Stable test model metadata.
    let modelInfo = ModelInfo(name: "fixture", provider: "test", contextLength: 8192)
    private struct ScriptState: Sendable {
        var rounds: [StructuredParkRound]
        var index: Int
    }

    /// Guards script state below.
    private let state: OSAllocatedUnfairLock<ScriptState>

    /// Creates a scripted provider.
    /// - Parameter rounds: Canned rounds in call order.
    init(rounds: [StructuredParkRound]) {
        self.state = OSAllocatedUnfairLock(initialState: ScriptState(rounds: rounds, index: 0))
    }

    /// Replays the next canned round as a finished stream.
    func chat(messages _: [Message], tools _: [any Tool]) -> AsyncStream<LLMResponse> {
        let round: StructuredParkRound = state.withLock { s in
            let next = s.index < s.rounds.count ? s.rounds[s.index] : s.rounds.last ?? StructuredParkRound("")
            s.index += 1
            return next
        }
        return AsyncStream { continuation in
            continuation.yield(LLMResponse(delta: round.text, isFinished: true, toolCalls: round.calls))
            continuation.finish()
        }
    }

    /// Unused embeddings stub.
    func embeddings(text _: [String]) async throws -> [[Float]] {
        []
    }
}

/// Builds a read-only fixture tool.
private func makeStructuredReadTool(name: String, output: String) -> StructuredParkTool {
    StructuredParkTool(name: name, output: output, permissionLevel: .readOnly)
}

/// Builds an approval-gated fixture tool.
private func makeStructuredGatedTool(name: String, output: String) -> StructuredParkTool {
    StructuredParkTool(name: name, output: output, permissionLevel: .requiresApproval)
}

/// Stub evaluator mapping specific hosts to test statuses.
private struct StubEgressEvaluator: EgressPolicyEvaluator, Sendable {
    let statuses: [String: HostStatus]

    func evaluateHostStatus(for host: String, sessionID _: UUID?) async -> HostStatus {
        statuses[host] ?? .allowed
    }
}

@Suite("Structured Park Admission")
struct StructuredParkTests {
    @Test
    func `Structured gated call parks without executing`() async throws {
        let conversations = ConversationManager()
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let bus = ToolBus(permissionGate: gate)
        await bus.register(tool: makeStructuredGatedTool(name: "stub.write", output: "must not run"))
        let gated = ToolInput(toolName: "stub.write", argumentsJSON: #"{"path":"/tmp/a"}"#, callID: "call_struct_gated_only")
        let llm = StructuredParkLLM(rounds: [StructuredParkRound("", [gated])])
        let orchestrator = Orchestrator(
            conversations: conversations,
            toolBus: bus,
            llm: llm,
            toolResolver: { _, _ in [] },
            approvalQueue: queue,
            permissionGate: gate
        )
        let sessionID = UUID()
        let response = try await orchestrator.process(input: UserInput(text: "Write it", sessionID: sessionID))
        #expect(response.isParked == true)
        #expect(await queue.count() == 1)
        #expect(response.toolActions.count == 1)
        #expect(response.toolActions.first?.toolName == "stub.write")
        #expect(response.toolActions.first?.result == nil)
        #expect(response.text.lowercased().contains("approval"))
        let history = await conversations.history(for: sessionID)
        #expect(!history.contains { $0.role == .tool })
        #expect(history.contains { $0.role == .assistant && $0.content.lowercased().contains("waiting") })
    }

    @Test
    func `Read-only structured call executes without parking`() async throws {
        let conversations = ConversationManager()
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let bus = ToolBus(permissionGate: gate)
        await bus.register(tool: makeStructuredReadTool(name: "stub.read", output: "read-ok"))
        let read = ToolInput(toolName: "stub.read", argumentsJSON: #"{"query":"x"}"#, callID: "call_struct_read")
        let llm = StructuredParkLLM(rounds: [
            StructuredParkRound("", [read]),
            StructuredParkRound("Done: found it.")
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
        let response = try await orchestrator.process(input: UserInput(text: "Find it", sessionID: sessionID))
        #expect(response.isParked == false)
        #expect(await queue.count() == 0)
        #expect(response.text == "Done: found it.")
        #expect(response.toolActions.count == 1)
        #expect(response.toolActions.first?.toolName == "stub.read")
        #expect(response.toolActions.first?.result?.isError == false)
    }

    @Test
    func `Covering grant lets a gated call execute without parking`() async throws {
        let conversations = ConversationManager()
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let bus = ToolBus(permissionGate: gate)
        await bus.register(tool: makeStructuredGatedTool(name: "stub.write", output: "write-ok"))
        let args = #"{"path":"/tmp/covered"}"#
        await gate.grantTrust(for: ActionDescriptor(toolName: "stub.write", target: "/tmp/covered"), duration: .oneHour)
        let gated = ToolInput(toolName: "stub.write", argumentsJSON: args, callID: "call_struct_covered")
        let llm = StructuredParkLLM(rounds: [
            StructuredParkRound("", [gated]),
            StructuredParkRound("Done: wrote it.")
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
        let response = try await orchestrator.process(input: UserInput(text: "Write it", sessionID: sessionID))
        #expect(response.isParked == false)
        #expect(await queue.count() == 0)
        #expect(response.toolActions.count == 1)
        #expect(response.toolActions.first?.result?.isError == false)
        #expect(response.toolActions.first?.result?.content.contains("write-ok") == true)
    }

    @Test
    func `Mixed round executes allowed first then parks gated in one batch`() async throws {
        let conversations = ConversationManager()
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let bus = ToolBus(permissionGate: gate)
        await bus.register(tool: makeStructuredReadTool(name: "stub.read", output: "read-ok"))
        await bus.register(tool: makeStructuredGatedTool(name: "stub.write", output: "must not run"))
        let read = ToolInput(toolName: "stub.read", argumentsJSON: #"{"query":"x"}"#, callID: "call_mixed_read")
        let gated1 = ToolInput(toolName: "stub.write", argumentsJSON: #"{"path":"/tmp/a"}"#, callID: "call_mixed_gated1")
        let gated2 = ToolInput(toolName: "stub.write", argumentsJSON: #"{"path":"/tmp/b"}"#, callID: "call_mixed_gated2")
        let llm = StructuredParkLLM(rounds: [StructuredParkRound("", [read, gated1, gated2])])
        let orchestrator = Orchestrator(
            conversations: conversations,
            toolBus: bus,
            llm: llm,
            toolResolver: { _, _ in [] },
            approvalQueue: queue,
            permissionGate: gate
        )
        let sessionID = UUID()
        let response = try await orchestrator.process(input: UserInput(text: "Run both", sessionID: sessionID))
        #expect(response.isParked == true)
        #expect(await queue.count() == 2)
        #expect(response.toolActions.contains { $0.toolName == "stub.read" && $0.result != nil })
        #expect(response.toolActions.contains { $0.toolName == "stub.write" && $0.callID == "call_mixed_gated1" && $0.result == nil })
        #expect(response.toolActions.contains { $0.toolName == "stub.write" && $0.callID == "call_mixed_gated2" && $0.result == nil })
        let parked = await orchestrator.parkedNarratedApprovals
        #expect(parked.count == 2)
        let batchIDs = Set(parked.values.map(\.batchID))
        #expect(batchIDs.count == 1)
        #expect(parked.values.allSatisfy { $0.priorActions.contains { $0.toolName == "stub.read" } })
        let history = await conversations.history(for: sessionID)
        #expect(history.contains { $0.role == .tool && $0.toolCallID == "call_mixed_read" })
        #expect(!history.contains { $0.role == .tool && $0.toolCallID == "call_mixed_gated1" })
    }

    @Test
    func `Structured plus narrated siblings share one batch with narration persisted once`() async throws {
        let conversations = ConversationManager()
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let bus = ToolBus(permissionGate: gate)
        await bus.register(tool: makeStructuredReadTool(name: "stub.read", output: "read-ok"))
        await bus.register(tool: makeStructuredGatedTool(name: "stub.write", output: "must not run"))
        let read = ToolInput(toolName: "stub.read", argumentsJSON: #"{"query":"x"}"#, callID: "call_combo_read")
        let structuredGated = ToolInput(toolName: "stub.write", argumentsJSON: #"{"path":"/tmp/a"}"#, callID: "call_combo_struct")
        let narrated = ToolInput.placeholderContent(for: [
            ToolInput(toolName: "stub.write", argumentsJSON: #"{"path":"/tmp/b"}"#, callID: "call_combo_narrated")
        ])
        let llm = StructuredParkLLM(rounds: [StructuredParkRound("Working on it.\n" + narrated, [read, structuredGated])])
        let orchestrator = Orchestrator(
            conversations: conversations,
            toolBus: bus,
            llm: llm,
            toolResolver: { _, _ in [] },
            approvalQueue: queue,
            permissionGate: gate
        )
        let sessionID = UUID()
        let response = try await orchestrator.process(input: UserInput(text: "Run all", sessionID: sessionID))
        #expect(response.isParked == true)
        #expect(await queue.count() == 2)
        let parked = await orchestrator.parkedNarratedApprovals
        #expect(parked.count == 2)
        #expect(Set(parked.values.map(\.batchID)).count == 1)
        let history = await conversations.history(for: sessionID)
        let narrationNotes = history.filter { message in
            guard message.role == .assistant else { return false }
            return NormalizedText.splitLines(message.content)
                .contains { ToolInput.parsePlaceholderLine($0) != nil }
        }
        #expect(narrationNotes.count == 1)
        let persistedCallIDs = NormalizedText.splitLines(narrationNotes.first?.content ?? "")
            .compactMap { ToolInput.parsePlaceholderLine($0)?.callID }
        #expect(persistedCallIDs.contains("call_combo_read"))
        #expect(persistedCallIDs.contains("call_combo_struct"))
        #expect(persistedCallIDs.contains("call_combo_narrated"))
    }

    @Test
    func `Gate-denied structured call fails terminally with zero parking`() async throws {
        let conversations = ConversationManager()
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let bus = ToolBus(permissionGate: gate)
        await bus.register(tool: makeStructuredGatedTool(name: "stub.write", output: "must not run"))
        await gate.deny(ActionDescriptor(toolName: "stub.write"), reason: "blocked for test")
        let gated = ToolInput(toolName: "stub.write", argumentsJSON: #"{"path":"/tmp/a"}"#, callID: "call_struct_denied")
        let llm = StructuredParkLLM(rounds: [
            StructuredParkRound("", [gated]),
            StructuredParkRound("Noted the denial.")
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
        let response = try await orchestrator.process(input: UserInput(text: "Write it", sessionID: sessionID))
        #expect(response.isParked == false)
        #expect(await queue.count() == 0)
        #expect(await orchestrator.parkedNarratedApprovals.isEmpty)
        #expect(response.toolActions.count == 1)
        #expect(response.toolActions.first?.result?.isError == true)
    }

    @Test
    func `Dry-run turn never parks`() async throws {
        let conversations = ConversationManager()
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let bus = ToolBus(permissionGate: gate)
        await bus.register(tool: makeStructuredGatedTool(name: "stub.write", output: "preview-ok"))
        await bus.setApprovalHandler { _, _, _ in true }
        let gated = ToolInput(toolName: "stub.write", argumentsJSON: #"{"path":"/tmp/a"}"#, callID: "call_struct_dryrun")
        let llm = StructuredParkLLM(rounds: [
            StructuredParkRound("", [gated]),
            StructuredParkRound("Previewed.")
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
        let tools = await bus.availableTools()
        var pending: [(content: String, role: Message.Role)] = []
        let request = TurnLoopRequest(
            workingMessages: [Message(role: .user, content: "Preview it")],
            tools: tools,
            recall: nil,
            sessionID: sessionID,
            systemPrompt: nil,
            onEvent: nil,
            isDryRun: true
        )
        let outcome = try await orchestrator.runTurnLoop(request, pendingEpisodic: &pending)
        guard case let .finished(finalText, toolActions, _, _) = outcome else {
            Issue.record("Dry run must finish without parking")
            return
        }
        #expect(finalText == "Previewed.")
        #expect(toolActions.count == 1)
        #expect(toolActions.first?.result?.isError == false)
        #expect(await queue.count() == 0)
        #expect(await orchestrator.parkedNarratedApprovals.isEmpty)
    }

    @Test
    func `Headless turn never parks`() async throws {
        let conversations = ConversationManager()
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let bus = ToolBus(permissionGate: gate)
        await bus.register(tool: makeStructuredGatedTool(name: "stub.write", output: "must not run"))
        let headlessHandler = await queue.headlessApprovalHandler()
        await bus.setApprovalHandler(headlessHandler)
        let gated = ToolInput(toolName: "stub.write", argumentsJSON: #"{"path":"/tmp/a"}"#, callID: "call_struct_headless")
        let llm = StructuredParkLLM(rounds: [
            StructuredParkRound("", [gated]),
            StructuredParkRound("Headless noted.")
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
    }
}

// MARK: - Egress Admission Tests

extension StructuredParkTests {
    @Test
    func `Unlisted egress host parks read-only tool with egress host badge`() async throws {
        let conversations = ConversationManager()
        let evaluator = StubEgressEvaluator(statuses: ["prismix.dev": .unlisted("Unlisted domain")])
        let gate = PermissionGate(egressEvaluator: evaluator)
        let queue = ApprovalQueue(permissionGate: gate)
        let bus = ToolBus(permissionGate: gate)
        await bus.register(tool: makeStructuredReadTool(name: "web.fetch", output: "article-html"))
        let unlistedCall = ToolInput(
            toolName: "web.fetch",
            argumentsJSON: #"{"url":"https://prismix.dev/news/f2f2b6598ef6"}"#,
            callID: "call_egress_unlisted"
        )
        let synthesis = "Here is the news."
        let llm = StructuredParkLLM(rounds: [
            StructuredParkRound("", [unlistedCall]),
            StructuredParkRound(synthesis)
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
        let parked = try await orchestrator.process(input: UserInput(text: "Fetch prismix", sessionID: sessionID))
        #expect(parked.isParked == true)
        #expect(await queue.count() == 1)
        let pending = await queue.list().first
        #expect(pending?.toolName == "web.fetch")
        #expect(pending?.egressHost == "prismix.dev")
        #expect(pending?.sessionID == sessionID)
        guard let approvalID = pending?.id else {
            Issue.record("Expected pending approval request")
            return
        }
        #expect(await queue.decide(id: approvalID, approved: true) == true)
        let resumed = try await orchestrator.resumeNarratedApproval(id: approvalID, approved: true)
        #expect(resumed?.sessionID == sessionID)
        #expect(resumed?.isParked == false)
        #expect(resumed?.toolActions.first?.toolName == "web.fetch")
        #expect(resumed?.toolActions.first?.result?.content.contains("article-html") == true)
    }

    @Test
    func `Allowed egress host does not park read-only tool`() async throws {
        let conversations = ConversationManager()
        let evaluator = StubEgressEvaluator(statuses: ["example.com": .allowed])
        let gate = PermissionGate(egressEvaluator: evaluator)
        let queue = ApprovalQueue(permissionGate: gate)
        let bus = ToolBus(permissionGate: gate)
        await bus.register(tool: makeStructuredReadTool(name: "web.fetch", output: "example-html"))
        let allowedCall = ToolInput(
            toolName: "web.fetch",
            argumentsJSON: #"{"url":"https://example.com/index.html"}"#,
            callID: "call_egress_allowed"
        )
        let llm = StructuredParkLLM(rounds: [
            StructuredParkRound("", [allowedCall]),
            StructuredParkRound("Fetched example.")
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
        let response = try await orchestrator.process(input: UserInput(text: "Fetch example", sessionID: sessionID))
        #expect(response.isParked == false)
        #expect(await queue.count() == 0)
        #expect(response.toolActions.count == 1)
        #expect(response.toolActions.first?.result?.content.contains("example-html") == true)
    }
}

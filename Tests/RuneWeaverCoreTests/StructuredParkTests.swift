// Rune Weaver Tests — Structured park admission in the turn loop.
//
// Verifies that natively requested (structured) tool calls requiring approval park
// before execution instead of entering the suspending bus handler. Scope is admission
// partitioning only: allowed-now execution, single-batch filing with narrated siblings,
// pre-admission refusal of target-shaped calls before any approval row is filed, and
// fail-closed preservation of denial, unknown, headless, and dry-run paths.
// Architecturally, the turn loop remains the single admission point, reusing the
// narrated park record and batch so structured and narrated approvals resume identically.

import Foundation
import os
@testable import RuneWeaverCore
@testable import RuneWeaverTools
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
        var recordedCalls: [[Message]] = []
    }

    /// Guards script state below.
    private let state: OSAllocatedUnfairLock<ScriptState>

    /// Creates a scripted provider.
    /// - Parameter rounds: Canned rounds in call order.
    init(rounds: [StructuredParkRound]) {
        self.state = OSAllocatedUnfairLock(initialState: ScriptState(rounds: rounds, index: 0))
    }

    /// Replays the next canned round as a finished stream, recording the prompt.
    func chat(messages: [Message], tools _: [any Tool]) -> AsyncStream<LLMResponse> {
        let round: StructuredParkRound = state.withLock { s in
            s.recordedCalls.append(messages)
            let next = s.index < s.rounds.count ? s.rounds[s.index] : s.rounds.last ?? StructuredParkRound("")
            s.index += 1
            return next
        }
        return AsyncStream { continuation in
            continuation.yield(LLMResponse(delta: round.text, isFinished: true, toolCalls: round.calls))
            continuation.finish()
        }
    }

    /// Snapshot of all message histories received by chat in call order.
    func recordedMessages() -> [[Message]] {
        state.withLock { $0.recordedCalls }
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
        await gate.denyRule(.toolWide, toolName: "stub.write", reason: "blocked for test")
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
        guard case let .finished(finalText, toolActions, _, _, _, _) = outcome else {
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

// MARK: - Messages send admission

/// Canned Messages gateway recording sends so admission tests can assert none ran.
private final class AdmissionMessagesGateway: MessagesGateway, Sendable {
    /// Lock-guarded send log.
    private struct State: Sendable {
        var sent: [(recipient: String, text: String)] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Records one send and reports success.
    func send(recipient: String, text: String) async throws -> MessagesSendResult {
        state.withLock { $0.sent.append((recipient, text)) }
        return MessagesSendResult(success: true, recipient: recipient, text: text, confirmed: true)
    }

    /// Unused search stub.
    func search(query _: String?, recipient _: String?, limit _: Int, since _: Date?, until _: Date?) async throws -> [MessagesMessageItem] {
        []
    }

    /// Unused read stub.
    func read(chatID _: String?, recipient _: String?, limit _: Int, since _: Date?, until _: Date?) async throws -> [MessagesMessageItem] {
        []
    }

    /// Recipients of every send attempted, in call order.
    var sentRecipients: [String] {
        state.withLock { $0.sent.map(\.recipient) }
    }
}

/// Canned recipient resolver serving one seeded best match and recording queries.
private final class AdmissionRecipientResolver: MessagesRecipientResolving, Sendable {
    /// Lock-guarded query log.
    private struct State: Sendable {
        var queries: [String] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let selected: MessageRecipientCandidate?

    /// Creates a resolver serving the seeded best match, or an empty resolution.
    /// - Parameter selected: Best-match candidate, or nil for a zero-match lookup.
    init(selected: MessageRecipientCandidate? = nil) {
        self.selected = selected
    }

    /// Records the query and serves the seeded resolution.
    func resolve(name: String, limit _: Int) async -> MessageRecipientResolution {
        state.withLock { $0.queries.append(name) }
        guard let selected else {
            return MessageRecipientResolution(query: name, candidates: [])
        }
        return MessageRecipientResolution(query: name, candidates: [selected], selected: selected)
    }

    /// Queries seen so far, in call order.
    var queries: [String] {
        state.withLock { $0.queries }
    }
}

/// Counts direct-bus approval handler invocations across the bus actor.
private actor BusApprovalCallCounter {
    /// Number of handler invocations observed.
    private(set) var count = 0

    /// Records one invocation.
    func increment() {
        count += 1
    }
}

extension StructuredParkTests {
    @Test
    func `Name-shaped messages.send is refused before filing with no approval row or grant`() async throws {
        let conversations = ConversationManager()
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let bus = ToolBus(permissionGate: gate)
        let selected = MessageRecipientCandidate(
            displayName: "Rebecca Mackin",
            handle: "rebecca@example.com",
            service: "iMessage",
            source: .contact
        )
        let resolver = AdmissionRecipientResolver(selected: selected)
        let gateway = AdmissionMessagesGateway()
        await bus.register(tool: MessagesSendTool(gateway: gateway, resolver: resolver))
        let nameCall = ToolInput(
            toolName: "messages.send",
            argumentsJSON: #"{"recipient":"Rebecca","text":"On my way"}"#,
            callID: "call_send_name"
        )
        let llm = StructuredParkLLM(rounds: [
            StructuredParkRound("", [nameCall]),
            StructuredParkRound("I need the exact handle first.")
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
        let response = try await orchestrator.process(input: UserInput(text: "Text Rebecca", sessionID: sessionID))

        #expect(response.isParked == false)
        #expect(await queue.count() == 0)
        #expect(await gate.activeRules().isEmpty == true)
        #expect(await orchestrator.parkedNarratedApprovals.isEmpty == true)
        #expect(gateway.sentRecipients.isEmpty)
        #expect(resolver.queries == ["Rebecca"])
        let action = try #require(response.toolActions.first { $0.callID == "call_send_name" })
        #expect(action.result?.isError == true)
        #expect(action.result?.content.contains("is a display name, not a phone number or email") == true)
        #expect(action.result?.content.contains(#"Retry messages.send with recipient "rebecca@example.com""#) == true)
        let history = await conversations.history(for: sessionID)
        #expect(history.contains { $0.role == .tool && $0.toolCallID == "call_send_name" })
    }

    @Test
    func `Name-shaped narrated messages.send is refused before filing`() async throws {
        let conversations = ConversationManager()
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let bus = ToolBus(permissionGate: gate)
        let selected = MessageRecipientCandidate(
            displayName: "Rebecca Mackin",
            handle: "rebecca@example.com",
            source: .contact
        )
        let resolver = AdmissionRecipientResolver(selected: selected)
        let gateway = AdmissionMessagesGateway()
        await bus.register(tool: MessagesSendTool(gateway: gateway, resolver: resolver))
        let narrated = ToolInput.placeholderContent(for: [
            ToolInput(
                toolName: "messages.send",
                argumentsJSON: #"{"recipient":"Rebecca","text":"On my way"}"#,
                callID: "call_narrated_send_name"
            )
        ])
        let llm = StructuredParkLLM(rounds: [
            StructuredParkRound(narrated),
            StructuredParkRound("I need the exact handle first.")
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
        let response = try await orchestrator.process(input: UserInput(text: "Text Rebecca", sessionID: sessionID))

        #expect(response.isParked == false)
        #expect(await queue.count() == 0)
        #expect(await gate.activeRules().isEmpty == true)
        #expect(gateway.sentRecipients.isEmpty)
        let action = try #require(response.toolActions.first { $0.callID == "call_narrated_send_name" })
        #expect(action.result?.isError == true)
        #expect(action.result?.content.contains("is a display name, not a phone number or email") == true)
    }

    @Test
    func `Boundary refusal survives the continuation park and reaches the resumed model`() async throws {
        // A round that both refuses a pre-admission call and trips the tool-round
        // budget must still answer the model: the round note and the refusal result
        // are persisted before the continuation park, the park context carries the
        // refusal actions, and the resumed synthesis prompt contains the actionable
        // candidates instead of leaving the model to retry the same name-shaped send.
        let conversations = ConversationManager()
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let bus = ToolBus(permissionGate: gate)
        await bus.register(tool: makeStructuredReadTool(name: "stub.read", output: "read-ok"))
        let selected = MessageRecipientCandidate(
            displayName: "Rebecca Mackin",
            handle: "rebecca@example.com",
            service: "iMessage",
            source: .contact
        )
        let resolver = AdmissionRecipientResolver(selected: selected)
        let gateway = AdmissionMessagesGateway()
        await bus.register(tool: MessagesSendTool(gateway: gateway, resolver: resolver))
        let readCall = ToolInput(toolName: "stub.read", argumentsJSON: #"{"query":"x"}"#, callID: "call_boundary_read")
        let nameCall = ToolInput(
            toolName: "messages.send",
            argumentsJSON: #"{"recipient":"Rebecca","text":"On my way"}"#,
            callID: "call_boundary_send"
        )
        let synthesis = "I need the exact handle first."
        let llm = StructuredParkLLM(rounds: [
            StructuredParkRound("", [readCall]),
            StructuredParkRound("", [nameCall]),
            StructuredParkRound(synthesis)
        ])
        let orchestrator = Orchestrator(
            conversations: conversations,
            toolBus: bus,
            llm: llm,
            maxToolIterations: 1,
            toolResolver: { _, _ in [] },
            approvalQueue: queue,
            permissionGate: gate
        )
        let sessionID = UUID()
        let parked = try await orchestrator.process(input: UserInput(text: "Text Rebecca", sessionID: sessionID))

        // The boundary round parks for continuation and files no send approval.
        #expect(parked.isParked == true)
        #expect(await queue.count() == 1)
        let request = try #require(await queue.list().first)
        #expect(request.toolName == "engine.continue")
        #expect(gateway.sentRecipients.isEmpty)

        // The refusal reached the response actions, the round note, and history.
        let refusedAction = try #require(parked.toolActions.first { $0.callID == nameCall.callID })
        #expect(refusedAction.result?.isError == true)
        #expect(refusedAction.result?.content.contains("is a display name, not a phone number or email") == true)
        #expect(refusedAction.result?.content.contains(#"Retry messages.send with recipient "rebecca@example.com""#) == true)
        let historyWhileParked = await conversations.history(for: sessionID)
        let refusalResult = try #require(historyWhileParked.first { $0.role == .tool && $0.toolCallID == nameCall.callID })
        #expect(refusalResult.content.contains("is a display name"))
        let noteCallIDs = historyWhileParked
            .filter { $0.role == .assistant }
            .flatMap { NormalizedText.splitLines($0.content) }
            .compactMap { ToolInput.parsePlaceholderLine($0)?.callID }
        #expect(noteCallIDs.contains(nameCall.callID))
        #expect(noteCallIDs.contains(request.input.callID))

        // The park context carries the refusal into the resumed turn.
        let parkedRecord = try #require(await orchestrator.parkedNarratedApprovals.values.first)
        #expect(parkedRecord.priorActions.contains { $0.callID == nameCall.callID && $0.result?.isError == true })

        // The resumed model sees the refusal and the continuation pairing stays valid.
        #expect(await queue.decide(id: request.id, approved: true) == true)
        let resumed = try await orchestrator.resumeNarratedApproval(id: request.id, approved: true)
        #expect(resumed?.isParked == false)
        #expect(resumed?.text == synthesis)
        let synthesisMessages = try #require(llm.recordedMessages().last)
        #expect(synthesisMessages.contains { $0.role == .tool && $0.toolCallID == nameCall.callID && $0.content.contains("is a display name") })
        #expect(synthesisMessages.contains { $0.content.contains("rebecca@example.com") })
        #expect(synthesisMessages.contains { $0.role == .assistant && $0.content.contains(request.input.callID) })
        #expect(synthesisMessages.last?.role == .tool)
        #expect(synthesisMessages.last?.toolCallID == request.input.callID)
        for index in 1 ..< synthesisMessages.count {
            let previous = synthesisMessages[index - 1]
            let current = synthesisMessages[index]
            #expect(!(previous.role == .assistant && current.role == .assistant), "Found consecutive assistant messages at index \(index - 1) and \(index)")
        }
    }

    @Test
    func `Narrated boundary refusal keeps one placeholder and reaches the resumed model`() async throws {
        // Narrated variant of the boundary round: the model's own narration already
        // carries the refused call's placeholder, so the pre-park note must not
        // duplicate it while still persisting the refusal result and carrying the
        // refusal into the continuation park.
        let conversations = ConversationManager()
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let bus = ToolBus(permissionGate: gate)
        await bus.register(tool: makeStructuredReadTool(name: "stub.read", output: "read-ok"))
        let selected = MessageRecipientCandidate(
            displayName: "Rebecca Mackin",
            handle: "rebecca@example.com",
            service: "iMessage",
            source: .contact
        )
        let resolver = AdmissionRecipientResolver(selected: selected)
        let gateway = AdmissionMessagesGateway()
        await bus.register(tool: MessagesSendTool(gateway: gateway, resolver: resolver))
        let round1 = ToolInput.placeholderContent(for: [
            ToolInput(toolName: "stub.read", argumentsJSON: #"{"query":"x"}"#, callID: "call_narr_boundary_read")
        ])
        let round2 = "On it.\n" + ToolInput.placeholderContent(for: [
            ToolInput(
                toolName: "messages.send",
                argumentsJSON: #"{"recipient":"Rebecca","text":"On my way"}"#,
                callID: "call_narr_boundary_send"
            )
        ])
        let synthesis = "I need the exact handle first."
        let llm = StructuredParkLLM(rounds: [
            StructuredParkRound(round1),
            StructuredParkRound(round2),
            StructuredParkRound(synthesis)
        ])
        let orchestrator = Orchestrator(
            conversations: conversations,
            toolBus: bus,
            llm: llm,
            maxToolIterations: 1,
            toolResolver: { _, _ in [] },
            approvalQueue: queue,
            permissionGate: gate
        )
        let sessionID = UUID()
        let parked = try await orchestrator.process(input: UserInput(text: "Text Rebecca", sessionID: sessionID))

        #expect(parked.isParked == true)
        let request = try #require(await queue.list().first)
        #expect(request.toolName == "engine.continue")
        #expect(gateway.sentRecipients.isEmpty)
        let refusedAction = try #require(parked.toolActions.first { $0.callID == "call_narr_boundary_send" })
        #expect(refusedAction.result?.isError == true)
        #expect(refusedAction.result?.content.contains("is a display name") == true)
        let historyWhileParked = await conversations.history(for: sessionID)
        #expect(historyWhileParked.contains { $0.role == .tool && $0.toolCallID == "call_narr_boundary_send" })
        let sendPlaceholderCount = historyWhileParked
            .filter { $0.role == .assistant }
            .flatMap { NormalizedText.splitLines($0.content) }
            .compactMap { ToolInput.parsePlaceholderLine($0)?.callID }
            .filter { $0 == "call_narr_boundary_send" }
            .count
        #expect(sendPlaceholderCount == 1)

        #expect(await queue.decide(id: request.id, approved: true) == true)
        let resumed = try await orchestrator.resumeNarratedApproval(id: request.id, approved: true)
        #expect(resumed?.isParked == false)
        #expect(resumed?.text == synthesis)
        let synthesisMessages = try #require(llm.recordedMessages().last)
        #expect(synthesisMessages.contains { $0.role == .tool && $0.toolCallID == "call_narr_boundary_send" && $0.content.contains("is a display name") })
        #expect(synthesisMessages.contains { $0.content.contains("rebecca@example.com") })
    }

    @Test
    func `Handle-shaped messages.send parks and its grant keys on the canonical handle`() async throws {
        let conversations = ConversationManager()
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let bus = ToolBus(permissionGate: gate)
        let gateway = AdmissionMessagesGateway()
        await bus.register(tool: MessagesSendTool(gateway: gateway))
        let call = ToolInput(
            toolName: "messages.send",
            argumentsJSON: #"{"recipient":"+1 (555) 123-4567","text":"Hi"}"#,
            callID: "call_send_handle"
        )
        let llm = StructuredParkLLM(rounds: [StructuredParkRound("", [call])])
        let orchestrator = Orchestrator(
            conversations: conversations,
            toolBus: bus,
            llm: llm,
            toolResolver: { _, _ in [] },
            approvalQueue: queue,
            permissionGate: gate
        )
        let sessionID = UUID()
        let response = try await orchestrator.process(input: UserInput(text: "Text the number", sessionID: sessionID))

        #expect(response.isParked == true)
        #expect(await queue.count() == 1)
        let pending = try #require(await queue.list().first)
        #expect(pending.toolName == "messages.send")
        #expect(pending.input.argumentsJSON == #"{"recipient":"+1 (555) 123-4567","text":"Hi"}"#)
        #expect(await queue.decide(id: pending.id, approved: true, duration: .oneHour) == true)

        let canonical = ActionDescriptor(toolName: "messages.send", target: "+15551234567")
        let rules = await gate.activeRules()
        #expect(rules.count == 1)
        #expect(rules.first?.toolName == canonical.toolName)
        #expect(rules.first?.scope == .exactTarget(canonical.target))
        let liveTool = try #require(await bus.tool(named: "messages.send"))
        #expect(ActionDescriptor.descriptor(for: call, tool: liveTool) == canonical)
        // A differently spelled call for the same number derives the identical
        // canonical target, so the narrow grant keeps covering without a re-prompt.
        let respelled = ToolInput(
            toolName: "messages.send",
            argumentsJSON: #"{"recipient":"+15551234567","text":"Again"}"#,
            callID: "call_send_respelled"
        )
        let respelledVerdict = await gate.checkPermission(toolCall: respelled, tool: liveTool)
        #expect(respelledVerdict == .allowed)
    }

    @Test
    func `Non-validating gated tool with recipient-shaped args still parks`() async throws {
        let conversations = ConversationManager()
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let bus = ToolBus(permissionGate: gate)
        await bus.register(tool: makeStructuredGatedTool(name: "stub.recipient", output: "must not run"))
        let call = ToolInput(
            toolName: "stub.recipient",
            argumentsJSON: #"{"recipient":"Rebecca"}"#,
            callID: "call_nonvalidating_recipient"
        )
        let llm = StructuredParkLLM(rounds: [StructuredParkRound("", [call])])
        let orchestrator = Orchestrator(
            conversations: conversations,
            toolBus: bus,
            llm: llm,
            toolResolver: { _, _ in [] },
            approvalQueue: queue,
            permissionGate: gate
        )
        let sessionID = UUID()
        let response = try await orchestrator.process(input: UserInput(text: "Run it", sessionID: sessionID))

        #expect(response.isParked == true)
        #expect(await queue.count() == 1)
        let pending = try #require(await queue.list().first)
        #expect(pending.toolName == "stub.recipient")
        #expect(pending.input.argumentsJSON == #"{"recipient":"Rebecca"}"#)
    }
}

// MARK: - Direct bus messages.send approval path

extension StructuredParkTests {
    @Test
    func `Bus approval path refuses a name-shaped send before the handler and mints nothing`() async {
        // The CLI REPL executes directly through `ToolBus`, so it never passes
        // the orchestrator partition. The bus consults the same pre-admission
        // verdict at the approval boundary: a name-shaped send is answered with
        // the resolver's candidates and never reaches the owner's prompt.
        let gate = PermissionGate()
        let bus = ToolBus(permissionGate: gate)
        let selected = MessageRecipientCandidate(
            displayName: "Rebecca Mackin",
            handle: "rebecca@example.com",
            service: "iMessage",
            source: .contact
        )
        let resolver = AdmissionRecipientResolver(selected: selected)
        let gateway = AdmissionMessagesGateway()
        await bus.register(tool: MessagesSendTool(gateway: gateway, resolver: resolver))
        let handlerCalls = BusApprovalCallCounter()
        await bus.setLegacyApprovalHandler { _, _ in
            await handlerCalls.increment()
            return true
        }
        let call = ToolInput(
            toolName: "messages.send",
            argumentsJSON: #"{"recipient":"Rebecca","text":"On my way"}"#,
            callID: "call_bus_send_name"
        )

        let result = await bus.execute(toolCall: call, context: ToolContext(conversationID: UUID()))

        #expect(result.isError == true)
        #expect(result.content.contains("is a display name, not a phone number or email"))
        #expect(await handlerCalls.count == 0)
        #expect(await gate.activeRules().isEmpty == true)
        #expect(gateway.sentRecipients.isEmpty)
        #expect(resolver.queries == ["Rebecca"])
    }

    @Test
    func `Bus approval path lets a malformed send reach the handler but mints no grant`() async {
        // Malformed shapes keep their existing admission path so `execute`
        // reports the argument error, but the CLI-style durable choice stores
        // nothing: the empty target is an invalid send descriptor, never a
        // tool-wide scope that would cover every later recipient.
        let gate = PermissionGate()
        let bus = ToolBus(permissionGate: gate)
        let gateway = AdmissionMessagesGateway()
        await bus.register(tool: MessagesSendTool(gateway: gateway))
        let handlerCalls = BusApprovalCallCounter()
        await bus.setLegacyApprovalHandler { tool, call in
            await handlerCalls.increment()
            let descriptor = ActionDescriptor.descriptor(for: call, tool: tool)
            await gate.grantTrust(for: descriptor, duration: .forever)
            return true
        }

        for arguments in [#"{"text":"hi"}"#, #"{"recipient":123,"text":"hi"}"#] {
            let result = await bus.execute(
                toolCall: ToolInput(
                    toolName: "messages.send",
                    argumentsJSON: arguments,
                    callID: "call_bus_send_malformed"
                ),
                context: ToolContext(conversationID: UUID())
            )
            #expect(result.isError == true)
            #expect(result.content.contains("Invalid messages.send arguments"))
        }
        #expect(await handlerCalls.count == 2)
        #expect(await gate.activeRules().isEmpty == true)
        #expect(await gate.isTrusted(ActionDescriptor(toolName: "messages.send")) == false)
        #expect(gateway.sentRecipients.isEmpty)
    }

    @Test
    func `Bus approval path refuses a grant for an array or alias-bypassed recipient`() async {
        // An array recipient fails the full decode, and a numeric recipient
        // beside a handle-shaped `to` fails it too, so both shapes reach the
        // CLI handler. The generic target path would derive a handle from the
        // array or the `to` alias; the strict send derivation yields the empty
        // target, so the durable choice stores nothing for a call that can
        // never execute.
        let gate = PermissionGate()
        let bus = ToolBus(permissionGate: gate)
        let gateway = AdmissionMessagesGateway()
        await bus.register(tool: MessagesSendTool(gateway: gateway))
        let handlerCalls = BusApprovalCallCounter()
        await bus.setLegacyApprovalHandler { tool, call in
            await handlerCalls.increment()
            let descriptor = ActionDescriptor.descriptor(for: call, tool: tool)
            await gate.grantTrust(for: descriptor, duration: .forever)
            return true
        }

        for arguments in [
            #"{"recipient":["+15551234567"],"text":"Hi"}"#,
            #"{"recipient":123,"to":"+15551234567","text":"Hi"}"#
        ] {
            let result = await bus.execute(
                toolCall: ToolInput(
                    toolName: "messages.send",
                    argumentsJSON: arguments,
                    callID: "call_bus_send_recipient_bypass"
                ),
                context: ToolContext(conversationID: UUID())
            )
            #expect(result.isError == true)
            #expect(result.content.contains("Invalid messages.send arguments"))
        }
        #expect(await handlerCalls.count == 2)
        #expect(await gate.activeRules().isEmpty == true)
        #expect(await gate.isTrusted(ActionDescriptor(toolName: "messages.send", target: "+15551234567")) == false)
        #expect(await gate.isTrusted(ActionDescriptor(toolName: "messages.send")) == false)
        #expect(gateway.sentRecipients.isEmpty)
    }

    @Test
    func `Bus approval path mints the canonical handle grant for a handle-shaped send`() async {
        let gate = PermissionGate()
        let bus = ToolBus(permissionGate: gate)
        let gateway = AdmissionMessagesGateway()
        await bus.register(tool: MessagesSendTool(gateway: gateway))
        let handlerCalls = BusApprovalCallCounter()
        await bus.setLegacyApprovalHandler { tool, call in
            await handlerCalls.increment()
            let descriptor = ActionDescriptor.descriptor(for: call, tool: tool)
            await gate.grantTrust(for: descriptor, duration: .forever)
            return true
        }
        let call = ToolInput(
            toolName: "messages.send",
            argumentsJSON: #"{"recipient":"+1 (555) 123-4567","text":"Hi"}"#,
            callID: "call_bus_send_handle"
        )

        let result = await bus.execute(toolCall: call, context: ToolContext(conversationID: UUID()))

        #expect(result.isError == false)
        #expect(await handlerCalls.count == 1)
        let canonical = ActionDescriptor(toolName: "messages.send", target: "+15551234567")
        let rules = await gate.activeRules()
        #expect(rules.count == 1)
        #expect(rules.first?.toolName == canonical.toolName)
        #expect(rules.first?.scope == .exactTarget(canonical.target))

        // A differently spelled variant of the same number derives the identical
        // canonical target and never prompts again.
        let respelled = ToolInput(
            toolName: "messages.send",
            argumentsJSON: #"{"recipient":"+15551234567","text":"Again"}"#,
            callID: "call_bus_send_respelled"
        )
        let respelledResult = await bus.execute(toolCall: respelled, context: ToolContext(conversationID: UUID()))
        #expect(respelledResult.isError == false)
        #expect(await handlerCalls.count == 1)
        #expect(gateway.sentRecipients == ["+15551234567", "+15551234567"])
    }

    @Test
    func `Operator takeover interrupts execution and parks turn for desktop resume`() async throws {
        let conversations = ConversationManager()
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let bus = ToolBus(permissionGate: gate)

        let takeoverContent = #"{"error":"OPERATOR TAKEOVER: Physical mouse movement detected.","operatorInterrupted":true,"results":[],"stepsCompleted":0,"stepsTotal":1,"success":false}"#
        await bus.register(tool: StructuredParkTool(
            name: "desktop.action",
            output: takeoverContent,
            permissionLevel: .readOnly
        ))
        await bus.register(tool: StructuredParkTool(
            name: "desktop.screenshot",
            output: #"{"screenshot":"data:image/png;base64,fresh_screen"}"#,
            permissionLevel: .readOnly
        ))

        let actionCall = ToolInput(toolName: "desktop.action", argumentsJSON: #"{"actions":[{"action":"click","x":50,"y":50}]}"#, callID: "call_takeover")
        let llm = StructuredParkLLM(rounds: [
            StructuredParkRound("", [actionCall]),
            StructuredParkRound("Resumed and continued.")
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
        let response = try await orchestrator.process(input: UserInput(text: "Click button", sessionID: sessionID))

        #expect(response.isParked == true)
        #expect(await queue.count() == 1)
        let pending = await queue.list()
        #expect(pending.first?.toolName == "desktop.resume")
        #expect(response.text.contains("Desktop automation paused"))

        guard let request = pending.first else {
            Issue.record("Expected pending desktop.resume request")
            return
        }
        let decided = await queue.decide(id: request.id, approved: true)
        #expect(decided == true)

        let resumed = try await orchestrator.resumeNarratedApproval(id: request.id, approved: true)
        #expect(resumed?.isParked == false)
        #expect(resumed?.text == "Resumed and continued.")

        let history = await conversations.history(for: sessionID)
        #expect(history.contains { $0.content.contains("[Fresh Display State]") })
    }
}

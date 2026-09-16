// Rune Weaver Tests — Run lifecycle with approval parking and session linkage.

import Foundation
import os
@testable import RuneWeaverCore
@testable import RuneWeaverServer
import Testing

/// Gated fixture tool for parked lifecycle tests.
private struct LifecycleGatedTool: Tool, Sendable {
    /// Registered tool name.
    let name: String
    /// Canned outcome text.
    let output: String
    /// Whether execution reports failure.
    let shouldFail: Bool
    /// Approval-gated permission level.
    let permissionLevel = PermissionLevel.requiresApproval
    /// Human-readable description.
    var description: String {
        "Fixture gated stub for \(name)."
    }

    /// Empty-object schema.
    let inputSchema = JSONSchema(rawValue: #"{"type":"object"}"#)

    /// Creates a gated stub.
    init(name: String = "stub.write", output: String = "write-ok", shouldFail: Bool = false) {
        self.name = name
        self.output = output
        self.shouldFail = shouldFail
    }

    func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        if shouldFail {
            return .failure("boom", callID: input.callID)
        }
        return .success(output, callID: input.callID)
    }
}

/// Scripted provider replaying canned texts in call order.
private final class LifecycleScriptedLLM: LLMProvider, Sendable {
    /// Stable test model metadata.
    let modelInfo = ModelInfo(name: "lifecycle-fixture", provider: "test", contextLength: 8192)
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

/// Builds an isolated memory engine on a fresh temporary directory.
private func makeLifecycleEngine() throws -> (MemoryEngine, URL) {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let engine = MemoryEngine(
        episodesDBPath: base.appendingPathComponent("episodes.db").path,
        vectorDBPath: base.appendingPathComponent("vectors").path,
        profilePath: base.appendingPathComponent("profile.json").path
    )
    return (engine, base)
}

/// Builds a server context wired for narrated parking with a scripted model.
private func makeLifecycleContext(
    narrated: String,
    synthesis: String,
    shouldFailTool: Bool = false
) async throws -> (ServerContext, UUID, UUID) {
    let (engine, base) = try makeLifecycleEngine()
    _ = base
    let conversations = ConversationManager()
    let gate = PermissionGate()
    let approvals = ApprovalQueue(permissionGate: gate)
    let bus = ToolBus(permissionGate: gate)
    await bus.register(tool: LifecycleGatedTool(shouldFail: shouldFailTool))
    let llm = LifecycleScriptedLLM(texts: [narrated, synthesis])
    let orchestrator = Orchestrator(
        conversations: conversations,
        toolBus: bus,
        llm: llm,
        toolResolver: { _, _ in [] },
        memoryEngine: engine,
        approvalQueue: approvals
    )
    let scheduler = SchedulerStore()
    let runs = RunLogStore()
    let hub = WSHub()
    let context = ServerContext(
        conversations: conversations,
        toolBus: bus,
        orchestrator: orchestrator,
        memoryEngine: engine,
        permissionGate: gate,
        approvals: approvals,
        scheduler: scheduler,
        runs: runs,
        hub: hub
    )
    let sessionID = UUID()
    // Drive one turn that parks on the gated narration.
    _ = try await orchestrator.process(input: UserInput(text: "Do gated work", sessionID: sessionID))
    let pending = await approvals.list().first
    let approvalID = try #require(pending?.id)
    return (context, sessionID, approvalID)
}

@Suite("Run Session Linkage")
struct RunSessionLinkageTests {
    @Test
    func `Append preserves session through entry and update`() async {
        let store = RunLogStore()
        let sessionID = UUID()
        let entry = await store.append(kind: "chat", status: "ok", message: "hello", sessionID: sessionID, response: "hi")
        #expect(entry.sessionID == sessionID)
        #expect(await store.entry(id: entry.id)?.sessionID == sessionID)
        let updated = await store.update(id: entry.id, status: "error")
        #expect(updated?.sessionID == sessionID)
        #expect(updated?.status == "error")
    }

    @Test
    func `List filters by session without mixing conversations`() async {
        let store = RunLogStore()
        let firstSession = UUID()
        let secondSession = UUID()
        _ = await store.append(kind: "chat", status: "ok", message: "first", sessionID: firstSession)
        _ = await store.append(kind: "chat", status: "ok", message: "second", sessionID: secondSession)
        _ = await store.append(kind: "chat", status: "ok", message: "third", sessionID: firstSession)
        let firstOnly = await store.list(limit: 10, sessionID: firstSession)
        #expect(firstOnly.count == 2)
        #expect(firstOnly.allSatisfy { $0.sessionID == firstSession })
        let secondOnly = await store.list(limit: 10, sessionID: secondSession)
        #expect(secondOnly.count == 1)
        #expect(secondOnly.first?.sessionID == secondSession)
        // Combined job plus session filtering narrows to the intersection.
        let jobID = UUID()
        let sessionID = UUID()
        _ = await store.append(kind: "scheduler", status: "ok", message: "job turn", jobID: jobID, sessionID: sessionID)
        _ = await store.append(kind: "scheduler", status: "ok", message: "other job", jobID: UUID(), sessionID: sessionID)
        let narrowed = await store.list(limit: 10, jobID: jobID, sessionID: sessionID)
        #expect(narrowed.count == 1)
        #expect(narrowed.first?.message == "job turn")
    }

    @Test
    func `Session survives SQLite round-trip`() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dbPath = tempDir.appendingPathComponent("runs_session.db").path
        let sessionID = UUID()
        let jobID = UUID()
        let store1 = await RunLogStore.load(capacity: 10, dbPath: dbPath)
        let entry = await store1.append(kind: "scheduler", status: "awaiting_approval", message: "parked", jobID: jobID, sessionID: sessionID, response: "waiting")
        #expect(entry.sessionID == sessionID)
        let store2 = await RunLogStore.load(capacity: 10, dbPath: dbPath)
        let reloaded = await store2.entry(id: entry.id)
        #expect(reloaded?.sessionID == sessionID)
        #expect(reloaded?.jobID == jobID)
        #expect(reloaded?.status == "awaiting_approval")
        let filtered = await store2.list(limit: 10, sessionID: sessionID)
        #expect(filtered.count == 1)
        #expect(filtered.first?.id == entry.id)
    }

    @Test
    func `Codable tolerates payloads written before session tagging`() throws {
        let sessionID = UUID()
        let tagged = RunLogEntry(kind: "chat", status: "ok", message: "hi", response: "hello")
        let taggedWithSession = RunLogEntry(
            jobID: nil,
            sessionID: sessionID,
            kind: "chat",
            status: "awaiting_approval",
            message: "parked",
            response: "waiting"
        )
        let roundTripped = try JSONDecoder().decode(RunLogEntry.self, from: JSONEncoder().encode(taggedWithSession))
        #expect(roundTripped.sessionID == sessionID)
        #expect(roundTripped.status == "awaiting_approval")
        // Payloads omitting the optional session key still decode.
        let sessionlessJSON = try JSONEncoder().encode(tagged)
        var sessionlessObject = try JSONSerialization.jsonObject(with: sessionlessJSON) as? [String: Any] ?? [:]
        sessionlessObject.removeValue(forKey: "sessionID")
        let sessionlessData = try JSONSerialization.data(withJSONObject: sessionlessObject)
        let decodedSessionless = try JSONDecoder().decode(RunLogEntry.self, from: sessionlessData)
        #expect(decodedSessionless.sessionID == nil)
        #expect(decodedSessionless.message == "hi")
    }
}

@Suite("Run Approval Lifecycle")
struct RunApprovalLifecycleTests {
    @Test
    func `Awaiting approval transitions to ok`() async {
        let store = RunLogStore()
        let sessionID = UUID()
        let parked = await store.append(kind: "chat", status: "awaiting_approval", message: "do work", sessionID: sessionID, response: "Waiting for approval")
        #expect(parked.status == "awaiting_approval")
        let resolved = await store.update(id: parked.id, status: "ok", response: "done", totalTokens: 11)
        #expect(resolved?.status == "ok")
        #expect(resolved?.sessionID == sessionID)
        #expect(resolved?.response == "done")
        #expect(resolved?.message == "do work")
    }

    @Test
    func `Awaiting approval transitions to error`() async {
        let store = RunLogStore()
        let sessionID = UUID()
        let parked = await store.append(kind: "chat", status: "awaiting_approval", message: "do work", sessionID: sessionID, response: "Waiting")
        let action = ToolAction(toolName: "stub.write", callID: "c1", argumentsJSON: "{}", result: .failure(toolCallID: "c1", content: "boom"))
        let resolved = await store.update(id: parked.id, status: "error", response: "failed", toolActions: [action])
        #expect(resolved?.status == "error")
        #expect(resolved?.sessionID == sessionID)
        #expect(resolved?.toolActions.first?.didSucceed == false)
    }

    @Test
    func `Awaiting approval transitions to denied`() async {
        let store = RunLogStore()
        let sessionID = UUID()
        let parked = await store.append(kind: "chat", status: "awaiting_approval", message: "do work", sessionID: sessionID, response: "Waiting")
        let resolved = await store.update(id: parked.id, status: "denied", response: "Approval denied for stub.write; not running it.")
        #expect(resolved?.status == "denied")
        #expect(resolved?.sessionID == sessionID)
        #expect(resolved?.response?.lowercased().contains("denied") == true)
    }

    @Test
    func `Resume allow transitions the parked run to ok`() async throws {
        let args = #"{"text":"hi"}"#
        let narrated = ToolInput.placeholderContent(for: [
            ToolInput(toolName: "stub.write", argumentsJSON: args, callID: "call_allow")
        ])
        let (context, sessionID, approvalID) = try await makeLifecycleContext(narrated: narrated, synthesis: "All done.")
        #expect(await isParkedTurn(sessionID: sessionID, context: context) == true)
        let parked = await context.runs.append(
            kind: "chat",
            status: "awaiting_approval",
            message: "Do gated work",
            sessionID: sessionID,
            response: "Waiting for approval to run stub.write."
        )
        #expect(await context.runs.count() == 1)
        #expect(await context.approvals.decide(id: approvalID, approved: true) == true)
        await resumeNarratedApproval(id: approvalID, approved: true, context: context)
        let transitioned = await context.runs.entry(id: parked.id)
        #expect(transitioned?.status == "ok")
        #expect(transitioned?.sessionID == sessionID)
        #expect(transitioned?.response == "All done.")
        #expect(transitioned?.toolActions.count == 1)
        #expect(transitioned?.toolActions.first?.toolName == "stub.write")
        #expect(await context.runs.count() == 1)
        #expect(await isParkedTurn(sessionID: sessionID, context: context) == false)
    }

    @Test
    func `Resume deny transitions the parked run to denied`() async throws {
        let args = #"{"text":"hi"}"#
        let narrated = ToolInput.placeholderContent(for: [
            ToolInput(toolName: "stub.write", argumentsJSON: args, callID: "call_deny")
        ])
        let (context, sessionID, approvalID) = try await makeLifecycleContext(narrated: narrated, synthesis: "unused")
        let parked = await context.runs.append(
            kind: "chat",
            status: "awaiting_approval",
            message: "Do gated work",
            sessionID: sessionID,
            response: "Waiting for approval."
        )
        #expect(await context.approvals.decide(id: approvalID, approved: false) == true)
        await resumeNarratedApproval(id: approvalID, approved: false, context: context)
        let transitioned = await context.runs.entry(id: parked.id)
        #expect(transitioned?.status == "denied")
        #expect(transitioned?.sessionID == sessionID)
        #expect(transitioned?.toolActions.isEmpty == true)
        #expect(transitioned?.response?.lowercased().contains("denied") == true)
        #expect(await context.runs.count() == 1)
    }

    @Test
    func `Resume allow with failing tool transitions to error`() async throws {
        let args = #"{"text":"hi"}"#
        let narrated = ToolInput.placeholderContent(for: [
            ToolInput(toolName: "stub.write", argumentsJSON: args, callID: "call_fail")
        ])
        let (context, sessionID, approvalID) = try await makeLifecycleContext(narrated: narrated, synthesis: "synthesis after failure", shouldFailTool: true)
        let parked = await context.runs.append(
            kind: "chat",
            status: "awaiting_approval",
            message: "Do gated work",
            sessionID: sessionID,
            response: "Waiting."
        )
        #expect(await context.approvals.decide(id: approvalID, approved: true) == true)
        await resumeNarratedApproval(id: approvalID, approved: true, context: context)
        let transitioned = await context.runs.entry(id: parked.id)
        #expect(transitioned?.status == "error")
        #expect(transitioned?.sessionID == sessionID)
        #expect(transitioned?.toolActions.first?.didSucceed == false)
    }

    @Test
    func `Resume without a parked run appends a session-tagged fallback`() async throws {
        let args = #"{"text":"hi"}"#
        let narrated = ToolInput.placeholderContent(for: [
            ToolInput(toolName: "stub.write", argumentsJSON: args, callID: "call_fallback")
        ])
        let (context, sessionID, approvalID) = try await makeLifecycleContext(narrated: narrated, synthesis: "Late synthesis.")
        // No awaiting run exists yet, so the resume must append rather than update.
        #expect(await context.runs.count() == 0)
        #expect(await context.approvals.decide(id: approvalID, approved: true) == true)
        await resumeNarratedApproval(id: approvalID, approved: true, context: context)
        let listed = await context.runs.list(limit: 10, sessionID: sessionID)
        #expect(listed.count == 1)
        #expect(listed.first?.status == "ok")
        #expect(listed.first?.sessionID == sessionID)
        #expect(listed.first?.response == "Late synthesis.")
    }

    @Test
    func `Resolved status distinguishes allow error from deny`() {
        let okResponse = OrchestratorResponse(
            text: "done",
            sessionID: UUID(),
            toolActions: [ToolAction(toolName: "stub.write", callID: "c", argumentsJSON: "{}", result: ToolResult(toolCallID: "c", content: "ok", isError: false))]
        )
        #expect(resolvedResumeStatus(approved: true, resumed: okResponse) == "ok")
        let failedResponse = OrchestratorResponse(
            text: "failed",
            sessionID: UUID(),
            toolActions: [ToolAction(toolName: "stub.write", callID: "c", argumentsJSON: "{}", result: .failure(toolCallID: "c", content: "boom"))]
        )
        #expect(resolvedResumeStatus(approved: true, resumed: failedResponse) == "error")
        let deniedResponse = OrchestratorResponse(text: "Approval denied for stub.write; not running it.", sessionID: UUID(), toolActions: [])
        #expect(resolvedResumeStatus(approved: false, resumed: deniedResponse) == "denied")
        let missingTool = OrchestratorResponse(text: "missing", sessionID: UUID(), toolActions: [])
        #expect(resolvedResumeStatus(approved: true, resumed: missingTool) == "error")
    }
}

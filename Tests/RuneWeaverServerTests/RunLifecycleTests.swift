// Rune Weaver Tests — Run lifecycle with approval parking and session linkage.

import Foundation
import NIOWebSocket
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
    func `Resume allow with failing tool completes run as ok`() async throws {
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
        #expect(transitioned?.status == "ok")
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
    func `Approved scheduler resume advances the framework cursor`() async throws {
        let args = #"{"text":"hi"}"#
        let narrated = ToolInput.placeholderContent(for: [
            ToolInput(toolName: "stub.write", argumentsJSON: args, callID: "call_sched_ok")
        ])
        let (context, sessionID, approvalID) = try await makeLifecycleContext(narrated: narrated, synthesis: "Scheduler done.")
        let job = try await context.scheduler.create(NewSchedulerJob(name: "cursor job", schedule: "* * * * *", prompt: "Do work"))
        let seed = Date(timeIntervalSince1970: 1_700_000_000)
        await context.scheduler.recordSuccessfulRun(id: job.id, endedAt: seed)
        let parked = await context.runs.append(
            kind: "scheduler",
            status: "awaiting_approval",
            message: "Do gated work",
            jobID: job.id,
            sessionID: sessionID,
            response: "Waiting for approval."
        )
        #expect(await context.approvals.decide(id: approvalID, approved: true) == true)
        await resumeNarratedApproval(id: approvalID, approved: true, context: context)
        let transitioned = await context.runs.entry(id: parked.id)
        #expect(transitioned?.status == "ok")
        #expect(transitioned?.kind == "scheduler")
        // A parked-then-approved scheduler turn is a completion, so the
        // framework cursor must move past the seeded watermark.
        let advanced = try #require(await context.scheduler.job(id: job.id)?.lastSuccessfulRunEndedAt)
        #expect(advanced > seed)
    }

    @Test
    func `Denied scheduler resume leaves the framework cursor untouched`() async throws {
        let args = #"{"text":"hi"}"#
        let narrated = ToolInput.placeholderContent(for: [
            ToolInput(toolName: "stub.write", argumentsJSON: args, callID: "call_sched_deny")
        ])
        let (context, sessionID, approvalID) = try await makeLifecycleContext(narrated: narrated, synthesis: "unused")
        let job = try await context.scheduler.create(NewSchedulerJob(name: "denied job", schedule: "* * * * *", prompt: "Do work"))
        let seed = Date(timeIntervalSince1970: 1_700_000_000)
        await context.scheduler.recordSuccessfulRun(id: job.id, endedAt: seed)
        let parked = await context.runs.append(
            kind: "scheduler",
            status: "awaiting_approval",
            message: "Do gated work",
            jobID: job.id,
            sessionID: sessionID,
            response: "Waiting for approval."
        )
        #expect(await context.approvals.decide(id: approvalID, approved: false) == true)
        await resumeNarratedApproval(id: approvalID, approved: false, context: context)
        let transitioned = await context.runs.entry(id: parked.id)
        #expect(transitioned?.status == "denied")
        // Denied turns never complete, so the next run must rescan the window.
        #expect(await context.scheduler.job(id: job.id)?.lastSuccessfulRunEndedAt == seed)
    }

    @Test
    func `Error scheduler resume leaves the framework cursor untouched`() async throws {
        let args = #"{"text":"hi"}"#
        let narrated = ToolInput.placeholderContent(for: [
            ToolInput(toolName: "stub.write", argumentsJSON: args, callID: "call_sched_error")
        ])
        let (context, sessionID, approvalID) = try await makeLifecycleContext(narrated: narrated, synthesis: "unused")
        let job = try await context.scheduler.create(NewSchedulerJob(name: "error job", schedule: "* * * * *", prompt: "Do work"))
        let seed = Date(timeIntervalSince1970: 1_700_000_000)
        await context.scheduler.recordSuccessfulRun(id: job.id, endedAt: seed)
        let parked = await context.runs.append(
            kind: "scheduler",
            status: "awaiting_approval",
            message: "Do gated work",
            jobID: job.id,
            sessionID: sessionID,
            response: "Waiting for approval."
        )
        #expect(await context.approvals.decide(id: approvalID, approved: true) == true)
        // Removing the tool forces the allowed resume onto the missing-tool
        // path, which settles with an empty action list and error status.
        await context.toolBus.unregister(toolNamed: "stub.write")
        await resumeNarratedApproval(id: approvalID, approved: true, context: context)
        let transitioned = await context.runs.entry(id: parked.id)
        #expect(transitioned?.status == "error")
        #expect(await context.scheduler.job(id: job.id)?.lastSuccessfulRunEndedAt == seed)
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
        #expect(resolvedResumeStatus(approved: true, resumed: failedResponse) == "ok")
        let deniedResponse = OrchestratorResponse(text: "Approval denied for stub.write; not running it.", sessionID: UUID(), toolActions: [])
        #expect(resolvedResumeStatus(approved: false, resumed: deniedResponse) == "denied")
        let missingTool = OrchestratorResponse(text: "missing", sessionID: UUID(), toolActions: [])
        #expect(resolvedResumeStatus(approved: true, resumed: missingTool) == "error")
    }
}

/// Recording socket capturing broadcast and direct frames without a live handshake.
///
/// Two instances model a reloaded tab plus its original: broadcast delivery must
/// reach both while requester-scoped replies reach only the requester, so each
/// socket keeps its own frame list for the delivery assertions below.
private actor BroadcastRecordingSocket: WSConnectionSocket {
    /// Frames delivered to this connection.
    private(set) var sent: [String] = []

    /// Records one frame.
    func send(_ text: String) async throws {
        sent.append(text)
    }

    /// Ignored; delivery tests never close the connection.
    func close(code _: WebSocketErrorCode) async throws {}
}

/// Immediate provider serving one finished text chunk.
///
/// A single delta plus the terminal done frame is enough to prove detached
/// delivery: the second socket must see both without re-sending the turn.
private struct BroadcastImmediateProvider: LLMProvider, Sendable {
    /// Stable test model metadata.
    let modelInfo = ModelInfo(name: "broadcast-immediate", provider: "test", contextLength: 2048)
    /// Canned answer text.
    let answer: String

    /// Creates an immediate stub.
    init(answer: String = "hello broadcast") {
        self.answer = answer
    }

    /// Serves the canned answer as one finished stream.
    func chat(messages _: [Message], tools _: [any Tool]) -> AsyncStream<LLMResponse> {
        let text = answer
        return AsyncStream { continuation in
            continuation.yield(LLMResponse(delta: text, isFinished: true, totalTokens: 5))
            continuation.finish()
        }
    }

    /// Unused embeddings stub.
    func embeddings(text _: [String]) async throws -> [[Float]] {
        []
    }
}

/// Delayed provider holding the turn open so cancellation can land mid-flight.
///
/// The pause lives inside the stream producer as an async sleep so the
/// orchestrator suspends instead of blocking its cooperative-pool thread;
/// a synchronous sleep would pin that thread while every broadcast suite
/// runs in parallel and starve the continuations the turn needs to settle.
private struct BroadcastDelayedProvider: LLMProvider, Sendable {
    /// Stable test model metadata.
    let modelInfo = ModelInfo(name: "broadcast-delayed", provider: "test", contextLength: 2048)
    /// Pause holding the turn open.
    let delaySeconds: TimeInterval

    /// Creates a delayed stub.
    init(delaySeconds: TimeInterval = 0.8) {
        self.delaySeconds = delaySeconds
    }

    /// Serves a canned answer after the pause.
    func chat(messages _: [Message], tools _: [any Tool]) -> AsyncStream<LLMResponse> {
        let delay = delaySeconds
        return AsyncStream { continuation in
            Task {
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                continuation.yield(LLMResponse(delta: "slow answer", isFinished: true, totalTokens: 5))
                continuation.finish()
            }
        }
    }

    /// Unused embeddings stub.
    func embeddings(text _: [String]) async throws -> [[Float]] {
        []
    }
}

/// Failing provider reporting a mid-stream LLM error.
///
/// The error chunk routes the turn onto the failed path, proving the terminal
/// error frame broadcasts session-tagged instead of answering one socket.
private struct BroadcastFailingProvider: LLMProvider, Sendable {
    /// Stable test model metadata.
    let modelInfo = ModelInfo(name: "broadcast-failing", provider: "test", contextLength: 2048)
    /// Failure detail surfaced in the error frame.
    let detail: String

    /// Creates a failing stub.
    init(detail: String = "broadcast boom") {
        self.detail = detail
    }

    /// Serves one error chunk.
    func chat(messages _: [Message], tools _: [any Tool]) -> AsyncStream<LLMResponse> {
        let detail = detail
        return AsyncStream { continuation in
            continuation.yield(LLMResponse(delta: "", errorMessage: detail))
            continuation.finish()
        }
    }

    /// Unused embeddings stub.
    func embeddings(text _: [String]) async throws -> [[Float]] {
        []
    }
}

/// Builds an isolated server context for broadcast delivery tests.
///
/// Each test owns its tracker, run store, and hub so the three-slot cap and the
/// frame lists never leak across cases; the temporary directory keeps SQLite off
/// the real engine data directory.
/// - Parameter provider: LLM backend driving the turn under test.
/// - Returns: Isolated context plus its temporary directory for cleanup.
private func makeBroadcastContext(provider: any LLMProvider) throws -> (ServerContext, URL) {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("runeweaver-broadcast-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let dbPath = base.appendingPathComponent("episodes.db").path
    let conversations = ConversationManager()
    let gate = PermissionGate()
    let approvals = ApprovalQueue(permissionGate: gate)
    let bus = ToolBus(permissionGate: gate)
    let memory = MemoryEngine(
        episodesDBPath: dbPath,
        vectorDBPath: base.appendingPathComponent("vectors").path,
        profilePath: base.appendingPathComponent("profile.json").path
    )
    let orchestrator = Orchestrator(
        conversations: conversations,
        toolBus: bus,
        llm: provider,
        memoryEngine: memory
    )
    let context = ServerContext(
        conversations: conversations,
        toolBus: bus,
        orchestrator: orchestrator,
        memoryEngine: memory,
        permissionGate: gate,
        approvals: approvals,
        scheduler: SchedulerStore(),
        runs: RunLogStore(),
        hub: WSHub()
    )
    return (context, base)
}

/// Polls until a condition holds or a short budget expires.
///
/// Turns spawn detached, so the test must wait for the run row plus the fan-out
/// to land instead of asserting immediately after the spawn returns.
/// - Parameter condition: Async predicate to poll.
/// - Returns: True when the predicate held in budget.
private func broadcastWaitUntil(_ condition: @Sendable @escaping () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(8)
    while Date() < deadline {
        if await condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return await condition()
}

/// Reads the frame discriminator without failing on unrelated shapes.
///
/// Run broadcasts carry a different payload than turn frames, so the delivery
/// assertions filter by this type instead of counting every frame on the socket.
/// - Parameter raw: Raw frame text.
/// - Returns: The `type` value, or nil when the payload is not JSON.
private func broadcastFrameType(_ raw: String) -> String? {
    guard let data = raw.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        return nil
    }
    return object["type"] as? String
}

/// Reads the owning session from a frame, when present.
///
/// Every broadcast turn frame carries its session so multiplexed views filter
/// before touching state; requester-scoped replies carry it too, so the direct
/// assertions below can prove the reply belonged to the requesting session.
/// - Parameter raw: Raw frame text.
/// - Returns: The session identifier, or nil when absent or malformed.
private func broadcastFrameSessionID(_ raw: String) -> UUID? {
    guard let data = raw.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let sid = object["sessionID"] as? String
    else {
        return nil
    }
    return UUID(uuidString: sid)
}

@Suite("WebSocket Broadcast Delivery")
struct WebSocketBroadcastDeliveryTests {
    @Test
    func `Second socket receives live deltas plus terminal done`() async throws {
        let (context, base) = try makeBroadcastContext(provider: BroadcastImmediateProvider())
        defer { try? FileManager.default.removeItem(at: base) }
        let firstID = UUID()
        let secondID = UUID()
        let first = BroadcastRecordingSocket()
        let second = BroadcastRecordingSocket()
        _ = await context.hub.add(id: firstID, box: first)
        _ = await context.hub.add(id: secondID, box: second)
        let sessionID = UUID()
        await handleWebSocketChat(
            WSChatMessage(text: "hello detached", sessionID: sessionID),
            connectionID: firstID,
            context: context
        )
        // The turn settles to success on its single audit row.
        let settled = await broadcastWaitUntil {
            await context.runs.list(limit: 10, sessionID: sessionID).first?.status == "ok"
        }
        #expect(settled == true)
        // Both viewers see the same live delta plus the terminal done for the
        // session started elsewhere; a reloaded tab reconciles without re-sending.
        let firstSettled = await broadcastWaitUntil {
            let frames = await first.sent
            return frames.contains { broadcastFrameType($0) == "delta" && broadcastFrameSessionID($0) == sessionID }
                && frames.contains { broadcastFrameType($0) == "done" && broadcastFrameSessionID($0) == sessionID }
        }
        #expect(firstSettled == true)
        let secondSettled = await broadcastWaitUntil {
            let frames = await second.sent
            return frames.contains { broadcastFrameType($0) == "delta" && broadcastFrameSessionID($0) == sessionID }
                && frames.contains { broadcastFrameType($0) == "done" && broadcastFrameSessionID($0) == sessionID }
        }
        #expect(secondSettled == true)
        // The terminal done decodes with its owning session intact.
        let secondFrames = await second.sent
        let doneRaw = try #require(secondFrames.first { broadcastFrameType($0) == "done" })
        let done = try JSONDecoder().decode(WSStreamDone.self, from: Data(doneRaw.utf8))
        #expect(done.sessionID == sessionID)
        #expect(done.text.contains("hello broadcast") == true)
    }

    @Test
    func `Cancelled frame broadcasts to every socket`() async throws {
        let (context, base) = try makeBroadcastContext(provider: BroadcastDelayedProvider())
        defer { try? FileManager.default.removeItem(at: base) }
        let firstID = UUID()
        let secondID = UUID()
        let first = BroadcastRecordingSocket()
        let second = BroadcastRecordingSocket()
        _ = await context.hub.add(id: firstID, box: first)
        _ = await context.hub.add(id: secondID, box: second)
        let sessionID = UUID()
        await handleWebSocketChat(
            WSChatMessage(text: "please cancel me", sessionID: sessionID),
            connectionID: firstID,
            context: context
        )
        #expect(await context.activeTurns.isActive(sessionID: sessionID) == true)
        #expect(await context.activeTurns.cancel(sessionID: sessionID) == true)
        await context.steeringQueue.clear(for: sessionID)
        let settled = await broadcastWaitUntil {
            await context.runs.list(limit: 10, sessionID: sessionID).first?.status == "cancelled"
        }
        #expect(settled == true)
        // Cancellation clears every viewer together, not just the requester.
        let firstGotCancel = await broadcastWaitUntil {
            let frames = await first.sent
            return frames.contains { broadcastFrameType($0) == "cancelled" && broadcastFrameSessionID($0) == sessionID }
        }
        #expect(firstGotCancel == true)
        let secondGotCancel = await broadcastWaitUntil {
            let frames = await second.sent
            return frames.contains { broadcastFrameType($0) == "cancelled" && broadcastFrameSessionID($0) == sessionID }
        }
        #expect(secondGotCancel == true)
    }

    @Test
    func `Error frame broadcasts to every socket`() async throws {
        let (context, base) = try makeBroadcastContext(provider: BroadcastFailingProvider())
        defer { try? FileManager.default.removeItem(at: base) }
        let firstID = UUID()
        let secondID = UUID()
        let first = BroadcastRecordingSocket()
        let second = BroadcastRecordingSocket()
        _ = await context.hub.add(id: firstID, box: first)
        _ = await context.hub.add(id: secondID, box: second)
        let sessionID = UUID()
        await handleWebSocketChat(
            WSChatMessage(text: "please fail", sessionID: sessionID),
            connectionID: firstID,
            context: context
        )
        let settled = await broadcastWaitUntil {
            await context.runs.list(limit: 10, sessionID: sessionID).first?.status == "error"
        }
        #expect(settled == true)
        // The terminal failure reaches every viewer holding the session.
        let firstGotError = await broadcastWaitUntil {
            let frames = await first.sent
            return frames.contains { broadcastFrameType($0) == "error" && broadcastFrameSessionID($0) == sessionID }
        }
        #expect(firstGotError == true)
        let secondGotError = await broadcastWaitUntil {
            let frames = await second.sent
            return frames.contains { broadcastFrameType($0) == "error" && broadcastFrameSessionID($0) == sessionID }
        }
        #expect(secondGotError == true)
        let secondFrames = await second.sent
        let errorRaw = try #require(secondFrames.first { broadcastFrameType($0) == "error" })
        let errorFrame = try JSONDecoder().decode(WSErrorFrame.self, from: Data(errorRaw.utf8))
        #expect(errorFrame.sessionID == sessionID)
        #expect(errorFrame.message.contains("broadcast boom") == true)
    }

    @Test
    func `Validation reply reaches only the requesting socket`() async throws {
        let (context, base) = try makeBroadcastContext(provider: BroadcastImmediateProvider())
        defer { try? FileManager.default.removeItem(at: base) }
        let firstID = UUID()
        let secondID = UUID()
        let first = BroadcastRecordingSocket()
        let second = BroadcastRecordingSocket()
        _ = await context.hub.add(id: firstID, box: first)
        _ = await context.hub.add(id: secondID, box: second)
        let sessionID = UUID()
        await handleWebSocketChat(
            WSChatMessage(text: "   ", sessionID: sessionID),
            connectionID: firstID,
            context: context
        )
        // Empty text never spawns a turn, so no run row exists to broadcast.
        #expect(await context.runs.list(limit: 10, sessionID: sessionID).isEmpty == true)
        let firstFrames = await first.sent
        #expect(firstFrames.count == 1)
        let raw = try #require(firstFrames.first)
        #expect(broadcastFrameType(raw) == "error")
        let errorFrame = try JSONDecoder().decode(WSErrorFrame.self, from: Data(raw.utf8))
        #expect(errorFrame.sessionID == sessionID)
        // The unrelated viewer sees nothing for another session's rejection.
        #expect(await second.sent.isEmpty == true)
    }

    @Test
    func `Busy rejection reaches only the requesting socket`() async throws {
        let (context, base) = try makeBroadcastContext(provider: BroadcastImmediateProvider())
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(ActiveTurnTracker.maxConcurrentTurns == 3)
        let firstSession = UUID()
        let secondSession = UUID()
        let thirdSession = UUID()
        _ = try #require(await context.activeTurns.tryAcquire(sessionID: firstSession, onCancel: {}))
        _ = try #require(await context.activeTurns.tryAcquire(sessionID: secondSession, onCancel: {}))
        _ = try #require(await context.activeTurns.tryAcquire(sessionID: thirdSession, onCancel: {}))
        let firstID = UUID()
        let secondID = UUID()
        let first = BroadcastRecordingSocket()
        let second = BroadcastRecordingSocket()
        _ = await context.hub.add(id: firstID, box: first)
        _ = await context.hub.add(id: secondID, box: second)
        let rejectedSession = UUID()
        await handleWebSocketChat(
            WSChatMessage(text: "over cap", sessionID: rejectedSession),
            connectionID: firstID,
            context: context
        )
        // Past-cap rejection spawns nothing, so no run row and no slot.
        #expect(await context.activeTurns.isActive(sessionID: rejectedSession) == false)
        #expect(await context.runs.list(limit: 10, sessionID: rejectedSession).isEmpty == true)
        let firstFrames = await first.sent
        #expect(firstFrames.count == 1)
        let raw = try #require(firstFrames.first)
        let errorFrame = try JSONDecoder().decode(WSErrorFrame.self, from: Data(raw.utf8))
        #expect(errorFrame.message.contains("Already running 3") == true)
        #expect(errorFrame.sessionID == rejectedSession)
        #expect(await second.sent.isEmpty == true)
        // Drain the held slots so the isolated tracker ends empty.
        for session in await context.activeTurns.runningSessionIDs() {
            _ = await context.activeTurns.cancel(sessionID: session)
        }
    }

    @Test
    func `Cancel acknowledgement reaches only the requesting socket`() async throws {
        let (context, base) = try makeBroadcastContext(provider: BroadcastImmediateProvider())
        defer { try? FileManager.default.removeItem(at: base) }
        let firstID = UUID()
        let secondID = UUID()
        let first = BroadcastRecordingSocket()
        let second = BroadcastRecordingSocket()
        _ = await context.hub.add(id: firstID, box: first)
        _ = await context.hub.add(id: secondID, box: second)
        let sessionID = UUID()
        // No turn runs, so the acknowledgement honestly reports nothing stopped.
        await handleWebSocketCancel(
            WSCancelMessage(sessionID: sessionID),
            connectionID: firstID,
            context: context
        )
        let firstFrames = await first.sent
        #expect(firstFrames.count == 1)
        let raw = try #require(firstFrames.first)
        #expect(broadcastFrameType(raw) == "cancelled")
        let ack = try JSONDecoder().decode(WSCancelledFrame.self, from: Data(raw.utf8))
        #expect(ack.sessionID == sessionID)
        #expect(ack.cancelled == false)
        // The unrelated viewer never sees another session's acknowledgement.
        #expect(await second.sent.isEmpty == true)
    }

    @Test
    func `Broadcast event helper is the single turn-event path`() async throws {
        let (context, base) = try makeBroadcastContext(provider: BroadcastImmediateProvider())
        defer { try? FileManager.default.removeItem(at: base) }
        let firstID = UUID()
        let secondID = UUID()
        let first = BroadcastRecordingSocket()
        let second = BroadcastRecordingSocket()
        _ = await context.hub.add(id: firstID, box: first)
        _ = await context.hub.add(id: secondID, box: second)
        let sessionID = UUID()
        // Every orchestrator event fans out through the shared broadcast helper,
        // so a delta emitted here must land on every connected socket.
        await broadcastWSEventFrame(.textDelta("shared delta"), sessionID: sessionID, context: context)
        let firstGotDelta = await broadcastWaitUntil {
            let frames = await first.sent
            return frames.contains { broadcastFrameType($0) == "delta" && broadcastFrameSessionID($0) == sessionID }
        }
        #expect(firstGotDelta == true)
        let secondGotDelta = await broadcastWaitUntil {
            let frames = await second.sent
            return frames.contains { broadcastFrameType($0) == "delta" && broadcastFrameSessionID($0) == sessionID }
        }
        #expect(secondGotDelta == true)
        let firstFrames = await first.sent
        let raw = try #require(firstFrames.first { broadcastFrameType($0) == "delta" })
        let delta = try JSONDecoder().decode(WSStreamDelta.self, from: Data(raw.utf8))
        #expect(delta.sessionID == sessionID)
        #expect(delta.delta == "shared delta")
    }
}

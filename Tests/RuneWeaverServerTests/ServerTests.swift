// Rune Weaver Tests — HTTP REST API, WebSocket, and scheduler integration tests.

import Foundation
import NIOWebSocket
import os
@testable import RuneWeaverCore
@testable import RuneWeaverServer
import RuneWeaverTools
import Testing
import Vapor

/// Stub LLM replaying one canned answer without the network.
private final class ServerStubProvider: LLMProvider, Sendable {
    /// Canned model metadata.
    let modelInfo = ModelInfo(name: "server-stub", provider: "stub", contextLength: 8192)
    /// Canned answer text.
    private let answer: String

    /// Creates a stub provider.
    /// - Parameter answer: Text served for every turn.
    init(answer: String = "stub answer") {
        self.answer = answer
    }

    /// Serves the canned answer as one finished turn.
    func chat(messages _: [Message], tools _: [any Tool]) -> AsyncStream<LLMResponse> {
        let text = answer
        return AsyncStream { continuation in
            continuation.yield(LLMResponse(delta: text))
            continuation.yield(LLMResponse(delta: "", isFinished: true, totalTokens: 7))
            continuation.finish()
        }
    }

    /// Unused embeddings stub.
    /// - Parameter text: Ignored texts.
    /// - Returns: One empty vector per input.
    func embeddings(text: [String]) async throws -> [[Float]] {
        Array(repeating: [Float](), count: text.count)
    }
}

/// Read-only stub for tool registry tests.
private struct ServerReadStub: Tool, Sendable {
    /// Stable stub name.
    let name = "stub.read"
    /// When the stub should be used.
    let description = "Read-only stub."
    /// Empty-object schema.
    let inputSchema = JSONSchema(rawValue: #"{"type":"object"}"#)
    /// Always allowed.
    let permissionLevel = PermissionLevel.readOnly

    /// Returns a canned success.
    func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        .success("read-ok", callID: input.callID)
    }
}

/// Approval-gated stub for approval flow tests.
private struct ServerWriteStub: Tool, Sendable {
    /// Stable stub name.
    let name = "stub.write"
    /// When the stub should be used.
    let description = "Approval-gated stub."
    /// Empty-object schema.
    let inputSchema = JSONSchema(rawValue: #"{"type":"object"}"#)
    /// Requires approval.
    let permissionLevel = PermissionLevel.requiresApproval

    /// Returns a canned success when approved.
    func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        .success("write-ok", callID: input.callID)
    }
}

/// Lock-guarded flag observed across the tracker cancel boundary.
private final class CancelFlag: Sendable {
    /// Guards the observed bit.
    private let stored = OSAllocatedUnfairLock(initialState: false)

    /// Marks the flag as fired.
    func set() {
        stored.withLock { $0 = true }
    }

    /// Whether the flag has been marked.
    var value: Bool {
        stored.withLock { $0 }
    }
}

/// Makes an isolated memory engine on a fresh temporary directory.
/// - Returns: Engine plus its base directory for cleanup.
private func makeIsolatedEngine() throws -> (MemoryEngine, URL) {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let engine = MemoryEngine(
        episodesDBPath: base.appendingPathComponent("episodes.db").path,
        vectorDBPath: base.appendingPathComponent("vectors").path,
        profilePath: base.appendingPathComponent("profile.json").path
    )
    return (engine, base)
}

@Suite("Server Config")
struct ServerConfigTests {
    @Test
    func `Defaults bind loopback with no auth`() {
        let config = ServerConfig.default
        #expect(config.hostname == "127.0.0.1")
        #expect(config.port == 8082)
        #expect(config.isLoopbackOnly == true)
    }

    @Test
    func `Localhost aliases count as loopback`() {
        #expect(ServerConfig(hostname: "localhost", port: 8082).isLoopbackOnly == true)
        #expect(ServerConfig(hostname: "::1", port: 8082).isLoopbackOnly == true)
        #expect(ServerConfig(hostname: "0.0.0.0", port: 8082).isLoopbackOnly == false)
    }

    @Test
    func `Route paths cover every surface`() {
        #expect(ServerPaths.health == "health")
        #expect(ServerPaths.chat == "chat")
        #expect(ServerPaths.tools == "tools")
        #expect(ServerPaths.toolCall == "call")
        #expect(ServerPaths.memory == "memory")
        #expect(ServerPaths.memorySearch == "search")
        #expect(ServerPaths.memoryFacts == "facts")
        #expect(ServerPaths.approvals == "approvals")
        #expect(ServerPaths.decide == "decide")
        #expect(ServerPaths.scheduler == "scheduler")
        #expect(ServerPaths.jobs == "jobs")
        #expect(ServerPaths.run == "run")
        #expect(ServerPaths.runs == "runs")
        #expect(ServerPaths.websocket == "ws")
        #expect(ServerPaths.archive == "archive")
        #expect(ServerPaths.unarchive == "unarchive")
    }
}

@Suite("Scheduler Store")
struct SchedulerStoreTests {
    @Test
    func `Create lists and fetches a job`() async throws {
        let store = SchedulerStore()
        let job = try await store.create(NewSchedulerJob(name: "morning digest", schedule: "0 8 * * *", prompt: "Summarize mail"))
        #expect(await store.count() == 1)
        let listed = await store.list()
        #expect(listed.count == 1)
        #expect(listed.first?.id == job.id)
        #expect(await store.job(id: job.id)?.name == "morning digest")
        #expect(await store.job(id: job.id)?.enabled == true)
    }

    @Test
    func `Blank fields are rejected`() async {
        let store = SchedulerStore()
        do {
            _ = try await store.create(NewSchedulerJob(name: "  ", schedule: "0 8 * * *", prompt: "hi"))
            Issue.record("Expected invalidField for blank name")
        } catch let error as SchedulerStoreError {
            #expect(error == .invalidField("name must not be empty"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        do {
            _ = try await store.create(NewSchedulerJob(name: "job", schedule: "", prompt: "hi"))
            Issue.record("Expected invalidField for blank schedule")
        } catch let error as SchedulerStoreError {
            #expect(error == .invalidField("job must have a cron schedule or poll trigger"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        do {
            _ = try await store.create(NewSchedulerJob(name: "job", schedule: "0 8 * * *", prompt: "  "))
            Issue.record("Expected invalidField for blank prompt")
        } catch let error as SchedulerStoreError {
            #expect(error == .invalidField("prompt must not be empty"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func `Update toggles and renames`() async throws {
        let store = SchedulerStore()
        let job = try await store.create(NewSchedulerJob(name: "digest", schedule: "0 8 * * *", prompt: "Summarize"))
        let updated = try await store.update(id: job.id, UpdateSchedulerJob(name: "evening digest", enabled: false))
        #expect(updated.name == "evening digest")
        #expect(updated.enabled == false)
        #expect(updated.schedule == "0 8 * * *")
    }

    @Test
    func `Update rejects blanks and unknown jobs`() async throws {
        let store = SchedulerStore()
        let job = try await store.create(NewSchedulerJob(name: "digest", schedule: "0 8 * * *", prompt: "Summarize"))
        do {
            _ = try await store.update(id: job.id, UpdateSchedulerJob(name: " "))
            Issue.record("Expected invalidField for blank rename")
        } catch let error as SchedulerStoreError {
            #expect(error == .invalidField("name must not be empty"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        do {
            _ = try await store.update(id: UUID(), UpdateSchedulerJob(name: "nope"))
            Issue.record("Expected unknownJob")
        } catch let error as SchedulerStoreError {
            guard case .unknownJob = error else {
                Issue.record("Expected unknownJob, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func `Delete removes and reports`() async throws {
        let store = SchedulerStore()
        let job = try await store.create(NewSchedulerJob(name: "digest", schedule: "0 8 * * *", prompt: "Summarize"))
        #expect(await store.delete(id: job.id) == true)
        #expect(await store.delete(id: job.id) == false)
        #expect(await store.job(id: job.id) == nil)
    }

    @Test
    func `Scheduler job pollLimit is clamped between 1 and 50`() async throws {
        let store = SchedulerStore()
        let createdHigh = try await store.create(NewSchedulerJob(
            name: "high limit",
            schedule: "",
            prompt: "Check mail",
            pollAccount: "work",
            pollLimit: 999
        ))
        #expect(createdHigh.pollLimit == 50)
        #expect(await store.job(id: createdHigh.id)?.pollLimit == 50)

        let createdLow = try await store.create(NewSchedulerJob(
            name: "low limit",
            schedule: "",
            prompt: "Check mail",
            pollAccount: "work",
            pollLimit: -10
        ))
        #expect(createdLow.pollLimit == 1)
        #expect(await store.job(id: createdLow.id)?.pollLimit == 1)

        let updated = try await store.update(id: createdHigh.id, UpdateSchedulerJob(pollLimit: 100))
        #expect(updated.pollLimit == 50)
        #expect(await store.job(id: createdHigh.id)?.pollLimit == 50)

        let updatedZero = try await store.update(id: createdHigh.id, UpdateSchedulerJob(pollLimit: 0))
        #expect(updatedZero.pollLimit == 1)
        #expect(await store.job(id: createdHigh.id)?.pollLimit == 1)

        let direct = SchedulerJob(
            name: "direct",
            schedule: "0 8 * * *",
            prompt: "hi",
            pollLimit: 200
        )
        #expect(direct.pollLimit == 50)
    }

    @Test
    func `Scheduler store persistence across re-instantiation`() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dbPath = tempDir.appendingPathComponent("test_scheduler.db").path

        let store1 = await SchedulerStore.load(dbPath: dbPath)
        let job1 = try await store1.create(NewSchedulerJob(
            name: "Morning Check",
            schedule: "0 8 * * *",
            prompt: "Check morning status"
        ))
        #expect(await store1.count() == 1)

        let store2 = await SchedulerStore.load(dbPath: dbPath)
        #expect(await store2.count() == 1)
        let loaded = await store2.job(id: job1.id)
        #expect(loaded?.name == "Morning Check")
        #expect(loaded?.prompt == "Check morning status")

        _ = try await store2.update(id: job1.id, UpdateSchedulerJob(prompt: "Updated prompt"))

        let store3 = await SchedulerStore.load(dbPath: dbPath)
        #expect(await store3.job(id: job1.id)?.prompt == "Updated prompt")

        #expect(await store3.delete(id: job1.id) == true)

        let store4 = await SchedulerStore.load(dbPath: dbPath)
        #expect(await store4.count() == 0)
    }

    @Test
    func `Scheduler store init stays memory-only without bootstrap`() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dbPath = tempDir.appendingPathComponent("test_scheduler_seed.db").path

        let writer = await SchedulerStore.load(dbPath: dbPath)
        _ = try await writer.create(NewSchedulerJob(name: "seeded", schedule: "0 8 * * *", prompt: "Seed"))
        // Plain init never blocks on disk: durable state appears only
        // after an explicit bootstrap.
        let unbootstrapped = SchedulerStore(dbPath: dbPath)
        #expect(await unbootstrapped.count() == 0)
        await unbootstrapped.bootstrap(from: .empty)
        #expect(await unbootstrapped.count() == 1)
    }
}

@Suite("Run Log Store")
struct RunLogStoreTests {
    @Test
    func `Append lists newest first`() async {
        let store = RunLogStore()
        _ = await store.append(kind: "chat", status: "ok", message: "first")
        _ = await store.append(kind: "chat", status: "ok", message: "second")
        let listed = await store.list(limit: 10)
        #expect(listed.count == 2)
        #expect(listed.first?.message == "second")
        #expect(await store.count() == 2)
    }

    @Test
    func `Limit bounds and non-positive returns empty`() async {
        let store = RunLogStore()
        _ = await store.append(kind: "chat", status: "ok", message: "one")
        _ = await store.append(kind: "chat", status: "ok", message: "two")
        #expect(await store.list(limit: 1).count == 1)
        #expect(await store.list(limit: 0).isEmpty == true)
    }

    @Test
    func `Capacity evicts oldest`() async {
        let store = RunLogStore(capacity: 2)
        _ = await store.append(kind: "chat", status: "ok", message: "one")
        _ = await store.append(kind: "chat", status: "ok", message: "two")
        _ = await store.append(kind: "chat", status: "ok", message: "three")
        #expect(await store.count() == 2)
        let listed = await store.list(limit: 10)
        #expect(listed.map(\.message).contains("one") == false)
        #expect(listed.map(\.message).contains("three") == true)
    }

    @Test
    func `Entry lookup and clear`() async {
        let store = RunLogStore()
        let entry = await store.append(kind: "scheduler", status: "ok", message: "job ran", jobID: UUID())
        #expect(await store.entry(id: entry.id)?.id == entry.id)
        #expect(await store.entry(id: UUID()) == nil)
        await store.clear()
        #expect(await store.count() == 0)
    }

    @Test
    func `Persistence survives across store re-instantiation`() async {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dbPath = tempDir.appendingPathComponent("test_runs.db").path

        let store1 = await RunLogStore.load(capacity: 10, dbPath: dbPath)
        _ = await store1.append(kind: "chat", status: "ok", message: "persisted turn 1")
        _ = await store1.append(kind: "scheduler", status: "ok", message: "persisted turn 2")
        #expect(await store1.count() == 2)

        let store2 = await RunLogStore.load(capacity: 10, dbPath: dbPath)
        #expect(await store2.count() == 2)
        let listed = await store2.list(limit: 10)
        #expect(listed.first?.message == "persisted turn 2")
        #expect(listed.last?.message == "persisted turn 1")
    }

    @Test
    func `Delete and clear remove entries from memory and SQLite`() async {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dbPath = tempDir.appendingPathComponent("test_runs_delete.db").path

        let store = await RunLogStore.load(capacity: 10, dbPath: dbPath)
        let entry1 = await store.append(kind: "chat", status: "ok", message: "first")
        let entry2 = await store.append(kind: "scheduler", status: "ok", message: "second")
        #expect(await store.count() == 2)

        // Delete single entry
        await store.delete(id: entry1.id)
        #expect(await store.count() == 1)
        #expect(await store.entry(id: entry1.id) == nil)
        #expect(await store.entry(id: entry2.id) != nil)

        // Verify deletion persists across reload
        let reloaded = await RunLogStore.load(capacity: 10, dbPath: dbPath)
        #expect(await reloaded.count() == 1)
        #expect(await reloaded.entry(id: entry1.id) == nil)
        #expect(await reloaded.entry(id: entry2.id) != nil)

        // Clear all entries and verify across reload
        await reloaded.clear()
        #expect(await reloaded.count() == 0)

        let reloadedEmpty = await RunLogStore.load(capacity: 10, dbPath: dbPath)
        #expect(await reloadedEmpty.count() == 0)
    }

    @Test
    func `Clear preserves running runs in memory and SQLite`() async {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dbPath = tempDir.appendingPathComponent("test_runs_clear_running.db").path

        let store = await RunLogStore.load(capacity: 10, dbPath: dbPath)
        let runningEntry = await store.append(kind: "chat", status: "running", message: "in flight turn")
        _ = await store.append(kind: "chat", status: "ok", message: "finished turn")
        _ = await store.append(kind: "scheduler", status: "error", message: "failed job")
        #expect(await store.count() == 3)

        await store.clear()
        #expect(await store.count() == 1)
        #expect(await store.entry(id: runningEntry.id) != nil)

        // Verify across reload that running entry is preserved on disk
        let reloaded = await RunLogStore.load(capacity: 10, dbPath: dbPath)
        #expect(await reloaded.count() == 1)
        #expect(await reloaded.entry(id: runningEntry.id)?.id == runningEntry.id)
    }

    @Test
    func `Startup crash recovery reconciles running runs and unfinished tool actions`() async {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dbPath = tempDir.appendingPathComponent("test_runs_recovery.db").path

        let store1 = await RunLogStore.load(capacity: 10, dbPath: dbPath)
        let unclosedAction = ToolAction(
            toolName: "files.read",
            callID: "call-crash-1",
            argumentsJSON: "{\"path\":\"foo.swift\"}",
            result: nil,
            roundIndex: 0
        )
        let crashedEntry = await store1.append(
            kind: "chat",
            status: "running",
            message: "in-flight prompt before crash",
            toolActions: [unclosedAction]
        )
        #expect(crashedEntry.status == "running")
        #expect(crashedEntry.toolActions.first?.result == nil)

        // Simulate app crash / restart by re-bootstrapping store2
        let store2 = await RunLogStore.load(capacity: 10, dbPath: dbPath)
        let reloadedRuns = await store2.list(limit: 10)
        #expect(reloadedRuns.count == 1)
        let recovered = reloadedRuns.first
        #expect(recovered?.id == crashedEntry.id)
        #expect(recovered?.status == "interrupted")
        #expect(recovered?.toolActions.count == 1)
        #expect(recovered?.toolActions.first?.result != nil)
        #expect(recovered?.toolActions.first?.result?.isError == true)
        #expect(recovered?.toolActions.first?.result?.content.contains("interrupted") == true)
    }
}

@Suite("Approval Queue")
struct ApprovalQueueTests {
    @Test
    func `Enqueue lists pending`() async {
        let store = ApprovalQueue()
        let request = await store.enqueue(
            toolName: "stub.write",
            description: "Write stub.",
            input: ToolInput(toolName: "stub.write", argumentsJSON: "{}")
        )
        #expect(await store.count() == 1)
        #expect(await store.request(id: request.id)?.toolName == "stub.write")
        #expect(await store.list().count == 1)
    }

    @Test
    func `Decide resolves waiter approved`() async {
        let gate = PermissionGate()
        let store = ApprovalQueue(permissionGate: gate)
        let request = await store.enqueue(
            toolName: "stub.write",
            description: "Write stub.",
            input: ToolInput(toolName: "stub.write", argumentsJSON: #"{"path":"/tmp/a"}"#)
        )
        async let waiting = await store.waitForDecision(id: request.id)
        let resolved = await store.decide(id: request.id, approved: true, duration: .oneHour)
        #expect(resolved == true)
        let decision = await waiting
        #expect(decision.approved == true)
        #expect(await store.count() == 0)
        let descriptor = ActionDescriptor(toolName: "stub.write", target: "/tmp/a")
        #expect(await gate.isTrusted(descriptor) == true)
    }

    @Test
    func `ThisTime approval records no trust`() async {
        let gate = PermissionGate()
        let store = ApprovalQueue(permissionGate: gate)
        let request = await store.enqueue(
            toolName: "stub.write",
            description: "Write stub.",
            input: ToolInput(toolName: "stub.write", argumentsJSON: #"{"path":"/tmp/b"}"#)
        )
        #expect(await store.decide(id: request.id, approved: true, duration: .thisTime) == true)
        let descriptor = ActionDescriptor(toolName: "stub.write", target: "/tmp/b")
        #expect(await gate.isTrusted(descriptor) == false)
    }

    @Test
    func `Decide denied resolves waiter denied`() async {
        let store = ApprovalQueue()
        let request = await store.enqueue(
            toolName: "stub.write",
            description: "Write stub.",
            input: ToolInput(toolName: "stub.write", argumentsJSON: "{}")
        )
        async let waiting = await store.waitForDecision(id: request.id)
        #expect(await store.decide(id: request.id, approved: false) == true)
        #expect(await waiting.approved == false)
    }

    @Test
    func `Unknown decide and wait deny without suspending`() async {
        let store = ApprovalQueue()
        #expect(await store.decide(id: UUID(), approved: true) == false)
        #expect(await store.waitForDecision(id: UUID()).approved == false)
    }

    @Test
    func `Early decision parks for later waiter`() async {
        let store = ApprovalQueue()
        let request = await store.enqueue(
            toolName: "stub.write",
            description: "Write stub.",
            input: ToolInput(toolName: "stub.write", argumentsJSON: "{}")
        )
        #expect(await store.decide(id: request.id, approved: true, duration: .thisTime) == true)
        #expect(await store.waitForDecision(id: request.id).approved == true)
    }
}

@Suite("Server DTOs")
struct ServerDTOTests {
    @Test
    func `ChatRequest resolves defaults`() {
        let request = ChatRequest(text: "hello")
        #expect(request.resolvedSource == "api")
        #expect(ChatRequest(text: "hi", source: "  ").resolvedSource == "api")
        #expect(ChatRequest(text: "hi", source: "dashboard").resolvedSource == "dashboard")
    }

    @Test
    func `ToolCallRequest resolves blanks`() {
        let request = ToolCallRequest(toolName: "stub.read")
        #expect(request.resolvedArgumentsJSON == "{}")
        #expect(request.resolvedCallID.isEmpty == false)
        #expect(ToolCallRequest(toolName: "x", argumentsJSON: "  ").resolvedArgumentsJSON == "{}")
        #expect(ToolCallRequest(toolName: "x", argumentsJSON: #"{"q":"hi"}"#).resolvedArgumentsJSON == #"{"q":"hi"}"#)
    }

    @Test
    func `StoreFact and decision requests resolve`() {
        #expect(StoreFactRequest(content: "fact").resolvedSource == "api")
        #expect(StoreFactRequest(content: "fact", source: "chat").resolvedSource == "chat")
        #expect(ApprovalDecisionRequest(approved: true).resolvedDuration == .thisTime)
        #expect(ApprovalDecisionRequest(approved: true, duration: .forever).resolvedDuration == .forever)
        #expect(WSDecisionMessage(id: UUID(), approved: true).resolvedDuration == .thisTime)
        // An omitted scope stays nil so the gate derives the request's own
        // target instead of silently minting tool-wide trust.
        #expect(ApprovalDecisionRequest(approved: true).resolvedScope == nil)
        #expect(ApprovalDecisionRequest(approved: true, scope: AccessScopeDTO(kind: .tool)).resolvedScope == .toolWide)
    }

    @Test
    func `Health defaults to green`() {
        let health = HealthResponse()
        #expect(health.status == "green")
        #expect(health.version == ServerPaths.apiVersion)
    }

    @Test
    func `ToolInfo maps permission levels`() {
        #expect(ToolInfo(ServerReadStub()).permissionLevel == "readOnly")
        #expect(ToolInfo(ServerWriteStub()).permissionLevel == "requiresApproval")
    }

    @Test
    func `Chat and decision DTOs round-trip`() throws {
        let sessionID = UUID()
        let chat = ChatRequest(text: "hello", sessionID: sessionID, source: "api")
        let chatData = try JSONEncoder().encode(chat)
        #expect(try JSONDecoder().decode(ChatRequest.self, from: chatData) == chat)
        let decisionID = UUID()
        let decision = WSDecisionMessage(id: decisionID, approved: true, duration: .oneDay)
        let decisionData = try JSONEncoder().encode(decision)
        #expect(try JSONDecoder().decode(WSDecisionMessage.self, from: decisionData) == decision)
    }

    @Test
    func `Settings response carries live scheduler default`() throws {
        var config = RuneWeaverConfig.default
        config.scheduler.defaultMaxToolIterations = 25
        let response = SettingsResponse(config: config, configPath: "/test/config.toml")
        #expect(response.schedulerMaxToolIterations == config.scheduler.defaultMaxToolIterations)
        #expect(response.schedulerMaxToolIterations == 25)
        let decoded = try JSONDecoder().decode(SettingsResponse.self, from: JSONEncoder().encode(response))
        #expect(decoded.schedulerMaxToolIterations == 25)
        // Payloads written before the scheduler key still decode at the scheduler default.
        let legacy = try JSONDecoder().decode(
            SettingsResponse.self,
            from: Data(#"{"engineName":"Rune Weaver","defaultProvider":"mlx"}"#.utf8)
        )
        #expect(legacy.schedulerMaxToolIterations == 25)
    }

    @Test
    func `WebSocket inbound classification`() throws {
        let chatText = try String(data: JSONEncoder().encode(WSChatMessage(text: "hello")), encoding: .utf8) ?? ""
        guard case .chat = WSInboundKind.classify(chatText) else {
            Issue.record("Expected chat kind")
            return
        }
        let decisionID = UUID()
        let decisionText = try String(data: JSONEncoder().encode(WSDecisionMessage(id: decisionID, approved: false)), encoding: .utf8) ?? ""
        guard case let .decision(message) = WSInboundKind.classify(decisionText) else {
            Issue.record("Expected decision kind")
            return
        }
        #expect(message.id == decisionID)
        let cancelID = UUID()
        let cancelText = "{\"type\":\"cancel\",\"sessionID\":\"\(cancelID.uuidString)\"}"
        guard case let .cancel(cancelMsg) = WSInboundKind.classify(cancelText) else {
            Issue.record("Expected cancel kind")
            return
        }
        #expect(cancelMsg.sessionID == cancelID)
        // A payload carrying both chat text and an approval decision must
        // classify as a decision; preferring chat would drop the decision and
        // leave the request pending forever.
        let overlappedID = UUID()
        let overlappedText = "{\"text\":\"please allow this\",\"id\":\"\(overlappedID.uuidString)\",\"approved\":true}"
        guard case let .decision(overlapped) = WSInboundKind.classify(overlappedText) else {
            Issue.record("Expected decision kind for overlapped payload")
            return
        }
        #expect(overlapped.id == overlappedID)
        #expect(overlapped.approved == true)
        #expect(WSInboundKind.classify("not json {{{") == .unknown)
        #expect(WSInboundKind.classify("{}") == .unknown)
    }

    @Test
    func `WebSocket streaming splits deltas`() {
        #expect(WSStreaming.deltas(for: "") == [])
        #expect(WSStreaming.deltas(for: "abc", chunkSize: 0) == ["abc"])
        let deltas = WSStreaming.deltas(for: "abcdef", chunkSize: 2)
        #expect(deltas == ["ab", "cd", "ef"])
        #expect(deltas.joined() == "abcdef")
    }

    @Test
    func `Approval prompt, tool streaming, and cancel frames round-trip`() throws {
        let request = PermissionRequest(
            toolName: "stub.write",
            description: "Write stub.",
            input: ToolInput(toolName: "stub.write", argumentsJSON: "{}")
        )
        let prompt = WSApprovalPrompt(request: request)
        #expect(try JSONDecoder().decode(WSApprovalPrompt.self, from: JSONEncoder().encode(prompt)) == prompt)
        #expect(try JSONDecoder().decode(WSStreamDelta.self, from: JSONEncoder().encode(WSStreamDelta(delta: "hi"))) == WSStreamDelta(delta: "hi"))
        let doneID = UUID()
        let done = WSStreamDone(text: "done", sessionID: doneID, totalTokens: 100, modelName: "test-model")
        #expect(try JSONDecoder().decode(WSStreamDone.self, from: JSONEncoder().encode(done)) == done)

        let toolStart = WSToolStartFrame(toolName: "email.search", callID: "c1", argumentsJSON: "{\"limit\":1}")
        #expect(try JSONDecoder().decode(WSToolStartFrame.self, from: JSONEncoder().encode(toolStart)) == toolStart)

        let toolEnd = WSToolEndFrame(toolName: "email.search", callID: "c1", result: ToolResult(toolCallID: "c1", content: "ok", isError: false))
        #expect(try JSONDecoder().decode(WSToolEndFrame.self, from: JSONEncoder().encode(toolEnd)) == toolEnd)

        let cancelMsg = WSCancelMessage(sessionID: doneID)
        #expect(try JSONDecoder().decode(WSCancelMessage.self, from: JSONEncoder().encode(cancelMsg)) == cancelMsg)
        // Encoded cancel frames carry the explicit discriminator and
        // classify back to `.cancel` with no hand-built JSON.
        let cancelText = try String(data: JSONEncoder().encode(cancelMsg), encoding: .utf8) ?? ""
        #expect(cancelText.contains("\"type\":\"cancel\""))
        guard case let .cancel(roundTripped) = WSInboundKind.classify(cancelText) else {
            Issue.record("Expected cancel kind from encoded WSCancelMessage")
            return
        }
        #expect(roundTripped == cancelMsg)

        let cancelledFrame = WSCancelledFrame(sessionID: doneID)
        #expect(try JSONDecoder().decode(WSCancelledFrame.self, from: JSONEncoder().encode(cancelledFrame)) == cancelledFrame)
        // The flag distinguishes real aborts from idle cancels for multiplexed views.
        let idleFrame = WSCancelledFrame(sessionID: doneID, cancelled: false)
        #expect(try JSONDecoder().decode(WSCancelledFrame.self, from: JSONEncoder().encode(idleFrame)) == idleFrame)
        let cancelledWithoutFlag = "{\"type\":\"cancelled\",\"sessionID\":\"\(doneID.uuidString)\"}"
        #expect(try JSONDecoder().decode(WSCancelledFrame.self, from: Data(cancelledWithoutFlag.utf8)) == cancelledFrame)
    }

    @Test
    func `ActiveTurnTracker registers cancels and unregisters tasks`() async {
        let tracker = ActiveTurnTracker()
        let sid = UUID()
        let task = Task {
            _ = try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        let registration = await tracker.register(sessionID: sid, task: task)
        #expect(registration.replaced == false)
        let cancelled = await tracker.cancel(sessionID: sid)
        #expect(cancelled == true)
        #expect(task.isCancelled == true)
        let cancelAgain = await tracker.cancel(sessionID: sid)
        #expect(cancelAgain == false)
    }

    @Test
    func `ActiveTurnTracker supersedes with cancel and token-checked unregister`() async {
        let tracker = ActiveTurnTracker()
        let sid = UUID()
        let first = Task {
            _ = try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        let firstRegistration = await tracker.register(sessionID: sid, task: first)
        #expect(firstRegistration.replaced == false)
        let second = Task {
            _ = try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        let secondRegistration = await tracker.register(sessionID: sid, task: second)
        // The second turn reports the replacement and cooperatively
        // cancels the first handle instead of leaking it.
        #expect(secondRegistration.replaced == true)
        #expect(first.isCancelled == true)
        #expect(second.isCancelled == false)
        // A stale completion must not delete the newer registration.
        await tracker.unregister(sessionID: sid, token: firstRegistration.token)
        #expect(await tracker.cancel(sessionID: sid) == true)
        #expect(second.isCancelled == true)
        await tracker.unregister(sessionID: sid, token: secondRegistration.token)
        #expect(await tracker.cancel(sessionID: sid) == false)
    }

    @Test
    func `ActiveTurnTracker idle cancel reports false without poisoning next turn`() async {
        let tracker = ActiveTurnTracker()
        let sid = UUID()
        // Stray cancel for an unknown session reports false and leaves no
        // mark, so the next genuine turn starts clean instead of aborting.
        #expect(await tracker.cancel(sessionID: sid) == false)
        let firstCancelled = CancelFlag()
        let first = await tracker.register(sessionID: sid, onCancel: { firstCancelled.set() })
        #expect(firstCancelled.value == false)
        await tracker.unregister(sessionID: sid, token: first.token)
        let secondCancelled = CancelFlag()
        let second = await tracker.register(sessionID: sid, onCancel: { secondCancelled.set() })
        #expect(secondCancelled.value == false)
        await tracker.unregister(sessionID: sid, token: second.token)
    }

    @Test
    func `ActiveTurnTracker pending bridge fires only for recently registered sessions`() async {
        let tracker = ActiveTurnTracker()
        let sid = UUID()
        // Establish liveness, then finish the turn so no entry remains.
        let setup = await tracker.register(sessionID: sid, onCancel: {})
        await tracker.unregister(sessionID: sid, token: setup.token)
        // Cancel within the race window still bridges to the next register.
        #expect(await tracker.cancel(sessionID: sid) == false)
        let bridged = CancelFlag()
        let first = await tracker.register(sessionID: sid, onCancel: { bridged.set() })
        #expect(bridged.value == true)
        await tracker.unregister(sessionID: sid, token: first.token)
        // The mark is consumed once, so a later turn starts clean.
        let later = CancelFlag()
        let second = await tracker.register(sessionID: sid, onCancel: { later.set() })
        #expect(later.value == false)
        await tracker.unregister(sessionID: sid, token: second.token)
    }

    @Test
    func `Cancellation rollback restores messages and summary without duplication`() async {
        let manager = ConversationManager()
        let sid = UUID()
        _ = await manager.ensureSession(id: sid)
        await manager.append(Message(role: .user, content: "hello"), to: sid)
        await manager.append(Message(role: .assistant, content: "hi there"), to: sid)
        _ = await manager.summarize(sessionID: sid, keeping: 1)
        let snapshot = await manager.rollbackSnapshot(for: sid)
        #expect(snapshot != nil)
        #expect(snapshot?.summary?.isEmpty == false)
        // Simulate a cancelled turn's appends on top of the snapshot.
        await manager.append(Message(role: .user, content: "cancelled question"), to: sid)
        await manager.append(Message(role: .assistant, content: "partial answer"), to: sid)
        if let snapshot {
            await manager.restoreRollbackSnapshot(snapshot)
        }
        let restored = await manager.session(id: sid)
        #expect(restored?.messages.count == snapshot?.messages.count)
        #expect(restored?.summary == snapshot?.summary)
        // The restored history carries exactly one synthetic summary
        // message: no duplicated prefix, no lost summary.
        let synthetic = await manager.history(for: sid).filter {
            $0.role == .system && $0.content.hasPrefix(Message.rollingSummaryPrefix)
        }
        #expect(synthetic.count == 1)
    }

    @Test
    func `Structured tool actions survive brackets in arguments`() async {
        let manager = ConversationManager()
        let sid = UUID()
        _ = await manager.ensureSession(id: sid)
        await manager.append(Message(role: .user, content: "check mail"), to: sid)
        let call = ToolInput(
            toolName: "email.search",
            argumentsJSON: #"{"filter":"a]b","ids":["x]"}"#,
            callID: "call-brackets"
        )
        await manager.append(
            Message(role: .assistant, content: ToolInput.placeholderContent(for: [call])),
            to: sid
        )
        await manager.append(Message(role: .tool, content: "1 found", toolCallID: "call-brackets"), to: sid)
        await manager.append(Message(role: .assistant, content: "You have one match."), to: sid)
        let grouped = await manager.toolActionsByMessage(for: sid)
        let actions = grouped.values.flatMap(\.self)
        #expect(actions.count == 1)
        #expect(actions.first?.toolName == "email.search")
        #expect(actions.first?.argumentsJSON == #"{"filter":"a]b","ids":["x]"}"#)
        #expect(actions.first?.result?.content == "1 found")
        let response = SessionToolActionsResponse(
            sessionID: sid,
            actions: grouped.map { SessionMessageToolActions(messageID: $0.key, actions: $0.value) }
        )
        #expect(response.count == 1)
        #expect(response.sessionID == sid)
    }
}

@Suite("Server Engine Flow")
struct ServerEngineFlowTests {
    @Test
    func `Chat turn appends a run log`() async throws {
        let (engine, base) = try makeIsolatedEngine()
        defer { try? FileManager.default.removeItem(at: base) }
        let conversations = ConversationManager()
        let bus = ToolBus()
        let orchestrator = Orchestrator(
            conversations: conversations,
            toolBus: bus,
            llm: ServerStubProvider(answer: "hello back"),
            memoryEngine: engine
        )
        let runs = RunLogStore()
        let sessionID = UUID()
        let response = try await orchestrator.process(input: UserInput(text: "hello", sessionID: sessionID, source: "api"))
        await runs.append(kind: "chat", status: "ok", message: "hello")
        #expect(response.text == "hello back")
        #expect(response.sessionID == sessionID)
        #expect(await runs.count() == 1)
        #expect(await runs.list(limit: 10).first?.kind == "chat")
    }

    @Test
    func `Memory search and facts round-trip`() async throws {
        let (engine, base) = try makeIsolatedEngine()
        defer { try? FileManager.default.removeItem(at: base) }
        try await engine.storeProfileFact(content: "My dog is named Biscuit", source: "api")
        try await engine.storeEpisodic(content: "Discussed brass compasses", sessionID: UUID())
        let search = try await engine.recall(query: "Biscuit compasses", limit: 10)
        #expect(search.isEmpty == false)
        let response = MemorySearchResponse(query: "Biscuit compasses", memories: search)
        #expect(response.count == search.count)
        let profile = await engine.getUserProfile()
        let facts = await FactsResponse(
            facts: profile.facts,
            preferences: profile.preferences,
            semanticCount: engine.semanticFactCount(),
            episodeCount: engine.episodeCount()
        )
        #expect(facts.facts.contains { $0.content.contains("Biscuit") })
        #expect(facts.episodeCount == 1)
    }

    @Test
    func `Tool call executes through the bus`() async {
        let bus = ToolBus(permissionGate: PermissionGate())
        await bus.register(tool: ServerReadStub())
        let body = ToolCallRequest(toolName: "stub.read", argumentsJSON: "{}")
        let result = await bus.execute(
            toolCall: ToolInput(
                toolName: body.toolName,
                argumentsJSON: body.resolvedArgumentsJSON,
                callID: body.resolvedCallID
            ),
            context: ToolContext(conversationID: UUID())
        )
        #expect(result.isError == false)
        #expect(result.content == "read-ok")
    }

    @Test
    func `Scheduler job runs and logs`() async throws {
        let (engine, base) = try makeIsolatedEngine()
        defer { try? FileManager.default.removeItem(at: base) }
        let conversations = ConversationManager()
        let bus = ToolBus()
        let orchestrator = Orchestrator(
            conversations: conversations,
            toolBus: bus,
            llm: ServerStubProvider(answer: "digest done"),
            memoryEngine: engine
        )
        let scheduler = SchedulerStore()
        let runs = RunLogStore()
        let job = try await scheduler.create(NewSchedulerJob(name: "digest", schedule: "0 8 * * *", prompt: "Summarize mail"))
        let response = try await orchestrator.process(input: UserInput(text: job.prompt, sessionID: UUID(), source: "scheduler"))
        await runs.append(kind: "scheduler", status: "ok", message: job.prompt, jobID: job.id)
        #expect(response.text == "digest done")
        let logged = await runs.list(limit: 10)
        #expect(logged.first?.jobID == job.id)
        #expect(logged.first?.kind == "scheduler")
    }

    @Test
    func `Disabled scheduler job is not runnable`() async throws {
        let scheduler = SchedulerStore()
        let job = try await scheduler.create(NewSchedulerJob(name: "digest", schedule: "0 8 * * *", prompt: "Summarize", enabled: false))
        #expect(await scheduler.job(id: job.id)?.enabled == false)
    }

    @Test
    func `Scheduler store enforces maxJobs capacity limit`() async throws {
        let scheduler = SchedulerStore()
        for i in 0 ..< SchedulerStore.maxJobs {
            try await scheduler.create(NewSchedulerJob(name: "job-\(i)", schedule: "0 8 * * *", prompt: "Prompt \(i)"))
        }
        #expect(await scheduler.count() == SchedulerStore.maxJobs)
        do {
            try await scheduler.create(NewSchedulerJob(name: "job-overflow", schedule: "0 8 * * *", prompt: "Overflow"))
            Issue.record("Expected capacity error")
        } catch let error as SchedulerStoreError {
            #expect(error == .invalidField("Job limit reached (\(SchedulerStore.maxJobs)). Delete existing jobs before creating new ones."))
        }
    }

    @Test
    func `Run log tracks in-progress status and updates to completion`() async throws {
        let (_, base) = try makeIsolatedEngine()
        defer { try? FileManager.default.removeItem(at: base) }
        let dbPath = base.appendingPathComponent("episodes.db").path
        let runs = await RunLogStore.load(dbPath: dbPath)

        let initial = await runs.append(
            kind: "scheduler",
            status: "running",
            message: "Running report",
            jobID: UUID(),
            durationMs: 0
        )
        #expect(initial.status == "running")

        let inProgressList = await runs.list(limit: 10)
        #expect(inProgressList.first?.status == "running")

        let updated = await runs.update(
            id: initial.id,
            status: "ok",
            response: "Report completed successfully",
            totalTokens: 128,
            durationMs: 420
        )
        #expect(updated?.status == "ok")
        #expect(updated?.response == "Report completed successfully")
        #expect(updated?.totalTokens == 128)
        #expect(updated?.durationMs == 420)

        // Read back from fresh store to verify SQLite persistence
        let freshRuns = await RunLogStore.load(dbPath: dbPath)
        let persistedList = await freshRuns.list(limit: 10)
        #expect(persistedList.first?.id == initial.id)
        #expect(persistedList.first?.status == "ok")
        #expect(persistedList.first?.response == "Report completed successfully")
    }

    @Test
    func `Conversation session preserves source attribute`() async throws {
        let (_, base) = try makeIsolatedEngine()
        defer { try? FileManager.default.removeItem(at: base) }
        let dbPath = base.appendingPathComponent("episodes.db").path
        let manager = ConversationManager(episodesDBPath: dbPath)

        let sessionID = UUID()
        _ = await manager.ensureSession(id: sessionID, title: "Daily Digest", source: "scheduler")
        await manager.append(Message(role: .user, content: "Start run"), to: sessionID)

        let sessions = await manager.listSessions()
        let summary = sessions.first { $0.id == sessionID }
        #expect(summary?.source == "scheduler")
        #expect(summary?.title == "Daily Digest")

        // Read back from a fresh manager instance to ensure SQLite roundtrip
        let freshManager = ConversationManager(episodesDBPath: dbPath)
        let freshSessions = await freshManager.listSessions()
        let freshSummary = freshSessions.first { $0.id == sessionID }
        #expect(freshSummary?.source == "scheduler")
        #expect(freshSummary?.title == "Daily Digest")
    }
}

@Suite("Tool State Store")
struct ToolStateStoreTests {
    @Test
    func `Persist and restore across store reload`() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dbPath = tempDir.appendingPathComponent("episodes.db").path

        let writer = ToolStateStore(dbPath: dbPath)
        await writer.setEnabled(toolName: "stub.read", enabled: false)
        // The store stays name-agnostic on purpose: memory tools toggle
        // through the same rows as every other registered tool.
        await writer.setEnabled(toolName: "memories.store", enabled: false)
        await writer.setEnabled(toolName: "stub.write", enabled: true)
        let first = await writer.loadAll()
        #expect(first["stub.read"] == false)
        #expect(first["memories.store"] == false)
        #expect(first["stub.write"] == true)
        #expect(await writer.isEnabled(toolName: "stub.read") == false)
        #expect(await writer.isEnabled(toolName: "never.toggled") == nil)

        // A fresh store on the same file observes the same rows, proving
        // restarts restore operator intent instead of resetting to enabled.
        let reloaded = ToolStateStore(dbPath: dbPath)
        let second = await reloaded.loadAll()
        #expect(second == first)
        #expect(await reloaded.isEnabled(toolName: "stub.read") == false)
        #expect(await reloaded.isEnabled(toolName: "memories.store") == false)
        #expect(await reloaded.isEnabled(toolName: "stub.write") == true)

        // Overwrites win and survive a third reload.
        await reloaded.setEnabled(toolName: "stub.read", enabled: true)
        let reread = ToolStateStore(dbPath: dbPath)
        #expect(await reread.isEnabled(toolName: "stub.read") == true)
        #expect(await reread.isEnabled(toolName: "memories.store") == false)
    }

    @Test
    func `Disabled tool rejected by ToolBus execute`() async {
        let bus = ToolBus(permissionGate: PermissionGate())
        await bus.register(tool: ServerReadStub())
        let ok = await bus.execute(
            toolCall: ToolInput(toolName: "stub.read", argumentsJSON: "{}"),
            context: ToolContext(conversationID: UUID())
        )
        #expect(ok.isError == false)
        #expect(ok.content == "read-ok")

        // Disabling rejects without invoking the tool, so callers can feed
        // the denial back to the model like any other bus-level failure.
        await bus.disableTool(named: "stub.read")
        #expect(await bus.isToolEnabled(named: "stub.read") == false)
        let denied = await bus.execute(
            toolCall: ToolInput(toolName: "stub.read", argumentsJSON: "{}"),
            context: ToolContext(conversationID: UUID())
        )
        #expect(denied.isError == true)
        #expect(denied.content.contains("currently disabled") == true)

        await bus.enableTool(named: "stub.read")
        #expect(await bus.isToolEnabled(named: "stub.read") == true)
        let restored = await bus.execute(
            toolCall: ToolInput(toolName: "stub.read", argumentsJSON: "{}"),
            context: ToolContext(conversationID: UUID())
        )
        #expect(restored.isError == false)
    }

    @Test
    func `Unknown tool state update reports notFound`() async throws {
        let (engine, base) = try makeIsolatedEngine()
        defer { try? FileManager.default.removeItem(at: base) }
        let dbPath = base.appendingPathComponent("episodes.db").path
        let conversations = ConversationManager()
        let gate = PermissionGate()
        let approvals = ApprovalQueue(permissionGate: gate)
        let bus = ToolBus(permissionGate: gate)
        await bus.register(tool: ServerReadStub())
        let orchestrator = Orchestrator(
            conversations: conversations,
            toolBus: bus,
            llm: ServerStubProvider(),
            memoryEngine: engine
        )
        let toolStates = ToolStateStore(dbPath: dbPath)
        let context = ServerContext(
            conversations: conversations,
            toolBus: bus,
            orchestrator: orchestrator,
            memoryEngine: engine,
            permissionGate: gate,
            approvals: approvals,
            toolStates: toolStates
        )

        // Unknown registered names 404 without persisting a dead row.
        do {
            _ = try await updateToolState(toolName: "does.not.exist", enabled: false, context: context)
            Issue.record("Expected notFound for unknown tool")
        } catch let abort as Abort {
            #expect(abort.status == .notFound)
        }
        #expect(await toolStates.isEnabled(toolName: "does.not.exist") == nil)

        // Blank names are a rejected request, not an unknown tool.
        do {
            _ = try await updateToolState(toolName: "   ", enabled: true, context: context)
            Issue.record("Expected badRequest for blank name")
        } catch let abort as Abort {
            #expect(abort.status == .badRequest)
        }

        // Known tools persist before responding and return the updated row.
        let disabled = try await updateToolState(toolName: "stub.read", enabled: false, context: context)
        #expect(disabled.name == "stub.read")
        #expect(disabled.isEnabled == false)
        #expect(await toolStates.isEnabled(toolName: "stub.read") == false)
        #expect(await bus.isToolEnabled(named: "stub.read") == false)

        let enabled = try await updateToolState(toolName: "stub.read", enabled: true, context: context)
        #expect(enabled.name == "stub.read")
        #expect(enabled.isEnabled == true)
        #expect(await toolStates.isEnabled(toolName: "stub.read") == true)
    }

    @Test
    func `ServerContext restores persisted states onto fresh bus`() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dbPath = tempDir.appendingPathComponent("episodes.db").path

        let writer = ToolStateStore(dbPath: dbPath)
        await writer.setEnabled(toolName: "stub.read", enabled: false)

        // A fresh bus starts enabled; restore must flip it from disk.
        let (engine, base) = try makeIsolatedEngine()
        defer { try? FileManager.default.removeItem(at: base) }
        let conversations = ConversationManager()
        let gate = PermissionGate()
        let approvals = ApprovalQueue(permissionGate: gate)
        let bus = ToolBus(permissionGate: gate)
        await bus.register(tool: ServerReadStub())
        #expect(await bus.isToolEnabled(named: "stub.read") == true)
        let orchestrator = Orchestrator(
            conversations: conversations,
            toolBus: bus,
            llm: ServerStubProvider(),
            memoryEngine: engine
        )
        let context = ServerContext(
            conversations: conversations,
            toolBus: bus,
            orchestrator: orchestrator,
            memoryEngine: engine,
            permissionGate: gate,
            approvals: approvals,
            toolStates: ToolStateStore(dbPath: dbPath)
        )
        await context.restoreToolStates()
        #expect(await bus.isToolEnabled(named: "stub.read") == false)
        let denied = await bus.execute(
            toolCall: ToolInput(toolName: "stub.read", argumentsJSON: "{}"),
            context: ToolContext(conversationID: UUID())
        )
        #expect(denied.isError == true)
        #expect(denied.content.contains("currently disabled") == true)
    }

    @Test
    func `Tool-state enable succeeds without a config gate for desktop tools`() async throws {
        let (engine, base) = try makeIsolatedEngine()
        defer { try? FileManager.default.removeItem(at: base) }
        let dbPath = base.appendingPathComponent("episodes.db").path
        let conversations = ConversationManager()
        let gate = PermissionGate()
        let approvals = ApprovalQueue(permissionGate: gate)
        let bus = ToolBus(permissionGate: gate)
        // Boot ships both desktop tools registered but disabled; the
        // tool-state toggle is the sole authority for enablement.
        for tool in DesktopTools.makeTools() {
            await bus.register(tool: tool, isEnabled: false)
        }
        let orchestrator = Orchestrator(
            conversations: conversations,
            toolBus: bus,
            llm: ServerStubProvider(),
            memoryEngine: engine
        )
        let toolStates = ToolStateStore(dbPath: dbPath)
        let context = ServerContext(
            conversations: conversations,
            toolBus: bus,
            orchestrator: orchestrator,
            memoryEngine: engine,
            permissionGate: gate,
            approvals: approvals,
            toolStates: toolStates
        )

        // Enabling persists and goes live with no config gate in the way.
        let enabled = try await updateToolState(toolName: "desktop.screenshot", enabled: true, context: context)
        #expect(enabled.isEnabled == true)
        #expect(await toolStates.isEnabled(toolName: "desktop.screenshot") == true)
        #expect(await bus.isToolEnabled(named: "desktop.screenshot") == true)

        // The second desktop tool enables independently through the same path.
        let actionEnabled = try await updateToolState(toolName: "desktop.action", enabled: true, context: context)
        #expect(actionEnabled.isEnabled == true)
        #expect(await toolStates.isEnabled(toolName: "desktop.action") == true)
        #expect(await bus.isToolEnabled(named: "desktop.action") == true)
    }
}

@Suite("Access Rules Routes")
struct AccessRulesRouteTests {
    /// Finds the rule a descriptor's trust currently lives under, so tests address rows by the
    /// target the owner approved rather than by identity. descriptor: Action the
    /// rule was minted for.
    private func rule(for descriptor: ActionDescriptor, gate: PermissionGate) async -> AccessRule? {
        await gate.activeRules().first { rule in
            rule.toolName == descriptor.toolName && rule.scope == .exactTarget(descriptor.target)
        }
    }

    /// Mirrors the GET /approvals/rules handler so route semantics stay
    /// covered without a live socket: prune expired, newest-first, then map.
    private func rulesResponse(for gate: PermissionGate) async -> AccessRulesResponse {
        let rules = await gate.activeRules()
        let newestFirst = rules.sorted { $0.grantedAt > $1.grantedAt }
        return AccessRulesResponse(rules: newestFirst.map(AccessRuleResponse.init))
    }

    /// Mirrors the DELETE /approvals/rules/:id handler mapping so the 404
    /// contract stays pinned to the revoke result.
    private func deleteRuleStatus(id: UUID, gate: PermissionGate) async throws -> HTTPStatus {
        let removed = await gate.revokeRule(id: id)
        guard removed else {
            throw Abort(.notFound, reason: "Unknown rule \(id.uuidString)")
        }
        return .noContent
    }

    /// Mirrors the POST /approvals/rules/:id/widen handler mapping so the tri-state contract stays
    /// pinned: a promoted rule is 204, an unknown or expired id is 404, and a live rule whose tool
    /// has no tool-wide scope is the honest conflict rather than "Unknown rule".
    private func widenRuleStatus(id: UUID, gate: PermissionGate) async throws -> HTTPStatus {
        switch await gate.widenGrant(id: id) {
        case .widened:
            .noContent
        case .notFound:
            throw Abort(.notFound, reason: "Unknown rule \(id.uuidString)")
        case let .notWidenable(reason):
            throw Abort(.conflict, reason: reason)
        }
    }

    /// Mirrors the PATCH /approvals/rules/:id handler mapping so the tri-state contract stays
    /// pinned: a re-armed rule is 204, an unknown or expired id is 404, and a live rule carrying a
    /// non-durable tier is the honest 400 rather than "Unknown rule".
    private func rearmRuleStatus(id: UUID, duration: TrustDuration, gate: PermissionGate) async throws -> HTTPStatus {
        switch await gate.rearmGrant(id: id, duration: duration) {
        case .rearmed:
            .noContent
        case .notFound:
            throw Abort(.notFound, reason: "Unknown rule \(id.uuidString)")
        case let .invalidDuration(reason):
            throw Abort(.badRequest, reason: reason)
        }
    }

    @Test
    func `Rules list returns oneHour and forever with correct fields`() async {
        let gate = PermissionGate()
        let timedDescriptor = ActionDescriptor(toolName: "email.send", target: "alice@example.com")
        let foreverDescriptor = ActionDescriptor(toolName: "file.write", target: "/tmp/report.md")
        await gate.grantTrust(for: timedDescriptor, duration: .oneHour)
        await gate.grantTrust(for: foreverDescriptor, duration: .forever)

        // Both rules gate their actions until revoked or expired.
        #expect(await gate.isTrusted(timedDescriptor) == true)
        #expect(await gate.isTrusted(foreverDescriptor) == true)

        let response = await rulesResponse(for: gate)
        #expect(response.count == 2)
        #expect(response.rules.count == 2)

        guard let timed = response.rules.first(where: { $0.duration == .oneHour }) else {
            Issue.record("Expected oneHour rule in list")
            return
        }
        #expect(timed.toolName == "email.send")
        #expect(timed.scope == AccessScopeDTO(kind: .exactTarget, target: "alice@example.com"))
        #expect(timed.action == .allow)
        #expect(timed.displayScope == "target 'alice@example.com'")
        #expect(timed.duration == .oneHour)
        // Timed rules carry a future expiry derived from the grant moment.
        #expect(timed.expiresAt != nil)
        if let expiresAt = timed.expiresAt {
            #expect(expiresAt > timed.grantedAt)
        }

        guard let forever = response.rules.first(where: { $0.duration == .forever }) else {
            Issue.record("Expected forever rule in list")
            return
        }
        #expect(forever.toolName == "file.write")
        #expect(forever.scope == AccessScopeDTO(kind: .exactTarget, target: "/tmp/report.md"))
        #expect(forever.displayScope == "target '/tmp/report.md'")
        #expect(forever.duration == .forever)
        // Forever rules never expire, so the wire expiry stays nil and
        // dashboards render them as never expiring instead of epoch dates.
        #expect(forever.expiresAt == nil)
    }

    @Test
    func `Rules list hides expired entries`() async throws {
        let now = Date()
        let expired = try #require(AccessRule(
            toolName: "email.send",
            scope: .exactTarget("stale@example.com"),
            action: .allow,
            grantedAt: now.addingTimeInterval(-7200),
            duration: .fiveMinutes,
            expiresAt: now.addingTimeInterval(-60)
        ))
        let active = try #require(AccessRule(
            toolName: "email.send",
            scope: .exactTarget("fresh@example.com"),
            action: .allow,
            grantedAt: now,
            duration: .oneHour,
            expiresAt: now.addingTimeInterval(3600)
        ))
        let forever = try #require(AccessRule(
            toolName: "file.write",
            scope: .exactTarget("/tmp/kept.md"),
            action: .allow,
            grantedAt: now,
            duration: .forever
        ))
        let store = InMemoryAccessRuleStore(rules: [expired, active, forever])
        let gate = await PermissionGate.load(ruleStore: store)

        let response = await rulesResponse(for: gate)
        #expect(response.count == 2)
        #expect(response.rules.contains { $0.scope == AccessScopeDTO(kind: .exactTarget, target: "stale@example.com") } == false)
        #expect(response.rules.contains { $0.scope == AccessScopeDTO(kind: .exactTarget, target: "fresh@example.com") } == true)
        #expect(response.rules.contains { $0.scope == AccessScopeDTO(kind: .exactTarget, target: "/tmp/kept.md") } == true)
        // Gating follows the filtered list: lapsed scope falls back to asking.
        #expect(await gate.isTrusted(ActionDescriptor(toolName: "email.send", target: "stale@example.com")) == false)
        #expect(await gate.isTrusted(ActionDescriptor(toolName: "email.send", target: "fresh@example.com")) == true)

        // An expiry exactly at the reference instant already counts as
        // expired, so clock skew cannot stretch a grant by one poll tick.
        let boundary = try #require(AccessRule(
            toolName: "email.send",
            scope: .exactTarget("edge@example.com"),
            grantedAt: now,
            duration: .fiveMinutes,
            expiresAt: now
        ))
        #expect(boundary.isExpired(at: now) == true)
        #expect(boundary.isValid(at: now) == false)
        // A nil expiry never lapses regardless of the reference date.
        #expect(forever.isExpired(at: now.addingTimeInterval(60 * 60 * 24 * 365)) == false)
    }

    @Test
    func `Revoke removes rule and restores gating`() async throws {
        let gate = PermissionGate()
        let descriptor = ActionDescriptor(toolName: "email.send", target: "bob@example.com")
        await gate.grantTrust(for: descriptor, duration: .oneHour)
        #expect(await gate.isTrusted(descriptor) == true)

        guard let id = await rule(for: descriptor, gate: gate)?.id else {
            Issue.record("Expected granted row before revoke")
            return
        }
        // A successful DELETE maps to 204 with no body.
        #expect(try await deleteRuleStatus(id: id, gate: gate).code == 204)

        // Revocation drops the row and returns gating to ask-every-time.
        #expect(await gate.isTrusted(descriptor) == false)
        let after = await rulesResponse(for: gate)
        #expect(after.rules.contains { $0.id == id } == false)
        #expect(after.count == 0)
    }

    @Test
    func `Revoke unknown rule reports notFound`() async {
        let gate = PermissionGate()
        let unknown = UUID()
        #expect(await gate.revokeRule(id: unknown) == false)
        do {
            _ = try await deleteRuleStatus(id: unknown, gate: gate)
            Issue.record("Expected notFound for unknown rule")
        } catch let abort as Abort {
            // The DELETE handler maps a missed revoke to 404 so dashboards
            // can explain the rule already lapsed instead of retrying.
            #expect(abort.status == .notFound)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func `ThisTime decision creates no rule row`() async {
        let gate = PermissionGate()
        let store = ApprovalQueue(permissionGate: gate)
        let request = await store.enqueue(
            toolName: "stub.write",
            description: "Write stub.",
            input: ToolInput(toolName: "stub.write", argumentsJSON: #"{"path":"/tmp/once.md"}"#)
        )
        #expect(await store.decide(id: request.id, approved: true, duration: .thisTime) == true)
        // One-shot approvals resolve the waiter but record no durable row,
        // so the rules list stays empty and gating stays closed.
        #expect(await gate.activeRules().isEmpty == true)
        #expect(await gate.isTrusted(ActionDescriptor(toolName: "stub.write", target: "/tmp/once.md")) == false)

        // A duration approval on the same gate mints exactly one row,
        // proving the absence above comes from the tier rather than wiring.
        let durable = await store.enqueue(
            toolName: "stub.write",
            description: "Write stub.",
            input: ToolInput(toolName: "stub.write", argumentsJSON: #"{"path":"/tmp/kept.md"}"#)
        )
        #expect(await store.decide(id: durable.id, approved: true, duration: .oneHour) == true)
        let listed = await rulesResponse(for: gate)
        #expect(listed.count == 1)
        #expect(listed.rules.first?.scope == AccessScopeDTO(kind: .exactTarget, target: "/tmp/kept.md"))
        #expect(await gate.isTrusted(ActionDescriptor(toolName: "stub.write", target: "/tmp/kept.md")) == true)
        #expect(await gate.isTrusted(ActionDescriptor(toolName: "stub.write", target: "/tmp/once.md")) == false)
    }

    @Test
    func `GET exposes zero usage for fresh rules`() async {
        let gate = PermissionGate()
        let fresh = ActionDescriptor(toolName: "email.send", target: "fresh@example.com")
        await gate.grantTrust(for: fresh, duration: .oneHour)

        // Fresh rows must encode the untouched baseline so dashboards can
        // distinguish never-fired trust from exercised trust.
        let response = await rulesResponse(for: gate)
        #expect(response.count == 1)
        guard let row = response.rules.first(where: { $0.scope == AccessScopeDTO(kind: .exactTarget, target: "fresh@example.com") }) else {
            Issue.record("Expected fresh rule in list")
            return
        }
        #expect(row.useCount == 0)
        #expect(row.lastUsedAt == nil)
        #expect(row.toolName == "email.send")
        #expect(row.duration == .oneHour)
    }

    @Test
    func `GET exposes incremented usage after recordUse`() async {
        let gate = PermissionGate()
        let fresh = ActionDescriptor(toolName: "email.send", target: "fresh@example.com")
        let used = ActionDescriptor(toolName: "email.send", target: "used@example.com")
        await gate.grantTrust(for: fresh, duration: .oneHour)
        await gate.grantTrust(for: used, duration: .forever)
        await gate.recordUse(scope: .exactTarget("used@example.com"), toolName: "email.send")
        await gate.recordUse(scope: .exactTarget("used@example.com"), toolName: "email.send")
        await gate.recordUse(scope: .exactTarget("used@example.com"), toolName: "email.send")

        // The list must carry the durable counters so the inbox proves
        // liveness without re-deriving it from run history.
        let response = await rulesResponse(for: gate)
        #expect(response.count == 2)
        guard let freshRow = response.rules.first(where: { $0.scope == AccessScopeDTO(kind: .exactTarget, target: "fresh@example.com") }) else {
            Issue.record("Expected fresh rule in list")
            return
        }
        #expect(freshRow.useCount == 0)
        #expect(freshRow.lastUsedAt == nil)
        guard let usedRow = response.rules.first(where: { $0.scope == AccessScopeDTO(kind: .exactTarget, target: "used@example.com") }) else {
            Issue.record("Expected used rule in list")
            return
        }
        #expect(usedRow.useCount == 3)
        #expect(usedRow.lastUsedAt != nil)
        #expect(usedRow.duration == .forever)
        #expect(usedRow.expiresAt == nil)
    }

    @Test
    func `DELETE persists removal and second delete stays notFound`() async throws {
        let gate = PermissionGate()
        let descriptor = ActionDescriptor(toolName: "email.send", target: "gone@example.com")
        await gate.grantTrust(for: descriptor, duration: .oneHour)
        guard let id = await rule(for: descriptor, gate: gate)?.id else {
            Issue.record("Expected granted row before delete")
            return
        }
        // First DELETE removes the row with an empty 204 body.
        #expect(try await deleteRuleStatus(id: id, gate: gate).code == 204)
        #expect(await gate.isTrusted(descriptor) == false)
        // A repeat DELETE for the same identifier must stay 404 so dashboards
        // explain the row is already gone instead of retrying.
        do {
            _ = try await deleteRuleStatus(id: id, gate: gate)
            Issue.record("Expected notFound for already-revoked rule")
        } catch let abort as Abort {
            #expect(abort.status == .notFound)
        }
        #expect(await gate.revokeRule(id: UUID()) == false)
    }

    @Test
    func `Revoke already-expired rule stays notFound`() async throws {
        let now = Date()
        let expired = try #require(AccessRule(
            toolName: "email.send",
            scope: .exactTarget("lapsed@example.com"),
            action: .allow,
            grantedAt: now.addingTimeInterval(-7200),
            duration: .fiveMinutes,
            expiresAt: now.addingTimeInterval(-60)
        ))
        // Bootstrap prunes the lapsed row, so the stranded identifier never
        // matches; the DELETE contract stays 404 for clock-skewed retries.
        let store = InMemoryAccessRuleStore(rules: [expired])
        let gate = await PermissionGate.load(ruleStore: store)
        #expect(await gate.activeRules().isEmpty == true)
        #expect(await gate.revokeRule(id: expired.id) == false)
        do {
            _ = try await deleteRuleStatus(id: expired.id, gate: gate)
            Issue.record("Expected notFound for already-expired rule")
        } catch let abort as Abort {
            #expect(abort.status == .notFound)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func `Widen rule route widens scope and unknown returns 404`() async throws {
        let gate = PermissionGate()
        let descriptor = ActionDescriptor(toolName: "email.send", target: "specific@example.com")
        await gate.grantTrust(for: descriptor, duration: .oneHour)

        guard let id = await rule(for: descriptor, gate: gate)?.id else {
            Issue.record("Expected rule")
            return
        }

        #expect(try await widenRuleStatus(id: id, gate: gate).code == 204)

        let active = await gate.activeRules()
        #expect(active.count == 1)
        #expect(active[0].scope == .toolWide)
        let response = await rulesResponse(for: gate)
        #expect(response.rules.first?.scope == AccessScopeDTO(kind: .tool))
        #expect(response.rules.first?.displayScope == "every target")

        let unknown = UUID()
        do {
            _ = try await widenRuleStatus(id: unknown, gate: gate)
            Issue.record("Expected notFound for unknown rule")
        } catch let abort as Abort {
            #expect(abort.status == .notFound)
        }
    }

    @Test
    func `Widen live messages.send rule returns honest conflict, not unknown`() async {
        let gate = PermissionGate()
        let descriptor = ActionDescriptor(toolName: "messages.send", target: "+15551234567")
        await gate.grantTrust(for: descriptor, duration: .forever)

        guard let id = await rule(for: descriptor, gate: gate)?.id else {
            Issue.record("Expected the canonical send grant")
            return
        }

        // A live send grant is per-recipient by design: the route must name the
        // refusal (409) instead of reporting the listed id as unknown (404),
        // and the grant must survive unchanged so it stays revocable.
        do {
            _ = try await widenRuleStatus(id: id, gate: gate)
            Issue.record("Expected conflict for a live messages.send rule")
        } catch let abort as Abort {
            #expect(abort.status == .conflict)
            #expect(abort.reason == "messages.send grants are per-recipient and cannot be widened")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        let survivor = await rule(for: descriptor, gate: gate)
        #expect(survivor?.toolName == "messages.send")
        #expect(survivor?.scope == .exactTarget("+15551234567"))
    }

    @Test
    func `Widen expired messages.send grant stays notFound`() async throws {
        let now = Date()
        let expired = try #require(AccessRule(
            toolName: "messages.send",
            scope: .exactTarget("+15551234567"),
            action: .allow,
            grantedAt: now.addingTimeInterval(-7200),
            duration: .fiveMinutes,
            expiresAt: now.addingTimeInterval(-60)
        ))
        // Bootstrap prunes the lapsed row, so a send grant that no longer
        // exists reads as notFound rather than as the live-grant refusal; the
        // gate's guard order is what keeps those outcomes distinct.
        let store = InMemoryAccessRuleStore(rules: [expired])
        let gate = await PermissionGate.load(ruleStore: store)
        do {
            _ = try await widenRuleStatus(id: expired.id, gate: gate)
            Issue.record("Expected notFound for an expired messages.send rule")
        } catch let abort as Abort {
            #expect(abort.status == .notFound)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func `ApprovalQueue decide with scope creates widened rule and reflects in rules list`() async {
        let gate = PermissionGate()
        let store = ApprovalQueue(permissionGate: gate)
        let request = await store.enqueue(
            toolName: "api.request",
            description: "API call",
            input: ToolInput(toolName: "api.request", argumentsJSON: #"{"url":"https://api.example.com/items"}"#)
        )

        let decided = await store.decide(id: request.id, approved: true, duration: .oneHour, scope: .toolWide)
        #expect(decided == true)

        let response = await rulesResponse(for: gate)
        #expect(response.count == 1)
        #expect(response.rules.first?.toolName == "api.request")
        #expect(response.rules.first?.scope == AccessScopeDTO(kind: .tool))
        #expect(await gate.isTrusted(ActionDescriptor(toolName: "api.request", target: "https://other.com/items")) == true)
    }

    @Test
    func `A durable deny lists beside allows with a nil expiry`() async {
        let gate = PermissionGate()
        let allowDescriptor = ActionDescriptor(toolName: "email.send", target: "friend@example.com")
        await gate.grantTrust(for: allowDescriptor, duration: .forever)
        await gate.denyRule(
            .exactTarget("blocked@example.com"),
            toolName: "email.send",
            reason: "owner refused this recipient"
        )

        // The rules surface lists both actions so the owner sees the whole
        // posture, and a deny carries no expiry because a refusal is standing.
        let response = await rulesResponse(for: gate)
        #expect(response.count == 2)
        guard let deny = response.rules.first(where: { $0.action == .deny }) else {
            Issue.record("Expected the deny rule in list")
            return
        }
        #expect(deny.scope == AccessScopeDTO(kind: .exactTarget, target: "blocked@example.com"))
        #expect(deny.expiresAt == nil)
        #expect(deny.duration == nil)
        #expect(deny.displayScope == "target 'blocked@example.com'")
        #expect(response.rules.contains { $0.action == .allow } == true)

        // Deny outranks the allow beside it, so the refused recipient stays
        // refused and names the rule that refused it.
        let blocked = ToolInput(toolName: "email.send", argumentsJSON: #"{"to":"blocked@example.com"}"#)
        #expect(await gate.checkPermission(toolCall: blocked, tool: ServerSendProbeTool()) == .denied(
            "Denied by rule: email.send is refused for target 'blocked@example.com' (owner refused this recipient)."
        ))
    }

    @Test
    func `Rearm preserves counters, identity, and creation time while recomputing expiry`() async throws {
        let gate = PermissionGate()
        let descriptor = ActionDescriptor(toolName: "email.send", target: "alice@example.com")
        await gate.grantTrust(for: descriptor, duration: .oneHour)
        await gate.recordUse(scope: .exactTarget("alice@example.com"), toolName: "email.send")
        await gate.recordUse(scope: .exactTarget("alice@example.com"), toolName: "email.send")
        guard let before = await rule(for: descriptor, gate: gate) else {
            Issue.record("Expected active grant before re-arm")
            return
        }
        let beforeGrantedAt = before.grantedAt
        let beforeLastUsed = before.lastUsedAt

        // A successful PATCH maps to an empty 204 with no second row; expiry
        // is recomputed from confirmation time while identity and liveness
        // counters survive the tier change.
        #expect(try await rearmRuleStatus(id: before.id, duration: .oneDay, gate: gate).code == 204)
        let active = await gate.activeRules()
        #expect(active.count == 1)
        guard let rearmed = active.first(where: { $0.id == before.id }) else {
            Issue.record("Expected the same rule row after re-arm")
            return
        }
        #expect(rearmed.scope == .exactTarget("alice@example.com"))
        #expect(rearmed.grantedAt == beforeGrantedAt)
        #expect(rearmed.useCount == 2)
        #expect(rearmed.lastUsedAt == beforeLastUsed)
        #expect(rearmed.duration == .oneDay)
        #expect(rearmed.expiresAt != nil)
    }

    @Test
    func `Rearm expired rule stays notFound`() async throws {
        let now = Date()
        let expired = try #require(AccessRule(
            toolName: "email.send",
            scope: .exactTarget("lapsed@example.com"),
            action: .allow,
            grantedAt: now.addingTimeInterval(-7200),
            duration: .fiveMinutes,
            expiresAt: now.addingTimeInterval(-60)
        ))
        // Bootstrap prunes the lapsed row, so the stranded identifier never
        // matches; the PATCH contract stays 404 for clock-skewed retries.
        let store = InMemoryAccessRuleStore(rules: [expired])
        let gate = await PermissionGate.load(ruleStore: store)
        #expect(await gate.activeRules().isEmpty == true)
        do {
            _ = try await rearmRuleStatus(id: expired.id, duration: .oneHour, gate: gate)
            Issue.record("Expected notFound for an expired rule")
        } catch let abort as Abort {
            #expect(abort.status == .notFound)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func `Rearm with thisTime stays badRequest with the one-shot refusal`() async {
        let gate = PermissionGate()
        let descriptor = ActionDescriptor(toolName: "email.send", target: "alice@example.com")
        await gate.grantTrust(for: descriptor, duration: .oneHour)
        guard let id = await rule(for: descriptor, gate: gate)?.id else {
            Issue.record("Expected active rule before re-arm")
            return
        }

        // The rule is live and listed, so "Unknown rule" would be factually
        // wrong; the tier refusal itself is the honest answer and leaves the
        // stored row unchanged.
        do {
            _ = try await rearmRuleStatus(id: id, duration: .thisTime, gate: gate)
            Issue.record("Expected badRequest for a one-shot re-arm")
        } catch let abort as Abort {
            #expect(abort.status == .badRequest)
            #expect(abort.reason == GrantRearmOutcome.thisTimeRefusal)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await gate.activeRules().count == 1)
        #expect(await gate.activeRules().first?.duration == .oneHour)
    }
}

/// Probe tool standing in for a gated send on the rules decision path.
private struct ServerSendProbeTool: Tool, Sendable {
    let name = "email.send"
    let description = "Probe for email.send."
    let permissionLevel = PermissionLevel.requiresApproval
    var inputSchema: JSONSchema {
        .emptyObject
    }

    func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        .success("probe-ok", callID: input.callID)
    }
}

/// Canned downstream responder used to observe whether the auth gate forwarded a
/// request rather than answering it itself.
private struct SurfaceProbeResponder: AsyncResponder, Sendable {
    func respond(to request: Request) async throws -> Response {
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: "X-Probe-Authenticated", value: request.runeWeaverAuthenticated ? "true" : "false")
        return Response(status: .ok, headers: headers, body: .init(string: "surface-probe"))
    }
}

/// Makes a verifier for the surface-shape tests. Only `verify` is exercised, so
/// the backing store never persists and stays off the real Keychain service.
private func makeSurfaceAuth(token: String = "owner-token") -> ServerAuth {
    let store = ServerAuthTokenStore(
        authConfig: AuthConfig(tokenEnv: "RUNEWEAVER_AUTH_TEST_UNSET", tokenFile: nil),
        service: "com.runeweaver.tests.\(UUID().uuidString)",
        inMemory: true
    )
    return ServerAuth(initialToken: token, store: store)
}

/// Materializes a throwaway on-disk bundle so the public-path gate is exercised
/// against real static files, matching how a built bundle actually ships.
private func makeSurfaceBundle() throws -> (bundle: DashboardBundle, directory: URL) {
    let files = [
        "index.html",
        "assets/index-abc123.js",
        "assets/index-abc123.css",
        "assets/vendor-chunk.woff2",
        "favicon.ico",
        "favicon-32x32.png",
        "favicon.svg",
        "apple-touch-icon.png",
        "site.webmanifest"
    ]
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("runeweaver-surface-bundle-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for relative in files {
        let fileURL = directory.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("bundle-fixture".utf8).write(to: fileURL)
    }
    return (DashboardBundle(directoryURL: directory), directory)
}

/// Creates an application for in-process request construction and shutdown.
private func withSurfaceApp<T>(_ body: (Application) async throws -> T) async throws -> T {
    let app = try await Application.make(.testing)
    do {
        let value = try await body(app)
        try await app.asyncShutdown()
        return value
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
}

/// Builds a request without touching a socket.
private func surfaceRequest(
    app: Application,
    method: HTTPMethod = .GET,
    path: String,
    token: String? = nil
) -> Request {
    var headers = HTTPHeaders()
    if let token {
        headers.replaceOrAdd(name: "Authorization", value: "Bearer \(token)")
    }
    return Request(
        application: app,
        method: method,
        url: URI(string: path),
        headers: headers,
        on: app.eventLoopGroup.next()
    )
}

@Suite("Authenticated Surfaces")
struct AuthenticatedSurfaceTests {
    @Test
    func `Unauthenticated health returns liveness only`() async throws {
        try await withSurfaceApp { app in
            let middleware = ServerAuthMiddleware(auth: makeSurfaceAuth())
            let response = try await middleware.respond(
                to: surfaceRequest(app: app, path: "/health"),
                chainingTo: SurfaceProbeResponder()
            )
            #expect(response.status == .ok)
            // The public liveness shape must not leak version, model, or engine
            // detail to a caller who has not authenticated.
            let body = response.body.string ?? ""
            #expect(body == #"{"status":"ok"}"#)
            #expect(body.contains("version") == false)
            #expect(body.contains("model") == false)
            #expect(body.contains("engine") == false)
        }
    }

    @Test
    func `Authenticated health reaches the full probe`() async throws {
        try await withSurfaceApp { app in
            let middleware = ServerAuthMiddleware(auth: makeSurfaceAuth())
            let response = try await middleware.respond(
                to: surfaceRequest(app: app, path: "/health", token: "owner-token"),
                chainingTo: SurfaceProbeResponder()
            )
            #expect(response.status == .ok)
            #expect(response.headers.first(name: "X-Probe-Authenticated") == "true")
            #expect((response.body.string ?? "") == "surface-probe")
        }
    }

    @Test
    func `Unauthenticated dashboard entry point is served publicly`() async throws {
        try await withSurfaceApp { app in
            let middleware = ServerAuthMiddleware(auth: makeSurfaceAuth())
            let response = try await middleware.respond(
                to: surfaceRequest(app: app, path: "/"),
                chainingTo: SurfaceProbeResponder()
            )
            // The SPA entry point is client code with no engine data: it must be
            // reachable so the in-bundle owner-token gate can render. The
            // forwarded request carries no authenticated marker.
            #expect(response.status == .ok)
            #expect((response.body.string ?? "") == "surface-probe")
            #expect(response.headers.first(name: "X-Probe-Authenticated") == "false")
        }
    }

    @Test
    func `Dashboard entry points and existing static assets are public`() async throws {
        try await withSurfaceApp { app in
            let (bundle, directory) = try makeSurfaceBundle()
            defer { try? FileManager.default.removeItem(at: directory) }
            let middleware = ServerAuthMiddleware(auth: makeSurfaceAuth(), dashboardBundle: bundle)
            for path in ["/index.html", "/login", "/assets/index-abc123.js", "/favicon.svg"] {
                let response = try await middleware.respond(
                    to: surfaceRequest(app: app, path: path),
                    chainingTo: SurfaceProbeResponder()
                )
                #expect(response.status == .ok)
                #expect((response.body.string ?? "") == "surface-probe")
            }
        }
    }

    @Test
    func `Authenticated dashboard request reaches the bundle`() async throws {
        try await withSurfaceApp { app in
            let middleware = ServerAuthMiddleware(auth: makeSurfaceAuth())
            let response = try await middleware.respond(
                to: surfaceRequest(app: app, path: "/", token: "owner-token"),
                chainingTo: SurfaceProbeResponder()
            )
            #expect(response.status == .ok)
            #expect(response.headers.first(name: "X-Probe-Authenticated") == "true")
        }
    }

    @Test
    func `Non-GET health is not a liveness bypass`() async throws {
        try await withSurfaceApp { app in
            let middleware = ServerAuthMiddleware(auth: makeSurfaceAuth())
            let response = try await middleware.respond(
                to: surfaceRequest(app: app, method: .POST, path: "/health"),
                chainingTo: SurfaceProbeResponder()
            )
            #expect(response.status == .unauthorized)
        }
    }

    @Test
    func `Unknown paths fail closed without revealing existence`() async throws {
        try await withSurfaceApp { app in
            let middleware = ServerAuthMiddleware(auth: makeSurfaceAuth())
            let known = try await middleware.respond(
                to: surfaceRequest(app: app, path: "/settings"),
                chainingTo: SurfaceProbeResponder()
            )
            let unknown = try await middleware.respond(
                to: surfaceRequest(app: app, path: "/definitely-not-a-route"),
                chainingTo: SurfaceProbeResponder()
            )
            // The gate runs before routing, so an unauthenticated caller cannot
            // map the surface by comparing a protected 401 with a missing 404.
            #expect(known.status == .unauthorized)
            #expect(unknown.status == .unauthorized)
            #expect((known.body.string ?? "") == (unknown.body.string ?? ""))
        }
    }

    @Test
    func `Browser navigation and subresource loads stay public while REST and WS stay gated`() async throws {
        try await withSurfaceApp { app in
            let (bundle, directory) = try makeSurfaceBundle()
            defer { try? FileManager.default.removeItem(at: directory) }
            let middleware = ServerAuthMiddleware(auth: makeSurfaceAuth(), dashboardBundle: bundle)
            // A browser attaches no bearer to a top-level navigation or a subresource fetch, so the
            // entry point and every real static bundle file must forward unauthenticated; otherwise
            // the UI can never boot to render its own owner-token gate.
            let navigationAndAssets = [
                "/",
                "/index.html",
                "/assets/index-abc123.js",
                "/assets/index-abc123.css",
                "/assets/vendor-chunk.woff2",
                "/favicon.ico",
                "/favicon-32x32.png",
                "/apple-touch-icon.png",
                "/site.webmanifest"
            ]
            for path in navigationAndAssets {
                let response = try await middleware.respond(
                    to: surfaceRequest(app: app, path: path),
                    chainingTo: SurfaceProbeResponder()
                )
                #expect(response.status == .ok, "\(path) should be served publicly")
                #expect((response.body.string ?? "") == "surface-probe")
                #expect(response.headers.first(name: "X-Probe-Authenticated") == "false")
            }

            // A public-looking extension alone must not bypass the gate: a registered data route
            // such as `/plugins/<id>` takes a free-form identifier, so these paths are data requests
            // even while a bundle is being served and must answer the uniform 401.
            for path in ["/plugins/index.html", "/plugins/report.json", "/plugins/theme.js", "/data.json"] {
                let crafted = try await middleware.respond(
                    to: surfaceRequest(app: app, path: path),
                    chainingTo: SurfaceProbeResponder()
                )
                // The gate fails closed before forwarding, so the probe
                // responder never runs and no probe header is attached.
                #expect(crafted.status == .unauthorized, "\(path) must stay gated")
                #expect(crafted.headers.first(name: "X-Probe-Authenticated") == nil)
            }

            // Data routes stay gated: an unauthenticated REST call and a
            // credential-free WebSocket handshake both answer the uniform 401.
            let rest = try await middleware.respond(
                to: surfaceRequest(app: app, path: "/settings"),
                chainingTo: SurfaceProbeResponder()
            )
            #expect(rest.status == .unauthorized)
            let socket = try await middleware.respond(
                to: surfaceRequest(app: app, path: "/ws"),
                chainingTo: SurfaceProbeResponder()
            )
            #expect(socket.status == .unauthorized)

            // A request that does carry the token still reaches the bundle and is
            // marked authenticated, so public bytes never erase a credential.
            let authenticated = try await middleware.respond(
                to: surfaceRequest(app: app, path: "/assets/index-abc123.js", token: "owner-token"),
                chainingTo: SurfaceProbeResponder()
            )
            #expect(authenticated.status == .ok)
            #expect(authenticated.headers.first(name: "X-Probe-Authenticated") == "true")
        }
    }
}

/// Recording socket capturing frames for detached-turn tests without a live handshake.
private actor DetachmentRecordingSocket: WSConnectionSocket {
    /// Frames delivered to this connection.
    private(set) var sent: [String] = []

    /// Records one frame.
    func send(_ text: String) async throws {
        sent.append(text)
    }

    /// Ignored; these tests never close the connection.
    func close(code _: WebSocketErrorCode) async throws {}
}

/// Provider holding the turn open with a pause so the test can seal the socket while inference is
/// still in flight.
private struct DetachmentDelayedProvider: LLMProvider, Sendable {
    /// Canned model metadata.
    let modelInfo = ModelInfo(name: "detachment-delayed", provider: "stub", contextLength: 2048)
    /// Answer served after the pause.
    let answer: String
    /// Cooperative pause before serving, holding the turn open.
    let delaySeconds: TimeInterval

    /// Creates a delayed stub.
    init(answer: String = "detached ok", delaySeconds: TimeInterval = 0.5) {
        self.answer = answer
        self.delaySeconds = delaySeconds
    }

    /// Serves the canned answer after the pause.
    func chat(messages _: [Message], tools _: [any Tool]) -> AsyncStream<LLMResponse> {
        let text = answer
        let delay = delaySeconds
        return AsyncStream { continuation in
            Task {
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                continuation.yield(LLMResponse(delta: text))
                continuation.yield(LLMResponse(delta: "", isFinished: true, totalTokens: 7))
                continuation.finish()
            }
        }
    }

    /// Unused embeddings stub.
    func embeddings(text: [String]) async throws -> [[Float]] {
        Array(repeating: [Float](), count: text.count)
    }
}

/// Provider delaying only turns carrying a marker so one session can hold a slow turn while its
/// replacement answers immediately.
private struct DetachmentBranchingProvider: LLMProvider, Sendable {
    /// Canned model metadata.
    let modelInfo = ModelInfo(name: "detachment-branching", provider: "stub", contextLength: 2048)
    /// Marker selecting the slow path.
    let slowMarker: String
    /// Pause for the slow path.
    let slowDelaySeconds: TimeInterval
    /// Answer for the slow path.
    let slowAnswer: String
    /// Answer for the fast path.
    let fastAnswer: String

    /// Serves the slow answer after a pause when the marker is present, else fast.
    func chat(messages: [Message], tools _: [any Tool]) -> AsyncStream<LLMResponse> {
        let isSlow = messages.contains { $0.content.contains(slowMarker) }
        let delay = isSlow ? slowDelaySeconds : 0
        let text = isSlow ? slowAnswer : fastAnswer
        return AsyncStream { continuation in
            Task {
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                continuation.yield(LLMResponse(delta: text))
                continuation.yield(LLMResponse(delta: "", isFinished: true, totalTokens: 7))
                continuation.finish()
            }
        }
    }

    /// Unused embeddings stub.
    func embeddings(text: [String]) async throws -> [[Float]] {
        Array(repeating: [Float](), count: text.count)
    }
}

/// Builds an isolated context for detached-turn tests off the real data directory.
private func makeDetachmentContext(provider: any LLMProvider) throws -> (ServerContext, URL) {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("runeweaver-detachment-\(UUID().uuidString)")
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
        pluginStore: ToolRegistryStore(dbPath: dbPath),
        toolStates: ToolStateStore(dbPath: dbPath)
    )
    return (context, base)
}

/// Polls an async condition until it holds or a short budget expires.
private func detachmentWaitUntil(_ condition: @Sendable @escaping () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(8)
    while Date() < deadline {
        if await condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return await condition()
}

@Suite("WebSocket Turn Detachment")
struct WebSocketTurnDetachmentTests {
    @Test
    func `Socket close leaves detached turn running`() async throws {
        let (context, base) = try makeDetachmentContext(provider: DetachmentDelayedProvider(delaySeconds: 0.5))
        defer { try? FileManager.default.removeItem(at: base) }
        let connectionID = UUID()
        _ = await context.hub.add(id: connectionID, box: DetachmentRecordingSocket())
        let connectionTasks = ConnectionChatTasks()
        let sessionID = UUID()
        await handleWebSocketChat(
            WSChatMessage(text: "hello detached", sessionID: sessionID),
            connectionID: connectionID,
            context: context
        )
        // Slot plus running row exist immediately after spawn.
        #expect(await context.activeTurns.isActive(sessionID: sessionID) == true)
        // Seal the socket while inference is still in flight.
        connectionTasks.cancelAll()
        await context.hub.remove(id: connectionID)
        // Detached ownership keeps the slot and the running row across the seal.
        #expect(await context.activeTurns.isActive(sessionID: sessionID) == true)
        #expect(await context.runs.list(limit: 10, sessionID: sessionID).first?.status == "running")
        // The turn still settles to success after the seal.
        let settled = await detachmentWaitUntil {
            await context.runs.list(limit: 10, sessionID: sessionID).first?.status == "ok"
        }
        #expect(settled == true)
        #expect(await context.activeTurns.isActive(sessionID: sessionID) == false)
    }

    @Test
    func `Explicit cancel stops detached turn`() async throws {
        let (context, base) = try makeDetachmentContext(provider: DetachmentDelayedProvider(delaySeconds: 0.6))
        defer { try? FileManager.default.removeItem(at: base) }
        let connectionID = UUID()
        _ = await context.hub.add(id: connectionID, box: DetachmentRecordingSocket())
        let sessionID = UUID()
        await handleWebSocketChat(
            WSChatMessage(text: "please cancel me", sessionID: sessionID),
            connectionID: connectionID,
            context: context
        )
        #expect(await context.activeTurns.isActive(sessionID: sessionID) == true)
        #expect(await context.activeTurns.cancel(sessionID: sessionID) == true)
        await context.steeringQueue.clear(for: sessionID)
        let settled = await detachmentWaitUntil {
            await context.runs.list(limit: 10, sessionID: sessionID).first?.status == "cancelled"
        }
        #expect(settled == true)
        #expect(await context.activeTurns.isActive(sessionID: sessionID) == false)
    }

    @Test
    func `Same-session supersede cancels prior turn`() async throws {
        let provider = DetachmentBranchingProvider(
            slowMarker: "slow-first",
            slowDelaySeconds: 0.8,
            slowAnswer: "slow",
            fastAnswer: "fast"
        )
        let (context, base) = try makeDetachmentContext(provider: provider)
        defer { try? FileManager.default.removeItem(at: base) }
        let connectionID = UUID()
        _ = await context.hub.add(id: connectionID, box: DetachmentRecordingSocket())
        let sessionID = UUID()
        await handleWebSocketChat(
            WSChatMessage(text: "slow-first", sessionID: sessionID),
            connectionID: connectionID,
            context: context
        )
        #expect(await context.activeTurns.isActive(sessionID: sessionID) == true)
        await handleWebSocketChat(
            WSChatMessage(text: "fast-second", sessionID: sessionID),
            connectionID: connectionID,
            context: context
        )
        // Both rows settle: the superseded turn cancels while its replacement succeeds.
        let settled = await detachmentWaitUntil {
            let rows = await context.runs.list(limit: 10, sessionID: sessionID)
            return rows.count == 2
                && rows.contains { $0.status == "cancelled" }
                && rows.contains { $0.status == "ok" }
        }
        #expect(settled == true)
        #expect(await context.activeTurns.isActive(sessionID: sessionID) == false)
    }

    @Test
    func `Fresh session past cap is rejected`() async throws {
        #expect(ActiveTurnTracker.maxConcurrentTurns == 3)
        let (context, base) = try makeDetachmentContext(provider: DetachmentDelayedProvider(delaySeconds: 0))
        defer { try? FileManager.default.removeItem(at: base) }
        let firstSession = UUID()
        let secondSession = UUID()
        let thirdSession = UUID()
        let first = try #require(await context.activeTurns.tryAcquire(sessionID: firstSession, onCancel: {}))
        let second = try #require(await context.activeTurns.tryAcquire(sessionID: secondSession, onCancel: {}))
        let third = try #require(await context.activeTurns.tryAcquire(sessionID: thirdSession, onCancel: {}))
        #expect(first.replaced == false)
        #expect(second.replaced == false)
        #expect(third.replaced == false)
        let rejectedSession = UUID()
        let connectionID = UUID()
        let socket = DetachmentRecordingSocket()
        _ = await context.hub.add(id: connectionID, box: socket)
        await handleWebSocketChat(
            WSChatMessage(text: "over cap", sessionID: rejectedSession),
            connectionID: connectionID,
            context: context
        )
        // Busy rejection answers the requester directly with no run row and no slot.
        let frames = await socket.sent
        #expect(frames.count == 1)
        let raw = try #require(frames.first)
        let frame = try JSONDecoder().decode(WSErrorFrame.self, from: Data(raw.utf8))
        #expect(frame.message.contains("Already running 3") == true)
        #expect(frame.sessionID == rejectedSession)
        #expect(await context.activeTurns.isActive(sessionID: rejectedSession) == false)
        #expect(await context.runs.list(limit: 10, sessionID: rejectedSession).isEmpty == true)
        // A replacement for the same session still fits past the cap.
        let superseding = await context.activeTurns.tryAcquire(sessionID: thirdSession, onCancel: {})
        #expect(superseding?.replaced == true)
        // Release every held slot so the isolated tracker drains cleanly.
        for session in await context.activeTurns.runningSessionIDs() {
            _ = await context.activeTurns.cancel(sessionID: session)
        }
    }

    @Test
    func `Long turn bounded only by cancel, no absolute timeout`() async throws {
        // No absolute turn watchdog: a healthy turn runs until explicit cancel,
        // same-session supersede, or its terminal frame. The tracker cap stays
        // the only bound.
        #expect(ActiveTurnTracker.maxConcurrentTurns == 3)
        let tracker = ActiveTurnTracker()
        let firstSession = UUID()
        let secondSession = UUID()
        let thirdSession = UUID()
        let first = try #require(await tracker.tryAcquire(sessionID: firstSession, onCancel: {}))
        let second = try #require(await tracker.tryAcquire(sessionID: secondSession, onCancel: {}))
        let third = try #require(await tracker.tryAcquire(sessionID: thirdSession, onCancel: {}))
        #expect(first.replaced == false)
        #expect(second.replaced == false)
        #expect(third.replaced == false)
        // Over-cap fresh session is rejected with no slot.
        let rejectedSession = UUID()
        #expect(await tracker.tryAcquire(sessionID: rejectedSession, onCancel: {}) == nil)
        #expect(await tracker.isActive(sessionID: rejectedSession) == false)
        // Explicit cancel clears the slot so a fresh session fits.
        #expect(await tracker.cancel(sessionID: secondSession) == true)
        #expect(await tracker.isActive(sessionID: secondSession) == false)
        let admitted = try #require(await tracker.tryAcquire(sessionID: rejectedSession, onCancel: {}))
        #expect(admitted.replaced == false)
        #expect(await tracker.isActive(sessionID: rejectedSession) == true)
        // Same-session supersede still replaces its own slot past the cap.
        let superseding = await tracker.tryAcquire(sessionID: firstSession, onCancel: {})
        #expect(superseding?.replaced == true)
        for session in await tracker.runningSessionIDs() {
            _ = await tracker.cancel(sessionID: session)
        }
    }

    @Test
    func `Stale unregister keeps replacement slot`() async throws {
        let tracker = ActiveTurnTracker()
        let sessionID = UUID()
        let first = await tracker.tryAcquire(sessionID: sessionID, onCancel: {})
        let firstToken = try #require(first).token
        #expect(first?.replaced == false)
        let second = await tracker.tryAcquire(sessionID: sessionID, onCancel: {})
        #expect(second?.replaced == true)
        // A stale completion must not release its replacement.
        await tracker.unregister(sessionID: sessionID, token: firstToken)
        #expect(await tracker.isActive(sessionID: sessionID) == true)
        #expect(await tracker.cancel(sessionID: sessionID) == true)
        let secondToken = try #require(second).token
        await tracker.unregister(sessionID: sessionID, token: secondToken)
        #expect(await tracker.isActive(sessionID: sessionID) == false)
        #expect(await tracker.cancel(sessionID: sessionID) == false)
    }
}

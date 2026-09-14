// Rune Weaver Tests — HTTP REST API, WebSocket, and scheduler integration tests.
//
// Validates loopback routing, health probes, chat interactions, memory search,
// approval queue resolution, scheduler job CRUD, and run log recording.

import Foundation
@testable import RuneWeaverCore
@testable import RuneWeaverServer
import Testing

/// Stub LLM replaying one canned answer without the network.
private final class ServerStubProvider: LLMProvider, @unchecked Sendable {
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
    /// - Parameters:
    ///   - messages: Ignored history.
    ///   - tools: Ignored tools.
    /// - Returns: Stream with the canned answer.
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
    /// - Parameters:
    ///   - input: Invocation arguments.
    ///   - context: Ambient execution context.
    /// - Returns: Canned success output.
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
    /// - Parameters:
    ///   - input: Invocation arguments.
    ///   - context: Ambient execution context.
    /// - Returns: Canned success output.
    func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        .success("write-ok", callID: input.callID)
    }
}

/// Lock-guarded flag observed across the tracker cancel boundary.
///
/// Cancel closures run on whatever task the tracker cancels, so the test
/// cannot capture a mutable local. The box keeps one immutable handle while
/// guarding the single bit behind a lock.
private final class CancelFlag: @unchecked Sendable {
    /// Guards the observed bit.
    private let lock = NSLock()
    /// Whether the cancel closure has fired.
    private var stored = false

    /// Marks the flag as fired.
    func set() {
        lock.lock()
        defer { lock.unlock() }
        stored = true
    }

    /// Whether the flag has been marked.
    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stored
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
}

@Suite("Approval Store")
struct ApprovalStoreTests {
    @Test
    func `Enqueue lists pending`() async {
        let store = ApprovalStore()
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
        let store = ApprovalStore(permissionGate: gate)
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
        let store = ApprovalStore(permissionGate: gate)
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
        let store = ApprovalStore()
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
        let store = ApprovalStore()
        #expect(await store.decide(id: UUID(), approved: true) == false)
        #expect(await store.waitForDecision(id: UUID()).approved == false)
    }

    @Test
    func `Early decision parks for later waiter`() async {
        let store = ApprovalStore()
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
    }

    @Test
    func `Health defaults to ok`() {
        let health = HealthResponse()
        #expect(health.status == "ok")
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
        // Legacy typeless frames still decode for back-compat.
        let legacyCancel = "{\"sessionID\":\"\(doneID.uuidString)\"}"
        #expect(try JSONDecoder().decode(WSCancelMessage.self, from: Data(legacyCancel.utf8)) == cancelMsg)

        let cancelledFrame = WSCancelledFrame(sessionID: doneID)
        #expect(try JSONDecoder().decode(WSCancelledFrame.self, from: JSONEncoder().encode(cancelledFrame)) == cancelledFrame)
        // The flag distinguishes real aborts from idle cancels for multiplexed views.
        let idleFrame = WSCancelledFrame(sessionID: doneID, cancelled: false)
        #expect(try JSONDecoder().decode(WSCancelledFrame.self, from: JSONEncoder().encode(idleFrame)) == idleFrame)
        // Frames from older engines omit the flag and still read as success.
        let legacyCancelled = "{\"type\":\"cancelled\",\"sessionID\":\"\(doneID.uuidString)\"}"
        #expect(try JSONDecoder().decode(WSCancelledFrame.self, from: Data(legacyCancelled.utf8)) == cancelledFrame)
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

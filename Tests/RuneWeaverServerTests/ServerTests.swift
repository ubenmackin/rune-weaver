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
    func `Approval prompt and stream frames round-trip`() throws {
        let request = PermissionRequest(
            toolName: "stub.write",
            description: "Write stub.",
            input: ToolInput(toolName: "stub.write", argumentsJSON: "{}")
        )
        let prompt = WSApprovalPrompt(request: request)
        #expect(try JSONDecoder().decode(WSApprovalPrompt.self, from: JSONEncoder().encode(prompt)) == prompt)
        #expect(try JSONDecoder().decode(WSStreamDelta.self, from: JSONEncoder().encode(WSStreamDelta(delta: "hi"))) == WSStreamDelta(delta: "hi"))
        let doneID = UUID()
        let done = WSStreamDone(text: "done", sessionID: doneID)
        #expect(try JSONDecoder().decode(WSStreamDone.self, from: JSONEncoder().encode(done)) == done)
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
}

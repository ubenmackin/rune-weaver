// Rune Weaver Tests — ServerSchedulerWorker automated execution tests.

import Foundation
@testable import RuneWeaverCore
@testable import RuneWeaverServer
import Testing
#if canImport(SQLite3)
    import SQLite3
#endif

private final class SchedulerStubLLM: LLMProvider, Sendable {
    let modelInfo = ModelInfo(name: "stub", provider: "stub", contextLength: 8192)
    private let answer: String

    init(answer: String = "done") {
        self.answer = answer
    }

    func chat(messages _: [Message], tools _: [any Tool]) -> AsyncStream<LLMResponse> {
        let text = answer
        return AsyncStream { continuation in
            continuation.yield(LLMResponse(delta: text))
            continuation.yield(LLMResponse(delta: "", isFinished: true, totalTokens: 7))
            continuation.finish()
        }
    }

    func embeddings(text: [String]) async throws -> [[Float]] {
        Array(repeating: [Float](), count: text.count)
    }
}

private struct StubWorkerTool: Tool, Sendable {
    let name = "echo_tool"
    let description = "Echo tool"
    let permissionLevel = PermissionLevel.readOnly
    var inputSchema: JSONSchema {
        JSONSchema(rawValue: #"{"type":"object"}"#)
    }

    func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        .success("ok", callID: input.callID)
    }
}

private final class BudgetExceededStubLLM: LLMProvider, Sendable {
    let modelInfo = ModelInfo(name: "stub", provider: "stub", contextLength: 8192)

    func chat(messages _: [Message], tools: [any Tool]) -> AsyncStream<LLMResponse> {
        AsyncStream { continuation in
            if tools.isEmpty {
                continuation.yield(LLMResponse(delta: "Partial draft: email composed but not sent due to iteration limit."))
                continuation.yield(LLMResponse(delta: "", isFinished: true, totalTokens: 15))
            } else {
                continuation.yield(LLMResponse(
                    delta: "Executing tool step...",
                    toolCalls: [ToolInput(toolName: "echo_tool", argumentsJSON: "{}")]
                ))
                continuation.yield(LLMResponse(delta: "", isFinished: true, totalTokens: 12))
            }
            continuation.finish()
        }
    }

    func embeddings(text: [String]) async throws -> [[Float]] {
        Array(repeating: [Float](), count: text.count)
    }
}

private final class FailingSchedulerLLM: LLMProvider, Sendable {
    let modelInfo = ModelInfo(name: "stub-fail", provider: "stub", contextLength: 8192)

    func chat(messages _: [Message], tools _: [any Tool]) -> AsyncStream<LLMResponse> {
        AsyncStream { continuation in
            continuation.yield(LLMResponse(delta: "", isFinished: true, errorMessage: "boom"))
            continuation.finish()
        }
    }

    func embeddings(text: [String]) async throws -> [[Float]] {
        Array(repeating: [Float](), count: text.count)
    }
}

/// Embedder that always cancels so the tick must settle through the
/// cancellation path instead of degrading to keyword recall.
private struct CancellingSchedulerEmbedder: EmbeddingsBackend, Sendable {
    let modelID = "cancel-stub"
    let dimension: Int? = 2

    func embed(_: [String]) async throws -> [[Float]] {
        throw CancellationError()
    }
}

private actor StringBox {
    var value: String
    init(_ value: String) {
        self.value = value
    }

    func set(_ value: String) {
        self.value = value
    }

    func get() -> String {
        value
    }
}

private actor ArgumentCapture {
    private var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }

    func get() -> [String] {
        values
    }
}

private struct CapturingStubTool: Tool, Sendable {
    let name: String
    let description = "Stub"
    let permissionLevel = PermissionLevel.readOnly
    var inputSchema: JSONSchema {
        JSONSchema(rawValue: #"{"type":"object"}"#)
    }

    let handler: @Sendable (ToolInput) async -> ToolOutput

    func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        await handler(input)
    }
}

@Suite("Server Scheduler Worker")
struct ServerSchedulerWorkerTests {
    private func makeWorker(
        answer: String = "done",
        llm: any LLMProvider? = nil,
        toolBus: ToolBus? = nil
    ) async throws -> (ServerSchedulerWorker, SchedulerStore, RunLogStore, URL) {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("sched_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbPath = tempDir.appendingPathComponent("episodes.db").path
        let memoryEngine = MemoryEngine(
            episodesDBPath: tempDir.appendingPathComponent("episodes.db").path,
            vectorDBPath: tempDir.appendingPathComponent("vectors").path,
            profilePath: tempDir.appendingPathComponent("profile.json").path
        )
        let conversations = ConversationManager(episodesDBPath: dbPath)
        let bus = toolBus ?? ToolBus()
        let orchestrator = Orchestrator(
            conversations: conversations,
            toolBus: bus,
            llm: llm ?? SchedulerStubLLM(answer: answer),
            memoryEngine: memoryEngine
        )
        let scheduler = await SchedulerStore.load(dbPath: dbPath)
        let runs = await RunLogStore.load(dbPath: dbPath)
        let hub = WSHub()
        let runLock = SchedulerRunLock()

        let worker = ServerSchedulerWorker(
            scheduler: scheduler,
            runs: runs,
            hub: hub,
            runLock: runLock,
            orchestrator: orchestrator,
            conversations: conversations,
            toolBus: bus,
            intervalSeconds: 60
        )
        return (worker, scheduler, runs, tempDir)
    }

    @Test
    func `Scheduler worker fires due cron job on tick`() async throws {
        let (worker, scheduler, runs, tempDir) = try await makeWorker(answer: "digest completed")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let job = try await scheduler.create(NewSchedulerJob(
            name: "morning digest",
            schedule: "* * * * *",
            prompt: "Summarize status"
        ))

        let now = Date()
        let nextMinute = now.addingTimeInterval(65)
        let results = await worker.tick(now: nextMinute)

        #expect(results.count == 1)
        #expect(results.first?.fired == true)
        #expect(results.first?.jobName == job.name)
        #expect(results.first?.responseText == "digest completed")

        let logged = await runs.list(limit: 10)
        #expect(logged.count == 1)
        #expect(logged.first?.status == "ok")
        #expect(logged.first?.response == "digest completed")
    }

    @Test
    func `Disabled job is never fired by worker`() async throws {
        let (worker, scheduler, runs, tempDir) = try await makeWorker()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        _ = try await scheduler.create(NewSchedulerJob(
            name: "disabled job",
            schedule: "* * * * *",
            prompt: "Do something",
            enabled: false
        ))

        let nextMinute = Date().addingTimeInterval(65)
        let results = await worker.tick(now: nextMinute)

        #expect(results.isEmpty)
        let logged = await runs.list(limit: 10)
        #expect(logged.isEmpty)
    }

    @Test
    func `Next fire date resolves earliest cron job`() async throws {
        let (worker, scheduler, _, tempDir) = try await makeWorker()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        _ = try await scheduler.create(NewSchedulerJob(
            name: "every-minute",
            schedule: "* * * * *",
            prompt: "Minutely"
        ))
        _ = try await scheduler.create(NewSchedulerJob(
            name: "daily-later",
            schedule: "0 23 * * *",
            prompt: "Late night"
        ))

        let next = await worker.nextFireDate(after: Date())
        #expect(next != nil)
        #expect(next?.jobName == "every-minute")
    }

    @Test
    func `Concurrent in-flight job is skipped on tick`() async throws {
        let (_, scheduler, runs, tempDir) = try await makeWorker()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let job = try await scheduler.create(NewSchedulerJob(
            name: "digest",
            schedule: "* * * * *",
            prompt: "Digest"
        ))

        // Simulate manual run already holding the lock
        let runLock = SchedulerRunLock()
        let memoryEngine = MemoryEngine(
            episodesDBPath: tempDir.appendingPathComponent("episodes.db").path,
            vectorDBPath: tempDir.appendingPathComponent("vectors").path,
            profilePath: tempDir.appendingPathComponent("profile.json").path
        )
        let customWorker = ServerSchedulerWorker(
            scheduler: scheduler,
            runs: runs,
            hub: WSHub(),
            runLock: runLock,
            orchestrator: Orchestrator(
                conversations: ConversationManager(),
                toolBus: ToolBus(),
                llm: SchedulerStubLLM(answer: "ok"),
                memoryEngine: memoryEngine
            ),
            conversations: ConversationManager(),
            toolBus: ToolBus()
        )

        let acquired = await runLock.tryAcquire(id: job.id, name: job.name)
        #expect(acquired == true)

        let nextMinute = Date().addingTimeInterval(65)
        let results = await customWorker.tick(now: nextMinute)

        #expect(results.count == 1)
        #expect(results.first?.fired == false)
        #expect(results.first?.skippedReason == "already running")
    }

    @Test
    func `Scheduler job exceeding tool budget records budget_exceeded status and surfaces milestone`() async throws {
        let bus = ToolBus()
        await bus.register(tool: StubWorkerTool())
        let stubLLM = BudgetExceededStubLLM()
        let (worker, scheduler, runs, tempDir) = try await makeWorker(
            llm: stubLLM,
            toolBus: bus
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let job = try await scheduler.create(NewSchedulerJob(
            name: "budget test job",
            schedule: "* * * * *",
            prompt: "Send daily report",
            maxToolIterations: 1
        ))

        let now = Date()
        let nextMinute = now.addingTimeInterval(65)
        let results = await worker.tick(now: nextMinute)

        #expect(results.count == 1)
        #expect(results.first?.fired == true)
        #expect(results.first?.jobName == job.name)
        #expect(results.first?.responseText?.contains("Partial draft: email composed") == true)

        let logged = await runs.list(limit: 10)
        #expect(logged.count == 1)
        #expect(logged.first?.status == "budget_exceeded")
        #expect(logged.first?.response?.contains("Partial draft: email composed") == true)
    }

    @Test
    func `Successful run records cursor`() async throws {
        let (worker, scheduler, _, tempDir) = try await makeWorker(answer: "done")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let job = try await scheduler.create(NewSchedulerJob(
            name: "cursor success",
            schedule: "* * * * *",
            prompt: "Summarize mail"
        ))
        #expect(await scheduler.job(id: job.id)?.lastSuccessfulRunEndedAt == nil)
        let results = await worker.tick(now: Date().addingTimeInterval(65))
        #expect(results.count == 1)
        #expect(results.first?.fired == true)
        let cursor = await scheduler.job(id: job.id)?.lastSuccessfulRunEndedAt
        #expect(cursor != nil)
        if let cursor {
            #expect(abs(cursor.timeIntervalSinceNow) < 60)
        }
    }

    @Test
    func `Run prompt carries cursor timestamp plus rule`() async throws {
        let (worker, scheduler, _, tempDir) = try await makeWorker(answer: "done")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let job = try await scheduler.create(NewSchedulerJob(
            name: "cursor prompt",
            schedule: "* * * * *",
            prompt: "Summarize mail"
        ))
        _ = await worker.tick(now: Date().addingTimeInterval(65))
        guard let finished = await scheduler.job(id: job.id) else {
            Issue.record("missing job after tick")
            return
        }
        let cursor = try #require(finished.lastSuccessfulRunEndedAt)
        let prompt = ServerSchedulerWorker.schedulerRunPrompt(for: finished)
        let stamp = ServerSchedulerWorker.schedulerCursorTimestampString(from: cursor)
        #expect(prompt.contains(finished.prompt))
        #expect(prompt.contains("Last successful run ended"))
        #expect(prompt.contains(stamp))
        #expect(prompt.contains("memories.store"))
        #expect(prompt.contains(ServerSchedulerWorker.schedulerCursorRuleLine))
    }

    @Test
    func `Cursorless job carries rule without timestamp`() async throws {
        let (_, scheduler, _, tempDir) = try await makeWorker()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let job = try await scheduler.create(NewSchedulerJob(
            name: "cursorless",
            schedule: "* * * * *",
            prompt: "Summarize mail with default lookback"
        ))
        let stored = await scheduler.job(id: job.id)
        #expect(stored?.lastSuccessfulRunEndedAt == nil)
        let prompt = ServerSchedulerWorker.schedulerRunPrompt(for: job)
        #expect(prompt.hasPrefix(job.prompt))
        #expect(prompt.contains(ServerSchedulerWorker.schedulerCursorRuleLine))
        #expect(prompt.contains(ServerSchedulerWorker.schedulerCursorlessLookbackLine))
        #expect(!prompt.contains("Last successful run ended"))
        // The cursorless prompt names the owning job's configured window
        // verbatim so the agent never guesses the default lookback.
        #expect(prompt.contains("Configured window"))
        #expect(prompt.contains("* * * * *"))
    }

    @Test
    func `Cursorless poll job names poll interval verbatim`() async throws {
        let (_, scheduler, _, tempDir) = try await makeWorker()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let job = try await scheduler.create(NewSchedulerJob(
            name: "cursorless poll",
            schedule: "",
            prompt: "Check inbox",
            pollAccount: "personal",
            pollIntervalSeconds: 300
        ))
        #expect(await scheduler.job(id: job.id)?.lastSuccessfulRunEndedAt == nil)
        let prompt = ServerSchedulerWorker.schedulerRunPrompt(for: job)
        #expect(prompt.contains(ServerSchedulerWorker.schedulerCursorlessLookbackLine))
        #expect(prompt.contains("300"))
        #expect(prompt.contains("personal"))
    }

    @Test
    func `Failed run preserves prior cursor`() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("sched_fail_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dbPath = tempDir.appendingPathComponent("episodes.db").path
        let memoryEngine = MemoryEngine(
            episodesDBPath: dbPath,
            vectorDBPath: tempDir.appendingPathComponent("vectors").path,
            profilePath: tempDir.appendingPathComponent("profile.json").path
        )
        let conversations = ConversationManager(episodesDBPath: dbPath)
        let scheduler = await SchedulerStore.load(dbPath: dbPath)
        let runs = await RunLogStore.load(dbPath: dbPath)
        let worker = ServerSchedulerWorker(
            scheduler: scheduler,
            runs: runs,
            hub: WSHub(),
            runLock: SchedulerRunLock(),
            orchestrator: Orchestrator(
                conversations: conversations,
                toolBus: ToolBus(),
                llm: FailingSchedulerLLM(),
                memoryEngine: memoryEngine
            ),
            conversations: conversations,
            toolBus: ToolBus()
        )
        let job = try await scheduler.create(NewSchedulerJob(
            name: "failing job",
            schedule: "* * * * *",
            prompt: "Do work"
        ))
        let seed = Date(timeIntervalSince1970: 1_700_000_000)
        await scheduler.recordSuccessfulRun(id: job.id, endedAt: seed)
        _ = await worker.tick(now: Date().addingTimeInterval(65))
        let after = await scheduler.job(id: job.id)?.lastSuccessfulRunEndedAt
        #expect(after == seed)
    }

    @Test
    func `Cancelled run preserves prior cursor`() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("sched_cancel_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dbPath = tempDir.appendingPathComponent("episodes.db").path
        let memoryEngine = MemoryEngine(
            episodesDBPath: dbPath,
            vectorDBPath: tempDir.appendingPathComponent("vectors").path,
            profilePath: tempDir.appendingPathComponent("profile.json").path
        )
        let conversations = ConversationManager(episodesDBPath: dbPath)
        let scheduler = await SchedulerStore.load(dbPath: dbPath)
        let runs = await RunLogStore.load(dbPath: dbPath)
        // A cancelling embedder drives the production tick through the
        // cancellation path: recall propagates the cancel, the turn throws,
        // and the worker settles without advancing the cursor.
        let worker = ServerSchedulerWorker(
            scheduler: scheduler,
            runs: runs,
            hub: WSHub(),
            runLock: SchedulerRunLock(),
            orchestrator: Orchestrator(
                conversations: conversations,
                toolBus: ToolBus(),
                llm: SchedulerStubLLM(answer: "ok"),
                memoryEngine: memoryEngine,
                embedder: CancellingSchedulerEmbedder()
            ),
            conversations: conversations,
            toolBus: ToolBus()
        )
        let job = try await scheduler.create(NewSchedulerJob(
            name: "cancel job",
            schedule: "* * * * *",
            prompt: "Do work"
        ))
        let seed = Date(timeIntervalSince1970: 1_700_000_100)
        await scheduler.recordSuccessfulRun(id: job.id, endedAt: seed)
        let results = await worker.tick(now: Date().addingTimeInterval(65))
        #expect(results.count == 1)
        #expect(results.first?.errorMessage == "cancelled")
        let after = await scheduler.job(id: job.id)?.lastSuccessfulRunEndedAt
        #expect(after == seed)
        let logged = await runs.list(limit: 10)
        #expect(logged.count == 1)
        #expect(logged.first?.status == "cancelled")
    }

    @Test
    func `Direct tool subject placeholder cannot reshape the arguments object`() async throws {
        let toolBus = ToolBus()
        let searchPayload = StringBox(
            #"{"messages":[{"id":"seed-0","subject":"Hello","from":"a@b.com","snippet":"","mailbox":"INBOX"}]}"#
        )
        await toolBus.register(tool: CapturingStubTool(name: "email.search") { input in
            await .success(searchPayload.get(), callID: input.callID)
        })
        let moves = ArgumentCapture()
        await toolBus.register(tool: CapturingStubTool(name: "email.move") { input in
            await moves.append(input.argumentsJSON)
            return .success(#"{"success":true}"#, callID: input.callID)
        })

        let (worker, scheduler, _, tempDir) = try await makeWorker(toolBus: toolBus)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        _ = try await scheduler.create(NewSchedulerJob(
            name: "subject move watcher",
            schedule: "",
            prompt: "",
            pollAccount: "personal",
            pollIntervalSeconds: 60,
            watcherSource: EventWatcherSource.email,
            rules: [EventRule(
                name: "Move on arrival",
                condition: EventRuleCondition(),
                action: .directTool(
                    toolName: "email.move",
                    argumentsJSON: #"{"subject":"{{subject}}","mailbox":"INBOX"}"#
                ),
                stopProcessing: true
            )]
        ))

        // First tick baselines the mailbox; the second sees the new message.
        _ = await worker.tick(now: Date())
        await searchPayload.set(
            #"{"messages":[{"id":"seed-0","subject":"Hello","from":"a@b.com","snippet":"","mailbox":"INBOX"},{"id":"m-1","subject":"x\",\"mailbox\":\"Trash","from":"boss@corp.com","snippet":"","mailbox":"INBOX"}]}"#
        )
        let results = await worker.tick(now: Date().addingTimeInterval(65))
        #expect(results.count == 1)
        #expect(results.first?.fired == true)

        let captured = await moves.get()
        #expect(captured.count == 1)
        let data = try #require(captured.first?.data(using: .utf8))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["subject"] as? String == "x\",\"mailbox\":\"Trash")
        #expect(object["mailbox"] as? String == "INBOX")
    }

    @Test
    func `Direct tool subject placeholder substitutes an ordinary subject cleanly`() async throws {
        let toolBus = ToolBus()
        let searchPayload = StringBox(
            #"{"messages":[{"id":"seed-0","subject":"Hello","from":"a@b.com","snippet":"","mailbox":"INBOX"}]}"#
        )
        await toolBus.register(tool: CapturingStubTool(name: "email.search") { input in
            await .success(searchPayload.get(), callID: input.callID)
        })
        let moves = ArgumentCapture()
        await toolBus.register(tool: CapturingStubTool(name: "email.move") { input in
            await moves.append(input.argumentsJSON)
            return .success(#"{"success":true}"#, callID: input.callID)
        })

        let (worker, scheduler, _, tempDir) = try await makeWorker(toolBus: toolBus)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        _ = try await scheduler.create(NewSchedulerJob(
            name: "digest move watcher",
            schedule: "",
            prompt: "",
            pollAccount: "personal",
            pollIntervalSeconds: 60,
            watcherSource: EventWatcherSource.email,
            rules: [EventRule(
                name: "Move on arrival",
                condition: EventRuleCondition(),
                action: .directTool(
                    toolName: "email.move",
                    argumentsJSON: #"{"subject":"{{subject}}","mailbox":"INBOX"}"#
                ),
                stopProcessing: true
            )]
        ))

        _ = await worker.tick(now: Date())
        await searchPayload.set(
            #"{"messages":[{"id":"seed-0","subject":"Hello","from":"a@b.com","snippet":"","mailbox":"INBOX"},{"id":"m-1","subject":"Weekly status digest","from":"boss@corp.com","snippet":"","mailbox":"INBOX"}]}"#
        )
        let results = await worker.tick(now: Date().addingTimeInterval(65))
        #expect(results.count == 1)
        #expect(results.first?.fired == true)

        let captured = await moves.get()
        #expect(captured.count == 1)
        let data = try #require(captured.first?.data(using: .utf8))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["subject"] as? String == "Weekly status digest")
        #expect(object["mailbox"] as? String == "INBOX")
        // The unchanged required-field backfill re-parses the escaped result
        // and still fills id plus account for email.move.
        #expect(object["id"] as? String == "m-1")
        #expect(object["account"] as? String == "personal")
    }
}

private actor AssertionCounter {
    var acquiredReasons: [String] = []
    var releaseCount = 0

    func recordAcquire(_ reason: String) {
        acquiredReasons.append(reason)
    }

    func recordRelease() {
        releaseCount += 1
    }

    func snapshot() -> (acquired: [String], released: Int) {
        (acquiredReasons, releaseCount)
    }
}

private final class BlockingCancellableLLM: LLMProvider, Sendable {
    let modelInfo = ModelInfo(name: "stub-blocking", provider: "stub", contextLength: 8192)
    private let started: AsyncStream<Void>.Continuation

    init(started: AsyncStream<Void>.Continuation) {
        self.started = started
    }

    func chat(messages _: [Message], tools _: [any Tool]) -> AsyncStream<LLMResponse> {
        started.yield(())
        return AsyncStream { continuation in
            let sleeper = Task {
                try? await Task.sleep(for: .seconds(30))
                continuation.finish()
            }
            continuation.onTermination = { _ in
                sleeper.cancel()
            }
        }
    }

    func embeddings(text: [String]) async throws -> [[Float]] {
        Array(repeating: [Float](), count: text.count)
    }
}

@Suite("Sleep Protection and Misfire Catch-Up")
struct SchedulerSleepAndMisfireTests {
    private func makeHarness(
        dbPath: String,
        llm: any LLMProvider = SchedulerStubLLM(answer: "done"),
        activeTurns: ActiveTurnTracker? = nil,
        runLock: SchedulerRunLock = SchedulerRunLock(),
        assertionCounter: AssertionCounter? = nil
    ) async -> (ServerSchedulerWorker, SchedulerStore, RunLogStore) {
        let dir = URL(fileURLWithPath: dbPath).deletingLastPathComponent()
        let memoryEngine = MemoryEngine(
            episodesDBPath: dbPath,
            vectorDBPath: dir.appendingPathComponent("vectors").path,
            profilePath: dir.appendingPathComponent("profile.json").path
        )
        let conversations = ConversationManager(episodesDBPath: dbPath)
        let bus = ToolBus()
        let orchestrator = Orchestrator(
            conversations: conversations,
            toolBus: bus,
            llm: llm,
            memoryEngine: memoryEngine
        )
        let scheduler = await SchedulerStore.load(dbPath: dbPath)
        let runs = await RunLogStore.load(dbPath: dbPath)
        let worker = ServerSchedulerWorker(
            scheduler: scheduler,
            runs: runs,
            hub: WSHub(),
            runLock: runLock,
            orchestrator: orchestrator,
            conversations: conversations,
            toolBus: bus,
            intervalSeconds: 60,
            activeTurns: activeTurns,
            acquireSleepAssertion: { reason in
                Task { await assertionCounter?.recordAcquire(reason) }
                return SystemSleepAssertion.testToken {
                    Task { await assertionCounter?.recordRelease() }
                }
            }
        )
        return (worker, scheduler, runs)
    }

    private func cronFor(hour: Int, minute: Int) -> String {
        "\(minute) \(hour) * * *"
    }

    @Test
    func `Sleep assertion is acquired on run start and released on success, failure, and cancellation`() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("sleep_assert_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dbPath = tempDir.appendingPathComponent("episodes.db").path

        // 1. Success path acquires and releases.
        let successCounter = AssertionCounter()
        let (worker1, store1, _) = await makeHarness(dbPath: dbPath, assertionCounter: successCounter)
        let job = try await store1.create(NewSchedulerJob(name: "sleep-ok", schedule: "* * * * *", prompt: "Go"))
        let res1 = await worker1.tick(now: Date().addingTimeInterval(65))
        #expect(res1.first?.fired == true)
        try await Task.sleep(for: .milliseconds(30))
        let snap1 = await successCounter.snapshot()
        #expect(snap1.acquired.count == 1)
        #expect(snap1.released == 1)

        // 2. Skipped run when runLock is busy does NOT acquire assertion.
        let skipLock = SchedulerRunLock()
        _ = await skipLock.tryAcquire(id: job.id, name: job.name)
        let skipCounter = AssertionCounter()
        let (workerSkip, _, _) = await makeHarness(dbPath: dbPath, runLock: skipLock, assertionCounter: skipCounter)
        let resSkip = await workerSkip.tick(now: Date().addingTimeInterval(130))
        #expect(resSkip.first?.skippedReason == "already running")
        try await Task.sleep(for: .milliseconds(30))
        #expect(await skipCounter.snapshot().acquired.isEmpty)
        await skipLock.release(id: job.id, name: job.name)

        // 3. Failing LLM still releases assertion.
        let failCounter = AssertionCounter()
        let (workerFail, storeFail, runsFail) = await makeHarness(
            dbPath: tempDir.appendingPathComponent("fail.db").path,
            llm: FailingSchedulerLLM(),
            assertionCounter: failCounter
        )
        _ = try await storeFail.create(NewSchedulerJob(name: "sleep-fail", schedule: "* * * * *", prompt: "Go"))
        let resFail = await workerFail.tick(now: Date().addingTimeInterval(65))
        #expect(resFail.first?.errorMessage != nil)
        #expect(await runsFail.list(limit: 5).first?.status == "error")
        try await Task.sleep(for: .milliseconds(30))
        let snapFail = await failCounter.snapshot()
        #expect(snapFail.acquired.count == 1)
        #expect(snapFail.released == 1)

        // 4. Cancelled turn still releases assertion.
        let (startedStream, startedCont) = AsyncStream.makeStream(of: Void.self)
        let activeTurns = ActiveTurnTracker()
        let cancelCounter = AssertionCounter()
        let cancelDB = tempDir.appendingPathComponent("cancel.db").path
        let (workerCancel, storeCancel, _) = await makeHarness(
            dbPath: cancelDB,
            llm: BlockingCancellableLLM(started: startedCont),
            activeTurns: activeTurns,
            assertionCounter: cancelCounter
        )
        _ = try await storeCancel.create(NewSchedulerJob(name: "sleep-cancel", schedule: "* * * * *", prompt: "Go"))
        let tickTask = Task {
            await workerCancel.tick(now: Date().addingTimeInterval(65))
        }
        var iter = startedStream.makeAsyncIterator()
        _ = await iter.next()
        let running = await activeTurns.runningSessionIDs()
        for sid in running {
            await activeTurns.cancel(sessionID: sid)
        }
        let cancelledResults = await tickTask.value
        #expect(cancelledResults.first?.errorMessage == "cancelled")
        try await Task.sleep(for: .milliseconds(30))
        let snapCancel = await cancelCounter.snapshot()
        #expect(snapCancel.acquired.count == 1)
        #expect(snapCancel.released == 1)
    }

    @Test
    func `Store migrates legacy rows to strict and persists catch_up, validation, and anchors`() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("store_misfire_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dbPath = tempDir.appendingPathComponent("legacy.db").path

        // Seed a legacy job without misfire columns using raw SQLite via SQLiteHelpers.
        let handle = try SQLiteHelpers.openHandle(dbPath: dbPath, unavailable: { _ in CancellationError() })
        try SQLiteHelpers.exec(
            handle: handle,
            sql: """
            CREATE TABLE scheduler_jobs(
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL UNIQUE,
                schedule TEXT NOT NULL,
                prompt TEXT NOT NULL,
                enabled INTEGER NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            INSERT INTO scheduler_jobs(id, name, schedule, prompt, enabled, created_at, updated_at)
            VALUES ('11111111-1111-1111-1111-111111111111', 'legacy daily', '0 8 * * *', 'Check mail', 1, 1700000000, 1700000000);
            """,
            failure: { _ in CancellationError() }
        )
        sqlite3_close(handle)

        let migratedStore = await SchedulerStore.load(dbPath: dbPath)
        let migratedJob = try #require(await migratedStore.list().first)
        #expect(migratedJob.misfirePolicy == .strict)
        #expect(migratedJob.lastScheduledSlotAt == nil)
        #expect(migratedJob.scheduleAnchorAt == nil)

        // Default create uses strict + sets anchor; catch_up persists across reload.
        let strictJob = try await migratedStore.create(NewSchedulerJob(name: "strict new", schedule: "0 9 * * *", prompt: "Hi"))
        #expect(strictJob.misfirePolicy == .strict)
        #expect(strictJob.scheduleAnchorAt != nil)

        let catchUpJob = try await migratedStore.create(NewSchedulerJob(
            name: "catchup new",
            schedule: "0 7 * * *",
            prompt: "Digest",
            misfirePolicy: "catch_up"
        ))
        #expect(catchUpJob.misfirePolicy == .catchUp)

        // Invalid misfire_policy fails validation cleanly without mutating job.
        await #expect(throws: SchedulerStoreError.self) {
            _ = try await migratedStore.update(id: catchUpJob.id, UpdateSchedulerJob(misfirePolicy: "invalid_mode"))
        }
        #expect(await migratedStore.job(id: catchUpJob.id)?.misfirePolicy == .catchUp)

        // Opting strict -> catch_up resets scheduleAnchorAt; empty string resets back to strict.
        let prevUpdated = strictJob.updatedAt
        try await Task.sleep(for: .milliseconds(20))
        let optedIn = try await migratedStore.update(id: strictJob.id, UpdateSchedulerJob(misfirePolicy: "catch_up"))
        #expect(optedIn.misfirePolicy == .catchUp)
        #expect(try #require(optedIn.scheduleAnchorAt) > prevUpdated)

        let resetStrict = try await migratedStore.update(id: strictJob.id, UpdateSchedulerJob(misfirePolicy: ""))
        #expect(resetStrict.misfirePolicy == .strict)

        // Reloading from SQLite preserves catch_up.
        let reloaded = await SchedulerStore.load(dbPath: dbPath)
        #expect(await reloaded.job(id: catchUpJob.id)?.misfirePolicy == .catchUp)
    }

    @Test
    func `Strict skips missed slots past 5-minute grace while catch_up fires once across missed days and restarts`() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("misfire_eval_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dbPath = tempDir.appendingPathComponent("episodes.db").path

        let cal = Calendar.current
        let now = Date()
        let missedTime = try #require(cal.date(byAdding: .minute, value: -30, to: now))
        let comps = cal.dateComponents([.hour, .minute], from: missedTime)
        let dailyExpr = try cronFor(hour: #require(comps.hour), minute: #require(comps.minute))
        let anchorThreeDaysAgo = try #require(cal.date(byAdding: .day, value: -3, to: missedTime))

        // Seed both a strict and a catch_up job anchored 3 days ago before today's missed slot.
        let strictJob = SchedulerJob(
            name: "strict-daily",
            schedule: dailyExpr,
            prompt: "Strict work",
            enabled: true,
            createdAt: anchorThreeDaysAgo,
            updatedAt: anchorThreeDaysAgo,
            misfirePolicy: .strict,
            scheduleAnchorAt: anchorThreeDaysAgo
        )
        let catchUpJob = SchedulerJob(
            name: "catchup-daily",
            schedule: dailyExpr,
            prompt: "Catchup work",
            enabled: true,
            createdAt: anchorThreeDaysAgo,
            updatedAt: anchorThreeDaysAgo,
            misfirePolicy: .catchUp,
            scheduleAnchorAt: anchorThreeDaysAgo
        )
        SQLiteSchedulerJobStore.write(job: strictJob, dbPath: dbPath)
        SQLiteSchedulerJobStore.write(job: catchUpJob, dbPath: dbPath)

        // Fresh worker simulates launching or waking 30 minutes after the scheduled time.
        let (worker, store, runs) = await makeHarness(dbPath: dbPath)
        let firstResults = await worker.tick(now: now)
        #expect(firstResults.count == 1)
        #expect(firstResults.first?.jobName == "catchup-daily")
        #expect(firstResults.first?.fireReason == .cronCatchUp)
        #expect(await store.job(id: strictJob.id)?.lastScheduledSlotAt == nil)
        #expect(await store.job(id: catchUpJob.id)?.lastScheduledSlotAt != nil)

        // Even across a fresh restart + tick immediately afterward, catch_up fires at most once.
        let (workerAfterRestart, _, _) = await makeHarness(dbPath: dbPath)
        let secondResults = await workerAfterRestart.tick(now: now.addingTimeInterval(5))
        #expect(secondResults.isEmpty)
        #expect(await runs.list(limit: 10).count == 1)
    }

    @Test
    func `Catch_up never retries a slot that started and failed and respects creation anchor`() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("misfire_noretry_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dbPath = tempDir.appendingPathComponent("episodes.db").path

        let cal = Calendar.current
        let now = Date()
        let earlierSlot = try #require(cal.date(byAdding: .minute, value: -20, to: now))
        let comps = cal.dateComponents([.hour, .minute], from: earlierSlot)
        let expr = try cronFor(hour: #require(comps.hour), minute: #require(comps.minute))
        let anchorYesterday = try #require(cal.date(byAdding: .day, value: -1, to: earlierSlot))

        // Job anchored yesterday -> earlier slot today is missed and starts with failing LLM.
        let failingJob = SchedulerJob(
            name: "catchup-fail",
            schedule: expr,
            prompt: "Fail once",
            enabled: true,
            createdAt: anchorYesterday,
            updatedAt: anchorYesterday,
            misfirePolicy: .catchUp,
            scheduleAnchorAt: anchorYesterday
        )
        // Newly created catch_up job created AFTER today's earlier slot -> must NOT fire for earlier slot.
        let newlyCreatedJob = SchedulerJob(
            name: "catchup-brand-new",
            schedule: expr,
            prompt: "Do not backfill",
            enabled: true,
            createdAt: now.addingTimeInterval(-60),
            updatedAt: now.addingTimeInterval(-60),
            misfirePolicy: .catchUp,
            scheduleAnchorAt: now.addingTimeInterval(-60)
        )
        SQLiteSchedulerJobStore.write(job: failingJob, dbPath: dbPath)
        SQLiteSchedulerJobStore.write(job: newlyCreatedJob, dbPath: dbPath)

        let (failingWorker, storeAfterFail, runs) = await makeHarness(dbPath: dbPath, llm: FailingSchedulerLLM())
        let failResults = await failingWorker.tick(now: now)
        #expect(failResults.count == 1)
        #expect(failResults.first?.jobName == "catchup-fail")
        #expect(await runs.list(limit: 5).first?.status == "error")
        #expect(await storeAfterFail.job(id: failingJob.id)?.lastScheduledSlotAt != nil)
        #expect(await storeAfterFail.job(id: newlyCreatedJob.id)?.lastScheduledSlotAt == nil)

        // Subsequent restart with healthy LLM must NOT retry the started failure.
        let (healthyWorker, _, _) = await makeHarness(dbPath: dbPath, llm: SchedulerStubLLM(answer: "recovered"))
        let retryResults = await healthyWorker.tick(now: now.addingTimeInterval(30))
        #expect(retryResults.isEmpty)
        #expect(await runs.list(limit: 10).count == 1)
    }

    @Test
    func `Wake signal interrupts long idle tick sleep immediately`() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("wake_signal_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dbPath = tempDir.appendingPathComponent("episodes.db").path

        let dir = tempDir
        let memoryEngine = MemoryEngine(
            episodesDBPath: dbPath,
            vectorDBPath: dir.appendingPathComponent("vectors").path,
            profilePath: dir.appendingPathComponent("profile.json").path
        )
        let conversations = ConversationManager(episodesDBPath: dbPath)
        let bus = ToolBus()
        let orchestrator = Orchestrator(conversations: conversations, toolBus: bus, llm: SchedulerStubLLM(), memoryEngine: memoryEngine)
        let store = await SchedulerStore.load(dbPath: dbPath)
        let runs = await RunLogStore.load(dbPath: dbPath)
        let counter = AssertionCounter()
        let worker = ServerSchedulerWorker(
            scheduler: store,
            runs: runs,
            hub: WSHub(),
            runLock: SchedulerRunLock(),
            orchestrator: orchestrator,
            conversations: conversations,
            toolBus: bus,
            intervalSeconds: 300,
            acquireSleepAssertion: { reason in
                Task { await counter.recordAcquire(reason) }
                return SystemSleepAssertion.testToken {
                    Task { await counter.recordRelease() }
                }
            }
        )

        await worker.start()
        defer { Task { await worker.stop() } }

        // Wait until the initial tick completes and the loop parks inside the 300s idle sleep.
        for _ in 0 ..< 250 {
            if await worker.isSleepingForNextTick {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await worker.isSleepingForNextTick)

        // Seed a missed catch_up job whose slot fell 10 minutes ago (after yesterday's anchor).
        let cal = Calendar.current
        let tenMinAgo = try #require(cal.date(byAdding: .minute, value: -10, to: Date()))
        let comps = cal.dateComponents([.hour, .minute], from: tenMinAgo)
        let yesterday = try #require(cal.date(byAdding: .day, value: -1, to: tenMinAgo))
        let schedule = try cronFor(hour: #require(comps.hour), minute: #require(comps.minute))
        let missedJob = SchedulerJob(
            name: "wake-catchup",
            schedule: schedule,
            prompt: "Run on wake",
            enabled: true,
            createdAt: yesterday,
            updatedAt: yesterday,
            misfirePolicy: .catchUp,
            scheduleAnchorAt: yesterday
        )
        await store.upsertJob(missedJob)

        // Verify wakeNow() interrupts the 300s idle sleep quickly rather than waiting 5 minutes.
        let wokeAt = ContinuousClock.now
        await worker.wakeNow()

        var completed = false
        for _ in 0 ..< 250 {
            let logged = await runs.list(limit: 5)
            if logged.contains(where: { $0.jobID == missedJob.id && $0.status == "ok" }) {
                completed = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(completed)
        #expect(ContinuousClock.now - wokeAt < .seconds(10))
        await worker.stop()
    }
}

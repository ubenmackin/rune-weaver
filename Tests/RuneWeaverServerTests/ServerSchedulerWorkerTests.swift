// Rune Weaver Tests — ServerSchedulerWorker automated execution tests.

import Foundation
import RuneWeaverCore
@testable import RuneWeaverServer
import Testing

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

@Suite("Server Scheduler Worker")
struct ServerSchedulerWorkerTests {
    private func makeWorker(
        answer: String = "done",
        llm: (any LLMProvider)? = nil,
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
}

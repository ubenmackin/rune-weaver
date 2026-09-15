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

@Suite("Server Scheduler Worker")
struct ServerSchedulerWorkerTests {
    private func makeWorker(
        answer: String = "done"
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
        let bus = ToolBus()
        let orchestrator = Orchestrator(
            conversations: conversations,
            toolBus: bus,
            llm: SchedulerStubLLM(answer: answer),
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
}

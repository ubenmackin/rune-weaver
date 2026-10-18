// Rune Weaver Tests — ServerSchedulerWorker automated execution tests.

import Foundation
@testable import RuneWeaverCore
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

    /// Seeds one legacy marker fact straight into the semantic store.
    private func seedLegacyMarker(_ content: String, into engine: MemoryEngine) async throws {
        try await engine.semanticStoreUpsert(
            StoredFact(
                id: UUID(),
                content: content,
                embedding: [],
                metadata: ["source": "chat"],
                createdAt: Date(),
                updatedAt: Date()
            )
        )
    }

    /// Asserts one cursor still reads as the seeded instant.
    private func expectCursor(_ cursor: Date?, stays seeded: Date) {
        guard let cursor else {
            Issue.record("cursor must survive the sweep")
            return
        }
        #expect(abs(cursor.timeIntervalSince(seeded)) < 1)
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
    func `Migration seeds newest date then deletes markers`() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("sched_migrate_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let scheduler = SchedulerStore()
        let job = try await scheduler.create(NewSchedulerJob(
            name: "email watcher",
            schedule: "* * * * *",
            prompt: "Check inbox",
            pollAccount: "personal"
        ))
        let memoryEngine = MemoryEngine(
            episodesDBPath: tempDir.appendingPathComponent("episodes.db").path,
            vectorDBPath: tempDir.appendingPathComponent("vectors").path,
            profilePath: tempDir.appendingPathComponent("profile.json").path
        )
        try await seedLegacyMarker("Email report last run: 2026-09-01T08:00:00Z", into: memoryEngine)
        try await seedLegacyMarker("Email report last run: 2026-10-02T09:30:00Z", into: memoryEngine)
        let migrated = await scheduler.migrateEmailReportMarkers(memoryEngine: memoryEngine)
        #expect(migrated.deletedMarkerCount == 2)
        #expect(migrated.seededCount == 1)
        let expected = SchedulerStore.embeddedRunDate(in: "Email report last run: 2026-10-02T09:30:00Z")
        let cursor = await scheduler.job(id: job.id)?.lastSuccessfulRunEndedAt
        #expect(cursor != nil)
        if let cursor, let expected {
            #expect(abs(cursor.timeIntervalSince(expected)) < 1)
        }
        let remaining = await memoryEngine.allSemanticFacts().filter { SchedulerStore.isEmailReportMarker($0.content) }
        #expect(remaining.isEmpty)
        let page = await memoryEngine.searchFactsPage(query: "Email report last run")
        #expect(page.total == 0)
    }

    @Test
    func `Boot tail migrates markers into owning cursor then deletes`() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("sched_boot_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dbPath = tempDir.appendingPathComponent("episodes.db").path
        let memoryEngine = MemoryEngine(
            episodesDBPath: dbPath,
            vectorDBPath: tempDir.appendingPathComponent("vectors").path,
            profilePath: tempDir.appendingPathComponent("profile.json").path
        )
        // Durable boot entry, mirroring loadDurableServerStores.
        let scheduler = await SchedulerStore.load(dbPath: dbPath)
        let emailJob = try await scheduler.create(NewSchedulerJob(
            name: "email watcher",
            schedule: "* * * * *",
            prompt: "Check inbox",
            pollAccount: "personal"
        ))
        let calendarJob = try await scheduler.create(NewSchedulerJob(
            name: "calendar sync",
            schedule: "* * * * *",
            prompt: "Sync calendar events"
        ))
        try await seedLegacyMarker("Email report last run: 2026-09-01T08:00:00Z", into: memoryEngine)
        try await seedLegacyMarker("Email report last run: 2026-10-02T09:30:00Z", into: memoryEngine)
        try await seedLegacyMarker("Email report last run: pending review", into: memoryEngine)
        try await memoryEngine.storeProfileFact(content: "Discussing the email report from last run planning", source: "chat")
        let conversations = ConversationManager(episodesDBPath: dbPath)
        let runs = await RunLogStore.load(dbPath: dbPath)
        let worker = ServerSchedulerWorker(
            scheduler: scheduler,
            runs: runs,
            hub: WSHub(),
            runLock: SchedulerRunLock(),
            orchestrator: Orchestrator(
                conversations: conversations,
                toolBus: ToolBus(),
                llm: SchedulerStubLLM(answer: "ok"),
                memoryEngine: memoryEngine
            ),
            conversations: conversations,
            toolBus: ToolBus()
        )
        // Boot-tail one-shot, mirroring ServerContext.bootstrapServices.
        let migrated = await worker.migrateEmailReportMarkers(memoryEngine: memoryEngine)
        #expect(migrated.deletedMarkerCount == 3)
        #expect(migrated.seededCount == 1)
        let expected = SchedulerStore.embeddedRunDate(in: "Email report last run: 2026-10-02T09:30:00Z")
        let cursor = await scheduler.job(id: emailJob.id)?.lastSuccessfulRunEndedAt
        #expect(cursor != nil)
        if let cursor, let expected {
            #expect(abs(cursor.timeIntervalSince(expected)) < 1)
        }
        #expect(await scheduler.job(id: calendarJob.id)?.lastSuccessfulRunEndedAt == nil)
        let remaining = await memoryEngine.allSemanticFacts()
        // The reserved shape is the deletable unit, so the unparseable "pending review" marker is
        // swept beside the dated ones instead of being stranded to compete in recall; a freeform
        // note that merely mentions the marker words is not a marker and survives.
        let markersLeft = remaining.filter { SchedulerStore.isEmailReportMarker($0.content) }
        #expect(markersLeft.isEmpty)
        #expect(remaining.contains(where: { $0.content == "Discussing the email report from last run planning" }))
    }

    @Test
    func `Future dated marker never seeds a cursor`() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("sched_future_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let scheduler = SchedulerStore()
        let job = try await scheduler.create(NewSchedulerJob(
            name: "email watcher",
            schedule: "* * * * *",
            prompt: "Check inbox",
            pollAccount: "personal"
        ))
        let memoryEngine = MemoryEngine(
            episodesDBPath: tempDir.appendingPathComponent("episodes.db").path,
            vectorDBPath: tempDir.appendingPathComponent("vectors").path,
            profilePath: tempDir.appendingPathComponent("profile.json").path
        )
        try await seedLegacyMarker("Email report last run: 2999-01-01T00:00:00Z", into: memoryEngine)
        let migrated = await scheduler.migrateEmailReportMarkers(memoryEngine: memoryEngine)
        // A marker dated after the boot instant cannot record a real run, so it
        // is neither seeded nor consumed: the cursor stays put and the marker
        // survives as evidence.
        #expect(migrated.seeds.isEmpty)
        #expect(migrated.deletedMarkerCount == 0)
        #expect(await scheduler.job(id: job.id)?.lastSuccessfulRunEndedAt == nil)
        let remaining = await memoryEngine.allSemanticFacts().filter { SchedulerStore.isEmailReportMarker($0.content) }
        #expect(remaining.count == 1)
    }

    @Test
    func `Marker migration stays one shot across boots`() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("sched_oneshot_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dbPath = tempDir.appendingPathComponent("episodes.db").path
        let memoryEngine = MemoryEngine(
            episodesDBPath: dbPath,
            vectorDBPath: tempDir.appendingPathComponent("vectors").path,
            profilePath: tempDir.appendingPathComponent("profile.json").path
        )
        let scheduler = await SchedulerStore.load(dbPath: dbPath)
        let job = try await scheduler.create(NewSchedulerJob(
            name: "email watcher",
            schedule: "* * * * *",
            prompt: "Check inbox",
            pollAccount: "personal"
        ))
        try await seedLegacyMarker("Email report last run: 2026-10-02T09:30:00Z", into: memoryEngine)
        let first = await scheduler.migrateEmailReportMarkers(memoryEngine: memoryEngine)
        #expect(first.seededCount == 1)
        #expect(first.deletedMarkerCount == 1)
        let seeded = try #require(await scheduler.job(id: job.id)?.lastSuccessfulRunEndedAt)

        // A marker written after the sweep must stay inert, in this process and
        // in every later boot, because the consumed latch is durable.
        try await seedLegacyMarker("Email report last run: 2026-10-05T07:15:00Z", into: memoryEngine)
        let second = await scheduler.migrateEmailReportMarkers(memoryEngine: memoryEngine)
        #expect(second.seeds.isEmpty)
        #expect(second.deletedMarkerCount == 0)
        await expectCursor(scheduler.job(id: job.id)?.lastSuccessfulRunEndedAt, stays: seeded)

        let rebooted = await SchedulerStore.load(dbPath: dbPath)
        let third = await rebooted.migrateEmailReportMarkers(memoryEngine: memoryEngine)
        #expect(third.seeds.isEmpty)
        #expect(third.deletedMarkerCount == 0)
        await expectCursor(rebooted.job(id: job.id)?.lastSuccessfulRunEndedAt, stays: seeded)
    }

    @Test
    func `Explicit email report flag scopes seeding to the owning job`() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("sched_flag_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let scheduler = SchedulerStore()
        let flagged = try await scheduler.create(NewSchedulerJob(
            name: "morning digest",
            schedule: "0 8 * * *",
            prompt: "Summarize the day",
            emailReportJob: true
        ))
        let mailMentioning = try await scheduler.create(NewSchedulerJob(
            name: "inbox tidy",
            schedule: "0 9 * * *",
            prompt: "Tidy the mail folders"
        ))
        let memoryEngine = MemoryEngine(
            episodesDBPath: tempDir.appendingPathComponent("episodes.db").path,
            vectorDBPath: tempDir.appendingPathComponent("vectors").path,
            profilePath: tempDir.appendingPathComponent("profile.json").path
        )
        try await seedLegacyMarker("Email report last run: 2026-10-02T09:30:00Z", into: memoryEngine)
        let migrated = await scheduler.migrateEmailReportMarkers(memoryEngine: memoryEngine)
        // Only the owner-flagged job inherits the seeded cursor: job text is
        // never sniffed, so a prompt that merely mentions mail stays inert.
        #expect(migrated.seededCount == 1)
        #expect(migrated.seeds.first?.jobID == flagged.id)
        #expect(await scheduler.job(id: flagged.id)?.lastSuccessfulRunEndedAt != nil)
        #expect(await scheduler.job(id: mailMentioning.id)?.lastSuccessfulRunEndedAt == nil)
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
}

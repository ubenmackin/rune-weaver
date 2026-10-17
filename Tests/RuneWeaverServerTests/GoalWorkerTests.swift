// Rune Weaver Server Tests — Goal advancement firing in the scheduler worker.

import Foundation
import NIOWebSocket
import os
import RuneWeaverCore
@testable import RuneWeaverServer
import Testing

/// Stub provider replaying one canned answer for every turn.
private final class GoalFireStubLLM: LLMProvider, Sendable {
    /// Stable test model metadata.
    let modelInfo = ModelInfo(name: "goal-fixture", provider: "test", contextLength: 8192)
    /// Canned answer text.
    private let answer: String

    /// Creates a stub.
    init(answer: String) {
        self.answer = answer
    }

    /// Replays the canned answer as a finished stream.
    func chat(messages _: [Message], tools _: [any Tool]) -> AsyncStream<LLMResponse> {
        let text = answer
        return AsyncStream { continuation in
            continuation.yield(LLMResponse(delta: text))
            continuation.yield(LLMResponse(delta: "", isFinished: true, totalTokens: 7))
            continuation.finish()
        }
    }

    /// Unused embeddings stub.
    func embeddings(text _: [String]) async throws -> [[Float]] {
        []
    }
}

/// Scripted provider replaying canned texts in call order for parked turns.
private final class GoalScriptedLLM: LLMProvider, Sendable {
    /// Stable test model metadata.
    let modelInfo = ModelInfo(name: "goal-park-fixture", provider: "test", contextLength: 8192)
    /// Guarded script state.
    private let state: OSAllocatedUnfairLock<(texts: [String], index: Int)>

    /// Creates a scripted provider.
    init(texts: [String]) {
        self.state = OSAllocatedUnfairLock(initialState: (texts, 0))
    }

    /// Replays the next canned text as a finished stream.
    func chat(messages _: [Message], tools _: [any Tool]) -> AsyncStream<LLMResponse> {
        let text: String = state.withLock { script in
            let next = script.index < script.texts.count ? script.texts[script.index] : script.texts.last ?? ""
            script.index += 1
            return next
        }
        return AsyncStream { continuation in
            continuation.yield(LLMResponse(delta: text, isFinished: true))
            continuation.finish()
        }
    }

    /// Unused embeddings stub.
    func embeddings(text _: [String]) async throws -> [[Float]] {
        []
    }
}

/// Approval-gated fixture tool for parked goal turns.
private struct GoalGatedTool: Tool, Sendable {
    /// Registered tool name.
    let name = "goal.write"
    /// Approval-gated permission level.
    let permissionLevel = PermissionLevel.requiresApproval
    /// Human-readable description.
    var description: String {
        "Fixture gated stub for goal advancement."
    }

    /// Empty-object schema.
    let inputSchema = JSONSchema(rawValue: #"{"type":"object"}"#)

    /// Executes the stub successfully.
    func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        .success("goal-write-ok", callID: input.callID)
    }
}

/// Recording socket capturing hub broadcasts without a live handshake.
private actor GoalWorkerRecordingSocket: WSConnectionSocket {
    /// Frames delivered to this connection.
    private(set) var sent: [String] = []

    /// Records one frame.
    func send(_ text: String) async throws {
        sent.append(text)
    }

    /// Ignored; these tests never close the connection.
    func close(code _: WebSocketErrorCode) async throws {}
}

/// Creates an isolated temporary database path and its base directory.
private func makeGoalDBPath() throws -> (path: String, base: URL) {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("goal-worker-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return (base.appendingPathComponent("episodes.db").path, base)
}

/// Builds an enabled goal engine over the given store with a stub planner.
private func makeEnabledGoalEngine(store: GoalStore, llm: any LLMProvider) -> GoalEngine {
    var config = GoalsConfig()
    config.enabled = true
    return GoalEngine(store: store, llm: llm, config: config)
}

/// Persists one active goal with a single pending step directly through the store.
private func persistGoal(
    store: GoalStore,
    title: String = "Tend herbs",
    statement: String = "Keep the kitchen herbs alive",
    nextDueAt: Date?,
    stepTitle: String = "Water basil"
) async throws -> Goal {
    let now = Date()
    let goal = Goal(
        title: title,
        statement: statement,
        status: .active,
        stepIntervalMinutes: 60,
        nextDueAt: nextDueAt,
        createdAt: now,
        updatedAt: now
    )
    let step = GoalStep(goalID: goal.id, ordinal: 0, title: stepTitle, status: .pending)
    try await store.create(goal: goal, steps: [step])
    return goal
}

@Suite("Goal Scheduler Worker")
struct GoalWorkerTests {
    @Test
    func `Due goal fires one linked turn with goal source`() async throws {
        let (dbPath, base) = try makeGoalDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = GoalStore(dbPath: dbPath)
        let goal = try await persistGoal(store: store, nextDueAt: Date().addingTimeInterval(-60))

        let stub = GoalFireStubLLM(answer: "advanced one step")
        let conversations = ConversationManager()
        let bus = ToolBus()
        let orchestrator = Orchestrator(conversations: conversations, toolBus: bus, llm: stub)
        let scheduler = SchedulerStore()
        let runs = RunLogStore()
        let hub = WSHub()
        let engine = makeEnabledGoalEngine(store: store, llm: stub)
        let worker = ServerSchedulerWorker(
            scheduler: scheduler,
            runs: runs,
            hub: hub,
            runLock: SchedulerRunLock(),
            orchestrator: orchestrator,
            conversations: conversations,
            toolBus: bus,
            goalStore: store,
            goalEngine: engine,
            goalRunLock: SchedulerRunLock()
        )

        let results = await worker.tick(now: Date())
        #expect(results.count == 1)
        #expect(results.first?.fired == true)
        #expect(results.first?.jobName == goal.title)
        #expect(results.first?.responseText == "advanced one step")

        // The background helper keeps scheduler and goal turns on one branch.
        #expect(Orchestrator.isBackgroundSource("goal") == true)
        #expect(Orchestrator.isBackgroundSource("scheduler") == true)
        #expect(Orchestrator.isBackgroundSource("text") == false)
        #expect(Orchestrator.isBackgroundSource(nil) == false)

        let logged = await runs.list(limit: 10)
        #expect(logged.count == 1)
        let entry = try #require(logged.first)
        #expect(entry.kind == "goal")
        #expect(entry.status == "ok")
        #expect(entry.goalID == goal.id)
        #expect(entry.message == goal.title)
        let sessionID = try #require(entry.sessionID)
        #expect(results.first?.sessionID == sessionID)
        // The fired goal result carries the goal link beside the real session.
        #expect(results.first?.goalID == goal.id)

        // The per-run session carries the goal source plus the durable link
        // so parked resumes and history filters stay joinable.
        let session = await conversations.session(id: sessionID)
        #expect(session?.source == "goal")
        #expect(session?.goalID == goal.id)

        // The due bump re-arms the next interval instead of stacking a second
        // immediate fire for the same due date.
        let second = await worker.tick(now: Date())
        #expect(second.isEmpty)
    }

    @Test
    func `Not-due goal stays silent`() async throws {
        let (dbPath, base) = try makeGoalDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = GoalStore(dbPath: dbPath)
        _ = try await persistGoal(store: store, nextDueAt: Date().addingTimeInterval(3600))

        let stub = GoalFireStubLLM(answer: "should not run")
        let conversations = ConversationManager()
        let bus = ToolBus()
        let orchestrator = Orchestrator(conversations: conversations, toolBus: bus, llm: stub)
        let engine = makeEnabledGoalEngine(store: store, llm: stub)
        let runs = RunLogStore()
        let worker = ServerSchedulerWorker(
            scheduler: SchedulerStore(),
            runs: runs,
            hub: WSHub(),
            runLock: SchedulerRunLock(),
            orchestrator: orchestrator,
            conversations: conversations,
            toolBus: bus,
            goalStore: store,
            goalEngine: engine,
            goalRunLock: SchedulerRunLock()
        )

        let results = await worker.tick(now: Date())
        #expect(results.isEmpty)
        #expect(await runs.count() == 0)
    }

    @Test
    func `Contended goal lock skips honestly`() async throws {
        let (dbPath, base) = try makeGoalDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = GoalStore(dbPath: dbPath)
        let goal = try await persistGoal(store: store, nextDueAt: Date().addingTimeInterval(-30))

        let stub = GoalFireStubLLM(answer: "should not run")
        let conversations = ConversationManager()
        let bus = ToolBus()
        let orchestrator = Orchestrator(conversations: conversations, toolBus: bus, llm: stub)
        let engine = makeEnabledGoalEngine(store: store, llm: stub)
        let runs = RunLogStore()
        let goalLock = SchedulerRunLock()
        let acquired = await goalLock.tryAcquire(id: goal.id, name: goal.title)
        #expect(acquired == true)

        let logged = OSAllocatedUnfairLock(initialState: [String]())
        let worker = ServerSchedulerWorker(
            scheduler: SchedulerStore(),
            runs: runs,
            hub: WSHub(),
            runLock: SchedulerRunLock(),
            orchestrator: orchestrator,
            conversations: conversations,
            toolBus: bus,
            logger: { line in logged.withLock { $0.append(line) } },
            goalStore: store,
            goalEngine: engine,
            goalRunLock: goalLock
        )

        let results = await worker.tick(now: Date())
        #expect(results.count == 1)
        #expect(results.first?.fired == false)
        #expect(results.first?.skippedReason == "already running")
        // A skipped goal never masquerades its goal identifier as a session:
        // the result carries a placeholder session plus the separate goal link.
        #expect(results.first?.sessionID != goal.id)
        #expect(results.first?.goalID == goal.id)
        #expect(logged.withLock { $0 }.contains(where: { $0.contains(goal.title) }) == true)

        // The skip still leaves an honest audit row carrying the goal link
        // without inventing an orphan session.
        let loggedRuns = await runs.list(limit: 10)
        #expect(loggedRuns.count == 1)
        #expect(loggedRuns.first?.status == "skipped")
        #expect(loggedRuns.first?.kind == "goal")
        #expect(loggedRuns.first?.goalID == goal.id)
        #expect(loggedRuns.first?.sessionID == nil)
        await goalLock.release(id: goal.id, name: goal.title)
    }

    @Test
    func `Parked goal turn resumes with linkage intact`() async throws {
        let (dbPath, base) = try makeGoalDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = GoalStore(dbPath: dbPath)
        let goal = try await persistGoal(store: store, nextDueAt: Date().addingTimeInterval(-30))

        let narrated = ToolInput.placeholderContent(for: [
            ToolInput(toolName: "goal.write", argumentsJSON: #"{"text":"hi"}"#, callID: "call_goal_park")
        ])
        let scripted = GoalScriptedLLM(texts: [narrated, "Goal synthesis done."])
        let conversations = ConversationManager()
        let gate = PermissionGate()
        let approvals = ApprovalQueue(permissionGate: gate)
        let bus = ToolBus(permissionGate: gate)
        await bus.register(tool: GoalGatedTool())
        let orchestrator = Orchestrator(
            conversations: conversations,
            toolBus: bus,
            llm: scripted,
            toolResolver: { _, _ in [] },
            approvalQueue: approvals
        )
        let planningStub = GoalFireStubLLM(answer: "unused")
        let engine = makeEnabledGoalEngine(store: store, llm: planningStub)
        let runs = RunLogStore()
        let worker = ServerSchedulerWorker(
            scheduler: SchedulerStore(),
            runs: runs,
            hub: WSHub(),
            runLock: SchedulerRunLock(),
            orchestrator: orchestrator,
            conversations: conversations,
            toolBus: bus,
            goalStore: store,
            goalEngine: engine,
            goalRunLock: SchedulerRunLock()
        )

        let results = await worker.tick(now: Date())
        #expect(results.count == 1)
        #expect(results.first?.fired == true)

        let parkedRuns = await runs.list(limit: 10)
        #expect(parkedRuns.count == 1)
        let parked = try #require(parkedRuns.first)
        #expect(parked.kind == "goal")
        #expect(parked.status == "awaiting_approval")
        #expect(parked.goalID == goal.id)
        let sessionID = try #require(parked.sessionID)
        #expect(await orchestrator.isSessionParked(sessionID) == true)

        // Claiming the turn bumps next_due_at by the goal cadence immediately, so
        // 1-minute ticks during the cadence window stay completely silent instead
        // of spamming "already running" every minute.
        let withinCadenceTickResults = await worker.tick(now: Date())
        #expect(withinCadenceTickResults.isEmpty)

        // If the cadence window elapses while the goal turn is still parked
        // awaiting approval, the next due tick skips once with "already running"
        // and suppresses duplicate skips on subsequent minutes for that due date.
        let pastCadenceNow = Date().addingTimeInterval(3601)
        let busyTickResults = await worker.tick(now: pastCadenceNow)
        #expect(busyTickResults.count == 1)
        #expect(busyTickResults.first?.fired == false)
        #expect(busyTickResults.first?.skippedReason == "already running")
        let repeatedBusyTick = await worker.tick(now: pastCadenceNow.addingTimeInterval(60))
        #expect(repeatedBusyTick.isEmpty)

        let pending = await approvals.list().first
        let approvalID = try #require(pending?.id)
        #expect(await approvals.decide(id: approvalID, approved: true) == true)
        let resumed = try await orchestrator.resumeNarratedApproval(id: approvalID, approved: true)
        let final = try #require(resumed)
        #expect(final.isParked == false)
        #expect(final.sessionID == sessionID)
        #expect(final.text == "Goal synthesis done.")
        #expect(await orchestrator.isSessionParked(sessionID) == false)

        // The resumed session keeps its goal source and link so history and
        // run rows stay joinable after the inbox decision.
        let session = await conversations.session(id: sessionID)
        #expect(session?.source == "goal")
        #expect(session?.goalID == goal.id)
    }

    @Test
    func `Nightly tick refreshes ideas and broadcasts the proactive frame`() async throws {
        let (dbPath, base) = try makeGoalDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let goalStore = GoalStore(dbPath: dbPath)
        let stub = GoalFireStubLLM(answer: "unused")
        let goalEngine = makeEnabledGoalEngine(store: goalStore, llm: stub)

        let ideasStore = IdeasStore(dbPath: dbPath)
        var ideasConfig = IdeasConfig()
        ideasConfig.enabled = true
        let ideasLLM = GoalFireStubLLM(answer: #"[{"kind":"tip","title":"Hydrate","body":"Drink water."}]"#)
        let ideasEngine = IdeasEngine(store: ideasStore, llm: ideasLLM, config: ideasConfig)

        let conversations = ConversationManager()
        let bus = ToolBus()
        let orchestrator = Orchestrator(conversations: conversations, toolBus: bus, llm: stub)
        let hub = WSHub()
        let socket = GoalWorkerRecordingSocket()
        _ = await hub.add(id: UUID(), box: socket)
        let worker = ServerSchedulerWorker(
            scheduler: SchedulerStore(),
            runs: RunLogStore(),
            hub: hub,
            runLock: SchedulerRunLock(),
            orchestrator: orchestrator,
            conversations: conversations,
            toolBus: bus,
            goalStore: goalStore,
            goalEngine: goalEngine,
            ideasEngine: ideasEngine,
            goalRunLock: SchedulerRunLock()
        )

        // The cadence high-water mark starts at construction, so the first tick
        // must advance past one full window to spend the review call.
        let later = Date().addingTimeInterval(2 * ServerSchedulerWorker.ideasRefreshInterval)
        _ = await worker.tick(now: later)

        let proposed = try await ideasStore.list(status: .proposed)
        #expect(proposed.map(\.title) == ["Hydrate"])
        let frames = await socket.sent
        #expect(frames.count == 1)
        let raw = try #require(frames.first)
        let decoded = try JSONDecoder().decode(WSProactiveMessageFrame.self, from: Data(raw.utf8))
        #expect(decoded.kind == WSProactiveMessageFrame.ideaProposedKind)
        #expect(decoded.title == "Hydrate")
        #expect(decoded.headline == "Drink water.")

        // A second tick inside the same cadence window stays quiet.
        _ = await worker.tick(now: later.addingTimeInterval(60))
        let after = await socket.sent
        #expect(after.count == 1)
    }

    @Test
    func `Achieving a goal surfaces its generated ideas on the proactive frame`() async throws {
        let (dbPath, base) = try makeGoalDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let goalStore = GoalStore(dbPath: dbPath)
        let now = Date()
        let goal = Goal(
            title: "Finish the report",
            statement: "Wrap it up",
            status: .active,
            stepIntervalMinutes: 60,
            nextDueAt: now.addingTimeInterval(-60),
            createdAt: now,
            updatedAt: now
        )
        // A plan with no actionable step flips the goal to achieved in the
        // post-advance scan, which is the hook that spends the ideas review call.
        try await goalStore.create(
            goal: goal,
            steps: [GoalStep(goalID: goal.id, ordinal: 0, title: "Draft", status: .done)]
        )

        let turnStub = GoalFireStubLLM(answer: "all done")
        let conversations = ConversationManager()
        let bus = ToolBus()
        let orchestrator = Orchestrator(conversations: conversations, toolBus: bus, llm: turnStub)

        let ideasStore = IdeasStore(dbPath: dbPath)
        var ideasConfig = IdeasConfig()
        ideasConfig.enabled = true
        let ideasLLM = GoalFireStubLLM(answer: #"[{"kind":"tip","title":"Plan the next win","body":"Pick one small goal."}]"#)
        let ideasEngine = IdeasEngine(store: ideasStore, llm: ideasLLM, config: ideasConfig)
        var goalsConfig = GoalsConfig()
        goalsConfig.enabled = true
        let goalEngine = GoalEngine(store: goalStore, llm: turnStub, config: goalsConfig, ideasEngine: ideasEngine)

        let hub = WSHub()
        let socket = GoalWorkerRecordingSocket()
        _ = await hub.add(id: UUID(), box: socket)
        let worker = ServerSchedulerWorker(
            scheduler: SchedulerStore(),
            runs: RunLogStore(),
            hub: hub,
            runLock: SchedulerRunLock(),
            orchestrator: orchestrator,
            conversations: conversations,
            toolBus: bus,
            goalStore: goalStore,
            goalEngine: goalEngine,
            ideasEngine: ideasEngine,
            goalRunLock: SchedulerRunLock()
        )

        _ = await worker.tick(now: Date())

        #expect(try await goalStore.goal(id: goal.id)?.status == .achieved)
        // Generation persists the achievement-born suggestion, and the worker
        // announces it despite the store's title dedup swallowing the next
        // nightly batch.
        let proposed = try await ideasStore.list(status: .proposed)
        #expect(proposed.map(\.title) == ["Plan the next win"])
        let frames = await socket.sent
        let ideaFrames = frames.compactMap { raw -> WSProactiveMessageFrame? in
            guard let decoded = try? JSONDecoder().decode(WSProactiveMessageFrame.self, from: Data(raw.utf8)),
                  decoded.kind == WSProactiveMessageFrame.ideaProposedKind
            else { return nil }
            return decoded
        }
        #expect(ideaFrames.count == 1)
        #expect(ideaFrames.first?.title == "Plan the next win")
        #expect(ideaFrames.first?.headline == "Pick one small goal.")
    }

    @Test
    func `Off proactive mode suppresses nightly idea frames`() async throws {
        let (dbPath, base) = try makeGoalDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let goalStore = GoalStore(dbPath: dbPath)
        let stub = GoalFireStubLLM(answer: "unused")
        let goalEngine = makeEnabledGoalEngine(store: goalStore, llm: stub)

        let ideasStore = IdeasStore(dbPath: dbPath)
        var ideasConfig = IdeasConfig()
        ideasConfig.enabled = true
        let ideasLLM = GoalFireStubLLM(answer: #"[{"kind":"tip","title":"Hydrate","body":"Drink water."}]"#)
        let ideasEngine = IdeasEngine(store: ideasStore, llm: ideasLLM, config: ideasConfig)

        let conversations = ConversationManager()
        let bus = ToolBus()
        let orchestrator = Orchestrator(conversations: conversations, toolBus: bus, llm: stub)
        let hub = WSHub()
        let socket = GoalWorkerRecordingSocket()
        _ = await hub.add(id: UUID(), box: socket)
        let worker = ServerSchedulerWorker(
            scheduler: SchedulerStore(),
            runs: RunLogStore(),
            hub: hub,
            runLock: SchedulerRunLock(),
            orchestrator: orchestrator,
            conversations: conversations,
            toolBus: bus,
            goalStore: goalStore,
            goalEngine: goalEngine,
            ideasEngine: ideasEngine,
            goalRunLock: SchedulerRunLock(),
            proactiveConfig: ProactiveConfig(mode: .off)
        )

        let later = Date().addingTimeInterval(2 * ServerSchedulerWorker.ideasRefreshInterval)
        _ = await worker.tick(now: later)

        // The suggestion is still generated and persisted; only the interruption
        // frame is suppressed, so an `off` install stays silent on the wire.
        let proposed = try await ideasStore.list(status: .proposed)
        #expect(proposed.map(\.title) == ["Hydrate"])
        let frames = await socket.sent
        let ideaFrames = frames.filter { raw in
            (try? JSONDecoder().decode(WSProactiveMessageFrame.self, from: Data(raw.utf8)))?.kind
                == WSProactiveMessageFrame.ideaProposedKind
        }
        #expect(ideaFrames.isEmpty)
    }

    @Test
    func `Active turn in tracker prevents duplicate goal advancement`() async throws {
        let (dbPath, base) = try makeGoalDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = GoalStore(dbPath: dbPath)
        let goal = try await persistGoal(store: store, nextDueAt: Date().addingTimeInterval(-60))

        let stub = GoalFireStubLLM(answer: "advanced")
        let conversations = ConversationManager()
        let bus = ToolBus()
        let orchestrator = Orchestrator(conversations: conversations, toolBus: bus, llm: stub)
        let activeTurns = ActiveTurnTracker()
        let session = await conversations.createSession(goalID: goal.id)
        await activeTurns.register(sessionID: session.id, onCancel: {})

        let runs = RunLogStore()
        let engine = makeEnabledGoalEngine(store: store, llm: stub)
        let worker = ServerSchedulerWorker(
            scheduler: SchedulerStore(),
            runs: runs,
            hub: WSHub(),
            runLock: SchedulerRunLock(),
            orchestrator: orchestrator,
            conversations: conversations,
            toolBus: bus,
            goalStore: store,
            goalEngine: engine,
            goalRunLock: SchedulerRunLock(),
            activeTurns: activeTurns
        )

        let results = await worker.tick(now: Date())
        #expect(results.count == 1)
        #expect(results.first?.fired == false)
        #expect(results.first?.skippedReason == "already running")
        #expect(await runs.count() == 1)
        #expect(await runs.list(limit: 1).first?.status == "skipped")

        // Subsequent 1-minute ticks while the turn is still running for the same
        // due date do not emit duplicate "already running" skip entries.
        let secondTick = await worker.tick(now: Date().addingTimeInterval(60))
        #expect(secondTick.isEmpty)
        #expect(await runs.count() == 1)
    }

    @Test
    func `Deleted goal skip suppression entry is pruned on the next tick`() async throws {
        let (dbPath, base) = try makeGoalDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = GoalStore(dbPath: dbPath)
        let goal = try await persistGoal(store: store, nextDueAt: Date().addingTimeInterval(-60))

        let stub = GoalFireStubLLM(answer: "should not run")
        let conversations = ConversationManager()
        let bus = ToolBus()
        let orchestrator = Orchestrator(conversations: conversations, toolBus: bus, llm: stub)
        let engine = makeEnabledGoalEngine(store: store, llm: stub)
        let runs = RunLogStore()
        let goalLock = SchedulerRunLock()
        let acquired = await goalLock.tryAcquire(id: goal.id, name: goal.title)
        #expect(acquired == true)
        let worker = ServerSchedulerWorker(
            scheduler: SchedulerStore(),
            runs: runs,
            hub: WSHub(),
            runLock: SchedulerRunLock(),
            orchestrator: orchestrator,
            conversations: conversations,
            toolBus: bus,
            goalStore: store,
            goalEngine: engine,
            goalRunLock: goalLock
        )

        // The contended tick records the skip-suppression high-water mark.
        let first = await worker.tick(now: Date())
        #expect(first.count == 1)
        #expect(first.first?.skippedReason == "already running")
        let marked = await worker.lastSkippedGoalDueAt
        #expect(marked[goal.id] != nil)

        // Once the goal is gone the entry has no live counterpart, so the next
        // tick prunes it instead of pinning it in the long-lived worker.
        try await store.delete(goalID: goal.id)
        let second = await worker.tick(now: Date().addingTimeInterval(60))
        #expect(second.isEmpty)
        let remaining = await worker.lastSkippedGoalDueAt
        #expect(remaining.isEmpty)
        #expect(await runs.count() == 1)
        await goalLock.release(id: goal.id, name: goal.title)
    }

    @Test
    func `Settled goal skip suppression entries are pruned on the next tick`() async throws {
        let (dbPath, base) = try makeGoalDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = GoalStore(dbPath: dbPath)
        let achievedGoal = try await persistGoal(store: store, title: "Finish the album", nextDueAt: Date().addingTimeInterval(-60))
        let abandonedGoal = try await persistGoal(store: store, title: "Learn the accordion", nextDueAt: Date().addingTimeInterval(-45))

        let stub = GoalFireStubLLM(answer: "should not run")
        let conversations = ConversationManager()
        let bus = ToolBus()
        let orchestrator = Orchestrator(conversations: conversations, toolBus: bus, llm: stub)
        let engine = makeEnabledGoalEngine(store: store, llm: stub)
        let runs = RunLogStore()
        let goalLock = SchedulerRunLock()
        #expect(await goalLock.tryAcquire(id: achievedGoal.id, name: achievedGoal.title) == true)
        #expect(await goalLock.tryAcquire(id: abandonedGoal.id, name: abandonedGoal.title) == true)
        let worker = ServerSchedulerWorker(
            scheduler: SchedulerStore(),
            runs: runs,
            hub: WSHub(),
            runLock: SchedulerRunLock(),
            orchestrator: orchestrator,
            conversations: conversations,
            toolBus: bus,
            goalStore: store,
            goalEngine: engine,
            goalRunLock: goalLock
        )

        let first = await worker.tick(now: Date())
        #expect(first.count == 2)
        #expect(first.allSatisfy { $0.skippedReason == "already running" })

        // Terminal goals keep no suppression entry: the next tick prunes both.
        try await store.setStatus(goalID: achievedGoal.id, status: .achieved)
        try await store.setStatus(goalID: abandonedGoal.id, status: .abandoned)
        let second = await worker.tick(now: Date().addingTimeInterval(60))
        #expect(second.isEmpty)
        let remaining = await worker.lastSkippedGoalDueAt
        #expect(remaining.isEmpty)
        #expect(await runs.count() == 2)
        await goalLock.release(id: achievedGoal.id, name: achievedGoal.title)
        await goalLock.release(id: abandonedGoal.id, name: abandonedGoal.title)
    }

    @Test
    func `Active busy goal keeps its skip suppression entry across ticks`() async throws {
        let (dbPath, base) = try makeGoalDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = GoalStore(dbPath: dbPath)
        let goal = try await persistGoal(store: store, nextDueAt: Date().addingTimeInterval(-60))

        let stub = GoalFireStubLLM(answer: "should not run")
        let conversations = ConversationManager()
        let bus = ToolBus()
        let orchestrator = Orchestrator(conversations: conversations, toolBus: bus, llm: stub)
        let engine = makeEnabledGoalEngine(store: store, llm: stub)
        let runs = RunLogStore()
        let goalLock = SchedulerRunLock()
        let acquired = await goalLock.tryAcquire(id: goal.id, name: goal.title)
        #expect(acquired == true)
        let worker = ServerSchedulerWorker(
            scheduler: SchedulerStore(),
            runs: runs,
            hub: WSHub(),
            runLock: SchedulerRunLock(),
            orchestrator: orchestrator,
            conversations: conversations,
            toolBus: bus,
            goalStore: store,
            goalEngine: engine,
            goalRunLock: goalLock
        )

        let first = await worker.tick(now: Date())
        #expect(first.count == 1)
        #expect(first.first?.skippedReason == "already running")

        // The goal is still active and due, so pruning leaves the entry in
        // place and the duplicate skip row stays suppressed.
        let second = await worker.tick(now: Date().addingTimeInterval(60))
        #expect(second.isEmpty)
        let marked = await worker.lastSkippedGoalDueAt
        #expect(marked[goal.id] != nil)
        #expect(await runs.count() == 1)
        await goalLock.release(id: goal.id, name: goal.title)
    }
}

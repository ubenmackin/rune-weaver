// Rune Weaver Server Tests — Goal advancement firing in the scheduler worker.
//
// Exercises the background goal turn source end to end with stub language
// providers: due goals fire exactly one linked turn, future goals stay
// silent, contended goal locks skip without running, and parked goal turns
// resume in their original session. The suite owns the worker plus goal
// store pairing so scheduler job firing and goal firing stay isolated on
// their dedicated single-flight locks.

import Foundation
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
}

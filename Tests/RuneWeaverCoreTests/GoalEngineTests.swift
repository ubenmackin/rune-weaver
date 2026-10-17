// Rune Weaver Core Tests — Goal pursuit engine, decomposition, and advancement.

import Foundation
import os
@testable import RuneWeaverCore
import Testing

/// Stub provider replaying canned plan texts in call order.
private final class StubGoalLLM: LLMProvider, Sendable {
    /// Stable test model metadata.
    let modelInfo = ModelInfo(name: "fixture", provider: "test", contextLength: 8192)

    /// Guarded script state.
    private struct ScriptState: Sendable {
        var texts: [String]
        var index: Int
        var calls: Int
    }

    /// Guards script state below.
    private let state: OSAllocatedUnfairLock<ScriptState>

    /// Creates a stub replaying the given texts.
    /// - Parameter texts: Canned replies; the last repeats when exhausted so
    ///   background and explicit decompose calls converge.
    init(texts: [String]) {
        self.state = OSAllocatedUnfairLock(initialState: ScriptState(texts: texts, index: 0, calls: 0))
    }

    /// Number of chat calls observed.
    var callCount: Int {
        state.withLock { $0.calls }
    }

    /// Replays the next canned text as a finished stream.
    func chat(messages _: [Message], tools _: [any Tool]) -> AsyncStream<LLMResponse> {
        let text: String = state.withLock { script in
            script.calls += 1
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

/// Creates an isolated temporary database path and its base directory.
private func makeEngineDBPath() -> (path: String, base: URL) {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("runeweaver-goal-engine-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return (base.appendingPathComponent("episodes.db").path, base)
}

/// Builds a goal snapshot for engine tests.
private func makeEngineGoal(
    id: UUID = UUID(),
    title: String = "Run daily",
    statement: String = "Run every morning",
    status: GoalStatus = .active,
    stepIntervalMinutes: Int = 1440,
    nextDueAt: Date? = nil
) -> Goal {
    let now = Date()
    return Goal(
        id: id,
        title: title,
        statement: statement,
        status: status,
        stepIntervalMinutes: stepIntervalMinutes,
        nextDueAt: nextDueAt,
        createdAt: now,
        updatedAt: now
    )
}

/// Builds one step anchored to a goal for engine tests.
private func makeEngineStep(goalID: UUID, ordinal: Int, title: String, status: StepStatus = .pending) -> GoalStep {
    GoalStep(goalID: goalID, ordinal: ordinal, title: title, status: status)
}

/// Builds an enabled engine over a fresh database.
private func makeEngine(
    dbPath: String,
    llm: StubGoalLLM,
    configure: (inout GoalsConfig) -> Void = { _ in }
) -> (engine: GoalEngine, store: GoalStore) {
    var config = GoalsConfig()
    config.enabled = true
    configure(&config)
    let store = GoalStore(dbPath: dbPath)
    let engine = GoalEngine(store: store, llm: llm, config: config)
    return (engine, store)
}

@Suite("GoalEngine")
struct GoalEngineTests {
    @Test
    func `GoalsConfig defaults stay opt-in with daily cadence`() {
        let config = GoalsConfig()
        #expect(config.enabled == false)
        #expect(config.stepIntervalMinutes == 1440)
        #expect(config.maxActiveGoals == 10)
        #expect(config.maxStepsPerGoal == 12)
        #expect(config.planTimeoutSeconds == 0)
        #expect(RuneWeaverConfig.default.goals == GoalsConfig())
    }

    @Test
    func `Absent goals section decodes to defaults`() throws {
        let text = """
        [llm]
        default_provider = "mlx"

        [llm.providers.mlx]
        enabled = true
        model = "gemma-4-9b"
        server_url = "http://localhost:8080"
        """
        let config = try RuneWeaverConfig(decoding: TOMLParser.parse(text))
        #expect(config.goals == GoalsConfig())
        try config.validate()
    }

    @Test
    func `Explicit goals section decodes and round-trips`() throws {
        let text = """
        [llm]
        default_provider = "mlx"

        [llm.providers.mlx]
        enabled = true
        model = "gemma-4-9b"
        server_url = "http://localhost:8080"

        [goals]
        enabled = true
        step_interval_minutes = 60
        max_active_goals = 5
        max_steps_per_goal = 8
        plan_timeout_seconds = 30
        """
        let config = try RuneWeaverConfig(decoding: TOMLParser.parse(text))
        #expect(config.goals.enabled == true)
        #expect(config.goals.stepIntervalMinutes == 60)
        #expect(config.goals.maxActiveGoals == 5)
        #expect(config.goals.maxStepsPerGoal == 8)
        #expect(config.goals.planTimeoutSeconds == 30)
        try config.validate()

        var roundTrip = RuneWeaverConfig.default
        roundTrip.goals = config.goals
        let rendered = roundTrip.renderTOML()
        #expect(rendered.contains("[goals]"))
        #expect(rendered.contains("step_interval_minutes = 60"))
        let reparsed = try RuneWeaverConfig(decoding: TOMLParser.parse(rendered))
        #expect(reparsed.goals == config.goals)
        try reparsed.validate()
    }

    @Test
    func `Goals validation bounds cadence caps and steps`() {
        expectGoalsValidationFailure({ $0.stepIntervalMinutes = 4 }, field: "goals.step_interval_minutes")
        expectGoalsValidationFailure({ $0.stepIntervalMinutes = 20161 }, field: "goals.step_interval_minutes")
        expectGoalsValidationFailure({ $0.maxActiveGoals = 0 }, field: "goals.max_active_goals")
        expectGoalsValidationFailure({ $0.maxActiveGoals = 51 }, field: "goals.max_active_goals")
        expectGoalsValidationFailure({ $0.maxStepsPerGoal = 0 }, field: "goals.max_steps_per_goal")
        expectGoalsValidationFailure({ $0.maxStepsPerGoal = 25 }, field: "goals.max_steps_per_goal")
    }

    @Test
    func `Create rejects when goals are disabled`() async throws {
        let (path, base) = makeEngineDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = GoalStore(dbPath: path)
        let engine = GoalEngine(store: store, llm: StubGoalLLM(texts: ["[]"]), config: GoalsConfig())
        do {
            _ = try await engine.create(title: "Run", statement: "Run daily")
            Issue.record("Expected GoalEngineError.disabled")
        } catch let error as GoalEngineError {
            #expect(error == .disabled)
        }
        #expect(try await store.list(status: nil).isEmpty)
    }

    @Test
    func `Create enforces the active goal cap`() async throws {
        let (path, base) = makeEngineDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let llm = StubGoalLLM(texts: [#"[{"title":"Step one"}]"#])
        let (engine, store) = makeEngine(dbPath: path, llm: llm) { $0.maxActiveGoals = 1 }
        _ = try await engine.create(title: "First", statement: "First goal")
        #expect(try await store.activeGoalCount() == 1)
        do {
            _ = try await engine.create(title: "Second", statement: "Second goal")
            Issue.record("Expected GoalEngineError.capReached")
        } catch let error as GoalEngineError {
            #expect(error == .capReached(limit: 1))
        }
    }

    @Test
    func `Happy parse replaces the placeholder with one model call`() async throws {
        let (path, base) = makeEngineDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let llm = StubGoalLLM(texts: [#"[{"title":"Lace shoes"},{"title":"Out the door"},{"title":"Cool down"}]"#])
        let (engine, store) = makeEngine(dbPath: path, llm: llm)
        let goal = makeEngineGoal(title: "Run daily", statement: "Run every morning")
        try await store.create(goal: goal, steps: [makeEngineStep(goalID: goal.id, ordinal: 0, title: "Planning in progress")])

        await engine.decompose(goal: goal)

        #expect(llm.callCount == 1)
        let steps = try await store.steps(goalID: goal.id)
        #expect(steps.map(\.title) == ["Lace shoes", "Out the door", "Cool down"])
        #expect(steps.map(\.ordinal) == [0, 1, 2])
        #expect(steps.allSatisfy { $0.status == .pending })
    }

    @Test
    func `Fenced and prefixed JSON recovers`() async throws {
        let (path, base) = makeEngineDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let fenced = """
        Here is your plan:
        ```json
        [{"title":"Alpha"},{"title":"Beta"}]
        ```
        Good luck!
        """
        let llm = StubGoalLLM(texts: [fenced])
        let (engine, store) = makeEngine(dbPath: path, llm: llm)
        let goal = makeEngineGoal()
        try await store.create(goal: goal, steps: [makeEngineStep(goalID: goal.id, ordinal: 0, title: "Planning in progress")])

        await engine.decompose(goal: goal)

        let titles = try await store.steps(goalID: goal.id).map(\.title)
        #expect(titles == ["Alpha", "Beta"])
    }

    @Test
    func `Unusable output marks goal unplanned with a note`() async throws {
        let (path, base) = makeEngineDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let llm = StubGoalLLM(texts: ["sorry, no plan today"])
        let (engine, store) = makeEngine(dbPath: path, llm: llm)
        let goal = makeEngineGoal(title: "Learn drums")
        try await store.create(goal: goal, steps: [])

        await engine.decompose(goal: goal)

        let steps = try await store.steps(goalID: goal.id)
        #expect(steps.isEmpty)
        let fresh = try await store.goal(id: goal.id)
        #expect(fresh?.status == .unplanned)
        let kinds = try await store.events(goalID: goal.id).map(\.kind)
        #expect(kinds.contains(.note))
    }

    @Test
    func `Long plans truncate to the configured step bound`() async throws {
        let (path, base) = makeEngineDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let llm = StubGoalLLM(texts: [#"[{"title":"One"},{"title":"Two"},{"title":"Three"},{"title":"Four"},{"title":"Five"}]"#])
        let (engine, store) = makeEngine(dbPath: path, llm: llm) { $0.maxStepsPerGoal = 3 }
        let goal = makeEngineGoal()
        try await store.create(goal: goal, steps: [makeEngineStep(goalID: goal.id, ordinal: 0, title: "Planning in progress")])

        await engine.decompose(goal: goal)

        let titles = try await store.steps(goalID: goal.id).map(\.title)
        #expect(titles == ["One", "Two", "Three"])
    }

    @Test
    func `AdvancePrompt composes plan statuses recent events and single-step guidance`() {
        let (path, base) = makeEngineDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let engine = GoalEngine(store: GoalStore(dbPath: path), llm: StubGoalLLM(texts: ["[]"]), config: {
            var config = GoalsConfig()
            config.enabled = true
            return config
        }())
        let goal = makeEngineGoal(title: "Run daily", statement: "Run every morning")
        let steps = [
            GoalStep(goalID: goal.id, ordinal: 0, title: "Lace shoes", status: .done, notes: "Double knotted"),
            makeEngineStep(goalID: goal.id, ordinal: 1, title: "Out the door", status: .inProgress),
            makeEngineStep(goalID: goal.id, ordinal: 2, title: "Cool down", status: .pending)
        ]
        let events = (0 ..< 7).map { index in
            GoalEvent(goalID: goal.id, kind: .note, message: "event \(index)")
        }
        let prompt = engine.advancePrompt(goal: goal, steps: steps, events: events)
        #expect(prompt.contains("Run daily"))
        #expect(prompt.contains("Run every morning"))
        #expect(prompt.contains("- Step 0 [done] Lace shoes — Double knotted"))
        #expect(prompt.contains("Current task:"))
        #expect(prompt.contains("Step 1 (stepOrdinal: 1) [in_progress]: Out the door"))
        // Future pending steps are withheld so the model cannot one-shot the entire plan.
        #expect(!prompt.contains("Cool down"))
        // Only the last five events travel so long trails do not crowd the turn.
        #expect(prompt.contains("event 6"))
        #expect(!prompt.contains("event 0"))
        #expect(!prompt.contains("event 1"))
        #expect(prompt.contains("goal.progress"))
        #expect(prompt.contains("stepOrdinal: 1"))
        #expect(prompt.contains("blockers"))
        #expect(prompt.contains("not rush later steps"))
    }

    @Test
    func `PostAdvance bumps the due date by the goal cadence`() async throws {
        let (path, base) = makeEngineDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let (engine, store) = makeEngine(dbPath: path, llm: StubGoalLLM(texts: ["[]"]))
        let originalDue = Date().addingTimeInterval(-3600)
        let goal = makeEngineGoal(stepIntervalMinutes: 60, nextDueAt: originalDue)
        try await store.create(
            goal: goal,
            steps: [makeEngineStep(goalID: goal.id, ordinal: 0, title: "Keep going", status: .pending)]
        )

        try await engine.postAdvance(goalID: goal.id, runID: UUID())

        let loadedOption = try await store.goal(id: goal.id)
        let loaded = try #require(loadedOption)
        let bumped = try #require(loaded.nextDueAt)
        #expect(bumped > originalDue)
        #expect(bumped.timeIntervalSince(Date()) > 3000)
    }

    @Test
    func `PostAdvance marks achieved when nothing remains actionable`() async throws {
        let (path, base) = makeEngineDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let (engine, store) = makeEngine(dbPath: path, llm: StubGoalLLM(texts: ["[]"]))
        let goal = makeEngineGoal()
        let done = makeEngineStep(goalID: goal.id, ordinal: 0, title: "Finished", status: .done)
        try await store.create(goal: goal, steps: [done])

        try await engine.postAdvance(goalID: goal.id, runID: UUID())

        let status = try await store.goal(id: goal.id)?.status
        #expect(status == .achieved)
        let kinds = try await store.events(goalID: goal.id).map(\.kind)
        #expect(kinds.contains(.completed))
    }

    @Test
    func `Lifecycle passthroughs move status with events and delete removes`() async throws {
        let (path, base) = makeEngineDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let (engine, store) = makeEngine(dbPath: path, llm: StubGoalLLM(texts: [#"[{"title":"Step one"}]"#]))
        let created = try await engine.create(title: "Persist", statement: "Stay with it")

        try await engine.pause(goalID: created.id)
        let pausedStatus = try await store.goal(id: created.id)?.status
        #expect(pausedStatus == .paused)

        try await engine.resume(goalID: created.id)
        let resumedStatus = try await store.goal(id: created.id)?.status
        #expect(resumedStatus == .active)

        try await engine.needsInput(goalID: created.id, reason: "Which mileage next?")
        let needsInputStatus = try await store.goal(id: created.id)?.status
        #expect(needsInputStatus == .needsInput)
        let messages = try await store.events(goalID: created.id).map(\.message)
        #expect(messages.contains { $0.contains("Which mileage next?") })

        try await engine.resume(goalID: created.id)
        try await engine.abandon(goalID: created.id)
        let abandonedStatus = try await store.goal(id: created.id)?.status
        #expect(abandonedStatus == .abandoned)

        try await engine.delete(goalID: created.id)
        let deleted = try await store.goal(id: created.id)
        #expect(deleted == nil)
    }

    @Test
    func `PostBudgetExceeded records audit event and advances due date before retry cap`() async throws {
        let (path, base) = makeEngineDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let (engine, store) = makeEngine(dbPath: path, llm: StubGoalLLM(texts: [])) {
            $0.maxStepBudgetExceededRetries = 3
        }
        let goal = makeEngineGoal(title: "Aggregate metrics")
        try await store.create(goal: goal, steps: [makeEngineStep(goalID: goal.id, ordinal: 0, title: "Fetch data")])

        let runID = UUID()
        _ = try await engine.postBudgetExceeded(goalID: goal.id, runID: runID)

        let events = try await store.events(goalID: goal.id)
        #expect(events.contains { $0.kind == .stepBudgetExceeded })

        let updated = try await store.goal(id: goal.id)
        #expect(updated?.status == .active)
        #expect(updated?.nextDueAt != nil)
    }

    @Test
    func `PostBudgetExceeded escalates to needsInput after reaching consecutive retry cap`() async throws {
        let (path, base) = makeEngineDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let (engine, store) = makeEngine(dbPath: path, llm: StubGoalLLM(texts: [])) {
            $0.maxStepBudgetExceededRetries = 2
        }
        let goal = makeEngineGoal(title: "Aggregate metrics")
        try await store.create(goal: goal, steps: [makeEngineStep(goalID: goal.id, ordinal: 0, title: "Fetch data")])

        let runID1 = UUID()
        _ = try await engine.postBudgetExceeded(goalID: goal.id, runID: runID1)
        let intermediate = try await store.goal(id: goal.id)
        #expect(intermediate?.status == .active)

        let runID2 = UUID()
        _ = try await engine.postBudgetExceeded(goalID: goal.id, runID: runID2)
        let final = try await store.goal(id: goal.id)
        #expect(final?.status == .needsInput)

        let events = try await store.events(goalID: goal.id)
        #expect(events.contains { $0.kind == .needsInput && $0.message.contains("stalled after 2 budget-exceeded turns") })
    }

    @Test
    func `CheckCompletion flips active goal with no actionable steps to achieved`() async throws {
        let (path, base) = makeEngineDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let (engine, store) = makeEngine(dbPath: path, llm: StubGoalLLM(texts: []))
        let goal = makeEngineGoal(title: "Finish project")
        let step = makeEngineStep(goalID: goal.id, ordinal: 0, title: "Only step")
        try await store.create(goal: goal, steps: [step])

        // Step still pending: checkCompletion returns false and status remains active
        let beforeDone = try await engine.checkCompletion(goalID: goal.id)
        #expect(beforeDone == false)
        #expect(try await store.goal(id: goal.id)?.status == .active)

        // Mark step done: checkCompletion flips goal to achieved
        try await store.setStepStatus(goalID: goal.id, stepID: step.id, status: .done, notes: "Complete", lastRunID: nil)
        let afterDone = try await engine.checkCompletion(goalID: goal.id)
        #expect(afterDone == true)
        #expect(try await store.goal(id: goal.id)?.status == .achieved)

        // Re-checking already-achieved goal returns false
        let alreadyAchieved = try await engine.checkCompletion(goalID: goal.id)
        #expect(alreadyAchieved == false)
    }

    @Test
    func `ReconcileActiveGoalsCompletion achieves active goals with all steps done`() async throws {
        let (path, base) = makeEngineDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let (engine, store) = makeEngine(dbPath: path, llm: StubGoalLLM(texts: []))
        let goalDone = makeEngineGoal(title: "Done goal")
        let stepDone = makeEngineStep(goalID: goalDone.id, ordinal: 0, title: "Done step", status: .done)
        try await store.create(goal: goalDone, steps: [stepDone])

        let goalPending = makeEngineGoal(title: "Pending goal")
        let stepPending = makeEngineStep(goalID: goalPending.id, ordinal: 0, title: "Pending step", status: .pending)
        try await store.create(goal: goalPending, steps: [stepPending])

        let reconciled = try await engine.reconcileActiveGoalsCompletion()
        #expect(reconciled.contains(goalDone.id))
        #expect(!reconciled.contains(goalPending.id))

        #expect(try await store.goal(id: goalDone.id)?.status == .achieved)
        #expect(try await store.goal(id: goalPending.id)?.status == .active)
    }

    @Test
    func `GoalAdvancementRunner advance skips model turn when all steps are done`() async throws {
        let (path, base) = makeEngineDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let (engine, store) = makeEngine(dbPath: path, llm: StubGoalLLM(texts: []))
        let goal = makeEngineGoal(title: "Finished goal")
        let step = makeEngineStep(goalID: goal.id, ordinal: 0, title: "Finished step", status: .done)
        try await store.create(goal: goal, steps: [step])

        actor CallTracker {
            var called = false
            func mark() {
                called = true
            }
        }
        let tracker = CallTracker()
        let outcome = try await GoalAdvancementRunner.advance(
            goal: goal,
            store: store,
            engine: engine,
            runID: UUID(),
            turn: { _ in
                await tracker.mark()
                return GoalAdvancementTurn(text: "Should not run", isParked: false)
            }
        )

        let wasCalled = await tracker.called
        #expect(wasCalled == false)
        #expect(outcome.text.contains("completed all steps"))
        #expect(try await store.goal(id: goal.id)?.status == .achieved)
    }
}

/// Mutates one goals field on a default config and asserts validation fails
/// with the expected dotted field name.
private func expectGoalsValidationFailure(
    _ mutate: (inout GoalsConfig) -> Void,
    field: String
) {
    var config = RuneWeaverConfig.default
    mutate(&config.goals)
    do {
        try config.validate()
        Issue.record("Expected ConfigError for \(field)")
    } catch let error as ConfigError {
        guard case let .validationError(failedField, _) = error else {
            Issue.record("Expected validationError, got \(error)")
            return
        }
        #expect(failedField == field)
    } catch {
        Issue.record("Expected ConfigError, got \(error)")
    }
}

// Rune Weaver Core Tests — Event-triggered goal wake-ups.

import Foundation
@testable import RuneWeaverCore
@testable import RuneWeaverTools
import Testing

/// Minimal provider so goal creation has a model without a network.
private final class GoalTriggerStubLLM: LLMProvider, Sendable {
    /// Stable test model metadata.
    let modelInfo = ModelInfo(name: "goal-trigger-fixture", provider: "test", contextLength: 8192)

    /// Replays one empty plan; trigger tests only care about persistence.
    func chat(messages _: [Message], tools _: [any Tool]) -> AsyncStream<LLMResponse> {
        AsyncStream { continuation in
            continuation.yield(LLMResponse(delta: "[]", isFinished: true))
            continuation.finish()
        }
    }

    /// Unused embeddings stub.
    func embeddings(text _: [String]) async throws -> [[Float]] {
        []
    }
}

/// Creates an isolated temporary database path and its base directory.
private func makeTriggerDBPath() -> (path: String, base: URL) {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("runeweaver-goal-triggers-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return (base.appendingPathComponent("episodes.db").path, base)
}

/// Persists one active goal with a single pending step directly through the store.
private func makeTriggerGoal(
    store: GoalStore,
    title: String = "Watch the inbox",
    nextDueAt: Date,
    status: GoalStatus = .active
) async throws -> Goal {
    let now = Date()
    let goal = Goal(
        title: title,
        statement: "Follow up when the watched event arrives",
        status: status,
        stepIntervalMinutes: 60,
        nextDueAt: nextDueAt,
        createdAt: now,
        updatedAt: now
    )
    let step = GoalStep(goalID: goal.id, ordinal: 0, title: "Check", status: .pending)
    try await store.create(goal: goal, steps: [step])
    return goal
}

/// Builds an enabled engine plus store over a fresh database.
private func makeTriggerStack(dbPath: String, maxTriggersPerGoal: Int? = nil) -> (engine: GoalEngine, store: GoalStore) {
    var config = GoalsConfig()
    config.enabled = true
    if let maxTriggersPerGoal {
        config.maxTriggersPerGoal = maxTriggersPerGoal
    }
    let store = GoalStore(dbPath: dbPath)
    let engine = GoalEngine(store: store, llm: GoalTriggerStubLLM(), config: config)
    return (engine, store)
}

@Suite("Goal Triggers")
struct GoalTriggerTests {
    @Test
    func `Triggers arm list and remove`() async throws {
        let (path, base) = makeTriggerDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = GoalStore(dbPath: path)
        let goal = try await makeTriggerGoal(store: store, nextDueAt: Date().addingTimeInterval(3600))

        let armed = try await store.addTrigger(
            goalID: goal.id,
            eventKind: "step_done",
            pattern: "basil",
            cooldownMinutes: 30
        )
        #expect(armed.goalID == goal.id)
        #expect(armed.eventKind == "step_done")
        #expect(armed.trimmedPattern == "basil")
        #expect(armed.lastFiredAt == nil)

        let listed = try await store.triggers(for: goal.id)
        #expect(listed.count == 1)
        #expect(listed.first?.id == armed.id)

        try await store.removeTriggers(goalID: goal.id)
        #expect(try await store.triggers(for: goal.id).isEmpty)

        // An unknown goal must not collect orphan trigger rows.
        do {
            _ = try await store.addTrigger(goalID: UUID(), eventKind: "note", pattern: nil, cooldownMinutes: 5)
            Issue.record("Expected notFound arming a trigger for an unknown goal")
        } catch let error as GoalStoreError {
            guard case .notFound = error else {
                Issue.record("Expected notFound, got \(error)")
                return
            }
        }
    }

    @Test
    func `Replace triggers swaps the whole set in one transaction`() async throws {
        let (path, base) = makeTriggerDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = GoalStore(dbPath: path)
        let goal = try await makeTriggerGoal(store: store, nextDueAt: Date().addingTimeInterval(3600))
        _ = try await store.addTrigger(goalID: goal.id, eventKind: "step_done", pattern: "stale", cooldownMinutes: 30)

        try await store.replaceTriggers(goalID: goal.id, drafts: [
            GoalTriggerDraft(eventKind: "episode", pattern: "urgent", cooldownMinutes: 15),
            // A blank kind can never match, so it drops rather than arming dead weight.
            GoalTriggerDraft(eventKind: "   ", cooldownMinutes: 5),
            GoalTriggerDraft(eventKind: "note", pattern: nil, cooldownMinutes: nil)
        ])

        let armed = try await store.triggers(for: goal.id)
        // The previous set is gone entirely; only the two valid drafts remain.
        #expect(armed.count == 2)
        #expect(armed.map(\.eventKind) == ["episode", "note"])
        #expect(armed.first?.trimmedPattern == "urgent")
        #expect(armed.first?.cooldownMinutes == 15)
        // A nil cooldown inherits the configured default instead of arming a
        // zero-window re-fire loop.
        #expect(armed.last?.cooldownMinutes == GoalsConfig.defaultTriggerCooldownMinutes)

        // An unknown goal rejects before any row is touched.
        do {
            try await store.replaceTriggers(goalID: UUID(), drafts: [GoalTriggerDraft(eventKind: "note")])
            Issue.record("Expected notFound replacing triggers on an unknown goal")
        } catch let error as GoalStoreError {
            guard case .notFound = error else {
                Issue.record("Expected notFound, got \(error)")
                return
            }
        }
    }

    @Test
    func `Replace triggers caps the set at the absolute bound`() async throws {
        let (path, base) = makeTriggerDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = GoalStore(dbPath: path)
        let goal = try await makeTriggerGoal(store: store, nextDueAt: Date().addingTimeInterval(3600))
        let drafts = (0 ..< (GoalsConfig.maxTriggersPerGoalBound + 10)).map { index in
            GoalTriggerDraft(eventKind: "kind-\(index)", pattern: nil, cooldownMinutes: 5)
        }
        try await store.replaceTriggers(goalID: goal.id, drafts: drafts)
        let armed = try await store.triggers(for: goal.id)
        // Direct store callers bypass the route budget, so the store itself is
        // the fail-closed guard: no more than the absolute bound ever arms.
        #expect(armed.count == GoalsConfig.maxTriggersPerGoalBound)
    }

    @Test
    func `Trigger match pulls the goal due and stamps last fired`() async throws {
        let (path, base) = makeTriggerDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = GoalStore(dbPath: path)
        let future = Date().addingTimeInterval(3600)
        let goal = try await makeTriggerGoal(store: store, nextDueAt: future)
        _ = try await store.addTrigger(goalID: goal.id, eventKind: "step_done", pattern: nil, cooldownMinutes: 30)

        let now = Date()
        let fires = try await store.fireMatchingTriggers(
            events: [GoalObservedEvent(kind: "step_done", message: "Laced shoes", occurredAt: now)],
            now: now
        )
        #expect(fires.count == 1)
        #expect(fires.first?.goalID == goal.id)

        let loadedOption = try await store.goal(id: goal.id)
        let loaded = try #require(loadedOption)
        let due = try #require(loaded.nextDueAt)
        #expect(abs(due.timeIntervalSince(now)) < 0.01)
        let triggers = try await store.triggers(for: goal.id)
        let trigger = try #require(triggers.first)
        #expect(trigger.lastFiredAt != nil)
    }

    @Test
    func `Cooldown suppresses repeats until the window elapses`() async throws {
        let (path, base) = makeTriggerDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = GoalStore(dbPath: path)
        let goal = try await makeTriggerGoal(store: store, nextDueAt: Date().addingTimeInterval(3600))
        _ = try await store.addTrigger(goalID: goal.id, eventKind: "step_done", pattern: nil, cooldownMinutes: 30)

        let start = Date()
        let event = GoalObservedEvent(kind: "step_done", message: "first", occurredAt: start)
        let first = try await store.fireMatchingTriggers(events: [event], now: start)
        #expect(first.count == 1)

        // Inside the debounce window the same kind of event is ignored.
        let soon = start.addingTimeInterval(60)
        let suppressed = try await store.fireMatchingTriggers(
            events: [GoalObservedEvent(kind: "step_done", message: "second", occurredAt: soon)],
            now: soon
        )
        #expect(suppressed.isEmpty)

        // Past the window it fires again, re-arming the goal.
        let later = start.addingTimeInterval(31 * 60)
        let again = try await store.fireMatchingTriggers(
            events: [GoalObservedEvent(kind: "step_done", message: "third", occurredAt: later)],
            now: later
        )
        #expect(again.count == 1)
    }

    @Test
    func `Pattern filters events by substring`() async throws {
        let (path, base) = makeTriggerDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = GoalStore(dbPath: path)
        let goal = try await makeTriggerGoal(store: store, nextDueAt: Date().addingTimeInterval(3600))
        _ = try await store.addTrigger(goalID: goal.id, eventKind: "episode", pattern: "urgent", cooldownMinutes: 1)

        let now = Date()
        let miss = try await store.fireMatchingTriggers(
            events: [GoalObservedEvent(kind: "episode", message: "just a ping", occurredAt: now)],
            now: now
        )
        #expect(miss.isEmpty)

        let hit = try await store.fireMatchingTriggers(
            events: [GoalObservedEvent(kind: "episode", message: "URGENT: disk full", occurredAt: now)],
            now: now
        )
        #expect(hit.count == 1)
    }

    @Test
    func `Store floors cooldowns at the configured minimum`() async throws {
        let (path, base) = makeTriggerDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = GoalStore(dbPath: path)
        let goal = try await makeTriggerGoal(store: store, nextDueAt: Date().addingTimeInterval(3600))

        // A direct store caller cannot bypass the re-fire guard the engine and
        // route layers enforce: zero and negative windows persist as the
        // minimum instead of an always-on loop.
        let zeroed = try await store.addTrigger(goalID: goal.id, eventKind: "zero", pattern: nil, cooldownMinutes: 0)
        #expect(zeroed.cooldownMinutes == GoalsConfig.minTriggerCooldownMinutes)
        let negative = try await store.addTrigger(goalID: goal.id, eventKind: "negative", pattern: nil, cooldownMinutes: -5)
        #expect(negative.cooldownMinutes == GoalsConfig.minTriggerCooldownMinutes)

        try await store.replaceTriggers(goalID: goal.id, drafts: [
            GoalTriggerDraft(eventKind: "replaced", cooldownMinutes: 0),
            GoalTriggerDraft(eventKind: "defaulted", cooldownMinutes: nil)
        ])
        let armed = try await store.triggers(for: goal.id)
        #expect(armed.count == 2)
        #expect(armed.first { $0.eventKind == "replaced" }?.cooldownMinutes == GoalsConfig.minTriggerCooldownMinutes)
        #expect(armed.first { $0.eventKind == "defaulted" }?.cooldownMinutes == GoalsConfig.defaultTriggerCooldownMinutes)
    }

    @Test
    func `Match debounces at the minimum even for a zero window`() {
        // Persistence floors new rows, but the pure matcher floors too so a
        // legacy zero-minute row still debounces instead of firing always-on.
        let trigger = GoalTrigger(
            goalID: UUID(),
            eventKind: "episode",
            pattern: nil,
            cooldownMinutes: 0,
            lastFiredAt: Date()
        )
        let immediate = GoalObservedEvent(kind: "episode", message: "ping", occurredAt: Date())
        #expect(trigger.matches(event: immediate, now: Date()) == false)
        let later = GoalObservedEvent(kind: "episode", message: "ping", occurredAt: Date())
        let afterMinimum = Date().addingTimeInterval(TimeInterval((GoalsConfig.minTriggerCooldownMinutes * 60) + 1))
        #expect(trigger.matches(event: later, now: afterMinimum) == true)
    }

    @Test
    func `Non-matching kind stays silent and leaves the due date alone`() async throws {
        let (path, base) = makeTriggerDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = GoalStore(dbPath: path)
        let future = Date().addingTimeInterval(3600)
        let goal = try await makeTriggerGoal(store: store, nextDueAt: future)
        _ = try await store.addTrigger(goalID: goal.id, eventKind: "step_done", pattern: nil, cooldownMinutes: 30)

        let fires = try await store.fireMatchingTriggers(
            events: [GoalObservedEvent(kind: "episode", message: "unrelated", occurredAt: Date())],
            now: Date()
        )
        #expect(fires.isEmpty)
        let loadedOption = try await store.goal(id: goal.id)
        let loaded = try #require(loadedOption)
        // The store persists the due date as `timeIntervalSince1970`, so a
        // round-trip can shift it by up to one ULP. Compare within a small
        // epsilon rather than requiring exact `Date` equality.
        let due = try #require(loaded.nextDueAt)
        #expect(abs(due.timeIntervalSince(future)) < 0.001)
    }

    @Test
    func `Paused goals never acquire a wake-up due`() async throws {
        let (path, base) = makeTriggerDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = GoalStore(dbPath: path)
        let future = Date().addingTimeInterval(3600)
        let goal = try await makeTriggerGoal(store: store, nextDueAt: future, status: .paused)
        _ = try await store.addTrigger(goalID: goal.id, eventKind: "step_done", pattern: nil, cooldownMinutes: 30)

        let fires = try await store.fireMatchingTriggers(
            events: [GoalObservedEvent(kind: "step_done", message: "Laced shoes", occurredAt: Date())],
            now: Date()
        )
        #expect(fires.isEmpty)
    }

    @Test
    func `Bridge polls mirrored episodes and arms the next due`() async throws {
        let (path, base) = makeTriggerDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let goalStore = GoalStore(dbPath: path)
        let episodeStore = EpisodeStore(dbPath: path)
        let future = Date().addingTimeInterval(3600)
        let goal = try await makeTriggerGoal(store: goalStore, nextDueAt: future)
        _ = try await goalStore.addTrigger(
            goalID: goal.id,
            eventKind: GoalTriggerEventKind.episode,
            pattern: nil,
            cooldownMinutes: 30
        )

        let since = Date().addingTimeInterval(-60)
        try await episodeStore.store(sessionID: UUID(), role: .user, content: "a fresh turn arrived")

        let now = Date()
        let bridge = GoalTriggerBridge()
        let fires = await bridge.poll(store: goalStore, episodeStore: episodeStore, now: now, since: since)
        #expect(fires.count == 1)
        let loadedOption = try await goalStore.goal(id: goal.id)
        let loaded = try #require(loadedOption)
        let due = try #require(loaded.nextDueAt)
        #expect(due < future)
    }

    @Test
    func `Status surfaces armed triggers with their last fire`() async throws {
        let (path, base) = makeTriggerDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let (_, store) = makeTriggerStack(dbPath: path)
        let goal = try await makeTriggerGoal(store: store, nextDueAt: Date().addingTimeInterval(3600))
        _ = try await store.addTrigger(goalID: goal.id, eventKind: "step_done", pattern: nil, cooldownMinutes: 30)
        _ = try await store.fireMatchingTriggers(
            events: [GoalObservedEvent(kind: "step_done", message: "hit", occurredAt: Date())],
            now: Date()
        )

        let status = GoalStatusTool(store: store)
        let output = try await status.execute(
            input: ToolInput(toolName: "goal.status", argumentsJSON: #"{"goalID":"\#(goal.id.uuidString)"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == false)
        let envelope = try JSONDecoder().decode(GoalStatusEnvelope.self, from: Data(output.content.utf8))
        let detail = try #require(envelope.goals.first)
        #expect(detail.triggers.count == 1)
        #expect(detail.triggers.first?.eventKind == "step_done")
        #expect(detail.triggers.first?.lastFiredAt != nil)
    }

    @Test
    func `Engine create arms triggers up to the configured budget`() async throws {
        let (path, base) = makeTriggerDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let (engine, store) = makeTriggerStack(dbPath: path, maxTriggersPerGoal: 1)
        let goal = try await engine.create(
            title: "Watch events",
            statement: "React to arriving events",
            triggers: [
                GoalTriggerDraft(eventKind: "step_done", cooldownMinutes: 15),
                GoalTriggerDraft(eventKind: "episode")
            ]
        )
        await engine.waitForPendingPlan(goalID: goal.id)
        let armed = try await store.triggers(for: goal.id)
        #expect(armed.count == 1)
        #expect(armed.first?.eventKind == "step_done")
        #expect(armed.first?.cooldownMinutes == 15)
    }

    @Test
    func `Create tool passes triggers and rejects blank kinds`() async throws {
        let (path, base) = makeTriggerDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let (engine, store) = makeTriggerStack(dbPath: path)
        let tool = GoalCreateTool(engine: engine)
        let output = try await tool.execute(
            input: ToolInput(
                toolName: "goal.create",
                argumentsJSON: #"{"title":"Watch","statement":"Watch events","triggers":[{"event_kind":"step_done","cooldown_minutes":20}]}"#
            ),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == false)
        let envelope = try JSONDecoder().decode(GoalCreateEnvelope.self, from: Data(output.content.utf8))
        let goalID = try #require(UUID(uuidString: envelope.goalID))
        let armed = try await store.triggers(for: goalID)
        #expect(armed.count == 1)
        #expect(armed.first?.eventKind == "step_done")
        #expect(armed.first?.cooldownMinutes == 20)

        let blank = try await tool.execute(
            input: ToolInput(
                toolName: "goal.create",
                argumentsJSON: #"{"title":"Watch","statement":"Watch events","triggers":[{"eventKind":"  "}]}"#
            ),
            context: ToolContext(conversationID: UUID())
        )
        #expect(blank.isError == true)
    }

    @Test
    func `Disabled goals still register tools that fail honestly`() async throws {
        let (path, base) = makeTriggerDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = GoalStore(dbPath: path)
        let engine = GoalEngine(store: store, llm: GoalTriggerStubLLM(), config: GoalsConfig())
        let tools = GoalTools.makeTools(engine: engine, store: store, goalsConfig: GoalsConfig())
        #expect(tools.map(\.name) == ["goal.create", "goal.status", "goal.progress"])
        let create = try #require(tools.first { $0.name == "goal.create" })
        let output = try await create.execute(
            input: ToolInput(
                toolName: "goal.create",
                argumentsJSON: #"{"title":"Watch","statement":"Watch events","triggers":[{"eventKind":"step_done"}]}"#
            ),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == true)
        #expect(output.content.contains("[goals]"))
        #expect(try await store.triggers(for: UUID()).isEmpty)
    }

    @Test
    func `Goals max triggers per goal round-trips through TOML`() throws {
        let text = """
        [goals]
        enabled = true
        max_triggers_per_goal = 3
        """
        let decoded = try RuneWeaverConfig(decoding: TOMLParser.parse(text))
        #expect(decoded.goals.maxTriggersPerGoal == 3)
        try decoded.validate()

        // The rendered file must carry the key back so a saved value survives a
        // reload instead of silently reverting to the default.
        var roundTrip = RuneWeaverConfig.default
        roundTrip.goals = decoded.goals
        let rendered = roundTrip.renderTOML()
        #expect(rendered.contains("max_triggers_per_goal = 3"))
        let reparsed = try RuneWeaverConfig(decoding: TOMLParser.parse(rendered))
        #expect(reparsed.goals.maxTriggersPerGoal == 3)
        try reparsed.validate()
    }

    @Test
    func `Goals config bounds and clamps the trigger budget`() throws {
        #expect(GoalsConfig().maxTriggersPerGoal == 8)

        var config = RuneWeaverConfig.default
        config.goals.maxTriggersPerGoal = -1
        do {
            try config.validate()
            Issue.record("Expected a negative trigger budget to fail validation")
        } catch let error as ConfigError {
            guard case let .validationError(field, _) = error else {
                Issue.record("Expected validationError, got \(error)")
                return
            }
            #expect(field == "goals.max_triggers_per_goal")
        }

        var tooMany = GoalsConfig()
        tooMany.maxTriggersPerGoal = 99
        #expect(tooMany.clamped().maxTriggersPerGoal == GoalsConfig.maxTriggersPerGoalBound)
    }
}

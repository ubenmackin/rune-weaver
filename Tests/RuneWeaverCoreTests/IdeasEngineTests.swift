// Rune Weaver Core Tests — Proactive Wayfinder ideas engine, store, and config.

import Foundation
import os
@testable import RuneWeaverCore
import Testing

/// Stub provider replaying canned review texts in call order.
private final class StubIdeasLLM: LLMProvider, Sendable {
    /// Stable test model metadata.
    let modelInfo = ModelInfo(name: "ideas-fixture", provider: "test", contextLength: 8192)

    /// Guarded script state.
    private struct ScriptState: Sendable {
        var texts: [String]
        var index: Int
        var calls: Int
    }

    /// Guards script state below.
    private let state: OSAllocatedUnfairLock<ScriptState>

    /// Creates a stub replaying the given texts.
    /// - Parameter texts: Canned replies; the last repeats when exhausted.
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

/// Provider whose stream never yields, finishes, or reacts to cancellation.
private final class HangingIdeasLLM: LLMProvider, Sendable {
    /// Stable test model metadata.
    let modelInfo = ModelInfo(name: "ideas-hanging", provider: "test", contextLength: 8192)

    /// Returns a stream that stays open forever.
    func chat(messages _: [Message], tools _: [any Tool]) -> AsyncStream<LLMResponse> {
        AsyncStream { _ in }
    }

    /// Unused embeddings stub.
    func embeddings(text _: [String]) async throws -> [[Float]] {
        []
    }
}

/// Stub provider that records the prompt of each review call so tests can pin
/// what the engine actually quoted to the model.
private final class CapturingIdeasLLM: LLMProvider, Sendable {
    /// Stable test model metadata.
    let modelInfo = ModelInfo(name: "ideas-capture", provider: "test", contextLength: 8192)
    /// Canned reply replayed for every call.
    private let answer: String
    /// Guarded captured prompts in call order.
    private let prompts = OSAllocatedUnfairLock<[String]>(initialState: [])

    /// Creates a capturing stub.
    /// - Parameter answer: Canned reply text.
    init(answer: String) {
        self.answer = answer
    }

    /// Prompts observed so far, oldest first.
    var capturedPrompts: [String] {
        prompts.withLock { $0 }
    }

    /// Records the prompt and replays the canned answer as a finished stream.
    func chat(messages: [Message], tools _: [any Tool]) -> AsyncStream<LLMResponse> {
        prompts.withLock { $0.append(messages.map(\.content).joined(separator: "\n")) }
        let text = answer
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
private func makeIdeasDBPath() -> (path: String, base: URL) {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("runeweaver-ideas-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return (base.appendingPathComponent("episodes.db").path, base)
}

/// Builds an enabled ideas engine over a fresh database and stub provider.
private func makeIdeasEngine(
    dbPath: String,
    llm: any LLMProvider,
    configure: (inout IdeasConfig) -> Void = { _ in }
) -> (engine: IdeasEngine, store: IdeasStore) {
    var config = IdeasConfig()
    config.enabled = true
    configure(&config)
    let store = IdeasStore(dbPath: dbPath)
    let engine = IdeasEngine(store: store, llm: llm, config: config)
    return (engine, store)
}

/// Builds one idea for store tests.
private func makeIdea(
    title: String,
    kind: IdeaKind = .tip,
    body: String = "Body",
    status: IdeaStatus = .proposed
) -> Idea {
    Idea(kind: kind, title: title, body: body, status: status)
}

@Suite("IdeasEngine")
struct IdeasEngineTests {
    @Test
    func `IdeasConfig defaults stay opt-in with a small batch`() {
        let config = IdeasConfig()
        #expect(config.enabled == false)
        #expect(config.maxPerCycle == 3)
        #expect(config.timeoutSeconds == 20)
        #expect(RuneWeaverConfig.default.ideas == IdeasConfig())
    }

    @Test
    func `Absent ideas section decodes to defaults`() throws {
        let text = """
        [llm]
        default_provider = "mlx"
        [llm.providers.mlx]
        enabled = true
        model = "gemma-4-9b"
        server_url = "http://localhost:8080"
        """
        let config = try RuneWeaverConfig(decoding: TOMLParser.parse(text))
        #expect(config.ideas == IdeasConfig())
        try config.validate()
    }

    @Test
    func `Explicit ideas section decodes and round-trips`() throws {
        let text = """
        [llm]
        default_provider = "mlx"
        [llm.providers.mlx]
        enabled = true
        model = "gemma-4-9b"
        server_url = "http://localhost:8080"
        [ideas]
        enabled = true
        max_per_cycle = 5
        timeout_seconds = 30
        """
        let config = try RuneWeaverConfig(decoding: TOMLParser.parse(text))
        #expect(config.ideas.enabled == true)
        #expect(config.ideas.maxPerCycle == 5)
        #expect(config.ideas.timeoutSeconds == 30)
        try config.validate()

        var roundTrip = RuneWeaverConfig.default
        roundTrip.ideas = config.ideas
        let rendered = roundTrip.renderTOML()
        #expect(rendered.contains("[ideas]"))
        #expect(rendered.contains("max_per_cycle = 5"))
        let reparsed = try RuneWeaverConfig(decoding: TOMLParser.parse(rendered))
        #expect(reparsed.ideas == config.ideas)
        try reparsed.validate()
    }

    @Test
    func `Ideas validation bounds the batch and review timeout`() {
        expectIdeasValidationFailure({ $0.maxPerCycle = 0 }, field: "ideas.max_per_cycle")
        expectIdeasValidationFailure({ $0.maxPerCycle = 11 }, field: "ideas.max_per_cycle")
        expectIdeasValidationFailure({ $0.timeoutSeconds = 0 }, field: "ideas.timeout_seconds")
        expectIdeasValidationFailure({ $0.timeoutSeconds = 121 }, field: "ideas.timeout_seconds")
    }

    @Test
    func `Ideas clamped pulls hand-built values inside bounds`() {
        let clamped = IdeasConfig(enabled: true, maxPerCycle: 99, timeoutSeconds: 0).clamped()
        #expect(clamped.enabled == true)
        #expect(clamped.maxPerCycle == IdeasConfig.maxMaxPerCycle)
        #expect(clamped.timeoutSeconds == IdeasConfig.minTimeoutSeconds)
    }

    @Test
    func `Review prompt includes outcomes and memory facts`() {
        let prompt = IdeasEngine.reviewPrompt(
            outcomes: ["- completed: Finished the report"],
            facts: ["Prefers mornings"],
            maxPerCycle: 2
        )
        #expect(prompt.contains("at most 2"))
        #expect(prompt.contains("Finished the report"))
        #expect(prompt.contains("Prefers mornings"))
        #expect(prompt.contains("plan_adjustment"))
        #expect(prompt.contains("new_goal"))
        // The adjustment contract demands a goal link so a suggestion can be
        // accepted against the goal it targets instead of being unlinkable.
        #expect(prompt.contains("goalId"))
    }

    @Test
    func `Over-long titles truncate and unknown kinds degrade to tip`() throws {
        let long = String(repeating: "a", count: 200)
        let json = "[{\"kind\":\"nonsense\",\"title\":\"\(long)\",\"body\":\"Hi\"}]"
        let parsed = try #require(IdeasEngine.parseIdeas(from: json, maxCount: 3))
        #expect(parsed.first?.title.count == IdeasEngine.maxTitleLength)
        #expect(parsed.first?.kind == .tip)
    }

    @Test
    func `Zero cap honors an empty batch instead of reinterpreting as one`() throws {
        let json = #"[{"kind":"tip","title":"One","body":""},{"kind":"tip","title":"Two","body":""}]"#
        // A zero cap means no suggestions: every layer agrees that the bound is
        // exact rather than promoting zero to one.
        let zeroed = try #require(IdeasEngine.parseIdeas(from: json, maxCount: 0))
        #expect(zeroed.isEmpty)
        let negative = try #require(IdeasEngine.parseIdeas(from: json, maxCount: -1))
        #expect(negative.isEmpty)
        let one = try #require(IdeasEngine.parseIdeas(from: json, maxCount: 1))
        #expect(one.map(\.title) == ["One"])
    }

    @Test
    func `Disabled generation is a no-op`() async throws {
        let (path, base) = makeIdeasDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let llm = StubIdeasLLM(texts: [#"[{"kind":"tip","title":"Read more","body":"Book a slot."}]"#])
        let store = IdeasStore(dbPath: path)
        let engine = IdeasEngine(store: store, llm: llm, config: IdeasConfig())

        let ideas = await engine.generate()

        #expect(ideas.isEmpty)
        #expect(llm.callCount == 0)
        #expect(try await store.list().isEmpty)
    }

    @Test
    func `Happy parse persists suggestions from one call`() async throws {
        let (path, base) = makeIdeasDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let json = #"[{"kind":"plan_adjustment","title":"Shorten the morning run","body":"Try a shorter loop."},{"kind":"tip","title":"Hydrate","body":"Drink more water."}]"#
        let (engine, store) = makeIdeasEngine(dbPath: path, llm: StubIdeasLLM(texts: [json]))

        let ideas = await engine.generate()

        #expect(ideas.count == 2)
        #expect(ideas.map(\.title) == ["Shorten the morning run", "Hydrate"])
        #expect(ideas.map(\.kind) == [.planAdjustment, .tip])
        #expect(ideas.allSatisfy { $0.status == .proposed })
        let persisted = try await store.list()
        #expect(persisted.count == 2)
    }

    @Test
    func `Fenced and prefixed JSON recovers`() async {
        let (path, base) = makeIdeasDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let fenced = """
        Here are some ideas:
        ```json
        [{"kind":"new_goal","title":"Learn drums","body":"Practice daily."}]
        ```
        Good luck!
        """
        let (engine, _) = makeIdeasEngine(dbPath: path, llm: StubIdeasLLM(texts: [fenced]))

        let ideas = await engine.generate()

        #expect(ideas.map(\.title) == ["Learn drums"])
        #expect(ideas.first?.kind == .newGoal)
    }

    @Test
    func `Review timeout bounds a non-cooperative provider stream`() async {
        let (path, base) = makeIdeasDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = IdeasStore(dbPath: path)
        var config = IdeasConfig()
        config.enabled = true
        config.timeoutSeconds = 1
        let engine = IdeasEngine(store: store, llm: HangingIdeasLLM(), config: config)

        let start = Date()
        let ideas = await engine.generate()
        let elapsed = Date().timeIntervalSince(start)

        // The bound is structural: the call returns near the configured timeout
        // even though the provider stream never yields or observes cancellation,
        // so a hung backend cannot stall the trigger that asked for ideas.
        #expect(ideas.isEmpty)
        #expect(elapsed < 5)
    }

    @Test
    func `Flaky parse yields an empty batch`() async throws {
        let (path, base) = makeIdeasDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let llm = StubIdeasLLM(texts: ["sorry, no ideas today"])
        let (engine, store) = makeIdeasEngine(dbPath: path, llm: llm)

        let ideas = await engine.generate()

        #expect(ideas.isEmpty)
        #expect(llm.callCount == 1)
        #expect(try await store.list().isEmpty)
    }

    @Test
    func `Dismissed titles may resurface under the non-dismissed dedup contract`() async throws {
        let (path, base) = makeIdeasDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let first = #"[{"kind":"tip","title":"Read more","body":"Finish the book."}]"#
        let second = #"[{"kind":"tip","title":"Read more","body":"Finish the book."},{"kind":"tip","title":"Stretch","body":"Five minutes."}]"#
        let (engine, store) = makeIdeasEngine(dbPath: path, llm: StubIdeasLLM(texts: [first, second]))

        let initial = await engine.generate()
        let dismissed = try #require(initial.first)
        _ = try await store.setStatus(id: dismissed.id, status: .dismissed)

        let secondBatch = await engine.generate()

        // Dedup only skips titles that duplicate an existing non-dismissed
        // idea, so a dismissed title is eligible again alongside the new one.
        #expect(secondBatch.map(\.title) == ["Read more", "Stretch"])
        #expect(try await store.dismissedTitles() == ["read more"])
    }

    @Test
    func `Plan adjustment steps parse into a newline-separated plan body`() throws {
        let json = #"[{"kind":"plan_adjustment","title":"Shorten the loop","steps":["  First step  ","","Second step"]}]"#
        let parsed = try #require(IdeasEngine.parseIdeas(from: json, maxCount: 3))
        #expect(parsed.first?.kind == .planAdjustment)
        // Structured steps land as the plan body so the accept route reads a
        // contract-backed plan instead of splitting free-form prose.
        #expect(parsed.first?.body == "First step\nSecond step")
    }

    @Test
    func `Plan adjustment steps are bounded by count and length`() throws {
        let long = String(repeating: "a", count: 400)
        let steps = (1 ... 20).map { _ in "\"\(long)\"" }.joined(separator: ",")
        let json = "[{\"kind\":\"plan_adjustment\",\"title\":\"T\",\"steps\":[\(steps)]}]"
        let parsed = try #require(IdeasEngine.parseIdeas(from: json, maxCount: 3))
        let body = try #require(parsed.first?.body)
        let lines = body.split(separator: "\n")
        #expect(lines.count == IdeasEngine.maxAdjustmentSteps)
        #expect(lines.allSatisfy { $0.count == IdeasEngine.maxAdjustmentStepLength })
    }

    @Test
    func `Plan adjustment without steps keeps its prose body`() throws {
        let json = #"[{"kind":"plan_adjustment","title":"Keep","body":"Try a shorter loop."}]"#
        let parsed = try #require(IdeasEngine.parseIdeas(from: json, maxCount: 3))
        #expect(parsed.first?.body == "Try a shorter loop.")
    }

    @Test
    func `Plan adjustment carries its linked goal id and tips ignore one`() throws {
        let goalID = UUID()
        let json = "[{\"kind\":\"plan_adjustment\",\"title\":\"Replan\",\"steps\":[\"One\"],\"goalId\":\"\(goalID.uuidString)\"},"
            + "{\"kind\":\"tip\",\"title\":\"Tip\",\"body\":\"Body\",\"goalId\":\"\(goalID.uuidString)\"}]"
        let parsed = try #require(IdeasEngine.parseIdeas(from: json, maxCount: 3))
        #expect(parsed[0].goalID == goalID)
        // A tip has no existing goal to target, so an emitted link is ignored
        // rather than mis-attributing the suggestion to an unrelated goal.
        #expect(parsed[1].goalID == nil)
    }

    @Test
    func `Review prompt quotes outcomes with their goal id`() async throws {
        let (path, base) = makeIdeasDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        // A stalled step is one of the outcome kinds the review reads, so its
        // goal id must reach the prompt for the model to copy.
        let goalStore = GoalStore(dbPath: path)
        let now = Date()
        let goal = Goal(
            title: "Tend herbs",
            statement: "Keep basil alive",
            status: .active,
            stepIntervalMinutes: 60,
            createdAt: now,
            updatedAt: now
        )
        let step = GoalStep(goalID: goal.id, ordinal: 0, title: "Water basil", status: .pending)
        try await goalStore.create(goal: goal, steps: [step])
        try await goalStore.setStepStatus(
            goalID: goal.id,
            stepID: step.id,
            status: .blocked,
            notes: "No water",
            lastRunID: nil
        )

        let llm = CapturingIdeasLLM(answer: "[]")
        let (engine, _) = makeIdeasEngine(dbPath: path, llm: llm)

        _ = await engine.generate()

        let prompt = try #require(llm.capturedPrompts.first)
        #expect(prompt.contains("goal_id=\(goal.id.uuidString)"))
    }

    @Test
    func `Generation persists the linked goal id from the review contract`() async throws {
        let (path, base) = makeIdeasDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let goalStore = GoalStore(dbPath: path)
        let now = Date()
        let goal = Goal(
            title: "Tend herbs",
            statement: "Keep basil alive",
            status: .active,
            stepIntervalMinutes: 60,
            createdAt: now,
            updatedAt: now
        )
        let step = GoalStep(goalID: goal.id, ordinal: 0, title: "Water basil", status: .pending)
        try await goalStore.create(goal: goal, steps: [step])
        try await goalStore.setStepStatus(
            goalID: goal.id,
            stepID: step.id,
            status: .blocked,
            notes: "No water",
            lastRunID: nil
        )

        let json = "[{\"kind\":\"plan_adjustment\",\"title\":\"Unblock the watering\","
            + "\"steps\":[\"Check the drip tray\"],\"goalId\":\"\(goal.id.uuidString)\"}]"
        let (engine, store) = makeIdeasEngine(dbPath: path, llm: StubIdeasLLM(texts: [json]))

        let ideas = await engine.generate()

        #expect(ideas.count == 1)
        #expect(ideas.first?.goalID == goal.id)
        let persisted = try await store.list(status: .proposed)
        #expect(persisted.first?.goalID == goal.id)
    }

    @Test
    func `Per-cycle cap bounds persisted ideas`() async throws {
        let (path, base) = makeIdeasDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let json = #"[{"kind":"tip","title":"One","body":""},{"kind":"tip","title":"Two","body":""},{"kind":"tip","title":"Three","body":""},{"kind":"tip","title":"Four","body":""},{"kind":"tip","title":"Five","body":""}]"#
        let llm = StubIdeasLLM(texts: [json])
        let (engine, store) = makeIdeasEngine(dbPath: path, llm: llm) { $0.maxPerCycle = 2 }

        let ideas = await engine.generate()

        #expect(ideas.map(\.title) == ["One", "Two"])
        #expect(llm.callCount == 1)
        #expect(try await store.list().count == 2)
    }

    @Test
    func `Achieving a goal fires the ideas hook`() async throws {
        let (path, base) = makeIdeasDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let ideasLLM = StubIdeasLLM(texts: ["[]"])
        let ideasStore = IdeasStore(dbPath: path)
        var ideasConfig = IdeasConfig()
        ideasConfig.enabled = true
        let ideasEngine = IdeasEngine(store: ideasStore, llm: ideasLLM, config: ideasConfig)

        let goalStore = GoalStore(dbPath: path)
        var goalsConfig = GoalsConfig()
        goalsConfig.enabled = true
        let goalEngine = GoalEngine(
            store: goalStore,
            llm: StubIdeasLLM(texts: ["[]"]),
            config: goalsConfig,
            ideasEngine: ideasEngine
        )
        let now = Date()
        let goal = Goal(
            title: "Finish the report",
            statement: "Wrap it up",
            status: .active,
            stepIntervalMinutes: 60,
            createdAt: now,
            updatedAt: now
        )
        let done = GoalStep(goalID: goal.id, ordinal: 0, title: "Draft", status: .done)
        try await goalStore.create(goal: goal, steps: [done])

        try await goalEngine.postAdvance(goalID: goal.id, runID: UUID())

        #expect(try await goalStore.goal(id: goal.id)?.status == .achieved)
        #expect(ideasLLM.callCount == 1)
    }

    @Test
    func `Advancing a goal without achieving skips the ideas hook`() async throws {
        let (path, base) = makeIdeasDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let ideasLLM = StubIdeasLLM(texts: ["[]"])
        let ideasStore = IdeasStore(dbPath: path)
        var ideasConfig = IdeasConfig()
        ideasConfig.enabled = true
        let ideasEngine = IdeasEngine(store: ideasStore, llm: ideasLLM, config: ideasConfig)

        let goalStore = GoalStore(dbPath: path)
        var goalsConfig = GoalsConfig()
        goalsConfig.enabled = true
        let goalEngine = GoalEngine(
            store: goalStore,
            llm: StubIdeasLLM(texts: ["[]"]),
            config: goalsConfig,
            ideasEngine: ideasEngine
        )
        let now = Date()
        let goal = Goal(
            title: "Keep going",
            statement: "Steady",
            status: .active,
            stepIntervalMinutes: 60,
            createdAt: now,
            updatedAt: now
        )
        let pending = GoalStep(goalID: goal.id, ordinal: 0, title: "Next", status: .pending)
        try await goalStore.create(goal: goal, steps: [pending])

        try await goalEngine.postAdvance(goalID: goal.id, runID: UUID())

        #expect(try await goalStore.goal(id: goal.id)?.status == .active)
        #expect(ideasLLM.callCount == 0)
    }

    @Test
    func `Achieving a goal with ideas disabled spends no call`() async throws {
        let (path, base) = makeIdeasDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let ideasLLM = StubIdeasLLM(texts: ["[]"])
        let ideasStore = IdeasStore(dbPath: path)
        let ideasEngine = IdeasEngine(store: ideasStore, llm: ideasLLM, config: IdeasConfig())

        let goalStore = GoalStore(dbPath: path)
        var goalsConfig = GoalsConfig()
        goalsConfig.enabled = true
        let goalEngine = GoalEngine(
            store: goalStore,
            llm: StubIdeasLLM(texts: ["[]"]),
            config: goalsConfig,
            ideasEngine: ideasEngine
        )
        let now = Date()
        let goal = Goal(
            title: "Finish the report",
            statement: "Wrap it up",
            status: .active,
            stepIntervalMinutes: 60,
            createdAt: now,
            updatedAt: now
        )
        let done = GoalStep(goalID: goal.id, ordinal: 0, title: "Draft", status: .done)
        try await goalStore.create(goal: goal, steps: [done])

        try await goalEngine.postAdvance(goalID: goal.id, runID: UUID())

        #expect(ideasLLM.callCount == 0)
    }
}

@Suite("IdeasStore")
struct IdeasStoreTests {
    @Test
    func `Idea raw values stay stable for persisted rows`() {
        // Raw strings are the on-disk and wire contract; a rename here would
        // orphan every existing ideas table and model-facing kind.
        #expect(IdeaKind.planAdjustment.rawValue == "plan_adjustment")
        #expect(IdeaKind.newGoal.rawValue == "new_goal")
        #expect(IdeaKind.tip.rawValue == "tip")
        #expect(IdeaStatus.proposed.rawValue == "proposed")
        #expect(IdeaStatus.dismissed.rawValue == "dismissed")
        #expect(IdeaStatus.accepted.rawValue == "accepted")
    }

    @Test
    func `Append dedups non-dismissed titles case-insensitively`() async throws {
        let (path, base) = makeIdeasDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = IdeasStore(dbPath: path)

        let first = try await store.append(ideas: [makeIdea(title: "Stretch")])
        #expect(first.count == 1)
        let duplicate = try await store.append(ideas: [makeIdea(title: "  stretch  ")])
        #expect(duplicate.isEmpty)
        #expect(try await store.list().count == 1)
    }

    @Test
    func `Append skips blank titles fail-closed`() async throws {
        let (path, base) = makeIdeasDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = IdeasStore(dbPath: path)

        // Whitespace-only titles would persist as an empty dedup key and then
        // vanish through the engine and dashboard filters, leaving counts and
        // lists drifting, so the store drops them before the transaction.
        let inserted = try await store.append(ideas: [
            makeIdea(title: "   "),
            makeIdea(title: ""),
            makeIdea(title: "\n\t "),
            makeIdea(title: "Keep me")
        ])
        #expect(inserted.map(\.title) == ["Keep me"])
        #expect(try await store.list().map(\.title) == ["Keep me"])
        #expect(try await store.counts(status: nil)[.proposed] == 1)
    }

    @Test
    func `Dismissed titles may be appended again`() async throws {
        let (path, base) = makeIdeasDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = IdeasStore(dbPath: path)

        let inserted = try await store.append(ideas: [makeIdea(title: "Read more")])
        let idea = try #require(inserted.first)
        _ = try await store.setStatus(id: idea.id, status: .dismissed)

        let again = try await store.append(ideas: [makeIdea(title: "Read more")])
        #expect(again.count == 1)
        let counts = try await store.counts(status: nil)
        #expect(counts[.dismissed] == 1)
        #expect(counts[.proposed] == 1)
    }

    @Test
    func `Single-row read resolves one idea without listing`() async throws {
        let (path, base) = makeIdeasDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = IdeasStore(dbPath: path)
        let inserted = try await store.append(ideas: [makeIdea(title: "One")])
        let id = try #require(inserted.first?.id)
        #expect(try await store.idea(id: id)?.title == "One")
        #expect(try await store.idea(id: UUID()) == nil)
    }

    @Test
    func `Claim transitions atomically and rejects a stale source state`() async throws {
        let (path, base) = makeIdeasDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = IdeasStore(dbPath: path)
        let inserted = try await store.append(ideas: [makeIdea(title: "One")])
        let id = try #require(inserted.first?.id)

        let claimed = try await store.claim(id: id, from: .proposed, to: .accepted)
        #expect(claimed.status == .accepted)
        // A replay from the exhausted source state conflicts instead of
        // reapplying, which is what keeps accept idempotent.
        do {
            _ = try await store.claim(id: id, from: .proposed, to: .accepted)
            Issue.record("Expected IdeasStoreError.conflict")
        } catch let error as IdeasStoreError {
            guard case .conflict = error else {
                Issue.record("Expected conflict, got \(error)")
                return
            }
        }
        // A missing identifier reads as notFound, not a conflict.
        do {
            _ = try await store.claim(id: UUID(), from: .proposed, to: .accepted)
            Issue.record("Expected IdeasStoreError.notFound")
        } catch let error as IdeasStoreError {
            guard case .notFound = error else {
                Issue.record("Expected notFound, got \(error)")
                return
            }
        }
    }

    @Test
    func `Status updates and counts group by state`() async throws {
        let (path, base) = makeIdeasDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = IdeasStore(dbPath: path)
        let inserted = try await store.append(ideas: [
            makeIdea(title: "One"),
            makeIdea(title: "Two"),
            makeIdea(title: "Three")
        ])
        #expect(inserted.count == 3)
        let accepted = try await store.setStatus(id: inserted[0].id, status: .accepted)
        #expect(accepted.status == .accepted)

        let counts = try await store.counts(status: nil)
        #expect(counts[.accepted] == 1)
        #expect(counts[.proposed] == 2)
        let acceptedIdeas = try await store.list(status: .accepted)
        #expect(acceptedIdeas.map(\.title) == ["One"])
    }

    @Test
    func `Unknown status target throws notFound`() async throws {
        let (path, base) = makeIdeasDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = IdeasStore(dbPath: path)
        do {
            _ = try await store.setStatus(id: UUID(), status: .dismissed)
            Issue.record("Expected IdeasStoreError.notFound")
        } catch let error as IdeasStoreError {
            guard case .notFound = error else {
                Issue.record("Expected notFound, got \(error)")
                return
            }
        }
    }
}

/// Mutates one ideas field on a default config and asserts validation fails
/// with the expected dotted field name.
private func expectIdeasValidationFailure(
    _ mutate: (inout IdeasConfig) -> Void,
    field: String
) {
    var config = RuneWeaverConfig.default
    mutate(&config.ideas)
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

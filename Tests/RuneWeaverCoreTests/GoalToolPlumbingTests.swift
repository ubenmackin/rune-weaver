// Rune Weaver Core Tests — Goal tool plumbing on the shared ToolBus.
//
// Exercises the three goal tools as the model sees them: strict schema shape, permission
// tiers through the gate, creation with session linkage, status reads with plans and trails,
// ledger progress with session-linked and single-active defaults, ambiguous guidance instead
// of guessing, blocked parking, and fail-closed disabled copy. Backed by isolated temporary
// databases with a stub language provider so no test touches the real memory store.

import Foundation
import os
@testable import RuneWeaverCore
@testable import RuneWeaverTools
import Testing

/// Stub provider replaying canned plan texts for goal tool tests.
private final class GoalToolStubLLM: LLMProvider, Sendable {
    /// Stable test model metadata.
    let modelInfo = ModelInfo(name: "goal-tool-fixture", provider: "test", contextLength: 8192)

    /// Guarded replay state.
    private struct ReplayState: Sendable {
        var texts: [String]
        var index: Int
    }

    /// Guards replay state.
    private let state: OSAllocatedUnfairLock<ReplayState>

    /// Creates a stub replaying the given texts.
    init(texts: [String]) {
        self.state = OSAllocatedUnfairLock(initialState: ReplayState(texts: texts, index: 0))
    }

    /// Replays the next canned text as a finished stream.
    func chat(messages _: [Message], tools _: [any Tool]) -> AsyncStream<LLMResponse> {
        let text: String = state.withLock { replay in
            let next = replay.index < replay.texts.count ? replay.texts[replay.index] : replay.texts.last ?? ""
            replay.index += 1
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
private func makeGoalToolDBPath() -> (path: String, base: URL) {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("runeweaver-goal-tools-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return (base.appendingPathComponent("episodes.db").path, base)
}

/// Builds an enabled pursuit policy for goal tool tests.
private func makeGoalToolEnabledConfig() -> GoalsConfig {
    var config = GoalsConfig()
    config.enabled = true
    return config
}

/// Builds an engine plus store over a fresh database.
private func makeGoalToolStack(dbPath: String, llm: GoalToolStubLLM, config: GoalsConfig) -> (engine: GoalEngine, store: GoalStore) {
    let store = GoalStore(dbPath: dbPath)
    let engine = GoalEngine(store: store, llm: llm, config: config)
    return (engine, store)
}

/// Persists one goal with explicit steps, bypassing background planning for determinism.
private func persistGoalToolFixture(
    store: GoalStore,
    title: String = "Run daily",
    statement: String = "Run every morning",
    status: GoalStatus = .active,
    steps: [(title: String, status: StepStatus)] = [("Lace shoes", .pending), ("Out the door", .pending)]
) async throws -> Goal {
    let now = Date()
    let goal = Goal(
        title: title,
        statement: statement,
        status: status,
        stepIntervalMinutes: 1440,
        nextDueAt: now.addingTimeInterval(3600),
        createdAt: now,
        updatedAt: now
    )
    let rows = steps.enumerated().map { index, entry in
        GoalStep(goalID: goal.id, ordinal: index, title: entry.title, status: entry.status)
    }
    try await store.create(goal: goal, steps: rows)
    return goal
}

/// Parses a strict tool schema into its JSON object form.
private func parseGoalToolSchema(_ raw: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(raw.utf8), options: []) as? [String: Any])
}

@Suite("Goal Tool Plumbing")
struct GoalToolPlumbingTests {
    @Test
    func `Goal tools register in order with ledger permission tiers`() {
        let (path, base) = makeGoalToolDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let llm = GoalToolStubLLM(texts: ["[]"])
        let (engine, store) = makeGoalToolStack(dbPath: path, llm: llm, config: makeGoalToolEnabledConfig())
        let conversations = ConversationManager()
        let tools = GoalTools.makeTools(engine: engine, store: store, conversations: conversations, goalsConfig: makeGoalToolEnabledConfig())
        #expect(tools.map(\.name) == ["goal.create", "goal.status", "goal.progress"])
        #expect(GoalTools.toolNames == ["goal.create", "goal.status", "goal.progress"])
        #expect(tools[0].permissionLevel == .requiresApproval)
        #expect(tools[1].permissionLevel == .readOnly)
        #expect(tools[2].permissionLevel == .requiresApproval)
    }

    @Test
    func `Goal schemas stay strict objects with alias coverage`() throws {
        let (path, base) = makeGoalToolDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let llm = GoalToolStubLLM(texts: ["[]"])
        let (engine, store) = makeGoalToolStack(dbPath: path, llm: llm, config: makeGoalToolEnabledConfig())
        let tools = GoalTools.makeTools(engine: engine, store: store, goalsConfig: makeGoalToolEnabledConfig())
        for tool in tools {
            let parsed = try parseGoalToolSchema(tool.inputSchema.rawValue)
            #expect(parsed["type"] as? String == "object", "Tool \(tool.name) must declare type object")
            #expect(parsed["additionalProperties"] as? Bool == false, "Tool \(tool.name) must opt into strict mode")
            #expect((parsed["properties"] as? [String: Any]) != nil, "Tool \(tool.name) must declare properties")
        }
        let byName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        let create = try #require(byName["goal.create"])
        #expect(create.inputSchema.rawValue.contains(#""required":["title","statement"]"#))
        let progress = try #require(byName["goal.progress"])
        #expect(progress.inputSchema.rawValue.contains("stepOrdinal"))
        #expect(progress.inputSchema.rawValue.contains("step_ordinal"))
        #expect(progress.inputSchema.rawValue.contains("allOf"))
        let status = try #require(byName["goal.status"])
        #expect(status.inputSchema.rawValue.contains("goalID"))
        #expect(status.inputSchema.rawValue.contains("goal_id"))
    }

    @Test
    func `Create and progress park for approval while status stays approval-free`() async throws {
        let (path, base) = makeGoalToolDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let llm = GoalToolStubLLM(texts: ["[]"])
        let (engine, store) = makeGoalToolStack(dbPath: path, llm: llm, config: makeGoalToolEnabledConfig())
        let tools = GoalTools.makeTools(engine: engine, store: store, goalsConfig: makeGoalToolEnabledConfig())
        let gate = PermissionGate()
        let byName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        let create = try #require(byName["goal.create"])
        let status = try #require(byName["goal.status"])
        let progress = try #require(byName["goal.progress"])
        let createCall = ToolInput(toolName: "goal.create", argumentsJSON: #"{"title":"Run","statement":"Run daily"}"#)
        let createVerdict = await gate.checkPermission(toolCall: createCall, tool: create)
        guard case .requiresApproval = createVerdict else {
            Issue.record("goal.create must park for approval")
            return
        }
        let statusCall = ToolInput(toolName: "goal.status", argumentsJSON: #"{"all":true}"#)
        let statusVerdict = await gate.checkPermission(toolCall: statusCall, tool: status)
        #expect(statusVerdict == .allowed)
        // Ledger moves mutate durable pursuit state (step transitions plus whole-goal
        // parking), so they park unlike remembered facts: the remember_fact bargain
        // covers semantic notes, not shared pursuit transitions.
        let progressCall = ToolInput(toolName: "goal.progress", argumentsJSON: #"{"stepOrdinal":0,"status":"done"}"#)
        let progressVerdict = await gate.checkPermission(toolCall: progressCall, tool: progress)
        guard case .requiresApproval = progressVerdict else {
            Issue.record("goal.progress must park for approval")
            return
        }
        // Status reads ride the bus without an approval handler.
        let bus = ToolBus(permissionGate: PermissionGate())
        for tool in tools {
            await bus.register(tool: tool)
        }
        await bus.setLegacyApprovalHandler { _, _ in false }
        let listed = await bus.toolNames()
        #expect(Set(listed) == Set(GoalTools.toolNames))
    }

    @Test
    func `Create links the creating chat observable on the manager`() async throws {
        let (path, base) = makeGoalToolDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let llm = GoalToolStubLLM(texts: [#"[{"title":"Lace shoes"}]"#])
        let config = makeGoalToolEnabledConfig()
        let (engine, store) = makeGoalToolStack(dbPath: path, llm: llm, config: config)
        let conversations = ConversationManager()
        let session = await conversations.createSession()
        let tools = GoalTools.makeTools(engine: engine, store: store, conversations: conversations, goalsConfig: config)
        let create = try #require(tools.first { $0.name == "goal.create" })
        let output = try await create.execute(
            input: ToolInput(toolName: "goal.create", argumentsJSON: #"{"title":"Run daily","statement":"Run every morning"}"#),
            context: ToolContext(conversationID: session.id)
        )
        #expect(output.isError == false)
        let envelope = try JSONDecoder().decode(GoalCreateEnvelope.self, from: Data(output.content.utf8))
        #expect(envelope.title == "Run daily")
        #expect(envelope.sessionID == session.id.uuidString)
        #expect(await conversations.session(id: session.id)?.goalID?.uuidString == envelope.goalID)
        let storedID = try #require(UUID(uuidString: envelope.goalID))
        #expect(try await store.goal(id: storedID) != nil)
    }

    @Test
    func `Create dry run previews without persisting`() async throws {
        let (path, base) = makeGoalToolDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let llm = GoalToolStubLLM(texts: ["[]"])
        let config = makeGoalToolEnabledConfig()
        let (engine, store) = makeGoalToolStack(dbPath: path, llm: llm, config: config)
        let tools = GoalTools.makeTools(engine: engine, store: store, goalsConfig: config)
        let create = try #require(tools.first { $0.name == "goal.create" })
        let output = try await create.execute(
            input: ToolInput(toolName: "goal.create", argumentsJSON: #"{"title":"Run daily","statement":"Run every morning"}"#),
            context: ToolContext(conversationID: UUID(), dryRun: true)
        )
        #expect(output.isError == false)
        #expect(try await store.list(status: nil).isEmpty)
    }

    @Test
    func `Status returns plans dues and recent events`() async throws {
        let (path, base) = makeGoalToolDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let llm = GoalToolStubLLM(texts: ["[]"])
        let config = makeGoalToolEnabledConfig()
        let (engine, store) = makeGoalToolStack(dbPath: path, llm: llm, config: config)
        let goal = try await persistGoalToolFixture(store: store)
        _ = try await store.appendEvent(goalID: goal.id, kind: .note, message: "Laced shoes at dawn")
        let tools = GoalTools.makeTools(engine: engine, store: store, goalsConfig: config)
        let status = try #require(tools.first { $0.name == "goal.status" })
        let single = try await status.execute(
            input: ToolInput(toolName: "goal.status", argumentsJSON: #"{"goalID":"\#(goal.id.uuidString)"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(single.isError == false)
        let singleEnvelope = try JSONDecoder().decode(GoalStatusEnvelope.self, from: Data(single.content.utf8))
        #expect(singleEnvelope.count == 1)
        let detail = try #require(singleEnvelope.goals.first)
        #expect(detail.steps.map(\.title).contains("Lace shoes"))
        #expect(detail.recentEvents.contains { $0.message.contains("Laced shoes") })
        #expect(detail.nextDueAt != nil)
        let all = try await status.execute(
            input: ToolInput(toolName: "goal.status", argumentsJSON: #"{"all":true,"limit":5}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(all.isError == false)
        #expect(all.content.contains("Lace shoes"))
        let missing = try await status.execute(
            input: ToolInput(toolName: "goal.status", argumentsJSON: "{}"),
            context: ToolContext(conversationID: UUID())
        )
        #expect(missing.isError == true)
    }

    @Test
    func `Progress resolves none single ambiguous plus session default`() async throws {
        let (path, base) = makeGoalToolDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let llm = GoalToolStubLLM(texts: ["[]"])
        let config = makeGoalToolEnabledConfig()
        let (engine, store) = makeGoalToolStack(dbPath: path, llm: llm, config: config)
        let conversations = ConversationManager()
        let session = await conversations.createSession()
        let tools = GoalTools.makeTools(engine: engine, store: store, conversations: conversations, goalsConfig: config)
        let progress = try #require(tools.first { $0.name == "goal.progress" })

        // No goals anywhere guides instead of guessing.
        let none = try await progress.execute(
            input: ToolInput(toolName: "goal.progress", argumentsJSON: #"{"stepOrdinal":0,"status":"done"}"#),
            context: ToolContext(conversationID: session.id)
        )
        #expect(none.isError == true)
        #expect(none.content.contains("No goal"))

        // One active goal is the only safe guess.
        let lone = try await persistGoalToolFixture(store: store, title: "Lone goal")
        let loneResult = try await progress.execute(
            input: ToolInput(toolName: "goal.progress", argumentsJSON: #"{"stepOrdinal":0,"status":"done"}"#),
            context: ToolContext(conversationID: session.id)
        )
        #expect(loneResult.isError == false)
        let loneEnvelope = try JSONDecoder().decode(GoalProgressEnvelope.self, from: Data(loneResult.content.utf8))
        #expect(loneEnvelope.goalID == lone.id.uuidString)
        #expect(try await store.steps(goalID: lone.id).first { $0.ordinal == 0 }?.status == .done)

        // Two active goals without a session link must not guess.
        _ = try await persistGoalToolFixture(store: store, title: "Second goal")
        let ambiguous = try await progress.execute(
            input: ToolInput(toolName: "goal.progress", argumentsJSON: #"{"stepOrdinal":0,"status":"done"}"#),
            context: ToolContext(conversationID: session.id)
        )
        #expect(ambiguous.isError == true)
        #expect(ambiguous.content.contains("Multiple active goals"))

        // The session link wins over the ambiguous scan.
        await conversations.linkSession(session.id, toGoal: lone.id)
        let linked = try await progress.execute(
            input: ToolInput(toolName: "goal.progress", argumentsJSON: #"{"stepOrdinal":1,"status":"in_progress"}"#),
            context: ToolContext(conversationID: session.id)
        )
        #expect(linked.isError == false)
        let linkedEnvelope = try JSONDecoder().decode(GoalProgressEnvelope.self, from: Data(linked.content.utf8))
        #expect(linkedEnvelope.goalID == lone.id.uuidString)
        #expect(linkedEnvelope.status == StepStatus.inProgress.rawValue)
    }

    @Test
    func `Blocked progress with a note parks the goal`() async throws {
        let (path, base) = makeGoalToolDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let llm = GoalToolStubLLM(texts: ["[]"])
        let config = makeGoalToolEnabledConfig()
        let (engine, store) = makeGoalToolStack(dbPath: path, llm: llm, config: config)
        let goal = try await persistGoalToolFixture(store: store)
        let tools = GoalTools.makeTools(engine: engine, store: store, goalsConfig: config)
        let progress = try #require(tools.first { $0.name == "goal.progress" })
        let output = try await progress.execute(
            input: ToolInput(
                toolName: "goal.progress",
                argumentsJSON: #"{"goalID":"\#(goal.id.uuidString)","stepOrdinal":0,"status":"blocked","note":"Waiting on shoes"}"#
            ),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == false)
        let envelope = try JSONDecoder().decode(GoalProgressEnvelope.self, from: Data(output.content.utf8))
        #expect(envelope.needsInput == true)
        #expect(try await store.goal(id: goal.id)?.status == .needsInput)
        #expect(try await store.events(goalID: goal.id).map(\.message).contains { $0.contains("Waiting on shoes") })
    }

    @Test
    func `Progress description teaches the ledger bargain`() {
        let (path, base) = makeGoalToolDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let llm = GoalToolStubLLM(texts: ["[]"])
        let (engine, store) = makeGoalToolStack(dbPath: path, llm: llm, config: makeGoalToolEnabledConfig())
        let tools = GoalTools.makeTools(engine: engine, store: store, goalsConfig: makeGoalToolEnabledConfig())
        let progress = tools.first { $0.name == "goal.progress" }
        #expect(progress?.description.contains("only the local ledger") == true)
        #expect(progress?.description.contains("permission-gated") == true)
    }

    @Test
    func `Disabled tools fail closed with the honest copy`() async throws {
        let (path, base) = makeGoalToolDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let llm = GoalToolStubLLM(texts: ["[]"])
        let disabled = GoalsConfig()
        let (engine, store) = makeGoalToolStack(dbPath: path, llm: llm, config: disabled)
        let tools = GoalTools.makeTools(engine: engine, store: store, goalsConfig: disabled)
        #expect(tools.count == 3)
        let create = try await tools.first { $0.name == "goal.create" }?.execute(
            input: ToolInput(toolName: "goal.create", argumentsJSON: #"{"title":"Run","statement":"Run daily"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(create?.isError == true)
        #expect(create?.content.contains("[goals]") == true)
        #expect(create?.content.lowercased().contains("disabled") == true)
        let status = try await tools.first { $0.name == "goal.status" }?.execute(
            input: ToolInput(toolName: "goal.status", argumentsJSON: #"{"all":true}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(status?.isError == true)
        #expect(status?.content.contains("[goals]") == true)
        let progress = try await tools.first { $0.name == "goal.progress" }?.execute(
            input: ToolInput(toolName: "goal.progress", argumentsJSON: #"{"stepOrdinal":0,"status":"done"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(progress?.isError == true)
        #expect(progress?.content.contains("[goals]") == true)
    }

    @Test
    func `Builtin registration stays nil-gated with disabled visibility`() async throws {
        let (path, base) = makeGoalToolDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let llm = GoalToolStubLLM(texts: ["[]"])
        let enabled = makeGoalToolEnabledConfig()
        let store = GoalStore(dbPath: path)
        let engine = GoalEngine(store: store, llm: llm, config: enabled)
        // A throwaway policy store keeps the mandatory egress supervisor off
        // the operator's real policy.toml while still verifying at the factory.
        let policyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rw-goal-plumbing-policy-\(UUID().uuidString).toml")
        let policyStore = PolicyStore(fileURL: policyURL)
        await policyStore.update(.safeDefault)
        // Nil collaborators keep the suite unchanged so unwired callers see no drift.
        let withoutGoals = try await BuiltinToolPlugins.makeAllTools(policyStore: policyStore)
        #expect(!withoutGoals.map(\.name).contains("goal.create"))
        // Wired collaborators register through the single shared path.
        let withGoals = try await BuiltinToolPlugins.makeAllTools(
            goalEngine: engine,
            goalStore: store,
            goalsConfig: enabled,
            policyStore: policyStore
        )
        #expect(Set(GoalTools.toolNames).isSubset(of: Set(withGoals.map(\.name))))
        #expect(Set(GoalTools.toolNames).isSubset(of: Set(BuiltinToolPlugins.allToolNames)))
        // Disabled still registers so GET /tools stays stable and calls fail honest.
        let disabledWired = try await BuiltinToolPlugins.makeAllTools(
            goalEngine: engine,
            goalStore: store,
            goalsConfig: GoalsConfig(),
            policyStore: policyStore
        )
        #expect(Set(GoalTools.toolNames).isSubset(of: Set(disabledWired.map(\.name))))
    }

    @Test
    func `Malformed goal arguments fail cleanly`() async throws {
        let (path, base) = makeGoalToolDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let llm = GoalToolStubLLM(texts: ["[]"])
        let config = makeGoalToolEnabledConfig()
        let (engine, store) = makeGoalToolStack(dbPath: path, llm: llm, config: config)
        let tools = GoalTools.makeTools(engine: engine, store: store, goalsConfig: config)
        let byName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        let create = try #require(byName["goal.create"])
        let empty = try await create.execute(
            input: ToolInput(toolName: "goal.create", argumentsJSON: #"{"title":"  ","statement":"  "}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(empty.isError == true)
        let progress = try #require(byName["goal.progress"])
        let badStatus = try await progress.execute(
            input: ToolInput(toolName: "goal.progress", argumentsJSON: #"{"stepOrdinal":0,"status":"pending"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(badStatus.isError == true)
        let badOrdinal = try await progress.execute(
            input: ToolInput(toolName: "goal.progress", argumentsJSON: #"{"stepOrdinal":-1,"status":"done"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(badOrdinal.isError == true)
    }
}

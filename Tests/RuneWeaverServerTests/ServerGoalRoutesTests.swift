// Rune Weaver Server Tests — Goals REST surface plus live push shapes.

import Foundation
import NIOWebSocket
@testable import RuneWeaverCore
@testable import RuneWeaverServer
import Testing
import Vapor

/// Stub provider replaying one canned answer for planning and advancement turns.
private final class GoalRouteStubLLM: LLMProvider, Sendable {
    /// Stable test model metadata.
    let modelInfo = ModelInfo(name: "goal-route-fixture", provider: "test", contextLength: 8192)
    /// Canned answer text.
    private let answer: String

    /// Creates a stub.
    init(answer: String = #"[{"title": "First step"}, {"title": "Second step"}]"#) {
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

/// Recording socket capturing hub broadcasts without a live handshake.
private actor GoalRouteRecordingSocket: WSConnectionSocket {
    /// Frames delivered to this connection.
    private(set) var sent: [String] = []

    /// Records one frame.
    func send(_ text: String) async throws {
        sent.append(text)
    }

    /// Ignored; these tests never close the connection.
    func close(code _: WebSocketErrorCode) async throws {}
}

/// Builds a configured application sharing an isolated goal store.
private func withGoalApp<T>(
    enabled: Bool = true,
    answer: String = #"[{"title": "First step"}, {"title": "Second step"}]"#,
    maxTriggersPerGoal: Int? = nil,
    _ body: (Application, ServerContext) async throws -> T
) async throws -> T {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("runeweaver-goal-routes-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let app = try await Application.make(.testing)
    do {
        let dbPath = base.appendingPathComponent("episodes.db").path
        let conversations = ConversationManager()
        let gate = PermissionGate()
        let approvals = ApprovalQueue(permissionGate: gate)
        let bus = ToolBus(permissionGate: gate)
        let memory = MemoryEngine(
            episodesDBPath: dbPath,
            vectorDBPath: base.appendingPathComponent("vectors").path,
            profilePath: base.appendingPathComponent("profile.json").path
        )
        let stub = GoalRouteStubLLM(answer: answer)
        let orchestrator = Orchestrator(
            conversations: conversations,
            toolBus: bus,
            llm: stub,
            memoryEngine: memory
        )
        let store = GoalStore(dbPath: dbPath)
        var goalsConfig = GoalsConfig()
        goalsConfig.enabled = enabled
        if let maxTriggersPerGoal {
            goalsConfig.maxTriggersPerGoal = maxTriggersPerGoal
        }
        let engine = GoalEngine(store: store, llm: stub, config: goalsConfig)
        let context = ServerContext(
            conversations: conversations,
            toolBus: bus,
            orchestrator: orchestrator,
            memoryEngine: memory,
            permissionGate: gate,
            approvals: approvals,
            scheduler: SchedulerStore(),
            runs: RunLogStore(),
            hub: WSHub(),
            pluginStore: ToolRegistryStore(dbPath: dbPath),
            toolStates: ToolStateStore(dbPath: dbPath),
            goals: store,
            goalEngine: engine,
            goalsConfig: goalsConfig
        )
        try configureRuneWeaver(app, context: context)
        let value = try await body(app, context)
        try await app.asyncShutdown()
        try? FileManager.default.removeItem(at: base)
        return value
    } catch {
        try? await app.asyncShutdown()
        try? FileManager.default.removeItem(at: base)
        throw error
    }
}

/// Sends one request through the full registered surface. app: Configured
/// application.
private func goalRequest(app: Application, method: HTTPMethod, path: String, body: some Content?) async throws -> Response {
    let request = Request(
        application: app,
        method: method,
        url: URI(string: path),
        on: app.eventLoopGroup.next()
    )
    if let body {
        try request.content.encode(body)
    }
    return try await app.responder.respond(to: request).get()
}

/// Sends a body-less request through the full registered surface.
private func goalRequest(app: Application, method: HTTPMethod, path: String) async throws -> Response {
    struct Empty: Content {}
    return try await goalRequest(app: app, method: method, path: path, body: Empty?.none)
}

/// Reads the frame discriminator without failing on unrelated shapes.
private func goalFrameType(_ raw: String) -> String? {
    guard let data = raw.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        return nil
    }
    return object["type"] as? String
}

@Suite("Goal Route Validation")
struct GoalRouteValidationTests {
    @Test
    func `Blank title is rejected`() async throws {
        try await withGoalApp { app, _ in
            let response = try await goalRequest(
                app: app,
                method: .POST,
                path: "/goals",
                body: GoalCreateRequest(title: "   ", statement: "Keep herbs alive")
            )
            #expect(response.status == .badRequest)
        }
    }

    @Test
    func `Malformed identifier is rejected`() async throws {
        try await withGoalApp { app, _ in
            let response = try await goalRequest(app: app, method: .GET, path: "/goals/not-a-uuid")
            #expect(response.status == .badRequest)
        }
    }

    @Test
    func `Unknown goal is not found`() async throws {
        try await withGoalApp { app, _ in
            let missing = UUID().uuidString
            let detail = try await goalRequest(app: app, method: .GET, path: "/goals/\(missing)")
            #expect(detail.status == .notFound)
            let patch = try await goalRequest(
                app: app,
                method: .PATCH,
                path: "/goals/\(missing)",
                body: GoalPatchRequest(title: "New title")
            )
            #expect(patch.status == .notFound)
            let deleted = try await goalRequest(app: app, method: .DELETE, path: "/goals/\(missing)")
            #expect(deleted.status == .notFound)
        }
    }

    @Test
    func `Unknown status filter is rejected`() async throws {
        try await withGoalApp { app, _ in
            let response = try await goalRequest(app: app, method: .GET, path: "/goals?status=nope")
            #expect(response.status == .badRequest)
        }
    }
}

@Suite("Goal Disabled Pursuit")
struct GoalDisabledTests {
    @Test
    func `Creation while disabled answers with the honest message`() async throws {
        try await withGoalApp(enabled: false) { app, _ in
            let response = try await goalRequest(
                app: app,
                method: .POST,
                path: "/goals",
                body: GoalCreateRequest(title: "Tend herbs", statement: "Keep basil alive")
            )
            #expect(response.status == .badRequest)
            // The engine message names the guard so dashboards surface why the
            // row was refused instead of a bare status code.
            let body = response.body.string ?? ""
            #expect(body.lowercased().contains("disabled") == true)
        }
    }
}

@Suite("Goal Trigger Budget")
struct GoalTriggerBudgetTests {
    @Test
    func `Patch caps armed triggers at the configured budget`() async throws {
        try await withGoalApp(maxTriggersPerGoal: 1) { app, context in
            let now = Date()
            let goal = Goal(
                title: "Watch inbox",
                statement: "React to arriving events",
                status: .active,
                stepIntervalMinutes: 60,
                nextDueAt: now,
                createdAt: now,
                updatedAt: now
            )
            try await context.goals.create(
                goal: goal,
                steps: [GoalStep(goalID: goal.id, ordinal: 0, title: "Check", status: .pending)]
            )
            let response = try await goalRequest(
                app: app,
                method: .PATCH,
                path: "/goals/\(goal.id.uuidString)",
                body: GoalPatchRequest(triggers: [
                    GoalTriggerInput(eventKind: "step_done", cooldownMinutes: 15),
                    GoalTriggerInput(eventKind: "episode", cooldownMinutes: 15),
                    GoalTriggerInput(eventKind: "mail_arrival", cooldownMinutes: 15)
                ])
            )
            #expect(response.status == .ok)
            // The edit honors the same per-goal budget creation does instead of
            // the absolute bound, so a hand-built curl cannot over-arm a goal.
            let armed = try await context.goals.triggers(for: goal.id)
            #expect(armed.count == 1)
            #expect(armed.first?.eventKind == "step_done")
        }
    }
}

@Suite("Goal Summary Counts")
struct GoalSummaryTests {
    @Test
    func `Summary tallies every lifecycle state`() async throws {
        try await withGoalApp { _, context in
            // Seed directly through the store so each row lands in its terminal
            // state without paying planning turns; the summary only counts.
            let now = Date()
            func seed(title: String, status: GoalStatus) async throws -> Goal {
                let goal = Goal(
                    title: title,
                    statement: "\(title) statement",
                    status: .active,
                    stepIntervalMinutes: 60,
                    nextDueAt: now,
                    createdAt: now,
                    updatedAt: now
                )
                try await context.goals.create(
                    goal: goal,
                    steps: [GoalStep(goalID: goal.id, ordinal: 0, title: "Only step", status: .pending)]
                )
                if status != .active {
                    try await context.goals.setStatus(goalID: goal.id, status: status)
                }
                return goal
            }
            _ = try await seed(title: "Active one", status: .active)
            _ = try await seed(title: "Active two", status: .active)
            _ = try await seed(title: "Paused", status: .paused)
            _ = try await seed(title: "Parked", status: .needsInput)
            _ = try await seed(title: "Done", status: .achieved)
            _ = try await seed(title: "Dropped", status: .abandoned)
            let stored = try await context.goals.list(status: nil)
            #expect(stored.count == 6)
            // Count through the DTO layer so the test pins the wire shape, not
            // just the store rows.
            var active = 0
            var paused = 0
            var needsInput = 0
            var achieved = 0
            var abandoned = 0
            for goal in stored {
                let steps = try await context.goals.steps(goalID: goal.id)
                let dto = GoalDTO(goal: goal, steps: steps)
                switch dto.status {
                case GoalStatus.active.rawValue:
                    active += 1
                case GoalStatus.paused.rawValue:
                    paused += 1
                case GoalStatus.needsInput.rawValue:
                    needsInput += 1
                case GoalStatus.achieved.rawValue:
                    achieved += 1
                case GoalStatus.abandoned.rawValue:
                    abandoned += 1
                default:
                    Issue.record("Unexpected status \(dto.status)")
                }
            }
            #expect(active == 2)
            #expect(paused == 1)
            #expect(needsInput == 1)
            #expect(achieved == 1)
            #expect(abandoned == 1)
            let summary = GoalsSummaryResponse(
                total: stored.count,
                active: active,
                paused: paused,
                needsInput: needsInput,
                achieved: achieved,
                abandoned: abandoned
            )
            #expect(summary.total == 6)
            #expect(summary.needsInput == 1)
        }
    }

    @Test
    func `Summary route answers through HTTP`() async throws {
        try await withGoalApp { app, context in
            let now = Date()
            let goal = Goal(
                title: "Tend herbs",
                statement: "Keep basil alive",
                status: .active,
                stepIntervalMinutes: 60,
                nextDueAt: now,
                createdAt: now,
                updatedAt: now
            )
            try await context.goals.create(
                goal: goal,
                steps: [GoalStep(goalID: goal.id, ordinal: 0, title: "Water", status: .pending)]
            )
            let response = try await goalRequest(app: app, method: .GET, path: "/goals/summary")
            #expect(response.status == .ok)
            let decoded = try response.content.decode(GoalsSummaryResponse.self)
            #expect(decoded.total >= 1)
            #expect(decoded.active >= 1)
            #expect(decoded.needsInput == 0)
        }
    }
}

@Suite("Goal Frame Shapes")
struct GoalFrameTests {
    @Test
    func `Goal updated frame round-trips with its snapshot`() throws {
        let id = UUID()
        let now = Date()
        let snapshot = WSGoalSnapshot(
            id: id,
            title: "Tend herbs",
            statement: "Keep basil alive",
            status: GoalStatus.active.rawValue,
            progress: WSGoalProgress(done: 1, total: 3),
            stepIntervalMinutes: 60,
            nextDueAt: now,
            originSessionID: nil,
            createdAt: now,
            updatedAt: now
        )
        let frame = WSGoalUpdatedFrame(goal: snapshot)
        let decoded = try JSONDecoder().decode(WSGoalUpdatedFrame.self, from: JSONEncoder().encode(frame))
        #expect(decoded == frame)
        #expect(decoded.type == "goal_updated")
        #expect(decoded.goal.id == id)
        #expect(decoded.goal.progress.done == 1)
        #expect(decoded.goal.progress.total == 3)
        // The REST DTO converts losslessly into the push snapshot so live rows
        // and list reloads reconcile instead of drifting on key spellings.
        let dto = GoalDTO(
            id: id,
            title: "Tend herbs",
            statement: "Keep basil alive",
            status: GoalStatus.active.rawValue,
            progress: GoalProgressDTO(done: 1, total: 3),
            stepIntervalMinutes: 60,
            nextDueAt: now,
            createdAt: now,
            updatedAt: now
        )
        #expect(dto.wsSnapshot() == snapshot)
    }

    @Test
    func `Proactive message frame round-trips with its links`() throws {
        let sessionID = UUID()
        let goalID = UUID()
        let frame = WSProactiveMessageFrame(
            kind: "goal_step_done",
            title: "Tend herbs",
            headline: "Watered the basil.",
            sessionID: sessionID,
            goalID: goalID
        )
        let decoded = try JSONDecoder().decode(WSProactiveMessageFrame.self, from: JSONEncoder().encode(frame))
        #expect(decoded == frame)
        #expect(decoded.type == "proactive_message")
        #expect(decoded.kind == "goal_step_done")
        #expect(decoded.title == "Tend herbs")
        #expect(decoded.headline == "Watered the basil.")
        #expect(decoded.sessionID == sessionID)
        #expect(decoded.goalID == goalID)
    }

    @Test
    func `Goal broadcast reaches every socket`() async throws {
        try await withGoalApp { _, context in
            let first = GoalRouteRecordingSocket()
            let second = GoalRouteRecordingSocket()
            _ = await context.hub.add(id: UUID(), box: first)
            _ = await context.hub.add(id: UUID(), box: second)
            let now = Date()
            let dto = GoalDTO(
                id: UUID(),
                title: "Tend herbs",
                statement: "Keep basil alive",
                status: GoalStatus.active.rawValue,
                progress: GoalProgressDTO(done: 0, total: 1),
                stepIntervalMinutes: 60,
                nextDueAt: now,
                createdAt: now,
                updatedAt: now
            )
            await context.hub.broadcastGoal(dto)
            let firstFrames = await first.sent
            let secondFrames = await second.sent
            #expect(firstFrames.count == 1)
            #expect(secondFrames.count == 1)
            let raw = try #require(firstFrames.first)
            #expect(goalFrameType(raw) == "goal_updated")
            let decoded = try JSONDecoder().decode(WSGoalUpdatedFrame.self, from: Data(raw.utf8))
            #expect(decoded.goal.id == dto.id)
            #expect(decoded.goal.title == dto.title)
        }
    }
}

@Suite("Goal Runs Filter")
struct GoalRunsFilterTests {
    @Test
    func `Run history filters by goal through HTTP`() async throws {
        try await withGoalApp(answer: "advanced one step") { app, context in
            let now = Date()
            let goal = Goal(
                title: "Tend herbs",
                statement: "Keep basil alive",
                status: .active,
                stepIntervalMinutes: 60,
                nextDueAt: now.addingTimeInterval(-60),
                createdAt: now,
                updatedAt: now
            )
            try await context.goals.create(
                goal: goal,
                steps: [GoalStep(goalID: goal.id, ordinal: 0, title: "Water basil", status: .pending)]
            )
            // One goal-linked run plus one unrelated chat run: the filter must
            // return exactly the linked row.
            _ = await context.runs.append(
                kind: "goal",
                status: "ok",
                message: goal.title,
                sessionID: UUID(),
                goalID: goal.id,
                response: "advanced one step"
            )
            _ = await context.runs.append(kind: "chat", status: "ok", message: "hello")
            let filtered = try await goalRequest(app: app, method: .GET, path: "/runs?goalId=\(goal.id.uuidString)")
            #expect(filtered.status == .ok)
            let decoded = try filtered.content.decode(RunLogsResponse.self)
            #expect(decoded.count == 1)
            #expect(decoded.runs.first?.goalID == goal.id)
            #expect(decoded.runs.first?.kind == "goal")
            // The snake_case spelling filters identically so dashboards can use
            // either key without a second code path.
            let snake = try await goalRequest(app: app, method: .GET, path: "/runs?goal_id=\(goal.id.uuidString)")
            #expect(snake.status == .ok)
            #expect(try snake.content.decode(RunLogsResponse.self).count == 1)
            let other = try await goalRequest(app: app, method: .GET, path: "/runs?goalId=\(UUID().uuidString)")
            #expect(other.status == .ok)
            #expect(try other.content.decode(RunLogsResponse.self).count == 0)
        }
    }

    @Test
    func `Manual advance returns run plus session identifiers`() async throws {
        try await withGoalApp(answer: "advanced one step") { app, context in
            let now = Date()
            let goal = Goal(
                title: "Tend herbs",
                statement: "Keep basil alive",
                status: .active,
                stepIntervalMinutes: 60,
                nextDueAt: now.addingTimeInterval(-60),
                createdAt: now,
                updatedAt: now
            )
            try await context.goals.create(
                goal: goal,
                steps: [GoalStep(goalID: goal.id, ordinal: 0, title: "Water basil", status: .pending)]
            )
            let response = try await goalRequest(app: app, method: .POST, path: "/goals/\(goal.id.uuidString)/advance")
            #expect(response.status == .ok)
            let receipt = try response.content.decode(GoalAdvanceResponse.self)
            #expect(receipt.goalID == goal.id)
            // The receipt links the durable run row and its session without a
            // second lookup: both identifiers resolve.
            #expect(await context.runs.entry(id: receipt.runID) != nil)
            #expect(await context.conversations.session(id: receipt.sessionID) != nil)
            #expect(await context.runs.entry(id: receipt.runID)?.goalID == goal.id)
        }
    }

    @Test
    func `Manual advance on unplanned goal triggers background planning`() async throws {
        try await withGoalApp(answer: #"[{"title": "Step 1"}, {"title": "Step 2"}]"#) { app, context in
            let now = Date()
            let goal = Goal(
                title: "Develop Plan",
                statement: "Plan something complex",
                status: .unplanned,
                stepIntervalMinutes: 60,
                nextDueAt: now,
                createdAt: now,
                updatedAt: now
            )
            try await context.goals.create(goal: goal, steps: [])
            let response = try await goalRequest(app: app, method: .POST, path: "/goals/\(goal.id.uuidString)/advance")
            #expect(response.status == .ok)
            let receipt = try response.content.decode(GoalAdvanceResponse.self)
            #expect(receipt.goalID == goal.id)
            await context.goalEngine.waitForPendingPlan(goalID: goal.id)
            let steps = try await context.goals.steps(goalID: goal.id)
            #expect(steps.count == 2)
            #expect(steps.map(\.title) == ["Step 1", "Step 2"])
            let fresh = try await context.goals.goal(id: goal.id)
            #expect(fresh?.status == .active)
        }
    }

    @Test
    func `Patch step to done achieves goal when no actionable steps remain`() async throws {
        try await withGoalApp { app, context in
            let now = Date()
            let goal = Goal(
                title: "Fix bug",
                statement: "Resolve issue",
                status: .active,
                stepIntervalMinutes: 60,
                nextDueAt: now,
                createdAt: now,
                updatedAt: now
            )
            let step = GoalStep(goalID: goal.id, ordinal: 0, title: "Apply patch", status: .pending)
            try await context.goals.create(
                goal: goal,
                steps: [step]
            )

            let response = try await goalRequest(
                app: app,
                method: .PATCH,
                path: "/goals/\(goal.id.uuidString)/steps/\(step.id.uuidString)",
                body: GoalStepPatchRequest(status: "done", note: "Patched")
            )
            #expect(response.status == .ok)
            let updatedStep = try response.content.decode(GoalStepDTO.self)
            #expect(updatedStep.status == "done")

            let freshGoal = try await context.goals.goal(id: goal.id)
            #expect(freshGoal?.status == .achieved)
        }
    }
}

@Suite("Goal Settings Merge")
struct GoalSettingsMergeTests {
    @Test
    func `Goals partial patch preserves omitted fields`() throws {
        // A dashboard edit elsewhere carries only its own keys, so each merge
        // must leave the rest of the stored pursuit policy untouched.
        var config = RuneWeaverConfig.default
        #expect(config.goals.enabled == false)
        #expect(config.goals.stepIntervalMinutes == 1440)
        #expect(config.goals.maxActiveGoals == 10)

        try UpdateSettingsRequest(goals: GoalsUpdate(enabled: true)).apply(to: &config)
        #expect(config.goals.enabled == true)
        #expect(config.goals.stepIntervalMinutes == 1440)
        #expect(config.goals.maxActiveGoals == 10)

        try UpdateSettingsRequest(goals: GoalsUpdate(stepIntervalMinutes: 60)).apply(to: &config)
        #expect(config.goals.enabled == true)
        #expect(config.goals.stepIntervalMinutes == 60)
        #expect(config.goals.maxActiveGoals == 10)

        // A request without a goals patch is a no-op for the section.
        try UpdateSettingsRequest().apply(to: &config)
        #expect(config.goals.enabled == true)
        #expect(config.goals.stepIntervalMinutes == 60)
        #expect(config.goals.maxActiveGoals == 10)
    }

    @Test
    func `Proactive partial patch preserves omitted fields`() throws {
        // Same no-reset contract for the interruption policy: one key never
        // clears the other, and an absent patch never resets the section.
        var config = RuneWeaverConfig.default
        #expect(config.proactive.mode == .all)
        #expect(config.proactive.judgeTimeoutSeconds == 15)

        try UpdateSettingsRequest(proactive: ProactiveUpdate(mode: "guarded")).apply(to: &config)
        #expect(config.proactive.mode == .guarded)
        #expect(config.proactive.judgeTimeoutSeconds == 15)

        try UpdateSettingsRequest(proactive: ProactiveUpdate(judgeTimeoutSeconds: 30)).apply(to: &config)
        #expect(config.proactive.mode == .guarded)
        #expect(config.proactive.judgeTimeoutSeconds == 30)

        try UpdateSettingsRequest().apply(to: &config)
        #expect(config.proactive.mode == .guarded)
        #expect(config.proactive.judgeTimeoutSeconds == 30)
    }

    @Test
    func `Proactive merge rejects unknown mode`() throws {
        // An unknown mode fails with the closed-set validation error instead
        // of persisting a mode the gate could never match.
        var config = RuneWeaverConfig.default
        #expect(throws: ConfigError.self) {
            try UpdateSettingsRequest(proactive: ProactiveUpdate(mode: "sometimes")).apply(to: &config)
        }
        #expect(config.proactive == RuneWeaverConfig.default.proactive)
    }

    @Test
    func `GoalsUpdate decodes and encodes camelCase`() throws {
        let payload = try #require("""
        {"enabled": true, "stepIntervalMinutes": 60, "maxActiveGoals": 5}
        """.data(using: .utf8))
        let decoded = try JSONDecoder().decode(GoalsUpdate.self, from: payload)
        #expect(decoded.enabled == true)
        #expect(decoded.stepIntervalMinutes == 60)
        #expect(decoded.maxActiveGoals == 5)

        let encoded = try JSONEncoder().encode(GoalsUpdate(enabled: true, stepIntervalMinutes: 60, maxActiveGoals: 5))
        let text = try #require(String(data: encoded, encoding: .utf8))
        #expect(text.contains("stepIntervalMinutes"))
        #expect(text.contains("maxActiveGoals"))
        #expect(!text.contains("step_interval_minutes"))
        #expect(!text.contains("max_active_goals"))
    }

    @Test
    func `ProactiveUpdate decodes and encodes camelCase`() throws {
        let payload = try #require("""
        {"mode": "guarded", "judgeTimeoutSeconds": 20}
        """.data(using: .utf8))
        let decoded = try JSONDecoder().decode(ProactiveUpdate.self, from: payload)
        #expect(decoded.mode == "guarded")
        #expect(decoded.judgeTimeoutSeconds == 20)

        let encoded = try JSONEncoder().encode(ProactiveUpdate(mode: "guarded", judgeTimeoutSeconds: 20))
        let text = try #require(String(data: encoded, encoding: .utf8))
        #expect(text.contains("judgeTimeoutSeconds"))
        #expect(!text.contains("judge_timeout_seconds"))
    }
}

@Suite("Goal WS Decode")
struct GoalWSDecodeTests {
    @Test
    func `Snapshot round trips origin session under canonical wire spelling`() throws {
        let id = UUID()
        let origin = UUID()
        let now = Date()
        let snapshot = WSGoalSnapshot(
            id: id,
            title: "Tend herbs",
            statement: "Keep basil alive",
            status: GoalStatus.active.rawValue,
            progress: WSGoalProgress(done: 1, total: 3),
            stepIntervalMinutes: 60,
            nextDueAt: now,
            originSessionID: origin,
            createdAt: now,
            updatedAt: now
        )
        let data = try JSONEncoder().encode(snapshot)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("originSessionId"))
        #expect(!text.contains("originSessionID"))

        let decoded = try JSONDecoder().decode(WSGoalSnapshot.self, from: data)
        #expect(decoded.originSessionID == origin)
        #expect(decoded.id == id)
    }
}

// Rune Weaver Server Tests — Proactive idea REST surface and settings merge.
//
// Purpose: pins the idea HTTP contract without a live network: request
// validation, unknown identifiers, the disabled/capped acceptance guards, the
// plan-adjustment and new-goal effects, the summary tallies, the proactive
// frame kind, and the `[ideas]` settings merge.
// Scope: route status codes, DTO shapes, and settings merge only; durable
// suggestion generation and the nightly cadence stay with the engine and worker
// suites.
// Architectural role: guards the thin adapter so future route edits cannot
// silently widen validation, drift the accept effects, or reset untouched
// settings fields.

import Foundation
import NIOWebSocket
@testable import RuneWeaverCore
@testable import RuneWeaverServer
import Testing
import Vapor

/// Stub provider replaying one canned answer for goal planning turns.
private final class IdeaRouteStubLLM: LLMProvider, Sendable {
    /// Stable test model metadata.
    let modelInfo = ModelInfo(name: "idea-route-fixture", provider: "test", contextLength: 8192)
    /// Canned answer text.
    private let answer: String

    /// Creates a stub.
    init(answer: String = #"[{"title": "Planned step"}]"#) {
        self.answer = answer
    }

    /// Replays the canned answer as a finished stream.
    func chat(messages _: [Message], tools _: [any Tool]) -> AsyncStream<LLMResponse> {
        let text = answer
        return AsyncStream { continuation in
            continuation.yield(LLMResponse(delta: text))
            continuation.yield(LLMResponse(delta: "", isFinished: true, totalTokens: 5))
            continuation.finish()
        }
    }

    /// Unused embeddings stub.
    func embeddings(text _: [String]) async throws -> [[Float]] {
        []
    }
}

/// Builds a configured application sharing an isolated ideas store.
///
/// The context carries explicit goal and idea stores so both postures are
/// observable through the same route surface; the temporary database keeps rows
/// off the real engine data directory.
/// - Parameters:
///   - goalsEnabled: Whether goal pursuit runs for this app.
///   - body: Test body receiving the app plus its context.
/// - Returns: Whatever `body` returns.
private func withIdeaApp<T>(
    goalsEnabled: Bool = true,
    _ body: (Application, ServerContext) async throws -> T
) async throws -> T {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("runeweaver-idea-routes-\(UUID().uuidString)")
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
        let stub = IdeaRouteStubLLM()
        let orchestrator = Orchestrator(
            conversations: conversations,
            toolBus: bus,
            llm: stub,
            memoryEngine: memory
        )
        let goalStore = GoalStore(dbPath: dbPath)
        var goalsConfig = GoalsConfig()
        goalsConfig.enabled = goalsEnabled
        let engine = GoalEngine(store: goalStore, llm: stub, config: goalsConfig)
        let ideaStore = IdeasStore(dbPath: dbPath)
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
            goals: goalStore,
            goalEngine: engine,
            goalsConfig: goalsConfig,
            ideas: ideaStore,
            ideasConfig: IdeasConfig()
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

/// Sends one request through the full registered surface.
/// - Parameters:
///   - app: Configured application.
///   - method: HTTP method.
///   - path: Path plus optional query string.
/// - Returns: Route response.
private func ideaRequest(app: Application, method: HTTPMethod, path: String) async throws -> Response {
    let request = Request(
        application: app,
        method: method,
        url: URI(string: path),
        on: app.eventLoopGroup.next()
    )
    return try await app.responder.respond(to: request).get()
}

/// Seeds one pending idea and returns its snapshot.
@discardableResult
private func seedIdea(
    _ context: ServerContext,
    kind: IdeaKind,
    title: String,
    body: String = "",
    goalID: UUID? = nil,
    status: IdeaStatus = .proposed
) async throws -> Idea {
    let idea = Idea(kind: kind, title: title, body: body, goalID: goalID, status: status)
    _ = try await context.ideas.append(ideas: [idea])
    if status != .proposed {
        _ = try await context.ideas.setStatus(id: idea.id, status: status)
    }
    return idea
}

/// Seeds one active goal with a single pending step.
private func seedActiveGoal(_ context: ServerContext, title: String = "Tend herbs") async throws -> Goal {
    let now = Date()
    let goal = Goal(
        title: title,
        statement: "Keep basil alive",
        status: .active,
        stepIntervalMinutes: 60,
        nextDueAt: now,
        createdAt: now,
        updatedAt: now
    )
    try await context.goals.create(
        goal: goal,
        steps: [GoalStep(goalID: goal.id, ordinal: 0, title: "Original step", status: .pending)]
    )
    return goal
}

@Suite("Idea Route Validation")
struct IdeaRouteValidationTests {
    @Test
    func `Malformed identifier is rejected`() async throws {
        try await withIdeaApp { app, _ in
            let accept = try await ideaRequest(app: app, method: .POST, path: "/ideas/not-a-uuid/accept")
            #expect(accept.status == .badRequest)
            let dismiss = try await ideaRequest(app: app, method: .POST, path: "/ideas/not-a-uuid/dismiss")
            #expect(dismiss.status == .badRequest)
        }
    }

    @Test
    func `Unknown identifier is not found`() async throws {
        try await withIdeaApp { app, _ in
            let missing = UUID().uuidString
            let accept = try await ideaRequest(app: app, method: .POST, path: "/ideas/\(missing)/accept")
            #expect(accept.status == .notFound)
            let dismiss = try await ideaRequest(app: app, method: .POST, path: "/ideas/\(missing)/dismiss")
            #expect(dismiss.status == .notFound)
        }
    }

    @Test
    func `Unknown status filter is rejected`() async throws {
        try await withIdeaApp { app, _ in
            let response = try await ideaRequest(app: app, method: .GET, path: "/ideas?status=nope")
            #expect(response.status == .badRequest)
        }
    }
}

@Suite("Idea Disabled Acceptance")
struct IdeaDisabledTests {
    @Test
    func `New-goal acceptance while disabled answers with the honest message`() async throws {
        try await withIdeaApp(goalsEnabled: false) { app, context in
            let idea = try await seedIdea(context, kind: .newGoal, title: "Start a journal", body: "One page a night.")
            let response = try await ideaRequest(app: app, method: .POST, path: "/ideas/\(idea.id.uuidString)/accept")
            #expect(response.status == .badRequest)
            let body = response.body.string ?? ""
            #expect(body.lowercased().contains("disabled") == true)
            // The refused idea stays proposed so the owner can retry once goals
            // are enabled instead of losing the suggestion to a failed accept.
            let stored = try await context.ideas.list(status: nil, limit: nil)
            #expect(stored.first(where: { $0.id == idea.id })?.status == .proposed)
        }
    }
}

@Suite("Idea Acceptance Effects")
struct IdeaAcceptanceTests {
    @Test
    func `Plan adjustment re-plans the linked active goal`() async throws {
        try await withIdeaApp { app, context in
            let goal = try await seedActiveGoal(context)
            let idea = try await seedIdea(
                context,
                kind: .planAdjustment,
                title: "Shorten the loop",
                body: "Adjusted one\nAdjusted two",
                goalID: goal.id
            )
            let response = try await ideaRequest(app: app, method: .POST, path: "/ideas/\(idea.id.uuidString)/accept")
            #expect(response.status == .ok)
            let decoded = try response.content.decode(IdeaDTO.self)
            #expect(decoded.status == IdeaStatus.accepted.rawValue)
            #expect(decoded.goalID == goal.id)
            // The linked goal's pending plan is replaced by the suggestion's
            // step lines, so the adjustment is observable rather than a no-op.
            let steps = try await context.goals.steps(goalID: goal.id)
            #expect(steps.map(\.title) == ["Adjusted one", "Adjusted two"])
            #expect(steps.allSatisfy { $0.status == .pending })
        }
    }

    @Test
    func `Engine-generated adjustment accepts through the review contract`() async throws {
        try await withIdeaApp { app, context in
            let goal = try await seedActiveGoal(context)
            // The review contract carries the source goal id: the canned reply
            // names the real goal so the generated row links back to it.
            let engine = IdeasEngine(
                store: context.ideas,
                llm: IdeaRouteStubLLM(answer: "[{\"kind\":\"plan_adjustment\",\"title\":\"Shorten the loop\",\"steps\":[\"Adjusted one\"],\"goalId\":\"\(goal.id.uuidString)\"}]"),
                config: IdeasConfig(enabled: true)
            )
            let generated = await engine.generate()
            let idea = try #require(generated.first)
            #expect(idea.goalID == goal.id)

            let response = try await ideaRequest(app: app, method: .POST, path: "/ideas/\(idea.id.uuidString)/accept")
            #expect(response.status == .ok)
            let decoded = try response.content.decode(IdeaDTO.self)
            #expect(decoded.status == IdeaStatus.accepted.rawValue)
            let steps = try await context.goals.steps(goalID: goal.id)
            #expect(steps.map(\.title) == ["Adjusted one"])
        }
    }

    @Test
    func `New-goal acceptance creates the goal through the engine`() async throws {
        try await withIdeaApp { app, context in
            let idea = try await seedIdea(context, kind: .newGoal, title: "Ship the field guide", body: "Publish it.")
            let response = try await ideaRequest(app: app, method: .POST, path: "/ideas/\(idea.id.uuidString)/accept")
            #expect(response.status == .ok)
            let goals = try await context.goals.list(status: nil)
            #expect(goals.contains { $0.title == "Ship the field guide" })
            let decoded = try response.content.decode(IdeaDTO.self)
            #expect(decoded.status == IdeaStatus.accepted.rawValue)
        }
    }

    @Test
    func `Tip acceptance only flips the lifecycle state`() async throws {
        try await withIdeaApp { app, context in
            let idea = try await seedIdea(context, kind: .tip, title: "Hydrate", body: "Drink more water.")
            let response = try await ideaRequest(app: app, method: .POST, path: "/ideas/\(idea.id.uuidString)/accept")
            #expect(response.status == .ok)
            let decoded = try response.content.decode(IdeaDTO.self)
            #expect(decoded.status == IdeaStatus.accepted.rawValue)
        }
    }

    @Test
    func `Dismissal moves the idea out of the proposed set`() async throws {
        try await withIdeaApp { app, context in
            let idea = try await seedIdea(context, kind: .tip, title: "Hydrate")
            let response = try await ideaRequest(app: app, method: .POST, path: "/ideas/\(idea.id.uuidString)/dismiss")
            #expect(response.status == .ok)
            let decoded = try response.content.decode(IdeaDTO.self)
            #expect(decoded.status == IdeaStatus.dismissed.rawValue)
            let proposed = try await context.ideas.list(status: .proposed, limit: nil)
            #expect(!proposed.contains { $0.id == idea.id })
        }
    }

    @Test
    func `Replayed acceptance conflicts instead of applying twice`() async throws {
        try await withIdeaApp { app, context in
            let idea = try await seedIdea(context, kind: .tip, title: "Hydrate", status: .accepted)
            let response = try await ideaRequest(app: app, method: .POST, path: "/ideas/\(idea.id.uuidString)/accept")
            #expect(response.status == .conflict)
        }
    }
}

@Suite("Idea Acceptance Conflicts")
struct IdeaConflictTests {
    @Test
    func `Plan adjustment on a missing or inactive goal conflicts`() async throws {
        try await withIdeaApp { app, context in
            // Missing linked goal.
            let orphan = try await seedIdea(
                context,
                kind: .planAdjustment,
                title: "Orphan adjustment",
                body: "Do this",
                goalID: UUID()
            )
            let orphanResponse = try await ideaRequest(app: app, method: .POST, path: "/ideas/\(orphan.id.uuidString)/accept")
            #expect(orphanResponse.status == .conflict)
            // The failed effect rolls the claimed status back so the owner can
            // retry after re-pointing the idea instead of stranding it accepted.
            #expect(try await context.ideas.idea(id: orphan.id)?.status == .proposed)

            // Inactive linked goal.
            let achieved = try await seedActiveGoal(context, title: "Finished pursuit")
            try await context.goals.setStatus(goalID: achieved.id, status: .achieved)
            let stale = try await seedIdea(
                context,
                kind: .planAdjustment,
                title: "Stale adjustment",
                body: "Do that",
                goalID: achieved.id
            )
            let staleResponse = try await ideaRequest(app: app, method: .POST, path: "/ideas/\(stale.id.uuidString)/accept")
            #expect(staleResponse.status == .conflict)
            #expect((staleResponse.body.string ?? "").lowercased().contains("not active"))

            // Unlinked adjustment.
            let unlinked = try await seedIdea(context, kind: .planAdjustment, title: "No goal", body: "Do neither")
            let unlinkedResponse = try await ideaRequest(app: app, method: .POST, path: "/ideas/\(unlinked.id.uuidString)/accept")
            #expect(unlinkedResponse.status == .conflict)
        }
    }
}

@Suite("Idea Summary And List")
struct IdeaSummaryTests {
    @Test
    func `Summary tallies every lifecycle state`() async throws {
        try await withIdeaApp { app, context in
            try await seedIdea(context, kind: .tip, title: "Proposed one")
            try await seedIdea(context, kind: .tip, title: "Proposed two")
            try await seedIdea(context, kind: .tip, title: "Accepted one", status: .accepted)
            try await seedIdea(context, kind: .tip, title: "Dismissed one", status: .dismissed)
            let response = try await ideaRequest(app: app, method: .GET, path: "/ideas/summary")
            #expect(response.status == .ok)
            let decoded = try response.content.decode(IdeasSummaryResponse.self)
            #expect(decoded.proposed == 2)
            #expect(decoded.accepted == 1)
            #expect(decoded.dismissed == 1)
            #expect(decoded.total == 4)
        }
    }

    @Test
    func `List filters by status`() async throws {
        try await withIdeaApp { app, context in
            try await seedIdea(context, kind: .tip, title: "Keep me")
            try await seedIdea(context, kind: .tip, title: "Hide me", status: .dismissed)
            let response = try await ideaRequest(app: app, method: .GET, path: "/ideas?status=proposed")
            #expect(response.status == .ok)
            let decoded = try response.content.decode(IdeasListResponse.self)
            #expect(decoded.ideas.count == 1)
            #expect(decoded.ideas.first?.title == "Keep me")
        }
    }
}

@Suite("Idea Proactive Frame")
struct IdeaFrameTests {
    @Test
    func `Idea-proposed proactive frame round-trips`() throws {
        let goalID = UUID()
        let frame = WSProactiveMessageFrame(
            kind: WSProactiveMessageFrame.ideaProposedKind,
            title: "Ship the field guide",
            headline: "Publish it next week.",
            goalID: goalID
        )
        let decoded = try JSONDecoder().decode(WSProactiveMessageFrame.self, from: JSONEncoder().encode(frame))
        #expect(decoded == frame)
        #expect(decoded.type == "proactive_message")
        #expect(decoded.kind == "idea_proposed")
        #expect(decoded.goalID == goalID)
    }
}

/// Recording socket capturing hub broadcasts without a live handshake.
private actor IdeaAcceptRecordingSocket: WSConnectionSocket {
    /// Frames delivered to this connection.
    private(set) var sent: [String] = []

    /// Records one frame.
    func send(_ text: String) async throws {
        sent.append(text)
    }

    /// Ignored; these tests never close the connection.
    func close(code _: WebSocketErrorCode) async throws {}
}

@Suite("Idea Acceptance Broadcast")
struct IdeaAcceptBroadcastTests {
    @Test
    func `New-goal acceptance broadcasts the created row`() async throws {
        try await withIdeaApp { app, context in
            let socket = IdeaAcceptRecordingSocket()
            _ = await context.hub.add(id: UUID(), box: socket)
            let idea = try await seedIdea(context, kind: .newGoal, title: "Ship the field guide", body: "Publish it.")
            let response = try await ideaRequest(app: app, method: .POST, path: "/ideas/\(idea.id.uuidString)/accept")
            #expect(response.status == .ok)
            // The accept path pushes the created row for live dashboards the
            // same way the create route does, so other sockets learn the row
            // without refetching; a trailing plan-ready refresh may add a
            // second frame, so the assertion pins presence, not count.
            let frames = await socket.sent
            #expect(!frames.isEmpty)
            let decoded = try frames.map { try JSONDecoder().decode(WSGoalUpdatedFrame.self, from: Data($0.utf8)) }
            #expect(decoded.allSatisfy { $0.type == "goal_updated" })
            #expect(decoded.contains { $0.goal.title == "Ship the field guide" })
        }
    }
}

@Suite("Idea Settings Merge")
struct IdeaSettingsMergeTests {
    @Test
    func `Ideas partial patch preserves omitted fields`() throws {
        var config = RuneWeaverConfig.default
        #expect(config.ideas.enabled == false)
        #expect(config.goals.enabled == false)
        #expect(config.proactive.mode == .all)

        try UpdateSettingsRequest(ideas: IdeasUpdate(enabled: true)).apply(to: &config)
        #expect(config.ideas.enabled == true)
        // Untouched sections keep their stored values exactly.
        #expect(config.goals == RuneWeaverConfig.default.goals)
        #expect(config.proactive == RuneWeaverConfig.default.proactive)

        try UpdateSettingsRequest(goals: GoalsUpdate(enabled: true)).apply(to: &config)
        #expect(config.goals.enabled == true)
        #expect(config.ideas.enabled == true)

        // A request with no ideas patch is a no-op for the section.
        try UpdateSettingsRequest().apply(to: &config)
        #expect(config.ideas.enabled == true)
        #expect(config.goals.enabled == true)
    }

    @Test
    func `IdeasUpdate snapshot round-trips through the merge`() throws {
        var config = RuneWeaverConfig.default
        var ideas = IdeasConfig()
        ideas.enabled = true
        try UpdateSettingsRequest(ideas: IdeasUpdate(ideas)).apply(to: &config)
        #expect(config.ideas == ideas)
        // The per-cycle policy fields survive the enable-only dashboard patch.
        #expect(config.ideas.maxPerCycle == ideas.maxPerCycle)
        #expect(config.ideas.timeoutSeconds == ideas.timeoutSeconds)
    }
}

@Suite("Idea Wire Contract")
struct IdeaWireContractTests {
    @Test
    func `Blank wire titles fail decoding fail-closed`() throws {
        let id = UUID()
        let now = Date()
        // A whitespace-only title would persist as an empty dedup key and then
        // vanish through dashboard filters, so the wire rejects it instead of
        // letting counts and lists drift.
        let payload: [String: Any] = [
            "id": id.uuidString,
            "kind": "tip",
            "title": "   ",
            "body": "",
            "status": "proposed",
            "createdAt": now.timeIntervalSince1970,
            "updatedAt": now.timeIntervalSince1970
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        do {
            _ = try JSONDecoder().decode(IdeaDTO.self, from: data)
            Issue.record("Expected a blank wire title to fail decoding")
        } catch is DecodingError {
            // Expected: fail-closed on blank titles.
        }
    }

    @Test
    func `Valid wire titles decode across goal spellings`() throws {
        let id = UUID()
        let goalID = UUID()
        let now = Date()
        let payload: [String: Any] = [
            "id": id.uuidString,
            "kind": "tip",
            "title": "Hydrate",
            "body": "",
            "goal_id": goalID.uuidString,
            "status": "proposed",
            "createdAt": now.timeIntervalSince1970,
            "updatedAt": now.timeIntervalSince1970
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let decoded = try JSONDecoder().decode(IdeaDTO.self, from: data)
        #expect(decoded.title == "Hydrate")
        #expect(decoded.goalID == goalID)
    }
}

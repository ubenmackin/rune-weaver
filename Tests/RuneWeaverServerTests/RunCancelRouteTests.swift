// Rune Weaver Server Tests — Fan-out run cancellation route.

import Foundation
import os
@testable import RuneWeaverCore
@testable import RuneWeaverServer
import Testing
import Vapor

/// Stub provider satisfying orchestrator construction; these tests never run a
/// chat turn, so it only needs stable metadata and a finished stream.
private final class RunCancelStubLLM: LLMProvider, Sendable {
    /// Stable test model metadata.
    let modelInfo = ModelInfo(name: "run-cancel-fixture", provider: "test", contextLength: 2048)

    /// Returns an immediately finished empty stream.
    func chat(messages _: [Message], tools _: [any Tool]) -> AsyncStream<LLMResponse> {
        AsyncStream { $0.finish() }
    }

    /// Unused embeddings stub.
    func embeddings(text _: [String]) async throws -> [[Float]] {
        []
    }
}

/// Cancellable orchestrator seam: each worker turn counts itself in flight and parks until
/// cancelled (or its hold elapses), so a route cancel is observable end to end while a held swarm
/// stays live for the test to stop.
private final class HeldFanOutSeam: OrchestratorFanOutSeam, Sendable {
    /// Guarded in-flight count.
    private struct State: Sendable {
        /// Turns currently in flight.
        var inFlight = 0
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())
    /// How long a turn parks before producing output. A long hold keeps the
    /// swarm live until the test cancels it; zero lets a swarm settle
    /// immediately so a test can cancel an already-finished row.
    private let holdSeconds: Double

    /// Creates a held seam.
    /// - Parameter holdSeconds: Park budget per worker turn; zero completes
    ///   immediately.
    init(holdSeconds: Double = 30) {
        self.holdSeconds = holdSeconds
    }

    /// Number of turns currently in flight.
    var inFlight: Int {
        state.withLock { $0.inFlight }
    }

    /// Runs one worker turn, discarding its output.
    func process(_ input: UserInput) async throws {
        _ = try await processCollecting(input)
    }

    /// Runs one worker turn: counts itself in flight, parks, then returns real output.
    func processCollecting(_ input: UserInput) async throws -> FanOutWorkerOutput {
        state.withLock { $0.inFlight += 1 }
        defer { state.withLock { $0.inFlight -= 1 } }
        if holdSeconds > 0 {
            try await Task.sleep(nanoseconds: UInt64(holdSeconds * 1_000_000_000))
        }
        return FanOutWorkerOutput(text: "Output for \(input.text)", isParked: false)
    }
}

/// Live collaborators for one cancellation-route scenario.
private struct RunCancelHarness {
    /// Configured application under test.
    let app: Application
    /// Shared engine context serving the routes.
    let context: ServerContext
    /// Run-log store the fan-out engine records through.
    let runs: RunLogStore
    /// Fan-out engine whose live registry backs the cancel route.
    let engine: FanOutEngine
    /// Orchestrator seam driving worker turns.
    let orchestrator: HeldFanOutSeam
}

/// Builds a configured application over an isolated run log and a fan-out engine driven by the
/// blocking seam. The temporary database keeps rows off the real engine data directory.
private func withRunCancelApp<T>(
    orchestrator: HeldFanOutSeam = HeldFanOutSeam(),
    fanOutConfig: FanOutConfig = FanOutConfig(),
    _ body: (RunCancelHarness) async throws -> T
) async throws -> T {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("runeweaver-run-cancel-\(UUID().uuidString)")
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
        let orchestratorInstance = Orchestrator(
            conversations: conversations,
            toolBus: bus,
            llm: RunCancelStubLLM(),
            memoryEngine: memory
        )
        // The route reads liveness from the engine, not the row, so the run store must be the same
        // instance the engine records through and both must ride the context under test.
        let runs = RunLogStore()
        let hub = WSHub()
        let engine = FanOutEngine(
            orchestrator: orchestrator,
            runLogs: FanOutRunLogAdapter(runs: runs, hub: hub),
            config: fanOutConfig
        )
        let context = ServerContext(
            conversations: conversations,
            toolBus: bus,
            orchestrator: orchestratorInstance,
            memoryEngine: memory,
            permissionGate: gate,
            approvals: approvals,
            scheduler: SchedulerStore(),
            runs: runs,
            hub: hub,
            pluginStore: ToolRegistryStore(dbPath: dbPath),
            toolStates: ToolStateStore(dbPath: dbPath),
            stagedFiles: StagedFilesStore(dbPath: dbPath),
            fanOut: engine,
            fanOutConfig: fanOutConfig
        )
        try configureRuneWeaver(app, context: context)
        let harness = RunCancelHarness(app: app, context: context, runs: runs, engine: engine, orchestrator: orchestrator)
        let value = try await body(harness)
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
private func runCancelRequest(app: Application, method: HTTPMethod, path: String) async throws -> Response {
    let request = Request(
        application: app,
        method: method,
        url: URI(string: path),
        on: app.eventLoopGroup.next()
    )
    return try await app.responder.respond(to: request).get()
}

/// Polls a condition until it holds or the deadline passes, so tests order themselves against live
/// worker state instead of racing fixed sleeps.
private func waitUntil(
    timeoutSeconds: Double = 5,
    _ condition: @escaping @Sendable () async -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if await condition() {
            return
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

/// Reads the refusal reason so a test can assert the honest message rather
/// than only the status code.
private func refusalReason(_ response: Response) -> String {
    response.body.string ?? ""
}

@Suite("Run Cancel Route")
struct RunCancelRouteTests {
    @Test
    func `Worker row cancel answers worker scope and settles its rows cancelled`() async throws {
        try await withRunCancelApp { harness in
            let engine = harness.engine
            let orchestrator = harness.orchestrator
            let runTask = Task {
                try await engine.runFanOut(
                    subtasks: [FanOutSubtask(title: "Solo", prompt: "Prompt for Solo")],
                    originSessionID: UUID()
                )
            }

            await waitUntil { orchestrator.inFlight == 1 }
            let childRow = try #require(await harness.runs.list(kind: FanOutEngine.workerRowKind).first)
            let response = try await runCancelRequest(
                app: harness.app,
                method: .POST,
                path: "/runs/\(childRow.id.uuidString)/cancel"
            )
            #expect(response.status == .ok)
            let body = try response.content.decode(RunCancelResponse.self)
            #expect(body.cancelled == true)
            #expect(body.scope == "worker")
            // A worker stop reports no swarm count; only a parent cancel does.
            #expect(body.workerCount == nil)

            // The accepted stop is a real settle, not just a status code: the
            // child row and its parent flip to the cancelled vocabulary the
            // Runs tab renders.
            let run = try await runTask.value
            #expect(run.status == .cancelled)
            #expect(await harness.runs.entry(id: childRow.id)?.status == "cancelled")
            let parentRow = try #require(await harness.runs.list(kind: FanOutEngine.parentRowKind).first)
            #expect(await harness.runs.entry(id: parentRow.id)?.status == "cancelled")
        }
    }

    @Test
    func `Parent row cancel answers run scope with worker count and stops the swarm`() async throws {
        try await withRunCancelApp { harness in
            let engine = harness.engine
            let orchestrator = harness.orchestrator
            let runTask = Task {
                try await engine.runFanOut(
                    subtasks: [
                        FanOutSubtask(title: "A", prompt: "Prompt for A"),
                        FanOutSubtask(title: "B", prompt: "Prompt for B")
                    ],
                    originSessionID: UUID()
                )
            }

            await waitUntil { orchestrator.inFlight == 2 }
            let parentRow = try #require(await harness.runs.list(kind: FanOutEngine.parentRowKind).first)
            let response = try await runCancelRequest(
                app: harness.app,
                method: .POST,
                path: "/runs/\(parentRow.id.uuidString)/cancel"
            )
            #expect(response.status == .ok)
            let body = try response.content.decode(RunCancelResponse.self)
            #expect(body.cancelled == true)
            #expect(body.scope == "run")
            #expect(body.workerCount == 2)

            // The swarm settles as a deliberate stop, and every row it wrote
            // carries that outcome beside its siblings.
            let run = try await runTask.value
            #expect(run.status == .cancelled)
            let rows = await harness.runs.list(limit: 10)
            #expect(rows.count == 3)
            #expect(rows.allSatisfy { $0.status == "cancelled" })
            #expect(await harness.runs.entry(id: parentRow.id)?.status == "cancelled")
        }
    }

    @Test
    func `Active non fan-out rows cancel cleanly and update run status`() async throws {
        try await withRunCancelApp { harness in
            let sessionID = UUID()
            let cancelledBox = OSAllocatedUnfairLock<Bool>(initialState: false)
            await harness.context.activeTurns.register(sessionID: sessionID) {
                cancelledBox.withLock { $0 = true }
            }

            for kind in ["scheduler", "goal", "index", "chat"] {
                let row = await harness.runs.append(
                    kind: kind,
                    status: "running",
                    message: "\(kind) work",
                    sessionID: kind == "goal" ? sessionID : nil
                )
                let response = try await runCancelRequest(
                    app: harness.app,
                    method: .POST,
                    path: "/runs/\(row.id.uuidString)/cancel"
                )
                #expect(response.status == .ok)
                let body = try response.content.decode(RunCancelResponse.self)
                #expect(body.cancelled == true)
                #expect(body.scope == "run")
                #expect(await harness.runs.entry(id: row.id)?.status == "cancelled")
            }

            #expect(cancelledBox.withLock { $0 } == true)
            #expect(await harness.context.activeTurns.isActive(sessionID: sessionID) == false)
        }
    }

    @Test
    func `Settled non fan-out rows answer conflict and stay untouched`() async throws {
        try await withRunCancelApp { harness in
            for kind in ["scheduler", "goal", "index"] {
                let row = await harness.runs.append(kind: kind, status: "ok", message: "\(kind) work")
                let response = try await runCancelRequest(
                    app: harness.app,
                    method: .POST,
                    path: "/runs/\(row.id.uuidString)/cancel"
                )
                #expect(response.status == .conflict)
                #expect(refusalReason(response).contains("Nothing running"))
                #expect(await harness.runs.entry(id: row.id)?.status == "ok")
            }
        }
    }

    @Test
    func `Awaiting approval rows cancel cleanly like running rows`() async throws {
        try await withRunCancelApp { harness in
            let sessionID = UUID()
            let cancelledBox = OSAllocatedUnfairLock<Bool>(initialState: false)
            await harness.context.activeTurns.register(sessionID: sessionID) {
                cancelledBox.withLock { $0 = true }
            }
            let row = await harness.runs.append(
                kind: "goal",
                status: "awaiting_approval",
                message: "parked work",
                sessionID: sessionID
            )
            let response = try await runCancelRequest(
                app: harness.app,
                method: .POST,
                path: "/runs/\(row.id.uuidString)/cancel"
            )
            #expect(response.status == .ok)
            let body = try response.content.decode(RunCancelResponse.self)
            #expect(body.cancelled == true)
            #expect(body.scope == "run")
            #expect(await harness.runs.entry(id: row.id)?.status == "cancelled")
            #expect(cancelledBox.withLock { $0 } == true)
        }
    }

    @Test
    func `Cancelled rows resist late success overwrite and reject recancel`() async throws {
        try await withRunCancelApp { harness in
            let row = await harness.runs.append(kind: "chat", status: "running", message: "live work")
            let settled = await harness.runs.cancel(id: row.id, durationMs: 7)
            #expect(settled?.status == "cancelled")
            // A late success racing the cancel keeps the owner's stop.
            let raced = await harness.runs.update(id: row.id, status: "ok", response: "late")
            #expect(raced?.status == "cancelled")
            #expect(await harness.runs.entry(id: row.id)?.status == "cancelled")
            // A second stop answers conflict through the atomic guard.
            let response = try await runCancelRequest(
                app: harness.app,
                method: .POST,
                path: "/runs/\(row.id.uuidString)/cancel"
            )
            #expect(response.status == .conflict)
            #expect(await harness.runs.entry(id: row.id)?.status == "cancelled")
        }
    }

    @Test
    func `Unknown row cancel answers not found and malformed identifiers are rejected`() async throws {
        try await withRunCancelApp { harness in
            let missing = UUID().uuidString
            let response = try await runCancelRequest(
                app: harness.app,
                method: .POST,
                path: "/runs/\(missing)/cancel"
            )
            #expect(response.status == .notFound)

            let malformed = try await runCancelRequest(
                app: harness.app,
                method: .POST,
                path: "/runs/not-a-uuid/cancel"
            )
            #expect(malformed.status == .badRequest)
        }
    }

    @Test
    func `Settled fan-out row cancel answers conflict`() async throws {
        // A zero hold lets the swarm settle before the cancel arrives, which
        // is the late-stop posture: the engine deregisters with the run, so a
        // settled row must never accept another stop.
        try await withRunCancelApp(orchestrator: HeldFanOutSeam(holdSeconds: 0)) { harness in
            let run = try await harness.engine.runFanOut(
                subtasks: [FanOutSubtask(title: "Quick", prompt: "Prompt for Quick")],
                originSessionID: UUID()
            )
            #expect(run.status == .completed)
            let parentRow = try #require(await harness.runs.list(kind: FanOutEngine.parentRowKind).first)
            #expect(await harness.runs.entry(id: parentRow.id)?.status == "ok")

            let childRow = try #require(await harness.runs.list(kind: FanOutEngine.workerRowKind).first)
            let parentResponse = try await runCancelRequest(
                app: harness.app,
                method: .POST,
                path: "/runs/\(parentRow.id.uuidString)/cancel"
            )
            #expect(parentResponse.status == .conflict)
            #expect(refusalReason(parentResponse).contains("Nothing running"))

            let childResponse = try await runCancelRequest(
                app: harness.app,
                method: .POST,
                path: "/runs/\(childRow.id.uuidString)/cancel"
            )
            #expect(childResponse.status == .conflict)

            // The late refusals leave the settled outcomes exactly as they were.
            #expect(await harness.runs.entry(id: parentRow.id)?.status == "ok")
            #expect(await harness.runs.entry(id: childRow.id)?.status == "ok")
        }
    }

    @Test
    func `settleTurnCancelled persists partial response and tool actions to run log and conversations`() async throws {
        try await withRunCancelApp { harness in
            let sessionID = UUID()
            let token = UUID()
            let initialEntry = RunLogEntry(
                id: UUID(),
                sessionID: sessionID,
                kind: "chat",
                status: "running",
                message: "Search for shoes"
            )
            await harness.runs.append(initialEntry)
            let audit = ChatTurnAuditSnapshot(
                partialText: "I found several options for you.",
                partialReasoning: "Looking up running shoes",
                toolActions: [
                    ToolAction(
                        toolName: "browser.navigate",
                        callID: "call-1",
                        argumentsJSON: "{\"url\":\"https://example.com\"}",
                        result: ToolResult(toolCallID: "call-1", content: "ok", isError: false)
                    )
                ],
                totalTokens: 1500
            )

            await settleTurnCancelled(
                context: harness.context,
                sessionID: sessionID,
                token: token,
                entry: initialEntry,
                startTime: Date().addingTimeInterval(-2),
                audit: audit
            )

            let settledRun = await harness.runs.entry(id: initialEntry.id)
            #expect(settledRun?.status == "cancelled")
            #expect(settledRun?.response == "I found several options for you.\n\n*(Turn cancelled by user)*")
            #expect(settledRun?.toolActions.count == 1)
            #expect(settledRun?.totalTokens == 1500)

            let session = await harness.context.conversations.session(id: sessionID)
            let lastMessage = session?.messages.last
            #expect(lastMessage?.role == .assistant)
            #expect(lastMessage?.content == "I found several options for you.\n\n*(Turn cancelled by user)*")
            #expect(lastMessage?.reasoning == "Looking up running shoes")
        }
    }
}

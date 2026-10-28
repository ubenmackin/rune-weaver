// Rune Weaver Tests — Run-row broadcast contract for direct tool calls and skipped scheduler runs.

import Foundation
import NIOWebSocket
import RuneWeaverCore
@testable import RuneWeaverServer
import Testing
import Vapor

/// Recording socket capturing hub frames without a live handshake, so run
/// broadcasts are directly observable after the request settles.
private actor RunRecordingSocket: WSConnectionSocket {
    /// Text frames delivered to this connection, in send order.
    private(set) var sent: [String] = []

    /// Records one frame.
    func send(_ text: String) async throws {
        sent.append(text)
    }

    /// Ignored; these tests never close the connection.
    func close(code _: WebSocketErrorCode) async throws {}
}

/// Decoded run-event envelope shared by every run broadcast path.
private struct RecordedRunEvent: Decodable {
    /// `"run_started"` for a live row, `"run_completed"` otherwise.
    let type: String
    /// The appended or updated run row.
    let run: RunLogEntry
}

/// Always-succeeding read-only stub so the direct tool-call route executes
/// without filing an approval.
private struct RunRoutesStubTool: Tool, Sendable {
    let name = "stub.echo"
    let description = "Echoes a canned result for run-route tests."
    let inputSchema = JSONSchema(rawValue: #"{"type":"object"}"#)
    let permissionLevel = PermissionLevel.readOnly

    func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        .success("echo-ok", callID: input.callID)
    }
}

/// Stub provider satisfying orchestrator construction; these tests never run a
/// chat turn, so it only needs stable metadata and a finished stream.
private final class RunRoutesStubLLM: LLMProvider, Sendable {
    /// Stable test model metadata.
    let modelInfo = ModelInfo(name: "run-routes-fixture", provider: "test", contextLength: 2048)

    /// Returns an immediately finished empty stream.
    func chat(messages _: [Message], tools _: [any Tool]) -> AsyncStream<LLMResponse> {
        AsyncStream { $0.finish() }
    }

    /// Unused embeddings stub.
    func embeddings(text _: [String]) async throws -> [[Float]] {
        []
    }
}

/// Builds an isolated context whose run store and hub are the same instances
/// the routes read and broadcast through, with a fresh temporary memory tree.
private func makeRunRoutesContext() throws -> ServerContext {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("runeweaver-run-routes-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let conversations = ConversationManager()
    let gate = PermissionGate()
    let approvals = ApprovalQueue(permissionGate: gate)
    let bus = ToolBus(permissionGate: gate)
    let memory = MemoryEngine(
        episodesDBPath: base.appendingPathComponent("episodes.db").path,
        vectorDBPath: base.appendingPathComponent("vectors").path,
        profilePath: base.appendingPathComponent("profile.json").path
    )
    let orchestrator = Orchestrator(
        conversations: conversations,
        toolBus: bus,
        llm: RunRoutesStubLLM(),
        memoryEngine: memory
    )
    return ServerContext(
        conversations: conversations,
        toolBus: bus,
        orchestrator: orchestrator,
        memoryEngine: memory,
        permissionGate: gate,
        approvals: approvals
    )
}

/// Serves the engine routes over the isolated context, shutting the app down
/// on every exit path.
private func withRunRoutesApp<T>(
    context: ServerContext,
    _ body: (Application) async throws -> T
) async throws -> T {
    let app = try await Application.make(.testing)
    do {
        app.runeWeaver = context
        registerRuneWeaverRoutes(app)
        let value = try await body(app)
        try await app.asyncShutdown()
        return value
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
}

/// Sends one request through the full registered surface.
private func sendRunRoutesRequest(
    _ app: Application,
    method: HTTPMethod,
    path: String
) async throws -> Response {
    let request = Request(
        application: app,
        method: method,
        url: URI(string: path),
        on: app.eventLoopGroup.next()
    )
    return try await app.responder.respond(to: request).get()
}

/// Decodes the run-event frames a socket received, in send order.
private func recordedRunEvents(from socket: RunRecordingSocket) async -> [RecordedRunEvent] {
    let frames = await socket.sent
    return frames.map { raw -> RecordedRunEvent? in
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RecordedRunEvent.self, from: data)
    }.compactMap(\.self)
}

@Suite("Server Run Routes Broadcast")
struct ServerRunRoutesTests {
    @Test
    func `Direct tool call appends and broadcasts the tool run row`() async throws {
        let context = try makeRunRoutesContext()
        await context.toolBus.register(tool: RunRoutesStubTool())
        let socket = RunRecordingSocket()
        _ = await context.hub.add(id: UUID(), box: socket)

        try await withRunRoutesApp(context: context) { app in
            let request = Request(
                application: app,
                method: .POST,
                url: URI(string: "/tools/call"),
                on: app.eventLoopGroup.next()
            )
            try request.content.encode(ToolCallRequest(toolName: "stub.echo", argumentsJSON: "{}"))
            let response = try await app.responder.respond(to: request).get()
            #expect(response.status == .ok)
            let result = try response.content.decode(ToolResult.self)
            #expect(result.isError == false)
        }

        // The row landed in the audit trail with the tool outcome attached.
        let rows = await context.runs.list(kind: "tool")
        try #require(rows.count == 1)
        #expect(rows[0].status == "ok")
        #expect(rows[0].toolActions.first?.toolName == "stub.echo")
        // The row reached the connected dashboard immediately instead of
        // waiting for the next run-history poll.
        let events = await recordedRunEvents(from: socket)
        try #require(events.count == 1)
        #expect(events[0].type == "run_completed")
        #expect(events[0].run.id == rows[0].id)
        #expect(events[0].run.kind == "tool")
        #expect(events[0].run.status == "ok")
    }

    @Test
    func `Manual run against a held lock broadcasts the skipped row`() async throws {
        let context = try makeRunRoutesContext()
        let socket = RunRecordingSocket()
        _ = await context.hub.add(id: UUID(), box: socket)
        let job = try await context.scheduler.create(
            NewSchedulerJob(name: "held job", schedule: "0 8 * * *", prompt: "Summarize mail")
        )
        // Simulate the in-flight tick that holds the single-flight lock, so the
        // manual fire must refuse.
        #expect(await context.runLock.tryAcquire(id: job.id, name: job.name) == true)

        try await withRunRoutesApp(context: context) { app in
            let response = try await sendRunRoutesRequest(
                app,
                method: .POST,
                path: "/scheduler/jobs/\(job.id.uuidString)/run"
            )
            #expect(response.status == .conflict)
        }

        // The skip row landed untagged, exactly like the refused request path.
        let rows = await context.runs.list(jobID: job.id)
        try #require(rows.count == 1)
        #expect(rows[0].kind == "scheduler")
        #expect(rows[0].status == "skipped")
        #expect(rows[0].sessionID == nil)
        // The refusal still broadcasts, so dashboards see the skip without a poll.
        let events = await recordedRunEvents(from: socket)
        try #require(events.count == 1)
        #expect(events[0].type == "run_completed")
        #expect(events[0].run.id == rows[0].id)
        #expect(events[0].run.status == "skipped")
        #expect(events[0].run.jobID == job.id)
        await context.runLock.release(id: job.id, name: job.name)
    }
}

// Rune Weaver Server Tests — Per-tool cancel classification, route, and socket.

import Foundation
import NIOWebSocket
@testable import RuneWeaverCore
@testable import RuneWeaverServer
import Testing
import Vapor

/// Test double for the hub socket backing a WebSocket tool cancel, recording the
/// frames the handler emits without a live network handshake so the miss and
/// rejection acknowledgements are directly observable.
private actor CancelRecordingSocket: WSConnectionSocket {
    /// Text frames the handler delivered to this connection.
    private(set) var sent: [String] = []

    /// Records one text frame.
    func send(_ text: String) async throws {
        sent.append(text)
    }

    /// Ignored; the cancel path never closes the connection.
    func close(code _: WebSocketErrorCode) async throws {}
}

/// Fan-in gate letting a test suspend until a blocked call has started.
private actor CallStartGate {
    /// One parked waiter and the start count it is waiting for.
    private struct Waiter: Sendable {
        /// Number of starts that satisfies this waiter.
        let target: Int
        /// Continuation resumed once the target is reached.
        let continuation: CheckedContinuation<Void, Never>
    }

    private var started = 0
    private var waiters: [Waiter] = []

    /// Records one tool call reaching its blocking point.
    func markStarted() {
        started += 1
        let ready = waiters.filter { $0.target <= started }
        waiters.removeAll { $0.target <= started }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }

    /// Suspends until at least `target` calls have started.
    /// - Parameter target: Number of starts to wait for.
    func waitForStarts(_ target: Int) async {
        guard started < target else { return }
        await withCheckedContinuation { continuation in
            waiters.append(Waiter(target: target, continuation: continuation))
        }
    }
}

/// Parks inside `execute` until cooperative cancellation so the route always
/// cancels a live call rather than racing a tool that finished first.
private struct BlockingStubTool: Tool, Sendable {
    /// Registered tool name.
    let name: String
    /// Gate notified once the call is blocked and therefore cancellable.
    let started: CallStartGate
    /// Read-only so no approval handler is needed.
    let permissionLevel = PermissionLevel.readOnly
    /// Empty-object schema.
    let inputSchema = JSONSchema(rawValue: #"{"type":"object"}"#)

    /// Human-readable description.
    var description: String {
        "Blocks until cancelled."
    }

    /// Signals that the call is live, then sleeps until the bus cancels the task.
    func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        await started.markStarted()
        try await Task.sleep(nanoseconds: 5_000_000_000)
        return .success("finished", callID: input.callID)
    }
}

/// Minimal provider so the route test can build a `ServerContext` without network.
private struct ToolCancelStubProvider: LLMProvider, Sendable {
    /// Canned model metadata.
    let modelInfo = ModelInfo(name: "tool-cancel-stub", provider: "stub", contextLength: 2048)

    /// Serves an immediately-finished empty turn; never exercised by these tests.
    func chat(messages _: [Message], tools _: [any Tool]) -> AsyncStream<LLMResponse> {
        AsyncStream { $0.finish() }
    }

    /// Unused embeddings stub.
    func embeddings(text _: [String]) async throws -> [[Float]] {
        []
    }
}

/// Builds a configured application plus an isolated context sharing `bus`.
private func withToolCancelApp<T>(bus: ToolBus, _ body: (Application) async throws -> T) async throws -> T {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("runeweaver-tool-cancel-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let app = try await Application.make(.testing)
    do {
        let dbPath = base.appendingPathComponent("episodes.db").path
        let conversations = ConversationManager()
        let gate = PermissionGate()
        let approvals = ApprovalQueue(permissionGate: gate)
        let memory = MemoryEngine(
            episodesDBPath: dbPath,
            vectorDBPath: base.appendingPathComponent("vectors").path,
            profilePath: base.appendingPathComponent("profile.json").path
        )
        let orchestrator = Orchestrator(
            conversations: conversations,
            toolBus: bus,
            llm: ToolCancelStubProvider(),
            memoryEngine: memory
        )
        let context = ServerContext(
            conversations: conversations,
            toolBus: bus,
            orchestrator: orchestrator,
            memoryEngine: memory,
            permissionGate: gate,
            approvals: approvals,
            pluginStore: ToolRegistryStore(dbPath: dbPath),
            toolStates: ToolStateStore(dbPath: dbPath)
        )
        try configureRuneWeaver(app, context: context)
        let value = try await body(app)
        try await app.asyncShutdown()
        try? FileManager.default.removeItem(at: base)
        return value
    } catch {
        try? await app.asyncShutdown()
        try? FileManager.default.removeItem(at: base)
        throw error
    }
}

/// POSTs one per-tool cancel payload through the full registered surface. app:
/// Configured application.
private func postToolCancel(app: Application, body: ToolCancelRequest) async throws -> Response {
    let request = Request(
        application: app,
        method: .POST,
        url: URI(string: "/chat/tool_cancel"),
        on: app.eventLoopGroup.next()
    )
    try request.content.encode(body)
    return try await app.responder.respond(to: request).get()
}

@Suite("Tool Cancel")
struct ToolCancelTests {
    @Test
    func `Well-formed tool cancel frames classify with their scope and reason`() throws {
        let sessionID = UUID()
        let frame = WSToolCancelMessage(sessionID: sessionID, callID: "call_1", reason: "user stopped it")
        let encoded = try String(data: JSONEncoder().encode(frame), encoding: .utf8) ?? ""
        guard case let .toolCancel(message) = WSInboundKind.classify(encoded) else {
            Issue.record("Expected toolCancel kind")
            return
        }
        #expect(message.sessionID == sessionID)
        #expect(message.callID == "call_1")
        #expect(message.reason == "user stopped it")
    }

    @Test
    func `Tool cancel frames without a reason still classify`() {
        let sessionID = UUID().uuidString
        let text = "{\"type\":\"tool_cancel\",\"sessionID\":\"\(sessionID)\",\"callID\":\"call_2\"}"
        guard case let .toolCancel(message) = WSInboundKind.classify(text) else {
            Issue.record("Expected toolCancel kind")
            return
        }
        #expect(message.callID == "call_2")
        #expect(message.reason == nil)
    }

    @Test
    func `Malformed and blank-identifier tool cancel frames degrade to unknown`() {
        let sessionID = UUID().uuidString
        // A missing required identifier cannot be scoped to a call, so the frame
        // is dropped rather than risking an abort against an unrelated call.
        #expect(WSInboundKind.classify("{\"type\":\"tool_cancel\",\"sessionID\":\"\(sessionID)\"}") == .unknown)
        // A null (blank) identifier satisfies the discriminator but not the
        // required string, so decoding fails closed to unknown.
        #expect(WSInboundKind.classify("{\"type\":\"tool_cancel\",\"sessionID\":\"\(sessionID)\",\"callID\":null}") == .unknown)
        // A non-string identifier is equally unusable.
        #expect(WSInboundKind.classify("{\"type\":\"tool_cancel\",\"sessionID\":\"\(sessionID)\",\"callID\":42}") == .unknown)
        // A missing session scope cannot prove ownership, so it stays unknown.
        #expect(WSInboundKind.classify("{\"type\":\"tool_cancel\",\"callID\":\"call_1\"}") == .unknown)
        // A bare discriminator carries no call at all.
        #expect(WSInboundKind.classify("{\"type\":\"tool_cancel\"}") == .unknown)
        // Truncated JSON never decodes.
        #expect(WSInboundKind.classify("{\"type\":\"tool_cancel\",\"callID\":\"call_1\"") == .unknown)
    }

    @Test
    func `Whitespace identifier classifies structurally and is rejected at the cancel boundary`() {
        let sessionID = UUID().uuidString
        // Classification is structural: a whitespace-only string is still a valid String, so it
        // reaches `.toolCancel`.
        let blank = "{\"type\":\"tool_cancel\",\"sessionID\":\"\(sessionID)\",\"callID\":\"   \"}"
        guard case let .toolCancel(message) = WSInboundKind.classify(blank) else {
            Issue.record("Expected structural toolCancel classification")
            return
        }
        #expect(message.callID == "   ")
    }

    @Test
    func `Route cancels a running call and reports the scoped success`() async throws {
        let bus = ToolBus()
        let started = CallStartGate()
        await bus.register(tool: BlockingStubTool(name: "stub.block", started: started))
        let sessionID = UUID()
        let callID = "call_route"

        try await withToolCancelApp(bus: bus) { app in
            // Start the call only after the route surface is live so the cancel
            // follows the start with no setup work in between.
            let running = Task {
                await bus.execute(
                    toolCall: ToolInput(toolName: "stub.block", argumentsJSON: "{}", callID: callID),
                    context: ToolContext(conversationID: sessionID)
                )
            }
            await started.waitForStarts(1)

            let response = try await postToolCancel(
                app: app,
                body: ToolCancelRequest(sessionID: sessionID, callID: callID, reason: "stop the tool")
            )
            #expect(response.status == .ok)
            let decoded = try response.content.decode(ToolCancelResponse.self)
            #expect(decoded.sessionID == sessionID)
            #expect(decoded.callID == callID)
            #expect(decoded.cancelled == true)

            // The turn receives the injected cancellation rather than hanging.
            let result = await running.value
            #expect(result.isError == true)
            #expect(result.content.contains("cancelled by user"))
        }
    }

    @Test
    func `Route rejects a blank call identifier with 400`() async throws {
        let bus = ToolBus()
        try await withToolCancelApp(bus: bus) { app in
            let response = try await postToolCancel(
                app: app,
                body: ToolCancelRequest(sessionID: UUID(), callID: "   ")
            )
            // A blank identifier must never degrade into a scan for any running
            // call, so the route fails the request before the bus is consulted.
            #expect(response.status == .badRequest)
        }
    }

    @Test
    func `Route reports a miss without erroring or pretending success`() async throws {
        let bus = ToolBus()
        let sessionID = UUID()
        try await withToolCancelApp(bus: bus) { app in
            let response = try await postToolCancel(
                app: app,
                body: ToolCancelRequest(sessionID: sessionID, callID: "never-running")
            )
            #expect(response.status == .ok)
            let decoded = try response.content.decode(ToolCancelResponse.self)
            #expect(decoded.sessionID == sessionID)
            #expect(decoded.callID == "never-running")
            #expect(decoded.cancelled == false)
        }
    }

    @Test
    func `WebSocket tool cancel reports a miss without pretending success`() async throws {
        let bus = ToolBus()
        let sessionID = UUID()
        try await withToolCancelApp(bus: bus) { app in
            let context = app.runeWeaver
            let connectionID = UUID()
            let socket = CancelRecordingSocket()
            _ = await context.hub.add(id: connectionID, box: socket)

            await handleWebSocketToolCancel(
                WSToolCancelMessage(sessionID: sessionID, callID: "never-running"),
                connectionID: connectionID,
                context: context
            )

            // A miss is reported honestly so the dashboard can roll back its optimistic
            // "cancelling" mark, but through the dedicated non-terminal frame: a session-tagged
            // `error` would make the dashboard tear down a turn that is still running.
            let frames = await socket.sent
            #expect(frames.count == 1)
            let raw = try #require(frames.first)
            let frame = try JSONDecoder().decode(WSToolCancelMissFrame.self, from: Data(raw.utf8))
            #expect(frame.type == "tool_cancel_miss")
            #expect(frame.callID == "never-running")
            #expect(frame.message?.contains("No in-flight tool call 'never-running'") == true)
            #expect(frame.sessionID == sessionID)
        }
    }

    @Test
    func `WebSocket tool cancel rejects a blank identifier before touching the bus`() async throws {
        let bus = ToolBus()
        let sessionID = UUID()
        try await withToolCancelApp(bus: bus) { app in
            let context = app.runeWeaver
            let connectionID = UUID()
            let socket = CancelRecordingSocket()
            _ = await context.hub.add(id: connectionID, box: socket)

            await handleWebSocketToolCancel(
                WSToolCancelMessage(sessionID: sessionID, callID: "   "),
                connectionID: connectionID,
                context: context
            )

            // The shared cancel path rejects a blank identifier before the bus is consulted, so it
            // can never degrade into aborting an arbitrary call.
            let frames = await socket.sent
            #expect(frames.count == 1)
            let raw = try #require(frames.first)
            let frame = try JSONDecoder().decode(WSToolCancelMissFrame.self, from: Data(raw.utf8))
            #expect(frame.type == "tool_cancel_miss")
            #expect(frame.message == "callID must not be empty")
            #expect(frame.sessionID == sessionID)
        }
    }

    @Test
    func `WebSocket tool cancel aborts a running call without a redundant acknowledgement`() async throws {
        let bus = ToolBus()
        let started = CallStartGate()
        await bus.register(tool: BlockingStubTool(name: "stub.ws", started: started))
        let sessionID = UUID()
        let callID = "call_ws"

        try await withToolCancelApp(bus: bus) { app in
            let context = app.runeWeaver
            let connectionID = UUID()
            let socket = CancelRecordingSocket()
            _ = await context.hub.add(id: connectionID, box: socket)

            let running = Task {
                await bus.execute(
                    toolCall: ToolInput(toolName: "stub.ws", argumentsJSON: "{}", callID: callID),
                    context: ToolContext(conversationID: sessionID)
                )
            }
            await started.waitForStarts(1)

            await handleWebSocketToolCancel(
                WSToolCancelMessage(sessionID: sessionID, callID: callID, reason: "stop the tool"),
                connectionID: connectionID,
                context: context
            )

            // The terminal tool_end frame follows the normal event path, so a
            // successful cancel needs no extra acknowledgement on this socket.
            #expect(await socket.sent.isEmpty)

            // The turn receives the injected cancellation rather than hanging.
            let result = await running.value
            #expect(result.isError == true)
            #expect(result.content.contains("cancelled by user"))
        }
    }

    @Test
    func `WebSocket tool cancel cannot abort another session's call`() async throws {
        let bus = ToolBus()
        let started = CallStartGate()
        await bus.register(tool: BlockingStubTool(name: "stub.ws", started: started))
        let owner = UUID()
        let attacker = UUID()
        let callID = "call_scoped"

        try await withToolCancelApp(bus: bus) { app in
            let context = app.runeWeaver
            let connectionID = UUID()
            let socket = CancelRecordingSocket()
            _ = await context.hub.add(id: connectionID, box: socket)

            let running = Task {
                await bus.execute(
                    toolCall: ToolInput(toolName: "stub.ws", argumentsJSON: "{}", callID: callID),
                    context: ToolContext(conversationID: owner)
                )
            }
            await started.waitForStarts(1)

            await handleWebSocketToolCancel(
                WSToolCancelMessage(sessionID: attacker, callID: callID, reason: nil),
                connectionID: connectionID,
                context: context
            )

            // A colliding call identifier must not let one session abort a call it
            // does not own; the handler reports the session-scoped miss through
            // the non-terminal frame so the attacker's own turn keeps running.
            let frames = await socket.sent
            #expect(frames.count == 1)
            let raw = try #require(frames.first)
            let frame = try JSONDecoder().decode(WSToolCancelMissFrame.self, from: Data(raw.utf8))
            #expect(frame.type == "tool_cancel_miss")
            #expect(frame.callID == callID)
            #expect(frame.message?.contains("No in-flight tool call '\(callID)'") == true)
            #expect(frame.sessionID == attacker)

            // Release the still-running call so the fixture task can finish.
            _ = await bus.cancelToolCall(callID: callID, sessionID: owner, reason: nil)
            _ = await running.value
        }
    }
}

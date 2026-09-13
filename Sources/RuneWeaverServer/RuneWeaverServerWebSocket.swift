// Rune Weaver Server — WebSocket chat, cancel, and approval handlers.
//
// Serves live chat turns, mid-turn cancellation, and inline approval
// decisions over the loopback WebSocket. Keeps per-connection task
// tracking and frame dispatch beside the socket route so the main server
// file stays within readability budgets while streaming keeps hub-ordered
// sends and cooperative cancellation.

import Foundation
import RuneWeaverCore
import Vapor

/// Tracks in-flight chat tasks for one WebSocket connection.
///
/// Chat turns spawn unstructured tasks so a later cancel frame can run
/// while the turn is still working; the registry ties those tasks to
/// the socket lifetime so a disconnect cancels them instead of leaving
/// the model and tools running with nowhere to stream.
///
/// Stays a lock-guarded registry instead of an actor because `cancelAll()`
/// runs from Vapor's synchronous `onClose` callback and `remove(id:)` runs
/// from `defer` inside unstructured chat tasks, neither of which can `await`
/// an actor call; forcing actor isolation would require blocking awaits or
/// fire-and-forget hops that could outlive the socket. Lock discipline:
/// `NSLock` guards `tasks` only, and `cancelAll()` copies the task handles
/// under lock then cancels after unlock so cancellation never runs while
/// holding the lock and cannot deadlock.
final class ConnectionChatTasks: @unchecked Sendable {
    /// Guards `tasks`.
    private let lock = NSLock()
    /// In-flight chat tasks keyed by tracking identifier.
    private var tasks: [UUID: Task<Void, Never>] = [:]

    /// Creates an empty registry.
    init() {}

    /// Tracks a chat task until it completes.
    /// - Parameters:
    ///   - task: In-flight chat task.
    ///   - id: Tracking identifier removed on completion.
    func insert(_ task: Task<Void, Never>, id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        tasks[id] = task
    }

    /// Stops tracking a completed chat task.
    /// - Parameter id: Tracking identifier from `insert`.
    func remove(id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        tasks.removeValue(forKey: id)
    }

    /// Cancels every tracked chat task.
    func cancelAll() {
        lock.lock()
        let current = Array(tasks.values)
        lock.unlock()
        for task in current {
            task.cancel()
        }
    }
}

/// Handles one inbound WebSocket text frame.
///
/// Chat frames run the orchestrator and stream the final text back as
/// `delta` chunks plus a `done` frame; decision frames resolve the
/// matching pending approval; anything else answers with an `error`
/// frame so the socket stays open. Cooperative with task cancellation:
/// checks `Task.isCancelled` before work and between sends so closing
/// the socket (or Vapor shutdown) stops the turn promptly instead of
/// streaming into a dead connection. All sends funnel through the hub
/// (`send(id:text:)`) so streamed deltas never race broadcast prompts.
/// - Parameters:
///   - text: Raw socket text frame.
///   - connectionID: Connection identifier owning the reply.
///   - context: Shared engine collaborators.
///   - connectionTasks: Registry tying chat tasks to the socket lifetime.
func handleWebSocketText(_ text: String, connectionID: UUID, context: ServerContext, connectionTasks: ConnectionChatTasks) async {
    guard !Task.isCancelled else { return }
    switch WSInboundKind.classify(text) {
    case let .chat(message):
        await handleWebSocketChat(message, connectionID: connectionID, context: context, connectionTasks: connectionTasks)
    case let .cancel(message):
        await handleWebSocketCancel(message, connectionID: connectionID, context: context)
    case let .decision(message):
        await handleWebSocketDecision(message, connectionID: connectionID, context: context)
    case .unknown:
        let hint = "Expected a chat frame {\"text\": \"...\"}, a decision frame, or a cancel frame"
        await sendWSError(hint, connectionID: connectionID, context: context)
    }
}

/// Dispatches an orchestrator event to a connected WebSocket client.
func sendWSEventFrame(_ event: OrchestratorEvent, connectionID: UUID, sessionID: UUID, context: ServerContext) async {
    guard !Task.isCancelled else { return }
    let frameText: String? = switch event {
    case let .toolStarted(toolName, callID, argumentsJSON):
        try? String(
            data: JSONEncoder().encode(WSToolStartFrame(toolName: toolName, callID: callID, argumentsJSON: argumentsJSON, sessionID: sessionID)),
            encoding: .utf8
        )
    case let .toolCompleted(toolName, callID, result):
        try? String(
            data: JSONEncoder().encode(WSToolEndFrame(toolName: toolName, callID: callID, result: result, sessionID: sessionID)),
            encoding: .utf8
        )
    case let .textDelta(delta):
        try? String(data: JSONEncoder().encode(WSStreamDelta(delta: delta, sessionID: sessionID)), encoding: .utf8)
    }
    if let frameText {
        await context.hub.send(id: connectionID, text: frameText)
    }
}

/// Executes a chat turn over WebSocket with real-time streaming and cooperative cancellation.
func handleWebSocketChat(_ message: WSChatMessage, connectionID: UUID, context: ServerContext, connectionTasks: ConnectionChatTasks) async {
    let trimmed: String
    do {
        trimmed = try validatedChatText(message.text)
    } catch let abort as Abort {
        await sendWSError(abort.reason, connectionID: connectionID, context: context, sessionID: message.sessionID)
        return
    } catch {
        await sendWSError(error.localizedDescription, connectionID: connectionID, context: context, sessionID: message.sessionID)
        return
    }
    let sessionID = message.sessionID ?? UUID()
    let source = (message.source ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

    // Register before spawning so a fast turn can never finish before its
    // slot exists; the box bridges the cancel action to the task created
    // just below. Completion cleanup is token-checked and await-ordered
    // (no fire-and-forget unregister), so a stale completion never
    // deletes a newer turn's registration for the same session. The task
    // also registers with the connection lifetime so a disconnect cancels
    // it instead of leaving work running with nowhere to stream.
    let taskBox = TurnTaskBox()
    let registration = await context.activeTurns.register(sessionID: sessionID, onCancel: { taskBox.cancel() })
    let trackingID = UUID()
    let chatTask: Task<Void, Never> = Task { [context, connectionID, sessionID, source, trimmed, registration, connectionTasks, trackingID] in
        defer { connectionTasks.remove(id: trackingID) }
        let startTime = Date()
        do {
            let response = try await context.orchestrator.process(
                input: UserInput(
                    text: trimmed,
                    sessionID: sessionID,
                    source: source.isEmpty ? "websocket" : source
                ),
                onEvent: { event in
                    await sendWSEventFrame(event, connectionID: connectionID, sessionID: sessionID, context: context)
                }
            )
            guard !Task.isCancelled else {
                await context.activeTurns.unregister(sessionID: sessionID, token: registration.token)
                return
            }
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            await context.runs.append(
                kind: "chat",
                status: "ok",
                message: trimmed,
                response: response.text,
                toolActions: response.toolActions,
                totalTokens: response.totalTokens,
                durationMs: durationMs
            )
            let done = WSStreamDone(from: response)
            if let data = try? JSONEncoder().encode(done), let frame = String(data: data, encoding: .utf8) {
                await context.hub.send(id: connectionID, text: frame)
            }
            await context.activeTurns.unregister(sessionID: sessionID, token: registration.token)
        } catch is CancellationError {
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            await context.runs.append(kind: "chat", status: "cancelled", message: trimmed, durationMs: durationMs)
            let cancelledFrame = WSCancelledFrame(sessionID: sessionID)
            if let data = try? JSONEncoder().encode(cancelledFrame), let frame = String(data: data, encoding: .utf8) {
                await context.hub.send(id: connectionID, text: frame)
            }
            await context.activeTurns.unregister(sessionID: sessionID, token: registration.token)
        } catch {
            guard !Task.isCancelled else {
                await context.activeTurns.unregister(sessionID: sessionID, token: registration.token)
                return
            }
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            await context.runs.append(kind: "chat", status: "error", message: trimmed, durationMs: durationMs)
            await sendWSError(error.localizedDescription, connectionID: connectionID, context: context, sessionID: sessionID)
            await context.activeTurns.unregister(sessionID: sessionID, token: registration.token)
        }
    }
    connectionTasks.insert(chatTask, id: trackingID)
    taskBox.set(chatTask)
}

/// Cancels an in-flight chat turn over WebSocket.
///
/// Reports whether a running turn was actually aborted so clients can tell
/// an idle cancel apart from a real one; idle cancels for unknown or
/// long-idle sessions leave no pending mark behind to poison the next turn.
func handleWebSocketCancel(_ message: WSCancelMessage, connectionID: UUID, context: ServerContext) async {
    var cancelled = false
    if let sid = message.sessionID {
        cancelled = await context.activeTurns.cancel(sessionID: sid)
    }
    let cancelledFrame = WSCancelledFrame(sessionID: message.sessionID, cancelled: cancelled)
    if let data = try? JSONEncoder().encode(cancelledFrame),
       let frame = String(data: data, encoding: .utf8)
    {
        await context.hub.send(id: connectionID, text: frame)
    }
}

/// Resolves an approval decision received over WebSocket.
func handleWebSocketDecision(_ message: WSDecisionMessage, connectionID: UUID, context: ServerContext) async {
    guard !Task.isCancelled else { return }
    let resolved = await context.approvals.decide(
        id: message.id,
        approved: message.approved,
        duration: message.resolvedDuration
    )
    guard resolved else {
        await sendWSError("Unknown approval \(message.id.uuidString)", connectionID: connectionID, context: context)
        return
    }
}

/// Sends one WebSocket error frame through the hub, best-effort.
/// - Parameters:
///   - message: Human-readable failure.
///   - connectionID: Connection identifier owning the reply.
///   - context: Shared engine collaborators.
///   - sessionID: Owning session, when the failure belongs to one turn.
func sendWSError(_ message: String, connectionID: UUID, context: ServerContext, sessionID: UUID? = nil) async {
    if Task.isCancelled {
        return
    }
    guard let data = try? JSONEncoder().encode(WSErrorFrame(message: message, sessionID: sessionID)),
          let frame = String(data: data, encoding: .utf8)
    else { return }
    await context.hub.send(id: connectionID, text: frame)
}

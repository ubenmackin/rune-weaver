// Rune Weaver Server — WebSocket chat, cancel, and approval handlers.

import Foundation
import os
import RuneWeaverCore
import Vapor

/// Tracks in-flight chat tasks for one WebSocket connection.
final class ConnectionChatTasks: Sendable {
    private let tasks = OSAllocatedUnfairLock(initialState: [UUID: Task<Void, Never>]())

    /// Creates an empty registry.
    init() {}

    /// Tracks a chat task until it completes.
    func insert(_ task: Task<Void, Never>, id: UUID) {
        tasks.withLock { $0[id] = task }
    }

    /// Stops tracking a completed chat task.
    /// - Parameter id: Tracking identifier from `insert`.
    func remove(id: UUID) {
        _ = tasks.withLock { $0.removeValue(forKey: id) }
    }

    /// Cancels every tracked chat task.
    func cancelAll() {
        let current = tasks.withLock { Array($0.values) }
        for task in current {
            task.cancel()
        }
    }
}

/// Handles one inbound WebSocket text frame.
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

/// Encodes an orchestrator event to its shared WebSocket wire text, if any.
func wsEventFrameText(_ event: OrchestratorEvent, sessionID: UUID) -> String? {
    switch event {
    case let .toolStarted(toolName, callID, argumentsJSON, roundIndex):
        try? String(
            data: JSONEncoder().encode(
                WSToolStartFrame(
                    toolName: toolName,
                    callID: callID,
                    argumentsJSON: argumentsJSON,
                    sessionID: sessionID,
                    roundIndex: roundIndex
                )
            ),
            encoding: .utf8
        )
    case let .toolCompleted(toolName, callID, result, roundIndex):
        try? String(
            data: JSONEncoder().encode(
                WSToolEndFrame(
                    toolName: toolName,
                    callID: callID,
                    result: result,
                    sessionID: sessionID,
                    roundIndex: roundIndex
                )
            ),
            encoding: .utf8
        )
    case let .textDelta(delta):
        try? String(data: JSONEncoder().encode(WSStreamDelta(delta: delta, sessionID: sessionID)), encoding: .utf8)
    case let .warning(message):
        // Degraded-tool notices stream as warning frames so clients surface skips
        // mid-turn without failing the turn; the terminal done frame repeats them.
        try? String(data: JSONEncoder().encode(WSWarningFrame(message: message, sessionID: sessionID)), encoding: .utf8)
    case let .turnTokens(roundIndex, roundTokens, turnTotalTokens):
        // Per-round usage progress for the live footer: session-tagged so multiplexed
        // views only apply their own turn and older clients drop the unknown type.
        // The terminal done frame stays authoritative for reconciliation.
        try? String(
            data: JSONEncoder().encode(
                WSTurnTokensFrame(
                    sessionID: sessionID,
                    roundIndex: roundIndex,
                    roundTokens: roundTokens,
                    turnTotalTokens: turnTotalTokens
                )
            ),
            encoding: .utf8
        )
    case .approval:
        nil
    }
}

/// Dispatches an orchestrator event to a connected WebSocket client.
func sendWSEventFrame(_ event: OrchestratorEvent, connectionID: UUID, sessionID: UUID, context: ServerContext) async {
    guard !Task.isCancelled else {
        return
    }
    if case let .approval(request) = event {
        await context.hub.broadcastApproval(request)
        return
    }
    if let frameText = wsEventFrameText(event, sessionID: sessionID) {
        await context.hub.send(id: connectionID, text: frameText)
    }
}

/// Broadcasts an orchestrator event to every connected WebSocket client.
func broadcastWSEventFrame(_ event: OrchestratorEvent, sessionID: UUID, context: ServerContext) async {
    guard !Task.isCancelled else {
        return
    }
    if case let .approval(request) = event {
        await context.hub.broadcastApproval(request)
        return
    }
    if let frameText = wsEventFrameText(event, sessionID: sessionID) {
        await context.hub.broadcast(text: frameText)
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

    // Register before spawning so a fast turn can never finish before its slot exists; the box
    // bridges the cancel action to the task created just below.
    let taskBox = TurnTaskBox()
    let registration = await context.activeTurns.register(sessionID: sessionID, onCancel: { taskBox.cancel() })
    let trackingID = UUID()
    let chatTask: Task<Void, Never> = Task { [context, connectionID, sessionID, source, trimmed, registration, connectionTasks, trackingID] in
        defer { connectionTasks.remove(id: trackingID) }
        let startTime = Date()
        // Liveness heartbeat covers the silent stretches where prompt evaluation
        // produces no deltas, tool frames, or warnings: without it a healthy
        // multi-minute local inference looks identical to a dropped socket and
        // the dashboard's inactivity timer cancels the turn mid-eval. The task
        // is unstructured so it ticks alongside `process`; the defer below
        // guarantees it stops on every terminal path, and per-send delivery
        // still flows through the queued 5s timeout so a slow peer cannot wedge
        // the turn. Sends targeted to the owning socket so unrelated sessions
        // never wake; the REST path keeps broadcasting because it has no owning
        // socket for multi-viewer turns.
        let heartbeat = Task { [context, connectionID, sessionID] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: WSTurnAlive.intervalNanoseconds)
                } catch {
                    break
                }
                if Task.isCancelled {
                    break
                }
                if let alive = WSTurnAlive.frameText(sessionID: sessionID) {
                    await context.hub.send(id: connectionID, text: alive)
                }
            }
        }
        defer { heartbeat.cancel() }
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
            // Parked approval-gated turns persist as awaiting_approval instead of ok so the inbox
            // decision can transition the same session entry. The per-turn parked flag keeps a
            // stale prior park in this session from mis-marking a fresh normal turn.
            let parked = response.isParked
            let parkedStatus = if parked {
                "awaiting_approval"
            } else {
                "ok"
            }
            let entry = await context.runs.append(
                kind: "chat",
                status: parkedStatus,
                message: trimmed,
                sessionID: sessionID,
                response: response.text,
                toolActions: response.toolActions,
                totalTokens: response.totalTokens,
                durationMs: durationMs
            )
            if parked {
                await context.hub.broadcastRun(entry)
            }
            // Live warning frames already streamed mid-turn; the terminal done frame repeats them
            // for polling clients, so no per-warning resend here that would double-count the bell.
            let done = WSStreamDone(from: response)
            if let data = try? JSONEncoder().encode(done), let frame = String(data: data, encoding: .utf8) {
                await context.hub.send(id: connectionID, text: frame)
            }
            await context.activeTurns.unregister(sessionID: sessionID, token: registration.token)
        } catch is CancellationError {
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            await context.runs.append(kind: "chat", status: "cancelled", message: trimmed, sessionID: sessionID, durationMs: durationMs)
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
            await context.runs.append(kind: "chat", status: "error", message: trimmed, sessionID: sessionID, durationMs: durationMs)
            await sendWSError(error.localizedDescription, connectionID: connectionID, context: context, sessionID: sessionID)
            await context.activeTurns.unregister(sessionID: sessionID, token: registration.token)
        }
    }
    connectionTasks.insert(chatTask, id: trackingID)
    taskBox.set(chatTask)
}

/// Cancels an in-flight chat turn over WebSocket.
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
    guard !Task.isCancelled else {
        return
    }
    let pending = await context.approvals.request(id: message.id)
    let resolved = await context.approvals.decide(
        id: message.id,
        approved: message.approved,
        duration: message.resolvedDuration
    )
    guard resolved else {
        await sendWSError("Unknown approval \(message.id.uuidString)", connectionID: connectionID, context: context)
        return
    }
    // Durable approvals create a stored grant inside `decide`, so
    // dashboards need a refresh signal; one-shot approvals store
    // nothing and leave the grants list untouched.
    if message.approved, message.resolvedDuration != .thisTime {
        await context.hub.broadcastTrustGrantsChanged()
    }
    if pending?.sessionID != nil {
        Task {
            await resumeNarratedApproval(
                id: message.id,
                approved: message.approved,
                context: context,
                sessionID: pending?.sessionID,
                decidedCallID: pending?.input.callID
            )
        }
    }
}

/// Sends one WebSocket error frame through the hub, best-effort.
func sendWSError(_ message: String, connectionID: UUID, context: ServerContext, sessionID: UUID? = nil) async {
    if Task.isCancelled {
        return
    }
    guard let data = try? JSONEncoder().encode(WSErrorFrame(message: message, sessionID: sessionID)),
          let frame = String(data: data, encoding: .utf8)
    else { return }
    await context.hub.send(id: connectionID, text: frame)
}

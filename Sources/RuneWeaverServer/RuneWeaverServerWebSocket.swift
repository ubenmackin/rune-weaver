// Rune Weaver Server — WebSocket chat, cancel, and approval handlers.

import Foundation
import os
import RuneWeaverCore
import Vapor

/// Tracks in-flight chat turns plus approval resumes for one WebSocket connection.
final class ConnectionChatTasks: Sendable {
    /// One slot: awaiting its task, holding it, or already cancelled.
    /// Sendable so the lock-protected table stays within Swift 6 isolation.
    enum Slot: Sendable {
        case reserved
        case task(Task<Void, Never>)
        case cancelled
    }

    /// Locked table plus whether the socket has closed.
    /// The flag stays beside the slots so reserve/insert/cancelAll decide
    /// atomically; otherwise a close landing between reserve and insert
    /// would leave the late task running with no handle to stop it.
    private struct State: Sendable {
        var slots: [UUID: Slot] = [:]
        var closed = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Creates an empty registry.
    init() {}

    /// Reserves a slot before creating the task to prevent race conditions.
    /// A reserve after close parks as cancelled so the matching insert
    /// aborts its task instead of leaking it past the socket lifetime.
    func reserve(id: UUID) {
        state.withLock {
            if $0.closed {
                $0.slots[id] = .cancelled
            } else {
                $0.slots[id] = .reserved
            }
        }
    }

    /// Tracks a chat or resume task until it completes.
    /// Always stores when open, even without a reservation, so a socket close
    /// can still stop it; when the slot was already cancelled (or the socket
    /// closed first) the task is cancelled immediately instead of stored.
    func insert(_ task: Task<Void, Never>, id: UUID) {
        let shouldCancel = state.withLock { locked -> Bool in
            if locked.closed {
                locked.slots[id] = .cancelled
                return true
            }
            if case .cancelled = locked.slots[id] {
                return true
            }
            locked.slots[id] = .task(task)
            return false
        }
        if shouldCancel {
            task.cancel()
        }
    }

    /// Stops tracking a completed chat or resume task.
    /// - Parameter id: Tracking identifier from `insert`.
    func remove(id: UUID) {
        _ = state.withLock { $0.slots.removeValue(forKey: id) }
    }

    /// Cancels every tracked chat and resume task.
    /// Reserved slots flip to cancelled so a racing insert aborts on arrival,
    /// and the closed flag makes later reserves cancel on insert; the socket
    /// close path and an explicit in-flight cancel share this one hop.
    func cancelAll() {
        let current = state.withLock { locked -> [Task<Void, Never>] in
            locked.closed = true
            var running: [Task<Void, Never>] = []
            for (id, slot) in locked.slots {
                switch slot {
                case let .task(task):
                    running.append(task)
                    locked.slots[id] = .cancelled
                case .reserved:
                    locked.slots[id] = .cancelled
                case .cancelled:
                    break
                }
            }
            return running
        }
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
        await handleWebSocketDecision(message, connectionID: connectionID, context: context, connectionTasks: connectionTasks)
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

    // Bound parallel turns so slow local inference never stacks silently: the
    // acquire and the registration happen in one tracker hop, so concurrent
    // fresh sessions cannot both slip past the cap. A replacement turn for
    // the same session always fits (it supersedes the prior slot), while a
    // fresh session past the cap fails honestly instead of starving every
    // turn at once.
    // Register before spawning so a fast turn can never finish before its slot exists; the box
    // bridges the cancel action to the task created just below.
    let taskBox = TurnTaskBox()
    guard let registration = await context.activeTurns.tryAcquire(sessionID: sessionID, onCancel: { taskBox.cancel() }) else {
        await sendWSError(
            "Already running \(ActiveTurnTracker.maxConcurrentTurns) chat turns — wait for one to finish or cancel it, then retry.",
            connectionID: connectionID,
            context: context,
            sessionID: sessionID
        )
        return
    }
    // Publish the running row immediately so dashboards badge the background
    // session from the run log even before the first delta streams; the
    // terminal paths below update this same row instead of appending a second,
    // keeping one audit entry per turn.
    let initialEntry = await context.runs.append(
        kind: "chat",
        status: "running",
        message: trimmed,
        sessionID: sessionID,
        durationMs: 0
    )
    await context.hub.broadcastRun(initialEntry)
    let trackingID = UUID()
    connectionTasks.reserve(id: trackingID)
    let params = WebSocketTurnParameters(
        context: context,
        connectionID: connectionID,
        sessionID: sessionID,
        source: source,
        trimmed: trimmed,
        registration: registration,
        trackingID: trackingID,
        initialEntry: initialEntry
    )
    let chatTask: Task<Void, Never> = Task { [weak connectionTasks] in
        await executeWebSocketTurn(params: params, connectionTasks: connectionTasks)
    }
    connectionTasks.insert(chatTask, id: trackingID)
    taskBox.set(chatTask)
}

/// Parameters required to execute a single WebSocket chat turn.
private struct WebSocketTurnParameters: Sendable {
    let context: ServerContext
    let connectionID: UUID
    let sessionID: UUID
    let source: String
    let trimmed: String
    let registration: TurnRegistration
    let trackingID: UUID
    let initialEntry: RunLogEntry
}

/// Runs one chat turn's liveness heartbeat, inference process, and status updates.
private func executeWebSocketTurn(params: WebSocketTurnParameters, connectionTasks: ConnectionChatTasks?) async {
    let context = params.context
    let connectionID = params.connectionID
    let sessionID = params.sessionID
    let source = params.source
    let trimmed = params.trimmed
    let registration = params.registration
    let trackingID = params.trackingID
    let initialEntry = params.initialEntry

    defer { connectionTasks?.remove(id: trackingID) }
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
    let heartbeat = startHeartbeat(context: context, connectionID: connectionID, sessionID: sessionID)
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
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            let entry = await context.runs.update(
                id: initialEntry.id,
                status: "cancelled",
                durationMs: durationMs
            ) ?? initialEntry
            await context.hub.broadcastRun(entry)
            // Cancellation can land after inference succeeds but before the done
            // frame sends, so the owning socket still needs a targeted terminal
            // frame to clear its pending state without waiting for a timeout.
            let cancelledFrame = WSCancelledFrame(sessionID: sessionID)
            if let data = try? JSONEncoder().encode(cancelledFrame), let frame = String(data: data, encoding: .utf8) {
                await context.hub.send(id: connectionID, text: frame)
            }
            await context.activeTurns.unregister(sessionID: sessionID, token: registration.token)
            return
        }
        let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
        // Parked approval-gated turns persist as awaiting_approval instead of ok so the inbox
        // decision can transition the same session entry. The per-turn parked flag keeps a
        // stale prior park in this session from mis-marking a fresh normal turn.
        // A parked turn clears the running badge (its broadcast lands as completed)
        // while the approvals badge carries the wait, matching the polled
        // running-session filter so live and reload views agree.
        let parked = response.isParked
        let parkedStatus = if parked {
            "awaiting_approval"
        } else {
            "ok"
        }
        let entry = await context.runs.update(
            id: initialEntry.id,
            status: parkedStatus,
            response: response.text,
            toolActions: response.toolActions,
            totalTokens: response.totalTokens,
            durationMs: durationMs
        ) ?? initialEntry
        await context.hub.broadcastRun(entry)
        // Live warning frames already streamed mid-turn; the terminal done frame repeats them
        // for polling clients, so no per-warning resend here that would double-count the bell.
        let done = WSStreamDone(from: response)
        if let data = try? JSONEncoder().encode(done), let frame = String(data: data, encoding: .utf8) {
            await context.hub.send(id: connectionID, text: frame)
        }
        await context.activeTurns.unregister(sessionID: sessionID, token: registration.token)
    } catch is CancellationError {
        let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
        let entry = await context.runs.update(
            id: initialEntry.id,
            status: "cancelled",
            durationMs: durationMs
        ) ?? initialEntry
        await context.hub.broadcastRun(entry)
        let cancelledFrame = WSCancelledFrame(sessionID: sessionID)
        if let data = try? JSONEncoder().encode(cancelledFrame), let frame = String(data: data, encoding: .utf8) {
            await context.hub.send(id: connectionID, text: frame)
        }
        await context.activeTurns.unregister(sessionID: sessionID, token: registration.token)
    } catch {
        guard !Task.isCancelled else {
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            let entry = await context.runs.update(
                id: initialEntry.id,
                status: "cancelled",
                durationMs: durationMs
            ) ?? initialEntry
            await context.hub.broadcastRun(entry)
            // A failure racing cancellation still leaves the owning socket
            // waiting, so it needs the same targeted terminal frame as the
            // other cancelled paths to clear its pending state promptly.
            let cancelledFrame = WSCancelledFrame(sessionID: sessionID)
            if let data = try? JSONEncoder().encode(cancelledFrame), let frame = String(data: data, encoding: .utf8) {
                await context.hub.send(id: connectionID, text: frame)
            }
            await context.activeTurns.unregister(sessionID: sessionID, token: registration.token)
            return
        }
        let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
        let entry = await context.runs.update(
            id: initialEntry.id,
            status: "error",
            durationMs: durationMs
        ) ?? initialEntry
        await context.hub.broadcastRun(entry)
        await sendWSError(error.localizedDescription, connectionID: connectionID, context: context, sessionID: sessionID)
        await context.activeTurns.unregister(sessionID: sessionID, token: registration.token)
    }
}

/// Spawns a background liveness heartbeat task for long inference turns.
private func startHeartbeat(context: ServerContext, connectionID: UUID, sessionID: UUID) -> Task<Void, Never> {
    Task {
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
func handleWebSocketDecision(_ message: WSDecisionMessage, connectionID: UUID, context: ServerContext, connectionTasks: ConnectionChatTasks) async {
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
        // Track the resume under the socket lifetime so close or shutdown
        // cancels it instead of leaving an orphaned synthesis turn running
        // with no viewer to receive its broadcasts. Reserve before spawning
        // so a close landing in the gap parks as cancelled and the insert
        // aborts immediately; the defer removes the slot on every terminal
        // path so the table never retains finished resumes.
        let trackingID = UUID()
        connectionTasks.reserve(id: trackingID)
        let approvalID = message.id
        let approved = message.approved
        let resumeSessionID = pending?.sessionID
        let decidedCallID = pending?.input.callID
        let resumeTask: Task<Void, Never> = Task { [weak connectionTasks] in
            defer { connectionTasks?.remove(id: trackingID) }
            guard !Task.isCancelled else { return }
            await resumeNarratedApproval(
                id: approvalID,
                approved: approved,
                context: context,
                sessionID: resumeSessionID,
                decidedCallID: decidedCallID
            )
        }
        connectionTasks.insert(resumeTask, id: trackingID)
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

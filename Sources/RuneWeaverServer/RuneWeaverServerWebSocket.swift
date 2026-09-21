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

/// Partial audit snapshot for a turn that ended without an authoritative response.
///
/// Named fields keep error paths readable where an anonymous triple would hide
/// which value is billed usage versus partial text, and keep the audit shape
/// identical between the REST and WebSocket failure paths.
struct ChatTurnAuditSnapshot: Sendable {
    /// Assistant text streamed before the failure, possibly empty.
    let partialText: String
    /// Tool actions completed or started before the failure.
    let toolActions: [ToolAction]
    /// Billed total accumulated before the failure, when reported.
    let totalTokens: Int?

    /// Creates a snapshot.
    init(partialText: String, toolActions: [ToolAction], totalTokens: Int? = nil) {
        self.partialText = partialText
        self.toolActions = toolActions
        self.totalTokens = totalTokens
    }
}

/// Accumulates mid-turn audit progress from orchestrator events so error paths keep partial context.
///
/// Success paths persist the authoritative response, while failures have no response to persist;
/// without this the audit row would drop tools that already ran. Completed tool frames build the
/// action list, pending starts cover a tool interrupted mid-call, deltas rebuild partial text, and
/// the latest turn total carries billed usage for the same response/toolActions/totalTokens shape
/// as success.
final class ChatTurnAuditProgress: Sendable {
    /// One started-but-unfinished tool call, kept so an interrupted call still audits.
    private struct PendingStart: Sendable {
        let toolName: String
        let argumentsJSON: String
        let roundIndex: Int?
    }

    /// Locked progress: pending starts plus completed actions, partial text, and billed total.
    private struct ProgressState: Sendable {
        var pendingStarts: [String: PendingStart] = [:]
        var completed: [ToolAction] = []
        var partialText = ""
        var totalTokens: Int?
    }

    private let state = OSAllocatedUnfairLock(initialState: ProgressState())

    /// Creates an empty accumulator.
    init() {}

    /// Folds one orchestrator event into the partial audit snapshot.
    /// - Parameter event: Live turn event to accumulate.
    func record(_ event: OrchestratorEvent) {
        state.withLock { locked in
            switch event {
            case let .toolStarted(toolName, callID, argumentsJSON, roundIndex):
                locked.pendingStarts[callID] = PendingStart(
                    toolName: toolName,
                    argumentsJSON: argumentsJSON,
                    roundIndex: roundIndex
                )
            case let .toolCompleted(toolName, callID, result, roundIndex):
                let pending = locked.pendingStarts.removeValue(forKey: callID)
                locked.completed.append(ToolAction(
                    toolName: toolName,
                    callID: callID,
                    argumentsJSON: pending?.argumentsJSON ?? "{}",
                    result: result,
                    roundIndex: roundIndex ?? pending?.roundIndex
                ))
            case let .textDelta(delta):
                locked.partialText += delta
            case let .turnTokens(_, _, turnTotalTokens):
                guard turnTotalTokens >= 0 else { break }
                locked.totalTokens = turnTotalTokens
            case .warning, .toolProgress, .approval:
                break
            }
        }
    }

    /// Snapshots the accumulated partial text, tool actions, and billed total.
    /// - Returns: Partial text plus completed actions with pending starts appended as result-less actions.
    func snapshot() -> ChatTurnAuditSnapshot {
        state.withLock { locked in
            var actions = locked.completed
            for callID in locked.pendingStarts.keys.sorted() {
                guard let pending = locked.pendingStarts[callID] else { continue }
                actions.append(ToolAction(
                    toolName: pending.toolName,
                    callID: callID,
                    argumentsJSON: pending.argumentsJSON,
                    result: nil,
                    roundIndex: pending.roundIndex
                ))
            }
            return ChatTurnAuditSnapshot(
                partialText: locked.partialText,
                toolActions: actions,
                totalTokens: locked.totalTokens
            )
        }
    }
}

/// Authorizes a WebSocket upgrade at the route boundary.
///
/// The global auth middleware is the primary gate; this re-checks the marker it
/// leaves behind so a WebSocket route registered without that middleware fails
/// closed instead of handing out a live socket. The credential itself is never
/// read here: the middleware validates it once and strips the upgrade query
/// token, so this guard cannot reintroduce it into logs.
/// - Parameter request: Upgrade handshake request.
/// - Returns: Empty headers to proceed, or nil to refuse the upgrade.
func authorizeWebSocketUpgrade(_ request: Request) async -> HTTPHeaders? {
    guard request.application.runeWeaverAuth != nil else {
        return [:]
    }
    return request.runeWeaverAuthenticated ? [:] : nil
}

/// Handles one inbound WebSocket text frame.
func handleWebSocketText(_ text: String, connectionID: UUID, context: ServerContext, connectionTasks: ConnectionChatTasks) async {
    guard !Task.isCancelled else { return }
    switch WSInboundKind.classify(text) {
    case let .chat(message):
        await handleWebSocketChat(message, connectionID: connectionID, context: context, connectionTasks: connectionTasks)
    case let .cancel(message):
        await handleWebSocketCancel(message, connectionID: connectionID, context: context)
    case let .toolCancel(message):
        await handleWebSocketToolCancel(message, connectionID: connectionID, context: context)
    case let .decision(message):
        await handleWebSocketDecision(message, connectionID: connectionID, context: context, connectionTasks: connectionTasks)
    case .unknown:
        let hint = "Expected a chat frame {\"text\": \"...\"}, a decision frame, a cancel frame, or a tool_cancel frame"
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
    case let .toolProgress(progress):
        // Generic indeterminate progress from a running tool: session-tagged so
        // multiplexed views only apply their own turn and older clients drop the
        // unknown type. Advisory only, so the terminal tool result stays the
        // authoritative record.
        try? String(
            data: JSONEncoder().encode(WSToolProgressFrame(progress, sessionID: sessionID)),
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

    // Steering frames never start a fresh turn: they either join the live turn
    // or fail honestly so the dashboard can roll back its optimistic bubble.
    // The liveness probe and the enqueue are separate actor hops, so a finish
    // or cancel can land between them; probing again after the enqueue keeps
    // that window honest instead of silently queuing into a dead session.
    // A joint tracker-plus-queue hop would close the window entirely, but the
    // double probe is the narrowest honest shape without one: text that loses
    // the race is withdrawn so the miss error and the queue agree, leaving no
    // orphaned copy to answer the next turn as a duplicate.
    if message.steer == true {
        guard await context.activeTurns.isActive(sessionID: sessionID) else {
            await sendWSError(
                "No active turn for this session — steering was not applied. Send as a new message.",
                connectionID: connectionID,
                context: context,
                sessionID: sessionID
            )
            return
        }
        await context.steeringQueue.enqueue(text: trimmed, sessionID: sessionID)
        guard await context.activeTurns.isActive(sessionID: sessionID) else {
            // Drop just-enqueued steering on miss so error and queue agree; prevents duplicate next turn.
            // Withdraw newest to match client pop; keeps error and queue in agreement.
            await context.steeringQueue.remove(text: trimmed, sessionID: sessionID)
            await sendWSError(
                "Turn ended before steering arrived — it missed the in-flight turn. Send as a new message.",
                connectionID: connectionID,
                context: context,
                sessionID: sessionID
            )
            return
        }
        return
    }

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
///
/// The heartbeat and audit accumulator stay here while terminal persistence
/// lives in the finish helpers below, keeping this body inside the lint budget
/// without changing the per-path audit behavior.
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
    let heartbeat = startHeartbeat(context: context, connectionID: connectionID, sessionID: sessionID)
    defer { heartbeat.cancel() }
    let auditProgress = ChatTurnAuditProgress()
    do {
        let response = try await context.orchestrator.process(
            input: UserInput(
                text: trimmed,
                sessionID: sessionID,
                source: source.isEmpty ? "websocket" : source
            ),
            onEvent: { event in
                auditProgress.record(event)
                await sendWSEventFrame(event, connectionID: connectionID, sessionID: sessionID, context: context)
            }
        )
        guard !Task.isCancelled else {
            await handleWebSocketTurnCancellation(
                context: context,
                connectionID: connectionID,
                sessionID: sessionID,
                registrationToken: registration.token,
                initialEntry: initialEntry,
                startTime: startTime
            )
            return
        }
        await finishWebSocketSuccessfulTurn(params: params, response: response, startTime: startTime)
    } catch is CancellationError {
        await handleWebSocketTurnCancellation(
            context: context,
            connectionID: connectionID,
            sessionID: sessionID,
            registrationToken: registration.token,
            initialEntry: initialEntry,
            startTime: startTime
        )
    } catch {
        guard !Task.isCancelled else {
            await handleWebSocketTurnCancellation(
                context: context,
                connectionID: connectionID,
                sessionID: sessionID,
                registrationToken: registration.token,
                initialEntry: initialEntry,
                startTime: startTime
            )
            return
        }
        await finishWebSocketFailedTurn(
            params: params,
            error: error,
            audit: auditProgress.snapshot(),
            startTime: startTime
        )
    }
}

/// Persists a successful WebSocket turn and delivers its terminal done frame.
///
/// Parked approval-gated turns persist as awaiting_approval instead of ok so the
/// inbox decision can transition the same session entry. Late steering stays
/// queued for the next turn so guidance arriving after the final ingest still
/// gets answered instead of vanishing after its optimistic render.
private func finishWebSocketSuccessfulTurn(
    params: WebSocketTurnParameters,
    response: OrchestratorResponse,
    startTime: Date
) async {
    let context = params.context
    let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
    let parkedStatus = if response.isParked {
        "awaiting_approval"
    } else {
        "ok"
    }
    let entry = await context.runs.update(
        id: params.initialEntry.id,
        status: parkedStatus,
        response: response.text,
        toolActions: response.toolActions,
        totalTokens: response.totalTokens,
        durationMs: durationMs
    ) ?? params.initialEntry
    await context.hub.broadcastRun(entry)
    var done = WSStreamDone(from: response)
    done.retainedSteerCount = await context.steeringQueue.pendingCount(for: params.sessionID)
    if let data = try? JSONEncoder().encode(done), let frame = String(data: data, encoding: .utf8) {
        await context.hub.send(id: params.connectionID, text: frame)
    }
    await context.activeTurns.unregister(sessionID: params.sessionID, token: params.registration.token)
}

/// Persists a failed WebSocket turn keeping the same audit shape as success.
///
/// Error rows reuse partial assistant text when streamed (else the error detail
/// so the row is never response-less) plus the tools that already ran and their
/// billed total, matching the tools the client already rendered live. Failed
/// turns keep late steering queued so the retry can still answer guidance that
/// arrived after the final ingest.
private func finishWebSocketFailedTurn(
    params: WebSocketTurnParameters,
    error: Error,
    audit: ChatTurnAuditSnapshot,
    startTime: Date
) async {
    let context = params.context
    let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
    let auditResponse = audit.partialText.isEmpty ? error.localizedDescription : audit.partialText
    let entry = await context.runs.update(
        id: params.initialEntry.id,
        status: "error",
        response: auditResponse,
        toolActions: audit.toolActions,
        totalTokens: audit.totalTokens,
        durationMs: durationMs
    ) ?? params.initialEntry
    await context.hub.broadcastRun(entry)
    let errorMessage = Message(
        role: .assistant,
        content: "Error: \(error.localizedDescription)",
        isError: true
    )
    await context.conversations.append(errorMessage, to: params.sessionID)
    await sendWSError(
        error.localizedDescription,
        connectionID: params.connectionID,
        context: context,
        sessionID: params.sessionID
    )
    await context.activeTurns.unregister(sessionID: params.sessionID, token: params.registration.token)
}

private func handleWebSocketTurnCancellation(
    context: ServerContext,
    connectionID: UUID,
    sessionID: UUID,
    registrationToken: UUID,
    initialEntry: RunLogEntry,
    startTime: Date
) async {
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
    await context.activeTurns.unregister(sessionID: sessionID, token: registrationToken)
    await context.steeringQueue.clear(for: sessionID)
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
        await context.steeringQueue.clear(for: sid)
    }
    let cancelledFrame = WSCancelledFrame(sessionID: message.sessionID, cancelled: cancelled)
    if let data = try? JSONEncoder().encode(cancelledFrame),
       let frame = String(data: data, encoding: .utf8)
    {
        await context.hub.send(id: connectionID, text: frame)
    }
}

/// Cancels one in-flight tool call over WebSocket, leaving its turn running.
///
/// The bus injects the cancellation as the call's failure result so the model
/// re-scopes and continues; the terminal `tool_end` frame follows the normal
/// event path, so a successful cancel needs no extra acknowledgement. Every
/// outcome that stops nothing — a settled call, an unowned call, or a rejected
/// identifier — reports through the dedicated non-terminal miss frame rather
/// than ``WSErrorFrame``: a session-tagged `error` is a terminal turn failure to
/// the dashboard, so reusing it here would tear down a turn that is still
/// running. The miss frame lets the dashboard roll back only its optimistic
/// "cancelling" mark, matching the REST fallback.
/// - Parameters:
///   - message: Decoded per-tool cancel frame.
///   - connectionID: Socket that sent the request.
///   - context: Server context owning the tool bus.
func handleWebSocketToolCancel(_ message: WSToolCancelMessage, connectionID: UUID, context: ServerContext) async {
    do {
        let cancelled = try await cancelInFlightToolCall(
            callID: message.callID,
            sessionID: message.sessionID,
            reason: message.reason,
            context: context
        )
        guard !cancelled else { return }
        await sendToolCancelMiss(
            "No in-flight tool call '\(message.callID)' for this session",
            callID: message.callID,
            connectionID: connectionID,
            context: context,
            sessionID: message.sessionID
        )
    } catch let abort as Abort {
        await sendToolCancelMiss(
            abort.reason,
            callID: message.callID,
            connectionID: connectionID,
            context: context,
            sessionID: message.sessionID
        )
    } catch {
        await sendToolCancelMiss(
            error.localizedDescription,
            callID: message.callID,
            connectionID: connectionID,
            context: context,
            sessionID: message.sessionID
        )
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
        duration: message.resolvedDuration,
        widen: message.resolvedWiden
    )
    guard resolved else {
        await sendWSError("Unknown approval \(message.id.uuidString)", connectionID: connectionID, context: context)
        return
    }
    // Durable approvals create a stored grant inside `decide`, so
    // dashboards need a refresh signal; one-shot approvals store
    // nothing and leave the grants list untouched. Continuation
    // approvals stay one-shot inside `decide` (coerced to thisTime
    // with no stored grant), so a durable vote on engine.continue
    // must not fire a refresh when nothing changed.
    if message.approved, message.resolvedDuration != .thisTime, pending?.toolName != "engine.continue" {
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

/// Sends one non-terminal per-tool cancel miss frame through the hub, best-effort.
///
/// Kept separate from ``sendWSError`` because the dashboard treats an owned
/// `error` as a terminal turn failure: routing a per-tool miss through that path
/// would drop a live turn's accumulated segments over a cancel that stopped
/// nothing. The dedicated shape only clears the target row's optimistic mark,
/// so this helper must never carry a turn-ending meaning.
/// - Parameters:
///   - message: Human-readable, non-terminal explanation.
///   - callID: Correlation identifier of the call that could not be cancelled.
///   - connectionID: Socket that requested the cancel.
///   - context: Server context owning the hub.
///   - sessionID: Owning session, when the request was scoped to one.
func sendToolCancelMiss(
    _ message: String,
    callID: String,
    connectionID: UUID,
    context: ServerContext,
    sessionID: UUID? = nil
) async {
    if Task.isCancelled {
        return
    }
    let miss = WSToolCancelMissFrame(sessionID: sessionID, callID: callID, message: message)
    guard let data = try? JSONEncoder().encode(miss),
          let frame = String(data: data, encoding: .utf8)
    else { return }
    await context.hub.send(id: connectionID, text: frame)
}

// Rune Weaver Server — WebSocket chat, cancel, and approval handlers.

import Foundation
import os
import RuneWeaverCore
import Vapor

/// Tracks in-flight approval resumes for one WebSocket connection.
final class ConnectionChatTasks: Sendable {
    /// One slot: awaiting its task, holding it, or already cancelled.
    /// Sendable so the lock-protected table stays within Swift 6 isolation.
    enum Slot: Sendable {
        case reserved
        case task(Task<Void, Never>)
        case cancelled
    }

    /// Locked table plus whether the socket has closed.
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

    /// Tracks a resume task until it completes.
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

    /// Stops tracking a completed resume task.
    /// - Parameter id: Tracking identifier from `insert`.
    func remove(id: UUID) {
        _ = state.withLock { $0.slots.removeValue(forKey: id) }
    }

    /// Cancels every tracked resume task.
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
struct ChatTurnAuditSnapshot: Sendable {
    /// Assistant text streamed before the failure, possibly empty.
    let partialText: String
    /// Assistant reasoning streamed before the failure, possibly empty.
    let partialReasoning: String
    /// Tool actions completed or started before the failure.
    let toolActions: [ToolAction]
    /// Billed total accumulated before the failure, when reported.
    let totalTokens: Int?

    /// Creates a snapshot.
    init(
        partialText: String,
        partialReasoning: String = "",
        toolActions: [ToolAction],
        totalTokens: Int? = nil
    ) {
        self.partialText = partialText
        self.partialReasoning = partialReasoning
        self.toolActions = toolActions
        self.totalTokens = totalTokens
    }
}

/// Accumulates mid-turn audit progress from orchestrator events so error paths keep partial
/// context.
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
        var partialReasoning = ""
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
            case let .reasoningDelta(delta):
                locked.partialReasoning += delta
            case let .turnTokens(_, _, turnTotalTokens, _):
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
                partialReasoning: locked.partialReasoning,
                toolActions: actions,
                totalTokens: locked.totalTokens
            )
        }
    }
}

/// Authorizes a WebSocket upgrade at the route boundary.
func isAllowedWebSocketOrigin(_ origin: String, request: Request) -> Bool {
    guard let originURL = URL(string: origin), let rawOriginHost = originURL.host, !rawOriginHost.isEmpty else {
        return false
    }
    if rawOriginHost == "." || rawOriginHost.hasSuffix(".") {
        return false
    }
    let originHost = canonicalWebSocketHost(rawOriginHost)
    if originHost.isEmpty || originHost == "." || originHost.hasSuffix(".") {
        return false
    }

    let originScheme = originURL.scheme?.lowercased()
    let isSecureOrigin = originScheme == "https" || originScheme == "wss"
    let originPort = originURL.port ?? (isSecureOrigin ? 443 : 80)

    let serverPort = request.application.runeWeaver.config.port
    let hostHeader = request.headers.first(name: .host)
    let hostPort: Int? = if let hostHeader {
        extractWebSocketPort(from: hostHeader)
    } else {
        nil
    }

    // Loopback hosts: origin port must match the server's configured port or Host header port
    if originHost == "127.0.0.1" || originHost == "localhost" || originHost == "::1" {
        if originPort == serverPort || (hostPort != nil && originPort == hostPort) {
            return true
        }
        return false
    }

    // Configured server hostname under the same normalization:
    let serverHost = canonicalWebSocketHost(request.application.runeWeaver.config.hostname)
    if !serverHost.isEmpty, serverHost != ".", !serverHost.hasSuffix("."), originHost == serverHost {
        if originPort == serverPort || (hostPort != nil && originPort == hostPort) {
            return true
        }
        return false
    }

    // Reverse-proxy parity: the request Host already passed
    // HostValidationMiddleware, so an Origin matching that validated Host is
    // the same site served under a proxy name rather than a cross-site page.
    if let hostHeader {
        let rawRequestHost = HostValidationMiddleware.extractHost(from: hostHeader)
        if rawRequestHost.isEmpty || rawRequestHost == "." || rawRequestHost.hasSuffix(".") {
            return false
        }
        let requestHost = canonicalWebSocketHost(rawRequestHost)
        if requestHost.isEmpty || requestHost == "." || requestHost.hasSuffix(".") {
            return false
        }
        if requestHost == originHost {
            if let hostPort {
                if originPort == hostPort {
                    return true
                }
            } else {
                if originPort == 80 || originPort == 443 || originPort == serverPort {
                    return true
                }
            }
        }
    }
    return false
}

/// Extracts an explicit port number from a Host header if present.
private func extractWebSocketPort(from hostHeader: String) -> Int? {
    let trimmed = hostHeader.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("[") {
        if let closingBracketIndex = trimmed.firstIndex(of: "]") {
            let after = trimmed[trimmed.index(after: closingBracketIndex)...]
            if after.hasPrefix(":") {
                return Int(after.dropFirst())
            }
        }
        return nil
    }
    if let colonIndex = trimmed.firstIndex(of: ":"), colonIndex == trimmed.lastIndex(of: ":") {
        let portPart = trimmed[trimmed.index(after: colonIndex)...]
        return Int(portPart)
    }
    return nil
}

/// Canonicalizes one host for WebSocket Origin comparison.
private func canonicalWebSocketHost(_ raw: String) -> String {
    var normalized = ServerEndpointConfig.normalizeHost(raw)
    if normalized.hasPrefix("["), normalized.hasSuffix("]"), normalized.count >= 2 {
        normalized = String(normalized.dropFirst().dropLast())
    }
    return normalized
}

/// - Parameter request: Upgrade handshake request.
/// - Returns: Empty headers to proceed, or nil to refuse the upgrade.
func authorizeWebSocketUpgrade(_ request: Request) -> HTTPHeaders? {
    if let origin = request.headers.first(name: .origin) {
        guard isAllowedWebSocketOrigin(origin, request: request) else {
            return nil
        }
    }
    guard request.application.runeWeaverAuth != nil else {
        return [:]
    }
    return request.runeWeaverAuthenticated ? [:] : nil
}

/// Handles one inbound WebSocket text frame.
func handleWebSocketText(
    _ text: String,
    connectionID: UUID,
    context: ServerContext,
    connectionTasks: ConnectionChatTasks,
    pulse: SystemHealthSnapshot? = nil
) async {
    guard !Task.isCancelled else { return }
    switch WSInboundKind.classify(text) {
    case let .chat(message):
        await handleWebSocketChat(message, connectionID: connectionID, context: context)
    case let .cancel(message):
        await handleWebSocketCancel(message, connectionID: connectionID, context: context)
    case let .toolCancel(message):
        await handleWebSocketToolCancel(message, connectionID: connectionID, context: context)
    case let .decision(message):
        let scopeOutcome = wsDecisionScope(from: text)
        if scopeOutcome.invalid {
            // A present-but-undecodable scope fails closed rather than
            // approving without the scope the owner chose.
            await sendWSError(
                "Unknown decision scope",
                connectionID: connectionID,
                context: context
            )
            return
        }
        await handleWebSocketDecision(
            message,
            scope: scopeOutcome.scope,
            connectionID: connectionID,
            context: context,
            connectionTasks: connectionTasks,
            pulse: pulse
        )
    case .unknown:
        let hint = "Expected a chat frame {\"text\": \"...\"}, a decision frame, a cancel frame, or a tool_cancel frame"
        await sendWSError(hint, connectionID: connectionID, context: context)
    }
}

/// Encodes an Encodable payload to JSON UTF-8 text, logging any failure.
func encodeWSFrame<T: Encodable>(_ value: T) -> String? {
    do {
        let data = try JSONEncoder().encode(value)
        return String(data: data, encoding: .utf8)
    } catch {
        RuneWeaverLog.server.error("RuneWeaverServerWebSocket: failed to encode \(T.self): \(error.localizedDescription)")
        return nil
    }
}

/// Encodes an orchestrator event to its shared WebSocket wire text, if any.
func wsEventFrameText(_ event: OrchestratorEvent, sessionID: UUID) -> String? {
    switch event {
    case let .toolStarted(toolName, callID, argumentsJSON, roundIndex):
        encodeWSFrame(
            WSToolStartFrame(
                toolName: toolName,
                callID: callID,
                argumentsJSON: argumentsJSON,
                sessionID: sessionID,
                roundIndex: roundIndex
            )
        )
    case let .toolCompleted(toolName, callID, result, roundIndex):
        encodeWSFrame(
            WSToolEndFrame(
                toolName: toolName,
                callID: callID,
                result: result,
                sessionID: sessionID,
                roundIndex: roundIndex
            )
        )
    case let .textDelta(delta):
        encodeWSFrame(WSStreamDelta(delta: delta, sessionID: sessionID))
    case let .reasoningDelta(delta):
        encodeWSFrame(WSStreamReasoningDelta(delta: delta, sessionID: sessionID))
    case let .warning(message):
        // Degraded-tool notices stream as warning frames so clients surface skips
        // mid-turn without failing the turn; the terminal done frame repeats them.
        encodeWSFrame(WSWarningFrame(message: message, sessionID: sessionID))
    case let .turnTokens(roundIndex, roundTokens, turnTotalTokens, contextTokens):
        // Per-round usage progress for the live footer: session-tagged so multiplexed
        // views only apply their own turn and older clients drop the unknown type.
        // The terminal done frame stays authoritative for reconciliation.
        encodeWSFrame(
            WSTurnTokensFrame(
                sessionID: sessionID,
                roundIndex: roundIndex,
                roundTokens: roundTokens,
                turnTotalTokens: turnTotalTokens,
                contextTokens: contextTokens
            )
        )
    case let .toolProgress(progress):
        // Generic indeterminate progress from a running tool: session-tagged so multiplexed views
        // only apply their own turn and older clients drop the unknown type.
        encodeWSFrame(WSToolProgressFrame(progress, sessionID: sessionID))
    case .approval:
        nil
    }
}

/// Broadcasts one orchestrator event to every connected WebSocket client.
func broadcastWSEventFrame(_ event: OrchestratorEvent, sessionID: UUID, hub: WSHub) async {
    guard !Task.isCancelled else {
        return
    }
    if case let .approval(request) = event {
        await hub.broadcastApproval(request)
        return
    }
    if case .toolProgress = event {
        if let frameText = wsEventFrameText(event, sessionID: sessionID) {
            Task { await hub.broadcast(text: frameText) }
        }
        return
    }
    if let frameText = wsEventFrameText(event, sessionID: sessionID) {
        await hub.broadcast(text: frameText)
    }
}

/// Convenience overload for call sites with a ServerContext.
func broadcastWSEventFrame(_ event: OrchestratorEvent, sessionID: UUID, context: ServerContext) async {
    await broadcastWSEventFrame(event, sessionID: sessionID, hub: context.hub)
}

/// Broadcasts a terminal stream done frame to every connected WebSocket client.
func broadcastStreamDone(
    for response: OrchestratorResponse,
    sessionID: UUID,
    hub: WSHub,
    steeringQueue: SteeringQueue? = nil
) async {
    var done = WSStreamDone(from: response)
    if let steeringQueue {
        done.retainedSteerCount = await steeringQueue.pendingCount(for: sessionID)
    }
    if let frame = encodeWSFrame(done) {
        await hub.broadcast(text: frame)
    }
}

/// Executes a chat turn over WebSocket with real-time streaming and cooperative cancellation.
func handleWebSocketChat(_ message: WSChatMessage, connectionID: UUID, context: ServerContext) async {
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

    // Steering frames never start a fresh turn: they either join the live turn or fail honestly so
    // the dashboard can roll back its optimistic bubble.
    if message.steer == true {
        guard await context.activeTurns.isActive(sessionID: sessionID) else {
            await sendWSError(
                "No active turn for this session. Steering was not applied. Send as a new message.",
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
                "Turn ended before steering arrived. It missed the in-flight turn. Send as a new message.",
                connectionID: connectionID,
                context: context,
                sessionID: sessionID
            )
            return
        }
        return
    }

    // Bound parallel turns so slow local inference never stacks silently: the acquire and the
    // registration happen in one tracker hop, so concurrent fresh sessions cannot both slip past the
    // cap.
    let taskBox = TurnTaskBox()
    guard let registration = await context.activeTurns.tryAcquire(sessionID: sessionID, onCancel: { taskBox.cancel() }) else {
        await sendWSError(
            "Already running \(ActiveTurnTracker.maxConcurrentTurns) chat turns. Wait for one to finish or cancel it, then retry.",
            connectionID: connectionID,
            context: context,
            sessionID: sessionID
        )
        return
    }
    // Publish the running row immediately so dashboards badge the background session from the run
    // log even before the first delta streams; the terminal paths below update this same row instead
    // of appending a second, keeping one audit entry per turn.
    let initialEntry = await context.runs.append(
        kind: "chat",
        status: "running",
        message: trimmed,
        sessionID: sessionID,
        durationMs: 0
    )
    await context.hub.broadcastRun(initialEntry)
    // Detached ownership: the tracker slot plus this task own the turn, so no connection-table
    // reserve/insert follows.
    let params = WebSocketTurnParameters(
        context: context,
        connectionID: connectionID,
        sessionID: sessionID,
        source: source,
        trimmed: trimmed,
        registration: registration,
        initialEntry: initialEntry
    )
    let chatTask: Task<Void, Never> = Task {
        await executeWebSocketTurn(params: params)
    }
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
    let initialEntry: RunLogEntry
}

/// Runs one chat turn's liveness heartbeat, inference process, and status updates.
private func executeWebSocketTurn(params: WebSocketTurnParameters) async {
    let context = params.context
    let sessionID = params.sessionID
    let source = params.source
    let trimmed = params.trimmed
    let registration = params.registration
    let initialEntry = params.initialEntry

    let startTime = Date()
    let heartbeat = startHeartbeat(context: context, sessionID: sessionID)
    defer { heartbeat.cancel() }
    let auditProgress = ChatTurnAuditProgress()
    await context.activeTurns.registerSnapshotProvider(sessionID: sessionID) {
        let snap = auditProgress.snapshot()
        return LiveTurnSnapshot(
            sessionID: sessionID,
            text: snap.partialText,
            reasoning: snap.partialReasoning,
            toolActions: snap.toolActions,
            totalTokens: snap.totalTokens
        )
    }
    do {
        let response = try await context.orchestrator.process(
            input: UserInput(
                text: trimmed,
                sessionID: sessionID,
                source: source.isEmpty ? "websocket" : source
            ),
            onEvent: { event in
                auditProgress.record(event)
                await broadcastWSEventFrame(event, sessionID: sessionID, context: context)
            }
        )
        guard !Task.isCancelled else {
            await handleWebSocketTurnCancellation(
                context: context,
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
            sessionID: sessionID,
            registrationToken: registration.token,
            initialEntry: initialEntry,
            startTime: startTime
        )
    } catch {
        guard !Task.isCancelled else {
            await handleWebSocketTurnCancellation(
                context: context,
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
    // Release the tracker slot before publishing the terminal row so observers polling the run log
    // never see a settled row with a stale active slot.
    await context.activeTurns.unregister(sessionID: params.sessionID, token: params.registration.token)
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
    if let frame = encodeWSFrame(done) {
        await context.hub.broadcast(text: frame)
    }
}

/// Persists a failed WebSocket turn keeping the same audit shape as success.
private func finishWebSocketFailedTurn(
    params: WebSocketTurnParameters,
    error: Error,
    audit: ChatTurnAuditSnapshot,
    startTime: Date
) async {
    let context = params.context
    let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
    let auditResponse = audit.partialText.isEmpty ? error.localizedDescription : audit.partialText
    // Release the tracker slot before publishing the terminal row so observers
    // polling the run log never see a settled row with a stale active slot,
    // matching the REST turn ordering.
    await context.activeTurns.unregister(sessionID: params.sessionID, token: params.registration.token)
    let entry = await context.runs.update(
        id: params.initialEntry.id,
        status: "error",
        response: auditResponse,
        toolActions: audit.toolActions,
        totalTokens: audit.totalTokens,
        durationMs: durationMs
    ) ?? params.initialEntry
    await context.hub.broadcastRun(entry)
    let errorReasoning: String? = audit.partialReasoning.isEmpty ? nil : audit.partialReasoning
    let errorMessage = Message(
        role: .assistant,
        content: "Error: \(error.localizedDescription)",
        isError: true,
        reasoning: errorReasoning
    )
    await context.conversations.append(errorMessage, to: params.sessionID)
    if let frame = encodeWSFrame(WSErrorFrame(message: error.localizedDescription, sessionID: params.sessionID)) {
        await context.hub.broadcast(text: frame)
    }
}

/// Settles a cancelled WebSocket turn and notifies every viewer. Cancellation arrives only through
/// explicit cancel or same-session supersede; the run row updates in place so the turn keeps one
/// audit entry.
private func handleWebSocketTurnCancellation(
    context: ServerContext,
    sessionID: UUID,
    registrationToken: UUID,
    initialEntry: RunLogEntry,
    startTime: Date
) async {
    await settleTurnCancelled(context: context, sessionID: sessionID, token: registrationToken, entry: initialEntry, startTime: startTime)
}

/// Spawns a background liveness heartbeat task for long inference turns.
private func startHeartbeat(context: ServerContext, sessionID: UUID) -> Task<Void, Never> {
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
                await context.hub.broadcast(text: alive)
            }
        }
    }
}

/// Cancels an in-flight chat turn over WebSocket. The tracker stop plus steering clear settle the
/// turn, while this acknowledgement answers only the requesting socket: it reports whether a running
/// turn was actually stopped.
func handleWebSocketCancel(_ message: WSCancelMessage, connectionID: UUID, context: ServerContext) async {
    var cancelled = false
    if let sid = message.sessionID {
        cancelled = await requestTurnCancellation(context: context, sessionID: sid)
    }
    let cancelledFrame = WSCancelledFrame(sessionID: message.sessionID, cancelled: cancelled)
    if let frame = encodeWSFrame(cancelledFrame) {
        await context.hub.send(id: connectionID, text: frame)
    }
}

/// Cancels one in-flight tool call over WebSocket, leaving its turn running.
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
func handleWebSocketDecision(
    _ message: WSDecisionMessage,
    scope: AccessScope? = nil,
    connectionID: UUID,
    context: ServerContext,
    connectionTasks: ConnectionChatTasks,
    pulse: SystemHealthSnapshot? = nil
) async {
    guard !Task.isCancelled else {
        return
    }
    let pending = await context.approvals.request(id: message.id)
    let approvalID = message.id
    let outcome = await applyApprovalDecision(
        input: ApprovalDecisionInput(
            id: message.id,
            approved: message.approved,
            duration: message.resolvedDuration,
            scope: scope,
            pending: pending,
            surface: "websocket"
        ),
        pulse: pulse,
        context: context,
        spawnResume: { effectiveApproved in
            guard let resumeSessionID = pending?.sessionID else { return }
            // Reserve before spawning so a close landing in the gap parks as cancelled and the
            // insert aborts immediately; the defer removes the slot on every terminal path so the
            // table never retains finished resumes.
            let trackingID = UUID()
            connectionTasks.reserve(id: trackingID)
            let decidedCallID = pending?.input.callID
            let resumeTask: Task<Void, Never> = Task { [weak connectionTasks] in
                defer { connectionTasks?.remove(id: trackingID) }
                guard !Task.isCancelled else { return }
                await resumeNarratedApproval(
                    id: approvalID,
                    approved: effectiveApproved,
                    context: context,
                    sessionID: resumeSessionID,
                    decidedCallID: decidedCallID
                )
            }
            connectionTasks.insert(resumeTask, id: trackingID)
        }
    )
    switch outcome {
    case .resolved:
        break
    case .unknown:
        await sendWSError("Unknown approval \(message.id.uuidString)", connectionID: connectionID, context: context)
    case .questionRequiresRespond:
        // Operator choices ride the answer-bearing respond path so an approval
        // without a choice cannot synthesize an empty acknowledgement.
        await sendWSError(
            "Use /respond for question.ask",
            connectionID: connectionID,
            context: context,
            sessionID: pending?.sessionID
        )
    case .systemNoticeRequiresRemedy:
        // Resolution is never a decision for a system notice: the triage
        // reports the refusal instead of resolving or minting trust.
        await sendWSError(
            "System notices settle through their mapped remedy, not a decision",
            connectionID: connectionID,
            context: context,
            sessionID: pending?.sessionID
        )
    case let .sideEffectFailed(reason):
        // The requester learns the decision could not be applied instead of
        // the approval silently resolving as approved.
        await sendWSError(reason, connectionID: connectionID, context: context)
    }
}

/// Fail-closed decode of the decision scope from a raw decision frame.
private struct WSDecisionScopeOutcome: Sendable {
    /// Decoded scope, nil for decisions without an explicit scope.
    let scope: AccessScope?
    /// True when the key was present but failed strict decoding.
    let invalid: Bool
}

private func wsDecisionScope(from text: String) -> WSDecisionScopeOutcome {
    guard let data = text.data(using: .utf8),
          let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any], raw.keys.contains("scope")
    else {
        return WSDecisionScopeOutcome(scope: nil, invalid: false)
    }
    // A JSON null scope reads as no explicit scope; any other present value
    // must strictly decode or the frame fails closed.
    if raw["scope"] is NSNull {
        return WSDecisionScopeOutcome(scope: nil, invalid: false)
    }
    struct DecisionFields: Decodable {
        var scope: AccessScopeDTO?
        enum CodingKeys: String, CodingKey { case scope }
    }
    let fields: DecisionFields
    do {
        fields = try JSONDecoder().decode(DecisionFields.self, from: data)
    } catch {
        RuneWeaverLog.server.debug("decodeDecisionScope: failed to decode scope: \(error.localizedDescription)")
        return WSDecisionScopeOutcome(scope: nil, invalid: true)
    }
    guard let scope = fields.scope, let canonical = scope.accessScope() else {
        return WSDecisionScopeOutcome(scope: nil, invalid: true)
    }
    return WSDecisionScopeOutcome(scope: canonical, invalid: false)
}

/// Sends one requester-scoped error frame through the hub, best-effort.
func sendWSError(_ message: String, connectionID: UUID, context: ServerContext, sessionID: UUID? = nil) async {
    if Task.isCancelled {
        return
    }
    guard let frame = encodeWSFrame(WSErrorFrame(message: message, sessionID: sessionID)) else { return }
    await context.hub.send(id: connectionID, text: frame)
}

/// Sends one non-terminal per-tool cancel miss frame through the hub, best-effort.
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
    guard let frame = encodeWSFrame(miss) else { return }
    await context.hub.send(id: connectionID, text: frame)
}

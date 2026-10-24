// Rune Weaver Server — REST chat routes.

import Foundation
import RuneWeaverCore
import Vapor

/// Registers the REST chat execution, cancel, and tool-cancel routes.
/// - Parameter app: Application receiving the routes.
func registerChatRoute(_ app: Application) {
    app.post(PathComponent.constant(ServerPaths.chat)) { req async throws -> OrchestratorResponse in
        let body = try req.content.decode(ChatRequest.self)
        let text = try validatedChatText(body.text)
        let context = req.application.runeWeaver
        let sessionID = body.resolvedSessionID
        let startTime = Date()

        // Bound parallel turns the same way as the WebSocket path so the REST fallback cannot stack
        // unbounded: the acquire and the registration happen in one tracker hop, so concurrent fresh
        // sessions cannot both slip past the cap.
        let taskBox = TurnTaskBox()
        guard let registration = await context.activeTurns.tryAcquire(sessionID: sessionID, onCancel: { taskBox.cancel() }) else {
            throw Abort(
                .tooManyRequests,
                reason: "Already running \(ActiveTurnTracker.maxConcurrentTurns) chat turns. Wait for one to finish or cancel it, then retry."
            )
        }
        // Publish the running row immediately so dashboards badge the session from the run log even
        // before inference streams; every terminal path below updates this same row instead of
        // appending a second, keeping one audit entry per turn like the WebSocket path.
        let initialEntry = await context.runs.append(
            kind: "chat",
            status: "running",
            message: text,
            sessionID: sessionID,
            durationMs: 0
        )
        await context.hub.broadcastRun(initialEntry)
        // Accumulate partial tool/text/token progress so the error path persists the
        // same response/toolActions/totalTokens shape as success instead of a tool-less
        // row; success keeps using the authoritative response verbatim.
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
        let chatTask: Task<OrchestratorResponse, Error> = Task {
            try await context.orchestrator.process(
                input: UserInput(
                    text: text,
                    sessionID: sessionID,
                    source: body.resolvedSource
                ),
                onEvent: { event in
                    auditProgress.record(event)
                    await forwardRESTChatEvent(event, sessionID: sessionID, context: context)
                }
            )
        }
        taskBox.set(chatTask)
        // REST keeps one broadcast heartbeat per turn so multi-viewer dashboards
        // stay live while prompt evaluation is silent; the helper owns the why.
        let heartbeat = startRESTChatHeartbeat(context: context, sessionID: sessionID)
        defer { heartbeat.cancel() }

        do {
            // Tie the inner turn to the request lifetime so a disconnect cancels the model and
            // tools instead of leaving them running with no client, matching the WebSocket close
            // path.
            let response = try await withTaskCancellationHandler {
                try await chatTask.value
            } onCancel: {
                chatTask.cancel()
            }
            // A late cancel between process return and settle takes the cancellation path so no done is emitted.
            guard !Task.isCancelled else {
                await settleTurnCancelled(context: context, sessionID: sessionID, token: registration.token, entry: initialEntry, startTime: startTime)
                throw Abort(.gone, reason: "Turn was cancelled by user")
            }
            await context.activeTurns.unregister(sessionID: sessionID, token: registration.token)
            // Parked approval-gated turns persist as awaiting_approval instead of ok so the inbox
            // decision can transition the same session entry. The per-turn parked flag keeps a
            // stale prior park in this session from mis-marking a fresh normal turn.
            await broadcastParkedApprovals(for: response, context: context)
            // The terminal response carries the content-free recall summary verbatim
            // so REST turns surface per-tier counts plus the skip flag with no extra lookup.
            let parkedStatus = if response.isParked {
                "awaiting_approval"
            } else {
                "ok"
            }
            await updateRESTChatRunAndBroadcast(
                context: context,
                initialEntry: initialEntry,
                startTime: startTime,
                status: parkedStatus,
                response: response
            )
            return response
        } catch is CancellationError {
            await settleTurnCancelled(context: context, sessionID: sessionID, token: registration.token, entry: initialEntry, startTime: startTime)
            throw Abort(.gone, reason: "Turn was cancelled by user")
        } catch {
            // A failure racing a cancel still settles as cancelled so no error overwrites it.
            if Task.isCancelled {
                await settleTurnCancelled(context: context, sessionID: sessionID, token: registration.token, entry: initialEntry, startTime: startTime)
                throw Abort(.gone, reason: "Turn was cancelled by user")
            }
            try await handleRESTChatError(
                error,
                context: context,
                turn: RESTChatErrorTurn(
                    sessionID: sessionID,
                    registrationToken: registration.token,
                    initialEntry: initialEntry,
                    startTime: startTime,
                    audit: auditProgress.snapshot()
                )
            )
        }
    }

    registerChatCancelRoute(app)
    registerChatToolCancelRoute(app)
}

/// Inputs for handling a failed REST chat turn without growing the handler signature.
struct RESTChatErrorTurn: Sendable {
    /// Owning session the failed turn belongs to.
    let sessionID: UUID
    /// Tracker token for the failed turn's slot.
    let registrationToken: UUID
    /// Running row published before inference started.
    let initialEntry: RunLogEntry
    /// Turn start for duration accounting.
    let startTime: Date
    /// Partial text, tool actions, and billed total accumulated before the failure.
    let audit: ChatTurnAuditSnapshot
}

/// Handles errors raised during a REST chat turn, persisting an error message and updating run
/// status.
private func handleRESTChatError(
    _ error: Error,
    context: ServerContext,
    turn: RESTChatErrorTurn
) async throws -> Never {
    await context.activeTurns.unregister(sessionID: turn.sessionID, token: turn.registrationToken)
    let errorReasoning: String? = turn.audit.partialReasoning.isEmpty ? nil : turn.audit.partialReasoning
    let errorMessage = Message(
        role: .assistant,
        content: "Error: \(error.localizedDescription)",
        isError: true,
        reasoning: errorReasoning
    )
    await context.conversations.append(errorMessage, to: turn.sessionID)
    await updateRESTChatRunAndBroadcast(
        context: context,
        initialEntry: turn.initialEntry,
        startTime: turn.startTime,
        status: "error",
        fallback: ChatTurnAuditSnapshot(
            partialText: turn.audit.partialText.isEmpty ? error.localizedDescription : turn.audit.partialText,
            partialReasoning: turn.audit.partialReasoning,
            toolActions: turn.audit.toolActions,
            totalTokens: turn.audit.totalTokens
        )
    )
    if let orchErr = error as? OrchestratorError {
        switch orchErr {
        case .emptyInput:
            throw Abort(.badRequest, reason: "text must not be empty")
        case let .toolLoopExceeded(iterations):
            throw Abort(.unprocessableEntity, reason: "Tool loop exceeded \(iterations) rounds")
        case let .llmFailed(detail):
            throw Abort(.badGateway, reason: detail)
        }
    }
    throw error
}

/// Forwards a REST turn's mid-turn progress to dashboard WebSocket clients.
private func forwardRESTChatEvent(_ event: OrchestratorEvent, sessionID: UUID, context: ServerContext) async {
    switch event {
    case .warning, .turnTokens, .toolProgress:
        await broadcastWSEventFrame(event, sessionID: sessionID, context: context)
    default:
        break
    }
}

/// Moves one REST turn's running audit row to its terminal state and broadcasts it.
private func updateRESTChatRunAndBroadcast(
    context: ServerContext,
    initialEntry: RunLogEntry,
    startTime: Date,
    status: String,
    response: OrchestratorResponse? = nil,
    fallback: ChatTurnAuditSnapshot? = nil
) async {
    let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
    let entry = await context.runs.update(
        id: initialEntry.id,
        status: status,
        response: response?.text ?? fallback?.partialText,
        toolActions: response?.toolActions ?? fallback?.toolActions,
        totalTokens: response?.totalTokens ?? fallback?.totalTokens,
        durationMs: durationMs
    ) ?? initialEntry
    await context.hub.broadcastRun(entry)
    if status == "error" || status == "failed" || status == "budget_exceeded" {
        let label = status == "budget_exceeded" ? "Tool Budget Exceeded" : "Chat Run Failed"
        let detail = entry.response ?? entry.message
        await context.notifier?.notify(
            title: "Rune Weaver: \(label)",
            body: detail.isEmpty ? "Chat turn failed to complete." : detail,
            identifier: "chat-run-\(entry.id.uuidString)"
        )
    }
}

/// Registers the REST cancellation endpoint sharing the same turn tracker.
/// - Parameter app: Application receiving the route.
private func registerChatCancelRoute(_ app: Application) {
    app.post(PathComponent.constant(ServerPaths.chat), PathComponent.constant("cancel")) { req async throws -> CancelChatResponse in
        let body = try req.content.decode(CancelChatRequest.self)
        let cancelled = await requestTurnCancellation(context: req.application.runeWeaver, sessionID: body.sessionID)
        return CancelChatResponse(sessionID: body.sessionID, cancelled: cancelled)
    }
}

/// Registers the REST per-tool cancellation endpoint.
private func registerChatToolCancelRoute(_ app: Application) {
    app.post(
        PathComponent.constant(ServerPaths.chat),
        PathComponent.constant(ServerPaths.toolCancel)
    ) { req async throws -> ToolCancelResponse in
        let body = try req.content.decode(ToolCancelRequest.self)
        let cancelled = try await cancelInFlightToolCall(
            callID: body.callID,
            sessionID: body.sessionID,
            reason: body.resolvedReason,
            context: req.application.runeWeaver
        )
        return ToolCancelResponse(
            sessionID: body.sessionID,
            callID: body.resolvedCallID ?? body.callID,
            cancelled: cancelled
        )
    }
}

/// Spawns the REST liveness heartbeat broadcast for one in-flight turn. context:
/// Server context owning the WebSocket hub.
private func startRESTChatHeartbeat(context: ServerContext, sessionID: UUID) -> Task<Void, Never> {
    Task { [context, sessionID] in
        // REST has no owning socket for multi-viewer turns so it broadcasts the session-tagged
        // heartbeat while the WebSocket path targets one socket.
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

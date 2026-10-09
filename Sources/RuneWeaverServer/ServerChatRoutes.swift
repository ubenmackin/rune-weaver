// Rune Weaver Server — REST chat routes.
//
// Owns the HTTP POST /chat, /chat/cancel, and /chat/tool-cancel routes backing
// clients when WebSocket is unavailable or for headless scripting turns.

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

        // Bound parallel turns the same way as the WebSocket path so the REST
        // fallback cannot stack unbounded: the acquire and the registration
        // happen in one tracker hop, so concurrent fresh sessions cannot both
        // slip past the cap. A replacement turn for the same session always
        // fits (it supersedes the prior slot). Register before spawning so a
        // fast turn can never finish before its slot exists; the box bridges
        // a cancel arriving in that gap to the task created just below,
        // matching `handleWebSocketChat`.
        let taskBox = TurnTaskBox()
        guard let registration = await context.activeTurns.tryAcquire(sessionID: sessionID, onCancel: { taskBox.cancel() }) else {
            throw Abort(
                .tooManyRequests,
                reason: "Already running \(ActiveTurnTracker.maxConcurrentTurns) chat turns — wait for one to finish or cancel it, then retry."
            )
        }
        // Publish the running row immediately so dashboards badge the session
        // from the run log even before inference streams; every terminal path
        // below updates this same row instead of appending a second, keeping
        // one audit entry per turn like the WebSocket path.
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
            await context.activeTurns.unregister(sessionID: sessionID, token: registration.token)
            // Parked approval-gated turns persist as awaiting_approval instead of ok so the inbox
            // decision can transition the same session entry. The per-turn parked flag keeps a
            // stale prior park in this session from mis-marking a fresh normal turn.
            await broadcastParkedApprovals(for: response, context: context)
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
            await context.activeTurns.unregister(sessionID: sessionID, token: registration.token)
            // Clear queued steering on cancel so stale guidance does not leak into the next turn.
            await context.steeringQueue.clear(for: sessionID)
            await updateRESTChatRunAndBroadcast(
                context: context,
                initialEntry: initialEntry,
                startTime: startTime,
                status: "cancelled"
            )
            throw Abort(.gone, reason: "Turn was cancelled by user")
        } catch {
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
///
/// Bundles the per-turn audit row plus the accumulated partial snapshot so the
/// error handler stays inside the parameter budget while keeping the same
/// single-entry audit shape as success.
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

/// Handles errors raised during a REST chat turn, persisting an error message and updating run status.
///
/// Error rows keep the same single-entry shape as success: partial assistant text when streamed
/// (else the error detail so the row is never response-less) plus the tools that already ran and
/// their billed total, so the audit entry matches the tools the client already rendered live.
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
///
/// REST has no stream, but dashboard WebSocket clients still deserve mid-turn
/// progress. Forward session-tagged warnings, per-round token usage, and generic
/// tool progress through the shared broadcast helper so REST and resume share one
/// session-filtered path and clients ignore other sessions; failures never fail the
/// turn. The terminal response stays authoritative for reconciliation.
/// - Parameters:
///   - event: Orchestrator event emitted by the running turn.
///   - sessionID: Session the turn belongs to, kept for client-side filtering.
///   - context: Server context owning the broadcast hub.
private func forwardRESTChatEvent(_ event: OrchestratorEvent, sessionID: UUID, context: ServerContext) async {
    switch event {
    case .warning, .turnTokens, .toolProgress:
        await broadcastWSEventFrame(event, sessionID: sessionID, context: context)
    default:
        break
    }
}

/// Moves one REST turn's running audit row to its terminal state and broadcasts it.
/// Every terminal path funnels through this single update so the run log keeps
/// one entry per turn and REST stays in parity with the WebSocket path, which
/// updates the same initial row instead of appending a second.
/// - Parameters:
///   - context: Server context owning the run store and broadcast hub.
///   - initialEntry: Running row published before inference started.
///   - startTime: Turn start for duration accounting.
///   - status: Terminal status (`ok`, `awaiting_approval`, `cancelled`, or `error`).
///   - response: Successful turn output, when the turn produced one.
///   - fallback: Partial text, tool actions, and billed total for failure paths without a response.
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
}

/// Registers the REST cancellation endpoint sharing the same turn tracker.
/// - Parameter app: Application receiving the route.
private func registerChatCancelRoute(_ app: Application) {
    app.post(PathComponent.constant(ServerPaths.chat), PathComponent.constant("cancel")) { req async throws -> CancelChatResponse in
        let body = try req.content.decode(CancelChatRequest.self)
        let cancelled = await req.application.runeWeaver.activeTurns.cancel(sessionID: body.sessionID)
        LLMCancelRegistry.shared.cancel(sessionID: body.sessionID)
        // Clear queued steering on cancel so stale guidance does not leak into the next turn.
        await req.application.runeWeaver.steeringQueue.clear(for: body.sessionID)
        let cancelledRuns = await req.application.runeWeaver.runs.cancelRunning(sessionID: body.sessionID)
        for run in cancelledRuns {
            await req.application.runeWeaver.hub.broadcastRun(run)
        }
        return CancelChatResponse(sessionID: body.sessionID, cancelled: cancelled || !cancelledRuns.isEmpty)
    }
}

/// Registers the REST per-tool cancellation endpoint.
///
/// Distinct from the turn-wide cancel route above: this aborts exactly one
/// running tool and leaves its turn alive, so the injected failure can steer the
/// model instead of ending the request. The tool bus owns the call registry and
/// the injected result, keeping REST and WebSocket cancellations on one path.
/// - Parameter app: Application receiving the route.
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

/// Spawns the REST liveness heartbeat broadcast for one in-flight turn.
/// - Parameters:
///   - context: Server context owning the WebSocket hub.
///   - sessionID: Session tagging the heartbeat frames.
/// - Returns: Heartbeat task cancelling with the turn.
private func startRESTChatHeartbeat(context: ServerContext, sessionID: UUID) -> Task<Void, Never> {
    Task { [context, sessionID] in
        // REST has no owning socket for multi-viewer turns so it broadcasts the
        // session-tagged heartbeat while the WebSocket path targets one socket.
        // Exactly one timer runs per REST turn; the caller cancels it on every
        // terminal path so concurrent heartbeats stay bounded to one per turn.
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

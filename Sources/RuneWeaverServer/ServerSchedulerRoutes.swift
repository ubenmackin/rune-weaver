// Rune Weaver Server — Scheduler routes and parked-turn resume helpers.

import Foundation
import RuneWeaverCore
import Vapor

/// Whether a session currently has a parked narrated turn awaiting approval.
func isParkedTurn(sessionID: UUID, context: ServerContext) async -> Bool {
    await context.orchestrator.isSessionParked(sessionID)
}

/// Broadcasts filed narrated approvals for a parked turn.
func broadcastParkedApprovals(for response: OrchestratorResponse, approvals: ApprovalQueue, hub: WSHub) async {
    guard response.isParked else {
        return
    }
    let callIDs = Set(response.toolActions.map(\.callID))
    guard !callIDs.isEmpty else {
        return
    }
    let pending = await approvals.requests(for: response.sessionID)
    for request in pending where callIDs.contains(request.input.callID) {
        await hub.broadcastApproval(request)
    }
}

/// Convenience overload for call sites with a ServerContext.
func broadcastParkedApprovals(for response: OrchestratorResponse, context: ServerContext) async {
    await broadcastParkedApprovals(for: response, approvals: context.approvals, hub: context.hub)
}

/// Finds the awaiting or actively resuming run owning a resumed parked batch by call overlap.
func awaitingParkedRun(
    for resumed: OrchestratorResponse,
    decidedCallID: String?,
    context: ServerContext
) async -> RunLogEntry? {
    let candidates = await context.runs.list(limit: 200, sessionID: resumed.sessionID).filter {
        $0.status == "running" || $0.status == "awaiting_approval"
    }
    guard !candidates.isEmpty else {
        return nil
    }
    if let decidedCallID, !decidedCallID.isEmpty, let match = candidates.first(where: { run in
        run.toolActions.contains { $0.callID == decidedCallID }
    }) {
        return match
    }
    let resumedCallIDs = Set(resumed.toolActions.map(\.callID))
    if !resumedCallIDs.isEmpty, let match = candidates.first(where: { run in
        run.toolActions.contains { resumedCallIDs.contains($0.callID) }
    }) {
        return match
    }
    return candidates.first
}

/// Finds the stranded running or awaiting run for a failed resume by call overlap.
func strandedParkedRun(
    sessionID: UUID,
    decidedCallID: String?,
    context: ServerContext
) async -> RunLogEntry? {
    let candidates = await context.runs.list(limit: 200, sessionID: sessionID).filter {
        $0.status == "running" || $0.status == "awaiting_approval"
    }
    guard !candidates.isEmpty else {
        return nil
    }
    if let decidedCallID, !decidedCallID.isEmpty, let match = candidates.first(where: { run in
        run.toolActions.contains { $0.callID == decidedCallID }
    }) {
        return match
    }
    return candidates.first
}

/// Resolves the final run status for a resumed narrated approval.
func resolvedResumeStatus(approved: Bool, resumed: OrchestratorResponse) -> String {
    if !approved, resumed.toolActions.isEmpty {
        return "denied"
    }
    if resumed.toolActions.isEmpty {
        return "error"
    }
    return "ok"
}

/// Resumes a parked approval in its tagged session, best-effort.
public func resumeNarratedApproval(
    id: UUID,
    approved: Bool,
    answer: String? = nil,
    context: ServerContext,
    sessionID: UUID? = nil,
    decidedCallID: String? = nil
) async {
    let targetSessionID: UUID? = if let sessionID {
        sessionID
    } else {
        await context.approvals.request(id: id)?.sessionID
    }

    // Decision broadcasts use the shared `WSApprovalDecidedFrame` wire shape so
    // REST, WebSocket, and dashboard inbox views stay in sync on one encoding.
    await context.hub.broadcastApprovalDecided(id: id, approved: approved, sessionID: targetSessionID)

    // If approving, immediately transition the run row to "running" and broadcast run_started
    // so Working Right Now stream and Chat history badge immediately reflect active execution.
    let awaitingRun: RunLogEntry? = if let targetSessionID {
        await strandedParkedRun(sessionID: targetSessionID, decidedCallID: decidedCallID, context: context)
    } else {
        nil
    }
    if approved, let awaiting = awaitingRun {
        let runningEntry = await context.runs.update(
            id: awaiting.id,
            status: "running"
        ) ?? awaiting
        await context.hub.broadcastRun(runningEntry)
    }

    // Track the resumed turn in ActiveTurnTracker and seed ChatTurnAuditProgress with prior
    // completed actions so mid-turn page refreshes (GET /sessions/:id/live-turn) see active=true
    // along with both pre-park and post-park tool actions.
    let auditProgress = ChatTurnAuditProgress(initialActions: awaitingRun?.toolActions ?? [])
    let taskBox = TurnTaskBox()
    var registration: TurnRegistration?
    if let targetSessionID {
        let reg = await context.activeTurns.register(
            sessionID: targetSessionID,
            onCancel: { taskBox.cancel() }
        )
        registration = reg
        await context.activeTurns.registerSnapshotProvider(sessionID: targetSessionID) {
            let snap = auditProgress.snapshot()
            return LiveTurnSnapshot(
                sessionID: targetSessionID,
                text: snap.partialText,
                reasoning: snap.partialReasoning,
                toolActions: snap.toolActions,
                totalTokens: snap.totalTokens
            )
        }
    }

    let resumed: OrchestratorResponse?
    do {
        let resumeTask: Task<OrchestratorResponse?, Error> = Task {
            try await context.orchestrator.resumeNarratedApproval(
                id: id,
                approved: approved,
                answer: answer,
                onEvent: { event in
                    auditProgress.record(event)
                    if let targetSessionID {
                        await broadcastWSEventFrame(event, sessionID: targetSessionID, context: context)
                    }
                }
            )
        }
        taskBox.set(resumeTask)
        resumed = try await withTaskCancellationHandler {
            try await resumeTask.value
        } onCancel: {
            resumeTask.cancel()
        }
    } catch {
        if let targetSessionID, let registration {
            await context.activeTurns.unregister(sessionID: targetSessionID, token: registration.token)
        }
        await handleResumeFailure(
            id: id,
            detail: error.localizedDescription,
            targetSessionID: targetSessionID,
            decidedCallID: decidedCallID,
            context: context
        )
        return
    }
    if let targetSessionID, let registration {
        await context.activeTurns.unregister(sessionID: targetSessionID, token: registration.token)
    }
    guard let resumed else {
        return
    }
    // Late steering stays queued above, so report its depth on done like the live
    // turn path: the dashboard keeps exactly that many newest bubbles and
    // releases the consumed ones answered here.
    var done = WSStreamDone(from: resumed)
    done.retainedSteerCount = await context.steeringQueue.pendingCount(for: resumed.sessionID)
    do {
        let data = try JSONEncoder().encode(done)
        if let frame = String(data: data, encoding: .utf8) {
            await context.hub.broadcast(text: frame)
        }
    } catch {
        RuneWeaverLog.server.error("ServerSchedulerRoutes: failed to encode WSStreamDone frame: \(error.localizedDescription)")
    }
    await recordResumedRun(
        resumed: resumed,
        approved: approved,
        decidedCallID: decidedCallID,
        context: context
    )
}

/// Handles cleanup and run log updates when resumeNarratedApproval throws.
private func handleResumeFailure(
    id: UUID,
    detail: String,
    targetSessionID: UUID?,
    decidedCallID: String?,
    context: ServerContext
) async {
    RuneWeaverLog.server.error("RuneWeaverServer resumeNarratedApproval \(id.uuidString) failed: \(detail)")
    guard let failedSessionID = targetSessionID else {
        return
    }
    if await isParkedTurn(sessionID: failedSessionID, context: context) {
        return
    }
    guard let stranded = await strandedParkedRun(
        sessionID: failedSessionID,
        decidedCallID: decidedCallID,
        context: context
    ) else {
        return
    }
    let updated = await context.runs.update(
        id: stranded.id,
        status: "error",
        response: "Resume failed for approval \(id.uuidString): \(detail)"
    ) ?? stranded
    await context.hub.broadcastRun(updated)
}

/// Records or updates the run log entry after a parked approval finishes.
private func recordResumedRun(
    resumed: OrchestratorResponse,
    approved: Bool,
    decidedCallID: String?,
    context: ServerContext
) async {
    let stillParked = resumed.isParked
    if stillParked {
        if let awaiting = await awaitingParkedRun(for: resumed, decidedCallID: decidedCallID, context: context) {
            let updated = await context.runs.update(
                id: awaiting.id,
                status: "awaiting_approval",
                response: resumed.text,
                toolActions: resumed.toolActions,
                totalTokens: resumed.totalTokens
            ) ?? awaiting
            await context.hub.broadcastRun(updated)
            return
        }
        let toolName = resumed.toolActions.first?.toolName ?? "tool"
        let entry = await context.runs.append(
            kind: "chat",
            status: "awaiting_approval",
            message: "Waiting for approval to run \(toolName).",
            sessionID: resumed.sessionID,
            response: resumed.text,
            toolActions: resumed.toolActions,
            totalTokens: resumed.totalTokens
        )
        await context.hub.broadcastRun(entry)
        return
    }
    let finalStatus = resolvedResumeStatus(approved: approved, resumed: resumed)
    if let awaiting = await awaitingParkedRun(for: resumed, decidedCallID: decidedCallID, context: context) {
        let updated = await context.runs.update(
            id: awaiting.id,
            status: finalStatus,
            response: resumed.text,
            toolActions: resumed.toolActions,
            totalTokens: resumed.totalTokens
        ) ?? awaiting
        await context.hub.broadcastRun(updated)
        // A parked-then-approved scheduler turn is a completion, so advance the
        // framework cursor exactly like the tick and manual paths. Denied, error,
        // and still-parked outcomes keep the prior value so the next run rescans.
        if finalStatus == "ok", let jobID = awaiting.jobID, awaiting.kind == "scheduler" {
            await context.scheduler.recordSuccessfulRun(id: jobID)
        }
        if awaiting.kind == "goal", let goalID = awaiting.goalID {
            if finalStatus == "ok" || resumed.isBudgetExceeded {
                let ideas = await (try? GoalAdvancementRunner.completeAfterTurn(
                    goalID: goalID,
                    engine: context.goalEngine,
                    runID: awaiting.id,
                    isParked: false,
                    isBudgetExceeded: resumed.isBudgetExceeded
                )) ?? []
                for idea in ideas {
                    await context.schedulerWorker.broadcastIdeaProposed(idea)
                }
            } else {
                _ = try? await GoalAdvancementRunner.completeAfterFailure(
                    goalID: goalID,
                    engine: context.goalEngine,
                    runID: awaiting.id
                )
            }
            await context.schedulerWorker.broadcastGoalSnapshot(goalID: goalID, store: context.goals)
        }
        return
    }
    let startLabel = approved ? "Approved" : "Denied"
    let toolName = resumed.toolActions.first?.toolName ?? "tool"
    let entry = await context.runs.append(
        kind: "chat",
        status: finalStatus,
        message: "\(startLabel) narrated \(toolName)",
        sessionID: resumed.sessionID,
        response: resumed.text,
        toolActions: resumed.toolActions,
        totalTokens: resumed.totalTokens
    )
    await context.hub.broadcastRun(entry)
}

/// Builds a locale-stable per-run title for a scheduler job.
/// Uses the shared cached run-title formatter so repeated fires reuse one
/// POSIX-stable instance instead of allocating per title.
func schedulerRunTitle(for job: SchedulerJob, at startTime: Date) -> String {
    "\(job.name) (\(SharedDateFormatters.runTitleString(from: startTime)))"
}

/// Creates an isolated per-run scheduler session for a job fire.
func makeSchedulerRunSession(job: SchedulerJob, startTime: Date, conversations: ConversationManager) async -> UUID {
    let sessionID = UUID()
    let runTitle = schedulerRunTitle(for: job, at: startTime)
    await conversations.ensureSession(id: sessionID, title: runTitle, source: "scheduler", overwrite: true)
    return sessionID
}

/// Registers scheduler job CRUD routes (list, create, fetch, update, delete).
/// - Parameter app: Application receiving the routes.
func registerSchedulerCRUDRoutes(_ app: Application) {
    let jobs = app.grouped(PathComponent.constant(ServerPaths.scheduler), PathComponent.constant(ServerPaths.jobs))
    jobs.get { req async throws -> SchedulerJobsResponse in
        let all = await req.application.runeWeaver.scheduler.list()
        if let limit = try parseQueryLimit(req, min: 1, max: SchedulerStore.maxJobs) {
            return SchedulerJobsResponse(jobs: Array(all.prefix(limit)))
        }
        return SchedulerJobsResponse(jobs: all)
    }
    jobs.post { req async throws -> SchedulerJob in
        let body = try req.content.decode(NewSchedulerJob.self)
        do {
            return try await req.application.runeWeaver.scheduler.create(body)
        } catch let error as SchedulerStoreError {
            switch error {
            case let .invalidField(detail):
                throw Abort(.badRequest, reason: detail)
            case let .unknownJob(detail):
                throw Abort(.notFound, reason: detail)
            }
        }
    }
    jobs.get(PathComponent.parameter("id")) { req async throws -> SchedulerJob in
        guard let raw = req.parameters.get("id"), let id = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "id must be a UUID")
        }
        guard let job = await req.application.runeWeaver.scheduler.job(id: id) else {
            throw Abort(.notFound, reason: "Unknown job \(raw)")
        }
        return job
    }
    jobs.put(PathComponent.parameter("id")) { req async throws -> SchedulerJob in
        guard let raw = req.parameters.get("id"), let id = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "id must be a UUID")
        }
        let body = try req.content.decode(UpdateSchedulerJob.self)
        do {
            return try await req.application.runeWeaver.scheduler.update(id: id, body)
        } catch let error as SchedulerStoreError {
            switch error {
            case let .invalidField(detail):
                throw Abort(.badRequest, reason: detail)
            case let .unknownJob(detail):
                throw Abort(.notFound, reason: detail)
            }
        }
    }
    jobs.delete(PathComponent.parameter("id")) { req async throws -> HTTPStatus in
        guard let raw = req.parameters.get("id"), let id = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "id must be a UUID")
        }
        let removed = await req.application.runeWeaver.scheduler.delete(id: id)
        guard removed else {
            throw Abort(.notFound, reason: "Unknown job \(raw)")
        }
        return .noContent
    }
}

/// Registers the manual scheduler job run route.
func registerSchedulerRunRoute(_ app: Application) {
    let jobs = app.grouped(PathComponent.constant(ServerPaths.scheduler), PathComponent.constant(ServerPaths.jobs))
    jobs.post(PathComponent.parameter("id"), PathComponent.constant(ServerPaths.run)) { req async throws -> OrchestratorResponse in
        try await handleSchedulerRun(req: req)
    }
}

/// Handles a manual scheduler job run request by validating the job and reserving the run.
private func handleSchedulerRun(req: Request) async throws -> OrchestratorResponse {
    guard let raw = req.parameters.get("id"), let id = UUID(uuidString: raw) else {
        throw Abort(.badRequest, reason: "id must be a UUID")
    }
    let context = req.application.runeWeaver
    guard let job = await context.scheduler.job(id: id) else {
        throw Abort(.notFound, reason: "Unknown job \(raw)")
    }
    guard job.enabled else {
        throw Abort(.conflict, reason: "Job \(raw) is disabled")
    }
    guard await context.runLock.tryAcquire(id: id, name: job.name) else {
        // Skipped runs create no conversation, so the audit entry stays
        // untagged instead of inventing an orphan session for filtering.
        await context.runs.append(
            kind: "scheduler",
            status: "skipped",
            message: "Skipped '\(job.name)': already running",
            jobID: id,
            sessionID: nil
        )
        throw Abort(.conflict, reason: "Job \(raw) is already running")
    }
    // The single-flight lock is held for the whole turn and released with a structured await on
    // every terminal path before returning, so the next acquire never observes a stale held lock
    // from a detached release racing the return.
    let startTime = Date()
    let sessionID = await makeSchedulerRunSession(job: job, startTime: startTime, conversations: context.conversations)

    let initialEntry = await context.runs.append(
        kind: "scheduler",
        status: "running",
        message: job.prompt,
        jobID: id,
        sessionID: sessionID,
        durationMs: 0
    )
    await context.hub.broadcastRun(initialEntry)

    return try await executeManualJobRun(
        job: job,
        sessionID: sessionID,
        initialEntry: initialEntry,
        startTime: startTime,
        context: context
    )
}

/// Executes the turn for a manual scheduler run, records the outcome, and releases the single-flight lock.
private func executeManualJobRun(
    job: SchedulerJob,
    sessionID: UUID,
    initialEntry: RunLogEntry,
    startTime: Date,
    context: ServerContext
) async throws -> OrchestratorResponse {
    do {
        let policy: ToolLimitPolicy = job.onToolLimit == "park" ? .park : .forceSynthesis
        // Manual runs carry the same framework cursor as automatic ticks; because the initial job
        // predates the single-flight lock, the prompt is re-read from the freshest stored cursor
        // under the lock, keeping both paths identical.
        let effectivePrompt = await context.schedulerWorker.freshSchedulerRunPrompt(for: job)
        let response = try await context.orchestrator.process(
            input: UserInput(
                text: effectivePrompt,
                sessionID: sessionID,
                source: "scheduler",
                toolLimitPolicy: policy,
                maxToolIterations: job.maxToolIterations
            ),
            onEvent: { event in
                await broadcastWSEventFrame(event, sessionID: sessionID, context: context)
            }
        )
        await broadcastStreamDone(for: response, sessionID: sessionID, hub: context.hub)
        let finishedAt = Date()
        let durationMs = Int(finishedAt.timeIntervalSince(startTime) * 1000)
        // Parked scheduler turns remain as awaiting_approval like chat turns, resolving through
        // the same inbox resume path in their session. Budget exceeded turns finish with
        // forced diagnostic synthesis and budget_exceeded status.
        await broadcastParkedApprovals(for: response, context: context)
        let runStatus = if response.isParked {
            "awaiting_approval"
        } else if response.isBudgetExceeded {
            "budget_exceeded"
        } else {
            "ok"
        }
        let entry = await context.runs.update(
            id: initialEntry.id,
            status: runStatus,
            response: response.text,
            toolActions: response.toolActions,
            totalTokens: response.totalTokens,
            durationMs: durationMs
        ) ?? initialEntry
        await context.hub.broadcastRun(entry)
        if response.shouldAdvanceSchedulerCursor {
            await context.scheduler.recordSuccessfulRun(id: job.id, endedAt: finishedAt)
        }
        await context.runLock.release(id: job.id, name: job.name)
        return response
    } catch let error as CancellationError {
        await finalizeSchedulerRun(
            initialEntry: initialEntry,
            status: "cancelled",
            startTime: startTime,
            job: job,
            context: context
        )
        throw error
    } catch let error as OrchestratorError {
        await finalizeSchedulerRun(
            initialEntry: initialEntry,
            status: "error",
            startTime: startTime,
            job: job,
            context: context
        )
        switch error {
        case .emptyInput:
            throw Abort(.badRequest, reason: "text must not be empty")
        case let .toolLoopExceeded(iterations):
            throw Abort(.unprocessableEntity, reason: "Tool loop exceeded \(iterations) rounds")
        case let .llmFailed(detail):
            throw Abort(.badGateway, reason: detail)
        }
    } catch {
        await finalizeSchedulerRun(
            initialEntry: initialEntry,
            status: "error",
            startTime: startTime,
            job: job,
            context: context
        )
        throw Abort(.badGateway, reason: error.localizedDescription)
    }
}

/// Finalizes a manual scheduler run by updating the run entry, broadcasting it, and releasing the single-flight lock.
private func finalizeSchedulerRun(
    initialEntry: RunLogEntry,
    status: String,
    startTime: Date,
    job: SchedulerJob,
    context: ServerContext
) async {
    let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
    let entry = await context.runs.update(
        id: initialEntry.id,
        status: status,
        durationMs: durationMs
    ) ?? initialEntry
    await context.hub.broadcastRun(entry)
    await context.runLock.release(id: job.id, name: job.name)
}

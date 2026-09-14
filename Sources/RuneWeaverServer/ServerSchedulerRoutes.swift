// Rune Weaver Server — Scheduler routes and parked-turn resume helpers.
//
// Hosts scheduler job CRUD plus manual run routes and the shared
// parked-approval helpers so the main service file stays within the length
// budget. Chat, scheduler auto-fire, and approval decide paths share one
// parked check and one resume lifecycle through these helpers.

import Foundation
import RuneWeaverCore
import Vapor

/// Whether a session currently has a parked narrated turn awaiting approval.
///
/// Consults the orchestrator's parked gated narrations so chat and scheduler
/// entry points share one parked check instead of re-filtering the inbox at
/// each call site. Structured gate waits that block the turn never park here.
/// New turns must prefer their own `OrchestratorResponse.isParked` flag over
/// this session-wide lookup so a stale parked approval from a prior turn
/// cannot mis-mark a fresh normal turn as awaiting approval.
/// - Parameters:
///   - sessionID: Owning session to inspect.
///   - context: Shared engine collaborators owning parked narrations.
/// - Returns: True when the session owns at least one parked approval.
func isParkedTurn(sessionID: UUID, context: ServerContext) async -> Bool {
    await context.orchestrator.isSessionParked(sessionID)
}

/// Broadcasts filed narrated approvals for a parked turn.
///
/// Mirrors the structured gate broadcast path so narrated parks emit live
/// approval prompts without polling: each pending queue entry whose call
/// identifier appears in the parked response is announced to connected
/// sockets. Normal turns never broadcast.
/// - Parameters:
///   - response: Completed turn carrying filed gated call identifiers.
///   - context: Shared engine collaborators owning the queue and hub.
func broadcastParkedApprovals(for response: OrchestratorResponse, context: ServerContext) async {
    guard response.isParked else {
        return
    }
    let callIDs = Set(response.toolActions.map(\.callID))
    guard !callIDs.isEmpty else {
        return
    }
    let pending = await context.approvals.requests(for: response.sessionID)
    for request in pending where callIDs.contains(request.input.callID) {
        await context.hub.broadcastApproval(request)
    }
}

/// Finds the awaiting run owning a resumed parked batch by call overlap.
///
/// Lists awaiting runs in the resumed session and prefers the entry whose
/// tool actions overlap the decided call or the resumed batch call
/// identifiers, falling back to the newest awaiting run for legacy entries
/// without call identifiers. Keeps multiple awaiting runs in one session
/// from resolving the wrong entry.
/// - Parameters:
///   - resumed: Resume response carrying the batch call identifiers.
///   - decidedCallID: Call identifier of the just-decided approval, if known.
///   - context: Shared engine collaborators owning the run log.
/// - Returns: Owning awaiting run, or nil when none is awaiting.
func awaitingParkedRun(
    for resumed: OrchestratorResponse,
    decidedCallID: String?,
    context: ServerContext
) async -> RunLogEntry? {
    let awaiting = await context.runs.list(limit: 200, sessionID: resumed.sessionID).filter { $0.status == "awaiting_approval" }
    guard !awaiting.isEmpty else {
        return nil
    }
    if let decidedCallID, !decidedCallID.isEmpty {
        if let match = awaiting.first(where: { run in
            run.toolActions.contains { $0.callID == decidedCallID }
        }) {
            return match
        }
    }
    let resumedCallIDs = Set(resumed.toolActions.map(\.callID))
    if !resumedCallIDs.isEmpty {
        if let match = awaiting.first(where: { run in
            run.toolActions.contains { resumedCallIDs.contains($0.callID) }
        }) {
            return match
        }
    }
    return awaiting.first
}

/// Finds the stranded awaiting run for a failed resume by call overlap.
///
/// Scopes the lookup to the failed session only and prefers the entry
/// overlapping the decided call identifier, falling back to the newest
/// awaiting run so one failure cannot flip unrelated sessions.
/// - Parameters:
///   - sessionID: Owning session of the failed approval.
///   - decidedCallID: Call identifier of the failed approval, if known.
///   - context: Shared engine collaborators owning the run log.
/// - Returns: Stranded awaiting run, or nil when none is awaiting.
func strandedParkedRun(
    sessionID: UUID,
    decidedCallID: String?,
    context: ServerContext
) async -> RunLogEntry? {
    let awaiting = await context.runs.list(limit: 200, sessionID: sessionID).filter { $0.status == "awaiting_approval" }
    guard !awaiting.isEmpty else {
        return nil
    }
    if let decidedCallID, !decidedCallID.isEmpty {
        if let match = awaiting.first(where: { run in
            run.toolActions.contains { $0.callID == decidedCallID }
        }) {
            return match
        }
    }
    return awaiting.first
}

/// Resolves the final run status for a resumed narrated approval.
///
/// Single denials land as denied so the audit trail distinguishes an explicit
/// refusal from a tool failure; batched denies with prior allows resolve by
/// their executed outcomes since synthesis already covered the batch. Allows
/// land as error when any executed call reported failure (including a missing
/// tool with no action), otherwise ok.
/// - Parameters:
///   - approved: Whether the inbox allowed the call.
///   - resumed: Resume response carrying executed actions.
/// - Returns: Final run status.
func resolvedResumeStatus(approved: Bool, resumed: OrchestratorResponse) -> String {
    if !approved, resumed.toolActions.isEmpty {
        return "denied"
    }
    if resumed.toolActions.isEmpty {
        return "error"
    }
    if resumed.toolActions.contains(where: { !$0.didSucceed }) {
        return "error"
    }
    return "ok"
}

/// Resumes a narrated parked approval in its tagged session, best-effort.
///
/// Runs after the inbox decision so the parked turn continues without
/// blocking the decide response: an allow executes the filed call, while a
/// deny records the denial in that session. One LLM round can park several
/// gated narrations; the session's awaiting_approval run stays awaiting
/// while siblings remain and transitions to ok, error, or denied only after
/// the last sibling synthesizes once, keeping one lifecycle per parked turn
/// and falling back to a fresh entry when the parked run already resolved.
/// Broadcasts so dashboard views refresh without polling. Shared by the REST
/// decide route and the WebSocket decision handler so both surfaces resume
/// identically. A resume throw only ever touches the failed session's own
/// awaiting run; unrelated sessions keep their parked lifecycle untouched.
/// Awaiting runs are matched by call-identifier overlap so multiple awaiting
/// runs in one session resolve the owning entry instead of the newest.
/// - Parameters:
///   - id: Approval request identifier that parked the turn.
///   - approved: Whether the inbox allowed the call.
///   - context: Shared engine collaborators owning the session and logs.
///   - sessionID: Owning session of the failed approval, when known. Scopes
///     the stranded-run fallback so one failure cannot flip other sessions'
///     parked runs to error. Defaults to nil, in which case the fallback
///     attempts the approvals lookup and otherwise only logs.
///   - decidedCallID: Call identifier of the decided approval, when known.
///     Scopes awaiting-run matching to the owning entry. Defaults to nil,
///     in which case batch call overlap plus newest fallback applies.
func resumeNarratedApproval(
    id: UUID,
    approved: Bool,
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
    if let data = try? JSONEncoder().encode(WSApprovalDecidedFrame(id: id, approved: approved, sessionID: targetSessionID)),
       let text = String(data: data, encoding: .utf8)
    {
        await context.hub.broadcast(text: text)
    }

    let resumed: OrchestratorResponse?
    do {
        resumed = try await context.orchestrator.resumeNarratedApproval(
            id: id,
            approved: approved,
            onEvent: { event in
                if let targetSessionID {
                    await broadcastWSEventFrame(event, sessionID: targetSessionID, context: context)
                }
            }
        )
    } catch {
        await handleResumeFailure(
            id: id,
            detail: error.localizedDescription,
            targetSessionID: targetSessionID,
            decidedCallID: decidedCallID,
            context: context
        )
        return
    }
    guard let resumed else {
        return
    }
    let done = WSStreamDone(from: resumed)
    if let data = try? JSONEncoder().encode(done), let frame = String(data: data, encoding: .utf8) {
        await context.hub.broadcast(text: frame)
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
    fputs("[ERROR] RuneWeaverServer resumeNarratedApproval \(id.uuidString) failed: \(detail)\n", stderr)
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

/// Records or updates the run log entry after a parked narrated approval finishes.
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

/// Lock-guarded cache for scheduler run title formatting.
///
/// `DateFormatter` is neither `Sendable` nor thread-safe, so the single
/// short-style instance lives in this `@unchecked Sendable` box and every
/// title renders while holding the lock. The fixed `en_US_POSIX` locale
/// keeps per-fire titles stable across user locales without paying a fresh
/// formatter per job fire.
private final class SchedulerRunTitleCache: @unchecked Sendable {
    /// Guards the shared formatter.
    private let lock = NSLock()
    /// Cached short-style formatter with a fixed locale, built once.
    private let formatter: DateFormatter

    /// Builds the cached formatter once.
    init() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        self.formatter = formatter
    }

    /// Renders the timestamp portion of a run title under the lock.
    /// - Parameter date: Fire time to format.
    /// - Returns: Locale-stable timestamp text.
    func string(from date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return formatter.string(from: date)
    }
}

/// Shared cached title formatter for scheduler run sessions.
private let sharedSchedulerRunTitleCache = SchedulerRunTitleCache()

/// Builds a locale-stable per-run title for a scheduler job.
///
/// Combines the job name with the fire timestamp so each independent run
/// session stays human-scannable in history while remaining deterministic
/// across locales via the shared cached formatter.
/// - Parameters:
///   - job: Job being executed.
///   - startTime: Fire time used for the timestamp.
/// - Returns: Run title for the session.
func schedulerRunTitle(for job: SchedulerJob, at startTime: Date) -> String {
    "\(job.name) (\(sharedSchedulerRunTitleCache.string(from: startTime)))"
}

/// Creates an isolated per-run scheduler session for a job fire.
///
/// Each execution gets a fresh `UUID()` stamped `source: "scheduler"` so
/// auto-fire and manual runs stay isolated from interactive chat and from
/// each other. Continuity across runs flows through scheduled background
/// prompting plus `run_logs` job linkage, not shared episodic history.
/// Shared by the auto-fire worker and the manual run route so both entry
/// points format titles and stamp sessions identically.
/// - Parameters:
///   - job: Job being executed.
///   - startTime: Fire time used for the title timestamp.
///   - conversations: Session owner.
/// - Returns: New per-run session identifier.
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
///
/// Manual entry point alongside in-process auto-fire: the service exposes CRUD
/// plus this single-flight `POST .../run` entry point and auto-fires cron and
/// poll triggers via `ServerSchedulerWorker` on the shared `SchedulerRunLock`.
/// The CLI `scheduler run` foreground loop is a separate auto-fire runner in
/// another process with its own `SchedulerEngine.running` lock and no shared
/// state, so concurrent service plus CLI runners can double-fire the same job —
/// run one auto-fire runner at a time. Concurrent runs for the same job inside
/// this process are rejected with `409`. Run completion is broadcast via
/// WebSocket to the dashboard and native Web Notifications, intentionally
/// superseding Script Editor (`osascript`) dialogs.
/// - Parameter app: Application receiving the route.
func registerSchedulerRunRoute(_ app: Application) {
    let jobs = app.grouped(PathComponent.constant(ServerPaths.scheduler), PathComponent.constant(ServerPaths.jobs))
    jobs.post(PathComponent.parameter("id"), PathComponent.constant(ServerPaths.run)) { req async throws -> OrchestratorResponse in
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

        do {
            let response = try await context.orchestrator.process(input: UserInput(
                text: job.prompt,
                sessionID: sessionID,
                source: "scheduler"
            ))
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            // Parked scheduler turns remain as awaiting_approval like chat turns,
            // resolving through the same inbox resume path in their session.
            // The per-turn parked flag keeps a stale prior park in this
            // session from mis-marking a fresh normal turn.
            await broadcastParkedApprovals(for: response, context: context)
            let parkedStatus = if response.isParked {
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
            await context.runLock.release(id: id, name: job.name)
            return response
        } catch let error as CancellationError {
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            let entry = await context.runs.update(
                id: initialEntry.id,
                status: "cancelled",
                durationMs: durationMs
            ) ?? initialEntry
            await context.hub.broadcastRun(entry)
            await context.runLock.release(id: id, name: job.name)
            throw error
        } catch let error as OrchestratorError {
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            let entry = await context.runs.update(
                id: initialEntry.id,
                status: "error",
                durationMs: durationMs
            ) ?? initialEntry
            await context.hub.broadcastRun(entry)
            await context.runLock.release(id: id, name: job.name)
            switch error {
            case .emptyInput:
                throw Abort(.badRequest, reason: "text must not be empty")
            case let .toolLoopExceeded(iterations):
                throw Abort(.unprocessableEntity, reason: "Tool loop exceeded \(iterations) rounds")
            case let .llmFailed(detail):
                throw Abort(.badGateway, reason: detail)
            }
        } catch {
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            let entry = await context.runs.update(
                id: initialEntry.id,
                status: "error",
                durationMs: durationMs
            ) ?? initialEntry
            await context.hub.broadcastRun(entry)
            await context.runLock.release(id: id, name: job.name)
            throw Abort(.badGateway, reason: error.localizedDescription)
        }
    }
}

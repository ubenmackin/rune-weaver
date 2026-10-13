// Rune Weaver Server — Approval decision contract and routes.
//
// Purpose: own the single decision path every transport shares — applying an
// approval verdict, mapping egress-parked requests through the supervisor and
// policy store, resuming parked turns, and broadcasting access-rule changes —
// so REST and WebSocket triage resolve identically and neither can drift.
// Scope: the decide-plus-map function, the approvals list and decision routes,
// and the operator question response route; rule listing and administration
// stay with the dedicated rules file, and grant storage stays with the gate.
// Architectural role: keeps the Vapor adapters decoupled from the engine core
// in one decision contract, so tier semantics live in exactly one function
// instead of one copy per transport.

import Foundation
import RuneWeaverCore
import Vapor

/// Outcome of one approval decision applied through the shared contract.
enum ApprovalDecisionOutcome: Equatable {
    /// The decision resolved; carries the effective approval verdict.
    case resolved(approved: Bool)
    /// No pending approval carried the identifier.
    case unknown
    /// The approval is an operator question and must ride the respond route.
    case questionRequiresRespond
    /// A required side effect failed, so nothing was approved or recorded.
    case sideEffectFailed(reason: String)
}

/// Transport-owned spawner for the narrated resume that follows a
/// session-tagged decision, receiving the effective approval verdict.
///
/// The shared contract decides when a resume runs; the transport keeps owning
/// how, so a WebSocket decision still tracks its resume under the connection
/// lifetime while REST spawns a detached task.
typealias ApprovalResumeSpawner = @Sendable (_ effectiveApproved: Bool) async -> Void

/// Caller-supplied parameters for applying an approval decision.
struct ApprovalDecisionInput: Sendable {
    var id: UUID
    var approved: Bool
    var duration: TrustDuration
    var scope: AccessScope?
    var pending: PermissionRequest?

    init(
        id: UUID,
        approved: Bool,
        duration: TrustDuration,
        scope: AccessScope? = nil,
        pending: PermissionRequest? = nil
    ) {
        self.id = id
        self.approved = approved
        self.duration = duration
        self.scope = scope
        self.pending = pending
    }
}

/// Applies one approval decision through the single decision contract the REST
/// route and WebSocket triage share.
///
/// Egress tiers are gone from the wire: the parked request's host plus the
/// requested duration carry the whole mapping, so both transports decide
/// identically and neither can drift. An allow side effect that fails never
/// approves a call the policy did not record — the request stays parked for a
/// later decision — and a durable deny whose policy write failed never
/// resolves, so the next identical call re-parks instead of silently
/// auto-denying. The brake-resume side effect, the question guard, the
/// durable-rule broadcast, and the session-tagged resume all live here so a
/// transport fix cannot reopen a second decision path.
/// - Parameters:
///   - input: Parameters identifying and describing the decision.
///   - pulse: Verified system-pulse actor receiving the watchdog record.
///   - context: Live server context owning the queue and side effects.
///   - spawnResume: Transport-owned spawner for the narrated resume.
/// - Returns: The outcome each transport maps to its own response shape.
func applyApprovalDecision(
    input: ApprovalDecisionInput,
    pulse: SystemHealthSnapshot? = nil,
    context: ServerContext,
    spawnResume: ApprovalResumeSpawner
) async -> ApprovalDecisionOutcome {
    guard let pending = input.pending else { return .unknown }
    // Operator choices ride the answer-bearing path so an approval without a
    // choice cannot synthesize an empty acknowledgement.
    if pending.toolName == "question.ask" {
        return .questionRequiresRespond
    }
    let effectiveApproved: Bool
    if let host = pending.egressHost, !host.isEmpty {
        // An egress-parked request maps through the supervisor and policy
        // store; a failed side effect fails closed rather than approving.
        guard let mapped = await egressApprovalVerdict(
            approved: input.approved,
            duration: input.duration,
            host: host,
            pending: pending,
            context: context
        ) else {
            return .sideEffectFailed(reason: "Approval decision could not be applied for this request")
        }
        effectiveApproved = mapped
    } else {
        effectiveApproved = input.approved
    }
    // An egress decision stores the host the call dialed; every other request
    // stores the caller's scope, or the target the gate derives when omitted.
    let resolvedScope: AccessScope? = if let host = pending.egressHost, !host.isEmpty {
        AccessScope.canonicalized(.domain(host: host, subdomains: false))
    } else {
        input.scope
    }
    let resolved = await context.approvals.decide(
        id: input.id,
        approved: effectiveApproved,
        duration: input.duration,
        scope: resolvedScope
    )
    guard resolved else { return .unknown }
    // The brake clears only on an explicit owner Resume: approving the brake
    // card releases every parked turn with fresh counters, while denying it
    // leaves the park exactly as the owner left it. Every transport reaches
    // this through the same call, so the resume no longer depends on which
    // surface the owner decided from.
    if effectiveApproved, pending.toolName == BehaviorWatchdog.brakeCardToolName {
        await context.watchdog.resume()
        if let pulse {
            await pulse.recordWatchdogHealth(context.watchdog.health())
        }
    }
    // A durable decision stores a rule inside `decide`, so dashboards need a
    // refresh signal; one-shot approvals store nothing. The one-shot tools
    // resolve a single parked batch rather than gating a repeatable call, so a
    // durable vote on them must not fire a refresh when nothing changed.
    // A standing deny is a durable mint too: approved=false plus forever
    // stores a deny rule inside `decide`, so it fires the same frame.
    let mintsDurableRule = input.duration.isDurable
        && (effectiveApproved || input.duration == .forever)
        && pending.toolName != "engine.continue"
        && pending.toolName != "question.ask"
        && pending.toolName != "desktop.resume"
        && pending.toolName != BehaviorWatchdog.brakeCardToolName
    if mintsDurableRule {
        await context.hub.broadcastAccessRulesChanged()
    }
    if pending.sessionID != nil {
        // The resume stays session-tagged so the parked turn continues in the
        // conversation that filed it.
        await spawnResume(effectiveApproved)
    }
    return .resolved(approved: effectiveApproved)
}

/// Maps an egress-parked decision onto its supervisor and policy side effects.
///
/// The parked request carries the host it dialed, so the polarity plus tier
/// carry the whole mapping: a one-shot allow spends a supervisor grant, a
/// session allow trusts the domain for the rest of the conversation, a durable
/// allow mints a domain-scoped rule, a one-shot deny refuses the call alone,
/// and a durable deny blocks the domain in policy beside the rule it mints.
/// Returns nil when a required side effect failed, so the caller fails closed
/// instead of approving a call nothing recorded.
/// - Parameters:
///   - approved: Approval polarity the client sent.
///   - duration: Requested trust tier.
///   - host: Host the parked request dialed.
///   - pending: Pending request owning the session scope.
///   - context: Live server context owning the supervisor and policy store.
/// - Returns: Effective approval verdict, or nil when a side effect failed.
func egressApprovalVerdict(
    approved: Bool,
    duration: TrustDuration,
    host: String,
    pending: PermissionRequest,
    context: ServerContext
) async -> Bool? {
    // The host can be model-filled, so a star shape is an attacker-controlled
    // pattern rather than a legitimate target. Deny tiers stay untouched:
    // blocking a wildcard only tightens the posture, while allowing one does
    // the opposite. Fail closed so the pattern is never approved.
    if approved, AllowedOriginPattern.classifyWildcard(host.lowercased()) != .none {
        return nil
    }
    if approved {
        switch duration {
        case .thisTime:
            // A one-shot grant is session-scoped whenever the parked request
            // carries a session, so one chat cannot spend another's approval.
            guard let supervisor = context.egressSupervisor else { return nil }
            await supervisor.allowDomainOnce(domain: host, sessionID: pending.sessionID)
            return true
        case .forSession:
            guard let sessionID = pending.sessionID, let supervisor = context.egressSupervisor else { return nil }
            await supervisor.allowDomainForSession(sessionID: sessionID, domain: host)
            return true
        case .forTask, .fiveMinutes, .oneHour, .oneDay, .forever:
            // The durable half runs inside `decide`, which mints the
            // domain-scoped rule; the host must be able to name that scope or
            // the approval would approve a call nothing records.
            guard AccessScope.canonicalized(.domain(host: host, subdomains: false)) != nil else { return nil }
            return true
        }
    }
    switch duration {
    case .forever:
        // The blocked entry lets the next identical call auto-deny instead of
        // re-parking; a dropped write must surface instead of resolving as a
        // one-time deny.
        do {
            try await context.policyStore.appendBlockedDomain(host)
        } catch {
            return nil
        }
        return false
    case .thisTime, .forTask, .forSession, .fiveMinutes, .oneHour, .oneDay:
        return false
    }
}

/// Registers approvals list plus decision routes.
/// Durable access-rules routes live in the dedicated rules file alongside
/// their change broadcast; both sets register on the same paths.
/// - Parameter app: Application receiving the routes.
func registerApprovalRoutes(_ app: Application) {
    app.get(PathComponent.constant(ServerPaths.approvals)) { req async throws -> ApprovalsResponse in
        let pending = await req.application.runeWeaver.approvals.list()
        if let limit = try parseQueryLimit(req, min: 1, max: 100) {
            return ApprovalsResponse(approvals: Array(pending.prefix(limit)))
        }
        return ApprovalsResponse(approvals: pending)
    }

    registerAccessRulesRoutes(app)
    registerQuestionResponseRoute(app)

    app
        .post(PathComponent.constant(ServerPaths.approvals), PathComponent.parameter("id"),
              PathComponent.constant(ServerPaths.decide))
        { req async throws -> ApprovalDecisionResponse in
            guard let raw = req.parameters.get("id"), let id = UUID(uuidString: raw) else {
                throw Abort(.badRequest, reason: "id must be a UUID")
            }
            // A malformed scope fails decoding before the gate runs, so an
            // unknown kind or a non-canonical payload stays a caller 400 with
            // the request still parked.
            let body = try req.content.decode(ApprovalDecisionRequest.self)
            let context = req.application.runeWeaver
            // Capture the tagged session before resolving: `decide` removes
            // the pending entry, so the resume path would otherwise lose
            // which conversation to continue.
            let pending = await context.approvals.request(id: id)
            let outcome = await applyApprovalDecision(
                input: ApprovalDecisionInput(
                    id: id,
                    approved: body.approved,
                    duration: body.resolvedDuration,
                    scope: body.resolvedScope,
                    pending: pending
                ),
                pulse: req.application.systemHealthSnapshot,
                context: context,
                spawnResume: { effectiveApproved in
                    // Detached like the pre-contract route: the decision
                    // answers immediately while the parked turn resumes behind
                    // it instead of holding the response open.
                    Task {
                        await resumeNarratedApproval(
                            id: id,
                            approved: effectiveApproved,
                            context: context,
                            sessionID: pending?.sessionID,
                            decidedCallID: pending?.input.callID
                        )
                    }
                }
            )
            switch outcome {
            case let .resolved(approved):
                return ApprovalDecisionResponse(id: id, approved: approved, duration: body.resolvedDuration)
            case .unknown:
                throw Abort(.notFound, reason: "Unknown approval \(raw)")
            case .questionRequiresRespond:
                throw Abort(.badRequest, reason: "Use /respond for question.ask")
            case let .sideEffectFailed(reason):
                // Persistence or grant failures never approve a call the
                // policy did not record: the request stays parked so the
                // owner can decide again once the write lands.
                throw Abort(.unprocessableEntity, reason: reason)
            }
        }
}

/// Registers operator question response route for human-in-the-loop choices.
/// - Parameter app: Application receiving the routes.
private func registerQuestionResponseRoute(_ app: Application) {
    app
        .post(PathComponent.constant(ServerPaths.approvals), PathComponent.parameter("id"),
              PathComponent.constant(ServerPaths.respond))
        { req async throws -> ApprovalDecisionResponse in
            guard let raw = req.parameters.get("id"), let id = UUID(uuidString: raw) else {
                throw Abort(.badRequest, reason: "id must be a UUID")
            }
            let body = try req.content.decode(QuestionResponseRequest.self)
            let context = req.application.runeWeaver
            let pending = await context.approvals.request(id: id)
            guard let pending else {
                throw Abort(.notFound, reason: "Unknown approval \(raw)")
            }
            // The response path resumes with an operator choice, so only
            // question approvals resolve here; other tools keep decide's
            // egress and grant handling instead of bypassing it.
            guard pending.toolName == "question.ask" else {
                throw Abort(.badRequest, reason: "Use /decide for non-question approvals")
            }
            let isCancelled = body.cancelled == true
            if !isCancelled {
                let trimmedAnswer = (body.answer ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedAnswer.isEmpty else {
                    throw Abort(.badRequest, reason: "Answer must not be empty unless cancelled")
                }
                // Matches the persona style bound so history and synthesis
                // cannot be blown up with unbounded operator text.
                guard trimmedAnswer.count <= 2000 else {
                    throw Abort(.badRequest, reason: "Answer must be at most 2000 characters")
                }
            }
            let approved = !isCancelled
            let resolved = await context.approvals.decide(
                id: id,
                approved: approved,
                duration: .thisTime,
                scope: nil
            )
            guard resolved else {
                throw Abort(.notFound, reason: "Unknown approval \(raw)")
            }
            if pending.sessionID != nil {
                Task {
                    await resumeNarratedApproval(
                        id: id,
                        approved: approved,
                        answer: body.answer,
                        context: context,
                        sessionID: pending.sessionID,
                        decidedCallID: pending.input.callID
                    )
                }
            }
            return ApprovalDecisionResponse(id: id, approved: approved, duration: .thisTime)
        }
}

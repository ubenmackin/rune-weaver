// Rune Weaver Server — Approval decision contract and routes.

import Foundation
import RuneWeaverCore
import Vapor

/// The client-facing subset of the decision-log surface vocabulary (ARCHITECTURE.md "Approvals —
/// Decision Contract, Surfaces, Decision Log"): the chat inline banner, the dashboard quick-action
/// card, and the Inbox card are the only surfaces a REST decide caller can name.
private let clientDecisionSurfaces: Set<String> = ["chat", "inbox", "dashboard"]

/// Normalizes a client-supplied surface tag to the closed vocabulary: known surfaces pass
/// through and anything else records "unknown", so the durable `surface` column only ever
/// carries a documented value without failing the decision it tags.
private func normalizedDecisionSurface(_ raw: String?) -> String {
    guard let raw, clientDecisionSurfaces.contains(raw) else { return "unknown" }
    return raw
}

/// Outcome of one approval decision applied through the shared contract.
enum ApprovalDecisionOutcome: Equatable {
    /// The decision resolved; carries the effective approval verdict.
    case resolved(approved: Bool)
    /// No pending approval carried the identifier.
    case unknown
    /// The approval is an operator question and must ride the respond route.
    case questionRequiresRespond
    /// The approval is an engine-filed system notice and settles only through its mapped remedy.
    case systemNoticeRequiresRemedy
    /// A required side effect failed, so nothing was approved or recorded.
    case sideEffectFailed(reason: String)
}

/// Transport-owned spawner for the narrated resume that follows a session-tagged decision,
/// receiving the effective approval verdict.
typealias ApprovalResumeSpawner = @Sendable (_ effectiveApproved: Bool) async -> Void

/// Caller-supplied parameters for applying an approval decision.
struct ApprovalDecisionInput: Sendable {
    var id: UUID
    var approved: Bool
    var duration: TrustDuration
    var scope: AccessScope?
    var pending: PermissionRequest?
    var surface: String

    init(
        id: UUID,
        approved: Bool,
        duration: TrustDuration,
        scope: AccessScope? = nil,
        pending: PermissionRequest? = nil,
        surface: String = "unknown"
    ) {
        self.id = id
        self.approved = approved
        self.duration = duration
        self.scope = scope
        self.pending = pending
        self.surface = surface
    }
}

/// Applies one approval decision through the single decision contract the REST route and WebSocket
/// triage share.
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
    // A system notice is surfacing-only: its resolution is never a decision,
    // so the shared contract refuses it here and the notice stays parked for
    // its mapped remedy instead of resolving or minting trust.
    if SystemNoticeTools.isSystemNotice(pending.toolName) {
        return .systemNoticeRequiresRemedy
    }
    let effectiveApproved: Bool
    let resolvedScope: AccessScope?
    if let host = pending.egressHost, !host.isEmpty {
        // Deny stays exact-host: a widened request never widens a refusal,
        // so the durable deny and blocked entry name only the dialed host.
        let egressScope: ResolvedEgressDecisionScope?
        if input.approved {
            let requested = resolvedEgressDecisionScope(host: host, requestedScope: input.scope)
            if input.scope != nil, requested == nil {
                return .sideEffectFailed(reason: "Requested domain scope does not cover egress host '\(host)'")
            }
            egressScope = requested
        } else {
            egressScope = resolvedEgressDecisionScope(host: host, requestedScope: nil)
        }
        // An egress-parked request maps through the supervisor and policy
        // store; a failed side effect fails closed rather than approving.
        guard let mapped = await egressApprovalVerdict(
            approved: input.approved,
            duration: input.duration,
            host: host,
            egressScope: egressScope,
            pending: pending,
            context: context
        ) else {
            return .sideEffectFailed(reason: "Approval decision could not be applied for this request")
        }
        effectiveApproved = mapped
        resolvedScope = egressScope?.scope
    } else {
        effectiveApproved = input.approved
        resolvedScope = input.scope
    }
    let resolved = await context.approvals.decide(
        id: input.id,
        approved: effectiveApproved,
        duration: input.duration,
        scope: resolvedScope
    )
    guard resolved else { return .unknown }
    // Recorded exactly once through the shared contract. The store never
    // throws by design, so the audit trail cannot block the decision.
    await context.approvalDecisions.append(ApprovalDecisionEntry(
        toolName: pending.toolName,
        scope: resolvedScope,
        allowed: effectiveApproved,
        duration: input.duration.rawValue,
        surface: input.surface,
        sessionID: pending.sessionID?.uuidString,
        displayTarget: pending.displayTarget,
        decidedAt: Date()
    ))
    // The brake clears only on an explicit owner Resume: approving the brake card releases every
    // parked turn with fresh counters, while denying it leaves the park exactly as the owner left
    // it.
    if effectiveApproved, pending.toolName == BehaviorWatchdog.brakeCardToolName {
        await context.watchdog.resume()
        if let pulse {
            await pulse.recordWatchdogHealth(context.watchdog.health())
            if await context.watchdog.isArmed() {
                await pulse.recordWatchdogGestation(nil)
            } else {
                await pulse.recordWatchdogGestation(context.watchdog.gestationRemainingDays())
            }
        }
    }
    // A durable decision stores a rule inside `decide`, so dashboards need a refresh signal;
    // one-shot approvals store nothing.
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

/// Shared widening guard owned by RuneWeaverCore, so the server and the
/// supervisor refuse the same bases the dashboard mirror refuses.
private func isNonWidenableDomainBase(_ canonicalHost: String) -> Bool {
    EgressWideningPolicy.isNonWidenableDomainBase(canonicalHost)
}

/// Resolved scope and supervisor domain string for an egress approval decision.
struct ResolvedEgressDecisionScope: Sendable, Equatable {
    let scope: AccessScope
    let supervisorDomain: String
}

/// Resolves and validates the domain scope for an egress-parked approval decision.
func resolvedEgressDecisionScope(
    host: String,
    requestedScope: AccessScope?
) -> ResolvedEgressDecisionScope? {
    guard let canonicalDialed = AccessScope.canonicalDomain(host) else {
        return nil
    }
    guard let requestedScope else {
        return ResolvedEgressDecisionScope(
            scope: .domain(host: canonicalDialed, subdomains: false),
            supervisorDomain: canonicalDialed
        )
    }
    guard case let .domain(scopedHost, subdomains) = requestedScope,
          let canonicalScoped = AccessScope.canonicalDomain(scopedHost)
    else {
        return nil
    }
    if subdomains {
        guard !isNonWidenableDomainBase(canonicalScoped), canonicalDialed == canonicalScoped || canonicalDialed.hasSuffix("." + canonicalScoped) else {
            return nil
        }
        return ResolvedEgressDecisionScope(
            scope: .domain(host: canonicalScoped, subdomains: true),
            supervisorDomain: "*.\(canonicalScoped)"
        )
    } else {
        guard canonicalDialed == canonicalScoped else { return nil }
        return ResolvedEgressDecisionScope(
            scope: .domain(host: canonicalScoped, subdomains: false),
            supervisorDomain: canonicalScoped
        )
    }
}

/// Maps an egress-parked decision onto its supervisor and policy side effects.
func egressApprovalVerdict(
    approved: Bool,
    duration: TrustDuration,
    host: String,
    egressScope: ResolvedEgressDecisionScope? = nil,
    pending: PermissionRequest,
    context: ServerContext
) async -> Bool? {
    // The host can be model-filled, so a star shape is an attacker-controlled pattern rather than a
    // legitimate target.
    if approved, AllowedOriginPattern.classifyWildcard(host.lowercased()) != .none {
        return nil
    }
    let resolved = egressScope ?? resolvedEgressDecisionScope(host: host, requestedScope: nil)
    if approved {
        // An unresolvable host names no scope, so fail closed on every tier.
        guard let resolved else { return nil }
        let targetDomain = resolved.supervisorDomain
        switch duration {
        case .thisTime:
            // A one-shot grant is session-scoped whenever the parked request
            // carries a session, so one chat cannot spend another's approval.
            guard let supervisor = context.egressSupervisor else { return nil }
            await supervisor.allowDomainOnce(domain: targetDomain, sessionID: pending.sessionID)
            return true
        case .forSession:
            guard let sessionID = pending.sessionID, let supervisor = context.egressSupervisor else { return nil }
            await supervisor.allowDomainForSession(sessionID: sessionID, domain: targetDomain)
            return true
        case .forTask, .fiveMinutes, .oneHour, .oneDay:
            return true
        case .forever:
            // The durable allow writes directly to policy.toml so it is persisted
            // to disk and visible in Settings -> Access -> Network without backdoors.
            do {
                try await context.policyStore.appendAllowedDomain(targetDomain)
            } catch {
                return nil
            }
            return true
        }
    }
    switch duration {
    case .forever:
        // Deny stays exact-host even when the caller sent a widened scope:
        // the blocked entry names only the dialed host.
        guard let exact = resolvedEgressDecisionScope(host: host, requestedScope: nil) else { return nil }
        let blockedTarget = exact.supervisorDomain
        do {
            try await context.policyStore.appendBlockedDomain(blockedTarget)
        } catch {
            return nil
        }
        return false
    case .thisTime, .forTask, .forSession, .fiveMinutes, .oneHour, .oneDay:
        return false
    }
}

/// Registers approvals list plus decision routes. Durable access-rules routes live in the dedicated
/// rules file alongside their change broadcast; both sets register on the same paths.
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
    registerApprovalHistoryRoutes(app)

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
                    pending: pending,
                    // Entry-boundary normalization: a hostile or drifted
                    // client tag never reaches the durable audit row; only
                    // the closed client-facing vocabulary passes through.
                    surface: normalizedDecisionSurface(body.surface)
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
            case .systemNoticeRequiresRemedy:
                // The inbox is a surfacing channel for notices, not a second
                // gate: the refusal keeps the notice parked for its remedy.
                throw Abort(
                    .badRequest,
                    reason: "System notices settle through their mapped remedy, not a decision"
                )
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
            // The store never throws by design, so recording cannot fail the response.
            await context.approvalDecisions.append(ApprovalDecisionEntry(
                toolName: pending.toolName,
                allowed: approved,
                duration: TrustDuration.thisTime.rawValue,
                surface: "question",
                sessionID: pending.sessionID?.uuidString,
                displayTarget: pending.displayTarget,
                decidedAt: Date()
            ))
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

/// Registers the decision history list plus clear routes.
/// - Parameter app: Application receiving the routes.
private func registerApprovalHistoryRoutes(_ app: Application) {
    app.get(
        PathComponent.constant(ServerPaths.approvals),
        PathComponent.constant(ServerPaths.history)
    ) { req async throws -> ApprovalHistoryResponse in
        let limit = try parseQueryLimit(req, default: 50, min: 1, max: 100)
        let tool = req.query[String.self, at: "tool"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let toolFilter = (tool?.isEmpty == false) ? tool : nil
        let actionFilter: Bool? = try {
            guard let raw = req.query[String.self, at: "action"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty
            else {
                return nil
            }
            if raw == "allowed" {
                return true
            }
            if raw == "denied" {
                return false
            }
            throw Abort(.badRequest, reason: "action must be allowed or denied")
        }()
        let context = req.application.runeWeaver
        // The filters ride the store's SELECT as WHERE clauses, so the page
        // and the total count reflect the query directly instead of slicing
        // an unbounded window in memory.
        let entries = try await context.approvalDecisions.list(
            limit: limit,
            offset: 0,
            toolName: toolFilter,
            allowed: actionFilter
        )
        let total = try await context.approvalDecisions.count(
            toolName: toolFilter,
            allowed: actionFilter
        )
        return ApprovalHistoryResponse(
            entries: entries.map(ApprovalHistoryEntry.init),
            count: total
        )
    }

    app.delete(
        PathComponent.constant(ServerPaths.approvals),
        PathComponent.constant(ServerPaths.history)
    ) { req async throws -> HTTPStatus in
        await req.application.runeWeaver.approvalDecisions.clearAll()
        return .noContent
    }
}

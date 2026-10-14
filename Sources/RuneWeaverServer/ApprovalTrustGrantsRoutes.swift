// Rune Weaver Server — Durable access rules routes and change broadcast.
//
// Owns the rules HTTP surface plus the lightweight change signal that keeps
// dashboards fresh: listing every live rule newest-first with allows and denies
// together, revoking by identifier, minting a standing allow or deny, widening
// an allow rule to its tool-wide scope, re-arming an allow rule to a new
// durable tier, and reading or clearing the ephemeral trust one session still
// carries beside the egress supervisor's session and one-shot domains.
//
// Status discipline stays what the grants surface taught: an unknown identifier
// (404) stays distinct from a live rule that cannot be widened (409) or
// re-armed (400), so a listed rule is never refused as "unknown". A deny mint
// never expires and a deny rule is never widened, because a refusal is not
// trust to promote. Every durable write broadcasts `access_rules_changed` so
// every open dashboard refetches without polling.

import Foundation
import RuneWeaverCore
import Vapor

/// Bound on a stored rule reason so an unbounded paste never persists to the
/// rule store or renders unbounded in every table row. Matches the cap the
/// dashboard's Rule modal enforces, so a compliant client never trips it and
/// a raw caller gets an honest refusal instead of a silently shortened note.
private let maxRuleReasonChars = 512

extension WSHub {
    /// Broadcasts an access-rule change so dashboards refresh their rules list.
    ///
    /// Dashboards refetch `GET /approvals/rules` on this signal, so the
    /// payload stays a lightweight discriminator instead of a full snapshot
    /// that could drift from the pruned store contents. Routes through the
    /// shared broadcast path so ordering and best-effort delivery stay
    /// single-sourced with every other hub event.
    public func broadcastAccessRulesChanged() async {
        let text: String
        do {
            let data = try JSONEncoder().encode(WSAccessRulesChanged())
            guard let encodedText = String(data: data, encoding: .utf8) else { return }
            text = encodedText
        } catch {
            RuneWeaverLog.server.error("WSHub: failed to encode access rules changed frame: \(error.localizedDescription)")
            return
        }
        await broadcast(text: text)
    }
}

/// Registers the access-rules list, revoke, create, widen, re-arm, and
/// session-trust routes.
/// - Parameter app: Application receiving the routes.
func registerAccessRulesRoutes(_ app: Application) {
    registerAccessRulesListAndRevokeRoutes(app)
    registerAccessRulesCreateRoute(app)
    registerAccessRulesMutationRoutes(app)
    registerAccessRulesSessionTrustRoutes(app)
}

private func registerAccessRulesListAndRevokeRoutes(_ app: Application) {
    app.get(
        PathComponent.constant(ServerPaths.approvals),
        PathComponent.constant(ServerPaths.rules)
    ) { req async throws -> AccessRulesResponse in
        let context = req.application.runeWeaver
        // `activeRules` prunes expired entries first, so lapsed durations never
        // surface here; a standing or forever rule carries a nil expiry and
        // always survives the prune, and a deny rule never ages out at all.
        let rules = await context.permissionGate.activeRules()
        let newestFirst = rules.sorted { $0.grantedAt > $1.grantedAt }
        return AccessRulesResponse(rules: newestFirst.map(AccessRuleResponse.init))
    }

    app.delete(
        PathComponent.constant(ServerPaths.approvals),
        PathComponent.constant(ServerPaths.rules),
        PathComponent.parameter("id")
    ) { req async throws -> HTTPStatus in
        guard let raw = req.parameters.get("id"), let id = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "id must be a UUID")
        }
        let context = req.application.runeWeaver
        let removed = await context.permissionGate.revokeRule(id: id)
        guard removed else {
            throw Abort(.notFound, reason: "Unknown rule \(raw)")
        }
        // Revocation only stops future matches; past allowed calls already
        // happened and stay in history, so dashboards must treat the delete
        // as future-only and not imply prior uses are undone.
        // Notify dashboards so a revoked rule disappears without a manual refresh.
        await context.hub.broadcastAccessRulesChanged()
        return .noContent
    }
}

private func registerAccessRulesCreateRoute(_ app: Application) {
    app.post(
        PathComponent.constant(ServerPaths.approvals),
        PathComponent.constant(ServerPaths.rules)
    ) { req async throws -> AccessRuleResponse in
        let body = try req.content.decode(RuleCreateRequest.self)
        let context = req.application.runeWeaver
        // The scope envelope already canonicalized inside the decode, so a
        // payload reaching here named a scope the gate accepts; the second
        // read keeps the mint boundary defensive against a future decode path.
        guard let toolName = AccessRule.canonicalToolName(body.toolName) else {
            throw Abort(.badRequest, reason: "toolName must not be empty")
        }
        guard let scope = body.scope.accessScope() else {
            throw Abort(.badRequest, reason: "scope is not a canonical access scope")
        }
        // Send trust is keyed to the exact canonical recipient the owner
        // authorized: a recipient set covers the handles it names, and an exact
        // target must itself spell a canonical handle. Any other send scope
        // stores nothing, for allows and denies alike.
        if toolName == "messages.send", !scope.isMintableSendScope {
            throw Abort(.badRequest, reason: "messages.send rules must name a recipient set or a canonical handle")
        }
        let storedRule: AccessRule
        switch body.action {
        case .allow:
            // A one-shot or lifecycle tier cannot back a durable row, so a
            // create carrying one reads as a caller error rather than silently
            // minting an unexpected lifetime.
            if let requested = body.duration, !requested.isDurable {
                throw Abort(.badRequest, reason: "An allow rule needs fiveMinutes, oneHour, oneDay, or forever (or no tier for a standing rule).")
            }
            let minted = try await context.permissionGate.grant(
                scope,
                toolName: toolName,
                duration: body.duration,
                reason: trimmedRuleReason(body.reason)
            )
            // A refused mint is the send invariant (no tool-wide send scope)
            // or a malformed shape; either way nothing was stored, so the row
            // stays absent and the caller learns instead of seeing a phantom.
            guard minted else {
                throw Abort(.badRequest, reason: "\(toolName) cannot be trusted under this scope")
            }
            let activeAllowRules = await context.permissionGate.activeRules()
            guard let rule = activeAllowRules.first(where: { (candidate: AccessRule) in
                candidate.action == .allow && candidate.toolName == toolName && candidate.scope == scope
            }) else {
                throw Abort(.badRequest, reason: "\(toolName) cannot be trusted under this scope")
            }
            storedRule = rule
        case .deny:
            // A standing refusal carries no expiry: a dated deny would lapse
            // into the allow decision underneath it, so the tier is ignored.
            try await context.permissionGate.denyRule(
                scope,
                toolName: toolName,
                reason: trimmedRuleReason(body.reason)
            )
            let activeDenyRules = await context.permissionGate.activeRules()
            guard let rule = activeDenyRules.first(where: { (candidate: AccessRule) in
                candidate.action == .deny && candidate.toolName == toolName && candidate.scope == scope
            }) else {
                throw Abort(.badRequest, reason: "\(toolName) cannot be refused under this scope")
            }
            storedRule = rule
        }
        // The new row changes what future calls decide, so every open dashboard
        // refetches instead of waiting for its next manual refresh.
        await context.hub.broadcastAccessRulesChanged()
        return AccessRuleResponse(storedRule)
    }
}

private func registerAccessRulesMutationRoutes(_ app: Application) {
    app.post(
        PathComponent.constant(ServerPaths.approvals),
        PathComponent.constant(ServerPaths.rules),
        PathComponent.parameter("id"),
        PathComponent.constant(ServerPaths.widen)
    ) { req async throws -> HTTPStatus in
        guard let raw = req.parameters.get("id"), let id = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "id must be a UUID")
        }
        let context = req.application.runeWeaver
        switch await context.permissionGate.widenGrant(id: id) {
        case .widened:
            await context.hub.broadcastAccessRulesChanged()
            return .noContent
        case .notFound:
            // An identifier that names no live rule stays 404 so a stale
            // dashboard row reads as gone rather than as a server refusal.
            throw Abort(.notFound, reason: "Unknown rule \(raw)")
        case let .notWidenable(reason):
            // The rule is live and listed, so "Unknown rule" would be
            // factually wrong; the refusal itself is the honest answer.
            throw Abort(.conflict, reason: reason)
        }
    }

    app.patch(
        PathComponent.constant(ServerPaths.approvals),
        PathComponent.constant(ServerPaths.rules),
        PathComponent.parameter("id")
    ) { req async throws -> HTTPStatus in
        guard let raw = req.parameters.get("id"), let id = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "id must be a UUID")
        }
        // A malformed duration string fails decoding before the gate runs, so
        // unknown tiers stay a caller 400 with file plus memory unchanged.
        let body = try req.content.decode(RearmRuleRequest.self)
        let context = req.application.runeWeaver
        switch await context.permissionGate.rearmGrant(id: id, duration: body.duration) {
        case .rearmed:
            // Re-arming rewrites expiry in place without minting a second row,
            // so dashboards must refetch the list to see the new duration.
            await context.hub.broadcastAccessRulesChanged()
            return .noContent
        case .notFound:
            // An identifier that names no live rule stays 404 so a stale or
            // lapsed row reads as gone rather than as a duration refusal.
            throw Abort(.notFound, reason: "Unknown rule \(raw)")
        case let .invalidDuration(reason):
            // The rule is live and listed, so "Unknown rule" would be
            // factually wrong; the tier refusal itself is the honest answer
            // and leaves file plus memory unchanged.
            throw Abort(.badRequest, reason: reason)
        }
    }
}

private func registerAccessRulesSessionTrustRoutes(_ app: Application) {
    app.get(
        PathComponent.constant(ServerPaths.approvals),
        PathComponent.constant(ServerPaths.sessionTrust)
    ) { req async throws -> SessionTrustResponse in
        guard let raw = req.query[String.self, at: "sessionID"],
              let sessionID = UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            throw Abort(.badRequest, reason: "sessionID must be a UUID")
        }
        let context = req.application.runeWeaver
        // Task grants read first, then session grants, so the caller can tell
        // a turn-scoped approval from a conversation-scoped one through the
        // duration tier alone.
        let grants = await context.permissionGate.ephemeralGrants(sessionID: sessionID).map(EphemeralGrantDTO.init)
        // The supervisor summary rides beside the gate grants so one read
        // proves the whole session posture; an unwired supervisor reads as no
        // ephemeral egress trust rather than failing the view.
        let summary = await context.egressSupervisor?.activeGrants(sessionID: sessionID)
        return SessionTrustResponse(
            sessionID: sessionID,
            grants: grants,
            egressSessionDomains: summary?.sessionDomains ?? [],
            egressOneShotDomains: summary?.oneShotDomains ?? []
        )
    }

    app.post(
        PathComponent.constant(ServerPaths.approvals),
        PathComponent.constant(ServerPaths.ephemeral),
        PathComponent.constant(ServerPaths.clear)
    ) { req async throws -> HTTPStatus in
        let body = try req.content.decode(EphemeralClearRequest.self)
        let context = req.application.runeWeaver
        // The gate's ephemeral tables and the supervisor's grant tables both
        // key on the session, so one clear drops every grant the conversation
        // still holds. An unknown session clears nothing and still answers
        // 204: the caller's row is already gone, which is the convergent
        // outcome rather than an error to surface.
        await context.permissionGate.clearSessionGrants(for: body.sessionID)
        if let supervisor = context.egressSupervisor {
            await supervisor.clearSession(sessionID: body.sessionID)
        }
        return .noContent
    }
}

/// Trimmed caller-facing reason for a deny mint, or nil when blank.
///
/// The gate renders a nil reason from the tool and scope, so a blank caller
/// note degrades to that derived text instead of storing an empty label.
/// A reason longer than ``maxRuleReasonChars`` is refused rather than
/// truncated, mirroring the scope canonicalizers: a denial reason is read
/// back to the agent, so a silently shortened note could say something the
/// owner never wrote, and the dashboard enforces the same cap in its modal.
/// - Parameter reason: Raw reason from the request.
/// - Returns: Trimmed reason, or nil when absent or blank.
/// - Throws: `Abort(.badRequest)` when the reason exceeds the stored bound.
private func trimmedRuleReason(_ reason: String?) throws -> String? {
    guard let reason else { return nil }
    let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
        return nil
    }
    guard trimmed.count <= maxRuleReasonChars else {
        throw Abort(.badRequest, reason: "reason must be at most \(maxRuleReasonChars) characters")
    }
    return trimmed
}

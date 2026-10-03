// Rune Weaver Server — Durable trust grants routes and change broadcast.
//
// Owns the trust-grants HTTP surface plus the lightweight change signal for
// grant/revoke broadcast (usage via poll/manual refresh): listing pruned active
// grants newest-first, revoking by identifier, re-arming an existing grant to
// a new duration tier, and widening an existing grant to all targets by
// identifier, with a hub broadcast notifying every connected client after
// durable changes that alter the grants list. Widen keeps an unknown
// identifier (404) distinct from a live grant whose tool has no tool-wide
// scope (409), so a listed grant is never refused as "unknown". Re-arm keeps
// an unknown identifier (404) distinct from a live grant carrying a
// non-durable tier (400), so a stale row reads as gone while a one-shot
// duration reads as a caller error.

import Foundation
import RuneWeaverCore
import Vapor

public extension WSHub {
    /// Broadcasts a durable-trust change so dashboards refresh their grants list.
    func broadcastTrustGrantsChanged() async {
        // Dashboards refetch `GET /approvals/grants` on this signal, so the
        // payload stays a lightweight discriminator instead of a full snapshot
        // that could drift from the pruned store contents. Routes through the
        // shared broadcast path so ordering and best-effort delivery stay
        // single-sourced with every other hub event.
        let text: String
        do {
            let data = try JSONEncoder().encode(WSTrustGrantsChanged())
            guard let encodedText = String(data: data, encoding: .utf8) else { return }
            text = encodedText
        } catch {
            RuneWeaverLog.server.error("WSHub: failed to encode trust grants changed frame: \(error.localizedDescription)")
            return
        }
        await broadcast(text: text)
    }
}

/// Registers the durable trust-grants list, revoke, duration re-arm, and
/// widen-to-all-targets routes.
/// - Parameter app: Application receiving the routes.
func registerTrustGrantsRoutes(_ app: Application) {
    app.get(
        PathComponent.constant(ServerPaths.approvals),
        PathComponent.constant(ServerPaths.grants)
    ) { req async throws -> TrustGrantsResponse in
        let context = req.application.runeWeaver
        // `activeGrants` prunes expired entries first, so one-shot approvals
        // and lapsed durations never surface here; `forever` grants carry a
        // nil expiry and always survive the prune.
        let grants = await context.permissionGate.activeGrants()
        let newestFirst = grants.sorted { $0.grantedAt > $1.grantedAt }
        return TrustGrantsResponse(grants: newestFirst.map(TrustGrantResponse.init))
    }

    app.delete(
        PathComponent.constant(ServerPaths.approvals),
        PathComponent.constant(ServerPaths.grants),
        PathComponent.parameter("id")
    ) { req async throws -> HTTPStatus in
        guard let raw = req.parameters.get("id"), let id = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "id must be a UUID")
        }
        let context = req.application.runeWeaver
        let removed = await context.permissionGate.revokeGrant(id: id)
        guard removed else {
            throw Abort(.notFound, reason: "Unknown grant \(raw)")
        }
        // Revocation only stops future matches; past allowed calls already
        // happened and stay in history, so dashboards must treat the delete
        // as future-only and not imply prior uses are undone.
        // Notify dashboards so a revoked grant disappears without a manual refresh.
        await context.hub.broadcastTrustGrantsChanged()
        return .noContent
    }

    app.post(
        PathComponent.constant(ServerPaths.approvals),
        PathComponent.constant(ServerPaths.grants),
        PathComponent.parameter("id"),
        PathComponent.constant(ServerPaths.widen)
    ) { req async throws -> HTTPStatus in
        guard let raw = req.parameters.get("id"), let id = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "id must be a UUID")
        }
        let context = req.application.runeWeaver
        switch await context.permissionGate.widenGrant(id: id) {
        case .widened:
            await context.hub.broadcastTrustGrantsChanged()
            return .noContent
        case .notFound:
            // An identifier that names no live grant stays 404 so a stale
            // dashboard row reads as gone rather than as a server refusal.
            throw Abort(.notFound, reason: "Unknown grant \(raw)")
        case let .notWidenable(reason):
            // The grant is live and listed, so "Unknown grant" would be
            // factually wrong; the refusal itself is the honest answer.
            throw Abort(.conflict, reason: reason)
        }
    }

    app.patch(
        PathComponent.constant(ServerPaths.approvals),
        PathComponent.constant(ServerPaths.grants),
        PathComponent.parameter("id")
    ) { req async throws -> HTTPStatus in
        guard let raw = req.parameters.get("id"), let id = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "id must be a UUID")
        }
        // A malformed duration string fails decoding before the gate runs, so
        // unknown tiers stay a caller 400 with file plus memory unchanged.
        let body = try req.content.decode(RearmGrantRequest.self)
        let context = req.application.runeWeaver
        switch await context.permissionGate.rearmGrant(id: id, duration: body.duration) {
        case .rearmed:
            // Re-arming rewrites expiry in place without minting a second row,
            // so dashboards must refetch the list to see the new duration.
            await context.hub.broadcastTrustGrantsChanged()
            return .noContent
        case .notFound:
            // An identifier that names no live grant stays 404 so a stale or
            // lapsed row reads as gone rather than as a duration refusal.
            throw Abort(.notFound, reason: "Unknown grant \(raw)")
        case let .invalidDuration(reason):
            // The grant is live and listed, so "Unknown grant" would be
            // factually wrong; the tier refusal itself is the honest answer
            // and leaves file plus memory unchanged.
            throw Abort(.badRequest, reason: reason)
        }
    }
}

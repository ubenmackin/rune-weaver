// Rune Weaver Server — Durable trust grants routes and change broadcast.
//
// Owns the trust-grants HTTP surface plus the lightweight change signal for
// grant/revoke broadcast (usage via poll/manual refresh): listing pruned active
// grants newest-first, revoking by identifier, and widening an existing grant to
// all targets by identifier, with a hub broadcast notifying every connected
// client after durable changes that alter the grants list.

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

/// Registers the durable trust-grants list, revoke, and widen-to-all-targets
/// routes.
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
        let widened = await context.permissionGate.widenGrant(id: id)
        guard widened else {
            throw Abort(.notFound, reason: "Unknown grant \(raw)")
        }
        await context.hub.broadcastTrustGrantsChanged()
        return .noContent
    }
}

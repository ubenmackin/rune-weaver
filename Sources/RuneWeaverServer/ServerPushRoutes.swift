// Rune Weaver Server — Web Push routes for public key, subscriptions, and test pushes.

import Foundation
import RuneWeaverCore
import Vapor

public struct VapidPublicKeyResponse: Content, Sendable {
    public let publicKey: String

    public init(publicKey: String) {
        self.publicKey = publicKey
    }
}

public struct PushSubscriptionPayload: Content, Sendable {
    public let endpoint: String
    public let p256dh: String
    public let auth: String
    public let userAgent: String?

    public init(endpoint: String, p256dh: String, auth: String, userAgent: String? = nil) {
        self.endpoint = endpoint
        self.p256dh = p256dh
        self.auth = auth
        self.userAgent = userAgent
    }
}

public struct PushSubscriptionResponse: Content, Sendable {
    public let status: String
    public let endpoint: String

    public init(status: String = "ok", endpoint: String) {
        self.status = status
        self.endpoint = endpoint
    }
}

public struct PushUnsubscribePayload: Content, Sendable {
    public let endpoint: String

    public init(endpoint: String) {
        self.endpoint = endpoint
    }
}

public struct PushUnsubscribeResponse: Content, Sendable {
    public let status: String
    public let removed: Bool

    public init(status: String = "ok", removed: Bool) {
        self.status = status
        self.removed = removed
    }
}

public struct PushTestResponse: Content, Sendable {
    public let status: String
    public let delivered: Int

    public init(status: String = "ok", delivered: Int) {
        self.status = status
        self.delivered = delivered
    }
}

/// Registers the Web Push routes on `/push`.
public func registerPushRoutes(_ app: Application) {
    let push = app.grouped(PathComponent.constant(ServerPaths.push))

    // GET /push/vapid-public-key
    push.get(PathComponent.constant(ServerPaths.vapidPublicKey)) { req async throws -> VapidPublicKeyResponse in
        let context = req.application.runeWeaver
        guard let sender = context.webPushSender else {
            throw Abort(.internalServerError, reason: "Web Push not configured.")
        }
        return VapidPublicKeyResponse(publicKey: sender.vapidKeys.publicKeyBase64URL)
    }

    // POST /push/subscriptions
    push.post(PathComponent.constant(ServerPaths.subscriptions)) { req async throws -> PushSubscriptionResponse in
        if req.application.runeWeaverAuth != nil, !req.runeWeaverAuthenticated {
            throw Abort(.unauthorized, reason: "Owner authentication required.")
        }
        let payload = try req.content.decode(PushSubscriptionPayload.self)
        let context = req.application.runeWeaver
        do {
            let record = try await context.pushSubscriptions.save(
                endpoint: payload.endpoint,
                p256dh: payload.p256dh,
                auth: payload.auth,
                userAgent: payload.userAgent
            )
            return PushSubscriptionResponse(endpoint: record.endpoint)
        } catch let error as PushSubscriptionError {
            throw Abort(.badRequest, reason: error.localizedDescription)
        }
    }

    // DELETE /push/subscriptions
    push.delete(PathComponent.constant(ServerPaths.subscriptions)) { req async throws -> PushUnsubscribeResponse in
        if req.application.runeWeaverAuth != nil, !req.runeWeaverAuthenticated {
            throw Abort(.unauthorized, reason: "Owner authentication required.")
        }
        let payload = try req.content.decode(PushUnsubscribePayload.self)
        let context = req.application.runeWeaver
        let removed = await context.pushSubscriptions.remove(endpoint: payload.endpoint)
        return PushUnsubscribeResponse(removed: removed)
    }

    // POST /push/test
    push.post(PathComponent.constant(ServerPaths.test)) { req async throws -> PushTestResponse in
        if req.application.runeWeaverAuth != nil, !req.runeWeaverAuthenticated {
            throw Abort(.unauthorized, reason: "Owner authentication required.")
        }
        let context = req.application.runeWeaver
        guard let sender = context.webPushSender else {
            throw Abort(.internalServerError, reason: "Web Push not configured.")
        }
        let delivered = await sender.broadcast(
            payload: WebPushSender.PushPayload(
                title: "Rune Weaver",
                body: "Test notification from your Rune Weaver server.",
                url: "/#approvals",
                tag: "test-alert"
            )
        )
        return PushTestResponse(delivered: delivered)
    }
}

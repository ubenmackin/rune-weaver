// Rune Weaver Server — Conversation session routes.
//
// Owns the session listing, retrieval, tool-action replay, rename, and
// deletion surface. Sessions are the durable unit clients resume against, so
// retrieval stays read-only while rename and delete funnel through the
// conversation manager's single entry points so working memory and billed
// token totals change together.

import Foundation
import RuneWeaverCore
import Vapor

/// Validates a session title once for the rename route.
func validatedSessionTitle(_ raw: String) throws -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        throw Abort(.badRequest, reason: "title must not be empty")
    }
    guard trimmed.count <= UpdateSessionRequest.maxTitleLength else {
        throw Abort(.payloadTooLarge, reason: "title exceeds \(UpdateSessionRequest.maxTitleLength) characters")
    }
    return trimmed
}

/// Registers session listing, retrieval, renaming, and deletion routes.
/// - Parameter app: Application receiving the routes.
func registerSessionRoutes(_ app: Application) {
    let sessions = app.grouped(PathComponent.constant(ServerPaths.sessions))
    sessions.get { req async throws -> SessionsResponse in
        let list = await req.application.runeWeaver.conversations.listSessions()
        return SessionsResponse(sessions: list)
    }
    sessions.get(PathComponent.parameter("id")) { req async throws -> ConversationSession in
        guard let raw = req.parameters.get("id"), let id = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "id must be a UUID")
        }
        guard let session = await req.application.runeWeaver.conversations.session(id: id) else {
            throw Abort(.notFound, reason: "Unknown session \(raw)")
        }
        return session
    }
    sessions.get(PathComponent.parameter("id"), PathComponent.constant(ServerPaths.toolActions)) { req async throws -> SessionToolActionsResponse in
        guard let raw = req.parameters.get("id"), let id = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "id must be a UUID")
        }
        let context = req.application.runeWeaver
        guard let session = await context.conversations.session(id: id) else {
            throw Abort(.notFound, reason: "Unknown session \(raw)")
        }
        // Authoritative per-message records derived server-side with the
        // shared placeholder parser, ordered oldest message first so
        // clients never regex-parse placeholder lines themselves.
        let grouped = await context.conversations.toolActionsByMessage(for: id)
        let actions = session.messages.compactMap { message -> SessionMessageToolActions? in
            guard let list = grouped[message.id] else { return nil }
            // Carry the parent note's persisted creation time so reloads reconcile
            // to the same server instant that live done frames advertise.
            return SessionMessageToolActions(messageID: message.id, actions: list, completedAt: message.createdAt.timeIntervalSince1970)
        }
        return SessionToolActionsResponse(sessionID: id, actions: actions)
    }
    sessions.patch(PathComponent.parameter("id")) { req async throws -> Response in
        guard let raw = req.parameters.get("id"), let id = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "id must be a UUID")
        }
        let body = try req.content.decode(UpdateSessionRequest.self)
        let title = try validatedSessionTitle(body.title)
        // Renaming an unknown session is a 404 like `GET /sessions/:id`,
        // not a silent no-op: `updateTitle` skips missing sessions.
        guard await req.application.runeWeaver.conversations.session(id: id) != nil else {
            throw Abort(.notFound, reason: "Unknown session \(raw)")
        }
        await req.application.runeWeaver.conversations.updateTitle(id: id, title: title)
        return Response(status: .noContent)
    }
    sessions.delete(PathComponent.parameter("id")) { req async throws -> Response in
        guard let raw = req.parameters.get("id"), let id = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "id must be a UUID")
        }
        // Single orchestrator entry point drops working memory and the
        // billed total together so deletes never leak token totals.
        await req.application.runeWeaver.orchestrator.removeSession(id: id)
        return Response(status: .noContent)
    }
}

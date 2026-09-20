// Rune Weaver Server — Run history routes.
//
// Owns the run-log listing, lookup, and deletion surface backing the dashboard
// history view. Run rows are the local audit trail for chat turns, direct tool
// calls, and scheduler firings, so listing stays bounded by a clamped limit
// while deletion is deliberate and explicit.

import Foundation
import Vapor

/// Registers run-log list plus entry routes.
func registerRunRoutes(_ app: Application) {
    app.get(PathComponent.constant(ServerPaths.runs)) { req async throws -> RunLogsResponse in
        let limit = try parseQueryLimit(req, default: 50, min: 1, max: 200)
        let jobID = req.query[String.self, at: "jobID"].flatMap { UUID(uuidString: $0) }
        // Session filters arrive under several client spellings, so accept the
        // camelCase pair plus the snake_case variant and resolve them to one
        // identifier before querying.
        let sessionID = req.query[String.self, at: "sessionID"]
            .flatMap { UUID(uuidString: $0) }
            ?? req.query[String.self, at: "sessionId"].flatMap { UUID(uuidString: $0) }
            ?? req.query[String.self, at: "session_id"].flatMap { UUID(uuidString: $0) }
        let entries = await req.application.runeWeaver.runs.list(limit: limit, jobID: jobID, sessionID: sessionID)
        return RunLogsResponse(runs: entries)
    }
    app.get(PathComponent.constant(ServerPaths.runs), PathComponent.parameter("id")) { req async throws -> RunLogEntry in
        guard let raw = req.parameters.get("id"), let id = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "id must be a UUID")
        }
        guard let entry = await req.application.runeWeaver.runs.entry(id: id) else {
            throw Abort(.notFound, reason: "Unknown run \(raw)")
        }
        return entry
    }
    app.delete(PathComponent.constant(ServerPaths.runs)) { req async throws -> Response in
        await req.application.runeWeaver.runs.clear()
        return Response(status: .noContent)
    }
    app.delete(PathComponent.constant(ServerPaths.runs), PathComponent.parameter("id")) { req async throws -> Response in
        guard let raw = req.parameters.get("id"), let id = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "id must be a UUID")
        }
        await req.application.runeWeaver.runs.delete(id: id)
        return Response(status: .noContent)
    }
}

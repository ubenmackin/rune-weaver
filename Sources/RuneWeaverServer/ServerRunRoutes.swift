// Rune Weaver Server — Run history routes.
//
// Owns the run-log listing, lookup, deletion, and fan-out cancellation surface
// backing the dashboard history view. Run rows are the local audit trail for
// chat turns, direct tool calls, and scheduler firings, so listing stays
// bounded by a clamped limit while deletion is deliberate and explicit. Only
// fan-out rows carry live work to stop; every other kind is immutable history.

import Foundation
import RuneWeaverCore
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
        // Goal filters accept the same camelCase plus snake_case spellings as
        // sessions so dashboards can scope run history to one tracked goal.
        let goalID = req.query[String.self, at: "goalID"]
            .flatMap { UUID(uuidString: $0) }
            ?? req.query[String.self, at: "goalId"].flatMap { UUID(uuidString: $0) }
            ?? req.query[String.self, at: "goal_id"].flatMap { UUID(uuidString: $0) }
        let entries = await req.application.runeWeaver.runs.list(limit: limit, jobID: jobID, sessionID: sessionID, goalID: goalID)
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
    app.post(
        PathComponent.constant(ServerPaths.runs),
        PathComponent.parameter("id"),
        PathComponent.constant(ServerPaths.runCancel)
    ) { req async throws -> RunCancelResponse in
        guard let raw = req.parameters.get("id"), let id = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "id must be a UUID")
        }
        let context = req.application.runeWeaver
        guard let row = await context.runs.entry(id: id) else {
            throw Abort(.notFound, reason: "Unknown run \(raw)")
        }
        // Only fan-out rows carry a live swarm or worker to stop. Every other
        // kind (chat, scheduler, goal, index, tool) is immutable history, so
        // the honest answer is a conflict rather than the `notRunning` a
        // fan-out row would get: otherwise a client would read "nothing
        // running" for a row that was never cancellable at all.
        guard row.kind == FanOutEngine.parentRowKind || row.kind == FanOutEngine.workerRowKind else {
            throw Abort(.conflict, reason: "Only fan-out rows support cancel")
        }
        switch await context.fanOut.cancel(rowID: id) {
        case let .runCancelled(workerCount):
            return RunCancelResponse(cancelled: true, scope: "run", workerCount: workerCount)
        case .workerCancelled:
            return RunCancelResponse(cancelled: true, scope: "worker")
        case .notRunning:
            // The engine's live registry owns liveness, not the row status: an
            // unknown row, an already-settled worker, and a swarm that already
            // settled all answer the same conflict so a late cancel can never
            // read as a successful stop.
            throw Abort(.conflict, reason: "Nothing running for this row.")
        }
    }
}

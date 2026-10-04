// Rune Weaver Server — Run history routes.
//
// Owns the run-log listing, lookup, deletion, and cancellation surface
// backing the dashboard history view. Run rows are the local audit trail for
// chat turns, direct tool calls, scheduler firings, goal advancements, and
// index runs, so listing stays bounded by a clamped limit while deletion is
// deliberate and explicit. Cancelling is cooperative: any running or parked
// awaiting_approval row settles to cancelled through its linked session with
// a hub broadcast, while settled rows answer conflict and fan-out rows
// cancel through the engine registry.

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
        if row.kind == FanOutEngine.parentRowKind || row.kind == FanOutEngine.workerRowKind {
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
        guard row.status == "running" || row.status == "awaiting_approval" else {
            throw Abort(.conflict, reason: "Nothing running for this row.")
        }
        let durationMs = Int(Date().timeIntervalSince(row.timestamp) * 1000)
        // The atomic settle owns the generation guard: only a still-live row
        // flips to cancelled, so a success that landed between the read above
        // and this write answers 409 instead of being resurrected, while the
        // cancelled-wins guard in `update` covers the opposite order. Parked
        // `awaiting_approval` rows cancel exactly like `running` rows through
        // the same cooperative contract plus steering clear, then settle to
        // `cancelled` with a hub broadcast.
        guard let updated = await context.runs.cancel(id: id, durationMs: durationMs) else {
            throw Abort(.conflict, reason: "Nothing running for this row.")
        }
        if let sessionID = row.sessionID {
            _ = await context.activeTurns.cancel(sessionID: sessionID)
            await context.steeringQueue.clear(for: sessionID)
        }
        await context.hub.broadcastRun(updated)
        return RunCancelResponse(cancelled: true, scope: "run")
    }
}

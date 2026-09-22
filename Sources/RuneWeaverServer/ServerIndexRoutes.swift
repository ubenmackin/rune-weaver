// Rune Weaver Server — Local document index status and control routes.
//
// Thin HTTP adapters over the injected `IndexCoordinator` and `DocIndexStore`:
// status reports aggregate counts, the last watermark, per-source enablement,
// recent failures, and live run state; run executes one on-demand pass; cancel
// asks an in-flight pass to stop at its next safe point; prune removes
// documents older than a cutoff; and reset clears the store. Run progress needs
// no new transport: it already rides the shared `ToolProgress`/WebSocket path
// and the `run_logs` audit stream the coordinator reports through.
//
// Policy stays single-sourced: the coordinator owns sequencing, cancellation,
// and the watermark; the store owns persistence; and config validation owns
// range and closed-set checks. These routes only translate outcomes to HTTP
// shapes and fail closed with a 503 when no index component is wired.

import Foundation
import RuneWeaverCore
import Vapor

/// Registers the local document index routes.
/// - Parameter app: Application receiving the routes.
func registerIndexRoutes(_ app: Application) {
    registerIndexStatusRoute(app)
    registerIndexRunRoute(app)
    registerIndexCancelRoute(app)
    registerIndexPruneRoute(app)
    registerIndexResetRoute(app)
}

/// Registers the status probe behind `GET /index/status`.
/// - Parameter app: Application receiving the route.
private func registerIndexStatusRoute(_ app: Application) {
    let index = app.grouped(PathComponent.constant(ServerPaths.index))

    index.get(PathComponent.constant(ServerPaths.indexStatus)) { req async throws -> IndexStatusResponse in
        let context = req.application.runeWeaver
        let config = try loadedIndexConfiguration()
        // A missing store or coordinator is a real absent component, not an
        // error: the probe reports zeroed counts and a stopped run so a stock
        // install still renders an honest empty state.
        let stats = try await context.indexStore?.stats()
        let running = await context.indexCoordinator?.isRunning ?? false
        let lastErrors = await recentIndexErrors(context: context)
        return makeIndexStatusResponse(config: config, stats: stats, running: running, lastErrors: lastErrors)
    }
}

/// Registers the on-demand run route behind `POST /index/run`.
///
/// The run is awaited like a chat turn: it can take minutes, and the matching
/// `POST /index/cancel` arrives on a concurrent request to stop it, so the
/// response always carries the terminal summary the dashboard renders.
/// - Parameter app: Application receiving the route.
private func registerIndexRunRoute(_ app: Application) {
    let index = app.grouped(PathComponent.constant(ServerPaths.index))

    index.post(PathComponent.constant(ServerPaths.indexRun)) { req async throws -> IndexRunResponse in
        let context = req.application.runeWeaver
        guard let coordinator = context.indexCoordinator else {
            throw Abort(.serviceUnavailable, reason: "Indexing is not configured.")
        }
        let summary = await coordinator.run(trigger: .onDemand)
        return IndexRunResponse(summary)
    }
}

/// Registers the cancellation route behind `POST /index/cancel`.
/// - Parameter app: Application receiving the route.
private func registerIndexCancelRoute(_ app: Application) {
    let index = app.grouped(PathComponent.constant(ServerPaths.index))

    index.post(PathComponent.constant(ServerPaths.indexCancel)) { req async throws -> IndexCancelResponse in
        let context = req.application.runeWeaver
        guard let coordinator = context.indexCoordinator else {
            throw Abort(.serviceUnavailable, reason: "Indexing is not configured.")
        }
        // Read liveness before asking to cancel: the flag is set immediately,
        // so a later probe could not distinguish a real abort from an idle
        // request, and the dashboard keys its notice off this one bit.
        let wasRunning = await coordinator.isRunning
        await coordinator.cancel()
        return IndexCancelResponse(cancelled: wasRunning)
    }
}

/// Registers the prune route behind `POST /index/prune`.
///
/// The cutoff is required: an absent `before` fails with 400 rather than
/// defaulting to now, so a bare prune can never silently clear the store.
/// - Parameter app: Application receiving the route.
private func registerIndexPruneRoute(_ app: Application) {
    let index = app.grouped(PathComponent.constant(ServerPaths.index))

    index.post(PathComponent.constant(ServerPaths.indexPrune)) { req async throws -> IndexPruneResponse in
        let context = req.application.runeWeaver
        guard let store = context.indexStore else {
            throw Abort(.serviceUnavailable, reason: "Indexing is not configured.")
        }
        // A missing cutoff and a malformed cutoff are distinct 400s: an empty
        // body carries no cutoff at all, so it keeps the missing-cutoff
        // message, while any present-but-undecodable body is a malformed
        // cutoff that must not masquerade as a missing one.
        let body: IndexPruneRequest
        do {
            body = try req.content.decode(IndexPruneRequest.self)
        } catch {
            let isEmpty = (req.body.data?.readableBytes ?? 0) == 0
            if isEmpty {
                throw Abort(.badRequest, reason: "Missing required cutoff: provide `before`.")
            }
            throw Abort(.badRequest, reason: "Invalid cutoff: 'before' must be an ISO-8601 date")
        }
        guard let cutoff = body.before else {
            throw Abort(.badRequest, reason: "Missing required cutoff: provide `before`.")
        }
        let removed = try await store.prune(before: cutoff)
        return IndexPruneResponse(removed: removed, before: cutoff)
    }
}

/// Registers the reset route behind `POST /index/reset`.
/// - Parameter app: Application receiving the route.
private func registerIndexResetRoute(_ app: Application) {
    let index = app.grouped(PathComponent.constant(ServerPaths.index))

    index.post(PathComponent.constant(ServerPaths.indexReset)) { req async throws -> IndexResetResponse in
        let context = req.application.runeWeaver
        guard let store = context.indexStore else {
            throw Abort(.serviceUnavailable, reason: "Indexing is not configured.")
        }
        try await store.reset()
        return IndexResetResponse(reset: true)
    }
}

/// Loads the active index policy, translating config failures into HTTP shapes.
/// - Returns: The `[index]` section of the stored configuration.
/// - Throws: `Abort(.badRequest)` for a rejected config and
///   `Abort(.internalServerError)` for an unreadable one.
private func loadedIndexConfiguration() throws -> IndexConfig {
    do {
        return try RuneWeaverConfig.loadDefault().index
    } catch let error as ConfigError {
        throw Abort(.badRequest, reason: String(describing: error))
    } catch {
        throw Abort(.internalServerError, reason: error.localizedDescription)
    }
}

/// Collects the most recent index run failures from the shared audit trail.
///
/// Only the `index`-kind rows already written by `ServerIndexRunReporter` are
/// consulted, so the status shape reuses the durable run log instead of adding
/// a second failure channel; rendering is bounded and carries no content.
/// - Parameters:
///   - context: Server context owning the run log.
///   - limit: Maximum failures to return, newest first.
/// - Returns: Failure detail strings, newest first.
private func recentIndexErrors(context: ServerContext, limit: Int = 5) async -> [String] {
    let recent = await context.runs.list(limit: 50)
    return recent
        .filter { $0.kind == ServerIndexRunReporter.kind && $0.status == IndexRunStatus.error.rawValue }
        .prefix(limit)
        .map { entry in
            let detail = entry.response?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (detail?.isEmpty == false ? detail : nil) ?? entry.message
        }
}

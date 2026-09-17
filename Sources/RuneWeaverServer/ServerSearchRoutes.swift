// Rune Weaver Server — Local SearXNG lifecycle routes for search settings.
//
// Thin HTTP adapters over the shared `SearXNGEnsurer`: health probes the
// configured base URL plus the live Start stage (resolving, daemon, pulling,
// starting, waiting with the Start time) so the dashboard can poll one
// endpoint about 1s for the amber Starting line, ensure collapses onto the
// self-healing cascade (runtime, daemon, start, pull, run, watch) with a
// trimmed banner plus chained diagnostics, stop halts the managed
// container, and remove deletes the container entry while leaving the image
// cache so the next Start recreates it. Lifecycle policy
// (loopback-only bind, per-install secret mount, tracked `:latest` image,
// 165s readiness watch ticking on short sleeps where reachable wins,
// terminal states fail fast with the logs tail and the backstop reports the
// last state plus logs, plus a minutes-budget pull when the image is absent,
// bounded 8s system start) lives single-source in the ensurer so boot,
// `web.search`, and these routes cannot drift; the routes only translate
// outcomes to HTTP shapes. Fresh runs track `:latest` by design so new
// installs follow upstream; pin via `SEARXNG_IMAGE` when reproducibility
// matters.
//
// Health reporting stays honest: ensure reports whether a local start was
// actually attempted plus the trimmed banner, warning with the container plus
// outcome plus chained per-stage diagnostics, stop re-probes after halting
// so the dashboard never shows Stopped while the engine still answers, and
// remove stops first then deletes so a running entry never half-deletes —
// when the engine still answers or the entry still lists afterwards the route
// refuses with guidance instead of claiming the entry is gone.

import Foundation
import RuneWeaverCore
import RuneWeaverTools
import Vapor

/// Registers the SearXNG lifecycle routes backing search settings.
/// Lifecycle logic lives single-sourced in `SearXNGEnsurer` (loopback-only
/// bind plus per-install secret mount); these routes only adapt it to HTTP.
/// Kept as a thin fan-out so no single body approaches the lint length
/// budget while boot, `web.search`, and these routes share one cascade.
func registerSearchRoutes(_ app: Application) {
    registerSearchHealthRoute(app)
    registerSearchEnsureRoute(app)
    registerSearchStopRoute(app)
    registerSearchRemoveRoute(app)
}

/// Registers the health probe backing the dashboard Starting line.
/// Split from the fan-out so the probe plus its live Start snapshot stays
/// independently readable as health shapes evolve.
/// - Parameter app: Application receiving the route.
private func registerSearchHealthRoute(_ app: Application) {
    let search = app.grouped(PathComponent.constant(ServerPaths.search))

    search.get(PathComponent.constant(ServerPaths.searchHealth)) { req async -> SearchHealthResponse in
        let context = req.application.runeWeaver
        let baseURL = context.browserConfig.searxngURL
        let reachable = await SearXNGEnsurer.isReachable(baseURL: baseURL)
        // Live stage rides along so a Start in flight renders its current step
        // plus elapsed time; nil when idle, so the dot alone decides the row.
        let progress = await SearXNGEnsurer.shared.currentStartProgress(for: baseURL)
        return SearchHealthResponse(
            reachable: reachable,
            baseURL: baseURL,
            containerName: SearXNGEnsurer.containerName,
            stage: progress?.stage.rawValue,
            startedAt: progress.map(\.startedAt.timeIntervalSince1970)
        )
    }
}

/// Registers the ensure route collapsing onto the shared self-healing cascade.
/// Split from the fan-out so cascade budgets plus banner threading stay
/// scoped to the one route that can trigger a Start.
/// - Parameter app: Application receiving the route.
private func registerSearchEnsureRoute(_ app: Application) {
    let search = app.grouped(PathComponent.constant(ServerPaths.search))

    search.post(PathComponent.constant(ServerPaths.searchEnsure)) { req async -> SearchEnsureResponse in
        let context = req.application.runeWeaver
        // Single-sourced through the shared ensurer so boot, search, and this
        // route collapse onto one in-flight attempt keyed by base URL instead
        // of duplicating the cascade budgets (shared `readinessWatchTimeoutSeconds`
        // 165s watch single-sourced in the ensurer plus a minutes-budget
        // pull when the image is absent). The trimmed banner threads
        // through for the inline slot while chained diagnostics thread through
        // for logs plus collapsed UI, so each failure renders once.
        let report = await SearXNGEnsurer.shared.ensureReport(browser: context.browserConfig)
        // Warn with the container plus outcome plus chained per-stage detail so
        // operator logs keep every failing stage without re-running the cascade;
        // the banner stays trimmed to terminal cause plus one command.
        if !report.reachable {
            let container = SearXNGEnsurer.containerName
            let banner = report.message ?? "none"
            let chained = report.diagnostics ?? "none"
            let warningMessage =
                "SearXNG ensure container=\(container) reachable=\(report.reachable) "
                    + "started=\(report.started) message=\(banner) diagnostics=\(chained)"
            req.logger.warning("\(warningMessage)")
            RuneWeaverLog.server.warning("\(warningMessage)")
        }
        return SearchEnsureResponse(
            reachable: report.reachable,
            baseURL: context.browserConfig.searxngURL,
            started: report.started,
            message: report.message,
            diagnostics: report.diagnostics
        )
    }
}

/// Registers the stop route with its honest post-halt re-probe.
/// Split from the fan-out so the halt-then-probe ordering stays scoped to
/// the one route that must never report Stopped while search answers.
/// - Parameter app: Application receiving the route.
private func registerSearchStopRoute(_ app: Application) {
    let search = app.grouped(PathComponent.constant(ServerPaths.search))

    search.post(PathComponent.constant(ServerPaths.searchStop)) { req async -> SearchStopResponse in
        let context = req.application.runeWeaver
        let baseURL = context.browserConfig.searxngURL
        // Best-effort halt followed by an honest probe: a missing runtime, a
        // failed stop, or an engine that still answers must surface as still
        // reachable so the UI never shows Stopped while search still answers.
        // A failed stop also carries a failure detail in `message` so the
        // dashboard error slot can render why the halt did not take.
        // Later searches re-ensure on demand via the same container name.
        await SearXNGEnsurer.bestEffortStop()
        let reachable = await SearXNGEnsurer.isReachable(baseURL: baseURL)
        let container = SearXNGEnsurer.containerName
        if reachable {
            let warningMessage =
                "SearXNG stop container=\(container) reachable=\(reachable) message=still reachable"
            req.logger.warning("\(warningMessage)")
            RuneWeaverLog.server.warning("\(warningMessage)")
        }
        return SearchStopResponse(
            stopped: !reachable,
            containerName: container,
            reachable: reachable,
            baseURL: baseURL,
            status: reachable ? "running" : "stopped",
            message: reachable ? "Stop did not halt \(container); engine still reachable at \(baseURL)." : nil
        )
    }
}

/// Registers the remove route with its stop-then-delete ordering.
/// Split from the fan-out so the reachable re-probe plus the still-listed
/// check stay scoped to the one route that must refuse a half-delete.
/// - Parameter app: Application receiving the route.
private func registerSearchRemoveRoute(_ app: Application) {
    let search = app.grouped(PathComponent.constant(ServerPaths.search))

    search.post(PathComponent.constant(ServerPaths.searchRemove)) { req async -> SearchRemoveResponse in
        let context = req.application.runeWeaver
        let baseURL = context.browserConfig.searxngURL
        let container = SearXNGEnsurer.containerName
        // Stop-then-rm ordering keeps a running entry from half-deleting: the
        // halt runs first so the delete below never races a live container,
        // and the image itself is never pulled or pruned here so the next
        // Start recreates from cache. Later searches re-ensure on demand via
        // the same container name.
        await SearXNGEnsurer.bestEffortStop()
        let runtime = SearXNGEnsurer.resolveRuntimeURL()
        if let runtime {
            await SearXNGEnsurer.removeStaleContainer(runtime: runtime)
        }
        // Honest re-probe first: when the engine still answers the halt or the
        // delete did not take, refuse with guidance instead of claiming removed
        // so the dashboard never shows a deleted entry while search answers.
        let reachable = await SearXNGEnsurer.isReachable(baseURL: baseURL)
        if reachable {
            let warningMessage =
                "SearXNG remove container=\(container) reachable=\(reachable) message=still reachable"
            req.logger.warning("\(warningMessage)")
            RuneWeaverLog.server.warning("\(warningMessage)")
            return SearchRemoveResponse(
                removed: false,
                containerName: container,
                reachable: true,
                baseURL: baseURL,
                status: "running",
                message: "Remove did not delete \(container); engine still reachable at \(baseURL). Stop the container first, then retry remove."
            )
        }
        // Reachable is down but a stopped entry can still linger when the `rm`
        // misses; the existence listing decides removed so a stopped-but-present
        // entry reports not-removed with retry guidance rather than silently
        // claiming a full delete.
        if let runtime {
            let stillListed = await SearXNGEnsurer.containerEntryExists(runtime: runtime)
            if stillListed {
                let warningMessage =
                    "SearXNG remove container=\(container) reachable=\(reachable) message=entry still listed"
                req.logger.warning("\(warningMessage)")
                RuneWeaverLog.server.warning("\(warningMessage)")
                return SearchRemoveResponse(
                    removed: false,
                    containerName: container,
                    reachable: false,
                    baseURL: baseURL,
                    status: "stopped",
                    message: "Remove stopped \(container) but did not delete it; the entry still exists. Retry remove."
                )
            }
        }
        return SearchRemoveResponse(
            removed: true,
            containerName: container,
            reachable: false,
            baseURL: baseURL,
            status: "stopped",
            message: nil
        )
    }
}

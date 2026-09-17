// Rune Weaver Server — Local SearXNG lifecycle routes for search settings.
//
// Thin HTTP adapters over the shared `SearXNGEnsurer`: health probes the
// configured base URL plus the live Start stage (resolving, daemon, pulling,
// starting, waiting with the Start time) so the dashboard can poll one
// endpoint about 1s for the amber Starting line, ensure collapses onto the
// self-healing cascade (runtime, daemon, start, pull, run, poll) with a
// trimmed banner plus chained diagnostics, and stop halts the managed
// container. Lifecycle policy
// (loopback-only bind, per-install secret mount, tracked `:latest` image,
// final poll 10s with 500 ms polls inside an about-41s cached worst-case
// cascade plus a minutes-budget pull when the image is absent,
// bounded 8s system start) lives single-source in the ensurer so boot,
// `web.search`, and these routes cannot drift; the routes only translate
// outcomes to HTTP shapes. Fresh runs track `:latest` by design so new
// installs follow upstream; pin via `SEARXNG_IMAGE` when reproducibility
// matters.
//
// Health reporting stays honest: ensure reports whether a local start was
// actually attempted plus the trimmed banner, warning with the container plus
// outcome plus chained per-stage diagnostics, and stop re-probes after halting
// so the dashboard never shows Stopped while the engine still answers.

import Foundation
import RuneWeaverCore
import RuneWeaverTools
import Vapor

/// Registers the SearXNG lifecycle routes backing search settings.
/// Lifecycle logic lives single-sourced in `SearXNGEnsurer` (loopback-only
/// bind plus per-install secret mount); these routes only adapt it to HTTP.
func registerSearchRoutes(_ app: Application) {
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

    search.post(PathComponent.constant(ServerPaths.searchEnsure)) { req async -> SearchEnsureResponse in
        let context = req.application.runeWeaver
        // Single-sourced through the shared ensurer so boot, search, and this
        // route collapse onto one in-flight attempt keyed by base URL instead
        // of duplicating the cascade budgets (final poll 10s with 500 ms
        // polls inside the about-41s cached cascade plus a minutes-budget
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

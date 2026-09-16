// Rune Weaver Server — Local SearXNG lifecycle routes for search settings.
//
// Thin HTTP adapters over the shared `SearXNGEnsurer`: health probes the
// configured base URL, ensure collapses onto the single-flight start-and-poll
// path, and stop halts the managed container. Lifecycle policy (loopback-only
// bind, per-install secret mount, pinned image, 10s budget with 500 ms polls)
// lives single-source in the ensurer so boot, `web.search`, and these routes
// cannot drift; the routes only translate outcomes to HTTP shapes.
//
// Health reporting stays honest: ensure reports whether a local start was
// actually attempted, and stop re-probes after halting so the dashboard never
// shows Stopped while the engine still answers.

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
        return SearchHealthResponse(
            reachable: reachable,
            baseURL: baseURL,
            containerName: SearXNGEnsurer.containerName
        )
    }

    search.post(PathComponent.constant(ServerPaths.searchEnsure)) { req async -> SearchEnsureResponse in
        let context = req.application.runeWeaver
        // Single-sourced through the shared ensurer so boot, search, and this
        // route collapse onto one in-flight attempt keyed by base URL instead
        // of duplicating the 10s budget and 500ms poll.
        let report = await SearXNGEnsurer.shared.ensureReport(browser: context.browserConfig)
        return SearchEnsureResponse(
            reachable: report.reachable,
            baseURL: context.browserConfig.searxngURL,
            started: report.started
        )
    }

    search.post(PathComponent.constant(ServerPaths.searchStop)) { req async -> SearchStopResponse in
        let context = req.application.runeWeaver
        let baseURL = context.browserConfig.searxngURL
        // Best-effort halt followed by an honest probe: a missing runtime, a
        // failed stop, or an engine that still answers must surface as still
        // reachable so the UI never shows Stopped while search still answers.
        // Later searches re-ensure on demand via the same container name.
        await SearXNGEnsurer.bestEffortStop()
        let reachable = await SearXNGEnsurer.isReachable(baseURL: baseURL)
        return SearchStopResponse(
            stopped: !reachable,
            containerName: SearXNGEnsurer.containerName,
            reachable: reachable,
            baseURL: baseURL,
            status: reachable ? "running" : "stopped"
        )
    }
}

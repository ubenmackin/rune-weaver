// Rune Weaver Server — Settings read/persist routes and live-reload helpers.
//
// Owns `GET`/`PUT /settings`: load, merge, validate, and persist the engine
// config, then push the saved values into the live engine so orchestrator
// budgets, media/browser/web/API tools, desktop policy, and index policy take
// effect without a restart.

import Foundation
import RuneWeaverCore
import RuneWeaverTools
import Vapor

/// Registers settings routes for reading and persisting configuration.
func registerSettingsRoutes(_ app: Application) {
    let settings = app.grouped(PathComponent.constant(ServerPaths.settings))
    settings.get { _ async throws -> SettingsResponse in
        let url = RuneWeaverConfig.defaultConfigFileURL()
        let config: RuneWeaverConfig
        do {
            config = try RuneWeaverConfig.loadDefault()
        } catch let error as ConfigError {
            throw Abort(.badRequest, reason: String(describing: error))
        } catch {
            throw Abort(.internalServerError, reason: error.localizedDescription)
        }
        return SettingsResponse(config: config, configPath: url.path)
    }
    settings.put { req async throws -> SettingsResponse in
        let body = try req.content.decode(UpdateSettingsRequest.self)
        let url = RuneWeaverConfig.defaultConfigFileURL()
        var config: RuneWeaverConfig
        do {
            config = try RuneWeaverConfig.loadDefault()
        } catch let error as ConfigError {
            throw Abort(.badRequest, reason: String(describing: error))
        } catch {
            throw Abort(.internalServerError, reason: error.localizedDescription)
        }
        do {
            try body.apply(to: &config)
            // Validate the merged config before persisting so a single bad
            // field cannot corrupt the stored file or live engine state.
            try config.validate()
            try config.save(to: url)
            let liveContext = req.application.runeWeaver
            await applyLiveOrchestratorTuning(body: body, context: liveContext)
            await reloadLiveMediaTools(body: body, config: config, context: liveContext)
            await reloadLiveNetworkTools(body: body, config: config, context: liveContext)
            await reloadLiveDesktopTools(body: body, config: config, context: liveContext)
            await reloadLiveIndexPolicy(body: body, config: config, context: liveContext)
        } catch let error as ConfigError {
            throw Abort(.badRequest, reason: String(describing: error))
        } catch {
            throw Abort(.internalServerError, reason: error.localizedDescription)
        }
        return SettingsResponse(config: config, configPath: url.path)
    }
}

/// Pushes persisted engine budgets into the live orchestrator so saved values take effect without a restart.
private func applyLiveOrchestratorTuning(body: UpdateSettingsRequest, context: ServerContext) async {
    if let maxToolIterations = body.maxToolIterations {
        await context.orchestrator.updateMaxToolIterations(maxToolIterations)
    }
    // Push the persisted compaction threshold into the live engine so
    // the saved value takes effect immediately instead of staying stale
    // until the next restart.
    if let compactionThresholdPercent = body.compactionThresholdPercent {
        await context.orchestrator.updateCompactionPercent(compactionThresholdPercent)
    }
}

/// Reloads media tools when media settings changed so Sonarr / Radarr picks up URLs without a restart.
/// Stored transports ride along so hermetic doubles survive a settings PUT instead of resetting to live defaults.
private func reloadLiveMediaTools(body: UpdateSettingsRequest, config: RuneWeaverConfig, context: ServerContext) async {
    guard body.media != nil else { return }
    for tool in MediaTools.makeTools(
        mediaConfig: config.media, transport: context.mediaTransport, secrets: context.mediaSecrets
    ) {
        let isEnabled = await context.toolBus.isToolEnabled(named: tool.name)
        await context.toolBus.register(tool: tool, isEnabled: isEnabled)
    }
}

/// Rebuilds the Playwright bridge with fresh origins while preserving injected doubles.
/// A managed subprocess gateway keeps its executable and budgets; a test double survives as-is.
private func gatewayForLiveReload(
    stored: (any BrowserPlaywrightGateway)?,
    busGateway: (any BrowserPlaywrightGateway)?,
    origins: Set<String>
) -> (any BrowserPlaywrightGateway)? {
    let baseGateway = stored ?? busGateway
    if let baseGateway, let managed = baseGateway as? SubprocessPlaywrightGateway {
        return SubprocessPlaywrightGateway(
            pythonExecutable: managed.pythonExecutable,
            timeoutSeconds: managed.timeoutSeconds,
            maxOutputBytes: managed.maxOutputBytes,
            allowlistedOrigins: origins
        )
    }
    return baseGateway
}

/// Reloads browser, web, and API tools when origins may have changed so homelab hosts apply immediately.
/// The stored gateway and transports ride along so a settings PUT refreshes origins without dropping the bridge.
private func reloadLiveNetworkTools(body: UpdateSettingsRequest, config: RuneWeaverConfig, context: ServerContext) async {
    // Provider endpoints feed the SSRF exemption set, so an LLM-endpoint change
    // must refresh live tools immediately rather than waiting for a restart.
    guard body.media != nil || body.browserAllowedOrigins != nil || body.browserSearxngURL != nil
        || body.searchSearxngURL != nil || body.providers != nil || body.defaultProvider != nil
        || body.fallbackProvider != nil
    else {
        return
    }
    let appLLMOrigins = LLMOrigins.serverURLs(from: config.llm)
    let browserOrigins = ApiSSRFGuard.allowlistedOrigins(
        browserConfig: config.browser,
        mediaConfig: config.media,
        llmServerURLs: appLLMOrigins
    )
    let busGateway: (any BrowserPlaywrightGateway)? = if let existing =
        await context.toolBus.tool(named: "browser.navigate") as? BrowserNavigateTool
    {
        existing.browserGateway
    } else {
        nil
    }
    if let gatewayForReload = gatewayForLiveReload(stored: context.browserGateway, busGateway: busGateway, origins: browserOrigins) {
        for tool in BrowserTools.makeTools(gateway: gatewayForReload, allowlistedOrigins: browserOrigins) {
            let isEnabled = await context.toolBus.isToolEnabled(named: tool.name)
            await context.toolBus.register(tool: tool, isEnabled: isEnabled)
        }
    } else {
        for tool in BrowserTools.makeTools(allowlistedOrigins: browserOrigins) {
            let isEnabled = await context.toolBus.isToolEnabled(named: tool.name)
            await context.toolBus.register(tool: tool, isEnabled: isEnabled)
        }
    }
    for tool in WebTools.makeTools(
        browserConfig: config.browser,
        mediaConfig: config.media,
        searchTransport: context.searchTransport,
        fetchTransport: context.fetchTransport,
        ensurer: context.searchEnsurer
    ) {
        let isEnabled = await context.toolBus.isToolEnabled(named: tool.name)
        await context.toolBus.register(tool: tool, isEnabled: isEnabled)
    }
    for tool in ApiRequestTools.makeTools(
        browserConfig: config.browser,
        mediaConfig: config.media,
        llmServerURLs: appLLMOrigins,
        transport: context.apiTransport
    ) {
        let isEnabled = await context.toolBus.isToolEnabled(named: tool.name)
        await context.toolBus.register(tool: tool, isEnabled: isEnabled)
    }
}

/// Reconciles live desktop tools with the persisted `[desktop]` policy so saved values take effect without a restart.
/// Follows the media reload pattern: a nil desktop patch is a no-op, stored
/// bridges ride along so hermetic doubles survive a settings PUT, and each
/// re-registered tool keeps its live enabled state. Both tools stay
/// registered (never absent from `GET /tools`); the fresh allow policy is
/// pushed into the context and re-applied over restored rows, so a toggle
/// turned off force-disables its tool while a toggle turned on still ships
/// the tool disabled until the operator enables it through the tool-state
/// route.
private func reloadLiveDesktopTools(body: UpdateSettingsRequest, config: RuneWeaverConfig, context: ServerContext) async {
    guard body.desktop != nil else { return }
    context.desktopConfig = config.desktop
    for tool in DesktopTools.makeTools(
        desktopConfig: config.desktop,
        captureBridge: context.desktopCaptureBridge,
        controlBridge: context.desktopControlBridge
    ) {
        let isEnabled = await context.toolBus.isToolEnabled(named: tool.name)
        await context.toolBus.register(tool: tool, isEnabled: isEnabled)
    }
    await context.restoreToolStates()
}

/// Applies the saved `[index]` policy to the live coordinator so the next run uses new values without a restart.
/// Status already reads the file live; this keeps the run gate in lockstep for coordinators wired at boot.
/// When no coordinator is wired (index disabled at boot), the next boot picks up the policy.
private func reloadLiveIndexPolicy(body: UpdateSettingsRequest, config: RuneWeaverConfig, context: ServerContext) async {
    guard body.index != nil else { return }
    guard let coordinator = context.indexCoordinator else { return }
    await coordinator.updateConfig(config.index)
}

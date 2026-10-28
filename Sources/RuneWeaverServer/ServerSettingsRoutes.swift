// Rune Weaver Server — Settings read/persist routes and live-reload helpers.

import Foundation
import RuneWeaverCore
import RuneWeaverLLM
import RuneWeaverTools
import Vapor

/// Registers settings routes for reading and persisting configuration.
func registerSettingsRoutes(_ app: Application) {
    let settings = app.grouped(PathComponent.constant(ServerPaths.settings))
    registerSettingsConfigRoutes(settings)
    registerSettingsSecretsRoutes(settings)
    registerSettingsPolicyRoutes(settings)
}

private func registerSettingsConfigRoutes(_ settings: RoutesBuilder) {
    settings.get { req async throws -> Response in
        let url = RuneWeaverConfig.defaultConfigFileURL()
        let config: RuneWeaverConfig
        do {
            config = try RuneWeaverConfig.loadDefault()
        } catch let error as ConfigError {
            throw Abort(.badRequest, reason: String(describing: error))
        } catch {
            throw Abort(.internalServerError, reason: error.localizedDescription)
        }
        let response = try await SettingsResponse(config: config, configPath: url.path).encodeResponse(for: req)
        response.headers.replaceOrAdd(name: "Cache-Control", value: "no-store, private")
        return response
    }
    settings.put { req async throws -> Response in
        try await handlePutSettings(req: req)
    }
}

private func handlePutSettings(req: Request) async throws -> Response {
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
    // Snapshot the stored bind before the merge so the response advertises a restart only when the
    // file values actually move.
    let oldServerHostname = config.server.hostname
    let oldServerPort = config.server.port
    let oldServerAllowedHosts = config.server.allowedHosts
    let oldLLMConfig = config.llm
    let oldGoals = config.goals
    let oldProactive = config.proactive
    let oldIdeas = config.ideas
    let oldPersona = config.persona
    // Snapshot the stored bash policy before the single merge so the changed
    // flag reflects a real move, not merely a non-empty patch.
    let bashBefore = BashSettingsUpdate(bash: config.bash)
    // Snapshot the stored containers policy before the single merge so the
    // changed flag reflects a real move, not merely a non-empty patch.
    let containersBefore = config.containers
    do {
        try body.apply(to: &config)
        let bashChanged = BashSettingsUpdate(bash: config.bash) != bashBefore
        // Validate the merged config before persisting so a single bad
        // field cannot corrupt the stored file or live engine state.
        try config.validate()
        // Deep-compare decides whether the containers generation moves, so
        // resending identical bounds skips the ledger update plus tool
        // rebuild instead of churning them on every full-form save.
        let containersChanged = config.containers != containersBefore
        // The bind and the Host gate stay on the boot values, so only a real
        // hostname/port/allowed_hosts change needs a restart.
        let normalizedHostname = canonicalRestartHost(config.server.hostname)
        let normalizedOldHostname = canonicalRestartHost(oldServerHostname)
        let normalizedAllowedHosts = config.server.allowedHosts.map {
            canonicalRestartHost(UpdateSettingsRequest.normalizedAllowedHost($0))
        }
        let normalizedOldAllowedHosts = oldServerAllowedHosts.map {
            canonicalRestartHost(UpdateSettingsRequest.normalizedAllowedHost($0))
        }
        let serverChanged = body.carriesServerPatch
            && (normalizedHostname != normalizedOldHostname
                || config.server.port != oldServerPort
                || Set(normalizedAllowedHosts) != Set(normalizedOldAllowedHosts))
        let llmChanged = config.llm != oldLLMConfig
        // `[goals]`, `[proactive]`, `[ideas]`, and `[persona]` persist to the file through the same
        // partial-patch merge but take effect on restart: the pursuit engine, the scheduler worker,
        // the ideas engine, and the prompt composer's owner-authored identity hold their policy from.
        let goalsChanged = config.goals != oldGoals
        let proactiveChanged = config.proactive != oldProactive
        let ideasChanged = config.ideas != oldIdeas
        let personaChanged = config.persona != oldPersona
        // LLM providers, budgets, tools, bash, containers, and network apply live
        // through the shared context and never join the restart set.
        let needsRestart = serverChanged || goalsChanged || proactiveChanged || ideasChanged || personaChanged
        let liveContext = req.application.runeWeaver
        // Fail-closed bind guard: a changed non-loopback hostname persists only when an owner token
        // resolves.
        if serverChanged, !UpdateSettingsRequest.isLoopbackHostname(config.server.hostname) {
            let hasToken = await serverBindHasOwnerToken(config: config)
            guard hasToken else {
                throw Abort(
                    .badRequest,
                    reason: "Refusing to save non-loopback hostname '\(config.server.hostname)' without a configured owner token. "
                        + "Set [server] hostname to a loopback address (127.0.0.1, localhost, ::1, or [::1]), "
                        + "or run 'rune-weaver auth token generate' to enable LAN binds."
                )
            }
        }
        // Fail-closed pre-save probe: a rejected `db_path` throws before the file is persisted and
        // before any live tool state mutates, so the durable file and live desktop/index state never
        // diverge.
        let prebuiltIndexComponents = try await preflightLiveIndexPolicy(savedConfig: config, context: liveContext, patchPresent: body.index != nil)
        if bashChanged {
            // Prove the rendered bytes reparse to the merged bash before touching
            // the durable file, so a serialization gap never leaves the file
            // holding a policy the live tools refuse to adopt.
            let proofURL = FileManager.default.temporaryDirectory.appendingPathComponent("runeweaver-bash-proof-\(UUID().uuidString).toml")
            defer { try? FileManager.default.removeItem(at: proofURL) }
            let reparsed: RuneWeaverConfig
            do {
                try config.save(to: proofURL)
                reparsed = try RuneWeaverConfig.load(from: proofURL)
            } catch {
                throw Abort(.internalServerError, reason: "Saved bash policy did not round-trip; refusing to update live tools: \(error)")
            }
            guard reparsed.bash == config.bash else {
                throw Abort(.internalServerError, reason: "Saved bash policy did not round-trip; refusing to update live tools.")
            }
        }
        // Fail-closed pre-save probe: resolve the LLM swap before the file persists so a rejected
        // provider set leaves both the durable file and the live engines on the stored generation.
        var llmSwap: LiveLLMSwap?
        if llmChanged {
            llmSwap = try await prepareLiveLLMSwap(config: config, context: liveContext)
        }
        try config.save(to: url)
        if let swap = llmSwap {
            await applyLiveLLMSwap(swap, context: liveContext)
        }
        await applyLiveOrchestratorTuning(body: body, context: liveContext)
        await applyLiveRecallBudgets(body: body, config: config, context: liveContext)
        await reloadLiveMediaTools(body: body, config: config, context: liveContext)
        try await reloadLiveNetworkTools(body: body, config: config, context: liveContext)
        await reloadLiveDesktopTools(body: body, config: config, context: liveContext)
        await reloadLiveBashFilesTools(body: body, config: config, context: liveContext, bashChanged: bashChanged, containersChanged: containersChanged)
        await reloadLiveFanOut(body: body, config: config, context: liveContext)
        await reloadLiveNotifications(body: body, config: config, context: liveContext)
        try await reloadLiveIndexPolicy(body: body, config: config, context: liveContext, prebuilt: prebuiltIndexComponents)
        // Configured services seed the allowlist through the shared derivation
        // the boot supervisor uses, so both paths pre-authorize exactly the
        // same hosts and a service source added there is never skipped here.
        await ensureConfiguredServiceEgressCandidates(config: config, store: liveContext.policyStore)
        // The saved file changes what Settings lists, so open tabs refetch
        // instead of waiting for a manual refresh.
        await liveContext.hub.broadcastSettingsChanged()
        // The bind and the Host middleware stay on the boot values: a
        // `[server]` save persists to the file and returns `requiresRestart`
        // without touching the live socket or middleware set.
        let response = try await SettingsResponse(config: config, configPath: url.path, requiresRestart: needsRestart).encodeResponse(for: req)
        response.headers.replaceOrAdd(name: "Cache-Control", value: "no-store, private")
        return response
    } catch let abort as Abort {
        throw abort
    } catch let error as ConfigError {
        throw Abort(.badRequest, reason: String(describing: error))
    } catch {
        throw Abort(.internalServerError, reason: error.localizedDescription)
    }
}

/// Seeds the configured-service egress candidates into the shared policy store.
func ensureConfiguredServiceEgressCandidates(config: RuneWeaverConfig, store: PolicyStore) async {
    await store.ensureServiceDomainsAllowed(urlsOrHosts: config.serviceEgressCandidates)
}

/// Maximum secret value bytes accepted by the store route. Bounds the Keychain write so an
/// unbounded body cannot pressure the Keychain or memory.
private let maxSecretStoreBytes = 16 * 1024

/// Maximum keys accepted per status lookup.
let maxSecretStatusKeys = 500

/// Validates a raw secret key for the secrets routes. Delegates the shape rule and the sovereign
/// reservation to the core single owner so store, status, and delete agree without duplicating
/// the alphabet, the length bound, or the reserved prefix. Internal so the route contract stays
/// pinned by the server tests.
func validateSecretKey(_ rawKey: String) throws -> String {
    let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard SecretsManager.isValidSurrogateKey(rawKey) else {
        if key.count > SecretsManager.maxSurrogateKeyLength {
            throw Abort(.badRequest, reason: "Key must not exceed \(SecretsManager.maxSurrogateKeyLength) characters.")
        }
        throw Abort(.badRequest, reason: "Key must not be empty and must contain only alphanumeric characters, underscores, hyphens, and periods.")
    }
    guard !SecretsManager.isReservedAccount(key) else {
        throw Abort(.badRequest, reason: "Keys prefixed '\(SecretsManager.reservedAccountPrefix)' are reserved for sovereign ledger material.")
    }
    return key
}

private func registerSettingsSecretsRoutes(_ settings: RoutesBuilder) {
    // Keychain secret management routes.
    let secretsGroup = settings.grouped(PathComponent.constant(ServerPaths.secrets))

    secretsGroup.get { req async throws -> Response in
        let secrets = req.application.runeWeaver.secrets ?? SecretsManager()
        do {
            let keys = try await secrets.listKeys()
            let response = try await SecretListResponse(keys: keys).encodeResponse(for: req)
            response.headers.replaceOrAdd(name: "Cache-Control", value: "no-store, private")
            return response
        } catch {
            throw Abort(.internalServerError, reason: "Failed to list secrets from Keychain: \(error.localizedDescription)")
        }
    }

    secretsGroup.post { req async throws -> Response in
        let body = try req.content.decode(StoreSecretRequest.self)
        let key = try validateSecretKey(body.key)
        guard !body.secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Abort(.badRequest, reason: "Secret must not be empty.")
        }
        guard body.secret.utf8.count <= maxSecretStoreBytes else {
            throw Abort(.payloadTooLarge, reason: "Secret exceeds \(maxSecretStoreBytes) bytes.")
        }
        let secrets = req.application.runeWeaver.secrets ?? SecretsManager()
        do {
            try await secrets.store(key: key, secret: body.secret)
        } catch {
            throw Abort(.internalServerError, reason: "Failed to store secret in Keychain: \(error.localizedDescription)")
        }
        let response = Response(status: .noContent)
        response.headers.replaceOrAdd(name: "Cache-Control", value: "no-store, private")
        return response
    }

    secretsGroup.post(PathComponent.constant(ServerPaths.status)) { req async throws -> Response in
        let body = try req.content.decode(SecretStatusRequest.self)
        guard body.keys.count <= maxSecretStatusKeys else {
            throw Abort(.badRequest, reason: "Keys must not exceed \(maxSecretStatusKeys) entries.")
        }
        let secrets = req.application.runeWeaver.secrets ?? SecretsManager()
        var statusMap: [String: Bool] = [:]
        for rawKey in body.keys {
            let key = try validateSecretKey(rawKey)
            do {
                let val = try await secrets.retrieve(key: key)
                statusMap[key] = !(val?.isEmpty ?? true)
            } catch {
                throw Abort(.internalServerError, reason: "Failed to retrieve secret status from Keychain: \(error.localizedDescription)")
            }
        }
        let response = try await SecretStatusResponse(status: statusMap).encodeResponse(for: req)
        response.headers.replaceOrAdd(name: "Cache-Control", value: "no-store, private")
        return response
    }

    secretsGroup.delete(PathComponent.parameter("key")) { req async throws -> Response in
        guard let rawKey = req.parameters.get("key") else {
            throw Abort(.badRequest, reason: "Key parameter missing.")
        }
        let key = try validateSecretKey(rawKey)
        let secrets = req.application.runeWeaver.secrets ?? SecretsManager()
        do {
            try await secrets.delete(key: key)
        } catch {
            throw Abort(.internalServerError, reason: "Failed to delete secret from Keychain: \(error.localizedDescription)")
        }
        let response = Response(status: .noContent)
        response.headers.replaceOrAdd(name: "Cache-Control", value: "no-store, private")
        return response
    }
}

/// Canonicalizes one hostname for the restart compare. Trims plus lowercases, then strips a single
/// outer bracket pair only when the inner text carries a colon so `::1` and `[::1]` (or `::` and
/// `[::]`) compare equal.
func canonicalRestartHost(_ value: String) -> String {
    var candidate = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if candidate.hasPrefix("["), candidate.hasSuffix("]"), candidate.count >= 2 {
        let inner = String(candidate.dropFirst().dropLast())
        // Only IPv6 literals use brackets; stripping unconditionally would map
        // `[example.com]` onto `example.com` and hide a spurious restart.
        if inner.contains(":") {
            candidate = inner
        }
    }
    return candidate
}

/// Whether an owner token guards the pending `[server]` bind. Any resolution failure reads as no
/// token so the caller fails closed with the Generate CTA instead of persisting an unauthenticated
/// LAN bind.
private func serverBindHasOwnerToken(config: RuneWeaverConfig) async -> Bool {
    do {
        return try await ServerAuth.resolve(authConfig: config.auth) != nil
    } catch {
        return false
    }
}

/// Prepared LLM swap held between pre-save preparation and post-save application: the selected
/// provider plus its derived server URLs. Preparation never mutates live state.
struct LiveLLMSwap: Sendable {
    /// Provider the merged config selects for serving turns.
    let provider: any LLMProvider
    /// De-duplicated provider server URLs feeding the SSRF loopback exemption.
    let serverURLs: [String]
}

/// Resolves the provider set for a merged `[llm]` section without touching live state, so a
/// rejected selection throws before the caller persists the config file.
func prepareLiveLLMSwap(config: RuneWeaverConfig, context: ServerContext) async throws -> LiveLLMSwap {
    var keysByEntry: [String: String] = [:]
    for (entryName, entry) in config.llm.providers {
        guard let envVar = entry.apiKeyEnv, !envVar.isEmpty else { continue }
        if let key = LLMProviderFactory.resolveAPIKey(explicit: nil, envVar: envVar) {
            keysByEntry[entryName] = key
        } else if let secrets = context.secrets, let stored = try? await secrets.retrieve(key: envVar) {
            keysByEntry[entryName] = stored
        }
    }
    let providers = LLMProviderFactory.makeProviders(from: config.llm, apiKeysByEntry: keysByEntry)
    guard let selected = LLMProviderFactory.selectProvider(named: nil, from: providers, config: config.llm) else {
        throw Abort(.badRequest, reason: "No enabled LLM provider is configured; enable at least one [llm.providers.*] entry matching [llm] default_provider.")
    }
    return LiveLLMSwap(provider: selected, serverURLs: LLMOrigins.serverURLs(from: config.llm))
}

/// Applies a prepared provider swap to the live orchestrator, goal engine, fan-out reviewer,
/// ideas engine, and egress supervisor without a restart.
func applyLiveLLMSwap(_ swap: LiveLLMSwap, context: ServerContext) async {
    await context.orchestrator.updateLanguageProvider(swap.provider)
    context.servingLLM = swap.provider
    await context.goalEngine.updateLLM(swap.provider)
    await context.fanOut.updateReviewer(swap.provider)
    if let ideas = context.ideasEngine {
        await ideas.updateLLM(swap.provider)
    }
    context.llmServerURLs = swap.serverURLs
    if let live = context.egressSupervisor {
        await live.updateLLMServerURLs(swap.serverURLs)
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

/// Pushes persisted recall budgets into the live orchestrator so saved values take effect without a
/// restart.
private func applyLiveRecallBudgets(body: UpdateSettingsRequest, config: RuneWeaverConfig, context: ServerContext) async {
    guard body.carriesRecallPatch else { return }
    await context.orchestrator.updateRecallBudgets(config.memory.recallBudgets)
}

/// Re-registers one tool while keeping its live enablement.
private func reregisterPreservingToggle(_ tool: any Tool, on context: ServerContext) async {
    let isEnabled = await context.toolBus.isToolEnabled(named: tool.name)
    await context.toolBus.register(tool: tool, isEnabled: isEnabled)
}

/// Reloads media tools when media settings changed so Sonarr / Radarr picks up URLs without a restart.
/// Stored transports ride along so hermetic doubles survive a settings PUT instead of resetting to live defaults.
private func reloadLiveMediaTools(body: UpdateSettingsRequest, config: RuneWeaverConfig, context: ServerContext) async {
    guard body.media != nil else { return }
    for tool in MediaTools.makeTools(
        mediaConfig: config.media, transport: context.mediaTransport, secrets: context.mediaSecrets
    ) {
        await reregisterPreservingToggle(tool, on: context)
    }
}

/// Rebuilds the Playwright bridge with fresh origins while preserving injected doubles. A managed
/// subprocess gateway keeps its executable and budgets; a test double survives as-is.
func gatewayForLiveReload(
    stored: any BrowserPlaywrightGateway?,
    busGateway: any BrowserPlaywrightGateway?,
    browserConfig: BrowserConfig,
    mediaConfig: MediaConfig? = nil,
    llmServerURLs: [String] = [],
    origins: Set<String> = [],
    egressSupervisor: OutboundEgressSupervisor
) -> any BrowserPlaywrightGateway {
    let baseGateway = stored ?? busGateway
    return SupervisedBrowserGateway.resolve(
        injected: baseGateway,
        browserConfig: browserConfig,
        mediaConfig: mediaConfig,
        llmServerURLs: llmServerURLs,
        mergedOrigins: origins,
        supervisor: egressSupervisor
    )
}

/// Reloads browser, web, and API tools when origins may have changed so homelab hosts apply
/// immediately. The stored gateway and transports ride along so a settings PUT refreshes origins
/// without dropping the bridge.
func reloadLiveNetworkTools(body: UpdateSettingsRequest, config: RuneWeaverConfig, context: ServerContext) async throws {
    guard body.media != nil || body.browserSearxngURL != nil
        || body.searchSearxngURL != nil || body.providers != nil || body.defaultProvider != nil
        || body.fallbackProvider != nil || body.browserTimeoutSeconds != nil || body.browserFetchTimeoutSeconds != nil
    else {
        return
    }
    let appLLMOrigins = LLMOrigins.serverURLs(from: config.llm)
    let browserOrigins = await mergedNetworkOrigins(
        browserConfig: config.browser,
        mediaConfig: config.media,
        llmServerURLs: appLLMOrigins,
        store: context.policyStore
    )
    if let live = context.egressSupervisor {
        await live.updateLLMServerURLs(appLLMOrigins)
        await reregisterNetworkTools(
            browserConfig: config.browser,
            mediaConfig: config.media,
            llmServerURLs: appLLMOrigins,
            origins: browserOrigins,
            supervisor: live,
            context: context
        )
        return
    }
    let supervisor = try await OutboundEgressSupervisor.make(
        policyStore: context.policyStore,
        secrets: context.secrets,
        browserConfig: config.browser,
        mediaConfig: config.media,
        llmServerURLs: appLLMOrigins
    )
    await reregisterNetworkTools(
        browserConfig: config.browser,
        mediaConfig: config.media,
        llmServerURLs: appLLMOrigins,
        origins: browserOrigins,
        supervisor: supervisor,
        context: context
    )
}

/// Rebuilds browser, web, and API tools after a committed policy write so a `local_exemptions` edit
/// applies live with no restart.
func refreshNetworkToolsAfterPolicySave(context: ServerContext) async {
    let browserConfig = context.browserConfig
    let mediaConfig = context.mediaConfig
    let llmServerURLs = context.llmServerURLs
    let mergedOrigins = await mergedNetworkOrigins(
        browserConfig: browserConfig,
        mediaConfig: mediaConfig,
        llmServerURLs: llmServerURLs,
        store: context.policyStore
    )
    let fallbackSupervisor: OutboundEgressSupervisor?
    do {
        fallbackSupervisor = try await OutboundEgressSupervisor.make(
            policyStore: context.policyStore,
            secrets: context.secrets,
            browserConfig: browserConfig,
            mediaConfig: mediaConfig,
            llmServerURLs: llmServerURLs
        )
    } catch is CancellationError {
        return
    } catch {
        RuneWeaverLog.server.error("refreshNetworkToolsAfterPolicySave: failed to make fallback OutboundEgressSupervisor: \(error.localizedDescription)")
        fallbackSupervisor = nil
    }
    guard let effectiveSupervisor = context.egressSupervisor ?? fallbackSupervisor else { return }
    await reregisterNetworkTools(
        browserConfig: browserConfig,
        mediaConfig: mediaConfig,
        llmServerURLs: llmServerURLs,
        origins: mergedOrigins,
        supervisor: effectiveSupervisor,
        context: context
    )
}

/// Reconciles live desktop tools with the persisted `[desktop]` policy so saved values take effect
/// without a restart.
private func reloadLiveDesktopTools(body: UpdateSettingsRequest, config: RuneWeaverConfig, context: ServerContext) async {
    guard body.desktop != nil else { return }
    context.desktopConfig = config.desktop
    for tool in DesktopTools.makeTools(
        desktopConfig: config.desktop,
        captureBridge: context.desktopCaptureBridge,
        controlBridge: context.desktopControlBridge,
        egressSupervisor: context.egressSupervisor
    ) {
        await reregisterPreservingToggle(tool, on: context)
    }
}

/// Reconciles the live bash and files tools with the persisted policies so saved values take effect
/// without a restart.
private func reloadLiveBashFilesTools(body: UpdateSettingsRequest, config: RuneWeaverConfig, context: ServerContext, bashChanged: Bool, containersChanged: Bool) async {
    let hasBashPatch = bashChanged
    let hasFilesPatch = body.carriesFilesPatch
    let hasWorkspacePatch = body.workspace.map { !$0.isEmpty } ?? false
    let hasContainersPatch = containersChanged
    guard hasBashPatch || hasFilesPatch || hasWorkspacePatch || hasContainersPatch else { return }
    context.setBashFiles(bash: config.bash, files: config.files)
    // Snapshot the swapped pair once so the gate update and the tool rebuilds
    // below observe the same fresh policies a concurrent turn cannot interleave.
    let live = context.bashFilesSnapshot()
    if hasContainersPatch {
        context.containersConfig = config.containers
        await StrictTurnRegistry.shared.applyContainersConfig(config.containers)
        await context.sandboxCleanup.updateConfig(config.containers)
    }
    if hasBashPatch {
        await context.permissionGate.updateBashConfig(config.bash)
    }
    if hasFilesPatch {
        // The gate reads the write posture before the tool runs, so the saved
        // `[files]` section has to reach it here or a live `write_mode` would
        // keep classifying under the policy the boot loaded.
        await context.permissionGate.updateFilesConfig(live.files)
    }
    if hasWorkspacePatch {
        await context.workspaceStore.updateConfig(config.workspace)
        await context.permissionGate.updateWorkspaceRoot(context.workspaceStore.root())
    }
    if hasFilesPatch {
        // The rebuilt write tool keeps the same supersede propagation hook so
        // a saved `write_mode` cannot silently drop the `file_superseded`
        // broadcast that settles already-mounted review cards.
        let supersededReviewNotifier = makeStagedSupersedeNotifier(hub: context.hub)
        for tool in FilesTools.makeTools(
            filesConfig: live.files,
            stagedFilesStore: context.stagedFiles,
            supersededReviewNotifier: supersededReviewNotifier
        ) {
            await reregisterPreservingToggle(tool, on: context)
        }
    }
    if hasBashPatch || hasFilesPatch || hasWorkspacePatch || hasContainersPatch {
        let overrides = await context.workspaceStore.overrides()
        let sharedLedger = await StrictTurnRegistry.shared.ephemeralLedger
        let containerSeam = ContainerSeam(
            containersConfig: config.containers,
            strictRegistry: StrictTurnRegistry.shared,
            ephemeralLedger: sharedLedger
        )
        let bashTool = BashTool(
            bashConfig: live.bash,
            filesConfig: live.files,
            egressSupervisor: context.egressSupervisor,
            workspaceConfig: config.workspace,
            workspaceStore: WorkspaceStore(
                config: config.workspace,
                homeDirectoryURL: overrides.homeDirectoryURL,
                rootURL: overrides.rootURL
            ),
            containers: containerSeam
        )
        await reregisterPreservingToggle(bashTool, on: context)
    }
    if hasFilesPatch || hasContainersPatch, !config.email.accounts.isEmpty, await context.toolBus.tool(named: "email.search") != nil {
        let sharedLedger = await StrictTurnRegistry.shared.ephemeralLedger
        for tool in EmailTools.makeTools(
            emailConfig: config.email,
            containersConfig: config.containers,
            filesConfig: live.files,
            ephemeralLedger: sharedLedger,
            securityConfig: config.security,
            booking: SchedulerStoreBookingAdapter(store: context.scheduler, hub: context.hub)
        ) {
            await reregisterPreservingToggle(tool, on: context)
        }
    }
}

/// Applies the saved `[fanout]` policy to the live engine so the next swarm uses new values without
/// a restart.
private func reloadLiveFanOut(body: UpdateSettingsRequest, config: RuneWeaverConfig, context: ServerContext) async {
    guard body.fanout != nil else { return }
    await context.fanOut.updateConfig(config.fanOut)
}

/// Pushes the saved `[notifications]` preferences into the live boxes so saved switches take effect
/// without a restart. The combined notifier, the scheduler worker, and the index reporter share
/// one box in the serving path, so updating each keeps filtering in sync even when a test wires
/// a distinct box.
private func reloadLiveNotifications(body: UpdateSettingsRequest, config: RuneWeaverConfig, context: ServerContext) async {
    guard body.carriesNotificationsPatch else { return }
    if let composite = context.notifier as? CompositeSchedulerNotifier {
        composite.updateNotifications(config.notifications)
    }
    await context.schedulerWorker.updateNotifications(config.notifications)
    if let coordinator = context.indexCoordinator {
        let reporter: ServerIndexRunReporter = if let composite = context.notifier as? CompositeSchedulerNotifier {
            ServerIndexBoot.makeReporterWithNotifier(runs: context.runs, hub: context.hub, notifier: composite)
        } else {
            ServerIndexRunReporter(
                runs: context.runs,
                hub: context.hub,
                notifier: context.notifier,
                notificationsBox: NotificationsConfigBox(config.notifications)
            )
        }
        await coordinator.setReporter(reporter)
    }
}

/// Applies the saved `[index]` policy to the live engine so the next run uses new values without a
/// restart.
private func reloadLiveIndexPolicy(body: UpdateSettingsRequest, config: RuneWeaverConfig, context: ServerContext, prebuilt: ServerIndexComponents? = nil) async throws {
    guard body.index != nil else { return }
    try await reconcileLiveIndexPolicy(savedConfig: config, context: context, prebuilt: prebuilt)
}

/// Reconciles the live document index with the persisted config. Shared by the settings route and
/// tests so enable-from-disabled, `db_path` swaps, disable-teardown, and fail-closed construction
/// follow one path.
func reconcileLiveIndexPolicy(savedConfig: RuneWeaverConfig, context: ServerContext, prebuilt: ServerIndexComponents? = nil) async throws {
    let saved = savedConfig.index
    // Disabling tears down: cancel the in-flight run and join its termination first so its terminal
    // summary is preserved and no old-generation run overlaps the teardown, then clear the pair so
    // controls fail closed.
    guard saved.enabled else {
        let live = context.liveIndexSnapshot()
        if let coordinator = live.coordinator, await coordinator.isRunning {
            try await cancelAndJoinIndexRun(coordinator)
        }
        context.setLiveIndex(store: nil, coordinator: nil)
        return
    }
    // Enabled with a wired coordinator on the same path is a policy refresh: the next run gates on
    // the new values without rebuilding stages.
    let live = context.liveIndexSnapshot()
    if let coordinator = live.coordinator, let store = live.store {
        let liveDBPath = await store.dbPath
        if liveDBPath == saved.dbPath {
            await coordinator.updateConfig(saved)
            return
        }
        // A changed `db_path` rebuilds against the new path.
        let fresh = try await reusedOrProbedIndexComponents(savedConfig: savedConfig, context: context, prebuilt: prebuilt)
        if await coordinator.isRunning {
            try await cancelAndJoinIndexRun(coordinator)
        }
        context.setLiveIndex(store: fresh.store, coordinator: fresh.coordinator)
        return
    }
    // Enabled while unwired constructs live so the next run needs no restart.
    // The probe runs before the swap so a bad `db_path` keeps the routes
    // failing closed instead of parking a broken store.
    let fresh = try await reusedOrProbedIndexComponents(savedConfig: savedConfig, context: context, prebuilt: prebuilt)
    context.setLiveIndex(store: fresh.store, coordinator: fresh.coordinator)
}

/// Pre-save fail-closed probe for a pending `[index]` patch. Runs before the config file is
/// persisted and before any live tool state mutates, so a rejected `db_path` never becomes durable
/// and file/live never diverge.
private func preflightLiveIndexPolicy(savedConfig: RuneWeaverConfig, context: ServerContext, patchPresent: Bool) async throws -> ServerIndexComponents? {
    guard patchPresent, savedConfig.index.enabled else { return nil }
    // Read the pair as one atomic snapshot so a concurrent PUT swapping
    // generations cannot interleave between the two reads and mis-classify
    // a same-path refresh as a `db_path`-change (or vice versa).
    let live = context.liveIndexSnapshot()
    if let store = live.store, live.coordinator != nil {
        let liveDBPath = await store.dbPath
        if liveDBPath == savedConfig.index.dbPath {
            return nil
        }
    }
    return try await probedIndexComponents(savedConfig: savedConfig, context: context)
}

/// Reuses preflight-probed components when they already cover this save.
private func reusedOrProbedIndexComponents(savedConfig: RuneWeaverConfig, context: ServerContext, prebuilt: ServerIndexComponents?) async throws -> ServerIndexComponents {
    if let prebuilt, prebuilt.docIndexDBPath == savedConfig.index.dbPath {
        return prebuilt
    }
    return try await probedIndexComponents(savedConfig: savedConfig, context: context)
}

/// Signals cancellation on an old-generation coordinator and joins its run task before the live
/// pair is swapped or cleared, so the previous generation cannot overlap the fresh one.
private func cancelAndJoinIndexRun(_ coordinator: IndexCoordinator) async throws {
    await coordinator.cancel()
    // Long enough for a cooperative stage to notice the flag between batches,
    // short enough that a wedged generation cannot hang `PUT /settings`.
    let graceNs: UInt64 = 5_000_000_000
    let sliceNs: UInt64 = 10_000_000
    let deadline = Date().addingTimeInterval(TimeInterval(graceNs) / 1_000_000_000)
    while await coordinator.isRunning {
        try Task.checkCancellation()
        guard Date() < deadline else { break }
        try await Task.sleep(nanoseconds: sliceNs)
    }
}

/// Builds boot-parity index components for the saved config and probes the new store so an
/// unwritable `db_path` fails before the live context is touched.
private func probedIndexComponents(savedConfig: RuneWeaverConfig, context: ServerContext) async throws -> ServerIndexComponents {
    guard let components = ServerIndexBoot.makeComponents(
        config: savedConfig,
        runs: context.runs,
        hub: context.hub,
        embedder: context.embedder,
        notifier: context.notifier
    ) else {
        throw Abort(.badRequest, reason: "Indexing is disabled in [index].")
    }
    do {
        _ = try await components.store.stats()
    } catch {
        throw Abort(.badRequest, reason: "Index database is not usable at '\(savedConfig.index.dbPath)': \(error.localizedDescription)")
    }
    return components
}

// MARK: - Network Tools Reload Helpers

/// Merges config-derived origins with stored local exemptions. The config side is the auto service
/// origins only (`searxng_url`, enabled media LAN URLs, configured LLM server URLs).
private func mergedNetworkOrigins(browserConfig: BrowserConfig, mediaConfig: MediaConfig?, llmServerURLs: [String], store: PolicyStore) async -> Set<String> {
    do {
        let exemptions = try await store.snapshot().network.localExemptions
        return SupervisedBrowserGateway.mergedOrigins(
            browserConfig: browserConfig,
            mediaConfig: mediaConfig,
            llmServerURLs: llmServerURLs,
            extraAllowlistedOrigins: exemptions
        )
    } catch {
        RuneWeaverLog.server.warning("ServerSettingsRoutes: failed to read policy store snapshot for network exemptions: \(error.localizedDescription)")
        return SupervisedBrowserGateway.mergedOrigins(
            browserConfig: browserConfig,
            mediaConfig: mediaConfig,
            llmServerURLs: llmServerURLs
        )
    }
}

/// Re-registers browser, web, and API tools over one merged origin set.
private func reregisterNetworkTools(
    browserConfig: BrowserConfig, mediaConfig: MediaConfig?,
    llmServerURLs: [String], origins: Set<String>,
    supervisor: OutboundEgressSupervisor, context: ServerContext
) async {
    let busGateway = await (context.toolBus.tool(named: "browser.navigate") as? BrowserNavigateTool)?.browserGateway
    let gateway = gatewayForLiveReload(
        stored: context.browserGateway, busGateway: busGateway, browserConfig: browserConfig,
        mediaConfig: mediaConfig, llmServerURLs: llmServerURLs, origins: origins, egressSupervisor: supervisor
    )
    for tool in BrowserTools.makeTools(
        gateway: gateway, browserConfig: browserConfig, mediaConfig: mediaConfig,
        llmServerURLs: llmServerURLs, allowlistedOrigins: origins, egressSupervisor: supervisor
    ) {
        await reregisterPreservingToggle(tool, on: context)
    }
    for tool in WebTools.makeTools(
        browserConfig: browserConfig, mediaConfig: mediaConfig, searchTransport: context.searchTransport,
        fetchTransport: context.fetchTransport, ensurer: context.searchEnsurer,
        gateway: gateway, supervisor: supervisor, extraAllowlistedOrigins: origins,
        llmServerURLs: llmServerURLs
    ) {
        await reregisterPreservingToggle(tool, on: context)
    }
    for tool in ApiRequestTools.makeTools(supervisor: supervisor, transport: context.apiTransport, browserConfig: browserConfig) {
        await reregisterPreservingToggle(tool, on: context)
    }
}

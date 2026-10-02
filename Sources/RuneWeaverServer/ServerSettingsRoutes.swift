// Rune Weaver Server — Settings read/persist routes and live-reload helpers.
//
// Owns `GET`/`PUT /settings`: load, merge, validate, and persist the engine
// config, then push the saved values into the live engine so orchestrator
// budgets, media/browser/web/API tools, desktop, bash/files policies, fan-out
// policy, and index policy take effect without a restart. `[goals]` and `[proactive]`
// persist to the file through the same partial-patch merge but take effect on
// restart: the pursuit engine and the scheduler worker hold their policy from
// boot with no live-reload path. `[server]` bind keys persist
// to the file but never live-reload the socket or the middleware set: they
// return `requiresRestart` so the dashboard shows a pending-vs-live restart
// banner instead of pretending the new bind is live. `[files]` saves apply
// live the same way and never claim a restart.
//
// The `/settings/policy` routes read and write the network-plus-credentials
// policy through the context's shared `PolicyStore`, the same instance
// backing the mandatory egress supervisor, so an HTTP policy write applies
// live in-process with no restart plus no watcher. The dashboard edits the
// structured DTO while serialization runs through the store-owned reparse
// round-trip proof, so file and supervisor cannot disagree on quoting; every
// candidate is validated against the two owned invariants — credential
// confinement plus rule-shadow prevention — with Abort 400 naming gate plus
// field, and a rejected candidate leaves file plus memory unchanged. Legacy
// filesystem and tool tables are ignored on load and never persisted, and the
// pane never shows a restart banner for policy.

import Foundation
import RuneWeaverCore
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
    // Snapshot the stored bind before the merge so the response advertises
    // a restart only when the file values actually move. A save that
    // resends unchanged bind keys (for example a full-form PUT) leaves the
    // flag false instead of crying restart on every edit.
    let oldServerHostname = config.server.hostname
    let oldServerPort = config.server.port
    let oldServerAllowedHosts = config.server.allowedHosts
    let oldLLMConfig = config.llm
    do {
        try body.apply(to: &config)
        // Validate the merged config before persisting so a single bad
        // field cannot corrupt the stored file or live engine state.
        try config.validate()
        // The bind and the Host gate stay on the boot values, so only a
        // real hostname/port/allowed_hosts change needs a restart. The
        // `carriesServerPatch` gate short-circuits saves without bind keys
        // so unrelated edits skip the compare entirely. Hostname
        // compares trimmed plus lowercased plus bracket-canonicalized and
        // allowed hosts compare as sets of their bracket-canonicalized
        // normalized Host forms so casing, `:port` spellings, bracketed
        // versus bare IPv6 spellings, or reorderings that the gate treats
        // identically do not trip a spurious restart, matching the
        // dashboard normalized dirty-check.
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
        // Providers build the live LLM at boot with no live-reload path,
        // so any provider delta (including supportsVision) leaves the live
        // model stale until restart.
        let providersChanged = config.llm.providers != oldLLMConfig.providers
        // `[goals]`, `[proactive]`, and `[ideas]` persist to the file through
        // the same partial-patch merge but take effect on restart: the pursuit
        // engine, the scheduler worker, and the ideas engine hold their policy
        // from boot with no live-reload path. Any patch carrying those keys must
        // advertise a restart instead of silently claiming live.
        let goalsProactiveOrIdeasChanged = body.goals != nil || body.proactive != nil || body.ideas != nil
        let needsRestart = serverChanged || llmChanged || providersChanged || goalsProactiveOrIdeasChanged
        let liveContext = req.application.runeWeaver
        // Fail-closed bind guard: a changed non-loopback hostname persists
        // only when an owner token resolves. Without one the save is
        // refused with a Generate CTA instead of silently downgrading to an
        // unauthenticated LAN bind or pretending loopback still applies.
        // Unchanged binds (including an already-stored LAN value resent by
        // a full-form save) skip the gate so unrelated edits stay saveable.
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
        // Fail-closed pre-save probe: a rejected `db_path` throws before
        // the file is persisted and before any live tool state mutates,
        // so the durable file and live desktop/index state never diverge.
        // The probed components ride along into the reconcile below so an
        // enable or `db_path` change builds and probes the new store once.
        let prebuiltIndexComponents = try await preflightLiveIndexPolicy(savedConfig: config, context: liveContext, patchPresent: body.index != nil)
        try config.save(to: url)
        await applyLiveOrchestratorTuning(body: body, context: liveContext)
        await applyLiveRecallBudgets(body: body, config: config, context: liveContext)
        await reloadLiveMediaTools(body: body, config: config, context: liveContext)
        try await reloadLiveNetworkTools(body: body, config: config, context: liveContext)
        await reloadLiveDesktopTools(body: body, config: config, context: liveContext)
        await reloadLiveBashFilesTools(body: body, config: config, context: liveContext)
        await reloadLiveFanOut(body: body, config: config, context: liveContext)
        try await reloadLiveIndexPolicy(body: body, config: config, context: liveContext, prebuilt: prebuiltIndexComponents)
        // Configured services seed the allowlist through the shared derivation
        // the boot supervisor uses, so both paths pre-authorize exactly the
        // same hosts and a service source added there is never skipped here.
        await ensureConfiguredServiceEgressCandidates(config: config, store: liveContext.policyStore)
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
///
/// The settings save path consumes the shared
/// `RuneWeaverConfig.serviceEgressCandidates` derivation, so boot and saves
/// pre-authorize the same hosts. The store's `ensureServiceDomainsAllowed`
/// keeps the write fail-closed, so a present-but-rejected `policy.toml` is
/// never overwritten to manufacture a verified posture.
/// Exposed internally so the live-reload regression can drive the same
/// application path the save uses.
/// - Parameters:
///   - config: Merged config carrying the configured services.
///   - store: The one policy store this process's supervisor reads.
func ensureConfiguredServiceEgressCandidates(config: RuneWeaverConfig, store: PolicyStore) async {
    await store.ensureServiceDomainsAllowed(urlsOrHosts: config.serviceEgressCandidates)
}

/// Maximum secret value bytes accepted by the store route.
///
/// Bounds the Keychain write so an unbounded body cannot pressure the
/// Keychain or memory. Measured in UTF-8 bytes, matching the transport size.
private let maxSecretStoreBytes = 16 * 1024

/// Maximum keys accepted per status lookup.
///
/// Single contract owner for the secret-status bound: the dashboard mirror
/// `SECRET_STATUS_CHUNK_SIZE` in `Web/src/components/SettingsManager.tsx` must
/// stay equal so badge-probe chunks never trip this gate. Both sides pin 500
/// (see `SettingsRouteTests` plus the dashboard contract test); update both
/// together.
///
/// Bounds the retrieve loop so one request cannot fan out unbounded Keychain
/// reads. Sized at 500 distinct keys to cover the dashboard badge probe,
/// which unions email password envs, provider `api_key_env` names, and the
/// Sonarr/Radarr names, without turning the probe into a 400.
let maxSecretStatusKeys = 500

/// Validates a raw secret key for the secrets routes.
///
/// Delegates the shape rule to the core single owner so store, status, and
/// delete agree without duplicating the alphabet or the length bound. Key
/// names never carry secret bytes, so the failure reason names only the
/// shape rule.
/// - Parameter rawKey: Untrimmed key from the request body or path.
/// - Returns: Trimmed key safe for the Keychain lookup.
/// - Throws: `Abort(.badRequest)` when the key is empty, holds non-name
///   characters, or exceeds the length bound.
private func validateSecretKey(_ rawKey: String) throws -> String {
    let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard SecretsManager.isValidSurrogateKey(rawKey) else {
        if key.count > SecretsManager.maxSurrogateKeyLength {
            throw Abort(.badRequest, reason: "Key must not exceed \(SecretsManager.maxSurrogateKeyLength) characters.")
        }
        throw Abort(.badRequest, reason: "Key must not be empty and must contain only alphanumeric characters, underscores, hyphens, and periods.")
    }
    return key
}

private func registerSettingsSecretsRoutes(_ settings: RoutesBuilder) {
    // Keychain secret management routes.
    // Responses never cache and never carry secret bytes: store and delete
    // answer `204 No Content` with no body — the same bodyless-success shape
    // every other side-effect route uses — while status returns only an
    // existence map.
    let secretsGroup = settings.grouped(PathComponent.constant(ServerPaths.secrets))

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

/// Canonicalizes one hostname for the restart compare.
///
/// Trims plus lowercases, then strips a single outer bracket pair only when the
/// inner text carries a colon so `::1` and `[::1]` (or `::` and `[::]`) compare
/// equal. A non-colon bracketed value (for example `[example.com]`) keeps its
/// brackets so it never collides with the bare form. The Host gate stores both
/// spellings for IPv6 literals, so without this the compare would report a
/// spurious restart when only the bracket spelling moves.
///
/// Exposed internally so the host-parity contract can pin it against the
/// dashboard mirror instead of drifting on bracket or case spellings.
/// - Parameter value: Raw or normalized hostname.
/// - Returns: Bracket-canonicalized hostname.
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

/// Whether an owner token guards the pending `[server]` bind.
///
/// Always resolves the merged `[auth]` section fresh so a token removed after
/// boot cannot strand the file behind a stale live verifier, while a token
/// provisioned after boot still authorizes the save. Any resolution failure
/// reads as no token so the caller fails closed with the Generate CTA instead
/// of persisting an unauthenticated LAN bind.
/// - Parameter config: Merged config about to be persisted.
/// - Returns: True when a token resolves from any configured source.
private func serverBindHasOwnerToken(config: RuneWeaverConfig) async -> Bool {
    do {
        return try await ServerAuth.resolve(authConfig: config.auth) != nil
    } catch {
        return false
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

/// Pushes persisted recall budgets into the live orchestrator so saved values take effect without a restart.
/// A save without recall keys is a no-op, so unrelated edits never touch the
/// live budgets; the merged config carries the clamped values so the live
/// engine and the persisted file agree even on edge inputs.
private func applyLiveRecallBudgets(body: UpdateSettingsRequest, config: RuneWeaverConfig, context: ServerContext) async {
    guard body.carriesRecallPatch else { return }
    await context.orchestrator.updateRecallBudgets(config.memory.recallBudgets)
}

/// Re-registers one tool while keeping its live enablement.
///
/// Live reload swaps the tool implementation for fresh config without
/// disturbing operator intent: the persisted tool-state toggle stays the sole
/// authority for enablement, so the fresh definition inherits the current
/// bus state instead of resetting to enabled.
/// - Parameters:
///   - tool: Freshly built tool replacing the live registration.
///   - context: Live server context owning the tool bus.
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

/// Rebuilds the Playwright bridge with fresh origins while preserving injected doubles.
/// A managed subprocess gateway keeps its executable and budgets; a test double survives as-is.
/// The live egress supervisor rides into the rebuilt gateway, so a settings
/// save never degrades browser entry or redirect-hop validation to SSRF-only.
/// Exposed internally so the live-reload regression can pin the rebuilt
/// gateway through the same builder the save path uses.
func gatewayForLiveReload(
    stored: (any BrowserPlaywrightGateway)?,
    busGateway: (any BrowserPlaywrightGateway)?,
    browserConfig: BrowserConfig,
    mediaConfig: MediaConfig? = nil,
    llmServerURLs: [String] = [],
    origins: Set<String> = [],
    egressSupervisor: OutboundEgressSupervisor?
) -> (any BrowserPlaywrightGateway)? {
    let baseGateway = stored ?? busGateway
    if let baseGateway, let managed = baseGateway as? SubprocessPlaywrightGateway {
        return SubprocessPlaywrightGateway(
            pythonExecutable: managed.pythonExecutable,
            timeoutSeconds: TimeInterval(browserConfig.timeoutSeconds),
            maxOutputBytes: managed.maxOutputBytes,
            browserConfig: browserConfig,
            mediaConfig: mediaConfig,
            llmServerURLs: llmServerURLs,
            allowlistedOrigins: origins,
            egressSupervisor: egressSupervisor
        )
    }
    return baseGateway
}

/// Reloads browser, web, and API tools when origins may have changed so homelab hosts apply immediately.
/// The stored gateway and transports ride along so a settings PUT refreshes origins without dropping the bridge.
/// The rebuilt gateway keeps the live egress supervisor and the API
/// supervisor reads the shared policy store, so an origin refresh keeps the
/// same declarative policy as the boot-time choke-point.
/// Exposed internally so the live-reload regression can drive the same
/// rebuild path the settings save uses and pin the `api.request` supervisor
/// identity against the triage/gate/browser instance.
func reloadLiveNetworkTools(body: UpdateSettingsRequest, config: RuneWeaverConfig, context: ServerContext) async throws {
    // Provider endpoints feed the SSRF exemption set, so an LLM-endpoint change
    // must refresh live tools immediately rather than waiting for a restart.
    guard body.media != nil || body.browserAllowedOrigins != nil || body.browserSearxngURL != nil
        || body.searchSearxngURL != nil || body.providers != nil || body.defaultProvider != nil
        || body.fallbackProvider != nil || body.browserTimeoutSeconds != nil || body.browserFetchTimeoutSeconds != nil
    else {
        return
    }
    let appLLMOrigins = LLMOrigins.serverURLs(from: config.llm)
    let browserOrigins = ApiSSRFGuard.allowlistedOrigins(
        browserConfig: config.browser,
        mediaConfig: config.media,
        llmServerURLs: appLLMOrigins
    )
    // The rebuild goes through the same supervisor factory as boot, reading
    // the shared policy store so an origin refresh never swaps in an
    // unsupervised api.request; a store that lost its verified policy fails
    // the PUT instead of degrading the live tool.
    let supervisor = try await OutboundEgressSupervisor.make(
        policyStore: context.policyStore,
        secrets: context.secrets,
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
    let effectiveSupervisor = context.egressSupervisor ?? supervisor
    if let gatewayForReload = gatewayForLiveReload(
        stored: context.browserGateway,
        busGateway: busGateway,
        browserConfig: config.browser,
        mediaConfig: config.media,
        llmServerURLs: appLLMOrigins,
        origins: browserOrigins,
        egressSupervisor: effectiveSupervisor
    ) {
        for tool in BrowserTools.makeTools(
            gateway: gatewayForReload,
            browserConfig: config.browser,
            mediaConfig: config.media,
            llmServerURLs: appLLMOrigins,
            allowlistedOrigins: browserOrigins,
            egressSupervisor: effectiveSupervisor
        ) {
            await reregisterPreservingToggle(tool, on: context)
        }
    } else {
        for tool in BrowserTools.makeTools(
            browserConfig: config.browser,
            mediaConfig: config.media,
            llmServerURLs: appLLMOrigins,
            allowlistedOrigins: browserOrigins,
            egressSupervisor: effectiveSupervisor
        ) {
            await reregisterPreservingToggle(tool, on: context)
        }
    }
    for tool in WebTools.makeTools(
        browserConfig: config.browser,
        mediaConfig: config.media,
        searchTransport: context.searchTransport,
        fetchTransport: context.fetchTransport,
        ensurer: context.searchEnsurer,
        supervisor: effectiveSupervisor
    ) {
        await reregisterPreservingToggle(tool, on: context)
    }
    // The rebuilt api.request must hold the same supervisor instance triage,
    // the permission gate, and the browser tools use (`effectiveSupervisor`):
    // ephemeral allowOnce/allowSession grants land on the context instance, so
    // binding the fresh factory result would make an approved retry check a
    // different actor and fail as unlisted after any settings save.
    for tool in ApiRequestTools.makeTools(
        supervisor: effectiveSupervisor,
        transport: context.apiTransport,
        browserConfig: config.browser
    ) {
        await reregisterPreservingToggle(tool, on: context)
    }
}

/// Reconciles live desktop tools with the persisted `[desktop]` policy so saved values take effect without a restart.
/// Follows the media reload pattern: a nil desktop patch is a no-op, stored
/// bridges ride along so hermetic doubles survive a settings PUT, and each
/// re-registered tool keeps its live enabled state. Both tools stay
/// registered (never absent from `GET /tools`); the fresh capture policy is
/// pushed into the context, and the tool-state toggle remains the sole
/// authority for enablement.
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

/// Reconciles the live bash and files tools with the persisted policies so saved values take effect without a restart.
/// Follows the desktop reload pattern: a save without any bash or files key
/// is a no-op, and each re-registered tool keeps its live enabled state. Both
/// policies swap into the context atomically so concurrent turns never see a
/// fresh shell beside a stale workspace guard, then the file tools refresh
/// first and the bash tool registers exactly once against the fresh pair for
/// its working-directory guard. Email tools follow only on a files patch when
/// mail accounts are configured and already on the bus.
/// - Parameters:
///   - body: Decoded settings patch selecting which policies move.
///   - config: Persisted config carrying the fresh policies.
///   - context: Live server context receiving the swap.
private func reloadLiveBashFilesTools(body: UpdateSettingsRequest, config: RuneWeaverConfig, context: ServerContext) async {
    let hasBashPatch = body.bash != nil
    let hasFilesPatch = body.filesDenyPatterns != nil || body.filesAllowRoots != nil || body.filesRequireApprovalOnDeny != nil || body.filesWriteMode != nil
    guard hasBashPatch || hasFilesPatch else { return }
    context.setBashFiles(bash: config.bash, files: config.files)
    if hasBashPatch {
        await context.permissionGate.updateBashConfig(config.bash)
    }
    let live = context.bashFilesSnapshot()
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
    let bashTool = BashTool(
        bashConfig: live.bash,
        filesConfig: live.files,
        egressSupervisor: context.egressSupervisor
    )
    await reregisterPreservingToggle(bashTool, on: context)
    if hasFilesPatch, !config.email.accounts.isEmpty {
        if await context.toolBus.tool(named: "email.search") != nil {
            for tool in EmailTools.makeTools(
                emailConfig: config.email,
                sandboxConfig: config.sandbox,
                filesConfig: live.files,
                securityConfig: config.security
            ) {
                await reregisterPreservingToggle(tool, on: context)
            }
        }
    }
}

/// Applies the saved `[fanout]` policy to the live engine so the next swarm uses new values without a restart.
/// Follows the recall-budget pattern: a nil fanout patch is a no-op so
/// unrelated edits never touch the live swarm, while a present patch pushes
/// the validated persisted snapshot. The engine clamps defensively on write,
/// so the live value and the durable file agree even on edge inputs.
private func reloadLiveFanOut(body: UpdateSettingsRequest, config: RuneWeaverConfig, context: ServerContext) async {
    guard body.fanout != nil else { return }
    await context.fanOut.updateConfig(config.fanOut)
}

/// Applies the saved `[index]` policy to the live engine so the next run uses new values without a restart.
/// When no coordinator is wired and the saved policy enables the index, the
/// store and coordinator are constructed live through the shared boot path and
/// swapped into the context; a changed `db_path` rebuilds against the new path
/// the same way. Disabling cancels any in-flight run and joins its
/// termination first, then tears down.
/// Construction is fail-closed: a bad `db_path` throws before the live context
/// is touched so the previous index keeps serving.
/// Status already reads the file live; run/cancel/prune/reset keep failing
/// closed only when genuinely unwired.
private func reloadLiveIndexPolicy(body: UpdateSettingsRequest, config: RuneWeaverConfig, context: ServerContext, prebuilt: ServerIndexComponents? = nil) async throws {
    guard body.index != nil else { return }
    try await reconcileLiveIndexPolicy(savedConfig: config, context: context, prebuilt: prebuilt)
}

/// Reconciles the live document index with the persisted config.
///
/// Shared by the settings route and tests so enable-from-disabled, `db_path`
/// swaps, disable-teardown, and fail-closed construction follow one path.
/// - Parameters:
///   - savedConfig: Persisted config carrying the `[index]` policy plus the
///     source policies the boot path binds into its stages.
///   - context: Live server context receiving the swap.
///   - prebuilt: Store plus coordinator probed by the pre-save preflight for
///     this same `savedConfig`. Reused when its `db_path` still matches so one
///     PUT probes a new path once instead of probing in preflight and again
///     here. Direct callers pass nil and probe inline.
/// - Throws: `Abort(.badRequest)` when a newly enabled `db_path` cannot back
///   a store, before the live context is mutated.
func reconcileLiveIndexPolicy(savedConfig: RuneWeaverConfig, context: ServerContext, prebuilt: ServerIndexComponents? = nil) async throws {
    let saved = savedConfig.index
    // Disabling tears down: cancel the in-flight run and join its termination
    // first so its terminal summary is preserved and no old-generation run
    // overlaps the teardown, then clear the pair so controls fail closed.
    // The pair is read as one atomic snapshot so concurrent PUTs never mix
    // generations.
    guard saved.enabled else {
        let live = context.liveIndexSnapshot()
        if let coordinator = live.coordinator, await coordinator.isRunning {
            try await cancelAndJoinIndexRun(coordinator)
        }
        context.setLiveIndex(store: nil, coordinator: nil)
        return
    }
    // Enabled with a wired coordinator on the same path is a policy refresh:
    // the next run gates on the new values without rebuilding stages.
    // The pair is read as one atomic snapshot so concurrent PUTs never mix
    // generations when classifying same-path vs `db_path`-change.
    let live = context.liveIndexSnapshot()
    if let coordinator = live.coordinator, let store = live.store {
        let liveDBPath = await store.dbPath
        if liveDBPath == saved.dbPath {
            await coordinator.updateConfig(saved)
            return
        }
        // A changed `db_path` rebuilds against the new path. Construct and
        // probe before touching the live pair so a bad path leaves the old
        // index serving; then cancel the old generation's run and join its
        // termination before swapping so only one generation runs at a time.
        // The pre-save preflight already probed this path for the same save,
        // so reuse its components instead of building a second time.
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

/// Pre-save fail-closed probe for a pending `[index]` patch.
///
/// Runs before the config file is persisted and before any live tool state
/// mutates, so a rejected `db_path` never becomes durable and file/live
/// never diverge. Mirrors `reconcileLiveIndexPolicy` without mutating: a
/// disabled policy or a same-path policy refresh needs no probe (nil), while
/// an enable-from-unwired or a changed `db_path` builds boot-parity
/// components and probes the new store first. The returned components ride
/// along into the reconcile so the PUT probes a new path once.
/// - Parameters:
///   - savedConfig: Merged config about to be persisted.
///   - context: Live server context supplying the embedder and vision provider.
///   - patchPresent: Whether the request carries an `index` patch.
/// - Returns: Probed components for a new path, or nil when no probe ran.
/// - Throws: `Abort(.badRequest)` when the new `db_path` cannot back a store.
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
///
/// The pre-save preflight probes the same `savedConfig` the reconcile then
/// swaps in, so rebuilding here would construct the store and run the stats
/// probe a second time per PUT. A stale or mismatched carryover (different
/// `db_path`, e.g. a direct test call passing an unrelated value) falls back
/// to a fresh inline probe.
/// - Parameters:
///   - savedConfig: Persisted config to build from.
///   - context: Live context supplying the shared embedder and vision provider.
///   - prebuilt: Components probed by the pre-save preflight, if any.
/// - Returns: The prebuilt components when their path matches, else freshly probed ones.
private func reusedOrProbedIndexComponents(savedConfig: RuneWeaverConfig, context: ServerContext, prebuilt: ServerIndexComponents?) async throws -> ServerIndexComponents {
    if let prebuilt, prebuilt.docIndexDBPath == savedConfig.index.dbPath {
        return prebuilt
    }
    return try await probedIndexComponents(savedConfig: savedConfig, context: context)
}

/// Signals cancellation on an old-generation coordinator and joins its run
/// task before the live pair is swapped or cleared, so the previous
/// generation cannot overlap the fresh one. `IndexCoordinator.cancel()` only
/// signals cooperative cancellation; without the join the old run would keep
/// executing between batches after `setLiveIndex` moved on.
/// The join is bounded: a stalled old generation stops blocking the PUT after
/// the grace window and the swap proceeds, while caller cancellation aborts
/// the wait instead of hanging the settings save.
/// - Parameter coordinator: Old-generation coordinator to stop and join.
/// - Throws: `CancellationError` when the awaiting PUT is cancelled.
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

/// Builds boot-parity index components for the saved config and probes the new
/// store so an unwritable `db_path` fails before the live context is touched.
/// The rebuilt coordinator reports through the live run store plus hub so a
/// settings-enabled run lands where the status probe reads it.
/// - Parameters:
///   - savedConfig: Persisted config to build from.
///   - context: Live context supplying the shared embedder and vision provider.
/// - Returns: Probed store plus coordinator.
/// - Throws: `Abort(.badRequest)` when the new store cannot serve stats.
private func probedIndexComponents(savedConfig: RuneWeaverConfig, context: ServerContext) async throws -> ServerIndexComponents {
    guard let components = ServerIndexBoot.makeComponents(
        config: savedConfig,
        runs: context.runs,
        hub: context.hub,
        embedder: context.embedder,
        visionLLM: context.servingLLM
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

// MARK: - Security Policy Routes

private func registerSettingsPolicyRoutes(_ settings: RoutesBuilder) {
    let policyGroup = settings.grouped(PathComponent.constant(ServerPaths.policy))

    // GET /settings/policy
    policyGroup.get { req async throws -> PolicyResponse in
        // The context's shared store is the in-process authority: it accepted
        // a policy at boot and every HTTP write updates the same actor state
        // the egress supervisor reads, so no filesystem watcher is needed.
        // One isolation reads policy, path, load flag, and violations
        // together, so a concurrent PUT cannot interleave and mix a pre-write
        // policy with post-write violations in one response.
        let store = req.application.runeWeaver.policyStore
        let snapshot = await store.readSnapshot()

        let dto = makePolicyDTO(from: snapshot.policy)
        return PolicyResponse(
            policy: dto,
            path: snapshot.fileURL.path,
            loadedFromDisk: snapshot.loadedFromDisk,
            violations: snapshot.violations
        )
    }

    // PUT /settings/policy
    policyGroup.put { req async throws -> PolicyResponse in
        let body: UpdatePolicyRequest
        do {
            body = try req.content.decode(UpdatePolicyRequest.self)
        } catch let abort as Abort {
            throw abort
        } catch {
            throw Abort(.badRequest, reason: "Invalid policy request: \(error). Gate: request, field: policy.")
        }
        let store = req.application.runeWeaver.policyStore

        // Validate before touching disk or memory so a rejected candidate
        // leaves the file and the live snapshot agreeing instead of diverging.
        let candidate = try validateStructuredPolicyInput(body.policy)

        // Persist through the actor so verification, serialization, the file
        // write, and the memory commit share one isolation: a throwing write
        // never leaves memory ahead of the file, and concurrent readers see
        // either the pre- or post-write snapshot.
        do {
            try await store.replace(candidate)
        } catch let invariant as PolicyInvariantError {
            switch invariant {
            case let .serializationFailed(reason):
                throw Abort(
                    .badRequest,
                    reason: "\(reason) Gate: serialization, field: policy."
                )
            case let .invariantViolations(violations):
                throw Abort(
                    .badRequest,
                    reason: "Security policy violates formal invariants: " + violations.joined(separator: "; ") + ". Gate: invariants, field: policy."
                )
            case let .notVerified(reason):
                throw Abort(.badRequest, reason: "\(reason). Gate: invariants, field: policy.")
            }
        }

        // Read the authoritative flags in one isolation so the dashboard never
        // diverges from the supervisor's view.
        let snapshot = await store.readSnapshot()
        let dto = makePolicyDTO(from: snapshot.policy)
        return PolicyResponse(
            policy: dto,
            path: snapshot.fileURL.path,
            loadedFromDisk: snapshot.loadedFromDisk,
            violations: snapshot.violations
        )
    }

    // POST /settings/policy/verify
    policyGroup.post(PathComponent.constant(ServerPaths.verify)) { req async throws -> VerifyPolicyResponse in
        let body: VerifyPolicyRequest
        do {
            body = try req.content.decode(VerifyPolicyRequest.self)
        } catch let abort as Abort {
            throw abort
        } catch {
            throw Abort(.badRequest, reason: "Invalid verify request: \(error). Gate: request, field: policy.")
        }
        // A candidate check never persists: structural problems and invariant
        // failures both report as an invalid verdict so editors can preview
        // without moving the file or the live snapshot.
        do {
            _ = try validateStructuredPolicyInput(body.policy)
            return VerifyPolicyResponse(valid: true, violations: [])
        } catch let abort as Abort {
            return VerifyPolicyResponse(valid: false, violations: [abort.reason])
        } catch {
            return VerifyPolicyResponse(valid: false, violations: [error.localizedDescription])
        }
    }
}

/// HTTP methods a credential binding may name.
///
/// Empty stays Any, so the list only narrows when present. Uppercased before
/// comparison so a lowercase editor spelling still authorizes the same verb
/// instead of failing closed on casing alone.
private let allowedPolicyMethods: Set<String> = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]

/// Validates a structured policy candidate from the REST contract.
///
/// Trims surrounding whitespace, drops blank method and prefix entries that
/// can only mean Any, rejects blank domain entries and empty host lists that
/// could only match nothing, enforces the schema version floor, the two-mode
/// allowlist, the surrogate key alphabet, the method allowlist, and the
/// leading-slash prefix shape, refuses TOML-breaking scalars that would not
/// survive a save/load cycle, then runs the two formal invariants. Any
/// failure throws a 400 naming the gate and field so the editor can repair
/// the exact entry.
/// - Parameter dto: Structured candidate from PUT or verify.
/// - Returns: Normalized core policy ready to serialize and persist.
/// - Throws: `Abort(.badRequest)` naming the gate and field.
func validateStructuredPolicyInput(_ dto: SecurityPolicyDTO) throws -> SecurityPolicy {
    guard dto.version >= 1 else {
        throw Abort(
            .badRequest,
            reason: "Invalid policy version '\(dto.version)': must be >= 1. Gate: version, field: version."
        )
    }
    let mode = try validatedPolicyMode(dto.network.mode)
    let allowed = try normalizedPolicyDomains(dto.network.allowedDomains, field: "allowed_domains")
    let blocked = try normalizedPolicyDomains(dto.network.blockedDomains, field: "blocked_domains")
    var normalizedCredentials: [String: CredentialBinding] = [:]
    normalizedCredentials.reserveCapacity(dto.credentials.count)
    for (rawKey, bindingDTO) in dto.credentials {
        let key = try validatedCredentialKey(rawKey)
        normalizedCredentials[key] = try normalizedCredentialBinding(key: key, dto: bindingDTO)
    }
    let candidate = makeSecurityPolicy(
        version: dto.version,
        mode: mode,
        allowedDomains: Set(allowed),
        blockedDomains: Set(blocked),
        credentials: normalizedCredentials
    )
    let violations = PolicyInvariantVerifier.verify(candidate)
    guard violations.isEmpty else {
        throw Abort(
            .badRequest,
            reason: "Security policy violates formal invariants: " + violations.joined(separator: "; ") + ". Gate: invariants, field: policy."
        )
    }
    return candidate
}

/// Resolves the validated egress posture.
///
/// Only the two surviving spellings persist. The retired `deny_by_default`
/// name maps to the fail-closed posture so older editors keep their intent
/// without persisting ambiguity.
private func validatedPolicyMode(_ rawValue: String) throws -> EgressMode {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed == "deny_by_default" {
        return .allowlistOnly
    }
    guard trimmed == EgressMode.allowlistOnly.rawValue || trimmed == EgressMode.unrestricted.rawValue else {
        throw Abort(
            .badRequest,
            reason: "Invalid network.mode '\(rawValue)': must be 'allowlist_only' "
                + "or 'unrestricted'. Gate: mode, field: network.mode."
        )
    }
    return EgressMode(rawValue: trimmed) ?? .allowlistOnly
}

/// Validates one host entry shared by network domains and credential bindings.
///
/// Trims, rejects blanks and TOML-breaking scalars, enforces the exact-or-
/// single-leading-`*.` shape with whitespace, comma, glob, path, userinfo,
/// fragment, and port gates, and classifies wildcards through the shared
/// helper. A lone colon is a port because a valid IPv6 literal always carries
/// at least two colons, so colon-bearing literals stay storable. Bracketed
/// IPv6 literals validate only on the binding gate; the network gate rejects
/// brackets like any other shape the matcher could never equal.
/// - Parameters:
///   - raw: Raw entry text.
///   - field: Full dotted field (for example `network.allowed_domains` or
///     `credentials.KEY.allowed_hosts`) naming the 400 field.
///   - gate: Failing gate (`network` or `binding`; TOML failures always use
///     `serialization`).
/// - Returns: Trimmed entry ready to store.
/// - Throws: `Abort(.badRequest)` naming the gate and field.
/// Context and error-formatting helper for host entry validation.
private struct HostValidationContext {
    let gate: String
    let field: String
    let isBinding: Bool
    let bindingKey: String
    let shortField: String

    init(field: String, gate: String) {
        self.gate = gate
        self.field = field
        self.isBinding = gate == "binding"
        if isBinding {
            if field.hasPrefix("credentials."), field.hasSuffix(".allowed_hosts") {
                let start = field.index(field.startIndex, offsetBy: "credentials.".count)
                let end = field.index(field.endIndex, offsetBy: -".allowed_hosts".count)
                self.bindingKey = String(field[start ..< end])
            } else {
                self.bindingKey = field
            }
            self.shortField = "allowed_hosts"
        } else {
            self.bindingKey = ""
            if field.hasPrefix("network.") {
                self.shortField = String(field.dropFirst("network.".count))
            } else {
                self.shortField = field
            }
        }
    }

    func shapeReason(trimmed: String, detail: String) -> String {
        if isBinding {
            return "Invalid credentials '\(bindingKey)' field 'allowed_hosts' value '\(trimmed)': "
                + detail + "Gate: \(gate), field: \(field)."
        }
        return "Invalid network field '\(shortField)' value '\(trimmed)': "
            + detail + "Gate: \(gate), field: \(field)."
    }

    func blankAbort() -> Abort {
        if isBinding {
            return Abort(
                .badRequest,
                reason: "Invalid credentials '\(bindingKey)' field 'allowed_hosts': "
                    + "must not contain blank entries. "
                    + "Gate: \(gate), field: \(field)."
            )
        }
        return Abort(
            .badRequest,
            reason: "Invalid network field '\(shortField)': must not contain blank entries. "
                + "Gate: \(gate), field: \(field)."
        )
    }

    func tomlBreakingAbort(trimmed: String) -> Abort {
        if isBinding {
            return Abort(
                .badRequest,
                reason: "Invalid credentials '\(bindingKey)' field 'allowed_hosts' value '\(trimmed)': "
                    + "carries TOML-breaking characters. "
                    + "Gate: serialization, field: \(field)."
            )
        }
        return Abort(
            .badRequest,
            reason: "Invalid network field '\(shortField)' value '\(trimmed)': "
                + "carries TOML-breaking characters. "
                + "Gate: serialization, field: \(field)."
        )
    }
}

/// Validates bracketed IPv6 literals for credential bindings.
private func validateBracketedIPv6Host(_ trimmed: String, context: HostValidationContext) throws {
    guard trimmed.hasPrefix("["),
          trimmed.hasSuffix("]"),
          trimmed.filter({ $0 == "[" }).count == 1,
          trimmed.filter({ $0 == "]" }).count == 1
    else {
        throw Abort(.badRequest, reason: context.shapeReason(trimmed: trimmed, detail: "must be an exact host or a single leading '*.example.com' edge. "))
    }
    let inner = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !inner.isEmpty,
          inner.contains(":"),
          !inner.contains("["),
          !inner.contains("]"),
          !inner.contains("*"),
          !inner.contains(" ")
    else {
        throw Abort(.badRequest, reason: context.shapeReason(trimmed: trimmed, detail: "must be an exact host or a single leading '*.example.com' edge. "))
    }
}

/// Enforces the wildcard domain constraint (single leading `*.example.com`).
private func validateWildcardHost(_ lowered: String, trimmed: String, context: HostValidationContext) throws {
    switch AllowedOriginPattern.classifyWildcard(lowered) {
    case .leading:
        break
    case .none, .trailing, .invalidShape, .invalidSuffix, .invalidStem:
        throw Abort(.badRequest, reason: context.shapeReason(trimmed: trimmed, detail: "only a single leading '*.example.com' edge authorizes. "))
    }
    let bare = String(lowered.dropFirst(2))
    guard lowered.hasPrefix("*."), !bare.isEmpty,
          !bare.hasPrefix("."), !bare.hasSuffix(".")
    else {
        throw Abort(.badRequest, reason: context.shapeReason(trimmed: trimmed, detail: "only a single leading '*.example.com' edge authorizes. "))
    }
    if lowered.contains(":") {
        throw Abort(.badRequest, reason: context.shapeReason(trimmed: trimmed, detail: "only a single leading '*.example.com' edge authorizes. "))
    }
}

/// Validates unbracketed host strings against forbidden characters, port colons, and wildcard shapes.
private func validateUnbracketedHostShape(_ lowered: String, trimmed: String, context: HostValidationContext) throws {
    if lowered.contains(" ") || lowered.contains("\t")
        || lowered.contains(",") || lowered.contains("?")
        || lowered.contains("[") || lowered.contains("]")
        || lowered.contains("/") || lowered.contains("\\")
        || lowered.contains("@") || lowered.contains("#")
    {
        throw Abort(.badRequest, reason: context.shapeReason(trimmed: trimmed, detail: "must be an exact host or a single leading '*.example.com' edge. "))
    }
    // A canonical URL host never carries a port, and every valid IPv6
    // literal has at least two colons, so exactly one colon can only be a
    // port suffix that the matcher could never equal.
    if lowered.filter({ $0 == ":" }).count == 1 {
        throw Abort(.badRequest, reason: context.shapeReason(trimmed: trimmed, detail: "must be a host without a port. "))
    }
    if lowered.contains("*") {
        try validateWildcardHost(lowered, trimmed: trimmed, context: context)
    }
}

private func validateHostEntry(_ raw: String, field: String, gate: String) throws -> String {
    let context = HostValidationContext(field: field, gate: gate)
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        throw context.blankAbort()
    }
    guard !PolicyStore.containsTOMLBreakingScalar(trimmed) else {
        throw context.tomlBreakingAbort(trimmed: trimmed)
    }
    // Bracketed literals wrap an IPv6 address only: one outer pair with a
    // colon-bearing inner and no port suffix. The inner strips for the
    // confinement check downstream, so sensitive bracketed targets still
    // refuse through the shared verifier rather than this shape gate.
    if context.isBinding, trimmed.contains("[") || trimmed.contains("]") {
        try validateBracketedIPv6Host(trimmed, context: context)
        return trimmed
    }
    try validateUnbracketedHostShape(trimmed.lowercased(), trimmed: trimmed, context: context)
    return trimmed
}

/// Trims one domain list and rejects blanks, unwritable scalars, and shapes
/// the matcher could never authorize.
///
/// Blank entries could only match an empty host, so they fail closed rather
/// than dropping silently; only an exact host or a single leading `*.` edge
/// authorizes at runtime, so every other star shape plus whitespace, comma,
/// glob syntax, path or userinfo separators, fragments, and port suffixes
/// refuses here to match the dashboard editor. A lone colon is a port because
/// a valid IPv6 literal always carries at least two colons, so colon-bearing
/// address literals stay storable. The two callers pass their field name so
/// the 400 names the exact list under repair.
private func normalizedPolicyDomains(_ values: [String], field: String) throws -> [String] {
    var normalized: [String] = []
    normalized.reserveCapacity(values.count)
    for raw in values {
        try normalized.append(validateHostEntry(raw, field: "network.\(field)", gate: "network"))
    }
    return normalized
}

/// Trims a credential key and enforces the surrogate alphabet.
///
/// Keys name Keychain slots, so the REST boundary shares the single core
/// alphabet instead of keeping a second copy that could drift wider.
private func validatedCredentialKey(_ rawKey: String) throws -> String {
    let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard SecretsManager.isValidSurrogateKey(rawKey), !key.isEmpty else {
        throw Abort(
            .badRequest,
            reason: "Invalid credentials key '\(rawKey)': "
                + "must satisfy SecretsManager.isValidSurrogateKey. "
                + "Gate: credentials, field: credentials.\(rawKey)."
        )
    }
    guard !PolicyStore.containsTOMLBreakingScalar(key) else {
        throw Abort(
            .badRequest,
            reason: "Invalid credentials key '\(rawKey)': carries TOML-breaking characters. "
                + "Gate: serialization, field: credentials.\(rawKey)."
        )
    }
    return key
}

/// Normalizes one per-key binding into its host, method, and prefix scopes.
private func normalizedCredentialBinding(key: String, dto: CredentialBindingDTO) throws -> CredentialBinding {
    try CredentialBinding(
        allowedHosts: Set(normalizedBindingHosts(key: key, values: dto.allowedHosts)),
        allowedMethods: Set(normalizedBindingMethods(key: key, values: dto.allowedMethods)),
        allowedPathPrefixes: normalizedBindingPrefixes(key: key, values: dto.allowedPathPrefixes)
    )
}

/// Trims binding hosts and rejects blanks, unwritable scalars, and shapes
/// the matcher could never authorize.
///
/// An empty host list authorizes nothing, so it fails closed as unusable
/// rather than persisting a credential that can never be sent. Only an exact
/// host, a bracketed IPv6 literal, or a single leading `*.` edge authorizes
/// at runtime, so every other star shape plus whitespace, comma, glob
/// syntax, path or userinfo separators, fragments, and port suffixes refuses
/// here with the binding gate instead of deferring to the generic verifier.
/// Bracketed literals strip to their inner address for the confinement check
/// downstream, and a lone colon is a port because a valid IPv6 literal always
/// carries at least two colons, so colon-bearing address literals stay
/// storable.
private func normalizedBindingHosts(key: String, values: [String]) throws -> [String] {
    var normalized: [String] = []
    normalized.reserveCapacity(values.count)
    for rawHost in values {
        try normalized.append(validateHostEntry(rawHost, field: "credentials.\(key).allowed_hosts", gate: "binding"))
    }
    guard !normalized.isEmpty else {
        throw Abort(
            .badRequest,
            reason: "Invalid credentials '\(key)' field 'allowed_hosts': must not be empty. "
                + "An empty host list authorizes nothing. "
                + "Gate: binding, field: credentials.\(key).allowed_hosts."
        )
    }
    return normalized
}

/// Trims and uppercases binding methods against the verb allowlist.
///
/// Blank entries drop because empty already means Any; anything remaining
/// must name a real verb so a typo fails closed instead of widening scope.
private func normalizedBindingMethods(key: String, values: [String]) throws -> [String] {
    let droppedBlanks = values.map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }.filter { !$0.isEmpty }
    var normalized: [String] = []
    normalized.reserveCapacity(droppedBlanks.count)
    for rawMethod in droppedBlanks {
        let uppered = rawMethod.uppercased()
        guard allowedPolicyMethods.contains(uppered) else {
            throw Abort(
                .badRequest,
                reason: "Invalid credentials '\(key)' field 'allowed_methods' value '\(rawMethod)': "
                    + "must be one of GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS. "
                    + "Gate: binding, field: credentials.\(key).allowed_methods."
            )
        }
        normalized.append(uppered)
    }
    return normalized
}

/// Trims binding prefixes and enforces the rooted-path shape.
///
/// Blank entries drop because empty already means Any; a surviving prefix
/// must start with a slash so it compares against the effective route path
/// the origin server actually handles.
private func normalizedBindingPrefixes(key: String, values: [String]) throws -> [String] {
    let droppedBlanks = values.map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }.filter { !$0.isEmpty }
    var normalized: [String] = []
    normalized.reserveCapacity(droppedBlanks.count)
    for prefix in droppedBlanks {
        guard prefix.hasPrefix("/") else {
            throw Abort(
                .badRequest,
                reason: "Invalid credentials '\(key)' field 'allowed_path_prefixes' value '\(prefix)': "
                    + "must start with '/'. "
                    + "Gate: binding, field: credentials.\(key).allowed_path_prefixes."
            )
        }
        guard !PolicyStore.containsTOMLBreakingScalar(prefix) else {
            throw Abort(
                .badRequest,
                reason: "Invalid credentials '\(key)' field 'allowed_path_prefixes' value '\(prefix)': "
                    + "carries TOML-breaking characters. "
                    + "Gate: serialization, field: credentials.\(key).allowed_path_prefixes."
            )
        }
        normalized.append(prefix)
    }
    return normalized
}

/// Builds a core policy from normalized REST fields.
///
/// The inverse of `makePolicyDTO`: the DTO shape maps one-to-one onto the
/// network-plus-credentials core, so a validated request and the stored
/// snapshot convert without loss in either direction.
/// - Parameters:
///   - version: Validated schema version, floored at 1 so older or
///     nonsensical values never persist.
///   - mode: Validated egress posture.
///   - allowedDomains: Trimmed allowlist entries.
///   - blockedDomains: Trimmed blocklist entries.
///   - credentials: Normalized per-key bindings.
/// - Returns: Core policy ready to verify and serialize.
private func makeSecurityPolicy(
    version: Int,
    mode: EgressMode,
    allowedDomains: Set<String>,
    blockedDomains: Set<String>,
    credentials: [String: CredentialBinding]
) -> SecurityPolicy {
    SecurityPolicy(
        version: version,
        network: NetworkEgressPolicy(
            mode: mode,
            allowedDomains: allowedDomains,
            blockedDomains: blockedDomains
        ),
        credentials: credentials
    )
}

private func makePolicyDTO(from policy: SecurityPolicy) -> SecurityPolicyDTO {
    let networkDTO = NetworkEgressPolicyDTO(
        mode: policy.network.mode.rawValue,
        allowedDomains: policy.network.allowedDomains.sorted(),
        blockedDomains: policy.network.blockedDomains.sorted()
    )

    var credsDTO: [String: CredentialBindingDTO] = [:]
    for (credentialKey, binding) in policy.credentials {
        credsDTO[credentialKey] = CredentialBindingDTO(
            allowedHosts: binding.allowedHosts.sorted(),
            allowedMethods: binding.allowedMethods.sorted(),
            allowedPathPrefixes: binding.allowedPathPrefixes
        )
    }

    return SecurityPolicyDTO(
        version: policy.version,
        network: networkDTO,
        credentials: credsDTO
    )
}

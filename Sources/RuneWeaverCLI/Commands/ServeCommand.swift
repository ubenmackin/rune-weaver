// Rune Weaver CLI — Engine API service command.

import ArgumentParser
import Foundation
import Logging
import RuneWeaverCore
import RuneWeaverLLM
import RuneWeaverServer
import RuneWeaverTools
import Vapor

/// Starts the local engine API service.
///
/// Binding is fail-closed: loopback always serves, while a non-loopback
/// `--hostname` or `[server] hostname` is allowed only when an owner bearer
/// token resolves from the configured sources. The resolved verifier is
/// threaded into the context and config so the bind policy and the request gate
/// can never disagree.
struct ServeCommand: AsyncParsableCommand {
    /// Top-level command configuration.
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Start the engine API service (REST, WebSocket, dashboard). Loopback by default; LAN binds require owner auth."
    )

    /// Config file path override.
    @ArgumentParser.Option(name: .long, help: "Path to config.toml (defaults to ~/.runeweaver/config.toml).")
    var config: String?

    /// Provider name overriding `llm.default_provider`.
    @ArgumentParser.Option(name: .long, help: "Override the configured LLM provider (e.g. mlx, openrouter, local).")
    var provider: String?

    /// Developer instructions prepended to served turns.
    @ArgumentParser.Option(name: .long, help: "System prompt prepended to served conversations.")
    var systemPrompt: String?

    /// Interface to bind, overriding `[server] hostname`. Loopback always
    /// serves; a non-loopback address requires a configured owner token.
    @ArgumentParser.Option(name: .long, help: "Interface to bind, overriding [server] hostname (a non-loopback address requires a configured owner token).")
    var hostname: String?

    /// TCP port to bind, overriding `[server] port`.
    @ArgumentParser.Option(name: .long, help: "TCP port to bind, overriding [server] port.")
    var port: Int?

    /// Loads config, wires the engine context, and serves until stopped.
    mutating func run() async throws {
        let resolved = try await validateAndLoadConfig()
        let loaded = resolved.loaded
        let auth = resolved.auth
        let serverConfig = resolved.serverConfig
        let (selected, allProviders) = try await resolveProvider(loaded: loaded)
        let contextBundle: (context: ServerContext, permissionGate: PermissionGate)
        do {
            contextBundle = try await buildContext(
                loaded: loaded,
                selected: selected,
                allProviders: allProviders,
                serverConfig: serverConfig,
                auth: auth,
                mediaConfig: loaded.config.media
            )
        } catch let error as PolicyInvariantError {
            // Fail-closed boot: the declarative policy could not be verified,
            // so the service never starts with an unsupervised api.request.
            print(TerminalStyle.error("Security policy rejected at boot: \(error.localizedDescription)"))
            throw ExitCode(1)
        }
        let (context, permissionGate) = contextBundle
        var env = try Environment.detect()
        try LoggingSystem.bootstrap(from: &env)
        let app = try await Application.make(env)
        await permissionGate.startPeriodicCleanup()
        // Tier-3 crash-orphan prune only; there is no host staging to sweep and no staging audit
        // tied to an old path. Document writes stage in Seatbelt-confined temp with an atomic move
        // on approval, so boot reclamation covers only orphaned detonation machines.
        let serveCleanup = SandboxCleaner.cleanup(config: loaded.config.sandbox)
        if serveCleanup.containersDestroyed > 0 || serveCleanup.staleMachinesStopped > 0 || !serveCleanup.errors.isEmpty {
            let reclaimed = serveCleanup.containersDestroyed
            let stopped = serveCleanup.staleMachinesStopped
            let errorCount = serveCleanup.errors.count
            print(TerminalStyle.dim(
                "Sandbox cleanup: reclaimed \(reclaimed) machines (\(stopped) stopped), \(errorCount) errors."
            ))
        }
        await context.sandboxCleanup.start(config: loaded.config.sandbox)
        // Ensure the local search engine before accepting turns so first searches stay warm; a down
        // engine never blocks boot — the failure surfaces as closed guidance on the next search
        // instead. The container is left running after quit by design.
        // Stream the owner flight's live stage plus elapsed time so a minutes-long pull stays
        // visible instead of hanging silently on one line; the snapshot's Start time is pinned
        // at flight creation, so elapsed counts the whole Start across stage moves.
        // The watcher only reads actor snapshots and never drives the flight.
        let searxngURL = loaded.config.browser.searxngURL
        let searxngStageWatcher = Task {
            var lastStage: SearXNGEnsurer.StartStage?
            var lastElapsed: Int?
            while !Task.isCancelled {
                let progress = await SearXNGEnsurer.shared.currentStartProgress(for: searxngURL)
                if let progress {
                    // Clamp clock skew so a future-dated Start never renders negative; ticking on
                    // elapsed change keeps a long pull visibly advancing while the stage is stuck.
                    let elapsed = max(0, Int(Date().timeIntervalSince(progress.startedAt)))
                    if progress.stage != lastStage || elapsed != lastElapsed {
                        lastStage = progress.stage
                        lastElapsed = elapsed
                        print(TerminalStyle.dim("SearXNG \(progress.stage.userCopy)… (\(elapsed)s)"))
                    }
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        do {
            try await SearXNGEnsurer.shared.ensure(browser: loaded.config.browser)
            searxngStageWatcher.cancel()
            print(TerminalStyle.dim("SearXNG ready at \(loaded.config.browser.searxngURL)."))
        } catch {
            searxngStageWatcher.cancel()
            print(TerminalStyle.dim("Search engine unavailable: \(error.localizedDescription)"))
        }
        try await runServerLoop(
            app: app,
            context: context,
            permissionGate: permissionGate,
            serverConfig: serverConfig,
            selectedName: selected.name
        )
    }

    /// Loads config, resolves owner auth, and validates the requested bind.
    ///
    /// An explicit flag wins; otherwise `[server] hostname`/`port` supply the
    /// bind defaults so the documented endpoint actually takes effect, and a
    /// config with no `[server]` block keeps the built-in loopback address.
    /// Resolution runs before serving so a token that is declared but unreadable
    /// (for example a loose-permissioned file) fails here instead of surfacing at
    /// the request gate. A non-loopback hostname is accepted only once a token
    /// resolves; otherwise the same loopback-only `ValidationError` is thrown,
    /// never a silent downgrade to an unauthenticated LAN bind.
    private func validateAndLoadConfig() async throws -> ResolvedServeConfiguration {
        // Check an explicit flag before the config can supply a fallback; a
        // configured port was already range-checked by `validate()` at load.
        if let flagPort = port, !ServerConfig.validPortRange.contains(flagPort) {
            throw ValidationError("--port must be \(ServerConfig.validPortRange) (got \(flagPort)).")
        }
        let loaded = try CLIConfigLoader.loadConfig(path: config)
        if loaded.isFallback {
            print(TerminalStyle.dim("No config found at \(loaded.url.path); using built-in defaults."))
        }
        let bindHostname = hostname ?? loaded.config.server.hostname
        let bindPort = port ?? loaded.config.server.port
        // Validate the effective bind hostname shape before the bind policy so a
        // `--hostname` carrying a widening shape fails with a clear message
        // rather than a bind-time or gate-time surprise. File values were
        // already checked by `validate()` at load; the flag bypasses that path.
        do {
            try RuneWeaverConfig.validateServerHostname(bindHostname)
        } catch {
            throw ValidationError("Invalid hostname '\(bindHostname)': \(String(describing: error))")
        }
        let auth: ServerAuth?
        do {
            auth = try await ServerAuth.resolve(authConfig: loaded.config.auth)
        } catch {
            throw ValidationError("Owner auth could not be resolved: \(error.localizedDescription)")
        }
        // The bind policy lives in `ServerConfig`; this only translates a refusal
        // into the CLI's loopback-only `ValidationError` so the operator gets an
        // actionable message instead of a bare transport error.
        let serverConfig = ServerConfig(
            hostname: bindHostname,
            port: bindPort,
            authConfigured: auth != nil,
            allowedHosts: loaded.config.server.allowedHosts
        )
        do {
            try serverConfig.requireBindable(authConfigured: auth != nil)
        } catch {
            throw ValidationError(
                "Hostname must be loopback (127.0.0.1, localhost, ::1, or [::1]) unless an owner token is configured "
                    + "(got '\(bindHostname)'). Set [server] hostname or pass --hostname to a loopback address, "
                    + "or run 'rune-weaver auth token generate' to enable LAN binds."
            )
        }
        return ResolvedServeConfiguration(loaded: loaded, auth: auth, serverConfig: serverConfig)
    }

    private func resolveProvider(loaded: CLIConfigLoader.LoadedConfig) async throws -> (selected: any LLMProvider, all: [any LLMProvider]) {
        let providers = await CLIProviderBuilder.buildProviders(from: loaded.config.llm)
        guard !providers.isEmpty else {
            print(TerminalStyle.error("No LLM providers are enabled. Check [llm.providers.*] in \(loaded.url.path)."))
            throw ExitCode(1)
        }
        guard let selected = CLIProviderBuilder.selectProvider(
            named: provider,
            from: providers,
            config: loaded.config.llm
        ) else {
            let names = providers.map(\.name).sorted().joined(separator: ", ")
            print(TerminalStyle.error("Unknown provider '\(provider ?? "")'. Available: \(names)."))
            throw ExitCode(1)
        }
        return (selected, providers)
    }
}

// MARK: - Context & Lifecycle

extension ServeCommand {
    private struct ToolBootstrapDependencies {
        let memoryEngine: MemoryEngine
        let embedder: (any EmbeddingsBackend)?
        let goalStore: GoalStore
        let goalEngine: GoalEngine
        let recipientAliasStore: RecipientAliasStore
        let conversations: ConversationManager
    }

    /// Shared seed for the preview and served tool registries.
    ///
    /// Bundles the resolved media policy, the one secrets instance, and the one
    /// security policy store per serve invocation so the preview bus, the
    /// served registry, and the settings policy routes observe the same
    /// instances instead of diverging on per-path defaults.
    private struct ToolBuildSeed {
        /// Resolved `[media]` policy feeding Sonarr/Radarr tool registration.
        let mediaConfig: MediaConfig
        /// Shared secrets backing surrogate resolution for every built tool.
        let secrets: SecretsManager
        /// The one security policy store for this process.
        let policyStore: PolicyStore
    }

    private func loadConversations(episodesDBPath: String) async -> ConversationManager {
        let conversations = ConversationManager(episodesDBPath: episodesDBPath)
        do {
            try await conversations.loadAll()
        } catch {
            cliPrintError(TerminalStyle.dim("Could not load conversation history; starting fresh."))
        }
        return conversations
    }

    private func loadPermissionGate(episodesDBPath: String, pluginsDir: String, bashConfig: BashConfig) async -> PermissionGate {
        let episodesDB = (episodesDBPath as NSString).expandingTildeInPath
        let trustStore = SQLiteTrustStore(dbPath: episodesDB)
        let gate = await PermissionGate.load(
            store: trustStore,
            pluginsDir: URL(fileURLWithPath: (pluginsDir as NSString).expandingTildeInPath)
        )
        await gate.updateBashConfig(bashConfig)
        return gate
    }

    private struct GoalStack {
        let store: GoalStore
        let engine: GoalEngine
        let recipientAliasStore: RecipientAliasStore
    }

    private func makeGoalStack(
        memoryConfig: MemoryConfig,
        goalsConfig: GoalsConfig,
        selected: any LLMProvider
    ) -> GoalStack {
        let goalStore = GoalStore(dbPath: memoryConfig.episodesDBPath)
        let goalEngine = GoalEngine(store: goalStore, llm: selected, config: goalsConfig)
        // The learned-alias store shares the same episodes file so a served
        // resolved-name send teaches later resolutions without another datastore.
        let recipientAliasStore = RecipientAliasStore(dbPath: memoryConfig.episodesDBPath)
        return GoalStack(store: goalStore, engine: goalEngine, recipientAliasStore: recipientAliasStore)
    }

    private func makePreviewBus(
        loaded: CLIConfigLoader.LoadedConfig,
        selected: any LLMProvider,
        permissionGate: PermissionGate,
        deps: ToolBootstrapDependencies,
        seed: ToolBuildSeed
    ) async throws -> ToolBus {
        try await CLIShared.makeToolBus(
            emailConfig: loaded.config.email,
            filesConfig: loaded.config.files,
            bashConfig: loaded.config.bash,
            memoryEngine: deps.memoryEngine,
            permissionGate: permissionGate,
            sandboxConfig: loaded.config.sandbox,
            embedder: deps.embedder,
            pluginConfig: loaded.config.plugins,
            episodesDBPath: loaded.config.memory.episodesDBPath,
            browserConfig: loaded.config.browser,
            llmConfig: loaded.config.llm,
            mediaConfig: seed.mediaConfig,
            desktopConfig: loaded.config.desktop,
            securityConfig: loaded.config.security,
            secrets: seed.secrets,
            goalsConfig: loaded.config.goals,
            goalEngine: deps.goalEngine,
            goalStore: deps.goalStore,
            goalConversations: deps.conversations,
            goalLLM: selected,
            policyStore: seed.policyStore,
            recipientAliasStore: deps.recipientAliasStore
        )
    }

    private func registerAndVerifyTools(
        context: ServerContext,
        plugins: [any Tool],
        selected: any LLMProvider,
        effectiveSystemPrompt: String
    ) async {
        for tool in plugins {
            // Preserve live enabled state across re-registration: a bare
            // register would reset every tool to enabled, and desktop tools
            // ship disabled — without this, a fresh install would flip them
            // live between registration and the restore below.
            let isEnabled = await context.toolBus.isToolEnabled(named: tool.name)
            await context.toolBus.register(tool: tool, isEnabled: isEnabled)
        }
        // Registration preserves live state now, but re-apply persisted
        // toggles anyway; the cached load makes this a memory-only pass after
        // the boot hydration in `make`.
        await context.restoreToolStates(forceReload: false)
        // Re-snapshot the live service registry so drift between the startup
        // preview and the serving bus surfaces instead of silently omitting
        // a rune from the prompt.
        let livePrompt = await SystemPromptComposer.resolve(
            flag: systemPrompt,
            toolBus: context.toolBus,
            supportsVision: selected.modelInfo.supportsVision
        )
        if livePrompt != effectiveSystemPrompt {
            print(TerminalStyle.dim("Served prompt differs from live registry; continuing with startup snapshot."))
        }
    }

    private func buildContext(
        loaded: CLIConfigLoader.LoadedConfig,
        selected: any LLMProvider,
        allProviders: [any LLMProvider],
        serverConfig: ServerConfig,
        auth: ServerAuth?,
        mediaConfig: MediaConfig? = nil
    ) async throws -> (context: ServerContext, permissionGate: PermissionGate) {
        // Point recall at the configured document index when `[index]` is
        // enabled; a disabled section keeps the keyword-and-vector engine.
        let docIndexDBPath: String? = loaded.config.index.enabled ? loaded.config.index.dbPath : nil
        let memoryEngine = CLIShared.memoryEngine(for: loaded.config.memory, docIndexDBPath: docIndexDBPath)
        let conversations = await loadConversations(episodesDBPath: loaded.config.memory.episodesDBPath)
        let permissionGate = await loadPermissionGate(
            episodesDBPath: loaded.config.memory.episodesDBPath,
            pluginsDir: loaded.config.plugins.pluginsDir,
            bashConfig: loaded.config.bash
        )
        // Resolve the embeddings producer once from config so served memory
        // routes and the orchestrator share one backend; nil keeps the
        // keyword-only path when vectors are disabled or unknown.
        let embedder = EmbeddingsBackendFactory.makeBackend(
            memoryEmbeddingBackend: loaded.config.memory.embeddingBackend,
            router: LLMRouter(providers: allProviders)
        )
        // Build the document index pipeline once so served recall, the nightly
        // trigger, and the `/index` routes share one store and coordinator; nil
        // when disabled keeps routes failing closed and recall unchanged. The
        // run reporter writes into the same run store the status probe reads
        // plus the same hub the sockets fan out from, so a manual run leaves
        // one start row updated in place by its completion.
        let runs = await RunLogStore.load(dbPath: loaded.config.memory.episodesDBPath)
        let hub = WSHub()
        let indexComponents = makeIndexComponents(
            loaded: loaded,
            allProviders: allProviders,
            selected: selected,
            runs: runs,
            hub: hub,
            embedder: embedder
        )
        // Resolve the media section once so the preview registry, the prompt
        // snapshot, and the served context register the same media tools.
        let resolvedMediaConfig = mediaConfig ?? loaded.config.media
        // One shared secrets instance per serve invocation so the preview bus,
        // the plugin snapshot, and the served context observe one fallback
        // store instead of minting per-tool instances that diverge.
        let sharedSecrets = SecretsManager()
        // One security policy store per serve process: the preview bus, the
        // served registry, and the settings policy routes read this same
        // instance, so an HTTP policy write is visible to the egress
        // supervisor without a restart. Loading here seeds the factory-safe
        // posture on a missing file and leaves corruption to fail the first
        // tool build closed below.
        let policyStore = await PolicyStore.makeLoaded(injected: nil)
        let goalStack = makeGoalStack(
            memoryConfig: loaded.config.memory,
            goalsConfig: loaded.config.goals,
            selected: selected
        )
        let deps = ToolBootstrapDependencies(
            memoryEngine: memoryEngine,
            embedder: embedder,
            goalStore: goalStack.store,
            goalEngine: goalStack.engine,
            recipientAliasStore: goalStack.recipientAliasStore,
            conversations: conversations
        )
        // One seed shared by the prompt preview and the served registry so both
        // builds observe the same media policy, secrets, and policy store.
        let seed = ToolBuildSeed(
            mediaConfig: resolvedMediaConfig,
            secrets: sharedSecrets,
            policyStore: policyStore
        )
        // Compose the default system prompt from the live registry so the
        // served model sees every registered tool; an explicit
        // --system-prompt still overrides it verbatim.
        let plugins = try await makePlugins(loaded: loaded, deps: deps, seed: seed)
        // Snapshot discovered runes before the service owns the registry so
        // external tools reach the served prompt; the service syncs the same
        // directory again on boot, keeping both views consistent.
        let effectiveSystemPrompt = try await resolveEffectiveSystemPrompt(
            loaded: loaded,
            selected: selected,
            permissionGate: permissionGate,
            deps: deps,
            seed: seed
        )
        let context = try await ServerContext.make(
            config: serverConfig,
            conversations: conversations,
            memoryEngine: memoryEngine,
            embedder: embedder,
            permissionGate: permissionGate,
            llm: selected,
            systemPrompt: effectiveSystemPrompt,
            schedulerConfig: loaded.config.scheduler,
            episodesDBPath: loaded.config.memory.episodesDBPath,
            pluginConfig: loaded.config.plugins,
            sandboxConfig: loaded.config.sandbox,
            browserConfig: loaded.config.browser,
            indexCoordinator: indexComponents?.coordinator,
            indexStore: indexComponents?.store,
            llmServerURLs: CLIShared.llmServerURLs(from: loaded.config.llm),
            engineConfig: loaded.config.engine,
            emailConfig: loaded.config.email,
            filesConfig: loaded.config.files,
            bashConfig: loaded.config.bash,
            mediaConfig: resolvedMediaConfig,
            desktopConfig: loaded.config.desktop,
            securityConfig: loaded.config.security,
            recallBudgets: loaded.config.memory.recallBudgets,
            goalsConfig: loaded.config.goals,
            ideasConfig: loaded.config.ideas,
            proactiveConfig: loaded.config.proactive,
            auth: auth,
            mediaSecrets: sharedSecrets,
            secrets: sharedSecrets,
            runs: runs,
            hub: hub,
            policyStore: policyStore
        )
        await registerAndVerifyTools(
            context: context,
            plugins: plugins,
            selected: selected,
            effectiveSystemPrompt: effectiveSystemPrompt
        )
        return (context, permissionGate)
    }

    private func makeIndexComponents(
        loaded: CLIConfigLoader.LoadedConfig,
        allProviders: [any LLMProvider],
        selected: any LLMProvider,
        runs: RunLogStore,
        hub: WSHub,
        embedder: (any EmbeddingsBackend)?
    ) -> ServerIndexComponents? {
        let makeEmbeddingsBackend: @Sendable () -> (any EmbeddingsBackend)? =
            EmbeddingsBackendFactory.makePoolFactory(
                memoryEmbeddingBackend: loaded.config.memory.embeddingBackend,
                providers: allProviders
            )
        return ServerIndexBoot.makeComponents(
            config: loaded.config,
            runs: runs,
            hub: hub,
            embedder: embedder,
            visionLLM: selected,
            makeEmbeddingsBackend: makeEmbeddingsBackend
        )
    }

    private func makePlugins(
        loaded: CLIConfigLoader.LoadedConfig,
        deps: ToolBootstrapDependencies,
        seed: ToolBuildSeed
    ) async throws -> [any Tool] {
        try await CLIShared.pluginTools(
            emailConfig: loaded.config.email,
            filesConfig: loaded.config.files,
            bashConfig: loaded.config.bash,
            memoryEngine: deps.memoryEngine,
            sandboxConfig: loaded.config.sandbox,
            embedder: deps.embedder,
            browserConfig: loaded.config.browser,
            llmConfig: loaded.config.llm,
            mediaConfig: seed.mediaConfig,
            securityConfig: loaded.config.security,
            secrets: seed.secrets,
            goalEngine: deps.goalEngine,
            goalStore: deps.goalStore,
            goalConversations: deps.conversations,
            goalsConfig: loaded.config.goals,
            policyStore: seed.policyStore,
            recipientAliasStore: deps.recipientAliasStore
        )
    }

    private func resolveEffectiveSystemPrompt(
        loaded: CLIConfigLoader.LoadedConfig,
        selected: any LLMProvider,
        permissionGate: PermissionGate,
        deps: ToolBootstrapDependencies,
        seed: ToolBuildSeed
    ) async throws -> String {
        let previewBus = try await makePreviewBus(
            loaded: loaded,
            selected: selected,
            permissionGate: permissionGate,
            deps: deps,
            seed: seed
        )
        return await SystemPromptComposer.resolve(
            flag: systemPrompt,
            toolBus: previewBus,
            supportsVision: selected.modelInfo.supportsVision
        )
    }

    private func runServerLoop(
        app: Application,
        context: ServerContext,
        permissionGate: PermissionGate,
        serverConfig: ServerConfig,
        selectedName: String
    ) async throws {
        do {
            try configureRuneWeaver(app, context: context)
            // State the trust posture before the bind: a non-loopback address is
            // only reachable because a token resolved, and the no-auth loopback
            // default gets a loud note so unauthenticated serving is never silent.
            if serverConfig.authConfigured {
                if serverConfig.isLoopbackOnly {
                    print(
                        TerminalStyle.success(
                            "Serving engine API on \(serverConfig.hostname):\(serverConfig.port) with owner auth "
                                + "(\(selectedName)). Ctrl+C to stop."
                        )
                    )
                } else {
                    print(
                        TerminalStyle.success(
                            "Serving engine API on \(serverConfig.hostname):\(serverConfig.port) with owner auth — "
                                + "reachable on your local network (\(selectedName)). Ctrl+C to stop."
                        )
                    )
                }
            } else {
                print(
                    TerminalStyle.dim(
                        "Serving engine API on \(serverConfig.hostname):\(serverConfig.port) without auth "
                            + "(\(selectedName)). Ctrl+C to stop."
                    )
                )
                print(
                    TerminalStyle.error(
                        "WARNING: no owner token is configured — serving UNAUTHENTICATED on loopback only. "
                            + "Run 'rune-weaver auth token generate' before binding to a LAN address."
                    )
                )
            }
            try await app.execute()
            await permissionGate.stopPeriodicCleanup()
            await context.sandboxCleanup.stop()
            await context.hub.closeAll()
            try await app.asyncShutdown()
        } catch {
            await permissionGate.stopPeriodicCleanup()
            await context.sandboxCleanup.stop()
            await context.hub.closeAll()
            try? await app.asyncShutdown()
            throw error
        }
    }
}

/// Resolved inputs for a single `serve` invocation.
///
/// Grouping the loaded config, the optional owner verifier, and the validated
/// bind policy keeps the auth-to-bind handoff legible at the call site; named
/// members also make it unambiguous which value is the credential verifier
/// rather than yet another config field.
private struct ResolvedServeConfiguration {
    /// Loaded config plus its source URL for operator messaging.
    let loaded: CLIConfigLoader.LoadedConfig
    /// Owner bearer verifier, or nil for the no-auth loopback posture.
    let auth: ServerAuth?
    /// Bind policy validated against the resolved auth posture.
    let serverConfig: ServerConfig
}

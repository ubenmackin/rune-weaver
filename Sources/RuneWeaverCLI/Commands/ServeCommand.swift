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
        // Crash-orphan prune only; there is no host staging to sweep and no staging audit
        // tied to an old path. Document writes stage in Seatbelt-confined temp with an atomic
        // move on approval, so boot reclamation covers only orphaned strict plus detonation containers.
        let serveCleanup = await SandboxCleaner.cleanup(config: loaded.config.containers, approvals: context.approvals)
        if serveCleanup.containersDestroyed > 0 || serveCleanup.scratchRemoved > 0 || !serveCleanup.errors.isEmpty {
            let reclaimed = serveCleanup.containersDestroyed
            let scratch = serveCleanup.scratchRemoved
            let errorCount = serveCleanup.errors.count
            print(TerminalStyle.dim(
                "Sandbox cleanup: reclaimed \(reclaimed) containers (\(scratch) scratch), \(errorCount) errors."
            ))
        }
        await context.sandboxCleanup.start(config: loaded.config.containers, approvals: context.approvals)
        // Ensure the local search engine before accepting turns so first searches stay warm; a down
        // engine never blocks boot — the failure surfaces as closed guidance on the next search
        // instead.
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
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    break
                }
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
        var embeddingWarmupTask: Task<Void, Never>?
        if loaded.config.memory.embeddingBackend == MemoryConfig.embeddingBackendLocal {
            embeddingWarmupTask = Task(priority: .utility) {
                do {
                    try await LlamaEmbeddingSupervisor.shared.ensureRunning()
                } catch is CancellationError {
                    // Ignored on cancel
                } catch {
                    RuneWeaverLog.server.warning("Local embedding warmup failed: \(error.localizedDescription)")
                }
            }
        }
        defer {
            embeddingWarmupTask?.cancel()
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
        // Validate the effective bind hostname shape before the bind policy so a `--hostname`
        // carrying a widening shape fails with a clear message rather than a bind-time or gate-time
        // surprise.
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
        let embedder: any EmbeddingsBackend?
        let goalStore: GoalStore
        let goalEngine: GoalEngine
        let recipientAliasStore: RecipientAliasStore
        let conversations: ConversationManager
    }

    /// Shared seed for the preview and served tool registries.
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

    private func loadPermissionGate(
        episodesDBPath: String,
        pluginsDir: String,
        bashConfig: BashConfig,
        filesConfig: FilesConfig,
        workspaceConfig: WorkspaceConfig
    ) async -> PermissionGate {
        let episodesDB = (episodesDBPath as NSString).expandingTildeInPath
        let ruleStore = SQLiteAccessRuleStore(dbPath: episodesDB)
        let gate = await PermissionGate.load(
            ruleStore: ruleStore,
            pluginsDir: URL(fileURLWithPath: (pluginsDir as NSString).expandingTildeInPath)
        )
        await gate.updateBashConfig(bashConfig)
        // The write posture is decided ahead of the tool, so the served `[files]` policy reaches
        // the gate: a staged or live write runs without a second approval request while an
        // ask-postured write parks exactly as before.
        await gate.updateFilesConfig(filesConfig)
        await gate.updateWorkspaceRoot(WorkspaceStore(config: workspaceConfig).root())
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
            containersConfig: loaded.config.containers,
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
            recipientAliasStore: deps.recipientAliasStore,
            workspaceConfig: loaded.config.workspace
        )
    }

    private func registerAndVerifyTools(
        context: ServerContext,
        plugins: [any Tool],
        selected: any LLMProvider,
        effectiveSystemPrompt: String
    ) async {
        for tool in plugins {
            // Preserve live enabled state across re-registration: a bare register would reset every
            // tool to enabled, and desktop tools ship disabled — without this, a fresh install would
            // flip them live between registration and the restore below.
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
            supportsVision: selected.modelInfo.supportsVision,
            persona: context.persona
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
            bashConfig: loaded.config.bash,
            filesConfig: loaded.config.files,
            workspaceConfig: loaded.config.workspace
        )
        // Resolve the embeddings producer once from config so served memory
        // routes and the orchestrator share one backend; nil keeps the
        // keyword-only path when vectors are disabled or unknown.
        let embedder = EmbeddingsBackendFactory.makeBackend(
            memoryEmbeddingBackend: loaded.config.memory.embeddingBackend,
            router: LLMRouter(providers: allProviders)
        )
        // Build the document index pipeline once so served recall, the nightly trigger, and the
        // `/index` routes share one store and coordinator; nil when disabled keeps routes failing
        // closed and recall unchanged.
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
        let assembly = ServingAssembly(
            loaded: loaded,
            selected: selected,
            serverConfig: serverConfig,
            auth: auth,
            conversations: conversations,
            memoryEngine: memoryEngine,
            permissionGate: permissionGate,
            embedder: embedder,
            runs: runs,
            hub: hub,
            indexComponents: indexComponents,
            mediaConfig: mediaConfig
        )
        return try await assembleServingContext(assembly)
    }

    private func assembleServingContext(
        _ assembly: ServingAssembly
    ) async throws -> (context: ServerContext, permissionGate: PermissionGate) {
        // Resolve the media section once so the preview registry, the prompt
        // snapshot, and the served context register the same media tools.
        let resolvedMediaConfig = assembly.mediaConfig ?? assembly.loaded.config.media
        // One shared secrets instance per serve invocation so the preview bus,
        // the plugin snapshot, and the served context observe one fallback store.
        let sharedSecrets = SecretsManager()
        // One policy store per serve process so HTTP policy writes stay visible
        // to the egress supervisor without a restart.
        let policyStore = await PolicyStore.makeLoaded(injected: nil)
        let goalStack = makeGoalStack(memoryConfig: assembly.loaded.config.memory, goalsConfig: assembly.loaded.config.goals, selected: assembly.selected)
        let deps = ToolBootstrapDependencies(
            memoryEngine: assembly.memoryEngine,
            embedder: assembly.embedder,
            goalStore: goalStack.store,
            goalEngine: goalStack.engine,
            recipientAliasStore: goalStack.recipientAliasStore,
            conversations: assembly.conversations
        )
        // One seed shared by the prompt preview and the served registry so both
        // builds observe the same media policy, secrets, and policy store.
        let seed = ToolBuildSeed(mediaConfig: resolvedMediaConfig, secrets: sharedSecrets, policyStore: policyStore)
        // Compose the default system prompt from the live registry so the
        // served model sees every registered tool; an explicit flag still wins.
        let plugins = try await makePlugins(loaded: assembly.loaded, deps: deps, seed: seed)
        // Snapshot discovered runes before the service owns the registry so
        // external tools reach the served prompt on first boot.
        let effectiveSystemPrompt = try await resolveEffectiveSystemPrompt(
            loaded: assembly.loaded,
            selected: assembly.selected,
            permissionGate: assembly.permissionGate,
            deps: deps,
            seed: seed
        )
        let context = try await ServerContext.make(
            config: assembly.serverConfig,
            conversations: assembly.conversations,
            memoryEngine: assembly.memoryEngine,
            embedder: assembly.embedder,
            permissionGate: assembly.permissionGate,
            llm: assembly.selected,
            systemPrompt: effectiveSystemPrompt,
            schedulerConfig: assembly.loaded.config.scheduler,
            episodesDBPath: assembly.loaded.config.memory.episodesDBPath,
            pluginConfig: assembly.loaded.config.plugins,
            containersConfig: assembly.loaded.config.containers,
            browserConfig: assembly.loaded.config.browser,
            indexCoordinator: assembly.indexComponents?.coordinator,
            indexStore: assembly.indexComponents?.store,
            llmServerURLs: CLIShared.llmServerURLs(from: assembly.loaded.config.llm),
            engineConfig: assembly.loaded.config.engine,
            emailConfig: assembly.loaded.config.email,
            filesConfig: assembly.loaded.config.files,
            bashConfig: assembly.loaded.config.bash,
            mediaConfig: resolvedMediaConfig,
            desktopConfig: assembly.loaded.config.desktop,
            securityConfig: assembly.loaded.config.security,
            recallBudgets: assembly.loaded.config.memory.recallBudgets,
            goalsConfig: assembly.loaded.config.goals,
            ideasConfig: assembly.loaded.config.ideas,
            proactiveConfig: assembly.loaded.config.proactive,
            auth: assembly.auth,
            mediaSecrets: sharedSecrets,
            secrets: sharedSecrets,
            runs: assembly.runs,
            hub: assembly.hub,
            policyStore: policyStore,
            workspaceConfig: assembly.loaded.config.workspace,
            persona: assembly.loaded.config.persona,
            notificationsConfig: assembly.loaded.config.notifications
        )
        await attachIndexFailureNotifier(context: context)
        await registerAndVerifyTools(context: context, plugins: plugins, selected: assembly.selected, effectiveSystemPrompt: effectiveSystemPrompt)
        return (context, assembly.permissionGate)
    }

    private func attachIndexFailureNotifier(context: ServerContext) async {
        guard context.indexCoordinator != nil else { return }
        // The pre-boot reporter has no notifier; swap in the combined notifier so
        // index failures push while keeping one coordinator for worker and routes.
        let reporter = ServerIndexBoot.makeReporterWithNotifier(runs: context.runs, hub: context.hub, notifier: context.notifier)
        await context.indexCoordinator?.setReporter(reporter)
    }

    private func makeIndexComponents(
        loaded: CLIConfigLoader.LoadedConfig,
        allProviders: [any LLMProvider],
        selected _: any LLMProvider,
        runs: RunLogStore,
        hub: WSHub,
        embedder: any EmbeddingsBackend?
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
            makeEmbeddingsBackend: makeEmbeddingsBackend
        )
    }

    private func makePlugins(
        loaded: CLIConfigLoader.LoadedConfig,
        deps: ToolBootstrapDependencies,
        seed: ToolBuildSeed
    ) async throws -> [any Tool] {
        let previewWorkspace = WorkspaceStore(config: loaded.config.workspace)
        return try await CLIShared.pluginTools(
            emailConfig: loaded.config.email,
            filesConfig: loaded.config.files,
            bashConfig: loaded.config.bash,
            memoryEngine: deps.memoryEngine,
            containersConfig: loaded.config.containers,
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
            recipientAliasStore: deps.recipientAliasStore,
            workspaceConfig: loaded.config.workspace,
            workspaceStore: previewWorkspace
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
            supportsVision: selected.modelInfo.supportsVision,
            persona: loaded.config.persona
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
                            "Serving engine API on \(serverConfig.hostname):\(serverConfig.port) with owner auth: "
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
                        "WARNING: no owner token is configured. Serving UNAUTHENTICATED on loopback only. "
                            + "Run 'rune-weaver auth token generate' before binding to a LAN address."
                    )
                )
            }
            try await app.execute()
            await permissionGate.stopPeriodicCleanup()
            await context.sandboxCleanup.stop()
            await context.hub.closeAll()
            await LlamaEmbeddingSupervisor.shared.stop()
            try await app.asyncShutdown()
        } catch {
            await permissionGate.stopPeriodicCleanup()
            await context.sandboxCleanup.stop()
            await context.hub.closeAll()
            await LlamaEmbeddingSupervisor.shared.stop()
            do {
                try await app.asyncShutdown()
            } catch {
                RuneWeaverLog.server.debug("ServeCommand: asyncShutdown error: \(error.localizedDescription)")
            }
            throw error
        }
    }
}

/// Resolved inputs for a single `serve` invocation.
private struct ResolvedServeConfiguration {
    /// Loaded config plus its source URL for operator messaging.
    let loaded: CLIConfigLoader.LoadedConfig
    /// Owner bearer verifier, or nil for the no-auth loopback posture.
    let auth: ServerAuth?
    /// Bind policy validated against the resolved auth posture.
    let serverConfig: ServerConfig
}

/// Grouped inputs for the served-engine assembly path.
private struct ServingAssembly {
    /// Loaded config backing every derived section.
    let loaded: CLIConfigLoader.LoadedConfig
    /// Provider selected for served turns.
    let selected: any LLMProvider
    /// Bind policy validated against the resolved auth posture.
    let serverConfig: ServerConfig
    /// Owner verifier, or nil for the no-auth loopback posture.
    let auth: ServerAuth?
    /// Conversation history shared with served turns.
    let conversations: ConversationManager
    /// Recall engine shared with served turns.
    let memoryEngine: MemoryEngine
    /// Permission gate shared with served turns.
    let permissionGate: PermissionGate
    /// Embeddings backend, or nil for keyword-only recall.
    let embedder: any EmbeddingsBackend?
    /// Run log backing lifecycle broadcasts.
    let runs: RunLogStore
    /// Hub carrying run lifecycle frames.
    let hub: WSHub
    /// Index collaborators, or nil when indexing is disabled.
    let indexComponents: ServerIndexComponents?
    /// Media policy override, or nil to use the loaded config.
    let mediaConfig: MediaConfig?
}

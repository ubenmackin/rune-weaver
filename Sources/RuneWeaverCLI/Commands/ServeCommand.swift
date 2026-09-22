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
        let (context, permissionGate) = await buildContext(
            loaded: loaded,
            selected: selected,
            allProviders: allProviders,
            serverConfig: serverConfig,
            auth: auth,
            mediaConfig: loaded.config.media
        )
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
        let auth: ServerAuth?
        do {
            auth = try await ServerAuth.resolve(authConfig: loaded.config.auth)
        } catch {
            throw ValidationError("Owner auth could not be resolved: \(error.localizedDescription)")
        }
        // The bind policy lives in `ServerConfig`; this only translates a refusal
        // into the CLI's loopback-only `ValidationError` so the operator gets an
        // actionable message instead of a bare transport error.
        let serverConfig = ServerConfig(hostname: bindHostname, port: bindPort, authConfigured: auth != nil)
        do {
            try serverConfig.requireBindable(authConfigured: auth != nil)
        } catch {
            throw ValidationError(
                "Hostname must be loopback (127.0.0.1, localhost, or ::1) unless an owner token is configured "
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

    private func buildContext(
        loaded: CLIConfigLoader.LoadedConfig,
        selected: any LLMProvider,
        allProviders: [any LLMProvider],
        serverConfig: ServerConfig,
        auth: ServerAuth?,
        mediaConfig: MediaConfig? = nil
    ) async -> (context: ServerContext, permissionGate: PermissionGate) {
        // Point recall at the configured document index when `[index]` is
        // enabled; a disabled section keeps the keyword-and-vector engine.
        let docIndexDBPath: String? = loaded.config.index.enabled ? loaded.config.index.dbPath : nil
        let memoryEngine = CLIShared.memoryEngine(for: loaded.config.memory, docIndexDBPath: docIndexDBPath)
        let conversations = ConversationManager(episodesDBPath: loaded.config.memory.episodesDBPath)
        do {
            try await conversations.loadAll()
        } catch {
            cliPrintError(TerminalStyle.dim("Could not load conversation history; starting fresh."))
        }
        let episodesDB = (loaded.config.memory.episodesDBPath as NSString).expandingTildeInPath
        let trustStore = SQLiteTrustStore(dbPath: episodesDB)
        let permissionGate = await PermissionGate.load(
            store: trustStore,
            pluginsDir: URL(fileURLWithPath: (loaded.config.plugins.pluginsDir as NSString).expandingTildeInPath)
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
        // when disabled keeps routes failing closed and recall unchanged.
        let indexComponents = ServerIndexBoot.makeComponents(
            config: loaded.config,
            embedder: embedder,
            visionLLM: selected
        )
        // Resolve the media section once so the preview registry, the prompt
        // snapshot, and the served context register the same media tools.
        let resolvedMediaConfig = mediaConfig ?? loaded.config.media
        // Compose the default system prompt from the live registry so the
        // served model sees every registered tool; an explicit
        // --system-prompt still overrides it verbatim.
        let plugins = CLIShared.pluginTools(
            emailConfig: loaded.config.email,
            filesConfig: loaded.config.files,
            memoryEngine: memoryEngine,
            sandboxConfig: loaded.config.sandbox,
            embedder: embedder,
            browserConfig: loaded.config.browser,
            llmConfig: loaded.config.llm,
            mediaConfig: resolvedMediaConfig
        )
        // Snapshot discovered runes before the service owns the registry so
        // external tools reach the served prompt; the service syncs the same
        // directory again on boot, keeping both views consistent.
        let previewBus = await CLIShared.makeToolBus(
            emailConfig: loaded.config.email,
            filesConfig: loaded.config.files,
            memoryEngine: memoryEngine,
            permissionGate: permissionGate,
            sandboxConfig: loaded.config.sandbox,
            embedder: embedder,
            pluginConfig: loaded.config.plugins,
            episodesDBPath: loaded.config.memory.episodesDBPath,
            browserConfig: loaded.config.browser,
            llmConfig: loaded.config.llm,
            mediaConfig: resolvedMediaConfig
        )
        let effectiveSystemPrompt = await SystemPromptComposer.resolve(
            flag: systemPrompt,
            toolBus: previewBus,
            supportsVision: selected.modelInfo.supportsVision,
            includeToolSchemas: !selected.modelInfo.supportsTools
        )
        let context = await ServerContext.make(
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
            mediaConfig: resolvedMediaConfig,
            auth: auth
        )
        for tool in plugins {
            await context.toolBus.register(tool: tool)
        }
        // Registration resets each tool to enabled, so re-apply persisted
        // toggles after late builtin registration; the cached load makes
        // this a memory-only pass after the boot hydration in `make`.
        await context.restoreToolStates(forceReload: false)
        // Re-snapshot the live service registry so drift between the startup
        // preview and the serving bus surfaces instead of silently omitting
        // a rune from the prompt.
        let livePrompt = await SystemPromptComposer.resolve(
            flag: systemPrompt,
            toolBus: context.toolBus,
            supportsVision: selected.modelInfo.supportsVision,
            includeToolSchemas: !selected.modelInfo.supportsTools
        )
        if livePrompt != effectiveSystemPrompt {
            print(TerminalStyle.dim("Served prompt differs from live registry; continuing with startup snapshot."))
        }
        return (context, permissionGate)
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

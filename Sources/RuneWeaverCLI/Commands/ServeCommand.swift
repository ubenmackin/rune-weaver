// Rune Weaver CLI — Engine API service command.

import ArgumentParser
import Foundation
import Logging
import RuneWeaverCore
import RuneWeaverLLM
import RuneWeaverServer
import RuneWeaverTools
import Vapor

/// Starts the local engine API service on loopback.
struct ServeCommand: AsyncParsableCommand {
    /// Top-level command configuration.
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Start the engine API service (REST, WebSocket, dashboard) on loopback."
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

    /// Interface to bind. Loopback only by design (auth-before-exposure).
    @ArgumentParser.Option(name: .long, help: "Interface to bind (loopback only, defaults to 127.0.0.1).")
    var hostname: String = ServerConfig.default.hostname

    /// TCP port to bind.
    @ArgumentParser.Option(name: .long, help: "TCP port to bind (defaults to 8082).")
    var port: Int = ServerConfig.default.port

    /// Loads config, wires the engine context, and serves until stopped.
    mutating func run() async throws {
        let loaded = try validateAndLoadConfig()
        let (selected, allProviders) = try await resolveProvider(loaded: loaded)
        let serverConfig = ServerConfig(hostname: hostname, port: port)
        let (context, permissionGate) = await buildContext(
            loaded: loaded,
            selected: selected,
            allProviders: allProviders,
            serverConfig: serverConfig
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
        do {
            try await SearXNGEnsurer.shared.ensure(browser: loaded.config.browser)
            print(TerminalStyle.dim("SearXNG ready at \(loaded.config.browser.searxngURL)."))
        } catch {
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

    private func validateAndLoadConfig() throws -> CLIConfigLoader.LoadedConfig {
        guard ServerConfig.validPortRange.contains(port) else {
            throw ValidationError("--port must be \(ServerConfig.validPortRange) (got \(port)).")
        }
        let serverConfig = ServerConfig(hostname: hostname, port: port)
        guard serverConfig.isLoopbackOnly else {
            throw ValidationError("--hostname must be loopback (127.0.0.1, localhost, or ::1) until auth lands (got '\(hostname)').")
        }
        let loaded = try CLIConfigLoader.loadConfig(path: config)
        if loaded.isFallback {
            print(TerminalStyle.dim("No config found at \(loaded.url.path); using built-in defaults."))
        }
        return loaded
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
        serverConfig: ServerConfig
    ) async -> (context: ServerContext, permissionGate: PermissionGate) {
        let memoryEngine = CLIShared.memoryEngine(for: loaded.config.memory)
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
        // Compose the default system prompt from the live registry so the
        // served model sees every registered tool; an explicit
        // --system-prompt still overrides it verbatim.
        let plugins = CLIShared.pluginTools(
            emailConfig: loaded.config.email,
            memoryEngine: memoryEngine,
            sandboxConfig: loaded.config.sandbox,
            embedder: embedder,
            browserConfig: loaded.config.browser,
            llmConfig: loaded.config.llm
        )
        // Snapshot discovered runes before the service owns the registry so
        // external tools reach the served prompt; the service syncs the same
        // directory again on boot, keeping both views consistent.
        let previewBus = await CLIShared.makeToolBus(
            emailConfig: loaded.config.email,
            memoryEngine: memoryEngine,
            permissionGate: permissionGate,
            sandboxConfig: loaded.config.sandbox,
            embedder: embedder,
            pluginConfig: loaded.config.plugins,
            episodesDBPath: loaded.config.memory.episodesDBPath,
            browserConfig: loaded.config.browser,
            llmConfig: loaded.config.llm
        )
        let effectiveSystemPrompt = await SystemPromptComposer.resolve(flag: systemPrompt, toolBus: previewBus)
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
            llmServerURLs: CLIShared.llmServerURLs(from: loaded.config.llm)
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
        let livePrompt = await SystemPromptComposer.resolve(flag: systemPrompt, toolBus: context.toolBus)
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
            print(TerminalStyle.dim("Serving engine API on \(serverConfig.hostname):\(serverConfig.port) (\(selectedName)). Ctrl+C to stop."))
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

// Rune Weaver CLI — Engine API service command.
//
// Launches the local HTTP REST, WebSocket, and static web dashboard service
// on loopback (127.0.0.1). Serves thin clients (iOS, macOS menu bar, web UI)
// under single-user local machine trust without authentication in v1. Refuses
// non-loopback bindings until authentication lands (auth-before-exposure).

import ArgumentParser
import Foundation
import Logging
import RuneWeaverCore
import RuneWeaverLLM
import RuneWeaverServer
import Vapor

/// Starts the local engine API service on loopback.
///
/// Builds a `ServerContext` via `ServerContext.make(...)`, registers the
/// shared plugin tools on its bus, configures a Vapor `Application` with
/// `configureRuneWeaver(_:context:)`, and runs it so the REST routes,
/// chat WebSocket, and static dashboard bundle serve on `127.0.0.1:8082`
/// by default with no auth (single-user, local-machine trust). The
/// service is CRUD plus manual-run only for the scheduler; cron and poll
/// triggers never auto-fire here — the CLI `scheduler run` foreground
/// loop is the sole auto-fire runner in a separate process.
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
        guard ServerConfig.validPortRange.contains(port) else {
            throw ValidationError("--port must be \(ServerConfig.validPortRange) (got \(port)).")
        }
        let loaded = try CLIConfigLoader.loadConfig(path: config)
        if loaded.isFallback {
            print(TerminalStyle.dim("No config found at \(loaded.url.path); using built-in defaults."))
        }
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
        let memoryEngine = CLIShared.memoryEngine(for: loaded.config.memory)
        let conversations = ConversationManager(episodesDBPath: loaded.config.memory.episodesDBPath)
        do {
            try await conversations.loadAll()
        } catch {
            cliPrintError(TerminalStyle.dim("Could not load conversation history; starting fresh."))
        }
        let permissionGate = PermissionGate()
        let serverConfig = ServerConfig(hostname: hostname, port: port)
        guard serverConfig.isLoopbackOnly else {
            throw ValidationError("--hostname must be loopback (127.0.0.1, localhost, or ::1) until auth lands (got '\(hostname)').")
        }
        // Compose the default system prompt from the live registry so the
        // served model sees every registered tool; an explicit
        // --system-prompt still overrides it verbatim.
        let plugins = CLIShared.pluginTools(
            emailConfig: loaded.config.email,
            memoryEngine: memoryEngine,
            sandboxConfig: loaded.config.sandbox
        )
        let effectiveSystemPrompt = SystemPromptComposer.resolve(flag: systemPrompt, tools: plugins)
        let context = await ServerContext.make(
            config: serverConfig,
            conversations: conversations,
            memoryEngine: memoryEngine,
            permissionGate: permissionGate,
            llm: selected,
            systemPrompt: effectiveSystemPrompt,
            schedulerConfig: loaded.config.scheduler,
            episodesDBPath: loaded.config.memory.episodesDBPath
        )
        for tool in plugins {
            await context.toolBus.register(tool: tool)
        }
        var env = try Environment.detect()
        try LoggingSystem.bootstrap(from: &env)
        let app = try await Application.make(env)
        do {
            try configureRuneWeaver(app, context: context)
            print(TerminalStyle.dim("Serving engine API on \(serverConfig.hostname):\(serverConfig.port) (\(selected.name)). Ctrl+C to stop."))
            try await app.execute()
            await context.hub.closeAll()
            try await app.asyncShutdown()
        } catch {
            await context.hub.closeAll()
            try? await app.asyncShutdown()
            throw error
        }
    }
}

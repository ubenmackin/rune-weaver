// Rune Weaver CLI — Subsystem status inspection and diagnostic commands.

import ArgumentParser
import Foundation
import RuneWeaverCore
import RuneWeaverLLM
import RuneWeaverTools

/// Shows system status: LLM providers, search, memory stats, and active tools.
struct StatusCommand: AsyncParsableCommand {
    /// Top-level command configuration.
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show system status: LLM providers, search, memory stats, and active tools."
    )

    /// Config file path override.
    @Option(name: .long, help: "Path to config.toml (defaults to ~/.runeweaver/config.toml).")
    var config: String?

    /// Loads config, probes providers, and prints the status report.
    mutating func run() async throws {
        let loaded = try CLIConfigLoader.loadConfig(path: config)
        let config = loaded.config
        if loaded.isFallback {
            print(TerminalStyle.dim("No config found at \(loaded.url.path); showing built-in defaults."))
        }
        print("\(TerminalStyle.success("●")) \(config.engine.name): \(loaded.url.path)")

        print("")
        print("LLM providers (default: \(config.llm.defaultProvider)):")
        let providers = await CLIProviderBuilder.buildProviders(from: config.llm)
        if providers.isEmpty {
            print(TerminalStyle.dim("  none enabled"))
        }
        for provider in providers.sorted(by: { $0.name < $1.name }) {
            let info = provider.modelInfo
            let reachable = await provider.isAvailable()
            let dot = reachable ? TerminalStyle.success("●") : TerminalStyle.error("○")
            let state = reachable ? "reachable" : "unreachable"
            let tools = info.supportsTools ? "tools" : "no-tools"
            let embeddings = info.supportsEmbeddings ? "embeddings" : "no-embeddings"
            print("  \(dot) \(provider.name): model \(info.name), context \(info.contextLength), \(tools), \(embeddings) (\(state))")
        }
        let disabled = config.llm.providers.filter { !$0.value.enabled }.map(\.key).sorted()
        if !disabled.isEmpty {
            print(TerminalStyle.dim("  disabled: \(disabled.joined(separator: ", "))"))
        }

        print("")
        print("Memory:")
        let engine = CLIShared.memoryEngine(for: config.memory)
        let episodeCount = await engine.episodeCount()
        let vectorFacts = await engine.allSemanticFacts()
        let vectorCount = vectorFacts.count
        let profile = await engine.getUserProfile()
        print("  episodes: \(episodeCount) (\(config.memory.episodesDBPath))")
        print("  semantic facts: \(vectorCount) (\(config.memory.vectorDBPath))")
        print("  profile: \(profile.facts.count) facts, \(profile.preferences.count) preferences")

        print("")
        print("Tools:")
        // One shared secrets instance so this probe observes the same
        // fallback store as the tools it lists instead of minting per-tool state.
        let sharedSecrets = SecretsManager()
        let toolBus = try await CLIShared.makeToolBus(
            emailConfig: config.email,
            filesConfig: config.files,
            bashConfig: config.bash,
            memoryEngine: engine,
            containersConfig: config.containers,
            pluginConfig: config.plugins,
            episodesDBPath: config.memory.episodesDBPath,
            browserConfig: config.browser,
            llmConfig: config.llm,
            securityConfig: config.security,
            secrets: sharedSecrets,
            workspaceConfig: config.workspace
        )
        let toolNames = await toolBus.toolNames().sorted()
        if toolNames.isEmpty {
            print(TerminalStyle.dim("  no plugin tools registered in this CLI process"))
        } else {
            print("  active: \(toolNames.joined(separator: ", "))")
        }

        print("")
        print("Search:")
        // Single-sourced through the `[browser]` schema so status reports
        // the same URL the search tool dials; reachability reuses the
        // ensurer probe so boot, search, and status agree on up vs down.
        let searchURL = config.browser.searxngURL
        let searchReachable = await SearXNGEnsurer.isReachable(baseURL: searchURL)
        let searchDot = searchReachable ? TerminalStyle.success("●") : TerminalStyle.error("○")
        let searchState = searchReachable ? "reachable" : "unreachable"
        print("  \(searchDot) SearXNG: \(searchState) (\(searchURL))")
        if !searchReachable {
            print(
                TerminalStyle.dim(
                    "  Start with scripts/searxng-up.sh or `container start \(SearXNGEnsurer.containerName)`; "
                        + "the container stays running after quit."
                )
            )
        }
    }
}

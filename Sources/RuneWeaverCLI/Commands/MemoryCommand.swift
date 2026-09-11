import ArgumentParser
import Foundation
import RuneWeaverCore

/// Searches semantic memory and shows what the agent knows.
///
/// `rune-weaver memory search <query>` recalls across episodic, semantic,
/// and profile tiers. `rune-weaver memory facts` lists long-lived profile
/// facts, preferences, and stored fact counts.
struct MemoryCommand: AsyncParsableCommand {
    /// Top-level command configuration.
    static let configuration = CommandConfiguration(
        commandName: "memory",
        abstract: "Search semantic memory and show what the agent knows.",
        subcommands: [MemorySearchCommand.self, MemoryFactsCommand.self]
    )
}

/// Searches all memory tiers for the query.
struct MemorySearchCommand: AsyncParsableCommand {
    /// Top-level command configuration.
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search semantic and episodic memory."
    )

    /// Query text to recall.
    @Argument(help: "Query text (quote multi-word queries).")
    var query: String

    /// Maximum results to show.
    @Option(name: .long, help: "Maximum results to show.")
    var limit: Int = 5

    /// Config file path override.
    @Option(name: .long, help: "Path to config.toml (defaults to ~/.runeweaver/config.toml).")
    var config: String?

    /// Recalls memories and prints them ranked by relevance.
    ///
    /// Recall merges episodic, semantic, and profile tiers per tier limit,
    /// then display is capped to the requested total so `--limit 5` never
    /// prints more than five rows.
    mutating func run() async throws {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError("Query must not be empty.")
        }
        guard limit > 0 else {
            throw ValidationError("--limit must be positive (got \(limit)).")
        }
        let loaded = try CLIConfigLoader.loadConfig(path: config)
        let engine = CLIShared.memoryEngine(for: loaded.config.memory)
        let requested = limit
        let results = try await engine.recall(query: query, limit: requested)
        let displayed = Array(results.prefix(requested))
        guard !displayed.isEmpty else {
            print(TerminalStyle.dim("No memories found for '\(query)'."))
            return
        }
        print("Found \(displayed.count) result\(displayed.count == 1 ? "" : "s") for '\(query)':")
        for (index, result) in displayed.enumerated() {
            let score = String(format: "%.3f", result.score)
            print("")
            print("\(index + 1). [\(result.source.rawValue)] (score \(score))")
            print("   \(result.content)")
        }
    }
}

/// Shows long-lived facts, preferences, and memory counts.
struct MemoryFactsCommand: AsyncParsableCommand {
    /// Top-level command configuration.
    static let configuration = CommandConfiguration(
        commandName: "facts",
        abstract: "Show what the agent knows: facts, preferences, and memory counts."
    )

    /// Config file path override.
    @Option(name: .long, help: "Path to config.toml (defaults to ~/.runeweaver/config.toml).")
    var config: String?

    /// Prints the user profile and stored fact samples.
    mutating func run() async throws {
        let loaded = try CLIConfigLoader.loadConfig(path: config)
        let engine = CLIShared.memoryEngine(for: loaded.config.memory)
        let profile = await engine.getUserProfile()
        let vectorFacts = await engine.allSemanticFacts()
        let episodeCount = await engine.episodeCount()

        print("Facts (\(profile.facts.count)):")
        if profile.facts.isEmpty {
            print(TerminalStyle.dim("  none stored"))
        }
        for fact in profile.facts {
            let confidence = String(format: "%.2f", fact.confidence)
            print("  - \(fact.content) \(TerminalStyle.dim("(confidence \(confidence), via \(fact.source))"))")
        }
        print("")
        print("Preferences (\(profile.preferences.count)):")
        if profile.preferences.isEmpty {
            print(TerminalStyle.dim("  none stored"))
        }
        for preference in profile.preferences {
            print("  - \(preference.key) = \(preference.value)")
        }
        print("")
        print("Semantic facts: \(vectorFacts.count) · Episodes: \(episodeCount)")
        for fact in vectorFacts.prefix(5) {
            print("  - \(cliInline(fact.content, limit: 160))")
        }
        if vectorFacts.count > 5 {
            print(TerminalStyle.dim("  …and \(vectorFacts.count - 5) more. Use 'memory search' to explore."))
        }
    }
}

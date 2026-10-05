// Rune Weaver CLI — Semantic and episodic memory management commands.
//
// Provides CLI commands to search memory tiers, manage facts, and reindex vector embeddings.

import ArgumentParser
import Foundation
import RuneWeaverCore
import RuneWeaverLLM

/// Searches semantic memory and shows what the agent knows.
struct MemoryCommand: AsyncParsableCommand {
    /// Top-level command configuration.
    static let configuration = CommandConfiguration(
        commandName: "memory",
        abstract: "Search semantic memory and show what the agent knows.",
        subcommands: [
            MemorySearchCommand.self,
            MemoryFactsCommand.self,
            MemoryReindexCommand.self,
            MemoryClearEpisodesCommand.self,
            MemoryDeleteEpisodeCommand.self,
            MemoryClearSessionEpisodesCommand.self
        ]
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
        // Resolve the embeddings producer from config through the shared factory so every backend
        // (`apple`, `provider`, `none`) behaves like chat and reindex; any embedding failure keeps
        // the keyword path while cancellation propagates.
        let providers = await CLIProviderBuilder.buildProviders(from: loaded.config.llm)
        let embedder = EmbeddingsBackendFactory.makeBackend(
            memoryEmbeddingBackend: loaded.config.memory.embeddingBackend,
            router: LLMRouter(providers: providers)
        )
        // `embedQuery` isolates embedding failures internally (falling back
        // to nil) and only rethrows cancellation, so a bare await suffices.
        let embedding: [Float]? = if let embedder {
            try await embedder.embedQuery(query)
        } else {
            nil
        }
        let results = try await engine.recall(query: query, embedding: embedding, limit: requested)
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
            print("  - \(ToolInput.inline(fact.content, limit: 160))")
        }
        if vectorFacts.count > 5 {
            print(TerminalStyle.dim("  …and \(vectorFacts.count - 5) more. Use 'memory search' to explore."))
        }
    }
}

/// Rebuilds the semantic index and optionally backfills embeddings.
struct MemoryReindexCommand: AsyncParsableCommand {
    /// Top-level command configuration.
    static let configuration = CommandConfiguration(
        commandName: "reindex",
        abstract: "Rebuild the semantic index and optionally backfill embeddings."
    )

    /// Embed keyword-only facts using the configured backend.
    @Flag(name: .long, help: "Embed keyword-only facts using the configured backend.")
    var embed: Bool = false

    /// Clear the vector store before reindexing.
    @Flag(name: .long, help: "Clear the vector store before reindexing.")
    var reset: Bool = false

    /// Texts per embedding call.
    @Option(name: .long, help: "Batch size for embedding calls.")
    var batchSize: Int = 32

    /// Config file path override.
    @Option(name: .long, help: "Path to config.toml (defaults to ~/.runeweaver/config.toml).")
    var config: String?

    /// Rebuilds the index, backfilling vectors when requested.
    mutating func run() async throws {
        guard batchSize > 0 else {
            throw ValidationError("--batch-size must be positive (got \(batchSize)).")
        }
        let loaded = try CLIConfigLoader.loadConfig(path: config)
        let engine = CLIShared.memoryEngine(for: loaded.config.memory)

        if embed {
            let backendName = loaded.config.memory.embeddingBackend
            let providers = await CLIProviderBuilder.buildProviders(from: loaded.config.llm)
            let router = LLMRouter(providers: providers)
            guard let embedder = EmbeddingsBackendFactory.makeBackend(
                memoryEmbeddingBackend: backendName,
                router: router
            ) else {
                if backendName == MemoryConfig.embeddingBackendNone {
                    print(TerminalStyle.dim(
                        "Embeddings are disabled (memory.embedding_backend = \"none\"). " +
                            "Set it to \"apple\" or \"provider\" to backfill vectors; leaving the keyword-only store untouched."
                    ))
                } else {
                    print(TerminalStyle.dim("Unknown embedding backend \"\(backendName)\"; leaving the keyword-only store untouched."))
                }
                return
            }
            // Clearing is explicit backfill intent on the enabled path only;
            // the disabled path above returns before touching the store.
            if reset {
                try await engine.clearSemanticStore()
            }
            let result = try await engine.backfillEmbeddings(embedder: embedder, batchSize: batchSize)
            let dimension = await engine.semanticDimension()
            let dimensionText = dimension.map(String.init) ?? "unknown"
            print("Backfilled embeddings: \(result.embedded) embedded, \(result.skipped) skipped, \(result.failed) failed (dimension \(dimensionText)).")
            return
        }

        // Without `--embed` the flag is explicit clearing intent even when
        // vectors are disabled, so `--reset` alone still clears.
        if reset {
            try await engine.clearSemanticStore()
        }
        let count = try await engine.reindexSemantic()
        let dimension = await engine.semanticDimension()
        let dimensionText = dimension.map(String.init) ?? "unknown"
        print("Reindexed semantic store: \(count) facts (dimension \(dimensionText)).")
    }
}

/// Clears every episodic turn across all sessions.
///
/// Scope stays episodic only: semantic facts, the profile, the document index,
/// and session ledgers outside the episodes tables are untouched. Clearing
/// applies immediately with no restart and no confirmation, matching the
/// immediacy of reindex --reset.
struct MemoryClearEpisodesCommand: AsyncParsableCommand {
    /// Top-level command configuration.
    static let configuration = CommandConfiguration(
        commandName: "clear-episodes",
        abstract: "Clear all episodic turns."
    )

    /// Config file path override.
    @Option(name: .long, help: "Path to config.toml (defaults to ~/.runeweaver/config.toml).")
    var config: String?

    /// Clears the episodes tables and prints the measured and remaining counts.
    mutating func run() async throws {
        let loaded = try CLIConfigLoader.loadConfig(path: config)
        // Delegate to the engine owner so the CLI never touches the episode
        // store directly; the returned count is measured before the delete.
        let engine = CLIShared.memoryEngine(for: loaded.config.memory)
        let deleted = try await engine.clearEpisodic()
        let remaining = await engine.episodeCount()
        print("Cleared \(deleted) episodic turns (\(remaining) remaining).")
    }
}

/// Deletes one episodic turn by identifier.
///
/// A missing identifier completes as a no-op so retries and double-deletes
/// never surface as failures. UUID shape is validated here at the boundary;
/// the engine takes the typed identifier as-is.
struct MemoryDeleteEpisodeCommand: AsyncParsableCommand {
    /// Top-level command configuration.
    static let configuration = CommandConfiguration(
        commandName: "delete-episode",
        abstract: "Delete one episodic turn by id."
    )

    /// Episode identifier to remove.
    @Argument(help: ArgumentHelp("Episode identifier (UUID).", valueName: "id"))
    var id: String

    /// Config file path override.
    @Option(name: .long, help: "Path to config.toml (defaults to ~/.runeweaver/config.toml).")
    var config: String?

    /// Validates the identifier, deletes the row, and prints what was removed.
    mutating func run() async throws {
        guard let episodeID = UUID(uuidString: id) else {
            throw ValidationError("id must be a UUID")
        }
        let loaded = try CLIConfigLoader.loadConfig(path: config)
        // Delegate to the engine owner so the CLI never touches the episode
        // store directly.
        let engine = CLIShared.memoryEngine(for: loaded.config.memory)
        try await engine.deleteEpisode(id: episodeID)
        print("Deleted episode \(episodeID.uuidString).")
    }
}

/// Clears every episodic turn for one session.
///
/// Only rows for the given session are removed; sibling sessions stay
/// searchable. An unknown session completes as a no-op with no failure.
struct MemoryClearSessionEpisodesCommand: AsyncParsableCommand {
    /// Top-level command configuration.
    static let configuration = CommandConfiguration(
        commandName: "clear-session-episodes",
        abstract: "Clear episodic turns for one session."
    )

    /// Session identifier whose episodes should be removed.
    @Argument(help: ArgumentHelp("Session identifier (UUID).", valueName: "session-id"))
    var sessionID: String

    /// Config file path override.
    @Option(name: .long, help: "Path to config.toml (defaults to ~/.runeweaver/config.toml).")
    var config: String?

    /// Validates the session identifier, deletes its rows, and prints the session.
    mutating func run() async throws {
        guard let sessionUUID = UUID(uuidString: sessionID) else {
            throw ValidationError("sessionID must be a UUID")
        }
        let loaded = try CLIConfigLoader.loadConfig(path: config)
        // Delegate to the engine owner so the CLI never touches the episode
        // store directly.
        let engine = CLIShared.memoryEngine(for: loaded.config.memory)
        try await engine.deleteSession(sessionUUID)
        print("Cleared episodes for session \(sessionUUID.uuidString).")
    }
}

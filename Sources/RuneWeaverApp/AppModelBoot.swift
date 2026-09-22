// Rune Weaver App — Menu bar boot collaborator construction.
//
// Isolates the document-index-aware boot helpers so the menu-bar model stays
// focused on lifecycle: provider key resolution without logging, dummy fallback
// selection, single-path memory wiring, best-effort conversation hydration, and
// shared embeddings construction. All helpers run on the main actor because
// they mutate published boot state through the owning model.

import Foundation
import RuneWeaverCore
import RuneWeaverLLM
import RuneWeaverServer
import RuneWeaverTools

@MainActor
extension AppModel {
    /// Resolves provider API keys at boot without logging values.
    ///
    /// Each entry reads its `apiKeyEnv` from the environment first, then the
    /// Keychain, so a missing credential simply stays absent and the provider
    /// falls back rather than failing boot.
    func resolveBootAPIKeys(config: RuneWeaverConfig, secrets: SecretsManager) async -> [String: String] {
        var keysByEntry: [String: String] = [:]
        for (entryName, entry) in config.llm.providers {
            guard let envVar = entry.apiKeyEnv, !envVar.isEmpty else { continue }
            if let key = LLMProviderFactory.resolveAPIKey(explicit: nil, envVar: envVar) {
                keysByEntry[entryName] = key
            } else if let stored = try? await secrets.retrieve(key: envVar) {
                keysByEntry[entryName] = stored
            }
        }
        return keysByEntry
    }

    /// Selects the active LLM provider, falling back to a dummy when none is enabled.
    ///
    /// The dummy keeps boot live so Settings can configure a provider; it never
    /// dials or stores anything.
    func selectBootProvider(config: RuneWeaverConfig, providers: [any LLMProvider]) -> any LLMProvider {
        if let chosen = LLMProviderFactory.selectProvider(named: nil, from: providers, config: config.llm) {
            return chosen
        }
        return FallbackDummyProvider()
    }

    /// Builds the memory engine sharing one document-index path with recall.
    ///
    /// A disabled `[index]` keeps the keyword-and-vector engine so recall is
    /// unchanged; an enabled section points recall at the same `db_path` the
    /// index pipeline writes, keeping the single-path invariant.
    func makeBootMemoryEngine(config: RuneWeaverConfig) -> MemoryEngine {
        if config.index.enabled {
            return MemoryEngine(
                episodesDBPath: config.memory.episodesDBPath,
                vectorDBPath: config.memory.vectorDBPath,
                docIndexDBPath: config.index.dbPath
            )
        }
        return MemoryEngine(config: config.memory)
    }

    /// Loads persisted conversations best-effort for menu-bar resume.
    ///
    /// A read failure starts fresh but surfaces through the console so missing
    /// history is never mistaken for an empty account.
    func loadBootConversations(config: RuneWeaverConfig) async -> ConversationManager {
        let conversations = ConversationManager(episodesDBPath: config.memory.episodesDBPath)
        do {
            try await conversations.loadAll()
        } catch {
            print("[RuneWeaverApp] Could not load conversation history; starting fresh: \(error)")
        }
        return conversations
    }

    /// Shares one embeddings backend across memory tools and served recall.
    ///
    /// Nil keeps keyword-only behavior when vectors are disabled, matching the
    /// CLI ranking path.
    func makeBootEmbedder(config: RuneWeaverConfig, providers: [any LLMProvider]) -> (any EmbeddingsBackend)? {
        EmbeddingsBackendFactory.makeBackend(
            memoryEmbeddingBackend: config.memory.embeddingBackend,
            router: LLMRouter(providers: providers)
        )
    }
}

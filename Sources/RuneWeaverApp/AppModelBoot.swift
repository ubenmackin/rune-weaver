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

    /// Encapsulates collaborators assembled during menu bar server boot.
    struct BootPipeline {
        let config: RuneWeaverConfig
        let bindConfig: ServerConfig
        let auth: ServerAuth?
        let secrets: SecretsManager
        let selectedProvider: any LLMProvider
        let memoryEngine: MemoryEngine
        let conversations: ConversationManager
        let embedder: (any EmbeddingsBackend)?
        let indexComponents: ServerIndexComponents?
        let plugins: [any Tool]
        let permissionGate: PermissionGate
        let effectiveSystemPrompt: String
    }

    /// Builds the permission gate and served prompt from the live registry so served turns see
    /// every registered tool including discovered runes.
    func buildGateAndSystemPrompt(
        plugins: [any Tool],
        config: RuneWeaverConfig
    ) async -> (PermissionGate, String) {
        let episodesDB = (config.memory.episodesDBPath as NSString).expandingTildeInPath
        let trustStore = SQLiteTrustStore(dbPath: episodesDB)
        let permissionGate = await PermissionGate.load(
            store: trustStore,
            pluginsDir: URL(fileURLWithPath: (config.plugins.pluginsDir as NSString).expandingTildeInPath)
        )
        await permissionGate.startPeriodicCleanup()
        let previewBus = ToolBus(permissionGate: permissionGate)
        let desktopNames = Set(DesktopTools.allToolNames)
        for tool in plugins {
            await previewBus.register(tool: tool, isEnabled: !desktopNames.contains(tool.name))
        }
        let previewPluginsURL = URL(fileURLWithPath: (config.plugins.pluginsDir as NSString).expandingTildeInPath)
        let previewStore = ToolRegistryStore(dbPath: (config.memory.episodesDBPath as NSString).expandingTildeInPath)
        let previewDiscovery = PluginDiscoveryService(pluginsDirectory: previewPluginsURL, store: previewStore)
        await previewDiscovery.discoverAndSync(toolBus: previewBus)
        let stored = await ToolStateStore(dbPath: episodesDB).loadAll()
        for (name, enabled) in stored {
            if enabled {
                await previewBus.enableTool(named: name)
            } else {
                await previewBus.disableTool(named: name)
            }
        }
        let effectiveSystemPrompt = await SystemPromptComposer.resolve(flag: nil, toolBus: previewBus)
        return (permissionGate, effectiveSystemPrompt)
    }

    /// Assembles the boot pipeline collaborators.
    func buildBootPipeline(
        config: RuneWeaverConfig,
        bindConfig: ServerConfig,
        auth: ServerAuth?
    ) async -> BootPipeline {
        let secrets = SecretsManager()
        let keysByEntry = await resolveBootAPIKeys(config: config, secrets: secrets)
        let providers = LLMProviderFactory.makeProviders(from: config.llm, apiKeysByEntry: keysByEntry)
        let selectedProvider = selectBootProvider(config: config, providers: providers)
        let memoryEngine = makeBootMemoryEngine(config: config)
        let conversations = await loadBootConversations(config: config)
        let embedder = makeBootEmbedder(config: config, providers: providers)
        let makeEmbeddingsBackend: @Sendable () -> (any EmbeddingsBackend)? =
            EmbeddingsBackendFactory.makePoolFactory(
                memoryEmbeddingBackend: config.memory.embeddingBackend,
                providers: providers
            )
        let indexComponents = ServerIndexBoot.makeComponents(
            config: config,
            embedder: embedder,
            visionLLM: selectedProvider,
            makeEmbeddingsBackend: makeEmbeddingsBackend
        )
        let goalStore = GoalStore(dbPath: config.memory.episodesDBPath)
        let goalEngine = GoalEngine(store: goalStore, llm: selectedProvider, config: config.goals)
        let plugins = BuiltinToolPlugins.makeAllTools(
            config: config,
            memoryEngine: memoryEngine,
            embedder: embedder,
            mediaSecrets: secrets,
            secrets: secrets,
            goalEngine: goalEngine,
            goalStore: goalStore,
            goalConversations: conversations
        )
        let (permissionGate, effectiveSystemPrompt) = await buildGateAndSystemPrompt(
            plugins: plugins,
            config: config
        )
        return BootPipeline(
            config: config,
            bindConfig: bindConfig,
            auth: auth,
            secrets: secrets,
            selectedProvider: selectedProvider,
            memoryEngine: memoryEngine,
            conversations: conversations,
            embedder: embedder,
            indexComponents: indexComponents,
            plugins: plugins,
            permissionGate: permissionGate,
            effectiveSystemPrompt: effectiveSystemPrompt
        )
    }

    /// Constructs the live ServerContext from the assembled boot pipeline.
    func makeBootServerContext(pipeline: BootPipeline) async -> ServerContext {
        let appLLMOrigins = LLMOrigins.serverURLs(from: pipeline.config.llm)
        return await ServerContext.make(
            config: pipeline.bindConfig,
            conversations: pipeline.conversations,
            memoryEngine: pipeline.memoryEngine,
            embedder: pipeline.embedder,
            permissionGate: pipeline.permissionGate,
            llm: pipeline.selectedProvider,
            systemPrompt: pipeline.effectiveSystemPrompt,
            schedulerConfig: pipeline.config.scheduler,
            episodesDBPath: pipeline.config.memory.episodesDBPath,
            pluginConfig: pipeline.config.plugins,
            notifier: notificationManager,
            onApprovalRequested: { [weak self] req in
                await self?.notificationManager.postApprovalNotification(req)
                await self?.refreshPendingApprovals()
            },
            sandboxConfig: pipeline.config.sandbox,
            browserConfig: pipeline.config.browser,
            indexCoordinator: pipeline.indexComponents?.coordinator,
            indexStore: pipeline.indexComponents?.store,
            llmServerURLs: appLLMOrigins,
            engineConfig: pipeline.config.engine,
            emailConfig: pipeline.config.email,
            filesConfig: pipeline.config.files,
            mediaConfig: pipeline.config.media,
            desktopConfig: pipeline.config.desktop,
            securityConfig: pipeline.config.security,
            goalsConfig: pipeline.config.goals,
            auth: pipeline.auth,
            mediaSecrets: pipeline.secrets,
            secrets: pipeline.secrets
        )
    }

    /// Registers the builtin plugin tools and restores persisted states on the context.
    func registerBootTools(context: ServerContext, plugins: [any Tool]) async {
        for tool in plugins {
            let isEnabled = await context.toolBus.isToolEnabled(named: tool.name)
            await context.toolBus.register(tool: tool, isEnabled: isEnabled)
        }
        await context.restoreToolStates(forceReload: false)
    }
}

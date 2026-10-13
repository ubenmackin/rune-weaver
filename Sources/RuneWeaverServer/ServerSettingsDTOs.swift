// Rune Weaver Server — Settings REST DTOs.
//
// Purpose: carries the full settings snapshot for `GET /settings` plus the
// partial update for `PUT /settings` so dashboard edits preserve every field
// the request omits while engine, server bind, media, index, desktop, goals,
// proactive, ideas, fanout, browser, bash, workspace, containers, and files
// patches merge in one place.
// Scope: REST bodies and merge policy only; range and shape checks stay with
// the config validation layer and live-reload decisions stay with the
// settings routes.
// Architectural role: keeps the Vapor settings adapters decoupled from the
// engine core in version-tolerant Codable contracts, so a dashboard built
// against an older engine still decodes.
//
// Live-apply note: `WorkspaceStore` derives limits per call (`usage`,
// `pruneTmp`, and `checkQuota` all read `config.clamped()`), so a save pushes
// the merged quotas into the live context store in place and the next usage,
// prune, and `bash.exec` checks enforce them with no restart. The rebuilt
// `BashTool` carries a fresh store with the same hermetic overrides, so
// isolated roots keep enforcing against the same tree.

import Foundation
import RuneWeaverCore
import Vapor

/// Settings snapshot for `GET /settings` and `PUT /settings`.
/// Carries both `browser*` (canonical `[browser]` keys) and `search*`
/// dashboard aliases with identical values so either contract reads without
/// falling back to defaults.
public struct SettingsResponse: Content, Equatable {
    public let engineName: String
    public let logLevel: String
    public let compactionThresholdPercent: Int
    public let maxToolIterations: Int
    /// Default tool iterations for scheduled runs (`[scheduler] max_tool_iterations`).
    public let schedulerMaxToolIterations: Int
    public let defaultProvider: String
    public let fallbackProvider: String?
    public let providers: [String: ProviderConfig]
    public let memoryVectorDBPath: String
    public let memoryEpisodesDBPath: String
    public let memoryEmbeddingModel: String
    public let memoryEmbeddingBackend: String
    /// Maximum hits fetched per recall tier before merging (`[memory] recall_per_tier_limit`).
    public let memoryRecallPerTierLimit: Int
    /// Maximum hits injected as system context on one auto turn (`[memory] recall_auto_limit`).
    public let memoryRecallAutoLimit: Int
    /// Minimum calibrated score for an injected recall hit (`[memory] recall_threshold`).
    public let memoryRecallThreshold: Double
    /// Maximum characters for the injected recall block (`[memory] recall_max_chars`).
    public let memoryRecallMaxChars: Int
    /// Maximum characters kept per hit before ellipsis truncation (`[memory] recall_per_hit_chars`).
    public let memoryRecallPerHitChars: Int
    /// Widening factor for the document candidate pool (`[memory] recall_doc_pool_multiplier`):
    /// `pool = clamped * multiplier` drives the vector leg's read width
    /// `min(max(pool * 10, 500), maxPerTierResults)` and the keyword leg mirrors it.
    /// Inert at the default page size — it moves the vector leg only once
    /// `pool * 10` clears the 500-row floor.
    public let memoryRecallDocPoolMultiplier: Int
    /// Weight mapping episodic rank scores onto the shared recall scale (`[memory] recall_episodic_weight`).
    public let memoryRecallEpisodicWeight: Double
    public let voiceSTTProvider: String
    public let voiceWhisperModel: String
    public let voiceTTSProvider: String
    /// Unified container runtime policy from `[containers]`.
    public let containers: ContainersConfig
    public let filesDenyPatterns: [String]
    public let filesAllowRoots: [String]
    public let filesRequireApprovalOnDeny: Bool
    /// Forced `files.write` posture from `[files] write_mode` (`model`, `staged`, or `live`).
    public let filesWriteMode: String
    /// Per-path write postures from `[files] write_path_rules`, evaluated above
    /// the global write mode with the longest matching rule winning.
    public let filesWritePathRules: [FilesWritePathRule]
    public let browserSearxngURL: String
    public let browserSearchTimeoutSeconds: Int
    public let browserMaxResults: Int
    public let browserTimeoutSeconds: Int
    public let browserFetchTimeoutSeconds: Int
    public let searchSearxngURL: String
    public let searchTimeoutSeconds: Int
    public let searchMaxResults: Int
    public let emailAccounts: [EmailAccount]
    public let pluginsDir: String
    public let pluginsMarketplaceIndexURL: String
    public let pluginsAutoRescan: Bool
    public let media: MediaConfig
    /// Local background indexer policy.
    public let index: IndexConfig
    /// macOS desktop vision and gated control policy.
    public let desktop: DesktopConfig
    /// Granular shell execution policy.
    public let bash: BashConfig
    /// Scratch workspace quotas and temp retention bounding shell turns.
    public let workspace: WorkspaceConfig
    /// Steady long-horizon pursuit policy.
    public let goals: GoalsConfig
    /// Interruption policy for background scheduler and goal turns.
    public let proactive: ProactiveConfig
    /// Proactive Wayfinder suggestion policy.
    public let ideas: IdeasConfig
    /// Parallel worker fan-out policy backing `fanout.run`.
    public let fanout: FanOutConfig
    /// Owner-facing assistant persona from `[persona]`. The stored snapshot
    /// rides the settings GET so the dashboard identity surface round-trips
    /// without a second endpoint; a persona save itself is boot-held and
    /// advertised through `requiresRestart`.
    public let persona: PersonaConfig
    /// HTTP bind interface from `[server] hostname`. Changing it needs a restart
    /// because the socket and the Host gate are fixed at boot.
    public let serverHostname: String
    /// HTTP bind port from `[server] port`. Changing it needs a restart.
    public let serverPort: Int
    /// Exact-only extra Host entries from `[server] allowed_hosts`, lowercased
    /// and port-stripped. Changing them needs a restart.
    public let serverAllowedHosts: [String]
    public let configPath: String
    /// Whether the saved values need a restart to take effect. True when the
    /// request carried bind-affecting `[server]` keys; the route never
    /// live-reloads the socket or the middleware set.
    public let requiresRestart: Bool

    public init(config: RuneWeaverConfig, configPath: String, requiresRestart: Bool = false) {
        self.engineName = config.engine.name
        self.logLevel = config.engine.logLevel
        self.compactionThresholdPercent = config.engine.compactionThresholdPercent
        self.maxToolIterations = config.engine.maxToolIterations
        self.schedulerMaxToolIterations = config.scheduler.defaultMaxToolIterations
        self.defaultProvider = config.llm.defaultProvider
        self.fallbackProvider = config.llm.fallbackProvider
        self.providers = config.llm.providers
        self.memoryVectorDBPath = config.memory.vectorDBPath
        self.memoryEpisodesDBPath = config.memory.episodesDBPath
        self.memoryEmbeddingModel = config.memory.embeddingModel
        self.memoryEmbeddingBackend = config.memory.embeddingBackend
        self.memoryRecallPerTierLimit = config.memory.recallBudgets.perTierLimit
        self.memoryRecallAutoLimit = config.memory.recallBudgets.autoLimit
        self.memoryRecallThreshold = config.memory.recallBudgets.threshold
        self.memoryRecallMaxChars = config.memory.recallBudgets.maxChars
        self.memoryRecallPerHitChars = config.memory.recallBudgets.perHitChars
        self.memoryRecallDocPoolMultiplier = config.memory.recallBudgets.docPoolMultiplier
        self.memoryRecallEpisodicWeight = config.memory.recallBudgets.episodicWeight
        self.voiceSTTProvider = config.voice.sttProvider
        self.voiceWhisperModel = config.voice.whisperModel
        self.voiceTTSProvider = config.voice.ttsProvider
        self.containers = config.containers
        self.filesDenyPatterns = config.files.denyPatterns
        self.filesAllowRoots = config.files.allowRoots
        self.filesRequireApprovalOnDeny = config.files.requireApprovalOnDeny
        self.filesWriteMode = config.files.writeMode.rawValue
        self.filesWritePathRules = config.files.writePathRules
        self.browserSearxngURL = config.browser.searxngURL
        self.browserSearchTimeoutSeconds = config.browser.searchTimeoutSeconds
        self.browserMaxResults = config.browser.maxResults
        self.browserTimeoutSeconds = config.browser.timeoutSeconds
        self.browserFetchTimeoutSeconds = config.browser.fetchTimeoutSeconds
        self.searchSearxngURL = config.browser.searxngURL
        self.searchTimeoutSeconds = config.browser.searchTimeoutSeconds
        self.searchMaxResults = config.browser.maxResults
        self.emailAccounts = config.email.accounts
        self.pluginsDir = config.plugins.pluginsDir
        self.pluginsMarketplaceIndexURL = config.plugins.marketplaceIndexURL
        self.pluginsAutoRescan = config.plugins.autoRescan
        self.media = config.media
        self.index = config.index
        self.desktop = config.desktop
        self.bash = config.bash
        self.workspace = config.workspace
        self.goals = config.goals
        self.proactive = config.proactive
        self.ideas = config.ideas
        self.fanout = config.fanOut
        self.persona = config.persona
        self.serverHostname = config.server.hostname
        self.serverPort = config.server.port
        self.serverAllowedHosts = config.server.allowedHosts
        self.configPath = configPath
        self.requiresRestart = requiresRestart
    }

    private enum CodingKeys: String, CodingKey {
        case engineName
        case logLevel
        case compactionThresholdPercent
        case maxToolIterations
        case schedulerMaxToolIterations
        case defaultProvider
        case fallbackProvider
        case providers
        case memoryVectorDBPath
        case memoryEpisodesDBPath
        case memoryEmbeddingModel
        case memoryEmbeddingBackend
        case memoryRecallPerTierLimit
        case memoryRecallAutoLimit
        case memoryRecallThreshold
        case memoryRecallMaxChars
        case memoryRecallPerHitChars
        case memoryRecallDocPoolMultiplier
        case memoryRecallEpisodicWeight
        case voiceSTTProvider
        case voiceWhisperModel
        case voiceTTSProvider
        case containers
        case filesDenyPatterns
        case filesAllowRoots
        case filesRequireApprovalOnDeny
        case filesWriteMode
        case filesWritePathRules
        case browserSearxngURL
        case browserSearchTimeoutSeconds
        case browserMaxResults
        case browserTimeoutSeconds
        case browserFetchTimeoutSeconds
        case searchSearxngURL
        case searchTimeoutSeconds
        case searchMaxResults
        case emailAccounts
        case pluginsDir
        case pluginsMarketplaceIndexURL
        case pluginsAutoRescan
        case media
        case index
        case desktop
        case bash
        case workspace
        case goals
        case proactive
        case ideas
        case fanout
        case persona
        case serverHostname
        case serverPort
        case serverAllowedHosts
        case configPath
        case requiresRestart
    }

    /// Decodes tolerantly so payloads from engines that predate an additive
    /// settings key still parse: the key falls back to its documented default
    /// — the `[server]` bind fields to the loopback defaults, `requiresRestart`
    /// to false, and `logLevel` to the engine's documented `info` — instead of
    /// failing the settings fetch. The posture is deliberately defensive rather
    /// than strict: every settings-surface key has a known default, so a missing
    /// key means an older writer on the wire, not a corrupt payload, and
    /// refusing the whole GET for one absent key would strand the dashboard on
    /// a surface it can render correctly from the remaining fields.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        engineName = try container.decode(String.self, forKey: .engineName)
        logLevel = try container.decodeIfPresent(String.self, forKey: .logLevel) ?? "info"
        compactionThresholdPercent = try container.decodeIfPresent(Int.self, forKey: .compactionThresholdPercent) ?? 80
        maxToolIterations = try container.decodeIfPresent(Int.self, forKey: .maxToolIterations) ?? 10
        schedulerMaxToolIterations = try container.decodeIfPresent(Int.self, forKey: .schedulerMaxToolIterations) ?? 25
        defaultProvider = try container.decode(String.self, forKey: .defaultProvider)
        fallbackProvider = try container.decodeIfPresent(String.self, forKey: .fallbackProvider)
        providers = try container.decodeIfPresent([String: ProviderConfig].self, forKey: .providers) ?? [:]
        memoryVectorDBPath = try container.decodeIfPresent(String.self, forKey: .memoryVectorDBPath) ?? ""
        memoryEpisodesDBPath = try container.decodeIfPresent(String.self, forKey: .memoryEpisodesDBPath) ?? ""
        memoryEmbeddingModel = try container.decodeIfPresent(String.self, forKey: .memoryEmbeddingModel) ?? ""
        memoryEmbeddingBackend = try container.decodeIfPresent(String.self, forKey: .memoryEmbeddingBackend) ?? "apple"
        memoryRecallPerTierLimit = try container.decodeIfPresent(Int.self, forKey: .memoryRecallPerTierLimit) ?? RecallBudgets.defaultPerTierLimit
        memoryRecallAutoLimit = try container.decodeIfPresent(Int.self, forKey: .memoryRecallAutoLimit) ?? RecallBudgets.defaultAutoLimit
        memoryRecallThreshold = try container.decodeIfPresent(Double.self, forKey: .memoryRecallThreshold) ?? RecallBudgets.defaultThreshold
        memoryRecallMaxChars = try container.decodeIfPresent(Int.self, forKey: .memoryRecallMaxChars) ?? RecallBudgets.defaultMaxChars
        memoryRecallPerHitChars = try container.decodeIfPresent(Int.self, forKey: .memoryRecallPerHitChars) ?? RecallBudgets.defaultPerHitChars
        memoryRecallDocPoolMultiplier = try container.decodeIfPresent(
            Int.self,
            forKey: .memoryRecallDocPoolMultiplier
        ) ?? RecallBudgets.defaultDocPoolMultiplier
        memoryRecallEpisodicWeight = try container.decodeIfPresent(Double.self, forKey: .memoryRecallEpisodicWeight) ?? RecallBudgets.defaultEpisodicWeight
        voiceSTTProvider = try container.decodeIfPresent(String.self, forKey: .voiceSTTProvider) ?? ""
        voiceWhisperModel = try container.decodeIfPresent(String.self, forKey: .voiceWhisperModel) ?? ""
        voiceTTSProvider = try container.decodeIfPresent(String.self, forKey: .voiceTTSProvider) ?? ""
        // Absent containers keeps the documented bounds so payloads written
        // before the `[containers]` surface existed still decode instead of
        // failing the settings fetch, mirroring the workspace tolerance.
        containers = try container.decodeIfPresent(ContainersConfig.self, forKey: .containers) ?? ContainersConfig()
        filesDenyPatterns = try container.decodeIfPresent([String].self, forKey: .filesDenyPatterns) ?? []
        filesAllowRoots = try container.decodeIfPresent([String].self, forKey: .filesAllowRoots) ?? []
        filesRequireApprovalOnDeny = try container.decodeIfPresent(Bool.self, forKey: .filesRequireApprovalOnDeny) ?? true
        filesWriteMode = try container.decodeIfPresent(String.self, forKey: .filesWriteMode) ?? "model"
        filesWritePathRules = try container.decodeIfPresent([FilesWritePathRule].self, forKey: .filesWritePathRules)
            ?? FilesWritePathRule.defaultRules
        browserSearxngURL = try container.decodeIfPresent(String.self, forKey: .browserSearxngURL) ?? ""
        browserSearchTimeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .browserSearchTimeoutSeconds) ?? 10
        browserMaxResults = try container.decodeIfPresent(Int.self, forKey: .browserMaxResults) ?? 10
        browserTimeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .browserTimeoutSeconds) ?? BrowserConfig.defaultTimeoutSeconds
        browserFetchTimeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .browserFetchTimeoutSeconds) ?? BrowserConfig.defaultFetchTimeoutSeconds
        searchSearxngURL = try container.decodeIfPresent(String.self, forKey: .searchSearxngURL) ?? browserSearxngURL
        searchTimeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .searchTimeoutSeconds) ?? browserSearchTimeoutSeconds
        searchMaxResults = try container.decodeIfPresent(Int.self, forKey: .searchMaxResults) ?? browserMaxResults
        emailAccounts = try container.decodeIfPresent([EmailAccount].self, forKey: .emailAccounts) ?? []
        pluginsDir = try container.decodeIfPresent(String.self, forKey: .pluginsDir) ?? ""
        pluginsMarketplaceIndexURL = try container.decodeIfPresent(String.self, forKey: .pluginsMarketplaceIndexURL) ?? ""
        pluginsAutoRescan = try container.decodeIfPresent(Bool.self, forKey: .pluginsAutoRescan) ?? true
        media = try container.decodeIfPresent(MediaConfig.self, forKey: .media) ?? MediaConfig()
        index = try container.decodeIfPresent(IndexConfig.self, forKey: .index) ?? IndexConfig()
        desktop = try container.decodeIfPresent(DesktopConfig.self, forKey: .desktop) ?? DesktopConfig()
        bash = try container.decodeIfPresent(BashConfig.self, forKey: .bash) ?? BashConfig()
        // Absent workspace keeps the stock scratch quotas so payloads written
        // before the `[workspace]` surface existed still decode instead of
        // failing the settings fetch, mirroring the persona tolerance below.
        workspace = try container.decodeIfPresent(WorkspaceConfig.self, forKey: .workspace) ?? WorkspaceConfig()
        goals = try container.decodeIfPresent(GoalsConfig.self, forKey: .goals) ?? GoalsConfig()
        proactive = try container.decodeIfPresent(ProactiveConfig.self, forKey: .proactive) ?? ProactiveConfig()
        ideas = try container.decodeIfPresent(IdeasConfig.self, forKey: .ideas) ?? IdeasConfig()
        fanout = try container.decodeIfPresent(FanOutConfig.self, forKey: .fanout) ?? FanOutConfig()
        // Absent persona keeps the stock identity so payloads written before
        // the `[persona]` surface existed still decode instead of failing the
        // settings fetch, mirroring the config document's own tolerance.
        persona = try container.decodeIfPresent(PersonaConfig.self, forKey: .persona) ?? PersonaConfig()
        serverHostname = try container.decodeIfPresent(String.self, forKey: .serverHostname) ?? ServerEndpointConfig.defaultHostname
        serverPort = try container.decodeIfPresent(Int.self, forKey: .serverPort) ?? ServerEndpointConfig.defaultPort
        serverAllowedHosts = try container.decodeIfPresent([String].self, forKey: .serverAllowedHosts) ?? []
        configPath = try container.decodeIfPresent(String.self, forKey: .configPath) ?? ""
        requiresRestart = try container.decodeIfPresent(Bool.self, forKey: .requiresRestart) ?? false
    }

    /// Encodes every field including the bind keys so newer dashboards can rely
    /// on their presence without falling back to defaults.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(engineName, forKey: .engineName)
        try container.encode(logLevel, forKey: .logLevel)
        try container.encode(compactionThresholdPercent, forKey: .compactionThresholdPercent)
        try container.encode(maxToolIterations, forKey: .maxToolIterations)
        try container.encode(schedulerMaxToolIterations, forKey: .schedulerMaxToolIterations)
        try container.encode(defaultProvider, forKey: .defaultProvider)
        try container.encodeIfPresent(fallbackProvider, forKey: .fallbackProvider)
        try container.encode(providers, forKey: .providers)
        try container.encode(memoryVectorDBPath, forKey: .memoryVectorDBPath)
        try container.encode(memoryEpisodesDBPath, forKey: .memoryEpisodesDBPath)
        try container.encode(memoryEmbeddingModel, forKey: .memoryEmbeddingModel)
        try container.encode(memoryEmbeddingBackend, forKey: .memoryEmbeddingBackend)
        try container.encode(memoryRecallPerTierLimit, forKey: .memoryRecallPerTierLimit)
        try container.encode(memoryRecallAutoLimit, forKey: .memoryRecallAutoLimit)
        try container.encode(memoryRecallThreshold, forKey: .memoryRecallThreshold)
        try container.encode(memoryRecallMaxChars, forKey: .memoryRecallMaxChars)
        try container.encode(memoryRecallPerHitChars, forKey: .memoryRecallPerHitChars)
        try container.encode(memoryRecallDocPoolMultiplier, forKey: .memoryRecallDocPoolMultiplier)
        try container.encode(memoryRecallEpisodicWeight, forKey: .memoryRecallEpisodicWeight)
        try container.encode(voiceSTTProvider, forKey: .voiceSTTProvider)
        try container.encode(voiceWhisperModel, forKey: .voiceWhisperModel)
        try container.encode(voiceTTSProvider, forKey: .voiceTTSProvider)
        try container.encode(containers, forKey: .containers)
        try container.encode(filesDenyPatterns, forKey: .filesDenyPatterns)
        try container.encode(filesAllowRoots, forKey: .filesAllowRoots)
        try container.encode(filesRequireApprovalOnDeny, forKey: .filesRequireApprovalOnDeny)
        try container.encode(filesWriteMode, forKey: .filesWriteMode)
        try container.encode(filesWritePathRules, forKey: .filesWritePathRules)
        try container.encode(browserSearxngURL, forKey: .browserSearxngURL)
        try container.encode(browserSearchTimeoutSeconds, forKey: .browserSearchTimeoutSeconds)
        try container.encode(browserMaxResults, forKey: .browserMaxResults)
        try container.encode(browserTimeoutSeconds, forKey: .browserTimeoutSeconds)
        try container.encode(browserFetchTimeoutSeconds, forKey: .browserFetchTimeoutSeconds)
        try container.encode(searchSearxngURL, forKey: .searchSearxngURL)
        try container.encode(searchTimeoutSeconds, forKey: .searchTimeoutSeconds)
        try container.encode(searchMaxResults, forKey: .searchMaxResults)
        try container.encode(emailAccounts, forKey: .emailAccounts)
        try container.encode(pluginsDir, forKey: .pluginsDir)
        try container.encode(pluginsMarketplaceIndexURL, forKey: .pluginsMarketplaceIndexURL)
        try container.encode(pluginsAutoRescan, forKey: .pluginsAutoRescan)
        try container.encode(media, forKey: .media)
        try container.encode(index, forKey: .index)
        try container.encode(desktop, forKey: .desktop)
        try container.encode(bash, forKey: .bash)
        try container.encode(workspace, forKey: .workspace)
        try container.encode(goals, forKey: .goals)
        try container.encode(proactive, forKey: .proactive)
        try container.encode(ideas, forKey: .ideas)
        try container.encode(fanout, forKey: .fanout)
        try container.encode(persona, forKey: .persona)
        try container.encode(serverHostname, forKey: .serverHostname)
        try container.encode(serverPort, forKey: .serverPort)
        try container.encode(serverAllowedHosts, forKey: .serverAllowedHosts)
        try container.encode(configPath, forKey: .configPath)
        try container.encode(requiresRestart, forKey: .requiresRestart)
    }
}

/// Request payload to update settings via `PUT /settings`.
/// Accepts both `browser*` (canonical) and `search*` (dashboard alias) keys;
/// the canonical key wins when both are present so either contract writes.
public struct UpdateSettingsRequest: Content, Equatable {
    public let engineName: String?
    public let logLevel: String?
    public let compactionThresholdPercent: Int?
    public let maxToolIterations: Int?
    public let defaultProvider: String?
    public let fallbackProvider: String?
    public let providers: [String: ProviderConfig]?
    public let memoryVectorDBPath: String?
    public let memoryEpisodesDBPath: String?
    public let memoryEmbeddingModel: String?
    public let memoryEmbeddingBackend: String?
    /// Per-tier fetch cap override for `[memory] recall_per_tier_limit`. Nil preserves the stored value.
    public let memoryRecallPerTierLimit: Int?
    /// Auto-injection cap override for `[memory] recall_auto_limit`. Nil preserves the stored value.
    public let memoryRecallAutoLimit: Int?
    /// Score floor override for `[memory] recall_threshold`. Nil preserves the stored value.
    public let memoryRecallThreshold: Double?
    /// Recall block budget override for `[memory] recall_max_chars`. Nil preserves the stored value.
    public let memoryRecallMaxChars: Int?
    /// Per-hit truncation override for `[memory] recall_per_hit_chars`. Nil preserves the stored value.
    public let memoryRecallPerHitChars: Int?
    /// Document pool widening override for `[memory] recall_doc_pool_multiplier`. Nil preserves the stored value.
    public let memoryRecallDocPoolMultiplier: Int?
    /// Episodic tier weight override for `[memory] recall_episodic_weight`. Nil preserves the stored value.
    public let memoryRecallEpisodicWeight: Double?
    public let voiceSTTProvider: String?
    public let voiceWhisperModel: String?
    public let voiceTTSProvider: String?
    /// Partial containers patch; a nil patch preserves the stored `[containers]` section.
    public let containers: ContainersSettingsUpdate?
    public let filesDenyPatterns: [String]?
    public let filesAllowRoots: [String]?
    public let filesRequireApprovalOnDeny: Bool?
    /// Forced `files.write` posture override (`model`, `staged`, or `live`). Nil preserves the stored value.
    public let filesWriteMode: String?
    /// Per-path write posture patch for `[files] write_path_rules`. A present
    /// list replaces the stored rules wholesale, including an explicit empty
    /// one that opts every path out; nil preserves the stored entries.
    public let filesWritePathRules: [FilesWritePathRule]?
    public let browserSearxngURL: String?
    public let browserSearchTimeoutSeconds: Int?
    public let browserMaxResults: Int?
    public let browserTimeoutSeconds: Int?
    public let browserFetchTimeoutSeconds: Int?
    public let searchSearxngURL: String?
    public let searchTimeoutSeconds: Int?
    public let searchMaxResults: Int?
    public let emailAccounts: [EmailAccount]?
    public let pluginsDir: String?
    public let pluginsMarketplaceIndexURL: String?
    public let pluginsAutoRescan: Bool?
    public let media: MediaSettingsUpdate?
    /// Partial local index patch; a nil patch preserves the stored `[index]` section.
    public let index: IndexSettingsUpdate?
    /// Partial desktop patch; a nil patch preserves the stored `[desktop]` section.
    public let desktop: DesktopSettingsUpdate?
    /// Partial bash patch; a nil patch preserves the stored `[bash]` section.
    public let bash: BashSettingsUpdate?
    /// Partial workspace patch; a nil patch preserves the stored `[workspace]` section.
    public let workspace: WorkspaceUpdate?
    /// Partial goals patch; a nil patch preserves the stored `[goals]` section.
    public let goals: GoalsUpdate?
    /// Partial proactive patch; a nil patch preserves the stored `[proactive]` section.
    public let proactive: ProactiveUpdate?
    /// Partial ideas patch; a nil patch preserves the stored `[ideas]` section.
    public let ideas: IdeasUpdate?
    /// Partial fan-out patch; a nil patch preserves the stored `[fanout]` section.
    public let fanout: FanOutSettingsUpdate?
    /// Partial persona patch; a nil patch preserves the stored `[persona]` section.
    public let persona: PersonaUpdate?
    /// Bind interface override for `[server] hostname`. Nil preserves the stored value.
    public let serverHostname: String?
    /// Bind port override for `[server] port`. Nil preserves the stored value.
    public let serverPort: Int?
    /// Exact-only extra Host entries for `[server] allowed_hosts`. Nil preserves the stored value.
    public let serverAllowedHosts: [String]?

    public init(
        engineName: String? = nil,
        logLevel: String? = nil,
        compactionThresholdPercent: Int? = nil,
        maxToolIterations: Int? = nil,
        defaultProvider: String? = nil,
        fallbackProvider: String? = nil,
        providers: [String: ProviderConfig]? = nil,
        memoryVectorDBPath: String? = nil,
        memoryEpisodesDBPath: String? = nil,
        memoryEmbeddingModel: String? = nil,
        memoryEmbeddingBackend: String? = nil,
        memoryRecallPerTierLimit: Int? = nil,
        memoryRecallAutoLimit: Int? = nil,
        memoryRecallThreshold: Double? = nil,
        memoryRecallMaxChars: Int? = nil,
        memoryRecallPerHitChars: Int? = nil,
        memoryRecallDocPoolMultiplier: Int? = nil,
        memoryRecallEpisodicWeight: Double? = nil,
        voiceSTTProvider: String? = nil,
        voiceWhisperModel: String? = nil,
        voiceTTSProvider: String? = nil,
        containers: ContainersSettingsUpdate? = nil,
        filesDenyPatterns: [String]? = nil,
        filesAllowRoots: [String]? = nil,
        filesRequireApprovalOnDeny: Bool? = nil,
        filesWriteMode: String? = nil,
        filesWritePathRules: [FilesWritePathRule]? = nil,
        browserSearxngURL: String? = nil,
        browserSearchTimeoutSeconds: Int? = nil,
        browserMaxResults: Int? = nil,
        browserTimeoutSeconds: Int? = nil,
        browserFetchTimeoutSeconds: Int? = nil,
        searchSearxngURL: String? = nil,
        searchTimeoutSeconds: Int? = nil,
        searchMaxResults: Int? = nil,
        emailAccounts: [EmailAccount]? = nil,
        pluginsDir: String? = nil,
        pluginsMarketplaceIndexURL: String? = nil,
        pluginsAutoRescan: Bool? = nil,
        media: MediaSettingsUpdate? = nil,
        index: IndexSettingsUpdate? = nil,
        desktop: DesktopSettingsUpdate? = nil,
        bash: BashSettingsUpdate? = nil,
        workspace: WorkspaceUpdate? = nil,
        goals: GoalsUpdate? = nil,
        proactive: ProactiveUpdate? = nil,
        ideas: IdeasUpdate? = nil,
        fanout: FanOutSettingsUpdate? = nil,
        persona: PersonaUpdate? = nil,
        serverHostname: String? = nil,
        serverPort: Int? = nil,
        serverAllowedHosts: [String]? = nil
    ) {
        self.engineName = engineName
        self.logLevel = logLevel
        self.compactionThresholdPercent = compactionThresholdPercent
        self.maxToolIterations = maxToolIterations
        self.defaultProvider = defaultProvider
        self.fallbackProvider = fallbackProvider
        self.providers = providers
        self.memoryVectorDBPath = memoryVectorDBPath
        self.memoryEpisodesDBPath = memoryEpisodesDBPath
        self.memoryEmbeddingModel = memoryEmbeddingModel
        self.memoryEmbeddingBackend = memoryEmbeddingBackend
        self.memoryRecallPerTierLimit = memoryRecallPerTierLimit
        self.memoryRecallAutoLimit = memoryRecallAutoLimit
        self.memoryRecallThreshold = memoryRecallThreshold
        self.memoryRecallMaxChars = memoryRecallMaxChars
        self.memoryRecallPerHitChars = memoryRecallPerHitChars
        self.memoryRecallDocPoolMultiplier = memoryRecallDocPoolMultiplier
        self.memoryRecallEpisodicWeight = memoryRecallEpisodicWeight
        self.voiceSTTProvider = voiceSTTProvider
        self.voiceWhisperModel = voiceWhisperModel
        self.voiceTTSProvider = voiceTTSProvider
        self.containers = containers
        self.filesDenyPatterns = filesDenyPatterns
        self.filesAllowRoots = filesAllowRoots
        self.filesRequireApprovalOnDeny = filesRequireApprovalOnDeny
        self.filesWriteMode = filesWriteMode
        self.filesWritePathRules = filesWritePathRules
        self.browserSearxngURL = browserSearxngURL
        self.browserSearchTimeoutSeconds = browserSearchTimeoutSeconds
        self.browserMaxResults = browserMaxResults
        self.browserTimeoutSeconds = browserTimeoutSeconds
        self.browserFetchTimeoutSeconds = browserFetchTimeoutSeconds
        self.searchSearxngURL = searchSearxngURL
        self.searchTimeoutSeconds = searchTimeoutSeconds
        self.searchMaxResults = searchMaxResults
        self.emailAccounts = emailAccounts
        self.pluginsDir = pluginsDir
        self.pluginsMarketplaceIndexURL = pluginsMarketplaceIndexURL
        self.pluginsAutoRescan = pluginsAutoRescan
        self.media = media
        self.index = index
        self.desktop = desktop
        self.bash = bash
        self.workspace = workspace
        self.goals = goals
        self.proactive = proactive
        self.ideas = ideas
        self.fanout = fanout
        self.persona = persona
        self.serverHostname = serverHostname
        self.serverPort = serverPort
        self.serverAllowedHosts = serverAllowedHosts
    }

    private enum CodingKeys: String, CodingKey {
        case engineName, logLevel, compactionThresholdPercent, maxToolIterations
        case defaultProvider, fallbackProvider, providers
        case memoryVectorDBPath, memoryEpisodesDBPath, memoryEmbeddingModel, memoryEmbeddingBackend
        case memoryRecallPerTierLimit, memoryRecallAutoLimit, memoryRecallThreshold
        case memoryRecallMaxChars, memoryRecallPerHitChars, memoryRecallDocPoolMultiplier, memoryRecallEpisodicWeight
        case voiceSTTProvider, voiceWhisperModel, voiceTTSProvider
        case containers
        case filesDenyPatterns, filesAllowRoots, filesRequireApprovalOnDeny, filesWriteMode
        case filesWritePathRules
        case browserSearxngURL, browserSearchTimeoutSeconds, browserMaxResults
        case browserTimeoutSeconds, browserFetchTimeoutSeconds
        case searchSearxngURL, searchTimeoutSeconds, searchMaxResults
        case emailAccounts, pluginsDir, pluginsMarketplaceIndexURL, pluginsAutoRescan
        case media, index, desktop, bash, workspace, goals, proactive, ideas, fanout, persona
        case serverHostname, serverPort, serverAllowedHosts
    }

    /// Decodes tolerantly so every key stays optional and unknown keys are
    /// ignored. The containers bounds ride the nested object so a missing
    /// section preserves the stored policy.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        engineName = try container.decodeIfPresent(String.self, forKey: .engineName)
        logLevel = try container.decodeIfPresent(String.self, forKey: .logLevel)
        compactionThresholdPercent = try container.decodeIfPresent(Int.self, forKey: .compactionThresholdPercent)
        maxToolIterations = try container.decodeIfPresent(Int.self, forKey: .maxToolIterations)
        defaultProvider = try container.decodeIfPresent(String.self, forKey: .defaultProvider)
        fallbackProvider = try container.decodeIfPresent(String.self, forKey: .fallbackProvider)
        providers = try container.decodeIfPresent([String: ProviderConfig].self, forKey: .providers)
        memoryVectorDBPath = try container.decodeIfPresent(String.self, forKey: .memoryVectorDBPath)
        memoryEpisodesDBPath = try container.decodeIfPresent(String.self, forKey: .memoryEpisodesDBPath)
        memoryEmbeddingModel = try container.decodeIfPresent(String.self, forKey: .memoryEmbeddingModel)
        memoryEmbeddingBackend = try container.decodeIfPresent(String.self, forKey: .memoryEmbeddingBackend)
        memoryRecallPerTierLimit = try container.decodeIfPresent(Int.self, forKey: .memoryRecallPerTierLimit)
        memoryRecallAutoLimit = try container.decodeIfPresent(Int.self, forKey: .memoryRecallAutoLimit)
        memoryRecallThreshold = try container.decodeIfPresent(Double.self, forKey: .memoryRecallThreshold)
        memoryRecallMaxChars = try container.decodeIfPresent(Int.self, forKey: .memoryRecallMaxChars)
        memoryRecallPerHitChars = try container.decodeIfPresent(Int.self, forKey: .memoryRecallPerHitChars)
        memoryRecallDocPoolMultiplier = try container.decodeIfPresent(Int.self, forKey: .memoryRecallDocPoolMultiplier)
        memoryRecallEpisodicWeight = try container.decodeIfPresent(Double.self, forKey: .memoryRecallEpisodicWeight)
        voiceSTTProvider = try container.decodeIfPresent(String.self, forKey: .voiceSTTProvider)
        voiceWhisperModel = try container.decodeIfPresent(String.self, forKey: .voiceWhisperModel)
        voiceTTSProvider = try container.decodeIfPresent(String.self, forKey: .voiceTTSProvider)
        containers = try container.decodeIfPresent(ContainersSettingsUpdate.self, forKey: .containers)
        filesDenyPatterns = try container.decodeIfPresent([String].self, forKey: .filesDenyPatterns)
        filesAllowRoots = try container.decodeIfPresent([String].self, forKey: .filesAllowRoots)
        filesRequireApprovalOnDeny = try container.decodeIfPresent(Bool.self, forKey: .filesRequireApprovalOnDeny)
        filesWriteMode = try container.decodeIfPresent(String.self, forKey: .filesWriteMode)
        // A closed-set posture fails the strict decode here, so a typo stays a
        // caller 400 naming the entry rather than silently defaulting it.
        filesWritePathRules = try container.decodeIfPresent([FilesWritePathRule].self, forKey: .filesWritePathRules)
        browserSearxngURL = try container.decodeIfPresent(String.self, forKey: .browserSearxngURL)
        browserSearchTimeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .browserSearchTimeoutSeconds)
        browserMaxResults = try container.decodeIfPresent(Int.self, forKey: .browserMaxResults)
        browserTimeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .browserTimeoutSeconds)
        browserFetchTimeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .browserFetchTimeoutSeconds)
        searchSearxngURL = try container.decodeIfPresent(String.self, forKey: .searchSearxngURL)
        searchTimeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .searchTimeoutSeconds)
        searchMaxResults = try container.decodeIfPresent(Int.self, forKey: .searchMaxResults)
        emailAccounts = try container.decodeIfPresent([EmailAccount].self, forKey: .emailAccounts)
        pluginsDir = try container.decodeIfPresent(String.self, forKey: .pluginsDir)
        pluginsMarketplaceIndexURL = try container.decodeIfPresent(String.self, forKey: .pluginsMarketplaceIndexURL)
        pluginsAutoRescan = try container.decodeIfPresent(Bool.self, forKey: .pluginsAutoRescan)
        media = try container.decodeIfPresent(MediaSettingsUpdate.self, forKey: .media)
        index = try container.decodeIfPresent(IndexSettingsUpdate.self, forKey: .index)
        desktop = try container.decodeIfPresent(DesktopSettingsUpdate.self, forKey: .desktop)
        bash = try container.decodeIfPresent(BashSettingsUpdate.self, forKey: .bash)
        workspace = try container.decodeIfPresent(WorkspaceUpdate.self, forKey: .workspace)
        goals = try container.decodeIfPresent(GoalsUpdate.self, forKey: .goals)
        proactive = try container.decodeIfPresent(ProactiveUpdate.self, forKey: .proactive)
        ideas = try container.decodeIfPresent(IdeasUpdate.self, forKey: .ideas)
        fanout = try container.decodeIfPresent(FanOutSettingsUpdate.self, forKey: .fanout)
        persona = try container.decodeIfPresent(PersonaUpdate.self, forKey: .persona)
        serverHostname = try container.decodeIfPresent(String.self, forKey: .serverHostname)
        serverPort = try container.decodeIfPresent(Int.self, forKey: .serverPort)
        serverAllowedHosts = try container.decodeIfPresent([String].self, forKey: .serverAllowedHosts)
    }
}

/// Partial `[containers]` patch for `PUT /settings`.
///
/// Every field stays optional so a request carrying only one key leaves the
/// rest of the stored admission bounds untouched instead of resetting them.
/// Covers the same field set as the full `ContainersConfig` snapshot, so a
/// caller holding a complete policy can build the patch through `init(_:)` and
/// reuse the merge path without hand-mapping fields.
public struct ContainersSettingsUpdate: Content, Equatable {
    /// Guest memory cap in MB. Nil preserves the stored value.
    public var memoryMB: Int?
    /// Maximum concurrent containers. Nil preserves the stored value.
    public var maxConcurrent: Int?
    /// Idle TTL in minutes. Nil preserves the stored value.
    public var ttlMinutes: Int?

    /// Creates a partial containers patch.
    /// - Parameters:
    ///   - memoryMB: Guest memory cap in MB.
    ///   - maxConcurrent: Maximum concurrent containers.
    ///   - ttlMinutes: Idle TTL in minutes.
    public init(
        memoryMB: Int? = nil,
        maxConcurrent: Int? = nil,
        ttlMinutes: Int? = nil
    ) {
        self.memoryMB = memoryMB
        self.maxConcurrent = maxConcurrent
        self.ttlMinutes = ttlMinutes
    }

    /// Populates a patch from a full snapshot so programmatic callers holding
    /// a complete `ContainersConfig` reuse the same merge path.
    /// - Parameter containers: Complete containers policy.
    public init(_ containers: ContainersConfig) {
        self.memoryMB = containers.memoryMB
        self.maxConcurrent = containers.maxConcurrent
        self.ttlMinutes = containers.ttlMinutes
    }

    private enum CodingKeys: String, CodingKey {
        case memoryMB = "memoryMb"
        case maxConcurrent
        case ttlMinutes
    }

    /// Merges this patch onto the stored policy, preserving every field the
    /// request omits. A nil field is a no-op, so a dashboard edit to one knob
    /// never resets the rest of the `[containers]` section.
    /// - Parameter containers: Stored containers policy to mutate in place.
    public func apply(to containers: inout ContainersConfig) throws {
        if let memoryMB {
            containers.memoryMB = try Self.validatedBound(memoryMB, field: "containers.memory_mb")
        }
        if let maxConcurrent {
            containers.maxConcurrent = try Self.validatedBound(maxConcurrent, field: "containers.max_concurrent")
        }
        if let ttlMinutes {
            containers.ttlMinutes = try Self.validatedBound(ttlMinutes, field: "containers.ttl_minutes")
        }
    }

    /// Validates one containers bound against the documented range so
    /// mistyped values fail fast with the offending field.
    private static func validatedBound(_ value: Int, field: String) throws -> Int {
        let bounds: (min: Int, max: Int) = switch field {
        case "containers.memory_mb":
            (ContainersConfig.minMemoryMB, ContainersConfig.maxMemoryMB)
        case "containers.max_concurrent":
            (ContainersConfig.minMaxConcurrent, ContainersConfig.maxMaxConcurrent)
        case "containers.ttl_minutes":
            (ContainersConfig.minTTLMinutes, ContainersConfig.maxTTLMinutes)
        default:
            (1, Int.max)
        }
        guard value >= bounds.min, value <= bounds.max else {
            throw ConfigError.validationError(
                field: field,
                message: "must be between \(bounds.min) and \(bounds.max) (got \(value))"
            )
        }
        return value
    }
}

extension UpdateSettingsRequest {
    /// Builds a request from a full containers snapshot, routing through the same
    /// merge path so snapshot callers keep working without hand-mapping fields.
    /// - Parameter containers: Complete containers policy.
    public init(containers: ContainersConfig) {
        self.init(containers: ContainersSettingsUpdate(containers))
    }
}

/// Configuration application methods for `UpdateSettingsRequest`.
///
/// Kept in an extension so the request struct body stays within the type
/// length budget.
extension UpdateSettingsRequest {
    /// Applies this update onto a loaded config, preserving every field
    /// the request omits.
    public func apply(to config: inout RuneWeaverConfig) throws {
        try applyEngine(to: &config.engine)
        applyLLM(to: &config.llm)
        applyMemory(to: &config.memory)
        try applyMemoryEmbeddingBackend(to: &config.memory)
        applyVoice(to: &config.voice)
        try applyContainers(to: &config.containers)
        try applyFiles(to: &config.files)
        applyBrowser(to: &config.browser)
        applyEmail(to: &config.email)
        applyPlugins(to: &config.plugins)
        applyMedia(to: &config.media)
        applyIndex(to: &config.index)
        applyDesktop(to: &config.desktop)
        try applyBash(to: &config.bash)
        try applyWorkspace(to: &config.workspace)
        applyGoals(to: &config.goals)
        try applyProactive(to: &config.proactive)
        applyIdeas(to: &config.ideas)
        applyFanOut(to: &config.fanOut)
        try applyPersona(to: &config.persona)
        try applyServer(to: &config.server)
    }

    private func applyEngine(to engine: inout EngineConfig) throws {
        if let engineName {
            engine.name = engineName
        }
        if let logLevel {
            engine.logLevel = logLevel
        }
        if let compactionThresholdPercent {
            engine.compactionThresholdPercent = compactionThresholdPercent
        }
        if let maxToolIterations {
            // Reject out-of-range budgets here so invalid values never persist
            // or reach the live orchestrator through the settings route.
            guard (1 ... 100).contains(maxToolIterations) else {
                throw ConfigError.validationError(
                    field: "engine.max_tool_iterations",
                    message: "must be between 1 and 100 (got \(maxToolIterations))"
                )
            }
            engine.maxToolIterations = maxToolIterations
        }
    }

    private func applyLLM(to llm: inout LLMConfig) {
        if let defaultProvider {
            llm.defaultProvider = defaultProvider
        }
        if let fallbackProvider {
            llm.fallbackProvider = fallbackProvider.isEmpty ? nil : fallbackProvider
        }
        if let providers {
            llm.providers = providers
        }
    }

    private func applyMemory(to memory: inout MemoryConfig) {
        if let memoryVectorDBPath {
            memory.vectorDBPath = memoryVectorDBPath
        }
        if let memoryEpisodesDBPath {
            memory.episodesDBPath = memoryEpisodesDBPath
        }
        if let memoryEmbeddingModel {
            memory.embeddingModel = memoryEmbeddingModel
        }
        // Recall budgets merge field-by-field so a dashboard edit to one knob
        // never resets the rest of the `[memory] recall_*` section, then clamp
        // into the documented ranges so the persisted file mirrors the live
        // engine contract even if a caller passes an edge value — fail-open
        // like file-load (`decodeMemory`), never a save refusal. A save
        // without recall keys is a no-op and preserves the stored budgets
        // verbatim. Validation documents this posture; live paths clamp again
        // at use via `RecallBudgets.clamped()`.
        if let memoryRecallPerTierLimit {
            memory.recallBudgets.perTierLimit = memoryRecallPerTierLimit
        }
        if let memoryRecallAutoLimit {
            memory.recallBudgets.autoLimit = memoryRecallAutoLimit
        }
        if let memoryRecallThreshold {
            memory.recallBudgets.threshold = memoryRecallThreshold
        }
        if let memoryRecallMaxChars {
            memory.recallBudgets.maxChars = memoryRecallMaxChars
        }
        if let memoryRecallPerHitChars {
            memory.recallBudgets.perHitChars = memoryRecallPerHitChars
        }
        if let memoryRecallDocPoolMultiplier {
            memory.recallBudgets.docPoolMultiplier = memoryRecallDocPoolMultiplier
        }
        if let memoryRecallEpisodicWeight {
            memory.recallBudgets.episodicWeight = memoryRecallEpisodicWeight
        }
        if carriesRecallPatch {
            memory.recallBudgets = memory.recallBudgets.clamped()
        }
    }

    private func applyMemoryEmbeddingBackend(to memory: inout MemoryConfig) throws {
        guard let memoryEmbeddingBackend else { return }
        let allowedBackends = MemoryConfig.allowedEmbeddingBackends
        guard allowedBackends.contains(memoryEmbeddingBackend) else {
            throw ConfigError.validationError(
                field: "memory.embedding_backend",
                message: "must be one of \(allowedBackends.joined(separator: ", ")) (got '\(memoryEmbeddingBackend)')"
            )
        }
        memory.embeddingBackend = memoryEmbeddingBackend
    }

    private func applyVoice(to voice: inout VoiceConfig) {
        if let voiceSTTProvider {
            voice.sttProvider = voiceSTTProvider
        }
        if let voiceWhisperModel {
            voice.whisperModel = voiceWhisperModel
        }
        if let voiceTTSProvider {
            voice.ttsProvider = voiceTTSProvider
        }
    }

    /// Merges a partial containers patch onto the stored policy, preserving every
    /// field the request omits. A nil patch is a no-op, so a dashboard edit
    /// elsewhere never resets the `[containers]` section. Validation stays
    /// single-sourced in `ContainersSettingsUpdate.apply(to:)` so the PUT and
    /// direct-merge paths agree with a clear 400 instead of persisting bad values.
    ///
    /// Internal so the shared settings `apply(to:)` keeps one merge path while
    /// the containers-specific logic lives beside its DTO.
    func applyContainers(to containers: inout ContainersConfig) throws {
        guard let update = self.containers else { return }
        try update.apply(to: &containers)
    }

    private func applyFiles(to files: inout FilesConfig) throws {
        if let filesDenyPatterns {
            try RuneWeaverConfig.validateFilesPatterns(filesDenyPatterns, field: "files.deny_patterns")
            files.denyPatterns = filesDenyPatterns
        }
        if let filesAllowRoots {
            try RuneWeaverConfig.validateFilesPatterns(filesAllowRoots, field: "files.allow_roots")
            files.allowRoots = filesAllowRoots
        }
        if let filesRequireApprovalOnDeny {
            files.requireApprovalOnDeny = filesRequireApprovalOnDeny
        }
        if let filesWriteMode {
            // Single-sourced through the core validator so the route's 400 and
            // the TOML load path agree on accepted spellings and message; a bad
            // value throws before the merge reaches the persisted file.
            files.writeMode = try RuneWeaverConfig.validateFilesWriteMode(filesWriteMode)
        }
        if let filesWritePathRules {
            // The list and each path stay bounded exactly as the config
            // document bounds them, so a settings PUT refuses a policy the
            // TOML load would refuse instead of persisting an unbounded rule
            // set the write-path classifier would have to fan out over.
            files.writePathRules = try Self.validatedWritePathRules(filesWritePathRules)
        }
    }

    /// Validates one `write_path_rules` patch against the bounds the config
    /// document enforces.
    ///
    /// Mirrors `FilesWritePathRule.maxRuleCount` and
    /// `FilesWritePathRule.maxPathLength` so the PUT path and the file-load
    /// path refuse the same list with the same field and message; paths store
    /// trimmed so a padded entry never reads as a longer prefix than it names.
    /// - Parameter rules: Raw rules from the request.
    /// - Returns: The validated rules in stored spelling.
    /// - Throws: `ConfigError.validationError` on an over-long list, a blank
    ///   path, or an over-bound path.
    private static func validatedWritePathRules(_ rules: [FilesWritePathRule]) throws -> [FilesWritePathRule] {
        guard rules.count <= FilesWritePathRule.maxRuleCount else {
            throw ConfigError.validationError(
                field: "files.write_paths",
                message: "must contain at most \(FilesWritePathRule.maxRuleCount) entries (got \(rules.count))"
            )
        }
        var validated: [FilesWritePathRule] = []
        validated.reserveCapacity(rules.count)
        for rule in rules {
            let trimmedPath = rule.path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedPath.isEmpty else {
                throw ConfigError.validationError(field: "files.write_paths.path", message: "must not be empty")
            }
            guard trimmedPath.count <= FilesWritePathRule.maxPathLength else {
                throw ConfigError.validationError(
                    field: "files.write_paths.path",
                    message: "must be at most \(FilesWritePathRule.maxPathLength) characters (got \(trimmedPath.count))"
                )
            }
            validated.append(FilesWritePathRule(path: trimmedPath, posture: rule.posture))
        }
        return validated
    }

    private func applyBrowser(to browser: inout BrowserConfig) {
        if let browserSearxngURL = browserSearxngURL ?? searchSearxngURL {
            browser.searxngURL = browserSearxngURL
        }
        if let browserSearchTimeoutSeconds = browserSearchTimeoutSeconds ?? searchTimeoutSeconds {
            browser.searchTimeoutSeconds = browserSearchTimeoutSeconds
        }
        if let browserMaxResults = browserMaxResults ?? searchMaxResults {
            browser.maxResults = browserMaxResults
        }
        if let browserTimeoutSeconds {
            browser.timeoutSeconds = browserTimeoutSeconds
        }
        if let browserFetchTimeoutSeconds {
            browser.fetchTimeoutSeconds = browserFetchTimeoutSeconds
        }
    }

    private func applyEmail(to email: inout EmailConfig) {
        if let emailAccounts {
            email.accounts = emailAccounts
        }
    }

    private func applyPlugins(to plugins: inout PluginConfig) {
        if let pluginsDir {
            plugins.pluginsDir = pluginsDir
        }
        if let pluginsMarketplaceIndexURL {
            plugins.marketplaceIndexURL = pluginsMarketplaceIndexURL
        }
        if let pluginsAutoRescan {
            plugins.autoRescan = pluginsAutoRescan
        }
    }

    /// Applies the `[server]` bind patch, preserving every key the request omits.
    /// A nil patch is a no-op, while a present patch writes verbatim after
    /// fail-closed checks so invalid values never persist or reach the live
    /// bind. Hostname validation is
    /// single-sourced through `RuneWeaverConfig.validateServerHostname` so the
    /// PUT and file-load paths agree with a clear 400 instead of a spurious
    /// 403 or an obscure bind failure.
    private func applyServer(to server: inout ServerEndpointConfig) throws {
        if let serverHostname {
            // Validates the exact-host shape (scheme, wildcard, slash,
            // userinfo, query, fragment, whitespace, controls,
            // normalized-empty, and `:port` for non-IPv6) before storing so
            // `http://evil` and sibling shapes never reach the file.
            try RuneWeaverConfig.validateServerHostname(serverHostname)
            server.hostname = serverHostname.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let serverPort {
            guard (1 ... 65535).contains(serverPort) else {
                throw ConfigError.validationError(
                    field: "server.port",
                    message: "must be between 1 and 65535 (got \(serverPort))"
                )
            }
            server.port = serverPort
        }
        if let serverAllowedHosts {
            // Validate the raw entries before port stripping hides a widening
            // shape: stripping first would carve `http` from `http://evil.com`
            // and let a scheme slip through as an exact host. This raw check
            // carries the only count bound (`maxAllowedHosts` on the supplied
            // entries): the deduped form can legitimately hold more entries
            // because each IPv6 literal stores both its bracketed and bare
            // spellings, so 11 IPv6 entries store as 22 without throwing.
            try RuneWeaverConfig.validateAllowedHosts(serverAllowedHosts)
            // Single-sourced through `dedupeNormalizedHosts` so file-load, the
            // PUT, the health snapshot, and the Host gate store identically.
            let deduped = ServerEndpointConfig.dedupeNormalizedHosts(serverAllowedHosts)
            for entry in deduped {
                guard !entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ConfigError.validationError(field: "server.allowed_hosts", message: "must not contain empty strings")
                }
            }
            server.allowedHosts = deduped
        }
    }
}

/// Request flags and hostname helpers for `UpdateSettingsRequest`.
///
/// Kept in an extension so the request struct body stays within the type
/// length budget; the route reads these without touching the stored patch.
extension UpdateSettingsRequest {
    /// Whether this request carries any bind-affecting `[server]` key.
    /// The settings route uses this to mark `requiresRestart` without
    /// live-reloading the socket or the middleware set.
    public var carriesServerPatch: Bool {
        serverHostname != nil || serverPort != nil || serverAllowedHosts != nil
    }

    /// Whether this request carries any `[memory] recall_*` budget key.
    /// The settings route uses this to push the merged budgets into the live
    /// orchestrator without a restart; a save without recall keys leaves the
    /// live engine untouched.
    public var carriesRecallPatch: Bool {
        memoryRecallPerTierLimit != nil || memoryRecallAutoLimit != nil || memoryRecallThreshold != nil
            || memoryRecallMaxChars != nil || memoryRecallPerHitChars != nil
            || memoryRecallDocPoolMultiplier != nil || memoryRecallEpisodicWeight != nil
    }

    /// Whether this request carries any `[files]` key, including the per-path
    /// write rules. The settings route uses this to apply the saved policy to
    /// the live gate and rebuild the file tools without a restart.
    public var carriesFilesPatch: Bool {
        filesDenyPatterns != nil || filesAllowRoots != nil || filesRequireApprovalOnDeny != nil
            || filesWriteMode != nil || filesWritePathRules != nil
    }

    /// Whether a hostname binds loopback only. Non-loopback binds need a
    /// resolvable owner token and fail closed otherwise. Single-sourced through
    /// `ServerConfig.isLoopbackHostname` so a hostname that saves as loopback
    /// also boots as loopback.
    public static func isLoopbackHostname(_ hostname: String) -> Bool {
        ServerConfig.isLoopbackHostname(hostname)
    }

    /// Normalizes one `allowed_hosts` entry to the compared Host form.
    /// Single-sourced through `ServerEndpointConfig.normalizeHost` in Core so
    /// the stored allowlist and the request gate trim, lowercase, and strip
    /// ports identically; a stored entry that matches at save time matches at
    /// gate time. Callers validate before and after so widening shapes never
    /// hide behind the strip.
    /// - Parameter entry: Raw configured entry.
    /// - Returns: Lowercased, port-stripped host.
    static func normalizedAllowedHost(_ entry: String) -> String {
        ServerEndpointConfig.normalizeHost(entry)
    }
}

/// Payload for storing a credential in the Keychain.
public struct StoreSecretRequest: Content, Sendable, Equatable {
    public let key: String
    public let secret: String

    public init(key: String, secret: String) {
        self.key = key
        self.secret = secret
    }
}

/// Request to query existence of secrets in Keychain/environment without returning secret bytes.
public struct SecretStatusRequest: Content, Sendable, Equatable {
    public let keys: [String]

    public init(keys: [String]) {
        self.keys = keys
    }
}

/// Response containing existence map of secrets.
public struct SecretStatusResponse: Content, Sendable, Equatable {
    public let status: [String: Bool]

    public init(status: [String: Bool]) {
        self.status = status
    }
}

/// Response carrying sorted secret key names without values.
public struct SecretListResponse: Content, Sendable, Equatable {
    public let keys: [String]

    public init(keys: [String]) {
        self.keys = keys
    }
}

// Rune Weaver Core — Configuration types and loader for config.toml.
import Foundation

/// Errors thrown while loading or validating `config.toml`.
public enum ConfigError: Error, Sendable, Equatable {
    /// The config file does not exist at the expected path.
    case fileNotFound(path: String)
    /// The file exists but could not be read or decoded as UTF-8.
    case unreadable(path: String, reason: String)
    /// A TOML syntax problem.
    case parseError(line: Int, message: String)
    /// A required field is absent.
    /// - Parameter field: Dotted field path (e.g. `llm.default_provider`).
    case missingRequired(field: String)
    /// A field value failed validation.
    case validationError(field: String, message: String)
}

// MARK: - Section structs

/// `[engine]` — top-level engine identity, logging, and context management.
public struct EngineConfig: Sendable, Codable, Equatable {
    /// Human-readable engine name shown in clients.
    public var name: String
    /// Log level: trace, debug, info, notice, warning, error, or critical.
    public var logLevel: String
    /// Context compaction threshold percentage (10-100). Default is 80%.
    public var compactionThresholdPercent: Int
    /// Maximum tool loop iterations before requesting continuation approval (1-100). Default is 10.
    public var maxToolIterations: Int

    /// Creates an engine config.
    public init(name: String = "Rune Weaver", logLevel: String = "info", compactionThresholdPercent: Int = 80, maxToolIterations: Int = 10) {
        self.name = name
        self.logLevel = logLevel
        self.compactionThresholdPercent = compactionThresholdPercent
        self.maxToolIterations = maxToolIterations
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case logLevel = "log_level"
        case compactionThresholdPercent = "compaction_threshold_percent"
        case maxToolIterations = "max_tool_iterations"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Rune Weaver"
        self.logLevel = try container.decodeIfPresent(String.self, forKey: .logLevel) ?? "info"
        self.compactionThresholdPercent = try container.decodeIfPresent(Int.self, forKey: .compactionThresholdPercent) ?? 80
        self.maxToolIterations = try container.decodeIfPresent(Int.self, forKey: .maxToolIterations) ?? 10
    }
}

// MARK: - Server endpoint & owner auth

/// `[server]` — HTTP API bind endpoint for the engine service.
///
/// Distinct from `RuneWeaverServer.ServerConfig`, which carries the runtime
/// bind policy and resolves auth; this is the file-facing shape only. Keeping
/// the names apart avoids an ambiguous `ServerConfig` when a module imports
/// both `RuneWeaverCore` and `RuneWeaverServer`.
public struct ServerEndpointConfig: Sendable, Codable, Equatable {
    /// Default loopback hostname; the v1 service is localhost-only.
    public static let defaultHostname = "127.0.0.1"
    /// Default engine API port, chosen to avoid MLX (8080) and llama.cpp (8081).
    public static let defaultPort = 8082

    /// Interface the service binds.
    public var hostname: String
    /// TCP port the service binds.
    public var port: Int

    /// Creates a server endpoint config.
    public init(hostname: String = defaultHostname, port: Int = defaultPort) {
        self.hostname = hostname
        self.port = port
    }

    private enum CodingKeys: String, CodingKey {
        case hostname
        case port
    }

    /// Decodes an endpoint, defaulting omitted keys to the loopback default.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.hostname = try container.decodeIfPresent(String.self, forKey: .hostname) ?? Self.defaultHostname
        self.port = try container.decodeIfPresent(Int.self, forKey: .port) ?? Self.defaultPort
    }
}

/// `[auth]` — single-owner bearer-token source for non-loopback binds.
///
/// Rune Weaver is single-owner by design: exactly one bearer token guards the
/// HTTP surface once it leaves loopback. The token value never lives in
/// `config.toml`; this section only names where to resolve it, in the order the
/// auth resolver applies: the environment variable named by `token_env` for
/// headless runs first, then macOS Keychain via ``SecretsManager`` (account
/// ``defaultTokenKey``, which itself prefers a same-named environment variable),
/// then the `0600` file named by `token_file`. Resolved token bytes must never
/// be logged or rendered into diagnostics.
public struct AuthConfig: Sendable, Codable, Equatable {
    /// Keychain account and default environment variable holding the token.
    public static let defaultTokenKey = "RUNEWEAVER_AUTH_TOKEN"
    /// Conventional `0600` token file under the app support directory.
    public static let defaultTokenFile = "~/.runeweaver/auth_token"

    /// Environment variable consulted before the Keychain. Nil keeps the
    /// default key name for both env and Keychain lookups.
    public var tokenEnv: String?
    /// Path (absolute or `~`-prefixed) to a `0600` token file. Nil disables
    /// the file fallback.
    public var tokenFile: String?

    /// Creates an auth config.
    public init(tokenEnv: String? = nil, tokenFile: String? = nil) {
        self.tokenEnv = tokenEnv
        self.tokenFile = tokenFile
    }

    /// Whether this section names an explicit token source.
    ///
    /// The Keychain is always an implicit source, so an all-nil section can
    /// still authenticate when a token is stored there; this reflects only the
    /// declared env/file overrides. Boot resolves whether a token is actually
    /// present.
    public var declaresTokenSource: Bool {
        tokenEnv != nil || tokenFile != nil
    }

    private enum CodingKeys: String, CodingKey {
        case tokenEnv = "token_env"
        case tokenFile = "token_file"
    }

    /// Decodes auth sources, treating absent keys as unset.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.tokenEnv = try container.decodeIfPresent(String.self, forKey: .tokenEnv)
        self.tokenFile = try container.decodeIfPresent(String.self, forKey: .tokenFile)
    }

    /// Encodes auth sources, omitting unset keys so a round-trip never invents
    /// a blank source that would read as configured.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(tokenEnv, forKey: .tokenEnv)
        try container.encodeIfPresent(tokenFile, forKey: .tokenFile)
    }
}

/// OpenAI-compatible request style for a provider entry.
public enum APIStyle: String, Sendable, Codable, CaseIterable {
    /// Chat Completions API (`POST /chat/completions`). Default.
    case chatCompletions = "chat-completions"
    /// Responses API (`POST /responses`).
    case responses
}

/// Single source of truth for llama.cpp prefix-reuse knob defaults.
/// Both the TOML file shape and the JSON options shape store an absent key as
/// unset so small servers keep auto-assignment and stored payloads keep an omitted
/// key distinct from an explicit hint; the effective wire hint for an absent cache
/// key is enabled, resolved through `resolvedCachePrompt(fileValue:)` at provider
/// construction so storage stays aligned while the wire keeps the always-on hint.
public enum LlamaPrefixReuse: Sendable {
    /// File-level default for `slot_count` (absent keeps server auto-assign).
    public static let defaultSlotCount: Int? = nil
    /// File-level default for `cache_prompt` (absent keeps the always-on hint).
    public static let defaultCachePrompt: Bool? = nil
    /// Effective wire hint when the file omits `cache_prompt`.
    public static let effectiveCachePromptWhenUnset = true

    /// Resolves a stored file value to the wire hint.
    /// - Parameter fileValue: Stored `cache_prompt`, nil when the file omits the key.
    /// - Returns: Stored value, or the always-on hint when unset.
    public static func resolvedCachePrompt(fileValue: Bool?) -> Bool {
        fileValue ?? effectiveCachePromptWhenUnset
    }
}

/// One `[llm.providers.<name>]` entry.
public struct ProviderConfig: Sendable, Codable, Equatable {
    /// Whether the router may select this provider.
    public var enabled: Bool
    /// Model identifier (e.g. `gemma-4-9b`). Local servers only.
    public var model: String?
    /// Server URL (MLX / llama.cpp / vLLM / OpenAI-compatible endpoint).
    public var serverURL: String?

    /// Environment variable holding the API key. Resolved via
    /// `SecretsManager` (env first, Keychain fallback). Never in TOML.
    public var apiKeyEnv: String?
    /// Provider backend type (e.g. `llamacpp`) for generic local entries.
    public var providerType: String?
    /// Request style for OpenAI-compatible endpoints.
    public var apiStyle: APIStyle
    /// Context window in tokens, when explicitly configured.
    public var contextLength: Int?
    /// Sticky slot pool size for llama.cpp prefix reuse. Nil keeps server
    /// auto-assignment so small `--parallel` servers never see an out-of-range
    /// id; set it to the server's `--parallel` value to opt into pinning.
    public var slotCount: Int?
    /// Prefix-cache hint for llama.cpp. Nil keeps the always-on default so
    /// existing files without the key preserve current wire behavior; an
    /// explicit false disables the hint.
    public var cachePrompt: Bool?

    /// Creates a provider config.
    public init(
        enabled: Bool = true,
        model: String? = nil,
        serverURL: String? = nil,
        apiKeyEnv: String? = nil,
        providerType: String? = nil,
        apiStyle: APIStyle = .chatCompletions,
        contextLength: Int? = nil,
        slotCount: Int? = LlamaPrefixReuse.defaultSlotCount,
        cachePrompt: Bool? = LlamaPrefixReuse.defaultCachePrompt
    ) {
        self.enabled = enabled
        self.model = model
        self.serverURL = serverURL
        self.apiKeyEnv = apiKeyEnv
        self.providerType = providerType
        self.apiStyle = apiStyle
        self.contextLength = contextLength
        self.slotCount = slotCount
        self.cachePrompt = cachePrompt
    }

    /// Snake wire keys match the TOML file shape. The JSON options shape in RuneWeaverLLM keeps
    /// camel keys for a different transport; stored defaults for both reference LlamaPrefixReuse
    /// plus the mirror test so the two shapes share one file-level default, with the effective
    /// wire hint resolved separately at provider construction.
    private enum CodingKeys: String, CodingKey {
        case enabled
        case model
        case serverURL = "server_url"
        case apiKeyEnv = "api_key_env"
        case providerType = "provider_type"
        case apiStyle = "api_style"
        case contextLength = "context_length"
        case slotCount = "slot_count"
        case cachePrompt = "cache_prompt"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.model = try container.decodeIfPresent(String.self, forKey: .model)
        self.serverURL = try container.decodeIfPresent(String.self, forKey: .serverURL)
        self.apiKeyEnv = try container.decodeIfPresent(String.self, forKey: .apiKeyEnv)
        self.providerType = try container.decodeIfPresent(String.self, forKey: .providerType)
        self.apiStyle = try container.decodeIfPresent(APIStyle.self, forKey: .apiStyle) ?? .chatCompletions
        self.contextLength = try container.decodeIfPresent(Int.self, forKey: .contextLength)
        self.slotCount = try container.decodeIfPresent(Int.self, forKey: .slotCount)
        self.cachePrompt = try container.decodeIfPresent(Bool.self, forKey: .cachePrompt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(serverURL, forKey: .serverURL)
        try container.encodeIfPresent(apiKeyEnv, forKey: .apiKeyEnv)
        try container.encodeIfPresent(providerType, forKey: .providerType)
        try container.encode(apiStyle, forKey: .apiStyle)
        try container.encodeIfPresent(contextLength, forKey: .contextLength)
        try container.encodeIfPresent(slotCount, forKey: .slotCount)
        try container.encodeIfPresent(cachePrompt, forKey: .cachePrompt)
    }
}

/// `[llm]` — provider selection and per-provider settings.
public struct LLMConfig: Sendable, Codable, Equatable {
    /// Name of the preferred provider (key under `providers`).
    public var defaultProvider: String
    /// Optional fallback provider when the default is unhealthy.
    public var fallbackProvider: String?
    /// Provider configurations keyed by provider name.
    public var providers: [String: ProviderConfig]

    /// Creates an LLM config.
    public init(
        defaultProvider: String = "mlx",
        fallbackProvider: String? = nil,
        providers: [String: ProviderConfig] = [:]
    ) {
        self.defaultProvider = defaultProvider
        self.fallbackProvider = fallbackProvider
        self.providers = providers
    }

    private enum CodingKeys: String, CodingKey {
        case defaultProvider = "default_provider"
        case fallbackProvider = "fallback_provider"
        case providers
    }
}

/// `[memory]` — episodic and semantic memory storage locations.
public struct MemoryConfig: Sendable, Codable, Equatable {
    /// JSON store path for semantic memory (LanceDB-compatible shape) holding
    /// keyword-only rows plus optional embedding vectors written through the
    /// configured `embedding_backend`.
    public var vectorDBPath: String
    /// SQLite path for episodic memory.
    public var episodesDBPath: String
    /// Embedding model identifier retained for forward compatibility.
    public var embeddingModel: String
    /// Embedding backend selector.
    public var embeddingBackend: String

    /// `embedding_backend` selector that disables vectors (keyword-only recall).
    public static let embeddingBackendNone = "none"
    /// `embedding_backend` selector that keeps vectors on-device via NaturalLanguage.
    public static let embeddingBackendApple = "apple"
    /// `embedding_backend` selector that reuses the configured LLM embeddings endpoint.
    public static let embeddingBackendProvider = "provider"

    /// Closed set of valid `embedding_backend` selectors.
    public static let allowedEmbeddingBackends = [embeddingBackendApple, embeddingBackendProvider, embeddingBackendNone]

    /// Default SQLite database path for episodic memory, run logs, and scheduler jobs.
    public static let defaultEpisodesDBPath = "~/.runeweaver/memory/episodes.db"

    /// Creates a memory config.
    public init(
        vectorDBPath: String = "~/.runeweaver/memory/vectors",
        episodesDBPath: String = MemoryConfig.defaultEpisodesDBPath,
        embeddingModel: String = "all-MiniLM-L6-v2",
        embeddingBackend: String = MemoryConfig.embeddingBackendApple
    ) {
        self.vectorDBPath = vectorDBPath
        self.episodesDBPath = episodesDBPath
        self.embeddingModel = embeddingModel
        self.embeddingBackend = embeddingBackend
    }

    private enum CodingKeys: String, CodingKey {
        case vectorDBPath = "vector_db_path"
        case episodesDBPath = "episodes_db_path"
        case embeddingModel = "embedding_model"
        case embeddingBackend = "embedding_backend"
    }

    /// Decodes a memory config, defaulting an absent backend to `apple`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.vectorDBPath = try container.decode(String.self, forKey: .vectorDBPath)
        self.episodesDBPath = try container.decode(String.self, forKey: .episodesDBPath)
        self.embeddingModel = try container.decode(String.self, forKey: .embeddingModel)
        self.embeddingBackend = try container.decodeIfPresent(String.self, forKey: .embeddingBackend) ?? Self.embeddingBackendApple
    }
}

/// `[voice]` — speech-to-text and text-to-speech providers.
public struct VoiceConfig: Sendable, Codable, Equatable {
    /// STT provider (e.g. `whisper`).
    public var sttProvider: String
    /// Whisper model size (e.g. `base`).
    public var whisperModel: String
    /// TTS provider (e.g. `system` for the macOS `say` command).
    public var ttsProvider: String

    /// Creates a voice config.
    public init(
        sttProvider: String = "whisper",
        whisperModel: String = "base",
        ttsProvider: String = "system"
    ) {
        self.sttProvider = sttProvider
        self.whisperModel = whisperModel
        self.ttsProvider = ttsProvider
    }

    private enum CodingKeys: String, CodingKey {
        case sttProvider = "stt_provider"
        case whisperModel = "whisper_model"
        case ttsProvider = "tts_provider"
    }
}

/// `[sandbox]` — Tier-3 detonation policy only.
public struct SandboxConfig: Sendable, Equatable {
    /// Hardcoded Apple Container CLI runtime for Tier 3 detonation.
    public var containerRuntime: String {
        Self.defaultContainerRuntime
    }

    /// Default OCI base image used for quarantine/detonation (defaults to "alpine:latest").
    public var containerBaseImage: String
    /// Crash-orphan reclamation TTL in minutes for ephemeral archive detonation machines (defaults to 10).
    /// Detonations are reaped immediately; the sweeper reclaims only machines orphaned by crashes.
    public var archiveSessionTTLMinutes: Int
    /// Maximum concurrent detonation machines allowed (defaults to 3). Enforced before spawn; excess requests fail closed until reclamation frees capacity.
    public var maxConcurrentMachines: Int

    /// Hardcoded Apple Container CLI runtime for Tier 3 detonation.
    public static let defaultContainerRuntime = "container"
    /// Default container base image.
    public static let defaultContainerBaseImage = "alpine:latest"
    /// Default idle TTL for archive container sessions (10 minutes).
    public static let defaultArchiveSessionTTLMinutes = 10
    /// Default maximum concurrent container machines.
    public static let defaultMaxConcurrentMachines = 3

    /// Creates a sandbox config.
    public init(
        containerBaseImage: String = defaultContainerBaseImage,
        archiveSessionTTLMinutes: Int = defaultArchiveSessionTTLMinutes,
        maxConcurrentMachines: Int = defaultMaxConcurrentMachines
    ) {
        self.containerBaseImage = containerBaseImage
        self.archiveSessionTTLMinutes = archiveSessionTTLMinutes
        self.maxConcurrentMachines = maxConcurrentMachines
    }

    private enum CodingKeys: String, CodingKey {
        case containerBaseImage = "container_base_image"
        case archiveSessionTTLMinutes = "archive_session_ttl_minutes"
        case maxConcurrentMachines = "max_concurrent_machines"
    }
}

extension SandboxConfig: Codable {
    /// Decodes a sandbox config with built-in fallbacks.
    /// - Parameter decoder: Decoder for the config document.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        containerBaseImage = try container.decodeIfPresent(String.self, forKey: .containerBaseImage) ?? Self.defaultContainerBaseImage
        archiveSessionTTLMinutes = try container.decodeIfPresent(Int.self, forKey: .archiveSessionTTLMinutes) ?? Self.defaultArchiveSessionTTLMinutes
        maxConcurrentMachines = try container.decodeIfPresent(Int.self, forKey: .maxConcurrentMachines) ?? Self.defaultMaxConcurrentMachines
    }

    /// Encodes a sandbox config with its Tier-3 detonation policy.
    /// - Parameter encoder: Encoder for the config document.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(containerBaseImage, forKey: .containerBaseImage)
        try container.encode(archiveSessionTTLMinutes, forKey: .archiveSessionTTLMinutes)
        try container.encode(maxConcurrentMachines, forKey: .maxConcurrentMachines)
    }
}

/// `[files]` — file-tool access policy.
public struct FilesConfig: Sendable, Equatable {
    /// Glob deny patterns enforced by the shared file access guard.
    public var denyPatterns: [String]
    /// Allowed root directories for file reads (`~` expands to home).
    public var allowRoots: [String]
    /// Whether deny hits escalate to approval instead of hard denial.
    public var requireApprovalOnDeny: Bool

    /// Default deny patterns enforced by the shared file access guard.
    public static let defaultDenyPatterns = [
        ".env*",
        ".netrc",
        "secrets.json",
        "config.toml",
        "*.pem",
        "*.key",
        "*keychain*",
        ".ssh/*",
        ".aws/*",
        ".runeweaver/memory/vectors/*"
    ]
    /// Default allowed roots (home directory).
    public static let defaultAllowRoots = ["~"]
    /// Default escalation for deny hits.
    public static let defaultRequireApprovalOnDeny = true

    /// Creates a files config.
    public init(
        denyPatterns: [String] = defaultDenyPatterns,
        allowRoots: [String] = defaultAllowRoots,
        requireApprovalOnDeny: Bool = defaultRequireApprovalOnDeny
    ) {
        self.denyPatterns = denyPatterns
        self.allowRoots = allowRoots
        self.requireApprovalOnDeny = requireApprovalOnDeny
    }

    private enum CodingKeys: String, CodingKey {
        case denyPatterns = "deny_patterns"
        case allowRoots = "allow_roots"
        case requireApprovalOnDeny = "require_approval_on_deny"
    }
}

extension FilesConfig: Codable {
    /// Decodes a files config, defaulting omitted keys.
    /// - Parameter decoder: Decoder for the config document.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        denyPatterns = try container.decodeIfPresent([String].self, forKey: .denyPatterns) ?? Self.defaultDenyPatterns
        allowRoots = try container.decodeIfPresent([String].self, forKey: .allowRoots) ?? Self.defaultAllowRoots
        requireApprovalOnDeny = try container.decodeIfPresent(Bool.self, forKey: .requireApprovalOnDeny) ?? Self.defaultRequireApprovalOnDeny
    }

    /// Encodes a files config including deny patterns and roots.
    /// - Parameter encoder: Encoder for the config document.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(denyPatterns, forKey: .denyPatterns)
        try container.encode(allowRoots, forKey: .allowRoots)
        try container.encode(requireApprovalOnDeny, forKey: .requireApprovalOnDeny)
    }
}

/// `[index]` — local background indexer policy for files, mail, and messages.
///
/// The indexer is off by default (``enabled``), so a fresh install never
/// reads a mailbox or walks the home directory until the operator opts in.
/// Source toggles narrow what an enabled indexer may touch, `roots`/`exclude`
/// bound the file walk, and the remaining knobs cap per-item work and where the
/// index database lives. Secrets never appear here; the index stores content
/// and derived vectors only.
public struct IndexConfig: Sendable, Codable, Equatable {
    /// Whether the background indexer runs at all. Defaults to off.
    public var enabled: Bool
    /// Whether local files are indexed. On by default once the indexer is enabled.
    public var files: Bool
    /// Whether mail is indexed. Off by default so enabling the indexer never
    /// silently reads a mailbox.
    public var mail: Bool
    /// Whether Apple Messages are indexed. Off by default.
    public var messages: Bool
    /// Root directories scanned for files (`~` expands to home).
    public var roots: [String]
    /// Glob patterns skipped during a file scan (VCS directories, build output,
    /// caches) so the walk never descends into material it should not index.
    public var exclude: [String]
    /// Largest file the indexer will read, in megabytes. Defaults to 20 MB.
    public var maxFileMB: Int
    /// How far back mail is vectorized: a window token (``allowedMailVectorWindows``)
    /// or `all`. Defaults to `2y` to keep the local store bounded.
    public var mailVectorWindow: String
    /// Policy for iCloud files whose bytes are evicted: `skip` or `download`.
    /// Defaults to `skip` so an index run never silently pulls a file down.
    public var iCloudEvicted: String
    /// Whether image files are described with the configured LLM. Off by
    /// default; enabling it sends image content to the active provider.
    public var describeImagesWithLLM: Bool
    /// Maximum number of items processed per nightly index run. `0` means
    /// unlimited. Defaults to unlimited.
    public var nightlyBudget: Int
    /// SQLite path for the index database.
    public var dbPath: String

    /// Default file source toggle.
    public static let defaultFilesEnabled = true
    /// Default mail source toggle.
    public static let defaultMailEnabled = false
    /// Default Messages source toggle.
    public static let defaultMessagesEnabled = false
    /// Default file roots (home directory).
    public static let defaultRoots = ["~"]
    /// Default exclude patterns skipped during a file scan.
    public static let defaultExcludePatterns = [
        ".git",
        "node_modules",
        ".build",
        "DerivedData",
        "Library",
        ".Trash",
        "*.app"
    ]
    /// Default maximum file size in megabytes.
    public static let defaultMaxFileMB = 20
    /// Hard upper bound for `max_file_mb`, keeping a typo from admitting a
    /// multi-gigabyte file into the index.
    public static let maxAllowedFileMB = 10240
    /// Default `mail_vector_window` value.
    public static let defaultMailVectorWindow = "2y"
    /// Closed set of valid `mail_vector_window` values; `all` disables the window.
    public static let allowedMailVectorWindows = ["30d", "6m", "1y", "2y", "all"]
    /// Default `icloud_evicted` policy.
    public static let defaultICloudEvicted = "skip"
    /// Closed set of valid `icloud_evicted` policies.
    public static let allowedICloudEvictions = ["skip", "download"]
    /// Default `nightly_budget` value (unlimited).
    public static let defaultNightlyBudget = 0
    /// Hard upper bound for `nightly_budget`, keeping a stray extra digit from
    /// scheduling an unbounded night's work.
    public static let maxAllowedNightlyBudget = 100_000
    /// Default SQLite path for the index database.
    /// This is the single source for the on-disk index location;
    /// `DocIndexStore.defaultDBPath` aliases this value.
    public static let defaultDBPath = "~/.runeweaver/index.db"

    /// Creates an index config.
    public init(
        enabled: Bool = false,
        files: Bool = defaultFilesEnabled,
        mail: Bool = defaultMailEnabled,
        messages: Bool = defaultMessagesEnabled,
        roots: [String] = defaultRoots,
        exclude: [String] = defaultExcludePatterns,
        maxFileMB: Int = defaultMaxFileMB,
        mailVectorWindow: String = defaultMailVectorWindow,
        iCloudEvicted: String = defaultICloudEvicted,
        describeImagesWithLLM: Bool = false,
        nightlyBudget: Int = defaultNightlyBudget,
        dbPath: String = defaultDBPath
    ) {
        self.enabled = enabled
        self.files = files
        self.mail = mail
        self.messages = messages
        self.roots = roots
        self.exclude = exclude
        self.maxFileMB = maxFileMB
        self.mailVectorWindow = mailVectorWindow
        self.iCloudEvicted = iCloudEvicted
        self.describeImagesWithLLM = describeImagesWithLLM
        self.nightlyBudget = nightlyBudget
        self.dbPath = dbPath
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case files
        case mail
        case messages
        case roots
        case exclude
        case maxFileMB = "max_file_mb"
        case mailVectorWindow = "mail_vector_window"
        case iCloudEvicted = "icloud_evicted"
        case describeImagesWithLLM = "describe_images_with_llm"
        case nightlyBudget = "nightly_budget"
        case dbPath = "db_path"
    }

    /// Decodes an index config, defaulting every omitted key.
    /// - Parameter decoder: Decoder for the config document.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        files = try container.decodeIfPresent(Bool.self, forKey: .files) ?? Self.defaultFilesEnabled
        mail = try container.decodeIfPresent(Bool.self, forKey: .mail) ?? Self.defaultMailEnabled
        messages = try container.decodeIfPresent(Bool.self, forKey: .messages) ?? Self.defaultMessagesEnabled
        roots = try container.decodeIfPresent([String].self, forKey: .roots) ?? Self.defaultRoots
        exclude = try container.decodeIfPresent([String].self, forKey: .exclude) ?? Self.defaultExcludePatterns
        maxFileMB = try container.decodeIfPresent(Int.self, forKey: .maxFileMB) ?? Self.defaultMaxFileMB
        mailVectorWindow = try container.decodeIfPresent(String.self, forKey: .mailVectorWindow) ?? Self.defaultMailVectorWindow
        iCloudEvicted = try container.decodeIfPresent(String.self, forKey: .iCloudEvicted) ?? Self.defaultICloudEvicted
        describeImagesWithLLM = try container.decodeIfPresent(Bool.self, forKey: .describeImagesWithLLM) ?? false
        nightlyBudget = try container.decodeIfPresent(Int.self, forKey: .nightlyBudget) ?? Self.defaultNightlyBudget
        dbPath = try container.decodeIfPresent(String.self, forKey: .dbPath) ?? Self.defaultDBPath
    }
}

/// SMTP transport security for an `[[email.accounts]]` entry.
public enum EmailSMTPSecurity: String, Sendable, Codable, Equatable, CaseIterable {
    /// Implicit TLS (typically port 465).
    case ssl
    /// STARTTLS upgrade (typically port 587).
    case starttls
    /// Try STARTTLS first, then implicit TLS. Default for unset accounts.
    case auto

    /// Whether this mode expects implicit TLS on connect.
    public var usesImplicitTLS: Bool {
        self == .ssl
    }
}

/// One `[[email.accounts]]` entry. Passwords live in the Keychain,
/// never in TOML.
public struct EmailAccount: Sendable, Equatable {
    /// Account nickname (e.g. `icloud`).
    public var name: String
    /// Account type (e.g. `imap`).
    public var type: String
    /// IMAP hostname.
    public var host: String
    /// IMAP port. Defaults to 993 (IMAP over TLS).
    public var port: Int
    /// Login username.
    public var username: String
    /// Optional SMTP hostname override (nil means derive from the IMAP host).
    public var smtpHost: String?
    /// Optional SMTP submission port override (nil means 587/465 fallback).
    public var smtpPort: Int?
    /// SMTP transport security. Defaults to `auto` for unset accounts.
    public var smtpSecurity: EmailSMTPSecurity

    /// Creates an email account entry.
    public init(
        name: String,
        type: String = "imap",
        host: String,
        port: Int = 993,
        username: String,
        smtpHost: String? = nil,
        smtpPort: Int? = nil,
        smtpSecurity: EmailSMTPSecurity = .auto
    ) {
        self.name = name
        self.type = type
        self.host = host
        self.port = port
        self.username = username
        // Shares the single blank agreement so whitespace-only overrides read as absent everywhere.
        self.smtpHost = NormalizedText.value(smtpHost)
        self.smtpPort = smtpPort
        self.smtpSecurity = smtpSecurity
    }

    /// Environment variable holding this account's password.
    public var passwordEnvVar: String {
        Self.passwordEnvVar(forAccountNamed: name)
    }

    /// Environment variable name for an account's password.
    public static func passwordEnvVar(forAccountNamed name: String) -> String {
        let sanitized = name.uppercased().map { character in
            character.isLetter || character.isNumber ? String(character) : "_"
        }.joined()
        return "EMAIL_\(sanitized)_PASSWORD"
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case type
        case host
        case port
        case username
        case smtpHost = "smtp_host"
        case smtpPort = "smtp_port"
        case smtpSecurity = "smtp_security"
    }
}

extension EmailAccount: Codable {
    /// Decodes an account, defaulting payloads without SMTP overrides.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? "imap"
        host = try container.decode(String.self, forKey: .host)
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 993
        username = try container.decode(String.self, forKey: .username)
        let rawHost = try container.decodeIfPresent(String.self, forKey: .smtpHost)
        // Shares the single blank agreement so whitespace-only overrides read as absent everywhere.
        smtpHost = NormalizedText.value(rawHost)
        smtpPort = try container.decodeIfPresent(Int.self, forKey: .smtpPort)
        smtpSecurity = try container.decodeIfPresent(EmailSMTPSecurity.self, forKey: .smtpSecurity) ?? .auto
    }

    /// Encodes an account, omitting unset SMTP overrides.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(type, forKey: .type)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(username, forKey: .username)
        try container.encodeIfPresent(smtpHost, forKey: .smtpHost)
        try container.encodeIfPresent(smtpPort, forKey: .smtpPort)
        if smtpSecurity != .auto {
            try container.encode(smtpSecurity, forKey: .smtpSecurity)
        }
    }
}

/// `[email]` — mail accounts.
public struct EmailConfig: Sendable, Codable, Equatable {
    /// Configured mail accounts.
    public var accounts: [EmailAccount]

    /// SMTP submission ports honored across validation and sending.
    public static let allowedSubmissionPorts: Set<Int> = [25, 465, 587, 2525]

    /// Creates an email config.
    public init(accounts: [EmailAccount] = []) {
        self.accounts = accounts
    }

    /// Finds an account by name.
    /// - Parameter name: Account nickname.
    /// - Returns: Matching account, or `nil` when absent.
    public func account(named name: String) -> EmailAccount? {
        accounts.first { $0.name == name }
    }

    /// Finds an account by exact name, falling back to a case-insensitive match.
    public func account(matching name: String) -> EmailAccount? {
        if let exact = account(named: name) {
            return exact
        }
        return accounts.first { $0.name.lowercased() == name.lowercased() }
    }

    private enum CodingKeys: String, CodingKey {
        case accounts
    }
}

/// One `[[home.homekit]]` entry.
public struct HomeKitConfig: Sendable, Codable, Equatable {
    /// Whether HomeKit control is enabled.
    public var enabled: Bool

    /// Creates a HomeKit config.
    public init(enabled: Bool = true) {
        self.enabled = enabled
    }
}

/// One `[[home.home_assistant]]` entry. Tokens live in the Keychain
/// or environment, never in TOML.
public struct HomeAssistantConfig: Sendable, Codable, Equatable {
    /// Whether Home Assistant control is enabled.
    public var enabled: Bool
    /// Home Assistant base URL.
    public var url: String?
    /// Environment variable holding the long-lived access token.
    public var tokenEnv: String?

    /// Creates a Home Assistant config.
    public init(enabled: Bool = true, url: String? = nil, tokenEnv: String? = nil) {
        self.enabled = enabled
        self.url = url
        self.tokenEnv = tokenEnv
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case url
        case tokenEnv = "token_env"
    }
}

/// `[home]` — home automation integrations.
public struct HomeConfig: Sendable, Codable, Equatable {
    /// HomeKit entries.
    public var homekit: [HomeKitConfig]
    /// Home Assistant entries.
    public var homeAssistant: [HomeAssistantConfig]

    /// Creates a home config.
    public init(
        homekit: [HomeKitConfig] = [],
        homeAssistant: [HomeAssistantConfig] = []
    ) {
        self.homekit = homekit
        self.homeAssistant = homeAssistant
    }

    private enum CodingKeys: String, CodingKey {
        case homekit
        case homeAssistant = "home_assistant"
    }
}

/// `[plugins]` — plugin discovery and marketplace configuration.
public struct PluginConfig: Sendable, Codable, Equatable {
    /// Directory where installed and discovered plugins reside (defaults to `~/.runeweaver/plugins`).
    public var pluginsDir: String
    /// Remote marketplace index URL for browsing and downloading runes.
    public var marketplaceIndexURL: String
    /// Whether to automatically scan the plugins directory on server startup.
    public var autoRescan: Bool

    /// Creates a plugin configuration.
    public init(
        pluginsDir: String = "~/.runeweaver/plugins",
        marketplaceIndexURL: String = "https://raw.githubusercontent.com/ubenmackin/rune-weaver-marketplace/main/index.json",
        autoRescan: Bool = true
    ) {
        self.pluginsDir = pluginsDir
        self.marketplaceIndexURL = marketplaceIndexURL
        self.autoRescan = autoRescan
    }

    private enum CodingKeys: String, CodingKey {
        case pluginsDir = "plugins_dir"
        case marketplaceIndexURL = "marketplace_index_url"
        case autoRescan = "auto_rescan"
    }
}

/// `[browser]` — local web search and fetch policy.
public struct BrowserConfig: Sendable, Codable, Equatable {
    /// SearXNG base URL (e.g. `http://127.0.0.1:8888`). Requests append `/search`.
    public var searxngURL: String
    /// Per-search HTTP timeout in seconds, bounding one SearXNG round trip.
    public var searchTimeoutSeconds: Int
    /// Maximum results returned per `web.search` call, bounding context fan-out.
    public var maxResults: Int

    /// Default SearXNG base URL for local-first installs.
    public static let defaultSearxngURL = "http://127.0.0.1:8888"
    /// Default per-search timeout in seconds.
    public static let defaultSearchTimeoutSeconds = 10
    /// Default result cap per search.
    public static let defaultMaxResults = 10
    /// Hard upper bound for `max_results`, mirroring mail search caps.
    public static let maxAllowedResults = 50

    /// Environment variable overriding the browser Python executable.
    /// Single source for the override name so the gateway, the managed venv
    /// ensurer, and health copy never drift; pipx and Homebrew installs do not
    /// satisfy `import playwright` for the server python, so an explicit path
    /// here always wins over the managed venv and the PATH fallback.
    public static let pythonBinEnvVar = "RUNEWEAVER_PYTHON_BIN"
    /// Managed virtual-environment directory for browser automation.
    /// Kept under `~/.runeweaver` so provisioning never touches a user-owned
    /// venv elsewhere and an existing managed entry is reused, never clobbered.
    public static let managedPythonVenvDir = "~/.runeweaver/python"
    /// Relative path of the interpreter inside the managed venv.
    public static let managedPythonRelativeBin = "bin/python"

    /// Managed venv directory with `~` expanded to the home directory.
    /// - Returns: Directory hosting the managed `bin/python`.
    public static func managedPythonVenvDirURL() -> URL {
        URL(fileURLWithPath: (managedPythonVenvDir as NSString).expandingTildeInPath)
    }

    /// Interpreter path inside the managed venv.
    /// - Returns: `~/.runeweaver/python/bin/python` expanded for the current user.
    public static func managedPythonExecutableURL() -> URL {
        managedPythonVenvDirURL().appendingPathComponent(managedPythonRelativeBin)
    }

    /// Display path for the managed venv directory (unexpanded, for copy).
    /// - Returns: `~/.runeweaver/python` as configured.
    public static func managedPythonVenvDisplayPath() -> String {
        managedPythonVenvDir
    }

    /// Display path for the managed interpreter (unexpanded, for copy).
    /// - Returns: `~/.runeweaver/python/bin/python` as configured.
    public static func managedPythonDisplayPath() -> String {
        (managedPythonVenvDir as NSString).appendingPathComponent(managedPythonRelativeBin)
    }

    /// Additional allowed homelab domains, hostnames, or IP patterns for browser/web navigation.
    public var allowedOrigins: [String]

    /// Default allowed origins for fresh installs.
    public static let defaultAllowedOrigins: [String] = []

    /// Creates a browser config.
    public init(
        searxngURL: String = defaultSearxngURL,
        searchTimeoutSeconds: Int = defaultSearchTimeoutSeconds,
        maxResults: Int = defaultMaxResults,
        allowedOrigins: [String] = defaultAllowedOrigins
    ) {
        self.searxngURL = searxngURL
        self.searchTimeoutSeconds = searchTimeoutSeconds
        self.maxResults = maxResults
        self.allowedOrigins = allowedOrigins
    }

    private enum CodingKeys: String, CodingKey {
        case searxngURL = "searxng_url"
        case searchTimeoutSeconds = "search_timeout_seconds"
        case maxResults = "max_results"
        case allowedOrigins = "allowed_origins"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        searxngURL = try container.decodeIfPresent(String.self, forKey: .searxngURL) ?? Self.defaultSearxngURL
        searchTimeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .searchTimeoutSeconds) ?? Self.defaultSearchTimeoutSeconds
        maxResults = try container.decodeIfPresent(Int.self, forKey: .maxResults) ?? Self.defaultMaxResults
        allowedOrigins = try container.decodeIfPresent([String].self, forKey: .allowedOrigins) ?? Self.defaultAllowedOrigins
    }
}

// MARK: - NormalizedText lives in NormalizedText.swift

// MARK: - Root config

/// Root configuration mirroring `~/.runeweaver/config.toml`.
public struct RuneWeaverConfig: Sendable, Codable, Equatable {
    /// Engine identity and logging.
    public var engine: EngineConfig
    /// HTTP API bind endpoint.
    public var server: ServerEndpointConfig
    /// Single-owner bearer-token source for non-loopback binds.
    public var auth: AuthConfig
    /// LLM provider selection.
    public var llm: LLMConfig
    /// Memory storage locations.
    public var memory: MemoryConfig
    /// Voice pipeline providers.
    public var voice: VoiceConfig
    /// Sandbox staging and trust policy.
    public var sandbox: SandboxConfig
    /// File-tool access policy (deny list plus allowed roots).
    public var files = FilesConfig()
    /// Mail accounts.
    public var email: EmailConfig
    /// Home automation.
    public var home: HomeConfig
    /// Scheduled jobs (cron and email-arrival triggers).
    public var scheduler: SchedulerConfig
    /// Plugin discovery and marketplace settings.
    public var plugins: PluginConfig
    /// Local web search and fetch policy.
    public var browser = BrowserConfig()
    /// Home media automation (Sonarr & Radarr).
    public var media = MediaConfig()
    /// Local background indexer policy for files, mail, and messages.
    public var index = IndexConfig()

    /// Creates a root config from section configs.
    public init(
        engine: EngineConfig = EngineConfig(),
        server: ServerEndpointConfig = ServerEndpointConfig(),
        auth: AuthConfig = AuthConfig(),
        llm: LLMConfig = LLMConfig(),
        memory: MemoryConfig = MemoryConfig(),
        voice: VoiceConfig = VoiceConfig(),
        sandbox: SandboxConfig = SandboxConfig(),
        files: FilesConfig = FilesConfig(),
        email: EmailConfig = EmailConfig(),
        home: HomeConfig = HomeConfig(),
        scheduler: SchedulerConfig = SchedulerConfig(),
        plugins: PluginConfig = PluginConfig(),
        browser: BrowserConfig = BrowserConfig(),
        media: MediaConfig = MediaConfig(),
        index: IndexConfig = IndexConfig()
    ) {
        self.engine = engine
        self.server = server
        self.auth = auth
        self.llm = llm
        self.memory = memory
        self.voice = voice
        self.sandbox = sandbox
        self.files = files
        self.email = email
        self.home = home
        self.scheduler = scheduler
        self.plugins = plugins
        self.browser = browser
        self.media = media
        self.index = index
    }

    /// Config with sensible defaults matching `config.toml.example`.
    public static var `default`: RuneWeaverConfig {
        RuneWeaverConfig(
            llm: LLMConfig(
                defaultProvider: "mlx",
                fallbackProvider: "openrouter",
                providers: [
                    "mlx": ProviderConfig(
                        enabled: true,
                        model: "gemma-4-9b",
                        serverURL: "http://localhost:8080"
                    ),
                    "openrouter": ProviderConfig(
                        enabled: true,
                        serverURL: "https://openrouter.ai/api/v1",
                        apiKeyEnv: "OPENROUTER_API_KEY"
                    ),
                    "local": ProviderConfig(
                        enabled: false,
                        serverURL: "http://localhost:8081",
                        providerType: "llamacpp"
                    )
                ]
            ),
            home: HomeConfig(
                homekit: [HomeKitConfig(enabled: true)],
                homeAssistant: [
                    HomeAssistantConfig(
                        enabled: true,
                        url: "http://homeassistant.local:8123",
                        tokenEnv: "HA_TOKEN"
                    )
                ]
            )
        )
    }

    /// Default config file location: `~/.runeweaver/config.toml`.
    /// - Returns: Resolved file URL with `~` expanded.
    public static func defaultConfigFileURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".runeweaver/config.toml")
    }

    /// Loads and validates the config at the default location.
    public static func loadDefault() throws -> RuneWeaverConfig {
        let url = defaultConfigFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .default
        }
        return try load(from: url)
    }

    /// Loads and validates the config at the given file URL.
    public static func load(from fileURL: URL) throws -> RuneWeaverConfig {
        let path = fileURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            throw ConfigError.fileNotFound(path: path)
        }
        let text: String
        do {
            text = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            throw ConfigError.unreadable(path: path, reason: error.localizedDescription)
        }
        let parsed = try TOMLParser.parse(text)
        let config = try RuneWeaverConfig(decoding: parsed)
        try config.validate()
        return config
    }
}

// MARK: - TOML serialization lives in Config+Serialization.swift

// MARK: - Validation lives in Config+Validation.swift

// MARK: - Hot-reloading loader lives in ConfigLoader.swift

// MARK: - TOML decoding lives in ConfigTOML.swift

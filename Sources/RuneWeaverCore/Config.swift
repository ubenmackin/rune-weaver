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
        case logLevel
        case compactionThresholdPercent
        case maxToolIterations
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
    /// Upper bound on explicit `allowed_hosts` entries, keeping the Host gate auditable.
    public static let maxAllowedHosts = 20
    /// Upper bound on one `allowed_hosts` entry, matching the DNS name limit.
    public static let maxAllowedHostLength = 253

    /// Interface the service binds.
    public var hostname: String
    /// TCP port the service binds.
    public var port: Int
    /// Extra exact hostnames the Host gate accepts beside loopback and the bind hostname.
    ///
    /// Entries are exact-only and matched after lowercasing plus port stripping,
    /// so no scheme, wildcard, CIDR, or bare `*` is stored here; validation
    /// rejects those shapes fail-closed and the middleware normalizes the rest.
    public var allowedHosts: [String]

    /// Creates a server endpoint config.
    ///
    /// The hostname and allowlist entries are trimmed so padded file values or
    /// direct construction never reach the bind or the gate with whitespace;
    /// widening shapes stay verbatim for the gate to drop fail-closed instead
    /// of allowlisting a carved fragment.
    public init(hostname: String = defaultHostname, port: Int = defaultPort, allowedHosts: [String] = []) {
        self.hostname = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port
        self.allowedHosts = allowedHosts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private enum CodingKeys: String, CodingKey {
        case hostname
        case port
        case allowedHosts
    }

    /// Decodes an endpoint, defaulting omitted keys to the loopback default.
    ///
    /// Values trim so padded payloads never reach the bind or the gate with
    /// whitespace; widening shapes stay verbatim for the gate to drop.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawHostname = try container.decodeIfPresent(String.self, forKey: .hostname) ?? Self.defaultHostname
        self.hostname = rawHostname.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = try container.decodeIfPresent(Int.self, forKey: .port) ?? Self.defaultPort
        let rawHosts = try container.decodeIfPresent([String].self, forKey: .allowedHosts) ?? []
        self.allowedHosts = rawHosts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
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
        case tokenEnv
        case tokenFile
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
    /// Whether the model accepts vision input (screenshots, images).
    /// Nil uses backend defaults (true for cloud endpoints, false for local servers).
    public var supportsVision: Bool?
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
        supportsVision: Bool? = nil,
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
        self.supportsVision = supportsVision
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
        case serverURL
        case apiKeyEnv
        case providerType
        case apiStyle
        case contextLength
        case supportsVision
        case slotCount
        case cachePrompt
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
        self.supportsVision = try container.decodeIfPresent(Bool.self, forKey: .supportsVision)
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
        try container.encodeIfPresent(supportsVision, forKey: .supportsVision)
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
        case defaultProvider
        case fallbackProvider
        case providers
    }
}

/// `[memory]` recall budgets bounding automatic and explicit recall fan-out.
///
/// Single source for the budgets-aware auto-recall path: per-tier fetch caps,
/// the auto injection cap, the calibrated score floor, the total and per-hit
/// char budgets, the document candidate-pool widening factor, scaled by the
/// vector leg's own read width and mirrored by the keyword leg, and the
/// episodic tier weight. The budgets-aware
/// `MemoryEngine` overloads read only this struct on the auto path; the
/// `automaticRecallLimit/threshold/maxChars` statics remain as defaults for
/// the legacy threshold-based overloads.
public struct RecallBudgets: Sendable, Codable, Equatable {
    /// Maximum hits fetched per tier before merging. Clamped `1...50`.
    public var perTierLimit: Int
    /// Maximum hits injected as system context on one auto turn. Clamped `1...50`.
    public var autoLimit: Int
    /// Minimum calibrated score for an injected recall hit. Clamped `0...1`.
    public var threshold: Double
    /// Maximum characters for the injected recall block, header included. Clamped `500...32000`.
    public var maxChars: Int
    /// Maximum characters kept per hit before ellipsis truncation. Clamped `100...8000`.
    public var perHitChars: Int
    /// Widening factor for the document candidate pool beyond the returned
    /// page: the vector leg scans `pool * 10` with a 500-row floor and the
    /// keyword leg reads that same width, so the multiplier only moves the
    /// vector leg once `pool * 10` clears 500. Clamped `1...8`.
    public var docPoolMultiplier: Int
    /// Weight mapping episodic rank scores onto the shared recall scale. Clamped `0...1`.
    public var episodicWeight: Double

    /// Bounds for `perTierLimit` and `autoLimit`.
    public static let limitBounds = 1 ... 50
    /// Bounds for `threshold` and `episodicWeight`.
    public static let scoreBounds = 0.0 ... 1.0
    /// Bounds for `maxChars`.
    public static let maxCharsBounds = 500 ... 32000
    /// Bounds for `perHitChars`.
    public static let perHitCharsBounds = 100 ... 8000
    /// Bounds for `docPoolMultiplier`.
    public static let docPoolMultiplierBounds = 1 ... 8

    /// Default hits fetched per tier before merging.
    public static let defaultPerTierLimit = 5
    /// Default hits injected as system context on one auto turn.
    public static let defaultAutoLimit = 5
    /// Default minimum calibrated score for an injected recall hit.
    public static let defaultThreshold = 0.1
    /// Default maximum characters for the injected recall block.
    public static let defaultMaxChars = 8000
    /// Default maximum characters kept per hit before truncation.
    public static let defaultPerHitChars = 2000
    /// Default widening factor for the document candidate pool, mirrored in
    /// width by the keyword leg.
    public static let defaultDocPoolMultiplier = 4
    /// Default weight mapping episodic rank scores onto the shared recall scale.
    public static let defaultEpisodicWeight = 0.25

    /// Creates recall budgets.
    public init(
        perTierLimit: Int = defaultPerTierLimit,
        autoLimit: Int = defaultAutoLimit,
        threshold: Double = defaultThreshold,
        maxChars: Int = defaultMaxChars,
        perHitChars: Int = defaultPerHitChars,
        docPoolMultiplier: Int = defaultDocPoolMultiplier,
        episodicWeight: Double = defaultEpisodicWeight
    ) {
        self.perTierLimit = perTierLimit
        self.autoLimit = autoLimit
        self.threshold = threshold
        self.maxChars = maxChars
        self.perHitChars = perHitChars
        self.docPoolMultiplier = docPoolMultiplier
        self.episodicWeight = episodicWeight
    }

    private enum CodingKeys: String, CodingKey {
        case perTierLimit
        case autoLimit
        case threshold
        case maxChars
        case perHitChars
        case docPoolMultiplier
        case episodicWeight
    }

    /// Decodes recall budgets, defaulting every omitted key.
    /// - Parameter decoder: Decoder for the config document.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        perTierLimit = try container.decodeIfPresent(Int.self, forKey: .perTierLimit) ?? Self.defaultPerTierLimit
        autoLimit = try container.decodeIfPresent(Int.self, forKey: .autoLimit) ?? Self.defaultAutoLimit
        threshold = try container.decodeIfPresent(Double.self, forKey: .threshold) ?? Self.defaultThreshold
        maxChars = try container.decodeIfPresent(Int.self, forKey: .maxChars) ?? Self.defaultMaxChars
        perHitChars = try container.decodeIfPresent(Int.self, forKey: .perHitChars) ?? Self.defaultPerHitChars
        docPoolMultiplier = try container.decodeIfPresent(Int.self, forKey: .docPoolMultiplier) ?? Self.defaultDocPoolMultiplier
        episodicWeight = try container.decodeIfPresent(Double.self, forKey: .episodicWeight) ?? Self.defaultEpisodicWeight
    }

    /// Encodes recall budgets.
    /// - Parameter encoder: Destination encoder.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(perTierLimit, forKey: .perTierLimit)
        try container.encode(autoLimit, forKey: .autoLimit)
        try container.encode(threshold, forKey: .threshold)
        try container.encode(maxChars, forKey: .maxChars)
        try container.encode(perHitChars, forKey: .perHitChars)
        try container.encode(docPoolMultiplier, forKey: .docPoolMultiplier)
        try container.encode(episodicWeight, forKey: .episodicWeight)
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
    /// Recall budgets bounding automatic and explicit recall fan-out.
    ///
    /// The budgets-aware `MemoryEngine` auto path reads this struct; file keys
    /// land as flat `recall_*` entries under `[memory]`. `MemoryConfig` itself
    /// nests them as the `recall_budgets` object in its Codable form, while the
    /// settings DTO exposes the same values as flat `memoryRecall*` fields so
    /// dashboard payloads stay version-tolerant without sharing the nesting.
    public var recallBudgets: RecallBudgets

    /// `embedding_backend` selector that disables vectors (keyword-only recall).
    public static let embeddingBackendNone = "none"
    /// `embedding_backend` selector that keeps vectors on-device via EmbeddingGemma 2 on Metal.
    public static let embeddingBackendLocal = "local"
    /// `embedding_backend` selector that reuses the configured LLM embeddings endpoint.
    public static let embeddingBackendProvider = "provider"

    /// Closed set of valid `embedding_backend` selectors.
    public static let allowedEmbeddingBackends = [embeddingBackendLocal, embeddingBackendProvider, embeddingBackendNone]

    /// Migrates a stored `embedding_backend` value, mapping legacy `apple` to `local`.
    public static func migratedEmbeddingBackend(_ raw: String) -> String {
        (raw == "apple") ? embeddingBackendLocal : raw
    }

    /// Default SQLite database path for episodic memory, run logs, and scheduler jobs.
    public static let defaultEpisodesDBPath = "~/.runeweaver/memory/episodes.db"

    /// Creates a memory config.
    public init(
        vectorDBPath: String = "~/.runeweaver/memory/vectors",
        episodesDBPath: String = MemoryConfig.defaultEpisodesDBPath,
        embeddingModel: String = "all-MiniLM-L6-v2",
        embeddingBackend: String = MemoryConfig.embeddingBackendLocal,
        recallBudgets: RecallBudgets = RecallBudgets()
    ) {
        self.vectorDBPath = vectorDBPath
        self.episodesDBPath = episodesDBPath
        self.embeddingModel = embeddingModel
        self.embeddingBackend = embeddingBackend
        self.recallBudgets = recallBudgets
    }

    private enum CodingKeys: String, CodingKey {
        case vectorDBPath
        case episodesDBPath
        case embeddingModel
        case embeddingBackend
        case recallBudgets
    }

    /// Decodes a memory config, defaulting an absent backend to `local` and migrating legacy `apple` to `local`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.vectorDBPath = try container.decode(String.self, forKey: .vectorDBPath)
        self.episodesDBPath = try container.decode(String.self, forKey: .episodesDBPath)
        self.embeddingModel = try container.decode(String.self, forKey: .embeddingModel)
        let rawBackend = try container.decodeIfPresent(String.self, forKey: .embeddingBackend) ?? Self.embeddingBackendLocal
        self.embeddingBackend = Self.migratedEmbeddingBackend(rawBackend)
        self.recallBudgets = try container.decodeIfPresent(RecallBudgets.self, forKey: .recallBudgets) ?? RecallBudgets()
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
        case sttProvider
        case whisperModel
        case ttsProvider
    }
}

/// `[containers]` — unified container runtime policy for sandboxed execution.
///
/// Single source for the container knobs: the guest memory budget, the
/// concurrent-container cap, and the idle reclamation TTL. Supersedes the
/// legacy `[sandbox]` table, which is ignored on load (with a logged note)
/// and shed on resave; legacy values are never migrated into this section.
/// The container images themselves are pinned in code — strict per-turn and
/// machine-scoped workspace containers run ``StrictContainerRunner/defaultImage``
/// (`debian:stable-slim`) and detonation containers run
/// ``LiveEmailArchiveDetonator/detonationImage`` (`alpine:3.22`) — so this
/// section carries no image key.
public struct ContainersConfig: Sendable, Equatable {
    /// Memory budget in megabytes for one container. Clamped `256...8192`.
    public var memoryMB: Int
    /// Maximum containers running at once. Clamped `1...32`.
    public var maxConcurrent: Int
    /// Idle lifetime in minutes before a container is reclaimed. Clamped `5...1440`.
    public var ttlMinutes: Int

    /// Default memory budget in megabytes.
    public static let defaultMemoryMB = 512
    /// Lower memory bound; below this a container cannot fit toolchains.
    public static let minMemoryMB = 256
    /// Upper memory bound before one container crowds the host.
    public static let maxMemoryMB = 8192
    /// Default concurrent container cap.
    public static let defaultMaxConcurrent = 5
    /// Lower concurrency bound; a zero or negative cap is meaningless.
    public static let minMaxConcurrent = 1
    /// Upper concurrency bound before containers oversubscribe the host.
    public static let maxMaxConcurrent = 32
    /// Default idle reclamation TTL in minutes.
    public static let defaultTTLMinutes = 60
    /// Shortest idle TTL that still survives one model round trip.
    public static let minTTLMinutes = 5
    /// Longest idle TTL before reclamation reads as storage rather than scratch.
    public static let maxTTLMinutes = 1440

    /// Creates a containers config.
    public init(
        memoryMB: Int = defaultMemoryMB,
        maxConcurrent: Int = defaultMaxConcurrent,
        ttlMinutes: Int = defaultTTLMinutes
    ) {
        self.memoryMB = memoryMB
        self.maxConcurrent = maxConcurrent
        self.ttlMinutes = ttlMinutes
    }

    private enum CodingKeys: String, CodingKey {
        case memoryMB = "memoryMb"
        case maxConcurrent
        case ttlMinutes
    }
}

extension ContainersConfig: Codable {
    /// Decodes a containers config, defaulting every omitted key.
    /// - Parameter decoder: Decoder for the config document.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        memoryMB = try container.decodeIfPresent(Int.self, forKey: .memoryMB) ?? Self.defaultMemoryMB
        maxConcurrent = try container.decodeIfPresent(Int.self, forKey: .maxConcurrent) ?? Self.defaultMaxConcurrent
        ttlMinutes = try container.decodeIfPresent(Int.self, forKey: .ttlMinutes) ?? Self.defaultTTLMinutes
    }

    /// Encodes a containers config.
    /// - Parameter encoder: Encoder for the config document.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(memoryMB, forKey: .memoryMB)
        try container.encode(maxConcurrent, forKey: .maxConcurrent)
        try container.encode(ttlMinutes, forKey: .ttlMinutes)
    }
}

/// Action for a granular bash execution rule.
public enum BashPermissionAction: String, Sendable, Codable, Equatable, CaseIterable {
    case allow
    case ask
    case deny
}

/// A pattern-matching rule for granular bash command permissions.
public struct BashRule: Sendable, Codable, Equatable {
    /// Command or pattern to match (e.g. "echo", "echo *", "git status", "*", "rm *").
    public var pattern: String
    /// Permission action to take when matched.
    public var action: BashPermissionAction

    public init(pattern: String, action: BashPermissionAction) {
        self.pattern = pattern
        self.action = action
    }
}

/// Sandbox execution tier for `bash.exec`.
///
/// Baseline is macOS 26 with no version branches; tiers describe mount scope only.
/// - `strictContainer` mounts only workspace `tmp`.
/// - `machineScoped` mounts only the workspace root.
/// - `hostSeatbelt` runs only on fnmatch/prefix match via `BashSecurity.matches`.
/// No tier mounts HOME.
public enum BashSandboxMode: String, Sendable, Codable, Equatable, CaseIterable {
    case strictContainer
    case machineScoped
    case hostSeatbelt
}

/// `[bash]` — granular shell execution policy.
///
/// CPU and memory bounds ride `ulimit` inside the shell so every spawned
/// command inherits them without a new supervisor process; the wall-clock
/// timeout stays the hard backstop because `ulimit` is best-effort on macOS.
public struct BashConfig: Sendable, Codable, Equatable {
    /// Whether the bash tool is enabled. Defaults to true.
    public var enabled: Bool
    /// Default action if no rule matches. Defaults to `ask`.
    public var defaultAction: BashPermissionAction
    /// Ordered permission rules evaluated top-to-bottom; the last matching rule decides.
    /// Put the catch-all first and specifics after.
    public var rules: [BashRule]
    /// Default execution timeout in seconds.
    public var timeoutSeconds: Int
    /// Whether outbound and inbound network access is permitted in sandbox. Defaults to false.
    public var allowNetwork: Bool
    /// CPU time budget in seconds applied via `ulimit -t` before each command.
    /// Sleeping processes accrue almost no CPU time, so a sleep-heavy command
    /// can run past this budget up to the wall-clock timeout.
    public var cpuSeconds: Int
    /// Address-space budget in megabytes applied via `ulimit -v` before each command.
    public var memoryMB: Int
    /// Sandbox execution tier. Defaults to `strictContainer`.
    public var sandboxMode: BashSandboxMode
    /// Fnmatch/prefix allow patterns gating `hostSeatbelt` execution via `BashSecurity.matches`.
    public var hostAllowPatterns: [String]

    /// Default rules: all commands require approval (`*` -> `ask`).
    public static let defaultRules: [BashRule] = [
        BashRule(pattern: "*", action: .ask)
    ]
    public static let defaultTimeoutSeconds: Int = 30
    /// Default CPU budget keeps tight loops from spinning past a couple minutes.
    public static let defaultCPUSeconds: Int = 120
    /// Default address-space budget fits compilers and scripts without inviting OOM swaps.
    public static let defaultMemoryMB: Int = 1024
    /// Default tier keeps execution in the strict container.
    public static let defaultSandboxMode: BashSandboxMode = .strictContainer
    /// Default host allows cover the Xcode toolchain.
    public static let defaultHostAllowPatterns: [String] = ["xcodebuild*", "codesign*"]
    /// Upper bound on `hostAllowPatterns` entries, keeping the allowlist auditable.
    public static let maxHostAllowPatterns = 50
    /// Longest single `hostAllowPatterns` entry.
    public static let maxHostAllowPatternLength = 256

    public init(
        enabled: Bool = true,
        defaultAction: BashPermissionAction = .ask,
        rules: [BashRule] = defaultRules,
        timeoutSeconds: Int = defaultTimeoutSeconds,
        allowNetwork: Bool = false,
        cpuSeconds: Int = defaultCPUSeconds,
        memoryMB: Int = defaultMemoryMB,
        sandboxMode: BashSandboxMode = defaultSandboxMode,
        hostAllowPatterns: [String] = defaultHostAllowPatterns
    ) {
        self.enabled = enabled
        self.defaultAction = defaultAction
        self.rules = rules
        self.timeoutSeconds = timeoutSeconds
        self.allowNetwork = allowNetwork
        self.cpuSeconds = cpuSeconds
        self.memoryMB = memoryMB
        self.sandboxMode = sandboxMode
        self.hostAllowPatterns = hostAllowPatterns
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case defaultAction
        case rules
        case timeoutSeconds
        case allowNetwork
        case cpuSeconds
        case memoryMB = "memoryMb"
        case sandboxMode
        case hostAllowPatterns
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.defaultAction = try container.decodeIfPresent(BashPermissionAction.self, forKey: .defaultAction) ?? .ask
        self.rules = try container.decodeIfPresent([BashRule].self, forKey: .rules) ?? Self.defaultRules
        self.timeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? Self.defaultTimeoutSeconds
        self.allowNetwork = try container.decodeIfPresent(Bool.self, forKey: .allowNetwork) ?? false
        self.cpuSeconds = try container.decodeIfPresent(Int.self, forKey: .cpuSeconds) ?? Self.defaultCPUSeconds
        self.memoryMB = try container.decodeIfPresent(Int.self, forKey: .memoryMB) ?? Self.defaultMemoryMB
        self.sandboxMode = try container.decodeIfPresent(BashSandboxMode.self, forKey: .sandboxMode) ?? Self.defaultSandboxMode
        self.hostAllowPatterns = try container.decodeIfPresent([String].self, forKey: .hostAllowPatterns) ?? Self.defaultHostAllowPatterns
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(defaultAction, forKey: .defaultAction)
        try container.encode(rules, forKey: .rules)
        try container.encode(timeoutSeconds, forKey: .timeoutSeconds)
        try container.encode(allowNetwork, forKey: .allowNetwork)
        try container.encode(cpuSeconds, forKey: .cpuSeconds)
        try container.encode(memoryMB, forKey: .memoryMB)
        try container.encode(sandboxMode, forKey: .sandboxMode)
        try container.encode(hostAllowPatterns, forKey: .hostAllowPatterns)
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
        case smtpHost
        case smtpPort
        case smtpSecurity
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

/// `[ideas]` — proactive Wayfinder suggestions.
///
/// Ideas stay opt-in so a fresh install never spends background model calls
/// brainstorming. `maxPerCycle` caps how many candidate ideas one generation
/// pass may surface, and `timeoutSeconds` bounds the single cheap review call
/// so a hung backend returns no ideas instead of stalling the trigger that
/// asked for them.
public struct IdeasConfig: Sendable, Equatable {
    /// Whether proactive idea generation runs at all. Off by default.
    public var enabled: Bool
    /// Maximum ideas persisted per generation cycle. Clamped `1...10`.
    public var maxPerCycle: Int
    /// Seconds the review waits on the model before returning no ideas.
    public var timeoutSeconds: Int

    /// Default keeps ideas off so stock installs stay quiet.
    public static let defaultEnabled = false
    /// Default batch keeps one review from flooding the ideas list.
    public static let defaultMaxPerCycle = 3
    /// Default review budget waits out slow local models without stalling the trigger.
    public static let defaultTimeoutSeconds = 20
    /// Fewest ideas worth a generation cycle.
    public static let minMaxPerCycle = 1
    /// Most ideas before one review floods the owner.
    public static let maxMaxPerCycle = 10
    /// Shortest review budget that still allows one model round trip.
    public static let minTimeoutSeconds = 1
    /// Largest review budget before a trigger holds too long.
    public static let maxTimeoutSeconds = 120

    /// Creates an ideas config.
    public init(
        enabled: Bool = defaultEnabled,
        maxPerCycle: Int = defaultMaxPerCycle,
        timeoutSeconds: Int = defaultTimeoutSeconds
    ) {
        self.enabled = enabled
        self.maxPerCycle = maxPerCycle
        self.timeoutSeconds = timeoutSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case maxPerCycle
        case timeoutSeconds
    }
}

extension IdeasConfig: Codable {
    /// Decodes an ideas config, defaulting every omitted key.
    /// - Parameter decoder: Decoder for the config document.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? Self.defaultEnabled
        maxPerCycle = try container.decodeIfPresent(Int.self, forKey: .maxPerCycle) ?? Self.defaultMaxPerCycle
        timeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? Self.defaultTimeoutSeconds
    }

    /// Encodes an ideas config.
    /// - Parameter encoder: Encoder for the config document.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(maxPerCycle, forKey: .maxPerCycle)
        try container.encode(timeoutSeconds, forKey: .timeoutSeconds)
    }
}

/// Parallel worker fan-out policy.
///
/// Single-gate policy: availability flows through tool registration alone,
/// so this section only tunes the swarm shape. The worker cap keeps a swarm
/// cheap on a local model, the timeout bounds one worker turn (zero means no
/// timeout, intentional for slow local models), and the tool-subset switch
/// stays off so research fan-out cannot mutate state unless explicitly widened.
public struct FanOutConfig: Sendable, Equatable {
    /// Maximum workers running at once. Clamped `1...8` so a wide subtask
    /// list cannot oversubscribe the serving model.
    public var maxWorkers: Int
    /// Wall-clock budget for one worker turn before it is marked failed.
    /// Zero means no timeout; positive values clamp to
    /// `1...maxWorkerTimeoutSeconds`.
    public var workerTimeoutSeconds: Int
    /// Whether workers may call the full tool registry. Off by default so
    /// research fan-out runs with the read-only subset and cannot mutate
    /// state; the widening switch is an explicit operator choice.
    public var fullTools: Bool

    /// Default worker cap keeps a swarm cheap on a local model.
    public static let defaultMaxWorkers = 2
    /// Lower worker bound; a zero or negative cap is meaningless.
    public static let minMaxWorkers = 1
    /// Upper worker bound before a swarm oversubscribes the serving model.
    public static let maxMaxWorkers = 8
    /// Zero means a worker runs with no wall-clock timeout, so slow local
    /// models can finish without the parent run timing them out.
    public static let unlimitedWorkerTimeoutSeconds = 0
    /// Default worker budget is unlimited so slow local models settle without
    /// an arbitrary bound; cancellation still ends the turn.
    public static let defaultWorkerTimeoutSeconds = 0
    /// Upper timeout bound (24h) before a stray digit holds a run open
    /// beyond any plausible model round.
    public static let maxWorkerTimeoutSeconds = 86400
    /// Default keeps workers on the read-only subset so research fan-out
    /// cannot mutate.
    public static let defaultFullTools = false

    /// Creates a fanout config.
    public init(
        maxWorkers: Int = defaultMaxWorkers,
        workerTimeoutSeconds: Int = defaultWorkerTimeoutSeconds,
        fullTools: Bool = defaultFullTools
    ) {
        self.maxWorkers = maxWorkers
        self.workerTimeoutSeconds = workerTimeoutSeconds
        self.fullTools = fullTools
    }

    /// Returns a copy clamped into the validated ranges.
    /// The engine clamps at init so a hand-built config degrades to the
    /// nearest sane bound instead of refusing to run or oversubscribing;
    /// load-time validation fails closed, and both postures share the same
    /// range constants so they cannot drift.
    /// - Returns: Config with the worker cap pulled inside bounds and a
    ///   non-positive timeout folded to unlimited (zero), otherwise clamped
    ///   to `1...maxWorkerTimeoutSeconds`.
    public func clamped() -> FanOutConfig {
        let timeout: Int = if workerTimeoutSeconds <= 0 {
            Self.unlimitedWorkerTimeoutSeconds
        } else {
            min(max(workerTimeoutSeconds, 1), Self.maxWorkerTimeoutSeconds)
        }
        return FanOutConfig(
            maxWorkers: min(max(maxWorkers, Self.minMaxWorkers), Self.maxMaxWorkers),
            workerTimeoutSeconds: timeout,
            fullTools: fullTools
        )
    }

    private enum CodingKeys: String, CodingKey {
        case maxWorkers
        case workerTimeoutSeconds
        case fullTools
    }
}

extension FanOutConfig: Codable {
    /// Decodes a fanout config, defaulting every omitted key.
    /// - Parameter decoder: Decoder for the config document.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        maxWorkers = try container.decodeIfPresent(Int.self, forKey: .maxWorkers) ?? Self.defaultMaxWorkers
        workerTimeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .workerTimeoutSeconds) ?? Self.defaultWorkerTimeoutSeconds
        fullTools = try container.decodeIfPresent(Bool.self, forKey: .fullTools) ?? Self.defaultFullTools
    }

    /// Encodes a fanout config.
    /// - Parameter encoder: Encoder for the config document.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(maxWorkers, forKey: .maxWorkers)
        try container.encode(workerTimeoutSeconds, forKey: .workerTimeoutSeconds)
        try container.encode(fullTools, forKey: .fullTools)
    }
}

/// `[workspace]` — agent scratch directory quotas and temp retention.
///
/// The workspace is the default working directory for shell execution, so it
/// needs explicit bounds: a size cap keeps stray downloads from filling the
/// disk, a file cap keeps quota walks and shell globs cheap, and a temp TTL
/// keeps `tmp/` from accumulating across runs without manual cleanup.
public struct WorkspaceConfig: Sendable, Equatable {
    /// Total bytes permitted under the workspace root. Clamped `10...10240` MB.
    public var quotaMB: Int
    /// Total files permitted under the workspace root. Clamped `100...100000`.
    public var quotaFiles: Int
    /// Days `tmp/` entries survive before pruning. Zero clears on every boot. Clamped `0...90`.
    public var tmpTTLDays: Int

    /// Default size cap keeps scratch generous without risking the disk.
    public static let defaultQuotaMB = 500
    /// Smallest size cap that still fits a working checkout plus outputs.
    public static let minQuotaMB = 10
    /// Largest size cap before scratch rivals the index database scale.
    public static let maxQuotaMB = 10240
    /// Default file cap keeps quota walks bounded on a laptop.
    public static let defaultQuotaFiles = 10000
    /// Fewest files worth configuring before the quota walk is trivial.
    public static let minQuotaFiles = 100
    /// Most files before a quota walk dominates a shell turn.
    public static let maxQuotaFiles = 100_000
    /// Default temp retention keeps a week of scratch for debugging.
    public static let defaultTmpTTLDays = 7
    /// Smallest retention; zero means clear `tmp/` on every boot.
    public static let minTmpTTLDays = 0
    /// Longest retention before `tmp/` reads as storage rather than scratch.
    public static let maxTmpTTLDays = 90

    /// Creates a workspace config.
    public init(
        quotaMB: Int = defaultQuotaMB,
        quotaFiles: Int = defaultQuotaFiles,
        tmpTTLDays: Int = defaultTmpTTLDays
    ) {
        self.quotaMB = quotaMB
        self.quotaFiles = quotaFiles
        self.tmpTTLDays = tmpTTLDays
    }

    /// Returns a copy clamped into the validated ranges.
    /// The engine clamps at use so a hand-built config degrades to the
    /// nearest sane bound instead of refusing to run or oversubscribing;
    /// load-time validation fails closed, and both postures share the same
    /// range constants so they cannot drift.
    /// - Returns: Config with quotas and retention pulled inside bounds.
    public func clamped() -> WorkspaceConfig {
        WorkspaceConfig(
            quotaMB: min(max(quotaMB, Self.minQuotaMB), Self.maxQuotaMB),
            quotaFiles: min(max(quotaFiles, Self.minQuotaFiles), Self.maxQuotaFiles),
            tmpTTLDays: min(max(tmpTTLDays, Self.minTmpTTLDays), Self.maxTmpTTLDays)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case quotaMB
        case quotaFiles
        case tmpTTLDays
    }
}

extension WorkspaceConfig: Codable {
    /// Decodes a workspace config, defaulting every omitted key.
    /// - Parameter decoder: Decoder for the config document.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        quotaMB = try container.decodeIfPresent(Int.self, forKey: .quotaMB) ?? Self.defaultQuotaMB
        quotaFiles = try container.decodeIfPresent(Int.self, forKey: .quotaFiles) ?? Self.defaultQuotaFiles
        tmpTTLDays = try container.decodeIfPresent(Int.self, forKey: .tmpTTLDays) ?? Self.defaultTmpTTLDays
    }

    /// Encodes a workspace config.
    /// - Parameter encoder: Encoder for the config document.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(quotaMB, forKey: .quotaMB)
        try container.encode(quotaFiles, forKey: .quotaFiles)
        try container.encode(tmpTTLDays, forKey: .tmpTTLDays)
    }
}

// MARK: - Subsystem configs (Home, Plugins, Browser, Desktop, Security, Goals, Proactive) live in Config+Subsystems.swift

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
    /// Unified container runtime policy for sandboxed execution.
    /// An absent `[containers]` table keeps the documented defaults; legacy
    /// `[sandbox]` keys are ignored on load with a logged note and never migrated.
    public var containers = ContainersConfig()
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
    /// macOS desktop vision and gated control policy.
    public var desktop = DesktopConfig()
    /// Harness-level defense policy for external content.
    public var security = SecurityConfig()
    /// Steady pursuit of long-horizon goals. Off by default.
    public var goals = GoalsConfig()
    /// Granular shell execution policy.
    public var bash = BashConfig()
    /// Interruption policy for background scheduler and goal turns.
    public var proactive = ProactiveConfig()
    /// Proactive Wayfinder idea suggestions. Off by default.
    public var ideas = IdeasConfig()
    /// Parallel worker fan-out policy. Availability flows through tool registration.
    public var fanOut = FanOutConfig()
    /// Agent scratch quotas and temp retention backing the default shell directory.
    /// An absent `[workspace]` table keeps the documented defaults.
    public var workspace = WorkspaceConfig()
    /// Owner-facing assistant persona woven into the prompt identity line.
    /// An absent `[persona]` table keeps the stock identity and today's prompt bytes.
    public var persona = PersonaConfig()

    /// Creates a root config from section configs.
    public init(
        engine: EngineConfig = EngineConfig(),
        server: ServerEndpointConfig = ServerEndpointConfig(),
        auth: AuthConfig = AuthConfig(),
        llm: LLMConfig = LLMConfig(),
        memory: MemoryConfig = MemoryConfig(),
        voice: VoiceConfig = VoiceConfig(),
        containers: ContainersConfig = ContainersConfig(),
        files: FilesConfig = FilesConfig(),
        email: EmailConfig = EmailConfig(),
        home: HomeConfig = HomeConfig(),
        scheduler: SchedulerConfig = SchedulerConfig(),
        plugins: PluginConfig = PluginConfig(),
        browser: BrowserConfig = BrowserConfig(),
        media: MediaConfig = MediaConfig(),
        index: IndexConfig = IndexConfig(),
        desktop: DesktopConfig = DesktopConfig(),
        security: SecurityConfig = SecurityConfig(),
        goals: GoalsConfig = GoalsConfig(),
        bash: BashConfig = BashConfig(),
        proactive: ProactiveConfig = ProactiveConfig(),
        ideas: IdeasConfig = IdeasConfig(),
        fanOut: FanOutConfig = FanOutConfig(),
        workspace: WorkspaceConfig = WorkspaceConfig(),
        persona: PersonaConfig = PersonaConfig()
    ) {
        self.engine = engine
        self.server = server
        self.auth = auth
        self.llm = llm
        self.memory = memory
        self.voice = voice
        self.containers = containers
        self.files = files
        self.email = email
        self.home = home
        self.scheduler = scheduler
        self.plugins = plugins
        self.browser = browser
        self.media = media
        self.index = index
        self.desktop = desktop
        self.security = security
        self.goals = goals
        self.bash = bash
        self.proactive = proactive
        self.ideas = ideas
        self.fanOut = fanOut
        self.workspace = workspace
        self.persona = persona
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

    private enum CodingKeys: String, CodingKey {
        case engine
        case server
        case auth
        case llm
        case memory
        case voice
        case containers
        case files
        case email
        case home
        case scheduler
        case plugins
        case browser
        case media
        case index
        case desktop
        case security
        case goals
        case bash
        case proactive
        case ideas
        case fanOut = "fanout"
        case workspace
        case persona
    }

    /// Decodes a persisted config, defaulting absent additive sections.
    ///
    /// TOML loading early-returns hardened when the section is missing, so JSON
    /// must match: payloads written before the defense policy, goal pursuit,
    /// proactive surfacing, or idea suggestions existed decode with hardened,
    /// disabled, surfacing, and opt-in defaults instead of throwing.
    /// Present-but-wrong-typed values still throw like every prior section.
    /// Only the security, goals, bash, proactive, ideas, fanout, workspace, persona,
    /// and containers sections are absent-tolerant; every other section decodes
    /// strictly so a truncated payload cannot silently load as hardened defaults.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.engine = try container.decode(EngineConfig.self, forKey: .engine)
        self.server = try container.decode(ServerEndpointConfig.self, forKey: .server)
        self.auth = try container.decode(AuthConfig.self, forKey: .auth)
        self.llm = try container.decode(LLMConfig.self, forKey: .llm)
        self.memory = try container.decode(MemoryConfig.self, forKey: .memory)
        self.voice = try container.decode(VoiceConfig.self, forKey: .voice)
        self.containers = try container.decodeIfPresent(ContainersConfig.self, forKey: .containers) ?? ContainersConfig()
        self.files = try container.decode(FilesConfig.self, forKey: .files)
        self.email = try container.decode(EmailConfig.self, forKey: .email)
        self.home = try container.decode(HomeConfig.self, forKey: .home)
        self.scheduler = try container.decode(SchedulerConfig.self, forKey: .scheduler)
        self.plugins = try container.decode(PluginConfig.self, forKey: .plugins)
        self.browser = try container.decode(BrowserConfig.self, forKey: .browser)
        self.media = try container.decode(MediaConfig.self, forKey: .media)
        self.index = try container.decode(IndexConfig.self, forKey: .index)
        self.desktop = try container.decode(DesktopConfig.self, forKey: .desktop)
        self.security = try container.decodeIfPresent(SecurityConfig.self, forKey: .security) ?? SecurityConfig()
        self.goals = try container.decodeIfPresent(GoalsConfig.self, forKey: .goals) ?? GoalsConfig()
        self.bash = try container.decodeIfPresent(BashConfig.self, forKey: .bash) ?? BashConfig()
        self.proactive = try container.decodeIfPresent(ProactiveConfig.self, forKey: .proactive) ?? ProactiveConfig()
        self.ideas = try container.decodeIfPresent(IdeasConfig.self, forKey: .ideas) ?? IdeasConfig()
        self.fanOut = try container.decodeIfPresent(FanOutConfig.self, forKey: .fanOut) ?? FanOutConfig()
        self.workspace = try container.decodeIfPresent(WorkspaceConfig.self, forKey: .workspace) ?? WorkspaceConfig()
        // Absent persona keeps the stock identity so payloads written before
        // the section existed compose today's prompt byte-for-byte.
        self.persona = try container.decodeIfPresent(PersonaConfig.self, forKey: .persona) ?? PersonaConfig()
    }

    /// Encodes every section, including the defense policy, goal pursuit, proactive surfacing, idea suggestions, workspace, and persona.
    /// - Parameter encoder: Destination encoder.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(engine, forKey: .engine)
        try container.encode(server, forKey: .server)
        try container.encode(auth, forKey: .auth)
        try container.encode(llm, forKey: .llm)
        try container.encode(memory, forKey: .memory)
        try container.encode(voice, forKey: .voice)
        try container.encode(containers, forKey: .containers)
        try container.encode(files, forKey: .files)
        try container.encode(email, forKey: .email)
        try container.encode(home, forKey: .home)
        try container.encode(scheduler, forKey: .scheduler)
        try container.encode(plugins, forKey: .plugins)
        try container.encode(browser, forKey: .browser)
        try container.encode(media, forKey: .media)
        try container.encode(index, forKey: .index)
        try container.encode(desktop, forKey: .desktop)
        try container.encode(security, forKey: .security)
        try container.encode(goals, forKey: .goals)
        try container.encode(bash, forKey: .bash)
        try container.encode(proactive, forKey: .proactive)
        try container.encode(ideas, forKey: .ideas)
        try container.encode(fanOut, forKey: .fanOut)
        try container.encode(workspace, forKey: .workspace)
        try container.encode(persona, forKey: .persona)
    }
}

// MARK: - TOML serialization lives in Config+Serialization.swift

// MARK: - Validation lives in Config+Validation.swift

// MARK: - TOML decoding lives in ConfigTOML.swift

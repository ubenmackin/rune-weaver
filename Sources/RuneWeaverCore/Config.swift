// Rune Weaver Core — Configuration types and loader for config.toml.
//
// Defines the `RuneWeaverConfig` section model (engine, LLM providers,
// memory, voice, sandbox, files policy, email, home, scheduler, plugins)
// plus `ConfigError`, built-in defaults, and the load-and-validate entry
// points. TOML parsing lives in `ConfigTOML`, validation in
// `Config+Validation`, and serialization in `Config+Serialization`; this
// file owns the schema those stages map onto.
import Foundation

/// Errors thrown while loading or validating `config.toml`.
///
/// Each case carries the context needed to tell the user exactly which
/// file, line, or field is wrong so misconfiguration is quick to fix.
public enum ConfigError: Error, Sendable, Equatable {
    /// The config file does not exist at the expected path.
    case fileNotFound(path: String)
    /// The file exists but could not be read or decoded as UTF-8.
    case unreadable(path: String, reason: String)
    /// A TOML syntax problem.
    /// - Parameters:
    ///   - line: 1-based line number.
    ///   - message: What was wrong.
    case parseError(line: Int, message: String)
    /// A required field is absent.
    /// - Parameter field: Dotted field path (e.g. `llm.default_provider`).
    case missingRequired(field: String)
    /// A field value failed validation.
    /// - Parameters:
    ///   - field: Dotted field path.
    ///   - message: Why the value is invalid.
    case validationError(field: String, message: String)
}

// MARK: - Section structs

/// `[engine]` — top-level engine identity and logging.
public struct EngineConfig: Sendable, Codable, Equatable {
    /// Human-readable engine name shown in clients.
    public var name: String
    /// Log level: trace, debug, info, notice, warning, error, or critical.
    public var logLevel: String

    /// Creates an engine config.
    /// - Parameters:
    ///   - name: Engine display name.
    ///   - logLevel: Log level string.
    public init(name: String = "Rune Weaver", logLevel: String = "info") {
        self.name = name
        self.logLevel = logLevel
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case logLevel = "log_level"
    }
}

/// OpenAI-compatible request style for a provider entry.
///
/// Chat Completions posts to `/chat/completions`; Responses posts to
/// `/responses`. Most providers use Chat Completions.
public enum APIStyle: String, Sendable, Codable, CaseIterable {
    /// Chat Completions API (`POST /chat/completions`). Default.
    case chatCompletions = "chat-completions"
    /// Responses API (`POST /responses`).
    case responses
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
    ///
    /// Nil means provider-default: the factory resolves an absent
    /// `context_length` to the backend's own default (MLX 8192,
    /// llama.cpp 4096, OpenAI-compatible 128000) instead of forcing a
    /// global value into local windows. The default is nil so an
    /// omitted key never overstates a local window. Pass an explicit
    /// value to override. Displayed as the denominator in the chat
    /// usage line and reported via `ModelInfo.contextLength` once
    /// resolved.
    public var contextLength: Int?

    /// Creates a provider config.
    public init(
        enabled: Bool = true,
        model: String? = nil,
        serverURL: String? = nil,
        apiKeyEnv: String? = nil,
        providerType: String? = nil,
        apiStyle: APIStyle = .chatCompletions,
        contextLength: Int? = nil
    ) {
        self.enabled = enabled
        self.model = model
        self.serverURL = serverURL
        self.apiKeyEnv = apiKeyEnv
        self.providerType = providerType
        self.apiStyle = apiStyle
        self.contextLength = contextLength
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case model
        case serverURL = "server_url"
        case apiKeyEnv = "api_key_env"
        case providerType = "provider_type"
        case apiStyle = "api_style"
        case contextLength = "context_length"
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
    ///
    /// Reserved for future small/embedding-model support and ignored by the
    /// `apple`, `provider`, and `none` backends today: `apple` uses the fixed
    /// on-device model, `provider` reuses the active chat model, and `none`
    /// stays keyword-only. Still required non-empty so older configs load.
    public var embeddingModel: String
    /// Embedding backend selector.
    ///
    /// `apple` keeps vectors on-device by default, `provider` reuses the
    /// configured LLM embeddings, and `none` stays keyword-only. The
    /// default preserves local-first behavior for existing installs.
    public var embeddingBackend: String

    /// `embedding_backend` selector that disables vectors (keyword-only recall).
    ///
    /// Named constants keep every selector's spelling in one place so config
    /// defaults, validation, the Settings API, and backend construction cannot
    /// drift to mismatched literals.
    public static let embeddingBackendNone = "none"
    /// `embedding_backend` selector that keeps vectors on-device via NaturalLanguage.
    public static let embeddingBackendApple = "apple"
    /// `embedding_backend` selector that reuses the configured LLM embeddings endpoint.
    public static let embeddingBackendProvider = "provider"

    /// Closed set of valid `embedding_backend` selectors.
    ///
    /// Single source for config validation, the Settings API, and backend
    /// construction so the paths never drift on which backends are accepted
    /// or how each selector maps to a concrete backend.
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
    ///
    /// Older payloads predate the backend selector, so only the new key is
    /// lenient; every other key stays strict to surface typos instead of
    /// silently falling back.
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
///
/// Archives detonate in zero-host-mounts ephemeral microVMs with manifest-only
/// returns. Each detonation is ephemeral and reaped immediately after
/// listing/extraction; `archiveSessionTTLMinutes` bounds only crash-orphan
/// reclamation via the periodic prune, and `maxConcurrentMachines` caps
/// concurrent detonations before spawn.
///
/// Legacy staging keys (`staging_path`, `retention_days`, `max_total_bytes`,
/// `cleanup_interval_seconds`) from older files are ignored with no crash and
/// no migration: document writes use Seatbelt-confined temp with an atomic
/// move on approval, so old dev-only staging directories are left untouched
/// for manual cleanup.
public struct SandboxConfig: Sendable, Equatable {
    /// Apple Container CLI runtime, hardcoded to `defaultContainerRuntime`.
    ///
    /// Tier 3 detonation only supports the Apple Container CLI, so there is
    /// no TOML, Settings API, or CLI surface to change it. Legacy
    /// `container_runtime` values in old files are ignored and this accessor
    /// always returns the constant so every caller shares one spelling.
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
    /// - Parameters:
    ///   - containerBaseImage: OCI image for detonation.
    ///   - archiveSessionTTLMinutes: Crash-orphan reclamation TTL in minutes for ephemeral detonation machines.
    ///   - maxConcurrentMachines: Cap on concurrent detonation machines, enforced before spawn.
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
    /// Decodes a sandbox config, defaulting payloads without the Tier-3 keys.
    ///
    /// Legacy staging and retention keys in old JSON payloads are ignored:
    /// unknown keys never decode, so old files keep loading with Tier-3
    /// defaults instead of failing the load.
    /// - Parameter decoder: Decoder for the config document.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Legacy `container_runtime` keys in old JSON payloads are ignored:
        // unknown keys never decode, so detonation stays pinned to the Apple
        // Container CLI instead of failing the load.
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
///
/// The deny list is enforced by the shared file access guard (dot-env
/// family, known secret filenames, private-key suffixes, keychain names,
/// SSH/AWS directories, and the vector store) so the dashboard shows the
/// same boundary the tools enforce. `allowRoots` pins the containment
/// boundary (`~` by default); paths resolving outside these roots are
/// denied. `requireApprovalOnDeny` keeps denials approval-gated instead of
/// silently dropping them. Changes apply on restart so running tools never
/// see a half-written policy.
public struct FilesConfig: Sendable, Equatable {
    /// Glob deny patterns enforced by the shared file access guard.
    public var denyPatterns: [String]
    /// Allowed root directories for file reads (`~` expands to home).
    public var allowRoots: [String]
    /// Whether deny hits escalate to approval instead of hard denial.
    public var requireApprovalOnDeny: Bool

    /// Default deny patterns enforced by the shared file access guard.
    ///
    /// Single source of the default boundary: the guard consumes these
    /// (via its `FilesConfig` parameter) instead of keeping a parallel
    /// hardcoded list, so config edits and code defaults cannot drift.
    /// Mirrored by `DEFAULT_FILES_DENY_PATTERNS` in `Web/src/api.ts`;
    /// keep the two pinned equal.
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
    ///
    /// Mirrored by `DEFAULT_FILES_ALLOW_ROOTS` in `Web/src/api.ts`; keep
    /// the two pinned equal.
    public static let defaultAllowRoots = ["~"]
    /// Default escalation for deny hits.
    public static let defaultRequireApprovalOnDeny = true

    /// Creates a files config.
    /// - Parameters:
    ///   - denyPatterns: Deny patterns enforced by the guard. Defaults to the shared default list.
    ///   - allowRoots: Allowed roots. Defaults to home (`~`).
    ///   - requireApprovalOnDeny: Whether denials escalate. Defaults to true.
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
    /// Decodes a files config, defaulting legacy payloads without the newer keys.
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

/// SMTP transport security for an `[[email.accounts]]` entry.
///
/// `auto` tries STARTTLS on submission first and falls back to implicit
/// TLS so unset accounts keep working without manual tuning; `starttls`
/// pins STARTTLS and `ssl` pins implicit TLS. Unknown strings fail closed
/// at decode and validation time instead of silently picking a mode.
public enum EmailSMTPSecurity: String, Sendable, Codable, Equatable, CaseIterable {
    /// Implicit TLS (typically port 465).
    case ssl
    /// STARTTLS upgrade (typically port 587).
    case starttls
    /// Try STARTTLS first, then implicit TLS. Default for unset accounts.
    case auto

    /// Whether this mode expects implicit TLS on connect.
    ///
    /// Only `ssl` dials TLS immediately; `starttls` and `auto` start
    /// cleartext and upgrade, with `auto` retrying the alternate port on
    /// failure.
    public var usesImplicitTLS: Bool {
        self == .ssl
    }
}

/// One `[[email.accounts]]` entry. Passwords live in the Keychain,
/// never in TOML.
///
/// The password is resolved at runtime from ``EmailAccount/passwordEnvVar``
/// via `SecretsManager` (environment first, Keychain service
/// `com.runeweaver.secrets` second), mirroring
/// `ProviderConfig.apiKeyEnv`. Only host, port, username, and the
/// variable name are ever echoed; the secret value is never logged.
/// Optional `smtp_host`, `smtp_port`, and `smtp_security` override the
/// derived submission endpoint; when absent the sender falls back to the
/// IMAP host on 587 STARTTLS then 465 SSL with verified TLS only.
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
        let trimmedHost = smtpHost?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.smtpHost = (trimmedHost?.isEmpty == false) ? trimmedHost : nil
        self.smtpPort = smtpPort
        self.smtpSecurity = smtpSecurity
    }

    /// Environment variable holding this account's password.
    ///
    /// Resolved at runtime via `SecretsManager`; the value itself never
    /// appears in TOML or `config show` output.
    public var passwordEnvVar: String {
        Self.passwordEnvVar(forAccountNamed: name)
    }

    /// Environment variable name for an account's password.
    /// - Parameter name: Account nickname (e.g. `icloud`).
    /// - Returns: `EMAIL_<UPPERCASED_NAME>_PASSWORD` with each
    ///   non-alphanumeric character mapped to `_` so every nickname maps
    ///   to a valid variable name.
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
    /// Decodes an account, defaulting legacy payloads without SMTP overrides.
    ///
    /// Absent `smtp_host`/`smtp_port` stay nil (derived fallback) and an
    /// absent `smtp_security` stays `auto`; blank `smtp_host` collapses to
    /// nil so empty dashboard rows never persist a meaningless override.
    /// - Parameter decoder: Decoder for the account document.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? "imap"
        host = try container.decode(String.self, forKey: .host)
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 993
        username = try container.decode(String.self, forKey: .username)
        let rawHost = try container.decodeIfPresent(String.self, forKey: .smtpHost)
        let trimmedHost = rawHost?.trimmingCharacters(in: .whitespacesAndNewlines)
        smtpHost = (trimmedHost?.isEmpty == false) ? trimmedHost : nil
        smtpPort = try container.decodeIfPresent(Int.self, forKey: .smtpPort)
        smtpSecurity = try container.decodeIfPresent(EmailSMTPSecurity.self, forKey: .smtpSecurity) ?? .auto
    }

    /// Encodes an account, omitting unset SMTP overrides.
    ///
    /// `smtp_host`/`smtp_port` encode only when set and `smtp_security`
    /// only when non-`auto` so legacy payloads round-trip without new keys
    /// while explicit overrides survive.
    /// - Parameter encoder: Encoder for the account document.
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
///
/// Passwords are not stored here; each account's password is resolved at
/// runtime from `EmailAccount.passwordEnvVar` via `SecretsManager`.
public struct EmailConfig: Sendable, Codable, Equatable {
    /// Configured mail accounts.
    public var accounts: [EmailAccount]

    /// SMTP submission ports honored across validation and sending.
    ///
    /// Single source for `RuneWeaverConfig` validation (`Config+Validation`)
    /// and `EmailSMTPBridge.submissionPorts` (RuneWeaverTools), which aliases
    /// this set so the two Swift copies cannot drift. The embedded Python
    /// SMTP helper (`EmailSMTPBridgeScript.source`) mirrors the same four
    /// ports; keep all three equal when changing this list.
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
    ///
    /// Single-sources the exact-then-case-insensitive lookup shared by the
    /// email tools so account resolution never drifts between call sites.
    /// - Parameter name: Trimmed account nickname.
    /// - Returns: Matching account, or `nil` when absent.
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

// MARK: - Root config

/// Root configuration mirroring `~/.runeweaver/config.toml`.
///
/// Load with ``RuneWeaverConfig/load(from:)`` for a one-shot read or
/// ``ConfigLoader`` for a hot-reloading snapshot. Every load is
/// validated; invalid files throw ``ConfigError`` with a clear field
/// path instead of silently falling back.
public struct RuneWeaverConfig: Sendable, Codable, Equatable {
    /// Engine identity and logging.
    public var engine: EngineConfig
    /// LLM provider selection.
    public var llm: LLMConfig
    /// Memory storage locations.
    public var memory: MemoryConfig
    /// Voice pipeline providers.
    public var voice: VoiceConfig
    /// Sandbox staging and trust policy.
    public var sandbox: SandboxConfig
    /// File-tool access policy (deny list plus allowed roots).
    ///
    /// Declared with a default so JSON payloads predating the `[files]`
    /// section still decode; TOML decoding applies the same default when
    /// the table is absent.
    public var files = FilesConfig()
    /// Mail accounts.
    public var email: EmailConfig
    /// Home automation.
    public var home: HomeConfig
    /// Scheduled jobs (cron and email-arrival triggers).
    public var scheduler: SchedulerConfig
    /// Plugin discovery and marketplace settings.
    public var plugins: PluginConfig

    /// Creates a root config from section configs.
    public init(
        engine: EngineConfig = EngineConfig(),
        llm: LLMConfig = LLMConfig(),
        memory: MemoryConfig = MemoryConfig(),
        voice: VoiceConfig = VoiceConfig(),
        sandbox: SandboxConfig = SandboxConfig(),
        files: FilesConfig = FilesConfig(),
        email: EmailConfig = EmailConfig(),
        home: HomeConfig = HomeConfig(),
        scheduler: SchedulerConfig = SchedulerConfig(),
        plugins: PluginConfig = PluginConfig()
    ) {
        self.engine = engine
        self.llm = llm
        self.memory = memory
        self.voice = voice
        self.sandbox = sandbox
        self.files = files
        self.email = email
        self.home = home
        self.scheduler = scheduler
        self.plugins = plugins
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
    ///
    /// When the file is absent, returns ``RuneWeaverConfig/default``
    /// so a fresh install works before the user has written any TOML.
    /// - Returns: Validated config.
    public static func loadDefault() throws -> RuneWeaverConfig {
        let url = defaultConfigFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .default
        }
        return try load(from: url)
    }

    /// Loads and validates the config at the given file URL.
    /// - Parameter fileURL: TOML file to read.
    /// - Returns: Validated config.
    /// - Throws: ``ConfigError`` when the file is missing, unreadable,
    ///   unparsable, or fails validation.
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

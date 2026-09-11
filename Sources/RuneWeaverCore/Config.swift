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
    /// Local server URL (MLX / llama.cpp / vLLM).
    public var serverURL: String?
    /// Cloud base URL (OpenAI-compatible endpoints).
    public var baseURL: String?
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
        baseURL: String? = nil,
        apiKeyEnv: String? = nil,
        providerType: String? = nil,
        apiStyle: APIStyle = .chatCompletions,
        contextLength: Int? = nil
    ) {
        self.enabled = enabled
        self.model = model
        self.serverURL = serverURL
        self.baseURL = baseURL
        self.apiKeyEnv = apiKeyEnv
        self.providerType = providerType
        self.apiStyle = apiStyle
        self.contextLength = contextLength
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case model
        case serverURL = "server_url"
        case baseURL = "base_url"
        case apiKeyEnv = "api_key_env"
        case providerType = "provider_type"
        case apiStyle = "api_style"
        case contextLength = "context_length"
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
    /// JSON keyword store path for semantic memory (LanceDB-compatible shape; vectors deferred).
    public var vectorDBPath: String
    /// SQLite path for episodic memory.
    public var episodesDBPath: String
    /// Embedding model identifier.
    public var embeddingModel: String

    /// Creates a memory config.
    public init(
        vectorDBPath: String = "~/.runeweaver/memory/vectors",
        episodesDBPath: String = "~/.runeweaver/memory/episodes.db",
        embeddingModel: String = "all-MiniLM-L6-v2"
    ) {
        self.vectorDBPath = vectorDBPath
        self.episodesDBPath = episodesDBPath
        self.embeddingModel = embeddingModel
    }

    private enum CodingKeys: String, CodingKey {
        case vectorDBPath = "vector_db_path"
        case episodesDBPath = "episodes_db_path"
        case embeddingModel = "embedding_model"
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

/// `[sandbox]` — staging area and trust escalation policy.
public struct SandboxConfig: Sendable, Codable, Equatable {
    /// Staging directory for file writes awaiting approval.
    public var stagingPath: String
    /// Successful executions before a write may auto-approve.
    public var autoApproveAfter: Int

    /// Creates a sandbox config.
    public init(
        stagingPath: String = "~/.runeweaver/sandbox",
        autoApproveAfter: Int = 5
    ) {
        self.stagingPath = stagingPath
        self.autoApproveAfter = autoApproveAfter
    }

    private enum CodingKeys: String, CodingKey {
        case stagingPath = "staging_path"
        case autoApproveAfter = "auto_approve_after"
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
public struct EmailAccount: Sendable, Codable, Equatable {
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

    /// Creates an email account entry.
    public init(
        name: String,
        type: String = "imap",
        host: String,
        port: Int = 993,
        username: String
    ) {
        self.name = name
        self.type = type
        self.host = host
        self.port = port
        self.username = username
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
    }
}

/// `[email]` — mail accounts.
///
/// Passwords are not stored here; each account's password is resolved at
/// runtime from `EmailAccount.passwordEnvVar` via `SecretsManager`.
public struct EmailConfig: Sendable, Codable, Equatable {
    /// Configured mail accounts.
    public var accounts: [EmailAccount]

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
    /// Mail accounts.
    public var email: EmailConfig
    /// Home automation.
    public var home: HomeConfig

    /// Creates a root config from section configs.
    public init(
        engine: EngineConfig = EngineConfig(),
        llm: LLMConfig = LLMConfig(),
        memory: MemoryConfig = MemoryConfig(),
        voice: VoiceConfig = VoiceConfig(),
        sandbox: SandboxConfig = SandboxConfig(),
        email: EmailConfig = EmailConfig(),
        home: HomeConfig = HomeConfig()
    ) {
        self.engine = engine
        self.llm = llm
        self.memory = memory
        self.voice = voice
        self.sandbox = sandbox
        self.email = email
        self.home = home
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
                        baseURL: "https://openrouter.ai/api/v1",
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

    /// Validates every section, throwing a descriptive error on failure.
    /// - Throws: ``ConfigError/validationError(field:message:)`` or
    ///   ``ConfigError/missingRequired(field:)``.
    public func validate() throws {
        try validateEngineSection()
        try validateLLMSection()
        try validateMemorySection()
        try validateVoiceSection()
        try validateSandboxSection()
        try validateEmailSection()
        try validateHomeSection()
    }

    private func validateEngineSection() throws {
        if engine.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ConfigError.validationError(field: "engine.name", message: "must not be empty")
        }
        let allowedLevels = ["trace", "debug", "info", "notice", "warning", "error", "critical"]
        if !allowedLevels.contains(engine.logLevel.lowercased()) {
            throw ConfigError.validationError(
                field: "engine.log_level",
                message: "must be one of \(allowedLevels.joined(separator: ", "))"
            )
        }
    }

    private func validateLLMSection() throws {
        if llm.defaultProvider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ConfigError.missingRequired(field: "llm.default_provider")
        }
        if let fallback = llm.fallbackProvider,
           fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            throw ConfigError.validationError(
                field: "llm.fallback_provider", message: "must not be empty when set"
            )
        }
        guard llm.providers[llm.defaultProvider] != nil else {
            throw ConfigError.validationError(
                field: "llm.default_provider",
                message: "unknown provider '\(llm.defaultProvider)' (missing [llm.providers.\(llm.defaultProvider)])"
            )
        }
        if let fallback = llm.fallbackProvider {
            guard llm.providers[fallback] != nil else {
                throw ConfigError.validationError(
                    field: "llm.fallback_provider",
                    message: "unknown provider '\(fallback)' (missing [llm.providers.\(fallback)])"
                )
            }
        }
        for (name, provider) in llm.providers {
            try validateProvider(provider, name: name)
        }
    }

    private func validateProvider(_ provider: ProviderConfig, name: String) throws {
        let prefix = "llm.providers.\(name)"
        if let model = provider.model, model.isEmpty {
            throw ConfigError.validationError(
                field: "\(prefix).model", message: "must not be empty when set"
            )
        }
        if let length = provider.contextLength, length <= 0 {
            throw ConfigError.validationError(
                field: "\(prefix).context_length", message: "must be positive"
            )
        }
        if let serverURL = provider.serverURL {
            try Self.validateURLField(serverURL, field: "\(prefix).server_url")
        }
        if let baseURL = provider.baseURL {
            try Self.validateURLField(baseURL, field: "\(prefix).base_url")
        }
        if let env = provider.apiKeyEnv, env.isEmpty {
            throw ConfigError.validationError(
                field: "\(prefix).api_key_env", message: "must not be empty when set"
            )
        }
        if let type = provider.providerType, type.isEmpty {
            throw ConfigError.validationError(
                field: "\(prefix).provider_type", message: "must not be empty when set"
            )
        }
    }

    private func validateMemorySection() throws {
        if memory.vectorDBPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ConfigError.validationError(
                field: "memory.vector_db_path", message: "must not be empty"
            )
        }
        if memory.episodesDBPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ConfigError.validationError(
                field: "memory.episodes_db_path", message: "must not be empty"
            )
        }
        if memory.embeddingModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ConfigError.validationError(
                field: "memory.embedding_model", message: "must not be empty"
            )
        }
    }

    private func validateVoiceSection() throws {
        if voice.sttProvider.isEmpty {
            throw ConfigError.validationError(
                field: "voice.stt_provider", message: "must not be empty"
            )
        }
        if voice.whisperModel.isEmpty {
            throw ConfigError.validationError(
                field: "voice.whisper_model", message: "must not be empty"
            )
        }
        if voice.ttsProvider.isEmpty {
            throw ConfigError.validationError(
                field: "voice.tts_provider", message: "must not be empty"
            )
        }
    }

    private func validateSandboxSection() throws {
        if sandbox.stagingPath.isEmpty {
            throw ConfigError.validationError(
                field: "sandbox.staging_path", message: "must not be empty"
            )
        }
        if sandbox.autoApproveAfter < 0 {
            throw ConfigError.validationError(
                field: "sandbox.auto_approve_after", message: "must be zero or positive"
            )
        }
    }

    private func validateEmailSection() throws {
        for account in email.accounts {
            try validateEmailAccount(account)
        }
    }

    private func validateEmailAccount(_ account: EmailAccount) throws {
        let prefix = "email.accounts[\(account.name)]"
        if account.name.isEmpty {
            throw ConfigError.validationError(
                field: "email.accounts.name", message: "must not be empty"
            )
        }
        if account.host.isEmpty {
            throw ConfigError.validationError(
                field: "\(prefix).host", message: "must not be empty"
            )
        }
        if account.username.isEmpty {
            throw ConfigError.validationError(
                field: "\(prefix).username", message: "must not be empty"
            )
        }
        if account.port < 1 || account.port > 65535 {
            throw ConfigError.validationError(
                field: "\(prefix).port", message: "must be between 1 and 65535"
            )
        }
    }

    private func validateHomeSection() throws {
        for entry in home.homeAssistant {
            if let url = entry.url {
                try Self.validateURLField(url, field: "home.home_assistant.url")
            }
            if let env = entry.tokenEnv, env.isEmpty {
                throw ConfigError.validationError(
                    field: "home.home_assistant.token_env",
                    message: "must not be empty when set"
                )
            }
        }
    }

    private static func validateURLField(_ value: String, field: String) throws {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ConfigError.validationError(field: field, message: "must not be empty when set")
        }
        guard let url = URL(string: value), url.scheme != nil, url.host != nil else {
            throw ConfigError.validationError(
                field: field, message: "must be an absolute URL (e.g. http://localhost:8080)"
            )
        }
    }
}

// MARK: - Hot-reloading loader

/// Loads `config.toml` and keeps the snapshot fresh via a file watcher.
///
/// The loader holds the last validated snapshot. Call ``ConfigLoader/load()``
/// to re-read on demand, or ``ConfigLoader/startWatching()`` to reload
/// automatically when the file changes. Invalid reloads keep the previous
/// good snapshot and report the error through `onError` instead of
/// replacing working config with a broken one.
public final class ConfigLoader: @unchecked Sendable {
    /// File being watched.
    public let fileURL: URL
    /// Last validated snapshot. Thread-safe via an internal lock.
    public var config: RuneWeaverConfig {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    /// Called on the watcher queue after a successful reload.
    /// Set before calling `startWatching()`.
    public var onChange: (@Sendable (RuneWeaverConfig) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return changeHandler
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            changeHandler = newValue
        }
    }

    /// Called on the watcher queue when a reload fails. The previous
    /// snapshot stays in effect. Set before calling `startWatching()`.
    public var onError: (@Sendable (Error) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return errorHandler
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            errorHandler = newValue
        }
    }

    private let lock = NSLock()
    private var snapshot: RuneWeaverConfig
    private var changeHandler: (@Sendable (RuneWeaverConfig) -> Void)?
    private var errorHandler: (@Sendable (Error) -> Void)?
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: CInt = -1
    private var isStartingWatch = false
    private let queue = DispatchQueue(label: "com.runeweaver.config-watcher")

    /// Creates a loader and performs the initial load.
    ///
    /// A missing file yields ``RuneWeaverConfig/default``; an existing
    /// but invalid file throws.
    /// - Parameter fileURL: Config file. Defaults to
    ///   `~/.runeweaver/config.toml`.
    public init(fileURL: URL? = nil) throws {
        let resolved = fileURL ?? RuneWeaverConfig.defaultConfigFileURL()
        self.fileURL = resolved
        if FileManager.default.fileExists(atPath: resolved.path) {
            self.snapshot = try RuneWeaverConfig.load(from: resolved)
        } else {
            self.snapshot = .default
        }
    }

    deinit {
        stopWatching()
    }

    /// Re-reads the file, validates, and replaces the snapshot.
    /// - Returns: The new snapshot.
    /// - Throws: ``ConfigError`` on failure. The old snapshot is kept.
    @discardableResult
    public func load() throws -> RuneWeaverConfig {
        let fresh: RuneWeaverConfig = if FileManager.default.fileExists(atPath: fileURL.path) {
            try RuneWeaverConfig.load(from: fileURL)
        } else {
            .default
        }
        lock.lock()
        snapshot = fresh
        lock.unlock()
        return fresh
    }

    /// Starts hot-reloading. Safe to call repeatedly; the second call
    /// is a no-op. Set `onChange`/`onError` before calling.
    ///
    /// Creation is serialized: a lock-guarded `isStartingWatch` flag is
    /// set synchronously so concurrent callers collapse into one watcher
    /// instead of each passing the `source == nil` check and leaking a
    /// `DispatchSource` plus file descriptor. All `source` /
    /// `fileDescriptor` mutations happen under the lock on the watcher
    /// queue.
    public func startWatching() {
        lock.lock()
        guard source == nil, !isStartingWatch else {
            lock.unlock()
            return
        }
        isStartingWatch = true
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            let path = self.fileURL.path
            guard FileManager.default.fileExists(atPath: path) else {
                self.lock.lock()
                self.isStartingWatch = false
                self.lock.unlock()
                return
            }
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else {
                self.lock.lock()
                self.isStartingWatch = false
                self.lock.unlock()
                return
            }
            self.lock.lock()
            // A concurrent stopWatching() may have run while we opened
            // the file descriptor; do not leak it.
            if self.source != nil {
                self.lock.unlock()
                close(fd)
                self.lock.lock()
                self.isStartingWatch = false
                self.lock.unlock()
                return
            }
            let watcher = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .extend, .attrib, .rename, .revoke, .delete],
                queue: self.queue
            )
            watcher.setEventHandler { [weak self] in
                guard let self else { return }
                do {
                    let fresh = try self.load()
                    self.onChange?(fresh)
                } catch {
                    self.onError?(error)
                }
            }
            watcher.setCancelHandler { [fd] in
                close(fd)
            }
            watcher.resume()
            self.source = watcher
            self.fileDescriptor = fd
            self.isStartingWatch = false
            self.lock.unlock()
        }
    }

    /// Stops hot-reloading. Safe to call when not watching.
    public func stopWatching() {
        // Cancel off the watcher queue to avoid a sync deadlock when
        // invoked from deinit or from within the event handler.
        let watcher: DispatchSourceFileSystemObject? = {
            lock.lock()
            defer { lock.unlock() }
            let existing = source
            source = nil
            fileDescriptor = -1
            isStartingWatch = false
            return existing
        }()
        watcher?.cancel()
    }
}

// MARK: - TOML decoding lives in ConfigTOML.swift

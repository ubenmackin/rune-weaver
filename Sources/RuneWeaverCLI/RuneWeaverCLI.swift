// Rune Weaver CLI — Shared terminal helpers and tool-bus wiring.

import Foundation
import os
import RuneWeaverCore
import RuneWeaverLLM
import RuneWeaverTools

/// Shared terminal styling, config loading, and provider wiring.
enum TerminalStyle {
    /// Whether ANSI colors may be emitted. Honors `NO_COLOR`.
    static var isColorEnabled: Bool {
        ProcessInfo.processInfo.environment["NO_COLOR"] == nil
    }

    /// Wraps text in the given ANSI code.
    static func wrap(_ text: String, _ code: String) -> String {
        guard isColorEnabled else { return text }
        return "\u{001B}[\(code)m\(text)\u{001B}[0m"
    }

    /// Styles user prompts and labels (green, bold).
    /// - Parameter text: Text to style.
    /// - Returns: Styled text.
    static func user(_ text: String) -> String {
        wrap(text, "32;1")
    }

    /// Styles assistant output labels (cyan, bold).
    /// - Parameter text: Text to style.
    /// - Returns: Styled text.
    static func assistant(_ text: String) -> String {
        wrap(text, "36;1")
    }

    /// Styles tool-call visibility lines (yellow).
    /// - Parameter text: Text to style.
    /// - Returns: Styled text.
    static func tool(_ text: String) -> String {
        wrap(text, "33")
    }

    /// Styles secondary text such as hints and metadata (dim).
    /// - Parameter text: Text to style.
    /// - Returns: Styled text.
    static func dim(_ text: String) -> String {
        wrap(text, "2")
    }

    /// Styles errors (red, bold).
    /// - Parameter text: Text to style.
    /// - Returns: Styled text.
    static func error(_ text: String) -> String {
        wrap(text, "31;1")
    }

    /// Styles success confirmations (green).
    /// - Parameter text: Text to style.
    /// - Returns: Styled text.
    static func success(_ text: String) -> String {
        wrap(text, "32")
    }

    /// Styles bold text.
    /// - Parameter text: Text to style.
    /// - Returns: Styled text.
    static func bold(_ text: String) -> String {
        wrap(text, "1")
    }
}

/// Resolves and loads `config.toml` for CLI commands.
enum CLIConfigLoader {
    /// Config plus the file URL it came from (or would live at).
    struct LoadedConfig {
        /// Validated config (built-in defaults when no file exists).
        let config: RuneWeaverConfig
        /// Resolved config file URL.
        let url: URL
        /// Whether built-in defaults were used because no file exists.
        let isFallback: Bool
    }

    /// Resolves the config file URL, expanding `~`.
    /// - Parameter path: Explicit `--config` value, if any.
    /// - Returns: File URL to load.
    static func configFileURL(for path: String?) -> URL {
        guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return RuneWeaverConfig.defaultConfigFileURL()
        }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    /// Loads the config, falling back to built-in defaults only when no
    /// file exists and no explicit path was given.
    static func loadConfig(path: String?) throws -> LoadedConfig {
        let url = configFileURL(for: path)
        if FileManager.default.fileExists(atPath: url.path) {
            return try LoadedConfig(config: RuneWeaverConfig.load(from: url), url: url, isFallback: false)
        }
        if path != nil {
            throw ConfigError.fileNotFound(path: url.path)
        }
        return try LoadedConfig(config: RuneWeaverConfig.loadDefault(), url: url, isFallback: true)
    }
}

/// Builds live LLM providers from the `[llm]` config section.
enum CLIProviderBuilder {
    /// Builds every enabled provider, resolving API keys from the
    /// environment first with a Keychain fallback via `SecretsManager`.
    static func buildProviders(from llm: LLMConfig) async -> [any LLMProvider] {
        let secrets = SecretsManager()
        var keysByEntry: [String: String] = [:]
        for (entryName, entry) in llm.providers {
            guard let envVar = entry.apiKeyEnv, !envVar.isEmpty else { continue }
            if let key = LLMProviderFactory.resolveAPIKey(explicit: nil, envVar: envVar) {
                keysByEntry[entryName] = key
            } else if let stored = try? await secrets.retrieve(key: envVar) {
                keysByEntry[entryName] = stored
            }
        }
        return LLMProviderFactory.makeProviders(from: llm, apiKeysByEntry: keysByEntry)
    }

    /// Selects the active provider: `--provider` override first (matched against the provider name,
    /// its local aliases, then the model name), then `default_provider`, then `fallback_provider`,
    /// then first enabled.
    static func selectProvider(
        named override: String?,
        from providers: [any LLMProvider],
        config: LLMConfig
    ) -> (any LLMProvider)? {
        LLMProviderFactory.selectProvider(named: override, from: providers, config: config)
    }

    /// Whether a provider matches a configured/CLI name, including the
    /// local-backend aliases (`llamacpp`, `llama-cpp`, `llama_cpp`,
    /// `local` all match each other). Comparison is case-insensitive.
    static func matchesProvider(_ provider: any LLMProvider, wanted: String) -> Bool {
        LLMProviderFactory.matchesProvider(provider, wanted: wanted)
    }
}

/// Compiler-checked lock-guarded box for CLI shared state.
final class CLILockedValue<Value: Sendable>: Sendable {
    /// Guards `value`.
    private let lock: OSAllocatedUnfairLock<Value>

    /// Creates a box.
    /// - Parameter value: Initial value.
    init(_ value: Value) {
        self.lock = OSAllocatedUnfairLock(initialState: value)
    }

    /// Runs `body` with exclusive access to the value.
    /// - Parameter body: Mutation or read to perform while locked.
    /// - Returns: Body result.
    func withLock<T: Sendable>(_ body: @Sendable (inout Value) throws -> T) rethrows -> T {
        try lock.withLock(body)
    }
}

/// Single shared store source for the CLI process.
enum CLIShared {
    /// Cached engines keyed by episodes, vector, and document index paths.
    private static let engines = CLILockedValue<[String: MemoryEngine]>([:])

    /// Returns the shared engine for the given memory config,
    /// creating and caching it on first use.
    ///
    /// The optional document index path points recall at the configured
    /// `[index]` database; nil keeps the keyword-and-vector engine.
    /// - Parameters:
    ///   - config: Memory paths from `config.toml`.
    ///   - docIndexDBPath: SQLite path for the document index, or nil for recall without it.
    /// - Returns: The cached engine for these paths.
    static func memoryEngine(for config: MemoryConfig, docIndexDBPath: String? = nil) -> MemoryEngine {
        let key = "\(config.episodesDBPath)\0\(config.vectorDBPath)\0\(docIndexDBPath ?? "")"
        return engines.withLock { cached in
            if let existing = cached[key] {
                return existing
            }
            let engine = if let docIndexDBPath {
                MemoryEngine(
                    episodesDBPath: config.episodesDBPath,
                    vectorDBPath: config.vectorDBPath,
                    docIndexDBPath: docIndexDBPath
                )
            } else {
                MemoryEngine(config: config)
            }
            cached[key] = engine
            return engine
        }
    }

    /// Configured LLM `server_url` values exempted from the SSRF loopback deny.
    /// Thin passthrough to the canonical `LLMOrigins` helper in `RuneWeaverCore`
    /// so the CLI resolves the same trimmed, de-duplicated origin list as the
    /// app and serve paths instead of deriving a second copy.
    /// - Parameter llmConfig: `[llm]` section carrying provider endpoints.
    /// - Returns: Non-empty trimmed server URLs.
    static func llmServerURLs(from llmConfig: LLMConfig?) -> [String] {
        LLMOrigins.serverURLs(from: llmConfig)
    }

    /// Built-in plugin tools registered into every CLI `ToolBus`.
    static func pluginTools(
        emailConfig: EmailConfig? = nil,
        filesConfig: FilesConfig? = nil,
        memoryEngine: MemoryEngine? = nil,
        sandboxConfig: SandboxConfig? = nil,
        embedder: (any EmbeddingsBackend)? = nil,
        browserConfig: BrowserConfig? = nil,
        llmConfig: LLMConfig? = nil,
        llmServerURLs: [String] = [],
        mediaConfig: MediaConfig? = nil
    ) -> [any Tool] {
        let browser = browserConfig ?? BrowserConfig()
        let baseOrigins = llmServerURLs
        let combinedOrigins = baseOrigins + Self.llmServerURLs(from: llmConfig).filter { !baseOrigins.contains($0) }
        return BuiltinToolPlugins.makeAllTools(
            emailConfig: emailConfig,
            filesConfig: filesConfig,
            sandboxConfig: sandboxConfig,
            browserConfig: browser,
            mediaConfig: mediaConfig,
            llmServerURLs: combinedOrigins,
            memoryEngine: memoryEngine,
            embedder: embedder
        )
    }

    /// Builds a `ToolBus` pre-populated from the shared plugin source.
    static func makeToolBus(
        emailConfig: EmailConfig? = nil,
        filesConfig: FilesConfig? = nil,
        memoryEngine: MemoryEngine? = nil,
        permissionGate: PermissionGate? = nil,
        approvalHandler: ToolApprovalHandler? = nil,
        sandboxConfig: SandboxConfig? = nil,
        embedder: (any EmbeddingsBackend)? = nil,
        pluginConfig: PluginConfig? = nil,
        episodesDBPath: String? = nil,
        browserConfig: BrowserConfig? = nil,
        llmConfig: LLMConfig? = nil,
        llmServerURLs: [String] = [],
        mediaConfig: MediaConfig? = nil
    ) async -> ToolBus {
        let bus = ToolBus(approvalHandler: approvalHandler, permissionGate: permissionGate)
        for tool in pluginTools(
            emailConfig: emailConfig,
            filesConfig: filesConfig,
            memoryEngine: memoryEngine,
            sandboxConfig: sandboxConfig,
            embedder: embedder,
            browserConfig: browserConfig,
            llmConfig: llmConfig,
            llmServerURLs: llmServerURLs,
            mediaConfig: mediaConfig
        ) {
            await bus.register(tool: tool)
        }
        if let pluginConfig {
            let expandedDir = (pluginConfig.pluginsDir as NSString).expandingTildeInPath
            let pluginsURL = URL(fileURLWithPath: expandedDir)
            let rawDBPath = episodesDBPath ?? "~/.runeweaver/episodes.db"
            let dbPath = (rawDBPath as NSString).expandingTildeInPath
            let store = ToolRegistryStore(dbPath: dbPath)
            let discovery = PluginDiscoveryService(pluginsDirectory: pluginsURL, store: store)
            await discovery.discoverAndSync(toolBus: bus)
        }
        return bus
    }
}

/// Prints a message to standard error.
/// - Parameter text: Message to print.
func cliPrintError(_ text: String) {
    if let data = (text + "\n").data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}

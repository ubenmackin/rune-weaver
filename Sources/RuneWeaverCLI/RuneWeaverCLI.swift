import Foundation
import RuneWeaverCore
import RuneWeaverLLM

/// Shared terminal styling, config loading, and provider wiring.
///
/// The `rune-weaver` CLI is the MVP interaction layer (terminal-only by
/// design — there is no web frontend). Every subcommand builds on these
/// helpers so config resolution, secrets handling, and output styling
/// stay consistent across `chat`, `config`, `memory`, and `status`.
enum TerminalStyle {
    /// Whether ANSI colors may be emitted. Honors `NO_COLOR`.
    static var isColorEnabled: Bool {
        ProcessInfo.processInfo.environment["NO_COLOR"] == nil
    }

    /// Wraps text in the given ANSI code.
    /// - Parameters:
    ///   - text: Text to style.
    ///   - code: ANSI code (e.g. `"32;1"`).
    /// - Returns: Styled text, or plain text when colors are disabled.
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
    /// - Parameter path: Explicit `--config` value, if any.
    /// - Returns: Loaded config and its file URL.
    /// - Throws: ``ConfigError`` when an existing file is missing,
    ///   unreadable, unparsable, or fails validation.
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
    ///
    /// Raw key values are held in memory only and are never printed or
    /// logged.
    /// - Parameter llm: Decoded `[llm]` config section.
    /// - Returns: Enabled providers.
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

    /// Selects the active provider: `--provider` override first (matched
    /// against the provider name, its local aliases, then the model
    /// name), then `default_provider`, then `fallback_provider`, then
    /// first enabled.
    ///
    /// The `local` config entry maps to the `llamacpp` backend
    /// (`llamacpp`/`llama-cpp`/`llama_cpp`/`local` are aliases), so
    /// `--provider local` and `default_provider = "local"` both resolve
    /// to a `LlamaCppProvider` whose `name` is `"llamacpp"`.
    /// - Parameters:
    ///   - override: Explicit `--provider` value, if any.
    ///   - providers: Enabled providers.
    ///   - config: Decoded `[llm]` config section.
    /// - Returns: Selected provider, or nil when the override matches nothing.
    static func selectProvider(
        named override: String?,
        from providers: [any LLMProvider],
        config: LLMConfig
    ) -> (any LLMProvider)? {
        if let override, !override.isEmpty {
            let wanted = override.lowercased()
            if let match = providers.first(where: { matchesProvider($0, wanted: wanted) }) {
                return match
            }
            return providers.first(where: { $0.modelInfo.name.lowercased() == wanted })
        }
        if let match = providers.first(where: { matchesProvider($0, wanted: config.defaultProvider) }) {
            return match
        }
        if let fallback = config.fallbackProvider,
           let match = providers.first(where: { matchesProvider($0, wanted: fallback) })
        {
            return match
        }
        return providers.first
    }

    /// Whether a provider matches a configured/CLI name, including the
    /// local-backend aliases (`llamacpp`, `llama-cpp`, `llama_cpp`,
    /// `local` all match each other). Comparison is case-insensitive.
    /// - Parameters:
    ///   - provider: Candidate provider.
    ///   - wanted: Configured or CLI-supplied name.
    /// - Returns: True when the names match directly or via alias.
    static func matchesProvider(_ provider: any LLMProvider, wanted: String) -> Bool {
        let normalized = wanted.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        if provider.name.lowercased() == normalized {
            return true
        }
        let localAliases: Set = ["llamacpp", "llama-cpp", "llama_cpp", "local"]
        if localAliases.contains(provider.name.lowercased()), localAliases.contains(normalized) {
            return true
        }
        return false
    }
}

/// Compiler-checked lock-guarded box for CLI shared state.
///
/// Encapsulates `NSLock` so the static itself stays an immutable
/// `static let` and every mutation runs inside `withLock` (which uses
/// `defer` for unlock), keeping access data-race free under Swift 6
/// concurrency without `nonisolated(unsafe)` mutable state.
final class CLILockedValue<Value: Sendable>: @unchecked Sendable {
    /// Guarded value.
    private var value: Value
    /// Guards `value`.
    private let lock = NSLock()

    /// Creates a box.
    /// - Parameter value: Initial value.
    init(_ value: Value) {
        self.value = value
    }

    /// Runs `body` with exclusive access to the value.
    /// - Parameter body: Mutation or read to perform while locked.
    /// - Returns: Body result.
    func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}

/// Single shared store source for the CLI process.
///
/// `status`, `memory`, and `chat` must not each open independent
/// `EpisodeStore` / `VectorStore` / `MemoryEngine` instances on the same
/// files: independent snapshots can diverge within one process. All
/// commands resolve their engine through `memoryEngine(for:)`, which
/// vends one cached `MemoryEngine` per path pair, and build their
/// `ToolBus` from the single `pluginTools()` source so the registry
/// stays consistent.
enum CLIShared {
    /// Cached engines keyed by episodes + vector paths.
    ///
    /// Immutable box; all access runs inside `withLock` so no
    /// `nonisolated(unsafe)` mutable state is needed.
    private static let engines = CLILockedValue<[String: MemoryEngine]>([:])

    /// Returns the shared engine for the given memory config,
    /// creating and caching it on first use.
    /// - Parameter config: Memory paths from `config.toml`.
    /// - Returns: Shared engine for those paths.
    static func memoryEngine(for config: MemoryConfig) -> MemoryEngine {
        let key = "\(config.episodesDBPath)\0\(config.vectorDBPath)"
        return engines.withLock { cached in
            if let existing = cached[key] {
                return existing
            }
            let engine = MemoryEngine(config: config)
            cached[key] = engine
            return engine
        }
    }

    /// Built-in plugin tools registered into every CLI `ToolBus`.
    ///
    /// The single source of truth for the CLI registry (currently no
    /// bundled plugins, so empty). Commands add these to their bus
    /// instead of constructing divergent registries.
    /// - Returns: Tools to register.
    static func pluginTools() -> [any Tool] {
        []
    }

    /// Builds a `ToolBus` pre-populated from the shared plugin source.
    /// - Parameters:
    ///   - permissionGate: Graduated-trust gate, if any.
    ///   - approvalHandler: Approval hook, if any.
    /// - Returns: Bus with every shared plugin registered.
    static func makeToolBus(
        permissionGate: PermissionGate? = nil,
        approvalHandler: ToolApprovalHandler? = nil
    ) async -> ToolBus {
        let bus = ToolBus(approvalHandler: approvalHandler, permissionGate: permissionGate)
        for tool in pluginTools() {
            await bus.register(tool: tool)
        }
        return bus
    }
}

/// Collapses whitespace and truncates text for single-line inline display.
///
/// Thin CLI alias over the single shared `ToolInput.inline(_:limit:)` helper
/// in `RuneWeaverCore` so chat display and persisted placeholders compact
/// identically. Tool arguments use 160, tool results use 300; callers pass
/// the limit explicitly so budgets never diverge through a default.
/// - Parameters:
///   - text: Text to compact.
///   - limit: Maximum characters before truncation.
/// - Returns: Single-line text, suffixed with `…` when truncated.
func cliInline(_ text: String, limit: Int) -> String {
    ToolInput.inline(text, limit: limit)
}

/// Prints a message to standard error.
/// - Parameter text: Message to print.
func cliPrintError(_ text: String) {
    if let data = (text + "\n").data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}

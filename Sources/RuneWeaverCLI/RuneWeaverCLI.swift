import Foundation
import RuneWeaverCore
import RuneWeaverLLM
import RuneWeaverTools

/// Shared terminal styling, config loading, and provider wiring.
///
/// The `rune-weaver` CLI links `RuneWeaverCore` directly for v1 (`chat`
/// and `scheduler run` build their own `ToolBus` and `Orchestrator` here
/// so terminal use works with no service running) and launches the shared
/// engine service via `serve` for the web dashboard, iOS, and macOS
/// clients (see the Engine-to-Service Shift in ARCHITECTURE.md). Every
/// subcommand builds on these helpers so config resolution, secrets
/// handling, and output styling stay consistent across `chat`, `config`,
/// `memory`, `scheduler`, `serve`, and `status`.
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
    /// Shared selection lives in `LLMProviderFactory` so the CLI and the
    /// menu-bar app resolve the same way; this wrapper keeps existing
    /// call sites stable.
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
        LLMProviderFactory.selectProvider(named: override, from: providers, config: config)
    }

    /// Whether a provider matches a configured/CLI name, including the
    /// local-backend aliases (`llamacpp`, `llama-cpp`, `llama_cpp`,
    /// `local` all match each other). Comparison is case-insensitive.
    ///
    /// Shared matching lives in `LLMProviderFactory`; this wrapper keeps
    /// existing call sites stable.
    /// - Parameters:
    ///   - provider: Candidate provider.
    ///   - wanted: Configured or CLI-supplied name.
    /// - Returns: True when the names match directly or via alias.
    static func matchesProvider(_ provider: any LLMProvider, wanted: String) -> Bool {
        LLMProviderFactory.matchesProvider(provider, wanted: wanted)
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
    /// The single source of truth for the CLI registry. Email search and
    /// read (`email.search`, `email.read`) are `readOnly` and built from
    /// the `[email]` section, while attachment downloads
    /// (`email.attachment`) are `requiresApproval` and stage under the
    /// `[sandbox]` staging path; memory tools (`remember_fact`,
    /// `recall_memories`) are built from the shared `MemoryEngine` so
    /// chat exposes them to the model as tool definitions every turn.
    /// Nil inputs yield no plugins for that family so legacy call sites
    /// stay valid. Commands pass their loaded config and shared engine
    /// instead of constructing divergent registries.
    /// - Parameters:
    ///   - emailConfig: Decoded `[email]` section, if any.
    ///   - memoryEngine: Shared engine for memory tools, if any.
    ///   - sandboxConfig: Decoded `[sandbox]` section for `email.attachment` staging. Defaults to the built-in staging path when nil.
    /// - Returns: Tools to register.
    static func pluginTools(emailConfig: EmailConfig? = nil, memoryEngine: MemoryEngine? = nil, sandboxConfig: SandboxConfig? = nil) -> [any Tool] {
        var tools: [any Tool] = []
        if let emailConfig {
            tools += EmailTools.makeTools(emailConfig: emailConfig, sandboxConfig: sandboxConfig ?? SandboxConfig())
        }
        if let memoryEngine {
            tools += MemoryTools.makeTools(engine: memoryEngine)
        }
        return tools
    }

    /// Builds a `ToolBus` pre-populated from the shared plugin source.
    /// - Parameters:
    ///   - emailConfig: Decoded `[email]` section, if any.
    ///   - memoryEngine: Shared engine for memory tools, if any.
    ///   - permissionGate: Graduated-trust gate, if any.
    ///   - approvalHandler: Approval hook, if any.
    ///   - sandboxConfig: Decoded `[sandbox]` section for `email.attachment` staging. Defaults to the built-in staging path when nil.
    /// - Returns: Bus with every shared plugin registered.
    static func makeToolBus(
        emailConfig: EmailConfig? = nil,
        memoryEngine: MemoryEngine? = nil,
        permissionGate: PermissionGate? = nil,
        approvalHandler: ToolApprovalHandler? = nil,
        sandboxConfig: SandboxConfig? = nil
    ) async -> ToolBus {
        let bus = ToolBus(approvalHandler: approvalHandler, permissionGate: permissionGate)
        for tool in pluginTools(emailConfig: emailConfig, memoryEngine: memoryEngine, sandboxConfig: sandboxConfig) {
            await bus.register(tool: tool)
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

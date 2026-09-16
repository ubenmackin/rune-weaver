// Rune Weaver CLI — Configuration show/set surface for config.toml.

import ArgumentParser
import Foundation
import RuneWeaverCore

/// Displays and updates configuration values.
struct ConfigCommand: AsyncParsableCommand {
    /// Top-level command configuration.
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Show and update configuration values.",
        subcommands: [ConfigShowCommand.self, ConfigSetCommand.self],
        defaultSubcommand: ConfigShowCommand.self
    )
}

/// Prints the effective configuration.
struct ConfigShowCommand: AsyncParsableCommand {
    /// Top-level command configuration.
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Display the effective configuration values."
    )

    /// Config file path override.
    @Option(name: .long, help: "Path to config.toml (defaults to ~/.runeweaver/config.toml).")
    var config: String?

    /// Prints every config section.
    mutating func run() async throws {
        let loaded = try CLIConfigLoader.loadConfig(path: config)
        if loaded.isFallback {
            print(TerminalStyle.dim("No config found at \(loaded.url.path); showing built-in defaults."))
        }
        let config = loaded.config
        print(TerminalStyle.dim("Config: \(loaded.url.path)"))
        print("")
        print("[engine]")
        print("name = \(config.engine.name)")
        print("log_level = \(config.engine.logLevel)")
        print("")
        printLLMSection(config)
        print("")
        print("[memory]")
        print("vector_db_path = \(config.memory.vectorDBPath)")
        print("episodes_db_path = \(config.memory.episodesDBPath)")
        print("embedding_model = \(config.memory.embeddingModel)")
        print("embedding_backend = \(config.memory.embeddingBackend)")
        print("")
        print("[voice]")
        print("stt_provider = \(config.voice.sttProvider)")
        print("whisper_model = \(config.voice.whisperModel)")
        print("tts_provider = \(config.voice.ttsProvider)")
        print("")
        printSandboxAndFilesSections(config)
        print("")
        print("[browser]")
        print("searxng_url = \(config.browser.searxngURL)")
        print("search_timeout_seconds = \(config.browser.searchTimeoutSeconds)")
        print("max_results = \(config.browser.maxResults)")
        print("")
        print("[email] (\(config.email.accounts.count) accounts)")
        for account in config.email.accounts {
            print("")
            print("[[email.accounts]]")
            print("name = \(account.name)")
            print("type = \(account.type)")
            print("host = \(account.host)")
            print("port = \(account.port)")
            print("username = \(account.username)")
            if let smtpHost = account.smtpHost {
                print("smtp_host = \(smtpHost)")
            }
            if let smtpPort = account.smtpPort {
                print("smtp_port = \(smtpPort)")
            }
            if account.smtpSecurity != .auto {
                print("smtp_security = \(account.smtpSecurity.rawValue)")
            }
        }
        print("")
        print("[home]")
        for entry in config.home.homekit {
            print("[[home.homekit]]")
            print("enabled = \(entry.enabled ? "true" : "false")")
        }
        for entry in config.home.homeAssistant {
            print("[[home.home_assistant]]")
            print("enabled = \(entry.enabled ? "true" : "false")")
            if let url = entry.url {
                print("url = \(url)")
            }
            if let tokenEnv = entry.tokenEnv {
                print("token_env = \(tokenEnv)")
            }
        }
        print("")
        print("[plugins]")
        print("plugins_dir = \(config.plugins.pluginsDir)")
        print("marketplace_index_url = \(config.plugins.marketplaceIndexURL)")
        print("auto_rescan = \(config.plugins.autoRescan ? "true" : "false")")
        print("")
        print("[scheduler] (\(config.scheduler.jobs.count) jobs)")
        if config.scheduler.jobs.isEmpty {
            print(TerminalStyle.dim("# Add [[scheduler.jobs]] entries; see Config/config.toml.example"))
        }
        for job in config.scheduler.jobs {
            print("")
            print("[[scheduler.jobs]]")
            print("name = \(job.name)")
            if let schedule = job.schedule {
                print("schedule = \(schedule)")
            }
            print("prompt = \(job.prompt)")
            print("enabled = \(job.enabled)")
            if let poll = job.poll {
                print("poll_account = \(poll.account)")
                print("poll_query = \(poll.query)")
                if let mailbox = poll.mailbox {
                    print("poll_mailbox = \(mailbox)")
                }
                print("poll_interval_seconds = \(poll.pollIntervalSeconds)")
                print("poll_limit = \(poll.limit)")
            }
        }
    }

    /// Prints the LLM provider section.
    private func printLLMSection(_ config: RuneWeaverConfig) {
        print("[llm]")
        print("default_provider = \(config.llm.defaultProvider)")
        print("fallback_provider = \(config.llm.fallbackProvider ?? "(none)")")
        for name in config.llm.providers.keys.sorted() {
            guard let entry = config.llm.providers[name] else { continue }
            print("")
            print("[llm.providers.\(name)]")
            print("enabled = \(entry.enabled)")
            if let model = entry.model {
                print("model = \(model)")
            }
            if let serverURL = entry.serverURL {
                print("server_url = \(serverURL)")
            }
            if let apiKeyEnv = entry.apiKeyEnv {
                print("api_key_env = \(apiKeyEnv)")
            }
            if let providerType = entry.providerType {
                print("provider_type = \(providerType)")
            }
            print("api_style = \(entry.apiStyle.rawValue)")
            if let contextLength = entry.contextLength {
                print("context_length = \(contextLength)")
            }
        }
    }

    /// Prints sandbox detonation and file-policy sections together.
    private func printSandboxAndFilesSections(_ config: RuneWeaverConfig) {
        print("[sandbox]")
        print("container_base_image = \(config.sandbox.containerBaseImage)")
        print("archive_session_ttl_minutes = \(config.sandbox.archiveSessionTTLMinutes)")
        print("max_concurrent_machines = \(config.sandbox.maxConcurrentMachines)")
        print("")
        print("[files]")
        let denyPatterns = "[" + config.files.denyPatterns.map { RuneWeaverConfig.tomlQuoted($0) }.joined(separator: ", ") + "]"
        let allowRoots = "[" + config.files.allowRoots.map { RuneWeaverConfig.tomlQuoted($0) }.joined(separator: ", ") + "]"
        print("deny_patterns = \(denyPatterns)")
        print("allow_roots = \(allowRoots)")
        print("require_approval_on_deny = \(config.files.requireApprovalOnDeny ? "true" : "false")")
    }
}

/// Updates a single configuration value.
struct ConfigSetCommand: AsyncParsableCommand {
    /// Top-level command configuration.
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Update a configuration value (e.g. llm.default_provider mlx)."
    )

    /// Dotted config key to update.
    @Argument(
        help: ArgumentHelp(
            "Dotted key (e.g. llm.default_provider, llm.providers.mlx.model, "
                + "memory.embedding_model, sandbox.container_base_image, browser.searxng_url)."
        )
    )
    var key: String

    /// New value for the key.
    @Argument(help: "New value. Booleans accept true/false/yes/no/1/0/on/off.")
    var value: String

    /// Config file path override.
    @Option(name: .long, help: "Path to config.toml (defaults to ~/.runeweaver/config.toml).")
    var config: String?

    /// Applies the update and writes the file.
    mutating func run() async throws {
        let url = CLIConfigLoader.configFileURL(for: config)
        if FileManager.default.fileExists(atPath: url.path) {
            let current = try String(contentsOf: url, encoding: .utf8)
            let assignment = try configTOMLAssignment(for: key, value: value)
            let updated = upsertTOMLValue(current, section: assignment.section, key: assignment.key, rendered: assignment.rendered)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try updated.write(to: url, atomically: true, encoding: .utf8)
            verifyConfigFile(at: url)
        } else {
            var fresh = RuneWeaverConfig.default
            try applyConfigValue(key: key, value: value, config: &fresh)
            try fresh.validate()
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try renderFullTOML(fresh).write(to: url, atomically: true, encoding: .utf8)
        }
        print(TerminalStyle.success("Set \(key) = \(value) in \(url.path)"))
    }

    /// Loads the file back to catch validation problems after writing.
    /// Validation failures print a warning instead of throwing.
    /// - Parameter url: Config file URL just written.
    private func verifyConfigFile(at url: URL) {
        do {
            _ = try RuneWeaverConfig.load(from: url)
        } catch {
            cliPrintError("Warning: written config failed validation: \(error)")
        }
    }
}

/// One TOML key assignment for a `config set` update.
private struct TOMLAssignment {
    /// Section header without brackets (e.g. `"llm.providers.mlx"`).
    let section: String
    /// Key name within the section.
    let key: String
    /// Rendered value (quoted string or bare bool/int).
    let rendered: String
}

/// Maps a dotted `config set` key to its TOML section, key, and value.
private func configTOMLAssignment(for key: String, value: String) throws -> TOMLAssignment {
    let lower = key.lowercased()
    if let direct = engineTOMLAssignment(key: lower, value: value) {
        return direct
    }
    if let direct = llmTopTOMLAssignment(key: lower, value: value) {
        return direct
    }
    if let direct = memoryTOMLAssignment(key: lower, value: value) {
        return direct
    }
    if let direct = voiceTOMLAssignment(key: lower, value: value) {
        return direct
    }
    if let direct = try sandboxTOMLAssignment(key: lower, value: value) {
        return direct
    }
    if let direct = try browserTOMLAssignment(key: lower, value: value) {
        return direct
    }
    return try providerTOMLAssignment(key: key, lower: lower, value: value)
}

private func engineTOMLAssignment(key lower: String, value: String) -> TOMLAssignment? {
    switch lower {
    case "engine.name":
        TOMLAssignment(section: "engine", key: "name", rendered: tomlQuoted(value))
    case "engine.log_level":
        TOMLAssignment(section: "engine", key: "log_level", rendered: tomlQuoted(value))
    default:
        nil
    }
}

private func llmTopTOMLAssignment(key lower: String, value: String) -> TOMLAssignment? {
    switch lower {
    case "llm.default_provider":
        TOMLAssignment(section: "llm", key: "default_provider", rendered: tomlQuoted(value))
    case "llm.fallback_provider":
        TOMLAssignment(section: "llm", key: "fallback_provider", rendered: tomlQuoted(value))
    default:
        nil
    }
}

private func memoryTOMLAssignment(key lower: String, value: String) -> TOMLAssignment? {
    switch lower {
    case "memory.vector_db_path":
        TOMLAssignment(section: "memory", key: "vector_db_path", rendered: tomlQuoted(value))
    case "memory.episodes_db_path":
        TOMLAssignment(section: "memory", key: "episodes_db_path", rendered: tomlQuoted(value))
    case "memory.embedding_model":
        TOMLAssignment(section: "memory", key: "embedding_model", rendered: tomlQuoted(value))
    case "memory.embedding_backend":
        TOMLAssignment(section: "memory", key: "embedding_backend", rendered: tomlQuoted(value))
    default:
        nil
    }
}

private func voiceTOMLAssignment(key lower: String, value: String) -> TOMLAssignment? {
    switch lower {
    case "voice.stt_provider":
        TOMLAssignment(section: "voice", key: "stt_provider", rendered: tomlQuoted(value))
    case "voice.whisper_model":
        TOMLAssignment(section: "voice", key: "whisper_model", rendered: tomlQuoted(value))
    case "voice.tts_provider":
        TOMLAssignment(section: "voice", key: "tts_provider", rendered: tomlQuoted(value))
    default:
        nil
    }
}

private func sandboxTOMLAssignment(key lower: String, value: String) throws -> TOMLAssignment? {
    switch lower {
    case "sandbox.container_base_image":
        TOMLAssignment(section: "sandbox", key: "container_base_image", rendered: tomlQuoted(value))
    case "sandbox.archive_session_ttl_minutes":
        try sandboxPositiveIntAssignment(dottedKey: "sandbox.archive_session_ttl_minutes", key: "archive_session_ttl_minutes", value: value)
    case "sandbox.max_concurrent_machines":
        try sandboxPositiveIntAssignment(dottedKey: "sandbox.max_concurrent_machines", key: "max_concurrent_machines", value: value)
    default:
        nil
    }
}

/// Builds a validated positive-integer sandbox assignment so mistyped values fail fast with the offending key.
private func sandboxPositiveIntAssignment(dottedKey: String, key: String, value: String) throws -> TOMLAssignment {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let intValue = Int(trimmed), intValue > 0 else {
        throw ValidationError("'\(dottedKey)' must be a positive integer (got '\(value)').")
    }
    return TOMLAssignment(section: "sandbox", key: key, rendered: String(intValue))
}

private func browserTOMLAssignment(key lower: String, value: String) throws -> TOMLAssignment? {
    // Browser bounds mirror validation so `config set` fails fast with the
    // offending key instead of writing a file that fails to load.
    switch lower {
    case "browser.searxng_url":
        return TOMLAssignment(section: "browser", key: "searxng_url", rendered: tomlQuoted(value))
    case "browser.search_timeout_seconds":
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let intValue = Int(trimmed), intValue >= 1, intValue <= 120 else {
            throw ValidationError("'browser.search_timeout_seconds' must be between 1 and 120 (got '\(value)').")
        }
        return TOMLAssignment(section: "browser", key: "search_timeout_seconds", rendered: String(intValue))
    case "browser.max_results":
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let intValue = Int(trimmed), intValue >= 1, intValue <= 50 else {
            throw ValidationError("'browser.max_results' must be between 1 and 50 (got '\(value)').")
        }
        return TOMLAssignment(section: "browser", key: "max_results", rendered: String(intValue))
    default:
        return nil
    }
}

private func providerTOMLAssignment(key: String, lower: String, value: String) throws -> TOMLAssignment {
    let parts = lower.split(separator: ".").map(String.init)
    guard parts.count == 4, parts[0] == "llm", parts[1] == "providers" else {
        throw ValidationError(
            "Unknown config key '\(key)'. Supported: engine.name, engine.log_level, llm.default_provider, "
                + "llm.fallback_provider, memory.*, voice.*, sandbox.*, browser.*, "
                + "llm.providers.<name>.(enabled|model|server_url|api_key_env|provider_type|api_style|context_length)."
        )
    }
    let section = "llm.providers.\(parts[2])"
    guard let field = try providerFieldAssignment(section: section, field: parts[3], key: key, value: value) else {
        throw ValidationError(
            "Unknown provider field '\(parts[3])'. Supported: enabled, model, server_url, api_key_env, provider_type, api_style, context_length."
        )
    }
    return field
}

private func providerFieldAssignment(section: String, field: String, key: String, value: String) throws -> TOMLAssignment? {
    switch field {
    case "enabled":
        return try TOMLAssignment(section: section, key: "enabled", rendered: tomlBool(value, key: key))
    case "model":
        return TOMLAssignment(section: section, key: "model", rendered: tomlQuoted(value))
    case "server_url":
        return TOMLAssignment(section: section, key: "server_url", rendered: tomlQuoted(value))
    case "api_key_env":
        return TOMLAssignment(section: section, key: "api_key_env", rendered: tomlQuoted(value))
    case "provider_type":
        return TOMLAssignment(section: section, key: "provider_type", rendered: tomlQuoted(value))
    case "api_style":
        guard let style = APIStyle(rawValue: value) else {
            throw ValidationError(
                "'\(key)' must be one of \(APIStyle.allCases.map(\.rawValue).joined(separator: ", ")) (got '\(value)')."
            )
        }
        return TOMLAssignment(section: section, key: "api_style", rendered: tomlQuoted(style.rawValue))
    case "context_length":
        let length = try providerContextLengthValue(key: key, value: value)
        return TOMLAssignment(section: section, key: "context_length", rendered: String(length))
    default:
        return nil
    }
}

/// Validates a provider context-window override shared by both file-edit and fresh-file paths.
private func providerContextLengthValue(key: String, value: String) throws -> Int {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let intValue = Int(trimmed), intValue > 0 else {
        throw ValidationError("'\(key)' must be a positive integer (got '\(value)').")
    }
    return intValue
}

/// Applies a `config set` update to an in-memory config (new-file path).
private func applyConfigValue(key: String, value: String, config: inout RuneWeaverConfig) throws {
    let lower = key.lowercased()
    if applyEngineValue(key: lower, value: value, config: &config) {
        return
    }
    if applyLLMTopValue(key: lower, value: value, config: &config) {
        return
    }
    if applyMemoryValue(key: lower, value: value, config: &config) {
        return
    }
    if applyVoiceValue(key: lower, value: value, config: &config) {
        return
    }
    if try applySandboxValue(key: lower, value: value, config: &config) {
        return
    }
    if try applyBrowserValue(key: key, lower: lower, value: value, config: &config) {
        return
    }
    try applyProviderValue(key: key, lower: lower, value: value, config: &config)
}

private func applyEngineValue(key lower: String, value: String, config: inout RuneWeaverConfig) -> Bool {
    switch lower {
    case "engine.name":
        config.engine.name = value
        return true
    case "engine.log_level":
        config.engine.logLevel = value
        return true
    default:
        return false
    }
}

private func applyLLMTopValue(key lower: String, value: String, config: inout RuneWeaverConfig) -> Bool {
    switch lower {
    case "llm.default_provider":
        config.llm.defaultProvider = value
        return true
    case "llm.fallback_provider":
        config.llm.fallbackProvider = value.isEmpty ? nil : value
        return true
    default:
        return false
    }
}

private func applyMemoryValue(key lower: String, value: String, config: inout RuneWeaverConfig) -> Bool {
    switch lower {
    case "memory.vector_db_path":
        config.memory.vectorDBPath = value
        return true
    case "memory.episodes_db_path":
        config.memory.episodesDBPath = value
        return true
    case "memory.embedding_model":
        config.memory.embeddingModel = value
        return true
    case "memory.embedding_backend":
        config.memory.embeddingBackend = value
        return true
    default:
        return false
    }
}

private func applyVoiceValue(key lower: String, value: String, config: inout RuneWeaverConfig) -> Bool {
    switch lower {
    case "voice.stt_provider":
        config.voice.sttProvider = value
        return true
    case "voice.whisper_model":
        config.voice.whisperModel = value
        return true
    case "voice.tts_provider":
        config.voice.ttsProvider = value
        return true
    default:
        return false
    }
}

private func applySandboxValue(key lower: String, value: String, config: inout RuneWeaverConfig) throws -> Bool {
    switch lower {
    case "sandbox.container_base_image":
        config.sandbox.containerBaseImage = value
        return true
    case "sandbox.archive_session_ttl_minutes":
        guard let intVal = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)), intVal > 0 else {
            throw ValidationError("sandbox.archive_session_ttl_minutes must be a positive integer (got '\(value)')")
        }
        config.sandbox.archiveSessionTTLMinutes = intVal
        return true
    case "sandbox.max_concurrent_machines":
        guard let intVal = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)), intVal > 0 else {
            throw ValidationError("sandbox.max_concurrent_machines must be a positive integer (got '\(value)')")
        }
        config.sandbox.maxConcurrentMachines = intVal
        return true
    default:
        return false
    }
}

private func applyBrowserValue(key: String, lower: String, value: String, config: inout RuneWeaverConfig) throws -> Bool {
    switch lower {
    case "browser.searxng_url":
        config.browser.searxngURL = value
        return true
    case "browser.search_timeout_seconds":
        guard let intVal = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)), intVal >= 1, intVal <= 120 else {
            throw ValidationError("'\(key)' must be between 1 and 120 (got '\(value)')")
        }
        config.browser.searchTimeoutSeconds = intVal
        return true
    case "browser.max_results":
        guard let intVal = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)), intVal >= 1, intVal <= 50 else {
            throw ValidationError("'\(key)' must be between 1 and 50 (got '\(value)')")
        }
        config.browser.maxResults = intVal
        return true
    default:
        return false
    }
}

private func applyProviderValue(key: String, lower: String, value: String, config: inout RuneWeaverConfig) throws {
    let parts = lower.split(separator: ".").map(String.init)
    guard parts.count == 4, parts[0] == "llm", parts[1] == "providers" else {
        throw ValidationError(
            "Unknown config key '\(key)'. Supported: engine.name, engine.log_level, llm.default_provider, "
                + "llm.fallback_provider, memory.*, voice.*, sandbox.*, browser.*, "
                + "llm.providers.<name>.(enabled|model|server_url|api_key_env|provider_type|api_style|context_length). "
                + "Run 'rune-weaver config show' for supported keys."
        )
    }
    var entry = config.llm.providers[parts[2]] ?? ProviderConfig()
    switch parts[3] {
    case "enabled":
        entry.enabled = try tomlBool(value, key: key) == "true"
    case "model":
        entry.model = value
    case "server_url":
        entry.serverURL = value
    case "api_key_env":
        entry.apiKeyEnv = value
    case "provider_type":
        entry.providerType = value
    case "api_style":
        guard let style = APIStyle(rawValue: value) else {
            throw ValidationError(
                "'\(key)' must be one of \(APIStyle.allCases.map(\.rawValue).joined(separator: ", ")) (got '\(value)')."
            )
        }
        entry.apiStyle = style
    case "context_length":
        entry.contextLength = try providerContextLengthValue(key: key, value: value)
    default:
        throw ValidationError(
            "Unknown provider field '\(parts[3])'. Supported: enabled, model, server_url, api_key_env, provider_type, api_style, context_length."
        )
    }
    config.llm.providers[parts[2]] = entry
}

/// Parses a boolean-ish value into canonical TOML `true`/`false`.
private func tomlBool(_ value: String, key: String) throws -> String {
    switch value.lowercased() {
    case "true", "1", "yes", "on":
        return "true"
    case "false", "0", "no", "off":
        return "false"
    default:
        throw ValidationError("'\(key)' must be a boolean (got '\(value)').")
    }
}

/// Quotes a string for TOML output via the canonical core serializer.
private func tomlQuoted(_ value: String) -> String {
    RuneWeaverConfig.tomlQuoted(value)
}

/// Inserts or replaces one key inside a TOML document, preserving every
/// other line, comment, and section.
private func upsertTOMLValue(_ text: String, section: String, key: String, rendered: String) -> String {
    var lines = text.components(separatedBy: "\n")
    let header = "[\(section)]"
    var headerIndex: Int?
    var keyIndex: Int?
    var nextHeaderIndex: Int?
    for (index, line) in lines.enumerated() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("[") {
            if tomlHeaderBody(trimmed) == header {
                headerIndex = index
            } else if headerIndex != nil {
                nextHeaderIndex = index
                break
            }
            continue
        }
        if headerIndex != nil, keyIndex == nil {
            let sides = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if sides.count == 2, sides[0].trimmingCharacters(in: .whitespaces) == key {
                keyIndex = index
            }
        }
    }
    if let keyIndex {
        let indent = lines[keyIndex].prefix(while: { $0 == " " || $0 == "\t" })
        let commentSuffix = tomlTrailingComment(lines[keyIndex])
        let separator: String = {
            if commentSuffix.isEmpty {
                return ""
            }
            if commentSuffix.hasPrefix("#") {
                return " "
            }
            return ""
        }()
        lines[keyIndex] = "\(indent)\(key) = \(rendered)\(separator)\(commentSuffix)"
        return lines.joined(separator: "\n")
    }
    if let headerIndex {
        lines.insert("\(key) = \(rendered)", at: headerIndex + 1)
        return lines.joined(separator: "\n")
    }
    let end = nextHeaderIndex ?? lines.count
    var prefix = lines[0 ..< end].joined(separator: "\n")
    if !prefix.isEmpty, !prefix.hasSuffix("\n") {
        prefix += "\n"
    }
    let suffix = lines[end...].joined(separator: "\n")
    var result = prefix
    if !result.isEmpty, !result.hasSuffix("\n") {
        result += "\n"
    }
    result += "\(header)\n\(key) = \(rendered)"
    if !suffix.isEmpty {
        result += "\n" + suffix
    } else if !text.hasSuffix("\n") {
        result += "\n"
    }
    return result
}

/// Returns a section header without its trailing `# comment`, if any.
private func tomlHeaderBody(_ trimmed: String) -> String {
    let comment = tomlTrailingComment(trimmed)
    guard !comment.isEmpty else {
        return trimmed
    }
    return String(trimmed.dropLast(comment.count)).trimmingCharacters(in: .whitespaces)
}

/// Extracts the trailing `# comment` from a TOML value line, if any.
private func tomlTrailingComment(_ line: String) -> String {
    var inDouble = false
    var inSingle = false
    var escaped = false
    var hashIndex: String.Index?
    var cursor = line.startIndex
    while cursor < line.endIndex {
        let character = line[cursor]
        if inDouble {
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                inDouble = false
            }
        } else if inSingle {
            if character == "'" {
                inSingle = false
            }
        } else {
            if character == "\"" {
                inDouble = true
            } else if character == "'" {
                inSingle = true
            } else if character == "#" {
                hashIndex = cursor
                break
            }
        }
        cursor = line.index(after: cursor)
    }
    guard let hash = hashIndex else { return "" }
    var start = hash
    while start > line.startIndex {
        let previous = line.index(before: start)
        if line[previous] == " " || line[previous] == "\t" {
            start = previous
        } else {
            break
        }
    }
    return String(line[start...])
}

/// Renders a full `config.toml` for freshly created files.
private func renderFullTOML(_ config: RuneWeaverConfig) -> String {
    config.renderTOML()
}

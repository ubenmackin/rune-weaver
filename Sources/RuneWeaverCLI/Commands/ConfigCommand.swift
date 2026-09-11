import ArgumentParser
import Foundation
import RuneWeaverCore

/// Displays and updates configuration values.
///
/// `rune-weaver config show` prints the effective config.
/// `rune-weaver config set <key> <value>` updates one dotted key
/// (e.g. `llm.default_provider`, `llm.providers.mlx.model`) while
/// preserving every other line, comment, and unknown section in the file.
/// Secret values are never printed and never stored in `config.toml` —
/// only `api_key_env` variable names appear.
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
            if let baseURL = entry.baseURL {
                print("base_url = \(baseURL)")
            }
            if let apiKeyEnv = entry.apiKeyEnv {
                print("api_key_env = \(apiKeyEnv)")
            }
            if let providerType = entry.providerType {
                print("provider_type = \(providerType)")
            }
        }
        print("")
        print("[memory]")
        print("vector_db_path = \(config.memory.vectorDBPath)")
        print("episodes_db_path = \(config.memory.episodesDBPath)")
        print("embedding_model = \(config.memory.embeddingModel)")
        print("")
        print("[voice]")
        print("stt_provider = \(config.voice.sttProvider)")
        print("whisper_model = \(config.voice.whisperModel)")
        print("tts_provider = \(config.voice.ttsProvider)")
        print("")
        print("[sandbox]")
        print("staging_path = \(config.sandbox.stagingPath)")
        print("auto_approve_after = \(config.sandbox.autoApproveAfter)")
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
    @Argument(help: "Dotted key (e.g. llm.default_provider, llm.providers.mlx.model, memory.embedding_model).")
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
/// - Parameters:
///   - key: Dotted key.
///   - value: Raw new value.
/// - Returns: TOML assignment to write.
/// - Throws: `ValidationError` for unknown keys or mistyped values.
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
    case "sandbox.staging_path":
        return TOMLAssignment(section: "sandbox", key: "staging_path", rendered: tomlQuoted(value))
    case "sandbox.auto_approve_after":
        guard Int(value) != nil else {
            throw ValidationError("'sandbox.auto_approve_after' must be an integer (got '\(value)').")
        }
        return TOMLAssignment(section: "sandbox", key: "auto_approve_after", rendered: value)
    default:
        return nil
    }
}

private func providerTOMLAssignment(key: String, lower: String, value: String) throws -> TOMLAssignment {
    let parts = lower.split(separator: ".").map(String.init)
    guard parts.count == 4, parts[0] == "llm", parts[1] == "providers" else {
        throw ValidationError(
            "Unknown config key '\(key)'. Supported: engine.name, engine.log_level, llm.default_provider, "
                + "llm.fallback_provider, memory.*, voice.*, sandbox.*, llm.providers.<name>.(enabled|model|server_url|base_url|api_key_env|provider_type)."
        )
    }
    let section = "llm.providers.\(parts[2])"
    guard let field = try providerFieldAssignment(section: section, field: parts[3], key: key, value: value) else {
        throw ValidationError(
            "Unknown provider field '\(parts[3])'. Supported: enabled, model, server_url, base_url, api_key_env, provider_type."
        )
    }
    return field
}

private func providerFieldAssignment(section: String, field: String, key: String, value: String) throws -> TOMLAssignment? {
    switch field {
    case "enabled":
        try TOMLAssignment(section: section, key: "enabled", rendered: tomlBool(value, key: key))
    case "model":
        TOMLAssignment(section: section, key: "model", rendered: tomlQuoted(value))
    case "server_url":
        TOMLAssignment(section: section, key: "server_url", rendered: tomlQuoted(value))
    case "base_url":
        TOMLAssignment(section: section, key: "base_url", rendered: tomlQuoted(value))
    case "api_key_env":
        TOMLAssignment(section: section, key: "api_key_env", rendered: tomlQuoted(value))
    case "provider_type":
        TOMLAssignment(section: section, key: "provider_type", rendered: tomlQuoted(value))
    default:
        nil
    }
}

/// Applies a `config set` update to an in-memory config (new-file path).
/// - Parameters:
///   - key: Dotted key.
///   - value: Raw new value.
///   - config: Config to mutate.
/// - Throws: `ValidationError` for unknown keys or mistyped values.
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
    case "sandbox.staging_path":
        config.sandbox.stagingPath = value
        return true
    case "sandbox.auto_approve_after":
        guard let number = Int(value) else {
            throw ValidationError("'sandbox.auto_approve_after' must be an integer (got '\(value)').")
        }
        config.sandbox.autoApproveAfter = number
        return true
    default:
        return false
    }
}

private func applyProviderValue(key: String, lower: String, value: String, config: inout RuneWeaverConfig) throws {
    let parts = lower.split(separator: ".").map(String.init)
    guard parts.count == 4, parts[0] == "llm", parts[1] == "providers" else {
        throw ValidationError("Unknown config key '\(key)'. Run 'rune-weaver config show' for supported keys.")
    }
    var entry = config.llm.providers[parts[2]] ?? ProviderConfig()
    switch parts[3] {
    case "enabled":
        entry.enabled = try tomlBool(value, key: key) == "true"
    case "model":
        entry.model = value
    case "server_url":
        entry.serverURL = value
    case "base_url":
        entry.baseURL = value
    case "api_key_env":
        entry.apiKeyEnv = value
    case "provider_type":
        entry.providerType = value
    default:
        throw ValidationError("Unknown provider field '\(parts[3])'.")
    }
    config.llm.providers[parts[2]] = entry
}

/// Parses a boolean-ish value into canonical TOML `true`/`false`.
/// - Parameters:
///   - value: Raw value.
///   - key: Dotted key (for error messages).
/// - Returns: `"true"` or `"false"`.
/// - Throws: `ValidationError` when the value is not boolean-like.
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

/// Quotes a string for TOML output.
/// - Parameter value: Raw string.
/// - Returns: Double-quoted, escaped TOML string.
private func tomlQuoted(_ value: String) -> String {
    var out = "\""
    for character in value {
        switch character {
        case "\\": out += "\\\\"
        case "\"": out += "\\\""
        case "\n": out += "\\n"
        case "\t": out += "\\t"
        default: out.append(character)
        }
    }
    out += "\""
    return out
}

/// Inserts or replaces one key inside a TOML document, preserving every
/// other line, comment, and section.
/// - Parameters:
///   - text: Current file contents.
///   - section: Section header without brackets.
///   - key: Key name within the section.
///   - rendered: Rendered value to write.
/// - Returns: Updated document text.
private func upsertTOMLValue(_ text: String, section: String, key: String, rendered: String) -> String {
    var lines = text.components(separatedBy: "\n")
    let header = "[\(section)]"
    var headerIndex: Int?
    var keyIndex: Int?
    var nextHeaderIndex: Int?
    for (index, line) in lines.enumerated() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("[") {
            if trimmed == header {
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
        lines[keyIndex] = "\(indent)\(key) = \(rendered)"
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

/// Renders a full `config.toml` for freshly created files.
/// - Parameter config: Config to render.
/// - Returns: TOML document text.
private func renderFullTOML(_ config: RuneWeaverConfig) -> String {
    var lines: [String] = ["# Generated by rune-weaver config set", ""]
    lines += ["[engine]", "name = \(tomlQuoted(config.engine.name))", "log_level = \(tomlQuoted(config.engine.logLevel))", ""]
    lines += ["[llm]", "default_provider = \(tomlQuoted(config.llm.defaultProvider))"]
    if let fallback = config.llm.fallbackProvider {
        lines.append("fallback_provider = \(tomlQuoted(fallback))")
    }
    lines.append("")
    for name in config.llm.providers.keys.sorted() {
        guard let entry = config.llm.providers[name] else { continue }
        lines.append("[llm.providers.\(name)]")
        lines.append("enabled = \(entry.enabled ? "true" : "false")")
        if let model = entry.model {
            lines.append("model = \(tomlQuoted(model))")
        }
        if let serverURL = entry.serverURL {
            lines.append("server_url = \(tomlQuoted(serverURL))")
        }
        if let baseURL = entry.baseURL {
            lines.append("base_url = \(tomlQuoted(baseURL))")
        }
        if let apiKeyEnv = entry.apiKeyEnv {
            lines.append("api_key_env = \(tomlQuoted(apiKeyEnv))")
        }
        if let providerType = entry.providerType {
            lines.append("provider_type = \(tomlQuoted(providerType))")
        }
        lines.append("")
    }
    lines += [
        "[memory]",
        "vector_db_path = \(tomlQuoted(config.memory.vectorDBPath))",
        "episodes_db_path = \(tomlQuoted(config.memory.episodesDBPath))",
        "embedding_model = \(tomlQuoted(config.memory.embeddingModel))",
        "",
        "[voice]",
        "stt_provider = \(tomlQuoted(config.voice.sttProvider))",
        "whisper_model = \(tomlQuoted(config.voice.whisperModel))",
        "tts_provider = \(tomlQuoted(config.voice.ttsProvider))",
        "",
        "[sandbox]",
        "staging_path = \(tomlQuoted(config.sandbox.stagingPath))",
        "auto_approve_after = \(config.sandbox.autoApproveAfter)",
        ""
    ]
    return lines.joined(separator: "\n")
}

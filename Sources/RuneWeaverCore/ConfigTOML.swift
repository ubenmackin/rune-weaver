import Foundation

// MARK: - Minimal TOML decoding

/// Scalar TOML value.
enum TOMLValue: Sendable, Equatable {
    case string(String)
    case integer(Int)
    case double(Double)
    case boolean(Bool)
}

/// Mutable node in the parsed TOML document tree.
final class TOMLNode {
    var values: [String: TOMLValue] = [:]
    var tables: [String: TOMLNode] = [:]
    var arrays: [String: [TOMLNode]] = [:]
}

/// Minimal TOML parser covering the `config.toml` schema.
///
/// Supports comments (`#`), quoted strings, integers, floats, booleans,
/// `[table]` / `[dotted.table]` headers, and `[[array-of-tables]]`
/// headers. Anything outside that subset throws a ``ConfigError/parseError(line:message:)``
/// naming the offending line.
enum TOMLParser {
    static func parse(_ text: String) throws -> TOMLNode {
        let root = TOMLNode()
        var current = root
        let lines = text.components(separatedBy: .newlines)
        for (index, rawLine) in lines.enumerated() {
            let lineNumber = index + 1
            let stripped = stripComment(from: rawLine).trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if stripped.isEmpty {
                continue
            }
            if stripped.hasPrefix("[[") {
                current = try parseArrayHeader(stripped, line: lineNumber, root: root)
            } else if stripped.hasPrefix("[") {
                current = try parseTableHeader(stripped, line: lineNumber, root: root)
            } else {
                try parseKeyValue(stripped, line: lineNumber, into: current)
            }
        }
        return root
    }

    private static func parseArrayHeader(_ stripped: String, line: Int, root: TOMLNode) throws -> TOMLNode {
        guard stripped.hasSuffix("]]") else {
            throw ConfigError.parseError(
                line: line, message: "malformed array-of-tables header: \(stripped)"
            )
        }
        let pathText = String(stripped.dropFirst(2).dropLast(2)).trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let path = try tablePath(pathText, line: line)
        return try appendArrayNode(at: path, in: root, line: line)
    }

    private static func parseTableHeader(_ stripped: String, line: Int, root: TOMLNode) throws -> TOMLNode {
        guard stripped.hasSuffix("]") else {
            throw ConfigError.parseError(
                line: line, message: "malformed table header: \(stripped)"
            )
        }
        let pathText = String(stripped.dropFirst().dropLast()).trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let path = try tablePath(pathText, line: line)
        return try tableNode(at: path, in: root, line: line)
    }

    private static func parseKeyValue(_ stripped: String, line: Int, into node: TOMLNode) throws {
        let (key, value) = try keyValue(stripped, lineNumber: line)
        if node.values[key] != nil {
            throw ConfigError.parseError(
                line: line, message: "duplicate key '\(key)'"
            )
        }
        node.values[key] = value
    }

    private static func tablePath(_ text: String, line: Int) throws -> [String] {
        let parts = text.split(separator: ".").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty }) else {
            throw ConfigError.parseError(line: line, message: "malformed table header: \(text)")
        }
        return parts.map { String($0) }
    }

    /// Resolves (creating when absent) the table node at `path`.
    /// - Parameters:
    ///   - path: Dotted table path segments. Must be non-empty.
    ///   - root: Document root.
    ///   - line: 1-based line number for error reporting.
    /// - Returns: Table node for the path.
    /// - Throws: ``ConfigError/parseError(line:message:)`` when a cached
    ///   entry is unexpectedly missing.
    private static func tableNode(at path: [String], in root: TOMLNode, line: Int) throws -> TOMLNode {
        var node = root
        for part in path {
            if node.tables[part] == nil {
                node.tables[part] = TOMLNode()
            }
            guard let next = node.tables[part] else {
                throw ConfigError.parseError(line: line, message: "missing table '\(part)'")
            }
            node = next
        }
        return node
    }

    /// Appends a new entry for the array-of-tables at `path`.
    /// - Parameters:
    ///   - path: Dotted array path segments. Must be non-empty.
    ///   - root: Document root.
    ///   - line: 1-based line number for error reporting.
    /// - Returns: Fresh entry node.
    /// - Throws: ``ConfigError/parseError(line:message:)`` when the path
    ///   is empty or a cached entry is unexpectedly missing.
    private static func appendArrayNode(at path: [String], in root: TOMLNode, line: Int) throws -> TOMLNode {
        var node = root
        for part in path.dropLast() {
            if node.tables[part] == nil {
                node.tables[part] = TOMLNode()
            }
            guard let next = node.tables[part] else {
                throw ConfigError.parseError(line: line, message: "missing table '\(part)'")
            }
            node = next
        }
        guard let leaf = path.last else {
            throw ConfigError.parseError(line: line, message: "malformed array-of-tables header")
        }
        let entry = TOMLNode()
        node.arrays[leaf, default: []].append(entry)
        return entry
    }

    private static func keyValue(_ line: String, lineNumber: Int) throws -> (String, TOMLValue) {
        guard let equals = splitOnEquals(line) else {
            throw ConfigError.parseError(
                line: lineNumber, message: "expected 'key = value', got: \(line)"
            )
        }
        let key = equals.0.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawValue = equals.1.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !rawValue.isEmpty else {
            throw ConfigError.parseError(
                line: lineNumber, message: "expected 'key = value', got: \(line)"
            )
        }
        return try (key, scalar(rawValue, line: lineNumber))
    }

    /// Splits on the first `=` outside quotes, honoring `\"` escapes
    /// inside double-quoted (basic) strings so a value like
    /// `"a \"=\" b"` does not mis-split. Single-quoted strings are TOML
    /// literals with no escapes and are scanned verbatim.
    private static func splitOnEquals(_ line: String) -> (String, String)? {
        var inDouble = false
        var inSingle = false
        var index = line.startIndex
        while index < line.endIndex {
            let char = line[index]
            if char == "\\", inDouble, !inSingle {
                // Skip the escaped character so `\"` never toggles quoting.
                let next = line.index(after: index)
                index = next < line.endIndex ? line.index(after: next) : line.endIndex
                continue
            }
            if char == "\"", !inSingle {
                inDouble.toggle()
            }
            if char == "'", !inDouble {
                inSingle.toggle()
            }
            if char == "=", !inDouble, !inSingle {
                return (String(line[..<index]), String(line[line.index(after: index)...]))
            }
            index = line.index(after: index)
        }
        return nil
    }

    private static func scalar(_ text: String, line: Int) throws -> TOMLValue {
        if text == "true" {
            return .boolean(true)
        }
        if text == "false" {
            return .boolean(false)
        }
        if text.hasPrefix("\"") || text.hasPrefix("'") {
            return try quoted(text, line: line)
        }
        if let integer = Int(text) {
            return .integer(integer)
        }
        if let double = Double(text) {
            return .double(double)
        }
        throw ConfigError.parseError(line: line, message: "unsupported value: \(text)")
    }

    private static func quoted(_ text: String, line: Int) throws -> TOMLValue {
        let quote: Character = text.hasPrefix("\"") ? "\"" : "'"
        guard text.count >= 2, text.last == quote else {
            throw ConfigError.parseError(line: line, message: "unterminated string: \(text)")
        }
        var result = ""
        var index = text.index(after: text.startIndex)
        let end = text.index(before: text.endIndex)
        while index < end {
            let char = text[index]
            if quote == "\"", char == "\\" {
                let next = text.index(after: index)
                guard next < end || next == end else {
                    throw ConfigError.parseError(
                        line: line, message: "dangling escape in string: \(text)"
                    )
                }
                if next == end {
                    throw ConfigError.parseError(
                        line: line, message: "dangling escape in string: \(text)"
                    )
                }
                switch text[next] {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "\\": result.append("\\")
                case "\"": result.append("\"")
                default: result.append(text[next])
                }
                index = text.index(after: next)
            } else {
                result.append(char)
                index = text.index(after: index)
            }
        }
        return .string(result)
    }

    /// Strips a trailing `#` comment, ignoring `#` inside quotes.
    ///
    /// Double-quoted (basic) strings honor backslash escapes, so a value
    /// like `"a \"#\" b"` keeps its `#`; single-quoted literal strings
    /// have no escapes and are scanned verbatim.
    private static func stripComment(from line: String) -> String {
        var inDouble = false
        var inSingle = false
        var index = line.startIndex
        while index < line.endIndex {
            let char = line[index]
            if char == "\\", inDouble, !inSingle {
                // Skip the escaped character so `\"` never toggles quoting.
                let next = line.index(after: index)
                index = next < line.endIndex ? line.index(after: next) : line.endIndex
                continue
            }
            if char == "\"", !inSingle {
                inDouble.toggle()
            }
            if char == "'", !inDouble {
                inSingle.toggle()
            }
            if char == "#", !inDouble, !inSingle {
                return String(line[..<index])
            }
            index = line.index(after: index)
        }
        return line
    }
}

// MARK: - TOML to struct mapping

extension TOMLNode {
    func string(_ key: String) -> String? {
        guard let value = values[key] else { return nil }
        if case let .string(text) = value {
            return text
        }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        guard let value = values[key] else { return nil }
        if case let .boolean(flag) = value {
            return flag
        }
        return nil
    }

    func int(_ key: String) -> Int? {
        guard let value = values[key] else { return nil }
        switch value {
        case let .integer(number): return number
        case let .double(number): return Int(number)
        default: return nil
        }
    }
}

extension RuneWeaverConfig {
    /// Builds a config from a parsed TOML document, applying defaults
    /// for every absent optional field.
    /// - Parameter root: Parsed TOML document.
    init(decoding root: TOMLNode) throws {
        var config = RuneWeaverConfig.default
        Self.decodeEngine(root, into: &config)
        try Self.decodeLLM(root, into: &config)
        Self.decodeMemory(root, into: &config)
        Self.decodeVoice(root, into: &config)
        Self.decodeSandbox(root, into: &config)
        try Self.decodeEmail(root, into: &config)
        Self.decodeHome(root, into: &config)
        self = config
    }

    private static func decodeEngine(_ root: TOMLNode, into config: inout RuneWeaverConfig) {
        guard let engine = root.tables["engine"] else { return }
        if let name = engine.string("name") {
            config.engine.name = name
        }
        if let level = engine.string("log_level") {
            config.engine.logLevel = level
        }
    }

    private static func decodeLLM(_ root: TOMLNode, into config: inout RuneWeaverConfig) throws {
        guard let llm = root.tables["llm"] else { return }
        if let defaultProvider = llm.string("default_provider") {
            config.llm.defaultProvider = defaultProvider
        }
        if llm.values.keys.contains("fallback_provider") {
            config.llm.fallbackProvider = llm.string("fallback_provider")
        } else {
            config.llm.fallbackProvider = nil
        }
        guard let providers = llm.tables["providers"] else { return }
        let decoded = try decodeProviders(providers)
        if !decoded.isEmpty {
            config.llm.providers = decoded
        }
    }

    private static func decodeProviders(_ providers: TOMLNode) throws -> [String: ProviderConfig] {
        var decoded: [String: ProviderConfig] = [:]
        for (name, node) in providers.tables {
            decoded[name] = try decodeProvider(node, name: name)
        }
        return decoded
    }

    /// Decodes one `[llm.providers.<name>]` entry.
    /// - Parameters:
    ///   - node: Parsed provider table.
    ///   - name: Provider entry name (for error field paths).
    /// - Returns: Decoded provider config.
    /// - Throws: ``ConfigError/validationError(field:message:)`` when
    ///   `api_style` names an unknown style.
    private static func decodeProvider(_ node: TOMLNode, name: String) throws -> ProviderConfig {
        let apiStyle: APIStyle
        if let raw = node.string("api_style") {
            guard let style = APIStyle(rawValue: raw) else {
                throw ConfigError.validationError(
                    field: "llm.providers.\(name).api_style",
                    message: "must be one of \(APIStyle.allCases.map(\.rawValue).joined(separator: ", ")) (got '\(raw)')"
                )
            }
            apiStyle = style
        } else if node.values["api_style"] != nil {
            throw ConfigError.validationError(
                field: "llm.providers.\(name).api_style",
                message: "must be one of \(APIStyle.allCases.map(\.rawValue).joined(separator: ", "))"
            )
        } else {
            apiStyle = .chatCompletions
        }
        return ProviderConfig(
            enabled: node.bool("enabled") ?? true,
            model: node.string("model"),
            serverURL: node.string("server_url"),
            baseURL: node.string("base_url"),
            apiKeyEnv: node.string("api_key_env"),
            providerType: node.string("provider_type"),
            apiStyle: apiStyle
        )
    }

    private static func decodeMemory(_ root: TOMLNode, into config: inout RuneWeaverConfig) {
        guard let memory = root.tables["memory"] else { return }
        if let path = memory.string("vector_db_path") {
            config.memory.vectorDBPath = path
        }
        if let path = memory.string("episodes_db_path") {
            config.memory.episodesDBPath = path
        }
        if let model = memory.string("embedding_model") {
            config.memory.embeddingModel = model
        }
    }

    private static func decodeVoice(_ root: TOMLNode, into config: inout RuneWeaverConfig) {
        guard let voice = root.tables["voice"] else { return }
        if let provider = voice.string("stt_provider") {
            config.voice.sttProvider = provider
        }
        if let model = voice.string("whisper_model") {
            config.voice.whisperModel = model
        }
        if let provider = voice.string("tts_provider") {
            config.voice.ttsProvider = provider
        }
    }

    private static func decodeSandbox(_ root: TOMLNode, into config: inout RuneWeaverConfig) {
        guard let sandbox = root.tables["sandbox"] else { return }
        if let path = sandbox.string("staging_path") {
            config.sandbox.stagingPath = path
        }
        if let count = sandbox.int("auto_approve_after") {
            config.sandbox.autoApproveAfter = count
        }
    }

    private static func decodeEmail(_ root: TOMLNode, into config: inout RuneWeaverConfig) throws {
        guard let email = root.tables["email"] else { return }
        let accountNodes = email.arrays["accounts"] ?? []
        config.email.accounts = try accountNodes.map(decodeEmailAccount)
    }

    private static func decodeEmailAccount(_ node: TOMLNode) throws -> EmailAccount {
        guard let name = node.string("name") else {
            throw ConfigError.missingRequired(field: "email.accounts.name")
        }
        guard let host = node.string("host") else {
            throw ConfigError.missingRequired(
                field: "email.accounts[\(name)].host"
            )
        }
        guard let username = node.string("username") else {
            throw ConfigError.missingRequired(
                field: "email.accounts[\(name)].username"
            )
        }
        return EmailAccount(
            name: name,
            type: node.string("type") ?? "imap",
            host: host,
            port: node.int("port") ?? 993,
            username: username
        )
    }

    private static func decodeHome(_ root: TOMLNode, into config: inout RuneWeaverConfig) {
        guard let home = root.tables["home"] else { return }
        let homekitNodes = home.arrays["homekit"] ?? home.singleAsArray("homekit")
        config.home.homekit = homekitNodes.map { node in
            HomeKitConfig(enabled: node.bool("enabled") ?? true)
        }
        let assistantNodes =
            home.arrays["home_assistant"] ?? home.singleAsArray("home_assistant")
        config.home.homeAssistant = assistantNodes.map { node in
            HomeAssistantConfig(
                enabled: node.bool("enabled") ?? true,
                url: node.string("url"),
                tokenEnv: node.string("token_env")
            )
        }
    }
}

extension TOMLNode {
    /// Wraps a singular `[home.<table>]` table as a one-element array so
    /// both `[home.homekit]` and `[[home.homekit]]` spellings load.
    func singleAsArray(_ name: String) -> [TOMLNode] {
        guard let node = tables[name] else { return [] }
        return [node]
    }
}

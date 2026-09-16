// Rune Weaver Core — Minimal TOML decoding for config.toml.
//
// Parses the engine configuration document into a typed node tree without
// external dependencies, covering the tables, arrays-of-tables, and scalar
// shapes the config schema uses. Decoders map the tree onto
// `RuneWeaverConfig` so missing sections fall back to built-in defaults
// while malformed lines fail with a line-numbered parse error.

import Foundation

// MARK: - Minimal TOML decoding

/// Scalar TOML value plus inline string lists for deny/allow lists.
enum TOMLValue: Sendable, Equatable {
    case string(String)
    case integer(Int)
    case double(Double)
    case boolean(Bool)
    case stringArray([String])
}

/// Node in the parsed TOML document tree with pure value semantics.
struct TOMLNode: Sendable, Equatable {
    var values: [String: TOMLValue] = [:]
    var tables: [String: TOMLNode] = [:]
    var arrays: [String: [TOMLNode]] = [:]

    /// Mutates the table at `path`, creating intermediate tables along the way.
    mutating func withTable<R>(at path: [String], _ body: (inout TOMLNode) throws -> R) rethrows -> R {
        guard let first = path.first else {
            return try body(&self)
        }
        var child = tables[first, default: TOMLNode()]
        defer { tables[first] = child }
        return try child.withTable(at: Array(path.dropFirst()), body)
    }
}

/// Minimal TOML parser covering the `config.toml` schema.
///
/// Supports comments (`#`), quoted strings, integers, floats, booleans,
/// inline string lists (e.g. `deny_patterns = ["a", "b"]` for the files
/// policy), `[table]` / `[dotted.table]` headers, and
/// `[[array-of-tables]]` headers. Anything outside that subset throws a
/// ``ConfigError/parseError(line:message:)`` naming the offending line.
enum TOMLParser {
    private enum Target {
        case root
        case table([String])
        case array([String])
    }

    static func parse(_ text: String) throws -> TOMLNode {
        var root = TOMLNode()
        var target = Target.root
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
                let path = try parseArrayHeader(stripped, line: lineNumber)
                try appendArrayNode(at: path, in: &root, line: lineNumber)
                target = .array(path)
            } else if stripped.hasPrefix("[") {
                let path = try parseTableHeader(stripped, line: lineNumber)
                root.withTable(at: path) { _ in }
                target = .table(path)
            } else {
                let (key, value) = try keyValue(stripped, lineNumber: lineNumber)
                try insertKeyValue(key: key, value: value, at: target, in: &root, line: lineNumber)
            }
        }
        return root
    }

    private static func parseArrayHeader(_ stripped: String, line: Int) throws -> [String] {
        guard stripped.hasSuffix("]]") else {
            throw ConfigError.parseError(
                line: line, message: "malformed array-of-tables header: \(stripped)"
            )
        }
        let pathText = String(stripped.dropFirst(2).dropLast(2)).trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return try tablePath(pathText, line: line)
    }

    private static func parseTableHeader(_ stripped: String, line: Int) throws -> [String] {
        guard stripped.hasSuffix("]") else {
            throw ConfigError.parseError(
                line: line, message: "malformed table header: \(stripped)"
            )
        }
        let pathText = String(stripped.dropFirst().dropLast()).trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return try tablePath(pathText, line: line)
    }

    private static func insertKeyValue(
        key: String,
        value: TOMLValue,
        at target: Target,
        in root: inout TOMLNode,
        line: Int
    ) throws {
        switch target {
        case .root:
            if root.values[key] != nil {
                throw ConfigError.parseError(line: line, message: "duplicate key '\(key)'")
            }
            root.values[key] = value

        case let .table(path):
            try root.withTable(at: path) { table in
                if table.values[key] != nil {
                    throw ConfigError.parseError(line: line, message: "duplicate key '\(key)'")
                }
                table.values[key] = value
            }

        case let .array(path):
            guard let leaf = path.last else {
                throw ConfigError.parseError(line: line, message: "malformed array-of-tables header")
            }
            let parentPath = Array(path.dropLast())
            try root.withTable(at: parentPath) { parent in
                guard var list = parent.arrays[leaf], !list.isEmpty else {
                    throw ConfigError.parseError(line: line, message: "missing array '\(leaf)'")
                }
                var entry = list[list.count - 1]
                if entry.values[key] != nil {
                    throw ConfigError.parseError(line: line, message: "duplicate key '\(key)'")
                }
                entry.values[key] = value
                list[list.count - 1] = entry
                parent.arrays[leaf] = list
            }
        }
    }

    private static func tablePath(_ text: String, line: Int) throws -> [String] {
        let parts = text.split(separator: ".").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty }) else {
            throw ConfigError.parseError(line: line, message: "malformed table header: \(text)")
        }
        return parts.map { String($0) }
    }

    /// Appends a new entry for the array-of-tables at `path`.
    /// - Parameters:
    ///   - path: Dotted array path segments. Must be non-empty.
    ///   - root: Document root.
    ///   - line: 1-based line number for error reporting.
    /// - Throws: ``ConfigError/parseError(line:message:)`` when the path
    ///   is empty.
    private static func appendArrayNode(at path: [String], in root: inout TOMLNode, line: Int) throws {
        guard let leaf = path.last else {
            throw ConfigError.parseError(line: line, message: "malformed array-of-tables header")
        }
        let parentPath = Array(path.dropLast())
        root.withTable(at: parentPath) { parent in
            parent.arrays[leaf, default: []].append(TOMLNode())
        }
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
        if text.hasPrefix("[") {
            return try stringArray(text, line: line)
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

    /// Parses an inline string list such as `["a", "b"]`.
    ///
    /// Only quoted string elements are accepted so numbers and booleans
    /// never coerce silently into patterns; commas inside quotes do not
    /// split. A trailing comma is tolerated and an empty `[]` yields no
    /// elements, matching the permissive TOML array shape used for
    /// deny/allow lists.
    /// - Parameters:
    ///   - text: Raw value text including brackets.
    ///   - line: 1-based line number for error reporting.
    /// - Returns: String array value.
    /// - Throws: ``ConfigError/parseError(line:message:)`` on malformed arrays.
    private static func stringArray(_ text: String, line: Int) throws -> TOMLValue {
        guard text.hasSuffix("]") else {
            throw ConfigError.parseError(line: line, message: "unterminated array: \(text)")
        }
        let inner = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inner.isEmpty else { return .stringArray([]) }
        var elements: [String] = []
        var current = ""
        var inDouble = false
        var inSingle = false
        var index = inner.startIndex
        while index < inner.endIndex {
            let char = inner[index]
            if char == "\\", inDouble, !inSingle {
                let next = inner.index(after: index)
                guard next < inner.endIndex else {
                    throw ConfigError.parseError(line: line, message: "dangling escape in array: \(text)")
                }
                current.append(char)
                current.append(inner[next])
                index = inner.index(after: next)
                continue
            }
            if char == "\"", !inSingle {
                inDouble.toggle()
                current.append(char)
            } else if char == "'", !inDouble {
                inSingle.toggle()
                current.append(char)
            } else if char == ",", !inDouble, !inSingle {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    guard case let .string(value) = try quoted(trimmed, line: line) else {
                        throw ConfigError.parseError(line: line, message: "array elements must be strings: \(text)")
                    }
                    elements.append(value)
                }
                current = ""
            } else {
                current.append(char)
            }
            index = inner.index(after: index)
        }
        let trailing = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trailing.isEmpty {
            guard case let .string(value) = try quoted(trailing, line: line) else {
                throw ConfigError.parseError(line: line, message: "array elements must be strings: \(text)")
            }
            elements.append(value)
        }
        if inDouble || inSingle {
            throw ConfigError.parseError(line: line, message: "unterminated string in array: \(text)")
        }
        return .stringArray(elements)
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
    /// Whether the key is present with any value type.
    /// - Parameter key: Key to check.
    /// - Returns: True when a value was parsed for the key.
    func has(_ key: String) -> Bool {
        values[key] != nil
    }

    /// Strict optional string: nil when absent, throws when present but
    /// not a string so wrong-typed values never silently default.
    /// - Parameters:
    ///   - key: TOML key.
    ///   - field: Dotted field path for error reporting.
    /// - Returns: String value, or nil when absent.
    /// - Throws: `ConfigError.validationError` when present but not a string.
    func strictString(_ key: String, field: String) throws -> String? {
        guard let value = values[key] else { return nil }
        guard case let .string(text) = value else {
            throw ConfigError.validationError(field: field, message: "must be a string")
        }
        return text
    }

    /// Strict optional boolean: nil when absent, throws when present but
    /// not a boolean so values like `enabled="yes"` never silently become true.
    /// - Parameters:
    ///   - key: TOML key.
    ///   - field: Dotted field path for error reporting.
    /// - Returns: Boolean value, or nil when absent.
    /// - Throws: `ConfigError.validationError` when present but not a boolean.
    func strictBool(_ key: String, field: String) throws -> Bool? {
        guard let value = values[key] else { return nil }
        guard case let .boolean(flag) = value else {
            throw ConfigError.validationError(field: field, message: "must be a boolean (true/false)")
        }
        return flag
    }

    /// Strict optional integer: nil when absent, throws when present but
    /// not an integer. Doubles never coerce (so `128.5` throws instead of
    /// truncating to `128`) and strings/booleans never silently default.
    /// - Parameters:
    ///   - key: TOML key.
    ///   - field: Dotted field path for error reporting.
    /// - Returns: Integer value, or nil when absent.
    /// - Throws: `ConfigError.validationError` when present but not an integer.
    func strictInt(_ key: String, field: String) throws -> Int? {
        guard let value = values[key] else { return nil }
        guard case let .integer(number) = value else {
            throw ConfigError.validationError(field: field, message: "must be an integer")
        }
        return number
    }

    /// Strict optional string list: nil when absent, throws when present
    /// but not an inline string array so wrong-typed values never silently
    /// clear the deny list.
    /// - Parameters:
    ///   - key: TOML key.
    ///   - field: Dotted field path for error reporting.
    /// - Returns: String list, or nil when absent.
    /// - Throws: `ConfigError.validationError` when present but not a string array.
    func strictStringArray(_ key: String, field: String) throws -> [String]? {
        guard let value = values[key] else { return nil }
        guard case let .stringArray(items) = value else {
            throw ConfigError.validationError(field: field, message: "must be an array of strings")
        }
        return items
    }
}

extension RuneWeaverConfig {
    /// Builds a config from a parsed TOML document, applying defaults
    /// for every absent optional field.
    /// - Parameter root: Parsed TOML document.
    init(decoding root: TOMLNode) throws {
        var config = RuneWeaverConfig.default
        try Self.decodeEngine(root, into: &config)
        try Self.decodeLLM(root, into: &config)
        try Self.decodeMemory(root, into: &config)
        try Self.decodeVoice(root, into: &config)
        try Self.decodeSandbox(root, into: &config)
        try Self.decodeFiles(root, into: &config)
        try Self.decodeEmail(root, into: &config)
        try Self.decodeHome(root, into: &config)
        try Self.decodeScheduler(root, into: &config)
        try Self.decodePlugins(root, into: &config)
        self = config
    }

    private static func decodeEngine(_ root: TOMLNode, into config: inout RuneWeaverConfig) throws {
        guard let engine = root.tables["engine"] else { return }
        if let name = try engine.strictString("name", field: "engine.name") {
            config.engine.name = name
        }
        if let level = try engine.strictString("log_level", field: "engine.log_level") {
            config.engine.logLevel = level
        }
    }

    private static func decodeLLM(_ root: TOMLNode, into config: inout RuneWeaverConfig) throws {
        guard let llm = root.tables["llm"] else { return }
        if let defaultProvider = try llm.strictString("default_provider", field: "llm.default_provider") {
            config.llm.defaultProvider = defaultProvider
        }
        if llm.has("fallback_provider") {
            // Present-but-wrong-typed values throw via `strictString`
            // instead of silently becoming nil.
            config.llm.fallbackProvider = try llm.strictString("fallback_provider", field: "llm.fallback_provider")
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
    ///
    /// Absent `context_length` decodes to nil (provider-default); the
    /// factory resolves nil per backend (MLX 8192, llama.cpp 4096,
    /// OpenAI-compatible 128000). Present-but-wrong-typed values throw
    /// instead of silently defaulting.
    /// - Parameters:
    ///   - node: Parsed provider table.
    ///   - name: Provider entry name (for error field paths).
    /// - Returns: Decoded provider config.
    /// - Throws: ``ConfigError/validationError(field:message:)`` when
    ///   `api_style` names an unknown style or any present value has the
    ///   wrong type.
    private static func decodeProvider(_ node: TOMLNode, name: String) throws -> ProviderConfig {
        let prefix = "llm.providers.\(name)"
        let apiStyle: APIStyle
        if let raw = try node.strictString("api_style", field: "\(prefix).api_style") {
            guard let style = APIStyle(rawValue: raw) else {
                throw ConfigError.validationError(
                    field: "llm.providers.\(name).api_style",
                    message: "must be one of \(APIStyle.allCases.map(\.rawValue).joined(separator: ", ")) (got '\(raw)')"
                )
            }
            apiStyle = style
        } else {
            apiStyle = .chatCompletions
        }
        let serverURL = try node.strictString("server_url", field: "\(prefix).server_url")
        return try ProviderConfig(
            enabled: node.strictBool("enabled", field: "\(prefix).enabled") ?? true,
            model: node.strictString("model", field: "\(prefix).model"),
            serverURL: serverURL,
            apiKeyEnv: node.strictString("api_key_env", field: "\(prefix).api_key_env"),
            providerType: node.strictString("provider_type", field: "\(prefix).provider_type"),
            apiStyle: apiStyle,
            contextLength: node.strictInt("context_length", field: "\(prefix).context_length")
        )
    }

    private static func decodeMemory(_ root: TOMLNode, into config: inout RuneWeaverConfig) throws {
        guard let memory = root.tables["memory"] else { return }
        if let path = try memory.strictString("vector_db_path", field: "memory.vector_db_path") {
            config.memory.vectorDBPath = path
        }
        if let path = try memory.strictString("episodes_db_path", field: "memory.episodes_db_path") {
            config.memory.episodesDBPath = path
        }
        if let model = try memory.strictString("embedding_model", field: "memory.embedding_model") {
            config.memory.embeddingModel = model
        }
        // Absent backend keeps the local-first default; present values are
        // validated later so a typo surfaces with the dotted field name.
        if let backend = try memory.strictString("embedding_backend", field: "memory.embedding_backend") {
            config.memory.embeddingBackend = backend
        }
    }

    private static func decodeVoice(_ root: TOMLNode, into config: inout RuneWeaverConfig) throws {
        guard let voice = root.tables["voice"] else { return }
        if let provider = try voice.strictString("stt_provider", field: "voice.stt_provider") {
            config.voice.sttProvider = provider
        }
        if let model = try voice.strictString("whisper_model", field: "voice.whisper_model") {
            config.voice.whisperModel = model
        }
        if let provider = try voice.strictString("tts_provider", field: "voice.tts_provider") {
            config.voice.ttsProvider = provider
        }
    }

    private static func decodeSandbox(_ root: TOMLNode, into config: inout RuneWeaverConfig) throws {
        guard let sandbox = root.tables["sandbox"] else { return }
        // Legacy staging keys (`staging_path`, `retention_days`,
        // `max_total_bytes`, `cleanup_interval_seconds`) are intentionally
        // ignored: Tier-3-only detonation has no host staging to bound, so old
        // files carrying the keys keep loading with Tier-3 defaults instead of
        // failing. Old dev-only staging directories are left untouched for
        // manual cleanup with no migration.
        // Legacy `container_runtime` is intentionally ignored: Tier 3 detonation
        // only supports the Apple Container CLI, so old files carrying the key
        // keep loading with the hardcoded default instead of failing.
        if let image = try sandbox.strictString("container_base_image", field: "sandbox.container_base_image") {
            config.sandbox.containerBaseImage = image
        }
        if let ttl = try sandbox.strictInt("archive_session_ttl_minutes", field: "sandbox.archive_session_ttl_minutes") {
            config.sandbox.archiveSessionTTLMinutes = ttl
        }
        if let maxMachines = try sandbox.strictInt("max_concurrent_machines", field: "sandbox.max_concurrent_machines") {
            config.sandbox.maxConcurrentMachines = maxMachines
        }
    }

    private static func decodeFiles(_ root: TOMLNode, into config: inout RuneWeaverConfig) throws {
        guard let files = root.tables["files"] else { return }
        if let patterns = try files.strictStringArray("deny_patterns", field: "files.deny_patterns") {
            config.files.denyPatterns = patterns
        }
        if let roots = try files.strictStringArray("allow_roots", field: "files.allow_roots") {
            config.files.allowRoots = roots
        }
        if let flag = try files.strictBool("require_approval_on_deny", field: "files.require_approval_on_deny") {
            config.files.requireApprovalOnDeny = flag
        }
    }

    private static func decodeEmail(_ root: TOMLNode, into config: inout RuneWeaverConfig) throws {
        guard let email = root.tables["email"] else { return }
        let accountNodes = email.arrays["accounts"] ?? []
        config.email.accounts = try accountNodes.map(decodeEmailAccount)
    }

    private static func decodeEmailAccount(_ node: TOMLNode) throws -> EmailAccount {
        guard let name = try node.strictString("name", field: "email.accounts.name") else {
            throw ConfigError.missingRequired(field: "email.accounts.name")
        }
        guard let host = try node.strictString("host", field: "email.accounts[\(name)].host") else {
            throw ConfigError.missingRequired(
                field: "email.accounts[\(name)].host"
            )
        }
        guard let username = try node.strictString("username", field: "email.accounts[\(name)].username") else {
            throw ConfigError.missingRequired(
                field: "email.accounts[\(name)].username"
            )
        }
        let rawSmtpHost = try node.strictString("smtp_host", field: "email.accounts[\(name)].smtp_host")
        let trimmedSmtpHost = rawSmtpHost?.trimmingCharacters(in: .whitespacesAndNewlines)
        let smtpHost = (trimmedSmtpHost?.isEmpty == false) ? trimmedSmtpHost : nil
        let smtpPort = try node.strictInt("smtp_port", field: "email.accounts[\(name)].smtp_port")
        let smtpSecurity: EmailSMTPSecurity
        if let rawSecurity = try node.strictString("smtp_security", field: "email.accounts[\(name)].smtp_security") {
            let lowered = rawSecurity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let parsed = EmailSMTPSecurity(rawValue: lowered) else {
                throw ConfigError.validationError(
                    field: "email.accounts[\(name)].smtp_security",
                    message: "must be one of \(EmailSMTPSecurity.allCases.map(\.rawValue).joined(separator: ", ")) (got '\(rawSecurity)')"
                )
            }
            smtpSecurity = parsed
        } else {
            smtpSecurity = .auto
        }
        return try EmailAccount(
            name: name,
            type: node.strictString("type", field: "email.accounts[\(name)].type") ?? "imap",
            host: host,
            port: node.strictInt("port", field: "email.accounts[\(name)].port") ?? 993,
            username: username,
            smtpHost: smtpHost,
            smtpPort: smtpPort,
            smtpSecurity: smtpSecurity
        )
    }

    private static func decodeHome(_ root: TOMLNode, into config: inout RuneWeaverConfig) throws {
        guard let home = root.tables["home"] else { return }
        let homekitNodes = home.arrays["homekit"] ?? home.singleAsArray("homekit")
        config.home.homekit = try homekitNodes.map { node in
            try HomeKitConfig(enabled: node.strictBool("enabled", field: "home.homekit.enabled") ?? true)
        }
        let assistantNodes =
            home.arrays["home_assistant"] ?? home.singleAsArray("home_assistant")
        config.home.homeAssistant = try assistantNodes.map { node in
            try HomeAssistantConfig(
                enabled: node.strictBool("enabled", field: "home.home_assistant.enabled") ?? true,
                url: node.strictString("url", field: "home.home_assistant.url"),
                tokenEnv: node.strictString("token_env", field: "home.home_assistant.token_env")
            )
        }
    }

    private static func decodeScheduler(_ root: TOMLNode, into config: inout RuneWeaverConfig) throws {
        guard let scheduler = root.tables["scheduler"] else { return }
        let jobNodes = scheduler.arrays["jobs"] ?? []
        guard !jobNodes.isEmpty else { return }
        config.scheduler.jobs = try jobNodes.map(decodeSchedulerJob)
    }

    private static func decodeSchedulerJob(_ node: TOMLNode) throws -> SchedulerJobConfig {
        guard let name = try node.strictString("name", field: "scheduler.jobs.name") else {
            throw ConfigError.missingRequired(field: "scheduler.jobs.name")
        }
        guard let prompt = try node.strictString("prompt", field: "scheduler.jobs[\(name)].prompt") else {
            throw ConfigError.missingRequired(field: "scheduler.jobs[\(name)].prompt")
        }
        let schedule = try node.strictString("schedule", field: "scheduler.jobs[\(name)].schedule")
        let enabled = try node.strictBool("enabled", field: "scheduler.jobs[\(name)].enabled") ?? true
        let pollAccount = try node.strictString("poll_account", field: "scheduler.jobs[\(name)].poll_account")
        let poll: EmailPollRule?
        if let account = pollAccount {
            let query = try node.strictString("poll_query", field: "scheduler.jobs[\(name)].poll_query") ?? ""
            let mailbox = try node.strictString("poll_mailbox", field: "scheduler.jobs[\(name)].poll_mailbox")
            let interval = try node.strictInt(
                "poll_interval_seconds",
                field: "scheduler.jobs[\(name)].poll_interval_seconds"
            ) ?? EmailPollRule.defaultPollIntervalSeconds
            let limit = try node.strictInt("poll_limit", field: "scheduler.jobs[\(name)].poll_limit") ?? EmailPollRule.defaultLimit
            poll = EmailPollRule(
                account: account,
                query: query,
                mailbox: mailbox,
                pollIntervalSeconds: interval,
                limit: limit
            )
        } else {
            // Atomic poll rule: stray poll fields without an account are
            // rejected (matching REST `SchedulerStore.validated()`) instead
            // of silently dropping them on cron-only jobs.
            if node.has("poll_query") {
                throw ConfigError.validationError(field: "scheduler.jobs[\(name)].poll_query", message: "poll_query requires poll_account")
            }
            if node.has("poll_mailbox") {
                throw ConfigError.validationError(field: "scheduler.jobs[\(name)].poll_mailbox", message: "poll_mailbox requires poll_account")
            }
            if node.has("poll_interval_seconds") {
                throw ConfigError.validationError(
                    field: "scheduler.jobs[\(name)].poll_interval_seconds",
                    message: "poll_interval_seconds requires poll_account"
                )
            }
            if node.has("poll_limit") {
                throw ConfigError.validationError(field: "scheduler.jobs[\(name)].poll_limit", message: "poll_limit requires poll_account")
            }
            poll = nil
        }
        return SchedulerJobConfig(name: name, prompt: prompt, enabled: enabled, schedule: schedule, poll: poll)
    }

    private static func decodePlugins(_ root: TOMLNode, into config: inout RuneWeaverConfig) throws {
        guard let plugins = root.tables["plugins"] else { return }
        if let dir = try plugins.strictString("plugins_dir", field: "plugins.plugins_dir") {
            config.plugins.pluginsDir = dir
        }
        if let url = try plugins.strictString("marketplace_index_url", field: "plugins.marketplace_index_url") {
            config.plugins.marketplaceIndexURL = url
        }
        if let autoRescan = try plugins.strictBool("auto_rescan", field: "plugins.auto_rescan") {
            config.plugins.autoRescan = autoRescan
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

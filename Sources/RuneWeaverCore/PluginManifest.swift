// Rune Weaver Core — Plugin manifest specification, parsing, and validation.

import Foundation

/// Runtime execution environment for a plugin.
public enum PluginRuntime: String, Sendable, Codable, CaseIterable {
    /// Python script executed in an isolated subprocess via JSON-RPC over stdin/stdout.
    case python
    /// Compiled binary or script executed directly in a sandboxed subprocess.
    case executable
}

/// Optional declared capabilities required by a plugin for static auditing.
public struct PluginCapabilities: Sendable, Codable, Equatable {
    /// External network hostnames or domains the plugin communicates with.
    public var network: [String]
    /// Local directory paths or sandbox targets the plugin accesses.
    public var filesystem: [String]
    /// Environment variables or injected secret keys required by the plugin.
    public var env: [String]

    /// Creates a capabilities descriptor.
    public init(
        network: [String] = [],
        filesystem: [String] = [],
        env: [String] = []
    ) {
        self.network = network
        self.filesystem = filesystem
        self.env = env
    }

    private enum CodingKeys: String, CodingKey {
        case network
        case filesystem
        case env
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        network = try container.decodeIfPresent([String].self, forKey: .network) ?? []
        filesystem = try container.decodeIfPresent([String].self, forKey: .filesystem) ?? []
        env = try container.decodeIfPresent([String].self, forKey: .env) ?? []
    }
}

/// Declaration of a required or optional credential for a plugin.
public struct PluginCredentialDeclaration: Sendable, Codable, Equatable {
    /// Environment variable or secret key (e.g. `"MONARCH_TOKEN"`).
    public let key: String
    /// Human-friendly display label (e.g. `"API Token (Recommended)"`).
    public let label: String
    /// Human-friendly instructions or context explaining where to find the secret.
    public let description: String?
    /// Whether the plugin strictly requires this credential to function.
    public let required: Bool

    public init(
        key: String,
        label: String? = nil,
        description: String? = nil,
        required: Bool = false
    ) {
        self.key = key
        self.label = label ?? key
        self.description = description
        self.required = required
    }

    private enum CodingKeys: String, CodingKey {
        case key
        case label
        case description
        case required
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let key = try container.decode(String.self, forKey: .key)
        self.key = key
        self.label = try container.decodeIfPresent(String.self, forKey: .label) ?? key
        self.description = try container.decodeIfPresent(String.self, forKey: .description)
        self.required = try container.decodeIfPresent(Bool.self, forKey: .required) ?? false
    }
}

/// Declaration of a configurable user option for a plugin.
public struct PluginOptionDeclaration: Sendable, Codable, Equatable {
    /// Configuration key identifier (e.g. `"session_file"`).
    public let key: String
    /// Human-friendly display label (e.g. `"Session Cache File"`).
    public let label: String
    /// Help text explaining what this setting controls.
    public let description: String?
    /// Option data type: `"string"`, `"boolean"`, `"number"`, or `"select"`.
    public let type: String
    /// Default value serialized as string.
    public let defaultValue: String?
    /// Available choices if type is `"select"`.
    public let options: [String]?

    public init(
        key: String,
        label: String? = nil,
        description: String? = nil,
        type: String = "string",
        defaultValue: String? = nil,
        options: [String]? = nil
    ) {
        self.key = key
        self.label = label ?? key
        self.description = description
        self.type = type
        self.defaultValue = defaultValue
        self.options = options
    }

    private enum CodingKeys: String, CodingKey {
        case key
        case label
        case description
        case type
        case defaultValue
        case options
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let key = try container.decode(String.self, forKey: .key)
        self.key = key
        self.label = try container.decodeIfPresent(String.self, forKey: .label) ?? key
        self.description = try container.decodeIfPresent(String.self, forKey: .description)
        self.type = try container.decodeIfPresent(String.self, forKey: .type) ?? "string"
        self.defaultValue = try container.decodeIfPresent(String.self, forKey: .defaultValue)
        self.options = try container.decodeIfPresent([String].self, forKey: .options)
    }
}

/// Declaration of a single tool exposed by a plugin.
public struct PluginToolDeclaration: Sendable, Codable, Equatable {
    /// Stable tool name (e.g. `"browser.navigate"`).
    public let name: String
    /// Instructions for the LLM explaining when and how to call the tool.
    public let description: String
    /// Function-calling JSON schema string.
    public let inputSchema: String
    /// Requested permission level (`readOnly` or `requiresApproval`).
    public let permissionLevel: PermissionLevel
    /// Declared operational capabilities.
    public let capabilities: PluginCapabilities?

    /// Creates a tool declaration.
    public init(
        name: String,
        description: String,
        inputSchema: String,
        permissionLevel: PermissionLevel,
        capabilities: PluginCapabilities? = nil
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.permissionLevel = permissionLevel
        self.capabilities = capabilities
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case description
        case inputSchema = "input_schema"
        case permissionLevel = "permission_level"
        case capabilities
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""

        // Schema can be encoded either as a raw JSON string or an arbitrary nested JSON object.
        if let rawSchema = try? container.decode(String.self, forKey: .inputSchema) {
            inputSchema = rawSchema
        } else {
            // Encode arbitrary object back to normalized JSON string
            let rawData = try container.decode(SendableJSON.self, forKey: .inputSchema)
            let data = try JSONEncoder().encode(rawData)
            inputSchema = String(data: data, encoding: .utf8) ?? "{}"
        }

        let permRaw = try container.decode(String.self, forKey: .permissionLevel)
        guard let level = PermissionLevel(rawValue: permRaw) else {
            throw PluginManifestError.invalidPermissionLevel(
                tool: name,
                level: permRaw,
                reason: "Unknown permission level '\(permRaw)'"
            )
        }
        guard level != .trusted else {
            throw PluginManifestError.trustedPermissionProhibited(
                tool: name,
                reason: "External plugins are prohibited from declaring 'trusted' permission level. Only 'readOnly' and 'requiresApproval' are permitted."
            )
        }
        permissionLevel = level
        capabilities = try container.decodeIfPresent(PluginCapabilities.self, forKey: .capabilities)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(description, forKey: .description)
        try container.encode(inputSchema, forKey: .inputSchema)
        try container.encode(permissionLevel.rawValue, forKey: .permissionLevel)
        try container.encodeIfPresent(capabilities, forKey: .capabilities)
    }
}

/// Manifest specification for an external or community rune package (`rune.json` / `plugin.json`).
public struct PluginManifest: Sendable, Codable, Equatable {
    /// Unique identifier (e.g. `"community.playwright-browser"`).
    public let id: String
    /// Human-readable display name.
    public let name: String
    /// Semantic version.
    public let version: String
    /// Package author or organization.
    public let author: String?
    /// Short summary of the plugin's capabilities.
    public let description: String
    /// Subprocess runtime environment.
    public let runtime: PluginRuntime
    /// Script or executable path relative to the plugin root directory.
    public let entrypoint: String
    /// Tools provided by this plugin.
    public let tools: [PluginToolDeclaration]
    /// Optional credential declarations for the plugin.
    public let credentials: [PluginCredentialDeclaration]?
    /// Optional configuration options exposed by the plugin.
    public let options: [PluginOptionDeclaration]?

    /// Effective credential declarations: uses explicit `credentials` if defined; otherwise
    /// synthesizes declarations from tools' `capabilities.env`.
    public var effectiveCredentials: [PluginCredentialDeclaration] {
        if let explicit = credentials, !explicit.isEmpty {
            return explicit
        }
        var seen = Set<String>()
        var synthesized: [PluginCredentialDeclaration] = []
        for tool in tools {
            for envKey in tool.capabilities?.env ?? [] where !seen.contains(envKey) {
                seen.insert(envKey)
                synthesized.append(
                    PluginCredentialDeclaration(
                        key: envKey,
                        label: envKey,
                        description: "Secret required by '\(tool.name)'",
                        required: false
                    )
                )
            }
        }
        return synthesized
    }

    /// All external network hosts declared across all tools in the plugin.
    public var effectiveNetworkHosts: [String] {
        var seen = Set<String>()
        var hosts: [String] = []
        for tool in tools {
            for host in tool.capabilities?.network ?? [] where !seen.contains(host) {
                seen.insert(host)
                hosts.append(host)
            }
        }
        return hosts
    }

    /// Creates a validated plugin manifest.
    public init(
        id: String,
        name: String,
        version: String,
        author: String? = nil,
        description: String,
        runtime: PluginRuntime,
        entrypoint: String,
        tools: [PluginToolDeclaration],
        credentials: [PluginCredentialDeclaration]? = nil,
        options: [PluginOptionDeclaration]? = nil
    ) throws {
        self.id = id
        self.name = name
        self.version = version
        self.author = author
        self.description = description
        self.runtime = runtime
        self.entrypoint = entrypoint
        self.tools = tools
        self.credentials = credentials
        self.options = options
        try validate()
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case version
        case author
        case description
        case runtime
        case entrypoint
        case tools
        case credentials
        case options
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decode(String.self, forKey: .version)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        do {
            runtime = try container.decode(PluginRuntime.self, forKey: .runtime)
        } catch {
            throw PluginManifestError.invalidField(
                field: "runtime",
                reason: "Runtime must be one of: python, executable. In-process native dynamic loading is not supported."
            )
        }
        entrypoint = try container.decode(String.self, forKey: .entrypoint)
        tools = try container.decode([PluginToolDeclaration].self, forKey: .tools)
        credentials = try container.decodeIfPresent([PluginCredentialDeclaration].self, forKey: .credentials)
        options = try container.decodeIfPresent([PluginOptionDeclaration].self, forKey: .options)
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(version, forKey: .version)
        try container.encodeIfPresent(author, forKey: .author)
        try container.encode(description, forKey: .description)
        try container.encode(runtime.rawValue, forKey: .runtime)
        try container.encode(entrypoint, forKey: .entrypoint)
        try container.encode(tools, forKey: .tools)
        try container.encodeIfPresent(credentials, forKey: .credentials)
        try container.encodeIfPresent(options, forKey: .options)
    }

    /// Performs invariant validation on the manifest fields.
    public func validate() throws {
        try validateIdentity()
        try validateEntrypoint()
        try validateToolDeclarations()
        try validateCredentialDeclarations()
        try validateOptionDeclarations()
    }

    private func validateIdentity() throws {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PluginManifestError.invalidField(field: "id", reason: "Plugin ID must not be empty.")
        }
        guard id.range(of: "^[a-zA-Z0-9_.-]+$", options: .regularExpression) != nil else {
            throw PluginManifestError.invalidField(
                field: "id",
                reason: "Plugin ID '\(id)' contains invalid characters. Only alphanumeric, '.', '-', and '_' are allowed."
            )
        }
        // The character allowlist alone still permits "." and "..", which would resolve to the pen
        // itself or its parent when used as a directory name. Reject them explicitly so manifest
        // validation holds even when a caller forgets the route-level containment check.
        if id == "." || id == ".." || id.contains("..") || id.contains("/") || id.contains("\\") {
            throw PluginManifestError.invalidField(
                field: "id",
                reason: "Plugin ID '\(id)' must not be '.'/'..' or contain path separators or parent traversal."
            )
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PluginManifestError.invalidField(field: "name", reason: "Plugin name must not be empty.")
        }
        // Empty versions pass decoding yet yield untraceable records downstream.
        guard !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PluginManifestError.invalidField(field: "version", reason: "Plugin version must not be empty.")
        }
    }

    private func validateEntrypoint() throws {
        guard !entrypoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PluginManifestError.invalidField(field: "entrypoint", reason: "Entrypoint must not be empty.")
        }
        // Entrypoint path traversal protection: cannot escape plugin root
        if entrypoint.contains("..") || entrypoint.hasPrefix("/") || entrypoint.hasPrefix("\\") {
            throw PluginManifestError.pathTraversalProhibited(entrypoint: entrypoint)
        }
        guard !tools.isEmpty else {
            throw PluginManifestError.invalidField(field: "tools", reason: "Plugin must declare at least one tool.")
        }
    }

    private static let reservedToolPrefixes = [
        "memory.", "memories.", "messages.", "email.", "config.", "scheduler.", "approvals.", "system."
    ]

    private func validateToolDeclarations() throws {
        var seenNames = Set<String>()
        for tool in tools {
            try validateSingleTool(tool, seenNames: &seenNames)
        }
    }

    private func validateSingleTool(_ tool: PluginToolDeclaration, seenNames: inout Set<String>) throws {
        let toolName = tool.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !toolName.isEmpty else {
            throw PluginManifestError.invalidField(field: "tools.name", reason: "Tool name cannot be empty.")
        }
        if seenNames.contains(toolName) {
            throw PluginManifestError.duplicateToolName(toolName)
        }
        seenNames.insert(toolName)
        try rejectReservedToolName(toolName)
        try rejectMalformedToolSchema(tool, toolName: toolName)
    }

    /// Reserved names stay barred even when a manifest otherwise parses.
    private func rejectReservedToolName(_ toolName: String) throws {
        let isReserved = toolName == "memories.store" || toolName == "memories.recall"
        let usesReservedPrefix = Self.reservedToolPrefixes.contains(where: { toolName.hasPrefix($0) })
        if isReserved || usesReservedPrefix {
            throw PluginManifestError.reservedToolName(tool: toolName, reason: "Reserved for core system engine.")
        }
    }

    /// Malformed schemas fail closed so registration never serves an uncallable tool.
    private func rejectMalformedToolSchema(_ tool: PluginToolDeclaration, toolName: String) throws {
        guard let schemaData = tool.inputSchema.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: schemaData)) is [String: Any]
        else {
            throw PluginManifestError.invalidJSONSchema(tool: toolName, schema: tool.inputSchema)
        }
    }

    private func validateCredentialDeclarations() throws {
        // Blank or duplicate credential keys would surface as empty auth rows.
        guard let creds = credentials else { return }
        var seenCredKeys = Set<String>()
        for cred in creds {
            let credKey = cred.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !credKey.isEmpty else {
                throw PluginManifestError.invalidField(field: "credentials.key", reason: "Credential key must not be empty.")
            }
            guard seenCredKeys.insert(credKey).inserted else {
                throw PluginManifestError.invalidField(field: "credentials.key", reason: "Duplicate credential key '\(credKey)'.")
            }
        }
    }

    private func validateOptionDeclarations() throws {
        // Unknown option types and empty select choices break dummy-proof config.
        guard let opts = options else { return }
        let allowedTypes = Set(["string", "boolean", "number", "select"])
        var seenOptKeys = Set<String>()
        for opt in opts {
            try validateSingleOption(opt, seenKeys: &seenOptKeys, allowedTypes: allowedTypes)
        }
    }

    private func validateSingleOption(
        _ opt: PluginOptionDeclaration,
        seenKeys: inout Set<String>,
        allowedTypes: Set<String>
    ) throws {
        let optKey = opt.key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !optKey.isEmpty else {
            throw PluginManifestError.invalidField(field: "options.key", reason: "Option key must not be empty.")
        }
        guard seenKeys.insert(optKey).inserted else {
            throw PluginManifestError.invalidField(field: "options.key", reason: "Duplicate option key '\(optKey)'.")
        }
        guard allowedTypes.contains(opt.type) else {
            throw PluginManifestError.invalidField(field: "options.type", reason: "Unknown option type '\(opt.type)' for key '\(optKey)'.")
        }
        if opt.type == "select" {
            guard let choices = opt.options, !choices.isEmpty else {
                throw PluginManifestError.invalidField(field: "options.options", reason: "Select option '\(optKey)' must declare non-empty options.")
            }
        }
    }

    /// Loads and validates a manifest from JSON data.
    public static func from(jsonData: Data) throws -> PluginManifest {
        let decoder = JSONDecoder()
        do {
            let manifest = try decoder.decode(PluginManifest.self, from: jsonData)
            try manifest.validate()
            return manifest
        } catch let manifestError as PluginManifestError {
            throw manifestError
        } catch let decodingError as DecodingError {
            throw PluginManifestError.invalidField(field: "manifest", reason: "\(decodingError)")
        } catch {
            throw PluginManifestError.invalidField(field: "manifest", reason: error.localizedDescription)
        }
    }
}

/// Errors raised during plugin manifest decoding and validation.
public enum PluginManifestError: Error, Sendable, Equatable, LocalizedError {
    case invalidField(field: String, reason: String)
    case pathTraversalProhibited(entrypoint: String)
    case invalidPermissionLevel(tool: String, level: String, reason: String)
    case trustedPermissionProhibited(tool: String, reason: String)
    case reservedToolName(tool: String, reason: String)
    case duplicateToolName(String)
    case invalidJSONSchema(tool: String, schema: String)

    public var errorDescription: String? {
        switch self {
        case let .invalidField(field, reason):
            "Invalid manifest field '\(field)': \(reason)"
        case let .pathTraversalProhibited(entrypoint):
            "Plugin entrypoint '\(entrypoint)' contains illegal path traversal segments or absolute path."
        case let .invalidPermissionLevel(tool, level, reason):
            "Tool '\(tool)' declared invalid permission level '\(level)': \(reason)"
        case let .trustedPermissionProhibited(tool, reason):
            "Security violation in tool '\(tool)': \(reason)"
        case let .reservedToolName(tool, reason):
            "Tool name '\(tool)' is reserved: \(reason)"
        case let .duplicateToolName(name):
            "Duplicate tool declaration for '\(name)'."
        case let .invalidJSONSchema(tool, _):
            "Tool '\(tool)' contains malformed JSON schema."
        }
    }
}

/// Helper for decoding arbitrary Sendable JSON objects in schemas.
private enum SendableJSON: Sendable, Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([SendableJSON])
    case object([String: SendableJSON])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let boolVal = try? container.decode(Bool.self) {
            self = .bool(boolVal)
        } else if let intVal = try? container.decode(Int.self) {
            self = .int(intVal)
        } else if let doubleVal = try? container.decode(Double.self) {
            self = .double(doubleVal)
        } else if let strVal = try? container.decode(String.self) {
            self = .string(strVal)
        } else if let arr = try? container.decode([SendableJSON].self) {
            self = .array(arr)
        } else if let dict = try? container.decode([String: SendableJSON].self) {
            self = .object(dict)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown JSON value")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(strVal): try container.encode(strVal)
        case let .int(intVal): try container.encode(intVal)
        case let .double(doubleVal): try container.encode(doubleVal)
        case let .bool(boolVal): try container.encode(boolVal)
        case let .array(arr): try container.encode(arr)
        case let .object(obj): try container.encode(obj)
        case .null: try container.encodeNil()
        }
    }
}

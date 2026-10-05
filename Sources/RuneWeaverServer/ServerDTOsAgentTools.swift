// Rune Weaver Server — Workspace and hash-pinned agent tool DTOs.
//
// Purpose: carry the workspace usage/prune shapes plus the `/agent-tools`
// pin-registry wire contracts between the engine stores and the dashboard.
// Scope: workspace usage/prune plus tool promote/list/verify/remove payloads
// only; persistence, hashing, and routing live with the Core stores and routes.
// Architectural role: Codable boundary beside ServerDTOs so the scratch-quota
// and pin-registry surfaces stay single-sourced across REST and WebSocket.

import Foundation
import RuneWeaverCore
import Vapor

// MARK: - Workspace + Agent Tools

/// Usage snapshot for `GET /workspace/usage`.
///
/// Carries the bounded walk counts alongside the configured quotas so the
/// dashboard renders a quota bar from one fetch; the walk never follows
/// symlinks, and `truncated` tells the viewer the counts are lower bounds.
public struct WorkspaceUsageResponse: Content, Equatable {
    /// Total bytes across counted regular files.
    public let bytes: Int
    /// Total regular files counted.
    public let files: Int
    /// Whether the walk stopped at the entry cap before covering the tree.
    public let truncated: Bool
    /// Configured size cap in megabytes.
    public let quotaMB: Int
    /// Configured file cap.
    public let quotaFiles: Int

    /// Creates a usage response.
    public init(bytes: Int, files: Int, truncated: Bool, quotaMB: Int, quotaFiles: Int) {
        self.bytes = bytes
        self.files = files
        self.truncated = truncated
        self.quotaMB = quotaMB
        self.quotaFiles = quotaFiles
    }
}

/// Prune receipt for `POST /workspace/tmp/prune`.
public struct WorkspacePruneResponse: Content, Equatable {
    /// Number of top-level `tmp/` entries removed.
    public let removed: Int

    /// Creates a prune receipt.
    public init(removed: Int) {
        self.removed = removed
    }
}

/// Wire shape of one pinned agent script for the `/agent-tools` routes.
///
/// Dates travel as server instants so dashboards render recency without
/// sharing a date strategy; `scriptPath` encodes camelCase while decoding
/// accepts the snake alias the promotion request advertises, so older
/// dashboards keep decoding.
public struct AgentToolDTO: Content, Sendable, Equatable {
    /// Stable row identifier.
    public let id: UUID
    /// Registry name.
    public let name: String
    /// Absolute script path inside `workspace/tools/`.
    public let scriptPath: String
    /// Pinned SHA-256 hex.
    public let sha256: String
    /// Lifecycle state (`enabled` or `disabled`).
    public let status: String
    /// When the row was first persisted.
    public let createdAt: Date
    /// When the row last changed.
    public let updatedAt: Date

    /// Creates a DTO.
    public init(id: UUID, name: String, scriptPath: String, sha256: String, status: String, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.scriptPath = scriptPath
        self.sha256 = sha256
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Builds a DTO from a stored row.
    public init(_ record: AgentToolRecord) {
        self.init(
            id: record.id,
            name: record.name,
            scriptPath: record.scriptPath,
            sha256: record.sha256,
            status: record.status.rawValue,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case scriptPath
        case scriptPathSnake = "script_path"
        case sha256
        case status
        case createdAt
        case updatedAt
    }

    /// Decodes tolerantly so snake-case promotion payloads still parse.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        if let camel = try container.decodeIfPresent(String.self, forKey: .scriptPath) {
            scriptPath = camel
        } else if let snake = try container.decodeIfPresent(String.self, forKey: .scriptPathSnake) {
            scriptPath = snake
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.scriptPath,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Missing script path"
                )
            )
        }
        sha256 = try container.decode(String.self, forKey: .sha256)
        status = try container.decode(String.self, forKey: .status)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    /// Encodes on the canonical camelCase keys.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(scriptPath, forKey: .scriptPath)
        try container.encode(sha256, forKey: .sha256)
        try container.encode(status, forKey: .status)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

/// Listing response for `GET /agent-tools`.
public struct AgentToolsResponse: Content, Equatable {
    /// Pinned rows ordered by name.
    public let tools: [AgentToolDTO]
    /// Number of rows in `tools`.
    public let count: Int

    /// Creates a listing response.
    public init(tools: [AgentToolDTO]) {
        self.tools = tools
        self.count = tools.count
    }
}

/// Promotion request for `POST /agent-tools/promote`.
public struct PromoteAgentToolRequest: Content, Equatable {
    /// Registry name for later runs.
    public let name: String?
    /// Script path inside `workspace/tools/`; snake is canonical.
    public let scriptPath: String?

    /// Creates a promote request.
    public init(name: String? = nil, scriptPath: String? = nil) {
        self.name = name
        self.scriptPath = scriptPath
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case scriptPath
        case scriptPathSnake = "script_path"
        case path
    }

    /// Decodes accepting the camel, snake, and short aliases so hand-built
    /// curls and dashboard forms agree without a second parameter.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        if let snake = try container.decodeIfPresent(String.self, forKey: .scriptPathSnake) {
            scriptPath = snake
        } else if let camel = try container.decodeIfPresent(String.self, forKey: .scriptPath) {
            scriptPath = camel
        } else if let short = try container.decodeIfPresent(String.self, forKey: .path) {
            scriptPath = short
        } else {
            scriptPath = nil
        }
    }

    /// Encodes on the canonical snake key.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(scriptPath, forKey: .scriptPathSnake)
    }

    /// Trimmed registry name, or nil when absent or blank.
    public var resolvedName: String? {
        guard let name else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Trimmed script path, or nil when absent or blank.
    public var resolvedScriptPath: String? {
        guard let scriptPath else { return nil }
        let trimmed = scriptPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Status patch for `PATCH /agent-tools/:id`.
///
/// Accepts the canonical `status` string (`enabled`/`disabled`), the boolean
/// `enabled` flag the tool-state route uses, and the `enable`/`disable`
/// action verbs dashboards sometimes send, so all three spellings converge
/// on one state instead of 400ing.
public struct PatchAgentToolRequest: Content, Equatable {
    /// Canonical status string, when supplied.
    public let status: String?
    /// Boolean flag, when supplied.
    public let enabled: Bool?
    /// Action verb, when supplied.
    public let action: String?

    /// Creates a patch request.
    public init(status: String? = nil, enabled: Bool? = nil, action: String? = nil) {
        self.status = status
        self.enabled = enabled
        self.action = action
    }

    /// Resolves the requested state, or nil when nothing usable was supplied.
    public var resolvedStatus: AgentToolStatus? {
        if let status {
            let trimmed = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if trimmed == AgentToolStatus.enabled.rawValue {
                return .enabled
            }
            if trimmed == AgentToolStatus.disabled.rawValue {
                return .disabled
            }
        }
        if let action {
            let trimmed = action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if trimmed == "enable" {
                return .enabled
            }
            if trimmed == "disable" {
                return .disabled
            }
        }
        if let enabled {
            return enabled ? .enabled : .disabled
        }
        return nil
    }
}

/// Verified run request for `POST /agent-tools/:id/run`.
public struct RunAgentToolRequest: Content, Equatable {
    /// Caller arguments appended after `--` as literal argv.
    public let argv: [String]?

    /// Creates a run request.
    public init(argv: [String]? = nil) {
        self.argv = argv
    }

    private enum CodingKeys: String, CodingKey {
        case argv
        case args
        case arguments
    }

    /// Decodes accepting the `args`/`arguments` aliases the tool decoder honors.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let direct = try container.decodeIfPresent([String].self, forKey: .argv) {
            argv = direct
        } else if let alias = try container.decodeIfPresent([String].self, forKey: .args) {
            argv = alias
        } else if let plural = try container.decodeIfPresent([String].self, forKey: .arguments) {
            argv = plural
        } else {
            argv = nil
        }
    }

    /// Encodes on the canonical key.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(argv, forKey: .argv)
    }

    /// Effective argv, defaulting an omitted list to empty.
    public var resolvedArgv: [String] {
        argv ?? []
    }
}

// Rune Weaver Server — Shared REST and WebSocket contracts for the engine API.

import Foundation
import RuneWeaverCore
import Vapor

/// Canonical route paths for the engine API.
public enum ServerPaths {
    /// Health probe.
    public static let health = "health"
    /// Chat turn.
    public static let chat = "chat"
    /// Tool registry and invocation.
    public static let tools = "tools"
    /// Tool invocation subpath under `/tools`.
    public static let toolCall = "call"
    /// Memory group.
    public static let memory = "memory"
    /// Memory search subpath under `/memory`.
    public static let memorySearch = "search"
    /// Memory facts subpath under `/memory`.
    public static let memoryFacts = "facts"
    /// Pending approvals group.
    public static let approvals = "approvals"
    /// Approval decision subpath under `/approvals/:id`.
    public static let decide = "decide"
    /// Durable trust grants subpath under `/approvals`.
    public static let grants = "grants"
    /// Scheduler group.
    public static let scheduler = "scheduler"
    /// Scheduler jobs subpath under `/scheduler`.
    public static let jobs = "jobs"
    /// Manual job run subpath under `/scheduler/jobs/:id`.
    public static let run = "run"
    /// Search group serving the local SearXNG lifecycle.
    public static let search = "search"
    /// Search health subpath under `/search`.
    public static let searchHealth = "health"
    /// Search ensure subpath under `/search`.
    public static let searchEnsure = "ensure"
    /// Search stop subpath under `/search`.
    public static let searchStop = "stop"
    /// Run log group.
    public static let runs = "runs"
    /// Sessions group.
    public static let sessions = "sessions"
    /// Structured tool actions subpath under `/sessions/:id`.
    public static let toolActions = "tool-actions"
    /// WebSocket endpoint for streamed chat plus live approval prompts.
    public static let websocket = "ws"
    /// Settings group.
    public static let settings = "settings"
    /// Plugins group.
    public static let plugins = "plugins"
    /// Plugin rescan subpath.
    public static let rescan = "rescan"
    /// Plugin state subpath.
    public static let state = "state"
    /// Marketplace group.
    public static let marketplace = "marketplace"
    /// Marketplace install subpath.
    public static let install = "install"
    /// Engine API version served on `/health`.
    /// Single-sourced through `RuneWeaverVersion` so health, User-Agents,
    /// and providers cannot drift.
    public static var apiVersion: String {
        RuneWeaverVersion.current
    }
}

/// Shared trimming-plus-default helpers for REST and WebSocket DTOs.
public enum DTODefaults {
    /// Trims an optional string, falling back when blank.
    public static func blankToDefault(_ value: String?, default defaultValue: String) -> String {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultValue : trimmed
    }

    /// Origin label, defaulting blanks to `"api"`.
    /// - Parameter value: Raw source value.
    /// - Returns: Trimmed source, or `"api"` when blank.
    public static func source(_ value: String?) -> String {
        blankToDefault(value, default: "api")
    }

    /// Raw JSON arguments, defaulting blanks to `"{}"`.
    /// - Parameter value: Raw arguments document.
    /// - Returns: Trimmed arguments, or `"{}"` when blank.
    public static func argumentsJSON(_ value: String?) -> String {
        blankToDefault(value, default: "{}")
    }

    /// Correlation identifier, generating one when blank.
    /// - Parameter value: Raw call identifier.
    /// - Returns: Trimmed identifier, or a new UUID string when blank.
    public static func callID(_ value: String?) -> String {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? UUID().uuidString : trimmed
    }

    /// Trust tier, defaulting to `thisTime` (one-shot).
    /// - Parameter value: Raw duration, if any.
    /// - Returns: Resolved duration.
    public static func duration(_ value: TrustDuration?) -> TrustDuration {
        value ?? .thisTime
    }
}

/// Health probe response for `GET /health`.
public struct HealthResponse: Content, Equatable {
    /// Always `"ok"` when the engine answers.
    public let status: String
    /// Engine display name.
    public let engine: String
    /// Engine API version.
    public let version: String
    /// Active serving model name.
    public let model: String?
    /// Active serving provider name.
    public let provider: String?
    /// Active context window limit.
    public let contextLength: Int?
    /// Whether the configured SearXNG URL answered (populated when known).
    public let searchReachable: Bool?
    /// Configured SearXNG base URL that was probed, when known.
    public let searchURL: String?
    /// Collapsed search status (`"running"`, `"stopped"`, or nil when unknown).
    public let searchStatus: String?

    /// Creates a health response.
    public init(
        status: String = "ok",
        engine: String = "Rune Weaver",
        version: String = ServerPaths.apiVersion,
        model: String? = nil,
        provider: String? = nil,
        contextLength: Int? = nil,
        searchReachable: Bool? = nil,
        searchURL: String? = nil,
        searchStatus: String? = nil
    ) {
        self.status = status
        self.engine = engine
        self.version = version
        self.model = model
        self.provider = provider
        self.contextLength = contextLength
        self.searchReachable = searchReachable
        self.searchURL = searchURL
        self.searchStatus = searchStatus
    }
}

/// Chat turn request for `POST /chat`.
public struct ChatRequest: Content, Equatable {
    /// Maximum accepted user text length, mirroring
    /// `MemoryEngine/maxContentLength` so the API rejects huge bodies with
    /// `413` before they reach the run log or the orchestrator.
    public static var maxTextLength: Int {
        MemoryEngine.maxContentLength
    }

    /// Raw user text.
    public let text: String
    /// Owning session. A new session starts when omitted.
    public var sessionID: UUID?
    /// Input origin (e.g. `"dashboard"`). Defaults to `"api"`.
    public var source: String?

    /// Creates a chat request.
    public init(text: String, sessionID: UUID? = nil, source: String? = nil) {
        self.text = text
        self.sessionID = sessionID
        self.source = source
    }

    /// Session to process under, generating one when omitted.
    /// - Returns: Owning session identifier.
    public var resolvedSessionID: UUID {
        sessionID ?? UUID()
    }

    /// Origin label, defaulting blanks to `"api"`.
    /// - Returns: Trimmed source, or `"api"` when blank.
    public var resolvedSource: String {
        DTODefaults.source(source)
    }
}

/// One tool in the registry for `GET /tools`.
public struct ToolInfo: Content, Equatable {
    /// Stable tool name (e.g. `"email.search"`).
    public let name: String
    /// When the LLM should use this tool.
    public let description: String
    /// Graduated-trust level (`readOnly`, `requiresApproval`, `trusted`).
    public let permissionLevel: String
    /// Raw JSON Schema for the tool input.
    public let inputSchema: String
    /// Whether this tool is currently enabled on the live bus.
    public let isEnabled: Bool
    /// Whether this tool is a built-in core capability vs external plugin.
    public let isBuiltIn: Bool
    /// Plugin ID owning this tool, if non-built-in.
    public let pluginID: String?
    /// Origin (`"builtin"`, `"local_disk"`, `"marketplace"`, `"agent_generated"`).
    public let source: String
    /// Integrity status (`"valid"`, `"tampered"`, `"unverified"`).
    public let integrityStatus: String

    /// Creates a tool info row.
    public init(
        name: String,
        description: String,
        permissionLevel: String,
        inputSchema: String,
        isEnabled: Bool = true,
        isBuiltIn: Bool = true,
        pluginID: String? = nil,
        source: String = "builtin",
        integrityStatus: String = "valid"
    ) {
        self.name = name
        self.description = description
        self.permissionLevel = permissionLevel
        self.inputSchema = inputSchema
        self.isEnabled = isEnabled
        self.isBuiltIn = isBuiltIn
        self.pluginID = pluginID
        self.source = source
        self.integrityStatus = integrityStatus
    }

    /// Creates a row from a runtime tool.
    /// - Parameter tool: Registered tool.
    public init(
        _ tool: any Tool,
        isEnabled: Bool = true,
        isBuiltIn: Bool = true,
        pluginID: String? = nil,
        source: String = "builtin",
        integrityStatus: String = "valid"
    ) {
        self.name = tool.name
        self.description = tool.description
        switch tool.permissionLevel {
        case .readOnly: self.permissionLevel = "readOnly"
        case .requiresApproval: self.permissionLevel = "requiresApproval"
        case .trusted: self.permissionLevel = "trusted"
        }
        self.inputSchema = tool.inputSchema.rawValue
        self.isEnabled = isEnabled
        self.isBuiltIn = isBuiltIn
        self.pluginID = pluginID
        self.source = source
        self.integrityStatus = integrityStatus
    }
}

/// Tool registry response for `GET /tools`.
public struct ToolsResponse: Content, Equatable {
    /// Registered tools in no guaranteed order.
    public let tools: [ToolInfo]
    /// Number of tools in `tools`.
    public let count: Int

    /// Creates a tools response.
    /// - Parameter tools: Registered tools.
    public init(tools: [ToolInfo]) {
        self.tools = tools
        self.count = tools.count
    }
}

/// Summary of an installed or discovered rune package.
public struct PluginSummary: Content, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let version: String
    public let author: String?
    public let description: String
    public let runtime: String
    public let source: String
    public let status: String
    public let isEnabled: Bool
    public let integrityHash: String?
    public let toolsCount: Int
    public let tools: [ToolInfo]
    public let permissionOverrides: [String: String]
    public let discoveredAt: Date
    public let updatedAt: Date

    public init(
        id: String,
        name: String,
        version: String,
        author: String? = nil,
        description: String,
        runtime: String,
        source: String,
        status: String,
        isEnabled: Bool,
        integrityHash: String? = nil,
        tools: [ToolInfo],
        permissionOverrides: [String: String] = [:],
        discoveredAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.author = author
        self.description = description
        self.runtime = runtime
        self.source = source
        self.status = status
        self.isEnabled = isEnabled
        self.integrityHash = integrityHash
        self.toolsCount = tools.count
        self.tools = tools
        self.permissionOverrides = permissionOverrides
        self.discoveredAt = discoveredAt
        self.updatedAt = updatedAt
    }
}

/// Response for `GET /plugins`.
public struct PluginsResponse: Content, Equatable {
    public let plugins: [PluginSummary]
    public let count: Int
    public let enabledCount: Int
    public let discoveredPendingCount: Int
    public let tamperedCount: Int

    public init(plugins: [PluginSummary]) {
        self.plugins = plugins
        self.count = plugins.count
        self.enabledCount = plugins.filter(\.isEnabled).count
        self.discoveredPendingCount = plugins.filter { $0.status == "discovered" }.count
        self.tamperedCount = plugins.filter { $0.status == "tampered" }.count
    }
}

/// Request to modify a plugin's state or override a tool's permission level.
public struct UpdatePluginStateRequest: Content, Equatable {
    /// Action: `"enable"`, `"disable"`, `"override_permission"`, or `"clear_override"`.
    public let action: String
    /// Target tool name for permission override.
    public let toolName: String?
    /// Overridden permission level (`"readOnly"`, `"requiresApproval"`).
    public let permissionLevel: String?

    public init(action: String, toolName: String? = nil, permissionLevel: String? = nil) {
        self.action = action
        self.toolName = toolName
        self.permissionLevel = permissionLevel
    }
}

/// One item in the community marketplace index.
public struct MarketplacePluginItem: Content, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let version: String
    public let author: String
    public let description: String
    public let downloadURL: String
    public let tags: [String]
    public let runtime: String
    public let declaredTools: [String]
    public let isInstalled: Bool

    public init(
        id: String,
        name: String,
        version: String,
        author: String,
        description: String,
        downloadURL: String,
        tags: [String] = [],
        runtime: String = "python",
        declaredTools: [String] = [],
        isInstalled: Bool = false
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.author = author
        self.description = description
        self.downloadURL = downloadURL
        self.tags = tags
        self.runtime = runtime
        self.declaredTools = declaredTools
        self.isInstalled = isInstalled
    }
}

/// Response for `GET /marketplace/plugins`.
public struct MarketplaceResponse: Content, Equatable {
    public let items: [MarketplacePluginItem]
    public let count: Int

    public init(items: [MarketplacePluginItem]) {
        self.items = items
        self.count = items.count
    }
}

/// Request to install a rune from the marketplace.
public struct InstallMarketplacePluginRequest: Content, Equatable {
    public let id: String
    public let downloadURL: String?

    public init(id: String, downloadURL: String? = nil) {
        self.id = id
        self.downloadURL = downloadURL
    }
}

/// Tool invocation request for `POST /tools/call`.
public struct ToolCallRequest: Content, Equatable {
    /// Name of the tool to run.
    public let toolName: String
    /// Raw JSON arguments. Defaults to `"{}"` when omitted.
    public var argumentsJSON: String?
    /// Correlation identifier. A new UUID string is used when omitted.
    public var callID: String?

    /// Creates a tool call request.
    public init(toolName: String, argumentsJSON: String? = nil, callID: String? = nil) {
        self.toolName = toolName
        self.argumentsJSON = argumentsJSON
        self.callID = callID
    }

    /// Arguments document, defaulting blanks to `"{}"`.
    /// - Returns: Raw JSON arguments.
    public var resolvedArgumentsJSON: String {
        DTODefaults.argumentsJSON(argumentsJSON)
    }

    /// Correlation identifier, generating one when omitted or blank.
    /// - Returns: Call identifier.
    public var resolvedCallID: String {
        DTODefaults.callID(callID)
    }
}

/// Tool enable/disable request for `POST /tools/:name/state`.
public struct UpdateToolStateRequest: Content, Equatable {
    /// Whether the named tool should be enabled on the live bus.
    public let enabled: Bool

    /// Creates a tool state request.
    /// - Parameter enabled: Desired enabled flag.
    public init(enabled: Bool) {
        self.enabled = enabled
    }
}

/// Memory search response for `GET /memory/search`.
public struct MemorySearchResponse: Content, Equatable {
    /// Query that was run.
    public let query: String
    /// Number of hits in `memories`.
    public let count: Int
    /// Hits, best first.
    public let memories: [MemoryResult]

    /// Creates a memory search response.
    public init(query: String, memories: [MemoryResult]) {
        self.query = query
        self.memories = memories
        self.count = memories.count
    }
}

/// Long-lived memory snapshot for `GET /memory/facts`.
public struct FactsResponse: Content, Equatable {
    /// Long-lived profile facts.
    public let facts: [UserFact]
    /// Key/value preferences.
    public let preferences: [Preference]
    /// Stored semantic fact count.
    public let semanticCount: Int
    /// Stored episode count.
    public let episodeCount: Int

    /// Creates a facts response.
    public init(facts: [UserFact], preferences: [Preference], semanticCount: Int, episodeCount: Int) {
        self.facts = facts
        self.preferences = preferences
        self.semanticCount = semanticCount
        self.episodeCount = episodeCount
    }
}

/// Fact write request for `POST /memory/facts`.
public struct StoreFactRequest: Content, Equatable {
    /// Fact text to store.
    public let content: String
    /// Origin label. Defaults to `"api"` when omitted.
    public var source: String?

    /// Creates a store-fact request.
    public init(content: String, source: String? = nil) {
        self.content = content
        self.source = source
    }

    /// Origin label, defaulting blanks to `"api"`.
    /// - Returns: Trimmed source, or `"api"` when blank.
    public var resolvedSource: String {
        DTODefaults.source(source)
    }
}

/// Pending approvals response for `GET /approvals`.
public struct ApprovalsResponse: Content, Equatable {
    /// Pending requests.
    public let approvals: [PermissionRequest]
    /// Number of requests in `approvals`.
    public let count: Int

    /// Creates an approvals response.
    /// - Parameter approvals: Pending requests.
    public init(approvals: [PermissionRequest]) {
        self.approvals = approvals
        self.count = approvals.count
    }
}

/// Approval decision request for `POST /approvals/:id/decide`.
public struct ApprovalDecisionRequest: Content, Equatable {
    /// Whether the tool call may run.
    public let approved: Bool
    /// Graduated-trust tier recorded on approval. Defaults to `thisTime`.
    public var duration: TrustDuration?

    /// Creates a decision request.
    public init(approved: Bool, duration: TrustDuration? = nil) {
        self.approved = approved
        self.duration = duration
    }

    /// Trust tier, defaulting to `thisTime` (one-shot).
    /// - Returns: Resolved duration.
    public var resolvedDuration: TrustDuration {
        DTODefaults.duration(duration)
    }
}

/// Approval decision response for `POST /approvals/:id/decide`.
public struct ApprovalDecisionResponse: Content, Equatable {
    /// Request identifier that was resolved.
    public let id: UUID
    /// Whether the call may run.
    public let approved: Bool
    /// Trust tier recorded on approval.
    public let duration: TrustDuration

    /// Creates a decision response.
    public init(id: UUID, approved: Bool, duration: TrustDuration) {
        self.id = id
        self.approved = approved
        self.duration = duration
    }
}

/// Scheduler job list response for `GET /scheduler/jobs`.
public struct SchedulerJobsResponse: Content, Equatable {
    /// Jobs, oldest first.
    public let jobs: [SchedulerJob]
    /// Number of jobs in `jobs`.
    public let count: Int

    /// Creates a jobs response.
    /// - Parameter jobs: Stored jobs.
    public init(jobs: [SchedulerJob]) {
        self.jobs = jobs
        self.count = jobs.count
    }
}

/// Run log list response for `GET /runs`.
public struct RunLogsResponse: Content, Equatable {
    /// Entries, newest first.
    public let runs: [RunLogEntry]
    /// Number of entries in `runs`.
    public let count: Int

    /// Creates a run logs response.
    /// - Parameter runs: Stored entries.
    public init(runs: [RunLogEntry]) {
        self.runs = runs
        self.count = runs.count
    }
}

/// Search engine health response for `GET /search/health`.
/// Encodes both `baseURL` (canonical) and `url` plus `status` so dashboard
/// clients reading either contract keep the custom port instead of falling
/// back to the default.
public struct SearchHealthResponse: Content, Equatable {
    /// Whether the SearXNG base URL answered with 2xx/3xx.
    public let reachable: Bool
    /// Configured SearXNG base URL that was probed.
    public let baseURL: String
    /// Container name backing the lifecycle, when managed.
    public let containerName: String
    /// Alias of `baseURL` for dashboard clients expecting `url`.
    public let url: String
    /// Collapsed status (`"running"` when reachable, else `"stopped"`).
    public let status: String

    /// Creates a health response.
    public init(reachable: Bool, baseURL: String, containerName: String, url: String? = nil, status: String? = nil) {
        self.reachable = reachable
        self.baseURL = baseURL
        self.containerName = containerName
        self.url = url ?? baseURL
        self.status = status ?? (reachable ? "running" : "stopped")
    }

    private enum CodingKeys: String, CodingKey {
        case reachable
        case baseURL
        case containerName
        case url
        case status
    }

    /// Decodes tolerantly across `baseURL`/`url` shapes.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reachable = try container.decode(Bool.self, forKey: .reachable)
        let base = try container.decodeIfPresent(String.self, forKey: .baseURL)
        let alias = try container.decodeIfPresent(String.self, forKey: .url)
        let resolved = base ?? alias ?? ""
        baseURL = resolved
        url = alias ?? resolved
        containerName = try container.decodeIfPresent(String.self, forKey: .containerName) ?? ""
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? (reachable ? "running" : "stopped")
    }

    /// Encodes both `baseURL` and `url` plus `status` for dual-contract reads.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(reachable, forKey: .reachable)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(url, forKey: .url)
        try container.encode(containerName, forKey: .containerName)
        try container.encode(status, forKey: .status)
    }
}

/// Search engine ensure response for `POST /search/ensure`.
/// Carries the last cascade failure detail in `message` when unreachable, so
/// the dashboard can render why the heal stopped instead of flipping silently.
public struct SearchEnsureResponse: Content, Equatable {
    /// Whether the engine answers after the ensure attempt.
    public let reachable: Bool
    /// Configured SearXNG base URL that was ensured.
    public let baseURL: String
    /// Whether a start was attempted during this call.
    public let started: Bool
    /// Alias of `baseURL` for dashboard clients expecting `url`.
    public let url: String
    /// Collapsed status (`"running"` when reachable, else `"stopped"`).
    public let status: String
    /// Last cascade failure detail (stage, exit, capped tail, timeout) when unreachable.
    public let message: String?

    /// Creates an ensure response.
    public init(reachable: Bool, baseURL: String, started: Bool, url: String? = nil, status: String? = nil, message: String? = nil) {
        self.reachable = reachable
        self.baseURL = baseURL
        self.started = started
        self.url = url ?? baseURL
        self.status = status ?? (reachable ? "running" : "stopped")
        let trimmed = (message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.message = trimmed.isEmpty ? nil : trimmed
    }

    private enum CodingKeys: String, CodingKey {
        case reachable
        case baseURL
        case started
        case url
        case status
        case message
    }

    /// Decodes tolerantly across `baseURL`/`url` shapes plus optional message.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reachable = try container.decode(Bool.self, forKey: .reachable)
        let base = try container.decodeIfPresent(String.self, forKey: .baseURL)
        let alias = try container.decodeIfPresent(String.self, forKey: .url)
        let resolved = base ?? alias ?? ""
        baseURL = resolved
        url = alias ?? resolved
        started = try container.decodeIfPresent(Bool.self, forKey: .started) ?? false
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? (reachable ? "running" : "stopped")
        let rawMessage = try container.decodeIfPresent(String.self, forKey: .message)
        let trimmed = (rawMessage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        message = trimmed.isEmpty ? nil : trimmed
    }

    /// Encodes both `baseURL` and `url` plus `status` for dual-contract reads.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(reachable, forKey: .reachable)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(url, forKey: .url)
        try container.encode(started, forKey: .started)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(message, forKey: .message)
    }
}

/// Search engine stop response for `POST /search/stop`.
/// Carries a failure detail in `message` when the engine still answers after
/// the stop, so the dashboard can render why the halt did not take instead of
/// falling back to a generic notice.
public struct SearchStopResponse: Content, Equatable {
    /// Whether the container is stopped (honest re-probe: false when the engine still answers).
    public let stopped: Bool
    /// Container name that was stopped.
    public let containerName: String
    /// Whether the engine answers after the stop (honest re-probe; true when the stop failed or the engine still answers).
    public let reachable: Bool
    /// Configured SearXNG base URL for dashboard fallback display.
    public let baseURL: String
    /// Alias of `baseURL` for dashboard clients expecting `url`.
    public let url: String
    /// Collapsed status (honest re-probe: `"running"` when still reachable, else `"stopped"`).
    public let status: String
    /// Failure detail when the engine still answers after the stop.
    public let message: String?

    /// Creates a stop response.
    public init(stopped: Bool, containerName: String, reachable: Bool = false, baseURL: String = "", url: String? = nil, status: String? = nil, message: String? = nil) {
        self.stopped = stopped
        self.containerName = containerName
        self.reachable = reachable
        self.baseURL = baseURL
        self.url = url ?? baseURL
        self.status = status ?? (reachable ? "running" : "stopped")
        let trimmed = (message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.message = trimmed.isEmpty ? nil : trimmed
    }

    private enum CodingKeys: String, CodingKey {
        case stopped
        case containerName
        case reachable
        case baseURL
        case url
        case status
        case message
    }

    /// Decodes tolerantly so dashboard `SearchHealthResponse` shapes still parse.
    /// An absent `stopped` derives from the honest `reachable` probe instead
    /// of optimistically assuming stopped on shape drift.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reachable = try container.decodeIfPresent(Bool.self, forKey: .reachable) ?? false
        stopped = try container.decodeIfPresent(Bool.self, forKey: .stopped) ?? !reachable
        containerName = try container.decodeIfPresent(String.self, forKey: .containerName) ?? ""
        let base = try container.decodeIfPresent(String.self, forKey: .baseURL)
        let alias = try container.decodeIfPresent(String.self, forKey: .url)
        let resolved = base ?? alias ?? ""
        baseURL = resolved
        url = alias ?? resolved
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? (reachable ? "running" : "stopped")
        let rawMessage = try container.decodeIfPresent(String.self, forKey: .message)
        let trimmed = (rawMessage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        message = trimmed.isEmpty ? nil : trimmed
    }

    /// Encodes the full shape so health-style readers keep working.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stopped, forKey: .stopped)
        try container.encode(containerName, forKey: .containerName)
        try container.encode(reachable, forKey: .reachable)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(url, forKey: .url)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(message, forKey: .message)
    }
}

/// WebSocket wire shapes, single-sourced from `RuneWeaverCore`.
public typealias WSChatMessage = RuneWeaverCore.WSChatMessage
/// Approval decision frame, single-sourced from core.
public typealias WSDecisionMessage = RuneWeaverCore.WSDecisionMessage
/// Streamed chat delta, single-sourced from core.
public typealias WSStreamDelta = RuneWeaverCore.WSStreamDelta
/// Terminal chat frame, single-sourced from core.
public typealias WSStreamDone = RuneWeaverCore.WSStreamDone
/// Live approval prompt, single-sourced from core.
public typealias WSApprovalPrompt = RuneWeaverCore.WSApprovalPrompt
/// Error frame, single-sourced from core.
public typealias WSErrorFrame = RuneWeaverCore.WSErrorFrame
/// Tool start frame, single-sourced from core.
public typealias WSToolStartFrame = RuneWeaverCore.WSToolStartFrame
/// Tool end frame, single-sourced from core.
public typealias WSToolEndFrame = RuneWeaverCore.WSToolEndFrame
/// Cancel message, single-sourced from core.
public typealias WSCancelMessage = RuneWeaverCore.WSCancelMessage
/// Cancelled confirmation frame, single-sourced from core.
public typealias WSCancelledFrame = RuneWeaverCore.WSCancelledFrame

/// Classifies one inbound WebSocket text frame.
public enum WSInboundKind: Sendable, Equatable {
    /// A chat message with user text.
    case chat(WSChatMessage)
    /// An approval decision for a pending request.
    case decision(WSDecisionMessage)
    /// A request to cancel the active turn.
    case cancel(WSCancelMessage)
    /// A frame that is neither chat, decision, nor cancel.
    case unknown
}

private struct WSCancelFramePeek: Codable, Sendable {
    let type: String?
    let sessionID: UUID?
    let text: String?
    let id: UUID?
}

public extension WSInboundKind {
    /// Classifies raw socket text into a chat, decision, cancel, or unknown kind.
    /// - Parameter text: Raw socket text frame.
    /// - Returns: The inbound kind, or `unknown` when no shape decodes.
    static func classify(_ text: String) -> WSInboundKind {
        guard let data = text.data(using: .utf8) else { return .unknown }
        let peek = try? JSONDecoder().decode(WSCancelFramePeek.self, from: data)
        let hasText = !(peek?.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        if let chat = try? JSONDecoder().decode(WSChatMessage.self, from: data),
           !chat.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return .chat(chat)
        }
        if peek?.type == "cancel", !hasText {
            return .cancel(WSCancelMessage(sessionID: peek?.sessionID))
        }
        if hasText, peek?.type == "cancel" {
            return .unknown
        }
        if let decision = try? JSONDecoder().decode(WSDecisionMessage.self, from: data) {
            return .decision(decision)
        }
        if peek?.type == "cancel" {
            return .cancel(WSCancelMessage(sessionID: peek?.sessionID))
        }
        return .unknown
    }
}

/// Splits final assistant text into streamed delta chunks.
public enum WSStreaming {
    /// Default characters per delta frame.
    public static let defaultChunkSize = 200

    /// Splits text into non-empty delta chunks.
    public static func deltas(for text: String, chunkSize: Int = defaultChunkSize) -> [String] {
        guard !text.isEmpty else { return [] }
        guard chunkSize > 0 else { return [text] }
        var chunks: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: chunkSize, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(String(text[start ..< end]))
            start = end
        }
        return chunks
    }
}

// MARK: - Sessions DTOs & Conformance

extension SessionSummary: Content {}
extension ConversationSession: Content {}
extension Message: Content {}

/// Session list response for `GET /sessions`.
public struct SessionsResponse: Content, Equatable {
    public let sessions: [SessionSummary]
    public let count: Int

    public init(sessions: [SessionSummary]) {
        self.sessions = sessions
        self.count = sessions.count
    }
}

/// Request payload to update session title for `PATCH /sessions/:id`.
public struct UpdateSessionRequest: Content, Equatable {
    /// Maximum accepted title length, mirroring
    /// `ConversationManager/maxTitleLength` so the API rejects huge titles
    /// with `413` before they reach the sessions table.
    public static var maxTitleLength: Int {
        ConversationManager.maxTitleLength
    }

    public let title: String

    public init(title: String) {
        self.title = title
    }
}

/// Structured tool actions of one assistant message for
/// `GET /sessions/:id/tool-actions`.
public struct SessionMessageToolActions: Content, Equatable {
    /// Parent assistant message identifier.
    public let messageID: UUID
    /// Tool calls derived from that message, in stored order.
    public let actions: [ToolAction]

    /// Creates a per-message actions row.
    public init(messageID: UUID, actions: [ToolAction]) {
        self.messageID = messageID
        self.actions = actions
    }
}

/// Structured tool-action history for `GET /sessions/:id/tool-actions`.
public struct SessionToolActionsResponse: Content, Equatable {
    /// Owning session identifier.
    public let sessionID: UUID
    /// Per-message actions, oldest message first.
    public let actions: [SessionMessageToolActions]
    /// Number of tool actions across all messages.
    public let count: Int

    /// Creates a tool-actions response.
    public init(sessionID: UUID, actions: [SessionMessageToolActions]) {
        self.sessionID = sessionID
        self.actions = actions
        self.count = actions.reduce(0) { $0 + $1.actions.count }
    }
}

/// Request payload to cancel an in-flight chat turn via `POST /chat/cancel`.
public struct CancelChatRequest: Content, Equatable {
    public let sessionID: UUID

    public init(sessionID: UUID) {
        self.sessionID = sessionID
    }
}

/// Response payload from `POST /chat/cancel`.
public struct CancelChatResponse: Content, Equatable {
    public let sessionID: UUID
    public let cancelled: Bool

    public init(sessionID: UUID, cancelled: Bool) {
        self.sessionID = sessionID
        self.cancelled = cancelled
    }
}

/// Settings snapshot for `GET /settings` and `PUT /settings`.
/// Carries both `browser*` (canonical `[browser]` keys) and `search*`
/// dashboard aliases with identical values so either contract reads without
/// falling back to defaults.
public struct SettingsResponse: Content, Equatable {
    public let engineName: String
    public let logLevel: String
    public let defaultProvider: String
    public let fallbackProvider: String?
    public let providers: [String: ProviderConfig]
    public let memoryVectorDBPath: String
    public let memoryEpisodesDBPath: String
    public let memoryEmbeddingModel: String
    public let memoryEmbeddingBackend: String
    public let voiceSTTProvider: String
    public let voiceWhisperModel: String
    public let voiceTTSProvider: String
    public let sandboxContainerBaseImage: String
    public let sandboxArchiveSessionTTLMinutes: Int
    public let sandboxMaxConcurrentMachines: Int
    public let filesDenyPatterns: [String]
    public let filesAllowRoots: [String]
    public let filesRequireApprovalOnDeny: Bool
    public let browserSearxngURL: String
    public let browserSearchTimeoutSeconds: Int
    public let browserMaxResults: Int
    public let searchSearxngURL: String
    public let searchTimeoutSeconds: Int
    public let searchMaxResults: Int
    public let emailAccounts: [EmailAccount]
    public let pluginsDir: String
    public let pluginsMarketplaceIndexURL: String
    public let pluginsAutoRescan: Bool
    public let configPath: String

    public init(config: RuneWeaverConfig, configPath: String) {
        self.engineName = config.engine.name
        self.logLevel = config.engine.logLevel
        self.defaultProvider = config.llm.defaultProvider
        self.fallbackProvider = config.llm.fallbackProvider
        self.providers = config.llm.providers
        self.memoryVectorDBPath = config.memory.vectorDBPath
        self.memoryEpisodesDBPath = config.memory.episodesDBPath
        self.memoryEmbeddingModel = config.memory.embeddingModel
        self.memoryEmbeddingBackend = config.memory.embeddingBackend
        self.voiceSTTProvider = config.voice.sttProvider
        self.voiceWhisperModel = config.voice.whisperModel
        self.voiceTTSProvider = config.voice.ttsProvider
        self.sandboxContainerBaseImage = config.sandbox.containerBaseImage
        self.sandboxArchiveSessionTTLMinutes = config.sandbox.archiveSessionTTLMinutes
        self.sandboxMaxConcurrentMachines = config.sandbox.maxConcurrentMachines
        self.filesDenyPatterns = config.files.denyPatterns
        self.filesAllowRoots = config.files.allowRoots
        self.filesRequireApprovalOnDeny = config.files.requireApprovalOnDeny
        self.browserSearxngURL = config.browser.searxngURL
        self.browserSearchTimeoutSeconds = config.browser.searchTimeoutSeconds
        self.browserMaxResults = config.browser.maxResults
        self.searchSearxngURL = config.browser.searxngURL
        self.searchTimeoutSeconds = config.browser.searchTimeoutSeconds
        self.searchMaxResults = config.browser.maxResults
        self.emailAccounts = config.email.accounts
        self.pluginsDir = config.plugins.pluginsDir
        self.pluginsMarketplaceIndexURL = config.plugins.marketplaceIndexURL
        self.pluginsAutoRescan = config.plugins.autoRescan
        self.configPath = configPath
    }
}

/// Request payload to update settings via `PUT /settings`.
/// Accepts both `browser*` (canonical) and `search*` (dashboard alias) keys;
/// the canonical key wins when both are present so either contract writes.
public struct UpdateSettingsRequest: Content, Equatable {
    public let engineName: String?
    public let logLevel: String?
    public let defaultProvider: String?
    public let fallbackProvider: String?
    public let providers: [String: ProviderConfig]?
    public let memoryVectorDBPath: String?
    public let memoryEpisodesDBPath: String?
    public let memoryEmbeddingModel: String?
    public let memoryEmbeddingBackend: String?
    public let voiceSTTProvider: String?
    public let voiceWhisperModel: String?
    public let voiceTTSProvider: String?
    public let sandboxContainerBaseImage: String?
    public let sandboxArchiveSessionTTLMinutes: Int?
    public let sandboxMaxConcurrentMachines: Int?
    public let filesDenyPatterns: [String]?
    public let filesAllowRoots: [String]?
    public let filesRequireApprovalOnDeny: Bool?
    public let browserSearxngURL: String?
    public let browserSearchTimeoutSeconds: Int?
    public let browserMaxResults: Int?
    public let searchSearxngURL: String?
    public let searchTimeoutSeconds: Int?
    public let searchMaxResults: Int?
    public let emailAccounts: [EmailAccount]?
    public let pluginsDir: String?
    public let pluginsMarketplaceIndexURL: String?
    public let pluginsAutoRescan: Bool?

    public init(
        engineName: String? = nil,
        logLevel: String? = nil,
        defaultProvider: String? = nil,
        fallbackProvider: String? = nil,
        providers: [String: ProviderConfig]? = nil,
        memoryVectorDBPath: String? = nil,
        memoryEpisodesDBPath: String? = nil,
        memoryEmbeddingModel: String? = nil,
        memoryEmbeddingBackend: String? = nil,
        voiceSTTProvider: String? = nil,
        voiceWhisperModel: String? = nil,
        voiceTTSProvider: String? = nil,
        sandboxContainerBaseImage: String? = nil,
        sandboxArchiveSessionTTLMinutes: Int? = nil,
        sandboxMaxConcurrentMachines: Int? = nil,
        filesDenyPatterns: [String]? = nil,
        filesAllowRoots: [String]? = nil,
        filesRequireApprovalOnDeny: Bool? = nil,
        browserSearxngURL: String? = nil,
        browserSearchTimeoutSeconds: Int? = nil,
        browserMaxResults: Int? = nil,
        searchSearxngURL: String? = nil,
        searchTimeoutSeconds: Int? = nil,
        searchMaxResults: Int? = nil,
        emailAccounts: [EmailAccount]? = nil,
        pluginsDir: String? = nil,
        pluginsMarketplaceIndexURL: String? = nil,
        pluginsAutoRescan: Bool? = nil
    ) {
        self.engineName = engineName
        self.logLevel = logLevel
        self.defaultProvider = defaultProvider
        self.fallbackProvider = fallbackProvider
        self.providers = providers
        self.memoryVectorDBPath = memoryVectorDBPath
        self.memoryEpisodesDBPath = memoryEpisodesDBPath
        self.memoryEmbeddingModel = memoryEmbeddingModel
        self.memoryEmbeddingBackend = memoryEmbeddingBackend
        self.voiceSTTProvider = voiceSTTProvider
        self.voiceWhisperModel = voiceWhisperModel
        self.voiceTTSProvider = voiceTTSProvider
        self.sandboxContainerBaseImage = sandboxContainerBaseImage
        self.sandboxArchiveSessionTTLMinutes = sandboxArchiveSessionTTLMinutes
        self.sandboxMaxConcurrentMachines = sandboxMaxConcurrentMachines
        self.filesDenyPatterns = filesDenyPatterns
        self.filesAllowRoots = filesAllowRoots
        self.filesRequireApprovalOnDeny = filesRequireApprovalOnDeny
        self.browserSearxngURL = browserSearxngURL
        self.browserSearchTimeoutSeconds = browserSearchTimeoutSeconds
        self.browserMaxResults = browserMaxResults
        self.searchSearxngURL = searchSearxngURL
        self.searchTimeoutSeconds = searchTimeoutSeconds
        self.searchMaxResults = searchMaxResults
        self.emailAccounts = emailAccounts
        self.pluginsDir = pluginsDir
        self.pluginsMarketplaceIndexURL = pluginsMarketplaceIndexURL
        self.pluginsAutoRescan = pluginsAutoRescan
    }

    /// Applies this update onto a loaded config, preserving every field
    /// the request omits.
    public func apply(to config: inout RuneWeaverConfig) throws {
        applyEngine(to: &config.engine)
        applyLLM(to: &config.llm)
        applyMemory(to: &config.memory)
        try applyMemoryEmbeddingBackend(to: &config.memory)
        applyVoice(to: &config.voice)
        applySandbox(to: &config.sandbox)
        try applyFiles(to: &config.files)
        applyBrowser(to: &config.browser)
        applyEmail(to: &config.email)
        applyPlugins(to: &config.plugins)
    }

    private func applyEngine(to engine: inout EngineConfig) {
        if let engineName {
            engine.name = engineName
        }
        if let logLevel {
            engine.logLevel = logLevel
        }
    }

    private func applyLLM(to llm: inout LLMConfig) {
        if let defaultProvider {
            llm.defaultProvider = defaultProvider
        }
        if let fallbackProvider {
            llm.fallbackProvider = fallbackProvider.isEmpty ? nil : fallbackProvider
        }
        if let providers {
            llm.providers = providers
        }
    }

    private func applyMemory(to memory: inout MemoryConfig) {
        if let memoryVectorDBPath {
            memory.vectorDBPath = memoryVectorDBPath
        }
        if let memoryEpisodesDBPath {
            memory.episodesDBPath = memoryEpisodesDBPath
        }
        if let memoryEmbeddingModel {
            memory.embeddingModel = memoryEmbeddingModel
        }
    }

    private func applyMemoryEmbeddingBackend(to memory: inout MemoryConfig) throws {
        guard let memoryEmbeddingBackend else { return }
        let allowedBackends = MemoryConfig.allowedEmbeddingBackends
        guard allowedBackends.contains(memoryEmbeddingBackend) else {
            throw ConfigError.validationError(
                field: "memory.embedding_backend",
                message: "must be one of \(allowedBackends.joined(separator: ", ")) (got '\(memoryEmbeddingBackend)')"
            )
        }
        memory.embeddingBackend = memoryEmbeddingBackend
    }

    private func applyVoice(to voice: inout VoiceConfig) {
        if let voiceSTTProvider {
            voice.sttProvider = voiceSTTProvider
        }
        if let voiceWhisperModel {
            voice.whisperModel = voiceWhisperModel
        }
        if let voiceTTSProvider {
            voice.ttsProvider = voiceTTSProvider
        }
    }

    private func applySandbox(to sandbox: inout SandboxConfig) {
        if let sandboxContainerBaseImage {
            sandbox.containerBaseImage = sandboxContainerBaseImage
        }
        if let sandboxArchiveSessionTTLMinutes {
            sandbox.archiveSessionTTLMinutes = sandboxArchiveSessionTTLMinutes
        }
        if let sandboxMaxConcurrentMachines {
            sandbox.maxConcurrentMachines = sandboxMaxConcurrentMachines
        }
    }

    private func applyFiles(to files: inout FilesConfig) throws {
        if let filesDenyPatterns {
            try RuneWeaverConfig.validateFilesPatterns(filesDenyPatterns, field: "files.deny_patterns")
            files.denyPatterns = filesDenyPatterns
        }
        if let filesAllowRoots {
            try RuneWeaverConfig.validateFilesPatterns(filesAllowRoots, field: "files.allow_roots")
            files.allowRoots = filesAllowRoots
        }
        if let filesRequireApprovalOnDeny {
            files.requireApprovalOnDeny = filesRequireApprovalOnDeny
        }
    }

    private func applyBrowser(to browser: inout BrowserConfig) {
        if let browserSearxngURL = browserSearxngURL ?? searchSearxngURL {
            browser.searxngURL = browserSearxngURL
        }
        if let browserSearchTimeoutSeconds = browserSearchTimeoutSeconds ?? searchTimeoutSeconds {
            browser.searchTimeoutSeconds = browserSearchTimeoutSeconds
        }
        if let browserMaxResults = browserMaxResults ?? searchMaxResults {
            browser.maxResults = browserMaxResults
        }
    }

    private func applyEmail(to email: inout EmailConfig) {
        if let emailAccounts {
            email.accounts = emailAccounts
        }
    }

    private func applyPlugins(to plugins: inout PluginConfig) {
        if let pluginsDir {
            plugins.pluginsDir = pluginsDir
        }
        if let pluginsMarketplaceIndexURL {
            plugins.marketplaceIndexURL = pluginsMarketplaceIndexURL
        }
        if let pluginsAutoRescan {
            plugins.autoRescan = pluginsAutoRescan
        }
    }
}

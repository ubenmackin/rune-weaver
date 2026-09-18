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
    /// Widen grant subpath under `/approvals/grants/:id`.
    public static let widen = "widen"
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
    /// Search remove subpath under `/search`.
    /// Deletes the managed container entry while leaving the image cache so the
    /// next Start recreates it; a running entry stops first rather than half-deleting.
    public static let searchRemove = "remove"
    /// Browser group serving the managed Playwright Python venv lifecycle.
    public static let browser = "browser"
    /// Browser health subpath under `/browser`.
    public static let browserHealth = "health"
    /// Browser ensure subpath under `/browser`.
    public static let browserEnsure = "ensure"
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
/// Carries the live Start stage when a SearXNG ensure flight is running so the
/// dashboard profile menu can poll one endpoint for both the dot and the
/// Starting line. Older engines omit the stage keys, which decode to nil.
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
    /// In-flight Start stage (`resolving`, `daemon`, `pulling`, `starting`,
    /// `waiting`), nil when no Start is running.
    public let searchStage: String?
    /// Unix seconds when the in-flight Start began, nil when idle.
    /// A number (not a Date) so every dashboard decodes it without sharing a
    /// date strategy with the engine.
    public let searchStartedAt: Double?

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
        searchStatus: String? = nil,
        searchStage: String? = nil,
        searchStartedAt: Double? = nil
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
        let trimmedStage = (searchStage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.searchStage = trimmedStage.isEmpty ? nil : trimmedStage
        if let searchStartedAt, searchStartedAt.isFinite, searchStartedAt > 0 {
            self.searchStartedAt = searchStartedAt
        } else {
            self.searchStartedAt = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case engine
        case version
        case model
        case provider
        case contextLength
        case searchReachable
        case searchURL
        case searchStatus
        case searchStage
        case searchStartedAt
    }

    /// Decodes tolerantly so payloads from engines that predate staged Start
    /// progress still parse with a nil stage instead of failing the probe.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "ok"
        engine = try container.decodeIfPresent(String.self, forKey: .engine) ?? "Rune Weaver"
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? ServerPaths.apiVersion
        model = try container.decodeIfPresent(String.self, forKey: .model)
        provider = try container.decodeIfPresent(String.self, forKey: .provider)
        contextLength = try container.decodeIfPresent(Int.self, forKey: .contextLength)
        searchReachable = try container.decodeIfPresent(Bool.self, forKey: .searchReachable)
        searchURL = try container.decodeIfPresent(String.self, forKey: .searchURL)
        searchStatus = try container.decodeIfPresent(String.self, forKey: .searchStatus)
        let rawStage = try container.decodeIfPresent(String.self, forKey: .searchStage)
        let trimmedStage = (rawStage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        searchStage = trimmedStage.isEmpty ? nil : trimmedStage
        let rawStartedAt = try container.decodeIfPresent(Double.self, forKey: .searchStartedAt)
        if let rawStartedAt, rawStartedAt.isFinite, rawStartedAt > 0 {
            searchStartedAt = rawStartedAt
        } else {
            searchStartedAt = nil
        }
    }

    /// Encodes the stage keys only when a Start is in flight.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        try container.encode(engine, forKey: .engine)
        try container.encode(version, forKey: .version)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(provider, forKey: .provider)
        try container.encodeIfPresent(contextLength, forKey: .contextLength)
        try container.encodeIfPresent(searchReachable, forKey: .searchReachable)
        try container.encodeIfPresent(searchURL, forKey: .searchURL)
        try container.encodeIfPresent(searchStatus, forKey: .searchStatus)
        try container.encodeIfPresent(searchStage, forKey: .searchStage)
        try container.encodeIfPresent(searchStartedAt, forKey: .searchStartedAt)
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
    /// Whether to grant tool-wide trust matching any target.
    public var widen: Bool?

    /// Creates a decision request.
    public init(approved: Bool, duration: TrustDuration? = nil, widen: Bool? = nil) {
        self.approved = approved
        self.duration = duration
        self.widen = widen
    }

    /// Trust tier, defaulting to `thisTime` (one-shot).
    /// - Returns: Resolved duration.
    public var resolvedDuration: TrustDuration {
        DTODefaults.duration(duration)
    }

    /// Whether to grant tool-wide trust matching any target, defaulting to
    /// `false` so an omitted flag never silently widens a grant. Kept beside
    /// `resolvedDuration` so the decision defaults stay single-sourced across
    /// the REST and WebSocket paths.
    /// - Returns: Resolved widen flag.
    public var resolvedWiden: Bool {
        widen ?? false
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
/// Mid-turn degraded-tool notice, single-sourced from core.
public typealias WSWarningFrame = RuneWeaverCore.WSWarningFrame

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
        // A decision is identified by its required `id` plus `approved` pair and
        // is classified before chat content sniffing: a payload can carry both
        // a stray text field and an approval decision, and preferring chat
        // would drop the decision so the request stays pending forever.
        if let decision = try? JSONDecoder().decode(WSDecisionMessage.self, from: data) {
            return .decision(decision)
        }
        if let chat = try? JSONDecoder().decode(WSChatMessage.self, from: data),
           !chat.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return .chat(chat)
        }
        // A cancel frame is only honored without text: chat sniffing already ran
        // above, so text surviving to here is either a stray field on a cancel
        // frame or a malformed body, and canceling the active turn on that
        // ambiguity would abort a turn the user never asked to stop.
        if peek?.type == "cancel" {
            return hasText ? .unknown : .cancel(WSCancelMessage(sessionID: peek?.sessionID))
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
    /// Parent message completion time as Unix seconds since 1970 (server clock).
    /// Optional so older engines that omit it still decode; clients fall back
    /// to the sibling chat history timestamp for the same message.
    public var completedAt: Double?

    /// Creates a per-message actions row.
    public init(messageID: UUID, actions: [ToolAction], completedAt: Double? = nil) {
        self.messageID = messageID
        self.actions = actions
        self.completedAt = completedAt
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
    public let compactionThresholdPercent: Int
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
        self.compactionThresholdPercent = config.engine.compactionThresholdPercent
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
    public let compactionThresholdPercent: Int?
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
        compactionThresholdPercent: Int? = nil,
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
        self.compactionThresholdPercent = compactionThresholdPercent
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
        if let compactionThresholdPercent {
            engine.compactionThresholdPercent = compactionThresholdPercent
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

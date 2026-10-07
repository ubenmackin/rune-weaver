// Rune Weaver Server — Shared REST and WebSocket contracts for the engine API.
//
// Purpose: carries the canonical route paths plus the shared REST and
// WebSocket request/response shapes so chat, tools, memory, approvals,
// scheduler, runs, and sessions encode identically on both ends of the wire.
// Scope: DTO bodies and wire classification only; route registration, auth
// gating, and persistence stay with the route and store layers.
// Architectural role: keeps the Vapor adapters decoupled from the engine core
// in version-tolerant Codable contracts, so a dashboard built against an
// older engine still decodes.

import Foundation
import RuneWeaverCore
import Vapor

/// Canonical route paths for the engine API.
public enum ServerPaths {
    /// Health probe.
    public static let health = "health"
    /// Chat turn.
    public static let chat = "chat"
    /// Per-tool cancellation subpath under `/chat`.
    /// Distinct from the turn-wide `/chat/cancel`: this aborts one running tool
    /// call and leaves its turn alive, so the model can reason about the result.
    public static let toolCancel = "tool_cancel"
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
    /// Episodic turns subpath under `/memory`.
    /// Clearing here drops only the episodic tables; semantic facts, profile,
    /// and session ledgers stay untouched by the engine owner.
    public static let memoryEpisodes = "episodes"
    /// Session literal under `/memory/episodes`.
    /// Registered before `/:id` so the literal wins over the parameter,
    /// mirroring the goals summary precedent.
    public static let memoryEpisodeSession = "session"
    /// Recent listing literal under `/memory/episodes`.
    /// Registered before `/:id` so the literal wins over the parameter,
    /// mirroring the goals summary precedent.
    public static let memoryEpisodesRecent = "recent"
    /// Pending approvals group.
    public static let approvals = "approvals"
    /// Approval decision subpath under `/approvals/:id`.
    public static let decide = "decide"
    /// Question response subpath under `/approvals/:id`.
    public static let respond = "respond"
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
    /// Fan-out cancellation subpath under `/runs/:id`.
    public static let runCancel = "cancel"
    /// Sessions group.
    public static let sessions = "sessions"
    /// Structured tool actions subpath under `/sessions/:id`.
    public static let toolActions = "tool-actions"
    /// Archive subpath under `/sessions/:id`.
    public static let archive = "archive"
    /// Unarchive subpath under `/sessions/:id`.
    public static let unarchive = "unarchive"
    /// WebSocket endpoint for streamed chat plus live approval prompts.
    public static let websocket = "ws"
    /// Settings group.
    public static let settings = "settings"
    /// Secrets subpath under `/settings`.
    public static let secrets = "secrets"
    /// Policy subpath under `/settings`.
    public static let policy = "policy"
    /// Verification subpath under `/settings/policy`.
    public static let verify = "verify"
    /// Local-access re-check preview subpath under `/settings/policy`.
    public static let recheckLocal = "recheck-local"
    /// Local-access re-check apply subpath under `/settings/policy`.
    public static let recheckLocalApply = "recheck-local/apply"
    /// Status subpath under `/settings/secrets`.
    public static let status = "status"
    /// Single-owner bearer auth group.
    public static let auth = "auth"
    /// Owner token rotation subpath under `/auth`.
    public static let rotate = "rotate"
    /// Owner browser session subpath under `/auth`.
    public static let session = "session"
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
    /// Staged files management group.
    public static let files = "files"
    /// Staged files subpath under `/files`.
    public static let filesStaged = "staged"
    /// File review status subpath under `/files`.
    public static let filesReviewStatus = "review-status"
    /// Accept staged file subpath under `/files`.
    public static let filesAccept = "accept"
    /// Discard staged file subpath under `/files`.
    public static let filesDiscard = "discard"
    /// Accept live write review subpath under `/files`.
    public static let filesLiveAccept = "live-accept"
    /// Decline live write review subpath under `/files`.
    public static let filesLiveDecline = "live-decline"
    /// Goals group backing steady pursuit tracking.
    public static let goals = "goals"
    /// Goals summary subpath under `/goals`.
    /// Registered before `/:id` so the literal wins over the parameter.
    public static let goalSummary = "summary"
    /// Goal manual-advance subpath under `/goals/:id`.
    public static let goalAdvance = "advance"
    /// Goal steps subpath under `/goals/:id`.
    public static let goalSteps = "steps"
    /// Ideas group backing proactive Wayfinder suggestions.
    public static let ideas = "ideas"
    /// Ideas summary subpath under `/ideas`.
    /// Registered before `/:id` so the literal wins over the parameter.
    public static let ideaSummary = "summary"
    /// Idea dismiss subpath under `/ideas/:id`.
    public static let ideaDismiss = "dismiss"
    /// Idea accept subpath under `/ideas/:id`.
    public static let ideaAccept = "accept"
    /// Agent scratch workspace group backing usage plus temp pruning.
    public static let workspace = "workspace"
    /// Workspace usage subpath under `/workspace`.
    public static let workspaceUsage = "usage"
    /// Workspace temp subpath under `/workspace`.
    public static let workspaceTmp = "tmp"
    /// Temp prune subpath under `/workspace/tmp`.
    public static let workspacePrune = "prune"
    /// Workspace machine subpath under `/workspace`.
    public static let workspaceMachine = "machine"
    /// Machine stop subpath under `/workspace/machine`.
    public static let workspaceMachineStop = "stop"
    /// Machine recycle subpath under `/workspace/machine`.
    public static let workspaceMachineRecycle = "recycle"
    /// Hash-pinned agent script registry group.
    /// Kebab spelling matches the multi-word route convention (`tool-actions`,
    /// `review-status`, `live-accept`) rather than the single `tool_cancel`
    /// snake outlier, so dashboards build the path with one rule.
    public static let agentTools = "agent-tools"
    /// Promotion subpath under `/agent-tools`.
    public static let agentToolsPromote = "promote"
    /// Verified run subpath under `/agent-tools/:id`.
    public static let agentToolsRun = "run"
    /// Engine API version served on `/health`.
    /// Single-sourced through `RuneWeaverVersion` so health, User-Agents,
    /// and providers cannot drift.
    public static var apiVersion: String {
        RuneWeaverVersion.current
    }
}

/// One staged file record returned by `GET /files/staged`.
public struct StagedFileEntry: Content, Sendable, Equatable {
    public let path: String
    public let stagingPath: String
    public let additions: Int
    public let deletions: Int
    public let diff: String
    public let updatedAt: String

    public init(
        path: String,
        stagingPath: String,
        additions: Int,
        deletions: Int,
        diff: String,
        updatedAt: String
    ) {
        self.path = path
        self.stagingPath = stagingPath
        self.additions = additions
        self.deletions = deletions
        self.diff = diff
        self.updatedAt = updatedAt
    }
}

/// Response payload for `GET /files/staged`.
public struct StagedFilesResponse: Content, Sendable, Equatable {
    public let files: [StagedFileEntry]

    public init(files: [StagedFileEntry]) {
        self.files = files
    }
}

/// Request payload for `POST /files/accept` and `POST /files/discard`.
public struct FileActionRequest: Content, Sendable {
    public let path: String?
    public let all: Bool?

    public init(path: String? = nil, all: Bool? = nil) {
        self.path = path
        self.all = all
    }
}

/// Response payload for file actions.
public struct FileActionResponse: Content, Sendable {
    public let status: String
    public let count: Int?

    public init(status: String, count: Int? = nil) {
        self.status = status
        self.count = count
    }
}

/// Batch review-status request for `POST /files/review-status`.
///
/// The caller names the live paths it is rendering so the response can carry
/// one answer per requested path even when a path has no ledger row at all.
public struct ReviewStatusRequest: Content, Sendable {
    /// Live file paths to look up; 1-200 non-empty entries.
    public let paths: [String]

    /// Creates a batch review-status request.
    public init(paths: [String]) {
        self.paths = paths
    }
}

/// Batch review-status response for `POST /files/review-status`.
///
/// Both maps key on the requested path strings exactly, so a client hydrates
/// every row from one round trip; a path absent from a ledger reads `"unknown"`
/// rather than being omitted, which keeps staged and live lookups symmetric.
public struct ReviewStatusResponse: Content, Sendable {
    /// Staged-ledger state per requested path, `"unknown"` when no row exists.
    public let stagedStates: [String: String]
    /// Live-write-ledger state per requested path, `"unknown"` when no row exists.
    public let liveStates: [String: String]

    /// Creates a batch review-status response.
    public init(stagedStates: [String: String], liveStates: [String: String]) {
        self.stagedStates = stagedStates
        self.liveStates = liveStates
    }
}

/// WebSocket broadcast payload for file actions.
///
/// Staged actions carry only type and path; a `live_resolved` frame also names
/// its terminal state so one event type covers acceptance, revert, and discard
/// without a second frame shape the dashboard would have to learn. A
/// `file_superseded` frame reuses the same shape with state `superseded` to
/// report a live write that resolved a pending staged row in-session — a
/// transition the write tool owns, so no resolution route broadcasts it.
public struct WSFileActionEvent: Content, Sendable {
    public let type: String
    public let path: String?
    public let state: String?

    public init(type: String, path: String? = nil, state: String? = nil) {
        self.type = type
        self.path = path
        self.state = state
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
/// The optional bind keys carry the live boot socket (not the file): the
/// dashboard compares the pending file from `GET /settings` against this boot
/// snapshot for its restart banner instead of comparing file against file.
/// The bind keys are owner-private: the route omits them unless the caller
/// cleared the owner gate (or no gate is installed on the loopback-no-auth
/// posture), so an unauthenticated probe never learns the boot bind. Absent
/// keys decode to nil and the dashboard keeps its file snapshot.
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
    /// Live boot bind hostname from the serving context. Nil on payloads from
    /// engines that predate the boot-bind advertisement; the dashboard falls
    /// back to its pre-save file snapshot in that case.
    public let serverHostname: String?
    /// Live boot bind port from the serving context. Nil when unknown.
    public let serverPort: Int?
    /// Live boot allowed-hosts from the serving context. Nil when unknown.
    public let serverAllowedHosts: [String]?

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
        searchStartedAt: Double? = nil,
        serverHostname: String? = nil,
        serverPort: Int? = nil,
        serverAllowedHosts: [String]? = nil
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
        let trimmedHostname = (serverHostname ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.serverHostname = trimmedHostname.isEmpty ? nil : trimmedHostname
        if let serverPort, (1 ... 65535).contains(serverPort) {
            self.serverPort = serverPort
        } else {
            self.serverPort = nil
        }
        // Normalize through the shared Host form plus dedupe so the dashboard
        // restart banner compares pending file and boot snapshot under identical
        // semantics instead of tripping on casing or `:port` spellings.
        self.serverAllowedHosts = Self.normalizedAllowedHosts(serverAllowedHosts)
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
        case serverHostname
        case serverPort
        case serverAllowedHosts
    }

    /// Decodes tolerantly so payloads from engines that predate staged Start
    /// progress still parse with a nil stage instead of failing the probe.
    /// The boot-bind keys are optional for the same reason: absent means the
    /// dashboard keeps its snapshot fallback instead of failing the probe.
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
        let rawHostname = try container.decodeIfPresent(String.self, forKey: .serverHostname)
        let trimmedHostname = (rawHostname ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        serverHostname = trimmedHostname.isEmpty ? nil : trimmedHostname
        let rawPort = try container.decodeIfPresent(Int.self, forKey: .serverPort)
        if let rawPort, (1 ... 65535).contains(rawPort) {
            serverPort = rawPort
        } else {
            serverPort = nil
        }
        let rawHosts = try container.decodeIfPresent([String].self, forKey: .serverAllowedHosts)
        serverAllowedHosts = Self.normalizedAllowedHosts(rawHosts)
    }

    /// Normalizes boot allowed-hosts through shared validation plus boot dedupe.
    ///
    /// Single-sourced through `RuneWeaverConfig.validateAllowedHosts` and
    /// `ServerEndpointConfig.dedupeNormalizedBootHosts` in Core so the health
    /// snapshot and the settings file compare under identical semantics;
    /// widening shapes drop nil matching the Host gate instead of allowlisting
    /// a carved fragment, and IPv6 counterparts ride along. The raw count
    /// bound was enforced at write time, so the boot entry point skips the
    /// raw-count prefix: the deduped form can legitimately exceed
    /// `maxAllowedHosts` because each IPv6 literal stores both its bracketed
    /// and bare spellings, so 11 IPv6 entries advertise as 22 matching the
    /// file, the PUT, and the gate instead of being cut back to 20.
    /// - Parameter hosts: Raw boot allowlist, or nil when unknown.
    /// - Returns: Normalized, deduped allowlist, or nil when unknown.
    private static func normalizedAllowedHosts(_ hosts: [String]?) -> [String]? {
        guard let hosts else { return nil }
        // Route through shared validation matching the Host gate so a widening
        // shape never widens the banner compare; invalid entries drop instead
        // of allowlisting a fragment.
        let valid = hosts.filter { (try? RuneWeaverConfig.validateAllowedHosts([$0])) != nil }
        return ServerEndpointConfig.dedupeNormalizedBootHosts(valid)
    }

    /// Encodes the stage keys only when a Start is in flight.
    /// The boot-bind keys encode only when known so older dashboards that
    /// ignore unknown keys keep parsing, and newer dashboards fall back to
    /// their snapshot when the keys are absent.
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
        try container.encodeIfPresent(serverHostname, forKey: .serverHostname)
        try container.encodeIfPresent(serverPort, forKey: .serverPort)
        try container.encodeIfPresent(serverAllowedHosts, forKey: .serverAllowedHosts)
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
    /// Whether this tool has configurable settings.
    public let hasConfig: Bool

    /// Creates a tool info row.
    /// `hasConfig` is stored verbatim so the listing route stays the single
    /// source of truth for which tools expose settings.
    public init(
        name: String,
        description: String,
        permissionLevel: String,
        inputSchema: String,
        isEnabled: Bool = true,
        isBuiltIn: Bool = true,
        pluginID: String? = nil,
        source: String = "builtin",
        integrityStatus: String = "valid",
        hasConfig: Bool = false
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
        self.hasConfig = hasConfig
    }

    /// Creates a row from a runtime tool.
    /// - Parameter tool: Registered tool.
    /// - Parameter hasConfig: Whether the tool exposes settings, supplied by the
    ///   caller so this type never branches on tool names.
    public init(
        _ tool: any Tool,
        isEnabled: Bool = true,
        isBuiltIn: Bool = true,
        pluginID: String? = nil,
        source: String = "builtin",
        integrityStatus: String = "valid",
        hasConfig: Bool = false
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
        self.hasConfig = hasConfig
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case description
        case permissionLevel
        case inputSchema
        case isEnabled
        case isBuiltIn
        case pluginID
        case source
        case integrityStatus
        case hasConfig
    }

    /// Decodes tolerantly so registries persisted before the settings flag
    /// existed still load with settings hidden instead of failing the listing.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decode(String.self, forKey: .description)
        permissionLevel = try container.decode(String.self, forKey: .permissionLevel)
        inputSchema = try container.decode(String.self, forKey: .inputSchema)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        isBuiltIn = try container.decode(Bool.self, forKey: .isBuiltIn)
        pluginID = try container.decodeIfPresent(String.self, forKey: .pluginID)
        source = try container.decode(String.self, forKey: .source)
        integrityStatus = try container.decode(String.self, forKey: .integrityStatus)
        hasConfig = try container.decodeIfPresent(Bool.self, forKey: .hasConfig) ?? false
    }

    /// Encodes every field including the settings flag so newer dashboards
    /// can rely on its presence without name-based fallbacks.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(description, forKey: .description)
        try container.encode(permissionLevel, forKey: .permissionLevel)
        try container.encode(inputSchema, forKey: .inputSchema)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(isBuiltIn, forKey: .isBuiltIn)
        try container.encodeIfPresent(pluginID, forKey: .pluginID)
        try container.encode(source, forKey: .source)
        try container.encode(integrityStatus, forKey: .integrityStatus)
        try container.encode(hasConfig, forKey: .hasConfig)
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

/// Paged facts window for `GET /memory/facts` with optional `q`, `limit`, and `offset`.
///
/// Carries the windowed rows plus the pre-slice total and the live store
/// tallies so the dashboard settles tab labels and the "More" cursor from one
/// read. Preferences ride along so older snapshots decoding as `FactsResponse`
/// keep parsing the same payload without a second fetch; the extra paging keys
/// are ignored by that shape while newer clients page off them.
public struct FactsPageResponse: Content, Equatable {
    /// Windowed facts for this page, newest first.
    public let facts: [UserFact]
    /// Total matching facts before slicing, driving the "More" cursor.
    public let total: Int
    /// Stored semantic fact count.
    public let semanticCount: Int
    /// Stored episode count.
    public let episodeCount: Int
    /// Window size honored for this page.
    public let limit: Int
    /// Cursor honored for this page.
    public let offset: Int
    /// Key/value preferences at read time.
    public let preferences: [Preference]

    /// Creates a paged facts response.
    public init(
        facts: [UserFact],
        total: Int,
        semanticCount: Int,
        episodeCount: Int,
        limit: Int,
        offset: Int,
        preferences: [Preference] = []
    ) {
        self.facts = facts
        self.total = total
        self.semanticCount = semanticCount
        self.episodeCount = episodeCount
        self.limit = limit
        self.offset = offset
        self.preferences = preferences
    }

    private enum CodingKeys: String, CodingKey {
        case facts
        case total
        case semanticCount
        case episodeCount
        case limit
        case offset
        case preferences
    }

    /// Decodes tolerantly so payloads from engines that predate paging still
    /// parse with the window standing in for the missing tally.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let facts = try container.decodeIfPresent([UserFact].self, forKey: .facts) ?? []
        self.facts = facts
        self.total = try container.decodeIfPresent(Int.self, forKey: .total) ?? facts.count
        self.semanticCount = try container.decodeIfPresent(Int.self, forKey: .semanticCount) ?? 0
        self.episodeCount = try container.decodeIfPresent(Int.self, forKey: .episodeCount) ?? 0
        self.limit = try container.decodeIfPresent(Int.self, forKey: .limit) ?? facts.count
        self.offset = try container.decodeIfPresent(Int.self, forKey: .offset) ?? 0
        self.preferences = try container.decodeIfPresent([Preference].self, forKey: .preferences) ?? []
    }

    /// Encodes every field so older dashboards decoding as `FactsResponse`
    /// find the snapshot keys they expect alongside the paging keys.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(facts, forKey: .facts)
        try container.encode(total, forKey: .total)
        try container.encode(semanticCount, forKey: .semanticCount)
        try container.encode(episodeCount, forKey: .episodeCount)
        try container.encode(limit, forKey: .limit)
        try container.encode(offset, forKey: .offset)
        try container.encode(preferences, forKey: .preferences)
    }
}

/// Episodic clear receipt for `DELETE /memory/episodes`.
///
/// Both counts describe the episodic tables only: how many rows the clear
/// removed and how many remain, so the dashboard can confirm the wipe without
/// a second read while semantic facts stay out of the shape entirely.
public struct EpisodicClearResponse: Content, Equatable {
    /// Rows removed by the clear, measured immediately before deleting.
    public let deletedCount: Int
    /// Rows remaining after the clear, measured immediately after deleting.
    public let episodeCount: Int

    /// Creates a clear receipt carrying both episodic measurements.
    public init(deletedCount: Int, episodeCount: Int) {
        self.deletedCount = deletedCount
        self.episodeCount = episodeCount
    }
}

/// One episodic turn for `GET /memory/episodes/recent`, newest first.
///
/// Carries the full stored content plus identity, owning session, and role so
/// the dashboard can preview a session without a second fetch. Timestamp rides
/// as Unix seconds so every client decodes it without sharing a date strategy.
/// Rows order newest first so the listing reads as a recency preview.
public struct EpisodicEpisodeDTO: Content, Equatable {
    /// Stored episode identifier.
    public let id: UUID
    /// Owning conversation session.
    public let sessionID: UUID
    /// Author role raw value (for example `"user"`).
    public let role: String
    /// Full stored turn content.
    public let content: String
    /// Occurrence time as Unix seconds since 1970 (server clock).
    public let timestamp: Double

    /// Creates an episodic listing row.
    public init(id: UUID, sessionID: UUID, role: String, content: String, timestamp: Double) {
        self.id = id
        self.sessionID = sessionID
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }
}

/// Recent episodic listing for `GET /memory/episodes/recent`, newest first.
///
/// Episodes cover the episodic tables only and order newest first; semantic
/// facts, profile, document index, and session ledgers stay out of the shape.
/// An unknown session reads as an empty list with count zero rather than an error.
/// The count always mirrors the row array length so tab tallies and listing rows
/// agree without a second fetch; a transmitted mismatch fails decoding instead
/// of surfacing as a silent empty.
public struct EpisodicRecentResponse: Content, Equatable {
    /// Episodic rows, newest first.
    public let episodes: [EpisodicEpisodeDTO]
    /// Number of rows in `episodes`.
    public let count: Int

    /// Creates a recent listing response.
    public init(episodes: [EpisodicEpisodeDTO]) {
        self.episodes = episodes
        self.count = episodes.count
    }

    private enum CodingKeys: String, CodingKey {
        case episodes
        case count
    }

    /// Decodes strictly so a missing payload or count mismatch surfaces as an error.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let episodes = try container.decode([EpisodicEpisodeDTO].self, forKey: .episodes)
        let transmitted = try container.decodeIfPresent(Int.self, forKey: .count) ?? episodes.count
        guard transmitted == episodes.count else {
            throw DecodingError.dataCorruptedError(
                forKey: .count,
                in: container,
                debugDescription: "count (\(transmitted)) must equal episodes.count (\(episodes.count))"
            )
        }
        self.episodes = episodes
        self.count = episodes.count
    }

    /// Encodes the row array plus its derived length.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(episodes, forKey: .episodes)
        try container.encode(episodes.count, forKey: .count)
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

extension ApprovalsResponse {
    /// Dashboard sandbox summary for one approval, single-sourced on the copy owner.
    ///
    /// Routes through the single shared call site so the dashboard DTO reads
    /// identical bytes to triage badges plus approval cards with no duplicate
    /// copy and no command, path, or host interpolation. Nil for non-bash
    /// tools or missing commands.
    /// - Parameters:
    ///   - request: Approval request carrying bash arguments.
    ///   - bashConfig: Live bash policy owning tier plus network defaults.
    ///   - workspaceRoot: Workspace root execution resolves against, or nil for the production root.
    /// - Returns: Shared summary for bash requests, or nil otherwise.
    public static func bashSandboxSummary(
        for request: PermissionRequest,
        bashConfig: BashConfig,
        workspaceRoot: URL? = nil
    ) -> String? {
        ApprovalQueue.bashSandboxSummary(for: request, bashConfig: bashConfig, workspaceRoot: workspaceRoot)
    }
}

/// Tiers for network egress interactive decisions.
public enum EgressDecisionTier: String, Codable, Sendable, Equatable {
    /// Allow this single tool call invocation.
    case allowOnce
    /// Allow for the duration of the active chat session.
    case allowSession
    /// Permanently add to policy.toml allowed_domains.
    case alwaysAllow
    /// Deny this single tool call invocation.
    case deny
    /// Permanently add to policy.toml blocked_domains.
    case denyAlways
}

/// Approval decision request for `POST /approvals/:id/decide`.
public struct ApprovalDecisionRequest: Content, Equatable {
    /// Whether the tool call may run.
    public let approved: Bool
    /// Graduated-trust tier recorded on approval. Defaults to `thisTime`.
    public var duration: TrustDuration?
    /// Whether to grant tool-wide trust matching any target.
    public var widen: Bool?
    /// Network egress decision tier when deciding an egress approval.
    public var egressDecision: EgressDecisionTier?

    /// Creates a decision request.
    public init(
        approved: Bool,
        duration: TrustDuration? = nil,
        widen: Bool? = nil,
        egressDecision: EgressDecisionTier? = nil
    ) {
        self.approved = approved
        self.duration = duration
        self.widen = widen
        self.egressDecision = egressDecision
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

/// Operator question response for `POST /approvals/:id/respond`.
public struct QuestionResponseRequest: Content, Sendable, Equatable {
    /// Chosen option or custom write-in text.
    public let answer: String?
    /// Whether the operator cancelled the question.
    public let cancelled: Bool?

    public init(answer: String? = nil, cancelled: Bool? = nil) {
        self.answer = answer
        self.cancelled = cancelled
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
/// Per-tool cancel message, single-sourced from core.
public typealias WSToolCancelMessage = RuneWeaverCore.WSToolCancelMessage
/// Cancelled confirmation frame, single-sourced from core.
public typealias WSCancelledFrame = RuneWeaverCore.WSCancelledFrame
/// Mid-turn degraded-tool notice, single-sourced from core.
public typealias WSWarningFrame = RuneWeaverCore.WSWarningFrame
/// Generic indeterminate tool progress, single-sourced from core.
public typealias WSToolProgressFrame = RuneWeaverCore.WSToolProgressFrame

/// Classifies one inbound WebSocket text frame.
public enum WSInboundKind: Sendable, Equatable {
    /// A chat message with user text.
    case chat(WSChatMessage)
    /// An approval decision for a pending request.
    case decision(WSDecisionMessage)
    /// A request to cancel the active turn.
    case cancel(WSCancelMessage)
    /// A request to cancel one running tool call, leaving its turn alive.
    case toolCancel(WSToolCancelMessage)
    /// A frame that is neither chat, decision, cancel, nor tool cancel.
    case unknown
}

private struct WSCancelFramePeek: Codable, Sendable {
    let type: String?
    let sessionID: UUID?
    let text: String?
    let id: UUID?
}

extension WSInboundKind {
    /// Classifies raw socket text into a chat, decision, cancel, tool-cancel, or unknown kind.
    /// - Parameter text: Raw socket text frame.
    /// - Returns: The inbound kind, or `unknown` when no shape decodes.
    public static func classify(_ text: String) -> WSInboundKind {
        guard let data = text.data(using: .utf8) else { return .unknown }
        let peek: WSCancelFramePeek? = {
            do {
                return try JSONDecoder().decode(WSCancelFramePeek.self, from: data)
            } catch {
                return nil
            }
        }()
        let hasText = !(peek?.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        // A decision is identified by its required `id` plus `approved` pair and
        // is classified before chat content sniffing: a payload can carry both
        // a stray text field and an approval decision, and preferring chat
        // would drop the decision so the request stays pending forever.
        do {
            let decision = try JSONDecoder().decode(WSDecisionMessage.self, from: data)
            return .decision(decision)
        } catch {
            RuneWeaverLog.server.debug("WSInboundKind.classify: not a decision message: \(error.localizedDescription)")
        }
        // A per-tool cancel carries an explicit discriminator plus a call
        // identifier, so it is matched before chat sniffing: its optional
        // `reason` never masquerades as chat text, and a malformed frame falls
        // through to unknown instead of aborting a whole turn.
        if peek?.type == "tool_cancel" {
            do {
                let toolCancel = try JSONDecoder().decode(WSToolCancelMessage.self, from: data)
                return .toolCancel(toolCancel)
            } catch {
                RuneWeaverLog.server.warning("WSInboundKind.classify: failed to decode WSToolCancelMessage: \(error.localizedDescription)")
                return .unknown
            }
        }
        do {
            let chat = try JSONDecoder().decode(WSChatMessage.self, from: data)
            if !chat.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .chat(chat)
            }
        } catch {
            RuneWeaverLog.server.debug("WSInboundKind.classify: not a chat message: \(error.localizedDescription)")
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

/// Request payload to cancel one in-flight tool call via `POST /chat/tool_cancel`.
///
/// Separate from ``CancelChatRequest`` because the two abort different scopes: a
/// turn cancel stops the whole reply, while this stops exactly one tool and lets
/// the model re-scope around its injected failure.
public struct ToolCancelRequest: Content, Equatable {
    /// Session owning the running call.
    public let sessionID: UUID
    /// Correlation identifier of the call to abort.
    public let callID: String
    /// Optional user reason forwarded to the model.
    public var reason: String?

    /// Creates a per-tool cancel request.
    public init(sessionID: UUID, callID: String, reason: String? = nil) {
        self.sessionID = sessionID
        self.callID = callID
        self.reason = reason
    }

    /// Trimmed call identifier, or nil when blank so the route can reject it.
    /// - Returns: Trimmed identifier, or nil when it carries no usable text.
    public var resolvedCallID: String? {
        let trimmed = callID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Trimmed and capped reason, or nil when nothing usable remains.
    /// Reuses the shared policy normalizer so REST and WebSocket cancellations
    /// bound the reason identically.
    /// - Returns: Normalized reason, or nil.
    public var resolvedReason: String? {
        OrchestratorToolLoop.normalizedToolCancelReason(reason)
    }
}

/// Response payload from `POST /chat/tool_cancel`.
public struct ToolCancelResponse: Content, Equatable {
    /// Session owning the call.
    public let sessionID: UUID
    /// Call identifier that was targeted.
    public let callID: String
    /// Whether a running call was actually cancelled.
    public let cancelled: Bool

    public init(sessionID: UUID, callID: String, cancelled: Bool) {
        self.sessionID = sessionID
        self.callID = callID
        self.cancelled = cancelled
    }
}

// MARK: - Workspace + Agent Tools live in ServerDTOsAgentTools.swift

// MARK: - Goals + Proactive Settings Patches and Merge live in ServerDTOsGoals.swift

// MARK: - Persona Settings Patch and Merge live in ServerDTOsPersona.swift

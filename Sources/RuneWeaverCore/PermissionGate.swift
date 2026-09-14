// Rune Weaver Core — Graduated-trust permission gate and trust storage.
//
// Enforces the trust boundary between the agent and the real world:
// read-only tools run freely, approval-gated tools require explicit
// decisions with graduated-trust grants, and denied actions refuse with
// reasons. Persists grants best-effort through a pluggable trust store.

import Foundation

/// How long a graduated-trust grant lasts.
///
/// Offered to the user when approving a state-changing action so they
/// are not approving the same thing forever. `thisTime` is a one-shot
/// approval and is never persisted; `forever` never expires.
public enum TrustDuration: String, Sendable, Codable, Equatable, CaseIterable {
    /// Approve once. No grant is stored.
    case thisTime
    /// Trust the action for the next 5 minutes.
    case fiveMinutes
    /// Trust the action for the next hour.
    case oneHour
    /// Trust the action for the next day.
    case oneDay
    /// Trust the action indefinitely.
    case forever

    /// Human-readable label shown in approval prompts.
    public var displayName: String {
        switch self {
        case .thisTime: "Only this time"
        case .fiveMinutes: "Next 5 minutes"
        case .oneHour: "Next hour"
        case .oneDay: "Next day"
        case .forever: "Forever"
        }
    }

    /// Grant lifetime in seconds, or nil when the grant never expires.
    ///
    /// `thisTime` returns `0` (expires immediately, so callers treat it
    /// as a single-use approval and skip persistence). `forever`
    /// returns `nil` (no expiry).
    public var timeInterval: TimeInterval? {
        switch self {
        case .thisTime: 0
        case .fiveMinutes: 5 * 60
        case .oneHour: 60 * 60
        case .oneDay: 24 * 60 * 60
        case .forever: nil
        }
    }
}

/// Identifies a trustable action: a tool plus an optional target.
///
/// Trust is stored per action per target, e.g. tool
/// `"email.send"` with target `"dr.smith@clinic.com"`. An empty
/// `target` means the grant covers every target for that tool.
public struct ActionDescriptor: Sendable, Codable, Equatable, Hashable {
    /// Name of the tool (e.g. `"email.send"`).
    public let toolName: String
    /// Action target (e.g. `"dr.smith@clinic.com"`). Empty matches all.
    public let target: String

    /// Creates an action descriptor.
    /// - Parameters:
    ///   - toolName: Name of the tool.
    ///   - target: Action target. Defaults to `""` (all targets).
    public init(toolName: String, target: String = "") {
        self.toolName = toolName
        self.target = target
    }

    /// Derives a descriptor from a tool call.
    ///
    /// Best-effort extraction of a target from common argument keys
    /// (`to`, `recipient`, `target`, `path`, `url`, `email`,
    /// `address`, `destination`). Falls back to `""` when no target
    /// can be found or the arguments are not JSON.
    /// - Parameters:
    ///   - toolCall: Invocation arguments.
    ///   - tool: The tool being invoked.
    /// - Returns: Descriptor for the call.
    public static func descriptor(for toolCall: ToolInput, tool: any Tool) -> ActionDescriptor {
        ActionDescriptor(toolName: tool.name, target: ActionDescriptor.target(from: toolCall))
    }

    /// Extracts a target string from raw tool arguments.
    /// - Parameter toolCall: Invocation carrying `argumentsJSON`.
    /// - Returns: The extracted target, or `""` when absent.
    public static func target(from toolCall: ToolInput) -> String {
        guard let data = toolCall.argumentsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "" }
        for key in ["to", "recipient", "target", "path", "url", "email", "address", "destination"] {
            if let value = object[key] as? String, !value.isEmpty {
                return value
            }
        }
        return ""
    }
}

/// A persisted graduated-trust grant for an ``ActionDescriptor``.
public struct TrustGrant: Sendable, Codable, Equatable {
    /// Stable grant identifier.
    public let id: UUID
    /// The trusted action (tool + target).
    public let actionDescriptor: ActionDescriptor
    /// When the grant was created.
    public let grantedAt: Date
    /// When the grant expires, or nil when it never expires.
    public let expiresAt: Date?
    /// The duration tier this grant was created with.
    public let duration: TrustDuration

    /// Creates a trust grant.
    /// - Parameters:
    ///   - id: Grant identifier. Defaults to a new UUID.
    ///   - actionDescriptor: The trusted action.
    ///   - grantedAt: Creation date. Defaults to now.
    ///   - expiresAt: Expiry date, or nil for no expiry.
    ///   - duration: Duration tier.
    public init(
        id: UUID = UUID(),
        actionDescriptor: ActionDescriptor,
        grantedAt: Date = Date(),
        expiresAt: Date?,
        duration: TrustDuration
    ) {
        self.id = id
        self.actionDescriptor = actionDescriptor
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
        self.duration = duration
    }

    /// Whether the grant is expired at the given date.
    /// - Parameter date: Reference date. Defaults to now.
    /// - Returns: True when `expiresAt` is past `date`.
    public func isExpired(at date: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= date
    }

    /// Whether the grant is currently valid.
    /// - Parameter date: Reference date. Defaults to now.
    /// - Returns: True when not expired.
    public func isValid(at date: Date = Date()) -> Bool {
        !isExpired(at: date)
    }
}

/// Approval prompt sent to connected clients (e.g. over WebSocket).
public struct PermissionRequest: Sendable, Codable, Equatable {
    /// Stable request identifier.
    public let id: UUID
    /// Name of the tool requesting approval.
    public let toolName: String
    /// Human-readable summary of what the tool wants to do.
    public let description: String
    /// The original invocation arguments.
    public let input: ToolInput
    /// Duration options offered to the user.
    public let suggestedDurations: [TrustDuration]
    /// Owning session for narrated parked turns, if known.
    ///
    /// Structured gate checks leave this untagged while the narration
    /// fallback stamps the session so the approvals inbox can resume the
    /// same conversation on allow or notify it on deny.
    public let sessionID: UUID?

    /// Coding keys for the approval prompt.
    private enum CodingKeys: String, CodingKey {
        /// Stable request identifier.
        case id
        /// Name of the tool requesting approval.
        case toolName
        /// Human-readable summary.
        case description
        /// Original invocation arguments.
        case input
        /// Duration options offered to the user.
        case suggestedDurations
        /// Owning session, when tagged.
        case sessionID
    }

    /// Creates a permission request.
    /// - Parameters:
    ///   - id: Request identifier. Defaults to a new UUID.
    ///   - toolName: Name of the tool.
    ///   - description: Human-readable summary.
    ///   - input: Original invocation.
    ///   - suggestedDurations: Duration options. Defaults to all tiers.
    ///   - sessionID: Owning session for parked narration. Defaults to nil (untagged).
    public init(
        id: UUID = UUID(),
        toolName: String,
        description: String,
        input: ToolInput,
        suggestedDurations: [TrustDuration] = TrustDuration.allCases,
        sessionID: UUID? = nil
    ) {
        self.id = id
        self.toolName = toolName
        self.description = description
        self.input = input
        self.suggestedDurations = suggestedDurations
        self.sessionID = sessionID
    }

    /// Decodes a request, tolerating payloads written before session tagging.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.toolName = try container.decode(String.self, forKey: .toolName)
        self.description = try container.decode(String.self, forKey: .description)
        self.input = try container.decode(ToolInput.self, forKey: .input)
        self.suggestedDurations = try container.decode([TrustDuration].self, forKey: .suggestedDurations)
        self.sessionID = try container.decodeIfPresent(UUID.self, forKey: .sessionID)
    }

    /// Encodes a request, omitting the session tag when untagged.
    /// - Parameter encoder: Destination encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(toolName, forKey: .toolName)
        try container.encode(description, forKey: .description)
        try container.encode(input, forKey: .input)
        try container.encode(suggestedDurations, forKey: .suggestedDurations)
        try container.encodeIfPresent(sessionID, forKey: .sessionID)
    }
}

/// Verdict returned by ``PermissionGate/checkPermission(toolCall:tool:)``.
///
/// `ToolBus` consults the gate before executing any tool: `allowed`
/// runs immediately, `requiresApproval` is forwarded to connected
/// clients (WebSocket) for a trust-tiered decision, and `denied`
/// fails the call with the associated reason.
public enum PermissionDecision: Sendable, Equatable {
    /// The call may run immediately.
    case allowed
    /// The call needs user approval via the associated request.
    case requiresApproval(PermissionRequest)
    /// The call is refused with the associated reason.
    case denied(String)
}

/// Persistence contract for ``TrustGrant`` records.
///
/// The gate keeps grants in memory and mirrors them to the store
/// best-effort; a corrupt or missing store never blocks permission
/// checks, it simply starts from an empty grant set.
public protocol TrustStore: Sendable {
    /// Loads all stored grants.
    /// - Returns: Persisted grants, possibly empty.
    func load() throws -> [TrustGrant]
    /// Replaces the stored grants.
    /// - Parameter grants: Current grants to persist.
    func save(_ grants: [TrustGrant]) throws
}

/// In-memory ``TrustStore`` for tests and ephemeral sessions.
public final class InMemoryTrustStore: TrustStore, @unchecked Sendable {
    private let lock = NSLock()
    private var grants: [TrustGrant]

    /// Creates an empty in-memory store.
    /// - Parameter grants: Seed grants. Defaults to empty.
    public init(grants: [TrustGrant] = []) {
        self.grants = grants
    }

    /// Returns the in-memory grants.
    /// - Returns: Current grants.
    public func load() throws -> [TrustGrant] {
        lock.lock()
        defer { lock.unlock() }
        return grants
    }

    /// Replaces the in-memory grants.
    /// - Parameter grants: Grants to keep.
    public func save(_ grants: [TrustGrant]) throws {
        lock.lock()
        defer { lock.unlock() }
        self.grants = grants
    }
}

/// JSON-file ``TrustStore`` persisted under `~/.runeweaver/`.
///
/// Stores grants as a JSON array at `fileURL`. Missing files read as
/// empty; writes are atomic.
public struct FileTrustStore: TrustStore, Sendable {
    /// File URL of the JSON grant list.
    public let fileURL: URL

    /// Creates a file store.
    /// - Parameter fileURL: Destination JSON file.
    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Loads grants from disk, returning empty when absent.
    /// - Returns: Persisted grants.
    public func load() throws -> [TrustGrant] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else { return [] }
        return try JSONDecoder().decode([TrustGrant].self, from: data)
    }

    /// Persists grants to disk atomically.
    /// - Parameter grants: Grants to persist.
    public func save(_ grants: [TrustGrant]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(grants)
        try data.write(to: fileURL, options: .atomic)
    }
}

/// Trust boundary between the agent and the real world.
///
/// The gate enforces graduated trust for state-changing tools:
/// - `readOnly` tools are always `allowed`.
/// - `trusted` tools are `allowed` unless explicitly denied.
/// - `requiresApproval` tools are `allowed` only when covered by a
///   live ``TrustGrant``; otherwise a ``PermissionRequest`` is
///   returned so `ToolBus` can forward it to connected clients via
///   WebSocket and record the user's chosen ``TrustDuration`` with
///   ``grantTrust(for:duration:)``.
public actor PermissionGate {
    /// Live grants, mirrored to the store best-effort.
    private var grants: [TrustGrant] = []
    /// Explicit refusals by descriptor, carrying the denial reason.
    private var denials: [ActionDescriptor: String] = [:]
    /// Optional persistence backend.
    private let store: (any TrustStore)?

    /// Creates a permission gate.
    /// - Parameter store: Persistence backend. Defaults to nil
    ///   (memory only). Stored grants load best-effort.
    public init(store: (any TrustStore)? = nil) {
        self.store = store
        if let store {
            grants = (try? store.load()) ?? []
            grants.removeAll { $0.isExpired() }
        }
    }

    /// Decides whether a tool call may run.
    ///
    /// Expired grants are pruned on every check. Denied descriptors
    /// return `denied` first; `readOnly`/`trusted` tools are otherwise
    /// `allowed`; `requiresApproval` tools return `allowed` when a
    /// live grant covers the call's descriptor (exact target match or
    /// a tool-wide grant with an empty target), else
    /// `requiresApproval` with a request offering every
    /// ``TrustDuration`` tier.
    /// - Parameters:
    ///   - toolCall: Invocation arguments.
    ///   - tool: The tool being invoked.
    /// - Returns: The permission verdict.
    public func checkPermission(toolCall: ToolInput, tool: any Tool) -> PermissionDecision {
        pruneExpired()
        let descriptor = ActionDescriptor.descriptor(for: toolCall, tool: tool)
        if let reason = denials[descriptor] ?? denials[ActionDescriptor(toolName: tool.name)] {
            return .denied(reason)
        }
        switch tool.permissionLevel {
        case .readOnly:
            return .allowed
        case .trusted:
            return .allowed
        case .requiresApproval:
            if covers(descriptor) {
                return .allowed
            }
            let request = PermissionRequest(
                toolName: tool.name,
                description: tool.description,
                input: toolCall,
                suggestedDurations: TrustDuration.allCases
            )
            return .requiresApproval(request)
        }
    }

    /// Records trust for an action.
    ///
    /// `thisTime` approvals are one-shot and intentionally not stored.
    /// Any existing grant for the same descriptor is replaced, then
    /// the grant set is persisted best-effort.
    /// - Parameters:
    ///   - descriptor: The action to trust.
    ///   - duration: How long the trust lasts.
    public func grantTrust(for descriptor: ActionDescriptor, duration: TrustDuration) {
        guard duration != .thisTime else { return }
        pruneExpired()
        grants.removeAll { $0.actionDescriptor == descriptor }
        let now = Date()
        let grant = TrustGrant(
            actionDescriptor: descriptor,
            grantedAt: now,
            expiresAt: duration.timeInterval.map { now.addingTimeInterval($0) },
            duration: duration
        )
        grants.append(grant)
        denials.removeValue(forKey: descriptor)
        persistBestEffort()
    }

    /// Removes trust for an action.
    ///
    /// Drops every grant matching the descriptor exactly, plus
    /// tool-wide grants when `descriptor.target` is empty, then
    /// persists best-effort. Missing grants are a no-op.
    /// - Parameter descriptor: The action to distrust.
    public func revokeTrust(for descriptor: ActionDescriptor) {
        if descriptor.target.isEmpty {
            grants.removeAll { $0.actionDescriptor.toolName == descriptor.toolName }
        } else {
            grants.removeAll { $0.actionDescriptor == descriptor }
        }
        persistBestEffort()
    }

    /// Explicitly refuses an action with a reason.
    ///
    /// Denied descriptors make ``checkPermission(toolCall:tool:)``
    /// return `denied` until ``removeDenial(for:)`` or a fresh
    /// ``grantTrust(for:duration:)`` clears them.
    /// - Parameters:
    ///   - descriptor: The action to refuse.
    ///   - reason: Human-readable reason surfaced to the LLM.
    public func deny(_ descriptor: ActionDescriptor, reason: String) {
        denials[descriptor] = reason
    }

    /// Clears an explicit refusal.
    /// - Parameter descriptor: The action to unblock.
    public func removeDenial(for descriptor: ActionDescriptor) {
        denials.removeValue(forKey: descriptor)
    }

    /// Returns the currently valid grants, pruning expired ones first.
    /// - Returns: Live grants.
    public func activeGrants() -> [TrustGrant] {
        pruneExpired()
        return grants
    }

    /// Whether a live grant covers the descriptor.
    /// - Parameter descriptor: The action to check.
    /// - Returns: True when a valid grant matches.
    public func isTrusted(_ descriptor: ActionDescriptor) -> Bool {
        pruneExpired()
        return covers(descriptor)
    }

    // MARK: - Private

    /// Whether any live grant covers the descriptor, either by exact
    /// target match or by a tool-wide grant with an empty target.
    private func covers(_ descriptor: ActionDescriptor) -> Bool {
        grants.contains {
            $0.isValid()
                && $0.actionDescriptor.toolName == descriptor.toolName
                && ($0.actionDescriptor.target.isEmpty || $0.actionDescriptor.target == descriptor.target)
        }
    }

    /// Drops expired grants.
    private func pruneExpired() {
        let now = Date()
        grants.removeAll { $0.isExpired(at: now) }
    }

    /// Mirrors grants to the store, swallowing errors so permission
    /// checks never fail on persistence issues.
    private func persistBestEffort() {
        guard let store else { return }
        try? store.save(grants)
    }
}

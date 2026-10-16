// Rune Weaver Server — Durable access-rule and session-trust DTOs for the approvals API.

import Foundation
import RuneWeaverCore
import Vapor

/// Access-rule change signal pushed by the engine over WebSocket.
public struct WSAccessRulesChanged: Codable, Sendable, Equatable {
    /// Always `"access_rules_changed"`.
    public let type: String

    /// Creates an access-rule change signal.
    public init() {
        self.type = "access_rules_changed"
    }
}

/// How wide a rule or a decision reaches for one tool.
public struct AccessScopeDTO: Content, Equatable, Sendable {
    /// Kind discriminator naming which payload fields carry the scope.
    public let kind: String
    /// Exact action target, for the `exactTarget` kind.
    public let target: String?
    /// Canonical handles, for the `recipientSet` kind.
    public let handles: [String]?
    /// Network host, for the `domain` kind.
    public let host: String?
    /// Whether the domain kind also covers subdomains. Absent reads as false.
    public let subdomains: Bool?
    /// Filesystem prefix, for the `pathPrefix` kind.
    public let path: String?
    /// Bash command pattern, for the `glob` kind.
    public let pattern: String?

    /// Kind spellings the envelope accepts; anything else fails the decode.
    public enum Kind: String, CaseIterable, Sendable {
        /// Every call of the tool, whatever the arguments say.
        case tool
        /// Exactly one action target.
        case exactTarget
        /// A set of message or mail recipients.
        case recipientSet
        /// A network host, optionally with every subdomain beneath it.
        case domain
        /// A filesystem path prefix and everything beneath it.
        case pathPrefix
        /// A bash command pattern.
        case glob
    }

    /// Creates an envelope from a canonical core scope.
    /// - Parameter scope: Canonical scope to project.
    public init(_ scope: AccessScope) {
        switch scope {
        case .toolWide:
            self.init(kind: .tool)
        case let .exactTarget(target):
            self.init(kind: .exactTarget, target: target)
        case let .recipientSet(handles):
            self.init(kind: .recipientSet, handles: handles)
        case let .domain(host, subdomains):
            self.init(kind: .domain, host: host, subdomains: subdomains)
        case let .pathPrefix(path):
            self.init(kind: .pathPrefix, path: path)
        case let .glob(pattern):
            self.init(kind: .glob, pattern: pattern)
        }
    }

    /// Creates an envelope from its kind plus payload. kind: Kind discriminator.
    public init(
        kind: Kind,
        target: String? = nil,
        handles: [String]? = nil,
        host: String? = nil,
        subdomains: Bool? = nil,
        path: String? = nil,
        pattern: String? = nil
    ) {
        self.kind = kind.rawValue
        self.target = target
        self.handles = handles
        self.host = host
        self.subdomains = subdomains
        self.path = path
        self.pattern = pattern
    }

    /// Canonical core scope this envelope names, or nil when malformed.
    /// - Returns: The canonical scope, or nil when the payload fails the gate.
    public func accessScope() -> AccessScope? {
        guard let kind = Kind(rawValue: kind) else { return nil }
        switch kind {
        case .tool:
            return .toolWide
        case .exactTarget:
            guard let target, !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return AccessScope.canonicalized(.exactTarget(target))
        case .recipientSet:
            guard let handles, !handles.isEmpty else { return nil }
            return AccessScope.canonicalized(.recipientSet(handles))
        case .domain:
            guard let host, !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return AccessScope.canonicalized(.domain(host: host, subdomains: subdomains ?? false))
        case .pathPrefix:
            guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return AccessScope.canonicalized(.pathPrefix(path))
        case .glob:
            guard let pattern, !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return AccessScope.canonicalized(.glob(pattern))
        }
    }

    /// Short human-readable label for dashboards, sharing the denial-text
    /// vocabulary so a rule row and a refusal name one scope the same way.
    public var displayLabel: String {
        guard let kind = Kind(rawValue: kind) else { return "unknown scope" }
        switch kind {
        case .tool:
            return "every target"
        case .exactTarget:
            return "target '\(target ?? "")'"
        case .recipientSet:
            let members = AccessScope.normalizeRecipients(handles ?? [])
            return "recipients \(members.joined(separator: ", "))"
        case .domain:
            return (subdomains ?? false) ? "domain \(host ?? "") and its subdomains" : "domain \(host ?? "")"
        case .pathPrefix:
            return "path prefix \(path ?? "")"
        case .glob:
            return "command pattern \(pattern ?? "")"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case target
        case handles
        case host
        case subdomains
        case path
        case pattern
    }

    /// Decodes one envelope, refusing an unknown kind or a malformed payload.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawKind = try container.decode(String.self, forKey: .kind)
        guard let kind = Kind(rawValue: rawKind) else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown access scope kind '\(rawKind)'."
            )
        }
        let decoded = try AccessScopeDTO(
            kind: kind,
            target: container.decodeIfPresent(String.self, forKey: .target),
            handles: container.decodeIfPresent([String].self, forKey: .handles),
            host: container.decodeIfPresent(String.self, forKey: .host),
            subdomains: container.decodeIfPresent(Bool.self, forKey: .subdomains),
            path: container.decodeIfPresent(String.self, forKey: .path),
            pattern: container.decodeIfPresent(String.self, forKey: .pattern)
        )
        guard let scope = decoded.accessScope() else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Access scope '\(rawKind)' is not canonical."
            )
        }
        // Store the canonical spelling so an encode never echoes back a payload
        // the gate would have refused.
        let canonical = AccessScopeDTO(scope)
        self.kind = canonical.kind
        target = canonical.target
        handles = canonical.handles
        host = canonical.host
        subdomains = canonical.subdomains
        path = canonical.path
        pattern = canonical.pattern
    }

    /// Encodes one envelope, omitting the payload fields its kind does not name.
    /// - Parameter encoder: Destination encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(target, forKey: .target)
        try container.encodeIfPresent(handles, forKey: .handles)
        try container.encodeIfPresent(host, forKey: .host)
        if subdomains != nil {
            try container.encodeIfPresent(subdomains, forKey: .subdomains)
        }
        try container.encodeIfPresent(path, forKey: .path)
        try container.encodeIfPresent(pattern, forKey: .pattern)
    }
}

/// One durable access rule for `GET /approvals/rules`. A nil `expiresAt` is the forever tier, so
/// readers render it as never expiring rather than as missing data.
public struct AccessRuleResponse: Content, Equatable, Sendable {
    /// Stable rule identifier.
    public let id: UUID
    /// Tool the rule covers.
    public let toolName: String
    /// How wide the rule reaches for that tool.
    public let scope: AccessScopeDTO
    /// Whether covered calls are trusted or refused.
    public let action: AccessAction
    /// Lifetime tier, or nil for a standing rule that never expires.
    public let duration: TrustDuration?
    /// When the rule was created.
    public let grantedAt: Date
    /// When the rule stops covering, or nil when it never expires.
    public let expiresAt: Date?
    /// How many covered calls have run against this rule.
    public let useCount: Int
    /// When the rule last covered a call, or nil when never used.
    public let lastUsedAt: Date?
    /// Caller-facing note recorded when the rule was created.
    public let reason: String?
    /// Human-readable scope for dashboards.
    public let displayScope: String

    /// Creates a rule row from a stored rule, deriving the display scope so a
    /// tool-wide rule stays unambiguous on dashboards.
    /// - Parameter rule: Stored rule.
    public init(_ rule: AccessRule) {
        self.init(
            id: rule.id,
            toolName: rule.toolName,
            scope: AccessScopeDTO(rule.scope),
            action: rule.action,
            duration: rule.duration,
            grantedAt: rule.grantedAt,
            expiresAt: rule.expiresAt,
            useCount: rule.useCount,
            lastUsedAt: rule.lastUsedAt,
            reason: rule.reason
        )
    }

    /// Creates a rule row. id: Stable rule identifier.
    public init(
        id: UUID,
        toolName: String,
        scope: AccessScopeDTO,
        action: AccessAction,
        duration: TrustDuration?,
        grantedAt: Date,
        expiresAt: Date?,
        useCount: Int = 0,
        lastUsedAt: Date? = nil,
        reason: String? = nil
    ) {
        self.id = id
        self.toolName = toolName
        self.scope = scope
        self.action = action
        self.duration = duration
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
        // Counters never go negative on dashboards; clamp direct construction
        // so a corrupt caller cannot seed a negative baseline.
        self.useCount = max(0, useCount)
        self.lastUsedAt = lastUsedAt
        self.reason = reason
        self.displayScope = scope.displayLabel
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case toolName
        case scope
        case action
        case duration
        case grantedAt
        case expiresAt
        case useCount
        case lastUsedAt
        case reason
        case displayScope
    }

    /// Decodes a rule row, tolerating payloads written before usage counters
    /// or the derived display label existed so legacy rows still read.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        toolName = try container.decode(String.self, forKey: .toolName)
        scope = try container.decode(AccessScopeDTO.self, forKey: .scope)
        action = try container.decodeIfPresent(AccessAction.self, forKey: .action) ?? .allow
        duration = try container.decodeIfPresent(TrustDuration.self, forKey: .duration)
        grantedAt = try container.decode(Date.self, forKey: .grantedAt)
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        let decodedCount = try container.decodeIfPresent(Int.self, forKey: .useCount) ?? 0
        useCount = max(0, decodedCount)
        lastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        // Older payloads predate the derived label, so fall back to the
        // scope-derived label instead of failing the whole row.
        if let stored = try container.decodeIfPresent(String.self, forKey: .displayScope),
           !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            displayScope = stored
        } else {
            displayScope = scope.displayLabel
        }
    }

    /// Encodes a rule row including its usage counters.
    /// - Parameter encoder: Destination encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(toolName, forKey: .toolName)
        try container.encode(scope, forKey: .scope)
        try container.encode(action, forKey: .action)
        try container.encodeIfPresent(duration, forKey: .duration)
        try container.encode(grantedAt, forKey: .grantedAt)
        try container.encodeIfPresent(expiresAt, forKey: .expiresAt)
        try container.encode(useCount, forKey: .useCount)
        try container.encodeIfPresent(lastUsedAt, forKey: .lastUsedAt)
        try container.encodeIfPresent(reason, forKey: .reason)
        try container.encode(displayScope, forKey: .displayScope)
    }
}

/// Durable access rules response for `GET /approvals/rules`.
public struct AccessRulesResponse: Content, Equatable, Sendable {
    /// Rules, newest first, allows and denies together.
    public let rules: [AccessRuleResponse]
    /// Number of rules in `rules`.
    public let count: Int

    /// Creates a rules response.
    /// - Parameter rules: Rule rows, already in display order.
    public init(rules: [AccessRuleResponse]) {
        self.rules = rules
        self.count = rules.count
    }
}

/// Standing rule creation request for `POST /approvals/rules`. The tool, scope, action, and
/// optional tier fully describe the rule, so a caller holding a complete policy builds one without
/// hand-mapping fields.
public struct RuleCreateRequest: Content, Equatable, Sendable {
    /// Tool the rule covers.
    public let toolName: String
    /// How wide the rule reaches for that tool.
    public let scope: AccessScopeDTO
    /// Whether covered calls are trusted or refused.
    public let action: AccessAction
    /// Lifetime tier for an allow rule; nil means the standing never-expires
    /// tier. Ignored for a deny rule, which never expires.
    public let duration: TrustDuration?
    /// Caller-facing note recorded with the rule.
    public let reason: String?

    /// Creates a rule creation request. toolName: Tool the rule covers.
    public init(
        toolName: String,
        scope: AccessScopeDTO,
        action: AccessAction,
        duration: TrustDuration? = nil,
        reason: String? = nil
    ) {
        self.toolName = toolName
        self.scope = scope
        self.action = action
        self.duration = duration
        self.reason = reason
    }
}

/// Duration re-arm request for `PATCH /approvals/rules/:id`.
public struct RearmRuleRequest: Content, Equatable, Sendable {
    /// Replacement duration tier.
    public let duration: TrustDuration

    /// Creates a re-arm request.
    /// - Parameter duration: Replacement duration tier.
    public init(duration: TrustDuration) {
        self.duration = duration
    }
}

/// One non-durable grant a session still carries: the `forTask` and `forSession` tiers that expire
/// with their turn or conversation instead of surviving into the durable rule store.
public struct EphemeralGrantDTO: Content, Equatable, Sendable {
    /// Tool the grant covers.
    public let toolName: String
    /// How wide the grant reaches for that tool.
    public let scope: AccessScopeDTO
    /// Which lifecycle boundary ends the grant.
    public let duration: TrustDuration

    /// Creates an ephemeral grant row. toolName: Tool the grant covers.
    public init(toolName: String, scope: AccessScopeDTO, duration: TrustDuration) {
        self.toolName = toolName
        self.scope = scope
        self.duration = duration
    }

    /// Creates a row from a stored grant, mapping its lifecycle kind onto the
    /// duration tier the dashboards already render.
    /// - Parameter grant: Stored ephemeral grant.
    public init(_ grant: EphemeralGrant) {
        self.init(
            toolName: grant.toolName,
            scope: AccessScopeDTO(grant.scope),
            duration: grant.kind == .task ? .forTask : .forSession
        )
    }
}

/// Session trust view for `GET /approvals/session-trust`.
public struct SessionTrustResponse: Content, Equatable, Sendable {
    /// Session the trust belongs to.
    public let sessionID: UUID
    /// Ephemeral grants the session still carries.
    public let grants: [EphemeralGrantDTO]
    /// Number of grants in `grants`.
    public let count: Int
    /// Domains the egress supervisor trusts for the rest of this session.
    public let egressSessionDomains: [String]
    /// Unspent one-shot domains the supervisor still allows for this session.
    public let egressOneShotDomains: [String]

    /// Creates a session trust view. sessionID: Session the trust belongs to.
    public init(
        sessionID: UUID,
        grants: [EphemeralGrantDTO],
        egressSessionDomains: [String],
        egressOneShotDomains: [String]
    ) {
        self.sessionID = sessionID
        self.grants = grants
        self.count = grants.count
        self.egressSessionDomains = egressSessionDomains
        self.egressOneShotDomains = egressOneShotDomains
    }
}

/// Ephemeral trust clear request for `POST /approvals/ephemeral/clear`.
public struct EphemeralClearRequest: Content, Equatable, Sendable {
    /// Session whose ephemeral trust clears.
    public let sessionID: UUID
    /// Tool the caller is revoking, when it named one row.
    public let toolName: String?

    /// Creates an ephemeral clear request. sessionID: Session whose ephemeral trust
    /// clears.
    public init(sessionID: UUID, toolName: String? = nil) {
        self.sessionID = sessionID
        self.toolName = toolName
    }
}

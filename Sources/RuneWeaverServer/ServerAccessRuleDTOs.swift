// Rune Weaver Server — Durable access-rule and session-trust DTOs for the approvals API.
//
// Purpose: carry the rules surface the dashboards read — one durable rule per
// tool-plus-scope pair with its allow or deny action, usage counters, and
// human-readable scope label — plus the ephemeral trust one session still holds
// and the egress supervisor's session and one-shot domains beside it.
// Scope: REST bodies and the scope envelope only; rule evaluation, minting,
// widening, re-arming, and expiry stay with `PermissionGate`, and the grant
// tables the ephemeral listing reads stay with the gate and
// `OutboundEgressSupervisor`.
// Architectural role: keeps the Vapor adapters decoupled from the engine core
// in version-tolerant Codable contracts, so a dashboard built against an older
// engine still decodes and a malformed scope fails here instead of minting
// trust nobody chose.

import Foundation
import RuneWeaverCore
import Vapor

/// Access-rule change signal pushed by the engine over WebSocket.
///
/// Dashboards refetch `GET /approvals/rules` on this signal, so the payload
/// stays a lightweight discriminator instead of a full snapshot that could
/// drift from the pruned store contents. Older clients drop the unknown `type`
/// without rendering, so the rename from the grants-era frame costs them
/// nothing.
public struct WSAccessRulesChanged: Codable, Sendable, Equatable {
    /// Always `"access_rules_changed"`.
    public let type: String

    /// Creates an access-rule change signal.
    public init() {
        self.type = "access_rules_changed"
    }
}

/// How wide a rule or a decision reaches for one tool.
///
/// The wire envelope carries the kind discriminator plus only the fields that
/// kind names, so a tool-wide scope stays a bare `{"kind":"tool"}` and a domain
/// scope carries its host. Every decode routes through the shared
/// ``AccessScope/canonicalized(_:)`` gate, so an over-bound recipient set, a
/// wildcard host, a relative prefix, or a blank glob fails here rather than
/// reaching a store that would have to refuse it later.
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

    /// Creates an envelope from its kind plus payload.
    /// - Parameters:
    ///   - kind: Kind discriminator.
    ///   - target: Exact target for the exact-target kind.
    ///   - handles: Canonical handles for the recipient-set kind.
    ///   - host: Host for the domain kind.
    ///   - subdomains: Subdomain coverage for the domain kind.
    ///   - path: Prefix for the path-prefix kind.
    ///   - pattern: Command pattern for the glob kind.
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
    ///
    /// A payload that does not survive ``AccessScope/canonicalized(_:)`` is
    /// malformed data rather than a scope the matcher should refuse later, so
    /// the decode throws and the route answers 400 instead of storing a rule
    /// nobody could exercise.
    /// - Parameter decoder: Source decoder.
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

/// One durable access rule for `GET /approvals/rules`.
///
/// Allow rules keep covered calls auto-approved until they expire or are
/// revoked; deny rules park covered calls forever. A nil `expiresAt` is the
/// forever tier, so readers render it as never expiring rather than as missing
/// data. The usage counters ride along so a dashboard can prove liveness — a
/// steadily advancing counter shows the rule is relied upon, while a long-lived
/// zero singles out untested trust that is safe to prune.
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

    /// Creates a rule row.
    /// - Parameters:
    ///   - id: Stable rule identifier.
    ///   - toolName: Tool the rule covers.
    ///   - scope: How wide the rule reaches.
    ///   - action: Whether covered calls are trusted or refused.
    ///   - duration: Lifetime tier, or nil for a standing rule.
    ///   - grantedAt: Creation time.
    ///   - expiresAt: Expiry, or nil when it never expires.
    ///   - useCount: Covered-call counter.
    ///   - lastUsedAt: Last covered-call time, nil when never used.
    ///   - reason: Caller-facing note.
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

/// Standing rule creation request for `POST /approvals/rules`.
///
/// The tool, scope, action, and optional tier fully describe the rule, so a
/// caller holding a complete policy builds one without hand-mapping fields. A
/// deny rule never expires: the duration is accepted for symmetry with the
/// allow shape and ignored, because a dated refusal would let it lapse into the
/// allow decision underneath it.
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

    /// Creates a rule creation request.
    /// - Parameters:
    ///   - toolName: Tool the rule covers.
    ///   - scope: How wide the rule reaches.
    ///   - action: Whether covered calls are trusted or refused.
    ///   - duration: Lifetime tier for an allow rule.
    ///   - reason: Caller-facing note.
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
///
/// Carries only the replacement tier so the permission gate stays the single
/// owner of expiry math; a re-arm must extend an allow rule to a durable tier,
/// never collapse it back to a one-shot decision that stores no rule.
public struct RearmRuleRequest: Content, Equatable, Sendable {
    /// Replacement duration tier.
    public let duration: TrustDuration

    /// Creates a re-arm request.
    /// - Parameter duration: Replacement duration tier.
    public init(duration: TrustDuration) {
        self.duration = duration
    }
}

/// One non-durable grant a session still carries: the `forTask` and `forSession`
/// tiers that expire with their turn or conversation instead of surviving into
/// the durable rule store. Ephemeral grants carry no identity and no action,
/// because a refusal stores nothing at all.
public struct EphemeralGrantDTO: Content, Equatable, Sendable {
    /// Tool the grant covers.
    public let toolName: String
    /// How wide the grant reaches for that tool.
    public let scope: AccessScopeDTO
    /// Which lifecycle boundary ends the grant.
    public let duration: TrustDuration

    /// Creates an ephemeral grant row.
    /// - Parameters:
    ///   - toolName: Tool the grant covers.
    ///   - scope: How wide the grant reaches.
    ///   - duration: `forTask` or `forSession`.
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
///
/// Lists the ephemeral grants the gate still holds for one session beside the
/// egress supervisor's session and one-shot domain allowances, so a dashboard
/// can show exactly what stays auto-approved for the rest of the conversation
/// without re-deriving it from run history.
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

    /// Creates a session trust view.
    /// - Parameters:
    ///   - sessionID: Session the trust belongs to.
    ///   - grants: Ephemeral grants the session still carries.
    ///   - egressSessionDomains: Supervisor session domains.
    ///   - egressOneShotDomains: Supervisor unspent one-shot domains.
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
///
/// The session is the unit of clearing: the gate's ephemeral tables and the
/// supervisor's grant tables both key on it, so one call drops every grant the
/// conversation still holds. An optional tool name is accepted for callers that
/// revoke one row at a time; the clear itself stays session-scoped because the
/// gate exposes no narrower boundary.
public struct EphemeralClearRequest: Content, Equatable, Sendable {
    /// Session whose ephemeral trust clears.
    public let sessionID: UUID
    /// Tool the caller is revoking, when it named one row.
    public let toolName: String?

    /// Creates an ephemeral clear request.
    /// - Parameters:
    ///   - sessionID: Session whose ephemeral trust clears.
    ///   - toolName: Tool the caller is revoking, when named.
    public init(sessionID: UUID, toolName: String? = nil) {
        self.sessionID = sessionID
        self.toolName = toolName
    }
}

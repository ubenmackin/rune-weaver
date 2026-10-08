// Rune Weaver Server — Security Policy REST DTOs.
//
// Purpose: carries structured security policy models for `/settings/policy*`
// endpoints, keeping policy payloads decoupled from settings representation.
// Scope: REST request and response bodies only; file I/O, verification, and
// persistence stay with the policy store and routes.
// Architectural role: keeps policy Codable contracts version-tolerant and
// decoupled from the broader settings surface so policy edits never fork settings.

import Foundation
import Vapor

// MARK: - Policy Settings DTOs

/// DTO mirroring NetworkEgressPolicy.
///
/// Only `allowlist_only` and `unrestricted` persist. The retired
/// `deny_by_default` name maps to the fail-closed posture on load and at the
/// REST boundary so older callers keep their intent without storing ambiguity.
/// `localExemptions` is server-owned: the pane renders it display-only and PUT
/// ignores any client-supplied value, deriving the stored set from server-side
/// classification instead. The wire emits camelCase `localExemptions` sorted;
/// snake_case `local_exemptions` decodes tolerantly for older callers but is
/// never emitted.
public struct NetworkEgressPolicyDTO: Content, Sendable, Equatable {
    public let mode: String
    public let allowedDomains: [String]
    public let blockedDomains: [String]
    public let localExemptions: [String]

    public init(mode: String, allowedDomains: [String], blockedDomains: [String], localExemptions: [String] = []) {
        self.mode = mode
        self.allowedDomains = allowedDomains
        self.blockedDomains = blockedDomains
        self.localExemptions = localExemptions
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case allowedDomains = "allowed_domains"
        case blockedDomains = "blocked_domains"
        case localExemptions
        case localExemptionsSnake = "local_exemptions"
    }

    /// Decodes tolerantly so older snake_case payloads still parse: camelCase
    /// wins when both spellings arrive so the two contracts cannot fork.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(String.self, forKey: .mode)
        allowedDomains = try container.decodeIfPresent([String].self, forKey: .allowedDomains) ?? []
        blockedDomains = try container.decodeIfPresent([String].self, forKey: .blockedDomains) ?? []
        let camel = try container.decodeIfPresent([String].self, forKey: .localExemptions)
        let snake = try container.decodeIfPresent([String].self, forKey: .localExemptionsSnake)
        localExemptions = camel ?? snake ?? []
    }

    /// Encodes the canonical wire shape: snake_case network lists plus
    /// camelCase `localExemptions`. The snake spelling decodes but never
    /// encodes so emitted payloads keep one spelling.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encode(allowedDomains, forKey: .allowedDomains)
        try container.encode(blockedDomains, forKey: .blockedDomains)
        try container.encode(localExemptions, forKey: .localExemptions)
    }
}

/// DTO mirroring CredentialBinding.
///
/// One binding pairs one key with its hosts, methods, and path prefixes. The
/// secret rides only when the request host matches, the method matches (or
/// the binding leaves methods empty for Any), and the effective route path
/// matches a prefix (or prefixes stay empty for Any). Prefixes apply to every
/// host in the same binding, so scoping is per-key rather than per-host. An
/// empty host list authorizes nothing and is rejected as unusable.
public struct CredentialBindingDTO: Content, Sendable, Equatable {
    public let allowedHosts: [String]
    public let allowedMethods: [String]
    public let allowedPathPrefixes: [String]

    public init(allowedHosts: [String], allowedMethods: [String], allowedPathPrefixes: [String]) {
        self.allowedHosts = allowedHosts
        self.allowedMethods = allowedMethods
        self.allowedPathPrefixes = allowedPathPrefixes
    }

    private enum CodingKeys: String, CodingKey {
        case allowedHosts = "allowed_hosts"
        case allowedMethods = "allowed_methods"
        case allowedPathPrefixes = "allowed_path_prefixes"
    }
}

/// DTO mirroring SecurityPolicy.
///
/// The policy file owns network plus credentials only. Filesystem and tool
/// sections no longer exist as declarative policy; older files may still
/// carry them but the store ignores those tables on load and never writes
/// them back, so the DTO carries exactly what the file can persist.
public struct SecurityPolicyDTO: Content, Sendable, Equatable {
    public let version: Int
    public let network: NetworkEgressPolicyDTO
    public let credentials: [String: CredentialBindingDTO]

    public init(
        version: Int = 1,
        network: NetworkEgressPolicyDTO,
        credentials: [String: CredentialBindingDTO]
    ) {
        self.version = version
        self.network = network
        self.credentials = credentials
    }
}

/// Local-access report returned by `PUT /settings/policy` and `POST /settings/policy/recheck-local/apply`.
///
/// `granted` names the exemptions added by this write, `removed` names the
/// exemptions dropped by it (derived from allowlist deletions on PUT and from
/// re-classification on re-check apply), and `neverDialable` names added
/// entries that persist name-only with no grant. `GET /settings/policy`
/// sends no report.
public struct PolicyLocalAccessReport: Content, Sendable, Equatable {
    public let granted: [String]
    public let removed: [String]
    public let neverDialable: [String]

    public init(granted: [String] = [], removed: [String] = [], neverDialable: [String] = []) {
        self.granted = granted
        self.removed = removed
        self.neverDialable = neverDialable
    }

    private enum CodingKeys: String, CodingKey {
        case granted
        case removed
        case neverDialable
        case neverDialableSnake = "never_dialable"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        granted = try container.decodeIfPresent([String].self, forKey: .granted) ?? []
        removed = try container.decodeIfPresent([String].self, forKey: .removed) ?? []
        let camel = try container.decodeIfPresent([String].self, forKey: .neverDialable)
        let snake = try container.decodeIfPresent([String].self, forKey: .neverDialableSnake)
        neverDialable = camel ?? snake ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(granted, forKey: .granted)
        try container.encode(removed, forKey: .removed)
        try container.encode(neverDialable, forKey: .neverDialable)
    }
}

/// Response returned by GET /settings/policy.
///
/// Carries the structured policy plus where it came from and its live
/// invariant status. There is no raw TOML on the wire: the dashboard edits
/// the structured shape and the server owns serialization, so the file and
/// the supervisor can never disagree on quoting. Writes apply live through
/// the shared store, so the response never advertises a restart for policy.
/// `localAccess` carries the PUT classification report and stays nil on GET.
public struct PolicyResponse: Content, Sendable, Equatable {
    public let policy: SecurityPolicyDTO
    public let path: String
    public let loadedFromDisk: Bool
    public let violations: [String]
    public let localAccess: PolicyLocalAccessReport?

    public init(
        policy: SecurityPolicyDTO,
        path: String,
        loadedFromDisk: Bool,
        violations: [String],
        localAccess: PolicyLocalAccessReport? = nil
    ) {
        self.policy = policy
        self.path = path
        self.loadedFromDisk = loadedFromDisk
        self.violations = violations
        self.localAccess = localAccess
    }

    private enum CodingKeys: String, CodingKey {
        case policy
        case path
        case loadedFromDisk = "loaded_from_disk"
        case violations
        case localAccess
        case localAccessSnake = "local_access"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        policy = try container.decode(SecurityPolicyDTO.self, forKey: .policy)
        path = try container.decode(String.self, forKey: .path)
        loadedFromDisk = try container.decodeIfPresent(Bool.self, forKey: .loadedFromDisk) ?? false
        violations = try container.decodeIfPresent([String].self, forKey: .violations) ?? []
        let camel = try container.decodeIfPresent(PolicyLocalAccessReport.self, forKey: .localAccess)
        let snake = try container.decodeIfPresent(PolicyLocalAccessReport.self, forKey: .localAccessSnake)
        localAccess = camel ?? snake
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(policy, forKey: .policy)
        try container.encode(path, forKey: .path)
        try container.encode(loadedFromDisk, forKey: .loadedFromDisk)
        try container.encode(violations, forKey: .violations)
        try container.encodeIfPresent(localAccess, forKey: .localAccess)
    }
}

/// Request for PUT /settings/policy.
///
/// Carries the structured candidate the caller wants persisted. The legacy
/// raw-TOML shape is rejected with a 400 naming the field so an old editor
/// learns the new contract instead of silently persisting unvalidated text.
public struct UpdatePolicyRequest: Content, Sendable, Equatable {
    public let policy: SecurityPolicyDTO

    public init(policy: SecurityPolicyDTO) {
        self.policy = policy
    }

    private enum CodingKeys: String, CodingKey {
        case policy
        case rawToml = "raw_toml"
        case rawTomlCamel = "rawToml"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Fail closed on the retired shape: accepting both keys would let an
        // old dashboard keep sending unvalidated text alongside the new shape.
        if container.contains(.rawToml) || container.contains(.rawTomlCamel) {
            throw Abort(
                .badRequest,
                reason: "Invalid policy field 'raw_toml': raw TOML is no longer supported. "
                    + "Send a structured 'policy' object with version, network, and credentials."
            )
        }
        self.policy = try container.decode(SecurityPolicyDTO.self, forKey: .policy)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(policy, forKey: .policy)
    }
}

/// Request for POST /settings/policy/verify.
///
/// Carries a structured candidate for a pure check with no persistence. The
/// retired raw-TOML shape is rejected the same way as PUT so editors get one
/// consistent migration signal.
public struct VerifyPolicyRequest: Content, Sendable, Equatable {
    public let policy: SecurityPolicyDTO

    public init(policy: SecurityPolicyDTO) {
        self.policy = policy
    }

    private enum CodingKeys: String, CodingKey {
        case policy
        case rawToml = "raw_toml"
        case rawTomlCamel = "rawToml"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.rawToml) || container.contains(.rawTomlCamel) {
            throw Abort(
                .badRequest,
                reason: "Invalid policy field 'raw_toml': raw TOML is no longer supported. "
                    + "Send a structured 'policy' object with version, network, and credentials."
            )
        }
        self.policy = try container.decode(SecurityPolicyDTO.self, forKey: .policy)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(policy, forKey: .policy)
    }
}

/// Response returned by POST /settings/policy/verify.
public struct VerifyPolicyResponse: Content, Sendable, Equatable {
    public let valid: Bool
    public let violations: [String]

    public init(valid: Bool, violations: [String]) {
        self.valid = valid
        self.violations = violations
    }
}

/// Request for POST /settings/policy/recheck-local and its apply sibling.
///
/// Carries the structured candidate the caller wants re-checked. Any
/// client-supplied `localExemptions` is ignored (server-owned): the pane
/// renders the field display-only and both endpoints derive the grant set
/// from server-side classification instead.
public struct RecheckLocalExemptionsRequest: Content, Sendable, Equatable {
    public let policy: SecurityPolicyDTO

    public init(policy: SecurityPolicyDTO) {
        self.policy = policy
    }

    private enum CodingKeys: String, CodingKey {
        case policy
        case rawToml = "raw_toml"
        case rawTomlCamel = "rawToml"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Fail closed on the retired shape like PUT and verify so an old
        // editor learns the structured contract instead of sending text.
        if container.contains(.rawToml) || container.contains(.rawTomlCamel) {
            throw Abort(
                .badRequest,
                reason: "Invalid policy field 'raw_toml': raw TOML is no longer supported. "
                    + "Send a structured 'policy' object with version, network, and credentials."
            )
        }
        self.policy = try container.decode(SecurityPolicyDTO.self, forKey: .policy)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(policy, forKey: .policy)
    }
}

/// Preview diff returned by POST /settings/policy/recheck-local.
///
/// `added` names grants the apply would create, `removed` names grants it
/// would drop, `unchanged` names grants it would keep, and `unresolved`
/// names entries that could not be proven without aborting. Every list is
/// sorted so the pane renders a stable diff. Preview never writes.
public struct RecheckLocalExemptionsResponse: Content, Sendable, Equatable {
    public let added: [String]
    public let removed: [String]
    public let unchanged: [String]
    public let unresolved: [String]

    public init(added: [String] = [], removed: [String] = [], unchanged: [String] = [], unresolved: [String] = []) {
        self.added = added
        self.removed = removed
        self.unchanged = unchanged
        self.unresolved = unresolved
    }
}

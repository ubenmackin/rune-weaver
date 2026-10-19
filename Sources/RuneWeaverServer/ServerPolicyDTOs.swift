// Rune Weaver Server — Security Policy REST DTOs.

import Foundation
import Vapor

// MARK: - Policy Settings DTOs

/// DTO mirroring NetworkEgressPolicy. Only `allowlist_only` and `unrestricted` persist.
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
        case allowedDomains
        case allowedDomainsSnake = "allowed_domains"
        case blockedDomains
        case blockedDomainsSnake = "blocked_domains"
        case localExemptions
        case localExemptionsSnake = "local_exemptions"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(String.self, forKey: .mode)
        // Camel wins when both spellings arrive; absent keys stay empty
        // so older drafts never wipe the candidate silently.
        let camelAllowed = try container.decodeIfPresent([String].self, forKey: .allowedDomains)
        let snakeAllowed = try container.decodeIfPresent([String].self, forKey: .allowedDomainsSnake)
        allowedDomains = camelAllowed ?? snakeAllowed ?? []
        let camelBlocked = try container.decodeIfPresent([String].self, forKey: .blockedDomains)
        let snakeBlocked = try container.decodeIfPresent([String].self, forKey: .blockedDomainsSnake)
        blockedDomains = camelBlocked ?? snakeBlocked ?? []
        let camelExemptions = try container.decodeIfPresent([String].self, forKey: .localExemptions)
        let snakeExemptions = try container.decodeIfPresent([String].self, forKey: .localExemptionsSnake)
        localExemptions = camelExemptions ?? snakeExemptions ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encode(allowedDomains, forKey: .allowedDomains)
        try container.encode(blockedDomains, forKey: .blockedDomains)
        try container.encode(localExemptions, forKey: .localExemptions)
    }
}

/// DTO mirroring CredentialBinding.
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
        case allowedHosts
        case allowedHostsSnake = "allowed_hosts"
        case allowedMethods
        case allowedMethodsSnake = "allowed_methods"
        case allowedPathPrefixes
        case allowedPathPrefixesSnake = "allowed_path_prefixes"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Camel wins when both spellings arrive; absent keys stay empty
        // so older drafts never wipe the candidate silently.
        let camelHosts = try container.decodeIfPresent([String].self, forKey: .allowedHosts)
        let snakeHosts = try container.decodeIfPresent([String].self, forKey: .allowedHostsSnake)
        allowedHosts = camelHosts ?? snakeHosts ?? []
        let camelMethods = try container.decodeIfPresent([String].self, forKey: .allowedMethods)
        let snakeMethods = try container.decodeIfPresent([String].self, forKey: .allowedMethodsSnake)
        allowedMethods = camelMethods ?? snakeMethods ?? []
        let camelPrefixes = try container.decodeIfPresent([String].self, forKey: .allowedPathPrefixes)
        let snakePrefixes = try container.decodeIfPresent([String].self, forKey: .allowedPathPrefixesSnake)
        allowedPathPrefixes = camelPrefixes ?? snakePrefixes ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(allowedHosts, forKey: .allowedHosts)
        try container.encode(allowedMethods, forKey: .allowedMethods)
        try container.encode(allowedPathPrefixes, forKey: .allowedPathPrefixes)
    }
}

/// DTO mirroring SecurityPolicy. The policy file owns network plus credentials only.
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

/// Local-access report returned by `PUT /settings/policy` and `POST
/// /settings/policy/recheck-local/apply`.
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
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        granted = try container.decodeIfPresent([String].self, forKey: .granted) ?? []
        removed = try container.decodeIfPresent([String].self, forKey: .removed) ?? []
        neverDialable = try container.decodeIfPresent([String].self, forKey: .neverDialable) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(granted, forKey: .granted)
        try container.encode(removed, forKey: .removed)
        try container.encode(neverDialable, forKey: .neverDialable)
    }
}

/// Response returned by GET /settings/policy. Carries the structured policy plus where it came from
/// and its live invariant status.
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
        case loadedFromDisk
        case violations
        case localAccess
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        policy = try container.decode(SecurityPolicyDTO.self, forKey: .policy)
        path = try container.decode(String.self, forKey: .path)
        loadedFromDisk = try container.decodeIfPresent(Bool.self, forKey: .loadedFromDisk) ?? false
        violations = try container.decodeIfPresent([String].self, forKey: .violations) ?? []
        localAccess = try container.decodeIfPresent(PolicyLocalAccessReport.self, forKey: .localAccess)
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

/// Preview diff returned by POST /settings/policy/recheck-local. Preview never writes.
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

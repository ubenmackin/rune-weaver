// Rune Weaver Core — Declarative security policy types for policy.toml.

import Foundation

// MARK: - Root Policy

/// Root security policy mirroring `~/.runeweaver/policy.toml`. The policy file is separate from
/// `config.toml` so security boundaries are independently versionable and auditable.
public struct SecurityPolicy: Sendable, Equatable {
    /// Schema version for forward compatibility. Current: 1.
    public var version: Int

    /// Network egress boundaries.
    public var network: NetworkEgressPolicy

    /// Per-secret credential-to-destination bindings.
    public var credentials: [String: CredentialBinding]

    /// Creates a security policy.
    public init(
        version: Int = 1,
        network: NetworkEgressPolicy = .safeDefault,
        credentials: [String: CredentialBinding] = [:]
    ) {
        self.version = version
        self.network = network
        self.credentials = credentials
    }

    /// Immutable factory-safe posture: allowlist-only network with no
    /// credential bindings, so a missing file boots with nothing reachable
    /// and no secret routable.
    public static let safeDefault = SecurityPolicy()

    /// Returns a copy of the policy with an additional allowed domain. Blank input is a no-op
    /// returning the policy unchanged: callers that must fail closed on empty (triage handlers)
    /// validate before calling.
    public func appendingAllowedDomain(_ domain: String) -> SecurityPolicy {
        guard let canonical = Self.canonicalDomainEntry(domain) else { return self }
        var updated = self
        var allowed = updated.network.allowedDomains
        allowed.insert(canonical)
        updated.network = NetworkEgressPolicy(
            mode: updated.network.mode,
            allowedDomains: allowed,
            blockedDomains: updated.network.blockedDomains,
            localExemptions: updated.network.localExemptions
        )
        return updated
    }

    /// Returns a copy of the policy with an additional blocked domain. `localExemptions` rides
    /// through untouched, so a domain append never widens or narrows an exemption grant.
    public func appendingBlockedDomain(_ domain: String) -> SecurityPolicy {
        guard let canonical = Self.canonicalDomainEntry(domain) else { return self }
        var updated = self
        var blocked = updated.network.blockedDomains
        blocked.insert(canonical)
        updated.network = NetworkEgressPolicy(
            mode: updated.network.mode,
            allowedDomains: updated.network.allowedDomains,
            blockedDomains: blocked,
            localExemptions: updated.network.localExemptions
        )
        return updated
    }

    /// Canonicalizes one caller-supplied domain for storage. Nil for blank input so appenders no-op
    /// instead of persisting an entry that could only match an empty host.
    private static func canonicalDomainEntry(_ domain: String) -> String? {
        let canonical = NetworkEgressPolicy.canonicalEntry(domain)
        guard !canonical.isEmpty, canonical != "*." else { return nil }
        return canonical
    }
}

// MARK: - Network Egress

/// Outbound network mode for the egress supervisor.
public enum EgressMode: String, Sendable, Equatable, CaseIterable {
    /// Only destinations in `allowedDomains` may be dialed.
    case allowlistOnly = "allowlist_only"
    /// No domain restrictions (SSRF guard and credential bindings still apply).
    case unrestricted
}

/// `[network]` — outbound network egress boundaries. The SSRF guard (`ApiSSRFGuard`) still blocks
/// metadata, link-local, and RFC 1918 ranges regardless of domain allowlist settings.
public struct NetworkEgressPolicy: Sendable, Equatable {
    /// Outbound network posture.
    public var mode: EgressMode
    /// Domains the agent may contact when `mode` is `.allowlistOnly`.
    /// Includes exact matches and wildcard prefixes (e.g. `*.github.com`).
    public var allowedDomains: Set<String>
    /// Domains explicitly blocked regardless of mode. Evaluated before
    /// the allowlist so a blocked domain is never reachable.
    public var blockedDomains: Set<String>
    /// Owner-declared local-network exemptions from `[network].local_exemptions`. Entries are
    /// shape-checked plus classified before storage; comparison always canonicalizes through
    /// `canonicalEntry(_:)`.
    public var localExemptions: Set<String>

    /// Creates a network egress policy.
    public init(
        mode: EgressMode = .allowlistOnly,
        allowedDomains: Set<String> = ["127.0.0.1"],
        blockedDomains: Set<String> = ["169.254.169.254"],
        localExemptions: Set<String> = []
    ) {
        self.mode = mode
        self.allowedDomains = allowedDomains
        self.blockedDomains = blockedDomains
        self.localExemptions = localExemptions
    }

    /// Factory safe default: allowlist-only with only loopback permitted.
    public static let safeDefault = NetworkEgressPolicy()

    /// Granular status of a host under this network egress policy.
    public enum HostStatus: Sendable, Equatable {
        /// Permitted by allowlist or unrestricted mode.
        case allowed
        /// Explicitly blocked by blocklist.
        case explicitlyBlocked(String)
        /// Not permitted by allowlist (unlisted).
        case unlisted(String)
    }

    /// Evaluates the granular status of a host.
    public func hostStatus(for host: String) -> HostStatus {
        let canonicalHost = SensitiveAddressNormalization.normalizedHost(host)

        // 1. Blocked domains always refuse.
        for blocked in blockedDomains {
            let canonicalBlocked = Self.canonicalEntry(blocked)
            guard canonicalBlocked.hasPrefix("*.") else {
                if canonicalBlocked == canonicalHost {
                    return .explicitlyBlocked("Host '\(host)' is explicitly blocked by security policy.")
                }
                continue
            }
            let suffix = String(canonicalBlocked.dropFirst(1))
            if canonicalHost.hasSuffix(suffix) || canonicalHost == String(canonicalBlocked.dropFirst(2)) {
                return .explicitlyBlocked("Host '\(host)' matches blocked pattern '\(blocked)' in security policy.")
            }
        }

        // 2. Unrestricted mode allows all non-blocked.
        if mode == .unrestricted {
            return .allowed
        }

        // 3. Allowlist check.
        for allowed in allowedDomains {
            let canonicalAllowed = Self.canonicalEntry(allowed)
            guard canonicalAllowed.hasPrefix("*.") else {
                if canonicalAllowed == canonicalHost {
                    return .allowed
                }
                continue
            }
            let suffix = String(canonicalAllowed.dropFirst(1))
            if canonicalHost.hasSuffix(suffix) || canonicalHost == String(canonicalAllowed.dropFirst(2)) {
                return .allowed
            }
        }

        return .unlisted("Host '\(host)' is not in the allowed domains list. Add it to [network].allowed_domains in policy.toml.")
    }

    /// Whether a given host is permitted under this policy.
    public func denyReason(for host: String) -> String? {
        switch hostStatus(for: host) {
        case .allowed:
            nil
        case let .explicitlyBlocked(reason), let .unlisted(reason):
            reason
        }
    }

    /// Canonicalizes one declared domain entry for comparison. Single owner for domain
    /// canonicalization: appenders reuse this instead of keeping a second copy, so storage and
    /// matching cannot drift on the `*.` edge.
    public static func canonicalEntry(_ entry: String) -> String {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("*.") else {
            return SensitiveAddressNormalization.normalizedHost(trimmed)
        }
        return "*." + SensitiveAddressNormalization.normalizedHost(String(trimmed.dropFirst(2)))
    }
}

// MARK: - Effective Request Path

/// Resolves the route path a request actually reaches, for binding comparison.
public enum EffectiveRequestPath: Sendable {
    /// Outcome of resolving one request destination.
    public enum Resolution: Sendable, Equatable {
        /// Effective path (`/v1/data`) after decoding and dot-segment removal.
        case effective(String)
        /// Ambiguous or malformed spelling that must be refused.
        case rejected(String)
    }

    /// Percent-decoding layers peeled before an over-encoded path is refused.
    private static let maximumDecodeLayers = 4

    /// Resolves a URL destination from its raw, still-encoded components.
    public static func resolve(for url: URL) -> Resolution {
        resolve(host: url.host(percentEncoded: true) ?? "", rawPath: url.path(percentEncoded: true))
    }

    /// Resolves a raw host plus raw path pair.
    public static func resolve(host: String, rawPath: String) -> Resolution {
        if let hostReason = encodedHostReason(host) {
            return .rejected("host '\(host)' \(hostReason)")
        }
        return resolve(rawPath: rawPath)
    }

    /// Resolves one raw path to the effective route path.
    public static func resolve(rawPath: String) -> Resolution {
        var current = rawPath.isEmpty ? "/" : rawPath
        var layers = 0
        while true {
            if let reason = encodedSpellingReason(current) {
                return .rejected("path '\(rawPath)' \(reason)")
            }
            guard let decoded = current.removingPercentEncoding else {
                return .rejected("path '\(rawPath)' carries malformed percent-encoding")
            }
            if decoded == current {
                break
            }
            layers += 1
            guard layers <= maximumDecodeLayers else {
                return .rejected("path '\(rawPath)' nests percent-encoding too deeply to resolve")
            }
            current = decoded
        }
        // Fully decoded now, so RFC 3986 removal sees the same segments an
        // origin server routes over.
        let effective = removeDotSegments(current)
        return .effective(effective.isEmpty ? "/" : effective)
    }

    /// RFC 3986 §5.2.4 `remove_dot_segments` over an already-decoded path.
    static func removeDotSegments(_ path: String) -> String {
        var input = path
        var output = ""
        while !input.isEmpty {
            if input.hasPrefix("../") {
                input.removeFirst(3)
            } else if input.hasPrefix("./") {
                input.removeFirst(2)
            } else if input.hasPrefix("/./") {
                input.removeFirst(2)
            } else if input == "/." {
                input = "/"
            } else if input.hasPrefix("/../") {
                input.removeFirst(3)
                removeLastOutputSegment(&output)
            } else if input == "/.." {
                input = "/"
                removeLastOutputSegment(&output)
            } else if input == "." || input == ".." {
                input = ""
            } else {
                // Move one segment — the leading slash plus everything up to
                // (not including) the next slash — from input to output.
                let nextSlash = input.dropFirst().firstIndex(of: "/")
                let segmentEnd = nextSlash ?? input.endIndex
                output += input[..<segmentEnd]
                input = String(input[segmentEnd...])
            }
        }
        return output
    }

    /// Reason a raw path is ambiguous: an encoded or raw separator, or a dot
    /// segment spelled as an escape.
    private static func encodedSpellingReason(_ raw: String) -> String? {
        let lowered = raw.lowercased()
        if lowered.contains("%2f") || lowered.contains("%5c") || raw.contains("\\") {
            return "spells a separator as an escape, so its routed destination is ambiguous"
        }
        for segment in raw.split(separator: "/", omittingEmptySubsequences: true) where segment.contains("%") {
            let decoded = segment.removingPercentEncoding ?? String(segment)
            if decoded == "." || decoded == ".." {
                return "spells a dot segment as an escape, so its routed destination is ambiguous"
            }
        }
        return nil
    }

    /// Reason a raw host is ambiguous: an encoded separator or encoded dot.
    private static func encodedHostReason(_ raw: String) -> String? {
        let lowered = raw.lowercased()
        if lowered.contains("%2f") || lowered.contains("%5c") {
            return "spells a separator as an escape"
        }
        if lowered.contains("%2e") {
            return "spells a dot as an escape"
        }
        return nil
    }

    /// Removes the final output segment and its preceding slash, per RFC 3986.
    private static func removeLastOutputSegment(_ output: inout String) {
        while let last = output.last, last != "/" {
            output.removeLast()
        }
        if output.hasSuffix("/") {
            output.removeLast()
        }
    }
}

// MARK: - Credential Binding

/// Binds a secret surrogate (`rwsecret:<key>`) to authorized destinations. A mismatch fails closed
/// — the secret is never loaded into memory.
public struct CredentialBinding: Sendable, Equatable {
    /// Hosts this credential may be sent to (e.g. `["api.github.com"]`).
    /// A single leading `*.` entry (`*.example.com`) also authorizes the
    /// base domain and its subdomains; any other star shape authorizes nothing.
    public var allowedHosts: Set<String>
    /// HTTP methods permitted (e.g. `["GET", "POST"]`). Empty means all.
    public var allowedMethods: Set<String>
    /// URL path prefixes permitted (e.g. `["/repos/", "/user"]`). Empty means all.
    public var allowedPathPrefixes: [String]

    /// Creates a credential binding.
    public init(
        allowedHosts: Set<String> = [],
        allowedMethods: Set<String> = [],
        allowedPathPrefixes: [String] = []
    ) {
        self.allowedHosts = allowedHosts
        self.allowedMethods = allowedMethods
        self.allowedPathPrefixes = allowedPathPrefixes
    }

    /// Whether a request to the given destination is authorized for this credential.
    public func denyReason(key: String, host: String, method: String, path: String) -> String? {
        let canonicalHost = SensitiveAddressNormalization.normalizedHost(host)
        let upperedMethod = method.uppercased()

        // Resolve the effective destination before any authorization decision.
        let effectivePath: String
        switch EffectiveRequestPath.resolve(host: host, rawPath: path) {
        case let .effective(resolved):
            effectivePath = resolved
        case let .rejected(reason):
            return "Credential '\(key)' is not authorized for '\(host)\(path)': \(reason)."
        }

        // Host check (required — empty allowedHosts means no destination is authorized)
        guard !allowedHosts.isEmpty else {
            return "Credential '\(key)' has no allowed hosts configured. Add hosts to [credentials.\(key)].allowed_hosts in policy.toml."
        }
        let hostAllowed = allowedHosts.contains(where: { Self.authorizes(canonicalHost: canonicalHost, pattern: $0) })
        guard hostAllowed else {
            return "Credential '\(key)' is not authorized for host '\(host)'. Allowed: \(allowedHosts.sorted().joined(separator: ", "))."
        }

        // Method check (empty means all methods allowed)
        if !allowedMethods.isEmpty {
            let methodAllowed = allowedMethods.contains(where: { $0.uppercased() == upperedMethod })
            guard methodAllowed else {
                let allowed = allowedMethods.sorted().joined(separator: ", ")
                return "Credential '\(key)' is not authorized for method '\(method)' on host '\(host)'. Allowed: \(allowed)."
            }
        }

        // Path prefix check (empty means all paths allowed)
        if !allowedPathPrefixes.isEmpty {
            let pathAllowed = allowedPathPrefixes.contains(where: { effectivePath.hasPrefix($0) })
            guard pathAllowed else {
                let allowed = allowedPathPrefixes.joined(separator: ", ")
                return "Credential '\(key)' is not authorized for path '\(effectivePath)' on host '\(host)'. Allowed prefixes: \(allowed)."
            }
        }

        return nil
    }

    /// Whether one `allowed_hosts` entry authorizes a canonical destination. A leading `*.` entry
    /// authorizes the base domain plus every subdomain, matching the invariant verifier's
    /// confinement semantics.
    private static func authorizes(canonicalHost: String, pattern: String) -> Bool {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        switch AllowedOriginPattern.classifyWildcard(trimmed.lowercased()) {
        case .none:
            return SensitiveAddressNormalization.normalizedHost(trimmed) == canonicalHost
        case .leading:
            let base = SensitiveAddressNormalization.normalizedHost(String(trimmed.dropFirst(2)))
            guard !base.isEmpty else { return false }
            return canonicalHost == base || canonicalHost.hasSuffix("." + base)
        case .trailing, .invalidShape, .invalidSuffix, .invalidStem:
            return false
        }
    }
}

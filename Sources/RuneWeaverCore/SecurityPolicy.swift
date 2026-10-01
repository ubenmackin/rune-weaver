// Rune Weaver Core — Declarative security policy types for policy.toml.
//
// Decouples security boundaries (network egress rules plus per-secret
// credential bindings) from application code into a versionable, auditable
// schema stored at `~/.runeweaver/policy.toml`. The file owns network plus
// credentials only: legacy filesystem and tool tables are ignored on load and
// never serialized back, so one store stays authoritative for egress and
// secret routing and a resaved file sheds retired sections.
//
// The two owned invariants are credential confinement plus rule-shadow
// prevention: bindings refuse forbidden, loopback, link-local, and private
// targets except through a single leading `*.` edge whose base is checked
// like an exact host, and a blocked domain always refuses even when an allow
// entry would otherwise cover it. `EgressMode` lists exactly `allowlist_only`
// plus `unrestricted`; a legacy `deny_by_default` string maps to
// `allowlist_only` at the parse boundary, preserving its fail-closed intent.
//
// Every type is `Sendable` and `Equatable` to match the repo-wide concurrency
// standard. The dashboard edits the structured shape while the server owns
// serialization with a reparse round-trip proof, so the bytes on disk always
// reload to the verified object and quoting edges cannot split file from
// supervisor. Writes apply live through the shared `PolicyStore` with no
// restart plus no watcher.
//
// The file also carries `EffectiveRequestPath`, the shared resolver that turns
// a raw request destination into the route path a credential binding
// authorizes, so every enforcement point compares what an origin server
// actually routes. One binding pairs one key with hosts plus methods plus
// path prefixes: empty hosts authorizes nothing while empty methods or
// prefixes authorize any value.

import Foundation

// MARK: - Root Policy

/// Root security policy mirroring `~/.runeweaver/policy.toml`.
///
/// The policy file is separate from `config.toml` so security boundaries
/// are independently versionable and auditable. A missing or malformed
/// policy file resolves to `SecurityPolicy.safeDefault` — the immutable
/// factory posture that denies by default.
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

    /// Returns a copy of the policy with an additional allowed domain.
    ///
    /// Trims surrounding whitespace and stores the canonical comparison form
    /// so `"  Evil.COM  "` lands exactly as the matcher evaluates it. Blank
    /// input is a no-op returning the policy unchanged: callers that must
    /// fail closed on empty (triage handlers) validate before calling.
    public func appendingAllowedDomain(_ domain: String) -> SecurityPolicy {
        guard let canonical = Self.canonicalDomainEntry(domain) else { return self }
        var updated = self
        var allowed = updated.network.allowedDomains
        allowed.insert(canonical)
        updated.network = NetworkEgressPolicy(
            mode: updated.network.mode,
            allowedDomains: allowed,
            blockedDomains: updated.network.blockedDomains
        )
        return updated
    }

    /// Returns a copy of the policy with an additional blocked domain.
    ///
    /// Trims surrounding whitespace and stores the canonical comparison form;
    /// blank input is a no-op returning the policy unchanged.
    public func appendingBlockedDomain(_ domain: String) -> SecurityPolicy {
        guard let canonical = Self.canonicalDomainEntry(domain) else { return self }
        var updated = self
        var blocked = updated.network.blockedDomains
        blocked.insert(canonical)
        updated.network = NetworkEgressPolicy(
            mode: updated.network.mode,
            allowedDomains: updated.network.allowedDomains,
            blockedDomains: blocked
        )
        return updated
    }

    /// Canonicalizes one caller-supplied domain for storage.
    ///
    /// Single-sourced through `NetworkEgressPolicy.canonicalEntry` so stored
    /// values compare equal to what `hostStatus(for:)` evaluates: the `*.`
    /// edge passes through with a normalized base while every other entry
    /// normalizes whole. Nil for blank input so appenders no-op instead of
    /// persisting an entry that could only match an empty host.
    private static func canonicalDomainEntry(_ domain: String) -> String? {
        let canonical = NetworkEgressPolicy.canonicalEntry(domain)
        guard !canonical.isEmpty, canonical != "*." else { return nil }
        return canonical
    }
}

// MARK: - Network Egress

/// Outbound network mode for the egress supervisor.
///
/// Exactly two postures exist. A stored `deny_by_default` string from an
/// older file no longer constructs a distinct mode and falls back to
/// `allowlistOnly` at the parse boundary, preserving its fail-closed intent.
public enum EgressMode: String, Sendable, Equatable, CaseIterable {
    /// Only destinations in `allowedDomains` may be dialed.
    case allowlistOnly = "allowlist_only"
    /// No domain restrictions (SSRF guard and credential bindings still apply).
    case unrestricted
}

/// `[network]` — outbound network egress boundaries.
///
/// Controls which external hosts the agent may contact. The SSRF guard
/// (`ApiSSRFGuard`) still blocks metadata, link-local, and RFC 1918 ranges
/// regardless of domain allowlist settings.
public struct NetworkEgressPolicy: Sendable, Equatable {
    /// Outbound network posture.
    public var mode: EgressMode
    /// Domains the agent may contact when `mode` is `.allowlistOnly`.
    /// Includes exact matches and wildcard prefixes (e.g. `*.github.com`).
    public var allowedDomains: Set<String>
    /// Domains explicitly blocked regardless of mode. Evaluated before
    /// the allowlist so a blocked domain is never reachable.
    public var blockedDomains: Set<String>

    /// Creates a network egress policy.
    public init(
        mode: EgressMode = .allowlistOnly,
        allowedDomains: Set<String> = ["127.0.0.1"],
        blockedDomains: Set<String> = ["169.254.169.254"]
    ) {
        self.mode = mode
        self.allowedDomains = allowedDomains
        self.blockedDomains = blockedDomains
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
    ///
    /// Evaluation order:
    /// 1. Blocked domains always refuse.
    /// 2. Unrestricted mode allows all non-blocked hosts.
    /// 3. Allowlist modes check exact match and wildcard suffix match.
    /// - Parameter host: Raw host component to evaluate.
    /// - Returns: `HostStatus` indicating allowed, explicitly blocked, or unlisted.
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
    ///
    /// Delegates to `hostStatus(for:)`.
    /// - Parameter host: Raw host component (name or address literal) to evaluate.
    /// - Returns: `nil` when allowed, or a human-readable refusal reason.
    public func denyReason(for host: String) -> String? {
        switch hostStatus(for: host) {
        case .allowed:
            nil
        case let .explicitlyBlocked(reason), let .unlisted(reason):
            reason
        }
    }

    /// Canonicalizes one declared domain entry for comparison.
    ///
    /// Single owner for domain canonicalization: appenders reuse this instead
    /// of keeping a second copy, so storage and matching cannot drift on the
    /// `*.` edge. Only the suffix of a `*.` entry names a host, so the
    /// wildcard edge passes through untouched; every other entry reuses the
    /// same normalizer the SSRF guard trusts. A malformed entry that
    /// normalizes to nothing can only equal an empty host, so it fails closed
    /// instead of matching broadly.
    static func canonicalEntry(_ entry: String) -> String {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("*.") else {
            return SensitiveAddressNormalization.normalizedHost(trimmed)
        }
        return "*." + SensitiveAddressNormalization.normalizedHost(String(trimmed.dropFirst(2)))
    }
}

// MARK: - Effective Request Path

/// Resolves the route path a request actually reaches, for binding comparison.
///
/// Foundation's decoded `URL.path` still carries `..` segments (and erases
/// `%2f`/`%2e` spellings), so a request to `https://host/v1/%2e%2e/admin`
/// reads as starting with `/v1/` while RFC 3986 routing sends it to `/admin`,
/// and the live Keychain value would ride a path the binding never authorized.
/// This resolver percent-decodes the raw path, applies RFC 3986 §5.2.4
/// `remove_dot_segments`, and refuses spellings whose routed destination
/// differs across proxy decoders: encoded path separators (`%2f`, `%5c`, raw
/// backslash) and encoded dot segments (`%2e`, `%2e%2e`, `.%2e`, and nested
/// encodings). One resolver serves every enforcement point — the egress
/// supervisor re-enters it for the initial URL and every redirect hop, because
/// each hop's binding decision flows through `CredentialBinding.denyReason`.
public enum EffectiveRequestPath: Sendable {
    /// Outcome of resolving one request destination.
    public enum Resolution: Sendable, Equatable {
        /// Effective path (`/v1/data`) after decoding and dot-segment removal.
        case effective(String)
        /// Ambiguous or malformed spelling that must be refused.
        case rejected(String)
    }

    /// Percent-decoding layers peeled before an over-encoded path is refused.
    ///
    /// One layer covers plain escaping and two cover double-encoded traversal
    /// (`%252e%252e`); deeper nesting refuses instead of being guessed at, so a
    /// multiply-wrapped separator never reaches the prefix comparison.
    private static let maximumDecodeLayers = 4

    /// Resolves a URL destination from its raw, still-encoded components.
    ///
    /// The raw accessors are deliberate: the decoded `URL.path` has already
    /// erased the escapes this resolver must refuse, and the raw forms are what
    /// the wire request carries.
    /// - Parameter url: Request URL under evaluation.
    /// - Returns: The effective path, or a refusal reason.
    public static func resolve(for url: URL) -> Resolution {
        resolve(host: url.host(percentEncoded: true) ?? "", rawPath: url.path(percentEncoded: true))
    }

    /// Resolves a raw host plus raw path pair.
    ///
    /// A host that spells a separator or dot as an escape is refused before
    /// wildcard suffix matching: resolvers disagree on those bytes, so the
    /// binding fails closed instead of authorizing an ambiguous authority.
    /// - Parameters:
    ///   - host: Raw authority component, escapes intact.
    ///   - rawPath: Raw path as it appears in the request target.
    /// - Returns: The effective path, or a refusal reason.
    public static func resolve(host: String, rawPath: String) -> Resolution {
        if let hostReason = encodedHostReason(host) {
            return .rejected("host '\(host)' \(hostReason)")
        }
        return resolve(rawPath: rawPath)
    }

    /// Resolves one raw path to the effective route path.
    ///
    /// Every decoding layer is checked before it is peeled, so a traversal
    /// wrapped in deeper percent-encoding is refused rather than smuggled
    /// through as an opaque literal segment.
    /// - Parameter rawPath: Raw path as it appears in the request target.
    /// - Returns: The effective path, or a refusal reason.
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
    ///
    /// Literal `.`/`..` segments are safe to normalize because every RFC 3986
    /// origin server removes them the same way; encoded spellings never reach
    /// this step because `resolve` refuses them first.
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

/// Binds a secret surrogate (`rwsecret:<key>`) to authorized destinations.
///
/// When the agent requests `rwsecret:GITHUB_PAT`, the egress supervisor
/// checks that the target URL's host, HTTP method, and path prefix all
/// match this binding before the Keychain is ever accessed. A mismatch
/// fails closed — the secret is never loaded into memory.
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
    ///
    /// Host authorization accepts exact destinations plus a single leading
    /// `*.` edge covering the base domain and any subdomain depth. The
    /// request host and each configured entry canonicalize through the shared
    /// host normalizer so casing, trailing dots, and alternate numeric
    /// spellings agree; malformed star shapes never authorize, so a typo
    /// fails closed instead of silently widening the binding.
    ///
    /// Path authorization compares the effective route path from
    /// `EffectiveRequestPath` — percent-decoded with RFC 3986 dot segments
    /// removed — and refuses encoded separators or encoded dot segments, so a
    /// traversal spelling like `/v1/../admin` can never satisfy a `/v1/`
    /// prefix. The same resolution runs for every redirect hop because the
    /// egress supervisor re-enters this method per hop.
    /// - Parameters:
    ///   - key: Secret key the binding belongs to (used in refusal wording).
    ///   - host: Raw target hostname.
    ///   - method: HTTP method (uppercased).
    ///   - path: Request path, raw or decoded; resolved before comparison.
    /// - Returns: `nil` when authorized, or a human-readable refusal reason.
    public func denyReason(key: String, host: String, method: String, path: String) -> String? {
        let canonicalHost = SensitiveAddressNormalization.normalizedHost(host)
        let upperedMethod = method.uppercased()

        // Resolve the effective destination before any authorization decision.
        // A binding must judge the path the origin server routes, not the raw
        // request text, and an ambiguous escape spelling has to refuse rather
        // than guess; resolving here also covers direct callers that hold an
        // already-decoded `URL.path`.
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

    /// Whether one `allowed_hosts` entry authorizes a canonical destination.
    ///
    /// A leading `*.` entry authorizes the base domain plus every subdomain,
    /// matching the invariant verifier's confinement semantics. Every other
    /// star shape (bare `*`, trailing `.*`, glob syntax, port qualifiers) is
    /// meaningless for a host binding and refuses.
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

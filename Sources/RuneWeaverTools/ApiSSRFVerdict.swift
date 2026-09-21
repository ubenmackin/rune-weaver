// Rune Weaver Tools — SSRF pre-DNS verdict and resolved-address vetting.
//
// Purpose: literal-only refusal stage plus fail-closed vetting of resolved
// addresses, so hostnames that cannot prove every address dialable never dial.
// Scope: pure parsing and range checks over the literal host plus the shared
// resolved-range table; DNS resolution and the bounded pool stay with the gate
// in `ApiSSRFGuard`. Architectural role: single-source verdict layer backing
// `ApiSSRFGuard`; the sync engine and the async inline stage share this stage
// so literal and resolved decisions cannot diverge between callers.

import Foundation
import RuneWeaverCore

extension ApiSSRFGuard {
    /// Non-DNS verdict shared by the sync engine and the async inline stage.
    /// Pure parsing and range checks only, so awaiting tasks can run it
    /// without hopping queues; anything needing the resolver returns
    /// `needsDNS` for the caller to vet on the appropriate path.
    enum SSRFPreDNSOutcome {
        case denied(String)
        case allowed
        case needsDNS(host: String)
    }

    /// Literal-only stage of the refusal engine; never touches the resolver.
    /// - Parameters:
    ///   - rawURL: Candidate URL.
    ///   - origins: Precomputed `host:port` exemptions that may be dialed.
    ///   - hasLLMOrigins: Whether LLM endpoints contribute exemptions, for honest wording.
    /// - Returns: Denial, allowance, or the hostname needing DNS vetting.
    static func preDNSOutcome(
        for rawURL: String,
        allowlistedOrigins origins: Set<String>,
        hasLLMOrigins: Bool
    ) -> SSRFPreDNSOutcome {
        guard let trimmed = NormalizedText.value(rawURL) else {
            return .denied("Empty URL: api.request needs an absolute http(s) URL.")
        }
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("file:") {
            return .denied("SSRF denied: file scheme is not allowed (\(trimmed)).")
        }
        guard WebURLSafety.isSafeUrl(trimmed) else {
            return .denied("Unsafe URL: api.request only dereferences absolute http(s) URLs (\(trimmed)).")
        }
        guard let url = URL(string: trimmed), let host = url.host, !host.isEmpty else {
            return .denied("Unsafe URL: api.request only dereferences absolute http(s) URLs (\(trimmed)).")
        }
        if isMetadataHost(host) {
            return .denied("SSRF denied: refusing metadata host '\(host)'.")
        }
        if isLinkLocalIPv4(host) {
            return .denied("SSRF denied: refusing link-local address '\(host)' (169.254.0.0/16).")
        }
        if isLinkLocalIPv6(host) {
            return .denied("SSRF denied: refusing link-local address '\(host)' (fe80::/10).")
        }
        if isLoopbackHost(host) {
            if isOriginAllowed(url: url, origins: origins) {
                return .allowed
            }
            // Exemption wording follows the configured origins so fetch-only
            // callers (no LLM origins) never promise an LLM exemption they do
            // not honor; the range decision stays single-source above.
            if hasLLMOrigins {
                return .denied("SSRF denied: refusing loopback host '\(host)' except configured searxng_url and LLM endpoints.")
            }
            return .denied("SSRF denied: refusing loopback host '\(host)' except configured searxng_url.")
        }
        let canonical = normalizedHost(host)
        if let value = ipv4Value(canonical), isSensitiveIPv4Value(value) {
            if isOriginAllowed(url: url, origins: origins) {
                return .allowed
            }
            return .denied("SSRF denied: refusing private or reserved IPv4 host '\(host)'.")
        }
        if isSensitiveIPv6Host(canonical) {
            if isOriginAllowed(url: url, origins: origins) {
                return .allowed
            }
            return .denied("SSRF denied: refusing private or loopback IPv6 host '\(host)'.")
        }
        if isIPAddressLiteral(host) {
            // Literals carry no resolver alias to rebind, so the allowlist verdict above
            // plus the public-literal default below settle them without DNS.
            return .allowed
        }
        if isOriginAllowed(url: url, origins: origins) {
            // An allowlisted name can still rebind to metadata or link-local between
            // check and dial, so even allowlisted DNS names must prove every resolved
            // address stays outside never-allowlisted space before dialing.
            return .needsDNS(host: host)
        }
        // Every remaining hostname must prove its addresses via the resolver: local DNS can
        // rebind reserved names to loopback or private ranges, so absence of proof fails closed.
        return .needsDNS(host: host)
    }

    /// Whether a host is an IP literal rather than a name needing DNS.
    /// Dotted IPv4-embedded IPv6 forms count only on a proven prefix so an unverified prefix
    /// cannot pass as the tail's public literal; pure IPv4 spellings and parsed hextet literals
    /// vet fully from their text while anything else must prove its addresses via the resolver.
    /// - Parameter host: URL host to classify.
    /// - Returns: True for parsed IP literals, false for DNS names.
    static func isIPAddressLiteral(_ host: String) -> Bool {
        let cleaned = ApiSSRFOrigin.cleanedHostBase(host)
        guard !cleaned.isEmpty else { return false }
        // Dotted-colon forms decide strictly here: a valid tail with an unproven prefix stays a
        // DNS name and fails closed instead of bypassing vetting as a public literal.
        if cleaned.contains(":"), cleaned.contains(".") {
            return ApiIPv4Parsing.isValidDottedIPv6Literal(cleaned)
        }
        if ApiIPv4Parsing.canonicalIPv4Octets(cleaned) != nil {
            return true
        }
        if cleaned.contains(":"), ApiIPv4Parsing.ipv6Hextets(cleaned) != nil {
            return true
        }
        return false
    }

    /// Fail-closed refusal for a hostname without a verified address.
    /// Returned for empty resolutions, wedged-resolver timeouts, and
    /// cancellations so absence of evidence never becomes permission to dial.
    /// - Parameter host: Hostname that could not be verified.
    /// - Returns: Refusal reason to surface to the caller.
    static func unverifiedDenial(for host: String) -> String {
        "SSRF denied: hostname '\(host)' could not be verified (DNS unavailable; fail closed)."
    }

    /// Reports whether a URL's origin or host matches any allowlisted origin or pattern.
    /// Exact `host:port` compares through the normalized origin key while bare hosts
    /// compare through the dedicated host-pattern matcher, so callers can tell why a
    /// full-URL entry alone never authorizes a host.
    static func isOriginAllowed(url: URL, origins: Set<String>) -> Bool {
        guard !origins.isEmpty else { return false }
        if let key = originKey(for: url), origins.contains(key.lowercased()) {
            return true
        }
        guard let rawHost = url.host else { return false }
        return isHostAllowed(rawHost, origins: origins)
    }

    /// Reports whether a host or IP string matches any allowlisted origin or pattern.
    /// Only DNS-host semantics apply here: exact hosts, `*.suffix` domain wildcards,
    /// and `prefix.*` IP wildcards. File-path glob characters (`?`, `[...]`, `**`)
    /// and the universal `*` never match, so a forged exemption set cannot silently
    /// broaden; exact `host:port` stays with the origin-key check in `isOriginAllowed`.
    static func isHostAllowed(_ host: String, origins: Set<String>) -> Bool {
        guard !origins.isEmpty else { return false }
        let cleanedHost = ApiSSRFOrigin.cleanedHostBase(host)
        guard !cleanedHost.isEmpty else { return false }
        let loweredHost = cleanedHost.lowercased()
        // Canonical form collapses resolver-accepted IP spellings so hex, octal, and
        // short aliases compare against the same allowlisted address.
        let normalizedHost = ApiSSRFOrigin.normalizedHost(host).lowercased()
        if origins.contains(loweredHost) || origins.contains(normalizedHost) {
            return true
        }
        for pattern in origins {
            let loweredPattern = pattern.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !loweredPattern.isEmpty else { continue }
            // Universal shapes never authorize: validation rejects them, and the
            // matcher stays closed even when a forged set carries one. The closed
            // set is shared with validation so the two cannot drift.
            if AllowedOriginPattern.isUniversalWildcard(loweredPattern) {
                continue
            }
            // Full URLs, paths, queries, and fragments are not host patterns: the
            // allowlist builder stores their host and key variants separately, so the
            // raw entry itself never authorizes a host here.
            if loweredPattern.contains("://") || loweredPattern.contains("/") || loweredPattern.contains("?")
                || loweredPattern.contains("#") || loweredPattern.contains(" ")
            {
                continue
            }
            if loweredPattern.contains("\u{00}") || loweredPattern.unicodeScalars.contains(where: {
                $0.value < 0x20 || $0.value == 0x7F
            }) {
                continue
            }
            // Wildcard edges share validation with config so only a single
            // leading `*.` or trailing `.*` can authorize; the shape verdict
            // already rejects file-glob syntax, malformed edges, and
            // port-qualified wildcards, which stay denied here instead of
            // persisting as entries that could never match a port-less host.
            switch AllowedOriginPattern.classifyWildcard(loweredPattern) {
            case .leading:
                let suffix = String(loweredPattern.dropFirst(1))
                let bare = String(loweredPattern.dropFirst(2))
                if loweredHost.hasSuffix(suffix) || normalizedHost.hasSuffix(suffix)
                    || loweredHost == bare || normalizedHost == bare
                {
                    return true
                }
                continue
            case .trailing:
                let prefix = String(loweredPattern.dropLast(1))
                if loweredHost.hasPrefix(prefix) || normalizedHost.hasPrefix(prefix) {
                    return true
                }
                continue
            case .invalidShape, .invalidSuffix, .invalidStem:
                continue
            case .none:
                break
            }
            // Any remaining wildcard or glob syntax has no host meaning and stays denied.
            if loweredPattern.contains("*") || AllowedOriginPattern.containsGlobSyntax(loweredPattern) {
                continue
            }
            // Exact host comparison on both spellings so canonical IP aliases match.
            if !loweredPattern.contains(":") {
                if loweredHost == loweredPattern || normalizedHost == loweredPattern {
                    return true
                }
                continue
            }
            // A `host:port` entry never authorizes a bare host probe: port-qualified
            // exemptions compare through the origin key in `isOriginAllowed`.
            continue
        }
        return false
    }

    /// Vets one address list against the shared resolved-range table.
    /// Centralizes the range decision so the system resolver and the canned
    /// debug proof cannot diverge on what counts as blocked.
    /// - Parameters:
    ///   - host: Hostname the addresses were claimed for, for honest wording.
    ///   - addresses: Resolved IP literals to vet.
    ///   - origins: Precomputed allowed origins/hosts that exempt internal IPs.
    /// - Returns: Refusal reason, or nil when every address is dialable.
    static func vettedIPListDenial(host: String, addresses: [String], origins: Set<String> = []) -> String? {
        guard !addresses.isEmpty else {
            return unverifiedDenial(for: host)
        }
        // An allowlisted name still proves every address: its exemption covers only
        // private and loopback resolutions, while metadata and link-local stay denied
        // even when allowlisted so a rebinding name cannot launder a blocked target.
        let hostAllowlisted = isHostAllowed(host, origins: origins)
        if isMetadataHost(host) {
            return "SSRF denied: refusing metadata host '\(host)'."
        }
        for ipAddress in addresses {
            if isLinkLocalIPv4(ipAddress) || isLinkLocalIPv6(ipAddress) || isMetadataHost(ipAddress) {
                return "SSRF denied: hostname '\(host)' resolves to blocked address"
            }
            if isLoopbackHost(ipAddress) {
                if hostAllowlisted || isHostAllowed(ipAddress, origins: origins) {
                    continue
                }
                return "SSRF denied: hostname '\(host)' resolves to blocked address"
            }
            let canonicalIP = normalizedHost(ipAddress)
            if let value = ipv4Value(canonicalIP), isSensitiveIPv4Value(value) {
                if hostAllowlisted || isHostAllowed(canonicalIP, origins: origins) {
                    continue
                }
                return "SSRF denied: hostname '\(host)' resolves to blocked address"
            }
            if isSensitiveIPv6Host(canonicalIP) {
                if hostAllowlisted || isHostAllowed(canonicalIP, origins: origins) {
                    continue
                }
                return "SSRF denied: hostname '\(host)' resolves to blocked address"
            }
        }
        return nil
    }
}

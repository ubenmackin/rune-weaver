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
            if let key = originKey(for: url), origins.contains(key) {
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
            if let key = originKey(for: url), origins.contains(key) {
                return .allowed
            }
            return .denied("SSRF denied: refusing private or reserved IPv4 host '\(host)'.")
        }
        if isSensitiveIPv6Host(canonical) {
            if let key = originKey(for: url), origins.contains(key) {
                return .allowed
            }
            return .denied("SSRF denied: refusing private or loopback IPv6 host '\(host)'.")
        }
        if let key = originKey(for: url), origins.contains(key) {
            return .allowed
        }
        if isIPAddressLiteral(host) {
            return .allowed
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

    /// Vets one address list against the shared resolved-range table.
    /// Centralizes the range decision so the system resolver and the canned
    /// debug proof cannot diverge on what counts as blocked.
    /// - Parameters:
    ///   - host: Hostname the addresses were claimed for, for honest wording.
    ///   - addresses: Resolved IP literals to vet.
    /// - Returns: Refusal reason, or nil when every address is dialable.
    static func vettedIPListDenial(host: String, addresses: [String]) -> String? {
        guard !addresses.isEmpty else {
            return unverifiedDenial(for: host)
        }
        for ipAddress in addresses {
            if isLinkLocalIPv4(ipAddress) || isLinkLocalIPv6(ipAddress) || isLoopbackHost(ipAddress) {
                return "SSRF denied: hostname '\(host)' resolves to blocked address"
            }
            let canonicalIP = normalizedHost(ipAddress)
            if let value = ipv4Value(canonicalIP), isSensitiveIPv4Value(value) {
                return "SSRF denied: hostname '\(host)' resolves to blocked address"
            }
            if isSensitiveIPv6Host(canonicalIP) {
                return "SSRF denied: hostname '\(host)' resolves to blocked address"
            }
        }
        return nil
    }
}

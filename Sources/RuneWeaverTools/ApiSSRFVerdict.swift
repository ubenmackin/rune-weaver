// Rune Weaver Tools — SSRF pre-DNS verdict, resolved-address vetting, and dial pins.
//
// Purpose: literal-only refusal stage plus fail-closed vetting of resolved
// addresses, so hostnames that cannot prove every address dialable never dial.
// Scope: pure parsing and range checks over the literal host plus the shared
// resolved-range table; DNS resolution and the bounded pool stay with the gate
// in `ApiSSRFGuard`. Every allowed verdict carries a dial pin — the numeric
// address(es) the resolved-range table proved — so callers can dial the proof
// instead of re-resolving the hostname at connect time (DNS rebinding).
// Architectural role: single-source verdict layer backing `ApiSSRFGuard`; the
// sync engine, the async inline stage, and the async pin-producing path share
// this stage so literal and resolved decisions cannot diverge between callers.
// The same layer also carries `LocalAccessVerdict`, the save-time
// local-access classifier's result, so a host's stored access grant and its
// dial decision cannot drift.

import Foundation
import RuneWeaverCore

/// Dial pin proven by the SSRF gate for one destination.
///
/// The pin is the dial-time half of the SSRF contract: it names the original
/// host identity (preserved for the HTTP `Host` header and the TLS server
/// name) plus the numeric addresses every one of which passed the
/// resolved-range table, so a transport can connect without consulting the
/// resolver again.
public struct SSRFDialPin: Sendable, Equatable {
    /// Original host, preserved for the `Host` header and TLS server name.
    public let host: String
    /// Numeric addresses proven dialable by the resolved-range vetting.
    public let addresses: [String]
    /// Effective destination port from the URL.
    public let port: Int
    /// Whether the hop dials TLS (`https`).
    public let isSecure: Bool

    /// Creates a dial pin.
    public init(host: String, addresses: [String], port: Int, isSecure: Bool) {
        self.host = host
        self.addresses = addresses
        self.port = port
        self.isSecure = isSecure
    }
}

/// Outcome of an async SSRF vetting pass.
public enum ApiSSRFVetting: Sendable, Equatable {
    /// The URL may be dialed; the transport must dial the pin's addresses.
    case dialable(SSRFDialPin)
    /// The URL was refused with a human-readable reason.
    case refused(String)

    /// Refusal reason, or nil when dialable.
    public var refusal: String? {
        if case let .refused(reason) = self {
            return reason
        }
        return nil
    }
}

/// Whether saving a host should grant the owner access to local-network
/// destinations.
///
/// One verdict type owns the save-time decision so the stored grant and the
/// dial-time guard cannot disagree: `.neverDialable` mirrors the guard's
/// no-exemption refusal for metadata, link-local, and embedded-translation
/// targets; `.localNetwork` mirrors the exemptable-sensitive ranges (loopback,
/// private, CGNAT, reserved, and unique-local); `.publicDestination` mirrors
/// the public-literal and public-answer allowance; and `.unresolved` mirrors
/// the guard's fail-closed answer when no address could be proven.
public enum LocalAccessVerdict: Sendable, Equatable {
    /// A public destination: saving it grants no local-network reach.
    case publicDestination
    /// A loopback, private, CGNAT, reserved, or unique-local destination.
    case localNetwork
    /// Never dialable even under an exemption: metadata, link-local, or an
    /// embedded translation of either.
    case neverDialable(reason: String)
    /// No address could be proven (blank host, empty answer, timeout, or
    /// cancellation); absence of proof never grants local access.
    case unresolved(reason: String)
}

extension ApiSSRFGuard {
    /// Async vetting against an explicit exemption set, returning the dial pin.
    /// Literal checks run inline on the calling task while DNS hops to the
    /// bounded pool with a fail-closed timeout, so the cooperative pool never
    /// stalls on a wedged resolver; an allowed verdict pins the proven
    /// addresses so the dial never re-resolves the name.
    /// - Parameters:
    ///   - rawURL: Candidate URL.
    ///   - allowlistedOrigins: Precomputed `host:port` exemptions that may be dialed.
    /// - Returns: Dialable pin, or a refusal reason.
    public static func vetAsync(
        for rawURL: String,
        allowlistedOrigins: Set<String> = []
    ) async -> ApiSSRFVetting {
        await vet(for: rawURL, origins: allowlistedOrigins, hasLLMOrigins: false)
    }

    /// Async vetting against an explicit exemption set with honest wording,
    /// returning the dial pin. Identical vetting to the default overload —
    /// `hasLLMOrigins` tunes only the loopback denial wording so a caller that
    /// unions LLM endpoints into its exemption set never denies with a reason
    /// promising fewer exemptions than the gate actually honors.
    /// - Parameters:
    ///   - rawURL: Candidate URL.
    ///   - allowlistedOrigins: Precomputed `host:port` exemptions that may be dialed.
    ///   - hasLLMOrigins: Whether LLM endpoints contribute exemptions, for honest wording.
    /// - Returns: Dialable pin, or a refusal reason.
    public static func vetAsync(
        for rawURL: String,
        allowlistedOrigins: Set<String>,
        hasLLMOrigins: Bool
    ) async -> ApiSSRFVetting {
        await vet(for: rawURL, origins: allowlistedOrigins, hasLLMOrigins: hasLLMOrigins)
    }

    /// Async vetting for a URL, returning the dial pin.
    /// The verdict stays point-in-time only in the sense that it is taken at
    /// vetting time: the returned pin closes the race by naming the addresses
    /// the dial must use, and a later rebinding answer cannot change them.
    public static func vetAsync(
        for rawURL: String,
        browserConfig: BrowserConfig,
        mediaConfig: MediaConfig? = nil,
        llmServerURLs: [String] = []
    ) async -> ApiSSRFVetting {
        let origins = allowlistedOrigins(browserConfig: browserConfig, mediaConfig: mediaConfig, llmServerURLs: llmServerURLs)
        let hasLLM = llmServerURLs.contains(where: { NormalizedText.value($0) != nil })
        return await vet(for: rawURL, origins: origins, hasLLMOrigins: hasLLM)
    }

    /// Shared async vetting engine over a precomputed exemption set.
    /// The pre-DNS stage runs inline (literal refusals never wait on DNS) and
    /// only a hostname needing proof hops to the bounded resolver pool; an
    /// allowed literal becomes a pin directly, while any other allowed host
    /// (the `localhost` loopback equivalence) still re-enters resolved-range
    /// vetting so the pin is always numeric.
    /// - Parameters:
    ///   - rawURL: Candidate URL.
    ///   - origins: Precomputed `host:port` exemptions that may be dialed.
    ///   - hasLLMOrigins: Whether LLM endpoints contribute exemptions, for honest wording.
    /// - Returns: Dialable pin, or a refusal reason.
    static func vet(for rawURL: String, origins: Set<String>, hasLLMOrigins: Bool) async -> ApiSSRFVetting {
        switch preDNSOutcome(for: rawURL, allowlistedOrigins: origins, hasLLMOrigins: hasLLMOrigins) {
        case let .denied(reason):
            return .refused(reason)
        case .allowed:
            guard let url = parsedVettingURL(rawURL) else {
                return .refused(unverifiedDenial(for: rawURL))
            }
            guard let pin = staticLiteralPin(for: url) else {
                // The pre-DNS stage allows numeric literals and the
                // `localhost` loopback equivalence; the latter still needs a
                // numeric pin, so it proves its addresses through the same
                // resolved-range vetting instead of dialing a name.
                guard let host = url.host, !host.isEmpty else {
                    return .refused(unverifiedDenial(for: rawURL))
                }
                return await dnsVettingAsync(host: host, origins: origins, url: url)
            }
            return .dialable(pin)
        case let .needsDNS(host):
            guard let url = parsedVettingURL(rawURL) else {
                return .refused(unverifiedDenial(for: host))
            }
            return await dnsVettingAsync(host: host, origins: origins, url: url)
        }
    }

    /// Parses a candidate URL to the shape whose pin will be built.
    /// - Parameter rawURL: Candidate URL string.
    /// - Returns: Parsed URL with a host, or nil when the string has none.
    static func parsedVettingURL(_ rawURL: String) -> URL? {
        guard let trimmed = NormalizedText.value(rawURL),
              let url = URL(string: trimmed),
              let host = url.host,
              !host.isEmpty
        else {
            return nil
        }
        return url
    }

    /// Pin for a numeric literal host that carries no resolver alias to rebind.
    /// - Parameter url: Parsed URL whose host is already vetted.
    /// - Returns: Pin naming the canonical literal, or nil for DNS names.
    static func staticLiteralPin(for url: URL) -> SSRFDialPin? {
        guard let host = url.host, !host.isEmpty, isIPAddressLiteral(host) else { return nil }
        // Obfuscated decimal, hex, octal, and short spellings canonicalize to
        // the same numeric literal the range checks classified, so the wire
        // dial cannot depend on how the spelling was written.
        let canonical = normalizedHost(host)
        guard !canonical.isEmpty, canonicalIPv4Octets(canonical) != nil || ipv6Hextets(canonical) != nil else {
            return nil
        }
        return SSRFDialPin(
            host: host,
            addresses: [canonical],
            port: effectivePort(for: url),
            isSecure: url.scheme?.lowercased() == "https"
        )
    }

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
        // A NAT64, 6to4, or IPv4-compatible spelling of link-local or metadata
        // space refuses before any allowlist exemption, mirroring the direct
        // spellings above: the decoded address decides, not the spelling.
        if let embeddedDenial = embeddedNeverExemptDenial(for: host) {
            return .denied(embeddedDenial)
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
        // Classify the literal's own prefix as well as the normalized form:
        // normalization collapses a dotted tail onto its dotted IPv4, which
        // would drop the link-local, unique-local, or embedded-translation
        // verdict the literal's prefix carries.
        if isSensitiveIPv6Host(host) || isSensitiveIPv6Host(canonical) {
            if isOriginAllowed(url: url, origins: origins) {
                return .allowed
            }
            return .denied("SSRF denied: refusing private or loopback IPv6 host '\(host)'.")
        }
        if isIPAddressLiteral(host) {
            // Literals carry no resolver alias to rebind, so the allowlist verdict above
            // plus the public-literal default below settle them without DNS. Sensitive
            // IPv4-embedded prefixes never reach here: their decoded address was
            // already classified above, before the public-literal allowance.
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

    /// Never-exempt refusal for the address an IPv4-embedding prefix carries.
    ///
    /// A NAT64 (`64:ff9b::/96` and local-use `64:ff9b:1::/48`), 6to4
    /// (`2002::/16`), IPv4-compatible (`::/96`), mapped, or translated
    /// spelling decodes to the IPv4 address it embeds; a decoded link-local
    /// or metadata target refuses even for an allowlisted name, exactly like
    /// the direct spelling, so an alternate spelling can never launder a
    /// blocked destination past the exemption. Private, loopback, and public
    /// decoded addresses return nil and follow the ordinary exemption path in
    /// each caller.
    /// - Parameter host: Address literal to decode.
    /// - Returns: Refusal reason, or nil when no never-exempt target embeds.
    static func embeddedNeverExemptDenial(for host: String) -> String? {
        guard let embedded = ApiSSRFAddresses.embeddedIPv4Literal(host) else { return nil }
        if isLinkLocalIPv4(embedded) {
            return "SSRF denied: refusing link-local address '\(host)' (IPv4-embedded)."
        }
        if isMetadataHost(embedded) {
            return "SSRF denied: refusing metadata host '\(host)'."
        }
        return nil
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

    /// Vets one address list against the shared resolved-range table and, when
    /// Vets one address list against the shared resolved-range table.
    /// Centralizes the range decision so the system resolver and the canned
    /// debug proof cannot diverge on what counts as blocked.
    /// - Parameters:
    ///   - host: Hostname the addresses were claimed for, for honest wording.
    ///   - addresses: Resolved IP literals to vet.
    ///   - origins: Precomputed allowed origins/hosts that exempt internal IPs.
    /// - Returns: Refusal reason, or nil when every address is dialable.
    static func vettedIPListDenial(
        host: String,
        addresses: [String],
        origins: Set<String> = []
    ) -> String? {
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
            // An IPv4-embedding prefix is vetted as the address it carries:
            // a NAT64, 6to4, or IPv4-compatible spelling of link-local or
            // metadata space stays denied even for an allowlisted name,
            // exactly like the direct spellings checked above.
            if embeddedNeverExemptDenial(for: ipAddress) != nil {
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
            // The literal's own prefix classifies before its normalized form:
            // normalization collapses a dotted tail onto its dotted IPv4,
            // which would drop the link-local, unique-local, or
            // embedded-translation verdict the prefix carries.
            if isSensitiveIPv6Host(ipAddress) || isSensitiveIPv6Host(canonicalIP) {
                if hostAllowlisted || isHostAllowed(canonicalIP, origins: origins) {
                    continue
                }
                return "SSRF denied: hostname '\(host)' resolves to blocked address"
            }
        }
        return nil
    }

    /// Vets one address list against the shared resolved-range table and, when
    /// every address clears, returns the dial pin naming them.
    /// Centralizes the range decision so the system resolver and the canned
    /// debug proof cannot diverge on what counts as blocked.
    /// - Parameters:
    ///   - host: Hostname the addresses were claimed for, for honest wording.
    ///   - addresses: Resolved IP literals to vet.
    ///   - origins: Precomputed allowed origins/hosts that exempt internal IPs.
    ///   - url: Destination URL supplying the pin's port and scheme.
    /// - Returns: Dialable pin, or the refusal reason.
    static func vettedIPListVetting(
        host: String,
        addresses: [String],
        origins: Set<String> = [],
        url: URL
    ) -> ApiSSRFVetting {
        if let denial = vettedIPListDenial(host: host, addresses: addresses, origins: origins) {
            return .refused(denial)
        }
        // Every address cleared, so the pin names the exact proof the dial
        // must use; the transport never re-resolves the hostname.
        return .dialable(
            SSRFDialPin(
                host: host,
                addresses: addresses,
                port: effectivePort(for: url),
                isSecure: url.scheme?.lowercased() == "https"
            )
        )
    }
}

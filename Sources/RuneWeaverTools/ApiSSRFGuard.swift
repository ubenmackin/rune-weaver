// Rune Weaver Tools — Single-source SSRF guard for API and fetch hops.
//
// The guard refuses metadata hosts, link-local, loopback except configured
// origins, private RFC 1918 ranges, and IPv6 unique-local addresses across
// decimal, hex, octal, and short IPv4 spellings. IPv4 parsing, address
// classification, and origin normalization live in small sibling helpers so
// the gate type stays within budget; every caller still enters through
// `ApiSSRFGuard`, so allowlist checks cannot diverge on obfuscated hosts.

import Foundation
import RuneWeaverCore

/// Four parsed IPv4 octets for range checks without tuple destructuring.
public struct IPv4Octets: Sendable, Equatable {
    /// First octet (e.g. `169` in `169.254.x.x`).
    public let firstOctet: Int
    /// Second octet (e.g. `254` in `169.254.x.x`).
    public let secondOctet: Int
    /// Third octet.
    public let thirdOctet: Int
    /// Fourth octet.
    public let fourthOctet: Int

    /// Creates parsed octets.
    public init(firstOctet: Int, secondOctet: Int, thirdOctet: Int, fourthOctet: Int) {
        self.firstOctet = firstOctet
        self.secondOctet = secondOctet
        self.thirdOctet = thirdOctet
        self.fourthOctet = fourthOctet
    }
}

/// Resolver-accepted IPv4 parsing shared by the SSRF guard.
///
/// Handles decimal, hex, octal, and short forms plus IPv4-mapped IPv6 so
/// obfuscated spellings canonicalize before any range decision.
enum ApiIPv4Parsing: Sendable {
    /// Parses one numeric IPv4 part in decimal, octal, or hex.
    static func parseNumericPart(_ part: String) -> UInt32? {
        let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") {
            let hex = String(trimmed.dropFirst(2))
            guard !hex.isEmpty, hex.count <= 8 else { return nil }
            guard hex.allSatisfy(\.isHexDigit) else { return nil }
            return UInt32(hex, radix: 16)
        }
        if trimmed.hasPrefix("0"), trimmed.count > 1, trimmed.allSatisfy(\.isNumber) {
            let digits = trimmed
            let isOctal = digits.allSatisfy { char in
                guard let ascii = char.asciiValue else { return false }
                return ascii >= 48 && ascii <= 55
            }
            if isOctal {
                return UInt32(digits, radix: 8)
            }
            return UInt32(digits, radix: 10)
        }
        guard trimmed.allSatisfy(\.isNumber) else { return nil }
        return UInt32(trimmed, radix: 10)
    }

    /// Parses IPv6 text into eight hextets for loopback and mapped checks.
    static func ipv6Hextets(_ host: String) -> [UInt16]? {
        let lowered = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowered.isEmpty, lowered.contains(":"), !lowered.contains(".") else { return nil }
        guard !lowered.contains("%") else { return nil }
        if lowered.contains("::") {
            let halves = lowered.components(separatedBy: "::")
            guard halves.count == 2 else { return nil }
            let headParts = halves[0].isEmpty ? [] : halves[0].split(separator: ":", omittingEmptySubsequences: false)
            let tailParts = halves[1].isEmpty ? [] : halves[1].split(separator: ":", omittingEmptySubsequences: false)
            for part in headParts + tailParts {
                guard !part.isEmpty, part.count <= 4, part.allSatisfy(\.isHexDigit) else { return nil }
            }
            guard headParts.count + tailParts.count <= 7 else { return nil }
            var groups: [UInt16] = []
            groups.reserveCapacity(8)
            for part in headParts {
                guard let value = UInt16(String(part), radix: 16) else { return nil }
                groups.append(value)
            }
            let missing = 8 - (headParts.count + tailParts.count)
            groups.append(contentsOf: Array(repeating: UInt16(0), count: missing))
            for part in tailParts {
                guard let value = UInt16(String(part), radix: 16) else { return nil }
                groups.append(value)
            }
            guard groups.count == 8 else { return nil }
            return groups
        }
        let parts = lowered.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 8 else { return nil }
        var groups: [UInt16] = []
        groups.reserveCapacity(8)
        for part in parts {
            guard !part.isEmpty, part.count <= 4, part.allSatisfy(\.isHexDigit) else { return nil }
            guard let value = UInt16(String(part), radix: 16) else { return nil }
            groups.append(value)
        }
        return groups
    }

    /// Parses any resolver-accepted IPv4 spelling to canonical octets.
    static func canonicalIPv4Octets(_ host: String) -> IPv4Octets? {
        let cleaned = ApiSSRFOrigin.cleanedHostBase(host)
        guard !cleaned.isEmpty else { return nil }
        if cleaned.contains(":") {
            return octetsFromMappedIPv6(cleaned.lowercased())
        }
        guard let values = numericValuesForDottedHost(cleaned) else { return nil }
        return octetsFromNumericValues(values)
    }

    /// Resolves the IPv4 octets hidden inside an IPv6 literal.
    static func octetsFromMappedIPv6(_ lowered: String) -> IPv4Octets? {
        if lowered.contains(".") {
            guard let lastColon = lowered.lastIndex(of: ":") else { return nil }
            let tail = String(lowered[lowered.index(after: lastColon)...])
            guard !tail.isEmpty, !tail.contains(":") else { return nil }
            return canonicalIPv4Octets(tail)
        }
        guard let groups = ipv6Hextets(lowered) else { return nil }
        guard isIPv4Mapped(groups) else { return nil }
        let high = groups[6]
        let low = groups[7]
        return IPv4Octets(
            firstOctet: Int(high >> 8),
            secondOctet: Int(high & UInt16(0xFF)),
            thirdOctet: Int(low >> 8),
            fourthOctet: Int(low & UInt16(0xFF))
        )
    }

    /// Whether eight hextets are an IPv4-mapped prefix (`::ffff:0:0/96`).
    static func isIPv4Mapped(_ groups: [UInt16]) -> Bool {
        guard groups.count == 8 else { return false }
        return groups[0] == 0 && groups[1] == 0 && groups[2] == 0 && groups[3] == 0 && groups[4] == 0 && groups[5] == 0xFFFF
    }

    /// Parses the dotted parts of a cleaned host into resolver numbers.
    static func numericValuesForDottedHost(_ cleaned: String) -> [UInt32]? {
        let parts = cleaned.split(separator: ".", omittingEmptySubsequences: false)
        guard (1 ... 4).contains(parts.count) else { return nil }
        var values: [UInt32] = []
        values.reserveCapacity(parts.count)
        for part in parts {
            guard !part.isEmpty else { return nil }
            guard let value = parseNumericPart(String(part)) else { return nil }
            values.append(value)
        }
        return values
    }

    /// Expands one to four resolver numbers into four canonical octets.
    static func octetsFromNumericValues(_ values: [UInt32]) -> IPv4Octets? {
        switch values.count {
        case 1:
            let value = values[0]
            return IPv4Octets(
                firstOctet: Int((value >> 24) & 0xFF),
                secondOctet: Int((value >> 16) & 0xFF),
                thirdOctet: Int((value >> 8) & 0xFF),
                fourthOctet: Int(value & 0xFF)
            )
        case 2:
            guard values[0] <= 255, values[1] <= 0xFFFFFF else { return nil }
            let first = values[0]
            let second = values[1]
            return IPv4Octets(
                firstOctet: Int(first),
                secondOctet: Int((second >> 16) & 0xFF),
                thirdOctet: Int((second >> 8) & 0xFF),
                fourthOctet: Int(second & 0xFF)
            )
        case 3:
            guard values[0] <= 255, values[1] <= 255, values[2] <= 0xFFFF else { return nil }
            let third = values[2]
            return IPv4Octets(
                firstOctet: Int(values[0]),
                secondOctet: Int(values[1]),
                thirdOctet: Int((third >> 8) & 0xFF),
                fourthOctet: Int(third & 0xFF)
            )
        case 4:
            for value in values {
                guard value <= 255 else { return nil }
            }
            return IPv4Octets(
                firstOctet: Int(values[0]),
                secondOctet: Int(values[1]),
                thirdOctet: Int(values[2]),
                fourthOctet: Int(values[3])
            )
        default:
            return nil
        }
    }
}

/// Host normalization and origin comparison shared by the SSRF guard.
///
/// Canonicalizes bracketed IPv6, zone IDs, and trailing dots plus the
/// scheme-default port so allowlist exemptions compare `host:port` exactly.
enum ApiSSRFOrigin: Sendable {
    /// Trims a raw host to its comparable base form.
    static func cleanedHostBase(_ host: String) -> String {
        var cleaned = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if cleaned.hasPrefix("["), cleaned.hasSuffix("]"), cleaned.count >= 2 {
            cleaned = String(cleaned.dropFirst().dropLast())
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let percent = cleaned.firstIndex(of: "%") {
            cleaned = String(cleaned[..<percent])
        }
        while cleaned.hasSuffix("."), cleaned.count > 1 {
            cleaned = String(cleaned.dropLast())
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Normalizes a URL host for origin comparison.
    static func normalizedHost(_ host: String) -> String {
        let cleaned = cleanedHostBase(host)
        guard !cleaned.isEmpty else { return "" }
        if let octets = ApiIPv4Parsing.canonicalIPv4Octets(cleaned) {
            return "\(octets.firstOctet).\(octets.secondOctet).\(octets.thirdOctet).\(octets.fourthOctet)"
        }
        if cleaned.contains(":"), !cleaned.contains("."), let groups = ApiIPv4Parsing.ipv6Hextets(cleaned) {
            return groups.map { String(Int($0), radix: 16) }.joined(separator: ":")
        }
        return cleaned
    }

    /// Effective port for origin comparison, filling the scheme default.
    static func effectivePort(for url: URL) -> Int {
        if let port = url.port, (1 ... 65535).contains(port) {
            return port
        }
        if url.scheme?.lowercased() == "https" {
            return 443
        }
        return 80
    }

    /// Origin key (`host:port`) for allowlist comparison.
    /// - Parameter url: Parsed URL with a host.
    /// - Returns: Lowercased origin, or nil when hostless.
    static func originKey(for url: URL) -> String? {
        guard let host = url.host, !host.isEmpty else { return nil }
        return "\(normalizedHost(host)):\(effectivePort(for: url))"
    }
}

/// Sensitive-range classification shared by the SSRF guard.
///
/// Covers loopback, link-local, private RFC 1918, `0.0.0.0/8`, and IPv6
/// unique-local addresses so fetch and API checks share one range table.
enum ApiSSRFAddresses: Sendable {
    /// Whether a host is in `169.254.0.0/16` (link-local, never allowlisted).
    static func isLinkLocalIPv4(_ host: String) -> Bool {
        guard let octets = ApiIPv4Parsing.canonicalIPv4Octets(host) else { return false }
        return octets.firstOctet == 169 && octets.secondOctet == 254
    }

    /// Whether a host is IPv6 link-local (`fe80::/10`, never allowlisted).
    static func isLinkLocalIPv6(_ host: String) -> Bool {
        let cleaned = ApiSSRFOrigin.cleanedHostBase(host)
        guard cleaned.contains(":"), !cleaned.contains(".") else { return false }
        guard let groups = ApiIPv4Parsing.ipv6Hextets(cleaned) else { return false }
        return (groups[0] & 0xFFC0) == 0xFE80
    }

    /// Whether a host is IPv4 loopback (`127.0.0.0/8`).
    static func isLoopbackIPv4(_ host: String) -> Bool {
        guard let octets = ApiIPv4Parsing.canonicalIPv4Octets(host) else { return false }
        return octets.firstOctet == 127
    }

    /// Whether a host is IPv6 loopback or unspecified.
    static func isLoopbackIPv6(_ host: String) -> Bool {
        let cleaned = ApiSSRFOrigin.cleanedHostBase(host)
        guard cleaned.contains(":") else { return false }
        if cleaned.contains(".") {
            return false
        }
        guard let groups = ApiIPv4Parsing.ipv6Hextets(cleaned) else { return false }
        let allZero = groups.allSatisfy { $0 == 0 }
        if allZero {
            return true
        }
        return groups[0] == 0 && groups[1] == 0 && groups[2] == 0 && groups[3] == 0 && groups[4] == 0 && groups[5] == 0 && groups[6] == 0 && groups[7] == 1
    }

    /// Whether a host is a loopback equivalent.
    static func isLoopbackHost(_ host: String) -> Bool {
        let cleaned = ApiSSRFOrigin.cleanedHostBase(host)
        guard !cleaned.isEmpty else { return false }
        if cleaned == "localhost" {
            return true
        }
        if isLoopbackIPv6(cleaned) {
            return true
        }
        guard let octets = ApiIPv4Parsing.canonicalIPv4Octets(cleaned) else { return false }
        if octets.firstOctet == 127 {
            return true
        }
        if octets.firstOctet == 0, octets.secondOctet == 0, octets.thirdOctet == 0, octets.fourthOctet == 0 {
            return true
        }
        return false
    }

    /// Whether a 32-bit IPv4 value dials a sensitive range (loopback,
    /// link-local, private RFC 1918, or `0.0.0.0/8`). Single-sourced so the
    /// API guard and the fetch guard cannot diverge on obfuscated spellings.
    static func isSensitiveIPv4Value(_ value: UInt32) -> Bool {
        if (value & 0xFF00_0000) == 0x7F00_0000 {
            return true
        }
        if (value & 0xFFFF_0000) == 0xA9FE_0000 {
            return true
        }
        if (value & 0xFF00_0000) == 0x0A00_0000 {
            return true
        }
        if (value & 0xFFF0_0000) == 0xAC10_0000 {
            return true
        }
        if (value & 0xFFFF_0000) == 0xC0A8_0000 {
            return true
        }
        if (value & 0xFF00_0000) == 0x0000_0000 {
            return true
        }
        return false
    }

    /// Parses a canonical host to its 32-bit IPv4 value for range checks.
    static func ipv4Value(_ host: String) -> UInt32? {
        guard let octets = ApiIPv4Parsing.canonicalIPv4Octets(host) else { return nil }
        return (UInt32(octets.firstOctet) << 24) | (UInt32(octets.secondOctet) << 16)
            | (UInt32(octets.thirdOctet) << 8) | UInt32(octets.fourthOctet)
    }

    /// Whether a canonical host is a sensitive IPv6 literal (loopback,
    /// link-local, unique-local `fc00::/7`, or mapped sensitive tails).
    /// Unique-local requires an IPv6 literal (a colon) plus the `fc00::/7`
    /// hextet mask, so DNS names like `fc.example.com` never false-positive.
    static func isSensitiveIPv6Host(_ canonical: String) -> Bool {
        if isLoopbackIPv6(canonical) || isLinkLocalIPv6(canonical) {
            return true
        }
        let lowered = canonical.lowercased()
        if lowered.contains(":"), lowered.contains(".") {
            if let lastColon = lowered.lastIndex(of: ":") {
                let embedded = String(lowered[lowered.index(after: lastColon)...])
                if let value = ipv4Value(embedded), isSensitiveIPv4Value(value) {
                    return true
                }
            }
            return false
        }
        if lowered.contains(":"), let groups = ApiIPv4Parsing.ipv6Hextets(lowered), !groups.isEmpty,
           (groups[0] & 0xFE00) == 0xFC00
        {
            return true
        }
        if lowered.contains("ffff"), lowered.hasSuffix(":7f00:1") || lowered.hasSuffix(":7f00:0001") {
            return true
        }
        return false
    }
}

/// SSRF guard for API URLs.
///
/// Single entry point for decimal, hex, octal, and short IPv4 forms plus IPv6
/// and metadata hosts; parsing, classification, and origin helpers live in
/// sibling types so this gate stays within budget without a second range pass.
public enum ApiSSRFGuard: Sendable {
    /// Well-known cloud metadata hostnames refused even over public DNS.
    public static let blockedMetadataHosts: Set<String> = [
        "metadata.google.internal",
        "metadata.google",
        "metadata.goog",
        "instance-data.compute.internal",
        "instance-data",
        "metadata.azure.internal",
        "metadata.aws.internal",
        "metadata"
    ]

    /// Whether a host is a well-known metadata hostname.
    public static func isMetadataHost(_ host: String) -> Bool {
        let lowered = ApiSSRFOrigin.cleanedHostBase(host)
        guard !lowered.isEmpty else { return false }
        if blockedMetadataHosts.contains(lowered) {
            return true
        }
        if lowered == "metadata" {
            return true
        }
        if lowered.contains("metadata.google") {
            return true
        }
        if lowered.contains("instance-data") {
            return true
        }
        if lowered.contains("metadata.azure") {
            return true
        }
        return false
    }

    /// Parses one numeric IPv4 part in decimal, octal, or hex.
    public static func parseNumericPart(_ part: String) -> UInt32? {
        ApiIPv4Parsing.parseNumericPart(part)
    }

    /// Parses IPv6 text into eight hextets for loopback and mapped checks.
    public static func ipv6Hextets(_ host: String) -> [UInt16]? {
        ApiIPv4Parsing.ipv6Hextets(host)
    }

    /// Parses any resolver-accepted IPv4 spelling to canonical octets.
    public static func canonicalIPv4Octets(_ host: String) -> IPv4Octets? {
        ApiIPv4Parsing.canonicalIPv4Octets(host)
    }

    /// Whether a host string is a dotted IPv4 literal.
    public static func ipv4Octets(_ host: String) -> IPv4Octets? {
        ApiIPv4Parsing.canonicalIPv4Octets(host)
    }

    /// Whether a host is in `169.254.0.0/16` (link-local, never allowlisted).
    public static func isLinkLocalIPv4(_ host: String) -> Bool {
        ApiSSRFAddresses.isLinkLocalIPv4(host)
    }

    /// Whether a host is IPv6 link-local (`fe80::/10`, never allowlisted).
    public static func isLinkLocalIPv6(_ host: String) -> Bool {
        ApiSSRFAddresses.isLinkLocalIPv6(host)
    }

    /// Whether a host is IPv4 loopback (`127.0.0.0/8`).
    public static func isLoopbackIPv4(_ host: String) -> Bool {
        ApiSSRFAddresses.isLoopbackIPv4(host)
    }

    /// Whether a host is IPv6 loopback or unspecified.
    public static func isLoopbackIPv6(_ host: String) -> Bool {
        ApiSSRFAddresses.isLoopbackIPv6(host)
    }

    /// Whether a host is a loopback equivalent.
    public static func isLoopbackHost(_ host: String) -> Bool {
        ApiSSRFAddresses.isLoopbackHost(host)
    }

    /// Whether a 32-bit IPv4 value dials a sensitive range.
    public static func isSensitiveIPv4Value(_ value: UInt32) -> Bool {
        ApiSSRFAddresses.isSensitiveIPv4Value(value)
    }

    /// Parses a canonical host to its 32-bit IPv4 value for range checks.
    public static func ipv4Value(_ host: String) -> UInt32? {
        ApiSSRFAddresses.ipv4Value(host)
    }

    /// Whether a canonical host is a sensitive IPv6 literal.
    public static func isSensitiveIPv6Host(_ canonical: String) -> Bool {
        ApiSSRFAddresses.isSensitiveIPv6Host(canonical)
    }

    /// Normalizes a URL host for origin comparison.
    public static func normalizedHost(_ host: String) -> String {
        ApiSSRFOrigin.normalizedHost(host)
    }

    /// Effective port for origin comparison, filling the scheme default.
    public static func effectivePort(for url: URL) -> Int {
        ApiSSRFOrigin.effectivePort(for: url)
    }

    /// Origin key (`host:port`) for allowlist comparison.
    /// - Parameter url: Parsed URL with a host.
    /// - Returns: Lowercased origin, or nil when hostless.
    public static func originKey(for url: URL) -> String? {
        ApiSSRFOrigin.originKey(for: url)
    }

    /// Allowlisted loopback origins derived from configuration.
    public static func allowlistedOrigins(browserConfig: BrowserConfig, llmServerURLs: [String]) -> Set<String> {
        var origins = Set<String>()
        let candidates = [browserConfig.searxngURL] + llmServerURLs
        for raw in candidates {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let url = URL(string: trimmed), let key = originKey(for: url) else { continue }
            origins.insert(key)
        }
        return origins
    }

    /// Refusal reason against an explicit exemption set, or nil when dialable.
    /// Browser flows pass an empty set because they never dial local origins,
    /// so every loopback and LAN spelling fails closed with no config to forge.
    /// - Parameters:
    ///   - rawURL: Candidate URL.
    ///   - allowlistedOrigins: Precomputed `host:port` exemptions that may be dialed.
    /// - Returns: Refusal reason, or nil when allowed.
    public static func denyReason(
        for rawURL: String,
        allowlistedOrigins: Set<String> = []
    ) -> String? {
        denyReasonImpl(for: rawURL, allowlistedOrigins: allowlistedOrigins, hasLLMOrigins: false)
    }

    /// Refusal reason for a URL, or nil when the URL may be dialed.
    /// Denies metadata, link-local, loopback (except the configured
    /// `searxng_url` plus LLM origins), private RFC 1918 ranges, `0.0.0.0/8`,
    /// and IPv6 unique-local addresses across decimal/hex/octal/short forms.
    public static func denyReason(
        for rawURL: String,
        browserConfig: BrowserConfig,
        llmServerURLs: [String] = []
    ) -> String? {
        let origins = allowlistedOrigins(browserConfig: browserConfig, llmServerURLs: llmServerURLs)
        let hasLLM = llmServerURLs.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        return denyReasonImpl(for: rawURL, allowlistedOrigins: origins, hasLLMOrigins: hasLLM)
    }

    /// Shared refusal engine over a precomputed exemption set.
    /// - Parameters:
    ///   - rawURL: Candidate URL.
    ///   - origins: Precomputed `host:port` exemptions that may be dialed.
    ///   - hasLLMOrigins: Whether LLM endpoints contribute exemptions, for honest wording.
    /// - Returns: Refusal reason, or nil when allowed.
    private static func denyReasonImpl(
        for rawURL: String,
        allowlistedOrigins origins: Set<String>,
        hasLLMOrigins: Bool
    ) -> String? {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Empty URL: api.request needs an absolute http(s) URL." }
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("file:") {
            return "SSRF denied: file scheme is not allowed (\(trimmed))."
        }
        guard WebURLSafety.isSafeUrl(trimmed) else {
            return "Unsafe URL: api.request only dereferences absolute http(s) URLs (\(trimmed))."
        }
        guard let url = URL(string: trimmed), let host = url.host, !host.isEmpty else {
            return "Unsafe URL: api.request only dereferences absolute http(s) URLs (\(trimmed))."
        }
        if isMetadataHost(host) {
            return "SSRF denied: refusing metadata host '\(host)'."
        }
        if isLinkLocalIPv4(host) {
            return "SSRF denied: refusing link-local address '\(host)' (169.254.0.0/16)."
        }
        if isLinkLocalIPv6(host) {
            return "SSRF denied: refusing link-local address '\(host)' (fe80::/10)."
        }
        if isLoopbackHost(host) {
            if let key = originKey(for: url), origins.contains(key) {
                return nil
            }
            // Exemption wording follows the configured origins so fetch-only
            // callers (no LLM origins) never promise an LLM exemption they do
            // not honor; the range decision stays single-source above.
            if hasLLMOrigins {
                return "SSRF denied: refusing loopback host '\(host)' except configured searxng_url and LLM endpoints."
            }
            return "SSRF denied: refusing loopback host '\(host)' except configured searxng_url."
        }
        let canonical = normalizedHost(host)
        if let value = ipv4Value(canonical), isSensitiveIPv4Value(value) {
            if let key = originKey(for: url), origins.contains(key) {
                return nil
            }
            return "SSRF denied: refusing private or reserved IPv4 host '\(host)'."
        }
        if isSensitiveIPv6Host(canonical) {
            if let key = originKey(for: url), origins.contains(key) {
                return nil
            }
            return "SSRF denied: refusing private or loopback IPv6 host '\(host)'."
        }
        return nil
    }

    /// Whether a URL may be dialed under the SSRF guard.
    public static func isAllowed(
        _ rawURL: String,
        browserConfig: BrowserConfig,
        llmServerURLs: [String] = []
    ) -> Bool {
        denyReason(for: rawURL, browserConfig: browserConfig, llmServerURLs: llmServerURLs) == nil
    }
}

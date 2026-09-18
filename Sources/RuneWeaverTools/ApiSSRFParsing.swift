// Rune Weaver Tools — SSRF address parsing and origin classification.
//
// Purpose: canonicalize resolver-accepted IPv4 spellings, IPv6 literals, and
// origin forms before any range decision, so obfuscated hosts cannot bypass
// the guard. Scope: parsing plus loopback, link-local, and private-range
// classification only, with no DNS or dial decisions. Architectural role:
// single-source parsing layer backing `ApiSSRFGuard`; every range check
// enters through these helpers so fetch and API paths cannot diverge.

import Foundation

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
/// obfuscated spellings canonicalize before any range decision. Parsers trim
/// manually rather than through the display-copy agreement because they need
/// the empty string plus numeric validation downstream, not nil-for-blank.
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

    /// Whether a cleaned host is a dotted IPv4-embedded IPv6 literal with a proven prefix.
    /// A valid tail alone cannot prove a literal: collapsing an unverified prefix onto an
    /// allowlisted tail would let garbage pass as the tail's origin without ever dialing it,
    /// so the prefix must parse with the tail occupying two hextets. Unproven forms stay DNS
    /// names and fail closed instead of passing as public literals.
    static func isValidDottedIPv6Literal(_ cleaned: String) -> Bool {
        guard cleaned.contains(":"), cleaned.contains(".") else { return false }
        guard let lastColon = cleaned.lastIndex(of: ":") else { return false }
        let tail = String(cleaned[cleaned.index(after: lastColon)...])
        guard !tail.isEmpty, !tail.contains(":"),
              canonicalIPv4Octets(tail) != nil
        else { return false }
        let prefix = String(cleaned[..<lastColon])
        return ipv6Hextets(prefix + ":0:0") != nil
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
/// Normalizers trim manually rather than through the display-copy agreement
/// because they must keep empty strings for downstream parsing plus bracket
/// and zone folding, not nil-for-blank.
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
        // Dotted-colon forms collapse only on a proven prefix: an unverified prefix must not
        // launder onto an allowlisted tail, so unproven forms stay distinct and fail closed via DNS.
        if cleaned.contains(":"), cleaned.contains(".") {
            guard ApiIPv4Parsing.isValidDottedIPv6Literal(cleaned),
                  let octets = ApiIPv4Parsing.canonicalIPv4Octets(cleaned)
            else { return cleaned }
            return "\(octets.firstOctet).\(octets.secondOctet).\(octets.thirdOctet).\(octets.fourthOctet)"
        }
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
        // IPv4-mapped tails decode numerically so zero-padded spellings collapse to one
        // verdict instead of relying on string suffixes; any sensitive mapped tail
        // (loopback 127/8, private, link-local, or 0/8) refuses like its dotted twin.
        if lowered.contains(":"), let groups = ApiIPv4Parsing.ipv6Hextets(lowered), groups.count == 8,
           groups[0] == 0, groups[1] == 0, groups[2] == 0, groups[3] == 0, groups[4] == 0,
           groups[5] == 0xFFFF
        {
            let value = (UInt32(groups[6]) << 16) | UInt32(groups[7])
            return isSensitiveIPv4Value(value)
        }
        return false
    }
}

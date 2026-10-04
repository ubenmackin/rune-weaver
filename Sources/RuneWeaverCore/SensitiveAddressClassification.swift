// Rune Weaver Core — Shared sensitive-address parsing and range classification.
//
// Purpose: canonicalize resolver-accepted IPv4 spellings, IPv6 literals, and
// origin forms before any range decision, so obfuscated hosts cannot bypass a
// security check. Scope: parsing plus loopback, link-local, private-range,
// shared/CGNAT, special-purpose reserved-block, cloud-metadata host matching,
// and mapped/translated/embedded IPv4-tail classification only, with no DNS or
// dial decisions.
// Architectural role: the engine's single-source classification layer — the
// SSRF egress guard and the formal policy invariant verifier both enter
// through these helpers, so credential-confinement and egress verdicts cannot
// diverge on alternate spellings of the same address.

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

/// Resolver-accepted IPv4 and IPv6 parsing shared by security checks.
///
/// Handles decimal, hex, octal, and short forms plus IPv4-mapped IPv6 so
/// obfuscated spellings canonicalize before any range decision. Parsers trim
/// manually rather than through the display-copy agreement because they need
/// the empty string plus numeric validation downstream, not nil-for-blank.
public enum SensitiveAddressParsing: Sendable {
    /// Parses one numeric IPv4 part in decimal, octal, or hex.
    public static func parseNumericPart(_ part: String) -> UInt32? {
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
    public static func ipv6Hextets(_ host: String) -> [UInt16]? {
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

    /// Parses IPv6 text into eight hextets, accepting the mixed dotted-tail form.
    ///
    /// `ipv6Hextets` deliberately rejects dots because callers need a
    /// pure-hextet verdict; this variant expands a dotted tail into the two
    /// hextets it denotes, so prefix classification (link-local, unique-local,
    /// and the IPv4-embedding prefixes) can run against the literal's own
    /// prefix instead of the dotted tail that normalization collapses to. The
    /// prefix must parse with two placeholder hextets appended, mirroring the
    /// dotted-literal proof the normalizer performs.
    /// - Parameter host: Raw or canonical host text.
    /// - Returns: Eight hextets, or nil when the text is not an IPv6 literal.
    static func ipv6HextetsExpandingDottedTail(_ host: String) -> [UInt16]? {
        let lowered = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard lowered.contains(":") else { return nil }
        guard lowered.contains(".") else { return ipv6Hextets(lowered) }
        guard let lastColon = lowered.lastIndex(of: ":") else { return nil }
        let tail = String(lowered[lowered.index(after: lastColon)...])
        guard !tail.isEmpty, !tail.contains(":"), let octets = canonicalIPv4Octets(tail) else { return nil }
        let prefix = String(lowered[..<lastColon])
        guard var groups = ipv6Hextets(prefix + ":0:0"), groups.count == 8 else { return nil }
        groups[6] = (UInt16(octets.firstOctet) << 8) | UInt16(octets.secondOctet)
        groups[7] = (UInt16(octets.thirdOctet) << 8) | UInt16(octets.fourthOctet)
        return groups
    }

    /// Parses any resolver-accepted IPv4 spelling to canonical octets.
    public static func canonicalIPv4Octets(_ host: String) -> IPv4Octets? {
        let cleaned = SensitiveAddressNormalization.cleanedHostBase(host)
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
    public static func isValidDottedIPv6Literal(_ cleaned: String) -> Bool {
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

/// Host normalization and origin comparison shared by security checks.
///
/// Canonicalizes bracketed IPv6, zone IDs, and trailing dots plus the
/// scheme-default port so allowlist exemptions compare `host:port` exactly.
/// Normalizers trim manually rather than through the display-copy agreement
/// because they must keep empty strings for downstream parsing plus bracket
/// and zone folding, not nil-for-blank.
public enum SensitiveAddressNormalization: Sendable {
    /// Trims a raw host to its comparable base form.
    public static func cleanedHostBase(_ host: String) -> String {
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
    public static func normalizedHost(_ host: String) -> String {
        let cleaned = cleanedHostBase(host)
        guard !cleaned.isEmpty else { return "" }
        // Dotted-colon forms collapse only on a proven prefix: an unverified prefix must not
        // launder onto an allowlisted tail, so unproven forms stay distinct and fail closed via DNS.
        if cleaned.contains(":"), cleaned.contains(".") {
            guard SensitiveAddressParsing.isValidDottedIPv6Literal(cleaned),
                  let octets = SensitiveAddressParsing.canonicalIPv4Octets(cleaned)
            else { return cleaned }
            return "\(octets.firstOctet).\(octets.secondOctet).\(octets.thirdOctet).\(octets.fourthOctet)"
        }
        if let octets = SensitiveAddressParsing.canonicalIPv4Octets(cleaned) {
            return "\(octets.firstOctet).\(octets.secondOctet).\(octets.thirdOctet).\(octets.fourthOctet)"
        }
        if cleaned.contains(":"), !cleaned.contains("."), let groups = SensitiveAddressParsing.ipv6Hextets(cleaned) {
            return groups.map { String(Int($0), radix: 16) }.joined(separator: ":")
        }
        return cleaned
    }

    /// Effective port for origin comparison, filling the scheme default.
    public static func effectivePort(for url: URL) -> Int {
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
    public static func originKey(for url: URL) -> String? {
        guard let host = url.host, !host.isEmpty else { return nil }
        return "\(normalizedHost(host)):\(effectivePort(for: url))"
    }
}

/// Sensitive-range classification shared by security checks.
///
/// Covers cloud-metadata hostnames and literals, loopback, link-local, private
/// RFC 1918, the shared address space (`100.64.0.0/10`, where cloud metadata
/// literals such as Alibaba's `100.100.100.200` answer), special-purpose
/// reserved IPv4 blocks, `0.0.0.0/8`, IPv6 unique-local addresses, and the
/// IPv4-embedding translation prefixes (mapped, translated, NAT64, 6to4, and
/// IPv4-compatible) so fetch, API, and policy-vault checks share one range
/// table.
public enum SensitiveAddressRanges: Sendable {
    /// Whether a host is in `169.254.0.0/16` (link-local, never allowlisted).
    public static func isLinkLocalIPv4(_ host: String) -> Bool {
        guard let value = ipv4Value(host) else { return false }
        return isLinkLocalIPv4Value(value)
    }

    /// Whether a host is IPv6 link-local (`fe80::/10`, never allowlisted).
    /// Mixed dotted-tail spellings parse through the shared expansion so
    /// `fe80::93.184.216.34` refuses like its `fe80::5db8:d822` twin instead
    /// of reading as the public tail once the prefix is dropped.
    public static func isLinkLocalIPv6(_ host: String) -> Bool {
        let cleaned = SensitiveAddressNormalization.cleanedHostBase(host)
        guard cleaned.contains(":") else { return false }
        guard let groups = SensitiveAddressParsing.ipv6HextetsExpandingDottedTail(cleaned) else { return false }
        return (groups[0] & 0xFFC0) == 0xFE80
    }

    /// Whether a host is IPv4 loopback (`127.0.0.0/8`).
    public static func isLoopbackIPv4(_ host: String) -> Bool {
        guard let octets = SensitiveAddressParsing.canonicalIPv4Octets(host) else { return false }
        return octets.firstOctet == 127
    }

    /// Whether a host is IPv6 loopback or unspecified.
    /// Mixed dotted-tail spellings expand to the hextets they denote, so
    /// `::0.0.0.1` classifies like its `::1` twin instead of reading as a
    /// plain dotted IPv4 after the prefix is dropped.
    public static func isLoopbackIPv6(_ host: String) -> Bool {
        let cleaned = SensitiveAddressNormalization.cleanedHostBase(host)
        guard cleaned.contains(":") else { return false }
        guard let groups = SensitiveAddressParsing.ipv6HextetsExpandingDottedTail(cleaned) else { return false }
        let allZero = groups.allSatisfy { $0 == 0 }
        if allZero {
            return true
        }
        return groups[0] == 0 && groups[1] == 0 && groups[2] == 0 && groups[3] == 0 && groups[4] == 0 && groups[5] == 0 && groups[6] == 0 && groups[7] == 1
    }

    /// Whether a host is a loopback equivalent.
    public static func isLoopbackHost(_ host: String) -> Bool {
        let cleaned = SensitiveAddressNormalization.cleanedHostBase(host)
        guard !cleaned.isEmpty else { return false }
        if cleaned == "localhost" {
            return true
        }
        if isLoopbackIPv6(cleaned) {
            return true
        }
        guard let octets = SensitiveAddressParsing.canonicalIPv4Octets(cleaned) else { return false }
        if octets.firstOctet == 127 {
            return true
        }
        if octets.firstOctet == 0, octets.secondOctet == 0, octets.thirdOctet == 0, octets.fourthOctet == 0 {
            return true
        }
        return false
    }

    /// Whether a 32-bit IPv4 value is in `169.254.0.0/16` (link-local).
    /// Value-level owner of the mask so host checks, resolved-address
    /// vetting, and the server LAN carve-out compose one boundary instead of
    /// re-deriving it from octets.
    public static func isLinkLocalIPv4Value(_ value: UInt32) -> Bool {
        (value & 0xFFFF_0000) == 0xA9FE_0000
    }

    /// Whether a 32-bit IPv4 value is in private RFC 1918 space
    /// (`10.0.0.0/8`, `172.16.0.0/12`, or `192.168.0.0/16`).
    /// Value-level owner of the three private masks so no caller drifts on a
    /// boundary.
    public static func isPrivateIPv4Value(_ value: UInt32) -> Bool {
        if (value & 0xFF00_0000) == 0x0A00_0000 {
            return true
        }
        if (value & 0xFFF0_0000) == 0xAC10_0000 {
            return true
        }
        if (value & 0xFFFF_0000) == 0xC0A8_0000 {
            return true
        }
        return false
    }

    /// Whether a 32-bit IPv4 value dials a sensitive range: loopback,
    /// `0.0.0.0/8`, link-local, private RFC 1918, shared address space
    /// (`100.64.0.0/10`, where Alibaba's metadata service answers at
    /// `100.100.100.200`), or a special-purpose reserved block that is never
    /// globally reachable (IETF protocol assignments, TEST-NET-1/2/3,
    /// benchmarking, deprecated 6to4 relay anycast, multicast, and the
    /// reserved `240.0.0.0/4` block including limited broadcast).
    /// Single-sourced so the API guard, the fetch guard, and the policy
    /// invariant verifier cannot diverge on obfuscated spellings, and so a
    /// cloud-metadata literal outside `169.254.0.0/16` cannot classify as
    /// public. Public unicast addresses stay unaffected.
    public static func isSensitiveIPv4Value(_ value: UInt32) -> Bool {
        // 127.0.0.0/8: loopback.
        if (value & 0xFF00_0000) == 0x7F00_0000 {
            return true
        }
        // 0.0.0.0/8: unspecified block.
        if (value & 0xFF00_0000) == 0x0000_0000 {
            return true
        }
        // 169.254.0.0/16: link-local.
        if isLinkLocalIPv4Value(value) {
            return true
        }
        // 10/8, 172.16/12, 192.168/16: private RFC 1918.
        if isPrivateIPv4Value(value) {
            return true
        }
        // 100.64.0.0/10: shared address space (RFC 6598 / CGNAT).
        if (value & 0xFFC0_0000) == 0x6440_0000 {
            return true
        }
        // 192.0.0.0/24: IETF protocol assignments.
        if (value & 0xFFFF_FF00) == 0xC000_0000 {
            return true
        }
        // 192.0.2.0/24: TEST-NET-1.
        if (value & 0xFFFF_FF00) == 0xC000_0200 {
            return true
        }
        // 192.88.99.0/24: deprecated 6to4 relay anycast.
        if (value & 0xFFFF_FF00) == 0xC058_6300 {
            return true
        }
        // 198.18.0.0/15: benchmarking.
        if (value & 0xFFFE_0000) == 0xC612_0000 {
            return true
        }
        // 198.51.100.0/24: TEST-NET-2.
        if (value & 0xFFFF_FF00) == 0xC633_6400 {
            return true
        }
        // 203.0.113.0/24: TEST-NET-3.
        if (value & 0xFFFF_FF00) == 0xCB00_7100 {
            return true
        }
        // 224.0.0.0/4: multicast.
        if (value & 0xF000_0000) == 0xE000_0000 {
            return true
        }
        // 240.0.0.0/4: reserved, including limited broadcast.
        if (value & 0xF000_0000) == 0xF000_0000 {
            return true
        }
        return false
    }

    /// Parses a canonical host to its 32-bit IPv4 value for range checks.
    public static func ipv4Value(_ host: String) -> UInt32? {
        guard let octets = SensitiveAddressParsing.canonicalIPv4Octets(host) else { return nil }
        return (UInt32(octets.firstOctet) << 24) | (UInt32(octets.secondOctet) << 16)
            | (UInt32(octets.thirdOctet) << 8) | UInt32(octets.fourthOctet)
    }

    /// The IPv4 address embedded in eight hextets by a translation prefix.
    ///
    /// Covers the fixed-offset IPv4-embedding prefixes the range table
    /// decodes — IPv4-mapped `::ffff:0:0/96`, IPv4-translated
    /// `::ffff:0:0:0/96`, NAT64 well-known `64:ff9b::/96` (RFC 6052) and
    /// local-use `64:ff9b:1::/48` (RFC 8215), 6to4 `2002::/16`, and
    /// IPv4-compatible `::/96`. Any other prefix returns nil so a native
    /// public IPv6 literal is never misread as an embedded address.
    /// - Parameter groups: Eight parsed hextets.
    /// - Returns: The embedded 32-bit IPv4 value, or nil when the prefix
    ///   embeds none.
    static func embeddedIPv4Value(in groups: [UInt16]) -> UInt32? {
        guard groups.count == 8 else { return nil }
        let tailValue = (UInt32(groups[6]) << 16) | UInt32(groups[7])
        // ::ffff:0:0/96 — IPv4-mapped.
        if groups[0] == 0, groups[1] == 0, groups[2] == 0, groups[3] == 0, groups[4] == 0, groups[5] == 0xFFFF {
            return tailValue
        }
        // ::ffff:0:0:0/96 — IPv4-translated (deprecated RFC 2765 form).
        if groups[0] == 0, groups[1] == 0, groups[2] == 0, groups[3] == 0, groups[4] == 0xFFFF, groups[5] == 0 {
            return tailValue
        }
        // 64:ff9b::/96 — NAT64 well-known prefix (RFC 6052).
        if groups[0] == 0x0064, groups[1] == 0xFF9B, groups[2] == 0, groups[3] == 0, groups[4] == 0, groups[5] == 0 {
            return tailValue
        }
        // 64:ff9b:1::/48 — local-use NAT64 prefix (RFC 8215): the embedded
        // IPv4 splits around the reserved u octet. The u bits are ignored
        // rather than required zero, so a malformed embedding cannot smuggle
        // the carried address past classification.
        if groups[0] == 0x0064, groups[1] == 0xFF9B, groups[2] == 0x0001 {
            return (UInt32(groups[3]) << 16) | (UInt32(groups[4] & 0x00FF) << 8) | UInt32(groups[5] >> 8)
        }
        // 2002::/16 — 6to4: the embedded IPv4 follows the prefix.
        if groups[0] == 0x2002 {
            return (UInt32(groups[1]) << 16) | UInt32(groups[2])
        }
        // ::/96 — IPv4-compatible (deprecated RFC 4291 form).
        if groups[0] == 0, groups[1] == 0, groups[2] == 0, groups[3] == 0, groups[4] == 0, groups[5] == 0 {
            return tailValue
        }
        return nil
    }

    /// Dotted-quad text of the IPv4 address an IPv6 literal embeds by a
    /// translation prefix, or nil when the literal embeds none.
    ///
    /// Single-sourced decode for the runtime SSRF guard, the fetch guard, and
    /// the policy verifier: a decoded link-local or metadata literal is
    /// refused even for an allowlisted name, so a NAT64, 6to4, or
    /// IPv4-compatible spelling cannot smuggle a never-dialable target past
    /// the exemption checks.
    /// - Parameter host: Raw or canonical host text.
    /// - Returns: Dotted-quad embedded address, or nil when none is embedded.
    public static func embeddedIPv4Literal(_ host: String) -> String? {
        let cleaned = SensitiveAddressNormalization.cleanedHostBase(host)
        guard cleaned.contains(":") else { return nil }
        guard let groups = SensitiveAddressParsing.ipv6HextetsExpandingDottedTail(cleaned),
              let value = embeddedIPv4Value(in: groups)
        else { return nil }
        let first = (value >> 24) & 0xFF
        let second = (value >> 16) & 0xFF
        let third = (value >> 8) & 0xFF
        let fourth = value & 0xFF
        return "\(first).\(second).\(third).\(fourth)"
    }

    /// Whether a canonical host is a sensitive IPv6 literal (loopback,
    /// link-local `fe80::/10`, unique-local `fc00::/7`, or an IPv4-embedding
    /// prefix whose decoded address is sensitive).
    ///
    /// The literal parses through the shared hextet reader, including mixed
    /// dotted-tail spellings, so prefix checks run against the literal's own
    /// prefix: `fe80::93.184.216.34` classifies like its `fe80::5db8:d822`
    /// twin instead of collapsing to the public tail. IPv4-embedding prefixes
    /// decode to the address they carry — IPv4-mapped, IPv4-translated, NAT64
    /// well-known and local-use, 6to4, and IPv4-compatible — and classify
    /// like the decoded address's dotted twin, so a translation spelling
    /// cannot masquerade as a plain public literal. Unique-local requires an
    /// IPv6 literal (a colon) plus the `fc00::/7` hextet mask, so DNS names
    /// like `fc.example.com` never false-positive.
    /// - Parameter canonical: Cleaned host text (raw literal also accepted).
    /// - Returns: True when the literal's own prefix or embedded address is
    ///   sensitive.
    public static func isSensitiveIPv6Host(_ canonical: String) -> Bool {
        let cleaned = SensitiveAddressNormalization.cleanedHostBase(canonical)
        guard cleaned.contains(":"),
              let groups = SensitiveAddressParsing.ipv6HextetsExpandingDottedTail(cleaned)
        else { return false }
        if groups.allSatisfy({ $0 == 0 }) {
            return true
        }
        if groups[0] == 0, groups[1] == 0, groups[2] == 0, groups[3] == 0,
           groups[4] == 0, groups[5] == 0, groups[6] == 0, groups[7] == 1
        {
            return true
        }
        if (groups[0] & 0xFFC0) == 0xFE80 {
            return true
        }
        if (groups[0] & 0xFE00) == 0xFC00 {
            return true
        }
        // Embedding prefixes decode numerically so zero-padded spellings
        // collapse to one verdict instead of relying on string suffixes; any
        // sensitive embedded address (loopback, private, shared/reserved,
        // link-local, or 0/8) refuses like its dotted twin, while a public
        // embedded address stays public.
        if let embedded = embeddedIPv4Value(in: groups) {
            return isSensitiveIPv4Value(embedded)
        }
        return false
    }

    /// Whether a raw host is a sensitive address literal without DNS.
    ///
    /// Covers loopback, unspecified, link-local `169.254.0.0/16` and
    /// `fe80::/10`, private RFC 1918, shared address space `100.64.0.0/10`
    /// (where Alibaba's metadata service answers), special-purpose reserved
    /// IPv4 blocks, `0.0.0.0/8`, unique-local `fc00::/7`, IPv4-mapped
    /// sensitive tails, and NAT64 (well-known and local-use), 6to4, and
    /// IPv4-compatible embedded spellings across decimal, hex, octal, short,
    /// and IPv6 forms.
    /// Only parsed literals and `localhost` classify true, so a public DNS
    /// name that merely starts with digits — or a `host:port` entry the
    /// binding comparison could never match — never false-positives.
    /// - Parameter host: Raw host from configuration, optionally bracketed.
    /// - Returns: True when the host is a sensitive literal target.
    public static func isSensitiveHostLiteral(_ host: String) -> Bool {
        let cleaned = SensitiveAddressNormalization.cleanedHostBase(host)
        guard !cleaned.isEmpty else { return false }
        if cleaned == "localhost" {
            return true
        }
        if cleaned.contains(":") {
            // Dotted-colon forms collapse only on a proven prefix: an unverified
            // prefix must not be decoded as a dotted tail, or `host:port` text
            // would masquerade as an address literal. Hextet-only forms must
            // parse as a full IPv6 literal before normalization.
            if cleaned.contains(".") {
                guard SensitiveAddressParsing.isValidDottedIPv6Literal(cleaned) else { return false }
            } else {
                guard SensitiveAddressParsing.ipv6Hextets(cleaned) != nil else { return false }
            }
            // Classify the literal's own prefix first: normalization collapses
            // a dotted tail onto its dotted IPv4, which would drop the prefix
            // along with every embedded-translation verdict it carries.
            if isSensitiveIPv6Host(cleaned) {
                return true
            }
            // Normalization collapses mapped and dotted tails to dotted IPv4,
            // so classify the collapsed form through the IPv4 table and every
            // remaining literal through the IPv6 table.
            let canonical = SensitiveAddressNormalization.normalizedHost(cleaned)
            guard let value = ipv4Value(canonical) else {
                return isSensitiveIPv6Host(canonical)
            }
            return isSensitiveIPv4Value(value)
        }
        guard let value = ipv4Value(cleaned) else { return false }
        return isSensitiveIPv4Value(value)
    }
}

// MARK: - Cloud Metadata Hosts

extension SensitiveAddressRanges {
    /// Well-known cloud metadata hostnames plus metadata address literals,
    /// refused even over public DNS and even when an allowlisted name resolves
    /// to them. Single-sourced here so the runtime SSRF guard and the policy
    /// invariant verifier cannot drift on what counts as a metadata target.
    public static let blockedMetadataHosts: Set<String> = [
        "metadata.google.internal",
        "metadata.google",
        "metadata.goog",
        "instance-data.compute.internal",
        "instance-data",
        "metadata.azure.internal",
        "metadata.aws.internal",
        "metadata",
        "169.254.169.254",
        "100.100.100.200"
    ]

    /// Whether a host is a well-known metadata hostname or metadata literal.
    /// Intent: exact plus dot-suffix match against the blocked set keeps
    /// subdomains like `sub.metadata.google.internal` refused while
    /// `foo-metadata.google-bar.example.com` passes; substring matching
    /// would overblock the latter, and an address literal such as
    /// `100.100.100.200` matches exactly so it is refused before any allowlist
    /// exemption. Invariant: comparison uses the cleaned lowercased base form,
    /// and empty hosts never match.
    public static func isMetadataHost(_ host: String) -> Bool {
        let lowered = SensitiveAddressNormalization.cleanedHostBase(host)
        guard !lowered.isEmpty else { return false }
        if blockedMetadataHosts.contains(lowered) {
            return true
        }
        // Dot-suffix covers subdomains of a blocked name without substring overblocking.
        return blockedMetadataHosts.contains { lowered.hasSuffix("." + $0) }
    }
}

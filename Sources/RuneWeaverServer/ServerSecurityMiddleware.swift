// Rune Weaver Server — HTTP-layer defense middleware: Host gate plus shared security headers.
//
// The owner bearer gate owns who may call the engine; this file owns how the
// HTTP layer itself resists rebinding and passive sniffing. The Host gate keeps
// a rebinding DNS name from reaching the engine through an allowed socket, and
// the shared headers (nosniff, DENY framing, referrer policy, fail-closed CSP,
// proxy-aware HSTS) ride every response including the Host gate's own early
// rejections, so no rejection path can be fingerprinted by missing headers.
// The server configuration installs both in the middleware chain; the Host gate
// additionally applies the shared headers to its own early rejections instead
// of duplicating the header list.

import Foundation
import RuneWeaverCore
import RuneWeaverTools
import Vapor

/// Vapor middleware validating inbound HTTP Host headers to protect against DNS rebinding.
public struct HostValidationMiddleware: AsyncMiddleware, Sendable {
    /// Permitted hosts (lowercased, without port).
    public let allowedHosts: Set<String>
    /// Whether missing Host headers should be permitted in testing environments.
    public let allowMissingHostInTesting: Bool
    /// Whether private-LAN Host values are accepted beside the explicit allowlist.
    ///
    /// True only for an all-interfaces bind (`0.0.0.0`, `::`, or `[::]`) with owner auth
    /// configured, so a loopback-only bind never widens to LAN ranges and an
    /// unauthenticated all-interfaces bind stays fail-closed on the explicit set.
    private let allowsLANRanges: Bool

    /// Creates host validation middleware allowing standard loopback hosts plus the server's configured hostname.
    /// - Parameters:
    ///   - hostname: Configured bind hostname.
    ///   - allowMissingHostInTesting: When true, requests in `.testing` without a Host header are allowed.
    public init(hostname: String, allowMissingHostInTesting: Bool = true) {
        self.init(hostname: hostname, allowedHosts: [], authConfigured: false, allowMissingHostInTesting: allowMissingHostInTesting)
    }

    /// Creates host validation middleware bound to the runtime bind policy plus explicit hosts.
    ///
    /// The bind policy and the Host gate share one decision: an all-interfaces
    /// bind with auth opens the LAN family (loopback, the literal bind, RFC 1918
    /// plus link-local IPv4, IPv6 ULA plus link-local, `.local` names, and the
    /// explicit entries), while any other bind stays strict on loopback plus the
    /// literal plus the explicit entries with no automatic LAN ranges.
    /// - Parameters:
    ///   - hostname: Configured bind hostname.
    ///   - allowedHosts: Explicit `allowed_hosts` entries, matched exact-only after lowercasing plus port stripping.
    ///   - authConfigured: Whether a resolvable owner token guards this bind.
    ///   - allowMissingHostInTesting: When true, requests in `.testing` without a Host header are allowed.
    public init(
        hostname: String,
        allowedHosts explicitHosts: [String],
        authConfigured: Bool,
        allowMissingHostInTesting: Bool = true
    ) {
        var hosts: Set = ["127.0.0.1", "localhost", "::1", "[::1]"]
        let trimmed = hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Trailing FQDN dots never gate: validators reject them fail-closed,
        // so a trailing-dot hostname (including a bare `.`) inserts nothing
        // here and fails closed like any other trailing-dot host instead of
        // riding the gate under a stripped spelling that never matches exactly.
        // Enforce the DNS name bound on the bind hostname so an over-long value
        // never widens the gate; file-load and ServeCommand already reject it,
        // while a hand-built context stays fail-closed here.
        if !trimmed.isEmpty, trimmed != ".", !trimmed.hasSuffix("."), trimmed.count <= ServerEndpointConfig.maxAllowedHostLength {
            hosts.insert(trimmed)
            // Clients send IPv6 literals bracketed or bare, so both spellings are
            // stored to keep the comparison exact without canonicalizing inbound Hosts.
            if trimmed.contains(":") {
                if trimmed.hasPrefix("["), trimmed.hasSuffix("]"), trimmed.count >= 2 {
                    let bare = String(trimmed.dropFirst().dropLast())
                    if !bare.isEmpty {
                        hosts.insert(bare)
                    }
                } else if !trimmed.hasPrefix("[") {
                    hosts.insert("[\(trimmed)]")
                }
            }
        }
        // Single-sourced through `dedupeNormalizedBootHosts` because the
        // explicit entries are already-bounded stored values: the raw count
        // was capped at write time by file-load and the settings PUT (which
        // keep `dedupeNormalizedHosts` for raw input), so re-applying the
        // raw-count prefix here would truncate an already-expanded store —
        // 11 IPv6 entries persist as 22 (bracketed plus bare) and must gate
        // as 22 instead of being cut back to 20. Widening shapes and
        // trailing-dot entries drop fail-closed through the shared
        // `RuneWeaverConfig.validateAllowedHosts` check inside the dedupe
        // instead of allowlisting a carved fragment, and IPv6 counterparts
        // ride along.
        for entry in ServerEndpointConfig.dedupeNormalizedBootHosts(explicitHosts) {
            hosts.insert(entry)
        }
        self.allowedHosts = hosts
        self.allowMissingHostInTesting = allowMissingHostInTesting
        self.allowsLANRanges = Self.isAllInterfacesBind(trimmed) && authConfigured
    }

    /// Whether a bind hostname listens on every interface.
    ///
    /// Only the IPv4 and IPv6 unspecified addresses widen the Host gate; a LAN
    /// IP bind (for example `192.168.1.20`) stays strict on its literal plus the
    /// explicit entries so one device does not implicitly authorize the whole subnet.
    /// - Parameter hostname: Trimmed, lowercased bind hostname.
    /// - Returns: True for `0.0.0.0`, `::`, or `[::]`.
    public static func isAllInterfacesBind(_ hostname: String) -> Bool {
        let trimmed = hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed == "0.0.0.0" || trimmed == "::" || trimmed == "[::]"
    }

    /// Whether a normalized Host is reachable on an authenticated all-interfaces bind.
    ///
    /// Covers only the LAN family the owner implicitly trusts by binding
    /// all-interfaces with auth: private IPv4, ULA plus link-local IPv6, and
    /// `.local` names. Public IPs and DNS names still fail closed to the
    /// explicit allowlist so a rebinding host cannot ride the LAN opening.
    /// - Parameter host: Lowercased, port-stripped Host from ``extractHost(from:)``.
    /// - Returns: True for a LAN-family host.
    public static func isLANAllowedHost(_ host: String) -> Bool {
        guard !host.isEmpty else { return false }
        if isPrivateIPv4LANHost(host) {
            return true
        }
        if isPrivateIPv6LANHost(host) {
            return true
        }
        return isLocalMDNSHost(host)
    }

    /// Whether a normalized Host is private IPv4 (RFC 1918) or link-local.
    ///
    /// Decimal dotted quads only: hex, octal, or short forms never open the LAN
    /// path and stay on the explicit allowlist instead, so obfuscated spellings
    /// cannot slip past the range check. The LAN family is exactly `10/8`,
    /// `172.16/12`, `192.168/16`, and `169.254/16`, composed from the
    /// sensitive-range table's per-family predicates so a widening of that
    /// table (shared address space, TEST-NET, benchmarking, multicast,
    /// reserved) can never silently widen this gate; loopback and the
    /// unspecified block stay off the LAN path because they belong on the
    /// explicit allowlist.
    /// - Parameter host: Lowercased, port-stripped Host.
    /// - Returns: True for `10/8`, `172.16/12`, `192.168/16`, or `169.254/16`.
    public static func isPrivateIPv4LANHost(_ host: String) -> Bool {
        guard let octets = parseIPv4Octets(host), octets.count == 4 else { return false }
        guard octets[0] != 0, octets[0] != 127 else { return false }
        // Built from the strict octets above rather than re-parsing, so the
        // value tested here is exactly the spelling the shape gate approved.
        let value = (UInt32(octets[0]) << 24) | (UInt32(octets[1]) << 16)
            | (UInt32(octets[2]) << 8) | UInt32(octets[3])
        // Deliberately narrower than the sensitive-egress table: composing the
        // two per-family predicates keeps the masks single-sourced without
        // inheriting shared/reserved blocks as LAN hosts.
        return ApiSSRFGuard.isPrivateIPv4Value(value) || ApiSSRFGuard.isLinkLocalIPv4Value(value)
    }

    /// Parses a decimal dotted quad without resolver-accepted obfuscation.
    /// - Parameter host: Candidate Host value.
    /// - Returns: Four octets, or nil when the shape is not a plain dotted quad.
    public static func parseIPv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        octets.reserveCapacity(4)
        for part in parts {
            // ASCII digits only: `Character.isNumber` accepts Unicode digits
            // that `Int` would reject inconsistently, so require 0-9 here.
            guard !part.isEmpty, part.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return nil }
            // A leading zero would be ambiguous with octal on some resolvers, so
            // multi-digit zero-prefixed parts stay off the LAN path and fail
            // closed to the explicit allowlist.
            if part.count > 1, part.hasPrefix("0") {
                return nil
            }
            guard let value = Int(part), (0 ... 255).contains(value) else { return nil }
            octets.append(value)
        }
        return octets
    }

    /// Whether a normalized Host is IPv6 ULA (`fc00::/7`) or link-local (`fe80::/10`).
    ///
    /// Bracketed and bare spellings both qualify because ``extractHost(from:)``
    /// preserves the caller's brackets; the zone suffix (`%eth0`) is ignored for
    /// the range decision since it names an interface, not an address change.
    /// - Parameter host: Lowercased, port-stripped Host.
    /// - Returns: True for ULA or link-local literals.
    public static func isPrivateIPv6LANHost(_ host: String) -> Bool {
        var candidate = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if candidate.hasPrefix("["), candidate.hasSuffix("]"), candidate.count >= 2 {
            candidate = String(candidate.dropFirst().dropLast())
        }
        if let percent = candidate.firstIndex(of: "%") {
            candidate = String(candidate[..<percent])
        }
        guard candidate.contains(":"), !candidate.contains(".") else { return false }
        guard let groups = ipv6Hextets(candidate) else { return false }
        // fc00::/7 (Unique Local Address): top seven bits 1111110.
        if (groups[0] & 0xFE00) == 0xFC00 {
            return true
        }
        // fe80::/10 (Link-Local): top ten bits 1111111010.
        if (groups[0] & 0xFFC0) == 0xFE80 {
            return true
        }
        return false
    }

    /// Parses IPv6 text into eight hextets for the ULA plus link-local masks.
    ///
    /// Single-sourced through `ApiSSRFGuard.ipv6Hextets` so the Host gate and
    /// the SSRF guard parse literals identically instead of drifting on a
    /// forked copy; dotted forms stay DNS names here because an embedded IPv4
    /// tail belongs to the IPv4 range check, not this literal path.
    /// - Parameter host: Unbracketed, zoneless, lowercased literal.
    /// - Returns: Eight hextets, or nil when the text is not a plain IPv6 literal.
    public static func ipv6Hextets(_ host: String) -> [UInt16]? {
        ApiSSRFGuard.ipv6Hextets(host)
    }

    /// Whether a normalized Host is a lowercase `.local` mDNS name.
    ///
    /// The input is already lowercased by ``extractHost(from:)``, so the suffix
    /// check itself enforces lowercase; a trailing FQDN dot fails closed to
    /// the explicit allowlist like any other punctuation. Each
    /// dot-separated label must be non-empty, at most 63 characters, and must
    /// not start or end with a dash so shapes like `...local` or `-.local`
    /// never open the LAN path.
    /// - Parameter host: Lowercased, port-stripped Host.
    /// - Returns: True for names ending in `.local`.
    public static func isLocalMDNSHost(_ host: String) -> Bool {
        guard !host.isEmpty else { return false }
        // A trailing FQDN dot never opens the LAN path: validators reject
        // trailing-dot hosts fail-closed, so `studio.local.` stays closed
        // here instead of riding the gate under a stripped spelling.
        let candidate = host
        guard candidate.hasSuffix(".local") else { return false }
        guard candidate.count > ".local".count else { return false }
        guard candidate.count <= 253 else { return false }
        guard !candidate.contains(":"), !candidate.contains("/") else { return false }
        guard !candidate.contains("?"), !candidate.contains("#"), !candidate.contains("@") else { return false }
        guard !candidate.contains(" "), !candidate.contains("\t") else { return false }
        guard !candidate.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-._")
        guard candidate.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        let labels = candidate.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.last == "local" else { return false }
        for label in labels {
            guard !label.isEmpty, label.count <= 63 else { return false }
            guard !label.hasPrefix("-"), !label.hasSuffix("-") else { return false }
        }
        return true
    }

    /// Whether a normalized Host passes this middleware's gate.
    /// - Parameter host: Lowercased, port-stripped Host from ``extractHost(from:)``.
    /// - Returns: True for the explicit allowlist, or for the LAN family when the bind opened it.
    public func isAllowedHost(_ host: String) -> Bool {
        if allowedHosts.contains(host) {
            return true
        }
        guard allowsLANRanges else { return false }
        return Self.isLANAllowedHost(host)
    }

    /// Normalizes and extracts the host component from a raw Host header value.
    /// Single-sourced through `ServerEndpointConfig.normalizeHost` in Core so
    /// the gate, the settings PUT, and file-load validation compare under
    /// identical semantics.
    public static func extractHost(from hostHeader: String) -> String {
        ServerEndpointConfig.normalizeHost(hostHeader)
    }

    public func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard let hostHeader = request.headers.first(name: .host) else {
            if allowMissingHostInTesting, request.application.environment == .testing {
                return try await next.respond(to: request)
            }
            // Route the missing-host branch through the shared security headers
            // so it carries the same nosniff/DENY/referrer policy plus
            // proxy-aware HSTS as every other response.
            let response = Response(
                status: .badRequest,
                headers: HTTPHeaders([
                    ("Content-Type", "application/json; charset=utf-8"),
                    ("Cache-Control", "no-store")
                ]),
                body: .init(string: #"{"error":"missing host header"}"#)
            )
            GlobalSecurityHeadersMiddleware.apply(to: response, for: request)
            return response
        }

        let host = Self.extractHost(from: hostHeader)
        guard isAllowedHost(host) else {
            RuneWeaverLog.server.warning("HostValidationMiddleware rejected invalid Host header: \(hostHeader)")
            // Route the 403 branch through the shared security headers so a
            // rebinding rejection cannot be fingerprinted by missing headers
            // and still carries proxy-aware HSTS when served behind TLS.
            let response = Response(
                status: .forbidden,
                headers: HTTPHeaders([
                    ("Content-Type", "application/json; charset=utf-8"),
                    ("Cache-Control", "no-store")
                ]),
                body: .init(string: #"{"error":"invalid host header"}"#)
            )
            GlobalSecurityHeadersMiddleware.apply(to: response, for: request)
            return response
        }

        return try await next.respond(to: request)
    }
}

/// Middleware injecting defense-in-depth HTTP security headers into all responses.
public struct GlobalSecurityHeadersMiddleware: AsyncMiddleware, Sendable {
    public init() {}

    /// Applies the shared security headers to a response.
    ///
    /// Single-sourced so the Host gate's early rejections carry the same
    /// nosniff/DENY/referrer policy plus proxy-aware HSTS as the middleware
    /// path instead of drifting on a duplicated header list.
    /// - Parameters:
    ///   - response: Response receiving the headers.
    ///   - request: Inbound request deciding proxy-aware HSTS.
    public static func apply(to response: Response, for request: Request) {
        response.headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        response.headers.replaceOrAdd(name: "X-Frame-Options", value: "DENY")
        response.headers.replaceOrAdd(name: "Referrer-Policy", value: "strict-origin-when-cross-origin")
        if !response.headers.contains(name: "Content-Security-Policy") {
            response.headers.replaceOrAdd(name: "Content-Security-Policy", value: "default-src 'none'; frame-ancestors 'none'; base-uri 'none';")
        }
        if ServerAuthRequest.isRequestSecure(request) {
            response.headers.replaceOrAdd(name: "Strict-Transport-Security", value: "max-age=31536000; includeSubDomains")
        }
    }

    public func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let response = try await next.respond(to: request)
        Self.apply(to: response, for: request)
        return response
    }
}

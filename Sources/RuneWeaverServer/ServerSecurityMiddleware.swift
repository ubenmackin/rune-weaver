// Rune Weaver Server — HTTP-layer defense middleware: Host gate plus shared security headers.

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
    private let allowsLANRanges: Bool

    /// Creates host validation middleware allowing standard loopback hosts plus the server's
    /// configured hostname.
    public init(hostname: String, allowMissingHostInTesting: Bool = true) {
        self.init(hostname: hostname, allowedHosts: [], authConfigured: false, allowMissingHostInTesting: allowMissingHostInTesting)
    }

    /// Creates host validation middleware bound to the runtime bind policy plus explicit hosts.
    public init(
        hostname: String,
        allowedHosts explicitHosts: [String],
        authConfigured: Bool,
        allowMissingHostInTesting: Bool = true
    ) {
        var hosts: Set = ["127.0.0.1", "localhost", "::1", "[::1]"]
        let trimmed = hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Trailing FQDN dots never gate: validators reject them fail-closed, so a trailing-dot
        // hostname (including a bare `.`) inserts nothing here and fails closed like any other
        // trailing-dot host instead of riding the gate under a stripped spelling that never matches.
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
        // Uses `dedupeNormalizedBootHosts` since explicit entries are already-bounded stored values;
        // re-applying the raw-count prefix would truncate expanded stores (e.g. 11 IPv6 entries persist
        // as 22 bracketed/bare forms and must gate as 22 rather than being cut to 20).
        for entry in ServerEndpointConfig.dedupeNormalizedBootHosts(explicitHosts) {
            hosts.insert(entry)
        }
        self.allowedHosts = hosts
        self.allowMissingHostInTesting = allowMissingHostInTesting
        self.allowsLANRanges = Self.isAllInterfacesBind(trimmed) && authConfigured
    }

    /// Whether a bind hostname listens on every interface.
    public static func isAllInterfacesBind(_ hostname: String) -> Bool {
        let trimmed = hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed == "0.0.0.0" || trimmed == "::" || trimmed == "[::]"
    }

    /// Whether a normalized Host is reachable on an authenticated all-interfaces bind.
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
    public static func ipv6Hextets(_ host: String) -> [UInt16]? {
        ApiSSRFGuard.ipv6Hextets(host)
    }

    /// Whether a normalized Host is a lowercase `.local` mDNS name.
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

    /// Applies the shared security headers to a response. - request: Inbound request deciding
    /// proxy-aware HSTS.
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

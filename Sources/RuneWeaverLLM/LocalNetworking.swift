// Rune Weaver LLM — Portable LAN Resolution under App Transport Security.
//
// Resolves cleartext HTTP local-network endpoints with multi-label hostnames
// to RFC 1918 / RFC 4193 private IP addresses, transparently rewriting request
// targets while preserving the Host header. Ensures self-hosted LLM endpoints
// on private LANs work out-of-the-box under NSAllowsLocalNetworking without
// compromising default-deny ATS security on the public Internet.

import Darwin
import Foundation

/// Helpers for resolving private local network endpoints under Apple App Transport Security (ATS).
///
/// ATS permits cleartext HTTP to RFC 1918 / RFC 4193 private IP addresses and `.local`
/// mDNS names when `NSAllowsLocalNetworking` is enabled in `Info.plist`. However, ATS
/// treats multi-label hostnames with dots (e.g. `nas.int.example.com` or `ollama.lan`)
/// as external Internet domains, blocking cleartext even when DNS points to a private LAN IP.
///
/// This module resolves multi-label local hostnames to their private IP addresses at request
/// time and preserves the original `Host` header, allowing Rune Weaver to communicate with
/// any self-hosted LLM on a private home or office network without weakening ATS globally
/// or hardcoding domain names into the application bundle.
public enum LocalNetworking {
    /// Checks whether an IPv4 address string falls into an RFC 1918 private range,
    /// loopback (127.0.0.0/8), or link-local (169.254.0.0/16).
    /// - Parameter ipAddress: IPv4 address string (e.g. "192.168.1.50").
    /// - Returns: True when the address is private, loopback, or link-local.
    public static func isPrivateIPv4Address(_ ipAddress: String) -> Bool {
        var addr = in_addr()
        guard inet_pton(AF_INET, ipAddress, &addr) == 1 else { return false }
        let hostByteOrder = UInt32(bigEndian: addr.s_addr)
        // 10.0.0.0/8: 0x0A000000 - 0x0AFFFFFF
        if (hostByteOrder & 0xFF00_0000) == 0x0A00_0000 {
            return true
        }
        // 172.16.0.0/12: 0xAC100000 - 0xAC1FFFFF
        if (hostByteOrder & 0xFFF0_0000) == 0xAC10_0000 {
            return true
        }
        // 192.168.0.0/16: 0xC0A80000 - 0xC0A8FFFF
        if (hostByteOrder & 0xFFFF_0000) == 0xC0A8_0000 {
            return true
        }
        // 127.0.0.0/8: loopback
        if (hostByteOrder & 0xFF00_0000) == 0x7F00_0000 {
            return true
        }
        // 169.254.0.0/16: link-local
        if (hostByteOrder & 0xFFFF_0000) == 0xA9FE_0000 {
            return true
        }
        return false
    }

    /// Checks whether an IPv6 address string falls into an RFC 4193 Unique Local range (fc00::/7),
    /// link-local (fe80::/10), or loopback (::1).
    /// - Parameter ipAddress: IPv6 address string.
    /// - Returns: True when the address is private, loopback, or link-local.
    public static func isPrivateIPv6Address(_ ipAddress: String) -> Bool {
        var clean = ipAddress
        if clean.hasPrefix("["), clean.hasSuffix("]") {
            clean = String(clean.dropFirst().dropLast())
        }
        var addr = in6_addr()
        guard inet_pton(AF_INET6, clean, &addr) == 1 else { return false }
        let firstByte = addr.__u6_addr.__u6_addr8.0
        // fc00::/7 (Unique Local Address)
        if (firstByte & 0xFE) == 0xFC {
            return true
        }
        // fe80::/10 (Link-Local)
        let secondByte = addr.__u6_addr.__u6_addr8.1
        if firstByte == 0xFE, (secondByte & 0xC0) == 0x80 {
            return true
        }
        // ::1 (Loopback)
        let bytes = Mirror(reflecting: addr.__u6_addr.__u6_addr8).children.compactMap { $0.value as? UInt8 }
        if bytes.count == 16, bytes.prefix(15).allSatisfy({ $0 == 0 }), bytes.last == 1 {
            return true
        }
        return false
    }

    /// Checks whether an IP address string is a private IPv4 or IPv6 address.
    /// - Parameter ipAddress: IP address string.
    /// - Returns: True when the address is private or loopback.
    public static func isPrivateIPAddress(_ ipAddress: String) -> Bool {
        isPrivateIPv4Address(ipAddress) || isPrivateIPv6Address(ipAddress)
    }

    /// Thread-safe in-memory cache for resolved private IP addresses.
    ///
    /// Caches resolution results across the process lifetime to eliminate blocking DNS latency
    /// on repeated HTTP client instantiations. Cached entries expire after the configured TTL
    /// (default 300 seconds), ensuring IP migrations or DNS updates take effect without requiring
    /// process restarts.
    private final class DNSCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: (resolvedIP: String?, timestamp: Date)] = [:]
        let defaultTTL: TimeInterval

        init(defaultTTL: TimeInterval = 300) {
            self.defaultTTL = defaultTTL
        }

        func get(_ host: String, ttl: TimeInterval) -> (found: Bool, resolvedIP: String?) {
            lock.lock()
            defer { lock.unlock() }
            guard let entry = entries[host] else { return (false, nil) }
            if Date().timeIntervalSince(entry.timestamp) < ttl {
                return (true, entry.resolvedIP)
            }
            entries.removeValue(forKey: host)
            return (false, nil)
        }

        func set(_ host: String, resolvedIP: String?) {
            lock.lock()
            defer { lock.unlock() }
            entries[host] = (resolvedIP: resolvedIP, timestamp: Date())
        }

        func clear() {
            lock.lock()
            defer { lock.unlock() }
            entries.removeAll()
        }
    }

    private static let cache = DNSCache()

    /// Clears the memoized DNS resolution cache.
    public static func clearCache() {
        cache.clear()
    }

    /// Resolves a hostname to a private IP address if it points to an RFC 1918 / RFC 4193 host.
    ///
    /// Results are memoized in an `NSLock`-guarded cache for the specified TTL (default 300 seconds)
    /// to eliminate blocking DNS queries on repeated HTTP client creations.
    /// - Parameters:
    ///   - host: Hostname to resolve (e.g. "nas.int.example.com").
    ///   - ttl: Maximum age in seconds of a cached DNS resolution result.
    /// - Returns: The resolved private IP address string, or nil if the host does not resolve to a private IP.
    public static func resolvePrivateIP(for host: String, ttl: TimeInterval = 300) -> String? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased() == "localhost" {
            return "127.0.0.1"
        }
        if isPrivateIPAddress(trimmed) {
            return trimmed
        }

        let cached = cache.get(trimmed, ttl: ttl)
        if cached.found {
            return cached.resolvedIP
        }

        let resolved = performDNSLookup(trimmed)
        cache.set(trimmed, resolvedIP: resolved)
        return resolved
    }

    private static func performDNSLookup(_ host: String) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM

        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let head = res else {
            return nil
        }
        defer { freeaddrinfo(head) }

        var curr: UnsafeMutablePointer<addrinfo>? = head
        while let ptr = curr {
            if ptr.pointee.ai_family == AF_INET {
                var addr = ptr.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if let cStr = inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) {
                    let ipStr = String(cString: cStr)
                    if isPrivateIPv4Address(ipStr) {
                        return ipStr
                    }
                }
            } else if ptr.pointee.ai_family == AF_INET6 {
                var addr = ptr.pointee.ai_addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                if let cStr = inet_ntop(AF_INET6, &addr, &buffer, socklen_t(INET6_ADDRSTRLEN)) {
                    let ipStr = String(cString: cStr)
                    if isPrivateIPv6Address(ipStr) {
                        return ipStr
                    }
                }
            }
            curr = ptr.pointee.ai_next
        }
        return nil
    }

    /// Rewrites a cleartext HTTP URL to use its resolved RFC 1918 / RFC 4193 private IP,
    /// returning the rewritten URL along with the original `Host` header to preserve virtual host routing.
    ///
    /// If the URL is HTTPS, loopback, `.local`, already a private IP, or resolves to a public IP,
    /// the URL is returned unchanged with a nil host header.
    /// - Parameters:
    ///   - url: Endpoint URL to inspect.
    ///   - resolver: Optional resolver closure for testing or custom resolution; defaults to `resolvePrivateIP(for:)`.
    /// - Returns: Tuple of effective target URL and optional original Host header to set on requests.
    public static func resolvedLocalTarget(
        for url: URL,
        resolver: (String) -> String? = { resolvePrivateIP(for: $0) }
    ) -> (url: URL, originalHost: String?) {
        guard url.scheme?.lowercased() == "http", let host = url.host, !host.isEmpty else {
            return (url, nil)
        }
        let lower = host.lowercased()
        if lower == "localhost" || lower == "127.0.0.1" || lower == "::1" || lower.hasSuffix(".local") || !host.contains(".") {
            return (url, nil)
        }
        if isPrivateIPAddress(host) {
            return (url, nil)
        }
        guard let privateIP = resolver(host) else {
            return (url, nil)
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard components != nil else { return (url, nil) }
        let formattedHost = if privateIP.contains(":"), !privateIP.hasPrefix("[") {
            "[\(privateIP)]"
        } else {
            privateIP
        }
        components?.host = formattedHost
        guard let targetURL = components?.url else { return (url, nil) }

        let originalHost: String = if let port = url.port {
            "\(host):\(port)"
        } else {
            host
        }
        return (targetURL, originalHost)
    }
}

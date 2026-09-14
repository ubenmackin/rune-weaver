// Rune Weaver LLM Tests — Local Networking Resolution under App Transport Security.
//
// Verifies RFC 1918 / RFC 4193 IP address classification, DNS memoization,
// and deterministic URL target rewriting with Host header preservation.

import Foundation
@testable import RuneWeaverLLM
import Testing

@Suite("Local Networking ATS")
struct LocalNetworkingTests {
    @Test
    func `IPv4 private and public address classification`() {
        // RFC 1918 10.0.0.0/8
        #expect(LocalNetworking.isPrivateIPv4Address("10.0.0.1"))
        #expect(LocalNetworking.isPrivateIPv4Address("10.100.100.100"))
        #expect(LocalNetworking.isPrivateIPv4Address("10.255.255.255"))

        // RFC 1918 172.16.0.0/12
        #expect(LocalNetworking.isPrivateIPv4Address("172.16.0.1"))
        #expect(LocalNetworking.isPrivateIPv4Address("172.31.255.255"))
        #expect(!LocalNetworking.isPrivateIPv4Address("172.15.255.255"))
        #expect(!LocalNetworking.isPrivateIPv4Address("172.32.0.1"))

        // RFC 1918 192.168.0.0/16
        #expect(LocalNetworking.isPrivateIPv4Address("192.168.0.1"))
        #expect(LocalNetworking.isPrivateIPv4Address("192.168.1.50"))
        #expect(LocalNetworking.isPrivateIPv4Address("192.168.255.255"))

        // Loopback & Link-local
        #expect(LocalNetworking.isPrivateIPv4Address("127.0.0.1"))
        #expect(LocalNetworking.isPrivateIPv4Address("169.254.1.1"))

        // Public IPs
        #expect(!LocalNetworking.isPrivateIPv4Address("8.8.8.8"))
        #expect(!LocalNetworking.isPrivateIPv4Address("1.1.1.1"))
        #expect(!LocalNetworking.isPrivateIPv4Address("93.184.216.34"))
        #expect(!LocalNetworking.isPrivateIPv4Address("not-an-ip"))
    }

    @Test
    func `IPv6 private and public address classification`() {
        // Loopback
        #expect(LocalNetworking.isPrivateIPv6Address("::1"))

        // RFC 4193 Unique Local fc00::/7
        #expect(LocalNetworking.isPrivateIPv6Address("fc00::1"))
        #expect(LocalNetworking.isPrivateIPv6Address("fd00::1234"))
        #expect(LocalNetworking.isPrivateIPv6Address("fd12:3456:789a:1::1"))

        // Link-Local fe80::/10
        #expect(LocalNetworking.isPrivateIPv6Address("fe80::1"))
        #expect(LocalNetworking.isPrivateIPv6Address("febf::ffff"))

        // Public IPv6
        #expect(!LocalNetworking.isPrivateIPv6Address("2001:4860:4860::8888"))
        #expect(!LocalNetworking.isPrivateIPv6Address("2606:4700:4700::1111"))
        #expect(!LocalNetworking.isPrivateIPv6Address("invalid-ipv6"))
    }

    @Test
    func `Resolved local target skips HTTPS, localhost, raw IPs, and .local domains`() throws {
        let httpsURL = try #require(URL(string: "https://api.openai.com/v1"))
        let (u1, h1) = LocalNetworking.resolvedLocalTarget(for: httpsURL)
        #expect(u1 == httpsURL)
        #expect(h1 == nil)

        let localhostURL = try #require(URL(string: "http://localhost:11434/v1"))
        let (u2, h2) = LocalNetworking.resolvedLocalTarget(for: localhostURL)
        #expect(u2 == localhostURL)
        #expect(h2 == nil)

        let loopbackIP = try #require(URL(string: "http://127.0.0.1:11434/v1"))
        let (u3, h3) = LocalNetworking.resolvedLocalTarget(for: loopbackIP)
        #expect(u3 == loopbackIP)
        #expect(h3 == nil)

        let rawPrivateIP = try #require(URL(string: "http://192.168.1.50:11434/v1"))
        let (u4, h4) = LocalNetworking.resolvedLocalTarget(for: rawPrivateIP)
        #expect(u4 == rawPrivateIP)
        #expect(h4 == nil)

        let mDNSURL = try #require(URL(string: "http://nas.local:11434/v1"))
        let (u5, h5) = LocalNetworking.resolvedLocalTarget(for: mDNSURL)
        #expect(u5 == mDNSURL)
        #expect(h5 == nil)

        let unqualifiedURL = try #require(URL(string: "http://nas:11434/v1"))
        let (u6, h6) = LocalNetworking.resolvedLocalTarget(for: unqualifiedURL)
        #expect(u6 == unqualifiedURL)
        #expect(h6 == nil)
    }

    @Test
    func `Resolved local target rewrites multi-label LAN domain with injected resolver`() throws {
        // Multi-label LAN domain with port
        let rawURL = try #require(URL(string: "http://nas.int.example.com:11434/v1"))
        let (targetURL, hostHeader) = LocalNetworking.resolvedLocalTarget(
            for: rawURL,
            resolver: { host in host == "nas.int.example.com" ? "10.100.100.100" : nil }
        )
        #expect(targetURL.absoluteString == "http://10.100.100.100:11434/v1")
        #expect(targetURL.host == "10.100.100.100")
        #expect(targetURL.port == 11434)
        #expect(targetURL.path == "/v1")
        #expect(hostHeader == "nas.int.example.com:11434")

        // Multi-label LAN domain without port
        let noPortURL = try #require(URL(string: "http://ollama.lan/v1"))
        let (noPortTarget, noPortHeader) = LocalNetworking.resolvedLocalTarget(
            for: noPortURL,
            resolver: { host in host == "ollama.lan" ? "192.168.1.50" : nil }
        )
        #expect(noPortTarget.absoluteString == "http://192.168.1.50/v1")
        #expect(noPortTarget.host == "192.168.1.50")
        #expect(noPortTarget.port == nil)
        #expect(noPortHeader == "ollama.lan")

        // IPv6 Unique Local address target
        let ipv6URL = try #require(URL(string: "http://ai.home.arpa:8080/v1"))
        let (ipv6Target, ipv6Header) = LocalNetworking.resolvedLocalTarget(
            for: ipv6URL,
            resolver: { host in host == "ai.home.arpa" ? "fd00::1234" : nil }
        )
        #expect(ipv6Target.host == "fd00::1234")
        #expect(ipv6Target.port == 8080)
        #expect(ipv6Header == "ai.home.arpa:8080")

        // Unresolvable or public domain returns original URL unmodified
        let publicURL = try #require(URL(string: "http://api.example.com/v1"))
        let (publicTarget, publicHeader) = LocalNetworking.resolvedLocalTarget(
            for: publicURL,
            resolver: { _ in nil }
        )
        #expect(publicTarget == publicURL)
        #expect(publicHeader == nil)
    }

    @Test
    func `DNS resolution cache and bypass rules`() {
        LocalNetworking.clearCache()

        // Loopback bypasses DNS query directly
        #expect(LocalNetworking.resolvePrivateIP(for: "localhost") == "127.0.0.1")

        // Raw IP addresses bypass DNS query directly
        #expect(LocalNetworking.resolvePrivateIP(for: "10.0.0.1") == "10.0.0.1")
        #expect(LocalNetworking.resolvePrivateIP(for: "192.168.1.1") == "192.168.1.1")
        #expect(LocalNetworking.resolvePrivateIP(for: "::1") == "::1")

        // Whitespace-only string returns nil
        #expect(LocalNetworking.resolvePrivateIP(for: "   ") == nil)
    }
}

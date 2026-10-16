// Rune Weaver Core Tests — Formal policy invariant verifier.

import Foundation
@testable import RuneWeaverCore
import Testing

@Suite("PolicyInvariantVerifier")
struct PolicyInvariantVerifierTests {
    // MARK: - Invariant 1: Credential Binding Confinement

    @Test
    func `Credential targeting public host passes`() {
        let policy = SecurityPolicy(
            credentials: [
                "GITHUB_PAT": CredentialBinding(allowedHosts: ["api.github.com"])
            ]
        )
        let violations = PolicyInvariantVerifier.verifyCredentialConfinement(policy)
        #expect(violations.isEmpty)
    }

    @Test
    func `Credential targeting wildcard * fails`() {
        let policy = SecurityPolicy(
            credentials: [
                "LEAKED_KEY": CredentialBinding(allowedHosts: ["*"])
            ]
        )
        let violations = PolicyInvariantVerifier.verifyCredentialConfinement(policy)
        #expect(!violations.isEmpty)
        #expect(violations.contains(where: { $0.contains("forbidden host") || $0.contains("wildcard") }))
    }

    @Test
    func `Credential targeting metadata IP fails`() {
        let policy = SecurityPolicy(
            credentials: [
                "AWS_KEY": CredentialBinding(allowedHosts: ["169.254.169.254"])
            ]
        )
        let violations = PolicyInvariantVerifier.verifyCredentialConfinement(policy)
        #expect(!violations.isEmpty)
        #expect(violations.contains(where: { $0.contains("169.254.169.254") }))
    }

    @Test
    func `Credential targeting CGNAT and reserved ranges fails`() {
        // Alibaba's metadata service answers in shared address space (`100.64.0.0/10`), so CGNAT
        // must fail like the other reserved blocks; otherwise this storage-boundary invariant and
        // the runtime SSRF table could reach different verdicts for the same host.
        let sensitiveHosts = [
            "100.100.100.200",
            "100.64.0.1",
            "100.127.255.255",
            "0x64.0x64.0x64.0xc8",
            "1684301000",
            "192.0.2.10",
            "198.18.0.1",
            "203.0.113.5",
            "224.0.0.1",
            "240.0.0.1"
        ]
        for host in sensitiveHosts {
            let policy = SecurityPolicy(
                credentials: ["SHARED_KEY": CredentialBinding(allowedHosts: [host])]
            )
            let violations = PolicyInvariantVerifier.verifyCredentialConfinement(policy)
            #expect(!violations.isEmpty, "expected a violation for '\(host)'")
        }
    }

    @Test
    func `Credential targeting private RFC 1918 range fails`() {
        let policy = SecurityPolicy(
            credentials: [
                "INTERNAL_KEY": CredentialBinding(allowedHosts: ["192.168.1.100"])
            ]
        )
        let violations = PolicyInvariantVerifier.verifyCredentialConfinement(policy)
        #expect(!violations.isEmpty)
        #expect(violations.contains(where: { $0.contains("private network") }))
    }

    @Test
    func `Credential targeting localhost fails`() {
        let policy = SecurityPolicy(
            credentials: [
                "LOCAL_KEY": CredentialBinding(allowedHosts: ["localhost"])
            ]
        )
        let violations = PolicyInvariantVerifier.verifyCredentialConfinement(policy)
        #expect(!violations.isEmpty)
    }

    @Test
    func `Credential targeting loopback IP fails`() {
        let policy = SecurityPolicy(
            credentials: [
                "LOOP_KEY": CredentialBinding(allowedHosts: ["127.0.0.1"])
            ]
        )
        let violations = PolicyInvariantVerifier.verifyCredentialConfinement(policy)
        #expect(!violations.isEmpty)
    }

    @Test
    func `Credential wildcard over public base passes`() {
        let policy = SecurityPolicy(
            credentials: [
                "API_KEY": CredentialBinding(allowedHosts: ["*.example.com"])
            ]
        )
        let violations = PolicyInvariantVerifier.verifyCredentialConfinement(policy)
        #expect(violations.isEmpty)
    }

    @Test
    func `Credential wildcard over forbidden or sensitive base fails`() {
        for host in ["*.localhost", "*.169.254.169.254", "*.127.0.0.1", "*.metadata.google.internal"] {
            let policy = SecurityPolicy(
                credentials: ["WILD_KEY": CredentialBinding(allowedHosts: [host])]
            )
            let violations = PolicyInvariantVerifier.verifyCredentialConfinement(policy)
            #expect(!violations.isEmpty, "expected a violation for '\(host)'")
        }
    }

    @Test
    func `Credential malformed wildcard shapes fail`() {
        for host in ["*", "*.*", "www.*", "*foo.example.com", "*.example.com:443"] {
            let policy = SecurityPolicy(
                credentials: ["WILD_KEY": CredentialBinding(allowedHosts: [host])]
            )
            let violations = PolicyInvariantVerifier.verifyCredentialConfinement(policy)
            #expect(!violations.isEmpty, "expected a violation for '\(host)'")
        }
    }

    @Test
    func `Credential with empty hosts warns`() {
        let policy = SecurityPolicy(
            credentials: [
                "ORPHANED": CredentialBinding(allowedHosts: [])
            ]
        )
        let violations = PolicyInvariantVerifier.verifyCredentialConfinement(policy)
        #expect(!violations.isEmpty)
        #expect(violations.contains(where: { $0.contains("no allowed_hosts") }))
    }

    // MARK: - Invariant 1: IPv6, mapped, and alternate spelling coverage

    @Test
    func `Credential targeting IPv6 loopback fails`() {
        let sensitiveHosts = ["::1", "[::1]", "0:0:0:0:0:0:0:1", "::"]
        for host in sensitiveHosts {
            let policy = SecurityPolicy(
                credentials: ["LOCAL_KEY": CredentialBinding(allowedHosts: [host])]
            )
            let violations = PolicyInvariantVerifier.verifyCredentialConfinement(policy)
            #expect(!violations.isEmpty, "expected a violation for '\(host)'")
        }
    }

    @Test
    func `Credential targeting IPv4-mapped sensitive ranges fails`() {
        let sensitiveHosts = [
            "::ffff:127.0.0.1",
            "::ffff:10.0.0.5",
            "::ffff:172.16.0.1",
            "::ffff:192.168.1.10",
            "::ffff:169.254.169.254",
            "::ffff:0:0",
            "::ffff:7f00:1",
            "0:0:0:0:0:ffff:a00:5"
        ]
        for host in sensitiveHosts {
            let policy = SecurityPolicy(
                credentials: ["MAPPED_KEY": CredentialBinding(allowedHosts: [host])]
            )
            let violations = PolicyInvariantVerifier.verifyCredentialConfinement(policy)
            #expect(!violations.isEmpty, "expected a violation for '\(host)'")
        }
    }

    @Test
    func `Credential targeting IPv6 link-local and unique-local fails`() {
        let sensitiveHosts = [
            "fe80::1",
            "febf:ffff:ffff:ffff:ffff:ffff:ffff:ffff",
            "fd12:3456::1",
            "fc00::1"
        ]
        for host in sensitiveHosts {
            let policy = SecurityPolicy(
                credentials: ["IPV6_KEY": CredentialBinding(allowedHosts: [host])]
            )
            let violations = PolicyInvariantVerifier.verifyCredentialConfinement(policy)
            #expect(!violations.isEmpty, "expected a violation for '\(host)'")
        }
    }

    @Test
    func `Credential targeting IPv4-embedded translation spellings fails`() {
        // NAT64, 6to4, and IPv4-compatible spellings of a sensitive address must be refused exactly
        // like their dotted twins, or a credential could be bound to the metadata endpoint through
        // an alternate spelling that the range table never decoded.
        let sensitiveHosts = [
            "64:ff9b::a9fe:a9fe", // NAT64 well-known prefix → 169.254.169.254
            "64:ff9b::a00:1", // NAT64 → 10.0.0.1
            "64:ff9b::169.254.169.254", // dotted NAT64 twin
            "64:ff9b:1:a9fe:a9:fe00::", // local-use NAT64 → 169.254.169.254
            "2002:a9fe:a9fe::", // 6to4 → 169.254.169.254
            "2002:a00:1::", // 6to4 → 10.0.0.1
            "::a9fe:a9fe", // IPv4-compatible → 169.254.169.254
            "::7f00:1", // IPv4-compatible → 127.0.0.1
            "::a00:1" // IPv4-compatible → 10.0.0.1
        ]
        for host in sensitiveHosts {
            let policy = SecurityPolicy(
                credentials: ["EMBEDDED_KEY": CredentialBinding(allowedHosts: [host])]
            )
            let violations = PolicyInvariantVerifier.verifyCredentialConfinement(policy)
            #expect(!violations.isEmpty, "expected a violation for '\(host)'")
        }
    }

    @Test
    func `Credential targeting public IPv4-embedded spellings passes`() {
        // Public embedded addresses stay allowed: the invariant refuses only
        // targets that are provably non-public, not the spelling itself.
        let publicHosts = [
            "64:ff9b::5db8:d822", // NAT64 → 93.184.216.34
            "64:ff9b:1:5db8:d8:2200::", // local-use NAT64 → 93.184.216.34
            "2002:5db8:d822::", // 6to4 → 93.184.216.34
            "::ffff:93.184.216.34" // mapped public
        ]
        let policy = SecurityPolicy(
            credentials: ["PUBLIC_KEY": CredentialBinding(allowedHosts: Set(publicHosts))]
        )
        let violations = PolicyInvariantVerifier.verifyCredentialConfinement(policy)
        #expect(violations.isEmpty)
    }

    @Test
    func `Credential targeting alternate IPv4 spellings of sensitive ranges fails`() {
        let sensitiveHosts = [
            "2130706433", // decimal 127.0.0.1
            "0x7f.0.0.1", // hex first octet
            "0177.0.0.1", // octal first octet
            "127.1", // short form
            "0xa9fea9fe", // hex 169.254.169.254
            "0300.0250.1.1" // octal 192.168.1.1
        ]
        for host in sensitiveHosts {
            let policy = SecurityPolicy(
                credentials: ["SPELLED_KEY": CredentialBinding(allowedHosts: [host])]
            )
            let violations = PolicyInvariantVerifier.verifyCredentialConfinement(policy)
            #expect(!violations.isEmpty, "expected a violation for '\(host)'")
        }
    }

    @Test
    func `Credential targeting public hosts is unaffected`() {
        let publicHosts = [
            "api.github.com",
            "api.openai.com",
            "93.184.216.34",
            "100.63.255.255",
            "100.128.0.0",
            "2606:4700:4700::1111",
            "::ffff:93.184.216.34",
            "10.example.com",
            "172.15.0.1"
        ]
        let policy = SecurityPolicy(
            credentials: ["PUBLIC_KEY": CredentialBinding(allowedHosts: Set(publicHosts))]
        )
        let violations = PolicyInvariantVerifier.verifyCredentialConfinement(policy)
        #expect(violations.isEmpty)
    }

    // MARK: - Invariant 2: Rule Shadow Prevention

    @Test
    func `No conflicts between allowed and blocked passes`() {
        let policy = SecurityPolicy(
            network: NetworkEgressPolicy(
                allowedDomains: ["api.github.com"],
                blockedDomains: ["evil.com"]
            )
        )
        let violations = PolicyInvariantVerifier.verifyRuleShadowing(policy)
        #expect(violations.isEmpty)
    }

    @Test
    func `Domain in both allowed and blocked flags conflict`() {
        let policy = SecurityPolicy(
            network: NetworkEgressPolicy(
                allowedDomains: ["evil.com"],
                blockedDomains: ["evil.com"]
            )
        )
        let violations = PolicyInvariantVerifier.verifyRuleShadowing(policy)
        #expect(!violations.isEmpty)
        #expect(violations.contains(where: { $0.contains("both") }))
    }

    @Test
    func `Wildcard allowed covering specific blocked flags conflict`() {
        let policy = SecurityPolicy(
            network: NetworkEgressPolicy(
                allowedDomains: ["*.evil.com"],
                blockedDomains: ["malware.evil.com"]
            )
        )
        let violations = PolicyInvariantVerifier.verifyRuleShadowing(policy)
        #expect(!violations.isEmpty)
    }

    // MARK: - Full Verification

    @Test
    func `Safe default policy passes all invariants`() {
        let violations = PolicyInvariantVerifier.verify(.safeDefault)
        #expect(violations.isEmpty)
    }

    @Test
    func `Multiple violations from a malicious policy`() {
        // A hostile posture trips both surviving invariants at once: the
        // bindings smuggle forbidden targets while the allowlist shadows its
        // own block entry, so one verify call names every failing gate.
        let policy = SecurityPolicy(
            network: NetworkEgressPolicy(
                allowedDomains: ["evil.com"],
                blockedDomains: ["evil.com"]
            ),
            credentials: [
                "LEAKED": CredentialBinding(allowedHosts: ["*"]),
                "META": CredentialBinding(allowedHosts: ["169.254.169.254"])
            ]
        )
        let violations = PolicyInvariantVerifier.verify(policy)
        #expect(violations.count >= 3)
    }
}

// Rune Weaver Core — Formal policy invariant verifier.
//
// Statically proves safety invariants on a SecurityPolicy before it is
// activated. Runs at engine boot and before any policy mutation.
// Violations fall back to the safe factory posture — the engine never runs
// with a broken policy.
//
// Two invariants are enforced over the network-plus-credentials scope:
//   1. Credential Binding Confinement — no credential targets wildcards beyond
//      a single leading `*.` subdomain edge, metadata hosts, loopback,
//      link-local, or private ranges.
//   2. Rule Shadow Prevention — broad allows cannot shadow specific denies.

import Foundation

/// Deterministic formal validator proving security policy invariants.
///
/// Every method is `static` and side-effect-free: the verifier reads
/// a `SecurityPolicy` and returns a list of human-readable violation
/// descriptions. An empty list means all invariants hold.
public enum PolicyInvariantVerifier: Sendable {
    /// Exact hosts that must never appear as credential binding targets.
    ///
    /// Cloud metadata endpoints, wildcard patterns, and special addresses
    /// that would allow credential exfiltration if bound. Range-based
    /// refusals (loopback, link-local, private, unique-local, mapped tails,
    /// and IPv4-embedded translation prefixes) are decided by the shared
    /// `SensitiveAddressRanges` table rather than enumerated here.
    public static let forbiddenCredentialHosts: Set<String> = [
        "*",
        "169.254.169.254", // AWS/GCP metadata
        "metadata.google.internal", // GCP metadata
        "100.100.100.200", // Alibaba metadata
        "fd00:ec2::254", // AWS IPv6 metadata
        "0.0.0.0",
        "localhost" // Credentials should target real endpoints
    ]

    /// Runs both invariant checks and returns violation descriptions.
    ///
    /// - Parameter policy: The security policy to verify.
    /// - Returns: Empty array when all invariants hold, or human-readable
    ///   violation descriptions for each failure.
    public static func verify(_ policy: SecurityPolicy) -> [String] {
        var violations: [String] = []
        violations.append(contentsOf: verifyCredentialConfinement(policy))
        violations.append(contentsOf: verifyRuleShadowing(policy))
        return violations
    }

    // MARK: - Invariant 1: Credential Binding Confinement

    /// Guarantees credentials can never be bound to wildcards (other than a
    /// single leading `*.` edge, whose base is checked like an exact host),
    /// loopback, link-local, private, or cloud metadata targets.
    ///
    /// Formally: ∀ c ∈ credentials, ∀ h ∈ allowedHosts(c):
    ///   h ∉ WildcardShapes ∪ ForbiddenHosts and Base(h) ∉ Metadata ∪ Loopback
    ///   ∪ LinkLocal ∪ PrivateRanges
    ///
    /// Hosts classify through the shared address parser and sensitive-range
    /// table, so IPv6 loopback (`::1`), IPv4-mapped sensitive tails
    /// (`::ffff:127.0.0.1`), IPv4-embedded translation spellings (NAT64
    /// `64:ff9b::/96`, 6to4 `2002::/16`, and IPv4-compatible `::/96` forms
    /// such as `64:ff9b::a9fe:a9fe`), link-local `fe80::/10`, unique-local
    /// `fc00::/7`, and decimal/hex/octal/short IPv4 spellings fail like their
    /// canonical twins instead of slipping past string prefixes. DNS names
    /// stay allowed because the runtime SSRF guard vets their resolved
    /// addresses; this invariant refuses only targets that are provably
    /// non-public at storage time.
    public static func verifyCredentialConfinement(_ policy: SecurityPolicy) -> [String] {
        var violations: [String] = []

        for (key, binding) in policy.credentials {
            for host in binding.allowedHosts {
                let lowered = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

                // A single leading `*.` is the only meaningful credential
                // wildcard: it authorizes the base domain plus subdomains at
                // runtime. The base re-enters the exact and range checks below
                // so `*.localhost` or `*.169.254.169.254` cannot smuggle a
                // forbidden suffix past confinement; every other star shape is
                // refused outright.
                let target: String
                switch AllowedOriginPattern.classifyWildcard(lowered) {
                case .none:
                    target = host
                case .leading:
                    target = String(lowered.dropFirst(2))
                case .trailing, .invalidShape, .invalidSuffix, .invalidStem:
                    violations.append(
                        "Invariant 1 (Credential Confinement): credential '\(key)' targets "
                            + "wildcard host '\(host)'. Use a single leading '*.' edge or a specific hostname."
                    )
                    continue
                }

                let cleaned = SensitiveAddressNormalization.cleanedHostBase(target)
                let canonical = SensitiveAddressNormalization.normalizedHost(target)

                // Check exact forbidden hosts, including canonicalized spellings
                // such as `::ffff:169.254.169.254` for the IPv4 metadata IP and
                // wildcard bases like `*.localhost`.
                if forbiddenCredentialHosts.contains(cleaned) || forbiddenCredentialHosts.contains(canonical) {
                    violations.append(
                        "Invariant 1 (Credential Confinement): credential '\(key)' targets "
                            + "forbidden host '\(host)'. Credentials must target specific public endpoints."
                    )
                    continue
                }

                // Check loopback, link-local, and private/reserved ranges through
                // the shared range table so no spelling can bypass the invariant.
                if SensitiveAddressRanges.isSensitiveHostLiteral(target) {
                    violations.append(
                        "Invariant 1 (Credential Confinement): credential '\(key)' targets "
                            + "\(sensitiveTargetLabel(target)) host '\(host)'. "
                            + "Credentials should target public endpoints."
                    )
                }
            }

            // Warn on empty hosts (no destination authorized means credential is unusable)
            if binding.allowedHosts.isEmpty {
                violations.append(
                    "Invariant 1 (Credential Confinement): credential '\(key)' has no "
                        + "allowed_hosts configured. The credential will be unusable until hosts are added."
                )
            }
        }

        return violations
    }

    /// Human-readable category for a host the range table classified sensitive.
    /// Wording only — the sensitive/clean verdict comes from the shared table.
    /// A decoded IPv4-embedded spelling labels as the embedded address's
    /// category, so the message names what the literal actually dials instead
    /// of just echoing the translation prefix.
    private static func sensitiveTargetLabel(_ host: String) -> String {
        if let embedded = SensitiveAddressRanges.embeddedIPv4Literal(host) {
            return sensitiveTargetLabel(embedded)
        }
        if SensitiveAddressRanges.isLoopbackHost(host) {
            return "loopback"
        }
        if SensitiveAddressRanges.isLinkLocalIPv4(host) || SensitiveAddressRanges.isLinkLocalIPv6(host) {
            return "link-local"
        }
        return "private network"
    }

    // MARK: - Invariant 2: Rule Shadow Prevention

    /// Guarantees that broad network allowlists do not shadow or invalidate
    /// specific deny rules: a blocked domain always refuses even when an
    /// allow entry would otherwise cover it.
    public static func verifyRuleShadowing(_ policy: SecurityPolicy) -> [String] {
        var violations: [String] = []

        // Check that allowed domains don't contradict blocked domains
        let allowedDomains = policy.network.allowedDomains
        let blockedDomains = policy.network.blockedDomains

        for blocked in blockedDomains {
            let loweredBlocked = blocked.lowercased()
            for allowed in allowedDomains {
                let loweredAllowed = allowed.lowercased()

                // Exact match conflict
                if loweredAllowed == loweredBlocked {
                    violations.append(
                        "Invariant 2 (Rule Shadowing): domain '\(blocked)' appears in both "
                            + "allowed_domains and blocked_domains. blocked_domains takes priority, "
                            + "but the conflict should be resolved."
                    )
                }

                // Wildcard allowed covering a specific blocked domain
                if loweredAllowed.hasPrefix("*.") {
                    let suffix = String(loweredAllowed.dropFirst(1))
                    if loweredBlocked.hasSuffix(suffix) || loweredBlocked == String(loweredAllowed.dropFirst(2)) {
                        violations.append(
                            "Invariant 2 (Rule Shadowing): wildcard allowed domain '\(allowed)' "
                                + "would cover blocked domain '\(blocked)'. blocked_domains takes priority, "
                                + "but the conflict should be resolved."
                        )
                    }
                }
            }
        }

        return violations
    }
}

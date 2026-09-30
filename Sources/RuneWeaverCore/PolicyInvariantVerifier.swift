// Rune Weaver Core — Formal policy invariant verifier.
//
// Statically proves mathematical safety invariants on a SecurityPolicy
// before it is activated. Runs at engine boot and before any policy
// mutation (PUT /settings/policy). Violations fall back to the safe
// factory posture — the engine never runs with a broken policy.
//
// Four invariants are enforced:
//   1. Path Containment Safety — no allow root encompasses a protected path,
//      declared in `deny_paths` or belonging to the always-on default deny set.
//   2. Credential Binding Confinement — no credential targets wildcards beyond
//      a single leading `*.` subdomain edge, metadata hosts, loopback,
//      link-local, or private ranges.
//   3. Rule Shadow Prevention — broad allows cannot shadow specific denies.
//   4. Critical Tool Lock — sensitive tools cannot be set to trusted.

import Foundation

/// Deterministic formal validator proving security policy invariants.
///
/// Every method is `static` and side-effect-free: the verifier reads
/// a `SecurityPolicy` and returns a list of human-readable violation
/// descriptions. An empty list means all invariants hold.
public enum PolicyInvariantVerifier: Sendable {
    /// Tools that must never be configured as `.trusted` via policy.
    ///
    /// These tools control real-world side effects (sending messages,
    /// controlling the desktop) and must always require human approval.
    public static let criticalTools: Set<String> = [
        "messages.send",
        "desktop.action",
        "desktop.screenshot"
    ]

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

    /// Runs all four invariant checks and returns violation descriptions.
    ///
    /// - Parameter policy: The security policy to verify.
    /// - Returns: Empty array when all invariants hold, or human-readable
    ///   violation descriptions for each failure.
    public static func verify(_ policy: SecurityPolicy) -> [String] {
        var violations: [String] = []
        violations.append(contentsOf: verifyPathContainment(policy))
        violations.append(contentsOf: verifyCredentialConfinement(policy))
        violations.append(contentsOf: verifyRuleShadowing(policy))
        violations.append(contentsOf: verifyCriticalToolLock(policy))
        return violations
    }

    // MARK: - Invariant 1: Path Containment Safety

    /// Guarantees no allowed root directory encompasses or exposes a protected
    /// directory (`~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.runeweaver/memory`,
    /// `~/Library/Keychains`).
    ///
    /// The declared `deny_paths` are always unioned with
    /// `SeatbeltProfileBuilder.defaultDeniedPaths`, so an empty or narrowed
    /// deny list can never make a protected directory an allowable root — the
    /// storage boundary holds the same guarantee the sandbox builder enforces
    /// at runtime.
    ///
    /// Formally: ∀ allow ∈ allowRoots, ∀ deny ∈ denyPaths ∪ protectedPaths:
    ///   Canonical(allow) ⊅ Canonical(deny)
    public static func verifyPathContainment(_ policy: SecurityPolicy) -> [String] {
        var violations: [String] = []

        // Union the fixed protected set in regardless of the declared list:
        // `allow_roots = ["~"], deny_paths = []` must not pass verification.
        var protected = Set(policy.filesystem.denyPaths)
        protected.formUnion(SeatbeltProfileBuilder.defaultDeniedPaths)

        let expandedRoots = policy.filesystem.allowRoots.map { expandTilde($0) }
        let expandedDenies = protected.map { expandTilde($0) }.sorted()

        for root in expandedRoots {
            let normalRoot = normalizePath(root)
            for deny in expandedDenies {
                let normalDeny = normalizePath(deny)

                // Check if the allow root encompasses the deny path.
                // A root encompasses a deny if the deny starts with the root path.
                let rootPrefix = normalRoot.hasSuffix("/") ? normalRoot : normalRoot + "/"

                if normalDeny.hasPrefix(rootPrefix) || normalDeny == normalRoot {
                    violations.append(
                        "Invariant 1 (Path Containment): allow_root '\(root)' encompasses protected deny_path '\(deny)'. "
                            + "Use specific subdirectories or configure an isolated workspace."
                    )
                }
            }
        }

        return violations
    }

    // MARK: - Invariant 2: Credential Binding Confinement

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
                        "Invariant 2 (Credential Confinement): credential '\(key)' targets "
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
                        "Invariant 2 (Credential Confinement): credential '\(key)' targets "
                            + "forbidden host '\(host)'. Credentials must target specific public endpoints."
                    )
                    continue
                }

                // Check loopback, link-local, and private/reserved ranges through
                // the shared range table so no spelling can bypass the invariant.
                if SensitiveAddressRanges.isSensitiveHostLiteral(target) {
                    violations.append(
                        "Invariant 2 (Credential Confinement): credential '\(key)' targets "
                            + "\(sensitiveTargetLabel(target)) host '\(host)'. "
                            + "Credentials should target public endpoints."
                    )
                }
            }

            // Warn on empty hosts (no destination authorized means credential is unusable)
            if binding.allowedHosts.isEmpty {
                violations.append(
                    "Invariant 2 (Credential Confinement): credential '\(key)' has no "
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

    // MARK: - Invariant 3: Rule Shadow Prevention

    /// Guarantees that broad network allowlists do not shadow or invalidate
    /// specific deny rules, and that filesystem allow roots are internally
    /// consistent.
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
                        "Invariant 3 (Rule Shadowing): domain '\(blocked)' appears in both "
                            + "allowed_domains and blocked_domains. blocked_domains takes priority, "
                            + "but the conflict should be resolved."
                    )
                }

                // Wildcard allowed covering a specific blocked domain
                if loweredAllowed.hasPrefix("*.") {
                    let suffix = String(loweredAllowed.dropFirst(1))
                    if loweredBlocked.hasSuffix(suffix) || loweredBlocked == String(loweredAllowed.dropFirst(2)) {
                        violations.append(
                            "Invariant 3 (Rule Shadowing): wildcard allowed domain '\(allowed)' "
                                + "would cover blocked domain '\(blocked)'. blocked_domains takes priority, "
                                + "but the conflict should be resolved."
                        )
                    }
                }
            }
        }

        return violations
    }

    // MARK: - Invariant 4: Critical Tool Lock

    /// Guarantees that sensitive tools (`messages.send`, `desktop.action`)
    /// can never be configured with `level = .trusted` via declarative policy.
    public static func verifyCriticalToolLock(_ policy: SecurityPolicy) -> [String] {
        var violations: [String] = []

        for (toolName, toolPolicy) in policy.tools where criticalTools.contains(toolName) {
            if toolPolicy.level == .trusted {
                violations.append(
                    "Invariant 4 (Critical Tool Lock): tool '\(toolName)' cannot be set to "
                        + "'trusted' via policy. This tool must always require human approval."
                )
            }
        }

        return violations
    }

    // MARK: - Helpers

    /// Expands `~` to the user's home directory.
    private static func expandTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    /// Normalizes a path for containment comparison.
    private static func normalizePath(_ path: String) -> String {
        let expanded = expandTilde(path)
        // Standardize by resolving `.` and `..` without following symlinks
        // at verification time (the real check happens at runtime via
        // SeatbeltProfileBuilder and FilesAccessGuard).
        let url = URL(fileURLWithPath: expanded).standardized
        return url.path
    }
}

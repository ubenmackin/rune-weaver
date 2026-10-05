// Rune Weaver Core — Shared allowed-origin wildcard policy for validation and matching.
//
// Purpose: single source for host-pattern rules and the `[network].local_exemptions`
// entry shape gate, so the SSRF matcher and the policy verifier cannot drift on
// what a wildcard means. Scope: pure string predicates over lowercased patterns only;
// URL parsing, IPv6 bracket handling, and origin-key comparison stay with their
// callers. Architectural role: owned by `RuneWeaverCore` so both the policy verifier
// and `RuneWeaverTools` resolve the same universal, glob, and single-edge decisions.

import Foundation

/// Shared wildcard policy for host patterns.
/// Lowercased input is assumed; matching callers normalize hosts before comparing
/// so hex, octal, and short IP spellings converge on one verdict.
public enum AllowedOriginPattern: Sendable {
    /// Whether a lowercased pattern is the bare universal `*`.
    /// - Parameter lowered: Lowercased, trimmed pattern.
    /// - Returns: True only for the single-star entry.
    public static func isBareUniversal(_ lowered: String) -> Bool {
        lowered == "*"
    }

    /// Whether a lowercased pattern is a universal star-dot shape (`*.*`, `**`).
    /// Star and dot characters alone can never name a host, so such shapes stay
    /// denied even when a forged exemption set carries them.
    /// - Parameter lowered: Lowercased, trimmed pattern.
    /// - Returns: True when only `*`, `.`, and whitespace remain.
    public static func isUniversalWildcardShape(_ lowered: String) -> Bool {
        lowered.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: ".", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether a lowercased pattern is any universal wildcard.
    /// Covers the bare star and every star-dot shape through one predicate so
    /// validation and matching share the same closed set.
    /// - Parameter lowered: Lowercased, trimmed pattern.
    /// - Returns: True for `*` and star-dot-only shapes.
    public static func isUniversalWildcard(_ lowered: String) -> Bool {
        isBareUniversal(lowered) || isUniversalWildcardShape(lowered)
    }

    /// Whether a lowercased pattern carries file-glob syntax with no host meaning.
    /// Question marks, classes, and extra stars belong to file globs; host
    /// patterns honor only a single leading `*.` or trailing `.*` edge.
    /// - Parameter lowered: Lowercased, trimmed pattern.
    /// - Returns: True when `?`, `[`, or `]` is present.
    public static func containsGlobSyntax(_ lowered: String) -> Bool {
        lowered.contains("?") || lowered.contains("[") || lowered.contains("]")
    }

    /// Wildcard placement for a lowercased pattern.
    public enum WildcardClassification: Sendable, Equatable {
        /// No `*` present; exact host handling applies.
        case none
        /// Single leading `*.` with a named suffix host.
        case leading
        /// Single trailing `.*` with a named IP or host stem.
        case trailing
        /// Star present but edges are not a single exclusive `*.` / `.*`.
        case invalidShape
        /// Leading edge present but the suffix names no host.
        case invalidSuffix
        /// Trailing edge present but the stem names no host.
        case invalidStem
    }

    /// Classifies the wildcard shape of a lowercased pattern.
    /// A single exclusive edge is required: one star, either a leading `*.` or a
    /// trailing `.*`, with a named remainder free of further stars. File-glob
    /// syntax inside a wildcard pattern invalidates the shape so `?` and classes
    /// can never ride a wildcard edge into an exemption. Port qualifiers also
    /// invalidate wildcards: host matching compares port-less names, so a
    /// port-qualified wildcard could never authorize yet would read as allowed.
    /// - Parameter lowered: Lowercased, trimmed pattern.
    /// - Returns: Placement, or the specific invalid reason.
    public static func classifyWildcard(_ lowered: String) -> WildcardClassification {
        let starCount = lowered.filter { $0 == "*" }.count
        guard starCount > 0 else { return .none }
        if containsGlobSyntax(lowered) {
            return .invalidShape
        }
        // Wildcards stay port-less so validation and the matcher share one
        // shape: exact `host:port` exemptions compare through the origin key,
        // while `*.host` and `prefix.*` compare against port-less names.
        if lowered.contains(":") {
            return .invalidShape
        }
        let hasLeading = lowered.hasPrefix("*.")
        let hasTrailing = lowered.hasSuffix(".*")
        guard starCount == 1, hasLeading != hasTrailing else {
            return .invalidShape
        }
        if hasLeading {
            let bare = String(lowered.dropFirst(2))
            guard !bare.isEmpty, !bare.contains("*") else {
                return .invalidSuffix
            }
            return .leading
        } else {
            let stem = String(lowered.dropLast(2))
            guard !stem.isEmpty, !stem.contains("*") else {
                return .invalidStem
            }
            return .trailing
        }
    }

    /// Whether a lowercased, trimmed pattern is a valid `local_exemptions` entry.
    ///
    /// The shape gate for owner-declared local-network grants: a valid entry
    /// names an exact host, an IPv4/IPv6 literal, a single leading `*.` edge,
    /// a single trailing `.*` edge, or the bare universal `*`. URL syntax,
    /// file-glob syntax, userinfo, fragments, ports, and whitespace are refused
    /// so an entry that could never match the host comparison cannot persist as
    /// a configured grant; never-dialable classification stays with the policy
    /// verifier so shape and range decisions remain separate gates.
    /// - Parameter lowered: Lowercased, trimmed entry text.
    /// - Returns: True when the entry has to-be-classified exemption shape.
    public static func isValidExemptionEntry(_ lowered: String) -> Bool {
        guard !lowered.isEmpty else { return false }
        // Whitespace never survives host comparison, so an entry carrying it
        // could only read as configured yet never match; fail closed here.
        guard lowered.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return false }
        for forbidden in [",", "?", "[", "]", "/", "\\", "@", "#"] where lowered.contains(forbidden) {
            return false
        }
        // A lone colon can only spell a `host:port` suffix, and exemption
        // matching is port-less, so a port-qualified entry could never
        // authorize; IPv6 literals keep their multiple colons.
        guard lowered.filter({ $0 == ":" }).count != 1 else { return false }
        if isBareUniversal(lowered) {
            return true
        }
        switch classifyWildcard(lowered) {
        case .none:
            return isExactHostShape(lowered)
        case .leading:
            return isExactHostShape(String(lowered.dropFirst(2)))
        case .trailing:
            return isExactHostShape(String(lowered.dropLast(2)))
        case .invalidShape, .invalidSuffix, .invalidStem:
            return false
        }
    }

    /// Whether a non-wildcard entry names an exact host or address literal.
    ///
    /// Resolver-accepted IPv4 spellings (decimal, hex, octal, and short) and
    /// IPv6 literals — including mixed dotted tails whose prefix proves out —
    /// pass as addresses; every other entry must be a dot-separated DNS name
    /// with non-empty labels. A trailing root dot is tolerated because the
    /// shared normalizer strips it before comparison.
    /// - Parameter lowered: Lowercased, trimmed exact entry.
    /// - Returns: True when the text names a host or address literal.
    private static func isExactHostShape(_ lowered: String) -> Bool {
        let cleaned = SensitiveAddressNormalization.cleanedHostBase(lowered)
        guard !cleaned.isEmpty else { return false }
        if SensitiveAddressParsing.canonicalIPv4Octets(cleaned) != nil {
            return true
        }
        if cleaned.contains(":") {
            return SensitiveAddressParsing.ipv6HextetsExpandingDottedTail(cleaned) != nil
        }
        for label in cleaned.split(separator: ".", omittingEmptySubsequences: false) {
            guard !label.isEmpty else { return false }
            guard label.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
                return false
            }
        }
        return true
    }
}

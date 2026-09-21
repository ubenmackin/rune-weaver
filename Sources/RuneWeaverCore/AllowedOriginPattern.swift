// Rune Weaver Core — Shared allowed-origin wildcard policy for validation and matching.
//
// Purpose: single source for the `browser.allowed_origins` host-pattern rules so
// config validation and the SSRF matcher cannot drift on what a wildcard means.
// Scope: pure string predicates over lowercased patterns only; URL parsing,
// IPv6 bracket handling, and origin-key comparison stay with their callers.
// Architectural role: owned by `RuneWeaverCore` so both the config validator and
// `RuneWeaverTools` resolve the same universal, glob, and single-edge decisions.

import Foundation

/// Shared wildcard policy for `browser.allowed_origins` host patterns.
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
}

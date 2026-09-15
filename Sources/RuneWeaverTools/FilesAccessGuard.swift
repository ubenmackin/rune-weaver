// Rune Weaver Tools — Shared sensitive-path guard for file tools.
//
// Centralises the deny logic shared by the file plugin family (`files.read`
// and its future write/search siblings) so every tool agrees on which paths
// are too sensitive to touch without explicit approval. Policy is driven by
// `[files]` (`FilesConfig`): deny patterns are glob-matched with the shared
// `FilesGlobMatching` engine, the home boundary generalises to the
// configured allow roots, and denials escalate per
// `require_approval_on_deny`. Defaults come from
// `FilesConfig.defaultDenyPatterns` / `defaultAllowRoots`, so the dashboard
// shows the same boundary the tools enforce. All decisions run on a
// normalised view of the path (tilde expansion, dot-segment
// standardisation, plus symlink resolution) so `..` tricks and symlinked
// escapes cannot bypass the check.

import Foundation
import RuneWeaverCore

/// Single source of truth for file-tool path policy.
///
/// The guard is deliberately path-based and content-blind: it never opens
/// the file, so a denied decision can never leak bytes. Callers thread the
/// decision into a failure envelope carrying an approval hint instead of
/// file content. An optional home override exists so tests can pin the
/// home boundary to an isolated directory without touching the real home.
public enum FilesAccessGuard: Sendable {
    /// Outcome of evaluating one path.
    ///
    /// `allowed` is true only when the path matches no deny pattern and sits
    /// inside the configured allow roots. `requiresApproval` follows
    /// `[files].require_approval_on_deny`: deny hits escalate to the
    /// approvals inbox when true and fail closed without a hint when false.
    /// Read-only callers cannot prompt themselves, so they surface the flag
    /// and leave the actual approval to the orchestrator. `resolvedPath` is
    /// the canonical location the decision was made against.
    public struct Decision: Sendable, Equatable {
        /// Whether the path may be read without escalation.
        public let allowed: Bool
        /// Whether the caller should surface an approval escalation hint.
        public let requiresApproval: Bool
        /// Human-readable policy reason (never file content).
        public let reason: String?
        /// Canonical path the decision was made against.
        public let resolvedPath: String

        /// Creates a decision.
        /// - Parameters:
        ///   - allowed: Whether the path may be read.
        ///   - requiresApproval: Whether to surface an approval hint.
        ///   - reason: Policy reason, if any.
        ///   - resolvedPath: Canonical path the decision was made against.
        public init(allowed: Bool, requiresApproval: Bool, reason: String?, resolvedPath: String) {
            self.allowed = allowed
            self.requiresApproval = requiresApproval
            self.reason = reason
            self.resolvedPath = resolvedPath
        }
    }

    /// Evaluates a raw path string against the `[files]` policy.
    /// - Parameters:
    ///   - path: Raw caller-supplied path (may contain `~`, `.`, `..`, or symlinks).
    ///   - homeDirectoryURL: Home boundary override for tests. Defaults to nil (real home).
    ///   - filesConfig: `[files]` deny/allow policy. Defaults to the built-in defaults.
    /// - Returns: The access decision against the canonical path.
    public static func evaluate(path: String, homeDirectoryURL: URL? = nil, filesConfig: FilesConfig = FilesConfig()) -> Decision {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Decision(
                allowed: false,
                requiresApproval: false,
                reason: "Empty path: a file path must not be blank.",
                resolvedPath: trimmed
            )
        }
        let resolved = resolvedURL(for: trimmed)
        return evaluate(url: resolved, homeDirectoryURL: homeDirectoryURL, filesConfig: filesConfig)
    }

    /// Evaluates an already-formed URL against the `[files]` policy.
    /// - Parameters:
    ///   - url: Candidate file URL.
    ///   - homeDirectoryURL: Home boundary override for tests. Defaults to nil (real home).
    ///   - filesConfig: `[files]` deny/allow policy. Defaults to the built-in defaults.
    /// - Returns: The access decision against the canonical path.
    public static func evaluate(url: URL, homeDirectoryURL: URL? = nil, filesConfig: FilesConfig = FilesConfig()) -> Decision {
        // Normalise through standardisation plus symlink resolution so a
        // symlinked parent or `..` segment cannot hide the true location;
        // every pattern and containment check below runs on this view.
        let canonical = url.standardized.resolvingSymlinksInPath()
        let home = resolvedHomeURL(overriding: homeDirectoryURL)

        if let reason = denyReason(for: canonical, home: home, filesConfig: filesConfig) {
            return Decision(
                allowed: false,
                requiresApproval: filesConfig.requireApprovalOnDeny,
                reason: reason,
                resolvedPath: canonical.path
            )
        }
        if !isInsideAnyRoot(canonical.path, roots: resolvedAllowRoots(filesConfig.allowRoots, home: home)) {
            return Decision(
                allowed: false,
                requiresApproval: filesConfig.requireApprovalOnDeny,
                reason: outsideRootsReason(roots: filesConfig.allowRoots),
                resolvedPath: canonical.path
            )
        }
        return Decision(allowed: true, requiresApproval: false, reason: nil, resolvedPath: canonical.path)
    }

    /// Expands and absolutises a raw path without applying policy.
    ///
    /// Tilde expands via the standard NSString rule, relative paths resolve
    /// against the process working directory so `../` escapes still land on
    /// an absolute location the home-containment check can judge, and the
    /// result is standardised plus symlink-resolved to match `evaluate`.
    /// - Parameter path: Raw caller-supplied path.
    /// - Returns: Canonical file URL.
    public static func resolvedURL(for path: String) -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = (trimmed as NSString).expandingTildeInPath
        let absolute: String
        if expanded.hasPrefix("/") {
            absolute = expanded
        } else {
            let cwd = FileManager.default.currentDirectoryPath
            absolute = (cwd as NSString).appendingPathComponent(expanded)
        }
        return URL(fileURLWithPath: absolute).standardized.resolvingSymlinksInPath()
    }

    /// Resolves the home boundary to a canonical URL.
    /// - Parameter overriding: Test override, if any.
    /// - Returns: Canonical home URL.
    public static func resolvedHomeURL(overriding: URL? = nil) -> URL {
        let base = overriding ?? FileManager.default.homeDirectoryForCurrentUser
        return base.standardized.resolvingSymlinksInPath()
    }

    /// Returns the deny-pattern reason for a canonical URL, if any.
    ///
    /// Each `deny_patterns` entry is a glob in the shared
    /// `FilesGlobMatching` dialect — the same engine behind `files.glob`
    /// and the `files.grep` include filter — so policy and search cannot
    /// drift into divergent dialects. Matching is case-insensitive so
    /// `Secrets.JSON` cannot evade `secrets.json`, and each pattern is
    /// tested against the filename, the home-relative path, every trailing
    /// suffix of that relative path (so `.ssh/*` also covers
    /// `sub/.ssh/config`), and the absolute path, so bare names
    /// (`config.toml`) and rooted shapes
    /// (`.runeweaver/memory/vectors/*`) deny wherever they appear. A
    /// trailing-`/*` pattern additionally denies its bare directory, and a
    /// leading `~` expands against the effective home. Defaults come from
    /// `FilesConfig.defaultDenyPatterns`, keeping one source for the
    /// boundary the dashboard shows and the tools enforce.
    /// - Parameters:
    ///   - canonical: Canonical file URL (already standardised and symlink-resolved).
    ///   - home: Effective (possibly test-overridden) home boundary.
    ///   - filesConfig: `[files]` policy carrying the deny patterns.
    /// - Returns: Deny reason naming the matched pattern, or nil when no pattern matches.
    private static func denyReason(for canonical: URL, home: URL, filesConfig: FilesConfig) -> String? {
        // Candidate views, lowercased once: the filename catches bare
        // shapes (`*.pem`), the relative path and its suffixes catch
        // directory shapes at any depth (`.ssh/*`), and the absolute path
        // catches rooted absolute patterns.
        var candidates: Set<String> = [canonical.lastPathComponent.lowercased(), canonical.path.lowercased()]
        if isInside(canonical.path, root: home.path), canonical.path != home.path {
            let prefix = home.path.hasSuffix("/") ? home.path : home.path + "/"
            if canonical.path.hasPrefix(prefix) {
                let relative = String(canonical.path.dropFirst(prefix.count)).lowercased()
                if !relative.isEmpty {
                    candidates.insert(relative)
                    let segments = relative.split(separator: "/").map(String.init)
                    if segments.count > 1 {
                        for start in 1 ..< segments.count {
                            candidates.insert(segments[start...].joined(separator: "/"))
                        }
                    }
                }
            }
        }
        for rawPattern in filesConfig.denyPatterns {
            let trimmed = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }
            let lowered = trimmed.lowercased()
            // Bare `~` denies the home tree, not just the directory inode,
            // so a broad operator entry cannot silently pass its children.
            if lowered == "~" {
                if isInside(canonical.path.lowercased(), root: home.path.lowercased()) {
                    return "Path matches deny pattern '\(trimmed)'; reading requires explicit approval."
                }
                continue
            }
            // Tilde-anchored patterns resolve against the effective home
            // (honouring the test override) rather than the process home.
            let variants: [String] = if lowered.hasPrefix("~/") {
                [lowered, home.path.lowercased() + lowered.dropFirst(1)]
            } else {
                [lowered]
            }
            for variant in variants {
                for candidate in candidates where FilesGlobMatching.matches(pattern: variant, relativePath: candidate) {
                    return "Path matches deny pattern '\(trimmed)'; reading requires explicit approval."
                }
                // A trailing `/*` also guards its bare directory (the glob
                // itself only matches children), mirroring the old
                // containment rule for roots like the vector store.
                if variant.hasSuffix("/*") {
                    let base = String(variant.dropLast(2))
                    if candidates.contains(base) {
                        return "Path matches deny pattern '\(trimmed)'; reading requires explicit approval."
                    }
                }
            }
        }
        return nil
    }

    /// Resolves configured allow roots to canonical absolute paths.
    ///
    /// `~` (and `~/...`) expands against the effective home — including the
    /// test override — rather than the process home, so pinned-home tests
    /// judge the same boundary production does; bare relative roots anchor
    /// at that home, while absolute roots standardise as written. Blank
    /// entries are dropped (validation rejects them at load time) and an
    /// empty result denies everything fail-closed.
    /// - Parameters:
    ///   - roots: Raw `[files].allow_roots` entries.
    ///   - home: Effective (possibly test-overridden) home boundary.
    /// - Returns: Canonical absolute root paths.
    private static func resolvedAllowRoots(_ roots: [String], home: URL) -> [String] {
        var resolved: [String] = []
        for raw in roots {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }
            if trimmed == "~" {
                resolved.append(home.path)
            } else if trimmed.hasPrefix("~/") {
                resolved.append(home.appendingPathComponent(String(trimmed.dropFirst(2))).standardized.path)
            } else if trimmed.hasPrefix("/") {
                resolved.append(URL(fileURLWithPath: trimmed).standardized.path)
            } else {
                resolved.append(home.appendingPathComponent(trimmed).standardized.path)
            }
        }
        return resolved
    }

    /// Reports whether a canonical path sits inside any allow root.
    /// - Parameters:
    ///   - target: Canonical target path.
    ///   - roots: Canonical absolute root paths.
    /// - Returns: True when `target` equals or descends from any root.
    private static func isInsideAnyRoot(_ target: String, roots: [String]) -> Bool {
        roots.contains { isInside(target, root: $0) }
    }

    /// Builds the outside-roots denial reason.
    ///
    /// The default single-root (`~`) message keeps the historical home
    /// wording; custom roots are named so operators can tell which
    /// boundary refused the path. Never carries file content.
    /// - Parameter roots: Configured allow roots as written in `[files]`.
    /// - Returns: Human-readable policy reason.
    private static func outsideRootsReason(roots: [String]) -> String {
        let trimmed = roots.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if trimmed.isEmpty {
            return "No allowed roots are configured; reading requires explicit approval."
        }
        if trimmed == ["~"] {
            return "Path resolves outside the home directory; reading requires explicit approval."
        }
        return "Path resolves outside the allowed roots (\(trimmed.joined(separator: ", "))); reading requires explicit approval."
    }

    /// Checks whether a canonical path sits inside a canonical root.
    ///
    /// Requires a `/` boundary (or exact equality) so a sibling such as
    /// `/home/user2` never matches root `/home/user`, mirroring the
    /// protected-path check used for plugin integrity.
    /// - Parameters:
    ///   - target: Canonical target path.
    ///   - root: Canonical root path.
    /// - Returns: True when `target` equals or descends from `root`.
    private static func isInside(_ target: String, root: String) -> Bool {
        if target == root {
            return true
        }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return target.hasPrefix(prefix)
    }
}

// Rune Weaver Core — Write-path policy for the `files.write` tool.

import Foundation

/// Write-posture policy shared by the `files.write` tool, its routes, and the CLI.
public enum WritePathPolicy: Sendable {
    /// Engine-owned deny patterns enforced on every write classification regardless of the
    /// configured `[files] deny_patterns` list.
    public static let alwaysDenyPatterns: [String] = [
        ".runeweaver/memory/*",
        ".runeweaver/memory/vectors/*",
        ".runeweaver/browser_profiles/*",
        ".runeweaver/policy.toml",
        ".runeweaver/auth_token",
        ".runeweaver/searxng/*"
    ]

    /// Outcome of classifying one write target.
    public struct Decision: Sendable, Equatable {
        /// Posture the write takes.
        public let posture: FilesWritePathPosture
        /// Policy reason for the posture (never file content).
        public let reason: String?
        /// Canonical path the decision was made against.
        public let resolvedPath: String

        /// Creates a decision.
        public init(posture: FilesWritePathPosture, reason: String?, resolvedPath: String) {
            self.posture = posture
            self.reason = reason
            self.resolvedPath = resolvedPath
        }
    }

    /// Classifies a raw write path against the `[files]` policy.
    public static func classify(
        path: String,
        filesConfig: FilesConfig,
        requestedMode: String? = nil,
        homeDirectoryURL: URL? = nil
    ) -> Decision {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Decision(
                posture: .ask,
                reason: "Empty path: a write target must not be blank.",
                resolvedPath: ""
            )
        }
        let canonical = canonicalPath(trimmed)
        let home = effectiveHome(homeDirectoryURL)

        if let reason = denyReason(canonicalPath: canonical, home: home, filesConfig: filesConfig) {
            return Decision(posture: .deny, reason: reason, resolvedPath: canonical)
        }
        if let rule = matchingRule(canonicalPath: canonical, home: home, rules: filesConfig.writePathRules) {
            return Decision(
                posture: rule.posture,
                reason: "Write path rule '\(rule.path)' sets the \(rule.posture.rawValue) posture.",
                resolvedPath: canonical
            )
        }
        let roots = resolveAllowRoots(filesConfig.allowRoots, homeDirectoryURL: homeDirectoryURL)
        guard isInsideAnyRoot(canonical, roots: roots) else {
            return Decision(
                posture: .ask,
                reason: outsideRootsReason(roots: filesConfig.allowRoots),
                resolvedPath: canonical
            )
        }
        switch filesConfig.writeMode {
        case .staged:
            return Decision(
                posture: .stage,
                reason: "Owner setting files.write_mode = 'staged' stages this write for review.",
                resolvedPath: canonical
            )
        case .live:
            return Decision(
                posture: .live,
                reason: "Owner setting files.write_mode = 'live' applies this write live with a rollback copy.",
                resolvedPath: canonical
            )
        case .model:
            let liveRequested = (requestedMode ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == "live"
            return Decision(
                posture: liveRequested ? .live : .stage,
                reason: liveRequested
                    ? "Requested 'live' mode applies this write live with a rollback copy."
                    : "Write defaults to staged review when no live mode is requested.",
                resolvedPath: canonical
            )
        }
    }

    /// Canonical view of a raw path: tilde-expanded, made absolute, then standardized with symlinks
    /// resolved.
    public static func canonicalPath(_ rawPath: String) -> String {
        var trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasPrefix("file://") {
            trimmed = String(trimmed.dropFirst(7))
        }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let absolute = expanded.hasPrefix("/")
            ? expanded
            : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(expanded)
        let standardized = URL(fileURLWithPath: absolute).standardizedFileURL
        let fileManager = FileManager.default
        var existing = standardized
        var trailing: [String] = []
        while !fileManager.fileExists(atPath: existing.path), existing.path != "/" {
            trailing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        for component in trailing {
            resolved.appendPathComponent(component)
        }
        return resolved.path
    }

    /// Resolves configured allow roots to canonical absolute paths. - homeDirectoryURL: Effective
    /// home boundary override, if any.
    public static func resolveAllowRoots(_ roots: [String], homeDirectoryURL: URL? = nil) -> [String] {
        let home = effectiveHome(homeDirectoryURL)
        var resolved: [String] = []
        for raw in roots {
            var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("file://") {
                trimmed = String(trimmed.dropFirst(7))
            }
            let expanded: URL = if trimmed == "~" {
                home
            } else if trimmed.hasPrefix("~/") {
                home.appendingPathComponent(String(trimmed.dropFirst(2)))
            } else if trimmed.hasPrefix("/") {
                URL(fileURLWithPath: trimmed)
            } else {
                home.appendingPathComponent(trimmed)
            }
            resolved.append(expanded.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL.path)
        }
        return resolved
    }

    /// Canonical home boundary, honouring a test override.
    /// - Parameter overriding: Home override, if any.
    /// - Returns: Canonical home URL.
    private static func effectiveHome(_ overriding: URL?) -> URL {
        let base = overriding ?? FileManager.default.homeDirectoryForCurrentUser
        return base.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Deny-pattern reason for a canonical path, or nil when none matches.
    private static func denyReason(canonicalPath: String, home: URL, filesConfig: FilesConfig) -> String? {
        let candidates = denyCandidateViews(canonicalPath: canonicalPath, home: home)
        // Engine-owned protected patterns are unioned ahead of the configured
        // list so no operator list can silently drop them (configured patterns
        // stay fully additive).
        for rawPattern in alwaysDenyPatterns + filesConfig.denyPatterns {
            let trimmed = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let lowered = trimmed.lowercased()
            // Bare `~` denies the home tree, not just the directory inode, so a
            // broad operator entry cannot silently pass its children.
            if lowered == "~" {
                if WorkspaceContainment.isInsidePath(canonicalPath.lowercased(), root: home.path.lowercased()) {
                    return denyReasonText(trimmed)
                }
                continue
            }
            // Tilde-anchored patterns resolve against the effective home
            // (honouring the override) rather than the process home.
            let variants: [String] = if lowered.hasPrefix("~/") {
                [lowered, home.path.lowercased() + String(lowered.dropFirst(1))]
            } else {
                [lowered]
            }
            for variant in variants {
                if candidates.contains(where: { SharedGlobMatching.matches(pattern: variant, relativePath: $0) }) {
                    return denyReasonText(trimmed)
                }
                // A trailing `/*` also guards its bare directory and all
                // descendants at any depth, mirroring the containment rule for
                // roots like the vector store and browser profiles.
                if variant.hasSuffix("/*") {
                    let base = String(variant.dropLast(2))
                    let prefix = base + "/"
                    if candidates.contains(where: { $0 == base || $0.hasPrefix(prefix) }) {
                        return denyReasonText(trimmed)
                    }
                }
            }
        }
        return nil
    }

    /// Deny reason naming the matched pattern.
    /// - Parameter trimmed: Pattern that matched.
    /// - Returns: Reason text carrying no file content.
    private static func denyReasonText(_ trimmed: String) -> String {
        "Path matches deny pattern '\(trimmed)'; writing is refused by policy."
    }

    /// Candidate views a canonical path contributes to deny matching: the filename, the
    /// home-relative path plus its trailing suffixes, and the absolute path — all lowercased for the
    /// case-insensitive macOS view.
    private static func denyCandidateViews(canonicalPath: String, home: URL) -> Set<String> {
        var candidates: Set<String> = [
            URL(fileURLWithPath: canonicalPath).lastPathComponent.lowercased(),
            canonicalPath.lowercased()
        ]
        let prefix = home.path.hasSuffix("/") ? home.path : home.path + "/"
        guard canonicalPath != home.path, canonicalPath.hasPrefix(prefix) else {
            return candidates
        }
        let relative = String(canonicalPath.dropFirst(prefix.count)).lowercased()
        guard !relative.isEmpty else { return candidates }
        candidates.insert(relative)
        let segments = relative.split(separator: "/").map(String.init)
        if segments.count > 1 {
            for start in 1 ..< segments.count {
                candidates.insert(segments[start...].joined(separator: "/"))
            }
        }
        return candidates
    }

    /// The longest write-path rule whose canonical base covers the target. - home: Canonical home
    /// boundary for `~` expansion.
    private static func matchingRule(canonicalPath: String, home: URL, rules: [FilesWritePathRule]) -> FilesWritePathRule? {
        var best: FilesWritePathRule?
        var bestLength = -1
        for rule in rules {
            guard let base = canonicalRuleBase(rule.path, home: home) else { continue }
            guard WorkspaceContainment.isInsidePath(canonicalPath, root: base) else { continue }
            if base.count > bestLength {
                best = rule
                bestLength = base.count
            }
        }
        return best
    }

    /// Canonical base a rule path covers, or nil when it can never match.
    private static func canonicalRuleBase(_ rawPath: String, home: URL) -> String? {
        var trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("file://") {
            trimmed = String(trimmed.dropFirst(7))
        }
        let expanded: URL
        if trimmed == "~" {
            expanded = home
        } else if trimmed.hasPrefix("~/") {
            expanded = home.appendingPathComponent(String(trimmed.dropFirst(2)))
        } else {
            guard trimmed.hasPrefix("/") else { return nil }
            expanded = URL(fileURLWithPath: trimmed)
        }
        var path = expanded.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL.path
        if path.hasSuffix("/*") {
            path = String(path.dropLast(2))
        }
        return path
    }

    /// Whether a canonical path sits inside any resolved allow root.
    private static func isInsideAnyRoot(_ target: String, roots: [String]) -> Bool {
        roots.contains { WorkspaceContainment.isInsidePath(target, root: $0) }
    }

    /// Outside-roots ask reason, naming the configured roots.
    /// - Parameter roots: Raw `[files] allow_roots` entries.
    /// - Returns: Reason text carrying no file content.
    private static func outsideRootsReason(roots: [String]) -> String {
        let trimmed = roots.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if trimmed.isEmpty {
            return "No allowed roots are configured; writing requires explicit approval."
        }
        if trimmed == ["~"] {
            return "Path resolves outside the home directory; writing requires explicit approval."
        }
        return "Path resolves outside the allowed roots (\(trimmed.joined(separator: ", "))); writing requires explicit approval."
    }
}

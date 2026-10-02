// Rune Weaver Tools — Shared sensitive-path guard for file tools.
//
// Single source of truth for the `[files]` path policy (`deny_patterns`,
// `allow_roots`, `require_approval_on_deny`). Every file-tool read evaluates
// here first: deny hits escalate to the approvals inbox (or fail closed when
// configured), outside-root paths refuse with the configured roots named, and
// only inside-root, non-denied paths read without escalation.
//
// Every check runs on a canonical view (standardised plus symlink-resolved) so
// a symlinked parent or `..` segment cannot hide the true location. Matching
// is case-insensitive across three candidate views — filename, home-relative
// path plus its suffixes (so `.ssh/*` guards nested depths), and absolute path
// — with a trailing-`/*` also guarding its bare directory, and `~` shapes
// resolving against the effective home rather than the process home. A
// reserved `.rune_`/`.rune_backup_` review sibling also contributes its
// derived live file's candidate views, so a staging or rollback name cannot
// reach bytes the live path refuses.

import Foundation
import RuneWeaverCore
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Failure opening a guarded path without following symlinks.
public enum FilesAccessOpenError: Error, Sendable, Equatable {
    /// Policy denied the path (point-in-time or re-validated handle path).
    case denied(String)
    /// The final component is a symlink, refused without following it.
    case symlinkRefused(String)
    /// The file could not be opened or inspected.
    case openFailed(String)
}

/// Single source of truth for file-tool path policy.
public enum FilesAccessGuard: Sendable {
    /// Outcome of evaluating one path.
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
        public init(allowed: Bool, requiresApproval: Bool, reason: String?, resolvedPath: String) {
            self.allowed = allowed
            self.requiresApproval = requiresApproval
            self.reason = reason
            self.resolvedPath = resolvedPath
        }
    }

    /// Engine-owned deny patterns enforced on every evaluation regardless of
    /// the configured `[files] deny_patterns` list.
    ///
    /// An explicit operator list replaces the editable defaults by design, so
    /// without this union a hand-edited or dashboard-saved config could
    /// silently drop the engine's own private state from the guard. Persistent
    /// browser-profile bytes (cookies, session tokens), the engine's whole
    /// memory tree (episodic sessions and approvals, the trust-grant ledger,
    /// the plaintext profile, and semantic vectors), the egress policy control
    /// file, and the engine's own credentials (the owner bearer-token file and
    /// per-install SearXNG settings) must never be readable or writable by
    /// file tools or enter LLM context, so operators may extend the guard but
    /// never drop these protected patterns.
    /// Deny matching also folds in the `.rune_`/`.rune_backup_` review siblings
    /// of each live target, so the derived review names inherit the same
    /// protection.
    static let alwaysDenyPatterns: [String] = [
        ".runeweaver/memory/*",
        ".runeweaver/memory/vectors/*",
        ".runeweaver/browser_profiles/*",
        ".runeweaver/policy.toml",
        ".runeweaver/auth_token",
        ".runeweaver/searxng/*"
    ]

    /// Evaluates a raw path string against the `[files]` policy.
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
    /// Resolution is point-in-time: the nearest existing ancestor is resolved
    /// once and missing trailing components are re-appended without a second
    /// validation, so a symlink swapped between this check and the later open
    /// could redirect the final target. Callers that read file bytes open via
    /// `openNoFollowAndValidate` instead of trusting this view across the gap.
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
        let url = URL(fileURLWithPath: absolute).standardizedFileURL
        // Walk up until we find an existing ancestor, resolve it, then re-append.
        let fileManager = FileManager.default
        var existing = url
        var trailing: [String] = []
        while !fileManager.fileExists(atPath: existing.path), existing.path != "/" {
            trailing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        for component in trailing {
            resolved.appendPathComponent(component)
        }
        return resolved
    }

    /// Opens a guarded path for reading without following a trailing symlink,
    /// then re-validates the opened handle against policy before returning it.
    /// Point-in-time evaluation alone leaves a symlink-swap gap between the
    /// check and the open, so the open refuses symlinked finals and the live
    /// handle path is checked again while its inode is pinned.
    /// - Parameters:
    ///   - path: Raw caller path (tilde and relative forms accepted).
    ///   - homeDirectoryURL: Test home override, if any.
    ///   - filesConfig: `[files]` policy to enforce on both checks.
    /// - Returns: Open handle plus the validated handle path.
    public static func openNoFollowAndValidate(
        path: String,
        homeDirectoryURL: URL? = nil,
        filesConfig: FilesConfig = FilesConfig()
    ) throws -> (handle: FileHandle, resolvedPath: String) {
        let decision = evaluate(path: path, homeDirectoryURL: homeDirectoryURL, filesConfig: filesConfig)
        guard decision.allowed else {
            throw FilesAccessOpenError.denied(decision.reason ?? "Reading this path requires explicit approval.")
        }
        let fd: Int32 = decision.resolvedPath.withCString { cString in
            open(cString, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else {
            if errno == ELOOP {
                throw FilesAccessOpenError.symlinkRefused(
                    "Refusing to follow symlink at \(decision.resolvedPath)."
                )
            }
            throw FilesAccessOpenError.openFailed(
                "Could not open file: \(decision.resolvedPath)."
            )
        }
        // The pinned descriptor outlives the read and would otherwise be
        // inherited by plugin and voice children, so enforce close-on-exec
        // even where the open-time flag is ignored.
        let existingFDFlags = fcntl(fd, F_GETFD)
        if existingFDFlags != -1 {
            _ = fcntl(fd, F_SETFD, existingFDFlags | FD_CLOEXEC)
        } else {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }
        guard let handlePath = handlePath(for: fd) else {
            _ = close(fd)
            throw FilesAccessOpenError.openFailed("Could not resolve opened file path.")
        }
        var statBuf = stat()
        guard fstat(fd, &statBuf) == 0 else {
            _ = close(fd)
            throw FilesAccessOpenError.openFailed("Could not stat opened file.")
        }
        // Refuse directories here so a directory handle never masquerades as
        // file bytes further up the call chain.
        let fileType = statBuf.st_mode & S_IFMT
        if fileType == S_IFDIR {
            _ = close(fd)
            throw FilesAccessOpenError.openFailed("Not a file: \(handlePath).")
        }
        // The descriptor pins the inode, so re-checking its live path closes
        // a swap that landed after the first evaluation.
        let recheck = evaluate(path: handlePath, homeDirectoryURL: homeDirectoryURL, filesConfig: filesConfig)
        guard recheck.allowed else {
            _ = close(fd)
            throw FilesAccessOpenError.denied(recheck.reason ?? "Reading this path requires explicit approval.")
        }
        return (FileHandle(fileDescriptor: fd, closeOnDealloc: true), recheck.resolvedPath)
    }

    /// Resolves the live filesystem path backing an open descriptor.
    private static func handlePath(for fd: Int32) -> String? {
        #if canImport(Darwin)
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let result = buffer.withUnsafeMutableBufferPointer { pointer -> Int32 in
                guard let base = pointer.baseAddress else { return -1 }
                return fcntl(fd, F_GETPATH, base)
            }
            guard result != -1 else { return nil }
            // Decode through the pointer form so decoding stops at the first
            // NUL instead of carrying the trailing padding into the path.
            return buffer.withUnsafeBufferPointer { pointer -> String? in
                guard let base = pointer.baseAddress else { return nil }
                return String(cString: base)
            }
        #else
            let procPath = "/proc/self/fd/\(fd)"
            var buffer = [CChar](repeating: 0, count: 4096)
            let length: Int = procPath.withCString { procCString in
                buffer.withUnsafeMutableBufferPointer { bufPtr -> Int in
                    guard let base = bufPtr.baseAddress else { return -1 }
                    return readlink(procCString, base, bufPtr.count - 1)
                }
            }
            guard length > 0, length < buffer.count else { return nil }
            buffer[length] = 0
            // Decode through the pointer form so decoding stops at the first
            // NUL instead of carrying the trailing padding into the path.
            return buffer.withUnsafeBufferPointer { pointer -> String? in
                guard let base = pointer.baseAddress else { return nil }
                return String(cString: base)
            }
        #endif
    }

    /// Resolves the home boundary to a canonical URL.
    /// - Parameter overriding: Test override, if any.
    /// - Returns: Canonical home URL.
    public static func resolvedHomeURL(overriding: URL? = nil) -> URL {
        let base = overriding ?? FileManager.default.homeDirectoryForCurrentUser
        return base.standardized.resolvingSymlinksInPath()
    }

    /// Returns the deny-pattern reason for a canonical URL, if any.
    private static func denyReason(for canonical: URL, home: URL, filesConfig: FilesConfig) -> String? {
        // Candidate views, lowercased once: the filename catches bare shapes
        // (`*.pem`), the relative path and its suffixes catch directory shapes
        // at any depth (`.ssh/*`), and the absolute path catches rooted
        // absolute patterns. A reserved review sibling also contributes the
        // candidates of the live file it derives from, so a `.rune_`/
        // `.rune_backup_` name cannot reach bytes its live path refuses.
        var candidates = denyCandidateViews(for: canonical, home: home)
        if let liveName = liveSiblingName(for: canonical.lastPathComponent) {
            let liveURL = canonical.deletingLastPathComponent().appendingPathComponent(liveName)
            candidates.formUnion(denyCandidateViews(for: liveURL, home: home))
        }
        // Engine-owned protected patterns are unioned ahead of the configured
        // list so no operator list can silently drop them (configured patterns
        // stay fully additive).
        for rawPattern in alwaysDenyPatterns + filesConfig.denyPatterns {
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
                // A trailing `/*` also guards its bare directory and all descendants
                // at any depth, mirroring the containment rule for roots like
                // the vector store and browser profiles.
                if variant.hasSuffix("/*") {
                    let base = String(variant.dropLast(2))
                    let prefix = base + "/"
                    for candidate in candidates {
                        if candidate == base || candidate.hasPrefix(prefix) {
                            return "Path matches deny pattern '\(trimmed)'; reading requires explicit approval."
                        }
                    }
                }
            }
        }
        return nil
    }

    /// Resolves configured allow roots to canonical absolute paths.
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
    private static func isInsideAnyRoot(_ target: String, roots: [String]) -> Bool {
        roots.contains { isInside(target, root: $0) }
    }

    /// Builds the outside-roots denial reason.
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
    private static func isInside(_ target: String, root: String) -> Bool {
        if target == root {
            return true
        }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return target.hasPrefix(prefix)
    }
}

/// Deny-matching candidate derivation kept out of the guard's primary body.
private extension FilesAccessGuard {
    /// Candidate views a canonical URL contributes to deny matching: the
    /// filename, the home-relative path plus its trailing suffixes, and the
    /// absolute path — all lowercased for the case-insensitive macOS view.
    /// - Parameters:
    ///   - canonical: Canonical URL to view.
    ///   - home: Canonical home boundary.
    /// - Returns: Lowercased candidate views.
    static func denyCandidateViews(for canonical: URL, home: URL) -> Set<String> {
        var candidates: Set<String> = [canonical.lastPathComponent.lowercased(), canonical.path.lowercased()]
        guard isInside(canonical.path, root: home.path), canonical.path != home.path else {
            return candidates
        }
        let prefix = home.path.hasSuffix("/") ? home.path : home.path + "/"
        guard canonical.path.hasPrefix(prefix) else {
            return candidates
        }
        let relative = String(canonical.path.dropFirst(prefix.count)).lowercased()
        guard !relative.isEmpty else {
            return candidates
        }
        candidates.insert(relative)
        let segments = relative.split(separator: "/").map(String.init)
        if segments.count > 1 {
            for start in 1 ..< segments.count {
                candidates.insert(segments[start...].joined(separator: "/"))
            }
        }
        return candidates
    }

    /// Live filename a reserved review sibling derives from, or nil when the
    /// filename is not a `.rune_`/`.rune_backup_` artifact.
    ///
    /// Prefix matching folds case because the default APFS volume does: a
    /// differently-cased spelling names the same artifact on disk. The
    /// rollback prefix is tested first because it contains the staging prefix.
    /// - Parameter filename: Final path component to test.
    /// - Returns: The live filename, or nil when the name is not a sibling.
    static func liveSiblingName(for filename: String) -> String? {
        let lowered = filename.lowercased()
        let prefix: String
        if lowered.hasPrefix(ReviewArtifacts.backupPrefix) {
            prefix = ReviewArtifacts.backupPrefix
        } else if lowered.hasPrefix(ReviewArtifacts.stagingPrefix) {
            prefix = ReviewArtifacts.stagingPrefix
        } else {
            return nil
        }
        let liveName = String(filename.dropFirst(prefix.count))
        return liveName.isEmpty ? nil : liveName
    }
}

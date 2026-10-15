// Rune Weaver Core — Agent scratch workspace with quotas and temp retention.
//
// Purpose: own the `~/.runeweaver/workspace` scratch directory that shell
// execution uses as its default working directory, bounding its growth with
// explicit size and file quotas plus age-based `tmp/` pruning.
// Scope: directory creation with owner-only permissions, bounded usage walks
// that never follow symlinks, quota enforcement with honest typed errors, and
// temp retention keyed by `[workspace] tmp_ttl_days`.
// Architectural role: `WorkspaceStore` actor beside the other Core stores so
// service boot and shell execution share one quota source; recall never sees
// this tree because the files walker prunes it unconditionally.

import Foundation

/// Bounded size and file counts for one workspace walk.
public struct WorkspaceUsage: Sendable, Equatable {
    /// Total bytes across counted regular files.
    public let bytes: Int
    /// Total regular files counted.
    public let files: Int
    /// Whether the walk stopped at the entry cap before covering the tree.
    public let truncated: Bool

    /// Creates a workspace usage snapshot.
    public init(bytes: Int, files: Int, truncated: Bool) {
        self.bytes = bytes
        self.files = files
        self.truncated = truncated
    }
}

/// Typed workspace failures with owner-actionable copy.
public enum WorkspaceError: Error, Sendable, Equatable {
    /// The workspace directory could not be created or secured.
    case ensureFailed(reason: String)
    /// Current usage exceeds the configured size or file quota.
    case quotaExceeded(bytes: Int, files: Int, truncated: Bool, quotaMB: Int, quotaFiles: Int)

    /// Human-readable reason, safe to surface to the owner.
    public var reason: String {
        switch self {
        case let .ensureFailed(reason):
            return reason
        case let .quotaExceeded(bytes, files, truncated, quotaMB, quotaFiles):
            let quotaBytes = quotaMB * 1024 * 1024
            let truncatedNote = truncated ? " (walk truncated; actual usage may be higher)" : ""
            return "Workspace quota exceeded: \(bytes) bytes across \(files) files\(truncatedNote)"
                + " exceeds limits of \(quotaMB) MB (\(quotaBytes) bytes) / \(quotaFiles) files."
                + " Prune workspace/tmp or raise [workspace] quotas."
        }
    }
}

extension WorkspaceError: LocalizedError {
    public var errorDescription: String? {
        reason
    }
}

/// Actor owning the agent scratch workspace on disk.
///
/// One store owns the root so boot pruning and shell quota checks observe the
/// same limits: the root resolves under the effective home, creation enforces
/// owner-only permissions even when the directory already exists, usage walks
/// stay bounded so a huge scratch tree cannot stall a turn, and temp pruning
/// keeps `tmp/` from accumulating without manual cleanup. The walker never
/// follows symlinks so a link loop or a link out of the workspace cannot be
/// traversed or counted.
public actor WorkspaceStore {
    /// Name of the temp subdirectory pruned by age.
    public static let tmpDirectoryName = "tmp"

    /// Resolved quotas and retention for this store.
    ///
    /// Mutable behind the actor so a settings save can push fresh quotas into
    /// the live store without rebuilding the root: usage, prune, and quota
    /// checks all derive limits per call, so the next check after an update
    /// enforces the new bounds while hermetic roots stay pinned.
    public private(set) var config: WorkspaceConfig
    /// Home boundary override for tests; nil means the real home.
    private let homeDirectoryURL: URL?
    /// Direct root override for tests; nil derives `~/.runeweaver/workspace`.
    private let rootOverride: URL?

    /// Creates a workspace store.
    /// - Parameters:
    ///   - config: Quotas and retention from `[workspace]`.
    ///   - homeDirectoryURL: Home boundary override, or nil for the real home.
    ///   - rootURL: Direct root override for hermetic tests, or nil to derive from home.
    public init(
        config: WorkspaceConfig = WorkspaceConfig(),
        homeDirectoryURL: URL? = nil,
        rootURL: URL? = nil
    ) {
        self.config = config
        self.homeDirectoryURL = homeDirectoryURL
        self.rootOverride = rootURL
    }

    /// Pushes fresh quotas into the live store without moving the root.
    ///
    /// The root overrides never change here, so a quota decrease takes effect
    /// on the next enforcement check while isolated test roots keep pointing
    /// at the same tree instead of falling back to the real home.
    /// - Parameter newConfig: Fresh `[workspace]` policy from the merged file state.
    public func updateConfig(_ newConfig: WorkspaceConfig) {
        config = newConfig
    }

    /// Returns the hermetic root overrides backing this store.
    ///
    /// Callers rebuilding a store for a live-reload pass the pair straight
    /// into the fresh init, so the rebuilt shell observes the same isolated
    /// tree instead of enforcing quotas against the wrong directory.
    /// - Returns: Home boundary plus direct root overrides for the fresh init.
    public func overrides() -> (homeDirectoryURL: URL?, rootURL: URL?) {
        (homeDirectoryURL, rootOverride)
    }

    /// Resolves the workspace root without touching disk.
    ///
    /// The override wins untouched for hermetic tests; otherwise the root
    /// derives as `~/.runeweaver/workspace` under the effective home so every
    /// boot and shell turn agrees on one location.
    /// - Returns: Canonical workspace root URL.
    public func root() -> URL {
        Self.resolveRoot(homeDirectoryURL: homeDirectoryURL, rootOverride: rootOverride)
    }

    /// Resolves the workspace root for the given overrides without touching disk.
    /// - Parameters:
    ///   - homeDirectoryURL: Home boundary override, or nil for the real home.
    ///   - rootOverride: Direct root override, or nil to derive from home.
    /// - Returns: Canonical workspace root URL.
    public static func resolveRoot(homeDirectoryURL: URL? = nil, rootOverride: URL? = nil) -> URL {
        if let rootOverride {
            return rootOverride.standardizedFileURL
        }
        let home = homeDirectoryURL ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".runeweaver/workspace").standardizedFileURL
    }

    /// Refuses when the workspace root or its `tmp/` is a symlink.
    ///
    /// A sandboxed `bash.exec` can swap `workspace -> /` between turns;
    /// creating, walking, or pruning through the link would then chmod,
    /// enumerate, or delete outside the workspace. Every entry point calls
    /// this before touching disk so the failure surfaces as `ensureFailed`
    /// instead of an outside-tree walk. The link probe itself is
    /// single-sourced via `WorkspaceContainment`.
    /// - Parameters:
    ///   - rootURL: Standardized workspace root.
    ///   - tmpURL: Standardized `tmp/` URL, or nil to check the root only.
    /// - Throws: ``WorkspaceError/ensureFailed(reason:)`` when either path is a symlink.
    private static func refuseSymlinkedRoot(_ rootURL: URL, tmpURL: URL? = nil) throws {
        var probe: [URL] = [rootURL]
        if let tmpURL {
            probe.append(tmpURL)
        }
        if let bad = WorkspaceContainment.firstSymlink(in: probe) {
            if bad.path == rootURL.path {
                throw WorkspaceError.ensureFailed(reason: "Workspace unavailable at \(rootURL.path): workspace root is a symlink and will not be followed")
            }
            throw WorkspaceError.ensureFailed(
                reason: "Workspace tmp unavailable at \(tmpURL?.path ?? bad.path): tmp directory is a symlink and will not be followed"
            )
        }
    }

    /// Expected canonical workspace root for containment checks.
    ///
    /// Production derives from the canonical home plus the fixed suffix
    /// without resolving the suffix itself, so a swapped intermediate such
    /// as `~/.runeweaver -> /` diverges from the expectation instead of
    /// resolving identically on both sides. Test overrides anchor on the
    /// override canonical so hermetic roots under system temp stay usable.
    private func expectedCanonicalRoot() -> URL {
        if let rootOverride {
            return WorkspaceContainment.canonical(rootOverride.standardizedFileURL)
        }
        let home = homeDirectoryURL ?? FileManager.default.homeDirectoryForCurrentUser
        let homeCanonical = WorkspaceContainment.canonical(home.standardizedFileURL)
        return homeCanonical.appendingPathComponent(".runeweaver/workspace").standardizedFileURL
    }

    /// Refuses when a symlink-resolved path escapes the expected root.
    ///
    /// `refuseSymlinkedRoot` covers only the final component via `lstat`; an
    /// intermediate swap (`~/.runeweaver -> /`) still passes it while
    /// `resolvingSymlinksInPath` lands outside the workspace. Every entry
    /// point verifies the canonical view stays under the expected root and
    /// fails closed otherwise. The check is point-in-time alongside the
    /// later symlink-skipping walk, not a substitute for it. Boundary math is
    /// single-sourced via `WorkspaceContainment`.
    private func verifyCanonicalContainment(canonical: URL, lexical: URL) throws {
        let expected = expectedCanonicalRoot()
        guard !WorkspaceContainment.escapesRoot(canonical: canonical, expectedRoot: expected) else {
            throw WorkspaceError.ensureFailed(reason: "Workspace unavailable at \(lexical.path): resolved path escapes workspace boundary (\(canonical.path))")
        }
    }

    /// Creates the workspace root (plus `tmp/`) with owner-only permissions.
    ///
    /// Creation is idempotent: an existing directory is re-secured to `0700`
    /// so a permissive `umask` or a restored backup cannot leave scratch
    /// world-readable. Failures throw instead of falling back to another
    /// directory, because a silent fallback would run commands in an
    /// unexpected location. A symlinked root or `tmp/` refuses fail-closed
    /// before any create or chmod follows the link outside the workspace.
    /// - Returns: The secured workspace root.
    /// - Throws: ``WorkspaceError/ensureFailed(reason:)`` when creation fails.
    @discardableResult
    public func ensure() throws -> URL {
        let rootURL = root()
        do {
            try Self.refuseSymlinkedRoot(rootURL)
            let tmpURL = rootURL.appendingPathComponent(Self.tmpDirectoryName)
            if WorkspaceContainment.isSymlink(at: tmpURL) {
                throw WorkspaceError.ensureFailed(reason: "Workspace tmp unavailable at \(tmpURL.path): tmp directory is a symlink and will not be followed")
            }
            // Re-validate after symlink resolution so a swapped intermediate
            // (`~/.runeweaver -> /`) cannot steer creation outside the
            // home-derived root even though the final component is not a link.
            let canonicalRoot = WorkspaceContainment.canonical(rootURL)
            try verifyCanonicalContainment(canonical: canonicalRoot, lexical: rootURL)
            let canonicalTmp = WorkspaceContainment.canonical(tmpURL)
            try verifyCanonicalContainment(canonical: canonicalTmp, lexical: tmpURL)
            try FileManager.default.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            // Re-secure when the directory already existed: creation alone
            // leaves existing permissions untouched. A chmod failure throws
            // through the outer catch as `ensureFailed` so a permissive
            // restored backup or umask never stays world-readable silently.
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootURL.path)
            try FileManager.default.createDirectory(
                at: tmpURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tmpURL.path)
            return rootURL
        } catch let error as WorkspaceError {
            throw error
        } catch {
            throw WorkspaceError.ensureFailed(reason: "Workspace unavailable at \(rootURL.path): \(error.localizedDescription)")
        }
    }

    /// Measures current usage with a bounded walk that never follows symlinks.
    ///
    /// The walk caps at twice the file quota so a huge scratch tree cannot
    /// stall a turn: reaching the cap reports `truncated` so callers know the
    /// counts are lower bounds, and any enumeration error also marks the walk
    /// truncated so an undercount never reads as a clean pass. Symlinked
    /// entries are skipped without descending, so a link loop cannot hang the
    /// walk and a link out of the workspace is never counted. A symlinked
    /// workspace root refuses fail-closed before the walk, and the walk runs
    /// on the symlink-resolved canonical root, so a swapped `workspace -> /`
    /// never enumerates outside the workspace.
    /// - Returns: Byte and file counts plus whether the cap truncated the walk.
    /// - Throws: ``WorkspaceError/ensureFailed(reason:)`` when the workspace
    ///   cannot be enumerated.
    public func usage() throws -> WorkspaceUsage {
        let limits = config.clamped()
        let cap = max(1, limits.quotaFiles * 2)
        let rootURL = root()
        try Self.refuseSymlinkedRoot(rootURL)
        let canonicalRoot = WorkspaceContainment.canonical(rootURL)
        // Fail closed when resolution escapes the home-derived root: without
        // this a swapped intermediate would enumerate outside the workspace
        // even though the final component passed the `lstat` refusal above.
        try verifyCanonicalContainment(canonical: canonicalRoot, lexical: rootURL)
        guard FileManager.default.fileExists(atPath: canonicalRoot.path) else {
            return WorkspaceUsage(bytes: 0, files: 0, truncated: false)
        }
        // An enumeration failure undercounts the tree, so it must surface as
        // truncated rather than as a clean lower bound.
        var enumerationFailed = false
        guard let enumerator = FileManager.default.enumerator(
            at: canonicalRoot,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey],
            options: [],
            errorHandler: { _, _ in
                enumerationFailed = true
                return true
            }
        ) else {
            throw WorkspaceError.ensureFailed(reason: "Workspace unavailable at \(rootURL.path): unable to enumerate workspace")
        }
        var bytes = 0
        var files = 0
        var entries = 0
        var truncated = false
        for case let url as URL in enumerator {
            if entries >= cap {
                truncated = true
                break
            }
            entries += 1
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey])
            // A symlink is never followed: a link loop cannot form and a link
            // cannot pull outside bytes into the quota.
            if values?.isSymbolicLink == true {
                if values?.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            if values?.isDirectory == true {
                continue
            }
            files += 1
            if let size = values?.fileSize {
                bytes += size
            }
        }
        if enumerationFailed {
            truncated = true
        }
        return WorkspaceUsage(bytes: bytes, files: files, truncated: truncated)
    }

    /// Deletes `tmp/` entries older than the configured retention.
    ///
    /// Each immediate child of `tmp/` is judged by its own modification time
    /// so one stale download cannot pin the whole directory; directories go
    /// recursively. A zero TTL clears every entry, giving owners a one-line
    /// "clear scratch on boot" switch. Missing `tmp/` is a no-op returning
    /// zero rather than an error, because a fresh workspace has nothing to prune.
    /// A symlinked root or `tmp/` refuses fail-closed before listing, and the
    /// listing plus removals run on the symlink-resolved canonical `tmp/`, so
    /// a swapped `workspace -> /` never deletes children outside the workspace.
    /// - Parameter now: Reference instant for age comparison.
    /// - Returns: Number of top-level `tmp/` entries removed.
    @discardableResult
    public func pruneTmp(now: Date = Date()) throws -> Int {
        let retention = config.clamped().tmpTTLDays
        let rootURL = root()
        let tmpURL = rootURL.appendingPathComponent(Self.tmpDirectoryName)
        try Self.refuseSymlinkedRoot(rootURL, tmpURL: tmpURL)
        let canonicalTmp = WorkspaceContainment.canonical(tmpURL)
        // Fail closed when resolution escapes the home-derived root: without
        // this a swapped intermediate would list and delete outside the
        // workspace even though the final components passed `lstat` above.
        let canonicalRoot = WorkspaceContainment.canonical(rootURL)
        try verifyCanonicalContainment(canonical: canonicalRoot, lexical: rootURL)
        try verifyCanonicalContainment(canonical: canonicalTmp, lexical: tmpURL)
        guard FileManager.default.fileExists(atPath: canonicalTmp.path) else {
            return 0
        }
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: canonicalTmp,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: []
            )
        } catch {
            throw WorkspaceError.ensureFailed(reason: "Workspace tmp unavailable at \(tmpURL.path): \(error.localizedDescription)")
        }
        // Zero retention clears everything without consulting mtimes, so a
        // clock skew can never spare a stale entry.
        if retention <= 0 {
            var removed = 0
            for child in children {
                do {
                    try FileManager.default.removeItem(at: child)
                    removed += 1
                } catch {
                    continue
                }
            }
            return removed
        }
        let cutoff = now.addingTimeInterval(TimeInterval(-retention * 24 * 60 * 60))
        var removed = 0
        for child in children {
            let values = try? child.resourceValues(forKeys: [.contentModificationDateKey])
            guard let mtime = values?.contentModificationDate else {
                continue
            }
            guard mtime < cutoff else {
                continue
            }
            do {
                try FileManager.default.removeItem(at: child)
                removed += 1
            } catch {
                continue
            }
        }
        return removed
    }

    /// Refuses when current usage exceeds the configured quotas.
    ///
    /// Runs before a shell spawn so an over-quota turn fails with quota
    /// guidance instead of executing and growing the tree further. Both
    /// dimensions are checked: bytes against `quota_mb` and files against
    /// `quota_files`, with the truncated flag carried so a bounded walk that
    /// already exceeds the quota still refuses honestly. A truncated walk
    /// fails closed even when its lower bounds sit under quota, because the
    /// unseen remainder may exceed it.
    /// - Throws: ``WorkspaceError/quotaExceeded`` naming usage versus limits.
    public func checkQuota() throws {
        let limits = config.clamped()
        let current = try usage()
        if current.truncated {
            throw WorkspaceError.quotaExceeded(
                bytes: current.bytes,
                files: current.files,
                truncated: true,
                quotaMB: limits.quotaMB,
                quotaFiles: limits.quotaFiles
            )
        }
        let quotaBytes = limits.quotaMB * 1024 * 1024
        if current.bytes > quotaBytes || current.files > limits.quotaFiles {
            throw WorkspaceError.quotaExceeded(
                bytes: current.bytes,
                files: current.files,
                truncated: current.truncated,
                quotaMB: limits.quotaMB,
                quotaFiles: limits.quotaFiles
            )
        }
    }
}

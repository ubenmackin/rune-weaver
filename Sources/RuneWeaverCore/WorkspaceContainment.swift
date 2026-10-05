// Rune Weaver Core — Single-sourced workspace containment plus immutable staging.
//
// Purpose: own the `lstat` symlink probe, slash-boundary prefix check, and
// canonical containment used by the scratch workspace and the hash-pinned
// agent-tool registry, so a swapped `workspace -> /` or `tmp -> /` refuses
// identically on every path and verified bytes never observe a writable window.
// Scope: symlink probing without following links, boundary-aware prefix
// checks, canonical resolution, eligible-directory containment, relative
// `workspace/` prefix stripping, and atomic owner-execute-only staging writes
// only; quotas, SQLite persistence, and HTTP routing live with the owning
// stores and server layers.
// Architectural role: shared Core helper beside the goal and policy stores,
// called by `WorkspaceStore` and `AgentToolStore` instead of triplicated
// private helpers, so containment agrees byte-for-byte.

import Foundation
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Single source for workspace boundary checks shared by the scratch store
/// and the hash-pinned agent-tool registry.
///
/// Both stores guard the same adversary: a sandboxed writer swapping
/// `workspace -> /` or `tmp -> /` between turns. The probe never follows the
/// final component, the prefix check never lets `workspace-evil/` match the
/// root, and both sides of every containment test resolve symlinks first so
/// a symlinked parent inside the tree cannot hide an outside target behind
/// an inside spelling.
public enum WorkspaceContainment {
    /// Whether the final path component is a symlink without following it.
    ///
    /// Uses `lstat` semantics (`isSymbolicLinkKey` plus a
    /// `destinationOfSymbolicLink` fallback for dangling links) so a swapped
    /// root or temp directory refuses before any create, walk, prune, or
    /// staged write follows it outside the workspace.
    /// - Parameter url: Path to probe.
    /// - Returns: True when the final component is a symlink.
    public static func isSymlink(at url: URL) -> Bool {
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            return true
        }
        return (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    /// Whether a canonical path sits inside a canonical root with a boundary.
    ///
    /// The trailing-slash form keeps `workspace-evil/` from prefix-matching
    /// the root. Callers pass already-canonical paths; see `canonical(_:)`
    /// and `isContained(path:inside:)` for the resolving variants.
    /// - Parameters:
    ///   - target: Canonical path under test.
    ///   - root: Canonical root boundary.
    /// - Returns: True when the target equals the root or sits beneath it.
    public static func isInsidePath(_ target: String, root: String) -> Bool {
        target == root || target.hasPrefix(root + "/")
    }

    /// Resolves symlinks and standardizes a path for containment checks.
    ///
    /// Both sides of every boundary test resolve together so benign system
    /// links (`/var` -> `/private/var` under test temp roots) stay usable
    /// while a swapped link diverges outside the root and refuses.
    /// - Parameter url: Path to canonicalize.
    /// - Returns: Symlink-resolved standardized URL.
    public static func canonical(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Whether a path resolves inside a directory with symlink safety.
    ///
    /// Both sides resolve before the boundary check, so a symlinked parent
    /// (`tools/evil -> /tmp` plus `tools/evil/pwn.sh`) cannot hide an outside
    /// target behind an inside spelling, and a moved workspace root still
    /// refuses at dispatch.
    /// - Parameters:
    ///   - path: Candidate path (absolute string form).
    ///   - directory: Eligible directory (unresolved is fine; resolved here).
    /// - Returns: True when the resolved candidate sits inside the resolved directory.
    public static func isContained(path: String, inside directory: URL) -> Bool {
        let candidate = canonical(URL(fileURLWithPath: path))
        let resolvedDir = canonical(directory)
        return isInsidePath(candidate.path, root: resolvedDir.path)
    }

    /// Whether a symlink-resolved path escapes an expected root.
    ///
    /// Point-in-time check alongside later symlink-skipping walks, not a
    /// substitute for them: an intermediate swap (`~/.runeweaver -> /`)
    /// passes the final-component `lstat` refusal while resolving outside,
    /// so every entry point verifies the canonical view stays under the
    /// expected root and fails closed otherwise.
    /// - Parameters:
    ///   - canonical: Symlink-resolved path under test.
    ///   - expectedRoot: Expected canonical root boundary.
    /// - Returns: True when the canonical path escapes and must refuse.
    public static func escapesRoot(canonical: URL, expectedRoot: URL) -> Bool {
        !isInsidePath(canonical.path, root: expectedRoot.path)
    }

    /// Finds the first symlinked URL in a probe list without following links.
    ///
    /// Lets each store refuse its own root plus temp plus tools pair through
    /// one probe while keeping its own typed error and copy: a non-nil return
    /// means the caller must fail closed before touching disk.
    /// - Parameter urls: Paths to probe in refusal order.
    /// - Returns: First symlinked URL, or nil when none are links.
    public static func firstSymlink(in urls: [URL]) -> URL? {
        for url in urls where isSymlink(at: url) {
            return url
        }
        return nil
    }

    /// Strips the redundant `workspace/` lead from a workspace-relative spelling.
    ///
    /// Relative promotion spellings resolve against the workspace root with a
    /// canonical `tools/` base, so `tools/cleanup.sh` and its absolute form
    /// agree. A legacy `workspace/tools/cleanup.sh` spelling strips to
    /// `tools/cleanup.sh` instead of nesting under `<root>/workspace/tools/`
    /// outside the eligible directory. Absolute and tilde spellings pass
    /// through untouched; the caller branches on the leading slash first.
    /// - Parameter path: Caller-supplied relative path.
    /// - Returns: Path without a leading `workspace/` segment when present.
    public static func stripWorkspacePrefix(_ path: String) -> String {
        if path == "workspace" {
            return ""
        }
        if path.hasPrefix("workspace/") {
            return String(path.dropFirst("workspace/".count))
        }
        return path
    }

    /// Writes bytes to a fresh file that is never writable.
    ///
    /// Reserves the destination exclusively (`O_CREAT|O_EXCL`) with
    /// owner-read plus execute bits (`0500`) before writing a single byte,
    /// so verified bytes never observe the writable window a create-then-chmod
    /// sequence leaves open. The random leaf name keeps a concurrent workspace
    /// writer from targeting a copy it cannot enumerate, and `O_NOFOLLOW`
    /// refuses a link planted at the destination instead of writing through
    /// it. Failures remove the partial copy so a torn write never survives.
    /// - Parameters:
    ///   - bytes: Exact bytes to stage.
    ///   - url: Fresh destination URL (must not exist).
    /// - Throws: An `NSError` in the `RuneWeaverCore` domain when reservation or the write fails.
    public static func writeImmutableBytes(_ bytes: Data, to url: URL) throws {
        let fd: Int32 = url.path.withCString { cString in
            open(cString, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, mode_t(0o500))
        }
        guard fd >= 0 else {
            throw NSError(
                domain: "RuneWeaverCore",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "could not stage temp file at \(url.path): \(String(cString: strerror(errno)))"]
            )
        }
        defer { _ = close(fd) }
        let existingFDFlags = fcntl(fd, F_GETFD)
        if existingFDFlags != -1 {
            _ = fcntl(fd, F_SETFD, existingFDFlags | FD_CLOEXEC)
        } else {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }
        do {
            try bytes.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress, !rawBuffer.isEmpty else { return }
                var offset = 0
                while offset < rawBuffer.count {
                    let written = write(fd, base.advanced(by: offset), rawBuffer.count - offset)
                    if written < 0 {
                        if errno == EINTR {
                            continue
                        }
                        throw NSError(
                            domain: "RuneWeaverCore",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "could not stage temp file at \(url.path): \(String(cString: strerror(errno)))"]
                        )
                    }
                    if written == 0 {
                        throw NSError(
                            domain: "RuneWeaverCore",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "could not stage temp file at \(url.path): short write"]
                        )
                    }
                    offset += Int(written)
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        // Re-assert owner-execute-only after the write so a permissive umask at
        // creation can never leave the payload writable; creation already
        // masked to at most 0500, so this only ever removes bits.
        _ = fchmod(fd, mode_t(0o500))
    }
}

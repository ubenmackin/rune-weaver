// Rune Weaver Core — Single-sourced workspace containment plus immutable staging.

import Foundation
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Single source for workspace boundary checks used by the scratch store. The scratch store guards
/// the same adversary: a sandboxed writer swapping `workspace -> /` or `tmp -> /` between turns.
public enum WorkspaceContainment {
    /// Whether the final path component is a symlink without following it.
    public static func isSymlink(at url: URL) -> Bool {
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            return true
        }
        return (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    /// Whether a canonical path sits inside a canonical root with a boundary. - root: Canonical
    /// root boundary.
    public static func isInsidePath(_ target: String, root: String) -> Bool {
        target == root || target.hasPrefix(root + "/")
    }

    /// Resolves symlinks and standardizes a path for containment checks.
    public static func canonical(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Whether a path resolves inside a directory with symlink safety.
    public static func isContained(path: String, inside directory: URL) -> Bool {
        let candidate = canonical(URL(fileURLWithPath: path))
        let resolvedDir = canonical(directory)
        return isInsidePath(candidate.path, root: resolvedDir.path)
    }

    /// Whether a symlink-resolved path escapes an expected root.
    public static func escapesRoot(canonical: URL, expectedRoot: URL) -> Bool {
        !isInsidePath(canonical.path, root: expectedRoot.path)
    }

    /// Finds the first symlinked URL in a probe list without following links.
    public static func firstSymlink(in urls: [URL]) -> URL? {
        for url in urls where isSymlink(at: url) {
            return url
        }
        return nil
    }

    /// Writes bytes to a fresh file that is never writable.
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

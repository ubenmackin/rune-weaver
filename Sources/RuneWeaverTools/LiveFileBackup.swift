// Rune Weaver Tools — Rollback-copy primitives behind a live-write review.

import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Filesystem primitives for the single rollback copy behind a live review.
public enum LiveFileBackup: Sendable {
    /// Creates a fresh snapshot of `liveURL` at `backupURL`. The destination must be absent: any
    /// entry already at the backup path — regular file, directory, or symlink — fails the snapshot
    /// closed and is never removed.
    public static func snapshot(liveURL: URL, backupURL: URL) throws {
        if let refusal = snapshotSourceRefusal(liveURL: liveURL, backupURL: backupURL) {
            throw fileError(refusal, path: liveURL.path)
        }
        if let refusal = snapshotDestinationRefusal(liveURL: liveURL, backupURL: backupURL) {
            throw fileError(refusal, path: liveURL.path)
        }
        #if os(macOS)
            let cloneResult = clonefile(liveURL.path, backupURL.path, UInt32(CLONE_NOFOLLOW))
            if cloneResult != 0 {
                // Fall back to a full copy when APFS cloning is unavailable, and fail closed when
                // the fallback also fails so a live overwrite never proceeds without a rollback
                // copy.
                let copyFlags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_NOFOLLOW | COPYFILE_EXCL)
                let copyResult = copyfile(liveURL.path, backupURL.path, nil, copyFlags)
                if copyResult != 0 {
                    let backupErrno = errno
                    throw fileError(
                        "Could not back up \(liveURL.path) to \(backupURL.path): errno \(backupErrno)",
                        path: liveURL.path
                    )
                }
            }
        #else
            try FileManager.default.copyItem(at: liveURL, to: backupURL)
        #endif
    }

    /// Refusal sentence when a fresh snapshot would find `liveURL` is not a regular file, or nil
    /// when the source may be captured.
    public static func snapshotSourceRefusal(liveURL: URL, backupURL: URL) -> String? {
        guard !isRegularFileNoFollow(liveURL) else { return nil }
        return "Could not back up \(liveURL.path) to \(backupURL.path): the live path is not a regular file."
    }

    /// Refusal sentence when a fresh snapshot would find `backupURL` occupied, or nil when the
    /// destination is free.
    public static func snapshotDestinationRefusal(liveURL: URL, backupURL: URL) -> String? {
        guard entryExists(at: backupURL) else { return nil }
        guard isRegularFileNoFollow(backupURL) else {
            return "Could not back up \(liveURL.path) to \(backupURL.path): the backup path is not a regular file."
        }
        return "Could not back up \(liveURL.path) to \(backupURL.path): a rollback copy already exists and is never replaced."
    }

    /// Removes the rollback copy at `backupURL`, if one exists. Absence is a no-op so a replayed
    /// decision cannot fail on an already removed copy.
    public static func removeBackup(at backupURL: URL) throws {
        let fileManager = FileManager.default
        guard entryExists(at: backupURL) else { return }
        guard isRegularFileNoFollow(backupURL) else {
            throw fileError(
                "Could not remove backup at \(backupURL.path): the backup path is not a regular file.",
                path: backupURL.path
            )
        }
        try fileManager.removeItem(at: backupURL)
    }

    /// Restores `liveURL` from its rollback copy.
    public static func restore(liveURL: URL, backupURL: URL) throws {
        let fileManager = FileManager.default
        guard isRegularFileNoFollow(backupURL) else {
            throw fileError(
                "Could not restore \(liveURL.path) from \(backupURL.path): the backup is missing or not a regular file.",
                path: liveURL.path
            )
        }
        if fileManager.fileExists(atPath: liveURL.path) {
            guard isRegularFileNoFollow(liveURL) else {
                throw fileError(
                    "Could not restore \(liveURL.path): the live path is not a regular file.",
                    path: liveURL.path
                )
            }
            _ = try fileManager.replaceItemAt(liveURL, withItemAt: backupURL)
        } else {
            try fileManager.moveItem(at: backupURL, to: liveURL)
        }
    }

    /// True only for regular files after Foundation's usual resolution: a missing path, directory,
    /// or other node type fails the check so callers stay fail-closed.
    public static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }

    /// Reports whether any entry exists at `url` without following a final
    /// symlink. A dangling symlink is an entry too, so a caller can refuse to
    /// write through a link that `fileExists` would resolve to "missing".
    static func entryExists(at url: URL) -> Bool {
        entryKind(at: url) != .missing
    }

    /// True only for regular files inspected without following a final
    /// symlink: a symlink (dangling or not), directory, or missing path all
    /// fail so every rollback-copy probe stays fail-closed.
    static func isRegularFileNoFollow(_ url: URL) -> Bool {
        entryKind(at: url) == .regular
    }

    /// No-follow classification of the entry at a candidate path, the shared
    /// basis for every symlink-safe probe in this file.
    private enum EntryKind {
        case missing
        case regular
        case symlink
        case other
    }

    /// Classifies the entry at `url` via `lstat`, so a final symlink is
    /// reported as a symlink rather than followed to its target.
    private static func entryKind(at url: URL) -> EntryKind {
        #if canImport(Darwin) || canImport(Glibc)
            var statBuf = stat()
            let result = url.path.withCString { lstat($0, &statBuf) }
            guard result == 0 else { return .missing }
            let fileType = statBuf.st_mode & S_IFMT
            if fileType == S_IFREG {
                return .regular
            }
            if fileType == S_IFLNK {
                return .symlink
            }
            return .other
        #else
            // No POSIX lstat on this platform; Foundation's attribute probe is
            // the closest no-follow approximation available.
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard let values else { return .missing }
            if values.isSymbolicLink == true {
                return .symlink
            }
            if values.isRegularFile == true {
                return .regular
            }
            return .other
        #endif
    }

    /// Builds the shared Cocoa file-write error shape for a failed operation.
    private static func fileError(_ message: String, path: String) -> NSError {
        NSError(
            domain: NSCocoaErrorDomain,
            code: CocoaError.fileWriteUnknown.rawValue,
            userInfo: [
                NSFilePathErrorKey: path,
                NSLocalizedDescriptionKey: message
            ]
        )
    }
}

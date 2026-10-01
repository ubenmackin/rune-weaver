// Rune Weaver Tools — Rollback-copy primitives behind a live-write review.
//
// Purpose: the `snapshot`/`restore`/`removeBackup` mechanics for the single
// `.rune_backup_<name>` copy that backs one live review.
// Scope: filesystem operations plus regular-file validation; the review ledger
// decides when a copy may exist and callers order writes around it.
// Architectural role: shared by `files.write` and the live resolution routes so
// snapshot/restore/remove semantics cannot drift between the write path and the
// decision path. Every helper fails closed on regular-file violations, and
// every entry probe is taken without following a final symlink (`lstat`), so a
// link planted at a copy or live path is an existing non-regular entry: a
// snapshot never writes through it, a restore never consumes it, and a removal
// never follows it. The source and destination refusal predicates are shared
// with preview callers, so a described snapshot refuses exactly what the real
// one refuses.

import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Filesystem primitives for the single rollback copy behind a live review.
///
/// A live review owns at most one `.rune_backup_<name>` copy beside the live
/// file: it is snapshotted when the review starts and is never rewritten while
/// a decision is pending, so it always holds the pre-series bytes needed to
/// revert the whole series. The ledger is authoritative for whether a copy
/// should exist; these helpers only carry out the mechanics.
public enum LiveFileBackup: Sendable {
    /// Creates a fresh snapshot of `liveURL` at `backupURL`.
    ///
    /// The destination must be absent: any entry already at the backup path —
    /// regular file, directory, or symlink — fails the snapshot closed and is
    /// never removed. That exclusivity is what keeps a peer process's
    /// just-captured rollback copy safe, because a copy created after the
    /// caller's presence probe can never be deleted here; a caller that finds
    /// the destination occupied resolves the entry instead of clobbering
    /// whatever is there. The live source must be a regular file: cloning a
    /// directory would produce a rollback copy that can never restore a file.
    /// The destination is probed without following a final symlink, so a link
    /// at the backup path is an existing non-regular entry — never an absent
    /// path — and the clone/copy can neither follow it nor write through it.
    /// `clonefile` refuses an existing destination and the copy fallback keeps
    /// `COPYFILE_EXCL`, so an entry that lands between the probe and the write
    /// is refused rather than replaced.
    /// - Parameters:
    ///   - liveURL: The live file to snapshot.
    ///   - backupURL: Rollback-copy destination beside the live file.
    /// - Throws: A file-write error when the live source is missing or not a
    ///   regular file, when any entry already exists at the backup path, or
    ///   when the clone and its copy fallback both fail.
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
                // Fall back to a full copy when APFS cloning is unavailable, and
                // fail closed when the fallback also fails so a live overwrite
                // never proceeds without a rollback copy. The no-follow flags
                // keep the fallback from following a link planted at either end
                // after the probes above, and the exclusive flag keeps it from
                // replacing an entry a concurrent start created in that window
                // — exactly the copy that start's pending row would reference.
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

    /// Refusal sentence when a fresh snapshot would find `liveURL` is not a
    /// regular file, or nil when the source may be captured.
    ///
    /// `snapshot` clones only a regular file — cloning a directory would
    /// produce a rollback copy that can never restore one — and its source
    /// probe does not follow a final symlink, so a link planted at the live
    /// path is an existing non-regular entry too. Callers that only describe a
    /// planned snapshot (dry runs and approval previews) share this predicate
    /// so they refuse exactly what the clone refuses instead of promising a
    /// live write disk would reject.
    /// - Parameters:
    ///   - liveURL: Live file a snapshot would capture.
    ///   - backupURL: Rollback-copy destination beside the live file.
    /// - Returns: The caller-facing refusal sentence naming the live path, or
    ///   nil when the source is a regular file.
    public static func snapshotSourceRefusal(liveURL: URL, backupURL: URL) -> String? {
        guard !isRegularFileNoFollow(liveURL) else { return nil }
        return "Could not back up \(liveURL.path) to \(backupURL.path): the live path is not a regular file."
    }

    /// Refusal sentence when a fresh snapshot would find `backupURL`
    /// occupied, or nil when the destination is free.
    ///
    /// `snapshot` creates exclusively and never deletes, so every entry kind —
    /// regular file, directory, or symlink, dangling or not — refuses the
    /// snapshot: a regular copy may be a peer process's just-captured original
    /// whose review row has not reached the shared ledger yet, and no local
    /// probe can prove otherwise. Callers that only describe a planned
    /// snapshot (dry runs and approval previews) share this predicate so they
    /// refuse exactly what the exclusive create refuses instead of promising
    /// a write disk would reject.
    /// - Parameters:
    ///   - liveURL: Live file a snapshot would capture.
    ///   - backupURL: Rollback-copy destination beside the live file.
    /// - Returns: The caller-facing refusal sentence naming the occupying
    ///   entry, or nil when the destination is free.
    public static func snapshotDestinationRefusal(liveURL: URL, backupURL: URL) -> String? {
        guard entryExists(at: backupURL) else { return nil }
        guard isRegularFileNoFollow(backupURL) else {
            return "Could not back up \(liveURL.path) to \(backupURL.path): the backup path is not a regular file."
        }
        return "Could not back up \(liveURL.path) to \(backupURL.path): a rollback copy already exists and is never replaced."
    }

    /// Removes the rollback copy at `backupURL`, if one exists.
    ///
    /// Absence is a no-op so a replayed decision cannot fail on an already
    /// removed copy. Only a regular file is removed: a directory is refused
    /// rather than recursed into, and a symlink (dangling or not) is refused
    /// rather than followed, because removing through a backup name must never
    /// reach whatever else the path happens to name.
    /// - Parameter backupURL: Rollback-copy path beside the live file.
    /// - Throws: A file-write error when the backup path exists but is not a
    ///   regular file, or when the removal itself fails.
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
    ///
    /// The live file is replaced atomically when it still exists and moved into
    /// place when it does not, because a review can outlive an external
    /// deletion of the live file. A missing or non-regular backup is refused so
    /// a restore never invents an empty live file, and both sides are probed
    /// without following a final symlink so a restore can neither consume a
    /// planted link as the copy nor move one onto the live path.
    /// - Parameters:
    ///   - liveURL: Live file to restore.
    ///   - backupURL: Rollback copy to restore from.
    /// - Throws: A file-write error when the backup is missing or not a regular
    ///   file, when the live path exists but is not a regular file, or when the
    ///   replace/move fails.
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

    /// True only for regular files after Foundation's usual resolution: a
    /// missing path, directory, or other node type fails the check so callers
    /// stay fail-closed. A symlink resolves to its target, which is why the
    /// rollback-copy probes use the no-follow variants below instead. Shared
    /// with the `files.write` staging-sibling cleanup and the server's staged
    /// and live review routes so every review-artifact mutation uses the same
    /// predicate.
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

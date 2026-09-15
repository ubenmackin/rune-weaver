// Rune Weaver Core — Sandbox staging retention and reclamation.
//
// Owns the lifecycle of staged files under the sandbox staging area. Staged
// writes in `pending/`, `approved/`, and `attachments/` are bounded by a
// retention window plus a total size cap so approvals stay reachable for days
// without unbounded disk growth. Cleanup runs at service boot and on a
// periodic cadence; every pass records only aggregate counts to the local
// audit trail, never file contents.

import Dispatch
import Foundation

/// Aggregate outcome of one sandbox cleanup pass.
///
/// Counts only, so audit consumers can reason about reclamation pressure
/// without ever seeing staged file names or bytes.
public struct SandboxCleanupSummary: Sendable, Equatable, Codable {
    /// Number of staged files removed in this pass.
    public let filesRemoved: Int
    /// Total bytes reclaimed in this pass.
    public let bytesFreed: Int
    /// Non-fatal problems encountered (for example skipped symlinks or
    /// failed removals). Messages carry no file contents.
    public let errors: [String]

    /// Creates a cleanup summary.
    /// - Parameters:
    ///   - filesRemoved: Files removed.
    ///   - bytesFreed: Bytes reclaimed.
    ///   - errors: Non-fatal problems. Defaults to empty.
    public init(filesRemoved: Int, bytesFreed: Int, errors: [String] = []) {
        self.filesRemoved = filesRemoved
        self.bytesFreed = bytesFreed
        self.errors = errors
    }
}

/// Audit event recorded for every sandbox cleanup pass.
///
/// Local-only and aggregate-only: it carries the staging location plus the
/// summary counts so later review can reconstruct when reclamation ran and
/// how much it freed, without ever persisting staged paths or contents.
public struct SandboxCleanupAuditEvent: Sendable, Codable, Equatable {
    /// Staging directory the pass swept (as configured, unexpanded).
    public let stagingPath: String
    /// Files removed in this pass.
    public let filesRemoved: Int
    /// Bytes reclaimed in this pass.
    public let bytesFreed: Int
    /// Number of non-fatal problems encountered.
    public let errorCount: Int
    /// When the pass completed.
    public let timestamp: Date

    /// Creates an audit event from a summary.
    /// - Parameters:
    ///   - stagingPath: Configured staging path.
    ///   - summary: Outcome to record.
    ///   - timestamp: Record time. Defaults to now.
    public init(stagingPath: String, summary: SandboxCleanupSummary, timestamp: Date = Date()) {
        self.stagingPath = stagingPath
        self.filesRemoved = summary.filesRemoved
        self.bytesFreed = summary.bytesFreed
        self.errorCount = summary.errors.count
        self.timestamp = timestamp
    }
}

/// Local JSONL audit log for sandbox cleanup passes.
///
/// Appends one JSON object per pass to
/// `~/.runeweaver/logs/sandbox-audit.jsonl` (overridable per call).
/// Writes are best-effort and serialized on a private queue: failures are
/// swallowed so auditing never fails the cleanup itself, and only aggregate
/// counts are persisted so staged contents never reach the log.
public enum FileSandboxAuditLog {
    /// Serial queue ordering audit appends.
    private static let queue = DispatchQueue(label: "com.runeweaver.sandbox.audit", qos: .utility)

    /// Default audit file URL.
    /// - Returns: `~/.runeweaver/logs/sandbox-audit.jsonl` as a file URL.
    public static func defaultLogURL() -> URL {
        let expanded = ("~/.runeweaver/logs" as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).appendingPathComponent("sandbox-audit.jsonl")
    }

    /// Appends a cleanup outcome as one JSON line, best-effort.
    /// - Parameters:
    ///   - summary: Outcome to record (counts only, no file contents).
    ///   - stagingPath: Configured staging path for context.
    ///   - fileURL: Destination file. Defaults to `defaultLogURL()`.
    public static func append(
        _ summary: SandboxCleanupSummary,
        stagingPath: String,
        to fileURL: URL? = nil
    ) {
        let event = SandboxCleanupAuditEvent(stagingPath: stagingPath, summary: summary)
        guard let data = try? JSONEncoder().encode(event) else { return }
        var line = data
        line.append(0x0A)
        let url = fileURL ?? defaultLogURL()
        let payload = line
        queue.async {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: url.path) {
                    let handle = try FileHandle(forWritingTo: url)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: payload)
                } else {
                    try payload.write(to: url, options: .atomic)
                }
            } catch {
                fputs("[WARN] FileSandboxAuditLog: Failed to append audit record to \(url.path): \(error)\n", stderr)
                // Best-effort: audit failures never fail the cleanup.
            }
        }
    }
}

/// Reclaims staged files under the sandbox staging area.
///
/// Pure filesystem sweep with no side effects beyond deletions and the
/// returned summary. Callers own audit logging (via `FileSandboxAuditLog`)
/// and scheduling (via `SandboxCleanupScheduler`) so tests can invoke the
/// sweep deterministically without timers or log files.
public enum SandboxCleaner {
    /// Managed subdirectories swept on every pass.
    ///
    /// Kept in one place so the sweeper, config docs, and tests cannot drift
    /// on which staging areas are bounded.
    public static let managedSubdirectories = ["pending", "approved", "attachments"]

    /// Sweeps staged files, enforcing retention then the total size cap.
    ///
    /// Retention runs first so clearly expired files never consume cap budget
    /// that should protect fresh approvals; the cap then evicts oldest-first
    /// so recent work survives pressure. Symlinks are never followed or
    /// deleted: any entry whose symlink-resolved location escapes the staging
    /// prefix is skipped and reported instead of removed.
    /// - Parameters:
    ///   - config: Sandbox retention and cap configuration.
    ///   - now: Reference date for age checks. Defaults to now so tests can pin time.
    /// - Returns: Aggregate counts plus non-fatal problems (no file contents).
    public static func cleanup(config: SandboxConfig, now: Date = Date()) -> SandboxCleanupSummary {
        var filesRemoved = 0
        var bytesFreed = 0
        var errors: [String] = []

        let trimmed = config.stagingPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return SandboxCleanupSummary(filesRemoved: 0, bytesFreed: 0, errors: ["Invalid sandbox staging path"])
        }
        let expanded = (trimmed as NSString).expandingTildeInPath
        // Resolve both sides before comparing so a symlinked staging root or
        // `..` segments cannot bypass the prefix check below.
        let stagingURL = URL(fileURLWithPath: expanded, isDirectory: true).standardized
        let resolvedStaging = stagingURL.resolvingSymlinksInPath().standardized
        let stagingPrefix = resolvedStaging.path.hasSuffix("/") ? resolvedStaging.path : resolvedStaging.path + "/"

        var isStagingDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: stagingURL.path, isDirectory: &isStagingDir) else {
            // Missing staging is a clean no-op, not an error: fresh installs
            // have nothing to reclaim yet.
            return SandboxCleanupSummary(filesRemoved: 0, bytesFreed: 0, errors: [])
        }

        var candidates: [StagedEntry] = []
        for subdir in managedSubdirectories {
            let subURL = stagingURL.appendingPathComponent(subdir, isDirectory: true)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: subURL.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            // A symlinked subdirectory pointing outside must not be descended
            // into; verify containment before enumerating.
            let resolvedSub = subURL.resolvingSymlinksInPath().standardized
            guard resolvedSub.path == resolvedStaging.path || resolvedSub.path.hasPrefix(stagingPrefix) else {
                errors.append("Skipped \(subdir): escapes the staging area")
                continue
            }
            collectFiles(under: subURL, stagingPrefix: stagingPrefix, candidates: &candidates, errors: &errors)
        }

        // Expiry first: stale files leave before cap pressure is measured so
        // the cap protects live approvals rather than expired debris.
        var remaining: [StagedEntry] = []
        remaining.reserveCapacity(candidates.count)
        let retentionInterval = Double(max(0, config.retentionDays)) * 86400
        let expiryEnabled = config.retentionDays > 0
        for entry in candidates {
            guard expiryEnabled, let modified = entry.modified else {
                remaining.append(entry)
                continue
            }
            guard now.timeIntervalSince(modified) > retentionInterval else {
                remaining.append(entry)
                continue
            }
            // Re-verify containment immediately before removal so a symlink
            // swapped between enumeration and deletion cannot redirect the unlink.
            let resolved = entry.url.resolvingSymlinksInPath().standardized
            guard resolved.path.hasPrefix(stagingPrefix) else {
                errors.append("Skipped expired file escaping the staging area")
                remaining.append(entry)
                continue
            }
            do {
                try FileManager.default.removeItem(at: entry.url)
                filesRemoved += 1
                bytesFreed += entry.size
            } catch {
                errors.append("Could not remove expired file: \(error.localizedDescription)")
                remaining.append(entry)
            }
        }

        // Size cap second, oldest-first: evicting the stalest approvals first
        // keeps the most recently staged work available the longest.
        if config.maxTotalBytes > 0 {
            var total = remaining.reduce(0) { $0 + $1.size }
            if total > config.maxTotalBytes {
                // Deterministic oldest-first order with a path tie-break so
                // repeated passes under the same clock evict identically.
                let ordered = remaining.sorted {
                    let left = $0.modified ?? Date.distantPast
                    let right = $1.modified ?? Date.distantPast
                    if left != right {
                        return left < right
                    }
                    return $0.url.path < $1.url.path
                }
                var survivors: [StagedEntry] = []
                survivors.reserveCapacity(ordered.count)
                for entry in ordered {
                    if total <= config.maxTotalBytes {
                        survivors.append(entry)
                        continue
                    }
                    let resolved = entry.url.resolvingSymlinksInPath().standardized
                    guard resolved.path.hasPrefix(stagingPrefix) else {
                        errors.append("Skipped oversized file escaping the staging area")
                        survivors.append(entry)
                        continue
                    }
                    do {
                        try FileManager.default.removeItem(at: entry.url)
                        filesRemoved += 1
                        bytesFreed += entry.size
                        total -= entry.size
                    } catch {
                        errors.append("Could not remove oversized file: \(error.localizedDescription)")
                        survivors.append(entry)
                    }
                }
                remaining = survivors
            }
        }

        return SandboxCleanupSummary(filesRemoved: filesRemoved, bytesFreed: bytesFreed, errors: errors)
    }

    /// One enumerated regular file with its reclamation metadata.
    private struct StagedEntry {
        /// Location to unlink when selected for reclamation.
        let url: URL
        /// Byte size at enumeration time.
        let size: Int
        /// Last modification, when readable; nil keeps the file out of expiry
        /// but sorts oldest-first under cap pressure so unknown ages evict first.
        let modified: Date?
    }

    /// Collects regular files under one managed subdirectory without following symlinks.
    ///
    /// Symlinked files and directories are never descended into or deleted;
    /// outside-pointing links are reported so operators notice staging that
    /// tries to reach beyond its prefix. Directories themselves are never
    /// reclaimed, only the files they contain.
    private static func collectFiles(
        under root: URL,
        stagingPrefix: String,
        candidates: inout [StagedEntry],
        errors: inout [String]
    ) {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .contentModificationDateKey, .fileSizeKey],
            options: []
        ) else {
            errors.append("Could not enumerate staging subdirectory")
            return
        }
        for case let fileURL as URL in enumerator {
            let flags = try? fileURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
            let isSymlink = flags?.isSymbolicLink == true
            let isDirectory = flags?.isDirectory == true
            if isSymlink {
                // Never follow or unlink links: an outside target would escape
                // the prefix, and descending into a linked directory could walk
                // the rest of the filesystem. Report only outside escapes so
                // inside links stay silent housekeeping.
                let resolved = fileURL.resolvingSymlinksInPath().standardized
                let inside = resolved.path == String(stagingPrefix.dropLast()) || resolved.path.hasPrefix(stagingPrefix)
                if !inside {
                    errors.append("Skipped symlink escaping the staging area")
                }
                if isDirectory {
                    enumerator.skipDescendants()
                }
                continue
            }
            if isDirectory {
                continue
            }
            guard flags?.isRegularFile == true else { continue }
            let resolved = fileURL.resolvingSymlinksInPath().standardized
            guard resolved.path.hasPrefix(stagingPrefix) else {
                errors.append("Skipped file escaping the staging area")
                continue
            }
            let detail = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            var size = detail?.fileSize ?? 0
            var modified = detail?.contentModificationDate
            if size == 0 || modified == nil {
                // Resource values can be absent on some filesystems; fall back
                // to attributes so size accounting and age checks stay accurate.
                if let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path) {
                    if size == 0, let number = attributes[.size] as? NSNumber {
                        size = number.intValue
                    }
                    if modified == nil, let date = attributes[.modificationDate] as? Date {
                        modified = date
                    }
                }
            }
            candidates.append(StagedEntry(url: fileURL, size: size, modified: modified))
        }
    }
}

/// Periodic scheduler running sandbox reclamation on a cadence.
///
/// Mirrors the trust-reaper pattern: the scheduler owns a single sleep loop
/// task cancelled only via `stop()`, since actor-isolated state cannot be
/// touched from `deinit`. Callers pair every `start` with `stop` on shutdown
/// so the sleep task never outlives its owner.
public actor SandboxCleanupScheduler {
    /// In-flight sleep loop, if started.
    private var task: Task<Void, Never>?
    /// Whether the loop is running.
    private var isStarted = false

    /// Creates an idle scheduler.
    public init() {}

    /// Starts the periodic cleanup loop.
    ///
    /// Safe to call repeatedly; the second call is a no-op. The interval comes
    /// from the config snapshot so later config edits take effect on the next
    /// `start` after a `stop`, keeping one source for the cadence.
    /// - Parameter config: Sandbox config supplying `cleanupIntervalSeconds`.
    public func start(config: SandboxConfig) {
        guard !isStarted else { return }
        isStarted = true
        let interval = max(1.0, Double(config.cleanupIntervalSeconds))
        let snapshot = config
        task = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                await self?.runOnce(config: snapshot)
            }
        }
    }

    /// Stops the periodic cleanup loop.
    ///
    /// Safe to call when not running; pair every `start` with this on shutdown.
    public func stop() {
        task?.cancel()
        task = nil
        isStarted = false
    }

    /// Whether the loop is running.
    public var running: Bool {
        isStarted
    }

    /// Runs one cleanup pass and records it to the audit trail.
    ///
    /// Only aggregate counts reach the audit log; staged file names and bytes
    /// never leave the filesystem. Audit writes are best-effort so a log
    /// failure never fails the sweep.
    /// - Parameters:
    ///   - config: Sandbox config to sweep.
    ///   - now: Reference date for age checks. Defaults to now.
    /// - Returns: Aggregate outcome of the pass.
    @discardableResult
    public func runOnce(config: SandboxConfig, now: Date = Date()) async -> SandboxCleanupSummary {
        let summary = SandboxCleaner.cleanup(config: config, now: now)
        FileSandboxAuditLog.append(summary, stagingPath: config.stagingPath)
        return summary
    }
}

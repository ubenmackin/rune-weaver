// Rune Weaver Core — Tier-3 crash-orphan reclamation.
//
// Confinement is Tier-1/Tier-2 Seatbelt plus Tier-3 microVM only; there is no
// host sandbox folder. Document writes stage in a Seatbelt-confined temp dir
// with an atomic move into the workspace on approval (never executed from
// temp, temp removed on deny or failure), and archives detonate in ephemeral
// microVMs with manifest-only returns. This sweeper therefore reclaims only
// Tier-3 crash-orphaned detonation machines left behind when a detonation
// host crashes before its immediate reap; it never sweeps staged files and
// performs no migration for old staging directories. Cleanup runs at service
// boot and on a periodic cadence; every pass records only aggregate counts
// to the local audit trail, never file contents.

import Dispatch
import Foundation

/// Aggregate outcome of one sandbox cleanup pass.
///
/// Counts only, so audit consumers can reason about reclamation pressure
/// without ever seeing file names or bytes. There is no host staging to
/// reclaim: document writes live in Seatbelt-confined temp until an atomic
/// move on approval, so file counts stay zero and only Tier-3 detonation
/// reclamation contributes.
public struct SandboxCleanupSummary: Sendable, Equatable, Codable {
    /// Legacy file count, always zero now that no host staging is swept.
    ///
    /// Retained so existing audit decoders and callers keep compiling while
    /// the sweeper covers only Tier-3 crash orphans.
    public let filesRemoved: Int
    /// Legacy byte count, always zero now that no host staging is swept.
    public let bytesFreed: Int
    /// Number of ephemeral or stale container machines destroyed.
    public let containersDestroyed: Int
    /// Number of stale running container machines stopped.
    public let staleMachinesStopped: Int
    /// Non-fatal problems encountered (for example listing failures).
    /// Messages carry no file contents.
    public let errors: [String]

    /// Creates a cleanup summary.
    /// - Parameters:
    ///   - filesRemoved: Legacy file count. Always zero; kept for compatibility.
    ///   - bytesFreed: Legacy byte count. Always zero; kept for compatibility.
    ///   - containersDestroyed: Container machines destroyed.
    ///   - staleMachinesStopped: Running container machines stopped.
    ///   - errors: Non-fatal problems. Defaults to empty.
    public init(
        filesRemoved: Int = 0,
        bytesFreed: Int = 0,
        containersDestroyed: Int = 0,
        staleMachinesStopped: Int = 0,
        errors: [String] = []
    ) {
        self.filesRemoved = filesRemoved
        self.bytesFreed = bytesFreed
        self.containersDestroyed = containersDestroyed
        self.staleMachinesStopped = staleMachinesStopped
        self.errors = errors
    }
}

/// Audit event recorded for every sandbox cleanup pass.
///
/// Local-only and aggregate-only: it carries a scope label plus the summary
/// counts so later review can reconstruct when Tier-3 reclamation ran and
/// how much it freed, without ever persisting file paths or contents.
public struct SandboxCleanupAuditEvent: Sendable, Codable, Equatable {
    /// Scope label for the pass, retained under the historic key for log continuity.
    ///
    /// New passes record the Tier-3 scope; older lines may carry a historic
    /// staging path that is no longer swept and must not be treated as live.
    public let stagingPath: String
    /// Legacy file count, always zero.
    public let filesRemoved: Int
    /// Legacy byte count, always zero.
    public let bytesFreed: Int
    /// Container machines destroyed in this pass.
    public let containersDestroyed: Int
    /// Stale machines stopped in this pass.
    public let staleMachinesStopped: Int
    /// Number of non-fatal problems encountered.
    public let errorCount: Int
    /// When the pass completed.
    public let timestamp: Date

    /// Scope recorded by current passes covering only Tier-3 orphans.
    public static let tier3Scope = "tier3-crash-orphans"

    /// Creates an audit event from a summary.
    /// - Parameters:
    ///   - stagingPath: Scope label to record. Defaults to the Tier-3 scope.
    ///   - summary: Outcome to record.
    ///   - timestamp: Record time. Defaults to now.
    public init(stagingPath: String = tier3Scope, summary: SandboxCleanupSummary, timestamp: Date = Date()) {
        self.stagingPath = stagingPath
        self.filesRemoved = summary.filesRemoved
        self.bytesFreed = summary.bytesFreed
        self.containersDestroyed = summary.containersDestroyed
        self.staleMachinesStopped = summary.staleMachinesStopped
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
/// counts are persisted so file contents never reach the log. Current passes
/// cover only Tier-3 crash-orphan reclamation under the Tier-3 scope.
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
    ///
    /// The Tier-3 scope is recorded instead of any host path because no host
    /// staging exists to sweep; the historic overload below remains only so
    /// older callers keep compiling.
    /// - Parameters:
    ///   - summary: Outcome to record (counts only, no file contents).
    ///   - fileURL: Destination file. Defaults to `defaultLogURL()`.
    public static func append(
        _ summary: SandboxCleanupSummary,
        to fileURL: URL? = nil
    ) {
        let event = SandboxCleanupAuditEvent(summary: summary)
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
                RuneWeaverLog.sandbox.warning("FileSandboxAuditLog: Failed to append audit record to \(url.path): \(error)")
                // Best-effort: audit failures never fail the cleanup.
            }
        }
    }

    /// Legacy append retaining the historic staging-path parameter.
    ///
    /// Kept only so callers predating the Tier-3-only model keep compiling;
    /// the supplied path is ignored and the Tier-3 scope is recorded instead
    /// because no host staging is swept.
    /// - Parameters:
    ///   - summary: Outcome to record (counts only, no file contents).
    ///   - stagingPath: Ignored historic label.
    ///   - fileURL: Destination file. Defaults to `defaultLogURL()`.
    @available(*, deprecated, message: "No host staging is swept; use append(_:to:) which records the Tier-3 scope.")
    public static func append(
        _ summary: SandboxCleanupSummary,
        stagingPath _: String,
        to fileURL: URL? = nil
    ) {
        append(summary, to: fileURL)
    }
}

/// Reclaims Tier-3 crash-orphaned detonation machines.
///
/// Pure prune with no side effects beyond stopping and deleting stale
/// `runeweaver-` container machines plus the returned summary. There is no
/// host staging to sweep: Seatbelt temp is removed by its writer on deny or
/// failure, and approved writes reach the workspace via one atomic move, so
/// old staging directories are left untouched with no migration. Callers own
/// audit logging (via `FileSandboxAuditLog`) and scheduling (via
/// `SandboxCleanupScheduler`) so tests can invoke the prune deterministically
/// without timers or log files.
public enum SandboxCleaner {
    /// Prunes Tier-3 crash orphans, ignoring any historic staging fields.
    ///
    /// Only `containerRuntime` and `archiveSessionTTLMinutes` are read; any
    /// retained staging or retention values on the config are ignored because
    /// no host folder exists to bound. File counts in the summary stay zero.
    /// - Parameters:
    ///   - config: Sandbox detonation configuration.
    ///   - now: Reference date for age checks. Defaults to now so tests can pin time.
    /// - Returns: Aggregate counts plus non-fatal problems (no file contents).
    public static func cleanup(config: SandboxConfig, now: Date = Date()) -> SandboxCleanupSummary {
        let containerResult = sweepContainers(config: config, now: now)

        return SandboxCleanupSummary(
            filesRemoved: 0,
            bytesFreed: 0,
            containersDestroyed: containerResult.destroyed,
            staleMachinesStopped: containerResult.stopped,
            errors: containerResult.errors
        )
    }

    private static func sweepContainers(config: SandboxConfig, now: Date) -> ContainerPruneResult {
        guard ContainerMachineManager.isRuntimeAvailable(runtime: config.containerRuntime) else {
            return ContainerPruneResult()
        }
        return ContainerMachineManager.pruneStaleMachinesSync(
            prefix: ContainerMachineManager.machinePrefix,
            maxAgeSeconds: TimeInterval(config.archiveSessionTTLMinutes * 60),
            now: now,
            runtime: config.containerRuntime
        )
    }
}

/// Periodic scheduler running sandbox reclamation on a cadence.
///
/// Mirrors the trust-reaper pattern: the scheduler owns a single sleep loop
/// task cancelled only via `stop()`, since actor-isolated state cannot be
/// touched from `deinit`. Callers pair every `start` with `stop` on shutdown
/// so the sleep task never outlives its owner.
public actor SandboxCleanupScheduler {
    /// Fixed cadence between Tier-3 reclamation passes.
    ///
    /// The cadence stays fixed rather than config-driven so crash-orphan
    /// pressure is bounded without another tuning knob; the config snapshot
    /// still supplies the detonation TTL evaluated on every pass.
    public static let defaultIntervalSeconds: TimeInterval = 3600
    /// In-flight sleep loop, if started.
    private var task: Task<Void, Never>?
    /// Whether the loop is running.
    private var isStarted = false

    /// Creates an idle scheduler.
    public init() {}

    /// Starts the periodic cleanup loop.
    ///
    /// Safe to call repeatedly; the second call is a no-op. Each pass reuses
    /// the config snapshot so later config edits take effect on the next
    /// `start` after a `stop`.
    /// - Parameter config: Sandbox config supplying the detonation TTL.
    public func start(config: SandboxConfig) {
        guard !isStarted else { return }
        isStarted = true
        let interval = Self.defaultIntervalSeconds
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

    /// Runs one Tier-3 prune pass and records it to the audit trail.
    ///
    /// Only aggregate counts reach the audit log; file names and bytes never
    /// leave the filesystem. Audit writes are best-effort so a log failure
    /// never fails the prune.
    /// - Parameters:
    ///   - config: Sandbox config supplying the detonation TTL.
    ///   - now: Reference date for age checks. Defaults to now.
    /// - Returns: Aggregate outcome of the pass.
    @discardableResult
    public func runOnce(config: SandboxConfig, now: Date = Date()) async -> SandboxCleanupSummary {
        let summary = SandboxCleaner.cleanup(config: config, now: now)
        FileSandboxAuditLog.append(summary)
        return summary
    }
}

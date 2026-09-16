// Rune Weaver Core — Tier-3 crash-orphan reclamation.

import Dispatch
import Foundation

/// Aggregate outcome of one sandbox cleanup pass.
public struct SandboxCleanupSummary: Sendable, Equatable, Codable {
    /// Number of ephemeral or stale container machines destroyed.
    public let containersDestroyed: Int
    /// Number of stale running container machines stopped.
    public let staleMachinesStopped: Int
    /// Non-fatal problems encountered (for example listing failures).
    public let errors: [String]

    /// Creates a cleanup summary.
    public init(
        containersDestroyed: Int = 0,
        staleMachinesStopped: Int = 0,
        errors: [String] = []
    ) {
        self.containersDestroyed = containersDestroyed
        self.staleMachinesStopped = staleMachinesStopped
        self.errors = errors
    }
}

/// Audit event recorded for every sandbox cleanup pass.
public struct SandboxCleanupAuditEvent: Sendable, Codable, Equatable {
    /// Scope label for the cleanup pass.
    public let scope: String
    /// Container machines destroyed in this pass.
    public let containersDestroyed: Int
    /// Stale machines stopped in this pass.
    public let staleMachinesStopped: Int
    /// Number of non-fatal problems encountered.
    public let errorCount: Int
    /// When the pass completed.
    public let timestamp: Date

    /// Scope recorded by passes covering Tier-3 crash orphans.
    public static let tier3Scope = "tier3-crash-orphans"

    /// Creates an audit event from a summary.
    public init(scope: String = tier3Scope, summary: SandboxCleanupSummary, timestamp: Date = Date()) {
        self.scope = scope
        self.containersDestroyed = summary.containersDestroyed
        self.staleMachinesStopped = summary.staleMachinesStopped
        self.errorCount = summary.errors.count
        self.timestamp = timestamp
    }
}

/// Local JSONL audit log for sandbox cleanup passes.
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
}

/// Reclaims Tier-3 crash-orphaned detonation machines.
public enum SandboxCleaner {
    /// Prunes Tier-3 crash orphans.
    public static func cleanup(config: SandboxConfig, now: Date = Date()) -> SandboxCleanupSummary {
        let containerResult = sweepContainers(config: config, now: now)

        return SandboxCleanupSummary(
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
public actor SandboxCleanupScheduler {
    /// Fixed cadence between Tier-3 reclamation passes.
    public static let defaultIntervalSeconds: TimeInterval = 3600
    /// In-flight sleep loop, if started.
    private var task: Task<Void, Never>?
    /// Whether the loop is running.
    private var isStarted = false

    /// Creates an idle scheduler.
    public init() {}

    /// Starts the periodic cleanup loop.
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
    @discardableResult
    public func runOnce(config: SandboxConfig, now: Date = Date()) async -> SandboxCleanupSummary {
        let summary = SandboxCleaner.cleanup(config: config, now: now)
        FileSandboxAuditLog.append(summary)
        return summary
    }
}

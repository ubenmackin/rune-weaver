// Rune Weaver Core — Sandbox container reclamation.
//
// Purpose: reclaim stopped plus orphaned ephemeral containers the immediate
// teardown missed, so crashed turns never leak containers or scratch.
// Scope: the hourly pass over the strict name prefix plus the detonation
// names (the machine singleton workspace container excluded), parked-session
// exemption, scratch following its owner, and the JSONL audit trail.
// Architectural role: single owner for sandbox reclamation; the sweep engine
// lives on the strict turn registry and this pass drives it on a cadence.

import Dispatch
import Foundation

/// Aggregate outcome of one sandbox cleanup pass.
public struct SandboxCleanupSummary: Sendable, Equatable, Codable {
    /// Number of stopped plus orphaned containers reclaimed.
    public let containersDestroyed: Int
    /// Number of scratch leaves deleted with their owners.
    public let scratchRemoved: Int
    /// Non-fatal problems encountered (for example listing failures).
    public let errors: [String]

    /// Creates a cleanup summary.
    public init(
        containersDestroyed: Int = 0,
        scratchRemoved: Int = 0,
        errors: [String] = []
    ) {
        self.containersDestroyed = containersDestroyed
        self.scratchRemoved = scratchRemoved
        self.errors = errors
    }
}

/// Audit event recorded for every sandbox cleanup pass.
public struct SandboxCleanupAuditEvent: Sendable, Codable, Equatable {
    /// Scope label for the cleanup pass.
    public let scope: String
    /// Containers reclaimed in this pass.
    public let containersDestroyed: Int
    /// Scratch leaves deleted in this pass.
    public let scratchRemoved: Int
    /// Number of non-fatal problems encountered.
    public let errorCount: Int
    /// When the pass completed.
    public let timestamp: Date

    /// Scope recorded by passes reclaiming crash orphans.
    public static let tier3Scope = "tier3-crash-orphans"

    /// Creates an audit event from a summary.
    public init(scope: String = tier3Scope, summary: SandboxCleanupSummary, timestamp: Date = Date()) {
        self.scope = scope
        self.containersDestroyed = summary.containersDestroyed
        self.scratchRemoved = summary.scratchRemoved
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
        let data: Data
        do {
            data = try JSONEncoder().encode(event)
        } catch {
            RuneWeaverLog.sandbox.error("SandboxCleanupAuditLog: failed to encode audit event: \(error.localizedDescription)")
            return
        }
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

/// Reclaims stopped plus orphaned ephemeral containers.
public enum SandboxCleaner {
    /// Sweeps stopped plus orphaned strict and detonation containers.
    ///
    /// The strict turn registry owns the sweep engine; this pass drives it
    /// with the `[containers]` idle TTL so the operator-configured window
    /// governs reclamation. Parked sessions keep their containers at any
    /// age, the machine singleton workspace container is never matched, and
    /// every swept container's scratch follows it.
    /// - Parameters:
    ///   - config: Live containers policy supplying the reclamation TTL.
    ///   - approvals: Approval queue deriving parked-session exemptions.
    ///   - registry: Turn registry to sweep; nil sweeps the shared live one.
    ///   - workspaceTmp: Scratch root for orphan aging; nil resolves the
    ///     default workspace `tmp/`.
    ///   - now: Current instant for aging.
    /// - Returns: Aggregate outcome of the pass.
    public static func cleanup(
        config: ContainersConfig,
        approvals: ApprovalQueue,
        registry: StrictTurnRegistry? = nil,
        workspaceTmp: URL? = nil,
        now: Date = Date()
    ) async -> SandboxCleanupSummary {
        let sweepRegistry = registry ?? StrictTurnRegistry.shared
        let scratchRoot = workspaceTmp ?? BashSandboxRouter.workspaceTmpURL(for: WorkspaceStore.resolveRoot())
        let result = await sweepRegistry.sweep(
            workspaceTmp: scratchRoot,
            approvals: approvals,
            now: now,
            ttlSeconds: TimeInterval(config.ttlMinutes * 60)
        )
        return SandboxCleanupSummary(
            containersDestroyed: result.containersRemoved,
            scratchRemoved: result.scratchRemoved
        )
    }
}

/// Periodic scheduler running sandbox reclamation on a cadence.
public actor SandboxCleanupScheduler {
    /// Fixed cadence between reclamation passes.
    public static let defaultIntervalSeconds: TimeInterval = 3600
    /// In-flight sleep loop, if started.
    private var task: Task<Void, Never>?
    /// Whether the loop is running.
    private var isStarted = false
    /// Latest containers policy governing reclamation TTL.
    private var liveConfig: ContainersConfig?

    /// Creates an idle scheduler.
    public init() {}

    /// Starts the periodic cleanup loop.
    public func start(config: ContainersConfig, approvals: ApprovalQueue) {
        guard !isStarted else { return }
        isStarted = true
        liveConfig = config
        let interval = Self.defaultIntervalSeconds
        task = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                await self?.runLiveOnce(approvals: approvals)
            }
        }
    }

    /// Pushes a freshly persisted `[containers]` policy into the live loop so a
    /// settings save takes effect without a restart.
    /// - Parameter newConfig: Persisted containers policy from the settings save.
    public func updateConfig(_ newConfig: ContainersConfig) {
        liveConfig = newConfig
    }

    /// Runs one pass against the latest pushed policy.
    private func runLiveOnce(approvals: ApprovalQueue) async {
        guard let effective = liveConfig else { return }
        await runOnce(config: effective, approvals: approvals)
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

    /// Runs one reclamation pass and records it to the audit trail.
    @discardableResult
    public func runOnce(config: ContainersConfig, approvals: ApprovalQueue, now: Date = Date()) async -> SandboxCleanupSummary {
        let summary = await SandboxCleaner.cleanup(config: config, approvals: approvals, now: now)
        FileSandboxAuditLog.append(summary)
        return summary
    }
}

// Rune Weaver Server — Single-flight lock for scheduler job execution.
//
// Guards concurrent job executions (`POST /scheduler/jobs/:id/run` plus the
// in-process auto-fire worker) within the API service. Prevents duplicate
// concurrent executions of the same job by UUID or normalized name, so a
// manual run never overlaps an auto-fire tick for the same job in this
// process.
//
// Service notifications travel exclusively through the WebSocket event hub
// plus Web Notifications; the service never shells to `osascript`. Local
// popups for terminal-driven runs stay with the CLI foreground loop via the
// core notifier.

import Foundation
import RuneWeaverCore

/// Single-flight lock for scheduler job runs inside the service process.
///
/// Guards concurrent `POST /scheduler/jobs/:id/run` calls plus in-process
/// auto-fire ticks (`ServerSchedulerWorker`) sharing one lock: the UUID and
/// name slots block overlapping runs for the same job regardless of which
/// identity the caller holds. This lock does NOT coordinate with the CLI
/// foreground runner (`SchedulerEngine.running` in `scheduler run`); the two
/// live in separate processes with no shared state, so the same job name can
/// still double-fire via service auto-fire plus CLI. Run one auto-fire runner
/// at a time. Prefer the `id:name:` overloads when
/// both are known so either key blocks the other within the service.
public actor SchedulerRunLock {
    /// Job identifiers with an in-flight run.
    private var runningIDs: Set<UUID> = []
    /// Job names with an in-flight run, mirroring `SchedulerEngine.running`.
    private var runningNames: Set<String> = []

    /// Creates an empty run lock.
    public init() {}

    /// Acquires the slot for a job.
    /// - Parameter id: Job identifier.
    /// - Returns: True when the slot was acquired.
    @discardableResult
    public func tryAcquire(id: UUID) -> Bool {
        if runningIDs.contains(id) {
            return false
        }
        runningIDs.insert(id)
        return true
    }

    /// Releases the slot for a job. Unknown identifiers are a no-op.
    /// - Parameter id: Job identifier.
    public func release(id: UUID) {
        runningIDs.remove(id)
    }

    /// Whether a job has an in-flight run.
    /// - Parameter id: Job identifier.
    /// - Returns: True while the job is running.
    public func isRunning(id: UUID) -> Bool {
        runningIDs.contains(id)
    }

    /// Acquires the slot for a job by name.
    /// - Parameter name: Job name.
    /// - Returns: True when the slot was acquired.
    @discardableResult
    public func tryAcquire(name: String) -> Bool {
        let key = normalizedSchedulerJobName(name)
        if runningNames.contains(key) {
            return false
        }
        runningNames.insert(key)
        return true
    }

    /// Releases the name slot for a job. Unknown names are a no-op.
    /// - Parameter name: Job name.
    public func release(name: String) {
        runningNames.remove(normalizedSchedulerJobName(name))
    }

    /// Whether a job name has an in-flight run.
    /// - Parameter name: Job name.
    /// - Returns: True while the job is running.
    public func isRunning(name: String) -> Bool {
        runningNames.contains(normalizedSchedulerJobName(name))
    }

    /// Acquires both the UUID and name slots atomically.
    ///
    /// Either key blocks the other within this service process so
    /// concurrent REST runs and in-process auto-fire ticks for the same job
    /// never overlap regardless of which identity the caller holds. Does not
    /// block CLI `scheduler run` fires for the same name (separate process,
    /// separate lock), so service auto-fire plus CLI can still double-fire —
    /// run one auto-fire runner at a time.
    /// - Parameters:
    ///   - id: Job identifier.
    ///   - name: Job name.
    /// - Returns: True when both slots were acquired.
    @discardableResult
    public func tryAcquire(id: UUID, name: String) -> Bool {
        let key = normalizedSchedulerJobName(name)
        if runningIDs.contains(id) || runningNames.contains(key) {
            return false
        }
        runningIDs.insert(id)
        runningNames.insert(key)
        return true
    }

    /// Releases both the UUID and name slots. Unknown keys are a no-op.
    /// - Parameters:
    ///   - id: Job identifier.
    ///   - name: Job name.
    public func release(id: UUID, name: String) {
        runningIDs.remove(id)
        runningNames.remove(normalizedSchedulerJobName(name))
    }
}

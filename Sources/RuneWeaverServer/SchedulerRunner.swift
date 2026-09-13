// Rune Weaver Server — Single-flight lock for manual job execution.
//
// Guards concurrent manual job execution requests (`POST /scheduler/jobs/:id/run`)
// within the API service. Prevents duplicate concurrent executions of the same
// job by UUID or normalized name while keeping API execution distinct from the
// standalone CLI scheduler foreground loop.
//
// Service notifications travel exclusively through the WebSocket event hub
// plus Web Notifications; the service never shells to `osascript`. Local
// popups for terminal-driven runs stay with the CLI foreground loop via the
// core notifier.

import Foundation
import RuneWeaverCore

/// Single-flight lock for engine API manual job runs.
///
/// REST-only guard for concurrent `POST /scheduler/jobs/:id/run` calls
/// inside this service process: the UUID and name slots block overlapping
/// manual runs for the same job regardless of which identity the caller
/// holds. This lock does NOT coordinate with the CLI foreground runner
/// (`SchedulerEngine.running` in `scheduler run`); the two live in
/// separate processes with no shared state, so the same job name can still
/// run concurrently via API plus CLI. The service is CRUD plus manual-run
/// only — cron and poll triggers never auto-fire here; the CLI foreground
/// loop is the sole auto-fire runner. Prefer the `id:name:` overloads when
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
    /// concurrent manual REST runs for the same job never overlap
    /// regardless of which identity the caller holds. Does not block CLI
    /// `scheduler run` fires for the same name (separate process, separate
    /// lock).
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

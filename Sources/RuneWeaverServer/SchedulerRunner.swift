// Rune Weaver Server — Single-flight lock for scheduler job execution.

import Foundation
import RuneWeaverCore

/// Single-flight lock for scheduler job runs inside the service process.
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
    public func release(id: UUID, name: String) {
        runningIDs.remove(id)
        runningNames.remove(normalizedSchedulerJobName(name))
    }
}

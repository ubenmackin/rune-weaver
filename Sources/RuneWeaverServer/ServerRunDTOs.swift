// Rune Weaver Server — Run history and fan-out cancellation DTOs.

import Foundation
import Vapor

/// Run log list response for `GET /runs`.
public struct RunLogsResponse: Content, Equatable {
    /// Entries, newest first.
    public let runs: [RunLogEntry]
    /// Number of entries in `runs`.
    public let count: Int

    /// Creates a run logs response.
    /// - Parameter runs: Stored entries.
    public init(runs: [RunLogEntry]) {
        self.runs = runs
        self.count = runs.count
    }
}

/// Response payload from `POST /runs/:id/cancel`. Only a live fan-out swarm or worker accepts a
/// stop; every refusal answers a conflict, so a returned body always means a stop was applied.
public struct RunCancelResponse: Content, Equatable {
    /// Whether a live run or worker accepted the stop (always `true` when a
    /// body is returned).
    public let cancelled: Bool
    /// What was stopped: `"run"` for a whole swarm, or `"worker"` for one child
    /// worker whose siblings keep running.
    public let scope: String
    /// In-flight worker tasks stopped by a run-scope cancel; nil for a worker
    /// stop. A cancel racing startup can honestly report zero while still
    /// marking the run's remaining subtasks cancelled.
    public let workerCount: Int?

    /// Creates a cancel response.
    public init(cancelled: Bool, scope: String, workerCount: Int? = nil) {
        self.cancelled = cancelled
        self.scope = scope
        self.workerCount = workerCount
    }
}

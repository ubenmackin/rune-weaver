// Rune Weaver Server — Index run reporter.
//
// Delivers index run lifecycle events onto the server's durable run log and
// live WebSocket hub.

import Foundation
import RuneWeaverCore

/// Adapter delivering index run lifecycle events onto the server's durable run
/// log and live WebSocket hub.
///
/// A run's start event is appended as a `running` row and broadcast as
/// `run_started`; its completion event updates that same row and broadcasts
/// `run_completed`. Both events carry the coordinator's per-run session
/// identifier, so index runs are filterable in run history exactly like
/// scheduler turns.
public struct ServerIndexRunReporter: IndexRunReporting {
    /// Kind tag applied to index run log rows.
    public static let kind = "index"

    /// Durable run audit trail.
    private let runs: RunLogStore
    /// Live sockets receiving run broadcasts.
    private let hub: WSHub

    /// Creates a reporter.
    /// - Parameters:
    ///   - runs: Run audit trail to persist into.
    ///   - hub: Socket hub to broadcast through.
    public init(runs: RunLogStore, hub: WSHub) {
        self.runs = runs
        self.hub = hub
    }

    /// Persists and broadcasts a run start.
    /// - Parameter event: The start event.
    public func runStarted(_ event: IndexRunEvent) async {
        let entry = RunLogEntry(
            id: event.id,
            sessionID: event.sessionID,
            kind: Self.kind,
            status: event.status.rawValue,
            message: event.message,
            timestamp: event.timestamp,
            response: event.response,
            durationMs: event.durationMs
        )
        await runs.append(entry)
        await hub.broadcastRun(entry)
    }

    /// Persists and broadcasts a run completion.
    ///
    /// The completion event already carries the end instant, so the update
    /// stamps it onto the start row: the finished time then reads as seconds
    /// ago at completion instead of the run's duration ago. The start row keeps
    /// nothing of the start except message order. Falls back to appending the
    /// completed entry when the start row is not present, so a completion never
    /// disappears because its start was pruned.
    /// - Parameter event: The completion event.
    public func runCompleted(_ event: IndexRunEvent) async {
        if let updated = await runs.update(
            id: event.id,
            status: event.status.rawValue,
            response: event.response,
            durationMs: event.durationMs,
            timestamp: event.timestamp
        ) {
            await hub.broadcastRun(updated)
            return
        }
        let entry = RunLogEntry(
            id: event.id,
            sessionID: event.sessionID,
            kind: Self.kind,
            status: event.status.rawValue,
            message: event.message,
            timestamp: event.timestamp,
            response: event.response,
            durationMs: event.durationMs
        )
        await runs.append(entry)
        await hub.broadcastRun(entry)
    }
}

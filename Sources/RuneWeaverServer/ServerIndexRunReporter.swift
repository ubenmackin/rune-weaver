// Rune Weaver Server — Index run reporter.

import Foundation
import RuneWeaverCore

/// Adapter delivering index run lifecycle events onto the server's durable run log and live
/// WebSocket hub.
public struct ServerIndexRunReporter: IndexRunReporting {
    /// Kind tag applied to index run log rows.
    public static let kind = "index"

    /// Durable run audit trail.
    private let runs: RunLogStore
    /// Live sockets receiving run broadcasts.
    private let hub: WSHub
    /// Optional notification dispatcher for failed index runs.
    private let notifier: any SchedulerNotifier?

    /// Creates a reporter. runs: Run audit trail to persist into.
    public init(runs: RunLogStore, hub: WSHub, notifier: any SchedulerNotifier? = nil) {
        self.runs = runs
        self.hub = hub
        self.notifier = notifier
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

    /// Persists and broadcasts a run completion. Falls back to appending the completed entry when
    /// the start row is not present, so a completion never disappears because its start was pruned.
    public func runCompleted(_ event: IndexRunEvent) async {
        if event.status == .error {
            let detail = event.response ?? event.message
            await notifier?.notify(
                title: "Rune Weaver: Index Run Failed",
                body: detail.isEmpty ? "Indexing encountered an error." : detail,
                identifier: "index-run-\(event.id.uuidString)"
            )
        }
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

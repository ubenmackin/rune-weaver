// Rune Weaver Server — Hub-aware fan-out run-log adapter.

import Foundation
import RuneWeaverCore

/// Run-audit witness that keeps fan-out rows live on the shared WebSocket hub.
struct FanOutRunLogAdapter: FanOutRunLogging, Sendable {
    /// Shared run-log store every row kind records through.
    let runs: RunLogStore
    /// Live hub receiving the lifecycle frame for each written row.
    let hub: WSHub

    /// Appends one fan-out row and broadcasts its `run_started` frame.
    @discardableResult
    func appendFanOutRow(kind: String, status: String, message: String, sessionID: UUID) async -> UUID {
        let entry = await runs.append(kind: kind, status: status, message: message, sessionID: sessionID)
        await hub.broadcastRun(entry)
        return entry.id
    }

    /// Flips one row's status and broadcasts the settled frame.
    func updateFanOutRow(id: UUID, status: String) async {
        guard let updated = await runs.update(id: id, status: status) else { return }
        await hub.broadcastRun(updated)
    }

    /// Settles one row with its raw output and duration, then broadcasts.
    func updateFanOutRow(id: UUID, status: String, response: String?, durationMs: Int?) async {
        guard let updated = await runs.update(id: id, status: status, response: response, durationMs: durationMs) else { return }
        await hub.broadcastRun(updated)
    }
}

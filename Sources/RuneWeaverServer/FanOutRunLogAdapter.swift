// Rune Weaver Server — Hub-aware fan-out run-log adapter.
//
// The single bridge between the core fan-out engine's narrow run-audit seam
// and the server's shared run-log store: every parent and worker row a swarm
// writes goes through `RunLogStore` and is then broadcast on the same `WSHub`
// every other run kind uses, so fan-out history stays live instead of only
// appearing on the next poll. Holding the two actors as plain let state keeps
// the engine independent of the transport while leaving tests free to inject
// recording sockets.

import Foundation
import RuneWeaverCore

/// Run-audit witness that keeps fan-out rows live on the shared WebSocket hub.
///
/// Chat, scheduler, goal, and index runs already broadcast their lifecycle
/// frames; without this adapter the fan-out engine's rows were the one silent
/// write path, visible only to pollers. Routing every append and settle here
/// makes fan-out the same live experience as the rest of the Runs surface,
/// with no change to the engine's own seam or to the polling contract.
struct FanOutRunLogAdapter: FanOutRunLogging, Sendable {
    /// Shared run-log store every row kind records through.
    let runs: RunLogStore
    /// Live hub receiving the lifecycle frame for each written row.
    let hub: WSHub

    /// Appends one fan-out row and broadcasts its `run_started` frame.
    ///
    /// Row identifier and session travel verbatim on the frame so a live view
    /// can dedupe the broadcast against a later poll by row id; the broadcast
    /// is awaited before the identifier returns so a caller that immediately
    /// settles the row cannot have its start frame overtaken by its own
    /// completion.
    /// - Parameters:
    ///   - kind: Row kind (`fanout` parent, `fanout_worker` children).
    ///   - status: Row status (`running` until the settle path flips it).
    ///   - message: Content-free display message.
    ///   - sessionID: Session the row belongs to.
    /// - Returns: The appended row's identifier.
    @discardableResult
    func appendFanOutRow(kind: String, status: String, message: String, sessionID: UUID) async -> UUID {
        let entry = await runs.append(kind: kind, status: status, message: message, sessionID: sessionID)
        await hub.broadcastRun(entry)
        return entry.id
    }

    /// Flips one row's status and broadcasts the settled frame.
    ///
    /// An unknown identifier leaves the store untouched and broadcasts
    /// nothing: a settle racing a pruned or foreign row must not fabricate a
    /// frame no viewer can reconcile against a stored row.
    /// - Parameters:
    ///   - id: Row identifier returned by ``appendFanOutRow(kind:status:message:sessionID:)``.
    ///   - status: Terminal row status.
    func updateFanOutRow(id: UUID, status: String) async {
        guard let updated = await runs.update(id: id, status: status) else { return }
        await hub.broadcastRun(updated)
    }

    /// Settles one row with its raw output and duration, then broadcasts.
    ///
    /// Mirrors the status-only witness behind the same unknown-id guard and
    /// keeps a worker's raw output plus duration in its child row (and the
    /// parent's merged summary in the parent row), so the frame a live view
    /// receives carries the full settled audit shape rather than just the
    /// badge flip.
    /// - Parameters:
    ///   - id: Row identifier returned by ``appendFanOutRow(kind:status:message:sessionID:)``.
    ///   - status: Terminal row status.
    ///   - response: Raw output the settled row keeps, or nil to keep the
    ///     stored response untouched.
    ///   - durationMs: Wall-clock duration in milliseconds, or nil to keep
    ///     the stored duration.
    func updateFanOutRow(id: UUID, status: String, response: String?, durationMs: Int?) async {
        guard let updated = await runs.update(id: id, status: status, response: response, durationMs: durationMs) else { return }
        await hub.broadcastRun(updated)
    }
}

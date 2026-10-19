// Rune Weaver Server — Shared turn cancellation settlement.

import Foundation
import RuneWeaverCore

/// Broadcasts settled cancelled rows with one cancelled frame per session.
func broadcastCancelledRuns(_ runs: [RunLogEntry], hub: WSHub, sessionID: UUID) async {
    // One cancelled frame per session even when several rows settle together.
    let frameText = encodeWSFrame(WSCancelledFrame(sessionID: sessionID))
    var first = true
    for run in runs {
        await hub.broadcastTerminalCancellation(run: run, frameText: first ? frameText : nil)
        first = false
    }
}

/// Settles one turn to cancelled exactly once, broadcasting only on transition.
func settleTurnCancelled(context: ServerContext, sessionID: UUID, token: UUID, entry: RunLogEntry, startTime: Date) async {
    // Release the tracker slot before publishing so observers never see
    // a settled row with a stale active slot.
    await context.activeTurns.unregister(sessionID: sessionID, token: token)
    // Clear queued steering on cancel so stale guidance never leaks into the next turn.
    await context.steeringQueue.clear(for: sessionID)
    let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
    // The cancel route may have settled this row already; skip the second broadcast.
    guard let settled = await context.runs.cancel(id: entry.id, durationMs: durationMs) else { return }
    let frameText = encodeWSFrame(WSCancelledFrame(sessionID: sessionID))
    await context.hub.broadcastTerminalCancellation(run: settled, frameText: frameText)
}

/// Cancels the active turn plus running rows for one session, broadcasting settlement.
func requestTurnCancellation(context: ServerContext, sessionID: UUID) async -> Bool {
    // Tracker cancel already trips LLM sockets so no direct registry call here.
    var cancelled = await context.activeTurns.cancel(sessionID: sessionID)
    // Clear queued steering on cancel so stale guidance never leaks into the next turn.
    await context.steeringQueue.clear(for: sessionID)
    let cancelledRuns = await context.runs.cancelRunning(sessionID: sessionID)
    if !cancelledRuns.isEmpty {
        cancelled = true
        await broadcastCancelledRuns(cancelledRuns, hub: context.hub, sessionID: sessionID)
    }
    return cancelled
}

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

/// Settles one turn to cancelled, broadcasting on fresh transition and on enrichment.
/// Late partial text re-broadcasts after an early cancel so observers see the final note.
func settleTurnCancelled(
    context: ServerContext,
    sessionID: UUID,
    token: UUID,
    entry: RunLogEntry,
    startTime: Date,
    audit: ChatTurnAuditSnapshot? = nil
) async {
    let partialText = audit?.partialText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let partialReasoning = audit?.partialReasoning.isEmpty == false ? audit?.partialReasoning : nil
    let toolActions = audit?.toolActions ?? []
    let totalTokens = audit?.totalTokens

    // Release the tracker slot before publishing so observers never see
    // a settled row with a stale active slot.
    await context.activeTurns.unregister(sessionID: sessionID, token: token)
    // Clear queued steering on cancel so stale guidance never leaks into the next turn.
    await context.steeringQueue.clear(for: sessionID)
    let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)

    let hasContent = !partialText.isEmpty || !toolActions.isEmpty
    let responseText: String? = if !partialText.isEmpty {
        "\(partialText)\n\n*(Turn cancelled by user)*"
    } else if hasContent {
        "*(Turn cancelled by user)*"
    } else {
        nil
    }

    guard let settled = await context.runs.cancel(
        id: entry.id,
        durationMs: durationMs,
        response: responseText,
        toolActions: toolActions.isEmpty ? nil : toolActions,
        totalTokens: totalTokens
    ) else { return }
    if hasContent {
        // A re-enriched already-cancelled row must not duplicate the turn note.
        let history = await context.conversations.history(for: sessionID)
        let alreadyNoted = history.last(where: { $0.role == .assistant })?.content.hasSuffix("*(Turn cancelled by user)*") ?? false
        if !alreadyNoted {
            let cancelMessage = Message(
                role: .assistant,
                content: responseText ?? "*(Turn cancelled by user)*",
                reasoning: partialReasoning
            )
            await context.conversations.append(cancelMessage, to: sessionID)
        }
    }
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

// Rune Weaver Server — Deterministic scheduled-send firing: stored-bytes replay with re-validation.
//
// Purpose: fires approved scheduled sends by replaying the exact bytes stored at
// approval through the owning send tool, re-validating the recipient and policy
// at fire time, and settling the row to sent or failed with a run-log row plus
// hub broadcast.
// Scope: the tick driver (expire past-due, claim exactly once, fire each), the
// stored-bytes argument builder, and the run-row audit. No LLM turn runs here:
// a scheduled send never regenerates content, so the owner's approved bytes are
// what ship.
// Architectural role: an extension of ``ServerSchedulerWorker`` beside the goal
// execution split, keeping the worker body within the type-length budget.

import Foundation
import RuneWeaverCore

extension ServerSchedulerWorker {
    /// Run status for an in-flight scheduled send replay.
    private static let scheduledSendSendingStatus = "sending"
    /// Run status for a delivered scheduled send.
    private static let scheduledSendSentStatus = "sent"
    /// Run status for a refused, failed, or skipped scheduled send.
    private static let scheduledSendFailedStatus = "failed"
    /// Tool name the email channel replays through.
    private static let emailSendToolName = "email.send"
    /// Tool name the messages channel replays through.
    private static let messagesSendToolName = "messages.send"

    /// Expires past-due sends, then claims and fires everything due at `now`.
    ///
    /// Expiry runs first so a send that aged out during downtime settles to
    /// `failed` with its skip reason before any claim sees it, keeping the
    /// claim window free of rows that must never fire. Each claimed send then
    /// replays exactly once through ``fireScheduledSend``.
    /// - Parameter now: Evaluation time.
    func fireDueScheduledSends(now: Date) async throws {
        for skipped in await scheduler.expirePastDueSends(now: now) {
            await notePastDueSkip(skipped)
        }
        for send in await scheduler.claimDueSends(now: now) {
            try await fireScheduledSend(send)
        }
    }

    /// Records one skipped past-due send as its inbox note on the Runs surface.
    ///
    /// The skip is already terminal in the store, so this row exists purely for
    /// the audit trail and the dashboard broadcast.
    private func notePastDueSkip(_ send: ScheduledSend) async {
        let entry = await runs.append(
            kind: "scheduler",
            status: Self.scheduledSendFailedStatus,
            message: scheduledSendMessage(send),
            response: send.failureReason,
            durationMs: 0
        )
        await hub.broadcastRun(entry)
        await logger?("Scheduled send to '\(send.recipient)' skipped: \(send.failureReason ?? "past due")")
    }

    /// Fires one claimed scheduled send by replaying its stored bytes.
    ///
    /// The send tool receives the exact approved bytes and re-runs its own
    /// fail-closed validation, so a recipient that went stale, a policy
    /// refusal, or a transport failure settles the row to `failed` with the
    /// tool's reason as the inbox note instead of shipping something the owner
    /// never approved. Nothing here asks a model for content.
    /// - Parameter send: Send claimed from the store, already in `sending`.
    func fireScheduledSend(_ send: ScheduledSend) async throws {
        let startedAt = Date()
        let entry = await runs.append(
            kind: "scheduler",
            status: Self.scheduledSendSendingStatus,
            message: scheduledSendMessage(send),
            durationMs: 0
        )
        await hub.broadcastRun(entry)

        let toolName = send.channel == .email ? Self.emailSendToolName : Self.messagesSendToolName
        guard let tool = await toolBus.tool(named: toolName) else {
            await settleFailed(
                send,
                runID: entry.id,
                startedAt: startedAt,
                reason: "Scheduled send failed: '\(toolName)' is not registered in this engine."
            )
            return
        }
        let input = ToolInput(
            toolName: toolName,
            argumentsJSON: Self.scheduledSendArgumentsJSON(send),
            callID: send.id.uuidString
        )
        // The approval that booked this send is the authorization: the context
        // carries it so the replay never re-files an approval row, while the
        // tool's own validation still gates every byte that ships.
        let context = ToolContext(conversationID: send.id, dryRun: false, approved: true)
        let output: ToolOutput
        do {
            output = try await tool.execute(input: input, context: context)
        } catch let cancel as CancellationError {
            // A cancelled replay halts the tick rather than settling: the claim
            // stays `sending` and a later boot reconciles the interrupted row.
            throw cancel
        } catch {
            output = .failure("Scheduled send failed: \(error.localizedDescription)", callID: input.callID)
        }
        guard output.isError else {
            await settleSent(send, runID: entry.id, startedAt: startedAt)
            return
        }
        await settleFailed(send, runID: entry.id, startedAt: startedAt, reason: output.content)
    }

    /// Settles a delivered send and its run row.
    private func settleSent(_ send: ScheduledSend, runID: UUID, startedAt: Date) async {
        _ = await scheduler.markScheduledSendSent(id: send.id)
        await logger?("Scheduled send to '\(send.recipient)' delivered.")
        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        if let entry = await runs.update(
            id: runID,
            status: Self.scheduledSendSentStatus,
            response: "Delivered to '\(send.recipient)'.",
            durationMs: durationMs
        ) {
            await hub.broadcastRun(entry)
        }
    }

    /// Settles a refused send, its run row, and the owner-facing note.
    private func settleFailed(_ send: ScheduledSend, runID: UUID, startedAt: Date, reason: String) async {
        _ = await scheduler.markScheduledSendFailed(id: send.id, reason: reason)
        await logger?("Scheduled send to '\(send.recipient)' failed: \(reason)")
        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        if let entry = await runs.update(
            id: runID,
            status: Self.scheduledSendFailedStatus,
            response: reason,
            durationMs: durationMs
        ) {
            await hub.broadcastRun(entry)
        }
    }

    /// Human-readable summary for the run row, carrying the channel and recipient.
    private func scheduledSendMessage(_ send: ScheduledSend) -> String {
        "Scheduled \(send.channel == .email ? "email" : "message") send to '\(send.recipient)'"
    }

    /// Encodes the stored bytes as the owning send tool's arguments.
    ///
    /// The payload is rebuilt straight from the row, never from a model: the
    /// stored body HTML ships verbatim as the custom override when the approval
    /// carried it, and the stored text is the plain companion (or the sole body
    /// for a text-only send). Sorted keys keep the encoded bytes stable so two
    /// identical rows replay identical arguments.
    /// - Parameter send: Send being fired.
    /// - Returns: JSON arguments object for the owning tool.
    static func scheduledSendArgumentsJSON(_ send: ScheduledSend) -> String {
        var payload: [String: Any] = [:]
        if send.channel == .email {
            payload["account"] = send.account ?? ""
            payload["to"] = [send.recipient]
            payload["subject"] = send.subject ?? ""
            if let bodyText = send.bodyText {
                payload["bodyText"] = bodyText
            }
            if let bodyHtml = send.bodyHtml {
                payload["bodyHtml"] = bodyHtml
            }
        } else {
            payload["recipient"] = send.recipient
            payload["text"] = send.bodyText ?? send.bodyHtml ?? ""
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return json
    }
}

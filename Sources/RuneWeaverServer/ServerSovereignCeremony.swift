// Rune Weaver Server — Sovereign ceremony scheduling and pulse recording.

import Foundation
import RuneWeaverCore
import Vapor

/// Collaborators one sovereign ceremony records through. Held as explicit values rather than the
/// application so a retained background loop never captures the application itself.
struct SovereignCeremonySink: Sendable {
    /// Tool name the inbox item carries for an unverifiable ceremony.
    static let inboxToolName = "sovereign.mismatch"
    /// Pulse actor receiving the ceremony verdict.
    let pulse: SystemHealthSnapshot
    /// Hub fanning a changed pulse out to live dashboards.
    let hub: WSHub
    /// Change gate deciding whether to publish.
    let lastServed: HealthPulseLastServed
    /// Ledger verifier running the ceremony.
    let ledger: SovereignLedger
    /// Inbox an unverifiable ceremony parks an item in, nil when unwired.
    let approvals: ApprovalQueue?
    /// Decision history recording automatic settlements, nil when unwired.
    let decisionLog: (any ApprovalDecisionRecording)?
}

/// Resolves the sovereign ceremony sink, seeding application storage on first use so every ceremony
/// path records into one pulse.
/// - Parameter app: Application owning the pulse plus the gates.
func sovereignCeremonySink(app: Application) -> SovereignCeremonySink {
    SovereignCeremonySink(
        pulse: securityProbeSink(app: app).pulse,
        hub: app.runeWeaver.hub,
        lastServed: app.healthPulseLastServed,
        ledger: app.runeWeaver.sovereignLedger,
        approvals: app.runeWeaver.approvals,
        decisionLog: app.runeWeaver.approvalDecisions
    )
}

/// Settles every pending system notice for one tool: one `approval_decided` frame per settled item
/// through the same hub publish path the decide route uses, plus one decision-history row carrying
/// the settle note so the audit trail records the automatic resolution.
func settleSystemNotice(
    toolName: String,
    note: String,
    approvals: ApprovalQueue,
    hub: WSHub,
    decisionLog: (any ApprovalDecisionRecording)?
) async {
    let settled = await approvals.settleSystemNotice(toolName: toolName)
    for request in settled {
        // Recovery settlement rides the same decided-frame path as an owner decision so
        // every dashboard view drops the settled card through one encoding.
        await hub.broadcastApprovalDecided(id: request.id, approved: true, sessionID: request.sessionID)
        // The settle note rides the row's display target: the only free-form
        // field the history renders, so recovery reads without a second channel.
        await decisionLog?.append(ApprovalDecisionEntry(
            toolName: request.toolName,
            scope: nil,
            allowed: true,
            duration: TrustDuration.thisTime.rawValue,
            surface: "settled",
            sessionID: request.sessionID?.uuidString,
            displayTarget: note,
            decidedAt: Date()
        ))
    }
}

/// Runs one sovereign verification ceremony and records it into the pulse.
@discardableResult
func runSovereignCeremony(sink: SovereignCeremonySink, reason: String) async -> SovereignVerdict? {
    let verdict: SovereignVerdict
    do {
        verdict = try await sink.ledger.verifyChain()
    } catch {
        RuneWeaverLog.server.warning("Sovereign ceremony (\(reason)): unverifiable artifact: \(error.localizedDescription)")
        // A stale, forged, or unreadable artifact refuses the ceremony, so
        // park fail-closed instead of keeping a possibly green prior pulse.
        await sink.pulse.recordSovereignFailure()
        let value = await sink.pulse.snapshot()
        if sink.lastServed.updateIfChanged(value) {
            await publishHealthPulse(value, hub: sink.hub)
        }
        if let approvals = sink.approvals {
            // Dedup keys on pending existence in one actor hop, so concurrent ceremonies cannot
            // double-park and a changed failure reason updates nothing until it resolves; the
            // filing broadcast rides the queue's insert hop, not a caller-side frame.
            await approvals.enqueueSystemNoticeIfAbsent(
                toolName: SovereignCeremonySink.inboxToolName,
                description: "Sovereign ceremony (\(reason)) could not verify history: \(error.localizedDescription). "
                    + "The system pulse stays fail-closed until a passing re-verification."
            )
        }
        return nil
    }
    await sink.pulse.recordSovereign(verdict)
    let value = await sink.pulse.snapshot()
    if sink.lastServed.updateIfChanged(value) {
        await publishHealthPulse(value, hub: sink.hub)
    }
    switch verdict.outcome {
    case .verified, .empty:
        RuneWeaverLog.server.info("Sovereign ceremony (\(reason)): \(verdict.outcome.rawValue) at \(verdict.primaryTip).")
        // A passing verdict is the mapped remedy resolving a parked mismatch card.
        if let approvals = sink.approvals {
            await settleSystemNotice(
                toolName: SovereignCeremonySink.inboxToolName,
                note: "Sovereign ceremony (\(reason)) recovered: \(verdict.outcome.rawValue) at \(verdict.primaryTip).",
                approvals: approvals,
                hub: sink.hub,
                decisionLog: sink.decisionLog
            )
        }
    case .mismatch:
        RuneWeaverLog.server.warning("Sovereign ceremony (\(reason)): mismatch parked red; primary \(verdict.primaryTip).")
    case .orphaned:
        RuneWeaverLog.server.warning("Sovereign ceremony (\(reason)): orphaned anchor parked red; primary \(verdict.primaryTip).")
    }
    return verdict
}

/// Re-attests the current primary head with a fresh signed vote, then re-runs the ceremony so the
/// restored copy is corroborated by a verified vote instead of a silent repair.
@discardableResult
func reattestSovereign(sink: SovereignCeremonySink) async -> SovereignVerdict? {
    do {
        _ = try await sink.ledger.writeCheckpoint()
    } catch {
        RuneWeaverLog.server.warning("Sovereign re-attestation: signing failed: \(error.localizedDescription)")
        return nil
    }
    return await runSovereignCeremony(sink: sink, reason: "reattest")
}

/// Re-baselines after an owner-approved delete. Rewrites the copy plus checkpoint
/// from the post-delete chain, then records the fresh verdict into the pulse.
@discardableResult
func rebaselineAfterOwnerDelete(sink: SovereignCeremonySink) async -> SovereignVerdict? {
    do {
        let verdict = try await sink.ledger.rebaselineToCurrentChain()
        await sink.pulse.recordSovereign(verdict)
        let value = await sink.pulse.snapshot()
        if sink.lastServed.updateIfChanged(value) {
            await publishHealthPulse(value, hub: sink.hub)
        }
        RuneWeaverLog.server.info("Sovereign re-baseline after owner delete: \(verdict.outcome.rawValue) at \(verdict.primaryTip).")
        // Re-baseline is the mapped remedy resolving a parked mismatch card.
        if let approvals = sink.approvals {
            await settleSystemNotice(
                toolName: SovereignCeremonySink.inboxToolName,
                note: "Sovereign re-baseline after owner delete recovered: \(verdict.outcome.rawValue) at \(verdict.primaryTip).",
                approvals: approvals,
                hub: sink.hub,
                decisionLog: sink.decisionLog
            )
        }
        return verdict
    } catch {
        RuneWeaverLog.server.warning("Sovereign re-baseline after owner delete failed: \(error.localizedDescription)")
        await sink.pulse.recordSovereignFailure()
        let value = await sink.pulse.snapshot()
        if sink.lastServed.updateIfChanged(value) {
            await publishHealthPulse(value, hub: sink.hub)
        }
        if let approvals = sink.approvals {
            // Dedup keys on pending existence in one actor hop, so a persistent re-baseline
            // failure parks one card and the filing broadcast rides the queue's insert hop
            // instead of a caller-side frame.
            await approvals.enqueueSystemNoticeIfAbsent(
                toolName: SovereignCeremonySink.inboxToolName,
                description: "Sovereign re-baseline after owner delete could not verify history: \(error.localizedDescription). "
                    + "The system pulse stays fail-closed until a passing re-verification."
            )
        }
        return nil
    }
}

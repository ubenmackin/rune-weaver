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
        approvals: app.runeWeaver.approvals
    )
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
            await approvals.enqueue(
                toolName: SovereignCeremonySink.inboxToolName,
                description: "Sovereign ceremony (\(reason)) could not verify history: \(error.localizedDescription). "
                    + "The system pulse stays fail-closed until a passing re-verification.",
                input: ToolInput(toolName: SovereignCeremonySink.inboxToolName, argumentsJSON: "{}")
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
    case .mismatch:
        RuneWeaverLog.server.warning("Sovereign ceremony (\(reason)): mismatch parked red; primary \(verdict.primaryTip).")
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
        return verdict
    } catch {
        RuneWeaverLog.server.warning("Sovereign re-baseline after owner delete failed: \(error.localizedDescription)")
        await sink.pulse.recordSovereignFailure()
        let value = await sink.pulse.snapshot()
        if sink.lastServed.updateIfChanged(value) {
            await publishHealthPulse(value, hub: sink.hub)
        }
        if let approvals = sink.approvals {
            await approvals.enqueue(
                toolName: SovereignCeremonySink.inboxToolName,
                description: "Sovereign re-baseline after owner delete could not verify history: \(error.localizedDescription). "
                    + "The system pulse stays fail-closed until a passing re-verification.",
                input: ToolInput(toolName: SovereignCeremonySink.inboxToolName, argumentsJSON: "{}")
            )
        }
        return nil
    }
}

// Rune Weaver Tests — System-notice registry parity and surfacing-only queue behavior.

import Foundation
@testable import RuneWeaverCore
import Testing

/// Probe tool standing in for a system-notice filing so the enrichment path
/// runs against a live Tool value without the Tools layer.
private struct NoticeProbeTool: Tool, Sendable {
    let name: String
    let description = "Probe tool for system-notice tests."
    let inputSchema = JSONSchema(rawValue: #"{"type":"object"}"#)
    let permissionLevel: PermissionLevel = .requiresApproval

    func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        .success("ok", callID: input.callID)
    }
}

/// Records notice-filed broadcast ids so the actor-hop delivery of the filed
/// frame stays assertable without a hub.
private actor NoticeBroadcastRecorder {
    private(set) var recorded: [UUID] = []

    func record(_ id: UUID) {
        recorded.append(id)
    }
}

@Suite("System Notice Tools Registry")
struct SystemNoticeToolsRegistryTests {
    @Test
    func `registry carries exactly the two system tool names`() {
        // Both surfacing tiers key on this closed registry, so the parity
        // tests on both sides pin these exact spellings.
        #expect(SystemNoticeTools.toolNames == ["sovereign.mismatch", "security.probe"])
        for name in SystemNoticeTools.toolNames {
            #expect(SystemNoticeTools.isSystemNotice(name))
        }
    }

    @Test
    func `registry membership never matches a name prefix`() {
        // The registry decides, never a name-prefix rule, so a lookalike
        // name files an ordinary approval instead of a notice.
        #expect(SystemNoticeTools.isSystemNotice("sovereign.mismatch.sequel") == false)
        #expect(SystemNoticeTools.isSystemNotice("security.probeX") == false)
        #expect(SystemNoticeTools.isSystemNotice("email.send") == false)
    }
}

@Suite("System Notice Queue")
struct SystemNoticeQueueTests {
    @Test
    func `atomic dedup parks exactly one notice per tool under concurrent filings`() async {
        let queue = ApprovalQueue()
        // Concurrent ceremony runs race the dedup: check and insert are one
        // actor hop, so exactly one notice parks no matter how many filings
        // interleave.
        let filed = await withTaskGroup(of: PermissionRequest?.self) { group in
            for index in 0 ..< 32 {
                group.addTask {
                    await queue.enqueueSystemNoticeIfAbsent(
                        toolName: "sovereign.mismatch",
                        description: "Ceremony \(index) could not verify history."
                    )
                }
            }
            var results: [PermissionRequest?] = []
            for await request in group {
                results.append(request)
            }
            return results
        }
        #expect(filed.compactMap(\.self).count == 1)
        let pending = await queue.list()
        #expect(pending.count == 1)
        #expect(pending.first?.toolName == "sovereign.mismatch")
        #expect(await queue.hasPending(toolName: "sovereign.mismatch"))
    }

    @Test
    func `each registered tool parks its own notice and lookalike names file nothing`() async {
        let queue = ApprovalQueue()
        let sovereign = await queue.enqueueSystemNoticeIfAbsent(
            toolName: "sovereign.mismatch",
            description: "Sovereign ceremony could not verify history."
        )
        let probe = await queue.enqueueSystemNoticeIfAbsent(
            toolName: "security.probe",
            description: "Security probes failed fail-closed."
        )
        #expect(sovereign != nil)
        #expect(probe != nil)
        // Dedup is per system tool, not per queue.
        #expect(await queue.count() == 2)
        // The registry decides, so a lookalike name files nothing.
        #expect(await queue.enqueueSystemNoticeIfAbsent(
            toolName: "sovereign.mismatchX",
            description: "Lookalike filing."
        ) == nil)
        #expect(await queue.count() == 2)
    }

    @Test
    func `decision path refuses a notice and mints no trust`() async throws {
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let notice = try #require(
            await queue.enqueueSystemNoticeIfAbsent(
                toolName: "security.probe",
                description: "Security probes failed fail-closed."
            )
        )
        // Approve-forever and deny-forever both refuse: resolution is never
        // a decision, so neither polarity can resolve the park or mint a rule.
        #expect(await queue.decide(id: notice.id, approved: true, duration: .forever, scope: .toolWide) == false)
        #expect(await queue.decide(id: notice.id, approved: false, duration: .forever, scope: .toolWide) == false)
        #expect(await queue.request(id: notice.id) != nil)
        #expect(await gate.activeRules().isEmpty)
    }

    @Test
    func `settlement removes only the named tool's notices and releases a parked waiter`() async throws {
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let notice = try #require(
            await queue.enqueueSystemNoticeIfAbsent(
                toolName: "sovereign.mismatch",
                description: "Sovereign ceremony could not verify history."
            )
        )
        let ordinary = await queue.enqueue(
            toolName: "files.write",
            description: "Ordinary approval.",
            input: ToolInput(toolName: "files.write", argumentsJSON: #"{"path":"out.txt"}"#)
        )
        async let decision = await queue.waitForDecision(id: notice.id)

        let settled = await queue.settleSystemNotice(toolName: "sovereign.mismatch")
        #expect(settled.map(\.id) == [notice.id])
        // A defensively parked waiter releases with the recovery verdict
        // instead of staying suspended.
        let resolved = await decision
        #expect(resolved.approved == true)
        // Only the notice resolved; the ordinary approval stays parked.
        #expect(await queue.request(id: notice.id) == nil)
        #expect(await queue.request(id: ordinary.id) != nil)
        // The remedy, not a decision, resolved the park, so no rule was minted.
        #expect(await gate.activeRules().isEmpty)
        await queue.clear()
    }

    @Test
    func `filing a notice schedules no assessment child`() async {
        let queue = ApprovalQueue()
        await queue.setOnEnriched { _ in
            Issue.record("A system notice must never schedule a safety assessment")
        }
        let notice = await queue.fileRequest(
            tool: NoticeProbeTool(name: "security.probe"),
            call: ToolInput(toolName: "security.probe", argumentsJSON: "{}")
        )
        // Past the assessor's bounded evaluation budget a real child would
        // have landed an assessment; the registry skip leaves the notice
        // unassessed and the surfacing channel silent.
        try? await Task.sleep(nanoseconds: 3_500_000_000)
        let parked = await queue.request(id: notice.id)
        #expect(parked?.assessment == nil)
        await queue.setOnEnriched(nil)
        await queue.clear()
    }

    @Test
    func `filing broadcast rides the same actor hop as the insert`() async throws {
        let queue = ApprovalQueue()
        let recorder = NoticeBroadcastRecorder()
        await queue.setOnNoticeFiled { request in
            await recorder.record(request.id)
        }
        let notice = try #require(
            await queue.enqueueSystemNoticeIfAbsent(
                toolName: "security.probe",
                description: "Security probes failed fail-closed."
            )
        )
        // The filed frame is already delivered when the filing call returns, so a settle that
        // removes the entry cannot race a later caller-side frame into stranding a phantom card.
        #expect(await recorder.recorded == [notice.id])
        // A deduped filing broadcasts nothing: the parked card is already live.
        await queue.enqueueSystemNoticeIfAbsent(
            toolName: "security.probe",
            description: "A changed failure reason updates nothing."
        )
        #expect(await recorder.recorded == [notice.id])
        await queue.setOnNoticeFiled(nil)
        await queue.clear()
    }
}

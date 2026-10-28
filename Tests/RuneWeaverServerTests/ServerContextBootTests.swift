// Rune Weaver Server Tests — Bounded wait installed by the live approval handler.

import Foundation
import RuneWeaverCore
@testable import RuneWeaverServer
import Testing

/// Registered name for the stub tool, kept off every real tool's namespace.
private let gatedStubToolName = "stub.gatedAction"

/// Requires-approval stub so a direct bus execution parks in the live approval handler.
private struct GatedStubTool: Tool, Sendable {
    let name = gatedStubToolName
    var description: String {
        "Stub capability that parks for approval."
    }

    let permissionLevel = PermissionLevel.requiresApproval
    let inputSchema = JSONSchema.emptyObject

    func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        .success("ran", callID: input.callID)
    }
}

/// Wires a gate, queue, and bus through the live approval handler with a short timeout.
private func makeGatedBus(decisionTimeoutSeconds: Double) async -> (bus: ToolBus, approvals: ApprovalQueue) {
    let gate = PermissionGate(ruleStore: InMemoryAccessRuleStore())
    let approvals = ApprovalQueue(permissionGate: gate)
    let bus = ToolBus(permissionGate: gate)
    let workspace = WorkspaceStore(
        rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("rw-boot-approval-\(UUID().uuidString)")
    )
    await installLiveApprovalHandler(
        bus: bus,
        approvals: approvals,
        hub: WSHub(),
        workspaceStore: workspace,
        onApprovalRequested: nil,
        decisionTimeoutSeconds: decisionTimeoutSeconds
    )
    await bus.register(tool: GatedStubTool())
    return (bus, approvals)
}

/// Polls until the handler files its request, bounded so a wiring failure fails
/// the test instead of hanging it.
private func firstFiledRequest(in approvals: ApprovalQueue) async throws -> PermissionRequest {
    for _ in 0 ..< 500 {
        if let request = await approvals.list().first {
            return request
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    return try #require(await approvals.list().first)
}

@Suite("Live Approval Handler Wait Bound")
struct ServerContextBootLiveApprovalTests {
    @Test
    func `an unanswered approval denies at the timeout and keeps the inbox entry`() async throws {
        let (bus, approvals) = await makeGatedBus(decisionTimeoutSeconds: 0.2)
        let startedAt = Date()
        let execution = Task {
            await bus.execute(
                toolCall: ToolInput(toolName: gatedStubToolName, argumentsJSON: "{}"),
                context: ToolContext(conversationID: UUID())
            )
        }
        defer { execution.cancel() }

        let request = try await firstFiledRequest(in: approvals)
        let result = await execution.value
        let elapsed = Date().timeIntervalSince(startedAt)

        #expect(result.isError)
        #expect(result.content.contains("denied by the approval gate"))
        // The 0.2s timeout must drive the deny, not the 300s default; the ceiling
        // tolerates timer-delivery lag when parallel suites saturate the machine.
        #expect(elapsed < 10.0)
        // Deny-on-timeout stays fail-closed: the request stays filed for triage.
        let retained = try #require(await approvals.request(id: request.id))
        #expect(retained.toolName == gatedStubToolName)
    }

    @Test
    func `a decided request still resolves approved before the timeout`() async throws {
        let (bus, approvals) = await makeGatedBus(decisionTimeoutSeconds: 0.2)
        let execution = Task {
            await bus.execute(
                toolCall: ToolInput(toolName: gatedStubToolName, argumentsJSON: "{}"),
                context: ToolContext(conversationID: UUID())
            )
        }
        defer { execution.cancel() }

        let request = try await firstFiledRequest(in: approvals)
        #expect(await approvals.decide(id: request.id, approved: true, duration: .thisTime))

        let result = await execution.value
        #expect(!result.isError)
        #expect(result.content == "ran")
        let pending = await approvals.list()
        #expect(!pending.contains { $0.id == request.id })
    }
}

// Rune Weaver Tests — Approval grant target matching for specialized tools.
//
// Guards the invariant that a durable narrow grant stores the exact descriptor
// the permission gate derives on the next call. Tools with a composed target
// (`browser.act`, `api.request`) must round-trip through the shared descriptor
// derivation so approving "this target" once keeps covering that same target
// instead of silently re-prompting or collapsing to the wrong scope.

import Foundation
@testable import RuneWeaverCore
import Testing

@Suite("Approval Target Matching")
struct ApprovalTargetMatchingTests {
    private struct BrowserActProbeTool: Tool, Sendable {
        let name = "browser.act"
        let description = "Act on a browser snapshot ref."
        let inputSchema = JSONSchema(rawValue: #"{"type":"object"}"#)
        let permissionLevel = PermissionLevel.requiresApproval
        func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
            .success("browser-ok", callID: input.callID)
        }
    }

    private struct ApiRequestProbeTool: Tool, Sendable {
        let name = "api.request"
        let description = "Constrained HTTP request."
        let inputSchema = JSONSchema(rawValue: #"{"type":"object"}"#)
        let permissionLevel = PermissionLevel.requiresApproval
        func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
            .success("api-ok", callID: input.callID)
        }
    }

    @Test
    func `browser.act narrow grant covers the identical next call`() async {
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let arguments = #"{"action":"click","ref":"e12","url":"https://example.com/page"}"#
        let call = ToolInput(toolName: "browser.act", argumentsJSON: arguments)
        let request = await queue.enqueue(
            toolName: "browser.act",
            description: "Act on a browser snapshot ref.",
            input: call
        )

        #expect(await queue.decide(id: request.id, approved: true, duration: .oneHour) == true)

        // The decision path knows only the tool name, so its derivation must
        // agree with the live-tool derivation the allow check runs later.
        let descriptor = ActionDescriptor.descriptor(for: call, tool: BrowserActProbeTool())
        #expect(descriptor.target == "click e12 @ https://example.com/page")
        #expect(descriptor == ActionDescriptor.descriptor(for: call, toolName: "browser.act"))
        // Generic extraction drops the action verb, which is exactly the drift
        // that would leave a stored grant unmatched.
        #expect(descriptor.target != ActionDescriptor.target(from: call))

        #expect(await gate.isTrusted(descriptor) == true)
        let verdict = await gate.checkPermission(toolCall: call, tool: BrowserActProbeTool())
        #expect(verdict == .allowed)
    }

    @Test
    func `api.request narrow grant covers the identical next call`() async {
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let arguments = #"{"method":"POST","url":"https://api.example.com/items","body":"{\"a\":1}"}"#
        let call = ToolInput(toolName: "api.request", argumentsJSON: arguments)
        let request = await queue.enqueue(
            toolName: "api.request",
            description: "Constrained HTTP request.",
            input: call
        )

        #expect(await queue.decide(id: request.id, approved: true, duration: .oneHour) == true)

        let descriptor = ActionDescriptor.descriptor(for: call, tool: ApiRequestProbeTool())
        #expect(descriptor.target == #"POST https://api.example.com/items body:{"a":1}"#)
        #expect(descriptor == ActionDescriptor.descriptor(for: call, toolName: "api.request"))
        // Generic extraction stores only the URL, dropping method and body.
        #expect(descriptor.target != ActionDescriptor.target(from: call))

        #expect(await gate.isTrusted(descriptor) == true)
        let verdict = await gate.checkPermission(toolCall: call, tool: ApiRequestProbeTool())
        #expect(verdict == .allowed)
    }

    @Test
    func `thisTime approval records no trust even when widen is requested`() async {
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let call = ToolInput(
            toolName: "api.request",
            argumentsJSON: #"{"method":"GET","url":"https://api.example.com/items"}"#
        )
        let request = await queue.enqueue(
            toolName: "api.request",
            description: "Constrained HTTP request.",
            input: call
        )

        // A one-shot decision must stay one-shot: the widen flag never overrides
        // the thisTime guard, so no grant is minted and the next call parks again.
        #expect(await queue.decide(id: request.id, approved: true, duration: .thisTime, widen: true) == true)
        #expect(await gate.activeGrants().isEmpty == true)

        let verdict = await gate.checkPermission(toolCall: call, tool: ApiRequestProbeTool())
        guard case .requiresApproval = verdict else {
            Issue.record("Expected thisTime approval to park again, got \(verdict)")
            return
        }
    }
}

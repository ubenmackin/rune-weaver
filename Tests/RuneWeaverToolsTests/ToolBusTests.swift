// Rune Weaver Tools Tests — Built-in tool bus wiring and registration tests.

import Foundation
@testable import RuneWeaverCore
@testable import RuneWeaverTools
import Testing

/// Read-only stub proving the bus bypasses approval for `readOnly` tools.
private struct ReadOnlyStubTool: Tool, Sendable {
    /// Stable stub name.
    let name = "stub.read"
    /// When the stub should be used.
    let description = "Read-only stub."
    /// Empty-object schema.
    let inputSchema = JSONSchema(rawValue: #"{"type":"object"}"#)
    /// Always allowed without prompts.
    let permissionLevel = PermissionLevel.readOnly

    /// Returns a canned success.
    func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        .success("stub-ok", callID: input.callID)
    }
}

/// Approval-gated stub proving the contrast: without approval the bus denies.
private struct ApprovalStubTool: Tool, Sendable {
    /// Stable stub name.
    let name = "stub.write"
    /// When the stub should be used.
    let description = "Approval-gated stub."
    /// Empty-object schema.
    let inputSchema = JSONSchema(rawValue: #"{"type":"object"}"#)
    /// Requires an approval decision.
    let permissionLevel = PermissionLevel.requiresApproval

    /// Returns a canned success when approval allows the call.
    func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        .success("stub-wrote", callID: input.callID)
    }
}

@Suite("Tool Bus")
struct ToolBusTests {
    @Test
    func `Unknown tool returns error result`() async {
        let bus = ToolBus()
        let input = ToolInput(toolName: "missing", argumentsJSON: "{}")
        let context = ToolContext(conversationID: UUID())
        let result = await bus.execute(toolCall: input, context: context)
        #expect(result.isError == true)
    }

    @Test
    func `ReadOnly tools run without approval prompts`() async {
        let bus = ToolBus(permissionGate: PermissionGate())
        await bus.register(tool: ReadOnlyStubTool())
        // A denying handler would fail the call if consulted; success proves bypass.
        await bus.setApprovalHandler { _, _ in false }
        let result = await bus.execute(
            toolCall: ToolInput(toolName: "stub.read", argumentsJSON: "{}"),
            context: ToolContext(conversationID: UUID())
        )
        #expect(result.isError == false)
        #expect(result.content == "stub-ok")
    }

    @Test
    func `ReadOnly tools run with a gate and no approval handler`() async {
        let bus = ToolBus(permissionGate: PermissionGate())
        await bus.register(tool: ReadOnlyStubTool())
        let result = await bus.execute(
            toolCall: ToolInput(toolName: "stub.read", argumentsJSON: "{}"),
            context: ToolContext(conversationID: UUID())
        )
        #expect(result.isError == false)
    }

    @Test
    func `RequiresApproval tools are denied without approval`() async {
        let bus = ToolBus(permissionGate: PermissionGate())
        await bus.register(tool: ApprovalStubTool())
        let result = await bus.execute(
            toolCall: ToolInput(toolName: "stub.write", argumentsJSON: "{}"),
            context: ToolContext(conversationID: UUID())
        )
        #expect(result.isError == true)
    }

    @Test
    func `RequiresApproval dry run still honors gate denials`() async {
        let gate = PermissionGate()
        let bus = ToolBus(permissionGate: gate)
        await bus.register(tool: ApprovalStubTool())
        // Explicit denial must hold even when the caller promises dry run.
        await gate.deny(ActionDescriptor(toolName: "stub.write"), reason: "no writes in test")
        let denied = await bus.execute(
            toolCall: ToolInput(toolName: "stub.write", argumentsJSON: "{}"),
            context: ToolContext(conversationID: UUID(), dryRun: true)
        )
        #expect(denied.isError == true)
        #expect(denied.content.contains("denied") == true)
    }

    @Test
    func `RequiresApproval dry run still requires approval`() async {
        let bus = ToolBus(permissionGate: PermissionGate())
        await bus.register(tool: ApprovalStubTool())
        // No handler means denial; dry run must not bypass the gate.
        let result = await bus.execute(
            toolCall: ToolInput(toolName: "stub.write", argumentsJSON: "{}"),
            context: ToolContext(conversationID: UUID(), dryRun: true)
        )
        #expect(result.isError == true)
    }
}

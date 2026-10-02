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

/// Fails with a caller-supplied message so the bus fallback classification is exercised.
private struct FailingStubTool: Tool, Sendable {
    /// Stable stub name.
    let name = "stub.fail"
    /// When the stub should be used.
    let description = "Always-failing stub."
    /// Empty-object schema.
    let inputSchema = JSONSchema(rawValue: #"{"type":"object"}"#)
    /// Always allowed without prompts.
    let permissionLevel = PermissionLevel.readOnly
    /// Failure content returned to the bus.
    let message: String
    /// Explicit category forwarded to the bus, or nil to exercise the fallback sniff.
    var errorKind: ToolErrorKind?

    /// Returns the canned failure, forwarding the explicit category when set so the
    /// bus-precedence path is covered alongside the sniffing path.
    func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        .failure(message, callID: input.callID, errorKind: errorKind)
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
        await bus.setLegacyApprovalHandler { _, _ in false }
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
    func `RequiresApproval dry run previews without approval`() async {
        let bus = ToolBus(permissionGate: PermissionGate())
        await bus.register(tool: ApprovalStubTool())
        // Dry-run previews never park: no handler needed, the tool previews
        // success through its dry-run path instead of waiting on the inbox.
        let preview = await bus.execute(
            toolCall: ToolInput(toolName: "stub.write", argumentsJSON: "{}"),
            context: ToolContext(conversationID: UUID(), dryRun: true)
        )
        #expect(preview.isError == false)
        // Fail-closed: the same call without dry run still denies with no handler.
        let denied = await bus.execute(
            toolCall: ToolInput(toolName: "stub.write", argumentsJSON: "{}"),
            context: ToolContext(conversationID: UUID())
        )
        #expect(denied.isError == true)
    }

    @Test
    func `Approval handler receives ToolContext with conversationID`() async {
        actor ContextHolder {
            var sessionID: UUID?

            func set(_ id: UUID?) {
                sessionID = id
            }

            func get() -> UUID? {
                sessionID
            }
        }
        let bus = ToolBus(permissionGate: PermissionGate())
        await bus.register(tool: ApprovalStubTool())
        let expectedSession = UUID()
        let holder = ContextHolder()
        await bus.setApprovalHandler { _, _, context in
            await holder.set(context.conversationID)
            return true
        }
        let result = await bus.execute(
            toolCall: ToolInput(toolName: "stub.write", argumentsJSON: "{}"),
            context: ToolContext(conversationID: expectedSession)
        )
        #expect(result.isError == false)
        #expect(await holder.get() == expectedSession)
    }

    @Test
    func `Clearing the approval handler denies gated tools`() async {
        let bus = ToolBus(permissionGate: PermissionGate())
        await bus.register(tool: ApprovalStubTool())
        await bus.setApprovalHandler { _, _, _ in true }
        let allowed = await bus.execute(
            toolCall: ToolInput(toolName: "stub.write", argumentsJSON: "{}"),
            context: ToolContext(conversationID: UUID())
        )
        #expect(allowed.isError == false)
        // A bare nil literal must resolve to the context-aware setter and clear it;
        // two same-named optional overloads would otherwise make this ambiguous.
        await bus.setApprovalHandler(nil)
        let denied = await bus.execute(
            toolCall: ToolInput(toolName: "stub.write", argumentsJSON: "{}"),
            context: ToolContext(conversationID: UUID())
        )
        #expect(denied.isError == true)
    }

    @Test
    func `Legacy two-argument handler still delegates`() async {
        let bus = ToolBus(permissionGate: PermissionGate())
        await bus.register(tool: ApprovalStubTool())
        // Compatibility path: callers that predate context-aware approvals keep
        // working through the bridging setter.
        await bus.setLegacyApprovalHandler { _, _ in true }
        let result = await bus.execute(
            toolCall: ToolInput(toolName: "stub.write", argumentsJSON: "{}"),
            context: ToolContext(conversationID: UUID())
        )
        #expect(result.isError == false)
    }

    @Test
    func `Invalid JSON arguments return invalidSyntax errorKind`() async {
        let bus = ToolBus()
        await bus.register(tool: ReadOnlyStubTool())
        let input = ToolInput(toolName: "stub.read", argumentsJSON: "{not valid json}")
        let context = ToolContext(conversationID: UUID())
        let result = await bus.execute(toolCall: input, context: context)
        #expect(result.isError == true)
        #expect(result.errorKind == .invalidSyntax)
        #expect(result.content.contains("Invalid arguments JSON"))
    }

    @Test
    func `Tool argument failure content classifies as invalidSyntax`() async {
        let bus = ToolBus()
        await bus.register(tool: FailingStubTool(message: "Invalid stub.fail arguments: 'x' must not be empty."))
        let result = await bus.execute(
            toolCall: ToolInput(toolName: "stub.fail", argumentsJSON: "{}"),
            context: ToolContext(conversationID: UUID())
        )
        #expect(result.isError == true)
        #expect(result.errorKind == .invalidSyntax)
    }

    @Test
    func `Tool runtime failure defaults to executionError`() async {
        let bus = ToolBus()
        await bus.register(tool: FailingStubTool(message: "Runtime exploded"))
        let result = await bus.execute(
            toolCall: ToolInput(toolName: "stub.fail", argumentsJSON: "{}"),
            context: ToolContext(conversationID: UUID())
        )
        #expect(result.isError == true)
        #expect(result.errorKind == .executionError)
    }

    @Test
    func `Explicit tool errorKind overrides the content sniff`() async {
        let bus = ToolBus()
        // Configuration and runtime messages can share the "Invalid ..." wording the
        // fallback sniffs for; an explicit kind is the tool's contract, so the bus
        // must report execution_error rather than mask it as invalid_syntax.
        await bus.register(tool: FailingStubTool(
            message: "Invalid browser.searxng_url 'nope': must be an absolute URL.",
            errorKind: .executionError
        ))
        let result = await bus.execute(
            toolCall: ToolInput(toolName: "stub.fail", argumentsJSON: "{}"),
            context: ToolContext(conversationID: UUID())
        )
        #expect(result.isError == true)
        #expect(result.errorKind == .executionError)
    }

    @Test
    func `Unknown tool returns invalidTool errorKind and available tools`() async {
        let bus = ToolBus()
        await bus.register(tool: ReadOnlyStubTool())
        let input = ToolInput(toolName: "missing.tool", argumentsJSON: "{}")
        let context = ToolContext(conversationID: UUID())
        let result = await bus.execute(toolCall: input, context: context)
        #expect(result.isError == true)
        #expect(result.errorKind == .invalidTool)
        #expect(result.content.contains("stub.read"))
    }

    @Test
    func `BuiltinToolPlugins makeAllTools includes files email and web tools`() async throws {
        let policyStore = await ToolsTestSupport.makeTestPolicyStore()
        let tools = try await BuiltinToolPlugins.makeAllTools(
            emailConfig: EmailConfig(),
            filesConfig: FilesConfig(),
            browserConfig: BrowserConfig(),
            policyStore: policyStore
        )
        let names = Set(tools.map(\.name))
        #expect(names.contains("files.read"))
        #expect(names.contains("files.grep"))
        #expect(names.contains("files.glob"))
        #expect(names.contains("web.search"))
        #expect(names.contains("email.search"))
    }

    @Test
    func `BuiltinToolPlugins forwards files policy to email attachment exports`() async throws {
        let realHome = FilesAccessGuard.resolvedHomeURL()
        let exportPath = realHome
            .appendingPathComponent("runeweaver-email-policy-\(UUID().uuidString).txt")
            .path
        // The path lives inside the default home root, so the default policy
        // permits it and only a forwarded restrictive policy can deny it.
        #expect(FilesAccessGuard.evaluate(path: exportPath, filesConfig: FilesConfig()).allowed)

        let restrictive = FilesConfig(
            denyPatterns: [],
            allowRoots: ["/tmp/runeweaver-email-policy-unused-root"],
            requireApprovalOnDeny: false
        )
        let policyStore = await ToolsTestSupport.makeTestPolicyStore()
        let tools = try await BuiltinToolPlugins.makeAllTools(
            emailConfig: EmailConfig(),
            filesConfig: restrictive,
            browserConfig: BrowserConfig(),
            policyStore: policyStore
        )
        guard let attachment = tools.first(where: { $0.name == "email.attachment" }) else {
            Issue.record("email.attachment was not registered")
            return
        }
        let payload = "{\"account\":\"personal\",\"id\":\"42\",\"index\":0,\"saveToPath\":\"\(exportPath)\"}"
        let output = try await attachment.execute(
            input: ToolInput(toolName: "email.attachment", argumentsJSON: payload),
            context: ToolContext(conversationID: UUID())
        )
        // Denial at the workspace guard precedes account lookup, so no account
        // or credential setup is needed to prove the forwarded policy is live.
        #expect(output.isError == true)
        #expect(output.content.contains("outside the allowed roots"))
    }

    @Test
    func `BuiltinToolPlugins allToolNames contains files and email names`() {
        let allNames = Set(BuiltinToolPlugins.allToolNames)
        #expect(allNames.contains("files.read"))
        #expect(allNames.contains("files.grep"))
        #expect(allNames.contains("files.glob"))
        #expect(allNames.contains("email.search"))
        #expect(allNames.contains("web.search"))
    }

    @Test
    func `Alias resolves identically across bus paths and unregister drops stale aliases`() async {
        let bus = ToolBus()
        await bus.register(tool: ReadOnlyStubTool())
        // Generic alias plumbing: the alias is only a second name for the
        // target, so every lookup and mutation must land on the same entry.
        // Otherwise an alias could execute while reporting disabled, or stay
        // enabled while its target is off.
        await bus.registerAlias(from: "stub.legacy", to: "stub.read")

        // Lookup shares resolution: alias and canonical name return the same tool.
        #expect(await bus.tool(named: "stub.legacy")?.name == "stub.read")
        #expect(await bus.tool(named: "stub.read")?.name == "stub.read")

        // Enablement shares resolution: both spellings report one state.
        #expect(await bus.isToolEnabled(named: "stub.legacy") == true)
        #expect(await bus.isToolEnabled(named: "stub.read") == true)

        // Disabling through the alias flips the shared target state, so the
        // canonical spelling observes the same gate.
        await bus.disableTool(named: "stub.legacy")
        #expect(await bus.isToolEnabled(named: "stub.read") == false)
        #expect(await bus.isToolEnabled(named: "stub.legacy") == false)

        // A disabled target stays disabled through the alias execution path.
        let disabled = await bus.execute(
            toolCall: ToolInput(toolName: "stub.legacy", argumentsJSON: "{}"),
            context: ToolContext(conversationID: UUID())
        )
        #expect(disabled.isError == true)

        // Enabling through the canonical name restores the alias view, proving
        // the toggle is one entry rather than two diverging flags.
        await bus.enableTool(named: "stub.read")
        #expect(await bus.isToolEnabled(named: "stub.legacy") == true)

        // Execution shares resolution: the alias call runs the target tool.
        let result = await bus.execute(
            toolCall: ToolInput(toolName: "stub.legacy", argumentsJSON: "{}"),
            context: ToolContext(conversationID: UUID())
        )
        #expect(result.isError == false)
        #expect(result.content == "stub-ok")

        // Unregister must drop stale aliases so a removed tool cannot be
        // reached through a leftover name after its definition is gone.
        await bus.unregister(toolNamed: "stub.read")
        #expect(await bus.tool(named: "stub.legacy") == nil)
        #expect(await bus.isToolEnabled(named: "stub.legacy") == false)
        let afterRemove = await bus.execute(
            toolCall: ToolInput(toolName: "stub.legacy", argumentsJSON: "{}"),
            context: ToolContext(conversationID: UUID())
        )
        #expect(afterRemove.isError == true)
    }

    @Test
    func `Boot registers no legacy memory aliases`() async throws {
        let policyStore = await ToolsTestSupport.makeTestPolicyStore()
        let tools = try await BuiltinToolPlugins.makeAllTools(
            emailConfig: EmailConfig(),
            filesConfig: FilesConfig(),
            browserConfig: BrowserConfig(),
            policyStore: policyStore
        )
        // Canonical memory names are the sole wire identity: a fresh build
        // must never advertise the retired spellings as tools.
        let names = Set(tools.map(\.name))
        #expect(!names.contains("remember_fact"))
        #expect(!names.contains("recall_memories"))

        // A bus built from the boot set resolves neither retired name, with or
        // without an explicit alias, so no boot path smuggles one in.
        let bus = ToolBus()
        for tool in tools {
            await bus.register(tool: tool)
        }
        #expect(await bus.tool(named: "remember_fact") == nil)
        #expect(await bus.tool(named: "recall_memories") == nil)
    }
}

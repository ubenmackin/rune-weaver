// Rune Weaver Core Tests — System prompt composer tests.
import Foundation
@testable import RuneWeaverCore
import Testing

/// Read-only stub with a distinctive description and schema.
private struct ComposerReadStub: Tool, Sendable {
    /// Stable stub name.
    let name = "stub.read"
    /// Distinctive description asserted in the composed prompt.
    let description = "Reads stub records for the composer test."
    /// Distinctive schema asserted in the composed prompt.
    let inputSchema = JSONSchema(rawValue: #"{"type":"object","properties":{"query":{"type":"string"}}}"#)
    /// Always allowed without prompts.
    let permissionLevel = PermissionLevel.readOnly

    /// Returns a canned success.
    func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        .success("stub-ok", callID: input.callID)
    }
}

/// Approval-gated stub with a distinctive description and schema.
private struct ComposerWriteStub: Tool, Sendable {
    /// Stable stub name.
    let name = "stub.write"
    /// Distinctive description asserted in the composed prompt.
    let description = "Writes stub records for the composer test."
    /// Distinctive schema asserted in the composed prompt.
    let inputSchema = JSONSchema(rawValue: #"{"type":"object","properties":{"text":{"type":"string"}}}"#)
    /// Requires an approval decision.
    let permissionLevel = PermissionLevel.requiresApproval

    /// Returns a canned success when approval allows the call.
    func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        .success("stub-wrote", callID: input.callID)
    }
}

@Suite("System Prompt Composer")
struct SystemPromptComposerTests {
    @Test
    func `Composed prompt lists every registered tool with description and schema`() async {
        let bus = ToolBus()
        await bus.register(tool: ComposerReadStub())
        await bus.register(tool: ComposerWriteStub())
        let prompt = await SystemPromptComposer.compose(toolBus: bus)
        for tool in await bus.availableTools() {
            #expect(prompt.contains(tool.name))
            // Prompts carry the one-line summary so multi-sentence sources stay within budget.
            #expect(prompt.contains(ToolPromptDisplay.oneLine(tool.description)))
            // Prompts carry minified sorted-keys schemas so strict backends see the same object without whitespace.
            let display = SystemPromptComposer.validatedDisplaySchema(for: tool, supportsVision: true, logSkips: false)
            #expect(display != nil)
            if let display {
                #expect(prompt.contains(SystemPromptComposer.compactSchemaJSON(display)))
            }
        }
        #expect(prompt.contains("stub.read"))
        #expect(prompt.contains("stub.write"))
        #expect(prompt.contains("Reads stub records for the composer test."))
        #expect(prompt.contains("Writes stub records for the composer test."))
        // The default tier needs no label; only gated levels are marked inline.
        #expect(!prompt.contains("Permission: readOnly"))
        #expect(!prompt.contains("[readOnly]"))
        #expect(prompt.contains("[requiresApproval]"))
    }

    @Test
    func `Composed prompt carries identity, tool-use policy, and memory guidance`() {
        let tools: [any Tool] = [ComposerReadStub(), ComposerWriteStub()]
        let prompt = SystemPromptComposer.compose(tools: tools)
        let lowered = prompt.lowercased()
        #expect(prompt.contains("Rune Weaver"))
        #expect(lowered.contains("helpful personal assistant"))
        #expect(lowered.contains("read freely"))
        #expect(lowered.contains("approval-gated writes go through the gate"))
        #expect(lowered.contains("auto-allowed"))
        #expect(lowered.contains("auditable"))
        #expect(prompt.contains("recall_memories"))
        #expect(prompt.contains("remember_fact"))
        #expect(lowered.contains("before answering from history"))
        #expect(lowered.contains("unprompted"))
        #expect(lowered.contains("durable"))
    }

    @Test
    func `Composed prompt from empty registry still carries identity`() {
        let prompt = SystemPromptComposer.compose(tools: [])
        #expect(prompt.contains("Rune Weaver"))
        #expect(prompt.contains("recall_memories"))
        #expect(prompt.contains("remember_fact"))
    }

    @Test
    func `Flag override is preserved over the composed default`() async {
        let tools: [any Tool] = [ComposerReadStub(), ComposerWriteStub()]
        let composed = SystemPromptComposer.compose(tools: tools)
        #expect(SystemPromptComposer.resolve(flag: "custom prompt", tools: tools) == "custom prompt")
        #expect(SystemPromptComposer.resolve(flag: nil, tools: tools) == composed)
        #expect(SystemPromptComposer.resolve(flag: "", tools: tools) == composed)

        let bus = ToolBus()
        await bus.register(tool: ComposerReadStub())
        await bus.register(tool: ComposerWriteStub())
        let busComposed = await SystemPromptComposer.compose(toolBus: bus)
        #expect(await SystemPromptComposer.resolve(flag: "custom prompt", toolBus: bus) == "custom prompt")
        #expect(await SystemPromptComposer.resolve(flag: nil, toolBus: bus) == busComposed)
        #expect(await SystemPromptComposer.resolve(flag: "", toolBus: bus) == busComposed)
    }

    @Test
    func `Composed prompt flows through existing system-message plumbing`() {
        let tools: [any Tool] = [ComposerReadStub()]
        let prompt = SystemPromptComposer.compose(tools: tools)
        let history = [Message(role: .user, content: "hello")].withSystemPrompt(prompt)
        #expect(history.first?.role == .system)
        #expect(history.first?.content == prompt)
    }

    @Test
    func `Prompt byte audit measures total plus per-tool schema contribution`() {
        let tools: [any Tool] = [ComposerReadStub(), ComposerWriteStub()]
        let audit = SystemPromptComposer.byteAudit(tools: tools)
        #expect(audit.totalBytes == SystemPromptComposer.compose(tools: tools).utf8.count)
        #expect(audit.perTool.count == 2)
        for entry in audit.perTool {
            #expect(entry.schemaBytes > 0)
            #expect(entry.entryBytes >= entry.schemaBytes)
        }
        // Sorted-by-name determinism keeps the audit stable across runs.
        #expect(audit.perTool.map(\.name) == ["stub.read", "stub.write"])
    }

    @Test
    func `Vision and text-only prompts stay distinct`() {
        let tools: [any Tool] = [ComposerReadStub()]
        let vision = SystemPromptComposer.compose(tools: tools, supportsVision: true)
        let textOnly = SystemPromptComposer.compose(tools: tools, supportsVision: false)
        #expect(vision != textOnly)
        #expect(vision.lowercased().contains("screenshot"))
        #expect(textOnly.lowercased().contains("text-only"))
    }

    @Test
    func `One-line summary keeps abbreviation guidance intact`() {
        // Abbreviations must not truncate mid-sentence, or prompt guidance is lost.
        let description = "Opens a URL in a fresh isolated context; returns text plus refs (e.g. e12) for browser.act. Auth walls escalate to human login; downloads are manifest-only."
        let oneLine = ToolPromptDisplay.oneLine(description)
        #expect(oneLine == "Opens a URL in a fresh isolated context; returns text plus refs (e.g. e12) for browser.act.")
        #expect(oneLine.contains("e12) for browser.act"))
    }
}

// Rune Weaver Core Tests — System prompt composer tests.
import Foundation
@testable import RuneWeaverCore
import Testing

/// Read-only stub with a distinctive description and schema.
private struct ComposerReadStub: Tool, Sendable {
    /// Stable stub name.
    let name = "stub.read"
    /// Distinctive description.
    let description = "Reads stub records for the composer test."
    /// Distinctive schema.
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
    /// Distinctive description.
    let description = "Writes stub records for the composer test."
    /// Distinctive schema.
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
    func `Composed prompt omits tool schema dumps and keeps lean policy`() async {
        let bus = ToolBus()
        await bus.register(tool: ComposerReadStub())
        await bus.register(tool: ComposerWriteStub())
        let prompt = await SystemPromptComposer.compose(toolBus: bus)

        // Native tool calling omits tool schemas and descriptions from prompt text
        #expect(!prompt.contains("Available tools:"))
        #expect(!prompt.contains("stub.read"))
        #expect(!prompt.contains("stub.write"))
        #expect(!prompt.contains("Reads stub records"))
        #expect(!prompt.contains("Writes stub records"))

        // Prompts carry identity, provenance marker, and tool-use policy
        #expect(prompt.contains("Rune Weaver"))
        #expect(prompt.contains(SystemPromptComposer.composedMarker))
        #expect(prompt.contains("Tool-use policy:"))
        #expect(SystemPromptComposer.isComposedPrompt(prompt))
    }

    @Test
    func `Composed prompt carries identity, tool-use policy, and canonical memory guidance`() {
        let tools: [any Tool] = [ComposerReadStub(), ComposerWriteStub()]
        let prompt = SystemPromptComposer.compose(tools: tools)
        let lowered = prompt.lowercased()

        #expect(prompt.contains("Rune Weaver"))
        #expect(lowered.contains("helpful personal assistant"))
        #expect(lowered.contains("read freely"))
        #expect(lowered.contains("approval-gated"))
        #expect(prompt.contains("memories.store"))
        #expect(prompt.contains("memories.recall"))
        #expect(!prompt.contains("remember_fact"))
        #expect(!prompt.contains("recall_memories"))
        #expect(lowered.contains("unprompted"))
        #expect(lowered.contains("durable"))
    }

    @Test
    func `Composed prompt from empty registry still carries identity`() {
        let prompt = SystemPromptComposer.compose(tools: [])
        #expect(prompt.contains("Rune Weaver"))
        #expect(prompt.contains("memories.recall"))
        #expect(prompt.contains("memories.store"))
        #expect(prompt.contains("Current date: " + SystemPromptComposer.currentDateString()))
    }

    @Test
    func `Current date parameter overrides calendar date and alters rendered prompt`() {
        let tools: [any Tool] = [ComposerReadStub()]
        let promptA = SystemPromptComposer.compose(tools: tools, supportsVision: true, currentDate: "2026-09-18")
        let promptB = SystemPromptComposer.compose(tools: tools, supportsVision: true, currentDate: "2026-09-19")
        #expect(promptA.contains("Current date: 2026-09-18"))
        #expect(promptB.contains("Current date: 2026-09-19"))
        #expect(promptA != promptB)
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
    func `Prompt byte audit measures total bytes without tool schema text`() {
        let tools: [any Tool] = [ComposerReadStub(), ComposerWriteStub()]
        let audit = SystemPromptComposer.byteAudit(tools: tools)
        #expect(audit.totalBytes == SystemPromptComposer.compose(tools: tools).utf8.count)
        #expect(audit.perTool.isEmpty)
    }

    @Test
    func `Scheduled prompt carries scheduled guidance and canonical memory guidance`() {
        let tools: [any Tool] = [ComposerReadStub(), ComposerWriteStub()]
        let scheduled = SystemPromptComposer.composeScheduled(tools: tools, supportsVision: true)
        #expect(!scheduled.contains("Available tools:"))
        #expect(!scheduled.contains("stub.read"))
        #expect(scheduled.contains("Scheduled task guidance:"))
        #expect(scheduled.contains("Rune Weaver"))
        #expect(scheduled.contains("memories.store"))
        #expect(scheduled.contains("memories.recall"))
    }

    @Test
    func `Freshness guardrail is present in both chat and scheduled prompts`() {
        let tools: [any Tool] = [ComposerReadStub()]
        let prompt = SystemPromptComposer.compose(tools: tools, supportsVision: true, currentDate: "2026-09-19")
        #expect(prompt.contains("current as of last night"))
        #expect(prompt.lowercased().contains("prefer live"))
        #expect(prompt.contains("Current date: 2026-09-19"))

        let scheduled = SystemPromptComposer.composeScheduled(tools: tools, supportsVision: true, currentDate: "2026-09-19")
        #expect(scheduled.contains("current as of last night"))
        #expect(scheduled.contains("Current date: 2026-09-19"))
        #expect(scheduled.contains("Scheduled task guidance:"))
    }

    @Test
    func `Entity-plus-time ruling travels verbatim in both chat and scheduled prompts`() {
        let tools: [any Tool] = [ComposerReadStub()]
        let ruling = "For entity-plus-time questions such as next sessions or upcoming deadlines, "
            + "live calendar.search and reminders.search results are decisive; "
            + "do not keep searching after they answer."

        let prompt = SystemPromptComposer.compose(tools: tools, supportsVision: true, currentDate: "2026-09-19")
        #expect(prompt.contains(ruling))

        let scheduled = SystemPromptComposer.composeScheduled(tools: tools, supportsVision: true, currentDate: "2026-09-19")
        #expect(scheduled.contains(ruling))
    }

    @Test
    func `Vision schema filter strips screenshot options when vision is disabled`() {
        let rawWithScreenshot = """
        {
          "type": "object",
          "properties": {
            "url": {"type": "string"},
            "includeScreenshot": {"type": "boolean"},
            "screenshot": {"type": "boolean"}
          },
          "required": ["url"]
        }
        """
        let stripped = SystemPromptComposer.strippedNavigateSchema(JSONSchema(rawValue: rawWithScreenshot))
        #expect(!stripped.rawValue.contains("includeScreenshot"))
        #expect(!stripped.rawValue.contains("screenshot"))
        #expect(stripped.rawValue.contains("url"))
    }

    @Test
    func `Recall plus starter pack slot order keeps lead system first`() {
        let tools: [any Tool] = [ComposerReadStub()]
        let prompt = SystemPromptComposer.compose(tools: tools)
        let system = Message(role: .system, content: prompt)
        let user1 = Message(role: .user, content: "Hi")
        let assistant1 = Message(role: .assistant, content: "Hello!")
        let user2 = Message(role: .user, content: "What do I like?")
        let history = [system, user1, assistant1, user2]
        let recall = Message(role: .system, content: "Relevant memories (use for context; do not mention unless relevant):\n[profile] tea")
        guard let starter = RecallStarterPack.build(
            profile: UserProfile(preferences: [Preference(key: "name", value: "Ada")]),
            indexAsOf: nil,
            goalLine: nil,
            budgets: RecallBudgets()
        ) else {
            Issue.record("Starter pack should inject for a named profile with a disabled index")
            return
        }
        let spliced = Orchestrator.stableHistoryWithRecallAndStarter(history, recall: recall, starterPack: starter)
        #expect(spliced.count == 6)
        #expect(spliced[0] == system)
        #expect(spliced[0].content == prompt)
        #expect(spliced[1] == user1)
        #expect(spliced[2] == assistant1)
        #expect(spliced[3] == recall)
        #expect(spliced[4] == starter)
        #expect(spliced[5] == user2)
        #expect(starter.content.contains("Profile: Ada"))
        #expect(starter.content.contains("Index as of: disabled"))
    }
}

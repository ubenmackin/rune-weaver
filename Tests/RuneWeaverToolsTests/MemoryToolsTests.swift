// Rune Weaver Tools Tests — Long-term memory tool plugin tests.

import Foundation
@testable import RuneWeaverCore
@testable import RuneWeaverTools
import Testing

@Suite("Memory Tools")
struct MemoryToolsTests {
    @Test
    func `Remember args accept text aliases and optional category`() throws {
        let direct = try JSONDecoder().decode(RememberFactArgs.self, from: Data(#"{"text":"my dog is named Biscuit"}"#.utf8))
        #expect(direct.text == "my dog is named Biscuit")
        #expect(direct.category == nil)
        let factAlias = try JSONDecoder().decode(RememberFactArgs.self, from: Data(#"{"fact":"my dog is named Biscuit","category":"preference"}"#.utf8))
        #expect(factAlias.text == "my dog is named Biscuit")
        #expect(factAlias.trimmedCategory == "preference")
        let contentAlias = try JSONDecoder().decode(RememberFactArgs.self, from: Data(#"{"content":"my dog is named Biscuit"}"#.utf8))
        #expect(contentAlias.text == "my dog is named Biscuit")
        let blankCategory = try JSONDecoder().decode(RememberFactArgs.self, from: Data(#"{"text":"hello","category":"  "}"#.utf8))
        #expect(blankCategory.trimmedCategory == nil)
    }

    @Test
    func `Recall args clamp limit`() throws {
        let low = try JSONDecoder().decode(RecallMemoriesArgs.self, from: Data(#"{"query":"hi","limit":0}"#.utf8))
        #expect(low.limit == 1)
        let high = try JSONDecoder().decode(RecallMemoriesArgs.self, from: Data(#"{"query":"hi","limit":500}"#.utf8))
        #expect(high.limit == 50)
        let omitted = try JSONDecoder().decode(RecallMemoriesArgs.self, from: Data(#"{"query":"hi"}"#.utf8))
        #expect(omitted.limit == RecallMemoriesArgs.defaultLimit)
    }

    @Test
    func `Memory tools are trusted and registered in order`() throws {
        let (engine, base) = try ToolsTestSupport.makeIsolatedMemoryEngine()
        defer { ToolsTestSupport.cleanupIsolatedEngineBase(base) }
        let tools = MemoryTools.makeTools(engine: engine)
        #expect(tools.count == 2)
        for tool in tools {
            #expect(tool.permissionLevel == .trusted)
        }
        #expect(tools.map(\.name) == ["remember_fact", "recall_memories"])
        #expect(MemoryTools.toolNames == ["remember_fact", "recall_memories"])
    }

    @Test
    func `Remember tool persists profile fact plus vector row`() async throws {
        let (engine, base) = try ToolsTestSupport.makeIsolatedMemoryEngine()
        defer { ToolsTestSupport.cleanupIsolatedEngineBase(base) }
        let capture = ToolsTestSupport.AuditCapture()
        let tool = RememberFactTool(engine: engine, audit: { capture.record($0) })
        let output = try await tool.execute(
            input: ToolInput(toolName: "remember_fact", argumentsJSON: #"{"text":"The lighthouse keeper collects brass compasses","category":"preference"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == false)
        #expect(output.content.contains("lighthouse keeper"))
        let profile = await engine.getUserProfile()
        #expect(profile.facts.contains { $0.content.contains("lighthouse keeper") })
        let facts = await engine.allSemanticFacts()
        #expect(facts.contains { $0.content.contains("lighthouse keeper") })
        let events = capture.captured()
        #expect(events.count == 1)
        #expect(events[0].text.contains("lighthouse keeper"))
        #expect(events[0].category == "preference")
        #expect(!(events[0].factID ?? "").isEmpty)
    }

    @Test
    func `Remember tool defaults source to tool when category omitted`() async throws {
        let (engine, base) = try ToolsTestSupport.makeIsolatedMemoryEngine()
        defer { ToolsTestSupport.cleanupIsolatedEngineBase(base) }
        let tool = RememberFactTool(engine: engine, audit: { _ in })
        let output = try await tool.execute(
            input: ToolInput(toolName: "remember_fact", argumentsJSON: #"{"text":"My gate code is 1234"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == false)
        let profile = await engine.getUserProfile()
        #expect(profile.facts.contains { $0.content.contains("1234") && $0.source == "tool" })
    }

    @Test
    func `Recall tool searches episodic plus profile facts`() async throws {
        let (engine, base) = try ToolsTestSupport.makeIsolatedMemoryEngine()
        defer { ToolsTestSupport.cleanupIsolatedEngineBase(base) }
        try await engine.storeEpisodic(
            content: "Sailed past the lighthouse at dawn with the harbor pilot",
            sessionID: UUID()
        )
        let remember = RememberFactTool(engine: engine, audit: { _ in })
        let stored = try await remember.execute(
            input: ToolInput(toolName: "remember_fact", argumentsJSON: #"{"text":"My favorite lighthouse is the northern brass beacon","category":"preference"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(stored.isError == false)
        let recall = RecallMemoriesTool(engine: engine)
        let output = try await recall.execute(
            input: ToolInput(toolName: "recall_memories", argumentsJSON: #"{"query":"lighthouse brass","limit":10}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == false)
        #expect(output.content.contains("harbor pilot"))
        #expect(output.content.contains("brass beacon"))
    }

    @Test
    func `Store recall round-trips through ToolBus`() async throws {
        let (engine, base) = try ToolsTestSupport.makeIsolatedMemoryEngine()
        defer { ToolsTestSupport.cleanupIsolatedEngineBase(base) }
        let capture = ToolsTestSupport.AuditCapture()
        let bus = ToolBus()
        for tool in MemoryTools.makeTools(engine: engine, audit: { capture.record($0) }) {
            await bus.register(tool: tool)
        }
        let names = await bus.toolNames()
        #expect(Set(names) == Set(["remember_fact", "recall_memories"]))
        let stored = await bus.execute(
            toolCall: ToolInput(toolName: "remember_fact", argumentsJSON: #"{"text":"The lighthouse keeper collects brass compasses"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(stored.isError == false)
        #expect(capture.captured().count == 1)
        let recalled = await bus.execute(
            toolCall: ToolInput(toolName: "recall_memories", argumentsJSON: #"{"query":"lighthouse compasses","limit":5}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(recalled.isError == false)
        #expect(recalled.content.contains("lighthouse keeper"))
    }

    @Test
    func `Memory tools run with a gate and denying handler without prompts`() async throws {
        let (engine, base) = try ToolsTestSupport.makeIsolatedMemoryEngine()
        defer { ToolsTestSupport.cleanupIsolatedEngineBase(base) }
        // Chat configuration: gate attached, denying handler. Trusted
        // memory tools must still succeed without prompting.
        let bus = ToolBus(permissionGate: PermissionGate())
        for tool in MemoryTools.makeTools(engine: engine, audit: { _ in }) {
            await bus.register(tool: tool)
        }
        await bus.setLegacyApprovalHandler { _, _ in false }
        try await engine.storeEpisodic(content: "Sailed past the lighthouse at dawn", sessionID: UUID())
        let remembered = await bus.execute(
            toolCall: ToolInput(toolName: "remember_fact", argumentsJSON: #"{"text":"My favorite lighthouse is brass"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(remembered.isError == false)
        let recalled = await bus.execute(
            toolCall: ToolInput(toolName: "recall_memories", argumentsJSON: #"{"query":"lighthouse","limit":5}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(recalled.isError == false)
        #expect(recalled.content.contains("lighthouse"))
    }

    @Test
    func `Dry run neither stores nor audits`() async throws {
        let (engine, base) = try ToolsTestSupport.makeIsolatedMemoryEngine()
        defer { ToolsTestSupport.cleanupIsolatedEngineBase(base) }
        let capture = ToolsTestSupport.AuditCapture()
        let tool = RememberFactTool(engine: engine, audit: { capture.record($0) })
        let output = try await tool.execute(
            input: ToolInput(toolName: "remember_fact", argumentsJSON: #"{"text":"The lighthouse keeper collects brass compasses"}"#),
            context: ToolContext(conversationID: UUID(), dryRun: true)
        )
        #expect(output.isError == false)
        #expect(capture.captured().isEmpty)
        let profile = await engine.getUserProfile()
        #expect(profile.facts.isEmpty)
        let facts = await engine.allSemanticFacts()
        #expect(facts.isEmpty)
    }

    @Test
    func `Malformed arguments fail cleanly`() async throws {
        let (engine, base) = try ToolsTestSupport.makeIsolatedMemoryEngine()
        defer { ToolsTestSupport.cleanupIsolatedEngineBase(base) }
        let capture = ToolsTestSupport.AuditCapture()
        let remember = RememberFactTool(engine: engine, audit: { capture.record($0) })
        let badShape = try await remember.execute(
            input: ToolInput(toolName: "remember_fact", argumentsJSON: #"{"category":"preference"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(badShape.isError == true)
        let emptyText = try await remember.execute(
            input: ToolInput(toolName: "remember_fact", argumentsJSON: #"{"text":"   "}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(emptyText.isError == true)
        let punctuationOnly = try await remember.execute(
            input: ToolInput(toolName: "remember_fact", argumentsJSON: #"{"text":"...!!!"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(punctuationOnly.isError == true)
        #expect(capture.captured().isEmpty)
        let recall = RecallMemoriesTool(engine: engine)
        let badRecall = try await recall.execute(
            input: ToolInput(toolName: "recall_memories", argumentsJSON: "not-json"),
            context: ToolContext(conversationID: UUID())
        )
        #expect(badRecall.isError == true)
        let emptyQuery = try await recall.execute(
            input: ToolInput(toolName: "recall_memories", argumentsJSON: #"{"query":"  "}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(emptyQuery.isError == true)
    }

    @Test
    func `Recall envelope round-trips hits`() throws {
        let envelope = RecallMemoriesEnvelope(
            query: "lighthouse",
            memories: [MemoryHit(content: "The lighthouse keeper collects brass compasses", score: 0.9, source: "profile", metadata: ["id": "abc"])]
        )
        let content = try MemoryToolEncoding.encodeRecallEnvelope(envelope)
        #expect(content.contains("lighthouse keeper"))
        let decoded = try JSONDecoder().decode(RecallMemoriesEnvelope.self, from: Data(content.utf8))
        #expect(decoded == envelope)
    }
}

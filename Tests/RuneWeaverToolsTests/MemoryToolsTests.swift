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
    func `Memory tools register in order with correct permission levels`() throws {
        let (engine, base) = try ToolsTestSupport.makeIsolatedMemoryEngine()
        defer { ToolsTestSupport.cleanupIsolatedEngineBase(base) }
        let tools = MemoryTools.makeTools(engine: engine)
        #expect(tools.count == 3)
        #expect(tools.map(\.name) == ["memories.store", "memories.recall", "memories.remove"])
        #expect(tools[0].permissionLevel == .trusted)
        #expect(tools[1].permissionLevel == .trusted)
        #expect(tools[2].permissionLevel == .requiresApproval)
        #expect(MemoryTools.toolNames == ["memories.store", "memories.recall", "memories.remove"])
    }

    @Test
    func `Remember tool persists profile fact plus vector row`() async throws {
        let (engine, base) = try ToolsTestSupport.makeIsolatedMemoryEngine()
        defer { ToolsTestSupport.cleanupIsolatedEngineBase(base) }
        let capture = ToolsTestSupport.AuditCapture()
        let tool = RememberFactTool(engine: engine, audit: { capture.record($0) })
        let output = try await tool.execute(
            input: ToolInput(toolName: "memories.store", argumentsJSON: #"{"text":"The lighthouse keeper collects brass compasses","category":"preference"}"#),
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
            input: ToolInput(toolName: "memories.store", argumentsJSON: #"{"text":"My gate code is 1234"}"#),
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
            input: ToolInput(toolName: "memories.store", argumentsJSON: #"{"text":"My favorite lighthouse is the northern brass beacon","category":"preference"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(stored.isError == false)
        let recall = RecallMemoriesTool(engine: engine)
        let output = try await recall.execute(
            input: ToolInput(toolName: "memories.recall", argumentsJSON: #"{"query":"lighthouse brass","limit":10}"#),
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
        await MemoryTools.register(on: bus, engine: engine, audit: { capture.record($0) })
        let names = await bus.toolNames()
        #expect(Set(names) == Set(["memories.store", "memories.recall", "memories.remove"]))
        // Execute via primary names
        let stored = await bus.execute(
            toolCall: ToolInput(toolName: "memories.store", argumentsJSON: #"{"text":"The lighthouse keeper collects brass compasses"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(stored.isError == false)
        #expect(capture.captured().count == 1)
        let recalled = await bus.execute(
            toolCall: ToolInput(toolName: "memories.recall", argumentsJSON: #"{"query":"lighthouse compasses","limit":5}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(recalled.isError == false)
        #expect(recalled.content.contains("lighthouse keeper"))
    }

    @Test
    func `Remove tool deletes by exact id`() async throws {
        let (engine, base) = try ToolsTestSupport.makeIsolatedMemoryEngine()
        defer { ToolsTestSupport.cleanupIsolatedEngineBase(base) }
        let capture = ToolsTestSupport.AuditCapture()
        let store = RememberFactTool(engine: engine, audit: { _ in })
        let stored = try await store.execute(
            input: ToolInput(toolName: "memories.store", argumentsJSON: #"{"text":"The lighthouse keeper collects brass compasses"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(stored.isError == false)
        let storedID = try #require(await engine.getUserProfile().facts.first?.id)
        let remove = RemoveFactTool(engine: engine, audit: { capture.record($0) })
        let output = try await remove.execute(
            input: ToolInput(toolName: "memories.remove", argumentsJSON: "{\"id\":\"\(storedID.uuidString)\"}"),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == false)
        let decoded = try JSONDecoder().decode(RemoveFactEnvelope.self, from: Data(output.content.utf8))
        #expect(decoded.removed == true)
        #expect(decoded.id == storedID.uuidString)
        let profile = await engine.getUserProfile()
        #expect(!profile.facts.contains { $0.id == storedID })
        let facts = await engine.allSemanticFacts()
        #expect(!facts.contains { $0.id == storedID })
        let events = capture.captured()
        #expect(events.count == 1)
        #expect(events[0].toolName == "memories.remove")
    }

    @Test
    func `Remove unknown id succeeds as no-op with removed:false`() async throws {
        let (engine, base) = try ToolsTestSupport.makeIsolatedMemoryEngine()
        defer { ToolsTestSupport.cleanupIsolatedEngineBase(base) }
        let capture = ToolsTestSupport.AuditCapture()
        let store = RememberFactTool(engine: engine, audit: { _ in })
        let stored = try await store.execute(
            input: ToolInput(toolName: "memories.store", argumentsJSON: #"{"text":"The lighthouse keeper collects brass compasses"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(stored.isError == false)
        let snapshotBefore = await engine.getUserProfile()
        let profileBefore = snapshotBefore.facts.count
        let vectorBefore = await engine.allSemanticFacts().count
        let unknown = UUID()
        #expect(!snapshotBefore.facts.contains { $0.id == unknown })
        let remove = RemoveFactTool(engine: engine, audit: { capture.record($0) })
        let output = try await remove.execute(
            input: ToolInput(toolName: "memories.remove", argumentsJSON: "{\"id\":\"\(unknown.uuidString)\"}"),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == false)
        let decoded = try JSONDecoder().decode(RemoveFactEnvelope.self, from: Data(output.content.utf8))
        #expect(decoded.removed == false)
        #expect(decoded.id == unknown.uuidString)
        let snapshotAfter = await engine.getUserProfile()
        #expect(snapshotAfter.facts.count == profileBefore)
        #expect(snapshotAfter.lastUpdated == snapshotBefore.lastUpdated)
        #expect(await engine.allSemanticFacts().count == vectorBefore)
        #expect(capture.captured().isEmpty)
    }

    @Test
    func `Remove tool rejects malformed ids`() async throws {
        let (engine, base) = try ToolsTestSupport.makeIsolatedMemoryEngine()
        defer { ToolsTestSupport.cleanupIsolatedEngineBase(base) }
        let capture = ToolsTestSupport.AuditCapture()
        let store = RememberFactTool(engine: engine, audit: { _ in })
        let stored = try await store.execute(
            input: ToolInput(toolName: "memories.store", argumentsJSON: #"{"text":"The lighthouse keeper collects brass compasses"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(stored.isError == false)
        let remove = RemoveFactTool(engine: engine, audit: { capture.record($0) })
        let blank = try await remove.execute(
            input: ToolInput(toolName: "memories.remove", argumentsJSON: #"{"id":"   "}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(blank.isError == true)
        let nonUUID = try await remove.execute(
            input: ToolInput(toolName: "memories.remove", argumentsJSON: #"{"id":"not-a-uuid"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(nonUUID.isError == true)
        let oversized = try await remove.execute(
            input: ToolInput(toolName: "memories.remove", argumentsJSON: "{\"id\":\"\(String(repeating: "a", count: 300))\"}"),
            context: ToolContext(conversationID: UUID())
        )
        #expect(oversized.isError == true)
        #expect(capture.captured().isEmpty)
        let profile = await engine.getUserProfile()
        #expect(profile.facts.count == 1)
        let facts = await engine.allSemanticFacts()
        #expect(facts.count == 1)
    }

    @Test
    func `Remove dry run mutates nothing`() async throws {
        let (engine, base) = try ToolsTestSupport.makeIsolatedMemoryEngine()
        defer { ToolsTestSupport.cleanupIsolatedEngineBase(base) }
        let capture = ToolsTestSupport.AuditCapture()
        let store = RememberFactTool(engine: engine, audit: { _ in })
        let stored = try await store.execute(
            input: ToolInput(toolName: "memories.store", argumentsJSON: #"{"text":"The lighthouse keeper collects brass compasses"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(stored.isError == false)
        let storedID = try #require(await engine.getUserProfile().facts.first?.id)
        let remove = RemoveFactTool(engine: engine, audit: { capture.record($0) })
        let output = try await remove.execute(
            input: ToolInput(toolName: "memories.remove", argumentsJSON: "{\"id\":\"\(storedID.uuidString)\"}"),
            context: ToolContext(conversationID: UUID(), dryRun: true)
        )
        #expect(output.isError == false)
        let profile = await engine.getUserProfile()
        #expect(profile.facts.contains { $0.id == storedID })
        let facts = await engine.allSemanticFacts()
        #expect(facts.contains { $0.id == storedID })
        #expect(capture.captured().isEmpty)
    }

    @Test
    func `Memory tools run with a gate and denying handler without prompts`() async throws {
        let (engine, base) = try ToolsTestSupport.makeIsolatedMemoryEngine()
        defer { ToolsTestSupport.cleanupIsolatedEngineBase(base) }
        // Chat configuration: gate attached, denying handler. Trusted
        // memory tools must still succeed without prompting.
        let bus = ToolBus(permissionGate: PermissionGate())
        await MemoryTools.register(on: bus, engine: engine, audit: { _ in })
        await bus.setApprovalHandler { _, _, _ in false }
        try await engine.storeEpisodic(content: "Sailed past the lighthouse at dawn", sessionID: UUID())
        let remembered = await bus.execute(
            toolCall: ToolInput(toolName: "memories.store", argumentsJSON: #"{"text":"My favorite lighthouse is brass"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(remembered.isError == false)
        let recalled = await bus.execute(
            toolCall: ToolInput(toolName: "memories.recall", argumentsJSON: #"{"query":"lighthouse","limit":5}"#),
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
            input: ToolInput(toolName: "memories.store", argumentsJSON: #"{"text":"The lighthouse keeper collects brass compasses"}"#),
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
            input: ToolInput(toolName: "memories.store", argumentsJSON: #"{"category":"preference"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(badShape.isError == true)
        let emptyText = try await remember.execute(
            input: ToolInput(toolName: "memories.store", argumentsJSON: #"{"text":"   "}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(emptyText.isError == true)
        let punctuationOnly = try await remember.execute(
            input: ToolInput(toolName: "memories.store", argumentsJSON: #"{"text":"...!!!"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(punctuationOnly.isError == true)
        #expect(capture.captured().isEmpty)
        // Run bookkeeping is framework-owned, so the trusted tool refuses the
        // reserved marker shape instead of forging a scheduler run cursor.
        let forgedCursor = try await remember.execute(
            input: ToolInput(
                toolName: "memories.store",
                argumentsJSON: #"{"text":"email report last run: 2999-01-01T00:00:00Z"}"#
            ),
            context: ToolContext(conversationID: UUID())
        )
        #expect(forgedCursor.isError == true)
        #expect(forgedCursor.content.contains("run bookkeeping"))
        let spelledMarker = try await remember.execute(
            input: ToolInput(
                toolName: "memories.store",
                argumentsJSON: #"{"text":"Email-Report-Last-Run: 2999-01-01T00:00:00Z"}"#
            ),
            context: ToolContext(conversationID: UUID())
        )
        #expect(spelledMarker.isError == true)
        #expect(capture.captured().isEmpty)
        let profile = await engine.getUserProfile()
        #expect(profile.facts.isEmpty)
        let facts = await engine.allSemanticFacts()
        #expect(facts.isEmpty)
        let recall = RecallMemoriesTool(engine: engine)
        let badRecall = try await recall.execute(
            input: ToolInput(toolName: "memories.recall", argumentsJSON: "not-json"),
            context: ToolContext(conversationID: UUID())
        )
        #expect(badRecall.isError == true)
        let emptyQuery = try await recall.execute(
            input: ToolInput(toolName: "memories.recall", argumentsJSON: #"{"query":"  "}"#),
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

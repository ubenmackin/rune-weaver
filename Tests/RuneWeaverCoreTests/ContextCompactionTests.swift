// Rune Weaver Tests — Context compaction and token budget management.

import Foundation
@testable import RuneWeaverCore
import Testing

@Suite("Context Compaction")
struct ContextCompactionTests {
    @Test
    func `Engine config defaults compaction threshold to 80 and validates range`() throws {
        var config = RuneWeaverConfig()
        config.llm.providers["mlx"] = ProviderConfig()
        #expect(config.engine.compactionThresholdPercent == 80)

        // Valid range 10...100
        config.engine.compactionThresholdPercent = 50
        #expect(throws: Never.self) {
            try config.validate()
        }

        // Below 10 throws validation error
        config.engine.compactionThresholdPercent = 5
        #expect(throws: ConfigError.self) {
            try config.validate()
        }

        // Above 100 throws validation error
        config.engine.compactionThresholdPercent = 105
        #expect(throws: ConfigError.self) {
            try config.validate()
        }
    }

    @Test
    func `TOML decodes compaction_threshold_percent under engine`() throws {
        let toml = """
        [engine]
        name = "Test Engine"
        compaction_threshold_percent = 75
        """
        let root = try TOMLParser.parse(toml)
        let config = try RuneWeaverConfig(decoding: root)
        #expect(config.engine.compactionThresholdPercent == 75)
    }

    @Test
    func `Engine compaction threshold survives save and reload`() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("compaction_threshold_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // A non-default threshold must round-trip through TOML so dashboard
        // edits persist instead of silently reverting to the default on next load.
        let fileURL = tempDir.appendingPathComponent("config.toml")
        var config = RuneWeaverConfig.default
        config.engine.compactionThresholdPercent = 75
        try config.save(to: fileURL)

        let reloaded = try RuneWeaverConfig.load(from: fileURL)
        #expect(reloaded.engine.compactionThresholdPercent == 75)
    }

    @Test
    func `ConversationManager leaves history intact when within budget`() async {
        let manager = ConversationManager()
        let sessionID = UUID()
        await manager.append(Message(role: .user, content: "Short message"), to: sessionID)
        await manager.append(Message(role: .assistant, content: "Short reply"), to: sessionID)

        let compacted = await manager.compactHistoryIfNeeded(
            for: sessionID,
            contextLength: 4000,
            thresholdPercent: 80
        )
        #expect(!compacted)

        let history = await manager.history(for: sessionID)
        #expect(history.count == 2)
        #expect(history[0].content == "Short message")
        #expect(history[1].content == "Short reply")
    }

    @Test
    func `ConversationManager prunes oversized older tool outputs in Phase 1`() async {
        let manager = ConversationManager()
        let sessionID = UUID()

        // Turn 1: User prompt
        await manager.append(Message(role: .user, content: "Fetch document"), to: sessionID)

        // Turn 1: Massive tool output (> 1000 chars)
        let largeOutput = String(repeating: "abcdefghij", count: 150) // 1500 chars (~375 tokens)
        await manager.append(Message(role: .tool, content: largeOutput, toolCallID: "call-1"), to: sessionID)

        // Turn 1: Assistant summary
        await manager.append(Message(role: .assistant, content: "Got it"), to: sessionID)

        // Turn 2: Recent user prompt & tool output (safe trailing messages)
        await manager.append(Message(role: .user, content: "Next step"), to: sessionID)
        await manager.append(Message(role: .assistant, content: "Working..."), to: sessionID)

        // Total chars ~1600 (~400 tokens). Set contextLength to 400 with 50% threshold => maxAllowedTokens = 200.
        let compacted = await manager.compactHistoryIfNeeded(
            for: sessionID,
            contextLength: 400,
            thresholdPercent: 50
        )
        #expect(compacted)

        let history = await manager.history(for: sessionID)
        // Check that older tool message was pruned
        guard let toolMsg = history.first(where: { $0.role == .tool }) else {
            Issue.record("Expected tool message")
            return
        }
        #expect(toolMsg.content.contains("[Output truncated for context budget]"))
        #expect(toolMsg.content.count < 400)
    }

    @Test
    func `ConversationManager evicts and summarizes oldest turns in Phase 2`() async {
        let manager = ConversationManager()
        let sessionID = UUID()

        // Multiple turns that exceed budget even without oversized tool outputs
        for i in 1 ... 10 {
            await manager.append(Message(role: .user, content: "Turn \(i) user request with some detailed context text."), to: sessionID)
            await manager.append(Message(role: .assistant, content: "Turn \(i) assistant response with explanations."), to: sessionID)
        }

        // With small context length, Phase 2 evicts oldest turns into summary
        let compacted = await manager.compactHistoryIfNeeded(
            for: sessionID,
            contextLength: 200,
            thresholdPercent: 50
        )
        #expect(compacted)

        let history = await manager.history(for: sessionID)
        // Summary prefix message should now exist
        #expect(history.contains { $0.role == .system && $0.content.contains(Message.rollingSummaryPrefix) })
        // Recent turns should still be in history
        #expect(history.contains { $0.role == .user && $0.content.contains("Turn 10") })
    }
}

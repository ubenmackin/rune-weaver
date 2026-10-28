// Rune Weaver Tests — ConversationManager eviction invariants across summarize and compaction.

import Foundation
@testable import RuneWeaverCore
import Testing

@Suite("Conversation Manager Eviction")
struct ConversationManagerTests {
    @Test
    func `Summarize strips orphan tool rows when the keep boundary splits a call from its result`() async {
        let manager = ConversationManager()
        let sessionID = UUID()

        await manager.append(Message(role: .system, content: "You are helpful"), to: sessionID)
        await manager.append(Message(role: .user, content: "Inspect the ledger"), to: sessionID)
        await manager.append(Message(role: .assistant, content: "Calling tool"), to: sessionID)
        await manager.append(Message(role: .tool, content: "Result A", toolCallID: "call-1"), to: sessionID)
        await manager.append(Message(role: .user, content: "Latest user prompt"), to: sessionID)
        await manager.append(Message(role: .assistant, content: "Latest reply"), to: sessionID)

        // The keep boundary (4) falls between the assistant tool call and its
        // result, which would otherwise leave the orphan .tool row leading history.
        let summary = await manager.summarize(sessionID: sessionID, keeping: 4)

        // The stranded result is evicted with the call, so it still reaches the rolling summary.
        #expect(summary?.contains("Result A") == true)

        let history = await manager.history(for: sessionID)
        // Rolling summary row, preserved system prompt, then turns: no orphan .tool row.
        #expect(history.map(\.role) == [.system, .system, .user, .assistant])
        #expect(history.first?.content.contains("Result A") == true)
    }

    @Test
    func `Compaction Phase 2 strips orphan tool rows when eviction splits a call from its result`() async {
        let manager = ConversationManager()
        let sessionID = UUID()

        // Estimated 201 tokens against a 100-token budget: evicting the user turn (100)
        // and the assistant call (1) lands exactly on budget, stranding its .tool
        // result at the head of the kept history.
        await manager.append(Message(role: .user, content: String(repeating: "u", count: 400)), to: sessionID)
        await manager.append(Message(role: .assistant, content: "call"), to: sessionID)
        await manager.append(Message(role: .tool, content: "Result A", toolCallID: "call-1"), to: sessionID)
        await manager.append(Message(role: .user, content: String(repeating: "v", count: 300)), to: sessionID)
        await manager.append(Message(role: .assistant, content: String(repeating: "w", count: 92)), to: sessionID)

        let compacted = await manager.compactHistoryIfNeeded(
            for: sessionID,
            contextLength: 400,
            thresholdPercent: 25
        )
        #expect(compacted)

        let history = await manager.history(for: sessionID)
        // The stranded result is summarized with its call, and kept history starts non-tool.
        #expect(history.first?.content.contains("Result A") == true)
        #expect(history.map(\.role) == [.system, .user, .assistant])
    }
}

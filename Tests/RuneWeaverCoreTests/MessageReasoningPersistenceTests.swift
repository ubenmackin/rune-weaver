// Rune Weaver Core Tests — Message reasoning persistence and migration tests.

import Foundation
@testable import RuneWeaverCore
import Testing
#if canImport(SQLite3)
    import SQLite3
#endif

@Suite("Message Reasoning Persistence")
struct MessageReasoningPersistenceTests {
    private func temporaryDBPath() -> (base: URL, dbPath: String) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("message-reasoning-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return (base, base.appendingPathComponent("episodes.db").path)
    }

    @Test
    func `Message reasoning persists and reloads cycle`() async {
        let (base, dbPath) = temporaryDBPath()
        defer { try? FileManager.default.removeItem(at: base) }

        let manager = ConversationManager(episodesDBPath: dbPath)
        let sessionID = UUID()
        await manager.ensureSession(id: sessionID, title: "Reasoning Test")
        let note = Message(
            role: .assistant,
            content: "Calculated response",
            reasoning: "Step 1: Analyzed inputs. Step 2: Derived result."
        )
        let appended = await manager.append(note, to: sessionID)
        #expect(appended.reasoning == "Step 1: Analyzed inputs. Step 2: Derived result.")

        let reloaded = await manager.session(id: sessionID)
        #expect(reloaded != nil)
        let assistantMsg = reloaded?.messages.first { $0.role == Message.Role.assistant }
        #expect(assistantMsg?.content == "Calculated response")
        #expect(assistantMsg?.reasoning == "Step 1: Analyzed inputs. Step 2: Derived result.")
    }
}

// Rune Weaver Core Tests — Message exitCode persistence and migration tests.

import Foundation
@testable import RuneWeaverCore
import Testing
#if canImport(SQLite3)
    import SQLite3
#endif

@Suite("Message Exit Code Persistence")
struct MessageExitCodePersistenceTests {
    private func temporaryDBPath() -> (base: URL, dbPath: String) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("message-exitcode-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return (base, base.appendingPathComponent("episodes.db").path)
    }

    @Test
    func `Message exitCode persists and reloads cycle`() async {
        let (base, dbPath) = temporaryDBPath()
        defer { try? FileManager.default.removeItem(at: base) }

        let manager = ConversationManager(episodesDBPath: dbPath)
        let sessionID = UUID()
        await manager.ensureSession(id: sessionID, title: "ExitCode Test")

        let narrated = ToolInput.placeholderContent(for: [
            ToolInput(toolName: "bash.exec", argumentsJSON: "{}", callID: "call_exit2")
        ])
        let assistantMsg = Message(
            role: .assistant,
            content: narrated
        )
        _ = await manager.append(assistantMsg, to: sessionID)

        let toolMsg = Message(
            role: .tool,
            content: "ls: cannot access '/Users': No such file or directory",
            toolCallID: "call_exit2",
            isError: true,
            exitCode: 2
        )
        let appended = await manager.append(toolMsg, to: sessionID)
        #expect(appended.exitCode == 2)

        let reloaded = await manager.session(id: sessionID)
        #expect(reloaded != nil)
        let toolResultMsg = reloaded?.messages.first { $0.toolCallID == "call_exit2" }
        #expect(toolResultMsg?.exitCode == 2)
        #expect(toolResultMsg?.isError == true)

        let toolActionsMap = await manager.toolActionsByMessage(for: sessionID)
        let actions = toolActionsMap.values.flatMap(\.self)
        let matchedResult = actions.first { $0.callID == "call_exit2" }?.result
        #expect(matchedResult?.exitCode == 2)
        #expect(matchedResult?.isError == true)
    }
}

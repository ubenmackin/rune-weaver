import Foundation
@testable import RuneWeaverCLI
import Testing

@Suite("Chat History Store")
struct ChatHistoryTests {
    @Test
    func `Default history file lives outside episodic memory`() {
        let url = ChatHistoryStore.defaultHistoryFileURL()
        #expect(url.lastPathComponent == "chat_history")
        #expect(url.path.contains(".runeweaver/history"))
        #expect(!url.path.contains("memory"))
        #expect(!url.path.contains("episodes"))
        #expect(!url.path.contains("vectors"))
    }

    @Test
    func `Record skips empty and whitespace-only prompts`() {
        var store = ChatHistoryStore(fileURL: nil)
        #expect(store.record("") == false)
        #expect(store.record("   ") == false)
        #expect(store.record("\n\t ") == false)
        #expect(store.entries.isEmpty)
    }

    @Test
    func `Record skips consecutive duplicates but keeps non-consecutive repeats`() {
        var store = ChatHistoryStore(fileURL: nil)
        #expect(store.record("hello") == true)
        #expect(store.record("hello") == false)
        #expect(store.record("world") == true)
        #expect(store.record("hello") == true)
        #expect(store.entries == ["hello", "world", "hello"])
    }

    @Test
    func `Record folds embedded newlines to keep one prompt per line`() {
        var store = ChatHistoryStore(fileURL: nil)
        #expect(store.record("first\nsecond") == true)
        #expect(store.entries == ["first second"])
        #expect(store.record("a\r\nb\rc") == true)
        #expect(store.entries.last == "a b c")
    }

    @Test
    func `Record caps entries to maxEntries`() {
        var store = ChatHistoryStore(fileURL: nil, maxEntries: 3)
        #expect(store.record("one") == true)
        #expect(store.record("two") == true)
        #expect(store.record("three") == true)
        #expect(store.record("four") == true)
        #expect(store.entries == ["two", "three", "four"])
    }

    @Test
    func `Init trims oversized starting entries to newest window`() {
        let store = ChatHistoryStore(fileURL: nil, maxEntries: 2, entries: ["a", "b", "c"])
        #expect(store.entries == ["b", "c"])
    }

    @Test
    func `Save and load round-trips across sessions`() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("runeweaver-chat-history-\(UUID().uuidString)")
        let file = dir.appendingPathComponent("chat_history")
        var first = ChatHistoryStore(fileURL: file)
        #expect(first.record("first prompt") == true)
        #expect(first.record("/help") == true)
        #expect(first.record("second prompt") == true)
        try first.save()
        #expect(FileManager.default.fileExists(atPath: file.path))

        var second = ChatHistoryStore(fileURL: file)
        second.load()
        #expect(second.entries == ["first prompt", "/help", "second prompt"])
    }

    @Test
    func `Load keeps newest window when file exceeds maxEntries`() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("runeweaver-chat-history-\(UUID().uuidString)")
        let file = dir.appendingPathComponent("chat_history")
        var writer = ChatHistoryStore(fileURL: file, maxEntries: 10)
        for index in 0 ..< 5 {
            #expect(writer.record("prompt \(index)") == true)
        }
        try writer.save()

        var reader = ChatHistoryStore(fileURL: file, maxEntries: 2)
        reader.load()
        #expect(reader.entries == ["prompt 3", "prompt 4"])
    }

    @Test
    func `Load with missing file keeps existing entries`() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("runeweaver-missing-\(UUID().uuidString)/chat_history")
        var store = ChatHistoryStore(fileURL: missing)
        store.load()
        #expect(store.entries.isEmpty)
    }

    @Test
    func `Load skips empty lines`() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("runeweaver-chat-history-\(UUID().uuidString)")
        let file = dir.appendingPathComponent("chat_history")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "hello\n\n   \nworld\n".write(to: file, atomically: true, encoding: .utf8)

        var store = ChatHistoryStore(fileURL: file)
        store.load()
        #expect(store.entries == ["hello", "world"])
    }
}

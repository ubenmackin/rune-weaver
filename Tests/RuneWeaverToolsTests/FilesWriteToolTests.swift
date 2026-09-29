// Rune Weaver Tools Tests — APFS CoW files.write tool and UnifiedDiffEngine.

import Foundation
@testable import RuneWeaverCore
@testable import RuneWeaverTools
import Testing

private enum WriteTestSupport {
    static func makeBaseAndHome() throws -> (base: URL, home: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("runeweaver-write-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let home = base.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return (base, home)
    }

    static func cleanup(_ base: URL) {
        try? FileManager.default.removeItem(at: base)
    }

    static func write(_ text: String, at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url, options: .atomic)
    }
}

@Suite("UnifiedDiffEngine")
struct UnifiedDiffEngineTests {
    @Test
    func `Identical content yields empty diff`() {
        let text = "Line 1\nLine 2\nLine 3"
        let result = UnifiedDiffEngine.computeDiff(oldText: text, newText: text, filepath: "test.txt")
        #expect(result.diff.isEmpty)
        #expect(result.additions == 0)
        #expect(result.deletions == 0)
    }

    @Test
    func `New file yields all additions from null`() {
        let newText = "Hello\nWorld\n"
        let result = UnifiedDiffEngine.computeDiff(oldText: nil, newText: newText, filepath: "new.txt")
        #expect(result.diff.contains("--- /dev/null"))
        #expect(result.diff.contains("+++ b/new.txt"))
        #expect(result.diff.contains("+Hello"))
        #expect(result.diff.contains("+World"))
        #expect(result.additions == 2)
        #expect(result.deletions == 0)
    }

    @Test
    func `Modification computes correct hunks and stats`() {
        let oldText = "func calculate() {\n    let a = 1\n    let b = 2\n    return a + b\n}"
        let newText = "func calculate() {\n    let a = 10\n    let b = 2\n    let c = 3\n    return a + b + c\n}"
        let result = UnifiedDiffEngine.computeDiff(oldText: oldText, newText: newText, filepath: "math.swift")
        #expect(!result.diff.isEmpty)
        #expect(result.diff.contains("--- a/math.swift"))
        #expect(result.diff.contains("+++ b/math.swift"))
        #expect(result.diff.contains("-    let a = 1"))
        #expect(result.diff.contains("+    let a = 10"))
        #expect(result.diff.contains("+    let c = 3"))
        #expect(result.diff.contains("-    return a + b"))
        #expect(result.diff.contains("+    return a + b + c"))
        #expect(result.additions == 3)
        #expect(result.deletions == 2)
    }
}

@Suite("files.write")
struct FilesWriteToolTests {
    @Test
    func `Default staged mode leaves live file untouched and creates staging clone`() async throws {
        let (base, home) = try WriteTestSupport.makeBaseAndHome()
        defer { WriteTestSupport.cleanup(base) }

        let originalFile = home.appendingPathComponent("document.txt")
        try WriteTestSupport.write("Original Version 1\n", at: originalFile)

        let tool = FilesWriteTool(homeDirectoryURL: home)
        let output = try await tool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(originalFile.path)\",\"content\":\"Updated Version 2\\n\"}"
            ),
            context: ToolContext(conversationID: UUID())
        )

        #expect(output.isError == false)
        let envelope = try JSONDecoder().decode(FilesWriteEnvelope.self, from: Data(output.content.utf8))
        #expect(envelope.status == "staged")
        #expect(envelope.stagingPath?.hasSuffix(".rune_document.txt") == true)
        #expect(envelope.diff.contains("-Original Version 1"))
        #expect(envelope.diff.contains("+Updated Version 2"))
        #expect(envelope.additions == 1)
        #expect(envelope.deletions == 1)

        // Verify live file is COMPLETELY UNTOUCHED
        let liveContent = try String(contentsOf: originalFile, encoding: .utf8)
        #expect(liveContent == "Original Version 1\n")

        // Verify staging file has new content
        let stagingURL = home.appendingPathComponent(".rune_document.txt")
        #expect(FileManager.default.fileExists(atPath: stagingURL.path))
        let stagedContent = try String(contentsOf: stagingURL, encoding: .utf8)
        #expect(stagedContent == "Updated Version 2\n")
    }

    @Test
    func `Staged mode on new file stages to dot rune without creating live file`() async throws {
        let (base, home) = try WriteTestSupport.makeBaseAndHome()
        defer { WriteTestSupport.cleanup(base) }

        let target = home.appendingPathComponent("brand_new.txt")
        let tool = FilesWriteTool(homeDirectoryURL: home)
        let output = try await tool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(target.path)\",\"content\":\"Line 1\\nLine 2\\n\"}"
            ),
            context: ToolContext(conversationID: UUID())
        )

        #expect(output.isError == false)
        let envelope = try JSONDecoder().decode(FilesWriteEnvelope.self, from: Data(output.content.utf8))
        #expect(envelope.status == "staged")
        #expect(envelope.diff.contains("--- /dev/null"))
        #expect(envelope.diff.contains("+Line 1"))

        // Live file must NOT exist
        #expect(!FileManager.default.fileExists(atPath: target.path))

        // Staging file exists
        let stagingURL = home.appendingPathComponent(".rune_brand_new.txt")
        #expect(FileManager.default.fileExists(atPath: stagingURL.path))
    }

    @Test
    func `Live mode overwrites live file and saves backup to dot rune`() async throws {
        let (base, home) = try WriteTestSupport.makeBaseAndHome()
        defer { WriteTestSupport.cleanup(base) }

        let target = home.appendingPathComponent("live_edit.txt")
        try WriteTestSupport.write("Old Live Text\n", at: target)

        let tool = FilesWriteTool(homeDirectoryURL: home)
        let output = try await tool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(target.path)\",\"content\":\"New Live Text\\n\",\"mode\":\"live\"}"
            ),
            context: ToolContext(conversationID: UUID())
        )

        #expect(output.isError == false)
        let envelope = try JSONDecoder().decode(FilesWriteEnvelope.self, from: Data(output.content.utf8))
        #expect(envelope.status == "live")
        // Live backups keep a distinct sibling prefix so the staged inbox
        // never mistakes a backup for a pending edit with an inverted diff.
        #expect(envelope.backupPath?.hasSuffix(".rune_backup_live_edit.txt") == true)

        // Live file must contain new content
        let currentLive = try String(contentsOf: target, encoding: .utf8)
        #expect(currentLive == "New Live Text\n")

        // Staging / backup file must contain old content
        let backupURL = home.appendingPathComponent(".rune_backup_live_edit.txt")
        #expect(FileManager.default.fileExists(atPath: backupURL.path))
        let backupContent = try String(contentsOf: backupURL, encoding: .utf8)
        #expect(backupContent == "Old Live Text\n")
    }

    @Test
    func `Denied path fails closed without touching disk`() async throws {
        let (base, home) = try WriteTestSupport.makeBaseAndHome()
        defer { WriteTestSupport.cleanup(base) }

        let deniedFile = home.appendingPathComponent(".env")
        let tool = FilesWriteTool(homeDirectoryURL: home)
        let output = try await tool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(deniedFile.path)\",\"content\":\"SECRET=123\"}"
            ),
            context: ToolContext(conversationID: UUID())
        )

        #expect(output.isError == true)
        #expect(output.content.contains("Access denied") || output.content.contains("approvalRequired"))

        // Neither .env nor .rune_.env should exist
        #expect(!FileManager.default.fileExists(atPath: deniedFile.path))
        let stagingURL = home.appendingPathComponent(".rune_.env")
        #expect(!FileManager.default.fileExists(atPath: stagingURL.path))
    }

    @Test
    func `Default staged mode records metadata into StagedFilesStore and live mode cleans it up`() async throws {
        let (base, home) = try WriteTestSupport.makeBaseAndHome()
        defer { WriteTestSupport.cleanup(base) }
        let store = StagedFilesStore(dbPath: base.appendingPathComponent("test.db").path)

        let originalFile = home.appendingPathComponent("document.txt")
        try WriteTestSupport.write("Original Version 1\n", at: originalFile)

        let tool = FilesWriteTool(homeDirectoryURL: home, stagedFilesStore: store)
        let output = try await tool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(originalFile.path)\",\"content\":\"Updated Version 2\\n\"}"
            ),
            context: ToolContext(conversationID: UUID())
        )

        #expect(output.isError == false)
        let records = await store.list()
        #expect(records.count == 1)
        #expect(records.first?.path == originalFile.path)

        // Now test live write cleans up the staged record
        let liveOutput = try await tool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(originalFile.path)\",\"content\":\"Live Version 3\\n\",\"mode\":\"live\"}"
            ),
            context: ToolContext(conversationID: UUID())
        )
        #expect(liveOutput.isError == false)
        let recordsAfterLive = await store.list()
        #expect(recordsAfterLive.isEmpty)
        let stagingURL = home.appendingPathComponent(".rune_document.txt")
        #expect(!FileManager.default.fileExists(atPath: stagingURL.path))
    }
}

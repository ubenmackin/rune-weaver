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

/// Records supersede notifications delivered through the write tool's
/// propagation hook so tests can pin exactly when the serving process would
/// broadcast a `file_superseded` frame.
private actor SupersedePathRecorder {
    /// Live paths reported so far, in delivery order.
    private(set) var paths: [String] = []

    /// Appends one reported live path.
    func record(_ path: String) {
        paths.append(path)
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
        let store = StagedFilesStore(dbPath: base.appendingPathComponent("test.db").path)

        let target = home.appendingPathComponent("live_edit.txt")
        try WriteTestSupport.write("Old Live Text\n", at: target)

        let tool = FilesWriteTool(homeDirectoryURL: home, stagedFilesStore: store)
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
    func `Default staged mode records metadata into StagedFilesStore and live mode supersedes it`() async throws {
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

        // Now test live write supersedes the staged review
        let liveOutput = try await tool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(originalFile.path)\",\"content\":\"Live Version 3\\n\",\"mode\":\"live\"}"
            ),
            context: ToolContext(conversationID: UUID())
        )
        #expect(liveOutput.isError == false)
        // The pending inbox stops listing it, but the row survives as a
        // durable terminal supersede.
        let recordsAfterLive = await store.list()
        #expect(recordsAfterLive.isEmpty)
        #expect(await store.state(forPath: originalFile.path) == .superseded)
        let stagingURL = home.appendingPathComponent(".rune_document.txt")
        #expect(!FileManager.default.fileExists(atPath: stagingURL.path))
    }

    @Test
    func `Forced staged setting overrides an explicit live request and names it`() async throws {
        let (base, home) = try WriteTestSupport.makeBaseAndHome()
        defer { WriteTestSupport.cleanup(base) }

        let liveOverrideSentence = " Requested 'live' mode was overridden by the owner setting files.write_mode = 'staged'."

        let originalFile = home.appendingPathComponent("document.txt")
        try WriteTestSupport.write("Original Version 1\n", at: originalFile)
        let stagingURL = home.appendingPathComponent(".rune_document.txt")

        let tool = FilesWriteTool(homeDirectoryURL: home, filesConfig: FilesConfig(writeMode: .staged))

        // The preview branch announces the override without creating the copy.
        let previewOutput = try await tool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(originalFile.path)\",\"content\":\"Updated Version 2\\n\",\"mode\":\"live\"}"
            ),
            context: ToolContext(conversationID: UUID(), dryRun: true)
        )
        #expect(previewOutput.isError == false)
        let preview = try JSONDecoder().decode(FilesWriteEnvelope.self, from: Data(previewOutput.content.utf8))
        #expect(preview.status == "preview")
        #expect(preview.stagingPath?.hasSuffix(".rune_document.txt") == true)
        #expect(preview.message.hasSuffix(liveOverrideSentence))
        #expect(!FileManager.default.fileExists(atPath: stagingURL.path))

        let output = try await tool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(originalFile.path)\",\"content\":\"Updated Version 2\\n\",\"mode\":\"live\"}"
            ),
            context: ToolContext(conversationID: UUID())
        )

        #expect(output.isError == false)
        let envelope = try JSONDecoder().decode(FilesWriteEnvelope.self, from: Data(output.content.utf8))
        #expect(envelope.status == "staged")
        #expect(envelope.stagingPath?.hasSuffix(".rune_document.txt") == true)
        #expect(envelope.message.hasSuffix(liveOverrideSentence))

        // The forced posture wins: the live file stayed untouched and the
        // review copy holds the requested content.
        let liveContent = try String(contentsOf: originalFile, encoding: .utf8)
        #expect(liveContent == "Original Version 1\n")
        #expect(FileManager.default.fileExists(atPath: stagingURL.path))
        let stagedContent = try String(contentsOf: stagingURL, encoding: .utf8)
        #expect(stagedContent == "Updated Version 2\n")
    }

    @Test
    func `Forced staged setting with omitted mode stages without an override note`() async throws {
        let (base, home) = try WriteTestSupport.makeBaseAndHome()
        defer { WriteTestSupport.cleanup(base) }

        let originalFile = home.appendingPathComponent("document.txt")
        try WriteTestSupport.write("Original Version 1\n", at: originalFile)

        let tool = FilesWriteTool(homeDirectoryURL: home, filesConfig: FilesConfig(writeMode: .staged))
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
        // An omitted mode defaults to staged, which agrees with the setting, so
        // the envelope carries the plain staged sentence and nothing more.
        #expect(envelope.message == "Changes staged to .rune_document.txt. Live file is unchanged pending user review.")
        #expect(!envelope.message.contains("overridden"))
    }

    @Test
    func `Forced live setting applies an explicit staged request live and supersedes review`() async throws {
        let (base, home) = try WriteTestSupport.makeBaseAndHome()
        defer { WriteTestSupport.cleanup(base) }
        let store = StagedFilesStore(dbPath: base.appendingPathComponent("test.db").path)

        let originalFile = home.appendingPathComponent("document.txt")
        try WriteTestSupport.write("Original Version 1\n", at: originalFile)

        // Seed a pending staged review through a model-posture tool.
        let modelTool = FilesWriteTool(homeDirectoryURL: home, stagedFilesStore: store)
        let stagedOutput = try await modelTool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(originalFile.path)\",\"content\":\"Staged Version 2\\n\"}"
            ),
            context: ToolContext(conversationID: UUID())
        )
        #expect(stagedOutput.isError == false)
        #expect(await store.state(forPath: originalFile.path) == .pending)

        let liveTool = FilesWriteTool(
            homeDirectoryURL: home,
            filesConfig: FilesConfig(writeMode: .live),
            stagedFilesStore: store
        )
        let output = try await liveTool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(originalFile.path)\",\"content\":\"Live Version 3\\n\",\"mode\":\"staged\"}"
            ),
            context: ToolContext(conversationID: UUID())
        )

        #expect(output.isError == false)
        let envelope = try JSONDecoder().decode(FilesWriteEnvelope.self, from: Data(output.content.utf8))
        #expect(envelope.status == "live")
        #expect(envelope.backupPath?.hasSuffix(".rune_backup_document.txt") == true)
        let stagedOverrideSentence = " Requested 'staged' mode was overridden by the owner setting files.write_mode = 'live'."
        #expect(envelope.message.hasSuffix(stagedOverrideSentence))

        // The forced posture wins: the live file moved forward and the stale
        // staged row plus its sibling were superseded away.
        let liveContent = try String(contentsOf: originalFile, encoding: .utf8)
        #expect(liveContent == "Live Version 3\n")
        let backupURL = home.appendingPathComponent(".rune_backup_document.txt")
        #expect(FileManager.default.fileExists(atPath: backupURL.path))
        let backupContent = try String(contentsOf: backupURL, encoding: .utf8)
        #expect(backupContent == "Original Version 1\n")
        #expect(await store.state(forPath: originalFile.path) == .superseded)
        #expect(await store.list().isEmpty)
        let stagingURL = home.appendingPathComponent(".rune_document.txt")
        #expect(!FileManager.default.fileExists(atPath: stagingURL.path))
    }

    @Test
    func `Forced live setting with omitted mode writes live without an override note`() async throws {
        let (base, home) = try WriteTestSupport.makeBaseAndHome()
        defer { WriteTestSupport.cleanup(base) }
        let store = StagedFilesStore(dbPath: base.appendingPathComponent("test.db").path)

        let target = home.appendingPathComponent("live_edit.txt")
        try WriteTestSupport.write("Old Live Text\n", at: target)

        let tool = FilesWriteTool(homeDirectoryURL: home, filesConfig: FilesConfig(writeMode: .live), stagedFilesStore: store)
        let output = try await tool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(target.path)\",\"content\":\"New Live Text\\n\"}"
            ),
            context: ToolContext(conversationID: UUID())
        )

        #expect(output.isError == false)
        let envelope = try JSONDecoder().decode(FilesWriteEnvelope.self, from: Data(output.content.utf8))
        #expect(envelope.status == "live")
        #expect(envelope.backupPath?.hasSuffix(".rune_backup_live_edit.txt") == true)
        // An omitted mode defaults to staged but was never requested, so the
        // forced live write reports only its own outcome.
        #expect(envelope.message == "Changes applied live to live_edit.txt. Backup saved to .rune_backup_live_edit.txt.")
        #expect(!envelope.message.contains("overridden"))

        let currentLive = try String(contentsOf: target, encoding: .utf8)
        #expect(currentLive == "New Live Text\n")
    }

    @Test
    func `Forced live preview announces the override without touching disk`() async throws {
        let (base, home) = try WriteTestSupport.makeBaseAndHome()
        defer { WriteTestSupport.cleanup(base) }
        let store = StagedFilesStore(dbPath: base.appendingPathComponent("test.db").path)

        let target = home.appendingPathComponent("live_preview.txt")
        try WriteTestSupport.write("Original Version 1\n", at: target)

        let tool = FilesWriteTool(homeDirectoryURL: home, filesConfig: FilesConfig(writeMode: .live), stagedFilesStore: store)
        let output = try await tool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(target.path)\",\"content\":\"Updated Version 2\\n\",\"mode\":\"staged\"}"
            ),
            context: ToolContext(conversationID: UUID(), dryRun: true)
        )

        #expect(output.isError == false)
        let envelope = try JSONDecoder().decode(FilesWriteEnvelope.self, from: Data(output.content.utf8))
        #expect(envelope.status == "preview")
        #expect(envelope.stagingPath == nil)
        #expect(envelope.backupPath?.hasSuffix(".rune_backup_live_preview.txt") == true)
        let stagedOverrideSentence = " Requested 'staged' mode was overridden by the owner setting files.write_mode = 'live'."
        #expect(envelope.message.hasSuffix(stagedOverrideSentence))
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".rune_backup_live_preview.txt").path))
        let liveContent = try String(contentsOf: target, encoding: .utf8)
        #expect(liveContent == "Original Version 1\n")
    }

    @Test
    func `Forced write mode omits the mode selector while model mode retains it`() {
        let modelTool = FilesWriteTool(filesConfig: FilesConfig(writeMode: .model))
        #expect(modelTool.inputSchema.rawValue.contains(#""mode""#))
        #expect(modelTool.description.contains("Defaults to safe 'staged' mode"))

        let stagedTool = FilesWriteTool(filesConfig: FilesConfig(writeMode: .staged))
        #expect(!stagedTool.inputSchema.rawValue.contains(#""mode""#))
        #expect(stagedTool.description.contains("Owner settings force staged mode"))
        #expect(stagedTool.inputSchema.rawValue.contains(#""required":["path","content"]"#))

        let liveTool = FilesWriteTool(filesConfig: FilesConfig(writeMode: .live))
        #expect(!liveTool.inputSchema.rawValue.contains(#""mode""#))
        #expect(liveTool.description.contains("Owner settings force live mode"))
    }

    @Test
    func `Invalid explicit mode still fails closed under model write mode`() async throws {
        let (base, home) = try WriteTestSupport.makeBaseAndHome()
        defer { WriteTestSupport.cleanup(base) }

        let target = home.appendingPathComponent("document.txt")
        try WriteTestSupport.write("Original Version 1\n", at: target)

        let tool = FilesWriteTool(homeDirectoryURL: home, filesConfig: FilesConfig(writeMode: .model))
        let output = try await tool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(target.path)\",\"content\":\"Rewritten\\n\",\"mode\":\"overwrite\"}"
            ),
            context: ToolContext(conversationID: UUID())
        )

        #expect(output.isError == true)
        #expect(output.content.contains("'mode' must be 'staged' or 'live'"))
        let liveContent = try String(contentsOf: target, encoding: .utf8)
        #expect(liveContent == "Original Version 1\n")
        let stagingURL = home.appendingPathComponent(".rune_document.txt")
        #expect(!FileManager.default.fileExists(atPath: stagingURL.path))
    }

    @Test
    func `Forced staged setting accepts and ignores an unrecognized mode value`() async throws {
        let (base, home) = try WriteTestSupport.makeBaseAndHome()
        defer { WriteTestSupport.cleanup(base) }
        let store = StagedFilesStore(dbPath: base.appendingPathComponent("test.db").path)

        let originalFile = home.appendingPathComponent("document.txt")
        try WriteTestSupport.write("Original Version 1\n", at: originalFile)

        // The forced posture owns mode selection, so a stale or garbage value
        // that lost its meaning must neither fail the write nor earn an
        // override sentence: only a value that contradicts the setting does.
        let tool = FilesWriteTool(
            homeDirectoryURL: home,
            filesConfig: FilesConfig(writeMode: .staged),
            stagedFilesStore: store
        )
        let output = try await tool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(originalFile.path)\",\"content\":\"Updated Version 2\\n\",\"mode\":\"overwrite\"}"
            ),
            context: ToolContext(conversationID: UUID())
        )

        #expect(output.isError == false)
        let envelope = try JSONDecoder().decode(FilesWriteEnvelope.self, from: Data(output.content.utf8))
        #expect(envelope.status == "staged")
        #expect(envelope.message == "Changes staged to .rune_document.txt. Live file is unchanged pending user review.")
        let liveContent = try String(contentsOf: originalFile, encoding: .utf8)
        #expect(liveContent == "Original Version 1\n")
        let stagingURL = home.appendingPathComponent(".rune_document.txt")
        #expect(try String(contentsOf: stagingURL, encoding: .utf8) == "Updated Version 2\n")
    }

    @Test
    func `Forced live setting accepts and ignores an unrecognized mode value`() async throws {
        let (base, home) = try WriteTestSupport.makeBaseAndHome()
        defer { WriteTestSupport.cleanup(base) }
        let store = StagedFilesStore(dbPath: base.appendingPathComponent("test.db").path)

        let target = home.appendingPathComponent("live_edit.txt")
        try WriteTestSupport.write("Old Live Text\n", at: target)

        let tool = FilesWriteTool(
            homeDirectoryURL: home,
            filesConfig: FilesConfig(writeMode: .live),
            stagedFilesStore: store
        )
        let output = try await tool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(target.path)\",\"content\":\"New Live Text\\n\",\"mode\":\"overwrite\"}"
            ),
            context: ToolContext(conversationID: UUID())
        )

        #expect(output.isError == false)
        let envelope = try JSONDecoder().decode(FilesWriteEnvelope.self, from: Data(output.content.utf8))
        #expect(envelope.status == "live")
        #expect(envelope.message == "Changes applied live to live_edit.txt. Backup saved to .rune_backup_live_edit.txt.")
        #expect(try String(contentsOf: target, encoding: .utf8) == "New Live Text\n")
        let backupURL = home.appendingPathComponent(".rune_backup_live_edit.txt")
        #expect(try String(contentsOf: backupURL, encoding: .utf8) == "Old Live Text\n")
    }

    @Test
    func `Live write that supersedes a staged review reports it through the propagation hook`() async throws {
        let (base, home) = try WriteTestSupport.makeBaseAndHome()
        defer { WriteTestSupport.cleanup(base) }
        let store = StagedFilesStore(dbPath: base.appendingPathComponent("test.db").path)
        let recorder = SupersedePathRecorder()

        let target = home.appendingPathComponent("document.txt")
        try WriteTestSupport.write("Original Version 1\n", at: target)
        let tool = FilesWriteTool(
            homeDirectoryURL: home,
            stagedFilesStore: store,
            supersededReviewNotifier: { path in await recorder.record(path) }
        )

        // A staged write touches no staged row it could supersede.
        _ = try await tool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(target.path)\",\"content\":\"Staged Version 2\\n\"}"
            ),
            context: ToolContext(conversationID: UUID())
        )
        #expect(await recorder.paths.isEmpty)

        // The live write supersedes the pending row and reports the live path
        // once, after the row reads terminal.
        let liveOutput = try await tool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(target.path)\",\"content\":\"Live Version 3\\n\",\"mode\":\"live\"}"
            ),
            context: ToolContext(conversationID: UUID())
        )
        #expect(liveOutput.isError == false)
        #expect(await recorder.paths == [target.path])
        #expect(await store.state(forPath: target.path) == .superseded)

        // A later write joins the live review without touching a staged row,
        // so it must not report a supersede that never happened.
        _ = try await tool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(target.path)\",\"content\":\"Live Version 4\\n\",\"mode\":\"live\"}"
            ),
            context: ToolContext(conversationID: UUID())
        )
        #expect(await recorder.paths == [target.path])
    }

    // MARK: - Live review rollback lifecycle

    @Test
    func `First live write snapshots the original and starts a pending review`() async throws {
        let (base, home) = try WriteTestSupport.makeBaseAndHome()
        defer { WriteTestSupport.cleanup(base) }
        let store = StagedFilesStore(dbPath: base.appendingPathComponent("test.db").path)

        let target = home.appendingPathComponent("series.txt")
        try WriteTestSupport.write("Original Version 1\n", at: target)

        let tool = FilesWriteTool(homeDirectoryURL: home, stagedFilesStore: store)
        let output = try await tool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(target.path)\",\"content\":\"Version 2\\n\",\"mode\":\"live\"}"
            ),
            context: ToolContext(conversationID: UUID())
        )

        #expect(output.isError == false)
        let envelope = try JSONDecoder().decode(FilesWriteEnvelope.self, from: Data(output.content.utf8))
        #expect(envelope.status == "live")
        #expect(envelope.message == "Changes applied live to series.txt. Backup saved to .rune_backup_series.txt.")
        #expect(envelope.backupPath?.hasSuffix(".rune_backup_series.txt") == true)

        // The snapshot holds the bytes from before the first live write, and
        // the write itself moved the live file forward.
        let backupURL = home.appendingPathComponent(".rune_backup_series.txt")
        #expect(try String(contentsOf: backupURL, encoding: .utf8) == "Original Version 1\n")
        #expect(try String(contentsOf: target, encoding: .utf8) == "Version 2\n")

        let review = try await store.liveReview(forPath: target.path)
        #expect(review?.resolution == nil)
        #expect(review?.backupPath == backupURL.path)
    }

    @Test
    func `Second live write joins the pending review and preserves the rollback copy`() async throws {
        let (base, home) = try WriteTestSupport.makeBaseAndHome()
        defer { WriteTestSupport.cleanup(base) }
        let store = StagedFilesStore(dbPath: base.appendingPathComponent("test.db").path)

        let target = home.appendingPathComponent("series.txt")
        try WriteTestSupport.write("Original Version 1\n", at: target)

        let tool = FilesWriteTool(homeDirectoryURL: home, stagedFilesStore: store)
        _ = try await tool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(target.path)\",\"content\":\"Version 2\\n\",\"mode\":\"live\"}"
            ),
            context: ToolContext(conversationID: UUID())
        )
        let firstReview = try await store.liveReview(forPath: target.path)

        let output = try await tool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(target.path)\",\"content\":\"Version 3\\n\",\"mode\":\"live\"}"
            ),
            context: ToolContext(conversationID: UUID())
        )

        #expect(output.isError == false)
        let envelope = try JSONDecoder().decode(FilesWriteEnvelope.self, from: Data(output.content.utf8))
        #expect(envelope.status == "live")
        #expect(envelope.message == "Changes applied live to series.txt. Existing rollback copy preserved at .rune_backup_series.txt.")
        #expect(envelope.backupPath?.hasSuffix(".rune_backup_series.txt") == true)

        // The copy still holds the pre-series original: joining a review never
        // re-clones the live file, while the live file moved to version 3.
        let backupURL = home.appendingPathComponent(".rune_backup_series.txt")
        #expect(try String(contentsOf: backupURL, encoding: .utf8) == "Original Version 1\n")
        #expect(try String(contentsOf: target, encoding: .utf8) == "Version 3\n")

        // The pending review was not restarted: same copy, same creation time.
        let secondReview = try await store.liveReview(forPath: target.path)
        #expect(secondReview?.resolution == nil)
        #expect(secondReview?.backupPath == firstReview?.backupPath)
        #expect(secondReview?.createdAt == firstReview?.createdAt)
    }

    @Test
    func `New file live write creates no backup and later writes join without one`() async throws {
        let (base, home) = try WriteTestSupport.makeBaseAndHome()
        defer { WriteTestSupport.cleanup(base) }
        let store = StagedFilesStore(dbPath: base.appendingPathComponent("test.db").path)

        let target = home.appendingPathComponent("brand_new.txt")
        let backupURL = home.appendingPathComponent(".rune_backup_brand_new.txt")
        let tool = FilesWriteTool(homeDirectoryURL: home, stagedFilesStore: store)

        let firstOutput = try await tool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(target.path)\",\"content\":\"Line 1\\n\",\"mode\":\"live\"}"
            ),
            context: ToolContext(conversationID: UUID())
        )
        #expect(firstOutput.isError == false)
        let firstEnvelope = try JSONDecoder().decode(FilesWriteEnvelope.self, from: Data(firstOutput.content.utf8))
        #expect(firstEnvelope.status == "live")
        #expect(firstEnvelope.backupPath == nil)
        #expect(firstEnvelope.message == "Changes applied live to brand_new.txt.")
        #expect(!FileManager.default.fileExists(atPath: backupURL.path))

        let firstReview = try await store.liveReview(forPath: target.path)
        #expect(firstReview?.resolution == nil)
        #expect(firstReview?.backupPath == nil)

        let secondOutput = try await tool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(target.path)\",\"content\":\"Line 2\\n\",\"mode\":\"live\"}"
            ),
            context: ToolContext(conversationID: UUID())
        )
        #expect(secondOutput.isError == false)
        let secondEnvelope = try JSONDecoder().decode(FilesWriteEnvelope.self, from: Data(secondOutput.content.utf8))
        #expect(secondEnvelope.backupPath == nil)
        #expect(secondEnvelope.message == "Changes applied live to brand_new.txt.")
        #expect(!FileManager.default.fileExists(atPath: backupURL.path))

        // A new-file review stays pending with no rollback copy, so reverting
        // the series can only delete the created file.
        let secondReview = try await store.liveReview(forPath: target.path)
        #expect(secondReview?.resolution == nil)
        #expect(secondReview?.backupPath == nil)
        #expect(secondReview?.createdAt == firstReview?.createdAt)
        #expect(try String(contentsOf: target, encoding: .utf8) == "Line 2\n")
    }

    @Test
    func `Terminal live review followed by a new write starts a fresh snapshot and pending review`() async throws {
        let (base, home) = try WriteTestSupport.makeBaseAndHome()
        defer { WriteTestSupport.cleanup(base) }
        let store = StagedFilesStore(dbPath: base.appendingPathComponent("test.db").path)

        let target = home.appendingPathComponent("series.txt")
        try WriteTestSupport.write("Original Version 1\n", at: target)
        let tool = FilesWriteTool(homeDirectoryURL: home, stagedFilesStore: store)

        // Two writes in one series: the second joins and leaves the copy at the
        // pre-series original.
        _ = try await tool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(target.path)\",\"content\":\"Version 2\\n\",\"mode\":\"live\"}"
            ),
            context: ToolContext(conversationID: UUID())
        )
        _ = try await tool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(target.path)\",\"content\":\"Version 3\\n\",\"mode\":\"live\"}"
            ),
            context: ToolContext(conversationID: UUID())
        )
        let backupURL = home.appendingPathComponent(".rune_backup_series.txt")
        #expect(try String(contentsOf: backupURL, encoding: .utf8) == "Original Version 1\n")
        #expect(await store.resolveLiveReview(path: target.path, resolution: .accepted) == true)

        // A settled decision consumes the copy, so the normal post-decision
        // state is a terminal row with nothing at the rollback path; the fresh
        // series then snapshots the bytes the decision left behind.
        try LiveFileBackup.removeBackup(at: backupURL)

        let output = try await tool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(target.path)\",\"content\":\"Version 4\\n\",\"mode\":\"live\"}"
            ),
            context: ToolContext(conversationID: UUID())
        )

        #expect(output.isError == false)
        let envelope = try JSONDecoder().decode(FilesWriteEnvelope.self, from: Data(output.content.utf8))
        #expect(envelope.message == "Changes applied live to series.txt. Backup saved to .rune_backup_series.txt.")
        #expect(try String(contentsOf: backupURL, encoding: .utf8) == "Version 3\n")
        #expect(try String(contentsOf: target, encoding: .utf8) == "Version 4\n")

        let review = try await store.liveReview(forPath: target.path)
        #expect(review?.resolution == nil)
        #expect(review?.backupPath == backupURL.path)
    }

    @Test
    func `A settled review's leftover copy is never replaced by a fresh snapshot`() async throws {
        let (base, home) = try WriteTestSupport.makeBaseAndHome()
        defer { WriteTestSupport.cleanup(base) }
        let store = StagedFilesStore(dbPath: base.appendingPathComponent("test.db").path)

        let target = home.appendingPathComponent("series.txt")
        try WriteTestSupport.write("Original Version 1\n", at: target)
        let tool = FilesWriteTool(homeDirectoryURL: home, stagedFilesStore: store)

        _ = try await tool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(target.path)\",\"content\":\"Version 2\\n\",\"mode\":\"live\"}"
            ),
            context: ToolContext(conversationID: UUID())
        )
        _ = try await tool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(target.path)\",\"content\":\"Version 3\\n\",\"mode\":\"live\"}"
            ),
            context: ToolContext(conversationID: UUID())
        )
        let backupURL = home.appendingPathComponent(".rune_backup_series.txt")
        #expect(await store.resolveLiveReview(path: target.path, resolution: .accepted) == true)

        // An entry survives at the rollback path although the series reads terminal (a crash
        // between a decision's copy consumption and its row write, an out-of-band copy, or a peer's
        // in-flight capture).
        let output = try await tool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(target.path)\",\"content\":\"Version 4\\n\",\"mode\":\"live\"}"
            ),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == true)
        #expect(output.content.contains("A rollback copy already exists"))
        #expect(try String(contentsOf: backupURL, encoding: .utf8) == "Original Version 1\n")
        #expect(try String(contentsOf: target, encoding: .utf8) == "Version 3\n")
        let settled = try await store.liveReview(forPath: target.path)
        #expect(settled?.resolution == .accepted)

        // The dry-run mirror carries the same refusal rather than promising a
        // write that disk would reject.
        let previewOutput = try await tool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(target.path)\",\"content\":\"Version 4\\n\",\"mode\":\"live\"}"
            ),
            context: ToolContext(conversationID: UUID(), dryRun: true)
        )
        #expect(previewOutput.isError == true)
        #expect(previewOutput.content.contains("A rollback copy already exists"))
        #expect(try String(contentsOf: backupURL, encoding: .utf8) == "Original Version 1\n")
    }

    @Test
    func `Unreadable review ledger fails the live write closed and previews promise nothing`() async throws {
        let (base, home) = try WriteTestSupport.makeBaseAndHome()
        defer { WriteTestSupport.cleanup(base) }

        // A regular file where the database's parent directory should be makes
        // the SQLite open fail deterministically: no ledger, no live write.
        let blocker = base.appendingPathComponent("not-a-directory")
        try WriteTestSupport.write("blocker", at: blocker)
        let store = StagedFilesStore(dbPath: blocker.appendingPathComponent("test.db").path)

        let target = home.appendingPathComponent("guarded.txt")
        try WriteTestSupport.write("Original Version 1\n", at: target)

        let tool = FilesWriteTool(homeDirectoryURL: home, stagedFilesStore: store)
        let output = try await tool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(target.path)\",\"content\":\"Version 2\\n\",\"mode\":\"live\"}"
            ),
            context: ToolContext(conversationID: UUID())
        )

        #expect(output.isError == true)
        #expect(output.content.contains("Could not read the review ledger; live write refused without a reliable rollback point."))
        #expect(try String(contentsOf: target, encoding: .utf8) == "Original Version 1\n")
        let backupURL = home.appendingPathComponent(".rune_backup_guarded.txt")
        #expect(!FileManager.default.fileExists(atPath: backupURL.path))

        // The dry-run mirror keeps working but stays silent about a rollback
        // copy it cannot promise.
        let previewOutput = try await tool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(target.path)\",\"content\":\"Version 2\\n\",\"mode\":\"live\"}"
            ),
            context: ToolContext(conversationID: UUID(), dryRun: true)
        )
        #expect(previewOutput.isError == false)
        let preview = try JSONDecoder().decode(FilesWriteEnvelope.self, from: Data(previewOutput.content.utf8))
        #expect(preview.status == "preview")
        #expect(preview.backupPath == nil)
        #expect(preview.message == "Dry run: would apply changes live to guarded.txt.")
        #expect(!FileManager.default.fileExists(atPath: backupURL.path))
    }

    @Test
    func `Live preview mirrors a pending review and leaves disk untouched`() async throws {
        let (base, home) = try WriteTestSupport.makeBaseAndHome()
        defer { WriteTestSupport.cleanup(base) }
        let store = StagedFilesStore(dbPath: base.appendingPathComponent("test.db").path)

        let target = home.appendingPathComponent("series.txt")
        try WriteTestSupport.write("Original Version 1\n", at: target)
        let tool = FilesWriteTool(homeDirectoryURL: home, stagedFilesStore: store)

        _ = try await tool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(target.path)\",\"content\":\"Version 2\\n\",\"mode\":\"live\"}"
            ),
            context: ToolContext(conversationID: UUID())
        )

        let previewOutput = try await tool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(target.path)\",\"content\":\"Version 3\\n\",\"mode\":\"live\"}"
            ),
            context: ToolContext(conversationID: UUID(), dryRun: true)
        )
        #expect(previewOutput.isError == false)
        let preview = try JSONDecoder().decode(FilesWriteEnvelope.self, from: Data(previewOutput.content.utf8))
        #expect(preview.status == "preview")
        #expect(preview.backupPath?.hasSuffix(".rune_backup_series.txt") == true)
        #expect(preview.message == "Dry run: would apply changes live to series.txt. Existing rollback copy would be preserved at .rune_backup_series.txt.")

        // The preview changes nothing: the live file and copy still hold the
        // versions the series left behind, and the review stays pending.
        let backupURL = home.appendingPathComponent(".rune_backup_series.txt")
        #expect(try String(contentsOf: target, encoding: .utf8) == "Version 2\n")
        #expect(try String(contentsOf: backupURL, encoding: .utf8) == "Original Version 1\n")
        let pendingPreview = try await store.liveReview(forPath: target.path)
        #expect(pendingPreview?.resolution == nil)
    }

    // MARK: - Reserved review-artifact namespace

    @Test
    func `Write to a backup-named target cannot clobber another file's rollback copy`() async throws {
        let (base, home) = try WriteTestSupport.makeBaseAndHome()
        defer { WriteTestSupport.cleanup(base) }
        let store = StagedFilesStore(dbPath: base.appendingPathComponent("test.db").path)

        // report.txt carries a pending live review whose rollback copy holds
        // the pre-write original.
        let report = home.appendingPathComponent("report.txt")
        try WriteTestSupport.write("Original Report\n", at: report)
        let tool = FilesWriteTool(homeDirectoryURL: home, stagedFilesStore: store)
        let firstOutput = try await tool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(report.path)\",\"content\":\"Edited Report\\n\",\"mode\":\"live\"}"
            ),
            context: ToolContext(conversationID: UUID())
        )
        #expect(firstOutput.isError == false)
        let backupURL = home.appendingPathComponent(".rune_backup_report.txt")
        #expect(try String(contentsOf: backupURL, encoding: .utf8) == "Original Report\n")
        let pendingReview = try await store.liveReview(forPath: report.path)
        #expect(pendingReview?.resolution == nil)

        // backup_report.txt derives the staging sibling .rune_backup_report.txt,
        // which IS that rollback copy, so every posture must refuse instead of
        // overwriting or deleting it.
        let collider = home.appendingPathComponent("backup_report.txt")
        for mode in ["staged", "live"] {
            let output = try await tool.execute(
                input: ToolInput(
                    toolName: "files.write",
                    argumentsJSON: "{\"path\":\"\(collider.path)\",\"content\":\"Clobber\\n\",\"mode\":\"\(mode)\"}"
                ),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == true)
            #expect(output.content.contains("collides with the reserved .rune_backup_<name> rollback namespace"))
        }
        let previewOutput = try await tool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(collider.path)\",\"content\":\"Clobber\\n\",\"mode\":\"live\"}"
            ),
            context: ToolContext(conversationID: UUID(), dryRun: true)
        )
        #expect(previewOutput.isError == true)
        #expect(previewOutput.content.contains("collides with the reserved .rune_backup_<name> rollback namespace"))

        // The rollback copy, the live bytes, and the pending review all
        // survive, and the refused target never came into existence.
        #expect(try String(contentsOf: backupURL, encoding: .utf8) == "Original Report\n")
        #expect(try String(contentsOf: report, encoding: .utf8) == "Edited Report\n")
        let reviewAfter = try await store.liveReview(forPath: report.path)
        #expect(reviewAfter?.resolution == nil)
        #expect(reviewAfter?.backupPath == backupURL.path)
        #expect(!FileManager.default.fileExists(atPath: collider.path))
    }

    @Test
    func `Write to a reserved artifact target cannot supersede another file's staged review`() async throws {
        let (base, home) = try WriteTestSupport.makeBaseAndHome()
        defer { WriteTestSupport.cleanup(base) }
        let store = StagedFilesStore(dbPath: base.appendingPathComponent("test.db").path)

        let document = home.appendingPathComponent("document.txt")
        try WriteTestSupport.write("Original Version 1\n", at: document)
        let tool = FilesWriteTool(homeDirectoryURL: home, stagedFilesStore: store)
        _ = try await tool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(document.path)\",\"content\":\"Staged Version 2\\n\"}"
            ),
            context: ToolContext(conversationID: UUID())
        )
        let stagingURL = home.appendingPathComponent(".rune_document.txt")
        #expect(await store.state(forPath: document.path) == .pending)

        // A live write at the staging artifact path would match the document's pending row through
        // the staging-path lookup and supersede it, so the reserved name must be refused at the tool
        // boundary.
        let reservedTargets = [stagingURL, home.appendingPathComponent(".RUNE_document.txt")]
        for target in reservedTargets {
            let output = try await tool.execute(
                input: ToolInput(
                    toolName: "files.write",
                    argumentsJSON: "{\"path\":\"\(target.path)\",\"content\":\"Clobber\\n\",\"mode\":\"live\"}"
                ),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == true)
            #expect(output.content.contains("is reserved for review artifacts"))
        }

        // The pending row, its staging copy, and the live file all survive.
        #expect(await store.state(forPath: document.path) == .pending)
        #expect(await store.list().count == 1)
        #expect(try String(contentsOf: stagingURL, encoding: .utf8) == "Staged Version 2\n")
        #expect(try String(contentsOf: document, encoding: .utf8) == "Original Version 1\n")
    }

    @Test
    func `Live write refuses a planted directory at the staging sibling instead of deleting it`() async throws {
        let (base, home) = try WriteTestSupport.makeBaseAndHome()
        defer { WriteTestSupport.cleanup(base) }
        let store = StagedFilesStore(dbPath: base.appendingPathComponent("test.db").path)

        let target = home.appendingPathComponent("guarded_live.txt")
        try WriteTestSupport.write("Original Version 1\n", at: target)

        // A directory planted at the reserved sibling name must never be
        // recursed into by the supersede cleanup.
        let stagingURL = home.appendingPathComponent(".rune_guarded_live.txt")
        try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        let sentinel = stagingURL.appendingPathComponent("sentinel.txt")
        try WriteTestSupport.write("Keep me\n", at: sentinel)

        let tool = FilesWriteTool(homeDirectoryURL: home, stagedFilesStore: store)
        let output = try await tool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(target.path)\",\"content\":\"Version 2\\n\",\"mode\":\"live\"}"
            ),
            context: ToolContext(conversationID: UUID())
        )

        #expect(output.isError == true)
        #expect(output.content.contains("is not a regular file"))

        // The refusal leaves every entry untouched: live bytes, the directory,
        // its sentinel, the backup path, and the review ledger.
        #expect(try String(contentsOf: target, encoding: .utf8) == "Original Version 1\n")
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: stagingURL.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "Keep me\n")
        let backupURL = home.appendingPathComponent(".rune_backup_guarded_live.txt")
        #expect(!FileManager.default.fileExists(atPath: backupURL.path))
        let review = try await store.liveReview(forPath: target.path)
        #expect(review == nil)

        // The dry-run mirror carries the same refusal rather than promising a
        // write that disk would reject.
        let previewOutput = try await tool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(target.path)\",\"content\":\"Version 2\\n\",\"mode\":\"live\"}"
            ),
            context: ToolContext(conversationID: UUID(), dryRun: true)
        )
        #expect(previewOutput.isError == true)
        #expect(previewOutput.content.contains("is not a regular file"))
    }

    // MARK: - Preview/disk parity for non-regular entries

    @Test
    func `Fresh-series live preview refuses a non-regular live target exactly like disk`() async throws {
        // A directory planted at the live path is an existing non-regular entry: the snapshot's
        // no-follow source guard refuses it on disk, so the preview must carry the identical refusal
        // instead of promising a live write and a backup that disk would reject.
        let (base, home) = try WriteTestSupport.makeBaseAndHome()
        defer { WriteTestSupport.cleanup(base) }
        let store = StagedFilesStore(dbPath: base.appendingPathComponent("test.db").path)

        let target = home.appendingPathComponent("victim.txt")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let sentinel = target.appendingPathComponent("sentinel.txt")
        try WriteTestSupport.write("Keep me\n", at: sentinel)

        let tool = FilesWriteTool(homeDirectoryURL: home, stagedFilesStore: store)
        let arguments = "{\"path\":\"\(target.path)\",\"content\":\"Attacker Write\\n\",\"mode\":\"live\"}"

        let previewOutput = try await tool.execute(
            input: ToolInput(toolName: "files.write", argumentsJSON: arguments),
            context: ToolContext(conversationID: UUID(), dryRun: true)
        )
        #expect(previewOutput.isError == true)
        #expect(previewOutput.content.contains("the live path is not a regular file"))

        // The disk write refuses on the same shared predicate with the same
        // sentence, so preview and disk can never drift.
        let writeOutput = try await tool.execute(
            input: ToolInput(toolName: "files.write", argumentsJSON: arguments),
            context: ToolContext(conversationID: UUID())
        )
        #expect(writeOutput.isError == true)
        #expect(writeOutput.content == previewOutput.content)

        // The refusal consumed nothing: the directory and its sentinel
        // survive, no rollback copy exists, and no review row was recorded.
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "Keep me\n")
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".rune_backup_victim.txt").path))
        #expect(try await store.liveReview(forPath: target.path) == nil)
    }

    @Test
    func `Staged write and preview refuse a directory planted at the staging sibling`() async throws {
        let (base, home) = try WriteTestSupport.makeBaseAndHome()
        defer { WriteTestSupport.cleanup(base) }
        let store = StagedFilesStore(dbPath: base.appendingPathComponent("test.db").path)

        let target = home.appendingPathComponent("guarded_staged.txt")
        try WriteTestSupport.write("Original Version 1\n", at: target)

        // A directory planted at the reserved sibling name is a non-regular entry that
        // `Data.write(.atomic)` cannot land on; both the staged write and its preview must refuse
        // before any disk mutation instead of surfacing a late write error.
        let stagingURL = home.appendingPathComponent(".rune_guarded_staged.txt")
        try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        let sentinel = stagingURL.appendingPathComponent("sentinel.txt")
        try WriteTestSupport.write("Keep me\n", at: sentinel)

        let tool = FilesWriteTool(homeDirectoryURL: home, stagedFilesStore: store)
        let arguments = "{\"path\":\"\(target.path)\",\"content\":\"Version 2\\n\"}"

        let previewOutput = try await tool.execute(
            input: ToolInput(toolName: "files.write", argumentsJSON: arguments),
            context: ToolContext(conversationID: UUID(), dryRun: true)
        )
        #expect(previewOutput.isError == true)
        #expect(previewOutput.content.contains("is not a regular file"))

        let writeOutput = try await tool.execute(
            input: ToolInput(toolName: "files.write", argumentsJSON: arguments),
            context: ToolContext(conversationID: UUID())
        )
        #expect(writeOutput.isError == true)
        #expect(writeOutput.content == previewOutput.content)

        // Nothing was mutated: the live bytes, the directory, and its sentinel
        // survive, and the refusal never reached either review ledger.
        #expect(try String(contentsOf: target, encoding: .utf8) == "Original Version 1\n")
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: stagingURL.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "Keep me\n")
        #expect(await store.state(forPath: target.path) == nil)
        #expect(try await store.liveReview(forPath: target.path) == nil)
    }

    // MARK: - Atomic review start

    @Test
    func `Fresh-series live write leaves an unexplained rollback copy untouched`() async throws {
        let (base, home) = try WriteTestSupport.makeBaseAndHome()
        defer { WriteTestSupport.cleanup(base) }
        let store = StagedFilesStore(dbPath: base.appendingPathComponent("test.db").path)

        // The state a racing peer leaves mid-start: its live overwrite already
        // landed and its captured original sits at the rollback path, but its
        // review row has not reached the ledger yet.
        let target = home.appendingPathComponent("series.txt")
        try WriteTestSupport.write("Version 2\n", at: target)
        let backupURL = home.appendingPathComponent(".rune_backup_series.txt")
        try WriteTestSupport.write("Original Version 1\n", at: backupURL)

        let tool = FilesWriteTool(homeDirectoryURL: home, stagedFilesStore: store)
        let output = try await tool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(target.path)\",\"content\":\"Version 3\\n\",\"mode\":\"live\"}"
            ),
            context: ToolContext(conversationID: UUID())
        )

        // A copy no settled series explains may be a peer's just-captured
        // original, so the write fails closed instead of replacing it.
        #expect(output.isError == true)
        #expect(output.content.contains("unexplained rollback copy"))
        #expect(try String(contentsOf: backupURL, encoding: .utf8) == "Original Version 1\n")
        #expect(try String(contentsOf: target, encoding: .utf8) == "Version 2\n")
        let review = try await store.liveReview(forPath: target.path)
        #expect(review == nil)

        // The dry-run mirror carries the same refusal rather than promising a
        // write that disk would reject.
        let previewOutput = try await tool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(target.path)\",\"content\":\"Version 3\\n\",\"mode\":\"live\"}"
            ),
            context: ToolContext(conversationID: UUID(), dryRun: true)
        )
        #expect(previewOutput.isError == true)
        #expect(previewOutput.content.contains("unexplained rollback copy"))
        #expect(try String(contentsOf: backupURL, encoding: .utf8) == "Original Version 1\n")
        #expect(try String(contentsOf: target, encoding: .utf8) == "Version 2\n")
    }

    @Test
    func `A peer copy landing between the presence probe and the snapshot is never deleted`() async throws {
        let (base, home) = try WriteTestSupport.makeBaseAndHome()
        defer { WriteTestSupport.cleanup(base) }
        let store = StagedFilesStore(dbPath: base.appendingPathComponent("test.db").path)

        let target = home.appendingPathComponent("series.txt")
        try WriteTestSupport.write("Original Version 1\n", at: target)
        let backupURL = home.appendingPathComponent(".rune_backup_series.txt")

        // Simulates cross-process race where destination is initially absent, but a peer lands an
        // original before the snapshot runs; exclusive creation must refuse to overwrite the peer's
        // bytes, leaving the sole rollback point intact.
        for previousSeriesSettled in [false, true] {
            try? FileManager.default.removeItem(at: backupURL)
            if previousSeriesSettled {
                #expect(await store.beginLiveReview(path: target.path, backupPath: backupURL.path) == true)
                #expect(await store.resolveLiveReview(path: target.path, resolution: .accepted) == true)
            }

            let outcome = await store.startLiveReview(path: target.path) { _ in
                #expect(!LiveFileBackup.entryExists(at: backupURL))
                do {
                    try Data("Peer Original\n".utf8).write(to: backupURL, options: .atomic)
                } catch {
                    return .refused(reason: error.localizedDescription)
                }
                do {
                    try LiveFileBackup.snapshot(liveURL: target, backupURL: backupURL)
                    return .captured(backupPath: backupURL.path)
                } catch {
                    return .refused(reason: error.localizedDescription)
                }
            }

            guard case .refused = outcome else {
                Issue.record("Expected the occupied destination to refuse the snapshot, got \(outcome)")
                return
            }
            #expect(try String(contentsOf: backupURL, encoding: .utf8) == "Peer Original\n")
            #expect(try String(contentsOf: target, encoding: .utf8) == "Original Version 1\n")
        }
        // The refused starts recorded no row of their own, so the settled row
        // stays settled and the peer's copy survives as the only rollback
        // point.
        let review = try await store.liveReview(forPath: target.path)
        #expect(review?.resolution == .accepted)
    }

    // MARK: - Rollback-destination symlink safety

    @Test
    func `Live write refuses a symlink planted at the rollback destination and writes through nothing`() async throws {
        let (base, home) = try WriteTestSupport.makeBaseAndHome()
        defer { WriteTestSupport.cleanup(base) }
        let store = StagedFilesStore(dbPath: base.appendingPathComponent("test.db").path)

        let target = home.appendingPathComponent("victim.txt")
        try WriteTestSupport.write("Original Version 1\n", at: target)
        let protected = home.appendingPathComponent("protected.txt")
        try WriteTestSupport.write("Protected Version 1\n", at: protected)
        let backupURL = home.appendingPathComponent(".rune_backup_victim.txt")

        let tool = FilesWriteTool(homeDirectoryURL: home, stagedFilesStore: store)

        // A dangling link and a link onto an existing file are both existing non-regular entries:
        // `fileExists` resolves them to "missing" or "file", but the no-follow probe sees the link
        // and must refuse before anything can be written through it.
        let linkTargets = [home.appendingPathComponent("never-created.txt"), protected]
        for linkTarget in linkTargets {
            try? FileManager.default.removeItem(at: backupURL)
            try FileManager.default.createSymbolicLink(at: backupURL, withDestinationURL: linkTarget)

            let output = try await tool.execute(
                input: ToolInput(
                    toolName: "files.write",
                    argumentsJSON: "{\"path\":\"\(target.path)\",\"content\":\"Attacker Write\\n\",\"mode\":\"live\"}"
                ),
                context: ToolContext(conversationID: UUID())
            )

            #expect(output.isError == true)
            #expect(output.content.contains("unexplained rollback copy"))
            if linkTarget == protected {
                #expect(try String(contentsOf: protected, encoding: .utf8) == "Protected Version 1\n")
            } else {
                #expect(!FileManager.default.fileExists(atPath: linkTarget.path))
            }
            #expect(try String(contentsOf: target, encoding: .utf8) == "Original Version 1\n")
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: backupURL.path) == linkTarget.path)
        }
        // The refusal never reached the ledger or the live write.
        #expect(try await store.liveReview(forPath: target.path) == nil)
    }

    @Test
    func `Fresh-series snapshot refuses a symlink at the rollback destination`() async throws {
        let (base, home) = try WriteTestSupport.makeBaseAndHome()
        defer { WriteTestSupport.cleanup(base) }
        let store = StagedFilesStore(dbPath: base.appendingPathComponent("test.db").path)

        let target = home.appendingPathComponent("victim.txt")
        try WriteTestSupport.write("Version 1\n", at: target)
        let backupURL = home.appendingPathComponent(".rune_backup_victim.txt")

        let tool = FilesWriteTool(homeDirectoryURL: home, stagedFilesStore: store)
        _ = try await tool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(target.path)\",\"content\":\"Version 2\\n\",\"mode\":\"live\"}"
            ),
            context: ToolContext(conversationID: UUID())
        )
        // Settle the series so the unexplained-entry pre-check stands aside
        // and the snapshot's own no-follow destination probe is what refuses.
        #expect(await store.resolveLiveReview(path: target.path, resolution: .accepted) == true)
        try FileManager.default.removeItem(at: backupURL)
        let protected = home.appendingPathComponent("protected.txt")
        try WriteTestSupport.write("Protected Version 1\n", at: protected)
        try FileManager.default.createSymbolicLink(at: backupURL, withDestinationURL: protected)

        let output = try await tool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(target.path)\",\"content\":\"Version 3\\n\",\"mode\":\"live\"}"
            ),
            context: ToolContext(conversationID: UUID())
        )

        #expect(output.isError == true)
        // The destination pre-check surfaces the shared refusal sentence
        // itself, so the disk error is the bare sentence a preview carries
        // rather than the snapshot's wrapped clone description.
        #expect(output.content == "Could not back up \(target.path) to \(backupURL.path): the backup path is not a regular file.")
        // The refused snapshot consumed nothing: the live bytes, the protected
        // file, and the link all survive, and the settled row was not replaced.
        #expect(try String(contentsOf: target, encoding: .utf8) == "Version 2\n")
        #expect(try String(contentsOf: protected, encoding: .utf8) == "Protected Version 1\n")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: backupURL.path) == protected.path)
        let review = try await store.liveReview(forPath: target.path)
        #expect(review?.resolution == .accepted)
    }

    @Test
    func `A settled series with a non-regular rollback entry refuses the preview and the write`() async throws {
        // A terminal row plus a regular leftover is covered above; a directory or symlink at the
        // rollback destination must refuse the preview too, because the snapshot's exclusive create
        // refuses any entry and an approval card must never promise a write disk rejects.
        for plantDirectory in [false, true] {
            let (base, home) = try WriteTestSupport.makeBaseAndHome()
            defer { WriteTestSupport.cleanup(base) }
            let store = StagedFilesStore(dbPath: base.appendingPathComponent("test.db").path)

            let target = home.appendingPathComponent("victim.txt")
            try WriteTestSupport.write("Version 1\n", at: target)
            let tool = FilesWriteTool(homeDirectoryURL: home, stagedFilesStore: store)
            _ = try await tool.execute(
                input: ToolInput(
                    toolName: "files.write",
                    argumentsJSON: "{\"path\":\"\(target.path)\",\"content\":\"Version 2\\n\",\"mode\":\"live\"}"
                ),
                context: ToolContext(conversationID: UUID())
            )
            // Settle the series so the unexplained-entry pre-check stands
            // aside, then replace the consumed copy with a non-regular entry.
            #expect(await store.resolveLiveReview(path: target.path, resolution: .accepted) == true)
            let backupURL = home.appendingPathComponent(".rune_backup_victim.txt")
            try FileManager.default.removeItem(at: backupURL)

            let protected = home.appendingPathComponent("protected.txt")
            try WriteTestSupport.write("Protected Version 1\n", at: protected)
            if plantDirectory {
                try FileManager.default.createDirectory(at: backupURL, withIntermediateDirectories: true)
                try WriteTestSupport.write("Keep me\n", at: backupURL.appendingPathComponent("sentinel.txt"))
            } else {
                try FileManager.default.createSymbolicLink(at: backupURL, withDestinationURL: protected)
            }

            let previewOutput = try await tool.execute(
                input: ToolInput(
                    toolName: "files.write",
                    argumentsJSON: "{\"path\":\"\(target.path)\",\"content\":\"Version 3\\n\",\"mode\":\"live\"}"
                ),
                context: ToolContext(conversationID: UUID(), dryRun: true)
            )
            #expect(previewOutput.isError == true)
            #expect(previewOutput.content.contains("the backup path is not a regular file"))

            // The disk write refuses through the same shared destination
            // predicate and surfaces the same bare sentence, so the two
            // refusals are byte-identical for this destination.
            let writeOutput = try await tool.execute(
                input: ToolInput(
                    toolName: "files.write",
                    argumentsJSON: "{\"path\":\"\(target.path)\",\"content\":\"Version 3\\n\",\"mode\":\"live\"}"
                ),
                context: ToolContext(conversationID: UUID())
            )
            #expect(writeOutput.isError == true)
            #expect(writeOutput.content == previewOutput.content)

            // Nothing was consumed or written through: the live bytes, the
            // planted entry, and the settled row all survive.
            #expect(try String(contentsOf: target, encoding: .utf8) == "Version 2\n")
            if plantDirectory {
                var isDirectory: ObjCBool = false
                #expect(FileManager.default.fileExists(atPath: backupURL.path, isDirectory: &isDirectory))
                #expect(isDirectory.boolValue)
                #expect(try String(contentsOf: backupURL.appendingPathComponent("sentinel.txt"), encoding: .utf8) == "Keep me\n")
            } else {
                #expect(try FileManager.default.destinationOfSymbolicLink(atPath: backupURL.path) == protected.path)
                #expect(try String(contentsOf: protected, encoding: .utf8) == "Protected Version 1\n")
            }
            let review = try await store.liveReview(forPath: target.path)
            #expect(review?.resolution == .accepted)
        }
    }

    @Test
    func `Live write refuses a denied rollback sibling before any disk mutation`() async throws {
        let (base, home) = try WriteTestSupport.makeBaseAndHome()
        defer { WriteTestSupport.cleanup(base) }
        let store = StagedFilesStore(dbPath: base.appendingPathComponent("test.db").path)

        let target = home.appendingPathComponent("guarded.txt")
        try WriteTestSupport.write("Original Version 1\n", at: target)

        // Only the derived rollback sibling is denied, so a refusal proves the
        // backup URL is vetted through the shared guard even though the live
        // path itself passed.
        let filesConfig = FilesConfig(denyPatterns: [".rune_backup_*"], allowRoots: [home.path])
        let tool = FilesWriteTool(homeDirectoryURL: home, filesConfig: filesConfig, stagedFilesStore: store)

        for dryRun in [false, true] {
            let output = try await tool.execute(
                input: ToolInput(
                    toolName: "files.write",
                    argumentsJSON: "{\"path\":\"\(target.path)\",\"content\":\"Version 2\\n\",\"mode\":\"live\"}"
                ),
                context: ToolContext(conversationID: UUID(), dryRun: dryRun)
            )
            #expect(output.isError == true)
            #expect(output.content.contains("Access denied"))
            #expect(output.content.contains(".rune_backup_guarded.txt"))
        }

        // The refusal precedes every mutation: the live bytes and the review
        // ledger are untouched and no copy exists.
        #expect(try String(contentsOf: target, encoding: .utf8) == "Original Version 1\n")
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".rune_backup_guarded.txt").path))
        #expect(try await store.liveReview(forPath: target.path) == nil)
    }

    @Test
    func `Concurrent fresh-series starts capture the pre-series original exactly once`() async throws {
        let (base, home) = try WriteTestSupport.makeBaseAndHome()
        defer { WriteTestSupport.cleanup(base) }
        let store = StagedFilesStore(dbPath: base.appendingPathComponent("test.db").path)

        let target = home.appendingPathComponent("series.txt")
        try WriteTestSupport.write("Original Version 1\n", at: target)
        let backupURL = home.appendingPathComponent(".rune_backup_series.txt")

        // Each racer snapshots the live bytes and then applies its own live write inside the same
        // start section, mirroring the tool's snapshot-then-write order.
        let racer: @Sendable (String) async -> LiveReviewStart = { version in
            await store.startLiveReview(path: target.path) { _ in
                guard FileManager.default.fileExists(atPath: target.path) else { return .noCopy }
                do {
                    try LiveFileBackup.snapshot(liveURL: target, backupURL: backupURL)
                    try Data(version.utf8).write(to: target)
                    return .captured(backupPath: backupURL.path)
                } catch {
                    return .refused(reason: error.localizedDescription)
                }
            }
        }

        async let first = racer("Version A\n")
        async let second = racer("Version B\n")
        let firstOutcome = await first
        let secondOutcome = await second
        let outcomes = [firstOutcome, secondOutcome]

        // Exactly one racer owns the fresh series; the other joins without
        // touching the copy, so the captured original survives.
        #expect(outcomes.count == 2)
        #expect(outcomes.contains(.started(backupPath: backupURL.path)))
        #expect(outcomes.contains(.joined(backupPath: backupURL.path)))
        #expect(try String(contentsOf: backupURL, encoding: .utf8) == "Original Version 1\n")
        let review = try await store.liveReview(forPath: target.path)
        #expect(review?.resolution == nil)
        #expect(review?.backupPath == backupURL.path)
    }

    // MARK: - Write path policy posture

    @Test
    func `Deny posture refuses the write even with approval granted`() async throws {
        let (base, home) = try WriteTestSupport.makeBaseAndHome()
        defer { WriteTestSupport.cleanup(base) }
        let store = StagedFilesStore(dbPath: base.appendingPathComponent("test.db").path)

        // A rule denies the tree outright, so no posture, mode request, or
        // recorded approval can write through it.
        let vault = home.appendingPathComponent("Vault", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        let target = vault.appendingPathComponent("notes.txt")

        var config = FilesConfig(allowRoots: ["~"], writeMode: .live)
        config.writePathRules = [FilesWritePathRule(path: "\(home.path)/Vault", posture: .deny)]
        let tool = FilesWriteTool(homeDirectoryURL: home, filesConfig: config, stagedFilesStore: store)

        let output = try await tool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(target.path)\",\"content\":\"PRIVATE PAYLOAD\\n\",\"mode\":\"live\"}"
            ),
            context: ToolContext(conversationID: UUID(), approved: true)
        )

        #expect(output.isError == true)
        #expect(output.content.contains("Access denied"))
        #expect(output.content.contains("Write path rule"))
        // The refusal names policy only: no file content travels in the envelope.
        #expect(output.content.contains("PRIVATE PAYLOAD") == false)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(!FileManager.default.fileExists(atPath: vault.appendingPathComponent(".rune_notes.txt").path))
        #expect(!FileManager.default.fileExists(atPath: vault.appendingPathComponent(".rune_backup_notes.txt").path))
        #expect(await store.state(forPath: target.path) == nil)
        #expect(try await store.liveReview(forPath: target.path) == nil)
    }

    @Test
    func `Deny pattern posture beats a live rule and a granted approval`() async throws {
        let (base, home) = try WriteTestSupport.makeBaseAndHome()
        defer { WriteTestSupport.cleanup(base) }
        let store = StagedFilesStore(dbPath: base.appendingPathComponent("test.db").path)

        // The deny tier outranks both the rule below it and every approval,
        // so the highest-precedence pattern wins even where the owner asked
        // for live writes of that tree.
        let secrets = home.appendingPathComponent("Secrets", isDirectory: true)
        try FileManager.default.createDirectory(at: secrets, withIntermediateDirectories: true)
        let target = secrets.appendingPathComponent("token.pem")

        var config = FilesConfig(allowRoots: ["~"], writeMode: .live)
        config.denyPatterns = ["*.pem"]
        config.writePathRules = [FilesWritePathRule(path: "\(home.path)/Secrets", posture: .live)]
        let tool = FilesWriteTool(homeDirectoryURL: home, filesConfig: config, stagedFilesStore: store)

        let output = try await tool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(target.path)\",\"content\":\"KEY MATERIAL\\n\",\"mode\":\"live\"}"
            ),
            context: ToolContext(conversationID: UUID(), approved: true)
        )

        #expect(output.isError == true)
        #expect(output.content.contains("Access denied"))
        #expect(output.content.contains("deny pattern"))
        #expect(output.content.contains("KEY MATERIAL") == false)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(!FileManager.default.fileExists(atPath: secrets.appendingPathComponent(".rune_token.pem").path))
    }

    @Test
    func `Ask posture fails closed without approval and writes once approved`() async throws {
        let (base, home) = try WriteTestSupport.makeBaseAndHome()
        defer { WriteTestSupport.cleanup(base) }
        let store = StagedFilesStore(dbPath: base.appendingPathComponent("test.db").path)

        let privateDir = home.appendingPathComponent("Private", isDirectory: true)
        try FileManager.default.createDirectory(at: privateDir, withIntermediateDirectories: true)
        let target = privateDir.appendingPathComponent("notes.txt")
        let stagingURL = privateDir.appendingPathComponent(".rune_notes.txt")

        var config = FilesConfig(allowRoots: ["~"], writeMode: .model)
        config.writePathRules = [FilesWritePathRule(path: "\(home.path)/Private", posture: .ask)]
        let tool = FilesWriteTool(homeDirectoryURL: home, filesConfig: config, stagedFilesStore: store)

        // The parked approval cannot self-approve: without a recorded
        // decide the call fails closed and previews promise nothing disk
        // would do.
        let refused = try await tool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(target.path)\",\"content\":\"Version 1\\n\"}"
            ),
            context: ToolContext(conversationID: UUID())
        )
        #expect(refused.isError == true)
        #expect(refused.content.contains("approvalRequired"))
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(!FileManager.default.fileExists(atPath: stagingURL.path))

        let refusedPreview = try await tool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(target.path)\",\"content\":\"Version 1\\n\"}"
            ),
            context: ToolContext(conversationID: UUID(), dryRun: true)
        )
        #expect(refusedPreview.isError == true)
        #expect(refusedPreview.content.contains("approvalRequired"))

        // The recorded decide authorizes the write, which proceeds under the
        // ordinary model-posture resolution and stages for review.
        let approved = try await tool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(target.path)\",\"content\":\"Version 1\\n\"}"
            ),
            context: ToolContext(conversationID: UUID(), approved: true)
        )
        #expect(approved.isError == false)
        let envelope = try JSONDecoder().decode(FilesWriteEnvelope.self, from: Data(approved.content.utf8))
        #expect(envelope.status == "staged")
        #expect(envelope.stagingPath?.hasSuffix(".rune_notes.txt") == true)
        #expect(try String(contentsOf: stagingURL, encoding: .utf8) == "Version 1\n")
        #expect(!FileManager.default.fileExists(atPath: target.path))
        let records = await store.list()
        #expect(records.count == 1)
        #expect(records.first?.path == target.path)
    }

    @Test
    func `Stage rule forces staged under a global live setting and names the override`() async throws {
        let (base, home) = try WriteTestSupport.makeBaseAndHome()
        defer { WriteTestSupport.cleanup(base) }
        let store = StagedFilesStore(dbPath: base.appendingPathComponent("test.db").path)

        let docs = home.appendingPathComponent("Docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let target = docs.appendingPathComponent("notes.txt")
        try WriteTestSupport.write("Version 1\n", at: target)
        let stagingURL = docs.appendingPathComponent(".rune_notes.txt")

        var config = FilesConfig(allowRoots: ["~"], writeMode: .live)
        config.writePathRules = [FilesWritePathRule(path: "\(home.path)/Docs", posture: .stage)]
        let tool = FilesWriteTool(homeDirectoryURL: home, filesConfig: config, stagedFilesStore: store)

        // Even an explicit live request loses to the rule, and the envelope
        // names the owner setting the policy overrode.
        let output = try await tool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(target.path)\",\"content\":\"Version 2\\n\",\"mode\":\"live\"}"
            ),
            context: ToolContext(conversationID: UUID())
        )

        #expect(output.isError == false)
        let envelope = try JSONDecoder().decode(FilesWriteEnvelope.self, from: Data(output.content.utf8))
        #expect(envelope.status == "staged")
        #expect(envelope.stagingPath?.hasSuffix(".rune_notes.txt") == true)
        #expect(envelope.message.hasSuffix(" Owner setting files.write_mode = 'live' was overridden by write path policy: this write is staged for review."))

        // The forced posture wins: the live file stayed untouched and the
        // review copy holds the requested bytes.
        #expect(try String(contentsOf: target, encoding: .utf8) == "Version 1\n")
        #expect(try String(contentsOf: stagingURL, encoding: .utf8) == "Version 2\n")
        let records = await store.list()
        #expect(records.count == 1)
        #expect(records.first?.path == target.path)
    }

    @Test
    func `Live rule forces live under a global staged setting and names the override`() async throws {
        let (base, home) = try WriteTestSupport.makeBaseAndHome()
        defer { WriteTestSupport.cleanup(base) }
        let store = StagedFilesStore(dbPath: base.appendingPathComponent("test.db").path)

        let liveDir = home.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: liveDir, withIntermediateDirectories: true)
        let target = liveDir.appendingPathComponent("notes.txt")
        try WriteTestSupport.write("Version 1\n", at: target)

        var config = FilesConfig(allowRoots: ["~"], writeMode: .staged)
        config.writePathRules = [FilesWritePathRule(path: "\(home.path)/Notes", posture: .live)]
        let tool = FilesWriteTool(homeDirectoryURL: home, filesConfig: config, stagedFilesStore: store)

        // An omitted mode defaults to staged, which the rule overrides; the
        // envelope names the owner setting the policy overrode.
        let output = try await tool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(target.path)\",\"content\":\"Version 2\\n\"}"
            ),
            context: ToolContext(conversationID: UUID())
        )

        #expect(output.isError == false)
        let envelope = try JSONDecoder().decode(FilesWriteEnvelope.self, from: Data(output.content.utf8))
        #expect(envelope.status == "live")
        #expect(envelope.message.hasSuffix(" Owner setting files.write_mode = 'staged' was overridden by write path policy: this write is applied live."))
        let backupURL = liveDir.appendingPathComponent(".rune_backup_notes.txt")
        #expect(envelope.backupPath?.hasSuffix(".rune_backup_notes.txt") == true)

        // The forced posture keeps the live review lifecycle intact: bytes
        // moved, the rollback copy holds the original, and the row stays
        // pending with nothing staged.
        #expect(try String(contentsOf: target, encoding: .utf8) == "Version 2\n")
        #expect(try String(contentsOf: backupURL, encoding: .utf8) == "Version 1\n")
        let review = try await store.liveReview(forPath: target.path)
        #expect(review?.resolution == nil)
        #expect(review?.backupPath == backupURL.path)
        #expect(await store.list().isEmpty)
    }

    @Test
    func `Stage rule forces staged over an explicit live request under the model posture`() async throws {
        let (base, home) = try WriteTestSupport.makeBaseAndHome()
        defer { WriteTestSupport.cleanup(base) }
        let store = StagedFilesStore(dbPath: base.appendingPathComponent("test.db").path)

        let docs = home.appendingPathComponent("Docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let target = docs.appendingPathComponent("notes.txt")
        try WriteTestSupport.write("Version 1\n", at: target)

        var config = FilesConfig(allowRoots: ["~"], writeMode: .model)
        config.writePathRules = [FilesWritePathRule(path: "\(home.path)/Docs", posture: .stage)]
        let tool = FilesWriteTool(homeDirectoryURL: home, filesConfig: config, stagedFilesStore: store)

        let output = try await tool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(target.path)\",\"content\":\"Version 2\\n\",\"mode\":\"live\"}"
            ),
            context: ToolContext(conversationID: UUID())
        )

        #expect(output.isError == false)
        let envelope = try JSONDecoder().decode(FilesWriteEnvelope.self, from: Data(output.content.utf8))
        #expect(envelope.status == "staged")
        #expect(envelope.message.hasSuffix(" Requested 'live' mode was overridden by write path policy: this write is staged for review."))
        #expect(try String(contentsOf: target, encoding: .utf8) == "Version 1\n")
        #expect(try String(contentsOf: docs.appendingPathComponent(".rune_notes.txt"), encoding: .utf8) == "Version 2\n")
    }

    @Test
    func `Live rule forces live over an explicit staged request under the model posture`() async throws {
        let (base, home) = try WriteTestSupport.makeBaseAndHome()
        defer { WriteTestSupport.cleanup(base) }
        let store = StagedFilesStore(dbPath: base.appendingPathComponent("test.db").path)

        let notes = home.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let target = notes.appendingPathComponent("notes.txt")
        try WriteTestSupport.write("Version 1\n", at: target)

        var config = FilesConfig(allowRoots: ["~"], writeMode: .model)
        config.writePathRules = [FilesWritePathRule(path: "\(home.path)/Notes", posture: .live)]
        let tool = FilesWriteTool(homeDirectoryURL: home, filesConfig: config, stagedFilesStore: store)

        let output = try await tool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(target.path)\",\"content\":\"Version 2\\n\",\"mode\":\"staged\"}"
            ),
            context: ToolContext(conversationID: UUID())
        )

        #expect(output.isError == false)
        let envelope = try JSONDecoder().decode(FilesWriteEnvelope.self, from: Data(output.content.utf8))
        #expect(envelope.status == "live")
        #expect(envelope.message.hasSuffix(" Requested 'staged' mode was overridden by write path policy: this write is applied live."))
        #expect(try String(contentsOf: target, encoding: .utf8) == "Version 2\n")
        #expect(try String(contentsOf: notes.appendingPathComponent(".rune_backup_notes.txt"), encoding: .utf8) == "Version 1\n")
    }

    @Test
    func `Agreeing posture keeps the plain envelope with no override sentence`() async throws {
        let (base, home) = try WriteTestSupport.makeBaseAndHome()
        defer { WriteTestSupport.cleanup(base) }
        let store = StagedFilesStore(dbPath: base.appendingPathComponent("test.db").path)

        // The rule agrees with the owner setting and the call omitted its
        // mode, so nothing lost and the envelope stays the plain sentence.
        let docs = home.appendingPathComponent("Docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let target = docs.appendingPathComponent("notes.txt")

        var config = FilesConfig(allowRoots: ["~"], writeMode: .staged)
        config.writePathRules = [FilesWritePathRule(path: "\(home.path)/Docs", posture: .stage)]
        let tool = FilesWriteTool(homeDirectoryURL: home, filesConfig: config, stagedFilesStore: store)

        let output = try await tool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(target.path)\",\"content\":\"Version 1\\n\"}"
            ),
            context: ToolContext(conversationID: UUID())
        )

        #expect(output.isError == false)
        let envelope = try JSONDecoder().decode(FilesWriteEnvelope.self, from: Data(output.content.utf8))
        #expect(envelope.status == "staged")
        #expect(envelope.message == "Changes staged to .rune_notes.txt. Live file is unchanged pending user review.")
        #expect(envelope.message.contains("overridden") == false)
    }

    @Test
    func `Reserved review artifact namespace stays refused under a forced live posture`() async throws {
        let (base, home) = try WriteTestSupport.makeBaseAndHome()
        defer { WriteTestSupport.cleanup(base) }
        let store = StagedFilesStore(dbPath: base.appendingPathComponent("test.db").path)

        // A staging sibling belongs to the review lifecycle, so the reserved
        // namespace refuses even when a rule forces every write live.
        let document = home.appendingPathComponent("document.txt")
        try WriteTestSupport.write("Original Version 1\n", at: document)
        _ = try await FilesWriteTool(homeDirectoryURL: home, stagedFilesStore: store).execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(document.path)\",\"content\":\"Staged Version 2\\n\"}"
            ),
            context: ToolContext(conversationID: UUID())
        )
        let reserved = home.appendingPathComponent(".rune_document.txt")
        #expect(await store.state(forPath: document.path) == .pending)

        var config = FilesConfig(allowRoots: ["~"], writeMode: .staged)
        config.writePathRules = [FilesWritePathRule(path: "\(home.path)", posture: .live)]
        let tool = FilesWriteTool(homeDirectoryURL: home, filesConfig: config, stagedFilesStore: store)

        let output = try await tool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(reserved.path)\",\"content\":\"Clobber\\n\"}"
            ),
            context: ToolContext(conversationID: UUID())
        )

        #expect(output.isError == true)
        #expect(output.content.contains("reserved for review artifacts"))
        // The staged copy, the live bytes, and the pending review all survive.
        #expect(try String(contentsOf: reserved, encoding: .utf8) == "Staged Version 2\n")
        #expect(try String(contentsOf: document, encoding: .utf8) == "Original Version 1\n")
        #expect(await store.state(forPath: document.path) == .pending)
    }
}

@Suite("LiveFileBackup")
struct LiveFileBackupTests {
    @Test
    func `snapshot refuses an occupied destination and never deletes the entry`() throws {
        let (base, home) = try WriteTestSupport.makeBaseAndHome()
        defer { WriteTestSupport.cleanup(base) }

        let live = home.appendingPathComponent("document.txt")
        let backup = home.appendingPathComponent(".rune_backup_document.txt")
        try WriteTestSupport.write("Live Version\n", at: live)
        try WriteTestSupport.write("Peer Original\n", at: backup)

        do {
            try LiveFileBackup.snapshot(liveURL: live, backupURL: backup)
            Issue.record("Expected the occupied destination to refuse the snapshot")
        } catch {
            #expect(error.localizedDescription.contains("a rollback copy already exists and is never replaced"))
        }

        // The entry at the destination may be a peer's only rollback point, so
        // a refused snapshot leaves every byte exactly where it was instead of
        // replacing the copy with a clone of the live file.
        #expect(try String(contentsOf: backup, encoding: .utf8) == "Peer Original\n")
        #expect(try String(contentsOf: live, encoding: .utf8) == "Live Version\n")
    }

    @Test
    func `snapshot and its source refusal agree that a non-regular live path is refused`() throws {
        let (base, home) = try WriteTestSupport.makeBaseAndHome()
        defer { WriteTestSupport.cleanup(base) }

        // A directory and a symlink — even onto a regular file — are both non-regular live sources
        // for the no-follow guard: cloning either would produce a rollback copy that can never
        // restore a file.
        let directory = home.appendingPathComponent("directory.txt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let protected = home.appendingPathComponent("protected.txt")
        try WriteTestSupport.write("Protected Version 1\n", at: protected)
        let link = home.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: protected)

        for live in [directory, link] {
            let backup = home.appendingPathComponent(".rune_backup_\(live.lastPathComponent)")
            let refusal = try #require(LiveFileBackup.snapshotSourceRefusal(liveURL: live, backupURL: backup))
            do {
                try LiveFileBackup.snapshot(liveURL: live, backupURL: backup)
                Issue.record("Expected a non-regular live path to refuse the snapshot")
            } catch {
                #expect(error.localizedDescription == refusal)
            }
            // The refused snapshot never wrote through the source or landed a
            // copy at the destination.
            #expect(!LiveFileBackup.entryExists(at: backup))
            #expect(try String(contentsOf: protected, encoding: .utf8) == "Protected Version 1\n")
        }
    }
}

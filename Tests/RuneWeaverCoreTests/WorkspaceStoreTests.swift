// Rune Weaver Core Tests — Agent scratch workspace quotas, shell default, and recall exclusion.

import Foundation
@testable import RuneWeaverCore
@testable import RuneWeaverTools
import Testing

/// Minimal `[llm]` prefix keeping config documents loadable in tests.
private let workspaceTestLLMPrefix = """
[llm]
default_provider = "mlx"
[llm.providers.mlx]
enabled = true
model = "gemma-4-9b"
server_url = "http://localhost:8080"
"""

/// Creates an isolated temporary directory for one test.
private func makeTempBase() throws -> URL {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("runeweaver-workspace-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
}

/// Removes a temporary directory without failing the test on cleanup errors.
private func removeTempBase(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

/// Writes empty files under a directory.
private func writeEmptyFiles(count: Int, in directory: URL, prefix: String = "file") throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for index in 0 ..< count {
        let url = directory.appendingPathComponent("\(prefix)-\(index).txt")
        try Data().write(to: url)
    }
}

/// Decodes a shell envelope from tool output content.
private func decodeBashEnvelope(_ content: String) throws -> BashResultEnvelope {
    try JSONDecoder().decode(BashResultEnvelope.self, from: Data(content.utf8))
}

@Suite("WorkspaceStore")
struct WorkspaceStoreTests {
    @Test
    func `Defaults keep documented quotas`() {
        let config = WorkspaceConfig()
        #expect(config.quotaMB == 500)
        #expect(config.quotaFiles == 10000)
        #expect(config.tmpTTLDays == 7)
        #expect(WorkspaceConfig.defaultQuotaMB == 500)
        #expect(WorkspaceConfig.defaultQuotaFiles == 10000)
        #expect(WorkspaceConfig.defaultTmpTTLDays == 7)
        #expect(RuneWeaverConfig.default.workspace == WorkspaceConfig())
    }

    @Test
    func `Absent workspace table decodes to defaults`() throws {
        let config = try RuneWeaverConfig(decoding: TOMLParser.parse(workspaceTestLLMPrefix))
        #expect(config.workspace.quotaMB == 500)
        #expect(config.workspace.quotaFiles == 10000)
        #expect(config.workspace.tmpTTLDays == 7)
        try config.validate()
    }

    @Test
    func `Explicit knobs decode and round-trip`() throws {
        let text = workspaceTestLLMPrefix + """
        \n[workspace]\nquota_mb = 600\nquota_files = 12000\ntmp_ttl_days = 3\n
        """
        let config = try RuneWeaverConfig(decoding: TOMLParser.parse(text))
        #expect(config.workspace.quotaMB == 600)
        #expect(config.workspace.quotaFiles == 12000)
        #expect(config.workspace.tmpTTLDays == 3)
        try config.validate()

        var roundTrip = RuneWeaverConfig.default
        roundTrip.workspace = config.workspace
        let rendered = roundTrip.renderTOML()
        #expect(rendered.contains("[workspace]"))
        #expect(rendered.contains("quota_mb = 600"))
        #expect(rendered.contains("quota_files = 12000"))
        #expect(rendered.contains("tmp_ttl_days = 3"))
        let reparsed = try RuneWeaverConfig(decoding: TOMLParser.parse(rendered))
        #expect(reparsed.workspace == config.workspace)
        try reparsed.validate()
    }

    @Test
    func `Clamped folds quotas into bounds`() {
        let floored = WorkspaceConfig(quotaMB: 1, quotaFiles: 1, tmpTTLDays: -5).clamped()
        #expect(floored.quotaMB == WorkspaceConfig.minQuotaMB)
        #expect(floored.quotaFiles == WorkspaceConfig.minQuotaFiles)
        #expect(floored.tmpTTLDays == WorkspaceConfig.minTmpTTLDays)

        let capped = WorkspaceConfig(quotaMB: 99999, quotaFiles: 9_999_999, tmpTTLDays: 999).clamped()
        #expect(capped.quotaMB == WorkspaceConfig.maxQuotaMB)
        #expect(capped.quotaFiles == WorkspaceConfig.maxQuotaFiles)
        #expect(capped.tmpTTLDays == WorkspaceConfig.maxTmpTTLDays)

        let kept = WorkspaceConfig(quotaMB: 600, quotaFiles: 12000, tmpTTLDays: 3).clamped()
        #expect(kept.quotaMB == 600)
        #expect(kept.quotaFiles == 12000)
        #expect(kept.tmpTTLDays == 3)

        let zeroTTLStays = WorkspaceConfig(quotaMB: 500, quotaFiles: 10000, tmpTTLDays: 0).clamped()
        #expect(zeroTTLStays.tmpTTLDays == 0)
    }

    @Test
    func `Validation rejects out-of-range quotas`() throws {
        var smallMB = RuneWeaverConfig.default
        smallMB.workspace.quotaMB = WorkspaceConfig.minQuotaMB - 1
        do {
            try smallMB.validate()
            Issue.record("Expected validation failure for small quota_mb")
        } catch let error as ConfigError {
            guard case let .validationError(field, _) = error else {
                Issue.record("Expected validationError, got \(error)")
                return
            }
            #expect(field == "workspace.quota_mb")
        }

        var largeFiles = RuneWeaverConfig.default
        largeFiles.workspace.quotaFiles = WorkspaceConfig.maxQuotaFiles + 1
        do {
            try largeFiles.validate()
            Issue.record("Expected validation failure for large quota_files")
        } catch let error as ConfigError {
            guard case let .validationError(field, _) = error else {
                Issue.record("Expected validationError, got \(error)")
                return
            }
            #expect(field == "workspace.quota_files")
        }

        var largeTTL = RuneWeaverConfig.default
        largeTTL.workspace.tmpTTLDays = WorkspaceConfig.maxTmpTTLDays + 1
        do {
            try largeTTL.validate()
            Issue.record("Expected validation failure for large tmp_ttl_days")
        } catch let error as ConfigError {
            guard case let .validationError(field, _) = error else {
                Issue.record("Expected validationError, got \(error)")
                return
            }
            #expect(field == "workspace.tmp_ttl_days")
        }
    }

    @Test
    func `Ensure creates owner-only root`() async throws {
        let base = try makeTempBase()
        defer { removeTempBase(base) }
        let root = base.appendingPathComponent("ws", isDirectory: true)
        let store = WorkspaceStore(config: WorkspaceConfig(), rootURL: root)
        let ensured = try await store.ensure()
        #expect(ensured.standardizedFileURL.path == root.standardizedFileURL.path)
        #expect(FileManager.default.fileExists(atPath: root.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        #expect(permissions == 0o700)
        let tmpAttributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("tmp").path)
        #expect((tmpAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test
    func `Ensure re-secures permissive root to owner-only`() async throws {
        let base = try makeTempBase()
        defer { removeTempBase(base) }
        let root = base.appendingPathComponent("ws", isDirectory: true)
        let store = WorkspaceStore(config: WorkspaceConfig(), rootURL: root)
        _ = try await store.ensure()
        // Simulate a restored backup or permissive umask leaving scratch
        // world-readable: the next ensure must chmod back to 0700, never
        // leave the permissive bits silently in place.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: root.appendingPathComponent("tmp").path
        )
        _ = try await store.ensure()
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let tmpAttributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("tmp").path)
        #expect((tmpAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test
    func `Ensure failure surfaces ensureFailed`() async throws {
        let base = try makeTempBase()
        defer { removeTempBase(base) }
        // A file at the root path blocks directory creation, proving
        // failures throw `ensureFailed` instead of falling back elsewhere.
        let blocker = base.appendingPathComponent("blocker")
        try Data("block".utf8).write(to: blocker)
        let store = WorkspaceStore(config: WorkspaceConfig(), rootURL: blocker.appendingPathComponent("ws"))
        do {
            _ = try await store.ensure()
            Issue.record("Expected ensureFailed when the root cannot be created")
        } catch let error as WorkspaceError {
            guard case let .ensureFailed(reason) = error else {
                Issue.record("Expected ensureFailed, got \(error)")
                return
            }
            #expect(reason.contains("Workspace unavailable"))
        }
    }

    @Test
    func `Quota boundary passes under and refuses over`() async throws {
        let base = try makeTempBase()
        defer { removeTempBase(base) }
        let root = base.appendingPathComponent("ws", isDirectory: true)
        // Minimum file quota keeps the fixture small while staying in bounds.
        let config = WorkspaceConfig(quotaMB: 500, quotaFiles: 100, tmpTTLDays: 7)
        let store = WorkspaceStore(config: config, rootURL: root)
        _ = try await store.ensure()
        try writeEmptyFiles(count: 3, in: root.appendingPathComponent("data", isDirectory: true))
        try await store.checkQuota()

        try writeEmptyFiles(count: 110, in: root.appendingPathComponent("overflow", isDirectory: true))
        do {
            try await store.checkQuota()
            Issue.record("Expected quota refusal once files exceed the limit")
        } catch let error as WorkspaceError {
            guard case let .quotaExceeded(bytes, files, _, quotaMB, quotaFiles) = error else {
                Issue.record("Expected quotaExceeded, got \(error)")
                return
            }
            #expect(quotaMB == 500)
            #expect(quotaFiles == 100)
            #expect(files > quotaFiles)
            #expect(bytes >= 0)
            #expect(error.reason.contains("bytes"))
            #expect(error.reason.contains("files"))
            #expect(error.reason.contains("500"))
            #expect(error.reason.contains("100"))
        }
    }

    @Test
    func `Usage never follows symlinks`() async throws {
        let base = try makeTempBase()
        defer { removeTempBase(base) }
        let root = base.appendingPathComponent("ws", isDirectory: true)
        let store = WorkspaceStore(config: WorkspaceConfig(), rootURL: root)
        _ = try await store.ensure()
        let target = root.appendingPathComponent("real.txt")
        try Data("scratch".utf8).write(to: target)
        let link = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let usage = try await store.usage()
        // Only the real file counts; the link is skipped without following it.
        #expect(usage.files == 1)
        #expect(usage.bytes == "scratch".utf8.count)
        #expect(!usage.truncated)
    }

    @Test
    func `Usage caps at twice quota and reports truncated`() async throws {
        let base = try makeTempBase()
        defer { removeTempBase(base) }
        let root = base.appendingPathComponent("ws", isDirectory: true)
        let config = WorkspaceConfig(quotaMB: 500, quotaFiles: 100, tmpTTLDays: 7)
        let store = WorkspaceStore(config: config, rootURL: root)
        _ = try await store.ensure()
        // Cap is twice the file quota (200 entries); writing past it proves
        // the walk stays bounded instead of stalling the turn.
        try writeEmptyFiles(count: 210, in: root.appendingPathComponent("many", isDirectory: true))
        let usage = try await store.usage()
        #expect(usage.truncated)
        #expect(usage.files <= 200)
    }

    @Test
    func `Truncated walk fails closed even under quota bounds`() async throws {
        let base = try makeTempBase()
        defer { removeTempBase(base) }
        let root = base.appendingPathComponent("ws", isDirectory: true)
        let config = WorkspaceConfig(quotaMB: 500, quotaFiles: 100, tmpTTLDays: 7)
        let store = WorkspaceStore(config: config, rootURL: root)
        _ = try await store.ensure()
        // Directories inflate the entry cap without counting as files: 210 empty directories exceed
        // the 200-entry cap while the file lower bound stays at zero, proving a truncated walk
        // cannot pass on its lower bounds alone.
        let holder = root.appendingPathComponent("many-dirs", isDirectory: true)
        try FileManager.default.createDirectory(at: holder, withIntermediateDirectories: true)
        for index in 0 ..< 210 {
            try FileManager.default.createDirectory(
                at: holder.appendingPathComponent("dir-\(index)", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        let usage = try await store.usage()
        #expect(usage.truncated)
        #expect(usage.files < 100)
        do {
            try await store.checkQuota()
            Issue.record("Expected quota refusal on a truncated walk even when bounds sit under quota")
        } catch let error as WorkspaceError {
            guard case let .quotaExceeded(_, _, truncated, quotaMB, quotaFiles) = error else {
                Issue.record("Expected quotaExceeded, got \(error)")
                return
            }
            #expect(truncated)
            #expect(quotaMB == 500)
            #expect(quotaFiles == 100)
            #expect(error.reason.contains("truncated"))
        }
    }

    @Test
    func `Tmp TTL prunes stale entries`() async throws {
        let base = try makeTempBase()
        defer { removeTempBase(base) }
        let root = base.appendingPathComponent("ws", isDirectory: true)
        let store = WorkspaceStore(config: WorkspaceConfig(quotaMB: 500, quotaFiles: 10000, tmpTTLDays: 7), rootURL: root)
        _ = try await store.ensure()
        let tmp = root.appendingPathComponent("tmp", isDirectory: true)
        let stale = tmp.appendingPathComponent("stale.txt")
        let fresh = tmp.appendingPathComponent("fresh.txt")
        try Data("old".utf8).write(to: stale)
        try Data("new".utf8).write(to: fresh)
        let now = Date()
        let eightDaysAgo = now.addingTimeInterval(-8 * 24 * 60 * 60)
        try FileManager.default.setAttributes([.modificationDate: eightDaysAgo], ofItemAtPath: stale.path)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: fresh.path)
        let removed = try await store.pruneTmp(now: now)
        #expect(removed == 1)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }

    @Test
    func `Tmp TTL zero clears everything`() async throws {
        let base = try makeTempBase()
        defer { removeTempBase(base) }
        let root = base.appendingPathComponent("ws", isDirectory: true)
        let store = WorkspaceStore(config: WorkspaceConfig(quotaMB: 500, quotaFiles: 10000, tmpTTLDays: 0), rootURL: root)
        _ = try await store.ensure()
        let tmp = root.appendingPathComponent("tmp", isDirectory: true)
        try Data("a".utf8).write(to: tmp.appendingPathComponent("a.txt"))
        try Data("b".utf8).write(to: tmp.appendingPathComponent("b.txt"))
        let removed = try await store.pruneTmp(now: Date())
        #expect(removed == 2)
        #expect(!FileManager.default.fileExists(atPath: tmp.appendingPathComponent("a.txt").path))
        #expect(!FileManager.default.fileExists(atPath: tmp.appendingPathComponent("b.txt").path))
    }

    @Test
    func `Default cwd is workspace when omitted`() async throws {
        let base = try makeTempBase()
        defer { removeTempBase(base) }
        let root = base.appendingPathComponent("ws", isDirectory: true)
        let workspaceConfig = WorkspaceConfig(quotaMB: 500, quotaFiles: 10000, tmpTTLDays: 7)
        let store = WorkspaceStore(config: workspaceConfig, rootURL: root)
        let bashConfig = BashConfig(
            rules: [
                BashRule(pattern: "*", action: .ask),
                BashRule(pattern: "pwd", action: .allow)
            ]
        )
        let tool = BashTool(
            bashConfig: bashConfig,
            filesConfig: FilesConfig(),
            allowUnsandboxedFallback: true,
            workspaceConfig: workspaceConfig,
            workspaceStore: store
        )
        let input = ToolInput(toolName: "bash.exec", argumentsJSON: #"{"command":"pwd"}"#)
        let output = try await tool.execute(input: input, context: ToolContext(conversationID: UUID()))
        #expect(!output.isError)
        let envelope = try decodeBashEnvelope(output.content)
        #expect(envelope.exitCode == 0)
        #expect(envelope.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == root.standardizedFileURL.path)
    }

    @Test
    func `Explicit cwd outside workspace keeps guard behavior`() async throws {
        let base = try makeTempBase()
        defer { removeTempBase(base) }
        let root = base.appendingPathComponent("ws", isDirectory: true)
        let explicit = base.appendingPathComponent("explicit", isDirectory: true)
        try FileManager.default.createDirectory(at: explicit, withIntermediateDirectories: true)
        let workspaceConfig = WorkspaceConfig()
        let store = WorkspaceStore(config: workspaceConfig, rootURL: root)
        let bashConfig = BashConfig(
            rules: [
                BashRule(pattern: "*", action: .ask),
                BashRule(pattern: "pwd", action: .allow)
            ]
        )
        // Allow both locations so the explicit choice is honored rather than
        // forced back into the workspace.
        let filesConfig = FilesConfig(allowRoots: [root.path, explicit.path])
        let tool = BashTool(
            bashConfig: bashConfig,
            filesConfig: filesConfig,
            allowUnsandboxedFallback: true,
            workspaceConfig: workspaceConfig,
            workspaceStore: store
        )
        let escapedCwd = explicit.path.replacingOccurrences(of: "\"", with: "\\\"")
        let input = ToolInput(toolName: "bash.exec", argumentsJSON: #"{"command":"pwd","cwd":"\#(escapedCwd)"}"#)
        let output = try await tool.execute(input: input, context: ToolContext(conversationID: UUID()))
        #expect(!output.isError)
        let envelope = try decodeBashEnvelope(output.content)
        #expect(envelope.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == explicit.standardizedFileURL.path)
    }

    @Test
    func `Over-quota exec refuses before spawning`() async throws {
        let base = try makeTempBase()
        defer { removeTempBase(base) }
        let root = base.appendingPathComponent("ws", isDirectory: true)
        let workspaceConfig = WorkspaceConfig(quotaMB: 500, quotaFiles: 100, tmpTTLDays: 7)
        let store = WorkspaceStore(config: workspaceConfig, rootURL: root)
        _ = try await store.ensure()
        try writeEmptyFiles(count: 110, in: root.appendingPathComponent("overflow", isDirectory: true))
        let bashConfig = BashConfig(
            rules: [
                BashRule(pattern: "*", action: .ask),
                BashRule(pattern: "pwd", action: .allow)
            ]
        )
        let tool = BashTool(
            bashConfig: bashConfig,
            filesConfig: FilesConfig(),
            allowUnsandboxedFallback: true,
            workspaceConfig: workspaceConfig,
            workspaceStore: store
        )
        let input = ToolInput(toolName: "bash.exec", argumentsJSON: #"{"command":"pwd"}"#)
        let output = try await tool.execute(input: input, context: ToolContext(conversationID: UUID()))
        #expect(output.isError)
        #expect(output.content.contains("Workspace quota exceeded"))
        #expect(output.content.contains("quota"))
    }

    @Test
    func `Indexer scopes scratch exclusion to runeweaver workspace`() {
        // A bare `workspace` entry must never return: only the scoped
        // `.runeweaver/workspace` prefix excludes scratch.
        #expect(!FilesIndexer.alwaysSkippedPatterns.contains("workspace"))
        #expect(FilesIndexer.alwaysSkippedPatterns.contains(".Trash"))
        #expect(FilesIndexer.alwaysSkippedPatterns.contains(".runeweaver"))
        #expect(FilesIndexer.isExcluded(
            relativePath: ".runeweaver/workspace/tmp/stale.txt",
            filename: "stale.txt",
            patterns: FilesIndexer.alwaysSkippedPatterns
        ))
        // User trees carrying a `workspace` component stay indexable.
        #expect(!FilesIndexer.isExcluded(
            relativePath: "workspace/scratch.txt",
            filename: "scratch.txt",
            patterns: FilesIndexer.alwaysSkippedPatterns
        ))
        #expect(!FilesIndexer.isExcluded(
            relativePath: "projects/workspace/notes.md",
            filename: "notes.md",
            patterns: FilesIndexer.alwaysSkippedPatterns
        ))
        #expect(!FilesIndexer.isExcluded(
            relativePath: "Documents/workspace",
            filename: "workspace",
            patterns: FilesIndexer.alwaysSkippedPatterns
        ))
        // A stale bare `workspace` pattern stays inert outside scratch but
        // still excludes the scoped subtree.
        #expect(!FilesIndexer.isExcluded(
            relativePath: "workspace/scratch.txt",
            filename: "scratch.txt",
            patterns: ["workspace"]
        ))
        #expect(FilesIndexer.isExcluded(
            relativePath: ".runeweaver/workspace/tmp/stale.txt",
            filename: "stale.txt",
            patterns: ["workspace"]
        ))
        #expect(!FilesIndexer.isExcluded(
            relativePath: "Documents/notes.txt",
            filename: "notes.txt",
            patterns: FilesIndexer.alwaysSkippedPatterns
        ))
        // Absolute-URL form covers walks rooted inside scratch itself.
        #expect(FilesIndexer.isWorkspaceScratchURL(URL(fileURLWithPath: "/Users/test/.runeweaver/workspace/tmp/a.txt")))
        #expect(!FilesIndexer.isWorkspaceScratchURL(URL(fileURLWithPath: "/Users/test/projects/workspace/notes.md")))
    }
}

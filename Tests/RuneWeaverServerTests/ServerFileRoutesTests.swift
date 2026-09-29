// Rune Weaver Server Tests — File staging routes and StagedFilesManager.

import Foundation
@testable import RuneWeaverCore
@testable import RuneWeaverServer
import RuneWeaverTools
import Testing
import Vapor

private enum FileRoutesTestSupport {
    static func makeTempWorkspace() throws -> (base: URL, workspace: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("runeweaver-files-routes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let workspace = base.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return (base, workspace)
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

@Suite("StagedFilesManager")
struct StagedFilesManagerTests {
    @Test
    func `findStagedFiles discovers dot rune files and computes diffs`() async throws {
        let (base, ws) = try FileRoutesTestSupport.makeTempWorkspace()
        defer { FileRoutesTestSupport.cleanup(base) }
        let store = StagedFilesStore(dbPath: ws.appendingPathComponent("staged.db").path)

        let liveFile = ws.appendingPathComponent("App.swift")
        try FileRoutesTestSupport.write("let x = 1\nlet y = 2\n", at: liveFile)

        let stagedFile = ws.appendingPathComponent(".rune_App.swift")
        try FileRoutesTestSupport.write("let x = 1\nlet y = 20\nlet z = 30\n", at: stagedFile)

        await store.recordStaged(path: liveFile.path, stagingPath: stagedFile.path)

        let entries = await StagedFilesManager.findStagedFiles(
            under: ws.path,
            filesConfig: FilesConfig(denyPatterns: [], allowRoots: [ws.path]),
            store: store
        )

        #expect(entries.count == 1)
        let entry = entries[0]
        #expect(URL(fileURLWithPath: entry.path).resolvingSymlinksInPath().path == liveFile.resolvingSymlinksInPath().path)
        #expect(URL(fileURLWithPath: entry.stagingPath).resolvingSymlinksInPath().path == stagedFile.resolvingSymlinksInPath().path)
        #expect(entry.additions == 2)
        #expect(entry.deletions == 1)
        #expect(entry.diff.contains("-let y = 2"))
        #expect(entry.diff.contains("+let y = 20"))
        #expect(entry.diff.contains("+let z = 30"))
    }

    @Test
    func `accept atomically replaces live file and removes staging`() async throws {
        let (base, ws) = try FileRoutesTestSupport.makeTempWorkspace()
        defer { FileRoutesTestSupport.cleanup(base) }
        let store = StagedFilesStore(dbPath: ws.appendingPathComponent("staged.db").path)

        let liveFile = ws.appendingPathComponent("Service.swift")
        try FileRoutesTestSupport.write("Original Version\n", at: liveFile)

        let stagedFile = ws.appendingPathComponent(".rune_Service.swift")
        try FileRoutesTestSupport.write("Accepted Version\n", at: stagedFile)

        await store.recordStaged(path: liveFile.path, stagingPath: stagedFile.path)

        // Temp workspace sits outside the default home root, so scope the
        // fail-closed guard to it; denied paths elsewhere still refuse.
        let filesConfig = FilesConfig(allowRoots: [ws.path])
        try await StagedFilesManager.accept(livePath: liveFile.path, stagingPath: stagedFile.path, filesConfig: filesConfig, store: store)

        // Live file contains accepted version
        let content = try String(contentsOf: liveFile, encoding: .utf8)
        #expect(content == "Accepted Version\n")

        // Staged file is removed from disk
        #expect(!FileManager.default.fileExists(atPath: stagedFile.path))

        // Cleaned up from store
        let remaining = await store.list()
        #expect(remaining.isEmpty)
    }

    @Test
    func `discard removes staging file and preserves live file`() async throws {
        let (base, ws) = try FileRoutesTestSupport.makeTempWorkspace()
        defer { FileRoutesTestSupport.cleanup(base) }
        let store = StagedFilesStore(dbPath: ws.appendingPathComponent("staged.db").path)

        let liveFile = ws.appendingPathComponent("Config.swift")
        try FileRoutesTestSupport.write("Live Unchanged\n", at: liveFile)

        let stagedFile = ws.appendingPathComponent(".rune_Config.swift")
        try FileRoutesTestSupport.write("Discarded Content\n", at: stagedFile)

        await store.recordStaged(path: liveFile.path, stagingPath: stagedFile.path)

        // Same scoped-root rationale as accept: permit the temp workspace
        // while the guard keeps failing closed outside it.
        let filesConfig = FilesConfig(allowRoots: [ws.path])
        try await StagedFilesManager.discard(stagingPath: stagedFile.path, filesConfig: filesConfig, store: store)

        // Live file remains unchanged
        let content = try String(contentsOf: liveFile, encoding: .utf8)
        #expect(content == "Live Unchanged\n")

        // Staged file is deleted from disk
        #expect(!FileManager.default.fileExists(atPath: stagedFile.path))

        // Cleaned up from store
        let remaining = await store.list()
        #expect(remaining.isEmpty)
    }
}

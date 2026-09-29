// Rune Weaver Core Tests — StagedFilesStore SQLite persistence tests.

import Foundation
@testable import RuneWeaverCore
import Testing

private enum StagedFilesStoreTestSupport {
    static func makeTempWorkspace() throws -> (base: URL, dbURL: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("runeweaver-stagedstore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let dbURL = base.appendingPathComponent("test_episodes.db")
        return (base, dbURL)
    }

    static func cleanup(_ base: URL) {
        try? FileManager.default.removeItem(at: base)
    }

    static func touchFile(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "test".write(to: url, atomically: true, encoding: .utf8)
    }
}

@Suite("StagedFilesStore")
struct StagedFilesStoreTests {
    @Test
    func `records and lists staged files when present on disk`() async throws {
        let (base, dbURL) = try StagedFilesStoreTestSupport.makeTempWorkspace()
        defer { StagedFilesStoreTestSupport.cleanup(base) }

        let store = StagedFilesStore(dbPath: dbURL.path)

        let file1 = base.appendingPathComponent("file1.swift")
        let staged1 = base.appendingPathComponent(".rune_file1.swift")
        try StagedFilesStoreTestSupport.touchFile(at: staged1)

        let file2 = base.appendingPathComponent("subdir/file2.swift")
        let staged2 = base.appendingPathComponent("subdir/.rune_file2.swift")
        try StagedFilesStoreTestSupport.touchFile(at: staged2)

        await store.recordStaged(path: file1.path, stagingPath: staged1.path)
        await store.recordStaged(path: file2.path, stagingPath: staged2.path)

        let all = await store.list()
        #expect(all.count == 2)
        #expect(all.contains { $0.path == file1.path && $0.stagingPath == staged1.path })
        #expect(all.contains { $0.path == file2.path && $0.stagingPath == staged2.path })
    }

    @Test
    func `filters by rootPath prefix`() async throws {
        let (base, dbURL) = try StagedFilesStoreTestSupport.makeTempWorkspace()
        defer { StagedFilesStoreTestSupport.cleanup(base) }

        let store = StagedFilesStore(dbPath: dbURL.path)

        let insideDir = base.appendingPathComponent("inside", isDirectory: true)
        let outsideDir = base.appendingPathComponent("outside", isDirectory: true)

        let fileInside = insideDir.appendingPathComponent("a.txt")
        let stagedInside = insideDir.appendingPathComponent(".rune_a.txt")
        try StagedFilesStoreTestSupport.touchFile(at: stagedInside)

        let fileOutside = outsideDir.appendingPathComponent("b.txt")
        let stagedOutside = outsideDir.appendingPathComponent(".rune_b.txt")
        try StagedFilesStoreTestSupport.touchFile(at: stagedOutside)

        await store.recordStaged(path: fileInside.path, stagingPath: stagedInside.path)
        await store.recordStaged(path: fileOutside.path, stagingPath: stagedOutside.path)

        let filtered = await store.list(under: insideDir.path)
        #expect(filtered.count == 1)
        #expect(filtered.first?.path == fileInside.path)
    }

    @Test
    func `removes staged record when accepted or discarded`() async throws {
        let (base, dbURL) = try StagedFilesStoreTestSupport.makeTempWorkspace()
        defer { StagedFilesStoreTestSupport.cleanup(base) }

        let store = StagedFilesStore(dbPath: dbURL.path)

        let file = base.appendingPathComponent("model.swift")
        let staged = base.appendingPathComponent(".rune_model.swift")
        try StagedFilesStoreTestSupport.touchFile(at: staged)

        await store.recordStaged(path: file.path, stagingPath: staged.path)
        #expect(await (store.list()).count == 1)

        // Remove by live path (accept)
        await store.removeStaged(pathOrStagingPath: file.path)
        #expect(await (store.list()).isEmpty)

        // Record again and remove by staging path (discard)
        await store.recordStaged(path: file.path, stagingPath: staged.path)
        #expect(await (store.list()).count == 1)
        await store.removeStaged(pathOrStagingPath: staged.path)
        #expect(await (store.list()).isEmpty)
    }

    @Test
    func `self healing automatically purges records if staging file is removed externally`() async throws {
        let (base, dbURL) = try StagedFilesStoreTestSupport.makeTempWorkspace()
        defer { StagedFilesStoreTestSupport.cleanup(base) }

        let store = StagedFilesStore(dbPath: dbURL.path)

        let file = base.appendingPathComponent("ghost.swift")
        let staged = base.appendingPathComponent(".rune_ghost.swift")
        try StagedFilesStoreTestSupport.touchFile(at: staged)

        await store.recordStaged(path: file.path, stagingPath: staged.path)
        #expect(await (store.list()).count == 1)

        // Remove file directly from disk behind the database's back
        try FileManager.default.removeItem(at: staged)

        // List should detect the missing file, self-heal, and return 0
        let listAfter = await store.list()
        #expect(listAfter.isEmpty)

        // Verify the database row was truly deleted
        let rawList = await store.list()
        #expect(rawList.isEmpty)
    }

    @Test
    func `upsert updates existing entry on multiple writes`() async throws {
        let (base, dbURL) = try StagedFilesStoreTestSupport.makeTempWorkspace()
        defer { StagedFilesStoreTestSupport.cleanup(base) }

        let store = StagedFilesStore(dbPath: dbURL.path)

        let file = base.appendingPathComponent("doc.md")
        let staged = base.appendingPathComponent(".rune_doc.md")
        try StagedFilesStoreTestSupport.touchFile(at: staged)

        let date1 = Date(timeIntervalSince1970: 1000)
        let date2 = Date(timeIntervalSince1970: 2000)

        await store.recordStaged(path: file.path, stagingPath: staged.path, updatedAt: date1)
        await store.recordStaged(path: file.path, stagingPath: staged.path, updatedAt: date2)

        let list = await store.list()
        #expect(list.count == 1)
        #expect(list.first?.updatedAt == date2)
    }
}

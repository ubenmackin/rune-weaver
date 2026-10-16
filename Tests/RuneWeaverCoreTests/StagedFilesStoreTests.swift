// Rune Weaver Core Tests — StagedFilesStore SQLite persistence tests.

import Dispatch
import Foundation
@testable import RuneWeaverCore
import Testing
#if canImport(SQLite3)
    import SQLite3
#endif

/// Performs a blocking semaphore wait off the cooperative pool.
private func waitForSemaphore(_ semaphore: DispatchSemaphore, timeout: DispatchTime? = nil) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            if let timeout {
                continuation.resume(returning: semaphore.wait(timeout: timeout) == .success)
            } else {
                semaphore.wait()
                continuation.resume(returning: true)
            }
        }
    }
}

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

    /// Executes one raw statement, bypassing the store so fixture tables
    /// genuinely predate the additive migration instead of being created by
    /// the code under test.
    @discardableResult
    static func execRaw(dbPath: String, sql: String) -> Bool {
        #if canImport(SQLite3)
            let expanded = (dbPath as NSString).expandingTildeInPath
            var handle: OpaquePointer?
            guard expanded.withCString({ sqlite3_open($0, &handle) }) == SQLITE_OK, let handle else { return false }
            defer { sqlite3_close(handle) }
            return sql.withCString { sqlite3_exec(handle, $0, nil, nil, nil) } == SQLITE_OK
        #else
            return false
        #endif
    }

    /// Declared columns for a table, lowercased for case-tolerant checks.
    static func rawColumnNames(dbPath: String, table: String) -> Set<String> {
        #if canImport(SQLite3)
            var names: Set<String> = []
            let expanded = (dbPath as NSString).expandingTildeInPath
            var handle: OpaquePointer?
            guard expanded.withCString({ sqlite3_open($0, &handle) }) == SQLITE_OK, let handle else { return names }
            defer { sqlite3_close(handle) }
            // The table name is a fixed literal from the test body, never user input.
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "PRAGMA table_info(\(table));", -1, &statement, nil) == SQLITE_OK,
                  let statement
            else { return names }
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                if let text = sqlite3_column_text(statement, 1) {
                    names.insert(String(cString: text).lowercased())
                }
            }
            return names
        #else
            return []
        #endif
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
    func `resolve stamps a terminal state and drops the row from the pending inbox`() async throws {
        let (base, dbURL) = try StagedFilesStoreTestSupport.makeTempWorkspace()
        defer { StagedFilesStoreTestSupport.cleanup(base) }

        let store = StagedFilesStore(dbPath: dbURL.path)

        let file = base.appendingPathComponent("model.swift")
        let staged = base.appendingPathComponent(".rune_model.swift")
        try StagedFilesStoreTestSupport.touchFile(at: staged)

        await store.recordStaged(path: file.path, stagingPath: staged.path)
        #expect(await store.state(forPath: file.path) == .pending)
        #expect(await store.list().count == 1)

        await store.resolveStaged(pathOrStagingPath: file.path, resolution: .accepted)
        #expect(await store.state(forPath: file.path) == .accepted)

        // Pending-only inbox: the row survives but is no longer listed.
        #expect(await store.list().isEmpty)

        // A replayed action with a different terminal state is a no-op.
        await store.resolveStaged(pathOrStagingPath: staged.path, resolution: .discarded)
        #expect(await store.state(forPath: file.path) == .accepted)
    }

    @Test
    func `resolve by staging path marks the row terminal and never overwrites it`() async throws {
        let (base, dbURL) = try StagedFilesStoreTestSupport.makeTempWorkspace()
        defer { StagedFilesStoreTestSupport.cleanup(base) }

        let store = StagedFilesStore(dbPath: dbURL.path)

        let file = base.appendingPathComponent("discarded.swift")
        let staged = base.appendingPathComponent(".rune_discarded.swift")
        try StagedFilesStoreTestSupport.touchFile(at: staged)

        await store.recordStaged(path: file.path, stagingPath: staged.path)
        await store.resolveStaged(pathOrStagingPath: staged.path, resolution: .discarded)
        #expect(await store.state(forPath: file.path) == .discarded)

        // Resolving by the live path afterwards never rewrites the answer.
        await store.resolveStaged(pathOrStagingPath: file.path, resolution: .accepted)
        #expect(await store.state(forPath: file.path) == .discarded)
    }

    @Test
    func `resolveStaged reports whether it transitioned a pending row`() async throws {
        let (base, dbURL) = try StagedFilesStoreTestSupport.makeTempWorkspace()
        defer { StagedFilesStoreTestSupport.cleanup(base) }

        let store = StagedFilesStore(dbPath: dbURL.path)

        let file = base.appendingPathComponent("reported.swift")
        let staged = base.appendingPathComponent(".rune_reported.swift")
        try StagedFilesStoreTestSupport.touchFile(at: staged)
        await store.recordStaged(path: file.path, stagingPath: staged.path)

        #expect(await store.resolveStaged(pathOrStagingPath: file.path, resolution: .superseded) == true)
        // A replay transitions nothing, so a live write can tell whether it
        // must report a supersede to live viewers.
        #expect(await store.resolveStaged(pathOrStagingPath: file.path, resolution: .superseded) == false)
        #expect(await store.state(forPath: file.path) == .superseded)

        // Unknown paths and invalid resolutions report no transition either.
        #expect(await store.resolveStaged(pathOrStagingPath: base.appendingPathComponent("absent.swift").path, resolution: .accepted) == false)
        #expect(await store.resolveStaged(pathOrStagingPath: file.path, resolution: .pending) == false)
    }

    @Test
    func `fresh staged write resets a resolved row to pending`() async throws {
        let (base, dbURL) = try StagedFilesStoreTestSupport.makeTempWorkspace()
        defer { StagedFilesStoreTestSupport.cleanup(base) }

        let store = StagedFilesStore(dbPath: dbURL.path)

        let file = base.appendingPathComponent("reset.md")
        let staged = base.appendingPathComponent(".rune_reset.md")
        try StagedFilesStoreTestSupport.touchFile(at: staged)

        await store.recordStaged(path: file.path, stagingPath: staged.path)
        await store.resolveStaged(pathOrStagingPath: file.path, resolution: .accepted)
        #expect(await store.state(forPath: file.path) == .accepted)
        #expect(await store.list().isEmpty)

        // A new edit re-enters review instead of reading as already decided.
        await store.recordStaged(path: file.path, stagingPath: staged.path, updatedAt: Date(timeIntervalSince1970: 2000))
        #expect(await store.state(forPath: file.path) == .pending)
        #expect(await store.list().count == 1)
    }

    @Test
    func `states for paths returns pending and terminal rows and omits unknown paths`() async throws {
        let (base, dbURL) = try StagedFilesStoreTestSupport.makeTempWorkspace()
        defer { StagedFilesStoreTestSupport.cleanup(base) }

        let store = StagedFilesStore(dbPath: dbURL.path)

        let pendingFile = base.appendingPathComponent("pending.swift")
        let pendingStaged = base.appendingPathComponent(".rune_pending.swift")
        try StagedFilesStoreTestSupport.touchFile(at: pendingStaged)
        let decidedFile = base.appendingPathComponent("decided.swift")
        let decidedStaged = base.appendingPathComponent(".rune_decided.swift")
        try StagedFilesStoreTestSupport.touchFile(at: decidedStaged)
        let unknownFile = base.appendingPathComponent("unknown.swift")

        await store.recordStaged(path: pendingFile.path, stagingPath: pendingStaged.path)
        await store.recordStaged(path: decidedFile.path, stagingPath: decidedStaged.path)
        await store.resolveStaged(pathOrStagingPath: decidedFile.path, resolution: .discarded)

        let states = try await store.states(forPaths: [pendingFile.path, decidedFile.path, unknownFile.path])
        #expect(states.count == 2)
        #expect(states[pendingFile.path] == .pending)
        #expect(states[decidedFile.path] == .discarded)
        #expect(states[unknownFile.path] == nil)
    }

    @Test
    func `list prunes a vanished pending staging file but never prunes resolved rows`() async throws {
        let (base, dbURL) = try StagedFilesStoreTestSupport.makeTempWorkspace()
        defer { StagedFilesStoreTestSupport.cleanup(base) }

        let store = StagedFilesStore(dbPath: dbURL.path)

        let pendingFile = base.appendingPathComponent("pending.swift")
        let pendingStaged = base.appendingPathComponent(".rune_pending.swift")
        try StagedFilesStoreTestSupport.touchFile(at: pendingStaged)
        let decidedFile = base.appendingPathComponent("decided.swift")
        let decidedStaged = base.appendingPathComponent(".rune_decided.swift")
        try StagedFilesStoreTestSupport.touchFile(at: decidedStaged)

        await store.recordStaged(path: pendingFile.path, stagingPath: pendingStaged.path)
        await store.recordStaged(path: decidedFile.path, stagingPath: decidedStaged.path)
        await store.resolveStaged(pathOrStagingPath: decidedFile.path, resolution: .accepted)

        // Both staging files vanish behind the store's back.
        try FileManager.default.removeItem(at: pendingStaged)
        try FileManager.default.removeItem(at: decidedStaged)

        #expect(await store.list().isEmpty)
        // The vanished pending row is pruned...
        #expect(await store.state(forPath: pendingFile.path) == nil)
        // ...while the terminal row survives its vanished staging file.
        #expect(await store.state(forPath: decidedFile.path) == .accepted)
    }

    @Test
    func `beginLiveReview starts once and preserves a pending review`() async throws {
        let (base, dbURL) = try StagedFilesStoreTestSupport.makeTempWorkspace()
        defer { StagedFilesStoreTestSupport.cleanup(base) }

        let store = StagedFilesStore(dbPath: dbURL.path)

        let file = base.appendingPathComponent("live.txt")
        let backup = base.appendingPathComponent(".rune_backup_live.txt")
        let otherBackup = base.appendingPathComponent(".rune_backup_other.txt")
        let firstSeen = Date(timeIntervalSince1970: 1000)
        let secondSeen = Date(timeIntervalSince1970: 2000)

        #expect(await store.beginLiveReview(path: file.path, backupPath: backup.path, at: firstSeen) == true)

        let pending = try await store.liveReview(forPath: file.path)
        #expect(pending?.path == file.path)
        #expect(pending?.resolution == nil)
        #expect(pending?.backupPath == backup.path)
        #expect(pending?.createdAt == firstSeen)

        // A pending review owns the row: re-beginning must not replace it.
        #expect(await store.beginLiveReview(path: file.path, backupPath: otherBackup.path, at: secondSeen) == false)
        let preserved = try await store.liveReview(forPath: file.path)
        #expect(preserved?.backupPath == backup.path)
        #expect(preserved?.createdAt == firstSeen)
        #expect(preserved?.resolution == nil)
    }

    @Test
    func `resolveLiveReview transitions pending to terminal once and is a no-op after`() async throws {
        let (base, dbURL) = try StagedFilesStoreTestSupport.makeTempWorkspace()
        defer { StagedFilesStoreTestSupport.cleanup(base) }

        let store = StagedFilesStore(dbPath: dbURL.path)

        let file = base.appendingPathComponent("live.txt")
        let firstSeen = Date(timeIntervalSince1970: 1000)
        let secondSeen = Date(timeIntervalSince1970: 2000)

        #expect(await store.beginLiveReview(path: file.path, backupPath: nil, at: firstSeen) == true)

        // Pending and staged-only markers are not valid live resolutions.
        #expect(await store.resolveLiveReview(path: file.path, resolution: .pending) == false)
        #expect(await store.resolveLiveReview(path: file.path, resolution: .superseded) == false)
        #expect(await store.liveState(forPath: file.path) == .pending)

        #expect(await store.resolveLiveReview(path: file.path, resolution: .accepted, at: secondSeen) == true)
        #expect(await store.liveState(forPath: file.path) == .accepted)

        // A replayed resolution is a no-op and never rewrites the answer.
        #expect(await store.resolveLiveReview(path: file.path, resolution: .discarded) == false)
        #expect(await store.liveState(forPath: file.path) == .accepted)
    }

    @Test
    func `liveReview reports unknown pending and terminal rows and a later begin replaces a decision`() async throws {
        let (base, dbURL) = try StagedFilesStoreTestSupport.makeTempWorkspace()
        defer { StagedFilesStoreTestSupport.cleanup(base) }

        let store = StagedFilesStore(dbPath: dbURL.path)

        let file = base.appendingPathComponent("live.txt")
        let backup = base.appendingPathComponent(".rune_backup_live.txt")
        let otherBackup = base.appendingPathComponent(".rune_backup_other.txt")

        #expect(try await store.liveReview(forPath: file.path) == nil)

        #expect(await store.beginLiveReview(path: file.path, backupPath: backup.path, at: Date(timeIntervalSince1970: 1000)) == true)
        let pending = try await store.liveReview(forPath: file.path)
        #expect(pending?.path == file.path)
        #expect(pending?.resolution == nil)
        #expect(pending?.resolvedAt == nil)

        let resolvedAt = Date(timeIntervalSince1970: 2000)
        #expect(await store.resolveLiveReview(path: file.path, resolution: .reverted, at: resolvedAt) == true)
        let terminal = try await store.liveReview(forPath: file.path)
        #expect(terminal?.resolution == .reverted)
        #expect(terminal?.resolvedAt == resolvedAt)

        // A fresh live write after a decision starts a new pending review.
        #expect(await store.beginLiveReview(path: file.path, backupPath: otherBackup.path, at: Date(timeIntervalSince1970: 3000)) == true)
        let restarted = try await store.liveReview(forPath: file.path)
        #expect(restarted?.resolution == nil)
        #expect(restarted?.backupPath == otherBackup.path)
        #expect(restarted?.resolvedAt == nil)
    }

    @Test
    func `liveStates for paths omits unknown paths`() async throws {
        let (base, dbURL) = try StagedFilesStoreTestSupport.makeTempWorkspace()
        defer { StagedFilesStoreTestSupport.cleanup(base) }

        let store = StagedFilesStore(dbPath: dbURL.path)

        let pendingFile = base.appendingPathComponent("pending.txt")
        let decidedFile = base.appendingPathComponent("decided.txt")
        let unknownFile = base.appendingPathComponent("unknown.txt")

        #expect(await store.beginLiveReview(path: pendingFile.path, backupPath: nil) == true)
        #expect(await store.beginLiveReview(path: decidedFile.path, backupPath: nil) == true)
        #expect(await store.resolveLiveReview(path: decidedFile.path, resolution: .reverted) == true)

        let states = try await store.liveStates(forPaths: [pendingFile.path, decidedFile.path, unknownFile.path])
        #expect(states.count == 2)
        #expect(states[pendingFile.path] == .pending)
        #expect(states[decidedFile.path] == .reverted)
        #expect(states[unknownFile.path] == nil)
    }

    @Test
    func `batched ledger reads throw when the store cannot be opened`() async throws {
        let (base, _) = try StagedFilesStoreTestSupport.makeTempWorkspace()
        defer { StagedFilesStoreTestSupport.cleanup(base) }

        // A regular file where the database's parent directory should be makes
        // the SQLite open fail deterministically.
        let blocker = base.appendingPathComponent("not-a-directory")
        try "blocker".write(to: blocker, atomically: true, encoding: .utf8)
        let store = StagedFilesStore(dbPath: blocker.appendingPathComponent("test.db").path)

        // A store failure must reach the caller as a failure for both ledgers:
        // folding it into an empty map would present unreadable as absent.
        let paths = [base.appendingPathComponent("file.swift").path]
        await #expect(throws: (any Error).self) {
            _ = try await store.states(forPaths: paths)
        }
        await #expect(throws: (any Error).self) {
            _ = try await store.liveStates(forPaths: paths)
        }
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

    @Test
    func `pre-migration staged rows gain the resolution columns and read as pending`() async throws {
        #if canImport(SQLite3)
            let (base, dbURL) = try StagedFilesStoreTestSupport.makeTempWorkspace()
            defer { StagedFilesStoreTestSupport.cleanup(base) }

            let file = base.appendingPathComponent("legacy.swift")
            let staged = base.appendingPathComponent(".rune_legacy.swift")
            try StagedFilesStoreTestSupport.touchFile(at: staged)

            // A database from before the review ledger existed: no resolution
            // columns, one edit already waiting for review.
            #expect(StagedFilesStoreTestSupport.execRaw(
                dbPath: dbURL.path,
                sql: """
                CREATE TABLE staged_files(
                    path TEXT PRIMARY KEY,
                    staging_path TEXT NOT NULL,
                    updated_at REAL NOT NULL
                );
                INSERT INTO staged_files(path, staging_path, updated_at)
                VALUES('\(file.path)', '\(staged.path)', \(Date().timeIntervalSince1970));
                """
            ) == true)

            // The first store operation opens and migrates the legacy database.
            let store = StagedFilesStore(dbPath: dbURL.path)
            #expect(await store.state(forPath: file.path) == .pending)

            let columns = StagedFilesStoreTestSupport.rawColumnNames(dbPath: dbURL.path, table: "staged_files")
            #expect(columns.contains("resolution") == true)
            #expect(columns.contains("resolved_at") == true)

            // The legacy row reaches the inbox and resolves durably.
            #expect(await store.list().count == 1)
            await store.resolveStaged(pathOrStagingPath: file.path, resolution: .accepted)
            #expect(await store.state(forPath: file.path) == .accepted)
            #expect(await store.list().isEmpty)

            // The live review ledger table was created alongside the migration.
            #expect(await store.beginLiveReview(path: file.path, backupPath: nil) == true)
            #expect(await store.liveState(forPath: file.path) == .pending)
        #endif
    }

    @Test
    func `startLiveReview cannot join a decision that is mid-resolution`() async throws {
        let (base, dbURL) = try StagedFilesStoreTestSupport.makeTempWorkspace()
        defer { StagedFilesStoreTestSupport.cleanup(base) }

        let store = StagedFilesStore(dbPath: dbURL.path)
        let file = base.appendingPathComponent("live.txt")
        let backup = base.appendingPathComponent(".rune_backup_live.txt")
        try StagedFilesStoreTestSupport.touchFile(at: backup)
        #expect(await store.beginLiveReview(path: file.path, backupPath: backup.path) == true)

        let decisionEntered = DispatchSemaphore(value: 0)
        let releaseDecision = DispatchSemaphore(value: 0)
        let decision = Task {
            try await store.resolveLiveReviewAtomically(path: file.path) { _ in
                decisionEntered.signal()
                // Hold the serialized lane so the concurrent start must wait for the whole read →
                // mutation → terminal write sequence.
                releaseDecision.wait()
                return .accepted
            }
        }
        // Wait until the decision owns the lane, bounded so a regression fails
        // instead of hanging and releases the lane before bailing out.
        let decisionOwnsLane = await waitForSemaphore(decisionEntered, timeout: .now() + 5)
        guard decisionOwnsLane else {
            releaseDecision.signal()
            Issue.record("The decision never entered its critical section")
            return
        }

        let startFinished = DispatchSemaphore(value: 0)
        let start = Task {
            let outcome = await store.startLiveReview(path: file.path) { _ in
                // Joining mid-resolution would skip the snapshot; reaching
                // this closure proves the start waited for the terminal row.
                .noCopy
            }
            startFinished.signal()
            return outcome
        }
        // The start must not finish while the decision is still resolving.
        #expect(await waitForSemaphore(startFinished, timeout: .now() + 0.5) == false)

        releaseDecision.signal()
        #expect(try await decision.value == .accepted)
        let outcome = await start.value
        // The decision settled first, so the start observes the terminal row
        // and opens a fresh series instead of joining the consumed review.
        #expect(outcome == .started(backupPath: nil))
        #expect(await store.liveState(forPath: file.path) == .pending)
    }

    @Test
    func `a contended start joins the pending row and preserves its copy`() async throws {
        let (base, dbURL) = try StagedFilesStoreTestSupport.makeTempWorkspace()
        defer { StagedFilesStoreTestSupport.cleanup(base) }

        let store = StagedFilesStore(dbPath: dbURL.path)
        let file = base.appendingPathComponent("live.txt")
        let backup = base.appendingPathComponent(".rune_backup_live.txt")
        try StagedFilesStoreTestSupport.touchFile(at: backup)
        #expect(await store.beginLiveReview(path: file.path, backupPath: backup.path) == true)

        // A second start cannot claim the path while a pending row owns it:
        // it joins without running the snapshot and must leave the copy the
        // pending row references exactly where it is.
        let startOutcome = await store.startLiveReview(path: file.path) { _ in
            Issue.record("A pending row must short-circuit the snapshot")
            return .noCopy
        }
        #expect(startOutcome == .joined(backupPath: backup.path))
        #expect(FileManager.default.fileExists(atPath: backup.path))
        #expect(try String(contentsOf: backup, encoding: .utf8) == "test")

        // `beginLiveReview` reports the same contention as a no-op and
        // likewise never removes the copy.
        #expect(await store.beginLiveReview(path: file.path, backupPath: nil) == false)
        #expect(FileManager.default.fileExists(atPath: backup.path))
        let row = try await store.liveReview(forPath: file.path)
        #expect(row?.resolution == nil)
        #expect(row?.backupPath == backup.path)
    }

    @Test
    func `a failed row write removes the captured copy when no pending row owns it`() async throws {
        let (base, dbURL) = try StagedFilesStoreTestSupport.makeTempWorkspace()
        defer { StagedFilesStoreTestSupport.cleanup(base) }

        let store = StagedFilesStore(dbPath: dbURL.path)
        let file = base.appendingPathComponent("live.txt")
        let backup = base.appendingPathComponent(".rune_backup_live.txt")

        // Warm the ledger so the review table exists before the trigger lands.
        #expect(await store.liveState(forPath: file.path) == nil)
        // A BEFORE INSERT trigger makes only the review row write fail while
        // the ledger stays readable: the re-read proves no pending row owns
        // the captured copy, so the start removes it instead of orphaning it.
        let triggerSQL = """
        CREATE TRIGGER refuse_live_review_insert BEFORE INSERT ON live_reviews
        BEGIN
            SELECT RAISE(ABORT, 'insert refused');
        END;
        """
        let triggerCreated = StagedFilesStoreTestSupport.execRaw(dbPath: dbURL.path, sql: triggerSQL)
        #expect(triggerCreated)

        let outcome = await store.startLiveReview(path: file.path) { _ in
            do {
                try Data("captured".utf8).write(to: backup, options: .atomic)
                return .captured(backupPath: backup.path)
            } catch {
                return .refused(reason: error.localizedDescription)
            }
        }

        #expect(outcome == .unreadable)
        #expect(!FileManager.default.fileExists(atPath: backup.path))
        #expect(try await store.liveReview(forPath: file.path) == nil)
    }
}

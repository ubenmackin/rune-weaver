// Rune Weaver Server Tests — File staging routes, live review resolution
// routes, batch review-status queries, and their manager helpers.

import Foundation
import NIOWebSocket
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

        // The pending inbox stays empty (resolved rows are filtered out) while
        // the row survives as a durable terminal acceptance.
        let remaining = await store.list()
        #expect(remaining.isEmpty)
        #expect(await store.state(forPath: liveFile.path) == .accepted)
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

        // The pending inbox stays empty (resolved rows are filtered out) while
        // the row survives as a durable terminal discard.
        let remaining = await store.list()
        #expect(remaining.isEmpty)
        #expect(await store.state(forPath: liveFile.path) == .discarded)
    }

    @Test
    func `accept and discard refuse a case-folded rollback-copy staging name`() async throws {
        let (base, ws) = try FileRoutesTestSupport.makeTempWorkspace()
        defer { FileRoutesTestSupport.cleanup(base) }
        let store = StagedFilesStore(dbPath: ws.appendingPathComponent("staged.db").path)

        let liveFile = ws.appendingPathComponent("notes.txt")
        try FileRoutesTestSupport.write("Edited Version\n", at: liveFile)
        // The differently-cased rollback copy names the same artifact on the
        // default case-folding volume, so both direct mutations must refuse it
        // instead of moving or removing a pending review's restore point.
        let backupFile = ws.appendingPathComponent(".rune_BACKUP_notes.txt")
        try FileRoutesTestSupport.write("Original Version\n", at: backupFile)
        _ = await store.beginLiveReview(path: liveFile.path, backupPath: backupFile.path)

        let filesConfig = FilesConfig(allowRoots: [ws.path])
        do {
            try await StagedFilesManager.accept(
                livePath: ws.appendingPathComponent("BACKUP_notes.txt").path,
                stagingPath: backupFile.path,
                filesConfig: filesConfig,
                store: store
            )
            Issue.record("Expected accept to refuse the case-folded rollback staging name")
        } catch let abort as Abort {
            #expect(abort.status == .forbidden)
        }
        do {
            try await StagedFilesManager.discard(stagingPath: backupFile.path, filesConfig: filesConfig, store: store)
            Issue.record("Expected discard to refuse the case-folded rollback staging name")
        } catch let abort as Abort {
            #expect(abort.status == .forbidden)
        }

        #expect(try String(contentsOf: backupFile, encoding: .utf8) == "Original Version\n")
        #expect(try String(contentsOf: liveFile, encoding: .utf8) == "Edited Version\n")
        #expect(await store.liveState(forPath: liveFile.path) == .pending)
    }
}

@Suite("LiveReviewManager")
struct LiveReviewManagerTests {
    @Test
    func `accept keeps the live bytes, clears the rollback copy, and reads accepted`() async throws {
        let (base, ws) = try FileRoutesTestSupport.makeTempWorkspace()
        defer { FileRoutesTestSupport.cleanup(base) }
        let store = StagedFilesStore(dbPath: ws.appendingPathComponent("staged.db").path)

        let liveFile = ws.appendingPathComponent("Service.swift")
        try FileRoutesTestSupport.write("Edited Version\n", at: liveFile)
        let backupFile = ws.appendingPathComponent(".rune_backup_Service.swift")
        try FileRoutesTestSupport.write("Original Version\n", at: backupFile)
        _ = await store.beginLiveReview(path: liveFile.path, backupPath: backupFile.path)

        // Temp workspace sits outside the default home root, so scope the
        // fail-closed guard to it; denied paths elsewhere still refuse.
        let state = try await LiveReviewManager.accept(
            livePath: liveFile.path,
            filesConfig: FilesConfig(allowRoots: [ws.path]),
            store: store
        )

        #expect(state == "accepted")
        let liveContent = try String(contentsOf: liveFile, encoding: .utf8)
        #expect(liveContent == "Edited Version\n")
        #expect(!FileManager.default.fileExists(atPath: backupFile.path))
        #expect(await store.liveState(forPath: liveFile.path) == .accepted)
    }

    @Test
    func `accept tolerates a rollback copy an out-of-band delete removed`() async throws {
        let (base, ws) = try FileRoutesTestSupport.makeTempWorkspace()
        defer { FileRoutesTestSupport.cleanup(base) }
        let store = StagedFilesStore(dbPath: ws.appendingPathComponent("staged.db").path)

        let liveFile = ws.appendingPathComponent("Kept.swift")
        try FileRoutesTestSupport.write("Kept Version\n", at: liveFile)
        // The row records a copy that is already gone: accept is the keep path,
        // so the review must still settle instead of stranding pending.
        let backupFile = ws.appendingPathComponent(".rune_backup_Kept.swift")
        _ = await store.beginLiveReview(path: liveFile.path, backupPath: backupFile.path)

        let state = try await LiveReviewManager.accept(
            livePath: liveFile.path,
            filesConfig: FilesConfig(allowRoots: [ws.path]),
            store: store
        )

        #expect(state == "accepted")
        #expect(FileManager.default.fileExists(atPath: liveFile.path))
        #expect(await store.liveState(forPath: liveFile.path) == .accepted)
    }

    @Test
    func `decline restores the original bytes, clears the rollback copy, and reads reverted`() async throws {
        let (base, ws) = try FileRoutesTestSupport.makeTempWorkspace()
        defer { FileRoutesTestSupport.cleanup(base) }
        let store = StagedFilesStore(dbPath: ws.appendingPathComponent("staged.db").path)

        let liveFile = ws.appendingPathComponent("Service.swift")
        try FileRoutesTestSupport.write("Edited Version\n", at: liveFile)
        let backupFile = ws.appendingPathComponent(".rune_backup_Service.swift")
        try FileRoutesTestSupport.write("Original Version\n", at: backupFile)
        _ = await store.beginLiveReview(path: liveFile.path, backupPath: backupFile.path)

        let state = try await LiveReviewManager.decline(
            livePath: liveFile.path,
            filesConfig: FilesConfig(allowRoots: [ws.path]),
            store: store
        )

        #expect(state == "reverted")
        let liveContent = try String(contentsOf: liveFile, encoding: .utf8)
        #expect(liveContent == "Original Version\n")
        #expect(!FileManager.default.fileExists(atPath: backupFile.path))
        #expect(await store.liveState(forPath: liveFile.path) == .reverted)
    }

    @Test
    func `decline on a new-file review deletes the file and reads discarded`() async throws {
        let (base, ws) = try FileRoutesTestSupport.makeTempWorkspace()
        defer { FileRoutesTestSupport.cleanup(base) }
        let store = StagedFilesStore(dbPath: ws.appendingPathComponent("staged.db").path)

        let liveFile = ws.appendingPathComponent("BrandNew.swift")
        try FileRoutesTestSupport.write("Brand New\n", at: liveFile)
        // A new-file review owns no rollback copy, so its decline removes the
        // created file instead of restoring anything.
        _ = await store.beginLiveReview(path: liveFile.path, backupPath: nil)

        let state = try await LiveReviewManager.decline(
            livePath: liveFile.path,
            filesConfig: FilesConfig(allowRoots: [ws.path]),
            store: store
        )

        #expect(state == "discarded")
        #expect(!FileManager.default.fileExists(atPath: liveFile.path))
        #expect(await store.liveState(forPath: liveFile.path) == .discarded)
    }

    @Test
    func `decline refuses a missing rollback copy and leaves the row pending`() async throws {
        let (base, ws) = try FileRoutesTestSupport.makeTempWorkspace()
        defer { FileRoutesTestSupport.cleanup(base) }
        let store = StagedFilesStore(dbPath: ws.appendingPathComponent("staged.db").path)

        let liveFile = ws.appendingPathComponent("Guarded.swift")
        try FileRoutesTestSupport.write("Edited Version\n", at: liveFile)
        let backupFile = ws.appendingPathComponent(".rune_backup_Guarded.swift")
        _ = await store.beginLiveReview(path: liveFile.path, backupPath: backupFile.path)

        do {
            _ = try await LiveReviewManager.decline(
                livePath: liveFile.path,
                filesConfig: FilesConfig(allowRoots: [ws.path]),
                store: store
            )
            Issue.record("Expected notFound when the rollback copy is missing")
        } catch let abort as Abort {
            #expect(abort.status == .notFound)
            #expect(abort.reason == "Rollback copy not found for \(liveFile.path).")
        }

        // The refusal leaves the live file and the row untouched so restoring
        // the copy lets the owner retry instead of losing the review.
        let liveContent = try String(contentsOf: liveFile, encoding: .utf8)
        #expect(liveContent == "Edited Version\n")
        #expect(await store.liveState(forPath: liveFile.path) == .pending)
    }

    @Test
    func `a symlinked rollback copy fails the decision closed instead of consuming its target`() async throws {
        let (base, ws) = try FileRoutesTestSupport.makeTempWorkspace()
        defer { FileRoutesTestSupport.cleanup(base) }
        let store = StagedFilesStore(dbPath: ws.appendingPathComponent("staged.db").path)

        let liveFile = ws.appendingPathComponent("Service.swift")
        try FileRoutesTestSupport.write("Edited Version\n", at: liveFile)
        let protected = ws.appendingPathComponent("protected.txt")
        try FileRoutesTestSupport.write("Protected Version\n", at: protected)
        // The pending row records the derived sibling, but the entry at that
        // path is a link onto another file. A decision must never resolve the
        // reserved name and delete or consume the link's target.
        let backupFile = ws.appendingPathComponent(".rune_backup_Service.swift")
        try FileManager.default.createSymbolicLink(at: backupFile, withDestinationURL: protected)
        _ = await store.beginLiveReview(path: liveFile.path, backupPath: backupFile.path)

        let filesConfig = FilesConfig(allowRoots: [ws.path])
        for isAccept in [true, false] {
            do {
                if isAccept {
                    _ = try await LiveReviewManager.accept(livePath: liveFile.path, filesConfig: filesConfig, store: store)
                } else {
                    _ = try await LiveReviewManager.decline(livePath: liveFile.path, filesConfig: filesConfig, store: store)
                }
                Issue.record("Expected the symlinked rollback copy to fail the decision closed")
            } catch {
                // Any refusal shape is acceptable; the invariant is that the
                // link's target survives and the review stays pending.
            }
        }

        #expect(FileManager.default.fileExists(atPath: protected.path))
        #expect(try String(contentsOf: protected, encoding: .utf8) == "Protected Version\n")
        #expect(try String(contentsOf: liveFile, encoding: .utf8) == "Edited Version\n")
        #expect(await store.liveState(forPath: liveFile.path) == .pending)
    }

    @Test
    func `either decision refuses a missing or already-terminal row`() async throws {
        let (base, ws) = try FileRoutesTestSupport.makeTempWorkspace()
        defer { FileRoutesTestSupport.cleanup(base) }
        let store = StagedFilesStore(dbPath: ws.appendingPathComponent("staged.db").path)
        let filesConfig = FilesConfig(allowRoots: [ws.path])

        let liveFile = ws.appendingPathComponent("Unreviewed.swift")
        try FileRoutesTestSupport.write("Untouched\n", at: liveFile)

        for isAccept in [true, false] {
            do {
                if isAccept {
                    _ = try await LiveReviewManager.accept(livePath: liveFile.path, filesConfig: filesConfig, store: store)
                } else {
                    _ = try await LiveReviewManager.decline(livePath: liveFile.path, filesConfig: filesConfig, store: store)
                }
                Issue.record("Expected notFound with no pending row")
            } catch let abort as Abort {
                #expect(abort.status == .notFound)
                #expect(abort.reason == "No pending live review for \(liveFile.path).")
            }
        }

        // A terminal row is not pending either, so a replayed decision refuses
        // rather than resurrecting the settled review.
        _ = await store.beginLiveReview(path: liveFile.path, backupPath: nil)
        _ = await store.resolveLiveReview(path: liveFile.path, resolution: .discarded)
        do {
            _ = try await LiveReviewManager.accept(livePath: liveFile.path, filesConfig: filesConfig, store: store)
            Issue.record("Expected notFound for an already-terminal row")
        } catch let abort as Abort {
            #expect(abort.status == .notFound)
        }

        #expect(FileManager.default.fileExists(atPath: liveFile.path))
    }
}

/// Stub provider satisfying orchestrator construction; the review-status
/// suites never run a chat turn, so a finished empty stream is all it owes.
private final class FileRouteStubLLM: LLMProvider, Sendable {
    /// Stable test model metadata.
    let modelInfo = ModelInfo(name: "file-route-fixture", provider: "test", contextLength: 2048)

    /// Returns an immediately finished empty stream.
    func chat(messages _: [Message], tools _: [any Tool]) -> AsyncStream<LLMResponse> {
        AsyncStream { $0.finish() }
    }

    /// Unused embeddings stub.
    func embeddings(text _: [String]) async throws -> [[Float]] {
        []
    }
}

/// Live collaborators for one review-status route scenario.
private struct FileReviewStatusHarness {
    /// Configured application under test.
    let app: Application
    /// Shared engine context serving the routes.
    let context: ServerContext
    /// Temporary root the test derives request paths from. It stays empty, so
    /// a 200 for any path under it proves the lookup never touched the filesystem.
    let root: URL
}

/// Builds a configured application sharing an isolated staged-files ledger.
///
/// The context carries an explicit store over a temporary database so review
/// rows never touch the real engine data directory, and the surface under test
/// is the same registered Vapor application the engine serves.
/// - Parameters:
///   - stagedFilesStore: Optional factory receiving the harness's temporary
///     base directory, so a test can inject a deliberately unreadable ledger;
///     nil builds the normal store over the shared episodes database.
///   - body: Test body receiving the harness.
/// - Returns: Whatever `body` returns.
private func withFileRouteApp<T>(
    stagedFilesStore: (@Sendable (URL) throws -> StagedFilesStore)? = nil,
    _ body: (FileReviewStatusHarness) async throws -> T
) async throws -> T {
    let (base, workspace) = try FileRoutesTestSupport.makeTempWorkspace()
    let app = try await Application.make(.testing)
    do {
        let dbPath = base.appendingPathComponent("episodes.db").path
        let conversations = ConversationManager()
        let gate = PermissionGate()
        let approvals = ApprovalQueue(permissionGate: gate)
        let bus = ToolBus(permissionGate: gate)
        let memory = MemoryEngine(
            episodesDBPath: dbPath,
            vectorDBPath: base.appendingPathComponent("vectors").path,
            profilePath: base.appendingPathComponent("profile.json").path
        )
        let orchestrator = Orchestrator(
            conversations: conversations,
            toolBus: bus,
            llm: FileRouteStubLLM(),
            memoryEngine: memory
        )
        let staged = if let stagedFilesStore {
            try stagedFilesStore(base)
        } else {
            StagedFilesStore(dbPath: dbPath)
        }
        let context = ServerContext(
            conversations: conversations,
            toolBus: bus,
            orchestrator: orchestrator,
            memoryEngine: memory,
            permissionGate: gate,
            approvals: approvals,
            scheduler: SchedulerStore(),
            runs: RunLogStore(),
            hub: WSHub(),
            pluginStore: ToolRegistryStore(dbPath: dbPath),
            toolStates: ToolStateStore(dbPath: dbPath),
            stagedFiles: staged
        )
        try configureRuneWeaver(app, context: context)
        let value = try await body(FileReviewStatusHarness(app: app, context: context, root: workspace))
        try await app.asyncShutdown()
        try? FileManager.default.removeItem(at: base)
        return value
    } catch {
        try? await app.asyncShutdown()
        try? FileManager.default.removeItem(at: base)
        throw error
    }
}

/// Sends one request with an encoded body through the full registered surface.
/// - Parameters:
///   - app: Configured application.
///   - method: HTTP method.
///   - path: Request path.
///   - body: Encodable request body.
/// - Returns: Route response.
private func fileRouteRequest(
    app: Application,
    method: HTTPMethod,
    path: String,
    body: some Content
) async throws -> Response {
    let request = Request(
        application: app,
        method: method,
        url: URI(string: path),
        on: app.eventLoopGroup.next()
    )
    try request.content.encode(body)
    return try await app.responder.respond(to: request).get()
}

@Suite("File Review Status Route")
struct FileReviewStatusRouteTests {
    @Test
    func `Both maps echo every requested path with ledger states or unknown`() async throws {
        try await withFileRouteApp { harness in
            let pendingStaged = harness.root.appendingPathComponent("Pending.swift").path
            let acceptedStaged = harness.root.appendingPathComponent("Accepted.swift").path
            let pendingLive = harness.root.appendingPathComponent("LivePending.swift").path
            let revertedLive = harness.root.appendingPathComponent("LiveReverted.swift").path
            // Absent from both ledgers and from disk: a 200 for this key proves
            // the lookup answered from SQLite instead of stat-ing the file.
            let unknown = harness.root.appendingPathComponent("Absent.swift").path

            let store = harness.context.stagedFiles
            await store.recordStaged(
                path: pendingStaged,
                stagingPath: harness.root.appendingPathComponent(".rune_Pending.swift").path
            )
            await store.recordStaged(
                path: acceptedStaged,
                stagingPath: harness.root.appendingPathComponent(".rune_Accepted.swift").path
            )
            await store.resolveStaged(pathOrStagingPath: acceptedStaged, resolution: .accepted)
            _ = await store.beginLiveReview(path: pendingLive, backupPath: nil)
            _ = await store.beginLiveReview(path: revertedLive, backupPath: nil)
            _ = await store.resolveLiveReview(path: revertedLive, resolution: .reverted)

            let requested = [pendingStaged, acceptedStaged, pendingLive, revertedLive, unknown]
            let response = try await fileRouteRequest(
                app: harness.app,
                method: .POST,
                path: "/files/review-status",
                body: ReviewStatusRequest(paths: requested)
            )
            #expect(response.status == .ok)
            let decoded = try response.content.decode(ReviewStatusResponse.self)
            // Both maps carry a key for every requested path, so staged reads
            // pending/accepted/unknown and live reads pending/reverted/unknown
            // without either ledger leaking into the other.
            #expect(decoded.stagedStates == [
                pendingStaged: "pending",
                acceptedStaged: "accepted",
                pendingLive: "unknown",
                revertedLive: "unknown",
                unknown: "unknown"
            ])
            #expect(decoded.liveStates == [
                pendingStaged: "unknown",
                acceptedStaged: "unknown",
                pendingLive: "pending",
                revertedLive: "reverted",
                unknown: "unknown"
            ])
            #expect(!FileManager.default.fileExists(atPath: unknown))
        }
    }

    @Test
    func `Empty path list is rejected`() async throws {
        try await withFileRouteApp { harness in
            let response = try await fileRouteRequest(
                app: harness.app,
                method: .POST,
                path: "/files/review-status",
                body: ReviewStatusRequest(paths: [])
            )
            #expect(response.status == .badRequest)
            #expect((response.body.string ?? "").contains("1 to 200 non-empty paths"))
        }
    }

    @Test
    func `Path list bound is enforced at 200`() async throws {
        try await withFileRouteApp { harness in
            // The bound is inclusive: 200 requested keys answer, 201 refuse.
            let withinBound = (0 ..< 200).map { harness.root.appendingPathComponent("File\($0).swift").path }
            let accepted = try await fileRouteRequest(
                app: harness.app,
                method: .POST,
                path: "/files/review-status",
                body: ReviewStatusRequest(paths: withinBound)
            )
            #expect(accepted.status == .ok)
            let decoded = try accepted.content.decode(ReviewStatusResponse.self)
            #expect(decoded.stagedStates.count == 200)
            #expect(decoded.liveStates.count == 200)

            let beyondBound = withinBound + [harness.root.appendingPathComponent("Extra.swift").path]
            let rejected = try await fileRouteRequest(
                app: harness.app,
                method: .POST,
                path: "/files/review-status",
                body: ReviewStatusRequest(paths: beyondBound)
            )
            #expect(rejected.status == .badRequest)
            #expect((rejected.body.string ?? "").contains("1 to 200 non-empty paths"))
        }
    }

    @Test
    func `Blank path entry is rejected`() async throws {
        try await withFileRouteApp { harness in
            let valid = harness.root.appendingPathComponent("Fine.swift").path
            // A whitespace-only entry trims to empty, so the whole batch fails
            // instead of keying the maps under a string no client can match.
            for paths in [["   "], [valid, "\t"]] {
                let response = try await fileRouteRequest(
                    app: harness.app,
                    method: .POST,
                    path: "/files/review-status",
                    body: ReviewStatusRequest(paths: paths)
                )
                #expect(response.status == .badRequest)
                #expect((response.body.string ?? "").contains("1 to 200 non-empty paths"))
            }
        }
    }

    @Test
    func `An unreadable ledger fails the status query with a non-2xx`() async throws {
        try await withFileRouteApp(stagedFilesStore: { base in
            // A regular file where the database's parent directory should be
            // makes every SQLite open fail deterministically.
            let blocker = base.appendingPathComponent("not-a-directory")
            try Data("blocker".utf8).write(to: blocker)
            return StagedFilesStore(dbPath: blocker.appendingPathComponent("episodes.db").path)
        }) { harness in
            let response = try await fileRouteRequest(
                app: harness.app,
                method: .POST,
                path: "/files/review-status",
                body: ReviewStatusRequest(paths: [harness.root.appendingPathComponent("Pending.swift").path])
            )
            // A store failure must not answer 200 with every path "unknown":
            // the client would render a still-pending review as a settled
            // no-action card, while a non-2xx keeps its pending UI in place.
            #expect(response.status == .internalServerError)
            #expect((response.body.string ?? "").contains("Could not read the review ledger"))
        }
    }
}

/// Recording socket capturing hub broadcasts without a live handshake.
private actor FileActionRecordingSocket: WSConnectionSocket {
    /// Frames delivered to this connection.
    private(set) var sent: [String] = []

    /// Records one frame.
    func send(_ text: String) async throws {
        sent.append(text)
    }

    /// Ignored; these tests never close the connection.
    func close(code _: WebSocketErrorCode) async throws {}
}

/// Polls a recording socket until it captures at least one frame or the budget expires.
/// - Parameter socket: Recording socket under test.
/// - Returns: Frames captured at the deadline.
private func waitForFileActionFrames(_ socket: FileActionRecordingSocket) async -> [String] {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        let frames = await socket.sent
        if !frames.isEmpty {
            return frames
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return await socket.sent
}

@Suite("Live Review Routes")
struct LiveReviewRouteTests {
    @Test
    func `Accept route keeps the live file, clears the copy, resolves, and broadcasts`() async throws {
        try await withFileRouteApp { harness in
            // Scope the fail-closed guard to the temp workspace; denied paths
            // elsewhere still refuse.
            harness.context.filesConfig = FilesConfig(allowRoots: [harness.root.path])
            let store = harness.context.stagedFiles
            let liveFile = harness.root.appendingPathComponent("Live.swift")
            let backupFile = harness.root.appendingPathComponent(".rune_backup_Live.swift")
            try FileRoutesTestSupport.write("Edited Version\n", at: liveFile)
            try FileRoutesTestSupport.write("Original Version\n", at: backupFile)
            _ = await store.beginLiveReview(path: liveFile.path, backupPath: backupFile.path)
            let socket = FileActionRecordingSocket()
            _ = await harness.context.hub.add(id: UUID(), box: socket)

            let response = try await fileRouteRequest(
                app: harness.app,
                method: .POST,
                path: "/files/live-accept",
                body: FileActionRequest(path: liveFile.path)
            )
            #expect(response.status == .ok)
            let decoded = try response.content.decode(FileActionResponse.self)
            #expect(decoded.status == "accepted")
            #expect(decoded.count == 1)

            let content = try String(contentsOf: liveFile, encoding: .utf8)
            #expect(content == "Edited Version\n")
            #expect(!FileManager.default.fileExists(atPath: backupFile.path))
            #expect(await store.liveState(forPath: liveFile.path) == .accepted)

            // The detached frame carries the same terminal state the ledger
            // holds so a reloaded viewer reconciles without refetching.
            let frames = await waitForFileActionFrames(socket)
            let decodedFrames = try frames.map { try JSONDecoder().decode(WSFileActionEvent.self, from: Data($0.utf8)) }
            #expect(decodedFrames.contains { $0.type == "live_resolved" && $0.path == liveFile.path && $0.state == "accepted" })
        }
    }

    @Test
    func `Decline route restores the rollback copy and broadcasts reverted`() async throws {
        try await withFileRouteApp { harness in
            harness.context.filesConfig = FilesConfig(allowRoots: [harness.root.path])
            let store = harness.context.stagedFiles
            let liveFile = harness.root.appendingPathComponent("Rollback.swift")
            let backupFile = harness.root.appendingPathComponent(".rune_backup_Rollback.swift")
            try FileRoutesTestSupport.write("Edited Version\n", at: liveFile)
            try FileRoutesTestSupport.write("Original Version\n", at: backupFile)
            _ = await store.beginLiveReview(path: liveFile.path, backupPath: backupFile.path)
            let socket = FileActionRecordingSocket()
            _ = await harness.context.hub.add(id: UUID(), box: socket)

            let response = try await fileRouteRequest(
                app: harness.app,
                method: .POST,
                path: "/files/live-decline",
                body: FileActionRequest(path: liveFile.path)
            )
            #expect(response.status == .ok)
            let decoded = try response.content.decode(FileActionResponse.self)
            #expect(decoded.status == "reverted")
            #expect(decoded.count == 1)

            let content = try String(contentsOf: liveFile, encoding: .utf8)
            #expect(content == "Original Version\n")
            #expect(!FileManager.default.fileExists(atPath: backupFile.path))
            #expect(await store.liveState(forPath: liveFile.path) == .reverted)

            let frames = await waitForFileActionFrames(socket)
            let decodedFrames = try frames.map { try JSONDecoder().decode(WSFileActionEvent.self, from: Data($0.utf8)) }
            #expect(decodedFrames.contains { $0.type == "live_resolved" && $0.path == liveFile.path && $0.state == "reverted" })
        }
    }

    @Test
    func `Decline route discards a new-file review and broadcasts discarded`() async throws {
        try await withFileRouteApp { harness in
            harness.context.filesConfig = FilesConfig(allowRoots: [harness.root.path])
            let store = harness.context.stagedFiles
            let liveFile = harness.root.appendingPathComponent("Created.swift")
            try FileRoutesTestSupport.write("Brand New\n", at: liveFile)
            _ = await store.beginLiveReview(path: liveFile.path, backupPath: nil)
            let socket = FileActionRecordingSocket()
            _ = await harness.context.hub.add(id: UUID(), box: socket)

            let response = try await fileRouteRequest(
                app: harness.app,
                method: .POST,
                path: "/files/live-decline",
                body: FileActionRequest(path: liveFile.path)
            )
            #expect(response.status == .ok)
            let decoded = try response.content.decode(FileActionResponse.self)
            #expect(decoded.status == "discarded")
            #expect(decoded.count == 1)

            #expect(!FileManager.default.fileExists(atPath: liveFile.path))
            #expect(await store.liveState(forPath: liveFile.path) == .discarded)

            let frames = await waitForFileActionFrames(socket)
            let decodedFrames = try frames.map { try JSONDecoder().decode(WSFileActionEvent.self, from: Data($0.utf8)) }
            #expect(decodedFrames.contains { $0.type == "live_resolved" && $0.path == liveFile.path && $0.state == "discarded" })
        }
    }

    @Test
    func `Decline route refuses a missing rollback copy and leaves the row pending`() async throws {
        try await withFileRouteApp { harness in
            harness.context.filesConfig = FilesConfig(allowRoots: [harness.root.path])
            let store = harness.context.stagedFiles
            let liveFile = harness.root.appendingPathComponent("MissingCopy.swift")
            let backupFile = harness.root.appendingPathComponent(".rune_backup_MissingCopy.swift")
            try FileRoutesTestSupport.write("Edited Version\n", at: liveFile)
            // The row carries a copy path but no copy exists on disk, so a
            // restore cannot invent one; the review must stay pending.
            _ = await store.beginLiveReview(path: liveFile.path, backupPath: backupFile.path)

            let response = try await fileRouteRequest(
                app: harness.app,
                method: .POST,
                path: "/files/live-decline",
                body: FileActionRequest(path: liveFile.path)
            )
            #expect(response.status == .notFound)
            #expect((response.body.string ?? "").contains("Rollback copy not found"))

            let content = try String(contentsOf: liveFile, encoding: .utf8)
            #expect(content == "Edited Version\n")
            #expect(await store.liveState(forPath: liveFile.path) == .pending)
        }
    }

    @Test
    func `Either route refuses a path with no pending review`() async throws {
        try await withFileRouteApp { harness in
            harness.context.filesConfig = FilesConfig(allowRoots: [harness.root.path])
            let store = harness.context.stagedFiles
            let liveFile = harness.root.appendingPathComponent("Unreviewed.swift")
            try FileRoutesTestSupport.write("Untouched\n", at: liveFile)

            for route in ["/files/live-accept", "/files/live-decline"] {
                let response = try await fileRouteRequest(
                    app: harness.app,
                    method: .POST,
                    path: route,
                    body: FileActionRequest(path: liveFile.path)
                )
                #expect(response.status == .notFound)
                #expect((response.body.string ?? "").contains("No pending live review"))
            }

            // A settled row is not pending either, so a replay refuses instead
            // of re-deciding the file.
            _ = await store.beginLiveReview(path: liveFile.path, backupPath: nil)
            _ = await store.resolveLiveReview(path: liveFile.path, resolution: .accepted)
            let replay = try await fileRouteRequest(
                app: harness.app,
                method: .POST,
                path: "/files/live-accept",
                body: FileActionRequest(path: liveFile.path)
            )
            #expect(replay.status == .notFound)

            let content = try String(contentsOf: liveFile, encoding: .utf8)
            #expect(content == "Untouched\n")
        }
    }

    @Test
    func `Either route rejects bulk all true and a missing path`() async throws {
        try await withFileRouteApp { harness in
            for route in ["/files/live-accept", "/files/live-decline"] {
                let bulk = try await fileRouteRequest(
                    app: harness.app,
                    method: .POST,
                    path: route,
                    body: FileActionRequest(all: true)
                )
                #expect(bulk.status == .badRequest)
                #expect((bulk.body.string ?? "").contains("Live reviews resolve one file at a time."))

                let blank = try await fileRouteRequest(
                    app: harness.app,
                    method: .POST,
                    path: route,
                    body: FileActionRequest(path: "   ")
                )
                #expect(blank.status == .badRequest)
                #expect((blank.body.string ?? "").contains("requires a 'path'"))
            }
        }
    }

    @Test
    func `Denied live path fails closed with no file change on either route`() async throws {
        try await withFileRouteApp { harness in
            harness.context.filesConfig = FilesConfig(allowRoots: [harness.root.path])
            let store = harness.context.stagedFiles
            // Sibling directory outside the allow root, with both sides seeded
            // so the refusal must happen before the copy is cleared or restored.
            let outsideDir = harness.root.deletingLastPathComponent().appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
            let liveFile = outsideDir.appendingPathComponent("Outside.swift")
            let backupFile = outsideDir.appendingPathComponent(".rune_backup_Outside.swift")
            try FileRoutesTestSupport.write("Edited Version\n", at: liveFile)
            try FileRoutesTestSupport.write("Original Version\n", at: backupFile)
            _ = await store.beginLiveReview(path: liveFile.path, backupPath: backupFile.path)

            for route in ["/files/live-accept", "/files/live-decline"] {
                let response = try await fileRouteRequest(
                    app: harness.app,
                    method: .POST,
                    path: route,
                    body: FileActionRequest(path: liveFile.path)
                )
                #expect(response.status == .forbidden)
            }

            let content = try String(contentsOf: liveFile, encoding: .utf8)
            #expect(content == "Edited Version\n")
            #expect(FileManager.default.fileExists(atPath: backupFile.path))
            #expect(await store.liveState(forPath: liveFile.path) == .pending)
        }
    }

    @Test
    func `Deny-pattern live path fails closed with no file change`() async throws {
        try await withFileRouteApp { harness in
            harness.context.filesConfig = FilesConfig(denyPatterns: ["*.secret"], allowRoots: [harness.root.path])
            let store = harness.context.stagedFiles
            let liveFile = harness.root.appendingPathComponent("notes.secret")
            let backupFile = harness.root.appendingPathComponent(".rune_backup_notes.secret")
            try FileRoutesTestSupport.write("Sensitive\n", at: liveFile)
            try FileRoutesTestSupport.write("Original\n", at: backupFile)
            _ = await store.beginLiveReview(path: liveFile.path, backupPath: backupFile.path)

            for route in ["/files/live-accept", "/files/live-decline"] {
                let response = try await fileRouteRequest(
                    app: harness.app,
                    method: .POST,
                    path: route,
                    body: FileActionRequest(path: liveFile.path)
                )
                #expect(response.status == .forbidden)
            }

            let content = try String(contentsOf: liveFile, encoding: .utf8)
            #expect(content == "Sensitive\n")
            #expect(FileManager.default.fileExists(atPath: backupFile.path))
            #expect(await store.liveState(forPath: liveFile.path) == .pending)
        }
    }

    @Test
    func `Denied rollback sibling fails closed before the decision mutates`() async throws {
        try await withFileRouteApp { harness in
            // The live path itself is allowed; only the derived rollback sibling
            // is denied, so a refusal here proves both sides are vetted.
            harness.context.filesConfig = FilesConfig(denyPatterns: [".rune_backup_*"], allowRoots: [harness.root.path])
            let store = harness.context.stagedFiles
            let liveFile = harness.root.appendingPathComponent("Guarded.swift")
            let backupFile = harness.root.appendingPathComponent(".rune_backup_Guarded.swift")
            try FileRoutesTestSupport.write("Edited Version\n", at: liveFile)
            try FileRoutesTestSupport.write("Original Version\n", at: backupFile)
            _ = await store.beginLiveReview(path: liveFile.path, backupPath: backupFile.path)

            for route in ["/files/live-accept", "/files/live-decline"] {
                let response = try await fileRouteRequest(
                    app: harness.app,
                    method: .POST,
                    path: route,
                    body: FileActionRequest(path: liveFile.path)
                )
                #expect(response.status == .forbidden)
            }

            let content = try String(contentsOf: liveFile, encoding: .utf8)
            #expect(content == "Edited Version\n")
            #expect(FileManager.default.fileExists(atPath: backupFile.path))
            #expect(await store.liveState(forPath: liveFile.path) == .pending)
        }
    }
}

@Suite("Staged Review Routes")
struct StagedReviewRouteTests {
    @Test
    func `Case-folded backup spelling is refused by both staged routes`() async throws {
        try await withFileRouteApp { harness in
            harness.context.filesConfig = FilesConfig(allowRoots: [harness.root.path])
            let store = harness.context.stagedFiles
            let liveFile = harness.root.appendingPathComponent("notes.txt")
            let backupFile = harness.root.appendingPathComponent(".rune_backup_notes.txt")
            try FileRoutesTestSupport.write("Edited Version\n", at: liveFile)
            try FileRoutesTestSupport.write("Original Version\n", at: backupFile)
            _ = await store.beginLiveReview(path: liveFile.path, backupPath: backupFile.path)

            // BACKUP_notes.txt derives the staging sibling .rune_BACKUP_notes.txt,
            // which names the same rollback copy on the default case-folding
            // APFS volume; both decisions must refuse the pair before any move
            // or removal reaches the copy.
            let collider = harness.root.appendingPathComponent("BACKUP_notes.txt").path
            for route in ["/files/accept", "/files/discard"] {
                let response = try await fileRouteRequest(
                    app: harness.app,
                    method: .POST,
                    path: route,
                    body: FileActionRequest(path: collider)
                )
                #expect(response.status == .forbidden)
                #expect((response.body.string ?? "").contains("Backup entries are not reviewable staged files."))
            }

            // The rollback copy, the live bytes, and the pending review all
            // survive the refusals.
            #expect(try String(contentsOf: backupFile, encoding: .utf8) == "Original Version\n")
            #expect(try String(contentsOf: liveFile, encoding: .utf8) == "Edited Version\n")
            #expect(await store.liveState(forPath: liveFile.path) == .pending)
        }
    }
}

@Suite("File Supersede Broadcast")
struct FileSupersedeBroadcastTests {
    @Test
    func `A live write that supersedes a staged review broadcasts file_superseded to every socket`() async throws {
        let (base, ws) = try FileRoutesTestSupport.makeTempWorkspace()
        defer { FileRoutesTestSupport.cleanup(base) }
        let store = StagedFilesStore(dbPath: ws.appendingPathComponent("staged.db").path)
        let hub = WSHub()
        let firstSocket = FileActionRecordingSocket()
        let secondSocket = FileActionRecordingSocket()
        _ = await hub.add(id: UUID(), box: firstSocket)
        _ = await hub.add(id: UUID(), box: secondSocket)

        let liveFile = ws.appendingPathComponent("Broadcast.swift")
        try FileRoutesTestSupport.write("Original Version\n", at: liveFile)
        let tool = FilesWriteTool(
            homeDirectoryURL: ws,
            filesConfig: FilesConfig(allowRoots: [ws.path]),
            stagedFilesStore: store,
            supersededReviewNotifier: makeStagedSupersedeNotifier(hub: hub)
        )

        // Seed the pending staged review the live write will supersede.
        let stagedOutput = try await tool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(liveFile.path)\",\"content\":\"Staged Version\\n\",\"mode\":\"staged\"}"
            ),
            context: ToolContext(conversationID: UUID())
        )
        #expect(stagedOutput.isError == false)

        let liveOutput = try await tool.execute(
            input: ToolInput(
                toolName: "files.write",
                argumentsJSON: "{\"path\":\"\(liveFile.path)\",\"content\":\"Live Version\\n\",\"mode\":\"live\"}"
            ),
            context: ToolContext(conversationID: UUID())
        )
        #expect(liveOutput.isError == false)
        #expect(await store.state(forPath: liveFile.path) == .superseded)

        // Every registered socket receives the same self-describing frame:
        // `file_superseded` naming the canonical live path and the staged
        // row's terminal state, so a mounted review card settles without a
        // reload and without a follow-up route call that would 404.
        for socket in [firstSocket, secondSocket] {
            let frames = await waitForFileActionFrames(socket)
            let decoded = try frames.map { try JSONDecoder().decode(WSFileActionEvent.self, from: Data($0.utf8)) }
            #expect(decoded.contains { $0.type == "file_superseded" && $0.path == liveFile.path && $0.state == "superseded" })
        }
    }
}

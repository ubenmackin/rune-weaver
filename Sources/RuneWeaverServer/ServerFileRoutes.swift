// Rune Weaver Server — Staged and live file review and resolution routes.

import Foundation
import RuneWeaverCore
import RuneWeaverTools
import Vapor

/// Scans for and manages .rune_* staged files.
enum StagedFilesManager {
    /// Reads UTF-8 text, collapsing every unreadable case to nil.
    /// - Parameter url: File to read.
    static func readUTF8Text(at url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            RuneWeaverLog.server.debug("ServerFileRoutes: failed to read file at \(url.path): \(error.localizedDescription)")
            return nil
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }

    /// Derives the shared default scan root from the `[files]` policy.
    /// - Parameter filesConfig: Policy whose first allow root anchors the scan.
    static func defaultScanRoot(filesConfig: FilesConfig) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardized.path
        let first = filesConfig.allowRoots
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
        guard let raw = first else { return home }
        if raw == "~" {
            return home
        }
        if raw.hasPrefix("~/") {
            return URL(fileURLWithPath: home)
                .appendingPathComponent(String(raw.dropFirst(2))).standardized.path
        }
        if raw.hasPrefix("/") {
            return URL(fileURLWithPath: raw).standardized.path
        }
        return URL(fileURLWithPath: home).appendingPathComponent(raw).standardized.path
    }

    /// Resolves the effective scan root shared by GET and bulk routes.
    /// requestedPath: Explicit caller root, if any.
    static func resolvedScanRoot(requestedPath: String?, filesConfig: FilesConfig) throws -> String {
        let trimmed = (requestedPath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.isEmpty ? defaultScanRoot(filesConfig: filesConfig) : trimmed
        let decision = FilesAccessGuard.evaluate(path: candidate, filesConfig: filesConfig)
        guard decision.allowed else {
            throw Abort(.forbidden, reason: decision.reason ?? "Access denied for path.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: decision.resolvedPath, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw Abort(.badRequest, reason: "Scan root is not a directory: \(candidate)")
        }
        return decision.resolvedPath
    }

    /// Resolves a live path to its canonical live/staging pair after policy checks.
    /// rawPath: Caller-supplied live path (tilde and relative forms accepted).
    static func guardedStagingPair(for rawPath: String, filesConfig: FilesConfig) throws -> (live: URL, staging: URL) {
        let liveURL = URL(fileURLWithPath: FilesAccessGuard.resolvedURL(for: rawPath).path)
        let stagingURL = ReviewArtifacts.stagingURL(forLiveURL: liveURL)
        // Rollback copies are restore points, not reviewable proposals. The
        // shared predicate folds case so a differently-cased target cannot
        // derive a staging name that lands on a rollback copy.
        guard !ReviewArtifacts.isRollbackArtifactFilename(stagingURL.lastPathComponent) else {
            throw Abort(.forbidden, reason: "Backup entries are not reviewable staged files.")
        }
        // Denied paths never reach disk: both sides fail closed before any move.
        let liveDecision = FilesAccessGuard.evaluate(path: liveURL.path, filesConfig: filesConfig)
        guard liveDecision.allowed else {
            throw Abort(.forbidden, reason: liveDecision.reason ?? "Access denied for path.")
        }
        let stagingDecision = FilesAccessGuard.evaluate(path: stagingURL.path, filesConfig: filesConfig)
        guard stagingDecision.allowed else {
            throw Abort(.forbidden, reason: stagingDecision.reason ?? "Access denied for staged path.")
        }
        // Canonical same-directory check so a crafted path cannot redirect the
        // staging lookup outside the live file's directory.
        let canonicalLive = URL(fileURLWithPath: liveDecision.resolvedPath)
        let canonicalStaging = URL(fileURLWithPath: stagingDecision.resolvedPath)
        guard canonicalStaging.deletingLastPathComponent().path == canonicalLive.deletingLastPathComponent().path,
              canonicalStaging.lastPathComponent == ReviewArtifacts.stagingPrefix + canonicalLive.lastPathComponent,
              !ReviewArtifacts.isRollbackArtifactFilename(canonicalStaging.lastPathComponent)
        else {
            throw Abort(.forbidden, reason: "Staged file must sit beside its live file as .rune_<name>.")
        }
        return (canonicalLive, canonicalStaging)
    }

    /// Retrieves all staged files, optionally scoped under a root path, without walking the disk.
    static func findStagedFiles(
        under rootPath: String? = nil,
        filesConfig: FilesConfig,
        store: StagedFilesStore? = nil
    ) async -> [StagedFileEntry] {
        let effectiveStore = store ?? StagedFilesStore()
        let records = await effectiveStore.list(under: rootPath)
        var results: [StagedFileEntry] = []
        let isoFormatter = ISO8601DateFormatter()

        for record in records {
            let liveURL = URL(fileURLWithPath: record.path)
            let stagingURL = URL(fileURLWithPath: record.stagingPath)

            // Validate both paths against policy guard
            let liveDecision = FilesAccessGuard.evaluate(path: liveURL.path, filesConfig: filesConfig)
            guard liveDecision.allowed else { continue }
            let stagedDecision = FilesAccessGuard.evaluate(path: stagingURL.path, filesConfig: filesConfig)
            guard stagedDecision.allowed else { continue }

            guard let stagedContent = readUTF8Text(at: stagingURL) else {
                continue
            }

            let liveContent = readUTF8Text(at: liveURL)
            let diff = UnifiedDiffEngine.computeDiff(
                oldText: liveContent,
                newText: stagedContent,
                filepath: liveURL.lastPathComponent
            )

            let updatedAt = isoFormatter.string(from: record.updatedAt)

            results.append(StagedFileEntry(
                path: liveURL.path,
                stagingPath: stagingURL.path,
                additions: diff.additions,
                deletions: diff.deletions,
                diff: diff.diff,
                updatedAt: updatedAt
            ))
        }

        results.sort { $0.path < $1.path }
        return results
    }

    /// Atomically replaces the live file with the staged file and resolves its review row. -
    /// Parameters: - livePath: Caller-supplied live path for the file to restore.
    static func accept(
        livePath: String,
        stagingPath: String,
        filesConfig: FilesConfig = FilesConfig(),
        store: StagedFilesStore? = nil
    ) async throws {
        // Re-validate both sides inside the mutation so the filesystem move
        // never trusts a caller-resolved pair without policy checks.
        let liveDecision = FilesAccessGuard.evaluate(path: livePath, filesConfig: filesConfig)
        guard liveDecision.allowed else {
            throw Abort(.forbidden, reason: liveDecision.reason ?? "Access denied for path.")
        }
        let stagingDecision = FilesAccessGuard.evaluate(path: stagingPath, filesConfig: filesConfig)
        guard stagingDecision.allowed else {
            throw Abort(.forbidden, reason: stagingDecision.reason ?? "Access denied for staged path.")
        }
        // Canonical same-directory check so a crafted pair cannot redirect
        // the replace/move outside the live file's directory.
        let liveURL = URL(fileURLWithPath: liveDecision.resolvedPath)
        let stagingURL = URL(fileURLWithPath: stagingDecision.resolvedPath)
        guard stagingURL.deletingLastPathComponent().path == liveURL.deletingLastPathComponent().path,
              stagingURL.lastPathComponent == ReviewArtifacts.stagingPrefix + liveURL.lastPathComponent,
              !ReviewArtifacts.isRollbackArtifactFilename(stagingURL.lastPathComponent)
        else {
            throw Abort(.forbidden, reason: "Staged file must sit beside its live file as .rune_<name>.")
        }
        guard FileManager.default.fileExists(atPath: stagingURL.path) else {
            throw Abort(.notFound, reason: "Staged file not found: \(stagingPath)")
        }
        // Staged entries must be regular files and live targets must not be
        // directories, so a crafted pair cannot cross file/dir types on
        // replace or move.
        guard LiveFileBackup.isRegularFile(stagingURL) else {
            throw Abort(.forbidden, reason: "Staged entry is not a regular file.")
        }
        if (try? liveURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            throw Abort(.forbidden, reason: "Live target is a directory.")
        }

        try FileManager.default.createDirectory(at: liveURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: liveURL.path) {
            _ = try FileManager.default.replaceItemAt(liveURL, withItemAt: stagingURL)
        } else {
            try FileManager.default.moveItem(at: stagingURL, to: liveURL)
        }

        let effectiveStore = store ?? StagedFilesStore()
        // The staging file was moved onto the live path above, and rows are recorded under the live
        // path, so resolving by it marks the pending review accepted.
        await effectiveStore.resolveStaged(pathOrStagingPath: liveURL.path, resolution: .accepted)
    }

    /// Deletes the staging file and resolves its review row as discarded.
    /// stagingPath: Caller-supplied staging path to remove.
    static func discard(
        stagingPath: String,
        filesConfig: FilesConfig = FilesConfig(),
        store: StagedFilesStore? = nil
    ) async throws {
        // Re-validate the staging side inside the mutation; the live side is
        // derived from the `.rune_` name and checked too so a crafted staging
        // path cannot smuggle an outside target into the inbox.
        let stagingDecision = FilesAccessGuard.evaluate(path: stagingPath, filesConfig: filesConfig)
        guard stagingDecision.allowed else {
            throw Abort(.forbidden, reason: stagingDecision.reason ?? "Access denied for staged path.")
        }
        let stagingURL = URL(fileURLWithPath: stagingDecision.resolvedPath)
        let stagingName = stagingURL.lastPathComponent
        guard stagingName.hasPrefix(ReviewArtifacts.stagingPrefix),
              stagingName.count > ReviewArtifacts.stagingPrefix.count,
              !ReviewArtifacts.isRollbackArtifactFilename(stagingName)
        else {
            throw Abort(.forbidden, reason: "Staged file must sit beside its live file as .rune_<name>.")
        }
        let liveURL = stagingURL.deletingLastPathComponent()
            .appendingPathComponent(String(stagingName.dropFirst(ReviewArtifacts.stagingPrefix.count)))
        let liveDecision = FilesAccessGuard.evaluate(path: liveURL.path, filesConfig: filesConfig)
        guard liveDecision.allowed else {
            throw Abort(.forbidden, reason: liveDecision.reason ?? "Access denied for path.")
        }
        if FileManager.default.fileExists(atPath: stagingURL.path) {
            // Removing a directory through a staging name would recursively
            // delete, so only regular files reach removeItem.
            guard LiveFileBackup.isRegularFile(stagingURL) else {
                throw Abort(.forbidden, reason: "Staged entry is not a regular file.")
            }
            try FileManager.default.removeItem(at: stagingURL)
        }

        let effectiveStore = store ?? StagedFilesStore()
        // Resolve by the staging path: rows carry it alongside the live path,
        // so a discard leaves the same durable terminal state an accept does.
        await effectiveStore.resolveStaged(pathOrStagingPath: stagingURL.path, resolution: .discarded)
    }
}

/// Resolves live-write reviews by keeping the live bytes or rolling them back.
enum LiveReviewManager {
    /// Resolves a live path to its canonical live/rollback pair after policy checks.
    /// - Parameters:
    /// - rawPath: Caller-supplied live path (tilde and relative forms accepted).
    static func guardedLivePair(for rawPath: String, filesConfig: FilesConfig) throws -> (live: URL, backup: URL) {
        let liveDecision = FilesAccessGuard.evaluate(path: rawPath, filesConfig: filesConfig)
        guard liveDecision.allowed else {
            throw Abort(.forbidden, reason: liveDecision.reason ?? "Access denied for path.")
        }
        let liveURL = URL(fileURLWithPath: liveDecision.resolvedPath)
        // The copy path is derived, never caller-supplied, so a request can only
        // name a live file and the guard decides which sibling may be mutated.
        let backupURL = ReviewArtifacts.backupURL(forLiveURL: liveURL)
        // A decision removes or moves the rollback copy, so a denied backup path fails closed too
        // even when the live path itself passed the guard.
        let backupDecision = FilesAccessGuard.evaluate(path: backupURL.path, filesConfig: filesConfig)
        guard backupDecision.allowed else {
            throw Abort(.forbidden, reason: backupDecision.reason ?? "Access denied for rollback path.")
        }
        return (liveURL, backupURL)
    }

    /// Keeps the live file and clears its rollback copy.
    static func accept(
        livePath: String,
        filesConfig: FilesConfig = FilesConfig(),
        store: StagedFilesStore? = nil
    ) async throws -> String {
        let pair = try guardedLivePair(for: livePath, filesConfig: filesConfig)
        let effectiveStore = store ?? StagedFilesStore()
        let resolution = try await effectiveStore.resolveLiveReviewAtomically(path: pair.live.path) { record in
            if record.backupPath != nil {
                // Accept is the keep path: the live bytes stay as written, so the rollback copy is
                // only cleared. A copy an out-of-band delete already removed is tolerated so the
                // review still settles.
                try LiveFileBackup.removeBackup(at: pair.backup)
            }
            return .accepted
        }
        guard let resolution else {
            throw Abort(.notFound, reason: "No pending live review for \(pair.live.path).")
        }
        return resolution.rawValue
    }

    /// Rolls the live file back to its rollback copy, or discards a new file.
    static func decline(
        livePath: String,
        filesConfig: FilesConfig = FilesConfig(),
        store: StagedFilesStore? = nil
    ) async throws -> String {
        let pair = try guardedLivePair(for: livePath, filesConfig: filesConfig)
        let effectiveStore = store ?? StagedFilesStore()
        let resolution = try await effectiveStore.resolveLiveReviewAtomically(path: pair.live.path) { record in
            if record.backupPath != nil {
                // The ledger records the derived sibling, and the guard already vetted that URL, so
                // the restore can only ever consume the copy beside the live file even if the row
                // were tampered with.
                guard FileManager.default.fileExists(atPath: pair.backup.path) else {
                    throw Abort(.notFound, reason: "Rollback copy not found for \(pair.live.path).")
                }
                // Atomic replace when the live file still exists, move when an
                // external delete removed it; both branches consume the copy,
                // so no separate backup removal is needed.
                try LiveFileBackup.restore(liveURL: pair.live, backupURL: pair.backup)
                return .reverted
            }
            // A new-file review owns no rollback copy, so declining it removes
            // the created file. An already-missing file is tolerated because
            // the review outcome is what matters, not the file's survival.
            if FileManager.default.fileExists(atPath: pair.live.path) {
                guard LiveFileBackup.isRegularFile(pair.live) else {
                    throw Abort(.forbidden, reason: "Live entry is not a regular file.")
                }
                try FileManager.default.removeItem(at: pair.live)
            }
            return .discarded
        }
        guard let resolution else {
            throw Abort(.notFound, reason: "No pending live review for \(pair.live.path).")
        }
        return resolution == .reverted ? "reverted" : "discarded"
    }
}

/// Registers staged files management routes.
func registerFileRoutes(_ app: Application) {
    let filesGroup = app.grouped(PathComponent.constant(ServerPaths.files))
    registerFileStagedRoute(filesGroup)
    registerFileReviewStatusRoute(filesGroup)
    registerFileAcceptRoute(filesGroup)
    registerFileDiscardRoute(filesGroup)
    registerFileLiveAcceptRoute(filesGroup)
    registerFileLiveDeclineRoute(filesGroup)
}

private func registerFileStagedRoute(_ filesGroup: RoutesBuilder) {
    // GET /files/staged
    filesGroup.get(PathComponent.constant(ServerPaths.filesStaged)) { req async throws -> StagedFilesResponse in
        let filesConfig = req.application.runeWeaver.filesConfig
        let store = req.application.runeWeaver.stagedFiles
        let requested = req.query[String.self, at: "path"]
        // Validate the scan root before touching the store so denied roots
        // fail closed with 403 and file roots with 400 instead of silently
        // yielding an empty inbox. The store query itself performs no crawl.
        let scanRoot = try StagedFilesManager.resolvedScanRoot(requestedPath: requested, filesConfig: filesConfig)
        let entries = await StagedFilesManager.findStagedFiles(under: scanRoot, filesConfig: filesConfig, store: store)
        return StagedFilesResponse(files: entries)
    }
}

/// Registers the batch review-status query route.
private func registerFileReviewStatusRoute(_ filesGroup: RoutesBuilder) {
    // POST /files/review-status
    filesGroup.post(PathComponent.constant(ServerPaths.filesReviewStatus)) { req async throws -> ReviewStatusResponse in
        let statusReq = try req.content.decode(ReviewStatusRequest.self)
        // Trims paths to match canonical ledger keys, then guards against blanks and counts > 200:
        // blank entries key unreachable responses and unbounded lists cause runaway sequential lookups.
        let paths = statusReq.paths.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !paths.isEmpty, paths.count <= 200, paths.allSatisfy({ !$0.isEmpty }) else {
            throw Abort(.badRequest, reason: "Body must carry 1 to 200 non-empty paths.")
        }

        let store = req.application.runeWeaver.stagedFiles
        let staged: [String: FileReviewState]
        let live: [String: FileReviewState]
        do {
            staged = try await store.states(forPaths: paths)
            live = try await store.liveStates(forPaths: paths)
        } catch {
            // The batched reads throw so a store failure cannot be mistaken
            // for absent rows; surface it as a non-2xx and let the client keep
            // the pending UI it already shows.
            RuneWeaverLog.stores.error(
                "files/review-status: could not read the review ledger: \(error.localizedDescription)"
            )
            throw Abort(.internalServerError, reason: "Could not read the review ledger; retry the status query.")
        }
        // Echo every requested path in both maps, defaulting a missing row to
        // "unknown", so a client renders each row's review posture from this
        // response alone instead of guessing from an omitted key.
        var stagedStates: [String: String] = [:]
        var liveStates: [String: String] = [:]
        stagedStates.reserveCapacity(paths.count)
        liveStates.reserveCapacity(paths.count)
        for path in paths {
            stagedStates[path] = staged[path]?.rawValue ?? "unknown"
            liveStates[path] = live[path]?.rawValue ?? "unknown"
        }
        return ReviewStatusResponse(stagedStates: stagedStates, liveStates: liveStates)
    }
}

private func registerFileAcceptRoute(_ filesGroup: RoutesBuilder) {
    // POST /files/accept
    filesGroup.post(PathComponent.constant(ServerPaths.filesAccept)) { req async throws -> FileActionResponse in
        let actionReq = try req.content.decode(FileActionRequest.self)
        let filesConfig = req.application.runeWeaver.filesConfig
        let store = req.application.runeWeaver.stagedFiles

        if actionReq.all == true {
            let requested = req.query[String.self, at: "path"] ?? actionReq.path
            // Validate the bulk scope before the store query so a denied or
            // file root fails closed instead of silently scoping to nothing.
            let scanRoot = try StagedFilesManager.resolvedScanRoot(requestedPath: requested, filesConfig: filesConfig)
            let staged = await StagedFilesManager.findStagedFiles(under: scanRoot, filesConfig: filesConfig, store: store)
            var count = 0
            // Per-file failures are collected and surfaced as a non-200
            // rather than swallowed into a bare success count.
            var failures: [String] = []
            var acceptedPaths: [String] = []
            for file in staged {
                do {
                    try await StagedFilesManager.accept(livePath: file.path, stagingPath: file.stagingPath, filesConfig: filesConfig, store: store)
                    count += 1
                    acceptedPaths.append(file.path)
                } catch {
                    failures.append("\(file.path): \(error.localizedDescription)")
                }
            }
            // The HTTP response carries the mutation truth; per-file frames
            // follow from a detached task so a slow viewer never delays the
            // review decision.
            let hub = req.application.runeWeaver.hub
            Task { [hub, acceptedPaths] in
                for path in acceptedPaths {
                    await hub.broadcastFileAction(WSFileActionEvent(type: "file_accepted", path: path))
                }
            }
            if !failures.isEmpty {
                throw Abort(
                    .internalServerError,
                    reason: "Accepted \(count) of \(staged.count); \(failures.count) failed: \(failures.joined(separator: "; "))"
                )
            }
            return FileActionResponse(status: "accepted", count: count)
        }

        guard let path = actionReq.path, !path.isEmpty else {
            throw Abort(.badRequest, reason: "Either 'path' or 'all: true' must be specified.")
        }

        let pair = try StagedFilesManager.guardedStagingPair(for: path, filesConfig: filesConfig)
        let liveURL = pair.live
        let stagingURL = pair.staging

        try await StagedFilesManager.accept(livePath: liveURL.path, stagingPath: stagingURL.path, filesConfig: filesConfig, store: store)

        // Return the mutation result first; the frame reconciles viewers eventually.
        let hub = req.application.runeWeaver.hub
        let livePath = liveURL.path
        Task { [hub, livePath] in
            await hub.broadcastFileAction(WSFileActionEvent(type: "file_accepted", path: livePath))
        }

        return FileActionResponse(status: "accepted", count: 1)
    }
}

private func registerFileDiscardRoute(_ filesGroup: RoutesBuilder) {
    // POST /files/discard
    filesGroup.post(PathComponent.constant(ServerPaths.filesDiscard)) { req async throws -> FileActionResponse in
        let actionReq = try req.content.decode(FileActionRequest.self)
        let filesConfig = req.application.runeWeaver.filesConfig
        let store = req.application.runeWeaver.stagedFiles

        if actionReq.all == true {
            let requested = req.query[String.self, at: "path"] ?? actionReq.path
            // Validate the bulk scope before the store query so a denied or
            // file root fails closed instead of silently scoping to nothing.
            let scanRoot = try StagedFilesManager.resolvedScanRoot(requestedPath: requested, filesConfig: filesConfig)
            let staged = await StagedFilesManager.findStagedFiles(under: scanRoot, filesConfig: filesConfig, store: store)
            var count = 0
            // Per-file failures are collected and surfaced as a non-200
            // rather than swallowed into a bare success count.
            var failures: [String] = []
            var discardedPaths: [String] = []
            for file in staged {
                do {
                    try await StagedFilesManager.discard(stagingPath: file.stagingPath, filesConfig: filesConfig, store: store)
                    count += 1
                    discardedPaths.append(file.path)
                } catch {
                    failures.append("\(file.path): \(error.localizedDescription)")
                }
            }
            // The HTTP response carries the mutation truth; per-file frames
            // follow from a detached task so a slow viewer never delays the
            // review decision.
            let hub = req.application.runeWeaver.hub
            Task { [hub, discardedPaths] in
                for path in discardedPaths {
                    await hub.broadcastFileAction(WSFileActionEvent(type: "file_discarded", path: path))
                }
            }
            if !failures.isEmpty {
                throw Abort(
                    .internalServerError,
                    reason: "Discarded \(count) of \(staged.count); \(failures.count) failed: \(failures.joined(separator: "; "))"
                )
            }
            return FileActionResponse(status: "discarded", count: count)
        }

        guard let path = actionReq.path, !path.isEmpty else {
            throw Abort(.badRequest, reason: "Either 'path' or 'all: true' must be specified.")
        }

        let pair = try StagedFilesManager.guardedStagingPair(for: path, filesConfig: filesConfig)
        let liveURL = pair.live
        let stagingURL = pair.staging

        try await StagedFilesManager.discard(stagingPath: stagingURL.path, filesConfig: filesConfig, store: store)

        // Return the mutation result first; the frame reconciles viewers eventually.
        let hub = req.application.runeWeaver.hub
        let livePath = liveURL.path
        Task { [hub, livePath] in
            await hub.broadcastFileAction(WSFileActionEvent(type: "file_discarded", path: livePath))
        }

        return FileActionResponse(status: "discarded", count: 1)
    }
}

/// Guards one live review request and returns its canonical live path.
private func guardedLiveReviewPath(_ actionReq: FileActionRequest, filesConfig: FilesConfig) throws -> String {
    guard actionReq.all != true else {
        throw Abort(.badRequest, reason: "Live reviews resolve one file at a time.")
    }
    guard let rawPath = actionReq.path, !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw Abort(.badRequest, reason: "A live review requires a 'path'.")
    }
    return try LiveReviewManager.guardedLivePair(for: rawPath, filesConfig: filesConfig).live.path
}

/// Broadcasts one detached `live_resolved` frame for a completed live review. req:
/// Request whose application owns the hub.
private func broadcastLiveResolved(_ req: Request, path: String, state: String) {
    // The HTTP response carries the mutation truth; the frame follows from a
    // detached task so a slow viewer never delays the review decision.
    let hub = req.application.runeWeaver.hub
    Task { [hub, path, state] in
        await hub.broadcastFileAction(WSFileActionEvent(type: "live_resolved", path: path, state: state))
    }
}

/// Builds the propagation hook reporting a live write that superseded a staged review.
func makeStagedSupersedeNotifier(hub: WSHub) -> @Sendable (String) async -> Void {
    { path in
        await hub.broadcastFileAction(
            WSFileActionEvent(
                type: "file_superseded",
                path: path,
                state: FileReviewState.superseded.rawValue
            )
        )
    }
}

private func registerFileLiveAcceptRoute(_ filesGroup: RoutesBuilder) {
    // POST /files/live-accept
    filesGroup.post(PathComponent.constant(ServerPaths.filesLiveAccept)) { req async throws -> FileActionResponse in
        let actionReq = try req.content.decode(FileActionRequest.self)
        let filesConfig = req.application.runeWeaver.filesConfig
        let store = req.application.runeWeaver.stagedFiles
        let livePath = try guardedLiveReviewPath(actionReq, filesConfig: filesConfig)
        let state = try await LiveReviewManager.accept(livePath: livePath, filesConfig: filesConfig, store: store)
        broadcastLiveResolved(req, path: livePath, state: state)
        return FileActionResponse(status: state, count: 1)
    }
}

private func registerFileLiveDeclineRoute(_ filesGroup: RoutesBuilder) {
    // POST /files/live-decline
    filesGroup.post(PathComponent.constant(ServerPaths.filesLiveDecline)) { req async throws -> FileActionResponse in
        let actionReq = try req.content.decode(FileActionRequest.self)
        let filesConfig = req.application.runeWeaver.filesConfig
        let store = req.application.runeWeaver.stagedFiles
        let livePath = try guardedLiveReviewPath(actionReq, filesConfig: filesConfig)
        let state = try await LiveReviewManager.decline(livePath: livePath, filesConfig: filesConfig, store: store)
        broadcastLiveResolved(req, path: livePath, state: state)
        return FileActionResponse(status: state, count: 1)
    }
}

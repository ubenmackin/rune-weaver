// Rune Weaver Server — Staged files review and resolution routes.

import Foundation
import RuneWeaverCore
import RuneWeaverTools
import Vapor

/// Scans for and manages .rune_* staged files.
enum StagedFilesManager {
    /// Deepest directory level the staged scan descends before pruning.
    private static let maxScanDepth = 32

    /// Canonical staging marker beside each live file.
    private static let stagedPrefix = ".rune_"
    /// Live-write rollback marker that must never surface in the review inbox.
    private static let backupPrefix = ".rune_backup_"

    /// Reads UTF-8 text, collapsing every unreadable case to nil.
    /// - Parameter url: File to read.
    /// - Returns: Text when the file exists and decodes as UTF-8, otherwise nil.
    ///   Missing files and binary payloads share the nil shape so live and
    ///   staged diffs agree on the create/delete path instead of diverging
    ///   between an empty string and a null old text.
    static func readUTF8Text(at url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return text
    }

    /// Reports whether a URL points at a regular file.
    /// - Parameter url: Candidate staging or live path.
    /// - Returns: True only for regular files, so directories and other
    ///   node types cannot ride a replace/move/remove across types.
    static func isRegularFile(at url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }

    /// Derives the shared default scan root from the `[files]` policy.
    /// - Parameter filesConfig: Policy whose first allow root anchors the scan.
    /// - Returns: Canonical default root, falling back to home when no roots
    ///   are configured. The server never inherits the process working
    ///   directory, which reflects the launch dir rather than the workspace.
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
    /// - Parameters:
    ///   - requestedPath: Explicit caller root, if any.
    ///   - filesConfig: `[files]` policy enforced before any scan.
    /// - Returns: Canonical directory path that passed the guard.
    /// - Throws: `Abort(.forbidden)` when the root is denied;
    ///   `Abort(.badRequest)` when it is not a directory, so a file root
    ///   cannot silently yield an empty inbox.
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
    /// - Parameters:
    ///   - rawPath: Caller-supplied live path (tilde and relative forms accepted).
    ///   - filesConfig: `[files]` policy enforced on both resolved paths.
    /// - Returns: Canonical live and staging URLs that passed the guard.
    /// - Throws: `Abort(.forbidden)` when either path is denied or the staging
    ///   entry does not sit beside its live file as `.rune_<name>`.
    static func guardedStagingPair(for rawPath: String, filesConfig: FilesConfig) throws -> (live: URL, staging: URL) {
        let liveURL = URL(fileURLWithPath: FilesAccessGuard.resolvedURL(for: rawPath).path)
        let stagingURL = liveURL.deletingLastPathComponent().appendingPathComponent(stagedPrefix + liveURL.lastPathComponent)
        // Rollback copies are restore points, not reviewable proposals.
        guard !stagingURL.lastPathComponent.hasPrefix(backupPrefix) else {
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
              canonicalStaging.lastPathComponent == stagedPrefix + canonicalLive.lastPathComponent,
              !canonicalStaging.lastPathComponent.hasPrefix(backupPrefix)
        else {
            throw Abort(.forbidden, reason: "Staged file must sit beside its live file as .rune_<name>.")
        }
        return (canonicalLive, canonicalStaging)
    }

    /// Scans a root directory for all .rune_* staged files.
    static func findStagedFiles(
        under rootPath: String,
        filesConfig: FilesConfig
    ) -> [StagedFileEntry] {
        // Refuse a denied scan root before touching the filesystem.
        let rootDecision = FilesAccessGuard.evaluate(path: rootPath, filesConfig: filesConfig)
        guard rootDecision.allowed else { return [] }
        let rootURL = URL(fileURLWithPath: rootDecision.resolvedPath)
        let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .isDirectoryKey],
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return []
        }

        var results: [StagedFileEntry] = []
        let skipDirs: Set = [".git", ".build", "build", "node_modules", "DerivedData", ".derivedData", ".venv"]

        while let element = enumerator.nextObject() {
            guard let url = element as? URL else { continue }
            // Bound traversal depth so a broad root cannot exhaust the request.
            if enumerator.level > maxScanDepth {
                enumerator.skipDescendants()
                continue
            }
            let name = url.lastPathComponent

            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                // Prune denied or escaped directories without descending into them.
                let dirDecision = FilesAccessGuard.evaluate(path: url.path, filesConfig: filesConfig)
                guard dirDecision.allowed,
                      dirDecision.resolvedPath == rootURL.path || dirDecision.resolvedPath.hasPrefix(rootPrefix)
                else {
                    enumerator.skipDescendants()
                    continue
                }
                if skipDirs.contains(name) {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard name.hasPrefix(stagedPrefix), name.count > stagedPrefix.count else {
                continue
            }
            // Live-write rollbacks share the staging directory but applying
            // one would revert live to its old bytes while discarding it
            // would delete the rollback, so keep them out of the inbox.
            guard !name.hasPrefix(backupPrefix) else {
                continue
            }

            // Keep the scan inside the allowed root even when a symlink points out.
            let stagedDecision = FilesAccessGuard.evaluate(path: url.path, filesConfig: filesConfig)
            guard stagedDecision.allowed,
                  stagedDecision.resolvedPath == rootURL.path || stagedDecision.resolvedPath.hasPrefix(rootPrefix)
            else {
                continue
            }

            let liveFilename = String(name.dropFirst(stagedPrefix.count))
            let liveURL = url.deletingLastPathComponent().appendingPathComponent(liveFilename)

            // Validate both paths against policy guard
            let decision = FilesAccessGuard.evaluate(path: liveURL.path, filesConfig: filesConfig)
            guard decision.allowed else { continue }
            // Require the canonical staging entry to sit beside its live file so
            // a renamed or linked entry cannot smuggle an outside path into the inbox.
            let canonicalStaging = URL(fileURLWithPath: stagedDecision.resolvedPath)
            let canonicalLive = URL(fileURLWithPath: decision.resolvedPath)
            guard canonicalStaging.deletingLastPathComponent().path == canonicalLive.deletingLastPathComponent().path,
                  canonicalStaging.lastPathComponent == stagedPrefix + canonicalLive.lastPathComponent,
                  !canonicalStaging.lastPathComponent.hasPrefix(backupPrefix)
            else {
                continue
            }

            // Missing files and binary payloads collapse to nil on both
            // sides through one helper, keeping the diff shape consistent.
            guard let stagedContent = readUTF8Text(at: url) else {
                continue
            }

            let liveContent = readUTF8Text(at: liveURL)

            let diff = UnifiedDiffEngine.computeDiff(
                oldText: liveContent,
                newText: stagedContent,
                filepath: liveFilename
            )

            let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            let isoFormatter = ISO8601DateFormatter()
            let updatedAt = isoFormatter.string(from: modDate)

            results.append(StagedFileEntry(
                path: liveURL.path,
                stagingPath: url.path,
                additions: diff.additions,
                deletions: diff.deletions,
                diff: diff.diff,
                updatedAt: updatedAt
            ))
        }

        results.sort { $0.path < $1.path }
        return results
    }

    /// Atomically replaces the live file with the staged file and removes the staging file.
    /// - Parameters:
    ///   - livePath: Caller-supplied live path for the file to restore.
    ///   - stagingPath: Caller-supplied staging path beside the live file.
    ///   - filesConfig: `[files]` policy re-enforced here so a direct call
    ///     cannot bypass the route-level guard.
    /// - Throws: `Abort(.forbidden)` when either path is denied or the pair
    ///   is not a same-directory `.rune_<name>` couple; `Abort(.notFound)`
    ///   when the staging entry is missing.
    static func accept(livePath: String, stagingPath: String, filesConfig: FilesConfig = FilesConfig()) throws {
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
              stagingURL.lastPathComponent == stagedPrefix + liveURL.lastPathComponent,
              !stagingURL.lastPathComponent.hasPrefix(backupPrefix)
        else {
            throw Abort(.forbidden, reason: "Staged file must sit beside its live file as .rune_<name>.")
        }
        guard FileManager.default.fileExists(atPath: stagingURL.path) else {
            throw Abort(.notFound, reason: "Staged file not found: \(stagingPath)")
        }
        // Staged entries must be regular files and live targets must not be
        // directories, so a crafted pair cannot cross file/dir types on
        // replace or move.
        guard isRegularFile(at: stagingURL) else {
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
    }

    /// Deletes the staging file.
    /// - Parameters:
    ///   - stagingPath: Caller-supplied staging path to remove.
    ///   - filesConfig: `[files]` policy re-enforced here so a direct call
    ///     cannot bypass the route-level guard.
    /// - Throws: `Abort(.forbidden)` when the staging path (or its derived
    ///   live counterpart) is denied or not a `.rune_<name>` entry.
    static func discard(stagingPath: String, filesConfig: FilesConfig = FilesConfig()) throws {
        // Re-validate the staging side inside the mutation; the live side is
        // derived from the `.rune_` name and checked too so a crafted staging
        // path cannot smuggle an outside target into the inbox.
        let stagingDecision = FilesAccessGuard.evaluate(path: stagingPath, filesConfig: filesConfig)
        guard stagingDecision.allowed else {
            throw Abort(.forbidden, reason: stagingDecision.reason ?? "Access denied for staged path.")
        }
        let stagingURL = URL(fileURLWithPath: stagingDecision.resolvedPath)
        let stagingName = stagingURL.lastPathComponent
        guard stagingName.hasPrefix(stagedPrefix), stagingName.count > stagedPrefix.count,
              !stagingName.hasPrefix(backupPrefix)
        else {
            throw Abort(.forbidden, reason: "Staged file must sit beside its live file as .rune_<name>.")
        }
        let liveURL = stagingURL.deletingLastPathComponent()
            .appendingPathComponent(String(stagingName.dropFirst(stagedPrefix.count)))
        let liveDecision = FilesAccessGuard.evaluate(path: liveURL.path, filesConfig: filesConfig)
        guard liveDecision.allowed else {
            throw Abort(.forbidden, reason: liveDecision.reason ?? "Access denied for path.")
        }
        guard FileManager.default.fileExists(atPath: stagingURL.path) else {
            return
        }
        // Removing a directory through a staging name would recursively
        // delete, so only regular files reach removeItem.
        guard isRegularFile(at: stagingURL) else {
            throw Abort(.forbidden, reason: "Staged entry is not a regular file.")
        }
        try FileManager.default.removeItem(at: stagingURL)
    }
}

/// Registers staged files management routes.
func registerFileRoutes(_ app: Application) {
    let filesGroup = app.grouped(PathComponent.constant(ServerPaths.files))

    // GET /files/staged
    filesGroup.get(PathComponent.constant(ServerPaths.filesStaged)) { req async throws -> StagedFilesResponse in
        let filesConfig = req.application.runeWeaver.filesConfig
        // Absent roots fall back to the policy home/allow-root default shared
        // with bulk scope, never the process launch directory.
        let resolvedRoot = try StagedFilesManager.resolvedScanRoot(
            requestedPath: req.query[String.self, at: "path"],
            filesConfig: filesConfig
        )
        let entries = StagedFilesManager.findStagedFiles(under: resolvedRoot, filesConfig: filesConfig)
        return StagedFilesResponse(files: entries)
    }

    // POST /files/accept
    filesGroup.post(PathComponent.constant(ServerPaths.filesAccept)) { req async throws -> FileActionResponse in
        let actionReq = try req.content.decode(FileActionRequest.self)
        let filesConfig = req.application.runeWeaver.filesConfig

        if actionReq.all == true {
            // Bulk scope shares the GET default root and its directory guard,
            // so bulk never acts outside the listed scope.
            let resolvedRoot = try StagedFilesManager.resolvedScanRoot(
                requestedPath: req.query[String.self, at: "path"] ?? actionReq.path,
                filesConfig: filesConfig
            )
            let staged = StagedFilesManager.findStagedFiles(under: resolvedRoot, filesConfig: filesConfig)
            var count = 0
            // Per-file failures are collected and surfaced as a non-200
            // rather than swallowed into a bare success count.
            var failures: [String] = []
            for file in staged {
                do {
                    try StagedFilesManager.accept(livePath: file.path, stagingPath: file.stagingPath, filesConfig: filesConfig)
                    count += 1
                    if let data = try? JSONEncoder().encode(WSFileActionEvent(type: "file_accepted", path: file.path)),
                       let text = String(data: data, encoding: .utf8)
                    {
                        await req.application.runeWeaver.hub.broadcast(text: text)
                    }
                } catch {
                    failures.append("\(file.path): \(error.localizedDescription)")
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

        try StagedFilesManager.accept(livePath: liveURL.path, stagingPath: stagingURL.path, filesConfig: filesConfig)

        if let data = try? JSONEncoder().encode(WSFileActionEvent(type: "file_accepted", path: liveURL.path)),
           let text = String(data: data, encoding: .utf8)
        {
            await req.application.runeWeaver.hub.broadcast(text: text)
        }

        return FileActionResponse(status: "accepted", count: 1)
    }

    // POST /files/discard
    filesGroup.post(PathComponent.constant(ServerPaths.filesDiscard)) { req async throws -> FileActionResponse in
        let actionReq = try req.content.decode(FileActionRequest.self)
        let filesConfig = req.application.runeWeaver.filesConfig

        if actionReq.all == true {
            // Bulk scope shares the GET default root and its directory guard,
            // so bulk never acts outside the listed scope.
            let resolvedRoot = try StagedFilesManager.resolvedScanRoot(
                requestedPath: req.query[String.self, at: "path"] ?? actionReq.path,
                filesConfig: filesConfig
            )
            let staged = StagedFilesManager.findStagedFiles(under: resolvedRoot, filesConfig: filesConfig)
            var count = 0
            // Per-file failures are collected and surfaced as a non-200
            // rather than swallowed into a bare success count.
            var failures: [String] = []
            for file in staged {
                do {
                    try StagedFilesManager.discard(stagingPath: file.stagingPath, filesConfig: filesConfig)
                    count += 1
                    if let data = try? JSONEncoder().encode(WSFileActionEvent(type: "file_discarded", path: file.path)),
                       let text = String(data: data, encoding: .utf8)
                    {
                        await req.application.runeWeaver.hub.broadcast(text: text)
                    }
                } catch {
                    failures.append("\(file.path): \(error.localizedDescription)")
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

        try StagedFilesManager.discard(stagingPath: stagingURL.path, filesConfig: filesConfig)

        if let data = try? JSONEncoder().encode(WSFileActionEvent(type: "file_discarded", path: liveURL.path)),
           let text = String(data: data, encoding: .utf8)
        {
            await req.application.runeWeaver.hub.broadcast(text: text)
        }

        return FileActionResponse(status: "discarded", count: 1)
    }
}

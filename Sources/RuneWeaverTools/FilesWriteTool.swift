// Rune Weaver Tools — APFS Copy-on-Write staging and file write tool (`files.write`).

import Foundation
import RuneWeaverCore

#if os(macOS)
    import Darwin
#endif

/// One unified diff hunk line.
public enum DiffLine: Equatable, Sendable {
    case context(String)
    case addition(String)
    case deletion(String)
}

/// Computes Myers line-by-line unified diffs with context hunks.
public enum UnifiedDiffEngine: Sendable {
    /// Splits text into lines without line terminators.
    public static func splitLines(_ text: String) -> [String] {
        if text.isEmpty {
            return []
        }
        var lines: [String] = []
        text.enumerateLines { line, _ in
            lines.append(line)
        }
        return lines
    }

    /// Result of computing a unified diff.
    public struct DiffResult: Sendable, Equatable {
        public let diff: String
        public let additions: Int
        public let deletions: Int
    }

    /// Computes the unified diff between `oldText` and `newText`.
    /// - Parameters:
    ///   - oldText: Original text (or nil/empty if new file).
    ///   - newText: New text.
    ///   - filepath: Relative or display path of the file.
    ///   - contextRadius: Number of context lines before/after each change block (default 3).
    public static func computeDiff(
        oldText: String?,
        newText: String,
        filepath: String,
        contextRadius: Int = 3
    ) -> DiffResult {
        let oldExisted = oldText != nil
        let oldLines = splitLines(oldText ?? "")
        let newLines = splitLines(newText)

        // Shortcut: identical content
        if oldExisted, oldLines == newLines {
            return DiffResult(diff: "", additions: 0, deletions: 0)
        }

        // If old did not exist, everything is an addition
        if !oldExisted {
            let additions = newLines.count
            var diff = "--- /dev/null\n+++ b/\(filepath)\n"
            diff += "@@ -0,0 +1,\(newLines.count) @@\n"
            for line in newLines {
                diff += "+\(line)\n"
            }
            return DiffResult(diff: diff, additions: additions, deletions: 0)
        }

        // Prefix and suffix trimming
        var prefixLen = 0
        let minCount = min(oldLines.count, newLines.count)
        while prefixLen < minCount, oldLines[prefixLen] == newLines[prefixLen] {
            prefixLen += 1
        }

        var suffixLen = 0
        while suffixLen < (minCount - prefixLen),
              oldLines[oldLines.count - 1 - suffixLen] == newLines[newLines.count - 1 - suffixLen]
        {
            suffixLen += 1
        }

        let middleOld = Array(oldLines[prefixLen ..< (oldLines.count - suffixLen)])
        let middleNew = Array(newLines[prefixLen ..< (newLines.count - suffixLen)])
        let middleDiff = computeMiddleDiff(middleOld: middleOld, middleNew: middleNew)

        var allDiffLines: [DiffLine] = []
        allDiffLines.reserveCapacity(prefixLen + middleDiff.count + suffixLen)
        for idx in 0 ..< prefixLen {
            allDiffLines.append(.context(oldLines[idx]))
        }
        allDiffLines.append(contentsOf: middleDiff)
        for idx in (oldLines.count - suffixLen) ..< oldLines.count {
            allDiffLines.append(.context(oldLines[idx]))
        }

        var additions = 0
        var deletions = 0
        var changeIndices: [Int] = []
        for (idx, line) in allDiffLines.enumerated() {
            switch line {
            case .addition:
                additions += 1
                changeIndices.append(idx)
            case .deletion:
                deletions += 1
                changeIndices.append(idx)
            case .context:
                break
            }
        }

        if changeIndices.isEmpty {
            return DiffResult(diff: "", additions: 0, deletions: 0)
        }

        let diffText = buildHunkText(
            allDiffLines: allDiffLines,
            changeIndices: changeIndices,
            filepath: filepath,
            contextRadius: contextRadius
        )

        return DiffResult(diff: diffText, additions: additions, deletions: deletions)
    }

    private static func computeMiddleDiff(middleOld: [String], middleNew: [String]) -> [DiffLine] {
        let rowCount = middleOld.count
        let colCount = middleNew.count

        if rowCount == 0 {
            return middleNew.map { .addition($0) }
        }
        if colCount == 0 {
            return middleOld.map { .deletion($0) }
        }
        if rowCount * colCount > 1_000_000 {
            // Guard against pathological diffs: treat middle as replacement
            return middleOld.map { .deletion($0) } + middleNew.map { .addition($0) }
        }

        // Standard LCS DP
        var lcsMatrix = Array(repeating: Array(repeating: 0, count: colCount + 1), count: rowCount + 1)
        for row in 1 ... rowCount {
            for col in 1 ... colCount {
                if middleOld[row - 1] == middleNew[col - 1] {
                    lcsMatrix[row][col] = lcsMatrix[row - 1][col - 1] + 1
                } else {
                    lcsMatrix[row][col] = max(lcsMatrix[row - 1][col], lcsMatrix[row][col - 1])
                }
            }
        }

        var row = rowCount
        var col = colCount
        var reversed: [DiffLine] = []
        while row > 0 || col > 0 {
            if row > 0, col > 0, middleOld[row - 1] == middleNew[col - 1] {
                reversed.append(.context(middleOld[row - 1]))
                row -= 1
                col -= 1
            } else if col > 0, row == 0 || lcsMatrix[row][col - 1] >= lcsMatrix[row - 1][col] {
                reversed.append(.addition(middleNew[col - 1]))
                col -= 1
            } else if row > 0 {
                reversed.append(.deletion(middleOld[row - 1]))
                row -= 1
            }
        }
        return reversed.reversed()
    }

    private struct HunkRange {
        var start: Int
        var end: Int
    }

    private static func buildHunkText(
        allDiffLines: [DiffLine],
        changeIndices: [Int],
        filepath: String,
        contextRadius: Int
    ) -> String {
        var hunks: [HunkRange] = []
        for idx in changeIndices {
            let hunkStart = max(0, idx - contextRadius)
            let hunkEnd = min(allDiffLines.count - 1, idx + contextRadius)

            if let last = hunks.last, hunkStart <= last.end + 1 {
                hunks[hunks.count - 1].end = max(last.end, hunkEnd)
            } else {
                hunks.append(HunkRange(start: hunkStart, end: hunkEnd))
            }
        }

        var diffText = "--- a/\(filepath)\n+++ b/\(filepath)\n"
        for hunk in hunks {
            var oldStart = 1
            var newStart = 1
            for idx in 0 ..< hunk.start {
                switch allDiffLines[idx] {
                case .context:
                    oldStart += 1
                    newStart += 1
                case .deletion:
                    oldStart += 1
                case .addition:
                    newStart += 1
                }
            }

            var oldCount = 0
            var newCount = 0
            for idx in hunk.start ... hunk.end {
                switch allDiffLines[idx] {
                case .context:
                    oldCount += 1
                    newCount += 1
                case .deletion:
                    oldCount += 1
                case .addition:
                    newCount += 1
                }
            }

            diffText += "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@\n"
            for idx in hunk.start ... hunk.end {
                switch allDiffLines[idx] {
                case let .context(line):
                    diffText += " \(line)\n"
                case let .deletion(line):
                    diffText += "-\(line)\n"
                case let .addition(line):
                    diffText += "+\(line)\n"
                }
            }
        }
        return diffText
    }
}

/// Arguments for `files.write`.
public struct FilesWriteArgs: Sendable, Equatable, Decodable {
    public let path: String
    public let content: String
    public let mode: String

    public static let defaultMode = "staged"

    public init(path: String, content: String, mode: String = defaultMode) {
        self.path = path
        self.content = content
        self.mode = mode
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case content
        case mode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.path = try container.decode(String.self, forKey: .path)
        self.content = try container.decode(String.self, forKey: .content)
        self.mode = try container.decodeIfPresent(String.self, forKey: .mode) ?? Self.defaultMode
    }

    public var trimmedPath: String {
        path.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isStaged: Bool {
        mode.lowercased() != "live"
    }
}

/// Payload envelope returned by `files.write`.
public struct FilesWriteEnvelope: Sendable, Equatable, Codable {
    public let status: String
    public let path: String
    public let stagingPath: String?
    public let backupPath: String?
    public let diff: String
    public let additions: Int
    public let deletions: Int
    public let message: String

    public init(
        status: String,
        path: String,
        stagingPath: String? = nil,
        backupPath: String? = nil,
        diff: String,
        additions: Int,
        deletions: Int,
        message: String
    ) {
        self.status = status
        self.path = path
        self.stagingPath = stagingPath
        self.backupPath = backupPath
        self.diff = diff
        self.additions = additions
        self.deletions = deletions
        self.message = message
    }
}

/// Tool providing safe APFS Copy-on-Write file writes and review diffs.
public struct FilesWriteTool: Tool, Sendable {
    public let name = "files.write"

    public let description =
        "Writes or stages changes to a local file with APFS Copy-on-Write backup. "
            + "Defaults to safe 'staged' mode where edits are saved to .rune_<filename> for user review before touching the live file. "
            + "Returns a unified diff of the changes."

    public let inputSchema =
        JSONSchema(
            rawValue: #"{"type":"object","properties":{"path":{"type":"string","description":"File path to write (\"~\" expands to home)"},"#
                + #""content":{"type":"string","description":"Full text content to write to the file"},"#
                + #""mode":{"type":"string","description":"Write mode: 'staged' (default, safe for review) "#
                + #"or 'live' (overwrites live file with .rune_backup_<filename> backup)","enum":["staged","live"]}},"#
                + #""required":["path","content"],"additionalProperties":false}"#
        )

    /// Writes mutate the filesystem (staged copies and live overwrites), so every call
    /// must flow through the permission gate for approval and protected-path denial.
    public let permissionLevel = PermissionLevel.requiresApproval

    private let homeDirectoryURL: URL?
    private let filesConfig: FilesConfig

    public init(homeDirectoryURL: URL? = nil, filesConfig: FilesConfig = FilesConfig()) {
        self.homeDirectoryURL = homeDirectoryURL
        self.filesConfig = filesConfig
    }

    private static func backupExistingFile(liveURL: URL, backupURL: URL) throws {
        if FileManager.default.fileExists(atPath: backupURL.path) {
            try FileManager.default.removeItem(at: backupURL)
        }
        #if os(macOS)
            let ret = clonefile(liveURL.path, backupURL.path, 0)
            if ret != 0 {
                // Fall back to a full copy when APFS cloning is unavailable, and fail closed
                // when the fallback also fails so a live overwrite never proceeds without a backup.
                let copyResult = copyfile(liveURL.path, backupURL.path, nil, copyfile_flags_t(COPYFILE_ALL))
                if copyResult != 0 {
                    let backupErrno = errno
                    throw NSError(
                        domain: NSCocoaErrorDomain,
                        code: CocoaError.fileWriteUnknown.rawValue,
                        userInfo: [
                            NSFilePathErrorKey: liveURL.path,
                            NSLocalizedDescriptionKey:
                                "Could not back up \(liveURL.path) to \(backupURL.path): errno \(backupErrno)"
                        ]
                    )
                }
            }
        #else
            try FileManager.default.copyItem(at: liveURL, to: backupURL)
        #endif
    }

    /// Missing files and non-UTF8 bytes both yield nil so the diff renders
    /// from /dev/null, matching the staged inbox scan which skips undecodable
    /// bytes rather than treating them as empty text.
    private static func readExistingContent(at url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url), let str = String(bytes: data, encoding: .utf8) else {
            return nil
        }
        return str
    }

    public func execute(input: ToolInput, context: ToolContext) async throws -> ToolOutput {
        let args: FilesWriteArgs
        do {
            args = try JSONDecoder().decode(FilesWriteArgs.self, from: Data(input.argumentsJSON.utf8))
        } catch {
            return .failure(
                "Invalid files.write arguments: expected {\"path\": \"<file>\", \"content\": \"<text>\"}.",
                callID: input.callID
            )
        }

        let rawPath = args.trimmedPath
        guard !rawPath.isEmpty else {
            return .failure("Invalid files.write arguments: 'path' must not be empty.", callID: input.callID)
        }

        // Fail closed on mode typos: an unknown mode must not silently inherit
        // the safe staged posture when the schema promises only staged or live.
        let normalizedMode = args.mode.lowercased()
        guard normalizedMode == "staged" || normalizedMode == "live" else {
            return .failure("Invalid files.write arguments: 'mode' must be 'staged' or 'live'.", callID: input.callID)
        }

        let decision = FilesAccessGuard.evaluate(path: rawPath, homeDirectoryURL: homeDirectoryURL, filesConfig: filesConfig)
        guard decision.allowed else {
            return FilesReadHelpers.deniedOutput(
                resolvedPath: decision.resolvedPath,
                reason: decision.reason,
                requiresApproval: decision.requiresApproval,
                callID: input.callID
            )
        }

        let liveURL = URL(fileURLWithPath: decision.resolvedPath)
        let parentDir = liveURL.deletingLastPathComponent()
        let filename = liveURL.lastPathComponent
        let stagingFilename = ".rune_" + filename
        let stagingURL = parentDir.appendingPathComponent(stagingFilename)
        // Live rollbacks keep a distinct sibling so the staged inbox never
        // mistakes a backup for a pending edit with an inverted diff; the
        // inbox scan excludes this prefix while still listing staged copies.
        let backupFilename = ".rune_backup_" + filename
        let backupURL = parentDir.appendingPathComponent(backupFilename)

        // An allowed file does not imply an allowed parent: deny patterns can
        // match ancestor components, so the directory is vetted before it is
        // created or written through.
        let parentDecision = FilesAccessGuard.evaluate(path: parentDir.path, homeDirectoryURL: homeDirectoryURL, filesConfig: filesConfig)
        guard parentDecision.allowed else {
            return FilesReadHelpers.deniedOutput(
                resolvedPath: parentDecision.resolvedPath,
                reason: parentDecision.reason,
                requiresApproval: parentDecision.requiresApproval,
                callID: input.callID
            )
        }

        let fileExists = FileManager.default.fileExists(atPath: liveURL.path)
        let originalContent = Self.readExistingContent(at: liveURL)

        let diffResult = UnifiedDiffEngine.computeDiff(
            oldText: originalContent,
            newText: args.content,
            filepath: filename
        )

        // Previews compute the same diff without touching the filesystem, so
        // approval screens and dry runs observe the change with no staging
        // copy, backup clone, directory creation, or live overwrite.
        if context.dryRun {
            let preview = if args.isStaged {
                FilesWriteEnvelope(
                    status: "preview",
                    path: decision.resolvedPath,
                    stagingPath: stagingURL.path,
                    backupPath: nil,
                    diff: diffResult.diff,
                    additions: diffResult.additions,
                    deletions: diffResult.deletions,
                    message: "Dry run: would stage changes to \(stagingFilename). Live file is unchanged."
                )
            } else {
                FilesWriteEnvelope(
                    status: "preview",
                    path: decision.resolvedPath,
                    stagingPath: nil,
                    backupPath: fileExists ? backupURL.path : nil,
                    diff: diffResult.diff,
                    additions: diffResult.additions,
                    deletions: diffResult.deletions,
                    message: "Dry run: would apply changes live to \(filename)."
                        + (fileExists ? " Backup would save to \(backupFilename)." : "")
                )
            }
            do {
                let data = try JSONEncoder().encode(preview)
                let jsonString = String(bytes: data, encoding: .utf8) ?? "{}"
                return .success(jsonString, callID: input.callID)
            } catch {
                return .failure("Failed encoding write output: \(error.localizedDescription)", callID: input.callID)
            }
        }

        do {
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        } catch {
            return .failure("Could not create directory \(parentDir.path): \(error.localizedDescription)", callID: input.callID)
        }

        // Staged edits leave the live file untouched, so only the live path
        // pays the copy-on-write backup cost; staging must not fail when a
        // backup clone would have failed.
        if !args.isStaged, fileExists {
            do {
                try Self.backupExistingFile(liveURL: liveURL, backupURL: backupURL)
            } catch {
                return .failure("Could not clone file for backup: \(error.localizedDescription)", callID: input.callID)
            }
        }

        let envelope: FilesWriteEnvelope
        if args.isStaged {
            do {
                try Data(args.content.utf8).write(to: stagingURL, options: .atomic)
            } catch {
                return .failure("Failed staging changes to \(stagingURL.path): \(error.localizedDescription)", callID: input.callID)
            }

            envelope = FilesWriteEnvelope(
                status: "staged",
                path: decision.resolvedPath,
                stagingPath: stagingURL.path,
                backupPath: nil,
                diff: diffResult.diff,
                additions: diffResult.additions,
                deletions: diffResult.deletions,
                message: "Changes staged to \(stagingFilename). Live file is unchanged pending user review."
            )
        } else {
            do {
                try Data(args.content.utf8).write(to: liveURL, options: .atomic)
            } catch {
                return .failure("Failed writing to live file \(liveURL.path): \(error.localizedDescription)", callID: input.callID)
            }

            envelope = FilesWriteEnvelope(
                status: "live",
                path: decision.resolvedPath,
                stagingPath: nil,
                backupPath: fileExists ? backupURL.path : nil,
                diff: diffResult.diff,
                additions: diffResult.additions,
                deletions: diffResult.deletions,
                message: "Changes applied live to \(filename)." + (fileExists ? " Backup saved to \(backupFilename)." : "")
            )
        }

        do {
            let data = try JSONEncoder().encode(envelope)
            let jsonString = String(bytes: data, encoding: .utf8) ?? "{}"
            return .success(jsonString, callID: input.callID)
        } catch {
            return .failure("Failed encoding write output: \(error.localizedDescription)", callID: input.callID)
        }
    }
}

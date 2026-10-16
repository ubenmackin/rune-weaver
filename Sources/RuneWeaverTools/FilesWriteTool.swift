// Rune Weaver Tools — APFS Copy-on-Write staging and file write tool (`files.write`).

import Foundation
import RuneWeaverCore

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

    /// Computes the unified diff between `oldText` and `newText`. oldText: Original
    /// text (or nil/empty if new file).
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
    /// Whether the call explicitly supplied `mode`.
    public let modeExplicit: Bool

    public static let defaultMode = "staged"

    public init(path: String, content: String, mode: String = defaultMode, modeExplicit: Bool = false) {
        self.path = path
        self.content = content
        self.mode = mode
        self.modeExplicit = modeExplicit
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
        let requestedMode = try container.decodeIfPresent(String.self, forKey: .mode)
        self.mode = requestedMode ?? Self.defaultMode
        self.modeExplicit = requestedMode != nil
    }

    public var trimmedPath: String {
        path.trimmingCharacters(in: .whitespacesAndNewlines)
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

/// Naming rules for the review artifacts that sit beside a live file.
public enum ReviewArtifacts {
    /// Canonical staging marker beside each live file.
    public static let stagingPrefix = ".rune_"
    /// Canonical rollback marker beside each live file.
    public static let backupPrefix = ".rune_backup_"
    /// Target prefix whose derived staging sibling lands in the rollback family.
    private static let backupNamedTargetPrefix = "backup_"

    /// Derives the staging sibling URL for a live file.
    public static func stagingURL(forLiveURL liveURL: URL) -> URL {
        liveURL.deletingLastPathComponent().appendingPathComponent(stagingPrefix + liveURL.lastPathComponent)
    }

    /// Derives the rollback sibling URL for a live file.
    public static func backupURL(forLiveURL liveURL: URL) -> URL {
        liveURL.deletingLastPathComponent().appendingPathComponent(backupPrefix + liveURL.lastPathComponent)
    }

    /// Reports whether a filename belongs to the rollback-copy namespace.
    public static func isRollbackArtifactFilename(_ filename: String) -> Bool {
        filename.lowercased().hasPrefix(backupPrefix)
    }

    /// Refuses a target filename whose own name or derived sibling collides with a reserved review
    /// artifact.
    static func reservationRefusal(forFilename filename: String) -> String? {
        let lowered = filename.lowercased()
        if lowered.hasPrefix(stagingPrefix) {
            return "Refusing files.write: '\(filename)' is reserved for review artifacts"
                + " (.rune_<name> / .rune_backup_<name>); choose a target outside that namespace."
        }
        if lowered.hasPrefix(backupNamedTargetPrefix) {
            return "Refusing files.write: '\(filename)' would derive the staging sibling"
                + " '\(stagingPrefix + filename)', which collides with the reserved"
                + " .rune_backup_<name> rollback namespace; choose a different target name."
        }
        return nil
    }
}

/// Tool providing safe APFS Copy-on-Write file writes and review diffs.
public struct FilesWriteTool: Tool, Sendable {
    public let name = "files.write"

    /// Model posture: the call chooses staged or live per invocation.
    private static let modelDescription =
        "Writes or stages changes to a local file with APFS Copy-on-Write backup. "
            + "Defaults to safe 'staged' mode where edits are saved to .rune_<filename> for user review before touching the live file. "
            + "Returns a unified diff of the changes."

    /// Forced-staged posture: the owner setting owns the review step.
    private static let stagedModeDescription =
        "Writes or stages changes to a local file with APFS Copy-on-Write backup. "
            + "Owner settings force staged mode: every write is saved to .rune_<filename> for user review before touching the live file, "
            + "and live writes are disabled. "
            + "Returns a unified diff of the changes."

    /// Forced-live posture: the owner setting owns the immediate apply.
    private static let liveModeDescription =
        "Writes or stages changes to a local file with APFS Copy-on-Write backup. "
            + "Owner settings force live mode: writes apply directly to the live file with a .rune_backup_<filename> rollback copy, "
            + "and staged review is disabled. "
            + "Returns a unified diff of the changes."

    /// Model posture keeps the per-call `mode` selector unchanged.
    private static let modelInputSchema =
        JSONSchema(
            rawValue: #"{"type":"object","properties":{"path":{"type":"string","description":"File path to write (\"~\" expands to home)"},"#
                + #""content":{"type":"string","description":"Full text content to write to the file"},"#
                + #""mode":{"type":"string","description":"Write mode: 'staged' (default, safe for review) "#
                + #"or 'live' (overwrites live file with .rune_backup_<filename> backup)","enum":["staged","live"]}},"#
                + #""required":["path","content"],"additionalProperties":false}"#
        )

    /// Forced postures own mode selection, so the schema drops `mode` rather
    /// than advertising a selector the model can never actually use.
    private static let forcedInputSchema =
        JSONSchema(
            rawValue: #"{"type":"object","properties":{"path":{"type":"string","description":"File path to write (\"~\" expands to home)"},"#
                + #""content":{"type":"string","description":"Full text content to write to the file"}},"#
                + #""required":["path","content"],"additionalProperties":false}"#
        )

    /// Human- and LLM-readable summary matching the configured write posture.
    public let description: String
    /// Advertised input schema matching the configured write posture.
    public let inputSchema: JSONSchema

    /// Writes mutate the filesystem (staged copies and live overwrites), so every call
    /// must flow through the permission gate for approval and protected-path denial.
    public let permissionLevel = PermissionLevel.requiresApproval

    private let homeDirectoryURL: URL?
    private let filesConfig: FilesConfig
    private let stagedFilesStore: StagedFilesStore
    /// Propagation seam for a live write that supersedes a pending staged review.
    private let supersededReviewNotifier: (@Sendable (String) async -> Void)?

    public init(
        homeDirectoryURL: URL? = nil,
        filesConfig: FilesConfig = FilesConfig(),
        stagedFilesStore: StagedFilesStore? = nil,
        supersededReviewNotifier: (@Sendable (String) async -> Void)? = nil
    ) {
        self.homeDirectoryURL = homeDirectoryURL
        self.filesConfig = filesConfig
        self.stagedFilesStore = stagedFilesStore ?? StagedFilesStore()
        self.supersededReviewNotifier = supersededReviewNotifier

        // Description and schema are derived once at construction because the
        // settings routes rebuild the files tools on save, which is what makes
        // a changed write_mode visible without a restart.
        switch filesConfig.writeMode {
        case .model:
            description = Self.modelDescription
            inputSchema = Self.modelInputSchema
        case .staged:
            description = Self.stagedModeDescription
            inputSchema = Self.forcedInputSchema
        case .live:
            description = Self.liveModeDescription
            inputSchema = Self.forcedInputSchema
        }
    }

    /// Exact envelope sentence when an explicit live request loses to a forced staged setting.
    private static let requestedLiveOverrideNote = " Requested 'live' mode was overridden by the owner setting files.write_mode = 'staged'."

    /// Exact envelope sentence when an explicit staged request loses to a forced live setting.
    private static let requestedStagedOverrideNote = " Requested 'staged' mode was overridden by the owner setting files.write_mode = 'live'."

    /// Exact envelope sentence when the write-path policy forces staged against
    /// the configured `live` setting.
    private static let policyOverridesConfiguredLiveNote =
        " Owner setting files.write_mode = 'live' was overridden by write path policy: this write is staged for review."

    /// Exact envelope sentence when the write-path policy forces staged against
    /// an explicit live request under the model posture.
    private static let policyOverridesRequestedLiveNote =
        " Requested 'live' mode was overridden by write path policy: this write is staged for review."

    /// Exact envelope sentence when the write-path policy forces live against
    /// the configured `staged` setting.
    private static let policyOverridesConfiguredStagedNote =
        " Owner setting files.write_mode = 'staged' was overridden by write path policy: this write is applied live."

    /// Exact envelope sentence when the write-path policy forces live against
    /// an explicit staged request under the model posture.
    private static let policyOverridesRequestedStagedNote =
        " Requested 'staged' mode was overridden by write path policy: this write is applied live."

    /// Refusal sentence when the review ledger cannot answer, so a live write
    /// has no reliable rollback point to promise.
    private static let unreadableLedgerRefusal = "Could not read the review ledger; live write refused without a reliable rollback point."

    /// Outcome of the write-path posture gate every call runs first.
    private enum PostureGate {
        /// The call may proceed in this resolved posture.
        case proceed(EffectiveWriteMode)
        /// The policy refused the call; the associated output is the failure.
        case refused(ToolOutput)
    }

    /// Runs the write-path posture gate ahead of mode resolution.
    private func resolvePosture(
        rawPath: String,
        args: FilesWriteArgs,
        approved: Bool,
        callID: String
    ) -> PostureGate {
        let requestedMode = args.mode.lowercased()
        let decision = WritePathPolicy.classify(
            path: rawPath,
            filesConfig: filesConfig,
            requestedMode: args.mode,
            homeDirectoryURL: homeDirectoryURL
        )
        if decision.posture == .deny {
            // The reason names policy only, and the refusal lands before any
            // read, staging copy, or live write: nothing on disk moves and
            // no file content enters the envelope.
            return .refused(FilesReadHelpers.deniedOutput(
                resolvedPath: decision.resolvedPath,
                reason: decision.reason,
                requiresApproval: false,
                callID: callID
            ))
        }
        if filesConfig.writeMode == .model {
            // Fail closed on mode typos: an unknown mode must not silently
            // inherit the safe staged posture when the schema promises only
            // staged or live.
            guard requestedMode == "staged" || requestedMode == "live" else {
                return .refused(.failure(
                    "Invalid files.write arguments: 'mode' must be 'staged' or 'live'.",
                    callID: callID
                ))
            }
        }
        if decision.posture == .ask, !approved {
            // A parked approval never self-approves: only a recorded decide
            // authorizes the write, so a missing approval fails closed with
            // nothing on disk touched.
            return .refused(FilesReadHelpers.deniedOutput(
                resolvedPath: decision.resolvedPath,
                reason: decision.reason,
                requiresApproval: true,
                callID: callID
            ))
        }
        // Policy, then owner settings, then the model-authored request; the
        // resolved posture carries any override sentence to every envelope
        // branch so a forced outcome stays honest.
        return .proceed(Self.resolveEffectiveMode(
            posture: decision.posture,
            requestedMode: requestedMode,
            modeExplicit: args.modeExplicit,
            configuredMode: filesConfig.writeMode
        ))
    }

    /// Resolves the posture the call must actually use, layering the write-path decision over the
    /// configured mode and the per-call request.
    private static func resolveEffectiveMode(
        posture: FilesWritePathPosture,
        requestedMode: String,
        modeExplicit: Bool,
        configuredMode: FilesWriteMode
    ) -> EffectiveWriteMode {
        let configured = resolveEffectiveMode(
            requestedMode: requestedMode,
            modeExplicit: modeExplicit,
            configuredMode: configuredMode
        )
        switch posture {
        case .stage:
            // The staged posture already won: keep the configured note when
            // the owner setting itself forced it, otherwise name whichever
            // authority asked for live and lost to the rule.
            if configured.isStaged {
                return configured
            }
            let liveLoser = configuredMode == .live
                ? policyOverridesConfiguredLiveNote
                : policyOverridesRequestedLiveNote
            return EffectiveWriteMode(isStaged: true, overrideNote: liveLoser)
        case .live:
            if !configured.isStaged {
                return configured
            }
            let stagedLoser = configuredMode == .staged
                ? policyOverridesConfiguredStagedNote
                : policyOverridesRequestedStagedNote
            return EffectiveWriteMode(isStaged: false, overrideNote: stagedLoser)
        case .ask, .deny:
            return configured
        }
    }

    /// Resolves the posture the configured `write_mode` plus the per-call request decide, before
    /// any write-path rule is layered on.
    private static func resolveEffectiveMode(
        requestedMode: String,
        modeExplicit: Bool,
        configuredMode: FilesWriteMode
    ) -> EffectiveWriteMode {
        switch configuredMode {
        case .model:
            EffectiveWriteMode(isStaged: requestedMode != "live", overrideNote: nil)
        case .staged:
            EffectiveWriteMode(
                isStaged: true,
                overrideNote: modeExplicit && requestedMode == "live" ? requestedLiveOverrideNote : nil
            )
        case .live:
            EffectiveWriteMode(
                isStaged: false,
                overrideNote: modeExplicit && requestedMode == "staged" ? requestedStagedOverrideNote : nil
            )
        }
    }

    /// Missing files and non-UTF8 bytes both yield nil so the diff renders
    /// from /dev/null, matching the staged inbox scan which skips undecodable
    /// bytes rather than treating them as empty text.
    private static func readExistingContent(at url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            RuneWeaverLog.tools.debug("FilesWriteTool: failed to read existing content at \(url.path): \(error.localizedDescription)")
            return nil
        }
        guard let str = String(bytes: data, encoding: .utf8) else {
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

        // The write-path policy owns posture, so every call passes its gate
        // before mode resolution and before any disk access.
        let effectiveMode: EffectiveWriteMode
        switch resolvePosture(rawPath: rawPath, args: args, approved: context.approved, callID: input.callID) {
        case let .proceed(mode):
            effectiveMode = mode
        case let .refused(output):
            return output
        }

        // Every derived path is vetted before any disk access; a refusal comes
        // back exactly as the guard produced it.
        let target: WriteTarget
        let diffResult: UnifiedDiffEngine.DiffResult
        switch resolveWriteTarget(
            rawPath: rawPath,
            content: args.content,
            effectiveMode: effectiveMode,
            callID: input.callID
        ) {
        case let .vetted(vettedTarget, vettedDiff):
            target = vettedTarget
            diffResult = vettedDiff
        case let .refused(output):
            return output
        }

        // Both postures act on the staging sibling: a live write removes it during supersede
        // cleanup (and `removeItem` deletes directories recursively), while a staged write replaces
        // it with `Data.write(.atomic)`.
        if let refusal = Self.stagingSiblingRefusal(target: target, isStaged: effectiveMode.isStaged) {
            return .failure(refusal, callID: input.callID)
        }

        // Live writes fail closed on an unreadable ledger before any disk mutation; previews
        // degrade to promising nothing, and the disk path re-resolves the authoritative posture
        // inside the store's atomic review start.
        guard let liveReviewLookup = await resolveLiveReviewLookup(
            effectiveMode: effectiveMode,
            livePath: target.liveURL.path,
            dryRun: context.dryRun
        ) else {
            return .failure(Self.unreadableLedgerRefusal, callID: input.callID)
        }

        // Previews compute the same diff without touching the filesystem, so
        // approval screens and dry runs observe the change with no staging
        // copy, backup clone, directory creation, or live overwrite.
        if context.dryRun {
            return makePreviewOutput(
                target: target,
                effectiveMode: effectiveMode,
                liveReviewLookup: liveReviewLookup,
                diffResult: diffResult,
                callID: input.callID
            )
        }

        return await performDiskWrite(
            target: target,
            args: args,
            effectiveMode: effectiveMode,
            diffResult: diffResult,
            callID: input.callID
        )
    }

    private struct WriteTarget {
        let liveURL: URL
        let parentDir: URL
        let filename: String
        let stagingURL: URL
        let stagingFilename: String
        let backupURL: URL
        let backupFilename: String
        let resolvedPath: String
        let fileExists: Bool
    }

    /// Outcome of vetting one write call's derived paths before disk access.
    private enum WriteTargetResolution {
        /// Every derived path passed the guard; the diff describes the change.
        case vetted(target: WriteTarget, diffResult: UnifiedDiffEngine.DiffResult)
        /// A guard refused the call; the associated output is the failure.
        case refused(ToolOutput)
    }

    /// Outcome of the review-ledger read a live write performs before disk.
    private enum LiveReviewLookup {
        /// No row exists: this write starts a fresh review series.
        case absent
        /// A row exists; its `resolution` decides whether this write joins.
        case record(LiveReviewRecord)
        /// The ledger could not be read: a live write refuses, while a preview
        /// makes no promise about the rollback copy.
        case unreadable

        /// True when no row exists, so a copy on disk has no ledger owner.
        var isAbsent: Bool {
            if case .absent = self {
                return true
            }
            return false
        }
    }

    /// How one live write relates to the review-owned rollback copy.
    private struct RollbackPlacement {
        /// True when this write joins an already-pending review, so neither the
        /// review row nor its rollback copy may be touched.
        let joinsPendingReview: Bool
        /// True when this write starts the review over an existing live file,
        /// so a fresh snapshot is taken before the overwrite.
        let startsWithExistingFile: Bool
        /// True when the review's rollback copy is the sibling backup file, so
        /// the envelope may name it.
        let hasRollbackCopy: Bool
    }

    /// The posture a call actually uses once owner settings are applied.
    private struct EffectiveWriteMode {
        /// True when the write must be staged for review.
        let isStaged: Bool
        /// Exact override sentence appended to the envelope when an explicit
        /// request contradicted the forced setting; nil when nothing lost.
        let overrideNote: String?
    }
}

// MARK: - Live write disk flow

extension FilesWriteTool {
    // MARK: - Target vetting

    /// Vets every path a write call derives before any disk access.
    private func resolveWriteTarget(
        rawPath: String,
        content: String,
        effectiveMode: EffectiveWriteMode,
        callID: String
    ) -> WriteTargetResolution {
        let decision = FilesAccessGuard.evaluate(path: rawPath, homeDirectoryURL: homeDirectoryURL, filesConfig: filesConfig)
        guard decision.allowed else {
            return .refused(FilesReadHelpers.deniedOutput(
                resolvedPath: decision.resolvedPath,
                reason: decision.reason,
                requiresApproval: decision.requiresApproval,
                callID: callID
            ))
        }

        let liveURL = URL(fileURLWithPath: decision.resolvedPath)
        let parentDir = liveURL.deletingLastPathComponent()
        let filename = liveURL.lastPathComponent

        // The review-artifact namespaces are owned by the staging/rollback lifecycle, and those
        // siblings share the target directory with other user files.
        if let refusal = ReviewArtifacts.reservationRefusal(forFilename: filename) {
            return .refused(.failure(refusal, callID: callID))
        }

        let stagingURL = ReviewArtifacts.stagingURL(forLiveURL: liveURL)
        let stagingFilename = stagingURL.lastPathComponent
        // Live rollbacks keep a distinct sibling so the staged inbox never
        // mistakes a backup for a pending edit with an inverted diff; the
        // inbox scan excludes this prefix while still listing staged copies.
        let backupURL = ReviewArtifacts.backupURL(forLiveURL: liveURL)

        // An allowed file does not imply an allowed parent: deny patterns can
        // match ancestor components, so the directory is vetted before it is
        // created or written through.
        let parentDecision = FilesAccessGuard.evaluate(path: parentDir.path, homeDirectoryURL: homeDirectoryURL, filesConfig: filesConfig)
        guard parentDecision.allowed else {
            return .refused(FilesReadHelpers.deniedOutput(
                resolvedPath: parentDecision.resolvedPath,
                reason: parentDecision.reason,
                requiresApproval: parentDecision.requiresApproval,
                callID: callID
            ))
        }

        // A live write snapshots to the derived rollback sibling and a decision consumes it, so the
        // sibling is vetted exactly as the review routes vet it: a denied backup path refuses before
        // any disk mutation even when the live path itself passed the guard.
        if !effectiveMode.isStaged {
            let backupDecision = FilesAccessGuard.evaluate(
                path: backupURL.path,
                homeDirectoryURL: homeDirectoryURL,
                filesConfig: filesConfig
            )
            guard backupDecision.allowed else {
                return .refused(FilesReadHelpers.deniedOutput(
                    resolvedPath: backupDecision.resolvedPath,
                    reason: backupDecision.reason,
                    requiresApproval: backupDecision.requiresApproval,
                    callID: callID
                ))
            }
        }
        let backupFilename = backupURL.lastPathComponent

        let fileExists = FileManager.default.fileExists(atPath: liveURL.path)
        let originalContent = Self.readExistingContent(at: liveURL)

        let diffResult = UnifiedDiffEngine.computeDiff(
            oldText: originalContent,
            newText: content,
            filepath: filename
        )

        let target = WriteTarget(
            liveURL: liveURL,
            parentDir: parentDir,
            filename: filename,
            stagingURL: stagingURL,
            stagingFilename: stagingFilename,
            backupURL: backupURL,
            backupFilename: backupFilename,
            resolvedPath: decision.resolvedPath,
            fileExists: fileExists
        )
        return .vetted(target: target, diffResult: diffResult)
    }

    /// Decides how this live write relates to the review-owned rollback copy.
    private static func rollbackPlacement(target: WriteTarget, lookup: LiveReviewLookup) -> RollbackPlacement {
        switch lookup {
        case let .record(review) where review.resolution == nil:
            let hasRollbackCopy = review.backupPath != nil
            return RollbackPlacement(
                joinsPendingReview: true,
                startsWithExistingFile: false,
                hasRollbackCopy: hasRollbackCopy
            )
        case .record, .absent:
            return RollbackPlacement(
                joinsPendingReview: false,
                startsWithExistingFile: target.fileExists,
                hasRollbackCopy: target.fileExists
            )
        case .unreadable:
            // The ledger could not answer, so promise nothing: a live write
            // refuses before reaching here, and a preview stays silent about a
            // backup that may never be created.
            return RollbackPlacement(
                joinsPendingReview: false,
                startsWithExistingFile: false,
                hasRollbackCopy: false
            )
        }
    }

    /// Resolves the pre-write review-ledger posture for a write call. Live disk writes fail closed
    /// on an unreadable ledger before any disk mutation, because they would otherwise overwrite a
    /// file with no reliable way back.
    private func resolveLiveReviewLookup(
        effectiveMode: EffectiveWriteMode,
        livePath: String,
        dryRun: Bool
    ) async -> LiveReviewLookup? {
        guard !effectiveMode.isStaged else { return .absent }
        do {
            let review = try await stagedFilesStore.liveReview(forPath: livePath)
            return review.map(LiveReviewLookup.record) ?? .absent
        } catch {
            return dryRun ? .unreadable : nil
        }
    }

    /// Sentence naming how a live preview would relate to the rollback copy,
    /// if at all. The conditional tense keeps an unexecuted plan from reading
    /// as a completed one.
    private static func previewBackupSentence(target: WriteTarget, placement: RollbackPlacement) -> String {
        if placement.joinsPendingReview {
            return placement.hasRollbackCopy
                ? " Existing rollback copy would be preserved at \(target.backupFilename)."
                : ""
        }
        guard placement.startsWithExistingFile else { return "" }
        return " Backup would save to \(target.backupFilename)."
    }

    /// Refusal sentence when a live write finds a rollback entry that the ledger cannot attribute
    /// to a settled series, or nil when the entry is absent or accounted for.
    private static func unexplainedBackupRefusal(backupURL: URL, previousSeriesSettled: Bool) -> String? {
        guard !previousSeriesSettled,
              LiveFileBackup.entryExists(at: backupURL)
        else {
            return nil
        }
        return "An unexplained rollback copy already exists at \(backupURL.lastPathComponent);"
            + " refusing to overwrite it. Resolve or remove it before writing live again."
    }

    /// Refusal sentence when a fresh snapshot would find the rollback destination occupied by a
    /// regular file, or nil when the entry is absent or not a regular file.
    private static func leftoverBackupRefusal(backupURL: URL) -> String? {
        guard LiveFileBackup.isRegularFileNoFollow(backupURL) else { return nil }
        return "A rollback copy already exists at \(backupURL.lastPathComponent);"
            + " refusing to overwrite it. Remove it before writing live again."
    }

    /// Refusal sentence when a fresh snapshot would fail, or nil when the snapshot would succeed.
    private static func freshSnapshotRefusal(target: WriteTarget) -> String? {
        if let refusal = leftoverBackupRefusal(backupURL: target.backupURL) {
            return refusal
        }
        if let refusal = LiveFileBackup.snapshotSourceRefusal(liveURL: target.liveURL, backupURL: target.backupURL) {
            return refusal
        }
        return LiveFileBackup.snapshotDestinationRefusal(liveURL: target.liveURL, backupURL: target.backupURL)
    }

    /// Refusal sentence when a write's staging sibling is a non-regular entry, or nil when the
    /// sibling is absent or a regular file.
    private static func stagingSiblingRefusal(target: WriteTarget, isStaged: Bool) -> String? {
        let stagingURL = target.stagingURL
        guard FileManager.default.fileExists(atPath: stagingURL.path),
              !LiveFileBackup.isRegularFile(stagingURL)
        else {
            return nil
        }
        let posture = isStaged ? "staged" : "live"
        let fate = isStaged ? "overwritten" : "removed"
        return "Refusing \(posture) write: the staging sibling \(target.stagingFilename) is not a regular file and will not be \(fate)."
    }

    private func makePreviewOutput(
        target: WriteTarget,
        effectiveMode: EffectiveWriteMode,
        liveReviewLookup: LiveReviewLookup,
        diffResult: UnifiedDiffEngine.DiffResult,
        callID: String?
    ) -> ToolOutput {
        let overrideNote = effectiveMode.overrideNote ?? ""
        // A disk write refuses an unexplained rollback copy because no ledger
        // row owns it, so the preview carries the same refusal instead of
        // promising a write that disk would reject.
        if !effectiveMode.isStaged, liveReviewLookup.isAbsent,
           let refusal = Self.unexplainedBackupRefusal(backupURL: target.backupURL, previousSeriesSettled: false)
        {
            return .failure(refusal, callID: callID)
        }
        // Computed up front so each if-expression branch stays a single
        // expression; the staged branch simply ignores the live placement.
        let placement = Self.rollbackPlacement(target: target, lookup: liveReviewLookup)
        // A fresh series over an existing live file must snapshot, and the snapshot refuses both a
        // non-regular live source and any entry already at its destination: the preview carries the
        // same refusals instead of promising a write that disk would reject.
        if !effectiveMode.isStaged, placement.startsWithExistingFile,
           let refusal = Self.freshSnapshotRefusal(target: target)
        {
            return .failure(refusal, callID: callID)
        }
        let preview = if effectiveMode.isStaged {
            FilesWriteEnvelope(
                status: "preview",
                path: target.resolvedPath,
                stagingPath: target.stagingURL.path,
                backupPath: nil,
                diff: diffResult.diff,
                additions: diffResult.additions,
                deletions: diffResult.deletions,
                message: "Dry run: would stage changes to \(target.stagingFilename). Live file is unchanged." + overrideNote
            )
        } else {
            FilesWriteEnvelope(
                status: "preview",
                path: target.resolvedPath,
                stagingPath: nil,
                backupPath: placement.hasRollbackCopy ? target.backupURL.path : nil,
                diff: diffResult.diff,
                additions: diffResult.additions,
                deletions: diffResult.deletions,
                message: "Dry run: would apply changes live to \(target.filename)."
                    + Self.previewBackupSentence(target: target, placement: placement)
                    + overrideNote
            )
        }
        return encodeEnvelope(preview, callID: callID)
    }

    private func performDiskWrite(
        target: WriteTarget,
        args: FilesWriteArgs,
        effectiveMode: EffectiveWriteMode,
        diffResult: UnifiedDiffEngine.DiffResult,
        callID: String?
    ) async -> ToolOutput {
        do {
            try FileManager.default.createDirectory(at: target.parentDir, withIntermediateDirectories: true)
        } catch {
            return .failure("Could not create directory \(target.parentDir.path): \(error.localizedDescription)", callID: callID)
        }

        if effectiveMode.isStaged {
            return await performStagedWrite(
                target: target,
                args: args,
                effectiveMode: effectiveMode,
                diffResult: diffResult,
                callID: callID
            )
        }
        return await performLiveWrite(
            target: target,
            args: args,
            effectiveMode: effectiveMode,
            diffResult: diffResult,
            callID: callID
        )
    }

    /// Writes the staged sibling and records its pending review. Staging never snapshots: the live
    /// file stays untouched, so a rollback snapshot failure must not be able to block a safe staged
    /// edit.
    private func performStagedWrite(
        target: WriteTarget,
        args: FilesWriteArgs,
        effectiveMode: EffectiveWriteMode,
        diffResult: UnifiedDiffEngine.DiffResult,
        callID: String?
    ) async -> ToolOutput {
        do {
            try Data(args.content.utf8).write(to: target.stagingURL, options: .atomic)
        } catch {
            return .failure("Failed staging changes to \(target.stagingURL.path): \(error.localizedDescription)", callID: callID)
        }

        await stagedFilesStore.recordStaged(
            path: target.liveURL.path,
            stagingPath: target.stagingURL.path,
            updatedAt: Date()
        )

        let envelope = FilesWriteEnvelope(
            status: "staged",
            path: target.resolvedPath,
            stagingPath: target.stagingURL.path,
            backupPath: nil,
            diff: diffResult.diff,
            additions: diffResult.additions,
            deletions: diffResult.deletions,
            message: "Changes staged to \(target.stagingFilename). Live file is unchanged pending user review."
                + (effectiveMode.overrideNote ?? "")
        )
        return encodeEnvelope(envelope, callID: callID)
    }

    /// Applies the live write around the review-owned rollback copy.
    private func performLiveWrite(
        target: WriteTarget,
        args: FilesWriteArgs,
        effectiveMode: EffectiveWriteMode,
        diffResult: UnifiedDiffEngine.DiffResult,
        callID: String?
    ) async -> ToolOutput {
        let liveURL = target.liveURL
        let backupURL = target.backupURL
        let content = args.content
        let start = await stagedFilesStore.startLiveReview(
            path: liveURL.path,
            applyingWrite: {
                // Writing inside the store's critical section is what keeps the ledger and the
                // filesystem from diverging: a decision cannot consume the joined rollback copy
                // between the start's return and this write.
                try Data(content.utf8).write(to: liveURL, options: .atomic)
            },
            snapshot: { previousSeriesSettled in
                // A copy the ledger cannot attribute to a settled series may be a
                // peer's just-captured original that has not reached the ledger
                // yet, so it is never replaced on a guess.
                if let refusal = Self.unexplainedBackupRefusal(backupURL: backupURL, previousSeriesSettled: previousSeriesSettled) {
                    return .refused(reason: refusal)
                }
                guard FileManager.default.fileExists(atPath: liveURL.path) else {
                    return .noCopy
                }
                // A fresh snapshot creates exclusively and never deletes at the destination, so a
                // regular copy already there — a settled series' leftover or a peer's in-flight
                // capture — refuses before the clone is attempted.
                if let refusal = Self.leftoverBackupRefusal(backupURL: backupURL) {
                    return .refused(reason: refusal)
                }
                // The snapshot's no-follow source guard refuses a live path that is not a regular
                // file; surfacing the shared refusal sentence here keeps the disk error identical to
                // the preview instead of reporting the clone's wrapped description.
                if let refusal = LiveFileBackup.snapshotSourceRefusal(liveURL: liveURL, backupURL: backupURL) {
                    return .refused(reason: refusal)
                }
                // The snapshot's exclusive create also refuses every non-regular entry at the
                // destination, which the leftover check above deliberately leaves to the snapshot's
                // own no-follow probe; mirroring that predicate here keeps the disk sentence.
                if let refusal = LiveFileBackup.snapshotDestinationRefusal(liveURL: liveURL, backupURL: backupURL) {
                    return .refused(reason: refusal)
                }
                do {
                    try LiveFileBackup.snapshot(liveURL: liveURL, backupURL: backupURL)
                    return .captured(backupPath: backupURL.path)
                } catch {
                    // Every predicted refusal fired above, so a throw here is a
                    // genuine clone/copy failure (or an entry racing past the
                    // probes) with no shared sentence to surface.
                    return .refused(reason: "Could not clone file for backup: \(error.localizedDescription)")
                }
            }
        )

        let backupPath: String?
        let rollbackSentence: String
        switch start {
        case .unreadable:
            return .failure(Self.unreadableLedgerRefusal, callID: callID)
        case let .refused(reason):
            return .failure(reason, callID: callID)
        case let .writeFailed(reason):
            return .failure("Failed writing to live file \(target.liveURL.path): \(reason)", callID: callID)
        case let .started(startedBackupPath):
            backupPath = startedBackupPath
            rollbackSentence = startedBackupPath == nil ? "" : " Backup saved to \(target.backupFilename)."
        case let .joined(joinedBackupPath):
            backupPath = joinedBackupPath
            rollbackSentence = joinedBackupPath == nil
                ? ""
                : " Existing rollback copy preserved at \(target.backupFilename)."
        }

        // A live write supersedes any previously staged edit for this path.
        let supersededStagedRow = await stagedFilesStore.resolveStaged(
            pathOrStagingPath: target.liveURL.path,
            resolution: .superseded
        )
        if FileManager.default.fileExists(atPath: target.stagingURL.path) {
            // `removeItem` deletes directories recursively, so only a regular file may be removed;
            // the pre-write check already refused a non-regular entry, and this guard keeps a race
            // from slipping a directory past that check.
            if LiveFileBackup.isRegularFile(target.stagingURL) {
                do {
                    try FileManager.default.removeItem(at: target.stagingURL)
                } catch {
                    // The row is already marked superseded, so an orphan
                    // sibling would turn invisible with no crawl to surface
                    // it; surface the failure instead of swallowing it.
                    let stagingPath = target.stagingURL.path
                    RuneWeaverLog.tools.error(
                        "files.write: failed removing superseded staging sibling at \(stagingPath): \(error.localizedDescription)"
                    )
                }
            } else {
                let stagingPath = target.stagingURL.path
                RuneWeaverLog.tools.error(
                    "files.write: superseded staging sibling at \(stagingPath) is not a regular file; leaving it in place."
                )
            }
        }

        if supersededStagedRow {
            // The staged row left the pending inbox without a route call, so an already-mounted
            // dashboard card would otherwise keep offering Accept/Discard on a sibling this write
            // deleted.
            await supersededReviewNotifier?(target.liveURL.path)
        }

        let envelope = FilesWriteEnvelope(
            status: "live",
            path: target.resolvedPath,
            stagingPath: nil,
            backupPath: backupPath == nil ? nil : target.backupURL.path,
            diff: diffResult.diff,
            additions: diffResult.additions,
            deletions: diffResult.deletions,
            message: "Changes applied live to \(target.filename)."
                + rollbackSentence
                + (effectiveMode.overrideNote ?? "")
        )
        return encodeEnvelope(envelope, callID: callID)
    }

    /// Encodes one write envelope into the tool's JSON success shape.
    private func encodeEnvelope(_ envelope: FilesWriteEnvelope, callID: String?) -> ToolOutput {
        do {
            let data = try JSONEncoder().encode(envelope)
            let jsonString = String(bytes: data, encoding: .utf8) ?? "{}"
            return .success(jsonString, callID: callID)
        } catch {
            return .failure("Failed encoding write output: \(error.localizedDescription)", callID: callID)
        }
    }
}

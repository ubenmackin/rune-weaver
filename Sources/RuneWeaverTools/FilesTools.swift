// Rune Weaver Tools — Local file tools (`files.read`, `files.grep`, `files.glob`) plus Seatbelt staging.

import Foundation
import RuneWeaverCore

/// Cadence gate shared by the `files.grep` and `files.glob` progress emitters.
struct FilesProgressThrottle {
    /// Work trigger: visits since the last report that open the gate on their own.
    static let fileInterval = 250
    /// Time floor mirrored from `ToolProgress` so both walkers share the wire timing.
    static let minimumSpacing = Duration.nanoseconds(Int64(ToolProgress.minimumReportIntervalNanoseconds))

    /// Visits counted at the last report; nil until the walk seeds the gate.
    private var lastReportedScanned: Int?
    /// Monotonic instant of the last report; nil until the walk seeds the gate.
    private var lastReportedInstant: ContinuousClock.Instant?

    /// Seeds the gate so the first file cannot report ahead of either threshold.
    /// scanned: Visit count at the start of the walk (normally zero).
    mutating func begin(scanned: Int, now: ContinuousClock.Instant) {
        lastReportedScanned = scanned
        lastReportedInstant = now
    }

    /// Reports whether the walk should emit progress for the visit just completed.
    func shouldReport(scanned: Int, now: ContinuousClock.Instant) -> Bool {
        guard let lastScanned = lastReportedScanned, let lastInstant = lastReportedInstant else {
            return true
        }
        let hasNewWork = scanned > lastScanned
        let spacingElapsed = now - lastInstant >= Self.minimumSpacing
        let crossedInterval = scanned - lastScanned >= Self.fileInterval
        return (spacingElapsed && hasNewWork) || crossedInterval
    }

    /// Records an emitted report so the next thresholds are measured from it.
    /// scanned: Visit count reported.
    mutating func markReported(scanned: Int, now: ContinuousClock.Instant) {
        lastReportedScanned = scanned
        lastReportedInstant = now
    }

    /// Floors a monotonic duration to whole milliseconds for display.
    /// - Parameter duration: Elapsed monotonic time.
    /// - Returns: Non-negative whole milliseconds.
    static func elapsedMilliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        let milliseconds = Double(components.seconds) * 1000
            + Double(components.attoseconds) / 1_000_000_000_000_000
        return max(0, Int(milliseconds))
    }
}

/// Scope copy for `files.glob` progress and prompt guidance.
public enum FilesGlobScopeWarning: Sendable {
    /// Warning copy describing a home-wide scan.
    public static let entireHomeCopy = "entire home folder"

    /// Reports whether a pattern is broad enough to call out on its own.
    public static func isBroad(_ pattern: String) -> Bool {
        if pattern == "*" || pattern == "**" {
            return true
        }
        guard !pattern.contains("/"), pattern.hasPrefix("*.") else {
            return false
        }
        let suffix = pattern.dropFirst(2)
        guard !suffix.isEmpty else { return false }
        return !suffix.contains { $0 == "*" || $0 == "?" || $0 == "[" || $0 == "]" }
    }

    /// Warning copy for a scan, or nil when the scan is already narrow. pattern:
    /// Trimmed glob pattern.
    public static func warningCopy(pattern: String, baseDirOmitted: Bool) -> String? {
        guard baseDirOmitted, isBroad(pattern) else { return nil }
        return entireHomeCopy
    }

    /// Builds the display line carried by progress frames. pattern: Trimmed glob
    /// pattern.
    public static func findMessage(pattern: String, scope: String?) -> String {
        guard let scope else {
            return "Find \(pattern)"
        }
        return "Find \(pattern) in \(scope)"
    }
}

/// Reduces a raw final path component to a safe progress tail. A root (`/`) or blank component
/// names no file, so it degrades to nil and the frame omits its tail rather than rendering an
/// absolute or empty value.
private func filesDisplayTail(_ component: String) -> String? {
    guard !component.isEmpty, component != "/" else { return nil }
    return component
}

/// Renders a resolved path as dashboard-safe scope copy, or nil when no safe scope can be named.
func filesScopeDisplay(resolvedPath: String, homeDirectoryURL: URL?) -> String? {
    let home = FilesAccessGuard.resolvedHomeURL(overriding: homeDirectoryURL).path
    if resolvedPath == home {
        return "~"
    }
    let prefix = home.hasSuffix("/") ? home : home + "/"
    if resolvedPath.hasPrefix(prefix) {
        return "~/" + String(resolvedPath.dropFirst(prefix.count))
    }
    return filesDisplayTail((resolvedPath as NSString).lastPathComponent)
}

/// Expresses a candidate file relative to the search root for progress display.
func filesRelativeDisplayPath(for fileURL: URL, root: URL) -> String? {
    let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
    if fileURL.path.hasPrefix(rootPrefix) {
        let relative = String(fileURL.path.dropFirst(rootPrefix.count))
        if !relative.isEmpty {
            return relative
        }
    }
    return filesDisplayTail(fileURL.lastPathComponent)
}

/// Read-only `files.read` tool for bounded local file reads.
public struct FilesReadTool: Tool, Sendable {
    /// Stable tool name referenced by the LLM and memory.
    public let name = "files.read"
    /// When the LLM should use this tool.
    public let description =
        "Reads a local text file with a line window. "
            + "Use when the user asks to open, quote, or summarize a file on disk. "
            + "Pass path plus optional 1-indexed offset and limit (default 2000 lines, max 5000). "
            + "Returns the canonical path, byte size, truncation flag, and text; sensitive paths fail with an approval hint. "
            + "Cloud shortcuts \"iCloud\", \"iCloud Drive\", \"Dropbox\", \"OneDrive\", "
            + "\"Google Drive\", \"GoogleDrive\" (plus \"~/\" forms and subpaths) resolve to live mounts."
    /// Function-calling contract for `path`, `offset`, `limit`, and `encoding`.
    public let inputSchema =
        JSONSchema(
            rawValue: #"{"type":"object","properties":{"path":{"type":"string","description":"File path to read "#
                + #"(\"~\" expands to home; \"iCloud\", \"iCloud Drive\", \"Dropbox\", "#
                + #"\"OneDrive\", \"Google Drive\", \"GoogleDrive\" plus \"~/\" forms and "#
                + #"subpaths expand to cloud roots)"},"#
                + #""offset":{"type":"integer","description":"1-indexed first "#
                + #"line to return (default 1)","minimum":1},"limit":{"type":"integer","description":"Maximum lines "#
                + #"(1-5000, default 2000)","minimum":1,"maximum":5000},"encoding":{"type":"string","description":"Text "#
                + #"encoding name (UTF-8 only in v1; omit for UTF-8)"}},"required":["path"],"additionalProperties":false}"#
        )
    /// Always allowed at the gate level; sensitive paths escalate via the failure hint instead.
    public let permissionLevel = PermissionLevel.readOnly

    /// Maximum bytes read from disk per call (1 MB).
    public static let maxFileBytes = 1_048_576

    /// Home boundary override for tests. Nil means the real home.
    private let homeDirectoryURL: URL?

    /// `[files]` policy enforced through the shared guard. Defaults to the built-in defaults.
    private let filesConfig: FilesConfig

    /// Creates a read tool.
    public init(homeDirectoryURL: URL? = nil, filesConfig: FilesConfig = FilesConfig()) {
        self.homeDirectoryURL = homeDirectoryURL
        self.filesConfig = filesConfig
    }

    /// Reads the requested line window, enforcing the guard first.
    public func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        let args: FilesReadArgs
        switch FilesReadHelpers.decodedReadArgs(input.argumentsJSON, callID: input.callID) {
        case let .success(decoded):
            args = decoded
        case let .failure(failure):
            return failure.output
        }
        // Guard before disk: denied paths never reach the filesystem, so no existence oracle or
        // byte leak can ride the failure message.
        let decision = FilesAccessGuard.evaluate(path: args.trimmedPath, homeDirectoryURL: homeDirectoryURL, filesConfig: filesConfig)
        guard decision.allowed else {
            return FilesReadHelpers.deniedOutput(
                resolvedPath: decision.resolvedPath,
                reason: decision.reason,
                requiresApproval: decision.requiresApproval,
                callID: input.callID
            )
        }
        let pinned: FilesReadHelpers.PinnedFileRead
        switch FilesReadHelpers.readPinnedFile(
            rawPath: args.trimmedPath,
            decision: decision,
            homeDirectoryURL: homeDirectoryURL,
            filesConfig: filesConfig,
            callID: input.callID
        ) {
        case let .success(read):
            pinned = read
        case let .failure(failure):
            return failure.output
        }
        let envelope = FilesReadHelpers.windowedEnvelope(args: args, pinned: pinned)
        do {
            let content = try FilesToolEncoding.encodeReadEnvelope(envelope)
            return .success(content, callID: input.callID)
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
    }
}

/// Arguments for the `files.grep` tool.
public struct FilesGrepArgs: Sendable, Equatable, Decodable {
    /// Regular expression matched against each text line.
    public let pattern: String
    /// File or directory root to search.
    public let path: String
    /// Optional filename glob narrowing candidates.
    public let include: String?
    /// Maximum matches to return, clamped to `1...200`.
    public let maxResults: Int
    /// Whether to recurse into subdirectories.
    public let recursive: Bool

    /// Default match count when the caller omits `maxResults`.
    public static let defaultMaxResults = 50
    /// Upper bound for `maxResults` so noisy patterns stay bounded.
    public static let maxMaxResults = 200
    /// Upper bound for `pattern` (and `include`) length so pathological inputs fail fast.
    public static let maxPatternChars = 500

    /// Memberwise initializer with `maxResults` clamping.
    public init(pattern: String, path: String, include: String? = nil, maxResults: Int = defaultMaxResults, recursive: Bool = true) {
        self.pattern = pattern
        self.path = path
        self.include = include
        self.maxResults = min(max(maxResults, 1), Self.maxMaxResults)
        self.recursive = recursive
    }

    private enum CodingKeys: String, CodingKey {
        case pattern
        case path
        case include
        case maxResults
        case maxResultsSnake = "max_results"
        case limit
        case recursive
    }

    /// Decodes arguments, accepting `max_results`/`limit` aliases and clamping `maxResults`.
    /// - Parameter decoder: Decoder for the arguments document.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let pattern = try container.decode(String.self, forKey: .pattern)
        let path = try container.decode(String.self, forKey: .path)
        let include = try container.decodeIfPresent(String.self, forKey: .include)
        // Alias tolerance keeps model-emitted `limit` working without
        // forking the schema; the first present alias wins.
        let rawMax = try container.decodeIfPresent(Int.self, forKey: .maxResults)
            ?? container.decodeIfPresent(Int.self, forKey: .maxResultsSnake)
            ?? container.decodeIfPresent(Int.self, forKey: .limit)
            ?? Self.defaultMaxResults
        let rec = try container.decodeIfPresent(Bool.self, forKey: .recursive) ?? true
        self.init(pattern: pattern, path: path, include: include, maxResults: rawMax, recursive: rec)
    }

    /// Trimmed regex source.
    public var trimmedPattern: String {
        pattern.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Trimmed search root.
    public var trimmedPath: String {
        path.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Trimmed include glob, nil when omitted or blank.
    public var trimmedInclude: String? {
        guard let include else { return nil }
        let trimmed = include.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// One grep hit: the canonical file, 1-indexed line, and bounded preview.
public struct FilesGrepMatch: Sendable, Equatable, Codable {
    /// Canonical file path holding the match.
    public let path: String
    /// 1-indexed line number within the file.
    public let line: Int
    /// Matching line text, capped at 200 characters.
    public let preview: String

    /// Creates a grep hit.
    public init(path: String, line: Int, preview: String) {
        self.path = path
        self.line = line
        self.preview = preview
    }
}

/// Envelope wrapping `files.grep` success output.
public struct FilesGrepEnvelope: Sendable, Equatable, Codable {
    /// Matches in sorted-path, ascending-line order.
    public let matches: [FilesGrepMatch]
    /// Whether matches past the cap were left unreported.
    public let truncated: Bool

    /// Creates a grep envelope.
    public init(matches: [FilesGrepMatch], truncated: Bool) {
        self.matches = matches
        self.truncated = truncated
    }
}

/// Arguments for the `files.glob` tool.
public struct FilesGlobArgs: Sendable, Equatable, Decodable {
    /// Glob pattern relative to `baseDir`.
    public let pattern: String
    /// Base directory root, nil when omitted (home boundary).
    public let baseDir: String?
    /// Maximum paths to return, clamped to `1...500`.
    public let maxResults: Int
    /// Whether to recurse into subdirectories.
    public let recursive: Bool

    /// Default path count when the caller omits `maxResults`.
    public static let defaultMaxResults = 100
    /// Upper bound for `maxResults` so `**/*` over a large tree stays bounded.
    public static let maxMaxResults = 500
    /// Upper bound for `pattern` length so pathological inputs fail fast.
    public static let maxPatternChars = 500

    /// Memberwise initializer with `maxResults` clamping.
    public init(pattern: String, baseDir: String? = nil, maxResults: Int = defaultMaxResults, recursive: Bool = true) {
        self.pattern = pattern
        self.baseDir = baseDir
        self.maxResults = min(max(maxResults, 1), Self.maxMaxResults)
        self.recursive = recursive
    }

    private enum CodingKeys: String, CodingKey {
        case pattern
        case baseDir
        case baseDirSnake = "base_dir"
        case basedir
        case maxResults
        case maxResultsSnake = "max_results"
        case limit
        case recursive
    }

    /// Decodes arguments, accepting snake-case and `limit` aliases.
    /// - Parameter decoder: Decoder for the arguments document.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let pattern = try container.decode(String.self, forKey: .pattern)
        let baseDir = try container.decodeIfPresent(String.self, forKey: .baseDir)
            ?? container.decodeIfPresent(String.self, forKey: .baseDirSnake)
            ?? container.decodeIfPresent(String.self, forKey: .basedir)
        let rawMax = try container.decodeIfPresent(Int.self, forKey: .maxResults)
            ?? container.decodeIfPresent(Int.self, forKey: .maxResultsSnake)
            ?? container.decodeIfPresent(Int.self, forKey: .limit)
            ?? Self.defaultMaxResults
        let rec = try container.decodeIfPresent(Bool.self, forKey: .recursive) ?? true
        self.init(pattern: pattern, baseDir: baseDir, maxResults: rawMax, recursive: rec)
    }

    /// Trimmed glob pattern.
    public var trimmedPattern: String {
        pattern.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Trimmed base directory, nil when omitted or blank.
    public var trimmedBaseDir: String? {
        guard let baseDir else { return nil }
        let trimmed = baseDir.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Envelope wrapping `files.glob` success output.
public struct FilesGlobEnvelope: Sendable, Equatable, Codable {
    /// Sorted canonical paths matching the glob.
    public let paths: [String]
    /// Whether paths past the cap were left unreported.
    public let truncated: Bool

    /// Creates a glob envelope.
    public init(paths: [String], truncated: Bool) {
        self.paths = paths
        self.truncated = truncated
    }
}

/// Shared glob matching for `files.grep` include filters and `files.glob`.
public enum FilesGlobMatching: Sendable {
    /// Reports whether a glob tries to climb with a `..` segment.
    /// - Parameter pattern: Glob pattern.
    /// - Returns: True when any `/`-separated segment is `..`.
    public static func containsDotDot(_ pattern: String) -> Bool {
        SharedGlobMatching.containsDotDot(pattern)
    }

    /// Reports whether a relative path matches a glob. pattern: Glob pattern.
    public static func matches(pattern: String, relativePath: String) -> Bool {
        SharedGlobMatching.matches(pattern: pattern, relativePath: relativePath)
    }

    /// Reports whether a path matches a glob pattern, following the Git and VS Code convention:
    /// patterns without a slash match against the filename component at any depth; slash-bearing
    /// patterns match against the root-relative path.
    public static func matchesPath(pattern: String, relativePath: String, filename: String) -> Bool {
        SharedGlobMatching.matchesPath(pattern: pattern, relativePath: relativePath, filename: filename)
    }

    /// Converts a glob to an anchored regular-expression source.
    /// - Parameter pattern: Glob pattern.
    /// - Returns: Anchored regex source matching the whole input.
    public static func regexSource(fromGlob pattern: String) -> String {
        SharedGlobMatching.regexSource(fromGlob: pattern)
    }
}

/// Read-only `files.grep` tool for regex search over local text files.
public struct FilesGrepTool: Tool, Sendable {
    /// Stable tool name referenced by the LLM and memory.
    public let name = "files.grep"
    /// When the LLM should use this tool.
    public let description =
        "Searches local text files for a regex pattern. "
            + "Use when the user asks to find text across files. "
            + "Pass pattern (RE2-safe regex, max 500 chars) plus a file or directory path, "
            + "optional include filename glob (e.g. *.swift), and maxResults (1-200, default 50). "
            + "Returns matching lines with 200-char previews and a truncation flag; sensitive paths fail with an approval hint. "
            + "Pass recursive false to search only the immediate children of the searched directory (default true). "
            + "Cloud shortcuts \"iCloud\", \"iCloud Drive\", \"Dropbox\", \"OneDrive\", "
            + "\"Google Drive\", \"GoogleDrive\" (plus \"~/\" forms and subpaths) resolve to live mounts."
    /// Function-calling contract for `pattern`, `path`, `include`, `maxResults`, and `recursive`.
    public let inputSchema =
        JSONSchema(
            rawValue: #"{"type":"object","properties":{"pattern":{"type":"string","description":"Regular expression "#
                + #"matched per line (RE2-safe, max 500 chars)"},"path":{"type":"string","description":"File or "#
                + #"directory to search (\"~\" expands to home; \"iCloud\", \"iCloud Drive\", "#
                + #"\"Dropbox\", \"OneDrive\", \"Google Drive\", \"GoogleDrive\" plus \"~/\" "#
                + #"forms and subpaths expand to cloud roots)"},"#
                + #""include":{"type":"string","description":"Optional "#
                + #"filename glob narrowing candidates (e.g. *.swift)"},"maxResults":{"type":"integer","description":"Maximum "#
                + #"matches (1-200, default 50)","minimum":1,"maximum":200},"recursive":{"type":"boolean","description":"Whether "#
                + #"to recurse into subdirectories (default true). Pass false to search only the immediate children of the searched directory."}}"#
                + #","required":["pattern","path"],"additionalProperties":false}"#
        )
    /// Always allowed at the gate level; sensitive paths escalate via the failure hint instead.
    public let permissionLevel = PermissionLevel.readOnly

    /// Maximum bytes searched per file (2 MB); larger files are skipped.
    public static let maxFileBytes = 2 * 1024 * 1024
    /// Maximum characters per match preview so long lines cannot flood context.
    public static let maxPreviewChars = 200

    /// Home boundary override for tests. Nil means the real home.
    private let homeDirectoryURL: URL?

    /// `[files]` policy enforced through the shared guard. Defaults to the built-in defaults.
    private let filesConfig: FilesConfig

    /// Monotonic instant source for progress throttling. Injectable so tests can
    /// advance the cadence deterministically; production reads the live clock.
    private let nowProvider: @Sendable () -> ContinuousClock.Instant

    /// Creates a grep tool.
    public init(homeDirectoryURL: URL? = nil, filesConfig: FilesConfig = FilesConfig()) {
        self.homeDirectoryURL = homeDirectoryURL
        self.filesConfig = filesConfig
        self.nowProvider = { ContinuousClock().now }
    }

    /// Creates a grep tool with an injectable monotonic clock so progress cadence can be exercised
    /// without sleeping. homeDirectoryURL: Home boundary override, or nil for the
    /// real home.
    init(
        homeDirectoryURL: URL? = nil,
        filesConfig: FilesConfig = FilesConfig(),
        nowProvider: @escaping @Sendable () -> ContinuousClock.Instant
    ) {
        self.homeDirectoryURL = homeDirectoryURL
        self.filesConfig = filesConfig
        self.nowProvider = nowProvider
    }

    /// Searches the requested root, enforcing the guard first.
    public func execute(input: ToolInput, context: ToolContext) async throws -> ToolOutput {
        let args: FilesGrepArgs
        do {
            args = try JSONDecoder().decode(FilesGrepArgs.self, from: Data(input.argumentsJSON.utf8))
        } catch {
            return .failure(
                "Invalid files.grep arguments: expected {\"pattern\": \"<regex>\", \"path\": \"<file-or-dir>\"}.",
                callID: input.callID
            )
        }
        let rawPattern = args.trimmedPattern
        guard !rawPattern.isEmpty else {
            return .failure("Invalid files.grep arguments: 'pattern' must not be empty.", callID: input.callID)
        }
        guard rawPattern.count <= FilesGrepArgs.maxPatternChars else {
            return .failure(
                "Invalid files.grep arguments: 'pattern' must be at most \(FilesGrepArgs.maxPatternChars) characters.",
                callID: input.callID
            )
        }
        let rawPath = args.trimmedPath
        guard !rawPath.isEmpty else {
            return .failure("Invalid files.grep arguments: 'path' must not be empty.", callID: input.callID)
        }
        if let include = args.trimmedInclude {
            guard include.count <= FilesGrepArgs.maxPatternChars else {
                return .failure(
                    "Invalid files.grep arguments: 'include' must be at most \(FilesGrepArgs.maxPatternChars) characters.",
                    callID: input.callID
                )
            }
            if FilesGlobMatching.containsDotDot(include) {
                return .failure("Invalid files.grep arguments: 'include' must not contain '..'.", callID: input.callID)
            }
        }
        if let unsupported = Self.re2UnsupportedReason(for: rawPattern) {
            return .failure("Unsupported regex '\(rawPattern)': \(unsupported)", callID: input.callID)
        }
        let expression: NSRegularExpression
        do {
            expression = try NSRegularExpression(pattern: rawPattern)
        } catch {
            return .failure("Invalid regex '\(rawPattern)': \(error.localizedDescription)", callID: input.callID)
        }
        // Guard before disk: a denied root never reaches FileManager, so no
        // existence oracle or byte leak can ride the failure message.
        let decision = FilesAccessGuard.evaluate(path: rawPath, homeDirectoryURL: homeDirectoryURL, filesConfig: filesConfig)
        guard decision.allowed else {
            return deniedOutput(
                resolvedPath: decision.resolvedPath,
                reason: decision.reason,
                requiresApproval: decision.requiresApproval,
                callID: input.callID
            )
        }
        let startURL = URL(fileURLWithPath: decision.resolvedPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: startURL.path, isDirectory: &isDirectory) else {
            return .failure("Path not found: \(decision.resolvedPath)", callID: input.callID)
        }
        let scan = try await scanMatches(
            root: startURL,
            isDirectory: isDirectory.boolValue,
            resolvedPath: decision.resolvedPath,
            expression: expression,
            args: args,
            context: context
        )
        let envelope = FilesGrepEnvelope(matches: scan.matches, truncated: scan.truncated)
        do {
            let content = try FilesToolEncoding.encodeGrepEnvelope(envelope)
            return .success(content, callID: input.callID)
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
    }

    /// Walks the root's candidates in one counted pass, matching `expression` and emitting advisory
    /// progress frames on the shared cadence.
    private func scanMatches(
        root: URL,
        isDirectory: Bool,
        resolvedPath: String,
        expression: NSRegularExpression,
        args: FilesGrepArgs,
        context: ToolContext
    ) async throws -> (matches: [FilesGrepMatch], truncated: Bool) {
        // Progress is advisory and throttled to the shared cadence; the scope copy
        // renders the search root relative to home so a frame never discloses an
        // absolute path.
        let scope = filesScopeDisplay(resolvedPath: resolvedPath, homeDirectoryURL: homeDirectoryURL)
        let progressMessage = scope.map { "Search \(args.trimmedPattern) in \($0)" }
            ?? "Search \(args.trimmedPattern)"
        let startInstant = nowProvider()
        var throttle = FilesProgressThrottle()
        throttle.begin(scanned: 0, now: startInstant)
        var scanned = 0
        var matches: [FilesGrepMatch] = []
        var totalMatched = 0

        // Visits one candidate file: counts the visit, appends any hits, and emits
        // progress. Extracted so a single-file root and a walked directory share the
        // same counted path.
        func visit(_ fileURL: URL) async throws {
            scanned += 1
            let includesFile = args.trimmedInclude.map {
                includeMatches(include: $0, fileURL: fileURL, root: root)
            } ?? true
            if includesFile, let lines = searchableLines(at: fileURL) {
                for (index, line) in lines.enumerated() {
                    // Cooperative cancel inside the line loop so a costly pattern over a large file
                    // aborts with the turn instead of hanging it; the per-file check above alone
                    // would let one file monopolize the turn.
                    if index & 15 == 0 {
                        try Task.checkCancellation()
                    }
                    let range = NSRange(line.startIndex ..< line.endIndex, in: line)
                    guard expression.firstMatch(in: line, range: range) != nil else {
                        continue
                    }
                    totalMatched += 1
                    // An unsorted walk finds files in arbitrary order, so keep only the
                    // lexicographically first `maxResults` hits; that reproduces the sorted prefix
                    // the old sorted-candidate scan returned without holding every hit from a noisy.
                    Self.insertBounded(
                        FilesGrepMatch(path: fileURL.path, line: index + 1, preview: Self.preview(line)),
                        into: &matches,
                        limit: args.maxResults
                    )
                }
            }
            // Emitted after the file so `matched` counts the visit just completed.
            let now = nowProvider()
            if throttle.shouldReport(scanned: scanned, now: now) {
                throttle.markReported(scanned: scanned, now: now)
                await context.progress(ToolProgress(
                    message: progressMessage,
                    scanned: scanned,
                    matched: totalMatched,
                    elapsedMs: FilesProgressThrottle.elapsedMilliseconds(now - startInstant),
                    current: filesRelativeDisplayPath(for: fileURL, root: root)
                ))
            }
        }

        if isDirectory {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: args.recursive ? [] : [.skipsSubdirectoryDescendants],
                errorHandler: { _, _ in true }
            ) else {
                return ([], false)
            }
            // `DirectoryEnumerator`'s `makeIterator()` is unavailable from async
            // contexts, so pull entries synchronously; the `await`s in the body
            // are unaffected and `skipDescendants()` still prunes descendants.
            var visited = 0
            while let element = enumerator.nextObject() {
                try Task.checkCancellation()
                visited += 1
                if visited % 50 == 0 {
                    await Task.yield()
                }
                guard let url = element as? URL else {
                    continue
                }
                // Content-blind prune: the guard never opens the file, so
                // skipping here cannot leak bytes.
                let decision = FilesAccessGuard.evaluate(url: url, homeDirectoryURL: homeDirectoryURL, filesConfig: filesConfig)
                guard decision.allowed else {
                    if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                if !args.recursive, (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    enumerator.skipDescendants()
                }
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    continue
                }
                try await visit(URL(fileURLWithPath: decision.resolvedPath))
            }
        } else {
            // Single-file roots still pass the descendant check: a file the
            // guard allows is searchable, anything else already failed above.
            try await visit(root)
        }
        return (matches, totalMatched > args.maxResults)
    }

    /// Inserts a hit, keeping `matches` ordered by path then line and capped at `limit`.
    private static func insertBounded(_ match: FilesGrepMatch, into matches: inout [FilesGrepMatch], limit: Int) {
        var low = 0
        var high = matches.count
        while low < high {
            let mid = (low + high) / 2
            let candidate = matches[mid]
            if candidate.path < match.path || (candidate.path == match.path && candidate.line < match.line) {
                low = mid + 1
            } else {
                high = mid
            }
        }
        matches.insert(match, at: low)
        if matches.count > limit {
            matches.removeLast()
        }
    }

    /// RE2-safe pattern policy lives in `FilesGrepHelpers` so this tool stays
    /// within budget; every search vets its pattern there before any file opens.
    /// Reports whether a file passes the optional include filter.
    private func includeMatches(include: String, fileURL: URL, root: URL) -> Bool {
        let filename = fileURL.lastPathComponent
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let relative = if fileURL.path.hasPrefix(rootPath) {
            String(fileURL.path.dropFirst(rootPath.count))
        } else {
            ""
        }
        return FilesGlobMatching.matchesPath(pattern: include, relativePath: relative, filename: filename)
    }

    /// Reads a file's searchable lines, or nil when the file is skipped.
    private func searchableLines(at url: URL) -> [String]? {
        let pinned: (handle: FileHandle, resolvedPath: String)
        do {
            pinned = try FilesAccessGuard.openNoFollowAndValidate(
                path: url.path,
                homeDirectoryURL: homeDirectoryURL,
                filesConfig: filesConfig
            )
        } catch {
            return nil
        }
        let handle = pinned.handle
        defer { try? handle.close() }
        do {
            let end = try handle.seekToEnd()
            guard end <= UInt64(Self.maxFileBytes) else {
                return nil
            }
            try handle.seek(toOffset: 0)
        } catch {
            return nil
        }
        let data: Data
        do {
            var accumulated = Data()
            while true {
                guard let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty else {
                    break
                }
                accumulated.append(chunk)
                guard accumulated.count <= Self.maxFileBytes else {
                    return nil
                }
            }
            data = accumulated
        } catch {
            return nil
        }
        guard !data.contains(0x00) else {
            return nil
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return NormalizedText.splitLines(text)
    }

    /// Builds the approval-escalation failure without file bytes.
    private func deniedOutput(resolvedPath: String, reason: String?, requiresApproval: Bool, callID: String) -> ToolOutput {
        let detail = reason ?? "Searching this path requires explicit approval."
        let envelope = FilesDeniedEnvelope(
            error: "Access denied: \(detail)",
            path: resolvedPath,
            approvalRequired: requiresApproval,
            reason: detail
        )
        do {
            let content = try FilesToolEncoding.encodeDeniedEnvelope(envelope)
            return .failure(content, callID: callID)
        } catch {
            return .failure("Access denied: \(detail)", callID: callID)
        }
    }

    /// Caps a matching line to the preview ceiling.
    private static func preview(_ line: String) -> String {
        guard line.count > maxPreviewChars else {
            return line
        }
        return String(line.prefix(maxPreviewChars))
    }
}

/// Read-only `files.glob` tool for listing paths by glob.
public struct FilesGlobTool: Tool, Sendable {
    /// Stable tool name referenced by the LLM and memory.
    public let name = "files.glob"
    /// When the LLM should use this tool.
    public let description =
        "Lists local paths matching a glob pattern. "
            + "Use when the user asks to find files by name. "
            + "Patterns without '/' (e.g. *.md or config.json) match filenames at any depth under baseDir. "
            + "Patterns with '/' (e.g. src/**/*.swift or docs/*.md) match paths relative to baseDir. "
            + "Pass pattern (*, ?, **, [...], max 500 chars, no '..'), "
            + "always pass the narrowest baseDir that covers the target, and maxResults (1-500, default 100). "
            + "Omitting baseDir searches the entire home directory, so pass it unless a home-wide scan is intended. "
            + "Returns sorted paths with a truncation flag; sensitive paths are pruned, denied bases fail with an approval hint. "
            + "Cloud shortcuts \"iCloud\", \"iCloud Drive\", \"Dropbox\", \"OneDrive\", "
            + "\"Google Drive\", \"GoogleDrive\" (plus \"~/\" forms and subpaths) resolve to live mounts."
    /// Function-calling contract for `pattern`, `baseDir`, and `maxResults`.
    public let inputSchema =
        JSONSchema(
            rawValue: #"{"type":"object","properties":{"pattern":{"type":"string","description":"Glob pattern "#
                + #"(*, ?, **, [...]; max 500 chars; no '..'). Patterns without '/' (e.g. *.md, config.json) match "#
                + #"filenames at any depth under baseDir. Patterns with '/' match paths relative to baseDir."},"baseDir":{"type":"string","description":"Base "#
                + #"directory to search; prefer the narrowest directory (\"~\" expands to home; "#
                + #"\"iCloud\", \"iCloud Drive\", \"Dropbox\", \"OneDrive\", \"Google Drive\", "#
                + #"\"GoogleDrive\" plus \"~/\" forms and subpaths expand to cloud roots). "#
                + #"Omitted searches the entire home directory"},"maxResults":{"type":"integer","description":"Maximum "#
                + #"paths (1-500, default 100)","minimum":1,"maximum":500},"recursive":{"type":"boolean","description":"Whether "#
                + #"to recurse into subdirectories (default true). Pass false to search only the immediate children of baseDir."}}"#
                + #","required":["pattern"],"additionalProperties":false}"#
        )
    /// Always allowed at the gate level; sensitive paths escalate via the failure hint instead.
    public let permissionLevel = PermissionLevel.readOnly

    /// Home boundary override for tests. Nil means the real home.
    private let homeDirectoryURL: URL?

    /// `[files]` policy enforced through the shared guard. Defaults to the built-in defaults.
    private let filesConfig: FilesConfig

    /// Monotonic instant source for progress throttling. Injectable so tests can
    /// advance the cadence deterministically; production reads the live clock.
    private let nowProvider: @Sendable () -> ContinuousClock.Instant

    /// Creates a glob tool.
    public init(homeDirectoryURL: URL? = nil, filesConfig: FilesConfig = FilesConfig()) {
        self.homeDirectoryURL = homeDirectoryURL
        self.filesConfig = filesConfig
        self.nowProvider = { ContinuousClock().now }
    }

    /// Creates a glob tool with an injectable monotonic clock so progress cadence can be exercised
    /// without sleeping. homeDirectoryURL: Home boundary override, or nil for the
    /// real home.
    init(
        homeDirectoryURL: URL? = nil,
        filesConfig: FilesConfig = FilesConfig(),
        nowProvider: @escaping @Sendable () -> ContinuousClock.Instant
    ) {
        self.homeDirectoryURL = homeDirectoryURL
        self.filesConfig = filesConfig
        self.nowProvider = nowProvider
    }

    /// Lists paths matching the glob, enforcing the guard first.
    public func execute(input: ToolInput, context: ToolContext) async throws -> ToolOutput {
        let args: FilesGlobArgs
        do {
            args = try JSONDecoder().decode(FilesGlobArgs.self, from: Data(input.argumentsJSON.utf8))
        } catch {
            return .failure(
                "Invalid files.glob arguments: expected {\"pattern\": \"<glob>\"}.",
                callID: input.callID
            )
        }
        let rawPattern = args.trimmedPattern
        guard !rawPattern.isEmpty else {
            return .failure("Invalid files.glob arguments: 'pattern' must not be empty.", callID: input.callID)
        }
        guard rawPattern.count <= FilesGlobArgs.maxPatternChars else {
            return .failure(
                "Invalid files.glob arguments: 'pattern' must be at most \(FilesGlobArgs.maxPatternChars) characters.",
                callID: input.callID
            )
        }
        // Dot-dot rejection runs before any disk access so escape attempts
        // fail as invalid input, not as approval prompts an attacker could
        // use to probe which escapes the policy notices.
        if FilesGlobMatching.containsDotDot(rawPattern) {
            return .failure("Invalid files.glob arguments: 'pattern' must not contain '..'.", callID: input.callID)
        }
        if rawPattern.hasPrefix("/") {
            return .failure("Invalid files.glob arguments: 'pattern' must be relative to baseDir, not absolute.", callID: input.callID)
        }
        let baseRaw: String = if let trimmed = args.trimmedBaseDir {
            trimmed
        } else {
            FilesAccessGuard.resolvedHomeURL(overriding: homeDirectoryURL).path
        }
        // Guard before disk: a denied base never reaches FileManager.
        let baseDecision = FilesAccessGuard.evaluate(path: baseRaw, homeDirectoryURL: homeDirectoryURL, filesConfig: filesConfig)
        guard baseDecision.allowed else {
            return deniedOutput(
                resolvedPath: baseDecision.resolvedPath,
                reason: baseDecision.reason,
                requiresApproval: baseDecision.requiresApproval,
                callID: input.callID
            )
        }
        let baseURL = URL(fileURLWithPath: baseDecision.resolvedPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: baseURL.path, isDirectory: &isDirectory) else {
            return .failure("Base directory not found: \(baseDecision.resolvedPath)", callID: input.callID)
        }
        guard isDirectory.boolValue else {
            return .failure("Not a directory: \(baseDecision.resolvedPath)", callID: input.callID)
        }
        let baseDirOmitted = args.trimmedBaseDir == nil
        let scope = filesScopeDisplay(resolvedPath: baseDecision.resolvedPath, homeDirectoryURL: homeDirectoryURL)
        let progressWarning = FilesGlobScopeWarning.warningCopy(pattern: rawPattern, baseDirOmitted: baseDirOmitted)
        let progressMessage = FilesGlobScopeWarning.findMessage(pattern: rawPattern, scope: scope)
        var matched = try await collectGlobMatches(
            baseURL: baseURL,
            rawPattern: rawPattern,
            recursive: args.recursive,
            progressMessage: progressMessage,
            progressWarning: progressWarning,
            context: context
        )
        // Lexicographic sort keeps repeated listings deterministic no
        // matter how the filesystem enumerates.
        matched.sort()
        let truncated = matched.count > args.maxResults
        let envelope = FilesGlobEnvelope(paths: Array(matched.prefix(args.maxResults)), truncated: truncated)
        do {
            let content = try FilesToolEncoding.encodeGlobEnvelope(envelope)
            return .success(content, callID: input.callID)
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
    }

    /// Walks `baseURL` in one counted pass, matching `rawPattern` and emitting advisory progress
    /// frames on the shared cadence.
    private func collectGlobMatches(
        baseURL: URL,
        rawPattern: String,
        recursive: Bool,
        progressMessage: String,
        progressWarning: String?,
        context: ToolContext
    ) async throws -> [String] {
        let prefix = baseURL.path.hasSuffix("/") ? baseURL.path : baseURL.path + "/"
        let startInstant = nowProvider()
        var throttle = FilesProgressThrottle()
        throttle.begin(scanned: 0, now: startInstant)
        var scanned = 0
        var matched: [String] = []
        guard let enumerator = FileManager.default.enumerator(
            at: baseURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: recursive ? [] : [.skipsSubdirectoryDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return matched
        }
        // `DirectoryEnumerator`'s `makeIterator()` is unavailable from async
        // contexts, so pull entries synchronously; the `await`s in the body
        // are unaffected and `skipDescendants()` still prunes descendants.
        var visited = 0
        while let element = enumerator.nextObject() {
            try Task.checkCancellation()
            visited += 1
            if visited % 50 == 0 {
                await Task.yield()
            }
            guard let url = element as? URL else {
                continue
            }
            // Content-blind prune: the guard never opens the entry, so
            // skipping here cannot leak bytes.
            let decision = FilesAccessGuard.evaluate(url: url, homeDirectoryURL: homeDirectoryURL, filesConfig: filesConfig)
            guard decision.allowed else {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            if !recursive, (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                enumerator.skipDescendants()
            }
            guard decision.resolvedPath.hasPrefix(prefix) else {
                continue
            }
            let relative = String(decision.resolvedPath.dropFirst(prefix.count))
            guard !relative.isEmpty else {
                continue
            }
            scanned += 1
            if FilesGlobMatching.matchesPath(pattern: rawPattern, relativePath: relative, filename: url.lastPathComponent) {
                matched.append(decision.resolvedPath)
            }
            // Emitted after the match so `matched` counts the visit just completed;
            // `relative` is already root-relative and guard-pruned, so a denied
            // path can never surface as `current`.
            let now = nowProvider()
            if throttle.shouldReport(scanned: scanned, now: now) {
                throttle.markReported(scanned: scanned, now: now)
                await context.progress(ToolProgress(
                    message: progressMessage,
                    warning: progressWarning,
                    scanned: scanned,
                    matched: matched.count,
                    elapsedMs: FilesProgressThrottle.elapsedMilliseconds(now - startInstant),
                    current: relative
                ))
            }
        }
        return matched
    }

    /// Builds the approval-escalation failure without file bytes.
    private func deniedOutput(resolvedPath: String, reason: String?, requiresApproval: Bool, callID: String) -> ToolOutput {
        let detail = reason ?? "Listing this path requires explicit approval."
        let envelope = FilesDeniedEnvelope(
            error: "Access denied: \(detail)",
            path: resolvedPath,
            approvalRequired: requiresApproval,
            reason: detail
        )
        do {
            let content = try FilesToolEncoding.encodeDeniedEnvelope(envelope)
            return .failure(content, callID: callID)
        } catch {
            return .failure("Access denied: \(detail)", callID: callID)
        }
    }
}

/// Seatbelt-confined staging for remaining document writes.
public enum SeatbeltTempStaging: Sendable {
    /// Leading name component for temp directories and files.
    public static let tempPrefix = "runeweaver-doc-"
    /// Errors thrown while staging or committing temp files.
    public struct StagingError: LocalizedError, Sendable {
        /// Human-readable reason without file contents.
        public let message: String
        /// Creates a staging error.
        /// - Parameter message: Human-readable reason.
        public init(_ message: String) {
            self.message = message
        }

        /// Human-readable reason for display.
        public var errorDescription: String? {
            message
        }
    }

    /// Creates an owner-only temp directory for staged document writes.
    public static func makeTempDirectory(prefix: String = tempPrefix) throws -> URL {
        try SeatbeltProfileBuilder.makeConfinedTempDirectory(prefix: prefix)
    }

    /// Stages bytes as one temp file inside a confined temp directory.
    public static func stageBytes(_ bytes: Data, filename: String, in directory: URL) throws -> URL {
        let base = (filename as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = base.isEmpty ? "document" : base.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\0", with: "_")
        let name = "\(UUID().uuidString)-\(cleaned)"
        let url = directory.appendingPathComponent(name, isDirectory: false)
        try bytes.write(to: url, options: .atomic)
        return url
    }

    /// Atomically moves a staged temp file into the workspace on approval.
    @discardableResult
    public static func atomicMoveTempFile(
        at tempURL: URL,
        to destinationPath: String,
        homeDirectoryURL: URL? = nil,
        filesConfig: FilesConfig = FilesConfig()
    ) throws -> String {
        let decision = FilesAccessGuard.evaluate(path: destinationPath, homeDirectoryURL: homeDirectoryURL, filesConfig: filesConfig)
        guard decision.allowed else {
            discardTemp(at: tempURL)
            throw StagingError(decision.reason ?? "Destination requires explicit approval.")
        }
        let destination = URL(fileURLWithPath: decision.resolvedPath, isDirectory: false)
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: tempURL)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: destination)
            }
            return decision.resolvedPath
        } catch {
            discardTemp(at: tempURL)
            throw StagingError("Could not commit staged file: \(error.localizedDescription)")
        }
    }

    /// Best-effort removes a staged temp file or directory.
    public static func discardTemp(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Factory registering the LLM-invokable file tools on a `ToolBus`.
public enum FilesTools {
    /// Tool names in registration order.
    public static let toolNames = ["files.read", "files.grep", "files.glob", "files.list", "files.write"]

    /// Builds the file tools.
    public static func makeTools(
        homeDirectoryURL: URL? = nil,
        filesConfig: FilesConfig = FilesConfig(),
        stagedFilesStore: StagedFilesStore? = nil,
        supersededReviewNotifier: (@Sendable (String) async -> Void)? = nil
    ) -> [any Tool] {
        let read: any Tool = FilesReadTool(homeDirectoryURL: homeDirectoryURL, filesConfig: filesConfig)
        let grep: any Tool = FilesGrepTool(homeDirectoryURL: homeDirectoryURL, filesConfig: filesConfig)
        let glob: any Tool = FilesGlobTool(homeDirectoryURL: homeDirectoryURL, filesConfig: filesConfig)
        let list: any Tool = FilesListTool(homeDirectoryURL: homeDirectoryURL, filesConfig: filesConfig)
        let write: any Tool = FilesWriteTool(
            homeDirectoryURL: homeDirectoryURL,
            filesConfig: filesConfig,
            stagedFilesStore: stagedFilesStore,
            supersededReviewNotifier: supersededReviewNotifier
        )
        return [read, grep, glob, list, write]
    }

    /// Registers the file tools, replacing same-named entries.
    public static func register(
        on bus: ToolBus,
        homeDirectoryURL: URL? = nil,
        filesConfig: FilesConfig = FilesConfig(),
        stagedFilesStore: StagedFilesStore? = nil,
        supersededReviewNotifier: (@Sendable (String) async -> Void)? = nil
    ) async {
        for tool in makeTools(
            homeDirectoryURL: homeDirectoryURL,
            filesConfig: filesConfig,
            stagedFilesStore: stagedFilesStore,
            supersededReviewNotifier: supersededReviewNotifier
        ) {
            await bus.register(tool: tool)
        }
    }
}

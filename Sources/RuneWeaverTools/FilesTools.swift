// Rune Weaver Tools — Local file tools (`files.read`, `files.grep`, `files.glob`) plus Seatbelt staging.

import Foundation
import RuneWeaverCore

/// Read-only `files.read` tool for bounded local file reads.
public struct FilesReadTool: Tool, Sendable {
    /// Stable tool name referenced by the LLM and memory.
    public let name = "files.read"
    /// When the LLM should use this tool.
    public let description =
        "Reads a local text file with a line window. "
            + "Use when the user asks to open, quote, or summarize a file on disk. "
            + "Pass path plus optional 1-indexed offset and limit (default 2000 lines, max 5000). "
            + "Returns the canonical path, byte size, truncation flag, and text; sensitive paths fail with an approval hint."
    /// Function-calling contract for `path`, `offset`, `limit`, and `encoding`.
    public let inputSchema =
        JSONSchema(
            rawValue: #"{"type":"object","properties":{"path":{"type":"string","description":"File path to read "#
                + #"(\"~\" expands to the home directory)"},"offset":{"type":"integer","description":"1-indexed first "#
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
        // Guard before disk: denied paths never reach the filesystem, so no
        // existence oracle or byte leak can ride the failure message. Byte
        // reads then open through the no-follow helper so the descriptor pins
        // the inode while its live path is re-validated, closing a symlink
        // swap between the first check and the read.
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

    /// Default match count when the caller omits `maxResults`.
    public static let defaultMaxResults = 50
    /// Upper bound for `maxResults` so noisy patterns stay bounded.
    public static let maxMaxResults = 200
    /// Upper bound for `pattern` (and `include`) length so pathological inputs fail fast.
    public static let maxPatternChars = 500

    /// Memberwise initializer with `maxResults` clamping.
    public init(pattern: String, path: String, include: String? = nil, maxResults: Int = defaultMaxResults) {
        self.pattern = pattern
        self.path = path
        self.include = include
        self.maxResults = min(max(maxResults, 1), Self.maxMaxResults)
    }

    private enum CodingKeys: String, CodingKey {
        case pattern
        case path
        case include
        case maxResults
        case maxResultsSnake = "max_results"
        case limit
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
        self.init(pattern: pattern, path: path, include: include, maxResults: rawMax)
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

    /// Default path count when the caller omits `maxResults`.
    public static let defaultMaxResults = 100
    /// Upper bound for `maxResults` so `**/*` over a large tree stays bounded.
    public static let maxMaxResults = 500
    /// Upper bound for `pattern` length so pathological inputs fail fast.
    public static let maxPatternChars = 500

    /// Memberwise initializer with `maxResults` clamping.
    public init(pattern: String, baseDir: String? = nil, maxResults: Int = defaultMaxResults) {
        self.pattern = pattern
        self.baseDir = baseDir
        self.maxResults = min(max(maxResults, 1), Self.maxMaxResults)
    }

    private enum CodingKeys: String, CodingKey {
        case pattern
        case baseDir
        case baseDirSnake = "base_dir"
        case basedir
        case maxResults
        case maxResultsSnake = "max_results"
        case limit
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
        self.init(pattern: pattern, baseDir: baseDir, maxResults: rawMax)
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
    public static func containsDotDot(_ pattern: String) -> Bool {
        pattern.split(separator: "/", omittingEmptySubsequences: true).contains { $0 == ".." }
    }

    /// Reports whether a relative path matches a glob.
    public static func matches(pattern: String, relativePath: String) -> Bool {
        let source = regexSource(fromGlob: pattern)
        guard let expression = try? NSRegularExpression(pattern: source) else {
            return false
        }
        let range = NSRange(relativePath.startIndex ..< relativePath.endIndex, in: relativePath)
        return expression.firstMatch(in: relativePath, range: range) != nil
    }

    /// Converts a glob to an anchored regular-expression source.
    public static func regexSource(fromGlob pattern: String) -> String {
        var source = "^"
        let chars = Array(pattern)
        var index = chars.startIndex
        while index < chars.endIndex {
            let char = chars[index]
            if char == "*" {
                let next = chars.index(after: index)
                if next < chars.endIndex, chars[next] == "*" {
                    let afterStars = chars.index(after: next)
                    if afterStars < chars.endIndex, chars[afterStars] == "/" {
                        source += "(.*/)?"
                        index = chars.index(after: afterStars)
                    } else {
                        source += ".*"
                        index = afterStars
                    }
                } else {
                    source += "[^/]*"
                    index = next
                }
            } else if char == "?" {
                source += "[^/]"
                index = chars.index(after: index)
            } else if char == "[" {
                // Copy character classes verbatim, translating glob
                // negation `[!...]` to regex `[^...]`; an unterminated
                // class falls back to a literal bracket.
                var closing: Int?
                var cursor = chars.index(after: index)
                var first = true
                while cursor < chars.endIndex {
                    if chars[cursor] == "]", !first {
                        closing = cursor
                        break
                    }
                    // A leading `]` or `!` is literal content, not the end.
                    first = false
                    cursor = chars.index(after: cursor)
                }
                if let closing {
                    var content = String(chars[chars.index(after: index) ..< closing])
                    if content.hasPrefix("!") {
                        content = "^" + String(content.dropFirst())
                    }
                    // Escape backslashes inside the class so the regex
                    // engine sees the intended set.
                    content = content.replacingOccurrences(of: "\\", with: "\\\\")
                    source += "[" + content + "]"
                    index = chars.index(after: closing)
                } else {
                    source += "\\["
                    index = chars.index(after: index)
                }
            } else if char == "\\" || char == "." || char == "+" || char == "(" || char == ")"
                || char == "|" || char == "^" || char == "$" || char == "{" || char == "}"
            {
                source += "\\\(char)"
                index = chars.index(after: index)
            } else {
                source.append(char)
                index = chars.index(after: index)
            }
        }
        source += "$"
        return source
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
            + "Returns matching lines with 200-char previews and a truncation flag; sensitive paths fail with an approval hint."
    /// Function-calling contract for `pattern`, `path`, `include`, and `maxResults`.
    public let inputSchema =
        JSONSchema(
            rawValue: #"{"type":"object","properties":{"pattern":{"type":"string","description":"Regular expression "#
                + #"matched per line (RE2-safe, max 500 chars)"},"path":{"type":"string","description":"File or "#
                + #"directory to search (\"~\" expands to the home directory)"},"include":{"type":"string","description":"Optional "#
                + #"filename glob narrowing candidates (e.g. *.swift)"},"maxResults":{"type":"integer","description":"Maximum "#
                + #"matches (1-200, default 50)","minimum":1,"maximum":200}},"required":["pattern","path"],"additionalProperties":false}"#
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

    /// Creates a grep tool.
    public init(homeDirectoryURL: URL? = nil, filesConfig: FilesConfig = FilesConfig()) {
        self.homeDirectoryURL = homeDirectoryURL
        self.filesConfig = filesConfig
    }

    /// Searches the requested root, enforcing the guard first.
    public func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
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
        let candidates: [URL] = if isDirectory.boolValue {
            prunedFiles(under: startURL)
        } else {
            // Single-file roots still pass the descendant check: a file the
            // guard allows is searchable, anything else already failed above.
            [startURL]
        }
        // Sorted roots keep match order deterministic across filesystems
        // whose enumeration order is undefined.
        let ordered = candidates.sorted { $0.path < $1.path }
        var matches: [FilesGrepMatch] = []
        var truncated = false
        outer: for fileURL in ordered {
            try Task.checkCancellation()
            if let include = args.trimmedInclude, !includeMatches(include: include, fileURL: fileURL, root: startURL) {
                continue
            }
            guard let lines = searchableLines(at: fileURL) else {
                continue
            }
            for (index, line) in lines.enumerated() {
                // Cooperative cancel inside the line loop so a costly pattern over a
                // large file aborts with the turn instead of hanging it; the per-file
                // check above alone would let one file monopolize the turn. Checked
                // periodically to keep the fast path cheap while staying responsive.
                if index & 15 == 0 {
                    try Task.checkCancellation()
                }
                let range = NSRange(line.startIndex ..< line.endIndex, in: line)
                guard expression.firstMatch(in: line, range: range) != nil else {
                    continue
                }
                if matches.count >= args.maxResults {
                    truncated = true
                    break outer
                }
                matches.append(FilesGrepMatch(path: fileURL.path, line: index + 1, preview: Self.preview(line)))
            }
        }
        let envelope = FilesGrepEnvelope(matches: matches, truncated: truncated)
        do {
            let content = try FilesToolEncoding.encodeGrepEnvelope(envelope)
            return .success(content, callID: input.callID)
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
    }

    /// RE2-safe pattern policy lives in `FilesGrepHelpers` so this tool stays
    /// within budget; every search vets its pattern there before any file opens.
    /// Reports whether a file passes the optional include filter.
    private func includeMatches(include: String, fileURL: URL, root: URL) -> Bool {
        let filename = fileURL.lastPathComponent
        if FilesGlobMatching.matches(pattern: include, relativePath: filename) {
            return true
        }
        // Fall back to the root-relative path for slash-bearing includes;
        // single-file roots have no relative parent, so only the filename
        // applies there.
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        if fileURL.path.hasPrefix(rootPath) {
            let relative = String(fileURL.path.dropFirst(rootPath.count))
            if !relative.isEmpty, FilesGlobMatching.matches(pattern: include, relativePath: relative) {
                return true
            }
        }
        return false
    }

    /// Lists searchable files under a directory, pruning guard denials.
    private func prunedFiles(under root: URL) -> [URL] {
        var files: [URL] = []
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return []
        }
        for element in enumerator {
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
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                continue
            }
            files.append(URL(fileURLWithPath: decision.resolvedPath))
        }
        return files
    }

    /// Reads a file's searchable lines, or nil when the file is skipped.
    /// Bytes come from the pinned no-follow descriptor with its live path
    /// re-validated, so a symlink swapped after pruning cannot redirect the
    /// read; denied, symlinked, or oversized files skip without leaking bytes.
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
        "Lists local paths matching a glob. "
            + "Use when the user asks to find files by name. "
            + "Pass pattern (glob with *, ?, **, [...], max 500 chars, relative to baseDir, no '..') "
            + "plus optional baseDir (defaults to home) and maxResults (1-500, default 100). "
            + "Returns sorted paths with a truncation flag; sensitive paths are pruned, denied bases fail with an approval hint."
    /// Function-calling contract for `pattern`, `baseDir`, and `maxResults`.
    public let inputSchema =
        JSONSchema(
            rawValue: #"{"type":"object","properties":{"pattern":{"type":"string","description":"Glob pattern "#
                + #"relative to baseDir (*, ?, **, [...]; max 500 chars; no '..')"},"baseDir":{"type":"string","description":"Base "#
                + #"directory to search (\"~\" expands to the home directory; omitted means home)"},"maxResults":{"type":"integer","description":"Maximum "#
                + #"paths (1-500, default 100)","minimum":1,"maximum":500}},"required":["pattern"],"additionalProperties":false}"#
        )
    /// Always allowed at the gate level; sensitive paths escalate via the failure hint instead.
    public let permissionLevel = PermissionLevel.readOnly

    /// Home boundary override for tests. Nil means the real home.
    private let homeDirectoryURL: URL?

    /// `[files]` policy enforced through the shared guard. Defaults to the built-in defaults.
    private let filesConfig: FilesConfig

    /// Creates a glob tool.
    public init(homeDirectoryURL: URL? = nil, filesConfig: FilesConfig = FilesConfig()) {
        self.homeDirectoryURL = homeDirectoryURL
        self.filesConfig = filesConfig
    }

    /// Lists paths matching the glob, enforcing the guard first.
    public func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
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
        let candidates = prunedRelativePaths(under: baseURL)
        var matched: [String] = []
        for (relative, canonical) in candidates {
            try Task.checkCancellation()
            if FilesGlobMatching.matches(pattern: rawPattern, relativePath: relative) {
                matched.append(canonical)
            }
        }
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

    /// Lists pruned descendants as root-relative and canonical pairs.
    private func prunedRelativePaths(under root: URL) -> [(relative: String, canonical: String)] {
        var pairs: [(relative: String, canonical: String)] = []
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return []
        }
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        for element in enumerator {
            guard let url = element as? URL else {
                continue
            }
            let decision = FilesAccessGuard.evaluate(url: url, homeDirectoryURL: homeDirectoryURL, filesConfig: filesConfig)
            guard decision.allowed else {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard decision.resolvedPath.hasPrefix(prefix) else {
                continue
            }
            let relative = String(decision.resolvedPath.dropFirst(prefix.count))
            guard !relative.isEmpty else {
                continue
            }
            pairs.append((relative: relative, canonical: decision.resolvedPath))
        }
        return pairs
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
    public static let toolNames = ["files.read", "files.grep", "files.glob"]

    /// Builds the file tools.
    public static func makeTools(homeDirectoryURL: URL? = nil, filesConfig: FilesConfig = FilesConfig()) -> [any Tool] {
        let read: any Tool = FilesReadTool(homeDirectoryURL: homeDirectoryURL, filesConfig: filesConfig)
        let grep: any Tool = FilesGrepTool(homeDirectoryURL: homeDirectoryURL, filesConfig: filesConfig)
        let glob: any Tool = FilesGlobTool(homeDirectoryURL: homeDirectoryURL, filesConfig: filesConfig)
        return [read, grep, glob]
    }

    /// Registers the file tools, replacing same-named entries.
    public static func register(on bus: ToolBus, homeDirectoryURL: URL? = nil, filesConfig: FilesConfig = FilesConfig()) async {
        for tool in makeTools(homeDirectoryURL: homeDirectoryURL, filesConfig: filesConfig) {
            await bus.register(tool: tool)
        }
    }
}

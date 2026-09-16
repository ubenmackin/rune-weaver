// Rune Weaver Tools — Local file tools (`files.read`, `files.grep`, `files.glob`) plus Seatbelt staging.
//
// Exposes bounded local file reads and search to the model over the shared
// `FilesAccessGuard` deny policy, driven by the `[files]` config section
// (`FilesConfig` deny patterns, allow roots, and deny escalation). Reads are line-windowed (offset/limit)
// with a byte cap and a binary sniff so oversized or non-text files fail
// with a note instead of flooding context or leaking credential bytes.
// Grep walks with deny pruning and skips binaries and oversized files;
// glob lists pruned, sorted paths. Denied paths fail with an
// approval-escalation hint and never return file content.
//
// Confinement is Tier-1/Tier-2 Seatbelt plus Tier-3 microVM only with no host
// sandbox folder: remaining document writes stage in a Seatbelt-confined temp
// dir (`SeatbeltTempStaging`) and reach the workspace via one guard-validated
// atomic move on approval. Temp is never executed from and is removed on deny
// or failure.

import Foundation
import RuneWeaverCore

/// Arguments for the `files.read` tool.
///
/// `path` is required; `offset` is the 1-indexed first line to return
/// (defaulting to 1 and clamped to at least 1 so `0` or negative values
/// read from the top instead of failing); `limit` caps returned lines
/// (defaulting to 2000 and clamped to `1...5000` so the model cannot fan
/// out an unbounded read); `encoding` names the text encoding and only
/// accepts UTF-8 variants in v1 so undecodable bytes fail cleanly rather
/// than arriving as mojibake.
public struct FilesReadArgs: Sendable, Equatable, Decodable {
    /// Raw file path (may contain `~`, `.`, `..`, or symlinks; resolved by the guard).
    public let path: String
    /// 1-indexed first line to return, clamped to at least 1.
    public let offset: Int
    /// Maximum lines to return, clamped to `1...5000`.
    public let limit: Int
    /// Optional text encoding name (UTF-8 only in v1).
    public let encoding: String?

    /// Default line count when the caller omits `limit`.
    public static let defaultLimit = 2000
    /// Upper bound for `limit` so reads stay bounded.
    public static let maxLimit = 5000
    /// Default first line when the caller omits `offset`.
    public static let defaultOffset = 1

    /// Memberwise initializer with offset/limit clamping.
    /// - Parameters:
    ///   - path: Raw file path.
    ///   - offset: 1-indexed first line. Clamped to at least 1.
    ///   - limit: Maximum lines. Clamped to `1...5000`.
    ///   - encoding: Optional encoding name.
    public init(path: String, offset: Int = defaultOffset, limit: Int = defaultLimit, encoding: String? = nil) {
        self.path = path
        self.offset = max(offset, Self.defaultOffset)
        self.limit = min(max(limit, 1), Self.maxLimit)
        self.encoding = encoding
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case offset
        case limit
        case encoding
    }

    /// Decodes arguments, clamping `offset` and `limit`.
    /// - Parameter decoder: Decoder for the arguments document.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let path = try container.decode(String.self, forKey: .path)
        let rawOffset = try container.decodeIfPresent(Int.self, forKey: .offset) ?? Self.defaultOffset
        let rawLimit = try container.decodeIfPresent(Int.self, forKey: .limit) ?? Self.defaultLimit
        let encoding = try container.decodeIfPresent(String.self, forKey: .encoding)
        self.init(path: path, offset: rawOffset, limit: rawLimit, encoding: encoding)
    }

    /// Trimmed file path.
    public var trimmedPath: String {
        path.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Trimmed encoding name, nil when omitted or blank.
    public var trimmedEncoding: String? {
        guard let encoding else { return nil }
        let trimmed = encoding.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Envelope wrapping `files.read` success output.
///
/// Encoded as the `ToolOutput.content` JSON document so the model receives
/// the canonical path, the on-disk size, whether the view was cut short,
/// and the selected text together. `truncated` covers both the line window
/// (`offset`/`limit` left lines unread) and the byte cap (the file holds
/// bytes past the 1 MB read ceiling).
public struct FilesReadEnvelope: Sendable, Equatable, Codable {
    /// Canonical path that was read.
    public let path: String
    /// On-disk file size in bytes.
    public let sizeBytes: Int
    /// Whether lines or bytes beyond the returned view were left unread.
    public let truncated: Bool
    /// Selected text lines joined with `\n`.
    public let content: String

    /// Creates a read envelope.
    /// - Parameters:
    ///   - path: Canonical path that was read.
    ///   - sizeBytes: On-disk file size in bytes.
    ///   - truncated: Whether the view was cut short.
    ///   - content: Selected text.
    public init(path: String, sizeBytes: Int, truncated: Bool, content: String) {
        self.path = path
        self.sizeBytes = sizeBytes
        self.truncated = truncated
        self.content = content
    }
}

/// Envelope wrapping `files.read` deny output.
///
/// Denied reads fail (never succeed) with this JSON document as the
/// `ToolOutput.content` so the orchestrator can surface an approval path.
/// It carries no file bytes: only the canonical path, the policy reason,
/// and the escalation flag the model needs to ask for approval.
public struct FilesDeniedEnvelope: Sendable, Equatable, Codable {
    /// Human-readable denial message.
    public let error: String
    /// Canonical path that was denied.
    public let path: String
    /// Escalation hint; mirrors the guard decision (false only when
    /// `[files].require_approval_on_deny` is false and the denial is hard).
    public let approvalRequired: Bool
    /// Policy reason (never file content).
    public let reason: String

    /// Creates a denied envelope.
    /// - Parameters:
    ///   - error: Human-readable denial message.
    ///   - path: Canonical path that was denied.
    ///   - approvalRequired: Escalation hint. Defaults to true.
    ///   - reason: Policy reason.
    public init(error: String, path: String, approvalRequired: Bool = true, reason: String) {
        self.error = error
        self.path = path
        self.approvalRequired = approvalRequired
        self.reason = reason
    }
}

/// Pure JSON encoding for the file tool output documents.
///
/// Envelopes encode with sorted keys so fixture tests can assert on stable
/// output without touching the filesystem beyond canned reads.
public enum FilesToolEncoding {
    /// Encodes a read envelope as the tool output document.
    /// - Parameter envelope: Envelope to encode.
    /// - Returns: JSON document for `ToolOutput.content`.
    /// - Throws: Encoding errors.
    public static func encodeReadEnvelope(_ envelope: FilesReadEnvelope) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(envelope)
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    /// Encodes a denied envelope as the tool failure document.
    /// - Parameter envelope: Envelope to encode.
    /// - Returns: JSON document for `ToolOutput.content`.
    /// - Throws: Encoding errors.
    public static func encodeDeniedEnvelope(_ envelope: FilesDeniedEnvelope) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(envelope)
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    /// Encodes a grep envelope as the tool output document.
    ///
    /// Sorted keys keep the match list stable for fixture assertions
    /// without touching the filesystem beyond canned searches.
    /// - Parameter envelope: Envelope to encode.
    /// - Returns: JSON document for `ToolOutput.content`.
    /// - Throws: Encoding errors.
    public static func encodeGrepEnvelope(_ envelope: FilesGrepEnvelope) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(envelope)
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    /// Encodes a glob envelope as the tool output document.
    ///
    /// Sorted keys keep the path list stable for fixture assertions.
    /// - Parameter envelope: Envelope to encode.
    /// - Returns: JSON document for `ToolOutput.content`.
    /// - Throws: Encoding errors.
    public static func encodeGlobEnvelope(_ envelope: FilesGlobEnvelope) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(envelope)
        return String(bytes: data, encoding: .utf8) ?? ""
    }
}

/// Read-only `files.read` tool for bounded local file reads.
///
/// Guards every path through `FilesAccessGuard` before touching disk:
/// sensitive or outside-home paths fail with an `approvalRequired` hint
/// and never return bytes. Allowed paths read at most the 1 MB ceiling,
/// refuse NUL-containing (binary) files with a note, decode as UTF-8, and
/// return the requested line window with a truncation flag. Read-only in
/// effect: it never mutates the filesystem and ignores `dryRun`, matching
/// the email read tools.
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
    /// - Parameters:
    ///   - homeDirectoryURL: Home boundary override forwarded to the guard. Defaults to nil (real home).
    ///   - filesConfig: `[files]` deny/allow policy forwarded to the guard. Defaults to the built-in defaults.
    public init(homeDirectoryURL: URL? = nil, filesConfig: FilesConfig = FilesConfig()) {
        self.homeDirectoryURL = homeDirectoryURL
        self.filesConfig = filesConfig
    }

    /// Reads the requested line window, enforcing the guard first.
    /// - Parameters:
    ///   - input: Invocation with `path` and optional `offset`, `limit`, `encoding`.
    ///   - context: Ambient execution context (dry run is ignored; reads never mutate).
    /// - Returns: JSON read envelope, or a failure without file bytes.
    public func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        let args: FilesReadArgs
        do {
            args = try JSONDecoder().decode(FilesReadArgs.self, from: Data(input.argumentsJSON.utf8))
        } catch {
            return .failure(
                "Invalid files.read arguments: expected {\"path\": \"<file>\", \"offset\": <1-based>, \"limit\": <1-5000>}.",
                callID: input.callID
            )
        }
        let rawPath = args.trimmedPath
        guard !rawPath.isEmpty else {
            return .failure("Invalid files.read arguments: 'path' must not be empty.", callID: input.callID)
        }
        if let encoding = args.trimmedEncoding, !isSupportedEncoding(encoding) {
            return .failure(
                "Unsupported encoding '\(encoding)': only UTF-8 is supported (omit 'encoding' for UTF-8).",
                callID: input.callID
            )
        }
        // Guard before disk: denied paths never reach FileManager, so no
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
        let fileURL = URL(fileURLWithPath: decision.resolvedPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else {
            return .failure("File not found: \(decision.resolvedPath)", callID: input.callID)
        }
        guard !isDirectory.boolValue else {
            return .failure("Not a file: \(decision.resolvedPath)", callID: input.callID)
        }
        let sizeBytes: Int
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            if let number = attributes[.size] as? NSNumber {
                sizeBytes = number.intValue
            } else if let intValue = attributes[.size] as? Int {
                sizeBytes = intValue
            } else {
                sizeBytes = 0
            }
        } catch {
            return .failure("Could not stat file: \(error.localizedDescription)", callID: input.callID)
        }
        let bytes: Data
        let byteTruncated: Bool
        do {
            let read = try readUpToCap(at: fileURL)
            bytes = read.prefix
            byteTruncated = read.truncated
        } catch {
            return .failure("Could not read file: \(error.localizedDescription)", callID: input.callID)
        }
        // NUL-byte sniff refuses binaries before decoding so binary bytes
        // never enter the envelope; the note names the refusal without
        // echoing any file content.
        if bytes.contains(0x00) {
            return .failure(
                "Binary file detected (NUL byte found); refusing to read \(decision.resolvedPath) as text.",
                callID: input.callID
            )
        }
        guard let text = String(data: bytes, encoding: .utf8) else {
            return .failure(
                "File is not valid UTF-8: \(decision.resolvedPath). Only UTF-8 text files are supported.",
                callID: input.callID
            )
        }
        let lines = splitLines(text)
        let start = max(args.offset - 1, 0)
        let selected: [String]
        let windowTruncated: Bool
        if start >= lines.count {
            // Offset past end-of-file yields an empty view; the byte cap
            // still governs `truncated` because unread bytes may exist past
            // the ceiling even when the window itself is empty.
            selected = []
            windowTruncated = false
        } else {
            let end = min(start + args.limit, lines.count)
            selected = Array(lines[start ..< end])
            windowTruncated = end < lines.count
        }
        let envelope = FilesReadEnvelope(
            path: decision.resolvedPath,
            sizeBytes: sizeBytes,
            truncated: byteTruncated || windowTruncated,
            content: selected.joined(separator: "\n")
        )
        do {
            let content = try FilesToolEncoding.encodeReadEnvelope(envelope)
            return .success(content, callID: input.callID)
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
    }

    /// Reports whether an encoding name selects the supported UTF-8 path.
    ///
    /// Accepts the spellings the model is likely to emit (`utf8`,
    /// `utf-8`, `utf_8`, case-insensitive, surrounding whitespace ignored)
    /// and rejects everything else so callers get a clear failure instead
    /// of silently mis-decoded text.
    /// - Parameter encoding: Raw encoding name.
    /// - Returns: True for UTF-8 spellings.
    private func isSupportedEncoding(_ encoding: String) -> Bool {
        let normalised = encoding.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalised == "utf8" || normalised == "utf-8" || normalised == "utf_8"
    }

    /// Builds the approval-escalation failure without file bytes.
    /// - Parameters:
    ///   - resolvedPath: Canonical path that was denied.
    ///   - reason: Policy reason, if any.
    ///   - requiresApproval: Escalation hint from the guard decision (false for hard denials).
    ///   - callID: Correlation identifier.
    /// - Returns: Failure whose content is the denied envelope JSON.
    private func deniedOutput(resolvedPath: String, reason: String?, requiresApproval: Bool, callID: String) -> ToolOutput {
        let detail = reason ?? "Reading this path requires explicit approval."
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

    /// Reads at most the 1 MB ceiling, reporting whether bytes were left unread.
    ///
    /// Small files take the single-shot path; files whose stat size exceeds
    /// the ceiling read only the leading window through a handle so a
    /// multi-gigabyte file cannot blow memory. The `+1` probe is unnecessary
    /// because the stat size already tells whether the ceiling cut bytes,
    /// and the handle path caps the in-memory prefix exactly.
    /// - Parameter url: Canonical file URL.
    /// - Returns: Leading bytes plus whether the file holds more past the ceiling.
    /// - Throws: Filesystem read errors.
    private func readUpToCap(at url: URL) throws -> (prefix: Data, truncated: Bool) {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size: Int = if let number = attributes[.size] as? NSNumber {
            number.intValue
        } else if let intValue = attributes[.size] as? Int {
            intValue
        } else {
            0
        }
        if size <= Self.maxFileBytes {
            let data = try Data(contentsOf: url)
            // A racing writer could still have grown the file past the
            // ceiling between stat and read; honour the actual bytes read.
            if data.count > Self.maxFileBytes {
                return (data.prefix(Self.maxFileBytes), true)
            }
            return (data, false)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var prefix = Data()
        var remaining = Self.maxFileBytes
        while remaining > 0 {
            let chunkSize = min(64 * 1024, remaining)
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                break
            }
            prefix.append(chunk)
            remaining -= chunk.count
        }
        return (prefix, true)
    }

    /// Splits decoded text into lines for windowed reads.
    ///
    /// Normalises Windows (`\r\n`) and legacy Mac (`\r`) endings to `\n`
    /// first so each visual line counts once, drops the single trailing
    /// empty slice produced by a final newline so `"a\nb\n"` counts as two
    /// lines, and maps an empty file to zero lines so `offset: 1` yields an
    /// empty (not single-blank-line) view.
    /// - Parameter text: Decoded file text.
    /// - Returns: Lines without terminators.
    private func splitLines(_ text: String) -> [String] {
        if text.isEmpty {
            return []
        }
        let normalised = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var parts = normalised.components(separatedBy: "\n")
        if parts.last?.isEmpty == true {
            parts.removeLast()
        }
        return parts
    }
}

/// Arguments for the `files.grep` tool.
///
/// `pattern` is a per-line regular expression kept RE2-safe so a future
/// engine swap cannot introduce backtracking surprises; `path` accepts a
/// file or a directory root; `include` optionally narrows candidates by
/// filename glob (for example `*.swift`) so broad roots stay cheap;
/// `maxResults` bounds returned matches so a noisy pattern cannot flood
/// context.
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
    /// - Parameters:
    ///   - pattern: Regular expression source.
    ///   - path: File or directory root.
    ///   - include: Optional filename glob.
    ///   - maxResults: Maximum matches. Clamped to `1...200`.
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
///
/// `preview` carries only the matching line (capped at 200 characters) so
/// a long line cannot flood context and no neighbouring lines leak.
public struct FilesGrepMatch: Sendable, Equatable, Codable {
    /// Canonical file path holding the match.
    public let path: String
    /// 1-indexed line number within the file.
    public let line: Int
    /// Matching line text, capped at 200 characters.
    public let preview: String

    /// Creates a grep hit.
    /// - Parameters:
    ///   - path: Canonical file path.
    ///   - line: 1-indexed line number.
    ///   - preview: Bounded line preview.
    public init(path: String, line: Int, preview: String) {
        self.path = path
        self.line = line
        self.preview = preview
    }
}

/// Envelope wrapping `files.grep` success output.
///
/// `truncated` is true only when at least one further match existed past
/// `maxResults`, so the model can narrow the pattern or raise the cap
/// instead of assuming completeness.
public struct FilesGrepEnvelope: Sendable, Equatable, Codable {
    /// Matches in sorted-path, ascending-line order.
    public let matches: [FilesGrepMatch]
    /// Whether matches past the cap were left unreported.
    public let truncated: Bool

    /// Creates a grep envelope.
    /// - Parameters:
    ///   - matches: Returned matches.
    ///   - truncated: Whether further matches existed.
    public init(matches: [FilesGrepMatch], truncated: Bool) {
        self.matches = matches
        self.truncated = truncated
    }
}

/// Arguments for the `files.glob` tool.
///
/// `pattern` is a glob relative to `baseDir` (`*`, `?`, `**`, `[...]`);
/// `baseDir` defaults to the home boundary so omitted roots cannot drift
/// to the process working directory; `maxResults` bounds returned paths.
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
    /// - Parameters:
    ///   - pattern: Glob pattern.
    ///   - baseDir: Base directory root, if any.
    ///   - maxResults: Maximum paths. Clamped to `1...500`.
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
///
/// Paths are canonical absolute paths sorted lexicographically so repeated
/// calls are deterministic; `truncated` signals that further paths existed
/// past the cap.
public struct FilesGlobEnvelope: Sendable, Equatable, Codable {
    /// Sorted canonical paths matching the glob.
    public let paths: [String]
    /// Whether paths past the cap were left unreported.
    public let truncated: Bool

    /// Creates a glob envelope.
    /// - Parameters:
    ///   - paths: Returned paths.
    ///   - truncated: Whether further paths existed.
    public init(paths: [String], truncated: Bool) {
        self.paths = paths
        self.truncated = truncated
    }
}

/// Shared glob matching for `files.grep` include filters and `files.glob`.
///
/// Both tools agree on one dialect — `*` spans within a segment, `?`
/// spans one non-separator character, `**` spans separators, `[...]`
/// spans a character class — so an `include` filter behaves exactly like
/// the equivalent glob pattern. Dot-dot detection lives here too so both
/// tools reject directory escapes through the same check.
public enum FilesGlobMatching: Sendable {
    /// Reports whether a glob tries to climb with a `..` segment.
    ///
    /// Splitting on `/` (ignoring empty slices from doubled separators)
    /// keeps `...` or `a..b` legal while `..`, `a/../b`, and `../x` fail,
    /// so legitimate dotted filenames never false-positive.
    /// - Parameter pattern: Raw glob pattern.
    /// - Returns: True when any `/`-separated segment equals `..`.
    public static func containsDotDot(_ pattern: String) -> Bool {
        pattern.split(separator: "/", omittingEmptySubsequences: true).contains { $0 == ".." }
    }

    /// Reports whether a relative path matches a glob.
    ///
    /// The glob compiles to an anchored regular expression on every call;
    /// patterns here are short (capped at 500 characters upstream) and
    /// calls are per-file, so caching would add shared state for no
    /// measurable win. A pattern that cannot compile defensively matches
    /// nothing rather than failing the whole search.
    /// - Parameters:
    ///   - pattern: Glob pattern.
    ///   - relativePath: `/`-separated path relative to the search root.
    /// - Returns: True on match.
    public static func matches(pattern: String, relativePath: String) -> Bool {
        let source = regexSource(fromGlob: pattern)
        guard let expression = try? NSRegularExpression(pattern: source) else {
            return false
        }
        let range = NSRange(relativePath.startIndex ..< relativePath.endIndex, in: relativePath)
        return expression.firstMatch(in: relativePath, range: range) != nil
    }

    /// Converts a glob to an anchored regular-expression source.
    ///
    /// `**/` becomes an optional directory prefix (`(.*/)?`) so `**/*.txt`
    /// matches top-level files as well as nested ones; lone `**` becomes
    /// `.*`; `*` stays within a segment (`[^/]*`) so `*.txt` never spans
    /// directories; `[!...]` negations translate to `[^...]` for the regex
    /// engine while unterminated `[` stays literal instead of failing.
    /// - Parameter pattern: Glob pattern.
    /// - Returns: Anchored regex source.
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
///
/// Every candidate — the starting root and each walked descendant — is
/// judged by `FilesAccessGuard` before any byte is read: a denied root
/// fails with an `approvalRequired` hint, while denied descendants are
/// pruned silently so one secret file cannot veto a whole-tree search.
/// Files over the 2 MB ceiling and NUL-containing (binary) or undecodable
/// files are skipped with no match rather than failing the call, keeping
/// noisy trees searchable. Read-only in effect: it never mutates the
/// filesystem and ignores `dryRun`, matching the email read tools.
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
    /// - Parameters:
    ///   - homeDirectoryURL: Home boundary override forwarded to the guard. Defaults to nil (real home).
    ///   - filesConfig: `[files]` deny/allow policy forwarded to the guard. Defaults to the built-in defaults.
    public init(homeDirectoryURL: URL? = nil, filesConfig: FilesConfig = FilesConfig()) {
        self.homeDirectoryURL = homeDirectoryURL
        self.filesConfig = filesConfig
    }

    /// Searches the requested root, enforcing the guard first.
    /// - Parameters:
    ///   - input: Invocation with `pattern`, `path`, optional `include` and `maxResults`.
    ///   - context: Ambient execution context (dry run is ignored; searches never mutate).
    /// - Returns: JSON grep envelope, or a failure without file bytes.
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

    /// Explains why a pattern cannot run on the RE2-safe subset, if any.
    ///
    /// RE2 omits lookaround, backreferences, atomic groups, and possessive
    /// quantifiers; rejecting them here (instead of at a future engine
    /// swap) keeps patterns portable and sidesteps the catastrophic
    /// backtracking those constructs enable. The scan skips escapes and
    /// character classes so a literal `(?=` inside `[...]` or after `\`
    /// never false-positives.
    /// - Parameter pattern: Raw regex source.
    /// - Returns: Human-readable reason, or nil when the pattern is in-subset.
    private static func re2UnsupportedReason(for pattern: String) -> String? {
        let chars = Array(pattern)
        var index = chars.startIndex
        var inClass = false
        while index < chars.endIndex {
            let char = chars[index]
            if char == "\\" {
                // Escaped pair: `\1`-`\9` outside a class is a backreference
                // (RE2 has no backreferences); `\k` starts a named
                // backreference. Anything else is a harmless escape.
                let next = chars.index(after: index)
                if next < chars.endIndex, !inClass {
                    let escaped = chars[next]
                    if ("1" ... "9").contains(escaped) {
                        return "backreferences (e.g. \\1) are not supported; match without referring to earlier groups."
                    }
                    if escaped == "k" {
                        return "named backreferences (\\k) are not supported; match without referring to earlier groups."
                    }
                }
                index = next < chars.endIndex ? chars.index(after: next) : chars.endIndex
                continue
            }
            if char == "[" {
                inClass = true
                index = chars.index(after: index)
                continue
            }
            if char == "]" {
                inClass = false
                index = chars.index(after: index)
                continue
            }
            if inClass {
                index = chars.index(after: index)
                continue
            }
            if char == "(" {
                // Peek the group opener for lookaround/atomic heads.
                let rest = String(chars[chars.index(after: index)...].prefix(4))
                if rest.hasPrefix("?=") || rest.hasPrefix("?!") {
                    return "lookahead (e.g. (?=...)) is not supported; match the text directly."
                }
                if rest.hasPrefix("?<=") || rest.hasPrefix("?<!") {
                    return "lookbehind (e.g. (?<=...)) is not supported; match the text directly."
                }
                if rest.hasPrefix("?>") {
                    return "atomic groups ((?>...)) are not supported; use a plain group instead."
                }
            }
            if char == "*" || char == "+" || char == "?" || char == "}" {
                // A `+` immediately after a quantifier is possessive
                // (`*+`, `++`, `?+`, `{2,3}+`); lazy `*?` stays legal.
                let next = chars.index(after: index)
                if next < chars.endIndex, chars[next] == "+" {
                    return "possessive quantifiers (e.g. *+) are not supported; use a greedy or lazy quantifier instead."
                }
            }
            index = chars.index(after: index)
        }
        return nil
    }

    /// Reports whether a file passes the optional include filter.
    ///
    /// Includes stay filename-oriented (`*.swift`) but also honour
    /// slash-bearing globs (`src/*.swift`) by testing the root-relative
    /// path as a fallback, so one flag covers both shallow and deep
    /// filters without a second parameter.
    /// - Parameters:
    ///   - include: Raw include glob.
    ///   - fileURL: Canonical candidate file.
    ///   - root: Canonical search root (file or directory).
    /// - Returns: True when the file should be searched.
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
    ///
    /// Denied directories prune their whole subtree via
    /// `skipDescendants()` and denied files are skipped individually, so a
    /// single secret path cannot veto the search. Every decision reuses
    /// `FilesAccessGuard` — no path pattern is reimplemented here.
    /// - Parameter root: Canonical directory root.
    /// - Returns: Canonical allowed file URLs (directories excluded).
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
    ///
    /// Files over the 2 MB ceiling, NUL-containing binaries, and
    /// non-UTF-8 bytes are skipped (nil) rather than failing the search,
    /// so one binary in a source tree cannot sink the whole call. Line
    /// endings normalise like `files.read` so previews count lines once.
    /// - Parameter url: Canonical file URL.
    /// - Returns: Lines without terminators, or nil to skip the file.
    private func searchableLines(at url: URL) -> [String]? {
        let size: Int
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let number = attributes[.size] as? NSNumber {
                size = number.intValue
            } else if let intValue = attributes[.size] as? Int {
                size = intValue
            } else {
                return nil
            }
        } catch {
            return nil
        }
        guard size <= Self.maxFileBytes else {
            return nil
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return nil
        }
        guard !data.contains(0x00) else {
            return nil
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        if text.isEmpty {
            return []
        }
        let normalised = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var parts = normalised.components(separatedBy: "\n")
        if parts.last?.isEmpty == true {
            parts.removeLast()
        }
        return parts
    }

    /// Builds the approval-escalation failure without file bytes.
    /// - Parameters:
    ///   - resolvedPath: Canonical path that was denied.
    ///   - reason: Policy reason, if any.
    ///   - requiresApproval: Escalation hint from the guard decision (false for hard denials).
    ///   - callID: Correlation identifier.
    /// - Returns: Failure whose content is the denied envelope JSON.
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
    ///
    /// Grapheme-cluster prefixing keeps the 200-character promise in user
    /// terms (not UTF-8 bytes or UTF-16 code units) so emoji-heavy lines
    /// truncate without splitting a visible character.
    /// - Parameter line: Full matching line without terminator.
    /// - Returns: At most 200 characters of the line.
    private static func preview(_ line: String) -> String {
        guard line.count > maxPreviewChars else {
            return line
        }
        return String(line.prefix(maxPreviewChars))
    }
}

/// Read-only `files.glob` tool for listing paths by glob.
///
/// The base directory and every walked descendant are judged by
/// `FilesAccessGuard` before any path is reported: a denied base fails
/// with an `approvalRequired` hint, while denied descendants are pruned
/// silently so one secret file cannot veto a listing. Patterns are
/// relative to the base and must not contain `..`, closing the classic
/// escape where `../../secret` climbs past the boundary. Read-only in
/// effect: it never mutates the filesystem and ignores `dryRun`.
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
    /// - Parameters:
    ///   - homeDirectoryURL: Home boundary override forwarded to the guard. Defaults to nil (real home).
    ///   - filesConfig: `[files]` deny/allow policy forwarded to the guard. Defaults to the built-in defaults.
    public init(homeDirectoryURL: URL? = nil, filesConfig: FilesConfig = FilesConfig()) {
        self.homeDirectoryURL = homeDirectoryURL
        self.filesConfig = filesConfig
    }

    /// Lists paths matching the glob, enforcing the guard first.
    /// - Parameters:
    ///   - input: Invocation with `pattern` and optional `baseDir` and `maxResults`.
    ///   - context: Ambient execution context (dry run is ignored; listings never mutate).
    /// - Returns: JSON glob envelope, or a failure without file bytes.
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
    ///
    /// Denied subtrees prune via `skipDescendants()` and denied files drop
    /// individually; every decision reuses `FilesAccessGuard` so no policy
    /// pattern lives here. Both files and directories report (the base
    /// itself does not) so patterns like `src` can match a directory.
    /// - Parameter root: Canonical base directory.
    /// - Returns: Pairs of root-relative match keys and canonical absolute paths.
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
    /// - Parameters:
    ///   - resolvedPath: Canonical path that was denied.
    ///   - reason: Policy reason, if any.
    ///   - requiresApproval: Escalation hint from the guard decision (false for hard denials).
    ///   - callID: Correlation identifier.
    /// - Returns: Failure whose content is the denied envelope JSON.
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
///
/// Stages bytes in an owner-only temp dir that the Seatbelt profile keeps
/// writable and readable but never executable, then moves them into the
/// workspace with one guard-validated atomic step on approval. There is no
/// host sandbox folder: temp is the only staging area, nothing is ever
/// executed from it, and it is removed on deny or failure with no migration
/// for old directories.
///
/// Approval discipline: validate the destination through `FilesAccessGuard`
/// at approval time (not just at stage time) so a policy change between
/// staging and approval still fails closed, and always discard temp on any
/// deny or filesystem failure so staged bytes never accumulate.
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
    ///
    /// Single-sourced through the core confined-temp helper so creation stays
    /// in one place; mode `0700` plus the Seatbelt never-execute deny hold for
    /// every caller. Callers own cleanup via `discardTemp(at:)` on deny or failure.
    /// - Parameter prefix: Leading name component. Defaults to `tempPrefix`.
    /// - Returns: Newly created temp directory URL.
    /// - Throws: Filesystem errors when creation fails.
    public static func makeTempDirectory(prefix: String = tempPrefix) throws -> URL {
        try SeatbeltProfileBuilder.makeConfinedTempDirectory(prefix: prefix)
    }

    /// Stages bytes as one temp file inside a confined temp directory.
    ///
    /// The filename is sanitized to its base name so a crafted attachment
    /// name cannot escape the temp dir via separators, and the write is
    /// atomic so a crash never leaves a half-written stage visible.
    /// - Parameters:
    ///   - bytes: Document bytes to stage.
    ///   - filename: Original filename, reduced to a safe base name.
    ///   - directory: Confined temp directory from `makeTempDirectory`.
    /// - Returns: Staged temp file URL, never executed from.
    /// - Throws: Filesystem errors when the write fails.
    public static func stageBytes(_ bytes: Data, filename: String, in directory: URL) throws -> URL {
        let base = (filename as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = base.isEmpty ? "document" : base.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\0", with: "_")
        let name = "\(UUID().uuidString)-\(cleaned)"
        let url = directory.appendingPathComponent(name, isDirectory: false)
        try bytes.write(to: url, options: .atomic)
        return url
    }

    /// Atomically moves a staged temp file into the workspace on approval.
    ///
    /// Re-validates the destination through `FilesAccessGuard` at move time so
    /// the approval decision is judged against live policy rather than a
    /// stale stage-time check, then ensures parents and moves. A same-volume
    /// rename is atomic; across volumes the move copies and unlinks, so
    /// callers must treat the destination as valid only after this returns.
    /// Temp is removed on success (consumed by the move) and best-effort
    /// removed on any failure so denies and errors never leak staged bytes.
    /// - Parameters:
    ///   - tempURL: Staged temp file URL.
    ///   - destinationPath: Raw workspace destination (may contain `~`).
    ///   - homeDirectoryURL: Home boundary override for tests. Defaults to nil (real home).
    ///   - filesConfig: `[files]` deny/allow policy. Defaults to the built-in defaults.
    /// - Returns: Canonical destination path that was written.
    /// - Throws: Guard denials or filesystem failures; temp is discarded on throw.
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
    ///
    /// Called on deny or failure so staged bytes never outlive their decision;
    /// failures are swallowed because cleanup must never mask the deny itself.
    /// - Parameter url: Temp file or directory to remove.
    public static func discardTemp(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Factory registering the LLM-invokable file tools on a `ToolBus`.
///
/// `files.read` stays `readOnly` while surfacing guard denials as
/// approval-hint failures; the shared guard keeps future write/search
/// tools on the same policy without duplicating patterns.
public enum FilesTools {
    /// Tool names in registration order.
    public static let toolNames = ["files.read", "files.grep", "files.glob"]

    /// Builds the file tools.
    /// - Parameters:
    ///   - homeDirectoryURL: Home boundary override forwarded to the tools. Defaults to nil (real home).
    ///   - filesConfig: `[files]` deny/allow policy forwarded to the tools. Defaults to the built-in defaults.
    /// - Returns: Read, grep, and glob tools in registration order.
    public static func makeTools(homeDirectoryURL: URL? = nil, filesConfig: FilesConfig = FilesConfig()) -> [any Tool] {
        let read: any Tool = FilesReadTool(homeDirectoryURL: homeDirectoryURL, filesConfig: filesConfig)
        let grep: any Tool = FilesGrepTool(homeDirectoryURL: homeDirectoryURL, filesConfig: filesConfig)
        let glob: any Tool = FilesGlobTool(homeDirectoryURL: homeDirectoryURL, filesConfig: filesConfig)
        return [read, grep, glob]
    }

    /// Registers the file tools, replacing same-named entries.
    /// - Parameters:
    ///   - bus: Bus receiving the tools (surfaced via `status` and sent to the model as tool definitions every chat turn).
    ///   - homeDirectoryURL: Home boundary override forwarded to the tools. Defaults to nil (real home).
    ///   - filesConfig: `[files]` deny/allow policy forwarded to the tools. Defaults to the built-in defaults.
    public static func register(on bus: ToolBus, homeDirectoryURL: URL? = nil, filesConfig: FilesConfig = FilesConfig()) async {
        for tool in makeTools(homeDirectoryURL: homeDirectoryURL, filesConfig: filesConfig) {
            await bus.register(tool: tool)
        }
    }
}

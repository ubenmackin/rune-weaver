// Rune Weaver Tools — Pinned file-read pipeline for `files.read`.
//
// Holds the read argument and envelope documents plus the O_NOFOLLOW pinned-read
// helpers (argument decoding, descriptor-pinned capped reads, line windowing).
// Reads pin the inode through a no-follow descriptor and re-validate the live
// path so a symlink swapped between the policy check and the read cannot
// redirect bytes, with the 1 MB and UTF-8 gates keeping envelopes bounded and
// text-only. Separated from the `files.read`/`grep`/`glob` tool definitions so
// the tool file stays within the file-length budget while the read path keeps
// one shared policy-checked implementation.

import Foundation
import RuneWeaverCore

/// Arguments for the `files.read` tool.
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
    public init(path: String, sizeBytes: Int, truncated: Bool, content: String) {
        self.path = path
        self.sizeBytes = sizeBytes
        self.truncated = truncated
        self.content = content
    }
}

/// Envelope wrapping `files.read` deny output.
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
    public init(error: String, path: String, approvalRequired: Bool = true, reason: String) {
        self.error = error
        self.path = path
        self.approvalRequired = approvalRequired
        self.reason = reason
    }
}

/// Pure JSON encoding for the file tool output documents.
public enum FilesToolEncoding {
    /// Encodes a read envelope as the tool output document.
    public static func encodeReadEnvelope(_ envelope: FilesReadEnvelope) throws -> String {
        try encode(envelope)
    }

    /// Encodes a denied envelope as the tool failure document.
    public static func encodeDeniedEnvelope(_ envelope: FilesDeniedEnvelope) throws -> String {
        try encode(envelope)
    }

    /// Encodes a grep envelope as the tool output document.
    public static func encodeGrepEnvelope(_ envelope: FilesGrepEnvelope) throws -> String {
        try encode(envelope)
    }

    /// Encodes a glob envelope as the tool output document.
    public static func encodeGlobEnvelope(_ envelope: FilesGlobEnvelope) throws -> String {
        try encode(envelope)
    }

    /// Single shared encoder keeping every file tool document on the same key
    /// order and formatting so read, deny, grep, and glob outputs cannot drift.
    /// Invariant: sorted keys plus pretty printing is the only supported shape;
    /// per-envelope wrappers delegate here instead of configuring their own encoder.
    private static func encode(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(value)
        return String(bytes: data, encoding: .utf8) ?? ""
    }
}

/// Shared pinned-read pipeline behind `files.read`, keeping the tool thin.
enum FilesReadHelpers: Sendable {
    /// Pinned read result carrying the validated path, size, text, and cap flag.
    struct PinnedFileRead: Sendable {
        /// Canonical path re-validated against the live descriptor.
        let validatedPath: String
        /// On-disk size observed while the descriptor pinned the inode.
        let sizeBytes: Int
        /// Decoded UTF-8 text within the byte ceiling.
        let text: String
        /// Whether bytes beyond the ceiling were left unread.
        let byteTruncated: Bool
    }

    /// Helper failure carrying the output to return, so helpers stay non-throwing without abusing `Result` over a non-`Error` payload.
    struct HelperFailure: Error, Sendable {
        /// Failure output the caller returns directly.
        let output: ToolOutput
    }

    /// Decodes caller arguments without touching disk so malformed input fails before any policy check.
    static func decodedReadArgs(_ argumentsJSON: String, callID: String) -> Result<FilesReadArgs, HelperFailure> {
        let args: FilesReadArgs
        do {
            args = try JSONDecoder().decode(FilesReadArgs.self, from: Data(argumentsJSON.utf8))
        } catch {
            return .failure(HelperFailure(output: ToolOutput.failure(
                "Invalid files.read arguments: expected {\"path\": \"<file>\", \"offset\": <1-based>, \"limit\": <1-5000>}.",
                callID: callID
            )))
        }
        guard !args.trimmedPath.isEmpty else {
            return .failure(HelperFailure(output: ToolOutput.failure(
                "Invalid files.read arguments: 'path' must not be empty.",
                callID: callID
            )))
        }
        if let encoding = args.trimmedEncoding, !isSupportedEncoding(encoding) {
            return .failure(HelperFailure(output: ToolOutput.failure(
                "Unsupported encoding '\(encoding)': only UTF-8 is supported (omit 'encoding' for UTF-8).",
                callID: callID
            )))
        }
        return .success(args)
    }

    /// Reads capped text through the no-follow descriptor so a swapped symlink cannot redirect the read.
    static func readPinnedFile(
        rawPath: String,
        decision: FilesAccessGuard.Decision,
        homeDirectoryURL: URL?,
        filesConfig: FilesConfig,
        callID: String
    ) -> Result<PinnedFileRead, HelperFailure> {
        let pinned: (handle: FileHandle, resolvedPath: String)
        do {
            pinned = try FilesAccessGuard.openNoFollowAndValidate(
                path: rawPath,
                homeDirectoryURL: homeDirectoryURL,
                filesConfig: filesConfig
            )
        } catch let error as FilesAccessOpenError {
            switch error {
            case let .denied(reason):
                return .failure(HelperFailure(output: deniedOutput(
                    resolvedPath: decision.resolvedPath,
                    reason: reason,
                    requiresApproval: decision.requiresApproval,
                    callID: callID
                )))
            case let .symlinkRefused(reason):
                return .failure(HelperFailure(output: ToolOutput.failure(reason, callID: callID)))
            case let .openFailed(reason):
                if reason.hasPrefix("Not a file") {
                    return .failure(HelperFailure(output: ToolOutput.failure(reason, callID: callID)))
                }
                if !FileManager.default.fileExists(atPath: decision.resolvedPath) {
                    return .failure(HelperFailure(output: ToolOutput.failure("File not found: \(decision.resolvedPath)", callID: callID)))
                }
                return .failure(HelperFailure(output: ToolOutput.failure(reason, callID: callID)))
            }
        } catch {
            return .failure(HelperFailure(output: ToolOutput.failure("Could not read file: \(error.localizedDescription)", callID: callID)))
        }
        let handle = pinned.handle
        defer { try? handle.close() }
        let validatedPath = pinned.resolvedPath
        let sizeBytes: Int
        do {
            let end = try handle.seekToEnd()
            sizeBytes = end > UInt64(Int.max) ? Int.max : Int(end)
            try handle.seek(toOffset: 0)
        } catch {
            return .failure(HelperFailure(output: ToolOutput.failure("Could not stat file: \(error.localizedDescription)", callID: callID)))
        }
        let bytes: Data
        let byteTruncated: Bool
        do {
            let read = try readUpToCap(from: handle)
            bytes = read.prefix
            byteTruncated = read.truncated || sizeBytes > FilesReadTool.maxFileBytes
        } catch {
            return .failure(HelperFailure(output: ToolOutput.failure("Could not read file: \(error.localizedDescription)", callID: callID)))
        }
        // NUL-byte sniff refuses binaries before decoding so binary bytes
        // never enter the envelope; the note names the refusal without
        // echoing any file content.
        if bytes.contains(0x00) {
            return .failure(HelperFailure(output: ToolOutput.failure(
                "Binary file detected (NUL byte found); refusing to read \(validatedPath) as text.",
                callID: callID
            )))
        }
        guard let text = String(data: bytes, encoding: .utf8) else {
            return .failure(HelperFailure(output: ToolOutput.failure(
                "File is not valid UTF-8: \(validatedPath). Only UTF-8 text files are supported.",
                callID: callID
            )))
        }
        return .success(PinnedFileRead(
            validatedPath: validatedPath,
            sizeBytes: sizeBytes,
            text: text,
            byteTruncated: byteTruncated
        ))
    }

    /// Slices decoded text into the requested line window for the output envelope.
    static func windowedEnvelope(args: FilesReadArgs, pinned: PinnedFileRead) -> FilesReadEnvelope {
        // Shared split keeps windowed reads on the same CRLF/CR boundaries as
        // TOML, history, archive, and template parsing.
        let lines = NormalizedText.splitLines(pinned.text)
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
        return FilesReadEnvelope(
            path: pinned.validatedPath,
            sizeBytes: pinned.sizeBytes,
            truncated: pinned.byteTruncated || windowTruncated,
            content: selected.joined(separator: "\n")
        )
    }

    /// Reports whether an encoding name selects the supported UTF-8 path.
    static func isSupportedEncoding(_ encoding: String) -> Bool {
        let normalised = encoding.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalised == "utf8" || normalised == "utf-8" || normalised == "utf_8"
    }

    /// Builds the approval-escalation failure without file bytes.
    static func deniedOutput(resolvedPath: String, reason: String?, requiresApproval: Bool, callID: String) -> ToolOutput {
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

    /// Reads at most the 1 MB ceiling from a pinned descriptor, reporting whether bytes were left unread.
    /// The caller opens via the no-follow helper and seeks to the start first,
    /// so this read observes the validated inode rather than a swapped path;
    /// the one-byte probe learns truncation without materialising the tail.
    static func readUpToCap(from handle: FileHandle) throws -> (prefix: Data, truncated: Bool) {
        var prefix = Data()
        prefix.reserveCapacity(min(FilesReadTool.maxFileBytes, 64 * 1024))
        var remaining = FilesReadTool.maxFileBytes
        while remaining > 0 {
            let chunkSize = min(64 * 1024, remaining)
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                break
            }
            prefix.append(chunk)
            remaining -= chunk.count
            if chunk.count < chunkSize {
                break
            }
        }
        guard remaining == 0 else {
            return (prefix, false)
        }
        if let extra = try handle.read(upToCount: 1), !extra.isEmpty {
            return (prefix, true)
        }
        return (prefix, false)
    }
}

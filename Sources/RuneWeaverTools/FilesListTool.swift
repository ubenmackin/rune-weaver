// Rune Weaver Tools — Shallow directory listing tool (`files.list`).

import Foundation
import RuneWeaverCore

/// Arguments for the `files.list` tool.
public struct FilesListArgs: Sendable, Equatable, Decodable {
    /// Directory path to list. Nil or empty means home directory.
    public let path: String?
    /// Whether to include hidden files (names starting with '.').
    public let showHidden: Bool
    /// Maximum entries to return, clamped to `1...500`.
    public let limit: Int

    /// Default entry count when omitted.
    public static let defaultLimit = 100
    /// Maximum allowable limit.
    public static let maxLimit = 500

    public init(path: String? = nil, showHidden: Bool = false, limit: Int = defaultLimit) {
        self.path = path
        self.showHidden = showHidden
        self.limit = min(max(limit, 1), Self.maxLimit)
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case dir
        case directory
        case showHidden = "show_hidden"
        case showHiddenCamel = "showHidden"
        case limit
        case maxResults = "max_results"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawPath = try container.decodeIfPresent(String.self, forKey: .path)
            ?? container.decodeIfPresent(String.self, forKey: .dir)
            ?? container.decodeIfPresent(String.self, forKey: .directory)
        let hidden = try container.decodeIfPresent(Bool.self, forKey: .showHidden)
            ?? container.decodeIfPresent(Bool.self, forKey: .showHiddenCamel)
            ?? false
        let rawLimit = try container.decodeIfPresent(Int.self, forKey: .limit)
            ?? container.decodeIfPresent(Int.self, forKey: .maxResults)
            ?? Self.defaultLimit
        self.init(path: rawPath, showHidden: hidden, limit: rawLimit)
    }

    /// Trimmed path, nil when empty.
    public var trimmedPath: String? {
        guard let path else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// One directory entry in `files.list` output.
public struct FilesListEntry: Sendable, Equatable, Codable {
    /// Filename without parent directory path.
    public let name: String
    /// Absolute path to entry.
    public let path: String
    /// Type of entry: `"file"`, `"directory"`, `"symlink"`, or `"other"`.
    public let type: String
    /// File size in bytes for regular files; nil for directories or special files.
    public let sizeBytes: Int64?

    public init(name: String, path: String, type: String, sizeBytes: Int64? = nil) {
        self.name = name
        self.path = path
        self.type = type
        self.sizeBytes = sizeBytes
    }
}

/// Success payload envelope for `files.list`.
public struct FilesListEnvelope: Sendable, Equatable, Codable {
    /// Immediate directory entries.
    public let entries: [FilesListEntry]
    /// Total entries reported.
    public let count: Int
    /// Whether additional entries were left unlisted past the limit.
    public let truncated: Bool

    public init(entries: [FilesListEntry], truncated: Bool) {
        self.entries = entries
        self.count = entries.count
        self.truncated = truncated
    }
}

/// Tool that performs shallow, non-recursive directory listings.
public struct FilesListTool: Tool, Sendable {
    /// Stable tool name referenced by the LLM.
    public let name = "files.list"

    /// Tool description guiding LLM selection.
    public let description =
        "Lists immediate files and subdirectories directly inside a directory (shallow, non-recursive). "
            + "Use when inspecting folder contents or directory hierarchy without scanning deep subdirectories. "
            + "Accepts path (defaults to home or current workspace), showHidden (default false), and limit (1-500, default 100)."

    /// JSON schema for tool arguments.
    public let inputSchema =
        JSONSchema(
            rawValue: #"{"type":"object","properties":{"path":{"type":"string","#
                + #""description":"Directory path to list (\"~\" expands to home). Omitted lists home directory."},"#
                + #""showHidden":{"type":"boolean","#
                + #""description":"Whether to include hidden files (names starting with '.'). Defaults to false."},"#
                + #""limit":{"type":"integer","description":"Maximum entries (1-500, default 100).","#
                + #""minimum":1,"maximum":500}},"additionalProperties":false}"#
        )

    /// Read-only permission level.
    public let permissionLevel = PermissionLevel.readOnly

    /// Home directory boundary override for tests.
    private let homeDirectoryURL: URL?

    /// Policy configuration.
    private let filesConfig: FilesConfig

    public init(homeDirectoryURL: URL? = nil, filesConfig: FilesConfig = FilesConfig()) {
        self.homeDirectoryURL = homeDirectoryURL
        self.filesConfig = filesConfig
    }

    public func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        let args: FilesListArgs
        do {
            args = try JSONDecoder().decode(FilesListArgs.self, from: Data(input.argumentsJSON.utf8))
        } catch {
            return .failure(
                "Invalid files.list arguments: expected JSON object.",
                callID: input.callID
            )
        }

        let targetRaw: String = if let trimmed = args.trimmedPath {
            trimmed
        } else {
            FilesAccessGuard.resolvedHomeURL(overriding: homeDirectoryURL).path
        }

        let decision = FilesAccessGuard.evaluate(path: targetRaw, homeDirectoryURL: homeDirectoryURL, filesConfig: filesConfig)
        guard decision.allowed else {
            let reason = decision.reason ?? "Access to this path is denied by security policy."
            return .failure(reason, callID: input.callID)
        }

        let targetURL = URL(fileURLWithPath: decision.resolvedPath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDir) else {
            return .failure("Directory not found: \(decision.resolvedPath)", callID: input.callID)
        }
        guard isDir.boolValue else {
            return .failure("Not a directory: \(decision.resolvedPath)", callID: input.callID)
        }

        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ]

        let options: FileManager.DirectoryEnumerationOptions = args.showHidden ? [] : [.skipsHiddenFiles]

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: targetURL,
            includingPropertiesForKeys: keys,
            options: options
        ) else {
            return .failure("Failed reading directory contents: \(decision.resolvedPath)", callID: input.callID)
        }

        var entries: [FilesListEntry] = []
        for url in contents {
            let itemDecision = FilesAccessGuard.evaluate(url: url, homeDirectoryURL: homeDirectoryURL, filesConfig: filesConfig)
            guard itemDecision.allowed else { continue }

            let resourceValues = try? url.resourceValues(forKeys: Set(keys))
            let isDirectory = resourceValues?.isDirectory ?? false
            let isRegularFile = resourceValues?.isRegularFile ?? false
            let isSymlink = resourceValues?.isSymbolicLink ?? false

            // Symlinks resolve as directories through resource values, so test
            // the link bit first to preserve the schema's symlink identity.
            let type = if isSymlink {
                "symlink"
            } else if isDirectory {
                "directory"
            } else if isRegularFile {
                "file"
            } else {
                "other"
            }

            let sizeBytes: Int64? = isRegularFile ? Int64(resourceValues?.fileSize ?? 0) : nil

            entries.append(FilesListEntry(
                name: url.lastPathComponent,
                path: itemDecision.resolvedPath,
                type: type,
                sizeBytes: sizeBytes
            ))
        }

        // Sort directories first, then files alphabetically
        entries.sort { first, second in
            if first.type == "directory", second.type != "directory" {
                return true
            }
            if first.type != "directory", second.type == "directory" {
                return false
            }
            return first.name.localizedStandardCompare(second.name) == .orderedAscending
        }

        let truncated = entries.count > args.limit
        let limitedEntries = Array(entries.prefix(args.limit))
        let envelope = FilesListEnvelope(entries: limitedEntries, truncated: truncated)

        do {
            let data = try JSONEncoder().encode(envelope)
            let jsonString = String(bytes: data, encoding: .utf8) ?? "{}"
            return .success(jsonString, callID: input.callID)
        } catch {
            return .failure("Failed encoding directory listing: \(error.localizedDescription)", callID: input.callID)
        }
    }
}

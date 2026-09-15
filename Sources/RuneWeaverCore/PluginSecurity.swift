// Rune Weaver Core — Plugin security boundaries, cryptographic hashing, and tamper detection.
//
// Calculates deterministic SHA-256 directory tree hashes for plugin packages.
// Provides tamper verification against approved hashes to invalidate modified plugins.
// Enforces filesystem write restrictions preventing automated tools or compromised prompts
// from directly mutating installed plugins or runtime configuration.

import CryptoKit
import Foundation

/// Security and integrity services for Rune Weaver plugins.
public enum PluginSecurity {
    /// File and directory names ignored during tree hashing and validation.
    public static let ignoredFileNames: Set<String> = [
        ".DS_Store",
        "__pycache__",
        ".git",
        ".gitignore",
        ".venv",
        "venv",
        ".pytest_cache"
    ]

    /// Calculates a deterministic SHA-256 tree hash of all files in a plugin directory.
    ///
    /// Every entry is gathered recursively, filtered only for transient caches, and
    /// sorted by relative POSIX path. Hidden dotfiles stay in the digest because an
    /// attacker can hide executable payload behind a leading dot that a manifest
    /// never names directly. Each record is length-framed so adjacent path and
    /// content bytes cannot be re-split into a colliding entry, and symlink
    /// destinations plus POSIX mode bits are folded in so target swaps or
    /// permission escalations invalidate the recorded approval hash.
    /// - Parameter directoryURL: Absolute URL to the plugin directory.
    /// - Returns: Lowercase hex SHA-256 string, or nil if the directory is unreadable.
    public static func calculateDirectoryHash(at directoryURL: URL) -> String? {
        let fileManager = FileManager.default
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }

        guard let entries = collectEntries(at: directoryURL, fileManager: fileManager) else {
            return nil
        }

        var hasher = SHA256()
        for entry in entries {
            // Frame the path with its byte length plus a separator so
            // ("a", "bc") and ("ab", "c") can never produce the same stream.
            if let pathData = entry.relativePath.data(using: .utf8) {
                var pathLength = UInt64(pathData.count).bigEndian
                withUnsafeBytes(of: &pathLength) { hasher.update(bufferPointer: $0) }
                hasher.update(data: pathData)
            }
            hasher.update(data: Data([0x00]))

            if entry.isSymlink {
                // Symlink target is hashed rather than followed
                hasher.update(data: Data([0x4C]))
                if let destData = entry.symlinkDestination.data(using: .utf8) {
                    var destLength = UInt64(destData.count).bigEndian
                    withUnsafeBytes(of: &destLength) { hasher.update(bufferPointer: $0) }
                    hasher.update(data: destData)
                }
                var modeBE = entry.mode.bigEndian
                withUnsafeBytes(of: &modeBE) { hasher.update(bufferPointer: $0) }
                hasher.update(data: Data([0x00]))
            } else if entry.isDirectory {
                // Directory markers make empty-directory creation visible
                hasher.update(data: Data([0x44]))
                var modeBE = entry.mode.bigEndian
                withUnsafeBytes(of: &modeBE) { hasher.update(bufferPointer: $0) }
                hasher.update(data: Data([0x00]))
            } else {
                guard hashFileEntry(entry, at: directoryURL, fileManager: fileManager, into: &hasher) else {
                    return nil
                }
            }
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private struct HashedEntry {
        let relativePath: String
        let isSymlink: Bool
        let symlinkDestination: String
        let isDirectory: Bool
        let mode: UInt32
    }

    private static func collectEntries(at directoryURL: URL, fileManager: FileManager) -> [HashedEntry]? {
        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey],
            options: []
        ) else {
            return nil
        }

        var entries: [HashedEntry] = []
        let rootPath = directoryURL.standardizedFileURL.path

        for case let fileURL as URL in enumerator {
            let lastComponent = fileURL.lastPathComponent
            if ignoredFileNames.contains(lastComponent) {
                if (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey])
            let isSymlink = resourceValues?.isSymbolicLink == true
            let isDirectory = resourceValues?.isDirectory == true
            let isRegularFile = resourceValues?.isRegularFile == true
            guard isSymlink || isDirectory || isRegularFile else {
                continue
            }

            let standardPath = fileURL.standardizedFileURL.path
            guard standardPath.hasPrefix(rootPath) else {
                continue
            }
            let relative = String(standardPath.dropFirst(rootPath.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !relative.isEmpty else {
                continue
            }

            var mode: UInt32 = 0
            if let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
               let permissions = attributes[.posixPermissions] as? Int
            {
                mode = UInt32(truncatingIfNeeded: permissions)
            }
            var destination = ""
            if isSymlink {
                destination = (try? fileManager.destinationOfSymbolicLink(atPath: fileURL.path)) ?? ""
            }
            entries.append(HashedEntry(
                relativePath: relative,
                isSymlink: isSymlink,
                symlinkDestination: destination,
                isDirectory: isDirectory && !isSymlink,
                mode: mode
            ))
        }

        entries.sort { $0.relativePath < $1.relativePath }
        return entries
    }

    private static func hashFileEntry(
        _ entry: HashedEntry,
        at directoryURL: URL,
        fileManager: FileManager,
        into hasher: inout SHA256
    ) -> Bool {
        hasher.update(data: Data([0x46]))
        let fileURL = directoryURL.appendingPathComponent(entry.relativePath)
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return false
        }
        defer { try? handle.close() }

        guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
              let fileSize = attributes[.size] as? UInt64
        else {
            return false
        }

        var contentLength = fileSize.bigEndian
        withUnsafeBytes(of: &contentLength) { hasher.update(bufferPointer: $0) }

        let chunkSize = 64 * 1024
        var bytesRead: UInt64 = 0
        while true {
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                break
            }
            bytesRead += UInt64(chunk.count)
            hasher.update(data: chunk)
        }

        guard bytesRead == fileSize else {
            return false
        }

        var modeBE = entry.mode.bigEndian
        withUnsafeBytes(of: &modeBE) { hasher.update(bufferPointer: $0) }
        hasher.update(data: Data([0x00]))
        return true
    }

    /// Compares two hex digests without regard to case.
    ///
    /// Single-sources the approval-hash comparison so the registry store and
    /// the integrity verifier cannot drift on case handling.
    /// - Parameters:
    ///   - lhs: First digest.
    ///   - rhs: Second digest.
    /// - Returns: True when both digests match ignoring case.
    public static func hashesEqual(_ lhs: String, _ rhs: String) -> Bool {
        lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }

    /// Verifies whether the files in a plugin directory match the recorded approval hash.
    /// - Parameters:
    ///   - directoryURL: Directory to inspect.
    ///   - expectedHash: The SHA-256 digest recorded when the human approved the plugin.
    /// - Returns: True if current files match the expected hash; false if modified or unreadable.
    public static func verifyIntegrity(at directoryURL: URL, expectedHash: String) -> Bool {
        guard let currentHash = calculateDirectoryHash(at: directoryURL) else {
            return false
        }
        return hashesEqual(currentHash, expectedHash)
    }

    /// Checks whether a target file URL points inside a protected engine path.
    ///
    /// The agent is prohibited from writing directly to `~/.runeweaver/plugins/`
    /// or `~/.runeweaver/config.toml`. Tool proposals must stage in `pending_plugins/`
    /// first to require human approval in the inbox.
    /// - Parameters:
    ///   - targetURL: Candidate path for file creation or modification.
    ///   - pluginsDir: Configured root plugins directory.
    /// - Returns: True if the path is protected and direct writes must be blocked.
    public static func isProtectedPath(targetURL: URL, pluginsDir: URL? = nil) -> Bool {
        /// Normalize through symlink resolution plus standardization so a
        /// symlinked plugins root or ".." segments cannot escape the prefix
        /// check, and require a "/" boundary so a sibling such as
        /// ".../plugins2" never matches the protected pen.
        func normalizedPath(_ url: URL) -> String {
            url.resolvingSymlinksInPath().standardizedFileURL.path
        }
        func isInside(_ target: String, _ root: String) -> Bool {
            target == root || target.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }

        let standardTarget = normalizedPath(targetURL)
        let homeDir = normalizedPath(FileManager.default.homeDirectoryForCurrentUser)
        let defaultPlugins = (homeDir as NSString).appendingPathComponent(".runeweaver/plugins")
        let defaultConfig = (homeDir as NSString).appendingPathComponent(".runeweaver/config.toml")

        if isInside(standardTarget, defaultPlugins) || standardTarget == defaultConfig {
            return true
        }

        if let pluginsDir {
            let customPlugins = normalizedPath(pluginsDir)
            if isInside(standardTarget, customPlugins) {
                return true
            }
        }

        return false
    }
}

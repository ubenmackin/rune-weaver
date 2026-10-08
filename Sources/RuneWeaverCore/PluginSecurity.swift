// Rune Weaver Core — Plugin security boundaries, cryptographic hashing, and tamper detection.

import CryptoKit
import Foundation

/// Security and integrity services for Rune Weaver plugins.
public enum PluginSecurity {
    /// File and directory names ignored during tree hashing and validation.
    /// Transient caches plus source-control metadata stay out of the hash so
    /// routine checkouts never read as tampering, while review covers
    /// provisioned source rather than the runtime itself.
    /// Provisioned virtual-environment directories (`.venv`/`venv`) hold
    /// executable code and stay hashed: skipping them would let a tampered
    /// interpreter or installed package bypass detection. Only narrow
    /// reinstall caches inside those environments (pip HTTP subtree, wheel
    /// downloads, `__pycache__` bytecode) stay out of the hash via
    /// `isVenvCacheEntry`; arbitrary files such as `.cache/evil.py` keep
    /// hashing, and dependency upgrades still change the digest and require
    /// re-approval by design.
    public static let ignoredFileNames: Set<String> = [
        ".DS_Store",
        "__pycache__",
        ".git",
        ".gitignore",
        ".pytest_cache"
    ]

    /// Directory names marking a provisioned Python virtual environment.
    private static let venvDirectoryNames: Set<String> = ["venv", ".venv"]

    /// Calculates a deterministic SHA-256 tree hash of all files in a plugin directory.
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
            // Only regenerable reinstall caches inside provisioned environments
            // stay out of the hash; every other venv entry (executables,
            // manifests, installed sources, plus arbitrary files such as
            // `.cache/evil.py`) remains hashed so tamper stays visible.
            if isVenvCacheEntry(
                relativePath: relative,
                lastComponent: lastComponent,
                isDirectory: isDirectory,
                isSymlink: isSymlink
            ) {
                if isDirectory, !isSymlink {
                    enumerator.skipDescendants()
                }
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

    /// Reports whether a plugin-relative path is a regenerable reinstall cache
    /// inside a provisioned virtual environment. Only the pip HTTP cache
    /// subtree, wheel downloads, and bytecode inside `__pycache__` qualify;
    /// launchers, manifests, installed sources, and arbitrary files such as
    /// `.cache/evil.py` stay hashed so executable tamper changes the digest.
    /// Symlinks always hash so a retargeted link cannot hide behind a cache
    /// name, and cache directory markers hash (except the pip subtree root)
    /// so file tamper inside stays visible while pip churn alone avoids
    /// forcing re-approval.
    private static func isVenvCacheEntry(
        relativePath: String,
        lastComponent: String,
        isDirectory: Bool,
        isSymlink: Bool
    ) -> Bool {
        // A symlink target change is tamper even under a cache-looking name,
        // and hashing a link costs only its target string, so links never skip.
        if isSymlink {
            return false
        }
        let segments = relativePath.lowercased().split(separator: "/").map(String.init)
        guard let venvIndex = segments.firstIndex(where: { venvDirectoryNames.contains($0) }) else {
            return false
        }
        // The venv directory marker itself hashes so removing the environment
        // stays visible; only entries beneath it can qualify as caches.
        guard venvIndex + 1 < segments.count else {
            return false
        }
        let suffix = Array(segments[(venvIndex + 1)...])
        let loweredLast = lastComponent.lowercased()
        // Wheel downloads are regenerable fetches, never executed in place;
        // sibling sources such as `wheels/evil.py` keep hashing. Only files
        // skip so a directory that happens to end in `.whl` still hashes its
        // marker and lets its contents speak individually.
        if !isDirectory, loweredLast.hasSuffix(".whl") {
            return true
        }
        // Bytecode only counts inside `__pycache__` where the interpreter
        // regenerates it; stray colocated `.pyc` files hash so planted
        // bytecode stays visible. Top-level `__pycache__` directories already
        // skip via the ignored names before reaching here.
        if !isDirectory,
           loweredLast.hasSuffix(".pyc") || loweredLast.hasSuffix(".pyo"),
           suffix.contains("__pycache__")
        {
            return true
        }
        // Pip HTTP cache only: a consecutive `.cache/pip` pair anywhere beneath
        // the venv. The pair covers both the immediate `venv/.cache/pip` layout
        // and nested managers, while a bare `.cache/evil.py` without the `pip`
        // hop keeps hashing. Directories hash except the pip subtree root, whose
        // marker plus descendants skip together so cache churn does not force
        // re-approval; file tamper under a hashed parent still surfaces via the
        // file entry itself.
        if suffix.count >= 2 {
            for index in 0 ..< (suffix.count - 1) {
                if suffix[index] == ".cache", suffix[index + 1] == "pip" {
                    return true
                }
            }
        }
        return false
    }

    private static func hashFileEntry(
        _ entry: HashedEntry,
        at directoryURL: URL,
        fileManager: FileManager,
        into hasher: inout SHA256
    ) -> Bool {
        hasher.update(data: Data([0x46]))
        let fileURL = directoryURL.appendingPathComponent(entry.relativePath)
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            RuneWeaverLog.tools.debug("PluginSecurity: failed opening file handle at \(fileURL.path): \(error.localizedDescription)")
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
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: chunkSize)
            } catch {
                RuneWeaverLog.tools.debug("PluginSecurity: failed reading chunk from \(fileURL.path): \(error.localizedDescription)")
                chunk = nil
            }
            guard let chunk, !chunk.isEmpty else {
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
    public static func hashesEqual(_ lhs: String, _ rhs: String) -> Bool {
        lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }

    /// Verifies whether the files in a plugin directory match the recorded approval hash.
    public static func verifyIntegrity(at directoryURL: URL, expectedHash: String) -> Bool {
        guard let currentHash = calculateDirectoryHash(at: directoryURL) else {
            return false
        }
        return hashesEqual(currentHash, expectedHash)
    }

    /// Checks whether a target file URL points inside a protected engine path.
    public static func isProtectedPath(targetURL: URL, pluginsDir: URL? = nil) -> Bool {
        /// Normalize through symlink resolution plus standardization so a symlinked plugins root or
        /// ".." segments cannot escape the prefix check, and require a "/" boundary so a sibling
        /// such as ".../plugins2" never matches the protected pen.
        func normalizedPath(_ url: URL) -> String {
            url.resolvingSymlinksInPath().standardizedFileURL.path
        }
        func isInside(_ target: String, _ root: String) -> Bool {
            target == root || target.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }

        let standardTarget = normalizedPath(targetURL)
        let homeDir = normalizedPath(FileManager.default.homeDirectoryForCurrentUser)
        let defaultPlugins = (homeDir as NSString).appendingPathComponent(".runeweaver/plugins")
        // The memory tree is the engine's private state — episodic sessions and
        // approvals, the trust-grant ledger, and the plaintext profile plus
        // semantic vectors — so a tool must be refused outright rather than
        // earning write access through the ordinary approval path.
        let defaultMemory = (homeDir as NSString).appendingPathComponent(".runeweaver/memory")
        let defaultConfig = (homeDir as NSString).appendingPathComponent(".runeweaver/config.toml")
        // The egress policy file is the credential/network control plane, and
        // the bearer token authorizes non-loopback access, so a tool must no
        // more replace them than the engine config beside them.
        let defaultPolicy = (homeDir as NSString).appendingPathComponent(".runeweaver/policy.toml")
        let defaultTokenFile = (homeDir as NSString).appendingPathComponent(".runeweaver/auth_token")

        if isInside(standardTarget, defaultPlugins) || isInside(standardTarget, defaultMemory)
            || standardTarget == defaultConfig
            || standardTarget == defaultPolicy || standardTarget == defaultTokenFile
        {
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

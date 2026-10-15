// Rune Weaver Core — Bootstrapping and verification of local llama-server binary.

import Foundation

#if canImport(Darwin)
    import Darwin
#endif

/// Errors raised during `llama-server` binary provisioning.
public enum LlamaServerProvisionError: Error, Sendable, Equatable {
    /// Download of binary archive failed.
    case downloadFailed(String)
    /// Extraction of binary archive failed.
    case extractionFailed(String)
    /// Destination directory creation failed.
    case directoryCreationFailed(String)
    /// Binary could not be made executable.
    case permissionFailed(String)
}

/// Automatically provisions the precompiled `llama-server` Darwin Metal binary if not installed.
public struct LlamaServerProvisioner: Sendable {
    /// Target binary filename.
    public static let binaryFileName = "llama-server"
    /// Default local bin directory under user home.
    public static let defaultBinDirectoryPath = "~/.runeweaver/bin"

    /// Known search paths for existing installations.
    public static let candidateBinaryPaths = [
        ("~/.runeweaver/bin/llama-server" as NSString).expandingTildeInPath,
        "/opt/homebrew/bin/llama-server",
        "/usr/local/bin/llama-server",
        "/usr/bin/llama-server"
    ]

    /// Pinned fallback release archive URL for macOS ARM64 Metal from ggml-org/llama.cpp.
    public static let defaultArchiveURL = URL(
        string: "https://github.com/ggml-org/llama.cpp/releases/download/b11609/llama-b11609-bin-macos-arm64.tar.gz"
    )!

    /// Directory where the provisioned binary lives.
    public let binDirectoryPath: String
    /// Download archive URL.
    public let archiveURL: URL

    /// Injected check for testing.
    private let fileExistsCheck: (@Sendable (URL) -> Bool)?
    /// Injected download action for testing.
    private let downloadAndExtractAction: (@Sendable (URL, URL) async throws -> Void)?

    /// Creates a server provisioner.
    public init(
        binDirectoryPath: String = defaultBinDirectoryPath,
        archiveURL: URL = defaultArchiveURL,
        fileExistsCheck: (@Sendable (URL) -> Bool)? = nil,
        downloadAndExtractAction: (@Sendable (URL, URL) async throws -> Void)? = nil
    ) {
        self.binDirectoryPath = binDirectoryPath
        self.archiveURL = archiveURL
        self.fileExistsCheck = fileExistsCheck
        self.downloadAndExtractAction = downloadAndExtractAction
    }

    /// Destination binary URL in `~/.runeweaver/bin/llama-server`.
    public var destinationBinaryURL: URL {
        let expanded = (binDirectoryPath as NSString).expandingTildeInPath
        let dirURL = URL(fileURLWithPath: expanded, isDirectory: true)
        return dirURL.appendingPathComponent(Self.binaryFileName)
    }

    /// Minimum llama.cpp build supporting EmbeddingGemma 2 (introduced in b11452+).
    public static let minCompatibleBuild = 11452

    /// Validates that a `llama-server` binary exists, is executable, and meets the minimum build requirement.
    public static func isCompatibleBinary(at url: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return false }
        let process = Process()
        process.executableURL = url
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return false }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return false }
            if let buildRange = output.range(of: "build ") {
                let afterBuild = output[buildRange.upperBound...]
                let digits = afterBuild.prefix(while: { $0.isNumber })
                if let buildNumber = Int(digits), buildNumber >= minCompatibleBuild {
                    return true
                }
            }
            return false
        } catch {
            return false
        }
    }

    /// Finds an existing executable `llama-server` on the machine if present and compatible.
    public func findExistingBinary() -> URL? {
        let dest = destinationBinaryURL
        if let check = fileExistsCheck {
            return check(dest) ? dest : nil
        }

        if Self.isCompatibleBinary(at: dest) {
            return dest
        }

        // Check known locations
        for path in Self.candidateBinaryPaths {
            let candidate = URL(fileURLWithPath: path)
            if candidate.standardizedFileURL != dest.standardizedFileURL, Self.isCompatibleBinary(at: candidate) {
                return candidate
            }
        }

        // Check system PATH
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(Self.binaryFileName)
                if candidate.standardizedFileURL != dest.standardizedFileURL, Self.isCompatibleBinary(at: candidate) {
                    return candidate
                }
            }
        }
        return nil
    }

    /// Whether `llama-server` is available anywhere on the machine.
    public func isBinaryAvailable() -> Bool {
        findExistingBinary() != nil
    }

    /// Ensures `llama-server` is present and executable, bootstrapping it automatically if missing.
    /// - Returns: Executable URL to `llama-server`.
    @discardableResult
    public func ensureBinaryAvailable() async throws -> URL {
        if let existing = findExistingBinary() {
            return existing
        }

        let targetBin = destinationBinaryURL
        let binDir = targetBin.deletingLastPathComponent()

        do {
            try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        } catch {
            throw LlamaServerProvisionError.directoryCreationFailed(
                "Could not create binary directory at \(binDir.path): \(error.localizedDescription)"
            )
        }

        if let custom = downloadAndExtractAction {
            try await custom(archiveURL, binDir)
            return targetBin
        }

        RuneWeaverLog.stores.info("LlamaServerProvisioner: Downloading llama-server archive from \(archiveURL.absoluteString)...")

        // Live download and extraction
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 1800
        let session = URLSession(configuration: config)

        let tempArchiveURL: URL
        do {
            let (downloadedURL, response) = try await session.download(from: archiveURL)
            if let http = response as? HTTPURLResponse, http.statusCode < 200 || http.statusCode >= 300 {
                throw LlamaServerProvisionError.downloadFailed("HTTP \(http.statusCode) downloading \(archiveURL)")
            }
            tempArchiveURL = downloadedURL
        } catch let error as LlamaServerProvisionError {
            throw error
        } catch {
            throw LlamaServerProvisionError.downloadFailed("Failed to download llama-server: \(error.localizedDescription)")
        }

        // Unpack tar.gz via /usr/bin/tar into binDir off the cooperative pool
        try await Task.detached {
            let tarProcess = Process()
            tarProcess.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tarProcess.arguments = ["-xzf", tempArchiveURL.path, "-C", binDir.path, "--strip-components", "1"]

            do {
                try tarProcess.run()
                tarProcess.waitUntilExit()
                if tarProcess.terminationStatus != 0 {
                    // Fallback attempt without --strip-components in case tar differs
                    let fallbackTar = Process()
                    fallbackTar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                    fallbackTar.arguments = ["-xzf", tempArchiveURL.path, "-C", binDir.path]
                    try fallbackTar.run()
                    fallbackTar.waitUntilExit()
                    if fallbackTar.terminationStatus != 0 {
                        throw LlamaServerProvisionError.extractionFailed("tar extraction exited with code \(fallbackTar.terminationStatus)")
                    }
                }
            } catch let error as LlamaServerProvisionError {
                throw error
            } catch {
                throw LlamaServerProvisionError.extractionFailed("Failed to run /usr/bin/tar: \(error.localizedDescription)")
            }
        }.value

        try? FileManager.default.removeItem(at: tempArchiveURL)

        // Flatten any subdirectories into binDir so dylibs sit next to the binary
        // Collect URLs first to avoid mutating during enumeration
        var filesToMove: [(src: URL, dest: URL)] = []
        if let enumerator = FileManager.default.enumerator(at: binDir, includingPropertiesForKeys: nil) {
            while let fileURL = enumerator.nextObject() as? URL {
                if fileURL.deletingLastPathComponent().path != binDir.path {
                    let dest = binDir.appendingPathComponent(fileURL.lastPathComponent)
                    filesToMove.append((src: fileURL, dest: dest))
                }
            }
        }
        for item in filesToMove where !FileManager.default.fileExists(atPath: item.dest.path) {
            try? FileManager.default.moveItem(at: item.src, to: item.dest)
        }

        // Ensure executable permissions (0o755)
        #if canImport(Darwin)
            _ = chmod(targetBin.path, 0o755)
        #endif

        // Strip quarantine flag if present
        let xattrProcess = Process()
        xattrProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattrProcess.arguments = ["-rd", "com.apple.quarantine", binDir.path]
        try? xattrProcess.run()
        xattrProcess.waitUntilExit()

        guard FileManager.default.isExecutableFile(atPath: targetBin.path) else {
            throw LlamaServerProvisionError.permissionFailed("llama-server at \(targetBin.path) is not executable")
        }

        return targetBin
    }
}

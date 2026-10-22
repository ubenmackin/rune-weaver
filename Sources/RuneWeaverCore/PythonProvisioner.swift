// Rune Weaver Core — Provisioning and verification of supported CPython runtime.

import CryptoKit
import Foundation

#if canImport(Darwin)
    import Darwin
#endif

/// Errors raised during CPython runtime provisioning.
public enum PythonProvisionError: Error, Sendable, Equatable {
    /// Download of the archive failed.
    case downloadFailed(String)
    /// Size, hash, or layout verification failed.
    case verificationFailed(String)
    /// Extraction of the archive failed.
    case extractionFailed(String)
    /// Destination directory creation failed.
    case directoryCreationFailed(String)
    /// Interpreter could not be made executable.
    case permissionFailed(String)
}

/// Provisions the pinned CPython 3.12 runtime under the user data dir.
public struct PythonProvisioner: Sendable {
    /// Pinned CPython line supported for plugin virtual environments.
    public static let defaultPythonVersion = "3.12.9"
    /// Default install root under the user home.
    public static let defaultInstallRoot = "~/.runeweaver/python"
    /// Relative path of the interpreter inside the install root.
    public static let interpreterRelativePath = "bin/python3"

    /// Pinned Darwin ARM64 archive for the supported CPython line.
    public static let defaultArchiveURL: URL = {
        guard let url = URL(
            string: "https://github.com/astral-sh/python-build-standalone/releases/download/20250205/cpython-3.12.9+20250205-aarch64-apple-darwin-install_only.tar.gz"
        ) else {
            preconditionFailure("Invalid hardcoded CPython archive URL")
        }
        return url
    }()

    /// Pinned SHA-256 digest for the declared archive.
    public static let defaultArchiveSHA256 = "b5199d66966141fb6d5447512d2b2fe0398d417da37b1949f58db3792d314eac"
    /// Minimum archive byte count accepted as a complete download.
    public static let defaultMinArchiveSize: Int64 = 10_000_000

    /// Install root path (tilde-expanded at use).
    public let installRootPath: String
    /// Remote archive URL.
    public let archiveURL: URL
    /// Expected SHA-256 hex digest for the archive.
    public let expectedSHA256: String
    /// Minimum valid archive byte count.
    public let minArchiveSize: Int64

    /// Injected existence check for testing.
    private let fileExistsCheck: (@Sendable (URL) -> Bool)?
    /// Injected archive fetch for testing (writes archive bytes to temp path).
    private let downloadAction: (@Sendable (URL, URL) async throws -> Void)?
    /// Injected full install for testing (receives archive URL and install dir).
    private let downloadAndExtractAction: (@Sendable (URL, URL) async throws -> Void)?

    /// Creates a CPython provisioner.
    public init(
        installRootPath: String = defaultInstallRoot,
        archiveURL: URL = defaultArchiveURL,
        expectedSHA256: String = defaultArchiveSHA256,
        minArchiveSize: Int64 = defaultMinArchiveSize,
        fileExistsCheck: (@Sendable (URL) -> Bool)? = nil,
        downloadAction: (@Sendable (URL, URL) async throws -> Void)? = nil,
        downloadAndExtractAction: (@Sendable (URL, URL) async throws -> Void)? = nil
    ) {
        self.installRootPath = installRootPath
        self.archiveURL = archiveURL
        self.expectedSHA256 = expectedSHA256
        self.minArchiveSize = minArchiveSize
        self.fileExistsCheck = fileExistsCheck
        self.downloadAction = downloadAction
        self.downloadAndExtractAction = downloadAndExtractAction
    }

    /// Destination interpreter URL under the install root.
    public var destinationInterpreterURL: URL {
        let expanded = (installRootPath as NSString).expandingTildeInPath
        let rootURL = URL(fileURLWithPath: expanded, isDirectory: true)
        return rootURL.appendingPathComponent(Self.interpreterRelativePath)
    }

    /// Install root directory URL.
    private var installRootURL: URL {
        let expanded = (installRootPath as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    /// Validates that an interpreter binary exists, runs, and reports the 3.12 line.
    public static func isCompatibleInterpreter(at url: URL) -> Bool {
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
            return output.contains("3.12")
        } catch {
            return false
        }
    }

    /// Reports whether the provisioned interpreter is present and executable.
    public func isProvisioned() -> Bool {
        let dest = destinationInterpreterURL
        if let check = fileExistsCheck {
            return check(dest)
        }
        return Self.isCompatibleInterpreter(at: dest)
    }

    /// Ensures the pinned interpreter exists, provisioning it atomically when missing.
    /// - Returns: Executable interpreter URL.
    @discardableResult
    public func ensureProvisioned() async throws -> URL {
        let dest = destinationInterpreterURL
        if isProvisioned() {
            return dest
        }

        let rootURL = installRootURL
        do {
            try FileManager.default.createDirectory(at: rootURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw PythonProvisionError.directoryCreationFailed(
                "Could not create install parent at \(rootURL.path): \(error.localizedDescription)"
            )
        }

        if let custom = downloadAndExtractAction {
            try await custom(archiveURL, rootURL)
            guard FileManager.default.isExecutableFile(atPath: dest.path) else {
                throw PythonProvisionError.permissionFailed("Provisioned interpreter at \(dest.path) is not executable")
            }
            return dest
        }

        RuneWeaverLog.stores.info("PythonProvisioner: Downloading CPython \(Self.defaultPythonVersion) from \(archiveURL.absoluteString)...")

        let tempArchiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cpython-\(UUID().uuidString).tar.gz")
        defer { try? FileManager.default.removeItem(at: tempArchiveURL) }

        try await downloadArchive(to: tempArchiveURL)

        // Size floor rejects truncated downloads before hashing.
        let archiveSize = (try? tempArchiveURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard Int64(archiveSize) >= minArchiveSize else {
            throw PythonProvisionError.verificationFailed(
                "Downloaded archive is truncated (\(archiveSize) bytes < \(minArchiveSize) minimum)."
            )
        }

        let digest = try sha256HexOfFile(at: tempArchiveURL)
        guard digest.caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
            throw PythonProvisionError.verificationFailed("Archive SHA-256 mismatch; refusing to install.")
        }

        try await rejectTraversal(in: tempArchiveURL)

        let stagingParent = FileManager.default.temporaryDirectory
            .appendingPathComponent("python-staging-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: stagingParent, withIntermediateDirectories: true)
        } catch {
            throw PythonProvisionError.directoryCreationFailed(
                "Could not create staging directory: \(error.localizedDescription)"
            )
        }
        defer { try? FileManager.default.removeItem(at: stagingParent) }

        try await extractArchive(at: tempArchiveURL, to: stagingParent)

        // Standalone archives nest under `python/`; direct extracts land `bin/` at top.
        let nestedRoot = stagingParent.appendingPathComponent("python", isDirectory: true)
        let payloadRoot: URL
        if FileManager.default.fileExists(atPath: nestedRoot.appendingPathComponent(Self.interpreterRelativePath).path) {
            payloadRoot = nestedRoot
        } else if FileManager.default.fileExists(atPath: stagingParent.appendingPathComponent(Self.interpreterRelativePath).path) {
            payloadRoot = stagingParent
        } else {
            throw PythonProvisionError.extractionFailed("Archive did not contain \(Self.interpreterRelativePath)")
        }

        // Only verified payload reaches the destination, so failure leaves no partial install.
        do {
            if FileManager.default.fileExists(atPath: rootURL.path) {
                try FileManager.default.removeItem(at: rootURL)
            }
            if payloadRoot.standardizedFileURL == stagingParent.standardizedFileURL {
                try FileManager.default.moveItem(at: stagingParent, to: rootURL)
            } else {
                try FileManager.default.moveItem(at: payloadRoot, to: rootURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: rootURL)
            throw PythonProvisionError.extractionFailed("Failed to stage CPython into place: \(error.localizedDescription)")
        }

        #if canImport(Darwin)
            _ = chmod(dest.path, 0o755)
        #endif

        // Quarantine flags on Gatekeeper-checked hosts would block exec; strip best-effort.
        let xattrProcess = Process()
        xattrProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattrProcess.arguments = ["-rd", "com.apple.quarantine", rootURL.path]
        try? xattrProcess.run()
        xattrProcess.waitUntilExit()

        guard FileManager.default.isExecutableFile(atPath: dest.path) else {
            try? FileManager.default.removeItem(at: rootURL)
            throw PythonProvisionError.permissionFailed("Provisioned interpreter at \(dest.path) is not executable")
        }

        return dest
    }

    /// Fetches the archive to the temp path via hook or URLSession.
    private func downloadArchive(to tempArchiveURL: URL) async throws {
        if let customDownload = downloadAction {
            try await customDownload(archiveURL, tempArchiveURL)
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 300
            config.timeoutIntervalForResource = 1800
            let session = URLSession(configuration: config)
            do {
                let (downloadedURL, response) = try await session.download(from: archiveURL)
                if let http = response as? HTTPURLResponse, http.statusCode < 200 || http.statusCode >= 300 {
                    throw PythonProvisionError.downloadFailed("HTTP \(http.statusCode) downloading \(archiveURL)")
                }
                if FileManager.default.fileExists(atPath: tempArchiveURL.path) {
                    try? FileManager.default.removeItem(at: tempArchiveURL)
                }
                try FileManager.default.moveItem(at: downloadedURL, to: tempArchiveURL)
            } catch let error as PythonProvisionError {
                throw error
            } catch {
                throw PythonProvisionError.downloadFailed("Failed to download CPython: \(error.localizedDescription)")
            }
        }
    }

    /// Computes the lowercase SHA-256 hex digest by streaming the file.
    private func sha256HexOfFile(at url: URL) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw PythonProvisionError.verificationFailed("Could not read archive for hashing: \(error.localizedDescription)")
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: 1024 * 1024)
            } catch {
                throw PythonProvisionError.verificationFailed("Could not hash archive: \(error.localizedDescription)")
            }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Lists archive members and rejects absolute or parent-escaping entries.
    private func rejectTraversal(in archiveURL: URL) async throws {
        let members = try await archiveMembers(at: archiveURL)
        for member in members {
            let trimmed = member.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            // Absolute targets plus `..` segments would write outside the staging dir.
            if trimmed.hasPrefix("/") || trimmed.hasPrefix("\\") {
                throw PythonProvisionError.verificationFailed("Archive contains absolute path: \(trimmed)")
            }
            let segments = trimmed.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
            if segments.contains("..") || trimmed.contains("../") || trimmed.contains("..\\") {
                throw PythonProvisionError.verificationFailed("Archive contains parent-escaping path: \(trimmed)")
            }
        }
    }

    /// Runs `tar -tzf` off the cooperative pool to list archive members.
    private func archiveMembers(at archiveURL: URL) async throws -> [String] {
        try await Task.detached {
            let listProcess = Process()
            listProcess.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            listProcess.arguments = ["-tzf", archiveURL.path]
            let pipe = Pipe()
            let errorPipe = Pipe()
            listProcess.standardOutput = pipe
            listProcess.standardError = errorPipe
            do {
                try listProcess.run()
                listProcess.waitUntilExit()
            } catch {
                throw PythonProvisionError.verificationFailed("Failed to inspect archive: \(error.localizedDescription)")
            }
            guard listProcess.terminationStatus == 0 else {
                throw PythonProvisionError.verificationFailed("Archive is corrupt (tar listing failed).")
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return output.components(separatedBy: .newlines)
        }.value
    }

    /// Extracts the verified archive into the staging directory.
    private func extractArchive(at archiveURL: URL, to stagingDir: URL) async throws {
        try await Task.detached {
            let tarProcess = Process()
            tarProcess.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tarProcess.arguments = ["-xzf", archiveURL.path, "-C", stagingDir.path]
            do {
                try tarProcess.run()
                tarProcess.waitUntilExit()
                guard tarProcess.terminationStatus == 0 else {
                    throw PythonProvisionError.extractionFailed("tar extraction exited with code \(tarProcess.terminationStatus)")
                }
            } catch let error as PythonProvisionError {
                throw error
            } catch {
                throw PythonProvisionError.extractionFailed("Failed to run /usr/bin/tar: \(error.localizedDescription)")
            }
        }.value
    }
}

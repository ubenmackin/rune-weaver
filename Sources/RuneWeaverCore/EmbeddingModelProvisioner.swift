// Rune Weaver Core — Provisioning and verification of local embedding models.

import Foundation

/// Errors that can occur during embedding model provisioning.
public enum EmbeddingModelProvisionError: Error, Sendable, Equatable {
    /// Model download failed with the given reason.
    case downloadFailed(String)
    /// File verification or checksum failed.
    case verificationFailed(String)
    /// Model directory could not be created or written.
    case directoryCreationFailed(String)
}

/// Manages local availability, downloading, and validation of the EmbeddingGemma 2 GGUF model and multimodal projector.
public struct EmbeddingModelProvisioner: Sendable {
    /// Standard model filename for EmbeddingGemma 2 text model.
    public static let defaultModelFileName = "embeddinggemma-2-Q8_0.gguf"
    /// Standard multimodal projector filename for EmbeddingGemma 2 (vision and audio encoders).
    public static let defaultMMProjFileName = "mmproj-embeddinggemma-2-Q8_0.gguf"
    /// Default local model directory under user home.
    public static let defaultModelDirectoryPath = "~/.runeweaver/models"
    /// Default Unsloth Hugging Face repository download URL for the EmbeddingGemma 2 Q8_0 GGUF.
    public static let defaultDownloadURL = URL(
        string: "https://huggingface.co/unsloth/embeddinggemma-2-GGUF/resolve/main/embeddinggemma-2-Q8_0.gguf"
    )!
    /// Default Hugging Face repository download URL for the multimodal projector.
    public static let defaultMMProjDownloadURL = URL(
        string: "https://huggingface.co/ggml-org/embeddinggemma-2-GGUF/resolve/bfcd298762cc34d0357ece5ebdd31791a3a374d8/mmproj-embeddinggemma-2-Q8_0.gguf"
    )!

    /// Default minimum file size in bytes for the text model (300 MB).
    public static let defaultMinModelSize: Int64 = 300_000_000
    /// Default minimum file size in bytes for the multimodal projector (500 MB).
    public static let defaultMinMMProjSize: Int64 = 500_000_000

    /// Target filename for the text model.
    public let modelFileName: String
    /// Target filename for the multimodal projector.
    public let mmprojFileName: String
    /// Target directory path.
    public let modelDirectoryPath: String
    /// Remote source URL for downloading the text GGUF.
    public let downloadURL: URL
    /// Remote source URL for downloading the multimodal projector.
    public let mmprojDownloadURL: URL
    /// Minimum valid byte count required to consider the text model verified.
    public let minExpectedSize: Int64
    /// Minimum valid byte count required to consider the multimodal projector verified.
    public let minMMProjExpectedSize: Int64

    /// Injected file-exists check for deterministic testing.
    private let fileExistsCheck: (@Sendable (URL) -> Bool)?
    /// Injected download action for deterministic testing.
    private let downloadAction: (@Sendable (URL, URL) async throws -> Void)?

    /// Creates a model provisioner.
    public init(
        modelFileName: String = defaultModelFileName,
        mmprojFileName: String = defaultMMProjFileName,
        modelDirectoryPath: String = defaultModelDirectoryPath,
        downloadURL: URL = defaultDownloadURL,
        mmprojDownloadURL: URL = defaultMMProjDownloadURL,
        minExpectedSize: Int64 = defaultMinModelSize,
        minMMProjExpectedSize: Int64 = defaultMinMMProjSize,
        fileExistsCheck: (@Sendable (URL) -> Bool)? = nil,
        downloadAction: (@Sendable (URL, URL) async throws -> Void)? = nil
    ) {
        self.modelFileName = modelFileName
        self.mmprojFileName = mmprojFileName
        self.modelDirectoryPath = modelDirectoryPath
        self.downloadURL = downloadURL
        self.mmprojDownloadURL = mmprojDownloadURL
        self.minExpectedSize = minExpectedSize
        self.minMMProjExpectedSize = minMMProjExpectedSize
        self.fileExistsCheck = fileExistsCheck
        self.downloadAction = downloadAction
    }

    /// Resolves the canonical local destination file URL for the text model.
    public var destinationFileURL: URL {
        let expanded = (modelDirectoryPath as NSString).expandingTildeInPath
        let dirURL = URL(fileURLWithPath: expanded, isDirectory: true)
        return dirURL.appendingPathComponent(modelFileName)
    }

    /// Resolves the canonical local destination file URL for the multimodal projector.
    public var destinationMMProjFileURL: URL {
        let expanded = (modelDirectoryPath as NSString).expandingTildeInPath
        let dirURL = URL(fileURLWithPath: expanded, isDirectory: true)
        return dirURL.appendingPathComponent(mmprojFileName)
    }

    /// Reports whether the model file currently exists and meets the minimum size requirement locally.
    public func isModelAvailable() -> Bool {
        isTargetAvailable(destinationFileURL, minSize: minExpectedSize)
    }

    /// Reports whether the multimodal projector file currently exists and meets the minimum size requirement locally.
    public func isMMProjAvailable() -> Bool {
        isTargetAvailable(destinationMMProjFileURL, minSize: minMMProjExpectedSize)
    }

    private func isTargetAvailable(_ target: URL, minSize: Int64) -> Bool {
        if let check = fileExistsCheck {
            return check(target)
        }
        guard FileManager.default.fileExists(atPath: target.path) else {
            return false
        }
        let size = (try? target.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return Int64(size) >= minSize
    }

    /// Ensures the model file is available locally, downloading and verifying it if missing or truncated.
    /// - Returns: File URL to the verified local GGUF model.
    @discardableResult
    public func ensureModelAvailable() async throws -> URL {
        try await downloadAndVerify(
            sourceURL: downloadURL,
            targetURL: destinationFileURL,
            minSize: minExpectedSize,
            label: "EmbeddingGemma 2"
        )
    }

    /// Ensures the multimodal projector file is available locally, downloading and verifying it if missing or truncated.
    /// - Returns: File URL to the verified local multimodal projector.
    @discardableResult
    public func ensureMMProjAvailable() async throws -> URL {
        try await downloadAndVerify(
            sourceURL: mmprojDownloadURL,
            targetURL: destinationMMProjFileURL,
            minSize: minMMProjExpectedSize,
            label: "EmbeddingGemma 2 multimodal projector"
        )
    }

    /// Ensures both the text backbone model and multimodal projector are available locally.
    /// - Returns: Tuple of verified URLs for (model, mmproj).
    public func ensureAllAvailable() async throws -> (modelURL: URL, mmprojURL: URL) {
        let model = try await ensureModelAvailable()
        let mmproj = try await ensureMMProjAvailable()
        return (model, mmproj)
    }

    private func downloadAndVerify(
        sourceURL: URL,
        targetURL: URL,
        minSize: Int64,
        label: String
    ) async throws -> URL {
        if isTargetAvailable(targetURL, minSize: minSize) {
            return targetURL
        }

        let parentDir = targetURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        } catch {
            throw EmbeddingModelProvisionError.directoryCreationFailed(
                "Could not create model directory at \(parentDir.path): \(error.localizedDescription)"
            )
        }

        if let customDownload = downloadAction {
            try await customDownload(sourceURL, targetURL)
            guard isTargetAvailable(targetURL, minSize: minSize) else {
                throw EmbeddingModelProvisionError.verificationFailed(
                    "Provisioned file at \(targetURL.path) did not meet size verification (\(minSize) bytes minimum)."
                )
            }
            return targetURL
        }

        RuneWeaverLog.stores.info("EmbeddingModelProvisioner: Downloading \(label) from \(sourceURL.absoluteString)...")

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: config)

        do {
            let (tempURL, response) = try await session.download(from: sourceURL)
            if let http = response as? HTTPURLResponse, http.statusCode < 200 || http.statusCode >= 300 {
                throw EmbeddingModelProvisionError.downloadFailed("HTTP status \(http.statusCode) downloading \(sourceURL)")
            }
            let tempSize = (try? tempURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard Int64(tempSize) >= minSize else {
                try? FileManager.default.removeItem(at: tempURL)
                throw EmbeddingModelProvisionError.verificationFailed(
                    "Downloaded file is truncated (\(tempSize) bytes < \(minSize) minimum)."
                )
            }
            if FileManager.default.fileExists(atPath: targetURL.path) {
                try? FileManager.default.removeItem(at: targetURL)
            }
            try FileManager.default.moveItem(at: tempURL, to: targetURL)
            RuneWeaverLog.stores.info("EmbeddingModelProvisioner: Successfully downloaded \(label) to \(targetURL.path).")
            return targetURL
        } catch let error as EmbeddingModelProvisionError {
            throw error
        } catch {
            throw EmbeddingModelProvisionError.downloadFailed(
                "Failed to download \(label) from \(sourceURL): \(error.localizedDescription)"
            )
        }
    }
}

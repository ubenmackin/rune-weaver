// Rune Weaver Voice — Audio transcription and text-to-speech processing pipeline.

import Foundation
import os
import RuneWeaverCore
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Failures raised by the voice pipeline.
public enum VoicePipelineError: Error, Sendable, Equatable {
    /// No speech-to-text backend is available in this build.
    case modelUnavailable(String)
    /// Transcription failed.
    case transcriptionFailed(String)
    /// Synthesis failed.
    case synthesisFailed(String)
}

/// Speech-to-text and text-to-speech pipeline.
public actor VoicePipeline {
    /// Supported speech-to-text backend.
    public enum STTProvider: String, Sendable {
        /// Local Whisper model.
        case whisper
    }

    /// Supported text-to-speech backend.
    public enum TTSProvider: String, Sendable {
        /// macOS system speech.
        case system
    }

    /// Speech-to-text backend.
    public let sttProvider: STTProvider
    /// Text-to-speech backend.
    public let ttsProvider: TTSProvider
    /// Whisper CLI executable (resolved from `WHISPER_BINARY` or `PATH`
    /// when nil).
    private let whisperBinary: String?

    /// Creates a voice pipeline with the configured backends.
    public init(
        sttProvider: STTProvider = .whisper,
        ttsProvider: TTSProvider = .system
    ) {
        self.sttProvider = sttProvider
        self.ttsProvider = ttsProvider
        self.whisperBinary = ProcessInfo.processInfo.environment["WHISPER_BINARY"]
    }

    /// Transcribes audio to text via the local Whisper CLI.
    public func transcribe(audio: [UInt8]) async throws -> String {
        guard !audio.isEmpty else {
            throw VoicePipelineError.transcriptionFailed("No audio bytes to transcribe")
        }
        guard let executable = resolveWhisperBinary() else {
            throw VoicePipelineError.modelUnavailable(
                "No Whisper binary found. Install whisper.cpp and set WHISPER_BINARY (Phase 6 setup)."
            )
        }
        let inputURL: URL
        do {
            // Owner-only staging keeps audio private at every instant: a direct
            // atomic write would inherit the process umask and read world-readable.
            inputURL = try stageSecureBytes(Data(audio), filename: "runeweaver-stt-\(UUID().uuidString).wav")
        } catch {
            throw VoicePipelineError.transcriptionFailed("Could not stage audio: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: inputURL) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--no-prints", "--output-txt", "--output-file", "-", inputURL.path]
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        // Use a Sendable-safe buffer so @Sendable readabilityHandler closures
        // can append without capturing mutable vars (Swift 6 strict concurrency).
        let pipeBuffers = PipeBuffers()

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty {
                pipeBuffers.appendOutput(chunk)
            }
        }

        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty {
                pipeBuffers.appendError(chunk)
            }
        }

        // Share the live child with the cancellation handler through a Sendable
        // box so a cancelled turn terminates the exact process instead of
        // hanging on its pipes and leaking the child.
        let processBox = BoundedProcessRunner.ProcessBox()
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { proc in
                    outputPipe.fileHandleForReading.readabilityHandler = nil
                    errorPipe.fileHandleForReading.readabilityHandler = nil

                    let finalOutput = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    let finalError = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    pipeBuffers.appendOutput(finalOutput)
                    pipeBuffers.appendError(finalError)

                    continuation.resume(returning: proc.terminationStatus)
                }
                do {
                    try process.run()
                    processBox.set(process)
                } catch {
                    outputPipe.fileHandleForReading.readabilityHandler = nil
                    errorPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: VoicePipelineError.transcriptionFailed("Could not launch Whisper: \(error.localizedDescription)"))
                }
            }
        } onCancel: {
            processBox.terminateIfRunning()
        }

        // A cancelled turn terminates the child, which resumes non-zero; report
        // cancel as cancellation so callers distinguish abort from failure.
        if Task.isCancelled {
            throw CancellationError()
        }
        let (outputData, errorData) = pipeBuffers.drain()
        guard status == 0 else {
            let detail = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown error"
            throw VoicePipelineError.transcriptionFailed("Whisper failed: \(detail)")
        }

        return String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Synthesizes text to audio via the macOS `say` command.
    public func synthesize(text: String) async throws -> [UInt8] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let inputURL: URL
        do {
            // Owner-only staging keeps the prompt private at every instant.
            inputURL = try stageSecureBytes(Data(trimmed.utf8), filename: "runeweaver-tts-input-\(UUID().uuidString).txt")
        } catch {
            throw VoicePipelineError.synthesisFailed("Could not stage TTS input: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: inputURL) }
        let outputURL: URL
        do {
            // Pre-reserve the child output at 0600 inside the 0700 staging
            // directory so the payload stays unreachable even though the child
            // creates with the process umask.
            outputURL = try reserveSecureOutput(filename: "runeweaver-tts-\(UUID().uuidString).aiff")
        } catch {
            throw VoicePipelineError.synthesisFailed("Could not stage TTS output: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-o", outputURL.path, "-f", inputURL.path]
        // Share the live child with the cancellation handler through a Sendable
        // box so a cancelled turn terminates the exact process instead of
        // hanging the continuation and leaking the child.
        let processBox = BoundedProcessRunner.ProcessBox()
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { proc in
                    continuation.resume(returning: proc.terminationStatus)
                }
                do {
                    try process.run()
                    processBox.set(process)
                } catch {
                    continuation.resume(throwing: VoicePipelineError.synthesisFailed("Could not launch system TTS: \(error.localizedDescription)"))
                }
            }
        } onCancel: {
            processBox.terminateIfRunning()
        }
        // A cancelled turn terminates the child, which resumes non-zero; report
        // cancel as cancellation so callers distinguish abort from failure.
        if Task.isCancelled {
            throw CancellationError()
        }
        // Re-enforce owner-only on the child-produced payload, which inherits
        // the process umask rather than the reserved mode on some systems.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputURL.path)
        guard status == 0 else {
            throw VoicePipelineError.synthesisFailed("System TTS exited with status \(status)")
        }
        let data: Data
        do {
            data = try Data(contentsOf: outputURL)
        } catch {
            throw VoicePipelineError.synthesisFailed("System TTS output unreadable at \(outputURL.path): \(error.localizedDescription)")
        }
        guard !data.isEmpty else {
            throw VoicePipelineError.synthesisFailed("System TTS produced no audio")
        }
        return Array(data)
    }

    // MARK: - Private

    /// Owner-only staging directory for transient voice files.
    /// A dedicated 0700 directory keeps staged audio and prompts unreachable
    /// while child processes write with default umask permissions.
    /// - Returns: Staging directory URL.
    private func secureStagingDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("runeweaver-voice", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        return directory
    }

    /// Stages bytes without a world-readable window.
    /// A direct atomic write inherits the process umask, so creation through
    /// an owner-only file keeps audio and prompts private at every instant.
    /// - Parameters:
    ///   - data: Bytes to stage.
    ///   - filename: Unique leaf name inside the staging directory.
    /// - Returns: Staged file URL.
    private func stageSecureBytes(_ data: Data, filename: String) throws -> URL {
        let directory = try secureStagingDirectory()
        let url = directory.appendingPathComponent(filename)
        // Exclusive reservation keeps staged audio private at every instant:
        // a plain create would inherit the process umask and silently clobber
        // a colliding name, while O_EXCL fails closed on a UUID collision.
        let fd: Int32 = url.path.withCString { cString in
            open(cString, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard fd >= 0 else {
            throw NSError(domain: "RuneWeaverVoice", code: 1, userInfo: [NSLocalizedDescriptionKey: "could not stage temp file"])
        }
        defer { _ = close(fd) }
        // Enforce close-on-exec where the open-time flag is ignored so the
        // staging descriptor never reaches transcription and synthesis children.
        let existingFDFlags = fcntl(fd, F_GETFD)
        if existingFDFlags != -1 {
            _ = fcntl(fd, F_SETFD, existingFDFlags | FD_CLOEXEC)
        } else {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }
        do {
            try data.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress, !rawBuffer.isEmpty else { return }
                var offset = 0
                while offset < rawBuffer.count {
                    let written = write(fd, base.advanced(by: offset), rawBuffer.count - offset)
                    if written < 0 {
                        if errno == EINTR {
                            continue
                        }
                        throw NSError(domain: "RuneWeaverVoice", code: 1, userInfo: [NSLocalizedDescriptionKey: "could not stage temp file"])
                    }
                    if written == 0 {
                        throw NSError(domain: "RuneWeaverVoice", code: 1, userInfo: [NSLocalizedDescriptionKey: "could not stage temp file"])
                    }
                    offset += Int(written)
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        // Re-assert owner-only after the child-agnostic write so a permissive
        // umask at creation can never leave the payload reachable.
        _ = fchmod(fd, mode_t(0o600))
        return url
    }

    /// Reserves an owner-only output slot for a child-produced file.
    /// Pre-creating at 0600 inside the 0700 staging directory keeps the
    /// eventual payload unreachable even though the child writes with the
    /// process umask; permissions are re-enforced after the child exits.
    /// - Parameter filename: Unique leaf name inside the staging directory.
    /// - Returns: Reserved file URL.
    private func reserveSecureOutput(filename: String) throws -> URL {
        try stageSecureBytes(Data(), filename: filename)
    }

    /// Locates the Whisper CLI, preferring `WHISPER_BINARY` then `PATH`.
    /// - Returns: Executable path, or nil when absent.
    private func resolveWhisperBinary() -> String? {
        if let configured = whisperBinary, !configured.isEmpty,
           FileManager.default.isExecutableFile(atPath: configured)
        {
            return configured
        }
        for candidate in ["whisper-cli", "whisper-cpp", "whisper", "main"] {
            if let found = Self.executableInPATH(candidate) {
                return found
            }
        }
        return nil
    }

    /// Searches `PATH` for an executable.
    /// - Parameter name: Binary name.
    /// - Returns: Full path, or nil when not found.
    private static func executableInPATH(_ name: String) -> String? {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin")
            .components(separatedBy: ":")
        for directory in paths {
            let full = (directory as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: full) {
                return full
            }
        }
        return nil
    }
}

// MARK: - Thread-safe pipe buffer

/// A `Sendable`-safe container for accumulating pipe output from `@Sendable`
/// `readabilityHandler` closures (Swift 6 strict concurrency).
private final class PipeBuffers: Sendable {
    private struct State: Sendable {
        var output = Data()
        var error = Data()
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func appendOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        state.withLock { $0.output.append(data) }
    }

    func appendError(_ data: Data) {
        guard !data.isEmpty else { return }
        state.withLock { $0.error.append(data) }
    }

    /// Returns accumulated output and error data, clearing the buffers.
    func drain() -> (output: Data, error: Data) {
        state.withLock { bufferState in
            let out = bufferState.output
            let err = bufferState.error
            bufferState.output = Data()
            bufferState.error = Data()
            return (out, err)
        }
    }
}

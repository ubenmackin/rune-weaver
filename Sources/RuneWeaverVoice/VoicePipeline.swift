import Foundation
import RuneWeaverCore

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
///
/// STT runs locally via Whisper (`whisper.cpp`); TTS uses the system
/// synthesizer (macOS `say`). Push-to-talk input and AirPods/HomePod
/// routing are handled at the client layer.
///
/// Voice is a Phase 6 capability: when no Whisper binary/model is
/// configured, `transcribe(audio:)` throws
/// `VoicePipelineError.modelUnavailable` instead of silently returning
/// an empty string, so callers can surface setup guidance.
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
    /// - Parameters:
    ///   - sttProvider: Speech-to-text backend.
    ///   - ttsProvider: Text-to-speech backend.
    public init(
        sttProvider: STTProvider = .whisper,
        ttsProvider: TTSProvider = .system
    ) {
        self.sttProvider = sttProvider
        self.ttsProvider = ttsProvider
        self.whisperBinary = ProcessInfo.processInfo.environment["WHISPER_BINARY"]
    }

    /// Transcribes audio to text via the local Whisper CLI.
    ///
    /// Writes `audio` (16-bit PCM WAV bytes) to a temporary file and
    /// invokes the Whisper executable. Throws `modelUnavailable` when no
    /// binary can be found, so missing Phase 6 setup is explicit rather
    /// than a silent empty transcript.
    /// - Parameter audio: Raw audio bytes (WAV container).
    /// - Returns: Transcription.
    public func transcribe(audio: [UInt8]) async throws -> String {
        guard !audio.isEmpty else {
            throw VoicePipelineError.transcriptionFailed("No audio bytes to transcribe")
        }
        guard let executable = resolveWhisperBinary() else {
            throw VoicePipelineError.modelUnavailable(
                "No Whisper binary found. Install whisper.cpp and set WHISPER_BINARY (Phase 6 setup)."
            )
        }
        let inputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("runeweaver-stt-\(UUID().uuidString).wav")
        do {
            try Data(audio).write(to: inputURL, options: .atomic)
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
        do {
            try process.run()
        } catch {
            throw VoicePipelineError.transcriptionFailed("Could not launch Whisper: \(error.localizedDescription)")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown error"
            throw VoicePipelineError.transcriptionFailed("Whisper failed: \(detail)")
        }
        return String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Synthesizes text to audio via the macOS `say` command.
    ///
    /// Writes `text` to a temporary file and invokes `say -f <file>`
    /// so that the content is never interpolated into a shell argument
    /// list.  Renders to a temporary AIFF file with `say -o` and
    /// returns the file bytes.  Empty input yields empty audio without
    /// invoking the synthesizer.
    /// - Parameter text: Text to speak.
    /// - Returns: Raw audio bytes (AIFF container).
    public func synthesize(text: String) async throws -> [UInt8] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let inputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("runeweaver-tts-input-\(UUID().uuidString).txt")
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("runeweaver-tts-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: inputURL) }
        defer { try? FileManager.default.removeItem(at: outputURL) }
        try trimmed.write(to: inputURL, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-o", outputURL.path, "-f", inputURL.path]
        do {
            try process.run()
        } catch {
            throw VoicePipelineError.synthesisFailed("Could not launch system TTS: \(error.localizedDescription)")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw VoicePipelineError.synthesisFailed("System TTS exited with status \(process.terminationStatus)")
        }
        guard let data = try? Data(contentsOf: outputURL), !data.isEmpty else {
            throw VoicePipelineError.synthesisFailed("System TTS produced no audio")
        }
        return Array(data)
    }

    // MARK: - Private

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

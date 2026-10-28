// Rune Weaver Voice Tests — Voice pipeline transcription and initialization tests.

import Foundation
@testable import RuneWeaverVoice
import Testing

/// Serializes the suite because transcription tests install a process-global
/// `WHISPER_BINARY` environment variable.
@Suite("Voice Pipeline", .serialized)
struct VoicePipelineTests {
    @Test
    func `Pipeline initializes with defaults`() {
        _ = VoicePipeline()
    }

    @Test
    func `Transcribe returns the stub-written transcript`() async throws {
        let stub = try Self.makeStubExecutable(script: """
        #!/bin/sh
        while [ $# -gt 0 ]; do
            if [ "$1" = "--output-file" ]; then
                echo "hello world" > "$2.txt"
            fi
            shift
        done
        exit 0
        """)
        defer { try? FileManager.default.removeItem(at: stub.deletingLastPathComponent()) }
        try await Self.withWhisperBinary(stub.path) {
            let pipeline = VoicePipeline()
            let transcript = try await pipeline.transcribe(audio: Self.sampleAudio)
            #expect(transcript == "hello world")
        }
    }

    @Test
    func `Transcribe fails when a zero-exit stub writes no transcript`() async throws {
        let stub = try Self.makeStubExecutable(script: """
        #!/bin/sh
        exit 0
        """)
        defer { try? FileManager.default.removeItem(at: stub.deletingLastPathComponent()) }
        try await Self.withWhisperBinary(stub.path) {
            let pipeline = VoicePipeline()
            do {
                _ = try await pipeline.transcribe(audio: Self.sampleAudio)
                Issue.record("Missing transcript should throw transcriptionFailed.")
            } catch let error as VoicePipelineError {
                guard case let .transcriptionFailed(message) = error else {
                    Issue.record("Expected transcriptionFailed, got \(error).")
                    return
                }
                #expect(message.contains("no transcript"))
            } catch {
                Issue.record("Unexpected error: \(error).")
            }
        }
    }

    @Test
    func `Transcribe failure carries the nonzero stub stderr detail`() async throws {
        let stub = try Self.makeStubExecutable(script: """
        #!/bin/sh
        echo "stub whisper: model load failed" >&2
        exit 3
        """)
        defer { try? FileManager.default.removeItem(at: stub.deletingLastPathComponent()) }
        try await Self.withWhisperBinary(stub.path) {
            let pipeline = VoicePipeline()
            do {
                _ = try await pipeline.transcribe(audio: Self.sampleAudio)
                Issue.record("Nonzero exit should throw transcriptionFailed.")
            } catch let error as VoicePipelineError {
                guard case let .transcriptionFailed(message) = error else {
                    Issue.record("Expected transcriptionFailed, got \(error).")
                    return
                }
                #expect(message.contains("model load failed"))
            } catch {
                Issue.record("Unexpected error: \(error).")
            }
        }
    }

    // MARK: - Helpers

    /// Opaque non-empty byte payload; the stub never inspects the staged audio.
    private static let sampleAudio: [UInt8] = Array("stub-audio".utf8)

    /// Writes a shell stub executable into a unique temporary directory so
    /// concurrent runs never collide.
    private static func makeStubExecutable(script: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("runeweaver-voice-stub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("stub-whisper.sh")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// Runs `body` with `WHISPER_BINARY` pointing at the stub path, restoring
    /// any prior value afterwards. The pipeline resolves the binary at init, so
    /// the variable must be installed before construction.
    private static func withWhisperBinary(
        _ path: String,
        _ body: @Sendable () async throws -> Void
    ) async throws {
        let saved: String? = "WHISPER_BINARY".withCString { keyPtr in
            getenv(keyPtr).map { String(cString: $0) }
        }
        setenv("WHISPER_BINARY", path, 1)
        defer {
            if let saved {
                setenv("WHISPER_BINARY", saved, 1)
            } else {
                unsetenv("WHISPER_BINARY")
            }
        }
        try await body()
    }
}

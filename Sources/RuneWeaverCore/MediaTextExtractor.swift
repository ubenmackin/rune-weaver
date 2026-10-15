// Rune Weaver Core — On-device media text extraction (Vision OCR & Speech recognition).

import Foundation
import os

#if canImport(Vision)
    import Vision
#endif

#if canImport(Speech)
    import Speech
#endif

#if canImport(AVFoundation)
    import AVFoundation
#endif

#if canImport(CoreGraphics)
    import CoreGraphics
#endif

public typealias MediaImageOCRHook = @Sendable (Data) throws -> String
public typealias MediaAudioTranscriptionHook = @Sendable (URL) async throws -> String

private let customImageOCRLock = OSAllocatedUnfairLock(initialState: MediaImageOCRHook?.none)
private let customAudioTranscriptionLock = OSAllocatedUnfairLock(initialState: MediaAudioTranscriptionHook?.none)

/// Extracts on-device text from images, audio, and video files using native Apple frameworks.
public struct MediaTextExtractor: Sendable {
    @TaskLocal public static var currentImageOCR: MediaImageOCRHook?
    @TaskLocal public static var currentAudioTranscription: MediaAudioTranscriptionHook?

    /// Scoped audio transcription hook for deterministic asynchronous testing without global state mutation.
    public static func withAudioTranscription<T>(
        _ hook: MediaAudioTranscriptionHook?,
        operation: () async throws -> T
    ) async rethrows -> T {
        try await $currentAudioTranscription.withValue(hook) {
            try await operation()
        }
    }

    /// Scoped image OCR hook for deterministic testing without global state mutation.
    public static func withImageOCR<T>(
        _ hook: MediaImageOCRHook?,
        operation: () async throws -> T
    ) async rethrows -> T {
        try await $currentImageOCR.withValue(hook) {
            try await operation()
        }
    }

    /// Scoped synchronous image OCR hook for deterministic testing without global state mutation.
    public static func withImageOCR<T>(
        _ hook: MediaImageOCRHook?,
        operation: () throws -> T
    ) rethrows -> T {
        try $currentImageOCR.withValue(hook) {
            try operation()
        }
    }

    /// Injected image OCR hook for deterministic unit testing.
    public static var customImageOCR: MediaImageOCRHook? {
        get {
            if let current = currentImageOCR {
                return current
            }
            return customImageOCRLock.withLock { $0 }
        }
        set { customImageOCRLock.withLock { $0 = newValue } }
    }

    /// Injected audio transcription hook for deterministic unit testing.
    public static var customAudioTranscription: MediaAudioTranscriptionHook? {
        get {
            if let current = currentAudioTranscription {
                return current
            }
            return customAudioTranscriptionLock.withLock { $0 }
        }
        set { customAudioTranscriptionLock.withLock { $0 = newValue } }
    }

    /// Supported image file extensions.
    public static let supportedImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "webp", "gif", "bmp", "svg"
    ]

    /// Supported audio file extensions.
    public static let supportedAudioExtensions: Set<String> = [
        "mp3", "m4a", "wav", "aac", "flac", "caf", "aiff"
    ]

    /// Supported video file extensions.
    public static let supportedVideoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "mkv", "avi", "webm"
    ]

    /// Checks if a filename has a recognized image extension.
    public static func isImageFile(fileName: String) -> Bool {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return supportedImageExtensions.contains(ext)
    }

    /// Checks if a filename has a recognized audio or video extension.
    public static func isAudioOrVideoFile(fileName: String) -> Bool {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return supportedAudioExtensions.contains(ext) || supportedVideoExtensions.contains(ext)
    }

    /// Performs on-device text recognition (OCR) synchronously on image data using Apple Vision.
    public static func recognizeTextSync(in imageData: Data) -> String {
        if let custom = customImageOCR {
            return (try? custom(imageData)) ?? ""
        }

        #if canImport(Vision)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(data: imageData, options: [:])
            do {
                try handler.perform([request])
                guard let observations = request.results else { return "" }
                var recognizedLines: [String] = []
                for observation in observations {
                    if let candidate = observation.topCandidates(1).first {
                        let string = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !string.isEmpty {
                            recognizedLines.append(string)
                        }
                    }
                }
                return recognizedLines.joined(separator: "\n")
            } catch {
                return ""
            }
        #else
            return ""
        #endif
    }

    /// Performs on-device text recognition (OCR) on image data using Apple Vision.
    /// - Parameter data: Raw image bytes (PNG, JPEG, HEIC, TIFF, etc.).
    /// - Returns: Recognized text joined by line breaks, or empty string if no text found.
    public static func recognizeText(in imageData: Data) async throws -> String {
        if let custom = customImageOCR {
            return try custom(imageData)
        }

        #if canImport(Vision)
            return try await Task.detached {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true

                let handler = VNImageRequestHandler(data: imageData, options: [:])
                try handler.perform([request])

                guard let observations = request.results else {
                    return ""
                }

                var recognizedLines: [String] = []
                for observation in observations {
                    if let candidate = observation.topCandidates(1).first {
                        let string = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !string.isEmpty {
                            recognizedLines.append(string)
                        }
                    }
                }
                return recognizedLines.joined(separator: "\n")
            }.value
        #else
            return ""
        #endif
    }

    /// Transcribes speech from an audio or video file URL using Apple Speech.framework.
    ///
    /// Speech authorization is checked without prompting so background indexing
    /// never surfaces a consent dialog; a non-authorized state degrades to an
    /// empty transcript. Recognition resumes exactly once: errors degrade to an
    /// empty string, a final result returns its transcript, and a callback with
    /// neither result nor error terminates instead of hanging the indexer.
    /// Cancellation cooperatively stops the underlying recognition task.
    /// - Parameter fileURL: Local URL to the audio/video file.
    /// - Returns: Transcribed text, or empty string if unavailable.
    public static func transcribeAudio(fileURL: URL) async throws -> String {
        if let custom = customAudioTranscription {
            return try await custom(fileURL)
        }

        #if canImport(Speech)
            guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
                return ""
            }
            try Task.checkCancellation()

            let coordinator = AudioTranscriptionCoordinator()
            return try await withTaskCancellationHandler {
                try await coordinator.start(fileURL: fileURL)
            } onCancel: {
                Task {
                    await coordinator.cancel()
                }
            }
        #else
            return ""
        #endif
    }
}

#if canImport(Speech)
    private actor AudioTranscriptionCoordinator {
        private var recognitionTask: SFSpeechRecognitionTask?
        private var isCancelled = false

        func start(fileURL: URL) async throws -> String {
            guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
                return ""
            }
            try Task.checkCancellation()

            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                let didResume = OSAllocatedUnfairLock(initialState: false)
                func resumeOnceReturning(_ value: String) {
                    let alreadyResumed = didResume.withLock { resumed in
                        if resumed {
                            return true
                        }
                        resumed = true
                        return false
                    }
                    guard !alreadyResumed else { return }
                    continuation.resume(returning: value)
                }
                func resumeOnceThrowing(_ error: Error) {
                    let alreadyResumed = didResume.withLock { resumed in
                        if resumed {
                            return true
                        }
                        resumed = true
                        return false
                    }
                    guard !alreadyResumed else { return }
                    continuation.resume(throwing: error)
                }
                if Task.isCancelled {
                    resumeOnceThrowing(CancellationError())
                    return
                }
                let request = SFSpeechURLRecognitionRequest(url: fileURL)
                request.shouldReportPartialResults = false
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if Task.isCancelled {
                        resumeOnceThrowing(CancellationError())
                        return
                    }
                    if let error {
                        // Failures degrade to empty string rather than crashing the indexer
                        RuneWeaverLog.stores.debug("MediaTextExtractor: audio transcription failed: \(error.localizedDescription)")
                        resumeOnceReturning("")
                        return
                    }
                    if let result {
                        if result.isFinal {
                            let transcript = result.bestTranscription.formattedString
                            resumeOnceReturning(transcript)
                        }
                        return
                    }
                    resumeOnceReturning("")
                }
                self.recognitionTask = task
                if self.isCancelled || Task.isCancelled {
                    task.cancel()
                }
            }
        }

        func cancel() {
            isCancelled = true
            recognitionTask?.cancel()
        }
    }
#endif

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
        "png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "webp"
    ]

    /// Supported audio file extensions.
    public static let supportedAudioExtensions: Set<String> = [
        "mp3", "m4a", "wav", "aac", "flac"
    ]

    /// Supported video file extensions.
    public static let supportedVideoExtensions: Set<String> = [
        "mp4", "mov", "m4v"
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

    /// Checks if a filename has a recognized video container extension.
    public static func isVideoFile(fileName: String) -> Bool {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return supportedVideoExtensions.contains(ext)
    }

    #if canImport(Vision)
        /// Bounds Vision OCR to 2 concurrent passes so the Neural Engine stays fair.
        private actor VisionOCRThrottle {
            private let limit: Int
            private var inFlight: Int = 0
            private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

            init(limit: Int = 2) {
                self.limit = max(1, limit)
            }

            func withPermit<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
                try Task.checkCancellation()
                try await acquire()
                defer { release() }
                try Task.checkCancellation()
                return try await operation()
            }

            private func acquire() async throws {
                try Task.checkCancellation()
                if inFlight < limit {
                    inFlight += 1
                    return
                }
                let id = UUID()
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        if Task.isCancelled {
                            continuation.resume(throwing: CancellationError())
                            return
                        }
                        waiters.append((id: id, continuation: continuation))
                    }
                } onCancel: {
                    Task { [self, id] in await self.cancelWaiter(id: id) }
                }
            }

            private func cancelWaiter(id: UUID) {
                guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
                let waiter = waiters.remove(at: index)
                waiter.continuation.resume(throwing: CancellationError())
            }

            private func release() {
                if !waiters.isEmpty {
                    let next = waiters.removeFirst()
                    next.continuation.resume(returning: ())
                } else {
                    inFlight -= 1
                }
            }
        }

        private static let visionDispatchQueue = DispatchQueue(
            label: "com.runeweaver.vision.ocr",
            qos: .userInitiated,
            attributes: .concurrent
        )
        private static let ocrThrottle = VisionOCRThrottle(limit: 2)

        /// Performs Apple Vision text recognition synchronously on a private or caller queue.
        private static func performVisionOCR(imageData: Data) throws -> String {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(data: imageData, options: [:])
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
        }
    #endif

    /// Performs on-device text recognition (OCR) synchronously on image data using Apple Vision.
    public static func recognizeTextSync(in imageData: Data) -> String {
        if let custom = customImageOCR {
            return (try? custom(imageData)) ?? ""
        }

        #if canImport(Vision)
            do {
                return try performVisionOCR(imageData: imageData)
            } catch {
                return ""
            }
        #else
            return ""
        #endif
    }

    /// Performs Vision OCR via dedicated queue throttled to 2, suspending without blocking.
    /// - Parameter data: Raw image bytes (PNG, JPEG, HEIC, TIFF, etc.).
    /// - Returns: Recognized text joined by line breaks, or empty string if no text found.
    public static func recognizeText(in imageData: Data) async throws -> String {
        if let custom = customImageOCR {
            return try custom(imageData)
        }

        #if canImport(Vision)
            return try await ocrThrottle.withPermit {
                try await withCheckedThrowingContinuation { continuation in
                    visionDispatchQueue.async {
                        do {
                            let text = try performVisionOCR(imageData: imageData)
                            continuation.resume(returning: text)
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }
        #else
            return ""
        #endif
    }

    /// Extracts the audio track from a video container into a temporary `.m4a` file.
    /// - Parameter videoURL: Local URL to the video file.
    /// - Returns: Temporary `.m4a` file URL when an audio track was exported, or `nil`.
    public static func extractAudioTrack(from videoURL: URL) async -> URL? {
        #if canImport(AVFoundation)
            let asset = AVURLAsset(url: videoURL)
            guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty, let session = AVAssetExportSession(
                asset: asset,
                presetName: AVAssetExportPresetAppleM4A
            ) else {
                return nil
            }
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("rw-speech-\(UUID().uuidString).m4a")
            do {
                try await session.export(to: tempURL, as: .m4a)
                return tempURL
            } catch {
                try? FileManager.default.removeItem(at: tempURL)
                return nil
            }
        #else
            return nil
        #endif
    }

    /// Checks whether a local media file contains at least one playable audio track.
    /// - Parameter fileURL: Local URL to inspect.
    /// - Returns: `true` when at least one `.audio` track can be loaded by `AVFoundation`.
    public static func hasAudioTrack(fileURL: URL) async -> Bool {
        #if canImport(AVFoundation)
            let asset = AVURLAsset(url: fileURL)
            guard let tracks = try? await asset.loadTracks(withMediaType: .audio) else {
                return false
            }
            return !tracks.isEmpty
        #else
            return false
        #endif
    }

    /// Transcribes speech from an audio or video file URL using Apple Speech.framework.
    public static func transcribeAudio(fileURL: URL) async throws -> String {
        if let custom = customAudioTranscription {
            return try await custom(fileURL)
        }

        #if canImport(Speech)
            try Task.checkCancellation()

            let ext = fileURL.pathExtension.lowercased()
            var targetURL = fileURL
            var cleanupURL: URL?
            if supportedVideoExtensions.contains(ext) {
                guard let extracted = await extractAudioTrack(from: fileURL) else {
                    return ""
                }
                targetURL = extracted
                cleanupURL = extracted
            }
            defer {
                if let cleanupURL {
                    try? FileManager.default.removeItem(at: cleanupURL)
                }
            }
            try Task.checkCancellation()

            // Guard against 0-track audio/container files before passing to SFSpeechURLRecognitionRequest,
            // which otherwise throws an uncaught Objective-C NSInvalidArgumentException in AVAssetReaderAudioMixOutput.
            guard await hasAudioTrack(fileURL: targetURL), SFSpeechRecognizer.authorizationStatus() == .authorized else {
                return ""
            }

            let coordinator = AudioTranscriptionCoordinator()
            return try await withTaskCancellationHandler {
                try await coordinator.start(fileURL: targetURL)
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

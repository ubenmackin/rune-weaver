// Rune Weaver Core Tests — Tests for MediaTextExtractor and document integration.

import Foundation
@testable import RuneWeaverCore
import Testing

struct MediaTextExtractorTests {
    @Test
    func `MediaTextExtractor identifies image and audio extensions accurately`() {
        #expect(MediaTextExtractor.isImageFile(fileName: "photo.jpg"))
        #expect(MediaTextExtractor.isImageFile(fileName: "scan.png"))
        #expect(MediaTextExtractor.isImageFile(fileName: "receipt.HEIC"))
        #expect(MediaTextExtractor.isImageFile(fileName: "animation.gif"))
        #expect(!MediaTextExtractor.isImageFile(fileName: "document.pdf"))

        #expect(MediaTextExtractor.isAudioOrVideoFile(fileName: "memo.m4a"))
        #expect(MediaTextExtractor.isAudioOrVideoFile(fileName: "recording.mp3"))
        #expect(MediaTextExtractor.isAudioOrVideoFile(fileName: "clip.mp4"))
        #expect(!MediaTextExtractor.isAudioOrVideoFile(fileName: "notes.txt"))
    }

    @Test
    func `DocumentTextExtractor extracts image with OCR text`() {
        let extractor = DocumentTextExtractor()
        let fakeImageData = "fake-image-bytes".data(using: .utf8)!

        let result = extractor.extract(data: fakeImageData, fileName: "test.png", contentType: "image/png")
        #expect(result.format == .image)
        #expect(result.status == .metadataOnly || result.status == .extracted || result.status == .partial)
    }

    @Test
    func `DocumentTextExtractor extracts audio as metadataOnly for multimodal processing`() {
        let extractor = DocumentTextExtractor()
        let fakeAudioData = "fake-audio-bytes".data(using: .utf8)!

        let result = extractor.extract(data: fakeAudioData, fileName: "test.m4a", contentType: "audio/x-m4a")
        #expect(result.format == .audio)
        #expect(result.status == .metadataOnly)
        #expect(result.reason?.contains("speech transcription requires on-disk file URL") == true)
    }

    @Test
    func `Custom OCR hook returns simulated text`() async throws {
        try await MediaTextExtractor.withImageOCR({ _ in
            "Simulated Invoice Total: $125.00"
        }) {
            let text = try await MediaTextExtractor.recognizeText(in: Data([0x01, 0x02]))
            #expect(text == "Simulated Invoice Total: $125.00")
        }
    }

    @Test
    func `Custom audio transcription hook returns simulated speech`() async throws {
        try await MediaTextExtractor.withAudioTranscription({ _ in
            "Simulated audio transcription text"
        }) {
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test-audio.m4a")
            try "audio-bytes".write(to: tempURL, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: tempURL) }

            let extractor = DocumentTextExtractor()
            let result = await extractor.extract(fileURL: tempURL)
            #expect(result.format == .audio)
            #expect(result.status == .extracted)
            #expect(result.text.contains("Simulated audio transcription text"))
        }
    }
}

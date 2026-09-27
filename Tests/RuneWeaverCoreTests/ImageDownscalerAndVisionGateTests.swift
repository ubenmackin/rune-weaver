// Rune Weaver Core Tests — Image downscaling, budget capping, and VisionGate tests.

import Foundation
@testable import RuneWeaverCore
import Testing

@Suite("Image Downscaler and VisionGate")
struct ImageDownscalerAndVisionGateTests {
    @Test
    func `Downscaler rejects non-image data cleanly`() {
        let invalidData = Data("hello not an image".utf8)
        let result = ImageDownscaler.downscaledDataURL(for: invalidData)
        #expect(result == nil)
    }

    @Test
    func `VisionGate strips data URLs when model does not support vision`() {
        let original = "Here is an image: data:image/jpeg;base64,/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA= and some trailing text."
        let stripped = VisionGate.strippedContent(original)
        #expect(stripped.contains(VisionGate.strippedPlaceholder))
        #expect(!stripped.contains("data:image/jpeg;base64"))
        #expect(stripped.contains("and some trailing text."))
    }

    @Test
    func `VisionGate strips imageDataBase64 JSON field for text-only model`() {
        let json = #"{"account":"work","id":"123","filename":"chart.png","imageDataBase64":"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==","sizeBytes":100}"#
        let stripped = VisionGate.strippedContent(json)
        #expect(!stripped.contains("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="))
        #expect(stripped.contains("\"imageDataBase64\": \"\(VisionGate.strippedPlaceholder)\""))
    }

    @Test
    func `VisionGate stripMessages preserves messages when supportsVision is true`() {
        let msg = Message(
            role: .assistant,
            content: "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        )
        let messages = [msg]
        let preserved = VisionGate.stripMessages(messages, supportsVision: true)
        #expect(preserved[0].content == msg.content)

        let stripped = VisionGate.stripMessages(messages, supportsVision: false)
        #expect(stripped[0].content.contains(VisionGate.strippedPlaceholder))
    }

    @Test
    func `VisionGate extractDataURLs extracts JSON screenshotDataURL with escaped slashes`() {
        let json = #"{"displayIndex":0,"scaledWidth":1280,"screenshotDataURL":"data:image\/jpeg;base64,\/9j\/4AAQSkZJRg==","screenshotHash":"hash123"}"#
        let extracted = VisionGate.extractDataURLs(json)
        #expect(extracted.dataURLs.count == 1)
        #expect(extracted.dataURLs[0] == "data:image/jpeg;base64,/9j/4AAQSkZJRg==")
        #expect(extracted.cleanedText.contains("\"screenshotDataURL\": \"[image attached]\""))
        #expect(!extracted.cleanedText.contains("/9j/4AAQSkZJRg=="))
        #expect(extracted.cleanedText.contains("\"screenshotHash\":\"hash123\""))
    }

    @Test
    func `VisionGate extractDataURLs extracts inline data URLs from user prompt`() {
        let text = "Here is the screenshot:\ndata:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==\nPlease analyze it."
        let extracted = VisionGate.extractDataURLs(text)
        #expect(extracted.dataURLs.count == 1)
        #expect(extracted.dataURLs[0].hasPrefix("data:image/png;base64,iVBOR"))
        #expect(!extracted.cleanedText.contains("data:image/png;base64"))
        #expect(extracted.cleanedText.contains("Please analyze it."))
    }

    @Test
    func `VisionGate extractDataURLs returns empty array when no images present`() {
        let text = "Just a regular text message without any image."
        let extracted = VisionGate.extractDataURLs(text)
        #expect(extracted.dataURLs.isEmpty)
        #expect(extracted.cleanedText == text)
    }

    @Test
    func `VisionGate handles large payloads exceeding regex limits without failure`() {
        let largeBase64 = String(repeating: "A", count: 250_000)
        let json = #"{"displayIndex":0,"scaledWidth":1280,"screenshotDataURL":"data:image\/jpeg;base64,\/9j\/\#(largeBase64)==","screenshotHash":"hash123"}"#
        let extracted = VisionGate.extractDataURLs(json)
        #expect(extracted.dataURLs.count == 1)
        #expect(extracted.dataURLs[0].hasPrefix("data:image/jpeg;base64,/9j/AAAA"))
        #expect(extracted.dataURLs[0].hasSuffix("=="))
        #expect(extracted.cleanedText.contains("\"screenshotDataURL\": \"[image attached]\""))
        #expect(!extracted.cleanedText.contains("AAAAAA"))

        let stripped = VisionGate.strippedContent(json)
        #expect(stripped.contains("\"screenshotDataURL\": \"\(VisionGate.strippedPlaceholder)\""))
        #expect(!stripped.contains("AAAAAA"))
    }
}

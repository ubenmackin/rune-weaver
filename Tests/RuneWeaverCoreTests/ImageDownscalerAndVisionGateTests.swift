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
}

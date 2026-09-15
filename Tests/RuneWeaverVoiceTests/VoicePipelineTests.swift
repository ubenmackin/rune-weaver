// Rune Weaver Voice Tests — Voice pipeline initialization tests.

@testable import RuneWeaverVoice
import Testing

@Suite("Voice Pipeline")
struct VoicePipelineTests {
    @Test
    func `Pipeline initializes with defaults`() {
        _ = VoicePipeline()
    }
}

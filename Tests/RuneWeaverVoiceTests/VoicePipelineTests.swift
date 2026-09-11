@testable import RuneWeaverVoice
import Testing

@Suite("Voice Pipeline")
struct VoicePipelineTests {
    @Test
    func `Pipeline initializes with defaults`() {
        _ = VoicePipeline()
    }
}

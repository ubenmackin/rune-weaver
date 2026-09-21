// Rune Weaver Core Tests — Config Media (Sonarr & Radarr) tests.
import Foundation
@testable import RuneWeaverCore
import Testing

@Suite("Config Media")
struct ConfigMediaTests {
    @Test
    func `Absent media section defaults to standard values`() throws {
        let text = """
        [llm]
        default_provider = "mlx"

        [llm.providers.mlx]
        enabled = true
        model = "gemma-4-9b"
        server_url = "http://localhost:8080"
        """
        let root = try TOMLParser.parse(text)
        let config = try RuneWeaverConfig(decoding: root)
        #expect(config.media.sonarr.enabled == true)
        #expect(config.media.sonarr.url == nil)
        #expect(config.media.sonarr.apiKeyEnv == "SONARR_API_KEY")
        #expect(config.media.radarr.enabled == true)
        #expect(config.media.radarr.url == nil)
        #expect(config.media.radarr.apiKeyEnv == "RADARR_API_KEY")
        try config.validate()
    }

    @Test
    func `Explicit media section decodes and validates`() throws {
        let text = """
        [llm]
        default_provider = "mlx"

        [llm.providers.mlx]
        enabled = true
        model = "gemma-4-9b"
        server_url = "http://localhost:8080"

        [media.sonarr]
        enabled = true
        url = "http://192.168.1.100:8989"
        api_key_env = "MY_SONARR_KEY"
        default_quality_profile = "HD-1080p"
        default_root_folder = "/data/media/tv"

        [media.radarr]
        enabled = false
        url = "https://movies.local:7878"
        api_key_env = "MY_RADARR_KEY"
        default_quality_profile = "Ultra-HD"
        default_root_folder = "/data/media/movies"
        """
        let root = try TOMLParser.parse(text)
        let config = try RuneWeaverConfig(decoding: root)
        #expect(config.media.sonarr.enabled == true)
        #expect(config.media.sonarr.url == "http://192.168.1.100:8989")
        #expect(config.media.sonarr.apiKeyEnv == "MY_SONARR_KEY")
        #expect(config.media.sonarr.defaultQualityProfile == "HD-1080p")
        #expect(config.media.sonarr.defaultRootFolder == "/data/media/tv")

        #expect(config.media.radarr.enabled == false)
        #expect(config.media.radarr.url == "https://movies.local:7878")
        #expect(config.media.radarr.apiKeyEnv == "MY_RADARR_KEY")
        #expect(config.media.radarr.defaultQualityProfile == "Ultra-HD")
        #expect(config.media.radarr.defaultRootFolder == "/data/media/movies")
        try config.validate()

        // Test roundtrip serialization
        let rendered = config.renderTOML()
        #expect(rendered.contains("[media.sonarr]"))
        #expect(rendered.contains("http://192.168.1.100:8989"))
        #expect(rendered.contains("[media.radarr]"))
        #expect(rendered.contains("https://movies.local:7878"))

        let roundtripRoot = try TOMLParser.parse(rendered)
        let roundtripConfig = try RuneWeaverConfig(decoding: roundtripRoot)
        #expect(roundtripConfig.media == config.media)
    }

    @Test
    func `Invalid media url fails validation`() throws {
        let text = """
        [llm]
        default_provider = "mlx"

        [llm.providers.mlx]
        enabled = true
        model = "gemma-4-9b"
        server_url = "http://localhost:8080"

        [media.sonarr]
        enabled = true
        url = "not-a-valid-url"
        """
        let root = try TOMLParser.parse(text)
        let config = try RuneWeaverConfig(decoding: root)
        #expect(throws: ConfigError.self) {
            try config.validate()
        }
    }
}

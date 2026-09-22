// Rune Weaver Core Tests — Config Desktop tests.
import Foundation
@testable import RuneWeaverCore
import Testing

@Suite("Config Desktop")
struct ConfigDesktopTests {
    @Test
    func `Absent desktop section defaults to standard values`() throws {
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
        // Fail-closed stock install: both allow boundaries off, so a fresh
        // config never exposes approval-free screen capture by omission.
        #expect(config.desktop.screenCaptureEnabled == false)
        #expect(config.desktop.controlEnabled == false)
        #expect(config.desktop.maxImageDimension == 1280)
        #expect(config.desktop.jpegQuality == 0.75)
        #expect(config.desktop.blockedApps.contains("Terminal"))
        #expect(config.desktop.blockedApps.contains("1Password"))
        #expect(config.desktop.blockedApps.contains("System Settings"))
        try config.validate()
    }

    @Test
    func `Explicit desktop section decodes per-tool toggles`() throws {
        let text = """
        [llm]
        default_provider = "mlx"

        [llm.providers.mlx]
        enabled = true
        model = "gemma-4-9b"
        server_url = "http://localhost:8080"

        [desktop]
        screen_capture_enabled = true
        control_enabled = true
        max_image_dimension = 1920
        jpeg_quality = 0.85
        blocked_apps = ["Terminal", "SecretApp"]
        """
        let root = try TOMLParser.parse(text)
        let config = try RuneWeaverConfig(decoding: root)
        #expect(config.desktop.screenCaptureEnabled == true)
        #expect(config.desktop.controlEnabled == true)
        #expect(config.desktop.maxImageDimension == 1920)
        #expect(config.desktop.jpegQuality == 0.85)
        #expect(config.desktop.blockedApps == ["Terminal", "SecretApp"])
        try config.validate()
    }

    @Test
    func `Legacy enabled master key ANDs into both toggles`() throws {
        // Older files carried a `[desktop]` `enabled` master switch; the
        // schema no longer writes it but still honors it at the TOML layer
        // so upgrades behave: `enabled = false` stays fail-closed even when
        // per-tool toggles say true, while `enabled = true` leaves each
        // decoded per-tool toggle as written.
        let base = """
        [llm]
        default_provider = "mlx"

        [llm.providers.mlx]
        enabled = true
        model = "gemma-4-9b"
        server_url = "http://localhost:8080"
        """

        let closed = base + """

        [desktop]
        enabled = false
        screen_capture_enabled = true
        control_enabled = true
        """
        let closedConfig = try RuneWeaverConfig(decoding: TOMLParser.parse(closed))
        #expect(closedConfig.desktop.screenCaptureEnabled == false)
        #expect(closedConfig.desktop.controlEnabled == false)
        try closedConfig.validate()

        let open = base + """

        [desktop]
        enabled = true
        screen_capture_enabled = true
        control_enabled = false
        """
        let openConfig = try RuneWeaverConfig(decoding: TOMLParser.parse(open))
        #expect(openConfig.desktop.screenCaptureEnabled == true)
        #expect(openConfig.desktop.controlEnabled == false)
        try openConfig.validate()
    }

    @Test
    func `Invalid max_image_dimension fails validation`() throws {
        var config = RuneWeaverConfig.default
        config.desktop.maxImageDimension = 100 // below minimum 256
        #expect(throws: ConfigError.self) {
            try config.validate()
        }

        config.desktop.maxImageDimension = 5000 // above maximum 3840
        #expect(throws: ConfigError.self) {
            try config.validate()
        }
    }

    @Test
    func `Invalid jpeg_quality fails validation`() throws {
        var config = RuneWeaverConfig.default
        config.desktop.jpegQuality = 0.05 // below minimum 0.1
        #expect(throws: ConfigError.self) {
            try config.validate()
        }

        config.desktop.jpegQuality = 1.5 // above maximum 1.0
        #expect(throws: ConfigError.self) {
            try config.validate()
        }
    }

    @Test
    func `Desktop section round-trips through TOML serialization without a master key`() throws {
        var config = RuneWeaverConfig.default
        config.desktop.screenCaptureEnabled = true
        config.desktop.controlEnabled = true
        config.desktop.maxImageDimension = 1600
        config.desktop.jpegQuality = 0.8
        config.desktop.blockedApps = ["Terminal", "Finder"]

        let toml = config.renderTOML()
        #expect(toml.contains("[desktop]"))
        #expect(toml.contains("screen_capture_enabled = true"))
        #expect(toml.contains("control_enabled = true"))
        #expect(toml.contains("max_image_dimension = 1600"))

        let parsed = try TOMLParser.parse(toml)
        let decoded = try RuneWeaverConfig(decoding: parsed)
        #expect(decoded.desktop.screenCaptureEnabled == true)
        #expect(decoded.desktop.controlEnabled == true)
        #expect(decoded.desktop.maxImageDimension == 1600)
        #expect(decoded.desktop.jpegQuality == 0.8)
        #expect(decoded.desktop.blockedApps == ["Terminal", "Finder"])
    }
}

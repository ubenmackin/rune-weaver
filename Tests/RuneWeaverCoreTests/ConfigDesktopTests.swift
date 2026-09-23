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
        // Stock install carries only capture knobs; enablement flows through
        // the tool-state toggle so a fresh config never implies live capture.
        #expect(config.desktop.maxImageDimension == 1280)
        #expect(config.desktop.jpegQuality == 0.75)
        #expect(config.desktop.blockedApps.contains("Terminal"))
        #expect(config.desktop.blockedApps.contains("1Password"))
        #expect(config.desktop.blockedApps.contains("System Settings"))
        try config.validate()
    }

    @Test
    func `Explicit desktop section decodes capture knobs`() throws {
        let text = """
        [llm]
        default_provider = "mlx"

        [llm.providers.mlx]
        enabled = true
        model = "gemma-4-9b"
        server_url = "http://localhost:8080"

        [desktop]
        max_image_dimension = 1920
        jpeg_quality = 0.85
        blocked_apps = ["Terminal", "SecretApp"]
        """
        let root = try TOMLParser.parse(text)
        let config = try RuneWeaverConfig(decoding: root)
        #expect(config.desktop.maxImageDimension == 1920)
        #expect(config.desktop.jpegQuality == 0.85)
        #expect(config.desktop.blockedApps == ["Terminal", "SecretApp"])
        try config.validate()
    }

    @Test
    func `Retired allow toggles and legacy master key are silently ignored`() throws {
        // Older files carried `screen_capture_enabled`, `control_enabled`,
        // and a master `enabled` key. The single-gate contract ignores them
        // so upgrades load without migration and enablement stays with the
        // tool-state toggle.
        let text = """
        [llm]
        default_provider = "mlx"

        [llm.providers.mlx]
        enabled = true
        model = "gemma-4-9b"
        server_url = "http://localhost:8080"

        [desktop]
        enabled = false
        screen_capture_enabled = true
        control_enabled = true
        max_image_dimension = 1600
        """
        let root = try TOMLParser.parse(text)
        let config = try RuneWeaverConfig(decoding: root)
        #expect(config.desktop.maxImageDimension == 1600)
        #expect(config.desktop.jpegQuality == 0.75)
        try config.validate()

        // Wrong-typed retired keys are ignored too, never a validation error.
        let loose = """
        [llm]
        default_provider = "mlx"

        [llm.providers.mlx]
        enabled = true
        model = "gemma-4-9b"
        server_url = "http://localhost:8080"

        [desktop]
        screen_capture_enabled = "yes"
        control_enabled = "no"
        """
        let looseConfig = try RuneWeaverConfig(decoding: TOMLParser.parse(loose))
        #expect(looseConfig.desktop.maxImageDimension == 1280)
        try looseConfig.validate()
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
    func `Desktop section round-trips through TOML serialization without retired keys`() throws {
        var config = RuneWeaverConfig.default
        config.desktop.maxImageDimension = 1600
        config.desktop.jpegQuality = 0.8
        config.desktop.blockedApps = ["Terminal", "Finder"]

        let toml = config.renderTOML()
        #expect(toml.contains("[desktop]"))
        #expect(!toml.contains("screen_capture_enabled"))
        #expect(!toml.contains("control_enabled"))
        // Provider and integration sections legitimately persist their own
        // `enabled` flags, so the retired desktop master key is checked
        // inside the [desktop] section only.
        let desktopSection: String
        if let start = toml.range(of: "[desktop]") {
            let tail = toml[start.lowerBound...]
            let body = tail.dropFirst("[desktop]".count)
            if let next = body.range(of: "\n[") {
                desktopSection = String(tail[..<next.lowerBound])
            } else {
                desktopSection = String(tail)
            }
        } else {
            desktopSection = ""
        }
        #expect(!desktopSection.contains("enabled = "))
        #expect(!desktopSection.contains("screen_capture_enabled"))
        #expect(!desktopSection.contains("control_enabled"))
        #expect(toml.contains("max_image_dimension = 1600"))

        let parsed = try TOMLParser.parse(toml)
        let decoded = try RuneWeaverConfig(decoding: parsed)
        #expect(decoded.desktop.maxImageDimension == 1600)
        #expect(decoded.desktop.jpegQuality == 0.8)
        #expect(decoded.desktop.blockedApps == ["Terminal", "Finder"])
    }
}

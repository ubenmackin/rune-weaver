// Rune Weaver Core Tests — Provider supports_vision configuration tests.

import Foundation
@testable import RuneWeaverCore
import Testing

@Suite("Provider Supports Vision Config")
struct ProviderSupportsVisionConfigTests {
    @Test
    func `ProviderConfig supportsVision defaults to nil`() {
        #expect(ProviderConfig().supportsVision == nil)
    }

    @Test
    func `Absent supports_vision decodes to nil`() throws {
        let text = """
        [llm]
        default_provider = "llamacpp"

        [llm.providers.llamacpp]
        enabled = true
        model = "local-model"
        server_url = "http://localhost:8081"
        """
        let root = try TOMLParser.parse(text)
        let config = try RuneWeaverConfig(decoding: root)
        #expect(config.llm.providers["llamacpp"]?.supportsVision == nil)
        try config.validate()
    }

    @Test
    func `Explicit supports_vision true decodes`() throws {
        let text = """
        [llm]
        default_provider = "local"

        [llm.providers.local]
        enabled = true
        provider_type = "llamacpp"
        model = "Qwen3.6-35B-A3B-UD-Q6_K_XL.gguf"
        server_url = "http://localhost:11434"
        supports_vision = true
        """
        let root = try TOMLParser.parse(text)
        let config = try RuneWeaverConfig(decoding: root)
        #expect(config.llm.providers["local"]?.supportsVision == true)
        try config.validate()
    }

    @Test
    func `Explicit supports_vision false decodes`() throws {
        let text = """
        [llm]
        default_provider = "openrouter"

        [llm.providers.openrouter]
        enabled = true
        model = "deepseek-chat"
        supports_vision = false
        """
        let root = try TOMLParser.parse(text)
        let config = try RuneWeaverConfig(decoding: root)
        #expect(config.llm.providers["openrouter"]?.supportsVision == false)
        try config.validate()
    }

    @Test
    func `Serialization roundtrips supports_vision true and false`() throws {
        var config = RuneWeaverConfig()
        config.llm.providers["vision-on"] = ProviderConfig(
            enabled: true,
            model: "qwen-vl",
            supportsVision: true
        )
        config.llm.providers["vision-off"] = ProviderConfig(
            enabled: true,
            model: "text-only",
            supportsVision: false
        )
        config.llm.providers["vision-unset"] = ProviderConfig(
            enabled: true,
            model: "default-model",
            supportsVision: nil
        )

        let tomlString = config.renderTOML()
        #expect(tomlString.contains("supports_vision = true"))
        #expect(tomlString.contains("supports_vision = false"))

        let redecoded = try RuneWeaverConfig(decoding: TOMLParser.parse(tomlString))
        #expect(redecoded.llm.providers["vision-on"]?.supportsVision == true)
        #expect(redecoded.llm.providers["vision-off"]?.supportsVision == false)
        #expect(redecoded.llm.providers["vision-unset"]?.supportsVision == nil)
    }
}

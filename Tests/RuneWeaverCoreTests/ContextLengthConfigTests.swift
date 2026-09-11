// RuneWeaver - Tests - Context length config
import Foundation
@testable import RuneWeaverCore
import Testing

@Suite("Context Length Config")
struct ContextLengthConfigTests {
    @Test
    func `ProviderConfig defaults to nil`() {
        #expect(ProviderConfig().contextLength == nil)
    }

    @Test
    func `Absent context_length decodes to nil`() throws {
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
        #expect(config.llm.providers["mlx"]?.contextLength == nil)
        try config.validate()
    }

    @Test
    func `Explicit context_length override decodes`() throws {
        let text = """
        [llm]
        default_provider = "openrouter"

        [llm.providers.openrouter]
        enabled = true
        base_url = "https://openrouter.ai/api/v1"
        api_key_env = "OPENROUTER_API_KEY"
        context_length = 1000000
        """
        let root = try TOMLParser.parse(text)
        let config = try RuneWeaverConfig(decoding: root)
        #expect(config.llm.providers["openrouter"]?.contextLength == 1_000_000)
        try config.validate()
    }

    @Test
    func `Non-positive context_length fails validation`() throws {
        let text = """
        [llm]
        default_provider = "mlx"

        [llm.providers.mlx]
        enabled = true
        model = "gemma-4-9b"
        server_url = "http://localhost:8080"
        context_length = 0
        """
        let root = try TOMLParser.parse(text)
        let config = try RuneWeaverConfig(decoding: root)
        do {
            try config.validate()
            Issue.record("Expected ConfigError for non-positive context_length")
        } catch let error as ConfigError {
            guard case let .validationError(field, _) = error else {
                Issue.record("Expected validationError, got \(error)")
                return
            }
            #expect(field == "llm.providers.mlx.context_length")
        }
    }
}

// Rune Weaver Core Tests — Config fallback provider tests.
import Foundation
@testable import RuneWeaverCore
import Testing

@Suite("Config Fallback Provider")
struct ConfigFallbackTests {
    @Test
    func `Absent fallback_provider decodes to nil and validates`() throws {
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
        #expect(config.llm.fallbackProvider == nil)
        try config.validate()
    }

    @Test
    func `Explicit known fallback_provider validates`() throws {
        let text = """
        [llm]
        default_provider = "mlx"
        fallback_provider = "openrouter"

        [llm.providers.mlx]
        enabled = true
        model = "gemma-4-9b"
        server_url = "http://localhost:8080"

        [llm.providers.openrouter]
        enabled = true
        server_url = "https://openrouter.ai/api/v1"
        api_key_env = "OPENROUTER_API_KEY"
        """
        let root = try TOMLParser.parse(text)
        let config = try RuneWeaverConfig(decoding: root)
        #expect(config.llm.fallbackProvider == "openrouter")
        try config.validate()
    }

    @Test
    func `Explicit unknown fallback_provider fails validation`() throws {
        let text = """
        [llm]
        default_provider = "mlx"
        fallback_provider = "missing-provider"

        [llm.providers.mlx]
        enabled = true
        model = "gemma-4-9b"
        server_url = "http://localhost:8080"
        """
        let root = try TOMLParser.parse(text)
        let config = try RuneWeaverConfig(decoding: root)
        #expect(config.llm.fallbackProvider == "missing-provider")
        do {
            try config.validate()
            Issue.record("Expected ConfigError for unknown fallback_provider")
        } catch let error as ConfigError {
            guard case let .validationError(field, _) = error else {
                Issue.record("Expected validationError, got \(error)")
                return
            }
            #expect(field == "llm.fallback_provider")
        }
    }

    @Test
    func `Recall budgets default when memory section absent`() throws {
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
        #expect(config.memory.recallBudgets == RecallBudgets())
        #expect(config.memory.recallBudgets.perTierLimit == 5)
        #expect(config.memory.recallBudgets.autoLimit == 5)
        #expect(config.memory.recallBudgets.threshold == 0.1)
        #expect(config.memory.recallBudgets.maxChars == 8000)
        #expect(config.memory.recallBudgets.perHitChars == 2000)
        #expect(config.memory.recallBudgets.docPoolMultiplier == 4)
        #expect(config.memory.recallBudgets.episodicWeight == 0.25)
        try config.validate()
    }

    @Test
    func `Recall budgets default when recall keys absent`() throws {
        let text = """
        [llm]
        default_provider = "mlx"

        [llm.providers.mlx]
        enabled = true
        model = "gemma-4-9b"
        server_url = "http://localhost:8080"

        [memory]
        vector_db_path = "~/.runeweaver/memory/vectors"
        episodes_db_path = "~/.runeweaver/memory/episodes.db"
        embedding_model = "all-MiniLM-L6-v2"
        """
        let root = try TOMLParser.parse(text)
        let config = try RuneWeaverConfig(decoding: root)
        #expect(config.memory.recallBudgets == RecallBudgets())
        try config.validate()
    }
}

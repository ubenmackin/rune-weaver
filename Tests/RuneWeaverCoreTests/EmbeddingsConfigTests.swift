// Rune Weaver Tests — Memory embedding backend selection.
import Foundation
@testable import RuneWeaverCore
import Testing

@Suite("Embeddings Config")
struct EmbeddingsConfigTests {
    @Test
    func `MemoryConfig defaults to apple backend`() {
        #expect(MemoryConfig().embeddingBackend == "apple")
        #expect(RuneWeaverConfig.default.memory.embeddingBackend == "apple")
    }

    @Test
    func `Absent embedding_backend decodes to apple`() throws {
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
        // Absent key preserves local-first behavior for existing installs.
        #expect(config.memory.embeddingBackend == "apple")
        try config.validate()
    }

    @Test
    func `Apple backend round-trips`() throws {
        try assertBackendRoundTrips("apple")
    }

    @Test
    func `Provider backend round-trips`() throws {
        try assertBackendRoundTrips("provider")
    }

    @Test
    func `None backend round-trips`() throws {
        try assertBackendRoundTrips("none")
    }

    @Test
    func `Unknown backend fails validation`() throws {
        let text = """
        [llm]
        default_provider = "mlx"

        [llm.providers.mlx]
        enabled = true
        model = "gemma-4-9b"
        server_url = "http://localhost:8080"

        [memory]
        embedding_backend = "carrier-pigeon"
        """
        let root = try TOMLParser.parse(text)
        let config = try RuneWeaverConfig(decoding: root)
        #expect(config.memory.embeddingBackend == "carrier-pigeon")
        do {
            try config.validate()
            Issue.record("Expected ConfigError for unknown embedding_backend")
        } catch let error as ConfigError {
            guard case let .validationError(field, _) = error else {
                Issue.record("Expected validationError, got \(error)")
                return
            }
            #expect(field == "memory.embedding_backend")
        }
    }

    @Test
    func `Embedding model persists alongside backend`() throws {
        let text = """
        [llm]
        default_provider = "mlx"

        [llm.providers.mlx]
        enabled = true
        model = "gemma-4-9b"
        server_url = "http://localhost:8080"

        [memory]
        embedding_model = "all-MiniLM-L6-v2"
        embedding_backend = "provider"
        """
        let root = try TOMLParser.parse(text)
        let config = try RuneWeaverConfig(decoding: root)
        // The model stays meaningful on the provider path and informational
        // elsewhere, so it must survive independently of the backend choice.
        #expect(config.memory.embeddingModel == "all-MiniLM-L6-v2")
        #expect(config.memory.embeddingBackend == "provider")
        try config.validate()
    }

    @Test
    func `Recall budgets round-trip`() throws {
        let text = """
        [llm]
        default_provider = "mlx"

        [llm.providers.mlx]
        enabled = true
        model = "gemma-4-9b"
        server_url = "http://localhost:8080"

        [memory]
        recall_per_tier_limit = 7
        recall_auto_limit = 3
        recall_threshold = 0.2
        recall_max_chars = 3000
        recall_per_hit_chars = 600
        recall_doc_pool_multiplier = 2
        recall_episodic_weight = 0.5
        """
        let root = try TOMLParser.parse(text)
        let config = try RuneWeaverConfig(decoding: root)
        #expect(config.memory.recallBudgets.perTierLimit == 7)
        #expect(config.memory.recallBudgets.autoLimit == 3)
        #expect(config.memory.recallBudgets.threshold == 0.2)
        #expect(config.memory.recallBudgets.maxChars == 3000)
        #expect(config.memory.recallBudgets.perHitChars == 600)
        #expect(config.memory.recallBudgets.docPoolMultiplier == 2)
        #expect(config.memory.recallBudgets.episodicWeight == 0.5)
        try config.validate()
        let rendered = config.renderTOML()
        #expect(rendered.contains("recall_per_tier_limit = 7"))
        #expect(rendered.contains("recall_auto_limit = 3"))
        #expect(rendered.contains("recall_threshold = 0.2"))
        #expect(rendered.contains("recall_max_chars = 3000"))
        #expect(rendered.contains("recall_per_hit_chars = 600"))
        #expect(rendered.contains("recall_doc_pool_multiplier = 2"))
        #expect(rendered.contains("recall_episodic_weight = 0.5"))
        let reparsed = try RuneWeaverConfig(decoding: TOMLParser.parse(rendered))
        #expect(reparsed.memory.recallBudgets == config.memory.recallBudgets)
        try reparsed.validate()
    }

    @Test
    func `Recall budgets defaults round-trip`() throws {
        let config = RuneWeaverConfig.default
        #expect(config.memory.recallBudgets == RecallBudgets())
        try config.validate()
        let rendered = config.renderTOML()
        #expect(rendered.contains("recall_per_tier_limit = 5"))
        #expect(rendered.contains("recall_threshold = 0.1"))
        let reparsed = try RuneWeaverConfig(decoding: TOMLParser.parse(rendered))
        #expect(reparsed.memory.recallBudgets == RecallBudgets())
        try reparsed.validate()
    }
}

/// Decodes one backend value, validates, renders, and re-decodes.
private func assertBackendRoundTrips(_ backend: String) throws {
    let text = """
    [llm]
    default_provider = "mlx"

    [llm.providers.mlx]
    enabled = true
    model = "gemma-4-9b"
    server_url = "http://localhost:8080"

    [memory]
    embedding_backend = "\(backend)"
    """
    let root = try TOMLParser.parse(text)
    let config = try RuneWeaverConfig(decoding: root)
    #expect(config.memory.embeddingBackend == backend)
    try config.validate()
    let rendered = config.renderTOML()
    #expect(rendered.contains("embedding_backend = \"\(backend)\""))
    let reparsed = try RuneWeaverConfig(decoding: TOMLParser.parse(rendered))
    #expect(reparsed.memory.embeddingBackend == backend)
    try reparsed.validate()
}

// Rune Weaver Tests — Memory embedding backend selection.
//
// Covers the `[memory] embedding_backend` selector that chooses how semantic
// recall vectors are produced. Validates the local-first default, per-value
// TOML round-trips, and rejection of unknown backends so recall never
// silently picks an unintended path.
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
}

/// Decodes one backend value, validates, renders, and re-decodes.
///
/// Rendering then re-parsing proves the TOML write path preserves the value
/// instead of only the in-memory struct holding it.
/// - Parameter backend: Backend string to round-trip.
/// - Throws: `ConfigError` on parse or validation failure.
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

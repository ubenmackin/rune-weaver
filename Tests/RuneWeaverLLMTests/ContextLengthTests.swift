// Rune Weaver LLM Tests — Context length providers and display.

@testable import RuneWeaverCore
@testable import RuneWeaverLLM
import Testing

@Suite("Context Length")
struct ContextLengthTests {
    @Test
    func `Nil context length resolves to 128000 for generic entries`() {
        let entry = ProviderConfig(
            enabled: true,
            serverURL: "https://example.com/v1",
            apiKeyEnv: "EXAMPLE_API_KEY"
        )
        #expect(entry.contextLength == nil)
        guard let provider = LLMProviderFactory.makeProvider(entryName: "custom", config: entry) else {
            Issue.record("Expected a provider for an enabled generic entry")
            return
        }
        guard let compat = provider as? OpenAICompatibleProvider else {
            Issue.record("Expected an OpenAICompatibleProvider, got \(type(of: provider))")
            return
        }
        #expect(compat.contextLength == 128_000)
        #expect(compat.modelInfo.contextLength == 128_000)
    }

    @Test
    func `Nil context length resolves to 8192 for MLX`() {
        let entry = ProviderConfig(
            enabled: true,
            model: "gemma-4-9b",
            serverURL: "http://localhost:8080"
        )
        #expect(entry.contextLength == nil)
        guard let provider = LLMProviderFactory.makeProvider(entryName: "mlx", config: entry) else {
            Issue.record("Expected a provider for an enabled mlx entry")
            return
        }
        guard let mlx = provider as? MLXProvider else {
            Issue.record("Expected an MLXProvider, got \(type(of: provider))")
            return
        }
        #expect(mlx.contextLength == 8192)
        #expect(mlx.modelInfo.contextLength == 8192)
    }

    @Test
    func `Nil context length resolves to 4096 for llama cpp`() {
        let entry = ProviderConfig(
            enabled: true,
            model: "local-model",
            serverURL: "http://localhost:8081",
            providerType: "llamacpp"
        )
        #expect(entry.contextLength == nil)
        guard let provider = LLMProviderFactory.makeProvider(entryName: "local", config: entry) else {
            Issue.record("Expected a provider for an enabled local entry")
            return
        }
        guard let local = provider as? LlamaCppProvider else {
            Issue.record("Expected a LlamaCppProvider, got \(type(of: provider))")
            return
        }
        #expect(local.contextLength == 4096)
        #expect(local.modelInfo.contextLength == 4096)
    }

    @Test
    func `Explicit override threads into provider and model info`() {
        let entry = ProviderConfig(
            enabled: true,
            serverURL: "https://example.com/v1",
            apiKeyEnv: "EXAMPLE_API_KEY",
            contextLength: 1_000_000
        )
        guard let provider = LLMProviderFactory.makeProvider(entryName: "custom", config: entry) else {
            Issue.record("Expected a provider for an enabled generic entry")
            return
        }
        guard let compat = provider as? OpenAICompatibleProvider else {
            Issue.record("Expected an OpenAICompatibleProvider, got \(type(of: provider))")
            return
        }
        #expect(compat.contextLength == 1_000_000)
        #expect(compat.modelInfo.contextLength == 1_000_000)
    }

    @Test
    func `Local entry override threads into provider`() {
        let entry = ProviderConfig(
            enabled: true,
            model: "gemma-4-9b",
            serverURL: "http://localhost:8080",
            contextLength: 1_000_000
        )
        guard let provider = LLMProviderFactory.makeProvider(entryName: "mlx", config: entry) else {
            Issue.record("Expected a provider for an enabled mlx entry")
            return
        }
        guard let mlx = provider as? MLXProvider else {
            Issue.record("Expected an MLXProvider, got \(type(of: provider))")
            return
        }
        #expect(mlx.contextLength == 1_000_000)
        #expect(mlx.modelInfo.contextLength == 1_000_000)
    }

    @Test
    func `Display math formats used window and percent`() {
        #expect(SessionTokenDisplay.percent(used: 12408, window: 1_000_000) == 1)
        #expect(SessionTokenDisplay.formatted(used: 12408, window: 1_000_000) == "12408/1000000, 1%")
        #expect(
            SessionTokenDisplay.label(model: "gpt-4o-mini", used: 12408, window: 1_000_000)
                == "(gpt-4o-mini · 12408/1000000, 1%)"
        )
        #expect(SessionTokenDisplay.label(model: "", used: 12408, window: 1_000_000) == "(12408/1000000, 1%)")
        #expect(SessionTokenDisplay.percent(used: 0, window: 1_000_000) == 0)
        #expect(SessionTokenDisplay.percent(used: 500, window: 1000) == 50)
        #expect(SessionTokenDisplay.percent(used: 100, window: 0) == 0)
    }

    @Test
    func `Session accumulation sums per-turn totals`() {
        var sessionTotal = 0
        sessionTotal += 10000
        sessionTotal += 2408
        #expect(sessionTotal == 12408)
        #expect(SessionTokenDisplay.formatted(used: sessionTotal, window: 1_000_000) == "12408/1000000, 1%")
    }
}

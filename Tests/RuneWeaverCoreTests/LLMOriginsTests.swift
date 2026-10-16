// Rune Weaver Core Tests — LLM SSRF-exemption origin derivation.

import Foundation
@testable import RuneWeaverCore
import Testing

@Suite("LLM Origins")
struct LLMOriginsTests {
    @Test
    func `Absent LLM config yields no origins`() {
        #expect(LLMOrigins.serverURLs(from: nil).isEmpty)
    }

    @Test
    func `Providers without server URLs are ignored`() {
        let llm = LLMConfig(providers: [
            "no-url": ProviderConfig(enabled: true),
            "blank": ProviderConfig(serverURL: "")
        ])
        #expect(LLMOrigins.serverURLs(from: llm).isEmpty)
    }

    @Test
    func `Whitespace-only URLs are dropped`() {
        let llm = LLMConfig(providers: [
            "spaces": ProviderConfig(serverURL: "   "),
            "tabs": ProviderConfig(serverURL: "\t\n")
        ])
        #expect(LLMOrigins.serverURLs(from: llm).isEmpty)
    }

    @Test
    func `Server URLs are trimmed`() {
        let llm = LLMConfig(providers: [
            "padded": ProviderConfig(serverURL: "  http://localhost:8080  ")
        ])
        #expect(LLMOrigins.serverURLs(from: llm) == ["http://localhost:8080"])
    }

    @Test
    func `Duplicate URLs collapse to the first occurrence`() {
        let llm = LLMConfig(providers: [
            "first": ProviderConfig(serverURL: "http://localhost:8080"),
            "duplicate": ProviderConfig(serverURL: "  http://localhost:8080  ")
        ])
        #expect(LLMOrigins.serverURLs(from: llm) == ["http://localhost:8080"])
    }

    @Test
    func `First-seen order across multiple providers is preserved`() {
        let llm = LLMConfig(providers: [
            "one": ProviderConfig(serverURL: "http://one:1"),
            "two": ProviderConfig(serverURL: "http://two:2"),
            "three": ProviderConfig(serverURL: "http://three:3")
        ])
        // Provider storage is unordered, so the contract worth pinning is that
        // the result mirrors the dictionary's iteration order instead of
        // reordering or sorting it.
        let expected = llm.providers.values.compactMap(\.serverURL)
        #expect(LLMOrigins.serverURLs(from: llm) == expected)
    }

    @Test
    func `All distinct origins from multiple providers are kept`() {
        let llm = LLMConfig(providers: [
            "local": ProviderConfig(serverURL: "http://localhost:8080"),
            "remote": ProviderConfig(serverURL: "https://openrouter.ai/api/v1"),
            "duplicate": ProviderConfig(serverURL: "http://localhost:8080")
        ])
        let origins = LLMOrigins.serverURLs(from: llm)
        #expect(origins.count == 2)
        #expect(Set(origins) == Set(["http://localhost:8080", "https://openrouter.ai/api/v1"]))
    }
}

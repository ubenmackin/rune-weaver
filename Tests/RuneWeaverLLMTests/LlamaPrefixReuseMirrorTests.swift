// Rune Weaver LLM Tests — Mirror test pinning prefix-reuse knobs across file and options shapes.

import Foundation
@testable import RuneWeaverCore
@testable import RuneWeaverLLM
import Testing

@Suite("Llama Prefix Reuse Mirror")
struct LlamaPrefixReuseMirrorTests {
    @Test
    func `Shared defaults stay in sync`() {
        // Stored absence stays unset on both shapes so small servers keep auto-assignment; the
        // effective wire hint for an absent cache key resolves separately at provider construction.
        #expect(ProviderConfig().slotCount == LlamaPrefixReuse.defaultSlotCount)
        #expect(ProviderConfig().cachePrompt == LlamaPrefixReuse.defaultCachePrompt)
        #expect(LlamaCppProviderOptions().slotCount == LlamaPrefixReuse.defaultSlotCount)
        #expect(LlamaCppProviderOptions().cachePrompt == LlamaPrefixReuse.defaultCachePrompt)
        #expect(LlamaPrefixReuse.defaultSlotCount == nil)
        #expect(LlamaPrefixReuse.defaultCachePrompt == nil)
        #expect(LlamaPrefixReuse.effectiveCachePromptWhenUnset == true)
        #expect(LlamaPrefixReuse.resolvedCachePrompt(fileValue: nil) == true)
        #expect(LlamaPrefixReuse.resolvedCachePrompt(fileValue: false) == false)
        #expect(LlamaPrefixReuse.resolvedCachePrompt(fileValue: true) == true)
    }

    @Test
    func `ProviderConfig shape uses camelCase keys and round-trips`() throws {
        let original = ProviderConfig(
            enabled: true,
            model: "local-model",
            serverURL: "http://localhost:8081",
            providerType: "llamacpp",
            slotCount: 4,
            cachePrompt: false
        )
        let data = try JSONEncoder().encode(original)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["slotCount"] as? Int == 4)
        #expect(json["cachePrompt"] as? Bool == false)
        #expect(json["slot_count"] == nil)
        #expect(json["cache_prompt"] == nil)

        let decoded = try JSONDecoder().decode(ProviderConfig.self, from: data)
        #expect(decoded == original)
    }

    @Test
    func `Absent file keys decode to unset`() throws {
        let minimal = try #require(#"{"enabled":true}"#.data(using: .utf8))
        let decoded = try JSONDecoder().decode(ProviderConfig.self, from: minimal)
        #expect(decoded.slotCount == nil)
        #expect(decoded.cachePrompt == nil)
        #expect(decoded.slotCount == LlamaPrefixReuse.defaultSlotCount)
        #expect(decoded.cachePrompt == LlamaPrefixReuse.defaultCachePrompt)
    }

    @Test
    func `Options shape uses camel keys and round-trips`() throws {
        let original = LlamaCppProviderOptions(
            serverURL: "http://localhost:8081",
            model: "local-model",
            contextLength: 4096,
            slotCount: 4,
            cachePrompt: false
        )
        let data = try JSONEncoder().encode(original)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["slotCount"] as? Int == 4)
        #expect(json["cachePrompt"] as? Bool == false)
        #expect(json["slot_count"] == nil)
        #expect(json["cache_prompt"] == nil)

        let decoded = try JSONDecoder().decode(LlamaCppProviderOptions.self, from: data)
        #expect(decoded == original)
    }

    @Test
    func `Absent options hints stay unset and resolve at the wire`() throws {
        let payload = try #require("""
        {"serverURL":"http://localhost:8081","model":"local-model","contextLength":4096}
        """.data(using: .utf8))
        let decoded = try JSONDecoder().decode(
            LlamaCppProviderOptions.self,
            from: payload
        )
        #expect(decoded.slotCount == nil)
        #expect(decoded.cachePrompt == LlamaPrefixReuse.defaultCachePrompt)
        #expect(decoded.makeProvider().cachePrompt == LlamaPrefixReuse.resolvedCachePrompt(fileValue: nil))
    }

    @Test
    func `Factory maps file knobs to the provider without drift`() {
        let unset = ProviderConfig(
            enabled: true,
            model: "local-model",
            serverURL: "http://localhost:8081",
            providerType: "llamacpp",
            slotCount: nil,
            cachePrompt: nil
        )
        guard let unsetProvider = LLMProviderFactory.makeProvider(entryName: "local", config: unset) as? LlamaCppProvider else {
            Issue.record("Expected a LlamaCppProvider for an enabled local entry")
            return
        }
        #expect(unsetProvider.slotCount == nil)
        #expect(unsetProvider.cachePrompt == LlamaPrefixReuse.resolvedCachePrompt(fileValue: nil))

        let explicit = ProviderConfig(
            enabled: true,
            model: "local-model",
            serverURL: "http://localhost:8081",
            providerType: "llamacpp",
            slotCount: 4,
            cachePrompt: false
        )
        guard let explicitProvider = LLMProviderFactory.makeProvider(entryName: "local", config: explicit) as? LlamaCppProvider else {
            Issue.record("Expected a LlamaCppProvider for an enabled local entry")
            return
        }
        #expect(explicitProvider.slotCount == 4)
        #expect(explicitProvider.cachePrompt == false)
    }
}

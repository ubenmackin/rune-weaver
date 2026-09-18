// Rune Weaver LLM — Provider configuration models and factory constructors.

import Foundation
import RuneWeaverCore

/// Backend selected for a provider entry.
public enum ProviderKind: String, Sendable, Codable, Equatable {
    /// Local MLX server (Apple Silicon).
    case mlx
    /// Local llama.cpp server.
    case llamaCpp = "llamacpp"
    /// Any OpenAI-compatible cloud or custom endpoint.
    case openAICompatible = "openai-compatible"
}

/// Initialization options for ``MLXProvider``.
public struct MLXProviderOptions: Sendable, Codable, Equatable {
    /// MLX server URL.
    public var serverURL: String
    /// Model identifier.
    public var model: String
    /// Context window in tokens.
    public var contextLength: Int

    /// Creates MLX options with local-first defaults.
    public init(
        serverURL: String = MLXProvider.defaultServerURL,
        model: String = MLXProvider.defaultModel,
        contextLength: Int = MLXProvider.defaultContextLength
    ) {
        self.serverURL = serverURL
        self.model = model
        self.contextLength = contextLength
    }

    /// Builds the provider.
    /// - Returns: Configured MLX provider.
    public func makeProvider() -> MLXProvider {
        MLXProvider(serverURL: serverURL, model: model, contextLength: contextLength)
    }
}

/// Initialization options for ``LlamaCppProvider``.
public struct LlamaCppProviderOptions: Sendable, Codable, Equatable {
    /// llama.cpp server URL.
    public var serverURL: String
    /// Model label sent with requests.
    public var model: String
    /// Context window in tokens.
    public var contextLength: Int
    /// Slot pool size for sticky `id_slot` pinning; nil omits the hint.
    /// Match this to the server's `--parallel` value to opt into prefix reuse.
    public var slotCount: Int?
    /// Prefix-cache hint sent as `cache_prompt`; nil omits the key.
    public var cachePrompt: Bool?

    /// Creates llama.cpp options with local-first defaults.
    /// The sticky slot and cache hint stay unset by default so servers with a small
    /// `--parallel` never reject an out-of-range id and stored payloads keep an
    /// omitted key distinct from an explicit hint. Stored defaults match the TOML
    /// shape through `LlamaPrefixReuse`; the effective wire hint resolves separately
    /// at provider construction so absent keys keep the always-on prefix hint.
    public init(
        serverURL: String = LlamaCppProvider.defaultServerURL,
        model: String = LlamaCppProvider.defaultModel,
        contextLength: Int = LlamaCppProvider.defaultContextLength,
        slotCount: Int? = LlamaPrefixReuse.defaultSlotCount,
        cachePrompt: Bool? = LlamaPrefixReuse.defaultCachePrompt
    ) {
        self.serverURL = serverURL
        self.model = model
        self.contextLength = contextLength
        self.slotCount = slotCount
        self.cachePrompt = cachePrompt
    }

    /// Builds the provider, resolving an unset cache hint to the always-on wire
    /// value so stored payloads stay aligned with the TOML shape while the wire
    /// keeps prefix reuse for payloads written before the knob existed.
    /// Provider-level construction stays session-agnostic; per-turn slot pinning
    /// takes the chat identifier at request time on `LlamaCppProvider`.
    /// - Returns: Configured llama.cpp provider.
    public func makeProvider() -> LlamaCppProvider {
        LlamaCppProvider(
            serverURL: serverURL,
            model: model,
            contextLength: contextLength,
            slotCount: slotCount,
            cachePrompt: LlamaPrefixReuse.resolvedCachePrompt(fileValue: cachePrompt)
        )
    }

    /// Camel wire keys match the JSON options transport. The TOML file shape keeps snake keys for
    /// the same knobs; stored defaults for both reference `LlamaPrefixReuse` plus the mirror test
    /// so the two shapes share one file-level default, with the effective wire hint resolved
    /// separately at provider construction.
    private enum CodingKeys: String, CodingKey {
        case serverURL
        case model
        case contextLength
        case slotCount
        case cachePrompt
    }

    /// Decodes options, leaving absent hints unset so stored payloads keep an
    /// omitted key distinct from an explicit hint.
    /// Both shapes share the same unset default; the effective wire hint resolves
    /// through `LlamaPrefixReuse.resolvedCachePrompt` at provider construction so
    /// payloads written before the knobs existed keep the always-on prefix hint
    /// on the wire without baking it into storage.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.serverURL = try container.decodeIfPresent(String.self, forKey: .serverURL) ?? LlamaCppProvider.defaultServerURL
        self.model = try container.decodeIfPresent(String.self, forKey: .model) ?? LlamaCppProvider.defaultModel
        self.contextLength = try container.decodeIfPresent(Int.self, forKey: .contextLength) ?? LlamaCppProvider.defaultContextLength
        self.slotCount = try container.decodeIfPresent(Int.self, forKey: .slotCount)
        self.cachePrompt = try container.decodeIfPresent(Bool.self, forKey: .cachePrompt)
    }

    /// Encodes options, omitting unset hints so older decoders see no new keys.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(serverURL, forKey: .serverURL)
        try container.encode(model, forKey: .model)
        try container.encode(contextLength, forKey: .contextLength)
        try container.encodeIfPresent(slotCount, forKey: .slotCount)
        try container.encodeIfPresent(cachePrompt, forKey: .cachePrompt)
    }
}

/// Initialization options for ``OpenAICompatibleProvider``.
public struct OpenAICompatibleProviderOptions: Sendable, Codable, Equatable {
    /// API root (OpenRouter by default).
    public var baseURL: String
    /// Resolved bearer token, if the endpoint requires auth.
    public var apiKey: String?
    /// Model identifier.
    public var model: String
    /// Context window in tokens.
    public var contextLength: Int
    /// Router identifier for this endpoint.
    public var providerID: String
    /// Whether to advertise embeddings support.
    public var embeddingsEnabled: Bool
    /// Request style selecting the wire endpoint and SSE shape.
    public var apiStyle: APIStyle = .chatCompletions

    /// Creates generic endpoint options.
    public init(
        baseURL: String = OpenAICompatibleProvider.defaultBaseURL,
        apiKey: String? = nil,
        model: String = OpenAICompatibleProvider.defaultModel,
        contextLength: Int = OpenAICompatibleProvider.defaultContextLength,
        providerID: String = "openrouter",
        embeddingsEnabled: Bool = true,
        apiStyle: APIStyle = .chatCompletions
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.contextLength = contextLength
        self.providerID = providerID
        self.embeddingsEnabled = embeddingsEnabled
        self.apiStyle = apiStyle
    }

    /// Builds the provider.
    /// - Returns: Configured OpenAI-compatible provider.
    public func makeProvider() -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(
            baseURL: baseURL,
            apiKey: apiKey,
            model: model,
            contextLength: contextLength,
            providerID: providerID,
            embeddingsEnabled: embeddingsEnabled,
            apiStyle: apiStyle
        )
    }
}

/// Builds providers from options structs and `config.toml` entries.
public enum LLMProviderFactory: Sendable {
    /// Builds a provider from explicit options.
    public static func makeProvider(kind: ProviderKind, apiKey: String? = nil) -> any LLMProvider {
        switch kind {
        case .mlx:
            MLXProvider()
        case .llamaCpp:
            LlamaCppProvider()
        case .openAICompatible:
            OpenAICompatibleProvider(apiKey: apiKey)
        }
    }

    /// Resolves a bearer token without touching the Keychain.
    public static func resolveAPIKey(explicit: String?, envVar: String?) -> String? {
        if let explicit, !explicit.isEmpty {
            return explicit
        }
        guard let envVar, !envVar.isEmpty else { return nil }
        guard let value = ProcessInfo.processInfo.environment[envVar],
              !value.isEmpty
        else { return nil }
        return value
    }

    /// Builds a provider from a `config.toml` entry.
    public static func makeProvider(
        entryName: String,
        config: RuneWeaverCore.ProviderConfig,
        apiKey: String? = nil
    ) -> (any LLMProvider)? {
        guard config.enabled else { return nil }
        let kindHint = (config.providerType ?? entryName).lowercased()
        switch kindHint {
        case "mlx":
            return MLXProvider(
                serverURL: config.serverURL ?? MLXProvider.defaultServerURL,
                model: config.model ?? MLXProvider.defaultModel,
                contextLength: config.contextLength ?? MLXProvider.defaultContextLength
            )
        case "llamacpp", "llama-cpp", "llama_cpp", "local":
            // An absent pool keeps server auto-assignment so default installs
            // never send an out-of-range `id_slot` to small `--parallel`
            // servers; operators opt in via `slot_count` matching the server's
            // pool. An absent cache hint resolves to the always-on prefix hint at the
            // wire so files written before the knob keep current behavior. Both the
            // TOML entry and the JSON options shape store the same unset default and
            // resolve through `LlamaPrefixReuse` so the two shapes stay in sync.
            return LlamaCppProvider(
                serverURL: config.serverURL ?? LlamaCppProvider.defaultServerURL,
                model: config.model ?? LlamaCppProvider.defaultModel,
                contextLength: config.contextLength ?? LlamaCppProvider.defaultContextLength,
                slotCount: config.slotCount ?? RuneWeaverCore.LlamaPrefixReuse.defaultSlotCount,
                cachePrompt: RuneWeaverCore.LlamaPrefixReuse.resolvedCachePrompt(fileValue: config.cachePrompt)
            )
        default:
            return OpenAICompatibleProvider(
                baseURL: config.serverURL ?? OpenAICompatibleProvider.defaultBaseURL,
                apiKey: apiKey,
                model: config.model ?? OpenAICompatibleProvider.defaultModel,
                contextLength: config.contextLength ?? OpenAICompatibleProvider.defaultContextLength,
                providerID: entryName,
                apiStyle: config.apiStyle
            )
        }
    }

    /// Builds every enabled provider in an `[llm]` section.
    public static func makeProviders(
        from llm: RuneWeaverCore.LLMConfig,
        apiKeysByEntry: [String: String] = [:]
    ) -> [any LLMProvider] {
        llm.providers.compactMap { entryName, config in
            makeProvider(entryName: entryName, config: config, apiKey: apiKeysByEntry[entryName])
        }
    }

    /// Selects the active provider: explicit override first (matched against the provider name, its
    /// local aliases, then the model name), then `default_provider`, then `fallback_provider`, then
    /// first enabled.
    public static func selectProvider(
        named override: String?,
        from providers: [any LLMProvider],
        config: RuneWeaverCore.LLMConfig
    ) -> (any LLMProvider)? {
        if let override, !override.isEmpty {
            let wanted = override.lowercased()
            if let match = providers.first(where: { matchesProvider($0, wanted: wanted) }) {
                return match
            }
            return providers.first(where: { $0.modelInfo.name.lowercased() == wanted })
        }
        if let match = providers.first(where: { matchesProvider($0, wanted: config.defaultProvider) }) {
            return match
        }
        if let fallback = config.fallbackProvider,
           let match = providers.first(where: { matchesProvider($0, wanted: fallback) })
        {
            return match
        }
        return providers.first
    }

    /// Whether a provider matches a configured name, including the local-backend aliases
    /// (`llamacpp`, `llama-cpp`, `llama_cpp`, `local` all match each other). Comparison is case-
    /// insensitive and trims surrounding whitespace.
    public static func matchesProvider(_ provider: any LLMProvider, wanted: String) -> Bool {
        let normalized = wanted.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        if provider.name.lowercased() == normalized {
            return true
        }
        let localAliases: Set = ["llamacpp", "llama-cpp", "llama_cpp", "local"]
        if localAliases.contains(provider.name.lowercased()), localAliases.contains(normalized) {
            return true
        }
        return false
    }
}

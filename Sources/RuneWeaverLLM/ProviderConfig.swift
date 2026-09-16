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

    /// Creates llama.cpp options with local-first defaults.
    public init(
        serverURL: String = LlamaCppProvider.defaultServerURL,
        model: String = LlamaCppProvider.defaultModel,
        contextLength: Int = LlamaCppProvider.defaultContextLength
    ) {
        self.serverURL = serverURL
        self.model = model
        self.contextLength = contextLength
    }

    /// Builds the provider.
    /// - Returns: Configured llama.cpp provider.
    public func makeProvider() -> LlamaCppProvider {
        LlamaCppProvider(serverURL: serverURL, model: model, contextLength: contextLength)
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
            return LlamaCppProvider(
                serverURL: config.serverURL ?? LlamaCppProvider.defaultServerURL,
                model: config.model ?? LlamaCppProvider.defaultModel,
                contextLength: config.contextLength ?? LlamaCppProvider.defaultContextLength
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

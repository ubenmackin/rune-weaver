// Rune Weaver Tools — Built-in tool plugin registration surface.
//
// Single-sources the full built-in suite (Email, Files, Memory, Web, Browser,
// API) shared by CLI, the menu-bar app, and serve. `CLIShared.makeToolBus`,
// `AppModel`, and `ServerContext.make` all build through this helper so the
// registry cannot drift between entry points. Web, browser, and API tools run
// under one `[browser]` policy; `api.request` additionally exempts the
// configured LLM origins from the SSRF loopback deny.

import RuneWeaverCore

/// Shared built-in tool suites registered on every `ToolBus` by CLI, app, and serve.
public enum BuiltinToolPlugins {
    /// Tool names in registration order for the web/browser subset.
    public static var toolNames: [String] {
        WebTools.toolNames + BrowserTools.toolNames + ApiRequestTools.toolNames
    }

    /// All built-in tool names across every suite in registration order
    /// (email, files, memory, web, browser, api).
    public static var allToolNames: [String] {
        EmailTools.toolNames + FilesTools.toolNames + MemoryTools.toolNames + toolNames
    }

    /// Builds the shared five-tool set for one `[browser]` policy.
    /// - Parameters:
    ///   - browserConfig: `[browser]` policy feeding search, fetch, and API tools.
    ///   - llmServerURLs: Configured LLM `server_url` values exempted from the SSRF loopback deny.
    ///   - gateway: Playwright gateway shared by the browser tools.
    ///   - searchTransport: Hermetic SearXNG transport for tests; live session when nil.
    ///   - fetchTransport: Hermetic fetch transport for tests; live session when nil.
    ///   - apiTransport: Hermetic API transport for tests; live session when nil.
    ///   - ensurer: Lifecycle ensurer for tests; shared actor when nil.
    /// - Returns: Tools in registration order.
    public static func makeTools(
        browserConfig: BrowserConfig = BrowserConfig(),
        llmServerURLs: [String] = [],
        gateway: (any BrowserPlaywrightGateway)? = nil,
        searchTransport: (any WebSearchTransport)? = nil,
        fetchTransport: (any WebFetchTransport)? = nil,
        apiTransport: (any ApiRequestTransport)? = nil,
        ensurer: (any SearXNGEnsuring)? = nil
    ) -> [any Tool] {
        WebTools.makeTools(
            browserConfig: browserConfig,
            searchTransport: searchTransport,
            fetchTransport: fetchTransport,
            ensurer: ensurer
        )
            + BrowserTools.makeTools(gateway: gateway)
            + ApiRequestTools.makeTools(browserConfig: browserConfig, llmServerURLs: llmServerURLs, transport: apiTransport)
    }

    /// Builds the full built-in tool suite (Email, Files, Memory, Web, Browser, API)
    /// from component configurations.
    public static func makeAllTools(
        emailConfig: EmailConfig? = nil,
        filesConfig: FilesConfig? = nil,
        sandboxConfig: SandboxConfig? = nil,
        browserConfig: BrowserConfig = BrowserConfig(),
        llmServerURLs: [String] = [],
        memoryEngine: MemoryEngine? = nil,
        embedder: (any EmbeddingsBackend)? = nil,
        gateway: (any BrowserPlaywrightGateway)? = nil,
        searchTransport: (any WebSearchTransport)? = nil,
        fetchTransport: (any WebFetchTransport)? = nil,
        apiTransport: (any ApiRequestTransport)? = nil,
        ensurer: (any SearXNGEnsuring)? = nil
    ) -> [any Tool] {
        var tools: [any Tool] = []
        if let emailConfig {
            // Forward the same `[files]` policy the Files tools use so the
            // email attachment export path enforces one policy, not defaults.
            tools += EmailTools.makeTools(
                emailConfig: emailConfig,
                sandboxConfig: sandboxConfig ?? SandboxConfig(),
                filesConfig: filesConfig ?? FilesConfig()
            )
        }
        tools += FilesTools.makeTools(filesConfig: filesConfig ?? FilesConfig())
        if let memoryEngine {
            tools += MemoryTools.makeTools(engine: memoryEngine, embedder: embedder)
        }
        tools += makeTools(
            browserConfig: browserConfig,
            llmServerURLs: llmServerURLs,
            gateway: gateway,
            searchTransport: searchTransport,
            fetchTransport: fetchTransport,
            apiTransport: apiTransport,
            ensurer: ensurer
        )
        return tools
    }

    /// Convenience overload building all tools from a unified `RuneWeaverConfig`.
    public static func makeAllTools(
        config: RuneWeaverConfig,
        memoryEngine: MemoryEngine? = nil,
        embedder: (any EmbeddingsBackend)? = nil,
        gateway: (any BrowserPlaywrightGateway)? = nil,
        searchTransport: (any WebSearchTransport)? = nil,
        fetchTransport: (any WebFetchTransport)? = nil,
        apiTransport: (any ApiRequestTransport)? = nil,
        ensurer: (any SearXNGEnsuring)? = nil
    ) -> [any Tool] {
        let appLLMOrigins = LLMOrigins.serverURLs(from: config.llm)
        return makeAllTools(
            emailConfig: config.email,
            filesConfig: config.files,
            sandboxConfig: config.sandbox,
            browserConfig: config.browser,
            llmServerURLs: appLLMOrigins,
            memoryEngine: memoryEngine,
            embedder: embedder,
            gateway: gateway,
            searchTransport: searchTransport,
            fetchTransport: fetchTransport,
            apiTransport: apiTransport,
            ensurer: ensurer
        )
    }

    /// Registers the full built-in tool suite on the provided ToolBus.
    /// The single registration surface for built-in tools; callers that need a
    /// custom subset build from `makeTools`/`makeAllTools` and register directly.
    public static func registerAll(
        on bus: ToolBus,
        emailConfig: EmailConfig? = nil,
        filesConfig: FilesConfig? = nil,
        sandboxConfig: SandboxConfig? = nil,
        browserConfig: BrowserConfig = BrowserConfig(),
        llmServerURLs: [String] = [],
        memoryEngine: MemoryEngine? = nil,
        embedder: (any EmbeddingsBackend)? = nil,
        gateway: (any BrowserPlaywrightGateway)? = nil,
        searchTransport: (any WebSearchTransport)? = nil,
        fetchTransport: (any WebFetchTransport)? = nil,
        apiTransport: (any ApiRequestTransport)? = nil,
        ensurer: (any SearXNGEnsuring)? = nil
    ) async {
        for tool in makeAllTools(
            emailConfig: emailConfig,
            filesConfig: filesConfig,
            sandboxConfig: sandboxConfig,
            browserConfig: browserConfig,
            llmServerURLs: llmServerURLs,
            memoryEngine: memoryEngine,
            embedder: embedder,
            gateway: gateway,
            searchTransport: searchTransport,
            fetchTransport: fetchTransport,
            apiTransport: apiTransport,
            ensurer: ensurer
        ) {
            await bus.register(tool: tool)
        }
    }
}

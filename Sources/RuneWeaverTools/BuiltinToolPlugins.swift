// Rune Weaver Tools — Built-in tool plugin registration surface.
//
// Single-sources the five-tool set shared by CLI and serve (`web.search`,
// `web.fetch`, `browser.navigate`, `browser.act`, `api.request`) under one
// `[browser]` policy. CLI (`CLIShared`) and serve (`ServerContext.make`) build
// through this helper so the registry cannot drift between entry points;
// `api.request` additionally exempts the configured LLM origins from the SSRF
// loopback deny.

import RuneWeaverCore

/// Shared built-in web and browser tools registered on every `ToolBus`.
public enum BuiltinToolPlugins {
    /// Tool names in registration order.
    public static var toolNames: [String] {
        WebTools.toolNames + BrowserTools.toolNames + ApiRequestTools.toolNames
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

    /// Registers the shared five-tool set, replacing same-named entries.
    /// - Parameters:
    ///   - bus: Registry receiving the tools.
    ///   - browserConfig: `[browser]` policy feeding search, fetch, and API tools.
    ///   - llmServerURLs: Configured LLM origins for the SSRF exemption.
    ///   - gateway: Playwright gateway shared by the browser tools.
    ///   - searchTransport: Hermetic SearXNG transport for tests; live session when nil.
    ///   - fetchTransport: Hermetic fetch transport for tests; live session when nil.
    ///   - apiTransport: Hermetic API transport for tests; live session when nil.
    ///   - ensurer: Lifecycle ensurer for tests; shared actor when nil.
    public static func register(
        on bus: ToolBus,
        browserConfig: BrowserConfig = BrowserConfig(),
        llmServerURLs: [String] = [],
        gateway: (any BrowserPlaywrightGateway)? = nil,
        searchTransport: (any WebSearchTransport)? = nil,
        fetchTransport: (any WebFetchTransport)? = nil,
        apiTransport: (any ApiRequestTransport)? = nil,
        ensurer: (any SearXNGEnsuring)? = nil
    ) async {
        for tool in makeTools(
            browserConfig: browserConfig,
            llmServerURLs: llmServerURLs,
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

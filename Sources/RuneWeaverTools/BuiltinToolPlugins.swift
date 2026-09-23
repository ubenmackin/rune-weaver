// Rune Weaver Tools — Built-in tool plugin registration surface.
//
// Single-sources the full built-in suite (Email, Files, Memory, Web, Browser,
// API, Media) shared by CLI, the menu-bar app, and serve. `CLIShared.makeToolBus`,
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
    /// (email, files, memory, web, browser, api, media, desktop).
    public static var allToolNames: [String] {
        EmailTools.toolNames + FilesTools.toolNames + MemoryTools.toolNames + toolNames + MediaTools.toolNames + DesktopTools.allToolNames
    }

    /// Builds the shared five-tool set for one `[browser]` policy.
    /// - Parameters:
    ///   - browserConfig: `[browser]` policy feeding search, fetch, and API tools.
    ///   - mediaConfig: Optional media policy for auto-allowing media server origins.
    ///   - llmServerURLs: Configured LLM `server_url` values exempted from the SSRF loopback deny.
    ///   - gateway: Playwright gateway shared by the browser tools.
    ///   - searchTransport: Hermetic SearXNG transport for tests; live session when nil.
    ///   - fetchTransport: Hermetic fetch transport for tests; live session when nil.
    ///   - apiTransport: Hermetic API transport for tests; live session when nil.
    ///   - ensurer: Lifecycle ensurer for tests; shared actor when nil.
    /// - Returns: Tools in registration order.
    public static func makeTools(
        browserConfig: BrowserConfig = BrowserConfig(),
        mediaConfig: MediaConfig? = nil,
        llmServerURLs: [String] = [],
        gateway: (any BrowserPlaywrightGateway)? = nil,
        searchTransport: (any WebSearchTransport)? = nil,
        fetchTransport: (any WebFetchTransport)? = nil,
        apiTransport: (any ApiRequestTransport)? = nil,
        ensurer: (any SearXNGEnsuring)? = nil
    ) -> [any Tool] {
        let origins = ApiSSRFGuard.allowlistedOrigins(
            browserConfig: browserConfig,
            mediaConfig: mediaConfig,
            llmServerURLs: llmServerURLs
        )
        return WebTools.makeTools(
            browserConfig: browserConfig,
            mediaConfig: mediaConfig,
            searchTransport: searchTransport,
            fetchTransport: fetchTransport,
            ensurer: ensurer
        )
            + BrowserTools.makeTools(gateway: gateway, allowlistedOrigins: origins)
            + ApiRequestTools.makeTools(
                browserConfig: browserConfig, mediaConfig: mediaConfig, llmServerURLs: llmServerURLs, transport: apiTransport
            )
    }

    /// Builds the full built-in tool suite (Email, Files, Memory, Web, Browser, API, Media, Desktop)
    /// from component configurations.
    public static func makeAllTools(
        emailConfig: EmailConfig? = nil,
        filesConfig: FilesConfig? = nil,
        sandboxConfig: SandboxConfig? = nil,
        browserConfig: BrowserConfig = BrowserConfig(),
        mediaConfig: MediaConfig? = nil,
        desktopConfig: DesktopConfig = DesktopConfig(),
        llmServerURLs: [String] = [],
        memoryEngine: MemoryEngine? = nil,
        embedder: (any EmbeddingsBackend)? = nil,
        gateway: (any BrowserPlaywrightGateway)? = nil,
        searchTransport: (any WebSearchTransport)? = nil,
        fetchTransport: (any WebFetchTransport)? = nil,
        apiTransport: (any ApiRequestTransport)? = nil,
        mediaTransport: (any MediaArrTransport)? = nil,
        ensurer: (any SearXNGEnsuring)? = nil,
        mediaSecrets: SecretsManager? = nil,
        desktopCaptureBridge: (any DesktopCapturing)? = nil,
        desktopControlBridge: (any DesktopControlling)? = nil
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
            mediaConfig: mediaConfig,
            llmServerURLs: llmServerURLs,
            gateway: gateway,
            searchTransport: searchTransport,
            fetchTransport: fetchTransport,
            apiTransport: apiTransport,
            ensurer: ensurer
        )
        if let mediaConfig {
            tools += MediaTools.makeTools(mediaConfig: mediaConfig, transport: mediaTransport, secrets: mediaSecrets)
        }
        tools += DesktopTools.makeTools(
            desktopConfig: desktopConfig,
            captureBridge: desktopCaptureBridge,
            controlBridge: desktopControlBridge
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
        mediaTransport: (any MediaArrTransport)? = nil,
        ensurer: (any SearXNGEnsuring)? = nil,
        mediaSecrets: SecretsManager? = nil
    ) -> [any Tool] {
        let appLLMOrigins = LLMOrigins.serverURLs(from: config.llm)
        return makeAllTools(
            emailConfig: config.email,
            filesConfig: config.files,
            sandboxConfig: config.sandbox,
            browserConfig: config.browser,
            mediaConfig: config.media,
            desktopConfig: config.desktop,
            llmServerURLs: appLLMOrigins,
            memoryEngine: memoryEngine,
            embedder: embedder,
            gateway: gateway,
            searchTransport: searchTransport,
            fetchTransport: fetchTransport,
            apiTransport: apiTransport,
            mediaTransport: mediaTransport,
            ensurer: ensurer,
            mediaSecrets: mediaSecrets
        )
    }

    /// Registers the full built-in tool suite on the provided ToolBus.
    /// The single registration surface for built-in tools; callers that need a
    /// custom subset build from `makeTools`/`makeAllTools` and register directly.
    ///
    /// Desktop tools always register but arrive disabled: persisted
    /// tool-state rows re-apply via `restoreToolStates`, so a stock install
    /// never puts approval-free screen capture in front of the model at boot
    /// until the operator enables the tool-state toggle.
    public static func registerAll(
        on bus: ToolBus,
        emailConfig: EmailConfig? = nil,
        filesConfig: FilesConfig? = nil,
        sandboxConfig: SandboxConfig? = nil,
        browserConfig: BrowserConfig = BrowserConfig(),
        mediaConfig: MediaConfig? = nil,
        desktopConfig: DesktopConfig = DesktopConfig(),
        llmServerURLs: [String] = [],
        memoryEngine: MemoryEngine? = nil,
        embedder: (any EmbeddingsBackend)? = nil,
        gateway: (any BrowserPlaywrightGateway)? = nil,
        searchTransport: (any WebSearchTransport)? = nil,
        fetchTransport: (any WebFetchTransport)? = nil,
        apiTransport: (any ApiRequestTransport)? = nil,
        mediaTransport: (any MediaArrTransport)? = nil,
        ensurer: (any SearXNGEnsuring)? = nil,
        mediaSecrets: SecretsManager? = nil,
        desktopCaptureBridge: (any DesktopCapturing)? = nil,
        desktopControlBridge: (any DesktopControlling)? = nil
    ) async {
        let desktopNames = Set(DesktopTools.allToolNames)
        for tool in makeAllTools(
            emailConfig: emailConfig,
            filesConfig: filesConfig,
            sandboxConfig: sandboxConfig,
            browserConfig: browserConfig,
            mediaConfig: mediaConfig,
            desktopConfig: desktopConfig,
            llmServerURLs: llmServerURLs,
            memoryEngine: memoryEngine,
            embedder: embedder,
            gateway: gateway,
            searchTransport: searchTransport,
            fetchTransport: fetchTransport,
            apiTransport: apiTransport,
            mediaTransport: mediaTransport,
            ensurer: ensurer,
            mediaSecrets: mediaSecrets,
            desktopCaptureBridge: desktopCaptureBridge,
            desktopControlBridge: desktopControlBridge
        ) {
            // Every other builtin keeps the enabled-by-default registration;
            // desktop tools ship disabled so only an operator-enabled tool
            // goes live (stored rows restore right after registration).
            await bus.register(tool: tool, isEnabled: !desktopNames.contains(tool.name))
        }
    }
}

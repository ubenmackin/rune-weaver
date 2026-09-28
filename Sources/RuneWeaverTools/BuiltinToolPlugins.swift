// Rune Weaver Tools — Built-in tool plugin registration surface.
//
// Single-sources the full built-in suite (Email, Messages, Files, Bash, Memory,
// Goals, Web, Browser, API, Media, Desktop) shared by CLI, the menu-bar app, and serve. `CLIShared.makeToolBus`,
// `AppModel`, and `ServerContext.make` all build through this helper so the
// registry cannot drift between entry points. Web, browser, and API tools run
// under one `[browser]` policy; `api.request` additionally exempts the
// configured LLM origins from the SSRF loopback deny. Goal tools register only
// when both the engine and store arrive (nil means unregistered); a disabled
// `[goals]` section still registers and fails closed inside each tool so the
// surface stays visible instead of shape-shifting.

import RuneWeaverCore

/// Shared built-in tool suites registered on every `ToolBus` by CLI, app, and serve.
public enum BuiltinToolPlugins {
    /// Tool names in registration order for the web/browser subset.
    public static var toolNames: [String] {
        WebTools.toolNames + BrowserTools.toolNames + ApiRequestTools.toolNames
    }

    /// All built-in tool names across every suite in registration order
    /// (email, messages, files, bash, memory, goals, web, browser, api, media, desktop).
    public static var allToolNames: [String] {
        EmailTools.toolNames
            + MessagesTools.toolNames
            + FilesTools.toolNames
            + ["bash.exec"]
            + MemoryTools.toolNames
            + GoalTools.toolNames
            + toolNames
            + MediaTools.toolNames
            + DesktopTools.allToolNames
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
    ///   - secrets: Shared secrets backing surrogate resolution; fresh instance when nil.
    /// - Returns: Tools in registration order.
    public static func makeTools(
        browserConfig: BrowserConfig = BrowserConfig(),
        mediaConfig: MediaConfig? = nil,
        llmServerURLs: [String] = [],
        gateway: (any BrowserPlaywrightGateway)? = nil,
        searchTransport: (any WebSearchTransport)? = nil,
        fetchTransport: (any WebFetchTransport)? = nil,
        apiTransport: (any ApiRequestTransport)? = nil,
        ensurer: (any SearXNGEnsuring)? = nil,
        secrets: SecretsManager? = nil
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
            + BrowserTools.makeTools(
                gateway: gateway,
                browserConfig: browserConfig,
                mediaConfig: mediaConfig,
                llmServerURLs: llmServerURLs,
                allowlistedOrigins: origins
            )
            + ApiRequestTools.makeTools(
                browserConfig: browserConfig,
                mediaConfig: mediaConfig,
                llmServerURLs: llmServerURLs,
                transport: apiTransport,
                secrets: secrets
            )
    }

    /// Builds the full built-in tool suite (Email, Messages, Files, Bash, Memory, Goals, Web, Browser, API, Media, Desktop)
    /// from component configurations.
    ///
    /// Goal tools join only when both the engine and store arrive; nil keeps them
    /// unregistered so callers without pursuit wiring see no shape change. A disabled
    /// `[goals]` section still registers through the same path and fails closed inside
    /// each tool, keeping `GET /tools` stable instead of shape-shifting with config.
    public static func makeAllTools(
        emailConfig: EmailConfig? = nil,
        filesConfig: FilesConfig? = nil,
        bashConfig: BashConfig = BashConfig(),
        sandboxConfig: SandboxConfig? = nil,
        browserConfig: BrowserConfig = BrowserConfig(),
        mediaConfig: MediaConfig? = nil,
        desktopConfig: DesktopConfig = DesktopConfig(),
        llmServerURLs: [String] = [],
        securityConfig: SecurityConfig = SecurityConfig(),
        memoryEngine: MemoryEngine? = nil,
        embedder: (any EmbeddingsBackend)? = nil,
        gateway: (any BrowserPlaywrightGateway)? = nil,
        searchTransport: (any WebSearchTransport)? = nil,
        fetchTransport: (any WebFetchTransport)? = nil,
        apiTransport: (any ApiRequestTransport)? = nil,
        mediaTransport: (any MediaArrTransport)? = nil,
        ensurer: (any SearXNGEnsuring)? = nil,
        mediaSecrets: SecretsManager? = nil,
        secrets: SecretsManager? = nil,
        desktopCaptureBridge: (any DesktopCapturing)? = nil,
        desktopControlBridge: (any DesktopControlling)? = nil,
        goalEngine: GoalEngine? = nil,
        goalStore: GoalStore? = nil,
        goalConversations: ConversationManager? = nil,
        goalsConfig: GoalsConfig = GoalsConfig(),
        messagesGateway: (any MessagesGateway)? = nil,
        chatDatabasePath: String = MessagesIndexer.defaultChatDatabasePath
    ) -> [any Tool] {
        var tools: [any Tool] = []
        if let emailConfig {
            // Forward the same `[files]` policy the Files tools use so the
            // email attachment export path enforces one policy, not defaults.
            tools += EmailTools.makeTools(
                emailConfig: emailConfig,
                sandboxConfig: sandboxConfig ?? SandboxConfig(),
                filesConfig: filesConfig ?? FilesConfig(),
                securityConfig: securityConfig
            )
        }
        tools += MessagesTools.makeTools(chatDatabasePath: chatDatabasePath, gateway: messagesGateway)
        tools += FilesTools.makeTools(filesConfig: filesConfig ?? FilesConfig())
        // Bash always registers so GET /tools stays stable; a disabled
        // config fails closed inside BashTool.execute via its enabled guard.
        tools.append(BashTool(bashConfig: bashConfig, filesConfig: filesConfig ?? FilesConfig()))
        if let memoryEngine {
            tools += MemoryTools.makeTools(engine: memoryEngine, embedder: embedder)
        }
        if let goalEngine, let goalStore {
            tools += GoalTools.makeTools(
                engine: goalEngine,
                store: goalStore,
                conversations: goalConversations,
                goalsConfig: goalsConfig
            )
        }
        tools += makeTools(
            browserConfig: browserConfig,
            mediaConfig: mediaConfig,
            llmServerURLs: llmServerURLs,
            gateway: gateway,
            searchTransport: searchTransport,
            fetchTransport: fetchTransport,
            apiTransport: apiTransport,
            ensurer: ensurer,
            secrets: secrets
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
        mediaSecrets: SecretsManager? = nil,
        secrets: SecretsManager? = nil,
        goalEngine: GoalEngine? = nil,
        goalStore: GoalStore? = nil,
        goalConversations: ConversationManager? = nil
    ) -> [any Tool] {
        let appLLMOrigins = LLMOrigins.serverURLs(from: config.llm)
        return makeAllTools(
            emailConfig: config.email,
            filesConfig: config.files,
            bashConfig: config.bash,
            sandboxConfig: config.sandbox,
            browserConfig: config.browser,
            mediaConfig: config.media,
            desktopConfig: config.desktop,
            llmServerURLs: appLLMOrigins,
            securityConfig: config.security,
            memoryEngine: memoryEngine,
            embedder: embedder,
            gateway: gateway,
            searchTransport: searchTransport,
            fetchTransport: fetchTransport,
            apiTransport: apiTransport,
            mediaTransport: mediaTransport,
            ensurer: ensurer,
            mediaSecrets: mediaSecrets,
            secrets: secrets,
            goalEngine: goalEngine,
            goalStore: goalStore,
            goalConversations: goalConversations,
            goalsConfig: config.goals
        )
    }

    /// Registers the full built-in tool suite on the provided ToolBus.
    /// The single registration surface for built-in tools; callers that need a
    /// custom subset build from `makeTools`/`makeAllTools` and register directly.
    ///
    /// Desktop tools always register but arrive disabled: persisted
    /// tool-state rows re-apply via `restoreToolStates`, so a stock install
    /// never puts approval-free screen capture in front of the model at boot
    /// until the operator enables the tool-state toggle. Goal tools register only
    /// when both the engine and store arrive, and they arrive enabled even when
    /// `[goals]` is off so the honest disabled copy (not a bus-disabled line) answers.
    public static func registerAll(
        on bus: ToolBus,
        emailConfig: EmailConfig? = nil,
        filesConfig: FilesConfig? = nil,
        bashConfig: BashConfig = BashConfig(),
        sandboxConfig: SandboxConfig? = nil,
        browserConfig: BrowserConfig = BrowserConfig(),
        mediaConfig: MediaConfig? = nil,
        desktopConfig: DesktopConfig = DesktopConfig(),
        llmServerURLs: [String] = [],
        securityConfig: SecurityConfig = SecurityConfig(),
        memoryEngine: MemoryEngine? = nil,
        embedder: (any EmbeddingsBackend)? = nil,
        gateway: (any BrowserPlaywrightGateway)? = nil,
        searchTransport: (any WebSearchTransport)? = nil,
        fetchTransport: (any WebFetchTransport)? = nil,
        apiTransport: (any ApiRequestTransport)? = nil,
        mediaTransport: (any MediaArrTransport)? = nil,
        ensurer: (any SearXNGEnsuring)? = nil,
        mediaSecrets: SecretsManager? = nil,
        secrets: SecretsManager? = nil,
        desktopCaptureBridge: (any DesktopCapturing)? = nil,
        desktopControlBridge: (any DesktopControlling)? = nil,
        goalEngine: GoalEngine? = nil,
        goalStore: GoalStore? = nil,
        goalConversations: ConversationManager? = nil,
        goalsConfig: GoalsConfig = GoalsConfig(),
        messagesGateway: (any MessagesGateway)? = nil,
        chatDatabasePath: String = MessagesIndexer.defaultChatDatabasePath
    ) async {
        let desktopNames = Set(DesktopTools.allToolNames)
        for tool in makeAllTools(
            emailConfig: emailConfig,
            filesConfig: filesConfig,
            bashConfig: bashConfig,
            sandboxConfig: sandboxConfig,
            browserConfig: browserConfig,
            mediaConfig: mediaConfig,
            desktopConfig: desktopConfig,
            llmServerURLs: llmServerURLs,
            securityConfig: securityConfig,
            memoryEngine: memoryEngine,
            embedder: embedder,
            gateway: gateway,
            searchTransport: searchTransport,
            fetchTransport: fetchTransport,
            apiTransport: apiTransport,
            mediaTransport: mediaTransport,
            ensurer: ensurer,
            mediaSecrets: mediaSecrets,
            secrets: secrets,
            desktopCaptureBridge: desktopCaptureBridge,
            desktopControlBridge: desktopControlBridge,
            goalEngine: goalEngine,
            goalStore: goalStore,
            goalConversations: goalConversations,
            goalsConfig: goalsConfig,
            messagesGateway: messagesGateway,
            chatDatabasePath: chatDatabasePath
        ) {
            // Every other builtin keeps the enabled-by-default registration;
            // desktop tools ship disabled so only an operator-enabled tool
            // goes live (stored rows restore right after registration).
            await bus.register(tool: tool, isEnabled: !desktopNames.contains(tool.name))
        }
        if memoryEngine != nil {
            await MemoryTools.registerMemoryAliases(on: bus)
        }
    }
}

// Rune Weaver Tools — Built-in tool plugin registration surface.
//
// Single-sources the full built-in suite (Email, Messages, Files, Bash, Memory,
// Goals, Fan-out, Web, Browser, API, Media, Desktop) shared by CLI, the menu-bar app, and serve. `CLIShared.makeToolBus`,
// `AppModel`, and `ServerContext.make` all build through this helper so the
// registry cannot drift between entry points. Web, browser, and API tools run
// under one `[browser]` policy; `api.request` additionally exempts the
// configured LLM origins from the SSRF loopback deny. Goal tools register only
// when both the engine and store arrive (nil means unregistered); a disabled
// `[goals]` section still registers and fails closed inside each tool so the
// surface stays visible instead of shape-shifting. Fan-out tools follow the
// ships-disabled invariant: registration rides the optional fan-out engine
// (nil means unregistered), and the tool registers disabled behind the
// tool-state toggle like the desktop tools, so a stock install never puts
// parallel worker fan-out in front of the model until the operator enables it.
//
// `api.request` is the one exception to silent-nil defaults: the factory takes
// `policyStore:` (nil builds and loads the factory default) and fails the
// whole build closed when no verified policy is available, so no entry point
// can register an unsupervised egress tool.

import RuneWeaverCore

/// Shared built-in tool suites registered on every `ToolBus` by CLI, app, and serve.
public enum BuiltinToolPlugins {
    /// Tool names in registration order for the web/browser subset.
    public static var toolNames: [String] {
        WebTools.toolNames + BrowserTools.toolNames + ApiRequestTools.toolNames
    }

    /// All built-in tool names across every suite in registration order
    /// (email, messages, files, bash, memory, goals, web, browser, api, media, desktop, fanout).
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
            + FanOutTools.toolNames
    }

    /// Tool names that ship disabled on every fresh registration.
    ///
    /// The tool-state toggle is the sole authority for these capabilities: boot
    /// paths register them with `isEnabled: false`, persisted rows restore
    /// operator intent right after, and no config gate overrides that state. A
    /// stock install therefore never puts these tools in front of the model
    /// until the operator enables them. Every fresh-registration site consumes
    /// this set so the boot paths cannot drift.
    public static let shipsDisabledToolNames: Set<String> = Set(
        DesktopTools.allToolNames + FanOutTools.toolNames
    )

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
    ///   - policyStore: Shared security policy store. Nil constructs and loads
    ///     the factory default, which reads `~/.runeweaver/policy.toml`, seeds
    ///     safe deny-by-default defaults on first run, and fails closed when
    ///     the file cannot be verified.
    /// - Returns: Tools in registration order.
    /// - Throws: `PolicyInvariantError` when no verified policy is available;
    ///   an unsupervised `api.request` is never registered.
    public static func makeTools(
        browserConfig: BrowserConfig = BrowserConfig(),
        mediaConfig: MediaConfig? = nil,
        llmServerURLs: [String] = [],
        gateway: (any BrowserPlaywrightGateway)? = nil,
        searchTransport: (any WebSearchTransport)? = nil,
        fetchTransport: (any WebFetchTransport)? = nil,
        apiTransport: (any ApiRequestTransport)? = nil,
        ensurer: (any SearXNGEnsuring)? = nil,
        secrets: SecretsManager? = nil,
        policyStore: PolicyStore? = nil,
        egressSupervisor: OutboundEgressSupervisor? = nil
    ) async throws -> [any Tool] {
        // Resolve the one store first so the supervisor and the merged
        // origins read the same verified snapshot; an injected store stays
        // authoritative while nil loads the factory default with the retired
        // browser origins migrated once.
        let resolvedStore = await PolicyStore.makeLoaded(
            injected: policyStore,
            legacyLocalOrigins: browserConfig.allowedOrigins
        )
        let baseOrigins = ApiSSRFGuard.allowlistedOrigins(
            browserConfig: browserConfig,
            mediaConfig: mediaConfig,
            llmServerURLs: llmServerURLs
        )
        // Effective exemptions union the config-derived auto origins
        // (`searxng_url`, enabled media LAN URLs, LLM server URLs) with the
        // owner-declared local grants; never-exempt targets stay refused
        // inside the guard even when present in either set. The retired
        // `browser.allowed_origins` never feeds the base set; its sole
        // consumer is the `legacyLocalOrigins` migration above.
        let localExemptions: Set<String> = await (try? resolvedStore.snapshot().network.localExemptions) ?? []
        let mergedOrigins = baseOrigins.union(localExemptions)
        let supervisor: OutboundEgressSupervisor = if let egressSupervisor {
            egressSupervisor
        } else {
            try await makeEgressSupervisor(
                resolvedStore: resolvedStore,
                secrets: secrets,
                browserConfig: browserConfig,
                mediaConfig: mediaConfig,
                llmServerURLs: llmServerURLs
            )
        }
        return WebTools.makeTools(
            browserConfig: browserConfig,
            mediaConfig: mediaConfig,
            searchTransport: searchTransport,
            fetchTransport: fetchTransport,
            ensurer: ensurer,
            supervisor: supervisor,
            extraAllowlistedOrigins: mergedOrigins
        )
            + BrowserTools.makeTools(
                gateway: gateway,
                browserConfig: browserConfig,
                mediaConfig: mediaConfig,
                llmServerURLs: llmServerURLs,
                allowlistedOrigins: mergedOrigins,
                egressSupervisor: supervisor
            )
            + ApiRequestTools.makeTools(
                supervisor: supervisor,
                transport: apiTransport,
                browserConfig: browserConfig
            )
    }

    /// Builds the full built-in tool suite (Email, Messages, Files, Bash, Memory, Goals, Web, Browser, API, Media, Desktop, Fan-out)
    /// from component configurations.
    ///
    /// Goal tools join only when both the engine and store arrive; nil keeps them
    /// unregistered so callers without pursuit wiring see no shape change. A disabled
    /// `[goals]` section still registers through the same path and fails closed inside
    /// each tool, keeping `GET /tools` stable instead of shape-shifting with config.
    /// Fan-out tools follow the ships-disabled invariant: the tool joins only when
    /// the fan-out engine arrives (nil keeps it unregistered), and it registers
    /// disabled behind the tool-state toggle (see `shipsDisabledToolNames`) with
    /// no config gate overriding that state. The read-only subset the workers get derives from
    /// the built registry snapshot at this point, so the fan-out tool is appended
    /// after every other suite and the subset covers everything this install ships.
    /// - Parameter policyStore: Shared security policy store; nil builds and
    ///   loads the factory default. Either way exactly one store instance and
    ///   one egress supervisor back the `api.request` registration.
    /// - Parameter supersededReviewNotifier: Optional propagation hook the
    ///   serving process hands to `files.write` so a live write that
    ///   supersedes a staged review reaches connected dashboards; nil keeps
    ///   direct-core writers silent.
    /// - Parameter recipientAliasStore: Durable alias store the send tool
    ///   learns from after a resolved-name send; nil keeps alias learning off.
    /// - Throws: `PolicyInvariantError` when no verified policy is available.
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
        chatDatabasePath: String = MessagesIndexer.defaultChatDatabasePath,
        recipientAliasStore: (any MessageAliasStoring)? = nil,
        stagedFilesStore: StagedFilesStore? = nil,
        supersededReviewNotifier: (@Sendable (String) async -> Void)? = nil,
        fanOutEngine: FanOutEngine? = nil,
        policyStore: PolicyStore? = nil,
        egressSupervisor: OutboundEgressSupervisor? = nil
    ) async throws -> [any Tool] {
        // Resolve the one store first so exactly one instance backs this
        // build; the inner web/browser build reuses it instead of loading a
        // second default.
        let resolvedStore = await PolicyStore.makeLoaded(
            injected: policyStore,
            legacyLocalOrigins: browserConfig.allowedOrigins
        )
        let supervisor: OutboundEgressSupervisor = if let egressSupervisor {
            egressSupervisor
        } else {
            try await makeEgressSupervisor(
                resolvedStore: resolvedStore,
                secrets: secrets,
                browserConfig: browserConfig,
                mediaConfig: mediaConfig,
                llmServerURLs: llmServerURLs,
                emailConfig: emailConfig
            )
        }
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
        tools += MessagesTools.makeTools(
            chatDatabasePath: chatDatabasePath,
            gateway: messagesGateway,
            recipientAliasStore: recipientAliasStore
        )
        tools += FilesTools.makeTools(
            filesConfig: filesConfig ?? FilesConfig(),
            stagedFilesStore: stagedFilesStore,
            supersededReviewNotifier: supersededReviewNotifier
        )
        // Bash always registers so GET /tools stays stable; a disabled
        // config fails closed inside BashTool.execute via its enabled guard.
        tools.append(
            BashTool(
                bashConfig: bashConfig,
                filesConfig: filesConfig ?? FilesConfig(),
                egressSupervisor: supervisor
            )
        )
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
        tools += try await makeTools(
            browserConfig: browserConfig,
            mediaConfig: mediaConfig,
            llmServerURLs: llmServerURLs,
            gateway: gateway,
            searchTransport: searchTransport,
            fetchTransport: fetchTransport,
            apiTransport: apiTransport,
            ensurer: ensurer,
            secrets: secrets,
            policyStore: resolvedStore,
            egressSupervisor: supervisor
        )
        if let mediaConfig {
            tools += MediaTools.makeTools(mediaConfig: mediaConfig, transport: mediaTransport, secrets: mediaSecrets)
        }
        tools += DesktopTools.makeTools(
            desktopConfig: desktopConfig,
            captureBridge: desktopCaptureBridge,
            controlBridge: desktopControlBridge,
            egressSupervisor: supervisor
        )
        if let fanOutEngine {
            // The fan-out tool appends last so the read-only subset derives
            // from the complete built registry; external plugins discovered
            // later join workers only when the fanout policy widens to the
            // full live registry.
            tools += FanOutTools.makeTools(
                engine: fanOutEngine,
                conversations: goalConversations,
                allowedToolNames: FanOutEngine.readOnlyToolNames(in: tools)
            )
        }
        return tools
    }

    /// Convenience overload building all tools from a unified `RuneWeaverConfig`.
    /// - Parameter policyStore: Shared security policy store; nil builds and
    ///   loads the factory default.
    /// - Parameter recipientAliasStore: Durable alias store the send tool
    ///   learns from after a resolved-name send; nil keeps alias learning off.
    /// - Throws: `PolicyInvariantError` when no verified policy is available.
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
        goalConversations: ConversationManager? = nil,
        fanOutEngine: FanOutEngine? = nil,
        policyStore: PolicyStore? = nil,
        egressSupervisor: OutboundEgressSupervisor? = nil,
        recipientAliasStore: (any MessageAliasStoring)? = nil
    ) async throws -> [any Tool] {
        let appLLMOrigins = LLMOrigins.serverURLs(from: config.llm)
        return try await makeAllTools(
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
            goalsConfig: config.goals,
            recipientAliasStore: recipientAliasStore,
            fanOutEngine: fanOutEngine,
            policyStore: policyStore,
            egressSupervisor: egressSupervisor
        )
    }

    /// Registers the full built-in tool suite on the provided ToolBus.
    /// The single registration surface for built-in tools; callers that need a
    /// custom subset build from `makeTools`/`makeAllTools` and register directly.
    ///
    /// Capabilities in `shipsDisabledToolNames` always register but arrive
    /// disabled: persisted tool-state rows re-apply via `restoreToolStates`, so a
    /// stock install never puts screen capture or parallel worker fan-out in front
    /// of the model at boot until the operator enables the tool-state toggle. Goal
    /// tools register only when both the engine and store arrive, and they arrive
    /// enabled even when `[goals]` is off so the honest disabled copy (not a
    /// bus-disabled line) answers. Fan-out tools follow the same ships-disabled
    /// posture: they register only when the fan-out engine arrives, and they arrive
    /// disabled with the tool-state toggle as the sole authority — no second gate.
    /// - Parameter policyStore: Shared security policy store; nil builds and
    ///   loads the factory default before any tool registers, so a boot can
    ///   never leave an unsupervised `api.request` on the bus.
    /// - Parameter recipientAliasStore: Durable alias store the send tool
    ///   learns from after a resolved-name send; nil keeps alias learning off.
    /// - Throws: `PolicyInvariantError` when no verified policy is available.
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
        chatDatabasePath: String = MessagesIndexer.defaultChatDatabasePath,
        recipientAliasStore: (any MessageAliasStoring)? = nil,
        stagedFilesStore: StagedFilesStore? = nil,
        supersededReviewNotifier: (@Sendable (String) async -> Void)? = nil,
        fanOutEngine: FanOutEngine? = nil,
        policyStore: PolicyStore? = nil,
        egressSupervisor: OutboundEgressSupervisor? = nil
    ) async throws {
        let shipsDisabled = Self.shipsDisabledToolNames
        for tool in try await makeAllTools(
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
            chatDatabasePath: chatDatabasePath,
            recipientAliasStore: recipientAliasStore,
            stagedFilesStore: stagedFilesStore,
            supersededReviewNotifier: supersededReviewNotifier,
            fanOutEngine: fanOutEngine,
            policyStore: policyStore,
            egressSupervisor: egressSupervisor
        ) {
            // Every other builtin keeps the enabled-by-default registration;
            // capabilities in `shipsDisabledToolNames` ship disabled so only an
            // operator-enabled tool goes live (stored rows restore right after
            // registration).
            await bus.register(tool: tool, isEnabled: !shipsDisabled.contains(tool.name))
        }
    }

    /// Builds the mandatory egress supervisor from the already-resolved store.
    ///
    /// Callers resolve the one store first via `PolicyStore.makeLoaded` so the
    /// supervisor and the merged origins read the same verified snapshot and
    /// exactly one store instance backs the build. The supervisor factory
    /// re-verifies the snapshot, so no unsupervised registry is built.
    /// - Throws: `PolicyInvariantError` when the store holds no verified policy.
    private static func makeEgressSupervisor(
        resolvedStore: PolicyStore,
        secrets: SecretsManager?,
        browserConfig: BrowserConfig,
        mediaConfig: MediaConfig?,
        llmServerURLs: [String],
        emailConfig: EmailConfig? = nil
    ) async throws -> OutboundEgressSupervisor {
        try await OutboundEgressSupervisor.make(
            policyStore: resolvedStore,
            secrets: secrets,
            browserConfig: browserConfig,
            mediaConfig: mediaConfig,
            emailConfig: emailConfig,
            llmServerURLs: llmServerURLs
        )
    }
}

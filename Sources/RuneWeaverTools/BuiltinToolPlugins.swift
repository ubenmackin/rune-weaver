// Rune Weaver Tools — Built-in tool plugin registration surface.

import RuneWeaverCore

/// Shared built-in tool suites registered on every `ToolBus` by CLI, app, and serve.
public enum BuiltinToolPlugins {
    /// Tool names that ship disabled on every fresh registration. A stock install therefore never
    /// puts these tools in front of the model until the operator enables them.
    public static let shipsDisabledToolNames: Set<String> = Set(
        DesktopTools.allToolNames + FanOutTools.toolNames
    )

    /// Builds the full built-in tool suite (Email, Messages, Calendar, Reminders, Files, Bash,
    /// Memory, Goals, Web, Browser, API, Media, Desktop, Fan-out) from component configurations.
    public static func makeAllTools(
        emailConfig: EmailConfig? = nil,
        filesConfig: FilesConfig? = nil,
        bashConfig: BashConfig = BashConfig(),
        containersConfig: ContainersConfig? = nil,
        browserConfig: BrowserConfig = BrowserConfig(),
        mediaConfig: MediaConfig? = nil,
        desktopConfig: DesktopConfig = DesktopConfig(),
        llmServerURLs: [String] = [],
        securityConfig: SecurityConfig = SecurityConfig(),
        memoryEngine: MemoryEngine? = nil,
        embedder: any EmbeddingsBackend? = nil,
        gateway: any BrowserPlaywrightGateway? = nil,
        searchTransport: any WebSearchTransport? = nil,
        fetchTransport: any WebFetchTransport? = nil,
        apiTransport: any ApiRequestTransport? = nil,
        mediaTransport: any MediaArrTransport? = nil,
        ensurer: any SearXNGEnsuring? = nil,
        mediaSecrets: SecretsManager? = nil,
        secrets: SecretsManager? = nil,
        desktopCaptureBridge: any DesktopCapturing? = nil,
        desktopControlBridge: any DesktopControlling? = nil,
        goalEngine: GoalEngine? = nil,
        goalStore: GoalStore? = nil,
        goalConversations: ConversationManager? = nil,
        goalsConfig: GoalsConfig = GoalsConfig(),
        goalUpdatedNotifier: (@Sendable (Goal, [GoalStep]) async -> Void)? = nil,
        messagesGateway: any MessagesGateway? = nil,
        calendarGateway: any CalendarGateway? = nil,
        remindersGateway: any RemindersGateway? = nil,
        chatDatabasePath: String = MessagesIndexer.defaultChatDatabasePath,
        recipientAliasStore: any MessageAliasStoring? = nil,
        scheduledSendBooking: any ScheduledSendBooking? = nil,
        stagedFilesStore: StagedFilesStore? = nil,
        supersededReviewNotifier: (@Sendable (String) async -> Void)? = nil,
        fanOutEngine: FanOutEngine? = nil,
        policyStore: PolicyStore? = nil,
        egressSupervisor: OutboundEgressSupervisor? = nil,
        workspaceConfig: WorkspaceConfig = WorkspaceConfig(),
        workspaceStore: WorkspaceStore? = nil
    ) async throws -> [any Tool] {
        // Resolve the one store first so exactly one instance backs this
        // build; the inner web/browser build reuses it instead of loading a
        // second default.
        let resolvedStore = await PolicyStore.makeLoaded(
            injected: policyStore
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
        let resolvedContainers = containersConfig ?? ContainersConfig()
        await StrictTurnRegistry.shared.applyContainersConfig(resolvedContainers)
        let sharedLedger = await StrictTurnRegistry.shared.ephemeralLedger
        let containerSeam = ContainerSeam(
            containersConfig: resolvedContainers,
            strictRegistry: StrictTurnRegistry.shared,
            ephemeralLedger: sharedLedger
        )
        var tools: [any Tool] = makeLeadingTools(
            resolvedContainers: resolvedContainers,
            sharedLedger: sharedLedger,
            emailConfig: emailConfig,
            filesConfig: filesConfig,
            securityConfig: securityConfig,
            messagesGateway: messagesGateway,
            chatDatabasePath: chatDatabasePath,
            calendarGateway: calendarGateway,
            remindersGateway: remindersGateway,
            stagedFilesStore: stagedFilesStore,
            recipientAliasStore: recipientAliasStore,
            scheduledSendBooking: scheduledSendBooking,
            supersededReviewNotifier: supersededReviewNotifier
        )
        // Bash always registers so GET /tools stays stable; a disabled config fails closed inside
        // BashTool.execute via its enabled guard.
        let sharedWorkspace = workspaceStore ?? WorkspaceStore(config: workspaceConfig)
        let bashTool = BashTool(
            bashConfig: bashConfig,
            filesConfig: filesConfig ?? FilesConfig(),
            allowUnsandboxedFallback: false,
            egressSupervisor: supervisor,
            workspaceConfig: workspaceConfig,
            workspaceStore: sharedWorkspace,
            containers: containerSeam
        )
        tools.append(bashTool)
        tools.append(QuestionAskTool())
        if let memoryEngine {
            tools += MemoryTools.makeTools(engine: memoryEngine, embedder: embedder)
        }
        if let goalEngine, let goalStore {
            tools += GoalTools.makeTools(
                engine: goalEngine,
                store: goalStore,
                conversations: goalConversations,
                goalsConfig: goalsConfig,
                goalUpdatedNotifier: goalUpdatedNotifier
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
            // The fan-out tool appends last so the read-only subset derives from the complete built
            // registry; external plugins discovered later join workers only when the fanout policy
            // widens to the full live registry.
            tools += FanOutTools.makeTools(
                engine: fanOutEngine,
                conversations: goalConversations,
                allowedToolNames: FanOutEngine.readOnlyToolNames(in: tools)
            )
        }
        return tools
    }

    /// Convenience overload building all tools from a unified `RuneWeaverConfig`.
    /// - Parameter policyStore: Shared security policy store; nil builds and loads the factory default.
    public static func makeAllTools(
        config: RuneWeaverConfig,
        memoryEngine: MemoryEngine? = nil,
        embedder: any EmbeddingsBackend? = nil,
        gateway: any BrowserPlaywrightGateway? = nil,
        searchTransport: any WebSearchTransport? = nil,
        fetchTransport: any WebFetchTransport? = nil,
        apiTransport: any ApiRequestTransport? = nil,
        mediaTransport: any MediaArrTransport? = nil,
        ensurer: any SearXNGEnsuring? = nil,
        mediaSecrets: SecretsManager? = nil,
        secrets: SecretsManager? = nil,
        goalEngine: GoalEngine? = nil,
        goalStore: GoalStore? = nil,
        goalConversations: ConversationManager? = nil,
        fanOutEngine: FanOutEngine? = nil,
        policyStore: PolicyStore? = nil,
        egressSupervisor: OutboundEgressSupervisor? = nil,
        recipientAliasStore: any MessageAliasStoring? = nil,
        scheduledSendBooking: any ScheduledSendBooking? = nil,
        workspaceStore: WorkspaceStore? = nil,
        calendarGateway: any CalendarGateway? = nil,
        remindersGateway: any RemindersGateway? = nil
    ) async throws -> [any Tool] {
        let appLLMOrigins = LLMOrigins.serverURLs(from: config.llm)
        return try await makeAllTools(
            emailConfig: config.email,
            filesConfig: config.files,
            bashConfig: config.bash,
            containersConfig: config.containers,
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
            calendarGateway: calendarGateway,
            remindersGateway: remindersGateway,
            recipientAliasStore: recipientAliasStore,
            scheduledSendBooking: scheduledSendBooking,
            fanOutEngine: fanOutEngine,
            policyStore: policyStore,
            egressSupervisor: egressSupervisor,
            workspaceConfig: config.workspace,
            workspaceStore: workspaceStore
        )
    }

    /// Registers the full built-in tool suite on the provided ToolBus. The single registration
    /// surface for built-in tools; callers that need a custom subset build from
    /// `makeTools`/`makeAllTools` and register directly.
    public static func registerAll(
        on bus: ToolBus,
        emailConfig: EmailConfig? = nil,
        filesConfig: FilesConfig? = nil,
        bashConfig: BashConfig = BashConfig(),
        containersConfig: ContainersConfig? = nil,
        browserConfig: BrowserConfig = BrowserConfig(),
        mediaConfig: MediaConfig? = nil,
        desktopConfig: DesktopConfig = DesktopConfig(),
        llmServerURLs: [String] = [],
        securityConfig: SecurityConfig = SecurityConfig(),
        memoryEngine: MemoryEngine? = nil,
        embedder: any EmbeddingsBackend? = nil,
        gateway: any BrowserPlaywrightGateway? = nil,
        searchTransport: any WebSearchTransport? = nil,
        fetchTransport: any WebFetchTransport? = nil,
        apiTransport: any ApiRequestTransport? = nil,
        mediaTransport: any MediaArrTransport? = nil,
        ensurer: any SearXNGEnsuring? = nil,
        mediaSecrets: SecretsManager? = nil,
        secrets: SecretsManager? = nil,
        desktopCaptureBridge: any DesktopCapturing? = nil,
        desktopControlBridge: any DesktopControlling? = nil,
        goalEngine: GoalEngine? = nil,
        goalStore: GoalStore? = nil,
        goalConversations: ConversationManager? = nil,
        goalsConfig: GoalsConfig = GoalsConfig(),
        goalUpdatedNotifier: (@Sendable (Goal, [GoalStep]) async -> Void)? = nil,
        messagesGateway: any MessagesGateway? = nil,
        calendarGateway: any CalendarGateway? = nil,
        remindersGateway: any RemindersGateway? = nil,
        chatDatabasePath: String = MessagesIndexer.defaultChatDatabasePath,
        recipientAliasStore: any MessageAliasStoring? = nil,
        scheduledSendBooking: any ScheduledSendBooking? = nil,
        stagedFilesStore: StagedFilesStore? = nil,
        supersededReviewNotifier: (@Sendable (String) async -> Void)? = nil,
        fanOutEngine: FanOutEngine? = nil,
        policyStore: PolicyStore? = nil,
        egressSupervisor: OutboundEgressSupervisor? = nil,
        workspaceConfig: WorkspaceConfig = WorkspaceConfig(),
        workspaceStore: WorkspaceStore? = nil
    ) async throws {
        let shipsDisabled = Self.shipsDisabledToolNames
        for tool in try await makeAllTools(
            emailConfig: emailConfig,
            filesConfig: filesConfig,
            bashConfig: bashConfig,
            containersConfig: containersConfig,
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
            goalUpdatedNotifier: goalUpdatedNotifier,
            messagesGateway: messagesGateway,
            calendarGateway: calendarGateway,
            remindersGateway: remindersGateway,
            chatDatabasePath: chatDatabasePath,
            recipientAliasStore: recipientAliasStore,
            scheduledSendBooking: scheduledSendBooking,
            stagedFilesStore: stagedFilesStore,
            supersededReviewNotifier: supersededReviewNotifier,
            fanOutEngine: fanOutEngine,
            policyStore: policyStore,
            egressSupervisor: egressSupervisor,
            workspaceConfig: workspaceConfig,
            workspaceStore: workspaceStore
        ) {
            // Every other builtin keeps the enabled-by-default registration; capabilities in
            // `shipsDisabledToolNames` ship disabled so only an operator-enabled tool goes live
            // (stored rows restore right after registration).
            await bus.register(tool: tool, isEnabled: !shipsDisabled.contains(tool.name))
        }
    }
}

// MARK: - Web / Browser Tool Suite

extension BuiltinToolPlugins {
    /// Builds the shared five-tool set for one `[browser]` policy. browserConfig:
    /// `[browser]` policy feeding search, fetch, and API tools.
    public static func makeTools(
        browserConfig: BrowserConfig = BrowserConfig(),
        mediaConfig: MediaConfig? = nil,
        llmServerURLs: [String] = [],
        gateway: any BrowserPlaywrightGateway? = nil,
        searchTransport: any WebSearchTransport? = nil,
        fetchTransport: any WebFetchTransport? = nil,
        apiTransport: any ApiRequestTransport? = nil,
        ensurer: any SearXNGEnsuring? = nil,
        secrets: SecretsManager? = nil,
        policyStore: PolicyStore? = nil,
        egressSupervisor: OutboundEgressSupervisor? = nil
    ) async throws -> [any Tool] {
        // Resolve the one store first so the supervisor and the merged
        // origins read the same verified snapshot; an injected store stays
        // authoritative while nil loads the factory default.
        let resolvedStore = await PolicyStore.makeLoaded(
            injected: policyStore
        )
        let baseOrigins = ApiSSRFGuard.allowlistedOrigins(
            browserConfig: browserConfig,
            mediaConfig: mediaConfig,
            llmServerURLs: llmServerURLs
        )
        // Effective exemptions union the config-derived auto origins
        // (`searxng_url`, enabled media LAN URLs, LLM server URLs) with the
        let localExemptions: Set<String>
        do {
            localExemptions = try await resolvedStore.snapshot().network.localExemptions
        } catch {
            RuneWeaverLog.tools.warning("BuiltinToolPlugins: failed to read policy store snapshot for network exemptions: \(error.localizedDescription)")
            localExemptions = []
        }
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
            gateway: gateway,
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
}

extension BuiltinToolPlugins {
    /// Tool names in registration order for the web/browser subset.
    public static var toolNames: [String] {
        WebTools.toolNames + BrowserTools.toolNames + ApiRequestTools.toolNames
    }

    /// All built-in tool names across every suite in registration order
    /// (email, messages, calendar, reminders, files, bash, memory, goals, web, browser, api, media, desktop, fanout).
    public static var allToolNames: [String] {
        EmailTools.toolNames
            + MessagesTools.toolNames
            + CalendarTools.toolNames
            + RemindersTools.toolNames
            + FilesTools.toolNames
            + ["bash.exec"]
            + MemoryTools.toolNames
            + GoalTools.toolNames
            + toolNames
            + MediaTools.toolNames
            + DesktopTools.allToolNames
            + FanOutTools.toolNames
    }

    /// Builds the leading suites (Email, Messages, Calendar, Reminders, Files) in registration order.
    private static func makeLeadingTools(
        resolvedContainers: ContainersConfig,
        sharedLedger: EphemeralContainerLedger,
        emailConfig: EmailConfig? = nil,
        filesConfig: FilesConfig? = nil,
        securityConfig: SecurityConfig = SecurityConfig(),
        messagesGateway: any MessagesGateway? = nil,
        chatDatabasePath: String = MessagesIndexer.defaultChatDatabasePath,
        calendarGateway: any CalendarGateway? = nil,
        remindersGateway: any RemindersGateway? = nil,
        stagedFilesStore: StagedFilesStore? = nil,
        recipientAliasStore: any MessageAliasStoring? = nil,
        scheduledSendBooking: any ScheduledSendBooking? = nil,
        supersededReviewNotifier: (@Sendable (String) async -> Void)? = nil
    ) -> [any Tool] {
        var tools: [any Tool] = []
        if let emailConfig {
            // Forward the same `[files]` policy the Files tools use so the
            // email attachment export path enforces one policy, not defaults.
            tools += EmailTools.makeTools(
                emailConfig: emailConfig,
                containersConfig: resolvedContainers,
                filesConfig: filesConfig ?? FilesConfig(),
                ephemeralLedger: sharedLedger,
                securityConfig: securityConfig,
                booking: scheduledSendBooking
            )
        }
        tools += MessagesTools.makeTools(
            chatDatabasePath: chatDatabasePath,
            gateway: messagesGateway,
            recipientAliasStore: recipientAliasStore,
            booking: scheduledSendBooking
        )
        // Calendar and reminders resolve nil to the shared production default: a single live
        // EventKit store on EventKit platforms, fail-closed unavailable elsewhere.
        #if canImport(EventKit)
            // One shared instance backs both gateways so calendar and reminders never mint separate
            // system stores.
            let sharedLiveStore = LiveEventKitStore()
            let effectiveCalendarGateway = calendarGateway ?? ProductionCalendarGateway(store: sharedLiveStore)
            let effectiveRemindersGateway = remindersGateway ?? ProductionRemindersGateway(store: sharedLiveStore)
        #else
            let effectiveCalendarGateway = calendarGateway ?? ProductionCalendarGateway(store: UnavailableEventKitStore())
            let effectiveRemindersGateway = remindersGateway ?? ProductionRemindersGateway(store: UnavailableEventKitStore())
        #endif
        tools += CalendarTools.makeTools(gateway: effectiveCalendarGateway)
        tools += RemindersTools.makeTools(gateway: effectiveRemindersGateway)
        tools += FilesTools.makeTools(
            filesConfig: filesConfig ?? FilesConfig(),
            stagedFilesStore: stagedFilesStore,
            supersededReviewNotifier: supersededReviewNotifier
        )
        return tools
    }

    /// Builds the mandatory egress supervisor from the already-resolved store. - Throws:
    /// `PolicyInvariantError` when the store holds no verified policy.
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

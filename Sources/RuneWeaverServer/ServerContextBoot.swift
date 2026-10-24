// Rune Weaver Server — Server context boot and factory wiring.

import Foundation
import RuneWeaverCore
import RuneWeaverTools
import Vapor

// MARK: - Factory and Bootstrapping

extension ServerContext {
    private struct ServerBootstrapServices: Sendable {
        let approvals: ApprovalQueue
        let durable: DurableServerStores
        let bus: ToolBus
        let goalStore: GoalStore
        let goalEngine: GoalEngine
        let ideasStore: IdeasStore
        let ideasEngine: IdeasEngine?
        let pluginStack: ResolvedPluginStack
    }

    private struct ToolConfigs: Sendable {
        let email: EmailConfig?
        let files: FilesConfig
        let bash: BashConfig
        let containers: ContainersConfig
        let browser: BrowserConfig
        let media: MediaConfig?
        let desktop: DesktopConfig
        let llmServerURLs: [String]
        let security: SecurityConfig
        let goals: GoalsConfig
        let workspace: WorkspaceConfig
    }

    private struct GoalComponents: Sendable {
        let engine: GoalEngine
        let store: GoalStore
        let conversations: ConversationManager
    }

    private struct ToolTransports: Sendable {
        let gateway: any BrowserPlaywrightGateway?
        let search: any WebSearchTransport?
        let fetch: any WebFetchTransport?
        let api: any ApiRequestTransport?
        let media: any MediaArrTransport?
        let ensurer: any SearXNGEnsuring?
        let mediaSecrets: SecretsManager?
        let secrets: SecretsManager?
        let desktopCapture: any DesktopCapturing?
        let desktopControl: any DesktopControlling?
    }

    private struct RuntimeEngineArgs: Sendable {
        let conversations: ConversationManager
        let bus: ToolBus
        let llm: any LLMProvider
        let systemPrompt: String?
        let engineConfig: EngineConfig
        let memoryEngine: MemoryEngine
        let approvals: ApprovalQueue
        let permissionGate: PermissionGate
        let embedder: any EmbeddingsBackend?
        let securityConfig: SecurityConfig
        /// Recall budgets bounding automatic recall fan-out. Carries the
        /// clamped `[memory] recall_*` values from config so headless and
        /// served turns inject with file config instead of defaults.
        let recallBudgets: RecallBudgets
        let durable: DurableServerStores
        let notifier: any SchedulerNotifier?
        let indexCoordinator: IndexCoordinator?
        let goalStore: GoalStore
        let goalEngine: GoalEngine
        /// Proactive suggestion engine, or nil when `[ideas]` is disabled.
        let ideasEngine: IdeasEngine?
        /// Interruption policy from `[proactive]` so the worker gate matches file config.
        let proactiveConfig: ProactiveConfig
        let fanOutConfig: FanOutConfig
        let activeTurns: ActiveTurnTracker
        let persona: PersonaConfig
    }

    /// Boot-time configuration resolved before durable stores open.
    private struct BootstrapConfig: Sendable {
        let scheduler: SchedulerConfig
        let episodesDBPath: String?
        let plugins: PluginConfig
        let goals: GoalsConfig
        let ideas: IdeasConfig
    }

    private static func bootstrapServices(
        permissionGate: PermissionGate,
        config: BootstrapConfig,
        llm: any LLMProvider,
        memoryEngine: MemoryEngine,
        runs: RunLogStore? = nil,
        hub: WSHub? = nil,
        secrets: SecretsManager? = nil
    ) async -> ServerBootstrapServices {
        let approvals = ApprovalQueue(permissionGate: permissionGate)
        let durable = await loadDurableServerStores(
            schedulerConfig: config.scheduler,
            episodesDBPath: config.episodesDBPath,
            runs: runs,
            hub: hub
        )
        let bus = ToolBus(permissionGate: permissionGate)
        let resolvedGoalDBPath = config.episodesDBPath ?? MemoryConfig.defaultEpisodesDBPath
        let goalStore = GoalStore(dbPath: resolvedGoalDBPath)
        // Ideas share the goals database and the serving provider; the engine
        // stays nil while `[ideas]` is disabled so a stock install never spends
        // a background review call.
        let ideasStore = IdeasStore(dbPath: goalStore.dbPath)
        let ideasEngine: IdeasEngine? = if config.ideas.enabled {
            IdeasEngine(
                store: ideasStore,
                llm: llm,
                config: config.ideas,
                memoryFacts: { await memoryEngine.getUserProfile().facts.map(\.content) }
            )
        } else {
            nil
        }
        let planReporter = ServerGoalPlanReporter(runs: durable.runs, hub: durable.hub)
        let goalEngine = GoalEngine(
            store: goalStore,
            llm: llm,
            config: config.goals,
            ideasEngine: ideasEngine,
            reporter: planReporter
        )
        let pluginStack = await resolvePluginStack(
            episodesDBPath: config.episodesDBPath,
            pluginConfig: config.plugins,
            bus: bus,
            secrets: secrets
        )
        return ServerBootstrapServices(
            approvals: approvals,
            durable: durable,
            bus: bus,
            goalStore: goalStore,
            goalEngine: goalEngine,
            ideasStore: ideasStore,
            ideasEngine: ideasEngine,
            pluginStack: pluginStack
        )
    }

    private struct BuiltinToolArgs: Sendable {
        let bus: ToolBus
        let configs: ToolConfigs
        let transports: ToolTransports
        let memoryEngine: MemoryEngine
        let embedder: any EmbeddingsBackend?
        let goals: GoalComponents
        let stagedFiles: StagedFilesStore
        /// Workspace store backing the shell default directory and quota gate.
        let workspaceStore: WorkspaceStore?
        /// Propagation hook reporting a live write that superseded a staged
        /// review, so the serve process broadcasts `file_superseded` to live
        /// dashboards; nil keeps the tool silent.
        let supersededReviewNotifier: (@Sendable (String) async -> Void)?
        /// Hook reporting goal state updates so live dashboards receive real-time goal_updated broadcasts.
        let goalUpdatedNotifier: (@Sendable (Goal, [GoalStep]) async -> Void)?
        /// Fan-out engine riding the live orchestrator, or nil when the
        /// caller did not wire one (the fanout.run tool then stays
        /// unregistered, mirroring the goal-tools invariant).
        let fanOutEngine: FanOutEngine?
        /// Booking seam storing approved scheduled sends for the send tools, or
        /// nil when no firing worker owns the rows (direct-core contexts keep
        /// scheduleAt failing closed with guidance).
        let scheduledSendBooking: any ScheduledSendBooking?
        /// The one policy store for this process, shared by the supervisor
        /// built for `api.request` and the settings policy routes.
        let policyStore: PolicyStore
        /// Mandatory egress supervisor backing runtime domain triage and dynamic allows.
        let egressSupervisor: OutboundEgressSupervisor?
    }

    private static func registerBuiltinTools(_ args: BuiltinToolArgs) async throws {
        try await BuiltinToolPlugins.registerAll(
            on: args.bus,
            emailConfig: args.configs.email,
            filesConfig: args.configs.files,
            bashConfig: args.configs.bash,
            containersConfig: args.configs.containers,
            browserConfig: args.configs.browser,
            mediaConfig: args.configs.media,
            desktopConfig: args.configs.desktop,
            llmServerURLs: args.configs.llmServerURLs,
            securityConfig: args.configs.security,
            memoryEngine: args.memoryEngine,
            embedder: args.embedder,
            gateway: args.transports.gateway,
            searchTransport: args.transports.search,
            fetchTransport: args.transports.fetch,
            apiTransport: args.transports.api,
            mediaTransport: args.transports.media,
            ensurer: args.transports.ensurer,
            mediaSecrets: args.transports.mediaSecrets,
            secrets: args.transports.secrets,
            desktopCaptureBridge: args.transports.desktopCapture,
            desktopControlBridge: args.transports.desktopControl,
            goalEngine: args.goals.engine,
            goalStore: args.goals.store,
            goalConversations: args.goals.conversations,
            goalsConfig: args.configs.goals,
            goalUpdatedNotifier: args.goalUpdatedNotifier,
            scheduledSendBooking: args.scheduledSendBooking,
            stagedFilesStore: args.stagedFiles,
            supersededReviewNotifier: args.supersededReviewNotifier,
            fanOutEngine: args.fanOutEngine,
            policyStore: args.policyStore,
            egressSupervisor: args.egressSupervisor,
            workspaceConfig: args.configs.workspace,
            workspaceStore: args.workspaceStore
        )
    }

    private struct RuntimeEngines: Sendable {
        let orchestrator: Orchestrator
        let schedulerWorker: ServerSchedulerWorker
        let steeringQueue: SteeringQueue
        let fanOutEngine: FanOutEngine
    }

    private static func makeExecutionEngines(
        args: RuntimeEngineArgs
    ) -> RuntimeEngines {
        let steeringQueue = SteeringQueue()
        let orchestrator = Orchestrator(
            conversations: args.conversations,
            toolBus: args.bus,
            llm: args.llm,
            systemPrompt: args.systemPrompt,
            maxToolIterations: args.engineConfig.maxToolIterations,
            memoryEngine: args.memoryEngine,
            approvalQueue: args.approvals,
            embedder: args.embedder,
            compactionThresholdPercent: args.engineConfig.compactionThresholdPercent,
            steeringQueue: steeringQueue,
            securityConfig: args.securityConfig,
            permissionGate: args.permissionGate,
            recallBudgets: args.recallBudgets,
            persona: args.persona
        )
        // The serving provider doubles as the guarded judge so file mode plus
        // judge travel together from boot instead of defaulting to surfacing all.
        let schedulerWorker = ServerSchedulerWorker(
            scheduler: args.durable.scheduler,
            runs: args.durable.runs,
            hub: args.durable.hub,
            runLock: args.durable.runLock,
            orchestrator: orchestrator,
            conversations: args.conversations,
            toolBus: args.bus,
            approvals: args.approvals,
            notifier: args.notifier,
            indexCoordinator: args.indexCoordinator,
            goalStore: args.goalStore,
            goalEngine: args.goalEngine,
            ideasEngine: args.ideasEngine,
            activeTurns: args.activeTurns,
            proactiveConfig: args.proactiveConfig,
            judgeLLM: args.llm
        )
        // Fan-out resolves over the shared orchestrator and run-log store so workers observe the
        // same model posture as chat, with the serving provider as the background reviewer.
        let fanOutEngine = FanOutEngine(
            orchestrator: orchestrator,
            runLogs: FanOutRunLogAdapter(runs: args.durable.runs, hub: args.durable.hub),
            config: args.fanOutConfig,
            reviewer: args.llm
        )
        return RuntimeEngines(
            orchestrator: orchestrator,
            schedulerWorker: schedulerWorker,
            steeringQueue: steeringQueue,
            fanOutEngine: fanOutEngine
        )
    }

    /// Derives the configured-service egress candidates for the boot supervisor.
    static func configuredServiceEgressCandidates(
        browser: BrowserConfig,
        media: MediaConfig?,
        email: EmailConfig?
    ) -> [String] {
        RuneWeaverConfig.serviceEgressCandidates(browser: browser, media: media, email: email)
    }

    private static func setupEgressAndPolicy(
        policyStore: PolicyStore,
        toolConfigs: ToolConfigs,
        secrets: SecretsManager?,
        permissionGate: PermissionGate
    ) async throws -> OutboundEgressSupervisor {
        let serviceCandidates = Self.configuredServiceEgressCandidates(
            browser: toolConfigs.browser,
            media: toolConfigs.media,
            email: toolConfigs.email
        )
        await policyStore.ensureServiceDomainsAllowed(urlsOrHosts: serviceCandidates)

        let egressSupervisor = try await OutboundEgressSupervisor.make(
            policyStore: policyStore,
            secrets: secrets,
            browserConfig: toolConfigs.browser,
            mediaConfig: toolConfigs.media,
            emailConfig: toolConfigs.email,
            llmServerURLs: toolConfigs.llmServerURLs
        )
        await permissionGate.setEgressEvaluator(egressSupervisor)
        // Durable egress allows and task grants live in the gate, so the
        // supervisor consults them during validation and a covered next call
        // stays auto-approved at execution as well as at the gate.
        await egressSupervisor.setPermissionGate(permissionGate)
        return egressSupervisor
    }

    private struct ToolRegistrationArgs: Sendable {
        let services: ServerBootstrapServices
        let configs: ToolConfigs
        let transports: ToolTransports
        let memoryEngine: MemoryEngine
        let embedder: any EmbeddingsBackend?
        let goals: GoalComponents
        let stagedFiles: StagedFilesStore
        let workspaceStore: WorkspaceStore
        let fanOutEngine: FanOutEngine
        let policyStore: PolicyStore
        let secrets: SecretsManager?
        let permissionGate: PermissionGate
    }

    /// Sets up egress supervision, re-evaluates plugins, and registers all builtin tools.
    private static func registerAllTools(_ args: ToolRegistrationArgs) async throws -> OutboundEgressSupervisor {
        let egressSupervisor = try await setupEgressAndPolicy(
            policyStore: args.policyStore, toolConfigs: args.configs,
            secrets: args.secrets, permissionGate: args.permissionGate
        )
        // Early rescan registered bridges without supervision, so refresh the
        // evaluator and re-register before serving network-capable tools.
        args.services.pluginStack.discovery.updateEgressEvaluator(egressSupervisor)
        _ = await args.services.pluginStack.discovery.discoverAndSync(toolBus: args.services.bus)
        try await registerBuiltinTools(BuiltinToolArgs(
            bus: args.services.bus, configs: args.configs, transports: args.transports,
            memoryEngine: args.memoryEngine, embedder: args.embedder,
            goals: args.goals, stagedFiles: args.stagedFiles,
            workspaceStore: args.workspaceStore,
            supersededReviewNotifier: makeStagedSupersedeNotifier(hub: args.services.durable.hub),
            goalUpdatedNotifier: { [hub = args.services.durable.hub] goal, steps in
                await hub.broadcastGoal(GoalDTO(goal: goal, steps: steps))
            },
            fanOutEngine: args.fanOutEngine,
            scheduledSendBooking: SchedulerStoreBookingAdapter(store: args.services.durable.scheduler),
            policyStore: args.policyStore,
            egressSupervisor: egressSupervisor
        ))
        return egressSupervisor
    }

    /// Resolves the sovereign ledger for boot, preloading its signing key.
    /// Keeps the fresh-install versus injected choice beside boot wiring.
    private static func resolveSovereignLedger(
        sovereignLedger: SovereignLedger?,
        dbPath: String,
        secrets: SecretsManager?
    ) async throws -> SovereignLedger {
        let ledger = Self.resolveLedger(sovereignLedger, dbPath: dbPath, secrets: secrets)
        do {
            try await ledger.preloadSigningKey()
        } catch {
            // localizedDescription carries the authored reason whose remedy
            // already matches the failure class, so no unconditional remedy
            // is appended here.
            throw Abort(.internalServerError, reason: "Sovereign signing key unavailable: \(error.localizedDescription)")
        }
        return ledger
    }

    /// Prepares the scratch workspace root before any shell turn runs.
    /// Failures stay best-effort with a log; the quota gate still fails closed.
    private static func prepareWorkspaceStore(
        workspaceStore: WorkspaceStore?,
        workspaceConfig: WorkspaceConfig,
        permissionGate: PermissionGate
    ) async -> WorkspaceStore {
        let store = workspaceStore ?? WorkspaceStore(config: workspaceConfig)
        await permissionGate.updateWorkspaceRoot(store.root())
        do {
            _ = try await store.ensure()
            _ = try await store.pruneTmp()
        } catch {
            RuneWeaverLog.server.warning("ServerContext: workspace boot skipped: \(error.localizedDescription)")
        }
        return store
    }

    private struct WebPushComponents: Sendable {
        let keys: WebPushKeys
        let subscriptions: PushSubscriptionStore
        let sender: WebPushSender
        let combinedNotifier: any SchedulerNotifier
        let combinedApprovalHandler: (@Sendable (PermissionRequest) async -> Void)?
    }

    /// Prepares VAPID keys, subscription persistence, Web Push sender, and combined alert handlers.
    private static func prepareWebPush(
        secrets: SecretsManager?,
        dbPath: String,
        notifier: any SchedulerNotifier?,
        onApprovalRequested: (@Sendable (PermissionRequest) async -> Void)?,
        notificationsBox: NotificationsConfigBox = NotificationsConfigBox()
    ) async throws -> WebPushComponents {
        let vapidKeys = try await WebPushKeys.loadOrGenerate(secrets: secrets)
        let pushSubscriptions = PushSubscriptionStore(dbPath: dbPath)
        let pushTransport: any WebPushTransport = ProcessInfo.processInfo.environment["RUNEWEAVER_HERMETIC_TESTS"] == "1"
            ? NoOpWebPushTransport()
            : URLSessionWebPushTransport()
        let pushSender = WebPushSender(vapidKeys: vapidKeys, subscriptions: pushSubscriptions, transport: pushTransport)
        let combinedNotifier = CompositeSchedulerNotifier(
            primary: notifier,
            pushSender: pushSender,
            notificationsBox: notificationsBox
        )
        let combinedApprovalHandler: (@Sendable (PermissionRequest) async -> Void)? = { request in
            guard NotificationsFilter.shouldSurface(.approvalRequested, config: notificationsBox.current) else { return }
            if let onApprovalRequested {
                await onApprovalRequested(request)
            }
            let label = request.assessment?.severity.rawValue ?? "unknown"
            await pushSender.broadcast(
                payload: WebPushSender.PushPayload(
                    title: "Action Requires Attention",
                    body: "Tool \(request.toolName) Severity: \(label). Decide in Inbox.",
                    url: "/#approvals",
                    tag: "approval-\(request.id.uuidString)"
                )
            )
        }
        return WebPushComponents(
            keys: vapidKeys,
            subscriptions: pushSubscriptions,
            sender: pushSender,
            combinedNotifier: combinedNotifier,
            combinedApprovalHandler: combinedApprovalHandler
        )
    }

    /// Builds a context wired for live approval prompts over WebSocket.
    /// - Parameter policyStore: The one security policy store for this process.
    public static func make(
        config: ServerConfig = .default,
        conversations: ConversationManager,
        memoryEngine: MemoryEngine,
        embedder: any EmbeddingsBackend? = nil,
        permissionGate: PermissionGate,
        llm: any LLMProvider,
        systemPrompt: String? = nil,
        schedulerConfig: SchedulerConfig = .empty,
        episodesDBPath: String? = nil,
        pluginConfig: PluginConfig = PluginConfig(),
        notifier: any SchedulerNotifier? = nil,
        onApprovalRequested: (@Sendable (PermissionRequest) async -> Void)? = nil,
        containersConfig: ContainersConfig = ContainersConfig(),
        browserConfig: BrowserConfig = BrowserConfig(),
        indexCoordinator: IndexCoordinator? = nil,
        indexStore: DocIndexStore? = nil,
        llmServerURLs: [String] = [],
        engineConfig: EngineConfig = EngineConfig(),
        emailConfig: EmailConfig? = nil,
        filesConfig: FilesConfig = FilesConfig(),
        bashConfig: BashConfig = BashConfig(),
        mediaConfig: MediaConfig? = nil,
        desktopConfig: DesktopConfig = DesktopConfig(),
        securityConfig: SecurityConfig = SecurityConfig(),
        recallBudgets: RecallBudgets = RecallBudgets(),
        goalsConfig: GoalsConfig = GoalsConfig(),
        ideasConfig: IdeasConfig = IdeasConfig(),
        proactiveConfig: ProactiveConfig = ProactiveConfig(),
        auth: ServerAuth? = nil,
        fanOutConfig: FanOutConfig = FanOutConfig(),
        browserGateway: any BrowserPlaywrightGateway? = nil,
        searchTransport: any WebSearchTransport? = nil,
        fetchTransport: any WebFetchTransport? = nil,
        apiTransport: any ApiRequestTransport? = nil,
        mediaTransport: any MediaArrTransport? = nil,
        searchEnsurer: any SearXNGEnsuring? = nil,
        mediaSecrets: SecretsManager? = nil,
        secrets: SecretsManager? = nil,
        desktopCaptureBridge: any DesktopCapturing? = nil,
        desktopControlBridge: any DesktopControlling? = nil,
        runs: RunLogStore? = nil,
        hub: WSHub? = nil,
        policyStore: PolicyStore? = nil,
        workspaceConfig: WorkspaceConfig = WorkspaceConfig(),
        workspaceStore: WorkspaceStore? = nil,
        persona: PersonaConfig = PersonaConfig(),
        watchdog: BehaviorWatchdog? = nil,
        sovereignLedger: SovereignLedger? = nil,
        onboarding: any OnboardingStoring? = nil,
        notificationsConfig: NotificationsConfig = NotificationsConfig()
    ) async throws -> ServerContext {
        // Resolve the one store for this process before any tool registers: an injected store is
        // authoritative, while the factory default is loaded here so the same instance feeds both
        // the egress supervisor and the settings policy routes.
        let resolvedPolicyStore = await PolicyStore.makeLoaded(
            injected: policyStore
        )
        await permissionGate.updateBashConfig(bashConfig)
        // The gate owns the write posture ahead of the tool, so the served
        // `[files]` policy reaches it here: a `write_mode` change then behaves
        // identically in the verdict and in the tool that executes the call.
        await permissionGate.updateFilesConfig(filesConfig)
        let resolvedWorkspaceStore = await prepareWorkspaceStore(
            workspaceStore: workspaceStore, workspaceConfig: workspaceConfig, permissionGate: permissionGate
        )
        let services = await bootstrapServices(
            permissionGate: permissionGate,
            config: BootstrapConfig(
                scheduler: schedulerConfig, episodesDBPath: episodesDBPath, plugins: pluginConfig,
                goals: goalsConfig, ideas: ideasConfig
            ),
            llm: llm,
            memoryEngine: memoryEngine,
            runs: runs,
            hub: hub,
            secrets: secrets
        )
        let toolConfigs = ToolConfigs(
            email: emailConfig, files: filesConfig, bash: bashConfig, containers: containersConfig,
            browser: browserConfig, media: mediaConfig, desktop: desktopConfig,
            llmServerURLs: llmServerURLs, security: securityConfig, goals: goalsConfig,
            workspace: workspaceConfig
        )
        let transports = ToolTransports(
            gateway: browserGateway, search: searchTransport, fetch: fetchTransport,
            api: apiTransport, media: mediaTransport, ensurer: searchEnsurer,
            mediaSecrets: mediaSecrets, secrets: secrets,
            desktopCapture: desktopCaptureBridge, desktopControl: desktopControlBridge
        )
        let goalComponents = GoalComponents(
            engine: services.goalEngine, store: services.goalStore, conversations: conversations
        )
        let dbPath = episodesDBPath ?? (MemoryConfig.defaultEpisodesDBPath as NSString).expandingTildeInPath
        let stagedFilesStore = StagedFilesStore(dbPath: dbPath)
        let resolvedSovereignLedger = try await resolveSovereignLedger(sovereignLedger: sovereignLedger, dbPath: dbPath, secrets: secrets)
        // Execution engines build before tool registration so the fan-out engine can ride the live
        // orchestrator into the fanout.run tool; engine construction is side-effect free, so the
        // earlier position changes nothing else about boot.
        let activeTurns = ActiveTurnTracker()
        let notificationsBox = NotificationsConfigBox(notificationsConfig)
        let webPush = try await prepareWebPush(
            secrets: secrets,
            dbPath: dbPath,
            notifier: notifier,
            onApprovalRequested: onApprovalRequested,
            notificationsBox: notificationsBox
        )
        let engines = makeExecutionEngines(args: RuntimeEngineArgs(
            conversations: conversations, bus: services.bus, llm: llm,
            systemPrompt: systemPrompt, engineConfig: engineConfig,
            memoryEngine: memoryEngine, approvals: services.approvals,
            permissionGate: permissionGate, embedder: embedder,
            securityConfig: securityConfig, recallBudgets: recallBudgets.clamped(),
            durable: services.durable, notifier: webPush.combinedNotifier,
            indexCoordinator: indexCoordinator, goalStore: services.goalStore,
            goalEngine: services.goalEngine, ideasEngine: services.ideasEngine,
            proactiveConfig: proactiveConfig, fanOutConfig: fanOutConfig,
            activeTurns: activeTurns, persona: persona
        ))
        let egressSupervisor = try await registerAllTools(ToolRegistrationArgs(
            services: services, configs: toolConfigs, transports: transports,
            memoryEngine: memoryEngine, embedder: embedder, goals: goalComponents,
            stagedFiles: stagedFilesStore, workspaceStore: resolvedWorkspaceStore,
            fanOutEngine: engines.fanOutEngine, policyStore: resolvedPolicyStore,
            secrets: secrets, permissionGate: permissionGate
        ))

        let context = ServerContext(
            config: config, conversations: conversations, toolBus: services.bus, orchestrator: engines.orchestrator,
            memoryEngine: memoryEngine, embedder: embedder, permissionGate: permissionGate, approvals: services.approvals,
            scheduler: services.durable.scheduler, runs: services.durable.runs, hub: services.durable.hub, runLock: services.durable.runLock,
            activeTurns: activeTurns, steeringQueue: engines.steeringQueue, schedulerWorker: engines.schedulerWorker,
            pluginStore: services.pluginStack.store, pluginDiscovery: services.pluginStack.discovery,
            pluginConfig: pluginConfig, toolStates: services.pluginStack.states,
            containersConfig: containersConfig, filesConfig: toolConfigs.files, bashConfig: toolConfigs.bash, browserConfig: browserConfig,
            indexCoordinator: indexCoordinator, indexStore: indexStore, servingLLM: llm, auth: auth, browserGateway: browserGateway,
            searchTransport: searchTransport, fetchTransport: fetchTransport, apiTransport: apiTransport, mediaTransport: mediaTransport,
            searchEnsurer: searchEnsurer, mediaSecrets: mediaSecrets, secrets: secrets,
            desktopCaptureBridge: desktopCaptureBridge, desktopControlBridge: desktopControlBridge, desktopConfig: desktopConfig,
            goals: services.goalStore, goalEngine: services.goalEngine, goalsConfig: goalsConfig, ideas: services.ideasStore,
            ideasEngine: services.ideasEngine, ideasConfig: ideasConfig, proactiveConfig: proactiveConfig, stagedFiles: stagedFilesStore,
            fanOut: engines.fanOutEngine, policyStore: resolvedPolicyStore, egressSupervisor: egressSupervisor,
            mediaConfig: toolConfigs.media, emailConfig: toolConfigs.email, llmServerURLs: toolConfigs.llmServerURLs,
            workspaceConfig: workspaceConfig, workspaceStore: resolvedWorkspaceStore,
            notifier: webPush.combinedNotifier,
            persona: persona,
            watchdog: watchdog, sovereignLedger: resolvedSovereignLedger,
            onboarding: onboarding ?? OnboardingStore(dbPath: dbPath),
            approvalDecisions: ApprovalDecisionLogStore(dbPath: dbPath),
            pushSubscriptions: webPush.subscriptions,
            webPushSender: webPush.sender
        )
        // Await the verified-pulse wiring before serving so early tool calls
        // observe watchdog counts and goal/policy changes invalidate the
        // shared answer cache from the first turn.
        await context.wireVerifiedPulseAsync(goalEngine: services.goalEngine)
        await finalizeServerContext(context, containersConfig: containersConfig, onApprovalRequested: webPush.combinedApprovalHandler)
        return context
    }

    /// Ephemeral fallback context used if Application.runeWeaver is queried before configuration.
    public static let fallbackUnconfigured: ServerContext = {
        let gate = PermissionGate(ruleStore: InMemoryAccessRuleStore())
        let bus = ToolBus(permissionGate: gate)
        let conv = ConversationManager()
        let mem = MemoryEngine(config: MemoryConfig())
        struct FallbackDummyLLM: LLMProvider {
            let modelInfo = ModelInfo(name: "dummy", provider: "dummy", contextLength: 2048)
            func chat(messages _: [Message], tools _: [any Tool]) -> AsyncStream<LLMResponse> {
                AsyncStream { $0.finish() }
            }

            func embeddings(text _: [String]) async throws -> [[Float]] {
                []
            }
        }
        let steering = SteeringQueue()
        let appq = ApprovalQueue(permissionGate: gate)
        let orch = Orchestrator(
            conversations: conv,
            toolBus: bus,
            llm: FallbackDummyLLM(),
            approvalQueue: appq,
            steeringQueue: steering,
            permissionGate: gate
        )
        return ServerContext(
            conversations: conv,
            toolBus: bus,
            orchestrator: orch,
            memoryEngine: mem,
            permissionGate: gate,
            approvals: appq,
            steeringQueue: steering,
            emailConfig: nil,
            onboarding: ThrowingOnboardingStore(dbPath: ":memory:")
        )
    }()
}

/// Reclaims crash-orphaned containers once at boot so restarts never inherit leaked guests.
/// The periodic lifecycle keeps pressure bounded afterwards; only aggregate counts reach the audit trail.
private func reclaimOrphanedContainers(config: ContainersConfig, approvals: ApprovalQueue) async {
    let bootSummary = await SandboxCleaner.cleanup(config: config, approvals: approvals)
    FileSandboxAuditLog.append(bootSummary)
}

/// Installs the live approval prompt path as the backstop for direct bus executions. Broadcasts
/// each filed request and waits with a timeout, keeping the bus wiring single-sourced for boot.
private func installLiveApprovalHandler(
    bus: ToolBus,
    approvals: ApprovalQueue,
    hub: WSHub,
    workspaceStore: WorkspaceStore,
    onApprovalRequested: (@Sendable (PermissionRequest) async -> Void)?
) async {
    let handlerApprovals = approvals
    let handlerHub = hub
    let handlerWorkspace = workspaceStore
    await bus.setApprovalHandler { tool, call, toolContext in
        // Two-phase filing path: file the pending request immediately with a nil assessment so the
        // inbox renders without awaiting the model, then broadcast and wait with a timeout.
        let owningSession = toolContext.conversationID
        let bashSnapshot = (tool as? BashTool)?.bashConfig
        let workspaceSnapshot = await handlerWorkspace.root()
        let request = await handlerApprovals.fileRequest(
            tool: tool,
            call: call,
            sessionID: owningSession,
            onEnriched: { updated in
                await handlerHub.broadcastApproval(updated)
                if let onApprovalRequested {
                    await onApprovalRequested(updated)
                }
            },
            bashConfig: bashSnapshot,
            workspaceRoot: workspaceSnapshot
        )
        await handlerHub.broadcastApproval(request)
        if let onApprovalRequested {
            await onApprovalRequested(request)
        }
        let decision = await handlerApprovals.waitForDecision(id: request.id)
        return decision.approved
    }
}

/// Durable boot collaborators hydrated together so `make` carries one bundle instead of four locals.
/// Keeps scheduler hydration single-sourced while staying within the tuple arity limit.
private struct DurableServerStores: Sendable {
    /// Scheduler job registry hydrated from SQLite or the bootstrap seed.
    let scheduler: SchedulerStore
    /// Run audit trail for chat turns and scheduler firings.
    let runs: RunLogStore
    /// Live sockets receiving approval broadcasts.
    let hub: WSHub
    /// Single-flight lock for scheduler job runs within this service process.
    let runLock: SchedulerRunLock
}

/// Plugin persistence plus discovery resolved together so restarts reuse the same registry directory.
/// Bundles the registry collaborators under one name to keep toggle restores single-sourced in `make`.
private struct ResolvedPluginStack: Sendable {
    /// Durable plugin registry store tracking discovered runes.
    let store: ToolRegistryStore
    /// Durable per-tool enable/disable toggles for every registered tool.
    let states: ToolStateStore
    /// Service discovering and syncing plugins from disk.
    let discovery: PluginDiscoveryService
}

/// Loads durable scheduler and run stores off the cooperative pool so actor init never blocks on
/// SQLite. Groups the four independent boot collaborators so durable hydration stays single-sourced.
private func loadDurableServerStores(
    schedulerConfig: SchedulerConfig,
    episodesDBPath: String?,
    runs: RunLogStore? = nil,
    hub: WSHub? = nil
) async -> DurableServerStores {
    let scheduler = await SchedulerStore.load(from: schedulerConfig, dbPath: episodesDBPath)
    let resolvedRuns = if let runs {
        runs
    } else {
        await RunLogStore.load(dbPath: episodesDBPath)
    }
    let resolvedHub = hub ?? WSHub()
    return DurableServerStores(scheduler: scheduler, runs: resolvedRuns, hub: resolvedHub, runLock: SchedulerRunLock())
}

/// Resolves plugin persistence plus discovery so restarts reuse the same registry directory.
/// Runs the optional rescan against the live bus, keeping toggle restores single-sourced in `make`.
private func resolvePluginStack(
    episodesDBPath: String?,
    pluginConfig: PluginConfig,
    bus: ToolBus,
    secrets: SecretsManager? = nil,
    egressEvaluator: any EgressPolicyEvaluator? = nil
) async -> ResolvedPluginStack {
    let resolvedDBPath = episodesDBPath ?? (MemoryConfig.defaultEpisodesDBPath as NSString).expandingTildeInPath
    let pStore = ToolRegistryStore(dbPath: resolvedDBPath)
    let tStates = ToolStateStore(dbPath: resolvedDBPath)
    let pluginsURL = URL(fileURLWithPath: (pluginConfig.pluginsDir as NSString).expandingTildeInPath)
    let pDiscovery = PluginDiscoveryService(
        pluginsDirectory: pluginsURL,
        store: pStore,
        secrets: secrets,
        egressEvaluator: egressEvaluator,
        toolStates: tStates
    )
    if pluginConfig.autoRescan {
        _ = await pDiscovery.discoverAndSync(toolBus: bus)
    }
    return ResolvedPluginStack(store: pStore, states: tStates, discovery: pDiscovery)
}

/// Wires live approval prompts and restores persisted tool toggles on a built context.
private func finalizeServerContext(
    _ context: ServerContext,
    containersConfig: ContainersConfig,
    onApprovalRequested: (@Sendable (PermissionRequest) async -> Void)?
) async {
    await reclaimOrphanedContainers(config: containersConfig, approvals: context.approvals)
    await installLiveApprovalHandler(
        bus: context.toolBus,
        approvals: context.approvals,
        hub: context.hub,
        workspaceStore: context.workspaceStore,
        onApprovalRequested: onApprovalRequested
    )
    if let onApprovalRequested {
        await context.orchestrator.setOnApprovalRequested(onApprovalRequested)
    }
    // System-notice filings broadcast from inside the queue's insert hop through this hook, so a
    // settle racing a filing can never strand a phantom notice card behind a late caller-side frame.
    let noticeHub = context.hub
    await context.approvals.setOnNoticeFiled { request in
        await noticeHub.broadcastApproval(request)
    }
    // Stored toggles win over fresh registration defaults so restarts
    // restore operator intent; tools registered after `make` (builtin
    // plugins in the serve path) re-apply via `restoreToolStates`.
    await context.restoreToolStates()
    // Reconcile active goals that completed all actionable steps, so restarts
    // never leave 1/1 finished goals in active status or re-fire them on scheduled ticks.
    do {
        let reconciled = try await context.goalEngine.reconcileActiveGoalsCompletion()
        if !reconciled.isEmpty {
            for goalID in reconciled {
                do {
                    guard let goal = try await context.goals.goal(id: goalID) else { continue }
                    let steps = try await context.goals.steps(goalID: goalID)
                    await context.hub.broadcastGoal(GoalDTO(goal: goal, steps: steps))
                } catch is CancellationError {
                    break
                } catch {
                    RuneWeaverLog.server.warning("ServerContext: failed to load reconciled goal \(goalID): \(error.localizedDescription)")
                }
            }
        }
    } catch {
        RuneWeaverLog.server.warning("ServerContext: boot goal reconciliation failed: \(error.localizedDescription)")
    }
    let hub = context.hub
    await LlamaEmbeddingSupervisor.shared.setStatusHandler { status, message, error in
        await hub.broadcastEmbeddingsStatus(status: status, message: message, error: error)
    }
    // Warm fills the 60s TTL snapshot so the first dashboard poll finds slow fields cached.
    let store = context.indexStore
    Task(priority: .utility) {
        do {
            _ = try await store?.storageBreakdown()
        } catch {
            RuneWeaverLog.server.debug("ServerContext: index storage warm skipped: \(error.localizedDescription)")
        }
    }
}

/// Storage key for the shared ``ServerContext``.
private struct ServerContextKey: StorageKey {
    /// Stored context type.
    typealias Value = ServerContext
}

extension Application {
    /// Shared engine context for every route. A missing configuration logs and serves an ephemeral
    /// fallback so one misconfigured route cannot crash the process; routes needing a strict 500 use
    /// `requireRuneWeaver()` instead.
    var runeWeaver: ServerContext {
        get {
            if let context = storage[ServerContextKey.self] {
                return context
            }
            RuneWeaverLog.server.error("Application.runeWeaver: ServerContext not configured. Call configureRuneWeaver(_:context:) before serving.")
            return ServerContext.fallbackUnconfigured
        }
        set {
            storage[ServerContextKey.self] = newValue
        }
    }

    /// Strict accessor failing closed with a 500 when unconfigured.
    /// - Returns: Configured context.
    /// - Throws: 500 Abort when no context was stored.
    func requireRuneWeaver() throws -> ServerContext {
        guard let context = storage[ServerContextKey.self] else {
            RuneWeaverLog.server.error("Application.requireRuneWeaver: ServerContext not configured. Call configureRuneWeaver(_:context:) before serving.")
            throw Abort(.internalServerError, reason: "ServerContext not configured.")
        }
        return context
    }
}

// Rune Weaver Server — Server execution context and bootstrap wiring.
//
// Holds shared engine collaborators, orchestrator, tools, and background workers
// for the HTTP and WebSocket API service.

import Foundation
import os
import RuneWeaverCore
import RuneWeaverTools
import Vapor

/// Live document index pair swapped by settings saves without a restart.
private struct LiveIndexPair: Sendable {
    /// Document store backing status, prune, and reset, or nil when unwired.
    var store: DocIndexStore?
    /// Coordinator sequencing the enabled source stages, or nil when unwired.
    var coordinator: IndexCoordinator?
}

/// Atomic shell plus workspace policy pair refreshed by settings saves.
/// Bash carries the working-directory guard from the files policy, so the two
/// must move together: a split write would let a fresh bash tool enforce a
/// stale allow-root set (or vice versa) for the window between writes.
private struct BashFilesPair: Sendable {
    /// Shell execution policy carrying enablement, rules, and timeouts.
    var bash: BashConfig
    /// Workspace access policy bounding reads and the bash guard.
    var files: FilesConfig
}

/// Stand-in provider for goal engine defaults when no serving model is wired.
/// Direct contexts in tests often pass no `servingLLM`; planning through this
/// backend yields no text so the engine keeps its resilient fallback plan
/// instead of failing creation.
private struct DefaultGoalLLM: LLMProvider, Sendable {
    /// Stable placeholder model metadata.
    let modelInfo = ModelInfo(name: "goal-default", provider: "test", contextLength: 2048)

    /// Returns an immediately finished empty stream.
    func chat(messages _: [Message], tools _: [any Tool]) -> AsyncStream<LLMResponse> {
        AsyncStream { $0.finish() }
    }

    /// Unused embeddings stub.
    func embeddings(text _: [String]) async throws -> [[Float]] {
        []
    }
}

/// Shared engine collaborators held in Vapor application storage.
public final class ServerContext: Sendable {
    /// Loopback binding plus port.
    public let config: ServerConfig
    /// Session and history owner.
    public let conversations: ConversationManager
    /// Tool registry consulted for model-requested calls.
    public let toolBus: ToolBus
    /// Core orchestration loop serving chat turns.
    public let orchestrator: Orchestrator
    /// Three-tier memory serving search and facts.
    public let memoryEngine: MemoryEngine
    /// Optional embeddings producer for vector-ranked memory routes.
    public let embedder: (any EmbeddingsBackend)?
    /// Graduated-trust gate backing approvals.
    public let permissionGate: PermissionGate
    /// Pending approval prompts shared by REST and WebSocket.
    public let approvals: ApprovalQueue
    /// Scheduler job registry.
    public let scheduler: SchedulerStore
    /// Run audit trail for chat turns and scheduler firings.
    public let runs: RunLogStore
    /// Live sockets receiving approval broadcasts.
    public let hub: WSHub
    /// Single-flight lock for scheduler job runs within this service process.
    public let runLock: SchedulerRunLock
    /// Active in-flight chat turn tasks for cancellation.
    public let activeTurns: ActiveTurnTracker
    /// Pending mid-turn steering queue for active multi-round turns.
    public let steeringQueue: SteeringQueue
    /// In-process background scheduler worker.
    public let schedulerWorker: ServerSchedulerWorker
    /// Durable plugin registry store tracking discovered runes.
    public let pluginStore: ToolRegistryStore
    /// Service discovering and syncing plugins from disk.
    public let pluginDiscovery: PluginDiscoveryService
    /// Durable per-tool enable/disable toggles for every registered tool.
    public let toolStates: ToolStateStore
    /// Staged files metadata store tracking edited files awaiting review.
    public let stagedFiles: StagedFilesStore
    /// Sandbox staging retention configuration bounding `pending/`, `approved/`, and `attachments/`.
    public let sandboxConfig: SandboxConfig
    /// Atomic bash plus files policy pair refreshed by settings saves.
    /// One lock covers both so concurrent readers never observe a fresh bash
    /// policy beside a stale files guard (or vice versa) mid-save, mirroring
    /// `liveIndexBox`.
    private let bashFilesBox: OSAllocatedUnfairLock<BashFilesPair>
    /// Live `[files]` access policy bounding read/write operations.
    /// Settings PUTs refresh it in place so saved deny patterns, allow
    /// roots, and approval escalation take effect without a restart.
    public var filesConfig: FilesConfig {
        get { bashFilesBox.withLock { $0.files } }
        set { bashFilesBox.withLock { $0.files = newValue } }
    }

    /// Live `[bash]` shell execution policy carrying enablement, default
    /// action, ordered rules, timeout, and network knobs. Settings PUTs
    /// refresh it in place so saved values take effect without a restart.
    public var bashConfig: BashConfig {
        get { bashFilesBox.withLock { $0.bash } }
        set { bashFilesBox.withLock { $0.bash = newValue } }
    }

    /// Periodic scheduler reclaiming expired and over-cap staged files.
    public let sandboxCleanup: SandboxCleanupScheduler
    /// Browser policy carrying the SearXNG base URL for the search lifecycle routes.
    public let browserConfig: BrowserConfig
    /// Durable goal registry backing steady advancement and the goal routes.
    public let goals: GoalStore
    /// Pursuit engine composing advancement prompts and bumping due dates.
    /// Shares the serving provider so planning observes the same model
    /// posture as chat turns instead of minting a second backend.
    public let goalEngine: GoalEngine
    /// Durable proactive idea registry backing the `/ideas` routes.
    public let ideas: IdeasStore
    /// Proactive suggestion engine composing the ideas store with the serving
    /// provider, or nil when `[ideas]` is disabled. Shares the serving provider
    /// so suggestion quality tracks the active model posture; the engine never
    /// mints its own backend.
    public let ideasEngine: IdeasEngine?
    /// Active chat provider backing vision description for live index rebuilds.
    /// Stored at boot so a settings save can resolve the vision stage the same
    /// way boot does without reaching back into the orchestrator.
    public let servingLLM: (any LLMProvider)?
    /// Live document index pair. Held behind a lock because settings PUTs swap
    /// the store and coordinator in place while this class stays Sendable,
    /// mirroring `desktopConfigBox`.
    private let liveIndexBox: OSAllocatedUnfairLock<LiveIndexPair>
    /// Local document index coordinator backing the `/index` routes, or nil when
    /// indexing is not wired. Swapped live by settings saves without a restart.
    /// Read-only by design: the store and coordinator always move as one
    /// generation through `setLiveIndex`, and readers needing both together
    /// use `liveIndexSnapshot`, so no caller can land a half-swapped pair.
    public var indexCoordinator: IndexCoordinator? {
        liveIndexBox.withLock { $0.coordinator }
    }

    /// Local document index store backing status, prune, and reset, or nil when
    /// indexing is not wired. Swapped live by settings saves without a restart.
    /// Read-only by design: the store and coordinator always move as one
    /// generation through `setLiveIndex`, and readers needing both together
    /// use `liveIndexSnapshot`, so no caller can land a half-swapped pair.
    public var indexStore: DocIndexStore? {
        liveIndexBox.withLock { $0.store }
    }

    /// Owner bearer verifier, or nil for the no-auth loopback posture.
    public let auth: ServerAuth?
    /// Shared Playwright gateway reused across browser live-reloads so a settings PUT
    /// refreshes allowlisted origins without dropping the managed bridge or test doubles.
    public let browserGateway: (any BrowserPlaywrightGateway)?
    /// Hermetic search transport preserved across live-reloads.
    public let searchTransport: (any WebSearchTransport)?
    /// Hermetic fetch transport preserved across live-reloads.
    public let fetchTransport: (any WebFetchTransport)?
    /// Hermetic API transport preserved across live-reloads.
    public let apiTransport: (any ApiRequestTransport)?
    /// Hermetic media transport preserved across live-reloads.
    public let mediaTransport: (any MediaArrTransport)?
    /// Search lifecycle ensurer preserved across live-reloads.
    public let searchEnsurer: (any SearXNGEnsuring)?
    /// Media secrets resolver preserved across live-reloads so injected doubles survive.
    public let mediaSecrets: SecretsManager?
    /// Shared secrets backing surrogate resolution preserved across live-reloads.
    public let secrets: SecretsManager?
    /// Hermetic desktop capture bridge preserved across live-reloads so a
    /// settings PUT refreshes capture knobs without dropping test doubles.
    public let desktopCaptureBridge: (any DesktopCapturing)?
    /// Hermetic desktop control bridge preserved across live-reloads so a
    /// settings PUT refreshes control knobs without dropping test doubles.
    public let desktopControlBridge: (any DesktopControlling)?
    /// Live `[desktop]` capture policy. Held behind a lock because
    /// settings PUTs refresh it in place while this class stays Sendable.
    private let desktopConfigBox: OSAllocatedUnfairLock<DesktopConfig>
    /// Live `[desktop]` policy carrying capture knobs (dimensions, quality,
    /// blocklist). Enablement flows solely through the tool-state toggle.
    public var desktopConfig: DesktopConfig {
        get { desktopConfigBox.withLock { $0 } }
        set { desktopConfigBox.withLock { $0 = newValue } }
    }

    /// Creates a server context.
    /// The `steeringQueue` must be the identical instance handed to
    /// `orchestrator` at its creation: routes enqueue through the context
    /// while the turn loop dequeues through the orchestrator, so a mismatched
    /// pair accepts steering yet never delivers it. Prefer `make`, which wires
    /// one shared queue into both; direct callers sharing a queue by hand can
    /// verify with `await orchestrator.sharedSteeringQueue === steeringQueue`.
    /// - Precondition: When the orchestrator was built with a steering queue,
    ///   the queue passed here is that same instance (identity, not equality).
    ///   An orchestrator built without a queue leaves steering inert.
    public init(
        config: ServerConfig = .default,
        conversations: ConversationManager,
        toolBus: ToolBus,
        orchestrator: Orchestrator,
        memoryEngine: MemoryEngine,
        embedder: (any EmbeddingsBackend)? = nil,
        permissionGate: PermissionGate,
        approvals: ApprovalQueue,
        scheduler: SchedulerStore = SchedulerStore(),
        runs: RunLogStore = RunLogStore(),
        hub: WSHub = WSHub(),
        runLock: SchedulerRunLock = SchedulerRunLock(),
        activeTurns: ActiveTurnTracker = ActiveTurnTracker(),
        steeringQueue: SteeringQueue = SteeringQueue(),
        schedulerWorker: ServerSchedulerWorker? = nil,
        pluginStore: ToolRegistryStore? = nil,
        pluginDiscovery: PluginDiscoveryService? = nil,
        toolStates: ToolStateStore? = nil,
        sandboxConfig: SandboxConfig = SandboxConfig(),
        sandboxCleanup: SandboxCleanupScheduler? = nil,
        filesConfig: FilesConfig = FilesConfig(),
        bashConfig: BashConfig = BashConfig(),
        browserConfig: BrowserConfig = BrowserConfig(),
        indexCoordinator: IndexCoordinator? = nil,
        indexStore: DocIndexStore? = nil,
        servingLLM: (any LLMProvider)? = nil,
        auth: ServerAuth? = nil,
        browserGateway: (any BrowserPlaywrightGateway)? = nil,
        searchTransport: (any WebSearchTransport)? = nil,
        fetchTransport: (any WebFetchTransport)? = nil,
        apiTransport: (any ApiRequestTransport)? = nil,
        mediaTransport: (any MediaArrTransport)? = nil,
        searchEnsurer: (any SearXNGEnsuring)? = nil,
        mediaSecrets: SecretsManager? = nil,
        secrets: SecretsManager? = nil,
        desktopCaptureBridge: (any DesktopCapturing)? = nil,
        desktopControlBridge: (any DesktopControlling)? = nil,
        desktopConfig: DesktopConfig = DesktopConfig(),
        goals: GoalStore? = nil,
        goalEngine: GoalEngine? = nil,
        goalsConfig: GoalsConfig = GoalsConfig(),
        ideas: IdeasStore? = nil,
        ideasEngine: IdeasEngine? = nil,
        ideasConfig: IdeasConfig = IdeasConfig(),
        proactiveConfig: ProactiveConfig = ProactiveConfig(),
        stagedFiles: StagedFilesStore? = nil
    ) {
        self.config = config
        self.conversations = conversations
        self.toolBus = toolBus
        self.orchestrator = orchestrator
        self.memoryEngine = memoryEngine
        self.embedder = embedder
        self.permissionGate = permissionGate
        self.approvals = approvals
        self.scheduler = scheduler
        self.runs = runs
        self.hub = hub
        self.runLock = runLock
        self.activeTurns = activeTurns
        self.steeringQueue = steeringQueue
        let defaultDBPath = (MemoryConfig.defaultEpisodesDBPath as NSString).expandingTildeInPath
        // Goals resolve before the worker so the default worker below can
        // carry them; an explicit worker still wins untouched for tests that
        // hand-build one without goals.
        let resolvedGoals = goals ?? GoalStore(dbPath: defaultDBPath)
        // Ideas default over the same `episodes.db` as goals so one database
        // carries both; an explicit store wins untouched. The engine is built
        // only when `[ideas]` is enabled and no explicit engine was handed in,
        // so a disabled install stays inert without spending provider memory.
        let resolvedIdeas = ideas ?? IdeasStore(dbPath: resolvedGoals.dbPath)
        let resolvedIdeasEngine: IdeasEngine? = if let ideasEngine {
            ideasEngine
        } else if ideasConfig.enabled {
            // Facts come from the live memory engine so suggestions observe the
            // owner's profile; capturing the actor is Sendable and the closure
            // only reads, never mutates.
            IdeasEngine(
                store: resolvedIdeas,
                llm: servingLLM ?? DefaultGoalLLM(),
                config: ideasConfig,
                memoryFacts: { await memoryEngine.getUserProfile().facts.map(\.content) }
            )
        } else {
            nil
        }
        let resolvedEngine: GoalEngine = if let goalEngine {
            goalEngine
        } else if let servingLLM {
            GoalEngine(store: resolvedGoals, llm: servingLLM, config: goalsConfig, ideasEngine: resolvedIdeasEngine)
        } else {
            GoalEngine(store: resolvedGoals, llm: DefaultGoalLLM(), config: goalsConfig, ideasEngine: resolvedIdeasEngine)
        }
        self.goals = resolvedGoals
        self.goalEngine = resolvedEngine
        self.ideas = resolvedIdeas
        self.ideasEngine = resolvedIdeasEngine
        // The interruption gate rides the stored `[proactive]` policy with the
        // serving provider as its guarded judge; an explicit worker still wins
        // untouched for tests that hand-build one without goals.
        self.schedulerWorker = schedulerWorker ?? ServerSchedulerWorker(
            scheduler: scheduler,
            runs: runs,
            hub: hub,
            runLock: runLock,
            orchestrator: orchestrator,
            conversations: conversations,
            toolBus: toolBus,
            indexCoordinator: indexCoordinator,
            goalStore: resolvedGoals,
            goalEngine: resolvedEngine,
            ideasEngine: resolvedIdeasEngine,
            proactiveConfig: proactiveConfig,
            judgeLLM: servingLLM
        )
        let pStore = pluginStore ?? ToolRegistryStore(dbPath: defaultDBPath)
        self.pluginStore = pStore
        self.pluginDiscovery = pluginDiscovery ?? PluginDiscoveryService(pluginsDirectory: PluginDiscoveryService.defaultPluginsDirectory(), store: pStore)
        self.toolStates = toolStates ?? ToolStateStore(dbPath: defaultDBPath)
        self.stagedFiles = stagedFiles ?? StagedFilesStore(dbPath: defaultDBPath)
        self.sandboxConfig = sandboxConfig
        self.bashFilesBox = OSAllocatedUnfairLock(initialState: BashFilesPair(bash: bashConfig, files: filesConfig))
        self.sandboxCleanup = sandboxCleanup ?? SandboxCleanupScheduler()
        self.browserConfig = browserConfig
        self.servingLLM = servingLLM
        self.liveIndexBox = OSAllocatedUnfairLock(initialState: LiveIndexPair(store: indexStore, coordinator: indexCoordinator))
        self.auth = auth
        self.browserGateway = browserGateway
        self.searchTransport = searchTransport
        self.fetchTransport = fetchTransport
        self.apiTransport = apiTransport
        self.mediaTransport = mediaTransport
        self.searchEnsurer = searchEnsurer
        self.mediaSecrets = mediaSecrets
        self.secrets = secrets
        self.desktopCaptureBridge = desktopCaptureBridge
        self.desktopControlBridge = desktopControlBridge
        self.desktopConfigBox = OSAllocatedUnfairLock(initialState: desktopConfig)
        // Fail fast when the context would enqueue through a different queue than
        // the turn loop dequeues through; such a pair accepts steering yet never
        // delivers it, so surface the wiring mistake at construction.
        precondition(
            orchestrator.sharedSteeringQueue == nil || orchestrator.sharedSteeringQueue === steeringQueue,
            "ServerContext steeringQueue must be identical instance handed to orchestrator"
        )
    }

    /// Reapplies every persisted tool toggle onto the live bus.
    /// Stored intent wins over fresh registration defaults, and the
    /// tool-state toggle is the sole authority for desktop tools.
    public func restoreToolStates(forceReload: Bool = false) async {
        let stored = await toolStates.loadAll(forceReload: forceReload)
        for (name, enabled) in stored {
            if enabled {
                await toolBus.enableTool(named: name)
            } else {
                await toolBus.disableTool(named: name)
            }
        }
    }

    /// Swaps the live document index pair atomically so status, run, cancel,
    /// prune, and reset observe one consistent generation without a restart.
    /// - Parameters:
    ///   - store: Document store to serve, or nil to unwire.
    ///   - coordinator: Coordinator to serve, or nil to unwire.
    public func setLiveIndex(store: DocIndexStore?, coordinator: IndexCoordinator?) {
        liveIndexBox.withLock { $0 = LiveIndexPair(store: store, coordinator: coordinator) }
    }

    /// Atomically snapshots the live document index pair so concurrent PUTs
    /// observe one consistent generation: the coordinator and store always
    /// belong together, never coordinator from gen A with store from gen B.
    /// - Returns: The live store and coordinator as one generation.
    public func liveIndexSnapshot() -> (store: DocIndexStore?, coordinator: IndexCoordinator?) {
        liveIndexBox.withLock { ($0.store, $0.coordinator) }
    }

    /// Swaps the live bash and files policies atomically so concurrent turns
    /// never observe a fresh shell policy beside a stale workspace guard.
    /// - Parameters:
    ///   - bash: Shell policy to serve.
    ///   - files: Workspace policy to serve.
    public func setBashFiles(bash: BashConfig, files: FilesConfig) {
        bashFilesBox.withLock { $0 = BashFilesPair(bash: bash, files: files) }
    }

    /// Atomically snapshots the live bash and files policies so a reload
    /// builds its tools from one consistent generation, mirroring
    /// `liveIndexSnapshot`.
    /// - Returns: The live shell and workspace policies as one generation.
    public func bashFilesSnapshot() -> (bash: BashConfig, files: FilesConfig) {
        bashFilesBox.withLock { ($0.bash, $0.files) }
    }
}

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
        let sandbox: SandboxConfig
        let browser: BrowserConfig
        let media: MediaConfig?
        let desktop: DesktopConfig
        let llmServerURLs: [String]
        let security: SecurityConfig
        let goals: GoalsConfig
    }

    private struct GoalComponents: Sendable {
        let engine: GoalEngine
        let store: GoalStore
        let conversations: ConversationManager
    }

    private struct ToolTransports: Sendable {
        let gateway: (any BrowserPlaywrightGateway)?
        let search: (any WebSearchTransport)?
        let fetch: (any WebFetchTransport)?
        let api: (any ApiRequestTransport)?
        let media: (any MediaArrTransport)?
        let ensurer: (any SearXNGEnsuring)?
        let mediaSecrets: SecretsManager?
        let secrets: SecretsManager?
        let desktopCapture: (any DesktopCapturing)?
        let desktopControl: (any DesktopControlling)?
    }

    private struct RuntimeEngineArgs: Sendable {
        let conversations: ConversationManager
        let bus: ToolBus
        let llm: any LLMProvider
        let systemPrompt: String?
        let engineConfig: EngineConfig
        let memoryEngine: MemoryEngine
        let approvals: ApprovalQueue
        let embedder: (any EmbeddingsBackend)?
        let securityConfig: SecurityConfig
        /// Recall budgets bounding automatic recall fan-out. Carries the
        /// clamped `[memory] recall_*` values from config so headless and
        /// served turns inject with file config instead of defaults.
        let recallBudgets: RecallBudgets
        let durable: DurableServerStores
        let notifier: (any SchedulerNotifier)?
        let indexCoordinator: IndexCoordinator?
        let goalStore: GoalStore
        let goalEngine: GoalEngine
        /// Proactive suggestion engine, or nil when `[ideas]` is disabled.
        let ideasEngine: IdeasEngine?
        /// Interruption policy from `[proactive]` so the worker gate matches file config.
        let proactiveConfig: ProactiveConfig
    }

    /// Boot-time configuration resolved before durable stores open.
    /// Groups the shared database path plus the config bundles that seed
    /// goal, ideas, plugin, and scheduler hydration, so `bootstrapServices`
    /// carries one seed instead of a long positional tail.
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
        hub: WSHub? = nil
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
        let goalEngine = GoalEngine(store: goalStore, llm: llm, config: config.goals, ideasEngine: ideasEngine)
        let pluginStack = await resolvePluginStack(episodesDBPath: config.episodesDBPath, pluginConfig: config.plugins, bus: bus)
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
        let embedder: (any EmbeddingsBackend)?
        let goals: GoalComponents
        let stagedFiles: StagedFilesStore
    }

    private static func registerBuiltinTools(_ args: BuiltinToolArgs) async {
        await BuiltinToolPlugins.registerAll(
            on: args.bus,
            emailConfig: args.configs.email,
            filesConfig: args.configs.files,
            bashConfig: args.configs.bash,
            sandboxConfig: args.configs.sandbox,
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
            stagedFilesStore: args.stagedFiles
        )
    }

    private struct RuntimeEngines: Sendable {
        let orchestrator: Orchestrator
        let schedulerWorker: ServerSchedulerWorker
        let steeringQueue: SteeringQueue
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
            recallBudgets: args.recallBudgets
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
            notifier: args.notifier,
            indexCoordinator: args.indexCoordinator,
            goalStore: args.goalStore,
            goalEngine: args.goalEngine,
            ideasEngine: args.ideasEngine,
            proactiveConfig: args.proactiveConfig,
            judgeLLM: args.llm
        )
        return RuntimeEngines(orchestrator: orchestrator, schedulerWorker: schedulerWorker, steeringQueue: steeringQueue)
    }

    /// Builds a context wired for live approval prompts over WebSocket.
    public static func make(
        config: ServerConfig = .default,
        conversations: ConversationManager,
        memoryEngine: MemoryEngine,
        embedder: (any EmbeddingsBackend)? = nil,
        permissionGate: PermissionGate,
        llm: any LLMProvider,
        systemPrompt: String? = nil,
        schedulerConfig: SchedulerConfig = .empty,
        episodesDBPath: String? = nil,
        pluginConfig: PluginConfig = PluginConfig(),
        notifier: (any SchedulerNotifier)? = nil,
        onApprovalRequested: (@Sendable (PermissionRequest) async -> Void)? = nil,
        sandboxConfig: SandboxConfig = SandboxConfig(),
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
        browserGateway: (any BrowserPlaywrightGateway)? = nil,
        searchTransport: (any WebSearchTransport)? = nil,
        fetchTransport: (any WebFetchTransport)? = nil,
        apiTransport: (any ApiRequestTransport)? = nil,
        mediaTransport: (any MediaArrTransport)? = nil,
        searchEnsurer: (any SearXNGEnsuring)? = nil,
        mediaSecrets: SecretsManager? = nil,
        secrets: SecretsManager? = nil,
        desktopCaptureBridge: (any DesktopCapturing)? = nil,
        desktopControlBridge: (any DesktopControlling)? = nil,
        runs: RunLogStore? = nil,
        hub: WSHub? = nil
    ) async -> ServerContext {
        await permissionGate.updateBashConfig(bashConfig)
        let services = await bootstrapServices(
            permissionGate: permissionGate,
            config: BootstrapConfig(
                scheduler: schedulerConfig, episodesDBPath: episodesDBPath, plugins: pluginConfig,
                goals: goalsConfig, ideas: ideasConfig
            ),
            llm: llm,
            memoryEngine: memoryEngine,
            runs: runs,
            hub: hub
        )
        let toolConfigs = ToolConfigs(
            email: emailConfig, files: filesConfig, bash: bashConfig, sandbox: sandboxConfig,
            browser: browserConfig, media: mediaConfig, desktop: desktopConfig,
            llmServerURLs: llmServerURLs, security: securityConfig, goals: goalsConfig
        )
        let transports = ToolTransports(
            gateway: browserGateway, search: searchTransport, fetch: fetchTransport,
            api: apiTransport, media: mediaTransport, ensurer: searchEnsurer,
            mediaSecrets: mediaSecrets, secrets: secrets,
            desktopCapture: desktopCaptureBridge, desktopControl: desktopControlBridge
        )
        let goalComponents = GoalComponents(
            engine: services.goalEngine,
            store: services.goalStore,
            conversations: conversations
        )
        let dbPath = episodesDBPath ?? (MemoryConfig.defaultEpisodesDBPath as NSString).expandingTildeInPath
        let stagedFilesStore = StagedFilesStore(dbPath: dbPath)
        await registerBuiltinTools(BuiltinToolArgs(
            bus: services.bus, configs: toolConfigs, transports: transports,
            memoryEngine: memoryEngine, embedder: embedder,
            goals: goalComponents, stagedFiles: stagedFilesStore
        ))
        let engineArgs = RuntimeEngineArgs(
            conversations: conversations, bus: services.bus, llm: llm,
            systemPrompt: systemPrompt, engineConfig: engineConfig,
            memoryEngine: memoryEngine, approvals: services.approvals,
            embedder: embedder, securityConfig: securityConfig,
            recallBudgets: recallBudgets.clamped(),
            durable: services.durable, notifier: notifier,
            indexCoordinator: indexCoordinator, goalStore: services.goalStore,
            goalEngine: services.goalEngine,
            ideasEngine: services.ideasEngine,
            proactiveConfig: proactiveConfig
        )
        let engines = makeExecutionEngines(args: engineArgs)
        let context = ServerContext(
            config: config, conversations: conversations, toolBus: services.bus,
            orchestrator: engines.orchestrator, memoryEngine: memoryEngine,
            embedder: embedder, permissionGate: permissionGate, approvals: services.approvals,
            scheduler: services.durable.scheduler, runs: services.durable.runs,
            hub: services.durable.hub, runLock: services.durable.runLock,
            activeTurns: ActiveTurnTracker(), steeringQueue: engines.steeringQueue,
            schedulerWorker: engines.schedulerWorker,
            pluginStore: services.pluginStack.store,
            pluginDiscovery: services.pluginStack.discovery,
            toolStates: services.pluginStack.states,
            sandboxConfig: sandboxConfig, filesConfig: toolConfigs.files,
            bashConfig: toolConfigs.bash, browserConfig: browserConfig,
            indexCoordinator: indexCoordinator, indexStore: indexStore,
            servingLLM: llm, auth: auth, browserGateway: browserGateway,
            searchTransport: searchTransport, fetchTransport: fetchTransport,
            apiTransport: apiTransport, mediaTransport: mediaTransport,
            searchEnsurer: searchEnsurer, mediaSecrets: mediaSecrets,
            secrets: secrets, desktopCaptureBridge: desktopCaptureBridge,
            desktopControlBridge: desktopControlBridge, desktopConfig: desktopConfig,
            goals: services.goalStore, goalEngine: services.goalEngine,
            goalsConfig: goalsConfig, ideas: services.ideasStore,
            ideasEngine: services.ideasEngine, ideasConfig: ideasConfig,
            proactiveConfig: proactiveConfig, stagedFiles: stagedFilesStore
        )
        await finalizeServerContext(context, sandboxConfig: sandboxConfig, onApprovalRequested: onApprovalRequested)
        return context
    }

    /// Ephemeral fallback context used if Application.runeWeaver is queried before configuration.
    public static let fallbackUnconfigured: ServerContext = {
        let gate = PermissionGate(store: InMemoryTrustStore())
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
        let orch = Orchestrator(conversations: conv, toolBus: bus, llm: FallbackDummyLLM(), steeringQueue: steering)
        let appq = ApprovalQueue(permissionGate: gate)
        return ServerContext(
            conversations: conv,
            toolBus: bus,
            orchestrator: orch,
            memoryEngine: mem,
            permissionGate: gate,
            approvals: appq,
            steeringQueue: steering
        )
    }()
}

/// Reclaims crash-orphaned detonation machines once at boot so restarts never inherit leaked VMs.
/// The periodic lifecycle keeps pressure bounded afterwards; only aggregate counts reach the audit trail.
private func reclaimSandboxDetonationMachines(config: SandboxConfig) {
    let bootSummary = SandboxCleaner.cleanup(config: config)
    FileSandboxAuditLog.append(bootSummary)
}

/// Installs the live approval prompt path as the backstop for direct bus executions.
/// Broadcasts each filed request and waits with a timeout, keeping the bus wiring single-sourced for boot.
/// Structured turns park before the bus in the common case and never reach this handler; it remains
/// the fail-safe for executions escaping the partition plus dry-run previews, denying on timeout.
private func installLiveApprovalHandler(
    bus: ToolBus,
    approvals: ApprovalQueue,
    hub: WSHub,
    onApprovalRequested: (@Sendable (PermissionRequest) async -> Void)?
) async {
    let handlerApprovals = approvals
    let handlerHub = hub
    await bus.setApprovalHandler { tool, call, toolContext in
        // Two-phase filing path: file the pending request immediately with a
        // nil assessment so the inbox renders without awaiting the model, then
        // broadcast and wait with a timeout. The enrichment hook rebroadcasts
        // the updated request on the identical id through the same channel
        // without re-parking, so live views replace the pending card in place.
        let owningSession = toolContext.conversationID
        let request = await handlerApprovals.fileRequest(
            tool: tool,
            call: call,
            sessionID: owningSession,
            onEnriched: { updated in
                await handlerHub.broadcastApproval(updated)
                if let onApprovalRequested {
                    await onApprovalRequested(updated)
                }
            }
        )
        await handlerHub.broadcastApproval(request)
        if let onApprovalRequested {
            await onApprovalRequested(request)
        }
        let decision = await handlerApprovals.waitForDecision(
            id: request.id,
            timeoutSeconds: ApprovalQueue.defaultDecisionTimeoutSeconds
        )
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

/// Loads durable scheduler and run stores off the cooperative pool so actor init never blocks on SQLite.
/// Groups the four independent boot collaborators so durable hydration stays single-sourced.
/// Callers proving the same run store plus hub to the index reporter pass them here so the
/// status probe, the socket hub, and the reporter share one instance instead of forking memory state.
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
    bus: ToolBus
) async -> ResolvedPluginStack {
    let resolvedDBPath = episodesDBPath ?? (MemoryConfig.defaultEpisodesDBPath as NSString).expandingTildeInPath
    let pStore = ToolRegistryStore(dbPath: resolvedDBPath)
    let tStates = ToolStateStore(dbPath: resolvedDBPath)
    let pluginsURL = URL(fileURLWithPath: (pluginConfig.pluginsDir as NSString).expandingTildeInPath)
    let pDiscovery = PluginDiscoveryService(pluginsDirectory: pluginsURL, store: pStore)
    if pluginConfig.autoRescan {
        _ = await pDiscovery.discoverAndSync(toolBus: bus)
    }
    return ResolvedPluginStack(store: pStore, states: tStates, discovery: pDiscovery)
}

/// Wires live approval prompts and restores persisted tool toggles on a built context.
/// Keeps `make` within the body-length gate by owning the boot tail that must run
/// after construction: orphaned detonation reclamation, bus approval handler
/// install, then stored-toggle restore so restarts honor operator intent.
private func finalizeServerContext(
    _ context: ServerContext,
    sandboxConfig: SandboxConfig,
    onApprovalRequested: (@Sendable (PermissionRequest) async -> Void)?
) async {
    reclaimSandboxDetonationMachines(config: sandboxConfig)
    await installLiveApprovalHandler(
        bus: context.toolBus,
        approvals: context.approvals,
        hub: context.hub,
        onApprovalRequested: onApprovalRequested
    )
    // Stored toggles win over fresh registration defaults so restarts
    // restore operator intent; tools registered after `make` (builtin
    // plugins in the serve path) re-apply via `restoreToolStates`.
    await context.restoreToolStates()
}

/// Storage key for the shared ``ServerContext``.
private struct ServerContextKey: StorageKey {
    /// Stored context type.
    typealias Value = ServerContext
}

extension Application {
    /// Shared engine context for every route.
    /// A missing configuration logs and serves an ephemeral fallback so one
    /// misconfigured route cannot crash the process; routes needing a strict
    /// 500 use `requireRuneWeaver()` instead.
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

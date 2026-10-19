// Rune Weaver Server — Server execution context and bootstrap wiring.

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
private struct BashFilesPair: Sendable {
    /// Shell execution policy carrying enablement, rules, and timeouts.
    var bash: BashConfig
    /// Workspace access policy bounding reads and the bash guard.
    var files: FilesConfig
}

/// Stand-in provider for goal engine defaults when no serving model is wired.
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

/// Single-flight lock serializing policy read-classify-write passes.
public actor PolicyWriteLock {
    /// True while one writer owns the read-classify-write window.
    private var isLocked = false
    /// Suspended writers in arrival order; the head owns the next handoff.
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func withLock<T: Sendable>(_ operation: () async throws -> T) async throws -> T {
        await acquire()
        do {
            let value = try await operation()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }

    private func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
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
    public let embedder: any EmbeddingsBackend?
    /// Graduated-trust gate backing approvals.
    public let permissionGate: PermissionGate
    /// Pending approval prompts shared by REST and WebSocket.
    public let approvals: ApprovalQueue
    /// Resolved decision audit trail shared by every decision surface.
    public let approvalDecisions: any ApprovalDecisionRecording
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
    /// Container admission policy bounding guest memory, concurrency, and idle TTL for isolated
    /// runs.
    private let containersBox: OSAllocatedUnfairLock<ContainersConfig>
    public var containersConfig: ContainersConfig {
        get { containersBox.withLock { $0 } }
        set { containersBox.withLock { $0 = newValue } }
    }

    /// Atomic bash plus files policy pair refreshed by settings saves.
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
    /// Proactive suggestion engine composing the ideas store with the serving provider, or nil when
    /// `[ideas]` is disabled.
    public let ideasEngine: IdeasEngine?
    /// Parallel worker fan-out engine backing the `fanout.run` tool.
    public let fanOut: FanOutEngine
    /// Active chat provider backing goal planning, ideas, fan-out review, and the proactive judge.
    private let servingLLMBox: OSAllocatedUnfairLock<any LLMProvider?>
    public var servingLLM: any LLMProvider? {
        get { servingLLMBox.withLock { $0 } }
        set { servingLLMBox.withLock { $0 = newValue } }
    }

    /// Live document index pair. Held behind a lock because settings PUTs swap
    /// the store and coordinator in place while this class stays Sendable,
    /// mirroring `desktopConfigBox`.
    private let liveIndexBox: OSAllocatedUnfairLock<LiveIndexPair>
    /// Local document index coordinator backing the `/index` routes, or nil when indexing is not
    /// wired. Swapped live by settings saves without a restart.
    public var indexCoordinator: IndexCoordinator? {
        liveIndexBox.withLock { $0.coordinator }
    }

    /// Local document index store backing status, prune, and reset, or nil when indexing is not
    /// wired. Swapped live by settings saves without a restart.
    public var indexStore: DocIndexStore? {
        liveIndexBox.withLock { $0.store }
    }

    /// Persisted Messages watermark the index reset route clears.
    public let indexMessagesStatePath: String
    /// Persisted mail checkpoint the index reset route clears. Mirrors
    /// `indexMessagesStatePath` so a test-wired reset can never delete the
    /// operator's live checkpoint either.
    public let indexMailCheckpointPath: String

    /// Owner bearer verifier, or nil for the no-auth loopback posture.
    public let auth: ServerAuth?
    /// Shared Playwright gateway reused across browser live-reloads so a settings PUT
    /// refreshes allowlisted origins without dropping the managed bridge or test doubles.
    public let browserGateway: any BrowserPlaywrightGateway?
    /// Hermetic search transport preserved across live-reloads.
    public let searchTransport: any WebSearchTransport?
    /// Hermetic fetch transport preserved across live-reloads.
    public let fetchTransport: any WebFetchTransport?
    /// Hermetic API transport preserved across live-reloads.
    public let apiTransport: any ApiRequestTransport?
    /// Hermetic media transport preserved across live-reloads.
    public let mediaTransport: any MediaArrTransport?
    /// Search lifecycle ensurer preserved across live-reloads.
    public let searchEnsurer: any SearXNGEnsuring?
    /// Media secrets resolver preserved across live-reloads so injected doubles survive.
    public let mediaSecrets: SecretsManager?
    /// Shared secrets backing surrogate resolution preserved across live-reloads.
    public let secrets: SecretsManager?
    /// The one verified security policy store for this process.
    public let policyStore: PolicyStore
    /// Mandatory outbound egress supervisor backing runtime domain triage and dynamic allows.
    public let egressSupervisor: OutboundEgressSupervisor?
    /// Single-flight lock serializing policy read-classify-write passes.
    public let policyWriteLock: PolicyWriteLock
    /// Live `[media]` policy carrying LAN exemption origins.
    public let mediaConfig: MediaConfig?
    /// Configured LLM server URLs feeding the SSRF loopback exemption.
    private let llmServerURLsBox: OSAllocatedUnfairLock<[String]>
    public var llmServerURLs: [String] {
        get { llmServerURLsBox.withLock { $0 } }
        set { llmServerURLsBox.withLock { $0 = newValue } }
    }

    /// Hermetic desktop capture bridge preserved across live-reloads so a
    /// settings PUT refreshes capture knobs without dropping test doubles.
    public let desktopCaptureBridge: any DesktopCapturing?
    /// Hermetic desktop control bridge preserved across live-reloads so a
    /// settings PUT refreshes control knobs without dropping test doubles.
    public let desktopControlBridge: any DesktopControlling?
    /// Live `[desktop]` capture policy. Held behind a lock because
    /// settings PUTs refresh it in place while this class stays Sendable.
    private let desktopConfigBox: OSAllocatedUnfairLock<DesktopConfig>
    /// Live `[desktop]` policy carrying capture knobs (dimensions, quality,
    /// blocklist). Enablement flows solely through the tool-state toggle.
    public var desktopConfig: DesktopConfig {
        get { desktopConfigBox.withLock { $0 } }
        set { desktopConfigBox.withLock { $0 = newValue } }
    }

    /// Scratch workspace owning the default shell directory, the eligible
    /// `tools/` promotion directory, and the quota plus retention policy.
    public let workspaceStore: WorkspaceStore
    /// Owner persona configured at boot.
    public let persona: PersonaConfig
    /// Trusted-tool anomaly watchdog counting executions and denials.
    public let watchdog: BehaviorWatchdog
    /// Sovereign ledger verifier proving the episode history unedited.
    public let sovereignLedger: SovereignLedger

    /// Creates a server context.
    public init(
        config: ServerConfig = .default,
        conversations: ConversationManager,
        toolBus: ToolBus,
        orchestrator: Orchestrator,
        memoryEngine: MemoryEngine,
        embedder: any EmbeddingsBackend? = nil,
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
        containersConfig: ContainersConfig = ContainersConfig(),
        sandboxCleanup: SandboxCleanupScheduler? = nil,
        filesConfig: FilesConfig = FilesConfig(),
        bashConfig: BashConfig = BashConfig(),
        browserConfig: BrowserConfig = BrowserConfig(),
        indexCoordinator: IndexCoordinator? = nil,
        indexStore: DocIndexStore? = nil,
        indexMessagesStatePath: String = MessagesIndexer.defaultStatePath,
        indexMailCheckpointPath: String = MailIndexCheckpointStore.defaultPath,
        servingLLM: any LLMProvider? = nil,
        auth: ServerAuth? = nil,
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
        desktopConfig: DesktopConfig = DesktopConfig(),
        goals: GoalStore? = nil,
        goalEngine: GoalEngine? = nil,
        goalsConfig: GoalsConfig = GoalsConfig(),
        ideas: IdeasStore? = nil,
        ideasEngine: IdeasEngine? = nil,
        ideasConfig: IdeasConfig = IdeasConfig(),
        proactiveConfig: ProactiveConfig = ProactiveConfig(),
        stagedFiles: StagedFilesStore? = nil,
        fanOut: FanOutEngine? = nil,
        fanOutConfig: FanOutConfig = FanOutConfig(),
        policyStore: PolicyStore? = nil,
        egressSupervisor: OutboundEgressSupervisor? = nil,
        mediaConfig: MediaConfig? = nil,
        llmServerURLs: [String] = [],
        policyWriteLock: PolicyWriteLock = PolicyWriteLock(),
        workspaceConfig: WorkspaceConfig = WorkspaceConfig(),
        workspaceStore: WorkspaceStore? = nil,
        persona: PersonaConfig = PersonaConfig(),
        watchdog: BehaviorWatchdog? = nil,
        sovereignLedger: SovereignLedger? = nil,
        approvalDecisions: any ApprovalDecisionRecording? = nil
    ) {
        self.config = config
        self.conversations = conversations
        self.toolBus = toolBus
        self.orchestrator = orchestrator
        self.memoryEngine = memoryEngine
        self.embedder = embedder
        self.permissionGate = permissionGate
        self.approvals = approvals
        self.approvalDecisions = approvalDecisions ?? InMemoryApprovalDecisionLog()
        self.scheduler = scheduler
        self.runs = runs
        self.hub = hub
        self.runLock = runLock
        self.activeTurns = activeTurns
        self.steeringQueue = steeringQueue
        self.persona = persona
        let defaultDBPath = (MemoryConfig.defaultEpisodesDBPath as NSString).expandingTildeInPath
        // Goals resolve before the worker so the default worker below can
        // carry them; an explicit worker still wins untouched for tests that
        // hand-build one without goals.
        let resolvedGoals = goals ?? GoalStore(dbPath: defaultDBPath)
        // Ideas default over the same `episodes.db` as goals so one database carries both; an
        // explicit store wins untouched.
        let resolvedIdeas = ideas ?? IdeasStore(dbPath: resolvedGoals.dbPath)
        let resolvedIdeasEngine = ideasEngine ?? (ideasConfig.enabled ? IdeasEngine(
            store: resolvedIdeas,
            llm: servingLLM ?? DefaultGoalLLM(),
            config: ideasConfig,
            memoryFacts: { await memoryEngine.getUserProfile().facts.map(\.content) }
        ) : nil)
        let planReporter = ServerGoalPlanReporter(runs: runs, hub: hub)
        let resolvedEngine = goalEngine ?? GoalEngine(
            store: resolvedGoals,
            llm: servingLLM ?? DefaultGoalLLM(),
            config: goalsConfig,
            ideasEngine: resolvedIdeasEngine,
            reporter: planReporter
        )
        self.goals = resolvedGoals
        self.goalEngine = resolvedEngine
        self.ideas = resolvedIdeas
        self.ideasEngine = resolvedIdeasEngine
        // Fan-out resolves over the shared orchestrator and run-log store so workers observe the
        // same model posture as chat, with the serving provider as the background reviewer; a
        // hand-built engine still wins untouched for tests that wire their own collaborators.
        self.fanOut = fanOut ?? FanOutEngine(
            orchestrator: orchestrator,
            runLogs: FanOutRunLogAdapter(runs: runs, hub: hub),
            config: fanOutConfig,
            reviewer: servingLLM
        )
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
            activeTurns: activeTurns,
            proactiveConfig: proactiveConfig,
            judgeLLM: servingLLM
        )
        let pStore = pluginStore ?? ToolRegistryStore(dbPath: defaultDBPath)
        self.pluginStore = pStore
        self.pluginDiscovery = pluginDiscovery ?? PluginDiscoveryService(pluginsDirectory: PluginDiscoveryService.defaultPluginsDirectory(), store: pStore)
        self.toolStates = toolStates ?? ToolStateStore(dbPath: defaultDBPath)
        self.stagedFiles = stagedFiles ?? StagedFilesStore(dbPath: defaultDBPath)
        self.containersBox = OSAllocatedUnfairLock(initialState: containersConfig)
        self.bashFilesBox = OSAllocatedUnfairLock(initialState: BashFilesPair(bash: bashConfig, files: filesConfig))
        self.sandboxCleanup = sandboxCleanup ?? SandboxCleanupScheduler()
        self.browserConfig = browserConfig
        self.servingLLMBox = OSAllocatedUnfairLock(initialState: servingLLM)
        self.liveIndexBox = OSAllocatedUnfairLock(initialState: LiveIndexPair(store: indexStore, coordinator: indexCoordinator))
        self.indexMessagesStatePath = indexMessagesStatePath
        self.indexMailCheckpointPath = indexMailCheckpointPath
        self.auth = auth
        self.browserGateway = browserGateway
        self.searchTransport = searchTransport
        self.fetchTransport = fetchTransport
        self.apiTransport = apiTransport
        self.mediaTransport = mediaTransport
        self.searchEnsurer = searchEnsurer
        self.mediaSecrets = mediaSecrets
        self.secrets = secrets
        // A direct init defaults to a fresh unloaded store; `make` always injects the resolved
        // instance so the supervisor and the policy routes share one store.
        self.policyStore = policyStore ?? PolicyStore()
        self.egressSupervisor = egressSupervisor
        self.policyWriteLock = policyWriteLock
        self.mediaConfig = mediaConfig
        self.llmServerURLsBox = OSAllocatedUnfairLock(initialState: llmServerURLs)
        self.desktopCaptureBridge = desktopCaptureBridge
        self.desktopControlBridge = desktopControlBridge
        self.desktopConfigBox = OSAllocatedUnfairLock(initialState: desktopConfig)
        let resolvedWorkspace = workspaceStore ?? WorkspaceStore(config: workspaceConfig)
        self.workspaceStore = resolvedWorkspace
        Self.requireMatchingSteeringQueue(orchestrator: orchestrator, steeringQueue: steeringQueue)
        // Verified-pulse collaborators resolve through the helpers below so the
        // body stays within the type-length budget; behavior is unchanged.
        self.watchdog = Self.resolveWatchdog(watchdog: watchdog, approvals: approvals, steeringQueue: steeringQueue, activeTurns: activeTurns)
        self.sovereignLedger = Self.resolveLedger(sovereignLedger, dbPath: defaultDBPath, secrets: secrets)
        wireVerifiedPulse(goalEngine: resolvedEngine)
    }

    // MARK: - Verified-Pulse Construction Wiring

    /// Fails fast when the context would enqueue through a different queue than the turn loop
    /// dequeues through; such a pair accepts steering yet never delivers it, so the wiring mistake
    /// surfaces at construction.
    private static func requireMatchingSteeringQueue(orchestrator: Orchestrator, steeringQueue: SteeringQueue) {
        precondition(
            orchestrator.sharedSteeringQueue == nil || orchestrator.sharedSteeringQueue === steeringQueue,
            "ServerContext steeringQueue must be identical instance handed to orchestrator"
        )
    }

    /// Resolves the behavior watchdog: a hand-built instance wins untouched for tests, while
    /// production boots count from the first tool call with parking through the shared turn tracker
    /// and filing into the shared inbox.
    private static func resolveWatchdog(
        watchdog: BehaviorWatchdog?,
        approvals: ApprovalQueue,
        steeringQueue: SteeringQueue,
        activeTurns: ActiveTurnTracker
    ) -> BehaviorWatchdog {
        watchdog ?? BehaviorWatchdog(
            approvalQueue: approvals,
            steeringQueue: steeringQueue,
            turnParking: activeTurns
        )
    }

    /// Resolves the sovereign ledger over the primary episode ledger file, so the copy corroborates
    /// live truth; an injected instance wins untouched for tests.
    private static func resolveLedger(_ ledger: SovereignLedger?, dbPath: String, secrets: SecretsManager? = nil) -> SovereignLedger {
        ledger ?? SovereignLedger(episodeStore: EpisodeStore(dbPath: dbPath), secrets: secrets ?? SecretsManager())
    }

    /// Fans the shared semantic answer cache out to the goal engine, the policy store, and the tool
    /// bus, so goal changes, policy changes, and trusted-tool outcomes all land without a restart.
    private func wireVerifiedPulse(goalEngine: GoalEngine) {
        Task {
            await wireVerifiedPulseAsync(goalEngine: goalEngine)
        }
    }

    /// Awaitable verified-pulse wiring for the serving path.
    func wireVerifiedPulseAsync(goalEngine: GoalEngine) async {
        let sharedCache = await memoryEngine.answerCache
        await goalEngine.setAnswerCache(sharedCache)
        await policyStore.setAnswerCache(sharedCache)
        await toolBus.setWatchdog(watchdog)
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

    /// Swaps the live document index pair atomically so status, run, cancel, prune, and reset
    /// observe one consistent generation without a restart. store: Document store to
    /// serve, or nil to unwire.
    public func setLiveIndex(store: DocIndexStore?, coordinator: IndexCoordinator?) {
        liveIndexBox.withLock { $0 = LiveIndexPair(store: store, coordinator: coordinator) }
    }

    /// Atomically snapshots the live document index pair so concurrent PUTs observe one consistent
    /// generation: the coordinator and store always belong together, never coordinator from gen A
    /// with store from gen B.
    public func liveIndexSnapshot() -> (store: DocIndexStore?, coordinator: IndexCoordinator?) {
        liveIndexBox.withLock { ($0.store, $0.coordinator) }
    }

    /// Swaps the live bash and files policies atomically so concurrent turns never observe a fresh
    /// shell policy beside a stale workspace guard. bash: Shell policy to serve.
    public func setBashFiles(bash: BashConfig, files: FilesConfig) {
        bashFilesBox.withLock { $0 = BashFilesPair(bash: bash, files: files) }
    }

    /// Atomically snapshots the live bash and files policies so a reload builds its tools from one
    /// consistent generation, mirroring `liveIndexSnapshot`. - Returns: The live shell and workspace
    /// policies as one generation.
    public func bashFilesSnapshot() -> (bash: BashConfig, files: FilesConfig) {
        bashFilesBox.withLock { ($0.bash, $0.files) }
    }

    /// Schedules a background task to await completion of goal planning and broadcast the updated
    /// goal.
    public func schedulePlanReadyBroadcast(goalID: UUID) {
        let hub = self.hub
        let store = self.goals
        let engine = self.goalEngine
        Task(priority: .background) {
            await engine.waitForPendingPlan(goalID: goalID)
            do {
                if let updated = try await store.goal(id: goalID) {
                    let freshSteps: [GoalStep]
                    do {
                        freshSteps = try await store.steps(goalID: goalID)
                    } catch is CancellationError {
                        return
                    } catch {
                        RuneWeaverLog.server.warning("ServerContext: plan-ready steps lookup failed for \(goalID): \(error.localizedDescription)")
                        freshSteps = []
                    }
                    await hub.broadcastGoal(GoalDTO(goal: updated, steps: freshSteps, isPlanning: false))
                }
            } catch is CancellationError {
                return
            } catch {
                RuneWeaverLog.server.error("ServerContext: plan-ready broadcast failed for \(goalID): \(error.localizedDescription)")
            }
        }
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
        let planReporter = ServerGoalPlanReporter(runs: durable.runs, hub: durable.hub)
        let goalEngine = GoalEngine(
            store: goalStore,
            llm: llm,
            config: config.goals,
            ideasEngine: ideasEngine,
            reporter: planReporter
        )
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

    /// Resolves the sovereign ledger for boot, preloading its signing key.
    /// Keeps the fresh-install versus injected choice beside boot wiring.
    private static func resolveSovereignLedger(
        sovereignLedger: SovereignLedger?,
        dbPath: String,
        secrets: SecretsManager?
    ) async throws -> SovereignLedger {
        let ledger = resolveLedger(sovereignLedger, dbPath: dbPath, secrets: secrets)
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
        sovereignLedger: SovereignLedger? = nil
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
            hub: hub
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
        let engines = makeExecutionEngines(args: RuntimeEngineArgs(
            conversations: conversations, bus: services.bus, llm: llm,
            systemPrompt: systemPrompt, engineConfig: engineConfig,
            memoryEngine: memoryEngine, approvals: services.approvals,
            permissionGate: permissionGate, embedder: embedder,
            securityConfig: securityConfig, recallBudgets: recallBudgets.clamped(),
            durable: services.durable, notifier: notifier,
            indexCoordinator: indexCoordinator, goalStore: services.goalStore,
            goalEngine: services.goalEngine, ideasEngine: services.ideasEngine,
            proactiveConfig: proactiveConfig, fanOutConfig: fanOutConfig,
            activeTurns: activeTurns, persona: persona
        ))
        let egressSupervisor = try await setupEgressAndPolicy(
            policyStore: resolvedPolicyStore, toolConfigs: toolConfigs,
            secrets: secrets, permissionGate: permissionGate
        )
        try await registerBuiltinTools(BuiltinToolArgs(
            bus: services.bus, configs: toolConfigs, transports: transports,
            memoryEngine: memoryEngine, embedder: embedder,
            goals: goalComponents, stagedFiles: stagedFilesStore,
            workspaceStore: resolvedWorkspaceStore,
            supersededReviewNotifier: makeStagedSupersedeNotifier(hub: services.durable.hub),
            goalUpdatedNotifier: { [hub = services.durable.hub] goal, steps in
                await hub.broadcastGoal(GoalDTO(goal: goal, steps: steps))
            },
            fanOutEngine: engines.fanOutEngine,
            scheduledSendBooking: SchedulerStoreBookingAdapter(store: services.durable.scheduler),
            policyStore: resolvedPolicyStore,
            egressSupervisor: egressSupervisor
        ))
        let context = ServerContext(
            config: config, conversations: conversations, toolBus: services.bus, orchestrator: engines.orchestrator,
            memoryEngine: memoryEngine, embedder: embedder, permissionGate: permissionGate, approvals: services.approvals,
            scheduler: services.durable.scheduler, runs: services.durable.runs, hub: services.durable.hub, runLock: services.durable.runLock,
            activeTurns: activeTurns, steeringQueue: engines.steeringQueue, schedulerWorker: engines.schedulerWorker,
            pluginStore: services.pluginStack.store, pluginDiscovery: services.pluginStack.discovery, toolStates: services.pluginStack.states,
            containersConfig: containersConfig, filesConfig: toolConfigs.files, bashConfig: toolConfigs.bash, browserConfig: browserConfig,
            indexCoordinator: indexCoordinator, indexStore: indexStore, servingLLM: llm, auth: auth, browserGateway: browserGateway,
            searchTransport: searchTransport, fetchTransport: fetchTransport, apiTransport: apiTransport, mediaTransport: mediaTransport,
            searchEnsurer: searchEnsurer, mediaSecrets: mediaSecrets, secrets: secrets,
            desktopCaptureBridge: desktopCaptureBridge, desktopControlBridge: desktopControlBridge, desktopConfig: desktopConfig,
            goals: services.goalStore, goalEngine: services.goalEngine, goalsConfig: goalsConfig, ideas: services.ideasStore,
            ideasEngine: services.ideasEngine, ideasConfig: ideasConfig, proactiveConfig: proactiveConfig, stagedFiles: stagedFilesStore,
            fanOut: engines.fanOutEngine, policyStore: resolvedPolicyStore, egressSupervisor: egressSupervisor,
            mediaConfig: toolConfigs.media, llmServerURLs: toolConfigs.llmServerURLs,
            workspaceConfig: workspaceConfig, workspaceStore: resolvedWorkspaceStore,
            persona: persona,
            watchdog: watchdog, sovereignLedger: resolvedSovereignLedger,
            approvalDecisions: ApprovalDecisionLogStore(dbPath: dbPath)
        )
        // Await the verified-pulse wiring before serving so early tool calls
        // observe watchdog counts and goal/policy changes invalidate the
        // shared answer cache from the first turn.
        await context.wireVerifiedPulseAsync(goalEngine: services.goalEngine)
        await finalizeServerContext(context, containersConfig: containersConfig, onApprovalRequested: onApprovalRequested)
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
            steeringQueue: steering
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

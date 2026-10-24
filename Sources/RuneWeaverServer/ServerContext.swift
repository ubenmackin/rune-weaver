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
    /// Optional notification dispatcher for desktop and system notifications.
    public let notifier: any SchedulerNotifier?
    /// Subscribed Web Push device endpoints for standalone PWA notifications.
    public let pushSubscriptions: PushSubscriptionStore
    /// RFC 8291/8292 outbound Web Push sender, or nil when VAPID is unconfigured.
    public let webPushSender: WebPushSender?
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

    /// Plugin configuration carrying marketplace URL and plugins directory.
    private let pluginConfigBox: OSAllocatedUnfairLock<PluginConfig>
    public var pluginConfig: PluginConfig {
        get { pluginConfigBox.withLock { $0 } }
        set { pluginConfigBox.withLock { $0 = newValue } }
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
    /// Live `[email]` accounts backing onboarding evidence; nil means unconfigured.
    public let emailConfig: EmailConfig?
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
    /// Single-row onboarding persistence backing the setup wizard.
    public let onboarding: any OnboardingStoring

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
        pluginConfig: PluginConfig = PluginConfig(),
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
        emailConfig: EmailConfig? = nil,
        llmServerURLs: [String] = [],
        policyWriteLock: PolicyWriteLock = PolicyWriteLock(),
        workspaceConfig: WorkspaceConfig = WorkspaceConfig(),
        workspaceStore: WorkspaceStore? = nil,
        notifier: any SchedulerNotifier? = nil,
        persona: PersonaConfig = PersonaConfig(),
        watchdog: BehaviorWatchdog? = nil,
        sovereignLedger: SovereignLedger? = nil,
        onboarding: any OnboardingStoring? = nil,
        approvalDecisions: any ApprovalDecisionRecording? = nil,
        pushSubscriptions: PushSubscriptionStore? = nil,
        webPushSender: WebPushSender? = nil
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
        self.notifier = notifier
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
        let resolvedPushSubscriptions = pushSubscriptions ?? PushSubscriptionStore(dbPath: resolvedGoals.dbPath)
        self.pushSubscriptions = resolvedPushSubscriptions
        // Nil stays unconfigured; push routes fail closed rather than serving an ephemeral key.
        self.webPushSender = webPushSender
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
        // Fan-out shares the orchestrator and run log so workers match chat posture.
        self.fanOut = Self.resolveFanOut(fanOut, orchestrator, runs, hub, fanOutConfig, servingLLM)
        // The gate rides the stored policy with the serving provider as judge.
        self.schedulerWorker = Self.resolveSchedulerWorker(
            schedulerWorker,
            SchedulerWorkerDeps(
                scheduler: scheduler, runs: runs, hub: hub, runLock: runLock, orchestrator: orchestrator,
                conversations: conversations, toolBus: toolBus, indexCoordinator: indexCoordinator,
                goalStore: resolvedGoals, goalEngine: resolvedEngine, ideasEngine: resolvedIdeasEngine,
                activeTurns: activeTurns, proactiveConfig: proactiveConfig, servingLLM: servingLLM
            )
        )
        let pStore = pluginStore ?? ToolRegistryStore(dbPath: defaultDBPath)
        self.pluginStore = pStore
        let resolvedToolStates = toolStates ?? ToolStateStore(dbPath: defaultDBPath)
        self.toolStates = resolvedToolStates
        self.pluginDiscovery = pluginDiscovery ?? PluginDiscoveryService(
            pluginsDirectory: PluginDiscoveryService.defaultPluginsDirectory(),
            store: pStore,
            toolStates: resolvedToolStates
        )
        self.stagedFiles = stagedFiles ?? StagedFilesStore(dbPath: defaultDBPath)
        self.containersBox = OSAllocatedUnfairLock(initialState: containersConfig)
        self.pluginConfigBox = OSAllocatedUnfairLock(initialState: pluginConfig)
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
        self.emailConfig = emailConfig
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
        self.onboarding = onboarding ?? OnboardingStore(dbPath: defaultDBPath)
        wireVerifiedPulse(goalEngine: resolvedEngine)
    }
}

/// Live helpers ride an extension so the main body stays within budget.
extension ServerContext {
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
    static func resolveLedger(_ ledger: SovereignLedger?, dbPath: String, secrets: SecretsManager? = nil) -> SovereignLedger {
        ledger ?? SovereignLedger(episodeStore: EpisodeStore(dbPath: dbPath), secrets: secrets ?? SecretsManager())
    }

    /// Resolves the fan-out engine sharing the orchestrator and run log.
    private static func resolveFanOut(
        _ fanOut: FanOutEngine?,
        _ orchestrator: Orchestrator,
        _ runs: RunLogStore,
        _ hub: WSHub,
        _ config: FanOutConfig,
        _ servingLLM: any LLMProvider?
    ) -> FanOutEngine {
        fanOut ?? FanOutEngine(
            orchestrator: orchestrator,
            runLogs: FanOutRunLogAdapter(runs: runs, hub: hub),
            config: config,
            reviewer: servingLLM
        )
    }

    /// Scheduler worker collaborators bundled so the resolver stays within the parameter budget.
    private struct SchedulerWorkerDeps: Sendable {
        let scheduler: SchedulerStore
        let runs: RunLogStore
        let hub: WSHub
        let runLock: SchedulerRunLock
        let orchestrator: Orchestrator
        let conversations: ConversationManager
        let toolBus: ToolBus
        let indexCoordinator: IndexCoordinator?
        let goalStore: GoalStore
        let goalEngine: GoalEngine
        let ideasEngine: IdeasEngine?
        let activeTurns: ActiveTurnTracker
        let proactiveConfig: ProactiveConfig
        let servingLLM: any LLMProvider?
    }

    /// Resolves the scheduler worker sharing the goal stack and turn tracker.
    private static func resolveSchedulerWorker(
        _ schedulerWorker: ServerSchedulerWorker?,
        _ deps: SchedulerWorkerDeps
    ) -> ServerSchedulerWorker {
        schedulerWorker ?? ServerSchedulerWorker(
            scheduler: deps.scheduler,
            runs: deps.runs,
            hub: deps.hub,
            runLock: deps.runLock,
            orchestrator: deps.orchestrator,
            conversations: deps.conversations,
            toolBus: deps.toolBus,
            indexCoordinator: deps.indexCoordinator,
            goalStore: deps.goalStore,
            goalEngine: deps.goalEngine,
            ideasEngine: deps.ideasEngine,
            activeTurns: deps.activeTurns,
            proactiveConfig: deps.proactiveConfig,
            judgeLLM: deps.servingLLM
        )
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
        // Quarantine reflects boot and mutation refreshes; reads use the cached set.
        let records = await pluginStore.loadAll()
        let quarantinedIDs = Set(records.filter { $0.status == .tampered }.map(\.id))
        await toolBus.setQuarantinedPluginIDs(quarantinedIDs)
        let recordByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        for (name, enabled) in stored {
            if enabled {
                if let tool = await toolBus.tool(named: name),
                   let bridge = tool as? SubprocessToolBridge
                {
                    guard let record = recordByID[bridge.pluginID],
                          record.status == .enabled,
                          record.integrityHash != nil,
                          !quarantinedIDs.contains(bridge.pluginID),
                          await !(toolBus.isQuarantined(pluginID: bridge.pluginID))
                    else {
                        await toolBus.disableTool(named: name)
                        continue
                    }
                }
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

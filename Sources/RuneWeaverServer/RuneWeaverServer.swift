// Rune Weaver Server — Loopback HTTP and WebSocket API service application.

import Foundation
import NIOWebSocket
import os
import RuneWeaverCore
import RuneWeaverTools
import Vapor

/// Localhost-only HTTP and WebSocket API service for Rune Weaver.
extension OrchestratorResponse: Content {}
extension ToolResult: Content {}
extension UserFact: Content {}
extension Preference: Content {}
extension MemoryResult: Content {}
extension PermissionRequest: Content {}
extension SchedulerJob: Content {}
extension NewSchedulerJob: Content {}
extension UpdateSchedulerJob: Content {}
extension RunLogEntry: Content {}

/// Receipt binding one registered turn to its tracker slot.
public struct TurnRegistration: Sendable, Equatable {
    /// Identity of this registration.
    public let token: UUID
    /// Whether a prior turn was replaced by this registration.
    public let replaced: Bool

    /// Creates a registration receipt.
    public init(token: UUID, replaced: Bool) {
        self.token = token
        self.replaced = replaced
    }
}

/// Manages in-flight chat turn tasks so they can be cancelled cooperatively.
public actor ActiveTurnTracker {
    /// One slot: registration identity plus its cooperative cancel action.
    private struct Entry {
        /// Identity of the registered turn.
        let token: UUID
        /// Cooperative cancel action for the registered turn.
        let cancel: @Sendable () -> Void
    }

    /// Active turns indexed by session identifier.
    private var entries: [UUID: Entry] = [:]
    /// Cancel marks waiting for a turn that has not registered yet.
    private var pendingCancels: [UUID: Date] = [:]
    /// Last registration per session, bounding idle-cancel poisoning.
    private var recentRegistrations: [UUID: Date] = [:]
    /// How long a pending cancel survives before it expires.
    private static let pendingCancelTTL: TimeInterval = 2

    /// Bounds how many interactive turns may run at once across sessions.
    /// Local inference degrades past a couple of concurrent evaluations, so a
    /// fresh session past the cap fails with an honest busy notice instead of
    /// stacking turns that would all look hung. Kept namespaced here (not as
    /// a module global) so REST and WebSocket share one cap. This is the
    /// authoritative single source: every health probe advertises it so the
    /// dashboard prefers the server value and only falls back to its mirrored
    /// constant for older engines, keeping admit and reject in agreement.
    public static let maxConcurrentTurns = 3

    /// Response header carrying the authoritative turn cap on every health probe.
    /// A header keeps the JSON contract stable while still giving the dashboard
    /// one server-owned value to prefer over its fallback constant.
    public static let turnCapHeaderName = "X-RuneWeaver-Max-Concurrent-Turns"

    public init() {}

    /// Registers an active turn task for a session.
    @discardableResult
    public func register(sessionID: UUID, task: Task<some Sendable, some Error>) -> TurnRegistration {
        store(sessionID: sessionID, cancel: { task.cancel() })
    }

    /// Registers a custom cancel closure for a session.
    @discardableResult
    public func register(sessionID: UUID, onCancel: @Sendable @escaping () -> Void) -> TurnRegistration {
        store(sessionID: sessionID, cancel: onCancel)
    }

    /// Atomically acquires a turn slot when capacity allows.
    /// A replacement turn for the same session always fits (it supersedes the
    /// prior slot); a fresh session past the cap returns nil instead of
    /// registering. The check and the store run in one actor hop so concurrent
    /// fresh sessions cannot both slip past the cap between a separate
    /// contains/count probe and a later register. The cap stays fixed here so
    /// no caller can widen it and silently stack slow inference turns.
    /// - Parameters:
    ///   - sessionID: Owning session.
    ///   - onCancel: Cooperative cancel action for the turn.
    /// - Returns: Registration receipt, or nil when a fresh session is over cap.
    public func tryAcquire(
        sessionID: UUID,
        onCancel: @Sendable @escaping () -> Void
    ) -> TurnRegistration? {
        if entries[sessionID] == nil, entries.count >= Self.maxConcurrentTurns {
            return nil
        }
        return store(sessionID: sessionID, cancel: onCancel)
    }

    /// Stores one entry, cancelling any prior turn for the session first.
    private func store(sessionID: UUID, cancel: @Sendable @escaping () -> Void) -> TurnRegistration {
        let replaced: Bool
        if let existing = entries[sessionID] {
            existing.cancel()
            replaced = true
        } else {
            replaced = false
        }
        let token = UUID()
        entries[sessionID] = Entry(token: token, cancel: cancel)
        recentRegistrations[sessionID] = Date()
        pruneRecentRegistrations()
        if let marked = pendingCancels[sessionID] {
            pendingCancels.removeValue(forKey: sessionID)
            if Date().timeIntervalSince(marked) <= Self.pendingCancelTTL {
                cancel()
            } else {
                pruneExpiredPendingCancels()
            }
        }
        return TurnRegistration(token: token, replaced: replaced)
    }

    /// Returns true if an active turn is currently running for the session.
    public func isActive(sessionID: UUID) -> Bool {
        entries[sessionID] != nil
    }

    /// Returns the session identifiers of all active turns currently in flight.
    public func runningSessionIDs() -> [UUID] {
        Array(entries.keys)
    }

    /// Unregisters the turn for a session when it completes.
    public func unregister(sessionID: UUID, token: UUID) {
        guard entries[sessionID]?.token == token else { return }
        entries.removeValue(forKey: sessionID)
    }

    /// Cancels the in-flight turn for a session.
    @discardableResult
    public func cancel(sessionID: UUID) -> Bool {
        if let entry = entries.removeValue(forKey: sessionID) {
            entry.cancel()
            return true
        }
        if let lastSeen = recentRegistrations[sessionID],
           Date().timeIntervalSince(lastSeen) <= Self.pendingCancelTTL
        {
            pendingCancels[sessionID] = Date()
            pruneExpiredPendingCancels()
        }
        return false
    }

    /// Drops stale registration timestamps so abandoned identifiers never accumulate.
    private func pruneRecentRegistrations() {
        let now = Date()
        for (id, marked) in recentRegistrations where now.timeIntervalSince(marked) > Self.pendingCancelTTL {
            recentRegistrations.removeValue(forKey: id)
        }
        while recentRegistrations.count > Self.maxPendingCancels {
            guard let oldest = recentRegistrations.min(by: { $0.value < $1.value })?.key else { break }
            recentRegistrations.removeValue(forKey: oldest)
        }
    }

    /// Drops expired pending cancels so abandoned session identifiers never accumulate.
    private func pruneExpiredPendingCancels() {
        let now = Date()
        for (id, marked) in pendingCancels where now.timeIntervalSince(marked) > Self.pendingCancelTTL {
            pendingCancels.removeValue(forKey: id)
        }
        while pendingCancels.count > Self.maxPendingCancels {
            guard let oldest = pendingCancels.min(by: { $0.value < $1.value })?.key else { break }
            pendingCancels.removeValue(forKey: oldest)
        }
    }

    /// Bounds pending cancel marks so random identifiers never grow memory without bound.
    private static let maxPendingCancels = 500
}

/// Bridges a tracker cancel action to a chat task created just after registration.
final class TurnTaskBox: Sendable {
    private struct State: Sendable {
        var cancelAction: (@Sendable () -> Void)?
        var cancelled = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Creates an empty box.
    init() {}

    /// Publishes the chat task, cancelling it when a cancel already arrived.
    /// - Parameter task: In-flight chat turn task.
    func set(_ task: Task<some Sendable, some Error>) {
        let shouldCancel = state.withLock { boxState -> Bool in
            boxState.cancelAction = { task.cancel() }
            return boxState.cancelled
        }
        if shouldCancel {
            task.cancel()
        }
    }

    /// Cancels the chat task, or flags the box when it is not set yet.
    func cancel() {
        let action = state.withLock { boxState -> (@Sendable () -> Void)? in
            boxState.cancelled = true
            return boxState.cancelAction
        }
        action?()
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
    /// Sandbox staging retention configuration bounding `pending/`, `approved/`, and `attachments/`.
    public let sandboxConfig: SandboxConfig
    /// Periodic scheduler reclaiming expired and over-cap staged files.
    public let sandboxCleanup: SandboxCleanupScheduler
    /// Browser policy carrying the SearXNG base URL for the search lifecycle routes.
    public let browserConfig: BrowserConfig
    /// Local document index coordinator backing the `/index` routes, or nil when
    /// indexing is not wired.
    public let indexCoordinator: IndexCoordinator?
    /// Local document index store backing status, prune, and reset, or nil when
    /// indexing is not wired.
    public let indexStore: DocIndexStore?
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
        browserConfig: BrowserConfig = BrowserConfig(),
        indexCoordinator: IndexCoordinator? = nil,
        indexStore: DocIndexStore? = nil,
        auth: ServerAuth? = nil,
        browserGateway: (any BrowserPlaywrightGateway)? = nil,
        searchTransport: (any WebSearchTransport)? = nil,
        fetchTransport: (any WebFetchTransport)? = nil,
        apiTransport: (any ApiRequestTransport)? = nil,
        mediaTransport: (any MediaArrTransport)? = nil,
        searchEnsurer: (any SearXNGEnsuring)? = nil,
        mediaSecrets: SecretsManager? = nil
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
        self.schedulerWorker = schedulerWorker ?? ServerSchedulerWorker(
            scheduler: scheduler,
            runs: runs,
            hub: hub,
            runLock: runLock,
            orchestrator: orchestrator,
            conversations: conversations,
            toolBus: toolBus,
            indexCoordinator: indexCoordinator
        )
        let defaultDBPath = (MemoryConfig.defaultEpisodesDBPath as NSString).expandingTildeInPath
        let pStore = pluginStore ?? ToolRegistryStore(dbPath: defaultDBPath)
        self.pluginStore = pStore
        self.pluginDiscovery = pluginDiscovery ?? PluginDiscoveryService(pluginsDirectory: PluginDiscoveryService.defaultPluginsDirectory(), store: pStore)
        self.toolStates = toolStates ?? ToolStateStore(dbPath: defaultDBPath)
        self.sandboxConfig = sandboxConfig
        self.sandboxCleanup = sandboxCleanup ?? SandboxCleanupScheduler()
        self.browserConfig = browserConfig
        self.indexCoordinator = indexCoordinator
        self.indexStore = indexStore
        self.auth = auth
        self.browserGateway = browserGateway
        self.searchTransport = searchTransport
        self.fetchTransport = fetchTransport
        self.apiTransport = apiTransport
        self.mediaTransport = mediaTransport
        self.searchEnsurer = searchEnsurer
        self.mediaSecrets = mediaSecrets
        // Fail fast when the context would enqueue through a different queue than
        // the turn loop dequeues through; such a pair accepts steering yet never
        // delivers it, so surface the wiring mistake at construction.
        precondition(
            orchestrator.sharedSteeringQueue == nil || orchestrator.sharedSteeringQueue === steeringQueue,
            "ServerContext steeringQueue must be identical instance handed to orchestrator"
        )
    }

    /// Reapplies every persisted tool toggle onto the live bus.
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
        mediaConfig: MediaConfig? = nil,
        auth: ServerAuth? = nil,
        browserGateway: (any BrowserPlaywrightGateway)? = nil,
        searchTransport: (any WebSearchTransport)? = nil,
        fetchTransport: (any WebFetchTransport)? = nil,
        apiTransport: (any ApiRequestTransport)? = nil,
        mediaTransport: (any MediaArrTransport)? = nil,
        searchEnsurer: (any SearXNGEnsuring)? = nil,
        mediaSecrets: SecretsManager? = nil
    ) async -> ServerContext {
        let approvals = ApprovalQueue(permissionGate: permissionGate)
        // Durable stores bootstrap asynchronously: actor initializers never
        // block the cooperative pool on SQLite reads, so disk hydration
        // suspends here on the shared serial store queue instead.
        let durable = await loadDurableServerStores(schedulerConfig: schedulerConfig, episodesDBPath: episodesDBPath)
        let scheduler = durable.scheduler
        let runs = durable.runs
        let hub = durable.hub
        let runLock = durable.runLock
        let bus = ToolBus(permissionGate: permissionGate)
        // Unified builtin tool registration covers Email, Files, Memory, Web, Browser, API, and media tools.
        // Injected gateway and transports ride along so hermetic doubles survive
        // from boot through later settings live-reloads instead of resetting to live defaults.
        await BuiltinToolPlugins.registerAll(
            on: bus,
            emailConfig: emailConfig,
            filesConfig: filesConfig,
            sandboxConfig: sandboxConfig,
            browserConfig: browserConfig,
            mediaConfig: mediaConfig,
            llmServerURLs: llmServerURLs,
            memoryEngine: memoryEngine,
            embedder: embedder,
            gateway: browserGateway,
            searchTransport: searchTransport,
            fetchTransport: fetchTransport,
            apiTransport: apiTransport,
            mediaTransport: mediaTransport,
            ensurer: searchEnsurer,
            mediaSecrets: mediaSecrets
        )
        let pluginStack = await resolvePluginStack(episodesDBPath: episodesDBPath, pluginConfig: pluginConfig, bus: bus)
        let pStore = pluginStack.store
        let tStates = pluginStack.states
        let pDiscovery = pluginStack.discovery
        // The orchestrator shares the approvals queue so narrated gated
        // calls file parked requests tagged with their session instead of
        // dropping, with resume continuing the same session on decision.
        let steeringQueue = SteeringQueue()
        let orchestrator = Orchestrator(
            conversations: conversations,
            toolBus: bus,
            llm: llm,
            systemPrompt: systemPrompt,
            maxToolIterations: engineConfig.maxToolIterations,
            memoryEngine: memoryEngine,
            approvalQueue: approvals,
            embedder: embedder,
            compactionThresholdPercent: engineConfig.compactionThresholdPercent,
            steeringQueue: steeringQueue
        )
        let schedulerWorker = ServerSchedulerWorker(
            scheduler: scheduler,
            runs: runs,
            hub: hub,
            runLock: runLock,
            orchestrator: orchestrator,
            conversations: conversations,
            toolBus: bus,
            notifier: notifier,
            indexCoordinator: indexCoordinator
        )
        let context = ServerContext(
            config: config,
            conversations: conversations,
            toolBus: bus,
            orchestrator: orchestrator,
            memoryEngine: memoryEngine,
            embedder: embedder,
            permissionGate: permissionGate,
            approvals: approvals,
            scheduler: scheduler,
            runs: runs,
            hub: hub,
            runLock: runLock,
            activeTurns: ActiveTurnTracker(),
            steeringQueue: steeringQueue,
            schedulerWorker: schedulerWorker,
            pluginStore: pStore,
            pluginDiscovery: pDiscovery,
            toolStates: tStates,
            sandboxConfig: sandboxConfig,
            browserConfig: browserConfig,
            indexCoordinator: indexCoordinator,
            indexStore: indexStore,
            auth: auth,
            browserGateway: browserGateway,
            searchTransport: searchTransport,
            fetchTransport: fetchTransport,
            apiTransport: apiTransport,
            mediaTransport: mediaTransport,
            searchEnsurer: searchEnsurer,
            mediaSecrets: mediaSecrets
        )
        reclaimSandboxDetonationMachines(config: sandboxConfig)
        await installLiveApprovalHandler(
            bus: bus,
            approvals: context.approvals,
            hub: context.hub,
            onApprovalRequested: onApprovalRequested
        )
        // Stored toggles win over fresh registration defaults so restarts
        // restore operator intent; tools registered after `make` (builtin
        // plugins in the serve path) re-apply via `restoreToolStates`.
        await context.restoreToolStates()
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

/// Installs the live approval prompt path so narrated gated calls file parked requests for their session.
/// Broadcasts each filed request and waits with a timeout, keeping the bus wiring single-sourced for boot.
private func installLiveApprovalHandler(
    bus: ToolBus,
    approvals: ApprovalQueue,
    hub: WSHub,
    onApprovalRequested: (@Sendable (PermissionRequest) async -> Void)?
) async {
    let handlerApprovals = approvals
    let handlerHub = hub
    await bus.setApprovalHandler { tool, call, toolContext in
        // Decorates the shared filing path: file through
        // `fileRequest(tool:call:sessionID:)` tagging the owning session,
        // then broadcast and wait with a timeout.
        let request = await handlerApprovals.fileRequest(tool: tool, call: call, sessionID: toolContext.conversationID)
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
private func loadDurableServerStores(
    schedulerConfig: SchedulerConfig,
    episodesDBPath: String?
) async -> DurableServerStores {
    let scheduler = await SchedulerStore.load(from: schedulerConfig, dbPath: episodesDBPath)
    let runs = await RunLogStore.load(dbPath: episodesDBPath)
    return DurableServerStores(scheduler: scheduler, runs: runs, hub: WSHub(), runLock: SchedulerRunLock())
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

/// Lifecycle hook draining live WebSockets on application shutdown.
struct WSHubShutdownLifecycle: LifecycleHandler {
    let hub: WSHub

    func shutdownAsync(_: Application) async {
        await hub.closeAll()
    }
}

/// Lifecycle hook managing the background scheduler worker on application start and stop.
struct ServerSchedulerLifecycle: LifecycleHandler {
    let worker: ServerSchedulerWorker

    func didBootAsync(_: Application) async throws {
        await worker.start()
    }

    func shutdownAsync(_: Application) async {
        await worker.stop()
    }
}

/// Lifecycle hook running sandbox staging reclamation on a cadence.
struct SandboxCleanupLifecycle: LifecycleHandler {
    let scheduler: SandboxCleanupScheduler
    let config: SandboxConfig

    func didBootAsync(_: Application) async throws {
        await scheduler.runOnce(config: config)
        await scheduler.start(config: config)
    }

    func shutdownAsync(_: Application) async {
        await scheduler.stop()
    }
}

/// Lifecycle hook warming the managed browser Python venv on serve boot.
/// Best-effort child so first navigates stay warm without ever delaying or
/// failing boot: the venv, pip, and browser budgets run in the background
/// while the live stage plus health payload carries state to the dashboard.
/// Failures stay in the server log so a down network never flips a healthy
/// boot into a failure.
final class BrowserWarmupLifecycle: LifecycleHandler {
    /// Retained warmup flight so shutdown can cancel it instead of leaving an
    /// ensure running after the server exits, mirroring the menu bar
    /// quit-cancel. Guarded by a lock because boot and shutdown arrive on
    /// different executors.
    private let warmupState: OSAllocatedUnfairLock<Task<Void, Never>?> = OSAllocatedUnfairLock(initialState: nil)

    func didBootAsync(_: Application) async throws {
        // Structured child inheriting task-locals and priority so logging plus
        // tracing flow from boot; never awaited here so a minutes-budget first
        // provision cannot hold the bind. The ensurer owns single-flight plus
        // staged progress, so a concurrent first navigate simply joins this
        // flight. Retained for shutdown cancel.
        warmupState.withLock { current in
            current?.cancel()
            current = Task(priority: .background) {
                await PlaywrightPythonEnsurer.shared.warmup()
            }
        }
    }

    func shutdownAsync(_: Application) async {
        warmupState.withLock { current in
            current?.cancel()
            current = nil
        }
    }
}

/// Configures loopback binding plus every engine route.
///
/// The resolved owner verifier is the single source of truth for the auth
/// posture: the bind policy and the gate must agree, so a context that claims
/// auth without a verifier (or the reverse) fails closed instead of silently
/// serving an unauthenticated or unenforced surface.
/// - Parameters:
///   - app: Application receiving configuration.
///   - context: Shared engine collaborators.
///   - auth: Resolved owner verifier, overriding `context.auth` when supplied.
public func configureRuneWeaver(_ app: Application, context: ServerContext, auth: ServerAuth? = nil) throws {
    let resolvedAuth = auth ?? context.auth
    guard context.config.authConfigured == (resolvedAuth != nil) else {
        throw ServerAuthError.misconfigured(
            reason: context.config.authConfigured
                ? "authConfigured is true but no bearer verifier was supplied"
                : "a bearer verifier was supplied but authConfigured is false"
        )
    }
    try context.config.requireBindable(authConfigured: resolvedAuth != nil)
    app.http.server.configuration.hostname = context.config.hostname
    app.http.server.configuration.port = context.config.port
    app.http.server.configuration.shutdownTimeout = .seconds(2)
    app.lifecycle.use(WSHubShutdownLifecycle(hub: context.hub))
    app.lifecycle.use(ServerSchedulerLifecycle(worker: context.schedulerWorker))
    app.lifecycle.use(SandboxCleanupLifecycle(scheduler: context.sandboxCleanup, config: context.sandboxConfig))
    app.lifecycle.use(BrowserWarmupLifecycle())
    app.runeWeaver = context
    app.runeWeaverAuth = resolvedAuth
    registerRuneWeaverRoutes(app)
}

/// Registers every engine route on the application.
///
/// When a verifier is installed, the auth middleware wraps the whole router so
/// every non-public path is gated before it can 404 or leak existence. With no
/// verifier the surface stays the v1 loopback-no-auth shape exactly, including
/// the absence of the rotation route.
public func registerRuneWeaverRoutes(_ app: Application) {
    // Resolve the bundle once so the public-path gate and the delivery handler
    // agree on exactly which bytes are real static artifacts.
    let dashboardBundle = DashboardBundle.resolve()
    if let auth = app.runeWeaverAuth {
        app.middleware.use(ServerAuthMiddleware(auth: auth, dashboardBundle: dashboardBundle))
        registerAuthRotateRoute(app, auth: auth)
    }
    registerHealthRoute(app)
    registerChatRoute(app)
    registerSessionRoutes(app)
    registerToolRoutes(app)
    registerPluginRoutes(app)
    registerMemoryRoutes(app)
    registerApprovalRoutes(app)
    registerSchedulerCRUDRoutes(app)
    registerSchedulerRunRoute(app)
    registerRunRoutes(app)
    registerSearchRoutes(app)
    registerBrowserRoutes(app)
    registerSettingsRoutes(app)
    registerIndexRoutes(app)
    registerWebSocketRoute(app)
    registerDashboardRoutes(app, bundle: dashboardBundle)
}

/// Registers the owner token rotation route.
///
/// Rotation is itself gated by the auth middleware, so a caller reaching this
/// handler has already presented the current token. The handler never echoes
/// the credential into logs or audit entries, only into the one-time response
/// body the owner must capture.
/// - Parameters:
///   - app: Application receiving the route.
///   - auth: Live owner verifier performing the rotation.
private func registerAuthRotateRoute(_ app: Application, auth: ServerAuth) {
    app.post(PathComponent.constant(ServerPaths.auth), PathComponent.constant(ServerPaths.rotate)) { req async throws -> Response in
        let token = try await auth.rotate()
        // Rotation retires the previous credential for every client. Established
        // sockets upgraded under the old token would otherwise keep receiving run
        // events and approval prompts and could still send chat/decision frames,
        // so retire them by generation rather than a blind drain: a registration
        // racing this sweep is refused by the same watermark, leaving no socket
        // that can linger passive and keep broadcasting under a dead credential.
        // The watermark is read after the swap so overlapping rotations only ever
        // raise it. Clients reconnect with the replacement.
        let liveGeneration = await auth.currentGeneration()
        await req.application.runeWeaver.hub.retire(liveGeneration: liveGeneration)
        // Encoded through the request's configured encoder for contract parity,
        // then marked no-store so a one-time credential is never cached.
        let response = try await ServerAuthRotateResponse(token: token).encodeResponse(for: req)
        response.headers.replaceOrAdd(name: "Cache-Control", value: "no-store")
        return response
    }
}

/// Registers the health probe route.
/// - Parameter app: Application receiving the route.
private func registerHealthRoute(_ app: Application) {
    app.get(PathComponent.constant(ServerPaths.health)) { req async throws -> Response in
        let modelInfo = await req.application.runeWeaver.orchestrator.modelInfo
        let searchURL = req.application.runeWeaver.browserConfig.searxngURL
        let searchReachable = await SearXNGEnsurer.isReachable(baseURL: searchURL)
        // Live Start stage rides along so the profile menu polls one endpoint
        // for both the dot and the Starting line; nil when idle.
        let searchProgress = await SearXNGEnsurer.shared.currentStartProgress(for: searchURL)
        let health = HealthResponse(
            engine: req.application.runeWeaver.memoryEngineDescription,
            model: modelInfo.name,
            provider: modelInfo.provider,
            contextLength: modelInfo.contextLength,
            searchReachable: searchReachable,
            searchURL: searchURL,
            searchStatus: searchReachable ? "running" : "stopped",
            searchStage: searchProgress?.stage.rawValue,
            searchStartedAt: searchProgress.map(\.startedAt.timeIntervalSince1970)
        )
        // Advertise the authoritative turn cap alongside the JSON body so the
        // dashboard prefers the server value over its fallback constant; a
        // header keeps the JSON contract stable while still collapsing
        // admit/reject drift to one server-owned number. Encoding through the
        // request's configured encoder keeps date and key strategies aligned
        // with every other Content route instead of freezing JSONEncoder defaults.
        let response = try await health.encodeResponse(for: req)
        response.headers.replaceOrAdd(name: ActiveTurnTracker.turnCapHeaderName, value: "\(ActiveTurnTracker.maxConcurrentTurns)")
        return response
    }
}

/// Validates chat text once for REST and WebSocket.
func validatedChatText(_ raw: String) throws -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        throw Abort(.badRequest, reason: "text must not be empty")
    }
    guard trimmed.count <= ChatRequest.maxTextLength else {
        throw Abort(.payloadTooLarge, reason: "text exceeds \(ChatRequest.maxTextLength) characters")
    }
    return trimmed
}

/// Registers memory search plus facts CRUD routes.
/// - Parameter app: Application receiving the routes.
private func registerMemoryRoutes(_ app: Application) {
    app.get(PathComponent.constant(ServerPaths.memory), PathComponent.constant(ServerPaths.memorySearch)) { req async throws -> MemorySearchResponse in
        guard let query = req.query[String.self, at: "q"],
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw Abort(.badRequest, reason: "q query parameter is required")
        }
        let limit = try parseQueryLimit(req, default: 10, min: 1, max: 50)
        let context = req.application.runeWeaver
        // Embed best-effort so vector hits rank by cosine similarity while
        // the response shape stays unchanged; any failure keeps keywords
        // while cancellation propagates.
        let embedding: [Float]? = if let embedder = context.embedder {
            try await embedder.embedQuery(query)
        } else {
            nil
        }
        let memories = try await context.memoryEngine.recall(query: query, embedding: embedding, limit: limit)
        return MemorySearchResponse(query: query, memories: memories)
    }

    app.get(PathComponent.constant(ServerPaths.memory), PathComponent.constant(ServerPaths.memoryFacts)) { req async throws -> FactsResponse in
        let context = req.application.runeWeaver
        let profile = await context.memoryEngine.getUserProfile()
        let semantic = await context.memoryEngine.allSemanticFacts()
        let episodes = await context.memoryEngine.episodeCount()
        return FactsResponse(
            facts: profile.facts,
            preferences: profile.preferences,
            semanticCount: semantic.count,
            episodeCount: episodes
        )
    }

    app.post(PathComponent.constant(ServerPaths.memory), PathComponent.constant(ServerPaths.memoryFacts)) { req async throws -> UserFact in
        let body = try req.content.decode(StoreFactRequest.self)
        guard MemoryEngine.isStorableFact(body.content) else {
            throw Abort(.badRequest, reason: "content must contain alphanumeric characters")
        }
        let context = req.application.runeWeaver
        let trimmed = body.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = body.resolvedSource
        // Vector-backed writes share the engine helper with the remember tool
        // so embedding, fallback, and cancellation stay single-sourced;
        // cancellation propagates while other failures surface as 422.
        do {
            return try await context.memoryEngine.storeFactWithEmbedder(
                content: trimmed,
                source: source,
                embedder: context.embedder
            )
        } catch let error as CancellationError {
            throw error
        } catch {
            throw Abort(.unprocessableEntity, reason: error.localizedDescription)
        }
    }

    app.delete(
        PathComponent.constant(ServerPaths.memory),
        PathComponent.constant(ServerPaths.memoryFacts),
        PathComponent.parameter("id")
    ) { req async throws -> HTTPStatus in
        guard let raw = req.parameters.get("id"), let id = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "id must be a UUID")
        }
        await req.application.runeWeaver.memoryEngine.removeFact(id: id)
        return .noContent
    }
}

/// Registers approvals list plus decision routes.
/// Durable trust-grants routes live in the dedicated grants file alongside
/// their change broadcast; both sets register on the same paths.
/// - Parameter app: Application receiving the routes.
private func registerApprovalRoutes(_ app: Application) {
    app.get(PathComponent.constant(ServerPaths.approvals)) { req async throws -> ApprovalsResponse in
        let pending = await req.application.runeWeaver.approvals.list()
        if let limit = try parseQueryLimit(req, min: 1, max: 100) {
            return ApprovalsResponse(approvals: Array(pending.prefix(limit)))
        }
        return ApprovalsResponse(approvals: pending)
    }

    registerTrustGrantsRoutes(app)

    app
        .post(PathComponent.constant(ServerPaths.approvals), PathComponent.parameter("id"),
              PathComponent.constant(ServerPaths.decide))
        { req async throws -> ApprovalDecisionResponse in
            guard let raw = req.parameters.get("id"), let id = UUID(uuidString: raw) else {
                throw Abort(.badRequest, reason: "id must be a UUID")
            }
            let body = try req.content.decode(ApprovalDecisionRequest.self)
            let context = req.application.runeWeaver
            // Capture the tagged session before resolving: `decide` removes
            // the pending entry, so the resume path would otherwise lose
            // which conversation to continue.
            let pending = await context.approvals.request(id: id)
            let resolved = await context.approvals.decide(
                id: id,
                approved: body.approved,
                duration: body.resolvedDuration,
                widen: body.resolvedWiden
            )
            guard resolved else {
                throw Abort(.notFound, reason: "Unknown approval \(raw)")
            }
            // Durable approvals create a stored grant inside `decide`, so
            // dashboards need a refresh signal; one-shot approvals store
            // nothing and leave the grants list untouched. Continuation
            // approvals stay one-shot inside `decide` (coerced to thisTime
            // with no stored grant), so a durable vote on engine.continue
            // must not fire a refresh when nothing changed.
            if body.approved, body.resolvedDuration != .thisTime, pending?.toolName != "engine.continue" {
                await context.hub.broadcastTrustGrantsChanged()
            }
            if pending?.sessionID != nil {
                Task {
                    await resumeNarratedApproval(
                        id: id,
                        approved: body.approved,
                        context: context,
                        sessionID: pending?.sessionID,
                        decidedCallID: pending?.input.callID
                    )
                }
            }
            return ApprovalDecisionResponse(id: id, approved: body.approved, duration: body.resolvedDuration)
        }
}

/// Registers the managed browser Python lifecycle routes backing browser settings.
/// Thin HTTP adapters over `PlaywrightPythonEnsurer`: health reports the
/// effective interpreter plus the live provision stage so the dashboard can
/// poll one endpoint about 1s for the amber Preparing line, and ensure
/// collapses onto the single-flight resolving, creating, installing, browsers
/// cascade. Provisioning policy (managed venv path, pinned Playwright release,
/// per-stage budgets) stays single-sourced in the ensurer so boot warmup,
/// first navigate, and these routes cannot drift; the routes only translate
/// outcomes to HTTP shapes.
/// - Parameter app: Application receiving the routes.
func registerBrowserRoutes(_ app: Application) {
    let browser = app.grouped(PathComponent.constant(ServerPaths.browser))

    browser.get(PathComponent.constant(ServerPaths.browserHealth)) { _ async -> BrowserPythonHealthResponse in
        // Side-effect free by design: the probe never provisions, so opening
        // Settings or polling mid-flight cannot start a second cascade. The
        // live stage rides along so a provision in flight renders its current
        // step plus elapsed time, nil when idle.
        let progress = await PlaywrightPythonEnsurer.shared.currentProgress()
        let probe = await PlaywrightPythonEnsurer.probeReadiness()
        return BrowserPythonHealthResponse(
            ready: probe.ready,
            pythonPath: probe.pythonPath,
            stage: progress?.stage.rawValue,
            startedAt: progress.map(\.startedAt.timeIntervalSince1970),
            message: probe.ready ? nil : PlaywrightPythonEnsurer.missingMessage(
                stage: progress?.stage,
                detail: "Browser Python is not ready",
                pythonPath: probe.pythonPath
            )
        )
    }

    browser.post(PathComponent.constant(ServerPaths.browserEnsure)) { req async -> BrowserPythonEnsureResponse in
        // Single-sourced through the shared ensurer so boot warmup, first
        // navigate, and this route collapse onto one in-flight provision
        // instead of racing venv plus pip installs. The trimmed banner threads
        // through for the inline slot while capped diagnostics thread through
        // for logs plus collapsed UI, so each failure renders once.
        let report = await PlaywrightPythonEnsurer.shared.ensureReport()
        if !report.ready {
            let banner = report.message ?? "none"
            let chained = report.diagnostics ?? "none"
            let warningMessage =
                "Browser ensure ready=\(report.ready) started=\(report.started) "
                    + "python=\(report.pythonPath) message=\(banner) diagnostics=\(chained)"
            req.logger.warning("\(warningMessage)")
            RuneWeaverLog.server.warning("\(warningMessage)")
        }
        return BrowserPythonEnsureResponse(
            ready: report.ready,
            started: report.started,
            pythonPath: report.pythonPath,
            venvPath: report.venvPath,
            message: report.message,
            diagnostics: report.diagnostics
        )
    }
}

/// Registers settings routes for reading and persisting configuration.
private func registerSettingsRoutes(_ app: Application) {
    let settings = app.grouped(PathComponent.constant(ServerPaths.settings))
    settings.get { _ async throws -> SettingsResponse in
        let url = RuneWeaverConfig.defaultConfigFileURL()
        let config: RuneWeaverConfig
        do {
            config = try RuneWeaverConfig.loadDefault()
        } catch let error as ConfigError {
            throw Abort(.badRequest, reason: String(describing: error))
        } catch {
            throw Abort(.internalServerError, reason: error.localizedDescription)
        }
        return SettingsResponse(config: config, configPath: url.path)
    }
    settings.put { req async throws -> SettingsResponse in
        let body = try req.content.decode(UpdateSettingsRequest.self)
        let url = RuneWeaverConfig.defaultConfigFileURL()
        var config: RuneWeaverConfig
        do {
            config = try RuneWeaverConfig.loadDefault()
        } catch let error as ConfigError {
            throw Abort(.badRequest, reason: String(describing: error))
        } catch {
            throw Abort(.internalServerError, reason: error.localizedDescription)
        }
        do {
            try body.apply(to: &config)
            // Validate the merged config before persisting so a single bad
            // field cannot corrupt the stored file or live engine state.
            try config.validate()
            try config.save(to: url)
            let liveContext = req.application.runeWeaver
            await applyLiveOrchestratorTuning(body: body, context: liveContext)
            await reloadLiveMediaTools(body: body, config: config, context: liveContext)
            await reloadLiveNetworkTools(body: body, config: config, context: liveContext)
        } catch let error as ConfigError {
            throw Abort(.badRequest, reason: String(describing: error))
        } catch {
            throw Abort(.internalServerError, reason: error.localizedDescription)
        }
        return SettingsResponse(config: config, configPath: url.path)
    }
}

/// Pushes persisted engine budgets into the live orchestrator so saved values take effect without a restart.
private func applyLiveOrchestratorTuning(body: UpdateSettingsRequest, context: ServerContext) async {
    if let maxToolIterations = body.maxToolIterations {
        await context.orchestrator.updateMaxToolIterations(maxToolIterations)
    }
    // Push the persisted compaction threshold into the live engine so
    // the saved value takes effect immediately instead of staying stale
    // until the next restart.
    if let compactionThresholdPercent = body.compactionThresholdPercent {
        await context.orchestrator.updateCompactionPercent(compactionThresholdPercent)
    }
}

/// Reloads media tools when media settings changed so Sonarr / Radarr picks up URLs without a restart.
/// Stored transports ride along so hermetic doubles survive a settings PUT instead of resetting to live defaults.
private func reloadLiveMediaTools(body: UpdateSettingsRequest, config: RuneWeaverConfig, context: ServerContext) async {
    guard body.media != nil else { return }
    for tool in MediaTools.makeTools(
        mediaConfig: config.media, transport: context.mediaTransport, secrets: context.mediaSecrets
    ) {
        let isEnabled = await context.toolBus.isToolEnabled(named: tool.name)
        await context.toolBus.register(tool: tool, isEnabled: isEnabled)
    }
}

/// Rebuilds the Playwright bridge with fresh origins while preserving injected doubles.
/// A managed subprocess gateway keeps its executable and budgets; a test double survives as-is.
private func gatewayForLiveReload(
    stored: (any BrowserPlaywrightGateway)?,
    busGateway: (any BrowserPlaywrightGateway)?,
    origins: Set<String>
) -> (any BrowserPlaywrightGateway)? {
    let baseGateway = stored ?? busGateway
    if let baseGateway, let managed = baseGateway as? SubprocessPlaywrightGateway {
        return SubprocessPlaywrightGateway(
            pythonExecutable: managed.pythonExecutable,
            timeoutSeconds: managed.timeoutSeconds,
            maxOutputBytes: managed.maxOutputBytes,
            allowlistedOrigins: origins
        )
    }
    return baseGateway
}

/// Reloads browser, web, and API tools when origins may have changed so homelab hosts apply immediately.
/// The stored gateway and transports ride along so a settings PUT refreshes origins without dropping the bridge.
private func reloadLiveNetworkTools(body: UpdateSettingsRequest, config: RuneWeaverConfig, context: ServerContext) async {
    // Provider endpoints feed the SSRF exemption set, so an LLM-endpoint change
    // must refresh live tools immediately rather than waiting for a restart.
    guard body.media != nil || body.browserAllowedOrigins != nil || body.browserSearxngURL != nil
        || body.searchSearxngURL != nil || body.providers != nil || body.defaultProvider != nil
        || body.fallbackProvider != nil
    else {
        return
    }
    let appLLMOrigins = LLMOrigins.serverURLs(from: config.llm)
    let browserOrigins = ApiSSRFGuard.allowlistedOrigins(
        browserConfig: config.browser,
        mediaConfig: config.media,
        llmServerURLs: appLLMOrigins
    )
    let busGateway: (any BrowserPlaywrightGateway)? = if let existing =
        await context.toolBus.tool(named: "browser.navigate") as? BrowserNavigateTool
    {
        existing.browserGateway
    } else {
        nil
    }
    if let gatewayForReload = gatewayForLiveReload(stored: context.browserGateway, busGateway: busGateway, origins: browserOrigins) {
        for tool in BrowserTools.makeTools(gateway: gatewayForReload, allowlistedOrigins: browserOrigins) {
            let isEnabled = await context.toolBus.isToolEnabled(named: tool.name)
            await context.toolBus.register(tool: tool, isEnabled: isEnabled)
        }
    } else {
        for tool in BrowserTools.makeTools(allowlistedOrigins: browserOrigins) {
            let isEnabled = await context.toolBus.isToolEnabled(named: tool.name)
            await context.toolBus.register(tool: tool, isEnabled: isEnabled)
        }
    }
    for tool in WebTools.makeTools(
        browserConfig: config.browser,
        mediaConfig: config.media,
        searchTransport: context.searchTransport,
        fetchTransport: context.fetchTransport,
        ensurer: context.searchEnsurer
    ) {
        let isEnabled = await context.toolBus.isToolEnabled(named: tool.name)
        await context.toolBus.register(tool: tool, isEnabled: isEnabled)
    }
    for tool in ApiRequestTools.makeTools(
        browserConfig: config.browser,
        mediaConfig: config.media,
        llmServerURLs: appLLMOrigins,
        transport: context.apiTransport
    ) {
        let isEnabled = await context.toolBus.isToolEnabled(named: tool.name)
        await context.toolBus.register(tool: tool, isEnabled: isEnabled)
    }
}

/// Registers the chat WebSocket with live approval prompts.
///
/// The upgrade re-checks the auth marker at the route boundary in addition to
/// the global middleware, so a socket can never be handed out without passing
/// the owner gate even if the middleware is not installed.
private func registerWebSocketRoute(_ app: Application) {
    app.webSocket(
        PathComponent.constant(ServerPaths.websocket),
        shouldUpgrade: { request in
            request.eventLoop.makeSucceededFuture(authorizeWebSocketUpgrade(request))
        },
        onUpgrade: { req, webSocket in
            let context = req.application.runeWeaver
            let auth = req.application.runeWeaverAuth
            let connectionID = UUID()
            let box = WSSocketBox(webSocket)
            let connectionTasks = ConnectionChatTasks()
            // Bind the socket to the token generation it upgraded under so a
            // later rotation revokes it at the frame boundary as well as through
            // the hub teardown, closing the window where a buffered frame could
            // still be answered after the swap.
            let generation = req.runeWeaverTokenGeneration
            let (stream, continuation) = AsyncStream<String>.makeStream()
            let connectionTask = Task { [box, context, connectionID, stream, connectionTasks, generation, auth, continuation] in
                // Register bound to the upgrade generation, then re-validate it
                // immediately: the middleware authenticates and `onUpgrade`
                // registers on separate hops, so a rotation can land in between.
                // A registration the hub already knows is retired is refused, and
                // one that slipped in before the sweep is caught by the auth
                // re-check. Either path removes the socket and closes it with the
                // policy violation instead of letting a passive socket linger to
                // receive broadcasts under a dead credential.
                let registered = await context.hub.add(id: connectionID, box: box, generation: generation)
                // Evaluate the retirement check outside the boolean expression:
                // its right operand is a non-async autoclosure, so an `await`
                // cannot appear there. Either a refused registration or a
                // retired generation must tear the socket down.
                let retired = await webSocketGenerationIsRetired(auth: auth, generation: generation)
                if !registered || retired {
                    connectionTasks.cancelAll()
                    await context.hub.remove(id: connectionID)
                    continuation.finish()
                    _ = try? await box.close(code: .policyViolation)
                    return
                }
                for await text in stream {
                    if Task.isCancelled {
                        break
                    }
                    if await webSocketGenerationIsRetired(auth: auth, generation: generation) {
                        break
                    }
                    await handleWebSocketText(text, connectionID: connectionID, context: context, connectionTasks: connectionTasks)
                    if Task.isCancelled {
                        break
                    }
                }
                let retiredAtEnd = await webSocketGenerationIsRetired(auth: auth, generation: generation)
                // Every socket close seals the turn registry so orphaned turns
                // cannot keep writing past the socket lifetime and the
                // reserve/insert race stays closed; only a retired credential
                // additionally closes the socket with a policy violation.
                connectionTasks.cancelAll()
                await context.hub.remove(id: connectionID)
                if retiredAtEnd {
                    _ = try? await box.close(code: .policyViolation)
                }
            }
            webSocket.onText { _, text in
                continuation.yield(text)
            }
            webSocket.onClose.whenComplete { _ in
                // Seal immediately so a normal disconnect cannot leak turns
                // when the connection task has not yet reached its own seal.
                connectionTasks.cancelAll()
                continuation.finish()
                connectionTask.cancel()
            }
        }
    )
}

/// Whether a socket's upgrade generation has been retired by a rotation.
///
/// A socket that upgraded without a verifier (the loopback no-auth posture)
/// carries no generation and is never revoked; an authenticated upgrade always
/// records one, so a live rotation retires every socket that holds it.
/// - Parameters:
///   - auth: Installed owner verifier, or nil for the ungated posture.
///   - generation: Generation captured at upgrade, or nil when unauthenticated.
/// - Returns: True when the token that authorized the socket is no longer live.
private func webSocketGenerationIsRetired(auth: ServerAuth?, generation: Int?) async -> Bool {
    guard let auth, let generation else { return false }
    return await !auth.isCurrentGeneration(generation)
}

/// Registers the static dashboard bundle routes.
///
/// The bundle is served without the owner credential because a browser cannot
/// attach a bearer header to navigation or asset fetches; the bundle renders its
/// own login gate and every data route stays behind the uniform 401. The auth
/// middleware forwards these GET paths through to this handler, and both share
/// the same resolved bundle so the gate's public-path classifier and this
/// delivery path cannot disagree.
/// - Parameters:
///   - app: Application receiving the routes.
///   - bundle: Resolved bundle to serve, or a fresh resolution when omitted.
public func registerDashboardRoutes(_ app: Application, bundle: DashboardBundle = .resolve()) {
    app.get { req async throws -> Response in
        try await bundle.response(for: req, requestPath: "")
    }
    app.get("**") { req async throws -> Response in
        let remainder = req.parameters.getCatchall().joined(separator: "/")
        return try await bundle.response(for: req, requestPath: remainder)
    }
}

extension ServerContext {
    /// Engine name surfaced on `/health` without exposing config details.
    var memoryEngineDescription: String {
        "Rune Weaver"
    }
}

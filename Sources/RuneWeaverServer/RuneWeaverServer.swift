// Rune Weaver Server — Loopback HTTP and WebSocket API service application.

import Foundation
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

    /// Creates a server context.
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
        schedulerWorker: ServerSchedulerWorker? = nil,
        pluginStore: ToolRegistryStore? = nil,
        pluginDiscovery: PluginDiscoveryService? = nil,
        toolStates: ToolStateStore? = nil,
        sandboxConfig: SandboxConfig = SandboxConfig(),
        sandboxCleanup: SandboxCleanupScheduler? = nil,
        browserConfig: BrowserConfig = BrowserConfig()
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
        self.schedulerWorker = schedulerWorker ?? ServerSchedulerWorker(
            scheduler: scheduler,
            runs: runs,
            hub: hub,
            runLock: runLock,
            orchestrator: orchestrator,
            conversations: conversations,
            toolBus: toolBus
        )
        let defaultDBPath = (MemoryConfig.defaultEpisodesDBPath as NSString).expandingTildeInPath
        let pStore = pluginStore ?? ToolRegistryStore(dbPath: defaultDBPath)
        self.pluginStore = pStore
        self.pluginDiscovery = pluginDiscovery ?? PluginDiscoveryService(pluginsDirectory: PluginDiscoveryService.defaultPluginsDirectory(), store: pStore)
        self.toolStates = toolStates ?? ToolStateStore(dbPath: defaultDBPath)
        self.sandboxConfig = sandboxConfig
        self.sandboxCleanup = sandboxCleanup ?? SandboxCleanupScheduler()
        self.browserConfig = browserConfig
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
        llmServerURLs: [String] = []
    ) async -> ServerContext {
        let approvals = ApprovalQueue(permissionGate: permissionGate)
        // Durable stores bootstrap asynchronously: actor initializers never
        // block the cooperative pool on SQLite reads, so disk hydration
        // suspends here on the shared serial store queue instead.
        let scheduler = await SchedulerStore.load(from: schedulerConfig, dbPath: episodesDBPath)
        let runs = await RunLogStore.load(dbPath: episodesDBPath)
        let hub = WSHub()
        let runLock = SchedulerRunLock()
        let bus = ToolBus(permissionGate: permissionGate)
        // One `[browser]` policy feeds every web-facing tool so serve shares
        // the same five-tool set as the CLI via the shared registration
        // surface; `api.request` additionally exempts the configured LLM
        // origins. Late builtin registration in the serve path replaces these
        // same names, so registering here keeps direct `make` callers covered.
        await BuiltinToolPlugins.register(on: bus, browserConfig: browserConfig, llmServerURLs: llmServerURLs)
        let resolvedDBPath = episodesDBPath ?? (MemoryConfig.defaultEpisodesDBPath as NSString).expandingTildeInPath
        let pStore = ToolRegistryStore(dbPath: resolvedDBPath)
        let tStates = ToolStateStore(dbPath: resolvedDBPath)
        let pluginsURL = URL(fileURLWithPath: (pluginConfig.pluginsDir as NSString).expandingTildeInPath)
        let pDiscovery = PluginDiscoveryService(pluginsDirectory: pluginsURL, store: pStore)
        if pluginConfig.autoRescan {
            _ = await pDiscovery.discoverAndSync(toolBus: bus)
        }
        // The orchestrator shares the approvals queue so narrated gated
        // calls file parked requests tagged with their session instead of
        // dropping, with resume continuing the same session on decision.
        let orchestrator = Orchestrator(
            conversations: conversations,
            toolBus: bus,
            llm: llm,
            systemPrompt: systemPrompt,
            memoryEngine: memoryEngine,
            approvalQueue: approvals,
            embedder: embedder
        )
        let schedulerWorker = ServerSchedulerWorker(
            scheduler: scheduler,
            runs: runs,
            hub: hub,
            runLock: runLock,
            orchestrator: orchestrator,
            conversations: conversations,
            toolBus: bus,
            notifier: notifier
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
            schedulerWorker: schedulerWorker,
            pluginStore: pStore,
            pluginDiscovery: pDiscovery,
            toolStates: tStates,
            sandboxConfig: sandboxConfig,
            browserConfig: browserConfig
        )
        // Reclaim crash-orphaned detonation machines once at boot so restarts
        // never inherit leaked VMs; the periodic lifecycle below keeps
        // pressure bounded afterwards. Only aggregate counts reach the audit trail.
        let bootSummary = SandboxCleaner.cleanup(config: sandboxConfig)
        FileSandboxAuditLog.append(bootSummary)
        let handlerApprovals = context.approvals
        let handlerHub = context.hub
        await bus.setApprovalHandler { tool, call in
            // Decorates the shared filing path: file through
            // `fileRequest(tool:call:)` (same as the headless handler),
            // then broadcast and wait with a timeout.
            let request = await handlerApprovals.fileRequest(tool: tool, call: call)
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
        let orch = Orchestrator(conversations: conv, toolBus: bus, llm: FallbackDummyLLM())
        let appq = ApprovalQueue(permissionGate: gate)
        return ServerContext(
            conversations: conv,
            toolBus: bus,
            orchestrator: orch,
            memoryEngine: mem,
            permissionGate: gate,
            approvals: appq
        )
    }()
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
public func configureRuneWeaver(_ app: Application, context: ServerContext) throws {
    try context.config.requireLoopback()
    app.http.server.configuration.hostname = context.config.hostname
    app.http.server.configuration.port = context.config.port
    app.http.server.configuration.shutdownTimeout = .seconds(2)
    app.lifecycle.use(WSHubShutdownLifecycle(hub: context.hub))
    app.lifecycle.use(ServerSchedulerLifecycle(worker: context.schedulerWorker))
    app.lifecycle.use(SandboxCleanupLifecycle(scheduler: context.sandboxCleanup, config: context.sandboxConfig))
    app.lifecycle.use(BrowserWarmupLifecycle())
    app.runeWeaver = context
    registerRuneWeaverRoutes(app)
}

/// Registers every engine route on the application.
public func registerRuneWeaverRoutes(_ app: Application) {
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
    registerWebSocketRoute(app)
    registerDashboardRoutes(app)
}

/// Bounds an integer limit to the closed range `minLimit...maxLimit`.
func clampLimit(_ raw: Int, min minLimit: Int, max maxLimit: Int) -> Int {
    min(max(raw, minLimit), maxLimit)
}

/// Parses the raw `limit` query string strictly.
func parsedRawQueryLimit(_ req: Request, min minLimit: Int, max maxLimit: Int) throws -> Int? {
    guard let rawString = req.query[String.self, at: "limit"] else {
        return nil
    }
    let trimmed = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let raw = Int(trimmed) else {
        throw Abort(.badRequest, reason: "limit must be an integer between \(minLimit) and \(maxLimit)")
    }
    guard raw >= minLimit, raw <= maxLimit else {
        throw Abort(.badRequest, reason: "limit must be between \(minLimit) and \(maxLimit)")
    }
    return clampLimit(raw, min: minLimit, max: maxLimit)
}

/// Extracts, parses, and validates a query `limit` parameter with a fallback default.
func parseQueryLimit(
    _ req: Request,
    default defaultLimit: Int,
    min minLimit: Int = 1,
    max maxLimit: Int
) throws -> Int {
    if let value = try parsedRawQueryLimit(req, min: minLimit, max: maxLimit) {
        return value
    }
    return defaultLimit
}

/// Extracts, parses, and validates an optional query `limit` parameter.
func parseQueryLimit(
    _ req: Request,
    min minLimit: Int = 1,
    max maxLimit: Int
) throws -> Int? {
    try parsedRawQueryLimit(req, min: minLimit, max: maxLimit)
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

/// Validates a session title once for the rename route.
func validatedSessionTitle(_ raw: String) throws -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        throw Abort(.badRequest, reason: "title must not be empty")
    }
    guard trimmed.count <= UpdateSessionRequest.maxTitleLength else {
        throw Abort(.payloadTooLarge, reason: "title exceeds \(UpdateSessionRequest.maxTitleLength) characters")
    }
    return trimmed
}

/// Registers the chat completion route plus cancellation endpoint.
/// - Parameter app: Application receiving the route.
private func registerChatRoute(_ app: Application) {
    app.post(PathComponent.constant(ServerPaths.chat)) { req async throws -> OrchestratorResponse in
        let body = try req.content.decode(ChatRequest.self)
        let text = try validatedChatText(body.text)
        let context = req.application.runeWeaver
        let sessionID = body.resolvedSessionID
        let startTime = Date()

        // Bound parallel turns the same way as the WebSocket path so the REST
        // fallback cannot stack unbounded: the acquire and the registration
        // happen in one tracker hop, so concurrent fresh sessions cannot both
        // slip past the cap. A replacement turn for the same session always
        // fits (it supersedes the prior slot). Register before spawning so a
        // fast turn can never finish before its slot exists; the box bridges
        // a cancel arriving in that gap to the task created just below,
        // matching `handleWebSocketChat`.
        let taskBox = TurnTaskBox()
        guard let registration = await context.activeTurns.tryAcquire(sessionID: sessionID, onCancel: { taskBox.cancel() }) else {
            throw Abort(
                .tooManyRequests,
                reason: "Already running \(ActiveTurnTracker.maxConcurrentTurns) chat turns — wait for one to finish or cancel it, then retry."
            )
        }
        // Publish the running row immediately so dashboards badge the session
        // from the run log even before inference streams; every terminal path
        // below updates this same row instead of appending a second, keeping
        // one audit entry per turn like the WebSocket path.
        let initialEntry = await context.runs.append(
            kind: "chat",
            status: "running",
            message: text,
            sessionID: sessionID,
            durationMs: 0
        )
        await context.hub.broadcastRun(initialEntry)
        let chatTask: Task<OrchestratorResponse, Error> = Task {
            try await context.orchestrator.process(
                input: UserInput(
                    text: text,
                    sessionID: sessionID,
                    source: body.resolvedSource
                ),
                onEvent: { event in
                    // REST has no stream, but dashboard WebSocket clients still deserve
                    // mid-turn progress. Forward session-tagged warnings and per-round
                    // token usage through the shared broadcast helper so REST and resume
                    // share one session-filtered path and clients ignore other sessions;
                    // failures never fail the turn. The terminal response stays
                    // authoritative for reconciliation.
                    switch event {
                    case .warning, .turnTokens:
                        await broadcastWSEventFrame(event, sessionID: sessionID, context: context)
                    default:
                        break
                    }
                }
            )
        }
        taskBox.set(chatTask)
        // REST keeps one broadcast heartbeat per turn so multi-viewer dashboards
        // stay live while prompt evaluation is silent; the helper owns the why.
        let heartbeat = startRESTChatHeartbeat(context: context, sessionID: sessionID)
        defer { heartbeat.cancel() }

        do {
            // Tie the inner turn to the request lifetime so a disconnect cancels the model and
            // tools instead of leaving them running with no client, matching the WebSocket close
            // path.
            let response = try await withTaskCancellationHandler {
                try await chatTask.value
            } onCancel: {
                chatTask.cancel()
            }
            await context.activeTurns.unregister(sessionID: sessionID, token: registration.token)
            // Parked approval-gated turns persist as awaiting_approval instead of ok so the inbox
            // decision can transition the same session entry. The per-turn parked flag keeps a
            // stale prior park in this session from mis-marking a fresh normal turn.
            await broadcastParkedApprovals(for: response, context: context)
            let parkedStatus = if response.isParked {
                "awaiting_approval"
            } else {
                "ok"
            }
            await updateRESTChatRunAndBroadcast(
                context: context,
                initialEntry: initialEntry,
                startTime: startTime,
                status: parkedStatus,
                response: response
            )
            return response
        } catch is CancellationError {
            await context.activeTurns.unregister(sessionID: sessionID, token: registration.token)
            await updateRESTChatRunAndBroadcast(
                context: context,
                initialEntry: initialEntry,
                startTime: startTime,
                status: "cancelled"
            )
            throw Abort(.gone, reason: "Turn was cancelled by user")
        } catch let error as OrchestratorError {
            await context.activeTurns.unregister(sessionID: sessionID, token: registration.token)
            await updateRESTChatRunAndBroadcast(
                context: context,
                initialEntry: initialEntry,
                startTime: startTime,
                status: "error"
            )
            switch error {
            case .emptyInput:
                throw Abort(.badRequest, reason: "text must not be empty")
            case let .toolLoopExceeded(iterations):
                throw Abort(.unprocessableEntity, reason: "Tool loop exceeded \(iterations) rounds")
            case let .llmFailed(detail):
                throw Abort(.badGateway, reason: detail)
            }
        } catch {
            await context.activeTurns.unregister(sessionID: sessionID, token: registration.token)
            await updateRESTChatRunAndBroadcast(
                context: context,
                initialEntry: initialEntry,
                startTime: startTime,
                status: "error"
            )
            throw error
        }
    }

    registerChatCancelRoute(app)
}

/// Moves one REST turn's running audit row to its terminal state and broadcasts it.
/// Every terminal path funnels through this single update so the run log keeps
/// one entry per turn and REST stays in parity with the WebSocket path, which
/// updates the same initial row instead of appending a second.
/// - Parameters:
///   - context: Server context owning the run store and broadcast hub.
///   - initialEntry: Running row published before inference started.
///   - startTime: Turn start for duration accounting.
///   - status: Terminal status (`ok`, `awaiting_approval`, `cancelled`, or `error`).
///   - response: Successful turn output, when the turn produced one.
private func updateRESTChatRunAndBroadcast(
    context: ServerContext,
    initialEntry: RunLogEntry,
    startTime: Date,
    status: String,
    response: OrchestratorResponse? = nil
) async {
    let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
    let entry = await context.runs.update(
        id: initialEntry.id,
        status: status,
        response: response?.text,
        toolActions: response?.toolActions,
        totalTokens: response?.totalTokens,
        durationMs: durationMs
    ) ?? initialEntry
    await context.hub.broadcastRun(entry)
}

/// Registers the REST cancellation endpoint sharing the same turn tracker.
/// - Parameter app: Application receiving the route.
private func registerChatCancelRoute(_ app: Application) {
    app.post(PathComponent.constant(ServerPaths.chat), PathComponent.constant("cancel")) { req async throws -> CancelChatResponse in
        let body = try req.content.decode(CancelChatRequest.self)
        let cancelled = await req.application.runeWeaver.activeTurns.cancel(sessionID: body.sessionID)
        return CancelChatResponse(sessionID: body.sessionID, cancelled: cancelled)
    }
}

/// Spawns the REST liveness heartbeat broadcast for one in-flight turn.
/// - Parameters:
///   - context: Server context owning the WebSocket hub.
///   - sessionID: Session tagging the heartbeat frames.
/// - Returns: Heartbeat task cancelling with the turn.
private func startRESTChatHeartbeat(context: ServerContext, sessionID: UUID) -> Task<Void, Never> {
    Task { [context, sessionID] in
        // REST has no owning socket for multi-viewer turns so it broadcasts the
        // session-tagged heartbeat while the WebSocket path targets one socket.
        // Exactly one timer runs per REST turn; the caller cancels it on every
        // terminal path so concurrent heartbeats stay bounded to one per turn.
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: WSTurnAlive.intervalNanoseconds)
            } catch {
                break
            }
            if Task.isCancelled {
                break
            }
            if let alive = WSTurnAlive.frameText(sessionID: sessionID) {
                await context.hub.broadcast(text: alive)
            }
        }
    }
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
            let resolved = await context.approvals.decide(id: id, approved: body.approved, duration: body.resolvedDuration)
            guard resolved else {
                throw Abort(.notFound, reason: "Unknown approval \(raw)")
            }
            // Durable approvals create a stored grant inside `decide`, so
            // dashboards need a refresh signal; one-shot approvals store
            // nothing and leave the grants list untouched.
            if body.approved, body.resolvedDuration != .thisTime {
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

/// Registers run-log list plus entry routes.
private func registerRunRoutes(_ app: Application) {
    app.get(PathComponent.constant(ServerPaths.runs)) { req async throws -> RunLogsResponse in
        let limit = try parseQueryLimit(req, default: 50, min: 1, max: 200)
        let jobID = req.query[String.self, at: "jobID"].flatMap { UUID(uuidString: $0) }
        let sessionID = req.query[String.self, at: "sessionID"]
            .flatMap { UUID(uuidString: $0) }
            ?? req.query[String.self, at: "sessionId"].flatMap { UUID(uuidString: $0) }
            ?? req.query[String.self, at: "session_id"].flatMap { UUID(uuidString: $0) }
        let entries = await req.application.runeWeaver.runs.list(limit: limit, jobID: jobID, sessionID: sessionID)
        return RunLogsResponse(runs: entries)
    }
    app.get(PathComponent.constant(ServerPaths.runs), PathComponent.parameter("id")) { req async throws -> RunLogEntry in
        guard let raw = req.parameters.get("id"), let id = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "id must be a UUID")
        }
        guard let entry = await req.application.runeWeaver.runs.entry(id: id) else {
            throw Abort(.notFound, reason: "Unknown run \(raw)")
        }
        return entry
    }
    app.delete(PathComponent.constant(ServerPaths.runs)) { req async throws -> Response in
        await req.application.runeWeaver.runs.clear()
        return Response(status: .noContent)
    }
    app.delete(PathComponent.constant(ServerPaths.runs), PathComponent.parameter("id")) { req async throws -> Response in
        guard let raw = req.parameters.get("id"), let id = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "id must be a UUID")
        }
        await req.application.runeWeaver.runs.delete(id: id)
        return Response(status: .noContent)
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
            try config.save(to: url)
        } catch let error as ConfigError {
            throw Abort(.badRequest, reason: String(describing: error))
        } catch {
            throw Abort(.internalServerError, reason: error.localizedDescription)
        }
        return SettingsResponse(config: config, configPath: url.path)
    }
}

/// Registers session listing, retrieval, renaming, and deletion routes.
/// - Parameter app: Application receiving the routes.
private func registerSessionRoutes(_ app: Application) {
    let sessions = app.grouped(PathComponent.constant(ServerPaths.sessions))
    sessions.get { req async throws -> SessionsResponse in
        let list = await req.application.runeWeaver.conversations.listSessions()
        return SessionsResponse(sessions: list)
    }
    sessions.get(PathComponent.parameter("id")) { req async throws -> ConversationSession in
        guard let raw = req.parameters.get("id"), let id = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "id must be a UUID")
        }
        guard let session = await req.application.runeWeaver.conversations.session(id: id) else {
            throw Abort(.notFound, reason: "Unknown session \(raw)")
        }
        return session
    }
    sessions.get(PathComponent.parameter("id"), PathComponent.constant(ServerPaths.toolActions)) { req async throws -> SessionToolActionsResponse in
        guard let raw = req.parameters.get("id"), let id = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "id must be a UUID")
        }
        let context = req.application.runeWeaver
        guard let session = await context.conversations.session(id: id) else {
            throw Abort(.notFound, reason: "Unknown session \(raw)")
        }
        // Authoritative per-message records derived server-side with the
        // shared placeholder parser, ordered oldest message first so
        // clients never regex-parse placeholder lines themselves.
        let grouped = await context.conversations.toolActionsByMessage(for: id)
        let actions = session.messages.compactMap { message -> SessionMessageToolActions? in
            guard let list = grouped[message.id] else { return nil }
            // Carry the parent note's persisted creation time so reloads reconcile
            // to the same server instant that live done frames advertise.
            return SessionMessageToolActions(messageID: message.id, actions: list, completedAt: message.createdAt.timeIntervalSince1970)
        }
        return SessionToolActionsResponse(sessionID: id, actions: actions)
    }
    sessions.patch(PathComponent.parameter("id")) { req async throws -> Response in
        guard let raw = req.parameters.get("id"), let id = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "id must be a UUID")
        }
        let body = try req.content.decode(UpdateSessionRequest.self)
        let title = try validatedSessionTitle(body.title)
        // Renaming an unknown session is a 404 like `GET /sessions/:id`,
        // not a silent no-op: `updateTitle` skips missing sessions.
        guard await req.application.runeWeaver.conversations.session(id: id) != nil else {
            throw Abort(.notFound, reason: "Unknown session \(raw)")
        }
        await req.application.runeWeaver.conversations.updateTitle(id: id, title: title)
        return Response(status: .noContent)
    }
    sessions.delete(PathComponent.parameter("id")) { req async throws -> Response in
        guard let raw = req.parameters.get("id"), let id = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "id must be a UUID")
        }
        // Single orchestrator entry point drops working memory and the
        // billed total together so deletes never leak token totals.
        await req.application.runeWeaver.orchestrator.removeSession(id: id)
        return Response(status: .noContent)
    }
}

/// Registers the chat WebSocket with live approval prompts.
private func registerWebSocketRoute(_ app: Application) {
    app.webSocket(PathComponent.constant(ServerPaths.websocket)) { req, webSocket in
        let context = req.application.runeWeaver
        let connectionID = UUID()
        let box = WSSocketBox(webSocket)
        let connectionTasks = ConnectionChatTasks()
        let (stream, continuation) = AsyncStream<String>.makeStream()
        let connectionTask = Task { [box, context, connectionID, stream, connectionTasks] in
            await context.hub.add(id: connectionID, box: box)
            for await text in stream {
                if Task.isCancelled {
                    break
                }
                await handleWebSocketText(text, connectionID: connectionID, context: context, connectionTasks: connectionTasks)
                if Task.isCancelled {
                    break
                }
            }
            connectionTasks.cancelAll()
            await context.hub.remove(id: connectionID)
        }
        webSocket.onText { _, text in
            continuation.yield(text)
        }
        webSocket.onClose.whenComplete { _ in
            connectionTasks.cancelAll()
            continuation.finish()
            connectionTask.cancel()
        }
    }
}

/// Registers the static dashboard bundle routes.
public func registerDashboardRoutes(_ app: Application) {
    let bundle = DashboardBundle.resolve()
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

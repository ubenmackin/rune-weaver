// Rune Weaver App — macOS Menu Bar State and Lifecycle Model.

import AppKit
import Foundation
import Logging
import RuneWeaverCore
import RuneWeaverLLM
import RuneWeaverServer
import RuneWeaverTools
import SwiftUI
import Vapor

/// Active chat session snapshot for menu bar presentation.
public struct ActiveChatInfo: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let title: String

    public init(id: UUID, title: String) {
        self.id = id
        self.title = title
    }
}

@Observable
@MainActor
public final class AppModel {
    public var serverStatus: String = "Starting..."
    public var isRunning: Bool = false
    /// Bind address for the embedded service. The published values start at the
    /// built-in loopback default; `[server]` config supplies the operative
    /// defaults at boot unless a caller changes these fields first.
    public var hostname: String = ServerEndpointConfig.defaultHostname
    public var port: Int = ServerEndpointConfig.defaultPort
    public var providerName: String = "Detecting..."
    public var pendingApprovals: [PermissionRequest] = []
    public var activeChats: [ActiveChatInfo] = []
    public var nextScheduleText: String = "No jobs scheduled"
    public var lastRunSummaryText: String = "None yet"
    /// Whether either desktop tool is enabled via its tool-state toggle (the
    /// menu-bar Desktop Control section shows then). Seeded at boot and
    /// re-read from the live context on every refresh tick, so a toggle
    /// flipped at runtime surfaces.
    public var isDesktopEnabled: Bool = false
    /// Whether a desktop action batch is currently executing.
    public var isDesktopActive: Bool = false
    /// Set to true to signal an emergency abort of the current desktop batch.
    public var desktopEmergencyStop: Bool = false

    public let notificationManager = AppNotificationManager()
    private let serverRunner = ServerRunnerActor()
    /// Live engine context backing menu-bar refresh. Internal instead of
    /// private so refresh-path tests can attach a fixture context without
    /// booting the embedded service.
    var serverContext: ServerContext?
    private var vaporApp: Application?
    private var serverTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    /// Best-effort search warmup flight started after boot goes live; stored
    /// so quit can cancel it instead of leaving a detached ensure running.
    private var searchWarmupTask: Task<Void, Never>?
    /// The menu label can appear again each time the menu opens, so startup
    /// must be idempotent instead of binding the loopback port twice.
    private var hasStartedBoot = false
    /// Effective endpoint adopted at boot, so dashboard links follow a
    /// `[server]`-supplied host or port instead of the published override
    /// fields. Nil before a successful bind.
    private var boundEndpoint: ServerEndpointConfig?

    public init() {
        // Construction stays side-effect free: the notification center is
        // configured when boot starts, so building the model (including in
        // refresh-path tests) never touches UNUserNotificationCenter.
        setupNotificationCallbacks()
    }

    private func setupNotificationCallbacks() {
        notificationManager.onApprovalDecision = { [weak self] id, approved in
            // Notification actions carry no duration choice, so they map to a
            // one-shot this-time decision that never widens trust. Routing
            // through the shared decision helper keeps this path from
            // stranding a parked narrated turn the way a bare `decide` would.
            await self?.decideApproval(id: id, approved: approved, duration: .thisTime, widen: false)
        }

        notificationManager.onOpenDashboard = { [weak self] in
            self?.openDashboard()
        }
    }

    /// Entry point for the menu label; repeat appearances must not reboot.
    public func start() {
        guard !hasStartedBoot else { return }
        hasStartedBoot = true
        // Notification setup rides the boot entry (categories plus the
        // authorization prompt) so model construction stays side-effect
        // free; a retry after a failed boot re-runs it, which is idempotent.
        notificationManager.configure()
        Task {
            await bootServer()
        }
    }

    /// Builds the permission gate and served prompt from the live registry so served turns see
    /// every registered tool including discovered runes.
    private func buildGateAndSystemPrompt(
        plugins: [any Tool],
        config: RuneWeaverConfig
    ) async -> (PermissionGate, String) {
        let episodesDB = (config.memory.episodesDBPath as NSString).expandingTildeInPath
        let trustStore = SQLiteTrustStore(dbPath: episodesDB)
        let permissionGate = await PermissionGate.load(
            store: trustStore,
            pluginsDir: URL(fileURLWithPath: (config.plugins.pluginsDir as NSString).expandingTildeInPath)
        )
        await permissionGate.startPeriodicCleanup()
        let previewBus = ToolBus(permissionGate: permissionGate)
        let desktopNames = Set(DesktopTools.allToolNames)
        for tool in plugins {
            // Mirror the served boot path: desktop tools ship disabled so the
            // startup prompt never advertises capture the model cannot call.
            await previewBus.register(tool: tool, isEnabled: !desktopNames.contains(tool.name))
        }
        let previewPluginsURL = URL(fileURLWithPath: (config.plugins.pluginsDir as NSString).expandingTildeInPath)
        let previewStore = ToolRegistryStore(dbPath: (config.memory.episodesDBPath as NSString).expandingTildeInPath)
        let previewDiscovery = PluginDiscoveryService(pluginsDirectory: previewPluginsURL, store: previewStore)
        await previewDiscovery.discoverAndSync(toolBus: previewBus)
        // Same reconcile as the live bus: stored toggles decide, so the
        // prompt matches what is runnable.
        let stored = await ToolStateStore(dbPath: episodesDB).loadAll()
        for (name, enabled) in stored {
            if enabled {
                await previewBus.enableTool(named: name)
            } else {
                await previewBus.disableTool(named: name)
            }
        }
        let effectiveSystemPrompt = await SystemPromptComposer.resolve(flag: nil, toolBus: previewBus)
        return (permissionGate, effectiveSystemPrompt)
    }

    /// Preconditions a snapshot of the published bind values against the
    /// resolved owner-auth posture.
    ///
    /// The policy itself lives in `ServerConfig.requireBindable`: loopback always
    /// serves, a non-loopback endpoint serves only once an owner token resolved,
    /// and an unauthenticated LAN bind is refused rather than silently
    /// downgraded to an open surface.
    private func validatedBootBind(host: String, port: Int, authConfigured: Bool) -> ServerConfig? {
        let bindConfig = ServerConfig(hostname: host, port: port, authConfigured: authConfigured)
        do {
            try bindConfig.requireBindable(authConfigured: authConfigured)
        } catch {
            self.serverStatus = "Failed: \(error.localizedDescription)"
            self.hasStartedBoot = false
            return nil
        }
        return bindConfig
    }

    /// Starts the Vapor application for an already-wired context and marks
    /// the menu bar live, keeping serve ownership in one place so boot and
    /// retry share the same startup sequence.
    private func launchBootServer(context: ServerContext, serverConfig: ServerConfig) async throws {
        let env = Environment(name: "production", arguments: ["vapor"])
        let app = try await Application.make(env)
        self.vaporApp = app

        try configureRuneWeaver(app, context: context)

        let runner = serverRunner
        serverTask = Task {
            await runner.runServer(app: app)
        }

        self.isRunning = true
        self.serverStatus = "Running on \(serverConfig.hostname):\(serverConfig.port)"
        // Record the endpoint actually bound so dashboard links follow it even
        // when `[server]` supplied the values.
        self.boundEndpoint = ServerEndpointConfig(hostname: serverConfig.hostname, port: serverConfig.port)

        startPolling()
    }

    /// Warms the local search engine after the menu bar server is already live.
    /// Best-effort by design: failures stay in the server log so a down engine
    /// never flips a healthy boot into a failure, while the health endpoint's
    /// live stage plus reachability carries state to the dashboard dot and
    /// message. Hops off the main actor via a nonisolated factory (a plain
    /// Task here would inherit MainActor isolation from this class), with the
    /// handle retained so quit can cancel the flight.
    private func startSearchWarmup(browserConfig: BrowserConfig) {
        searchWarmupTask?.cancel()
        let captured = browserConfig
        searchWarmupTask = Self.makeSearchWarmupTask(browserConfig: captured)
    }

    /// Creates the warmup flight off MainActor isolation.
    /// Nonisolated so the minutes-budget ensure never blocks the menu bar while
    /// still inheriting task-locals and priority (unlike a detached task);
    /// the caller retains the handle for quit cancel.
    private nonisolated static func makeSearchWarmupTask(browserConfig: BrowserConfig) -> Task<Void, Never> {
        Task(priority: .background) {
            await Self.runSearchWarmup(browserConfig: browserConfig)
        }
    }

    /// Background search engine warmup execution running off @MainActor.
    private nonisolated static func runSearchWarmup(browserConfig: BrowserConfig) async {
        let searxngURL = browserConfig.searxngURL
        // Structured group ties the stage ticker to the ensure flight so parent
        // cancel or scope exit always reaps the watcher; no unstructured
        // watcher can leak past settle. Ticks only when stage or elapsed moves,
        // matching the serve boot lines for long pulls.
        await withDiscardingTaskGroup { group in
            group.addTask {
                var lastStage: SearXNGEnsurer.StartStage?
                var lastElapsed: Int?
                while !Task.isCancelled {
                    let progress = await SearXNGEnsurer.shared.currentStartProgress(for: searxngURL)
                    if let progress {
                        // Clamp clock skew so a future-dated start never renders negative.
                        let elapsed = max(0, Int(Date().timeIntervalSince(progress.startedAt)))
                        if progress.stage != lastStage || elapsed != lastElapsed {
                            lastStage = progress.stage
                            lastElapsed = elapsed
                            RuneWeaverLog.server.info("SearXNG \(progress.stage.userCopy)… (\(elapsed)s)")
                        }
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
            do {
                try await SearXNGEnsurer.shared.ensure(browser: browserConfig)
                RuneWeaverLog.server.info("SearXNG ready at \(browserConfig.searxngURL).")
            } catch is CancellationError {
                // Best-effort warmup swallows cancel so quit stays silent.
            } catch {
                RuneWeaverLog.server.warning("Search engine unavailable: \(error.localizedDescription)")
            }
            group.cancelAll()
        }
    }

    /// Stops the trust reaper started during gate build so a boot failure
    /// never leaks its sleep task, then drops half-wired state so a later
    /// retry boots clean instead of reusing a stopped gate.
    private func cleanupBootFailure(bootGate: PermissionGate?, error: Error) async {
        if let gate = bootGate {
            await gate.stopPeriodicCleanup()
            if serverContext?.permissionGate === gate {
                self.serverContext = nil
            }
        }
        if let app = vaporApp {
            try? await app.asyncShutdown()
            self.vaporApp = nil
        }
        self.serverStatus = "Failed: \(error.localizedDescription)"
        // Allow a later appearance to retry after a startup failure
        // instead of leaving the menu permanently failed.
        self.hasStartedBoot = false
    }

    private func bootServer() async {
        // Retained outside the do so the catch can stop the trust reaper
        // when Application.make or configure throws after the gate started it.
        var bootGate: PermissionGate?
        do {
            let config: RuneWeaverConfig
            do {
                config = try RuneWeaverConfig.loadDefault()
            } catch let error as ConfigError {
                // Refuse to boot from defaults when a stored file exists but
                // fails validation, so corrupt settings are never mistaken
                // for intentional defaults.
                self.serverStatus = "Failed: invalid config: \(String(describing: error))"
                self.hasStartedBoot = false
                return
            }

            // `[server]` supplies the bind defaults while the published fields
            // stay the override channel: a field left at its built-in default
            // adopts the configured value, and an explicit change wins. Snapshot
            // both once so an edit mid-boot cannot produce a half-old address;
            // the policy is applied after auth resolves.
            let bindHost = hostname == ServerEndpointConfig.defaultHostname ? config.server.hostname : hostname
            let bindPort = port == ServerEndpointConfig.defaultPort ? config.server.port : port

            // Resolve the owner token before the bind check so the bind policy
            // and the request gate share one posture, matching `serve`. A
            // declared but unreadable token (for example a loose-permissioned
            // file) fails boot here instead of surfacing at the gate; the
            // resolved value is never logged or rendered.
            let auth: ServerAuth?
            do {
                auth = try await ServerAuth.resolve(authConfig: config.auth)
            } catch {
                self.serverStatus = "Failed: owner auth could not be resolved: \(error.localizedDescription)"
                self.hasStartedBoot = false
                return
            }

            guard let bindConfig = validatedBootBind(
                host: bindHost,
                port: bindPort,
                authConfigured: auth != nil
            ) else { return }

            let secrets = SecretsManager()
            let keysByEntry = await resolveBootAPIKeys(config: config, secrets: secrets)

            let providers = LLMProviderFactory.makeProviders(from: config.llm, apiKeysByEntry: keysByEntry)
            let selectedProvider = selectBootProvider(config: config, providers: providers)

            self.providerName = selectedProvider.name

            let memoryEngine = makeBootMemoryEngine(config: config)
            let conversations = await loadBootConversations(config: config)

            let embedder = makeBootEmbedder(config: config, providers: providers)

            // Build the document index pipeline once so served recall, the nightly
            // trigger, and the `/index` routes share one store and coordinator; nil
            // when disabled keeps routes failing closed and recall unchanged.
            let indexComponents = ServerIndexBoot.makeComponents(
                config: config,
                embedder: embedder,
                visionLLM: selectedProvider
            )

            // Keep the menu-bar registry identical to the serve command's shared
            // plugin set so served turns see the same tools as terminal use.
            // The boot secrets instance backs both surrogate resolution and
            // media credential lookups so per-tool fresh instances cannot
            // diverge from the served context.
            let plugins = BuiltinToolPlugins.makeAllTools(
                config: config,
                memoryEngine: memoryEngine,
                embedder: embedder,
                mediaSecrets: secrets,
                secrets: secrets
            )
            let appLLMOrigins = LLMOrigins.serverURLs(from: config.llm)

            let (permissionGate, effectiveSystemPrompt) = await buildGateAndSystemPrompt(
                plugins: plugins,
                config: config
            )
            bootGate = permissionGate

            let context = await ServerContext.make(
                config: bindConfig,
                conversations: conversations,
                memoryEngine: memoryEngine,
                embedder: embedder,
                permissionGate: permissionGate,
                llm: selectedProvider,
                systemPrompt: effectiveSystemPrompt,
                schedulerConfig: config.scheduler,
                episodesDBPath: config.memory.episodesDBPath,
                pluginConfig: config.plugins,
                notifier: notificationManager,
                onApprovalRequested: { [weak self] req in
                    await self?.notificationManager.postApprovalNotification(req)
                    await self?.refreshPendingApprovals()
                },
                sandboxConfig: config.sandbox,
                browserConfig: config.browser,
                indexCoordinator: indexComponents?.coordinator,
                indexStore: indexComponents?.store,
                llmServerURLs: appLLMOrigins,
                engineConfig: config.engine,
                emailConfig: config.email,
                filesConfig: config.files,
                mediaConfig: config.media,
                desktopConfig: config.desktop,
                securityConfig: config.security,
                auth: auth,
                mediaSecrets: secrets,
                secrets: secrets
            )

            for tool in plugins {
                // Preserve live enabled state across re-registration: a bare
                // register would reset every tool to enabled, and desktop
                // tools ship disabled — without this, a fresh install would
                // flip them live between registration and the restore below.
                let isEnabled = await context.toolBus.isToolEnabled(named: tool.name)
                await context.toolBus.register(tool: tool, isEnabled: isEnabled)
            }
            // Registration resets no state now, but re-apply persisted
            // toggles anyway; the cached load makes this a memory-only pass
            // after the boot hydration in `make`.
            await context.restoreToolStates(forceReload: false)

            self.serverContext = context
            // Seed the menu section from the live tool-state toggles;
            // `refreshState` re-reads the live context each tick so a runtime
            // flip also surfaces.
            let screenshotLive = await context.toolBus.isToolEnabled(named: DesktopTools.screenshotToolName)
            let actionLive = await context.toolBus.isToolEnabled(named: DesktopTools.actionToolName)
            self.isDesktopEnabled = screenshotLive || actionLive

            try await launchBootServer(context: context, serverConfig: bindConfig)
            // Boot is already live at this point, so warm search detached:
            // a down engine must never block the menu bar or fail the boot.
            startSearchWarmup(browserConfig: config.browser)
        } catch {
            await cleanupBootFailure(bootGate: bootGate, error: error)
        }
    }

    private func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else { break }
                await self?.refreshState()
            }
        }
    }

    public func refreshState() async {
        guard let context = serverContext else { return }
        // Re-read the live tool-state toggles every tick so a dashboard or
        // tool-route flip surfaces the Desktop Control section (active
        // indicator plus Emergency Stop) without waiting for a restart.
        let screenshotLive = await context.toolBus.isToolEnabled(named: DesktopTools.screenshotToolName)
        let actionLive = await context.toolBus.isToolEnabled(named: DesktopTools.actionToolName)
        self.isDesktopEnabled = screenshotLive || actionLive
        let pending = await context.approvals.list()
        let runs = await context.runs.list(limit: 1)
        let runningIDs = await context.activeTurns.runningSessionIDs()
        // Mirror the shared desktop monitor so the indicator and Emergency
        // Stop appear for exactly the window a batch is dispatching input.
        let desktopRunning = await DesktopControlMonitor.shared.isActive
        if desktopRunning {
            self.isDesktopActive = true
        } else {
            self.isDesktopActive = false
        }
        // Consume the local stop latch once the batch settles so a later
        // batch starts clean instead of inheriting a stale abort.
        if desktopEmergencyStop, !desktopRunning {
            desktopEmergencyStop = false
            await DesktopControlMonitor.shared.clearEmergencyStop()
        }

        var chats: [ActiveChatInfo] = []
        for sid in runningIDs {
            let session = await context.conversations.session(id: sid)
            // Shared fallback keeps the menu label identical to the engine
            // display title for untitled sessions instead of a second prefix.
            let title = session?.displayTitle ?? ConversationSession.fallbackTitle(for: sid)
            chats.append(ActiveChatInfo(id: sid, title: title))
        }
        self.activeChats = chats.sorted(by: { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending })

        self.pendingApprovals = pending

        if let next = await context.schedulerWorker.nextFireDate() {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            let rel = formatter.localizedString(for: next.date, relativeTo: Date())
            self.nextScheduleText = "\(next.jobName) (\(rel))"
        } else {
            let jobs = await context.scheduler.list()
            let enabledCount = jobs.filter(\.enabled).count
            self.nextScheduleText = enabledCount == 0 ? "No active jobs" : "\(enabledCount) jobs active"
        }

        if let last = runs.first {
            let timeStr = DateFormatter.localizedString(from: last.timestamp, dateStyle: .none, timeStyle: .short)
            let status = last.status.uppercased()
            let msg = last.message.count > 30 ? String(last.message.prefix(30)) + "…" : last.message
            self.lastRunSummaryText = "[\(status)] \(msg) (\(timeStr))"
        } else {
            self.lastRunSummaryText = "None yet"
        }
    }

    public func refreshPendingApprovals() async {
        guard let context = serverContext else { return }
        self.pendingApprovals = await context.approvals.list()
    }
}

// MARK: - Actions & Navigation

public extension AppModel {
    func approve(id: UUID, duration: TrustDuration = .thisTime, widen: Bool = false) {
        Task {
            await decideApproval(id: id, approved: true, duration: duration, widen: widen)
        }
    }

    func deny(id: UUID) {
        Task {
            await decideApproval(id: id, approved: false, duration: .thisTime, widen: false)
        }
    }

    /// Resolves one approval through the same path the served inbox uses so
    /// every client converges and a parked narrated turn continues instead of
    /// stalling. The session tag plus decided call identifier must be captured
    /// before `decide` removes the pending entry, because the resume path needs
    /// the owning conversation and call to select the awaiting run. Decisions
    /// for untagged approvals stop here: REST and WebSocket both skip the shared
    /// resume helper when no session owns the request, and this path must match
    /// so a menu-bar decision cannot broadcast a decided frame carrying a null
    /// session or enter a resume no other client takes.
    private func decideApproval(id: UUID, approved: Bool, duration: TrustDuration, widen: Bool) async {
        guard let context = serverContext else { return }
        let pending = await context.approvals.request(id: id)
        let resolved = await context.approvals.decide(id: id, approved: approved, duration: duration, widen: widen)
        guard resolved else {
            await refreshPendingApprovals()
            return
        }
        // Durable approvals create a stored grant inside `decide`, so the
        // grants list must refresh; one-shot approvals store nothing. `widen`
        // only applies off `thisTime`, so a this-time decision never widens.
        if approved, duration != .thisTime {
            await context.hub.broadcastTrustGrantsChanged()
        }
        // Only session-tagged approvals own a conversation to resume. The
        // shared helper also emits the decided frame other tabs use to evict,
        // so tagged one-shot approvals still broadcast even though the resume
        // itself no-ops for them. Untagged approvals stay broadcast-free,
        // matching REST and WebSocket and keeping a null session off the wire.
        if pending?.sessionID != nil {
            await resumeNarratedApproval(
                id: id,
                approved: approved,
                context: context,
                sessionID: pending?.sessionID,
                decidedCallID: pending?.input.callID
            )
        }
        await refreshPendingApprovals()
    }

    /// Builds a dashboard URL from the effective bind values so host text can never inject a
    /// scheme or path, and so a concurrent edit cannot produce a half-old address. Only loopback
    /// hosts are opened: the app never puts the owner token in a URL, so a non-loopback engine
    /// address is left for the owner to open directly.
    private func dashboardURL(fragment: String? = nil, queryItems: [URLQueryItem]? = nil) -> URL? {
        // Follow the endpoint actually bound at boot (which may come from
        // `[server]`), falling back to the published fields before boot.
        let host = (boundEndpoint?.hostname ?? hostname).trimmingCharacters(in: .whitespacesAndNewlines)
        let portValue = boundEndpoint?.port ?? port
        guard ServerConfig.validPortRange.contains(portValue), !host.isEmpty else { return nil }
        guard ServerConfig(hostname: host, port: portValue).isLoopbackOnly else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = portValue
        components.path = "/"
        if let queryItems, !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        if let fragment {
            components.fragment = fragment
        }
        return components.url
    }

    func openDashboard() {
        if let url = dashboardURL() {
            NSWorkspace.shared.open(url)
        }
    }

    func openChat(id: UUID) {
        if let url = dashboardURL(fragment: "chat", queryItems: [URLQueryItem(name: "session", value: id.uuidString)]) {
            NSWorkspace.shared.open(url)
        }
    }

    func openSettings() {
        if let url = dashboardURL(fragment: "settings", queryItems: [URLQueryItem(name: "standalone", value: "true")]) {
            SettingsWindowController.shared.show(url: url)
        }
    }

    func quit() {
        pollingTask?.cancel()
        pollingTask = nil
        // Cancel the detached search flight up front so quit never leaves
        // the container start plus watch running after the menu bar exits.
        searchWarmupTask?.cancel()
        searchWarmupTask = nil
        let context = serverContext
        let app = vaporApp
        let task = serverTask
        serverTask = nil
        let runner = serverRunner
        Task(priority: .userInitiated) {
            await runner.shutdown(context: context, app: app)
            task?.cancel()
            NSApplication.shared.terminate(nil)
        }
    }

    /// Signals an emergency abort of all in-flight desktop automation.
    func emergencyStopDesktop() {
        desktopEmergencyStop = true
        isDesktopActive = false
        RuneWeaverLog.app.warning("Desktop emergency stop triggered by user")
        let context = serverContext
        Task {
            await DesktopControlMonitor.shared.requestEmergencyStop()
            if let context {
                for sessionID in await context.activeTurns.runningSessionIDs() {
                    await context.activeTurns.cancel(sessionID: sessionID)
                }
            }
        }
    }
}

/// Actor encapsulating background server execution and shutdown off the MainActor.
private actor ServerRunnerActor {
    func runServer(app: Application) async {
        do {
            try await app.execute()
        } catch {
            print("[RuneWeaverApp] Server terminated: \(error)")
        }
    }

    func shutdown(context: ServerContext?, app: Application?) async {
        if let context {
            await context.permissionGate.stopPeriodicCleanup()
            await context.sandboxCleanup.stop()
            await context.hub.closeAll()
        }
        if let app {
            try? await app.asyncShutdown()
        }
    }
}

/// Minimal fallback provider when no LLM provider is enabled in config.
///
/// Internal so boot helpers in a companion file share the same unconfigured
/// path without duplicating the placeholder turn.
struct FallbackDummyProvider: LLMProvider {
    var modelInfo: ModelInfo {
        ModelInfo(name: "unconfigured", provider: "none", contextLength: 4096, supportsTools: false, supportsEmbeddings: false)
    }

    func chat(messages _: [Message], tools _: [any Tool]) -> AsyncStream<LLMResponse> {
        AsyncStream { continuation in
            continuation.yield(LLMResponse(delta: "No LLM provider is configured. Please configure an LLM provider in Settings.", isFinished: true))
            continuation.finish()
        }
    }

    func embeddings(text _: [String]) async throws -> [[Float]] {
        []
    }
}

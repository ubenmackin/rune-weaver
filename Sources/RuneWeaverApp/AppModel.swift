// Rune Weaver App — macOS Menu Bar State and Lifecycle Model.
//
// Boots the loopback engine server in-process, maintains live status
// for the menu bar UI, handles approval decisions, and orchestrates
// graceful shutdown.

import AppKit
import Foundation
import Logging
import RuneWeaverCore
import RuneWeaverLLM
import RuneWeaverServer
import RuneWeaverTools
import SwiftUI
import Vapor

@MainActor
public final class AppModel: ObservableObject {
    @Published public var serverStatus: String = "Starting..."
    @Published public var isRunning: Bool = false
    @Published public var hostname: String = "127.0.0.1"
    @Published public var port: Int = 8082
    @Published public var providerName: String = "Detecting..."
    @Published public var pendingApprovals: [PermissionRequest] = []
    @Published public var nextScheduleText: String = "No jobs scheduled"
    @Published public var lastRunSummaryText: String = "None yet"

    public let notificationManager = AppNotificationManager()
    private var serverContext: ServerContext?
    private var vaporApp: Application?
    private var serverTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    /// The menu label can appear again each time the menu opens, so startup
    /// must be idempotent instead of binding the loopback port twice.
    private var hasStartedBoot = false

    public init() {
        notificationManager.configure()
        setupNotificationCallbacks()
    }

    private func setupNotificationCallbacks() {
        notificationManager.onApprovalDecision = { [weak self] id, approved in
            await self?.serverContext?.approvals.decide(id: id, approved: approved)
            await self?.refreshPendingApprovals()
        }

        notificationManager.onOpenDashboard = { [weak self] in
            Task { @MainActor [weak self] in
                self?.openDashboard()
            }
        }
    }

    /// Entry point for the menu label; repeat appearances must not reboot.
    public func start() {
        guard !hasStartedBoot else { return }
        hasStartedBoot = true
        Task {
            await bootServer()
        }
    }

    /// Builds the permission gate and served prompt from the live registry so
    /// served turns see every registered tool including discovered runes.
    /// The preview bus snapshots external runes before the service owns the
    /// registry; the service syncs the same directory again on boot, keeping
    /// both views consistent. Forwards the configured plugins directory so
    /// custom locations get the same protected-path enforcement.
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
        for tool in plugins {
            await previewBus.register(tool: tool)
        }
        let previewPluginsURL = URL(fileURLWithPath: (config.plugins.pluginsDir as NSString).expandingTildeInPath)
        let previewStore = ToolRegistryStore(dbPath: (config.memory.episodesDBPath as NSString).expandingTildeInPath)
        let previewDiscovery = PluginDiscoveryService(pluginsDirectory: previewPluginsURL, store: previewStore)
        await previewDiscovery.discoverAndSync(toolBus: previewBus)
        let effectiveSystemPrompt = await SystemPromptComposer.resolve(flag: nil, toolBus: previewBus)
        return (permissionGate, effectiveSystemPrompt)
    }

    /// Snapshots the published bind values so a later edit cannot change the
    /// address halfway through startup; loopback stays the only permitted
    /// interface until authentication exists.
    private func validatedBootBind() -> ServerConfig? {
        let bindHost = hostname
        let bindPort = port
        guard ServerConfig.validPortRange.contains(bindPort) else {
            self.serverStatus = "Failed: port \(bindPort) is out of range."
            self.hasStartedBoot = false
            return nil
        }
        let bindConfig = ServerConfig(hostname: bindHost, port: bindPort)
        guard bindConfig.isLoopbackOnly else {
            self.serverStatus = "Failed: refusing non-loopback bind without authentication."
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

        serverTask = Task.detached {
            do {
                try await app.execute()
            } catch {
                print("[RuneWeaverApp] Server terminated: \(error)")
            }
        }

        self.isRunning = true
        self.serverStatus = "Running on \(serverConfig.hostname):\(serverConfig.port)"

        startPolling()
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
        guard let bindConfig = validatedBootBind() else { return }
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

            let secrets = SecretsManager()
            var keysByEntry: [String: String] = [:]
            for (entryName, entry) in config.llm.providers {
                guard let envVar = entry.apiKeyEnv, !envVar.isEmpty else { continue }
                if let key = LLMProviderFactory.resolveAPIKey(explicit: nil, envVar: envVar) {
                    keysByEntry[entryName] = key
                } else if let stored = try? await secrets.retrieve(key: envVar) {
                    keysByEntry[entryName] = stored
                }
            }

            let providers = LLMProviderFactory.makeProviders(from: config.llm, apiKeysByEntry: keysByEntry)
            let selectedProvider: any LLMProvider = if let chosen = LLMProviderFactory.selectProvider(named: nil, from: providers, config: config.llm) {
                chosen
            } else {
                FallbackDummyProvider()
            }

            self.providerName = selectedProvider.name

            let memoryEngine = MemoryEngine(config: config.memory)
            let conversations = ConversationManager(episodesDBPath: config.memory.episodesDBPath)
            do {
                try await conversations.loadAll()
            } catch {
                // Start fresh but surface the failure so missing history is
                // never mistaken for an empty account.
                print("[RuneWeaverApp] Could not load conversation history; starting fresh: \(error)")
            }

            // Share one embeddings backend across memory tools and served
            // recall so menu-bar turns rank and write vectors like the CLI;
            // nil keeps keyword-only behavior when vectors are disabled.
            let embedder = EmbeddingsBackendFactory.makeBackend(
                memoryEmbeddingBackend: config.memory.embeddingBackend,
                router: LLMRouter(providers: providers)
            )

            // Keep the menu-bar registry identical to the serve command's shared
            // plugin set so served turns see the same tools as terminal use.
            var plugins: [any Tool] = []
            plugins += EmailTools.makeTools(emailConfig: config.email, sandboxConfig: config.sandbox)
            plugins += MemoryTools.makeTools(engine: memoryEngine, embedder: embedder)

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
                }
            )

            for tool in plugins {
                await context.toolBus.register(tool: tool)
            }
            // Registration resets each tool to enabled, so re-apply persisted
            // toggles after late builtin registration; the cached load makes
            // this a memory-only pass after the boot hydration in `make`.
            await context.restoreToolStates(forceReload: false)

            self.serverContext = context

            try await launchBootServer(context: context, serverConfig: bindConfig)
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
        let pending = await context.approvals.list()
        let runs = await context.runs.list(limit: 1)

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

    public func approve(id: UUID) {
        Task {
            await serverContext?.approvals.decide(id: id, approved: true)
            await refreshPendingApprovals()
        }
    }

    public func deny(id: UUID) {
        Task {
            await serverContext?.approvals.decide(id: id, approved: false)
            await refreshPendingApprovals()
        }
    }

    /// Builds a dashboard URL from a snapshot of the bind values so host text
    /// can never inject a scheme or path, and so a concurrent edit cannot
    /// produce a half-old address. Refuses non-loopback hosts because the
    /// service has no authentication yet.
    private func dashboardURL(fragment: String? = nil) -> URL? {
        let host = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        let portValue = port
        guard ServerConfig.validPortRange.contains(portValue), !host.isEmpty else { return nil }
        guard ServerConfig(hostname: host, port: portValue).isLoopbackOnly else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = portValue
        components.path = "/"
        if let fragment {
            components.fragment = fragment
        }
        return components.url
    }

    public func openDashboard() {
        if let url = dashboardURL() {
            NSWorkspace.shared.open(url)
        }
    }

    public func openSettings() {
        if let url = dashboardURL(fragment: "settings") {
            NSWorkspace.shared.open(url)
        }
    }

    public func quit() {
        pollingTask?.cancel()
        pollingTask = nil
        // Capture collaborators on the main actor, then shut down off it so
        // the blocking server shutdown never stalls interface termination.
        let context = serverContext
        let app = vaporApp
        let task = serverTask
        serverTask = nil
        Task.detached(priority: .userInitiated) {
            if let context {
                // Stop the trust reaper explicitly; nothing else owns its
                // lifetime past shutdown.
                await context.permissionGate.stopPeriodicCleanup()
                await context.hub.closeAll()
            }
            if let app {
                try? await app.asyncShutdown()
            }
            task?.cancel()
            await MainActor.run {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

/// Minimal fallback provider when no LLM provider is enabled in config.
private struct FallbackDummyProvider: LLMProvider {
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

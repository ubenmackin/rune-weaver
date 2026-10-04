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
    /// Single-line menu title for the embedded service. Holds only the
    /// display title (at most 40 characters), never the full error text, so
    /// the narrow menu stays readable while diagnostics live in the log plus
    /// the one-line detail below.
    public var serverStatus: String = "Starting…"
    /// Whether the latest boot attempt failed. The sole selector for the
    /// Failed menu affordance, so views never branch on title text and a
    /// stale failure cannot linger past a healthy transition.
    public var isServerFailed: Bool = false
    /// One-line failure summary for the menu (at most 140 characters), nil
    /// while the service is healthy. Kept in memory only and cleared on
    /// every healthy transition, so no failure text persists past recovery.
    public var serverStatusDetail: String?
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
    /// Whether a desktop action batch is currently executing.
    ///
    /// The sole selector for the Desktop Control menu section: armed-but-idle
    /// tool toggles stay out of the menu, so the section appears only while a
    /// batch runs and Emergency Stop is reachable exactly when it can act.
    public var isDesktopActive: Bool = false
    /// Set to true to signal an emergency abort of the current desktop batch.
    public var desktopEmergencyStop: Bool = false
    /// Whether an index run is in flight. Polled from the live coordinator on
    /// the shared refresh tick, so the menu label and Indexing section track
    /// runs without a second cadence.
    public var isIndexing: Bool = false
    /// Whether a cancel request is in flight for the run in flight. Claimed
    /// synchronously in `cancelIndexRun` so double-clicks collapse to one
    /// cancel, and cleared on the refresh tick once the run settles. Drives
    /// the disabled Cancelling state of the menu cancel button.
    public var isCancellingIndex: Bool = false
    /// Display label for what caused the run in flight (for example Manual Run).
    public var indexTriggerText: String = "Index Run"
    /// Display elapsed time for the run in flight (for example 12s).
    public var indexElapsedText: String = "…"
    /// Items examined by the run in flight, or zero (unknown) when no live
    /// frame has landed yet. Scanned includes skipped and errored items, so
    /// it never reports committed documents as a stand-in.
    public var indexScannedCount: Int = 0
    /// Documents written by the run in flight, or committed documents when no
    /// live frame has landed yet.
    public var indexIndexedCount: Int = 0
    /// Last relative item reported by the run in flight, truncated to menu
    /// width, or nil when the run has reported nothing yet.
    public var indexCurrentFile: String?
    /// Whether boot resolved no owner token, so the menu should surface the
    /// first-run onboarding sheet. Loopback stays bootable for local use; the
    /// flag only records that LAN binds stay refused until a token is minted.
    public var needsOwnerToken: Bool = false
    /// Durable completion flag for the Permissions window. Seeded from the
    /// store at construction so a relaunch never reopens guidance the owner
    /// already dismissed, while the menu entry can still open the window.
    public private(set) var hasCompletedPermissionsOnboarding: Bool = false
    /// Backing store for the Permissions completion flag. Injected so tests
    /// can isolate first-run state in a fresh defaults suite without touching
    /// the owner's real flag.
    private let permissionsOnboardingStore: PermissionsOnboardingStore
    /// Freshly minted owner token shown exactly once. Held in memory only and
    /// cleared on acknowledgement; never logged and never written outside the
    /// Keychain/file persistence owned by the auth store. The setter stays
    /// private so acknowledgement is the sole external mutation path and the
    /// secret cannot be overwritten from outside the model.
    public private(set) var generatedOnceToken: String?
    /// Non-secret SHA-256 prefix identifying the stored owner token, so
    /// Settings can prove which credential is active without rendering it.
    public var ownerTokenFingerprint: String?

    /// Credential-free origin of the stored token (environment, Keychain, or
    /// file), explaining to the owner where the next boot will read from.
    public var ownerTokenSourceLabel: String?
    /// Last owner-token mint or status failure, rendered as guidance rather
    /// than a bare error so the owner can act without opening Terminal.
    public var ownerTokenError: String?
    /// Whether a token mint is in flight, so Generate/Rotate stay single-flight
    /// instead of persisting competing credentials.
    public var isGeneratingOwnerToken: Bool = false
    /// Whether a server restart is in flight, so concurrent Retry double-clicks
    /// collapse to a single shutdown+boot sequence instead of racing the bind.
    public var isRestarting: Bool = false

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
    private let searchEnsurer: any SearXNGEnsuring
    private let onTerminate: @MainActor @Sendable () -> Void
    /// Tracks completed shutdown so repeat quit requests or delegate callbacks
    /// never run double-stop or race process termination.
    private(set) var isTerminated = false

    public init(
        permissionsOnboardingStore: PermissionsOnboardingStore = PermissionsOnboardingStore(),
        searchEnsurer: any SearXNGEnsuring = SearXNGEnsurer.shared,
        onTerminate: @escaping @MainActor @Sendable () -> Void = { NSApplication.shared.terminate(nil) }
    ) {
        // Construction stays side-effect free: the notification center is
        // configured when boot starts, so building the model (including in
        // refresh-path tests) never touches UNUserNotificationCenter.
        // The completion flag snapshots the durable store so first-run
        // guidance survives relaunches through UserDefaults, not memory.
        self.permissionsOnboardingStore = permissionsOnboardingStore
        self.hasCompletedPermissionsOnboarding = permissionsOnboardingStore.isCompleted
        self.searchEnsurer = searchEnsurer
        self.onTerminate = onTerminate
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
        Task { [weak self] in
            guard let self else { return }
            await self.bootServer()
        }
    }

    /// Maximum characters for the single-line menu title, sized for the
    /// narrow menu surface so a long hostname cannot widen it.
    private static let serverStatusTitleLimit = 40
    /// Maximum characters for the one-line failure summary, sized to carry
    /// an actionable hint without embedding the full error text.
    private static let serverStatusDetailLimit = 140

    /// Marks boot as starting, clearing any stale failure so a retry never
    /// renders a previous refusal beside fresh progress. Sole writer for the
    /// starting title alongside the running and failed helpers.
    public func setServerStarting() {
        serverStatus = "Starting…"
        isServerFailed = false
        serverStatusDetail = nil
    }

    /// Marks boot as running, clearing any stale failure. The title names
    /// the bound endpoint for healthy boots and appends the local-only cue
    /// when no owner token was resolved, so a loopback boot is never
    /// mistaken for a fully provisioned one.
    public func setServerRunning(host: String, port: Int, authConfigured: Bool) {
        // Trim here as well as at the bind site so a padded value set
        // directly still renders the classified address.
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = "Running on \(trimmedHost):\(port)"
        let title = authConfigured ? base : base + " — local only"
        serverStatus = Self.truncatedServerTitle(title)
        isServerFailed = false
        serverStatusDetail = nil
    }

    /// Marks boot as failed with a one-line summary, keeping the menu title
    /// fixed and short while the detail carries the actionable hint. The
    /// full error stays in the log; only the truncated tail reaches the UI
    /// and no secret ever flows through this path.
    public func setServerFailed(detail: String) {
        serverStatus = "Server failed"
        isServerFailed = true
        serverStatusDetail = Self.truncatedServerDetail(detail)
    }
}

// MARK: - Server Status String Helpers & Boot Lifecycle

extension AppModel {
    /// Collapses text to a single trimmed line so menu rows never wrap on
    /// an embedded newline from an underlying error.
    private static func singleLineServerText(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Caps the menu title to the narrow-surface limit, keeping the leading
    /// portion where the endpoint address starts.
    private static func truncatedServerTitle(_ title: String) -> String {
        let oneLine = singleLineServerText(title)
        guard oneLine.count > serverStatusTitleLimit else { return oneLine }
        return String(oneLine.prefix(serverStatusTitleLimit - 1)) + "…"
    }

    /// Caps the failure summary to the one-line limit, keeping the trailing
    /// portion where the actionable hint sits and prefixing an ellipsis to
    /// mark the truncation.
    private static func truncatedServerDetail(_ detail: String) -> String {
        let oneLine = singleLineServerText(detail)
        guard oneLine.count > serverStatusDetailLimit else { return oneLine }
        return "…" + String(oneLine.suffix(serverStatusDetailLimit - 1))
    }

    /// Preconditions a snapshot of the published bind values against the
    /// resolved owner-auth posture.
    ///
    /// The policy itself lives in `ServerConfig.requireBindable`: loopback always
    /// serves, a non-loopback endpoint serves only once an owner token resolved,
    /// and an unauthenticated LAN bind is refused rather than silently
    /// downgraded to an open surface.
    private func validatedBootBind(host: String, port: Int, authConfigured: Bool, allowedHosts: [String] = []) -> ServerConfig? {
        // Trim before validation so a padded file value classifies as the
        // loopback it names and the refusal message echoes the same address
        // the policy evaluated.
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let bindConfig = ServerConfig(hostname: trimmedHost, port: port, authConfigured: authConfigured, allowedHosts: allowedHosts)
        do {
            try bindConfig.requireBindable(authConfigured: authConfigured)
        } catch let error as ServerConfigError {
            if let full = error.errorDescription {
                RuneWeaverLog.app.error("Server bind refused: \(full)")
            }
            switch error {
            case .nonLoopbackRefused:
                // Fail-closed LAN bind without a token stays refused with an
                // actionable hint instead of the full policy text.
                setServerFailed(detail: "Bind \(trimmedHost) refused — no owner token")
            case .invalidPort:
                // Port bounds stay enforced by the shared range; the truncated
                // description carries the offending value without widening the menu.
                setServerFailed(detail: error.localizedDescription)
            }
            self.hasStartedBoot = false
            return nil
        } catch {
            RuneWeaverLog.app.error("Server bind refused: \(error.localizedDescription)")
            setServerFailed(detail: error.localizedDescription)
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
        // The running helper owns the healthy title plus the flag reset, so a
        // previous refusal cannot linger beside the live endpoint.
        self.setServerRunning(host: serverConfig.hostname, port: serverConfig.port, authConfigured: serverConfig.authConfigured)
        // Record the endpoint actually bound so dashboard links follow it even
        // when `[server]` supplied the values.
        self.boundEndpoint = ServerEndpointConfig(
            hostname: serverConfig.hostname,
            port: serverConfig.port,
            allowedHosts: serverConfig.allowedHosts
        )

        startPolling()
    }

    /// Warms the local search engine after the menu bar server is already live.
    /// Best-effort by design: failures stay in the server log so a down engine
    /// never flips a healthy boot into a failure, while the health endpoint's
    /// live stage plus reachability carries state to the dashboard dot and
    /// message. Hops off the main actor via a nonisolated factory (a plain
    /// Task here is non-isolated and does not inherit MainActor isolation,
    /// so isolation must be explicit), with the
    /// handle retained so quit can cancel the flight.
    private func startSearchWarmup(browserConfig: BrowserConfig) {
        searchWarmupTask?.cancel()
        let captured = browserConfig
        let ensurer = searchEnsurer
        searchWarmupTask = Self.makeSearchWarmupTask(browserConfig: captured, ensurer: ensurer)
    }

    /// Creates the warmup flight off MainActor isolation.
    /// Nonisolated so the minutes-budget ensure never blocks the menu bar while
    /// still inheriting task-locals and priority (unlike a detached task);
    /// the caller retains the handle for quit cancel.
    private nonisolated static func makeSearchWarmupTask(
        browserConfig: BrowserConfig,
        ensurer: any SearXNGEnsuring
    ) -> Task<Void, Never> {
        Task(priority: .background) {
            await Self.runSearchWarmup(browserConfig: browserConfig, ensurer: ensurer)
        }
    }

    /// Background search engine warmup execution running off @MainActor.
    private nonisolated static func runSearchWarmup(
        browserConfig: BrowserConfig,
        ensurer: any SearXNGEnsuring
    ) async {
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
                try await ensurer.ensure(browser: browserConfig)
                RuneWeaverLog.server.info("SearXNG ready at \(browserConfig.searxngURL).")
            } catch is CancellationError {
                // Best-effort warmup swallows cancel so quit stays silent.
                RuneWeaverLog.server.debug("SearXNG warmup cancelled.")
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
        // Keep the full failure in the log for diagnostics; only the
        // truncated one-line tail reaches the menu.
        RuneWeaverLog.app.error("Server boot failed: \(error.localizedDescription)")
        setServerFailed(detail: error.localizedDescription)
        // Allow a later appearance to retry after a startup failure
        // instead of leaving the menu permanently failed.
        self.hasStartedBoot = false
    }

    private func bootServer() async {
        // Clear any stale refusal up front so a retry starts from Starting…
        // and only the fresh outcome decides the next failed or running state.
        setServerStarting()
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
                // for intentional defaults. The full parse detail stays in
                // the log; the menu carries only the actionable hint.
                RuneWeaverLog.app.error("Invalid config: \(String(describing: error))")
                setServerFailed(detail: "Invalid config — check ~/.runeweaver/config.toml")
                self.hasStartedBoot = false
                return
            }

            // `[server]` supplies the bind defaults while the published fields
            // stay the override channel: a field left at its built-in default
            // adopts the configured value, and an explicit change wins. Snapshot
            // both once so an edit mid-boot cannot produce a half-old address;
            // the policy is applied after auth resolves.
            let rawBindHost = hostname == ServerEndpointConfig.defaultHostname ? config.server.hostname : hostname
            // Trim surrounding whitespace so a padded file value still boots
            // as the loopback it classifies as, and never reaches the bind
            // policy or the served hostname untrimmed.
            let bindHost = rawBindHost.trimmingCharacters(in: .whitespacesAndNewlines)
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
                // A declared but unreadable credential fails here with guidance
                // instead of surfacing at the request gate; the secret itself
                // never reaches the log or the menu.
                RuneWeaverLog.app.error("Owner auth resolve failed: \(error.localizedDescription)")
                setServerFailed(detail: "Owner auth unreadable — check Keychain plus file permissions")
                self.hasStartedBoot = false
                return
            }

            // A missing token is a first-run posture, not a boot failure:
            // loopback stays usable for local work while the menu surfaces an
            // actionable onboarding state instead of failing silently. The
            // fingerprint is derived and the raw value dropped immediately so
            // only the non-secret prefix ever reaches published state.
            if auth == nil {
                self.needsOwnerToken = true
                self.ownerTokenFingerprint = nil
                self.ownerTokenSourceLabel = nil
            } else {
                self.needsOwnerToken = false
                self.ownerTokenError = nil
                if let resolved = try? await ServerAuthTokenStore(authConfig: config.auth).resolve() {
                    self.ownerTokenFingerprint = ServerAuth.fingerprint(resolved.token)
                    self.ownerTokenSourceLabel = resolved.source.label
                } else {
                    self.ownerTokenFingerprint = nil
                    self.ownerTokenSourceLabel = nil
                }
            }

            guard let bindConfig = validatedBootBind(
                host: bindHost,
                port: bindPort,
                authConfigured: auth != nil,
                allowedHosts: config.server.allowedHosts
            ) else {
                // A non-loopback bind without a token stays refused rather
                // than downgraded to an open surface; keep the onboarding flag
                // so the menu can still offer in-app generation.
                if auth == nil {
                    self.needsOwnerToken = true
                }
                return
            }

            let pipeline = await buildBootPipeline(config: config, bindConfig: bindConfig, auth: auth)
            self.providerName = pipeline.selectedProvider.name
            bootGate = pipeline.permissionGate

            let context = try await makeBootServerContext(pipeline: pipeline)
            await registerBootTools(context: context, plugins: pipeline.plugins)

            self.serverContext = context
            // The Desktop Control menu section gates on live batch activity
            // (isDesktopActive mirrored from the shared monitor on each tick),
            // not on tool-state toggles, so boot seeds no enabled flag here.

            try await launchBootServer(context: context, serverConfig: bindConfig)
            // A loopback boot without a token stays live for local use, but
            // the title must still name the local-only posture so the owner
            // never mistakes it for a fully provisioned bind.
            if auth == nil {
                self.needsOwnerToken = true
                setServerRunning(host: bindConfig.hostname, port: bindConfig.port, authConfigured: false)
            } else {
                self.needsOwnerToken = false
            }
            // Boot is already live at this point, so warm search detached:
            // a down engine must never block the menu bar or fail the boot.
            startSearchWarmup(browserConfig: config.browser)
        } catch {
            await cleanupBootFailure(bootGate: bootGate, error: error)
        }
    }
}

// MARK: - State Refresh & Status Display

extension AppModel {
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
        // Poll the live index pair on the same tick so the label indicator
        // and the Indexing section track runs without a second cadence.
        await refreshIndexState(context: context)

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

    /// Refreshes the menu-bar indexing snapshot from the live index pair.
    ///
    /// Prefers the coordinator live totals while a run is in flight and falls
    /// back to the store committed document count for indexed only when the run
    /// started but no live frame has landed yet. Scanned counts examined items
    /// including skipped and errored ones, so it stays zero (unknown) rather
    /// than misreporting committed documents. Idle clears the flag so the
    /// section hides.
    private func refreshIndexState(context: ServerContext) async {
        // Snapshot the pair atomically so the coordinator and store always
        // belong to one generation, never a half-swapped mix.
        let liveIndex = context.liveIndexSnapshot()
        guard let coordinator = liveIndex.coordinator else {
            self.isIndexing = false
            self.isCancellingIndex = false
            return
        }
        if let live = await coordinator.liveTotals {
            self.isIndexing = true
            self.indexTriggerText = Self.indexTriggerLabel(for: live.trigger)
            self.indexElapsedText = Self.indexElapsedText(milliseconds: live.elapsedMs)
            self.indexScannedCount = live.scanned
            self.indexIndexedCount = live.indexed
            self.indexCurrentFile = Self.truncatedIndexCurrent(live.current)
        } else {
            let running = await coordinator.isRunning
            self.isIndexing = running
            if running {
                // No live frame yet (the run just started); show the committed
                // document count as indexed so the row never reads zero for a
                // live run. Scanned counts examined items including skipped and
                // errored ones, so it stays zero (unknown) instead of
                // misreporting committed documents as scanned.
                if let store = liveIndex.store {
                    do {
                        let stats = try await store.stats()
                        self.indexScannedCount = 0
                        self.indexIndexedCount = stats.documents
                    } catch {
                        // A store failure must never read as an empty index:
                        // log it and keep the previous counts so 0/0 cannot
                        // masquerade as an empty store.
                        RuneWeaverLog.app.warning("Index stats unavailable for menu snapshot: \(error.localizedDescription)")
                    }
                } else {
                    // No store wired for this context; keep the previous
                    // counts and let the elapsed placeholder carry the
                    // unknown state instead of inventing a zero.
                    RuneWeaverLog.app.warning("Index store unavailable for menu snapshot; keeping previous counts.")
                }
                self.indexTriggerText = "Index Run"
                self.indexElapsedText = "…"
                self.indexCurrentFile = nil
            } else {
                // Idle resets display state so a later run starts clean
                // instead of inheriting a stale row.
                self.isCancellingIndex = false
                self.indexTriggerText = "Index Run"
                self.indexElapsedText = "…"
                self.indexScannedCount = 0
                self.indexIndexedCount = 0
                self.indexCurrentFile = nil
            }
        }
    }

    /// Maps an index run trigger to the menu display copy, matching the
    /// dashboard wording for run notices and history rows.
    /// - Parameter trigger: What caused the run.
    /// - Returns: Plain-language label for the menu row.
    static func indexTriggerLabel(for trigger: IndexRunTrigger) -> String {
        switch trigger {
        case .nightly:
            "Nightly Run"
        case .onDemand:
            "Manual Run"
        case .catchUp:
            "Catch-Up Run"
        }
    }

    /// Formats an elapsed millisecond count for the one-line menu row.
    /// - Parameter milliseconds: Milliseconds since the run began.
    /// - Returns: Compact duration such as 12s, 1m 5s, or 2h 3m.
    static func indexElapsedText(milliseconds: Int) -> String {
        let totalSeconds = max(0, milliseconds / 1000)
        if totalSeconds < 60 {
            return "\(totalSeconds)s"
        }
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if minutes < 60 {
            return "\(minutes)m \(seconds)s"
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return "\(hours)h \(remainingMinutes)m"
    }

    /// Maximum characters for the menu-bar current-file row. Sized for the
    /// narrow menu surface: long enough to keep the filename plus a few
    /// parent segments, short enough to avoid widening the menu.
    private static let indexCurrentMenuLimit = 48

    /// Truncates a relative index path to menu width, keeping the trailing
    /// portion so the filename stays visible (the suffix is significant for
    /// paths, while a leading prefix would hide it behind parent directories).
    /// - Parameter current: Last relative item reported by the run.
    /// - Returns: Truncated row text, or nil when there is nothing to show.
    static func truncatedIndexCurrent(_ current: String?) -> String? {
        guard let current, !current.isEmpty else { return nil }
        if current.count <= indexCurrentMenuLimit {
            return current
        }
        return "…" + String(current.suffix(indexCurrentMenuLimit))
    }
}

// MARK: - Actions & Navigation

extension AppModel {
    public func approve(id: UUID, duration: TrustDuration = .thisTime, widen: Bool = false) {
        Task {
            await decideApproval(id: id, approved: true, duration: duration, widen: widen)
        }
    }

    public func deny(id: UUID) {
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

    /// Whether the web dashboard and web settings can be opened from the menu.
    public var isDashboardAvailable: Bool {
        // A refused bind leaves no live endpoint while the published fields
        // still fall back to loopback defaults, so availability must require
        // a successful bind instead of a constructible URL alone; otherwise
        // the menu would offer a dashboard that has no server behind it.
        guard isRunning, boundEndpoint != nil else { return false }
        return dashboardURL() != nil
    }

    /// Builds a dashboard URL from the effective bind values so host text can never inject a
    /// scheme or path, and so a concurrent edit cannot produce a half-old address.
    /// When bound to an all-interfaces wildcard (0.0.0.0, ::, [::], *), resolves to 127.0.0.1
    /// so local navigation reaches the service via loopback.
    public func dashboardURL(fragment: String? = nil, queryItems: [URLQueryItem]? = nil) -> URL? {
        // Follow the endpoint actually bound at boot (which may come from
        // `[server]`), falling back to the published fields before boot.
        let host = (boundEndpoint?.hostname ?? hostname).trimmingCharacters(in: .whitespacesAndNewlines)
        let portValue = boundEndpoint?.port ?? port
        guard ServerConfig.validPortRange.contains(portValue), !host.isEmpty else { return nil }

        // All-interfaces binds (0.0.0.0, ::, [::], *) listen across every interface
        // including loopback; route local dashboard/settings navigation to 127.0.0.1.
        let lower = host.lowercased()
        let urlHost = if lower == "0.0.0.0" || lower == "::" || lower == "[::]" || lower == "*" {
            "127.0.0.1"
        } else if lower.hasPrefix("["), lower.hasSuffix("]"), lower.count >= 2 {
            // URLComponents.host expects the bare IPv6 literal without outer brackets.
            String(lower.dropFirst().dropLast())
        } else {
            host
        }

        var components = URLComponents()
        components.scheme = "http"
        components.host = urlHost
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

    public func openDashboard() {
        if let url = dashboardURL() {
            NSWorkspace.shared.open(url)
        }
    }

    public func openChat(id: UUID) {
        if let url = dashboardURL(fragment: "chat", queryItems: [URLQueryItem(name: "session", value: id.uuidString)]) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Opens the dashboard on the Memory section's Index Status inner tab,
    /// where the run controls live beside Search and Memory. The fragment
    /// carries the indexing subpath the dashboard routes on, so the inner tab
    /// opens selected instead of the default Search and Memory view.
    public func openIndexStatus() {
        if let url = dashboardURL(fragment: "memory/indexing") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Requests cancellation of the run in flight through the coordinator
    /// cancel path, keeping committed batches so the next run resumes from
    /// there. Claims the cancelling flag synchronously so double-clicks
    /// collapse to one cancel; the flag clears on the refresh tick once the
    /// run settles. Returns immediately; the refresh tick hides the section
    /// once the run settles.
    public func cancelIndexRun() {
        guard !isCancellingIndex else { return }
        guard let context = serverContext else {
            RuneWeaverLog.app.warning("Cancel index run requested with no live engine context.")
            return
        }
        guard let coordinator = context.liveIndexSnapshot().coordinator else {
            RuneWeaverLog.app.warning("Cancel index run requested with no index coordinator.")
            return
        }
        isCancellingIndex = true
        Task {
            await coordinator.cancel()
        }
    }

    public func openSettings() {
        if let url = dashboardURL(fragment: "settings", queryItems: [URLQueryItem(name: "standalone", value: "true")]) {
            Task { [weak self] in
                guard let self else { return }
                let sessionToken = try? await self.serverContext?.auth?.createSession()
                await SettingsWindowController.shared.show(url: url, sessionToken: sessionToken)
            }
        }
    }

    public func openOwnerAccess() {
        OwnerAccessWindowController.shared.show(model: self)
    }

    /// Marks Permissions onboarding complete and persists it, so the window
    /// opens exactly once per install while the menu entry stays available.
    public func markPermissionsOnboardingCompleted() {
        hasCompletedPermissionsOnboarding = true
        permissionsOnboardingStore.markCompleted()
    }

    /// Opens the Permissions checklist window on demand from the menu or the
    /// first-run gate, always with a fresh live view model from the controller.
    public func openPermissions() {
        PermissionsWindowController.shared.show(model: self)
    }

    /// Shuts down background polling, server runner, and the auto-started search engine container.
    /// Idempotent so multiple quit notifications or tests never double-stop.
    public func stopForQuit() async {
        guard !isTerminated else { return }
        isTerminated = true
        pollingTask?.cancel()
        pollingTask = nil
        // Cancel the detached search flight up front so quit reaps any in-flight ensure.
        searchWarmupTask?.cancel()
        searchWarmupTask = nil
        let context = serverContext
        let app = vaporApp
        let task = serverTask
        serverTask = nil
        let runner = serverRunner
        let ensurer = searchEnsurer

        async let stopServer: Void = runner.shutdown(context: context, app: app)
        async let stopSearch: Void = ensurer.stop()
        _ = await (stopServer, stopSearch)
        task?.cancel()
    }

    public func quit() {
        Task(priority: .userInitiated) { @MainActor [weak self] in
            guard let self else { return }
            await self.stopForQuit()
            self.onTerminate()
        }
    }

    /// Signals an emergency abort of all in-flight desktop automation.
    public func emergencyStopDesktop() {
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

// MARK: - Owner Token Onboarding & Settings Access

extension AppModel {
    /// Mints the first owner token for a fresh install through the shared
    /// auth store, so the menu bar never reimplements randomness or storage.
    /// The running service keeps its boot-time posture until the
    /// acknowledgement restart, which is why the needs flag stays set here.
    public func generateOwnerToken() {
        guard !isGeneratingOwnerToken else { return }
        // Set synchronously before the Task hops so a double-tap cannot pass
        // the guard twice and persist competing credentials; the async mint
        // below only clears it.
        isGeneratingOwnerToken = true
        Task { [weak self] in
            guard let self else { return }
            await self.mintOwnerToken(replacing: false)
        }
    }

    /// Replaces the stored owner token through the same store the first mint
    /// uses, keeping Terminal optional for rotation. The live service still
    /// enforces the previous credential until the acknowledgement restart
    /// adopts the replacement, so a lost copy can be recovered by rotating
    /// again before acknowledging.
    public func rotateOwnerToken() {
        guard !isGeneratingOwnerToken else { return }
        // Same synchronous single-flight as generation: claim the flag on the
        // MainActor before spawning the mint Task.
        isGeneratingOwnerToken = true
        Task { [weak self] in
            guard let self else { return }
            await self.mintOwnerToken(replacing: true)
        }
    }

    /// Re-reads the stored credential without minting, so Settings can prove
    /// which token is active by fingerprint prefix alone. The raw value is
    /// dropped immediately after hashing; only the prefix and source label
    /// ever reach published state.
    public func refreshOwnerTokenStatus() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let config = try RuneWeaverConfig.loadDefault()
                let store = ServerAuthTokenStore(authConfig: config.auth)
                if let resolved = try await store.resolve() {
                    self.ownerTokenFingerprint = ServerAuth.fingerprint(resolved.token)
                    self.ownerTokenSourceLabel = resolved.source.label
                    self.ownerTokenError = nil
                    // The needs flag tracks the running service posture, not
                    // merely stored presence: a freshly minted token still
                    // needs the restart before the gate enforces it.
                    if self.serverContext?.auth != nil {
                        self.needsOwnerToken = false
                    }
                } else {
                    // No stored credential means LAN binds stay refused; keep
                    // the onboarding flag so the menu keeps offering generation.
                    self.ownerTokenFingerprint = nil
                    self.ownerTokenSourceLabel = nil
                    if self.serverContext?.auth == nil {
                        self.needsOwnerToken = true
                    }
                }
            } catch {
                // A loose-permissioned file or unreadable Keychain must read
                // as guidance, never as a silent empty state that looks
                // unconfigured.
                self.ownerTokenError = "Could not read the owner token: \(error.localizedDescription)"
            }
        }
    }

    /// Clears the once-shown secret from memory and restarts the embedded
    /// service so the gate adopts the stored credential. Clearing first
    /// guarantees the secret cannot linger in published state past the owner's
    /// confirmation, even if the restart itself fails.
    public func acknowledgeGeneratedToken() {
        generatedOnceToken = nil
        restartServerToAdoptToken()
    }

    /// Restarts the embedded service without terminating the menu bar, so a
    /// newly minted token takes effect without relaunching the app. The
    /// shutdown mirrors quit (polling, warmup, gate, hub, app) but returns to
    /// boot instead of terminating.
    public func restartServerToAdoptToken() {
        guard !isRestarting else { return }
        // Claim synchronously on the MainActor before the Task hops so a
        // concurrent Retry double-click collapses to one shutdown+boot.
        isRestarting = true
        Task { [weak self] in
            guard let self else { return }
            await self.restartServer()
        }
    }

    /// Mints via the single-owner rotation path so CSPRNG bytes plus
    /// Keychain/0600 persistence stay single-sourced with the terminal flow.
    /// An empty seed is honest for first generation because the throwaway
    /// verifier is never served; rotation seeds from the stored value so a
    /// storage failure leaves the working credential untouched.
    private func mintOwnerToken(replacing: Bool) async {
        // The single-flight flag was already claimed synchronously by
        // generateOwnerToken/rotateOwnerToken before the Task hop, so a
        // double-tap cannot enter here twice; this hop only clears it.
        ownerTokenError = nil
        defer { isGeneratingOwnerToken = false }
        do {
            let config = try RuneWeaverConfig.loadDefault()
            let store = ServerAuthTokenStore(authConfig: config.auth)
            let existing = try await store.resolve()
            if !replacing, existing != nil {
                // Refusing to overwrite keeps a single call from silently
                // invalidating every other device; rotation is the explicit
                // path for replacement.
                self.ownerTokenError = "An owner token is already configured (\(existing?.source.label ?? "stored")). Use Rotate to replace it."
                if let existing {
                    self.ownerTokenFingerprint = ServerAuth.fingerprint(existing.token)
                    self.ownerTokenSourceLabel = existing.source.label
                }
                return
            }
            if replacing, existing == nil {
                // Rotating with nothing stored would mint under a misleading
                // label, so generation stays the honest entry point instead.
                self.ownerTokenError = "No owner token is configured yet. Use Generate to create one."
                return
            }
            let seeder = if replacing, let current = existing {
                ServerAuth(initialToken: current.token, store: store)
            } else {
                ServerAuth(initialToken: "", store: store)
            }
            // The store persists before the swap, so a failure here leaves the
            // previous credential valid instead of stranding the owner.
            let token = try await seeder.rotate()
            // Held in memory only for the once-only display; Settings and
            // status surfaces render the fingerprint derived below, never this.
            self.generatedOnceToken = token
            self.ownerTokenFingerprint = ServerAuth.fingerprint(token)
            if let reread = try? await store.resolve() {
                self.ownerTokenSourceLabel = reread.source.label
            }
        } catch let error as ServerAuthError {
            // An environment override outranks persisted storage across
            // restarts, so its guidance must name the variable instead of
            // reporting a success that the next boot would undo.
            self.ownerTokenError = error.localizedDescription
        } catch {
            self.ownerTokenError = "Could not generate the owner token: \(error.localizedDescription)"
        }
    }

    /// Shuts down the live service and boots again from disk, letting a newly
    /// stored token flow through the same resolve-plus-bind path as launch.
    /// Live state is dropped before reboot so a failed restart never resumes
    /// a half-wired context, and the boot flag is held across the hop so a
    /// concurrent menu appearance cannot bind the port twice.
    private func restartServer() async {
        // The isRestarting flag was claimed synchronously by
        // restartServerToAdoptToken; clearing here releases the single-flight
        // even when the reboot fails, so a later Retry can run.
        defer { isRestarting = false }
        pollingTask?.cancel()
        pollingTask = nil
        searchWarmupTask?.cancel()
        searchWarmupTask = nil
        let context = serverContext
        let app = vaporApp
        let task = serverTask
        serverTask = nil
        let runner = serverRunner
        await runner.shutdown(context: context, app: app)
        task?.cancel()
        self.serverContext = nil
        self.vaporApp = nil
        self.boundEndpoint = nil
        self.isRunning = false
        // Hold the boot flag across the hop so the relaunch is the only
        // writer; a failure inside boot clears it for a later retry.
        self.hasStartedBoot = true
        await bootServer()
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

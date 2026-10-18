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

/// Lifecycle hook running sandbox container reclamation on a cadence.
struct SandboxCleanupLifecycle: LifecycleHandler {
    let scheduler: SandboxCleanupScheduler
    let config: ContainersConfig
    let approvals: ApprovalQueue

    func didBootAsync(_: Application) async throws {
        await scheduler.runOnce(config: config, approvals: approvals)
        await scheduler.start(config: config, approvals: approvals)
    }

    func shutdownAsync(_: Application) async {
        await scheduler.stop()
    }
}

/// Lifecycle hook warming the managed browser Python venv on serve boot.
final class BrowserWarmupLifecycle: LifecycleHandler {
    /// Retained warmup flight so shutdown can cancel it instead of leaving an ensure running after
    /// the server exits, mirroring the menu bar quit-cancel.
    private let warmupState: OSAllocatedUnfairLock<Task<Void, Never>?> = OSAllocatedUnfairLock(initialState: nil)

    func didBootAsync(_: Application) async throws {
        // Structured child inheriting task-locals and priority so logging plus tracing flow from
        // boot; never awaited here so a minutes-budget first provision cannot hold the bind.
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
    app.routes.defaultMaxBodySize = "2mb"
    app.http.server.configuration.hostname = context.config.hostname
    app.http.server.configuration.port = context.config.port
    app.http.server.configuration.shutdownTimeout = .seconds(2)
    app.lifecycle.use(WSHubShutdownLifecycle(hub: context.hub))
    app.lifecycle.use(ServerSchedulerLifecycle(worker: context.schedulerWorker))
    app.lifecycle.use(SandboxCleanupLifecycle(scheduler: context.sandboxCleanup, config: context.containersConfig, approvals: context.approvals))
    app.lifecycle.use(BrowserWarmupLifecycle())
    // Boot and nightly cadence for the security probe suite. Both record
    // into the verified pulse; boot additionally refuses to serve when a
    // fail-closed verifier fails.
    app.lifecycle.use(SecurityProbeBootLifecycle())
    app.lifecycle.use(SecurityProbeNightlyLifecycle())
    // Registered before the route middleware so the suite observes the
    // committed response every inner producer recorded; only a successful
    // policy write triggers a re-run, so previews and refused saves stay quiet.
    app.middleware.use(SecurityProbePolicyWriteMiddleware())
    app.runeWeaver = context
    app.runeWeaverAuth = resolvedAuth
    registerRuneWeaverRoutes(app)
}

/// Registers every engine route on the application.
public func registerRuneWeaverRoutes(_ app: Application) {
    app.routes.defaultMaxBodySize = "2mb"
    let serverConfig = app.runeWeaver.config
    // Global headers run outermost so Host gate rejections flow through the
    // same nosniff/DENY/referrer plus proxy-aware HSTS path instead of
    // bypassing it; the Host gate also applies them directly for defense in depth.
    app.middleware.use(GlobalSecurityHeadersMiddleware())
    app.middleware.use(HostValidationMiddleware(
        hostname: serverConfig.hostname,
        allowedHosts: serverConfig.allowedHosts,
        authConfigured: serverConfig.authConfigured
    ))
    // Resolve the bundle once so the public-path gate and the delivery handler
    // agree on exactly which bytes are real static artifacts.
    let dashboardBundle = DashboardBundle.resolve()
    if let auth = app.runeWeaverAuth {
        app.middleware.use(ServerAuthMiddleware(auth: auth, dashboardBundle: dashboardBundle))
        registerAuthRotateRoute(app, auth: auth)
        registerAuthSessionRoutes(app, auth: auth)
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
    registerScheduledSendRoutes(app)
    registerSovereignReattestRoute(app)
    registerSovereignRebaselineRoute(app)
    registerRunRoutes(app)
    registerGoalRoutes(app)
    registerIdeaRoutes(app)
    registerWorkspaceRoutes(app)
    registerSearchRoutes(app)
    registerBrowserRoutes(app)
    registerSettingsRoutes(app)
    registerIndexRoutes(app)
    registerFileRoutes(app)
    registerWebSocketRoute(app)
    registerDashboardRoutes(app, bundle: dashboardBundle)
}

/// Registers the owner token rotation route. The handler never echoes the credential into logs or
/// audit entries, only into the one-time response body the owner must capture.
private func registerAuthRotateRoute(_ app: Application, auth: ServerAuth) {
    app.post(PathComponent.constant(ServerPaths.auth), PathComponent.constant(ServerPaths.rotate)) { req async throws -> Response in
        let token = try await auth.rotate()
        // Rotation retires the previous credential for every client.
        let liveGeneration = await auth.currentGeneration()
        await req.application.runeWeaver.hub.retire(liveGeneration: liveGeneration)
        // Encoded through the request's configured encoder for contract parity,
        // then marked no-store so a one-time credential is never cached.
        let response = try await ServerAuthRotateResponse(token: token).encodeResponse(for: req)
        response.headers.replaceOrAdd(name: "Cache-Control", value: "no-store")
        let sessionID = try await auth.createSession()
        response.cookies[ServerAuthRequest.sessionCookieName] = ServerAuthRequest.makeSessionCookie(
            token: sessionID,
            isSecure: ServerAuthRequest.isRequestSecure(req)
        )
        return response
    }
}

/// Request body for `POST /auth/session`.
private struct AuthSessionRequestBody: Content {
    let token: String?
}

/// Registers the owner browser session routes (`POST /auth/session` and `DELETE /auth/session`).
private func registerAuthSessionRoutes(_ app: Application, auth: ServerAuth) {
    let authGroup = app.grouped(PathComponent.constant(ServerPaths.auth))

    // POST /auth/session (login)
    authGroup.post(PathComponent.constant(ServerPaths.session)) { req async throws -> Response in
        // Throttle on both the derived client and the direct peer, matching the
        // middleware gate: the header value rotates freely even from loopback,
        // so the peer bucket is what bounds a rotating guesser.
        let throttle = ServerAuthRequest.throttleIdentities(for: req)
        let identity = throttle.identity

        // Read token from JSON body or Authorization header
        let bodyToken: String?
        do {
            bodyToken = try req.content.decode(AuthSessionRequestBody.self).token?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            RuneWeaverLog.server.debug("RuneWeaverServer: session login did not decode JSON body: \(error.localizedDescription)")
            bodyToken = nil
        }
        let headerToken = req.headers.bearerAuthorization?.token.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = (bodyToken?.isEmpty == false ? bodyToken : nil) ?? (headerToken?.isEmpty == false ? headerToken : nil) ?? ""

        // Owner-only verification: the request gate accepts sessions by design, but minting a
        // session requires the owner credential itself, matching the documented exchange.
        guard await auth.verifyOwnerToken(candidate) else {
            RuneWeaverLog.server.warning("Owner auth session login rejected from \(identity).")
            if let retryAfter = await auth.recordFailure(
                for: identity,
                isLoopback: throttle.isLoopback,
                peerIdentity: throttle.peerIdentity,
                peerIsLoopback: throttle.peerIsLoopback
            ) {
                return ServerAuthMiddleware.throttledResponse(retryAfter: retryAfter)
            }
            return ServerAuthMiddleware.unauthorizedResponse()
        }

        await auth.clearFailures(for: identity)
        await auth.clearFailures(for: throttle.peerIdentity)
        let sessionID = try await auth.createSession()
        let response = Response(
            status: .ok,
            headers: HTTPHeaders([
                ("Content-Type", "application/json; charset=utf-8"),
                ("Cache-Control", "no-store")
            ]),
            body: .init(string: #"{"status":"ok"}"#)
        )
        response.cookies[ServerAuthRequest.sessionCookieName] = ServerAuthRequest.makeSessionCookie(
            token: sessionID,
            isSecure: ServerAuthRequest.isRequestSecure(req)
        )
        return response
    }

    // DELETE /auth/session (logout)
    authGroup.delete(PathComponent.constant(ServerPaths.session)) { req async throws -> Response in
        if let cookieToken = req.cookies[ServerAuthRequest.sessionCookieName]?.string {
            await auth.revokeSession(cookieToken)
        }
        let response = Response(
            status: .ok,
            headers: HTTPHeaders([
                ("Content-Type", "application/json; charset=utf-8"),
                ("Cache-Control", "no-store")
            ]),
            body: .init(string: #"{"status":"ok"}"#)
        )
        response.cookies[ServerAuthRequest.sessionCookieName] = ServerAuthRequest.makeExpiredSessionCookie(
            isSecure: ServerAuthRequest.isRequestSecure(req)
        )
        return response
    }
}

/// Storage key for the verified system-pulse snapshot actor.
private struct SystemHealthSnapshotKey: StorageKey {
    /// Stored pulse actor type.
    typealias Value = SystemHealthSnapshot
}

/// Storage key for the shared last-served pulse change gate.
private struct HealthPulseLastServedKey: StorageKey {
    /// Stored change gate type.
    typealias Value = HealthPulseLastServed
}

/// Storage key for the recorded probe-report hash gate.
private struct SecurityProbeGateKey: StorageKey {
    /// Stored probe-report gate type.
    typealias Value = SecurityProbeGate
}

extension Application {
    /// Verified system-pulse snapshot actor for the health route. A missing entry degrades to an
    /// ephemeral actor over the current context instead of failing the probe.
    var systemHealthSnapshot: SystemHealthSnapshot {
        get {
            if let pulse = storage[SystemHealthSnapshotKey.self] {
                return pulse
            }
            return SystemHealthSnapshot(policyStore: runeWeaver.policyStore)
        }
        set {
            storage[SystemHealthSnapshotKey.self] = newValue
        }
    }

    /// Shared change gate so the health route and every probe path publish a pulse only when the
    /// value actually moved.
    var healthPulseLastServed: HealthPulseLastServed {
        get {
            if let gate = storage[HealthPulseLastServedKey.self] {
                return gate
            }
            return HealthPulseLastServed()
        }
        set {
            storage[HealthPulseLastServedKey.self] = newValue
        }
    }

    /// Recorded probe-report hash gate.
    var securityProbeGate: SecurityProbeGate {
        get {
            if let gate = storage[SecurityProbeGateKey.self] {
                return gate
            }
            return SecurityProbeGate()
        }
        set {
            storage[SecurityProbeGateKey.self] = newValue
        }
    }
}

/// Locked last-served pulse value suppressing identical rebroadcasts.
final class HealthPulseLastServed: Sendable {
    /// Last served snapshot, nil before the first probe.
    private let box: OSAllocatedUnfairLock<HealthSnapshotValue?>

    /// Creates an empty gate.
    init() {
        box = OSAllocatedUnfairLock(initialState: nil)
    }

    /// Atomically records `fresh` when it differs from the last served value.
    /// - Parameter fresh: Snapshot just built for this probe.
    /// - Returns: True when `fresh` differs and must be published plus served.
    func updateIfChanged(_ fresh: HealthSnapshotValue) -> Bool {
        box.withLock { current in
            guard current != fresh else { return false }
            current = fresh
            return true
        }
    }
}

/// Public pulse projection pushed over the socket hub on change. Carries the operational signal
/// only: tips stay on the authenticated REST path, so the push never discloses digests to a surface
/// the probe itself would redact.
private struct HealthPulseUpdatedFrame: Encodable {
    /// Always `"health_updated"`.
    let type = "health_updated"
    /// Closed pulse status.
    let status: String
    /// Last explicit ledger verification as Unix seconds, when stamped.
    let ledgerVerifiedAt: Double?
    /// Whether the live policy verifies.
    let policyVerified: Bool?
    /// Collapsed probe verdict, when any probe has reported.
    let probeVerdict: String?
    /// Bounded backing reasons for a non-green status.
    let degradedReasons: [String]?
    /// Mapped recovery action for a red pulse.
    let remediation: String?
}

/// Publishes a changed pulse value to live dashboards, best-effort.
func publishHealthPulse(_ value: HealthSnapshotValue, hub: WSHub) async {
    let frame = HealthPulseUpdatedFrame(
        status: value.status.rawValue,
        ledgerVerifiedAt: value.ledgerVerifiedAt?.timeIntervalSince1970,
        policyVerified: value.policyVerified,
        probeVerdict: value.probeVerdict?.rawValue,
        degradedReasons: value.degradedReasons.isEmpty ? nil : value.degradedReasons,
        remediation: PulseRemediation(value.remediation).rawValue
    )
    guard let data = try? JSONEncoder().encode(frame),
          let text = String(data: data, encoding: .utf8)
    else { return }
    await hub.broadcast(text: text)
}

// MARK: - Security Probe Wiring

/// Collaborators one security probe run records through. Held as explicit values rather than the
/// application so a retained background loop never captures the application itself.
struct SecurityProbeSink: Sendable {
    /// Tool name the inbox item carries for a fail-closed probe posture.
    static let inboxToolName = "security.probe"

    /// Pulse actor receiving the suite outcomes.
    let pulse: SystemHealthSnapshot
    /// Hub fanning a changed pulse out to live dashboards.
    let hub: WSHub
    /// Report-hash gate deciding whether the posture moved.
    let gate: SecurityProbeGate
    /// Change gate deciding whether to publish.
    let lastServed: HealthPulseLastServed
    /// Inbox a fail-closed posture parks an item in, nil when unwired.
    let approvals: ApprovalQueue?
    /// Trusted-tool anomaly watchdog evaluated on the same cadence.
    let watchdog: BehaviorWatchdog?
    /// Decision history recording automatic settlements, nil when unwired.
    let decisionLog: any ApprovalDecisionRecording?
}

/// Recorded probe-report hash gate suppressing identical re-records.
final class SecurityProbeGate: Sendable {
    /// Last recorded report hash, nil before the first run.
    private let box: OSAllocatedUnfairLock<String?>

    init() {
        box = OSAllocatedUnfairLock(initialState: nil)
    }

    /// Records the report hash when it differs from the last one.
    /// - Parameter report: Report about to be recorded.
    /// - Returns: True when the hash moved and the posture must be recorded.
    func shouldRecord(_ report: ProbeReport) -> Bool {
        box.withLock { current in
            guard current != report.hash else { return false }
            current = report.hash
            return true
        }
    }
}

/// Resolves the probe sink for an application, seeding application storage on first use so every
/// probe path records into one pulse.
func securityProbeSink(app: Application) -> SecurityProbeSink {
    let pulse: SystemHealthSnapshot
    if let stored = app.storage[SystemHealthSnapshotKey.self] {
        pulse = stored
    } else {
        pulse = SystemHealthSnapshot(policyStore: app.runeWeaver.policyStore)
        app.systemHealthSnapshot = pulse
    }
    let lastServed: HealthPulseLastServed
    if let stored = app.storage[HealthPulseLastServedKey.self] {
        lastServed = stored
    } else {
        lastServed = HealthPulseLastServed()
        app.healthPulseLastServed = lastServed
    }
    let gate: SecurityProbeGate
    if let stored = app.storage[SecurityProbeGateKey.self] {
        gate = stored
    } else {
        gate = SecurityProbeGate()
        app.securityProbeGate = gate
    }
    return SecurityProbeSink(
        pulse: pulse,
        hub: app.runeWeaver.hub,
        gate: gate,
        lastServed: lastServed,
        approvals: app.runeWeaver.approvals,
        watchdog: app.runeWeaver.watchdog,
        decisionLog: app.runeWeaver.approvalDecisions
    )
}

/// Runs the periodic security probe suite, records it into the pulse, and publishes a moved
/// verdict.
@discardableResult
func runSecurityProbes(sink: SecurityProbeSink, reason: String) async -> ProbeReport {
    let report = await SecurityProbeSuite.runAll()
    // The watchdog evaluates on the same periodic cadence — boot, policy
    // writes, nightly, and on-demand — never per tool call, so its brake
    // posture fuses into the pulse alongside the verifier suite.
    if let watchdog = sink.watchdog {
        _ = await watchdog.evaluate()
        await sink.pulse.recordWatchdogHealth(watchdog.health())
        if await watchdog.isArmed() {
            await sink.pulse.recordWatchdogGestation(nil)
        } else {
            await sink.pulse.recordWatchdogGestation(watchdog.gestationRemainingDays())
        }
    }
    guard sink.gate.shouldRecord(report) else {
        RuneWeaverLog.server.debug("Security probe suite (\(reason)): posture unchanged.")
        return report
    }
    await sink.pulse.recordProbes(report)
    let value = await sink.pulse.snapshot()
    if sink.lastServed.updateIfChanged(value) {
        await publishHealthPulse(value, hub: sink.hub)
    }
    let failed = report.probes.filter { !$0.passed }.map(\.name).sorted()
    let critical = report.probes
        .filter { !$0.passed && $0.failClosed }
        .map(\.name)
        .sorted()
    if let approvals = sink.approvals {
        if !critical.isEmpty {
            // The parked item carries no decision to make: the inbox is a surfacing channel, not
            // a second gate. Pending existence dedups beside the report-hash gate in one actor
            // hop, and the filing broadcast rides the queue's insert hop.
            await approvals.enqueueSystemNoticeIfAbsent(
                toolName: SecurityProbeSink.inboxToolName,
                description: "Security probes failed: \(critical.joined(separator: ", ")). "
                    + "The system pulse stays fail-closed until a passing re-check."
            )
        } else {
            // A suite with no fail-closed failures is the mapped remedy
            // resolving a parked probe notice: one settle broadcast per item.
            await settleSystemNotice(
                toolName: SecurityProbeSink.inboxToolName,
                note: "Security probes recovered after \(reason): no fail-closed verifiers failing.",
                approvals: approvals,
                hub: sink.hub,
                decisionLog: sink.decisionLog
            )
        }
    }
    if !critical.isEmpty {
        RuneWeaverLog.server.warning("Security probe suite (\(reason)): fail-closed verifiers failed (\(critical.joined(separator: ", "))).")
    } else if !failed.isEmpty {
        RuneWeaverLog.server.info("Security probe suite (\(reason)): \(failed.joined(separator: ", ")) failed.")
    } else {
        RuneWeaverLog.server.info("Security probe suite (\(reason)): all \(report.probes.count) verifiers passed.")
    }
    return report
}

/// Lifecycle hook running the security probe suite at serve boot.
final class SecurityProbeBootLifecycle: LifecycleHandler {
    func didBootAsync(_ app: Application) async throws {
        let report = await runSecurityProbes(sink: securityProbeSink(app: app), reason: "boot")
        // The sovereign ceremony runs at boot on the same cadence: a recorded
        // mismatch parks the pulse red without blocking the bind, so history
        // truth is corroborated from the first snapshot.
        _ = await runSovereignCeremony(sink: sovereignCeremonySink(app: app), reason: "boot")
        guard !report.failedCritical else {
            let critical = report.probes
                .filter { !$0.passed && $0.failClosed }
                .map(\.name)
                .sorted()
            throw SecurityProbeBootError(critical: critical)
        }
    }
}

/// Boot refusal naming the fail-closed verifiers that failed.
private struct SecurityProbeBootError: Error, CustomStringConvertible {
    /// Verifier names that failed fail-closed at boot.
    let critical: [String]

    var description: String {
        "Serve boot refused: critical security probes failed (\(critical.joined(separator: ", ")))."
    }
}

/// Lifecycle hook running the security probe suite on the nightly cadence.
final class SecurityProbeNightlyLifecycle: LifecycleHandler {
    /// Nightly cadence window between suite runs.
    static let intervalSeconds: TimeInterval = 24 * 60 * 60

    /// Retained loop task so shutdown cancels it instead of leaving a sleeping task alive past the
    /// server, mirroring the browser warmup flight. Guarded by a lock because boot and shutdown
    /// arrive on different executors.
    private let loopState: OSAllocatedUnfairLock<Task<Void, Never>?>

    init() {
        loopState = OSAllocatedUnfairLock(initialState: nil)
    }

    func didBootAsync(_ app: Application) async throws {
        // Resolve the sink once while isolated to the boot context so the
        // retained loop captures only Sendable collaborators.
        let sink = securityProbeSink(app: app)
        let sovereignSink = sovereignCeremonySink(app: app)
        loopState.withLock { current in
            current?.cancel()
            current = Task(priority: .background) {
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .seconds(Self.intervalSeconds))
                    } catch {
                        break
                    }
                    if Task.isCancelled {
                        break
                    }
                    _ = await runSecurityProbes(sink: sink, reason: "nightly")
                    _ = await runSovereignCeremony(sink: sovereignSink, reason: "nightly")
                }
            }
        }
    }

    func shutdownAsync(_: Application) async {
        loopState.withLock { current in
            current?.cancel()
            current = nil
        }
    }
}

/// Middleware running the security probe suite after a committed policy write.
final class SecurityProbePolicyWriteMiddleware: AsyncMiddleware, Sendable {
    /// Creates the middleware.
    init() {}

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let response = try await next.respond(to: request)
        guard Self.isPolicyWrite(request), (200 ..< 300).contains(Int(response.status.code)) else {
            return response
        }
        _ = await runSecurityProbes(sink: securityProbeSink(app: request.application), reason: "policy-write")
        return response
    }

    /// Whether a request is one of the committing policy write paths.
    /// - Parameter request: Inbound request that produced a response.
    /// - Returns: True for the PUT and the re-check apply writes.
    static func isPolicyWrite(_ request: Request) -> Bool {
        var path = request.url.path
        while path.hasSuffix("/") {
            path = String(path.dropLast())
        }
        switch (request.method, path) {
        case (.PUT, "/\(ServerPaths.settings)/\(ServerPaths.policy)"):
            return true
        case (.POST, "/\(ServerPaths.settings)/\(ServerPaths.policy)/\(ServerPaths.recheckLocalApply)"):
            return true
        default:
            return false
        }
    }
}

/// Registers the health probe route.
/// - Parameter app: Application receiving the route.
private func registerHealthRoute(_ app: Application) {
    // Boot the verified pulse once per registration against the serving policy store, then build
    // the boot snapshot eagerly: serve boot (via configureRuneWeaver) and direct route registration
    // converge here, and the first dashboard poll compares against a boot value instead of nil.
    let pulse = SystemHealthSnapshot(policyStore: app.runeWeaver.policyStore)
    app.systemHealthSnapshot = pulse
    let lastServed = HealthPulseLastServed()
    // Adopt the same gate into application storage so boot and periodic
    // probe runs share this route's change gate instead of holding a second
    // one, keeping one publish path per pulse value.
    app.healthPulseLastServed = lastServed
    // Structured warm inheriting boot priority so the boot snapshot builds
    // without ever delaying or failing registration; never awaited here.
    Task(priority: .utility) { _ = await pulse.snapshot() }
    app.get(PathComponent.constant(ServerPaths.health)) { req async throws -> Response in
        let modelInfo = await req.application.runeWeaver.orchestrator.modelInfo
        let searchURL = req.application.runeWeaver.browserConfig.searxngURL
        let searchReachable = await SearXNGEnsurer.isReachable(baseURL: searchURL)
        // Live Start stage rides along so the profile menu polls one endpoint
        // for both the dot and the Starting line; nil when idle.
        let searchProgress = await SearXNGEnsurer.shared.currentStartProgress(for: searchURL)
        let liveConfig = req.application.runeWeaver.config
        // Boot bind is owner-private: only callers clearing the owner gate receive bind details,
        // while unauthenticated probes see no hostname, port, or allowlist (the route does not
        // rely on middleware filtering alone).
        let disclosesBind = req.runeWeaverAuthenticated
        // Search reachability stays on the TopNav dot plus the Settings search panel via
        // searchReachable plus searchStatus plus searchStage; it is never recorded into the pulse,
        // so idle search never moves the dot.
        let pulse = req.application.systemHealthSnapshot
        // The watchdog evaluates on the serving cadence too: the trailing window reads live state,
        // so a spike engages the brake without a restart and the pulse fuses the latest posture on
        // every probe.
        let watchdog = req.application.runeWeaver.watchdog
        _ = await watchdog.evaluate()
        await pulse.recordWatchdogHealth(watchdog.health())
        if await watchdog.isArmed() {
            await pulse.recordWatchdogGestation(nil)
        } else {
            await pulse.recordWatchdogGestation(watchdog.gestationRemainingDays())
        }
        let pulseValue = await pulse.snapshot()
        // Publish only on deep change against the last served value so
        // steady-state polling never re-fans an identical pulse.
        if lastServed.updateIfChanged(pulseValue) {
            await publishHealthPulse(pulseValue, hub: req.application.runeWeaver.hub)
        }
        // Tips ride the authenticated projection only, mirroring the bind
        // keys: an unauthenticated probe learns the verdict plus the reasons
        // but never the digests.
        let health = HealthResponse(
            status: pulseValue.status.rawValue,
            engine: req.application.runeWeaver.memoryEngineDescription,
            model: modelInfo.name,
            provider: modelInfo.provider,
            contextLength: modelInfo.contextLength,
            searchReachable: searchReachable,
            searchURL: searchURL,
            searchStatus: searchReachable ? "running" : "stopped",
            searchStage: searchProgress?.stage.rawValue,
            searchStartedAt: searchProgress.map(\.startedAt.timeIntervalSince1970),
            serverHostname: disclosesBind ? liveConfig.hostname : nil,
            serverPort: disclosesBind ? liveConfig.port : nil,
            serverAllowedHosts: disclosesBind ? liveConfig.allowedHosts : nil,
            ledgerTip: disclosesBind ? pulseValue.ledgerTip : nil,
            ledgerVerifiedAt: pulseValue.ledgerVerifiedAt?.timeIntervalSince1970,
            policyHash: disclosesBind ? pulseValue.policyHash : nil,
            policyVerified: pulseValue.policyVerified,
            probeVerdict: pulseValue.probeVerdict?.rawValue,
            degradedReasons: pulseValue.degradedReasons.isEmpty ? nil : pulseValue.degradedReasons,
            infoNotes: pulseValue.infoNotes.isEmpty ? nil : pulseValue.infoNotes,
            remediation: PulseRemediation(pulseValue.remediation)
        )
        // Advertise the authoritative turn cap alongside the JSON body so the dashboard prefers the
        // server value over its fallback constant; a header keeps the JSON contract stable while
        // still collapsing admit/reject drift to one server-owned number.
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
    registerMemorySearchRoute(app)

    app.get(PathComponent.constant(ServerPaths.memory), PathComponent.constant(ServerPaths.memoryFacts)) { req async throws -> FactsPageResponse in
        // Query trimming plus limit plus offset parsing stay at the transport edge so the engine
        // keeps its typed contract: a blank `q` reads the recent window instead of failing, while
        // malformed paging rejects before any store read.
        let rawQuery = req.query[String.self, at: "q"] ?? ""
        let trimmedQuery = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = try parseQueryLimit(req, default: 20, min: 1, max: 100)
        let offset: Int
        if let rawString = req.query[String.self, at: "offset"] {
            let trimmed = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let raw = Int(trimmed), raw >= 0, raw <= 100_000 else {
                throw Abort(.badRequest, reason: "offset must be an integer between 0 and 100000")
            }
            offset = raw
        } else {
            offset = 0
        }
        let context = req.application.runeWeaver
        // Delegate to the engine-owned paged reader so REST never reaches past the owner into the
        // vector or episode stores directly.
        let result = await context.memoryEngine.searchFactsPage(query: trimmedQuery, limit: limit, offset: offset)
        let profile = await context.memoryEngine.getUserProfile()
        return FactsPageResponse(
            facts: result.page,
            total: result.total,
            semanticCount: result.semanticCount,
            episodeCount: result.episodeCount,
            limit: limit,
            offset: offset,
            preferences: profile.preferences
        )
    }

    app.post(PathComponent.constant(ServerPaths.memory), PathComponent.constant(ServerPaths.memoryFacts)) { req async throws -> UserFact in
        let body = try req.content.decode(StoreFactRequest.self)
        // The scheduler run cursor is framework-owned, so the REST boundary
        // refuses the reserved marker shape exactly like the memory tool.
        guard !SchedulerRunBookkeeping.isReservedFactText(body.content) else {
            throw Abort(.badRequest, reason: "content must not restate framework run bookkeeping")
        }
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

    registerEpisodicDeleteRoutes(app)
}

/// Registers the memory search route.
private func registerMemorySearchRoute(_ app: Application) {
    app.get(PathComponent.constant(ServerPaths.memory), PathComponent.constant(ServerPaths.memorySearch)) { req async throws -> MemorySearchResponse in
        guard let query = req.query[String.self, at: "q"],
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw Abort(.badRequest, reason: "q query parameter is required")
        }
        let limit = try parseQueryLimit(req, default: 10, min: 1, max: 50)
        let context = req.application.runeWeaver
        // Live recall budgets from the orchestrator so dashboard search honors
        // the same clamped `[memory] recall_*` values chat turns inject with
        // instead of default budgets.
        let budgets = await context.orchestrator.budgets
        // Same inference as chat auto-recall so both surfaces see the same windowed corpus.
        let plan = MemoryQueryRouter.plan(for: query, currentDate: Date(), budgets: budgets)
        // Chat fans out with the folded alias form, so the dashboard recalls
        // with the same expanded query to keep one corpus.
        let recallQuery = plan.expandedQuery.isEmpty ? query : plan.expandedQuery
        // Embed best-effort so vector hits rank by cosine similarity while
        // the response shape stays unchanged; cancellation propagates while
        // other failures fall back to the keyword path, mirroring chat recall.
        let embedding: [Float]?
        do {
            if let embedder = context.embedder {
                embedding = try await embedder.embedQuery(recallQuery)
            } else {
                embedding = nil
            }
        } catch let error as CancellationError {
            throw error
        } catch {
            embedding = nil
        }
        let recalled = try await context.memoryEngine.recall(
            query: recallQuery,
            embedding: embedding,
            limit: limit,
            since: plan.since,
            until: plan.until,
            budgets: budgets,
            skipDocIndex: plan.skipDocIndex
        )
        // Mirror the chat post-recall live override so forced-live queries
        // hide indexed chunks on both surfaces. The live check runs only when
        // the plan keeps the index visible.
        var hideIndexed = plan.skipDocIndex
        if !hideIndexed {
            hideIndexed = await LiveSearchOverride.shared.shouldUseLiveSearch(for: query)
        }
        let memories: [MemoryResult] = hideIndexed ? recalled.filter { $0.source != .docIndex } : recalled
        return MemorySearchResponse(query: query, memories: memories)
    }
}

/// Registers episodic recent listing plus bulk, session, and single-row delete routes.
private func registerEpisodicDeleteRoutes(_ app: Application) {
    app.get(
        PathComponent.constant(ServerPaths.memory),
        PathComponent.constant(ServerPaths.memoryEpisodes),
        PathComponent.constant(ServerPaths.memoryEpisodesRecent)
    ) { req async throws -> EpisodicRecentResponse in
        // Limit plus session filtering stay validated here so the engine keeps
        // its typed contract: malformed limits reject through the shared range
        // helper while a malformed session rejects before any store read.
        let limit = try parseQueryLimit(req, default: 20, min: 1, max: 100)
        let sessionID: UUID?
        if let raw = req.query[String.self, at: "sessionID"] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsed = UUID(uuidString: trimmed) else {
                throw Abort(.badRequest, reason: "sessionID must be a UUID")
            }
            sessionID = parsed
        } else {
            sessionID = nil
        }
        let episodes: [Episode]
        do {
            episodes = try await req.application.runeWeaver.memoryEngine.listRecentEpisodes(limit: limit, sessionID: sessionID)
        } catch {
            throw Abort(.internalServerError, reason: error.localizedDescription)
        }
        // Ordering is engine-owned: listRecentEpisodes already returns newest first, so map
        // directly with no re-sort.
        let rows = episodes.map { episode in
            EpisodicEpisodeDTO(
                id: episode.id,
                sessionID: episode.sessionID,
                role: episode.role.rawValue,
                content: episode.content,
                timestamp: episode.timestamp.timeIntervalSince1970
            )
        }
        return EpisodicRecentResponse(episodes: rows)
    }

    app.delete(
        PathComponent.constant(ServerPaths.memory),
        PathComponent.constant(ServerPaths.memoryEpisodes)
    ) { req async throws -> EpisodicClearResponse in
        // Clearing is episodic-only: both receipt counts derive from a single atomic transaction,
        // preventing interleaving fetches while semantic rows, profile, and index remain untouched.
        do {
            let result = try await req.application.runeWeaver.memoryEngine.clearEpisodicWithRemaining()
            // Owner-approved delete re-baselines inline so the pulse stays green.
            _ = await rebaselineAfterOwnerDelete(sink: sovereignCeremonySink(app: req.application))
            return EpisodicClearResponse(deletedCount: result.deleted, episodeCount: result.remaining)
        } catch {
            throw Abort(.internalServerError, reason: error.localizedDescription)
        }
    }

    // The `session` literal registers before the `:id` parameter so the exact
    // path wins without relying on route length alone, mirroring the goals
    // summary precedent; a session-shaped delete must never read as one id.
    app.delete(
        PathComponent.constant(ServerPaths.memory),
        PathComponent.constant(ServerPaths.memoryEpisodes),
        PathComponent.constant(ServerPaths.memoryEpisodeSession),
        PathComponent.parameter("sessionID")
    ) { req async throws -> HTTPStatus in
        guard let raw = req.parameters.get("sessionID"), let sessionID = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "sessionID must be a UUID")
        }
        do {
            try await req.application.runeWeaver.memoryEngine.deleteSession(sessionID)
        } catch {
            throw Abort(.internalServerError, reason: error.localizedDescription)
        }
        // Owner-approved delete re-baselines inline so the pulse stays green.
        _ = await rebaselineAfterOwnerDelete(sink: sovereignCeremonySink(app: req.application))
        return .noContent
    }

    app.delete(
        PathComponent.constant(ServerPaths.memory),
        PathComponent.constant(ServerPaths.memoryEpisodes),
        PathComponent.parameter("id")
    ) { req async throws -> HTTPStatus in
        guard let raw = req.parameters.get("id"), let id = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "id must be a UUID")
        }
        do {
            try await req.application.runeWeaver.memoryEngine.deleteEpisode(id: id)
        } catch {
            throw Abort(.internalServerError, reason: error.localizedDescription)
        }
        // Owner-approved delete re-baselines inline so the pulse stays green.
        _ = await rebaselineAfterOwnerDelete(sink: sovereignCeremonySink(app: req.application))
        // A missing row is a successful no-op: deletes stay idempotent so
        // retries and stale dashboard rows converge without a 404.
        return .noContent
    }
}

/// Registers the owner-authenticated sovereign re-baseline route.
private func registerSovereignRebaselineRoute(_ app: Application) {
    app.post(
        PathComponent.constant(ServerPaths.health),
        PathComponent.constant(ServerPaths.sovereign),
        PathComponent.constant(ServerPaths.rebaseline)
    ) { req async throws -> SovereignRebaselineResponse in
        // Denied stays denied when authenticated: without the owner credential
        // the route refuses instead of re-baselining to a smaller head.
        if req.application.runeWeaverAuth != nil, !req.runeWeaverAuthenticated {
            throw Abort(.unauthorized, reason: "Owner authentication required.")
        }
        let sink = sovereignCeremonySink(app: req.application)
        guard let verdict = await rebaselineAfterOwnerDelete(sink: sink) else {
            throw Abort(.internalServerError, reason: "Sovereign re-baseline failed; pulse parked red.")
        }
        return SovereignRebaselineResponse(verdict: verdict)
    }
}

/// Registers the managed browser Python lifecycle routes backing browser settings.
func registerBrowserRoutes(_ app: Application) {
    let browser = app.grouped(PathComponent.constant(ServerPaths.browser))

    browser.get(PathComponent.constant(ServerPaths.browserHealth)) { _ async -> BrowserPythonHealthResponse in
        // Side-effect free by design: the probe never provisions, so opening Settings or polling
        // mid-flight cannot start a second cascade.
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
        // Single-sourced through the shared ensurer so boot warmup, first navigate, and this route
        // collapse onto one in-flight provision instead of racing venv plus pip installs.
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

/// Registers the chat WebSocket with live approval prompts.
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
            // Bind the socket to the token generation it upgraded under so a later rotation revokes
            // it at the frame boundary as well as through the hub teardown, closing the window where
            // a buffered frame could still be answered after the swap.
            let generation = req.runeWeaverTokenGeneration
            let (stream, continuation) = AsyncStream<String>.makeStream()
            // The verified pulse rides in so a brake decision records its
            // watchdog health into the same actor the health route serves.
            let pulse = req.application.systemHealthSnapshot
            let connectionTask = Task { [box, context, connectionID, stream, connectionTasks, generation, auth, continuation, pulse] in
                // Register bound to the upgrade generation, then re-validate it immediately: the
                // middleware authenticates and `onUpgrade` registers on separate hops, so a rotation
                // can land in between.
                let registered = await context.hub.add(id: connectionID, box: box, generation: generation)
                // Evaluate the retirement check outside the boolean expression: its right operand
                // is a non-async autoclosure, so an `await` cannot appear there.
                let retired = await webSocketGenerationIsRetired(auth: auth, generation: generation)
                if !registered || retired {
                    connectionTasks.cancelAll()
                    await context.hub.remove(id: connectionID)
                    continuation.finish()
                    do {
                        _ = try await box.close(code: .policyViolation)
                    } catch {
                        RuneWeaverLog.server.debug("WebSocket unregister/retired close error: \(error.localizedDescription)")
                    }
                    return
                }
                for await text in stream {
                    if Task.isCancelled {
                        break
                    }
                    if await webSocketGenerationIsRetired(auth: auth, generation: generation) {
                        break
                    }
                    await handleWebSocketText(
                        text,
                        connectionID: connectionID,
                        context: context,
                        connectionTasks: connectionTasks,
                        pulse: pulse
                    )
                    if Task.isCancelled {
                        break
                    }
                }
                let retiredAtEnd = await webSocketGenerationIsRetired(auth: auth, generation: generation)
                // Every socket close seals the turn registry so orphaned turns cannot keep writing
                // past the socket lifetime and the reserve/insert race stays closed; only a retired
                // credential additionally closes the socket with a policy violation.
                connectionTasks.cancelAll()
                await context.hub.remove(id: connectionID)
                if retiredAtEnd {
                    do {
                        _ = try await box.close(code: .policyViolation)
                    } catch {
                        RuneWeaverLog.server.debug("WebSocket retiredAtEnd close error: \(error.localizedDescription)")
                    }
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
private func webSocketGenerationIsRetired(auth: ServerAuth?, generation: Int?) async -> Bool {
    guard let auth, let generation else { return false }
    return await !auth.isCurrentGeneration(generation)
}

/// Registers the static dashboard bundle routes.
public func registerDashboardRoutes(_ app: Application, bundle: DashboardBundle = .resolve()) {
    app.get { req async throws -> Response in
        try await bundle.response(for: req, requestPath: "")
    }
    app.get("**") { req async throws -> Response in
        let remainder = req.parameters.getCatchall().joined(separator: "/")
        let firstComponent = remainder
            .split(separator: "/", omittingEmptySubsequences: true)
            .first
            .map { String($0).lowercased() } ?? ""
        if firstComponent == ServerPaths.memory.lowercased() {
            // Vapor negotiates Abort payloads by Accept, so a browser Accept can
            // still render HTML here; answer explicit JSON so /memory/* never serves HTML.
            return Response(
                status: .notFound,
                headers: HTTPHeaders([("Content-Type", "application/json; charset=utf-8")]),
                body: .init(string: #"{"reason":"Not found"}"#)
            )
        }
        return try await bundle.response(for: req, requestPath: remainder)
    }
}

extension ServerContext {
    /// Engine name surfaced on `/health` without exposing config details.
    var memoryEngineDescription: String {
        "Rune Weaver"
    }
}

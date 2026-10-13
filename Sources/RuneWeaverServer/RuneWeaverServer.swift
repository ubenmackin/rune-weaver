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
///
/// The periodic security probe suite wires here too: it runs at serve boot
/// with a fail-closed refusal on a critical verifier failure, after every
/// committed policy write through the policy-write middleware, and on the
/// nightly cadence through its own lifecycle loop. The per-tool path stays
/// untouched, so tool latency never carries probe cost.
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
///
/// When a verifier is installed, the auth middleware wraps the whole router so
/// every non-public path is gated before it can 404 or leak existence. With no
/// verifier the surface stays the v1 loopback-no-auth shape exactly, including
/// the absence of the rotation route.
///
/// The Host gate reads the runtime bind policy (`hostname`, `allowedHosts`,
/// `authConfigured`) from the stored context so the policy that refused or
/// permitted the bind is the same one gating Host headers; the HTTP server
/// hostname was already set from that config in `configureRuneWeaver`.
///
/// Engine API routes always register before the dashboard bundle so a
/// `/memory/*` listing never falls through to the single-page client fallback
/// HTML: known listings answer JSON while unknown memory paths answer JSON
/// `404`, keeping error copy machine-readable for retry affordances.
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
///
/// Login exchanges the owner bearer token — read from the JSON body or the
/// `Authorization` header — for one fresh ephemeral session. A resent session
/// value is not an owner credential and fails closed here like any wrong
/// token, so sessions cannot mint their own replacements.
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

        // Owner-only verification: the request gate accepts sessions by design,
        // but minting a session requires the owner credential itself, matching
        // the documented exchange. Every attempt — including a resent or
        // retried login — re-presents and re-verifies it.
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
    /// Verified system-pulse snapshot actor for the health route.
    ///
    /// Installed once at route registration against the serving policy
    /// store, so serve boot and direct route registration share one pulse
    /// path. A missing entry degrades to an ephemeral actor over the
    /// current context instead of failing the probe.
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

    /// Shared change gate so the health route and every probe path publish a
    /// pulse only when the value actually moved.
    ///
    /// The health route installs one instance at registration and the probe
    /// sink adopts it, so a boot or nightly probe that produces an unchanged
    /// verdict never re-fans a steady-state pulse.
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
    ///
    /// The suite's "changed" signal is the report hash compare: a run whose
    /// posture matches the last recorded one re-asserts the same verdict, so
    /// the recorder stays quiet instead of rewriting identical outcomes.
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
///
/// Shared by the health route and every security probe path: each compares
/// its fresh snapshot against the last served one by deep value equality
/// and publishes only on change, so steady-state polling plus a repeated
/// nightly pass never re-fan an identical pulse to live dashboards.
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

/// Public pulse projection pushed over the socket hub on change.
///
/// Carries the operational signal only: tips stay on the authenticated REST
/// path, so the push never discloses digests to a surface the probe itself
/// would redact. Dashboards refetch the full shape on receipt.
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
}

/// Publishes a changed pulse value to live dashboards, best-effort.
///
/// Shared with the sovereign ceremony path so both publishers fan out through
/// one encoding instead of drifting into parallel frame shapes.
/// - Parameters:
///   - value: Snapshot that differed from the last served one.
///   - hub: Socket hub fanning out to dashboards.
func publishHealthPulse(_ value: HealthSnapshotValue, hub: WSHub) async {
    let frame = HealthPulseUpdatedFrame(
        status: value.status.rawValue,
        ledgerVerifiedAt: value.ledgerVerifiedAt?.timeIntervalSince1970,
        policyVerified: value.policyVerified,
        probeVerdict: value.probeVerdict?.rawValue,
        degradedReasons: value.degradedReasons.isEmpty ? nil : value.degradedReasons
    )
    guard let data = try? JSONEncoder().encode(frame),
          let text = String(data: data, encoding: .utf8)
    else { return }
    await hub.broadcast(text: text)
}

// MARK: - Security Probe Wiring

/// Collaborators one security probe run records through.
///
/// Held as explicit values rather than the application so a retained
/// background loop never captures the application itself.
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

/// Resolves the probe sink for an application, seeding application storage
/// on first use so every probe path records into one pulse.
///
/// Serve installs the pulse and the last-served gate at route registration;
/// a direct route registration that never did still converges here instead
/// of recording into an actor no route serves.
/// - Parameter app: Application owning the pulse plus the gates.
/// - Returns: The sink every probe path records through.
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
        watchdog: app.runeWeaver.watchdog
    )
}

/// Runs the periodic security probe suite, records it into the pulse, and
/// publishes a moved verdict.
///
/// The report-hash gate keeps an unchanged posture quiet — a nightly pass on
/// a healthy machine re-asserts the same verdict instead of re-broadcasting
/// a steady-state pulse — while a moved posture records and publishes, so
/// the dashboard clears red only on a fresh passing snapshot. A fail-closed
/// posture parks one bounded inbox item so the owner learns about it through
/// the approvals surface; the item is gated by the same hash compare, so a
/// persistent failure parks one item instead of one per run. Log lines carry
/// verifier names and counts only, never outcome detail, following the
/// content-free logging convention.
/// - Parameters:
///   - sink: Pulse, hub, inbox, and gates the run records through.
///   - reason: Trigger label for the log line.
/// - Returns: The report the run produced.
@discardableResult
func runSecurityProbes(sink: SecurityProbeSink, reason: String) async -> ProbeReport {
    let report = await SecurityProbeSuite.runAll()
    // The watchdog evaluates on the same periodic cadence — boot, policy
    // writes, nightly, and on-demand — never per tool call, so its brake
    // posture fuses into the pulse alongside the verifier suite.
    if let watchdog = sink.watchdog {
        _ = await watchdog.evaluate()
        await sink.pulse.recordWatchdogHealth(watchdog.health())
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
    if let approvals = sink.approvals, !critical.isEmpty {
        // The parked item carries no decision to make: deciding it stores no
        // grant, so the inbox is a surfacing channel for a fail-closed
        // posture, not a second gate the owner must re-run.
        await approvals.enqueue(
            toolName: SecurityProbeSink.inboxToolName,
            description: "Security probes failed: \(critical.joined(separator: ", ")). "
                + "The system pulse stays fail-closed until a passing re-check.",
            input: ToolInput(toolName: SecurityProbeSink.inboxToolName, argumentsJSON: "{}")
        )
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
///
/// Fail-closed: a critical verifier failure (traversal, symlink escape, or
/// replay) throws, so the boot aborts instead of serving an engine that
/// cannot prove containment. Non-critical failures record into the pulse
/// and surface on the dashboard without blocking the bind.
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
///
/// Rides its own loop rather than the scheduler worker tick so the cadence
/// owns one single-flight: a retained task cancelled on shutdown, sleeping
/// the nightly interval between runs. A passing run whose report hash
/// matches the boot posture stays quiet; only a moved posture records.
final class SecurityProbeNightlyLifecycle: LifecycleHandler {
    /// Nightly cadence window between suite runs.
    static let intervalSeconds: TimeInterval = 24 * 60 * 60

    /// Retained loop task so shutdown cancels it instead of leaving a
    /// sleeping task alive past the server, mirroring the browser warmup
    /// flight. Guarded by a lock because boot and shutdown arrive on
    /// different executors.
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
///
/// The two committing paths — `PUT /settings/policy` and the on-demand
/// `POST /settings/policy/recheck-local/apply` — land live with no restart,
/// so the suite re-runs once the write committed and records the fresh
/// posture. Preview and verify paths write nothing, a refused save leaves
/// the prior posture standing, and neither triggers a run.
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
    // Boot the verified pulse once per registration against the serving
    // policy store, then build the boot snapshot eagerly: serve boot (via
    // configureRuneWeaver) and direct route registration converge here, and
    // the first dashboard poll compares against a boot value instead of nil.
    // The snapshot reads the live store on every probe, so policy writes
    // surface with no restart plus no watcher.
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
        // The boot bind is owner-private: only callers that cleared the owner
        // gate learn it for the restart banner, while any other caller reaching
        // this handler (the middleware answers unauthenticated probes with the
        // minimal liveness shape, but the route must not rely on that alone)
        // sees no hostname, port, or allowlist. The loopback-no-auth posture
        // installs no verifier, so no request carries the authenticated marker
        // and the keys stay omitted there as well; the dashboard tolerates
        // absent keys by keeping its file snapshot, so omission degrades the
        // banner instead of breaking the probe.
        let disclosesBind = req.runeWeaverAuthenticated
        // Record this probe's subsystem outcome before snapshotting so the
        // served verdict always reflects the probe just run: a down search
        // degrades (it never failed closed), and a recovered one clears on
        // the next passing cycle when its entry is overwritten. Read through
        // application storage so a replaced test actor takes effect.
        let pulse = req.application.systemHealthSnapshot
        await pulse.recordProbes([HealthProbeOutcome(
            name: "search",
            passed: searchReachable,
            detail: searchReachable ? nil : "Search service is unreachable."
        )])
        // The watchdog evaluates on the serving cadence too: the trailing
        // window reads live state, so a spike engages the brake without a
        // restart and the pulse fuses the latest posture on every probe.
        let watchdog = req.application.runeWeaver.watchdog
        _ = await watchdog.evaluate()
        await pulse.recordWatchdogHealth(watchdog.health())
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
            degradedReasons: pulseValue.degradedReasons.isEmpty ? nil : pulseValue.degradedReasons
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
    registerMemorySearchRoute(app)

    app.get(PathComponent.constant(ServerPaths.memory), PathComponent.constant(ServerPaths.memoryFacts)) { req async throws -> FactsPageResponse in
        // Query trimming plus limit plus offset parsing stay at the transport
        // edge so the engine keeps its typed contract: a blank `q` reads the
        // recent window instead of failing, while malformed paging rejects
        // before any store read. The engine owns normalization plus clamping
        // as the backstop, so this block only validates wire shape.
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
        // Delegate to the engine-owned paged reader so REST never reaches
        // past the owner into the vector or episode stores directly. Reads
        // open storage on demand with no cached snapshot, so a just-stored
        // fact is visible on the next fetch with no restart.
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
///
/// Split from `registerMemoryRoutes` so the parent stays within the function
/// body budget; search registers first so the remaining memory routes keep
/// the parent's original registration order.
/// - Parameter app: Application receiving the routes.
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
///
/// Split from `registerMemoryRoutes` so the parent stays within the function
/// body budget; route order preserves the `session` and `recent` literals
/// winning over `:id`.
/// - Parameter app: Application receiving the routes.
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
        // Ordering is engine-owned: listRecentEpisodes already returns newest
        // first, so map directly with no re-sort. Reads open SQLite on demand
        // with no cached snapshot, so a just-stored turn is visible immediately
        // with no restart and no watcher.
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
        // Clearing is episodic-only by engine ownership: both receipt numbers
        // come from the single atomic engine clear (measured in the same
        // transaction, remaining as its immediate post-condition), so no second
        // fetch can interleave a mirrored turn between them, while semantic rows,
        // profile, index, sessions, runs, goals, ideas, and grants stay out of
        // the write path entirely.
        do {
            let result = try await req.application.runeWeaver.memoryEngine.clearEpisodicWithRemaining()
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
        // A missing row is a successful no-op: deletes stay idempotent so
        // retries and stale dashboard rows converge without a 404.
        return .noContent
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
            // The verified pulse rides in so a brake decision records its
            // watchdog health into the same actor the health route serves.
            let pulse = req.application.systemHealthSnapshot
            let connectionTask = Task { [box, context, connectionID, stream, connectionTasks, generation, auth, continuation, pulse] in
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
                // Every socket close seals the turn registry so orphaned turns
                // cannot keep writing past the socket lifetime and the
                // reserve/insert race stays closed; only a retired credential
                // additionally closes the socket with a policy violation.
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
///
/// Engine API routes register before this bundle so listings answer JSON; any
/// `/memory/*` path reaching here is unknown and answers JSON `404` instead of
/// the single-page HTML fallback, keeping Abort errors machine-readable.
/// - Parameters:
///   - app: Application receiving the routes.
///   - bundle: Resolved bundle to serve, or a fresh resolution when omitted.
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

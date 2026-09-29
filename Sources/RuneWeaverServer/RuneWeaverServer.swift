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

/// Conformance letting the core fan-out engine record its audit rows through
/// the shared run-log store. The seam stays core-side so the server entry
/// types never leak into RuneWeaverCore; this adapter is the only bridge, and
/// it appends through the same store instance every chat and scheduler row
/// uses so the fan-out swarm renders beside the rest of the audit trail.
extension RunLogStore: FanOutRunLogging {
    public func appendFanOutRow(kind: String, status: String, message: String, sessionID: UUID) async -> UUID {
        await append(kind: kind, status: status, message: message, sessionID: sessionID).id
    }

    public func updateFanOutRow(id: UUID, status: String) async {
        _ = await update(id: id, status: status)
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
    app.routes.defaultMaxBodySize = "2mb"
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
///
/// The Host gate reads the runtime bind policy (`hostname`, `allowedHosts`,
/// `authConfigured`) from the stored context so the policy that refused or
/// permitted the bind is the same one gating Host headers; the HTTP server
/// hostname was already set from that config in `configureRuneWeaver`.
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
    registerRunRoutes(app)
    registerGoalRoutes(app)
    registerIdeaRoutes(app)
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
        let identity = ServerAuthRequest.clientIdentity(for: req)
        let isLoopback = ServerAuthRequest.isLoopback(identity)

        // Read token from JSON body or Authorization header
        let bodyToken = (try? req.content.decode(AuthSessionRequestBody.self))?.token?.trimmingCharacters(in: .whitespacesAndNewlines)
        let headerToken = req.headers.bearerAuthorization?.token.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = (bodyToken?.isEmpty == false ? bodyToken : nil) ?? (headerToken?.isEmpty == false ? headerToken : nil) ?? ""

        // Owner-only verification: the request gate accepts sessions by design,
        // but minting a session requires the owner credential itself, matching
        // the documented exchange. Every attempt — including a resent or
        // retried login — re-presents and re-verifies it.
        guard await auth.verifyOwnerToken(candidate) else {
            RuneWeaverLog.server.warning("Owner auth session login rejected from \(identity).")
            if let retryAfter = await auth.recordFailure(for: identity, isLoopback: isLoopback) {
                return ServerAuthMiddleware.throttledResponse(retryAfter: retryAfter)
            }
            return ServerAuthMiddleware.unauthorizedResponse()
        }

        await auth.clearFailures(for: identity)
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
        let health = HealthResponse(
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
            serverAllowedHosts: disclosesBind ? liveConfig.allowedHosts : nil
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

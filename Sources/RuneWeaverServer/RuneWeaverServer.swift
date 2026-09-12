// Rune Weaver Server — Loopback HTTP and WebSocket API service application.
//
// Configures and boots the Vapor service exposing chat endpoints, tool bus
// execution, memory search/facts, headless approval queues, scheduler job
// CRUD, and static dashboard assets over localhost. Enforces loopback-only
// binding and single-user trust.

import Foundation
import RuneWeaverCore
import Vapor

/// Localhost-only HTTP and WebSocket API service for Rune Weaver.
///
/// Fronts the core engine with Vapor, serving chat turns, tools, memory,
/// approvals, run logs, and the static dashboard bundle on loopback.
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

/// Sendable-safe box for a non-Sendable Vapor `WebSocket`.
///
/// `WebSocket` is not `Sendable`, so it cannot be stored directly in the
/// `Sendable` actor `WSHub` under Swift 6. The box is `@unchecked Sendable`
/// with an audited contract: it is immutable after init, only `WSHub`
/// touches `socket`, and every send (chat deltas, errors, approval
/// broadcasts) funnels through the per-connection `WSSendQueue` plus
/// `wsSendWithTimeout` so sends to the same connection serialize and
/// preserve per-connection frame order. The socket still crosses threads
/// transitively (race tasks capture the box); safety rests on single-owner
/// hub routing plus serialized per-connection sends, not on thread
/// confinement. Never call `box.socket.send` outside `WSHub`.
public final class WSSocketBox: @unchecked Sendable {
    /// Wrapped socket.
    public let socket: WebSocket

    /// Wraps a socket.
    /// - Parameter socket: Connected socket.
    public init(_ socket: WebSocket) {
        self.socket = socket
    }
}

/// One-shot gate ensuring a WebSocket send continuation resumes exactly once.
///
/// The timeout race resumes from two unstructured tasks (the socket send
/// and the sleep); whichever finishes first wins and the loser is cancelled.
/// Audit note: the gate holds a non-`Sendable` `CheckedContinuation`, so the
/// continuation crosses threads transitively wherever the gate does. Safety
/// rests on the lock-guarded single-resume contract below, not on staying on
/// one thread: `NSLock` serializes `didResume` plus `continuation`, `resume`
/// is idempotent, and the continuation is resumed at most once then released.
/// Racing tasks capture the `Sendable` gate and resume through it; they never
/// resume a captured continuation directly.
private final class WSResumeOnce: @unchecked Sendable {
    /// Guards `didResume` and `continuation`.
    private let lock = NSLock()
    /// Continuation to resume once (nil after resume).
    private var continuation: CheckedContinuation<Void, Never>?
    /// Whether the continuation already resumed.
    private var didResume = false

    /// Creates a gate holding a continuation.
    /// - Parameter continuation: Continuation to resume once.
    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    /// Resumes the held continuation unless already resumed.
    func resume() {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return }
        didResume = true
        continuation?.resume()
        continuation = nil
    }
}

/// Serializes outbound frames for one WebSocket connection.
///
/// One queue per connection: the hub fans out concurrently across
/// connections (no head-of-line blocking) while successive sends to the
/// same connection serialize through its queue, preserving per-connection
/// frame order even when broadcasts and chat deltas interleave.
private actor WSSendQueue {
    /// Sends one frame through the queue, best-effort with timeout.
    /// - Parameters:
    ///   - text: Text frame to send.
    ///   - box: Boxed socket to send on.
    func send(_ text: String, to box: WSSocketBox) async {
        await wsSendWithTimeout(text, to: box)
    }
}

/// Live WebSocket connections for approval broadcasts.
///
/// One hub per engine process. Chat sockets register on connect and
/// unregister on close; the approval path broadcasts every new
/// ``PermissionRequest`` so connected clients can answer inline with a
/// decision frame without polling REST. The hub is the sole sender on
/// every socket: chat and error frames go through `send(id:text:)`
/// so streamed deltas never race broadcast prompts on the
/// same connection.
public actor WSHub {
    /// Connected sockets indexed by connection identifier.
    private var sockets: [UUID: WSSocketBox] = [:]
    /// Per-connection send queues preserving frame order per socket.
    private var queues: [UUID: WSSendQueue] = [:]

    /// Creates an empty hub.
    public init() {}

    /// Registers an already-boxed socket without crossing the actor
    /// boundary with a non-`Sendable` value.
    /// - Parameters:
    ///   - id: Connection identifier.
    ///   - box: Boxed socket (Sendable).
    public func add(id: UUID, box: WSSocketBox) {
        sockets[id] = box
        if queues[id] == nil {
            queues[id] = WSSendQueue()
        }
    }

    /// Unregisters a socket. Unknown identifiers are a no-op.
    /// - Parameter id: Connection identifier.
    public func remove(id: UUID) {
        sockets.removeValue(forKey: id)
        queues.removeValue(forKey: id)
    }

    /// Number of connected sockets.
    /// - Returns: Connection count.
    public func count() -> Int {
        sockets.count
    }

    /// Queue for a connection, creating it when missing.
    /// - Parameter id: Connection identifier.
    /// - Returns: Serial sender for the connection.
    private func queue(for id: UUID) -> WSSendQueue {
        if let existing = queues[id] {
            return existing
        }
        let created = WSSendQueue()
        queues[id] = created
        return created
    }

    /// Broadcasts one approval prompt to every connected socket.
    ///
    /// Best-effort concurrent fan-out across connections with a per-send
    /// timeout so one slow or closed socket never head-of-line blocks
    /// approvals. Sends to the same connection serialize through its
    /// per-connection queue so successive broadcasts keep frame order.
    /// Encoding failures and timed-out or closed sockets are skipped.
    /// - Parameter request: Pending request to announce.
    public func broadcastApproval(_ request: PermissionRequest) async {
        guard let data = try? JSONEncoder().encode(WSApprovalPrompt(request: request)),
              let text = String(data: data, encoding: .utf8)
        else { return }
        let targets: [(WSSendQueue, WSSocketBox)] = sockets.map { (queue(for: $0.key), $0.value) }
        await withTaskGroup(of: Void.self) { group in
            for (queue, box) in targets {
                group.addTask {
                    await queue.send(text, to: box)
                }
            }
        }
    }

    /// Sends one text frame to the connection with the given identifier.
    ///
    /// No-op when the connection already closed. Routes through the
    /// per-connection queue so per-connection frame order is preserved.
    /// This is the sole single-send path; all chat deltas, done frames,
    /// and error frames funnel through it.
    /// - Parameters:
    ///   - id: Connection identifier.
    ///   - text: Text frame to send.
    public func send(id: UUID, text: String) async {
        guard let box = sockets[id] else { return }
        await queue(for: id).send(text, to: box)
    }
}

/// Holds one side of the timeout race.
///
/// The timeout task is created before the send task so the send winner can
/// always cancel the sleeper; the timeout loser looks the send task up at
/// fire time (long after the synchronous assignment), so neither direction
/// has a forward-reference race. One holder tracks each side so outer
/// task cancellation can cancel both. Audit note: the holder stores a
/// non-`Sendable` `Task` handle behind `@unchecked Sendable`; all access to
/// `task` is serialized by `NSLock`, `cancel` copies the handle under lock
/// and cancels outside it, and tasks are cancelled at most (best-effort
/// hang mitigation) rather than awaited, so no data race on the handle.
private final class WSSendTaskHolder: @unchecked Sendable {
    /// Guards `task`.
    private let lock = NSLock()
    /// Held race task, if assigned.
    private var task: Task<Void, Never>?

    /// Creates an empty holder.
    init() {}

    /// Assigns the race task.
    /// - Parameter task: In-flight race task.
    func set(_ task: Task<Void, Never>) {
        lock.lock()
        defer { lock.unlock() }
        self.task = task
    }

    /// Cancels the held task, if assigned.
    func cancel() {
        lock.lock()
        let current = task
        lock.unlock()
        current?.cancel()
    }
}

/// Holds the one-shot resume gate for the timeout race.
///
/// The gate is created inside the `withCheckedContinuation` closure, so
/// the outer `withTaskCancellationHandler` cancellation path cannot
/// capture it directly. The box publishes it once assigned so
/// cancellation resumes the suspended send immediately instead of
/// waiting out the timeout. Audit note: the box holds a `WSResumeOnce`
/// (which transitively holds the continuation) behind `@unchecked
/// Sendable`; all access to `gate` is serialized by `NSLock`, `resume`
/// copies the gate under lock and resumes outside it, and the gate's own
/// single-resume lock makes a concurrent publish-plus-cancel race safe
/// (at most one resume wins).
private final class WSResumeOnceBox: @unchecked Sendable {
    /// Guards `gate`.
    private let lock = NSLock()
    /// Published gate, if assigned.
    private var gate: WSResumeOnce?

    /// Creates an empty box.
    init() {}

    /// Publishes the gate.
    /// - Parameter gate: Gate guarding the send continuation.
    func set(_ gate: WSResumeOnce) {
        lock.lock()
        defer { lock.unlock() }
        self.gate = gate
    }

    /// Resumes the published gate, if assigned.
    func resume() {
        lock.lock()
        let current = gate
        lock.unlock()
        current?.resume()
    }
}

/// Sends one WebSocket text frame with a per-send timeout, best-effort.
///
/// Races an unstructured `send` task against a sleep without awaiting a
/// hung send: whichever finishes first resumes and the loser is cancelled
/// (the hung send is cancelled best-effort and left to finish in the
/// background; the sleeper is cancelled when the send wins so no stray
/// sleeping task lingers up to the timeout per send under broadcast
/// fan-out) so a slow socket resolves within the timeout instead of
/// blocking the broadcast fan-out past it. Cancelling the connection
/// task resumes immediately through the cancellation fast-path instead
/// of waiting out the timeout: the handler cancels both race tasks and
/// resumes the gate so `WSHub.remove` runs promptly on socket close or
/// shutdown. Hub-only: call
/// `WSHub.send(id:text:)` or `WSHub.broadcastApproval`
/// instead of calling this directly so one logical owner keeps
/// per-connection frame order through the per-connection queues.
/// - Parameters:
///   - text: Text frame to send.
///   - box: Boxed socket to send on (Sendable).
///   - timeoutNanoseconds: Per-send timeout. Defaults to 5 seconds.
private func wsSendWithTimeout(_ text: String, to box: WSSocketBox, timeoutNanoseconds: UInt64 = 5_000_000_000) async {
    let onceBox = WSResumeOnceBox()
    let sendHolder = WSSendTaskHolder()
    let timeoutHolder = WSSendTaskHolder()
    await withTaskCancellationHandler {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = WSResumeOnce(continuation)
            onceBox.set(once)
            let timeoutTask = Task { [once, sendHolder] in
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                } catch {
                    return
                }
                sendHolder.cancel()
                once.resume()
            }
            timeoutHolder.set(timeoutTask)
            let sendTask = Task { [once, box, text, timeoutHolder] in
                try? await box.socket.send(text)
                timeoutHolder.cancel()
                once.resume()
            }
            sendHolder.set(sendTask)
            if Task.isCancelled {
                timeoutHolder.cancel()
                sendHolder.cancel()
                once.resume()
            }
        }
    } onCancel: {
        timeoutHolder.cancel()
        sendHolder.cancel()
        onceBox.resume()
    }
}

/// Shared collaborators for every engine API route.
///
/// One context per engine process. REST handlers read it from
/// `Application` storage and WebSocket handlers capture it once per
/// connection so streamed chat and live approvals share the same
/// orchestrator, memory, approvals, scheduler, and run logs as REST with
/// no per-client forks.
///
/// Checked `Sendable` (no `unchecked`): every stored collaborator is an
/// actor (`ConversationManager`, `ToolBus`, `Orchestrator`,
/// `MemoryEngine`, `PermissionGate`, `ApprovalQueue`, `SchedulerStore`,
/// `RunLogStore`, `WSHub`, `SchedulerRunLock`) plus the `Sendable`
/// `ServerConfig` value, all held in immutable `let`s, so no field forces
/// unchecked sharing.
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
    /// Single-flight lock for manual job runs within this service process.
    /// Guards concurrent `POST .../run` calls only; it does not coordinate
    /// with the CLI foreground runner, which owns cron/poll auto-fire.
    public let runLock: SchedulerRunLock

    /// Creates a server context.
    /// - Parameters:
    ///   - config: Loopback binding. Defaults to `.default`.
    ///   - conversations: Session owner.
    ///   - toolBus: Tool registry.
    ///   - orchestrator: Orchestration loop.
    ///   - memoryEngine: Memory tiers.
    ///   - permissionGate: Trust gate.
    ///   - approvals: Pending approvals.
    ///   - scheduler: Job registry. Defaults to empty.
    ///   - runs: Run audit trail. Defaults to empty.
    ///   - hub: Live sockets. Defaults to empty.
    ///   - runLock: Single-flight lock for manual runs. Defaults to empty.
    public init(
        config: ServerConfig = .default,
        conversations: ConversationManager,
        toolBus: ToolBus,
        orchestrator: Orchestrator,
        memoryEngine: MemoryEngine,
        permissionGate: PermissionGate,
        approvals: ApprovalQueue,
        scheduler: SchedulerStore = SchedulerStore(),
        runs: RunLogStore = RunLogStore(),
        hub: WSHub = WSHub(),
        runLock: SchedulerRunLock = SchedulerRunLock()
    ) {
        self.config = config
        self.conversations = conversations
        self.toolBus = toolBus
        self.orchestrator = orchestrator
        self.memoryEngine = memoryEngine
        self.permissionGate = permissionGate
        self.approvals = approvals
        self.scheduler = scheduler
        self.runs = runs
        self.hub = hub
        self.runLock = runLock
    }

    /// Builds a context wired for live approval prompts over WebSocket.
    ///
    /// The bus approval handler files every gated call through the shared
    /// `ApprovalQueue/fileRequest(tool:call:)` path, broadcasts it on `hub`,
    /// then suspends on the decision with a timeout so a forgotten approval
    /// denies instead of hanging the HTTP/WebSocket worker forever. Callers
    /// must register tools on the returned bus before serving.
    /// - Parameters:
    ///   - config: Loopback binding. Defaults to `.default`.
    ///   - conversations: Session owner.
    ///   - memoryEngine: Memory tiers.
    ///   - permissionGate: Trust gate.
    ///   - llm: LLM backend serving completions.
    ///   - systemPrompt: Developer instructions. Defaults to nil.
    ///   - schedulerConfig: Durable `config.toml [[scheduler.jobs]]` used
    ///     to seed the runtime scheduler registry. Defaults to empty.
    /// - Returns: Context with an approval-broadcasting bus.
    public static func make(
        config: ServerConfig = .default,
        conversations: ConversationManager,
        memoryEngine: MemoryEngine,
        permissionGate: PermissionGate,
        llm: any LLMProvider,
        systemPrompt: String? = nil,
        schedulerConfig: SchedulerConfig = .empty
    ) async -> ServerContext {
        let approvals = ApprovalQueue(permissionGate: permissionGate)
        let scheduler = SchedulerStore(from: schedulerConfig)
        let runs = RunLogStore()
        let hub = WSHub()
        let runLock = SchedulerRunLock()
        let bus = ToolBus(permissionGate: permissionGate)
        let orchestrator = Orchestrator(
            conversations: conversations,
            toolBus: bus,
            llm: llm,
            systemPrompt: systemPrompt,
            memoryEngine: memoryEngine
        )
        let context = ServerContext(
            config: config,
            conversations: conversations,
            toolBus: bus,
            orchestrator: orchestrator,
            memoryEngine: memoryEngine,
            permissionGate: permissionGate,
            approvals: approvals,
            scheduler: scheduler,
            runs: runs,
            hub: hub,
            runLock: runLock
        )
        let handlerApprovals = context.approvals
        let handlerHub = context.hub
        await bus.setApprovalHandler { tool, call in
            // Decorates the shared filing path: file through
            // `fileRequest(tool:call:)` (same as the headless handler),
            // then broadcast and wait with a timeout.
            let request = await handlerApprovals.fileRequest(tool: tool, call: call)
            await handlerHub.broadcastApproval(request)
            let decision = await handlerApprovals.waitForDecision(
                id: request.id,
                timeoutSeconds: ApprovalQueue.defaultDecisionTimeoutSeconds
            )
            return decision.approved
        }
        return context
    }
}

/// Storage key for the shared ``ServerContext``.
private struct ServerContextKey: StorageKey {
    /// Stored context type.
    typealias Value = ServerContext
}

extension Application {
    /// Shared engine context for every route.
    var runeWeaver: ServerContext {
        get {
            guard let context = storage[ServerContextKey.self] else {
                fatalError("ServerContext not configured. Call configureRuneWeaver(_:context:) before serving.")
            }
            return context
        }
        set {
            storage[ServerContextKey.self] = newValue
        }
    }
}

/// Configures loopback binding plus every engine route.
///
/// Binds `127.0.0.1:8082` by default with no auth (single-user,
/// local-machine trust; remote access rides the WireGuard VPN, never a
/// public port). Refuses to bind a non-loopback interface until
/// authentication lands (auth-before-exposure). Registers REST (`/health`, `/chat`, `/tools`,
/// `/memory`, `/approvals`, `/scheduler/jobs`, `/runs`) plus the
/// WebSocket (`/ws`) for streamed chat and live approval prompts, plus
/// the static dashboard bundle (`/` and assets) on the same origin with
/// no CORS.
/// - Parameters:
///   - app: Vapor application to configure.
///   - context: Shared engine collaborators.
/// - Throws: Never; kept throwing for Vapor `configure` conventions.
public func configureRuneWeaver(_ app: Application, context: ServerContext) throws {
    context.config.requireLoopback()
    app.http.server.configuration.hostname = context.config.hostname
    app.http.server.configuration.port = context.config.port
    app.runeWeaver = context
    registerRuneWeaverRoutes(app)
}

/// Registers every engine route on the application.
///
/// Single surface shared by all clients with no per-client forks:
/// health, chat, tools, memory search and facts, approvals list and
/// decide, scheduler job CRUD plus manual run, run logs, the chat
/// WebSocket, and the static dashboard bundle on the same origin.
/// - Parameter app: Application receiving the routes.
public func registerRuneWeaverRoutes(_ app: Application) {
    registerHealthRoute(app)
    registerChatRoute(app)
    registerToolRoutes(app)
    registerMemoryRoutes(app)
    registerApprovalRoutes(app)
    registerSchedulerCRUDRoutes(app)
    registerSchedulerRunRoute(app)
    registerRunRoutes(app)
    registerWebSocketRoute(app)
    registerDashboardRoutes(app)
}

/// Bounds an integer limit to the closed range `minLimit...maxLimit`.
///
/// Single shared clamp for every query-`limit` parsing path so bound logic
/// cannot drift between overloads.
/// - Parameters:
///   - raw: Candidate value.
///   - minLimit: Minimum allowed value.
///   - maxLimit: Maximum allowed value.
/// - Returns: Value bounded to `minLimit...maxLimit`.
private func clampLimit(_ raw: Int, min minLimit: Int, max maxLimit: Int) -> Int {
    min(max(raw, minLimit), maxLimit)
}

/// Parses the raw `limit` query string strictly.
///
/// Inspects the raw query string so `?limit=abc` (which Vapor decodes as
/// nil `Int`) surfaces as `400` instead of silently falling back to the
/// default, and out-of-range values `400` instead of silently clamping to
/// the nearest bound.
/// - Parameters:
///   - req: Inbound request.
///   - minLimit: Minimum allowed value.
///   - maxLimit: Maximum allowed value.
/// - Returns: Bounded limit, or nil when the parameter is omitted.
/// - Throws: `Abort(.badRequest)` on non-integer or out-of-range input.
private func parsedRawQueryLimit(_ req: Request, min minLimit: Int, max maxLimit: Int) throws -> Int? {
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
/// - Parameters:
///   - req: Inbound request.
///   - defaultLimit: Default limit when query parameter is omitted.
///   - minLimit: Minimum allowed value. Defaults to 1.
///   - maxLimit: Maximum allowed value.
/// - Returns: Validated integer limit.
/// - Throws: `Abort(.badRequest)` on non-integer or out-of-range input.
private func parseQueryLimit(
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
/// - Parameters:
///   - req: Inbound request.
///   - minLimit: Minimum allowed value. Defaults to 1.
///   - maxLimit: Maximum allowed value.
/// - Returns: Validated integer limit, or nil if omitted.
/// - Throws: `Abort(.badRequest)` on non-integer or out-of-range input.
private func parseQueryLimit(
    _ req: Request,
    min minLimit: Int = 1,
    max maxLimit: Int
) throws -> Int? {
    try parsedRawQueryLimit(req, min: minLimit, max: maxLimit)
}

/// Registers the health probe route.
/// - Parameter app: Application receiving the route.
private func registerHealthRoute(_ app: Application) {
    app.get(PathComponent.constant(ServerPaths.health)) { req async throws -> HealthResponse in
        HealthResponse(engine: req.application.runeWeaver.memoryEngineDescription)
    }
}

/// Validates chat text once for REST and WebSocket.
///
/// Trims surrounding whitespace, rejects empty text, and enforces
/// `ChatRequest/maxTextLength` so both entry points share one rule.
/// - Parameter raw: Raw user text.
/// - Returns: Trimmed text safe to process.
/// - Throws: `Abort` with `.badRequest` for empty text or
///   `.payloadTooLarge` when over the limit.
private func validatedChatText(_ raw: String) throws -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        throw Abort(.badRequest, reason: "text must not be empty")
    }
    guard trimmed.count <= ChatRequest.maxTextLength else {
        throw Abort(.payloadTooLarge, reason: "text exceeds \(ChatRequest.maxTextLength) characters")
    }
    return trimmed
}

/// Registers the chat completion route.
/// - Parameter app: Application receiving the route.
private func registerChatRoute(_ app: Application) {
    app.post(PathComponent.constant(ServerPaths.chat)) { req async throws -> OrchestratorResponse in
        let body = try req.content.decode(ChatRequest.self)
        let text = try validatedChatText(body.text)
        let context = req.application.runeWeaver
        let sessionID = body.resolvedSessionID
        do {
            let response = try await context.orchestrator.process(input: UserInput(
                text: text,
                sessionID: sessionID,
                source: body.resolvedSource
            ))
            await context.runs.append(kind: "chat", status: "ok", message: text)
            return response
        } catch let error as OrchestratorError {
            await context.runs.append(kind: "chat", status: "error", message: text)
            switch error {
            case .emptyInput:
                throw Abort(.badRequest, reason: "text must not be empty")
            case let .toolLoopExceeded(iterations):
                throw Abort(.unprocessableEntity, reason: "Tool loop exceeded \(iterations) rounds")
            case let .llmFailed(detail):
                throw Abort(.badGateway, reason: detail)
            }
        }
    }
}

/// Registers tool listing plus direct tool-call routes.
/// - Parameter app: Application receiving the routes.
private func registerToolRoutes(_ app: Application) {
    app.get(PathComponent.constant(ServerPaths.tools)) { req async throws -> ToolsResponse in
        let tools = await req.application.runeWeaver.toolBus.availableTools()
        return ToolsResponse(tools: tools.map(ToolInfo.init).sorted { $0.name < $1.name })
    }

    app.post(PathComponent.constant(ServerPaths.tools), PathComponent.constant(ServerPaths.toolCall)) { req async throws -> ToolResult in
        let body = try req.content.decode(ToolCallRequest.self)
        guard !body.toolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Abort(.badRequest, reason: "toolName must not be empty")
        }
        let context = req.application.runeWeaver
        let call = ToolInput(
            toolName: body.toolName,
            argumentsJSON: body.resolvedArgumentsJSON,
            callID: body.resolvedCallID
        )
        return await context.toolBus.execute(
            toolCall: call,
            context: ToolContext(conversationID: UUID())
        )
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
        let memories = try await context.memoryEngine.recall(query: query, limit: limit)
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
        do {
            return try await context.memoryEngine.storeProfileFact(
                content: body.content.trimmingCharacters(in: .whitespacesAndNewlines),
                source: body.resolvedSource
            )
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

/// Registers approvals list plus decide routes.
/// - Parameter app: Application receiving the routes.
private func registerApprovalRoutes(_ app: Application) {
    app.get(PathComponent.constant(ServerPaths.approvals)) { req async throws -> ApprovalsResponse in
        let pending = await req.application.runeWeaver.approvals.list()
        if let limit = try parseQueryLimit(req, min: 1, max: 100) {
            return ApprovalsResponse(approvals: Array(pending.prefix(limit)))
        }
        return ApprovalsResponse(approvals: pending)
    }

    app
        .post(PathComponent.constant(ServerPaths.approvals), PathComponent.parameter("id"),
              PathComponent.constant(ServerPaths.decide))
        { req async throws -> ApprovalDecisionResponse in
            guard let raw = req.parameters.get("id"), let id = UUID(uuidString: raw) else {
                throw Abort(.badRequest, reason: "id must be a UUID")
            }
            let body = try req.content.decode(ApprovalDecisionRequest.self)
            let context = req.application.runeWeaver
            let resolved = await context.approvals.decide(id: id, approved: body.approved, duration: body.resolvedDuration)
            guard resolved else {
                throw Abort(.notFound, reason: "Unknown approval \(raw)")
            }
            return ApprovalDecisionResponse(id: id, approved: body.approved, duration: body.resolvedDuration)
        }
}

/// Registers scheduler job CRUD routes (list, create, fetch, update, delete).
/// - Parameter app: Application receiving the routes.
private func registerSchedulerCRUDRoutes(_ app: Application) {
    let jobs = app.grouped(PathComponent.constant(ServerPaths.scheduler), PathComponent.constant(ServerPaths.jobs))
    jobs.get { req async throws -> SchedulerJobsResponse in
        let all = await req.application.runeWeaver.scheduler.list()
        if let limit = try parseQueryLimit(req, min: 1, max: SchedulerStore.maxJobs) {
            return SchedulerJobsResponse(jobs: Array(all.prefix(limit)))
        }
        return SchedulerJobsResponse(jobs: all)
    }
    jobs.post { req async throws -> SchedulerJob in
        let body = try req.content.decode(NewSchedulerJob.self)
        do {
            return try await req.application.runeWeaver.scheduler.create(body)
        } catch let error as SchedulerStoreError {
            switch error {
            case let .invalidField(detail):
                throw Abort(.badRequest, reason: detail)
            case let .unknownJob(detail):
                throw Abort(.notFound, reason: detail)
            }
        }
    }
    jobs.get(PathComponent.parameter("id")) { req async throws -> SchedulerJob in
        guard let raw = req.parameters.get("id"), let id = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "id must be a UUID")
        }
        guard let job = await req.application.runeWeaver.scheduler.job(id: id) else {
            throw Abort(.notFound, reason: "Unknown job \(raw)")
        }
        return job
    }
    jobs.put(PathComponent.parameter("id")) { req async throws -> SchedulerJob in
        guard let raw = req.parameters.get("id"), let id = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "id must be a UUID")
        }
        let body = try req.content.decode(UpdateSchedulerJob.self)
        do {
            return try await req.application.runeWeaver.scheduler.update(id: id, body)
        } catch let error as SchedulerStoreError {
            switch error {
            case let .invalidField(detail):
                throw Abort(.badRequest, reason: detail)
            case let .unknownJob(detail):
                throw Abort(.notFound, reason: detail)
            }
        }
    }
    jobs.delete(PathComponent.parameter("id")) { req async throws -> HTTPStatus in
        guard let raw = req.parameters.get("id"), let id = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "id must be a UUID")
        }
        let removed = await req.application.runeWeaver.scheduler.delete(id: id)
        guard removed else {
            throw Abort(.notFound, reason: "Unknown job \(raw)")
        }
        return .noContent
    }
}

/// Registers the manual scheduler job run route.
///
/// Manual-run only: the service exposes CRUD plus this single-flight
/// `POST .../run` entry point. Cron and poll triggers never auto-fire in
/// the service; the CLI `scheduler run` foreground loop is the sole
/// auto-fire runner (separate process, separate `SchedulerEngine.running`
/// lock). Concurrent manual runs for the same job inside this process are
/// rejected with `409`.
/// - Parameter app: Application receiving the route.
private func registerSchedulerRunRoute(_ app: Application) {
    let jobs = app.grouped(PathComponent.constant(ServerPaths.scheduler), PathComponent.constant(ServerPaths.jobs))
    jobs.post(PathComponent.parameter("id"), PathComponent.constant(ServerPaths.run)) { req async throws -> OrchestratorResponse in
        guard let raw = req.parameters.get("id"), let id = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "id must be a UUID")
        }
        let context = req.application.runeWeaver
        guard let job = await context.scheduler.job(id: id) else {
            throw Abort(.notFound, reason: "Unknown job \(raw)")
        }
        guard job.enabled else {
            throw Abort(.conflict, reason: "Job \(raw) is disabled")
        }
        guard await context.runLock.tryAcquire(id: id, name: job.name) else {
            await context.runs.append(kind: "scheduler", status: "skipped", message: "Skipped '\(job.name)': already running", jobID: id)
            throw Abort(.conflict, reason: "Job \(raw) is already running")
        }
        do {
            // Stable per-name session shared with the scheduler engine so
            // manual runs and engine fires append to one episodic session.
            let sessionID = SchedulerEngine.deterministicSessionID(forJobNamed: job.name)
            let response = try await context.orchestrator.process(input: UserInput(
                text: job.prompt,
                sessionID: sessionID,
                source: "scheduler"
            ))
            await context.runs.append(kind: "scheduler", status: "ok", message: job.prompt, jobID: id)
            // Offload the blocking `osascript` spawn (`Process.run` plus
            // `waitUntilExit`) to a non-cooperative queue so the Vapor
            // worker never blocks on a child process per manual run
            // (`Task.detached` alone would still occupy a cooperative
            // executor thread).
            let notifyName = job.name
            let notifyPreview = response.text
            DispatchQueue.global(qos: .utility).async {
                SchedulerMacOSNotifier.notify(jobName: notifyName, preview: notifyPreview)
            }
            await context.runLock.release(id: id, name: job.name)
            return response
        } catch let error as CancellationError {
            await context.runLock.release(id: id, name: job.name)
            throw error
        } catch {
            await context.runs.append(kind: "scheduler", status: "error", message: job.prompt, jobID: id)
            await context.runLock.release(id: id, name: job.name)
            throw Abort(.badGateway, reason: error.localizedDescription)
        }
    }
}

/// Registers run-log list plus entry routes.
/// - Parameter app: Application receiving the routes.
private func registerRunRoutes(_ app: Application) {
    app.get(PathComponent.constant(ServerPaths.runs)) { req async throws -> RunLogsResponse in
        let limit = try parseQueryLimit(req, default: 50, min: 1, max: 200)
        let entries = await req.application.runeWeaver.runs.list(limit: limit)
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
}

/// Registers the chat WebSocket with live approval prompts.
///
/// One connection task registers on the hub before consuming a serial
/// `AsyncStream` of inbound frames, so chat turns stay ordered and
/// `remove` always runs after `add` in the same task (no stale
/// sockets). Each frame is awaited serially in the `for await` loop so
/// per-connection frame order is preserved by design; the close handler's
/// `connectionTask.cancel()` still cancels the in-flight turn promptly
/// (cooperative via `Task.isCancelled` checks and the cancellable
/// `ApprovalQueue.waitForDecision`), and `remove` still runs after the
/// loop drains. The close handler finishes the stream and cancels the
/// stored task handle so no per-message tasks leak.
/// - Parameter app: Application receiving the route.
private func registerWebSocketRoute(_ app: Application) {
    app.webSocket(PathComponent.constant(ServerPaths.websocket)) { req, webSocket in
        let context = req.application.runeWeaver
        let connectionID = UUID()
        let box = WSSocketBox(webSocket)
        let (stream, continuation) = AsyncStream<String>.makeStream()
        let connectionTask = Task { [box, context, connectionID, stream] in
            await context.hub.add(id: connectionID, box: box)
            for await text in stream {
                if Task.isCancelled {
                    break
                }
                await handleWebSocketText(text, connectionID: connectionID, context: context)
                if Task.isCancelled {
                    break
                }
            }
            await context.hub.remove(id: connectionID)
        }
        webSocket.onText { _, text in
            continuation.yield(text)
        }
        webSocket.onClose.whenComplete { _ in
            continuation.finish()
            connectionTask.cancel()
        }
    }
}

/// Registers the static dashboard bundle routes.
///
/// The dashboard is compiled once with npm (`cd Web && npm ci && npm
/// run build`) into `Web/dist` and served here on the same loopback
/// origin as the JSON API, so the browser uses relative `fetch` calls
/// with no runtime Node server and no CORS. API routes above keep
/// precedence; these handlers only answer paths no API route claimed.
/// When `Web/dist` is missing the stub reports the Node build steps
/// instead of failing silently.
/// - Parameter app: Application receiving the dashboard routes.
public func registerDashboardRoutes(_ app: Application) {
    let bundle = DashboardBundle.resolve()
    app.get { _ async throws -> Response in
        bundle.response(for: "")
    }
    app.get("**") { req async throws -> Response in
        let remainder = req.parameters.getCatchall().joined(separator: "/")
        return bundle.response(for: remainder)
    }
}

/// Handles one inbound WebSocket text frame.
///
/// Chat frames run the orchestrator and stream the final text back as
/// `delta` chunks plus a `done` frame; decision frames resolve the
/// matching pending approval; anything else answers with an `error`
/// frame so the socket stays open. Cooperative with task cancellation:
/// checks `Task.isCancelled` before work and between sends so closing
/// the socket (or Vapor shutdown) stops the turn promptly instead of
/// streaming into a dead connection. All sends funnel through the hub
/// (`send(id:text:)`) so streamed deltas never race broadcast prompts.
/// - Parameters:
///   - text: Raw socket text frame.
///   - connectionID: Connection identifier owning the reply.
///   - context: Shared engine collaborators.
private func handleWebSocketText(_ text: String, connectionID: UUID, context: ServerContext) async {
    if Task.isCancelled {
        return
    }
    switch WSInboundKind.classify(text) {
    case let .chat(message):
        let trimmed: String
        do {
            trimmed = try validatedChatText(message.text)
        } catch let abort as Abort {
            await sendWSError(abort.reason, connectionID: connectionID, context: context)
            return
        } catch {
            await sendWSError(error.localizedDescription, connectionID: connectionID, context: context)
            return
        }
        if Task.isCancelled {
            return
        }
        let sessionID = message.sessionID ?? UUID()
        let source = (message.source ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let response = try await context.orchestrator.process(input: UserInput(
                text: trimmed,
                sessionID: sessionID,
                source: source.isEmpty ? "websocket" : source
            ))
            if Task.isCancelled {
                return
            }
            await context.runs.append(kind: "chat", status: "ok", message: trimmed)
            for chunk in WSStreaming.deltas(for: response.text) {
                if Task.isCancelled {
                    break
                }
                guard let data = try? JSONEncoder().encode(WSStreamDelta(delta: chunk)),
                      let frame = String(data: data, encoding: .utf8)
                else { continue }
                await context.hub.send(id: connectionID, text: frame)
            }
            if Task.isCancelled {
                return
            }
            if let data = try? JSONEncoder().encode(WSStreamDone(text: response.text, sessionID: response.sessionID)),
               let frame = String(data: data, encoding: .utf8)
            {
                await context.hub.send(id: connectionID, text: frame)
            }
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled {
                return
            }
            await context.runs.append(kind: "chat", status: "error", message: trimmed)
            await sendWSError(error.localizedDescription, connectionID: connectionID, context: context)
        }
    case let .decision(message):
        if Task.isCancelled {
            return
        }
        let resolved = await context.approvals.decide(
            id: message.id,
            approved: message.approved,
            duration: message.resolvedDuration
        )
        guard resolved else {
            await sendWSError("Unknown approval \(message.id.uuidString)", connectionID: connectionID, context: context)
            return
        }
    case .unknown:
        let hint = "Expected a chat frame {\"text\": \"...\"} or a decision frame {\"id\": \"...\", \"approved\": true}"
        await sendWSError(hint, connectionID: connectionID, context: context)
    }
}

/// Sends one WebSocket error frame through the hub, best-effort.
/// - Parameters:
///   - message: Human-readable failure.
///   - connectionID: Connection identifier owning the reply.
///   - context: Shared engine collaborators.
private func sendWSError(_ message: String, connectionID: UUID, context: ServerContext) async {
    if Task.isCancelled {
        return
    }
    guard let data = try? JSONEncoder().encode(WSErrorFrame(message: message)),
          let frame = String(data: data, encoding: .utf8)
    else { return }
    await context.hub.send(id: connectionID, text: frame)
}

extension ServerContext {
    /// Engine name surfaced on `/health` without exposing config details.
    var memoryEngineDescription: String {
        "Rune Weaver"
    }
}

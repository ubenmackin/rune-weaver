// Rune Weaver Tests — Decision contract for parked approvals on REST and WebSocket.

import Foundation
import NIOWebSocket
import RuneWeaverCore
@testable import RuneWeaverServer
import RuneWeaverTools
import Testing
import Vapor

/// Recording socket capturing hub frames without a live handshake, so a
/// transport's rejection frame is directly observable.
private actor DecisionRecordingSocket: WSConnectionSocket {
    /// Text frames delivered to this connection.
    private(set) var sent: [String] = []

    /// Records one text frame.
    func send(_ text: String) async throws {
        sent.append(text)
    }

    /// Ignored; the decision path never closes the connection.
    func close(code _: WebSocketErrorCode) async throws {}
}

/// Probe tool standing in for `api.request` on the gate authorization path.
private struct EgressGateProbeTool: Tool, Sendable {
    /// Tool name the gate branches and scopes on.
    let name: String
    /// Trust level the probe declares; approval-gated like the real tool.
    var permissionLevel: PermissionLevel = .requiresApproval

    /// Summary shown in approval prompts.
    var description: String {
        "Probe for \(name)."
    }

    /// Accepts any object; the gate reads only the fields it names.
    var inputSchema: JSONSchema {
        .emptyObject
    }

    /// The probe never executes; the verdict is the assertion target.
    func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        .success("probe-ok", callID: input.callID)
    }
}

/// Records the effective verdicts a shared decision handed its
/// transport-owned resume spawner.
private actor DecisionResumeRecorder {
    /// Effective verdicts in call order.
    private(set) var calls: [Bool] = []

    /// Records one effective verdict.
    func record(_ effectiveApproved: Bool) {
        calls.append(effectiveApproved)
    }
}

/// One throwaway verified policy plus the context wired to it.
private struct DecisionHarness {
    /// Context whose store and supervisor are the instances under test.
    let context: ServerContext
    /// The one policy store the handlers read and write.
    let store: PolicyStore
    /// Backing policy file, read back to prove a rejected write never landed.
    let fileURL: URL
    /// Throwaway directory removed at test end.
    let directory: URL

    /// Current policy file text, or nil when no write has landed yet.
    /// - Returns: File contents, or nil when absent or unreadable.
    func persistedPolicy() -> String? {
        try? String(contentsOf: fileURL, encoding: .utf8)
    }

    /// Removes the throwaway directory.
    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Builds an isolated context whose policy file, store, and supervisor are the exact instances the
/// REST and WebSocket handlers read.
private func makeDecisionHarness(wiredSupervisor: Bool = true) async throws -> DecisionHarness {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("rw-decision-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appendingPathComponent("policy.toml")
    let store = PolicyStore(fileURL: fileURL)
    await store.load()
    let supervisor = await wiredSupervisor ? (try? OutboundEgressSupervisor.make(policyStore: store)) : nil
    let base = ServerContext.fallbackUnconfigured
    let gate = PermissionGate(ruleStore: InMemoryAccessRuleStore())
    let context = ServerContext(
        config: .default,
        conversations: base.conversations,
        toolBus: base.toolBus,
        orchestrator: base.orchestrator,
        memoryEngine: base.memoryEngine,
        permissionGate: gate,
        approvals: ApprovalQueue(permissionGate: gate),
        hub: WSHub(),
        steeringQueue: base.steeringQueue,
        policyStore: store,
        egressSupervisor: supervisor
    )
    // Wire the gate and supervisor both ways like production boot: the gate consults the supervisor
    // for host status and the supervisor honors the gate's covering domain allows, so a durable or
    // task-tier approval keeps the next identical call auto-approved at both layers.
    if let supervisor {
        await gate.setEgressEvaluator(supervisor)
        await supervisor.setPermissionGate(gate)
    }
    return DecisionHarness(context: context, store: store, fileURL: fileURL, directory: directory)
}

/// Enqueues one unlisted `api.request` approval carrying the given host. The host is passed
/// explicitly so the guard under test is exercised against a deterministic wildcard shape rather
/// than URL-parser spelling.
private func enqueueEgressRequest(
    host: String,
    sessionID: UUID? = nil,
    context: ServerContext
) async -> PermissionRequest {
    let request = PermissionRequest(
        toolName: "api.request",
        description: "Outbound request.",
        input: ToolInput(toolName: "api.request", argumentsJSON: "{}"),
        sessionID: sessionID,
        egressHost: host
    )
    await context.approvals.enqueue(request)
    return request
}

/// Polls a recording socket until it captures at least one frame or the budget expires.
/// - Parameter socket: Recording socket under test.
/// - Returns: Frames captured at the deadline.
private func waitForDecisionFrames(_ socket: DecisionRecordingSocket) async -> [String] {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        let frames = await socket.sent
        if !frames.isEmpty {
            return frames
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return await socket.sent
}

/// Runs one test body against an application serving the full engine routes over the isolated
/// context, shutting the app down on every exit path. context: Context the routes
/// must serve.
private func withDecisionRouteApp<T>(
    context: ServerContext,
    _ body: (Application) async throws -> T
) async throws -> T {
    let app = try await Application.make(.testing)
    do {
        app.runeWeaver = context
        registerRuneWeaverRoutes(app)
        let value = try await body(app)
        try await app.asyncShutdown()
        return value
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
}

/// Runs one approval decision through the real REST route surface. app: Configured
/// application.
private func decideViaREST(
    app: Application,
    id: UUID,
    approved: Bool,
    duration: TrustDuration
) async throws -> Response {
    let request = Request(
        application: app,
        method: .POST,
        url: URI(string: "/approvals/\(id.uuidString)/decide"),
        on: app.eventLoopGroup.next()
    )
    // The unified body carries exactly the approved flag plus the tier, which
    // is the whole decision contract an egress-parked request resolves against.
    try request.content.encode(RESTDecisionBody(approved: approved, duration: duration.rawValue))
    return try await app.responder.respond(to: request).get()
}

/// Wire body the unified decision path carries for these tests.
private struct RESTDecisionBody: Content {
    /// Approval polarity.
    let approved: Bool
    /// Requested trust tier raw value.
    let duration: String
}

/// Drives one decision frame through the real WebSocket inbound path. text: Raw
/// decision frame text.
private func decideViaWebSocket(_ text: String, context: ServerContext) async -> DecisionRecordingSocket {
    let socket = DecisionRecordingSocket()
    let connectionID = UUID()
    _ = await context.hub.add(id: connectionID, box: socket)
    // Drive the real inbound classification plus scope decode so the test
    // covers the WebSocket transport end to end, not only the shared function
    // it dispatches into.
    await handleWebSocketText(
        text,
        connectionID: connectionID,
        context: context,
        connectionTasks: ConnectionChatTasks()
    )
    return socket
}

/// Renders one decision frame for the WebSocket transport. id: Pending approval
/// identifier.
private func decisionFrame(id: UUID, approved: Bool, duration: TrustDuration) -> String {
    #"{"id":"\#(id.uuidString)","approved":\#(approved ? "true" : "false"),"duration":"\#(duration.rawValue)"}"#
}

/// Applies one decision through the shared contract and returns its outcome. id:
/// Pending approval identifier.
private func decideShared(
    id: UUID,
    approved: Bool,
    duration: TrustDuration,
    pending: PermissionRequest,
    context: ServerContext
) async -> ApprovalDecisionOutcome {
    await applyApprovalDecision(
        input: ApprovalDecisionInput(
            id: id,
            approved: approved,
            duration: duration,
            pending: pending
        ),
        pulse: nil,
        context: context,
        spawnResume: { _ in }
    )
}

@Suite("Egress Decision Contract")
struct EgressDecisionContractTests {
    @Test
    func `Wildcard host fails closed on every allow tier and writes no policy`() async throws {
        let harness = try await makeDecisionHarness()
        defer { harness.cleanUp() }
        let before = harness.persistedPolicy()

        // Hostile shapes span leading, trailing, bare, embedded, and
        // port-qualified stars so the guard cannot be bypassed by a spelling
        // that classifies as any non-exact wildcard.
        let hostileHosts = ["*.com", "*.co.uk", "*", "example.*", "api.*.com", "*.com:443"]
        let sessionID = UUID()
        for hostile in hostileHosts {
            let request = await enqueueEgressRequest(host: hostile, sessionID: sessionID, context: harness.context)
            for duration in [TrustDuration.thisTime, .forSession, .forever] {
                let outcome = await decideShared(
                    id: request.id,
                    approved: true,
                    duration: duration,
                    pending: request,
                    context: harness.context
                )
                guard case .sideEffectFailed = outcome else {
                    Issue.record("Expected \(duration.rawValue) to refuse '\(hostile)'")
                    continue
                }
            }
            // The approval stays pending so the caller has only deny left.
            #expect(await harness.context.approvals.request(id: request.id) != nil)
        }

        #expect(harness.persistedPolicy() == before)
        #expect(harness.persistedPolicy()?.contains("*") != true)
        // The factory posture already trusts loopback, so prove the refusal by
        // the absence of every hostile entry rather than an empty allowlist.
        let allowed = try await harness.store.snapshot().network.allowedDomains
        #expect(allowed.intersection(hostileHosts).isEmpty)
        #expect(await harness.context.permissionGate.activeRules().isEmpty)
    }

    @Test
    func `thisTime allow spends a one-shot supervisor grant`() async throws {
        let harness = try await makeDecisionHarness()
        defer { harness.cleanUp() }
        let sessionID = UUID()
        let request = await enqueueEgressRequest(host: "api.github.com", sessionID: sessionID, context: harness.context)

        let outcome = await decideShared(
            id: request.id,
            approved: true,
            duration: .thisTime,
            pending: request,
            context: harness.context
        )
        guard case let .resolved(approved) = outcome else {
            Issue.record("Expected a resolved one-shot allow")
            return
        }
        #expect(approved == true)

        // The grant is a supervisor one-shot scoped to the owning session, and
        // nothing durable was stored for it.
        let summary = await harness.context.egressSupervisor?.activeGrants(sessionID: sessionID)
        #expect(summary?.oneShotDomains == ["api.github.com"])
        #expect(summary?.sessionDomains.isEmpty == true)
        #expect(await harness.context.permissionGate.activeRules().isEmpty)
        #expect(harness.persistedPolicy()?.contains("api.github.com") != true)
    }

    @Test
    func `forSession allow grants the domain to the conversation`() async throws {
        let harness = try await makeDecisionHarness()
        defer { harness.cleanUp() }
        let sessionID = UUID()
        let request = await enqueueEgressRequest(host: "api.github.com", sessionID: sessionID, context: harness.context)

        let outcome = await decideShared(
            id: request.id,
            approved: true,
            duration: .forSession,
            pending: request,
            context: harness.context
        )
        guard case let .resolved(approved) = outcome else {
            Issue.record("Expected a resolved session allow")
            return
        }
        #expect(approved == true)

        let summary = await harness.context.egressSupervisor?.activeGrants(sessionID: sessionID)
        #expect(summary?.sessionDomains == ["api.github.com"])
        #expect(summary?.oneShotDomains.isEmpty == true)
        // A session tier never persists a rule or a policy entry.
        #expect(await harness.context.permissionGate.activeRules().isEmpty)
        #expect(harness.persistedPolicy()?.contains("api.github.com") != true)
    }

    @Test
    func `forever allow mints a durable domain rule`() async throws {
        let harness = try await makeDecisionHarness()
        defer { harness.cleanUp() }
        let sessionID = UUID()
        let request = await enqueueEgressRequest(host: "api.github.com", sessionID: sessionID, context: harness.context)

        let outcome = await decideShared(
            id: request.id,
            approved: true,
            duration: .forever,
            pending: request,
            context: harness.context
        )
        guard case let .resolved(approved) = outcome else {
            Issue.record("Expected a resolved durable allow")
            return
        }
        #expect(approved == true)

        // The durable half is a domain-scoped allow rule, so the decision is
        // visible on the rules surface and survives a restart of the process.
        let rules = await harness.context.permissionGate.activeRules()
        #expect(rules.count == 1)
        #expect(rules.first?.action == .allow)
        #expect(rules.first?.toolName == "api.request")
        #expect(rules.first?.scope == .domain(host: "api.github.com", subdomains: false))
        #expect(rules.first?.expiresAt == nil)
        // A durable egress allow stores no supervisor grant and writes no
        // policy entry: the rule is the whole durable record.
        let summary = await harness.context.egressSupervisor?.activeGrants(sessionID: sessionID)
        #expect(summary?.sessionDomains.isEmpty == true)
        #expect(summary?.oneShotDomains.isEmpty == true)
        #expect(harness.persistedPolicy()?.contains("api.github.com") != true)

        // The rule authorizes the next identical call: the gate allows it and the supervisor
        // reports the host allowed, in a session that never approved anything, proving the trust is
        // durable rather than session-bound.
        let nextCall = ToolInput(toolName: "api.request", argumentsJSON: #"{"url":"https://api.github.com/repos"}"#)
        #expect(await harness.context.permissionGate.checkPermission(toolCall: nextCall, tool: EgressGateProbeTool(name: "api.request"), sessionID: UUID()) == .allowed)
        #expect(await harness.context.egressSupervisor?.evaluateHostStatus(for: "api.github.com", sessionID: UUID()) == .allowed)
    }

    @Test
    func `fiveMinutes allow authorizes the next identical call at the gate and supervisor`() async throws {
        let harness = try await makeDecisionHarness()
        defer { harness.cleanUp() }
        let sessionID = UUID()
        let request = await enqueueEgressRequest(host: "api.github.com", sessionID: sessionID, context: harness.context)

        let outcome = await decideShared(
            id: request.id,
            approved: true,
            duration: .fiveMinutes,
            pending: request,
            context: harness.context
        )
        guard case let .resolved(approved) = outcome else {
            Issue.record("Expected a resolved five-minutes allow")
            return
        }
        #expect(approved == true)

        // The dated tier persists as a domain-scoped allow rule carrying its
        // expiry, with no supervisor grant and no policy write beside it.
        let rules = await harness.context.permissionGate.activeRules()
        #expect(rules.count == 1)
        #expect(rules.first?.action == .allow)
        #expect(rules.first?.toolName == "api.request")
        #expect(rules.first?.scope == .domain(host: "api.github.com", subdomains: false))
        #expect(rules.first?.duration == .fiveMinutes)
        #expect(rules.first?.expiresAt != nil)

        // The rule authorizes the next identical call while it lives: the
        // gate allows it and the supervisor reports the host allowed.
        let nextCall = ToolInput(toolName: "api.request", argumentsJSON: #"{"url":"https://api.github.com/repos"}"#)
        #expect(await harness.context.permissionGate.checkPermission(toolCall: nextCall, tool: EgressGateProbeTool(name: "api.request"), sessionID: sessionID) == .allowed)
        #expect(await harness.context.egressSupervisor?.evaluateHostStatus(for: "api.github.com", sessionID: sessionID) == .allowed)
    }

    @Test
    func `forTask allow authorizes the next identical call in session at the gate and supervisor`() async throws {
        let harness = try await makeDecisionHarness()
        defer { harness.cleanUp() }
        let sessionID = UUID()
        let request = await enqueueEgressRequest(host: "api.github.com", sessionID: sessionID, context: harness.context)

        let outcome = await decideShared(
            id: request.id,
            approved: true,
            duration: .forTask,
            pending: request,
            context: harness.context
        )
        guard case let .resolved(approved) = outcome else {
            Issue.record("Expected a resolved task allow")
            return
        }
        #expect(approved == true)

        // The task tier lives as an in-memory ephemeral grant, never as a
        // durable rule, a supervisor grant, or a policy write.
        let grants = await harness.context.permissionGate.ephemeralGrants(sessionID: sessionID)
        #expect(grants.count == 1)
        #expect(grants.first?.kind == .task)
        #expect(grants.first?.toolName == "api.request")
        #expect(grants.first?.scope == .domain(host: "api.github.com", subdomains: false))
        #expect(await harness.context.permissionGate.activeRules().isEmpty)

        // The grant authorizes the next identical call in its session at both
        // layers, while another session still parks and stays unlisted.
        let nextCall = ToolInput(toolName: "api.request", argumentsJSON: #"{"url":"https://api.github.com/repos"}"#)
        #expect(await harness.context.permissionGate.checkPermission(toolCall: nextCall, tool: EgressGateProbeTool(name: "api.request"), sessionID: sessionID) == .allowed)
        #expect(await harness.context.egressSupervisor?.evaluateHostStatus(for: "api.github.com", sessionID: sessionID) == .allowed)
        let otherSession = UUID()
        let parked = await harness.context.permissionGate.checkPermission(toolCall: nextCall, tool: EgressGateProbeTool(name: "api.request"), sessionID: otherSession)
        guard case .requiresApproval = parked else {
            Issue.record("Expected another session to re-park, got \(parked)")
            return
        }
        #expect(await harness.context.egressSupervisor?.evaluateHostStatus(for: "api.github.com", sessionID: otherSession) != .allowed)
    }

    @Test
    func `thisTime deny refuses the call only`() async throws {
        let harness = try await makeDecisionHarness()
        defer { harness.cleanUp() }
        let before = harness.persistedPolicy()
        let request = await enqueueEgressRequest(host: "api.github.com", context: harness.context)

        let outcome = await decideShared(
            id: request.id,
            approved: false,
            duration: .thisTime,
            pending: request,
            context: harness.context
        )
        guard case let .resolved(approved) = outcome else {
            Issue.record("Expected a resolved one-shot deny")
            return
        }
        #expect(approved == false)

        // A one-shot deny is the safe default: nothing stored anywhere, so the
        // next identical call re-parks instead of auto-denying.
        #expect(await harness.context.permissionGate.activeRules().isEmpty)
        #expect(harness.persistedPolicy() == before)
        let policy = try await harness.store.snapshot()
        #expect(policy.network.blockedDomains.contains("api.github.com") == false)
        #expect(policy.network.allowedDomains.contains("api.github.com") == false)
    }

    @Test
    func `forever deny blocks the domain and mints a durable deny rule`() async throws {
        let harness = try await makeDecisionHarness()
        defer { harness.cleanUp() }
        let request = await enqueueEgressRequest(host: "blocked.example.com", context: harness.context)

        let outcome = await decideShared(
            id: request.id,
            approved: false,
            duration: .forever,
            pending: request,
            context: harness.context
        )
        guard case let .resolved(approved) = outcome else {
            Issue.record("Expected a resolved durable deny")
            return
        }
        #expect(approved == false)

        // The blocked entry lets the next identical call auto-deny, and the
        // rule beside it carries the refusal onto the rules surface.
        let policy = try await harness.store.snapshot()
        #expect(policy.network.blockedDomains.contains("blocked.example.com"))
        #expect(policy.network.allowedDomains.contains("blocked.example.com") == false)
        #expect(harness.persistedPolicy()?.contains("blocked.example.com") == true)
        let rules = await harness.context.permissionGate.activeRules()
        #expect(rules.count == 1)
        #expect(rules.first?.action == .deny)
        #expect(rules.first?.scope == .domain(host: "blocked.example.com", subdomains: false))
        #expect(rules.first?.expiresAt == nil)
    }

    @Test
    func `a missing supervisor fails the one-shot allow closed`() async throws {
        let harness = try await makeDecisionHarness(wiredSupervisor: false)
        defer { harness.cleanUp() }
        let request = await enqueueEgressRequest(host: "api.github.com", context: harness.context)

        let outcome = await decideShared(
            id: request.id,
            approved: true,
            duration: .thisTime,
            pending: request,
            context: harness.context
        )
        guard case .sideEffectFailed = outcome else {
            Issue.record("Expected a supervisor-less one-shot allow to fail closed")
            return
        }
        // Nothing resolved, so the request stays parked for a later decision.
        #expect(await harness.context.approvals.request(id: request.id) != nil)
    }

    @Test
    func `a malformed decision scope fails before the gate runs`() {
        // An unknown kind and a wildcard host both fail the canonical gate, so
        // neither reaches a mint path that would have to refuse it.
        for scope in [["kind": "nonsense"], ["kind": "domain", "host": "*.com"]] {
            let payload = ["approved": true, "duration": "forever", "scope": scope] as [String: Any]
            let decoded = try? JSONDecoder().decode(
                ApprovalDecisionRequest.self,
                from: JSONSerialization.data(withJSONObject: payload)
            )
            #expect(decoded == nil, "scope \(scope) must fail decoding")
        }
    }

    @Test
    func `an unknown approval is not resolved by either transport`() async throws {
        let harness = try await makeDecisionHarness()
        defer { harness.cleanUp() }
        let unknown = UUID()

        let outcome = await applyApprovalDecision(
            input: ApprovalDecisionInput(
                id: unknown,
                approved: true,
                duration: .forever
            ),
            pulse: nil,
            context: harness.context,
            spawnResume: { _ in }
        )
        guard case .unknown = outcome else {
            Issue.record("Expected unknown for a missing pending request")
            return
        }

        try await withDecisionRouteApp(context: harness.context) { app in
            let response = try await decideViaREST(app: app, id: unknown, approved: true, duration: .forever)
            #expect(response.status == .notFound)
        }
        let socket = await decideViaWebSocket(
            decisionFrame(id: unknown, approved: true, duration: .forever),
            context: harness.context
        )
        let frames = await waitForDecisionFrames(socket)
        #expect(frames.contains { $0.contains("Unknown approval") })
    }

    @Test
    func `a question approval still reports the respond route on both transports`() async throws {
        let harness = try await makeDecisionHarness()
        defer { harness.cleanUp() }
        let sessionID = UUID()
        let request = await harness.context.approvals.enqueue(
            toolName: "question.ask",
            description: "Which one?",
            input: ToolInput(toolName: "question.ask", argumentsJSON: #"{"question":"Pick one"}"#),
            sessionID: sessionID
        )

        let outcome = await decideShared(
            id: request.id,
            approved: true,
            duration: .thisTime,
            pending: request,
            context: harness.context
        )
        guard case .questionRequiresRespond = outcome else {
            Issue.record("Expected the question guard to hold")
            return
        }

        try await withDecisionRouteApp(context: harness.context) { app in
            let response = try await decideViaREST(app: app, id: request.id, approved: true, duration: .thisTime)
            #expect(response.status == .badRequest)
        }
        let socket = await decideViaWebSocket(
            decisionFrame(id: request.id, approved: true, duration: .thisTime),
            context: harness.context
        )
        let frames = await waitForDecisionFrames(socket)
        #expect(frames.contains { $0.contains("Use /respond for question.ask") || $0.contains(#"Use \/respond for question.ask"#) })
        #expect(await harness.context.approvals.request(id: request.id) != nil)
    }

    @Test
    func `REST and WebSocket map the same tiers identically`() async throws {
        // Both transports resolve through one shared function, so the durable
        // record for one (approved, duration) pair cannot depend on which
        // surface the owner decided from.
        let restHarness = try await makeDecisionHarness()
        defer { restHarness.cleanUp() }
        let socketHarness = try await makeDecisionHarness()
        defer { socketHarness.cleanUp() }

        // No session tag: the mapping parity under test concerns the stored
        // record, and an untagged decision spawns no resume whose broadcast
        // would race the frame assertions below.
        let restRequest = await enqueueEgressRequest(host: "api.github.com", context: restHarness.context)
        let socketRequest = await enqueueEgressRequest(host: "api.github.com", context: socketHarness.context)

        try await withDecisionRouteApp(context: restHarness.context) { app in
            let response = try await decideViaREST(app: app, id: restRequest.id, approved: true, duration: .forever)
            #expect(response.status == .ok)
            let decoded = try response.content.decode(ApprovalDecisionResponse.self)
            #expect(decoded.approved == true)
            #expect(decoded.duration == .forever)
        }
        let socket = await decideViaWebSocket(
            decisionFrame(id: socketRequest.id, approved: true, duration: .forever),
            context: socketHarness.context
        )
        #expect(await socketHarness.context.approvals.request(id: socketRequest.id) == nil)
        // A durable allow broadcasts the rules change on the approving
        // transport exactly like the durable REST path does.
        let frames = await waitForDecisionFrames(socket)
        #expect(frames.contains { $0.contains("access_rules_changed") })

        let restRules = await restHarness.context.permissionGate.activeRules()
        let socketRules = await socketHarness.context.permissionGate.activeRules()
        #expect(restRules.map(\.action) == socketRules.map(\.action))
        #expect(restRules.map(\.toolName) == socketRules.map(\.toolName))
        #expect(restRules.map(\.scope) == socketRules.map(\.scope))
        #expect(restRules.map(\.duration) == socketRules.map(\.duration))
        #expect(restRules.map(\.expiresAt) == socketRules.map(\.expiresAt))
    }

    @Test
    func `a session-tagged decision hands the resume its effective verdict`() async throws {
        let harness = try await makeDecisionHarness()
        defer { harness.cleanUp() }
        let sessionID = UUID()
        let recorder = DecisionResumeRecorder()
        let request = await harness.context.approvals.enqueue(
            toolName: "stub.write",
            description: "Write stub.",
            input: ToolInput(toolName: "stub.write", argumentsJSON: #"{"path":"/tmp/ws.md"}"#),
            sessionID: sessionID
        )

        let outcome = await applyApprovalDecision(
            input: ApprovalDecisionInput(
                id: request.id,
                approved: true,
                duration: .thisTime,
                pending: request
            ),
            pulse: nil,
            context: harness.context,
            spawnResume: { effectiveApproved in
                await recorder.record(effectiveApproved)
            }
        )

        // The resume block stays shared with REST, so the transport only owns
        // how the synthesis task is tracked, never whether it runs.
        #expect(outcome == .resolved(approved: true))
        #expect(await recorder.calls == [true])
        #expect(await harness.context.approvals.request(id: request.id) == nil)
    }
}

@Suite("Egress Decision Transports")
struct EgressDecisionTransportTests {
    @Test
    func `REST wildcard allow fails closed and leaves the approval pending`() async throws {
        let harness = try await makeDecisionHarness()
        defer { harness.cleanUp() }
        let before = harness.persistedPolicy()
        let approval = await enqueueEgressRequest(host: "*.com", context: harness.context)

        try await withDecisionRouteApp(context: harness.context) { app in
            let response = try await decideViaREST(app: app, id: approval.id, approved: true, duration: .forever)
            #expect(response.status == .unprocessableEntity)
        }

        #expect(await harness.context.approvals.request(id: approval.id) != nil)
        #expect(harness.persistedPolicy() == before)
        #expect(await harness.context.permissionGate.activeRules().isEmpty)
    }

    @Test
    func `REST exact-host allow approves and mints the durable rule`() async throws {
        let harness = try await makeDecisionHarness()
        defer { harness.cleanUp() }
        let approval = await enqueueEgressRequest(host: "api.github.com", context: harness.context)

        try await withDecisionRouteApp(context: harness.context) { app in
            let response = try await decideViaREST(app: app, id: approval.id, approved: true, duration: .forever)
            #expect(response.status == .ok)
            let decoded = try response.content.decode(ApprovalDecisionResponse.self)
            #expect(decoded.approved == true)
        }

        #expect(await harness.context.approvals.request(id: approval.id) == nil)
        let rules = await harness.context.permissionGate.activeRules()
        #expect(rules.count == 1)
        #expect(rules.first?.scope == .domain(host: "api.github.com", subdomains: false))
        #expect(rules.first?.action == .allow)

        // The minted rule authorizes the next identical call at the gate and
        // in supervisor validation, not just on the rules surface.
        let nextCall = ToolInput(toolName: "api.request", argumentsJSON: #"{"url":"https://api.github.com/repos"}"#)
        #expect(await harness.context.permissionGate.checkPermission(toolCall: nextCall, tool: EgressGateProbeTool(name: "api.request")) == .allowed)
        #expect(await harness.context.egressSupervisor?.evaluateHostStatus(for: "api.github.com", sessionID: nil) == .allowed)
    }

    @Test
    func `WebSocket wildcard allow fails closed and leaves the approval pending`() async throws {
        let harness = try await makeDecisionHarness()
        defer { harness.cleanUp() }
        let before = harness.persistedPolicy()
        let approval = await enqueueEgressRequest(host: "*.com", context: harness.context)

        let socket = await decideViaWebSocket(
            decisionFrame(id: approval.id, approved: true, duration: .forever),
            context: harness.context
        )

        #expect(await harness.context.approvals.request(id: approval.id) != nil)
        #expect(harness.persistedPolicy() == before)
        // The requester learns the decision could not be applied instead of
        // the approval silently resolving as approved.
        let frames = await waitForDecisionFrames(socket)
        #expect(frames.contains { $0.contains("could not be applied") })
    }

    @Test
    func `REST deny resolves the request as denied without side effects`() async throws {
        let harness = try await makeDecisionHarness()
        defer { harness.cleanUp() }
        let before = harness.persistedPolicy()
        let approval = await enqueueEgressRequest(host: "api.github.com", context: harness.context)

        try await withDecisionRouteApp(context: harness.context) { app in
            let response = try await decideViaREST(app: app, id: approval.id, approved: false, duration: .thisTime)
            #expect(response.status == .ok)
            let decoded = try response.content.decode(ApprovalDecisionResponse.self)
            #expect(decoded.approved == false)
        }

        #expect(await harness.context.approvals.request(id: approval.id) == nil)
        #expect(harness.persistedPolicy() == before)
        #expect(await harness.context.permissionGate.activeRules().isEmpty)
    }

    @Test
    func `REST denyAlways writes the blocked domain and mints the deny rule`() async throws {
        let harness = try await makeDecisionHarness()
        defer { harness.cleanUp() }
        let approval = await enqueueEgressRequest(host: "blocked.example.com", context: harness.context)

        try await withDecisionRouteApp(context: harness.context) { app in
            let response = try await decideViaREST(app: app, id: approval.id, approved: false, duration: .forever)
            #expect(response.status == .ok)
            let decoded = try response.content.decode(ApprovalDecisionResponse.self)
            #expect(decoded.approved == false)
        }

        #expect(await harness.context.approvals.request(id: approval.id) == nil)
        let policy = try await harness.store.snapshot()
        #expect(policy.network.blockedDomains.contains("blocked.example.com"))
        #expect(harness.persistedPolicy()?.contains("blocked.example.com") == true)
        let rules = await harness.context.permissionGate.activeRules()
        #expect(rules.count == 1)
        #expect(rules.first?.action == .deny)
        #expect(rules.first?.scope == .domain(host: "blocked.example.com", subdomains: false))
    }

    @Test
    func `WebSocket deny resolves the request as denied without side effects`() async throws {
        let harness = try await makeDecisionHarness()
        defer { harness.cleanUp() }
        let before = harness.persistedPolicy()
        let approval = await enqueueEgressRequest(host: "api.github.com", context: harness.context)

        let socket = await decideViaWebSocket(
            decisionFrame(id: approval.id, approved: false, duration: .thisTime),
            context: harness.context
        )

        #expect(await harness.context.approvals.request(id: approval.id) == nil)
        #expect(harness.persistedPolicy() == before)
        // A successful deny needs no acknowledgement, and no error frame may
        // arrive: an owned error reads as a terminal turn failure to clients.
        #expect(await socket.sent.isEmpty)
    }

    @Test
    func `WebSocket denyAlways writes the blocked domain and mints the deny rule`() async throws {
        let harness = try await makeDecisionHarness()
        defer { harness.cleanUp() }
        let approval = await enqueueEgressRequest(host: "blocked.example.com", context: harness.context)

        let socket = await decideViaWebSocket(
            decisionFrame(id: approval.id, approved: false, duration: .forever),
            context: harness.context
        )

        #expect(await harness.context.approvals.request(id: approval.id) == nil)
        let policy = try await harness.store.snapshot()
        #expect(policy.network.blockedDomains.contains("blocked.example.com"))
        #expect(harness.persistedPolicy()?.contains("blocked.example.com") == true)
        // A durable deny mint refreshes dashboards exactly like a durable allow mint:
        // approved=false plus forever stores a standing deny rule inside `decide`, so the deciding
        // socket receives exactly one access_rules_changed frame — no acknowledgement and no error.
        var frames = await waitForDecisionFrames(socket)
        // Let a duplicate broadcast or stray ack/error land before pinning
        // the count, so a late straggler cannot dodge the assertion.
        try? await Task.sleep(nanoseconds: 300_000_000)
        frames = await socket.sent
        #expect(frames.count == 1)
        #expect(frames.first?.contains("access_rules_changed") == true)
    }

    @Test
    func `WebSocket malformed scope fails closed before the gate runs`() async throws {
        let harness = try await makeDecisionHarness()
        defer { harness.cleanUp() }
        let approval = await enqueueEgressRequest(host: "api.github.com", context: harness.context)

        let socket = await decideViaWebSocket(
            #"{"id":"\#(approval.id.uuidString)","approved":true,"duration":"forever","scope":{"kind":"nonsense"}}"#,
            context: harness.context
        )

        #expect(await harness.context.approvals.request(id: approval.id) != nil)
        #expect(await harness.context.permissionGate.activeRules().isEmpty)
        let frames = await waitForDecisionFrames(socket)
        #expect(frames.contains { $0.contains("Unknown decision scope") })
    }

    @Test
    func `WebSocket exact-host allow approves through the real frame path`() async throws {
        let harness = try await makeDecisionHarness()
        defer { harness.cleanUp() }
        let sessionID = UUID()
        let approval = await enqueueEgressRequest(host: "api.github.com", sessionID: sessionID, context: harness.context)

        _ = await decideViaWebSocket(
            decisionFrame(id: approval.id, approved: true, duration: .forSession),
            context: harness.context
        )

        #expect(await harness.context.approvals.request(id: approval.id) == nil)
        let summary = await harness.context.egressSupervisor?.activeGrants(sessionID: sessionID)
        #expect(summary?.sessionDomains == ["api.github.com"])
        #expect(summary?.oneShotDomains.isEmpty == true)
        // A session tier stores no durable rule, so the rules surface stays
        // empty and the decision needed no refresh broadcast.
        #expect(await harness.context.permissionGate.activeRules().isEmpty)
    }
}

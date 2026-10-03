// Rune Weaver Tests — Egress decision approval guards for REST and WebSocket.
//
// Purpose: pins the fail-closed contract of `applyEgressDecision` when a
// model-supplied network target carries a wildcard-shaped host (`*.com`, `*`,
// `example.*`). The egress matcher treats such a pattern as covering every
// destination it names, so an approval click must neither approve the call nor
// persist the pattern into policy.toml — wildcard entries remain a deliberate
// policy-editor action only.
// Scope: decision-tier side effects through the one handler REST and WebSocket
// triage share, plus each transport's rejection behavior. Wildcard
// classification itself and policy invariant math stay with their own suites.
// Architectural role: regression coverage for the single shared triage handler,
// so a future tier edit cannot reopen broad, attacker-steerable egress.

import Foundation
import NIOWebSocket
import RuneWeaverCore
@testable import RuneWeaverServer
import RuneWeaverTools
import Testing
import Vapor

/// Recording socket capturing hub frames without a live handshake, so a
/// transport's rejection frame is directly observable.
private actor EgressDecisionRecordingSocket: WSConnectionSocket {
    /// Text frames delivered to this connection.
    private(set) var sent: [String] = []

    /// Records one text frame.
    func send(_ text: String) async throws {
        sent.append(text)
    }

    /// Ignored; the decision path never closes the connection.
    func close(code _: WebSocketErrorCode) async throws {}
}

/// One throwaway verified policy plus the context wired to it.
private struct EgressDecisionHarness {
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

/// Builds an isolated context whose policy file, store, and supervisor are the
/// exact instances the REST and WebSocket handlers read.
///
/// The fallback context supplies the shared turn machinery because these tests
/// exercise the decision handler alone: no boot, no auth, no tool registration.
/// Borrowing it keeps one construction path for lean route tests, while the
/// per-test hub and approval queue keep frames and pending state isolated.
/// - Returns: The harness with its loaded store and live supervisor.
private func makeEgressDecisionHarness() async throws -> EgressDecisionHarness {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("rw-egress-decision-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appendingPathComponent("policy.toml")
    let store = PolicyStore(fileURL: fileURL)
    await store.load()
    let supervisor = try await OutboundEgressSupervisor.make(policyStore: store)
    let base = ServerContext.fallbackUnconfigured
    let context = ServerContext(
        config: .default,
        conversations: base.conversations,
        toolBus: base.toolBus,
        orchestrator: base.orchestrator,
        memoryEngine: base.memoryEngine,
        permissionGate: base.permissionGate,
        approvals: ApprovalQueue(permissionGate: base.permissionGate),
        hub: WSHub(),
        steeringQueue: base.steeringQueue,
        policyStore: store,
        egressSupervisor: supervisor
    )
    return EgressDecisionHarness(context: context, store: store, fileURL: fileURL, directory: directory)
}

/// Enqueues one unlisted `api.request` approval carrying the given host.
///
/// The host is passed explicitly so the guard under test is exercised against
/// a deterministic wildcard shape rather than URL-parser spelling; the
/// extraction test below separately pins the model-argument-to-host chain.
/// A tagged session lets callers prove the `.allowSession` refusal comes from
/// the wildcard guard rather than from the session-less guard beside it.
/// - Parameters:
///   - host: Egress host filed on the pending request.
///   - sessionID: Owning conversation, when the caller needs a session tier.
///   - context: Context owning the approval queue.
/// - Returns: The pending request awaiting a decision.
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
private func waitForEgressFrames(_ socket: EgressDecisionRecordingSocket) async -> [String] {
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

/// Runs one test body against an application serving the full engine routes
/// over the isolated context, shutting the app down on every exit path.
/// - Parameters:
///   - context: Context the routes must serve.
///   - body: Test body receiving the configured app.
/// - Returns: Whatever `body` returns.
private func withEgressRouteApp<T>(
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

/// Runs one approval decision through the real REST route surface.
/// - Parameters:
///   - app: Configured application.
///   - id: Pending approval identifier.
///   - tier: Egress decision tier sent in the JSON body.
/// - Returns: The route response, without binding a socket.
private func decideViaREST(
    app: Application,
    id: UUID,
    tier: EgressDecisionTier
) async throws -> Response {
    let request = Request(
        application: app,
        method: .POST,
        url: URI(string: "/approvals/\(id.uuidString)/decide"),
        on: app.eventLoopGroup.next()
    )
    try request.content.encode(ApprovalDecisionRequest(approved: true, egressDecision: tier))
    return try await app.responder.respond(to: request).get()
}

@Suite("Egress Decision Guard")
struct EgressDecisionGuardTests {
    @Test
    func `Wildcard URL host reaches the approval queue as a wildcard shape`() async throws {
        let harness = try await makeEgressDecisionHarness()
        defer { harness.cleanUp() }

        // The attack chain starts at the model-filled argument, so the
        // extraction must file the star shape the decision guard then refuses.
        let request = await harness.context.approvals.enqueue(
            toolName: "api.request",
            description: "Outbound request.",
            input: ToolInput(toolName: "api.request", argumentsJSON: #"{"url":"https://*.com/"}"#)
        )
        #expect(request.egressHost?.contains("*") == true)
    }

    @Test
    func `Every allow tier refuses wildcard hosts without writing policy`() async throws {
        let harness = try await makeEgressDecisionHarness()
        defer { harness.cleanUp() }
        let before = harness.persistedPolicy()

        // Hostile shapes span leading, trailing, bare, embedded, and
        // port-qualified stars so the guard cannot be bypassed by a spelling
        // that classifies as any non-exact wildcard.
        let hostileHosts = ["*.com", "*.co.uk", "*", "example.*", "api.*.com", "*.com:443"]
        let sessionID = UUID()
        for hostile in hostileHosts {
            let request = await enqueueEgressRequest(host: hostile, sessionID: sessionID, context: harness.context)
            for tier in [EgressDecisionTier.allowOnce, .allowSession, .alwaysAllow] {
                let applied = await applyEgressDecision(tier: tier, pending: request, context: harness.context)
                #expect(applied == false, "\(tier.rawValue) must refuse '\(hostile)'")
            }
            // The approval stays pending so the caller has only deny left.
            #expect(await harness.context.approvals.request(id: request.id) != nil)
        }

        #expect(harness.persistedPolicy() == before)
        #expect(harness.persistedPolicy()?.contains("*") != true)
    }

    @Test
    func `Exact hosts still approve and persist`() async throws {
        let harness = try await makeEgressDecisionHarness()
        defer { harness.cleanUp() }

        let request = await enqueueEgressRequest(host: "api.github.com", context: harness.context)
        let once = await applyEgressDecision(tier: .allowOnce, pending: request, context: harness.context)
        #expect(once == true)
        let persisted = await applyEgressDecision(tier: .alwaysAllow, pending: request, context: harness.context)
        #expect(persisted == true)
        #expect(harness.persistedPolicy()?.contains("api.github.com") == true)
        #expect(try await harness.store.snapshot().network.allowedDomains.contains("api.github.com"))
    }

    @Test
    func `Deny tier applies without egress side effects`() async throws {
        let harness = try await makeEgressDecisionHarness()
        defer { harness.cleanUp() }
        let before = harness.persistedPolicy()

        let request = await enqueueEgressRequest(host: "api.github.com", context: harness.context)
        let applied = await applyEgressDecision(tier: .deny, pending: request, context: harness.context)

        // A one-shot deny is the safe default: the handler reports success so
        // the caller resolves the call as denied, but it must neither grant the
        // host nor record policy, and it leaves resolution to the transport.
        #expect(applied == true)
        #expect(await harness.context.approvals.request(id: request.id) != nil)
        let policy = try await harness.store.snapshot()
        #expect(policy.network.blockedDomains.contains("api.github.com") == false)
        #expect(policy.network.allowedDomains.contains("api.github.com") == false)
        #expect(harness.persistedPolicy() == before)
    }

    @Test
    func `DenyAlways tier appends the blocked domain`() async throws {
        let harness = try await makeEgressDecisionHarness()
        defer { harness.cleanUp() }

        let request = await enqueueEgressRequest(host: "blocked.example.com", context: harness.context)
        let applied = await applyEgressDecision(tier: .denyAlways, pending: request, context: harness.context)

        // A durable deny is the only deny tier with a policy side effect: the
        // blocked entry lets the next identical call auto-deny instead of
        // re-parking, and it must never land on the allow side.
        #expect(applied == true)
        let policy = try await harness.store.snapshot()
        #expect(policy.network.blockedDomains.contains("blocked.example.com"))
        #expect(policy.network.allowedDomains.contains("blocked.example.com") == false)
        #expect(harness.persistedPolicy()?.contains("blocked.example.com") == true)
    }

    @Test
    func `Denied stays denied when the request carries credentials`() async throws {
        let harness = try await makeEgressDecisionHarness()
        defer { harness.cleanUp() }

        // A durable block must hold even for an authenticated call: the
        // network gate runs before any secret handling, so presenting a
        // credential never reopens a denied destination.
        let blocked = await enqueueEgressRequest(host: "blocked.example.com", context: harness.context)
        #expect(await applyEgressDecision(tier: .denyAlways, pending: blocked, context: harness.context) == true)
        let supervisor = try #require(harness.context.egressSupervisor)
        let destination = try #require(URL(string: "https://blocked.example.com/v1/status"))
        let verdict = await supervisor.validate(
            url: destination,
            method: "GET",
            headers: ["Authorization": "Bearer rwsecret:ANY_KEY"]
        )
        switch verdict {
        case .allowed:
            Issue.record("Expected a blocked host to stay denied even with credentials attached")
        case let .denied(reason), let .unlistedDomain(_, reason):
            #expect(reason.lowercased().contains("blocked"))
        }
    }

    @Test
    func `Triage alwaysAllow never adds localExemptions`() async throws {
        let harness = try await makeEgressDecisionHarness()
        defer { harness.cleanUp() }

        // Only PUT and re-check apply may write `localExemptions` (Shared
        // Contract C): triage persists the allow entry alone, even for a
        // local-network literal that classification would otherwise grant.
        let before = try await harness.store.snapshot()
        #expect(before.network.localExemptions.isEmpty)

        let request = await enqueueEgressRequest(host: "192.168.1.10", context: harness.context)
        let applied = await applyEgressDecision(tier: .alwaysAllow, pending: request, context: harness.context)
        #expect(applied == true)

        let policy = try await harness.store.snapshot()
        #expect(policy.network.allowedDomains.contains("192.168.1.10"))
        #expect(policy.network.localExemptions.isEmpty)

        // The store appenders preserve the same boundary directly: an
        // allowlist append rides through with exemptions untouched.
        _ = try await harness.store.appendAllowedDomain("192.168.1.11")
        let appended = try await harness.store.snapshot()
        #expect(appended.network.allowedDomains.contains("192.168.1.11"))
        #expect(appended.network.localExemptions.isEmpty)
    }
}

@Suite("Egress Decision Transports")
struct EgressDecisionTransportTests {
    @Test
    func `REST wildcard allow fails closed and leaves the approval pending`() async throws {
        let harness = try await makeEgressDecisionHarness()
        defer { harness.cleanUp() }
        let before = harness.persistedPolicy()
        let approval = await enqueueEgressRequest(host: "*.com", context: harness.context)

        try await withEgressRouteApp(context: harness.context) { app in
            let response = try await decideViaREST(app: app, id: approval.id, tier: .alwaysAllow)
            #expect(response.status == .unprocessableEntity)
        }

        #expect(await harness.context.approvals.request(id: approval.id) != nil)
        #expect(harness.persistedPolicy() == before)
    }

    @Test
    func `REST exact-host allow still approves and persists`() async throws {
        let harness = try await makeEgressDecisionHarness()
        defer { harness.cleanUp() }
        let approval = await enqueueEgressRequest(host: "api.github.com", context: harness.context)

        try await withEgressRouteApp(context: harness.context) { app in
            let response = try await decideViaREST(app: app, id: approval.id, tier: .alwaysAllow)
            #expect(response.status == .ok)
            let decoded = try response.content.decode(ApprovalDecisionResponse.self)
            #expect(decoded.approved == true)
        }

        #expect(await harness.context.approvals.request(id: approval.id) == nil)
        #expect(harness.persistedPolicy()?.contains("api.github.com") == true)
    }

    @Test
    func `WebSocket wildcard allow fails closed and leaves the approval pending`() async throws {
        let harness = try await makeEgressDecisionHarness()
        defer { harness.cleanUp() }
        let before = harness.persistedPolicy()
        let approval = await enqueueEgressRequest(host: "*.com", context: harness.context)

        let socket = EgressDecisionRecordingSocket()
        let connectionID = UUID()
        _ = await harness.context.hub.add(id: connectionID, box: socket)
        // Drive the real inbound classification plus tier decode so the test
        // covers the WebSocket transport end to end, not only the shared
        // function it dispatches into.
        let frame = #"{"id":"\#(approval.id.uuidString)","approved":true,"egressDecision":"alwaysAllow"}"#
        await handleWebSocketText(
            frame,
            connectionID: connectionID,
            context: harness.context,
            connectionTasks: ConnectionChatTasks()
        )

        #expect(await harness.context.approvals.request(id: approval.id) != nil)
        #expect(harness.persistedPolicy() == before)
        // The requester learns the decision could not be applied instead of
        // the approval silently resolving as approved.
        let frames = await waitForEgressFrames(socket)
        #expect(frames.contains { $0.contains("could not be applied") })
    }

    @Test
    func `REST deny resolves the request as denied without egress side effects`() async throws {
        let harness = try await makeEgressDecisionHarness()
        defer { harness.cleanUp() }
        let before = harness.persistedPolicy()
        let approval = await enqueueEgressRequest(host: "api.github.com", context: harness.context)

        try await withEgressRouteApp(context: harness.context) { app in
            let response = try await decideViaREST(app: app, id: approval.id, tier: .deny)
            #expect(response.status == .ok)
            let decoded = try response.content.decode(ApprovalDecisionResponse.self)
            #expect(decoded.approved == false)
        }

        #expect(await harness.context.approvals.request(id: approval.id) == nil)
        #expect(harness.persistedPolicy() == before)
    }

    @Test
    func `REST denyAlways writes the blocked domain and resolves denied`() async throws {
        let harness = try await makeEgressDecisionHarness()
        defer { harness.cleanUp() }
        let approval = await enqueueEgressRequest(host: "blocked.example.com", context: harness.context)

        try await withEgressRouteApp(context: harness.context) { app in
            let response = try await decideViaREST(app: app, id: approval.id, tier: .denyAlways)
            #expect(response.status == .ok)
            let decoded = try response.content.decode(ApprovalDecisionResponse.self)
            #expect(decoded.approved == false)
        }

        #expect(await harness.context.approvals.request(id: approval.id) == nil)
        let policy = try await harness.store.snapshot()
        #expect(policy.network.blockedDomains.contains("blocked.example.com"))
        #expect(harness.persistedPolicy()?.contains("blocked.example.com") == true)
    }

    @Test
    func `WebSocket deny resolves the request as denied without egress side effects`() async throws {
        let harness = try await makeEgressDecisionHarness()
        defer { harness.cleanUp() }
        let before = harness.persistedPolicy()
        let approval = await enqueueEgressRequest(host: "api.github.com", context: harness.context)

        let socket = EgressDecisionRecordingSocket()
        let connectionID = UUID()
        _ = await harness.context.hub.add(id: connectionID, box: socket)
        // A deny still rides the real inbound classification, so the transport
        // proves the tier decodes and resolves rather than only the shared
        // handler being called directly.
        let frame = #"{"id":"\#(approval.id.uuidString)","approved":true,"egressDecision":"deny"}"#
        await handleWebSocketText(
            frame,
            connectionID: connectionID,
            context: harness.context,
            connectionTasks: ConnectionChatTasks()
        )

        #expect(await harness.context.approvals.request(id: approval.id) == nil)
        #expect(harness.persistedPolicy() == before)
        // A successful deny needs no acknowledgement, and no error frame may
        // arrive: an owned error reads as a terminal turn failure to clients.
        let frames = await socket.sent
        #expect(frames.isEmpty)
    }

    @Test
    func `WebSocket denyAlways writes the blocked domain and resolves denied`() async throws {
        let harness = try await makeEgressDecisionHarness()
        defer { harness.cleanUp() }
        let approval = await enqueueEgressRequest(host: "blocked.example.com", context: harness.context)

        let socket = EgressDecisionRecordingSocket()
        let connectionID = UUID()
        _ = await harness.context.hub.add(id: connectionID, box: socket)
        let frame = #"{"id":"\#(approval.id.uuidString)","approved":true,"egressDecision":"denyAlways"}"#
        await handleWebSocketText(
            frame,
            connectionID: connectionID,
            context: harness.context,
            connectionTasks: ConnectionChatTasks()
        )

        #expect(await harness.context.approvals.request(id: approval.id) == nil)
        let policy = try await harness.store.snapshot()
        #expect(policy.network.blockedDomains.contains("blocked.example.com"))
        #expect(harness.persistedPolicy()?.contains("blocked.example.com") == true)
        // The durable block changes the grants surface, so connected clients
        // receive the same refresh signal the REST path emits.
        let frames = await waitForEgressFrames(socket)
        #expect(frames.contains { $0.contains("trust_grants_changed") })
    }
}

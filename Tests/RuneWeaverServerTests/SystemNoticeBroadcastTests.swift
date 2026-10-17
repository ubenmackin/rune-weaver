// Rune Weaver Tests — System-notice filing broadcast, settlement broadcast, and decide refusal.

import Foundation
import NIOWebSocket
import RuneWeaverCore
@testable import RuneWeaverServer
import Testing
import Vapor

/// Recording socket capturing hub frames without a live handshake, so filing
/// and settlement broadcasts are directly observable.
private actor NoticeRecordingSocket: WSConnectionSocket {
    /// Text frames delivered to this connection, in send order.
    private(set) var sent: [String] = []

    /// Records one frame.
    func send(_ text: String) async throws {
        sent.append(text)
    }

    /// Ignored; these tests never close the connection.
    func close(code _: WebSocketErrorCode) async throws {}
}

/// Decoded approval prompt envelope carried by a filing broadcast.
private struct RecordedApprovalPrompt: Decodable {
    /// Always `"approval"`.
    let type: String
    /// The newly filed request.
    let request: PermissionRequest
}

/// Decoded decision-settlement envelope.
private struct RecordedDecidedFrame: Decodable {
    /// Always `"approval_decided"`.
    let type: String
    /// Resolved request identifier.
    let id: UUID
    /// Effective approval verdict.
    let approved: Bool
}

/// Decoded error envelope for a refused decision frame.
private struct RecordedErrorFrame: Decodable {
    /// Always `"error"`.
    let type: String
    /// Human-readable refusal.
    let message: String
}

/// Signer standing in for an unavailable signing key so the ceremony refuses
/// fail-closed into the notice-filing path.
private struct UnavailableSigner: SovereignSigner {
    let identity = "runeweaver-test-unavailable-signer"

    func preloadIfNeeded() async throws {
        throw SovereignLedgerError.signingKeyUnavailable(reason: "test signing key unavailable")
    }

    func sign(challenge _: String) async throws -> String {
        throw SovereignLedgerError.signingKeyUnavailable(reason: "test signing key unavailable")
    }

    func verify(challenge _: String, signature _: String) async -> Bool {
        false
    }
}

/// Builds a ledger over a throwaway scratch tree whose signer always fails,
/// so every ceremony takes the unverifiable-artifact path.
private func makeFailingLedger() throws -> (ledger: SovereignLedger, scratch: URL) {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("rw-notice-ledger-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    let ledger = SovereignLedger(
        episodeStore: EpisodeStore(dbPath: scratch.appendingPathComponent("episodes.db").path),
        sovereignCopyPath: scratch.appendingPathComponent("ledger.sovereign.jsonl").path,
        checkpointPath: scratch.appendingPathComponent("sovereign-checkpoint.json").path,
        signer: UnavailableSigner(),
        secrets: SecretsManager(service: "com.runeweaver.test.notice.\(UUID().uuidString)", inMemory: true),
        now: { Date(timeIntervalSince1970: 1_700_000_000) }
    )
    return (ledger, scratch)
}

/// Minimal context wired to an in-memory gate so the decide routes run
/// against a live approval queue with no network stack.
private func makeNoticeDecisionContext() -> ServerContext {
    let base = ServerContext.fallbackUnconfigured
    let gate = PermissionGate(ruleStore: InMemoryAccessRuleStore())
    return ServerContext(
        config: .default,
        conversations: base.conversations,
        toolBus: base.toolBus,
        orchestrator: base.orchestrator,
        memoryEngine: base.memoryEngine,
        permissionGate: gate,
        approvals: ApprovalQueue(permissionGate: gate),
        hub: WSHub(),
        steeringQueue: base.steeringQueue
    )
}

/// Runs one test body against an application serving the engine routes over
/// the isolated context, shutting the app down on every exit path.
private func withNoticeRouteApp<T>(
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

/// Files one system notice through the atomic dedup entry the filing sites use.
private func fileNotice(
    _ toolName: String,
    description: String,
    context: ServerContext
) async -> PermissionRequest? {
    await context.approvals.enqueueSystemNoticeIfAbsent(toolName: toolName, description: description)
}

@Suite("System Notice Filing Broadcast")
struct SystemNoticeFilingBroadcastTests {
    @Test
    func `failing ceremony files one notice and broadcasts it live`() async throws {
        let (ledger, scratch) = try makeFailingLedger()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let hub = WSHub()
        let socket = NoticeRecordingSocket()
        _ = await hub.add(id: UUID(), box: socket)
        let approvals = ApprovalQueue()
        // Production wiring: the filed frame leaves through the queue's insert-hop hook, so the
        // ceremony path carries no caller-side broadcast of its own.
        await approvals.setOnNoticeFiled { request in
            await hub.broadcastApproval(request)
        }
        let sink = SovereignCeremonySink(
            pulse: SystemHealthSnapshot(),
            hub: hub,
            lastServed: HealthPulseLastServed(),
            ledger: ledger,
            approvals: approvals,
            decisionLog: InMemoryApprovalDecisionLog()
        )

        _ = await runSovereignCeremony(sink: sink, reason: "test")

        // The unverifiable ceremony parks exactly one surfacing-only notice.
        let pending = await approvals.list()
        try #require(pending.count == 1)
        #expect(pending[0].toolName == "sovereign.mismatch")
        // The filing reached the live dashboard as an approval prompt frame
        // carrying the filed request, so no refresh control is needed.
        let frames = await socket.sent
        let prompts = frames.map { raw -> RecordedApprovalPrompt? in
            guard let data = raw.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(RecordedApprovalPrompt.self, from: data)
        }.compactMap(\.self)
        try #require(prompts.count == 1)
        #expect(prompts[0].type == "approval")
        #expect(prompts[0].request.id == pending[0].id)
        #expect(prompts[0].request.toolName == "sovereign.mismatch")
    }

    @Test
    func `a second failing ceremony dedups instead of double-parking or rebroadcasting`() async throws {
        let (ledger, scratch) = try makeFailingLedger()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let hub = WSHub()
        let socket = NoticeRecordingSocket()
        _ = await hub.add(id: UUID(), box: socket)
        let approvals = ApprovalQueue()
        await approvals.setOnNoticeFiled { request in
            await hub.broadcastApproval(request)
        }
        let sink = SovereignCeremonySink(
            pulse: SystemHealthSnapshot(),
            hub: hub,
            lastServed: HealthPulseLastServed(),
            ledger: ledger,
            approvals: approvals,
            decisionLog: InMemoryApprovalDecisionLog()
        )
        _ = await runSovereignCeremony(sink: sink, reason: "test")

        // A changed failure reason updates nothing until the notice resolves.
        _ = await runSovereignCeremony(sink: sink, reason: "test-again")

        let pending = await approvals.list()
        #expect(pending.count == 1)
        let prompts = await socket.sent.compactMap { raw -> RecordedApprovalPrompt? in
            guard let data = raw.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(RecordedApprovalPrompt.self, from: data)
        }
        #expect(prompts.count == 1)
    }
}

@Suite("System Notice Settlement")
struct SystemNoticeSettlementTests {
    @Test
    func `settlement broadcasts one decided frame per item and records one settled row`() async throws {
        let hub = WSHub()
        let socket = NoticeRecordingSocket()
        _ = await hub.add(id: UUID(), box: socket)
        let approvals = ApprovalQueue()
        let log = InMemoryApprovalDecisionLog()
        let notice = try #require(
            await approvals.enqueueSystemNoticeIfAbsent(
                toolName: "sovereign.mismatch",
                description: "Sovereign ceremony could not verify history."
            )
        )
        let ordinary = await approvals.enqueue(
            toolName: "files.write",
            description: "Ordinary approval.",
            input: ToolInput(toolName: "files.write", argumentsJSON: "{}")
        )

        let note = "Sovereign ceremony (test) recovered: verified at tip-abc."
        await settleSystemNotice(
            toolName: "sovereign.mismatch",
            note: note,
            approvals: approvals,
            hub: hub,
            decisionLog: log
        )

        // Only the notice resolved; the ordinary approval stays parked.
        #expect(await approvals.request(id: notice.id) == nil)
        #expect(await approvals.request(id: ordinary.id) != nil)
        // One approval_decided frame through the same publish path the decide
        // route uses, carrying the settled notice id.
        let frames = await socket.sent
        let decided = frames.map { raw -> RecordedDecidedFrame? in
            guard let data = raw.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(RecordedDecidedFrame.self, from: data)
        }.compactMap(\.self)
        try #require(decided.count == 1)
        #expect(decided[0].type == "approval_decided")
        #expect(decided[0].id == notice.id)
        #expect(decided[0].approved == true)
        // The recovery note rides the settled history row's display target.
        let entries = try await log.list(limit: 10, offset: 0)
        try #require(entries.count == 1)
        #expect(entries[0].toolName == "sovereign.mismatch")
        #expect(entries[0].surface == "settled")
        #expect(entries[0].allowed == true)
        #expect(entries[0].displayTarget == note)
    }

    @Test
    func `settlement with nothing parked broadcasts and records nothing`() async throws {
        let hub = WSHub()
        let socket = NoticeRecordingSocket()
        _ = await hub.add(id: UUID(), box: socket)
        let approvals = ApprovalQueue()
        let log = InMemoryApprovalDecisionLog()

        await settleSystemNotice(
            toolName: "sovereign.mismatch",
            note: "Unobserved recovery.",
            approvals: approvals,
            hub: hub,
            decisionLog: log
        )

        #expect(await socket.sent.isEmpty)
        #expect(try await log.list(limit: 10, offset: 0).isEmpty)
    }
}

@Suite("System Notice Decide Refusal")
struct SystemNoticeDecideRefusalTests {
    @Test
    func `REST decide refuses a notice id with bad request and leaves it parked`() async throws {
        let context = makeNoticeDecisionContext()
        let notice = try #require(await fileNotice(
            "security.probe",
            description: "Security probes failed fail-closed.",
            context: context
        ))
        try await withNoticeRouteApp(context: context) { app in
            let request = Request(
                application: app,
                method: .POST,
                url: URI(string: "/approvals/\(notice.id.uuidString)/decide"),
                on: app.eventLoopGroup.next()
            )
            try request.content.encode(RestNoticeDecisionBody(approved: true, duration: TrustDuration.forever.rawValue))
            let response = try await app.responder.respond(to: request).get()
            // The shared contract refuses rather than resolving the park or
            // minting durable trust on a surfacing-only notice.
            #expect(response.status == .badRequest)
        }
        #expect(await context.approvals.request(id: notice.id) != nil)
        #expect(await context.permissionGate.activeRules().isEmpty)
    }

    @Test
    func `WebSocket triage refuses a notice id with an error frame and leaves it parked`() async throws {
        let context = makeNoticeDecisionContext()
        let notice = try #require(await fileNotice(
            "sovereign.mismatch",
            description: "Sovereign ceremony could not verify history.",
            context: context
        ))
        // The refusal is requester-scoped, so the recording socket must ride
        // the same connection id the triage answers.
        let socket = NoticeRecordingSocket()
        let connectionID = UUID()
        _ = await context.hub.add(id: connectionID, box: socket)

        await handleWebSocketText(
            #"{"id":"\#(notice.id.uuidString)","approved":true,"duration":"forever"}"#,
            connectionID: connectionID,
            context: context,
            connectionTasks: ConnectionChatTasks()
        )

        // The requester learns the refusal instead of a silent no-op.
        let frames = await socket.sent
        let errors = frames.map { raw -> RecordedErrorFrame? in
            guard let data = raw.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(RecordedErrorFrame.self, from: data)
        }.compactMap(\.self)
        try #require(errors.count == 1)
        #expect(errors[0].type == "error")
        #expect(errors[0].message.contains("mapped remedy"))
        #expect(await context.approvals.request(id: notice.id) != nil)
        #expect(await context.permissionGate.activeRules().isEmpty)
    }
}

/// Wire body the refusal tests carry, mirroring the unified decision contract.
private struct RestNoticeDecisionBody: Content {
    /// Approval polarity.
    let approved: Bool
    /// Requested trust tier raw value.
    let duration: String
}

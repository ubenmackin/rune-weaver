// Rune Weaver Tests — Approval decision history recording and routes.
//
// Purpose: pin the shared decision audit trail. Every resolved decision lands
// exactly once through the decision contract with its surface tag, while
// unresolved decisions record nothing and a failing store never fails the
// response.
// Scope: REST decide and respond recording, WebSocket triage tagging, and the
// history list plus clear routes. Scope canonicalization and tier mapping stay
// with their own suites.
// Architectural role: regression coverage for the audit side of the single
// decision contract, so a transport edit cannot silently drop history.

import Foundation
import RuneWeaverCore
@testable import RuneWeaverServer
import RuneWeaverTools
import Testing
import Vapor

/// Isolated context plus its decision log for history tests.
private struct HistoryHarness {
    let context: ServerContext
    let log: InMemoryApprovalDecisionLog
    let directory: URL

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func makeHistoryHarness(wiredSupervisor: Bool = true) async throws -> HistoryHarness {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("rw-history-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = PolicyStore(fileURL: directory.appendingPathComponent("policy.toml"))
    await store.load()
    let madeSupervisor = try? await OutboundEgressSupervisor.make(policyStore: store)
    let supervisor = wiredSupervisor ? madeSupervisor : nil
    let base = ServerContext.fallbackUnconfigured
    let gate = PermissionGate(ruleStore: InMemoryAccessRuleStore())
    let log = InMemoryApprovalDecisionLog()
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
        egressSupervisor: supervisor,
        approvalDecisions: log
    )
    if let supervisor {
        await gate.setEgressEvaluator(supervisor)
        await supervisor.setPermissionGate(gate)
    }
    return HistoryHarness(context: context, log: log, directory: directory)
}

private func withHistoryRouteApp<T>(
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

private func historyRequest(app: Application, method: HTTPMethod, url: String) -> Request {
    Request(application: app, method: method, url: URI(string: url), on: app.eventLoopGroup.next())
}

private func decideViaHistoryREST(
    app: Application,
    id: UUID,
    approved: Bool,
    duration: TrustDuration,
    surface: String? = nil,
    scope: AccessScopeDTO? = nil
) async throws -> Response {
    let request = historyRequest(app: app, method: .POST, url: "/approvals/\(id.uuidString)/decide")
    try request.content.encode(ApprovalDecisionRequest(
        approved: approved,
        duration: duration,
        scope: scope,
        surface: surface
    ))
    return try await app.responder.respond(to: request).get()
}

private func respondViaHistoryREST(
    app: Application,
    id: UUID,
    answer: String? = nil,
    cancelled: Bool? = nil
) async throws -> Response {
    let request = historyRequest(app: app, method: .POST, url: "/approvals/\(id.uuidString)/respond")
    try request.content.encode(QuestionResponseRequest(answer: answer, cancelled: cancelled))
    return try await app.responder.respond(to: request).get()
}

private func getHistory(app: Application, query: String = "") async throws -> Response {
    try await app.responder.respond(
        to: historyRequest(app: app, method: .GET, url: "/approvals/history\(query)")
    ).get()
}

/// True when the logged row and the pending request name the same display
/// target, or when neither names one.
private func displayTargetsMatch(_ logged: String?, _ pending: String?) -> Bool {
    switch (logged, pending) {
    case (nil, nil): true
    case let (a?, b?): a == b
    default: false
    }
}

@Suite("Approval Decision History")
struct ServerApprovalHistoryTests {
    @Test
    func `REST decide records one row with the surface tag`() async throws {
        let harness = try await makeHistoryHarness()
        defer { harness.cleanUp() }
        let sessionID = UUID()
        let pending = await harness.context.approvals.enqueue(
            toolName: "files.write",
            description: "Write notes.",
            input: ToolInput(toolName: "files.write", argumentsJSON: #"{"path":"/tmp/notes.md"}"#),
            sessionID: sessionID
        )

        try await withHistoryRouteApp(context: harness.context) { app in
            let response = try await decideViaHistoryREST(
                app: app,
                id: pending.id,
                approved: true,
                duration: .thisTime,
                surface: "inbox",
                scope: AccessScopeDTO(kind: .tool)
            )
            #expect(response.status == .ok)
        }

        let entries = try await harness.log.list(limit: 10, offset: 0)
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.toolName == "files.write")
        #expect(entry.allowed == true)
        #expect(entry.duration == TrustDuration.thisTime.rawValue)
        #expect(entry.surface == "inbox")
        #expect(entry.sessionID == sessionID.uuidString)
        #expect(displayTargetsMatch(
            entry.displayTarget,
            pending.displayTarget
        ))
        #expect(entry.scopeKind == "toolWide")
        #expect(entry.scopeData == "tool")
    }

    @Test
    func `denied and durable decisions record polarity plus tier`() async throws {
        let harness = try await makeHistoryHarness()
        defer { harness.cleanUp() }
        let denied = await harness.context.approvals.enqueue(
            toolName: "files.write",
            description: "Write notes.",
            input: ToolInput(toolName: "files.write", argumentsJSON: #"{"path":"/tmp/notes.md"}"#)
        )
        let durable = await harness.context.approvals.enqueue(
            toolName: "files.write",
            description: "Write report.",
            input: ToolInput(toolName: "files.write", argumentsJSON: #"{"path":"/tmp/report.md"}"#)
        )

        try await withHistoryRouteApp(context: harness.context) { app in
            let deniedResponse = try await decideViaHistoryREST(
                app: app, id: denied.id, approved: false, duration: .thisTime
            )
            #expect(deniedResponse.status == .ok)
            let durableResponse = try await decideViaHistoryREST(
                app: app, id: durable.id, approved: true, duration: .forever
            )
            #expect(durableResponse.status == .ok)
        }

        let entries = try await harness.log.list(limit: 10, offset: 0)
        #expect(entries.count == 2)
        let deniedEntry = try #require(entries.first { $0.toolName == "files.write" && !$0.allowed })
        #expect(deniedEntry.duration == TrustDuration.thisTime.rawValue)
        #expect(deniedEntry.surface == "unknown")
        let durableEntry = try #require(entries.first { $0.allowed })
        #expect(durableEntry.duration == TrustDuration.forever.rawValue)
    }

    @Test
    func `egress decision records the dialed domain scope`() async throws {
        let harness = try await makeHistoryHarness()
        defer { harness.cleanUp() }
        let sessionID = UUID()
        let pending = PermissionRequest(
            toolName: "api.request",
            description: "Outbound request.",
            input: ToolInput(toolName: "api.request", argumentsJSON: "{}"),
            sessionID: sessionID,
            egressHost: "api.github.com"
        )
        await harness.context.approvals.enqueue(pending)

        try await withHistoryRouteApp(context: harness.context) { app in
            let response = try await decideViaHistoryREST(
                app: app, id: pending.id, approved: true, duration: .thisTime, surface: "dashboard"
            )
            #expect(response.status == .ok)
        }

        let entries = try await harness.log.list(limit: 10, offset: 0)
        let entry = try #require(entries.first)
        #expect(entry.scopeKind == "domain")
        #expect(entry.scopeData == "api.github.com")
        #expect(entry.surface == "dashboard")
    }

    @Test
    func `failed and unknown decisions record nothing`() async throws {
        let harness = try await makeHistoryHarness()
        defer { harness.cleanUp() }
        let hostile = PermissionRequest(
            toolName: "api.request",
            description: "Outbound request.",
            input: ToolInput(toolName: "api.request", argumentsJSON: "{}"),
            egressHost: "*.com"
        )
        await harness.context.approvals.enqueue(hostile)

        try await withHistoryRouteApp(context: harness.context) { app in
            let hostileResponse = try await decideViaHistoryREST(
                app: app, id: hostile.id, approved: true, duration: .forever
            )
            #expect(hostileResponse.status == .unprocessableEntity)
            let unknownResponse = try await decideViaHistoryREST(
                app: app, id: UUID(), approved: true, duration: .thisTime
            )
            #expect(unknownResponse.status == .notFound)
        }
        #expect(try await harness.log.count() == 0)
    }

    @Test
    func `question response records a one-shot question row`() async throws {
        let harness = try await makeHistoryHarness()
        defer { harness.cleanUp() }
        let sessionID = UUID()
        let pending = await harness.context.approvals.enqueue(
            toolName: "question.ask",
            description: "Which one?",
            input: ToolInput(toolName: "question.ask", argumentsJSON: #"{"question":"Pick one"}"#),
            sessionID: sessionID
        )

        try await withHistoryRouteApp(context: harness.context) { app in
            let response = try await respondViaHistoryREST(app: app, id: pending.id, answer: "The first")
            #expect(response.status == .ok)
        }

        let entries = try await harness.log.list(limit: 10, offset: 0)
        let entry = try #require(entries.first)
        #expect(entry.toolName == "question.ask")
        #expect(entry.allowed == true)
        #expect(entry.duration == TrustDuration.thisTime.rawValue)
        #expect(entry.surface == "question")
        #expect(entry.sessionID == sessionID.uuidString)
        #expect(entry.scopeKind == nil)
    }

    @Test
    func `an off-vocabulary decide surface tag records unknown`() async throws {
        let harness = try await makeHistoryHarness()
        defer { harness.cleanUp() }
        let hostile = await harness.context.approvals.enqueue(
            toolName: "files.write",
            description: "Write notes.",
            input: ToolInput(toolName: "files.write", argumentsJSON: #"{"path":"/tmp/notes.md"}"#)
        )
        let overLong = await harness.context.approvals.enqueue(
            toolName: "files.write",
            description: "Write report.",
            input: ToolInput(toolName: "files.write", argumentsJSON: #"{"path":"/tmp/report.md"}"#)
        )

        try await withHistoryRouteApp(context: harness.context) { app in
            let hostileResponse = try await decideViaHistoryREST(
                app: app,
                id: hostile.id,
                approved: true,
                duration: .thisTime,
                // A hostile or drifted client can send any string in the
                // surface field; the decide entry boundary normalizes it to
                // the closed vocabulary so the durable surface column only
                // ever carries a documented value, without failing the
                // decision the row tags.
                surface: "hacker"
            )
            #expect(hostileResponse.status == .ok)
            let overLongResponse = try await decideViaHistoryREST(
                app: app,
                id: overLong.id,
                approved: true,
                duration: .thisTime,
                surface: String(repeating: "chat-", count: 20)
            )
            #expect(overLongResponse.status == .ok)
        }

        let entries = try await harness.log.list(limit: 10, offset: 0)
        #expect(entries.count == 2)
        for entry in entries {
            #expect(entry.surface == "unknown")
        }
    }

    @Test
    func `WebSocket triage records the websocket surface`() async throws {
        let harness = try await makeHistoryHarness()
        defer { harness.cleanUp() }
        let pending = await harness.context.approvals.enqueue(
            toolName: "files.write",
            description: "Write notes.",
            input: ToolInput(toolName: "files.write", argumentsJSON: #"{"path":"/tmp/notes.md"}"#)
        )

        let frame = #"{"id":"\#(pending.id.uuidString)","approved":true,"duration":"thisTime"}"#
        await handleWebSocketText(
            frame,
            connectionID: UUID(),
            context: harness.context,
            connectionTasks: ConnectionChatTasks()
        )

        let entries = try await harness.log.list(limit: 10, offset: 0)
        let entry = try #require(entries.first)
        #expect(entry.surface == "websocket")
        #expect(entry.allowed == true)
    }

    @Test
    func `history lists newest first with tool and action filters`() async throws {
        let harness = try await makeHistoryHarness()
        defer { harness.cleanUp() }
        let base = Date()
        await harness.log.append(ApprovalDecisionEntry(
            toolName: "files.write", allowed: true, duration: "thisTime",
            surface: "inbox", decidedAt: base
        ))
        await harness.log.append(ApprovalDecisionEntry(
            toolName: "api.request", allowed: false, duration: "thisTime",
            surface: "dashboard", decidedAt: base.addingTimeInterval(1)
        ))
        await harness.log.append(ApprovalDecisionEntry(
            toolName: "files.write", allowed: false, duration: "forever",
            surface: "inbox", decidedAt: base.addingTimeInterval(2)
        ))

        try await withHistoryRouteApp(context: harness.context) { app in
            let page = try await getHistory(app: app, query: "?limit=1").content
                .decode(ApprovalHistoryResponse.self)
            #expect(page.entries.count == 1)
            #expect(page.count == 3)
            #expect(page.entries.first?.toolName == "files.write")
            #expect(page.entries.first?.duration == "forever")

            let byTool = try await getHistory(app: app, query: "?tool=api.request").content
                .decode(ApprovalHistoryResponse.self)
            #expect(byTool.count == 1)
            #expect(byTool.entries.first?.surface == "dashboard")

            let denied = try await getHistory(app: app, query: "?action=denied").content
                .decode(ApprovalHistoryResponse.self)
            #expect(denied.count == 2)

            let allowed = try await getHistory(app: app, query: "?action=allowed&tool=files.write").content
                .decode(ApprovalHistoryResponse.self)
            #expect(allowed.count == 1)

            #expect(try await getHistory(app: app, query: "?action=sometimes").status == .badRequest)
        }
    }

    @Test
    func `history filters ride the store query beyond one page`() async throws {
        let harness = try await makeHistoryHarness()
        defer { harness.cleanUp() }
        // A SQLite-backed log with more matching rows than one page holds:
        // the tool/action predicates must ride the store's WHERE, so the page
        // slices the filtered set and the count reports the filtered total —
        // not a post-fetch slice of an unbounded window.
        let store = ApprovalDecisionLogStore(
            dbPath: harness.directory.appendingPathComponent("episodes.db").path
        )
        let base = Date()
        for index in 0 ..< 10 {
            await store.append(ApprovalDecisionEntry(
                toolName: index.isMultiple(of: 2) ? "files.write" : "api.request",
                allowed: !index.isMultiple(of: 3),
                duration: "thisTime",
                surface: "inbox",
                decidedAt: base.addingTimeInterval(Double(index))
            ))
        }
        let baseContext = ServerContext.fallbackUnconfigured
        let gate = PermissionGate(ruleStore: InMemoryAccessRuleStore())
        let context = ServerContext(
            config: .default,
            conversations: baseContext.conversations,
            toolBus: baseContext.toolBus,
            orchestrator: baseContext.orchestrator,
            memoryEngine: baseContext.memoryEngine,
            permissionGate: gate,
            approvals: ApprovalQueue(permissionGate: gate),
            hub: WSHub(),
            steeringQueue: baseContext.steeringQueue,
            approvalDecisions: store
        )

        try await withHistoryRouteApp(context: context) { app in
            // Denied rows sit exactly at indexes 0, 3, 6, 9; a two-row page
            // holds the newest two (9 then 6) while the count reports all
            // four — rows outside the predicate never occupy page slots.
            let denied = try await getHistory(app: app, query: "?action=denied&limit=2").content
                .decode(ApprovalHistoryResponse.self)
            #expect(denied.count == 4)
            #expect(denied.entries.map(\.toolName) == ["api.request", "files.write"])
            #expect(denied.entries.map(\.allowed).allSatisfy { !$0 })

            // The tool predicate excludes the oldest row (index 0) rather
            // than letting it fill the page; the count is the filtered total.
            let byTool = try await getHistory(app: app, query: "?tool=files.write&limit=3").content
                .decode(ApprovalHistoryResponse.self)
            #expect(byTool.count == 5)
            #expect(byTool.entries.count == 3)
            #expect(byTool.entries.map(\.toolName).allSatisfy { $0 == "files.write" })

            // Both predicates compose in the single store query.
            let combined = try await getHistory(app: app, query: "?tool=files.write&action=denied").content
                .decode(ApprovalHistoryResponse.self)
            #expect(combined.count == 2)
            #expect(combined.entries.map(\.toolName).allSatisfy { $0 == "files.write" })
            #expect(combined.entries.map(\.allowed).allSatisfy { !$0 })
        }
    }

    @Test
    func `clearing history leaves an empty listing`() async throws {
        let harness = try await makeHistoryHarness()
        defer { harness.cleanUp() }
        await harness.log.append(ApprovalDecisionEntry(
            toolName: "files.write", allowed: true, duration: "thisTime", surface: "inbox"
        ))

        try await withHistoryRouteApp(context: harness.context) { app in
            let deleted = try await app.responder.respond(
                to: historyRequest(app: app, method: .DELETE, url: "/approvals/history")
            ).get()
            #expect(deleted.status == .noContent)
            let empty = try await getHistory(app: app).content.decode(ApprovalHistoryResponse.self)
            #expect(empty.entries.isEmpty)
            #expect(empty.count == 0)
        }
    }

    @Test
    func `an unwritable store still answers the decide`() async throws {
        let harness = try await makeHistoryHarness()
        defer { harness.cleanUp() }
        // A store path under a missing directory drops writes with a log, so
        // the decision resolves even though nothing persists.
        let dropping = ApprovalDecisionLogStore(
            dbPath: harness.directory.appendingPathComponent("missing/episodes.db").path
        )
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
            approvalDecisions: dropping
        )
        let pending = await context.approvals.enqueue(
            toolName: "files.write",
            description: "Write notes.",
            input: ToolInput(toolName: "files.write", argumentsJSON: #"{"path":"/tmp/notes.md"}"#)
        )

        try await withHistoryRouteApp(context: context) { app in
            let response = try await decideViaHistoryREST(
                app: app, id: pending.id, approved: true, duration: .thisTime
            )
            #expect(response.status == .ok)
        }
    }
}

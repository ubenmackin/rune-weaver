// Rune Weaver Tests — Access-rules REST surface plus session trust and files settings merge.
//
// Purpose: pin the rules surface the dashboards drive — listing allows and
// denies newest-first with their counters and display scopes, revoking,
// minting a standing allow or deny, widening, re-arming, reading one session's
// ephemeral trust beside the egress supervisor's grants, and clearing that
// trust — plus the `[files] write_path_rules` merge and bounds the settings PUT
// shares with the config document.
// Scope: route status codes, DTO shapes, and the live-apply wiring; rule
// evaluation, deny-outranks ordering, and expiry math stay with the Core
// suites, and the decision mapping itself stays with `EgressDecisionTests`.
// Architectural role: guards the surface that turns one owner decision into a
// durable rule, so a route edit cannot store a half-described rule, answer
// "unknown" for a listed rule, or persist a policy the config loader would
// refuse.

import Foundation
import NIOWebSocket
import RuneWeaverCore
@testable import RuneWeaverServer
import RuneWeaverTools
import Testing
import Vapor

/// One throwaway context serving the approval routes under test.
private struct AccessRulesHarness {
    /// Context whose gate, hub, and supervisor the routes read.
    let context: ServerContext
    /// The one policy store the routes read and write.
    let store: PolicyStore
    /// Throwaway directory removed at test end.
    let directory: URL

    /// Removes the throwaway directory.
    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Builds an isolated context whose gate, policy store, and supervisor are the
/// exact instances the routes read.
///
/// The fallback context supplies the shared turn machinery because these tests
/// exercise the routes alone: no boot, no auth, no tool registration.
/// - Returns: The harness with a loaded store and live supervisor.
private func makeAccessRulesHarness() async throws -> AccessRulesHarness {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("rw-access-rules-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appendingPathComponent("policy.toml")
    let store = PolicyStore(fileURL: fileURL)
    await store.load()
    let supervisor = try? await OutboundEgressSupervisor.make(policyStore: store)
    let base = ServerContext.fallbackUnconfigured
    let gate = PermissionGate()
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
    return AccessRulesHarness(context: context, store: store, directory: directory)
}

/// Runs one test body against an application serving the full engine routes
/// over the isolated context, shutting the app down on every exit path.
/// - Parameters:
///   - context: Context the routes must serve.
///   - body: Test body receiving the configured app.
/// - Returns: Whatever `body` returns.
private func withAccessRulesApp<T>(
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

/// Performs one route call and returns its response.
/// - Parameters:
///   - app: Configured application.
///   - method: HTTP method.
///   - path: Request path.
///   - body: Content body, when the request carries one.
/// - Returns: The route response.
private func accessRulesCall(
    app: Application,
    method: HTTPMethod,
    path: String,
    body: (some Content)?
) async throws -> Response {
    let request = Request(
        application: app,
        method: method,
        url: URI(string: path),
        on: app.eventLoopGroup.next()
    )
    if let body {
        try request.content.encode(body)
    }
    return try await app.responder.respond(to: request).get()
}

/// Sends a body-less request through the configured access rules routes.
private func accessRulesCall(
    app: Application,
    method: HTTPMethod,
    path: String
) async throws -> Response {
    struct Empty: Content {}
    return try await accessRulesCall(app: app, method: method, path: path, body: Empty?.none)
}

/// Posts one rule body so a payload the decoder refuses is observable.
/// - Parameters:
///   - app: Configured application.
///   - body: Body to encode.
/// - Returns: The route response.
private func postRuleBody(app: Application, body: some Content) async throws -> Response {
    let request = Request(
        application: app,
        method: .POST,
        url: URI(string: "/approvals/rules"),
        on: app.eventLoopGroup.next()
    )
    try request.content.encode(body)
    return try await app.responder.respond(to: request).get()
}

/// Wire-shaped rule body the malformed-scope tests submit.
///
/// The fields travel as plain strings so the engine's decoders, not the test
/// double, decide which scopes are canonical: an unknown kind, a wildcard
/// host, or a one-shot tier must fail at the route boundary.
private struct RawScopeRuleBody: Content {
    /// Tool the rule would cover.
    let toolName: String
    /// Unvalidated scope envelope.
    let scope: [String: String]
    /// Action the rule would carry.
    let action: String
    /// Lifetime tier the rule would carry.
    let duration: String
}

/// Seeds one allow rule and one deny rule on the harness gate.
/// - Parameter harness: Harness whose gate receives the rules.
/// - Returns: The seeded allow rule's identifier.
@discardableResult
private func seedRules(_ harness: AccessRulesHarness) async -> UUID {
    #expect(await harness.context.permissionGate.grant(
        .exactTarget("alice@example.com"),
        toolName: "email.send",
        duration: .forever
    ))
    await harness.context.permissionGate.denyRule(
        .glob("rm *"),
        toolName: "bash.exec",
        reason: "owner refuses removals"
    )
    guard let allow = await harness.context.permissionGate.activeRules().first(where: {
        $0.action == .allow
    }) else {
        return UUID()
    }
    return allow.id
}

@Suite("Access Rules Live Routes")
struct AccessRulesRouteLiveTests {
    @Test
    func `GET lists allows and denies newest first with counters and display scopes`() async throws {
        let harness = try await makeAccessRulesHarness()
        defer { harness.cleanUp() }
        await seedRules(harness)
        // One exercised use proves the counters reach the wire.
        await harness.context.permissionGate.recordUse(scope: .exactTarget("alice@example.com"), toolName: "email.send")

        try await withAccessRulesApp(context: harness.context) { app in
            let response = try await accessRulesCall(app: app, method: .GET, path: "/approvals/rules")
            #expect(response.status == .ok)
            let body = try response.content.decode(AccessRulesResponse.self)
            #expect(body.count == 2)
            #expect(body.rules.count == 2)

            guard let allow = body.rules.first(where: { $0.action == .allow }) else {
                Issue.record("Expected the allow rule in the list")
                return
            }
            #expect(allow.toolName == "email.send")
            #expect(allow.scope == AccessScopeDTO(kind: .exactTarget, target: "alice@example.com"))
            #expect(allow.action == .allow)
            #expect(allow.duration == .forever)
            #expect(allow.expiresAt == nil)
            #expect(allow.displayScope == "target 'alice@example.com'")
            #expect(allow.useCount == 1)
            #expect(allow.lastUsedAt != nil)

            guard let deny = body.rules.first(where: { $0.action == .deny }) else {
                Issue.record("Expected the deny rule in the list")
                return
            }
            #expect(deny.toolName == "bash.exec")
            #expect(deny.scope == AccessScopeDTO(kind: .glob, pattern: "rm *"))
            #expect(deny.duration == nil)
            #expect(deny.expiresAt == nil)
            #expect(deny.displayScope == "command pattern rm *")
            #expect(deny.reason == "owner refuses removals")

            // Newest first, so a freshly minted row leads the list.
            let dates = body.rules.map(\.grantedAt)
            #expect(dates == dates.sorted(by: >))
        }
    }

    @Test
    func `DELETE unknown rule reports notFound`() async throws {
        let harness = try await makeAccessRulesHarness()
        defer { harness.cleanUp() }

        try await withAccessRulesApp(context: harness.context) { app in
            let response = try await accessRulesCall(
                app: app,
                method: .DELETE,
                path: "/approvals/rules/\(UUID().uuidString)"
            )
            #expect(response.status == .notFound)
        }
    }

    @Test
    func `DELETE revokes a live rule and broadcasts the change`() async throws {
        let harness = try await makeAccessRulesHarness()
        defer { harness.cleanUp() }
        let id = await seedRules(harness)
        let socket = RulesRecordingSocket()
        let connectionID = UUID()
        _ = await harness.context.hub.add(id: connectionID, box: socket)

        try await withAccessRulesApp(context: harness.context) { app in
            let response = try await accessRulesCall(
                app: app,
                method: .DELETE,
                path: "/approvals/rules/\(id.uuidString)"
            )
            #expect(response.status == .noContent)
        }

        #expect(await harness.context.permissionGate.activeRules().count == 1)
        let frames = await waitForRulesFrames(socket)
        #expect(frames.contains { $0.contains("access_rules_changed") })
    }

    @Test
    func `POST mints a standing allow from the rules surface`() async throws {
        let harness = try await makeAccessRulesHarness()
        defer { harness.cleanUp() }

        try await withAccessRulesApp(context: harness.context) { app in
            let request = RuleCreateRequest(
                toolName: "email.send",
                scope: AccessScopeDTO(kind: .exactTarget, target: "carol@example.com"),
                action: .allow,
                duration: .oneHour
            )
            let response = try await accessRulesCall(app: app, method: .POST, path: "/approvals/rules", body: request)
            #expect(response.status == .ok)
            let row = try response.content.decode(AccessRuleResponse.self)
            #expect(row.toolName == "email.send")
            #expect(row.scope == AccessScopeDTO(kind: .exactTarget, target: "carol@example.com"))
            #expect(row.action == .allow)
            #expect(row.duration == .oneHour)
            #expect(row.expiresAt != nil)

            let listed = try await accessRulesCall(app: app, method: .GET, path: "/approvals/rules")
            let body = try listed.content.decode(AccessRulesResponse.self)
            #expect(body.count == 1)
            #expect(body.rules.first?.id == row.id)
        }
    }

    @Test
    func `POST deny never expires whatever tier the request names`() async throws {
        let harness = try await makeAccessRulesHarness()
        defer { harness.cleanUp() }

        try await withAccessRulesApp(context: harness.context) { app in
            // A dated tier is accepted for symmetry with the allow shape and
            // ignored: a refusal that lapsed would let the call through.
            let request = RuleCreateRequest(
                toolName: "email.send",
                scope: AccessScopeDTO(kind: .exactTarget, target: "blocked@example.com"),
                action: .deny,
                duration: .fiveMinutes,
                reason: "owner refuses this recipient"
            )
            let response = try await accessRulesCall(app: app, method: .POST, path: "/approvals/rules", body: request)
            #expect(response.status == .ok)
            let row = try response.content.decode(AccessRuleResponse.self)
            #expect(row.action == .deny)
            #expect(row.duration == nil)
            #expect(row.expiresAt == nil)
            #expect(row.reason == "owner refuses this recipient")
        }

        // The refusal decides live: a covered call is denied and names the rule.
        let call = ToolInput(toolName: "email.send", argumentsJSON: #"{"to":"blocked@example.com"}"#)
        let verdict = await harness.context.permissionGate.checkPermission(
            toolCall: call,
            tool: RulesProbeTool(name: "email.send")
        )
        guard case let .denied(reason) = verdict else {
            Issue.record("Expected the deny rule to refuse the call")
            return
        }
        #expect(reason.contains("Denied by rule"))
    }

    @Test
    func `POST with a malformed scope fails 400 and stores nothing`() async throws {
        let harness = try await makeAccessRulesHarness()
        defer { harness.cleanUp() }

        // An unknown kind, a wildcard host, a relative prefix, and an empty
        // recipient set all fail the canonical gate inside the decode.
        let malformed: [[String: Any]] = [
            ["kind": "nonsense"],
            ["kind": "domain", "host": "*.com"],
            ["kind": "pathPrefix", "path": "relative/notes"],
            ["kind": "recipientSet", "handles": []]
        ]
        for scope in malformed {
            let payload: [String: Any] = [
                "toolName": "email.send",
                "scope": scope,
                "action": "allow",
                "duration": "forever"
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            #expect((try? JSONDecoder().decode(RuleCreateRequest.self, from: data)) == nil)
        }

        // The decode is what refuses them, so prove it on the wire too.
        try await withAccessRulesApp(context: harness.context) { app in
            let body = RawScopeRuleBody(
                toolName: "email.send",
                scope: ["kind": "domain", "host": "*.com"],
                action: "allow",
                duration: "forever"
            )
            let response = try await postRuleBody(app: app, body: body)
            #expect(response.status == .badRequest)
        }
        #expect(await harness.context.permissionGate.activeRules().isEmpty)
    }

    @Test
    func `POST refuses a tool-wide send scope and a one-shot tier`() async throws {
        let harness = try await makeAccessRulesHarness()
        defer { harness.cleanUp() }

        try await withAccessRulesApp(context: harness.context) { app in
            // Send trust is per-recipient, so the tool-wide scope is refused at
            // the mint boundary instead of storing a row no call can exercise.
            let wideSend = RawScopeRuleBody(
                toolName: "messages.send",
                scope: ["kind": "tool"],
                action: "allow",
                duration: "forever"
            )
            let wideResponse = try await postRuleBody(app: app, body: wideSend)
            #expect(wideResponse.status == .badRequest)

            // A display name is not a canonical handle, so it stores nothing
            // either — the approved call would still fail closed at execution.
            let namedSend = RawScopeRuleBody(
                toolName: "messages.send",
                scope: ["kind": "exactTarget", "target": "Rebecca"],
                action: "allow",
                duration: "forever"
            )
            let namedResponse = try await postRuleBody(app: app, body: namedSend)
            #expect(namedResponse.status == .badRequest)

            // A one-shot tier cannot back a durable row.
            let oneShot = RawScopeRuleBody(
                toolName: "email.send",
                scope: ["kind": "exactTarget", "target": "a@x.com"],
                action: "allow",
                duration: "thisTime"
            )
            let oneShotResponse = try await postRuleBody(app: app, body: oneShot)
            #expect(oneShotResponse.status == .badRequest)
        }
        #expect(await harness.context.permissionGate.activeRules().isEmpty)
    }

    @Test
    func `PATCH unknown rule reports notFound and a one-shot tier stays badRequest`() async throws {
        let harness = try await makeAccessRulesHarness()
        defer { harness.cleanUp() }
        let id = await seedRules(harness)

        try await withAccessRulesApp(context: harness.context) { app in
            let unknown = try await accessRulesCall(
                app: app,
                method: .PATCH,
                path: "/approvals/rules/\(UUID().uuidString)",
                body: RearmRuleRequest(duration: .oneDay)
            )
            #expect(unknown.status == .notFound)

            // A deny rule carries no expiry to recompute, so re-arming one
            // reads as the honest unknown rather than a silent no-op.
            let denyID = await harness.context.permissionGate.activeRules().first(where: { $0.action == .deny })?.id
            let deny = try await accessRulesCall(
                app: app,
                method: .PATCH,
                path: "/approvals/rules/\(denyID?.uuidString ?? UUID().uuidString)",
                body: RearmRuleRequest(duration: .oneDay)
            )
            #expect(deny.status == .notFound)

            let oneShot = try await accessRulesCall(
                app: app,
                method: .PATCH,
                path: "/approvals/rules/\(id.uuidString)",
                body: RearmRuleRequest(duration: .thisTime)
            )
            #expect(oneShot.status == .badRequest)
        }

        // The failed re-arm leaves the stored row untouched.
        let rules = await harness.context.permissionGate.activeRules()
        #expect(rules.first(where: { $0.id == id })?.duration == .forever)
    }

    @Test
    func `PATCH re-arms a live allow rule to a new durable tier`() async throws {
        let harness = try await makeAccessRulesHarness()
        defer { harness.cleanUp() }
        let id = await seedRules(harness)

        try await withAccessRulesApp(context: harness.context) { app in
            let response = try await accessRulesCall(
                app: app,
                method: .PATCH,
                path: "/approvals/rules/\(id.uuidString)",
                body: RearmRuleRequest(duration: .oneDay)
            )
            #expect(response.status == .noContent)
        }

        let rules = await harness.context.permissionGate.activeRules()
        #expect(rules.count == 2)
        #expect(rules.first(where: { $0.id == id })?.duration == .oneDay)
        #expect(rules.first(where: { $0.id == id })?.expiresAt != nil)
    }

    @Test
    func `widen distinguishes unknown from unwidenable and promotes an allow`() async throws {
        let harness = try await makeAccessRulesHarness()
        defer { harness.cleanUp() }
        let allowID = await seedRules(harness)
        await harness.context.permissionGate.grantTrust(
            for: ActionDescriptor(toolName: "messages.send", target: "+15551234567"),
            duration: .forever
        )
        let sendID = await harness.context.permissionGate.activeRules().first(where: {
            $0.toolName == "messages.send"
        })?.id

        try await withAccessRulesApp(context: harness.context) { app in
            let unknown = try await accessRulesCall(
                app: app,
                method: .POST,
                path: "/approvals/rules/\(UUID().uuidString)/widen"
            )
            #expect(unknown.status == .notFound)

            // A live send rule is per-recipient by design, so widening reports
            // the honest conflict instead of "unknown".
            let send = try await accessRulesCall(
                app: app,
                method: .POST,
                path: "/approvals/rules/\(sendID?.uuidString ?? UUID().uuidString)/widen"
            )
            #expect(send.status == .conflict)

            let widened = try await accessRulesCall(
                app: app,
                method: .POST,
                path: "/approvals/rules/\(allowID.uuidString)/widen"
            )
            #expect(widened.status == .noContent)
        }

        // The promotion replaces the narrow scope in place and keeps the rule's
        // identity, so no second row appears.
        let rules = await harness.context.permissionGate.activeRules()
        #expect(rules.first(where: { $0.id == allowID })?.scope == .toolWide)
    }

    @Test
    func `session-trust lists ephemeral grants beside the supervisor domains`() async throws {
        let harness = try await makeAccessRulesHarness()
        defer { harness.cleanUp() }
        let sessionID = UUID()
        #expect(await harness.context.permissionGate.grant(
            .recipientSet(["a@x.com", "b@x.com"]),
            toolName: "email.send",
            duration: .forTask,
            sessionID: sessionID
        ))
        #expect(await harness.context.permissionGate.grant(
            .toolWide,
            toolName: "bash.exec",
            duration: .forSession,
            sessionID: sessionID
        ))
        await harness.context.egressSupervisor?.allowDomainForSession(sessionID: sessionID, domain: "api.example.com")
        await harness.context.egressSupervisor?.allowDomainOnce(domain: "cdn.example.com", sessionID: sessionID)

        // Another session's trust never leaks into this reading.
        let other = UUID()
        #expect(await harness.context.permissionGate.grant(
            .toolWide,
            toolName: "stub.write",
            duration: .forSession,
            sessionID: other
        ))

        try await withAccessRulesApp(context: harness.context) { app in
            let response = try await accessRulesCall(
                app: app,
                method: .GET,
                path: "/approvals/session-trust?sessionID=\(sessionID.uuidString)"
            )
            #expect(response.status == .ok)
            let body = try response.content.decode(SessionTrustResponse.self)
            #expect(body.sessionID == sessionID)
            #expect(body.count == 2)
            #expect(body.grants.count == 2)

            // Task grants read first so a caller can tell a turn-scoped
            // approval from a conversation-scoped one through the tier alone.
            #expect(body.grants[0].duration == .forTask)
            #expect(body.grants[0].toolName == "email.send")
            #expect(body.grants[0].scope == AccessScopeDTO(kind: .recipientSet, handles: ["a@x.com", "b@x.com"]))
            #expect(body.grants[1].duration == .forSession)
            #expect(body.grants[1].toolName == "bash.exec")
            #expect(body.grants[1].scope == AccessScopeDTO(kind: .tool))

            #expect(body.egressSessionDomains == ["api.example.com"])
            #expect(body.egressOneShotDomains == ["cdn.example.com"])
        }
    }

    @Test
    func `session-trust without a usable session id reports badRequest`() async throws {
        let harness = try await makeAccessRulesHarness()
        defer { harness.cleanUp() }

        try await withAccessRulesApp(context: harness.context) { app in
            for path in ["/approvals/session-trust", "/approvals/session-trust?sessionID=not-a-uuid"] {
                let response = try await accessRulesCall(app: app, method: .GET, path: path)
                #expect(response.status == .badRequest, "\(path) must be refused")
            }
        }
    }

    @Test
    func `ephemeral clear drops the session gate grants and supervisor state`() async throws {
        let harness = try await makeAccessRulesHarness()
        defer { harness.cleanUp() }
        let sessionID = UUID()
        #expect(await harness.context.permissionGate.grant(
            .toolWide,
            toolName: "bash.exec",
            duration: .forSession,
            sessionID: sessionID
        ))
        await harness.context.egressSupervisor?.allowDomainForSession(sessionID: sessionID, domain: "api.example.com")
        await harness.context.egressSupervisor?.allowDomainOnce(domain: "cdn.example.com", sessionID: sessionID)

        try await withAccessRulesApp(context: harness.context) { app in
            let request = EphemeralClearRequest(sessionID: sessionID, toolName: "bash.exec")
            let cleared = try await accessRulesCall(
                app: app,
                method: .POST,
                path: "/approvals/ephemeral/clear",
                body: request
            )
            #expect(cleared.status == .noContent)

            let trust = try await accessRulesCall(
                app: app,
                method: .GET,
                path: "/approvals/session-trust?sessionID=\(sessionID.uuidString)"
            )
            let body = try trust.content.decode(SessionTrustResponse.self)
            #expect(body.grants.isEmpty)
            #expect(body.egressSessionDomains.isEmpty)
            #expect(body.egressOneShotDomains.isEmpty)
        }
    }

    @Test
    func `ephemeral clear for an unknown session is a no-op`() async throws {
        let harness = try await makeAccessRulesHarness()
        defer { harness.cleanUp() }

        try await withAccessRulesApp(context: harness.context) { app in
            // A session nothing knows about converges: the caller's row is
            // already gone, so the clear answers 204 instead of a 404.
            let request = EphemeralClearRequest(sessionID: UUID())
            let response = try await accessRulesCall(
                app: app,
                method: .POST,
                path: "/approvals/ephemeral/clear",
                body: request
            )
            #expect(response.status == .noContent)
        }
    }
}

/// Recording socket capturing hub frames for the rules change signal.
private actor RulesRecordingSocket: WSConnectionSocket {
    /// Text frames delivered to this connection.
    private(set) var sent: [String] = []

    /// Records one text frame.
    func send(_ text: String) async throws {
        sent.append(text)
    }

    /// Ignored; these tests never close the connection.
    func close(code _: WebSocketErrorCode) async throws {}
}

/// Polls a recording socket until it captures at least one frame or the budget expires.
/// - Parameter socket: Recording socket under test.
/// - Returns: Frames captured at the deadline.
private func waitForRulesFrames(_ socket: RulesRecordingSocket) async -> [String] {
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

/// Probe tool standing in for a gated call on the rules decision path.
private struct RulesProbeTool: Tool, Sendable {
    let name: String
    let description = "Probe tool."
    let permissionLevel = PermissionLevel.requiresApproval
    var inputSchema: JSONSchema {
        .emptyObject
    }

    func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        .success("probe-ok", callID: input.callID)
    }
}

@Suite("Files Write Path Rules Settings")
struct FilesWritePathRulesSettingsTests {
    @Test
    func `write_path_rules merges through the settings DTO and round-trips`() throws {
        var config = RuneWeaverConfig.default
        let rules = [
            FilesWritePathRule(path: "~/Notes", posture: .live),
            FilesWritePathRule(path: "~/Documents/Secrets", posture: .deny)
        ]
        let request = try JSONDecoder().decode(
            UpdateSettingsRequest.self,
            from: Data(#"{"filesWritePathRules":[{"path":"~/Notes","posture":"live"},{"path":"~/Documents/Secrets","posture":"deny"}]}"#.utf8)
        )
        #expect(request.filesWritePathRules == rules)
        #expect(request.carriesFilesPatch == true)

        try request.apply(to: &config)
        try config.validate()
        #expect(config.files.writePathRules == rules)

        // GET mirrors the persisted rules so the dashboard renders live values.
        let response = SettingsResponse(config: config, configPath: "/test/config.toml")
        #expect(response.filesWritePathRules == rules)
        let decoded = try JSONDecoder().decode(SettingsResponse.self, from: JSONEncoder().encode(response))
        #expect(decoded.filesWritePathRules == rules)

        // The persisted file carries the same rules so a reload agrees.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rw-write-path-rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("config.toml")
        try config.save(to: fileURL)
        let reloaded = try RuneWeaverConfig.load(from: fileURL)
        #expect(reloaded.files.writePathRules == rules)
    }

    @Test
    func `write_path_rules mirrors the config document bounds`() {
        // An over-long list, a blank path, and an over-bound path all refuse
        // with the same field names the TOML loader uses, so the PUT and the
        // file-load paths cannot drift on what a rule may carry.
        let tooMany = (0 ... Int(FilesWritePathRule.maxRuleCount)).map { index in
            FilesWritePathRule(path: "/tmp/\(index)", posture: .ask)
        }
        var listConfig = RuneWeaverConfig.default
        expectValidationError(
            field: "files.write_paths",
            body: { try UpdateSettingsRequest(filesWritePathRules: tooMany).apply(to: &listConfig) }
        )
        var blankConfig = RuneWeaverConfig.default
        expectValidationError(
            field: "files.write_paths.path",
            body: { try UpdateSettingsRequest(filesWritePathRules: [FilesWritePathRule(path: "   ", posture: .ask)]).apply(to: &blankConfig) }
        )
        let longPath = "/tmp/" + String(repeating: "a", count: FilesWritePathRule.maxPathLength)
        var longConfig = RuneWeaverConfig.default
        expectValidationError(
            field: "files.write_paths.path",
            body: { try UpdateSettingsRequest(filesWritePathRules: [FilesWritePathRule(path: longPath, posture: .ask)]).apply(to: &longConfig) }
        )
    }

    @Test
    func `a closed-set posture failure fails decoding before the merge`() {
        // A posture outside the closed set is a decode failure, so the route
        // answers 400 before anything is persisted.
        let request = try? JSONDecoder().decode(
            UpdateSettingsRequest.self,
            from: Data(#"{"filesWritePathRules":[{"path":"~/Notes","posture":"ship"}]}"#.utf8)
        )
        #expect(request == nil)
    }

    @Test
    func `an unrelated save preserves the stored rules and reports no files patch`() throws {
        var config = RuneWeaverConfig.default
        config.files.writePathRules = [FilesWritePathRule(path: "~/Notes", posture: .stage)]

        let unrelated = UpdateSettingsRequest(engineName: "Kept Files")
        #expect(unrelated.carriesFilesPatch == false)
        try unrelated.apply(to: &config)
        #expect(config.files.writePathRules == [FilesWritePathRule(path: "~/Notes", posture: .stage)])
    }

    @Test
    func `a write_path_rules save reaches the live gate with no restart`() async throws {
        var config = RuneWeaverConfig.default
        let rules = [FilesWritePathRule(path: "~/Notes", posture: .deny)]
        try UpdateSettingsRequest(filesWritePathRules: rules).apply(to: &config)

        // The route pushes the merged section into the live gate beside its
        // bash update, so the next write classifies under the saved policy.
        let gate = PermissionGate()
        await gate.updateFilesConfig(config.files)
        let live = await gate.filesConfigSnapshot()
        #expect(live.writePathRules == rules)

        // A covered write refuses under the live posture instead of staging.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let call = ToolInput(
            toolName: "files.write",
            argumentsJSON: #"{"path":"\#(home)/Notes/report.md","content":"notes"}"#
        )
        let verdict = await gate.checkPermission(toolCall: call, tool: FilesWriteProbeTool())
        guard case let .denied(reason) = verdict else {
            Issue.record("Expected the saved deny posture to refuse the write")
            return
        }
        #expect(!reason.isEmpty)
    }
}

/// Applies one update and converts the thrown validation error into a record.
/// - Parameters:
///   - field: Dotted field name the error must carry.
///   - body: Throwing apply closure under test.
private func expectValidationError(field: String, body: () throws -> Void) {
    do {
        try body()
        Issue.record("Expected a validation error naming \(field)")
    } catch let error as ConfigError {
        guard case let .validationError(failedField, _) = error else {
            Issue.record("Expected a validation error, got \(error)")
            return
        }
        #expect(failedField == field)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

/// Probe tool standing in for a gated `files.write` call.
private struct FilesWriteProbeTool: Tool, Sendable {
    let name = "files.write"
    let description = "Probe for files.write."
    let permissionLevel = PermissionLevel.requiresApproval
    var inputSchema: JSONSchema {
        .emptyObject
    }

    func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        .success("probe-ok", callID: input.callID)
    }
}

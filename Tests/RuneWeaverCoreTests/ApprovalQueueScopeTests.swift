// Rune Weaver Tests — Approval decision scope derivation and durable minting.
//
// Purpose: pin the contract that one decision resolves one parked request into
// the scope the owner actually authorized — a nil scope derives the parked
// egress host for an unlisted-host request and the descriptor target for every
// other request, a durable denial mints a standing deny rule that outranks
// every allow, the one-shot tools (engine.continue, question.ask,
// desktop.resume, behavior.brake) never mint a row even under a durable tier
// with a non-nil scope, a scheduled send (email.send or messages.send
// carrying a wire-valid scheduleAt) coerces the approval to thisTime with no
// stored rule while a durable denial still mints the recipient deny, and the
// per-recipient messages.send invariant refuses any send scope that is not a
// recipient set or a canonical handle. The same boundary keeps the
// enrichment-cancel-before-decide ordering, so a late model result never
// resurrects a decided entry or mints a second row.
// Architectural role: the regression suite for `ApprovalQueue.decide`, the one
// decision path the chat banner, inbox, dashboard, and WebSocket triage all
// share, so no surface can drift onto a scope or a durable row the queue never
// resolved.

import Foundation
@testable import RuneWeaverCore
import Testing

@Suite("Approval Queue Scope")
struct ApprovalQueueScopeTests {
    /// Probe tool so the gate can evaluate a live call without the Tools layer.
    private struct ScopeProbeTool: Tool, Sendable {
        let name: String
        let description = "Probe tool for approval scope tests."
        let inputSchema = JSONSchema(rawValue: #"{"type":"object"}"#)
        let permissionLevel: PermissionLevel = .requiresApproval

        func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
            .success("ok", callID: input.callID)
        }
    }

    @Test
    func `nil scope on an egress request resolves to a domain scope`() async {
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let tool = ScopeProbeTool(name: "api.request")
        let request = await queue.enqueue(
            toolName: "api.request",
            description: "Call API",
            input: ToolInput(toolName: "api.request", argumentsJSON: #"{"url":"https://Example.COM/v1"}"#),
            egressHost: "Example.COM"
        )

        #expect(await queue.decide(id: request.id, approved: true, duration: .forever) == true)

        // The parked host is the scope, canonicalized by the rule, so the grant
        // reaches the domain the call dialed and not the composed descriptor
        // target the generic derivation would have stored.
        let rules = await gate.activeRules()
        #expect(rules.count == 1)
        #expect(rules.first?.toolName == "api.request")
        #expect(rules.first?.action == .allow)
        #expect(rules.first?.scope == .domain(host: "example.com", subdomains: false))
        // Another path on the same host is covered; another host still parks.
        let sameHost = ToolInput(toolName: "api.request", argumentsJSON: #"{"url":"https://example.com/other"}"#)
        #expect(await gate.checkPermission(toolCall: sameHost, tool: tool) == .allowed)
        let otherHost = ToolInput(toolName: "api.request", argumentsJSON: #"{"url":"https://other.com/v1"}"#)
        guard case .requiresApproval = await gate.checkPermission(toolCall: otherHost, tool: tool) else {
            Issue.record("Expected a different host to park, got a non-parking verdict")
            return
        }
    }

    @Test
    func `nil scope on a plain request resolves to the derived target`() async {
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let tool = ScopeProbeTool(name: "browser.act")
        let call = ToolInput(toolName: "browser.act", argumentsJSON: #"{"action":"click","ref":"e12","url":"https://example.com/page"}"#)
        let request = await queue.enqueue(
            toolName: "browser.act",
            description: "Act on a browser snapshot ref.",
            input: call
        )

        #expect(await queue.decide(id: request.id, approved: true, duration: .oneHour) == true)

        // The decision path knows only the tool name, so its derivation must
        // agree with the live-tool derivation the allow check runs later.
        let rules = await gate.activeRules()
        #expect(rules.count == 1)
        #expect(rules.first?.scope == .exactTarget("click e12 @ https://example.com/page"))
        #expect(await gate.checkPermission(toolCall: call, tool: tool) == .allowed)
    }

    @Test
    func `explicit scope overrides the derived one`() async {
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let request = await queue.enqueue(
            toolName: "api.request",
            description: "Call API",
            input: ToolInput(toolName: "api.request", argumentsJSON: #"{"method":"GET","url":"https://api.example.com/items"}"#)
        )

        #expect(await queue.decide(id: request.id, approved: true, duration: .oneHour, scope: .toolWide) == true)

        let rules = await gate.activeRules()
        #expect(rules.count == 1)
        #expect(rules.first?.scope == .toolWide)
        #expect(
            await gate.isTrusted(
                ActionDescriptor(toolName: "api.request", target: "GET https://other.example.com/x")
            ) == true
        )
    }

    @Test
    func `empty derived target stores nothing instead of widening`() async {
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let request = await queue.enqueue(
            toolName: "goal.create",
            description: "Create goal.",
            input: ToolInput(toolName: "goal.create", argumentsJSON: "{}")
        )

        // A malformed call derives an empty target, which is the malformed-call
        // signature rather than a tool-wide scope, so nothing is minted while
        // the decision itself still resolves.
        #expect(await queue.decide(id: request.id, approved: true, duration: .forever) == true)
        #expect(await gate.activeRules().isEmpty == true)
        #expect(await queue.count() == 0)
    }

    @Test
    func `durable denial mints a standing deny rule that outranks the allow`() async throws {
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let tool = ScopeProbeTool(name: "stub.write")
        let call = ToolInput(toolName: "stub.write", argumentsJSON: #"{"path":"/tmp/deny"}"#)
        // A standing allow first: the deny must outrank it rather than evict it.
        await gate.grantTrust(for: ActionDescriptor.descriptor(for: call, toolName: "stub.write"), duration: .forever)
        let request = await queue.enqueue(
            toolName: "stub.write",
            description: "Write stub.",
            input: call
        )
        async let decision = await queue.waitForDecision(id: request.id)
        #expect(await queue.decide(id: request.id, approved: false, duration: .forever) == true)
        let resolved = await decision
        #expect(resolved.approved == false)
        #expect(resolved.duration == .forever)

        let rules = await gate.activeRules()
        let deny = try #require(rules.first(where: { $0.action == .deny }))
        #expect(deny.toolName == "stub.write")
        #expect(deny.scope == .exactTarget("/tmp/deny"))
        // A standing rule carries no tier and no expiry, so it never ages out.
        #expect(deny.duration == nil)
        #expect(deny.expiresAt == nil)
        #expect(deny.reason == "Denied by owner decision on stub.write.")
        // The allow survives beside it, and the deny still outranks.
        #expect(rules.contains(where: { $0.action == .allow }) == true)
        guard case let .denied(reason) = await gate.checkPermission(toolCall: call, tool: tool) else {
            Issue.record("Expected the deny rule to refuse the call")
            return
        }
        #expect(reason.contains("Denied by owner decision on stub.write."))
    }

    @Test
    func `one-time denial stores no deny rule`() async {
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let request = await queue.enqueue(
            toolName: "stub.write",
            description: "Write stub.",
            input: ToolInput(toolName: "stub.write", argumentsJSON: #"{"path":"/tmp/once"}"#)
        )

        #expect(await queue.decide(id: request.id, approved: false, duration: .thisTime) == true)
        #expect(await gate.activeRules().isEmpty == true)
    }

    @Test
    func `durable denial on an egress request mints a domain deny rule`() async {
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let request = await queue.enqueue(
            toolName: "api.request",
            description: "Call API",
            input: ToolInput(toolName: "api.request", argumentsJSON: #"{"url":"https://blocked.example.com/v1"}"#),
            egressHost: "Blocked.Example.COM"
        )

        #expect(await queue.decide(id: request.id, approved: false, duration: .forever) == true)

        let rules = await gate.activeRules()
        #expect(rules.count == 1)
        #expect(rules.first?.action == .deny)
        #expect(rules.first?.scope == .domain(host: "blocked.example.com", subdomains: false))
        #expect(rules.first?.reason == "Denied by owner decision on api.request.")
    }

    @Test
    func `one-shot tools coerce durable tiers and mint no rule`() async {
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        // brake trust is meaningless: behavior.brake is not an executable tool,
        // so a durable vote must not mint a dead row for it either.
        for toolName in ["engine.continue", "question.ask", "desktop.resume", "behavior.brake"] {
            let approved = await queue.enqueue(
                toolName: toolName,
                description: "\(toolName) request.",
                input: ToolInput(toolName: toolName, argumentsJSON: #"{"rounds":2}"#)
            )
            // A durable approval with a non-nil scope still stores nothing.
            #expect(await queue.decide(id: approved.id, approved: true, duration: .forever, scope: .toolWide) == true)
            // A durable denial stores nothing either.
            let denied = await queue.enqueue(
                toolName: toolName,
                description: "\(toolName) request.",
                input: ToolInput(toolName: toolName, argumentsJSON: #"{"rounds":2}"#)
            )
            #expect(await queue.decide(id: denied.id, approved: false, duration: .forever, scope: .toolWide) == true)
            // The waiter observes the coerced thisTime tier, not the durable vote.
            let waiting = await queue.enqueue(
                toolName: toolName,
                description: "\(toolName) request.",
                input: ToolInput(toolName: toolName, argumentsJSON: #"{"rounds":2}"#)
            )
            async let decision = await queue.waitForDecision(id: waiting.id)
            #expect(await queue.decide(id: waiting.id, approved: true, duration: .forever, scope: .toolWide) == true)
            let resolved = await decision
            #expect(resolved.approved == true)
            #expect(resolved.duration == .thisTime)
        }
        #expect(await gate.activeRules().isEmpty == true)
        await queue.clear()
    }

    @Test
    func `handle send with nil scope mints the canonical handle grant`() async {
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let tool = ScopeProbeTool(name: "messages.send")
        let request = await queue.enqueue(
            toolName: "messages.send",
            description: "Send a message.",
            input: ToolInput(toolName: "messages.send", argumentsJSON: #"{"recipient":"+1 (555) 123-4567","text":"Hi"}"#)
        )

        #expect(await queue.decide(id: request.id, approved: true, duration: .forever) == true)

        let rules = await gate.activeRules()
        #expect(rules.count == 1)
        #expect(rules.first?.scope == .exactTarget("+15551234567"))
        let respelled = ToolInput(toolName: "messages.send", argumentsJSON: #"{"recipient":"+15551234567","text":"Hi"}"#)
        #expect(await gate.checkPermission(toolCall: respelled, tool: tool) == .allowed)
    }

    @Test
    func `invalid send scopes store nothing while the decision still resolves`() async {
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        // A name-shaped recipient is not a handle and a missing recipient
        // derives an empty target; neither may key send trust.
        for arguments in [
            #"{"recipient":"Rebecca","text":"Hi"}"#,
            #"{"text":"Hi"}"#
        ] {
            let derived = await queue.enqueue(
                toolName: "messages.send",
                description: "Send a message.",
                input: ToolInput(toolName: "messages.send", argumentsJSON: arguments)
            )
            #expect(await queue.decide(id: derived.id, approved: true, duration: .forever) == true)
        }
        // Explicit non-send-shaped scopes never key a send grant either.
        for scope in [
            AccessScope.toolWide,
            AccessScope.domain(host: "example.com", subdomains: false),
            AccessScope.glob("sms *")
        ] {
            let explicit = await queue.enqueue(
                toolName: "messages.send",
                description: "Send a message.",
                input: ToolInput(toolName: "messages.send", argumentsJSON: #"{"recipient":"+15551234567","text":"Hi"}"#)
            )
            #expect(await queue.decide(id: explicit.id, approved: true, duration: .forever, scope: scope) == true)
        }

        #expect(await gate.activeRules().isEmpty == true)
        await queue.clear()
    }

    @Test
    func `recipient set send scope covers the canonical handle`() async {
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let tool = ScopeProbeTool(name: "messages.send")
        let request = await queue.enqueue(
            toolName: "messages.send",
            description: "Send a message.",
            input: ToolInput(toolName: "messages.send", argumentsJSON: #"{"recipient":"+1 (555) 123-4567","text":"Hi"}"#)
        )

        #expect(
            await queue.decide(
                id: request.id,
                approved: true,
                duration: .forever,
                scope: .recipientSet(["+1 (555) 123-4567", "bob@example.com"])
            ) == true
        )

        let rules = await gate.activeRules()
        #expect(rules.count == 1)
        #expect(rules.first?.scope == .recipientSet(["+15551234567", "bob@example.com"]))
        let call = ToolInput(toolName: "messages.send", argumentsJSON: #"{"recipient":"+15551234567","text":"Hi"}"#)
        #expect(await gate.checkPermission(toolCall: call, tool: tool) == .allowed)
    }

    @Test
    func `scheduled sends coerce durable approvals to thisTime with no stored rule`() async {
        let fireAt = Date().addingTimeInterval(3600)
        let epoch = String(fireAt.timeIntervalSince1970)
        let iso = SharedDateFormatters.isoInternetTimeString(from: fireAt)
        // Both wire shapes across both send tools and both durable tiers: the
        // booking is the sole effect, so even a lasting vote resolves one-shot
        // with no stored row.
        let cases: [(toolName: String, arguments: String)] = [
            ("email.send", #"{"account":"volcrypt","to":["a@example.com"],"subject":"Hi","scheduleAt":\#(epoch)}"#),
            ("email.send", #"{"account":"volcrypt","to":["a@example.com"],"subject":"Hi","scheduleAt":"\#(iso)"}"#),
            ("messages.send", #"{"recipient":"+15551234567","text":"Hi","scheduleAt":\#(epoch)}"#),
            ("messages.send", #"{"recipient":"+15551234567","text":"Hi","scheduleAt":"\#(iso)"}"#)
        ]
        for duration in [TrustDuration.forever, TrustDuration.oneHour] {
            for entry in cases {
                let gate = PermissionGate()
                let queue = ApprovalQueue(permissionGate: gate)
                let request = await queue.enqueue(
                    toolName: entry.toolName,
                    description: "Scheduled send.",
                    input: ToolInput(toolName: entry.toolName, argumentsJSON: entry.arguments)
                )
                async let decision = await queue.waitForDecision(id: request.id)
                #expect(await queue.decide(id: request.id, approved: true, duration: duration) == true)
                let resolved = await decision
                #expect(resolved.approved == true)
                #expect(resolved.duration == .thisTime)
                #expect(await gate.activeRules().isEmpty == true)
                await queue.clear()
            }
        }
    }

    @Test
    func `sends without a valid fire time keep existing duration behavior`() async {
        // Absent, blank, and malformed fire times are immediate sends, so a
        // durable vote still mints exactly as before.
        let arguments = [
            #"{"account":"volcrypt","to":["a@example.com"],"subject":"Hi"}"#,
            #"{"account":"volcrypt","to":["a@example.com"],"subject":"Hi","scheduleAt":""}"#,
            #"{"account":"volcrypt","to":["a@example.com"],"subject":"Hi","scheduleAt":"not-a-date"}"#,
            #"{"account":"volcrypt","to":["a@example.com"],"subject":"Hi","scheduleAt":true}"#,
            #"{"account":"volcrypt","to":["a@example.com"],"subject":"Hi","scheduleAt":{}}"#
        ]
        for args in arguments {
            let gate = PermissionGate()
            let queue = ApprovalQueue(permissionGate: gate)
            let request = await queue.enqueue(
                toolName: "email.send",
                description: "Immediate send.",
                input: ToolInput(toolName: "email.send", argumentsJSON: args)
            )
            #expect(await queue.decide(id: request.id, approved: true, duration: .forever) == true)
            let rules = await gate.activeRules()
            #expect(rules.count == 1)
            #expect(rules.first?.toolName == "email.send")
            #expect(rules.first?.action == .allow)
            await queue.clear()
        }
    }

    @Test
    func `deny-forever on a scheduled send still mints the standing deny`() async {
        let fireAt = Date().addingTimeInterval(3600)
        let epoch = String(fireAt.timeIntervalSince1970)
        let iso = SharedDateFormatters.isoInternetTimeString(from: fireAt)
        let cases: [(toolName: String, arguments: String)] = [
            ("email.send", #"{"account":"volcrypt","to":["a@example.com"],"subject":"Hi","scheduleAt":\#(epoch)}"#),
            ("messages.send", #"{"recipient":"+1 (555) 123-4567","text":"Hi","scheduleAt":"\#(iso)"}"#)
        ]
        for entry in cases {
            let gate = PermissionGate()
            let queue = ApprovalQueue(permissionGate: gate)
            let request = await queue.enqueue(
                toolName: entry.toolName,
                description: "Scheduled send.",
                input: ToolInput(toolName: entry.toolName, argumentsJSON: entry.arguments)
            )
            async let decision = await queue.waitForDecision(id: request.id)
            #expect(await queue.decide(id: request.id, approved: false, duration: .forever) == true)
            let resolved = await decision
            #expect(resolved.approved == false)
            // The waiter observes the coerced one-shot tier while the standing
            // refusal still lands.
            #expect(resolved.duration == .thisTime)
            let rules = await gate.activeRules()
            #expect(rules.count == 1)
            #expect(rules.first?.toolName == entry.toolName)
            #expect(rules.first?.action == .deny)
            await queue.clear()
        }

        // The messages refusal keys on the canonical handle, so an immediate
        // repeat to that handle fails closed on the deny.
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let tool = ScopeProbeTool(name: "messages.send")
        let scheduled = ToolInput(
            toolName: "messages.send",
            argumentsJSON: #"{"recipient":"+1 (555) 123-4567","text":"Hi","scheduleAt":\#(epoch)}"#
        )
        let request = await queue.enqueue(
            toolName: "messages.send",
            description: "Scheduled send.",
            input: scheduled
        )
        #expect(await queue.decide(id: request.id, approved: false, duration: .forever) == true)
        let rules = await gate.activeRules()
        #expect(rules.count == 1)
        #expect(rules.first?.scope == .exactTarget("+15551234567"))
        let repeatCall = ToolInput(toolName: "messages.send", argumentsJSON: #"{"recipient":"+15551234567","text":"Hi"}"#)
        guard case .denied = await gate.checkPermission(toolCall: repeatCall, tool: tool) else {
            Issue.record("Expected the deny rule to refuse the repeat send")
            return
        }
        await queue.clear()
    }

    @Test
    func `enrichment racing a durable decision still loses`() async {
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        await queue.setOnEnriched { _ in
            Issue.record("Late enrichment must not rebroadcast a decided request")
        }
        let tool = ScopeProbeTool(name: "files.write")
        let call = ToolInput(toolName: "files.write", argumentsJSON: #"{"path":"race.txt"}"#)
        let pending = await queue.fileRequest(tool: tool, call: call)
        #expect(await queue.decide(id: pending.id, approved: true, duration: .forever, scope: .exactTarget("/tmp/race")) == true)

        // Allow the model budget to elapse; the late result must not resurrect
        // the entry, rebroadcast it, or mint a second row.
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        #expect(await queue.request(id: pending.id) == nil)
        #expect(await queue.count() == 0)
        let late = await queue.updateAssessment(
            id: pending.id,
            assessment: ImpactAssessment(severity: .safe, outcome: "Late.", warnings: [])
        )
        #expect(late == nil)
        let rules = await gate.activeRules()
        #expect(rules.count == 1)
        #expect(rules.first?.scope == .exactTarget("/tmp/race"))
        await queue.setOnEnriched(nil)
        await queue.clear()
    }
}

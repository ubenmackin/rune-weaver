// Rune Weaver Tests — Approval grant target matching for specialized tools.
//
// Guards the invariant that a durable narrow grant stores the exact descriptor
// the permission gate derives on the next call. Tools with a composed target
// (`browser.act`, `api.request`) or a canonicalized target (`messages.send`)
// must round-trip through the shared descriptor derivation so approving "this
// target" once keeps covering that same target instead of silently re-prompting
// or collapsing to the wrong scope, and so a send grant can never key on a
// display name. The same boundary refuses empty send targets (malformed calls)
// and tool-wide send scopes outright, so the CLI approval path cannot mint a
// grant a malformed call could never have earned.

import Foundation
@testable import RuneWeaverCore
import Testing

@Suite("Approval Target Matching")
struct ApprovalTargetMatchingTests {
    private struct BrowserActProbeTool: Tool, Sendable {
        let name = "browser.act"
        let description = "Act on a browser snapshot ref."
        let inputSchema = JSONSchema(rawValue: #"{"type":"object"}"#)
        let permissionLevel = PermissionLevel.requiresApproval
        func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
            .success("browser-ok", callID: input.callID)
        }
    }

    private struct ApiRequestProbeTool: Tool, Sendable {
        let name = "api.request"
        let description = "Constrained HTTP request."
        let inputSchema = JSONSchema(rawValue: #"{"type":"object"}"#)
        let permissionLevel = PermissionLevel.requiresApproval
        func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
            .success("api-ok", callID: input.callID)
        }
    }

    private struct MessagesSendProbeTool: Tool, Sendable {
        let name = "messages.send"
        let description = "Send a message."
        let inputSchema = JSONSchema(rawValue: #"{"type":"object"}"#)
        let permissionLevel = PermissionLevel.requiresApproval
        func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
            .success("sent", callID: input.callID)
        }
    }

    @Test
    func `browser.act narrow grant covers the identical next call`() async {
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let arguments = #"{"action":"click","ref":"e12","url":"https://example.com/page"}"#
        let call = ToolInput(toolName: "browser.act", argumentsJSON: arguments)
        let request = await queue.enqueue(
            toolName: "browser.act",
            description: "Act on a browser snapshot ref.",
            input: call
        )

        #expect(await queue.decide(id: request.id, approved: true, duration: .oneHour) == true)

        // The decision path knows only the tool name, so its derivation must
        // agree with the live-tool derivation the allow check runs later.
        let descriptor = ActionDescriptor.descriptor(for: call, tool: BrowserActProbeTool())
        #expect(descriptor.target == "click e12 @ https://example.com/page")
        #expect(descriptor == ActionDescriptor.descriptor(for: call, toolName: "browser.act"))
        // Generic extraction drops the action verb, which is exactly the drift
        // that would leave a stored grant unmatched.
        #expect(descriptor.target != ActionDescriptor.target(from: call))

        #expect(await gate.isTrusted(descriptor) == true)
        let verdict = await gate.checkPermission(toolCall: call, tool: BrowserActProbeTool())
        #expect(verdict == .allowed)
    }

    @Test
    func `api.request narrow grant covers the identical next call`() async {
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let arguments = #"{"method":"POST","url":"https://api.example.com/items","body":"{\"a\":1}"}"#
        let call = ToolInput(toolName: "api.request", argumentsJSON: arguments)
        let request = await queue.enqueue(
            toolName: "api.request",
            description: "Constrained HTTP request.",
            input: call
        )

        #expect(await queue.decide(id: request.id, approved: true, duration: .oneHour) == true)

        let descriptor = ActionDescriptor.descriptor(for: call, tool: ApiRequestProbeTool())
        #expect(descriptor.target == #"POST https://api.example.com/items body:{"a":1}"#)
        #expect(descriptor == ActionDescriptor.descriptor(for: call, toolName: "api.request"))
        // Generic extraction stores only the URL, dropping method and body.
        #expect(descriptor.target != ActionDescriptor.target(from: call))

        #expect(await gate.isTrusted(descriptor) == true)
        let verdict = await gate.checkPermission(toolCall: call, tool: ApiRequestProbeTool())
        #expect(verdict == .allowed)
    }

    @Test
    func `thisTime approval records no trust even when a scope is requested`() async {
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let call = ToolInput(
            toolName: "api.request",
            argumentsJSON: #"{"method":"GET","url":"https://api.example.com/items"}"#
        )
        let request = await queue.enqueue(
            toolName: "api.request",
            description: "Constrained HTTP request.",
            input: call
        )

        // A one-shot decision must stay one-shot: the requested scope never
        // overrides the thisTime guard, so no rule is minted and the next call
        // parks again.
        #expect(await queue.decide(id: request.id, approved: true, duration: .thisTime, scope: .toolWide) == true)
        #expect(await gate.activeRules().isEmpty == true)

        let verdict = await gate.checkPermission(toolCall: call, tool: ApiRequestProbeTool())
        guard case .requiresApproval = verdict else {
            Issue.record("Expected thisTime approval to park again, got \(verdict)")
            return
        }
    }

    @Test
    func `messages.send narrow grant keys on the canonical handle`() async {
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let call = ToolInput(toolName: "messages.send", argumentsJSON: #"{"recipient":"+1 (555) 123-4567","text":"Hi"}"#)
        let request = await queue.enqueue(
            toolName: "messages.send",
            description: "Send a message.",
            input: call
        )

        #expect(await queue.decide(id: request.id, approved: true, duration: .oneHour) == true)

        // The decision path knows only the tool name, so its derivation must
        // agree with the live-tool derivation the allow check runs later.
        let descriptor = ActionDescriptor.descriptor(for: call, tool: MessagesSendProbeTool())
        #expect(descriptor.target == "+15551234567")
        #expect(descriptor == ActionDescriptor.descriptor(for: call, toolName: "messages.send"))
        // Generic extraction keeps the raw punctuation spelling, which would
        // miss the identical next send spelled compactly.
        #expect(descriptor.target != ActionDescriptor.target(from: call))

        #expect(await gate.isTrusted(descriptor) == true)
        let respelled = ToolInput(toolName: "messages.send", argumentsJSON: #"{"recipient":"+15551234567","text":"Hi"}"#)
        let respelledVerdict = await gate.checkPermission(toolCall: respelled, tool: MessagesSendProbeTool())
        #expect(respelledVerdict == .allowed)
    }

    @Test
    func `name-shaped messages.send decision mints no grant`() async {
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let call = ToolInput(toolName: "messages.send", argumentsJSON: #"{"recipient":"Rebecca","text":"Hi"}"#)
        let request = await queue.enqueue(
            toolName: "messages.send",
            description: "Send a message.",
            input: call
        )

        // Admission refuses name-shaped sends before filing; this pins the
        // defensive guard so a directly enqueued request can never key a grant
        // on a display name even when the owner chooses a durable tier.
        #expect(await queue.decide(id: request.id, approved: true, duration: .forever) == true)
        #expect(await gate.activeRules().isEmpty == true)
    }

    @Test
    func `messages.send tool-wide decision mints no grant`() async {
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let call = ToolInput(toolName: "messages.send", argumentsJSON: #"{"recipient":"+15551234567","text":"Hi"}"#)
        let request = await queue.enqueue(
            toolName: "messages.send",
            description: "Send a message.",
            input: call
        )

        // There is no tool-wide send scope: even an explicit tool-wide decision
        // stores nothing, while the approved call itself still proceeds.
        #expect(await queue.decide(id: request.id, approved: true, duration: .forever, scope: .toolWide) == true)
        #expect(await gate.activeRules().isEmpty == true)
    }

    @Test
    func `malformed messages.send durable approval mints no grant and no tool-wide scope`() async {
        // The CLI approval handler mints straight through `grantTrust` with the
        // descriptor derived from the live call, so the malformed shapes — a
        // missing, blank, or non-string recipient — must store nothing at that
        // boundary. Their derived target is empty, which is an invalid send
        // descriptor, never the tool-wide scope every other tool supports.
        let gate = PermissionGate()
        let tool = MessagesSendProbeTool()
        for arguments in [
            #"{"text":"hi"}"#,
            #"{"recipient":123,"text":"hi"}"#,
            #"{"recipient":"   ","text":"hi"}"#
        ] {
            let call = ToolInput(toolName: "messages.send", argumentsJSON: arguments)
            let descriptor = ActionDescriptor.descriptor(for: call, tool: tool)
            #expect(descriptor.target.isEmpty)
            await gate.grantTrust(for: descriptor, duration: .forever)
        }

        #expect(await gate.activeRules().isEmpty == true)
        #expect(await gate.isTrusted(ActionDescriptor(toolName: "messages.send")) == false)

        // A later handle-shaped send still parks instead of riding a stored
        // wide scope.
        let handle = ToolInput(toolName: "messages.send", argumentsJSON: #"{"recipient":"+15551234567","text":"Hi"}"#)
        let verdict = await gate.checkPermission(toolCall: handle, tool: tool)
        guard case .requiresApproval = verdict else {
            Issue.record("Expected a handle send to park with no grant stored, got \(verdict)")
            return
        }
    }

    @Test
    func `array or non-string recipient with a handle to mints no grant`() async {
        // `MessagesSendArgs` cannot decode an array recipient, nor a non-string
        // recipient beside a handle-shaped `to`, so admission proceeds. The
        // generic target path would still derive a canonical-looking handle
        // from the array or from the `to` alias, which is exactly how such a
        // call could mint a durable per-handle grant for a send that can never
        // execute. The strict send derivation returns the empty target for both
        // shapes, and `isGrantable` refuses that empty target.
        let gate = PermissionGate()
        let bus = ToolBus(permissionGate: gate)
        await bus.register(tool: MessagesSendProbeTool())
        let handlerCalls = HandlerCallCounter()
        await bus.setLegacyApprovalHandler { tool, call in
            await handlerCalls.increment()
            let descriptor = ActionDescriptor.descriptor(for: call, tool: tool)
            await gate.grantTrust(for: descriptor, duration: .forever)
            return true
        }

        for arguments in [
            #"{"recipient":["+15551234567"],"text":"Hi"}"#,
            #"{"recipient":123,"to":"+15551234567","text":"Hi"}"#
        ] {
            let call = ToolInput(toolName: "messages.send", argumentsJSON: arguments)
            // The generic extraction would key a grant on a handle the
            // malformed call never delivers; the strict derivation agrees
            // between the live-tool and tool-name paths and yields no target.
            #expect(ActionDescriptor.target(from: call) == "+15551234567")
            let descriptor = ActionDescriptor.descriptor(for: call, tool: MessagesSendProbeTool())
            #expect(descriptor.target.isEmpty)
            #expect(descriptor == ActionDescriptor.descriptor(for: call, toolName: "messages.send"))

            let result = await bus.execute(toolCall: call, context: ToolContext(conversationID: UUID()))
            #expect(result.isError == false)
        }
        #expect(await handlerCalls.count == 2)
        #expect(await gate.activeRules().isEmpty == true)
        #expect(await gate.isTrusted(ActionDescriptor(toolName: "messages.send", target: "+15551234567")) == false)
        #expect(await gate.isTrusted(ActionDescriptor(toolName: "messages.send")) == false)

        // The strict send branch must not leak into other tools: generic target
        // derivation keeps accepting the array shape for non-send callers.
        let other = ToolInput(toolName: "stub.recipient", argumentsJSON: #"{"recipient":["+15551234567"]}"#)
        #expect(ActionDescriptor.descriptor(for: other, toolName: "stub.recipient").target == "+15551234567")
    }

    @Test
    func `CLI-style durable approval stores only the canonical handle grant`() async {
        // Reproduces the CLI's durable-approval handler without the REPL:
        // the handler derives the descriptor from the call and mints it straight
        // through the gate. Malformed and name-shaped calls must leave the grant
        // list empty; a handle-shaped call must store exactly its canonical
        // handle and cover the respelled next send without prompting again.
        let gate = PermissionGate()
        let bus = ToolBus(permissionGate: gate)
        await bus.register(tool: MessagesSendProbeTool())
        let handlerCalls = HandlerCallCounter()
        await bus.setLegacyApprovalHandler { tool, call in
            await handlerCalls.increment()
            let descriptor = ActionDescriptor.descriptor(for: call, tool: tool)
            await gate.grantTrust(for: descriptor, duration: .forever)
            return true
        }

        for arguments in [
            #"{"text":"hi"}"#,
            #"{"recipient":123,"text":"hi"}"#,
            #"{"recipient":"Rebecca","text":"hi"}"#
        ] {
            let result = await bus.execute(
                toolCall: ToolInput(toolName: "messages.send", argumentsJSON: arguments),
                context: ToolContext(conversationID: UUID())
            )
            #expect(result.isError == false)
        }
        #expect(await gate.activeRules().isEmpty == true)
        #expect(await gate.isTrusted(ActionDescriptor(toolName: "messages.send")) == false)
        #expect(await handlerCalls.count == 3)

        let handle = ToolInput(toolName: "messages.send", argumentsJSON: #"{"recipient":"+1 (555) 123-4567","text":"hi"}"#)
        let approved = await bus.execute(toolCall: handle, context: ToolContext(conversationID: UUID()))
        #expect(approved.isError == false)
        let canonical = ActionDescriptor(toolName: "messages.send", target: "+15551234567")
        let rules = await gate.activeRules()
        #expect(rules.count == 1)
        #expect(rules.first?.toolName == canonical.toolName)
        #expect(rules.first?.scope == .exactTarget(canonical.target))
        #expect(await handlerCalls.count == 4)

        let respelled = ToolInput(toolName: "messages.send", argumentsJSON: #"{"recipient":"+15551234567","text":"again"}"#)
        let covered = await bus.execute(toolCall: respelled, context: ToolContext(conversationID: UUID()))
        #expect(covered.isError == false)
        #expect(await handlerCalls.count == 4)
    }

    @Test
    func `legacy tool-wide messages.send rule is dropped and never covers a send`() async throws {
        // A row written before the per-recipient invariant may carry the
        // tool-wide scope. It is dropped at load and, even if it survived, a
        // tool-wide send scope is an invalid rule shape rather than a scope
        // that can authorize a send.
        let legacy = try #require(AccessRule(
            toolName: "messages.send",
            scope: .toolWide,
            action: .allow,
            grantedAt: Date(),
            duration: .forever
        ))
        let store = InMemoryAccessRuleStore(rules: [legacy])
        let gate = await PermissionGate.load(ruleStore: store)
        #expect(await gate.activeRules().isEmpty == true)

        let tool = MessagesSendProbeTool()
        let handle = ToolInput(toolName: "messages.send", argumentsJSON: #"{"recipient":"+15551234567","text":"Hi"}"#)
        let verdict = await gate.checkPermission(toolCall: handle, tool: tool)
        guard case .requiresApproval = verdict else {
            Issue.record("Expected a legacy wide send grant not to cover, got \(verdict)")
            return
        }
    }

    @Test
    func `messages.send grants never widen to a tool-wide scope`() async {
        let gate = PermissionGate()
        let canonical = ActionDescriptor(toolName: "messages.send", target: "+15551234567")
        await gate.grantTrust(for: canonical, duration: .forever)
        guard let rule = await gate.activeRules().first else {
            Issue.record("Expected the canonical send grant")
            return
        }

        // There is no tool-wide send scope, so a promotion to every recipient
        // is refused with the honest reason and the handle grant stays exactly
        // as approved. The outcome is `notWidenable`, never `notFound`, so the
        // widen route cannot misreport the live grant as unknown.
        #expect(
            await gate.widenGrant(id: rule.id)
                == .notWidenable(reason: GrantWidenOutcome.messagesSendRefusal)
        )
        let survivor = await gate.activeRules()
        #expect(survivor.count == 1)
        #expect(survivor.first?.toolName == canonical.toolName)
        #expect(survivor.first?.scope == .exactTarget(canonical.target))
        #expect(await gate.isTrusted(ActionDescriptor(toolName: "messages.send")) == false)
    }

    @Test
    func `non-messages durable grants keep their tool-wide semantics`() async {
        // The send-specific guard must not change any other tool: an empty
        // target still mints a tool-wide grant that covers every target.
        let gate = PermissionGate()
        await gate.grantTrust(for: ActionDescriptor(toolName: "email.send"), duration: .forever)
        #expect(await gate.isTrusted(ActionDescriptor(toolName: "email.send")) == true)
        #expect(await gate.isTrusted(ActionDescriptor(toolName: "email.send", target: "anyone@example.com")) == true)
    }

    /// Counts CLI-style approval handler invocations across the bus actor.
    private actor HandlerCallCounter {
        /// Number of handler invocations observed.
        private(set) var count = 0

        /// Records one invocation.
        func increment() {
            count += 1
        }
    }
}

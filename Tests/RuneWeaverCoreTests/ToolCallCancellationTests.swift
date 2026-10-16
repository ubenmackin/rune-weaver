// Rune Weaver Core Tests — Per-call tool cancellation race and session scoping.

import Foundation
@testable import RuneWeaverCore
import Testing

/// Fan-in gate letting a test suspend until one or more blocked tool calls have
/// reached their blocking point, so a cancel is issued only after the call is
/// actually registered on the bus.
private actor CallStartGate {
    /// One parked waiter and the start count it is waiting for.
    private struct Waiter: Sendable {
        /// Number of starts that satisfies this waiter.
        let target: Int
        /// Continuation resumed once the target is reached.
        let continuation: CheckedContinuation<Void, Never>
    }

    private var started = 0
    private var waiters: [Waiter] = []

    /// Records one tool call reaching its blocking point.
    func markStarted() {
        started += 1
        let ready = waiters.filter { $0.target <= started }
        waiters.removeAll { $0.target <= started }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }

    /// Suspends until at least `target` calls have started.
    /// - Parameter target: Number of starts to wait for.
    func waitForStarts(_ target: Int) async {
        guard started < target else { return }
        await withCheckedContinuation { continuation in
            waiters.append(Waiter(target: target, continuation: continuation))
        }
    }
}

/// Parks inside `execute` until cooperative cancellation, so a per-call cancel
/// deterministically races an unsettled tool instead of losing to a fast finish.
private struct BlockingStubTool: Tool, Sendable {
    /// Registered tool name.
    let name: String
    /// Gate notified once the call is blocked and therefore cancellable.
    let started: CallStartGate
    /// Read-only so no approval handler is needed for these fixtures.
    let permissionLevel = PermissionLevel.readOnly
    /// Empty-object schema.
    let inputSchema = JSONSchema(rawValue: #"{"type":"object"}"#)

    /// Human-readable description.
    var description: String {
        "Blocks until cancelled."
    }

    /// Signals that the call is live, then sleeps until the bus cancels the task.
    func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        await started.markStarted()
        try await Task.sleep(nanoseconds: 5_000_000_000)
        return .success("finished", callID: input.callID)
    }
}

/// Returns immediately so its slot settles before any cancel can win.
private struct ImmediateStubTool: Tool, Sendable {
    /// Registered tool name.
    let name: String
    /// Read-only so no approval handler is needed.
    let permissionLevel = PermissionLevel.readOnly
    /// Empty-object schema.
    let inputSchema = JSONSchema(rawValue: #"{"type":"object"}"#)

    /// Human-readable description.
    var description: String {
        "Finishes immediately."
    }

    /// Returns a canned success without suspending.
    func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        .success("done", callID: input.callID)
    }
}

@Suite("Tool Call Cancellation")
struct ToolCallCancellationTests {
    @Test
    func `Cancel wins the race and injects a cancellation failure`() async {
        let bus = ToolBus()
        let started = CallStartGate()
        await bus.register(tool: BlockingStubTool(name: "stub.block", started: started))
        let sessionID = UUID()
        let callID = "call_block"
        let running = Task {
            await bus.execute(
                toolCall: ToolInput(toolName: "stub.block", argumentsJSON: "{}", callID: callID),
                context: ToolContext(conversationID: sessionID)
            )
        }
        await started.waitForStarts(1)

        let cancelled = await bus.cancelToolCall(callID: callID, sessionID: sessionID, reason: "user said stop")
        #expect(cancelled == true)

        let result = await running.value
        // The turn receives the abort as the tool's own failure, not as a
        // thrown error, so it can re-scope and keep running.
        #expect(result.isError == true)
        #expect(result.errorKind == .executionError)
        #expect(result.toolCallID == callID)
        #expect(result.content.contains("cancelled by user"))
        #expect(result.content.contains("user said stop"))

        // A second cancel for the same call is a clean miss: the slot is gone
        // and the cancellation is never reported twice.
        #expect(await bus.cancelToolCall(callID: callID, sessionID: sessionID, reason: nil) == false)
    }

    @Test
    func `Settled call refuses a late cancel`() async {
        let bus = ToolBus()
        await bus.register(tool: ImmediateStubTool(name: "stub.now"))
        let sessionID = UUID()
        let result = await bus.execute(
            toolCall: ToolInput(toolName: "stub.now", argumentsJSON: "{}", callID: "call_done"),
            context: ToolContext(conversationID: sessionID)
        )
        #expect(result.isError == false)
        #expect(result.content == "done")

        // The call already returned and released its slot, so a cancel arriving
        // afterwards must not fabricate a cancellation for a finished call.
        let cancelled = await bus.cancelToolCall(callID: "call_done", sessionID: sessionID, reason: "too late")
        #expect(cancelled == false)
    }

    @Test
    func `Session-mismatched cancel leaves the call running`() async {
        let bus = ToolBus()
        let started = CallStartGate()
        await bus.register(tool: BlockingStubTool(name: "stub.block", started: started))
        let owner = UUID()
        let stranger = UUID()
        let callID = "call_owned"
        let running = Task {
            await bus.execute(
                toolCall: ToolInput(toolName: "stub.block", argumentsJSON: "{}", callID: callID),
                context: ToolContext(conversationID: owner)
            )
        }
        await started.waitForStarts(1)

        // A cancel from any other session is scoped out, so it neither aborts
        // the call nor consumes its slot.
        #expect(await bus.cancelToolCall(callID: callID, sessionID: stranger, reason: nil) == false)

        // Only the owning session can stop it, proving the slot survived the miss.
        #expect(await bus.cancelToolCall(callID: callID, sessionID: owner, reason: nil) == true)
        let result = await running.value
        #expect(result.isError == true)
        #expect(result.content.contains("cancelled by user"))
    }

    @Test
    func `Colliding call IDs in different sessions stay independently cancellable`() async {
        let bus = ToolBus()
        let started = CallStartGate()
        await bus.register(tool: BlockingStubTool(name: "stub.block", started: started))
        let sessionA = UUID()
        let sessionB = UUID()
        // A model minting identifiers per turn can legitimately reuse the same
        // call ID across sessions, so the registry must key on the session too.
        let callID = "call_collision"
        let runningA = Task {
            await bus.execute(
                toolCall: ToolInput(toolName: "stub.block", argumentsJSON: "{}", callID: callID),
                context: ToolContext(conversationID: sessionA)
            )
        }
        let runningB = Task {
            await bus.execute(
                toolCall: ToolInput(toolName: "stub.block", argumentsJSON: "{}", callID: callID),
                context: ToolContext(conversationID: sessionB)
            )
        }
        await started.waitForStarts(2)

        // Cancelling A must leave B's identically named slot untouched; keying
        // on the identifier alone would have overwritten B when A registered.
        #expect(await bus.cancelToolCall(callID: callID, sessionID: sessionA, reason: nil) == true)
        let resultA = await runningA.value
        #expect(resultA.isError == true)

        // B is still live and needs its own session-scoped cancel to end.
        #expect(await bus.cancelToolCall(callID: callID, sessionID: sessionB, reason: nil) == true)
        let resultB = await runningB.value
        #expect(resultB.isError == true)
    }

    @Test
    func `Blank and unknown identifiers are clean misses`() async {
        let bus = ToolBus()
        await bus.register(tool: BlockingStubTool(name: "stub.block", started: CallStartGate()))
        // A blank identifier can never match a registered call, so it is
        // rejected before any lookup rather than aborting an arbitrary one.
        #expect(await bus.cancelToolCall(callID: "   ", sessionID: UUID(), reason: nil) == false)
        // An identifier no call carries is a miss, not an error.
        #expect(await bus.cancelToolCall(callID: "never-running", sessionID: UUID(), reason: nil) == false)
    }

    @Test
    func `Cancel reason is capped before it reaches the model`() async {
        let bus = ToolBus()
        let started = CallStartGate()
        await bus.register(tool: BlockingStubTool(name: "stub.block", started: started))
        let sessionID = UUID()
        let callID = "call_reason"
        let running = Task {
            await bus.execute(
                toolCall: ToolInput(toolName: "stub.block", argumentsJSON: "{}", callID: callID),
                context: ToolContext(conversationID: sessionID)
            )
        }
        await started.waitForStarts(1)

        let overflow = String(repeating: "x", count: OrchestratorToolLoop.maxToolCancelReasonLength + 200)
        #expect(await bus.cancelToolCall(callID: callID, sessionID: sessionID, reason: overflow) == true)

        let result = await running.value
        // The reason flows straight back into tool history, so the cap must
        // bound prompt growth even when a caller supplies a wall of text.
        #expect(result.content.contains(String(repeating: "x", count: OrchestratorToolLoop.maxToolCancelReasonLength)))
        #expect(result.content.contains(String(repeating: "x", count: OrchestratorToolLoop.maxToolCancelReasonLength + 1)) == false)
    }
}

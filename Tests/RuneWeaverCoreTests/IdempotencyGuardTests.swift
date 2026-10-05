// Rune Weaver Core — Idempotency safeguard tests.
// Exercises the UncertainActionTracker and ToolBus idempotency guard behavior to verify
// that unconfirmed or timed-out mutating actions block immediate identical retries until
// state verification occurs.

import Foundation
import os
@testable import RuneWeaverCore
import Testing

@Suite("Idempotency Safeguard Tests")
struct IdempotencyGuardTests {
    private struct MockMutatingTool: Tool, Sendable {
        let name: String
        let description = "Mock mutating tool for idempotency testing"
        let inputSchema = JSONSchema(rawValue: #"{"type":"object"}"#)
        let permissionLevel = PermissionLevel.trusted
        let shouldTimeout: @Sendable () -> Bool

        func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
            if shouldTimeout() {
                return .failure("Connection timed out after 30 seconds", callID: input.callID)
            }
            return .success("Action performed successfully", callID: input.callID)
        }
    }

    private struct MockReadTool: Tool, Sendable {
        let name = "files.read"
        let description = "Mock read-only tool"
        let inputSchema = JSONSchema(rawValue: #"{"type":"object"}"#)
        let permissionLevel = PermissionLevel.readOnly

        func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
            .success("Read data content", callID: input.callID)
        }
    }

    @Test
    func `tracker records and blocks identical mutating action within TTL`() async {
        let tracker = UncertainActionTracker(ttl: 60)
        let tool = "files.write"
        let args = #"{"path":"/tmp/test.txt","content":"hello"}"#

        #expect(await tracker.isBlocked(toolName: tool, argumentsJSON: args) == false)

        await tracker.recordUncertain(toolName: tool, argumentsJSON: args)
        #expect(await tracker.isBlocked(toolName: tool, argumentsJSON: args) == true)

        // Different arguments are not blocked
        let diffArgs = #"{"path":"/tmp/other.txt","content":"hello"}"#
        #expect(await tracker.isBlocked(toolName: tool, argumentsJSON: diffArgs) == false)

        // Read-only tools are never considered mutating or blocked
        #expect(await tracker.isBlocked(toolName: "files.read", argumentsJSON: args) == false)

        // Clearing removes the block
        await tracker.clear(toolName: tool, argumentsJSON: args)
        #expect(await tracker.isBlocked(toolName: tool, argumentsJSON: args) == false)
    }

    private final class TimeoutFlag: Sendable {
        private let state = OSAllocatedUnfairLock(initialState: true)

        var willTimeout: Bool {
            get { state.withLock { $0 } }
            set { state.withLock { $0 = newValue } }
        }
    }

    @Test
    func `toolBus intercepts timed out mutating tool and blocks duplicate retry`() async {
        let flag = TimeoutFlag()
        let mockTool = MockMutatingTool(name: "files.write") {
            flag.willTimeout
        }

        let tracker = UncertainActionTracker(ttl: 300)
        let bus = ToolBus(uncertainTracker: tracker)
        await bus.register(tool: mockTool)

        let sessionID = UUID()
        let call = ToolInput(toolName: "files.write", argumentsJSON: #"{"path":"/tmp/idempotent.txt"}"#)
        let context = ToolContext(conversationID: sessionID)

        // First attempt times out
        let result1 = await bus.execute(toolCall: call, context: context)
        #expect(result1.isError == true)
        #expect(result1.errorKind == .uncertainOutcome)
        #expect(result1.content.contains("REFUSED (IDEMPOTENCY_GUARD)"))

        // Second attempt is blocked immediately by idempotency safeguard without re-executing
        let result2 = await bus.execute(toolCall: call, context: context)
        #expect(result2.isError == true)
        #expect(result2.errorKind == .idempotencyBlocked)
        #expect(result2.content.contains("Identical mutating action 'files.write' was previously executed with uncertain outcome"))

        // After clearing (or state verification), the tool can run again
        await tracker.clear(toolName: call.toolName, argumentsJSON: call.argumentsJSON)
        flag.willTimeout = false

        let result3 = await bus.execute(toolCall: call, context: context)
        #expect(result3.isError == false)
        #expect(result3.content == "Action performed successfully")
    }
}

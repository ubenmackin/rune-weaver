// Rune Weaver Tests — End-to-end tool progress emission through the orchestrator.
//
// Protects the wiring that carries a running tool's advisory `ToolProgress` from
// its `ToolContext` sink onto `OrchestratorEvent.toolProgress`. The bus is the
// layer that stamps authoritative call identity, so a tool emits without knowing
// its own call; if the orchestrator constructs a context with the default no-op
// reporter, every report is silently discarded and the dashboard's progress path
// is unreachable even though the wire frame exists.

import Foundation
import os
@testable import RuneWeaverCore
import Testing

/// Read-only fixture that reports one progress frame before returning.
private struct EmittingProgressTool: Tool, Sendable {
    /// Registered tool name.
    let name: String
    /// Human-readable status line carried by the report.
    let message: String
    /// Human-readable description.
    var description: String {
        "Fixture stub for \(name)."
    }

    /// Empty-object schema.
    let inputSchema = JSONSchema(rawValue: #"{"type":"object"}"#)
    /// Always allowed at the gate level.
    let permissionLevel = PermissionLevel.readOnly

    /// Emits a report with no identity of its own so the bus must stamp it.
    func execute(input: ToolInput, context: ToolContext) async throws -> ToolOutput {
        await context.progress(
            ToolProgress(message: message, scanned: 7, matched: 3, elapsedMs: 12, current: "notes/one.txt")
        )
        return .success("ok", callID: input.callID)
    }
}

/// Scripted provider replaying canned response rounds in call order.
private final class ScriptedRoundLLM: LLMProvider, Sendable {
    let modelInfo = ModelInfo(name: "fixture", provider: "test", contextLength: 8192)
    private struct State: Sendable {
        var rounds: [[LLMResponse]]
        var index: Int
    }

    /// Guards script state below.
    private let state: OSAllocatedUnfairLock<State>

    /// Creates a scripted provider.
    /// - Parameter rounds: Canned response chunks per LLM round.
    init(rounds: [[LLMResponse]]) {
        self.state = OSAllocatedUnfairLock(initialState: State(rounds: rounds, index: 0))
    }

    /// Replays the next round as a finished stream.
    func chat(messages _: [Message], tools _: [any Tool]) -> AsyncStream<LLMResponse> {
        let chunks: [LLMResponse] = state.withLock { s in
            guard s.index < s.rounds.count else { return [] }
            let round = s.rounds[s.index]
            s.index += 1
            return round
        }
        return AsyncStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }

    /// Unused embeddings stub.
    /// - Parameter text: Ignored texts.
    /// - Returns: Empty vectors.
    func embeddings(text _: [String]) async throws -> [[Float]] {
        []
    }
}

@Suite("Tool Progress Emission")
struct ToolProgressEmissionTests {
    @Test
    func `Orchestrator forwards tool progress stamped with the call identity`() async throws {
        actor EventCollector {
            var events: [OrchestratorEvent] = []
            func append(_ event: OrchestratorEvent) {
                events.append(event)
            }
        }

        let conversations = ConversationManager()
        let bus = ToolBus()
        await bus.register(tool: EmittingProgressTool(name: "fixture.scan", message: "Scanning files"))
        let round1 = [
            LLMResponse(
                delta: "",
                totalTokens: 10,
                toolCalls: [ToolInput(toolName: "fixture.scan", argumentsJSON: "{}", callID: "call_progress")]
            )
        ]
        let round2 = [LLMResponse(delta: "done", isFinished: true, totalTokens: 5)]
        let orchestrator = Orchestrator(conversations: conversations, toolBus: bus, llm: ScriptedRoundLLM(rounds: [round1, round2]))

        let collector = EventCollector()
        _ = try await orchestrator.process(
            input: UserInput(text: "scan files", sessionID: UUID()),
            onEvent: { event in await collector.append(event) }
        )

        let events = await collector.events
        let progress = try #require(events.compactMap { event -> ToolProgress? in
            if case let .toolProgress(report) = event {
                return report
            }
            return nil
        }.first)
        // The bus owns attribution: the tool emitted a bare report and the event
        // must carry the invoking call's identity for subscribers to correlate it.
        #expect(progress.callID == "call_progress")
        #expect(progress.toolName == "fixture.scan")
        #expect(progress.message == "Scanning files")
        #expect(progress.scanned == 7)
        #expect(progress.matched == 3)
        #expect(progress.elapsedMs == 12)
        #expect(progress.current == "notes/one.txt")
    }
}

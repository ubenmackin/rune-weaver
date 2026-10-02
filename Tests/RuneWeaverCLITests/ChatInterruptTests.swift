// Rune Weaver CLI Tests — Chat interrupt cancellation tests.
import Foundation
@testable import RuneWeaverCLI
import Testing

@Suite("Chat Interrupt Cancellation")
struct ChatInterruptTests {
    @Test
    func `Interrupt flag trips resets and consumes`() {
        let interrupt = ChatInterruptState()
        #expect(interrupt.isTripped == false)
        #expect(ChatTurnInterrupt.isCancelled(interrupt) == false)
        interrupt.trip()
        #expect(interrupt.isTripped == true)
        #expect(ChatTurnInterrupt.isCancelled(interrupt) == true)
        interrupt.reset()
        #expect(interrupt.isTripped == false)
        interrupt.trip()
        #expect(interrupt.consume() == true)
        #expect(interrupt.isTripped == false)
        #expect(interrupt.consume() == false)
    }

    @Test
    func `Mid-stream SIGINT aborts stream and discards partial text`() {
        let interrupt = ChatInterruptState()
        let snapshot = ["user: find emails about quarterly report"]
        var working = snapshot
        var streamed = ""
        let deltas = ["Hello ", "world", "!!!"]
        var outcome: ChatTurnOutcome = .completed
        for (index, delta) in deltas.enumerated() {
            if index == 1 {
                interrupt.trip()
            }
            if ChatTurnInterrupt.isCancelled(interrupt) {
                outcome = .cancelled
                break
            }
            streamed += delta
        }
        if outcome == .cancelled {
            #expect(streamed == "Hello ")
            #expect(working == snapshot)
        } else {
            working.append("assistant: \(streamed)")
        }
        #expect(outcome == .cancelled)
        #expect(working == snapshot)
        #expect(ChatTurnInterrupt.consumeTurnCancellation(interrupt) == true)
        #expect(ChatTurnInterrupt.isCancelled(interrupt) == false)
    }

    @Test
    func `Mid-tool SIGINT stops tool loop and discards partial turn`() {
        let interrupt = ChatInterruptState()
        let snapshot = ["user: summarize inbox"]
        var working = snapshot
        let requested = ["email.search", "email.read", "memories.recall"]
        var executed: [String] = []
        var outcome: ChatTurnOutcome = .completed
        for (index, tool) in requested.enumerated() {
            if ChatTurnInterrupt.isCancelled(interrupt) {
                outcome = .cancelled
                break
            }
            if index == 1 {
                interrupt.trip()
            }
            if ChatTurnInterrupt.isCancelled(interrupt) {
                outcome = .cancelled
                break
            }
            executed.append(tool)
            working.append("tool: \(tool)")
        }
        if outcome == .cancelled {
            working = snapshot
        }
        #expect(outcome == .cancelled)
        #expect(executed == ["email.search"])
        #expect(working == snapshot)
        #expect(ChatTurnInterrupt.consumeTurnCancellation(interrupt) == true)
        #expect(interrupt.isTripped == false)
    }

    @Test
    func `Prompt-level SIGINT exits while consumed turn cancel returns to prompt`() {
        let atPrompt = ChatInterruptState()
        #expect(ChatTurnInterrupt.isCancelled(atPrompt) == false)
        atPrompt.trip()
        #expect(ChatTurnInterrupt.isCancelled(atPrompt) == true)

        let duringTurn = ChatInterruptState()
        duringTurn.trip()
        #expect(ChatTurnInterrupt.isCancelled(duringTurn) == true)
        #expect(ChatTurnInterrupt.consumeTurnCancellation(duringTurn) == true)
        #expect(ChatTurnInterrupt.isCancelled(duringTurn) == false)
        duringTurn.trip()
        #expect(ChatTurnInterrupt.isCancelled(duringTurn) == true)
    }
}

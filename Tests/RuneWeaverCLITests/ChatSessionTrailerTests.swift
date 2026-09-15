// Rune Weaver CLI Tests — Chat session trailer formatting and token counter tests.

import Foundation
@testable import RuneWeaverCLI
import Testing

@Suite("Chat Session Trailer")
struct ChatSessionTrailerTests {
    @Test
    func `Trailer prints with nil turn usage without advancing counter`() {
        let counter = CLILockedValue(12408)
        let line = ChatSessionTrailer.line(
            modelName: "gpt-4o-mini",
            sessionTokens: counter,
            turnTotalTokens: nil,
            window: 1_000_000
        )
        #expect(!line.isEmpty)
        #expect(line == "(gpt-4o-mini · 12408/1000000, 1%)")
        #expect(counter.withLock { $0 } == 12408)
    }

    @Test
    func `Trailer accumulates turn usage across turns`() {
        let counter = CLILockedValue(0)
        let first = ChatSessionTrailer.line(
            modelName: "gpt-4o-mini",
            sessionTokens: counter,
            turnTotalTokens: 10000,
            window: 1_000_000
        )
        #expect(counter.withLock { $0 } == 10000)
        #expect(first == "(gpt-4o-mini · 10000/1000000, 1%)")

        let second = ChatSessionTrailer.line(
            modelName: "gpt-4o-mini",
            sessionTokens: counter,
            turnTotalTokens: 2408,
            window: 1_000_000
        )
        #expect(counter.withLock { $0 } == 12408)
        #expect(second == "(gpt-4o-mini · 12408/1000000, 1%)")

        let third = ChatSessionTrailer.line(
            modelName: "gpt-4o-mini",
            sessionTokens: counter,
            turnTotalTokens: nil,
            window: 1_000_000
        )
        #expect(counter.withLock { $0 } == 12408)
        #expect(third == "(gpt-4o-mini · 12408/1000000, 1%)")
    }
}

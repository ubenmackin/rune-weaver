// Rune Weaver App Tests — AppModel quit lifecycle and SearXNG auto-stop.

import Foundation
import os
@testable import RuneWeaverApp
@testable import RuneWeaverCore
@testable import RuneWeaverTools
import Testing

private final class MockSearXNGEnsurer: SearXNGEnsuring, Sendable {
    private struct State: Sendable {
        var ensureCallCount = 0
        var stopCallCount = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var ensureCallCount: Int {
        state.withLock { $0.ensureCallCount }
    }

    var stopCallCount: Int {
        state.withLock { $0.stopCallCount }
    }

    func ensure(browser _: BrowserConfig) async throws {
        state.withLock { $0.ensureCallCount += 1 }
    }

    func stop() async {
        state.withLock { $0.stopCallCount += 1 }
    }
}

@Suite("AppModel quit lifecycle")
@MainActor
struct AppModelQuitTests {
    @Test
    func `stopForQuit invokes search ensurer stop and is idempotent`() async {
        let mock = MockSearXNGEnsurer()
        let model = AppModel(searchEnsurer: mock, onTerminate: {})
        #expect(model.isTerminated == false)
        #expect(mock.stopCallCount == 0)

        await model.stopForQuit()

        #expect(model.isTerminated == true)
        #expect(mock.stopCallCount == 1)

        // Idempotency: second call must not invoke stop() again
        await model.stopForQuit()
        #expect(mock.stopCallCount == 1)
    }

    @Test
    func `quit triggers stopForQuit and calls onTerminate`() async {
        let mock = MockSearXNGEnsurer()
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let model = AppModel(
            searchEnsurer: mock,
            onTerminate: {
                continuation.yield()
                continuation.finish()
            }
        )
        model.quit()

        for await _ in stream {
            break
        }

        #expect(model.isTerminated == true)
        #expect(mock.stopCallCount == 1)
    }

    @Test
    func `SearXNGEnsuring protocol default stop is callable`() async {
        struct DefaultEnsurer: SearXNGEnsuring {
            func ensure(browser _: BrowserConfig) async throws {}
        }
        let ensurer = DefaultEnsurer()
        await ensurer.stop()
    }
}

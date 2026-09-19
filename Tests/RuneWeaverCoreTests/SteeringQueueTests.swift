// Rune Weaver Tests — Steering queue memory bounds.
// Covers per-session and total caps so a fast steering producer or leaked stream
// registration stays bounded instead of growing the queue without limit.

import Foundation
import os
@testable import RuneWeaverCore
import Testing

/// Synchronous fired flag shared across interrupt callbacks.
private final class FiredFlag: Sendable {
    /// Guarded fired state.
    private let state = OSAllocatedUnfairLock(initialState: false)

    /// Creates an unfired flag.
    init() {}

    /// Marks the flag fired.
    func fire() {
        state.withLock { $0 = true }
    }

    /// Whether the flag has fired.
    var fired: Bool {
        state.withLock { $0 }
    }
}

@Suite("Steering Queue Bounds")
struct SteeringQueueTests {
    @Test
    func `Per-session pending overflow keeps newest guidance`() async {
        let queue = SteeringQueue()
        let sessionID = UUID()
        for index in 0 ..< (SteeringQueue.maxPendingPerSession + 5) {
            await queue.enqueue(text: "msg-\(index)", sessionID: sessionID)
        }
        #expect(await queue.pendingCount(for: sessionID) == SteeringQueue.maxPendingPerSession)
        // Oldest five shed so the queue stays pinned to the latest direction.
        #expect(await queue.dequeue(for: sessionID) == "msg-5")
    }

    @Test
    func `Drained sessions release their slot`() async {
        let queue = SteeringQueue()
        let sessionID = UUID()
        await queue.enqueue(text: "pivot", sessionID: sessionID)
        _ = await queue.dequeue(for: sessionID)
        #expect(await queue.pendingSessionCount() == 0)
        #expect(await queue.hasSteer(for: sessionID) == false)

        await queue.enqueue(text: "pivot", sessionID: sessionID)
        await queue.clear(for: sessionID)
        #expect(await queue.pendingSessionCount() == 0)
    }

    @Test
    func `Per-session interrupt overflow evicts oldest callback`() async {
        let queue = SteeringQueue()
        let sessionID = UUID()
        let oldestFired = FiredFlag()
        let newestFired = FiredFlag()
        _ = await queue.registerInterrupt(sessionID: sessionID) { oldestFired.fire() }
        for _ in 1 ..< SteeringQueue.maxInterruptsPerSession {
            _ = await queue.registerInterrupt(sessionID: sessionID) {}
        }
        _ = await queue.registerInterrupt(sessionID: sessionID) { newestFired.fire() }
        #expect(await queue.interruptCount(for: sessionID) == SteeringQueue.maxInterruptsPerSession)
        await queue.enqueue(text: "pivot", sessionID: sessionID)
        // The first registration shed so the live stream callback survives.
        #expect(oldestFired.fired == false)
        #expect(newestFired.fired == true)
    }

    @Test
    func `Session overflow evicts least-recently-touched session`() async {
        let queue = SteeringQueue()
        let oldest = UUID()
        await queue.enqueue(text: "first", sessionID: oldest)
        for _ in 0 ..< SteeringQueue.maxTrackedSessions {
            await queue.enqueue(text: "pivot", sessionID: UUID())
        }
        #expect(await queue.pendingSessionCount() == SteeringQueue.maxTrackedSessions)
        // The earliest writer evicts so active sessions keep their steering.
        #expect(await queue.hasSteer(for: oldest) == false)
    }
}

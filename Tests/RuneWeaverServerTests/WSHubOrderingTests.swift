// Rune Weaver Tests — WebSocket hub per-socket frame ordering.

import Foundation
import NIOWebSocket
import RuneWeaverCore
@testable import RuneWeaverServer
import Testing

/// Test double for a hub socket whose send sleeps a configurable delay before
/// recording, so out-of-order send completion on one socket is observable.
private actor DelayedRecordingSocket: WSConnectionSocket {
    /// Text frames the hub delivered to this socket, in delivery order.
    private(set) var sent: [String] = []
    /// Whether the hub closed this connection.
    private(set) var closed = false
    /// Delay each send sleeps for; read at send start so a later edit never shortens an in-flight send.
    private var delayNanoseconds: UInt64 = 0

    /// Adjusts the delay future sends will sleep for.
    func setDelay(_ nanoseconds: UInt64) {
        delayNanoseconds = nanoseconds
    }

    func send(_ text: String) async throws {
        let delay = delayNanoseconds
        if delay > 0 {
            try? await Task.sleep(nanoseconds: delay)
        }
        sent.append(text)
    }

    func close(code _: WebSocketErrorCode) async throws {
        closed = true
    }
}

@Suite("WebSocket Hub Ordering")
struct WSHubOrderingTests {
    @Test
    func `Frames on one socket arrive in call order even when a later send completes sooner`() async {
        let hub = WSHub()
        let socket = DelayedRecordingSocket()
        let id = UUID()
        _ = await hub.add(id: id, box: socket)

        await socket.setDelay(300_000_000)
        let first = Task { await hub.broadcast(text: "first") }
        // Let the first send reach the socket before the second is issued with no delay.
        try? await Task.sleep(nanoseconds: 50_000_000)
        await socket.setDelay(0)
        let second = Task { await hub.broadcast(text: "second") }
        await first.value
        await second.value

        #expect(await socket.sent == ["first", "second"])
    }

    @Test
    func `tool_progress is delivered before any frame the producer broadcasts after it`() async {
        let hub = WSHub()
        let socket = DelayedRecordingSocket()
        let sessionID = UUID()
        _ = await hub.add(id: UUID(), box: socket)

        await socket.setDelay(300_000_000)
        await broadcastWSEventFrame(
            .toolProgress(ToolProgress(callID: "call-1", toolName: "files.grep", message: "scanning")),
            sessionID: sessionID,
            hub: hub
        )
        await socket.setDelay(0)
        await broadcastWSEventFrame(.textDelta("partial"), sessionID: sessionID, hub: hub)

        let frameTypes = await socket.sent.compactMap { frame in
            (try? JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])
                .flatMap { $0["type"] as? String }
        }
        #expect(frameTypes == ["tool_progress", "delta"])
    }

    @Test
    func `A caller cancelled while queued is skipped without reordering later frames`() async {
        let hub = WSHub()
        let socket = DelayedRecordingSocket()
        let id = UUID()
        _ = await hub.add(id: id, box: socket)

        await socket.setDelay(300_000_000)
        let first = Task { await hub.broadcast(text: "first") }
        try? await Task.sleep(nanoseconds: 50_000_000)

        let queued = Task { await hub.broadcast(text: "queued") }
        // Give the queued send time to chain behind the in-flight one, then cancel its caller.
        try? await Task.sleep(nanoseconds: 20_000_000)
        queued.cancel()

        await socket.setDelay(0)
        let third = Task { await hub.broadcast(text: "third") }
        await first.value
        await queued.value
        await third.value

        #expect(await socket.sent == ["first", "third"])
        // The failed send prunes the connection, matching the hub's failed-send contract.
        #expect(await hub.count() == 0)
    }
}

// Rune Weaver Server — WebSocket socket plumbing and broadcast hub.
//
// Owns the per-connection socket box, the serialized per-connection send
// queue with its per-send timeout, and the hub fanning approval prompts,
// run events, and stream frames out to live sockets. Kept apart from the
// route surface so each file stays focused on one layer: this file moves
// bytes, while the service file owns routes and request handling.

import Foundation
import NIOWebSocket
import os
import RuneWeaverCore
import Vapor

/// Actor box for Vapor `WebSocket`.
public actor WSSocketBox {
    /// Wrapped socket.
    public let socket: WebSocket

    /// Wraps a socket.
    /// - Parameter socket: Connected socket.
    public init(_ socket: WebSocket) {
        self.socket = socket
    }

    /// Sends a text frame.
    public func send(_ text: String) async throws {
        try await socket.send(text)
    }

    /// Closes the socket cleanly.
    public func close(code: WebSocketErrorCode = .goingAway) async throws {
        try await socket.close(code: code)
    }
}

/// One-shot gate ensuring a WebSocket send continuation resumes exactly once.
private final class WSResumeOnce: Sendable {
    private struct State: Sendable {
        var continuation: CheckedContinuation<Void, Never>?
        var didResume = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Creates a gate holding a continuation.
    /// - Parameter continuation: Continuation to resume once.
    init(_ continuation: CheckedContinuation<Void, Never>) {
        state.withLock { $0.continuation = continuation }
    }

    /// Resumes the held continuation unless already resumed.
    func resume() {
        let cont = state.withLock { lockState -> CheckedContinuation<Void, Never>? in
            guard !lockState.didResume else { return nil }
            lockState.didResume = true
            let continuation = lockState.continuation
            lockState.continuation = nil
            return continuation
        }
        cont?.resume()
    }
}

/// Serializes outbound frames for one WebSocket connection.
private actor WSSendQueue {
    /// Sends one frame through the queue, best-effort with timeout.
    func send(_ text: String, to box: WSSocketBox) async {
        await wsSendWithTimeout(text, to: box)
    }
}

/// Live WebSocket connections for approval broadcasts.
public actor WSHub {
    /// Connected sockets indexed by connection identifier.
    private var sockets: [UUID: WSSocketBox] = [:]
    /// Per-connection send queues preserving frame order per socket.
    private var queues: [UUID: WSSendQueue] = [:]

    /// Creates an empty hub.
    public init() {}

    /// Registers an already-boxed socket without crossing the actor
    /// boundary with a non-`Sendable` value.
    public func add(id: UUID, box: WSSocketBox) {
        sockets[id] = box
        if queues[id] == nil {
            queues[id] = WSSendQueue()
        }
    }

    /// Unregisters a socket. Unknown identifiers are a no-op.
    /// - Parameter id: Connection identifier.
    public func remove(id: UUID) {
        sockets.removeValue(forKey: id)
        queues.removeValue(forKey: id)
    }

    /// Number of connected sockets.
    /// - Returns: Connection count.
    public func count() -> Int {
        sockets.count
    }

    /// Closes and drains all connected sockets cleanly on server shutdown.
    public func closeAll() async {
        let targets = Array(sockets.values)
        sockets.removeAll()
        queues.removeAll()
        for box in targets {
            _ = try? await box.close(code: .goingAway)
        }
    }

    /// Queue for a connection, creating it when missing.
    /// - Parameter id: Connection identifier.
    /// - Returns: Serial sender for the connection.
    private func queue(for id: UUID) -> WSSendQueue {
        if let existing = queues[id] {
            return existing
        }
        let created = WSSendQueue()
        queues[id] = created
        return created
    }

    /// Broadcasts one approval prompt to every connected socket.
    public func broadcastApproval(_ request: PermissionRequest) async {
        guard let data = try? JSONEncoder().encode(WSApprovalPrompt(request: request)),
              let text = String(data: data, encoding: .utf8)
        else { return }
        await fanOut(text)
    }

    /// Broadcasts a run log event (started or completed) to every connected socket.
    public func broadcastRun(_ run: RunLogEntry) async {
        struct WSRunEvent: Codable {
            let type: String
            let run: RunLogEntry
        }
        let eventType = (run.status == "running" || run.status == "awaiting_approval") ? "run_started" : "run_completed"
        guard let data = try? JSONEncoder().encode(WSRunEvent(type: eventType, run: run)),
              let text = String(data: data, encoding: .utf8)
        else { return }
        await fanOut(text)
    }

    /// Broadcasts an arbitrary text frame to every connected socket.
    public func broadcast(text: String) async {
        await fanOut(text)
    }

    /// Concurrent best-effort fan-out shared by every broadcast path.
    private func fanOut(_ text: String) async {
        let targets: [(WSSendQueue, WSSocketBox)] = sockets.map { (queue(for: $0.key), $0.value) }
        await withTaskGroup(of: Void.self) { group in
            for (queue, box) in targets {
                group.addTask {
                    await queue.send(text, to: box)
                }
            }
        }
    }

    /// Sends one text frame to the connection with the given identifier.
    public func send(id: UUID, text: String) async {
        guard let box = sockets[id] else { return }
        await queue(for: id).send(text, to: box)
    }
}

/// Holds one side of the timeout race.
private final class WSSendTaskHolder: Sendable {
    private let task = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    init() {}

    func set(_ newTask: Task<Void, Never>) {
        task.withLock { $0 = newTask }
    }

    func cancel() {
        let current = task.withLock { $0 }
        current?.cancel()
    }
}

private final class WSResumeOnceBox: Sendable {
    private let gate = OSAllocatedUnfairLock<WSResumeOnce?>(initialState: nil)

    init() {}

    func set(_ newGate: WSResumeOnce) {
        gate.withLock { $0 = newGate }
    }

    func resume() {
        let current = gate.withLock { $0 }
        current?.resume()
    }
}

/// Sends one WebSocket text frame with a per-send timeout, best-effort.
private func wsSendWithTimeout(_ text: String, to box: WSSocketBox, timeoutNanoseconds: UInt64 = 5_000_000_000) async {
    let onceBox = WSResumeOnceBox()
    let sendHolder = WSSendTaskHolder()
    let timeoutHolder = WSSendTaskHolder()
    await withTaskCancellationHandler {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = WSResumeOnce(continuation)
            onceBox.set(once)
            let timeoutTask = Task { [once, sendHolder] in
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                } catch {
                    return
                }
                sendHolder.cancel()
                once.resume()
            }
            timeoutHolder.set(timeoutTask)
            let sendTask = Task { [once, box, text, timeoutHolder] in
                try? await box.send(text)
                timeoutHolder.cancel()
                once.resume()
            }
            sendHolder.set(sendTask)
            if Task.isCancelled {
                timeoutHolder.cancel()
                sendHolder.cancel()
                once.resume()
            }
        }
    } onCancel: {
        timeoutHolder.cancel()
        sendHolder.cancel()
        onceBox.resume()
    }
}

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

/// Socket surface the hub needs to move bytes and drop a connection.
///
/// Tracking connections behind this seam keeps the hub independent of the
/// concrete Vapor socket, so revocation (a rotation closing retired sockets)
/// stays observable in tests without a live network handshake.
public protocol WSConnectionSocket: Sendable {
    /// Sends one text frame.
    func send(_ text: String) async throws
    /// Closes the connection with a status code.
    func close(code: WebSocketErrorCode) async throws
}

/// Actor box for Vapor `WebSocket`.
public actor WSSocketBox: WSConnectionSocket {
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

/// Serializes outbound frames for one WebSocket connection.
private actor WSSendQueue {
    /// Sends one frame through the queue, best-effort with timeout.
    func send(_ text: String, to box: any WSConnectionSocket) async {
        await wsSendWithTimeout(text, to: box)
    }
}

/// One registered connection plus the token generation it authenticated under.
private struct RegisteredConnection: Sendable {
    /// Socket used to move bytes and drop the connection.
    let box: any WSConnectionSocket
    /// Token generation captured at upgrade, or nil for the ungated loopback
    /// posture where no rotation can ever retire the connection.
    let generation: Int?
}

/// Live WebSocket connections for approval broadcasts.
public actor WSHub {
    /// Connected sockets indexed by connection identifier.
    private var sockets: [UUID: RegisteredConnection] = [:]
    /// Per-connection send queues preserving frame order per socket.
    private var queues: [UUID: WSSendQueue] = [:]
    /// Lowest token generation still allowed to send or receive.
    ///
    /// Rotation raises this watermark in the same hop that sweeps the hub, so a
    /// socket whose generation is already known to be retired is neither fanned
    /// out to nor allowed to register late. It only ever advances, so a second
    /// rotation racing the first cannot lower it back onto a retired credential.
    private var minimumLiveGeneration: Int?

    /// Creates an empty hub.
    public init() {}

    /// Registers an already-boxed socket without crossing the actor
    /// boundary with a non-`Sendable` value.
    ///
    /// A registration that lands after its own generation was retired is
    /// refused rather than stored: the rotation already swept the hub, so
    /// accepting it would let a socket holding the retired credential linger
    /// and keep receiving broadcasts. The caller must close a refused socket.
    /// - Parameters:
    ///   - id: Connection identifier.
    ///   - box: Socket surface used to move bytes and drop the connection.
    ///   - generation: Generation captured at upgrade, or nil for the ungated
    ///     loopback posture that rotation never retires.
    /// - Returns: True when the socket is registered, false when its generation
    ///   is already retired.
    @discardableResult
    public func add(id: UUID, box: any WSConnectionSocket, generation: Int? = nil) -> Bool {
        guard !isRetired(generation) else { return false }
        sockets[id] = RegisteredConnection(box: box, generation: generation)
        if queues[id] == nil {
            queues[id] = WSSendQueue()
        }
        return true
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
        let targets = sockets.values.map(\.box)
        sockets.removeAll()
        queues.removeAll()
        for box in targets {
            _ = try? await box.close(code: .goingAway)
        }
    }

    /// Retires every socket bound to a superseded token generation.
    ///
    /// Called once the replacement token is live, so a socket that upgraded
    /// under the retired credential is dropped here even when it would
    /// otherwise sit passive and never trip the per-frame generation check.
    /// Raising the watermark and draining in the same actor hop keeps the
    /// revocation atomic against registration and fan-out: a socket can be
    /// refused, closed, or filtered, but never both registered and delivered to
    /// under a generation the hub already knows is retired. The watermark is
    /// anchored to the generation current *after* the swap and only ever
    /// advances, so overlapping rotations cannot lower it onto a retired
    /// credential.
    /// - Parameter liveGeneration: Generation that is current after the rotation.
    public func retire(liveGeneration: Int) async {
        minimumLiveGeneration = max(minimumLiveGeneration ?? 0, liveGeneration)
        for box in drainRetired() {
            _ = try? await box.close(code: .policyViolation)
        }
    }

    /// Removes and returns every socket whose generation is no longer live.
    private func drainRetired() -> [any WSConnectionSocket] {
        let staleIDs = sockets.compactMap { id, connection in
            isRetired(connection.generation) ? id : nil
        }
        var targets: [any WSConnectionSocket] = []
        for id in staleIDs {
            if let box = sockets.removeValue(forKey: id)?.box {
                targets.append(box)
            }
            queues.removeValue(forKey: id)
        }
        return targets
    }

    /// Whether a socket generation sits below the live watermark.
    ///
    /// Before the first rotation no watermark exists, so every registration is
    /// live; afterwards a nil generation is the ungated posture, which a hub
    /// that just retired a token can no longer trust either.
    /// - Parameter generation: Generation to test, or nil when unauthenticated.
    /// - Returns: True when the generation is known to be superseded.
    private func isRetired(_ generation: Int?) -> Bool {
        guard let minimumLiveGeneration else { return false }
        guard let generation else { return true }
        return generation < minimumLiveGeneration
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
        // Only a live `running` turn keeps the session badge lit. A parked
        // `awaiting_approval` turn lands as completed so live and polled views
        // agree; the approvals badge carries the wait instead of double-badging
        // one blocked turn, matching the dashboard active-status filter.
        let eventType = run.status == "running" ? "run_started" : "run_completed"
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
        // A socket the hub already knows holds a retired generation is skipped
        // here, so revocation does not depend on the socket sending a frame to
        // discover it was dropped.
        let targets: [(WSSendQueue, any WSConnectionSocket)] = sockets.compactMap { id, connection in
            guard !isRetired(connection.generation) else { return nil }
            return (queue(for: id), connection.box)
        }
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
        guard let connection = sockets[id], !isRetired(connection.generation) else { return }
        await queue(for: id).send(text, to: connection.box)
    }
}

/// Exactly-once gate for one best-effort send.
/// Holds the non-throwing continuation so the send, the timeout, and
/// cancellation race on one shared verdict without a throwing bridge.
/// Invariant: only the first racer resumes; late arrivals are ignored, and a
/// resume racing registration still settles instead of hanging.
private final class WSSendGate: Sendable {
    /// Locked verdict carrying the waiter plus the settled flag.
    private struct State: Sendable {
        /// Waiter to resume once, cleared on settle.
        var continuation: CheckedContinuation<Void, Never>?
        /// Whether a racer already settled the verdict.
        var didResume = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Creates an empty gate awaiting its waiter.
    init() {}

    /// Publishes the waiter, settling immediately when a racer already won.
    func set(_ continuation: CheckedContinuation<Void, Never>) {
        let alreadySettled = state.withLock { lockState -> Bool in
            if lockState.didResume {
                return true
            }
            lockState.continuation = continuation
            return false
        }
        if alreadySettled {
            continuation.resume(returning: ())
        }
    }

    /// Resumes the waiter unless already resumed.
    func resume(returning value: Void = ()) {
        let pending = state.withLock { lockState -> CheckedContinuation<Void, Never>? in
            guard !lockState.didResume else { return nil }
            lockState.didResume = true
            let held = lockState.continuation
            lockState.continuation = nil
            return held
        }
        pending?.resume(returning: value)
    }
}

/// Sends one WebSocket text frame with a per-send timeout, best-effort.
/// The send, the timeout, and cancellation race on one shared verdict so a slow
/// socket arriving after a timeout cannot resume twice; the winner drops its loser
/// so burst sends never stack lingering sleeps. Late arrivals observe the stored
/// outcome instead of racing.
private func wsSendWithTimeout(_ text: String, to box: any WSConnectionSocket, timeoutNanoseconds: UInt64 = 5_000_000_000) async {
    let gate = WSSendGate()
    let sendTasks = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    let timeoutTasks = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    await withTaskCancellationHandler {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            gate.set(continuation)
            let timeoutTask = Task { [gate, sendTasks] in
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                } catch {
                    return
                }
                sendTasks.withLock { $0 }?.cancel()
                gate.resume(returning: ())
            }
            timeoutTasks.withLock { $0 = timeoutTask }
            let sendTask = Task { [gate, box, text, timeoutTasks] in
                try? await box.send(text)
                timeoutTasks.withLock { $0 }?.cancel()
                gate.resume(returning: ())
            }
            sendTasks.withLock { $0 = sendTask }
            if Task.isCancelled {
                timeoutTasks.withLock { $0 }?.cancel()
                sendTasks.withLock { $0 }?.cancel()
                gate.resume(returning: ())
            }
        }
    } onCancel: {
        timeoutTasks.withLock { $0 }?.cancel()
        sendTasks.withLock { $0 }?.cancel()
        gate.resume(returning: ())
    }
}

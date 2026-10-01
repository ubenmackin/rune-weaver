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
    @discardableResult
    func send(_ text: String, to box: any WSConnectionSocket, timeoutNanoseconds: UInt64 = 1_000_000_000) async -> Bool {
        await wsSendWithTimeout(text, to: box, timeoutNanoseconds: timeoutNanoseconds)
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
        let text: String
        do {
            let data = try JSONEncoder().encode(WSApprovalPrompt(request: request))
            guard let encodedText = String(data: data, encoding: .utf8) else { return }
            text = encodedText
        } catch {
            RuneWeaverLog.server.error("WSHub: failed to encode approval prompt: \(error.localizedDescription)")
            return
        }
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
        let text: String
        do {
            let data = try JSONEncoder().encode(WSRunEvent(type: eventType, run: run))
            guard let encodedText = String(data: data, encoding: .utf8) else { return }
            text = encodedText
        } catch {
            RuneWeaverLog.server.error("WSHub: failed to encode run event: \(error.localizedDescription)")
            return
        }
        await fanOut(text)
    }

    /// Broadcasts one goal snapshot to every connected socket.
    ///
    /// The DTO converts to the core snapshot so the REST list and the live push
    /// share one JSON shape: dashboards patch the row in place instead of
    /// refetching after every create, plan-ready, progress, status flip, or
    /// advancement turn.
    /// - Parameter dto: Current goal row with its progress tally.
    public func broadcastGoal(_ dto: GoalDTO) async {
        let text: String
        do {
            let frame = WSGoalUpdatedFrame(goal: dto.wsSnapshot())
            let data = try JSONEncoder().encode(frame)
            guard let encodedText = String(data: data, encoding: .utf8) else { return }
            text = encodedText
        } catch {
            RuneWeaverLog.server.error("WSHub: failed to encode goal_updated frame: \(error.localizedDescription)")
            return
        }
        await fanOut(text)
    }

    /// Broadcasts one proactive nudge to every connected socket.
    ///
    /// Best-effort like every other push: encoding failures log and drop instead
    /// of failing the turn that volunteered the card.
    /// - Parameter frame: Card carrying kind, title, and headline.
    public func broadcastProactiveMessage(_ frame: WSProactiveMessageFrame) async {
        let text: String
        do {
            let data = try JSONEncoder().encode(frame)
            guard let encodedText = String(data: data, encoding: .utf8) else { return }
            text = encodedText
        } catch {
            RuneWeaverLog.server.error("WSHub: failed to encode proactive_message frame: \(error.localizedDescription)")
            return
        }
        await fanOut(text)
    }

    /// Broadcasts one file-review action frame to every connected socket.
    ///
    /// Shared by the staged/live resolution routes and the live-write
    /// supersede hook so every `file_*` frame — `file_accepted`,
    /// `file_discarded`, `file_superseded`, `live_resolved` — encodes through
    /// one path.
    /// - Parameter event: Frame carrying the event type, live path, and
    ///   optional terminal review state.
    public func broadcastFileAction(_ event: WSFileActionEvent) async {
        let text: String
        do {
            let data = try JSONEncoder().encode(event)
            guard let encodedText = String(data: data, encoding: .utf8) else { return }
            text = encodedText
        } catch {
            RuneWeaverLog.server.error("WSHub: failed to encode file action frame: \(error.localizedDescription)")
            return
        }
        await fanOut(text)
    }

    /// Broadcasts an arbitrary text frame to every connected socket.
    public func broadcast(text: String) async {
        await fanOut(text)
    }

    /// Target for fan-out broadcast avoiding large tuples.
    private struct FanOutTarget: Sendable {
        let id: UUID
        let queue: WSSendQueue
        let box: any WSConnectionSocket
    }

    /// Concurrent best-effort fan-out shared by every broadcast path.
    private func fanOut(_ text: String) async {
        // A socket the hub already knows holds a retired generation is skipped
        // here, so revocation does not depend on the socket sending a frame to
        // discover it was dropped.
        let targets = sockets.compactMap { id, connection -> FanOutTarget? in
            guard !isRetired(connection.generation) else { return nil }
            return FanOutTarget(id: id, queue: queue(for: id), box: connection.box)
        }
        var failedIDs: [UUID] = []
        await withTaskGroup(of: (UUID, Bool).self) { group in
            for target in targets {
                group.addTask {
                    let ok = await target.queue.send(text, to: target.box)
                    return (target.id, ok)
                }
            }
            for await (id, ok) in group where !ok {
                failedIDs.append(id)
            }
        }
        for id in failedIDs {
            remove(id: id)
        }
    }

    /// Sends one text frame to the connection with the given identifier.
    public func send(id: UUID, text: String) async {
        guard let connection = sockets[id], !isRetired(connection.generation) else { return }
        let ok = await queue(for: id).send(text, to: connection.box)
        if !ok {
            remove(id: id)
        }
    }
}

/// Exactly-once gate for one best-effort send.
/// Holds the non-throwing continuation so the send, the timeout, and
/// cancellation race on one shared verdict without a throwing bridge.
/// Invariant: only the first racer resumes; late arrivals are ignored, and a
/// resume racing registration still settles instead of hanging.
private final class WSSendGate: Sendable {
    /// Locked verdict carrying the waiter plus the settled outcome.
    private struct State: Sendable {
        /// Waiter to resume once, cleared on settle.
        var continuation: CheckedContinuation<Bool, Never>?
        /// Whether a racer already settled the verdict, and if so, the boolean result.
        var result: Bool?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Creates an empty gate awaiting its waiter.
    init() {}

    /// Publishes the waiter, settling immediately when a racer already won.
    func set(_ continuation: CheckedContinuation<Bool, Never>) {
        let earlyResult = state.withLock { lockState -> Bool? in
            if let result = lockState.result {
                return result
            }
            lockState.continuation = continuation
            return nil
        }
        if let earlyResult {
            continuation.resume(returning: earlyResult)
        }
    }

    /// Resumes the waiter unless already resumed.
    func resume(returning value: Bool) {
        let pending = state.withLock { lockState -> CheckedContinuation<Bool, Never>? in
            guard lockState.result == nil else { return nil }
            lockState.result = value
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
/// outcome instead of racing. Returns true if sent successfully, false if timed out or failed.
private func wsSendWithTimeout(
    _ text: String,
    to box: any WSConnectionSocket,
    timeoutNanoseconds: UInt64 = 1_000_000_000
) async -> Bool {
    let gate = WSSendGate()
    let sendTasks = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    let timeoutTasks = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    return await withTaskCancellationHandler {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            gate.set(continuation)
            let timeoutTask = Task { [gate, sendTasks, box] in
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                } catch {
                    return
                }
                sendTasks.withLock { $0 }?.cancel()
                _ = try? await box.close(code: .policyViolation)
                gate.resume(returning: false)
            }
            timeoutTasks.withLock { $0 = timeoutTask }
            let sendTask = Task { [gate, box, text, timeoutTasks] in
                do {
                    try await box.send(text)
                    timeoutTasks.withLock { $0 }?.cancel()
                    gate.resume(returning: true)
                } catch {
                    timeoutTasks.withLock { $0 }?.cancel()
                    _ = try? await box.close(code: .policyViolation)
                    gate.resume(returning: false)
                }
            }
            sendTasks.withLock { $0 = sendTask }
            if Task.isCancelled {
                timeoutTasks.withLock { $0 }?.cancel()
                sendTasks.withLock { $0 }?.cancel()
                gate.resume(returning: false)
            }
        }
    } onCancel: {
        timeoutTasks.withLock { $0 }?.cancel()
        sendTasks.withLock { $0 }?.cancel()
        gate.resume(returning: false)
    }
}

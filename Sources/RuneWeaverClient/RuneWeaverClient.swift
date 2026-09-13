// Rune Weaver Client — WebSocket transport to the localhost-only engine service.
//
// Owns connection state and chat/decision framing for every client surface
// (iOS, macOS menu bar, web dashboard) over one shared wire shape.
// Aliases the single-sourced `RuneWeaverCore` frames so encoding never drifts;
// UI lives in the app targets, transport lives here.

import Foundation
import RuneWeaverCore

/// Sendable-safe box for a non-Sendable `URLSessionWebSocketTask`.
///
/// `URLSessionWebSocketTask` is not `Sendable`, so it cannot be stored
/// directly in the `Sendable` actor `RuneWeaverClient` or captured across
/// `Sendable` closures under Swift 6. The box is `@unchecked Sendable`
/// with an audited contract: the client is the sole owner, all
/// `send`/`receive`/`cancel` hops run through actor-isolated methods, and
/// `URLSessionWebSocketTask` serializes its own I/O, so crossing the
/// boundary inside the box introduces no data race.
private final class ClientSocketBox: @unchecked Sendable {
    /// Wrapped socket.
    let task: URLSessionWebSocketTask

    /// Wraps a socket.
    /// - Parameter task: Live socket task.
    init(_ task: URLSessionWebSocketTask) {
        self.task = task
    }
}

/// WebSocket wire shapes, single-sourced from `RuneWeaverCore`.
///
/// The canonical `WSChatMessage`, `WSDecisionMessage`, `WSStreamDelta`,
/// `WSStreamDone`, `WSApprovalPrompt`, and `WSErrorFrame` live in
/// `RuneWeaverCore/WSWire.swift` and are aliased here (and in
/// `RuneWeaverServer`) so the JSON encoding never drifts between modules;
/// drift breaks `WSInboundKind.classify`, which tells chat frames apart by
/// the presence of `text` versus `id` plus `approved`, and cancel frames by
/// their explicit `"type": "cancel"` discriminator.
public typealias ClientChatMessage = RuneWeaverCore.WSChatMessage
/// Decision frame, single-sourced from core (`WSDecisionMessage`).
public typealias ClientDecisionMessage = RuneWeaverCore.WSDecisionMessage
/// Streamed delta, single-sourced from core (`WSStreamDelta`).
public typealias ClientStreamDelta = RuneWeaverCore.WSStreamDelta
/// Terminal chat frame, single-sourced from core (`WSStreamDone`).
public typealias ClientStreamDone = RuneWeaverCore.WSStreamDone
/// Approval prompt, single-sourced from core (`WSApprovalPrompt`).
public typealias ClientApprovalPrompt = RuneWeaverCore.WSApprovalPrompt
/// Error frame, single-sourced from core (`WSErrorFrame`).
public typealias ClientErrorFrame = RuneWeaverCore.WSErrorFrame

/// Peek at the `type` discriminator of one inbound engine frame.
private struct ClientFramePeek: Codable {
    /// Frame discriminator (`delta`, `done`, `approval`, or `error`).
    let type: String
}

/// Thin client connection to the core engine.
///
/// Clients (iOS, macOS menu bar, web dashboard) connect over WebSocket to
/// the loopback-only v1 service (`127.0.0.1` with no auth, so
/// local-process access is the protection boundary). Remote access over
/// WireGuard VPN stays deferred until authentication lands and the service
/// may bind beyond loopback. This type owns connection state and
/// message transport; UI lives in the app targets.
///
/// The engine exposes a WebSocket endpoint at `/ws` (derived from
/// `baseURL` by swapping `http(s)` for `ws(s)`). `connect()` performs
/// a real WebSocket handshake verified with a ping/pong round-trip and
/// only enters `.connected` on success. Outbound chat uses the shared
/// `{"text": ...}` shape classified by `WSInboundKind` on the engine (one
/// engine API, no per-client forks); inbound chat is a `delta` stream plus
/// a terminal `done` frame, with `approval` broadcasts skipped and `error`
/// frames terminating the turn as a transport failure.
public actor RuneWeaverClient {
    /// Connection lifecycle state.
    public enum ConnectionState: String, Sendable {
        /// Not connected.
        case disconnected
        /// Connection in progress.
        case connecting
        /// Ready to send and receive.
        case connected
    }

    /// Server URL of the core engine.
    public let baseURL: URL
    /// Current connection state.
    public private(set) var state: ConnectionState = .disconnected
    /// Last connection or transport failure, if any.
    public private(set) var lastError: String?

    /// Live socket, present only while connecting or connected.
    private var socketBox: ClientSocketBox?

    /// Creates a client for the given engine URL.
    /// - Parameter baseURL: Engine base URL.
    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    /// Opens the WebSocket connection to the engine.
    ///
    /// Derives the `/ws` endpoint from `baseURL`, resumes a
    /// `URLSessionWebSocketTask`, and verifies the handshake with a
    /// ping/pong round-trip. Enters `.connected` only on success;
    /// otherwise returns to `.disconnected` and records `lastError`.
    public func connect() async {
        if state == .connected || state == .connecting {
            return
        }
        state = .connecting
        lastError = nil
        guard let socketURL = Self.webSocketURL(for: baseURL) else {
            state = .disconnected
            lastError = "Cannot derive a WebSocket URL from \(baseURL)"
            return
        }
        let task = URLSession.shared.webSocketTask(with: socketURL)
        let box = ClientSocketBox(task)
        socketBox = box
        task.resume()
        do {
            try await Self.ping(task: task)
            guard socketBox?.task === task else {
                // A concurrent disconnect() cancelled this attempt.
                task.cancel()
                return
            }
            state = .connected
        } catch {
            if socketBox?.task === task {
                task.cancel()
                socketBox = nil
            }
            state = .disconnected
            lastError = error.localizedDescription
        }
    }

    /// Closes the connection.
    public func disconnect() async {
        socketBox?.task.cancel(with: .goingAway, reason: nil)
        socketBox = nil
        state = .disconnected
    }

    /// Sends a user message and streams the reply.
    ///
    /// Requires an active connection: when disconnected the stream
    /// terminates immediately. Otherwise the message content is framed as
    /// the shared `{"text": ...}` chat shape, sent as a WebSocket text
    /// frame, and the engine `delta`/`done` stream is consumed until the
    /// terminal `done` frame, which is yielded as a single assistant
    /// message. `approval` broadcasts arriving mid-turn are skipped;
    /// `error` frames terminate the stream and record `lastError`.
    /// Transport failures terminate the stream and record `lastError`.
    /// - Parameter message: User message.
    /// - Returns: Stream of assistant messages.
    public func send(_ message: Message) -> AsyncStream<Message> {
        send(text: message.content, source: "client")
    }

    /// Sends raw user text and streams the reply.
    ///
    /// Shared engine wire: outbound uses `ClientChatMessage` (`{"text": ...}`)
    /// so `WSInboundKind.classify` sees a chat frame; inbound consumes the
    /// `delta` stream plus the terminal `done` frame. Approval prompts are
    /// skipped so one socket carries both streamed chat and live decisions.
    /// - Parameters:
    ///   - text: Raw user text.
    ///   - sessionID: Owning session. Defaults to nil (new session).
    ///   - source: Input origin. Defaults to `"client"`.
    /// - Returns: Stream yielding the final assistant message.
    public func send(text: String, sessionID: UUID? = nil, source: String? = "client") -> AsyncStream<Message> {
        guard state == .connected, let box = socketBox else {
            return AsyncStream { $0.finish() }
        }
        return AsyncStream { continuation in
            let worker = Task { [box] in
                await self.runChatTurn(
                    box: box,
                    text: text,
                    sessionID: sessionID,
                    source: source,
                    continuation: continuation
                )
            }
            continuation.onTermination = { @Sendable _ in worker.cancel() }
        }
    }

    /// Sends an approval decision for a pending request.
    ///
    /// Frames the decision as the shared `{"id": ..., "approved": ...}`
    /// shape classified by `WSInboundKind` so inline WebSocket decisions
    /// resolve the same approval queue as REST without polling.
    /// - Parameters:
    ///   - id: Pending request identifier.
    ///   - approved: Whether the tool call may run.
    ///   - duration: Trust tier. Defaults to `thisTime`.
    public func sendDecision(id: UUID, approved: Bool, duration: TrustDuration = .thisTime) async throws {
        guard let box = socketBox else {
            throw URLError(.notConnectedToInternet)
        }
        let outbound = ClientDecisionMessage(id: id, approved: approved, duration: duration)
        let payload = try JSONEncoder().encode(outbound)
        guard let frame = String(data: payload, encoding: .utf8) else {
            throw URLError(.cannotParseResponse)
        }
        try await box.task.send(.string(frame))
    }

    // MARK: - Private

    /// Outcome of handling one inbound engine frame.
    private enum ChatFrameResult {
        /// Keep streaming further frames.
        case continued
        /// Turn is complete; the receive loop should return.
        case finished
    }

    /// Runs one chat turn over an established socket.
    ///
    /// Sends the shared `{"text": ...}` chat frame, then consumes the
    /// `delta` stream until the terminal `done` frame. Approval broadcasts
    /// are skipped and `error` frames terminate the turn as a failure.
    /// - Parameters:
    ///   - box: Live socket box.
    ///   - text: Raw user text.
    ///   - sessionID: Owning session.
    ///   - source: Input origin.
    ///   - continuation: Stream receiving the final assistant message.
    private func runChatTurn(
        box: ClientSocketBox,
        text: String,
        sessionID: UUID?,
        source: String?,
        continuation: AsyncStream<Message>.Continuation
    ) async {
        do {
            let frame = try Self.chatFrame(text: text, sessionID: sessionID, source: source)
            try await box.task.send(.string(frame))
            var accumulated = ""
            while true {
                if Task.isCancelled {
                    continuation.finish()
                    return
                }
                let replyText = try await Self.replyText(box: box)
                guard let replyData = replyText.data(using: .utf8) else {
                    throw URLError(.cannotDecodeContentData)
                }
                let result = try Self.handleFrame(
                    replyData,
                    accumulated: &accumulated,
                    continuation: continuation
                )
                if result == .finished {
                    return
                }
            }
        } catch is CancellationError {
            continuation.finish()
        } catch {
            self.recordTransportFailure(error.localizedDescription)
            continuation.finish()
        }
    }

    /// Encodes the outbound chat frame.
    /// - Parameters:
    ///   - text: Raw user text.
    ///   - sessionID: Owning session.
    ///   - source: Input origin.
    /// - Returns: UTF-8 WebSocket text frame in the shared chat shape.
    private static func chatFrame(text: String, sessionID: UUID?, source: String?) throws -> String {
        let outbound = ClientChatMessage(text: text, sessionID: sessionID, source: source)
        let payload = try JSONEncoder().encode(outbound)
        guard let frame = String(data: payload, encoding: .utf8) else {
            throw URLError(.cannotParseResponse)
        }
        return frame
    }

    /// Receives the next inbound WebSocket frame as text.
    /// - Parameter box: Live socket box.
    /// - Returns: Inbound frame payload as UTF-8 text.
    private static func replyText(box: ClientSocketBox) async throws -> String {
        let reply = try await box.task.receive()
        switch reply {
        case let .string(string):
            return string
        case let .data(data):
            guard let decoded = String(data: data, encoding: .utf8) else {
                throw URLError(.cannotDecodeContentData)
            }
            return decoded
        @unknown default:
            throw URLError(.cannotDecodeContentData)
        }
    }

    /// Handles one inbound engine frame.
    ///
    /// Typed `delta`/`done`/`approval`/`error` frames take precedence; a
    /// payload without a discriminator falls back to a bare `Message` frame
    /// from an older engine.
    /// - Parameters:
    ///   - replyData: Raw inbound payload.
    ///   - accumulated: Running delta text used when `done` carries no text.
    ///   - continuation: Stream receiving the final assistant message.
    /// - Returns: Whether the turn finished or should continue streaming.
    private static func handleFrame(
        _ replyData: Data,
        accumulated: inout String,
        continuation: AsyncStream<Message>.Continuation
    ) throws -> ChatFrameResult {
        if let peek = try? JSONDecoder().decode(ClientFramePeek.self, from: replyData) {
            return try handleTypedFrame(
                peek.type,
                replyData: replyData,
                accumulated: &accumulated,
                continuation: continuation
            )
        }
        // Legacy fallback: a bare `Message` frame from an older engine.
        if let legacy = try? JSONDecoder().decode(Message.self, from: replyData) {
            continuation.yield(legacy)
            continuation.finish()
            return .finished
        }
        return .continued
    }

    /// Handles one discriminator-typed engine frame.
    /// - Parameters:
    ///   - type: Frame discriminator.
    ///   - replyData: Raw inbound payload.
    ///   - accumulated: Running delta text used when `done` carries no text.
    ///   - continuation: Stream receiving the final assistant message.
    /// - Returns: Whether the turn finished or should continue streaming.
    private static func handleTypedFrame(
        _ type: String,
        replyData: Data,
        accumulated: inout String,
        continuation: AsyncStream<Message>.Continuation
    ) throws -> ChatFrameResult {
        switch type {
        case "delta":
            if let delta = try? JSONDecoder().decode(ClientStreamDelta.self, from: replyData) {
                accumulated += delta.delta
            }
            return .continued
        case "done":
            guard let done = try? JSONDecoder().decode(ClientStreamDone.self, from: replyData) else {
                return .continued
            }
            let content = done.text.isEmpty ? accumulated : done.text
            continuation.yield(Message(role: .assistant, content: content))
            continuation.finish()
            return .finished
        case "approval":
            // Broadcast prompt arriving mid-turn; skip and keep streaming.
            return .continued
        case "error":
            if let failure = try? JSONDecoder().decode(ClientErrorFrame.self, from: replyData) {
                throw URLError(.cannotParseResponse, userInfo: [NSLocalizedDescriptionKey: failure.message])
            }
            throw URLError(.cannotParseResponse)
        default:
            return .continued
        }
    }

    /// Derives the engine WebSocket endpoint from the base URL.
    /// - Parameter baseURL: Engine base URL (`http(s)://host[:port][/prefix]`).
    /// - Returns: `ws(s)` URL with `/ws` appended, or nil when `baseURL`
    ///   has no host.
    private static func webSocketURL(for baseURL: URL) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              components.host != nil
        else { return nil }
        switch components.scheme?.lowercased() {
        case "https":
            components.scheme = "wss"
        default:
            components.scheme = "ws"
        }
        var path = components.path
        if path.hasSuffix("/") {
            path.removeLast()
        }
        path += "/ws"
        components.path = path
        return components.url
    }

    /// Verifies a freshly resumed socket with a ping/pong round-trip.
    /// - Parameter task: Socket to probe.
    private static func ping(task: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            task.sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// Records a transport failure observed while sending.
    /// - Parameter message: Failure description.
    private func recordTransportFailure(_ message: String) {
        lastError = message
    }
}

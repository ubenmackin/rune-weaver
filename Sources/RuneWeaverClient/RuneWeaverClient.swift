import Foundation
import RuneWeaverCore

/// Thin client connection to the core engine.
///
/// Clients (iOS, macOS menu bar, web dashboard) connect over
/// WebSocket via WireGuard VPN. This type owns connection state and
/// message transport; UI lives in the app targets.
///
/// The engine exposes a WebSocket endpoint at `/ws` (derived from
/// `baseURL` by swapping `http(s)` for `ws(s)`). `connect()` performs
/// a real WebSocket handshake verified with a ping/pong round-trip and
/// only enters `.connected` on success; `send(_:)` frames each
/// `Message` as JSON over the socket and streams the decoded reply.
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
    private var webSocketTask: URLSessionWebSocketTask?

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
        webSocketTask = task
        task.resume()
        do {
            try await Self.ping(task: task)
            guard webSocketTask === task else {
                // A concurrent disconnect() cancelled this attempt.
                task.cancel()
                return
            }
            state = .connected
        } catch {
            if webSocketTask === task {
                task.cancel()
                webSocketTask = nil
            }
            state = .disconnected
            lastError = error.localizedDescription
        }
    }

    /// Closes the connection.
    public func disconnect() async {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        state = .disconnected
    }

    /// Sends a user message and streams the reply.
    ///
    /// Requires an active connection: when disconnected the stream
    /// terminates immediately. Otherwise the message is encoded as JSON,
    /// sent as a WebSocket text frame, and the next text frame from the
    /// engine is decoded and yielded as a single reply before the stream
    /// finishes. Transport failures terminate the stream and record
    /// `lastError`.
    /// - Parameter message: User message.
    /// - Returns: Stream of assistant messages.
    public func send(_ message: Message) -> AsyncStream<Message> {
        guard state == .connected, let task = webSocketTask else {
            return AsyncStream { $0.finish() }
        }
        return AsyncStream { continuation in
            let worker = Task {
                do {
                    let payload = try JSONEncoder().encode(message)
                    guard let text = String(data: payload, encoding: .utf8) else {
                        throw URLError(.cannotParseResponse)
                    }
                    try await task.send(.string(text))
                    let reply = try await task.receive()
                    let replyText: String
                    switch reply {
                    case let .string(string):
                        replyText = string
                    case let .data(data):
                        guard let decoded = String(data: data, encoding: .utf8) else {
                            throw URLError(.cannotDecodeContentData)
                        }
                        replyText = decoded
                    @unknown default:
                        throw URLError(.cannotDecodeContentData)
                    }
                    guard let replyData = replyText.data(using: .utf8) else {
                        throw URLError(.cannotDecodeContentData)
                    }
                    let decoded = try JSONDecoder().decode(Message.self, from: replyData)
                    continuation.yield(decoded)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    self.recordTransportFailure(error.localizedDescription)
                    continuation.finish()
                }
            }
            continuation.onTermination = { @Sendable _ in worker.cancel() }
        }
    }

    // MARK: - Private

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

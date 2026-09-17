// Rune Weaver Client — WebSocket transport to the localhost-only engine service.

import Foundation
import RuneWeaverCore

/// WebSocket wire shapes, single-sourced from `RuneWeaverCore`.
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
/// Degraded-tool notice, single-sourced from core (`WSWarningFrame`).
public typealias ClientWarningFrame = RuneWeaverCore.WSWarningFrame

/// Peek at the `type` discriminator of one inbound engine frame.
private struct ClientFramePeek: Codable {
    /// Frame discriminator (`delta`, `done`, `warning`, `tool_start`, `tool_end`, `approval`, `cancelled`, or `error`).
    let type: String
}

/// Thin client connection to the core engine.
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
    private var socketTask: URLSessionWebSocketTask?

    /// Creates a client for the given engine URL.
    /// - Parameter baseURL: Engine base URL.
    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    /// Opens the WebSocket connection to the engine.
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
        socketTask = task
        task.resume()
        do {
            try await Self.ping(task: task)
            guard socketTask === task else {
                // A concurrent disconnect() cancelled this attempt.
                task.cancel()
                return
            }
            state = .connected
        } catch {
            if socketTask === task {
                task.cancel()
                socketTask = nil
            }
            state = .disconnected
            lastError = error.localizedDescription
        }
    }

    /// Closes the connection.
    public func disconnect() async {
        socketTask?.cancel(with: .goingAway, reason: nil)
        socketTask = nil
        state = .disconnected
    }

    /// Sends a user message and streams the reply.
    public func send(_ message: Message) -> AsyncStream<Message> {
        send(text: message.content, source: "client")
    }

    /// Sends raw user text and streams the reply.
    public func send(text: String, sessionID: UUID? = nil, source: String? = "client") -> AsyncStream<Message> {
        guard state == .connected, socketTask != nil else {
            return AsyncStream { $0.finish() }
        }
        return AsyncStream { continuation in
            let worker = Task {
                await self.runChatTurn(
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
    public func sendDecision(id: UUID, approved: Bool, duration: TrustDuration = .thisTime) async throws {
        guard let task = socketTask else {
            throw URLError(.notConnectedToInternet)
        }
        let outbound = ClientDecisionMessage(id: id, approved: approved, duration: duration)
        let payload = try JSONEncoder().encode(outbound)
        guard let frame = String(data: payload, encoding: .utf8) else {
            throw URLError(.cannotParseResponse)
        }
        try await task.send(.string(frame))
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
    private func runChatTurn(
        text: String,
        sessionID: UUID?,
        source: String?,
        continuation: AsyncStream<Message>.Continuation
    ) async {
        guard let task = socketTask else {
            continuation.finish()
            return
        }
        do {
            let frame = try Self.chatFrame(text: text, sessionID: sessionID, source: source)
            try await task.send(.string(frame))
            var accumulated = ""
            var liveWarningLines = Set<String>()
            while true {
                if Task.isCancelled {
                    continuation.finish()
                    return
                }
                let replyText = try await Self.replyText(task: task)
                guard let replyData = replyText.data(using: .utf8) else {
                    throw URLError(.cannotDecodeContentData)
                }
                let result = try Self.handleFrame(
                    replyData,
                    accumulated: &accumulated,
                    liveWarnings: &liveWarningLines,
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
    private static func chatFrame(text: String, sessionID: UUID?, source: String?) throws -> String {
        let outbound = ClientChatMessage(text: text, sessionID: sessionID, source: source)
        let payload = try JSONEncoder().encode(outbound)
        guard let frame = String(data: payload, encoding: .utf8) else {
            throw URLError(.cannotParseResponse)
        }
        return frame
    }

    /// Receives the next inbound WebSocket frame as text.
    /// - Parameter task: Live socket task.
    /// - Returns: Inbound frame payload as UTF-8 text.
    private static func replyText(task: URLSessionWebSocketTask) async throws -> String {
        let reply = try await task.receive()
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
    private static func handleFrame(
        _ replyData: Data,
        accumulated: inout String,
        liveWarnings: inout Set<String>,
        continuation: AsyncStream<Message>.Continuation
    ) throws -> ChatFrameResult {
        if let peek = try? JSONDecoder().decode(ClientFramePeek.self, from: replyData) {
            return try handleTypedFrame(
                peek.type,
                replyData: replyData,
                accumulated: &accumulated,
                liveWarnings: &liveWarnings,
                continuation: continuation
            )
        }
        return .continued
    }

    /// Handles one discriminator-typed engine frame.
    private static func handleTypedFrame(
        _ type: String,
        replyData: Data,
        accumulated: inout String,
        liveWarnings: inout Set<String>,
        continuation: AsyncStream<Message>.Continuation
    ) throws -> ChatFrameResult {
        switch type {
        case "delta":
            if let delta = try? JSONDecoder().decode(ClientStreamDelta.self, from: replyData) {
                accumulated += delta.delta
            }
            return .continued
        case "warning":
            // Degraded-tool notices stay informational but must not go silent for library
            // consumers: surface each skip as a system message so fail-open turns stay honest.
            if let warning = try? JSONDecoder().decode(ClientWarningFrame.self, from: replyData) {
                let trimmed = warning.message.trimmingCharacters(in: .whitespacesAndNewlines)
                // One message per skipped tool even on retransmit: collapse live repeats by value.
                if !trimmed.isEmpty, liveWarnings.insert(trimmed).inserted {
                    continuation.yield(Message(role: .system, content: trimmed))
                }
            }
            return .continued
        case "done":
            guard let done = try? JSONDecoder().decode(ClientStreamDone.self, from: replyData) else {
                return .continued
            }
            // Terminal warnings repeat mid-turn notices for polling clients; surface only lines
            // not already streamed live so library turns carry one message per skipped tool.
            if let warnings = done.warnings {
                var emittedTerminal = Set<String>()
                for line in warnings {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    guard !liveWarnings.contains(trimmed) else { continue }
                    guard emittedTerminal.insert(trimmed).inserted else { continue }
                    liveWarnings.insert(trimmed)
                    continuation.yield(Message(role: .system, content: trimmed))
                }
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

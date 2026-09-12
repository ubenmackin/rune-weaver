// Rune Weaver Core — Single-source WebSocket wire shapes for the engine API.
//
// Every client (CLI service launcher, iOS, macOS menu bar, web dashboard)
// speaks these shapes over one localhost-only surface with no per-client
// forks. `RuneWeaverServer` and `RuneWeaverClient` expose them via
// typealiases so the JSON encoding never drifts between modules; `drift`
// breaks `WSInboundKind.classify`, which tells chat frames apart by the
// presence of `text` versus `id` plus `approved`.

import Foundation

/// Chat message sent by a WebSocket client.
///
/// The socket accepts chat frames carrying `text` (plus the legacy
/// `{"content":"..."}` shape for thin-client migration), or a
/// decision message carrying `id` plus `approved`. Shapes are told apart
/// by which required field is present so one socket carries both streamed
/// chat and live approval decisions without a second connection.
public struct WSChatMessage: Codable, Sendable, Equatable {
    /// Raw user text.
    public let text: String
    /// Owning session. A new session starts when omitted.
    public var sessionID: UUID?
    /// Input origin. Defaults to `"websocket"` when omitted.
    public var source: String?

    /// Creates a WebSocket chat message.
    /// - Parameters:
    ///   - text: Raw user text.
    ///   - sessionID: Owning session. Defaults to nil (new session).
    ///   - source: Input origin. Defaults to nil (`"websocket"`).
    public init(text: String, sessionID: UUID? = nil, source: String? = nil) {
        self.text = text
        self.sessionID = sessionID
        self.source = source
    }
}

/// Legacy thin-client chat frame carrying `content`.
///
/// Accepts `{"content":"..."}` from older thin clients that predate the
/// `{"text":"..."}` shape. The full `Message` type requires
/// `id`/`role`/`content`/`createdAt`, so it can never decode a bare
/// content frame; this dedicated shape keeps the legacy path live.
/// - Parameter content: Raw user text.
public struct WSLegacyContentMessage: Codable, Sendable, Equatable {
    /// Raw user text.
    public let content: String

    /// Creates a legacy content message.
    /// - Parameter content: Raw user text.
    public init(content: String) {
        self.content = content
    }
}

/// Approval decision sent by a WebSocket client.
public struct WSDecisionMessage: Codable, Sendable, Equatable {
    /// Pending request identifier being resolved.
    public let id: UUID
    /// Whether the tool call may run.
    public let approved: Bool
    /// Graduated-trust tier recorded on approval.
    public var duration: TrustDuration?

    /// Creates a WebSocket decision message.
    /// - Parameters:
    ///   - id: Pending request identifier.
    ///   - approved: Whether the call may run.
    ///   - duration: Trust tier. Defaults to nil (`thisTime`).
    public init(id: UUID, approved: Bool, duration: TrustDuration? = nil) {
        self.id = id
        self.approved = approved
        self.duration = duration
    }

    /// Trust tier, defaulting to `thisTime` (one-shot).
    /// - Returns: Resolved duration.
    public var resolvedDuration: TrustDuration {
        duration ?? .thisTime
    }
}

/// Streamed chat delta sent by the engine over WebSocket.
public struct WSStreamDelta: Codable, Sendable, Equatable {
    /// Always `"delta"`.
    public let type: String
    /// Incremental assistant text.
    public let delta: String

    /// Creates a stream delta.
    /// - Parameter delta: Incremental assistant text.
    public init(delta: String) {
        self.type = "delta"
        self.delta = delta
    }
}

/// Terminal chat frame sent by the engine over WebSocket.
public struct WSStreamDone: Codable, Sendable, Equatable {
    /// Always `"done"`.
    public let type: String
    /// Final assistant text.
    public let text: String
    /// Owning session identifier.
    public let sessionID: UUID

    /// Creates a stream done frame.
    /// - Parameters:
    ///   - text: Final assistant text.
    ///   - sessionID: Owning session identifier.
    public init(text: String, sessionID: UUID) {
        self.type = "done"
        self.text = text
        self.sessionID = sessionID
    }
}

/// Live approval prompt pushed by the engine over WebSocket.
public struct WSApprovalPrompt: Codable, Sendable, Equatable {
    /// Always `"approval"`.
    public let type: String
    /// Pending request awaiting a decision.
    public let request: PermissionRequest

    /// Creates an approval prompt.
    /// - Parameter request: Pending request.
    public init(request: PermissionRequest) {
        self.type = "approval"
        self.request = request
    }
}

/// Error frame sent by the engine over WebSocket.
public struct WSErrorFrame: Codable, Sendable, Equatable {
    /// Always `"error"`.
    public let type: String
    /// Human-readable failure.
    public let message: String

    /// Creates an error frame.
    /// - Parameter message: Human-readable failure.
    public init(message: String) {
        self.type = "error"
        self.message = message
    }
}

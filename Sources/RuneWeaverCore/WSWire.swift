// Rune Weaver Core — Single-source WebSocket wire shapes for the engine API.
//
// Every client (CLI service launcher, iOS, macOS menu bar, web dashboard)
// speaks these shapes over one localhost-only surface with no per-client
// forks. `RuneWeaverServer` and `RuneWeaverClient` expose them via
// typealiases so the JSON encoding never drifts between modules; `drift`
// breaks `WSInboundKind.classify`, which tells chat frames apart by the
// presence of `text` versus `id` plus `approved`, and cancel frames by
// their explicit `"type": "cancel"` discriminator.

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
    /// Owning session identifier.
    public var sessionID: UUID?

    /// Creates a stream delta.
    /// - Parameters:
    ///   - delta: Incremental assistant text.
    ///   - sessionID: Owning session identifier.
    public init(delta: String, sessionID: UUID? = nil) {
        self.type = "delta"
        self.delta = delta
        self.sessionID = sessionID
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
    /// Tool invocations performed while answering.
    public var toolActions: [ToolAction]?
    /// Billed tokens accumulated across LLM rounds in this turn.
    public var totalTokens: Int?
    /// Serving model name.
    public var modelName: String?
    /// Context window limit.
    public var contextLength: Int?
    /// Cumulative tokens for session.
    public var sessionTokens: Int?

    /// Creates a stream done frame.
    /// - Parameters:
    ///   - text: Final assistant text.
    ///   - sessionID: Owning session identifier.
    ///   - toolActions: Tool invocations performed.
    ///   - totalTokens: Billed tokens for turn.
    ///   - modelName: Serving model name.
    ///   - contextLength: Context window limit.
    ///   - sessionTokens: Cumulative tokens for session.
    public init(
        text: String,
        sessionID: UUID,
        toolActions: [ToolAction]? = nil,
        totalTokens: Int? = nil,
        modelName: String? = nil,
        contextLength: Int? = nil,
        sessionTokens: Int? = nil
    ) {
        self.type = "done"
        self.text = text
        self.sessionID = sessionID
        self.toolActions = toolActions
        self.totalTokens = totalTokens
        self.modelName = modelName
        self.contextLength = contextLength
        self.sessionTokens = sessionTokens
    }

    /// Creates a terminal frame from an orchestrator response.
    ///
    /// Single shared mapping for the response token and model fields so
    /// the REST and WebSocket surfaces never drift when those fields
    /// evolve.
    /// - Parameter response: Completed turn to report.
    public init(from response: OrchestratorResponse) {
        self.init(
            text: response.text,
            sessionID: response.sessionID,
            toolActions: response.toolActions,
            totalTokens: response.totalTokens,
            modelName: response.modelName,
            contextLength: response.contextLength,
            sessionTokens: response.sessionTokens
        )
    }
}

/// Streamed tool start event sent by the engine over WebSocket.
public struct WSToolStartFrame: Codable, Sendable, Equatable {
    /// Always `"tool_start"`.
    public let type: String
    /// Name of the tool being called.
    public let toolName: String
    /// Correlation identifier of the call.
    public let callID: String
    /// Raw JSON arguments sent to the tool.
    public let argumentsJSON: String
    /// Owning session identifier.
    public var sessionID: UUID?

    /// Creates a tool start frame.
    public init(toolName: String, callID: String, argumentsJSON: String, sessionID: UUID? = nil) {
        self.type = "tool_start"
        self.toolName = toolName
        self.callID = callID
        self.argumentsJSON = argumentsJSON
        self.sessionID = sessionID
    }
}

/// Streamed tool end event sent by the engine over WebSocket.
public struct WSToolEndFrame: Codable, Sendable, Equatable {
    /// Always `"tool_end"`.
    public let type: String
    /// Name of the tool that ran.
    public let toolName: String
    /// Correlation identifier of the call.
    public let callID: String
    /// Result returned by the tool.
    public let result: ToolResult
    /// Owning session identifier.
    public var sessionID: UUID?

    /// Creates a tool end frame.
    public init(toolName: String, callID: String, result: ToolResult, sessionID: UUID? = nil) {
        self.type = "tool_end"
        self.toolName = toolName
        self.callID = callID
        self.result = result
        self.sessionID = sessionID
    }
}

/// Cancellation message sent by a WebSocket client.
///
/// Carries the explicit `"cancel"` discriminator so
/// `WSInboundKind.classify` recognises it without shape sniffing;
/// decoding tolerates the legacy typeless `{"sessionID": ...}` frame.
public struct WSCancelMessage: Codable, Sendable, Equatable {
    /// Always `"cancel"`.
    public let type: String
    /// Optional session identifier to cancel.
    public let sessionID: UUID?

    /// Creates a cancellation message.
    public init(sessionID: UUID? = nil) {
        self.type = "cancel"
        self.sessionID = sessionID
    }

    /// Coding keys for the cancel frame.
    enum CodingKeys: String, CodingKey {
        /// Frame discriminator.
        case type
        /// Session to cancel.
        case sessionID
    }

    /// Decodes a cancel frame, defaulting a missing discriminator.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decodeIfPresent(String.self, forKey: .type) ?? "cancel"
        self.sessionID = try container.decodeIfPresent(UUID.self, forKey: .sessionID)
    }
}

/// Cancellation confirmation frame sent by the engine over WebSocket.
///
/// `cancelled` tells idle cancels apart from real ones: `true` means an
/// in-flight turn was found and aborted, `false` means nothing was running
/// (and, for unknown or long-idle sessions, no pending mark was left to
/// poison the next turn). Missing flags from older engines decode as
/// `true` to keep the previous always-success shape readable.
public struct WSCancelledFrame: Codable, Sendable, Equatable {
    /// Always `"cancelled"`.
    public let type: String
    /// Cancelled session identifier, if known.
    public let sessionID: UUID?
    /// Whether a running turn was actually cancelled.
    public let cancelled: Bool

    /// Creates a cancelled frame.
    /// - Parameters:
    ///   - sessionID: Cancelled session, when known.
    ///   - cancelled: Whether a running turn was aborted.
    public init(sessionID: UUID? = nil, cancelled: Bool = true) {
        self.type = "cancelled"
        self.sessionID = sessionID
        self.cancelled = cancelled
    }

    /// Coding keys for the cancelled frame.
    enum CodingKeys: String, CodingKey {
        /// Frame discriminator.
        case type
        /// Cancelled session.
        case sessionID
        /// Whether a turn was aborted.
        case cancelled
    }

    /// Decodes a cancelled frame, defaulting a missing flag for back-compat.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decodeIfPresent(String.self, forKey: .type) ?? "cancelled"
        self.sessionID = try container.decodeIfPresent(UUID.self, forKey: .sessionID)
        self.cancelled = try container.decodeIfPresent(Bool.self, forKey: .cancelled) ?? true
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
    /// Owning session, when the failure belongs to one turn.
    ///
    /// Tagged so multiplexed views sharing one socket ignore errors for
    /// other sessions; nil for connection-level failures with no turn.
    public var sessionID: UUID?

    /// Creates an error frame.
    /// - Parameters:
    ///   - message: Human-readable failure.
    ///   - sessionID: Owning session, when known.
    public init(message: String, sessionID: UUID? = nil) {
        self.type = "error"
        self.message = message
        self.sessionID = sessionID
    }
}

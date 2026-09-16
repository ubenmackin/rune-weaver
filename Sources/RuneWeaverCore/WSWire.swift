// Rune Weaver Core — Single-source WebSocket wire shapes for the engine API.

import Foundation

/// Chat message sent by a WebSocket client.
public struct WSChatMessage: Codable, Sendable, Equatable {
    /// Raw user text.
    public let text: String
    /// Owning session. A new session starts when omitted.
    public var sessionID: UUID?
    /// Input origin. Defaults to `"websocket"` when omitted.
    public var source: String?

    /// Creates a WebSocket chat message.
    public init(text: String, sessionID: UUID? = nil, source: String? = nil) {
        self.text = text
        self.sessionID = sessionID
        self.source = source
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
    /// Whether this turn parked waiting on approval.
    public var isParked: Bool = false

    /// Creates a stream done frame.
    public init(
        text: String,
        sessionID: UUID,
        toolActions: [ToolAction]? = nil,
        totalTokens: Int? = nil,
        modelName: String? = nil,
        contextLength: Int? = nil,
        sessionTokens: Int? = nil,
        isParked: Bool = false
    ) {
        self.type = "done"
        self.text = text
        self.sessionID = sessionID
        self.toolActions = toolActions
        self.totalTokens = totalTokens
        self.modelName = modelName
        self.contextLength = contextLength
        self.sessionTokens = sessionTokens
        self.isParked = isParked
    }

    /// Coding keys for the terminal frame.
    enum CodingKeys: String, CodingKey {
        /// Frame discriminator.
        case type
        /// Final assistant text.
        case text
        /// Owning session identifier.
        case sessionID
        /// Tool invocations performed.
        case toolActions
        /// Billed tokens for turn.
        case totalTokens
        /// Serving model name.
        case modelName
        /// Context window limit.
        case contextLength
        /// Cumulative tokens for session.
        case sessionTokens
        /// Whether the turn parked waiting on approval.
        case isParked
    }

    /// Decodes a terminal frame, defaulting a missing parked flag for back-compat.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decodeIfPresent(String.self, forKey: .type) ?? "done"
        self.text = try container.decode(String.self, forKey: .text)
        self.sessionID = try container.decode(UUID.self, forKey: .sessionID)
        self.toolActions = try container.decodeIfPresent([ToolAction].self, forKey: .toolActions)
        self.totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens)
        self.modelName = try container.decodeIfPresent(String.self, forKey: .modelName)
        self.contextLength = try container.decodeIfPresent(Int.self, forKey: .contextLength)
        self.sessionTokens = try container.decodeIfPresent(Int.self, forKey: .sessionTokens)
        self.isParked = try container.decodeIfPresent(Bool.self, forKey: .isParked) ?? false
    }

    /// Creates a terminal frame from an orchestrator response.
    public init(from response: OrchestratorResponse) {
        self.init(
            text: response.text,
            sessionID: response.sessionID,
            toolActions: response.toolActions,
            totalTokens: response.totalTokens,
            modelName: response.modelName,
            contextLength: response.contextLength,
            sessionTokens: response.sessionTokens,
            isParked: response.isParked
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
}

/// Cancellation confirmation frame sent by the engine over WebSocket.
public struct WSCancelledFrame: Codable, Sendable, Equatable {
    /// Always `"cancelled"`.
    public let type: String
    /// Cancelled session identifier, if known.
    public let sessionID: UUID?
    /// Whether a running turn was actually cancelled.
    public let cancelled: Bool

    /// Creates a cancelled frame.
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

/// Approval decision broadcast sent by the engine over WebSocket.
public struct WSApprovalDecidedFrame: Codable, Sendable, Equatable {
    /// Always `"approval_decided"`.
    public let type: String
    /// Resolved request identifier.
    public let id: UUID
    /// Whether the tool call may run.
    public let approved: Bool
    /// Owning session, when the approval was tagged.
    public var sessionID: UUID?

    /// Creates an approval decision broadcast.
    public init(id: UUID, approved: Bool, sessionID: UUID? = nil) {
        self.type = "approval_decided"
        self.id = id
        self.approved = approved
        self.sessionID = sessionID
    }
}

/// Error frame sent by the engine over WebSocket.
public struct WSErrorFrame: Codable, Sendable, Equatable {
    /// Always `"error"`.
    public let type: String
    /// Human-readable failure.
    public let message: String
    /// Owning session, when the failure belongs to one turn.
    public var sessionID: UUID?

    /// Creates an error frame.
    public init(message: String, sessionID: UUID? = nil) {
        self.type = "error"
        self.message = message
        self.sessionID = sessionID
    }
}

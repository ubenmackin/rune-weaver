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
    /// Whether this message is a mid-turn steering injection.
    public var steer: Bool?

    /// Creates a WebSocket chat message.
    public init(text: String, sessionID: UUID? = nil, source: String? = nil, steer: Bool? = nil) {
        self.text = text
        self.sessionID = sessionID
        self.source = source
        self.steer = steer
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
    /// Whether to grant tool-wide trust matching any target.
    public var widen: Bool?

    /// Creates a WebSocket decision message.
    public init(id: UUID, approved: Bool, duration: TrustDuration? = nil, widen: Bool? = nil) {
        self.id = id
        self.approved = approved
        self.duration = duration
        self.widen = widen
    }

    /// Trust tier, defaulting to `thisTime` (one-shot).
    /// - Returns: Resolved duration.
    public var resolvedDuration: TrustDuration {
        duration ?? .thisTime
    }

    /// Whether to grant tool-wide trust matching any target, defaulting to `false` so an omitted
    /// flag never silently widens a grant.
    public var resolvedWiden: Bool {
        widen ?? false
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

/// Streamed reasoning / thought delta sent by the engine over WebSocket.
public struct WSStreamReasoningDelta: Codable, Sendable, Equatable {
    /// Always `"reasoning_delta"`.
    public let type: String
    /// Incremental model reasoning / thought text.
    public let delta: String
    /// Owning session identifier.
    public var sessionID: UUID?

    /// Creates a stream reasoning delta.
    public init(delta: String, sessionID: UUID? = nil) {
        self.type = "reasoning_delta"
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
    /// Tool invocations performed while answering. Each entry carries its own
    /// chronological `roundIndex` so clients interleave text and tools oldest-first.
    public var toolActions: [ToolAction]?
    /// Highest round index in this turn, when any tool ran. Lets clients that only
    /// inspect the terminal frame learn the turn had multiple rounds without scanning
    /// every action; nil for text-only turns.
    public var roundIndex: Int?
    /// Billed tokens accumulated across LLM rounds in this turn.
    public var totalTokens: Int?
    /// Serving model name.
    public var modelName: String?
    /// Context window limit.
    public var contextLength: Int?
    /// Cumulative tokens for session.
    public var sessionTokens: Int?
    /// Active context tokens in the model's KV cache at turn completion.
    public var contextTokens: Int?
    /// Whether this turn parked waiting on approval.
    public var isParked: Bool = false
    /// Degraded-tool notices for tools omitted this turn. Nil when absent for back-compat.
    public var warnings: [String]?
    /// Completion time as Unix seconds since 1970 on the server clock. Optional so
    /// older dashboards that omit it still decode; clients fall back to receipt time.
    public var completedAt: Double?
    /// Late steering still queued server-side at turn completion.
    public var retainedSteerCount: Int?
    /// Content-free recall counts plus source names plus skip flag for the chip.
    /// Nil on frames from engines predating the chip, which render no chip.
    public var recallDiagnostics: RecallSummary?

    /// Creates a stream done frame.
    public init(
        text: String,
        sessionID: UUID,
        toolActions: [ToolAction]? = nil,
        totalTokens: Int? = nil,
        modelName: String? = nil,
        contextLength: Int? = nil,
        sessionTokens: Int? = nil,
        contextTokens: Int? = nil,
        isParked: Bool = false,
        warnings: [String]? = nil,
        roundIndex: Int? = nil,
        completedAt: Double? = nil,
        retainedSteerCount: Int? = nil,
        recallDiagnostics: RecallSummary? = nil
    ) {
        self.type = "done"
        self.text = text
        self.sessionID = sessionID
        self.toolActions = toolActions
        self.totalTokens = totalTokens
        self.modelName = modelName
        self.contextLength = contextLength
        self.sessionTokens = sessionTokens
        self.contextTokens = contextTokens
        self.isParked = isParked
        self.warnings = warnings
        // Callers stamp the persisted assistant note's creation time so live frames and
        // history reloads share one instant; nil keeps equality deterministic and lets
        // clients fall back to receipt time when no note persisted.
        self.completedAt = completedAt
        // Only non-negative counts cross the wire so a drifted negative never asks
        // the dashboard to retain a negative slice; nil degrades to clear-as-answered.
        self.retainedSteerCount = if let retainedSteerCount, retainedSteerCount < 0 {
            nil
        } else {
            retainedSteerCount
        }
        self.recallDiagnostics = recallDiagnostics
        // Derive the turn's highest round from its actions when the caller omits it,
        // so multi-round turns advertise their boundary count without extra bookkeeping.
        if let roundIndex {
            self.roundIndex = roundIndex
        } else {
            self.roundIndex = toolActions?.compactMap(\.roundIndex).max()
        }
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
        /// Highest round index in this turn.
        case roundIndex
        /// Billed tokens for turn.
        case totalTokens
        /// Serving model name.
        case modelName
        /// Context window limit.
        case contextLength
        /// Cumulative tokens for session.
        case sessionTokens
        /// Active context tokens in KV cache.
        case contextTokens
        /// Whether the turn parked waiting on approval.
        case isParked
        /// Degraded-tool notices.
        case warnings
        /// Completion time as Unix seconds.
        case completedAt
        /// Late steering still queued at completion.
        case retainedSteerCount
        /// Content-free recall summary for the chip.
        case recallDiagnostics
    }

    /// Decodes a terminal frame, defaulting a missing parked flag for back-compat while rejecting
    /// negative token counters so a drifted payload fails here exactly where the live progress frame
    /// drops it, instead of reconciling to a negative total.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decodeIfPresent(String.self, forKey: .type) ?? "done"
        self.text = try container.decode(String.self, forKey: .text)
        self.sessionID = try container.decode(UUID.self, forKey: .sessionID)
        self.toolActions = try container.decodeIfPresent([ToolAction].self, forKey: .toolActions)
        self.roundIndex = try container.decodeIfPresent(Int.self, forKey: .roundIndex) ?? toolActions?.compactMap(\.roundIndex).max()
        let totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens)
        if let totalTokens, totalTokens < 0 {
            throw DecodingError.dataCorruptedError(forKey: .totalTokens, in: container, debugDescription: "totalTokens must be non-negative")
        }
        self.totalTokens = totalTokens
        self.modelName = try container.decodeIfPresent(String.self, forKey: .modelName)
        self.contextLength = try container.decodeIfPresent(Int.self, forKey: .contextLength)
        let sessionTokens = try container.decodeIfPresent(Int.self, forKey: .sessionTokens)
        if let sessionTokens, sessionTokens < 0 {
            throw DecodingError.dataCorruptedError(forKey: .sessionTokens, in: container, debugDescription: "sessionTokens must be non-negative")
        }
        self.sessionTokens = sessionTokens
        let contextTokens = try container.decodeIfPresent(Int.self, forKey: .contextTokens)
        if let contextTokens, contextTokens < 0 {
            throw DecodingError.dataCorruptedError(forKey: .contextTokens, in: container, debugDescription: "contextTokens must be non-negative")
        }
        self.contextTokens = contextTokens
        self.isParked = try container.decodeIfPresent(Bool.self, forKey: .isParked) ?? false
        self.warnings = try container.decodeIfPresent([String].self, forKey: .warnings)
        self.completedAt = try container.decodeIfPresent(Double.self, forKey: .completedAt)
        // A drifted negative count degrades to absent so the terminal frame still
        // settles the turn; the dashboard clears consumed tracking as answered
        // instead of dropping the reply on a malformed count.
        let retainedSteerCount = try container.decodeIfPresent(Int.self, forKey: .retainedSteerCount)
        self.retainedSteerCount = if let retainedSteerCount, retainedSteerCount < 0 {
            nil
        } else {
            retainedSteerCount
        }
        self.recallDiagnostics = try container.decodeIfPresent(RecallSummary.self, forKey: .recallDiagnostics)
    }

    /// Encodes a terminal frame, omitting an absent round so older decoders see no new key.
    /// - Parameter encoder: Destination encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(text, forKey: .text)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encodeIfPresent(toolActions, forKey: .toolActions)
        try container.encodeIfPresent(roundIndex, forKey: .roundIndex)
        try container.encodeIfPresent(totalTokens, forKey: .totalTokens)
        try container.encodeIfPresent(modelName, forKey: .modelName)
        try container.encodeIfPresent(contextLength, forKey: .contextLength)
        try container.encodeIfPresent(sessionTokens, forKey: .sessionTokens)
        try container.encodeIfPresent(contextTokens, forKey: .contextTokens)
        try container.encode(isParked, forKey: .isParked)
        try container.encodeIfPresent(warnings, forKey: .warnings)
        // Omit an absent completion so older decoders see no new key.
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
        // Omit an absent retained count so older dashboards see no new key.
        try container.encodeIfPresent(retainedSteerCount, forKey: .retainedSteerCount)
        // Omit an absent summary so older dashboards see no new key and render no chip.
        try container.encodeIfPresent(recallDiagnostics, forKey: .recallDiagnostics)
    }

    /// Creates a terminal frame from an orchestrator response.
    /// Carries the response's persisted completion instant through without re-stamping
    /// so live frames and history reloads reconcile to the same server instant.
    public init(from response: OrchestratorResponse, retainedSteerCount: Int? = nil) {
        self.init(
            text: response.text,
            sessionID: response.sessionID,
            toolActions: response.toolActions,
            totalTokens: response.totalTokens,
            modelName: response.modelName,
            contextLength: response.contextLength,
            sessionTokens: response.sessionTokens,
            contextTokens: response.contextTokens,
            isParked: response.isParked,
            warnings: response.warnings.isEmpty ? nil : response.warnings,
            completedAt: response.completedAt,
            retainedSteerCount: retainedSteerCount,
            recallDiagnostics: response.recallDiagnostics
        )
    }
}

/// Mid-turn degraded-tool notice sent by the engine over WebSocket.
/// Carries only the preformatted warning line plus its session so streaming
/// clients can surface skips without failing the turn or leaking schemas.
public struct WSWarningFrame: Codable, Sendable, Equatable {
    /// Always `"warning"`.
    public let type: String
    /// Preformatted warning line naming only the skipped tool.
    public let message: String
    /// Owning session identifier.
    public var sessionID: UUID?

    /// Creates a warning frame.
    public init(message: String, sessionID: UUID? = nil) {
        self.type = "warning"
        self.message = message
        self.sessionID = sessionID
    }

    /// Coding keys for the warning frame.
    enum CodingKeys: String, CodingKey {
        /// Frame discriminator.
        case type
        /// Preformatted warning line.
        case message
        /// Owning session.
        case sessionID
    }

    /// Decodes a warning frame, defaulting a missing discriminator for back-compat.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decodeIfPresent(String.self, forKey: .type) ?? "warning"
        self.message = try container.decode(String.self, forKey: .message)
        self.sessionID = try container.decodeIfPresent(UUID.self, forKey: .sessionID)
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
    /// Zero-based LLM round that produced this call, oldest first. Nil on payloads
    /// written before round tracking so older dashboards still decode; clients treat
    /// absent as unordered and fall back to arrival order, which remains chronological.
    public var roundIndex: Int?

    /// Creates a tool start frame.
    public init(toolName: String, callID: String, argumentsJSON: String, sessionID: UUID? = nil, roundIndex: Int? = nil) {
        self.type = "tool_start"
        self.toolName = toolName
        self.callID = callID
        self.argumentsJSON = argumentsJSON
        self.sessionID = sessionID
        self.roundIndex = roundIndex
    }

    /// Coding keys for the tool start frame.
    enum CodingKeys: String, CodingKey {
        /// Frame discriminator.
        case type
        /// Name of the tool being called.
        case toolName
        /// Correlation identifier of the call.
        case callID
        /// Raw JSON arguments sent to the tool.
        case argumentsJSON
        /// Owning session identifier.
        case sessionID
        /// Zero-based LLM round that produced the call.
        case roundIndex
    }

    /// Decodes a tool start frame, defaulting a missing round for back-compat while rejecting blank
    /// identity so a drifted payload fails here exactly where the live progress frame drops it.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decodeIfPresent(String.self, forKey: .type) ?? "tool_start"
        let toolName = try container.decode(String.self, forKey: .toolName)
        guard !toolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .toolName, in: container, debugDescription: "toolName must be non-blank")
        }
        self.toolName = toolName
        let callID = try container.decode(String.self, forKey: .callID)
        guard !callID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .callID, in: container, debugDescription: "callID must be non-blank")
        }
        self.callID = callID
        self.argumentsJSON = try container.decode(String.self, forKey: .argumentsJSON)
        self.sessionID = try container.decodeIfPresent(UUID.self, forKey: .sessionID)
        self.roundIndex = try container.decodeIfPresent(Int.self, forKey: .roundIndex)
    }

    /// Encodes a tool start frame, omitting an absent round so older decoders see no new key.
    /// - Parameter encoder: Destination encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(toolName, forKey: .toolName)
        try container.encode(callID, forKey: .callID)
        try container.encode(argumentsJSON, forKey: .argumentsJSON)
        try container.encodeIfPresent(sessionID, forKey: .sessionID)
        try container.encodeIfPresent(roundIndex, forKey: .roundIndex)
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
    /// Zero-based LLM round that produced this call, mirroring the start frame so
    /// resumed batches rejoin the same chronological timeline instead of collapsing.
    public var roundIndex: Int?

    /// Creates a tool end frame.
    public init(toolName: String, callID: String, result: ToolResult, sessionID: UUID? = nil, roundIndex: Int? = nil) {
        self.type = "tool_end"
        self.toolName = toolName
        self.callID = callID
        self.result = result
        self.sessionID = sessionID
        self.roundIndex = roundIndex
    }

    /// Coding keys for the tool end frame.
    enum CodingKeys: String, CodingKey {
        /// Frame discriminator.
        case type
        /// Name of the tool that ran.
        case toolName
        /// Correlation identifier of the call.
        case callID
        /// Result returned by the tool.
        case result
        /// Owning session identifier.
        case sessionID
        /// Zero-based LLM round that produced the call.
        case roundIndex
    }

    /// Decodes a tool end frame, defaulting a missing round for back-compat while rejecting blank
    /// identity so a drifted payload fails here exactly where the live progress frame drops it. -
    /// Parameter decoder: Source decoder.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decodeIfPresent(String.self, forKey: .type) ?? "tool_end"
        let toolName = try container.decode(String.self, forKey: .toolName)
        guard !toolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .toolName, in: container, debugDescription: "toolName must be non-blank")
        }
        self.toolName = toolName
        let callID = try container.decode(String.self, forKey: .callID)
        guard !callID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .callID, in: container, debugDescription: "callID must be non-blank")
        }
        self.callID = callID
        self.result = try container.decode(ToolResult.self, forKey: .result)
        self.sessionID = try container.decodeIfPresent(UUID.self, forKey: .sessionID)
        self.roundIndex = try container.decodeIfPresent(Int.self, forKey: .roundIndex)
    }

    /// Encodes a tool end frame, omitting an absent round for older decoders.
    /// - Parameter encoder: Destination encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(toolName, forKey: .toolName)
        try container.encode(callID, forKey: .callID)
        try container.encode(result, forKey: .result)
        try container.encodeIfPresent(sessionID, forKey: .sessionID)
        try container.encodeIfPresent(roundIndex, forKey: .roundIndex)
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

/// Per-tool cancellation message sent by a WebSocket client. The session identifier scopes the
/// request so one session can never cancel another's in-flight call, even if call identifiers
/// collide.
public struct WSToolCancelMessage: Codable, Sendable, Equatable {
    /// Always `"tool_cancel"`.
    public let type: String
    /// Session owning the call to abort.
    public let sessionID: UUID
    /// Correlation identifier of the running call to abort.
    public let callID: String
    /// Optional user reason forwarded to the model; capped server-side before
    /// it is injected into the tool history.
    public let reason: String?

    /// Creates a per-tool cancellation message.
    public init(sessionID: UUID, callID: String, reason: String? = nil) {
        self.type = "tool_cancel"
        self.sessionID = sessionID
        self.callID = callID
        self.reason = reason
    }

    /// Coding keys for the per-tool cancellation message.
    enum CodingKeys: String, CodingKey {
        /// Frame discriminator.
        case type
        /// Owning session.
        case sessionID
        /// Correlation identifier of the call.
        case callID
        /// Optional user reason.
        case reason
    }
}

/// Non-terminal acknowledgement that a per-tool cancel found nothing to stop.
public struct WSToolCancelMissFrame: Codable, Sendable, Equatable {
    /// Always `"tool_cancel_miss"`.
    public let type: String
    /// Owning session so multiplexed views only clear their own row's mark.
    public var sessionID: UUID?
    /// Correlation identifier of the call that could not be cancelled.
    public var callID: String
    /// Human-readable, non-terminal explanation for the miss.
    public var message: String?

    /// Creates a per-tool cancel miss frame.
    public init(sessionID: UUID? = nil, callID: String, message: String? = nil) {
        self.type = "tool_cancel_miss"
        self.sessionID = sessionID
        self.callID = callID
        self.message = message
    }

    /// Coding keys for the miss frame.
    enum CodingKeys: String, CodingKey {
        /// Frame discriminator.
        case type
        /// Owning session.
        case sessionID
        /// Correlation identifier of the call.
        case callID
        /// Non-terminal explanation.
        case message
    }

    /// Decodes a miss frame, defaulting a missing discriminator for back-compat. The call identity
    /// stays required so a partial payload throws here instead of clearing an unrelated row in the
    /// dashboard.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decodeIfPresent(String.self, forKey: .type) ?? "tool_cancel_miss"
        self.sessionID = try container.decodeIfPresent(UUID.self, forKey: .sessionID)
        self.callID = try container.decode(String.self, forKey: .callID)
        self.message = try container.decodeIfPresent(String.self, forKey: .message)
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

/// Session-tagged liveness heartbeat proving a turn is still processing while prompt evaluation
/// produces no deltas to stream.
public struct WSTurnAliveFrame: Codable, Sendable, Equatable {
    /// Always `"turn_alive"`.
    public let type: String
    /// Owning session so multiplexed views only re-arm their own turn.
    public var sessionID: UUID?

    /// Creates a heartbeat for a session.
    public init(sessionID: UUID? = nil) {
        self.type = "turn_alive"
        self.sessionID = sessionID
    }

    /// Coding keys for the heartbeat.
    enum CodingKeys: String, CodingKey {
        /// Frame discriminator.
        case type
        /// Owning session.
        case sessionID
    }

    /// Decodes a heartbeat, defaulting a missing discriminator for back-compat.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decodeIfPresent(String.self, forKey: .type) ?? "turn_alive"
        self.sessionID = try container.decodeIfPresent(UUID.self, forKey: .sessionID)
    }
}

/// Namespace for the heartbeat cadence and encoder paired with the frame above.
/// Kept beside the frame so the interval and the wire shape change together.
public enum WSTurnAlive: Sendable {
    /// Cadence for liveness heartbeats while a turn produces no streamable frames.
    /// Twenty seconds sits inside the window where a dashboard can distinguish a
    /// healthy long prompt evaluation from a dropped socket without spamming it.
    public static let intervalNanoseconds: UInt64 = 20_000_000_000

    /// Encodes a session-tagged liveness heartbeat, nil when encoding fails.
    /// - Parameter sessionID: Owning session.
    /// - Returns: Wire text, or nil when encoding fails.
    public static func frameText(sessionID: UUID) -> String? {
        do {
            let data = try JSONEncoder().encode(WSTurnAliveFrame(sessionID: sessionID))
            return String(data: data, encoding: .utf8)
        } catch {
            RuneWeaverLog.server.error("WSTurnAlive: failed to encode turn alive frame: \(error.localizedDescription)")
            return nil
        }
    }
}

/// Per-round token usage progress for the in-flight turn. Lets dashboards show a running turn total
/// and a live session estimate without waiting for the terminal done frame, which stays
/// authoritative for reconciliation.
public struct WSTurnTokensFrame: Codable, Sendable, Equatable {
    /// Always `"turn_tokens"`.
    public let type: String
    /// Owning session so multiplexed views only apply their own turn.
    public var sessionID: UUID?
    /// Zero-based LLM round that produced this usage, oldest first. Required so
    /// dashboards never attribute usage to the wrong round when a key goes missing.
    public var roundIndex: Int
    /// Billed tokens for this round alone, from the provider usage. Required so a
    /// missing key drops the frame instead of rendering a zeroed round.
    public var roundTokens: Int
    /// Cumulative billed tokens for this turn so far. Required so a missing key
    /// drops the frame instead of resetting the live footer.
    public var turnTotalTokens: Int
    /// Estimated context-window occupancy at this round. Optional so older engines
    /// that omit it still decode; dashboards keep their prior value when absent.
    public var contextTokens: Int?

    /// Creates a token progress frame.
    public init(sessionID: UUID? = nil, roundIndex: Int, roundTokens: Int, turnTotalTokens: Int, contextTokens: Int? = nil) {
        self.type = "turn_tokens"
        self.sessionID = sessionID
        self.roundIndex = roundIndex
        self.roundTokens = roundTokens
        self.turnTotalTokens = turnTotalTokens
        self.contextTokens = contextTokens
    }

    /// Coding keys for the token progress frame.
    enum CodingKeys: String, CodingKey {
        /// Frame discriminator.
        case type
        /// Owning session.
        case sessionID
        /// Zero-based LLM round.
        case roundIndex
        /// Billed tokens for this round.
        case roundTokens
        /// Cumulative billed tokens for the turn.
        case turnTotalTokens
        /// Context-window occupancy estimate.
        case contextTokens
    }

    /// Decodes a token progress frame, defaulting a missing discriminator for back-compat while
    /// requiring every counter so a partial payload throws and the caller drops it instead of
    /// rendering zeroed progress.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decodeIfPresent(String.self, forKey: .type) ?? "turn_tokens"
        self.sessionID = try container.decodeIfPresent(UUID.self, forKey: .sessionID)
        let roundIndex = try container.decode(Int.self, forKey: .roundIndex)
        guard roundIndex >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .roundIndex, in: container, debugDescription: "roundIndex must be non-negative")
        }
        self.roundIndex = roundIndex
        let roundTokens = try container.decode(Int.self, forKey: .roundTokens)
        guard roundTokens >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .roundTokens, in: container, debugDescription: "roundTokens must be non-negative")
        }
        self.roundTokens = roundTokens
        let turnTotalTokens = try container.decode(Int.self, forKey: .turnTotalTokens)
        guard turnTotalTokens >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .turnTotalTokens, in: container, debugDescription: "turnTotalTokens must be non-negative")
        }
        self.turnTotalTokens = turnTotalTokens
        let contextTokens = try container.decodeIfPresent(Int.self, forKey: .contextTokens)
        if let contextTokens, contextTokens < 0 {
            throw DecodingError.dataCorruptedError(forKey: .contextTokens, in: container, debugDescription: "contextTokens must be non-negative")
        }
        self.contextTokens = contextTokens
    }
}

/// Generic indeterminate progress reported by any tool while it runs.
public struct WSToolProgressFrame: Codable, Sendable, Equatable {
    /// Always `"tool_progress"`.
    public let type: String
    /// Owning session so multiplexed views only apply their own turn.
    public var sessionID: UUID?
    /// Correlation identifier of the call this progress belongs to.
    public var callID: String
    /// Name of the tool reporting progress.
    public var toolName: String
    /// Human-readable status line.
    public var message: String
    /// Advisory broad-scope warning for ``message``, when the emitter has one.
    public var warning: String?
    /// Items examined so far. Required so a missing key drops the frame instead
    /// of rendering a zeroed count.
    public var scanned: Int
    /// Items matched so far. Required for the same reason as ``scanned``.
    public var matched: Int
    /// Milliseconds elapsed since the call began, required for the same reason.
    public var elapsedMs: Int
    /// Relative display path of the item currently being processed, if any.
    /// Absolute or traversing candidates degrade to nil rather than leaking.
    public var current: String?

    /// Creates a progress frame.
    public init(
        sessionID: UUID? = nil,
        callID: String,
        toolName: String,
        message: String,
        warning: String? = nil,
        scanned: Int,
        matched: Int,
        elapsedMs: Int,
        current: String? = nil
    ) {
        self.type = "tool_progress"
        self.sessionID = sessionID
        self.callID = callID
        self.toolName = toolName
        self.message = message
        self.warning = ToolProgress.normalizedWarning(warning)
        self.scanned = max(0, scanned)
        self.matched = max(0, matched)
        self.elapsedMs = max(0, elapsedMs)
        self.current = ToolProgress.relativeCurrent(current)
    }

    /// Creates a frame from a tool-emitted value, preserving its sanitized path.
    /// progress: Emitted progress, already attributed by the bus.
    public init(_ progress: ToolProgress, sessionID: UUID? = nil) {
        self.init(
            sessionID: sessionID,
            callID: progress.callID,
            toolName: progress.toolName,
            message: progress.message,
            warning: progress.warning,
            scanned: progress.scanned,
            matched: progress.matched,
            elapsedMs: progress.elapsedMs,
            current: progress.current
        )
    }

    /// Coding keys for the progress frame.
    enum CodingKeys: String, CodingKey {
        /// Frame discriminator.
        case type
        /// Owning session.
        case sessionID
        /// Correlation identifier of the call.
        case callID
        /// Name of the reporting tool.
        case toolName
        /// Human-readable status line.
        case message
        /// Advisory broad-scope warning for the status line.
        case warning
        /// Items examined so far.
        case scanned
        /// Items matched so far.
        case matched
        /// Milliseconds elapsed.
        case elapsedMs
        /// Relative display path of the current item.
        case current
    }

    /// Decodes a progress frame, defaulting a missing discriminator for back-compat while requiring
    /// identity and every numeric field so a partial payload throws and the caller drops it instead
    /// of rendering mis-attributed progress.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decodeIfPresent(String.self, forKey: .type) ?? "tool_progress"
        self.sessionID = try container.decodeIfPresent(UUID.self, forKey: .sessionID)
        // Identity is the attribution anchor: a frame with a blank call or tool cannot be matched
        // to a live row, so it fails here exactly where the dashboard guard rejects blank identity
        // instead of rendering mis-attributed progress.
        let callID = try container.decode(String.self, forKey: .callID)
        guard !callID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .callID, in: container, debugDescription: "callID must be non-blank")
        }
        self.callID = callID
        let toolName = try container.decode(String.self, forKey: .toolName)
        guard !toolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .toolName, in: container, debugDescription: "toolName must be non-blank")
        }
        self.toolName = toolName
        self.message = try container.decode(String.self, forKey: .message)
        // Optional like the relative tail: a frame without a warning is valid, and a blank,
        // drifted, or non-string warning degrades to absent instead of dropping an otherwise
        // complete progress line.
        let rawWarning = try? container.decode(String.self, forKey: .warning)
        self.warning = ToolProgress.normalizedWarning(rawWarning)
        let scanned = try container.decode(Int.self, forKey: .scanned)
        guard scanned >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .scanned, in: container, debugDescription: "scanned must be non-negative")
        }
        self.scanned = scanned
        let matched = try container.decode(Int.self, forKey: .matched)
        guard matched >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .matched, in: container, debugDescription: "matched must be non-negative")
        }
        self.matched = matched
        let elapsedMs = try container.decode(Int.self, forKey: .elapsedMs)
        guard elapsedMs >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .elapsedMs, in: container, debugDescription: "elapsedMs must be non-negative")
        }
        self.elapsedMs = elapsedMs
        // Sanitize on the way in as well as out so a peer cannot smuggle an absolute path into view
        // state through a handcrafted frame.
        self.current = ToolProgress.relativeCurrent(try? container.decode(String.self, forKey: .current))
    }
}

// MARK: - Goal pursuit and proactive outreach frames

// Outbound live kinds beyond chat turns: `goal_updated` carries the current goal snapshot so
// dashboards refresh one row without refetching the list, while `proactive_message` carries an
// owner-visible nudge (kind, title, headline) that the engine volunteers outside any turn.

/// Finished-versus-planned tally for one goal.
public struct WSGoalProgress: Codable, Sendable, Equatable {
    /// Steps finished.
    public let done: Int
    /// Steps in the plan.
    public let total: Int

    /// Creates a progress tally, clamping drifted negatives to zero so a
    /// handcrafted frame never renders a negative fraction.
    public init(done: Int, total: Int) {
        self.done = max(0, done)
        self.total = max(0, total)
    }
}

/// Wire snapshot of one goal for `goal_updated` frames.
public struct WSGoalSnapshot: Codable, Sendable, Equatable {
    /// Stable goal identifier.
    public let id: UUID
    /// Short human-readable title.
    public let title: String
    /// Fuller statement of intent.
    public let statement: String
    /// Lifecycle state raw value (`active`, `paused`, `needs_input`, ...).
    public let status: String
    /// Finished-versus-planned tally.
    public let progress: WSGoalProgress
    /// Cadence hint in minutes between due advancements.
    public let stepIntervalMinutes: Int
    /// Next time the goal becomes due; nil means no schedule.
    public let nextDueAt: Date?
    /// Session that originated the goal, when known.
    public let originSessionID: UUID?
    /// When the goal was first persisted.
    public let createdAt: Date
    /// When the goal row last changed.
    public let updatedAt: Date
    /// Whether the agent is actively planning or drafting steps for this goal.
    public let isPlanning: Bool?

    /// Creates a snapshot.
    public init(
        id: UUID,
        title: String,
        statement: String,
        status: String,
        progress: WSGoalProgress,
        stepIntervalMinutes: Int,
        nextDueAt: Date? = nil,
        originSessionID: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isPlanning: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.statement = statement
        self.status = status
        self.progress = progress
        self.stepIntervalMinutes = stepIntervalMinutes
        self.nextDueAt = nextDueAt
        self.originSessionID = originSessionID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isPlanning = isPlanning
    }

    /// Coding keys for the snapshot.
    enum CodingKeys: String, CodingKey {
        /// Stable goal identifier.
        case id
        /// Short title.
        case title
        /// Fuller statement.
        case statement
        /// Lifecycle state.
        case status
        /// Progress tally.
        case progress
        /// Cadence hint.
        case stepIntervalMinutes
        /// Next due instant.
        case nextDueAt
        /// Origin session under the canonical wire spelling.
        case originSessionId
        /// Creation instant.
        case createdAt
        /// Last-change instant.
        case updatedAt
        /// Active planning indicator.
        case isPlanning
    }

    /// Decodes tolerantly across the origin-session spellings so payloads written with either of
    /// the two historical keys land on one field instead of failing the push.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.title = try container.decode(String.self, forKey: .title)
        self.statement = try container.decode(String.self, forKey: .statement)
        self.status = try container.decode(String.self, forKey: .status)
        self.progress = try container.decode(WSGoalProgress.self, forKey: .progress)
        self.stepIntervalMinutes = try container.decode(Int.self, forKey: .stepIntervalMinutes)
        self.nextDueAt = try container.decodeIfPresent(Date.self, forKey: .nextDueAt)
        self.originSessionID = try container.decodeIfPresent(UUID.self, forKey: .originSessionId)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.isPlanning = try container.decodeIfPresent(Bool.self, forKey: .isPlanning)
    }

    /// Encodes under the canonical wire spellings so older decoders see no new key.
    /// - Parameter encoder: Destination encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(statement, forKey: .statement)
        try container.encode(status, forKey: .status)
        try container.encode(progress, forKey: .progress)
        try container.encode(stepIntervalMinutes, forKey: .stepIntervalMinutes)
        try container.encodeIfPresent(nextDueAt, forKey: .nextDueAt)
        try container.encodeIfPresent(originSessionID, forKey: .originSessionId)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(isPlanning, forKey: .isPlanning)
    }
}

/// Goal change broadcast sent by the engine over WebSocket.
public struct WSGoalUpdatedFrame: Codable, Sendable, Equatable {
    /// Always `"goal_updated"`.
    public let type: String
    /// Current goal snapshot.
    public let goal: WSGoalSnapshot

    /// Creates a goal update frame.
    public init(goal: WSGoalSnapshot) {
        self.type = "goal_updated"
        self.goal = goal
    }

    /// Coding keys for the update frame.
    enum CodingKeys: String, CodingKey {
        /// Frame discriminator.
        case type
        /// Current goal snapshot.
        case goal
    }

    /// Decodes an update frame, defaulting a missing discriminator for back-compat.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decodeIfPresent(String.self, forKey: .type) ?? "goal_updated"
        self.goal = try container.decode(WSGoalSnapshot.self, forKey: .goal)
    }
}

/// Owner-visible nudge volunteered by the engine outside any turn. Blank kind, title, or headline
/// fail decoding here exactly where the dashboard guard drops them, instead of rendering an empty
/// card.
public struct WSProactiveMessageFrame: Codable, Sendable, Equatable {
    /// Always `"proactive_message"`.
    public let type: String
    /// Trigger family naming why the engine volunteered this card.
    public let kind: String
    /// Short card title.
    public let title: String
    /// One-line card body.
    public let headline: String
    /// Owning session for deep-linking, when the nudge belongs to one turn.
    public var sessionID: UUID?
    /// Owning goal for deep-linking, when the nudge belongs to one goal.
    public var goalID: UUID?

    /// Creates a proactive message frame.
    public init(kind: String, title: String, headline: String, sessionID: UUID? = nil, goalID: UUID? = nil) {
        self.type = "proactive_message"
        self.kind = kind
        self.title = title
        self.headline = headline
        self.sessionID = sessionID
        self.goalID = goalID
    }

    /// Coding keys for the proactive frame. The remaining cases stay decode-only so historical
    /// payloads still land without forking the encoded shape.
    enum CodingKeys: String, CodingKey {
        /// Frame discriminator.
        case type
        /// Trigger family.
        case kind
        /// Short card title.
        case title
        /// One-line card body.
        case headline
        /// Owning session.
        case sessionID
        /// Owning goal under the canonical spelling.
        case goalId
    }

    /// Decodes a proactive frame, defaulting a missing discriminator while rejecting blank card
    /// text so a drifted payload fails here exactly where the dashboard guard drops it.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decodeIfPresent(String.self, forKey: .type) ?? "proactive_message"
        let kind = try container.decode(String.self, forKey: .kind)
        guard !kind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "kind must be non-blank")
        }
        self.kind = kind
        let title = try container.decode(String.self, forKey: .title)
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .title, in: container, debugDescription: "title must be non-blank")
        }
        self.title = title
        let headline = try container.decode(String.self, forKey: .headline)
        guard !headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .headline, in: container, debugDescription: "headline must be non-blank")
        }
        self.headline = headline
        self.sessionID = try container.decodeIfPresent(UUID.self, forKey: .sessionID)
        self.goalID = try container.decodeIfPresent(UUID.self, forKey: .goalId)
    }

    /// Encodes under the canonical spellings so older decoders see no new key.
    /// - Parameter encoder: Destination encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(kind, forKey: .kind)
        try container.encode(title, forKey: .title)
        try container.encode(headline, forKey: .headline)
        try container.encodeIfPresent(sessionID, forKey: .sessionID)
        try container.encodeIfPresent(goalID, forKey: .goalId)
    }
}

extension WSProactiveMessageFrame {
    /// Kind naming a proactive card that announces a freshly proposed idea.
    public static let ideaProposedKind = "idea_proposed"
}

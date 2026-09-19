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

    /// Whether to grant tool-wide trust matching any target, defaulting to
    /// `false` so an omitted flag never silently widens a grant. Clients may
    /// omit the key, so the narrow default lives here instead of at each call
    /// site where it could drift.
    /// - Returns: Resolved widen flag.
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
    /// every action; nil for text-only or legacy turns.
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
    /// Late steering still queued server-side at turn completion. Lets dashboards
    /// keep exactly the newest retained bubbles for the next turn and release the
    /// consumed ones answered here; nil on older engines where clients clear as
    /// answered. Counted at done construction so the terminal frame and the queue
    /// agree without an extra round trip.
    public var retainedSteerCount: Int?

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
        retainedSteerCount: Int? = nil
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
    }

    /// Decodes a terminal frame, defaulting a missing parked flag for back-compat
    /// while rejecting negative token counters so a drifted payload fails here
    /// exactly where the live progress frame drops it, instead of reconciling to
    /// a negative total. Integer decoding already rejects fractional counters; the
    /// explicit guards below reject negatives to match `WSTurnTokensFrame`.
    /// - Parameter decoder: Source decoder.
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
            retainedSteerCount: retainedSteerCount
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

    /// Decodes a tool start frame, defaulting a missing round for back-compat.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decodeIfPresent(String.self, forKey: .type) ?? "tool_start"
        self.toolName = try container.decode(String.self, forKey: .toolName)
        self.callID = try container.decode(String.self, forKey: .callID)
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

    /// Decodes a tool end frame, defaulting a missing round for back-compat.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decodeIfPresent(String.self, forKey: .type) ?? "tool_end"
        self.toolName = try container.decode(String.self, forKey: .toolName)
        self.callID = try container.decode(String.self, forKey: .callID)
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

/// Trust-grant change signal pushed by the engine over WebSocket.
///
/// Dashboards keep the trust list fresh by listening for this push instead of
/// polling the grants endpoint, so a grant stored in one tab appears in every
/// other tab without refresh lag, without extra request load, and without
/// risking a stale allowlist when the next approval is judged.
public struct WSTrustGrantsChanged: Codable, Sendable, Equatable {
    /// Always `"trust_grants_changed"`.
    public let type: String

    /// Creates a trust-grant change signal.
    public init() {
        self.type = "trust_grants_changed"
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

/// Session-tagged liveness heartbeat proving a turn is still processing while
/// prompt evaluation produces no deltas to stream. Older dashboards decode an
/// unknown `type` as ignorable, so they drop this without rendering while newer
/// clients re-arm their inactivity timer on it. Lives here so REST and WebSocket
/// turns share one encoding; the TypeScript `WSTurnAliveFrame` mirrors this shape.
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
        guard let data = try? JSONEncoder().encode(WSTurnAliveFrame(sessionID: sessionID)),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return text
    }
}

/// Per-round token usage progress for the in-flight turn. Lets dashboards show a
/// running turn total and a live session estimate without waiting for the terminal
/// done frame, which stays authoritative for reconciliation. Session-tagged like
/// the heartbeat so multiplexed views only apply their own turn and older clients
/// drop the unknown `type` without rendering. Counters stay required so a partial
/// payload never renders as zeroed progress. Lives here so REST and WebSocket
/// turns share one encoding; the TypeScript `WSTurnTokensFrame` mirrors this shape
/// with the same required integer counters and drops frames missing any of them.
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

    /// Creates a token progress frame.
    public init(sessionID: UUID? = nil, roundIndex: Int, roundTokens: Int, turnTotalTokens: Int) {
        self.type = "turn_tokens"
        self.sessionID = sessionID
        self.roundIndex = roundIndex
        self.roundTokens = roundTokens
        self.turnTotalTokens = turnTotalTokens
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
    }

    /// Decodes a token progress frame, defaulting a missing discriminator for back-compat
    /// while requiring every counter so a partial payload throws and the caller drops
    /// it instead of rendering zeroed progress.
    /// Counters must stay non-negative integers so a drifted fractional or negative
    /// payload fails here exactly where the dashboard guard drops it, instead of
    /// decoding in tests while vanishing live.
    /// - Parameter decoder: Source decoder.
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
    }
}

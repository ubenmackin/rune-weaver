// Rune Weaver Core — Orchestrator public contract types.
// Holds the turn input, tool-action, response, event, and parked-approval value types shared
// by the orchestration loop, the service routes, and the CLI. Keeping the wire and resume
// contract in one place lets the loop file stay focused on execution while the shapes it
// exchanges remain stable across callers.

import Foundation

/// Convenience alias for the conversation role.
public typealias Role = Message.Role

/// User input received by the orchestrator.
public struct UserInput: Sendable, Codable, Equatable {
    /// Raw user text (or voice transcription).
    public let text: String
    /// Owning session identifier.
    public let sessionID: UUID
    /// Input origin (e.g. `"text"`, `"voice"`, `"dashboard"`).
    public let source: String
    /// Optional turn-specific system prompt override.
    public let systemPrompt: String?

    /// Creates user input.
    public init(text: String, sessionID: UUID = UUID(), source: String = "text", systemPrompt: String? = nil) {
        self.text = text
        self.sessionID = sessionID
        self.source = source
        self.systemPrompt = systemPrompt
    }
}

/// One tool invocation performed while answering.
public struct ToolAction: Sendable, Codable, Equatable {
    /// Name of the tool that ran.
    public let toolName: String
    /// Correlation identifier of the call.
    public let callID: String
    /// Raw JSON arguments sent to the tool.
    public let argumentsJSON: String
    /// Result returned by the bus, if the call ran.
    public let result: ToolResult?
    /// Zero-based LLM round that produced this call, oldest first. Nil on payloads
    /// written before round tracking so legacy history still decodes; clients treat
    /// absent as unordered and fall back to stored order, which remains chronological.
    public let roundIndex: Int?
    /// Whether the call succeeded.
    public var didSucceed: Bool {
        result?.isError == false
    }

    /// Coding keys matching the persisted and wire shape.
    private enum CodingKeys: String, CodingKey {
        /// Name of the tool that ran.
        case toolName
        /// Correlation identifier of the call.
        case callID
        /// Raw JSON arguments sent to the tool.
        case argumentsJSON
        /// Result returned by the bus.
        case result
        /// Zero-based LLM round that produced the call.
        case roundIndex
    }

    /// Creates a tool action.
    public init(toolName: String, callID: String, argumentsJSON: String, result: ToolResult? = nil, roundIndex: Int? = nil) {
        self.toolName = toolName
        self.callID = callID
        self.argumentsJSON = argumentsJSON
        self.result = result
        self.roundIndex = roundIndex
    }

    /// Decodes a tool action, defaulting a missing round to unordered for back-compat.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.toolName = try container.decode(String.self, forKey: .toolName)
        self.callID = try container.decode(String.self, forKey: .callID)
        self.argumentsJSON = try container.decode(String.self, forKey: .argumentsJSON)
        self.result = try container.decodeIfPresent(ToolResult.self, forKey: .result)
        self.roundIndex = try container.decodeIfPresent(Int.self, forKey: .roundIndex)
    }

    /// Encodes a tool action, omitting an absent round so older decoders see no new key.
    /// - Parameter encoder: Destination encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(toolName, forKey: .toolName)
        try container.encode(callID, forKey: .callID)
        try container.encode(argumentsJSON, forKey: .argumentsJSON)
        try container.encodeIfPresent(result, forKey: .result)
        try container.encodeIfPresent(roundIndex, forKey: .roundIndex)
    }
}

/// Response returned by the orchestrator.
public struct OrchestratorResponse: Sendable, Codable, Equatable {
    /// Final assistant text.
    public let text: String
    /// Owning session identifier.
    public let sessionID: UUID
    /// Tool invocations performed while answering.
    public let toolActions: [ToolAction]
    /// Session-billed tokens accumulated across every LLM round in this turn (each round's
    /// `totalTokens`, summed). Nil when no round reported usage, mirroring the CLI
    /// `runChunkedTurn`/`runTextTurn` session total for the API path.
    public let totalTokens: Int?
    /// Serving model name.
    public let modelName: String?
    /// Context window limit in tokens.
    public let contextLength: Int?
    /// Cumulative billed tokens for this session, if tracked.
    public let sessionTokens: Int?
    /// Whether this turn parked waiting on approval.
    public let isParked: Bool
    /// Degraded-tool notices for tools omitted this turn. Carries only tool names
    /// plus a static reason so no secrets or schema payloads reach the wire.
    public let warnings: [String]
    /// Completion time as Unix seconds since 1970 on the server clock. Optional so
    /// older engines that omit it still decode; clients fall back to receipt time.
    public let completedAt: Double?

    /// Coding keys matching the JSON wire shape.
    private enum CodingKeys: String, CodingKey {
        /// Final assistant text.
        case text
        /// Owning session identifier.
        case sessionID
        /// Tool invocations performed.
        case toolActions
        /// Session-billed tokens.
        case totalTokens
        /// Serving model name.
        case modelName
        /// Context window limit.
        case contextLength
        /// Cumulative billed tokens.
        case sessionTokens
        /// Whether the turn parked waiting on approval.
        case isParked
        /// Degraded-tool notices.
        case warnings
        /// Completion time as Unix seconds.
        case completedAt
    }

    /// Creates a response.
    public init(
        text: String,
        sessionID: UUID,
        toolActions: [ToolAction] = [],
        totalTokens: Int? = nil,
        modelName: String? = nil,
        contextLength: Int? = nil,
        sessionTokens: Int? = nil,
        isParked: Bool = false,
        warnings: [String] = [],
        completedAt: Double? = nil
    ) {
        self.text = text
        self.sessionID = sessionID
        self.toolActions = toolActions
        self.totalTokens = totalTokens
        self.modelName = modelName
        self.contextLength = contextLength
        self.sessionTokens = sessionTokens
        self.isParked = isParked
        self.warnings = warnings
        // Callers stamp the persisted assistant note's creation time so live turns and
        // history reloads share one instant; nil when suppressed text persisted no note
        // keeps equality deterministic and lets clients fall back to receipt time.
        self.completedAt = completedAt
    }

    /// Decodes a response, defaulting missing parked flags to not parked and missing warnings to empty
    /// while rejecting negative token counters so a drifted payload fails here exactly
    /// where the live progress frame drops it, instead of reconciling to a negative total.
    /// Integer decoding already rejects fractional counters; the explicit guards below
    /// reject negatives to match `WSTurnTokensFrame`.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.text = try container.decode(String.self, forKey: .text)
        self.sessionID = try container.decode(UUID.self, forKey: .sessionID)
        self.toolActions = try container.decodeIfPresent([ToolAction].self, forKey: .toolActions) ?? []
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
        self.isParked = try container.decodeIfPresent(Bool.self, forKey: .isParked) ?? false
        self.warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
        self.completedAt = try container.decodeIfPresent(Double.self, forKey: .completedAt)
    }

    /// Encodes a response.
    /// - Parameter encoder: Destination encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(toolActions, forKey: .toolActions)
        try container.encodeIfPresent(totalTokens, forKey: .totalTokens)
        try container.encodeIfPresent(modelName, forKey: .modelName)
        try container.encodeIfPresent(contextLength, forKey: .contextLength)
        try container.encodeIfPresent(sessionTokens, forKey: .sessionTokens)
        try container.encode(isParked, forKey: .isParked)
        // Omit empty warnings so older decoders see an absent key and degrade to no banner,
        // mirroring WSStreamDone which nils empty lists for back-compat.
        if !warnings.isEmpty {
            try container.encode(warnings, forKey: .warnings)
        }
        // Omit an absent completion so older decoders see no new key.
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
    }
}

/// Failures raised by ``Orchestrator``.
public enum OrchestratorError: Error, Sendable, Equatable {
    /// The input text was empty or whitespace-only.
    case emptyInput
    /// The tool loop still requested tool calls after `maxToolIterations`
    /// tool rounds plus the final synthesis turn.
    case toolLoopExceeded(iterations: Int)
    /// The LLM stream reported a mid-stream failure, even when partial
    /// text was already yielded. Surfaced instead of finishing the turn
    /// as a silent success.
    case llmFailed(String)
}

extension OrchestratorError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyInput:
            "Input text was empty or whitespace-only."
        case let .toolLoopExceeded(iterations):
            "Tool loop exceeded \(iterations) rounds."
        case let .llmFailed(detail):
            detail
        }
    }
}

/// Real-time progress event emitted during turn orchestration.
public enum OrchestratorEvent: Sendable, Codable, Equatable {
    /// Tool execution is about to begin.
    case toolStarted(toolName: String, callID: String, argumentsJSON: String, roundIndex: Int?)
    /// Tool execution has completed.
    case toolCompleted(toolName: String, callID: String, result: ToolResult, roundIndex: Int?)
    /// Incremental assistant text delta generated by the model.
    case textDelta(String)
    /// Filed narrated approval awaiting an inbox decision.
    case approval(PermissionRequest)
    /// Degraded-tool notice for a tool omitted this turn. Carries only the
    /// preformatted warning line so no schema payloads reach subscribers.
    case warning(String)
    /// Per-round token usage for the in-flight turn. Emitted after each LLM round
    /// that reports usage so dashboards can show a running turn total and a live
    /// session estimate without waiting for the terminal done frame, which stays
    /// authoritative for reconciliation. Missing usage emits nothing so views keep
    /// prior totals instead of zeroing.
    case turnTokens(roundIndex: Int, roundTokens: Int, turnTotalTokens: Int)
}

/// Parked narrated approval awaiting a later decision.
public struct ParkedNarratedApproval: Sendable, Equatable {
    /// Owning session the narration parked in.
    public let sessionID: UUID
    /// Gated invocation filed for approval.
    public let toolCall: ToolInput
    /// Effective system prompt active when the turn parked.
    public let systemPrompt: String?
    /// Recall context active when the turn parked, so resumed synthesis keeps the
    /// same prefix instead of dropping prior-run state.
    public let recall: Message?
    /// Per-turn batch identifier shared by siblings parked together.
    public let batchID: UUID
    /// Zero-based LLM round that produced this gated call, so resumed turns can
    /// rejoin the same chronological timeline instead of collapsing to one bucket.
    public let roundIndex: Int?
    /// Zero-based round for the resumed synthesis turn, one past the gated batch so
    /// live token progress never reuses a pre-park round.
    public let synthesisRoundIndex: Int
    /// Billed tokens accumulated before parking, so resumed synthesis can report a
    /// cumulative turn total instead of resetting to the synthesis round alone.
    public let billedTokens: Int?

    /// Creates a parked approval.
    public init(
        sessionID: UUID,
        toolCall: ToolInput,
        systemPrompt: String? = nil,
        recall: Message? = nil,
        batchID: UUID = UUID(),
        roundIndex: Int? = nil,
        billedTokens: Int? = nil,
        synthesisRoundIndex: Int? = nil
    ) {
        self.sessionID = sessionID
        self.toolCall = toolCall
        self.systemPrompt = systemPrompt
        self.recall = recall
        self.batchID = batchID
        self.roundIndex = roundIndex
        // Default derives one past the gated batch so callers that only know the
        // gated round still resume chronologically; untracked history resumes at zero.
        self.synthesisRoundIndex = synthesisRoundIndex ?? (roundIndex ?? -1) + 1
        self.billedTokens = billedTokens
    }
}

/// Synthesized text for a resumed parked turn.
/// Named fields keep the resume path readable at call sites where an anonymous triple
/// would hide which value is billed usage versus the completion stamp.
struct ParkedTurnSynthesis: Sendable {
    /// Final assistant text for the resumed turn.
    let text: String
    /// Billed tokens reported by the synthesis round, if any.
    let billedTokens: Int?
    /// Completion instant taken from the persisted note so live and reload agree; nil
    /// when suppressed text persisted no note so equality stays deterministic and
    /// clients fall back to receipt time.
    let completedAt: Double?
}

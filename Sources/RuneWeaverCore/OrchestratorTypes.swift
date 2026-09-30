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
    /// Goal this turn's session works toward, when the caller tags one.
    /// The orchestrator stamps the session link on creation; untagged chat
    /// turns carry nil and never disturb an existing link.
    public let goalID: UUID?
    /// Explicit tool names this turn may call, or nil for the full registry.
    /// Fan-out workers carry the read-only subset so research fan-out cannot
    /// mutate state; the orchestrator tool loop filters its registry snapshot
    /// by this list before the loop, so the prompt and the wire advertise only
    /// the callable subset.
    public let allowedTools: [String]?
    /// Optional display title this turn stamps on its session, when the caller
    /// names the work (e.g. a fan-out subtask title). Nil leaves an existing
    /// stored title alone.
    public let title: String?
    /// Session that spawned this turn's session, when the caller nests it
    /// (e.g. a fan-out worker under the session that invoked the swarm).
    /// Nil never clears a stored parent link.
    public let parentSessionID: UUID?

    /// Coding keys matching the persisted and wire shape, with the goal tag on
    /// the shared `goalId` spelling plus a tolerant legacy fallback.
    private enum CodingKeys: String, CodingKey {
        case text
        case sessionID
        case source
        case systemPrompt
        case goalID = "goalId"
        case goalIDLegacy = "goalID"
        case allowedTools
        case title
        case parentSessionID
    }

    /// Creates user input.
    public init(
        text: String,
        sessionID: UUID = UUID(),
        source: String = "text",
        systemPrompt: String? = nil,
        goalID: UUID? = nil,
        allowedTools: [String]? = nil,
        title: String? = nil,
        parentSessionID: UUID? = nil
    ) {
        self.text = text
        self.sessionID = sessionID
        self.source = source
        self.systemPrompt = systemPrompt
        self.goalID = goalID
        self.allowedTools = allowedTools
        self.title = title
        self.parentSessionID = parentSessionID
    }

    /// Decodes user input, defaulting a missing goal tag to untagged, a missing
    /// tool subset to the full registry, and missing origin fields to nil so
    /// inputs encoded before goal linkage, fan-out, or worker nesting decode.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.text = try container.decode(String.self, forKey: .text)
        self.sessionID = try container.decode(UUID.self, forKey: .sessionID)
        self.source = try container.decode(String.self, forKey: .source)
        self.systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt)
        self.goalID = try container.decodeIfPresent(UUID.self, forKey: .goalID)
            ?? container.decodeIfPresent(UUID.self, forKey: .goalIDLegacy)
        self.allowedTools = try container.decodeIfPresent([String].self, forKey: .allowedTools)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.parentSessionID = try container.decodeIfPresent(UUID.self, forKey: .parentSessionID)
    }

    /// Encodes user input, omitting absent goal, tool-subset, title, and parent
    /// fields so older decoders see no new keys.
    /// - Parameter encoder: Destination encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(systemPrompt, forKey: .systemPrompt)
        try container.encodeIfPresent(goalID, forKey: .goalID)
        try container.encodeIfPresent(allowedTools, forKey: .allowedTools)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(parentSessionID, forKey: .parentSessionID)
    }

    /// Filters a tool snapshot down to the input's allowed subset.
    ///
    /// Fan-out workers carry an explicit allowed list so research fan-out
    /// cannot mutate state; nil keeps the full registry so plain turns pay
    /// nothing. Names match exactly (no aliases, no prefixes) because the
    /// subset is composed from registry names the caller already observed,
    /// and the snapshot's order is preserved so prompt and wire bytes stay
    /// identical for server prefix caching.
    /// - Parameters:
    ///   - tools: Registry snapshot (sorted, disabled tools omitted).
    ///   - allowed: Explicit tool names to keep, or nil for the full registry.
    /// - Returns: The filtered snapshot.
    public static func filteredTools(_ tools: [any Tool], allowed: [String]?) -> [any Tool] {
        guard let allowed else { return tools }
        let allowedSet = Set(allowed)
        return tools.filter { allowedSet.contains($0.name) }
    }
}

/// Category of tool error for reporting and UI distinction.
public enum ToolErrorKind: String, Sendable, Codable, Equatable {
    /// Attempted invocation of an unknown, unregistered, or disabled tool name.
    case invalidTool = "invalid_tool"
    /// Tool exists, but arguments failed JSON parsing or schema validation.
    case invalidSyntax = "invalid_syntax"
    /// Valid tool and arguments, but runtime execution failed.
    case executionError = "execution_error"
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
    /// Active context tokens in the model's KV cache at turn completion.
    public let contextTokens: Int?
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
        /// Active context tokens in KV cache.
        case contextTokens
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
        contextTokens: Int? = nil,
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
        self.contextTokens = contextTokens
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
        let contextTokens = try container.decodeIfPresent(Int.self, forKey: .contextTokens)
        if let contextTokens, contextTokens < 0 {
            throw DecodingError.dataCorruptedError(forKey: .contextTokens, in: container, debugDescription: "contextTokens must be non-negative")
        }
        self.contextTokens = contextTokens
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
        try container.encodeIfPresent(contextTokens, forKey: .contextTokens)
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

/// Resolved automatic recall plus starter footing for one turn.
/// Named fields keep the shared turn wiring readable at call sites where an
/// anonymous 4-tuple would trip `large_tuple` and hide which value carries
/// diagnostics versus the deterministic plan.
public struct TurnRecallAndStarter: Sendable, Equatable {
    /// Recall message for the stable slot, nil when the turn stays silent.
    public let recall: Message?
    /// Trusted starter pack for the second stable slot, nil when absent.
    public let starterPack: Message?
    /// Per-turn recall observability, safe to log.
    public let diagnostics: RecallDiagnostics
    /// Deterministic plan that produced the recall.
    public let plan: RecallPlan

    /// Creates resolved turn recall and starter footing.
    public init(recall: Message?, starterPack: Message?, diagnostics: RecallDiagnostics, plan: RecallPlan) {
        self.recall = recall
        self.starterPack = starterPack
        self.diagnostics = diagnostics
        self.plan = plan
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
    /// Incremental model reasoning / thought delta generated by thinking models.
    case reasoningDelta(String)
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
    case turnTokens(roundIndex: Int, roundTokens: Int, turnTotalTokens: Int, contextTokens: Int? = nil)
    /// Generic indeterminate progress from a tool that is still running. Emitted
    /// only when a tool chooses to report through its context, so subscribers must
    /// treat it as advisory: dropping it never affects the turn's outcome, and the
    /// terminal tool result remains the authoritative record.
    case toolProgress(ToolProgress)
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
    /// Starter footing active when the turn parked, so resumed synthesis reuses
    /// the turn's pack verbatim instead of recomposing from the live engine.
    public let starterPack: Message?
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
    /// Actions executed prior to parking in this turn.
    public let priorActions: [ToolAction]
    /// Tool round counter accumulated before parking.
    public let toolRounds: Int
    /// Active context tokens in KV cache before parking.
    public let contextTokens: Int?

    /// Creates a parked approval.
    public init(
        sessionID: UUID,
        toolCall: ToolInput,
        systemPrompt: String? = nil,
        recall: Message? = nil,
        starterPack: Message? = nil,
        batchID: UUID = UUID(),
        roundIndex: Int? = nil,
        billedTokens: Int? = nil,
        synthesisRoundIndex: Int? = nil,
        priorActions: [ToolAction] = [],
        toolRounds: Int = 0,
        contextTokens: Int? = nil
    ) {
        self.sessionID = sessionID
        self.toolCall = toolCall
        self.systemPrompt = systemPrompt
        self.recall = recall
        self.starterPack = starterPack
        self.batchID = batchID
        self.roundIndex = roundIndex
        // Default derives one past the gated batch so callers that only know the
        // gated round still resume chronologically; untracked history resumes at zero.
        self.synthesisRoundIndex = synthesisRoundIndex ?? (roundIndex ?? -1) + 1
        self.billedTokens = billedTokens
        self.priorActions = priorActions
        self.toolRounds = toolRounds
        self.contextTokens = contextTokens
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

/// Context grouping the inputs for one parked-approval filing path.
struct ParkGatedCallsContext {
    let gated: [ToolInput]
    let narratedText: String
    let tools: [any Tool]
    let sessionID: UUID
    let priorActions: [ToolAction]
    let billedTokens: Int?
    let priorBilledTokens: Int?
    let systemPrompt: String?
    let recall: Message?
    /// Starter footing threaded from the turn's request so parking preserves
    /// the turn's pack verbatim across resume instead of recomposing.
    let starterPack: Message?
    let onEvent: (@Sendable (OrchestratorEvent) async -> Void)?
    /// Chronological round for the gated batch: one past the structured batch in
    /// mixed turns, otherwise one past all prior tool rounds so reloads interleave
    /// identically to live.
    let gatedRoundIndex: Int
    var contextTokens: Int?
    /// Whether this turn's assistant narration note was already persisted before
    /// filing. Mixed turns execute their structured calls first, which writes the
    /// note once; filing must stay a no-op then or the narration and its
    /// placeholders land in history twice.
    let narrationAlreadyPersisted: Bool
}

/// Inputs for one bounded tool-loop run.
struct TurnLoopRequest {
    let workingMessages: [Message]
    let tools: [any Tool]
    let recall: Message?
    /// Starter footing built once at turn start and reused verbatim every
    /// tool round so a mid-turn profile or index change never shifts the
    /// prefix mid-loop.
    let starterPack: Message?
    let sessionID: UUID
    let systemPrompt: String?
    let onEvent: (@Sendable (OrchestratorEvent) async -> Void)?
    var initialToolActions: [ToolAction] = []
    var priorBilledTokens: Int?
    var initialToolRounds: Int = 0
    var initialLlmRoundIndex: Int = 0
    /// Whether this turn previews without mutating. Dry runs never park so gated
    /// calls keep their ToolBus preview path instead of filing approvals.
    var isDryRun: Bool = false

    /// Creates a turn-loop request threading the turn's recall and starter pack.
    init(
        workingMessages: [Message],
        tools: [any Tool],
        recall: Message?,
        starterPack: Message? = nil,
        sessionID: UUID,
        systemPrompt: String?,
        onEvent: (@Sendable (OrchestratorEvent) async -> Void)?,
        initialToolActions: [ToolAction] = [],
        priorBilledTokens: Int? = nil,
        initialToolRounds: Int = 0,
        initialLlmRoundIndex: Int = 0,
        isDryRun: Bool = false
    ) {
        self.workingMessages = workingMessages
        self.tools = tools
        self.recall = recall
        self.starterPack = starterPack
        self.sessionID = sessionID
        self.systemPrompt = systemPrompt
        self.onEvent = onEvent
        self.initialToolActions = initialToolActions
        self.priorBilledTokens = priorBilledTokens
        self.initialToolRounds = initialToolRounds
        self.initialLlmRoundIndex = initialLlmRoundIndex
        self.isDryRun = isDryRun
    }
}

/// Outcome of one bounded tool-loop run.
enum TurnLoopOutcome {
    case finished(finalText: String, toolActions: [ToolAction], billedTokens: Int?, contextTokens: Int? = nil)
    case parked(OrchestratorResponse)
}

/// Inputs for building an ephemeral parked progress response when siblings are pending.
struct PendingParkedContext {
    let parked: ParkedNarratedApproval
    let remaining: [ToolAction]
    let newAction: ToolAction?
    let baseText: String
    let approved: Bool
    let warnings: [String]
    let onEvent: (@Sendable (OrchestratorEvent) async -> Void)?
}

/// Inputs for parking a turn on narrated gated calls.
struct ParkTurnContext {
    let gated: [ToolInput]
    let narratedText: String
    let toolActions: [ToolAction]
    let billedTokens: Int?
    let toolRounds: Int
    var contextTokens: Int?
    /// Whether the assistant narration note was already persisted earlier in this
    /// turn, telling the filing path to skip its own persist.
    var narrationAlreadyPersisted: Bool = false
}

/// Intermediate result of an LLM round.
/// Reasoning deltas stream to clients live but stay out of the final text by
/// design: they are never promoted into `text` or persisted per turn, so no
/// unused reasoning state is carried here.
struct TurnDraft: Sendable {
    let text: String
    let billedTokens: Int?
    let toolCalls: [ToolInput]

    init(text: String, billedTokens: Int? = nil, toolCalls: [ToolInput] = []) {
        self.text = text
        self.billedTokens = billedTokens
        self.toolCalls = toolCalls
    }
}

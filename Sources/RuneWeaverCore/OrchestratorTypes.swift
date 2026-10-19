// Rune Weaver Core — Orchestrator public contract types.

import Foundation

/// Convenience alias for the conversation role.
public typealias Role = Message.Role

/// Policy for handling turns that reach the tool loop iteration ceiling.
public enum ToolLimitPolicy: String, Sendable, Codable, Equatable {
    /// Parks turn in approval queue requesting continuation (standard for interactive chat).
    case park
    /// Injects diagnostic synthesis notice, suppresses further tools, and completes turn as budget exceeded (background).
    case forceSynthesis
}

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
    public let allowedTools: [String]?
    /// Optional display title this turn stamps on its session, when the caller
    /// names the work (e.g. a fan-out subtask title). Nil leaves an existing
    /// stored title alone.
    public let title: String?
    /// Session that spawned this turn's session, when the caller nests it
    /// (e.g. a fan-out worker under the session that invoked the swarm).
    /// Nil never clears a stored parent link.
    public let parentSessionID: UUID?
    /// Policy on reaching tool iteration limit (defaults to nil, resolved by orchestrator from source).
    public let toolLimitPolicy: ToolLimitPolicy?
    /// Turn-level tool iteration limit override (defaults to nil, resolved by orchestrator).
    public let maxToolIterations: Int?

    /// Coding keys matching the persisted and wire shape, with the goal tag on
    /// the shared `goalId` spelling.
    private enum CodingKeys: String, CodingKey {
        case text
        case sessionID
        case source
        case systemPrompt
        case goalID = "goalId"
        case allowedTools
        case title
        case parentSessionID
        case toolLimitPolicy = "tool_limit_policy"
        case maxToolIterations = "max_tool_iterations"
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
        parentSessionID: UUID? = nil,
        toolLimitPolicy: ToolLimitPolicy? = nil,
        maxToolIterations: Int? = nil
    ) {
        self.text = text
        self.sessionID = sessionID
        self.source = source
        self.systemPrompt = systemPrompt
        self.goalID = goalID
        self.allowedTools = allowedTools
        self.title = title
        self.parentSessionID = parentSessionID
        self.toolLimitPolicy = toolLimitPolicy
        self.maxToolIterations = maxToolIterations
    }

    /// Decodes user input, defaulting a missing goal tag to untagged, a missing tool subset to the
    /// full registry, and missing origin fields to nil so inputs encoded before goal linkage,
    /// fan-out, or worker nesting decode.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.text = try container.decode(String.self, forKey: .text)
        self.sessionID = try container.decode(UUID.self, forKey: .sessionID)
        self.source = try container.decode(String.self, forKey: .source)
        self.systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt)
        self.goalID = try container.decodeIfPresent(UUID.self, forKey: .goalID)
        self.allowedTools = try container.decodeIfPresent([String].self, forKey: .allowedTools)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.parentSessionID = try container.decodeIfPresent(UUID.self, forKey: .parentSessionID)
        self.toolLimitPolicy = try container.decodeIfPresent(ToolLimitPolicy.self, forKey: .toolLimitPolicy)
        self.maxToolIterations = try container.decodeIfPresent(Int.self, forKey: .maxToolIterations)
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
        try container.encodeIfPresent(toolLimitPolicy, forKey: .toolLimitPolicy)
        try container.encodeIfPresent(maxToolIterations, forKey: .maxToolIterations)
    }

    /// Filters a tool snapshot down to the input's allowed subset.
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
    /// Action outcome could not be verified (e.g. timeout on a mutating call).
    case uncertainOutcome = "uncertain_outcome"
    /// Identical repeat call blocked until prior uncertain outcome is verified.
    case idempotencyBlocked = "idempotency_blocked"
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
    /// Zero-based LLM round that produced this call, oldest first. Nil when
    /// unnumbered; clients treat absent as unordered and fall back to stored order.
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

/// Content-free recall observability carried on every turn completion.
public struct RecallSummary: Sendable, Codable, Equatable {
    /// Per-hit source raw values in rank order, never content.
    public let sources: [String]
    /// True when the document index was skipped for this pass.
    public let skippedDocIndex: Bool
    /// Total injected hits, always equal to `sources.count` on encode.
    public let hitCount: Int
    /// Per-tier tallies derived from `sources`.
    public let countsBySource: [String: Int]

    /// Creates a summary, deriving absent counts from the source list.
    public init(
        sources: [String] = [],
        skippedDocIndex: Bool = false,
        hitCount: Int? = nil,
        countsBySource: [String: Int]? = nil
    ) {
        self.sources = sources
        self.skippedDocIndex = skippedDocIndex
        self.hitCount = hitCount ?? sources.count
        self.countsBySource = countsBySource ?? Self.talliedCounts(for: sources)
    }

    /// Projects diagnostics to the wire-safe subset, dropping identifiers and scores.
    public init(from diagnostics: RecallDiagnostics) {
        self.init(
            sources: diagnostics.sources,
            skippedDocIndex: diagnostics.skippedDocIndex
        )
    }

    /// Tallies one count per source value.
    static func talliedCounts(for sources: [String]) -> [String: Int] {
        var tallied: [String: Int] = [:]
        for source in sources {
            tallied[source, default: 0] += 1
        }
        return tallied
    }

    /// Coding keys matching the JSON wire shape.
    private enum CodingKeys: String, CodingKey {
        case sources
        case skippedDocIndex
        case hitCount
        case countsBySource
    }

    /// Decodes tolerantly so payloads missing derived tallies still land.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let sources = try container.decodeIfPresent([String].self, forKey: .sources) ?? []
        self.sources = sources
        self.skippedDocIndex = try container.decodeIfPresent(Bool.self, forKey: .skippedDocIndex) ?? false
        self.hitCount = try container.decodeIfPresent(Int.self, forKey: .hitCount) ?? sources.count
        self.countsBySource = try container.decodeIfPresent([String: Int].self, forKey: .countsBySource) ?? Self.talliedCounts(for: sources)
    }

    /// Encodes every field so older decoders ignoring the parent key stay silent.
    /// - Parameter encoder: Destination encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sources, forKey: .sources)
        try container.encode(skippedDocIndex, forKey: .skippedDocIndex)
        try container.encode(hitCount, forKey: .hitCount)
        try container.encode(countsBySource, forKey: .countsBySource)
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
    /// Whether this turn ran out of tool iteration budget before completing all actions.
    public let isBudgetExceeded: Bool
    /// Content-free recall counts plus source names plus skip flag for the chip.
    /// Nil on payloads from engines predating the chip, which render no chip.
    public let recallDiagnostics: RecallSummary?

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
        /// Whether tool budget was exceeded.
        case isBudgetExceeded = "is_budget_exceeded"
        /// Content-free recall summary for the chip.
        case recallDiagnostics
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
        completedAt: Double? = nil,
        isBudgetExceeded: Bool = false,
        recallDiagnostics: RecallSummary? = nil
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
        self.isBudgetExceeded = isBudgetExceeded
        self.recallDiagnostics = recallDiagnostics
    }

    /// Decodes a response, defaulting missing parked flags to not parked and missing warnings to
    /// empty while rejecting negative token counters so a drifted payload fails here exactly where
    /// the live progress frame drops it, instead of reconciling to a negative total.
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
        self.isBudgetExceeded = try container.decodeIfPresent(Bool.self, forKey: .isBudgetExceeded) ?? false
        self.recallDiagnostics = try container.decodeIfPresent(RecallSummary.self, forKey: .recallDiagnostics)
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
        if isBudgetExceeded {
            try container.encode(isBudgetExceeded, forKey: .isBudgetExceeded)
        }
        // Omit an absent summary so older dashboards see no new key and render no chip.
        try container.encodeIfPresent(recallDiagnostics, forKey: .recallDiagnostics)
    }
}

/// Resolved automatic recall plus starter footing for one turn.
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
    /// Per-round token usage for the in-flight turn.
    case turnTokens(roundIndex: Int, roundTokens: Int, turnTotalTokens: Int, contextTokens: Int? = nil)
    /// Generic indeterminate progress from a tool that is still running.
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
    /// Content-free recall summary preserved across resume so parked turns keep their chip.
    public let recallDiagnostics: RecallSummary?

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
        contextTokens: Int? = nil,
        recallDiagnostics: RecallSummary? = nil
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
        self.recallDiagnostics = recallDiagnostics
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
    /// Content-free recall summary threaded from the turn request so parked cards keep their chip.
    let recallDiagnostics: RecallSummary?
    /// Chronological round for the gated batch: one past the structured batch in
    /// mixed turns, otherwise one past all prior tool rounds so reloads interleave
    /// identically to live.
    let gatedRoundIndex: Int
    var contextTokens: Int?
    /// Whether this turn's assistant narration note was already persisted before filing.
    let narrationAlreadyPersisted: Bool
    /// Live bash policy stamped onto filed bash approvals so the tier line
    /// renders on every card.
    let bashConfig: BashConfig?
    /// Workspace root execution resolves against for tier stamping.
    let workspaceRoot: URL?

    init(
        gated: [ToolInput],
        narratedText: String,
        tools: [any Tool],
        sessionID: UUID,
        priorActions: [ToolAction],
        billedTokens: Int?,
        priorBilledTokens: Int?,
        systemPrompt: String?,
        recall: Message?,
        starterPack: Message?,
        onEvent: (@Sendable (OrchestratorEvent) async -> Void)?,
        gatedRoundIndex: Int,
        contextTokens: Int?,
        narrationAlreadyPersisted: Bool,
        bashConfig: BashConfig? = nil,
        workspaceRoot: URL? = nil,
        recallDiagnostics: RecallSummary? = nil
    ) {
        self.gated = gated
        self.narratedText = narratedText
        self.tools = tools
        self.sessionID = sessionID
        self.priorActions = priorActions
        self.billedTokens = billedTokens
        self.priorBilledTokens = priorBilledTokens
        self.systemPrompt = systemPrompt
        self.recall = recall
        self.starterPack = starterPack
        self.onEvent = onEvent
        self.recallDiagnostics = recallDiagnostics
        self.gatedRoundIndex = gatedRoundIndex
        self.contextTokens = contextTokens
        self.narrationAlreadyPersisted = narrationAlreadyPersisted
        self.bashConfig = bashConfig
        self.workspaceRoot = workspaceRoot
    }
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
    /// Policy on reaching tool iteration limit.
    var toolLimitPolicy: ToolLimitPolicy = .park
    /// Overridden tool iteration limit for this turn, or nil to use orchestrator default.
    var effectiveMaxToolIterations: Int?
    /// Live bash policy snapshot stamped onto filed bash approvals.
    let bashConfig: BashConfig?
    /// Workspace root execution resolves against for tier stamping.
    let workspaceRoot: URL?
    /// Strict container registry execution used, so reap targets the same
    /// registry instead of the shared live one.
    let strictRegistry: StrictTurnRegistry?
    /// Content-free recall summary carried to terminal payloads without extra I/O.
    let recallDiagnostics: RecallSummary?

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
        isDryRun: Bool = false,
        toolLimitPolicy: ToolLimitPolicy = .park,
        effectiveMaxToolIterations: Int? = nil,
        bashConfig: BashConfig? = nil,
        workspaceRoot: URL? = nil,
        strictRegistry: StrictTurnRegistry? = nil,
        recallDiagnostics: RecallSummary? = nil
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
        self.toolLimitPolicy = toolLimitPolicy
        self.effectiveMaxToolIterations = effectiveMaxToolIterations
        self.bashConfig = bashConfig
        self.workspaceRoot = workspaceRoot
        self.strictRegistry = strictRegistry
        self.recallDiagnostics = recallDiagnostics
    }
}

/// Outcome of one bounded tool-loop run.
enum TurnLoopOutcome {
    case finished(
        finalText: String,
        toolActions: [ToolAction],
        billedTokens: Int?,
        contextTokens: Int? = nil,
        isBudgetExceeded: Bool = false,
        reasoning: String? = nil
    )
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
    /// Live bash policy snapshot carried into the park filing path.
    var bashConfig: BashConfig?
    /// Workspace root execution resolves against for tier stamping.
    var workspaceRoot: URL?
}

/// Intermediate result of an LLM round.
/// Stores generated text and optional reasoning / thought deltas.
struct TurnDraft: Sendable {
    let text: String
    let reasoning: String?
    let billedTokens: Int?
    let toolCalls: [ToolInput]

    init(text: String, reasoning: String? = nil, billedTokens: Int? = nil, toolCalls: [ToolInput] = []) {
        self.text = text
        self.reasoning = reasoning
        self.billedTokens = billedTokens
        self.toolCalls = toolCalls
    }
}

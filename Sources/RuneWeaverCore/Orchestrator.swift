// Rune Weaver Core — Turn orchestration and tool execution loop.
//
// Receives user input, routes it through the LLM, executes requested tools
// via the tool bus, and returns final responses with session memory
// mirroring. Hosts the narration fallback for local models and the
// file-and-park lifecycle for approval-gated narrations with same-session
// resume.

import Foundation

/// Convenience alias for the conversation role.
///
/// The canonical cases live on ``Message/Role``
/// (`system`/`user`/`assistant`/`tool`); this alias exists so call
/// sites written against the orchestration spec can say `Role`.
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
    /// - Parameters:
    ///   - text: Raw user text.
    ///   - sessionID: Owning session. Defaults to a new UUID.
    ///   - source: Input origin. Defaults to `"text"`.
    ///   - systemPrompt: Optional turn-specific system prompt override. Defaults to nil.
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
    /// Whether the call succeeded.
    public var didSucceed: Bool {
        result?.isError == false
    }

    /// Creates a tool action.
    /// - Parameters:
    ///   - toolName: Name of the tool.
    ///   - callID: Correlation identifier.
    ///   - argumentsJSON: Raw JSON arguments.
    ///   - result: Tool result, if available.
    public init(toolName: String, callID: String, argumentsJSON: String, result: ToolResult? = nil) {
        self.toolName = toolName
        self.callID = callID
        self.argumentsJSON = argumentsJSON
        self.result = result
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
    /// Session-billed tokens accumulated across every LLM round in this
    /// turn (each round's `totalTokens`, summed). Nil when no round
    /// reported usage, mirroring the CLI `runChunkedTurn`/`runTextTurn`
    /// session total for the API path.
    public let totalTokens: Int?
    /// Serving model name.
    public let modelName: String?
    /// Context window limit in tokens.
    public let contextLength: Int?
    /// Cumulative billed tokens for this session, if tracked.
    public let sessionTokens: Int?
    /// Whether this turn parked waiting on approval.
    ///
    /// True only for the turn that filed gated narrations; stale parked
    /// approvals from prior turns in the same session never flip a fresh
    /// normal turn to parked.
    public let isParked: Bool

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
    }

    /// Creates a response.
    /// - Parameters:
    ///   - text: Final assistant text.
    ///   - sessionID: Owning session.
    ///   - toolActions: Tool invocations performed.
    ///   - totalTokens: Billed tokens accumulated across LLM rounds, if any.
    ///   - modelName: Serving model name. Defaults to nil.
    ///   - contextLength: Context window limit. Defaults to nil.
    ///   - sessionTokens: Cumulative tokens for session. Defaults to nil.
    ///   - isParked: Whether this turn parked waiting on approval. Defaults to false.
    public init(
        text: String,
        sessionID: UUID,
        toolActions: [ToolAction] = [],
        totalTokens: Int? = nil,
        modelName: String? = nil,
        contextLength: Int? = nil,
        sessionTokens: Int? = nil,
        isParked: Bool = false
    ) {
        self.text = text
        self.sessionID = sessionID
        self.toolActions = toolActions
        self.totalTokens = totalTokens
        self.modelName = modelName
        self.contextLength = contextLength
        self.sessionTokens = sessionTokens
        self.isParked = isParked
    }

    /// Decodes a response, defaulting missing parked flags to not parked.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.text = try container.decode(String.self, forKey: .text)
        self.sessionID = try container.decode(UUID.self, forKey: .sessionID)
        self.toolActions = try container.decodeIfPresent([ToolAction].self, forKey: .toolActions) ?? []
        self.totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens)
        self.modelName = try container.decodeIfPresent(String.self, forKey: .modelName)
        self.contextLength = try container.decodeIfPresent(Int.self, forKey: .contextLength)
        self.sessionTokens = try container.decodeIfPresent(Int.self, forKey: .sessionTokens)
        self.isParked = try container.decodeIfPresent(Bool.self, forKey: .isParked) ?? false
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
    case toolStarted(toolName: String, callID: String, argumentsJSON: String)
    /// Tool execution has completed.
    case toolCompleted(toolName: String, callID: String, result: ToolResult)
    /// Incremental assistant text delta generated by the model.
    case textDelta(String)
    /// Filed narrated approval awaiting an inbox decision.
    ///
    /// Emitted once per gated narration filed while parking so service
    /// layers can broadcast the live approval prompt without polling.
    case approval(PermissionRequest)
}

/// Resolves model-requested tool calls for the current context.
///
/// The core `LLMProvider.chat` stream carries text only; providers
/// that natively stream tool calls (see `ChunkStreamingProvider` in
/// RuneWeaverLLM) adapt by injecting a resolver that returns the
/// calls for the latest assistant turn. A nil resolver means
/// text-only responses with no tool loop.
/// - Parameters:
///   - messages: Current working history including the latest turn.
///   - tools: Tools the model may call.
/// - Returns: Tool calls to execute, or empty when the turn is final.
public typealias OrchestratorToolResolver = @Sendable ([Message], [any Tool]) async throws -> [ToolInput]

/// Single shared tool-loop policy for the orchestrator and the CLI chat loop.
///
/// Centralizes the decisions both entry points must make identically so the
/// CLI delegates here instead of reimplementing the orchestration loop:
/// assistant-note content for tool-only turns, whether assistant text is
/// worth storing, compact episodic tool records stripped of call mechanics,
/// when the tool-round budget is exceeded, and how input sources are
/// normalized.
public enum OrchestratorToolLoop {
    /// Returns the assistant content to persist for a tool round.
    ///
    /// Blank model text falls back to the shared placeholder so tool results
    /// keep their parent turn. When the model sends both text and tool calls
    /// in one turn, both are kept (text plus placeholder lines) so the next
    /// Responses body can still replay every `function_call` with its
    /// matching `function_call_output` instead of orphaning tool results.
    /// - Parameters:
    ///   - text: Latest assistant text.
    ///   - calls: Tool calls needing a parent assistant note.
    /// - Returns: Placeholder when text is blank, text when there are no
    ///   calls, otherwise text plus the placeholder record.
    public static func assistantNoteContent(text: String, calls: [ToolInput]) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return ToolInput.placeholderContent(for: calls)
        }
        if calls.isEmpty {
            return text
        }
        return text + "\n" + ToolInput.placeholderContent(for: calls)
    }

    /// Whether final assistant text is worth storing and returning.
    /// - Parameter text: Final assistant text.
    /// - Returns: True when the text is non-blank.
    public static func shouldStoreAssistantText(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether the tool-round budget is exceeded.
    /// - Parameters:
    ///   - rounds: Tool rounds run so far (one-based after increment).
    ///   - max: Maximum allowed tool rounds.
    /// - Returns: True when `rounds` exceeds `max`.
    public static func isLimitExceeded(rounds: Int, max: Int) -> Bool {
        rounds > max
    }

    /// Builds the compact episodic record for one tool execution.
    ///
    /// Single shared episodic policy so the orchestrator and the CLI chat
    /// loop persist identical clean content: working memory keeps the full
    /// assistant placeholder plus correlated tool messages for LLM replay,
    /// while episodic memory keeps only user text verbatim, final assistant
    /// text verbatim, and one compact `"Used <tool>: <outcome>"` record per
    /// meaningful tool execution with no placeholder lines, call
    /// identifiers, or call-argument JSON. Blank outcomes yield nil so
    /// empty results skip the episodic mirror while staying in working
    /// history for LLM feedback.
    /// - Parameters:
    ///   - toolName: Name of the tool that ran.
    ///   - result: Result returned by the bus.
    /// - Returns: Compact episodic record, or nil when not meaningful.
    public static func episodicToolRecord(toolName: String, result: ToolResult) -> String? {
        MemoryEngine.episodicToolRecord(toolName: toolName, result: result)
    }

    /// Normalizes an input source label, defaulting blanks to `"chat"`.
    ///
    /// Trims surrounding whitespace so `"  "` and `""` both resolve to the
    /// default instead of persisting blank origins on profile facts.
    /// - Parameter source: Raw input origin (e.g. `"text"`, `"voice"`).
    /// - Returns: Trimmed source, or `"chat"` when blank.
    public static func resolvedSource(_ source: String) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "chat" : trimmed
    }

    /// Converts narrated placeholder lines into read-only tool calls.
    ///
    /// When a turn yields assistant text but zero structured tool calls,
    /// each `Calling <name> <arguments> [<callID>]` line is parsed with
    /// the shared `ToolInput/parsePlaceholderLine(_:)` parser and kept
    /// only when the named tool is registered, its permission level is
    /// `readOnly`, and its arguments are a valid JSON object. Matches
    /// receive fresh call identifiers so narrated identifiers never
    /// correlate with executed results. Unknown tools, invalid argument
    /// JSON, and approval-gated tools yield no calls and stay unexecuted.
    /// - Parameters:
    ///   - text: Latest assistant text possibly containing placeholders.
    ///   - tools: Available tools the model may call.
    /// - Returns: Executable read-only calls in line order, or empty when
    ///   no narrated line qualifies.
    public static func narratedToolCalls(from text: String, tools: [any Tool]) -> [ToolInput] {
        narratedCalls(from: text, tools: tools, where: { $0.permissionLevel == .readOnly })
    }

    /// Converts narrated placeholder lines into approval-gated tool calls.
    ///
    /// Companion to `narratedToolCalls(from:tools:)` for the parked-approval
    /// path: each `Calling <name> <arguments> [<callID>]` line is parsed with
    /// the same shared parser and kept only when the named tool is
    /// registered, its permission level is `requiresApproval`, and its
    /// arguments are a valid JSON object. Matches receive fresh call
    /// identifiers so narrated identifiers never correlate with filed
    /// requests. Read-only, trusted, unknown, and malformed lines yield no
    /// calls here; read-only lines stay on the direct-execution path.
    /// - Parameters:
    ///   - text: Latest assistant text possibly containing placeholders.
    ///   - tools: Available tools the model may call.
    /// - Returns: Parkable gated calls in line order, or empty when no
    ///   narrated line qualifies.
    public static func narratedGatedCalls(from text: String, tools: [any Tool]) -> [ToolInput] {
        narratedCalls(from: text, tools: tools, where: { $0.permissionLevel == .requiresApproval })
    }

    /// Converts narrated placeholder lines into tool calls matching a permission filter.
    ///
    /// Single shared parsing path for the read-only and gated narration
    /// fallbacks so trim, line splitting, tool lookup, and JSON validation
    /// cannot drift; callers differ only by which permission level they keep.
    /// - Parameters:
    ///   - text: Latest assistant text possibly containing placeholders.
    ///   - tools: Available tools the model may call.
    ///   - predicate: Keeps a resolved tool when true (one permission level per caller).
    /// - Returns: Matching calls in line order, or empty when none qualifies.
    private static func narratedCalls(
        from text: String,
        tools: [any Tool],
        where predicate: (any Tool) -> Bool
    ) -> [ToolInput] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let byName = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var calls: [ToolInput] = []
        for rawLine in normalized.components(separatedBy: "\n") {
            guard let parsed = ToolInput.parsePlaceholderLine(rawLine) else { continue }
            guard let tool = byName[parsed.toolName] else { continue }
            guard predicate(tool) else { continue }
            guard isNarrationArgumentsJSON(parsed.argumentsJSON) else { continue }
            calls.append(ToolInput(
                toolName: parsed.toolName,
                argumentsJSON: parsed.argumentsJSON,
                callID: UUID().uuidString
            ))
        }
        return calls
    }

    /// Builds the parked-turn message ending a narration that needs approval.
    ///
    /// Names every gated tool so the waiting turn stays auditable without
    /// leaking argument JSON, and points at the approvals inbox where the
    /// decision resumes the same session.
    /// - Parameter calls: Gated calls filed for this turn.
    /// - Returns: User-visible waiting message.
    public static func waitingOnApprovalMessage(for calls: [ToolInput]) -> String {
        let names = Array(Set(calls.map(\.toolName))).sorted()
        let joined = names.isEmpty ? "the requested tool" : names.joined(separator: ", ")
        return "Waiting for approval to run \(joined). Approve in the approvals inbox to continue."
    }

    /// Builds the session notice recording a denied narrated approval.
    ///
    /// Keeps the denial in working memory so the next synthesis never
    /// assumes the gated call ran, without echoing argument JSON.
    /// - Parameter toolName: Name of the denied tool.
    /// - Returns: User-visible denial notice.
    public static func deniedApprovalMessage(for toolName: String) -> String {
        let trimmed = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "the requested tool" : trimmed
        return "Approval denied for \(name); not running it."
    }

    /// Whether raw narration arguments are a JSON object.
    ///
    /// Guards the narration fallback so hallucinated argument text never
    /// executes: only strings decoding to a JSON object qualify, while
    /// truncated placeholders, bare words, arrays, and malformed JSON
    /// are rejected.
    /// - Parameter argumentsJSON: Raw arguments text from a placeholder line.
    /// - Returns: True when the text decodes to a JSON object.
    private static func isNarrationArgumentsJSON(_ argumentsJSON: String) -> Bool {
        let trimmed = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let data = trimmed.data(using: .utf8) else { return false }
        do {
            let value = try JSONSerialization.jsonObject(with: data, options: [])
            return value is [String: Any]
        } catch {
            return false
        }
    }
}

/// Parked narrated approval awaiting a later decision.
///
/// Captures the owning session plus the gated invocation so an allow can
/// execute the exact filed call and a deny can notify the same session,
/// even after the approvals inbox entry is resolved.
public struct ParkedNarratedApproval: Sendable, Equatable {
    /// Owning session the narration parked in.
    public let sessionID: UUID
    /// Gated invocation filed for approval.
    public let toolCall: ToolInput
    /// Effective system prompt active when the turn parked.
    ///
    /// Preserves the turn's prompt so the resume synthesis continues with
    /// the same instructions: scheduler turns keep their background
    /// prompting and custom overrides survive the inbox round-trip instead
    /// of falling back to the default prompt.
    public let systemPrompt: String?
    /// Per-turn batch identifier shared by siblings parked together.
    ///
    /// Minted once per parking turn so two gated turns parked in the same
    /// session before either decides stay isolated instead of merging into
    /// one batch that synthesizes once with mixed outcomes.
    public let batchID: UUID

    /// Creates a parked approval.
    /// - Parameters:
    ///   - sessionID: Owning session.
    ///   - toolCall: Gated invocation.
    ///   - systemPrompt: Effective prompt active when the turn parked.
    ///     Defaults to nil (legacy untagged, falls back to the default).
    ///   - batchID: Per-turn batch identifier. Defaults to a new UUID.
    public init(sessionID: UUID, toolCall: ToolInput, systemPrompt: String? = nil, batchID: UUID = UUID()) {
        self.sessionID = sessionID
        self.toolCall = toolCall
        self.systemPrompt = systemPrompt
        self.batchID = batchID
    }
}

/// Context grouping the inputs for one parked-approval filing path.
///
/// Groups the gated-narration inputs so the filing helper stays within the
/// parameter budget without changing filing behavior.
private struct ParkGatedCallsContext {
    let gated: [ToolInput]
    let narratedText: String
    let tools: [any Tool]
    let sessionID: UUID
    let priorActions: [ToolAction]
    let billedTokens: Int?
    let systemPrompt: String?
    let onEvent: (@Sendable (OrchestratorEvent) async -> Void)?
}

/// Inputs for one bounded tool-loop run.
///
/// Bundles working history plus turn context so the extracted loop helper
/// stays within the parameter budget while sharing the same loop policy.
private struct TurnLoopRequest {
    let workingMessages: [Message]
    let tools: [any Tool]
    let recall: Message?
    let sessionID: UUID
    let systemPrompt: String?
    let onEvent: (@Sendable (OrchestratorEvent) async -> Void)?
}

/// Outcome of one bounded tool-loop run.
///
/// Finished carries final text plus actions and billed tokens for the caller
/// to store; parked carries the waiting response already flushed.
private enum TurnLoopOutcome {
    case finished(finalText: String, toolActions: [ToolAction], billedTokens: Int?)
    case parked(OrchestratorResponse)
}

/// Intermediate result of an LLM round.
///
/// Carries concatenated text plus billed tokens and streamed tool calls so
/// the loop helper shares one collection shape with the synthesis path.
private struct TurnDraft: Sendable {
    let text: String
    let billedTokens: Int?
    let toolCalls: [ToolInput]
}

/// Core orchestration loop: input, context, LLM, tools, response.
///
/// The orchestrator receives user input, loads session context,
/// calls the LLM, executes any requested tools via the ``ToolBus``
/// (feeding each ``ToolResult`` back for the next LLM turn), and
/// returns the final text while storing every turn in the
/// ``ConversationManager`` and mirroring clean turns into episodic memory
/// via an optional ``MemoryEngine`` failure-isolated: user text and final
/// assistant text verbatim, interim assistant notes skipped, and each
/// meaningful tool execution as one compact `"Used <tool>: <outcome>"`
/// record with no placeholder lines, call identifiers, or call-argument
/// JSON. The CLI chat loop delegates its per-round decisions to
/// ``OrchestratorToolLoop`` so both entry points share one loop policy.
///
/// Narrated approval-gated calls never execute inline. When narration
/// names a `requiresApproval` tool, the turn files one
/// ``ApprovalQueue`` request per call tagged with the session, ends parked
/// with a waiting message, and resumes on decision: an allow executes the
/// filed call and runs a synthesis turn in the same session, while a deny
/// records the denial in that session.
public actor Orchestrator {
    /// Session and history owner.
    private let conversations: ConversationManager
    /// Tool registry and permission gate.
    private let toolBus: ToolBus
    /// LLM backend serving completions.
    private let llm: any LLMProvider
    /// Developer instructions prepended to every turn.
    private let systemPrompt: String?
    /// Maximum tool-call rounds per response, plus one final synthesis turn.
    private let maxToolIterations: Int
    /// Optional resolver mapping an assistant turn to tool calls.
    private let toolResolver: OrchestratorToolResolver?
    /// Episodic mirror for every turn, when configured.
    private let memoryEngine: MemoryEngine?
    /// Queue receiving narrated gated calls, when configured.
    ///
    /// Nil keeps the legacy drop behavior for callers without an approvals
    /// inbox (CLI, scheduler headless); a queue enables file-and-park plus
    /// later resume in the same session.
    private let approvalQueue: ApprovalQueue?
    /// Parked gated narrations indexed by approval request identifier.
    private var parkedNarratedApprovals: [UUID: ParkedNarratedApproval] = [:]
    /// Executed gated actions buffered per parked batch while siblings stay pending.
    ///
    /// One LLM round can park several gated narrations under one batch
    /// identifier; each inbox decision executes its call immediately but
    /// synthesis waits until the last sibling in that batch resolves so the
    /// turn synthesizes once with every outcome.
    private var parkedBatchExecutedActions: [UUID: [ToolAction]] = [:]
    /// Cumulative billed tokens tracked per session.
    private var sessionTokensBySession: [UUID: Int] = [:]
    /// Access order for token totals, oldest first.
    ///
    /// Dictionary iteration is unordered, so a separate queue records
    /// recency: the just-billed session moves to the back and eviction
    /// drops the front, keeping the victim deterministic under overflow.
    private var sessionTokenOrder: [UUID] = []
    /// Bounds token totals so deleted sessions never leak memory.
    ///
    /// Mirrors the conversation manager capacity so per-session usage
    /// cannot grow without bound across many short-lived sessions.
    private static let maxTrackedSessions = 500

    /// Creates an orchestrator.
    /// - Parameters:
    ///   - conversations: Session and history owner.
    ///   - toolBus: Tool registry and permission gate.
    ///   - llm: LLM backend serving completions.
    ///   - systemPrompt: Developer instructions prepended to every
    ///     turn. Defaults to nil.
    ///   - maxToolIterations: Maximum tool-call rounds per response.
    ///     After the last tool round one final synthesis turn runs so
    ///     tool results are always answered. Defaults to 8.
    ///   - toolResolver: Resolver mapping an assistant turn to tool
    ///     calls. Defaults to nil (text-only).
    ///   - memoryEngine: Episodic mirror receiving every turn
    ///     failure-isolated. Defaults to nil (no mirroring).
    ///   - approvalQueue: Queue receiving narrated gated calls for
    ///     file-and-park plus resume. Defaults to nil (drop gated narration).
    public init(
        conversations: ConversationManager,
        toolBus: ToolBus,
        llm: any LLMProvider,
        systemPrompt: String? = nil,
        maxToolIterations: Int = 8,
        toolResolver: OrchestratorToolResolver? = nil,
        memoryEngine: MemoryEngine? = nil,
        approvalQueue: ApprovalQueue? = nil
    ) {
        self.conversations = conversations
        self.toolBus = toolBus
        self.llm = llm
        self.systemPrompt = systemPrompt
        self.maxToolIterations = max(1, maxToolIterations)
        self.toolResolver = toolResolver
        self.memoryEngine = memoryEngine
        self.approvalQueue = approvalQueue
    }

    /// Processes one user input through the full loop.
    ///
    /// 1. Resolves (or creates) the session and stores the user turn in
    ///    working memory, mirroring it to episodic memory.
    /// 2. Handles explicit remember requests (`remember ...`,
    ///    `/remember ...`) by storing the profile fact via the memory
    ///    engine and returning an acknowledgement without calling the LLM,
    ///    so non-CLI callers share the CLI remember behavior.
    /// 3. Loads context, injects automatic recall, and calls the LLM.
    ///    Every turn runs one bounded keyword recall via
    ///    `MemoryEngine.recallMessage(for:sessionID:)` whose top matches
    ///    inject as source-labeled, token-bounded system context via
    ///    `MemoryEngine.automaticRecallContext`, spliced with
    ///    `MemoryEngine.historyWithRecall` after leading system messages
    ///    and never stored.
    /// 4. Executes requested tools via the bus, appends each result,
    ///    and re-invokes the LLM until the turn is final. Real-time events
    ///    (`.toolStarted`, `.toolCompleted`, `.textDelta`) are emitted to
    ///    `onEvent` as they occur.
    /// 5. Stores the final assistant turn and returns it. If cancelled
    ///    before any tool ran, restores the pre-turn raw session snapshot
    ///    (messages plus rolling summary) so working memory stays clean;
    ///    when tools already executed, working partials and their episodic
    ///    mirrors are kept so side effects stay auditable.
    /// - Parameter input: User text plus session routing.
    /// - Returns: Final text, session, and tool actions taken.
    public func process(input: UserInput) async throws -> OrchestratorResponse {
        try await process(input: input, onEvent: nil)
    }

    /// Processes one user input with real-time progress notifications.
    /// - Parameters:
    ///   - input: User text plus session routing.
    ///   - onEvent: Optional event handler for tool and text streaming.
    /// - Returns: Final text, session, and tool actions taken.
    public func process(
        input: UserInput,
        onEvent: (@Sendable (OrchestratorEvent) async -> Void)? = nil
    ) async throws -> OrchestratorResponse {
        try Task.checkCancellation()
        let text = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw OrchestratorError.emptyInput
        }
        let sessionID = input.sessionID
        _ = await conversations.ensureSession(id: sessionID)
        // Raw pre-turn copy (messages plus rolling summary, never the
        // synthetic summary-prefix view) so cancellation restores both
        // without duplicating the summary or keeping truncated growth.
        let preTurnSnapshot = await conversations.rollbackSnapshot(for: sessionID)
        // Episodic mirrors buffer until commit: user text, compact tool
        // records, and final text flush on success or on failures that
        // keep working partials. A cancel with no executed tools rolls
        // back cleanly with no flush; a cancel after tools keeps both
        // stores so side effects stay auditable.
        var pendingEpisodic: [(content: String, role: Message.Role)] = []

        do {
            await conversations.append(Message(role: .user, content: text), to: sessionID)
            pendingEpisodic.append((text, .user))

            if let earlyResponse = await rememberEarlyResponse(
                text: text,
                source: input.source,
                sessionID: sessionID,
                pendingEpisodic: &pendingEpisodic,
                onEvent: onEvent
            ) {
                try Task.checkCancellation()
                await flushEpisodic(pendingEpisodic, sessionID: sessionID)
                return earlyResponse
            }

            let effectiveSystemPrompt: String? = if let custom = input.systemPrompt {
                custom
            } else if input.source == "scheduler" {
                await SystemPromptComposer.composeScheduled(tools: toolBus.availableTools())
            } else {
                systemPrompt
            }
            let recall: Message? = if let memoryEngine {
                await memoryEngine.recallMessage(for: text, sessionID: sessionID)
            } else {
                nil
            }
            let workingMessages = await MemoryEngine.historyWithRecall(
                conversations.workingHistory(for: sessionID, systemPrompt: effectiveSystemPrompt),
                recall: recall
            )
            let tools = await toolBus.availableTools()
            let request = TurnLoopRequest(
                workingMessages: workingMessages,
                tools: tools,
                recall: recall,
                sessionID: sessionID,
                systemPrompt: effectiveSystemPrompt,
                onEvent: onEvent
            )
            let outcome = try await runTurnLoop(request, pendingEpisodic: &pendingEpisodic)
            switch outcome {
            case let .parked(parkedResponse):
                return parkedResponse
            case let .finished(finalText, toolActions, loopBilled):
                await storeFinalAssistantText(finalText, sessionID: sessionID, pendingEpisodic: &pendingEpisodic)
                try Task.checkCancellation()
                await flushEpisodic(pendingEpisodic, sessionID: sessionID)
                let cumulativeTokens = accumulateSessionTokens(loopBilled, for: sessionID)
                return OrchestratorResponse(
                    text: finalText,
                    sessionID: sessionID,
                    toolActions: toolActions,
                    totalTokens: loopBilled,
                    modelName: llm.modelInfo.name,
                    contextLength: llm.modelInfo.contextLength,
                    sessionTokens: cumulativeTokens
                )
            }
        } catch is CancellationError {
            // Executed tools already changed the world: keep working-memory
            // partials and mirror them so the audit trail survives the
            // cancel instead of being rolled back as if nothing ran.
            let hasExecutedTools = pendingEpisodic.contains { $0.role == .tool }
            if hasExecutedTools {
                await flushEpisodicUncancellable(pendingEpisodic, sessionID: sessionID)
            } else if let preTurnSnapshot {
                await conversations.restoreRollbackSnapshot(preTurnSnapshot)
            }
            throw CancellationError()
        } catch {
            // Non-cancellation failures keep working-memory partials, so
            // flush the buffered mirror to match instead of diverging.
            await flushEpisodic(pendingEpisodic, sessionID: sessionID)
            throw error
        }
    }

    /// Serving model info (model name and context length limit).
    public var modelInfo: ModelInfo {
        llm.modelInfo
    }

    /// Whether a session owns a parked narrated turn awaiting approval.
    ///
    /// Centralizes the parked check so chat, scheduler, and service entry
    /// points share one lookup instead of re-filtering inbox identifiers at
    /// each call site.
    /// - Parameter sessionID: Owning session to inspect.
    /// - Returns: True when the session owns at least one parked approval.
    public func isSessionParked(_ sessionID: UUID) -> Bool {
        for parked in parkedNarratedApprovals.values where parked.sessionID == sessionID {
            return true
        }
        return false
    }
}

// MARK: - Parked approvals and turn loop execution

/// Holds the resume path plus the extracted tool-loop helpers so the main
/// actor body stays within the length budget while sharing file-private state.
extension Orchestrator {
    /// Resumes a parked narrated approval after its inbox decision.
    ///
    /// An allow executes the filed call directly (honoring the explicit
    /// decision without re-entering the bus gate, so one-shot approvals run
    /// without a second prompt), appends the result, then runs one synthesis
    /// turn in the same session. A deny appends the denial notice to the
    /// same session without executing. Either path drains a parked early
    /// queue decision left by the inbox so it cannot leak into a later wait.
    /// Unknown identifiers yield nil so structured waits and headless
    /// denials without a parked turn stay untouched.
    /// - Parameters:
    ///   - id: Approval request identifier filed when the turn parked.
    ///   - approved: Whether the inbox allowed the call.
    ///   - onEvent: Optional handler receiving tool and text streaming events.
    /// - Returns: Resume response in the parked session, or nil when unknown.
    public func resumeNarratedApproval(
        id: UUID,
        approved: Bool,
        onEvent: (@Sendable (OrchestratorEvent) async -> Void)? = nil
    ) async throws -> OrchestratorResponse? {
        try Task.checkCancellation()
        guard let parked = parkedNarratedApprovals.removeValue(forKey: id) else {
            return nil
        }
        if let queue = approvalQueue {
            _ = await queue.takeEarlyDecision(id: id)
        }
        _ = await conversations.ensureSession(id: parked.sessionID)
        if approved {
            return try await resumeAllowedParked(parked, onEvent: onEvent)
        } else {
            return try await resumeDeniedParked(parked, onEvent: onEvent)
        }
    }

    /// Resumes a denied parked approval, deferring synthesis while siblings remain.
    ///
    /// Records the refusal then completes the batch through the shared
    /// finalizer so intermediate denies keep the turn awaiting and the last
    /// decision synthesizes once when prior allows executed.
    /// - Parameters:
    ///   - parked: Denied parked approval just removed from tracking.
    ///   - onEvent: Optional handler receiving text streaming events.
    /// - Returns: Progress while siblings remain, else final denial or synthesis.
    private func resumeDeniedParked(
        _ parked: ParkedNarratedApproval,
        onEvent: (@Sendable (OrchestratorEvent) async -> Void)? = nil
    ) async throws -> OrchestratorResponse {
        let denial = await recordParkedDenial(parked.toolCall, sessionID: parked.sessionID, onEvent: onEvent)
        return try await finishParkedBatch(
            parked: parked,
            baseText: denial,
            newAction: nil,
            approved: false,
            onEvent: onEvent
        )
    }

    /// Resumes an allowed parked approval, executing then synthesizing once all siblings land.
    ///
    /// Executes immediately so side effects land in order, then completes
    /// through the shared finalizer so intermediate allows keep the turn
    /// awaiting and the last sibling synthesizes once atomically.
    /// - Parameters:
    ///   - parked: Allowed parked approval just removed from tracking.
    ///   - onEvent: Optional handler receiving tool and text streaming events.
    /// - Returns: Progress while siblings remain, else final synthesis or missing notice.
    private func resumeAllowedParked(
        _ parked: ParkedNarratedApproval,
        onEvent: (@Sendable (OrchestratorEvent) async -> Void)? = nil
    ) async throws -> OrchestratorResponse {
        let sessionID = parked.sessionID
        let call = parked.toolCall
        guard let tool = await toolBus.tool(named: call.toolName) else {
            let missing = await recordParkedMissingTool(call.toolName, sessionID: sessionID, onEvent: onEvent)
            return try await finishParkedBatch(
                parked: parked,
                baseText: missing,
                newAction: nil,
                approved: true,
                onEvent: onEvent
            )
        }
        let action = await executeParkedCall(call, tool: tool, sessionID: sessionID, onEvent: onEvent)
        return try await finishParkedBatch(
            parked: parked,
            baseText: "",
            newAction: action,
            approved: true,
            onEvent: onEvent
        )
    }

    /// Completes one parked batch decision, deferring synthesis until the last sibling lands.
    ///
    /// Buffers the just-executed action when present, returns progress with
    /// remaining pendings while siblings stay parked, and otherwise takes the
    /// buffered batch for one synthesis turn (or the base notice when nothing
    /// executed) so the run flips once with every outcome.
    /// - Parameters:
    ///   - parked: Just-decided parked approval, already removed from tracking.
    ///   - baseText: Denial or missing notice, or empty when an action executed.
    ///   - newAction: Executed action to buffer, or nil when nothing ran.
    ///   - approved: Whether the just-decided call was allowed.
    ///   - onEvent: Optional handler receiving progress and synthesis events.
    /// - Returns: Progress while siblings remain, else final synthesis or base notice.
    private func finishParkedBatch(
        parked: ParkedNarratedApproval,
        baseText: String,
        newAction: ToolAction?,
        approved: Bool,
        onEvent: (@Sendable (OrchestratorEvent) async -> Void)?
    ) async throws -> OrchestratorResponse {
        let sessionID = parked.sessionID
        let batchID = parked.batchID
        if let newAction {
            appendBufferedParkedAction(newAction, forBatch: batchID)
        }
        let remaining = remainingPendingActions(inBatch: batchID)
        if !remaining.isEmpty {
            let buffered = bufferedParkedActions(forBatch: batchID)
            let noun = if remaining.count == 1 {
                "approval"
            } else {
                "approvals"
            }
            let progress: String = if newAction != nil {
                parkedBatchProgressMessage(
                    toolName: parked.toolCall.toolName,
                    remainingCount: remaining.count,
                    approved: approved
                )
            } else {
                "\(baseText) Waiting for \(remaining.count) more \(noun)."
            }
            await onEvent?(.textDelta(progress))
            return OrchestratorResponse(
                text: progress,
                sessionID: sessionID,
                toolActions: buffered + remaining,
                modelName: llm.modelInfo.name,
                contextLength: llm.modelInfo.contextLength,
                sessionTokens: sessionTokensBySession[sessionID],
                isParked: true
            )
        }
        let buffered = takeBufferedParkedActions(forBatch: batchID)
        if buffered.isEmpty {
            return OrchestratorResponse(
                text: baseText,
                sessionID: sessionID,
                toolActions: [],
                modelName: llm.modelInfo.name,
                contextLength: llm.modelInfo.contextLength,
                sessionTokens: sessionTokensBySession[sessionID],
                isParked: false
            )
        }
        let prompt = await resolveParkedSynthesisPrompt(parked)
        let synthesis = try await synthesizeParkedTurn(sessionID: sessionID, prompt: prompt, onEvent: onEvent)
        let cumulative = accumulateSessionTokens(synthesis.billedTokens, for: sessionID)
        return OrchestratorResponse(
            text: synthesis.text,
            sessionID: sessionID,
            toolActions: buffered,
            totalTokens: synthesis.billedTokens,
            modelName: llm.modelInfo.name,
            contextLength: llm.modelInfo.contextLength,
            sessionTokens: cumulative,
            isParked: false
        )
    }

    /// Resolves the synthesis prompt for a parked turn.
    ///
    /// Parked scheduler and custom-prompt turns must resume with the same
    /// instructions they parked with; falling back to the default prompt
    /// would contradict scheduled background continuity. Stored effective
    /// prompts win, while legacy untagged parks recompute the scheduled
    /// prompt when their session still carries the scheduler source.
    /// - Parameter parked: Parked approval carrying the turn's prompt, if stored.
    /// - Returns: Prompt for the resume synthesis history.
    private func resolveParkedSynthesisPrompt(_ parked: ParkedNarratedApproval) async -> String? {
        if let stored = parked.systemPrompt {
            return stored
        }
        let source = await conversations.session(id: parked.sessionID)?.source
        if source == "scheduler" {
            let tools = await toolBus.availableTools()
            return SystemPromptComposer.composeScheduled(tools: tools)
        }
        return systemPrompt
    }

    /// Pending actions for siblings still awaiting inbox decisions.
    ///
    /// Keeps the awaiting run auditable while siblings resolve: decided
    /// calls carry results while undecided siblings stay pending with no
    /// result for detail views and call-ID fallback. Scoped to one parking
    /// batch so separate turns in the same session never merge.
    /// - Parameter batchID: Per-turn batch identifier to inspect.
    /// - Returns: Pending actions for remaining siblings, sorted for stability.
    private func remainingPendingActions(inBatch batchID: UUID) -> [ToolAction] {
        parkedNarratedApprovals.values
            .filter { $0.batchID == batchID }
            .map {
                ToolAction(
                    toolName: $0.toolCall.toolName,
                    callID: $0.toolCall.callID,
                    argumentsJSON: $0.toolCall.argumentsJSON,
                    result: nil
                )
            }
            .sorted {
                if $0.toolName != $1.toolName {
                    return $0.toolName < $1.toolName
                }
                return $0.callID < $1.callID
            }
    }

    /// Buffered executed actions for one parked batch.
    /// - Parameter batchID: Per-turn batch identifier.
    /// - Returns: Executed gated actions decided so far, in decision order.
    private func bufferedParkedActions(forBatch batchID: UUID) -> [ToolAction] {
        parkedBatchExecutedActions[batchID] ?? []
    }

    /// Buffers one executed gated action for a parked batch.
    /// - Parameters:
    ///   - action: Executed action to keep for the final synthesis response.
    ///   - batchID: Per-turn batch identifier.
    private func appendBufferedParkedAction(_ action: ToolAction, forBatch batchID: UUID) {
        parkedBatchExecutedActions[batchID, default: []].append(action)
    }

    /// Takes and clears buffered executed actions for a parked batch.
    /// - Parameter batchID: Per-turn batch identifier.
    /// - Returns: Executed actions in decision order, possibly empty.
    private func takeBufferedParkedActions(forBatch batchID: UUID) -> [ToolAction] {
        let buffered = parkedBatchExecutedActions[batchID] ?? []
        parkedBatchExecutedActions.removeValue(forKey: batchID)
        return buffered
    }

    /// Progress text for a parked batch still awaiting sibling decisions.
    ///
    /// Keeps the awaiting run response informative while siblings resolve
    /// without inventing a synthesis: names the just-decided tool and the
    /// remaining count so dashboards show forward motion.
    /// - Parameters:
    ///   - toolName: Just-decided tool.
    ///   - remainingCount: Siblings still pending.
    ///   - approved: Whether the just-decided call was allowed.
    /// - Returns: User-visible progress message.
    private func parkedBatchProgressMessage(toolName: String, remainingCount: Int, approved: Bool) -> String {
        let trimmed = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name: String = if trimmed.isEmpty {
            "the requested tool"
        } else {
            trimmed
        }
        let verb = if approved {
            "Approved"
        } else {
            "Denied"
        }
        if remainingCount <= 0 {
            return "\(verb) \(name)."
        }
        let noun = if remainingCount == 1 {
            "approval"
        } else {
            "approvals"
        }
        return "\(verb) \(name); waiting for \(remainingCount) more \(noun)."
    }

    /// Records a denied parked call in its session.
    ///
    /// Keeps the denial in working memory so a later synthesis never assumes
    /// the gated call ran, without echoing argument JSON.
    /// - Parameters:
    ///   - call: Denied invocation.
    ///   - sessionID: Owning session.
    ///   - onEvent: Optional handler receiving the denial delta.
    /// - Returns: Denial notice text.
    private func recordParkedDenial(
        _ call: ToolInput,
        sessionID: UUID,
        onEvent: (@Sendable (OrchestratorEvent) async -> Void)?
    ) async -> String {
        let denial = OrchestratorToolLoop.deniedApprovalMessage(for: call.toolName)
        await conversations.append(Message(role: .assistant, content: denial), to: sessionID)
        await onEvent?(.textDelta(denial))
        await flushEpisodic([(denial, .assistant)], sessionID: sessionID)
        return denial
    }

    /// Records a missing-tool notice for an allowed parked call.
    ///
    /// The inbox allowed the call but the tool vanished before resume, so no
    /// action exists to buffer; the notice keeps the session auditable.
    /// - Parameters:
    ///   - toolName: Missing tool name.
    ///   - sessionID: Owning session.
    ///   - onEvent: Optional handler receiving the notice delta.
    /// - Returns: Missing-tool notice text.
    private func recordParkedMissingTool(
        _ toolName: String,
        sessionID: UUID,
        onEvent: (@Sendable (OrchestratorEvent) async -> Void)?
    ) async -> String {
        let missing = "Approval allowed for \(toolName), but the tool is no longer available."
        await conversations.append(Message(role: .assistant, content: missing), to: sessionID)
        await onEvent?(.textDelta(missing))
        await flushEpisodic([(missing, .assistant)], sessionID: sessionID)
        return missing
    }

    /// Executes one allowed parked call without re-entering the gate.
    ///
    /// Honors the explicit inbox decision with direct execution so one-shot
    /// approvals run without a second prompt, publishing real-time events
    /// and mirroring the compact tool record for resume.
    /// - Parameters:
    ///   - call: Filed gated invocation to run.
    ///   - tool: Resolved tool to execute.
    ///   - sessionID: Owning session.
    ///   - onEvent: Optional handler receiving tool streaming events.
    /// - Returns: Executed action carrying the tool result.
    private func executeParkedCall(
        _ call: ToolInput,
        tool: any Tool,
        sessionID: UUID,
        onEvent: (@Sendable (OrchestratorEvent) async -> Void)?
    ) async -> ToolAction {
        await onEvent?(.toolStarted(
            toolName: call.toolName,
            callID: call.callID,
            argumentsJSON: call.argumentsJSON
        ))
        let result: ToolResult
        do {
            let output = try await tool.execute(
                input: call,
                context: ToolContext(conversationID: sessionID)
            )
            result = ToolResult(output, toolCallID: call.callID)
        } catch {
            result = .failure(
                toolCallID: call.callID,
                content: "Tool '\(call.toolName)' failed: \(error.localizedDescription)"
            )
        }
        let action = ToolAction(
            toolName: call.toolName,
            callID: call.callID,
            argumentsJSON: call.argumentsJSON,
            result: result
        )
        await onEvent?(.toolCompleted(
            toolName: call.toolName,
            callID: call.callID,
            result: result
        ))
        await conversations.append(result.asMessage(), to: sessionID)
        var pending: [(content: String, role: Message.Role)] = []
        if let record = OrchestratorToolLoop.episodicToolRecord(toolName: call.toolName, result: result) {
            pending.append((record, .tool))
        }
        await flushEpisodic(pending, sessionID: sessionID)
        return action
    }

    /// Runs one synthesis turn for a parked batch in its session.
    ///
    /// Uses the turn's effective prompt so scheduler and custom-prompt parks
    /// continue with the same instructions they parked with, then stores the
    /// final text when it carries user-visible content.
    /// - Parameters:
    ///   - sessionID: Owning session.
    ///   - prompt: Effective prompt active when the turn parked.
    ///   - onEvent: Optional handler receiving text streaming events.
    /// - Returns: Final text plus billed tokens, if reported.
    private func synthesizeParkedTurn(
        sessionID: UUID,
        prompt: String?,
        onEvent: (@Sendable (OrchestratorEvent) async -> Void)?
    ) async throws -> (text: String, billedTokens: Int?) {
        try Task.checkCancellation()
        let tools = await toolBus.availableTools()
        let workingMessages = await conversations.workingHistory(for: sessionID, systemPrompt: prompt)
        let collected = try await collectTurn(messages: workingMessages, tools: tools, onDelta: { delta in
            await onEvent?(.textDelta(delta))
        })
        var pending: [(content: String, role: Message.Role)] = []
        await storeFinalAssistantText(collected.text, sessionID: sessionID, pendingEpisodic: &pending)
        await flushEpisodic(pending, sessionID: sessionID)
        return (collected.text, collected.billedTokens)
    }

    // MARK: - Private helpers

    /// Runs the bounded tool loop for one turn until final text or parking.
    ///
    /// Owns working-history refresh, round budgeting, and mixed
    /// read-plus-gated handling so `process` stays within the body budget.
    /// - Parameters:
    ///   - request: Working history plus turn context for this run.
    ///   - pendingEpisodic: In-out mirror buffer receiving tool records.
    /// - Returns: Finished text plus actions, or a parked waiting response.
    private func runTurnLoop(
        _ request: TurnLoopRequest,
        pendingEpisodic: inout [(content: String, role: Message.Role)]
    ) async throws -> TurnLoopOutcome {
        var workingMessages = request.workingMessages
        let tools = request.tools
        let recall = request.recall
        let sessionID = request.sessionID
        let onEvent = request.onEvent
        var toolActions: [ToolAction] = []
        var finalText = ""
        var toolRounds = 0
        var billedTokens: Int?
        while true {
            try Task.checkCancellation()
            let collected = try await collectTurn(messages: workingMessages, tools: tools, onDelta: { delta in
                await onEvent?(.textDelta(delta))
            })
            if let billed = collected.billedTokens {
                billedTokens = (billedTokens ?? 0) + billed
            }
            finalText = collected.text
            var calls = collected.toolCalls
            if calls.isEmpty {
                calls = try await resolveToolCalls(messages: workingMessages, assistantText: finalText, tools: tools)
            }
            // Narrated gated calls are always collected so mixed turns that
            // pair structured calls with gated narration file approvals
            // instead of dropping them.
            let gated = OrchestratorToolLoop.narratedGatedCalls(from: finalText, tools: tools)
            if calls.isEmpty, gated.isEmpty {
                break
            }
            if !calls.isEmpty {
                toolRounds += 1
                if OrchestratorToolLoop.isLimitExceeded(rounds: toolRounds, max: maxToolIterations) {
                    throw OrchestratorError.toolLoopExceeded(iterations: maxToolIterations)
                }
                let assistantNote = assistantNoteMessage(text: finalText, calls: calls)
                await conversations.append(assistantNote, to: sessionID)
                let executed = try await executeToolCalls(calls, sessionID: sessionID, onEvent: onEvent, pendingEpisodic: &pendingEpisodic)
                toolActions.append(contentsOf: executed)
                if !gated.isEmpty, approvalQueue != nil {
                    let context = ParkGatedCallsContext(
                        gated: gated,
                        narratedText: finalText,
                        tools: tools,
                        sessionID: sessionID,
                        priorActions: toolActions,
                        billedTokens: billedTokens,
                        systemPrompt: request.systemPrompt,
                        onEvent: onEvent
                    )
                    let parked = await parkGatedCalls(context, pendingEpisodic: &pendingEpisodic)
                    return .parked(parked)
                }
                workingMessages = await refreshedWorkingMessages(sessionID: sessionID, recall: recall, systemPrompt: request.systemPrompt)
                finalText = ""
                continue
            }
            if !gated.isEmpty {
                if approvalQueue != nil {
                    let context = ParkGatedCallsContext(
                        gated: gated,
                        narratedText: finalText,
                        tools: tools,
                        sessionID: sessionID,
                        priorActions: toolActions,
                        billedTokens: billedTokens,
                        systemPrompt: request.systemPrompt,
                        onEvent: onEvent
                    )
                    let parked = await parkGatedCalls(context, pendingEpisodic: &pendingEpisodic)
                    return .parked(parked)
                }
                break
            }
        }
        return .finished(finalText: finalText, toolActions: toolActions, billedTokens: billedTokens)
    }

    /// Builds the working-memory note recording one tool round's intent.
    ///
    /// Keeps the turn loop short by owning note construction; the caller
    /// appends it immediately so later tool results always follow their
    /// narrating turn.
    /// - Parameters:
    ///   - text: Assistant text narrating these calls.
    ///   - calls: Tool calls resolved for this round.
    /// - Returns: Assistant message to append before execution.
    private func assistantNoteMessage(text: String, calls: [ToolInput]) -> Message {
        Message(
            role: .assistant,
            content: OrchestratorToolLoop.assistantNoteContent(text: text, calls: calls)
        )
    }

    /// Refreshes recall-augmented history after one tool round.
    ///
    /// Re-reads working history with the turn's bounded recall spliced
    /// after leading system messages, so the next LLM call observes fresh
    /// tool results without persisting recall.
    /// - Parameters:
    ///   - sessionID: Owning session.
    ///   - recall: Bounded recall context for this turn, if any.
    ///   - systemPrompt: Turn-specific system prompt override, if any.
    /// - Returns: History for the next LLM round.
    private func refreshedWorkingMessages(sessionID: UUID, recall: Message?, systemPrompt: String? = nil) async -> [Message] {
        await MemoryEngine.historyWithRecall(
            conversations.workingHistory(for: sessionID, systemPrompt: systemPrompt ?? self.systemPrompt),
            recall: recall
        )
    }

    /// Stores the final assistant text when it carries user-visible content.
    ///
    /// Placeholder `Calling ... [...]` narration and blank turns stay out
    /// of working memory; the episodic mirror buffers alongside so commit
    /// keeps both stores aligned.
    /// - Parameters:
    ///   - finalText: Final turn text.
    ///   - sessionID: Owning session.
    ///   - pendingEpisodic: In-out mirror buffer receiving the final text.
    private func storeFinalAssistantText(
        _ finalText: String,
        sessionID: UUID,
        pendingEpisodic: inout [(content: String, role: Message.Role)]
    ) async {
        guard OrchestratorToolLoop.shouldStoreAssistantText(finalText) else { return }
        await conversations.append(Message(role: .assistant, content: finalText), to: sessionID)
        pendingEpisodic.append((finalText, .assistant))
    }

    /// Executes tool calls in sequence, publishing real-time events and recording outcomes.
    ///
    /// Each executed tool is logged before observing cancellation: the
    /// action, its completion event, the working-memory message, and the
    /// compact episodic record all land first, so a cancel arriving after
    /// the side effect still leaves an audit trail before rethrowing.
    private func executeToolCalls(
        _ calls: [ToolInput],
        sessionID: UUID,
        onEvent: (@Sendable (OrchestratorEvent) async -> Void)?,
        pendingEpisodic: inout [(content: String, role: Message.Role)]
    ) async throws -> [ToolAction] {
        var actions: [ToolAction] = []
        let context = ToolContext(conversationID: sessionID)
        for call in calls {
            try Task.checkCancellation()
            await onEvent?(.toolStarted(
                toolName: call.toolName,
                callID: call.callID,
                argumentsJSON: call.argumentsJSON
            ))
            let result = await toolBus.execute(toolCall: call, context: context)
            let action = ToolAction(
                toolName: call.toolName,
                callID: call.callID,
                argumentsJSON: call.argumentsJSON,
                result: result
            )
            actions.append(action)
            await onEvent?(.toolCompleted(
                toolName: call.toolName,
                callID: call.callID,
                result: result
            ))
            await conversations.append(result.asMessage(), to: sessionID)
            if let record = OrchestratorToolLoop.episodicToolRecord(toolName: call.toolName, result: result) {
                pendingEpisodic.append((record, .tool))
            }
            try Task.checkCancellation()
        }
        return actions
    }

    /// Files gated narrations and ends the turn parked waiting on approval.
    ///
    /// Each gated call is filed through the shared queue path tagged with
    /// the session, tracked for a later resume under one per-turn batch
    /// identifier, and left unexecuted so prose can never bypass the gate.
    /// Filed requests also emit live approval events so service layers can
    /// broadcast the prompt without polling. Working memory keeps the
    /// narrating note plus the waiting message for audit and replay, while
    /// the episodic mirror keeps only the waiting message alongside prior
    /// tool records.
    /// - Parameters:
    ///   - context: Grouped gated-narration inputs for this parked turn.
    ///   - pendingEpisodic: In-out mirror buffer receiving the waiting message.
    /// - Returns: Parked response carrying the waiting message.
    private func parkGatedCalls(
        _ context: ParkGatedCallsContext,
        pendingEpisodic: inout [(content: String, role: Message.Role)]
    ) async -> OrchestratorResponse {
        let byName = Dictionary(context.tools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let batchID = UUID()
        if let queue = approvalQueue {
            for call in context.gated {
                guard let tool = byName[call.toolName] else { continue }
                let request = await queue.fileRequest(tool: tool, call: call, sessionID: context.sessionID)
                parkedNarratedApprovals[request.id] = ParkedNarratedApproval(
                    sessionID: context.sessionID,
                    toolCall: call,
                    systemPrompt: context.systemPrompt,
                    batchID: batchID
                )
                await context.onEvent?(.approval(request))
            }
        }
        let waiting = OrchestratorToolLoop.waitingOnApprovalMessage(for: context.gated)
        await conversations.append(assistantNoteMessage(text: context.narratedText, calls: context.gated), to: context.sessionID)
        await conversations.append(Message(role: .assistant, content: waiting), to: context.sessionID)
        pendingEpisodic.append((waiting, .assistant))
        await context.onEvent?(.textDelta(waiting))
        await flushEpisodic(pendingEpisodic, sessionID: context.sessionID)
        let cumulativeTokens = accumulateSessionTokens(context.billedTokens, for: context.sessionID)
        // Parked gated calls stay pending with no result so the awaiting
        // approval run entry keeps their names and call identifiers for
        // detail views and call-ID fallback.
        let pendingGatedActions = context.gated.map {
            ToolAction(toolName: $0.toolName, callID: $0.callID, argumentsJSON: $0.argumentsJSON, result: nil)
        }
        return OrchestratorResponse(
            text: waiting,
            sessionID: context.sessionID,
            toolActions: context.priorActions + pendingGatedActions,
            totalTokens: context.billedTokens,
            modelName: llm.modelInfo.name,
            contextLength: llm.modelInfo.contextLength,
            sessionTokens: cumulativeTokens,
            isParked: true
        )
    }
}

// MARK: - Session tokens and memory mirroring

/// Holds episodic flushing, remember handling, token totals, and LLM
/// collection helpers so no single type body exceeds the length budget.
extension Orchestrator {
    /// Flushes buffered episodic mirrors without throwing.
    ///
    /// Called once on commit (and on non-cancellation failures to match
    /// working-memory partials). Cancelled turns flush only when tools
    /// already executed, so a pure cancel leaves no trace while a cancel
    /// after side effects stays auditable in both stores.
    /// - Parameters:
    ///   - pending: Buffered content plus roles in commit order.
    ///   - sessionID: Owning session.
    private func flushEpisodic(_ pending: [(content: String, role: Message.Role)], sessionID: UUID) async {
        guard let memoryEngine else { return }
        for entry in pending {
            await memoryEngine.mirrorTurn(content: entry.content, sessionID: sessionID, role: entry.role, failurePolicy: .silent)
        }
    }

    /// Flushes buffered episodic mirrors without observing cancellation.
    ///
    /// Cancel-path companion to `flushEpisodic(_:sessionID:)`: the caller is
    /// already cancelled when tools have executed, so cancellable mirrors
    /// would throw before dispatch and drop the audit trail. Runs each mirror
    /// to completion so executed tools stay auditable in both stores.
    /// - Parameters:
    ///   - pending: Buffered content plus roles in commit order.
    ///   - sessionID: Owning session.
    private func flushEpisodicUncancellable(
        _ pending: [(content: String, role: Message.Role)],
        sessionID: UUID
    ) async {
        guard let memoryEngine else { return }
        for entry in pending {
            await memoryEngine.mirrorTurnUncancellable(
                content: entry.content,
                sessionID: sessionID,
                role: entry.role
            )
        }
    }

    /// Returns an acknowledgement response for explicit remember requests, if applicable.
    ///
    /// Remember intents bypass the LLM so profile facts persist deterministically
    /// with the same acknowledgement every caller sees; the turn lands in
    /// working memory immediately while the episodic mirror buffers in
    /// `pendingEpisodic` until the caller flushes on commit. Nil means the
    /// input is a normal turn that must continue through recall and the
    /// tool loop.
    /// - Parameters:
    ///   - text: Trimmed user text to inspect for a remember intent.
    ///   - source: Input origin recorded on the stored profile fact.
    ///   - sessionID: Owning session for the acknowledgement turn.
    ///   - pendingEpisodic: In-out buffer receiving the acknowledgement for commit-time flush.
    ///   - onEvent: Optional handler receiving the acknowledgement delta.
    /// - Returns: A complete response for remember requests, otherwise nil.
    private func rememberEarlyResponse(
        text: String,
        source: String,
        sessionID: UUID,
        pendingEpisodic: inout [(content: String, role: Message.Role)],
        onEvent: (@Sendable (OrchestratorEvent) async -> Void)?
    ) async -> OrchestratorResponse? {
        guard let factText = MemoryEngine.rememberFactText(from: text) else {
            return nil
        }
        let acknowledgement = await rememberAcknowledgement(factText: factText, source: source)
        await conversations.append(Message(role: .assistant, content: acknowledgement), to: sessionID)
        pendingEpisodic.append((acknowledgement, .assistant))
        await onEvent?(.textDelta(acknowledgement))
        return OrchestratorResponse(
            text: acknowledgement,
            sessionID: sessionID,
            toolActions: [],
            sessionTokens: sessionTokensBySession[sessionID]
        )
    }

    /// Folds this turn's billed tokens into the session total.
    ///
    /// The LLM reports per-round usage while callers bill per session, so the
    /// turn sum is added once here and the running total returned; turns with
    /// no reported usage leave the stored total untouched so untracked
    /// providers never reset prior accumulation.
    /// - Parameters:
    ///   - billedTokens: Tokens billed across every LLM round in this turn, if any.
    ///   - sessionID: Owning session whose cumulative total is updated.
    /// - Returns: Cumulative session total after folding in this turn.
    private func accumulateSessionTokens(_ billedTokens: Int?, for sessionID: UUID) -> Int? {
        guard let billedTokens else {
            return sessionTokensBySession[sessionID]
        }
        let updated = (sessionTokensBySession[sessionID] ?? 0) + billedTokens
        sessionTokensBySession[sessionID] = updated
        // Keep recency behind the map so overflow evicts deterministically.
        if let prior = sessionTokenOrder.firstIndex(of: sessionID) {
            sessionTokenOrder.remove(at: prior)
        }
        sessionTokenOrder.append(sessionID)
        // Bound the map so removed or evicted sessions cannot leak totals
        // forever; drops the least-recently-billed session rather than the
        // just-updated one. Falls back to any other tracked session and
        // finally to the order head when the order desyncs, so one
        // desynced append cannot grow the map without bound.
        if sessionTokensBySession.count > Self.maxTrackedSessions {
            let victim = sessionTokenOrder.first(where: { $0 != sessionID })
                ?? sessionTokensBySession.keys.first(where: { $0 != sessionID })
                ?? sessionTokenOrder.first
            if let victim {
                sessionTokensBySession.removeValue(forKey: victim)
                sessionTokenOrder.removeAll(where: { $0 == victim })
            }
        }
        return updated
    }

    /// Drops the cached token total for one session.
    ///
    /// Call alongside conversation removal so deleted sessions never leave
    /// stale totals behind. Parked narrated approvals for the session are
    /// dropped as well so a deleted conversation cannot resume later.
    /// - Parameter id: Session whose total is discarded.
    public func forgetSession(id: UUID) {
        sessionTokensBySession.removeValue(forKey: id)
        sessionTokenOrder.removeAll(where: { $0 == id })
        let removedBatchIDs = Set(parkedNarratedApprovals.values.filter { $0.sessionID == id }.map(\.batchID))
        parkedNarratedApprovals = parkedNarratedApprovals.filter { $0.value.sessionID != id }
        for batchID in removedBatchIDs {
            parkedBatchExecutedActions.removeValue(forKey: batchID)
        }
    }

    /// Removes one session from history and drops its billed total together.
    ///
    /// Single entry point for deletes so working memory and token totals
    /// never diverge when callers remove sessions outside the chat turn.
    /// - Parameter id: Session to remove.
    public func removeSession(id: UUID) async {
        await conversations.removeSession(id: id)
        forgetSession(id: id)
    }

    /// Removes every session and drops every billed total together.
    ///
    /// Parked narrated approvals are dropped as well so no deleted session
    /// can resume after the wipe.
    public func removeAllSessions() async {
        await conversations.removeAllSessions()
        clearSessionTokens()
        parkedNarratedApprovals.removeAll()
        parkedBatchExecutedActions.removeAll()
    }

    /// Clears one session's history and drops its billed total together.
    ///
    /// Mirrors the REPL `/clear` reset so a cleared session restarts
    /// billing from zero instead of carrying prior totals.
    /// - Parameter sessionID: Session to clear.
    public func clearSession(_ sessionID: UUID) async {
        await conversations.clear(sessionID: sessionID)
        forgetSession(id: sessionID)
    }

    /// Drops every cached session token total.
    ///
    /// Parked narrated approvals are kept: token totals are a billing cache
    /// while parked approvals are pending user decisions that outlive a
    /// billing reset.
    public func clearSessionTokens() {
        sessionTokensBySession.removeAll()
        sessionTokenOrder.removeAll()
    }

    /// Stores an explicit remember request and builds its acknowledgement.
    ///
    /// Shares acknowledgement text with the CLI remember path via
    /// `MemoryEngine.rememberAcknowledgementText(for:stored:)` so every
    /// caller stores the same assistant turn: storable facts persist via
    /// the memory engine failure-isolated, empty or punctuation-only facts
    /// yield usage text, and store failures yield a failure note without
    /// touching the LLM path.
    /// - Parameters:
    ///   - factText: Stripped fact text from the remember parser.
    ///   - source: Input origin stored on the profile fact.
    /// - Returns: Acknowledgement text for the assistant turn.
    private func rememberAcknowledgement(factText: String, source: String) async -> String {
        guard MemoryEngine.isStorableFact(factText) else {
            return MemoryEngine.rememberAcknowledgementText(for: factText, stored: false)
        }
        guard let memoryEngine else {
            return MemoryEngine.rememberAcknowledgementText(for: factText, stored: false)
        }
        let stored = await memoryEngine.storeRememberedFact(
            content: factText,
            source: OrchestratorToolLoop.resolvedSource(source)
        )
        return MemoryEngine.rememberAcknowledgementText(for: factText, stored: stored)
    }

    /// Collects a full text turn from the streaming chat API.
    ///
    /// Mid-stream failures surface as `OrchestratorError.llmFailed` even
    /// when partial text was already yielded, so callers never mistake a
    /// truncated turn for a successful one. Billed usage reported on the
    /// terminal `LLMResponse` chunk is returned alongside the text so the
    /// API path surfaces the same session-cumulative usage the CLI
    /// `runChunkedTurn`/`runTextTurn` paths render.
    /// - Parameters:
    ///   - messages: Conversation history.
    ///   - tools: Tools the model may call.
    /// - Returns: Concatenated response text, billed tokens if reported, and streamed tool calls.
    /// - Throws: `OrchestratorError.llmFailed` when the stream reports an error.
    private func collectTurn(
        messages: [Message],
        tools: [any Tool],
        onDelta: (@Sendable (String) async -> Void)? = nil
    ) async throws -> TurnDraft {
        var text = ""
        var billed: Int?
        var toolCalls: [ToolInput] = []
        let stream = llm.chat(messages: messages, tools: tools)
        for await chunk in stream {
            try Task.checkCancellation()
            if let message = chunk.errorMessage {
                throw OrchestratorError.llmFailed(message.isEmpty ? "unknown error" : message)
            }
            text += chunk.delta
            if !chunk.toolCalls.isEmpty {
                toolCalls.append(contentsOf: chunk.toolCalls)
            }
            // Deltas stream even when a chunk also carries tool calls:
            // suppressing them breaks streaming fidelity for models that
            // narrate alongside function calls.
            if !chunk.delta.isEmpty {
                await onDelta?(chunk.delta)
            }
            if chunk.isFinished {
                billed = chunk.totalTokens
                break
            }
        }
        return TurnDraft(text: text, billedTokens: billed, toolCalls: toolCalls)
    }

    /// Resolves tool calls for the latest assistant turn.
    ///
    /// Appends the just-collected assistant text unless history already
    /// ends with that exact turn, so resolvers always see the latest
    /// text. Blank assistant text is skipped so resolvers never observe
    /// an empty trailing turn. When the resolver yields zero structured
    /// calls, narrated `Calling ... [...]` placeholder lines fall back
    /// to read-only executions via
    /// `OrchestratorToolLoop/narratedToolCalls(from:tools:)` so text-only
    /// turns describing a read still run it; invalid argument JSON,
    /// unknown tools, and approval-gated tools stay unexecuted.
    /// - Parameters:
    ///   - messages: Working history.
    ///   - assistantText: Latest assistant text (for resolvers that
    ///     parse text).
    ///   - tools: Available tools.
    /// - Returns: Calls to execute, or empty when final.
    private func resolveToolCalls(messages: [Message], assistantText: String, tools: [any Tool]) async throws -> [ToolInput] {
        guard let toolResolver else {
            return OrchestratorToolLoop.narratedToolCalls(from: assistantText, tools: tools)
        }
        var context = messages
        if !assistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let last = context.last {
                if last.role != .assistant || last.content != assistantText {
                    context.append(Message(role: .assistant, content: assistantText))
                }
            } else {
                context.append(Message(role: .assistant, content: assistantText))
            }
        }
        let calls = try await toolResolver(context, tools)
        if !calls.isEmpty {
            return calls
        }
        return OrchestratorToolLoop.narratedToolCalls(from: assistantText, tools: tools)
    }
}

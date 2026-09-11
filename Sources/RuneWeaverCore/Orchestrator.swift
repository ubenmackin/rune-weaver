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

    /// Creates user input.
    /// - Parameters:
    ///   - text: Raw user text.
    ///   - sessionID: Owning session. Defaults to a new UUID.
    ///   - source: Input origin. Defaults to `"text"`.
    public init(text: String, sessionID: UUID = UUID(), source: String = "text") {
        self.text = text
        self.sessionID = sessionID
        self.source = source
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

    /// Creates a response.
    /// - Parameters:
    ///   - text: Final assistant text.
    ///   - sessionID: Owning session.
    ///   - toolActions: Tool invocations performed.
    public init(text: String, sessionID: UUID, toolActions: [ToolAction] = []) {
        self.text = text
        self.sessionID = sessionID
        self.toolActions = toolActions
    }
}

/// Failures raised by ``Orchestrator``.
public enum OrchestratorError: Error, Sendable, Equatable {
    /// The input text was empty or whitespace-only.
    case emptyInput
    /// The tool loop still requested tool calls after `maxToolIterations`
    /// tool rounds plus the final synthesis turn.
    case toolLoopExceeded(iterations: Int)
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
/// assistant-note content for tool-only turns, whether a tool result is
/// worth mirroring or assistant text is worth storing, when the tool-round
/// budget is exceeded, and how input sources are normalized.
public enum OrchestratorToolLoop {
    /// Returns the assistant content to persist for a tool round.
    ///
    /// Blank model text falls back to the shared placeholder so tool results
    /// keep their parent turn.
    /// - Parameters:
    ///   - text: Latest assistant text.
    ///   - calls: Tool calls needing a parent assistant note.
    /// - Returns: `text` when non-blank, else the placeholder record.
    public static func assistantNoteContent(text: String, calls: [ToolInput]) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? ToolInput.placeholderContent(for: calls) : text
    }

    /// Whether a tool result is worth mirroring to episodic memory.
    ///
    /// Empty results skip only the episodic mirror so keyword search stays
    /// free of empty turns. Working history always keeps every result so
    /// the next LLM turn has feedback and never repeats the call.
    /// - Parameter content: Tool result content.
    /// - Returns: True when the content is non-blank.
    public static func shouldStoreToolResult(_ content: String) -> Bool {
        !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
}

/// Core orchestration loop: input, context, LLM, tools, response.
///
/// The orchestrator receives user input, loads session context,
/// calls the LLM, executes any requested tools via the ``ToolBus``
/// (feeding each ``ToolResult`` back for the next LLM turn), and
/// returns the final text while storing every turn in the
/// ``ConversationManager`` and mirroring it raw into episodic memory
/// via an optional ``MemoryEngine`` (failure-isolated, per the Memory
/// Flow step 1: every turn to episodic). The CLI chat loop delegates
/// its per-round decisions to ``OrchestratorToolLoop`` so both entry
/// points share one loop policy.
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
    public init(
        conversations: ConversationManager,
        toolBus: ToolBus,
        llm: any LLMProvider,
        systemPrompt: String? = nil,
        maxToolIterations: Int = 8,
        toolResolver: OrchestratorToolResolver? = nil,
        memoryEngine: MemoryEngine? = nil
    ) {
        self.conversations = conversations
        self.toolBus = toolBus
        self.llm = llm
        self.systemPrompt = systemPrompt
        self.maxToolIterations = max(1, maxToolIterations)
        self.toolResolver = toolResolver
        self.memoryEngine = memoryEngine
    }

    /// Processes one user input through the full loop.
    ///
    /// 1. Resolves (or creates) the session and stores the user turn in
    ///    working memory, mirroring it to episodic memory.
    /// 2. Handles explicit remember requests (`remember ...`,
    ///    `/remember ...`) by storing the profile fact via the memory
    ///    engine and returning an acknowledgement without calling the LLM,
    ///    so non-CLI callers share the CLI remember behavior.
    /// 3. Loads context and calls the LLM.
    /// 4. Executes requested tools via the bus, appends each result,
    ///    and re-invokes the LLM until the turn is final. Up to
    ///    `maxToolIterations` tool rounds run, followed by one final
    ///    synthesis turn so the last tool results are always answered;
    ///    when the synthesis turn still requests tools, throws
    ///    ``OrchestratorError/toolLoopExceeded(iterations:)``.
    ///    Every assistant note and tool result is appended to working
    ///    history so the next LLM turn has feedback; non-empty tool
    ///    results are mirrored to episodic memory failure-isolated while
    ///    empty results skip only the episodic mirror so keyword search
    ///    stays free of empty turns.
    /// 5. Stores the final assistant turn and returns it. Empty final
    ///    text (empty LLM stream or failure) is not stored or mirrored.
    /// - Parameter input: User text plus session routing.
    /// - Returns: Final text, session, and tool actions taken.
    public func process(input: UserInput) async throws -> OrchestratorResponse {
        let text = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw OrchestratorError.emptyInput
        }
        let sessionID = input.sessionID
        _ = await conversations.ensureSession(id: sessionID)
        await conversations.append(Message(role: .user, content: text), to: sessionID)
        await memoryEngine?.mirrorTurn(content: text, sessionID: sessionID, role: .user, failurePolicy: .silent)

        if let factText = MemoryEngine.rememberFactText(from: text) {
            let acknowledgement = await rememberAcknowledgement(factText: factText, source: input.source)
            await conversations.append(Message(role: .assistant, content: acknowledgement), to: sessionID)
            await memoryEngine?.mirrorTurn(
                content: acknowledgement,
                sessionID: sessionID,
                role: .assistant,
                failurePolicy: .silent
            )
            return OrchestratorResponse(text: acknowledgement, sessionID: sessionID, toolActions: [])
        }

        var workingMessages = await conversations.workingHistory(for: sessionID, systemPrompt: systemPrompt)
        let tools = await toolBus.availableTools()
        var toolActions: [ToolAction] = []
        var finalText = ""
        var toolRounds = 0

        while true {
            finalText = await collectText(messages: workingMessages, tools: tools)
            let calls = try await resolveToolCalls(messages: workingMessages, assistantText: finalText, tools: tools)
            if calls.isEmpty {
                break
            }
            toolRounds += 1
            if OrchestratorToolLoop.isLimitExceeded(rounds: toolRounds, max: maxToolIterations) {
                throw OrchestratorError.toolLoopExceeded(iterations: maxToolIterations)
            }
            let context = ToolContext(conversationID: sessionID)
            let assistantNote = Message(
                role: .assistant,
                content: OrchestratorToolLoop.assistantNoteContent(text: finalText, calls: calls)
            )
            await conversations.append(assistantNote, to: sessionID)
            await memoryEngine?.mirrorTurn(
                content: assistantNote.content,
                sessionID: sessionID,
                role: .assistant,
                failurePolicy: .silent
            )
            for call in calls {
                let result = await toolBus.execute(toolCall: call, context: context)
                toolActions.append(ToolAction(
                    toolName: call.toolName,
                    callID: call.callID,
                    argumentsJSON: call.argumentsJSON,
                    result: result
                ))
                await conversations.append(result.asMessage(), to: sessionID)
                if OrchestratorToolLoop.shouldStoreToolResult(result.content) {
                    await memoryEngine?.mirrorTurn(
                        content: result.content,
                        sessionID: sessionID,
                        role: .tool,
                        toolCallID: result.toolCallID,
                        failurePolicy: .silent
                    )
                }
            }
            workingMessages = await conversations.workingHistory(for: sessionID, systemPrompt: systemPrompt)
            finalText = ""
        }

        if OrchestratorToolLoop.shouldStoreAssistantText(finalText) {
            await conversations.append(Message(role: .assistant, content: finalText), to: sessionID)
            await memoryEngine?.mirrorTurn(
                content: finalText,
                sessionID: sessionID,
                role: .assistant,
                failurePolicy: .silent
            )
        }
        return OrchestratorResponse(text: finalText, sessionID: sessionID, toolActions: toolActions)
    }

    // MARK: - Private helpers

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
    /// - Parameters:
    ///   - messages: Conversation history.
    ///   - tools: Tools the model may call.
    /// - Returns: Concatenated response text.
    private func collectText(messages: [Message], tools: [any Tool]) async -> String {
        var text = ""
        let stream = llm.chat(messages: messages, tools: tools)
        for await chunk in stream {
            text += chunk.delta
            if chunk.isFinished {
                break
            }
        }
        return text
    }

    /// Resolves tool calls for the latest assistant turn.
    ///
    /// Appends the just-collected assistant text unless history already
    /// ends with that exact turn, so resolvers always see the latest
    /// text. Blank assistant text is skipped so resolvers never observe
    /// an empty trailing turn.
    /// - Parameters:
    ///   - messages: Working history.
    ///   - assistantText: Latest assistant text (for resolvers that
    ///     parse text).
    ///   - tools: Available tools.
    /// - Returns: Calls to execute, or empty when final.
    private func resolveToolCalls(messages: [Message], assistantText: String, tools: [any Tool]) async throws -> [ToolInput] {
        guard let toolResolver else { return [] }
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
        return try await toolResolver(context, tools)
    }
}

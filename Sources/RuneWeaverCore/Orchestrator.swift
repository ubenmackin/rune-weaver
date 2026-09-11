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
    /// The tool loop still had pending calls after `maxToolIterations`.
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

/// Core orchestration loop: input, context, LLM, tools, response.
///
/// The orchestrator receives user input, loads session context,
/// calls the LLM, executes any requested tools via the ``ToolBus``
/// (feeding each ``ToolResult`` back for the next LLM turn), and
/// returns the final text while storing every turn in the
/// ``ConversationManager``.
public actor Orchestrator {
    /// Session and history owner.
    private let conversations: ConversationManager
    /// Tool registry and permission gate.
    private let toolBus: ToolBus
    /// LLM backend serving completions.
    private let llm: any LLMProvider
    /// Developer instructions prepended to every turn.
    private let systemPrompt: String?
    /// Maximum tool-call rounds before giving up.
    private let maxToolIterations: Int
    /// Optional resolver mapping an assistant turn to tool calls.
    private let toolResolver: OrchestratorToolResolver?

    /// Creates an orchestrator.
    /// - Parameters:
    ///   - conversations: Session and history owner.
    ///   - toolBus: Tool registry and permission gate.
    ///   - llm: LLM backend serving completions.
    ///   - systemPrompt: Developer instructions prepended to every
    ///     turn. Defaults to nil.
    ///   - maxToolIterations: Maximum tool-call rounds. Defaults to 8.
    ///   - toolResolver: Resolver mapping an assistant turn to tool
    ///     calls. Defaults to nil (text-only).
    public init(
        conversations: ConversationManager,
        toolBus: ToolBus,
        llm: any LLMProvider,
        systemPrompt: String? = nil,
        maxToolIterations: Int = 8,
        toolResolver: OrchestratorToolResolver? = nil
    ) {
        self.conversations = conversations
        self.toolBus = toolBus
        self.llm = llm
        self.systemPrompt = systemPrompt
        self.maxToolIterations = max(1, maxToolIterations)
        self.toolResolver = toolResolver
    }

    /// Processes one user input through the full loop.
    ///
    /// 1. Resolves (or creates) the session and stores the user turn.
    /// 2. Loads context and calls the LLM.
    /// 3. Executes requested tools via the bus, appends each result,
    ///    and re-invokes the LLM until the turn is final. When tool
    ///    calls are still pending after `maxToolIterations` rounds,
    ///    throws ``OrchestratorError/toolLoopExceeded(iterations:)``.
    /// 4. Stores the final assistant turn and returns it.
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

        var workingMessages = await workingHistory(for: sessionID)
        let tools = await toolBus.availableTools()
        var toolActions: [ToolAction] = []
        var finalText = ""
        var lastTurnHadCalls = false

        for _ in 0 ..< maxToolIterations {
            finalText = await collectText(messages: workingMessages, tools: tools)
            let calls = try await resolveToolCalls(messages: workingMessages, assistantText: finalText, tools: tools)
            if calls.isEmpty {
                lastTurnHadCalls = false
                break
            }
            lastTurnHadCalls = true
            let context = ToolContext(conversationID: sessionID)
            let assistantNote = Message(
                role: .assistant,
                content: finalText.isEmpty ? "Calling \(calls.map(\.toolName).joined(separator: ", "))…" : finalText
            )
            await conversations.append(assistantNote, to: sessionID)
            for call in calls {
                let result = await toolBus.execute(toolCall: call, context: context)
                toolActions.append(ToolAction(
                    toolName: call.toolName,
                    callID: call.callID,
                    argumentsJSON: call.argumentsJSON,
                    result: result
                ))
                await conversations.append(result.asMessage(), to: sessionID)
            }
            workingMessages = await workingHistory(for: sessionID)
            finalText = ""
        }

        if lastTurnHadCalls {
            throw OrchestratorError.toolLoopExceeded(iterations: maxToolIterations)
        }
        await conversations.append(Message(role: .assistant, content: finalText), to: sessionID)
        return OrchestratorResponse(text: finalText, sessionID: sessionID, toolActions: toolActions)
    }

    // MARK: - Private helpers

    /// Builds the working history with the system prompt first.
    ///
    /// Dedup is shared with the CLI chat loop via
    /// `Array.withSystemPrompt(_:)`: an identical leading system message
    /// is kept, a stale one is replaced, and prompts are never stacked.
    /// - Parameter sessionID: Session identifier.
    /// - Returns: Messages for the next LLM call.
    private func workingHistory(for sessionID: UUID) async -> [Message] {
        let history = await conversations.history(for: sessionID)
        return history.withSystemPrompt(systemPrompt)
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
    /// - Parameters:
    ///   - messages: Working history.
    ///   - assistantText: Latest assistant text (for resolvers that
    ///     parse text).
    ///   - tools: Available tools.
    /// - Returns: Calls to execute, or empty when final.
    private func resolveToolCalls(messages: [Message], assistantText: String, tools: [any Tool]) async throws -> [ToolInput] {
        guard let toolResolver else { return [] }
        var context = messages
        if let last = context.last, last.role != .assistant {
            context.append(Message(role: .assistant, content: assistantText))
        }
        return try await toolResolver(context, tools)
    }
}

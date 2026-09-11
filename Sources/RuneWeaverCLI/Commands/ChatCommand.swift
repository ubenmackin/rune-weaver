import ArgumentParser
import Foundation
import RuneWeaverCore
import RuneWeaverLLM

/// Cooperative SIGINT state for the chat REPL.
///
/// Tripped by the `SIGINT` dispatch source and polled by the REPL loop.
/// Lock-guarded (instead of a signal-handler-mutated global) so it is
/// data-race free under Swift 6 concurrency.
private final class ChatInterruptState: @unchecked Sendable {
    /// Whether SIGINT has been delivered.
    private var tripped = false
    /// Guards `tripped` across the signal queue and the REPL task.
    private let lock = NSLock()

    /// Records SIGINT delivery.
    func trip() {
        lock.lock()
        tripped = true
        lock.unlock()
    }

    /// Whether SIGINT has been delivered.
    var isTripped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return tripped
    }
}

/// Maps a REPL answer to a graduated-trust tier.
///
/// Accepts the numbered menu (`1`–`5`), tier names, and `y`/`yes` as a
/// one-shot approval for compatibility with the old binary prompt.
/// Anything else (including empty input) denies the call.
/// - Parameter answer: Raw trimmed user input, if any.
/// - Returns: The chosen tier, or nil to deny.
private func chatTrustDuration(for answer: String?) -> TrustDuration? {
    switch (answer ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "1", "once", "this time", "only this time", "y", "yes":
        .thisTime
    case "2", "5 minutes", "5minutes", "5 min", "five minutes":
        .fiveMinutes
    case "3", "hour", "1 hour", "one hour", "next hour":
        .oneHour
    case "4", "day", "1 day", "one day", "next day":
        .oneDay
    case "5", "forever", "always":
        .forever
    default:
        nil
    }
}

/// Interactive chat session with the agent.
///
/// Loads `config.toml`, selects an LLM provider (with `--provider`
/// overriding `llm.default_provider`), and enters a read-eval-print loop.
/// Assistant tokens stream back with a typewriter effect, requested tool
/// calls are shown inline (yellow) with their results, and
/// `requiresApproval` tools prompt for confirmation before running.
/// Ctrl+C, EOF, `/exit`, and `/quit` all shut the session down gracefully.
struct ChatCommand: AsyncParsableCommand {
    /// Top-level command configuration.
    static let configuration = CommandConfiguration(
        commandName: "chat",
        abstract: "Start an interactive chat session with the agent."
    )

    /// Provider name overriding `llm.default_provider`.
    @Option(name: .long, help: "Override the configured LLM provider (e.g. mlx, openrouter, local).")
    var provider: String?

    /// Session UUID to resume; a new session starts when omitted.
    @Option(name: .long, help: "Resume a previous session by UUID. Starts a new session when omitted.")
    var session: String?

    /// Config file path override.
    @Option(name: .long, help: "Path to config.toml (defaults to ~/.runeweaver/config.toml).")
    var config: String?

    /// Developer instructions prepended to the conversation.
    @Option(name: .long, help: "System prompt prepended to the conversation.")
    var systemPrompt: String?

    /// Maximum tool-call rounds per assistant turn.
    @Option(name: .long, help: "Maximum tool-call rounds per assistant turn.")
    var maxToolIterations: Int = 8

    /// Loads config, selects a provider, and enters the REPL.
    mutating func run() async throws {
        let loaded = try CLIConfigLoader.loadConfig(path: config)
        if loaded.isFallback {
            print(TerminalStyle.dim("No config found at \(loaded.url.path); using built-in defaults."))
        }

        let providers = await CLIProviderBuilder.buildProviders(from: loaded.config.llm)
        guard !providers.isEmpty else {
            print(TerminalStyle.error("No LLM providers are enabled. Check [llm.providers.*] in \(loaded.url.path)."))
            throw ExitCode(1)
        }
        guard let selected = CLIProviderBuilder.selectProvider(
            named: provider,
            from: providers,
            config: loaded.config.llm
        ) else {
            let names = providers.map(\.name).sorted().joined(separator: ", ")
            print(TerminalStyle.error("Unknown provider '\(provider ?? "")'. Available: \(names)."))
            throw ExitCode(1)
        }

        let sessionID = try resolveSessionID(session)
        var active = selected
        // Tag cloud requests with the chat session when the backend supports it.
        // Local providers never send the session header, so they are left untouched.
        if var sessioned = active as? OpenAICompatibleProvider {
            sessioned.sessionID = sessionID.uuidString
            active = sessioned
        }
        let conversations = ConversationManager()
        await conversations.ensureSession(id: sessionID)
        let permissionGate = PermissionGate()
        let toolBus = await CLIShared.makeToolBus(permissionGate: permissionGate)
        await toolBus.setApprovalHandler { tool, call in
            print(TerminalStyle.tool("Tool '\(call.toolName)' requires approval."))
            print(TerminalStyle.dim("  [1] Only this time  [2] Next 5 minutes  [3] Next hour  [4] Next day  [5] Forever  [N] Deny (default)"))
            print(TerminalStyle.tool("  Allow? "), terminator: "")
            fflush(stdout)
            let answer = readLine(strippingNewline: true)
            guard let duration = chatTrustDuration(for: answer) else {
                return false
            }
            if duration != .thisTime {
                let descriptor = ActionDescriptor.descriptor(for: call, tool: tool)
                await permissionGate.grantTrust(for: descriptor, duration: duration)
            }
            return true
        }

        print(TerminalStyle.dim("Connected to \(active.name) (\(active.modelInfo.name)). Session \(sessionID.uuidString)."))
        print(TerminalStyle.dim("Type /help for commands, /exit to quit. Ctrl+C shuts down gracefully."))
        await runChatREPL(
            provider: active,
            conversations: conversations,
            toolBus: toolBus,
            sessionID: sessionID,
            systemPrompt: systemPrompt,
            maxToolIterations: max(1, maxToolIterations)
        )
    }

    /// Parses `--session` into a UUID, starting fresh when omitted.
    /// - Parameter raw: Raw `--session` value, if any.
    /// - Returns: Session identifier to use.
    /// - Throws: `ValidationError` when the value is not a UUID.
    private func resolveSessionID(_ raw: String?) throws -> UUID {
        guard let raw, !raw.isEmpty else { return UUID() }
        guard let id = UUID(uuidString: raw) else {
            throw ValidationError("--session must be a UUID (got '\(raw)').")
        }
        return id
    }
}

/// Runs the read-eval-print loop until EOF, `/exit`, or SIGINT.
///
/// SIGINT is observed via a `DispatchSourceSignal` (block-based, no C
/// handler globals) tripping a lock-guarded flag polled by the loop,
/// which is data-race free under Swift 6 concurrency.
/// - Parameters:
///   - provider: Active LLM backend serving completions.
///   - conversations: Session and history owner.
///   - toolBus: Tool registry consulted for model-requested calls.
///   - sessionID: Session identifier for this REPL.
///   - systemPrompt: Developer instructions prepended to every turn.
///   - maxToolIterations: Maximum tool-call rounds per assistant turn.
private func runChatREPL(
    provider: any LLMProvider,
    conversations: ConversationManager,
    toolBus: ToolBus,
    sessionID: UUID,
    systemPrompt: String?,
    maxToolIterations: Int
) async {
    let interrupt = ChatInterruptState()
    signal(SIGINT, SIG_IGN)
    let signalQueue = DispatchQueue(label: "com.runeweaver.chat-sigint")
    let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: signalQueue)
    signalSource.setEventHandler { interrupt.trip() }
    signalSource.resume()
    defer {
        signalSource.cancel()
        signal(SIGINT, SIG_DFL)
    }

    while !interrupt.isTripped {
        print(TerminalStyle.user("you> "), terminator: "")
        fflush(stdout)
        guard let line = readLine(strippingNewline: true) else {
            break
        }
        if interrupt.isTripped {
            break
        }
        let input = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.isEmpty {
            continue
        }
        if let action = await handleSlashCommand(input, conversations: conversations, sessionID: sessionID) {
            if action == .quit {
                break
            }
            continue
        }
        await conversations.append(Message(role: .user, content: input), to: sessionID)
        await runAssistantTurn(
            provider: provider,
            conversations: conversations,
            toolBus: toolBus,
            sessionID: sessionID,
            systemPrompt: systemPrompt,
            maxToolIterations: maxToolIterations
        )
    }
    print(TerminalStyle.dim("Chat session closed. Session \(sessionID.uuidString) ended."))
}

/// REPL slash-command outcome.
private enum REPLAction {
    /// Keep the loop running.
    case keepGoing
    /// Exit the loop gracefully.
    case quit
}

/// Handles `/`-prefixed REPL commands.
/// - Parameters:
///   - input: Raw trimmed user input.
///   - conversations: Session and history owner.
///   - sessionID: Current session identifier.
/// - Returns: The loop action, or nil when `input` is not a command.
private func handleSlashCommand(
    _ input: String,
    conversations: ConversationManager,
    sessionID: UUID
) async -> REPLAction? {
    guard input.hasPrefix("/") else { return nil }
    switch input.lowercased() {
    case "/exit", "/quit":
        return .quit
    case "/help":
        print(TerminalStyle.dim("Commands: /help, /clear, /session, /exit"))
        return .keepGoing
    case "/clear":
        await conversations.clear(sessionID: sessionID)
        print(TerminalStyle.dim("Conversation cleared."))
        return .keepGoing
    case "/session":
        print(TerminalStyle.dim("Session \(sessionID.uuidString)"))
        return .keepGoing
    default:
        print(TerminalStyle.dim("Unknown command '\(input)'. Try /help."))
        return .keepGoing
    }
}

/// Builds the working history with the system prompt first.
///
/// Shared dedup with the orchestrator via `Array.withSystemPrompt(_:)`:
/// an identical leading system message is kept, a stale one is replaced,
/// and prompts are never stacked.
/// - Parameters:
///   - conversations: Session and history owner.
///   - sessionID: Session identifier.
///   - systemPrompt: Developer instructions, if any.
/// - Returns: Messages for the next LLM call.
private func chatWorkingHistory(
    conversations: ConversationManager,
    sessionID: UUID,
    systemPrompt: String?
) async -> [Message] {
    let history = await conversations.history(for: sessionID)
    return history.withSystemPrompt(systemPrompt)
}

/// Runs one assistant turn, dispatching to the chunk or text path.
/// - Parameters:
///   - provider: Active LLM backend.
///   - conversations: Session and history owner.
///   - toolBus: Tool registry for model-requested calls.
///   - sessionID: Session identifier.
///   - systemPrompt: Developer instructions, if any.
///   - maxToolIterations: Maximum tool-call rounds.
private func runAssistantTurn(
    provider: any LLMProvider,
    conversations: ConversationManager,
    toolBus: ToolBus,
    sessionID: UUID,
    systemPrompt: String?,
    maxToolIterations: Int
) async {
    if let chunked = provider as? any ChunkStreamingProvider {
        await runChunkedTurn(
            provider: chunked,
            conversations: conversations,
            toolBus: toolBus,
            sessionID: sessionID,
            systemPrompt: systemPrompt,
            maxToolIterations: maxToolIterations
        )
    } else {
        await runTextTurn(
            provider: provider,
            conversations: conversations,
            toolBus: toolBus,
            sessionID: sessionID,
            systemPrompt: systemPrompt
        )
    }
}

/// Runs one assistant turn via chunk streaming with tool-call visibility.
///
/// Text deltas print as they arrive (typewriter effect); model-requested
/// tool calls print in yellow, execute via the bus, and show their results
/// inline before the next LLM round.
/// - Parameters:
///   - provider: Chunk-streaming LLM backend.
///   - conversations: Session and history owner.
///   - toolBus: Tool registry for model-requested calls.
///   - sessionID: Session identifier.
///   - systemPrompt: Developer instructions, if any.
///   - maxToolIterations: Maximum tool-call rounds before giving up.
private func runChunkedTurn(
    provider: any ChunkStreamingProvider,
    conversations: ConversationManager,
    toolBus: ToolBus,
    sessionID: UUID,
    systemPrompt: String?,
    maxToolIterations: Int
) async {
    let tools = await toolBus.availableTools()
    let definitions = tools.map { ToolDefinition($0) }
    var rounds = 0
    while rounds < maxToolIterations {
        rounds += 1
        let history = await chatWorkingHistory(
            conversations: conversations,
            sessionID: sessionID,
            systemPrompt: systemPrompt
        )
        print(TerminalStyle.assistant("weaver> "), terminator: "")
        var text = ""
        var calls: [ToolCall] = []
        var streamError: String?
        var usage: TokenUsage?
        var model = ""
        for await chunk in provider.chatChunks(messages: history, tools: definitions) {
            switch chunk {
            case let .textDelta(delta):
                text += delta
                print(delta, terminator: "")
                fflush(stdout)
            case let .toolCall(call):
                calls.append(call)
            case let .done(meta):
                model = meta.model
                usage = meta.usage
            case let .error(message):
                streamError = message
            }
        }
        print("")
        if let streamError {
            print(TerminalStyle.error("Request failed: \(streamError)"))
            return
        }
        if let usage {
            let label = model.isEmpty ? "" : "\(model) · "
            print(TerminalStyle.dim("(\(label)\(usage.totalTokens) tokens)"))
        }
        if calls.isEmpty {
            await conversations.append(Message(role: .assistant, content: text), to: sessionID)
            return
        }
        let note = text.isEmpty
            ? "Calling \(calls.map(\.name).joined(separator: ", "))…"
            : text
        await conversations.append(Message(role: .assistant, content: note), to: sessionID)
        for call in calls {
            print(TerminalStyle.tool("◈ calling \(call.name) \(cliInline(call.argumentsJSON, limit: 160))"))
            let result = await toolBus.execute(
                toolCall: ToolInput(toolName: call.name, argumentsJSON: call.argumentsJSON, callID: call.id),
                context: ToolContext(conversationID: sessionID)
            )
            let marker = result.isError ? "✕" : "→"
            print(TerminalStyle.dim("  \(marker) \(cliInline(result.content))"))
            await conversations.append(result.asMessage(), to: sessionID)
        }
    }
    print(TerminalStyle.error("Tool loop exceeded \(maxToolIterations) rounds; stopping."))
}

/// Runs one assistant turn via the text-only stream (no tool visibility).
/// - Parameters:
///   - provider: Active LLM backend.
///   - conversations: Session and history owner.
///   - toolBus: Tool registry (used for history context).
///   - sessionID: Session identifier.
///   - systemPrompt: Developer instructions, if any.
private func runTextTurn(
    provider: any LLMProvider,
    conversations: ConversationManager,
    toolBus: ToolBus,
    sessionID: UUID,
    systemPrompt: String?
) async {
    let tools = await toolBus.availableTools()
    let history = await chatWorkingHistory(
        conversations: conversations,
        sessionID: sessionID,
        systemPrompt: systemPrompt
    )
    print(TerminalStyle.assistant("weaver> "), terminator: "")
    var text = ""
    for await part in provider.chat(messages: history, tools: tools) {
        if !part.delta.isEmpty {
            text += part.delta
            print(part.delta, terminator: "")
            fflush(stdout)
        }
        if part.isFinished {
            break
        }
    }
    print("")
    await conversations.append(Message(role: .assistant, content: text), to: sessionID)
}

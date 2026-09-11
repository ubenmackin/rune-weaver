import ArgumentParser
import Foundation
import RuneWeaverCore
import RuneWeaverLLM

/// Cooperative SIGINT state for the chat REPL.
///
/// Tripped by the `SIGINT` dispatch source and polled by the REPL loop.
/// State lives in the shared `CLILockedValue` box so every access runs
/// inside `withLock`, keeping it data-race free under Swift 6
/// concurrency without manual lock handling.
private final class ChatInterruptState: Sendable {
    /// Lock-guarded delivery flag.
    private let flag = CLILockedValue(false)

    /// Records SIGINT delivery.
    func trip() {
        flag.withLock { $0 = true }
    }

    /// Whether SIGINT has been delivered.
    var isTripped: Bool {
        flag.withLock { $0 }
    }
}

/// Centralized SIGINT installation shared by chat REPL sessions.
///
/// Installs the ignore plus dispatch-source handler once and restores
/// the prior handler when the last session exits, so concurrent REPLs
/// never race on the global signal disposition. Every registered state
/// is tripped on SIGINT; sessions unregister on exit.
/// - Note: All mutable state below is guarded by `lock`, and every
///   critical section uses `defer`-guarded unlock, which justifies
///   `@unchecked Sendable`: no mutable state is ever accessed without
///   holding the lock.
private final class ChatSignalManager: @unchecked Sendable {
    /// Shared installation for the process.
    static let shared = ChatSignalManager()

    /// Guards installation state below.
    private let lock = NSLock()
    /// Prior handler to restore when the last session exits.
    private var previousHandler: (@convention(c) (Int32) -> Void)?
    /// Whether a prior handler is stored.
    private var hasPreviousHandler = false
    /// Active dispatch source while installed.
    private var source: DispatchSourceSignal?
    /// States tripped on SIGINT.
    private var states: [ChatInterruptState] = []
    /// Serial queue owning the signal source.
    private let queue = DispatchQueue(label: "com.runeweaver.chat-sigint")

    /// Snapshot captured under lock for deferred signal restoration.
    ///
    /// Replaces a three-member tuple so the uninstall path stays within
    /// the `large_tuple` lint budget without splitting the locked
    /// critical section.
    private struct SignalRestorePlan {
        /// Whether the source was torn down and the prior handler needs restoring.
        let shouldRestore: Bool
        /// Prior handler captured at install time.
        let previous: (@convention(c) (Int32) -> Void)?
        /// Whether a prior handler was captured.
        let hadPrevious: Bool
    }

    /// Registers a REPL state, installing the handler on first use.
    /// - Parameter state: REPL interrupt flag to trip on SIGINT.
    func install(_ state: ChatInterruptState) {
        let shouldInstall: Bool = {
            lock.lock()
            defer { lock.unlock() }
            states.append(state)
            return source == nil
        }()
        guard shouldInstall else { return }
        lock.lock()
        defer { lock.unlock() }
        // Re-check under the lock so two concurrent installs only install once.
        guard source == nil else { return }
        previousHandler = signal(SIGINT, SIG_IGN)
        hasPreviousHandler = true
        let created = DispatchSource.makeSignalSource(signal: SIGINT, queue: queue)
        created.setEventHandler { [weak self] in self?.tripAll() }
        created.resume()
        source = created
    }

    /// Unregisters a REPL state, restoring the prior handler when last exits.
    /// - Parameter state: REPL interrupt flag to remove.
    func uninstall(_ state: ChatInterruptState) {
        let plan: SignalRestorePlan = {
            lock.lock()
            defer { lock.unlock() }
            states.removeAll { $0 === state }
            let shouldRestore = states.isEmpty && source != nil
            let previous = previousHandler
            let hadPrevious = hasPreviousHandler
            if shouldRestore {
                source?.cancel()
                source = nil
                previousHandler = nil
                hasPreviousHandler = false
            }
            return SignalRestorePlan(shouldRestore: shouldRestore, previous: previous, hadPrevious: hadPrevious)
        }()
        if plan.shouldRestore, plan.hadPrevious {
            signal(SIGINT, plan.previous ?? SIG_DFL)
        }
    }

    /// Trips every registered REPL state.
    private func tripAll() {
        let snapshot: [ChatInterruptState] = {
            lock.lock()
            defer { lock.unlock() }
            return states
        }()
        for state in snapshot {
            state.trip()
        }
    }
}

/// Exactly-once resume state for a blocking standard-input read.
///
/// Blocking `readLine` cannot be cancelled mid-read, so both the
/// background completion and task cancellation race to resume. The
/// locked flag guarantees the continuation resumes exactly once: a
/// cancelled REPL unblocks promptly with nil while the late background
/// read is ignored, and a completed read wins when it finishes first.
/// All state is guarded by `lock` with `defer`-guarded unlock.
private final class StdinReadState: @unchecked Sendable {
    /// Guards resume state below.
    private let lock = NSLock()
    /// Whether the continuation has resumed.
    private var didResume = false
    /// Pending continuation awaiting the background read.
    private var continuation: CheckedContinuation<String?, Never>?

    /// Stores the continuation awaiting the background read.
    ///
    /// When cancellation already won the race, resumes immediately with
    /// nil so the waiter never hangs on a stored-but-never-resumed
    /// continuation.
    /// - Parameter continuation: Continuation to resume exactly once.
    func set(_ continuation: CheckedContinuation<String?, Never>) {
        let alreadyResumed: Bool = {
            lock.lock()
            defer { lock.unlock() }
            if didResume {
                return true
            }
            self.continuation = continuation
            return false
        }()
        if alreadyResumed {
            continuation.resume(returning: nil)
        }
    }

    /// Resumes exactly once, ignoring late racers.
    /// - Parameter value: Line without the newline, or nil on EOF or cancellation.
    func resume(returning value: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return }
        didResume = true
        continuation?.resume(returning: value)
        continuation = nil
    }
}

/// Reads one line from standard input without blocking the cooperative pool.
///
/// Dispatches blocking `readLine` to a background queue and suspends
/// until input arrives, so async REPL and approval paths never block
/// the executor. Task cancellation resumes with nil exactly once via
/// `StdinReadState` so a cancelled REPL unblocks promptly while the
/// late background read is ignored; the background completion path is
/// the only other resumer.
/// - Returns: The line without the newline, or nil on EOF or cancellation.
private func readStdinLine() async -> String? {
    let state = StdinReadState()
    return await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
            state.set(continuation)
            DispatchQueue.global(qos: .userInitiated).async {
                state.resume(returning: readLine(strippingNewline: true))
            }
        }
    } onCancel: {
        state.resume(returning: nil)
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

    /// Maximum tool-call rounds per assistant turn, plus one final synthesis turn.
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
        let memoryEngine = CLIShared.memoryEngine(for: loaded.config.memory)
        var active = selected
        // Tag cloud requests with the chat session when the backend supports it.
        // Local providers never send the session header, so they are left untouched.
        if var sessioned = active as? OpenAICompatibleProvider {
            sessioned.sessionID = sessionID.uuidString
            active = sessioned
        }
        // Working memory (ConversationManager sessions/messages tables) is the
        // live source of truth; episodic storage (MemoryEngine episodes tables)
        // in the same file is the durable mirror. Hydration flows one way,
        // episodic into working, only for fresh sessions so `/clear` (which
        // clears both stores) never resurrects cleared history on resume.
        let conversations = ConversationManager(episodesDBPath: loaded.config.memory.episodesDBPath)
        do {
            try await conversations.loadAll()
        } catch {
            cliPrintError(TerminalStyle.dim("Could not load conversation history; starting fresh."))
        }
        let hadPersistedSession = await conversations.session(id: sessionID) != nil
        await conversations.ensureSession(id: sessionID)
        if await conversations.messageCount(for: sessionID) == 0, !hadPersistedSession {
            do {
                let limit = await conversations.maxMessages
                let episodes = try await memoryEngine.recentEpisodes(for: sessionID, limit: limit)
                if !episodes.isEmpty {
                    await conversations.setHistory(episodes.map { $0.asMessage() }, for: sessionID)
                }
            } catch {
                cliPrintError(TerminalStyle.dim("Could not load episodic history; starting fresh."))
            }
        }
        let permissionGate = PermissionGate()
        let toolBus = await CLIShared.makeToolBus(permissionGate: permissionGate)
        await toolBus.setApprovalHandler { tool, call in
            print(TerminalStyle.tool("Tool '\(call.toolName)' requires approval."))
            print(TerminalStyle.dim("  [1] Only this time  [2] Next 5 minutes  [3] Next hour  [4] Next day  [5] Forever  [N] Deny (default)"))
            print(TerminalStyle.tool("  Allow? "), terminator: "")
            fflush(stdout)
            let answer = await readStdinLine()
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
        let context = ChatTurnContext(
            conversations: conversations,
            toolBus: toolBus,
            sessionID: sessionID,
            systemPrompt: systemPrompt,
            maxToolIterations: max(1, maxToolIterations),
            memoryEngine: memoryEngine
        )
        await runChatREPL(
            provider: active,
            context: context
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

/// Shared dependencies for one chat REPL session.
///
/// Bundles the REPL collaborators so turn helpers stay within the
/// parameter budget while keeping call sites readable.
private struct ChatTurnContext: Sendable {
    /// Session and history owner.
    let conversations: ConversationManager
    /// Tool registry consulted for model-requested calls.
    let toolBus: ToolBus
    /// Session identifier for this REPL.
    let sessionID: UUID
    /// Developer instructions prepended to every turn.
    let systemPrompt: String?
    /// Maximum tool-call rounds per assistant turn, plus one final synthesis turn.
    let maxToolIterations: Int
    /// Shared engine receiving one episode per turn.
    let memoryEngine: MemoryEngine
}

/// Runs the read-eval-print loop until EOF, `/exit`, or SIGINT.
///
/// SIGINT is observed via the shared `ChatSignalManager` (block-based
/// dispatch source, no C handler globals) tripping a lock-boxed flag
/// polled by the loop, which is data-race free under Swift 6
/// concurrency. Installation is reference-counted and restores the
/// prior handler when the last session exits. Standard-input reads
/// suspend on a background queue via `readStdinLine()` so the
/// cooperative pool is never blocked.
/// - Parameters:
///   - provider: Active LLM backend serving completions.
///   - context: Shared REPL dependencies for this session.
private func runChatREPL(
    provider: any LLMProvider,
    context: ChatTurnContext
) async {
    let interrupt = ChatInterruptState()
    ChatSignalManager.shared.install(interrupt)
    defer {
        ChatSignalManager.shared.uninstall(interrupt)
    }

    while !interrupt.isTripped {
        print(TerminalStyle.user("you> "), terminator: "")
        fflush(stdout)
        guard let line = await readStdinLine() else {
            break
        }
        if interrupt.isTripped {
            break
        }
        let input = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.isEmpty {
            continue
        }
        if let action = await handleSlashCommand(
            input,
            conversations: context.conversations,
            sessionID: context.sessionID,
            memoryEngine: context.memoryEngine
        ) {
            if action == .quit {
                break
            }
            continue
        }
        if let fact = MemoryEngine.rememberFactText(from: input) {
            await appendUserAndHandleRemember(
                input: input,
                fact: fact,
                conversations: context.conversations,
                sessionID: context.sessionID,
                engine: context.memoryEngine
            )
            continue
        }
        await context.conversations.append(Message(role: .user, content: input), to: context.sessionID)
        await context.memoryEngine.mirrorTurn(
            content: input,
            sessionID: context.sessionID,
            role: .user,
            failurePolicy: .report,
            onFailure: chatMirrorFailureHandler
        )
        await runAssistantTurn(
            provider: provider,
            context: context
        )
    }
    print(TerminalStyle.dim("Chat session closed. Session \(context.sessionID.uuidString) ended."))
}

/// Reports episodic mirror failures as a dim warning on standard error.
///
/// Single handler passed with `.report` to the shared
/// `MemoryEngine.mirrorTurn(_:...)` helper so the failure message stays
/// single-sourced in `RuneWeaverCore`.
private let chatMirrorFailureHandler: @Sendable (String) -> Void = { message in
    cliPrintError(TerminalStyle.dim(message))
}

/// Stores an explicit remember request and acknowledges it.
///
/// Shares acknowledgement text with the orchestrator via
/// `MemoryEngine.rememberAcknowledgementText(for:stored:)` so every caller
/// stores the same assistant turn. The acknowledgement is recorded in
/// working memory and mirrored to episodic memory like any other turn;
/// empty or punctuation-only facts print usage after the turn is mirrored,
/// and storage failures print a dim note without touching the LLM path.
/// - Parameters:
///   - fact: Stripped fact text.
///   - engine: Shared memory engine for the session.
///   - conversations: Session and history owner.
///   - sessionID: Current session identifier.
private func chatStoreRememberedFact(
    _ fact: String,
    engine: MemoryEngine,
    conversations: ConversationManager,
    sessionID: UUID
) async {
    let storable = MemoryEngine.isStorableFact(fact)
    let stored = storable ? await engine.storeRememberedFact(content: fact, source: "chat") : false
    let acknowledgement = MemoryEngine.rememberAcknowledgementText(for: fact, stored: stored)
    await conversations.append(Message(role: .assistant, content: acknowledgement), to: sessionID)
    await engine.mirrorTurn(
        content: acknowledgement,
        sessionID: sessionID,
        role: .assistant,
        failurePolicy: .report,
        onFailure: chatMirrorFailureHandler
    )
    if stored || !storable {
        print(TerminalStyle.dim(acknowledgement))
    } else {
        cliPrintError(TerminalStyle.dim(acknowledgement))
    }
}

/// Appends a remember request to working memory and stores the fact.
///
/// Shared by the REPL and slash-command paths so `remember` and
/// `/remember` behave identically. Every turn is recorded in working
/// and episodic memory, including the acknowledgement assistant turn;
/// empty or punctuation-only requests still print usage after both turns
/// are mirrored.
/// - Parameters:
///   - input: Raw user input preserved as the working-memory turn.
///   - fact: Stripped fact text from the remember parser.
///   - conversations: Session and history owner.
///   - sessionID: Current session identifier.
///   - engine: Shared engine for episodic and fact storage.
private func appendUserAndHandleRemember(
    input: String,
    fact: String,
    conversations: ConversationManager,
    sessionID: UUID,
    engine: MemoryEngine
) async {
    await conversations.append(Message(role: .user, content: input), to: sessionID)
    await engine.mirrorTurn(
        content: input,
        sessionID: sessionID,
        role: .user,
        failurePolicy: .report,
        onFailure: chatMirrorFailureHandler
    )
    await chatStoreRememberedFact(fact, engine: engine, conversations: conversations, sessionID: sessionID)
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
///   - memoryEngine: Shared engine for `/remember` captures.
/// - Returns: The loop action, or nil when `input` is not a command.
private func handleSlashCommand(
    _ input: String,
    conversations: ConversationManager,
    sessionID: UUID,
    memoryEngine: MemoryEngine
) async -> REPLAction? {
    if input.hasPrefix("/"), let fact = MemoryEngine.rememberFactText(from: input) {
        await appendUserAndHandleRemember(
            input: input,
            fact: fact,
            conversations: conversations,
            sessionID: sessionID,
            engine: memoryEngine
        )
        return .keepGoing
    }
    guard input.hasPrefix("/") else { return nil }
    let lower = input.lowercased()
    switch lower {
    case "/exit", "/quit":
        return .quit
    case "/help":
        print(TerminalStyle.dim("Commands: /help, /clear, /session, /remember <fact>, /exit"))
        return .keepGoing
    case "/clear":
        await conversations.clear(sessionID: sessionID)
        do {
            try await memoryEngine.deleteSession(sessionID)
        } catch {
            cliPrintError(TerminalStyle.dim("Could not clear episodic history; continuing."))
        }
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

/// Runs one assistant turn, dispatching to the chunk or text path.
/// - Parameters:
///   - provider: Active LLM backend.
///   - context: Shared REPL dependencies for this session.
private func runAssistantTurn(
    provider: any LLMProvider,
    context: ChatTurnContext
) async {
    if let chunked = provider as? any ChunkStreamingProvider {
        await runChunkedTurn(
            provider: chunked,
            context: context
        )
    } else {
        await runTextTurn(
            provider: provider,
            context: context
        )
    }
}

/// Runs one assistant turn via chunk streaming with tool-call visibility.
///
/// Text deltas print as they arrive (typewriter effect); model-requested
/// tool calls print in yellow, execute via the bus, and show their results
/// inline before the next LLM round. Up to `maxToolIterations` tool rounds
/// run, followed by one final synthesis turn so the last tool results are
/// always answered; when the synthesis turn still requests tools the loop
/// stops with an exceeded notice without executing the extra calls. The
/// assistant turn is always recorded, using the shared
/// `OrchestratorToolLoop.assistantNoteContent(text:calls:)` policy
/// (truncated arguments, name, and call identifier) when the model sends
/// tool calls without text, so tool results keep their parent. Empty tool
/// results skip only the episodic mirror via the shared
/// `OrchestratorToolLoop` policy so hydrated history matches live history
/// and keyword search stays free of empty turns.
/// - Parameters:
///   - provider: Chunk-streaming LLM backend.
///   - context: Shared REPL dependencies for this session.
private func runChunkedTurn(
    provider: any ChunkStreamingProvider,
    context: ChatTurnContext
) async {
    let tools = await context.toolBus.availableTools()
    let definitions = tools.map { ToolDefinition($0) }
    var toolRounds = 0
    while true {
        let history = await context.conversations.workingHistory(
            for: context.sessionID,
            systemPrompt: context.systemPrompt
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
            guard OrchestratorToolLoop.shouldStoreAssistantText(text) else { return }
            await context.conversations.append(Message(role: .assistant, content: text), to: context.sessionID)
            await context.memoryEngine.mirrorTurn(
                content: text,
                sessionID: context.sessionID,
                role: .assistant,
                failurePolicy: .report,
                onFailure: chatMirrorFailureHandler
            )
            return
        }
        toolRounds += 1
        if OrchestratorToolLoop.isLimitExceeded(rounds: toolRounds, max: context.maxToolIterations) {
            print(TerminalStyle.error("Tool loop exceeded \(context.maxToolIterations) rounds; stopping."))
            return
        }
        let inputs = calls.map { ToolInput(toolName: $0.name, argumentsJSON: $0.argumentsJSON, callID: $0.id) }
        let assistantContent = OrchestratorToolLoop.assistantNoteContent(text: text, calls: inputs)
        await context.conversations.append(Message(role: .assistant, content: assistantContent), to: context.sessionID)
        await context.memoryEngine.mirrorTurn(
            content: assistantContent,
            sessionID: context.sessionID,
            role: .assistant,
            failurePolicy: .report,
            onFailure: chatMirrorFailureHandler
        )
        for call in calls {
            print(TerminalStyle.tool("◈ calling \(call.name) \(cliInline(call.argumentsJSON, limit: 160))"))
            let result = await context.toolBus.execute(
                toolCall: ToolInput(toolName: call.name, argumentsJSON: call.argumentsJSON, callID: call.id),
                context: ToolContext(conversationID: context.sessionID)
            )
            let marker = result.isError ? "✕" : "→"
            print(TerminalStyle.dim("  \(marker) \(cliInline(result.content, limit: 300))"))
            await context.conversations.append(result.asMessage(), to: context.sessionID)
            if OrchestratorToolLoop.shouldStoreToolResult(result.content) {
                await context.memoryEngine.mirrorTurn(
                    content: result.content,
                    sessionID: context.sessionID,
                    role: .tool,
                    toolCallID: result.toolCallID,
                    failurePolicy: .report,
                    onFailure: chatMirrorFailureHandler
                )
            }
        }
    }
}

/// Runs one assistant turn via the text-only stream (no tool visibility).
///
/// The text-only `LLMProvider.chat` stream carries no tool calls, so this
/// path cannot resolve or execute tools via the shared resolver. When tools
/// are registered an explicit warning is emitted that tools are disabled in
/// the text path; use a `ChunkStreamingProvider` backend for full tool
/// support. Storage decisions delegate to the shared
/// `OrchestratorToolLoop` policy like every other loop.
/// - Parameters:
///   - provider: Active LLM backend.
///   - context: Shared REPL dependencies for this session.
private func runTextTurn(
    provider: any LLMProvider,
    context: ChatTurnContext
) async {
    let tools = await context.toolBus.availableTools()
    if !tools.isEmpty {
        print(TerminalStyle.dim("Tools are disabled in the text-only path (\(tools.count) available); continuing without tool calls."))
    }
    let history = await context.conversations.workingHistory(
        for: context.sessionID,
        systemPrompt: context.systemPrompt
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
    guard OrchestratorToolLoop.shouldStoreAssistantText(text) else { return }
    await context.conversations.append(Message(role: .assistant, content: text), to: context.sessionID)
    await context.memoryEngine.mirrorTurn(
        content: text,
        sessionID: context.sessionID,
        role: .assistant,
        failurePolicy: .report,
        onFailure: chatMirrorFailureHandler
    )
}

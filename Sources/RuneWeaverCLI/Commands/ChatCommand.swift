// Rune Weaver CLI — Interactive chat session and REPL command.

import ArgumentParser
import Foundation
import os
import RuneWeaverCore
import RuneWeaverLLM
import RuneWeaverTools

/// Cooperative SIGINT state for the chat REPL.
final class ChatInterruptState: Sendable {
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

    /// Clears a delivered SIGINT so the next prompt starts clean.
    func reset() {
        flag.withLock { $0 = false }
    }

    /// Atomically checks and clears a delivered SIGINT.
    /// - Returns: True when SIGINT had been delivered.
    func consume() -> Bool {
        flag.withLock { value in
            let wasTripped = value
            value = false
            return wasTripped
        }
    }
}

/// Outcome of one assistant turn.
enum ChatTurnOutcome: Sendable, Equatable {
    /// The turn finished and persisted normally.
    case completed
    /// SIGINT tripped mid-turn; partial output was discarded.
    case cancelled
}

/// Cooperative cancellation policy for assistant turns.
enum ChatTurnInterrupt {
    /// Whether the shared SIGINT flag has been delivered.
    /// - Parameter interrupt: Shared SIGINT flag.
    /// - Returns: True when SIGINT was delivered.
    static func isCancelled(_ interrupt: ChatInterruptState) -> Bool {
        interrupt.isTripped
    }

    /// Consumes a turn cancellation so the next prompt starts clean.
    /// - Parameter interrupt: Shared SIGINT flag.
    /// - Returns: True when a cancellation was consumed.
    static func consumeTurnCancellation(_ interrupt: ChatInterruptState) -> Bool {
        interrupt.consume()
    }
}

/// Centralized SIGINT installation shared by chat REPL sessions.
private final class ChatSignalManager: Sendable {
    /// Shared installation for the process.
    static let shared = ChatSignalManager()

    private struct State: Sendable {
        var previousHandler: (@convention(c) (Int32) -> Void)?
        var hasPreviousHandler = false
        var source: (any DispatchSourceSignal)?
        var states: [ChatInterruptState] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Serial queue owning the signal source.
    private let queue = DispatchQueue(label: "com.runeweaver.chat-sigint")

    /// Snapshot captured under lock for deferred signal restoration.
    private struct SignalRestorePlan {
        /// Whether the source was torn down and the prior handler needs restoring.
        let shouldRestore: Bool
        /// Prior handler captured at install time.
        let previous: (@convention(c) (Int32) -> Void)?
        /// Whether a prior handler was captured.
        let hadPrevious: Bool
    }

    /// Registers a REPL state, installing the handler on first use.
    /// - Parameter interruptState: REPL interrupt flag to trip on SIGINT.
    func install(_ interruptState: ChatInterruptState) {
        let shouldInstall = state.withLock { managerState -> Bool in
            managerState.states.append(interruptState)
            return managerState.source == nil
        }
        guard shouldInstall else { return }

        let createdSource = state.withLock { managerState -> (any DispatchSourceSignal)? in
            guard managerState.source == nil else { return nil }
            managerState.previousHandler = signal(SIGINT, SIG_IGN)
            managerState.hasPreviousHandler = true
            let created = DispatchSource.makeSignalSource(signal: SIGINT, queue: queue)
            managerState.source = created
            return created
        }
        if let created = createdSource {
            created.setEventHandler { [weak self] in self?.tripAll() }
            created.resume()
        }
    }

    /// Unregisters a REPL state, restoring the prior handler when last exits.
    /// - Parameter interruptState: REPL interrupt flag to remove.
    func uninstall(_ interruptState: ChatInterruptState) {
        let (plan, sourceToCancel) = state.withLock { managerState -> (SignalRestorePlan, (any DispatchSourceSignal)?) in
            managerState.states.removeAll { $0 === interruptState }
            let shouldRestore = managerState.states.isEmpty && managerState.source != nil
            let previous = managerState.previousHandler
            let hadPrevious = managerState.hasPreviousHandler
            let src = managerState.source
            if shouldRestore {
                managerState.source = nil
                managerState.previousHandler = nil
                managerState.hasPreviousHandler = false
            }
            return (SignalRestorePlan(shouldRestore: shouldRestore, previous: previous, hadPrevious: hadPrevious), shouldRestore ? src : nil)
        }
        sourceToCancel?.cancel()
        if plan.shouldRestore, plan.hadPrevious {
            signal(SIGINT, plan.previous ?? SIG_DFL)
        }
    }

    /// Trips every registered REPL state.
    private func tripAll() {
        let snapshot = state.withLock { $0.states }
        for interruptState in snapshot {
            interruptState.trip()
        }
    }
}

/// Maps a REPL answer to a graduated-trust tier.
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
        // in the same file is the durable mirror.
        let conversations = await initializeConversations(
            sessionID: sessionID,
            memoryConfig: loaded.config.memory,
            memoryEngine: memoryEngine
        )
        // Email search/read are `readOnly` and memory tools are `trusted` per the owner memory-
        // write trust ruling, so both bypass the approval handler by design (see
        // `ToolBus.execute`): the handler below only fires for `requiresApproval` tools (including...
        let embedder = EmbeddingsBackendFactory.makeBackend(
            memoryEmbeddingBackend: loaded.config.memory.embeddingBackend,
            router: LLMRouter(providers: providers)
        )
        let episodesDB = (loaded.config.memory.episodesDBPath as NSString).expandingTildeInPath
        let trustStore = SQLiteTrustStore(dbPath: episodesDB)
        let permissionGate = await PermissionGate.load(
            store: trustStore,
            pluginsDir: URL(fileURLWithPath: (loaded.config.plugins.pluginsDir as NSString).expandingTildeInPath)
        )
        // Prune expired trust grants during the session so expired rows do
        // not linger for the life of the REPL; stopped explicitly on exit.
        await permissionGate.startPeriodicCleanup()
        let toolBus = await CLIShared.makeToolBus(
            emailConfig: loaded.config.email,
            memoryEngine: memoryEngine,
            permissionGate: permissionGate,
            sandboxConfig: loaded.config.sandbox,
            embedder: embedder,
            pluginConfig: loaded.config.plugins,
            episodesDBPath: loaded.config.memory.episodesDBPath,
            browserConfig: loaded.config.browser,
            llmConfig: loaded.config.llm
        )
        await toolBus.setApprovalHandler { tool, call in
            print(TerminalStyle.tool("Tool '\(call.toolName)' requires approval."))
            print(TerminalStyle.dim("  [1] Only this time  [2] Next 5 minutes  [3] Next hour  [4] Next day  [5] Forever  [N] Deny (default)"))
            // Approval reads go through the line editor like the main
            // prompt so arrow keys edit instead of echoing escape codes.
            let answer = await ChatLineEditing.readLine(prompt: TerminalStyle.tool("  Allow? "))
            guard let duration = chatTrustDuration(for: answer) else {
                return false
            }
            if duration != .thisTime {
                let descriptor = ActionDescriptor.descriptor(for: call, tool: tool)
                await permissionGate.grantTrust(for: descriptor, duration: duration)
            }
            return true
        }
        let startupTools = await toolBus.toolNames().sorted()
        if startupTools.isEmpty {
            print(TerminalStyle.dim("No plugin tools registered; continuing without tool calls."))
        } else {
            print(TerminalStyle.dim("Tools: \(startupTools.joined(separator: ", "))."))
        }
        // Verified-live email accounts print here so the user knows which
        // nickname to name in prompts (e.g. "on volcrypt" or "on icloud"). Only
        // non-sensitive fields print; passwords never appear.
        let startupEmailAccounts = loaded.config.email.accounts.sorted(by: { $0.name < $1.name })
        if !startupEmailAccounts.isEmpty {
            let summary = startupEmailAccounts.map { "\($0.name) (\($0.username)@\($0.host):\($0.port))" }
                .joined(separator: ", ")
            print(TerminalStyle.dim("Email accounts: \(summary)."))
        }

        print(TerminalStyle.dim("Connected to \(active.name) (\(active.modelInfo.name)). Session \(sessionID.uuidString)."))
        print(TerminalStyle.dim("Type /help for commands, /exit to quit. Ctrl+C shuts down gracefully."))
        try await warmSearchEngine(browser: loaded.config.browser)
        // Default system prompt is composed from the live registry so the
        // model sees every registered tool; an explicit --system-prompt
        // still overrides it verbatim via SystemPromptComposer.resolve.
        let effectiveSystemPrompt = await SystemPromptComposer.resolve(flag: systemPrompt, toolBus: toolBus)
        let context = ChatTurnContext(
            conversations: conversations,
            toolBus: toolBus,
            sessionID: sessionID,
            systemPrompt: effectiveSystemPrompt,
            maxToolIterations: max(1, maxToolIterations),
            memoryEngine: memoryEngine,
            embedder: embedder,
            sessionTokens: CLILockedValue(0)
        )
        await runChatREPL(
            provider: active,
            context: context
        )
        await permissionGate.stopPeriodicCleanup()
    }

    /// Warms the local search engine on boot so first searches stay fast.
    private func warmSearchEngine(browser: BrowserConfig) async throws {
        do {
            try await SearXNGEnsurer.shared.ensure(browser: browser)
            print(TerminalStyle.dim("SearXNG ready at \(browser.searxngURL)."))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            print(TerminalStyle.dim("Search engine unavailable: \(error.localizedDescription)"))
        }
    }

    /// Parses `--session` into a UUID, starting fresh when omitted.
    private func resolveSessionID(_ raw: String?) throws -> UUID {
        guard let raw, !raw.isEmpty else { return UUID() }
        guard let id = UUID(uuidString: raw) else {
            throw ValidationError("--session must be a UUID (got '\(raw)').")
        }
        return id
    }

    /// Prepares and hydrates working conversation history from episodic storage.
    private func initializeConversations(
        sessionID: UUID,
        memoryConfig: MemoryConfig,
        memoryEngine: MemoryEngine
    ) async -> ConversationManager {
        let conversations = ConversationManager(episodesDBPath: memoryConfig.episodesDBPath)
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
                let replayable = MemoryEngine.hydrationMessages(from: episodes)
                if !replayable.isEmpty {
                    await conversations.setHistory(replayable, for: sessionID)
                }
            } catch {
                cliPrintError(TerminalStyle.dim("Could not load episodic history; starting fresh."))
            }
        }
        return conversations
    }
}

/// Shared dependencies for one chat REPL session.
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
    /// Optional embeddings producer for vector-ranked recall and tool writes.
    let embedder: (any EmbeddingsBackend)?
    /// Session-cumulative billed tokens rendered via `SessionTokenDisplay`.
    let sessionTokens: CLILockedValue<Int>
}

/// Builds the session trailer line for one assistant turn.
enum ChatSessionTrailer {
    /// Formats the trailer and advances the session counter when needed.
    static func line(
        modelName: String,
        sessionTokens: CLILockedValue<Int>,
        turnTotalTokens: Int?,
        window: Int
    ) -> String {
        let used = sessionTokens.withLock { value in
            if let turnTotalTokens {
                value += turnTotalTokens
            }
            return value
        }
        return SessionTokenDisplay.label(model: modelName, used: used, window: window)
    }
}

/// Runs the read-eval-print loop until EOF, `/exit`, or SIGINT at the prompt.
private func runChatREPL(
    provider: any LLMProvider,
    context: ChatTurnContext
) async {
    let interrupt = ChatInterruptState()
    ChatSignalManager.shared.install(interrupt)
    defer {
        ChatSignalManager.shared.uninstall(interrupt)
    }

    var history = ChatHistoryStore(fileURL: ChatHistoryStore.defaultHistoryFileURL())
    await history.loadAsync()
    ChatLineEditing.preload(history.entries)

    while !ChatTurnInterrupt.isCancelled(interrupt) {
        guard let line = await ChatLineEditing.readLine(prompt: TerminalStyle.user("you> ")) else {
            break
        }
        if ChatTurnInterrupt.isCancelled(interrupt) {
            break
        }
        let input = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.isEmpty {
            continue
        }
        if history.record(input) {
            ChatLineEditing.note(input)
            do {
                try await history.saveAsync()
            } catch {
                cliPrintError(TerminalStyle.dim("Could not save prompt history; continuing."))
            }
        }
        do {
            if let action = try await handleSlashCommand(
                input,
                conversations: context.conversations,
                sessionID: context.sessionID,
                memoryEngine: context.memoryEngine,
                sessionTokens: context.sessionTokens,
                toolBus: context.toolBus,
                embedder: context.embedder
            ) {
                if action == .quit {
                    break
                }
                continue
            }
            if let fact = MemoryEngine.rememberFactText(from: input) {
                try await appendUserAndHandleRemember(
                    input: input,
                    fact: fact,
                    conversations: context.conversations,
                    sessionID: context.sessionID,
                    engine: context.memoryEngine,
                    toolBus: context.toolBus,
                    embedder: context.embedder
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
            let outcome = try await runAssistantTurn(
                provider: provider,
                context: context,
                query: input,
                interrupt: interrupt
            )
            if outcome == .cancelled {
                // The turn already discarded its partial working-memory writes and printed its
                // cancellation notice. Consume the flag so the loop returns to the prompt within
                // the same interaction; a second SIGINT at the prompt still exits.
                interrupt.reset()
                continue
            }
        } catch is CancellationError {
            // Task cancellation aborts the turn rather than degrading to
            // no-memory or a downgraded remember; return to the prompt like a
            // SIGINT-cancelled turn.
            print(TerminalStyle.dim("Cancelled."))
            interrupt.reset()
            continue
        } catch {
            cliPrintError(TerminalStyle.dim("Request failed: \(error.localizedDescription)"))
            continue
        }
    }
    print(TerminalStyle.dim("Chat session closed. Session \(context.sessionID.uuidString) ended."))
}

/// Reports episodic mirror failures as a dim warning on standard error.
private let chatMirrorFailureHandler: @Sendable (String) -> Void = { message in
    cliPrintError(TerminalStyle.dim(message))
}

/// Stores an explicit remember request and acknowledges it.
private func chatStoreRememberedFact(
    _ fact: String,
    engine: MemoryEngine,
    conversations: ConversationManager,
    sessionID: UUID,
    toolBus: ToolBus,
    embedder: (any EmbeddingsBackend)? = nil
) async throws {
    let storable = MemoryEngine.isStorableFact(fact)
    let stored = storable ? try await engine.storeRememberedFact(content: fact, source: "chat", embedder: embedder) : false
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
    // Remember turns bypass the model but must stay honest about omitted tools:
    // surface the same degraded-tool notices as model turns so skips never go silent.
    for warning in await OrchestratorToolLoop.degradedToolWarnings(for: toolBus.availableTools()) {
        cliPrintError(warning)
    }
}

/// Appends a remember request to working memory and stores the fact.
private func appendUserAndHandleRemember(
    input: String,
    fact: String,
    conversations: ConversationManager,
    sessionID: UUID,
    engine: MemoryEngine,
    toolBus: ToolBus,
    embedder: (any EmbeddingsBackend)? = nil
) async throws {
    await conversations.append(Message(role: .user, content: input), to: sessionID)
    await engine.mirrorTurn(
        content: input,
        sessionID: sessionID,
        role: .user,
        failurePolicy: .report,
        onFailure: chatMirrorFailureHandler
    )
    try await chatStoreRememberedFact(fact, engine: engine, conversations: conversations, sessionID: sessionID, toolBus: toolBus, embedder: embedder)
}

/// REPL slash-command outcome.
private enum REPLAction {
    /// Keep the loop running.
    case keepGoing
    /// Exit the loop gracefully.
    case quit
}

/// Handles `/`-prefixed REPL commands.
private func handleSlashCommand(
    _ input: String,
    conversations: ConversationManager,
    sessionID: UUID,
    memoryEngine: MemoryEngine,
    sessionTokens: CLILockedValue<Int>,
    toolBus: ToolBus,
    embedder: (any EmbeddingsBackend)? = nil
) async throws -> REPLAction? {
    if input.hasPrefix("/"), let fact = MemoryEngine.rememberFactText(from: input) {
        try await appendUserAndHandleRemember(
            input: input,
            fact: fact,
            conversations: conversations,
            sessionID: sessionID,
            engine: memoryEngine,
            toolBus: toolBus,
            embedder: embedder
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
        print(TerminalStyle.dim("Email is read-only via chat: ask to find or summarize (e.g. find emails about quarterly report on volcrypt or icloud)."))
        return .keepGoing
    case "/clear":
        await conversations.clear(sessionID: sessionID)
        // The REPL tracks billed totals beside working memory rather than
        // inside the orchestrator map, so clearing history must also reset
        // the counter or the next trailer would bill the cleared turns.
        sessionTokens.withLock { $0 = 0 }
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
private func runAssistantTurn(
    provider: any LLMProvider,
    context: ChatTurnContext,
    query: String,
    interrupt: ChatInterruptState
) async throws -> ChatTurnOutcome {
    if let chunked = provider as? any ChunkStreamingProvider {
        try await runChunkedTurn(
            provider: chunked,
            context: context,
            query: query,
            interrupt: interrupt
        )
    } else {
        try await runTextTurn(
            provider: provider,
            context: context,
            query: query,
            interrupt: interrupt
        )
    }
}

// MARK: - Chunked turn helpers

/// Pre-turn snapshot plus tool-round budget for one chunked turn.
private struct ChunkedTurnProgress: Sendable {
    /// Working-memory snapshot restored on cancellation.
    let snapshot: [Message]
    /// Tool rounds run so far.
    var rounds: Int
}

/// Accumulated chunk-stream result for one LLM round.
private struct ChunkedTurnDraft: Sendable {
    /// Accumulated assistant text.
    var text: String
    /// Structured tool calls in stream order.
    var calls: [ToolCall]
    /// Billed usage when the backend reported it.
    var usage: TokenUsage?
    /// Serving model name when the stream reported it.
    var servedModel: String
    /// Terminal stream error, if any.
    var streamError: String?
}

/// Drains one chunk stream into a draft.
private func drainChunkedStream(
    provider: any ChunkStreamingProvider,
    definitions: [ToolDefinition],
    history: [Message],
    session: UUID?,
    interrupt: ChatInterruptState
) async -> ChunkedTurnDraft {
    var text = ""
    var calls: [ToolCall] = []
    var streamError: String?
    var usage: TokenUsage?
    var servedModel = ""
    // Pin the turn to the chat session so sticky-slot backends reuse the
    // cached prefix instead of falling back to server auto-assignment.
    for await chunk in provider.chatChunks(messages: history, tools: definitions, session: session) {
        if ChatTurnInterrupt.isCancelled(interrupt) {
            break
        }
        switch chunk {
        case let .textDelta(delta):
            text += delta
            print(delta, terminator: "")
            fflush(stdout)
        case let .toolCall(call):
            calls.append(call)
        case let .done(meta):
            usage = meta.usage
            if !meta.model.isEmpty {
                servedModel = meta.model
            }
        case let .error(message):
            streamError = message
        }
    }
    return ChunkedTurnDraft(text: text, calls: calls, usage: usage, servedModel: servedModel, streamError: streamError)
}

/// Rolls working memory back and reports cancellation.
private func cancelChunkedTurn(
    context: ChatTurnContext,
    snapshot: [Message],
    withLeadingNewline: Bool
) async -> ChatTurnOutcome {
    await context.conversations.setHistory(snapshot, for: context.sessionID)
    if withLeadingNewline {
        print("")
    }
    print(TerminalStyle.dim("Cancelled."))
    return .cancelled
}

/// Handles a chunked round with no structured calls via the narrated fallback.
private func handleChunkedNarratedTurn(
    text: String,
    tools: [any Tool],
    context: ChatTurnContext,
    interrupt: ChatInterruptState,
    progress: inout ChunkedTurnProgress
) async -> ChatTurnOutcome? {
    let narrated = OrchestratorToolLoop.narratedToolCalls(from: text, tools: tools)
    if narrated.isEmpty {
        guard OrchestratorToolLoop.shouldStoreAssistantText(text) else { return .completed }
        if ChatTurnInterrupt.isCancelled(interrupt) {
            return await cancelChunkedTurn(context: context, snapshot: progress.snapshot, withLeadingNewline: false)
        }
        await context.conversations.append(Message(role: .assistant, content: text), to: context.sessionID)
        await context.memoryEngine.mirrorTurn(
            content: text,
            sessionID: context.sessionID,
            role: .assistant,
            failurePolicy: .report,
            onFailure: chatMirrorFailureHandler
        )
        return .completed
    }
    progress.rounds += 1
    if OrchestratorToolLoop.isLimitExceeded(rounds: progress.rounds, max: context.maxToolIterations) {
        print(TerminalStyle.error("Tool loop exceeded \(context.maxToolIterations) rounds; stopping."))
        return .completed
    }
    if ChatTurnInterrupt.isCancelled(interrupt) {
        return await cancelChunkedTurn(context: context, snapshot: progress.snapshot, withLeadingNewline: false)
    }
    let narratedContent = OrchestratorToolLoop.assistantNoteContent(text: text, calls: narrated)
    await context.conversations.append(Message(role: .assistant, content: narratedContent), to: context.sessionID)
    let toolsCancelled = await executeChunkedInputs(narrated, context: context, interrupt: interrupt)
    if toolsCancelled {
        return await cancelChunkedTurn(context: context, snapshot: progress.snapshot, withLeadingNewline: false)
    }
    return nil
}

/// Handles a chunked round with structured calls under the shared budget.
private func handleChunkedStructuredTurn(
    text: String,
    calls: [ToolCall],
    context: ChatTurnContext,
    interrupt: ChatInterruptState,
    progress: inout ChunkedTurnProgress
) async -> ChatTurnOutcome? {
    progress.rounds += 1
    if OrchestratorToolLoop.isLimitExceeded(rounds: progress.rounds, max: context.maxToolIterations) {
        print(TerminalStyle.error("Tool loop exceeded \(context.maxToolIterations) rounds; stopping."))
        return .completed
    }
    if ChatTurnInterrupt.isCancelled(interrupt) {
        return await cancelChunkedTurn(context: context, snapshot: progress.snapshot, withLeadingNewline: false)
    }
    // Fail-closed per tool: withhold hallucinated names for omitted schemas so invalid tools
    // never reach execution. Silent partition keeps the prompt and wire filters as the single log sites.
    let validNames = await Set(VisionSchemaFilter.partitionValidSchemas(
        entries: context.toolBus.availableTools(),
        name: { $0.name },
        rawSchema: { $0.inputSchema.rawValue },
        logSkips: false
    ).valid.map(\.name))
    let inputs = calls.filter { validNames.contains($0.name) }
        .map { ToolInput(toolName: $0.name, argumentsJSON: $0.argumentsJSON, callID: $0.id) }
    // All calls withheld: end as text-only so the turn stays honest without looping for another round.
    if inputs.isEmpty {
        guard OrchestratorToolLoop.shouldStoreAssistantText(text) else { return .completed }
        if ChatTurnInterrupt.isCancelled(interrupt) {
            return await cancelChunkedTurn(context: context, snapshot: progress.snapshot, withLeadingNewline: false)
        }
        await context.conversations.append(Message(role: .assistant, content: text), to: context.sessionID)
        await context.memoryEngine.mirrorTurn(
            content: text,
            sessionID: context.sessionID,
            role: .assistant,
            failurePolicy: .report,
            onFailure: chatMirrorFailureHandler
        )
        return .completed
    }
    let assistantContent = OrchestratorToolLoop.assistantNoteContent(text: text, calls: inputs)
    await context.conversations.append(Message(role: .assistant, content: assistantContent), to: context.sessionID)
    let toolsCancelled = await executeChunkedInputs(inputs, context: context, interrupt: interrupt)
    if toolsCancelled {
        return await cancelChunkedTurn(context: context, snapshot: progress.snapshot, withLeadingNewline: false)
    }
    return nil
}

/// Runs one assistant turn via chunk streaming with tool-call visibility.
private func runChunkedTurn(
    provider: any ChunkStreamingProvider,
    context: ChatTurnContext,
    query: String,
    interrupt: ChatInterruptState
) async throws -> ChatTurnOutcome {
    let tools = await context.toolBus.availableTools()
    // Degraded tools stay out of the model request but must not fail the turn:
    // warn once per skipped name on stderr and continue with the valid subset.
    let filteredTools = VisionSchemaFilter.validatedTools(tools)
    for skipped in filteredTools.skipped.sorted() {
        // Single-source warning wording so CLI and orchestrator banners agree.
        cliPrintError(OrchestratorToolLoop.degradedToolWarning(for: skipped))
    }
    let validTools = filteredTools.valid
    let definitions = validTools.map { ToolDefinition($0) }
    let recall = try await context.memoryEngine.recallMessage(for: query, sessionID: context.sessionID, embedder: context.embedder)
    let historySnapshot = await context.conversations.session(id: context.sessionID)?.messages ?? []
    var progress = ChunkedTurnProgress(snapshot: historySnapshot, rounds: 0)
    while true {
        if ChatTurnInterrupt.isCancelled(interrupt) {
            return await cancelChunkedTurn(context: context, snapshot: progress.snapshot, withLeadingNewline: true)
        }
        let baseHistory = await context.conversations.workingHistory(
            for: context.sessionID,
            systemPrompt: context.systemPrompt
        )
        let history = Orchestrator.stableHistoryWithRecall(baseHistory, recall: recall)
        print(TerminalStyle.assistant("weaver> "), terminator: "")
        let draft = await drainChunkedStream(
            provider: provider,
            definitions: definitions,
            history: history,
            session: context.sessionID,
            interrupt: interrupt
        )
        // Abort the in-flight request immediately: breaking the `for await` releases the provider
        // continuation and cancels the underlying request, and the partial text and calls below are
        // discarded without persisting, mirroring, or advancing the session total.
        if ChatTurnInterrupt.isCancelled(interrupt) {
            return await cancelChunkedTurn(context: context, snapshot: progress.snapshot, withLeadingNewline: true)
        }
        print("")
        if let streamError = draft.streamError {
            print(TerminalStyle.error("Request failed: \(streamError)"))
            return .completed
        }
        // Poll before the trailer so a turn cancelled while the stream
        // drained never prints or advances the session total. The snapshot
        // below still guards the race between this poll and the trailer.
        if ChatTurnInterrupt.isCancelled(interrupt) {
            return await cancelChunkedTurn(context: context, snapshot: progress.snapshot, withLeadingNewline: false)
        }
        let trailerModel = draft.servedModel.isEmpty ? provider.modelInfo.name : draft.servedModel
        // Snapshot before the trailer advances the session total so a late
        // cancellation after the trailer can roll the counter back and keep
        // the documented "no trailer advance" contract.
        let tokensBeforeTrailer = context.sessionTokens.withLock { $0 }
        print(TerminalStyle.dim(ChatSessionTrailer.line(
            modelName: trailerModel,
            sessionTokens: context.sessionTokens,
            turnTotalTokens: draft.usage?.totalTokens,
            window: provider.modelInfo.contextLength
        )))
        if draft.calls.isEmpty {
            if let outcome = await handleChunkedNarratedTurn(
                text: draft.text,
                tools: tools,
                context: context,
                interrupt: interrupt,
                progress: &progress
            ) {
                if outcome == .cancelled {
                    context.sessionTokens.withLock { $0 = tokensBeforeTrailer }
                }
                return outcome
            }
            continue
        }
        if let outcome = await handleChunkedStructuredTurn(
            text: draft.text,
            calls: draft.calls,
            context: context,
            interrupt: interrupt,
            progress: &progress
        ) {
            if outcome == .cancelled {
                context.sessionTokens.withLock { $0 = tokensBeforeTrailer }
            }
            return outcome
        }
    }
}

/// Executes chunked tool inputs, printing results and mirroring episodic records.
private func executeChunkedInputs(
    _ inputs: [ToolInput],
    context: ChatTurnContext,
    interrupt: ChatInterruptState
) async -> Bool {
    for input in inputs {
        if ChatTurnInterrupt.isCancelled(interrupt) {
            return true
        }
        print(TerminalStyle.tool("◈ calling \(input.toolName) \(ToolInput.inline(input.argumentsJSON, limit: 160))"))
        let result = await context.toolBus.execute(
            toolCall: input,
            context: ToolContext(conversationID: context.sessionID)
        )
        if ChatTurnInterrupt.isCancelled(interrupt) {
            return true
        }
        let marker = result.isError ? "✕" : "→"
        print(TerminalStyle.dim("  \(marker) \(ToolInput.inline(result.content, limit: 300))"))
        await context.conversations.append(result.asMessage(), to: context.sessionID)
        if let record = OrchestratorToolLoop.episodicToolRecord(toolName: input.toolName, result: result) {
            await context.memoryEngine.mirrorTurn(
                content: record,
                sessionID: context.sessionID,
                role: .tool,
                failurePolicy: .report,
                onFailure: chatMirrorFailureHandler
            )
        }
    }
    return false
}

/// Accumulated text-only stream result for one LLM round.
private struct TextTurnDraft: Sendable {
    /// Accumulated assistant text.
    var text: String
    /// Terminal stream error, if any.
    var streamError: String?
    /// Billed usage when the backend reported it.
    var billedTokens: Int?
}

/// Drains one text-only stream into a draft.
private func drainTextStream(
    provider: any LLMProvider,
    history: [Message],
    tools: [any Tool],
    session: UUID?,
    interrupt: ChatInterruptState
) async -> TextTurnDraft {
    var text = ""
    var streamError: String?
    var billedTokens: Int?
    // Pin the turn to the chat session so sticky-slot backends reuse the
    // cached prefix instead of falling back to server auto-assignment.
    for await part in provider.chat(messages: history, tools: tools, session: session) {
        if ChatTurnInterrupt.isCancelled(interrupt) {
            break
        }
        if let message = part.errorMessage {
            streamError = message.isEmpty ? "unknown error" : message
            // Record the failure but keep draining the stream so the
            // provider continuation is released and any trailing usage
            // or error chunks are observed instead of leaking.
            continue
        }
        if !part.delta.isEmpty {
            text += part.delta
            print(part.delta, terminator: "")
            fflush(stdout)
        }
        if part.isFinished {
            // Record billed usage and keep draining until the stream
            // finishes instead of breaking early, so later usage or
            // error chunks are not missed and the continuation closes.
            if let total = part.totalTokens {
                billedTokens = total
            }
        }
    }
    return TextTurnDraft(text: text, streamError: streamError, billedTokens: billedTokens)
}

/// Runs one assistant turn via the text-only stream with the shared narrated tool loop.
private func runTextTurn(
    provider: any LLMProvider,
    context: ChatTurnContext,
    query: String,
    interrupt: ChatInterruptState
) async throws -> ChatTurnOutcome {
    let tools = await context.toolBus.availableTools()
    // Mirror the chunked path: degraded tools stay out of the wire request with one honest
    // warning per skipped name so text-only turns never go silent about omissions.
    let filteredTextTools = VisionSchemaFilter.validatedTools(tools)
    for skipped in filteredTextTools.skipped.sorted() {
        cliPrintError(OrchestratorToolLoop.degradedToolWarning(for: skipped))
    }
    let validTextTools = filteredTextTools.valid
    let recall = try await context.memoryEngine.recallMessage(for: query, sessionID: context.sessionID, embedder: context.embedder)
    let historySnapshot = await context.conversations.session(id: context.sessionID)?.messages ?? []
    var toolRounds = 0
    while true {
        if ChatTurnInterrupt.isCancelled(interrupt) {
            await context.conversations.setHistory(historySnapshot, for: context.sessionID)
            print("")
            print(TerminalStyle.dim("Cancelled."))
            return .cancelled
        }
        let baseHistory = await context.conversations.workingHistory(
            for: context.sessionID,
            systemPrompt: context.systemPrompt
        )
        let history = Orchestrator.stableHistoryWithRecall(baseHistory, recall: recall)
        print(TerminalStyle.assistant("weaver> "), terminator: "")
        let draft = await drainTextStream(
            provider: provider,
            history: history,
            tools: validTextTools,
            session: context.sessionID,
            interrupt: interrupt
        )
        let text = draft.text
        let streamError = draft.streamError
        let billedTokens = draft.billedTokens
        if ChatTurnInterrupt.isCancelled(interrupt) {
            await context.conversations.setHistory(historySnapshot, for: context.sessionID)
            print("")
            print(TerminalStyle.dim("Cancelled."))
            return .cancelled
        }
        print("")
        if let streamError {
            print(TerminalStyle.error("Request failed: \(streamError)"))
            return .completed
        }
        // Poll before the trailer so a turn cancelled while the stream
        // drained never prints or advances the session total. The snapshot
        // below still guards the race between this poll and the trailer.
        if ChatTurnInterrupt.isCancelled(interrupt) {
            await context.conversations.setHistory(historySnapshot, for: context.sessionID)
            print(TerminalStyle.dim("Cancelled."))
            return .cancelled
        }
        // Snapshot before the trailer advances the session total so a late
        // cancellation after the trailer can roll the counter back and keep
        // the documented "no trailer advance" contract.
        let tokensBeforeTrailer = context.sessionTokens.withLock { $0 }
        print(TerminalStyle.dim(ChatSessionTrailer.line(
            modelName: provider.modelInfo.name,
            sessionTokens: context.sessionTokens,
            turnTotalTokens: billedTokens,
            window: provider.modelInfo.contextLength
        )))
        let narrated = OrchestratorToolLoop.narratedToolCalls(from: text, tools: tools)
        if narrated.isEmpty {
            guard OrchestratorToolLoop.shouldStoreAssistantText(text) else { return .completed }
            if ChatTurnInterrupt.isCancelled(interrupt) {
                context.sessionTokens.withLock { $0 = tokensBeforeTrailer }
                await context.conversations.setHistory(historySnapshot, for: context.sessionID)
                print(TerminalStyle.dim("Cancelled."))
                return .cancelled
            }
            await context.conversations.append(Message(role: .assistant, content: text), to: context.sessionID)
            await context.memoryEngine.mirrorTurn(
                content: text,
                sessionID: context.sessionID,
                role: .assistant,
                failurePolicy: .report,
                onFailure: chatMirrorFailureHandler
            )
            return .completed
        }
        toolRounds += 1
        if OrchestratorToolLoop.isLimitExceeded(rounds: toolRounds, max: context.maxToolIterations) {
            print(TerminalStyle.error("Tool loop exceeded \(context.maxToolIterations) rounds; stopping."))
            return .completed
        }
        if ChatTurnInterrupt.isCancelled(interrupt) {
            context.sessionTokens.withLock { $0 = tokensBeforeTrailer }
            await context.conversations.setHistory(historySnapshot, for: context.sessionID)
            print(TerminalStyle.dim("Cancelled."))
            return .cancelled
        }
        let narratedContent = OrchestratorToolLoop.assistantNoteContent(text: text, calls: narrated)
        await context.conversations.append(Message(role: .assistant, content: narratedContent), to: context.sessionID)
        let toolsCancelled = await executeChunkedInputs(narrated, context: context, interrupt: interrupt)
        if toolsCancelled {
            context.sessionTokens.withLock { $0 = tokensBeforeTrailer }
            await context.conversations.setHistory(historySnapshot, for: context.sessionID)
            print(TerminalStyle.dim("Cancelled."))
            return .cancelled
        }
    }
}

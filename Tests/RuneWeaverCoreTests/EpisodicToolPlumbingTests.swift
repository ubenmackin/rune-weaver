// Rune Weaver Tests — Episodic tool plumbing between working and durable memory.
import Foundation
import os
@testable import RuneWeaverCore
import Testing

/// Builds an isolated engine on a fresh temporary directory.
private func makeToolPlumbingEngine() -> (engine: MemoryEngine, base: URL) {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let engine = MemoryEngine(
        episodesDBPath: base.appendingPathComponent("episodes.db").path,
        vectorDBPath: base.appendingPathComponent("vectors").path,
        profilePath: base.appendingPathComponent("profile.json").path
    )
    return (engine, base)
}

/// Fixture tool returning a canned outcome for episodic tests.
private struct FixturePlumbingTool: Tool, Sendable {
    /// Registered tool name.
    let name: String
    /// Canned outcome text.
    let output: String
    /// Human-readable description.
    var description: String {
        "Fixture stub for \(name)."
    }

    /// Empty-object schema.
    let inputSchema = JSONSchema(rawValue: #"{"type":"object"}"#)
    /// Always allowed without prompts.
    let permissionLevel = PermissionLevel.readOnly

    /// Returns the canned outcome.
    func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        .success(output, callID: input.callID)
    }
}

/// Scripted provider replaying canned texts in call order.
private final class ScriptedPlumbingLLM: LLMProvider, Sendable {
    /// Stable test model metadata.
    let modelInfo = ModelInfo(name: "fixture", provider: "test", contextLength: 8192)
    private struct ScriptState: Sendable {
        var texts: [String]
        var index: Int
    }

    /// Guards script state below.
    private let state: OSAllocatedUnfairLock<ScriptState>

    /// Creates a scripted provider.
    /// - Parameter texts: Canned texts in call order.
    init(texts: [String]) {
        self.state = OSAllocatedUnfairLock(initialState: ScriptState(texts: texts, index: 0))
    }

    /// Replays the next canned text as a finished stream.
    func chat(messages _: [Message], tools _: [any Tool]) -> AsyncStream<LLMResponse> {
        let text: String = state.withLock { s in
            let next = s.index < s.texts.count ? s.texts[s.index] : s.texts.last ?? ""
            s.index += 1
            return next
        }
        return AsyncStream { continuation in
            continuation.yield(LLMResponse(delta: text, isFinished: true))
            continuation.finish()
        }
    }

    /// Unused embeddings stub.
    /// - Parameter text: Ignored texts.
    /// - Returns: Empty vectors.
    func embeddings(text _: [String]) async throws -> [[Float]] {
        []
    }
}

/// Slow fixture tool giving the test a window to cancel mid-turn.
private struct SlowPlumbingTool: Tool, Sendable {
    /// Registered tool name.
    let name: String
    /// Canned outcome text.
    let output: String
    /// Optional notification callback when execution starts.
    var onStart: (@Sendable () -> Void)?
    /// Human-readable description.
    var description: String {
        "Slow fixture stub for \(name)."
    }

    /// Empty-object schema.
    let inputSchema = JSONSchema(rawValue: #"{"type":"object"}"#)
    /// Always allowed without prompts.
    let permissionLevel = PermissionLevel.readOnly

    /// Sleeps briefly then returns the canned outcome.
    func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        onStart?()
        try? await Task.sleep(nanoseconds: 500_000_000)
        return .success(output, callID: input.callID)
    }
}

@Suite("Episodic Tool Plumbing")
struct EpisodicToolPlumbingTests {
    @Test
    func `Tool record keeps tool name plus outcome`() {
        let result = ToolResult(toolCallID: "call_fixture_aaa111", content: "Found 2 emails about the lighthouse")
        let record = MemoryEngine.episodicToolRecord(toolName: "email.search", result: result)
        #expect(record != nil)
        #expect(record?.contains("email.search") == true)
        #expect(record?.contains("Found 2 emails about the lighthouse") == true)
        #expect(record?.contains("call_fixture_aaa111") == false)
        #expect(record?.contains("Calling ") == false)
    }

    @Test
    func `Tool record skips blank outcomes and marks failures`() {
        let blank = ToolResult(toolCallID: "call_x", content: "   \n\t  ")
        #expect(MemoryEngine.episodicToolRecord(toolName: "email.search", result: blank) == nil)
        #expect(MemoryEngine.episodicToolRecord(toolName: "  ", content: "ok", isError: false) == nil)
        let failed = MemoryEngine.episodicToolRecord(
            toolName: "calendar.list",
            content: "Denied by approval gate",
            isError: true
        )
        #expect(failed?.contains("calendar.list") == true)
        #expect(failed?.contains("Denied by approval gate") == true)
        let shared = OrchestratorToolLoop.episodicToolRecord(
            toolName: "calendar.list",
            result: ToolResult(toolCallID: "call_y", content: "Denied by approval gate", isError: true)
        )
        #expect(shared == failed)
    }

    @Test
    func `Stripping removes placeholder lines and keeps other text`() {
        let calls = [
            ToolInput(toolName: "email.search", argumentsJSON: #"{"query":"lighthouse"}"#, callID: "call_fixture_aaa111")
        ]
        let placeholder = ToolInput.placeholderContent(for: calls)
        #expect(MemoryEngine.isToolPlumbingLine(placeholder))
        #expect(!MemoryEngine.isToolPlumbingLine("I found two emails."))
        let mixed = "I will check.\n" + placeholder + "\nDone."
        let stripped = MemoryEngine.strippingToolPlumbing(from: mixed)
        #expect(stripped.contains("I will check."))
        #expect(stripped.contains("Done."))
        #expect(!stripped.contains("Calling "))
        #expect(!stripped.contains("call_fixture_aaa111"))
    }

    @Test
    func `Tool-heavy turn persists clean content without placeholder IDs or call JSON`() async throws {
        let (engine, base) = makeToolPlumbingEngine()
        defer { try? FileManager.default.removeItem(at: base) }
        let conversations = ConversationManager()
        let bus = ToolBus()
        await bus.register(tool: FixturePlumbingTool(name: "email.search", output: "Found 2 emails about the lighthouse keeper"))
        await bus.register(tool: FixturePlumbingTool(name: "calendar.list", output: "No events tomorrow"))
        let narration = "I will check both sources."
        let finalText = "Done: found lighthouse emails and no calendar events."
        let llm = ScriptedPlumbingLLM(texts: [narration, finalText])
        let emailArgs = #"{"query":"lighthouse"}"#
        let calendarArgs = #"{"date":"tomorrow"}"#
        let firstID = "call_fixture_aaa111"
        let secondID = "call_fixture_bbb222"
        let resolver: OrchestratorToolResolver = { messages, _ in
            if messages.contains(where: { $0.role == .tool }) {
                return []
            }
            return [
                ToolInput(toolName: "email.search", argumentsJSON: emailArgs, callID: firstID),
                ToolInput(toolName: "calendar.list", argumentsJSON: calendarArgs, callID: secondID)
            ]
        }
        let orchestrator = Orchestrator(
            conversations: conversations,
            toolBus: bus,
            llm: llm,
            toolResolver: resolver,
            memoryEngine: engine
        )
        let sessionID = UUID()
        let userText = "Check email and calendar for lighthouse"
        let response = try await orchestrator.process(input: UserInput(text: userText, sessionID: sessionID))
        #expect(response.text == finalText)
        #expect(response.toolActions.count == 2)

        let history = await conversations.history(for: sessionID)
        #expect(history.contains { $0.role == .assistant && $0.content.contains("Calling ") })
        #expect(history.contains { $0.role == .assistant && $0.content.contains(firstID) })
        #expect(history.contains { $0.role == .tool && $0.toolCallID == firstID })
        #expect(history.contains { $0.role == .tool && $0.toolCallID == secondID })

        let episodes = try await engine.episodes(for: sessionID)
        try #require(episodes.count == 4)
        #expect(episodes.contains { $0.role == .user && $0.content == userText })
        #expect(episodes.contains { $0.role == .assistant && $0.content == finalText })
        #expect(episodes.contains {
            $0.role == .tool && $0.content.contains("email.search") && $0.content.contains("Found 2 emails about the lighthouse keeper")
        })
        #expect(episodes.contains {
            $0.role == .tool && $0.content.contains("calendar.list") && $0.content.contains("No events tomorrow")
        })
        let joined = episodes.map(\.content).joined(separator: "\n")
        #expect(!joined.contains("Calling "))
        #expect(!joined.contains(firstID))
        #expect(!joined.contains(secondID))
        #expect(!joined.contains(emailArgs))
        #expect(!joined.contains(calendarArgs))
        #expect(!joined.contains(narration))
        for episode in episodes {
            #expect(episode.metadata["tool_call_id"] == nil)
        }
    }

    @Test
    func `ConversationManager syncs session and messages written by another instance to disk`() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let dbPath = base.appendingPathComponent("episodes.db").path

        let writer = ConversationManager(episodesDBPath: dbPath)
        let reader = ConversationManager(episodesDBPath: dbPath)

        let sessionID = UUID()
        await writer.append(Message(role: .user, content: "Hello from CLI"), to: sessionID)
        await writer.append(Message(role: .assistant, content: "Hello back"), to: sessionID)
        try await writer.saveAll()

        let fetched = await reader.session(id: sessionID)
        try #require(fetched != nil)
        #expect(fetched?.messages.count == 2)
        #expect(fetched?.messages[0].content == "Hello from CLI")
        #expect(fetched?.messages[1].content == "Hello back")

        let summaries = await reader.listSessions()
        #expect(summaries.contains { $0.id == sessionID })
    }

    @Test
    func `Cancelled turn after tool keeps working and episodic audit`() async throws {
        let (engine, base) = makeToolPlumbingEngine()
        defer { try? FileManager.default.removeItem(at: base) }
        let conversations = ConversationManager()
        let bus = ToolBus()
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        await bus.register(tool: SlowPlumbingTool(name: "email.search", output: "Found 1 email", onStart: {
            continuation.yield()
        }))
        let llm = ScriptedPlumbingLLM(texts: ["checking", "final"])
        let callID = "call_audit_cancel_1"
        let resolver: OrchestratorToolResolver = { messages, _ in
            if messages.contains(where: { $0.role == .tool }) {
                return []
            }
            return [ToolInput(toolName: "email.search", argumentsJSON: "{}", callID: callID)]
        }
        let orchestrator = Orchestrator(
            conversations: conversations,
            toolBus: bus,
            llm: llm,
            toolResolver: resolver,
            memoryEngine: engine
        )
        let sessionID = UUID()
        let task = Task {
            try await orchestrator.process(input: UserInput(text: "check mail", sessionID: sessionID))
        }
        // Cancel while the slow tool runs so the side effect has already
        // happened when cancellation lands.
        for await _ in stream {
            task.cancel()
            break
        }
        let result = await task.result
        guard case let .failure(error) = result, error is CancellationError else {
            Issue.record("Expected CancellationError, got \(result)")
            return
        }
        // Working memory keeps the executed tool instead of rolling back.
        let history = await conversations.history(for: sessionID)
        #expect(history.contains { $0.role == .tool && $0.toolCallID == callID })
        // Episodic memory mirrors the executed tool for the audit trail.
        let episodes = try await engine.episodes(for: sessionID)
        #expect(episodes.contains { $0.role == .tool && $0.content.contains("email.search") })
    }
}

// Rune Weaver Core Tests — Orchestrator Persona prompt injection.

import Foundation
import os
@testable import RuneWeaverCore
import Testing

/// Provider that captures messages passed to chat for prompt assertions.
private final class CapturingPersonaLLM: LLMProvider, Sendable {
    let modelInfo = ModelInfo(name: "capturing-persona-fixture", provider: "test", contextLength: 8192)
    private let lock = OSAllocatedUnfairLock(initialState: [[Message]]())

    var capturedMessages: [[Message]] {
        lock.withLock { $0 }
    }

    func chat(messages: [Message], tools _: [any Tool]) -> AsyncStream<LLMResponse> {
        lock.withLock { $0.append(messages) }
        return AsyncStream { continuation in
            continuation.yield(LLMResponse(delta: "Done", isFinished: true))
            continuation.finish()
        }
    }

    func embeddings(text _: [String]) async throws -> [[Float]] {
        []
    }
}

private func makeIsolatedMemoryEngine() throws -> (MemoryEngine, URL) {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("orch-persona-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let engine = MemoryEngine(
        episodesDBPath: base.appendingPathComponent("episodes.db").path,
        vectorDBPath: base.appendingPathComponent("vectors").path,
        profilePath: base.appendingPathComponent("profile.json").path
    )
    return (engine, base)
}

@Suite("Orchestrator Persona")
struct OrchestratorPersonaTests {
    @Test
    func `Custom persona is injected into the system prompt on chat turn`() async throws {
        let (engine, base) = try makeIsolatedMemoryEngine()
        defer { try? FileManager.default.removeItem(at: base) }

        let customPersona = PersonaConfig(
            assistantName: "Weaver",
            tone: .warm,
            style: "Keep it actionable.",
            userName: "Ben",
            avatar: .violet
        )

        let llm = CapturingPersonaLLM()
        let orchestrator = Orchestrator(
            conversations: ConversationManager(),
            toolBus: ToolBus(permissionGate: PermissionGate()),
            llm: llm,
            memoryEngine: engine,
            persona: customPersona
        )

        #expect(orchestrator.persona == customPersona)

        _ = try await orchestrator.process(input: UserInput(
            text: "hellow what is your name?",
            sessionID: UUID()
        ))

        let messages = try #require(llm.capturedMessages.first)
        let systemMessage = try #require(messages.first { $0.role == .system })

        let expectedIdentity = "You are Weaver, Be warm and encouraging while staying focused. Keep it actionable. The owner's preferred name is Ben, use it sparingly and naturally."
        #expect(systemMessage.content.contains(expectedIdentity))
        #expect(!systemMessage.content.contains("You are Rune Weaver, a helpful personal assistant"))
    }

    @Test
    func `Default persona preserves legacy identity line in system prompt`() async throws {
        let (engine, base) = try makeIsolatedMemoryEngine()
        defer { try? FileManager.default.removeItem(at: base) }

        let llm = CapturingPersonaLLM()
        let orchestrator = Orchestrator(
            conversations: ConversationManager(),
            toolBus: ToolBus(permissionGate: PermissionGate()),
            llm: llm,
            memoryEngine: engine
        )

        #expect(orchestrator.persona == PersonaConfig())

        _ = try await orchestrator.process(input: UserInput(
            text: "Hello!",
            sessionID: UUID()
        ))

        let messages = try #require(llm.capturedMessages.first)
        let systemMessage = try #require(messages.first { $0.role == .system })

        #expect(systemMessage.content.contains(SystemPromptComposer.legacyIdentityLine))
    }

    @Test
    func `Custom persona is preserved in scheduled background turn`() async throws {
        let (engine, base) = try makeIsolatedMemoryEngine()
        defer { try? FileManager.default.removeItem(at: base) }

        let customPersona = PersonaConfig(
            assistantName: "Weaver",
            tone: .concise,
            style: "",
            userName: "Ben"
        )

        let llm = CapturingPersonaLLM()
        let orchestrator = Orchestrator(
            conversations: ConversationManager(),
            toolBus: ToolBus(permissionGate: PermissionGate()),
            llm: llm,
            memoryEngine: engine,
            persona: customPersona
        )

        _ = try await orchestrator.process(input: UserInput(
            text: "Run nightly check",
            sessionID: UUID(),
            source: "scheduler"
        ))

        let messages = try #require(llm.capturedMessages.first)
        let systemMessage = try #require(messages.first { $0.role == .system })

        let expectedIdentity = "You are Weaver, Keep replies short and direct; no small talk. The owner's preferred name is Ben, use it sparingly and naturally."
        #expect(systemMessage.content.contains(expectedIdentity))
        #expect(systemMessage.content.contains("Scheduled task guidance:"))
    }
}

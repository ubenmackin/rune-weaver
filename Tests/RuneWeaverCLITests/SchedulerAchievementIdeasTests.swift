// Rune Weaver CLI Tests — Headless achievement suggestion wiring and log line.
//
// The headless scheduler loop keeps no live hub for the service's proactive
// broadcast, so each finished goal turn names the achievement-born suggestions
// the shared runner persisted. These tests pin the wiring contract (the headless
// ideas engine mirrors the service bootstrap's enabled gate) plus the formatting
// contract: quiet turns stay quiet, and surfaced turns name the count plus the
// bounded titles.

import Foundation
@testable import RuneWeaverCLI
@testable import RuneWeaverCore
import Testing

/// Minimal provider so headless wiring has a model without a network.
private final class HeadlessIdeasStubLLM: LLMProvider, Sendable {
    /// Stable test model metadata.
    let modelInfo = ModelInfo(name: "headless-ideas-fixture", provider: "test", contextLength: 8192)

    /// Replays one empty batch; wiring tests only care about construction.
    func chat(messages _: [Message], tools _: [any Tool]) -> AsyncStream<LLMResponse> {
        AsyncStream { continuation in
            continuation.yield(LLMResponse(delta: "[]", isFinished: true))
            continuation.finish()
        }
    }

    /// Unused embeddings stub.
    func embeddings(text _: [String]) async throws -> [[Float]] {
        []
    }
}

/// Creates an isolated temporary database path and its base directory.
private func makeHeadlessIdeasDBPath() -> (path: String, base: URL) {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("runeweaver-headless-ideas-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return (base.appendingPathComponent("episodes.db").path, base)
}

@Suite("Scheduler Achievement Ideas Log")
struct SchedulerAchievementIdeasTests {
    @Test
    func `Quiet turns produce no log line`() {
        #expect(SchedulerRunCommand.achievementIdeasLogLine(goalTitle: "Tend herbs", ideas: []) == nil)
    }

    @Test
    func `Surfaced turns name the count and titles`() {
        let ideas = [
            Idea(kind: .tip, title: "Water at dawn", body: "Basil likes mornings."),
            Idea(kind: .newGoal, title: "Start a journal", body: "One page a night.")
        ]
        let line = SchedulerRunCommand.achievementIdeasLogLine(goalTitle: "Tend herbs", ideas: ideas)
        #expect(line == "Goal 'Tend herbs' proposed 2 suggestion(s): Water at dawn; Start a journal")
    }

    @Test
    func `Verbose titles stay inline-bounded`() throws {
        let ideas = [Idea(kind: .tip, title: String(repeating: "w", count: 500), body: "")]
        let line = try #require(SchedulerRunCommand.achievementIdeasLogLine(goalTitle: "Tend herbs", ideas: ideas))
        // The titles ride inline-bounded so one verbose suggestion cannot flood
        // the tick log; the count prefix stays intact.
        #expect(line.hasPrefix("Goal 'Tend herbs' proposed 1 suggestion(s): "))
        #expect(line.count < "Goal 'Tend herbs' proposed 1 suggestion(s): ".count + 200)
    }
}

@Suite("Scheduler Headless Ideas Wiring")
struct SchedulerHeadlessIdeasWiringTests {
    @Test
    func `Disabled ideas keep a nil headless engine`() {
        let (path, base) = makeHeadlessIdeasDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = IdeasStore(dbPath: path)
        // A stock install never spends a background review call, so the
        // headless runtime keeps no engine and post-advance stays quiet.
        #expect(SchedulerRunCommand.makeHeadlessIdeasEngine(
            store: store,
            llm: HeadlessIdeasStubLLM(),
            config: IdeasConfig()
        ) == nil)
    }

    @Test
    func `Enabled ideas wire a live headless engine`() async throws {
        let (path, base) = makeHeadlessIdeasDBPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = IdeasStore(dbPath: path)
        var config = IdeasConfig()
        config.enabled = true
        let engine = SchedulerRunCommand.makeHeadlessIdeasEngine(
            store: store,
            llm: HeadlessIdeasStubLLM(),
            config: config,
            memoryFacts: { [] }
        )
        let wired = try #require(engine)
        #expect(await wired.isEnabled == true)
    }
}

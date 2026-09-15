// Rune Weaver Core Tests — Memory recall injection tests.
import Foundation
@testable import RuneWeaverCore
import Testing

/// Builds an isolated engine on a fresh temporary directory.
///
/// Each test gets its own episodes database, vector directory, and
/// profile file so fixture writes never leak between tests.
/// - Returns: Engine plus the base directory owning its files.
private func makeRecallInjectionEngine() -> (engine: MemoryEngine, base: URL) {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let engine = MemoryEngine(
        episodesDBPath: base.appendingPathComponent("episodes.db").path,
        vectorDBPath: base.appendingPathComponent("vectors").path,
        profilePath: base.appendingPathComponent("profile.json").path
    )
    return (engine, base)
}

@Suite("Memory Recall Injection")
struct MemoryRecallInjectionTests {
    @Test
    func `Recall context skips empty and below-threshold hits`() {
        #expect(MemoryEngine.automaticRecallContext(for: []) == nil)
        let weak = [
            MemoryResult(content: "unrelated aside", score: 0.05, source: .profile)
        ]
        #expect(MemoryEngine.automaticRecallContext(for: weak) == nil)
        let relevant = [
            MemoryResult(content: "My dog is named Biscuit", score: 0.2, source: .profile)
        ]
        let context = MemoryEngine.automaticRecallContext(for: relevant)
        #expect(context != nil)
        #expect(context?.contains(MemoryEngine.automaticRecallHeader) == true)
        #expect(context?.contains("[profile]") == true)
        #expect(context?.contains("Biscuit") == true)
    }

    @Test
    func `Recall context labels sources and truncates to budget`() {
        let results = [
            MemoryResult(content: "Sailed past the lighthouse at dawn", score: 1.0, source: .episodic),
            MemoryResult(content: "My dog is named Biscuit", score: 0.9, source: .profile),
            MemoryResult(content: String(repeating: "Biscuit ", count: 400), score: 0.8, source: .semantic)
        ]
        let context = MemoryEngine.automaticRecallContext(for: results, maxChars: 200)
        #expect(context != nil)
        #expect((context?.count ?? 0) <= 200)
        #expect(context?.hasSuffix("…") == true)
        #expect(context?.contains("[episodic]") == true)
        #expect(context?.contains("[profile]") == true)
        let message = MemoryEngine.automaticRecallMessage(for: results, maxChars: 200)
        #expect(message?.role == .system)
        #expect(message?.content == context)
    }

    @Test
    func `Two sessions share recall via the keyword path`() async throws {
        let (engine, base) = makeRecallInjectionEngine()
        defer { try? FileManager.default.removeItem(at: base) }
        let sessionA = UUID()
        try await engine.storeEpisodic(
            content: "The lighthouse keeper collects brass compasses",
            sessionID: sessionA
        )
        try await engine.storeProfileFact(content: "My dog is named Biscuit", source: "chat")
        let results = try await engine.recall(query: "What is my dog Biscuit name?", embedding: nil, limit: 5)
        #expect(results.contains { $0.content.contains("Biscuit") && $0.score >= MemoryEngine.automaticRecallThreshold })
        let context = MemoryEngine.automaticRecallContext(for: results)
        #expect(context != nil)
        #expect(context?.contains("Biscuit") == true)
        let unrelated = try await engine.recall(query: "quantum entanglement calibration", embedding: nil, limit: 5)
        #expect(MemoryEngine.automaticRecallContext(for: unrelated) == nil)
    }
}

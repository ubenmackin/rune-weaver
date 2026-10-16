// Rune Weaver Core Tests — Memory recall injection tests.

import Foundation
@testable import RuneWeaverCore
import Testing

/// Builds an isolated engine on a fresh temporary directory.
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

/// Embedder that always cancels so recall must propagate instead of degrading.
private struct CancellingEmbedder: EmbeddingsBackend, Sendable {
    /// Stable identifier marking vectors as test fixtures.
    let modelID = "cancel-stub"
    /// Fixed width matching the fixture vectors.
    let dimension: Int? = 2

    /// Throws cancellation for every batch.
    func embed(_ _: [String]) async throws -> [[Float]] {
        throw CancellationError()
    }
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

    @Test
    func `historyWithRecall anchors recall before active user turn preserving prefix`() {
        let recall = Message(role: .system, content: "Relevant memories: user likes tea")

        // 1. Multi-turn conversation: recall must sit before User 2, leaving (System, User 1, Assistant 1) intact
        let system = Message(role: .system, content: "You are an assistant")
        let user1 = Message(role: .user, content: "Hi")
        let assistant1 = Message(role: .assistant, content: "Hello! How can I help you?")
        let user2 = Message(role: .user, content: "What do I like?")
        let multiTurn = [system, user1, assistant1, user2]

        let spliced = MemoryEngine.historyWithRecall(multiTurn, recall: recall)
        #expect(spliced.count == 5)
        #expect(spliced[0] == system)
        #expect(spliced[1] == user1)
        #expect(spliced[2] == assistant1)
        #expect(spliced[3] == recall)
        #expect(spliced[4] == user2)

        // 2. Single turn (System, User 1)
        let singleTurn = [system, user1]
        let singleSpliced = MemoryEngine.historyWithRecall(singleTurn, recall: recall)
        #expect(singleSpliced == [system, recall, user1])

        // 3. Tool round in active turn: recall stays before User 2
        let toolCallNote = Message(role: .assistant, content: "Calling tool")
        let toolResult = Message(role: .tool, content: "result", toolCallID: "call_1")
        let toolTurn = [system, user1, assistant1, user2, toolCallNote, toolResult]
        let toolSpliced = MemoryEngine.historyWithRecall(toolTurn, recall: recall)
        #expect(toolSpliced == [system, user1, assistant1, recall, user2, toolCallNote, toolResult])

        // 4. System-only history fallback
        let systemOnly = [system]
        let systemSpliced = MemoryEngine.historyWithRecall(systemOnly, recall: recall)
        #expect(systemSpliced == [system, recall])

        // 5. Nil recall returns identical history
        #expect(MemoryEngine.historyWithRecall(multiTurn, recall: nil) == multiTurn)
    }

    @Test
    func `Recall budgets clamp low out-of-range values`() {
        let clamped = RecallBudgets(
            perTierLimit: 0,
            autoLimit: -5,
            threshold: -0.5,
            maxChars: 10,
            perHitChars: 10,
            docPoolMultiplier: 0,
            episodicWeight: -1.0
        ).clamped()
        #expect(clamped.perTierLimit == 1)
        #expect(clamped.autoLimit == 1)
        #expect(clamped.threshold == 0.0)
        #expect(clamped.maxChars == 500)
        #expect(clamped.perHitChars == 100)
        #expect(clamped.docPoolMultiplier == 1)
        #expect(clamped.episodicWeight == 0.0)
    }

    @Test
    func `Recall budgets clamp high out-of-range values`() {
        let clamped = RecallBudgets(
            perTierLimit: 100,
            autoLimit: 99,
            threshold: 2.0,
            maxChars: 99999,
            perHitChars: 99999,
            docPoolMultiplier: 20,
            episodicWeight: 5.0
        ).clamped()
        #expect(clamped.perTierLimit == 50)
        #expect(clamped.autoLimit == 50)
        #expect(clamped.threshold == 1.0)
        #expect(clamped.maxChars == 32000)
        #expect(clamped.perHitChars == 8000)
        #expect(clamped.docPoolMultiplier == 8)
        #expect(clamped.episodicWeight == 1.0)
    }

    @Test
    func `Recall budgets file-load clamps out-of-range values`() throws {
        let text = """
        [llm]
        default_provider = "mlx"

        [llm.providers.mlx]
        enabled = true
        model = "gemma-4-9b"
        server_url = "http://localhost:8080"

        [memory]
        recall_per_tier_limit = 0
        recall_auto_limit = 500
        recall_threshold = 5
        recall_max_chars = 10
        recall_per_hit_chars = 1
        recall_doc_pool_multiplier = 99
        recall_episodic_weight = -2
        """
        let root = try TOMLParser.parse(text)
        let config = try RuneWeaverConfig(decoding: root)
        // File-load degrades to the nearest bound instead of refusing to boot.
        #expect(config.memory.recallBudgets.perTierLimit == 1)
        #expect(config.memory.recallBudgets.autoLimit == 50)
        #expect(config.memory.recallBudgets.threshold == 1.0)
        #expect(config.memory.recallBudgets.maxChars == 500)
        #expect(config.memory.recallBudgets.perHitChars == 100)
        #expect(config.memory.recallBudgets.docPoolMultiplier == 8)
        #expect(config.memory.recallBudgets.episodicWeight == 0.0)
        try config.validate()
    }

    @Test
    func `packRecallHits drops candidate hits that do not fit completely without ellipsis amputation`() {
        let hit1 = MemoryResult(content: "First memory item: " + String(repeating: "A", count: 350), score: 0.9, source: .profile)
        let hit2 = MemoryResult(content: "Second memory item: " + String(repeating: "B", count: 350), score: 0.8, source: .profile)
        let hit3 = MemoryResult(content: "Third memory item: " + String(repeating: "C", count: 350), score: 0.7, source: .profile)

        // With maxChars 500: header (68) + line1 (~370) = ~438 <= 500.
        // line2 cannot fit in the remaining ~62 chars, so it must be dropped without chopping line1.
        let budgetFittingOnlyOne = RecallBudgets(
            perTierLimit: 5,
            autoLimit: 5,
            threshold: 0.1,
            maxChars: 500,
            perHitChars: 2000
        )

        let packed = MemoryEngine.packRecallHits(from: [hit1, hit2, hit3], budgets: budgetFittingOnlyOne, labelingEnabled: false)
        #expect(packed.injectedHits.count == 1)
        #expect(packed.injectedHits.first?.content == hit1.content)
        #expect(packed.contextText != nil)
        #expect(packed.contextText?.contains("First memory item") == true)
        #expect(packed.contextText?.contains("Second memory item") == false)
        #expect(packed.contextText?.hasSuffix("…") == false)
        #expect(packed.injectedChars == (packed.contextText?.count ?? 0))
    }

    @Test
    func `Forced live override injects zero doc hits but keeps profile`() async throws {
        await LiveSearchOverride.shared.setForced(false)
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let docIndexPath = base.appendingPathComponent("docindex.db").path
        let engine = MemoryEngine(
            episodesDBPath: base.appendingPathComponent("episodes.db").path,
            vectorDBPath: base.appendingPathComponent("vectors").path,
            docIndexDBPath: docIndexPath,
            profilePath: base.appendingPathComponent("profile.json").path
        )
        let store = DocIndexStore(dbPath: docIndexPath)
        let document = try await store.upsertDocument(IndexedDocument(
            source: .files,
            externalID: "forced-doc",
            displayName: "forced-doc",
            mtime: Date(),
            contentHash: "hash-forced-doc",
            indexedAt: Date()
        ))
        _ = try await store.upsertChunks(
            documentID: document.id,
            chunks: [IndexedChunk(documentID: document.id, ordinal: 0, text: "harbor forcedlivetoken voyage manifest")]
        )
        try await engine.storeProfileFact(content: "harbor forcedlivetoken profile harbor master", source: "chat")

        // Baseline without the override keeps the indexed hit.
        let plainPlan = MemoryQueryRouter.plan(for: "harbor forcedlivetoken", currentDate: Date())
        #expect(plainPlan.skipDocIndex == false)
        let baseline = try await engine.recallMessage(
            for: "harbor forcedlivetoken",
            sessionID: UUID(),
            budgets: RecallBudgets(),
            plan: plainPlan
        )
        let baselineContent = baseline?.content ?? ""
        #expect(baselineContent.contains("forcedlivetoken"))
        #expect(baselineContent.contains("[docIndex]"))

        // Forced override down-weights docs to zero while profile still injects.
        await LiveSearchOverride.shared.setForced(true)
        var forcedContent = ""
        var forcedHasDoc = false
        do {
            let forcedPlan = MemoryQueryRouter.plan(for: "harbor forcedlivetoken", currentDate: Date())
            let forced = try await engine.recallMessage(
                for: "harbor forcedlivetoken",
                sessionID: UUID(),
                budgets: RecallBudgets(),
                plan: forcedPlan
            )
            forcedContent = forced?.content ?? ""
            forcedHasDoc = forcedContent.contains("[docIndex]")
        } catch {
            Issue.record("Forced recall threw: \(error)")
        }
        await LiveSearchOverride.shared.setForced(false)
        #expect(!forcedContent.isEmpty)
        #expect(forcedContent.contains("forcedlivetoken"))
        #expect(forcedHasDoc == false)
        #expect(forcedContent.contains("[profile]") || forcedContent.contains("[semantic]"))

        // Freshness wording with the override also injects profile without docs.
        await LiveSearchOverride.shared.setForced(true)
        var freshContent = ""
        var freshHasDoc = false
        do {
            let freshPlan = MemoryQueryRouter.plan(for: "today unread harbor forcedlivetoken", currentDate: Date())
            #expect(freshPlan.skipDocIndex == true)
            let fresh = try await engine.recallMessage(
                for: "today unread harbor forcedlivetoken",
                sessionID: UUID(),
                budgets: RecallBudgets(),
                plan: freshPlan
            )
            freshContent = fresh?.content ?? ""
            freshHasDoc = freshContent.contains("[docIndex]")
        } catch {
            Issue.record("Fresh forced recall threw: \(error)")
        }
        await LiveSearchOverride.shared.setForced(false)
        #expect(!freshContent.isEmpty)
        #expect(freshContent.contains("forcedlivetoken"))
        #expect(freshHasDoc == false)
    }

    @Test
    func `Cancelled embedding aborts automatic recall`() async throws {
        let (engine, base) = makeRecallInjectionEngine()
        defer { try? FileManager.default.removeItem(at: base) }
        do {
            _ = try await engine.recallMessage(
                for: "harbor cancel token",
                sessionID: UUID(),
                embedder: CancellingEmbedder(),
                budgets: RecallBudgets(),
                plan: nil
            )
            Issue.record("Expected CancellationError")
        } catch is CancellationError {
            // Cancel propagates instead of degrading to keyword fallback.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
    }

    @Test
    func `Starter pack shows profile plus index watermark`() {
        let profile = UserProfile(
            preferences: [Preference(key: "name", value: "Ada")],
            lastUpdated: Date(timeIntervalSince1970: 1_000_000)
        )
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let pack = RecallStarterPack.build(
            profile: profile,
            indexAsOf: stamp,
            goalLine: nil,
            budgets: RecallBudgets()
        )
        #expect(pack?.role == .system)
        let content = pack?.content ?? ""
        #expect(content.contains("Profile: Ada"))
        #expect(content.contains("Index as of: \(ISO8601DateFormatter().string(from: stamp))"))
        #expect(!content.contains("Goal:"))
        #expect(!content.contains(ContentTrustLabeler.banner))
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.count == 2)
        for line in lines {
            #expect(line.count < 200)
        }
        #expect(content.count < 600)
    }

    @Test
    func `Starter pack disabled shows disabled and empty yields nil`() {
        let named = UserProfile(preferences: [Preference(key: "name", value: "Ada")])
        let disabled = RecallStarterPack.build(
            profile: named,
            indexAsOf: nil,
            goalLine: nil,
            budgets: RecallBudgets()
        )
        #expect(disabled?.role == .system)
        #expect(disabled?.content.contains("Profile: Ada") == true)
        #expect(disabled?.content.contains("Index as of: disabled") == true)
        let empty = RecallStarterPack.build(
            profile: UserProfile.empty,
            indexAsOf: nil,
            goalLine: nil,
            budgets: RecallBudgets()
        )
        #expect(empty == nil)
        let emptyWithIndex = RecallStarterPack.build(
            profile: UserProfile.empty,
            indexAsOf: Date(timeIntervalSince1970: 1_700_000_000),
            goalLine: nil,
            budgets: RecallBudgets()
        )
        #expect(emptyWithIndex?.content.contains("Profile: none") == true)
        #expect(emptyWithIndex?.content.contains("Index as of: ") == true)
    }

    @Test
    func `Starter pack goal line is optional and bounds hold`() {
        let profile = UserProfile(preferences: [Preference(key: "name", value: "Ada")])
        let withGoal = RecallStarterPack.build(
            profile: profile,
            indexAsOf: nil,
            goalLine: "Finish harbor manifest",
            budgets: RecallBudgets()
        )
        #expect(withGoal?.content.contains("Goal: Finish harbor manifest") == true)
        #expect((withGoal?.content.count ?? 0) < 600)
        let long = RecallStarterPack.build(
            profile: UserProfile(preferences: [Preference(key: "name", value: String(repeating: "A", count: 500))]),
            indexAsOf: Date(timeIntervalSince1970: 1_700_000_000),
            goalLine: String(repeating: "G", count: 500),
            budgets: RecallBudgets()
        )
        let content = long?.content ?? ""
        #expect(!content.isEmpty)
        #expect(content.count < 600)
        for line in content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            #expect(line.count < 200)
        }
    }

    @Test
    func `recallWithDiagnostics mirrors recall hits with shape intact`() async throws {
        let (engine, base) = makeRecallInjectionEngine()
        defer { try? FileManager.default.removeItem(at: base) }
        try await engine.storeEpisodic(content: "The harbor master keeps brass compasses", sessionID: UUID())
        try await engine.storeProfileFact(content: "My dog is named Biscuit", source: "chat")
        let (hits, diagnostics) = try await engine.recallWithDiagnostics(query: "harbor Biscuit compasses", limit: 5)
        let direct = try await engine.recall(query: "harbor Biscuit compasses", limit: 5)
        #expect(hits.count == direct.count)
        #expect(diagnostics.hitIDs.count == hits.count)
        #expect(diagnostics.sources.count == hits.count)
        #expect(diagnostics.scores.count == hits.count)
        #expect(diagnostics.sources == hits.map(\.source.rawValue))
        #expect(diagnostics.scores == hits.map(\.score))
        #expect(diagnostics.injectedChars >= 0)
        // No document store in this fixture, so the index reads as skipped.
        #expect(diagnostics.skippedDocIndex == true)
    }

    @Test
    func `Diagnostics log line carries IDs plus scores and no content`() async throws {
        let (engine, base) = makeRecallInjectionEngine()
        defer { try? FileManager.default.removeItem(at: base) }
        try await engine.storeProfileFact(content: "My dog is named Biscuit", source: "chat")
        let (_, diagnostics) = try await engine.recallWithDiagnostics(query: "Biscuit dog name", limit: 5)
        #expect(!diagnostics.hitIDs.isEmpty)
        let line = Orchestrator.recallDiagnosticsLogLine(diagnostics)
        #expect(line.contains("hits="))
        #expect(line.contains("injectedChars="))
        #expect(line.contains("skippedDocIndex="))
        for id in diagnostics.hitIDs {
            #expect(line.contains(id))
        }
        for score in diagnostics.scores {
            #expect(line.contains("\(score)"))
        }
        // Content and secrets never enter the diagnostics line.
        #expect(!line.contains("Biscuit"))
        #expect(!line.contains("My dog is named"))
    }

    @Test
    func `Silent-nil recall still emits zero-hit diagnostics`() async throws {
        let (engine, base) = makeRecallInjectionEngine()
        defer { try? FileManager.default.removeItem(at: base) }
        let sessionID = UUID()
        let (emptyMessage, emptyDiagnostics) = try await engine.recallMessageWithDiagnostics(
            for: "   ",
            sessionID: sessionID,
            budgets: RecallBudgets()
        )
        #expect(emptyMessage == nil)
        #expect(emptyDiagnostics.hitIDs.isEmpty)
        #expect(emptyDiagnostics.sources.isEmpty)
        #expect(emptyDiagnostics.scores.isEmpty)
        #expect(emptyDiagnostics.injectedChars == 0)
        let emptyLine = Orchestrator.recallDiagnosticsLogLine(emptyDiagnostics)
        #expect(emptyLine.contains("hits=0"))
        #expect(emptyLine.contains("injectedChars=0"))
        // Below-threshold hits also surface as a zero-hit line.
        let weak = [MemoryResult(content: "unrelated aside", score: 0.01, source: .profile)]
        #expect(MemoryEngine.automaticRecallMessage(for: weak) == nil)
        let (weakMessage, weakDiagnostics) = try await engine.recallMessageWithDiagnostics(
            for: "quantum entanglement calibration xyzzy",
            sessionID: sessionID,
            budgets: RecallBudgets()
        )
        #expect(weakMessage == nil)
        #expect(weakDiagnostics.hitIDs.isEmpty)
        #expect(weakDiagnostics.injectedChars == 0)
    }
}

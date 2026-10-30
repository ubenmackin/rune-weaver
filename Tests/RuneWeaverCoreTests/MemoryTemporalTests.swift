// Rune Weaver Core Tests — Dated-window recall across episodic and indexed memory.

import Foundation
@testable import RuneWeaverCore
@testable import RuneWeaverTools
import Testing

/// Isolated engine plus stores sharing one temporary directory.
private func makeTemporalEngine() -> (engine: MemoryEngine, store: DocIndexStore, episodes: EpisodeStore, base: URL) {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let episodesPath = base.appendingPathComponent("episodes.db").path
    let docIndexPath = base.appendingPathComponent("docindex.db").path
    let engine = MemoryEngine(
        episodesDBPath: episodesPath,
        vectorDBPath: base.appendingPathComponent("vectors").path,
        docIndexDBPath: docIndexPath,
        profilePath: base.appendingPathComponent("profile.json").path
    )
    return (engine, DocIndexStore(dbPath: docIndexPath), EpisodeStore(dbPath: episodesPath), base)
}

/// July window bounds shared by the dated tests.
private func julyWindow() throws -> TemporalRange {
    try TemporalFilter.parse(since: "2026-07-01", until: "2026-08-01")
}

/// Mid-July instant safely inside the window.
private func julyMid() throws -> Date {
    let range = try TemporalFilter.parse(since: "2026-07-15", until: nil)
    return try #require(range.since)
}

/// Mid-August instant safely outside the July window.
private func augustMid() throws -> Date {
    let range = try TemporalFilter.parse(since: "2026-08-15", until: nil)
    return try #require(range.since)
}

/// Stores one document with a single chunk. Calendars rows gate the window.
@discardableResult
private func storeTemporalDoc(
    in store: DocIndexStore,
    source: IndexSource = .files,
    externalID: String,
    text: String,
    mtime: Date?,
    embedding: [Float] = []
) async throws -> IndexedDocument {
    let document = try await store.upsertDocument(IndexedDocument(
        source: source,
        externalID: externalID,
        displayName: externalID,
        mtime: mtime,
        contentHash: "hash-\(externalID)",
        indexedAt: Date()
    ))
    _ = try await store.upsertChunks(
        documentID: document.id,
        chunks: [IndexedChunk(documentID: document.id, ordinal: 0, text: text, embedding: embedding)]
    )
    return document
}

@Suite("Memory Temporal Window")
struct MemoryTemporalTests {
    @Test
    func `Recall args decode since until plus blank as omitted`() throws {
        let decoded = try JSONDecoder().decode(
            RecallMemoriesArgs.self,
            from: Data(#"{"query":"harbor","since":"2026-07-01","until":"2026-08-01"}"#.utf8)
        )
        #expect(decoded.query == "harbor")
        #expect(decoded.since == "2026-07-01")
        #expect(decoded.until == "2026-08-01")

        // Blank strings behave as omitted so whitespace-only bounds stay unbounded.
        let blank = try JSONDecoder().decode(
            RecallMemoriesArgs.self,
            from: Data(#"{"query":"harbor","since":"   ","until":""}"#.utf8)
        )
        #expect(blank.since == nil)
        #expect(blank.until == nil)

        let omitted = try JSONDecoder().decode(
            RecallMemoriesArgs.self,
            from: Data(#"{"query":"harbor"}"#.utf8)
        )
        #expect(omitted.since == nil)
        #expect(omitted.until == nil)

        // Memberwise init normalizes the same way so direct construction matches decoding.
        let direct = RecallMemoriesArgs(query: "harbor", since: "  ", until: nil)
        #expect(direct.since == nil)

        // Limits stay clamped while the window rides alongside.
        let clamped = try JSONDecoder().decode(
            RecallMemoriesArgs.self,
            from: Data(#"{"query":"hi","limit":500,"since":"2026-07-01"}"#.utf8)
        )
        #expect(clamped.limit == RecallMemoriesArgs.maxLimit)
        #expect(clamped.since == "2026-07-01")
    }

    @Test
    func `Inverted range rejects fail-closed`() throws {
        do {
            _ = try TemporalFilter.parse(since: "2026-08-01", until: "2026-07-01")
            Issue.record("Expected rejection for inverted range")
        } catch {
            let message = error.localizedDescription
            #expect(message.contains("since") && message.contains("until"))
        }
    }

    @Test
    func `Malformed bounds name the offending field`() throws {
        do {
            _ = try TemporalFilter.parse(since: "not-a-date", until: nil)
            Issue.record("Expected rejection for bad since")
        } catch {
            #expect(error.localizedDescription.contains("since"))
        }
        do {
            _ = try TemporalFilter.parse(since: nil, until: "yesterday")
            Issue.record("Expected rejection for bad until")
        } catch {
            #expect(error.localizedDescription.contains("until"))
        }
    }

    @Test
    func `Recall tool fails closed on malformed bounds`() async throws {
        let (engine, _, _, base) = makeTemporalEngine()
        defer { try? FileManager.default.removeItem(at: base) }
        let tool = RecallMemoriesTool(engine: engine)
        let badSince = try await tool.execute(
            input: ToolInput(toolName: "memories.recall", argumentsJSON: #"{"query":"harbor","since":"not-a-date"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(badSince.isError == true)
        #expect(badSince.content.contains("since"))
        let badUntil = try await tool.execute(
            input: ToolInput(toolName: "memories.recall", argumentsJSON: #"{"query":"harbor","until":"13-Sep-2026"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(badUntil.isError == true)
        #expect(badUntil.content.contains("until"))
        let inverted = try await tool.execute(
            input: ToolInput(toolName: "memories.recall", argumentsJSON: #"{"query":"harbor","since":"2026-08-01","until":"2026-07-01"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(inverted.isError == true)
        #expect(inverted.content.contains("since") && inverted.content.contains("until"))
    }

    @Test
    func `Recall schema advertises the dated window`() {
        let (engine, _, _, base) = makeTemporalEngine()
        defer { try? FileManager.default.removeItem(at: base) }
        let tool = RecallMemoriesTool(engine: engine)
        #expect(tool.inputSchema.rawValue.contains("since"))
        #expect(tool.inputSchema.rawValue.contains("until"))
        let lowered = tool.description.lowercased()
        #expect(lowered.contains("since") && lowered.contains("until"))
    }

    @Test
    func `Keyword path filters by mtime join`() async throws {
        let (_, store, _, base) = makeTemporalEngine()
        defer { try? FileManager.default.removeItem(at: base) }
        let window = try julyWindow()
        let july = try julyMid()
        let august = try augustMid()
        try await storeTemporalDoc(in: store, externalID: "july-doc", text: "harbor temporalwindowtoken july voyage", mtime: july)
        try await storeTemporalDoc(in: store, externalID: "august-doc", text: "harbor temporalwindowtoken august voyage", mtime: august)

        // Unbounded sees both months so the window is what excludes August.
        let unbounded = try await store.searchKeyword(query: "temporalwindowtoken harbor", limit: 10)
        #expect(unbounded.count == 2)

        // Bounded reads keep past files recallable; only calendars gate on mtime.
        let boundedFiles = try await store.searchKeyword(
            query: "temporalwindowtoken harbor",
            limit: 10,
            since: window.since,
            until: window.until
        )
        #expect(boundedFiles.count == 2)

        // Calendar occurrences gate strictly to [since, until).
        try await storeTemporalDoc(in: store, source: .calendars, externalID: "july-cal", text: "harbor calendarwindowtoken july voyage", mtime: july)
        try await storeTemporalDoc(in: store, source: .calendars, externalID: "august-cal", text: "harbor calendarwindowtoken august voyage", mtime: august)
        let unboundedCals = try await store.searchKeyword(query: "calendarwindowtoken", limit: 10)
        #expect(unboundedCals.count == 2)
        let julyOnly = try await store.searchKeyword(
            query: "calendarwindowtoken",
            limit: 10,
            since: window.since,
            until: window.until
        )
        #expect(julyOnly.count == 1)
        #expect(julyOnly.first?.text.contains("july") == true)
    }

    @Test
    func `Keyword fragment without fallback returns empty`() async throws {
        let (_, store, _, base) = makeTemporalEngine()
        defer { try? FileManager.default.removeItem(at: base) }
        let window = try julyWindow()
        let july = try julyMid()
        let august = try augustMid()
        // Interior fragments miss prefix BM25 and no table scan fills the gap.
        try await storeTemporalDoc(in: store, externalID: "july-frag", text: "hello world lighthouse beacon july", mtime: july)
        try await storeTemporalDoc(in: store, externalID: "august-frag", text: "hello world lighthouse beacon august", mtime: august)

        // Interior substrings only: LIKE would match, prefix BM25 must not.
        let unbounded = try await store.searchKeyword(query: "ello orld", limit: 10)
        #expect(unbounded.isEmpty)
        let bounded = try await store.searchKeyword(
            query: "ello orld",
            limit: 10,
            since: window.since,
            until: window.until
        )
        #expect(bounded.isEmpty)
    }

    @Test
    func `Vector pool filters by mtime`() async throws {
        let (_, store, _, base) = makeTemporalEngine()
        defer { try? FileManager.default.removeItem(at: base) }
        let window = try julyWindow()
        let july = try julyMid()
        let august = try augustMid()
        try await storeTemporalDoc(in: store, externalID: "july-vector", text: "archaic ledger july entry", mtime: july, embedding: [1.0, 0.0])
        try await storeTemporalDoc(in: store, externalID: "august-vector", text: "archaic ledger august entry", mtime: august, embedding: [1.0, 0.0])

        let unbounded = try await store.chunkVectors(limit: 10)
        #expect(unbounded.count == 2)

        let julyOnly = try await store.chunkVectors(limit: 10, since: window.since, until: window.until)
        #expect(julyOnly.count == 1)
        #expect(julyOnly.first?.text.contains("july") == true)
    }

    @Test
    func `NULL mtime excluded when bounded`() async throws {
        let (_, store, _, base) = makeTemporalEngine()
        defer { try? FileManager.default.removeItem(at: base) }
        let window = try julyWindow()
        let july = try julyMid()
        try await storeTemporalDoc(in: store, externalID: "dated", text: "harbor nullwindowtoken dated voyage", mtime: july)
        try await storeTemporalDoc(in: store, externalID: "undated", text: "harbor nullwindowtoken undated voyage", mtime: nil)

        // An unbounded query has no window to exclude from, so both rows match.
        let unbounded = try await store.searchKeyword(query: "nullwindowtoken harbor", limit: 10)
        #expect(unbounded.count == 2)

        // Files rows stay recallable without an event date under a bound.
        let bounded = try await store.searchKeyword(
            query: "nullwindowtoken harbor",
            limit: 10,
            since: window.since,
            until: window.until
        )
        #expect(bounded.count == 2)

        // Calendar rows without an event date cannot satisfy the window.
        try await storeTemporalDoc(in: store, source: .calendars, externalID: "dated-cal", text: "harbor nullcalendarwindowtoken dated voyage", mtime: july)
        try await storeTemporalDoc(in: store, source: .calendars, externalID: "undated-cal", text: "harbor nullcalendarwindowtoken undated voyage", mtime: nil)
        let unboundedCals = try await store.searchKeyword(query: "nullcalendarwindowtoken", limit: 10)
        #expect(unboundedCals.count == 2)
        let boundedCals = try await store.searchKeyword(
            query: "nullcalendarwindowtoken",
            limit: 10,
            since: window.since,
            until: window.until
        )
        #expect(boundedCals.count == 1)
        #expect(boundedCals.first?.text.contains("dated") == true)

        let boundedVectors = try await store.chunkVectors(limit: 10, since: window.since, until: window.until)
        // The dated row above is keyword-only, so the bounded vector pool holds
        // neither fixture row; the assertion pins exclusion rather than a count.
        #expect(boundedVectors.allSatisfy { !$0.text.contains("nullwindowtoken") })
    }

    @Test
    func `Episodic FTS filters by timestamp`() async throws {
        let (_, _, episodes, base) = makeTemporalEngine()
        defer { try? FileManager.default.removeItem(at: base) }
        let window = try julyWindow()
        let july = try julyMid()
        let august = try augustMid()
        try await episodes.store(Episode(sessionID: UUID(), role: .user, content: "harbor episodicmarker july voyage", timestamp: july))
        try await episodes.store(Episode(sessionID: UUID(), role: .user, content: "harbor episodicmarker august voyage", timestamp: august))

        let unbounded = try await episodes.search(query: "episodicmarker harbor", limit: 10)
        #expect(unbounded.count == 2)

        let julyOnly = try await episodes.search(
            query: "episodicmarker harbor",
            limit: 10,
            since: window.since,
            until: window.until
        )
        #expect(julyOnly.count == 1)
        #expect(julyOnly.first?.content.contains("july") == true)
    }

    @Test
    func `Episodic LIKE fallback filters by timestamp`() async throws {
        let (_, _, episodes, base) = makeTemporalEngine()
        defer { try? FileManager.default.removeItem(at: base) }
        let window = try julyWindow()
        let july = try julyMid()
        let august = try augustMid()
        try await episodes.store(Episode(sessionID: UUID(), role: .user, content: "hello world lighthouse beacon july", timestamp: july))
        try await episodes.store(Episode(sessionID: UUID(), role: .user, content: "hello world lighthouse beacon august", timestamp: august))

        // Fragment tokens miss the FTS index, proving the LIKE fallback carries the window.
        let julyOnly = try await episodes.search(
            query: "ello wor",
            limit: 10,
            since: window.since,
            until: window.until
        )
        #expect(julyOnly.count == 1)
        #expect(julyOnly.first?.content.contains("july") == true)
    }

    @Test
    func `July recall returns July-only with in-window dates`() async throws {
        let (engine, store, episodes, base) = makeTemporalEngine()
        defer { try? FileManager.default.removeItem(at: base) }
        let window = try julyWindow()
        let july = try julyMid()
        let august = try augustMid()
        // Calendar-scoped bounds keep past files recallable, so July-only uses calendars.
        try await storeTemporalDoc(in: store, source: .calendars, externalID: "july-recall", text: "harbor julyrecalltoken july festival", mtime: july)
        try await storeTemporalDoc(in: store, source: .calendars, externalID: "august-recall", text: "harbor julyrecalltoken august festival", mtime: august)
        try await episodes.store(Episode(sessionID: UUID(), role: .user, content: "harbor julyrecalltoken july harbor walk", timestamp: july))
        try await episodes.store(Episode(sessionID: UUID(), role: .user, content: "harbor julyrecalltoken august harbor walk", timestamp: august))

        let results = try await engine.recall(
            query: "harbor julyrecalltoken",
            limit: 10,
            since: window.since,
            until: window.until
        )
        #expect(!results.isEmpty)
        #expect(results.allSatisfy { !$0.content.contains("august") })
        #expect(results.contains { $0.content.contains("july") })
        // Document hits carry the event date inside the window, never the index time.
        let formatter = ISO8601DateFormatter()
        let lower = try #require(window.since)
        let upper = try #require(window.until)
        for result in results where result.source == .docIndex {
            let dateText = try #require(result.metadata["date"])
            let date = try #require(formatter.date(from: dateText))
            #expect(date >= lower && date < upper)
        }
    }

    @Test
    func `Calibration watermark caps unchanged plus unbounded preserves order`() async throws {
        let (engine, store, _, base) = makeTemporalEngine()
        defer { try? FileManager.default.removeItem(at: base) }
        let window = try julyWindow()
        let july = try julyMid()
        // Identical bodies isolate ordering to the recency prior.
        try await storeTemporalDoc(in: store, externalID: "older", text: "identical calibration body", mtime: july)
        try await storeTemporalDoc(in: store, externalID: "newer", text: "identical calibration body", mtime: july)

        let unbounded = await engine.recallDocuments(query: "identical calibration", limit: 10)
        let bounded = await engine.recallDocuments(
            query: "identical calibration",
            limit: 10,
            since: window.since,
            until: window.until
        )
        // The window filters before ranking, so both paths rank the same survivors.
        #expect(unbounded.count == 2)
        #expect(bounded.count == 2)
        #expect(unbounded.map(\.content) == bounded.map(\.content))
        for result in bounded {
            #expect(result.score >= 0 && result.score <= 1)
            #expect(result.metadata["index_as_of"] != nil)
            let watermark = try #require(result.metadata["index_as_of"])
            #expect(ISO8601DateFormatter().date(from: watermark) != nil)
        }

        // Per-tier caps still bound the page: one slot returns one hit.
        let capped = await engine.recallDocuments(
            query: "identical calibration",
            limit: 1,
            since: window.since,
            until: window.until
        )
        #expect(capped.count == 1)
    }

    @Test
    func `July vacation auto-recall is windowed to July`() async throws {
        let (engine, store, episodes, base) = makeTemporalEngine()
        defer { try? FileManager.default.removeItem(at: base) }
        let window = try julyWindow()
        let july = try julyMid()
        let august = try augustMid()
        // Calendar-scoped bounds keep past files recallable, so July-only uses calendars.
        try await storeTemporalDoc(in: store, source: .calendars, externalID: "july-vacation", text: "harbor julyvacationtoken july vacation festival", mtime: july)
        try await storeTemporalDoc(in: store, source: .calendars, externalID: "august-vacation", text: "harbor julyvacationtoken august vacation festival", mtime: august)
        try await episodes.store(Episode(sessionID: UUID(), role: .user, content: "harbor julyvacationtoken july vacation walk", timestamp: july))
        try await episodes.store(Episode(sessionID: UUID(), role: .user, content: "harbor julyvacationtoken august vacation walk", timestamp: august))

        let currentDate = try julyMid()
        let plan = MemoryQueryRouter.plan(for: "July vacation julyvacationtoken", currentDate: currentDate)
        #expect(plan.since == window.since)
        #expect(plan.until == window.until)
        #expect(plan.skipDocIndex == false)

        let message = try await engine.recallMessage(
            for: "July vacation julyvacationtoken",
            sessionID: UUID(),
            budgets: RecallBudgets(),
            plan: plan
        )
        let content = try #require(message?.content)
        #expect(content.contains("july"))
        #expect(!content.contains("august"))
    }
}

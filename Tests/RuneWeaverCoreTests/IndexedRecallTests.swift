// Rune Weaver Core Tests — Hybrid document-index recall: merge, rerank, watermark, live fallback.
//
// Exercises the MemoryEngine document-index retrieval path end to end against
// isolated temporary databases: the keyword/vector candidate union, deterministic
// reranking, index-watermark propagation, and the live-tool guidance plus runtime
// override that steer freshness-sensitive queries away from the durable index.
// Tests never touch the real `~/.runeweaver/memory` stores.

import Foundation
@testable import RuneWeaverCore
import Testing

/// Builds an engine that shares one isolated document index with the test.
/// - Returns: The engine, a store over the same database, and the base directory to remove.
private func makeIndexedRecallEngine() -> (engine: MemoryEngine, store: DocIndexStore, base: URL) {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let docIndexPath = base.appendingPathComponent("docindex.db").path
    let engine = MemoryEngine(
        episodesDBPath: base.appendingPathComponent("episodes.db").path,
        vectorDBPath: base.appendingPathComponent("vectors").path,
        docIndexDBPath: docIndexPath,
        profilePath: base.appendingPathComponent("profile.json").path
    )
    return (engine, DocIndexStore(dbPath: docIndexPath), base)
}

/// Stores one document with a single chunk and returns the persisted document.
/// - Parameters:
///   - store: Document index to write through.
///   - externalID: Source-scoped identifier.
///   - text: Chunk body text.
///   - embedding: Chunk embedding; empty stores a keyword-only chunk.
///   - indexedAt: Revision timestamp driving the index watermark.
/// - Returns: The persisted document, including its stable identifier.
@discardableResult
private func storeChunk(
    in store: DocIndexStore,
    externalID: String,
    text: String,
    embedding: [Float] = [],
    indexedAt: Date = Date()
) async throws -> IndexedDocument {
    let document = try await store.upsertDocument(IndexedDocument(
        source: .files,
        externalID: externalID,
        displayName: externalID,
        contentHash: "hash-\(externalID)",
        indexedAt: indexedAt
    ))
    _ = try await store.upsertChunks(
        documentID: document.id,
        chunks: [IndexedChunk(documentID: document.id, ordinal: 0, text: text, embedding: embedding)]
    )
    return document
}

@Suite("Indexed Recall")
struct IndexedRecallTests {
    @Test
    func `Document recall unions keyword and vector candidates`() async throws {
        let (engine, store, base) = makeIndexedRecallEngine()
        defer { try? FileManager.default.removeItem(at: base) }

        // Keyword-only chunk: shares the query token but carries no embedding,
        // so only the FTS5 path can surface it.
        try await storeChunk(in: store, externalID: "keyword", text: "sourdough starter feeding schedule")
        // Vector-only chunk: no query-token overlap, but it points along the
        // query embedding axis, so only the cosine path can surface it.
        try await storeChunk(in: store, externalID: "vector", text: "zeta quantum ledger", embedding: [1.0, 0.0])

        let results = await engine.recallDocuments(query: "sourdough", embedding: [1.0, 0.0], limit: 10)
        #expect(!results.isEmpty)
        #expect(results.allSatisfy { $0.source == .docIndex })
        #expect(results.contains { $0.content.contains("sourdough") })
        #expect(results.contains { $0.content.contains("zeta") })
    }

    @Test
    func `Document recall prefers the more recent chunk on equal signals`() async throws {
        let (engine, store, base) = makeIndexedRecallEngine()
        defer { try? FileManager.default.removeItem(at: base) }

        // Identical bodies and embeddings: only the newest-first recency prior
        // separates them, so the later-inserted row must rank first.
        let older = try await storeChunk(in: store, externalID: "older", text: "identical body", embedding: [1.0, 0.0])
        let newer = try await storeChunk(in: store, externalID: "newer", text: "identical body", embedding: [1.0, 0.0])

        let results = await engine.recallDocuments(query: "unrelated phrase", embedding: [1.0, 0.0], limit: 10)
        #expect(results.count == 2)
        #expect(results.first?.metadata["document_id"] == newer.id.uuidString)
        #expect(results.last?.metadata["document_id"] == older.id.uuidString)
    }

    @Test
    func `Document recall reranks an exact name above a topical near-match`() async throws {
        let (engine, store, base) = makeIndexedRecallEngine()
        defer { try? FileManager.default.removeItem(at: base) }

        // Identical embeddings keep the retrieval base equal, so only the
        // token-overlap and exact-name terms can separate the two chunks: the
        // one carrying the literal file name must win over the near-match.
        try await storeChunk(in: store, externalID: "exact", text: "quarterly notes.md summary", embedding: [1.0, 0.0])
        try await storeChunk(in: store, externalID: "topical", text: "quarterly summary of the plan", embedding: [1.0, 0.0])

        let results = await engine.recallDocuments(query: "quarterly notes.md", embedding: [1.0, 0.0], limit: 10)
        #expect(results.count == 2)
        #expect(results.first?.content.contains("notes.md") == true)
        #expect(results.contains { $0.content.contains("quarterly summary") })
    }

    @Test
    func `Document recall stamps the index watermark on every hit`() async throws {
        let (engine, store, base) = makeIndexedRecallEngine()
        defer { try? FileManager.default.removeItem(at: base) }
        let stamped = Date(timeIntervalSince1970: 5000)
        try await storeChunk(in: store, externalID: "watermark", text: "biscuit recipe card", indexedAt: stamped)

        let results = await engine.recallDocuments(query: "biscuit", limit: 5)
        #expect(!results.isEmpty)
        let watermarks = results.compactMap { $0.metadata["index_as_of"] }
        #expect(watermarks.count == results.count)
        for watermark in watermarks {
            #expect(ISO8601DateFormatter().date(from: watermark) != nil)
        }
        // The watermark reports the last write, not the recall time, so a
        // stale index never claims to be current.
        let expected = ISO8601DateFormatter().string(from: stamped)
        #expect(watermarks.allSatisfy { $0 == expected })

        // The merged recall carries the same watermark so callers can surface
        // how fresh the indexed answer is.
        let merged = try await engine.recall(query: "biscuit", limit: 5)
        #expect(merged.contains { $0.metadata["index_as_of"] != nil })
    }

    @Test
    func `Document recall keeps recent vectors visible in a bounded pool`() async throws {
        let (engine, store, base) = makeIndexedRecallEngine()
        defer { try? FileManager.default.removeItem(at: base) }

        // The oldest vector shares no query tokens, so only the bounded
        // newest-first pool can decide whether the recent write is seen.
        try await storeChunk(
            in: store,
            externalID: "old-vector",
            text: "archaic ledger entry",
            embedding: [1.0, 0.0]
        )
        try await storeChunk(
            in: store,
            externalID: "new-vector",
            text: "recent ledger entry",
            embedding: [1.0, 0.0]
        )

        // A pool of one must hold the newest row; an oldest-first scan would
        // return only the archaic entry here.
        let newestOnly = try await store.chunkVectors(limit: 1)
        #expect(newestOnly.count == 1)
        #expect(newestOnly.first?.text.contains("recent") == true)

        let results = await engine.recallDocuments(query: "ledger", embedding: [1.0, 0.0], limit: 10)
        #expect(results.contains { $0.content.contains("recent") })
    }

    @Test
    func `Vector path failure still returns keyword hits`() async throws {
        let (engine, store, base) = makeIndexedRecallEngine()
        defer { try? FileManager.default.removeItem(at: base) }
        try await storeChunk(in: store, externalID: "keyword", text: "compass calibration notes")
        try await storeChunk(in: store, externalID: "vector", text: "unrelated ledger", embedding: [1.0, 0.0])

        // A dimension-mismatched query embedding makes every cosine score zero;
        // the keyword read must still surface its chunk rather than failing.
        let mismatched = await engine.recallDocuments(query: "compass", embedding: [1.0, 0.0, 0.0], limit: 5)
        #expect(mismatched.contains { $0.content.contains("compass") })

        // A nil embedding takes the same keyword-only path.
        let keywordOnly = await engine.recallDocuments(query: "compass", embedding: nil, limit: 5)
        #expect(keywordOnly.contains { $0.content.contains("compass") })
    }

    @Test
    func `Document recall never fails a turn without a configured index`() async {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let engine = MemoryEngine(
            episodesDBPath: base.appendingPathComponent("episodes.db").path,
            vectorDBPath: base.appendingPathComponent("vectors").path,
            profilePath: base.appendingPathComponent("profile.json").path
        )

        let results = await engine.recallDocuments(query: "anything at all", limit: 5)
        #expect(results.isEmpty)
    }

    @Test
    func `Freshness-sensitive queries prefer the live path`() async {
        #expect(LiveSearchGuidance.prefersLiveSearch(for: "what arrived today?"))
        #expect(LiveSearchGuidance.prefersLiveSearch(for: "anything unread from last night?"))
        #expect(LiveSearchGuidance.prefersLiveSearch(for: "the just-arrived invoice"))
        #expect(LiveSearchGuidance.prefersLiveSearch(for: "what is the latest status?"))
        #expect(LiveSearchGuidance.prefersLiveSearch(for: "summarize my this morning mail"))
        #expect(!LiveSearchGuidance.prefersLiveSearch(for: "what is my sourdough recipe?"))

        let override = LiveSearchOverride()
        #expect(await override.isForced() == false)
        #expect(await override.shouldUseLiveSearch(for: "what arrived today?") == true)
        #expect(await override.shouldUseLiveSearch(for: "sourdough recipe") == false)

        // The runtime flag forces the live path regardless of query wording.
        await override.setForced(true)
        #expect(await override.isForced() == true)
        #expect(await override.shouldUseLiveSearch(for: "sourdough recipe") == true)

        await override.setForced(false)
        #expect(await override.shouldUseLiveSearch(for: "sourdough recipe") == false)
    }

    @Test
    func `Composed prompt carries index freshness guidance and the force-live flag`() {
        let prompt = SystemPromptComposer.compose(tools: [])
        let lowered = prompt.lowercased()
        #expect(lowered.contains("current as of last night"))
        #expect(lowered.contains("today"))
        #expect(lowered.contains("latest"))
        #expect(lowered.contains("unread"))
        #expect(lowered.contains("just-arrived"))
        #expect(prompt.contains("email.search"))
        #expect(prompt.contains("files.grep"))
        #expect(prompt.contains(LiveSearchGuidance.forceLiveFlagName))
    }

    @Test
    func `Document recall enriches hit metadata with display name, path, and source`() async throws {
        let (engine, store, base) = makeIndexedRecallEngine()
        defer { try? FileManager.default.removeItem(at: base) }

        let doc = IndexedDocument(
            source: .files,
            externalID: "bills.numbers",
            displayName: "bills.numbers",
            path: "/Users/alice/Desktop/bills.numbers",
            contentHash: "hash-bills",
            indexedAt: Date()
        )
        let stored = try await store.upsertDocument(doc)
        _ = try await store.upsertChunks(documentID: stored.id, chunks: [
            IndexedChunk(documentID: stored.id, ordinal: 0, text: "Electricity $120 Paid Water $45 Unpaid")
        ])

        let results = await engine.recallDocuments(query: "Electricity bills", limit: 5)
        #expect(!results.isEmpty)
        let hit = try #require(results.first)
        #expect(hit.metadata["display_name"] == "bills.numbers")
        #expect(hit.metadata["path"] == "/Users/alice/Desktop/bills.numbers")
        #expect(hit.metadata["document_source"] == "files")
    }

    @Test
    func `Document recall round-trips event dates from mtime`() async throws {
        let (engine, store, base) = makeIndexedRecallEngine()
        defer { try? FileManager.default.removeItem(at: base) }

        // A 2019 event long predates the index write, so the hit must carry
        // event time rather than the snapshot watermark; otherwise
        // when-questions would answer with the index time.
        let mtime2019 = Date(timeIntervalSince1970: 1_546_300_800)
        // Truncated to whole seconds because the persisted timestamp plus the
        // second-precision ISO8601 rendering cannot preserve sub-second
        // fractions; without this the round-trip would look flaky.
        let recentMtime = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))

        let stored2019 = try await store.upsertDocument(IndexedDocument(
            source: .messages,
            externalID: "msg-2019",
            displayName: "msg-2019",
            messageID: "msg-2019",
            mailbox: "chat-thread-1",
            mtime: mtime2019,
            contentHash: "hash-msg-2019",
            indexedAt: Date()
        ))
        _ = try await store.upsertChunks(documentID: stored2019.id, chunks: [
            IndexedChunk(documentID: stored2019.id, ordinal: 0, text: "lantern festival reunion photographs")
        ])

        let storedRecent = try await store.upsertDocument(IndexedDocument(
            source: .messages,
            externalID: "msg-recent",
            displayName: "msg-recent",
            messageID: "msg-recent",
            mailbox: "chat-thread-1",
            mtime: recentMtime,
            contentHash: "hash-msg-recent",
            indexedAt: Date()
        ))
        _ = try await store.upsertChunks(documentID: storedRecent.id, chunks: [
            IndexedChunk(documentID: storedRecent.id, ordinal: 0, text: "harbor picnic seating chart")
        ])

        // No mtime means unknown event time, so the hit must omit the key
        // entirely rather than emitting an empty or epoch value; callers use
        // absence to distinguish unknown from known.
        let storedUndated = try await store.upsertDocument(IndexedDocument(
            source: .messages,
            externalID: "msg-undated",
            displayName: "msg-undated",
            messageID: "msg-undated",
            mailbox: "chat-thread-1",
            contentHash: "hash-msg-undated",
            indexedAt: Date()
        ))
        _ = try await store.upsertChunks(documentID: storedUndated.id, chunks: [
            IndexedChunk(documentID: storedUndated.id, ordinal: 0, text: "undated field sketch notebook")
        ])

        let formatter = ISO8601DateFormatter()
        let hits2019 = await engine.recallDocuments(query: "lantern", limit: 5)
        let hit2019 = try #require(hits2019.first { $0.metadata["document_id"] == stored2019.id.uuidString })
        #expect(hit2019.metadata["date"] == formatter.string(from: mtime2019))

        let hitsRecent = await engine.recallDocuments(query: "picnic", limit: 5)
        let hitRecent = try #require(hitsRecent.first { $0.metadata["document_id"] == storedRecent.id.uuidString })
        #expect(hitRecent.metadata["date"] == formatter.string(from: recentMtime))

        let hitsUndated = await engine.recallDocuments(query: "sketch", limit: 5)
        let hitUndated = try #require(hitsUndated.first { $0.metadata["document_id"] == storedUndated.id.uuidString })
        #expect(hitUndated.metadata["date"] == nil)
    }
}

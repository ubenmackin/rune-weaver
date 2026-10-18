// Rune Weaver Core — Semantic answer cache for repeated pure Q&A turns.

import Foundation

/// One cached answer plus the instant it was filed.
public struct CachedAnswer: Sendable, Equatable {
    /// Full assistant text replayed on a hit.
    public let text: String
    /// When the answer was filed, driving the expiry check.
    public let storedAt: Date

    /// Creates a cached answer stamped at the current instant by default.
    public init(text: String, storedAt: Date = Date()) {
        self.text = text
        self.storedAt = storedAt
    }
}

/// In-memory cache of pure assistant answers keyed by query, persona, and model.
public actor SemanticAnswerCache {
    /// Minimum similarity a near-duplicate question must reach to hit.
    public static let similarityThreshold = 0.92
    /// Entry lifetime; a lookup past this age misses and drops the entry.
    public static let timeToLive: TimeInterval = 24 * 60 * 60
    /// Maximum retained entries; the oldest evict first past this count.
    public static let maxEntries = 500
    /// Maximum characters in a storable answer.
    public static let maxAnswerChars = 2000

    /// Source label marking a transcribed voice prompt.
    private static let voiceSource = "voice"

    /// One retained answer with the material similarity matching needs.
    private struct Entry: Sendable {
        let answer: CachedAnswer
        let embedding: [Float]
        let queryTokens: Set<String>
    }

    /// Composite key: normalized query plus persona plus model identifier.
    private struct Key: Hashable, Sendable {
        let normalizedQuery: String
        let persona: String
        let modelID: String
    }

    /// Retained entries keyed by their composite identity.
    private var entries: [Key: Entry] = [:]
    /// Optional embeddings producer for the vector similarity path.
    private let embedder: any EmbeddingsBackend?

    /// Creates a cache, optionally scoring through an embeddings backend.
    /// - Parameter embedder: Backend serving vector similarity; nil keeps the
    ///   keyword-overlap path.
    public init(embedder: any EmbeddingsBackend? = nil) {
        self.embedder = embedder
    }

    /// Retained entry count, for diagnostics and tests.
    public var entryCount: Int {
        entries.count
    }

    /// Normalizes query text into the shared cache key form.
    public static func normalizedQuery(_ text: String) -> String {
        let folded = NormalizedText.splitLines(text).joined(separator: " ")
        let collapsed = folded.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed.lowercased()
    }

    /// Whether a turn is excluded from the cache entirely. Excluding them at the turn boundary is
    /// what makes "never store" imply "never hit": an excluded turn files nothing, so no later
    /// lookup can match its text.
    public static func isExcludedTurn(source: String?, executedToolCalls: Int, isParked: Bool = false) -> Bool {
        if isParked {
            return true
        }
        if Orchestrator.isBackgroundSource(source) {
            return true
        }
        if source == voiceSource {
            return true
        }
        return executedToolCalls > 0
    }

    /// Looks up one cached answer for a normalized question.
    public func lookup(normalizedQuery: String, persona: String, modelID: String) async -> CachedAnswer? {
        let query = Self.normalizedQuery(normalizedQuery)
        guard !query.isEmpty else { return nil }
        pruneExpired()
        if let entry = entries[Key(normalizedQuery: query, persona: persona, modelID: modelID)] {
            return entry.answer
        }
        let queryTokens = Self.salientTokens(of: query)
        guard !queryTokens.isEmpty else { return nil }
        let queryEmbedding = await embedText(query)
        var best: CachedAnswer?
        var bestScore = 0.0
        for (key, entry) in entries where key.persona == persona && key.modelID == modelID {
            guard let score = Self.score(queryTokens: queryTokens, queryEmbedding: queryEmbedding, entry: entry), score > bestScore else { continue }
            best = entry.answer
            bestScore = score
        }
        guard bestScore >= Self.similarityThreshold else { return nil }
        return best
    }

    /// Files one pure answer for a normalized question. The query embeds best-effort: an
    /// unavailable or cancelled embedding degrades the entry to keyword similarity instead of
    /// dropping an answer the turn already produced.
    public func storeAnswer(normalizedQuery: String, persona: String, modelID: String, answer: CachedAnswer) async {
        let query = Self.normalizedQuery(normalizedQuery)
        guard !query.isEmpty else { return }
        let text = answer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= Self.maxAnswerChars else { return }
        let embedding = await embedText(query)
        entries[Key(normalizedQuery: query, persona: persona, modelID: modelID)] = Entry(
            answer: CachedAnswer(text: text, storedAt: answer.storedAt),
            embedding: embedding,
            queryTokens: Self.salientTokens(of: query)
        )
        evictOverflow()
    }

    /// Clears every entry because a durable memory write can change answers.
    public func invalidateOnMemoryWrite() async {
        entries.removeAll()
    }

    /// Scores one entry against the query, or nil when there is no match basis.
    private static func score(queryTokens: Set<String>, queryEmbedding: [Float], entry: Entry) -> Double? {
        if !queryEmbedding.isEmpty, !entry.embedding.isEmpty, queryEmbedding.count == entry.embedding.count {
            let cosine = cosineSimilarity(queryEmbedding, entry.embedding)
            if cosine.isFinite {
                return max(0.0, cosine)
            }
        }
        let union = queryTokens.union(entry.queryTokens)
        guard !union.isEmpty else { return nil }
        let overlap = queryTokens.intersection(entry.queryTokens).count
        guard overlap > 0 else { return nil }
        return Double(overlap) / Double(union.count)
    }

    /// Cosine similarity between two equal-width vectors, zero when degenerate.
    private static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Double {
        var dot: Double = 0
        var lhsMagnitude: Double = 0
        var rhsMagnitude: Double = 0
        for index in lhs.indices {
            let left = Double(lhs[index])
            let right = Double(rhs[index])
            dot += left * right
            lhsMagnitude += left * left
            rhsMagnitude += right * right
        }
        guard lhsMagnitude > 0, rhsMagnitude > 0 else { return 0 }
        return dot / (lhsMagnitude.squareRoot() * rhsMagnitude.squareRoot())
    }

    /// Salient tokens for keyword similarity, single-sourced from the shared tokenizer.
    private static func salientTokens(of query: String) -> Set<String> {
        Set(Tokenization.salientTokens(from: query))
    }

    /// Embeds text best-effort, degrading to no vector on any failure.
    private func embedText(_ text: String) async -> [Float] {
        guard let embedder else { return [] }
        do {
            let vector = try await embedder.embedQuery(text)
            return vector ?? []
        } catch {
            return []
        }
    }

    /// Drops entries past the TTL so expiry reads as a miss, not a stale hit.
    private func pruneExpired() {
        let cutoff = Date().addingTimeInterval(-Self.timeToLive)
        entries = entries.filter { _, entry in entry.answer.storedAt > cutoff }
    }

    /// Evicts the oldest entries once the store passes its cap.
    private func evictOverflow() {
        guard entries.count > Self.maxEntries else { return }
        let overflow = entries.count - Self.maxEntries
        let oldest = entries
            .sorted { lhs, rhs in
                if lhs.value.answer.storedAt != rhs.value.answer.storedAt {
                    return lhs.value.answer.storedAt < rhs.value.answer.storedAt
                }
                return lhs.key.normalizedQuery < rhs.key.normalizedQuery
            }
            .prefix(overflow)
        for (key, _) in oldest {
            entries.removeValue(forKey: key)
        }
    }
}

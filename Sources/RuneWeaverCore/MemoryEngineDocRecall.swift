// Rune Weaver Core — Document-aware recall for the three-tier memory engine.
//
// Combines episodic, semantic, document-index, and profile hits onto one
// calibrated scale so chat turns see files, mail, and facts together. The FTS5
// keyword path and the cosine path over stored chunk embeddings are unioned
// newest-first, reranked with token overlap, recency, and exact name bonuses,
// and stamped with the MAX(indexed_at) watermark. Keyword-only fallback keeps
// retrieval alive when embeddings are missing, and cancellation propagates
// instead of degrading.

import Foundation

// MARK: - MemoryEngine Combined Recall

public extension MemoryEngine {
    /// Recalls across episodic, semantic, document-index, and profile tiers.
    func recall(query: String, embedding: [Float]? = nil, limit: Int = 10) async throws -> [MemoryResult] {
        guard limit > 0 else { return [] }
        let perTier = min(limit, Self.maxPerTierResults)
        let episodic = try await searchEpisodes(query: query, limit: perTier)
        let semanticRaw = await querySemantic(query: query, embedding: embedding ?? [], limit: perTier)
        let semantic: [MemoryResult] = if (embedding ?? []).isEmpty {
            semanticRaw.map { Self.normalizedSemantic($0) }
        } else {
            semanticRaw
        }
        let profile = profileResults(query: query, limit: perTier)
        let docIndex = await recallDocuments(query: query, embedding: embedding, limit: perTier)
        let merged = episodic + semantic + docIndex + profile
        let calibrated = merged.map { Self.calibrated($0) }
        let sorted = calibrated.sorted(by: Self.recallOrder)
        // `perTier` is capped at `maxPerTierResults` (1000) above, so
        // `perTier * 4` cannot overflow.
        let cap = perTier * 4
        return Array(Self.dedupe(sorted).prefix(cap))
    }

    /// Recalls document-index chunks by unioning keyword and vector candidates.
    ///
    /// The FTS5 keyword path and the cosine path over stored chunk embeddings
    /// are merged onto the shared calibrated recall scale and reranked with a
    /// token-overlap term, a recency prior, and an exact name-or-path bonus. A
    /// missing query embedding or a failed vector read still returns the
    /// keyword hits, so retrieval never fails a turn. The vector scan is a
    /// bounded newest-first pool, so recent writes stay visible at scale.
    /// - Parameters:
    ///   - query: Raw user query.
    ///   - embedding: Query embedding for the vector path, or nil for keyword-only.
    ///   - limit: Maximum chunk results.
    /// - Returns: Calibrated doc-index results carrying the index watermark.
    func recallDocuments(
        query: String,
        embedding: [Float]? = nil,
        limit: Int = 5
    ) async -> [MemoryResult] {
        guard limit > 0, let docIndexStore else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let clamped = min(limit, Self.maxPerTierResults)
        // Keep the vector scan wider than the returned page so a strong
        // semantic match is not crowded out by keyword hits. The store caps
        // the pool to the newest rows, keeping recent writes visible at scale.
        let pool = min(max(clamped * Self.docIndexCandidateMultiplier, clamped), Self.maxPerTierResults)
        let keyword = await (try? docIndexStore.searchKeyword(query: trimmed, limit: pool)) ?? []
        let vectors = await (try? docIndexStore.chunkVectors(limit: pool)) ?? []
        let queryEmbedding = (embedding?.isEmpty == false) ? embedding : nil
        let candidates = Self.docIndexCandidates(keyword: keyword, vectors: vectors, queryEmbedding: queryEmbedding)
        guard !candidates.isEmpty else { return [] }
        let stats = try? await docIndexStore.stats()
        let docIDs = Set(candidates.map(\.chunk.documentID))
        let documents = await (try? docIndexStore.documents(ids: docIDs)) ?? [:]
        let ranked = Self.rankedDocIndexResults(
            candidates,
            query: trimmed,
            queryTokens: Tokenization.tokenize(trimmed),
            documents: documents,
            indexAsOf: stats?.indexAsOf
        )
        return Array(ranked.prefix(clamped))
    }
}

// MARK: - MemoryEngine Recall Helpers

extension MemoryEngine {
    /// Keyword matches against profile facts and preferences.
    private func profileResults(query: String, limit: Int) -> [MemoryResult] {
        guard limit > 0 else { return [] }
        let queryTokens = Tokenization.tokenize(query)
        guard !queryTokens.isEmpty else { return [] }
        var results: [MemoryResult] = []
        for fact in profile.facts {
            let contentTokens = Tokenization.tokenize(fact.content)
            guard let raw = Tokenization.keywordScore(
                queryTokens: queryTokens,
                contentTokens: contentTokens,
                content: fact.content,
                query: query
            ) else { continue }
            results.append(MemoryResult(
                content: fact.content,
                score: min(max((Double(raw) / 10.0) * max(fact.confidence, 0.1), 0.0), 1.0),
                source: .profile,
                metadata: ["id": fact.id.uuidString, "confidence": "\(fact.confidence)"]
            ))
        }
        for preference in profile.preferences {
            let haystack = "\(preference.key) \(preference.value)"
            let contentTokens = Tokenization.tokenize(haystack)
            guard let raw = Tokenization.keywordScore(
                queryTokens: queryTokens,
                contentTokens: contentTokens,
                content: haystack,
                query: query
            ) else { continue }
            results.append(MemoryResult(
                content: "\(preference.key): \(preference.value)",
                score: min(max((Double(raw) / 10.0) * max(preference.confidence, 0.1), 0.0), 1.0),
                source: .profile,
                metadata: ["key": preference.key, "value": preference.value]
            ))
        }
        return Array(results.sorted { $0.score > $1.score }.prefix(limit))
    }

    /// Weight mapping episodic rank scores onto the shared recall scale.
    private static let episodicTierWeight = 0.25

    /// Weight for semantic hits on the shared recall scale.
    private static let semanticTierWeight = 1.0

    /// Weight for document-index hits on the shared recall scale.
    private static let docIndexTierWeight = 1.0

    /// Weight for profile hits on the shared recall scale.
    private static let profileTierWeight = 1.0

    /// Applies the tier weight for a recall hit's source.
    private static func calibrated(_ result: MemoryResult) -> MemoryResult {
        let weight: Double = switch result.source {
        case .episodic: Self.episodicTierWeight
        case .semantic: Self.semanticTierWeight
        case .docIndex: Self.docIndexTierWeight
        case .profile: Self.profileTierWeight
        }
        return MemoryResult(
            content: result.content,
            score: min(max(result.score * weight, 0.0), 1.0),
            source: result.source,
            metadata: result.metadata
        )
    }

    /// Normalizes a keyword semantic hit to the shared `[0, 1]` recall scale.
    private static func normalizedSemantic(_ result: MemoryResult) -> MemoryResult {
        MemoryResult(
            content: result.content,
            score: min(max(result.score / 10.0, 0.0), 1.0),
            source: result.source,
            metadata: result.metadata
        )
    }

    /// Priority for tie-breaking merged recall hits.
    private static func sourcePriority(_ source: MemorySource) -> Int {
        switch source {
        case .profile: 3
        case .semantic: 2
        case .docIndex: 1
        case .episodic: 0
        }
    }

    /// Orders merged recall hits by score, then tier priority, then doc-chunk identity.
    private static func recallOrder(_ lhs: MemoryResult, _ rhs: MemoryResult) -> Bool {
        if lhs.score != rhs.score {
            return lhs.score > rhs.score
        }
        let lhsPriority = sourcePriority(lhs.source)
        let rhsPriority = sourcePriority(rhs.source)
        if lhsPriority != rhsPriority {
            return lhsPriority > rhsPriority
        }
        if lhs.source == .docIndex, rhs.source == .docIndex {
            return docIndexResultOrder(lhs, rhs)
        }
        return false
    }

    /// One document-index candidate gathered from the keyword and vector paths.
    private struct DocIndexCandidate: Sendable {
        /// Chunk payload returned by the store.
        let chunk: IndexedChunk
        /// Rank-normalized keyword score in `(0, 1]`, zero when keyword-absent.
        let keywordScore: Double
        /// Cosine similarity in `[0, 1]`, zero when vector-absent.
        let vectorScore: Double
        /// Newest-first position in the union, driving the recency prior.
        let order: Int
    }

    /// Extra vector candidates scanned per returned page.
    private static let docIndexCandidateMultiplier = 4

    /// Base retrieval weight in the doc-index rerank, leaving room for bonuses.
    private static let docIndexBaseWeight = 0.6

    /// Keyword-overlap weight in the doc-index rerank.
    private static let docIndexOverlapWeight = 0.2

    /// Recency-prior weight in the doc-index rerank.
    private static let docIndexRecencyWeight = 0.1

    /// Exact name-or-path bonus in the doc-index rerank.
    private static let docIndexExactMatchWeight = 0.1

    /// Unions keyword and vector candidates into one newest-first list.
    ///
    /// Vector chunks arrive newest-first from the bounded store pool, so they
    /// keep that order before the keyword-only hits are appended. The resulting
    /// position is the recency prior because both reads break ties toward newer rows.
    private static func docIndexCandidates(
        keyword: [IndexedChunk],
        vectors: [IndexedChunk],
        queryEmbedding: [Float]?
    ) -> [DocIndexCandidate] {
        var keywordRanks: [UUID: Int] = [:]
        for (rank, chunk) in keyword.enumerated() where keywordRanks[chunk.id] == nil {
            keywordRanks[chunk.id] = rank + 1
        }
        func keywordScore(for chunk: IndexedChunk) -> Double {
            guard let rank = keywordRanks[chunk.id] else { return 0 }
            return 1.0 / Double(rank)
        }
        var candidates: [DocIndexCandidate] = []
        if let queryEmbedding, !queryEmbedding.isEmpty {
            for chunk in vectors {
                let cosine = VectorStore.cosineSimilarity(queryEmbedding, chunk.embedding)
                guard cosine > 0 else { continue }
                candidates.append(DocIndexCandidate(
                    chunk: chunk,
                    keywordScore: keywordScore(for: chunk),
                    vectorScore: min(max(cosine, 0), 1),
                    order: candidates.count
                ))
            }
        }
        var seen = Set(candidates.map(\.chunk.id))
        for chunk in keyword where !seen.contains(chunk.id) {
            seen.insert(chunk.id)
            candidates.append(DocIndexCandidate(
                chunk: chunk,
                keywordScore: keywordScore(for: chunk),
                vectorScore: 0,
                order: candidates.count
            ))
        }
        return candidates
    }

    /// Calibrates and reranks doc-index candidates, stamping the index watermark and document metadata.
    private static func rankedDocIndexResults(
        _ candidates: [DocIndexCandidate],
        query: String,
        queryTokens: Set<String>,
        documents: [UUID: IndexedDocument] = [:],
        indexAsOf: Date?
    ) -> [MemoryResult] {
        let total = candidates.count
        let watermark = indexAsOf.map { indexWatermark($0) }
        let scored = candidates.map { candidate -> MemoryResult in
            let base = docIndexBaseWeight * max(candidate.keywordScore, candidate.vectorScore)
            let overlap = docIndexOverlap(queryTokens: queryTokens, chunkText: candidate.chunk.text)
            let recency = docIndexRecency(order: candidate.order, total: total)
            let exact = hasExactNameOrPathMatch(query: query, chunkText: candidate.chunk.text) ? 1.0 : 0.0
            let bonus = docIndexOverlapWeight * overlap + docIndexRecencyWeight * recency + docIndexExactMatchWeight * exact
            let score = min(max(base + bonus, 0.0), 1.0)
            var metadata: [String: String] = [
                "id": candidate.chunk.id.uuidString,
                "document_id": candidate.chunk.documentID.uuidString,
                "ordinal": "\(candidate.chunk.ordinal)"
            ]
            if let doc = documents[candidate.chunk.documentID] {
                metadata["display_name"] = doc.displayName
                metadata["document_source"] = doc.source.rawValue
                if let path = doc.path {
                    metadata["path"] = path
                }
                if let mailbox = doc.mailbox {
                    metadata["mailbox"] = mailbox
                }
                if let messageID = doc.messageID {
                    metadata["message_id"] = messageID
                }
                if let mtime = doc.mtime {
                    metadata["date"] = indexWatermark(mtime)
                }
            }
            if let watermark {
                metadata["index_as_of"] = watermark
            }
            return MemoryResult(
                content: candidate.chunk.text,
                score: score,
                source: .docIndex,
                metadata: metadata
            )
        }
        return scored.map { Self.calibrated($0) }.sorted { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            return docIndexResultOrder(lhs, rhs)
        }
    }

    /// Fraction of query tokens present in a chunk, in `[0, 1]`.
    private static func docIndexOverlap(queryTokens: Set<String>, chunkText: String) -> Double {
        guard !queryTokens.isEmpty else { return 0 }
        let chunkTokens = Tokenization.tokenize(chunkText)
        return Double(queryTokens.intersection(chunkTokens).count) / Double(queryTokens.count)
    }

    /// Newest-first recency prior for one union position, in `[0, 1]`.
    private static func docIndexRecency(order: Int, total: Int) -> Double {
        guard total > 1 else { return 1 }
        return min(max(1.0 - Double(order) / Double(total - 1), 0.0), 1.0)
    }

    /// Whether the query names a file or path that appears verbatim in the chunk.
    ///
    /// Exact-name and path tokens are literal fragments (they carry a dot or a
    /// slash), so a substring hit is a strong signal that this chunk is the
    /// document the user pointed at rather than a topical near-match.
    private static func hasExactNameOrPathMatch(query: String, chunkText: String) -> Bool {
        let loweredChunk = chunkText.lowercased()
        let tokens = query.split { $0.isWhitespace || $0.isNewline }.map { String($0).lowercased() }
        return tokens.contains { token in
            guard token.contains(".") || token.contains("/") else { return false }
            return loweredChunk.contains(token)
        }
    }

    /// Deterministic doc-chunk order: document, then position within it, then id.
    private static func docIndexResultOrder(_ lhs: MemoryResult, _ rhs: MemoryResult) -> Bool {
        let lhsDocument = lhs.metadata["document_id"] ?? ""
        let rhsDocument = rhs.metadata["document_id"] ?? ""
        if lhsDocument != rhsDocument {
            return lhsDocument < rhsDocument
        }
        let lhsOrdinal = Int(lhs.metadata["ordinal"] ?? "") ?? 0
        let rhsOrdinal = Int(rhs.metadata["ordinal"] ?? "") ?? 0
        if lhsOrdinal != rhsOrdinal {
            return lhsOrdinal < rhsOrdinal
        }
        return (lhs.metadata["id"] ?? "") < (rhs.metadata["id"] ?? "")
    }

    /// Formats the index snapshot time as an ISO-8601 watermark.
    private static func indexWatermark(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    /// Dedupes merged recall hits by identifier, with content scope.
    private static func dedupe(_ results: [MemoryResult]) -> [MemoryResult] {
        var seenIDs = Set<String>()
        var seenSemanticProfileContent = Set<String>()
        var kept: [MemoryResult] = []
        kept.reserveCapacity(results.count)
        for result in results {
            let contentKey = result.content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let isEpisodic = result.source == .episodic
            if let id = result.metadata["id"], !id.isEmpty {
                guard !seenIDs.contains(id) else { continue }
                if !isEpisodic {
                    guard !seenSemanticProfileContent.contains(contentKey) else { continue }
                    seenSemanticProfileContent.insert(contentKey)
                }
                seenIDs.insert(id)
                kept.append(result)
            } else {
                if isEpisodic {
                    kept.append(result)
                } else {
                    guard !seenSemanticProfileContent.contains(contentKey) else { continue }
                    seenSemanticProfileContent.insert(contentKey)
                    kept.append(result)
                }
            }
        }
        return kept
    }
}

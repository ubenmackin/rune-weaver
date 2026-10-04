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

extension MemoryEngine {
    /// Recalls across episodic, semantic, document-index, and profile tiers.
    ///
    /// `skipDocIndex` mirrors the plan-level freshness skip so direct callers
    /// report the same miss-vs-skip observability as the automatic path; when
    /// true the document fetch is skipped and `skippedDocIndex` reports true.
    public func recall(
        query: String,
        embedding: [Float]? = nil,
        limit: Int = 10,
        since: Date? = nil,
        until: Date? = nil,
        budgets: RecallBudgets = RecallBudgets(),
        skipDocIndex: Bool = false
    ) async throws -> [MemoryResult] {
        let (hits, _) = try await recallWithDiagnostics(
            query: query,
            embedding: embedding,
            limit: limit,
            since: since,
            until: until,
            budgets: budgets,
            skipDocIndex: skipDocIndex
        )
        return hits
    }

    /// Recalls across tiers while reporting observability alongside hits.
    ///
    /// Retrieved-vs-injected: `hits` are the retrieved set (deduped,
    /// pre-threshold, up to `perTier * 4` for tool and merge use) while
    /// `diagnostics` describe the injected set (threshold-filtered plus
    /// `autoLimit`-capped via `injectedRecallHits`, matching what
    /// `automaticRecallContext` actually injects and what
    /// `recallMessageWithDiagnostics` reports, so both paths log the same
    /// injected `hits/ids/scores`). Diagnostics carry hit identifiers plus
    /// sources plus scores plus the would-inject char estimate plus the
    /// doc-index skip flag, never content.
    /// `injectedChars` estimates the budgets-aware context block length for the
    /// injected hits; `skippedDocIndex` is true when the caller requested a
    /// plan-level skip or no document store is configured, matching
    /// `recallMessageWithDiagnostics`, so callers can distinguish an empty
    /// index or a freshness skip from a miss.
    public func recallWithDiagnostics(
        query: String,
        embedding: [Float]? = nil,
        limit: Int = 10,
        since: Date? = nil,
        until: Date? = nil,
        budgets: RecallBudgets = RecallBudgets(),
        skipDocIndex: Bool = false
    ) async throws -> ([MemoryResult], RecallDiagnostics) {
        let skipped = skipDocIndex || docIndexStore == nil
        guard limit > 0 else { return ([], RecallDiagnostics.zero(skippedDocIndex: skipped)) }
        let clampedBudgets = budgets.clamped()
        let perTier = min(min(limit, clampedBudgets.perTierLimit), Self.maxPerTierResults)
        guard perTier > 0 else { return ([], RecallDiagnostics.zero(skippedDocIndex: skipped)) }
        let episodic = try await searchEpisodes(query: query, limit: perTier, since: since, until: until)
        let semanticRaw = await querySemantic(query: query, embedding: embedding ?? [], limit: perTier)
        let semantic: [MemoryResult] = if (embedding ?? []).isEmpty {
            semanticRaw.map { Self.normalizedSemantic($0) }
        } else {
            semanticRaw
        }
        let profile = profileResults(query: query, limit: perTier)
        let docIndex: [MemoryResult] = if skipDocIndex {
            []
        } else {
            await recallDocuments(
                query: query,
                embedding: embedding,
                limit: perTier,
                since: since,
                until: until,
                budgets: clampedBudgets
            )
        }
        let merged = episodic + semantic + docIndex + profile
        let calibrated = merged.map { Self.calibrated($0, episodicWeight: clampedBudgets.episodicWeight) }
        let sorted = calibrated.sorted(by: Self.recallOrder)
        // `perTier` is capped at `maxPerTierResults` (1000) above, so
        // `perTier * 4` cannot overflow.
        let cap = perTier * 4
        let hits = Array(Self.dedupe(sorted).prefix(cap))
        let context = Self.automaticRecallContext(for: hits, budgets: clampedBudgets)
        let injectedChars = context?.count ?? 0
        // Diagnostics report the injected set so this path logs the same
        // `hits/ids/scores` as `recallMessageWithDiagnostics`; a nil block
        // reports zero hits for silent-nil parity.
        let injected: [MemoryResult] = context == nil ? [] : Self.injectedRecallHits(from: hits, budgets: clampedBudgets)
        let diagnostics = Self.recallDiagnostics(for: injected, injectedChars: injectedChars, skippedDocIndex: skipped)
        return (hits, diagnostics)
    }

    /// Recalls document-index chunks by unioning keyword and vector candidates.
    ///
    /// The FTS5 keyword path and the cosine path over stored chunk embeddings
    /// are unioned newest-first, reciprocal-rank-fused (`rrf = 1/(60+rank)` per
    /// list, summed when a chunk appears in both), then reranked with the
    /// shared `0.6*max+0.2*overlap+0.1*recency+0.1*exact` blend plus the RRF
    /// boost and calibrated by the doc-index tier weight. A missing query
    /// embedding or a failed vector read still returns the keyword hits, so
    /// retrieval never fails a turn. The vector scan is a bounded
    /// newest-first pool widened by budgets, so recent writes stay visible at
    /// scale while an old-but-relevant keyword hit still surfaces via union.
    /// - Parameters:
    ///   - query: Raw user query.
    ///   - embedding: Query embedding for the vector path, or nil for keyword-only.
    ///   - limit: Maximum chunk results.
    ///   - since: Inclusive lower bound on the parent document event time, or nil for unbounded.
    ///   - until: Exclusive upper bound on the parent document event time, or nil for unbounded.
    ///   - budgets: Recall budgets carrying the doc-pool multiplier and per-tier cap.
    /// - Returns: Calibrated doc-index results carrying the index watermark.
    public func recallDocuments(
        query: String,
        embedding: [Float]? = nil,
        limit: Int = 5,
        since: Date? = nil,
        until: Date? = nil,
        budgets: RecallBudgets = RecallBudgets()
    ) async -> [MemoryResult] {
        guard limit > 0, let docIndexStore else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let clampedBudgets = budgets.clamped()
        let clamped = min(min(limit, clampedBudgets.perTierLimit), Self.maxPerTierResults)
        guard clamped > 0 else { return [] }
        // Widen the vector scan beyond the returned page so a strong semantic
        // match is not crowded out by keyword hits. The store caps the pool to
        // the newest rows, keeping recent writes visible at scale; the keyword
        // union keeps an old-but-relevant hit recallable outside that pool.
        // The dated window filters candidates before ranking so calibration,
        // watermark, and per-tier caps stay unchanged.
        // `docPoolMultiplier` clamps to `1...8`, so the widened pool never
        // shrinks below `clamped` and needs no lower bound.
        let pool = min(clamped * clampedBudgets.docPoolMultiplier, Self.maxPerTierResults)
        let keyword = await (try? docIndexStore.searchKeyword(query: trimmed, limit: pool, since: since, until: until)) ?? []
        let vectorLimit = (since != nil || until != nil) ? DocIndexStore.maxVectorWindowResults : min(max(pool * 10, 500), Self.maxPerTierResults)
        let vectors = await (try? docIndexStore.chunkVectors(limit: vectorLimit, since: since, until: until)) ?? []
        let queryEmbedding = (embedding?.isEmpty == false) ? embedding : nil
        let candidates = Self.docIndexCandidates(keyword: keyword, vectors: vectors, queryEmbedding: queryEmbedding)
        guard !candidates.isEmpty else { return [] }
        let stats = try? await docIndexStore.stats()
        let docIDs = Set(candidates.map(\.chunk.documentID))
        let documents = await (try? docIndexStore.documents(ids: docIDs)) ?? [:]
        let salient = Set(Tokenization.salientTokens(from: trimmed))
        let effectiveQueryTokens = salient.isEmpty ? Tokenization.tokenize(trimmed) : salient
        let ranked = Self.rankedDocIndexResults(
            candidates,
            query: trimmed,
            queryTokens: effectiveQueryTokens,
            documents: documents,
            indexAsOf: stats?.indexAsOf,
            episodicWeight: clampedBudgets.episodicWeight
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
    ///
    /// The episodic weight comes from the clamped recall budgets so the
    /// `recall_episodic_weight` file knob reaches the shared scale; the
    /// remaining tier weights stay fixed.
    private static func calibrated(_ result: MemoryResult, episodicWeight: Double = episodicTierWeight) -> MemoryResult {
        let weight: Double = switch result.source {
        case .episodic: episodicWeight
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

    /// Orders merged recall hits by score, then tier priority, then stable identity.
    ///
    /// Equal-score equal-priority hits fall back to a deterministic
    /// `source.rawValue`, then `metadata["id"]`, then `content` comparison so
    /// repeated turns sort identically instead of leaving Swift sort order undefined.
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
        if lhs.source.rawValue != rhs.source.rawValue {
            return lhs.source.rawValue < rhs.source.rawValue
        }
        let lhsID = lhs.metadata["id"] ?? ""
        let rhsID = rhs.metadata["id"] ?? ""
        if lhsID != rhsID {
            return lhsID < rhsID
        }
        if lhs.content != rhs.content {
            return lhs.content < rhs.content
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
        /// One-based keyword rank, nil when keyword-absent.
        let keywordRank: Int?
        /// One-based cosine rank, nil when vector-absent.
        let vectorRank: Int?
        /// Reciprocal-rank-fusion boost `sum(1/(60+rank))` over present lists.
        let rrf: Double
    }

    /// RRF damping constant keeping the fusion boost small beside the rerank blend.
    private static let docIndexRRFK = 60.0

    /// Base retrieval weight in the doc-index rerank, leaving room for bonuses.
    private static let docIndexBaseWeight = 0.6

    /// Keyword-overlap weight in the doc-index rerank.
    private static let docIndexOverlapWeight = 0.2

    /// Recency-prior weight in the doc-index rerank.
    private static let docIndexRecencyWeight = 0.1

    /// Exact name-or-path bonus in the doc-index rerank.
    private static let docIndexExactMatchWeight = 0.1

    /// Reciprocal-rank score for one list rank, zero when absent.
    private static func rrfScore(rank: Int?) -> Double {
        guard let rank else { return 0 }
        return 1.0 / (docIndexRRFK + Double(rank))
    }

    /// Unions keyword and vector candidates into one newest-first list.
    ///
    /// Vector chunks arrive newest-first from the bounded store pool, so they
    /// keep that order before the keyword-only hits are appended. The resulting
    /// position is the recency prior because both reads break ties toward newer rows.
    /// The single fusion is an additive RRF boost: each present list contributes
    /// `1/(60+rank)` (keyword rank from FTS order, vector rank from cosine order),
    /// summed when a chunk appears in both, then added to the existing
    /// `0.6*max+0.2*overlap+0.1*recency+0.1*exact` blend before tier calibration.
    /// Keyword-only chunks outside the newest-first vector pool still union in,
    /// so an old-but-relevant match survives a narrow pool.
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
        var scoredVectors: [(chunk: IndexedChunk, cosine: Double)] = []
        if let queryEmbedding, !queryEmbedding.isEmpty {
            for chunk in vectors {
                let cosine = VectorStore.cosineSimilarity(queryEmbedding, chunk.embedding)
                guard cosine > 0 else { continue }
                scoredVectors.append((chunk: chunk, cosine: min(max(cosine, 0), 1)))
            }
        }
        let cosineOrdered = scoredVectors.sorted { lhs, rhs in
            if lhs.cosine != rhs.cosine {
                return lhs.cosine > rhs.cosine
            }
            return lhs.chunk.id.uuidString < rhs.chunk.id.uuidString
        }
        var vectorRanks: [UUID: Int] = [:]
        for (index, entry) in cosineOrdered.enumerated() where vectorRanks[entry.chunk.id] == nil {
            vectorRanks[entry.chunk.id] = index + 1
        }
        var cosineByID: [UUID: Double] = [:]
        for entry in scoredVectors where cosineByID[entry.chunk.id] == nil {
            cosineByID[entry.chunk.id] = entry.cosine
        }
        let topVectorLimit = max(keyword.count * 4, 100)
        let topVectorIDs = Set(cosineOrdered.prefix(topVectorLimit).map(\.chunk.id))
        var candidates: [DocIndexCandidate] = []
        var seen = Set<UUID>()
        for entry in scoredVectors where topVectorIDs.contains(entry.chunk.id) {
            let id = entry.chunk.id
            guard !seen.contains(id) else { continue }
            seen.insert(id)
            let keywordRank = keywordRanks[id]
            let vectorRank = vectorRanks[id]
            let rrf = rrfScore(rank: keywordRank) + rrfScore(rank: vectorRank)
            candidates.append(DocIndexCandidate(
                chunk: entry.chunk,
                keywordScore: keywordScore(for: entry.chunk),
                vectorScore: cosineByID[id] ?? 0,
                order: candidates.count,
                keywordRank: keywordRank,
                vectorRank: vectorRank,
                rrf: rrf
            ))
        }
        for chunk in keyword where !seen.contains(chunk.id) {
            seen.insert(chunk.id)
            let keywordRank = keywordRanks[chunk.id]
            let rrf = rrfScore(rank: keywordRank)
            candidates.append(DocIndexCandidate(
                chunk: chunk,
                keywordScore: keywordScore(for: chunk),
                vectorScore: 0,
                order: candidates.count,
                keywordRank: keywordRank,
                vectorRank: nil,
                rrf: rrf
            ))
        }
        return candidates
    }

    /// Calibrates and reranks doc-index candidates, stamping the index watermark and document metadata.
    ///
    /// `episodicWeight` threads through from the clamped recall budgets for
    /// call-site uniformity with the merged path; doc-index hits calibrate
    /// with the fixed doc-index tier weight.
    private static func rankedDocIndexResults(
        _ candidates: [DocIndexCandidate],
        query: String,
        queryTokens: Set<String>,
        documents: [UUID: IndexedDocument] = [:],
        indexAsOf: Date?,
        episodicWeight: Double = episodicTierWeight
    ) -> [MemoryResult] {
        let total = candidates.count
        let watermark = indexAsOf.map { indexWatermark($0) }
        let scored = candidates.map { candidate -> MemoryResult in
            let base = docIndexBaseWeight * max(candidate.keywordScore, candidate.vectorScore)
            let overlap = docIndexOverlap(queryTokens: queryTokens, chunkText: candidate.chunk.text)
            let recency = docIndexRecency(order: candidate.order, total: total)
            let exact = hasExactNameOrPathMatch(query: query, chunkText: candidate.chunk.text) ? 1.0 : 0.0
            let bonus = docIndexOverlapWeight * overlap + docIndexRecencyWeight * recency + docIndexExactMatchWeight * exact
            let fused = min(max(base + bonus + candidate.rrf, 0.0), 1.0)
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
                score: fused,
                source: .docIndex,
                metadata: metadata
            )
        }
        return scored.map { Self.calibrated($0, episodicWeight: episodicWeight) }.sorted { lhs, rhs in
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
    /// Exact-name and path tokens are literal fragments with a file-like
    /// shape (a stem plus a dot plus an extension, or a slash-delimited path
    /// with a minimum length), so a substring hit is a strong signal that
    /// this chunk is the document the user pointed at rather than a topical
    /// near-match. Bare dotted prose (`e.g.`, `i.e.`, `v1.2`) carries a dot
    /// but no file shape and earns no bonus.
    private static func hasExactNameOrPathMatch(query: String, chunkText: String) -> Bool {
        let loweredChunk = chunkText.lowercased()
        let tokens = query.split { $0.isWhitespace || $0.isNewline }.map { String($0).lowercased() }
        return tokens.contains { token in
            let candidate = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'()[]{}<>,;:!?…"))
            guard isFileLikeToken(candidate) else { return false }
            return loweredChunk.contains(candidate)
        }
    }

    /// Whether a query token has a file-like shape before any substring test.
    ///
    /// Slash tokens need a minimum length with the slash away from the edges
    /// (so `src/foo` qualifies); dot tokens need a stem plus a dot plus a
    /// short alphabetic extension (so `report.pdf` qualifies while `e.g.`,
    /// `i.e.`, and `v1.2` do not).
    private static func isFileLikeToken(_ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        if token.contains("/") {
            guard token.count >= 3 else { return false }
            guard !token.hasPrefix("/"), !token.hasSuffix("/") else { return false }
            return token.contains { $0.isLetter || $0.isNumber }
        }
        guard token.contains(".") else { return false }
        guard token.count >= 4 else { return false }
        guard !token.hasPrefix("."), !token.hasSuffix(".") else { return false }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        guard parts.allSatisfy({ !$0.isEmpty }) else { return false }
        guard let ext = parts.last else { return false }
        guard ext.count >= 1, ext.count <= 5 else { return false }
        guard ext.contains(where: \.isLetter) else { return false }
        guard ext.allSatisfy({ $0.isLetter || $0.isNumber }) else { return false }
        return true
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

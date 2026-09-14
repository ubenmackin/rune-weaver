import Foundation

/// A single semantic memory record: a fact plus its embedding.
///
/// Facts persist as JSON under the configured vector directory
/// (`~/.runeweaver/memory/vectors` from `config.toml`). The store
/// exposes the same shape as an embedded LanceDB table — append facts,
/// query by cosine similarity, filter by metadata — so a native
/// LanceDB binding can replace the file backend later without
/// changing callers.
public struct StoredFact: Sendable, Codable, Equatable, Identifiable {
    /// Unique identifier for this fact.
    public let id: UUID
    /// Human-readable fact text.
    public let content: String
    /// Embedding vector for similarity search.
    public let embedding: [Float]
    /// Caller-supplied key/value annotations (never secrets).
    public let metadata: [String: String]
    /// Creation timestamp.
    public let createdAt: Date
    /// Last mutation timestamp.
    public let updatedAt: Date

    /// Creates a stored fact.
    /// - Parameters:
    ///   - id: Unique identifier. Defaults to a new UUID.
    ///   - content: Fact text.
    ///   - embedding: Embedding vector.
    ///   - metadata: Key/value annotations. Defaults to empty.
    ///   - createdAt: Creation date. Defaults to now.
    ///   - updatedAt: Last mutation date. Defaults to now.
    public init(
        id: UUID = UUID(),
        content: String,
        embedding: [Float],
        metadata: [String: String] = [:],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.content = content
        self.embedding = embedding
        self.metadata = metadata
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A fact paired with its cosine similarity to a query vector.
///
/// Scores are in `[-1, 1]` (higher is more similar); an empty or
/// zero-norm query vector scores `0`.
public struct ScoredFact: Sendable, Codable, Equatable {
    /// The matching fact.
    public let fact: StoredFact
    /// Cosine similarity to the query vector.
    public let score: Double

    /// Creates a scored fact.
    /// - Parameters:
    ///   - fact: The matching fact.
    ///   - score: Cosine similarity.
    public init(fact: StoredFact, score: Double) {
        self.fact = fact
        self.score = score
    }
}

/// Failures raised by ``VectorStore``.
public enum VectorStoreError: Error, Sendable, Equatable {
    /// The vector directory could not be created or read.
    case storeUnavailable(String)
    /// A read or write against the store failed.
    case persistenceFailed(String)
    /// The embedding width does not match the store's dimension.
    case dimensionMismatch(expected: Int, got: Int)
}

/// Embedded vector store for semantic memory (LanceDB-compatible shape).
///
/// Facts live in memory for fast cosine-similarity queries and are
/// mirrored to `<directory>/facts.json` after every mutation. The
/// first stored embedding fixes the store dimension; later writes
/// with a different width throw
/// ``VectorStoreError/dimensionMismatch(expected:got:)``. Use
/// ``VectorStore/reindex()`` to compact the file and revalidate every
/// row after bulk edits or manual file changes.
///
/// Blocking JSON file work runs off the actor executor via the
/// nonisolated `runStoreIO(_:)` helper (background queue plus
/// continuation) so mutations stay suspension-friendly: in-memory state
/// updates on the actor, then the snapshot persists in the background.
public actor VectorStore {
    /// Directory holding `facts.json` (the LanceDB dataset stand-in).
    public let directoryPath: String
    /// Embedding width fixed by the first stored fact, if any.
    public private(set) var dimension: Int?
    /// Expected width from init, preserved across clear and reload.
    ///
    /// Derived widths come from stored rows and reset when the store empties;
    /// this configured width survives empties so an explicit expectation never
    /// silently clears to nil behind callers.
    private let configuredDimension: Int?
    /// Maximum results returned per query.
    ///
    /// Bounds keyword and vector fan-out so huge limits never materialize
    /// unbounded result arrays.
    private static let maxResults = 1000

    /// Facts indexed by identifier.
    private var facts: [UUID: StoredFact] = [:]

    /// Creates a store, loading any existing `facts.json` best-effort.
    /// - Parameters:
    ///   - directoryPath: Directory for `facts.json`. `~` is expanded.
    ///     Created on first write.
    ///   - dimension: Expected embedding width. When set, writes with
    ///     any other width throw even on an empty store.
    public init(directoryPath: String, dimension: Int? = nil) {
        self.directoryPath = directoryPath
        self.configuredDimension = dimension
        self.dimension = dimension
        let loaded = Self.loadBestEffort(directoryPath: directoryPath)
        self.facts = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
        if self.dimension == nil {
            let widths = Set(loaded.map(\.embedding.count).filter { $0 > 0 })
            self.dimension = widths.count == 1 ? widths.first : nil
        }
    }

    // MARK: - Writes

    /// Stores a fact with its embedding (upsert by new `id`).
    ///
    /// Blocking file work runs off the actor executor via the background helper.
    /// - Parameters:
    ///   - content: Fact text.
    ///   - embedding: Embedding vector. Must match ``dimension``.
    ///   - metadata: Key/value annotations. Defaults to empty.
    /// - Returns: The stored fact.
    @discardableResult
    public func store(
        content: String,
        embedding: [Float],
        metadata: [String: String] = [:]
    ) async throws -> StoredFact {
        let fact = StoredFact(content: content, embedding: embedding, metadata: metadata)
        try await upsert(fact)
        return fact
    }

    /// Inserts or replaces a fact by `id`.
    ///
    /// Empty embeddings are keyword-only rows: they skip dimension
    /// enforcement so extraction without a model never pollutes the
    /// store width. In-memory state updates on the actor; the file
    /// mirror persists off the executor.
    /// - Parameter fact: Fact to persist.
    public func upsert(_ fact: StoredFact) async throws {
        if !fact.embedding.isEmpty {
            try checkDimension(fact.embedding.count)
        }
        var stored = fact
        if facts[fact.id] != nil {
            stored = StoredFact(
                id: fact.id,
                content: fact.content,
                embedding: fact.embedding,
                metadata: fact.metadata,
                createdAt: facts[fact.id]?.createdAt ?? fact.createdAt,
                updatedAt: Date()
            )
        }
        facts[stored.id] = stored
        if dimension == nil, !stored.embedding.isEmpty {
            dimension = stored.embedding.count
        }
        try await persistSnapshot()
    }

    /// Inserts or replaces a batch of facts by `id`.
    ///
    /// Empty (keyword-only) embeddings are allowed alongside sized
    /// rows; all non-empty rows must share one width. In-memory state
    /// updates on the actor; the file mirror persists off the executor.
    /// - Parameter facts: Facts to persist.
    public func upsert(_ facts: [StoredFact]) async throws {
        guard !facts.isEmpty else { return }
        let widths = Set(facts.map(\.embedding.count).filter { $0 > 0 })
        guard widths.count <= 1 else {
            throw VectorStoreError.persistenceFailed("Batch embeddings must share one dimension")
        }
        if let width = widths.first {
            try checkDimension(width)
        }
        for fact in facts {
            let stored: StoredFact = if let existing = self.facts[fact.id] {
                StoredFact(
                    id: fact.id,
                    content: fact.content,
                    embedding: fact.embedding,
                    metadata: fact.metadata,
                    createdAt: existing.createdAt,
                    updatedAt: Date()
                )
            } else {
                fact
            }
            self.facts[stored.id] = stored
        }
        if dimension == nil, let width = widths.first {
            dimension = width
        }
        try await persistSnapshot()
    }

    /// Removes a fact. Missing identifiers are a no-op.
    ///
    /// The derived width is recomputed from the surviving rows so removing the
    /// last sized row never leaves a stale width behind: an empty (or
    /// keyword-only) store that still reported the old width would reject the
    /// next backend's first vector even though no sized row remains. An
    /// init-configured expectation survives so explicit width enforcement is
    /// never dropped behind callers. The file mirror persists off the actor
    /// executor.
    /// - Parameter id: Fact identifier.
    public func remove(id: UUID) async throws {
        guard facts.removeValue(forKey: id) != nil else { return }
        if configuredDimension == nil {
            let widths = Set(facts.values.map(\.embedding.count).filter { $0 > 0 })
            dimension = widths.count == 1 ? widths.first : nil
        }
        try await persistSnapshot()
    }

    /// Removes every fact, resetting derived width but keeping configured width.
    ///
    /// Derived widths learned from stored rows clear so the next backend width
    /// starts clean; an init-configured expectation survives so direct clears
    /// never drop the enforcement callers constructed with. The file mirror
    /// persists off the actor executor.
    public func clear() async throws {
        facts.removeAll()
        dimension = configuredDimension
        try await persistSnapshot()
    }

    // MARK: - Reads

    /// Total stored fact count.
    /// - Returns: Fact count.
    public func count() -> Int {
        facts.count
    }

    /// All facts, newest first.
    /// - Returns: Stored facts.
    public func allFacts() -> [StoredFact] {
        facts.values.sorted { $0.createdAt > $1.createdAt }
    }

    /// Finds one fact by identifier.
    /// - Parameter id: Fact identifier.
    /// - Returns: The fact, or nil when unknown.
    public func fact(id: UUID) -> StoredFact? {
        facts[id]
    }

    /// Queries by cosine similarity with optional metadata filtering.
    ///
    /// Only facts whose metadata contains every `metadataFilter`
    /// key/value pair are considered. Empty, width-mismatched, and
    /// zero-norm vectors score `0` via `cosineSimilarity` and are
    /// filtered out so only positively similar facts return. Results
    /// are sorted by score descending; ties break newest first, then by
    /// identifier so unordered dictionary iteration stays deterministic.
    /// - Parameters:
    ///   - embedding: Query vector.
    ///   - limit: Maximum results. Defaults to 5. Non-positive limits
    ///     return an empty list. Larger limits are capped.
    ///   - metadataFilter: Required metadata pairs. Defaults to nil.
    /// - Returns: Scored facts with positive similarity, best first.
    public func query(
        embedding: [Float],
        limit: Int = 5,
        metadataFilter: [String: String]? = nil
    ) -> [ScoredFact] {
        guard limit > 0 else { return [] }
        let clamped = min(limit, Self.maxResults)
        let candidates = filterCandidates(metadataFilter: metadataFilter)
        let scored = candidates.map { fact in
            ScoredFact(fact: fact, score: Self.cosineSimilarity(embedding, fact.embedding))
        }.filter { $0.score > 0 }
        return Array(Self.sortScored(scored).prefix(clamped))
    }

    /// Keyword search over fact content with optional metadata filtering.
    ///
    /// Used when no query embedding is available: case-insensitive
    /// token overlap scoring, ties broken newest first, then by
    /// identifier so unordered dictionary iteration stays deterministic.
    /// - Parameters:
    ///   - query: Search text.
    ///   - limit: Maximum results. Defaults to 5. Non-positive limits
    ///     return an empty list. Larger limits are capped.
    ///   - metadataFilter: Required metadata pairs. Defaults to nil.
    /// - Returns: Scored facts, best first. Empty for blank queries.
    public func search(
        query: String,
        limit: Int = 5,
        metadataFilter: [String: String]? = nil
    ) -> [ScoredFact] {
        guard limit > 0 else { return [] }
        let clamped = min(limit, Self.maxResults)
        let queryTokens = Tokenization.tokenize(query)
        guard !queryTokens.isEmpty else { return [] }
        let candidates = filterCandidates(metadataFilter: metadataFilter)
        let scored = candidates.compactMap { fact -> ScoredFact? in
            let contentTokens = Tokenization.tokenize(fact.content)
            guard let raw = Tokenization.keywordScore(
                queryTokens: queryTokens,
                contentTokens: contentTokens,
                content: fact.content,
                query: query
            ) else { return nil }
            return ScoredFact(fact: fact, score: Double(raw))
        }
        return Array(Self.sortScored(scored).prefix(clamped))
    }

    // MARK: - Re-indexing

    /// Rebuilds the on-disk index from disk and memory.
    ///
    /// Reloads from disk first (reconciling externally added rows),
    /// merges the result with in-memory facts so unsaved rows are never
    /// discarded, then re-sorts facts (newest first), drops
    /// exact-duplicate rows (same content and metadata, keeping the
    /// newest), revalidates a single embedding dimension across all
    /// rows, and rewrites `facts.json` atomically. A corrupt file throws
    /// without mutating memory or overwriting disk, so reindex never
    /// wipes the store; only a missing file loads as empty. An
    /// init-configured width survives compaction so explicit expectations
    /// never clear behind callers. Call after bulk edits or manual file
    /// changes.
    /// - Returns: Fact count after compaction.
    /// - Throws: `VectorStoreError/persistenceFailed(_:)` when the file
    ///   exists but cannot be read or decoded, or when stored rows have
    ///   mixed embedding dimensions.
    ///
    /// The disk reload and the file rewrite run off the actor executor
    /// via the background helper; merging, deduping, and dimension
    /// checks run on the actor over the combined snapshot.
    @discardableResult
    public func reindex() async throws -> Int {
        let directoryPath = self.directoryPath
        let memorySnapshot = facts
        let onDisk = try await runStoreIO {
            try Self.loadThrowing(directoryPath: directoryPath)
        }
        let combined = (onDisk + Array(memorySnapshot.values)).sorted { $0.createdAt > $1.createdAt }
        var seenIDs: Set<UUID> = []
        var seenContent: Set<String> = []
        var compacted: [UUID: StoredFact] = [:]
        compacted.reserveCapacity(combined.count)
        for fact in combined {
            guard !seenIDs.contains(fact.id) else { continue }
            let key = "\(fact.content)\n\(fact.metadata.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","))"
            guard !seenContent.contains(key) else { continue }
            seenIDs.insert(fact.id)
            seenContent.insert(key)
            compacted[fact.id] = fact
        }
        let widths = Set(compacted.values.map(\.embedding.count).filter { $0 > 0 })
        if widths.count > 1 {
            throw VectorStoreError.persistenceFailed("Stored facts have mixed embedding dimensions: \(widths.sorted())")
        }
        facts = compacted
        dimension = configuredDimension ?? widths.first
        try await persistSnapshot()
        return facts.count
    }

    /// Reloads facts from disk, replacing memory.
    ///
    /// A configured init width survives reloads so an explicit expectation is
    /// never lost to an empty or externally changed file; without one, the
    /// dimension derives from the loaded widths (a single width wins while
    /// mixed or missing widths clear to nil) so externally changed files never
    /// leave a stale width behind.
    public func reload() {
        facts = Dictionary(uniqueKeysWithValues: Self.loadBestEffort(directoryPath: directoryPath).map { ($0.id, $0) })
        if let configuredDimension {
            dimension = configuredDimension
            return
        }
        let widths = Set(facts.values.map(\.embedding.count).filter { $0 > 0 })
        dimension = widths.count == 1 ? widths.first : nil
    }

    // MARK: - Similarity

    /// Filters facts by required metadata pairs.
    ///
    /// Shared by `query` and `search` so metadata filtering stays
    /// single-sourced across vector and keyword recall.
    /// - Parameter metadataFilter: Required metadata pairs. Defaults to nil.
    /// - Returns: Facts matching every pair, or all facts when the filter is nil or empty.
    private func filterCandidates(metadataFilter: [String: String]?) -> [StoredFact] {
        facts.values.filter { fact in
            guard let metadataFilter, !metadataFilter.isEmpty else { return true }
            return metadataFilter.allSatisfy { fact.metadata[$0.key] == $0.value }
        }
    }

    /// Sorts scored facts best first with deterministic ties.
    ///
    /// Shared by `query` and `search`: score descending, then newest
    /// first, then identifier so unordered dictionary iteration stays
    /// deterministic.
    /// - Parameter scored: Scored facts to order.
    /// - Returns: Facts sorted best first.
    private static func sortScored(_ scored: [ScoredFact]) -> [ScoredFact] {
        scored.sorted {
            if $0.score != $1.score {
                return $0.score > $1.score
            }
            if $0.fact.createdAt != $1.fact.createdAt {
                return $0.fact.createdAt > $1.fact.createdAt
            }
            return $0.fact.id.uuidString < $1.fact.id.uuidString
        }
    }

    /// Cosine similarity between two vectors.
    /// - Parameters:
    ///   - lhs: First vector.
    ///   - rhs: Second vector.
    /// - Returns: Cosine similarity in `[-1, 1]`; `0` when either
    ///   vector is empty, zero-norm, or the widths differ.
    static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard !lhs.isEmpty, lhs.count == rhs.count else { return 0 }
        var dot: Double = 0
        var lhsNorm: Double = 0
        var rhsNorm: Double = 0
        for index in lhs.indices {
            let left = Double(lhs[index])
            let right = Double(rhs[index])
            dot += left * right
            lhsNorm += left * left
            rhsNorm += right * right
        }
        guard lhsNorm > 0, rhsNorm > 0 else { return 0 }
        return dot / (lhsNorm.squareRoot() * rhsNorm.squareRoot())
    }

    // MARK: - Persistence

    /// Validates an embedding width against the store dimension.
    /// - Parameter width: Candidate embedding count.
    private func checkDimension(_ width: Int) throws {
        if let dimension, width != dimension {
            throw VectorStoreError.dimensionMismatch(expected: dimension, got: width)
        }
    }

    /// File URL for the persisted dataset.
    /// - Parameter directoryPath: Store directory. `~` is expanded.
    /// - Returns: URL of `facts.json` inside the expanded directory.
    private static func fileURL(directoryPath: String) -> URL {
        let expanded = (directoryPath as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true).appendingPathComponent("facts.json")
    }

    /// Loads persisted facts without throwing (used from `init`).
    /// - Parameter directoryPath: Store directory.
    /// - Returns: Stored facts, empty on any failure.
    private static func loadBestEffort(directoryPath: String) -> [StoredFact] {
        let url = fileURL(directoryPath: directoryPath)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode([StoredFact].self, from: data)) ?? []
    }

    /// Loads persisted facts, throwing on corrupt data (used by `reindex`).
    ///
    /// A missing file loads as empty so a fresh store reindexes cleanly;
    /// an existing file that cannot be read or decoded throws instead of
    /// returning empty, so callers never compact memory into an empty set
    /// and overwrite good data.
    /// - Parameter directoryPath: Store directory.
    /// - Returns: Stored facts, empty only when the file is missing.
    /// - Throws: `VectorStoreError/persistenceFailed(_:)` when the file
    ///   exists but cannot be read or decoded.
    private static func loadThrowing(directoryPath: String) throws -> [StoredFact] {
        let url = fileURL(directoryPath: directoryPath)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            return try decoder.decode([StoredFact].self, from: data)
        } catch {
            throw VectorStoreError.persistenceFailed("Could not read vector store: \(error.localizedDescription)")
        }
    }

    /// Persists the in-memory snapshot off the actor executor.
    ///
    /// Captures the ordered facts and directory on the actor, then writes
    /// the file on a background queue so the actor stays
    /// suspension-friendly while the write completes.
    private func persistSnapshot() async throws {
        let ordered = facts.values.sorted { $0.createdAt > $1.createdAt }
        let directoryPath = self.directoryPath
        try await runStoreIO {
            try Self.writeSnapshot(ordered, directoryPath: directoryPath)
        }
    }

    /// Writes an ordered snapshot to `facts.json` atomically.
    ///
    /// Nonisolated file helper shared by every mutation so blocking
    /// directory creation, encoding, and writes never run on the actor
    /// executor.
    /// - Parameters:
    ///   - ordered: Facts to write, newest first.
    ///   - directoryPath: Store directory. `~` is expanded.
    private static func writeSnapshot(_ ordered: [StoredFact], directoryPath: String) throws {
        let url = Self.fileURL(directoryPath: directoryPath)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(ordered)
            try data.write(to: url, options: .atomic)
        } catch let error as VectorStoreError {
            throw error
        } catch {
            throw VectorStoreError.persistenceFailed("Could not write vector store: \(error.localizedDescription)")
        }
    }
}

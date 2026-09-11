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
public actor VectorStore {
    /// Directory holding `facts.json` (the LanceDB dataset stand-in).
    public let directoryPath: String
    /// Embedding width fixed by the first stored fact, if any.
    public private(set) var dimension: Int?

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
        self.dimension = dimension
        let loaded = Self.loadBestEffort(directoryPath: directoryPath)
        self.facts = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
        if self.dimension == nil {
            self.dimension = loaded.map(\.embedding.count).first { $0 > 0 }
        }
    }

    // MARK: - Writes

    /// Stores a fact with its embedding (upsert by new `id`).
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
    ) throws -> StoredFact {
        let fact = StoredFact(content: content, embedding: embedding, metadata: metadata)
        try upsert(fact)
        return fact
    }

    /// Inserts or replaces a fact by `id`.
    ///
    /// Empty embeddings are keyword-only rows: they skip dimension
    /// enforcement so extraction without a model never pollutes the
    /// store width.
    /// - Parameter fact: Fact to persist.
    public func upsert(_ fact: StoredFact) throws {
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
        try save()
    }

    /// Inserts or replaces a batch of facts by `id`.
    ///
    /// Empty (keyword-only) embeddings are allowed alongside sized
    /// rows; all non-empty rows must share one width.
    /// - Parameter facts: Facts to persist.
    public func upsert(_ facts: [StoredFact]) throws {
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
        try save()
    }

    /// Removes a fact. Missing identifiers are a no-op.
    /// - Parameter id: Fact identifier.
    public func remove(id: UUID) throws {
        guard facts.removeValue(forKey: id) != nil else { return }
        try save()
    }

    /// Removes every fact, keeping the configured dimension.
    public func clear() throws {
        facts.removeAll()
        try save()
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
    /// key/value pair are considered. Results are sorted by score
    /// descending; ties break newest first.
    /// - Parameters:
    ///   - embedding: Query vector.
    ///   - limit: Maximum results. Defaults to 5.
    ///   - metadataFilter: Required metadata pairs. Defaults to nil.
    /// - Returns: Scored facts, best first.
    public func query(
        embedding: [Float],
        limit: Int = 5,
        metadataFilter: [String: String]? = nil
    ) -> [ScoredFact] {
        let candidates = facts.values.filter { fact in
            guard let metadataFilter, !metadataFilter.isEmpty else { return true }
            return metadataFilter.allSatisfy { fact.metadata[$0.key] == $0.value }
        }
        let scored = candidates.map { fact in
            ScoredFact(fact: fact, score: Self.cosineSimilarity(embedding, fact.embedding))
        }
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.fact.createdAt > $1.fact.createdAt }
            .prefix(max(1, limit))
            .map(\.self)
    }

    /// Keyword search over fact content with optional metadata filtering.
    ///
    /// Used when no query embedding is available: case-insensitive
    /// token overlap scoring, ties broken newest first.
    /// - Parameters:
    ///   - query: Search text.
    ///   - limit: Maximum results. Defaults to 5.
    ///   - metadataFilter: Required metadata pairs. Defaults to nil.
    /// - Returns: Scored facts, best first. Empty for blank queries.
    public func search(
        query: String,
        limit: Int = 5,
        metadataFilter: [String: String]? = nil
    ) -> [ScoredFact] {
        let queryTokens = Self.tokenize(query)
        guard !queryTokens.isEmpty else { return [] }
        let candidates = facts.values.filter { fact in
            guard let metadataFilter, !metadataFilter.isEmpty else { return true }
            return metadataFilter.allSatisfy { fact.metadata[$0.key] == $0.value }
        }
        let scored = candidates.compactMap { fact -> ScoredFact? in
            let contentTokens = Set(Self.tokenize(fact.content))
            let overlap = queryTokens.intersection(contentTokens).count
            let substring = fact.content.range(of: query, options: .caseInsensitive) != nil
            guard overlap > 0 || substring else { return nil }
            return ScoredFact(fact: fact, score: Double(overlap * 2 + (substring ? 1 : 0)))
        }
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.fact.createdAt > $1.fact.createdAt }
            .prefix(max(1, limit))
            .map(\.self)
    }

    // MARK: - Re-indexing

    /// Rebuilds the on-disk index from memory.
    ///
    /// Re-sorts facts (newest first), drops exact-duplicate rows
    /// (same content and metadata, keeping the newest), revalidates a
    /// single embedding dimension across all rows, and rewrites
    /// `facts.json` atomically. Call after bulk edits or manual file
    /// changes; also reloads anything written to disk externally.
    /// - Returns: Fact count after compaction.
    @discardableResult
    public func reindex() throws -> Int {
        let onDisk = Self.loadBestEffort(directoryPath: directoryPath)
        for fact in onDisk where facts[fact.id] == nil {
            facts[fact.id] = fact
        }
        let sorted = facts.values.sorted { $0.createdAt > $1.createdAt }
        var seen: Set<String> = []
        var compacted: [UUID: StoredFact] = [:]
        compacted.reserveCapacity(sorted.count)
        for fact in sorted {
            let key = "\(fact.content)\n\(fact.metadata.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","))"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            compacted[fact.id] = fact
        }
        let widths = Set(compacted.values.map(\.embedding.count).filter { $0 > 0 })
        if widths.count > 1 {
            throw VectorStoreError.persistenceFailed("Stored facts have mixed embedding dimensions: \(widths.sorted())")
        }
        facts = compacted
        if dimension == nil, let width = widths.first {
            dimension = width
        }
        try save()
        return facts.count
    }

    /// Reloads facts from disk, replacing memory.
    public func reload() {
        facts = Dictionary(uniqueKeysWithValues: Self.loadBestEffort(directoryPath: directoryPath).map { ($0.id, $0) })
        if dimension == nil {
            dimension = facts.values.map(\.embedding.count).first { $0 > 0 }
        }
    }

    // MARK: - Similarity

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

    /// Lowercased alphanumeric tokens for keyword scoring.
    /// - Parameter text: Text to tokenize.
    /// - Returns: Token set.
    private static func tokenize(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { !$0.isEmpty })
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

    /// Writes all facts to `facts.json` atomically.
    private func save() throws {
        let url = Self.fileURL(directoryPath: directoryPath)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            encoder.outputFormatting = [.sortedKeys]
            let ordered = facts.values.sorted { $0.createdAt > $1.createdAt }
            let data = try encoder.encode(ordered)
            try data.write(to: url, options: .atomic)
        } catch let error as VectorStoreError {
            throw error
        } catch {
            throw VectorStoreError.persistenceFailed("Could not write vector store: \(error.localizedDescription)")
        }
    }
}

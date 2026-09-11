import Foundation

/// Where a memory result came from.
public enum MemorySource: String, Sendable, Codable, Equatable, CaseIterable {
    /// Past conversation turns (episodic store).
    case episodic
    /// Facts with embeddings (vector store).
    case semantic
    /// Long-lived user profile facts and preferences.
    case profile
}

/// One retrieved memory with its relevance score.
///
/// Higher `score` means more relevant: cosine similarity in `[-1, 1]`
/// for semantic hits, `1.0`-descending rank order for episodic hits,
/// and stored `confidence` for profile hits.
public struct MemoryResult: Sendable, Codable, Equatable {
    /// Human-readable content.
    public let content: String
    /// Relevance score (higher is more relevant).
    public let score: Double
    /// Which memory tier produced this result.
    public let source: MemorySource
    /// Key/value annotations (session id, fact id, role, ...).
    public let metadata: [String: String]

    /// Creates a memory result.
    /// - Parameters:
    ///   - content: Result content.
    ///   - score: Relevance score.
    ///   - source: Originating tier.
    ///   - metadata: Key/value annotations. Defaults to empty.
    public init(content: String, score: Double, source: MemorySource, metadata: [String: String] = [:]) {
        self.content = content
        self.score = score
        self.source = source
        self.metadata = metadata
    }
}

/// A long-lived fact about the user held in the profile.
public struct UserFact: Sendable, Codable, Equatable, Identifiable {
    /// Unique identifier for this fact.
    public let id: UUID
    /// Human-readable fact text.
    public let content: String
    /// Confidence in `[0, 1]`. Extracted facts start below `1.0`.
    public let confidence: Double
    /// Where the fact came from (e.g. `"user"`, `"extracted"`, `"import"`).
    public let source: String
    /// When the fact was last confirmed or updated.
    public let lastConfirmed: Date

    /// Creates a user fact.
    /// - Parameters:
    ///   - id: Unique identifier. Defaults to a new UUID.
    ///   - content: Fact text.
    ///   - confidence: Confidence in `[0, 1]`. Defaults to `1.0`.
    ///   - source: Origin label. Defaults to `"user"`.
    ///   - lastConfirmed: Confirmation date. Defaults to now.
    public init(
        id: UUID = UUID(),
        content: String,
        confidence: Double = 1.0,
        source: String = "user",
        lastConfirmed: Date = Date()
    ) {
        self.id = id
        self.content = content
        self.confidence = confidence
        self.source = source
        self.lastConfirmed = lastConfirmed
    }
}

/// A key/value preference about the user (e.g. `name` → `"Ada"`).
public struct Preference: Sendable, Codable, Equatable {
    /// Preference key (e.g. `"name"`, `"likes"`, `"favorite-drink"`).
    public let key: String
    /// Preference value.
    public let value: String
    /// Confidence in `[0, 1]`.
    public let confidence: Double

    /// Creates a preference.
    /// - Parameters:
    ///   - key: Preference key.
    ///   - value: Preference value.
    ///   - confidence: Confidence in `[0, 1]`. Defaults to `1.0`.
    public init(key: String, value: String, confidence: Double = 1.0) {
        self.key = key
        self.value = value
        self.confidence = confidence
    }
}

/// The user's long-lived profile: facts plus preferences.
public struct UserProfile: Sendable, Codable, Equatable {
    /// Long-lived facts about the user.
    public var facts: [UserFact]
    /// Key/value preferences.
    public var preferences: [Preference]
    /// When the profile was last mutated.
    public var lastUpdated: Date

    /// Creates a user profile.
    /// - Parameters:
    ///   - facts: Long-lived facts. Defaults to empty.
    ///   - preferences: Preferences. Defaults to empty.
    ///   - lastUpdated: Mutation date. Defaults to now.
    public init(facts: [UserFact] = [], preferences: [Preference] = [], lastUpdated: Date = Date()) {
        self.facts = facts
        self.preferences = preferences
        self.lastUpdated = lastUpdated
    }

    /// Empty profile stamped with the current date.
    public static var empty: UserProfile {
        UserProfile()
    }
}

/// Failures raised by ``MemoryEngine``.
public enum MemoryEngineError: Error, Sendable, Equatable {
    /// The profile file could not be read or written.
    case profileUnavailable(String)
    /// An underlying episodic write or read failed.
    case episodicFailed(String)
    /// An underlying semantic write failed.
    case semanticFailed(String)
}

/// Three-tier memory: episodic (SQLite + FTS5), semantic (vector),
/// and profile (structured user facts and preferences).
///
/// Memory flow: user input lands in working memory (the
/// `ConversationManager`), completed turns are fanned out here via
/// ``MemoryEngine/storeEpisodic(content:metadata:sessionID:role:)``,
/// key facts are extracted via
/// ``MemoryEngine/extractAndStoreFacts(from:embeddings:)`` and stored
/// with embeddings via
/// ``MemoryEngine/storeSemantic(fact:embedding:metadata:confidence:source:)``,
/// and future queries recall both tiers plus the profile.
public actor MemoryEngine {
    /// Episodic conversation-history store.
    private let episodeStore: EpisodeStore
    /// Semantic fact/vector store.
    private let vectorStore: VectorStore
    /// In-memory profile snapshot, mirrored to disk best-effort.
    private var profile: UserProfile
    /// JSON file backing the profile, if configured.
    private let profilePath: String?

    /// Creates an engine from live stores.
    /// - Parameters:
    ///   - episodeStore: Episodic store.
    ///   - vectorStore: Semantic store.
    ///   - profilePath: JSON file for the profile. Defaults to nil
    ///     (memory only).
    ///   - initialProfile: Starting profile. Defaults to the file
    ///     contents when `profilePath` exists, else empty.
    public init(
        episodeStore: EpisodeStore,
        vectorStore: VectorStore,
        profilePath: String? = nil,
        initialProfile: UserProfile? = nil
    ) {
        self.episodeStore = episodeStore
        self.vectorStore = vectorStore
        self.profilePath = profilePath
        if let initialProfile {
            self.profile = initialProfile
        } else if let profilePath, let loaded = Self.loadProfileBestEffort(path: profilePath) {
            self.profile = loaded
        } else {
            self.profile = UserProfile.empty
        }
    }

    /// Creates an engine from filesystem paths.
    /// - Parameters:
    ///   - episodesDBPath: SQLite path for episodic memory.
    ///   - vectorDBPath: Directory for semantic memory.
    ///   - profilePath: JSON file for the profile. When nil, defaults
    ///     to `<episodesDBPath>.profile.json`.
    public init(episodesDBPath: String, vectorDBPath: String, profilePath: String? = nil) {
        self.init(
            episodeStore: EpisodeStore(dbPath: episodesDBPath),
            vectorStore: VectorStore(directoryPath: vectorDBPath),
            profilePath: profilePath ?? (episodesDBPath + ".profile.json")
        )
    }

    /// Creates an engine from the shared memory config.
    /// - Parameter config: Memory paths from `config.toml`.
    public init(config: MemoryConfig) {
        self.init(episodesDBPath: config.episodesDBPath, vectorDBPath: config.vectorDBPath)
    }

    // MARK: - Episodic

    /// Stores one conversation turn in episodic memory.
    /// - Parameters:
    ///   - content: Turn text.
    ///   - metadata: Key/value annotations. Defaults to empty.
    ///   - sessionID: Owning session. Defaults to a new UUID.
    ///   - role: Who produced the turn. Defaults to `.user`.
    /// - Returns: The stored turn as a memory result.
    @discardableResult
    public func storeEpisodic(
        content: String,
        metadata: [String: String]? = nil,
        sessionID: UUID = UUID(),
        role: Message.Role = .user
    ) async throws -> MemoryResult {
        do {
            let episode = try await episodeStore.store(
                sessionID: sessionID,
                role: role,
                content: content,
                metadata: metadata ?? [:]
            )
            return MemoryResult(
                content: episode.content,
                score: 1.0,
                source: .episodic,
                metadata: ["id": episode.id.uuidString, "session_id": sessionID.uuidString, "role": role.rawValue]
            )
        } catch {
            throw MemoryEngineError.episodicFailed(error.localizedDescription)
        }
    }

    /// Searches episodic memory by keyword.
    /// - Parameters:
    ///   - query: Search text.
    ///   - limit: Maximum results. Defaults to 10.
    /// - Returns: Matching turns, best first.
    public func searchEpisodes(query: String, limit: Int = 10) async throws -> [MemoryResult] {
        do {
            let episodes = try await episodeStore.search(query: query, limit: max(1, limit))
            return episodes.enumerated().map { index, episode in
                MemoryResult(
                    content: episode.content,
                    score: 1.0 / Double(index + 1),
                    source: .episodic,
                    metadata: [
                        "id": episode.id.uuidString,
                        "session_id": episode.sessionID.uuidString,
                        "role": episode.role.rawValue
                    ]
                )
            }
        } catch {
            throw MemoryEngineError.episodicFailed(error.localizedDescription)
        }
    }

    // MARK: - Semantic

    /// Stores a fact in semantic memory and in the user profile.
    /// - Parameters:
    ///   - fact: Fact text.
    ///   - embedding: Embedding vector for the fact.
    ///   - metadata: Key/value annotations. Defaults to empty.
    ///   - confidence: Confidence in `[0, 1]`. Defaults to `1.0`.
    ///   - source: Origin label. Defaults to `"user"`.
    /// - Returns: The profile fact that was recorded.
    @discardableResult
    public func storeSemantic(
        fact: String,
        embedding: [Float],
        metadata: [String: String]? = nil,
        confidence: Double = 1.0,
        source: String = "user"
    ) async throws -> UserFact {
        do {
            let stored = try await vectorStore.store(content: fact, embedding: embedding, metadata: metadata ?? [:])
            let userFact = UserFact(
                id: stored.id,
                content: fact,
                confidence: confidence,
                source: source,
                lastConfirmed: Date()
            )
            upsertProfileFact(userFact)
            return userFact
        } catch let error as VectorStoreError {
            throw MemoryEngineError.semanticFailed(String(describing: error))
        } catch {
            throw MemoryEngineError.semanticFailed(error.localizedDescription)
        }
    }

    /// Queries semantic memory by embedding, filtered by metadata.
    ///
    /// When `embedding` is empty the store falls back to keyword
    /// overlap scoring against `query` so callers without an
    /// embeddings model still get useful recall.
    /// - Parameters:
    ///   - query: Query text (used for the keyword fallback and
    ///     echoed in result metadata).
    ///   - embedding: Query vector.
    ///   - limit: Maximum results. Defaults to 5.
    ///   - metadataFilter: Required metadata pairs. Defaults to nil.
    /// - Returns: Matching facts, best first.
    public func querySemantic(
        query: String,
        embedding: [Float],
        limit: Int = 5,
        metadataFilter: [String: String]? = nil
    ) async -> [MemoryResult] {
        let scored: [ScoredFact] = if embedding.isEmpty {
            await vectorStore.search(query: query, limit: max(1, limit), metadataFilter: metadataFilter)
        } else {
            await vectorStore.query(embedding: embedding, limit: max(1, limit), metadataFilter: metadataFilter)
        }
        return scored.map { hit in
            MemoryResult(
                content: hit.fact.content,
                score: hit.score,
                source: .semantic,
                metadata: ["id": hit.fact.id.uuidString, "query": query]
                    .merging(hit.fact.metadata) { current, _ in current }
            )
        }
    }

    // MARK: - Profile

    /// Returns the current user profile.
    /// - Returns: Facts, preferences, and last-update time.
    public func getUserProfile() -> UserProfile {
        profile
    }

    /// Total stored episode count from the shared episode store.
    ///
    /// Exposed so CLI commands can report memory stats from a single
    /// `MemoryEngine` instead of opening an independent `EpisodeStore`
    /// on the same file and diverging.
    /// - Returns: Row count, or 0 when the store is unavailable.
    public func episodeCount() async -> Int {
        await (try? episodeStore.count()) ?? 0
    }

    /// Total stored semantic fact count from the shared vector store.
    /// - Returns: Fact count.
    public func semanticFactCount() async -> Int {
        await vectorStore.count()
    }

    /// All semantic facts, oldest first, from the shared vector store.
    /// - Returns: Stored facts for display commands.
    public func allSemanticFacts() async -> [StoredFact] {
        await vectorStore.allFacts().sorted { $0.createdAt < $1.createdAt }
    }

    /// Records or replaces a preference, then persists the profile.
    /// - Parameter preference: Preference to store.
    public func setPreference(_ preference: Preference) {
        profile.preferences.removeAll { $0.key == preference.key && $0.value == preference.value }
        profile.preferences.append(preference)
        touchProfile()
    }

    /// Removes a preference by key and value.
    /// - Parameters:
    ///   - key: Preference key.
    ///   - value: Preference value.
    public func removePreference(key: String, value: String) {
        profile.preferences.removeAll { $0.key == key && $0.value == value }
        touchProfile()
    }

    /// Confirms a profile fact, refreshing its confidence and timestamp.
    /// - Parameters:
    ///   - id: Fact identifier.
    ///   - confidence: New confidence. Defaults to `1.0`.
    public func confirmFact(id: UUID, confidence: Double = 1.0) {
        guard let index = profile.facts.firstIndex(where: { $0.id == id }) else { return }
        let existing = profile.facts[index]
        profile.facts[index] = UserFact(
            id: existing.id,
            content: existing.content,
            confidence: confidence,
            source: existing.source,
            lastConfirmed: Date()
        )
        touchProfile()
    }

    /// Removes a profile fact (semantic rows are left for `reindex`).
    /// - Parameter id: Fact identifier.
    public func removeFact(id: UUID) {
        profile.facts.removeAll { $0.id == id }
        touchProfile()
    }

    // MARK: - Extraction

    /// Extracts durable facts and preferences from free text.
    ///
    /// Rule-based and fully local: splits `text` into sentences, keeps
    /// first-person / possessive / "remember" sentences as facts, pulls
    /// `call me X`, `my favorite X is Y`, and `I like/love/prefer X`
    /// patterns into preferences, then stores each fact with the
    /// caller-supplied embedding (or a keyword-only row when none is
    /// given for that sentence) so search keeps working.
    /// - Parameters:
    ///   - text: Free text (e.g. a user message) to mine.
    ///   - embeddings: Optional per-sentence embeddings keyed by the
    ///     exact sentence text. Defaults to empty (keyword-only rows).
    /// - Returns: Facts that were stored.
    @discardableResult
    public func extractAndStoreFacts(
        from text: String,
        embeddings: [String: [Float]] = [:]
    ) async throws -> [UserFact] {
        let sentences = Self.splitSentences(text)
        var created: [UserFact] = []
        for sentence in sentences {
            if let preference = Self.extractPreference(from: sentence) {
                setPreference(preference)
            }
            guard Self.isFactLike(sentence) else { continue }
            let embedding = embeddings[sentence] ?? []
            let stored: StoredFact
            do {
                stored = try await vectorStore.store(content: sentence, embedding: embedding)
            } catch let error as VectorStoreError {
                throw MemoryEngineError.semanticFailed(String(describing: error))
            }
            let fact = UserFact(
                id: stored.id,
                content: sentence,
                confidence: 0.9,
                source: "extracted",
                lastConfirmed: Date()
            )
            upsertProfileFact(fact)
            created.append(fact)
        }
        return created
    }

    // MARK: - Combined recall

    /// Recalls across episodic, semantic, and profile tiers at once.
    ///
    /// Episodic keyword hits, semantic vector/keyword hits, and
    /// profile keyword hits are merged and sorted by score descending.
    /// - Parameters:
    ///   - query: Query text.
    ///   - embedding: Optional query vector. When nil or empty,
    ///     semantic search uses keyword scoring.
    ///   - limit: Maximum results per tier before merging.
    ///     Defaults to 10.
    /// - Returns: Merged results, best first.
    public func recall(query: String, embedding: [Float]? = nil, limit: Int = 10) async throws -> [MemoryResult] {
        let perTier = max(1, limit)
        var merged = try await searchEpisodes(query: query, limit: perTier)
        merged += await querySemantic(query: query, embedding: embedding ?? [], limit: perTier)
        merged += profileResults(query: query)
        return merged.sorted { $0.score > $1.score }.prefix(perTier * 2).map(\.self)
    }

    /// Keyword matches against profile facts and preferences.
    /// - Parameter query: Search text.
    /// - Returns: Profile hits scored by token overlap.
    private func profileResults(query: String) -> [MemoryResult] {
        let queryTokens = Self.tokenize(query)
        guard !queryTokens.isEmpty else { return [] }
        var results: [MemoryResult] = []
        for fact in profile.facts {
            let overlap = queryTokens.intersection(Self.tokenize(fact.content)).count
            let substring = fact.content.range(of: query, options: .caseInsensitive) != nil
            guard overlap > 0 || substring else { continue }
            results.append(MemoryResult(
                content: fact.content,
                score: (Double(overlap * 2 + (substring ? 1 : 0)) / 10.0) * max(fact.confidence, 0.1),
                source: .profile,
                metadata: ["id": fact.id.uuidString, "confidence": "\(fact.confidence)"]
            ))
        }
        for preference in profile.preferences {
            let haystack = "\(preference.key) \(preference.value)"
            let overlap = queryTokens.intersection(Self.tokenize(haystack)).count
            let substring = haystack.range(of: query, options: .caseInsensitive) != nil
            guard overlap > 0 || substring else { continue }
            results.append(MemoryResult(
                content: "\(preference.key): \(preference.value)",
                score: (Double(overlap * 2 + (substring ? 1 : 0)) / 10.0) * max(preference.confidence, 0.1),
                source: .profile,
                metadata: ["key": preference.key, "value": preference.value]
            ))
        }
        return results.sorted { $0.score > $1.score }
    }

    // MARK: - Profile internals

    /// Inserts or replaces a profile fact by `id`, then persists.
    /// - Parameter fact: Fact to record.
    private func upsertProfileFact(_ fact: UserFact) {
        profile.facts.removeAll { $0.id == fact.id }
        profile.facts.append(fact)
        touchProfile()
    }

    /// Stamps `lastUpdated` and mirrors the profile to disk best-effort.
    private func touchProfile() {
        profile.lastUpdated = Date()
        persistProfileBestEffort()
    }

    /// Writes the profile JSON without throwing (used after mutation).
    private func persistProfileBestEffort() {
        guard let profilePath else { return }
        guard let snapshot = try? JSONEncoder().encode(profileSnapshot()) else { return }
        let expanded = (profilePath as NSString).expandingTildeInPath
        let directory = (expanded as NSString).deletingLastPathComponent
        if !directory.isEmpty {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        try? snapshot.write(to: URL(fileURLWithPath: expanded), options: .atomic)
    }

    /// Snapshot of the profile with a fresh timestamp.
    /// - Returns: The current profile value.
    private func profileSnapshot() -> UserProfile {
        profile
    }

    /// Loads a persisted profile without throwing (used from `init`).
    /// - Parameter path: JSON file path.
    /// - Returns: The profile, or nil on any failure.
    private static func loadProfileBestEffort(path: String) -> UserProfile? {
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else { return nil }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: expanded)) else { return nil }
        return try? JSONDecoder().decode(UserProfile.self, from: data)
    }

    // MARK: - Heuristics

    /// Splits text into trimmed sentence candidates.
    /// - Parameter text: Free text.
    /// - Returns: Sentences longer than a couple of characters.
    private static func splitSentences(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 2 }
    }

    /// Whether a sentence looks worth remembering.
    ///
    /// Keeps first-person statements, possessives, and explicit
    /// "remember" requests; drops bare questions and very short text.
    /// - Parameter sentence: Candidate sentence.
    /// - Returns: True when the sentence should become a fact.
    private static func isFactLike(_ sentence: String) -> Bool {
        let lower = sentence.lowercased()
        if lower.hasSuffix("?") {
            return false
        }
        let markers = ["i am", "i'm", "i like", "i love", "i prefer", "i work", "i live", "my ", "remember"]
        return markers.contains { lower.contains($0) } || sentence.count > 40
    }

    /// Pulls a `Preference` out of common phrasings.
    /// - Parameter sentence: Candidate sentence.
    /// - Returns: A preference, or nil when no pattern matches.
    private static func extractPreference(from sentence: String) -> Preference? {
        let lower = sentence.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = lower.range(of: "call me ") {
            let name = sentence[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,"))
            guard !name.isEmpty, name.count < 60 else { return nil }
            return Preference(key: "name", value: name, confidence: 0.95)
        }
        if lower.contains("my favorite"), lower.contains(" is ") {
            let parts = sentence.components(separatedBy: CharacterSet(charactersIn: ":"))
            let clause = parts.last ?? sentence
            let sides = clause.components(separatedBy: " is ")
            guard sides.count >= 2 else { return nil }
            let keyPart = sides[0].lowercased()
            let keyTokens = keyPart.split(separator: " ").suffix(2).map(String.init).joined(separator: "-")
            let value = sides[1...].joined(separator: " is ").trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,"))
            guard !keyTokens.isEmpty, !value.isEmpty, value.count < 120 else { return nil }
            return Preference(key: "favorite-\(keyTokens)", value: value, confidence: 0.9)
        }
        for marker in ["i love ", "i like ", "i prefer "] {
            if let range = lower.range(of: marker) {
                let value = sentence[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,"))
                guard !value.isEmpty, value.count < 120 else { return nil }
                return Preference(key: "likes", value: value, confidence: 0.85)
            }
        }
        return nil
    }

    /// Lowercased alphanumeric tokens for keyword scoring.
    /// - Parameter text: Text to tokenize.
    /// - Returns: Token set.
    private static func tokenize(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { !$0.isEmpty })
    }
}

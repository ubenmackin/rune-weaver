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

/// Failure policy for episodic turn mirroring.
///
/// Single policy shared by the orchestrator (silent) and the CLI chat
/// loop (report) so both callers use one `MemoryEngine`-owned helper
/// with an explicit policy instead of duplicated helpers.
public enum MirrorFailurePolicy: Sendable, Equatable {
    /// Ignore mirror failures.
    case silent
    /// Invoke the failure handler with the shared message.
    case report
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
    /// Maximum results fetched per tier before merging.
    ///
    /// Bounds fan-out so huge limits (e.g. `.max`) never issue unbounded
    /// store queries; stores additionally clamp to `Int32.max` at the
    /// SQLite boundary.
    private static let maxPerTierResults = 1000
    /// Maximum characters accepted for a single stored content.
    ///
    /// Bounds episodic turns and semantic facts alike so unbounded input
    /// never materializes huge rows; consistent with the tighter
    /// preference caps applied during extraction.
    public static let maxContentLength = 10000
    /// Maximum episodic records retained before auto-compacting old sessions.
    public static let maxEpisodicCount = 10000

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
    ///   - content: Turn text. Must be non-empty after trimming
    ///     whitespace and at most `maxContentLength` characters;
    ///     empty or overlong content is rejected.
    ///   - metadata: Key/value annotations. Defaults to empty.
    ///   - sessionID: Owning session. Defaults to a new UUID.
    ///   - role: Who produced the turn. Defaults to `.user`.
    /// - Returns: The stored turn as a memory result.
    /// - Throws: `MemoryEngineError/episodicFailed(_:)` when the content
    ///   is empty, exceeds `maxContentLength`, or the store write fails.
    @discardableResult
    public func storeEpisodic(
        content: String,
        metadata: [String: String]? = nil,
        sessionID: UUID = UUID(),
        role: Message.Role = .user
    ) async throws -> MemoryResult {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MemoryEngineError.episodicFailed("Content must not be empty.")
        }
        guard content.count <= Self.maxContentLength else {
            throw MemoryEngineError.episodicFailed("Content exceeds \(Self.maxContentLength) characters.")
        }
        do {
            let episode = try await episodeStore.store(
                sessionID: sessionID,
                role: role,
                content: content,
                metadata: metadata ?? [:]
            )
            if let total = try? await episodeStore.count(), total > Self.maxEpisodicCount {
                _ = try? await episodeStore.compactSessions(olderThan: Date().addingTimeInterval(-30 * 86400))
            }
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

    /// Compacts episodic sessions older than the specified date.
    /// - Parameters:
    ///   - olderThan: Date cutoff for compaction.
    /// - Returns: Compacted episode summaries.
    @discardableResult
    public func compactEpisodic(olderThan: Date) async throws -> [EpisodeSummary] {
        try await episodeStore.compactSessions(olderThan: olderThan)
    }

    /// Searches episodic memory by keyword.
    /// - Parameters:
    ///   - query: Search text.
    ///   - limit: Maximum results. Defaults to 10. Non-positive limits
    ///     return an empty list. Larger limits are capped per tier.
    /// - Returns: Matching turns, best first.
    public func searchEpisodes(query: String, limit: Int = 10) async throws -> [MemoryResult] {
        guard limit > 0 else { return [] }
        let clamped = min(limit, Self.maxPerTierResults)
        let episodes = try await withEpisodic {
            try await episodeStore.search(query: query, limit: clamped)
        }
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
    }

    /// Runs an episodic store operation, mapping failures.
    /// - Parameter work: Store operation to run.
    /// - Returns: Operation result.
    /// - Throws: `MemoryEngineError/episodicFailed(_:)` when the store fails.
    private func withEpisodic<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch {
            throw MemoryEngineError.episodicFailed(error.localizedDescription)
        }
    }

    /// Returns stored episodes for one session, oldest first.
    ///
    /// Exposed so the chat REPL can hydrate working memory on
    /// `--session` resume from the same episodic store every turn
    /// mirrors into, keeping session continuity without opening an
    /// independent `EpisodeStore`. When `limit` is set, returns the
    /// oldest `limit` episodes; use `recentEpisodes(for:limit:)` for
    /// the newest window needed by resume hydration.
    /// - Parameters:
    ///   - sessionID: Owning session identifier.
    ///   - limit: Maximum episodes. Defaults to nil (all). When set,
    ///     the oldest `limit` episodes are returned. Non-positive limits
    ///     return an empty list.
    /// - Returns: Matching episodes in chronological order.
    /// - Throws: `MemoryEngineError/episodicFailed(_:)` when the read fails.
    public func episodes(for sessionID: UUID, limit: Int? = nil) async throws -> [Episode] {
        if let limit, limit <= 0 {
            return []
        }
        let clamped = limit.map { min($0, Self.maxPerTierResults) }
        return try await withEpisodic {
            try await episodeStore.episodes(for: sessionID, limit: clamped)
        }
    }

    /// Returns the newest stored episodes for one session, oldest first.
    ///
    /// Bounded resume path: fetches only the last `limit` turns instead
    /// of loading the whole session, then returns them in chronological
    /// order for direct history hydration.
    /// - Parameters:
    ///   - sessionID: Owning session identifier.
    ///   - limit: Maximum episodes. Non-positive limits return an empty list.
    /// - Returns: Newest episodes in chronological order.
    /// - Throws: `MemoryEngineError/episodicFailed(_:)` when the read fails.
    public func recentEpisodes(for sessionID: UUID, limit: Int) async throws -> [Episode] {
        guard limit > 0 else { return [] }
        let clamped = min(limit, Self.maxPerTierResults)
        return try await withEpisodic {
            try await episodeStore.recentEpisodes(for: sessionID, limit: clamped)
        }
    }

    /// Deletes every episodic turn for a session. Unknown sessions are a no-op.
    ///
    /// Used by `/clear` so working memory (`ConversationManager`) and the
    /// durable episodic mirror stay consistent sharing one database file.
    /// - Parameter sessionID: Owning session identifier.
    /// - Throws: `MemoryEngineError/episodicFailed(_:)` when the delete fails.
    public func deleteSession(_ sessionID: UUID) async throws {
        try await withEpisodic {
            try await episodeStore.deleteSession(sessionID)
        }
    }

    // MARK: - Semantic

    /// Stores a fact in semantic memory and in the user profile.
    /// - Parameters:
    ///   - fact: Fact text. Leading/trailing whitespace is trimmed. Must not
    ///     exceed `maxContentLength` characters.
    ///   - embedding: Embedding vector for the fact.
    ///   - metadata: Key/value annotations. Defaults to empty.
    ///   - confidence: Confidence in `[0, 1]` stored on the profile fact.
    ///     Defaults to `1.0`.
    ///   - source: Origin label. Defaults to `"user"`.
    /// - Returns: The profile fact that was recorded.
    /// - Throws: `MemoryEngineError/semanticFailed(_:)` when the fact
    ///   is empty, has no alphanumeric characters, exceeds
    ///   `maxContentLength`, holds an out-of-range confidence, or the
    ///   store write fails.
    @discardableResult
    public func storeSemantic(
        fact: String,
        embedding: [Float],
        metadata: [String: String]? = nil,
        confidence: Double = 1.0,
        source: String = "user"
    ) async throws -> UserFact {
        let trimmed = try Self.validatedFactText(fact)
        guard (0.0 ... 1.0).contains(confidence) else {
            throw MemoryEngineError.semanticFailed("Confidence must be in [0, 1].")
        }
        return try await persistValidatedFact(
            content: trimmed,
            embedding: embedding,
            metadata: metadata ?? [:],
            confidence: confidence,
            source: source
        )
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
    ///   - limit: Maximum results. Defaults to 5. Non-positive limits
    ///     return an empty list. Larger limits are capped per tier.
    ///   - metadataFilter: Required metadata pairs. Defaults to nil.
    /// - Returns: Matching facts, best first.
    public func querySemantic(
        query: String,
        embedding: [Float],
        limit: Int = 5,
        metadataFilter: [String: String]? = nil
    ) async -> [MemoryResult] {
        guard limit > 0 else { return [] }
        let clamped = min(limit, Self.maxPerTierResults)
        let scored: [ScoredFact] = if embedding.isEmpty {
            await vectorStore.search(query: query, limit: clamped, metadataFilter: metadataFilter)
        } else {
            await vectorStore.query(embedding: embedding, limit: clamped, metadataFilter: metadataFilter)
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

    /// Stores an explicit user-supplied fact in structured memory.
    ///
    /// Persists `content` as a keyword-only row in the vector store (no
    /// embeddings model required) and mirrors it into the user profile
    /// so both `getUserProfile()` and `allSemanticFacts()` surface it
    /// for display commands. Vector-backed similarity stays deferred
    /// until a local embeddings backend exists.
    /// - Parameters:
    ///   - content: Fact text. Leading/trailing whitespace is trimmed. Must not
    ///     exceed `maxContentLength` characters.
    ///   - source: Origin label. Defaults to `"chat"`.
    ///   - confidence: Confidence in `[0, 1]`. Defaults to `1.0`.
    /// - Returns: The profile fact that was recorded.
    /// - Throws: `MemoryEngineError/semanticFailed(_:)` when the fact
    ///   is empty, has no alphanumeric characters, exceeds
    ///   `maxContentLength`, holds an out-of-range confidence, or the
    ///   store write fails.
    @discardableResult
    public func storeProfileFact(
        content: String,
        source: String = "chat",
        confidence: Double = 1.0
    ) async throws -> UserFact {
        let trimmed = try Self.validatedFactText(content)
        guard (0.0 ... 1.0).contains(confidence) else {
            throw MemoryEngineError.semanticFailed("Confidence must be in [0, 1].")
        }
        return try await persistValidatedFact(
            content: trimmed,
            embedding: [],
            metadata: ["source": source],
            confidence: confidence,
            source: source
        )
    }

    /// Persists one fact to the vector store and mirrors it into the profile.
    ///
    /// Validating entry shared by fact extraction so vector writes,
    /// profile mirroring, and error mapping stay in one place. Trims and
    /// validates `content` once before delegating to
    /// `persistValidatedFact(content:embedding:metadata:confidence:source:)`.
    /// Callers validate `confidence` is in `[0, 1]` before delegating here.
    /// - Parameters:
    ///   - content: Fact text to store. Leading/trailing whitespace is trimmed.
    ///   - embedding: Embedding vector (empty for keyword-only rows).
    ///   - metadata: Key/value annotations.
    ///   - confidence: Confidence in `[0, 1]` stored on the profile fact.
    ///   - source: Origin label.
    /// - Returns: The profile fact that was recorded.
    /// - Throws: `MemoryEngineError/semanticFailed(_:)` when the fact
    ///   is empty, has no alphanumeric characters, exceeds
    ///   `maxContentLength`, or the store write fails.
    private func persistFact(
        content: String,
        embedding: [Float],
        metadata: [String: String],
        confidence: Double,
        source: String
    ) async throws -> UserFact {
        let trimmed = try Self.validatedFactText(content)
        return try await persistValidatedFact(
            content: trimmed,
            embedding: embedding,
            metadata: metadata,
            confidence: confidence,
            source: source
        )
    }

    /// Persists one already-validated fact to the vector store and mirrors it into the profile.
    ///
    /// Shared by `storeSemantic`, `storeProfileFact`, and `persistFact`
    /// so validation happens once per store: callers pass trimmed text
    /// from `validatedFactText(_:)` and this helper assumes it is
    /// non-empty, alphanumeric, and within `maxContentLength`.
    /// - Parameters:
    ///   - content: Trimmed fact text, already validated.
    ///   - embedding: Embedding vector (empty for keyword-only rows).
    ///   - metadata: Key/value annotations.
    ///   - confidence: Confidence in `[0, 1]` stored on the profile fact.
    ///   - source: Origin label.
    /// - Returns: The profile fact that was recorded.
    /// - Throws: `MemoryEngineError/semanticFailed(_:)` when the store write fails.
    private func persistValidatedFact(
        content trimmed: String,
        embedding: [Float],
        metadata: [String: String],
        confidence: Double,
        source: String
    ) async throws -> UserFact {
        do {
            let stored = try await vectorStore.store(content: trimmed, embedding: embedding, metadata: metadata)
            let fact = UserFact(
                id: stored.id,
                content: trimmed,
                confidence: confidence,
                source: source,
                lastConfirmed: Date()
            )
            upsertProfileFact(fact)
            return fact
        } catch let error as VectorStoreError {
            throw MemoryEngineError.semanticFailed(String(describing: error))
        } catch {
            throw MemoryEngineError.semanticFailed(error.localizedDescription)
        }
    }

    /// Records a preference, then persists the profile.
    ///
    /// Single-value keys (currently `name`) replace any existing row
    /// with the same key so `call me X` never stacks names. All other
    /// keys (including `likes` and `favorite-*`) accumulate: only an
    /// exact key-plus-value duplicate is removed before appending, so
    /// `I like apples` then `I like oranges` keeps both while storing
    /// `I like apples` twice keeps one row.
    /// - Parameter preference: Preference to store.
    public func setPreference(_ preference: Preference) {
        if Self.isSingleValuePreferenceKey(preference.key) {
            profile.preferences.removeAll { $0.key == preference.key }
        } else {
            profile.preferences.removeAll { $0.key == preference.key && $0.value == preference.value }
        }
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
    ///
    /// Confidence is clamped to `[0, 1]` so out-of-range input cannot
    /// inflate later recall scoring.
    /// - Parameters:
    ///   - id: Fact identifier.
    ///   - confidence: New confidence in `[0, 1]`. Defaults to `1.0`.
    public func confirmFact(id: UUID, confidence: Double = 1.0) {
        guard let index = profile.facts.firstIndex(where: { $0.id == id }) else { return }
        let clamped = min(max(confidence, 0.0), 1.0)
        let existing = profile.facts[index]
        profile.facts[index] = UserFact(
            id: existing.id,
            content: existing.content,
            confidence: clamped,
            source: existing.source,
            lastConfirmed: Date()
        )
        touchProfile()
    }

    /// Removes a profile fact without touching the vector store.
    ///
    /// Profile-only path: drops the profile mirror and persists, so
    /// synchronous callers keep working. Use the async
    /// ``MemoryEngine/removeFact(id:)`` when the semantic row must be
    /// deleted as well, or ``MemoryEngine/removeFactThrowing(id:)``
    /// when failures must throw. Named distinctly from the async
    /// `removeFact` so forgetting `await` is a compile error instead
    /// of a silent profile-only delete leaving an orphaned vector row.
    /// - Parameter id: Fact identifier. Unknown identifiers are a no-op.
    public func removeProfileFact(id: UUID) {
        profile.facts.removeAll { $0.id == id }
        touchProfile()
    }

    /// Removes a profile fact and its semantic row best-effort.
    ///
    /// Deletes the vector row first with failures ignored, then
    /// removes the profile mirror so callers never need `try`. When
    /// the vector delete fails the orphaned row stays recallable via
    /// the keyword fallback until reindex or clear; use
    /// ``MemoryEngine/removeFactThrowing(id:)`` when the caller must
    /// observe persistence failures. Synchronous callers without an
    /// async context should use ``MemoryEngine/removeProfileFact(id:)``
    /// instead.
    /// - Parameter id: Fact identifier. Unknown identifiers are a no-op.
    public func removeFact(id: UUID) async {
        try? await vectorStore.remove(id: id)
        profile.facts.removeAll { $0.id == id }
        touchProfile()
    }

    /// Removes a profile fact and its semantic row, reporting failures.
    ///
    /// Deletes the vector row first so orphaned rows never stay
    /// recallable, then removes the profile mirror.
    /// - Parameter id: Fact identifier. Unknown identifiers are a no-op.
    /// - Throws: `MemoryEngineError/semanticFailed(_:)` when the vector
    ///   delete fails.
    public func removeFactThrowing(id: UUID) async throws {
        do {
            try await vectorStore.remove(id: id)
        } catch let error as VectorStoreError {
            throw MemoryEngineError.semanticFailed(String(describing: error))
        } catch {
            throw MemoryEngineError.semanticFailed(error.localizedDescription)
        }
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
    /// given for that sentence) so search keeps working. Sentences
    /// without alphanumeric content are skipped. Writes are
    /// failure-isolated per sentence: one persist failure (e.g. an
    /// embedding width mismatch) skips that sentence and the rest still
    /// store, returning only successes. This failure-isolated method never
    /// throws; every per-sentence failure is swallowed so extraction never
    /// interrupts the caller. Use `extractAndStoreFactsThrowing(from:embeddings:)`
    /// when the caller must observe persist failures.
    /// - Parameters:
    ///   - text: Free text (e.g. a user message) to mine.
    ///   - embeddings: Optional per-sentence embeddings keyed by the
    ///     exact sentence text. Defaults to empty (keyword-only rows).
    /// - Returns: Facts that were stored.
    @discardableResult
    public func extractAndStoreFacts(
        from text: String,
        embeddings: [String: [Float]] = [:]
    ) async -> [UserFact] {
        let sentences = Self.splitSentences(text)
        var created: [UserFact] = []
        for sentence in sentences {
            do {
                let facts = try await collectFactsThrowing(from: sentence, embeddings: embeddings)
                created.append(contentsOf: facts)
            } catch {
                continue
            }
        }
        return created
    }

    /// Extracts durable facts and preferences from free text, reporting failures.
    ///
    /// Throwing overload of `extractAndStoreFacts(from:embeddings:)` with
    /// identical sentence splitting, preference extraction, and fact
    /// filtering. Unlike the failure-isolated variant, the first persist
    /// failure (e.g. an embedding width mismatch) is thrown so callers can
    /// observe store errors; facts stored before the failure remain stored.
    /// - Parameters:
    ///   - text: Free text (e.g. a user message) to mine.
    ///   - embeddings: Optional per-sentence embeddings keyed by the
    ///     exact sentence text. Defaults to empty (keyword-only rows).
    /// - Returns: Facts that were stored.
    /// - Throws: `MemoryEngineError/semanticFailed(_:)` when a fact persist fails.
    @discardableResult
    public func extractAndStoreFactsThrowing(
        from text: String,
        embeddings: [String: [Float]] = [:]
    ) async throws -> [UserFact] {
        try await collectFactsThrowing(from: text, embeddings: embeddings)
    }

    /// Collects facts from free text, throwing on the first persist failure.
    ///
    /// Single shared extraction loop for `extractAndStoreFacts(from:embeddings:)`
    /// and `extractAndStoreFactsThrowing(from:embeddings:)`: splits `text`
    /// into sentences, records preferences, filters fact-like storable
    /// sentences, and persists each with its caller-supplied embedding.
    /// The failure-isolated wrapper calls this helper per sentence and
    /// catches, so one width mismatch never aborts the remaining sentences.
    /// - Parameters:
    ///   - text: Free text (e.g. a user message) to mine.
    ///   - embeddings: Optional per-sentence embeddings keyed by the
    ///     exact sentence text.
    /// - Returns: Facts that were stored.
    /// - Throws: `MemoryEngineError/semanticFailed(_:)` when a fact persist fails.
    private func collectFactsThrowing(
        from text: String,
        embeddings: [String: [Float]]
    ) async throws -> [UserFact] {
        let sentences = Self.splitSentences(text)
        var created: [UserFact] = []
        for sentence in sentences {
            if let preference = Self.extractPreference(from: sentence) {
                setPreference(preference)
            }
            guard Self.isFactLike(sentence) else { continue }
            guard Self.isStorableFact(sentence) else { continue }
            let embedding = embeddings[sentence] ?? []
            let fact = try await persistFact(
                content: sentence,
                embedding: embedding,
                metadata: ["source": "extracted"],
                confidence: 0.9,
                source: "extracted"
            )
            created.append(fact)
        }
        return created
    }

    // MARK: - Combined recall

    /// Recalls across episodic, semantic, and profile tiers.
    ///
    /// Episodic FTS hits, semantic hits, and profile keyword hits are
    /// always merged and sorted by score descending so memory search
    /// works with zero ML dependencies. When `embedding` holds a query
    /// vector, semantic hits use vector similarity; when nil or empty,
    /// semantic hits fall back to keyword overlap via `querySemantic`
    /// so keyword-only rows (including orphaned vector rows whose
    /// profile fact was removed) stay recallable. Keyword semantic
    /// scores are normalized to `[0, 1]` before merging so tiers share
    /// one scale, and merged hits are deduped by identifier (with content
    /// matches scoped to semantic and profile mirrors, keeping episodic
    /// turns) keeping the best score because profile facts mirror vector rows.
    /// - Parameters:
    ///   - query: Query text.
    ///   - embedding: Optional query vector. When nil or empty,
    ///     semantic search uses the keyword fallback.
    ///   - limit: Maximum results per tier before merging.
    ///     Defaults to 10. Non-positive limits return an empty list.
    ///     Larger limits are capped per tier.
    /// - Returns: Merged results, best first.
    public func recall(query: String, embedding: [Float]? = nil, limit: Int = 10) async throws -> [MemoryResult] {
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
        let merged = episodic + semantic + profile
        let sorted = merged.sorted {
            if $0.score != $1.score {
                return $0.score > $1.score
            }
            return Self.sourcePriority($0.source) > Self.sourcePriority($1.source)
        }
        // `perTier` is capped at `maxPerTierResults` (1000) above, so
        // `perTier * 3` cannot overflow.
        let cap = perTier * 3
        return Array(Self.dedupe(sorted).prefix(cap))
    }
}

// MARK: - MemoryEngine Recall Helpers

extension MemoryEngine {
    /// Keyword matches against profile facts and preferences.
    ///
    /// Scores are clamped to `[0, 1]` so profile hits share one scale
    /// with normalized semantic and episodic hits.
    /// - Parameters:
    ///   - query: Search text.
    ///   - limit: Maximum hits to return. Non-positive limits return
    ///     an empty list.
    /// - Returns: Profile hits scored by token overlap.
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

    /// Normalizes a keyword semantic hit to the shared `[0, 1]` recall scale.
    ///
    /// Keyword overlap scores (`overlap * 2 + substring`) grow unbounded
    /// and would always outrank episodic (`1/(index+1)`) and profile
    /// (`overlap/10 * confidence`) hits. Dividing by `10` aligns keyword
    /// semantic hits with profile scoring.
    /// - Parameter result: Raw semantic hit.
    /// - Returns: Hit with a clamped `[0, 1]` score.
    private static func normalizedSemantic(_ result: MemoryResult) -> MemoryResult {
        MemoryResult(
            content: result.content,
            score: min(max(result.score / 10.0, 0.0), 1.0),
            source: result.source,
            metadata: result.metadata
        )
    }

    /// Priority for tie-breaking merged recall hits.
    ///
    /// Profile hits carry confidence and survive over mirrored vector rows
    /// when scores tie.
    /// - Parameter source: Hit source.
    /// - Returns: Higher wins ties.
    private static func sourcePriority(_ source: MemorySource) -> Int {
        switch source {
        case .profile: 2
        case .semantic: 1
        case .episodic: 0
        }
    }

    /// Dedupes merged recall hits by identifier, with content scope.
    ///
    /// Profile facts mirror vector rows under the same `id`, so recall
    /// would otherwise return the same fact twice with different sources
    /// and scores. Content matches are deduped only between semantic and
    /// profile hits; episodic turns keep their own content even when it
    /// matches a stored fact so identical wording never loses recall
    /// coverage. The input is expected sorted best-first with profile
    /// winning ties; the first occurrence wins.
    /// - Parameter results: Sorted merged hits.
    /// - Returns: Hits with duplicate identifiers or mirrored content removed.
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

// MARK: - MemoryEngine Chat Helpers

public extension MemoryEngine {
    /// Extracts an explicit remember request from chat input.
    ///
    /// Matches case-insensitive `remember that <fact>`, `remember <fact>`,
    /// and `/remember <fact>` forms, preserving the fact's original casing
    /// while trimming surrounding whitespace. The separator after the
    /// command may be any whitespace (space, tab, multiple spaces), not
    /// just a single space. A leading `that` after `/remember` is stripped
    /// only when followed by whitespace or end so hyphenated or punctuated
    /// words such as `that-foo` are preserved. Bare `remember` forms that
    /// look interrogative (a `?` followed by whitespace or end, including
    /// a trailing `?`) are not treated as store requests so conversational
    /// questions such as `remember when we went to Paris? It was great`
    /// still reach the LLM while facts containing `?` inside a token such
    /// as `remember my password is foo?bar` still store; the explicit
    /// `/remember` form always captures.
    /// - Parameter input: Raw user input.
    /// - Returns: Stripped fact text (possibly empty when no fact was
    ///   given), or nil when `input` is not a remember request.
    static func rememberFactText(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let suffix = suffixAfterCommand(trimmed, command: "/remember") {
            return stripLeadingThatWord(from: suffix)
        }
        if let suffix = suffixAfterCommand(trimmed, command: "remember") {
            guard !isInterrogative(trimmed) else { return nil }
            return stripLeadingThatWord(from: suffix)
        }
        return nil
    }

    /// Suffix after a case-insensitive command prefix.
    ///
    /// Accepts the bare command (`remember`) or the command followed by
    /// any whitespace (`remember\tfact`, `remember  fact`), preserving
    /// the fact's original casing while trimming surrounding whitespace.
    /// Matching uses an anchored case-insensitive range so case folding
    /// never misaligns the suffix slice.
    /// - Parameters:
    ///   - trimmed: Already-trimmed user input.
    ///   - command: Command prefix without trailing whitespace.
    /// - Returns: Stripped suffix, or nil when the prefix does not match.
    private static func suffixAfterCommand(_ trimmed: String, command: String) -> String? {
        guard let range = trimmed.range(of: command, options: [.caseInsensitive, .anchored]) else {
            return nil
        }
        if range.upperBound == trimmed.endIndex {
            return ""
        }
        guard trimmed[range.upperBound].isWhitespace else { return nil }
        return String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether trimmed input looks like a question rather than a store request.
    ///
    /// Only a `?` followed by whitespace or end marks an interrogative so
    /// facts containing `?` inside a token (e.g. `foo?bar`) still store
    /// while conversational questions (`remember when we went to Paris?
    /// It was great`, trailing `?`) still reach the LLM.
    /// - Parameter trimmed: Already-trimmed user input.
    /// - Returns: True when a `?` is followed by whitespace or end.
    private static func isInterrogative(_ trimmed: String) -> Bool {
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            if trimmed[index] == "?" {
                let next = trimmed.index(after: index)
                if next == trimmed.endIndex || trimmed[next].isWhitespace {
                    return true
                }
            }
            index = trimmed.index(after: index)
        }
        return false
    }

    /// Strips a leading `that` word from a remember suffix.
    ///
    /// Keeps `/remember that <fact>` consistent with `remember that <fact>`
    /// while tolerating any whitespace run and casing (`that`, `THAT`,
    /// `that  fact`, `that\tfact`). `that` is stripped only when followed
    /// by end or whitespace so hyphenated or punctuated words such as
    /// `that-foo` or `that.foo` are preserved; a bare `that` or `that`
    /// followed only by whitespace becomes empty so the caller prints
    /// usage instead of storing it.
    /// - Parameter suffix: Fact candidate after the remember command.
    /// - Returns: Fact without the leading `that`, empty for bare `that`,
    ///   or the suffix unchanged when `that` starts a longer word or is
    ///   followed by punctuation.
    private static func stripLeadingThatWord(from suffix: String) -> String {
        guard let range = suffix.range(of: "that", options: [.caseInsensitive, .anchored]) else {
            return suffix
        }
        if range.upperBound == suffix.endIndex {
            return ""
        }
        let next = suffix[range.upperBound]
        guard next.isWhitespace else { return suffix }
        let remainder = String(suffix[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard containsAlphanumeric(remainder) else { return "" }
        return remainder
    }

    /// Whether text holds at least one alphanumeric character.
    /// - Parameter text: Candidate fact text.
    /// - Returns: True when an alphanumeric character is present.
    private static func containsAlphanumeric(_ text: String) -> Bool {
        text.rangeOfCharacter(from: .alphanumerics) != nil
    }

    /// Whether text is storable as an explicit fact.
    ///
    /// Shared by profile stores and chat remember paths so empty and
    /// punctuation-only validation stays in one place. Surrounding
    /// whitespace is ignored.
    /// - Parameter content: Candidate fact text.
    /// - Returns: True when trimmed text is non-empty and holds at
    ///   least one alphanumeric character.
    static func isStorableFact(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return containsAlphanumeric(trimmed)
    }

    /// Builds the acknowledgement text for an explicit remember request.
    ///
    /// Single shared text for the CLI remember path and
    /// `Orchestrator.rememberAcknowledgement` so every caller stores the
    /// same assistant turn. Usage text is returned when `fact` holds no
    /// storable content; otherwise the stored flag selects between the
    /// remembered confirmation and the failure note.
    /// - Parameters:
    ///   - fact: Stripped fact text.
    ///   - stored: Whether the fact was stored.
    /// - Returns: Acknowledgement text for the assistant turn.
    static func rememberAcknowledgementText(for fact: String, stored: Bool) -> String {
        guard isStorableFact(fact) else {
            return "Usage: /remember <fact> — what should I remember?"
        }
        return stored ? "Remembered: \(fact)" : "Could not remember that."
    }

    /// Validates fact text and returns the trimmed form.
    ///
    /// Single helper for `storeSemantic`, `storeProfileFact`, and
    /// `persistFact` so empty versus punctuation-only failures stay
    /// consistent. Facts longer than `maxContentLength` characters are
    /// rejected, matching the episodic bound.
    /// - Parameter content: Candidate fact text.
    /// - Returns: Trimmed fact text.
    /// - Throws: `MemoryEngineError/semanticFailed(_:)` when the fact is
    ///   empty, has no alphanumeric characters, or exceeds
    ///   `maxContentLength`.
    internal static func validatedFactText(_ content: String) throws -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MemoryEngineError.semanticFailed("Fact must not be empty.")
        }
        guard containsAlphanumeric(trimmed) else {
            throw MemoryEngineError.semanticFailed("Fact must contain alphanumeric characters.")
        }
        guard trimmed.count <= maxContentLength else {
            throw MemoryEngineError.semanticFailed("Fact exceeds \(maxContentLength) characters.")
        }
        return trimmed
    }

    /// Mirrors one chat turn into episodic memory without throwing.
    ///
    /// Used by the chat REPL so a failing store never interrupts the
    /// conversation. `toolCallID` is kept in episode metadata so hydration
    /// can restore tool correlation for future LLM turns.
    /// - Parameters:
    ///   - content: Turn text to persist.
    ///   - sessionID: Session identifier used as the conversation key.
    ///   - role: Who produced the turn. Defaults to `.user`.
    ///   - toolCallID: Tool correlation identifier for `.tool` turns.
    ///     Defaults to nil.
    /// - Returns: True when the turn was stored.
    @discardableResult
    func storeChatTurn(
        content: String,
        sessionID: UUID,
        role: Message.Role = .user,
        toolCallID: String? = nil
    ) async -> Bool {
        do {
            var metadata: [String: String] = [:]
            if let toolCallID, !toolCallID.isEmpty {
                metadata["tool_call_id"] = toolCallID
            }
            try await storeEpisodic(content: content, metadata: metadata, sessionID: sessionID, role: role)
            return true
        } catch {
            return false
        }
    }

    /// Shared notice when an episodic mirror write fails.
    static let mirrorFailureMessage = "Episodic memory write failed; continuing."

    /// Mirrors one turn into episodic memory with an explicit failure policy.
    ///
    /// Single `MemoryEngine`-owned helper for the orchestrator and the CLI
    /// chat loop: `.silent` ignores failures (orchestrator), `.report`
    /// invokes `onFailure` with the shared message (CLI dim warning).
    /// - Parameters:
    ///   - content: Turn text to persist.
    ///   - sessionID: Session identifier used as the conversation key.
    ///   - role: Who produced the turn. Defaults to `.user`.
    ///   - toolCallID: Tool correlation identifier for `.tool` turns.
    ///     Defaults to nil.
    ///   - failurePolicy: Whether to report failures. Defaults to `.silent`.
    ///   - onFailure: Handler receiving the shared failure message when
    ///     `failurePolicy` is `.report` and the store fails. Defaults to nil.
    /// - Returns: True when the turn was stored.
    @discardableResult
    func mirrorTurn(
        content: String,
        sessionID: UUID,
        role: Message.Role = .user,
        toolCallID: String? = nil,
        failurePolicy: MirrorFailurePolicy = .silent,
        onFailure: (@Sendable (String) -> Void)? = nil
    ) async -> Bool {
        let stored = await storeChatTurn(
            content: content,
            sessionID: sessionID,
            role: role,
            toolCallID: toolCallID
        )
        if !stored, failurePolicy == .report {
            onFailure?(Self.mirrorFailureMessage)
        }
        return stored
    }

    /// Mirrors one turn without observing cancellation.
    ///
    /// Cancelled turns keep working-memory partials for executed tools, so the
    /// episodic mirror must land even though the surrounding task is already
    /// cancelled; a cancellable store would throw before dispatch and leave
    /// the audit trail behind.
    /// - Parameters:
    ///   - content: Turn text to persist.
    ///   - sessionID: Session identifier used as the conversation key.
    ///   - role: Who produced the turn. Defaults to `.user`.
    /// - Returns: True when the turn was stored.
    @discardableResult
    func mirrorTurnUncancellable(
        content: String,
        sessionID: UUID,
        role: Message.Role = .user
    ) async -> Bool {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        guard content.count <= Self.maxContentLength else { return false }
        return await episodeStore.storeUncancellable(
            sessionID: sessionID,
            role: role,
            content: content
        )
    }

    /// Maximum characters kept from a tool outcome in a compact episodic record.
    ///
    /// Bounds the outcome portion of `episodicToolRecord(toolName:content:isError:)`
    /// so one large tool payload never materializes a huge episode row; the
    /// record truncates with an ellipsis when over budget.
    static let episodicToolOutcomeLimit = 2000

    /// Builds compact episodic content for one tool execution.
    ///
    /// Episodic memory keeps user text and final assistant text verbatim and
    /// drops interim assistant notes (narration plus `Calling ... [...]`
    /// placeholder lines) entirely, so tool-call mechanics never reach the
    /// store. Each meaningful tool execution persists as one compact record
    /// carrying only the tool name plus its outcome; raw placeholder call
    /// identifiers and call-argument JSON are never included, and no
    /// `tool_call_id` metadata is stored alongside the record.
    /// - Parameters:
    ///   - toolName: Name of the tool that ran (e.g. `"email.search"`).
    ///   - content: Raw tool outcome text.
    ///   - isError: Whether the outcome represents a failure.
    /// - Returns: Compact record such as `"Used email.search: <outcome>"`
    ///   (or `"Used email.search (failed): <outcome>"` when `isError`), or
    ///   nil when the name is blank or the outcome is blank after stripping
    ///   placeholder lines.
    static func episodicToolRecord(toolName: String, content: String, isError: Bool) -> String? {
        let trimmedName = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }
        let trimmedOutcome = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOutcome.isEmpty else { return nil }
        let cleaned = strippingToolPlumbing(from: trimmedOutcome)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        let compact = cleaned.count > episodicToolOutcomeLimit
            ? String(cleaned.prefix(episodicToolOutcomeLimit)) + "…"
            : cleaned
        if isError {
            return "Used \(trimmedName) (failed): \(compact)"
        }
        return "Used \(trimmedName): \(compact)"
    }

    /// Builds compact episodic content from a bus result.
    ///
    /// Convenience over `episodicToolRecord(toolName:content:isError:)` so
    /// orchestration loops pass the executed call name plus its
    /// ``ToolResult`` without unpacking fields at the call site.
    /// - Parameters:
    ///   - toolName: Name of the tool that ran.
    ///   - result: Result returned by the bus.
    /// - Returns: Compact record, or nil when the outcome is not meaningful.
    static func episodicToolRecord(toolName: String, result: ToolResult) -> String? {
        episodicToolRecord(toolName: toolName, content: result.content, isError: result.isError)
    }

    /// Whether a line looks like persisted tool-call plumbing.
    ///
    /// Delegates to the shared `ToolInput/parsePlaceholderLine(_:)` parser
    /// (the same parser backing Responses replay) so episodic stripping and
    /// replay never drift; ordinary prose starting with "Calling " (e.g.
    /// "Calling the bank tomorrow") never counts as plumbing.
    /// - Parameter line: Single line to inspect.
    /// - Returns: True when the line has the full placeholder shape.
    static func isToolPlumbingLine(_ line: String) -> Bool {
        ToolInput.parsePlaceholderLine(line) != nil
    }

    /// Removes tool-call plumbing lines from text.
    ///
    /// Drops every `Calling ...` placeholder line and trims the remainder,
    /// preserving all other lines verbatim. Used defensively when building
    /// compact tool records so a leaked placeholder never reaches episodic
    /// storage.
    /// - Parameter text: Candidate text possibly containing placeholders.
    /// - Returns: Text without plumbing lines, trimmed.
    static func strippingToolPlumbing(from text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        let kept = lines.filter { !isToolPlumbingLine($0) }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Stores a remembered fact without throwing.
    ///
    /// Used by the chat REPL for explicit remember requests so a failing
    /// store never interrupts the conversation. Punctuation-only facts
    /// (no alphanumeric characters) are rejected like empty facts.
    /// - Parameters:
    ///   - content: Fact text.
    ///   - source: Origin label. Defaults to `"chat"`.
    /// - Returns: True when the fact was stored.
    @discardableResult
    func storeRememberedFact(content: String, source: String = "chat") async -> Bool {
        guard Self.isStorableFact(content) else { return false }
        do {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            try await storeProfileFact(content: trimmed, source: source)
            return true
        } catch {
            return false
        }
    }

    /// Maximum memories injected as system context on one chat turn.
    ///
    /// Top-N bound for the keyword `recall` fan-out so every turn issues
    /// one bounded per-tier read; context size never grows with store size.
    static let automaticRecallLimit = 5

    /// Minimum score for an injected recall hit.
    ///
    /// Recall merges episodic rank scores (`1/(index+1)`) with normalized
    /// keyword scores (overlap scaled to `[0, 1]`, profile further scaled
    /// by confidence). Hits below this threshold are treated as noise and
    /// the turn runs with no injected context.
    static let automaticRecallThreshold = 0.1

    /// Maximum characters for the injected recall block, header included.
    ///
    /// Bounds the source-labeled system message (roughly 500 tokens at
    /// four characters per token) so long-term context never crowds out
    /// the live conversation; over-budget blocks truncate with an ellipsis.
    static let automaticRecallMaxChars = 2000

    /// Header labeling injected recall as system context.
    static let automaticRecallHeader =
        "Relevant memories (use for context; do not mention unless relevant):"

    /// Builds source-labeled recall context, token-bounded with truncation.
    ///
    /// Keeps hits scoring at or above `threshold`, renders each as
    /// `[source] content` on its own line under the shared header, and
    /// truncates the whole block to `maxChars` with an ellipsis when over
    /// budget. Returns nil when no hit clears the threshold so callers
    /// skip injection entirely.
    /// - Parameters:
    ///   - results: Ranked recall hits, best first.
    ///   - threshold: Minimum score to keep. Defaults to
    ///     `automaticRecallThreshold`.
    ///   - maxChars: Maximum characters including the header. Defaults to
    ///     `automaticRecallMaxChars`. Non-positive limits return nil.
    /// - Returns: System context text, or nil when nothing is relevant.
    static func automaticRecallContext(
        for results: [MemoryResult],
        threshold: Double = automaticRecallThreshold,
        maxChars: Int = automaticRecallMaxChars
    ) -> String? {
        guard maxChars > 0 else { return nil }
        let relevant = results.filter { $0.score >= threshold }
        guard !relevant.isEmpty else { return nil }
        let lines = relevant.map { result -> String in
            let singleLine = result.content
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\t", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let compact = singleLine.count > 500 ? String(singleLine.prefix(500)) + "…" : singleLine
            return "[\(result.source.rawValue)] \(compact)"
        }
        let block = ([automaticRecallHeader] + lines).joined(separator: "\n")
        guard block.count > maxChars else { return block }
        if maxChars == 1 {
            return "…"
        }
        return String(block.prefix(maxChars - 1)) + "…"
    }

    /// Wraps recall hits as an injectable system message.
    ///
    /// Thin wrapper over `automaticRecallContext(for:threshold:maxChars:)`
    /// so chat loops inject one `system` message without duplicating the
    /// threshold and truncation policy.
    /// - Parameters:
    ///   - results: Ranked recall hits, best first.
    ///   - threshold: Minimum score to keep. Defaults to
    ///     `automaticRecallThreshold`.
    ///   - maxChars: Maximum characters including the header. Defaults to
    ///     `automaticRecallMaxChars`.
    /// - Returns: System message to inject, or nil when nothing is relevant.
    static func automaticRecallMessage(
        for results: [MemoryResult],
        threshold: Double = automaticRecallThreshold,
        maxChars: Int = automaticRecallMaxChars
    ) -> Message? {
        guard let text = automaticRecallContext(for: results, threshold: threshold, maxChars: maxChars) else {
            return nil
        }
        return Message(role: .system, content: text)
    }
}

// MARK: - MemoryEngine Automatic Recall

public extension MemoryEngine {
    /// Drops the just-mirrored self-echo from recall hits.
    ///
    /// Single shared filter for the orchestrator and the CLI chat loop so
    /// both entry points agree on what counts as an echo: an episodic hit
    /// from this session whose content matches the query
    /// case-insensitively after trimming. Semantic and profile hits, and
    /// episodic hits from other sessions, always survive.
    /// - Parameters:
    ///   - results: Ranked recall hits, best first.
    ///   - query: Current user message used as the recall query.
    ///   - sessionID: Current session identifier for echo filtering.
    /// - Returns: Hits with the self-echo removed.
    static func filteredRecallResults(
        _ results: [MemoryResult],
        query: String,
        sessionID: UUID
    ) -> [MemoryResult] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return results.filter { result in
            guard result.source == .episodic else { return true }
            guard result.metadata["session_id"] == sessionID.uuidString else { return true }
            return result.content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != trimmedQuery
        }
    }

    /// Inserts injected recall into LLM history after leading system messages.
    ///
    /// Single shared splice for the orchestrator and the CLI chat loop:
    /// the recall `system` message goes right after any leading `system`
    /// rows (developer prompt, rolling summary), ahead of the live
    /// conversation. Ephemeral only; the recall message is never appended
    /// to working memory.
    /// - Parameters:
    ///   - history: Base LLM history including prompt and summary.
    ///   - recall: Recall system message, if any.
    /// - Returns: History with recall spliced in, or unchanged when nil.
    static func historyWithRecall(_ history: [Message], recall: Message?) -> [Message] {
        guard let recall else { return history }
        var spliced = history
        var index = 0
        while index < spliced.count, spliced[index].role == .system {
            index += 1
        }
        spliced.insert(recall, at: index)
        return spliced
    }

    /// Resolves automatic recall for one user turn, failure-isolated.
    ///
    /// Single `MemoryEngine`-owned helper for the orchestrator and the CLI
    /// chat loop: runs one bounded keyword `recall` (nil embeddings),
    /// drops the just-mirrored self-echo via `filteredRecallResults`, and
    /// wraps the survivors via `automaticRecallMessage`. Recall failures,
    /// empty queries, and below-threshold hits yield nil so the turn
    /// proceeds with no injected context.
    /// - Parameters:
    ///   - query: Current user message used as the recall query.
    ///   - sessionID: Current session identifier for self-echo filtering.
    /// - Returns: System message to inject, or nil when nothing is relevant.
    func recallMessage(for query: String, sessionID: UUID) async -> Message? {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do {
            let results = try await recall(
                query: query,
                embedding: nil,
                limit: Self.automaticRecallLimit
            )
            let filtered = Self.filteredRecallResults(results, query: query, sessionID: sessionID)
            return Self.automaticRecallMessage(for: filtered)
        } catch {
            return nil
        }
    }
}

// MARK: - Episode Message Conversion

public extension Episode {
    /// Converts an episodic turn back to working-memory history.
    ///
    /// Preserves the episode identifier, tool correlation identifier, and
    /// timestamp so hydrated history keeps LLM tool wiring intact. Tool
    /// correlation is read from `metadata["tool_call_id"]` written by the
    /// chat turn mirror helper.
    /// - Returns: Equivalent chat message.
    func asMessage() -> Message {
        Message(
            id: id,
            role: role,
            content: content,
            toolCallID: metadata["tool_call_id"],
            createdAt: timestamp
        )
    }

    /// Converts an episode for session-resume hydration, if replayable.
    ///
    /// Legacy correlated tool rows (role `.tool` with a non-blank
    /// `tool_call_id` in metadata) keep their wiring via `asMessage()` so
    /// future LLM turns retain tool correlation. Compact episodic tool
    /// records (`"Used <tool>: <outcome>"`, role `.tool`, no `tool_call_id`
    /// by policy) have no parent `function_call` in the episodic store —
    /// interim assistant placeholder notes are never mirrored — so sending
    /// them as `.tool` messages would orphan them with nil/empty `call_id`.
    /// They hydrate as replay-safe `.assistant` synthesis carrying the same
    /// outcome text, so compact outcomes survive resume instead of
    /// vanishing while the next turn stays replayable.
    /// - Returns: Equivalent chat message, or nil for blank tool records.
    func hydrationMessage() -> Message? {
        guard role == .tool else { return asMessage() }
        if let callID = metadata["tool_call_id"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !callID.isEmpty
        {
            return asMessage()
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Message(id: id, role: .assistant, content: trimmed, createdAt: timestamp)
    }
}

public extension MemoryEngine {
    /// Converts episodes to replay-safe working history for resume.
    ///
    /// Legacy correlated `.tool` rows (with `tool_call_id`) replay with
    /// their wiring intact; compact `"Used <tool>: <outcome>"` records
    /// without a call identifier hydrate as `.assistant` synthesis (see
    /// `Episode.hydrationMessage()`) so outcomes survive resume without
    /// ever sending orphaned tool messages with nil/empty `call_id` and
    /// no parent `function_call`.
    /// - Parameter episodes: Episodes in chronological order.
    /// - Returns: Messages safe to load into working history.
    static func hydrationMessages(from episodes: [Episode]) -> [Message] {
        episodes.compactMap { $0.hydrationMessage() }
    }
}

// MARK: - MemoryEngine Profile Persistence

extension MemoryEngine {
    /// Serial queue for profile file writes.
    ///
    /// The actor captures each profile snapshot in call order and
    /// enqueues the write here, so disk order always matches actor
    /// order even when mutations arrive back-to-back.
    private static let profileWriteQueue = DispatchQueue(label: "com.runeweaver.memoryengine.profile", qos: .utility)

    /// Inserts or replaces a profile fact by `id`, then persists.
    /// - Parameter fact: Fact to record.
    private func upsertProfileFact(_ fact: UserFact) {
        profile.facts.removeAll { $0.id == fact.id }
        profile.facts.append(fact)
        touchProfile()
    }

    /// Whether a preference key holds a single value.
    ///
    /// Single-value keys replace on write; all other keys accumulate
    /// exact-duplicate-deduped rows. Currently only `name` is
    /// single-value (case-insensitive); `likes`, `favorite-*`, and any
    /// future keys are multi-value.
    /// - Parameter key: Preference key.
    /// - Returns: True when the key replaces on write.
    private static func isSingleValuePreferenceKey(_ key: String) -> Bool {
        key.lowercased() == "name"
    }

    /// Stamps `lastUpdated` and mirrors the profile to disk best-effort.
    private func touchProfile() {
        profile.lastUpdated = Date()
        persistProfileBestEffort()
    }

    /// Writes the profile JSON without throwing (used after mutation).
    ///
    /// The snapshot is captured on the actor in call order and the file
    /// write is enqueued on the serial profile queue, so disk order
    /// matches actor order and rapid mutations cannot reorder.
    /// Failures are ignored best-effort.
    private func persistProfileBestEffort() {
        guard let profilePath else { return }
        guard let data = try? JSONEncoder().encode(profileSnapshot()) else { return }
        let expanded = (profilePath as NSString).expandingTildeInPath
        Self.profileWriteQueue.async {
            let directory = (expanded as NSString).deletingLastPathComponent
            if !directory.isEmpty {
                try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            }
            try? data.write(to: URL(fileURLWithPath: expanded), options: .atomic)
        }
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
}

// MARK: - MemoryEngine Heuristics

extension MemoryEngine {
    /// Splits text into trimmed sentence candidates.
    ///
    /// Splits on `.`, `!`, `?`, and newlines, preserving a trailing
    /// `?` on the sentence so interrogatives stay detectable by
    /// `isFactLike`. Other terminators are stripped like before.
    /// - Parameter text: Free text.
    /// - Returns: Sentences longer than a couple of characters.
    private static func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        for character in text {
            if character == "." || character == "!" || character == "?" || character == "\n" {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    if character == "?" {
                        sentences.append(trimmed + "?")
                    } else {
                        sentences.append(trimmed)
                    }
                }
                current = ""
            } else {
                current.append(character)
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            sentences.append(tail)
        }
        return sentences.filter { $0.count > 2 }
    }

    /// Whether a sentence looks worth remembering.
    ///
    /// Keeps first-person statements, possessives, and explicit
    /// "remember" requests; drops bare questions and very short text.
    /// `splitSentences` preserves trailing `?` so this check observes
    /// the original interrogative form. Markers match on token and word
    /// boundaries (via `Tokenization.tokenize` and `\b` regex) so
    /// substrings like `"my "` inside `"enemy"` never match.
    /// - Parameter sentence: Candidate sentence.
    /// - Returns: True when the sentence should become a fact.
    private static func isFactLike(_ sentence: String) -> Bool {
        let lower = sentence.lowercased()
        if lower.hasSuffix("?") {
            return false
        }
        let tokens = Tokenization.tokenize(sentence)
        if tokens.contains("my") || tokens.contains("remember") {
            return true
        }
        let phrases = ["i am", "i'm", "i like", "i love", "i prefer", "i work", "i live"]
        for phrase in phrases {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: phrase))\\b"
            if lower.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }
        return sentence.count > 40
    }

    /// Pulls a `Preference` out of common phrasings.
    ///
    /// Matches `call me X`, `my favorite X is Y`, and
    /// `I love/like/prefer X` case-insensitively against the original
    /// sentence so suffix slices never misalign. `call me` and
    /// `my favorite` match on word boundaries (`\b` regex) so
    /// substrings like `"recall me"` or `"enemy favorite"` never match.
    /// Favorite keys strip leading `my`/`favorite` before prefixing so
    /// `my favorite drink` becomes `favorite-drink` without stutter, and
    /// an already prefixed key is never double-prefixed.
    /// - Parameter sentence: Candidate sentence.
    /// - Returns: A preference, or nil when no pattern matches.
    private static func extractPreference(from sentence: String) -> Preference? {
        let trimmedSentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmedSentence.range(of: #"\bcall me\b"#, options: [.regularExpression, .caseInsensitive]) {
            let name = String(trimmedSentence[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count < 60 else { return nil }
            return Preference(key: "name", value: name, confidence: 0.95)
        }
        if trimmedSentence.range(of: #"\bmy favorite\b"#, options: [.regularExpression, .caseInsensitive]) != nil,
           trimmedSentence.range(of: " is ", options: .caseInsensitive) != nil
        {
            let parts = trimmedSentence.components(separatedBy: ":")
            let clause = parts.last ?? trimmedSentence
            guard let isRange = clause.range(of: " is ", options: .caseInsensitive) else { return nil }
            let keyPart = String(clause[..<isRange.lowerBound])
            let valueRaw = String(clause[isRange.upperBound...])
            var keyWords = keyPart.lowercased().split(separator: " ").map(String.init)
            while let first = keyWords.first, first == "my" || first == "favorite" {
                keyWords.removeFirst()
            }
            let meaningful = keyWords.suffix(2).joined(separator: "-")
            let key: String = if meaningful.isEmpty {
                "favorite"
            } else if meaningful == "favorite" || meaningful.hasPrefix("favorite-") {
                meaningful
            } else {
                "favorite-\(meaningful)"
            }
            let value = valueRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,"))
            guard !value.isEmpty, value.count < 120 else { return nil }
            return Preference(key: key, value: value, confidence: 0.9)
        }
        for marker in ["i love ", "i like ", "i prefer "] {
            if let range = trimmedSentence.range(of: marker, options: .caseInsensitive) {
                let value = String(trimmedSentence[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,"))
                guard !value.isEmpty, value.count < 120 else { return nil }
                return Preference(key: "likes", value: value, confidence: 0.85)
            }
        }
        return nil
    }
}

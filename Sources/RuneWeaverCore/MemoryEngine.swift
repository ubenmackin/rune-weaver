// Rune Weaver Core — Three-tier memory orchestration across working and durable stores.

import Foundation

/// Where a memory result came from.
public enum MemorySource: String, Sendable, Codable, Equatable, CaseIterable {
    /// Past conversation turns (episodic store).
    case episodic
    /// Facts with embeddings (vector store).
    case semantic
    /// Indexed document and mail chunks (document index).
    case docIndex
    /// Long-lived user profile facts and preferences.
    case profile
}

/// One retrieved memory with its relevance score.
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
    public init(content: String, score: Double, source: MemorySource, metadata: [String: String] = [:]) {
        self.content = content
        self.score = score
        self.source = source
        self.metadata = metadata
    }
}

/// Observability for one recall pass, safe to log (IDs and scores only, never content).
extension MemoryEngine {
    /// Recall diagnostics carried alongside hits for per-turn observability.
    public struct RecallDiagnostics: Sendable, Equatable {
        /// Stable identifiers for retrieved hits, in rank order.
        public let hitIDs: [String]
        /// Source raw values for retrieved hits, in rank order.
        public let sources: [String]
        /// Calibrated scores for retrieved hits, in rank order.
        public let scores: [Double]
        /// Characters that would be (or were) injected into model context.
        public let injectedChars: Int
        /// True when the document index was skipped for this pass.
        public let skippedDocIndex: Bool

        /// Creates recall diagnostics.
        public init(hitIDs: [String], sources: [String], scores: [Double], injectedChars: Int, skippedDocIndex: Bool) {
            self.hitIDs = hitIDs
            self.sources = sources
            self.scores = scores
            self.injectedChars = injectedChars
            self.skippedDocIndex = skippedDocIndex
        }

        /// Zero-hit diagnostics for silent-nil recalls, preserving the skip flag.
        public static func zero(skippedDocIndex: Bool = false) -> Self {
            Self(hitIDs: [], sources: [], scores: [], injectedChars: 0, skippedDocIndex: skippedDocIndex)
        }

        /// Safe single-line summary with counts plus scores plus skip flag, never content.
        public var logLine: String {
            "hits=\(hitIDs.count) injectedChars=\(injectedChars) skippedDocIndex=\(skippedDocIndex) ids=\(hitIDs) sources=\(sources) scores=\(scores)"
        }
    }
}

/// Top-level alias so call sites can spell the diagnostics without the owner prefix.
public typealias RecallDiagnostics = MemoryEngine.RecallDiagnostics

extension MemoryEngine {
    /// Stable identifier for one recall hit, never content.
    public static func recallHitID(for result: MemoryResult, at index: Int) -> String {
        if let id = result.metadata["id"]?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            return id
        }
        if let documentID = result.metadata["document_id"]?.trimmingCharacters(in: .whitespacesAndNewlines), !documentID.isEmpty {
            return documentID
        }
        if let key = result.metadata["key"]?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            return "preference:\(singleLineSquashed(key))"
        }
        return "\(result.source.rawValue):\(index)"
    }

    /// Builds diagnostics for retrieved hits with the given injection-char estimate.
    public static func recallDiagnostics(for hits: [MemoryResult], injectedChars: Int, skippedDocIndex: Bool) -> RecallDiagnostics {
        RecallDiagnostics(
            hitIDs: hits.enumerated().map { recallHitID(for: $1, at: $0) },
            sources: hits.map(\.source.rawValue),
            scores: hits.map(\.score),
            injectedChars: injectedChars,
            skippedDocIndex: skippedDocIndex
        )
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
public enum MirrorFailurePolicy: Sendable, Equatable {
    /// Ignore mirror failures.
    case silent
    /// Invoke the failure handler with the shared message.
    case report
}

/// Three-tier memory: episodic (SQLite + FTS5), semantic (vector),
/// and profile (structured user facts and preferences).
public actor MemoryEngine {
    /// Episodic conversation-history store.
    private let episodeStore: EpisodeStore

    /// Semantic fact/vector store.
    private let vectorStore: VectorStore
    /// Durable document index for hybrid keyword/vector recall, when configured.
    let docIndexStore: DocIndexStore?
    /// In-memory profile snapshot, mirrored to disk best-effort.
    var profile: UserProfile
    /// JSON file backing the profile, if configured.
    private let profilePath: String?
    /// Semantic answer cache for repeated pure Q&A turns.
    public let answerCache: SemanticAnswerCache
    /// Maximum results fetched per tier before merging.
    static let maxPerTierResults = 1000
    /// Maximum characters accepted for a single stored content.
    public static let maxContentLength = 10000
    /// Maximum episodic records retained before auto-compacting old sessions.
    public static let maxEpisodicCount = 10000

    /// Creates an engine from live stores.
    public init(
        episodeStore: EpisodeStore,
        vectorStore: VectorStore,
        docIndexStore: DocIndexStore? = nil,
        profilePath: String? = nil,
        initialProfile: UserProfile? = nil,
        answerCache: SemanticAnswerCache? = nil
    ) {
        self.episodeStore = episodeStore
        self.vectorStore = vectorStore
        self.docIndexStore = docIndexStore
        self.profilePath = profilePath
        // The cache always exists and always starts empty, so the answer-cache
        // path has no disabled state to resurrect after boot; a caller holding
        // a cache wired to its embeddings producer injects it here.
        self.answerCache = answerCache ?? SemanticAnswerCache()
        if let initialProfile {
            self.profile = initialProfile
        } else if let profilePath, let loaded = Self.loadProfileBestEffort(path: profilePath) {
            self.profile = loaded
        } else {
            self.profile = UserProfile.empty
        }
    }

    /// Creates an engine from filesystem paths. episodesDBPath: SQLite path for
    /// episodic memory.
    public init(
        episodesDBPath: String,
        vectorDBPath: String,
        docIndexDBPath: String? = nil,
        profilePath: String? = nil
    ) {
        self.init(
            episodeStore: EpisodeStore(dbPath: episodesDBPath),
            vectorStore: VectorStore(directoryPath: vectorDBPath),
            docIndexStore: docIndexDBPath.map { DocIndexStore(dbPath: $0) },
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
            do {
                let total = try await episodeStore.count()
                if total > Self.maxEpisodicCount {
                    _ = try await episodeStore.compactSessions(olderThan: Date().addingTimeInterval(-30 * 86400))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                RuneWeaverLog.memory.warning("MemoryEngine: episodic compaction check failed: \(error.localizedDescription)")
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
    @discardableResult
    public func compactEpisodic(olderThan: Date) async throws -> [EpisodeSummary] {
        try await episodeStore.compactSessions(olderThan: olderThan)
    }

    /// Searches episodic memory by keyword, optionally restricted to a dated window.
    public func searchEpisodes(query: String, limit: Int = 10, since: Date? = nil, until: Date? = nil) async throws -> [MemoryResult] {
        guard limit > 0 else { return [] }
        let clamped = min(limit, Self.maxPerTierResults)
        let episodes = try await withEpisodic {
            try await episodeStore.search(query: query, limit: clamped, since: since, until: until)
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
    private func withEpisodic<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch {
            throw MemoryEngineError.episodicFailed(error.localizedDescription)
        }
    }

    /// Returns stored episodes for one session, oldest first.
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
    public func recentEpisodes(for sessionID: UUID, limit: Int) async throws -> [Episode] {
        guard limit > 0 else { return [] }
        let clamped = min(limit, Self.maxPerTierResults)
        return try await withEpisodic {
            try await episodeStore.recentEpisodes(for: sessionID, limit: clamped)
        }
    }

    /// Lists recent episodic turns across all sessions or one session, newest first.
    public func listRecentEpisodes(limit: Int = 20, sessionID: UUID? = nil) async throws -> [Episode] {
        guard limit > 0 else { return [] }
        let clamped = min(limit, Self.maxPerTierResults)
        let fetched: [Episode] = if let sessionID {
            try await withEpisodic {
                try await episodeStore.recentEpisodes(for: sessionID, limit: clamped)
            }
        } else {
            try await withEpisodic {
                try await episodeStore.recent(limit: clamped)
            }
        }
        // The session-scoped store read returns oldest first while the global
        // read returns newest first, so normalize here to one newest-first
        // contract with a stable tie-break. Callers never sort this listing.
        return fetched.sorted {
            if $0.timestamp != $1.timestamp {
                return $0.timestamp > $1.timestamp
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    /// Deletes every episodic turn for a session. Unknown sessions are a no-op.
    public func deleteSession(_ sessionID: UUID) async throws {
        try await withEpisodic {
            try await episodeStore.deleteSession(sessionID)
        }
    }

    /// Clears every episodic turn across all sessions, returning the removed count.
    public func clearEpisodic() async throws -> Int {
        try await withEpisodic {
            try await episodeStore.clearReturningCount()
        }
    }

    /// Clears every episodic turn, returning both the removed and remaining counts.
    public func clearEpisodicWithRemaining() async throws -> (deleted: Int, remaining: Int) {
        try await withEpisodic {
            let deleted = try await episodeStore.clearReturningCount()
            return (deleted: deleted, remaining: 0)
        }
    }

    /// Deletes one episodic turn by identifier. Missing rows are a no-op.
    public func deleteEpisode(id: UUID) async throws {
        try await withEpisodic {
            try await episodeStore.delete(id: id)
        }
    }

    // MARK: - Semantic

    /// Stores a fact in semantic memory and in the user profile.
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

    public func episodeCount() async -> Int {
        do {
            return try await episodeStore.count()
        } catch is CancellationError {
            return 0
        } catch {
            RuneWeaverLog.memory.warning("MemoryEngine: failed to query episode count: \(error.localizedDescription)")
            return 0
        }
    }

    /// Stores an explicit user-supplied fact in structured memory.
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
            // A durable fact write can change future answers, so pure answers
            // cached before it must not replay alongside it.
            await answerCache.invalidateOnMemoryWrite()
            return fact
        } catch let error as VectorStoreError {
            throw MemoryEngineError.semanticFailed(String(describing: error))
        } catch {
            throw MemoryEngineError.semanticFailed(error.localizedDescription)
        }
    }

    /// Records a preference, then persists the profile. Async because the durable write clears the
    /// semantic answer cache: a new preference rewrites future answers, so cached pure answers must
    /// not survive it.
    public func setPreference(_ preference: Preference) async {
        if Self.isSingleValuePreferenceKey(preference.key) {
            profile.preferences.removeAll { $0.key == preference.key }
        } else {
            profile.preferences.removeAll { $0.key == preference.key && $0.value == preference.value }
        }
        profile.preferences.append(preference)
        touchProfile()
        await answerCache.invalidateOnMemoryWrite()
    }

    /// Removes a preference by key and value.
    /// Async so the durable write clears the semantic answer cache like every
    /// other profile mutation.
    public func removePreference(key: String, value: String) async {
        profile.preferences.removeAll { $0.key == key && $0.value == value }
        touchProfile()
        await answerCache.invalidateOnMemoryWrite()
    }

    /// Confirms a profile fact, refreshing its confidence and timestamp.
    /// Async so the durable write clears the semantic answer cache like every
    /// other profile mutation.
    public func confirmFact(id: UUID, confidence: Double = 1.0) async {
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
        await answerCache.invalidateOnMemoryWrite()
    }

    /// Removes a profile fact without touching the vector store.
    /// Async so the durable write clears the semantic answer cache like every
    /// other profile mutation.
    public func removeProfileFact(id: UUID) async {
        profile.facts.removeAll { $0.id == id }
        touchProfile()
        await answerCache.invalidateOnMemoryWrite()
    }

    /// Removes a profile fact and its semantic row best-effort.
    public func removeFact(id: UUID) async {
        do {
            try await vectorStore.remove(id: id)
        } catch is CancellationError {
            return
        } catch {
            RuneWeaverLog.memory.warning("MemoryEngine: failed to remove vector fact \(id): \(error.localizedDescription)")
        }
        profile.facts.removeAll { $0.id == id }
        touchProfile()
        await answerCache.invalidateOnMemoryWrite()
    }

    /// Removes a profile fact and its semantic row, reporting failures.
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
        await answerCache.invalidateOnMemoryWrite()
    }
}

// MARK: - MemoryEngine Fact Extraction

extension MemoryEngine {
    /// Extracts durable facts and preferences from free text.
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
    @discardableResult
    public func extractAndStoreFactsThrowing(
        from text: String,
        embeddings: [String: [Float]] = [:]
    ) async throws -> [UserFact] {
        try await collectFactsThrowing(from: text, embeddings: embeddings)
    }

    /// Collects facts from free text, throwing on the first persist failure.
    private func collectFactsThrowing(
        from text: String,
        embeddings: [String: [Float]]
    ) async throws -> [UserFact] {
        let sentences = Self.splitSentences(text)
        var created: [UserFact] = []
        for sentence in sentences {
            if let preference = Self.extractPreference(from: sentence) {
                await setPreference(preference)
            }
            guard Self.isFactLike(sentence), Self.isStorableFact(sentence) else { continue }
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
}

// MARK: - MemoryEngine Semantic Store Maintenance

extension MemoryEngine {
    /// Total stored semantic fact count without exposing the store.
    func semanticStoreCount() async -> Int {
        await vectorStore.count()
    }

    /// All stored semantic facts without exposing the store.
    /// - Returns: Stored facts in store order.
    func semanticStoreAllFacts() async -> [StoredFact] {
        await vectorStore.allFacts()
    }

    /// Active embedding width of the semantic store, if known.
    /// - Returns: Store dimension, or nil when unknown or empty.
    func semanticStoreDimension() async -> Int? {
        await vectorStore.dimension
    }

    /// Clears every semantic row, resetting derived width but keeping configured width.
    func semanticStoreClear() async throws {
        try await vectorStore.clear()
        await vectorStore.reload()
    }

    /// Compacts the semantic store and revalidates its dimension.
    /// - Returns: Fact count after compaction.
    func semanticStoreReindex() async throws -> Int {
        try await vectorStore.reindex()
    }

    /// Inserts or replaces one semantic fact by `id`.
    /// - Parameter fact: Fact to persist.
    func semanticStoreUpsert(_ fact: StoredFact) async throws {
        try await vectorStore.upsert(fact)
    }
}

// MARK: - MemoryEngine Chat Helpers

extension MemoryEngine {
    /// Extracts an explicit remember request from chat input.
    public static func rememberFactText(from input: String) -> String? {
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
    public static func isStorableFact(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // Reserved run-bookkeeping shapes stay framework-owned: accepting one
        // would let an agent-authored write forge a scheduler run cursor.
        guard !SchedulerRunBookkeeping.isReservedFactText(trimmed) else { return false }
        return containsAlphanumeric(trimmed)
    }

    /// Builds the acknowledgement text for an explicit remember request.
    public static func rememberAcknowledgementText(for fact: String, stored: Bool) -> String {
        guard isStorableFact(fact) else {
            return "Usage: /remember <fact> — what should I remember?"
        }
        return stored ? "Remembered: \(fact)" : "Could not remember that."
    }

    /// Validates fact text and returns the trimmed form.
    static func validatedFactText(_ content: String) throws -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MemoryEngineError.semanticFailed("Fact must not be empty.")
        }
        // The storage boundary refuses reserved run-bookkeeping shapes too, so
        // no engine write path — tool, REST, extraction, or import — can forge
        // a scheduler run cursor.
        guard !SchedulerRunBookkeeping.isReservedFactText(trimmed) else {
            throw MemoryEngineError.semanticFailed("Fact must not restate framework run bookkeeping.")
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
    @discardableResult
    public func storeChatTurn(
        content: String,
        sessionID: UUID,
        role: Message.Role = .user,
        toolCallID: String? = nil,
        metadata: [String: String]? = nil
    ) async -> Bool {
        do {
            var episodeMetadata = metadata ?? [:]
            if let toolCallID, !toolCallID.isEmpty {
                episodeMetadata["tool_call_id"] = toolCallID
            }
            try await storeEpisodic(content: content, metadata: episodeMetadata, sessionID: sessionID, role: role)
            return true
        } catch {
            return false
        }
    }

    /// Shared notice when an episodic mirror write fails.
    public static let mirrorFailureMessage = "Episodic memory write failed; continuing."

    /// Mirrors one turn into episodic memory with an explicit failure policy.
    @discardableResult
    public func mirrorTurn(
        content: String,
        sessionID: UUID,
        role: Message.Role = .user,
        toolCallID: String? = nil,
        metadata: [String: String]? = nil,
        failurePolicy: MirrorFailurePolicy = .silent,
        onFailure: (@Sendable (String) -> Void)? = nil
    ) async -> Bool {
        let stored = await storeChatTurn(
            content: content,
            sessionID: sessionID,
            role: role,
            toolCallID: toolCallID,
            metadata: metadata
        )
        if !stored, failurePolicy == .report {
            onFailure?(Self.mirrorFailureMessage)
        }
        return stored
    }

    /// Mirrors one turn without observing cancellation.
    @discardableResult
    public func mirrorTurnUncancellable(
        content: String,
        sessionID: UUID,
        role: Message.Role = .user,
        metadata: [String: String] = [:]
    ) async -> Bool {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, content.count <= Self.maxContentLength else { return false }
        return await episodeStore.storeUncancellable(
            sessionID: sessionID,
            role: role,
            content: content,
            metadata: metadata
        )
    }

    /// Maximum characters kept from a tool outcome in a compact episodic record.
    public static let episodicToolOutcomeLimit = 2000

    /// Builds compact episodic content for one tool execution.
    public static func episodicToolRecord(
        toolName: String,
        content: String,
        isError: Bool,
        trustLevel: ContentTrustLevel = .untrustedExternal,
        labelingEnabled: Bool = true
    ) -> String? {
        let trimmedName = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }
        let trimmedOutcome = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOutcome.isEmpty else { return nil }
        // Screenshots stay hash-only on disk: strip data URLs before the
        // outcome is compacted so no base64 prefix persists in episodes.
        let redacted = VisionGate.strippedContent(trimmedOutcome)
        let cleaned = strippingToolPlumbing(from: redacted)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        let compact = cleaned.count > episodicToolOutcomeLimit
            ? String(cleaned.prefix(episodicToolOutcomeLimit)) + "…"
            : cleaned
        let visibleOutcome = OrchestratorToolLoop.labeledResultContent(
            compact,
            trustLevel: trustLevel,
            toolName: trimmedName,
            labelingEnabled: labelingEnabled
        )
        if isError {
            return "Used \(trimmedName) (failed): \(visibleOutcome)"
        }
        return "Used \(trimmedName): \(visibleOutcome)"
    }

    /// Builds compact episodic content from a bus result. Fail-closed legacy path: provenance is
    /// unknown here, so the record labels as untrusted rather than trusting by default.
    public static func episodicToolRecord(toolName: String, result: ToolResult) -> String? {
        episodicToolRecord(
            toolName: toolName,
            content: result.content,
            isError: result.isError,
            trustLevel: .untrustedExternal
        )
    }

    /// Builds compact episodic content from a bus result with declared provenance.
    public static func episodicToolRecord(
        toolName: String,
        result: ToolResult,
        trustLevel: ContentTrustLevel,
        labelingEnabled: Bool = true
    ) -> String? {
        episodicToolRecord(
            toolName: toolName,
            content: result.content,
            isError: result.isError,
            trustLevel: trustLevel,
            labelingEnabled: labelingEnabled
        )
    }

    /// Removes tool-call plumbing lines from text.
    /// Delegates to the shared tool-loop scrubber so history cleaning keeps one
    /// placeholder grammar instead of a drifting per-store copy.
    public static func strippingToolPlumbing(from text: String) -> String {
        OrchestratorToolLoop.scrubPlaceholderPlumbing(from: text)
    }

    /// Stores one fact preferring vectors, falling back to keyword-only.
    public func storeFactWithEmbedder(
        content: String,
        source: String,
        embedder: any EmbeddingsBackend?
    ) async throws -> UserFact {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if let embedder {
            let steeredFact = EmbeddingGemmaPrompts.document(title: "fact", text: trimmed)
            do {
                if let vector = try await embedder.embed([steeredFact]).first, !vector.isEmpty {
                    return try await storeSemantic(
                        fact: trimmed,
                        embedding: vector,
                        metadata: ["source": source],
                        source: source
                    )
                }
            } catch let error as CancellationError {
                throw error
            } catch {
                RuneWeaverLog.memory.info("MemoryEngine: Semantic store failed, falling back to keyword storage: \(error)")
                // Fall through to keyword-only storage below.
            }
        }
        return try await storeProfileFact(content: trimmed, source: source)
    }

    /// Stores a remembered fact, preferring vectors when a producer is set.
    @discardableResult
    public func storeRememberedFact(
        content: String,
        source: String = "chat",
        embedder: any EmbeddingsBackend? = nil
    ) async throws -> Bool {
        guard Self.isStorableFact(content) else { return false }
        do {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if let embedder {
                _ = try await storeFactWithEmbedder(content: trimmed, source: source, embedder: embedder)
            } else {
                try await storeProfileFact(content: trimmed, source: source)
            }
            return true
        } catch let error as CancellationError {
            throw error
        } catch {
            return false
        }
    }
}

// MARK: - Automatic recall formatting, execution, and hydration live in MemoryEngine+AutoRecall.swift

// MARK: - MemoryEngine Profile Persistence

extension MemoryEngine {
    /// Serial queue for profile file writes.
    private static let profileWriteQueue = DispatchQueue(label: "com.runeweaver.memoryengine.profile", qos: .utility)

    /// Inserts or replaces a profile fact by `id`, then persists.
    /// - Parameter fact: Fact to record.
    private func upsertProfileFact(_ fact: UserFact) {
        profile.facts.removeAll { $0.id == fact.id }
        profile.facts.append(fact)
        touchProfile()
    }

    /// Whether a preference key holds a single value.
    private static func isSingleValuePreferenceKey(_ key: String) -> Bool {
        key.lowercased() == "name"
    }

    /// Stamps `lastUpdated` and mirrors the profile to disk best-effort.
    private func touchProfile() {
        profile.lastUpdated = Date()
        persistProfileBestEffort()
    }

    /// Writes the profile JSON without throwing (used after mutation).
    private func persistProfileBestEffort() {
        guard let profilePath else { return }
        let data: Data
        do {
            data = try JSONEncoder().encode(profileSnapshot())
        } catch {
            RuneWeaverLog.memory.error("MemoryEngine: Failed to encode user profile snapshot: \(error.localizedDescription)")
            return
        }
        let expanded = (profilePath as NSString).expandingTildeInPath
        Self.profileWriteQueue.async {
            let directory = (expanded as NSString).deletingLastPathComponent
            if !directory.isEmpty {
                do {
                    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                } catch {
                    RuneWeaverLog.memory.warning("MemoryEngine: Failed to create profile directory '\(directory)': \(error.localizedDescription)")
                }
            }
            do {
                try data.write(to: URL(fileURLWithPath: expanded), options: .atomic)
            } catch {
                RuneWeaverLog.memory.warning("MemoryEngine: Failed to persist user profile to '\(expanded)': \(error.localizedDescription)")
            }
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
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: expanded))
        } catch {
            RuneWeaverLog.memory.warning("MemoryEngine: Failed to read user profile from '\(expanded)': \(error.localizedDescription)")
            return nil
        }
        do {
            return try JSONDecoder().decode(UserProfile.self, from: data)
        } catch {
            RuneWeaverLog.memory.warning("MemoryEngine: Failed to decode user profile from '\(expanded)': \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - MemoryEngine Heuristics

extension MemoryEngine {
    /// Splits text into trimmed sentence candidates.
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

// MARK: - MemoryEngine Semantic Answer Cache Delegation

extension MemoryEngine {
    /// Cached answer for one repeated pure question, or nil on a miss. An empty or blank query
    /// yields nil without a failure, matching the recall contract that a cache problem can never
    /// fail a turn.
    public func cachedAnswer(for normalizedQuery: String, persona: String, modelID: String) async -> CachedAnswer? {
        await answerCache.lookup(normalizedQuery: normalizedQuery, persona: persona, modelID: modelID)
    }

    /// Files one pure Q&A answer so the next identical question hits the cache.
    public func cacheAnswer(_ text: String, for normalizedQuery: String, persona: String, modelID: String) async {
        await answerCache.storeAnswer(
            normalizedQuery: normalizedQuery,
            persona: persona,
            modelID: modelID,
            answer: CachedAnswer(text: text)
        )
    }
}

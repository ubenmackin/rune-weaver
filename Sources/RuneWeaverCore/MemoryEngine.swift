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
public extension MemoryEngine {
    /// Recall diagnostics carried alongside hits for per-turn observability.
    struct RecallDiagnostics: Sendable, Equatable {
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

public extension MemoryEngine {
    /// Stable identifier for one recall hit, never content.
    static func recallHitID(for result: MemoryResult, at index: Int) -> String {
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
    static func recallDiagnostics(for hits: [MemoryResult], injectedChars: Int, skippedDocIndex: Bool) -> RecallDiagnostics {
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
    ///
    /// Internal so the document-recall extension in a companion file shares the
    /// same single store path without duplicating configuration.
    let docIndexStore: DocIndexStore?
    /// In-memory profile snapshot, mirrored to disk best-effort.
    ///
    /// Internal so recall merging in a companion file reads the live profile
    /// without exposing mutation outside the engine.
    var profile: UserProfile
    /// JSON file backing the profile, if configured.
    private let profilePath: String?
    /// Maximum results fetched per tier before merging.
    ///
    /// Internal so recall extensions share one per-tier cap with the episodic
    /// and semantic paths instead of drifting into separate limits.
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
        initialProfile: UserProfile? = nil
    ) {
        self.episodeStore = episodeStore
        self.vectorStore = vectorStore
        self.docIndexStore = docIndexStore
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
    ///   - vectorDBPath: Directory for the semantic vector store.
    ///   - docIndexDBPath: SQLite path for the document index; omit for keyword-and-vector recall only.
    ///   - profilePath: JSON profile path; defaults beside the episodes database.
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

    /// Deletes every episodic turn for a session. Unknown sessions are a no-op.
    public func deleteSession(_ sessionID: UUID) async throws {
        try await withEpisodic {
            try await episodeStore.deleteSession(sessionID)
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

    /// Total stored episode count from the shared episode store.
    public func episodeCount() async -> Int {
        await (try? episodeStore.count()) ?? 0
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
            return fact
        } catch let error as VectorStoreError {
            throw MemoryEngineError.semanticFailed(String(describing: error))
        } catch {
            throw MemoryEngineError.semanticFailed(error.localizedDescription)
        }
    }

    /// Records a preference, then persists the profile.
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
    public func removePreference(key: String, value: String) {
        profile.preferences.removeAll { $0.key == key && $0.value == value }
        touchProfile()
    }

    /// Confirms a profile fact, refreshing its confidence and timestamp.
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
    public func removeProfileFact(id: UUID) {
        profile.facts.removeAll { $0.id == id }
        touchProfile()
    }

    /// Removes a profile fact and its semantic row best-effort.
    public func removeFact(id: UUID) async {
        try? await vectorStore.remove(id: id)
        profile.facts.removeAll { $0.id == id }
        touchProfile()
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
    }

    // MARK: - Extraction

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

public extension MemoryEngine {
    /// Extracts an explicit remember request from chat input.
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
    static func isStorableFact(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return containsAlphanumeric(trimmed)
    }

    /// Builds the acknowledgement text for an explicit remember request.
    static func rememberAcknowledgementText(for fact: String, stored: Bool) -> String {
        guard isStorableFact(fact) else {
            return "Usage: /remember <fact> — what should I remember?"
        }
        return stored ? "Remembered: \(fact)" : "Could not remember that."
    }

    /// Validates fact text and returns the trimmed form.
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
    static let episodicToolOutcomeLimit = 2000

    /// Builds compact episodic content for one tool execution.
    ///
    /// Untrusted external bytes stay delimited as data so a later recall cannot
    /// re-enter as trusted instructions: the `Used <tool>:` prefix is
    /// engine-authored and stays outside the label while the compact outcome
    /// carries the single-sourced data-only block. Trusted tools pass through
    /// with the exact historical shape, and a disabled labeler passes through
    /// byte-identically for debugging. Unknown provenance fails closed to
    /// untrusted so a caller that forgets to declare trust cannot silently
    /// persist attacker bytes as trusted history.
    static func episodicToolRecord(
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

    /// Builds compact episodic content from a bus result.
    ///
    /// Fail-closed legacy path: provenance is unknown here, so the record
    /// labels as untrusted rather than trusting by default. Callers with a
    /// declared `contentTrustLevel` use the overload below.
    static func episodicToolRecord(toolName: String, result: ToolResult) -> String? {
        episodicToolRecord(
            toolName: toolName,
            content: result.content,
            isError: result.isError,
            trustLevel: .untrustedExternal
        )
    }

    /// Builds compact episodic content from a bus result with declared provenance.
    static func episodicToolRecord(
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
    static func strippingToolPlumbing(from text: String) -> String {
        OrchestratorToolLoop.scrubPlaceholderPlumbing(from: text)
    }

    /// Stores one fact preferring vectors, falling back to keyword-only.
    func storeFactWithEmbedder(
        content: String,
        source: String,
        embedder: (any EmbeddingsBackend)?
    ) async throws -> UserFact {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if let embedder {
            if let vector = try await embedder.embedQuery(trimmed) {
                do {
                    return try await storeSemantic(
                        fact: trimmed,
                        embedding: vector,
                        metadata: ["source": source],
                        source: source
                    )
                } catch let error as CancellationError {
                    throw error
                } catch {
                    RuneWeaverLog.memory.info("MemoryEngine: Semantic store failed, falling back to keyword storage: \(error)")
                    // Fall through to keyword-only storage below.
                }
            }
        }
        return try await storeProfileFact(content: trimmed, source: source)
    }

    /// Stores a remembered fact, preferring vectors when a producer is set.
    @discardableResult
    func storeRememberedFact(
        content: String,
        source: String = "chat",
        embedder: (any EmbeddingsBackend)? = nil
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

    /// Maximum memories injected as system context on one chat turn.
    ///
    /// Legacy default for the threshold-based `automaticRecallContext` and
    /// `automaticRecallMessage` overloads below. The budgets-aware overloads
    /// read `RecallBudgets.autoLimit` instead; see `RecallBudgets` for the
    /// single source on the auto path.
    static let automaticRecallLimit = 5

    /// Minimum calibrated score for an injected recall hit.
    ///
    /// Legacy default for the threshold-based overloads. The budgets-aware
    /// overloads read `RecallBudgets.threshold` instead.
    static let automaticRecallThreshold = 0.1

    /// Maximum characters for the injected recall block, header included.
    ///
    /// Legacy default for the threshold-based overloads. The budgets-aware
    /// overloads read `RecallBudgets.maxChars` instead.
    static let automaticRecallMaxChars = 2000

    /// Header labeling injected recall as system context.
    static let automaticRecallHeader =
        "Relevant memories (use for context; do not mention unless relevant):"

    /// Whether a recall tier may carry attacker-controlled bytes.
    ///
    /// Indexed chunks hold file, mail, and message text, so they always
    /// re-enter as labeled data. Episodic tool mirrors (`Used <tool>: ...`)
    /// may carry web, browser, mail, and API bytes; plain user and assistant
    /// turns stay trusted verbatim so everyday recall pays no label tax.
    /// Semantic facts and profile preferences are owner-stored and stay
    /// trusted verbatim.
    static func isUntrustedRecallSource(_ source: MemorySource) -> Bool {
        source == .docIndex
    }

    /// Whether one recall hit must re-enter as labeled data.
    ///
    /// Structural, not advisory: tool mirrors are identified by the
    /// engine-authored `Used ` prefix the mirror writer owns, never by tool
    /// names, so a renamed tool keeps its provenance and user turns that
    /// happen to mention a tool stay trusted unless they carry the prefix.
    /// Index chunks always qualify through the single-sourced tier policy
    /// above; all other tiers qualify only when they carry the tool-mirror
    /// prefix.
    static func shouldLabelRecallResult(_ result: MemoryResult) -> Bool {
        if isUntrustedRecallSource(result.source) {
            return true
        }
        if result.source == .episodic {
            let trimmed = result.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.hasPrefix("Used ") || trimmed.hasPrefix("Used\n")
        }
        return false
    }

    /// Whether a recall payload already carries the data-only block.
    ///
    /// Fresh tool mirrors wrap at storage, so recall must not wrap them again:
    /// re-labeling would sanitize the inner delimiters into placeholder text
    /// and double the token tax. The check requires the full block structure
    /// in order (banner, then opening stem, then closing delimiter) so prose
    /// merely quoting one marker never reads as already-labeled. Index chunks
    /// always take the outer label regardless — sanitization neutralizes any
    /// forged delimiters inside — so a chunk quoting the banner cannot dodge
    /// labeling.
    static func isAlreadyLabeledRecallPayload(_ compact: String) -> Bool {
        guard let bannerRange = compact.range(of: ContentTrustLabeler.banner),
              let beginRange = compact.range(of: ContentTrustLabeler.beginPrefix),
              let endRange = compact.range(of: ContentTrustLabeler.endDelimiter)
        else {
            return false
        }
        return bannerRange.lowerBound < beginRange.lowerBound && beginRange.lowerBound < endRange.lowerBound
    }

    /// Truncates one recall block to `maxChars`, preserving the `maxChars == 1` edge.
    ///
    /// Single source for the header-plus-lines block cap so the
    /// threshold-based and budgets-aware overloads cannot drift.
    static func truncateRecallBlock(_ block: String, maxChars: Int) -> String {
        guard block.count > maxChars else { return block }
        if maxChars == 1 {
            return "…"
        }
        return String(block.prefix(maxChars - 1)) + "…"
    }

    /// Builds source-labeled recall context, token-bounded with truncation.
    ///
    /// Tool-mirror and index lines wrap their compact payload in the
    /// single-sourced data-only block so mirrored attacker bytes cannot
    /// re-enter as trusted system instructions; the `[source]` prefix stays
    /// outside the label as engine-authored routing. Indexed chunks always
    /// label so quoted delimiters cannot dodge the boundary (sanitization
    /// neutralizes inner copies); tool mirrors skip only when the full block
    /// structure is already present. Trusted tiers pass through with the
    /// historical shape, and a disabled labeler passes through
    /// byte-identically for debugging. Doc lines always carry one trailing
    /// citation suffix `[date|path|display_name]` built from hit metadata
    /// outside the truncation budget so it is never truncated away.
    static func automaticRecallContext(
        for results: [MemoryResult],
        threshold: Double = automaticRecallThreshold,
        maxChars: Int = automaticRecallMaxChars,
        labelingEnabled: Bool = true
    ) -> String? {
        guard maxChars > 0 else { return nil }
        let relevant = results.filter { $0.score >= threshold }
        guard !relevant.isEmpty else { return nil }
        let lines = relevant.map { recallLine(for: $0, perHitChars: RecallBudgets().clamped().perHitChars, labelingEnabled: labelingEnabled) }
        let block = ([automaticRecallHeader] + lines).joined(separator: "\n")
        return truncateRecallBlock(block, maxChars: maxChars)
    }

    /// Wraps recall hits as an injectable system message.
    static func automaticRecallMessage(
        for results: [MemoryResult],
        threshold: Double = automaticRecallThreshold,
        maxChars: Int = automaticRecallMaxChars,
        labelingEnabled: Bool = true
    ) -> Message? {
        guard let text = automaticRecallContext(for: results, threshold: threshold, maxChars: maxChars, labelingEnabled: labelingEnabled) else {
            return nil
        }
        return Message(role: .system, content: text)
    }

    /// Builds source-labeled recall context bounded by recall budgets.
    ///
    /// Budgets-aware entry for automatic recall: threshold, block cap,
    /// per-hit truncation, and injected-hit cap all come from the clamped
    /// budgets so file-load and live paths agree. Each hit keeps single-line
    /// squash plus `…` at `perHitChars`, preserves one trailing citation
    /// suffix `[date|path|display_name]` outside that truncation budget, and
    /// the whole block keeps the header plus `maxChars` total truncation.
    /// Labeling mirrors the threshold-based helper above.
    static func automaticRecallContext(
        for results: [MemoryResult],
        budgets: RecallBudgets,
        labelingEnabled: Bool = true
    ) -> String? {
        let clamped = budgets.clamped()
        guard clamped.maxChars > 0 else { return nil }
        let relevant = results.filter { $0.score >= clamped.threshold }
        guard !relevant.isEmpty else { return nil }
        let capped = Array(relevant.prefix(clamped.autoLimit))
        guard !capped.isEmpty else { return nil }
        let lines = capped.map { recallLine(for: $0, perHitChars: clamped.perHitChars, labelingEnabled: labelingEnabled) }
        let block = ([automaticRecallHeader] + lines).joined(separator: "\n")
        return truncateRecallBlock(block, maxChars: clamped.maxChars)
    }

    /// One recall line with per-hit truncation plus a preserved citation suffix.
    ///
    /// Content is squashed to one line and truncated to `perHitChars` with
    /// `…`; the citation suffix is appended outside that budget so it is never
    /// truncated away. Untrusted payloads label only the content bytes while
    /// the `[source]` prefix and the trailing citation stay outside as
    /// engine-authored routing.
    static func recallLine(for result: MemoryResult, perHitChars: Int, labelingEnabled: Bool) -> String {
        let singleLine = singleLineSquashed(result.content)
        let compact = singleLine.count > perHitChars ? String(singleLine.prefix(perHitChars)) + "…" : singleLine
        let citation = citationSuffix(for: result)
        if labelingEnabled, shouldLabelRecallResult(result) {
            if isUntrustedRecallSource(result.source) {
                let labeled = ContentTrustLabeler.label(toolName: recallSourceTag(for: result), content: compact)
                if let citation {
                    return "[\(result.source.rawValue)] \(labeled) \(citation)"
                }
                return "[\(result.source.rawValue)] \(labeled)"
            }
            // Check the emitted truncated payload, not the pre-truncation line:
            // a stored tool-mirror block truncated to `perHitChars` can lose
            // its closing delimiter, so a full-content check would skip
            // re-labeling and emit an unclosed block. Re-wrapping the
            // truncated bytes keeps the delimiters well-formed (labeling
            // sanitizes inner copies).
            if !isAlreadyLabeledRecallPayload(compact) {
                let labeled = ContentTrustLabeler.label(toolName: "recall:\(result.source.rawValue)", content: compact)
                if let citation {
                    return "[\(result.source.rawValue)] \(labeled) \(citation)"
                }
                return "[\(result.source.rawValue)] \(labeled)"
            }
        }
        if let citation {
            if compact.isEmpty {
                return "[\(result.source.rawValue)] \(citation)"
            }
            return "[\(result.source.rawValue)] \(compact) \(citation)"
        }
        return "[\(result.source.rawValue)] \(compact)"
    }

    /// Squashes recall content to a single trimmed line.
    static func singleLineSquashed(_ content: String) -> String {
        content
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Engine-authored attribution for the untrusted data-only block.
    static func recallSourceTag(for result: MemoryResult) -> String {
        if let name = result.metadata["display_name"], !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let trimmedName = singleLineSquashed(name)
            if let path = result.metadata["path"], !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "recall:\(result.source.rawValue):\(trimmedName) (\(singleLineSquashed(path)))"
            }
            return "recall:\(result.source.rawValue):\(trimmedName)"
        }
        return "recall:\(result.source.rawValue)"
    }

    /// One trailing citation suffix from hit metadata, never truncated away.
    ///
    /// Exactly one bracketed suffix per hit: available `date`, `path`, and
    /// `display_name` fields joined with `|` as `[date|path|display_name]`.
    /// Doc-index lines always carry a suffix (falling back to the chunk's
    /// `document_id` when the parent lookup missed); other tiers carry one
    /// only when they already hold such metadata.
    static func citationSuffix(for result: MemoryResult) -> String? {
        var parts: [String] = []
        if let date = result.metadata["date"]?.trimmingCharacters(in: .whitespacesAndNewlines), !date.isEmpty {
            let squashed = singleLineSquashed(date)
            if !squashed.isEmpty {
                parts.append(squashed)
            }
        }
        if let path = result.metadata["path"]?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            let squashed = singleLineSquashed(path)
            if !squashed.isEmpty {
                parts.append(squashed)
            }
        }
        if let displayName = result.metadata["display_name"]?.trimmingCharacters(in: .whitespacesAndNewlines), !displayName.isEmpty {
            let squashed = singleLineSquashed(displayName)
            if !squashed.isEmpty {
                parts.append(squashed)
            }
        }
        if parts.isEmpty {
            guard result.source == .docIndex else { return nil }
            if let documentID = result.metadata["document_id"]?.trimmingCharacters(in: .whitespacesAndNewlines), !documentID.isEmpty {
                return "[\(singleLineSquashed(documentID))]"
            }
            return "[indexed document]"
        }
        return "[\(parts.joined(separator: "|"))]"
    }

    /// Wraps recall hits as an injectable system message bounded by recall budgets.
    static func automaticRecallMessage(
        for results: [MemoryResult],
        budgets: RecallBudgets,
        labelingEnabled: Bool = true
    ) -> Message? {
        guard let text = automaticRecallContext(for: results, budgets: budgets, labelingEnabled: labelingEnabled) else {
            return nil
        }
        return Message(role: .system, content: text)
    }

    /// Injected subset of retrieved hits in rank order.
    ///
    /// Single source for recall observability: threshold-filtered plus
    /// `autoLimit`-capped, matching what `automaticRecallContext(for:budgets:)`
    /// and `automaticRecallMessage(for:budgets:)` actually inject. Retrieved
    /// hits stay pre-threshold (deduped, up to `perTier * 4`); diagnostics
    /// report this injected subset so `recallWithDiagnostics` and
    /// `recallMessageWithDiagnostics` log the same injected set by path.
    static func injectedRecallHits(from results: [MemoryResult], budgets: RecallBudgets) -> [MemoryResult] {
        let clamped = budgets.clamped()
        let relevant = results.filter { $0.score >= clamped.threshold }
        return Array(relevant.prefix(clamped.autoLimit))
    }
}

// MARK: - MemoryEngine Automatic Recall

public extension MemoryEngine {
    /// Drops the just-mirrored self-echo from recall hits.
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

    /// Inserts injected recall at a stable slot keeping the prefix identical across rounds.
    /// In multi-turn history, recall is inserted directly before the active user turn so
    /// all prior (system, user, assistant) turns preserve their prefix-cache tokens.
    /// If no user message is present, recall sits after leading system messages.
    static func historyWithRecall(_ history: [Message], recall: Message?) -> [Message] {
        guard let recall else { return history }
        guard !history.isEmpty else { return [recall] }
        if let lastUserIndex = history.lastIndex(where: { $0.role == .user }) {
            var spliced = history
            spliced.insert(recall, at: lastUserIndex)
            return spliced
        }
        var insertAt = 0
        while insertAt < history.count, history[insertAt].role == .system {
            insertAt += 1
        }
        var spliced = history
        spliced.insert(recall, at: insertAt)
        return spliced
    }

    /// Resolves automatic recall for one user turn, failure-isolated except cancellation.
    ///
    /// Temporal plus freshness-aware entry: the caller builds one `RecallPlan`
    /// via `MemoryQueryRouter.plan` and passes `RecallBudgets` alongside it.
    /// The plan window bounds `recall(query:embedding:limit:since:until:)`,
    /// `skipDocIndex` drops document hits via post-filter so the skip flag
    /// stays honest without extra index I/O, and a
    /// forced `LiveSearchOverride.shouldUseLiveSearch` filters remaining
    /// document hits so profile and semantic hits still inject.
    /// Embedding is best-effort: cancellation propagates while other errors
    /// fall back to nil for the keyword path. Empty queries, store errors,
    /// and below-threshold hits yield nil without failing the turn.
    func recallMessage(
        for query: String,
        sessionID: UUID,
        embedder: (any EmbeddingsBackend)? = nil,
        labelingEnabled: Bool = true,
        budgets: RecallBudgets = RecallBudgets(),
        plan: RecallPlan? = nil
    ) async throws -> Message? {
        let (message, _) = try await recallMessageWithDiagnostics(
            for: query,
            sessionID: sessionID,
            embedder: embedder,
            labelingEnabled: labelingEnabled,
            budgets: budgets,
            plan: plan
        )
        return message
    }

    /// Resolves automatic recall while reporting observability alongside the message.
    ///
    /// Retrieved-vs-injected: the intermediate `recall` hits are the retrieved
    /// set (deduped, pre-threshold, up to `perTier * 4`); diagnostics describe
    /// the injected set (threshold-filtered plus `autoLimit`-capped via
    /// `injectedRecallHits`, matching what the returned message injects and
    /// what `recallWithDiagnostics` reports, so both paths log the same
    /// injected `hits/ids/scores`). Diagnostics carry hit identifiers plus
    /// sources plus scores plus the injected char count plus the doc-index
    /// skip flag, never content.
    /// Silent-nil recalls (empty query, embedding fallback, store error, or
    /// below-threshold hits) return nil with zero-hit diagnostics so callers
    /// still emit one observability line per turn.
    func recallMessageWithDiagnostics(
        for query: String,
        sessionID: UUID,
        embedder: (any EmbeddingsBackend)? = nil,
        labelingEnabled: Bool = true,
        budgets: RecallBudgets = RecallBudgets(),
        plan: RecallPlan? = nil
    ) async throws -> (Message?, RecallDiagnostics) {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let skipped = (plan?.skipDocIndex ?? false) || docIndexStore == nil
            return (nil, RecallDiagnostics.zero(skippedDocIndex: skipped))
        }
        let effectiveBudgets = budgets.clamped()
        // Thread the caller's budgets into the default plan so `perTier`
        // and `expandedQuery` derive from the same clamped value the turn
        // fans out with instead of the default budgets.
        let effectivePlan = plan ?? MemoryQueryRouter.plan(for: query, currentDate: Date(), budgets: effectiveBudgets)
        let skipped = effectivePlan.skipDocIndex || docIndexStore == nil
        let recallQuery = effectivePlan.expandedQuery.isEmpty ? query : effectivePlan.expandedQuery
        var embedding: [Float]?
        do {
            if let embedder {
                embedding = try await embedder.embedQuery(recallQuery)
            } else {
                embedding = nil
            }
        } catch let error as CancellationError {
            throw error
        } catch {
            embedding = nil
        }
        do {
            // `plan.perTier` is the single source for fan-out; budgets still
            // govern threshold, caps, and weights downstream.
            let results = try await recall(
                query: recallQuery,
                embedding: embedding,
                limit: effectivePlan.perTier,
                since: effectivePlan.since,
                until: effectivePlan.until,
                budgets: effectiveBudgets,
                skipDocIndex: effectivePlan.skipDocIndex
            )
            let windowed: [MemoryResult] = if effectivePlan.skipDocIndex {
                results.filter { $0.source != .docIndex }
            } else if await LiveSearchOverride.shared.shouldUseLiveSearch(for: query) {
                // In this branch the plan did not request a skip, so a live
                // verdict here can only come from the forced override. Doc
                // hits filter out explicitly so a zero threshold cannot
                // re-admit them via `score >= threshold` while profile and
                // semantic hits still inject.
                results.filter { $0.source != .docIndex }
            } else {
                results
            }
            let filtered = Self.filteredRecallResults(windowed, query: query, sessionID: sessionID)
            let message = Self.automaticRecallMessage(for: filtered, budgets: effectiveBudgets, labelingEnabled: labelingEnabled)
            let injectedChars = message?.content.count ?? 0
            // When the block is nil (no relevant hits) report zero hits so
            // silent-nil turns still emit a zero-hit line. The injected set
            // shares `injectedRecallHits` with `recallWithDiagnostics` so both
            // paths report the same threshold plus `autoLimit` capped hits.
            let reported: [MemoryResult] = message == nil ? [] : Self.injectedRecallHits(from: filtered, budgets: effectiveBudgets)
            let diagnostics = Self.recallDiagnostics(for: reported, injectedChars: injectedChars, skippedDocIndex: skipped)
            return (message, diagnostics)
        } catch let error as CancellationError {
            throw error
        } catch {
            return (nil, RecallDiagnostics.zero(skippedDocIndex: skipped))
        }
    }
}

// MARK: - Episode Message Conversion

public extension Episode {
    /// Converts an episodic turn back to working-memory history.
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
    static func hydrationMessages(from episodes: [Episode]) -> [Message] {
        episodes.compactMap { $0.hydrationMessage() }
    }
}

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
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: expanded)) else { return nil }
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

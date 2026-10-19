// Rune Weaver Core — Onboarding persistence for the single-row setup state.

import Foundation
#if canImport(SQLite3)
    import SQLite3
#endif

/// Durable onboarding state held as exactly one row in `episodes.db`.
public struct OnboardingState: Sendable, Codable, Equatable {
    /// Completion instant, nil while the wizard never finished.
    public var completedAt: Date?
    /// Skipped step ids from the closed allowlist.
    public var skippedSteps: [String]
    /// Whether the post-setup checklist is dismissed.
    public var checklistDismissed: Bool
    /// Optional owner seed prompt, capped at 200 characters.
    public var seedPromptUsed: String?

    /// Creates an onboarding state.
    public init(
        completedAt: Date? = nil,
        skippedSteps: [String] = [],
        checklistDismissed: Bool = false,
        seedPromptUsed: String? = nil
    ) {
        self.completedAt = completedAt
        self.skippedSteps = skippedSteps
        self.checklistDismissed = checklistDismissed
        self.seedPromptUsed = seedPromptUsed
    }

    /// Never-started shape served when the table holds no row.
    public static var neverStarted: OnboardingState {
        OnboardingState()
    }
}

/// Failures raised by the onboarding store.
public enum OnboardingStoreError: Error, Sendable, Equatable {
    /// The SQLite file could not be opened or migrated.
    case storeUnavailable(String)
    /// A read or write against the store failed.
    case persistenceFailed(String)
    /// A skipped step id is outside the closed allowlist.
    case unknownStep(String)
    /// More than the bounded skipped-step count was requested.
    case tooManySkipped(Int)
    /// A seed prompt exceeds the 200-character bound.
    case seedTooLong(Int)
}

extension OnboardingStoreError: LocalizedError {
    /// Human-readable refusal naming the failing bound.
    public var errorDescription: String? {
        switch self {
        case let .storeUnavailable(detail):
            "Onboarding store unavailable: \(detail)"
        case let .persistenceFailed(detail):
            "Onboarding store write failed: \(detail)"
        case let .unknownStep(step):
            "unknown_step: \(step)"
        case let .tooManySkipped(count):
            "Too many skipped steps (\(count)); maximum is \(OnboardingStore.maxSkippedSteps)."
        case let .seedTooLong(count):
            "Seed prompt is \(count) characters; maximum is \(OnboardingStore.maxSeedPromptLength)."
        }
    }
}

/// Seam for onboarding persistence so fallback and tests substitute doubles.
public protocol OnboardingStoring: Sendable {
    /// Filesystem path backing the store, or sentinel for doubles.
    var dbPath: String { get }

    /// Reads the single row, degrading to never-started when absent.
    func read() throws -> OnboardingState

    /// Validates and persists the single row.
    func write(_ state: OnboardingState) throws
}

/// Fail-closed double for unconfigured contexts; every access throws.
public struct ThrowingOnboardingStore: OnboardingStoring {
    /// Sentinel path never touching the production database.
    public let dbPath: String

    /// Creates a throwing double over an in-memory sentinel path.
    public init(dbPath: String = ":memory:") {
        self.dbPath = dbPath
    }

    /// Always throws so unconfigured reads fail closed.
    public func read() throws -> OnboardingState {
        throw OnboardingStoreError.storeUnavailable("onboarding unavailable")
    }

    /// Always throws so unconfigured writes fail closed.
    public func write(_ _: OnboardingState) throws {
        throw OnboardingStoreError.storeUnavailable("onboarding unavailable")
    }
}

/// Single-row SQLite persistence for the onboarding wizard.
public final class OnboardingStore: OnboardingStoring, Sendable {
    /// Closed step allowlist backing skip validation.
    public static let allowedSteps: Set<String> = ["brain", "persona", "connect", "protect"]
    /// Maximum skipped-step entries stored on the single row.
    public static let maxSkippedSteps = 4
    /// Maximum stored seed-prompt characters.
    public static let maxSeedPromptLength = 200

    /// Filesystem path of the shared SQLite database.
    public let dbPath: String

    /// Creates a store holding only the path; tables materialize on first read or write.
    public init(dbPath: String = (MemoryConfig.defaultEpisodesDBPath as NSString).expandingTildeInPath) {
        self.dbPath = dbPath
    }

    /// Reads the single row, returning the never-started shape when absent.
    public func read() throws -> OnboardingState {
        try Self.ensureTable(dbPath: dbPath)
        return try Self.readRow(dbPath: dbPath)
    }

    /// Validates and persists the single row, replacing any prior values.
    public func write(_ state: OnboardingState) throws {
        try Self.validated(state)
        try Self.ensureTable(dbPath: dbPath)
        try Self.writeRow(state, dbPath: dbPath)
    }

    /// Rejects unknown steps, over-capacity skips, and over-long seeds.
    public static func validated(_ state: OnboardingState) throws {
        for step in state.skippedSteps {
            guard allowedSteps.contains(step) else {
                throw OnboardingStoreError.unknownStep(step)
            }
        }
        guard state.skippedSteps.count <= maxSkippedSteps else {
            throw OnboardingStoreError.tooManySkipped(state.skippedSteps.count)
        }
        if let seed = state.seedPromptUsed, seed.count > maxSeedPromptLength {
            throw OnboardingStoreError.seedTooLong(seed.count)
        }
    }

    /// Creates the single-row table when absent.
    private static func ensureTable(dbPath: String) throws {
        #if canImport(SQLite3)
            let handle = try SQLiteHelpers.openHandle(dbPath: dbPath, unavailable: OnboardingStoreError.storeUnavailable)
            defer { sqlite3_close(handle) }
            try SQLiteHelpers.exec(
                handle: handle,
                sql: """
                CREATE TABLE IF NOT EXISTS onboarding_state(
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    completed_at TEXT,
                    skipped_steps TEXT NOT NULL DEFAULT '[]',
                    checklist_dismissed INTEGER NOT NULL DEFAULT 0,
                    seed_prompt_used TEXT
                );
                """,
                failure: OnboardingStoreError.storeUnavailable
            )
        #else
            throw OnboardingStoreError.storeUnavailable("SQLite unavailable")
        #endif
    }

    /// Reads row id 1, degrading to never-started when the row is absent.
    private static func readRow(dbPath: String) throws -> OnboardingState {
        #if canImport(SQLite3)
            let handle = try SQLiteHelpers.openHandle(dbPath: dbPath, unavailable: OnboardingStoreError.storeUnavailable)
            defer { sqlite3_close(handle) }
            let sql = "SELECT completed_at, skipped_steps, checklist_dismissed, seed_prompt_used FROM onboarding_state WHERE id = 1;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw OnboardingStoreError.persistenceFailed("Could not prepare onboarding read.")
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else {
                return .neverStarted
            }
            let completedAt = Self.parseDate(SQLiteHelpers.columnText(statement, index: 0))
            let skipped = Self.parseSkipped(SQLiteHelpers.columnText(statement, index: 1))
            let dismissedValue = SQLiteHelpers.columnInt64(statement, index: 2) ?? 0
            let seed = Self.normalizeSeed(SQLiteHelpers.columnText(statement, index: 3))
            return OnboardingState(
                completedAt: completedAt,
                skippedSteps: skipped,
                checklistDismissed: dismissedValue == 1,
                seedPromptUsed: seed
            )
        #else
            throw OnboardingStoreError.storeUnavailable("SQLite unavailable")
        #endif
    }

    /// Replaces row id 1 with the validated state.
    private static func writeRow(_ state: OnboardingState, dbPath: String) throws {
        #if canImport(SQLite3)
            let handle = try SQLiteHelpers.openHandle(dbPath: dbPath, unavailable: OnboardingStoreError.storeUnavailable)
            defer { sqlite3_close(handle) }
            let sql = """
            INSERT INTO onboarding_state(id, completed_at, skipped_steps, checklist_dismissed, seed_prompt_used)
            VALUES(1, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                completed_at = excluded.completed_at,
                skipped_steps = excluded.skipped_steps,
                checklist_dismissed = excluded.checklist_dismissed,
                seed_prompt_used = excluded.seed_prompt_used;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw OnboardingStoreError.persistenceFailed("Could not prepare onboarding write.")
            }
            defer { sqlite3_finalize(statement) }
            let completedText: String? = state.completedAt.map { SharedDateFormatters.isoWithFractionalSecondsString(from: $0) }
            let skippedText = Self.encodeSkipped(state.skippedSteps)
            SQLiteHelpers.bindText(statement, index: 1, value: completedText)
            SQLiteHelpers.bindText(statement, index: 2, value: skippedText)
            sqlite3_bind_int64(statement, 3, state.checklistDismissed ? 1 : 0)
            SQLiteHelpers.bindText(statement, index: 4, value: state.seedPromptUsed)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw OnboardingStoreError.persistenceFailed("Could not persist onboarding state.")
            }
        #else
            throw OnboardingStoreError.storeUnavailable("SQLite unavailable")
        #endif
    }

    /// Parses an ISO8601 timestamp, accepting fractional and plain forms.
    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return SharedDateFormatters.isoWithFractionalSecondsDate(from: trimmed)
            ?? SharedDateFormatters.isoInternetTimeDate(from: trimmed)
            ?? SharedDateFormatters.isoDefaultDate(from: trimmed)
    }

    /// Decodes the skipped-steps JSON array, degrading corrupt payloads to empty.
    private static func parseSkipped(_ raw: String?) -> [String] {
        guard let raw, let data = raw.data(using: .utf8), let decoded = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return decoded.filter { allowedSteps.contains($0) }.prefix(maxSkippedSteps).map(\.self)
    }

    /// Encodes skipped steps as a JSON array string.
    private static func encodeSkipped(_ steps: [String]) -> String {
        guard let data = try? JSONEncoder().encode(steps),
              let text = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        return text
    }

    /// Normalizes an empty or blank seed to nil so absent stays absent.
    private static func normalizeSeed(_ raw: String?) -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return raw
    }
}

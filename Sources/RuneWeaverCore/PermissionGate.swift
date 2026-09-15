// Rune Weaver Core — Graduated-trust permission gate and trust storage.
//
// Enforces the trust boundary between the agent and the real world:
// read-only tools run freely, approval-gated tools require explicit
// decisions with graduated-trust grants, and denied actions refuse with
// reasons. Persists grants best-effort through a pluggable trust store.

import Foundation
#if canImport(SQLite3)
    import SQLite3
#endif

/// How long a graduated-trust grant lasts.
///
/// Offered to the user when approving a state-changing action so they
/// are not approving the same thing forever. `thisTime` is a one-shot
/// approval and is never persisted; `forever` never expires.
public enum TrustDuration: String, Sendable, Codable, Equatable, CaseIterable {
    /// Approve once. No grant is stored.
    case thisTime
    /// Trust the action for the next 5 minutes.
    case fiveMinutes
    /// Trust the action for the next hour.
    case oneHour
    /// Trust the action for the next day.
    case oneDay
    /// Trust the action indefinitely.
    case forever

    /// Human-readable label shown in approval prompts.
    public var displayName: String {
        switch self {
        case .thisTime: "Only this time"
        case .fiveMinutes: "Next 5 minutes"
        case .oneHour: "Next hour"
        case .oneDay: "Next day"
        case .forever: "Forever"
        }
    }

    /// Grant lifetime in seconds, or nil when the grant never expires.
    ///
    /// `thisTime` returns `0` (expires immediately, so callers treat it
    /// as a single-use approval and skip persistence). `forever`
    /// returns `nil` (no expiry).
    public var timeInterval: TimeInterval? {
        switch self {
        case .thisTime: 0
        case .fiveMinutes: 5 * 60
        case .oneHour: 60 * 60
        case .oneDay: 24 * 60 * 60
        case .forever: nil
        }
    }
}

/// Identifies a trustable action: a tool plus an optional target.
///
/// Trust is stored per action per target, e.g. tool
/// `"email.send"` with target `"dr.smith@clinic.com"`. An empty
/// `target` means the grant covers every target for that tool.
public struct ActionDescriptor: Sendable, Codable, Equatable, Hashable {
    /// Name of the tool (e.g. `"email.send"`).
    public let toolName: String
    /// Action target (e.g. `"dr.smith@clinic.com"`). Empty matches all.
    public let target: String

    /// Creates an action descriptor.
    /// - Parameters:
    ///   - toolName: Name of the tool.
    ///   - target: Action target. Defaults to `""` (all targets).
    public init(toolName: String, target: String = "") {
        self.toolName = toolName
        self.target = target
    }

    /// Derives a descriptor from a tool call.
    ///
    /// Best-effort extraction of a target from common argument keys
    /// (`to`, `recipient`, `target`, `path`, `url`, `email`,
    /// `address`, `destination`). Falls back to `""` when no target
    /// can be found or the arguments are not JSON.
    /// - Parameters:
    ///   - toolCall: Invocation arguments.
    ///   - tool: The tool being invoked.
    /// - Returns: Descriptor for the call.
    public static func descriptor(for toolCall: ToolInput, tool: any Tool) -> ActionDescriptor {
        ActionDescriptor(toolName: tool.name, target: ActionDescriptor.target(from: toolCall))
    }

    /// Extracts a target string from raw tool arguments.
    ///
    /// Email recipients are case-insensitive and may arrive as a single
    /// string or an array, so `to` (plus the `recipient`/`email` aliases)
    /// normalizes to a lowercased comma-joined list. A grant for one
    /// address then bypasses only that address while a different recipient
    /// re-prompts. All other tools fall back to the first non-empty string
    /// among the remaining target keys.
    /// - Parameter toolCall: Invocation carrying `argumentsJSON`.
    /// - Returns: The extracted target, or `""` when absent.
    public static func target(from toolCall: ToolInput) -> String {
        guard let data = toolCall.argumentsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "" }
        for key in ["to", "recipient", "email"] {
            if let joined = normalizedEmailTarget(object[key]) {
                return joined
            }
        }
        for key in ["target", "path", "url", "address", "destination"] {
            if let value = object[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return ""
    }

    /// Normalizes an email recipient value to a lowercased target.
    ///
    /// Accepts a bare string (`"Dr.Smith@Clinic.com"` trims and lowercases)
    /// or an array of strings (trims, drops blanks, lowercases, and joins
    /// with commas). Non-string elements are ignored so a malformed array
    /// never produces a grant-bypassing target. Returns nil when no usable
    /// address remains so callers fall through to the next alias.
    /// - Parameter value: Raw JSON value for `to`/`recipient`/`email`.
    /// - Returns: Lowercased target, or nil when absent.
    private static func normalizedEmailTarget(_ value: Any?) -> String? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            // Split comma-separated strings so `"a@x.com, B@x.com"` matches
            // the array-joined form instead of a spacing variant.
            let parts = trimmed.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }.filter { !$0.isEmpty }
            guard !parts.isEmpty else { return nil }
            return parts.joined(separator: ",")
        }
        if let list = value as? [String] {
            let parts = list.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }.filter { !$0.isEmpty }
            guard !parts.isEmpty else { return nil }
            return parts.joined(separator: ",")
        }
        if let list = value as? [Any] {
            let parts = list.compactMap { $0 as? String }.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }.filter { !$0.isEmpty }
            guard !parts.isEmpty else { return nil }
            return parts.joined(separator: ",")
        }
        return nil
    }
}

/// A persisted graduated-trust grant for an ``ActionDescriptor``.
public struct TrustGrant: Sendable, Codable, Equatable {
    /// Stable grant identifier.
    public let id: UUID
    /// The trusted action (tool + target).
    public let actionDescriptor: ActionDescriptor
    /// When the grant was created.
    public let grantedAt: Date
    /// When the grant expires, or nil when it never expires.
    public let expiresAt: Date?
    /// The duration tier this grant was created with.
    public let duration: TrustDuration

    /// Creates a trust grant.
    /// - Parameters:
    ///   - id: Grant identifier. Defaults to a new UUID.
    ///   - actionDescriptor: The trusted action.
    ///   - grantedAt: Creation date. Defaults to now.
    ///   - expiresAt: Expiry date, or nil for no expiry.
    ///   - duration: Duration tier.
    public init(
        id: UUID = UUID(),
        actionDescriptor: ActionDescriptor,
        grantedAt: Date = Date(),
        expiresAt: Date?,
        duration: TrustDuration
    ) {
        self.id = id
        self.actionDescriptor = actionDescriptor
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
        self.duration = duration
    }

    /// Whether the grant is expired at the given date.
    /// - Parameter date: Reference date. Defaults to now.
    /// - Returns: True when `expiresAt` is past `date`.
    public func isExpired(at date: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= date
    }

    /// Whether the grant is currently valid.
    /// - Parameter date: Reference date. Defaults to now.
    /// - Returns: True when not expired.
    public func isValid(at date: Date = Date()) -> Bool {
        !isExpired(at: date)
    }
}

/// Approval prompt sent to connected clients (e.g. over WebSocket).
public struct PermissionRequest: Sendable, Codable, Equatable {
    /// Stable request identifier.
    public let id: UUID
    /// Name of the tool requesting approval.
    public let toolName: String
    /// Human-readable summary of what the tool wants to do.
    public let description: String
    /// The original invocation arguments.
    public let input: ToolInput
    /// Duration options offered to the user.
    public let suggestedDurations: [TrustDuration]
    /// Owning session for narrated parked turns, if known.
    ///
    /// Structured gate checks leave this untagged while the narration
    /// fallback stamps the session so the approvals inbox can resume the
    /// same conversation on allow or notify it on deny.
    public let sessionID: UUID?

    /// Coding keys for the approval prompt.
    private enum CodingKeys: String, CodingKey {
        /// Stable request identifier.
        case id
        /// Name of the tool requesting approval.
        case toolName
        /// Human-readable summary.
        case description
        /// Original invocation arguments.
        case input
        /// Duration options offered to the user.
        case suggestedDurations
        /// Owning session, when tagged.
        case sessionID
    }

    /// Creates a permission request.
    /// - Parameters:
    ///   - id: Request identifier. Defaults to a new UUID.
    ///   - toolName: Name of the tool.
    ///   - description: Human-readable summary.
    ///   - input: Original invocation.
    ///   - suggestedDurations: Duration options. Defaults to all tiers.
    ///   - sessionID: Owning session for parked narration. Defaults to nil (untagged).
    public init(
        id: UUID = UUID(),
        toolName: String,
        description: String,
        input: ToolInput,
        suggestedDurations: [TrustDuration] = TrustDuration.allCases,
        sessionID: UUID? = nil
    ) {
        self.id = id
        self.toolName = toolName
        self.description = description
        self.input = input
        self.suggestedDurations = suggestedDurations
        self.sessionID = sessionID
    }

    /// Decodes a request, tolerating payloads written before session tagging.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.toolName = try container.decode(String.self, forKey: .toolName)
        self.description = try container.decode(String.self, forKey: .description)
        self.input = try container.decode(ToolInput.self, forKey: .input)
        self.suggestedDurations = try container.decode([TrustDuration].self, forKey: .suggestedDurations)
        self.sessionID = try container.decodeIfPresent(UUID.self, forKey: .sessionID)
    }

    /// Encodes a request, omitting the session tag when untagged.
    /// - Parameter encoder: Destination encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(toolName, forKey: .toolName)
        try container.encode(description, forKey: .description)
        try container.encode(input, forKey: .input)
        try container.encode(suggestedDurations, forKey: .suggestedDurations)
        try container.encodeIfPresent(sessionID, forKey: .sessionID)
    }
}

/// Verdict returned by ``PermissionGate/checkPermission(toolCall:tool:)``.
///
/// `ToolBus` consults the gate before executing any tool: `allowed`
/// runs immediately, `requiresApproval` is forwarded to connected
/// clients (WebSocket) for a trust-tiered decision, and `denied`
/// fails the call with the associated reason.
public enum PermissionDecision: Sendable, Equatable {
    /// The call may run immediately.
    case allowed
    /// The call needs user approval via the associated request.
    case requiresApproval(PermissionRequest)
    /// The call is refused with the associated reason.
    case denied(String)
}

/// Persistence contract for ``TrustGrant`` records.
///
/// The gate keeps grants in memory and mirrors them to the store
/// best-effort; a corrupt or missing store never blocks permission
/// checks, it simply starts from an empty grant set.
public protocol TrustStore: Sendable {
    /// Loads all stored active grants.
    /// - Returns: Persisted grants, possibly empty.
    func load() async throws -> [TrustGrant]
    /// Replaces the stored grants.
    /// - Parameter grants: Current grants to persist.
    func save(_ grants: [TrustGrant]) async throws
    /// Deletes expired grants from storage.
    /// - Parameter date: Threshold date.
    func pruneExpired(at date: Date) async throws
}

/// In-memory ``TrustStore`` for tests and ephemeral sessions.
public actor InMemoryTrustStore: TrustStore {
    private var grants: [TrustGrant]

    /// Creates an empty in-memory store.
    /// - Parameter grants: Seed grants. Defaults to empty.
    public init(grants: [TrustGrant] = []) {
        self.grants = grants
    }

    /// Returns the in-memory grants.
    /// - Returns: Current grants.
    public func load() async throws -> [TrustGrant] {
        grants
    }

    /// Replaces the in-memory grants.
    /// - Parameter grants: Grants to keep.
    public func save(_ grants: [TrustGrant]) async throws {
        self.grants = grants
    }

    /// Prunes expired in-memory grants.
    /// - Parameter date: Expiry threshold. Defaults to now.
    public func pruneExpired(at date: Date = Date()) async throws {
        grants.removeAll { $0.isExpired(at: date) }
    }
}

/// JSON-file ``TrustStore`` persisted under `~/.runeweaver/`.
///
/// Stores grants as a JSON array at `fileURL`. Missing files read as
/// empty; writes are atomic.
public struct FileTrustStore: TrustStore, Sendable {
    /// File URL of the JSON grant list.
    public let fileURL: URL

    /// Creates a file store.
    /// - Parameter fileURL: Destination JSON file.
    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Loads grants from disk, returning empty when absent.
    /// - Returns: Persisted grants.
    public func load() async throws -> [TrustGrant] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else { return [] }
        return try JSONDecoder().decode([TrustGrant].self, from: data)
    }

    /// Persists grants to disk atomically.
    /// - Parameter grants: Grants to persist.
    public func save(_ grants: [TrustGrant]) async throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(grants)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Prunes expired grants from disk.
    /// - Parameter date: Expiry threshold.
    public func pruneExpired(at date: Date = Date()) async throws {
        var current: [TrustGrant]
        do {
            current = try await load()
        } catch {
            current = []
        }
        current.removeAll { $0.isExpired(at: date) }
        try await save(current)
    }
}

#if canImport(SQLite3)
    /// Internal SQLite helper for durable trust grant persistence in `episodes.db`.
    enum SQLiteTrustStorage {
        private struct TrustStorageError: Error {
            let message: String
        }

        private static func open(dbPath: String) throws -> OpaquePointer? {
            let handle = try SQLiteHelpers.openHandle(dbPath: dbPath, unavailable: { TrustStorageError(message: $0) })
            try SQLiteHelpers.exec(
                handle: handle,
                sql: """
                CREATE TABLE IF NOT EXISTS trust_grants (
                    id TEXT PRIMARY KEY,
                    tool_name TEXT NOT NULL,
                    target TEXT NOT NULL,
                    granted_at REAL NOT NULL,
                    expires_at REAL,
                    duration TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_trust_grants_tool_target ON trust_grants(tool_name, target);
                CREATE INDEX IF NOT EXISTS idx_trust_grants_expires_at ON trust_grants(expires_at);
                """,
                failure: { TrustStorageError(message: $0) }
            )
            return handle
        }

        static func load(dbPath: String) -> [TrustGrant] {
            guard let handle = try? open(dbPath: dbPath) else { return [] }
            defer { sqlite3_close(handle) }
            let now = Date().timeIntervalSince1970
            let sql = "SELECT id, tool_name, target, granted_at, expires_at, duration FROM trust_grants WHERE expires_at IS NULL OR expires_at > ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            SQLiteHelpers.bindDouble(statement, index: 1, value: now)
            var results: [TrustGrant] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let idString = SQLiteHelpers.columnText(statement, index: 0),
                      let id = UUID(uuidString: idString),
                      let toolName = SQLiteHelpers.columnText(statement, index: 1),
                      let durationRaw = SQLiteHelpers.columnText(statement, index: 5),
                      let duration = TrustDuration(rawValue: durationRaw)
                else { continue }
                let target = SQLiteHelpers.columnText(statement, index: 2) ?? ""
                let grantedAtSeconds = SQLiteHelpers.columnDouble(statement, index: 3)
                let grantedAt = Date(timeIntervalSince1970: grantedAtSeconds)
                var expiresAt: Date?
                if sqlite3_column_type(statement, 4) != SQLITE_NULL {
                    expiresAt = Date(timeIntervalSince1970: SQLiteHelpers.columnDouble(statement, index: 4))
                }
                results.append(TrustGrant(
                    id: id,
                    actionDescriptor: ActionDescriptor(toolName: toolName, target: target),
                    grantedAt: grantedAt,
                    expiresAt: expiresAt,
                    duration: duration
                ))
            }
            return results
        }

        static func pruneExpired(at date: Date, dbPath: String) {
            guard let handle = try? open(dbPath: dbPath) else { return }
            defer { sqlite3_close(handle) }
            let sql = "DELETE FROM trust_grants WHERE expires_at IS NOT NULL AND expires_at <= ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(statement) }
            SQLiteHelpers.bindDouble(statement, index: 1, value: date.timeIntervalSince1970)
            _ = sqlite3_step(statement)
        }

        static func save(grants: [TrustGrant], dbPath: String) {
            guard let handle = try? open(dbPath: dbPath) else { return }
            defer { sqlite3_close(handle) }
            // Replace the table atomically: any prepare/step failure rolls
            // back to the pre-save contents instead of committing an
            // empty or partial grant set that would wipe live trust.
            guard sqlite3_exec(handle, "BEGIN IMMEDIATE TRANSACTION;", nil, nil, nil) == SQLITE_OK else { return }
            guard sqlite3_exec(handle, "DELETE FROM trust_grants;", nil, nil, nil) == SQLITE_OK else {
                _ = sqlite3_exec(handle, "ROLLBACK;", nil, nil, nil)
                return
            }
            let insertSQL = "INSERT INTO trust_grants (id, tool_name, target, granted_at, expires_at, duration) VALUES (?, ?, ?, ?, ?, ?);"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
                _ = sqlite3_exec(handle, "ROLLBACK;", nil, nil, nil)
                return
            }
            var succeeded = true
            for grant in grants {
                sqlite3_reset(stmt)
                SQLiteHelpers.bindText(stmt, index: 1, value: grant.id.uuidString)
                SQLiteHelpers.bindText(stmt, index: 2, value: grant.actionDescriptor.toolName)
                SQLiteHelpers.bindText(stmt, index: 3, value: grant.actionDescriptor.target)
                SQLiteHelpers.bindDouble(stmt, index: 4, value: grant.grantedAt.timeIntervalSince1970)
                if let exp = grant.expiresAt {
                    SQLiteHelpers.bindDouble(stmt, index: 5, value: exp.timeIntervalSince1970)
                } else {
                    sqlite3_bind_null(stmt, 5)
                }
                SQLiteHelpers.bindText(stmt, index: 6, value: grant.duration.rawValue)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    succeeded = false
                    break
                }
            }
            sqlite3_finalize(stmt)
            if succeeded {
                if sqlite3_exec(handle, "COMMIT;", nil, nil, nil) != SQLITE_OK {
                    _ = sqlite3_exec(handle, "ROLLBACK;", nil, nil, nil)
                }
            } else {
                _ = sqlite3_exec(handle, "ROLLBACK;", nil, nil, nil)
            }
        }
    }
#endif

/// SQLite-backed ``TrustStore`` persisted under `episodes.db` in table `trust_grants`.
public struct SQLiteTrustStore: TrustStore, Sendable {
    /// Filesystem path of the SQLite database (`episodes.db`).
    public let dbPath: String

    /// Creates an SQLite trust store.
    /// - Parameter dbPath: SQLite database file path.
    public init(dbPath: String) {
        self.dbPath = dbPath
    }

    /// Loads active non-expired grants from SQLite.
    public func load() async throws -> [TrustGrant] {
        #if canImport(SQLite3)
            return await SQLiteSerialIO.runUncancellable {
                SQLiteTrustStorage.load(dbPath: dbPath)
            }
        #else
            return []
        #endif
    }

    /// Replaces the persisted grants in SQLite.
    public func save(_ grants: [TrustGrant]) async throws {
        #if canImport(SQLite3)
            await SQLiteSerialIO.runUncancellable {
                SQLiteTrustStorage.save(grants: grants, dbPath: dbPath)
            }
        #endif
    }

    /// Deletes expired grants from SQLite.
    public func pruneExpired(at date: Date = Date()) async throws {
        #if canImport(SQLite3)
            await SQLiteSerialIO.runUncancellable {
                SQLiteTrustStorage.pruneExpired(at: date, dbPath: dbPath)
            }
        #endif
    }
}

/// Trust boundary between the agent and the real world.
///
/// The gate enforces graduated trust for state-changing tools:
/// - `readOnly` tools are always `allowed`.
/// - `trusted` tools are `allowed` unless explicitly denied.
/// - `requiresApproval` tools are `allowed` only when covered by a
///   live ``TrustGrant``; otherwise a ``PermissionRequest`` is
///   returned so `ToolBus` can forward it to connected clients via
///   WebSocket and record the user's chosen ``TrustDuration`` with
///   ``grantTrust(for:duration:)``.
public actor PermissionGate {
    /// Live grants, mirrored to the store best-effort.
    private var grants: [TrustGrant] = []
    /// Explicit refusals by descriptor, carrying the denial reason.
    private var denials: [ActionDescriptor: String] = [:]
    /// Optional persistence backend.
    private let store: (any TrustStore)?
    /// Configured plugins directory for protected path enforcement.
    public let pluginsDir: URL?
    /// Recurring task for pruning expired grants periodically.
    ///
    /// Owned by the actor and cancelled only via `stopPeriodicCleanup()`;
    /// there is intentionally no `deinit` cancel because actor-isolated
    /// state cannot be touched from a non-isolated `deinit`.
    private var reaperTask: Task<Void, Never>?

    /// Creates a permission gate.
    /// - Parameters:
    ///   - store: Persistence backend. Defaults to nil (memory only).
    ///   - pluginsDir: Configured plugins directory. Defaults to nil (uses default path).
    public init(store: (any TrustStore)? = nil, pluginsDir: URL? = nil) {
        self.store = store
        self.pluginsDir = pluginsDir
    }

    /// Loads a permission gate hydrated from durable storage, pruning expired grants on startup.
    /// - Parameters:
    ///   - store: Persistence backend.
    ///   - pluginsDir: Configured plugins directory.
    /// - Returns: Hydrated permission gate.
    public static func load(store: (any TrustStore)? = nil, pluginsDir: URL? = nil) async -> PermissionGate {
        let gate = PermissionGate(store: store, pluginsDir: pluginsDir)
        await gate.bootstrap()
        return gate
    }

    /// Hydrates grants from storage, cleaning up expired records immediately.
    public func bootstrap() async {
        guard let store else { return }
        let now = Date()
        try? await store.pruneExpired(at: now)
        do {
            grants = try await store.load()
        } catch {
            grants = []
        }
        grants.removeAll { $0.isExpired(at: now) }
    }

    /// Starts a periodic background reaper that checks and cleans up expired grants.
    ///
    /// The reaper lives until `stopPeriodicCleanup()` cancels it; callers
    /// own that shutdown pairing because the actor cannot cancel
    /// isolated state from `deinit`.
    /// - Parameter intervalSeconds: Cadence between checks. Defaults to 60.
    ///   Clamped to a minimum of 0.01 seconds so sub-second test cadences
    ///   tick as requested while guarding against zero or negative sleeps.
    public func startPeriodicCleanup(intervalSeconds: TimeInterval = 60) {
        stopPeriodicCleanup()
        let interval = max(0.01, intervalSeconds)
        reaperTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    break
                }
                guard !Task.isCancelled, let self else { break }
                await self.pruneExpiredAndPersist()
            }
        }
    }

    /// Stops the periodic background cleanup reaper.
    ///
    /// Safe to call when no reaper is running; pair every
    /// `startPeriodicCleanup()` with this on shutdown so the sleep
    /// task does not outlive its owner.
    public func stopPeriodicCleanup() {
        reaperTask?.cancel()
        reaperTask = nil
    }

    /// Prunes expired grants from memory and storage.
    ///
    /// Runs on the actor so overlapping grant and revoke calls serialize;
    /// the store prune is awaited, preserving disk order with call order.
    public func pruneExpiredAndPersist() async {
        let now = Date()
        grants.removeAll { $0.isExpired(at: now) }
        if let store {
            try? await store.pruneExpired(at: now)
        }
    }

    /// Checks whether a tool call targets a protected engine path.
    private func isProtectedTarget(toolCall: ToolInput) -> Bool {
        guard let data = toolCall.argumentsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            let target = ActionDescriptor.target(from: toolCall)
            guard !target.isEmpty else { return false }
            let url = URL(fileURLWithPath: (target as NSString).expandingTildeInPath)
            return PluginSecurity.isProtectedPath(targetURL: url, pluginsDir: pluginsDir)
        }

        // Path-only keys: `to` is intentionally excluded because `email.send`
        // carries recipients under `to` as `[String]`, not a filesystem path;
        // scanning it would risk false protected-path denials on addresses.
        let candidateKeys = ["path", "file_path", "filePath", "target", "destination", "directory", "dir"]
        for key in candidateKeys {
            if let str = object[key] as? String, !str.isEmpty {
                let url = URL(fileURLWithPath: (str as NSString).expandingTildeInPath)
                if PluginSecurity.isProtectedPath(targetURL: url, pluginsDir: pluginsDir) {
                    return true
                }
            }
        }
        return false
    }

    /// Decides whether a tool call may run.
    ///
    /// Expired grants are pruned on every check. Denied descriptors
    /// return `denied` first; `readOnly`/`trusted` tools are otherwise
    /// `allowed`; `requiresApproval` tools return `allowed` when a
    /// live grant covers the call's descriptor (exact target match or
    /// a tool-wide grant with an empty target), else
    /// `requiresApproval` with a request offering every
    /// ``TrustDuration`` tier.
    /// - Parameters:
    ///   - toolCall: Invocation arguments.
    ///   - tool: The tool being invoked.
    /// - Returns: The permission verdict.
    public func checkPermission(toolCall: ToolInput, tool: any Tool) -> PermissionDecision {
        pruneExpired()
        let descriptor = ActionDescriptor.descriptor(for: toolCall, tool: tool)
        if let reason = denials[descriptor] ?? denials[ActionDescriptor(toolName: tool.name)] {
            return .denied(reason)
        }

        // Guard against automated agent modifications to protected engine paths
        if tool.permissionLevel != .readOnly, isProtectedTarget(toolCall: toolCall) {
            return .denied("Access denied: direct modification of protected Rune Weaver engine files or installed plugins is prohibited.")
        }

        switch tool.permissionLevel {
        case .readOnly:
            return .allowed
        case .trusted:
            return .allowed
        case .requiresApproval:
            if covers(descriptor) {
                return .allowed
            }
            let request = PermissionRequest(
                toolName: tool.name,
                description: tool.description,
                input: toolCall,
                suggestedDurations: TrustDuration.allCases
            )
            return .requiresApproval(request)
        }
    }

    /// Records trust for an action.
    ///
    /// `thisTime` approvals are one-shot and intentionally not stored.
    /// Any existing grant for the same descriptor is replaced, then
    /// the full grant set is awaited to storage so rapid
    /// grant and revoke sequences commit in actor order instead of racing.
    /// - Parameters:
    ///   - descriptor: The action to trust.
    ///   - duration: How long the trust lasts.
    public func grantTrust(for descriptor: ActionDescriptor, duration: TrustDuration) async {
        guard duration != .thisTime else { return }
        pruneExpired()
        grants.removeAll { $0.actionDescriptor == descriptor }
        let now = Date()
        let grant = TrustGrant(
            actionDescriptor: descriptor,
            grantedAt: now,
            expiresAt: duration.timeInterval.map { now.addingTimeInterval($0) },
            duration: duration
        )
        grants.append(grant)
        denials.removeValue(forKey: descriptor)
        await persist()
    }

    /// Removes trust for an action.
    ///
    /// Drops every grant matching the descriptor exactly, plus
    /// tool-wide grants when `descriptor.target` is empty, then awaits
    /// the pruned set to storage in actor order. Missing grants are a no-op.
    /// - Parameter descriptor: The action to distrust.
    public func revokeTrust(for descriptor: ActionDescriptor) async {
        if descriptor.target.isEmpty {
            grants.removeAll { $0.actionDescriptor.toolName == descriptor.toolName }
        } else {
            grants.removeAll { $0.actionDescriptor == descriptor }
        }
        await persist()
    }

    /// Explicitly refuses an action with a reason.
    ///
    /// Denied descriptors make ``checkPermission(toolCall:tool:)``
    /// return `denied` until ``removeDenial(for:)`` or a fresh
    /// ``grantTrust(for:duration:)`` clears them.
    /// - Parameters:
    ///   - descriptor: The action to refuse.
    ///   - reason: Human-readable reason surfaced to the LLM.
    public func deny(_ descriptor: ActionDescriptor, reason: String) {
        denials[descriptor] = reason
    }

    /// Clears an explicit refusal.
    /// - Parameter descriptor: The action to unblock.
    public func removeDenial(for descriptor: ActionDescriptor) {
        denials.removeValue(forKey: descriptor)
    }

    /// Returns the currently valid grants, pruning expired ones first.
    /// - Returns: Live grants.
    public func activeGrants() -> [TrustGrant] {
        pruneExpired()
        return grants
    }

    /// Whether a live grant covers the descriptor.
    /// - Parameter descriptor: The action to check.
    /// - Returns: True when a valid grant matches.
    public func isTrusted(_ descriptor: ActionDescriptor) -> Bool {
        pruneExpired()
        return covers(descriptor)
    }

    // MARK: - Private

    /// Whether any live grant covers the descriptor, either by exact
    /// target match or by a tool-wide grant with an empty target.
    private func covers(_ descriptor: ActionDescriptor) -> Bool {
        grants.contains {
            $0.isValid()
                && $0.actionDescriptor.toolName == descriptor.toolName
                && ($0.actionDescriptor.target.isEmpty || $0.actionDescriptor.target == descriptor.target)
        }
    }

    /// Drops expired grants from memory only, without touching storage.
    ///
    /// Synchronous checks prune here so they never fire unordered
    /// background saves; durability for expiries comes from the awaited
    /// paths (`grantTrust`, `revokeTrust`, `pruneExpiredAndPersist`)
    /// and startup `bootstrap`, keeping disk order tied to actor order.
    private func pruneExpired() {
        let now = Date()
        grants.removeAll { $0.isExpired(at: now) }
    }

    /// Mirrors the current grants to the store in actor order.
    ///
    /// Awaited by every mutating path so the actor serializes saves;
    /// errors stay best-effort so permission checks never fail on
    /// persistence issues.
    private func persist() async {
        guard let store else { return }
        let snapshot = grants
        do {
            try await store.save(snapshot)
        } catch {
            RuneWeaverLog.stores.error("PermissionGate: Failed to persist trust grants: \(error)")
        }
    }
}

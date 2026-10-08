// Rune Weaver Server — Durable auth-session persistence for owner auth.
//
// Browser sessions are ephemeral bearer credentials with an idle window, so the
// engine must remember which sessions survive a restart without ever writing a
// raw session token to disk. This file owns that boundary: the persisted JSON
// schema plus the restricted-file store that reads and writes it under a `0700`
// `~/.runeweaver` directory and a `0600` file. Only SHA-256 digests of session
// tokens are represented here, and every refused or undecodable document is
// surfaced as a typed error instead of a silent empty state, so the session
// owner (`ServerAuth`) stays the single place that decides liveness, eviction,
// renewal, and logging.

import Foundation
import RuneWeaverCore

/// One browser session as it is persisted to disk.
///
/// The ``digest`` identifies the session token without being it: a restart
/// verifies a presented cookie by digest, so the raw token never has to exist
/// outside process memory. `generation` binds the entry to the owner-token
/// generation it was minted under so a rotation can drop stale entries;
/// `lastSeenAt` drives the sliding idle window and the least-recently-seen
/// eviction order, while `cookieRefreshedAt` throttles renewal so an active
/// browser is not re-issued its cookie on every request.
public struct PersistedAuthSession: Codable, Equatable, Sendable {
    /// Lowercase SHA-256 hex digest of the session token.
    public let digest: String
    /// Owner-token generation the session was minted under.
    public let generation: Int
    /// When the session was created.
    public let createdAt: Date
    /// Last request the session authenticated.
    public let lastSeenAt: Date
    /// Last time the session cookie was re-issued.
    public let cookieRefreshedAt: Date

    /// Creates a persisted session entry.
    /// - Parameters:
    ///   - digest: Lowercase SHA-256 hex digest of the session token.
    ///   - generation: Owner-token generation the session was minted under.
    ///   - createdAt: When the session was created.
    ///   - lastSeenAt: Last request the session authenticated.
    ///   - cookieRefreshedAt: Last time the session cookie was re-issued.
    public init(
        digest: String,
        generation: Int,
        createdAt: Date,
        lastSeenAt: Date,
        cookieRefreshedAt: Date
    ) {
        self.digest = digest
        self.generation = generation
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.cookieRefreshedAt = cookieRefreshedAt
    }
}

/// The complete durable auth-session document.
///
/// ``version`` is validated on load so a future schema change is refused as
/// unreadable rather than misread under today's semantics. `generation` is the
/// owner-token generation the whole set was minted under and is resumed across
/// restarts so sessions minted before the last rotation stay dead. `sessions`
/// is empty after a rotation and never holds raw tokens.
public struct PersistedAuthSessions: Codable, Equatable, Sendable {
    /// Schema version this build writes and accepts.
    public static let currentVersion = 1

    /// Schema version of the serialized document.
    public let version: Int
    /// Owner-token generation the persisted sessions were minted under.
    public let generation: Int
    /// Persisted session entries, digests only.
    public let sessions: [PersistedAuthSession]

    /// Creates a persisted session document.
    /// - Parameters:
    ///   - version: Schema version, defaulting to ``currentVersion``.
    ///   - generation: Owner-token generation the sessions were minted under.
    ///   - sessions: Persisted session entries, digests only.
    public init(
        version: Int = PersistedAuthSessions.currentVersion,
        generation: Int,
        sessions: [PersistedAuthSession]
    ) {
        self.version = version
        self.generation = generation
        self.sessions = sessions
    }
}

/// Reads and writes the durable auth-session document at a restricted path.
///
/// The store is intentionally policy-free: it enforces only the file boundary
/// (owner-only mode, atomic replace) and fails closed on any refused or
/// unrecognized document, leaving liveness, eviction, and logging to
/// ``ServerAuth``. A nil ``fileURL`` disables the store entirely, so a caller
/// can run with no session persistence and no disk IO at all.
public struct ServerAuthSessionStore: Sendable {
    /// File name inside the shared `~/.runeweaver` state directory.
    public static let fileName = "auth-sessions.json"

    /// Conventional session-store path, following the same `~/.runeweaver`
    /// state directory as `AuthConfig.defaultTokenFile` so credentials and
    /// session metadata live under one owner-only root.
    public static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".runeweaver/\(fileName)")
    }

    /// Restricted session file, or nil when persistence is disabled.
    public let fileURL: URL?

    /// Creates a session store.
    /// - Parameter fileURL: Restricted session file, or nil to disable disk IO.
    public init(fileURL: URL? = ServerAuthSessionStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    /// Loads the persisted session document.
    ///
    /// A missing file and a disabled store both read as "no persisted state"
    /// (nil) rather than an error, because a first boot and an intentionally
    /// session-less process are legitimate. A refused or undecodable document
    /// throws instead of degrading to nil, so the caller can warn and start
    /// empty while still distinguishing "nothing persisted" from "persisted
    /// state was dropped".
    /// - Returns: The persisted document, or nil when absent or disabled.
    /// - Throws: ``ServerAuthError/insecureSessionsFile(path:)`` for a loose
    ///   file, or ``ServerAuthError/sessionStoreUnreadable(path:)`` for a
    ///   document that cannot be decoded or uses an unknown schema version.
    public func load() throws -> PersistedAuthSessions? {
        guard let fileURL else { return nil }
        guard let data = try ServerAuthTokenStore.readRestrictedData(
            fileURL,
            insecureFileError: ServerAuthError.insecureSessionsFile
        ) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let state: PersistedAuthSessions
        do {
            state = try decoder.decode(PersistedAuthSessions.self, from: data)
        } catch {
            RuneWeaverLog.server.error("ServerAuthSessionStore: failed to decode session store at \(fileURL.path): \(error.localizedDescription)")
            throw ServerAuthError.sessionStoreUnreadable(path: fileURL.path)
        }
        guard state.version == PersistedAuthSessions.currentVersion else {
            RuneWeaverLog.server.error("ServerAuthSessionStore: unsupported version \(state.version) at \(fileURL.path)")
            throw ServerAuthError.sessionStoreUnreadable(path: fileURL.path)
        }
        return state
    }

    /// Persists the session document through the restricted-file writer.
    ///
    /// The schema is written as sorted JSON with whole-second dates so the
    /// bytes are deterministic and a reload resumes exactly the state that was
    /// written. A nil ``fileURL`` makes this a no-op, so a disabled store never
    /// touches disk.
    /// - Parameter state: Document to persist.
    /// - Throws: ``ServerAuthError`` when the restricted write fails.
    public func save(_ state: PersistedAuthSessions) throws {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        try ServerAuthTokenStore.writeRestrictedFile(data, to: fileURL)
    }
}

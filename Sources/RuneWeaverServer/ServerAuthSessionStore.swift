// Rune Weaver Server — Durable auth-session persistence for owner auth.

import Foundation
import RuneWeaverCore

/// One browser session as it is persisted to disk. The ``digest`` identifies the session token
/// without being it: a restart verifies a presented cookie by digest, so the raw token never has to
/// exist outside process memory.
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

    /// Creates a persisted session entry. digest: Lowercase SHA-256 hex digest of
    /// the session token.
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

/// The complete durable auth-session document. `sessions` is empty after a rotation and never holds
/// raw tokens.
public struct PersistedAuthSessions: Codable, Equatable, Sendable {
    /// Schema version this build writes and accepts.
    public static let currentVersion = 1

    /// Schema version of the serialized document.
    public let version: Int
    /// Owner-token generation the persisted sessions were minted under.
    public let generation: Int
    /// Persisted session entries, digests only.
    public let sessions: [PersistedAuthSession]

    /// Creates a persisted session document. version: Schema version, defaulting to
    /// ``currentVersion``.
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
    public func load() throws -> PersistedAuthSessions? {
        guard let fileURL, let data = try ServerAuthTokenStore.readRestrictedData(
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

    /// Persists the session document through the restricted-file writer. A nil ``fileURL`` makes
    /// this a no-op, so a disabled store never touches disk.
    public func save(_ state: PersistedAuthSessions) throws {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        try ServerAuthTokenStore.writeRestrictedFile(data, to: fileURL)
    }
}

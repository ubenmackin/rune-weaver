// Rune Weaver Server — Single-owner bearer authentication for the engine surface.

import CryptoKit
import Foundation
import RuneWeaverCore
import Vapor

#if canImport(Security)
    import Security
#endif

/// Errors raised while resolving, verifying, or rotating the owner token.
public enum ServerAuthError: Error, LocalizedError, Sendable, Equatable {
    /// The bind policy and the resolved credential disagree, so serving would
    /// either expose an unauthenticated surface or silently ignore a token.
    case misconfigured(reason: String)
    /// The system CSPRNG failed to produce random bytes.
    case tokenGenerationFailed
    /// A rotated token could not be persisted to any configured source.
    case tokenStorageFailed(reason: String)
    /// The configured token file is readable by group or other accounts, or its
    /// permission mode could not be verified.
    case insecureTokenFile(path: String)
    /// Rotation was refused because a live environment override outranks every
    /// persistence target and would shadow the replacement on the next boot.
    case environmentOverrideActive(name: String)
    /// The configured auth-session file is readable by group or other accounts,
    /// or its permission mode could not be verified.
    case insecureSessionsFile(path: String)
    /// The persisted auth-session file could not be decoded or carries an
    /// unsupported schema version.
    case sessionStoreUnreadable(path: String)

    public var errorDescription: String? {
        switch self {
        case let .misconfigured(reason):
            "Owner auth misconfiguration: \(reason)"
        case .tokenGenerationFailed:
            "Failed to generate a secure owner token."
        case let .tokenStorageFailed(reason):
            "Failed to persist the rotated owner token: \(reason)"
        case let .insecureTokenFile(path):
            "Refusing to read owner token file \(path): permissions must be 0600."
        case let .environmentOverrideActive(name):
            "Cannot rotate the owner token while environment override \(name) is set; "
                + "update or unset it so the replacement can take effect."
        case let .insecureSessionsFile(path):
            "Refusing to read auth session file \(path): permissions must be 0600."
        case let .sessionStoreUnreadable(path):
            "Failed to read auth session file \(path): it is corrupt or uses an unsupported version."
        }
    }
}

/// Credential-free origin of a resolved owner token.
public enum ServerAuthTokenSource: Sendable, Equatable {
    /// The environment variable named by `auth.token_env`.
    case environment(name: String)
    /// The shared Keychain account ``AuthConfig/defaultTokenKey``.
    case keychain
    /// The restricted `0600` file named by `auth.token_file`.
    case file(path: String)

    /// Human-readable, credential-free label for operator output.
    public var label: String {
        switch self {
        case let .environment(name): "environment (\(name))"
        case .keychain: "Keychain"
        case let .file(path): "file (\(path))"
        }
    }
}

/// One resolved owner token plus the source it came from. The token stays in memory only: callers
/// must render only its fingerprint and source label, never the credential itself.
public struct ResolvedServerAuthToken: Sendable {
    /// Token value, used to verify or fingerprint but never rendered as-is.
    public let token: String
    /// Credential-free origin of ``token``.
    public let source: ServerAuthTokenSource

    /// Creates a resolved token. token: Token value.
    public init(token: String, source: ServerAuthTokenSource) {
        self.token = token
        self.source = source
    }
}

/// Resolves and persists the owner bearer token across the Keychain, the headless environment
/// override, and the restricted-permission file fallback.
public struct ServerAuthTokenStore: Sendable {
    /// Keychain-backed secret access, reused so the auth surface and providers
    /// cannot drift on service namespace or environment precedence.
    private let secrets: SecretsManager
    /// Explicit environment variable consulted before the shared Keychain lookup.
    private let tokenEnv: String?
    /// Resolved `0600` file fallback, or nil when the config disables it.
    private let tokenFileURL: URL?

    /// Creates a token store from the `[auth]` config section. authConfig: Declared
    /// token sources.
    public init(
        authConfig: AuthConfig,
        service: String = SecretsManager.defaultService,
        inMemory: Bool = false
    ) {
        self.secrets = SecretsManager(service: service, inMemory: inMemory)
        let trimmedEnv = authConfig.tokenEnv?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.tokenEnv = (trimmedEnv?.isEmpty ?? true) ? nil : trimmedEnv
        if let file = authConfig.tokenFile?.trimmingCharacters(in: .whitespacesAndNewlines), !file.isEmpty {
            self.tokenFileURL = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
        } else {
            self.tokenFileURL = nil
        }
    }

    /// Resolves the current token from the first configured source. A group/other-readable file
    /// fails closed rather than falling through to an unprotected value.
    public func resolve() async throws -> ResolvedServerAuthToken? {
        if let tokenEnv, let value = Self.normalizedToken(Self.environmentValue(tokenEnv)) {
            return ResolvedServerAuthToken(token: value, source: .environment(name: tokenEnv))
        }
        if let stored = try await secrets.retrieve(key: AuthConfig.defaultTokenKey),
           let value = Self.normalizedToken(stored)
        {
            let fromEnvironment = Self.normalizedToken(Self.environmentValue(AuthConfig.defaultTokenKey)) != nil
            let source: ServerAuthTokenSource = fromEnvironment
                ? .environment(name: AuthConfig.defaultTokenKey)
                : .keychain
            return ResolvedServerAuthToken(token: value, source: source)
        }
        if let tokenFileURL, let value = try Self.readRestrictedFile(tokenFileURL) {
            return ResolvedServerAuthToken(token: value, source: .file(path: tokenFileURL.path))
        }
        return nil
    }

    /// Persists a rotated token to every configured source. The Keychain is always written; the
    /// file fallback is written only when `token_file` names one.
    func persist(_ token: String) async throws {
        var persisted = false
        var keychainPersisted = false
        var failures: [String] = []
        do {
            try await secrets.store(key: AuthConfig.defaultTokenKey, secret: token)
            keychainPersisted = true
            persisted = true
        } catch {
            failures.append("Keychain: \(error.localizedDescription)")
        }
        if let tokenFileURL {
            do {
                try Self.writeRestrictedFile(Data(token.utf8), to: tokenFileURL)
                persisted = true
            } catch {
                failures.append("file: \(error.localizedDescription)")
            }
        }
        guard persisted else {
            throw ServerAuthError.tokenStorageFailed(reason: failures.joined(separator: "; "))
        }
        guard keychainPersisted || environmentOverrideIsLive else {
            // The Keychain is the effective source and did not persist, so a
            // later resolution could shadow the new file value with the retired
            // credential. Refuse rather than report a rotation that cannot hold.
            throw ServerAuthError.tokenStorageFailed(reason: failures.joined(separator: "; "))
        }
    }

    /// Whether a live environment variable outranks the Keychain on the next boot.
    private var environmentOverrideIsLive: Bool {
        activeEnvironmentOverride() != nil
    }

    /// Names the environment variable whose live value outranks persisted storage, or nil when no
    /// override is in effect.
    func activeEnvironmentOverride() -> String? {
        if let tokenEnv, Self.normalizedToken(Self.environmentValue(tokenEnv)) != nil {
            return tokenEnv
        }
        if Self.normalizedToken(Self.environmentValue(AuthConfig.defaultTokenKey)) != nil {
            return AuthConfig.defaultTokenKey
        }
        return nil
    }

    /// Normalizes a resolved value identically for every source.
    private static func normalizedToken(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    /// Reads bytes from a restricted file, refusing one that other local accounts could read or
    /// whose mode cannot be verified.
    static func readRestrictedData(
        _ fileURL: URL,
        insecureFileError: (String) -> ServerAuthError = ServerAuthError.insecureTokenFile,
        fileManager: FileManager = .default
    ) throws -> Data? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
              let permissions = attributes[.posixPermissions] as? NSNumber
        else {
            // Fail closed: without a verified mode there is no way to prove the
            // bytes are owner-only, so they must not be read at all.
            throw insecureFileError(fileURL.path)
        }
        if permissions.intValue & 0o077 != 0 {
            throw insecureFileError(fileURL.path)
        }
        do {
            return try Data(contentsOf: fileURL)
        } catch {
            RuneWeaverLog.server.error("ServerAuth: failed to read restricted data at \(fileURL.path): \(error.localizedDescription)")
            throw error
        }
    }

    /// Reads a restricted token file and normalizes its text value.
    static func readRestrictedFile(_ fileURL: URL, fileManager: FileManager = .default) throws -> String? {
        guard let data = try readRestrictedData(fileURL, fileManager: fileManager),
              let value = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return Self.normalizedToken(value)
    }

    /// Writes restricted bytes to a `0600` file inside a `0700` directory using
    /// a same-directory temp plus an atomic replace, so a crash never leaves a
    /// half-written credential and no window exposes it under a looser mode.
    static func writeRestrictedFile(_ data: Data, to fileURL: URL) throws {
        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // Re-assert the directory mode: a directory created by an older build or
        // a restore could be wider, and restricted bytes must never sit in one.
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let tempURL = directory.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        guard fileManager.createFile(
            atPath: tempURL.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw ServerAuthError.tokenStorageFailed(reason: "could not create temporary token file")
        }
        do {
            if fileManager.fileExists(atPath: fileURL.path) {
                _ = try fileManager.replaceItemAt(fileURL, withItemAt: tempURL)
            } else {
                try fileManager.moveItem(at: tempURL, to: fileURL)
            }
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw error
        }
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    /// Reads a live environment variable, matching ``SecretsManager``'s approach
    /// so a value exported after launch is still honored.
    private static func environmentValue(_ key: String) -> String? {
        key.withCString { cKey in
            guard let cValue = getenv(cKey) else { return nil }
            return String(validatingCString: cValue)
        }
    }
}

/// How a presented credential authenticated, captured atomically with the verification itself.
public struct ServerAuthVerifiedPresentation: Equatable, Sendable {
    /// Credential class that matched.
    public enum Kind: Sendable, Equatable {
        /// The live owner bearer token.
        case ownerToken
        /// An active browser session minted under the live generation.
        case browserSession
    }

    /// Token generation the credential verified under.
    public let generation: Int
    /// Which credential class matched.
    public let kind: Kind
    /// Whether the browser session cookie is due to be re-issued. Always false for
    /// ``Kind/ownerToken``: the owner token never rides a cookie, so an owner verification must not
    /// attach one.
    public let shouldRefreshSessionCookie: Bool

    /// Creates a verified presentation. generation: Token generation the credential
    /// verified under.
    public init(generation: Int, kind: Kind, shouldRefreshSessionCookie: Bool) {
        self.generation = generation
        self.kind = kind
        self.shouldRefreshSessionCookie = shouldRefreshSessionCookie
    }
}

/// One-time response carrying the freshly rotated owner token.
public struct ServerAuthRotateResponse: Content, Sendable {
    /// The new bearer token.
    public let token: String

    /// Creates a rotation response.
    /// - Parameter token: New bearer token.
    public init(token: String) {
        self.token = token
    }
}

/// Verifies and rotates the single owner bearer token.
public actor ServerAuth {
    /// Failed attempts from one non-loopback identity before throttling.
    public static let maxFailures = 5
    /// Failed attempts from a loopback identity before throttling (higher ceiling to prevent owner lockout while bounding brute-force).
    public static let maxLoopbackFailures = 25
    /// Window over which failures accumulate before the bucket resets.
    public static let failureWindow: TimeInterval = 60
    /// Cooldown advertised through `Retry-After` once the bucket trips.
    public static let retryAfterSeconds = 30
    /// Idle window after which a session with no requests is dead.
    public static let sessionIdleTimeoutSeconds: TimeInterval = 86400
    /// Minimum interval between re-issuing one browser's session cookie.
    public static let sessionCookieRenewalIntervalSeconds: TimeInterval = 300
    /// Minimum interval between touch-class session persists.
    static let sessionPersistenceCoalesceSeconds: TimeInterval = 60
    /// Upper bound on tracked identities so random clients cannot grow memory without bound.
    private static let maxTrackedIdentities = 1024

    /// Live token; compared in constant time and replaced only by `rotate`.
    private var token: String
    /// Monotonic generation advanced by each rotation.
    private var generation = 0
    /// Persistence seam for rotations.
    private let store: ServerAuthTokenStore
    /// Per-identity failure state.
    private var failures: [String: FailureBucket] = [:]
    /// Ephemeral browser sessions keyed by SHA-256 hex digest of the session token.
    private var sessions: [String: SessionEntry] = [:]
    /// Upper bound on active browser sessions to prevent unbounded memory growth.
    private static let maxActiveSessions = 100
    /// Durable session sink, or nil for an in-memory-only verifier that never touches disk.
    private let sessionStore: ServerAuthSessionStore?
    /// Injectable clock so sliding expiry, cookie renewal, and coalescing are deterministic.
    private let now: @Sendable () -> Date
    /// Whether in-memory session state differs from what the persisted file holds.
    private var sessionsDirty = false
    /// Last persistence attempt, throttling touch-class writes to the coalesce interval.
    private var lastPersistedAt: Date?

    /// One active browser session, keyed by the digest of its token. The digest key means the table
    /// itself never carries a credential.
    private struct SessionEntry: Sendable {
        let generation: Int
        let createdAt: Date
        var lastSeenAt: Date
        var cookieRefreshedAt: Date
    }

    /// Accumulated failures for one identity.
    private struct FailureBucket: Sendable {
        /// Failures observed inside the current window.
        var count: Int
        /// Start of the current window, reset once it ages out.
        var windowStart: Date
        /// Moment throttling lifts, when the bucket has tripped.
        var blockedUntil: Date?
    }

    /// Creates a verifier with a known token. Prefer ``resolve(authConfig:service:inMemory:)`` at
    /// boot so the token is loaded from the configured sources instead of hard-coded.
    public init(
        initialToken: String,
        store: ServerAuthTokenStore,
        sessionStore: ServerAuthSessionStore? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.token = initialToken
        self.store = store
        self.sessionStore = sessionStore
        self.now = now
        guard let sessionStore else { return }
        do {
            guard let persisted = try sessionStore.load() else { return }
            let current = now()
            var restored: [String: SessionEntry] = [:]
            restored.reserveCapacity(persisted.sessions.count)
            var dropped = false
            for persistedSession in persisted.sessions {
                let entry = SessionEntry(
                    generation: persistedSession.generation,
                    createdAt: persistedSession.createdAt,
                    lastSeenAt: persistedSession.lastSeenAt,
                    cookieRefreshedAt: persistedSession.cookieRefreshedAt
                )
                guard persistedSession.generation == persisted.generation,
                      !Self.isExpired(entry, at: current)
                else {
                    dropped = true
                    continue
                }
                // A hand-edited file can repeat a digest; a later entry replaces
                // the earlier one instead of trapping in a unique-keys initializer.
                if restored.updateValue(entry, forKey: persistedSession.digest) != nil {
                    dropped = true
                }
            }
            if Self.evictOverflowSessions(&restored) {
                dropped = true
            }
            self.generation = persisted.generation
            self.sessions = restored
            if dropped {
                self.sessionsDirty = true
            }
        } catch {
            RuneWeaverLog.server.warning(
                "Failed to load persisted owner auth sessions; starting empty: \(error.localizedDescription)"
            )
        }
    }

    /// Resolves a boot token from the configured sources. authConfig: Declared
    /// token sources.
    public static func resolve(
        authConfig: AuthConfig,
        service: String = SecretsManager.defaultService,
        inMemory: Bool = false
    ) async throws -> ServerAuth? {
        let store = ServerAuthTokenStore(authConfig: authConfig, service: service, inMemory: inMemory)
        guard let loaded = try await store.resolve()?.token else {
            return nil
        }
        let trimmed = loaded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        return ServerAuth(
            initialToken: trimmed,
            store: store,
            sessionStore: inMemory ? nil : ServerAuthSessionStore()
        )
    }

    /// Mints a fresh ephemeral session token for browser dashboard access. Only the SHA-256 digest
    /// of the token is stored, so neither the session table nor the persisted document can leak a
    /// credential.
    public func createSession() throws -> String {
        pruneExpiredSessions()
        let sessionToken = try Self.generateToken()
        let current = now()
        sessions[Self.sessionDigestHex(sessionToken)] = SessionEntry(
            generation: generation,
            createdAt: current,
            lastSeenAt: current,
            cookieRefreshedAt: current
        )
        // Insert-then-evict keeps "at most the cap" as a post-condition even
        // when the table was already full before the mint.
        Self.evictOverflowSessions(&sessions)
        markDirty(structural: true)
        return sessionToken
    }

    /// Revokes an ephemeral browser session on logout. The removal is structural, so the persisted
    /// set is rewritten immediately: a restart must not resurrect a session the owner just logged
    /// out.
    public func revokeSession(_ sessionID: String) {
        sessions.removeValue(forKey: Self.sessionDigestHex(sessionID))
        markDirty(structural: true)
    }

    /// Flushes all active browser sessions (e.g. during token rotation).
    public func revokeAllSessions() {
        sessions.removeAll(keepingCapacity: false)
        markDirty(structural: true)
    }

    /// Whether an ephemeral session identifier is currently active. Applies the same generation and
    /// idle-window checks as ``verify(_:)``, so an expired or rotated session never reads as active.
    public func hasActiveSession(_ sessionID: String) -> Bool {
        guard let entry = sessions[Self.sessionDigestHex(sessionID)] else { return false }
        return entry.generation == generation && !Self.isExpired(entry, at: now())
    }

    /// Verifies a presented credential and captures how it authenticated, atomically.
    public func verifyAndCaptureGeneration(_ presented: String) -> ServerAuthVerifiedPresentation? {
        guard !presented.isEmpty else { return nil }
        let digest = Self.sessionDigestHex(presented)
        if let entry = sessions[digest] {
            let current = now()
            guard entry.generation == self.generation, !Self.isExpired(entry, at: current) else {
                sessions.removeValue(forKey: digest)
                markDirty(structural: true)
                return nil
            }
            var refreshed = entry
            refreshed.lastSeenAt = current
            var shouldRefreshCookie = false
            if current.timeIntervalSince(entry.cookieRefreshedAt) >= Self.sessionCookieRenewalIntervalSeconds {
                refreshed.cookieRefreshedAt = current
                shouldRefreshCookie = true
            }
            sessions[digest] = refreshed
            markDirty(structural: false)
            return ServerAuthVerifiedPresentation(
                generation: entry.generation,
                kind: .browserSession,
                shouldRefreshSessionCookie: shouldRefreshCookie
            )
        }
        guard Self.constantTimeEquals(presented, token) else { return nil }
        return ServerAuthVerifiedPresentation(
            generation: generation,
            kind: .ownerToken,
            shouldRefreshSessionCookie: false
        )
    }

    /// Verifies a presented credential in constant time.
    public func verify(_ presented: String) -> Bool {
        verifyAndCaptureGeneration(presented) != nil
    }

    /// Verifies a presented value against the live owner bearer token only, excluding ephemeral
    /// browser sessions.
    public func verifyOwnerToken(_ presented: String) -> Bool {
        guard !presented.isEmpty else { return false }
        return Self.constantTimeEquals(presented, token)
    }

    /// Generation a request authenticated under.
    /// - Returns: Current generation, advanced by each rotation.
    public func currentGeneration() -> Int {
        generation
    }

    /// Whether a socket's upgrade generation still matches the live token.
    public func isCurrentGeneration(_ generation: Int) -> Bool {
        generation == self.generation
    }

    /// Rotates the owner token, persisting the new value before it goes live. Persistence happens
    /// first so a storage failure leaves the current token valid instead of stranding the owner with
    /// a token that was never saved.
    public func rotate() async throws -> String {
        if let overrideName = store.activeEnvironmentOverride() {
            throw ServerAuthError.environmentOverrideActive(name: overrideName)
        }
        let newToken = try Self.generateToken()
        try await store.persist(newToken)
        let oldFingerprint = Self.fingerprint(token)
        let newFingerprint = Self.fingerprint(newToken)
        token = newToken
        generation += 1
        failures.removeAll()
        revokeAllSessions()
        // Fingerprints only: the audit trail must never carry a credential.
        RuneWeaverLog.server.notice(
            "Owner bearer token rotated (old \(oldFingerprint), new \(newFingerprint))."
        )
        return newToken
    }

    /// Records one failed attempt and reports the current throttle interval.
    public func recordFailure(for identity: String, isLoopback: Bool) -> Int? {
        let maxLimit = isLoopback ? Self.maxLoopbackFailures : Self.maxFailures
        let now = Date()
        var bucket = failures[identity] ?? FailureBucket(count: 0, windowStart: now, blockedUntil: nil)
        if let remaining = blockedRemaining(for: identity, now: now) {
            return remaining
        }
        if now.timeIntervalSince(bucket.windowStart) > Self.failureWindow {
            bucket = FailureBucket(count: 0, windowStart: now, blockedUntil: nil)
        }
        bucket.count += 1
        if bucket.count >= maxLimit {
            bucket.blockedUntil = now.addingTimeInterval(TimeInterval(Self.retryAfterSeconds))
            failures[identity] = bucket
            pruneFailures(now: now)
            RuneWeaverLog.server.warning(
                "Owner auth throttled \(identity) after \(bucket.count) failed attempts."
            )
            return Self.retryAfterSeconds
        }
        failures[identity] = bucket
        pruneFailures(now: now)
        return nil
    }

    /// Clears the failure bucket after a successful authentication.
    /// - Parameter identity: Client address whose bucket is reset.
    public func clearFailures(for identity: String) {
        failures.removeValue(forKey: identity)
    }

    /// Records one failed attempt against both the derived client bucket and the direct-peer
    /// bucket.
    public func recordFailure(for identity: String, isLoopback: Bool, peerIdentity: String, peerIsLoopback: Bool) -> Int? {
        if identity == peerIdentity {
            return recordFailure(for: identity, isLoopback: isLoopback)
        }
        let now = Date()
        if let remaining = blockedRemaining(for: peerIdentity, now: now) ?? blockedRemaining(for: identity, now: now) {
            return remaining
        }
        return recordFailure(for: peerIdentity, isLoopback: peerIsLoopback) ?? recordFailure(for: identity, isLoopback: isLoopback)
    }

    /// Remaining cooldown for an already-tripped bucket, without incrementing it.
    private func blockedRemaining(for identity: String, now: Date) -> Int? {
        guard let blockedUntil = failures[identity]?.blockedUntil, blockedUntil > now else { return nil }
        return Self.secondsRoundedUp(blockedUntil.timeIntervalSince(now))
    }

    /// Drops aged-out buckets once the table grows, then evicts oldest windows
    /// so random identifiers cannot grow memory without bound.
    private func pruneFailures(now: Date) {
        guard failures.count > Self.maxTrackedIdentities else { return }
        for (id, bucket) in Array(failures) {
            let blocked = bucket.blockedUntil.map { $0 > now } ?? false
            if !blocked, now.timeIntervalSince(bucket.windowStart) > Self.failureWindow {
                failures.removeValue(forKey: id)
            }
        }
        while failures.count > Self.maxTrackedIdentities, let oldest = failures.min(by: { $0.value.windowStart < $1.value.windowStart })?.key {
            failures.removeValue(forKey: oldest)
        }
    }

    /// Rounds a positive interval up to whole seconds for `Retry-After`.
    private static func secondsRoundedUp(_ interval: TimeInterval) -> Int {
        max(1, Int(interval.rounded(.up)))
    }

    /// Compares fixed-width SHA-256 digests with a branch-free XOR fold.
    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let lhsDigest = SHA256.hash(data: Data(lhs.utf8))
        let rhsDigest = SHA256.hash(data: Data(rhs.utf8))
        var difference: UInt8 = 0
        for (lhsByte, rhsByte) in zip(lhsDigest, rhsDigest) {
            difference |= lhsByte ^ rhsByte
        }
        return difference == 0
    }

    /// Generates a 256-bit URL-safe token from the system CSPRNG.
    private static func generateToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        #if canImport(Security)
            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            guard status == errSecSuccess else {
                throw ServerAuthError.tokenGenerationFailed
            }
        #else
            var generator = SystemRandomNumberGenerator()
            for index in bytes.indices {
                bytes[index] = UInt8.random(in: .min ... .max, using: &generator)
            }
        #endif
        return Data(bytes).runeWeaverBase64URL
    }

    /// Short digest identifying a token without exposing it.
    public static func fingerprint(_ token: String) -> String {
        let digest = SHA256.hash(data: Data(token.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Full digest that keys one session token in memory and on disk.
    private static func sessionDigestHex(_ token: String) -> String {
        let digest = SHA256.hash(data: Data(token.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Whether a session has been idle past the sliding window.
    private static func isExpired(_ entry: SessionEntry, at current: Date) -> Bool {
        current.timeIntervalSince(entry.lastSeenAt) > sessionIdleTimeoutSeconds
    }

    /// Drops expired sessions from memory without a structural write.
    private func pruneExpiredSessions() {
        let current = now()
        let expiredDigests = sessions
            .filter { Self.isExpired($0.value, at: current) }
            .map(\.key)
        guard !expiredDigests.isEmpty else { return }
        for digest in expiredDigests {
            sessions.removeValue(forKey: digest)
        }
        sessionsDirty = true
    }

    /// Evicts least-recently-seen sessions until the table is back within the cap.
    @discardableResult
    private static func evictOverflowSessions(_ sessions: inout [String: SessionEntry]) -> Bool {
        var evicted = false
        while sessions.count > maxActiveSessions {
            guard let victim = sessions.min(by: { lhs, rhs in
                if lhs.value.lastSeenAt != rhs.value.lastSeenAt {
                    return lhs.value.lastSeenAt < rhs.value.lastSeenAt
                }
                if lhs.value.createdAt != rhs.value.createdAt {
                    return lhs.value.createdAt < rhs.value.createdAt
                }
                return lhs.key < rhs.key
            }) else {
                break
            }
            sessions.removeValue(forKey: victim.key)
            evicted = true
        }
        return evicted
    }

    /// Marks session state dirty and persists it when the change class allows.
    private func markDirty(structural: Bool) {
        sessionsDirty = true
        let current = now()
        let touchPersistDue = lastPersistedAt.map {
            current.timeIntervalSince($0) >= Self.sessionPersistenceCoalesceSeconds
        } ?? true
        if structural || touchPersistDue {
            persistNow(at: current)
        }
    }

    /// Writes the current session table and records the attempt either way. A missing store clears
    /// the dirty flag without IO, matching the contract that an in-memory-only verifier never
    /// touches disk.
    private func persistNow(at current: Date) {
        defer { lastPersistedAt = current }
        guard let sessionStore else {
            sessionsDirty = false
            return
        }
        var entries: [PersistedAuthSession] = []
        entries.reserveCapacity(sessions.count)
        for (digest, entry) in sessions {
            entries.append(
                PersistedAuthSession(
                    digest: digest,
                    generation: entry.generation,
                    createdAt: entry.createdAt,
                    lastSeenAt: entry.lastSeenAt,
                    cookieRefreshedAt: entry.cookieRefreshedAt
                )
            )
        }
        entries.sort { $0.digest < $1.digest }
        let state = PersistedAuthSessions(generation: generation, sessions: entries)
        do {
            try sessionStore.save(state)
            sessionsDirty = false
        } catch {
            RuneWeaverLog.server.warning(
                "Failed to persist owner auth sessions; retrying after the coalesce interval: \(error.localizedDescription)"
            )
        }
    }
}

/// Throttle scope for one request, pairing the derived client bucket with the direct-peer bucket.
public struct ServerAuthThrottleIdentities: Sendable, Equatable {
    /// Derived client bucket from `ServerAuthRequest/clientIdentity(for:)`.
    public let identity: String
    /// Whether the derived identity uses the loopback bound.
    public let isLoopback: Bool
    /// Direct socket peer bucket from `ServerAuthRequest/directPeerIdentity(for:)`.
    public let peerIdentity: String
    /// Whether the direct peer uses the loopback bound.
    public let peerIsLoopback: Bool

    /// Creates a throttle scope.
    public init(identity: String, isLoopback: Bool, peerIdentity: String, peerIsLoopback: Bool) {
        self.identity = identity
        self.isLoopback = isLoopback
        self.peerIdentity = peerIdentity
        self.peerIsLoopback = peerIsLoopback
    }
}

/// Request classification shared by the middleware and the WebSocket upgrade guard.
public enum ServerAuthRequest {
    /// Whether a request is a WebSocket upgrade handshake.
    public static func isWebSocketUpgrade(_ request: Request) -> Bool {
        guard request.headers.first(name: .secWebSocketKey) != nil else { return false }
        let connection = request.headers.first(name: .connection)?.lowercased() ?? ""
        let upgrade = request.headers.first(name: .upgrade)?.lowercased() ?? ""
        return connection.contains("upgrade") && upgrade == "websocket"
    }

    /// Cookie name holding the owner session token for browser dashboard access.
    public static let sessionCookieName = "rw_session"

    /// Extracts the presented bearer credential.
    public static func presentedBearer(for request: Request, allowQueryToken: Bool) -> String? {
        if let header = request.headers.bearerAuthorization?.token {
            let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        if let cookie = request.cookies[sessionCookieName]?.string {
            let trimmed = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        guard allowQueryToken,
              let query = request.query[String.self, at: "token"]
        else {
            return nil
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// Generates an HttpOnly session cookie value for the owner token.
    public static func makeSessionCookie(
        token: String,
        isSecure: Bool = false,
        maxAge: Int = Int(ServerAuth.sessionIdleTimeoutSeconds)
    ) -> HTTPCookies.Value {
        HTTPCookies.Value(
            string: token,
            expires: nil,
            maxAge: maxAge,
            domain: nil,
            path: "/",
            isSecure: isSecure,
            isHTTPOnly: true,
            sameSite: .strict
        )
    }

    /// Generates an expired session cookie to clear the session on logout.
    public static func makeExpiredSessionCookie(isSecure: Bool = false) -> HTTPCookies.Value {
        HTTPCookies.Value(
            string: "",
            expires: Date(timeIntervalSince1970: 0),
            maxAge: 0,
            domain: nil,
            path: "/",
            isSecure: isSecure,
            isHTTPOnly: true,
            sameSite: .strict
        )
    }

    /// Determines whether the inbound request was made over HTTPS directly or through a
    /// TLS-terminating reverse proxy.
    public static func isRequestSecure(_ request: Request) -> Bool {
        if request.url.scheme?.lowercased() == "https" {
            return true
        }
        // The header is only as trustworthy as the peer that sent it: a remote
        // peer can forge it, so only a direct loopback proxy may assert TLS.
        guard let peerIP = request.remoteAddress?.ipAddress else {
            // No peer to authenticate — fail closed. In-memory test requests
            // have no socket, so honor the header only when explicitly running
            // under `.testing`, never by treating absence as trust.
            guard request.application.environment == .testing else { return false }
            return forwardedProtoIsHttps(request)
        }
        guard isLoopbackAddress(peerIP) else {
            return false
        }
        return forwardedProtoIsHttps(request)
    }

    /// Whether the `X-Forwarded-Proto` header asserts HTTPS. Only the first entry matters because a
    /// trusted local proxy prepends the client-facing protocol; later entries are downstream hops,
    /// not the edge.
    private static func forwardedProtoIsHttps(_ request: Request) -> Bool {
        guard let forwardedProto = request.headers.first(name: "X-Forwarded-Proto") else {
            return false
        }
        let primary = forwardedProto.split(separator: ",").first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return primary == "https"
    }

    /// Whether a socket peer address is loopback.
    /// - Parameter peerIP: Direct peer address, never `unknown`.
    private static func isLoopbackAddress(_ peerIP: String) -> Bool {
        peerIP == "127.0.0.1" || peerIP == "::1" || peerIP.lowercased() == "localhost"
    }

    /// Stable client identity for failure buckets.
    public static func clientIdentity(for request: Request) -> String {
        let peerIP = request.remoteAddress?.ipAddress
        if let peerIP, isLoopbackAddress(peerIP) {
            if let forwardedFor = request.headers.first(name: "X-Forwarded-For") {
                if let clientIP = forwardedFor.split(separator: ",").first?.trimmingCharacters(in: .whitespacesAndNewlines), !clientIP.isEmpty {
                    return clientIP
                }
            }
            return peerIP
        }
        return peerIP ?? "unknown"
    }

    /// Direct socket peer address, never derived from forwarding headers.
    /// - Parameter request: Inbound request.
    public static func directPeerIdentity(for request: Request) -> String {
        request.remoteAddress?.ipAddress ?? "unknown"
    }

    /// Throttle scope for one request: the derived client bucket plus the direct-peer bucket.
    public static func throttleIdentities(for request: Request) -> ServerAuthThrottleIdentities {
        let identity = clientIdentity(for: request)
        let peerIdentity = directPeerIdentity(for: request)
        return ServerAuthThrottleIdentities(
            identity: identity,
            isLoopback: isLoopback(identity),
            peerIdentity: peerIdentity,
            peerIsLoopback: isLoopback(peerIdentity)
        )
    }

    /// Whether an identity is loopback and therefore uses the loopback bound. `unknown` (no socket
    /// peer, such as in-process or test requests) uses the loopback bound like a local peer rather
    /// than the stricter remote bound.
    public static func isLoopback(_ identity: String) -> Bool {
        identity == "unknown" || isLoopbackAddress(identity)
    }

    /// Whether a path serves public dashboard bytes. Browsers cannot attach an `Authorization`
    /// header to a navigation or a `<script>` fetch, so these bytes must be public or the
    /// authenticated UI can never boot.
    public static func isPublicDashboardPath(
        _ path: String,
        bundle: DashboardBundle,
        fileManager: FileManager = .default
    ) -> Bool {
        // A traversal never resolves to a bundle file, so it must not ride the
        // public branch into any other route.
        guard !path.contains("..") else { return false }
        let normalized = path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        // The SPA entry points are always public, even when no bundle resolves:
        // a navigation must reach the in-bundle owner-token gate.
        if normalized.isEmpty || normalized == "index.html" || normalized == "login" {
            return true
        }
        // Every other public path must be a real bundle artifact. Resolving the
        // path against the actual bundle means a crafted data-route path that
        // merely ends in a static extension no longer qualifies.
        guard isBundleStaticPath(normalized) else { return false }
        return bundle.localFileURL(for: path, fileManager: fileManager) != nil
    }

    /// Whether a normalized path sits in a location the bundle publishes.
    private static func isBundleStaticPath(_ normalizedPath: String) -> Bool {
        if normalizedPath.hasPrefix("assets/") {
            return true
        }
        return isKnownStaticRootFile(normalizedPath)
    }

    /// Whether a root-level path names a static file the bundle ships.
    private static func isKnownStaticRootFile(_ normalizedPath: String) -> Bool {
        guard !normalizedPath.contains("/") else { return false }
        if knownStaticRootFiles.contains(normalizedPath) {
            return true
        }
        // Sized favicons share the `favicon-<size>.png` shape at the root.
        return normalizedPath.hasPrefix("favicon-") && normalizedPath.hasSuffix(".png")
    }

    /// Root-level static file names the bundle publishes beside the SPA.
    private static let knownStaticRootFiles: Set<String> = [
        "favicon.ico", "favicon.svg", "favicon.png",
        "apple-touch-icon.png", "apple-touch-icon-precomposed.png",
        "site.webmanifest", "manifest.webmanifest", "manifest.json",
        "robots.txt"
    ]

    /// Whether a path is the single WebSocket endpoint. The upgrade-only query fallback is
    /// restricted to this path so a spoofed handshake shape on a REST route can never turn a URL
    /// query into a credential.
    public static func isWebSocketPath(_ path: String) -> Bool {
        path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() == ServerPaths.websocket
    }

    /// Whether a path serves the minimal public liveness shape.
    /// - Parameter path: Request path (query excluded).
    /// - Returns: True for the liveness probe.
    public static func isLivenessPath(_ path: String) -> Bool {
        path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() == "health"
    }

    /// Whether a path is the browser session management endpoint (`POST /auth/session`, `DELETE /auth/session`).
    public static func isAuthSessionPath(_ path: String) -> Bool {
        path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() == "\(ServerPaths.auth)/\(ServerPaths.session)"
    }

    /// Removes the `token` query parameter from a request. Called after an upgrade credential is
    /// validated so downstream handlers and logs can never capture it; the rest of the query string
    /// is preserved.
    public static func stripPresentedToken(from request: Request) {
        guard let query = request.url.query, !query.isEmpty else { return }
        let retained = query
            .split(separator: "&", omittingEmptySubsequences: true)
            .filter { component in
                let key = component
                    .split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    .first ?? component
                return key.lowercased() != "token"
            }
        var uri = request.url
        uri.query = retained.isEmpty ? nil : retained.joined(separator: "&")
        request.url = uri
    }
}

/// Request-local marker set once the owner credential is verified.
private struct ServerAuthenticatedKey: StorageKey {
    /// Whether the request passed owner auth.
    typealias Value = Bool
}

/// Request-local generation recorded when the owner credential is verified.
private struct ServerAuthGenerationKey: StorageKey {
    /// Token generation the request authenticated under.
    typealias Value = Int
}

extension Request {
    /// Whether this request already passed owner bearer authentication.
    public var runeWeaverAuthenticated: Bool {
        get { storage[ServerAuthenticatedKey.self] ?? false }
        set { storage[ServerAuthenticatedKey.self] = newValue }
    }

    /// Token generation this request authenticated under, or nil when the ungated loopback posture
    /// installed no verifier.
    public var runeWeaverTokenGeneration: Int? {
        get { storage[ServerAuthGenerationKey.self] }
        set { storage[ServerAuthGenerationKey.self] = newValue }
    }
}

/// Storage key for the installed owner-auth verifier.
private struct ServerAuthApplicationKey: StorageKey {
    /// Installed verifier type.
    typealias Value = ServerAuth
}

extension Application {
    /// Owner bearer verifier installed by `configureRuneWeaver`, or nil for the no-auth loopback
    /// posture.
    public var runeWeaverAuth: ServerAuth? {
        get { storage[ServerAuthApplicationKey.self] }
        set { storage[ServerAuthApplicationKey.self] = newValue }
    }
}

/// Vapor middleware gating the engine surface behind the owner bearer token.
public struct ServerAuthMiddleware: AsyncMiddleware {
    /// Live owner verifier.
    private let auth: ServerAuth
    /// Bundle the public-path classifier resolves against, so only real static
    /// files are forwarded and a crafted data-route path is not.
    private let dashboardBundle: DashboardBundle

    /// Creates the middleware.
    public init(auth: ServerAuth, dashboardBundle: DashboardBundle = .resolve()) {
        self.auth = auth
        self.dashboardBundle = dashboardBundle
    }

    public func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        // Throttle on both the derived client and the direct peer: the header
        // value rotates freely even from loopback, so the peer bucket is what
        // bounds a rotating guesser to the loopback ceiling.
        let throttle = ServerAuthRequest.throttleIdentities(for: request)
        let identity = throttle.identity
        let path = request.url.path
        // A WebSocket handshake is the only surface where the query fallback is
        // safe, so it is consulted only for a genuine upgrade on the WebSocket
        // route; a lookup key alone on any other path stays header-only.
        let isUpgrade = ServerAuthRequest.isWebSocketUpgrade(request)
        let allowQueryToken = isUpgrade && ServerAuthRequest.isWebSocketPath(path)
        let presented = ServerAuthRequest.presentedBearer(for: request, allowQueryToken: allowQueryToken)

        // Verify and capture the generation in one actor hop.
        if let presented, let presentation = await auth.verifyAndCaptureGeneration(presented) {
            await auth.clearFailures(for: identity)
            await auth.clearFailures(for: throttle.peerIdentity)
            request.runeWeaverAuthenticated = true
            request.runeWeaverTokenGeneration = presentation.generation
            if isUpgrade {
                // Validate once, then erase the credential before the handshake
                // crosses into route handling so no downstream log captures it.
                ServerAuthRequest.stripPresentedToken(from: request)
            }
            let response = try await next.respond(to: request)
            // Only a browser session has a cookie to slide, and only once the renewal throttle has
            // elapsed; the owner bearer never rides a cookie and an upgrade cannot act on a
            // `Set-Cookie`.
            if presentation.kind == .browserSession,
               presentation.shouldRefreshSessionCookie,
               !isUpgrade,
               response.cookies[ServerAuthRequest.sessionCookieName] == nil
            {
                response.cookies[ServerAuthRequest.sessionCookieName] = ServerAuthRequest.makeSessionCookie(
                    token: presented,
                    isSecure: ServerAuthRequest.isRequestSecure(request)
                )
            }
            return response
        }

        if request.method == .GET || request.method == .HEAD {
            // The dashboard bundle boots the owner-token gate itself, so its bytes are forwarded
            // without a credential; the bundle carries no engine data and every data route stays
            // behind the 401 below.
            if ServerAuthRequest.isPublicDashboardPath(path, bundle: dashboardBundle) {
                return try await next.respond(to: request)
            }
            if ServerAuthRequest.isLivenessPath(path) {
                return Self.livenessResponse()
            }
        }

        // Browser session login (`POST /auth/session`) and logout (`DELETE /auth/session`)
        // handle candidate credentials directly and fail closed with their own failure-bucket
        // throttling, so they must be reachable without an existing session.
        if ServerAuthRequest.isAuthSessionPath(path) {
            return try await next.respond(to: request)
        }

        // Audit one line per rejected request with no credential echo; the path
        // excludes the query string, so a dropped token can never appear here.
        RuneWeaverLog.server.warning(
            "Owner auth rejected \(request.method) \(path) from \(identity)."
        )
        if let retryAfter = await auth.recordFailure(
            for: identity,
            isLoopback: throttle.isLoopback,
            peerIdentity: throttle.peerIdentity,
            peerIsLoopback: throttle.peerIsLoopback
        ) {
            return Self.throttledResponse(retryAfter: retryAfter)
        }
        return Self.unauthorizedResponse()
    }

    /// Uniform 401 that never distinguishes a missing credential from a wrong one.
    static func unauthorizedResponse() -> Response {
        Response(
            status: .unauthorized,
            headers: HTTPHeaders([
                ("Content-Type", "application/json; charset=utf-8"),
                ("Cache-Control", "no-store"),
                ("WWW-Authenticate", #"Bearer realm="Rune Weaver""#)
            ]),
            body: .init(string: #"{"error":"unauthorized"}"#)
        )
    }

    /// Throttled response advertising the cooldown.
    /// - Parameter retryAfter: Whole seconds until the bucket resets.
    static func throttledResponse(retryAfter: Int) -> Response {
        Response(
            status: .tooManyRequests,
            headers: HTTPHeaders([
                ("Content-Type", "application/json; charset=utf-8"),
                ("Cache-Control", "no-store"),
                ("Retry-After", "\(retryAfter)"),
                ("WWW-Authenticate", #"Bearer realm="Rune Weaver""#)
            ]),
            body: .init(string: #"{"error":"too many failed authentication attempts","retryAfter":\#(retryAfter)}"#)
        )
    }

    /// Minimal liveness shape that leaks no version, model, or search detail.
    static func livenessResponse() -> Response {
        Response(
            status: .ok,
            headers: HTTPHeaders([
                ("Content-Type", "application/json; charset=utf-8"),
                ("Cache-Control", "no-store")
            ]),
            body: .init(string: #"{"status":"ok"}"#)
        )
    }
}

/// URL-safe base64 without padding so a token survives query strings and headers.
extension Data {
    /// Encoded token body.
    fileprivate var runeWeaverBase64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

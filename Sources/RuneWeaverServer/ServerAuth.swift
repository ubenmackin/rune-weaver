// Rune Weaver Server — Single-owner bearer authentication for the engine surface.
//
// Rune Weaver is a personal, single-owner harness: exactly one bearer token
// guards the HTTP surface once it leaves loopback. This file owns the credential
// model — constant-time verification, the rotating token store, the brute-force
// bucket, the digest-keyed sliding browser sessions with their restricted-file
// persistence, and the Vapor middleware that gates every non-public route — so
// route files only declare paths while the trust boundary stays in one place.
//
// The public surface is tiny and carries no engine data: the static dashboard
// bundle plus a liveness shape that leaks no version, model, or search detail.
// The bundle must be reachable without a credential because a browser cannot
// attach an `Authorization` header to a top-level navigation or a `<script>`
// fetch, so gating its bytes behind the bearer would make the authenticated UI
// unreachable by construction; the bundle boots, probes the public liveness
// shape, and renders its own owner-token gate before any data request. Every
// data route — REST and the WebSocket upgrade — still fails closed with the
// same uniform 401, so a caller cannot distinguish a missing credential from a
// wrong one, and the credential is never logged.

import CryptoKit
import Foundation
import RuneWeaverCore
import RuneWeaverTools
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
///
/// The label names the source — an environment variable, the shared Keychain,
/// or the restricted file — so operator output can explain how the engine will
/// authenticate without ever carrying token material.
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

/// One resolved owner token plus the source it came from.
///
/// The token stays in memory only: callers must render only its fingerprint and
/// source label, never the credential itself.
public struct ResolvedServerAuthToken: Sendable {
    /// Token value, used to verify or fingerprint but never rendered as-is.
    public let token: String
    /// Credential-free origin of ``token``.
    public let source: ServerAuthTokenSource

    /// Creates a resolved token.
    /// - Parameters:
    ///   - token: Token value.
    ///   - source: Credential-free origin of the token.
    public init(token: String, source: ServerAuthTokenSource) {
        self.token = token
        self.source = source
    }
}

/// Resolves and persists the owner bearer token across the Keychain, the
/// headless environment override, and the restricted-permission file fallback.
///
/// Resolution order mirrors the security model: an explicit `token_env` variable
/// first, then the Keychain account `RUNEWEAVER_AUTH_TOKEN` (``SecretsManager``
/// already prefers a same-named environment variable before the Keychain), and
/// finally the `0600` file named by `token_file`. A nil file path disables that
/// fallback, matching ``AuthConfig/declaresTokenSource``. The resolved value is
/// never logged or rendered into diagnostics.
public struct ServerAuthTokenStore: Sendable {
    /// Keychain-backed secret access, reused so the auth surface and providers
    /// cannot drift on service namespace or environment precedence.
    private let secrets: SecretsManager
    /// Explicit environment variable consulted before the shared Keychain lookup.
    private let tokenEnv: String?
    /// Resolved `0600` file fallback, or nil when the config disables it.
    private let tokenFileURL: URL?

    /// Creates a token store from the `[auth]` config section.
    /// - Parameters:
    ///   - authConfig: Declared token sources.
    ///   - service: Keychain service namespace.
    ///   - inMemory: When true, secrets are kept in-memory and never touch the system Keychain.
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

    /// Resolves the current token from the first configured source.
    ///
    /// This is the single source of truth for the precedence env → Keychain →
    /// restricted file, so the boot verifier and the CLI diagnostics cannot
    /// drift and silently weaken each other. The Keychain branch reads through
    /// ``SecretsManager`` (which itself prefers the same-named environment
    /// variable) and reports the environment origin distinctly when that is
    /// where the value came from. A group/other-readable file fails closed
    /// rather than falling through to an unprotected value.
    /// - Returns: The token plus its credential-free source, or nil when no
    ///   source is provisioned.
    /// - Throws: ``SecretsError`` when the Keychain itself is unreadable, so the
    ///   caller can fail closed instead of falling through to a weaker source;
    ///   or ``ServerAuthError/insecureTokenFile(path:)`` for a loose file or one
    ///   whose permission mode cannot be verified.
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

    /// Persists a rotated token to every configured source.
    ///
    /// The Keychain is always written; the file fallback is written only when
    /// `token_file` names one. Because ``resolve()`` consults the Keychain
    /// before the file, a file-only success cannot be trusted while the
    /// Keychain still holds the retired value: a restart would resurrect it and
    /// reject the replacement. So unless a live environment override outranks
    /// the Keychain, the Keychain write itself must succeed; otherwise the
    /// rotation is refused and the live token stays untouched. An environment
    /// override remains operator-owned and is not a persistence target.
    /// - Parameter token: New token value.
    /// - Throws: ``ServerAuthError/tokenStorageFailed(reason:)`` when the
    ///   effective highest-precedence source did not persist.
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
    ///
    /// Resolution reads the configured `token_env` first, then the shared
    /// ``SecretsManager`` (which itself prefers `RUNEWEAVER_AUTH_TOKEN` in the
    /// environment), then the file. When either environment value is live it
    /// wins after a restart regardless of what persistence wrote, so a Keychain
    /// write failure cannot resurrect a retired token from a stale entry.
    private var environmentOverrideIsLive: Bool {
        activeEnvironmentOverride() != nil
    }

    /// Names the environment variable whose live value outranks persisted
    /// storage, or nil when no override is in effect.
    ///
    /// One accessor answers both "does an override win a restart?" for
    /// ``persist(_:)`` and "which variable must the operator change before a
    /// rotation can hold?" for ``ServerAuth/rotate()``, so the two can never
    /// disagree about the effective source.
    /// - Returns: The overriding variable's name, or nil.
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
    ///
    /// Environment values can arrive padded (for example from a shell export),
    /// and an untrimmed value would make `auth token status` report a different
    /// secret than the one boot enforces. Trimming here keeps the environment,
    /// Keychain, and file branches byte-for-byte comparable.
    /// - Parameter value: Raw source value, or nil when the source is absent.
    /// - Returns: The trimmed token, or nil when the source is blank.
    private static func normalizedToken(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    /// Reads bytes from a restricted file, refusing one that other local
    /// accounts could read or whose mode cannot be verified.
    ///
    /// A loose mode is a fail-closed error rather than a warning: trusting
    /// bytes another account can read would silently weaken the owner-only
    /// trust boundary the file exists to enforce. The same holds when the
    /// permission attribute is unavailable — an unverifiable mode is
    /// indistinguishable from a loose one, so the read never proceeds on a
    /// failed stat or a failed `NSNumber` cast. Callers name the error for
    /// their own artifact, so the token and session stores share one
    /// permission policy while still reporting which file was refused.
    /// - Parameters:
    ///   - fileURL: Restricted file to read.
    ///   - insecureFileError: Error constructor naming the refused path.
    ///   - fileManager: Filesystem accessor, injectable so the unreadable-attribute
    ///     path can be exercised without loosening a real file.
    /// - Returns: The file's bytes, or nil when the file is absent or unreadable.
    /// - Throws: The `insecureFileError` for a loose file or one whose
    ///   permission mode could not be verified.
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
        return try? Data(contentsOf: fileURL)
    }

    /// Reads a restricted token file and normalizes its text value.
    ///
    /// Environment values can arrive padded, so the file branch trims through
    /// the same normalization as every other source; a blank result is treated
    /// as absent. Permission refusal is delegated to ``readRestrictedData(_:insecureFileError:fileManager:)``
    /// so the token and session stores cannot drift on the mode policy.
    /// - Parameters:
    ///   - fileURL: Restricted token file.
    ///   - fileManager: Filesystem accessor, injectable so the unreadable-attribute
    ///     path can be exercised without loosening a real file.
    /// - Returns: The trimmed token, or nil when the file is absent or blank.
    /// - Throws: ``ServerAuthError/insecureTokenFile(path:)`` for a loose file or
    ///   one whose permission mode could not be read.
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

/// How a presented credential authenticated, captured atomically with the
/// verification itself.
///
/// The owner token and browser sessions are both bearer credentials, but they
/// differ in the follow-up they permit: only a browser session may have its
/// cookie re-issued, and both are bound to the generation that was live when
/// they were checked. Returning this shape from one actor hop keeps the
/// classification and the generation consistent under a concurrent
/// ``ServerAuth/rotate()`` instead of letting a separate lookup observe a
/// rotation in between.
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
    /// Whether the browser session cookie is due to be re-issued.
    ///
    /// Always false for ``Kind/ownerToken``: the owner token never rides a
    /// cookie, so an owner verification must not attach one.
    public let shouldRefreshSessionCookie: Bool

    /// Creates a verified presentation.
    /// - Parameters:
    ///   - generation: Token generation the credential verified under.
    ///   - kind: Which credential class matched.
    ///   - shouldRefreshSessionCookie: Whether the cookie is due for renewal.
    public init(generation: Int, kind: Kind, shouldRefreshSessionCookie: Bool) {
        self.generation = generation
        self.kind = kind
        self.shouldRefreshSessionCookie = shouldRefreshSessionCookie
    }
}

/// One-time response carrying the freshly rotated owner token.
///
/// The token is returned exactly once here; the caller is responsible for
/// storing it. It is deliberately absent from every log line and audit entry.
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
///
/// The live token is held in memory for comparison; rotation persists the new
/// value through ``ServerAuthTokenStore`` and swaps it in one actor hop, so the
/// previous token is invalid immediately and every other device falls back to
/// the login gate on its next request. Each rotation also advances a generation
/// that established WebSockets track, so a socket that upgraded under the
/// retired token is dropped instead of continuing to stream. Failed attempts
/// accumulate in per-client buckets that trip a temporary `Retry-After`; the
/// loopback owner uses a higher typo-tolerant bound (`maxLoopbackFailures`)
/// so local mistypes rarely throttle, while brute force stays bounded behind
/// the same cooldown and window as remote peers.
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
    ///
    /// The window slides with every authenticated request and has no absolute
    /// cap: daily activity keeps a session alive indefinitely, and only a
    /// rotation forcibly revokes one. The browser cookie advertises the same
    /// lifetime as its `Max-Age`.
    public static let sessionIdleTimeoutSeconds: TimeInterval = 86400
    /// Minimum interval between re-issuing one browser's session cookie.
    ///
    /// Renewal is throttled so an active dashboard is not sent a fresh
    /// `Set-Cookie` on every request while its idle window still slides.
    public static let sessionCookieRenewalIntervalSeconds: TimeInterval = 300
    /// Minimum interval between touch-class session persists.
    ///
    /// Structural changes always write immediately; touch updates coalesce to
    /// this interval so request-rate activity does not become disk IO.
    static let sessionPersistenceCoalesceSeconds: TimeInterval = 60
    /// Upper bound on tracked identities so random clients cannot grow memory without bound.
    private static let maxTrackedIdentities = 1024

    /// Live token; compared in constant time and replaced only by `rotate`.
    private var token: String
    /// Monotonic generation advanced by each rotation.
    ///
    /// A WebSocket records the generation it upgraded under, so a rotation can
    /// revoke sockets that authenticated with the retired token instead of
    /// letting them keep streaming or sending with a credential that no longer
    /// verifies at the gate.
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

    /// One active browser session, keyed by the digest of its token.
    ///
    /// The digest key means the table itself never carries a credential. The
    /// generation binds the session to the live owner token so a rotation
    /// revokes sessions minted under the retired credential instead of letting
    /// them survive past it; `lastSeenAt` drives the sliding idle window and the
    /// least-recently-seen eviction order, and `cookieRefreshedAt` throttles
    /// renewal so an active browser is not re-issued its cookie on every request.
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

    /// Creates a verifier with a known token.
    /// Prefer ``resolve(authConfig:service:inMemory:)`` at boot so the token is loaded
    /// from the configured sources instead of hard-coded.
    ///
    /// When a session store is supplied, unexpired persisted sessions minted
    /// under the persisted generation are restored so a restart preserves device
    /// logins. A refused or undecodable document logs a credential-free warning
    /// and starts empty rather than trusting it; drops found at load only set the
    /// dirty flag, so a boot that merely shed stale entries waits for the next
    /// touch or structural change before rewriting the file.
    /// - Parameters:
    ///   - initialToken: Non-empty live token.
    ///   - store: Persistence seam used by rotations.
    ///   - sessionStore: Durable session sink, or nil to keep sessions in memory only.
    ///   - now: Clock used for expiry, renewal, and persistence scheduling.
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

    /// Resolves a boot token from the configured sources.
    /// - Parameters:
    ///   - authConfig: Declared token sources.
    ///   - service: Keychain service namespace.
    ///   - inMemory: When true, secrets are kept in-memory and never touch the system
    ///     Keychain, and the durable session store is disabled so no session file is
    ///     read or written.
    /// - Returns: A verifier, or nil when no source resolves (loopback-no-auth).
    /// - Throws: ``ServerAuthError`` on unreadable storage so boot fails closed.
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

    /// Mints a fresh ephemeral session token for browser dashboard access.
    ///
    /// Only the SHA-256 digest of the token is stored, so neither the session
    /// table nor the persisted document can leak a credential. The entry is
    /// bound to the current generation so a later ``rotate()`` revokes it with
    /// every other live session, and the table is trimmed to the cap by evicting
    /// the least-recently-seen session. A structural change persists
    /// immediately, so a crash cannot strand a browser holding a cookie the
    /// server has already forgotten. Called from the login (`POST /auth/session`)
    /// and rotation (`POST /auth/rotate`) routes after the owner credential verifies.
    /// - Returns: The newly minted 256-bit session token.
    /// - Throws: ``ServerAuthError/tokenGenerationFailed`` when the system
    ///   CSPRNG cannot produce random bytes; no weaker fallback is minted.
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

    /// Revokes an ephemeral browser session on logout.
    ///
    /// The removal is structural, so the persisted set is rewritten immediately:
    /// a restart must not resurrect a session the owner just logged out.
    public func revokeSession(_ sessionID: String) {
        sessions.removeValue(forKey: Self.sessionDigestHex(sessionID))
        markDirty(structural: true)
    }

    /// Flushes all active browser sessions (e.g. during token rotation).
    ///
    /// The empty set is persisted immediately, so the clear survives a restart
    /// instead of letting disk resurrect sessions the rotation retired.
    public func revokeAllSessions() {
        sessions.removeAll(keepingCapacity: false)
        markDirty(structural: true)
    }

    /// Whether an ephemeral session identifier is currently active.
    ///
    /// Applies the same generation and idle-window checks as ``verify(_:)``, so
    /// an expired or rotated session never reads as active.
    public func hasActiveSession(_ sessionID: String) -> Bool {
        guard let entry = sessions[Self.sessionDigestHex(sessionID)] else { return false }
        return entry.generation == generation && !Self.isExpired(entry, at: now())
    }

    /// Verifies a presented credential and captures how it authenticated,
    /// atomically.
    ///
    /// ``rotate()`` swaps the live token and advances `generation` in the same
    /// actor hop, so reading the generation in a separate call after a plain
    /// ``verify(_:)`` can observe a rotation that landed between the two hops: a
    /// request authenticated with the retired token would then be stamped with
    /// the new generation and survive both the hub watermark and the per-frame
    /// check. Returning the presentation from the same hop as the constant-time
    /// comparison closes that window — the value always belongs to whichever
    /// credential actually matched. The call suspends no further once it begins,
    /// so it cannot interleave with a rotation.
    ///
    /// Browser sessions also slide here: a touch updates `lastSeenAt`, and once
    /// the renewal throttle has elapsed the presentation asks the caller to
    /// re-issue the cookie. An entry that is expired or was minted under a
    /// retired generation is dropped on sight, since presenting it proves the
    /// browser still holds a credential the server has already retired.
    /// - Parameter presented: Credential from the header, cookie, or upgrade query.
    /// - Returns: How the credential authenticated, or nil when it did not.
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
    ///
    /// Reuses the atomic compare-and-capture so the comparison semantics live in
    /// exactly one place and a future change cannot weaken one path while the
    /// other still guards the surface.
    /// - Parameter presented: Credential from the header, cookie, or upgrade query.
    /// - Returns: True for the live owner token or an active browser session.
    public func verify(_ presented: String) -> Bool {
        verifyAndCaptureGeneration(presented) != nil
    }

    /// Verifies a presented value against the live owner bearer token only,
    /// excluding ephemeral browser sessions.
    ///
    /// Session minting (`POST /auth/session`) exchanges the owner credential
    /// for a fresh session, so it must verify the owner token specifically: a
    /// resent session value verifies at the request gate by design, but
    /// accepting it here would let that value mint unbounded replacement
    /// sessions instead of failing closed like any other wrong credential.
    /// - Parameter presented: Candidate owner token from the login body or header.
    /// - Returns: True only for the live owner token.
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
    ///
    /// A socket that upgraded while `generation` was current must stop being
    /// trusted the moment ``rotate()`` advances the counter; re-checking per
    /// frame closes the gap between the token swap and the socket teardown.
    /// - Parameter generation: Generation captured at upgrade.
    /// - Returns: True while the token that authorized the socket is current.
    public func isCurrentGeneration(_ generation: Int) -> Bool {
        generation == self.generation
    }

    /// Rotates the owner token, persisting the new value before it goes live.
    ///
    /// Persistence happens first so a storage failure leaves the current token
    /// valid instead of stranding the owner with a token that was never saved.
    /// A live environment override outranks every persistence target, so a
    /// rotation it cannot replace would be reported as successful and then
    /// silently undone on the next boot; that case is refused up front rather
    /// than minting a credential that cannot hold.
    ///
    /// Every live session is cleared through ``revokeAllSessions()``, whose
    /// structural write persists the empty set alongside the advanced
    /// generation, so a restart cannot resurrect a session this rotation retired.
    /// - Returns: The new token, returned to the caller exactly once.
    /// - Throws: ``ServerAuthError/environmentOverrideActive(name:)`` when an
    ///   environment override would shadow the replacement, or
    ///   ``ServerAuthError`` when generation or persistence fails.
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
    ///
    /// An already-blocked identity returns the remaining cooldown without
    /// incrementing, so repeated guesses cannot extend their own lockout.
    /// Loopback uses a higher typo-tolerant bound (`maxLoopbackFailures` 25)
    /// than remote (`maxFailures` 5) because the owner shares the machine and
    /// mistypes locally, but it is still bounded: reaching the bound trips a
    /// `retryAfterSeconds` cooldown inside the `failureWindow`, and buckets
    /// prune under `maxTrackedIdentities`.
    /// - Parameters:
    ///   - identity: Client address used to scope the bucket.
    ///   - isLoopback: Whether the identity uses the loopback bound.
    /// - Returns: `Retry-After` seconds when throttled, otherwise nil.
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

    /// Records one failed attempt against both the derived client bucket and the direct-peer bucket.
    ///
    /// `X-Forwarded-For` is caller-controlled even behind a loopback proxy, so
    /// throttling the derived identity alone lets a local peer rotate the header
    /// for a fresh bucket per guess and bypass both bounds. Recording the
    /// non-spoofable peer alongside preserves per-client attribution (a stable
    /// client still trips its own `maxFailures` bound) while the shared peer
    /// bucket trips at `maxLoopbackFailures` no matter how the header rotates.
    /// When either bucket is already blocked, the remaining cooldown is answered
    /// without incrementing either, so blocked guesses cannot extend the lockout.
    /// - Parameters:
    ///   - identity: Derived client bucket from `ServerAuthRequest.clientIdentity`.
    ///   - isLoopback: Whether the derived identity uses the loopback bound.
    ///   - peerIdentity: Direct socket peer bucket from `ServerAuthRequest.directPeerIdentity`.
    ///   - peerIsLoopback: Whether the peer identity uses the loopback bound.
    /// - Returns: `Retry-After` seconds when either bucket is throttled, otherwise nil.
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
    ///
    /// Shared so the single- and dual-bucket paths answer a blocked identity
    /// identically instead of forking the blocked check.
    /// - Parameters:
    ///   - identity: Bucket to inspect.
    ///   - now: Clock value shared with the calling record.
    /// - Returns: Whole seconds until the bucket lifts, or nil when unblocked.
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
    ///
    /// Hashing removes length and byte-position signals, and equal-width digests
    /// keep the comparison independent of how many leading bytes match, so a
    /// caller cannot time-probe the token.
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
    ///
    /// Shared so the audit trail and the CLI `auth token status` output agree on
    /// what a given token's identifier is instead of forking the hash. Eight
    /// bytes is enough to compare or support-reference a credential while
    /// leaving it infeasible to recover.
    /// - Parameter token: Token to fingerprint.
    /// - Returns: First eight bytes of the SHA-256 digest as lowercase hex.
    public static func fingerprint(_ token: String) -> String {
        let digest = SHA256.hash(data: Data(token.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Full digest that keys one session token in memory and on disk.
    ///
    /// The digest is the session's durable identity: persisting or logging it
    /// reveals nothing usable, while a presented token can still be looked up
    /// without keeping raw credentials outside process memory.
    /// - Parameter token: Raw session token.
    /// - Returns: 64 lowercase hex characters.
    private static func sessionDigestHex(_ token: String) -> String {
        let digest = SHA256.hash(data: Data(token.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Whether a session has been idle past the sliding window.
    ///
    /// Static because the actor's synchronous initializer is nonisolated and
    /// must prune persisted entries before the actor is usable; keeping the one
    /// predicate here means load, touch, and lookup cannot drift on what
    /// "expired" means.
    /// - Parameters:
    ///   - entry: Session entry to test.
    ///   - current: Clock value shared by the calling operation.
    /// - Returns: True when the idle window has fully lapsed.
    private static func isExpired(_ entry: SessionEntry, at current: Date) -> Bool {
        current.timeIntervalSince(entry.lastSeenAt) > sessionIdleTimeoutSeconds
    }

    /// Drops expired sessions from memory without a structural write.
    ///
    /// Expiry is implicit in the clock advancing, so it must not force disk IO
    /// on its own; the dirty flag still records that memory has diverged from
    /// disk, and the next touch or structural change persists the pruned set.
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
    ///
    /// Ordering by `lastSeenAt` makes an idle session lose to an active one;
    /// ties fall back to the older creation time and then the digest, so
    /// eviction stays deterministic even when two sessions were touched in the
    /// same instant.
    /// - Parameter sessions: Session table to trim in place.
    /// - Returns: True when at least one entry was evicted.
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
    ///
    /// Structural changes (mint, revoke, rotation) write immediately so they
    /// survive a crash; touch updates coalesce to the interval so a busy browser
    /// cannot turn every request into disk IO. A recorded attempt throttles
    /// retries after a failed write to the same interval instead of hammering a
    /// failing disk, and a verifier that has not attempted a write yet has no
    /// throttle to honor.
    /// - Parameter structural: Whether a session was added or removed.
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

    /// Writes the current session table and records the attempt either way.
    ///
    /// A missing store clears the dirty flag without IO, matching the contract
    /// that an in-memory-only verifier never touches disk. A failed write logs a
    /// credential-free warning and leaves the dirty flag set so the next
    /// coalesce interval retries; the attempt is recorded for both outcomes so a
    /// failing filesystem is not retried on every request.
    /// - Parameter current: Clock value shared with the change that triggered the write.
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
///
/// A single value keeps the middleware and login gates from drifting: the derived
/// identity preserves per-client attribution behind a trusted proxy, while the
/// peer identity bounds header rotation to the loopback ceiling when a caller
/// cycles `X-Forwarded-For` to escape the per-client bucket.
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
    /// - Parameters:
    ///   - identity: Derived client bucket.
    ///   - isLoopback: Whether the derived identity uses the loopback bound.
    ///   - peerIdentity: Direct socket peer bucket.
    ///   - peerIsLoopback: Whether the direct peer uses the loopback bound.
    public init(identity: String, isLoopback: Bool, peerIdentity: String, peerIsLoopback: Bool) {
        self.identity = identity
        self.isLoopback = isLoopback
        self.peerIdentity = peerIdentity
        self.peerIsLoopback = peerIsLoopback
    }
}

/// Request classification shared by the middleware and the WebSocket upgrade guard.
///
/// Keeping the credential-extraction rules in one place means the header path,
/// the upgrade-only query fallback, and the client identity used for throttling
/// cannot drift between the two gates.
public enum ServerAuthRequest {
    /// Whether a request is a WebSocket upgrade handshake.
    ///
    /// The full handshake shape is required: `Connection: upgrade`, an
    /// `Upgrade: websocket` token, and the client's `Sec-WebSocket-Key`. Checking
    /// the key alone would let an ordinary REST request bearing a spoofed header
    /// masquerade as an upgrade and reach the query-token fallback, leaking the
    /// credential into URL and referrer logs.
    /// - Parameter request: Inbound request.
    /// - Returns: True for a genuine upgrade, never for a plain GET.
    public static func isWebSocketUpgrade(_ request: Request) -> Bool {
        guard request.headers.first(name: .secWebSocketKey) != nil else { return false }
        let connection = request.headers.first(name: .connection)?.lowercased() ?? ""
        let upgrade = request.headers.first(name: .upgrade)?.lowercased() ?? ""
        return connection.contains("upgrade") && upgrade == "websocket"
    }

    /// Cookie name holding the owner session token for browser dashboard access.
    public static let sessionCookieName = "rw_session"

    /// Extracts the presented bearer credential.
    ///
    /// The `token` query parameter is accepted only when `allowQueryToken` is
    /// set, because browsers cannot attach an `Authorization` header to a
    /// WebSocket handshake; REST requests must use the header so a credential
    /// never rides along in a logged URL. Browser sessions present an `HttpOnly`
    /// cookie so the credential is never accessible to client scripts.
    /// - Parameters:
    ///   - request: Inbound request.
    ///   - allowQueryToken: Whether the upgrade query fallback is permitted.
    /// - Returns: The presented token, or nil when none is present.
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
    ///
    /// The cookie advertises the same sliding idle lifetime the server enforces,
    /// so a browser drops the credential at roughly the moment the session would
    /// die server-side instead of holding a cookie for a session that is already
    /// gone. `Max-Age` (rather than `Expires`) is used so a refreshed cookie
    /// fully replaces the browser's previous deadline, and the parameter lets a
    /// caller mint a deliberately different lifetime without forking the
    /// attribute list.
    /// - Parameters:
    ///   - token: Session token to store in the cookie.
    ///   - isSecure: Whether the cookie is HTTPS-only.
    ///   - maxAge: Lifetime in seconds, defaulting to the sliding idle window.
    /// - Returns: Session cookie ready to attach to a response.
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

    /// Determines whether the inbound request was made over HTTPS directly or through a TLS-terminating reverse proxy.
    ///
    /// A direct `https` URL is secure on its own. `X-Forwarded-Proto` is honored
    /// only when the direct socket peer is loopback, meaning a trusted local
    /// proxy asserted it; a remote peer can forge the header, so it never
    /// confers security, and an absent peer fails closed as insecure. Test-built
    /// requests carry no peer, so the header is honored there only under an
    /// explicit `.testing` environment check, never by treating absence as
    /// trust — keeping HSTS and `Secure` cookies off spoofed transports.
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

    /// Whether the `X-Forwarded-Proto` header asserts HTTPS.
    ///
    /// Only the first entry matters because a trusted local proxy prepends the
    /// client-facing protocol; later entries are downstream hops, not the edge.
    /// - Parameter request: Inbound request.
    /// - Returns: True when the primary protocol is `https`.
    private static func forwardedProtoIsHttps(_ request: Request) -> Bool {
        guard let forwardedProto = request.headers.first(name: "X-Forwarded-Proto") else {
            return false
        }
        let primary = forwardedProto.split(separator: ",").first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return primary == "https"
    }

    /// Whether a socket peer address is loopback.
    ///
    /// Single-sourced so the TLS trust gate and the throttle classifier agree
    /// on which peers count as local instead of drifting on forked literals.
    /// - Parameter peerIP: Direct peer address, never `unknown`.
    /// - Returns: True for the loopback literals.
    private static func isLoopbackAddress(_ peerIP: String) -> Bool {
        peerIP == "127.0.0.1" || peerIP == "::1" || peerIP.lowercased() == "localhost"
    }

    /// Stable client identity for failure buckets.
    ///
    /// The first `X-Forwarded-For` entry is honored only from a direct loopback
    /// peer so proxied clients attribute to their own bucket, but that value is
    /// caller-controlled and rotates freely — so callers must always throttle
    /// the non-spoofable ``directPeerIdentity(for:)`` alongside this identity
    /// (see ``throttleIdentities(for:)``) instead of bucketing on this alone.
    /// `unknown` means there is no throttleable peer (in-process or test requests).
    /// - Parameter request: Inbound request.
    /// - Returns: Address string used to scope the failure bucket.
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
    ///
    /// Forwarding headers rotate under caller control, so this non-spoofable
    /// peer is the anchor that keeps per-client attribution from becoming a
    /// throttle bypass: the peer bucket aggregates every identity one loopback
    /// proxy asserts.
    /// - Parameter request: Inbound request.
    /// - Returns: Peer address, or `unknown` when there is no socket peer.
    public static func directPeerIdentity(for request: Request) -> String {
        request.remoteAddress?.ipAddress ?? "unknown"
    }

    /// Throttle scope for one request: the derived client bucket plus the direct-peer bucket.
    ///
    /// Bundling both keeps the two middleware paths from drifting: the derived
    /// identity preserves per-client attribution behind a trusted proxy, while
    /// the peer identity bounds header rotation to the loopback ceiling.
    /// - Parameter request: Inbound request.
    /// - Returns: Derived identity and peer identity with their loopback bounds.
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

    /// Whether an identity is loopback and therefore uses the loopback bound.
    ///
    /// `unknown` (no socket peer, such as in-process or test requests) uses the
    /// loopback bound like a local peer rather than the stricter remote bound.
    /// - Parameter identity: Identity from ``clientIdentity(for:)`` or ``directPeerIdentity(for:)``.
    /// - Returns: True for loopback addresses or `unknown`.
    public static func isLoopback(_ identity: String) -> Bool {
        identity == "unknown" || isLoopbackAddress(identity)
    }

    /// Whether a path serves public dashboard bytes.
    ///
    /// The dashboard bundle is static client code with no engine data: it loads,
    /// probes the public liveness shape, and renders its own owner-token gate
    /// before it presents the credential on any data request. Browsers cannot
    /// attach an `Authorization` header to a navigation or a `<script>` fetch,
    /// so these bytes must be public or the authenticated UI can never boot.
    ///
    /// Classification fails closed: only the SPA entry points and paths that
    /// resolve to real bundle files qualify. A public-looking extension is never
    /// sufficient on its own, because a registered data route can carry a
    /// free-form parameter whose value ends in one (for example a plugin id of
    /// `index.html` or `report.json`); treating those as bundle bytes would
    /// forward them past the owner gate. Every other path stays gated so an
    /// unknown route cannot probe the engine surface for existence.
    /// - Parameters:
    ///   - path: Request path (query excluded).
    ///   - bundle: Resolved bundle the request would be served from.
    ///   - fileManager: Filesystem accessor used for the existence check.
    /// - Returns: True only for the entry points or an existing static bundle file.
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
    ///
    /// Kept separate from the existence check so an unrecognized location is
    /// rejected before any filesystem access, and a directory prefix can never
    /// be mistaken for a root-level static file.
    /// - Parameter normalizedPath: Slash-trimmed, lowercased request path.
    /// - Returns: True for the hashed asset directory or a known root file.
    private static func isBundleStaticPath(_ normalizedPath: String) -> Bool {
        if normalizedPath.hasPrefix("assets/") {
            return true
        }
        return isKnownStaticRootFile(normalizedPath)
    }

    /// Whether a root-level path names a static file the bundle ships.
    ///
    /// Root files have fixed, build-generated names (favicons, web manifest,
    /// robots policy), so they are allowlisted explicitly rather than inferred
    /// from their extension; a nested path is never a root file.
    /// - Parameter normalizedPath: Slash-trimmed, lowercased request path.
    /// - Returns: True for a recognized root-level static file name.
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

    /// Whether a path is the single WebSocket endpoint.
    ///
    /// The upgrade-only query fallback is restricted to this path so a spoofed
    /// handshake shape on a REST route can never turn a URL query into a
    /// credential.
    /// - Parameter path: Request path (query excluded).
    /// - Returns: True for the WebSocket route.
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

    /// Removes the `token` query parameter from a request.
    ///
    /// Called after an upgrade credential is validated so downstream handlers and
    /// logs can never capture it; the rest of the query string is preserved.
    /// - Parameter request: Request whose URL is rewritten in place.
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

public extension Request {
    /// Whether this request already passed owner bearer authentication.
    ///
    /// The WebSocket upgrade guard reads this marker instead of re-reading the
    /// credential, so the middleware can drop the query token before any
    /// downstream log observes it.
    var runeWeaverAuthenticated: Bool {
        get { storage[ServerAuthenticatedKey.self] ?? false }
        set { storage[ServerAuthenticatedKey.self] = newValue }
    }

    /// Token generation this request authenticated under, or nil when the
    /// ungated loopback posture installed no verifier.
    ///
    /// A WebSocket captures this at upgrade so a later rotation can revoke the
    /// connection at the frame boundary, not only when frames are fanned out.
    var runeWeaverTokenGeneration: Int? {
        get { storage[ServerAuthGenerationKey.self] }
        set { storage[ServerAuthGenerationKey.self] = newValue }
    }
}

/// Storage key for the installed owner-auth verifier.
private struct ServerAuthApplicationKey: StorageKey {
    /// Installed verifier type.
    typealias Value = ServerAuth
}

public extension Application {
    /// Owner bearer verifier installed by `configureRuneWeaver`, or nil for the
    /// no-auth loopback posture.
    ///
    /// `registerRuneWeaverRoutes` reads this to decide whether to gate the
    /// surface, so a context without a verifier stays byte-for-byte the v1
    /// loopback behavior, including the absence of the rotation route.
    var runeWeaverAuth: ServerAuth? {
        get { storage[ServerAuthApplicationKey.self] }
        set { storage[ServerAuthApplicationKey.self] = newValue }
    }
}

/// Vapor middleware gating the engine surface behind the owner bearer token.
///
/// The public surface is intentionally tiny: the static dashboard bundle (which
/// carries no engine data and renders its own owner-token gate) and a minimal
/// liveness shape never reveal version, model, or search state, while every
/// other path — REST and the WebSocket upgrade — returns the same uniform 401 so
/// a caller cannot tell a missing credential from a wrong one. Failures feed a
/// per-client bucket that answers with `Retry-After`.
public struct ServerAuthMiddleware: AsyncMiddleware {
    /// Live owner verifier.
    private let auth: ServerAuth
    /// Bundle the public-path classifier resolves against, so only real static
    /// files are forwarded and a crafted data-route path is not.
    private let dashboardBundle: DashboardBundle

    /// Creates the middleware.
    /// - Parameters:
    ///   - auth: Live owner verifier.
    ///   - dashboardBundle: Resolved bundle used to classify public static bytes.
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

        // Verify and capture the generation in one actor hop. Splitting them
        // would let a rotation land in between and stamp a retired-token upgrade
        // with the new generation, which would then pass the hub watermark and
        // the per-frame check instead of being refused.
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
            // Only a browser session has a cookie to slide, and only once the
            // renewal throttle has elapsed; the owner bearer never rides a
            // cookie and an upgrade cannot act on a `Set-Cookie`. A cookie the
            // handler already issued (logout's expiry or rotation's fresh
            // session) is authoritative, so renewal must not clobber it.
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
            // The dashboard bundle boots the owner-token gate itself, so its
            // bytes are forwarded without a credential; the bundle carries no
            // engine data and every data route stays behind the 401 below.
            // Vapor maps HEAD onto the GET route, so probes must classify the
            // same way instead of failing with a spurious 401.
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
private extension Data {
    /// Encoded token body.
    var runeWeaverBase64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

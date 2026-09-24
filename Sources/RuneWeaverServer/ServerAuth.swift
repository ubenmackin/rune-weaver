// Rune Weaver Server — Single-owner bearer authentication for the engine surface.
//
// Rune Weaver is a personal, single-owner harness: exactly one bearer token
// guards the HTTP surface once it leaves loopback. This file owns the credential
// model — constant-time verification, the rotating token store, the brute-force
// bucket, and the Vapor middleware that gates every non-public route — so route
// files only declare paths while the trust boundary stays in one place.
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
    public init(authConfig: AuthConfig, service: String = SecretsManager.defaultService) {
        self.secrets = SecretsManager(service: service)
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
                try Self.writeRestrictedFile(token, to: tokenFileURL)
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

    /// Reads the token file, refusing one that other local accounts could read
    /// or whose mode cannot be verified.
    ///
    /// A loose mode is a fail-closed error rather than a warning: trusting a
    /// credential another account can read would silently weaken the owner-only
    /// trust boundary the token exists to enforce. The same holds when the
    /// permission attribute is unavailable — an unverifiable mode is
    /// indistinguishable from a loose one, so the read never proceeds on a
    /// failed stat or a failed `NSNumber` cast.
    /// - Parameters:
    ///   - fileURL: Restricted token file.
    ///   - fileManager: Filesystem accessor, injectable so the unreadable-attribute
    ///     path can be exercised without loosening a real file.
    /// - Returns: The trimmed token, or nil when the file is absent or blank.
    /// - Throws: ``ServerAuthError/insecureTokenFile(path:)`` for a loose file or
    ///   one whose permission mode could not be read.
    static func readRestrictedFile(_ fileURL: URL, fileManager: FileManager = .default) throws -> String? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
              let permissions = attributes[.posixPermissions] as? NSNumber
        else {
            // Fail closed: without a verified mode there is no way to prove the
            // credential is owner-only, so it must not be read at all.
            throw ServerAuthError.insecureTokenFile(path: fileURL.path)
        }
        if permissions.intValue & 0o077 != 0 {
            throw ServerAuthError.insecureTokenFile(path: fileURL.path)
        }
        guard let data = try? Data(contentsOf: fileURL), let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return Self.normalizedToken(value)
    }

    /// Writes the token to a `0600` file inside a `0700` directory using a
    /// same-directory temp plus an atomic replace, so a crash never leaves a
    /// half-written credential and no window exposes it under a looser mode.
    private static func writeRestrictedFile(_ token: String, to fileURL: URL) throws {
        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // Re-assert the directory mode: a directory created by an older build or
        // a restore could be wider, and the token must never sit in one.
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let tempURL = directory.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        guard fileManager.createFile(
            atPath: tempURL.path,
            contents: Data(token.utf8),
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
/// loopback owner is never throttled, so a remote guesser can never lock the
/// owner out.
public actor ServerAuth {
    /// Failed attempts from one non-loopback identity before throttling.
    public static let maxFailures = 5
    /// Window over which failures accumulate before the bucket resets.
    public static let failureWindow: TimeInterval = 60
    /// Cooldown advertised through `Retry-After` once the bucket trips.
    public static let retryAfterSeconds = 30
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
    /// Ephemeral browser sessions, mapping session token -> session entry.
    private var sessions: [String: SessionEntry] = [:]
    /// Upper bound on active browser sessions to prevent unbounded memory growth.
    private static let maxActiveSessions = 100

    /// One active browser session: the token generation it was minted under plus
    /// when it was created.
    ///
    /// The generation binds the session to the live owner token so a rotation
    /// revokes sessions minted under the retired credential instead of letting
    /// them survive past it; `createdAt` orders entries oldest-first so the
    /// 100-session cap evicts the stalest sessions first.
    private struct SessionEntry: Sendable {
        let generation: Int
        let createdAt: Date
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
    /// Prefer ``resolve(authConfig:service:)`` at boot so the token is loaded
    /// from the configured sources instead of hard-coded.
    /// - Parameters:
    ///   - initialToken: Non-empty live token.
    ///   - store: Persistence seam used by rotations.
    public init(initialToken: String, store: ServerAuthTokenStore) {
        self.token = initialToken
        self.store = store
    }

    /// Resolves a boot token from the configured sources.
    /// - Parameters:
    ///   - authConfig: Declared token sources.
    ///   - service: Keychain service namespace.
    /// - Returns: A verifier, or nil when no source resolves (loopback-no-auth).
    /// - Throws: ``ServerAuthError`` on unreadable storage so boot fails closed.
    public static func resolve(
        authConfig: AuthConfig,
        service: String = SecretsManager.defaultService
    ) async throws -> ServerAuth? {
        let store = ServerAuthTokenStore(authConfig: authConfig, service: service)
        guard let loaded = try await store.resolve()?.token else {
            return nil
        }
        let trimmed = loaded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        return ServerAuth(initialToken: trimmed, store: store)
    }

    /// Mints a fresh ephemeral session token for browser dashboard access.
    ///
    /// The token is bound to the current generation so a later ``rotate()``
    /// revokes it with every other live session, and entries carry their
    /// creation time so the 100-session cap evicts oldest-first instead of
    /// growing without bound. Called from the login (`POST /auth/session`) and
    /// rotation (`POST /auth/rotate`) routes after the owner credential verifies.
    /// - Returns: The newly minted 256-bit session token.
    /// - Throws: ``ServerAuthError/tokenGenerationFailed`` when the system
    ///   CSPRNG cannot produce random bytes; no weaker fallback is minted.
    public func createSession() throws -> String {
        if sessions.count >= Self.maxActiveSessions {
            let sorted = sessions.sorted { $0.value.createdAt < $1.value.createdAt }
            for (key, _) in sorted.prefix(sessions.count - Self.maxActiveSessions + 1) {
                sessions.removeValue(forKey: key)
            }
        }
        let sessionToken = try Self.generateToken()
        sessions[sessionToken] = SessionEntry(generation: generation, createdAt: Date())
        return sessionToken
    }

    /// Revokes an ephemeral browser session on logout.
    public func revokeSession(_ sessionID: String) {
        sessions.removeValue(forKey: sessionID)
    }

    /// Flushes all active browser sessions (e.g. during token rotation).
    public func revokeAllSessions() {
        sessions.removeAll(keepingCapacity: false)
    }

    /// Whether an ephemeral session identifier is currently active.
    public func hasActiveSession(_ sessionID: String) -> Bool {
        sessions[sessionID] != nil
    }

    /// Verifies a presented token and captures the generation it verified under,
    /// atomically.
    ///
    /// ``rotate()`` swaps the live token and advances `generation` in the same
    /// actor hop, so reading the generation in a separate call after a plain
    /// ``verify(_:)`` can observe a rotation that landed between the two hops: a
    /// request authenticated with the retired token would then be stamped with
    /// the new generation and survive both the hub watermark and the per-frame
    /// check. Returning the generation from the same hop as the constant-time
    /// comparison closes that window — the value always belongs to whichever
    /// token actually matched. The call suspends no further once it begins, so it
    /// cannot interleave with a rotation.
    /// - Parameter presented: Credential from the header or upgrade query.
    /// - Returns: The generation the live token was verified under, or nil when
    ///   the presented value is empty or does not match.
    public func verifyAndCaptureGeneration(_ presented: String) -> Int? {
        guard !presented.isEmpty else { return nil }
        if let session = sessions[presented] {
            if session.generation == self.generation {
                return session.generation
            } else {
                sessions.removeValue(forKey: presented)
                return nil
            }
        }
        guard Self.constantTimeEquals(presented, token) else { return nil }
        return generation
    }

    /// Verifies a presented token in constant time.
    ///
    /// Reuses the atomic compare-and-capture so the constant-time comparison
    /// semantics live in exactly one place and a future change cannot weaken one
    /// path while the other still guards the surface.
    /// - Parameter presented: Credential from the header or upgrade query.
    /// - Returns: True only for the live token.
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
    /// incrementing, so repeated guesses cannot extend their own lockout. A
    /// loopback identity is never throttled: the owner shares the machine and
    /// must never be locked out by their own mistyped token.
    /// - Parameters:
    ///   - identity: Client address used to scope the bucket.
    ///   - isLoopback: Whether the identity is exempt from throttling.
    /// - Returns: `Retry-After` seconds when throttled, otherwise nil.
    public func recordFailure(for identity: String, isLoopback: Bool) -> Int? {
        guard !isLoopback else { return nil }
        let now = Date()
        var bucket = failures[identity] ?? FailureBucket(count: 0, windowStart: now, blockedUntil: nil)
        if let blockedUntil = bucket.blockedUntil, blockedUntil > now {
            return Self.secondsRoundedUp(blockedUntil.timeIntervalSince(now))
        }
        if now.timeIntervalSince(bucket.windowStart) > Self.failureWindow {
            bucket = FailureBucket(count: 0, windowStart: now, blockedUntil: nil)
        }
        bucket.count += 1
        if bucket.count >= Self.maxFailures {
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
        while failures.count > Self.maxTrackedIdentities {
            guard let oldest = failures.min(by: { $0.value.windowStart < $1.value.windowStart })?.key else { break }
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
    public static func makeSessionCookie(token: String, isSecure: Bool = false) -> HTTPCookies.Value {
        HTTPCookies.Value(
            string: token,
            expires: nil,
            maxAge: nil,
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
    public static func isRequestSecure(_ request: Request) -> Bool {
        if request.url.scheme?.lowercased() == "https" {
            return true
        }
        if let forwardedProto = request.headers.first(name: "X-Forwarded-Proto") {
            let primary = forwardedProto.split(separator: ",").first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if primary == "https" {
                return true
            }
        }
        return false
    }

    /// Stable client identity for failure buckets.
    ///
    /// The raw socket address is used rather than forwarding headers, which a
    /// caller can spoof to evade throttling. `unknown` means there is no
    /// throttleable peer (in-process or test requests).
    /// - Parameter request: Inbound request.
    /// - Returns: Address string used to scope the failure bucket.
    public static func clientIdentity(for request: Request) -> String {
        request.remoteAddress?.ipAddress ?? "unknown"
    }

    /// Whether an identity is loopback (or absent) and therefore never throttled.
    /// - Parameter identity: Identity from ``clientIdentity(for:)``.
    /// - Returns: True when the owner's own machine is making the request.
    public static func isLoopback(_ identity: String) -> Bool {
        identity == "unknown"
            || identity == "127.0.0.1"
            || identity == "::1"
            || identity.lowercased() == "localhost"
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
        let identity = ServerAuthRequest.clientIdentity(for: request)
        let isLoopback = ServerAuthRequest.isLoopback(identity)
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
        if let presented, let verifiedGeneration = await auth.verifyAndCaptureGeneration(presented) {
            await auth.clearFailures(for: identity)
            request.runeWeaverAuthenticated = true
            request.runeWeaverTokenGeneration = verifiedGeneration
            if isUpgrade {
                // Validate once, then erase the credential before the handshake
                // crosses into route handling so no downstream log captures it.
                ServerAuthRequest.stripPresentedToken(from: request)
            }
            return try await next.respond(to: request)
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
        if let retryAfter = await auth.recordFailure(for: identity, isLoopback: isLoopback) {
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

/// Vapor middleware validating inbound HTTP Host headers to protect against DNS rebinding.
public struct HostValidationMiddleware: AsyncMiddleware, Sendable {
    /// Permitted hosts (lowercased, without port).
    public let allowedHosts: Set<String>
    /// Whether missing Host headers should be permitted in testing environments.
    public let allowMissingHostInTesting: Bool
    /// Whether private-LAN Host values are accepted beside the explicit allowlist.
    ///
    /// True only for an all-interfaces bind (`0.0.0.0`, `::`, or `[::]`) with owner auth
    /// configured, so a loopback-only bind never widens to LAN ranges and an
    /// unauthenticated all-interfaces bind stays fail-closed on the explicit set.
    private let allowsLANRanges: Bool

    /// Creates host validation middleware allowing standard loopback hosts plus the server's configured hostname.
    /// - Parameters:
    ///   - hostname: Configured bind hostname.
    ///   - allowMissingHostInTesting: When true, requests in `.testing` without a Host header are allowed.
    public init(hostname: String, allowMissingHostInTesting: Bool = true) {
        self.init(hostname: hostname, allowedHosts: [], authConfigured: false, allowMissingHostInTesting: allowMissingHostInTesting)
    }

    /// Creates host validation middleware bound to the runtime bind policy plus explicit hosts.
    ///
    /// The bind policy and the Host gate share one decision: an all-interfaces
    /// bind with auth opens the LAN family (loopback, the literal bind, RFC 1918
    /// plus link-local IPv4, IPv6 ULA plus link-local, `.local` names, and the
    /// explicit entries), while any other bind stays strict on loopback plus the
    /// literal plus the explicit entries with no automatic LAN ranges.
    /// - Parameters:
    ///   - hostname: Configured bind hostname.
    ///   - allowedHosts: Explicit `allowed_hosts` entries, matched exact-only after lowercasing plus port stripping.
    ///   - authConfigured: Whether a resolvable owner token guards this bind.
    ///   - allowMissingHostInTesting: When true, requests in `.testing` without a Host header are allowed.
    public init(
        hostname: String,
        allowedHosts explicitHosts: [String],
        authConfigured: Bool,
        allowMissingHostInTesting: Bool = true
    ) {
        var hosts: Set = ["127.0.0.1", "localhost", "::1", "[::1]"]
        let trimmed = hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Trailing FQDN dots never gate: validators reject them fail-closed,
        // so a trailing-dot hostname (including a bare `.`) inserts nothing
        // here and fails closed like any other trailing-dot host instead of
        // riding the gate under a stripped spelling that never matches exactly.
        // Enforce the DNS name bound on the bind hostname so an over-long value
        // never widens the gate; file-load and ServeCommand already reject it,
        // while a hand-built context stays fail-closed here.
        if !trimmed.isEmpty, trimmed != ".", !trimmed.hasSuffix("."), trimmed.count <= ServerEndpointConfig.maxAllowedHostLength {
            hosts.insert(trimmed)
            // Clients send IPv6 literals bracketed or bare, so both spellings are
            // stored to keep the comparison exact without canonicalizing inbound Hosts.
            if trimmed.contains(":") {
                if trimmed.hasPrefix("["), trimmed.hasSuffix("]"), trimmed.count >= 2 {
                    let bare = String(trimmed.dropFirst().dropLast())
                    if !bare.isEmpty {
                        hosts.insert(bare)
                    }
                } else if !trimmed.hasPrefix("[") {
                    hosts.insert("[\(trimmed)]")
                }
            }
        }
        // Single-sourced through `dedupeNormalizedBootHosts` because the
        // explicit entries are already-bounded stored values: the raw count
        // was capped at write time by file-load and the settings PUT (which
        // keep `dedupeNormalizedHosts` for raw input), so re-applying the
        // raw-count prefix here would truncate an already-expanded store —
        // 11 IPv6 entries persist as 22 (bracketed plus bare) and must gate
        // as 22 instead of being cut back to 20. Widening shapes and
        // trailing-dot entries drop fail-closed through the shared
        // `RuneWeaverConfig.validateAllowedHosts` check inside the dedupe
        // instead of allowlisting a carved fragment, and IPv6 counterparts
        // ride along.
        for entry in ServerEndpointConfig.dedupeNormalizedBootHosts(explicitHosts) {
            hosts.insert(entry)
        }
        self.allowedHosts = hosts
        self.allowMissingHostInTesting = allowMissingHostInTesting
        self.allowsLANRanges = Self.isAllInterfacesBind(trimmed) && authConfigured
    }

    /// Whether a bind hostname listens on every interface.
    ///
    /// Only the IPv4 and IPv6 unspecified addresses widen the Host gate; a LAN
    /// IP bind (for example `192.168.1.20`) stays strict on its literal plus the
    /// explicit entries so one device does not implicitly authorize the whole subnet.
    /// - Parameter hostname: Trimmed, lowercased bind hostname.
    /// - Returns: True for `0.0.0.0`, `::`, or `[::]`.
    public static func isAllInterfacesBind(_ hostname: String) -> Bool {
        let trimmed = hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed == "0.0.0.0" || trimmed == "::" || trimmed == "[::]"
    }

    /// Whether a normalized Host is reachable on an authenticated all-interfaces bind.
    ///
    /// Covers only the LAN family the owner implicitly trusts by binding
    /// all-interfaces with auth: private IPv4, ULA plus link-local IPv6, and
    /// `.local` names. Public IPs and DNS names still fail closed to the
    /// explicit allowlist so a rebinding host cannot ride the LAN opening.
    /// - Parameter host: Lowercased, port-stripped Host from ``extractHost(from:)``.
    /// - Returns: True for a LAN-family host.
    public static func isLANAllowedHost(_ host: String) -> Bool {
        guard !host.isEmpty else { return false }
        if isPrivateIPv4LANHost(host) {
            return true
        }
        if isPrivateIPv6LANHost(host) {
            return true
        }
        return isLocalMDNSHost(host)
    }

    /// Whether a normalized Host is private IPv4 (RFC 1918) or link-local.
    ///
    /// Decimal dotted quads only: hex, octal, or short forms never open the LAN
    /// path and stay on the explicit allowlist instead, so obfuscated spellings
    /// cannot slip past the range check. Range membership itself is
    /// single-sourced through the SSRF guard's sensitive-range table so the two
    /// gates cannot drift on RFC 1918 or link-local boundaries; loopback and
    /// the unspecified block are carved out first because they belong on the
    /// explicit allowlist, leaving only the LAN family (`10/8`, `172.16/12`,
    /// `192.168/16`, `169.254/16`). A future range-table change that widens the
    /// shared table must re-audit this carve-out before it can widen the gate.
    /// - Parameter host: Lowercased, port-stripped Host.
    /// - Returns: True for `10/8`, `172.16/12`, `192.168/16`, or `169.254/16`.
    public static func isPrivateIPv4LANHost(_ host: String) -> Bool {
        guard let octets = parseIPv4Octets(host), octets.count == 4 else { return false }
        guard octets[0] != 0, octets[0] != 127 else { return false }
        // Built from the strict octets above rather than re-parsing, so the
        // value tested here is exactly the spelling the shape gate approved.
        let value = (UInt32(octets[0]) << 24) | (UInt32(octets[1]) << 16)
            | (UInt32(octets[2]) << 8) | UInt32(octets[3])
        return ApiSSRFGuard.isSensitiveIPv4Value(value)
    }

    /// Parses a decimal dotted quad without resolver-accepted obfuscation.
    /// - Parameter host: Candidate Host value.
    /// - Returns: Four octets, or nil when the shape is not a plain dotted quad.
    public static func parseIPv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        octets.reserveCapacity(4)
        for part in parts {
            // ASCII digits only: `Character.isNumber` accepts Unicode digits
            // that `Int` would reject inconsistently, so require 0-9 here.
            guard !part.isEmpty, part.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return nil }
            // A leading zero would be ambiguous with octal on some resolvers, so
            // multi-digit zero-prefixed parts stay off the LAN path and fail
            // closed to the explicit allowlist.
            if part.count > 1, part.hasPrefix("0") {
                return nil
            }
            guard let value = Int(part), (0 ... 255).contains(value) else { return nil }
            octets.append(value)
        }
        return octets
    }

    /// Whether a normalized Host is IPv6 ULA (`fc00::/7`) or link-local (`fe80::/10`).
    ///
    /// Bracketed and bare spellings both qualify because ``extractHost(from:)``
    /// preserves the caller's brackets; the zone suffix (`%eth0`) is ignored for
    /// the range decision since it names an interface, not an address change.
    /// - Parameter host: Lowercased, port-stripped Host.
    /// - Returns: True for ULA or link-local literals.
    public static func isPrivateIPv6LANHost(_ host: String) -> Bool {
        var candidate = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if candidate.hasPrefix("["), candidate.hasSuffix("]"), candidate.count >= 2 {
            candidate = String(candidate.dropFirst().dropLast())
        }
        if let percent = candidate.firstIndex(of: "%") {
            candidate = String(candidate[..<percent])
        }
        guard candidate.contains(":"), !candidate.contains(".") else { return false }
        guard let groups = ipv6Hextets(candidate) else { return false }
        // fc00::/7 (Unique Local Address): top seven bits 1111110.
        if (groups[0] & 0xFE00) == 0xFC00 {
            return true
        }
        // fe80::/10 (Link-Local): top ten bits 1111111010.
        if (groups[0] & 0xFFC0) == 0xFE80 {
            return true
        }
        return false
    }

    /// Parses IPv6 text into eight hextets for the ULA plus link-local masks.
    ///
    /// Single-sourced through `ApiSSRFGuard.ipv6Hextets` so the Host gate and
    /// the SSRF guard parse literals identically instead of drifting on a
    /// forked copy; dotted forms stay DNS names here because an embedded IPv4
    /// tail belongs to the IPv4 range check, not this literal path.
    /// - Parameter host: Unbracketed, zoneless, lowercased literal.
    /// - Returns: Eight hextets, or nil when the text is not a plain IPv6 literal.
    public static func ipv6Hextets(_ host: String) -> [UInt16]? {
        ApiSSRFGuard.ipv6Hextets(host)
    }

    /// Whether a normalized Host is a lowercase `.local` mDNS name.
    ///
    /// The input is already lowercased by ``extractHost(from:)``, so the suffix
    /// check itself enforces lowercase; a trailing FQDN dot fails closed to
    /// the explicit allowlist like any other punctuation. Each
    /// dot-separated label must be non-empty, at most 63 characters, and must
    /// not start or end with a dash so shapes like `...local` or `-.local`
    /// never open the LAN path.
    /// - Parameter host: Lowercased, port-stripped Host.
    /// - Returns: True for names ending in `.local`.
    public static func isLocalMDNSHost(_ host: String) -> Bool {
        guard !host.isEmpty else { return false }
        // A trailing FQDN dot never opens the LAN path: validators reject
        // trailing-dot hosts fail-closed, so `studio.local.` stays closed
        // here instead of riding the gate under a stripped spelling.
        let candidate = host
        guard candidate.hasSuffix(".local") else { return false }
        guard candidate.count > ".local".count else { return false }
        guard candidate.count <= 253 else { return false }
        guard !candidate.contains(":"), !candidate.contains("/") else { return false }
        guard !candidate.contains("?"), !candidate.contains("#"), !candidate.contains("@") else { return false }
        guard !candidate.contains(" "), !candidate.contains("\t") else { return false }
        guard !candidate.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-._")
        guard candidate.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        let labels = candidate.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.last == "local" else { return false }
        for label in labels {
            guard !label.isEmpty, label.count <= 63 else { return false }
            guard !label.hasPrefix("-"), !label.hasSuffix("-") else { return false }
        }
        return true
    }

    /// Whether a normalized Host passes this middleware's gate.
    /// - Parameter host: Lowercased, port-stripped Host from ``extractHost(from:)``.
    /// - Returns: True for the explicit allowlist, or for the LAN family when the bind opened it.
    public func isAllowedHost(_ host: String) -> Bool {
        if allowedHosts.contains(host) {
            return true
        }
        guard allowsLANRanges else { return false }
        return Self.isLANAllowedHost(host)
    }

    /// Normalizes and extracts the host component from a raw Host header value.
    /// Single-sourced through `ServerEndpointConfig.normalizeHost` in Core so
    /// the gate, the settings PUT, and file-load validation compare under
    /// identical semantics.
    public static func extractHost(from hostHeader: String) -> String {
        ServerEndpointConfig.normalizeHost(hostHeader)
    }

    public func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard let hostHeader = request.headers.first(name: .host) else {
            if allowMissingHostInTesting, request.application.environment == .testing {
                return try await next.respond(to: request)
            }
            // Route the missing-host branch through the shared security headers
            // so it carries the same nosniff/DENY/referrer policy plus
            // proxy-aware HSTS as every other response.
            let response = Response(
                status: .badRequest,
                headers: HTTPHeaders([
                    ("Content-Type", "application/json; charset=utf-8"),
                    ("Cache-Control", "no-store")
                ]),
                body: .init(string: #"{"error":"missing host header"}"#)
            )
            GlobalSecurityHeadersMiddleware.apply(to: response, for: request)
            return response
        }

        let host = Self.extractHost(from: hostHeader)
        guard isAllowedHost(host) else {
            RuneWeaverLog.server.warning("HostValidationMiddleware rejected invalid Host header: \(hostHeader)")
            // Route the 403 branch through the shared security headers so a
            // rebinding rejection cannot be fingerprinted by missing headers
            // and still carries proxy-aware HSTS when served behind TLS.
            let response = Response(
                status: .forbidden,
                headers: HTTPHeaders([
                    ("Content-Type", "application/json; charset=utf-8"),
                    ("Cache-Control", "no-store")
                ]),
                body: .init(string: #"{"error":"invalid host header"}"#)
            )
            GlobalSecurityHeadersMiddleware.apply(to: response, for: request)
            return response
        }

        return try await next.respond(to: request)
    }
}

/// Middleware injecting defense-in-depth HTTP security headers into all responses.
public struct GlobalSecurityHeadersMiddleware: AsyncMiddleware, Sendable {
    public init() {}

    /// Applies the shared security headers to a response.
    ///
    /// Single-sourced so the Host gate's early rejections carry the same
    /// nosniff/DENY/referrer policy plus proxy-aware HSTS as the middleware
    /// path instead of drifting on a duplicated header list.
    /// - Parameters:
    ///   - response: Response receiving the headers.
    ///   - request: Inbound request deciding proxy-aware HSTS.
    public static func apply(to response: Response, for request: Request) {
        response.headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        response.headers.replaceOrAdd(name: "X-Frame-Options", value: "DENY")
        response.headers.replaceOrAdd(name: "Referrer-Policy", value: "strict-origin-when-cross-origin")
        if ServerAuthRequest.isRequestSecure(request) {
            response.headers.replaceOrAdd(name: "Strict-Transport-Security", value: "max-age=31536000; includeSubDomains")
        }
    }

    public func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let response = try await next.respond(to: request)
        Self.apply(to: response, for: request)
        return response
    }
}

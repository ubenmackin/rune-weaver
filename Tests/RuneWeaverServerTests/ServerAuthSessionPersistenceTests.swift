// Rune Weaver Tests — Durable auth-session store and sliding session lifecycle.
//
// The session store is the persistence seam for browser sessions, so these
// tests pin two contracts: a saved document reloads exactly (schema version,
// owner-token generation, and whole-second timestamps), and a loose, corrupt,
// or unknown-version document is refused with a typed error instead of being
// trusted. The sliding-session suite then exercises the verifier that owns the
// store — digests-only persistence, the 24h idle window, cookie-renewal
// throttling, LRU cap eviction, and restart/rotation handling. Every case runs
// against an isolated temp directory, so no real credential or session file is
// touched.

import CryptoKit
import Foundation
import os
import RuneWeaverCore
@testable import RuneWeaverServer
import Testing

/// Builds an isolated session-store fixture: a `0700` temp directory plus the
/// `auth-sessions.json` path inside it, deliberately not created so each test
/// controls the initial state the store sees.
private func makeSessionStoreFixture() throws -> (directory: URL, fileURL: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("runeweaver-sessions-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    let fileURL = directory.appendingPathComponent(ServerAuthSessionStore.fileName)
    return (directory, fileURL)
}

/// Two distinct entries so multi-session encoding and key ordering are exercised.
private func sampleSessions() -> [PersistedAuthSession] {
    [
        PersistedAuthSession(
            digest: String(repeating: "a", count: 64),
            generation: 7,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastSeenAt: Date(timeIntervalSince1970: 1_700_000_090),
            cookieRefreshedAt: Date(timeIntervalSince1970: 1_700_000_030)
        ),
        PersistedAuthSession(
            digest: String(repeating: "b", count: 64),
            generation: 7,
            createdAt: Date(timeIntervalSince1970: 1_700_000_100),
            lastSeenAt: Date(timeIntervalSince1970: 1_700_000_200),
            cookieRefreshedAt: Date(timeIntervalSince1970: 1_700_000_150)
        )
    ]
}

/// Builds a representative persisted state from whole-second timestamps so the
/// `.secondsSince1970` codec round-trips without sub-second drift.
private func sampleState(
    generation: Int,
    sessions: [PersistedAuthSession]
) -> PersistedAuthSessions {
    PersistedAuthSessions(generation: generation, sessions: sessions)
}

/// Writes a fixture file with an explicit mode, mirroring how a loose or
/// hand-edited session file reaches the store.
private func writeSessionFile(
    _ contents: Data,
    to fileURL: URL,
    permissions: Int = 0o600
) throws {
    try contents.write(to: fileURL)
    try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: fileURL.path)
}

@Suite("Server Auth Session Store")
struct ServerAuthSessionStoreTests {
    @Test
    func `Round trip preserves version generation and whole-second dates`() throws {
        let (directory, fileURL) = try makeSessionStoreFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ServerAuthSessionStore(fileURL: fileURL)
        let state = sampleState(generation: 7, sessions: sampleSessions())

        try store.save(state)
        let loaded = try store.load()

        #expect(loaded == state)
        #expect(loaded?.version == PersistedAuthSessions.currentVersion)
        #expect(loaded?.generation == 7)
        #expect(loaded?.sessions.count == 2)
        #expect(loaded?.sessions.first?.lastSeenAt == Date(timeIntervalSince1970: 1_700_000_090))
        #expect(loaded?.sessions.first?.digest == String(repeating: "a", count: 64))
    }

    @Test
    func `Saved file is 0600 inside a 0700 directory`() throws {
        let (directory, fileURL) = try makeSessionStoreFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ServerAuthSessionStore(fileURL: fileURL)

        try store.save(sampleState(generation: 7, sessions: sampleSessions()))

        let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileMode = (fileAttributes[.posixPermissions] as? NSNumber)?.intValue
        #expect(fileMode == 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let directoryMode = (directoryAttributes[.posixPermissions] as? NSNumber)?.intValue
        #expect(directoryMode == 0o700)
    }

    @Test
    func `Missing file loads nil`() throws {
        let (directory, fileURL) = try makeSessionStoreFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ServerAuthSessionStore(fileURL: fileURL)

        #expect(try store.load() == nil)
    }

    @Test
    func `Loose file permissions fail closed as insecure sessions file`() throws {
        // A session file another local account could read must be refused even
        // though its contents are digests: the owner-only boundary stays
        // uniform across every restricted file.
        let (directory, fileURL) = try makeSessionStoreFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ServerAuthSessionStore(fileURL: fileURL)
        let contents = Data(#"{"version":1,"generation":0,"sessions":[]}"#.utf8)
        try writeSessionFile(contents, to: fileURL, permissions: 0o644)

        do {
            _ = try store.load()
            Issue.record("Expected insecureSessionsFile for a group/other-readable session file")
        } catch let error as ServerAuthError {
            guard case let .insecureSessionsFile(path) = error else {
                Issue.record("Expected insecureSessionsFile, got \(error)")
                return
            }
            #expect(path == fileURL.path)
            #expect(error.errorDescription?.isEmpty == false)
        }
    }

    @Test
    func `Corrupt JSON fails closed as unreadable`() throws {
        let (directory, fileURL) = try makeSessionStoreFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ServerAuthSessionStore(fileURL: fileURL)
        try writeSessionFile(Data("{ not valid json".utf8), to: fileURL)

        do {
            _ = try store.load()
            Issue.record("Expected sessionStoreUnreadable for malformed JSON")
        } catch let error as ServerAuthError {
            guard case let .sessionStoreUnreadable(path) = error else {
                Issue.record("Expected sessionStoreUnreadable, got \(error)")
                return
            }
            #expect(path == fileURL.path)
            #expect(error.errorDescription?.isEmpty == false)
        }
    }

    @Test
    func `Unknown schema version fails closed as unreadable`() throws {
        // A future schema must never be decoded under today's semantics, so it
        // is refused exactly like corrupt bytes rather than losing fields.
        let (directory, fileURL) = try makeSessionStoreFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ServerAuthSessionStore(fileURL: fileURL)
        try store.save(PersistedAuthSessions(version: 2, generation: 7, sessions: sampleSessions()))

        do {
            _ = try store.load()
            Issue.record("Expected sessionStoreUnreadable for an unknown schema version")
        } catch let error as ServerAuthError {
            guard case let .sessionStoreUnreadable(path) = error else {
                Issue.record("Expected sessionStoreUnreadable, got \(error)")
                return
            }
            #expect(path == fileURL.path)
        }
    }

    @Test
    func `Disabled store never touches disk`() throws {
        // A nil fileURL is the explicit no-persistence posture: loads report no
        // state and saves are a no-op, so nothing appears beside the fixture.
        let (directory, fileURL) = try makeSessionStoreFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ServerAuthSessionStore(fileURL: nil)

        #expect(try store.load() == nil)
        try store.save(sampleState(generation: 7, sessions: sampleSessions()))
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(contents.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fileURL.path) == false)
    }
}

/// Test-only clock for the sliding-session suite: a mutable instant the tests
/// move explicitly, so idle expiry, cookie-renewal throttling, and persistence
/// coalescing are deterministic instead of sleeping against wall time.
private final class TestClock: Sendable {
    private let box: OSAllocatedUnfairLock<Date>

    /// Current instant handed to the verifier through its injected clock.
    var now: Date {
        box.withLock { $0 }
    }

    /// Creates a clock pinned to a whole-second instant so `.secondsSince1970`
    /// persistence round-trips byte-for-byte.
    init(now: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.box = OSAllocatedUnfairLock(initialState: now)
    }

    /// Moves the clock forward, as if that much wall time had passed.
    /// - Parameter interval: Seconds to advance by.
    func advance(_ interval: TimeInterval) {
        box.withLock { $0 = $0.addingTimeInterval(interval) }
    }
}

/// SHA-256 hex digest of a session token, mirroring the verifier's keying so a
/// staged file can target a token without ever persisting the raw value.
/// - Parameter token: Raw session token.
/// - Returns: 64 lowercase hex characters.
private func sessionDigestHex(_ token: String) -> String {
    let digest = SHA256.hash(data: Data(token.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}

/// Builds a verifier over an isolated token file plus a temp session file, wired
/// to a deterministic clock.
///
/// `persistedSessions` is staged through the real store before construction, so
/// a test can hand the verifier a prewritten document (restart, retired
/// generation, and load-time pruning cases); a nil value leaves the session file
/// absent. The token file is always `0600` inside a `0700` directory, so
/// rotation never touches a developer's real credential.
/// - Parameters:
///   - clock: Deterministic clock injected into the verifier.
///   - token: Live owner token to initialize the verifier with.
///   - persistedSessions: Optional document to stage before the verifier loads.
/// - Returns: The verifier, its token store, the fixture directory, and the session file path.
private func makeSlidingSessionAuth(
    clock: TestClock,
    token: String = "owner-token",
    persistedSessions: PersistedAuthSessions? = nil
) throws -> (auth: ServerAuth, tokenStore: ServerAuthTokenStore, directory: URL, sessionFileURL: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("runeweaver-sliding-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    let tokenFileURL = directory.appendingPathComponent("auth_token")
    let sessionFileURL = directory.appendingPathComponent(ServerAuthSessionStore.fileName)
    if let persistedSessions {
        try ServerAuthSessionStore(fileURL: sessionFileURL).save(persistedSessions)
    }
    try token.write(to: tokenFileURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFileURL.path)
    // Keep the shared default environment override out of the picture so a
    // rotation under test is never refused by an operator's shell export.
    _ = unsetenv(AuthConfig.defaultTokenKey)
    let tokenStore = ServerAuthTokenStore(
        authConfig: AuthConfig(
            tokenEnv: "RUNEWEAVER_AUTH_TEST_UNSET_\(UUID().uuidString)",
            tokenFile: tokenFileURL.path
        ),
        service: "com.runeweaver.tests.\(UUID().uuidString)",
        inMemory: true
    )
    let auth = ServerAuth(
        initialToken: token,
        store: tokenStore,
        sessionStore: ServerAuthSessionStore(fileURL: sessionFileURL),
        now: { clock.now }
    )
    return (auth, tokenStore, directory, sessionFileURL)
}

@Suite("Server Auth Sliding Sessions")
struct ServerAuthSlidingSessionTests {
    @Test
    func `Sessions persist as digests and verify as browser sessions`() async throws {
        let clock = TestClock()
        let (auth, _, directory, sessionFileURL) = try makeSlidingSessionAuth(clock: clock)
        defer { try? FileManager.default.removeItem(at: directory) }

        let session = try await auth.createSession()
        #expect(await auth.verify(session))
        let presentation = try #require(await auth.verifyAndCaptureGeneration(session))
        #expect(presentation.kind == .browserSession)

        // The durable document is the only artifact a restart reads, so it must
        // carry the digest and never either raw credential.
        let persistedText = try String(contentsOf: sessionFileURL, encoding: .utf8)
        #expect(persistedText.contains(session) == false)
        #expect(persistedText.contains("owner-token") == false)
        #expect(persistedText.contains("\"digest\":\"") == true)
    }

    @Test
    func `An idle session dies once the sliding window lapses`() async throws {
        let clock = TestClock()
        let (auth, _, directory, _) = try makeSlidingSessionAuth(clock: clock)
        defer { try? FileManager.default.removeItem(at: directory) }

        let session = try await auth.createSession()
        #expect(await auth.verify(session))
        clock.advance(ServerAuth.sessionIdleTimeoutSeconds + 1)
        #expect(await auth.verify(session) == false)
        #expect(await auth.hasActiveSession(session) == false)
    }

    @Test
    func `Activity slides the idle window without an absolute cap`() async throws {
        let clock = TestClock()
        let (auth, _, directory, _) = try makeSlidingSessionAuth(clock: clock)
        defer { try? FileManager.default.removeItem(at: directory) }

        let session = try await auth.createSession()
        clock.advance(20 * 3600)
        #expect(await auth.verify(session))
        clock.advance(20 * 3600)
        #expect(await auth.verify(session))
        // A session active past the original creation-plus-timeout moment still
        // dies only after a full idle window with zero requests.
        clock.advance(ServerAuth.sessionIdleTimeoutSeconds + 1)
        #expect(await auth.verify(session) == false)
        #expect(await auth.hasActiveSession(session) == false)
    }

    @Test
    func `Cookie renewal is throttled to the renewal interval`() async throws {
        let clock = TestClock()
        let (auth, _, directory, _) = try makeSlidingSessionAuth(clock: clock)
        defer { try? FileManager.default.removeItem(at: directory) }

        let session = try await auth.createSession()
        let initial = try #require(await auth.verifyAndCaptureGeneration(session))
        #expect(initial.shouldRefreshSessionCookie == false)

        clock.advance(ServerAuth.sessionCookieRenewalIntervalSeconds + 1)
        let renewed = try #require(await auth.verifyAndCaptureGeneration(session))
        #expect(renewed.shouldRefreshSessionCookie == true)

        // The renewal stamped `cookieRefreshedAt`, so an immediate repeat must
        // not re-issue the cookie again.
        let repeated = try #require(await auth.verifyAndCaptureGeneration(session))
        #expect(repeated.shouldRefreshSessionCookie == false)

        clock.advance(ServerAuth.sessionCookieRenewalIntervalSeconds * 2 + 2)
        let renewedAgain = try #require(await auth.verifyAndCaptureGeneration(session))
        #expect(renewedAgain.shouldRefreshSessionCookie == true)
    }

    @Test
    func `Owner token verifies as an owner presentation without a cookie refresh`() async throws {
        let clock = TestClock()
        let (auth, _, directory, _) = try makeSlidingSessionAuth(clock: clock)
        defer { try? FileManager.default.removeItem(at: directory) }

        let presentation = try #require(await auth.verifyAndCaptureGeneration("owner-token"))
        #expect(presentation.kind == .ownerToken)
        #expect(presentation.shouldRefreshSessionCookie == false)
        let generation = await auth.currentGeneration()
        #expect(presentation.generation == generation)
    }

    @Test
    func `The cap evicts the least recently seen session`() async throws {
        let clock = TestClock()
        let (auth, _, directory, _) = try makeSlidingSessionAuth(clock: clock)
        defer { try? FileManager.default.removeItem(at: directory) }

        var sessions: [String] = []
        for _ in 0 ..< 100 {
            try await sessions.append(auth.createSession())
            clock.advance(1)
        }
        // Touching the first session makes it more recent than the second, so
        // the overflow mint must evict the stalest last-seen entry instead of
        // the oldest creation.
        #expect(await auth.verify(sessions[0]))

        let newest = try await auth.createSession()
        #expect(await auth.verify(sessions[0]))
        #expect(await auth.verify(sessions[99]))
        #expect(await auth.verify(newest))
        #expect(await auth.verify(sessions[1]) == false)
        #expect(await auth.hasActiveSession(sessions[1]) == false)
    }

    @Test
    func `A restarted verifier accepts an unexpired persisted session`() async throws {
        let clock = TestClock()
        let (auth, tokenStore, directory, sessionFileURL) = try makeSlidingSessionAuth(clock: clock)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Rotate first so the restored generation is demonstrably not the
        // process default, then mint the one session the restart must honor.
        let rotatedToken = try await auth.rotate()
        let session = try await auth.createSession()

        let restarted = ServerAuth(
            initialToken: rotatedToken,
            store: tokenStore,
            sessionStore: ServerAuthSessionStore(fileURL: sessionFileURL),
            now: { clock.now }
        )
        #expect(await restarted.currentGeneration() == 1)
        #expect(await restarted.verify(session))
        #expect(await restarted.hasActiveSession(session))
    }

    @Test
    func `Rotation clears persisted sessions and advances the generation`() async throws {
        let clock = TestClock()
        let (auth, tokenStore, directory, sessionFileURL) = try makeSlidingSessionAuth(clock: clock)
        defer { try? FileManager.default.removeItem(at: directory) }

        let session = try await auth.createSession()
        let rotatedToken = try await auth.rotate()

        let store = ServerAuthSessionStore(fileURL: sessionFileURL)
        let persisted = try #require(try store.load())
        #expect(persisted.sessions.isEmpty)
        #expect(persisted.generation == 1)

        // A fresh process over the rotated file must reject the retired session
        // instead of resurrecting it from a stale cookie.
        let restarted = ServerAuth(
            initialToken: rotatedToken,
            store: tokenStore,
            sessionStore: ServerAuthSessionStore(fileURL: sessionFileURL),
            now: { clock.now }
        )
        #expect(await restarted.verify(session) == false)
        #expect(await restarted.hasActiveSession(session) == false)
    }

    @Test
    func `An entry expired at load is dropped`() async throws {
        let clock = TestClock()
        let sessionToken = "expired-persisted-session"
        let idleAge = ServerAuth.sessionIdleTimeoutSeconds + 1
        let expiredEntry = PersistedAuthSession(
            digest: sessionDigestHex(sessionToken),
            generation: 0,
            createdAt: clock.now.addingTimeInterval(-idleAge),
            lastSeenAt: clock.now.addingTimeInterval(-idleAge),
            cookieRefreshedAt: clock.now.addingTimeInterval(-idleAge)
        )
        let (auth, _, directory, _) = try makeSlidingSessionAuth(
            clock: clock,
            persistedSessions: PersistedAuthSessions(generation: 0, sessions: [expiredEntry])
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(await auth.verify(sessionToken) == false)
        #expect(await auth.hasActiveSession(sessionToken) == false)
    }

    @Test
    func `An entry from a retired generation is dropped at load`() async throws {
        let clock = TestClock()
        let sessionToken = "retired-generation-session"
        let retiredEntry = PersistedAuthSession(
            digest: sessionDigestHex(sessionToken),
            generation: 1,
            createdAt: clock.now,
            lastSeenAt: clock.now,
            cookieRefreshedAt: clock.now
        )
        let (auth, _, directory, _) = try makeSlidingSessionAuth(
            clock: clock,
            persistedSessions: PersistedAuthSessions(generation: 2, sessions: [retiredEntry])
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        // The persisted generation is resumed before the stale entry is judged,
        // so the mismatch is exactly what drops it.
        #expect(await auth.currentGeneration() == 2)
        #expect(await auth.verify(sessionToken) == false)
        #expect(await auth.hasActiveSession(sessionToken) == false)
    }

    @Test
    func `Touch persistence coalesces until the interval elapses`() async throws {
        let clock = TestClock()
        let (auth, _, directory, sessionFileURL) = try makeSlidingSessionAuth(clock: clock)
        defer { try? FileManager.default.removeItem(at: directory) }

        let session = try await auth.createSession()
        let store = ServerAuthSessionStore(fileURL: sessionFileURL)
        let created = try #require(try store.load())
        #expect(created.sessions.count == 1)
        #expect(created.sessions.first?.lastSeenAt == clock.now)

        // A touch inside the coalesce window slides memory but must not rewrite
        // the file, so an active browser does not force a write per request.
        clock.advance(10)
        #expect(await auth.verify(session))
        let coalesced = try #require(try store.load())
        #expect(coalesced.sessions.first?.lastSeenAt == created.sessions.first?.lastSeenAt)

        // Once the interval has elapsed the next touch persists the fresh
        // `lastSeenAt`, so a restart resumes the slid window.
        clock.advance(ServerAuth.sessionPersistenceCoalesceSeconds - 10 + 1)
        #expect(await auth.verify(session))
        let flushed = try #require(try store.load())
        #expect(flushed.sessions.first?.lastSeenAt == clock.now)
    }
}

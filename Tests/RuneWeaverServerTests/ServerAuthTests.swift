// Rune Weaver Tests — Owner bearer auth: bind policy, token lifecycle, and the
// middleware trust boundary.
//
// Rune Weaver is single-owner by design, so these tests pin the fail-closed
// contract that protects a non-loopback bind: a LAN address never serves unless
// a verifier resolved, every rejected request answers identically without
// echoing the credential, throttling only ever touches a non-loopback peer, and
// rotation stays reachable only through the gate it replaces. Requests are
// driven in-process through the middleware and a local responder so no socket is
// bound and no real token store is touched beyond an isolated temp directory.

import Foundation
import NIOCore
import NIOWebSocket
import RuneWeaverCore
@testable import RuneWeaverServer
import Testing
import Vapor

/// Canned downstream responder used to observe whether the gate forwarded a
/// request and whether it marked the request authenticated.
private struct AuthProbeResponder: AsyncResponder, Sendable {
    func respond(to request: Request) async throws -> Response {
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: "X-Probe-Authenticated", value: request.runeWeaverAuthenticated ? "true" : "false")
        headers.replaceOrAdd(name: "X-Probe-Query", value: request.url.query ?? "")
        return Response(status: .ok, headers: headers, body: .init(string: "probe"))
    }
}

/// Test double for a hub socket that records close calls without a live
/// network handshake, so rotation revocation is directly observable.
private actor RecordingSocket: WSConnectionSocket {
    /// Whether the hub has closed this connection.
    var closed = false
    /// Status code passed to the most recent `close(code:)`, so a revocation
    /// can be distinguished from a clean drain.
    var lastCloseCode: WebSocketErrorCode?

    func send(_: String) async throws {}

    func close(code: WebSocketErrorCode) async throws {
        closed = true
        lastCloseCode = code
    }
}

/// File manager whose permission lookup always fails, used to prove the
/// restricted-file guard fails closed when a file's mode cannot be verified.
private final class UnreadableAttributesFileManager: FileManager {
    override func attributesOfItem(atPath _: String) throws -> [FileAttributeKey: Any] {
        throw CocoaError(.fileReadNoPermission)
    }
}

/// Builds an isolated `0600` token file so resolution and rotation never touch a
/// developer's real credential. The surrounding directory is `0700`, matching
/// the mode `ServerAuthTokenStore` writes.
private func makeTokenFile(
    contents: String,
    permissions: Int = 0o600
) throws -> (directory: URL, fileURL: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("runeweaver-auth-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    let fileURL = directory.appendingPathComponent("auth_token")
    try contents.write(to: fileURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: fileURL.path)
    return (directory, fileURL)
}

/// Makes a verifier whose persistence target is an isolated temp token file and in-memory secrets store.
private func makeAuth(
    token: String = "owner-token"
) throws -> (auth: ServerAuth, directory: URL, fileURL: URL) {
    let (directory, fileURL) = try makeTokenFile(contents: token)
    let store = ServerAuthTokenStore(
        authConfig: AuthConfig(tokenEnv: "RUNEWEAVER_AUTH_TEST_UNSET", tokenFile: fileURL.path),
        service: "com.runeweaver.tests.\(UUID().uuidString)",
        inMemory: true
    )
    return (ServerAuth(initialToken: token, store: store), directory, fileURL)
}

/// Creates an application for in-process request construction and shutdown.
private func withTestApp<T>(_ body: (Application) async throws -> T) async throws -> T {
    let app = try await Application.make(.testing)
    do {
        let value = try await body(app)
        try await app.asyncShutdown()
        return value
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
}

/// Builds a request without touching a socket.
private func makeRequest(
    app: Application,
    method: HTTPMethod = .GET,
    path: String,
    headers: HTTPHeaders = .init(),
    remoteAddress: SocketAddress? = nil
) -> Request {
    Request(
        application: app,
        method: method,
        url: URI(string: path),
        headers: headers,
        remoteAddress: remoteAddress,
        on: app.eventLoopGroup.next()
    )
}

/// Materializes a throwaway on-disk bundle so the public-path classifier is
/// exercised against real files rather than extension strings. Each entry is a
/// bundle-relative path; parent directories are created as needed.
private func makeBundle(files: [String]) throws -> (bundle: DashboardBundle, directory: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("runeweaver-bundle-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for relative in files {
        let fileURL = directory.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("bundle-fixture".utf8).write(to: fileURL)
    }
    return (DashboardBundle(directoryURL: directory), directory)
}

/// The upgrade handshake headers a browser sends before a WebSocket is granted.
private let webSocketUpgradeHeaders = HTTPHeaders([
    ("Connection", "Upgrade"),
    ("Upgrade", "websocket"),
    ("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ=="),
    ("Sec-WebSocket-Version", "13")
])

@Suite("Server Auth Bind Policy")
struct ServerAuthBindPolicyTests {
    @Test
    func `Loopback binds with and without owner auth`() throws {
        // The owner's own machine always serves; a resolved token is optional.
        try ServerConfig(hostname: "127.0.0.1", port: 8082, authConfigured: false).requireBindable()
        try ServerConfig(hostname: "localhost", port: 8082, authConfigured: false).requireBindable(authConfigured: false)
        try ServerConfig(hostname: "127.0.0.1", port: 8082, authConfigured: true).requireBindable(authConfigured: true)
    }

    @Test
    func `Non-loopback refuses without auth and binds with auth`() throws {
        // The refusal is the auth-before-exposure rule: a LAN bind must never be
        // a silent downgrade to an unauthenticated surface.
        do {
            try ServerConfig(hostname: "192.168.1.20", port: 8082, authConfigured: false).requireBindable()
            Issue.record("Expected nonLoopbackRefused for an unauthenticated LAN bind")
        } catch let error as ServerConfigError {
            guard case let .nonLoopbackRefused(host) = error else {
                Issue.record("Expected nonLoopbackRefused, got \(error)")
                return
            }
            #expect(host == "192.168.1.20")
        }
        try ServerConfig(hostname: "192.168.1.20", port: 8082, authConfigured: true).requireBindable(authConfigured: true)
    }
}

@Suite("Server Auth Token Lifecycle")
struct ServerAuthTokenLifecycleTests {
    @Test
    func `Resolve returns nil without a source and a verifier from a restricted file`() async throws {
        // Unique namespace + unset env keeps this hermetic: neither the real
        // Keychain service nor a developer's token file is consulted.
        let emptyService = "com.runeweaver.tests.\(UUID().uuidString)"
        let absent = try await ServerAuth.resolve(
            authConfig: AuthConfig(tokenEnv: "RUNEWEAVER_AUTH_TEST_UNSET_\(UUID().uuidString)", tokenFile: nil),
            service: emptyService,
            inMemory: true
        )
        #expect(absent == nil)

        let (directory, fileURL) = try makeTokenFile(contents: "file-token")
        defer { try? FileManager.default.removeItem(at: directory) }
        let resolved = try await ServerAuth.resolve(
            authConfig: AuthConfig(tokenEnv: "RUNEWEAVER_AUTH_TEST_UNSET_\(UUID().uuidString)", tokenFile: fileURL.path),
            service: "com.runeweaver.tests.\(UUID().uuidString)",
            inMemory: true
        )
        let auth = try #require(resolved)
        #expect(await auth.verify("file-token"))
        #expect(await auth.verify("other-token") == false)
    }

    @Test
    func `Loose token file permissions fail closed`() async throws {
        // A credential another local account could read would silently widen the
        // owner-only boundary, so resolution refuses it instead of warning.
        let (directory, fileURL) = try makeTokenFile(contents: "leaky-token", permissions: 0o644)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            _ = try await ServerAuth.resolve(
                authConfig: AuthConfig(tokenEnv: "RUNEWEAVER_AUTH_TEST_UNSET_\(UUID().uuidString)", tokenFile: fileURL.path),
                service: "com.runeweaver.tests.\(UUID().uuidString)",
                inMemory: true
            )
            Issue.record("Expected insecureTokenFile for a group/other-readable token file")
        } catch let error as ServerAuthError {
            guard case .insecureTokenFile = error else {
                Issue.record("Expected insecureTokenFile, got \(error)")
                return
            }
        }
    }

    @Test
    func `Verify accepts only the live token`() async throws {
        let (auth, directory, _) = try makeAuth(token: "alpha-token")
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(await auth.verify("alpha-token"))
        #expect(await auth.verify("beta-token") == false)
        #expect(await auth.verify("Alpha-token") == false)
        #expect(await auth.verify("") == false)
    }

    @Test
    func `Rotate retires the previous token and persists the new value`() async throws {
        let (auth, directory, fileURL) = try makeAuth(token: "first-token")
        defer { try? FileManager.default.removeItem(at: directory) }

        let rotated = try await auth.rotate()
        #expect(rotated.isEmpty == false)
        #expect(rotated != "first-token")
        #expect(await auth.verify("first-token") == false)
        #expect(await auth.verify(rotated))

        // A second rotation replaces the first, proving the live value is
        // swapped rather than accumulated.
        let second = try await auth.rotate()
        #expect(second != rotated)
        #expect(await auth.verify(rotated) == false)
        #expect(await auth.verify(second))

        let persisted = try String(contentsOf: fileURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(persisted == second)
    }

    @Test
    func `Rotation advances the token generation that retires older sockets`() async throws {
        // A socket records the generation it upgraded under; advancing the
        // counter on rotation is what lets the frame loop drop it.
        let (auth, directory, _) = try makeAuth(token: "first-token")
        defer { try? FileManager.default.removeItem(at: directory) }
        let initial = await auth.currentGeneration()
        #expect(await auth.isCurrentGeneration(initial))
        _ = try await auth.rotate()
        #expect(await auth.isCurrentGeneration(initial) == false)
        let advanced = await auth.currentGeneration()
        #expect(advanced == initial + 1)
        #expect(await auth.isCurrentGeneration(advanced))
    }

    @Test
    func `Verify and capture never stamps a retired token with the new generation`() async throws {
        // The token comparison and the generation read must share one actor hop.
        // If they were separate, a rotation landing between them would return the
        // new generation for a request authenticated with the retired token, and
        // a socket stamped with it would pass the hub watermark and the per-frame
        // check instead of being refused.
        let (auth, directory, _) = try makeAuth(token: "first-token")
        defer { try? FileManager.default.removeItem(at: directory) }

        // Deterministic pre-rotation capture: the generation of the live token.
        let captured = try #require(await auth.verifyAndCaptureGeneration("first-token"))
        #expect(captured == 0)
        #expect(await auth.verifyAndCaptureGeneration("first-token") == captured)
        #expect(await auth.verifyAndCaptureGeneration("stale-token") == nil)
        #expect(await auth.verifyAndCaptureGeneration("") == nil)

        // Stress the verify-to-capture window: rotate while captures are in
        // flight. A retired token may only ever report the generation it verified
        // under, never the one the rotation advances to; an empty result is a
        // post-rotation rejection, which is also correct.
        let rotation = Task { try await auth.rotate() }
        var observed: Set<Int> = []
        for _ in 0 ..< 200 {
            if let generation = await auth.verifyAndCaptureGeneration("first-token") {
                observed.insert(generation)
            }
        }
        let minted = try await rotation.value
        #expect(observed.isSubset(of: [captured]))

        // Once the rotation lands, the captured generation is retired, the
        // replacement captures the advanced generation, and the hub refuses a
        // socket stamped with the retired value. That refusal is what keeps an
        // upgrade authenticated by the retired token from being registered.
        #expect(await auth.isCurrentGeneration(captured) == false)
        let advanced = try #require(await auth.verifyAndCaptureGeneration(minted))
        #expect(advanced == captured + 1)
        #expect(await auth.isCurrentGeneration(advanced))

        let hub = WSHub()
        let socket = RecordingSocket()
        // A rotation raises the hub watermark to the generation live afterwards,
        // so a socket stamped with the retired value is refused at registration.
        await hub.retire(liveGeneration: advanced)
        let accepted = await hub.add(id: UUID(), box: socket, generation: captured)
        #expect(accepted == false)
        #expect(await hub.count() == 0)
    }

    @Test
    func `Failed Keychain write refuses rotation instead of reverting on restart`() async throws {
        // Resolution consults the Keychain before the file, so a rotation that
        // only wrote the file could resurrect a stale Keychain value after a
        // restart and reject the replacement. An empty Keychain namespace makes
        // the write fail deterministically.
        let (directory, fileURL) = try makeTokenFile(contents: "first-token")
        defer { try? FileManager.default.removeItem(at: directory) }
        // Keep the default env override out of the picture so the Keychain is
        // unambiguously the effective source.
        _ = unsetenv(AuthConfig.defaultTokenKey)
        let store = ServerAuthTokenStore(
            authConfig: AuthConfig(
                tokenEnv: "RUNEWEAVER_AUTH_TEST_UNSET_\(UUID().uuidString)",
                tokenFile: fileURL.path
            ),
            service: ""
        )
        let auth = ServerAuth(initialToken: "first-token", store: store)
        do {
            _ = try await auth.rotate()
            Issue.record("Expected tokenStorageFailed when the Keychain is the effective source and did not persist")
        } catch let error as ServerAuthError {
            guard case .tokenStorageFailed = error else {
                Issue.record("Expected tokenStorageFailed, got \(error)")
                return
            }
        }
        // Fail closed: a partial persist never swaps the live credential.
        #expect(await auth.verify("first-token"))
    }

    @Test
    func `Rotation is refused while an environment override is live`() async throws {
        // A live environment override wins resolution on the next boot, so a
        // rotation it cannot replace would report success and then silently
        // revert. Refuse it up front and name the variable instead of minting a
        // credential that cannot hold.
        let (directory, fileURL) = try makeTokenFile(contents: "first-token")
        defer { try? FileManager.default.removeItem(at: directory) }
        let envName = "RUNEWEAVER_AUTH_TEST_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        _ = setenv(envName, "override-token", 1)
        defer { _ = unsetenv(envName) }
        let store = ServerAuthTokenStore(
            authConfig: AuthConfig(tokenEnv: envName, tokenFile: fileURL.path),
            service: ""
        )
        let auth = ServerAuth(initialToken: "first-token", store: store)
        do {
            _ = try await auth.rotate()
            Issue.record("Expected environmentOverrideActive while an environment override is live")
        } catch let error as ServerAuthError {
            guard case let .environmentOverrideActive(name) = error else {
                Issue.record("Expected environmentOverrideActive, got \(error)")
                return
            }
            #expect(name == envName)
        }
        // Fail closed: the live credential and the persisted value are untouched.
        #expect(await auth.verify("first-token"))
        #expect(await auth.currentGeneration() == 0)
        let persisted = try String(contentsOf: fileURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(persisted == "first-token")
    }

    @Test
    func `Unreadable token file permissions fail closed`() throws {
        // An unverifiable mode is indistinguishable from a loose one, so the
        // guard must refuse to read the token rather than fall through when the
        // attribute lookup (or its cast) fails.
        let (directory, fileURL) = try makeTokenFile(contents: "guarded-token")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            _ = try ServerAuthTokenStore.readRestrictedFile(
                fileURL,
                fileManager: UnreadableAttributesFileManager()
            )
            Issue.record("Expected insecureTokenFile when the permission mode cannot be read")
        } catch let error as ServerAuthError {
            guard case .insecureTokenFile = error else {
                Issue.record("Expected insecureTokenFile, got \(error)")
                return
            }
        }
    }
}

@Suite("Server Auth Middleware")
struct ServerAuthMiddlewareTests {
    @Test
    func `Valid bearer is forwarded and marks the request`() async throws {
        try await withTestApp { app in
            let (auth, directory, _) = try makeAuth()
            defer { try? FileManager.default.removeItem(at: directory) }
            let middleware = ServerAuthMiddleware(auth: auth)
            let request = makeRequest(
                app: app,
                path: "/settings",
                headers: ["Authorization": "Bearer owner-token"]
            )
            let response = try await middleware.respond(to: request, chainingTo: AuthProbeResponder())
            #expect(response.status == .ok)
            #expect(response.headers.first(name: "X-Probe-Authenticated") == "true")
        }
    }

    @Test
    func `Missing and wrong credentials answer with one uniform 401`() async throws {
        try await withTestApp { app in
            let (auth, directory, _) = try makeAuth()
            defer { try? FileManager.default.removeItem(at: directory) }
            let middleware = ServerAuthMiddleware(auth: auth)

            let missing = try await middleware.respond(
                to: makeRequest(app: app, path: "/settings"),
                chainingTo: AuthProbeResponder()
            )
            #expect(missing.status == .unauthorized)
            let unauthorizedBody = missing.body.string ?? ""
            #expect(unauthorizedBody == #"{"error":"unauthorized"}"#)
            #expect(missing.headers.first(name: "WWW-Authenticate")?.contains("Bearer") == true)
            #expect(missing.headers.first(name: "Cache-Control") == "no-store")

            let presented = "intruder-secret-token"
            let wrong = try await middleware.respond(
                to: makeRequest(app: app, path: "/settings", headers: ["Authorization": "Bearer \(presented)"]),
                chainingTo: AuthProbeResponder()
            )
            // A caller must not be able to tell a missing credential from a wrong
            // one, and the presented value must never be echoed back.
            let wrongBody = wrong.body.string ?? ""
            #expect(wrong.status == .unauthorized)
            #expect(wrongBody == unauthorizedBody)
            #expect(wrongBody.contains(presented) == false)
            #expect(wrong.headers.contains { $0.value.contains(presented) } == false)
        }
    }

    @Test
    func `WebSocket upgrade is refused without a credential`() async throws {
        try await withTestApp { app in
            let (auth, directory, _) = try makeAuth()
            defer { try? FileManager.default.removeItem(at: directory) }
            let middleware = ServerAuthMiddleware(auth: auth)
            let response = try await middleware.respond(
                to: makeRequest(app: app, path: "/ws", headers: webSocketUpgradeHeaders),
                chainingTo: AuthProbeResponder()
            )
            #expect(response.status == .unauthorized)
        }
    }

    @Test
    func `WebSocket upgrade accepts the query fallback and strips it`() async throws {
        try await withTestApp { app in
            let (auth, directory, _) = try makeAuth()
            defer { try? FileManager.default.removeItem(at: directory) }
            let middleware = ServerAuthMiddleware(auth: auth)
            // Browsers cannot set an Authorization header on a handshake, so the
            // upgrade is the only surface allowed to present the token in the
            // query; it must be removed before downstream handlers can log it.
            let response = try await middleware.respond(
                to: makeRequest(
                    app: app,
                    path: "/ws?token=owner-token&session=abc",
                    headers: webSocketUpgradeHeaders
                ),
                chainingTo: AuthProbeResponder()
            )
            #expect(response.status == .ok)
            #expect(response.headers.first(name: "X-Probe-Authenticated") == "true")
            #expect(response.headers.first(name: "X-Probe-Query") == "session=abc")
        }
    }

    @Test
    func `Query token is ignored on plain REST requests`() async throws {
        try await withTestApp { app in
            let (auth, directory, _) = try makeAuth()
            defer { try? FileManager.default.removeItem(at: directory) }
            let middleware = ServerAuthMiddleware(auth: auth)
            // The query fallback is upgrade-only: a REST call must use the header
            // so a token never rides along in a logged URL.
            let response = try await middleware.respond(
                to: makeRequest(app: app, path: "/settings?token=owner-token"),
                chainingTo: AuthProbeResponder()
            )
            #expect(response.status == .unauthorized)
        }
    }

    @Test
    func `Spoofed upgrade key alone does not enable the query fallback`() async throws {
        try await withTestApp { app in
            let (auth, directory, _) = try makeAuth()
            defer { try? FileManager.default.removeItem(at: directory) }
            let middleware = ServerAuthMiddleware(auth: auth)
            // A key header alone is not a handshake: without Connection/Upgrade
            // the request stays a plain REST call and must not accept the query
            // token, which would leak it into URL and referrer logs.
            let response = try await middleware.respond(
                to: makeRequest(
                    app: app,
                    path: "/settings?token=owner-token",
                    headers: ["Sec-WebSocket-Key": "dGhlIHNhbXBsZSBub25jZQ=="]
                ),
                chainingTo: AuthProbeResponder()
            )
            #expect(response.status == .unauthorized)
        }
    }

    @Test
    func `Query fallback is restricted to the WebSocket path`() async throws {
        try await withTestApp { app in
            let (auth, directory, _) = try makeAuth()
            defer { try? FileManager.default.removeItem(at: directory) }
            let middleware = ServerAuthMiddleware(auth: auth)
            // A full handshake shape on a REST route still must not accept the
            // query token: only the real `/ws` upgrade may use the fallback.
            let response = try await middleware.respond(
                to: makeRequest(
                    app: app,
                    path: "/settings?token=owner-token",
                    headers: webSocketUpgradeHeaders
                ),
                chainingTo: AuthProbeResponder()
            )
            #expect(response.status == .unauthorized)
        }
    }

    @Test
    func `Repeated failures trip Retry-After while loopback stays exempt`() async throws {
        try await withTestApp { app in
            let (auth, directory, _) = try makeAuth()
            defer { try? FileManager.default.removeItem(at: directory) }
            let middleware = ServerAuthMiddleware(auth: auth)
            let remote = try SocketAddress(ipAddress: "203.0.113.9", port: 5000)

            for _ in 0 ..< (ServerAuth.maxFailures - 1) {
                let response = try await middleware.respond(
                    to: makeRequest(app: app, path: "/settings", remoteAddress: remote),
                    chainingTo: AuthProbeResponder()
                )
                #expect(response.status == .unauthorized)
            }
            let throttled = try await middleware.respond(
                to: makeRequest(app: app, path: "/settings", remoteAddress: remote),
                chainingTo: AuthProbeResponder()
            )
            #expect(throttled.status == .tooManyRequests)
            #expect(throttled.headers.first(name: "Retry-After") == "\(ServerAuth.retryAfterSeconds)")
            // An already-blocked peer gets the remaining cooldown rather than
            // extending its own lockout with more guesses.
            let stillThrottled = try await middleware.respond(
                to: makeRequest(app: app, path: "/settings", remoteAddress: remote),
                chainingTo: AuthProbeResponder()
            )
            #expect(stillThrottled.status == .tooManyRequests)

            // The owner shares the machine and must never be locked out by a
            // mistyped token, so loopback failures are never bucketed.
            let loopback = try SocketAddress(ipAddress: "127.0.0.1", port: 5001)
            for _ in 0 ..< (ServerAuth.maxFailures + 2) {
                let response = try await middleware.respond(
                    to: makeRequest(app: app, path: "/settings", remoteAddress: loopback),
                    chainingTo: AuthProbeResponder()
                )
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test
    func `Partial handshake headers on the WebSocket path do not enable the query fallback`() async throws {
        try await withTestApp { app in
            let (auth, directory, _) = try makeAuth()
            defer { try? FileManager.default.removeItem(at: directory) }
            let middleware = ServerAuthMiddleware(auth: auth)
            // Connection/Upgrade without the client nonce is ordinary traffic,
            // not a handshake, so the query credential must stay ignored.
            let withoutKey = HTTPHeaders([
                ("Connection", "Upgrade"),
                ("Upgrade", "websocket")
            ])
            let missingKey = try await middleware.respond(
                to: makeRequest(app: app, path: "/ws?token=owner-token", headers: withoutKey),
                chainingTo: AuthProbeResponder()
            )
            #expect(missingKey.status == .unauthorized)

            // A mismatched Upgrade token is likewise not a handshake even with a
            // nonce present; only the real websocket upgrade may use the query.
            let wrongUpgrade = HTTPHeaders([
                ("Connection", "Upgrade"),
                ("Upgrade", "h2c"),
                ("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ==")
            ])
            let mismatched = try await middleware.respond(
                to: makeRequest(app: app, path: "/ws?token=owner-token", headers: wrongUpgrade),
                chainingTo: AuthProbeResponder()
            )
            #expect(mismatched.status == .unauthorized)
        }
    }

    @Test
    func `HEAD reaches the public surface exactly like GET`() async throws {
        try await withTestApp { app in
            let (auth, directory, _) = try makeAuth()
            defer { try? FileManager.default.removeItem(at: directory) }
            let middleware = ServerAuthMiddleware(auth: auth)
            // Vapor maps HEAD onto the GET route, so probes that use HEAD must
            // classify like GET instead of receiving a spurious 401.
            let publicHead = try await middleware.respond(
                to: makeRequest(app: app, method: .HEAD, path: "/"),
                chainingTo: AuthProbeResponder()
            )
            #expect(publicHead.status == .ok)
            let livenessHead = try await middleware.respond(
                to: makeRequest(app: app, method: .HEAD, path: "/health"),
                chainingTo: AuthProbeResponder()
            )
            #expect(livenessHead.status == .ok)
            // A data path stays gated regardless of the verb.
            let gatedHead = try await middleware.respond(
                to: makeRequest(app: app, method: .HEAD, path: "/settings"),
                chainingTo: AuthProbeResponder()
            )
            #expect(gatedHead.status == .unauthorized)
        }
    }
}

@Suite("Server Auth Rotate Route")
struct ServerAuthRotateRouteTests {
    /// POSTs the rotation route through the full registered surface.
    private func postRotate(app: Application, token: String?) async throws -> Response {
        var headers = HTTPHeaders()
        if let token {
            headers.replaceOrAdd(name: "Authorization", value: "Bearer \(token)")
        }
        let request = Request(
            application: app,
            method: .POST,
            url: URI(string: "/auth/rotate"),
            headers: headers,
            on: app.eventLoopGroup.next()
        )
        return try await app.responder.respond(to: request).get()
    }

    /// Whether the POST rotation route is present in the route table.
    private func hasRotateRoute(_ app: Application) -> Bool {
        app.routes.all.contains { route in
            route.method == .POST && route.path == [.constant(ServerPaths.auth), .constant(ServerPaths.rotate)]
        }
    }

    @Test
    func `Rotate route mints one token and retires the previous`() async throws {
        let (auth, directory, _) = try makeAuth(token: "first-token")
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withTestApp { app in
            app.runeWeaver = makeConfigurationContext(config: .default)
            app.runeWeaverAuth = auth
            registerRuneWeaverRoutes(app)
            #expect(hasRotateRoute(app) == true)

            let first = try await postRotate(app: app, token: "first-token")
            #expect(first.status == .ok)
            // A one-time credential must never be cached by a browser or proxy.
            #expect(first.headers.first(name: "Cache-Control") == "no-store")
            let minted = try first.content.decode(ServerAuthRotateResponse.self).token
            #expect(minted != "first-token")
            #expect(await auth.verify(minted))
            #expect(await auth.verify("first-token") == false)

            // The retired token is dead at the gate, so any other signed-in
            // device falls back to the login gate on its next request.
            let retired = try await postRotate(app: app, token: "first-token")
            #expect(retired.status == .unauthorized)

            // The freshly minted token can itself rotate again, once per call.
            let second = try await postRotate(app: app, token: minted)
            #expect(second.status == .ok)
            let secondToken = try second.content.decode(ServerAuthRotateResponse.self).token
            #expect(secondToken != minted)
            let third = try await postRotate(app: app, token: secondToken)
            #expect(third.status == .ok)

            // Anonymous callers cannot reach the rotation handler.
            let anonymous = try await postRotate(app: app, token: nil)
            #expect(anonymous.status == .unauthorized)
        }
    }

    @Test
    func `Rotate route is absent without a verifier`() async throws {
        try await withTestApp { app in
            registerRuneWeaverRoutes(app)
            // No verifier means no gate and no rotation surface, exactly like the
            // v1 loopback-no-auth shape.
            #expect(hasRotateRoute(app) == false)
            let anonymous = try await postRotate(app: app, token: nil)
            #expect(anonymous.status == .notFound)
        }
    }

    @Test
    func `Rotate closes sockets that upgraded under the retired token`() async throws {
        let (auth, directory, _) = try makeAuth(token: "first-token")
        defer { try? FileManager.default.removeItem(at: directory) }
        let hub = WSHub()
        let socket = RecordingSocket()
        await hub.add(id: UUID(), box: socket)
        #expect(await hub.count() == 1)

        try await withTestApp { app in
            app.runeWeaver = makeConfigurationContext(config: .default, hub: hub)
            app.runeWeaverAuth = auth
            registerRuneWeaverRoutes(app)

            let response = try await postRotate(app: app, token: "first-token")
            #expect(response.status == .ok)
            // An already-open session must not survive the swap, or the holder
            // of the retired token could keep reading engine data and sending
            // chat, decision, or cancel frames after rotation.
            #expect(await hub.count() == 0)
            #expect(await socket.closed)
        }
    }

    @Test
    func `Retired generation stops frames and closes the socket with policy violation`() async throws {
        // A socket registers bound to the generation it upgraded under, and the
        // frame loop re-checks that generation before handling every frame. A
        // rotation retires it, so the next frame must be refused and the revoked
        // connection dropped as .policyViolation rather than a clean drain.
        // Driving the real rotation route exercises the production retirement
        // path end to end instead of hand-rolling the close.
        let (auth, directory, _) = try makeAuth(token: "first-token")
        defer { try? FileManager.default.removeItem(at: directory) }
        let hub = WSHub()
        let socket = RecordingSocket()
        let connectionID = UUID()

        // The generation captured at upgrade time authorizes frame handling, and
        // the socket is registered against it.
        let upgradeGeneration = await auth.currentGeneration()
        await hub.add(id: connectionID, box: socket, generation: upgradeGeneration)
        #expect(await auth.isCurrentGeneration(upgradeGeneration))
        #expect(await hub.count() == 1)

        try await withTestApp { app in
            app.runeWeaver = makeConfigurationContext(config: .default, hub: hub)
            app.runeWeaverAuth = auth
            registerRuneWeaverRoutes(app)
            let response = try await postRotate(app: app, token: "first-token")
            #expect(response.status == .ok)
        }

        // The frame boundary now reports the captured generation retired, so no
        // further frame would be handled, and the hub revoked the socket with the
        // policy-violation close rather than a clean going-away drain.
        #expect(await auth.isCurrentGeneration(upgradeGeneration) == false)
        #expect(await hub.count() == 0)
        #expect(await socket.closed)
        #expect(await socket.lastCloseCode == .policyViolation)
    }
}

/// Builds a context around the ephemeral fallback collaborators so a
/// configuration test can vary only the bind policy and the verifier without
/// booting the engine, binding a socket, or opening a real database.
private func makeConfigurationContext(
    config: ServerConfig,
    auth: ServerAuth? = nil,
    hub: WSHub = WSHub()
) -> ServerContext {
    let base = ServerContext.fallbackUnconfigured
    return ServerContext(
        config: config,
        conversations: base.conversations,
        toolBus: base.toolBus,
        orchestrator: base.orchestrator,
        memoryEngine: base.memoryEngine,
        permissionGate: base.permissionGate,
        approvals: base.approvals,
        hub: hub,
        steeringQueue: base.steeringQueue,
        auth: auth
    )
}

@Suite("Server Auth Configuration")
struct ServerAuthConfigurationTests {
    /// Whether the POST rotation route is present in the route table.
    private func hasRotateRoute(_ app: Application) -> Bool {
        app.routes.all.contains { route in
            route.method == .POST && route.path == [.constant(ServerPaths.auth), .constant(ServerPaths.rotate)]
        }
    }

    @Test
    func `Configure refuses a bind that disagrees with the resolved verifier`() async throws {
        try await withTestApp { app in
            // Advertising auth the surface cannot enforce must fail closed rather
            // than serve an unauthenticated LAN bind.
            let claimed = makeConfigurationContext(config: ServerConfig(hostname: "127.0.0.1", port: 8082, authConfigured: true))
            do {
                try configureRuneWeaver(app, context: claimed)
                Issue.record("Expected misconfigured for authConfigured without a verifier")
            } catch let error as ServerAuthError {
                guard case .misconfigured = error else {
                    Issue.record("Expected misconfigured, got \(error)")
                    return
                }
            }
        }
        try await withTestApp { app in
            let (auth, directory, _) = try makeAuth()
            defer { try? FileManager.default.removeItem(at: directory) }
            // The reverse lie: a verifier the flag says is not there.
            let denied = makeConfigurationContext(
                config: ServerConfig(hostname: "127.0.0.1", port: 8082, authConfigured: false),
                auth: auth
            )
            do {
                try configureRuneWeaver(app, context: denied)
                Issue.record("Expected misconfigured when a verifier is supplied without authConfigured")
            } catch let error as ServerAuthError {
                guard case .misconfigured = error else {
                    Issue.record("Expected misconfigured, got \(error)")
                    return
                }
            }
        }
    }

    @Test
    func `Non-loopback configuration refuses without a token and boots with one`() async throws {
        try await withTestApp { app in
            // The same fail-closed policy the CLI `serve --hostname` translation
            // consumes: a LAN address never downgrades to an unauthenticated bind.
            let refused = makeConfigurationContext(
                config: ServerConfig(hostname: "192.168.1.20", port: 8082, authConfigured: false)
            )
            do {
                try configureRuneWeaver(app, context: refused)
                Issue.record("Expected nonLoopbackRefused for an unauthenticated LAN bind")
            } catch let error as ServerConfigError {
                guard case let .nonLoopbackRefused(host) = error else {
                    Issue.record("Expected nonLoopbackRefused, got \(error)")
                    return
                }
                #expect(host == "192.168.1.20")
            }
        }
        try await withTestApp { app in
            let (auth, directory, _) = try makeAuth()
            defer { try? FileManager.default.removeItem(at: directory) }
            let lan = makeConfigurationContext(
                config: ServerConfig(hostname: "192.168.1.20", port: 8082, authConfigured: true),
                auth: auth
            )
            try configureRuneWeaver(app, context: lan)
            // A resolved token and a matching flag is the only configuration that
            // may boot a LAN bind, and it installs both the gate and rotation.
            #expect(app.runeWeaverAuth != nil)
            #expect(app.http.server.configuration.hostname == "192.168.1.20")
            #expect(hasRotateRoute(app) == true)
        }
    }

    @Test
    func `Loopback without auth configures an ungated surface`() async throws {
        try await withTestApp { app in
            let context = makeConfigurationContext(config: ServerConfig.default)
            try configureRuneWeaver(app, context: context)
            // No verifier means no gate and no rotation surface: the v1 loopback
            // no-auth posture is preserved rather than silently gated.
            #expect(app.runeWeaverAuth == nil)
            #expect(hasRotateRoute(app) == false)
        }
    }
}

@Suite("Server Auth Public Surface")
struct ServerAuthPublicSurfaceTests {
    @Test
    func `SPA entry points stay public even without a resolved bundle`() {
        // A navigation must reach the in-bundle owner-token gate whether or not
        // a built bundle exists, so the entry points are always forwarded.
        let missing = DashboardBundle(directoryURL: nil)
        for path in ["/", "", "/index.html", "/login"] {
            #expect(ServerAuthRequest.isPublicDashboardPath(path, bundle: missing), "\(path) should be public")
        }
    }

    @Test
    func `Entry points and existing bundle files classify as public`() throws {
        // A browser cannot attach a bearer header to a navigation or a
        // subresource fetch, so the SPA entry point plus real static bundle files
        // must stay public or the authenticated UI can never boot.
        let (bundle, directory) = try makeBundle(files: [
            "index.html",
            "assets/index-abc123.js",
            "assets/index-abc123.css",
            "assets/vendor-chunk.woff2",
            "favicon.ico",
            "favicon-32x32.png",
            "apple-touch-icon.png",
            "site.webmanifest"
        ])
        defer { try? FileManager.default.removeItem(at: directory) }
        let publicPaths = [
            "/",
            "/index.html",
            "/login",
            "/assets/index-abc123.js",
            "/assets/index-abc123.css",
            "/assets/vendor-chunk.woff2",
            "/favicon.ico",
            "/favicon-32x32.png",
            "/apple-touch-icon.png",
            "/site.webmanifest"
        ]
        for path in publicPaths {
            #expect(ServerAuthRequest.isPublicDashboardPath(path, bundle: bundle), "\(path) should be public")
        }
    }

    @Test
    func `Extension-only and parameterized data paths stay gated`() throws {
        // The classifier must never forward a path on its extension alone: a
        // registered route such as `/plugins/<id>` takes a free-form identifier,
        // so `/plugins/index.html` and `/plugins/report.json` are data requests,
        // not bundle bytes, and neither is present in the bundle.
        let (bundle, directory) = try makeBundle(files: ["index.html"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let gatedPaths = [
            "/settings",
            "/ws",
            "/chat",
            "/health",
            "/../secrets",
            "/assets/../settings",
            "/plugins/index.html",
            "/plugins/report.json",
            "/plugins/theme.js",
            "/data.json",
            "/assets/missing-abc123.js"
        ]
        for path in gatedPaths {
            #expect(ServerAuthRequest.isPublicDashboardPath(path, bundle: bundle) == false, "\(path) must stay gated")
        }
    }
}

@Suite("Server Auth CLI-Backed Lifecycle")
struct ServerAuthCLILifecycleTests {
    @Test
    func `Resolved source labels stay credential-free and name the origin`() async throws {
        // `auth token status` renders only the source label and a fingerprint, so
        // the labels must describe where a token came from without carrying it.
        #expect(ServerAuthTokenSource.environment(name: "RUNEWEAVER_AUTH_TOKEN").label == "environment (RUNEWEAVER_AUTH_TOKEN)")
        #expect(ServerAuthTokenSource.keychain.label == "Keychain")
        #expect(ServerAuthTokenSource.file(path: "/tmp/auth_token").label == "file (/tmp/auth_token)")

        let envName = "RUNEWEAVER_AUTH_TEST_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        _ = setenv(envName, "env-token", 1)
        defer { _ = unsetenv(envName) }
        let store = ServerAuthTokenStore(
            authConfig: AuthConfig(tokenEnv: envName, tokenFile: nil),
            service: "com.runeweaver.tests.\(UUID().uuidString)",
            inMemory: true
        )
        let resolved = try await store.resolve()
        let unwrapped = try #require(resolved)
        #expect(unwrapped.token == "env-token")
        #expect(unwrapped.source == .environment(name: envName))
    }

    @Test
    func `Whitespace-padded environment tokens resolve trimmed`() async throws {
        // Status/fingerprint output reads the same store as enforcement, so a
        // padded export must normalize identically instead of reporting a
        // fingerprint for a value boot would reject.
        let envName = "RUNEWEAVER_AUTH_TEST_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        _ = setenv(envName, "  env-token  ", 1)
        defer { _ = unsetenv(envName) }
        let store = ServerAuthTokenStore(
            authConfig: AuthConfig(tokenEnv: envName, tokenFile: nil),
            service: "com.runeweaver.tests.\(UUID().uuidString)",
            inMemory: true
        )
        let resolved = try await store.resolve()
        let unwrapped = try #require(resolved)
        #expect(unwrapped.token == "env-token")
        #expect(unwrapped.source == .environment(name: envName))
    }

    @Test
    func `File resolution reports the restricted path`() async throws {
        let (directory, fileURL) = try makeTokenFile(contents: "file-token")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ServerAuthTokenStore(
            authConfig: AuthConfig(
                tokenEnv: "RUNEWEAVER_AUTH_TEST_UNSET_\(UUID().uuidString)",
                tokenFile: fileURL.path
            ),
            service: "com.runeweaver.tests.\(UUID().uuidString)",
            inMemory: true
        )
        let resolved = try await store.resolve()
        let unwrapped = try #require(resolved)
        #expect(unwrapped.token == "file-token")
        #expect(unwrapped.source == .file(path: fileURL.path))
    }

    @Test
    func `Fingerprint is a stable non-secret identifier`() {
        // `auth token status` names a credential by this short digest, so it must
        // be deterministic, differ per token, and never contain token material.
        let first = ServerAuth.fingerprint("alpha-token")
        let again = ServerAuth.fingerprint("alpha-token")
        let other = ServerAuth.fingerprint("beta-token")
        #expect(first == again)
        #expect(first != other)
        #expect(first.count == 16)
        // Hoist the key-path predicate out of `#expect`: the macro's rethrows
        // argument checker cannot see that `allSatisfy(\.isHexDigit)` is
        // non-throwing, and the key-path form keeps SwiftFormat's `preferKeyPath`
        // rule satisfied.
        let allHexDigits = first.allSatisfy(\.isHexDigit)
        #expect(allHexDigits)
        #expect(first.contains("alpha") == false)
    }

    @Test
    func `Empty-seed mint matches the CLI generate path`() async throws {
        // `auth token generate` mints through an empty-seed actor so a blank
        // credential is never live: rotating an empty seed yields a fresh 256-bit
        // token, persists it, and leaves the empty string unverifiable.
        let (directory, fileURL) = try makeTokenFile(contents: "")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ServerAuthTokenStore(
            authConfig: AuthConfig(
                tokenEnv: "RUNEWEAVER_AUTH_TEST_UNSET_\(UUID().uuidString)",
                tokenFile: fileURL.path
            ),
            service: "com.runeweaver.tests.\(UUID().uuidString)",
            inMemory: true
        )
        let auth = ServerAuth(initialToken: "", store: store)
        #expect(await auth.verify("") == false)
        let minted = try await auth.rotate()
        #expect(minted.isEmpty == false)
        #expect(await auth.verify(minted))
        #expect(await auth.verify("") == false)
        let persisted = try String(contentsOf: fileURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(persisted == minted)
    }
}

@Suite("Server Auth Session and Security Headers")
struct ServerAuthSessionAndSecurityHeadersTests {
    @Test
    func `presentedBearer accepts rw_session cookie`() async throws {
        try await withTestApp { app in
            let request = Request(application: app, on: app.eventLoopGroup.next())
            request.cookies[ServerAuthRequest.sessionCookieName] = HTTPCookies.Value(string: "cookie-secret")
            #expect(ServerAuthRequest.presentedBearer(for: request, allowQueryToken: false) == "cookie-secret")
        }
    }

    @Test
    func `Auth session routes manage HttpOnly session cookie`() async throws {
        let (auth, directory, _) = try makeAuth(token: "valid-owner-token")
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withTestApp { app in
            app.runeWeaver = makeConfigurationContext(config: .default)
            app.runeWeaverAuth = auth
            registerRuneWeaverRoutes(app)

            // 1. POST /auth/session with valid token
            let loginReq = Request(
                application: app,
                method: .POST,
                url: URI(string: "/auth/session"),
                on: app.eventLoopGroup.next()
            )
            try loginReq.content.encode(["token": "valid-owner-token"])
            let loginRes = try await app.responder.respond(to: loginReq).get()
            #expect(loginRes.status == .ok)
            let sessionCookie = loginRes.cookies[ServerAuthRequest.sessionCookieName]
            let unwrappedCookie = try #require(sessionCookie)
            #expect(unwrappedCookie.string != "valid-owner-token")
            #expect(!unwrappedCookie.string.isEmpty)
            #expect(await auth.hasActiveSession(unwrappedCookie.string) == true)
            #expect(unwrappedCookie.isHTTPOnly)
            #expect(unwrappedCookie.sameSite == .strict)
            #expect(unwrappedCookie.path == "/")

            // 2. Access protected route using the cookie
            let protectedReq = Request(
                application: app,
                method: .GET,
                url: URI(string: "/settings"),
                on: app.eventLoopGroup.next()
            )
            protectedReq.cookies[ServerAuthRequest.sessionCookieName] = sessionCookie
            let protectedRes = try await app.responder.respond(to: protectedReq).get()
            #expect(protectedRes.status == .ok)

            // 3. POST /auth/session with invalid token fails
            let badLoginReq = Request(
                application: app,
                method: .POST,
                url: URI(string: "/auth/session"),
                on: app.eventLoopGroup.next()
            )
            try badLoginReq.content.encode(["token": "wrong-token"])
            let badLoginRes = try await app.responder.respond(to: badLoginReq).get()
            #expect(badLoginRes.status == .unauthorized)

            // 4. DELETE /auth/session revokes session server-side and expires cookie
            let logoutReq = Request(
                application: app,
                method: .DELETE,
                url: URI(string: "/auth/session"),
                on: app.eventLoopGroup.next()
            )
            logoutReq.cookies[ServerAuthRequest.sessionCookieName] = sessionCookie
            let logoutRes = try await app.responder.respond(to: logoutReq).get()
            #expect(logoutRes.status == .ok)
            #expect(await auth.hasActiveSession(unwrappedCookie.string) == false)
            let expiredCookie = logoutRes.cookies[ServerAuthRequest.sessionCookieName]
            let unwrappedExpired = try #require(expiredCookie)
            #expect(unwrappedExpired.maxAge == 0)

            // 5. Subsequent request using revoked cookie is rejected
            let afterLogoutReq = Request(
                application: app,
                method: .GET,
                url: URI(string: "/settings"),
                on: app.eventLoopGroup.next()
            )
            afterLogoutReq.cookies[ServerAuthRequest.sessionCookieName] = sessionCookie
            let afterLogoutRes = try await app.responder.respond(to: afterLogoutReq).get()
            #expect(afterLogoutRes.status == .unauthorized)
        }
    }

    @Test
    func `Token rotation refreshes session cookie`() async throws {
        let (auth, directory, _) = try makeAuth(token: "orig-token")
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withTestApp { app in
            app.runeWeaver = makeConfigurationContext(config: .default)
            app.runeWeaverAuth = auth
            registerRuneWeaverRoutes(app)

            let req = Request(
                application: app,
                method: .POST,
                url: URI(string: "/auth/rotate"),
                on: app.eventLoopGroup.next()
            )
            req.headers.bearerAuthorization = .init(token: "orig-token")
            let res = try await app.responder.respond(to: req).get()
            #expect(res.status == .ok)
            let cookie = res.cookies[ServerAuthRequest.sessionCookieName]
            let unwrapped = try #require(cookie)
            #expect(!unwrapped.string.isEmpty)
            #expect(unwrapped.string != "orig-token")
            #expect(await auth.hasActiveSession(unwrapped.string) == true)
            #expect(unwrapped.isHTTPOnly)
        }
    }

    @Test
    func `Session values cannot mint replacements through the login route`() async throws {
        // Minting requires the owner credential itself: a resent session
        // verifies at the request gate by design but must fail closed at
        // login like any wrong token, so sessions cannot mint their own
        // replacements. The owner-only verifier mirrors that boundary
        // directly: sessions fail, the live owner passes, and empty fails.
        let (auth, directory, _) = try makeAuth(token: "owner-token")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = try await auth.createSession()
        #expect(await auth.verifyOwnerToken(sessionID) == false)
        #expect(await auth.verifyOwnerToken("owner-token") == true)
        #expect(await auth.verifyOwnerToken("") == false)

        try await withTestApp { app in
            app.runeWeaver = makeConfigurationContext(config: .default)
            app.runeWeaverAuth = auth
            registerRuneWeaverRoutes(app)

            let retryReq = Request(
                application: app,
                method: .POST,
                url: URI(string: "/auth/session"),
                on: app.eventLoopGroup.next()
            )
            try retryReq.content.encode(["token": sessionID])
            let retryRes = try await app.responder.respond(to: retryReq).get()
            #expect(retryRes.status == .unauthorized)
        }
    }

    @Test
    func `isRequestSecure detects HTTPS direct and X-Forwarded-Proto`() async throws {
        try await withTestApp { app in
            let req1 = Request(application: app, method: .GET, url: URI(string: "https://localhost/auth/session"), on: app.eventLoopGroup.next())
            #expect(ServerAuthRequest.isRequestSecure(req1) == true)

            let req2 = Request(application: app, method: .GET, url: URI(string: "http://localhost/auth/session"), on: app.eventLoopGroup.next())
            req2.headers.replaceOrAdd(name: "X-Forwarded-Proto", value: "https")
            #expect(ServerAuthRequest.isRequestSecure(req2) == true)

            let req3 = Request(application: app, method: .GET, url: URI(string: "http://localhost/auth/session"), on: app.eventLoopGroup.next())
            req3.headers.replaceOrAdd(name: "X-Forwarded-Proto", value: "https, http")
            #expect(ServerAuthRequest.isRequestSecure(req3) == true)

            let req4 = Request(application: app, method: .GET, url: URI(string: "http://localhost/auth/session"), on: app.eventLoopGroup.next())
            #expect(ServerAuthRequest.isRequestSecure(req4) == false)
        }
    }

    @Test
    func `HostValidationMiddleware rejects rebinding and permits allowed hosts`() async throws {
        try await withTestApp { app in
            let middleware = HostValidationMiddleware(hostname: "127.0.0.1", allowMissingHostInTesting: false)

            // Valid host header
            let validReq = Request(application: app, method: .GET, url: URI(string: "/health"), on: app.eventLoopGroup.next())
            validReq.headers.replaceOrAdd(name: .host, value: "127.0.0.1:8082")
            let validRes = try await middleware.respond(to: validReq, chainingTo: AuthProbeResponder())
            #expect(validRes.status == .ok)

            // Valid localhost header
            let localhostReq = Request(application: app, method: .GET, url: URI(string: "/health"), on: app.eventLoopGroup.next())
            localhostReq.headers.replaceOrAdd(name: .host, value: "localhost:8082")
            let localhostRes = try await middleware.respond(to: localhostReq, chainingTo: AuthProbeResponder())
            #expect(localhostRes.status == .ok)

            // Rebinding attack host header rejected with 403
            let evilReq = Request(application: app, method: .GET, url: URI(string: "/health"), on: app.eventLoopGroup.next())
            evilReq.headers.replaceOrAdd(name: .host, value: "attacker.com:8082")
            let evilRes = try await middleware.respond(to: evilReq, chainingTo: AuthProbeResponder())
            #expect(evilRes.status == .forbidden)

            // Missing host header rejected with 400 when allowMissingHostInTesting is false
            let missingReq = Request(application: app, method: .GET, url: URI(string: "/health"), on: app.eventLoopGroup.next())
            let missingRes = try await middleware.respond(to: missingReq, chainingTo: AuthProbeResponder())
            #expect(missingRes.status == .badRequest)
        }
    }

    @Test
    func `Global security headers and Cache-Control applied to API responses`() async throws {
        let (auth, directory, _) = try makeAuth(token: "sec-token")
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withTestApp { app in
            app.runeWeaver = makeConfigurationContext(config: .default)
            app.runeWeaverAuth = auth
            registerRuneWeaverRoutes(app)

            // Health probe carries defensive headers
            let healthReq = Request(application: app, method: .GET, url: URI(string: "/health"), on: app.eventLoopGroup.next())
            healthReq.headers.replaceOrAdd(name: .host, value: "127.0.0.1")
            let healthRes = try await app.responder.respond(to: healthReq).get()
            #expect(healthRes.headers.first(name: "X-Content-Type-Options") == "nosniff")
            #expect(healthRes.headers.first(name: "X-Frame-Options") == "DENY")
            #expect(healthRes.headers.first(name: "Referrer-Policy") == "strict-origin-when-cross-origin")

            // Settings carries no-store, private Cache-Control
            let settingsReq = Request(application: app, method: .GET, url: URI(string: "/settings"), on: app.eventLoopGroup.next())
            settingsReq.headers.bearerAuthorization = .init(token: "sec-token")
            settingsReq.headers.replaceOrAdd(name: .host, value: "127.0.0.1")
            let settingsRes = try await app.responder.respond(to: settingsReq).get()
            #expect(settingsRes.status == .ok)
            #expect(settingsRes.headers.first(name: "Cache-Control") == "no-store, private")
            #expect(settingsRes.headers.first(name: "X-Content-Type-Options") == "nosniff")
        }
    }

    @Test
    func `DashboardBundle responses carry Content Security Policy and frame headers`() async throws {
        let (bundle, directory) = try makeBundle(files: ["index.html"])
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withTestApp { app in
            let req = Request(application: app, on: app.eventLoopGroup.next())
            let res = try await bundle.response(for: req, requestPath: "/")
            #expect(res.headers.first(name: "Content-Security-Policy")?.contains("default-src 'self'") == true)
            #expect(res.headers.first(name: "X-Frame-Options") == "DENY")
            #expect(res.headers.first(name: "X-Content-Type-Options") == "nosniff")
            #expect(res.headers.first(name: "Referrer-Policy") == "strict-origin-when-cross-origin")
        }
    }
}

@Suite("Host Validation Matrix")
struct HostValidationMatrixTests {
    /// Drives one Host header through the gate without binding a socket.
    private func statusForHost(
        app: Application,
        middleware: HostValidationMiddleware,
        host: String,
        bearerToken: String? = nil
    ) async throws -> Response {
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .host, value: host)
        if let bearerToken {
            headers.replaceOrAdd(name: .authorization, value: "Bearer \(bearerToken)")
        }
        let request = Request(
            application: app,
            method: .GET,
            url: URI(string: "/health"),
            headers: headers,
            on: app.eventLoopGroup.next()
        )
        return try await middleware.respond(to: request, chainingTo: AuthProbeResponder())
    }

    /// The rejection body must stay fixed so callers cannot probe the allowlist,
    /// and a presented credential must never be reflected back.
    private func expectForbiddenWithoutEcho(_ response: Response, presentedToken: String) {
        #expect(response.status == .forbidden)
        let body = response.body.string ?? ""
        #expect(body == #"{"error":"invalid host header"}"#)
        #expect(body.contains(presentedToken) == false)
        #expect(response.headers.contains { $0.value.contains(presentedToken) } == false)
    }

    @Test
    func `All-interfaces bind refuses without auth and binds with auth`() throws {
        // An all-interfaces bind listens everywhere, so without a token it is
        // the same unauthenticated LAN exposure the bind policy refuses.
        for unspecified in ["0.0.0.0", "::", "[::]"] {
            do {
                try ServerConfig(hostname: unspecified, port: 8082, authConfigured: false)
                    .requireBindable(authConfigured: false)
                Issue.record("Expected nonLoopbackRefused for \(unspecified) without auth")
            } catch let error as ServerConfigError {
                guard case let .nonLoopbackRefused(host) = error else {
                    Issue.record("Expected nonLoopbackRefused, got \(error)")
                    return
                }
                #expect(host == unspecified)
            }
            try ServerConfig(hostname: unspecified, port: 8082, authConfigured: true)
                .requireBindable(authConfigured: true)
        }
    }

    @Test
    func `Loopback Host headers pass on an all-interfaces bind`() async throws {
        try await withTestApp { app in
            // Loopback is the owner's own machine, so it stays reachable even
            // when the bind widens to the LAN family under owner auth.
            let middleware = HostValidationMiddleware(
                hostname: "0.0.0.0",
                allowedHosts: [],
                authConfigured: true,
                allowMissingHostInTesting: false
            )
            for host in ["127.0.0.1:8082", "localhost:8082", "127.0.0.1", "localhost", "[::1]:8082", "::1"] {
                let response = try await statusForHost(app: app, middleware: middleware, host: host)
                #expect(response.status == .ok, "\(host) should pass")
            }
        }
    }

    @Test
    func `All-interfaces with auth allows the LAN family and explicit entries`() async throws {
        try await withTestApp { app in
            // A 0.0.0.0 bind with a resolved token intentionally serves the LAN
            // the owner trusted by binding everywhere: private IPv4 ranges,
            // link-adjacent .local names, and the exact explicit entries.
            let middleware = HostValidationMiddleware(
                hostname: "0.0.0.0",
                allowedHosts: ["my-mac.tail123.ts.net"],
                authConfigured: true,
                allowMissingHostInTesting: false
            )
            let allowed = [
                "10.0.0.5",
                "10.0.0.5:8082",
                "192.168.1.20:8082",
                "172.16.5.4",
                "172.31.255.1:8082",
                "studio.local",
                "studio.local:8082",
                "STUDIO.LOCAL:8082",
                "my-mac.tail123.ts.net",
                "my-mac.tail123.ts.net:8082"
            ]
            for host in allowed {
                let response = try await statusForHost(app: app, middleware: middleware, host: host)
                #expect(response.status == .ok, "\(host) should pass on an authenticated all-interfaces bind")
            }
        }
    }

    @Test
    func `All-interfaces with auth rejects rebinding shapes without echoing the token`() async throws {
        try await withTestApp { app in
            // Public names, public IPs, and widening shapes must stay outside
            // the LAN opening: only the private family plus the explicit list
            // rides the all-interfaces bind, so a rebinding host cannot use it.
            // Hand-built widening entries are dropped by the gate itself, so a
            // context assembled past config validation still fails closed.
            let middleware = HostValidationMiddleware(
                hostname: "0.0.0.0",
                allowedHosts: ["my-mac.tail123.ts.net", "*.example.com", "192.168.1.0/24", "*", "http://evil.com"],
                authConfigured: true,
                allowMissingHostInTesting: false
            )
            let presented = "owner-secret-probe-token"
            let rejected = [
                "evil.com",
                "evil.com:8082",
                "attacker.com:8082",
                "8.8.8.8",
                "8.8.8.8:8082",
                "93.184.216.34",
                "203.0.113.9:8082",
                "*.example.com",
                "192.168.1.0/24",
                "*",
                "http://evil.com"
            ]
            for host in rejected {
                let response = try await statusForHost(
                    app: app,
                    middleware: middleware,
                    host: host,
                    bearerToken: presented
                )
                expectForbiddenWithoutEcho(response, presentedToken: presented)
            }
            // A neighbor outside the private ranges is not smuggled in by the
            // LAN opening even though it looks nearby.
            for host in ["172.32.0.1", "172.15.0.1", "11.0.0.1"] {
                let response = try await statusForHost(
                    app: app,
                    middleware: middleware,
                    host: host,
                    bearerToken: presented
                )
                expectForbiddenWithoutEcho(response, presentedToken: presented)
            }
        }
    }

    @Test
    func `All-interfaces without auth stays strict on the explicit set`() async throws {
        try await withTestApp { app in
            // Without a resolved token the all-interfaces bind never boots, and
            // the gate mirrors that posture: the LAN family stays closed and
            // only loopback plus the literal plus explicit entries pass.
            let middleware = HostValidationMiddleware(
                hostname: "0.0.0.0",
                allowedHosts: ["my-mac.tail123.ts.net"],
                authConfigured: false,
                allowMissingHostInTesting: false
            )
            let presented = "owner-secret-probe-token"
            for host in ["10.0.0.5", "192.168.1.20:8082", "172.16.5.4", "studio.local"] {
                let response = try await statusForHost(
                    app: app,
                    middleware: middleware,
                    host: host,
                    bearerToken: presented
                )
                expectForbiddenWithoutEcho(response, presentedToken: presented)
            }
            // The explicit entry and loopback still pass: strict means narrow,
            // not empty.
            for host in ["127.0.0.1:8082", "localhost:8082", "my-mac.tail123.ts.net:8082"] {
                let response = try await statusForHost(app: app, middleware: middleware, host: host)
                #expect(response.status == .ok, "\(host) should still pass without auth")
            }
        }
    }

    @Test
    func `Literal LAN IP bind joins the allowed set without opening the subnet`() async throws {
        try await withTestApp { app in
            // Binding the literal LAN address is the narrow workaround: the
            // address itself joins the allowlist, but no sibling on the subnet
            // is implied the way the authenticated all-interfaces bind implies
            // the whole private family.
            let middleware = HostValidationMiddleware(
                hostname: "192.168.1.20",
                allowedHosts: [],
                authConfigured: true,
                allowMissingHostInTesting: false
            )
            let literal = try await statusForHost(app: app, middleware: middleware, host: "192.168.1.20:8082")
            #expect(literal.status == .ok)
            let loopback = try await statusForHost(app: app, middleware: middleware, host: "127.0.0.1:8082")
            #expect(loopback.status == .ok)
            let presented = "owner-secret-probe-token"
            let neighbor = try await statusForHost(
                app: app,
                middleware: middleware,
                host: "192.168.1.21:8082",
                bearerToken: presented
            )
            expectForbiddenWithoutEcho(neighbor, presentedToken: presented)
        }
    }
}

@Suite("Host Parity Contract")
struct HostParityContractTests {
    /// One pinned vector shared with the dashboard mirror. The same JSON
    /// literal lives in the web suite so a bracket, case, port, or
    /// trailing-dot drift on either side fails its own suite instead of
    /// silently forking the restart compare, the Host gate, or validation.
    private struct HostParityVector: Decodable {
        let input: String
        let canonical: String
        let normalized: String
        let hostnameValid: Bool
        let allowedHostValid: Bool
    }

    /// Pinned outputs for the restart canonicalizer, the Host normalizer,
    /// and the exact-host validator. Bracketed IPv6 strips only in the
    /// canonical form, casing folds in both string forms, `:port` survives
    /// the canonical form but strips in the normalized form only for an
    /// empty or colon-plus-numeric-port suffix after `]` (trailing junk like
    /// `[::1]evil` survives verbatim and fails validation), unbracketed
    /// `host:port` strips only for an empty or numeric port (`evil.com:evil`
    /// and `[::1]:evil` survive verbatim and fail validation), and a trailing
    /// dot survives both string forms while failing validation.
    private static let fixtureJSON = """
    [
      {"input":"example.com","canonical":"example.com","normalized":"example.com","hostnameValid":true,"allowedHostValid":true},
      {"input":"  Example.COM  ","canonical":"example.com","normalized":"example.com","hostnameValid":true,"allowedHostValid":true},
      {"input":"[::1]","canonical":"::1","normalized":"[::1]","hostnameValid":true,"allowedHostValid":true},
      {"input":"::1","canonical":"::1","normalized":"::1","hostnameValid":true,"allowedHostValid":true},
      {"input":"[FE80::1]","canonical":"fe80::1","normalized":"[fe80::1]","hostnameValid":true,"allowedHostValid":true},
      {"input":"[Example.COM]","canonical":"[example.com]","normalized":"[example.com]","hostnameValid":false,"allowedHostValid":false},
      {"input":"Example.COM:8082","canonical":"example.com:8082","normalized":"example.com","hostnameValid":false,"allowedHostValid":true},
      {"input":"[::1]:8082","canonical":"[::1]:8082","normalized":"[::1]","hostnameValid":false,"allowedHostValid":true},
      {"input":"[::1]evil","canonical":"[::1]evil","normalized":"[::1]evil","hostnameValid":false,"allowedHostValid":false},
      {"input":"evil.com:evil","canonical":"evil.com:evil","normalized":"evil.com:evil","hostnameValid":false,"allowedHostValid":false},
      {"input":"[::1]:evil","canonical":"[::1]:evil","normalized":"[::1]:evil","hostnameValid":false,"allowedHostValid":false},
      {"input":"localhost.","canonical":"localhost.","normalized":"localhost.","hostnameValid":false,"allowedHostValid":false},
      {"input":"example.com.","canonical":"example.com.","normalized":"example.com.","hostnameValid":false,"allowedHostValid":false},
      {"input":"LOCALHOST","canonical":"localhost","normalized":"localhost","hostnameValid":true,"allowedHostValid":true},
      {"input":"  [::1]  ","canonical":"::1","normalized":"[::1]","hostnameValid":true,"allowedHostValid":true},
      {"input":"http://evil.com","canonical":"http://evil.com","normalized":"http","hostnameValid":false,"allowedHostValid":false},
      {"input":"*.example.com","canonical":"*.example.com","normalized":"*.example.com","hostnameValid":false,"allowedHostValid":false},
      {"input":"[::1","canonical":"[::1","normalized":"[::1","hostnameValid":false,"allowedHostValid":false},
      {"input":":8082","canonical":":8082","normalized":"","hostnameValid":false,"allowedHostValid":false}
    ]
    """

    /// Decodes the pinned vectors so a malformed fixture fails loudly
    /// instead of passing vacuously on an empty matrix.
    /// - Returns: Pinned vectors in fixture order.
    /// - Throws: Decoding error when the fixture drifts from the contract shape.
    private static func fixture() throws -> [HostParityVector] {
        try JSONDecoder().decode([HostParityVector].self, from: Data(fixtureJSON.utf8))
    }

    @Test
    func `Restart canonicalizer normalizer and exact-host validator match the pinned matrix`() throws {
        let vectors = try Self.fixture()
        #expect(vectors.isEmpty == false)
        for vector in vectors {
            // The restart compare strips brackets only around a colon-bearing
            // literal so `[::1]` and `::1` agree while `[example.com]` stays distinct.
            #expect(canonicalRestartHost(vector.input) == vector.canonical, "canonicalRestartHost('\(vector.input)')")
            // The Host gate strips a `:port` only for an empty or numeric
            // suffix in both bracketed and unbracketed forms, so the saved
            // allowlist and the request header compare alike without
            // truncating trailing junk like `evil.com:evil` or `[::1]:evil`
            // to an allowlisted literal.
            #expect(ServerEndpointConfig.normalizeHost(vector.input) == vector.normalized, "normalizeHost('\(vector.input)')")
            // Hostname validation rejects a `:port` suffix the allowlist
            // strips, while both reject schemes, wildcards, unbalanced or
            // non-IPv6 brackets, non-numeric port tails, and a trailing dot
            // fail-closed.
            let hostnameOK = (try? RuneWeaverConfig.validateServerHostname(vector.input)) != nil
            #expect(hostnameOK == vector.hostnameValid, "validateServerHostname('\(vector.input)')")
            let allowedOK = (try? RuneWeaverConfig.validateAllowedHosts([vector.input])) != nil
            #expect(allowedOK == vector.allowedHostValid, "validateAllowedHosts('\(vector.input)')")
        }
    }
}

#if canImport(Security)
    import Security

    /// Deletes a generic password from the Keychain if one was written during tests.
    private func deleteTestKeychainItem(service: String, account: String = AuthConfig.defaultTokenKey) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
#endif

@Suite("SecretsManager In-Memory and Keychain Isolation Tests")
struct SecretsManagerInMemoryTests {
    @Test
    func `InMemory secrets manager stores and retrieves without touching Keychain`() async throws {
        let service = "com.runeweaver.tests.inmemory.\(UUID().uuidString)"
        let secrets = SecretsManager(service: service, inMemory: true)

        try await secrets.store(key: "TEST_KEY", secret: "test-secret-value")
        let retrieved = try await secrets.retrieve(key: "TEST_KEY")
        #expect(retrieved == "test-secret-value")

        #if canImport(Security)
            // Assert that the item was NOT written to the macOS Keychain
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: "TEST_KEY",
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            #expect(status == errSecItemNotFound, "Item should not exist in Keychain when inMemory is true")
        #endif

        try await secrets.delete(key: "TEST_KEY")
        let absent = try await secrets.retrieve(key: "TEST_KEY")
        #expect(absent == nil)
    }

    @Test
    func `InMemory ServerAuthTokenStore persists and rotates without Keychain leakage`() async throws {
        let (directory, fileURL) = try makeTokenFile(contents: "initial-token")
        defer { try? FileManager.default.removeItem(at: directory) }

        let service = "com.runeweaver.tests.inmemory.\(UUID().uuidString)"
        let store = ServerAuthTokenStore(
            authConfig: AuthConfig(tokenEnv: "RUNEWEAVER_AUTH_TEST_UNSET", tokenFile: fileURL.path),
            service: service,
            inMemory: true
        )
        let auth = ServerAuth(initialToken: "initial-token", store: store)

        let rotated = try await auth.rotate()
        #expect(rotated.isEmpty == false)
        #expect(await auth.verify(rotated))

        #if canImport(Security)
            // Verify no Keychain item was written
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: AuthConfig.defaultTokenKey,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            #expect(status == errSecItemNotFound, "Rotation with inMemory store must not persist to Keychain")
        #endif
    }
}

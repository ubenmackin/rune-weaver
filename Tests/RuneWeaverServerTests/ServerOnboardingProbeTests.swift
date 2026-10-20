// Rune Weaver Server — Onboarding probe SSRF oracle route coverage.

import Foundation
import NIOCore
import os
import RuneWeaverCore
@testable import RuneWeaverServer
@testable import RuneWeaverTools
import Testing
import Vapor
#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Failure modes for the loopback probe upstream stub.
private enum ProbeUpstreamError: Error {
    case socketFailed
    case bindFailed
    case listenFailed
}

/// Binds a loopback socket on an ephemeral port for the caller to own.
private func bindLoopbackEphemeral() throws -> (fd: Int32, port: Int) {
    #if canImport(Darwin)
        let streamType: Int32 = SOCK_STREAM
    #else
        let streamType = Int32(SOCK_STREAM.rawValue)
    #endif
    let fd = socket(AF_INET, streamType, 0)
    guard fd >= 0 else {
        throw ProbeUpstreamError.socketFailed
    }
    var reuse: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    addr.sin_port = 0
    let bound = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0 else {
        _ = close(fd)
        throw ProbeUpstreamError.bindFailed
    }
    var name = sockaddr_in()
    var nameLen = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &name) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            getsockname(fd, sockPtr, &nameLen)
        }
    }
    guard named == 0 else {
        _ = close(fd)
        throw ProbeUpstreamError.bindFailed
    }
    return (fd, Int(UInt16(bigEndian: name.sin_port)))
}

/// Reserves then releases a loopback port so the probe dials a refused socket.
private func closedLoopbackPort() throws -> Int {
    let (fd, port) = try bindLoopbackEphemeral()
    _ = close(fd)
    return port
}

/// Minimal loopback HTTP/1.1 stub settling probe dials without leaving the host.
private final class ProbeUpstream: Sendable {
    private let listenFD: Int32
    let port: Int
    private let closed = OSAllocatedUnfairLock(initialState: false)

    init() throws {
        let (fd, port) = try bindLoopbackEphemeral()
        guard listen(fd, 32) == 0 else {
            _ = close(fd)
            throw ProbeUpstreamError.listenFailed
        }
        listenFD = fd
        self.port = port
        let listenFD = fd
        let closed = self.closed
        // Accept off the cooperative pool so a parked accept never starves tests.
        DispatchQueue(label: "runeweaver-probe-accept-\(port)").async {
            while !closed.withLock({ $0 }) {
                var pollFD = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pollFD, 1, 100)
                guard ready > 0 else {
                    continue
                }
                var peer = sockaddr_in()
                var peerLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let client = withUnsafeMutablePointer(to: &peer) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                        accept(listenFD, sockPtr, &peerLen)
                    }
                }
                guard client >= 0 else {
                    if closed.withLock({ $0 }) {
                        break
                    }
                    continue
                }
                Task.detached {
                    await ProbeUpstream.serve(client)
                }
            }
        }
    }

    /// Stops accepting; in-flight stub replies settle on their own sockets.
    func shutdown() {
        closed.withLock { $0 = true }
        _ = Darwin.shutdown(listenFD, SHUT_RDWR)
        _ = close(listenFD)
    }

    /// Serves one accepted socket with a canned path-based reply.
    private static func serve(_ fd: Int32) async {
        defer { _ = close(fd) }
        var request = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while request.count < 16384 {
            let received = chunk.withUnsafeMutableBytes { ptr -> Int in
                guard let base = ptr.baseAddress else {
                    return -1
                }
                return recv(fd, base, ptr.count, 0)
            }
            guard received > 0 else {
                break
            }
            request.append(contentsOf: chunk.prefix(received))
            if request.range(of: Data("\r\n\r\n".utf8)) != nil {
                break
            }
        }
        let path = Self.requestPath(from: request)
        if path.hasPrefix("/slow") {
            // Parks past the probe timeout so the dial fails closed to false.
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            Self.send(fd, status: 200, reason: "OK", headers: [], body: "slow-ok")
        } else if path.hasPrefix("/redirect") {
            // The probe refuses to follow, so the 302 itself proves liveness.
            Self.send(fd, status: 302, reason: "Found", headers: ["Location: /"], body: "")
        } else if path.hasPrefix("/missing") {
            Self.send(fd, status: 404, reason: "Not Found", headers: [], body: "missing-fixture")
        } else if path.hasPrefix("/secret") {
            Self.send(fd, status: 200, reason: "OK", headers: [], body: "upstream-secret-marker-7f3a9c")
        } else {
            Self.send(fd, status: 200, reason: "OK", headers: [], body: "probe-ok")
        }
    }

    /// Reads the request target, tolerating absolute-form targets behind proxies.
    private static func requestPath(from request: Data) -> String {
        guard let text = String(data: request, encoding: .utf8),
              let line = text.components(separatedBy: "\r\n").first
        else {
            return "/"
        }
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else {
            return "/"
        }
        let target = String(parts[1])
        if target.hasPrefix("http"), let url = URL(string: target) {
            return url.path.isEmpty ? "/" : url.path
        }
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
        return path.isEmpty ? "/" : path
    }

    /// Writes one minimal HTTP/1.1 reply then lets the deferred close land.
    private static func send(_ fd: Int32, status: Int, reason: String, headers: [String], body: String) {
        let payload = Data(body.utf8)
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(payload.count)\r\nConnection: close\r\nContent-Type: text/plain\r\n"
        for field in headers {
            head += "\(field)\r\n"
        }
        head += "\r\n"
        var bytes = Data(head.utf8)
        bytes.append(payload)
        bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < bytes.count {
                guard let base = raw.baseAddress?.advanced(by: offset) else {
                    break
                }
                let sent = Darwin.send(fd, base, bytes.count - offset, 0)
                guard sent > 0 else {
                    break
                }
                offset += sent
            }
        }
    }
}

/// Builds an isolated owner verifier over a throwaway `0600` token file.
private func makeProbeAuth(token: String = "probe-owner-token") throws -> (auth: ServerAuth, directory: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("runeweaver-probe-auth-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    let fileURL = directory.appendingPathComponent("auth_token")
    try token.write(to: fileURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    let store = ServerAuthTokenStore(
        authConfig: AuthConfig(tokenEnv: "RUNEWEAVER_AUTH_TEST_UNSET", tokenFile: fileURL.path),
        service: "com.runeweaver.tests.\(UUID().uuidString)",
        inMemory: true
    )
    return (ServerAuth(initialToken: token, store: store), directory)
}

/// Builds an isolated policy store carrying the blocked set under test.
private func makeProbePolicyStore(blocked: Set<String>) async throws -> (store: PolicyStore, directory: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("runeweaver-probe-policy-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = PolicyStore(fileURL: directory.appendingPathComponent("policy.toml"))
    await store.load()
    let policy = SecurityPolicy(
        version: 1,
        network: NetworkEgressPolicy(
            mode: .allowlistOnly,
            allowedDomains: ["127.0.0.1"],
            blockedDomains: blocked,
            localExemptions: []
        ),
        credentials: [:]
    )
    try await store.replace(policy)
    return (store, directory)
}

/// Runs one body against the probe surface with owner auth installed.
private func withProbeApp<T>(
    blocked: Set<String> = ["169.254.169.254"],
    _ body: (Application, String) async throws -> T
) async throws -> T {
    let (auth, authDirectory) = try makeProbeAuth()
    let (store, policyDirectory) = try await makeProbePolicyStore(blocked: blocked)
    let app = try await Application.make(.testing)
    do {
        let base = ServerContext.fallbackUnconfigured
        let context = ServerContext(
            config: ServerConfig(hostname: "127.0.0.1", port: 8082, authConfigured: true),
            conversations: base.conversations,
            toolBus: base.toolBus,
            orchestrator: base.orchestrator,
            memoryEngine: base.memoryEngine,
            permissionGate: base.permissionGate,
            approvals: base.approvals,
            steeringQueue: base.steeringQueue,
            auth: auth,
            policyStore: store
        )
        try configureRuneWeaver(app, context: context)
        let value = try await body(app, "probe-owner-token")
        try await app.asyncShutdown()
        try? FileManager.default.removeItem(at: authDirectory)
        try? FileManager.default.removeItem(at: policyDirectory)
        return value
    } catch {
        try? await app.asyncShutdown()
        try? FileManager.default.removeItem(at: authDirectory)
        try? FileManager.default.removeItem(at: policyDirectory)
        throw error
    }
}

/// POSTs one probe body through the registered surface.
private func probeResponse(app: Application, serverURL: String?, token: String?) async throws -> Response {
    var headers = HTTPHeaders()
    if let token {
        headers.replaceOrAdd(name: "Authorization", value: "Bearer \(token)")
    }
    let request = Request(
        application: app,
        method: .POST,
        url: URI(string: "/onboarding/probe"),
        headers: headers,
        on: app.eventLoopGroup.next()
    )
    try request.content.encode(OnboardingProbeRequest(serverURL: serverURL))
    return try await app.responder.respond(to: request).get()
}

/// POSTs undecodable bytes so the handler exercises its malformed-body guard.
private func malformedProbeResponse(app: Application, token: String) async throws -> Response {
    var headers = HTTPHeaders()
    headers.replaceOrAdd(name: "Authorization", value: "Bearer \(token)")
    headers.contentType = .json
    let request = Request(
        application: app,
        method: .POST,
        url: URI(string: "/onboarding/probe"),
        headers: headers,
        collectedBody: ByteBuffer(string: "{malformed"),
        on: app.eventLoopGroup.next()
    )
    return try await app.responder.respond(to: request).get()
}

@Suite("Server Onboarding Probe")
struct ServerOnboardingProbeTests {
    @Test
    func `Valid loopback probe answers reachable`() async throws {
        let upstream = try ProbeUpstream()
        defer { upstream.shutdown() }
        try await withProbeApp { app, token in
            let response = try await probeResponse(app: app, serverURL: "http://127.0.0.1:\(upstream.port)/ok", token: token)
            #expect(response.status == .ok)
            #expect(try response.content.decode(OnboardingProbeResponse.self) == OnboardingProbeResponse(reachable: true))
        }
    }

    @Test
    func `Missing path still counts as reachable`() async throws {
        let upstream = try ProbeUpstream()
        defer { upstream.shutdown() }
        try await withProbeApp { app, token in
            // Any HTTP response proves liveness, including a 404 from the stub.
            let response = try await probeResponse(app: app, serverURL: "http://127.0.0.1:\(upstream.port)/missing", token: token)
            #expect(response.status == .ok)
            #expect(try response.content.decode(OnboardingProbeResponse.self).reachable == true)
        }
    }

    @Test
    func `Empty and invalid URLs answer bad request`() async throws {
        try await withProbeApp { app, token in
            let candidates: [String?] = [nil, "", "not a url"]
            for candidate in candidates {
                let response = try await probeResponse(app: app, serverURL: candidate, token: token)
                #expect(response.status == .badRequest)
            }
        }
    }

    @Test
    func `Invalid scheme answers bad request`() async throws {
        try await withProbeApp { app, token in
            let response = try await probeResponse(app: app, serverURL: "ftp://127.0.0.1/", token: token)
            #expect(response.status == .badRequest)
        }
    }

    @Test
    func `Overlong URL answers bad request`() async throws {
        try await withProbeApp { app, token in
            let padded = "http://127.0.0.1:8082/" + String(repeating: "a", count: 240)
            let response = try await probeResponse(app: app, serverURL: padded, token: token)
            #expect(response.status == .badRequest)
        }
    }

    @Test
    func `Malformed body answers bad request`() async throws {
        try await withProbeApp { app, token in
            let response = try await malformedProbeResponse(app: app, token: token)
            #expect(response.status == .badRequest)
        }
    }

    @Test
    func `Missing credential answers unauthorized`() async throws {
        let upstream = try ProbeUpstream()
        defer { upstream.shutdown() }
        try await withProbeApp { app, _ in
            let response = try await probeResponse(app: app, serverURL: "http://127.0.0.1:\(upstream.port)/ok", token: nil)
            #expect(response.status == .unauthorized)
        }
    }

    @Test
    func `Unreachable loopback port answers unreachable`() async throws {
        let port = try closedLoopbackPort()
        try await withProbeApp { app, token in
            let response = try await probeResponse(app: app, serverURL: "http://127.0.0.1:\(port)/", token: token)
            #expect(response.status == .ok)
            #expect(try response.content.decode(OnboardingProbeResponse.self).reachable == false)
        }
    }

    @Test
    func `Blocked host stays denied when authenticated`() async throws {
        try await withProbeApp(blocked: ["169.254.169.254", "blocked.example.com"]) { app, token in
            // A public answer would otherwise dial, so the refusal proves the blocklist gate.
            let resolver: @Sendable (String) -> [String] = { _ in ["93.184.216.34"] }
            let response = try await ApiSSRFGuard.$taskTestDNSResolver.withValue(resolver) {
                try await probeResponse(app: app, serverURL: "http://blocked.example.com/", token: token)
            }
            #expect(response.status == .ok)
            #expect(try response.content.decode(OnboardingProbeResponse.self).reachable == false)
        }
    }

    @Test
    func `Metadata literal never dials`() async throws {
        try await withProbeApp { app, token in
            let response = try await probeResponse(app: app, serverURL: "http://169.254.169.254/", token: token)
            #expect(response.status == .ok)
            #expect(try response.content.decode(OnboardingProbeResponse.self).reachable == false)
        }
    }

    @Test
    func `Metadata hostname never dials even with a dialable answer`() async throws {
        try await withProbeApp { app, token in
            // A loopback answer would otherwise dial, so the refusal proves never-dial.
            let resolver: @Sendable (String) -> [String] = { _ in ["127.0.0.1"] }
            let response = try await ApiSSRFGuard.$taskTestDNSResolver.withValue(resolver) {
                try await probeResponse(app: app, serverURL: "http://metadata.google.internal/", token: token)
            }
            #expect(response.status == .ok)
            #expect(try response.content.decode(OnboardingProbeResponse.self).reachable == false)
        }
    }

    @Test
    func `Link-local literal never dials`() async throws {
        try await withProbeApp { app, token in
            let response = try await probeResponse(app: app, serverURL: "http://169.254.10.20/", token: token)
            #expect(response.status == .ok)
            #expect(try response.content.decode(OnboardingProbeResponse.self).reachable == false)
        }
    }

    @Test
    func `Redirect refusal still counts as reachable`() async throws {
        let upstream = try ProbeUpstream()
        defer { upstream.shutdown() }
        try await withProbeApp { app, token in
            let response = try await probeResponse(app: app, serverURL: "http://127.0.0.1:\(upstream.port)/redirect", token: token)
            #expect(response.status == .ok)
            #expect(try response.content.decode(OnboardingProbeResponse.self).reachable == true)
        }
    }

    @Test
    func `Hanging upstream fails closed to unreachable`() async throws {
        let upstream = try ProbeUpstream()
        defer { upstream.shutdown() }
        try await withProbeApp { app, token in
            // The single-candidate shape keeps the wait to one probe timeout.
            let response = try await probeResponse(app: app, serverURL: "http://127.0.0.1:\(upstream.port)/slow/v1/models", token: token)
            #expect(response.status == .ok)
            #expect(try response.content.decode(OnboardingProbeResponse.self).reachable == false)
        }
    }

    @Test
    func `Probe response carries only the reachable flag`() async throws {
        let upstream = try ProbeUpstream()
        defer { upstream.shutdown() }
        try await withProbeApp { app, token in
            let response = try await probeResponse(app: app, serverURL: "http://127.0.0.1:\(upstream.port)/secret", token: token)
            #expect(response.status == .ok)
            #expect(try response.content.decode(OnboardingProbeResponse.self) == OnboardingProbeResponse(reachable: true))
            let raw = try #require(response.body.string)
            #expect(!raw.contains("upstream-secret-marker"))
            let shape = try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
            #expect(Set(shape.keys) == ["reachable"])
        }
    }
}

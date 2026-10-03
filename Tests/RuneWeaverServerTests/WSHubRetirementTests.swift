// Rune Weaver Tests — WebSocket hub token-generation retirement.
//
// Owner-token rotation must revoke established `/ws` sessions immediately, even
// when a socket sits passive and never sends another frame. These tests pin the
// hub half of that contract: retirement advances a monotonically rising live
// watermark, closes the sockets bound to a superseded generation, refuses a
// registration that races the sweep, and never fans a broadcast out to a socket
// the hub already knows holds a dead generation. A recording fake stands in for
// the live socket so close codes and delivered frames are directly observable
// without a network handshake.

import Foundation
import NIOWebSocket
@testable import RuneWeaverServer
import Testing
import Vapor

/// Test double for a hub socket recording sends and close reasons without a
/// live network handshake, so retirement is directly observable.
private actor RetirementRecordingSocket: WSConnectionSocket {
    /// Text frames the hub delivered to this socket.
    private(set) var sent: [String] = []
    /// Whether the hub closed this connection at all.
    private(set) var closed = false
    /// Whether the close was the policy-violation teardown revocation uses.
    private(set) var policyClosed = false

    func send(_ text: String) async throws {
        sent.append(text)
    }

    func close(code: WebSocketErrorCode) async throws {
        closed = true
        if case .policyViolation = code {
            policyClosed = true
        }
    }
}

@Suite("WebSocket Hub Retirement")
struct WSHubRetirementTests {
    @Test
    func `Retiring a generation closes its sockets and refuses a racing registration`() async {
        // The passive socket is bound to the generation captured at upgrade and
        // registered; retirement must drop it even though it never sends a frame.
        let hub = WSHub()
        let socket = RetirementRecordingSocket()
        #expect(await hub.add(id: UUID(), box: socket, generation: 3))
        #expect(await hub.count() == 1)

        await hub.retire(liveGeneration: 4)

        #expect(await hub.count() == 0)
        #expect(await socket.closed)
        #expect(await socket.policyClosed)

        // A socket whose middleware auth completed under the retired generation
        // but whose registration lands after the sweep must be refused rather
        // than stored, closing the TOCTOU window the blind drain left open.
        let late = RetirementRecordingSocket()
        #expect(await hub.add(id: UUID(), box: late, generation: 3) == false)
        #expect(await hub.count() == 0)
        #expect(await late.closed == false)
    }

    @Test
    func `Broadcast never reaches a socket holding a retired generation`() async {
        // A passive retired-token socket must not receive run or approval
        // broadcasts after the swap, and must not be delivered to by name either.
        let hub = WSHub()
        let id = UUID()
        let socket = RetirementRecordingSocket()
        _ = await hub.add(id: id, box: socket, generation: 1)

        await hub.retire(liveGeneration: 2)
        await hub.broadcast(text: "run_started")
        await hub.send(id: id, text: "approval_request")

        #expect(await socket.sent.isEmpty)
    }

    @Test
    func `Retirement leaves a socket on the live generation untouched`() async {
        // Retiring an older generation must not disturb a socket already bound
        // to the newly live one, and that socket keeps receiving broadcasts.
        let hub = WSHub()
        let live = RetirementRecordingSocket()
        _ = await hub.add(id: UUID(), box: live, generation: 4)

        await hub.retire(liveGeneration: 4)

        #expect(await hub.count() == 1)
        #expect(await live.closed == false)
        await hub.broadcast(text: "ok")
        #expect(await live.sent == ["ok"])
    }

    @Test
    func `A stale rotation cannot lower the live watermark onto a retired generation`() async {
        // Concurrent rotations can report their live generation out of order;
        // the watermark only ever advances, so an older report cannot re-admit a
        // socket bound to a generation already swept.
        let hub = WSHub()
        await hub.retire(liveGeneration: 5)
        await hub.retire(liveGeneration: 2)

        #expect(await hub.add(id: UUID(), box: RetirementRecordingSocket(), generation: 4) == false)
        #expect(await hub.add(id: UUID(), box: RetirementRecordingSocket(), generation: 5))
    }

    @Test
    func `An ungated socket is retired once a token rotation sweeps the hub`() async {
        // The loopback no-auth posture never rotates, but a hub that just retired
        // a token must not keep trusting a socket with no recorded generation.
        let hub = WSHub()
        let socket = RetirementRecordingSocket()
        _ = await hub.add(id: UUID(), box: socket)
        #expect(await hub.count() == 1)

        await hub.retire(liveGeneration: 1)

        #expect(await hub.count() == 0)
        #expect(await socket.policyClosed)
    }

    @Test
    func `Failing socket is closed and pruned from hub on broadcast`() async {
        let hub = WSHub()
        let socket = FailingSocket()
        let id = UUID()
        _ = await hub.add(id: id, box: socket)
        #expect(await hub.count() == 1)

        await hub.broadcast(text: "alert")

        #expect(await hub.count() == 0)
        #expect(await socket.closed)
    }

    @Test
    func `Origin check allows loopback and rejects arbitrary cross-site origins`() async throws {
        let app = try await Application.make(.testing)
        do {
            let request = Request(application: app, on: app.eventLoopGroup.any())

            #expect(isAllowedWebSocketOrigin("http://localhost:8082", request: request))
            #expect(!isAllowedWebSocketOrigin("http://localhost:3000", request: request))
            #expect(isAllowedWebSocketOrigin("http://127.0.0.1:8082", request: request))
            #expect(!isAllowedWebSocketOrigin("http://127.0.0.1:8080", request: request))
            #expect(isAllowedWebSocketOrigin("http://[::1]:8082", request: request))
            #expect(!isAllowedWebSocketOrigin("http://[::1]:8080", request: request))
            #expect(!isAllowedWebSocketOrigin("https://evil.com", request: request))
            #expect(!isAllowedWebSocketOrigin("https://attacker.org", request: request))
            #expect(!isAllowedWebSocketOrigin("not-a-valid-url", request: request))

            // Host-omitting request: matching loopback port passes, mismatched port fails,
            // arbitrary cross-site origins fail, and malformed origins fail closed.
            #expect(isAllowedWebSocketOrigin("http://localhost:8082", request: request))
            #expect(!isAllowedWebSocketOrigin("http://localhost:3000", request: request))
            #expect(!isAllowedWebSocketOrigin("https://evil.com", request: request))

            // Reverse-proxy parity: the request Host already passed
            // HostValidationMiddleware, so an Origin matching that validated
            // Host is the same site behind a proxy name rather than cross-site.
            var proxyHeaders = HTTPHeaders()
            proxyHeaders.replaceOrAdd(name: "Host", value: "runeweaver.int.volcrypt.com")
            let proxyRequest = Request(
                application: app,
                headers: proxyHeaders,
                on: app.eventLoopGroup.any()
            )
            #expect(isAllowedWebSocketOrigin("wss://runeweaver.int.volcrypt.com/ws", request: proxyRequest))
            // Cross-host Origin against the same validated Host still refuses.
            #expect(!isAllowedWebSocketOrigin("https://evil.com", request: proxyRequest))

            // Port-stripped parity: a Host carrying a port matches the bare Origin host.
            var proxyPortHeaders = HTTPHeaders()
            proxyPortHeaders.replaceOrAdd(name: "Host", value: "runeweaver.int.volcrypt.com:443")
            let proxyPortRequest = Request(
                application: app,
                headers: proxyPortHeaders,
                on: app.eventLoopGroup.any()
            )
            #expect(isAllowedWebSocketOrigin("https://runeweaver.int.volcrypt.com", request: proxyPortRequest))
            #expect(!isAllowedWebSocketOrigin("https://evil.com", request: proxyPortRequest))

            // Mismatched Host and Origin still fails: rebinding defense lives in
            // HostValidationMiddleware upstream, and the Origin check only trusts
            // exact parity with that already-validated Host.
            var mismatchedHeaders = HTTPHeaders()
            mismatchedHeaders.replaceOrAdd(name: "Host", value: "runeweaver.int.volcrypt.com")
            let mismatchedRequest = Request(
                application: app,
                headers: mismatchedHeaders,
                on: app.eventLoopGroup.any()
            )
            #expect(!isAllowedWebSocketOrigin("http://rebind.attacker.com:8082", request: mismatchedRequest))
            try await app.asyncShutdown()
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
    }

    @Test
    func `Bracketed IPv6 Host-Origin parity passes under one normalization`() async throws {
        // `URL.host` strips `[::1]` brackets while the normalized Host header
        // keeps them; both sides canonicalize to the bare form so a bracketed
        // IPv6 proxy matches instead of failing parity.
        let app = try await Application.make(.testing)
        do {
            var bracketedHeaders = HTTPHeaders()
            bracketedHeaders.replaceOrAdd(name: "Host", value: "[::1]:8080")
            let bracketedRequest = Request(
                application: app,
                headers: bracketedHeaders,
                on: app.eventLoopGroup.any()
            )
            #expect(!isAllowedWebSocketOrigin("http://[::1]:3000", request: bracketedRequest))
            #expect(isAllowedWebSocketOrigin("ws://[::1]:8080", request: bracketedRequest))
            #expect(isAllowedWebSocketOrigin("ws://[::1]:8082", request: bracketedRequest))

            var bareHeaders = HTTPHeaders()
            bareHeaders.replaceOrAdd(name: "Host", value: "[::1]")
            let bareRequest = Request(
                application: app,
                headers: bareHeaders,
                on: app.eventLoopGroup.any()
            )
            #expect(!isAllowedWebSocketOrigin("http://[::1]:3000", request: bareRequest))
            #expect(isAllowedWebSocketOrigin("http://[::1]:8082", request: bareRequest))

            // Non-loopback bracketed IPv6 parity exercises the fixed path:
            // loopback `::1` already passes before parity, so only a
            // non-loopback literal proves the bracket canonicalization.
            var ulaHeaders = HTTPHeaders()
            ulaHeaders.replaceOrAdd(name: "Host", value: "[fd00::1]:443")
            let ulaRequest = Request(
                application: app,
                headers: ulaHeaders,
                on: app.eventLoopGroup.any()
            )
            #expect(isAllowedWebSocketOrigin("https://[fd00::1]", request: ulaRequest))
            #expect(!isAllowedWebSocketOrigin("https://evil.com", request: ulaRequest))
            try await app.asyncShutdown()
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
    }

    @Test
    func `Trailing-dot Host-Origin parity fails closed locally`() async throws {
        // Defense in depth at the origin layer: trailing-dot hosts are rejected
        // here even when Host==Origin matches, instead of relying solely on
        // upstream `HostValidationMiddleware` or riding parity under a stripped
        // spelling.
        let app = try await Application.make(.testing)
        do {
            var trailingHeaders = HTTPHeaders()
            trailingHeaders.replaceOrAdd(name: "Host", value: "evil.com.")
            let trailingRequest = Request(
                application: app,
                headers: trailingHeaders,
                on: app.eventLoopGroup.any()
            )
            #expect(!isAllowedWebSocketOrigin("http://evil.com./", request: trailingRequest))
            #expect(!isAllowedWebSocketOrigin("http://evil.com.", request: trailingRequest))

            var proxyTrailingHeaders = HTTPHeaders()
            proxyTrailingHeaders.replaceOrAdd(name: "Host", value: "runeweaver.int.volcrypt.com.")
            let proxyTrailingRequest = Request(
                application: app,
                headers: proxyTrailingHeaders,
                on: app.eventLoopGroup.any()
            )
            #expect(!isAllowedWebSocketOrigin("https://runeweaver.int.volcrypt.com.", request: proxyTrailingRequest))
            try await app.asyncShutdown()
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
    }

    @Test
    func `Attacker Host-Origin parity relies on upstream Host gate`() async throws {
        // Pins the middleware ordering assumption: parity alone passes any
        // Host==Origin pair (including `rebind.attacker.com`), so end-to-end
        // safety for that pair rests on `HostValidationMiddleware` rejecting the
        // attacker Host upstream (`registerRuneWeaverRoutes` installs the Host
        // gate before the `/ws` route). An allowlisted proxy Host passes both
        // layers while the attacker Host passes only the origin layer in
        // isolation and fails the combined stack.
        let app = try await Application.make(.testing)
        do {
            var attackerHeaders = HTTPHeaders()
            attackerHeaders.replaceOrAdd(name: "Host", value: "rebind.attacker.com")
            let attackerRequest = Request(
                application: app,
                headers: attackerHeaders,
                on: app.eventLoopGroup.any()
            )
            #expect(isAllowedWebSocketOrigin("http://rebind.attacker.com:8082", request: attackerRequest))
            let defaultGate = HostValidationMiddleware(hostname: "127.0.0.1", allowedHosts: [], authConfigured: false)
            #expect(!defaultGate.isAllowedHost(HostValidationMiddleware.extractHost(from: "rebind.attacker.com")))

            var proxyHeaders = HTTPHeaders()
            proxyHeaders.replaceOrAdd(name: "Host", value: "runeweaver.int.volcrypt.com")
            let proxyRequest = Request(
                application: app,
                headers: proxyHeaders,
                on: app.eventLoopGroup.any()
            )
            #expect(isAllowedWebSocketOrigin("wss://runeweaver.int.volcrypt.com/ws", request: proxyRequest))
            let proxyGate = HostValidationMiddleware(
                hostname: "127.0.0.1",
                allowedHosts: ["runeweaver.int.volcrypt.com"],
                authConfigured: false
            )
            #expect(proxyGate.isAllowedHost(HostValidationMiddleware.extractHost(from: "runeweaver.int.volcrypt.com")))
            try await app.asyncShutdown()
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
    }
}

/// Socket fixture that throws on send to test pruning.
private actor FailingSocket: WSConnectionSocket {
    private(set) var closed = false

    func send(_: String) async throws {
        struct MockError: Error {}
        throw MockError()
    }

    func close(code _: WebSocketErrorCode) async throws {
        closed = true
    }
}

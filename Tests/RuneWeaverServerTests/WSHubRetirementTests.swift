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

            #expect(isAllowedWebSocketOrigin("http://localhost:3000", request: request))
            #expect(isAllowedWebSocketOrigin("http://127.0.0.1:8080", request: request))
            #expect(isAllowedWebSocketOrigin("http://[::1]:8080", request: request))
            #expect(!isAllowedWebSocketOrigin("https://evil.com", request: request))
            #expect(!isAllowedWebSocketOrigin("https://attacker.org", request: request))
            #expect(!isAllowedWebSocketOrigin("not-a-valid-url", request: request))

            // DNS rebinding protection: even if Host matches Origin, non-loopback non-configured hosts are rejected
            var rebindingHeaders = HTTPHeaders()
            rebindingHeaders.replaceOrAdd(name: "Host", value: "rebind.attacker.com:8082")
            let rebindingRequest = Request(
                application: app,
                headers: rebindingHeaders,
                on: app.eventLoopGroup.any()
            )
            #expect(!isAllowedWebSocketOrigin("http://rebind.attacker.com:8082", request: rebindingRequest))
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

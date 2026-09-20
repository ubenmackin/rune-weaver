// Rune Weaver Tests — Client connection and transport tests.

import Foundation
@testable import RuneWeaverClient
import Testing

@Suite("Client Connection")
struct ClientTests {
    @Test
    func `Client starts disconnected`() async throws {
        let client = try RuneWeaverClient(baseURL: #require(URL(string: "http://localhost:8080")))
        #expect(await client.state == .disconnected)
    }

    @Test
    func `Handshake presents the owner bearer when a token is configured`() throws {
        let socketURL = try #require(URL(string: "ws://127.0.0.1:8080/ws"))
        let request = RuneWeaverClient.handshakeRequest(for: socketURL, token: "owner-token")
        #expect(request.url == socketURL)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer owner-token")
    }

    @Test
    func `Handshake omits the credential without a token`() throws {
        let socketURL = try #require(URL(string: "ws://127.0.0.1:8080/ws"))
        let request = RuneWeaverClient.handshakeRequest(for: socketURL, token: nil)
        #expect(request.url == socketURL)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test
    func `Handshake treats a blank token as no credential`() throws {
        let socketURL = try #require(URL(string: "ws://127.0.0.1:8080/ws"))
        let request = RuneWeaverClient.handshakeRequest(for: socketURL, token: "")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }
}

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
}

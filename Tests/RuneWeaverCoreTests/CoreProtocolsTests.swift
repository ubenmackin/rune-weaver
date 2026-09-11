import Foundation
@testable import RuneWeaverCore
import Testing

@Suite("Core Protocols")
struct CoreProtocolsTests {
    @Test
    func `Message stores role and content`() {
        let message = Message(role: .user, content: "Hello")
        #expect(message.role == .user)
        #expect(message.content == "Hello")
    }

    @Test
    func `PermissionLevel covers graduated trust`() {
        #expect(PermissionLevel.allCases.count == 3)
    }

    @Test
    func `ToolOutput success and failure flags`() {
        #expect(ToolOutput.success("ok").isError == false)
        #expect(ToolOutput.failure("bad").isError == true)
    }

    @Test
    func `ModelInfo stores provider metadata`() {
        let info = ModelInfo(name: "gemma-4-9b", provider: "mlx", contextLength: 8192)
        #expect(info.name == "gemma-4-9b")
        #expect(info.supportsTools == true)
    }
}

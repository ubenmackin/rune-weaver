// RuneWeaver - Tests - Core protocols
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

    @Test
    func `api_style chat-completions decodes`() throws {
        let text = """
        [llm]
        default_provider = "custom"

        [llm.providers.custom]
        enabled = true
        base_url = "https://example.com/v1"
        api_style = "chat-completions"
        """
        let root = try TOMLParser.parse(text)
        let config = try RuneWeaverConfig(decoding: root)
        #expect(config.llm.providers["custom"]?.apiStyle == .chatCompletions)
    }

    @Test
    func `api_style responses decodes`() throws {
        let text = """
        [llm]
        default_provider = "custom"

        [llm.providers.custom]
        enabled = true
        base_url = "https://example.com/v1"
        api_style = "responses"
        """
        let root = try TOMLParser.parse(text)
        let config = try RuneWeaverConfig(decoding: root)
        #expect(config.llm.providers["custom"]?.apiStyle == .responses)
    }

    @Test
    func `api_style defaults to chat-completions when absent`() throws {
        let text = """
        [llm]
        default_provider = "custom"

        [llm.providers.custom]
        enabled = true
        base_url = "https://example.com/v1"
        """
        let root = try TOMLParser.parse(text)
        let config = try RuneWeaverConfig(decoding: root)
        #expect(config.llm.providers["custom"]?.apiStyle == .chatCompletions)
    }

    @Test
    func `Unknown api_style throws ConfigError`() throws {
        let text = """
        [llm]
        default_provider = "custom"

        [llm.providers.custom]
        enabled = true
        base_url = "https://example.com/v1"
        api_style = "carrier-pigeon"
        """
        let root = try TOMLParser.parse(text)
        do {
            _ = try RuneWeaverConfig(decoding: root)
            Issue.record("Expected ConfigError for unknown api_style")
        } catch let error as ConfigError {
            guard case let .validationError(field, _) = error else {
                Issue.record("Expected validationError, got \(error)")
                return
            }
            #expect(field == "llm.providers.custom.api_style")
        }
    }
}

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

    @Test
    func `Episode write then recall round-trips through file store`() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let engine = MemoryEngine(
            episodesDBPath: base.appendingPathComponent("episodes.db").path,
            vectorDBPath: base.appendingPathComponent("vectors").path,
            profilePath: base.appendingPathComponent("profile.json").path
        )
        let sessionID = UUID()
        try await engine.storeEpisodic(
            content: "The lighthouse keeper collects brass compasses",
            sessionID: sessionID
        )
        let results = try await engine.recall(query: "lighthouse compasses", limit: 5)
        #expect(results.contains { $0.content.contains("lighthouse") && $0.source == .episodic })
    }

    @Test
    func `Recall without embedding returns episodic and profile content`() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let engine = MemoryEngine(
            episodesDBPath: base.appendingPathComponent("episodes.db").path,
            vectorDBPath: base.appendingPathComponent("vectors").path,
            profilePath: base.appendingPathComponent("profile.json").path
        )
        try await engine.storeEpisodic(
            content: "Discussed espresso brewing with the Chemex dripper",
            sessionID: UUID()
        )
        try await engine.storeProfileFact(content: "I love espresso brewed with Chemex", source: "chat")
        let results = try await engine.recall(query: "espresso Chemex", limit: 5)
        #expect(results.contains { $0.source == .episodic && $0.content.contains("Chemex") })
        #expect(results.contains { $0.source == .profile && $0.content.contains("espresso") })
        #expect(results == results.sorted { $0.score > $1.score })
    }
}

@Suite("Chat Memory Helpers")
struct ChatMemoryHelperTests {
    @Test
    func `Remember phrases parse all forms`() {
        #expect(MemoryEngine.rememberFactText(from: "remember my dog is named Biscuit") == "my dog is named Biscuit")
        #expect(MemoryEngine.rememberFactText(from: "remember that my dog is named Biscuit") == "my dog is named Biscuit")
        #expect(MemoryEngine.rememberFactText(from: "/remember my dog is named Biscuit") == "my dog is named Biscuit")
        #expect(MemoryEngine.rememberFactText(from: "Remember That the gate code is 1234") == "the gate code is 1234")
        #expect(MemoryEngine.rememberFactText(from: "hello world") == nil)
    }

    @Test
    func `Chat helpers isolate store failures`() async {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let blocker = base.appendingPathComponent("blocker")
        _ = FileManager.default.createFile(atPath: blocker.path, contents: nil)
        let engine = MemoryEngine(
            episodesDBPath: blocker.appendingPathComponent("episodes.db").path,
            vectorDBPath: blocker.appendingPathComponent("vectors").path,
            profilePath: base.appendingPathComponent("profile.json").path
        )
        let chatStored = await engine.storeChatTurn(content: "hello", sessionID: UUID())
        #expect(chatStored == false)
        let remembered = await engine.storeRememberedFact(content: "I love testing")
        #expect(remembered == false)
    }
}

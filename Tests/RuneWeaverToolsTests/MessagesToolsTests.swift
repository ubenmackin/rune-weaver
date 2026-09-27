// Rune Weaver Tools Tests — Messages search, read, and send tool tests.

import Foundation
@testable import RuneWeaverCore
@testable import RuneWeaverTools
import Testing

/// In-memory stub gateway for hermetic Messages tool tests.
final class StubMessagesGateway: MessagesGateway, @unchecked Sendable {
    var searchResults: [MessagesMessageItem] = []
    var readResults: [MessagesMessageItem] = []
    var sentMessages: [(recipient: String, text: String)] = []
    var shouldFailSend: String?

    init(
        searchResults: [MessagesMessageItem] = [],
        readResults: [MessagesMessageItem] = []
    ) {
        self.searchResults = searchResults
        self.readResults = readResults
    }

    func search(query: String?, recipient: String?, limit: Int, since _: Date? = nil, until _: Date? = nil) async throws -> [MessagesMessageItem] {
        var results = searchResults
        if let query, !query.isEmpty, query != "*" {
            results = results.filter { $0.text.localizedCaseInsensitiveContains(query) }
        }
        if let recipient, !recipient.isEmpty {
            results = results.filter {
                $0.sender.localizedCaseInsensitiveContains(recipient)
                    || ($0.chatID?.localizedCaseInsensitiveContains(recipient) ?? false)
            }
        }
        return Array(results.prefix(limit))
    }

    func read(chatID: String?, recipient: String?, limit: Int, since _: Date? = nil, until _: Date? = nil) async throws -> [MessagesMessageItem] {
        var results = readResults
        if let chatID, !chatID.isEmpty {
            results = results.filter { $0.chatID == chatID }
        }
        if let recipient, !recipient.isEmpty {
            results = results.filter { $0.sender.localizedCaseInsensitiveContains(recipient) }
        }
        return Array(results.prefix(limit))
    }

    func send(recipient: String, text: String) async throws -> MessagesSendResult {
        if let failure = shouldFailSend {
            throw MessagesToolError.scriptFailed(failure)
        }
        sentMessages.append((recipient: recipient, text: text))
        return MessagesSendResult(success: true, recipient: recipient, text: text)
    }
}

@Suite("Messages Tools")
struct MessagesToolsTests {
    @Test
    func `Messages tools metadata and permission levels`() {
        let stub = StubMessagesGateway()
        let tools = MessagesTools.makeTools(gateway: stub)
        #expect(tools.count == 3)
        #expect(MessagesTools.toolNames == ["messages.search", "messages.read", "messages.send"])

        let search = tools.first { $0.name == "messages.search" }
        #expect(search != nil)
        #expect(search?.permissionLevel == .readOnly)

        let read = tools.first { $0.name == "messages.read" }
        #expect(read != nil)
        #expect(read?.permissionLevel == .readOnly)

        let send = tools.first { $0.name == "messages.send" }
        #expect(send != nil)
        #expect(send?.permissionLevel == .requiresApproval)
    }

    @Test
    func `Messages search args clamp limit and parse options`() throws {
        let args = try JSONDecoder().decode(MessagesSearchArgs.self, from: Data(#"{"query":"vacation","recipient":"Mom","limit":100}"#.utf8))
        #expect(args.query == "vacation")
        #expect(args.recipient == "Mom")
        #expect(args.limit == MessagesSearchArgs.maxLimit)

        let defaultArgs = try JSONDecoder().decode(MessagesSearchArgs.self, from: Data(#"{}"#.utf8))
        #expect(defaultArgs.query == nil)
        #expect(defaultArgs.recipient == nil)
        #expect(defaultArgs.limit == MessagesSearchArgs.defaultLimit)
    }

    @Test
    func `Messages search tool returns matching items in envelope`() async throws {
        let stub = StubMessagesGateway(searchResults: [
            MessagesMessageItem(
                id: "msg-1",
                text: "Remember the trip to Maui with the family?",
                date: "2026-06-15T14:30:00Z",
                isFromMe: false,
                sender: "Mom",
                chatID: "chat123",
                chatDisplayName: "Family Chat",
                tapback: "Loved a message",
                attachments: ["photo.jpg"]
            ),
            MessagesMessageItem(
                id: "msg-2",
                text: "Here are the bills from this month",
                date: "2026-07-01T10:00:00Z",
                isFromMe: false,
                sender: "Dad",
                chatID: "chat456"
            )
        ])
        let tool = MessagesSearchTool(gateway: stub)
        let output = try await tool.execute(
            input: ToolInput(toolName: "messages.search", argumentsJSON: #"{"query":"Maui"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == false)
        #expect(output.content.contains("Maui"))
        #expect(output.content.contains("Family Chat"))
        #expect(output.content.contains("Loved a message"))
        #expect(!output.content.contains("bills from this month"))

        let envelope = try JSONDecoder().decode(MessagesSearchEnvelope.self, from: Data(output.content.utf8))
        #expect(envelope.count == 1)
        #expect(envelope.messages.first?.sender == "Mom")
    }

    @Test
    func `Messages read tool requires chat identifier or recipient`() async throws {
        let stub = StubMessagesGateway()
        let tool = MessagesReadTool(gateway: stub)
        let output = try await tool.execute(
            input: ToolInput(toolName: "messages.read", argumentsJSON: #"{}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == true)
        #expect(output.content.contains("either 'chatId' or 'recipient' must be specified"))
    }

    @Test
    func `Messages read tool returns conversation history`() async throws {
        let stub = StubMessagesGateway(readResults: [
            MessagesMessageItem(
                id: "m-1",
                text: "Can you send the tickets?",
                date: "2026-06-14T09:00:00Z",
                isFromMe: true,
                sender: "Me",
                chatID: "chat123"
            ),
            MessagesMessageItem(
                id: "m-2",
                text: "Sure, here they are!",
                date: "2026-06-14T09:05:00Z",
                isFromMe: false,
                sender: "Mom",
                chatID: "chat123",
                attachments: ["tickets.pdf"]
            )
        ])
        let tool = MessagesReadTool(gateway: stub)
        let output = try await tool.execute(
            input: ToolInput(toolName: "messages.read", argumentsJSON: #"{"chatId":"chat123","limit":10}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == false)
        let envelope = try JSONDecoder().decode(MessagesReadEnvelope.self, from: Data(output.content.utf8))
        #expect(envelope.count == 2)
        #expect(envelope.messages.first?.text == "Can you send the tickets?")
        #expect(envelope.messages.last?.attachments == ["tickets.pdf"])
    }

    @Test
    func `Messages send tool validates recipient and text`() async throws {
        let stub = StubMessagesGateway()
        let tool = MessagesSendTool(gateway: stub)

        let badEmpty = try await tool.execute(
            input: ToolInput(toolName: "messages.send", argumentsJSON: #"{"recipient":"","text":"Hello"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(badEmpty.isError == true)

        let missing = try await tool.execute(
            input: ToolInput(toolName: "messages.send", argumentsJSON: #"{"recipient":"+15551234567"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(missing.isError == true)
    }

    @Test
    func `Messages send dry run does not invoke gateway`() async throws {
        let stub = StubMessagesGateway()
        let tool = MessagesSendTool(gateway: stub)
        let output = try await tool.execute(
            input: ToolInput(toolName: "messages.send", argumentsJSON: #"{"to":"+15551234567","message":"See you soon!"}"#),
            context: ToolContext(conversationID: UUID(), dryRun: true)
        )
        #expect(output.isError == false)
        #expect(stub.sentMessages.isEmpty)
        #expect(output.content.contains("Dry run: would send message"))
    }

    @Test
    func `Messages send invokes gateway and returns success`() async throws {
        let stub = StubMessagesGateway()
        let tool = MessagesSendTool(gateway: stub)
        let output = try await tool.execute(
            input: ToolInput(toolName: "messages.send", argumentsJSON: #"{"recipient":"alice@example.com","text":"Lunch today?"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == false)
        #expect(stub.sentMessages.count == 1)
        #expect(stub.sentMessages.first?.recipient == "alice@example.com")
        #expect(stub.sentMessages.first?.text == "Lunch today?")

        let envelope = try JSONDecoder().decode(MessagesSendEnvelope.self, from: Data(output.content.utf8))
        #expect(envelope.success == true)
        #expect(envelope.recipient == "alice@example.com")
    }

    @Test
    func `AppleScript escaping escapes quotes and backslashes`() {
        let input = "He said: \"Hello \\ world!\"\nNew line"
        let escaped = ProductionMessagesGateway.escapeAppleScriptString(input)
        #expect(escaped == "He said: \\\"Hello \\\\ world!\\\"\\nNew line")
    }

    @Test
    func `Messages tools round-trip through ToolBus`() async {
        let stub = StubMessagesGateway(searchResults: [
            MessagesMessageItem(id: "1", text: "Flight confirmed", date: "2026-09-01T00:00:00Z", isFromMe: false, sender: "Airline")
        ])
        let bus = ToolBus()
        await MessagesTools.register(on: bus, gateway: stub)

        let names = await bus.toolNames()
        #expect(Set(names).isSuperset(of: Set(["messages.search", "messages.read", "messages.send"])))

        let searched = await bus.execute(
            toolCall: ToolInput(toolName: "messages.search", argumentsJSON: #"{"query":"Flight"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(searched.isError == false)
        #expect(searched.content.contains("Flight confirmed"))
    }
}

// Rune Weaver Tools Tests — Messages search, read, and send tool tests.

import Foundation
import os
@testable import RuneWeaverCore
@testable import RuneWeaverTools
import Testing

/// In-memory stub gateway for hermetic Messages tool tests.
final class StubMessagesGateway: MessagesGateway, Sendable {
    private struct State: Sendable {
        var searchResults: [MessagesMessageItem]
        var readResults: [MessagesMessageItem]
        var sentMessages: [(recipient: String, text: String)] = []
        var shouldFailSend: String?
    }

    private let state: OSAllocatedUnfairLock<State>

    var searchResults: [MessagesMessageItem] {
        get { state.withLock { $0.searchResults } }
        set { state.withLock { $0.searchResults = newValue } }
    }

    var readResults: [MessagesMessageItem] {
        get { state.withLock { $0.readResults } }
        set { state.withLock { $0.readResults = newValue } }
    }

    var sentMessages: [(recipient: String, text: String)] {
        get { state.withLock { $0.sentMessages } }
        set { state.withLock { $0.sentMessages = newValue } }
    }

    var shouldFailSend: String? {
        get { state.withLock { $0.shouldFailSend } }
        set { state.withLock { $0.shouldFailSend = newValue } }
    }

    init(
        searchResults: [MessagesMessageItem] = [],
        readResults: [MessagesMessageItem] = []
    ) {
        self.state = OSAllocatedUnfairLock(
            initialState: State(
                searchResults: searchResults,
                readResults: readResults
            )
        )
    }

    func search(query: String?, recipient: String?, limit: Int, since _: Date? = nil, until _: Date? = nil) async throws -> [MessagesMessageItem] {
        let results = state.withLock { s in
            var res = s.searchResults
            if let query, !query.isEmpty, query != "*" {
                res = res.filter { $0.text.localizedCaseInsensitiveContains(query) }
            }
            if let recipient, !recipient.isEmpty {
                res = res.filter {
                    $0.sender.localizedCaseInsensitiveContains(recipient)
                        || ($0.chatID?.localizedCaseInsensitiveContains(recipient) ?? false)
                }
            }
            return res
        }
        return Array(results.prefix(limit))
    }

    func read(chatID: String?, recipient: String?, limit: Int, since _: Date? = nil, until _: Date? = nil) async throws -> [MessagesMessageItem] {
        let results = state.withLock { s in
            var res = s.readResults
            if let chatID, !chatID.isEmpty {
                res = res.filter { $0.chatID == chatID }
            }
            if let recipient, !recipient.isEmpty {
                res = res.filter { $0.sender.localizedCaseInsensitiveContains(recipient) }
            }
            return res
        }
        return Array(results.prefix(limit))
    }

    func send(recipient: String, text: String) async throws -> MessagesSendResult {
        try state.withLock { s in
            if let failure = s.shouldFailSend {
                throw MessagesToolError.scriptFailed(failure)
            }
            s.sentMessages.append((recipient: recipient, text: text))
        }
        return MessagesSendResult(success: true, recipient: recipient, text: text)
    }
}

/// Minute-aligned future fire time so the stored instant equals the requested one.
private func messagesMinuteAlignedFireAt(hoursAhead: Double = 1) -> Date {
    let raw = Date().addingTimeInterval(hoursAhead * 3600)
    let epoch = raw.timeIntervalSince1970
    return Date(timeIntervalSince1970: epoch - epoch.truncatingRemainder(dividingBy: 60))
}

/// Locked box recording booking drafts without touching a store.
private final class MessagesBookingBox: Sendable {
    private struct State: Sendable {
        var drafts: [ScheduledSendDraft] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var count: Int {
        state.withLock { $0.drafts.count }
    }

    var drafts: [ScheduledSendDraft] {
        state.withLock { $0.drafts }
    }

    /// Records one booking draft.
    /// - Parameter draft: Draft passed to the seam.
    func record(_ draft: ScheduledSendDraft) {
        state.withLock { $0.drafts.append(draft) }
    }
}

/// Stub booking seam recording drafts or throwing a canned failure.
private struct StubMessagesBooking: ScheduledSendBooking, Sendable {
    /// Box receiving drafts, when set.
    let box: MessagesBookingBox?
    /// Failure thrown by `book`, when set.
    let failure: String?

    /// Creates a stub booking.
    init(box: MessagesBookingBox? = nil, failure: String? = nil) {
        self.box = box
        self.failure = failure
    }

    /// Records the draft and returns a receipt, or throws the canned failure.
    func book(_ draft: ScheduledSendDraft) async throws -> BookedScheduledSend {
        if let failure {
            throw MessagesToolError.scriptFailed(failure)
        }
        box?.record(draft)
        return BookedScheduledSend(id: UUID(), fireAt: draft.fireAt)
    }
}

@Suite("Messages Tools")
struct MessagesToolsTests {
    @Test
    func `Messages tools metadata and permission levels`() {
        let stub = StubMessagesGateway()
        let tools = MessagesTools.makeTools(gateway: stub, resolver: StubMessagesRecipientResolver())
        #expect(tools.count == 4)
        #expect(MessagesTools.toolNames == ["messages.search", "messages.read", "messages.send", "messages.resolveRecipient"])

        let search = tools.first { $0.name == "messages.search" }
        #expect(search != nil)
        #expect(search?.permissionLevel == .readOnly)
        #expect(search?.contentTrustLevel == .untrustedExternal)

        let read = tools.first { $0.name == "messages.read" }
        #expect(read != nil)
        #expect(read?.permissionLevel == .readOnly)
        #expect(read?.contentTrustLevel == .untrustedExternal)

        let send = tools.first { $0.name == "messages.send" }
        #expect(send != nil)
        #expect(send?.permissionLevel == .requiresApproval)
        #expect(send?.contentTrustLevel == .untrustedExternal)

        let resolve = tools.first { $0.name == "messages.resolveRecipient" }
        #expect(resolve != nil)
        #expect(resolve?.permissionLevel == .readOnly)
        #expect(resolve?.contentTrustLevel == .untrustedExternal)
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
        #expect(Set(names).isSuperset(of: Set(["messages.search", "messages.read", "messages.send", "messages.resolveRecipient"])))

        let searched = await bus.execute(
            toolCall: ToolInput(toolName: "messages.search", argumentsJSON: #"{"query":"Flight"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(searched.isError == false)
        #expect(searched.content.contains("Flight confirmed"))
    }

    @Test
    func `Messages scheduled send books exactly one send without gateway use`() async throws {
        let stub = StubMessagesGateway()
        let bookingBox = MessagesBookingBox()
        let tool = MessagesSendTool(gateway: stub, booking: StubMessagesBooking(box: bookingBox))
        let fireAt = messagesMinuteAlignedFireAt()
        let output = try await tool.execute(
            input: ToolInput(
                toolName: "messages.send",
                argumentsJSON: #"{"recipient":"+15551234567","text":"See you soon!","scheduleAt":\#(fireAt.timeIntervalSince1970)}"#
            ),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == false)
        #expect(stub.sentMessages.isEmpty)
        #expect(bookingBox.count == 1)
        let draft = try #require(bookingBox.drafts.first)
        #expect(draft.channel == .messages)
        #expect(draft.recipient == "+15551234567")
        #expect(draft.text == "See you soon!")
        #expect(draft.fireAt == fireAt)
        #expect(output.content.contains("Booked"))
        #expect(output.content.contains("+15551234567"))
        #expect(output.content.contains(SharedDateFormatters.isoInternetTimeUTCString(from: fireAt)))
        let envelope = try JSONDecoder().decode(MessagesSendEnvelope.self, from: Data(output.content.utf8))
        #expect(envelope.success == true)
        #expect((envelope.note ?? "").contains("+15551234567"))
    }

    @Test
    func `Messages scheduled send rejects past fire time with its reason`() async throws {
        let stub = StubMessagesGateway()
        let bookingBox = MessagesBookingBox()
        let tool = MessagesSendTool(gateway: stub, booking: StubMessagesBooking(box: bookingBox))
        let output = try await tool.execute(
            input: ToolInput(
                toolName: "messages.send",
                argumentsJSON: #"{"recipient":"+15551234567","text":"Hi","scheduleAt":\#(Date().addingTimeInterval(-60).timeIntervalSince1970)}"#
            ),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == true)
        #expect(output.content.contains("at least 5 minutes"))
        #expect(bookingBox.count == 0)
        #expect(stub.sentMessages.isEmpty)
    }

    @Test
    func `Messages scheduled send rejects far-future fire time with its reason`() async throws {
        let stub = StubMessagesGateway()
        let bookingBox = MessagesBookingBox()
        let tool = MessagesSendTool(gateway: stub, booking: StubMessagesBooking(box: bookingBox))
        let output = try await tool.execute(
            input: ToolInput(
                toolName: "messages.send",
                argumentsJSON: #"{"recipient":"+15551234567","text":"Hi","scheduleAt":\#(Date().addingTimeInterval(400 * 24 * 3600).timeIntervalSince1970)}"#
            ),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == true)
        #expect(output.content.contains("at most 365 days"))
        #expect(bookingBox.count == 0)
        #expect(stub.sentMessages.isEmpty)
    }

    @Test
    func `Messages scheduled send rejects malformed fire time without booking`() async throws {
        let stub = StubMessagesGateway()
        let bookingBox = MessagesBookingBox()
        let tool = MessagesSendTool(gateway: stub, booking: StubMessagesBooking(box: bookingBox))
        let output = try await tool.execute(
            input: ToolInput(
                toolName: "messages.send",
                argumentsJSON: #"{"recipient":"+15551234567","text":"Hi","scheduleAt":"not-a-date"}"#
            ),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == true)
        #expect(bookingBox.count == 0)
        #expect(stub.sentMessages.isEmpty)
    }

    @Test
    func `Messages scheduled send without wired booking refuses with guidance`() async throws {
        let stub = StubMessagesGateway()
        let tool = MessagesSendTool(gateway: stub)
        let output = try await tool.execute(
            input: ToolInput(
                toolName: "messages.send",
                argumentsJSON: #"{"recipient":"+15551234567","text":"Hi","scheduleAt":\#(messagesMinuteAlignedFireAt().timeIntervalSince1970)}"#
            ),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == true)
        #expect(output.content.contains("Schedules surface"))
        #expect(stub.sentMessages.isEmpty)
    }

    @Test
    func `Messages scheduled dry run previews booking without writing`() async throws {
        let stub = StubMessagesGateway()
        let bookingBox = MessagesBookingBox()
        let tool = MessagesSendTool(gateway: stub, booking: StubMessagesBooking(box: bookingBox))
        let fireAt = messagesMinuteAlignedFireAt()
        let output = try await tool.execute(
            input: ToolInput(
                toolName: "messages.send",
                argumentsJSON: #"{"recipient":"+15551234567","text":"See you soon!","scheduleAt":\#(fireAt.timeIntervalSince1970)}"#
            ),
            context: ToolContext(conversationID: UUID(), dryRun: true)
        )
        #expect(output.isError == false)
        #expect(bookingBox.count == 0)
        #expect(stub.sentMessages.isEmpty)
        #expect(output.content.contains("Dry run"))
        #expect(output.content.contains("book"))
        #expect(output.content.contains(SharedDateFormatters.isoInternetTimeUTCString(from: fireAt)))
    }

    @Test
    func `Messages scheduled send through bus parks for approval without booking`() async {
        let stub = StubMessagesGateway()
        let bookingBox = MessagesBookingBox()
        let bus = ToolBus(permissionGate: PermissionGate())
        for tool in MessagesTools.makeTools(gateway: stub, booking: StubMessagesBooking(box: bookingBox)) {
            await bus.register(tool: tool)
        }
        let result = await bus.execute(
            toolCall: ToolInput(
                toolName: "messages.send",
                argumentsJSON: #"{"recipient":"+15551234567","text":"Hi","scheduleAt":\#(messagesMinuteAlignedFireAt().timeIntervalSince1970)}"#
            ),
            context: ToolContext(conversationID: UUID())
        )
        #expect(result.isError == true)
        #expect(result.content.contains("requires approval"))
        #expect(bookingBox.count == 0)
        #expect(stub.sentMessages.isEmpty)
    }

    @Test
    func `Messages scheduled booking failure stays caller-visible`() async throws {
        let stub = StubMessagesGateway()
        let tool = MessagesSendTool(gateway: stub, booking: StubMessagesBooking(failure: "store unavailable: disk full"))
        let output = try await tool.execute(
            input: ToolInput(
                toolName: "messages.send",
                argumentsJSON: #"{"recipient":"+15551234567","text":"Hi","scheduleAt":\#(messagesMinuteAlignedFireAt().timeIntervalSince1970)}"#
            ),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == true)
        #expect(output.content.contains("store unavailable"))
        #expect(stub.sentMessages.isEmpty)
    }
}

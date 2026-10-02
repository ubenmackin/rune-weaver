// Rune Weaver Tools Tests — name-shaped recipients for messages.search and messages.read.
//
// Purpose: pin the shared name-routing path on the read-only Messages tools. A
// name resolves to every candidate handle (deduped, ranked order), the gateway
// is queried once per handle, and the merged rows are deduped by id, sorted
// newest first, and capped to the request limit — with read reversing the capped
// set back to its chronological contract. Also pins the fail-closed zero-match
// note, ambiguity fan-out with no `resolvedRecipient`, and exact passthrough for
// handle- and chatId-shaped inputs.
//
// Scope: hermetic tool-level tests over `StubMessagesGateway` and
// `StubMessagesRecipientResolver`; nothing here touches Contacts or `chat.db`.
//
// Architectural role: guards the contract that lets one typed name read the
// same conversation a handle would, without guessing identity when the resolver
// reports ambiguity.

import Foundation
@testable import RuneWeaverCore
@testable import RuneWeaverTools
import Testing

@Suite("Messages Search Recipient")
struct MessagesSearchRecipientTests {
    // MARK: - Helpers

    /// Builds one resolution candidate for seeded resolutions.
    private func candidate(
        displayName: String? = nil,
        handle: String,
        service: String? = nil,
        lastMessageAt: Date? = nil,
        source: MessageRecipientSource = .contact,
        contactID: String? = nil
    ) -> MessageRecipientCandidate {
        MessageRecipientCandidate(
            displayName: displayName,
            handle: handle,
            service: service,
            lastMessageAt: lastMessageAt,
            source: source,
            contactID: contactID
        )
    }

    /// Builds one gateway message row.
    private func message(
        id: String,
        text: String = "hello",
        date: String,
        sender: String,
        chatID: String? = nil
    ) -> MessagesMessageItem {
        MessagesMessageItem(
            id: id,
            text: text,
            date: date,
            isFromMe: false,
            sender: sender,
            chatID: chatID
        )
    }

    /// Executes messages.search with an injected gateway and resolver.
    private func runSearch(
        _ argumentsJSON: String,
        gateway: StubMessagesGateway,
        resolver: (any MessagesRecipientResolving)? = nil
    ) async throws -> ToolOutput {
        let tool = MessagesSearchTool(gateway: gateway, resolver: resolver)
        return try await tool.execute(
            input: ToolInput(toolName: "messages.search", argumentsJSON: argumentsJSON),
            context: ToolContext(conversationID: UUID())
        )
    }

    /// Executes messages.read with an injected gateway and resolver.
    private func runRead(
        _ argumentsJSON: String,
        gateway: StubMessagesGateway,
        resolver: (any MessagesRecipientResolving)? = nil
    ) async throws -> ToolOutput {
        let tool = MessagesReadTool(gateway: gateway, resolver: resolver)
        return try await tool.execute(
            input: ToolInput(toolName: "messages.read", argumentsJSON: argumentsJSON),
            context: ToolContext(conversationID: UUID())
        )
    }

    /// Decodes a search envelope from tool output.
    private func searchEnvelope(_ output: ToolOutput) throws -> MessagesSearchEnvelope {
        try JSONDecoder().decode(MessagesSearchEnvelope.self, from: Data(output.content.utf8))
    }

    /// Decodes a read envelope from tool output.
    private func readEnvelope(_ output: ToolOutput) throws -> MessagesReadEnvelope {
        try JSONDecoder().decode(MessagesReadEnvelope.self, from: Data(output.content.utf8))
    }

    /// The exact zero-match guidance both tools must return for an unresolvable name.
    private func guidanceNote(for name: String) -> String {
        "No contact or recent conversation matches \"" + name + "\". Pass a phone number or email, "
            + "or open Rune Weaver menu -> Permissions… -> Enable for Contacts."
    }

    /// Rebecca's two canonical handles as one unambiguous identity.
    private func rebeccaResolution() -> MessageRecipientResolution {
        let email = candidate(
            displayName: "Rebecca Mackin",
            handle: "rebecca@example.com",
            service: "iMessage",
            contactID: "contact-1"
        )
        let phone = candidate(
            displayName: "Rebecca Mackin",
            handle: "+15551234567",
            service: "SMS",
            contactID: "contact-1"
        )
        return MessageRecipientResolution(query: "Rebecca", candidates: [email, phone], selected: email)
    }

    // MARK: - messages.search

    @Test
    func `Name search merges every handle newest first and reports the chosen handle`() async throws {
        let gateway = StubMessagesGateway(searchResults: [
            message(id: "email-1", text: "from email", date: "2026-06-01T10:00:00Z", sender: "rebecca@example.com", chatID: "chat-email"),
            message(id: "phone-1", text: "from phone", date: "2026-06-02T10:00:00Z", sender: "+15551234567", chatID: "chat-phone"),
            message(id: "phone-2", text: "newest from phone", date: "2026-06-03T10:00:00Z", sender: "+15551234567", chatID: "chat-phone")
        ])
        let resolver = StubMessagesRecipientResolver(resolutionsByName: ["Rebecca": rebeccaResolution()])

        let output = try await runSearch(#"{"recipient":"Rebecca"}"#, gateway: gateway, resolver: resolver)

        #expect(output.isError == false)
        let envelope = try searchEnvelope(output)
        #expect(envelope.messages.map(\.id) == ["phone-2", "phone-1", "email-1"])
        #expect(envelope.resolvedRecipient == "rebecca@example.com")
        #expect(envelope.note == nil)
        #expect(envelope.recipient == "Rebecca")
        #expect(resolver.queries == ["Rebecca"])
        #expect(resolver.resolveCalls.map(\.limit) == [5])
    }

    @Test
    func `Name search dedupes a message reached through two handles`() async throws {
        let gateway = StubMessagesGateway(searchResults: [
            message(id: "shared", text: "seen twice", date: "2026-06-05T10:00:00Z", sender: "rebecca@example.com +15551234567"),
            message(id: "email-only", text: "email", date: "2026-06-04T10:00:00Z", sender: "rebecca@example.com"),
            message(id: "phone-only", text: "phone", date: "2026-06-03T10:00:00Z", sender: "+15551234567")
        ])
        let resolver = StubMessagesRecipientResolver(resolutionsByName: ["Rebecca": rebeccaResolution()])

        let envelope = try await searchEnvelope(runSearch(#"{"recipient":"Rebecca"}"#, gateway: gateway, resolver: resolver))

        #expect(envelope.count == 3)
        #expect(envelope.messages.map(\.id) == ["shared", "email-only", "phone-only"])
    }

    @Test
    func `Name search caps the merged set at the request limit`() async throws {
        let gateway = StubMessagesGateway(searchResults: [
            message(id: "one", date: "2026-06-01T10:00:00Z", sender: "rebecca@example.com"),
            message(id: "two", date: "2026-06-02T10:00:00Z", sender: "+15551234567"),
            message(id: "three", date: "2026-06-03T10:00:00Z", sender: "+15551234567")
        ])
        let resolver = StubMessagesRecipientResolver(resolutionsByName: ["Rebecca": rebeccaResolution()])

        let envelope = try await searchEnvelope(runSearch(#"{"recipient":"Rebecca","limit":2}"#, gateway: gateway, resolver: resolver))

        #expect(envelope.count == 2)
        #expect(envelope.messages.map(\.id) == ["three", "two"])
    }

    @Test
    func `Ambiguous name searches every candidate and leaves resolvedRecipient nil`() async throws {
        let gateway = StubMessagesGateway(searchResults: [
            message(id: "a-1", date: "2026-06-01T10:00:00Z", sender: "rebecca.a@example.com"),
            message(id: "b-1", date: "2026-06-02T10:00:00Z", sender: "rebecca.b@example.com")
        ])
        let first = candidate(displayName: "Rebecca A", handle: "rebecca.a@example.com", contactID: "contact-a")
        let second = candidate(displayName: "Rebecca B", handle: "rebecca.b@example.com", contactID: "contact-b")
        let resolver = StubMessagesRecipientResolver(resolutionsByName: [
            "Rebecca": MessageRecipientResolution(
                query: "Rebecca",
                candidates: [first, second],
                selected: nil,
                isAmbiguous: true
            )
        ])

        let envelope = try await searchEnvelope(runSearch(#"{"recipient":"Rebecca"}"#, gateway: gateway, resolver: resolver))

        #expect(envelope.messages.map(\.id) == ["b-1", "a-1"])
        #expect(envelope.resolvedRecipient == nil)
        #expect(envelope.note == nil)
    }

    @Test
    func `Zero-match name returns the guidance note without querying the gateway`() async throws {
        // The seeded sender mirrors the query, so a gateway call carrying the raw
        // name would have matched; an empty result proves no call happened.
        let gateway = StubMessagesGateway(searchResults: [
            message(id: "ghost-1", date: "2026-06-01T10:00:00Z", sender: "Ghost")
        ])
        let resolver = StubMessagesRecipientResolver()

        let output = try await runSearch(#"{"recipient":"Ghost"}"#, gateway: gateway, resolver: resolver)

        #expect(output.isError == false)
        let envelope = try searchEnvelope(output)
        #expect(envelope.count == 0)
        #expect(envelope.messages.isEmpty)
        #expect(envelope.resolvedRecipient == nil)
        #expect(envelope.note == guidanceNote(for: "Ghost"))
        #expect(resolver.queries == ["Ghost"])
    }

    @Test
    func `Nil resolver fails a name closed with the guidance note`() async throws {
        let gateway = StubMessagesGateway(searchResults: [
            message(id: "ghost-1", date: "2026-06-01T10:00:00Z", sender: "Ghost")
        ])

        let envelope = try await searchEnvelope(runSearch(#"{"recipient":"Ghost"}"#, gateway: gateway, resolver: nil))

        #expect(envelope.count == 0)
        #expect(envelope.resolvedRecipient == nil)
        #expect(envelope.note == guidanceNote(for: "Ghost"))
    }

    @Test
    func `Handle-shaped search recipient keeps the single-call passthrough`() async throws {
        let gateway = StubMessagesGateway(searchResults: [
            message(id: "older", date: "2026-06-01T10:00:00Z", sender: "rebecca@example.com"),
            message(id: "newer", date: "2026-06-03T10:00:00Z", sender: "rebecca@example.com")
        ])
        let resolver = StubMessagesRecipientResolver(resolutionsByName: ["Rebecca": rebeccaResolution()])

        let envelope = try await searchEnvelope(runSearch(#"{"recipient":"rebecca@example.com"}"#, gateway: gateway, resolver: resolver))

        // Seeded order is preserved: the name-path date sort never runs.
        #expect(envelope.messages.map(\.id) == ["older", "newer"])
        #expect(envelope.resolvedRecipient == nil)
        #expect(envelope.note == nil)
        #expect(resolver.queries.isEmpty)
    }

    // MARK: - messages.read

    @Test
    func `Name read merges every handle and restores chronological order`() async throws {
        let gateway = StubMessagesGateway(readResults: [
            message(id: "r-old", date: "2026-06-01T10:00:00Z", sender: "rebecca@example.com", chatID: "chat-email"),
            message(id: "r-mid", date: "2026-06-02T10:00:00Z", sender: "rebecca@example.com", chatID: "chat-email"),
            message(id: "r-new", date: "2026-06-03T10:00:00Z", sender: "+15551234567", chatID: "chat-phone")
        ])
        let resolver = StubMessagesRecipientResolver(resolutionsByName: ["Rebecca": rebeccaResolution()])

        let envelope = try await readEnvelope(runRead(#"{"recipient":"Rebecca"}"#, gateway: gateway, resolver: resolver))

        #expect(envelope.messages.map(\.id) == ["r-old", "r-mid", "r-new"])
        #expect(envelope.resolvedRecipient == "rebecca@example.com")
        #expect(envelope.note == nil)
    }

    @Test
    func `Name read caps the newest rows before reversing`() async throws {
        let gateway = StubMessagesGateway(readResults: [
            message(id: "r-old", date: "2026-06-01T10:00:00Z", sender: "rebecca@example.com", chatID: "chat-email"),
            message(id: "r-mid", date: "2026-06-02T10:00:00Z", sender: "rebecca@example.com", chatID: "chat-email"),
            message(id: "r-new", date: "2026-06-03T10:00:00Z", sender: "+15551234567", chatID: "chat-phone")
        ])
        let resolver = StubMessagesRecipientResolver(resolutionsByName: ["Rebecca": rebeccaResolution()])

        let envelope = try await readEnvelope(runRead(#"{"recipient":"Rebecca","limit":2}"#, gateway: gateway, resolver: resolver))

        // Newest two overall, then restored to chronological order.
        #expect(envelope.messages.map(\.id) == ["r-mid", "r-new"])
    }

    @Test
    func `Zero-match read returns the guidance note and an empty thread`() async throws {
        let gateway = StubMessagesGateway(readResults: [
            message(id: "ghost-1", date: "2026-06-01T10:00:00Z", sender: "Ghost", chatID: "chat-ghost")
        ])
        let resolver = StubMessagesRecipientResolver()

        let output = try await runRead(#"{"recipient":"Ghost"}"#, gateway: gateway, resolver: resolver)

        #expect(output.isError == false)
        let envelope = try readEnvelope(output)
        #expect(envelope.count == 0)
        #expect(envelope.messages.isEmpty)
        #expect(envelope.resolvedRecipient == nil)
        #expect(envelope.note == guidanceNote(for: "Ghost"))
    }

    @Test
    func `ChatId read keeps the single-call passthrough`() async throws {
        let gateway = StubMessagesGateway(readResults: [
            message(id: "in-chat", date: "2026-06-01T10:00:00Z", sender: "Mom", chatID: "chat-1"),
            message(id: "other-chat", date: "2026-06-02T10:00:00Z", sender: "Dad", chatID: "chat-2")
        ])
        let resolver = StubMessagesRecipientResolver(resolutionsByName: ["Rebecca": rebeccaResolution()])

        let envelope = try await readEnvelope(runRead(#"{"chatId":"chat-1"}"#, gateway: gateway, resolver: resolver))

        #expect(envelope.messages.map(\.id) == ["in-chat"])
        #expect(envelope.resolvedRecipient == nil)
        #expect(envelope.note == nil)
        #expect(resolver.queries.isEmpty)
    }

    // MARK: - Factory and envelopes

    @Test
    func `Factory wires the resolver into search and read`() async throws {
        let gateway = StubMessagesGateway(
            searchResults: [message(id: "email-1", date: "2026-06-01T10:00:00Z", sender: "rebecca@example.com")],
            readResults: [message(id: "email-1", date: "2026-06-01T10:00:00Z", sender: "rebecca@example.com")]
        )
        let resolver = StubMessagesRecipientResolver(resolutionsByName: ["Rebecca": rebeccaResolution()])
        let tools = MessagesTools.makeTools(gateway: gateway, resolver: resolver)

        let search = try #require(tools.first { $0.name == "messages.search" })
        let searchOutput = try await search.execute(
            input: ToolInput(toolName: search.name, argumentsJSON: #"{"recipient":"Rebecca"}"#),
            context: ToolContext(conversationID: UUID())
        )
        let searchResult = try searchEnvelope(searchOutput)
        #expect(searchResult.resolvedRecipient == "rebecca@example.com")

        let read = try #require(tools.first { $0.name == "messages.read" })
        let readOutput = try await read.execute(
            input: ToolInput(toolName: read.name, argumentsJSON: #"{"recipient":"Rebecca"}"#),
            context: ToolContext(conversationID: UUID())
        )
        let readResult = try readEnvelope(readOutput)
        #expect(readResult.resolvedRecipient == "rebecca@example.com")
        #expect(resolver.queries == ["Rebecca", "Rebecca"])
    }

    @Test
    func `Envelopes round-trip the routing fields and decode legacy payloads`() throws {
        let search = MessagesSearchEnvelope(
            query: "Rebecca",
            recipient: "Rebecca",
            resolvedRecipient: "rebecca@example.com",
            messages: []
        )
        let searchRoundTrip = try JSONDecoder().decode(MessagesSearchEnvelope.self, from: JSONEncoder().encode(search))
        #expect(searchRoundTrip == search)

        // Legacy payloads predate the routing fields; missing optionals decode as nil.
        let legacy = try JSONDecoder().decode(
            MessagesSearchEnvelope.self,
            from: Data(#"{"count":0,"messages":[],"recipient":"+15551234567"}"#.utf8)
        )
        #expect(legacy.query == nil)
        #expect(legacy.resolvedRecipient == nil)
        #expect(legacy.note == nil)

        let read = MessagesReadEnvelope(
            chatID: nil,
            recipient: nil,
            resolvedRecipient: "rebecca@example.com",
            note: "guidance",
            messages: []
        )
        let readRoundTrip = try JSONDecoder().decode(MessagesReadEnvelope.self, from: JSONEncoder().encode(read))
        #expect(readRoundTrip == read)
        #expect(readRoundTrip.note == "guidance")
    }
}

// Rune Weaver Tools Tests — messages.resolveRecipient tool behavior.
//
// Purpose: pin the read-only resolution tool end to end — argument validation
// (blank and over-length names, limit clamping, the `query` alias), envelope
// projection of a resolution (`resolved`, `ambiguous`, ranked candidates, and
// the zero-match guidance note), handle passthrough, and the encoded JSON shape
// callers decode.
//
// Scope: hermetic tool-level tests over `StubMessagesRecipientResolver`, plus
// one factory-wiring test that exercises the default resolver against a bogus
// `chat.db` path and an alias stub; the resolver's own ranking, scoring, and
// identity rules are covered by the Core recipient-resolver suite.
//
// Architectural role: guards the contract the model relies on before
// `messages.send`, including the guidance note that turns a zero-match into an
// owner question instead of a guessed handle.

import Foundation
@testable import RuneWeaverCore
@testable import RuneWeaverTools
import Testing

@Suite("Messages Resolve Recipient Tool")
struct MessagesResolveRecipientToolTests {
    /// Builds one candidate for seeded resolutions.
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

    /// Executes the tool over one stub resolver and returns its output.
    private func run(_ argumentsJSON: String, through resolver: StubMessagesRecipientResolver) async throws -> ToolOutput {
        let tool = MessagesResolveRecipientTool(resolver: resolver)
        return try await tool.execute(
            input: ToolInput(toolName: "messages.resolveRecipient", argumentsJSON: argumentsJSON),
            context: ToolContext(conversationID: UUID())
        )
    }

    @Test
    func `Unique match returns resolved candidate with ranked envelope`() async throws {
        let selected = candidate(
            displayName: "Rebecca Mackin",
            handle: "rebecca@example.com",
            service: "iMessage",
            contactID: "contact-1"
        )
        let resolver = StubMessagesRecipientResolver(resolutionsByName: [
            "Rebecca": MessageRecipientResolution(query: "Rebecca", candidates: [selected], selected: selected)
        ])
        let output = try await run(#"{"name":"Rebecca"}"#, through: resolver)

        #expect(output.isError == false)
        let envelope = try JSONDecoder().decode(MessagesResolveRecipientEnvelope.self, from: Data(output.content.utf8))
        #expect(envelope.query == "Rebecca")
        #expect(envelope.ambiguous == false)
        #expect(envelope.resolved?.handle == "rebecca@example.com")
        #expect(envelope.resolved?.contactID == "contact-1")
        #expect(envelope.candidates.map(\.handle) == ["rebecca@example.com"])
        #expect(envelope.note == nil)
        #expect(resolver.queries == ["Rebecca"])
        #expect(resolver.resolveCalls.first?.limit == MessagesResolveRecipientArgs.defaultLimit)
    }

    @Test
    func `Query alias resolves like the canonical name`() async throws {
        let selected = candidate(handle: "sam@example.com")
        let resolver = StubMessagesRecipientResolver(resolutionsByName: [
            "Sam": MessageRecipientResolution(query: "Sam", candidates: [selected], selected: selected)
        ])
        let output = try await run(#"{"query":"Sam"}"#, through: resolver)

        #expect(output.isError == false)
        #expect(resolver.queries == ["Sam"])
        let envelope = try JSONDecoder().decode(MessagesResolveRecipientEnvelope.self, from: Data(output.content.utf8))
        #expect(envelope.resolved?.handle == "sam@example.com")
    }

    @Test
    func `Ambiguous top score reports ambiguity and no resolved candidate`() async throws {
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
        let output = try await run(#"{"name":"Rebecca"}"#, through: resolver)

        #expect(output.isError == false)
        let envelope = try JSONDecoder().decode(MessagesResolveRecipientEnvelope.self, from: Data(output.content.utf8))
        #expect(envelope.ambiguous == true)
        #expect(envelope.resolved == nil)
        #expect(envelope.candidates.map(\.handle) == ["rebecca.a@example.com", "rebecca.b@example.com"])
        #expect(envelope.note == nil)
    }

    @Test
    func `Zero match returns the guidance note as a successful value`() async throws {
        let resolver = StubMessagesRecipientResolver()
        let output = try await run(#"{"name":"Nobody"}"#, through: resolver)

        #expect(output.isError == false)
        let envelope = try JSONDecoder().decode(MessagesResolveRecipientEnvelope.self, from: Data(output.content.utf8))
        #expect(envelope.candidates.isEmpty)
        #expect(envelope.resolved == nil)
        #expect(envelope.ambiguous == false)
        let note = try #require(envelope.note)
        #expect(note.contains(#"No match for "Nobody"."#))
        #expect(note.contains("Privacy & Security -> Contacts"))
    }

    @Test
    func `Typed handle passes through as the resolved candidate`() async throws {
        let selected = candidate(handle: "+15551234567", service: "iMessage", source: .handle)
        let resolver = StubMessagesRecipientResolver(resolutionsByName: [
            "+1 (555) 123-4567": MessageRecipientResolution(
                query: "+15551234567",
                candidates: [selected],
                selected: selected
            )
        ])
        let output = try await run(#"{"name":"+1 (555) 123-4567"}"#, through: resolver)

        #expect(output.isError == false)
        // The raw spelling reaches the resolver unchanged so it can canonicalize.
        #expect(resolver.queries == ["+1 (555) 123-4567"])
        let envelope = try JSONDecoder().decode(MessagesResolveRecipientEnvelope.self, from: Data(output.content.utf8))
        #expect(envelope.resolved?.handle == "+15551234567")
        #expect(envelope.resolved?.source == .handle)
    }

    @Test
    func `Blank or missing name fails with the expected shape and never resolves`() async throws {
        let resolver = StubMessagesRecipientResolver()

        let blank = try await run(#"{"name":"   "}"#, through: resolver)
        #expect(blank.isError == true)
        #expect(blank.content.contains("must not be blank"))
        #expect(blank.content.contains(#"{"name": "Rebecca"}"#))

        let missing = try await run(#"{}"#, through: resolver)
        #expect(missing.isError == true)
        #expect(missing.content.contains("must not be blank"))
        #expect(resolver.queries.isEmpty)
    }

    @Test
    func `Over-length name fails before lookup`() async throws {
        let resolver = StubMessagesRecipientResolver()
        let longName = String(repeating: "a", count: MessagesResolveRecipientArgs.maxNameLength + 1)
        let output = try await run(#"{"name":"\#(longName)"}"#, through: resolver)

        #expect(output.isError == true)
        #expect(output.content.contains("200"))
        #expect(output.content.contains(#"{"name": "Rebecca"}"#))
        #expect(resolver.queries.isEmpty)
    }

    @Test
    func `Limit clamps to the supported range and forwards to the resolver`() async throws {
        let high = try JSONDecoder().decode(MessagesResolveRecipientArgs.self, from: Data(#"{"name":"Rebecca","limit":99}"#.utf8))
        #expect(high.limit == MessagesResolveRecipientArgs.maxLimit)

        let low = try JSONDecoder().decode(MessagesResolveRecipientArgs.self, from: Data(#"{"name":"Rebecca","limit":0}"#.utf8))
        #expect(low.limit == 1)

        let fallback = try JSONDecoder().decode(MessagesResolveRecipientArgs.self, from: Data(#"{"name":"Rebecca"}"#.utf8))
        #expect(fallback.limit == MessagesResolveRecipientArgs.defaultLimit)

        let resolver = StubMessagesRecipientResolver()
        _ = try await run(#"{"name":"Rebecca","limit":99}"#, through: resolver)
        #expect(resolver.resolveCalls.first?.limit == MessagesResolveRecipientArgs.maxLimit)
    }

    @Test
    func `Envelope JSON is sorted, pretty-printed, and omits absent optionals`() async throws {
        let selected = candidate(handle: "rebecca@example.com")
        let resolver = StubMessagesRecipientResolver(resolutionsByName: [
            "Rebecca": MessageRecipientResolution(query: "Rebecca", candidates: [selected], selected: selected)
        ])
        let output = try await run(#"{"name":"Rebecca"}"#, through: resolver)

        #expect(output.content.hasPrefix("{\n"))
        #expect(output.content.contains("\n  "))
        // Sorted keys keep top-level fields alphabetical, and nil optionals stay
        // omitted rather than rendering as nulls.
        let ambiguousIndex = try #require(output.content.range(of: "\"ambiguous\""))
        let candidatesIndex = try #require(output.content.range(of: "\"candidates\""))
        let queryIndex = try #require(output.content.range(of: "\"query\""))
        let resolvedIndex = try #require(output.content.range(of: "\"resolved\""))
        #expect(ambiguousIndex.lowerBound < candidatesIndex.lowerBound)
        #expect(candidatesIndex.lowerBound < queryIndex.lowerBound)
        #expect(queryIndex.lowerBound < resolvedIndex.lowerBound)
        #expect(!output.content.contains("\"note\""))

        let object = try #require(try JSONSerialization.jsonObject(with: Data(output.content.utf8)) as? [String: Any])
        #expect(object["query"] as? String == "Rebecca")
        #expect(object["ambiguous"] as? Bool == false)
        #expect((object["candidates"] as? [[String: Any]])?.count == 1)
        #expect(object["resolved"] != nil)
        #expect(object["note"] == nil)
    }

    @Test
    func `Factory registers the resolve tool against the injected resolver`() async throws {
        let resolver = StubMessagesRecipientResolver()
        let tools = MessagesTools.makeTools(gateway: StubMessagesGateway(), resolver: resolver)
        let resolveTool = try #require(tools.first { $0.name == "messages.resolveRecipient" })
        #expect(resolveTool.permissionLevel == .readOnly)
        #expect(resolveTool.contentTrustLevel == .untrustedExternal)

        let output = try await resolveTool.execute(
            input: ToolInput(toolName: resolveTool.name, argumentsJSON: #"{"name":"Rebecca"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == false)
        #expect(resolver.queries == ["Rebecca"])
    }

    @Test
    func `Factory default resolver consults the wired alias store`() async throws {
        let alias = candidate(
            displayName: "Rebecca Mackin",
            handle: "+15551234567",
            service: "iMessage",
            source: .alias
        )
        let aliasStore = StubMessageAliasStore(candidatesByNameKey: ["rebecca mackin": [alias]])
        // No resolver is injected, so the factory builds the production
        // resolver; the bogus chat database path keeps history enrichment inert
        // without touching the live Messages store.
        let tools = MessagesTools.makeTools(
            chatDatabasePath: "/nonexistent/runeweaver-tests/chat.db",
            gateway: StubMessagesGateway(),
            recipientAliasStore: aliasStore
        )
        let resolveTool = try #require(tools.first { $0.name == "messages.resolveRecipient" })

        let output = try await resolveTool.execute(
            input: ToolInput(toolName: resolveTool.name, argumentsJSON: #"{"name":"Rebecca Mackin"}"#),
            context: ToolContext(conversationID: UUID())
        )

        #expect(output.isError == false)
        // The alias read is the wiring proof: a resolver built without the store
        // never asks it anything.
        #expect(aliasStore.requestedNameKeys == ["rebecca mackin"])
        let envelope = try JSONDecoder().decode(MessagesResolveRecipientEnvelope.self, from: Data(output.content.utf8))
        // A wired alias scores 110, above any address-book exact match (100), so
        // the learned handle wins whenever the store is consulted.
        #expect(envelope.resolved?.handle == "+15551234567")
        #expect(envelope.resolved?.source == .alias)
    }
}

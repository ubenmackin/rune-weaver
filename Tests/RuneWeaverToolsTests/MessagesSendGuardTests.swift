// Rune Weaver Tools Tests — messages.send display-name guard and alias learning.
//
// Purpose: pin the user-facing invariant that a display name can never reach
// AppleScript. A name-shaped recipient is refused before any dry-run preview or
// gateway call, with the resolver's best candidate and an exact retry handle
// (or the owner question when several contacts match, or guidance when none
// do); a handle recipient still canonicalizes and sends; a successful send
// with `resolvedFrom` records exactly one alias; and because a refusal embeds
// contact-derived candidate fields, the tool declares untrusted content so the
// model-context boundary wraps that refusal as data, never instructions.
// The tool also declares the shared pre-admission validation seam so the turn
// loop can refuse a name-shaped call with this same refusal before it can park
// for approval.
//
// Scope: hermetic tool-level tests over `StubMessagesGateway`,
// `StubMessagesRecipientResolver`, and `StubMessageAliasStore`; no test touches
// Contacts, `chat.db`, or `osascript`.
//
// Architectural role: guards the send tool's refusal contract, its
// untrusted-content declaration for candidate-bearing refusals, and the
// best-effort alias write, so a regression would surface as an unlabeled
// attacker-influenceable field reaching model context or as a wrong recipient
// in the real world rather than as a compile error.

import Foundation
@testable import RuneWeaverCore
@testable import RuneWeaverTools
import Testing

/// Gateway stub that reports an unsuccessful send without throwing, standing in
/// for a refusal that completed at the Messages boundary.
private struct RefusedSendGateway: MessagesGateway {
    func search(query _: String?, recipient _: String?, limit _: Int, since _: Date?, until _: Date?) async throws -> [MessagesMessageItem] {
        []
    }

    func read(chatID _: String?, recipient _: String?, limit _: Int, since _: Date?, until _: Date?) async throws -> [MessagesMessageItem] {
        []
    }

    func send(recipient: String, text: String) async throws -> MessagesSendResult {
        MessagesSendResult(success: false, recipient: recipient, text: text, details: "Refused by Messages.")
    }
}

@Suite("Messages Send Guard")
struct MessagesSendGuardTests {
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

    /// Executes messages.send over the injected doubles.
    private func execute(
        _ argumentsJSON: String,
        gateway: StubMessagesGateway,
        resolver: StubMessagesRecipientResolver? = nil,
        aliasStore: StubMessageAliasStore? = nil,
        dryRun: Bool = false
    ) async throws -> ToolOutput {
        let tool = MessagesSendTool(
            gateway: gateway,
            resolver: resolver,
            recipientAliasStore: aliasStore
        )
        return try await tool.execute(
            input: ToolInput(toolName: "messages.send", argumentsJSON: argumentsJSON),
            context: ToolContext(conversationID: UUID(), dryRun: dryRun)
        )
    }

    // MARK: - Name refusal

    @Test
    func `Single match refuses the name with the best match and retry handle`() async throws {
        let selected = candidate(
            displayName: "Rebecca Mackin",
            handle: "rebecca@example.com",
            service: "iMessage",
            contactID: "contact-1"
        )
        let resolver = StubMessagesRecipientResolver(resolutionsByName: [
            "Rebecca Mackin": MessageRecipientResolution(query: "Rebecca Mackin", candidates: [selected], selected: selected)
        ])
        let gateway = StubMessagesGateway()

        let output = try await execute(
            #"{"recipient":"Rebecca Mackin","text":"On my way"}"#,
            gateway: gateway,
            resolver: resolver
        )

        #expect(output.isError == true)
        #expect(
            output.content
                == #"Recipient "Rebecca Mackin" is a display name, not a phone number or email. Best match: Rebecca Mackin <rebecca@example.com> (iMessage). Retry messages.send with recipient "rebecca@example.com" and resolvedFrom "Rebecca Mackin"."#
        )
        #expect(gateway.sentMessages.isEmpty)
        #expect(resolver.resolveCalls.count == 1)
        #expect(resolver.resolveCalls.first?.limit == 5)
    }

    @Test
    func `Best match appends recency and falls back to the raw query without a display name`() async throws {
        let twoDaysAgo = try #require(Calendar.current.date(byAdding: .day, value: -2, to: Date()))
        let selected = candidate(handle: "+15551234567", service: "SMS", lastMessageAt: twoDaysAgo)
        let resolver = StubMessagesRecipientResolver(resolutionsByName: [
            "Rebecca": MessageRecipientResolution(query: "Rebecca", candidates: [selected], selected: selected)
        ])
        let gateway = StubMessagesGateway()

        let output = try await execute(#"{"recipient":"Rebecca","text":"Hi"}"#, gateway: gateway, resolver: resolver)

        #expect(output.isError == true)
        #expect(output.content.contains("Best match: Rebecca <+15551234567> (SMS), last messaged 2 days ago."))
        #expect(output.content.hasSuffix(#". Retry messages.send with recipient "+15551234567" and resolvedFrom "Rebecca"."#))
        #expect(gateway.sentMessages.isEmpty)
    }

    @Test
    func `Ambiguous resolution lists up to three numbered candidates and asks the user`() async throws {
        let candidates = [
            candidate(displayName: "Rebecca A", handle: "rebecca.a@example.com", service: "iMessage"),
            candidate(displayName: "Rebecca B", handle: "rebecca.b@example.com"),
            candidate(displayName: "Rebecca C", handle: "rebecca.c@example.com"),
            candidate(displayName: "Rebecca D", handle: "rebecca.d@example.com")
        ]
        let resolver = StubMessagesRecipientResolver(resolutionsByName: [
            "Rebecca": MessageRecipientResolution(query: "Rebecca", candidates: candidates, selected: nil, isAmbiguous: true)
        ])
        let gateway = StubMessagesGateway()

        let output = try await execute(#"{"recipient":"Rebecca","text":"Hi"}"#, gateway: gateway, resolver: resolver)

        #expect(output.isError == true)
        #expect(output.content.hasPrefix(#"Multiple contacts match "Rebecca": "#))
        #expect(output.content.contains(#"1. Rebecca A <rebecca.a@example.com> (iMessage)"#))
        #expect(output.content.contains(#"2. Rebecca B <rebecca.b@example.com>"#))
        #expect(output.content.contains(#"3. Rebecca C <rebecca.c@example.com>"#))
        #expect(!output.content.contains("rebecca.d@example.com"))
        #expect(output.content.hasSuffix(" Ask the user which one, then retry with the exact handle."))
        #expect(gateway.sentMessages.isEmpty)
    }

    @Test
    func `Zero match asks for an exact phone number or email`() async throws {
        let resolver = StubMessagesRecipientResolver()
        let gateway = StubMessagesGateway()

        let output = try await execute(#"{"recipient":"Rebecca","text":"Hi"}"#, gateway: gateway, resolver: resolver)

        #expect(output.isError == true)
        #expect(
            output.content
                == #"No contact or recent conversation matches "Rebecca". Ask the user for the exact phone number or email, or grant Contacts access to Rune Weaver in System Settings -> Privacy & Security -> Contacts."#
        )
        #expect(gateway.sentMessages.isEmpty)
    }

    @Test
    func `Dry-run name send refuses identically without a preview envelope`() async throws {
        let selected = candidate(displayName: "Rebecca Mackin", handle: "rebecca@example.com")
        let resolver = StubMessagesRecipientResolver(resolutionsByName: [
            "Rebecca Mackin": MessageRecipientResolution(query: "Rebecca Mackin", candidates: [selected], selected: selected)
        ])
        let gateway = StubMessagesGateway()

        let output = try await execute(
            #"{"recipient":"Rebecca Mackin","text":"On my way"}"#,
            gateway: gateway,
            resolver: resolver,
            dryRun: true
        )

        #expect(output.isError == true)
        #expect(output.content.contains("is a display name, not a phone number or email"))
        #expect(!output.content.contains("Dry run"))
        #expect(!output.content.contains("\"success\""))
        #expect(gateway.sentMessages.isEmpty)
    }

    @Test
    func `Name refusal without a wired resolver still fails closed`() async throws {
        let gateway = StubMessagesGateway()

        let output = try await execute(#"{"recipient":"Rebecca","text":"Hi"}"#, gateway: gateway)

        #expect(output.isError == true)
        #expect(output.content.contains(#"No contact or recent conversation matches "Rebecca"."#))
        #expect(gateway.sentMessages.isEmpty)
    }

    @Test
    func `Candidate-bearing name refusal reaches model context as labeled untrusted data`() async throws {
        let selected = candidate(displayName: "Rebecca Mackin", handle: "rebecca@example.com")
        let resolver = StubMessagesRecipientResolver(resolutionsByName: [
            "Rebecca Mackin": MessageRecipientResolution(query: "Rebecca Mackin", candidates: [selected], selected: selected)
        ])
        let tool = MessagesSendTool(gateway: StubMessagesGateway(), resolver: resolver)
        #expect(tool.contentTrustLevel == .untrustedExternal)

        let output = try await tool.execute(
            input: ToolInput(toolName: "messages.send", argumentsJSON: #"{"recipient":"Rebecca Mackin","text":"On my way"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == true)

        // The refusal embeds contact-derived candidate fields, so it must enter
        // model context delimited as data even though it is a failed result.
        let labeled = OrchestratorToolLoop.labeledResultContent(output.content, for: tool)
        #expect(labeled.contains(ContentTrustLabeler.banner))
        #expect(labeled.contains(ContentTrustLabeler.beginDelimiter(toolName: "messages.send")))
        #expect(labeled.contains("rebecca@example.com"))
        #expect(labeled.hasSuffix(ContentTrustLabeler.endDelimiter))
    }

    // MARK: - Handle passthrough and canonicalization

    @Test
    func `Handle recipient passes through and never consults the resolver`() async throws {
        let resolver = StubMessagesRecipientResolver()
        let gateway = StubMessagesGateway()

        let output = try await execute(
            #"{"recipient":"alice@example.com","text":"Lunch today?"}"#,
            gateway: gateway,
            resolver: resolver
        )

        #expect(output.isError == false)
        #expect(gateway.sentMessages.count == 1)
        #expect(gateway.sentMessages.first?.recipient == "alice@example.com")
        #expect(resolver.queries.isEmpty)

        let envelope = try JSONDecoder().decode(MessagesSendEnvelope.self, from: Data(output.content.utf8))
        #expect(envelope.success == true)
        #expect(envelope.recipient == "alice@example.com")
    }

    @Test
    func `Phone punctuation canonicalizes before the gateway and the preview`() async throws {
        let gateway = StubMessagesGateway()

        let sent = try await execute(
            #"{"recipient":"+1 (555) 123-4567","text":"Hi"}"#,
            gateway: gateway
        )
        #expect(sent.isError == false)
        #expect(gateway.sentMessages.first?.recipient == "+15551234567")

        let preview = try await execute(
            #"{"recipient":"(555) 123-4567","text":"Hi"}"#,
            gateway: gateway,
            dryRun: true
        )
        let envelope = try JSONDecoder().decode(MessagesSendEnvelope.self, from: Data(preview.content.utf8))
        #expect(envelope.recipient == "5551234567")
        #expect(envelope.note?.contains("'5551234567'") == true)
    }

    // MARK: - Alias learning

    @Test
    func `Successful resolved-name send records exactly one alias`() async throws {
        let aliasStore = StubMessageAliasStore()
        let gateway = StubMessagesGateway()

        let output = try await execute(
            #"{"recipient":"+1 (555) 123-4567","text":"On my way","resolvedFrom":"Rebecca Mackin"}"#,
            gateway: gateway,
            aliasStore: aliasStore
        )

        #expect(output.isError == false)
        #expect(gateway.sentMessages.first?.recipient == "+15551234567")
        #expect(aliasStore.recorded.count == 1)
        let recorded = try #require(aliasStore.recorded.first)
        #expect(recorded.name == "Rebecca Mackin")
        #expect(recorded.handle == "+15551234567")
        #expect(recorded.service == nil)
        #expect(recorded.displayName == nil)
    }

    @Test
    func `Exact-handle send without resolvedFrom records no alias`() async throws {
        let aliasStore = StubMessageAliasStore()
        let gateway = StubMessagesGateway()

        let output = try await execute(
            #"{"recipient":"alice@example.com","text":"Hi"}"#,
            gateway: gateway,
            aliasStore: aliasStore
        )

        #expect(output.isError == false)
        #expect(aliasStore.recorded.isEmpty)
    }

    @Test
    func `Failed gateway send records no alias and keeps the failure text`() async throws {
        let aliasStore = StubMessageAliasStore()
        let gateway = StubMessagesGateway()
        gateway.shouldFailSend = "boom"

        let output = try await execute(
            #"{"recipient":"alice@example.com","text":"Hi","resolvedFrom":"Rebecca"}"#,
            gateway: gateway,
            aliasStore: aliasStore
        )

        #expect(output.isError == true)
        #expect(output.content.contains("messages.send failed"))
        #expect(aliasStore.recorded.isEmpty)
    }

    @Test
    func `Refused and dry-run sends record no alias`() async throws {
        let aliasStore = StubMessageAliasStore()
        let refusedTool = MessagesSendTool(
            gateway: RefusedSendGateway(),
            recipientAliasStore: aliasStore
        )
        let refused = try await refusedTool.execute(
            input: ToolInput(toolName: "messages.send", argumentsJSON: #"{"recipient":"alice@example.com","text":"Hi","resolvedFrom":"Rebecca"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(refused.isError == false)

        let gateway = StubMessagesGateway()
        let dryRun = try await execute(
            #"{"recipient":"alice@example.com","text":"Hi","resolvedFrom":"Rebecca"}"#,
            gateway: gateway,
            aliasStore: aliasStore,
            dryRun: true
        )
        #expect(dryRun.isError == false)
        #expect(aliasStore.recorded.isEmpty)
    }

    @Test
    func `Name refusal records no alias`() async throws {
        let aliasStore = StubMessageAliasStore()
        let resolver = StubMessagesRecipientResolver()
        let gateway = StubMessagesGateway()

        let output = try await execute(
            #"{"recipient":"Rebecca","text":"Hi","resolvedFrom":"Rebecca"}"#,
            gateway: gateway,
            resolver: resolver,
            aliasStore: aliasStore
        )

        #expect(output.isError == true)
        #expect(aliasStore.recorded.isEmpty)
    }

    // MARK: - Factory plumbing and argument decoding

    @Test
    func `Factory forwards resolver and alias store into the send tool`() async throws {
        let selected = candidate(displayName: "Rebecca", handle: "+15551234567")
        let resolver = StubMessagesRecipientResolver(resolutionsByName: [
            "Rebecca": MessageRecipientResolution(query: "Rebecca", candidates: [selected], selected: selected)
        ])
        let aliasStore = StubMessageAliasStore()
        let gateway = StubMessagesGateway()
        let tools = MessagesTools.makeTools(gateway: gateway, resolver: resolver, recipientAliasStore: aliasStore)
        let send = try #require(tools.first { $0.name == "messages.send" })

        let refused = try await send.execute(
            input: ToolInput(toolName: "messages.send", argumentsJSON: #"{"recipient":"Rebecca","text":"Hi"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(refused.isError == true)
        #expect(resolver.queries == ["Rebecca"])

        let sent = try await send.execute(
            input: ToolInput(toolName: "messages.send", argumentsJSON: #"{"recipient":"+15551234567","text":"Hi","resolvedFrom":"Rebecca"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(sent.isError == false)
        #expect(aliasStore.recorded.count == 1)
        #expect(aliasStore.recorded.first?.handle == "+15551234567")
    }

    @Test
    func `Send args decode resolvedFrom with trimming and blank folding`() throws {
        let args = try JSONDecoder().decode(
            MessagesSendArgs.self,
            from: Data(#"{"to":"+1 (555) 123-4567","message":"Hi","resolvedFrom":"  Rebecca Mackin  "}"#.utf8)
        )
        #expect(args.recipient == "+1 (555) 123-4567")
        #expect(args.text == "Hi")
        #expect(args.resolvedFrom == "Rebecca Mackin")

        let blank = try JSONDecoder().decode(
            MessagesSendArgs.self,
            from: Data(#"{"recipient":"a@example.com","text":"Hi","resolvedFrom":"   "}"#.utf8)
        )
        #expect(blank.resolvedFrom == nil)

        let missing = try JSONDecoder().decode(
            MessagesSendArgs.self,
            from: Data(#"{"recipient":"a@example.com","text":"Hi"}"#.utf8)
        )
        #expect(missing.resolvedFrom == nil)
    }

    @Test
    func `Send args reject a null byte in resolvedFrom`() throws {
        do {
            _ = try JSONDecoder().decode(
                MessagesSendArgs.self,
                from: Data(#"{"recipient":"a@example.com","text":"Hi","resolvedFrom":"Re\u0000becca"}"#.utf8)
            )
            Issue.record("Expected a DecodingError for a null byte in resolvedFrom")
        } catch let error as DecodingError {
            guard case let .dataCorrupted(context) = error else {
                Issue.record("Expected dataCorrupted, got \(error)")
                return
            }
            #expect(context.debugDescription.contains("null bytes"))
        } catch {
            Issue.record("Expected DecodingError, got \(error)")
        }
    }

    // MARK: - Pre-admission validation

    @Test
    func `Admission verdict refuses a name with the shared candidates and proceeds for handles`() async {
        let selected = candidate(displayName: "Rebecca Mackin", handle: "rebecca@example.com", service: "iMessage")
        let resolver = StubMessagesRecipientResolver(resolutionsByName: [
            "Rebecca Mackin": MessageRecipientResolution(query: "Rebecca Mackin", candidates: [selected], selected: selected)
        ])
        let tool = MessagesSendTool(gateway: StubMessagesGateway(), resolver: resolver)

        let verdict = await tool.admissionVerdict(for: ToolInput(
            toolName: "messages.send",
            argumentsJSON: #"{"recipient":"Rebecca Mackin","text":"On my way"}"#
        ))
        guard case let .refuse(reason) = verdict else {
            Issue.record("Expected a pre-admission refusal for a name-shaped recipient")
            return
        }
        #expect(
            reason
                == #"Recipient "Rebecca Mackin" is a display name, not a phone number or email. Best match: Rebecca Mackin <rebecca@example.com> (iMessage). Retry messages.send with recipient "rebecca@example.com" and resolvedFrom "Rebecca Mackin"."#
        )
        #expect(resolver.queries == ["Rebecca Mackin"])

        // Handles and malformed shapes keep their existing admission path:
        // `execute` owns the argument-shape errors.
        let handleVerdict = await tool.admissionVerdict(for: ToolInput(
            toolName: "messages.send",
            argumentsJSON: #"{"recipient":"+1 (555) 123-4567","text":"Hi"}"#
        ))
        #expect(handleVerdict == .proceed)
        let blankVerdict = await tool.admissionVerdict(for: ToolInput(
            toolName: "messages.send",
            argumentsJSON: #"{"recipient":"","text":"Hi"}"#
        ))
        #expect(blankVerdict == .proceed)
        let missingVerdict = await tool.admissionVerdict(for: ToolInput(
            toolName: "messages.send",
            argumentsJSON: #"{"text":"Hi"}"#
        ))
        #expect(missingVerdict == .proceed)
    }

    @Test
    func `Admission refuses a name when companion fields are missing, blank, or wrong-typed`() async throws {
        let selected = candidate(displayName: "Rebecca Mackin", handle: "rebecca@example.com", service: "iMessage")
        let resolver = StubMessagesRecipientResolver(resolutionsByName: [
            "Rebecca Mackin": MessageRecipientResolution(query: "Rebecca Mackin", candidates: [selected], selected: selected)
        ])
        let tool = MessagesSendTool(gateway: StubMessagesGateway(), resolver: resolver)

        // Each shape is name-shaped but malformed as a full `MessagesSendArgs`
        // decode, so pre-admission must judge the recipient on its own.
        let nameShapes = [
            #"{"recipient":"Rebecca Mackin"}"#,
            #"{"recipient":"Rebecca Mackin","text":""}"#,
            #"{"recipient":"Rebecca Mackin","text":123}"#,
            #"{"to":"Rebecca Mackin","text":123}"#,
            #"{"recipient":"Rebecca Mackin","to":123}"#
        ]
        for argumentsJSON in nameShapes {
            let verdict = await tool.admissionVerdict(for: ToolInput(
                toolName: "messages.send",
                argumentsJSON: argumentsJSON
            ))
            guard case let .refuse(reason) = verdict else {
                Issue.record("Expected a pre-admission refusal for \(argumentsJSON)")
                continue
            }
            #expect(reason.contains("is a display name, not a phone number or email"))
            #expect(reason.contains(#"Retry messages.send with recipient "rebecca@example.com""#))
        }
        #expect(resolver.queries.count == nameShapes.count)

        // A nameless malformed shape keeps the existing admission path so
        // `execute` reports its own argument error.
        let namelessVerdict = await tool.admissionVerdict(for: ToolInput(
            toolName: "messages.send",
            argumentsJSON: #"{"text":"hi"}"#
        ))
        #expect(namelessVerdict == .proceed)
        let namelessOutput = try await execute(#"{"text":"hi"}"#, gateway: StubMessagesGateway(), resolver: resolver)
        #expect(namelessOutput.isError == true)
        #expect(namelessOutput.content.contains("Invalid messages.send arguments"))

        // A wrong-typed recipient and a null-byte recipient are malformed, not
        // name-shaped, so `execute` keeps reporting the argument error.
        let wrongTypedVerdict = await tool.admissionVerdict(for: ToolInput(
            toolName: "messages.send",
            argumentsJSON: #"{"recipient":123,"text":"Hi"}"#
        ))
        #expect(wrongTypedVerdict == .proceed)
        let nullByteVerdict = await tool.admissionVerdict(for: ToolInput(
            toolName: "messages.send",
            argumentsJSON: #"{"recipient":"Re\u0000becca","text":"Hi"}"#
        ))
        #expect(nullByteVerdict == .proceed)
    }
}

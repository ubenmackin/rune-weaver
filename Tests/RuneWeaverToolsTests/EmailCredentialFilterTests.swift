// Rune Weaver Tools Tests — Deterministic credential filter for agent-visible mail.
//
// Pins the least-privilege boundary around one-time codes, magic sign-in
// links, and password-reset links: definite signals redact link URLs and code
// values while subjects and senders stay visible, suspicious hints pass
// through untouched, the disabled filter is byte-identical, ordinary numbers
// never trigger without a nearby keyword, and the index gateway ingests the
// same redacted form the tools show so recall cannot resurrect a hidden link.

import Foundation
@testable import RuneWeaverCore
@testable import RuneWeaverTools
import Testing

@Suite("Email Credential Filter")
struct EmailCredentialFilterTests {
    @Test
    func `One-time code redacts value but keeps headers`() throws {
        let subject = "Your verification code"
        let body = "Hi, your verification code is 482913. Enter it within 10 minutes."
        let verdict = EmailCredentialFilter.assess(subject: subject, body: body)
        #expect(verdict.level == .credentialBearing)
        let redacted = try #require(verdict.redactedBody)
        #expect(!redacted.contains("482913"))
        #expect(redacted.contains(EmailCredentialFilter.redactedCodePlaceholder))
    }

    @Test
    func `Spaced code near keyword redacts`() throws {
        let verdict = EmailCredentialFilter.assess(
            subject: "Login",
            body: "Your OTP is 123 456 for this sign-in attempt."
        )
        #expect(verdict.level == .credentialBearing)
        let redacted = try #require(verdict.redactedBody)
        #expect(!redacted.contains("123 456"))
        #expect(redacted.contains(EmailCredentialFilter.redactedCodePlaceholder))
    }

    @Test
    func `Magic link redacts URL`() throws {
        let body = "Click this magic link to sign in: https://accounts.example.com/auth/magic?token=abc123XYZ — it expires soon."
        let verdict = EmailCredentialFilter.assess(subject: "Sign in", body: body)
        #expect(verdict.level == .credentialBearing)
        let redacted = try #require(verdict.redactedBody)
        #expect(!redacted.contains("abc123XYZ"))
        #expect(!redacted.contains("accounts.example.com/auth/magic"))
        #expect(redacted.contains(EmailCredentialFilter.redactedLinkPlaceholder))
    }

    @Test
    func `Sign-in link phrase with URL redacts`() throws {
        let body = "Here is your sign-in link: https://example.com/signin?token=hello-world-1 — tap to continue."
        let verdict = EmailCredentialFilter.assess(subject: "Your sign-in link", body: body)
        #expect(verdict.level == .credentialBearing)
        let redacted = try #require(verdict.redactedBody)
        #expect(redacted.contains(EmailCredentialFilter.redactedLinkPlaceholder))
    }

    @Test
    func `Password reset redacts reset URL`() throws {
        let body = "Reset your password here: https://example.com/reset?token=xyz789 — ignore if you did not ask."
        let verdict = EmailCredentialFilter.assess(subject: "Password reset requested", body: body)
        #expect(verdict.level == .credentialBearing)
        let redacted = try #require(verdict.redactedBody)
        #expect(!redacted.contains("xyz789"))
        #expect(redacted.contains(EmailCredentialFilter.redactedLinkPlaceholder))
    }

    @Test
    func `Set a new password phrase redacts`() throws {
        let body = "Set a new password at https://example.com/account/reset-password?code=999000 now."
        let verdict = EmailCredentialFilter.assess(subject: "Security", body: body)
        #expect(verdict.level == .credentialBearing)
        let redacted = try #require(verdict.redactedBody)
        #expect(redacted.contains(EmailCredentialFilter.redactedLinkPlaceholder))
    }

    @Test
    func `Suspicious hint passes unredacted`() {
        let verdict = EmailCredentialFilter.assess(
            subject: "Security alert",
            body: "We noticed a login attempt. If this was you, ignore this note."
        )
        #expect(verdict.level == .suspicious)
        #expect(verdict.redactedBody == nil)
        let hit = EmailSearchHit(
            id: "9",
            subject: "Security alert",
            from: "security@example.com",
            date: "Mon, 01 Sep 2025 09:00:00 +0000",
            snippet: "We noticed a login attempt. If this was you, ignore this note."
        )
        #expect(hit.agentVisible() == hit)
    }

    @Test
    func `Keyword without code stays suspicious`() {
        let verdict = EmailCredentialFilter.assess(
            subject: "Hello",
            body: "Your verification code will arrive shortly in a separate note."
        )
        #expect(verdict.level == .suspicious)
        #expect(verdict.redactedBody == nil)
    }

    @Test
    func `Ordinary mail without signals is none`() {
        let verdict = EmailCredentialFilter.assess(
            subject: "Quarterly report",
            body: "Please review the quarterly numbers attached."
        )
        #expect(verdict.level == .none)
        #expect(verdict.redactedBody == nil)
    }

    @Test
    func `Dates and prices without keywords never redact`() {
        let body = "Meeting notes from 2026-09-23. Total $19.99 due. Invoice year 2024, ref 77."
        let verdict = EmailCredentialFilter.assess(subject: "Notes", body: body)
        #expect(verdict.level == .none)
        #expect(EmailCredentialFilter.agentVisibleBody(subject: "Notes", body: body, enabled: true) == body)
    }

    @Test
    func `Distant code outside the window does not trigger`() {
        let filler = String(repeating: "lorem ipsum dolor sit amet ", count: 30)
        let body = "Verification info below. " + filler + " 482913"
        let verdict = EmailCredentialFilter.assess(subject: "Hello", body: body)
        #expect(verdict.level != .credentialBearing)
    }

    @Test
    func `Nearby code inside the window triggers`() {
        let body = "Your verification code is 482913 — enter it now."
        let verdict = EmailCredentialFilter.assess(subject: "Hello", body: body)
        #expect(verdict.level == .credentialBearing)
    }

    @Test
    func `Matching stays case-insensitive and scheme-agnostic`() throws {
        let upper = EmailCredentialFilter.assess(
            subject: "VERIFY",
            body: "YOUR VERIFICATION CODE IS 739201."
        )
        #expect(upper.level == .credentialBearing)
        let www = EmailCredentialFilter.assess(
            subject: "Sign in",
            body: "Magic link: www.example.com/magic?token=ZZZ111 — tap to sign in."
        )
        #expect(www.level == .credentialBearing)
        let wwwRedacted = try #require(www.redactedBody)
        #expect(wwwRedacted.contains(EmailCredentialFilter.redactedLinkPlaceholder))
        let bare = EmailCredentialFilter.assess(
            subject: "Reset",
            body: "Reset your password at accounts.example.com/reset?token=qrs222 now."
        )
        #expect(bare.level == .credentialBearing)
    }

    @Test
    func `Disabled filter passes byte-identically`() {
        let subject = "Your verification code"
        let body = "Your verification code is 482913: https://example.com/auth?token=abc."
        let hit = EmailSearchHit(
            id: "1",
            subject: subject,
            from: "no-reply@example.com",
            date: "Mon, 01 Sep 2025 09:00:00 +0000",
            snippet: body
        )
        #expect(hit.agentVisible(credentialFilterEnabled: false) == hit)
        let message = EmailFullMessage(
            id: "1",
            subject: subject,
            from: "no-reply@example.com",
            to: "you@yourdomain.com",
            date: "Mon, 01 Sep 2025 09:00:00 +0000",
            body: body
        )
        #expect(message.agentVisible(credentialFilterEnabled: false) == message)
        #expect(EmailCredentialFilter.agentVisibleBody(subject: subject, body: body, enabled: false) == body)
        #expect(EmailCredentialFilter.agentVisibleSnippet(subject: subject, snippet: body, enabled: false) == body)
    }

    @Test
    func `Sender and subject stay visible after redaction`() {
        let hit = EmailSearchHit(
            id: "7",
            subject: "Your verification code",
            from: "no-reply@example.com",
            date: "Mon, 01 Sep 2025 09:00:00 +0000",
            snippet: "Your verification code is 482913 — welcome."
        )
        let visible = hit.agentVisible()
        #expect(visible.subject == hit.subject)
        #expect(visible.from == hit.from)
        #expect(visible.id == hit.id)
        #expect(!visible.snippet.contains("482913"))
        #expect(visible.snippet.contains(EmailCredentialFilter.redactedCodePlaceholder))

        let message = EmailFullMessage(
            id: "8",
            subject: "Reset your password",
            from: "support@example.com",
            to: "you@yourdomain.com",
            date: "Mon, 01 Sep 2025 09:00:00 +0000",
            body: "Reset your password: https://example.com/reset?token=abc123"
        )
        let visibleMessage = message.agentVisible()
        #expect(visibleMessage.subject == message.subject)
        #expect(visibleMessage.from == message.from)
        #expect(visibleMessage.to == message.to)
        #expect(!visibleMessage.body.contains("abc123"))
        #expect(visibleMessage.body.contains(EmailCredentialFilter.redactedLinkPlaceholder))
    }

    @Test
    func `Search tool redacts at the envelope boundary when enabled`() async throws {
        let credentialHit = EmailSearchHit(
            id: "42",
            subject: "Your verification code",
            from: "no-reply@example.com",
            date: "Mon, 01 Sep 2025 09:00:00 +0000",
            snippet: "Your verification code is 482913 — enter it now."
        )
        let gateway = ToolsTestSupport.StubEmailGateway(hits: [credentialHit])
        let tool = EmailSearchTool(emailConfig: ToolsTestSupport.testEmailConfig(), gateway: gateway)
        try await ToolsTestSupport.withTestPassword {
            let output = try await tool.execute(
                input: ToolInput(toolName: "email.search", argumentsJSON: #"{"account":"personal","query":"*","limit":5}"#),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == false)
            #expect(!output.content.contains("482913"))
            #expect(output.content.contains(EmailCredentialFilter.redactedCodePlaceholder))
            #expect(output.content.contains("Your verification code"))
            #expect(output.content.contains("no-reply@example.com"))
        }
    }

    @Test
    func `Search tool passes byte-identically when disabled`() async throws {
        let credentialHit = EmailSearchHit(
            id: "42",
            subject: "Your verification code",
            from: "no-reply@example.com",
            date: "Mon, 01 Sep 2025 09:00:00 +0000",
            snippet: "Your verification code is 482913 — enter it now."
        )
        var disabled = SecurityConfig()
        disabled.emailCredentialFilter = false
        let gateway = ToolsTestSupport.StubEmailGateway(hits: [credentialHit])
        let tool = EmailSearchTool(
            emailConfig: ToolsTestSupport.testEmailConfig(),
            gateway: gateway,
            securityConfig: disabled
        )
        try await ToolsTestSupport.withTestPassword {
            let output = try await tool.execute(
                input: ToolInput(toolName: "email.search", argumentsJSON: #"{"account":"personal","query":"*","limit":5}"#),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == false)
            #expect(output.content.contains("482913"))
            #expect(!output.content.contains(EmailCredentialFilter.redactedCodePlaceholder))
        }
    }

    @Test
    func `Read tool redacts body but keeps headers`() async throws {
        let message = EmailFullMessage(
            id: "7",
            subject: "Reset your password",
            from: "support@example.com",
            to: "you@yourdomain.com",
            date: "Mon, 01 Sep 2025 09:00:00 +0000",
            body: "Reset your password: https://example.com/reset?token=secret999"
        )
        let tool = EmailReadTool(
            emailConfig: ToolsTestSupport.testEmailConfig(),
            gateway: ToolsTestSupport.StubEmailGateway(message: message)
        )
        try await ToolsTestSupport.withTestPassword {
            let output = try await tool.execute(
                input: ToolInput(toolName: "email.read", argumentsJSON: #"{"account":"personal","id":"7","mailbox":"INBOX"}"#),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == false)
            #expect(!output.content.contains("secret999"))
            #expect(output.content.contains(EmailCredentialFilter.redactedLinkPlaceholder))
            #expect(output.content.contains("Reset your password"))
            #expect(output.content.contains("support@example.com"))
        }
    }

    @Test
    func `Index adapter ingests the redacted form`() async throws {
        let message = EmailFullMessage(
            id: "11",
            subject: "Your verification code",
            from: "no-reply@example.com",
            to: "you@yourdomain.com",
            date: "Mon, 01 Sep 2025 09:00:00 +0000",
            body: "Your verification code is 482913: https://example.com/auth?token=abc123"
        )
        let hit = EmailSearchHit(
            id: "11",
            subject: message.subject,
            from: message.from,
            date: message.date,
            snippet: "Your verification code is 482913"
        )
        let stub = ToolsTestSupport.StubEmailGateway(hits: [hit], message: message)
        let adapter = EmailIMAPMailIndexGateway(
            gateway: stub,
            eventLog: MailSessionEventLog(sink: { _ in })
        )
        let credentials = MailIndexCredentials(
            accountName: "personal",
            host: "mail.yourdomain.com",
            port: 993,
            username: "you@yourdomain.com",
            password: "test-secret"
        )
        let indexed = try await adapter.messages(
            credentials: credentials,
            mailbox: "INBOX",
            limit: 10,
            mode: .peek
        )
        #expect(indexed.count == 1)
        #expect(indexed[0].subject == message.subject)
        #expect(indexed[0].from == message.from)
        #expect(!indexed[0].body.contains("482913"))
        #expect(!indexed[0].body.contains("abc123"))
        #expect(indexed[0].body.contains(EmailCredentialFilter.redactedCodePlaceholder))
        #expect(indexed[0].body.contains(EmailCredentialFilter.redactedLinkPlaceholder))
    }

    @Test
    func `Index adapter passes byte-identically when disabled`() async throws {
        let message = EmailFullMessage(
            id: "12",
            subject: "Your verification code",
            from: "no-reply@example.com",
            to: "you@yourdomain.com",
            date: "Mon, 01 Sep 2025 09:00:00 +0000",
            body: "Your verification code is 482913."
        )
        let hit = EmailSearchHit(
            id: "12",
            subject: message.subject,
            from: message.from,
            date: message.date,
            snippet: message.body
        )
        let stub = ToolsTestSupport.StubEmailGateway(hits: [hit], message: message)
        let adapter = EmailIMAPMailIndexGateway(
            gateway: stub,
            credentialFilterEnabled: false,
            eventLog: MailSessionEventLog(sink: { _ in })
        )
        let credentials = MailIndexCredentials(
            accountName: "personal",
            host: "mail.yourdomain.com",
            port: 993,
            username: "you@yourdomain.com",
            password: "test-secret"
        )
        let indexed = try await adapter.messages(
            credentials: credentials,
            mailbox: "INBOX",
            limit: 10,
            mode: .peek
        )
        #expect(indexed.count == 1)
        #expect(indexed[0].body == message.body)
    }

    @Test
    func `Security defaults keep the filter on`() {
        #expect(SecurityConfig().emailCredentialFilter == true)
        #expect(SecurityConfig.defaultEmailCredentialFilter == true)
        #expect(SecurityConfig().untrustedLabeling == true)
    }

    @Test
    func `Absent security section defaults the filter on`() throws {
        let text = """
        [llm]
        default_provider = "mlx"

        [llm.providers.mlx]
        enabled = true
        model = "gemma-4-9b"
        server_url = "http://localhost:8080"
        """
        let config = try RuneWeaverConfig(decoding: TOMLParser.parse(text))
        #expect(config.security.emailCredentialFilter == true)
        #expect(config.security.untrustedLabeling == true)
        try config.validate()
    }

    @Test
    func `Security section round-trips both keys additively`() throws {
        let text = """
        [llm]
        default_provider = "mlx"

        [llm.providers.mlx]
        enabled = true
        model = "gemma-4-9b"
        server_url = "http://localhost:8080"

        [security]
        untrusted_labeling = false
        email_credential_filter = false
        """
        let config = try RuneWeaverConfig(decoding: TOMLParser.parse(text))
        #expect(config.security.untrustedLabeling == false)
        #expect(config.security.emailCredentialFilter == false)
        try config.validate()
        let toml = config.renderTOML()
        #expect(toml.contains("[security]"))
        #expect(toml.contains("untrusted_labeling = false"))
        #expect(toml.contains("email_credential_filter = false"))
        let decoded = try RuneWeaverConfig(decoding: TOMLParser.parse(toml))
        #expect(decoded.security.untrustedLabeling == false)
        #expect(decoded.security.emailCredentialFilter == false)
        var enabled = RuneWeaverConfig.default
        enabled.security.emailCredentialFilter = true
        #expect(enabled.renderTOML().contains("email_credential_filter = true"))
    }
}

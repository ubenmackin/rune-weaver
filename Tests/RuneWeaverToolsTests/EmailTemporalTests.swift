// Rune Weaver Tools Tests — Temporal window coverage for email.search.
//
// Purpose: pin the shared since/until contract for email.search so dated
// windows, fail-closed rejection, IMAP date shaping, and Swift post-filtering
// stay identical across gateways and scripts.
// Scope: args decoding with blank-as-omitted, parse-before-credentials,
// IMAP payload dates, Python criteria shapes, Swift post-filtering with
// unparseable handling, and fan-out merge newest-first under the existing cap.
// Architectural role: guards the email side of the single TemporalFilter choke
// point without re-implementing date math.

import Foundation
@testable import RuneWeaverCore
@testable import RuneWeaverTools
import Testing

/// Serialized temporal coverage: credential environment mutation is process-global.
@Suite("Email Temporal", .serialized)
struct EmailTemporalTests {
    /// Formats an instant as RFC2822 so the shared merge parser round-trips it.
    private static func rfc2822(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }

    /// Builds a hit stamped at an absolute instant.
    private static func hit(id: String, date: Date, mailbox: String = "INBOX") -> EmailSearchHit {
        EmailSearchHit(
            id: id,
            subject: "Subject \(id)",
            from: "sender@example.com",
            date: rfc2822(date),
            snippet: "Snippet \(id)",
            mailbox: mailbox
        )
    }

    /// Builds a hit with a raw date header that may not parse.
    private static func rawHit(id: String, rawDate: String, mailbox: String = "INBOX") -> EmailSearchHit {
        EmailSearchHit(
            id: id,
            subject: "Subject \(id)",
            from: "sender@example.com",
            date: rawDate,
            snippet: "Snippet \(id)",
            mailbox: mailbox
        )
    }

    @Test
    func `Search args decode since until and blank behaves as omitted`() throws {
        let decoded = try JSONDecoder().decode(
            EmailSearchArgs.self,
            from: Data(#"{"account":"personal","query":"hi","since":"2026-09-13","until":"2026-09-14"}"#.utf8)
        )
        #expect(decoded.since == "2026-09-13")
        #expect(decoded.until == "2026-09-14")
        #expect(decoded.trimmedSince == "2026-09-13")
        #expect(decoded.trimmedUntil == "2026-09-14")

        let blank = try JSONDecoder().decode(
            EmailSearchArgs.self,
            from: Data(#"{"account":"personal","query":"hi","since":"   ","until":""}"#.utf8)
        )
        #expect(blank.since == nil)
        #expect(blank.until == nil)
        #expect(blank.trimmedSince == nil)
        #expect(blank.trimmedUntil == nil)

        let omitted = try JSONDecoder().decode(
            EmailSearchArgs.self,
            from: Data(#"{"account":"personal","query":"hi"}"#.utf8)
        )
        #expect(omitted.since == nil)
        #expect(omitted.until == nil)

        // Memberwise init also normalizes blank to omitted.
        let direct = EmailSearchArgs(account: "personal", query: "hi", since: "  ", until: "2026-09-14")
        #expect(direct.since == nil)
        #expect(direct.until == "2026-09-14")
    }

    @Test
    func `Malformed since fails naming since before credentials`() async throws {
        let tool = EmailSearchTool(
            emailConfig: ToolsTestSupport.testEmailConfig(),
            gateway: ToolsTestSupport.StubEmailGateway()
        )
        // No password installed: temporal rejection must win over credential resolution.
        let output = try await tool.execute(
            input: ToolInput(toolName: "email.search", argumentsJSON: #"{"account":"personal","query":"hi","since":"not-a-date"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == true)
        #expect(output.content.contains("since"))
        #expect(!output.content.contains("Missing password"))
    }

    @Test
    func `Malformed until names until and inverted rejects`() async throws {
        let tool = EmailSearchTool(
            emailConfig: ToolsTestSupport.testEmailConfig(),
            gateway: ToolsTestSupport.StubEmailGateway()
        )
        let badUntil = try await tool.execute(
            input: ToolInput(toolName: "email.search", argumentsJSON: #"{"account":"personal","query":"hi","until":"yesterday"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(badUntil.isError == true)
        #expect(badUntil.content.contains("until"))

        let inverted = try await tool.execute(
            input: ToolInput(toolName: "email.search", argumentsJSON: #"{"account":"personal","query":"hi","since":"2026-09-14","until":"2026-09-13"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(inverted.isError == true)
        #expect(inverted.content.contains("since") && inverted.content.contains("until"))
    }

    @Test
    func `Input schema carries since until with local-day ISO8601 copy`() {
        let tool = EmailSearchTool(
            emailConfig: ToolsTestSupport.testEmailConfig(),
            gateway: ToolsTestSupport.StubEmailGateway()
        )
        let raw = tool.inputSchema.rawValue
        #expect(raw.contains("\"since\""))
        #expect(raw.contains("\"until\""))
        #expect(raw.lowercased().contains("local"))
        #expect(raw.contains("ISO8601"))
    }

    @Test
    func `Day window returns hits dated that local day only`() async throws {
        let range = try TemporalFilter.parse(since: "2026-09-13", until: "2026-09-14")
        let lower = try #require(range.since)
        let upper = try #require(range.until)
        let inside = lower.addingTimeInterval(3600)
        let before = lower.addingTimeInterval(-1)
        let after = upper.addingTimeInterval(0)
        let hits = [
            Self.hit(id: "3", date: inside),
            Self.hit(id: "2", date: before),
            Self.hit(id: "1", date: after)
        ]
        let tool = EmailSearchTool(
            emailConfig: ToolsTestSupport.testEmailConfig(),
            gateway: ToolsTestSupport.StubEmailGateway(hits: hits)
        )
        try await ToolsTestSupport.withTestPassword {
            let output = try await tool.execute(
                input: ToolInput(
                    toolName: "email.search",
                    argumentsJSON: #"{"account":"personal","query":"*","since":"2026-09-13","until":"2026-09-14"}"#
                ),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == false)
            let envelope = try JSONDecoder().decode(EmailSearchEnvelope.self, from: Data(output.content.utf8))
            #expect(envelope.messages.map(\.id) == ["3"])
        }
    }

    @Test
    func `July window scopes July and undated keeps everything`() async throws {
        let range = try TemporalFilter.parse(since: "2026-07-01", until: "2026-08-01")
        let lower = try #require(range.since)
        let upper = try #require(range.until)
        let july = lower.addingTimeInterval(86400 * 10)
        let june = lower.addingTimeInterval(-3600)
        let august = upper.addingTimeInterval(1)
        let hits = [
            Self.hit(id: "10", date: july),
            Self.hit(id: "9", date: june),
            Self.hit(id: "8", date: august)
        ]
        let tool = EmailSearchTool(
            emailConfig: ToolsTestSupport.testEmailConfig(),
            gateway: ToolsTestSupport.StubEmailGateway(hits: hits)
        )
        try await ToolsTestSupport.withTestPassword {
            let scoped = try await tool.execute(
                input: ToolInput(
                    toolName: "email.search",
                    argumentsJSON: #"{"account":"personal","query":"*","since":"2026-07-01","until":"2026-08-01"}"#
                ),
                context: ToolContext(conversationID: UUID())
            )
            #expect(scoped.isError == false)
            let envelope = try JSONDecoder().decode(EmailSearchEnvelope.self, from: Data(scoped.content.utf8))
            #expect(envelope.messages.map(\.id) == ["10"])

            let undated = try await tool.execute(
                input: ToolInput(toolName: "email.search", argumentsJSON: #"{"account":"personal","query":"*"}"#),
                context: ToolContext(conversationID: UUID())
            )
            #expect(undated.isError == false)
            let full = try JSONDecoder().decode(EmailSearchEnvelope.self, from: Data(undated.content.utf8))
            #expect(full.messages.count == 3)
        }
    }

    @Test
    func `Swift post-filter drops unparseable when bounded and keeps when unbounded`() throws {
        let range = try TemporalFilter.parse(since: "2026-09-13", until: "2026-09-14")
        let lower = try #require(range.since)
        let dated = Self.hit(id: "1", date: lower.addingTimeInterval(60))
        let broken = Self.rawHit(id: "2", rawDate: "not a date")
        let empty = Self.rawHit(id: "3", rawDate: "")
        // Bounded window keeps only parseable hits inside [since, until).
        let bounded = [dated, broken, empty].filter { range.matches(date: EmailSearchMerge.date(of: $0)) }
        #expect(bounded.map(\.id) == ["1"])
        // Unbounded window keeps everything, including unparseable headers.
        let unbounded = try TemporalFilter.parse(since: nil, until: nil)
        let kept = [dated, broken, empty].filter { unbounded.matches(date: EmailSearchMerge.date(of: $0)) }
        #expect(kept.count == 3)
        // Exact until instant belongs to the next window, not this one.
        let upper = try #require(range.until)
        let boundary = Self.hit(id: "4", date: upper)
        #expect(range.matches(date: EmailSearchMerge.date(of: boundary)) == false)
    }

    @Test
    func `Bridge request carries IMAP payload dates`() throws {
        let credentials = ResolvedEmailCredentials(
            accountName: "personal",
            host: "mail.example.com",
            port: 993,
            username: "you@example.com",
            password: "test-secret"
        )
        let range = try TemporalFilter.parse(since: "2026-09-13", until: "2026-09-14")
        let request = EmailIMAPBridgeRequest.search(
            credentials: credentials,
            query: "hello",
            limit: 10,
            mailbox: "INBOX",
            hasAttachment: nil,
            since: range.since,
            until: range.until
        )
        let payload = try JSONEncoder().encode(request)
        let document = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        let decoded = try #require(document)
        let sinceDate = try #require(range.since)
        let untilDate = try #require(range.until)
        #expect((decoded["since"] as? String) == TemporalFilter.imapDateString(from: sinceDate))
        #expect((decoded["until"] as? String) == TemporalFilter.imapDateString(from: untilDate))

        let unbounded = EmailIMAPBridgeRequest.search(
            credentials: credentials,
            query: "",
            limit: 10,
            mailbox: "INBOX"
        )
        let plain = try JSONEncoder().encode(unbounded)
        let plainDoc = try JSONSerialization.jsonObject(with: plain) as? [String: Any]
        #expect((plainDoc?["since"] as? String) == nil)
        #expect((plainDoc?["until"] as? String) == nil)
    }

    @Test
    func `Bridge request rounds non-midnight until for BEFORE`() throws {
        let credentials = ResolvedEmailCredentials(
            accountName: "personal",
            host: "mail.example.com",
            port: 993,
            username: "you@example.com",
            password: "test-secret"
        )
        let range = try TemporalFilter.parse(since: "2026-07-14", until: "2026-07-16")
        let sinceDate = try #require(range.since)
        let untilMidnight = try #require(range.until)
        let untilNoon = untilMidnight.addingTimeInterval(-12 * 3600)
        // untilNoon is noon on the 15th: same-day BEFORE would drop 00:00-12:00.
        #expect(TemporalFilter.imapDateString(from: untilNoon) == "15-Jul-2026")
        let request = EmailIMAPBridgeRequest.search(
            credentials: credentials,
            query: "hello",
            limit: 10,
            mailbox: "INBOX",
            hasAttachment: nil,
            since: sinceDate,
            until: untilNoon
        )
        let payload = try JSONEncoder().encode(request)
        let document = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        let decoded = try #require(document)
        // SINCE stays day-granular; BEFORE rounds up so the server keeps the 15th.
        #expect((decoded["since"] as? String) == TemporalFilter.imapDateString(from: sinceDate))
        #expect((decoded["until"] as? String) == "16-Jul-2026")
        #expect((decoded["until"] as? String) == TemporalFilter.imapUntilDateString(from: untilNoon))
    }

    @Test
    func `Session serializes non-midnight until rounded for BEFORE`() async throws {
        let range = try TemporalFilter.parse(since: "2026-07-14", until: "2026-07-16")
        let sinceDate = try #require(range.since)
        let untilMidnight = try #require(range.until)
        let untilNoon = untilMidnight.addingTimeInterval(-12 * 3600)
        let searchPayload = #"{"ok": true, "messages": []}"#
        let fake = FakeSessionLineTransport(responses: [#"{"ok": true}"#, searchPayload])
        let credentials = ResolvedEmailCredentials(
            accountName: "personal",
            host: "mail.example.com",
            port: 993,
            username: "you@example.com",
            password: "test-secret"
        )
        let session = EmailIMAPSession(credentials: credentials, transportFactory: { fake })
        try await session.start()
        _ = try await session.search(mailbox: "INBOX", query: "hello", limit: 10, since: sinceDate, until: untilNoon)
        let lines = fake.writtenLines
        #expect(lines.count == 2)
        let searchLine = try #require(lines.last)
        #expect(searchLine.contains(TemporalFilter.imapDateString(from: sinceDate)))
        #expect(searchLine.contains("16-Jul-2026"))
        await session.close()
    }

    @Test
    func `Session serializes bounds with IMAP date strings`() async throws {
        let range = try TemporalFilter.parse(since: "2026-09-13", until: "2026-09-14")
        let sinceDate = try #require(range.since)
        let untilDate = try #require(range.until)
        let sinceIMAP = TemporalFilter.imapDateString(from: sinceDate)
        let untilIMAP = TemporalFilter.imapDateString(from: untilDate)
        let searchPayload = #"{"ok": true, "messages": []}"#
        let fake = FakeSessionLineTransport(responses: [#"{"ok": true}"#, searchPayload])
        let credentials = ResolvedEmailCredentials(
            accountName: "personal",
            host: "mail.example.com",
            port: 993,
            username: "you@example.com",
            password: "test-secret"
        )
        let session = EmailIMAPSession(credentials: credentials, transportFactory: { fake })
        try await session.start()
        _ = try await session.search(mailbox: "INBOX", query: "hello", limit: 10, since: range.since, until: range.until)
        let lines = fake.writtenLines
        #expect(lines.count == 2)
        let searchLine = try #require(lines.last)
        #expect(searchLine.contains("\"since\""))
        #expect(searchLine.contains("\"until\""))
        #expect(searchLine.contains(sinceIMAP))
        #expect(searchLine.contains(untilIMAP))
        await session.close()
    }

    @Test
    func `Python helpers share the dated criteria shape`() throws {
        for source in [EmailIMAPBridgeScript.source, EmailIMAPSessionScript.source] {
            #expect(source.contains("since_imap"))
            #expect(source.contains("until_imap"))
            #expect(source.contains("date_prefix"))
            #expect(source.contains("SINCE %s BEFORE %s"))
            #expect(source.contains("SINCE %s"))
            #expect(source.contains("BEFORE %s"))
            // Dated keyword intersects the date prefix with the keyword OR shape.
            #expect(source.contains("%s OR OR SUBJECT"))
            // Dated wildcard sends the date prefix alone.
            #expect(source.contains("conn.uid(\"search\", None, date_prefix)"))
            // Undated shapes stay byte-identical.
            #expect(source.contains("conn.uid(\"search\", None, \"ALL\")"))
            #expect(source.contains("OR OR SUBJECT \"%s\" FROM \"%s\" BODY \"%s\""))
            try ToolsTestSupport.assertBridgeSourceParses(source)
        }
    }

    @Test
    func `Fan-out merge stays newest-first under cap with window`() async throws {
        let range = try TemporalFilter.parse(since: "2026-09-13", until: "2026-09-14")
        let lower = try #require(range.since)
        let first = lower.addingTimeInterval(3600)
        let second = lower.addingTimeInterval(7200)
        let third = lower.addingTimeInterval(10800)
        let stale = lower.addingTimeInterval(-7200)
        let inboxHits = [Self.hit(id: "1", date: first, mailbox: "INBOX"), Self.hit(id: "9", date: stale, mailbox: "INBOX")]
        let archiveHits = [Self.hit(id: "2", date: second, mailbox: "Archive"), Self.hit(id: "3", date: third, mailbox: "Archive")]
        let gateway = ToolsTestSupport.StubEmailGateway(
            listedMailboxes: ["INBOX", "Archive"],
            hitsByMailbox: ["INBOX": inboxHits, "Archive": archiveHits]
        )
        let tool = EmailSearchTool(emailConfig: ToolsTestSupport.testEmailConfig(), gateway: gateway)
        try await ToolsTestSupport.withTestPassword {
            let output = try await tool.execute(
                input: ToolInput(
                    toolName: "email.search",
                    argumentsJSON: #"{"account":"personal","query":"*","limit":2,"since":"2026-09-13","until":"2026-09-14"}"#
                ),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == false)
            let envelope = try JSONDecoder().decode(EmailSearchEnvelope.self, from: Data(output.content.utf8))
            // Newest-first across folders under the cap; the stale hit never surfaces.
            #expect(envelope.messages.map(\.id) == ["3", "2"])
            #expect(envelope.count == 2)
        }
    }
}

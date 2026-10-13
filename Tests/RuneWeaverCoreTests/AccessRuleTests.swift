// Rune Weaver Core Tests — Access rule scopes, the single matcher, and rule rows.
//
// Pins the contract that one tool plus one scope plus one action plus one
// optional lifetime describes a rule, and that the single scope matcher is the
// only place scope comparison happens: every case matches only its documented
// shape, a malformed call matches nothing but toolWide, and a malformed scope is
// refused at creation so it can never be judged at evaluation. Also pins the
// canonicalizers (recipient spelling, host shape, path prefix, glob), the
// tagged envelope's unknown-kind and non-canonical refusals, tolerant durable
// decoding, and the legacy-target equivalence that keeps a migrated row
// covering the exact call the owner approved.

import Foundation
@testable import RuneWeaverCore
import Testing

@Suite("Access Rule Scopes")
struct AccessRuleTests {
    /// Creates an isolated temporary directory for one fixture.
    private func makeTempWorkspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("runeweaver-access-rule-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func removeTempWorkspace(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
    }

    /// The canonical prefix a path scope stores for a raw spelling.
    private func canonicalPrefix(_ raw: String) throws -> String {
        try #require(AccessScope.canonicalPathPrefix(raw), "expected a canonical prefix for \(raw)")
    }

    // MARK: - toolWide

    @Test
    func `toolWide covers every call of its tool, arguments unread`() {
        let scope = AccessScope.toolWide
        #expect(scope.matches(toolName: "email.send", argumentsJSON: #"{"to":"a@x.com"}"#))
        #expect(scope.matches(toolName: "bash.exec", argumentsJSON: #"{"command":"rm -rf /"}"#))
        #expect(scope.matches(toolName: "email.send", argumentsJSON: "{}"))
        // A malformed call still matches toolWide: the scope never reads args.
        #expect(scope.matches(toolName: "email.send", argumentsJSON: "not json"))
        #expect(scope.matches(toolName: "email.send", argumentsJSON: "[]"))
        #expect(scope.matches(toolName: "email.send", argumentsJSON: ""))
    }

    @Test
    func `rule covers only its own tool`() throws {
        let rule = AccessRule(toolName: "email.send", scope: .toolWide, action: .allow)
        #expect(rule != nil)
        #expect(try #require(rule?.covers(toolName: "email.send", argumentsJSON: #"{"to":"a@x.com"}"#) as Bool?))
        #expect(try #require(rule?.covers(toolName: "email.send", argumentsJSON: "garbage") as Bool?))
        // A near-miss name is a different tool, never the same one with noise.
        #expect(try !#require(rule?.covers(toolName: "email.send ", argumentsJSON: #"{"to":"a@x.com"}"#) as Bool?))
        #expect(try !#require(rule?.covers(toolName: "email", argumentsJSON: #"{"to":"a@x.com"}"#) as Bool?))
        #expect(try !#require(rule?.covers(toolName: "messages.send", argumentsJSON: #"{"to":"a@x.com"}"#) as Bool?))
    }

    // MARK: - exactTarget

    @Test
    func `exactTarget reproduces the legacy target derivation`() {
        let sendCall = ToolInput(toolName: "email.send", argumentsJSON: #"{"to":["a@x.com","B@x.com"]}"#)
        let legacyTarget = ActionDescriptor.descriptor(for: sendCall, toolName: "email.send").target
        #expect(legacyTarget == "a@x.com,b@x.com")
        #expect(legacyTarget == ActionDescriptor.target(from: sendCall))
        #expect(AccessScope.exactTarget(legacyTarget)
            .matches(toolName: "email.send", argumentsJSON: sendCall.argumentsJSON))
        // Composed and canonicalized shapes keep their own key, so the typed
        // spelling never stands in for the one the gate stored.
        #expect(!AccessScope.exactTarget("a@x.com, B@x.com").matches(toolName: "email.send", argumentsJSON: sendCall.argumentsJSON))
        #expect(!AccessScope.exactTarget("").matches(toolName: "email.send", argumentsJSON: sendCall.argumentsJSON))
    }

    @Test
    func `exactTarget covers a messages send only by canonical handle`() {
        let sendArgs = #"{"recipient":"+1 (555) 123-4567"}"#
        let call = ToolInput(toolName: "messages.send", argumentsJSON: sendArgs)
        let canonical = ActionDescriptor.descriptor(for: call, toolName: "messages.send").target
        #expect(canonical == "+15551234567")
        #expect(AccessScope.exactTarget(canonical).matches(toolName: "messages.send", argumentsJSON: sendArgs))
        #expect(!AccessScope.exactTarget("+1 (555) 123-4567").matches(toolName: "messages.send", argumentsJSON: sendArgs))
    }

    @Test
    func `exactTarget covers the composed browser action shape`() {
        let args = #"{"action":"click","ref":"e12","url":"https://example.com/page"}"#
        #expect(AccessScope.exactTarget("click e12 @ https://example.com/page")
            .matches(toolName: "browser.act", argumentsJSON: args))
        // The generic derivation drops the action verb, so it is a different rule.
        let generic = ActionDescriptor.target(from: ToolInput(toolName: "browser.act", argumentsJSON: args))
        #expect(generic == "e12 @ https://example.com/page")
        #expect(!AccessScope.exactTarget(generic).matches(toolName: "browser.act", argumentsJSON: args))
    }

    @Test
    func `exactTarget never matches a malformed or empty call`() {
        let scope = AccessScope.exactTarget("a@x.com")
        #expect(!scope.matches(toolName: "email.send", argumentsJSON: "not json"))
        #expect(!scope.matches(toolName: "email.send", argumentsJSON: ""))
        #expect(!scope.matches(toolName: "email.send", argumentsJSON: "{}"))
        #expect(!scope.matches(toolName: "email.send", argumentsJSON: "[]"))
        #expect(!scope.matches(toolName: "email.send", argumentsJSON: #"{"to":"b@x.com"}"#))
    }

    // MARK: - recipientSet

    @Test
    func `recipientSet matches the documented recipient shape`() {
        let scope = AccessScope.recipientSet(["b@x.com", "a@x.com"])
        #expect(scope.matches(toolName: "email.send", argumentsJSON: #"{"to":"a@x.com"}"#))
        #expect(scope.matches(toolName: "email.send", argumentsJSON: #"{"to":["b@x.com","a@x.com"]}"#))
        // A comma-joined spelling and an array agree once normalized.
        #expect(scope.matches(toolName: "email.send", argumentsJSON: #"{"to":"b@x.com, a@x.com"}"#))
        // Casing and surrounding whitespace are the same recipient.
        #expect(scope.matches(toolName: "email.send", argumentsJSON: #"{"to":" B@X.COM "}"#))
        #expect(scope.matches(toolName: "email.send", argumentsJSON: #"{"recipient":"a@x.com"}"#))
    }

    @Test
    func `recipientSet never matches an outside, blank, or malformed call`() {
        let scope = AccessScope.recipientSet(["a@x.com", "b@x.com"])
        #expect(!scope.matches(toolName: "email.send", argumentsJSON: #"{"to":"z@x.com"}"#))
        #expect(!scope.matches(toolName: "email.send", argumentsJSON: #"{"to":"a@x.com, z@x.com"}"#))
        #expect(!scope.matches(toolName: "email.send", argumentsJSON: #"{}"#))
        #expect(!scope.matches(toolName: "email.send", argumentsJSON: #"{"to":"   "}"#))
        #expect(!scope.matches(toolName: "email.send", argumentsJSON: #"{"to":["a@x.com",null]}"#))
        #expect(!scope.matches(toolName: "email.send", argumentsJSON: "not json"))
        #expect(!scope.matches(toolName: "email.send", argumentsJSON: ""))
    }

    @Test
    func `recipientSet compares messages sends by canonical handle`() {
        let scope = AccessScope.recipientSet(["5551234567", "a@x.com"])
        // Punctuation, spacing, and the NANP country prefix fold onto one key.
        #expect(scope.matches(toolName: "messages.send", argumentsJSON: #"{"recipient":"+1 (555) 123-4567"}"#))
        #expect(scope.matches(toolName: "messages.send", argumentsJSON: #"{"recipient":"555.123.4567"}"#))
        #expect(scope.matches(toolName: "messages.send", argumentsJSON: #"{"to":"a@x.com"}"#))
        // A display name is not a handle, so it cannot ride a recipient scope.
        #expect(!scope.matches(toolName: "messages.send", argumentsJSON: #"{"recipient":"Rebecca Mackin"}"#))
        #expect(!scope.matches(toolName: "messages.send", argumentsJSON: #"{"recipient":"+1 (555) 999-9999"}"#))
        #expect(!scope.matches(toolName: "messages.send", argumentsJSON: "not json"))
    }

    // MARK: - domain

    @Test
    func `domain matches exact hosts and optional subdomains`() {
        let exact = AccessScope.domain(host: "example.com", subdomains: false)
        #expect(exact.matches(toolName: "api.request", argumentsJSON: #"{"url":"https://example.com/v1"}"#))
        #expect(exact.matches(toolName: "web.fetch", argumentsJSON: #"{"url":"https://EXAMPLE.com/x"}"#))
        #expect(exact.matches(toolName: "bash.exec", argumentsJSON: #"{"command":"curl https://example.com/x"}"#))
        // Subdomains stay out unless the rule opts in.
        #expect(!exact.matches(toolName: "api.request", argumentsJSON: #"{"url":"https://sub.example.com/v1"}"#))

        let wide = AccessScope.domain(host: "example.com", subdomains: true)
        #expect(wide.matches(toolName: "api.request", argumentsJSON: #"{"url":"https://sub.example.com/v1"}"#))
        #expect(wide.matches(toolName: "api.request", argumentsJSON: #"{"url":"https://example.com/v1"}"#))
        // A sibling name that merely ends with the host is not a subdomain.
        #expect(!wide.matches(toolName: "api.request", argumentsJSON: #"{"url":"https://notexample.com/v1"}"#))
        #expect(!wide.matches(toolName: "api.request", argumentsJSON: #"{"url":"https://other.com/v1"}"#))
    }

    @Test
    func `domain never matches a hostless, blank, or malformed call`() {
        let scope = AccessScope.domain(host: "example.com", subdomains: true)
        #expect(!scope.matches(toolName: "api.request", argumentsJSON: "{}"))
        #expect(!scope.matches(toolName: "api.request", argumentsJSON: #"{"url":"   "}"#))
        #expect(!scope.matches(toolName: "api.request", argumentsJSON: #"{"url":"/relative/path"}"#))
        #expect(!scope.matches(toolName: "api.request", argumentsJSON: "not json"))
        #expect(!scope.matches(toolName: "api.request", argumentsJSON: ""))
    }

    // MARK: - pathPrefix

    @Test
    func `pathPrefix covers the first path argument and its children`() throws {
        let root = try makeTempWorkspace()
        defer { removeTempWorkspace(root) }
        let notes = root.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let prefix = try canonicalPrefix(notes.path)
        let scope = AccessScope.pathPrefix(prefix)

        #expect(scope.matches(toolName: "files.write", argumentsJSON: #"{"path":"\#(notes.path)/todo.md"}"#))
        #expect(scope.matches(toolName: "files.write", argumentsJSON: #"{"path":"\#(notes.path)/deep/nested/todo.md"}"#))
        // The prefix itself is inside the scope.
        #expect(scope.matches(toolName: "files.write", argumentsJSON: #"{"path":"\#(notes.path)"}"#))

        let sibling = root.appendingPathComponent("notes-evil")
        #expect(!scope.matches(toolName: "files.write", argumentsJSON: #"{"path":"\#(sibling.path)/todo.md"}"#))
        let outside = root.appendingPathComponent("other")
        #expect(!scope.matches(toolName: "files.write", argumentsJSON: #"{"path":"\#(outside.path)/todo.md"}"#))
        // A relative argument never resolves to a boundary.
        #expect(!scope.matches(toolName: "files.write", argumentsJSON: #"{"path":"notes/todo.md"}"#))
        #expect(!scope.matches(toolName: "files.write", argumentsJSON: "{}"))
        #expect(!scope.matches(toolName: "files.write", argumentsJSON: "not json"))
    }

    @Test
    func `pathPrefix canonicalizes symlinked spellings onto one boundary`() throws {
        let root = try makeTempWorkspace()
        defer { removeTempWorkspace(root) }
        let real = root.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let throughReal = try canonicalPrefix(real.path)
        let throughLink = try canonicalPrefix(link.path)
        // Both spellings resolve to the same boundary, so a grant keyed on one
        // covers a call written through the other.
        #expect(throughLink == throughReal)
        let scope = AccessScope.pathPrefix(throughReal)
        #expect(scope.matches(toolName: "files.write", argumentsJSON: #"{"path":"\#(link.path)/todo.md"}"#))
        #expect(scope.matches(toolName: "files.write", argumentsJSON: #"{"path":"\#(real.path)/todo.md"}"#))
    }

    // MARK: - glob

    @Test
    func `glob matches bash commands and never other tools`() {
        let scope = AccessScope.glob("git status")
        #expect(scope.matches(toolName: "bash.exec", argumentsJSON: #"{"command":"git status --short"}"#))
        #expect(scope.matches(toolName: "bash.exec", argumentsJSON: #"{"command":"git status"}"#))
        #expect(!scope.matches(toolName: "bash.exec", argumentsJSON: #"{"command":"git commit -m msg"}"#))
        #expect(!scope.matches(toolName: "bash.exec", argumentsJSON: #"{"command":"echogram test"}"#))
        // A path-shaped argument is not a command line.
        #expect(!scope.matches(toolName: "files.write", argumentsJSON: #"{"path":"git status"}"#))
        #expect(!scope.matches(toolName: "messages.send", argumentsJSON: #"{"recipient":"git status"}"#))

        let wildcard = AccessScope.glob("rm *")
        #expect(wildcard.matches(toolName: "bash.exec", argumentsJSON: #"{"command":"rm -rf /tmp/x"}"#))
        #expect(!wildcard.matches(toolName: "bash.exec", argumentsJSON: #"{"command":"echo rm -rf /tmp/x"}"#))
    }

    @Test
    func `glob never matches a blank or malformed command`() {
        let scope = AccessScope.glob("*")
        #expect(!scope.matches(toolName: "bash.exec", argumentsJSON: "{}"))
        #expect(!scope.matches(toolName: "bash.exec", argumentsJSON: #"{"command":"   "}"#))
        #expect(!scope.matches(toolName: "bash.exec", argumentsJSON: "not json"))
        #expect(!scope.matches(toolName: "bash.exec", argumentsJSON: ""))
    }

    // MARK: - Canonicalizers

    @Test
    func `normalizeRecipients trims, lowercases, dedupes, and sorts`() {
        let normalized = AccessScope.normalizeRecipients(["  b@x.com ", "A@X.com", "", "   ", "b@x.com", "c@x.com"])
        #expect(normalized == ["a@x.com", "b@x.com", "c@x.com"])
        #expect(AccessScope.normalizeRecipients([]) == [])
        #expect(AccessScope.normalizeRecipients(["  ", ""]) == [])
    }

    @Test
    func `canonicalDomain accepts hosts and refuses unusable shapes`() {
        #expect(AccessScope.canonicalDomain("EXAMPLE.com") == "example.com")
        #expect(AccessScope.canonicalDomain("  Example.COM.  ") == "example.com")
        #expect(AccessScope.canonicalDomain("localhost") == "localhost")
        #expect(AccessScope.canonicalDomain("10.0.0.1") == "10.0.0.1")

        #expect(AccessScope.canonicalDomain("") == nil)
        #expect(AccessScope.canonicalDomain("    ") == nil)
        #expect(AccessScope.canonicalDomain(".") == nil)
        #expect(AccessScope.canonicalDomain("*") == nil)
        #expect(AccessScope.canonicalDomain("*.example.com") == nil)
        #expect(AccessScope.canonicalDomain("example.com.*") == nil)
        #expect(AccessScope.canonicalDomain("exam*ple.com") == nil)
        #expect(AccessScope.canonicalDomain("example.com:8080") == nil)
        #expect(AccessScope.canonicalDomain("http://example.com") == nil)
        #expect(AccessScope.canonicalDomain("user@example.com") == nil)
        #expect(AccessScope.canonicalDomain("exa mple.com") == nil)
        #expect(AccessScope.canonicalDomain("exa..mple.com") == nil)
        #expect(AccessScope.canonicalDomain(String(repeating: "a", count: 250) + ".com") == nil)
    }

    @Test
    func `canonicalPathPrefix refuses relative and over-long spellings`() {
        #expect(AccessScope.canonicalPathPrefix("") == nil)
        #expect(AccessScope.canonicalPathPrefix("   ") == nil)
        #expect(AccessScope.canonicalPathPrefix("notes/todo.md") == nil)
        #expect(AccessScope.canonicalPathPrefix("../etc/passwd") == nil)
        #expect(AccessScope.canonicalPathPrefix("./notes") == nil)
        #expect(AccessScope.canonicalPathPrefix(String(repeating: "a", count: 1025)) == nil)
        #expect(AccessScope.canonicalPathPrefix("/" + String(repeating: "a", count: 1023)) == "/" + String(repeating: "a", count: 1023))
    }

    @Test
    func `canonicalPathPrefix expands a tilde like the explicit spelling`() {
        let throughTilde = AccessScope.canonicalPathPrefix("~/notes")
        let throughHome = AccessScope.canonicalPathPrefix(NSHomeDirectory() + "/notes")
        #expect(throughTilde == throughHome)
        #expect(AccessScope.canonicalPathPrefix("~") == AccessScope.canonicalPathPrefix(NSHomeDirectory()))
    }

    @Test
    func `canonicalGlob trims and bounds the pattern`() {
        #expect(AccessScope.canonicalGlob("  git status  ") == "git status")
        #expect(AccessScope.canonicalGlob("rm *") == "rm *")
        #expect(AccessScope.canonicalGlob("") == nil)
        #expect(AccessScope.canonicalGlob("   ") == nil)
        #expect(AccessScope.canonicalGlob(String(repeating: "a", count: 257)) == nil)
        #expect(AccessScope.canonicalGlob(String(repeating: "a", count: 256)) != nil)
    }

    @Test
    func `canonicalized enforces every bound at creation`() throws {
        #expect(AccessScope.canonicalized(.toolWide) == .toolWide)
        #expect(AccessScope.canonicalized(.exactTarget("a@x.com")) == .exactTarget("a@x.com"))
        #expect(AccessScope.canonicalized(.exactTarget("   ")) == nil)
        #expect(AccessScope.canonicalized(.domain(host: "EXAMPLE.com.", subdomains: true)) == .domain(host: "example.com", subdomains: true))
        #expect(AccessScope.canonicalized(.domain(host: "*.example.com", subdomains: false)) == nil)
        #expect(AccessScope.canonicalized(.glob("  git status ")) == .glob("git status"))
        #expect(AccessScope.canonicalized(.glob(" ")) == nil)

        // Members normalize into their stored spelling rather than trusting the
        // caller's order or casing.
        let spelled = try #require(AccessScope.canonicalized(.recipientSet(["B@X.com", "a@x.com", "a@x.com"])))
        #expect(spelled == .recipientSet(["a@x.com", "b@x.com"]))

        #expect(AccessScope.canonicalized(.recipientSet((1 ... 50).map { "user\($0)@x.com" })) != nil)
        #expect(AccessScope.canonicalized(.recipientSet((1 ... 51).map { "user\($0)@x.com" })) == nil)
        #expect(AccessScope.canonicalized(.recipientSet([])) == nil)
        #expect(AccessScope.canonicalized(.recipientSet(["  ", ""])) == nil)
    }

    @Test
    func `canonicalToolName refuses a blank tool name`() {
        #expect(AccessRule.canonicalToolName("email.send") == "email.send")
        #expect(AccessRule.canonicalToolName("  bash.exec ") == "bash.exec")
        #expect(AccessRule.canonicalToolName("") == nil)
        #expect(AccessRule.canonicalToolName("   ") == nil)
    }

    // MARK: - Encoding

    @Test
    func `every scope round-trips through the tagged envelope`() throws {
        let root = try makeTempWorkspace()
        defer { removeTempWorkspace(root) }
        let prefix = try canonicalPrefix(root.path)
        let scopes: [AccessScope] = [
            .toolWide,
            .exactTarget("dr.smith@clinic.com"),
            .recipientSet(["a@x.com", "b@x.com"]),
            .domain(host: "example.com", subdomains: true),
            .domain(host: "example.com", subdomains: false),
            .pathPrefix(prefix),
            .glob("git status")
        ]
        for scope in scopes {
            let data = try JSONEncoder().encode(scope)
            let back = try JSONDecoder().decode(AccessScope.self, from: data)
            #expect(back == scope)
        }
    }

    @Test
    func `the envelope carries a recognizable kind and value`() throws {
        let data = try JSONEncoder().encode(AccessScope.domain(host: "example.com", subdomains: true))
        let raw = try #require(String(data: data, encoding: .utf8))
        #expect(raw.contains(#""kind":"domain""#))
        #expect(raw.contains(#""host":"example.com""#))
        #expect(raw.contains(#""subdomains":true"#))

        let memberData = try JSONEncoder().encode(AccessScope.recipientSet(["a@x.com", "b@x.com"]))
        let memberRaw = try #require(String(data: memberData, encoding: .utf8))
        #expect(memberRaw.contains(#""kind":"recipientSet""#))
        #expect(memberRaw.contains(#""value":["a@x.com","b@x.com"]"#))
    }

    @Test
    func `an unknown envelope kind fails decoding and never matches`() throws {
        let unknown = #"{"kind":"futureKind","value":"a@x.com"}"#
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(AccessScope.self, from: Data(unknown.utf8))
        }
        // The matching surface knows only the six canonical cases, so a shape a
        // decode rejects has no stored spelling that could match a call.
        #expect(AccessScope.exactTarget("a@x.com").matches(toolName: "email.send", argumentsJSON: #"{"to":"a@x.com"}"#))
        // A scope no canonicalizer accepts fails closed at evaluation too.
        #expect(!AccessScope.domain(host: "*.example.com", subdomains: false)
            .matches(toolName: "api.request", argumentsJSON: #"{"url":"https://api.example.com"}"#))
        #expect(!AccessScope.exactTarget("   ").matches(toolName: "email.send", argumentsJSON: #"{"to":"a@x.com"}"#))
    }

    @Test
    func `a non-canonical or valueless envelope fails decoding`() throws {
        let wildcardHost = #"{"kind":"domain","value":{"host":"*.example.com","subdomains":false}}"#
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(AccessScope.self, from: Data(wildcardHost.utf8))
        }
        let relativePath = #"{"kind":"pathPrefix","value":"notes/todo.md"}"#
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(AccessScope.self, from: Data(relativePath.utf8))
        }
        let valueless = #"{"kind":"exactTarget"}"#
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(AccessScope.self, from: Data(valueless.utf8))
        }
        let kindless = #"{"value":"a@x.com"}"#
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(AccessScope.self, from: Data(kindless.utf8))
        }
    }

    @Test
    func `decoding canonicalizes a sloppily spelled recipient set`() throws {
        let sloppy = #"{"kind":"recipientSet","value":[" B@X.COM ","a@x.com","a@x.com"]}"#
        let scope = try JSONDecoder().decode(AccessScope.self, from: Data(sloppy.utf8))
        #expect(scope == .recipientSet(["a@x.com", "b@x.com"]))
    }

    // MARK: - AccessRule rows

    @Test
    func `rule creation refuses unusable scopes, tools, and durations`() {
        #expect(AccessRule(toolName: "", scope: .toolWide) == nil)
        #expect(AccessRule(toolName: "   ", scope: .toolWide) == nil)
        #expect(AccessRule(toolName: "email.send", scope: .recipientSet([])) == nil)
        #expect(AccessRule(toolName: "email.send", scope: .domain(host: "*.example.com", subdomains: false)) == nil)
        #expect(AccessRule(toolName: "bash.exec", scope: .glob(" ")) == nil)
        #expect(AccessRule(toolName: "email.send", scope: .toolWide, duration: .thisTime) == nil)
        #expect(AccessRule(toolName: "email.send", scope: .toolWide, duration: .forTask) == nil)
        #expect(AccessRule(toolName: "email.send", scope: .toolWide, duration: .forSession) == nil)

        let durableTiers: [TrustDuration] = [.fiveMinutes, .oneHour, .oneDay, .forever]
        for tier in durableTiers {
            #expect(AccessRule(toolName: "email.send", scope: .toolWide, duration: tier) != nil)
        }
        #expect(AccessRule(toolName: "email.send", scope: .toolWide, duration: nil) != nil)
    }

    @Test
    func `a standing rule never expires and a dated tier derives one`() throws {
        let standing = try #require(AccessRule(toolName: "bash.exec", scope: .toolWide, action: .allow))
        #expect(standing.duration == nil)
        #expect(standing.expiresAt == nil)
        #expect(standing.useCount == 0)
        #expect(standing.lastUsedAt == nil)
        #expect(standing.reason == nil)
        #expect(!standing.isExpired())
        #expect(standing.isValid())

        let grantedAt = Date(timeIntervalSince1970: 1000)
        let dated = try #require(AccessRule(
            toolName: "bash.exec",
            scope: .toolWide,
            grantedAt: grantedAt,
            duration: .oneHour
        ))
        #expect(dated.duration == .oneHour)
        #expect(dated.expiresAt == grantedAt.addingTimeInterval(60 * 60))
        #expect(dated.isValid(at: grantedAt.addingTimeInterval(60)))
        #expect(dated.isExpired(at: grantedAt.addingTimeInterval(60 * 60)))
        #expect(!dated.isValid(at: grantedAt.addingTimeInterval(61 * 60)))

        // A forever tier carries no expiry, so an explicit one cannot shorten it.
        let forever = try #require(AccessRule(
            toolName: "bash.exec",
            scope: .toolWide,
            duration: .forever,
            expiresAt: Date(timeIntervalSince1970: 1)
        ))
        #expect(forever.expiresAt == nil)
        #expect(!forever.isExpired(at: Date(timeIntervalSince1970: 10000)))
    }

    @Test
    func `rule encoding round-trips a durable row`() throws {
        let grantedAt = Date(timeIntervalSince1970: 1000)
        let id = try #require(UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000000"))
        let rule = try #require(AccessRule(
            id: id,
            toolName: "email.send",
            scope: .recipientSet(["a@x.com", "b@x.com"]),
            action: .deny,
            grantedAt: grantedAt,
            duration: .oneDay,
            reason: "owner refused this batch"
        ))
        let data = try JSONEncoder().encode(rule)
        let back = try JSONDecoder().decode(AccessRule.self, from: data)
        #expect(back == rule)
        #expect(back.action == .deny)
        #expect(back.reason == "owner refused this batch")
        #expect(back.duration == .oneDay)
    }

    @Test
    func `rule decoding tolerates missing counters and refuses non-durable rows`() throws {
        let tolerated = #"{"id":"AAAAAAAA-0000-0000-0000-000000000001","toolName":"email.send","scope":{"kind":"toolWide"},"action":"allow","grantedAt":0}"#
        let rule = try JSONDecoder().decode(AccessRule.self, from: Data(tolerated.utf8))
        #expect(rule.toolName == "email.send")
        #expect(rule.scope == .toolWide)
        #expect(rule.duration == nil)
        #expect(rule.useCount == 0)
        #expect(rule.lastUsedAt == nil)
        #expect(rule.reason == nil)
        #expect(!rule.isExpired())

        let negative = #"{"id":"AAAAAAAA-0000-0000-0000-000000000002","toolName":"email.send","scope":{"kind":"toolWide"},"action":"allow","grantedAt":0,"useCount":-7,"lastUsedAt":null}"#
        let clamped = try JSONDecoder().decode(AccessRule.self, from: Data(negative.utf8))
        #expect(clamped.useCount == 0)
        #expect(clamped.lastUsedAt == nil)

        for tier in ["thisTime", "forTask", "forSession"] {
            let oneShot = #"{"id":"AAAAAAAA-0000-0000-0000-000000000003","toolName":"email.send","scope":{"kind":"toolWide"},"action":"allow","grantedAt":0,"duration":"\#(tier)"}"#
            #expect(throws: DecodingError.self) {
                _ = try JSONDecoder().decode(AccessRule.self, from: Data(oneShot.utf8))
            }
        }

        let blankTool = #"{"id":"AAAAAAAA-0000-0000-0000-000000000004","toolName":"   ","scope":{"kind":"toolWide"},"action":"allow","grantedAt":0}"#
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(AccessRule.self, from: Data(blankTool.utf8))
        }

        let wildcardScope = #"{"id":"AAAAAAAA-0000-0000-0000-000000000005","toolName":"api.request","scope":{"kind":"domain","value":{"host":"*.example.com","subdomains":false}},"action":"allow","grantedAt":0}"#
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(AccessRule.self, from: Data(wildcardScope.utf8))
        }
    }

    // MARK: - EphemeralGrant

    @Test
    func `ephemeral grants carry a task or session kind and a canonical scope`() {
        let grant = EphemeralGrant(toolName: "email.send", scope: .recipientSet(["a@x.com"]), kind: .task)
        #expect(grant != nil)
        #expect(grant?.toolName == "email.send")
        #expect(grant?.kind == .task)
        #expect(grant?.scope == .recipientSet(["a@x.com"]))
        #expect(EphemeralGrant.Kind.allCases == [.task, .session])

        #expect(EphemeralGrant(toolName: "", scope: .toolWide, kind: .task) == nil)
        #expect(EphemeralGrant(toolName: "email.send", scope: .recipientSet([]), kind: .session) == nil)
        #expect(EphemeralGrant(toolName: "api.request", scope: .domain(host: "*.example.com", subdomains: false), kind: .session) == nil)
        let paddedTool = EphemeralGrant(toolName: "  email.send  ", scope: .toolWide, kind: .task)
        #expect(paddedTool?.toolName == "email.send")
    }

    @Test
    func `ephemeral grants encode and decode`() throws {
        let grant = try #require(EphemeralGrant(toolName: "bash.exec", scope: .glob("git status"), kind: .session))
        let data = try JSONEncoder().encode(grant)
        let back = try JSONDecoder().decode(EphemeralGrant.self, from: data)
        #expect(back == grant)
    }
}

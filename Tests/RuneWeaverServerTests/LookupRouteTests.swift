// Rune Weaver Server Tests — Mailbox and calendar lookup route contracts.

import Foundation
import RuneWeaverCore
@testable import RuneWeaverServer
import RuneWeaverTools
import Testing
import Vapor

private enum LookupStubError: Error, Sendable {
    case gatewayFailed
    case unused
}

private struct FixedMailboxGateway: EmailIMAPGateway, Sendable {
    let listing: EmailMailboxListing

    func mailboxListing(credentials _: ResolvedEmailCredentials) async throws -> EmailMailboxListing {
        listing
    }

    func status(credentials _: ResolvedEmailCredentials, mailbox: String) async throws -> EmailMailboxStatus {
        EmailMailboxStatus(mailbox: mailbox, uidNext: 1, uidValidity: 1)
    }

    func search(credentials _: ResolvedEmailCredentials, mailbox _: String, query _: String, limit _: Int) async throws -> [EmailSearchHit] {
        []
    }

    func fetch(credentials _: ResolvedEmailCredentials, mailbox _: String, messageID _: String) async throws -> EmailFullMessage {
        throw LookupStubError.unused
    }

    func attachment(credentials _: ResolvedEmailCredentials, mailbox _: String, messageID _: String, attachmentIndex _: Int) async throws -> EmailAttachmentData {
        throw LookupStubError.unused
    }

    func append(credentials _: ResolvedEmailCredentials, mailbox _: String, rawMessage _: Data) async throws {
        throw LookupStubError.unused
    }
}

private struct FailingMailboxGateway: EmailIMAPGateway, Sendable {
    func mailboxListing(credentials _: ResolvedEmailCredentials) async throws -> EmailMailboxListing {
        throw LookupStubError.gatewayFailed
    }

    func status(credentials _: ResolvedEmailCredentials, mailbox: String) async throws -> EmailMailboxStatus {
        EmailMailboxStatus(mailbox: mailbox, uidNext: 1, uidValidity: 1)
    }

    func search(credentials _: ResolvedEmailCredentials, mailbox _: String, query _: String, limit _: Int) async throws -> [EmailSearchHit] {
        []
    }

    func fetch(credentials _: ResolvedEmailCredentials, mailbox _: String, messageID _: String) async throws -> EmailFullMessage {
        throw LookupStubError.unused
    }

    func attachment(credentials _: ResolvedEmailCredentials, mailbox _: String, messageID _: String, attachmentIndex _: Int) async throws -> EmailAttachmentData {
        throw LookupStubError.unused
    }

    func append(credentials _: ResolvedEmailCredentials, mailbox _: String, rawMessage _: Data) async throws {
        throw LookupStubError.unused
    }
}

private struct PerAccountMailboxGateway: EmailIMAPGateway, Sendable {
    let listings: [String: EmailMailboxListing]

    func mailboxListing(credentials: ResolvedEmailCredentials) async throws -> EmailMailboxListing {
        listings[credentials.accountName] ?? EmailMailboxListing(mailboxes: ["INBOX"], delimiter: "/")
    }

    func status(credentials _: ResolvedEmailCredentials, mailbox: String) async throws -> EmailMailboxStatus {
        EmailMailboxStatus(mailbox: mailbox, uidNext: 1, uidValidity: 1)
    }

    func search(credentials _: ResolvedEmailCredentials, mailbox _: String, query _: String, limit _: Int) async throws -> [EmailSearchHit] {
        []
    }

    func fetch(credentials _: ResolvedEmailCredentials, mailbox _: String, messageID _: String) async throws -> EmailFullMessage {
        throw LookupStubError.unused
    }

    func attachment(credentials _: ResolvedEmailCredentials, mailbox _: String, messageID _: String, attachmentIndex _: Int) async throws -> EmailAttachmentData {
        throw LookupStubError.unused
    }

    func append(credentials _: ResolvedEmailCredentials, mailbox _: String, rawMessage _: Data) async throws {
        throw LookupStubError.unused
    }
}

private struct FixedCalendarStore: CalendarStore, Sendable {
    let served: [StoreCalendar]

    func authorizationStatus() -> CalendarAuthorizationStatus {
        .authorized
    }

    func requestAccess() async throws -> Bool {
        true
    }

    func calendars() throws -> [StoreCalendar] {
        served
    }

    func predicateForEvents(start: Date, end: Date, calendars: [StoreCalendar]) -> CalendarFetchPredicate {
        CalendarFetchPredicate(start: start, end: end, calendars: calendars)
    }

    func events(matching _: CalendarFetchPredicate) throws -> [StoreEvent] {
        []
    }

    func event(withIdentifier _: String) throws -> StoreEvent? {
        nil
    }

    func save(_ event: StoreEvent) throws -> StoreEvent {
        event
    }

    func remove(_: StoreEvent, span _: CalendarSpan) throws {}
}

private func makeLookupTokenFile(contents: String) throws -> (directory: URL, fileURL: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("runeweaver-lookup-auth-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    let fileURL = directory.appendingPathComponent("auth_token")
    try contents.write(to: fileURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    return (directory, fileURL)
}

private func makeLookupAuth(token: String = "owner-token") throws -> (auth: ServerAuth, directory: URL) {
    let (directory, fileURL) = try makeLookupTokenFile(contents: token)
    let store = ServerAuthTokenStore(
        authConfig: AuthConfig(tokenEnv: "RUNEWEAVER_AUTH_TEST_UNSET", tokenFile: fileURL.path),
        service: "com.runeweaver.tests.\(UUID().uuidString)",
        inMemory: true
    )
    return (ServerAuth(initialToken: token, store: store), directory)
}

private func withLookupTestApp<T>(_ body: (Application) async throws -> T) async throws -> T {
    let app = try await Application.make(.testing)
    do {
        let value = try await body(app)
        try await app.asyncShutdown()
        return value
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
}

private func makeLookupTestContext(auth: ServerAuth? = nil, emailConfig: EmailConfig? = nil) -> ServerContext {
    let base = ServerContext.fallbackUnconfigured
    return ServerContext(
        config: .default,
        conversations: base.conversations,
        toolBus: base.toolBus,
        orchestrator: base.orchestrator,
        memoryEngine: base.memoryEngine,
        permissionGate: base.permissionGate,
        approvals: base.approvals,
        steeringQueue: base.steeringQueue,
        auth: auth,
        emailConfig: emailConfig
    )
}

private func lookupRequest(app: Application, path: String, token: String? = nil) async throws -> Response {
    var headers = HTTPHeaders()
    if let token {
        headers.replaceOrAdd(name: "Authorization", value: "Bearer \(token)")
    }
    let request = Request(
        application: app,
        method: .GET,
        url: URI(string: path),
        headers: headers,
        on: app.eventLoopGroup.next()
    )
    return try await app.responder.respond(to: request).get()
}

private func lookupAccount(named name: String) -> EmailAccount {
    EmailAccount(name: name, host: "imap.example.test", username: "user@example.test")
}

/// Serialized because mailbox tests mutate process-wide credential environment entries.
@Suite("Lookup Routes", .serialized)
struct LookupRouteTests {
    @Test
    func `Unknown account answers 404 JSON`() async throws {
        let (auth, directory) = try makeLookupAuth()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withLookupTestApp { app in
            app.runeWeaver = makeLookupTestContext(
                auth: auth,
                emailConfig: EmailConfig(accounts: [lookupAccount(named: "lookup-home")])
            )
            app.runeWeaverAuth = auth
            app.lookupEmailGateway = FixedMailboxGateway(listing: EmailMailboxListing(mailboxes: ["INBOX"], delimiter: "/"))
            registerRuneWeaverRoutes(app)

            let response = try await lookupRequest(app: app, path: "/email/accounts/missing/mailboxes", token: "owner-token")
            #expect(response.status == .notFound)
            #expect((response.body.string ?? "").contains("Unknown email account"))
        }
    }

    @Test
    func `Mailbox listing returns the exact shape`() async throws {
        let (auth, directory) = try makeLookupAuth()
        defer { try? FileManager.default.removeItem(at: directory) }
        let accountName = "lookup-shape"
        let envKey = EmailAccount.passwordEnvVar(forAccountNamed: accountName)
        setenv(envKey, "lookup-test-secret", 1)
        defer { unsetenv(envKey) }
        try await withLookupTestApp { app in
            app.runeWeaver = makeLookupTestContext(
                auth: auth,
                emailConfig: EmailConfig(accounts: [lookupAccount(named: accountName)])
            )
            app.runeWeaverAuth = auth
            app.lookupEmailGateway = FixedMailboxGateway(listing: EmailMailboxListing(mailboxes: ["INBOX", "Sent"], delimiter: "/"))
            registerRuneWeaverRoutes(app)

            let response = try await lookupRequest(app: app, path: "/email/accounts/\(accountName)/mailboxes", token: "owner-token")
            #expect(response.status == .ok)
            let decoded = try response.content.decode(MailboxesResponse.self)
            #expect(decoded.mailboxes == ["INBOX", "Sent"])
            #expect(decoded.delimiter == "/")
            let raw = try #require(response.body.string)
            let object = try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
            #expect(Set(object.keys) == Set(["mailboxes", "delimiter"]))
        }
    }

    @Test
    func `Star account serves the union instead of 404`() async throws {
        let (auth, directory) = try makeLookupAuth()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = "lookup-union-alpha"
        let second = "lookup-union-beta"
        let firstKey = EmailAccount.passwordEnvVar(forAccountNamed: first)
        let secondKey = EmailAccount.passwordEnvVar(forAccountNamed: second)
        setenv(firstKey, "lookup-test-secret", 1)
        setenv(secondKey, "lookup-test-secret", 1)
        defer { unsetenv(firstKey); unsetenv(secondKey) }
        try await withLookupTestApp { app in
            app.runeWeaver = makeLookupTestContext(
                auth: auth,
                emailConfig: EmailConfig(accounts: [lookupAccount(named: first), lookupAccount(named: second)])
            )
            app.runeWeaverAuth = auth
            app.lookupEmailGateway = PerAccountMailboxGateway(listings: [
                first: EmailMailboxListing(mailboxes: ["INBOX", "Sent"], delimiter: "/"),
                second: EmailMailboxListing(mailboxes: ["INBOX", "Archive"], delimiter: "/")
            ])
            registerRuneWeaverRoutes(app)

            // The wizard lists "*" for All accounts, so the route must serve
            // it instead of refusing like an unknown single account.
            let response = try await lookupRequest(app: app, path: "/email/accounts/*/mailboxes", token: "owner-token")
            #expect(response.status == .ok)
            let decoded = try response.content.decode(MailboxesResponse.self)
            #expect(decoded.mailboxes == ["Archive", "INBOX", "Sent"])
            #expect(decoded.delimiter == "/")
        }
    }

    @Test
    func `Nil delimiter encodes as null`() async throws {
        let (auth, directory) = try makeLookupAuth()
        defer { try? FileManager.default.removeItem(at: directory) }
        let accountName = "lookup-nulldelim"
        let envKey = EmailAccount.passwordEnvVar(forAccountNamed: accountName)
        setenv(envKey, "lookup-test-secret", 1)
        defer { unsetenv(envKey) }
        try await withLookupTestApp { app in
            app.runeWeaver = makeLookupTestContext(
                auth: auth,
                emailConfig: EmailConfig(accounts: [lookupAccount(named: accountName)])
            )
            app.runeWeaverAuth = auth
            app.lookupEmailGateway = FixedMailboxGateway(listing: EmailMailboxListing(mailboxes: ["INBOX"], delimiter: nil))
            registerRuneWeaverRoutes(app)

            let response = try await lookupRequest(app: app, path: "/email/accounts/\(accountName)/mailboxes", token: "owner-token")
            #expect(response.status == .ok)
            let decoded = try response.content.decode(MailboxesResponse.self)
            #expect(decoded.delimiter == nil)
            #expect((response.body.string ?? "").contains("\"delimiter\":null"))
        }
    }

    @Test
    func `Mailbox failure answers 502 JSON instead of an empty list`() async throws {
        let (auth, directory) = try makeLookupAuth()
        defer { try? FileManager.default.removeItem(at: directory) }
        let accountName = "lookup-failing"
        let envKey = EmailAccount.passwordEnvVar(forAccountNamed: accountName)
        setenv(envKey, "lookup-test-secret", 1)
        defer { unsetenv(envKey) }
        try await withLookupTestApp { app in
            app.runeWeaver = makeLookupTestContext(
                auth: auth,
                emailConfig: EmailConfig(accounts: [lookupAccount(named: accountName)])
            )
            app.runeWeaverAuth = auth
            app.lookupEmailGateway = FailingMailboxGateway()
            registerRuneWeaverRoutes(app)

            let response = try await lookupRequest(app: app, path: "/email/accounts/\(accountName)/mailboxes", token: "owner-token")
            #expect(response.status == .badGateway)
            #expect(!(response.body.string ?? "").contains("\"mailboxes\":[]"))
        }
    }

    @Test
    func `Calendars return id title shape`() async throws {
        let (auth, directory) = try makeLookupAuth()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withLookupTestApp { app in
            app.runeWeaver = makeLookupTestContext(auth: auth)
            app.runeWeaverAuth = auth
            app.lookupCalendarStore = FixedCalendarStore(served: [
                StoreCalendar(identifier: "cal-1", title: "Home"),
                StoreCalendar(identifier: "cal-2", title: "Work")
            ])
            registerRuneWeaverRoutes(app)

            let response = try await lookupRequest(app: app, path: "/calendars", token: "owner-token")
            #expect(response.status == .ok)
            let decoded = try response.content.decode(CalendarsResponse.self)
            #expect(decoded.calendars.map(\.id) == ["cal-1", "cal-2"])
            #expect(decoded.calendars.map(\.title) == ["Home", "Work"])
            let raw = try #require(response.body.string)
            let object = try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
            #expect(Set(object.keys) == Set(["calendars"]))
        }
    }

    @Test
    func `Lookup routes refuse anonymous callers`() async throws {
        let (auth, directory) = try makeLookupAuth()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withLookupTestApp { app in
            app.runeWeaver = makeLookupTestContext(
                auth: auth,
                emailConfig: EmailConfig(accounts: [lookupAccount(named: "lookup-home")])
            )
            app.runeWeaverAuth = auth
            app.lookupEmailGateway = FixedMailboxGateway(listing: EmailMailboxListing(mailboxes: ["INBOX"], delimiter: "/"))
            app.lookupCalendarStore = FixedCalendarStore(served: [StoreCalendar(identifier: "cal-1", title: "Home")])
            registerRuneWeaverRoutes(app)

            let mailboxes = try await lookupRequest(app: app, path: "/email/accounts/lookup-home/mailboxes")
            #expect(mailboxes.status == .unauthorized)
            let calendars = try await lookupRequest(app: app, path: "/calendars")
            #expect(calendars.status == .unauthorized)
        }
    }
}

// Rune Weaver Server — Authenticated mailbox and calendar lookup routes.

import Foundation
import RuneWeaverCore
import RuneWeaverTools
import Vapor

/// Mailbox listing for `GET /email/accounts/:name/mailboxes`.
public struct MailboxesResponse: Content, Sendable, Equatable {
    /// Selectable mailbox names in server order.
    public let mailboxes: [String]
    /// Hierarchy delimiter reported by the server, nil when unknown.
    public let delimiter: String?

    /// Creates a mailbox listing response.
    public init(mailboxes: [String], delimiter: String? = nil) {
        self.mailboxes = mailboxes
        self.delimiter = delimiter
    }

    private enum CodingKeys: String, CodingKey {
        case mailboxes
        case delimiter
    }

    /// Decodes a listing, tolerating a missing delimiter as unknown.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mailboxes = try container.decode([String].self, forKey: .mailboxes)
        delimiter = try container.decodeIfPresent(String.self, forKey: .delimiter)
    }

    /// Encodes a listing, writing an explicit null so the key never vanishes.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mailboxes, forKey: .mailboxes)
        if let delimiter {
            try container.encode(delimiter, forKey: .delimiter)
        } else {
            try container.encodeNil(forKey: .delimiter)
        }
    }
}

/// One calendar row for `GET /calendars`.
public struct LookupCalendarEntry: Content, Sendable, Equatable {
    /// Stable calendar identifier.
    public let id: String
    /// Human-readable calendar title.
    public let title: String

    /// Creates a calendar row.
    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// Calendar listing for `GET /calendars`.
public struct CalendarsResponse: Content, Sendable, Equatable {
    /// Calendars backing the lookup.
    public let calendars: [LookupCalendarEntry]

    /// Creates a calendar listing response.
    public init(calendars: [LookupCalendarEntry]) {
        self.calendars = calendars
    }
}

private struct LookupEmailGatewayKey: StorageKey {
    typealias Value = any EmailIMAPGateway
}

private struct LookupCalendarStoreKey: StorageKey {
    typealias Value = any CalendarStore
}

extension Application {
    /// IMAP gateway backing mailbox lookups, injectable for hermetic tests.
    public var lookupEmailGateway: any EmailIMAPGateway {
        get {
            if let stored = storage[LookupEmailGatewayKey.self] {
                return stored
            }
            return SubprocessIMAPGateway()
        }
        set {
            storage[LookupEmailGatewayKey.self] = newValue
        }
    }

    /// Calendar store backing calendar lookups, injectable for hermetic tests.
    public var lookupCalendarStore: any CalendarStore {
        get {
            if let stored = storage[LookupCalendarStoreKey.self] {
                return stored
            }
            return ProductionCalendarGateway().store
        }
        set {
            storage[LookupCalendarStoreKey.self] = newValue
        }
    }
}

/// Registers the mailbox and calendar lookup routes.
public func registerLookupRoutes(_ app: Application) {
    app.get(
        PathComponent.constant("email"),
        PathComponent.constant("accounts"),
        PathComponent.parameter("name"),
        PathComponent.constant("mailboxes")
    ) { req async throws -> MailboxesResponse in
        if req.application.runeWeaverAuth != nil, !req.runeWeaverAuthenticated {
            throw Abort(.unauthorized, reason: "Owner authentication required.")
        }
        guard let raw = req.parameters.get("name") else {
            throw Abort(.badRequest, reason: "Account name is required.")
        }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw Abort(.badRequest, reason: "Account name is required.")
        }
        // "*" polls every account, so serve the union instead of 404.
        if name == "*" {
            guard let config = req.application.runeWeaver.emailConfig, !config.accounts.isEmpty else {
                return MailboxesResponse(mailboxes: [], delimiter: nil)
            }
            var union = Set<String>()
            var delimiter: String?
            var servedAny = false
            var lastError: Error?
            for account in config.accounts {
                do {
                    let credentials = try await EmailCredentialResolver.resolvedCredentials(for: account)
                    let listing = try await req.application.lookupEmailGateway.mailboxListing(credentials: credentials)
                    servedAny = true
                    union.formUnion(listing.mailboxes)
                    if delimiter == nil {
                        delimiter = listing.delimiter
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastError = error
                    continue
                }
            }
            // Every-account failure shares 502 so an empty list never masquerades as success.
            guard servedAny else {
                throw Abort(.badGateway, reason: lastError?.localizedDescription ?? "Mailbox list is unavailable.")
            }
            return MailboxesResponse(mailboxes: union.sorted(), delimiter: delimiter)
        }
        // Unknown names refuse with 404 so misconfiguration never reads as an empty mailbox list.
        guard let account = req.application.runeWeaver.emailConfig?.account(matching: name) else {
            throw Abort(.notFound, reason: "Unknown email account '\(raw)'.")
        }
        let credentials: ResolvedEmailCredentials
        do {
            credentials = try await EmailCredentialResolver.resolvedCredentials(for: account)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Credential and upstream failures share 502 so an empty list never masquerades as success.
            throw Abort(.badGateway, reason: error.localizedDescription)
        }
        do {
            let listing = try await req.application.lookupEmailGateway.mailboxListing(credentials: credentials)
            return MailboxesResponse(mailboxes: listing.mailboxes, delimiter: listing.delimiter)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Abort(.badGateway, reason: error.localizedDescription)
        }
    }

    app.get(PathComponent.constant("calendars")) { req async throws -> CalendarsResponse in
        if req.application.runeWeaverAuth != nil, !req.runeWeaverAuthenticated {
            throw Abort(.unauthorized, reason: "Owner authentication required.")
        }
        do {
            let calendars = try req.application.lookupCalendarStore.calendars()
            return CalendarsResponse(calendars: calendars.map { LookupCalendarEntry(id: $0.identifier, title: $0.title) })
        } catch {
            throw Abort(.badGateway, reason: error.localizedDescription)
        }
    }
}

// Rune Weaver Tools — Mailbox listing and single-message move models.
//
// Covers the read-only folder-discovery surface (`email.listMailboxes` with the
// server hierarchy delimiter) and the approval-gated single-message relocation
// (`email.move` with an opt-in Seen flag). Wire parsing here stays fail-closed
// so partial bridge payloads surface as decode failures instead of silent
// no-op successes.

import Foundation
import RuneWeaverCore

/// Selectable mailbox listing returned by the gateway `LIST` operation.
///
/// Bundles the folder names with the server hierarchy delimiter so presenters can render
/// nested trees without re-querying the bridge for separator metadata.
public struct EmailMailboxListing: Sendable, Equatable, Codable {
    /// Selectable mailbox names in server order.
    public let mailboxes: [String]
    /// Hierarchy delimiter reported by the server (nil when unknown).
    public let delimiter: String?

    /// Creates a mailbox listing, preserving the server delimiter verbatim.
    /// Only nil or empty collapses to nil; whitespace (including a space
    /// delimiter) is significant server metadata and is kept as reported.
    public init(mailboxes: [String], delimiter: String? = nil) {
        self.mailboxes = mailboxes
        if let delimiter, !delimiter.isEmpty {
            self.delimiter = delimiter
        } else {
            self.delimiter = nil
        }
    }
}

/// Mailbox STATUS snapshot returned by the gateway `STATUS` operation.
///
/// Bundles the next-assigned UID with the server validity token so fixed
/// backfill windows anchor from `uidNext - 1` and validity mismatches reset
/// the incremental watermark without duplicating documents.
public struct EmailMailboxStatus: Sendable, Equatable, Codable {
    /// Mailbox the status was read from.
    public let mailbox: String
    /// Next UID the server will assign.
    public let uidNext: Int
    /// Server validity token for the mailbox.
    public let uidValidity: Int

    /// Creates a mailbox status snapshot.
    /// - Parameters:
    ///   - mailbox: Mailbox the status was read from.
    ///   - uidNext: Next UID the server will assign.
    ///   - uidValidity: Server validity token.
    public init(mailbox: String, uidNext: Int, uidValidity: Int) {
        self.mailbox = mailbox
        self.uidNext = uidNext
        self.uidValidity = uidValidity
    }
}

/// Arguments for the `email.listMailboxes` tool.
public struct EmailListMailboxesArgs: Sendable, Equatable, Decodable {
    /// Account nickname matching an `EmailAccount.name` entry.
    public let account: String

    /// Memberwise initializer.
    public init(account: String) {
        self.account = account
    }

    private enum CodingKeys: String, CodingKey {
        case account
    }

    /// Decodes arguments.
    /// - Parameter decoder: Decoder for the arguments document.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        account = try container.decode(String.self, forKey: .account)
    }

    /// Trimmed account nickname.
    public var trimmedAccount: String {
        account.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Envelope wrapping `email.listMailboxes` tool output.
public struct EmailListMailboxesEnvelope: Sendable, Equatable, Codable {
    /// Account nickname that was listed.
    public let account: String
    /// Number of entries in `mailboxes`.
    public let count: Int
    /// Selectable mailbox names in server order.
    public let mailboxes: [String]
    /// Hierarchy delimiter reported by the server (nil when unknown).
    public let delimiter: String?

    /// Creates a listing envelope, deriving `count` so callers cannot drift from the payload.
    /// The delimiter is preserved verbatim; only nil or empty collapses to nil.
    public init(account: String, mailboxes: [String], delimiter: String? = nil) {
        self.account = account
        self.mailboxes = mailboxes
        self.count = mailboxes.count
        if let delimiter, !delimiter.isEmpty {
            self.delimiter = delimiter
        } else {
            self.delimiter = nil
        }
    }
}

/// Arguments for the `email.move` tool.
public struct EmailMoveArgs: Sendable, Equatable, Decodable {
    /// Account nickname matching an `EmailAccount.name` entry.
    public let account: String
    /// IMAP UID (falling back to sequence number) of the message.
    public let messageID: String
    /// Optional source mailbox holding the message (nil means `INBOX`).
    public let mailbox: String?
    /// Optional destination mailbox (nil means the caller must resolve a default downstream).
    public let destination: String?
    /// Whether to mark the message read as part of the move. Defaults to false.
    public let markAsRead: Bool

    /// Memberwise initializer.
    public init(
        account: String,
        messageID: String,
        mailbox: String? = nil,
        destination: String? = nil,
        markAsRead: Bool = false
    ) {
        self.account = account
        self.messageID = messageID
        self.mailbox = mailbox
        self.destination = destination
        self.markAsRead = markAsRead
    }

    private enum CodingKeys: String, CodingKey {
        case account
        case id
        case messageId
        case messageID = "message_id"
        case uid
        case mailbox
        case folder
        case source
        case fromMailbox
        case fromMailboxSnake = "from_mailbox"
        case destination
        case destinationMailbox
        case destinationMailboxSnake = "destination_mailbox"
        case toMailbox
        case toMailboxSnake = "to_mailbox"
        case markAsRead
        case markAsReadSnake = "mark_as_read"
    }

    /// Decodes arguments, accepting every documented id, source, and destination alias.
    /// Blank aliases behave as omitted so a valid later alias still wins, mirroring
    /// the message-id handling where empty strings are skipped.
    /// - Parameter decoder: Decoder for the arguments document.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        account = try container.decode(String.self, forKey: .account)
        let idAlias = try container.decodeIfPresent(String.self, forKey: .id)
        let messageIdAlias = try container.decodeIfPresent(String.self, forKey: .messageId)
        let messageIDSnakeAlias = try container.decodeIfPresent(String.self, forKey: .messageID)
        let uidAlias = try container.decodeIfPresent(String.self, forKey: .uid)
        let idCandidates = [idAlias, messageIdAlias, messageIDSnakeAlias, uidAlias]
        guard let resolvedID = EmailMailboxNormalization.firstNonBlank(idCandidates) else {
            throw DecodingError.keyNotFound(
                CodingKeys.id,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Missing message id (expected 'id', 'messageId', 'message_id', or 'uid')"
                )
            )
        }
        messageID = resolvedID
        // Source aliases cover model callers (`mailbox`/`folder`) and bridge dialects
        // (`source`/`fromMailbox`); the first non-blank alias wins.
        let mailboxAlias = try container.decodeIfPresent(String.self, forKey: .mailbox)
        let folderAlias = try container.decodeIfPresent(String.self, forKey: .folder)
        let sourceAlias = try container.decodeIfPresent(String.self, forKey: .source)
        let fromMailboxAlias = try container.decodeIfPresent(String.self, forKey: .fromMailbox)
        let fromMailboxSnakeAlias = try container.decodeIfPresent(String.self, forKey: .fromMailboxSnake)
        mailbox = EmailMailboxNormalization.firstNonBlank([mailboxAlias, folderAlias, sourceAlias, fromMailboxAlias, fromMailboxSnakeAlias])
        // Destination aliases mirror the source spread so moves stay robust across callers.
        let destinationAlias = try container.decodeIfPresent(String.self, forKey: .destination)
        let destinationMailboxAlias = try container.decodeIfPresent(String.self, forKey: .destinationMailbox)
        let destinationMailboxSnakeAlias = try container.decodeIfPresent(String.self, forKey: .destinationMailboxSnake)
        let toMailboxAlias = try container.decodeIfPresent(String.self, forKey: .toMailbox)
        let toMailboxSnakeAlias = try container.decodeIfPresent(String.self, forKey: .toMailboxSnake)
        let destinationCandidates = [
            destinationAlias, destinationMailboxAlias, destinationMailboxSnakeAlias, toMailboxAlias, toMailboxSnakeAlias
        ]
        destination = EmailMailboxNormalization.firstNonBlank(destinationCandidates)
        // Optional read flag defaults to false so plain moves never flip Seen implicitly.
        let markAsReadPrimary = try container.decodeIfPresent(Bool.self, forKey: .markAsRead)
        let markAsReadSnake = try container.decodeIfPresent(Bool.self, forKey: .markAsReadSnake)
        markAsRead = markAsReadPrimary ?? markAsReadSnake ?? false
    }

    /// Trimmed account nickname.
    public var trimmedAccount: String {
        account.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Trimmed message identifier.
    public var trimmedMessageID: String {
        messageID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Trimmed source mailbox, or nil when omitted or blank (meaning `INBOX`).
    public var trimmedMailbox: String? {
        EmailMailboxNormalization.trimmed(mailbox)
    }

    /// Trimmed destination mailbox, or nil when omitted or blank.
    public var trimmedDestination: String? {
        EmailMailboxNormalization.trimmed(destination)
    }
}

/// Envelope wrapping `email.move` tool output.
public struct EmailMoveEnvelope: Sendable, Equatable, Codable {
    /// Account nickname the message was moved under.
    public let account: String
    /// IMAP UID of the message.
    public let id: String
    /// Source mailbox the message was moved from.
    public let mailbox: String
    /// Destination mailbox the message was moved to.
    public let destination: String
    /// Whether the message was relocated.
    public let moved: Bool
    /// Whether the message was marked read as part of the move.
    public let markedAsRead: Bool
    /// Human-readable note (nil when the move needs no extra context).
    public let note: String?

    private enum CodingKeys: String, CodingKey {
        case account
        case id
        case mailbox
        case destination
        case moved
        case markedAsRead
        case note
    }

    /// Creates a move envelope, normalizing blank mailboxes to `INBOX` for stable output.
    public init(
        account: String,
        id: String,
        mailbox: String = "INBOX",
        destination: String,
        moved: Bool,
        markedAsRead: Bool,
        note: String? = nil
    ) {
        self.account = account
        self.id = id
        self.mailbox = EmailMailboxNormalization.normalizedMailbox(mailbox)
        self.destination = EmailMailboxNormalization.normalizedMailbox(destination)
        self.moved = moved
        self.markedAsRead = markedAsRead
        self.note = note
    }

    /// Decodes a move envelope, defaulting omitted mailboxes to `INBOX`.
    /// - Parameter decoder: Decoder for the envelope document.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        account = try container.decode(String.self, forKey: .account)
        id = try container.decode(String.self, forKey: .id)
        let rawMailbox = try container.decodeIfPresent(String.self, forKey: .mailbox)
        mailbox = EmailMailboxNormalization.normalizedMailbox(rawMailbox)
        let rawDestination = try container.decodeIfPresent(String.self, forKey: .destination)
        destination = EmailMailboxNormalization.normalizedMailbox(rawDestination)
        moved = try container.decode(Bool.self, forKey: .moved)
        markedAsRead = try container.decode(Bool.self, forKey: .markedAsRead)
        note = try container.decodeIfPresent(String.self, forKey: .note)
    }

    /// Encodes a move envelope including both mailbox labels.
    /// - Parameter encoder: Encoder for the envelope document.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(account, forKey: .account)
        try container.encode(id, forKey: .id)
        try container.encode(mailbox, forKey: .mailbox)
        try container.encode(destination, forKey: .destination)
        try container.encode(moved, forKey: .moved)
        try container.encode(markedAsRead, forKey: .markedAsRead)
        try container.encodeIfPresent(note, forKey: .note)
    }
}

public extension EmailBridgeParsing {
    /// Filters a raw `LIST` mailbox list to selectable folders.
    static func selectableMailboxes(from entries: [(flags: String, mailbox: String)]) -> [String] {
        entries.compactMap { entry in
            let lowered = entry.flags.lowercased()
            if lowered.contains("noselect") || lowered.contains("nonexistent") {
                return nil
            }
            let trimmed = entry.mailbox.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    /// Resolves a requested mailbox against the selectable list.
    static func resolveMailbox(_ requested: String, among available: [String]) -> String? {
        if available.contains(requested) {
            return requested
        }
        let lowered = requested.lowercased()
        return available.first { $0.lowercased() == lowered }
    }

    /// Resolves a requested mailbox against an already-listed selectable list.
    static func resolveMailboxAgainstList(requested: String, available: [String]) throws -> String {
        guard !available.isEmpty else {
            throw unknownMailboxError(requested: requested, available: available)
        }
        guard let canonical = resolveMailbox(requested, among: available) else {
            throw unknownMailboxError(requested: requested, available: available)
        }
        return canonical
    }

    /// Builds the unknown-mailbox failure without secrets.
    static func unknownMailboxError(requested: String, available: [String]) -> EmailIMAPError {
        if available.isEmpty {
            return EmailIMAPError.bridgeFailed("Unknown mailbox '\(requested)' (no selectable mailboxes found)")
        }
        return EmailIMAPError.bridgeFailed("Unknown mailbox '\(requested)' (available: \(available.sorted().joined(separator: ", ")))")
    }

    /// Bridge `mailbox-listing` response shape carrying the hierarchy delimiter.
    struct MailboxListingResponse: Decodable {
        /// Whether the operation succeeded.
        let ok: Bool
        /// Error detail when `ok` is false.
        let error: String?
        /// Selectable mailboxes when `ok` is true.
        let mailboxes: [String]?
        /// Hierarchy delimiter reported by the server (nil when unknown).
        let delimiter: String?
    }

    /// Decodes a bridge `list` stdout payload carrying mailboxes plus the hierarchy delimiter.
    /// This is the single listing parser; the legacy bare-name parser was removed
    /// so delimiter metadata cannot be silently dropped.
    static func parseMailboxListingPayload(_ data: Data) throws -> EmailMailboxListing {
        let response = try JSONDecoder().decode(MailboxListingResponse.self, from: data)
        if !response.ok {
            throw EmailIMAPError.bridgeFailed(response.error ?? "IMAP list failed")
        }
        return EmailMailboxListing(mailboxes: response.mailboxes ?? [], delimiter: response.delimiter)
    }

    /// Compatibility shim over the single listing parser for existing callers.
    /// Delegates to `parseMailboxListingPayload` so delimiter metadata stays canonical.
    static func parseListPayload(_ data: Data) throws -> [String] {
        try parseMailboxListingPayload(data).mailboxes
    }

    /// Encodes selectable mailboxes as the `email.listMailboxes` tool output document.
    static func encodeListMailboxesEnvelope(account: String, mailboxes: [String], delimiter: String? = nil) throws -> String {
        let envelope = EmailListMailboxesEnvelope(account: account, mailboxes: mailboxes, delimiter: delimiter)
        return try encodeListMailboxesEnvelope(envelope)
    }

    /// Encodes a mailbox-listing envelope as the `email.listMailboxes` tool output document.
    static func encodeListMailboxesEnvelope(_ envelope: EmailListMailboxesEnvelope) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(envelope)
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    /// Encodes a move result as the `email.move` tool output document.
    static func encodeMoveEnvelope(_ envelope: EmailMoveEnvelope) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(envelope)
        return String(bytes: data, encoding: .utf8) ?? ""
    }
}

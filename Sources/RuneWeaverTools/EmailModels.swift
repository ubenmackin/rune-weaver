// Rune Weaver Tools — Email arg/envelope models and bridge wire formats.

import Foundation
import RuneWeaverCore

/// Shared mailbox-name normalization for email args and envelopes.
public enum EmailMailboxNormalization: Sendable {
    /// Trims an optional mailbox, returning nil when omitted or blank.
    /// - Parameter value: Raw mailbox value, if any.
    /// - Returns: Trimmed mailbox, or nil when omitted or blank.
    public static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Normalizes a mailbox to a non-empty canonical value.
    public static func normalizedMailbox(_ value: String?) -> String {
        guard let trimmed = trimmed(value), !trimmed.isEmpty else { return "INBOX" }
        return trimmed
    }

    /// Returns the first alias that is present and non-blank after trimming.
    /// Blank strings behave as omitted so a valid later alias still wins.
    /// - Parameter candidates: Aliases in priority order.
    /// - Returns: First non-blank alias, or nil when all are omitted or blank.
    public static func firstNonBlank(_ candidates: [String?]) -> String? {
        for candidate in candidates {
            guard let candidate else { continue }
            if candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }
            return candidate
        }
        return nil
    }

    /// Variadic convenience over the array form.
    /// - Parameter candidates: Aliases in priority order.
    /// - Returns: First non-blank alias, or nil when all are omitted or blank.
    public static func firstNonBlank(_ candidates: String?...) -> String? {
        firstNonBlank(candidates)
    }
}

/// Search arguments for the `email.search` tool.
public struct EmailSearchArgs: Sendable, Equatable, Decodable {
    /// Account nickname matching an `EmailAccount.name` entry.
    ///
    /// Optional because a search may target every configured account: an
    /// omitted, blank, or `"*"` account is the multi-account selector, so the
    /// model is never forced to know account names to ask "search everything".
    public let account: String?
    /// Free-text query matched against subject, sender, and body (`"*"`/empty means most-recent via `ALL`).
    public let query: String
    /// Maximum hits to return, clamped to `1...50`.
    public let limit: Int
    /// Optional mailbox narrowing the search to one folder (nil means every selectable mailbox).
    public let mailbox: String?
    /// Optional filter for whether the email has attachments (nil means no filtering).
    public let hasAttachment: Bool?
    /// Optional inclusive lower bound (`YYYY-MM-DD` local day or full ISO8601; nil means unbounded below).
    public let since: String?
    /// Optional exclusive upper bound (`YYYY-MM-DD` local day or full ISO8601; nil means unbounded above).
    public let until: String?

    /// Default hit count when the caller omits `limit`.
    public static let defaultLimit = 10
    /// Upper bound for `limit` so searches stay bounded.
    public static let maxLimit = 50
    /// Literal account selector meaning "every configured account".
    public static let allAccountsToken = "*"

    /// Memberwise initializer with limit clamping.
    public init(account: String?, query: String, limit: Int = defaultLimit, mailbox: String? = nil, hasAttachment: Bool? = nil, since: String? = nil, until: String? = nil) {
        self.account = account
        self.query = query
        self.limit = min(max(limit, 1), Self.maxLimit)
        self.mailbox = mailbox
        self.hasAttachment = hasAttachment
        self.since = EmailMailboxNormalization.trimmed(since)
        self.until = EmailMailboxNormalization.trimmed(until)
    }

    private enum CodingKeys: String, CodingKey {
        case account
        case query
        case limit
        case mailbox
        case folder
        case hasAttachment
        case hasAttachments
        case hasAttachmentSnake = "has_attachment"
        case hasAttachmentsSnake = "has_attachments"
        case since
        case until
    }

    /// Decodes arguments, trimming whitespace and clamping `limit`.
    ///
    /// `account` is decoded optionally so an omitted key is a valid
    /// all-accounts request rather than a decoding failure; rejecting or
    /// resolving the selector belongs to the tool layer after validation.
    /// - Parameter decoder: Decoder for the arguments document.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let account = try container.decodeIfPresent(String.self, forKey: .account)
        let query = try container.decode(String.self, forKey: .query)
        let rawLimit = try container.decodeIfPresent(Int.self, forKey: .limit) ?? Self.defaultLimit
        let mailbox = try container.decodeIfPresent(String.self, forKey: .mailbox)
            ?? container.decodeIfPresent(String.self, forKey: .folder)
        let hasAttachment = try container.decodeIfPresent(Bool.self, forKey: .hasAttachment)
            ?? container.decodeIfPresent(Bool.self, forKey: .hasAttachments)
            ?? container.decodeIfPresent(Bool.self, forKey: .hasAttachmentSnake)
            ?? container.decodeIfPresent(Bool.self, forKey: .hasAttachmentsSnake)
        let rawSince = try container.decodeIfPresent(String.self, forKey: .since)
        let rawUntil = try container.decodeIfPresent(String.self, forKey: .until)
        self.init(account: account, query: query, limit: rawLimit, mailbox: mailbox, hasAttachment: hasAttachment, since: rawSince, until: rawUntil)
    }

    /// Trimmed account nickname, or nil for omitted, blank, and `"*"` inputs.
    ///
    /// Collapsing the all-accounts token to nil here keeps single-account
    /// resolution from ever receiving a literal star; the tool layer branches
    /// on `isAllAccountsRequest` first.
    public var trimmedAccount: String? {
        let trimmed = EmailMailboxNormalization.trimmed(account)
        return trimmed == Self.allAccountsToken ? nil : trimmed
    }

    /// Whether the selector requests every configured account
    /// (omitted, blank after trimming, or the literal `"*"`).
    public var isAllAccountsRequest: Bool {
        let trimmed = EmailMailboxNormalization.trimmed(account)
        return trimmed == nil || trimmed == Self.allAccountsToken
    }

    /// Trimmed query text.
    public var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Trimmed mailbox narrowing, or nil when omitted or blank (meaning every selectable mailbox).
    public var trimmedMailbox: String? {
        EmailMailboxNormalization.trimmed(mailbox)
    }

    /// Trimmed inclusive lower bound, or nil when omitted or blank (meaning unbounded below).
    public var trimmedSince: String? {
        EmailMailboxNormalization.trimmed(since)
    }

    /// Trimmed exclusive upper bound, or nil when omitted or blank (meaning unbounded above).
    public var trimmedUntil: String? {
        EmailMailboxNormalization.trimmed(until)
    }
}

/// Read arguments for the `email.read` tool.
public struct EmailReadArgs: Sendable, Equatable, Decodable {
    /// Account nickname matching an `EmailAccount.name` entry.
    public let account: String
    /// IMAP UID (falling back to sequence number) of the message.
    public let messageID: String
    /// Optional mailbox holding the message (nil means `INBOX`).
    public let mailbox: String?

    /// Memberwise initializer.
    public init(account: String, messageID: String, mailbox: String? = nil) {
        self.account = account
        self.messageID = messageID
        self.mailbox = mailbox
    }

    private enum CodingKeys: String, CodingKey {
        case account
        case id
        case messageId
        case messageID = "message_id"
        case uid
        case mailbox
        case folder
    }

    /// Decodes arguments, accepting every documented id alias.
    /// Blank aliases behave as omitted so a valid later alias still wins.
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
        let mailboxAlias = try container.decodeIfPresent(String.self, forKey: .mailbox)
        let folderAlias = try container.decodeIfPresent(String.self, forKey: .folder)
        mailbox = EmailMailboxNormalization.firstNonBlank([mailboxAlias, folderAlias])
    }

    /// Trimmed account nickname.
    public var trimmedAccount: String {
        account.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Trimmed message identifier.
    public var trimmedMessageID: String {
        messageID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Trimmed mailbox holding the message, or nil when omitted or blank (meaning `INBOX`).
    public var trimmedMailbox: String? {
        EmailMailboxNormalization.trimmed(mailbox)
    }
}

/// One `email.search` hit: headers plus a short text snippet.
public struct EmailSearchHit: Sendable, Equatable, Codable {
    /// IMAP UID of the message (sequence fallback when the server omits UIDs).
    public let id: String
    /// Decoded `Subject` header (empty when absent).
    public let subject: String
    /// Decoded `From` header (empty when absent).
    public let from: String
    /// Raw `Date` header (empty when absent).
    public let date: String
    /// Leading body text, single-line, at most 200 characters.
    public let snippet: String
    /// Mailbox holding the message (e.g. `INBOX`).
    public let mailbox: String
    /// Owning account nickname (e.g. `personal`), so merged multi-account hits
    /// stay routable back to the account for follow-up `email.read`/`email.move`
    /// calls. Empty only for legacy payloads predating per-hit labeling.
    public let account: String
    /// Whether the message has attachments.
    public let hasAttachments: Bool?
    /// Number of attachment parts in the message.
    public let attachmentCount: Int?

    /// Creates a search hit.
    public init(
        id: String,
        subject: String,
        from: String,
        date: String,
        snippet: String,
        mailbox: String = "INBOX",
        account: String = "",
        hasAttachments: Bool? = nil,
        attachmentCount: Int? = nil
    ) {
        self.id = id
        self.subject = subject
        self.from = from
        self.date = date
        self.snippet = snippet
        self.mailbox = EmailMailboxNormalization.normalizedMailbox(mailbox)
        self.account = account
        self.hasAttachments = hasAttachments
        self.attachmentCount = attachmentCount
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case subject
        case from
        case date
        case snippet
        case mailbox
        case account
        case hasAttachments
        case attachmentCount
    }

    /// Decodes a hit, defaulting omitted `mailbox` to `INBOX` and omitted
    /// `account` to empty so bridge payloads from before per-hit account
    /// labeling still decode.
    /// - Parameter decoder: Decoder for the hit document.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        subject = try container.decode(String.self, forKey: .subject)
        from = try container.decode(String.self, forKey: .from)
        date = try container.decode(String.self, forKey: .date)
        snippet = try container.decode(String.self, forKey: .snippet)
        let rawMailbox = try container.decodeIfPresent(String.self, forKey: .mailbox)
        mailbox = EmailMailboxNormalization.normalizedMailbox(rawMailbox)
        account = try container.decodeIfPresent(String.self, forKey: .account) ?? ""
        hasAttachments = try container.decodeIfPresent(Bool.self, forKey: .hasAttachments)
        attachmentCount = try container.decodeIfPresent(Int.self, forKey: .attachmentCount)
    }

    /// Encodes a hit including its mailbox and account labels.
    /// - Parameter encoder: Encoder for the hit document.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(subject, forKey: .subject)
        try container.encode(from, forKey: .from)
        try container.encode(date, forKey: .date)
        try container.encode(snippet, forKey: .snippet)
        try container.encode(mailbox, forKey: .mailbox)
        try container.encode(account, forKey: .account)
        try container.encodeIfPresent(hasAttachments, forKey: .hasAttachments)
        try container.encodeIfPresent(attachmentCount, forKey: .attachmentCount)
    }
}

extension EmailSearchHit {
    /// Whether this hit satisfies an attachment-presence filter.
    /// Older hits may carry only a count, so presence derives from either signal;
    /// a nil filter matches every hit so unfiltered callers keep the full list.
    public func matches(hasAttachment: Bool?) -> Bool {
        guard let hasAttachment else { return true }
        return (hasAttachments ?? ((attachmentCount ?? 0) > 0)) == hasAttachment
    }
}

/// Attachment metadata for `email.read`.
public struct EmailAttachmentInfo: Sendable, Equatable, Codable {
    /// Original filename (or `unnamed-attachment` when absent).
    public let filename: String
    /// MIME type (e.g. `application/pdf`).
    public let contentType: String
    /// Decoded byte size of the attachment part (nil when unknown).
    public let sizeBytes: Int?

    /// Creates attachment metadata.
    public init(filename: String, contentType: String, sizeBytes: Int? = nil) {
        self.filename = filename
        self.contentType = contentType
        self.sizeBytes = sizeBytes
    }
}

/// Full message returned by `email.read`.
public struct EmailFullMessage: Sendable, Equatable, Codable {
    /// IMAP UID of the message.
    public let id: String
    /// Decoded `Subject` header.
    public let subject: String
    /// Decoded `From` header.
    public let from: String
    /// Decoded `To` header.
    public let to: String
    /// Raw `Date` header.
    public let date: String
    /// Decoded plain-text body.
    public let body: String
    /// Listed attachment parts (empty when none).
    public let attachments: [EmailAttachmentInfo]
    /// Whether attachments are listed (true when `attachments` is non-empty).
    public let attachmentsDeferred: Bool
    /// Human-readable listing note (nil when no attachments are listed).
    public let attachmentsNote: String?

    /// Creates a full message.
    public init(
        id: String,
        subject: String,
        from: String,
        to: String,
        date: String,
        body: String,
        attachments: [EmailAttachmentInfo] = [],
        attachmentsDeferred: Bool? = nil,
        attachmentsNote: String? = nil
    ) {
        self.id = id
        self.subject = subject
        self.from = from
        self.to = to
        self.date = date
        self.body = body
        self.attachments = attachments
        let deferred = attachmentsDeferred ?? !attachments.isEmpty
        self.attachmentsDeferred = deferred
        if let attachmentsNote {
            self.attachmentsNote = attachmentsNote
        } else if deferred, !attachments.isEmpty {
            self.attachmentsNote = EmailFullMessage.deferredNote(count: attachments.count)
        } else {
            self.attachmentsNote = nil
        }
    }

    /// Builds the listing note for available attachments.
    /// - Parameter count: Number of listed parts.
    /// - Returns: Human-readable note pointing at `email.attachment`.
    public static func deferredNote(count: Int) -> String {
        if count == 1 {
            return "1 attachment listed; use email.attachment to download."
        }
        return "\(count) attachments listed; use email.attachment to download."
    }
}

/// Envelope wrapping `email.search` tool output.
public struct EmailSearchEnvelope: Sendable, Equatable, Codable {
    /// Account nickname that was searched; the literal "all" for multi-account calls.
    public let account: String
    /// Query that was run.
    public let query: String
    /// Number of hits in `messages`.
    public let count: Int
    /// Hits, newest first.
    public let messages: [EmailSearchHit]
    /// Requested mailbox narrowing (nil means every selectable mailbox).
    public let mailbox: String?
    /// Folders actually searched, in search order.
    public let mailboxes: [String]?
    /// Accounts successfully searched, in config sequence (nil on legacy payloads).
    public let accounts: [String]?
    /// Accounts skipped due to credential or gateway failure, in config sequence.
    ///
    /// Fail-soft multi-account searches report partial coverage here so the
    /// agent can tell the user which mailboxes the result set does not speak for.
    public let failedAccounts: [String]?

    /// Creates a search envelope.
    public init(
        account: String,
        query: String,
        messages: [EmailSearchHit],
        mailbox: String? = nil,
        mailboxes: [String]? = nil,
        accounts: [String]? = nil,
        failedAccounts: [String]? = nil
    ) {
        self.account = account
        self.query = query
        self.messages = messages
        self.count = messages.count
        self.mailbox = mailbox
        self.mailboxes = mailboxes
        self.accounts = accounts
        self.failedAccounts = failedAccounts
    }

    private enum CodingKeys: String, CodingKey {
        case account
        case query
        case count
        case messages
        case mailbox
        case mailboxes
        case accounts
        case failedAccounts
    }

    /// Decodes an envelope tolerantly so legacy payloads lacking the
    /// multi-account keys (`accounts`, `failedAccounts`) still parse.
    /// `count` derives from `messages` rather than trusting the wire value,
    /// keeping the count invariant true for every decoded envelope.
    /// - Parameter decoder: Decoder for the envelope document.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        account = try container.decode(String.self, forKey: .account)
        query = try container.decode(String.self, forKey: .query)
        messages = try container.decode([EmailSearchHit].self, forKey: .messages)
        count = messages.count
        mailbox = try container.decodeIfPresent(String.self, forKey: .mailbox)
        mailboxes = try container.decodeIfPresent([String].self, forKey: .mailboxes)
        accounts = try container.decodeIfPresent([String].self, forKey: .accounts)
        failedAccounts = try container.decodeIfPresent([String].self, forKey: .failedAccounts)
    }

    /// Encodes an envelope, omitting nil multi-account keys. The search tool
    /// always passes both keys, so its output always carries them; per-hit
    /// account labels are always encoded.
    /// - Parameter encoder: Encoder for the envelope document.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(account, forKey: .account)
        try container.encode(query, forKey: .query)
        try container.encode(count, forKey: .count)
        try container.encode(messages, forKey: .messages)
        try container.encodeIfPresent(mailbox, forKey: .mailbox)
        try container.encodeIfPresent(mailboxes, forKey: .mailboxes)
        try container.encodeIfPresent(accounts, forKey: .accounts)
        try container.encodeIfPresent(failedAccounts, forKey: .failedAccounts)
    }
}

/// Envelope wrapping `email.read` tool output.
public struct EmailReadEnvelope: Sendable, Equatable, Codable {
    /// Account nickname the message was read from.
    public let account: String
    /// IMAP UID of the message.
    public let id: String
    /// Decoded `Subject` header.
    public let subject: String
    /// Decoded `From` header.
    public let from: String
    /// Decoded `To` header.
    public let to: String
    /// Raw `Date` header.
    public let date: String
    /// Decoded plain-text body.
    public let body: String
    /// Listed attachment parts.
    public let attachments: [EmailAttachmentInfo]
    /// Whether attachments are listed.
    public let attachmentsDeferred: Bool
    /// Human-readable listing note (nil when nothing is listed).
    public let attachmentsNote: String?
    /// Mailbox the message was read from.
    public let mailbox: String

    private enum CodingKeys: String, CodingKey {
        case account
        case id
        case subject
        case from
        case to
        case date
        case body
        case attachments
        case attachmentsDeferred
        case attachmentsNote
        case mailbox
    }

    /// Creates a read envelope from a decoded message.
    public init(account: String, message: EmailFullMessage, mailbox: String = "INBOX") {
        self.account = account
        self.id = message.id
        self.subject = message.subject
        self.from = message.from
        self.to = message.to
        self.date = message.date
        self.body = message.body
        self.attachments = message.attachments
        self.attachmentsDeferred = message.attachmentsDeferred
        self.attachmentsNote = message.attachmentsNote
        self.mailbox = EmailMailboxNormalization.normalizedMailbox(mailbox)
    }

    /// Decodes a read envelope, defaulting omitted `mailbox` to `INBOX`.
    /// - Parameter decoder: Decoder for the envelope document.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        account = try container.decode(String.self, forKey: .account)
        id = try container.decode(String.self, forKey: .id)
        subject = try container.decode(String.self, forKey: .subject)
        from = try container.decode(String.self, forKey: .from)
        to = try container.decode(String.self, forKey: .to)
        date = try container.decode(String.self, forKey: .date)
        body = try container.decode(String.self, forKey: .body)
        attachments = try container.decode([EmailAttachmentInfo].self, forKey: .attachments)
        attachmentsDeferred = try container.decode(Bool.self, forKey: .attachmentsDeferred)
        attachmentsNote = try container.decodeIfPresent(String.self, forKey: .attachmentsNote)
        let rawMailbox = try container.decodeIfPresent(String.self, forKey: .mailbox)
        mailbox = EmailMailboxNormalization.normalizedMailbox(rawMailbox)
    }

    /// Encodes a read envelope including its mailbox.
    /// - Parameter encoder: Encoder for the envelope document.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(account, forKey: .account)
        try container.encode(id, forKey: .id)
        try container.encode(subject, forKey: .subject)
        try container.encode(from, forKey: .from)
        try container.encode(to, forKey: .to)
        try container.encode(date, forKey: .date)
        try container.encode(body, forKey: .body)
        try container.encode(attachments, forKey: .attachments)
        try container.encode(attachmentsDeferred, forKey: .attachmentsDeferred)
        try container.encodeIfPresent(attachmentsNote, forKey: .attachmentsNote)
        try container.encode(mailbox, forKey: .mailbox)
    }
}

/// Arguments for the `email.attachment` tool.
public struct EmailAttachmentArgs: Sendable, Equatable, Decodable {
    /// Account nickname matching an `EmailAccount.name` entry.
    public let account: String
    /// IMAP UID (falling back to sequence number) of the message.
    public let messageID: String
    /// Zero-based position in the `email.read` attachment list.
    public let attachmentIndex: Int
    /// Optional mailbox holding the message (nil means `INBOX`).
    public let mailbox: String?
    /// Whether to inline a text preview in the success envelope. Defaults to false.
    public let preview: Bool
    /// Relative path of one entry inside a detonated archive to inspect (nil means list only).
    public let subpath: String?
    /// Workspace destination for an approval-gated export from a detonated archive (nil means no export).
    public let saveToPath: String?

    /// Memberwise initializer.
    public init(account: String, messageID: String, attachmentIndex: Int, mailbox: String? = nil, preview: Bool = false, subpath: String? = nil, saveToPath: String? = nil) {
        self.account = account
        self.messageID = messageID
        self.attachmentIndex = attachmentIndex
        self.mailbox = mailbox
        self.preview = preview
        self.subpath = subpath
        self.saveToPath = saveToPath
    }

    private enum CodingKeys: String, CodingKey {
        case account
        case id
        case messageId
        case messageID = "message_id"
        case uid
        case index
        case attachmentIndex
        case attachmentIndexSnake = "attachment_index"
        case mailbox
        case folder
        case preview
        case subpath
        case saveToPath
    }

    /// Decodes arguments, accepting every documented id and index alias.
    /// Blank id and mailbox aliases behave as omitted so valid later aliases still win.
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
        if let direct = try container.decodeIfPresent(Int.self, forKey: .index) {
            attachmentIndex = direct
        } else if let camel = try container.decodeIfPresent(Int.self, forKey: .attachmentIndex) {
            attachmentIndex = camel
        } else if let snake = try container.decodeIfPresent(Int.self, forKey: .attachmentIndexSnake) {
            attachmentIndex = snake
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.index,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Missing attachment index (expected 'index', 'attachmentIndex', or 'attachment_index')"
                )
            )
        }
        let mailboxAlias = try container.decodeIfPresent(String.self, forKey: .mailbox)
        let folderAlias = try container.decodeIfPresent(String.self, forKey: .folder)
        mailbox = EmailMailboxNormalization.firstNonBlank([mailboxAlias, folderAlias])
        // Optional preview flag defaults to false.
        preview = try container.decodeIfPresent(Bool.self, forKey: .preview) ?? false
        // Archive follow-ups stay optional;
        // blank strings collapse downstream via the trimmed helpers rather than here.
        subpath = try container.decodeIfPresent(String.self, forKey: .subpath)
        saveToPath = try container.decodeIfPresent(String.self, forKey: .saveToPath)
    }

    /// Trimmed account nickname.
    public var trimmedAccount: String {
        account.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Trimmed message identifier.
    public var trimmedMessageID: String {
        messageID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Trimmed mailbox holding the message, or nil when omitted or blank (meaning `INBOX`).
    public var trimmedMailbox: String? {
        EmailMailboxNormalization.trimmed(mailbox)
    }

    /// Trimmed archive entry path, or nil when omitted or blank (meaning list only).
    public var trimmedSubpath: String? {
        EmailMailboxNormalization.trimmed(subpath)
    }

    /// Trimmed workspace export destination, or nil when omitted or blank (meaning no export).
    public var trimmedSaveToPath: String? {
        EmailMailboxNormalization.trimmed(saveToPath)
    }
}

/// One downloaded attachment with its bytes.
public struct EmailAttachmentData: Sendable, Equatable {
    /// Original filename (or `unnamed-attachment` when absent).
    public let filename: String
    /// MIME type (e.g. `application/pdf`).
    public let contentType: String
    /// Decoded byte size of the attachment part.
    public let sizeBytes: Int
    /// Decoded attachment bytes.
    public let data: Data

    /// Creates downloaded attachment bytes.
    public init(filename: String, contentType: String, sizeBytes: Int, data: Data) {
        self.filename = filename
        self.contentType = contentType
        self.sizeBytes = sizeBytes
        self.data = data
    }
}

/// One entry inside an unpacked archive.
public struct EmailArchiveEntry: Sendable, Equatable, Codable {
    /// Relative path inside the archive.
    public let path: String
    /// Uncompressed size in bytes.
    public let sizeBytes: Int
    /// Coarse MIME category of the entry.
    public let category: String

    public init(path: String, sizeBytes: Int, category: String = "other") {
        self.path = path
        self.sizeBytes = sizeBytes
        self.category = category
    }
}

/// Envelope wrapping `email.attachment` tool output.
public struct EmailAttachmentEnvelope: Sendable, Equatable, Codable {
    /// Account nickname the attachment was fetched from.
    public let account: String
    /// IMAP UID of the message.
    public let id: String
    /// Zero-based position in the `email.read` attachment list.
    public let index: Int
    /// Original filename.
    public let filename: String
    /// MIME type (e.g. `application/pdf`).
    public let contentType: String
    /// Decoded byte size of the attachment part.
    public let sizeBytes: Int
    /// Staging or destination path (nil when skipped or memory-only).
    public let path: String?
    /// Whether the download was skipped (oversized part or dry run).
    public let skipped: Bool
    /// Human-readable note for skipped downloads (nil when saved).
    public let note: String?
    /// Mailbox the attachment was fetched from.
    public let mailbox: String
    /// ISO-8601 expiry of the staged file, derived from the sandbox retention window (nil when skipped or unknown).
    public let expiresAt: String?
    /// Coarse MIME bucket guiding follow-up handling: `pdf`, `image`, `text`, `archive`, or `other`.
    public let mimeCategory: String?
    /// Human follow-up hint.
    public let nextSteps: String?
    /// Inline leading text for small text payloads when requested (nil unless previewed).
    public let preview: String?
    /// Whether `preview` was truncated at the inline char cap (nil when no preview).
    public let previewTruncated: Bool?

    /// Direct text extracted from document attachments (PDF, DOCX, CSV, TXT).
    public let extractedText: String?
    /// Base64-encoded image data for multimodal vision models.
    public let imageDataBase64: String?
    /// Identifier for the ephemeral container session that detonated the archive.
    public let archiveSessionId: String?
    /// Manifest of files contained in an unpacked archive.
    public let archiveManifest: [EmailArchiveEntry]?
    /// Subpath inside an archive that was inspected.
    public let subpath: String?

    private enum CodingKeys: String, CodingKey {
        case account
        case id
        case index
        case filename
        case contentType
        case sizeBytes
        case path
        case skipped
        case note
        case mailbox
        case expiresAt
        case mimeCategory
        case nextSteps
        case preview
        case previewTruncated
        case extractedText
        case imageDataBase64
        case archiveSessionId
        case archiveManifest
        case subpath
    }

    /// Creates an attachment envelope.
    public init(
        account: String,
        id: String,
        index: Int,
        filename: String,
        contentType: String,
        sizeBytes: Int,
        path: String? = nil,
        skipped: Bool = false,
        note: String? = nil,
        mailbox: String = "INBOX",
        expiresAt: String? = nil,
        mimeCategory: String? = nil,
        nextSteps: String? = nil,
        preview: String? = nil,
        previewTruncated: Bool? = nil,
        extractedText: String? = nil,
        imageDataBase64: String? = nil,
        archiveSessionId: String? = nil,
        archiveManifest: [EmailArchiveEntry]? = nil,
        subpath: String? = nil
    ) {
        self.account = account
        self.id = id
        self.index = index
        self.filename = filename
        self.contentType = contentType
        self.sizeBytes = sizeBytes
        self.path = path
        self.skipped = skipped
        self.note = note
        self.mailbox = EmailMailboxNormalization.normalizedMailbox(mailbox)
        self.expiresAt = expiresAt
        self.mimeCategory = mimeCategory
        self.nextSteps = nextSteps
        self.preview = preview
        self.previewTruncated = previewTruncated
        self.extractedText = extractedText
        self.imageDataBase64 = imageDataBase64
        self.archiveSessionId = archiveSessionId
        self.archiveManifest = archiveManifest
        self.subpath = subpath
    }

    /// Decodes an attachment envelope.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        account = try container.decode(String.self, forKey: .account)
        id = try container.decode(String.self, forKey: .id)
        index = try container.decode(Int.self, forKey: .index)
        filename = try container.decode(String.self, forKey: .filename)
        contentType = try container.decode(String.self, forKey: .contentType)
        sizeBytes = try container.decode(Int.self, forKey: .sizeBytes)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        skipped = try container.decode(Bool.self, forKey: .skipped)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        let rawMailbox = try container.decodeIfPresent(String.self, forKey: .mailbox)
        mailbox = EmailMailboxNormalization.normalizedMailbox(rawMailbox)
        expiresAt = try container.decodeIfPresent(String.self, forKey: .expiresAt)
        mimeCategory = try container.decodeIfPresent(String.self, forKey: .mimeCategory)
        nextSteps = try container.decodeIfPresent(String.self, forKey: .nextSteps)
        preview = try container.decodeIfPresent(String.self, forKey: .preview)
        previewTruncated = try container.decodeIfPresent(Bool.self, forKey: .previewTruncated)
        extractedText = try container.decodeIfPresent(String.self, forKey: .extractedText)
        imageDataBase64 = try container.decodeIfPresent(String.self, forKey: .imageDataBase64)
        archiveSessionId = try container.decodeIfPresent(String.self, forKey: .archiveSessionId)
        archiveManifest = try container.decodeIfPresent([EmailArchiveEntry].self, forKey: .archiveManifest)
        subpath = try container.decodeIfPresent(String.self, forKey: .subpath)
    }

    /// Encodes an attachment envelope.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(account, forKey: .account)
        try container.encode(id, forKey: .id)
        try container.encode(index, forKey: .index)
        try container.encode(filename, forKey: .filename)
        try container.encode(contentType, forKey: .contentType)
        try container.encode(sizeBytes, forKey: .sizeBytes)
        try container.encodeIfPresent(path, forKey: .path)
        try container.encode(skipped, forKey: .skipped)
        try container.encodeIfPresent(note, forKey: .note)
        try container.encode(mailbox, forKey: .mailbox)
        try container.encodeIfPresent(expiresAt, forKey: .expiresAt)
        try container.encodeIfPresent(mimeCategory, forKey: .mimeCategory)
        try container.encodeIfPresent(nextSteps, forKey: .nextSteps)
        try container.encodeIfPresent(preview, forKey: .preview)
        try container.encodeIfPresent(previewTruncated, forKey: .previewTruncated)
        try container.encodeIfPresent(extractedText, forKey: .extractedText)
        try container.encodeIfPresent(imageDataBase64, forKey: .imageDataBase64)
        try container.encodeIfPresent(archiveSessionId, forKey: .archiveSessionId)
        try container.encodeIfPresent(archiveManifest, forKey: .archiveManifest)
        try container.encodeIfPresent(subpath, forKey: .subpath)
    }
}

/// Post-download lifecycle for staged `email.attachment` files.
public enum EmailAttachmentLifecycle: Sendable {
    /// Maximum bytes eligible for an inline preview (256 KB).
    public static let maxPreviewBytes = 256 * 1024
    /// Maximum chars inlined in `preview` before truncation.
    public static let maxPreviewChars = 2000
    /// Maximum entries returned in an archive manifest before truncation.
    public static let maxArchiveManifestEntries = 500
    /// Maximum characters accepted for an archive subpath.
    public static let maxArchiveSubpathChars = 1024
    /// Fallback retention window in days when the caller passes a non-positive value.
    ///
    /// Keeps expiry math total without coupling to detonation policy.
    public static let defaultRetentionDays = 14

    /// Returns the coarse MIME bucket for a content type.
    public static func mimeCategory(for contentType: String) -> String {
        let base = contentType.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? ""
        if base == "application/pdf" {
            return "pdf"
        }
        if base.hasPrefix("image/") {
            return "image"
        }
        if base.hasPrefix("text/") || base == "application/json" || base == "text/csv" {
            return "text"
        }
        switch base {
        case "application/zip", "application/x-zip-compressed",
             "application/x-tar", "application/tar",
             "application/gzip", "application/x-gzip",
             "application/x-7z-compressed", "application/x-rar-compressed":
            return "archive"
        default:
            return "other"
        }
    }

    /// Returns whether an attachment part must detonate inside a microVM.
    /// Delegates to the single archive truth table so MIME/extension membership
    /// cannot drift from magic-byte routing; byte-level matches layer on top
    /// inside `AttachmentSecurity.requiresMicroVMDetonation`.
    public static func isArchive(contentType: String, filename: String) -> Bool {
        AttachmentSecurity.isArchiveFilenameOrMime(contentType: contentType, filename: filename)
    }

    /// Validates an archive subpath without touching any filesystem.
    public static func validateArchiveSubpath(_ subpath: String) throws -> String {
        let trimmed = subpath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw EmailIMAPError.bridgeFailed("Invalid subpath: subpath must not be empty")
        }
        guard trimmed.count <= maxArchiveSubpathChars else {
            throw EmailIMAPError.bridgeFailed("Invalid subpath: subpath must be at most \(maxArchiveSubpathChars) characters")
        }
        if trimmed.unicodeScalars.contains(where: { $0.value == 13 || $0.value == 10 || $0.value == 0 }) {
            throw EmailIMAPError.bridgeFailed("Invalid subpath: subpath must not contain CR, LF, or NUL")
        }
        guard !trimmed.hasPrefix("/"), !trimmed.hasPrefix("\\") else {
            throw EmailIMAPError.bridgeFailed("Invalid subpath: subpath must be a relative path inside the archive")
        }
        let segments = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if segments.contains("..") {
            throw EmailIMAPError.bridgeFailed("Invalid subpath: subpath must not escape the archive")
        }
        return trimmed
    }

    /// Maps an archive entry path to the coarse MIME bucket.
    public static func archiveEntryCategory(forPath path: String) -> String {
        let lower = path.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.hasSuffix(".pdf") {
            return "pdf"
        }
        for suffix in [".png", ".jpg", ".jpeg", ".heic", ".heif", ".webp", ".gif", ".bmp", ".tiff", ".tif"] where lower.hasSuffix(suffix) {
            return "image"
        }
        for suffix in [".txt", ".md", ".markdown", ".csv", ".json", ".log", ".xml", ".html", ".htm"] where lower.hasSuffix(suffix) {
            return "text"
        }
        if isArchive(contentType: "application/octet-stream", filename: lower) {
            return "archive"
        }
        return "other"
    }

    /// Returns whether a part may be inlined as text.
    public static func isPreviewable(contentType: String, sizeBytes: Int, dataCount: Int) -> Bool {
        let base = contentType.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? ""
        let isTextType = base.hasPrefix("text/") || base == "application/json" || base == "text/csv"
        guard isTextType else { return false }
        return sizeBytes <= maxPreviewBytes && dataCount <= maxPreviewBytes
    }

    /// Builds the inline preview for an eligible payload.
    public static func inlinePreview(for data: Data) -> (text: String, truncated: Bool)? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        if text.count > maxPreviewChars {
            return (String(text.prefix(maxPreviewChars)), true)
        }
        return (text, false)
    }

    /// Returns the staged-file expiry for a retention window.
    public static func expiryDate(from now: Date = Date(), retentionDays: Int) -> Date {
        let days = retentionDays > 0 ? retentionDays : Self.defaultRetentionDays
        return now.addingTimeInterval(TimeInterval(days * 86400))
    }

    /// Formats an expiry date as ISO-8601 for the envelope.
    /// - Parameter date: Expiry date.
    /// - Returns: ISO-8601 string (internet date-time, no fractional seconds).
    public static func expiryString(from date: Date) -> String {
        // Shared UTC formatter preserves the envelope shape without per-call setup.
        SharedDateFormatters.isoInternetTimeUTCString(from: date)
    }

    /// Builds the human follow-up hint for an attachment outcome.
    public static func nextStepsHint(
        path: String? = nil,
        expiresAt: String? = nil,
        mimeCategory: String,
        previewTruncated: Bool? = nil,
        archiveSessionId: String? = nil
    ) -> String {
        let expiry = expiresAt ?? ""
        if let path, !path.isEmpty {
            switch mimeCategory {
            case "text" where previewTruncated == true:
                return "Preview shows the first 2000 chars. Use files.read with path \"\(path)\" for the full text. Staged file expires \(expiry)."
            case "text":
                return "Text staged at \"\(path)\". Use files.read with path \"\(path)\" for the full text. Staged file expires \(expiry)."
            case "pdf":
                return "PDF staged at \"\(path)\". Use files.read with path \"\(path)\" to extract a text preview. Staged file expires \(expiry)."
            case "image":
                return "Image staged at \"\(path)\". Use files.read with path \"\(path)\" to inspect it. Staged file expires \(expiry)."
            default:
                return "Attachment staged at \"\(path)\". Use files.read with path \"\(path)\" to inspect it. Staged file expires \(expiry)."
            }
        }

        switch mimeCategory {
        case "archive":
            let session = archiveSessionId ?? "active"
            return "Archive unpacked in quarantine session '\(session)'. "
                + "Call email.attachment with 'subpath' to inspect a file, or 'saveToPath' to copy to your workspace."
        case "image":
            return "Image sanitized and delivered as base64 block for multimodal visual inspection."
        case "text", "pdf":
            return "Document contents extracted directly into 'extractedText'."
        default:
            return "Attachment processed in isolated microVM container."
        }
    }
}

/// Merges per-mailbox search hits newest-first.
public enum EmailSearchMerge: Sendable {
    /// Parses an RFC 2822 or ISO-8601 `Date` header.
    /// Tries shared POSIX layouts first, then ISO-8601, so varied bridge date
    /// headers still sort newest-first without per-call formatter setup.
    private static func rfc2822Dates(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "dd MMM yyyy HH:mm:ss Z",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ssXXXXX",
            "yyyy-MM-dd HH:mm:ss Z"
        ]
        // One shared POSIX formatter serves every layout; no per-format allocation.
        for format in formats {
            if let date = SharedDateFormatters.posixDate(from: trimmed, format: format) {
                return date
            }
        }
        return SharedDateFormatters.isoDefaultDate(from: trimmed)
    }

    /// Parses a hit date for sorting.
    /// - Parameter hit: Hit whose `date` header is parsed.
    /// - Returns: Parsed date, or nil when absent or unparseable.
    public static func date(of hit: EmailSearchHit) -> Date? {
        rfc2822Dates(hit.date)
    }

    /// Merges per-mailbox hits newest-first, capped by `limit`.
    public static func mergedNewestFirst(_ groups: [[EmailSearchHit]], limit: Int) -> [EmailSearchHit] {
        let capped = max(1, limit)
        let indexed = groups.flatMap(\.self).enumerated().map { (index: $0.offset, hit: $0.element) }
        let dated = indexed.map { entry in
            (hit: entry.hit, index: entry.index, date: rfc2822Dates(entry.hit.date))
        }
        let sorted = dated.sorted { lhs, rhs in
            switch (lhs.date, rhs.date) {
            case let (left?, right?):
                if left != right {
                    return left > right
                }
                return lhs.index < rhs.index
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (nil, nil):
                return lhs.index < rhs.index
            }
        }
        return Array(sorted.prefix(capped).map(\.hit))
    }
}

// MARK: - Agent-visible credential filtering

extension EmailSearchHit {
    /// Returns the agent-visible copy of this hit, redacting credential links and codes.
    ///
    /// Snippet and subject rewrite together; sender, date, mailbox, and account
    /// stay visible so the agent knows what arrived where and can tell the
    /// user. The account label must survive byte-identically or follow-up
    /// `email.read`/`email.move` calls could not name the owning account. The
    /// human inbox is untouched — this applies solely to tool output. A
    /// disabled filter or a non-bearing verdict returns self byte-identically.
    /// - Parameter credentialFilterEnabled: False passes through byte-identically.
    /// - Returns: Redacted copy, or self when no redaction applies.
    public func agentVisible(credentialFilterEnabled: Bool = true) -> EmailSearchHit {
        EmailCredentialFilter.applyFilter(enabled: credentialFilterEnabled, original: self) {
            let visibleSnippet = EmailCredentialFilter.agentVisibleSnippet(
                subject: subject,
                snippet: snippet,
                enabled: credentialFilterEnabled
            )
            let visibleSubject = EmailCredentialFilter.agentVisibleSubject(
                subject: subject,
                body: snippet,
                enabled: credentialFilterEnabled
            )
            return EmailSearchHit(
                id: id,
                subject: visibleSubject,
                from: from,
                date: date,
                snippet: visibleSnippet,
                mailbox: mailbox,
                account: account,
                hasAttachments: hasAttachments,
                attachmentCount: attachmentCount
            )
        }
    }
}

extension EmailFullMessage {
    /// Returns the agent-visible copy of this message, redacting credential links and codes.
    ///
    /// Body and subject rewrite together; sender, recipients, and attachment
    /// metadata stay visible. A disabled filter or a non-bearing verdict
    /// returns self byte-identically.
    /// - Parameter credentialFilterEnabled: False passes through byte-identically.
    /// - Returns: Redacted copy, or self when no redaction applies.
    public func agentVisible(credentialFilterEnabled: Bool = true) -> EmailFullMessage {
        EmailCredentialFilter.applyFilter(enabled: credentialFilterEnabled, original: self) {
            let visibleBody = EmailCredentialFilter.agentVisibleBody(
                subject: subject,
                body: body,
                enabled: credentialFilterEnabled
            )
            let visibleSubject = EmailCredentialFilter.agentVisibleSubject(
                subject: subject,
                body: body,
                enabled: credentialFilterEnabled
            )
            return EmailFullMessage(
                id: id,
                subject: visibleSubject,
                from: from,
                to: to,
                date: date,
                body: visibleBody,
                attachments: attachments,
                attachmentsDeferred: attachmentsDeferred,
                attachmentsNote: attachmentsNote
            )
        }
    }
}

extension EmailSearchEnvelope {
    /// Returns the agent-visible envelope with every hit filtered.
    ///
    /// Filtering maps over hits so the count and ordering stay identical and
    /// only snippet and subject text can change; sender, mailbox, and the
    /// account-routing fields never redact.
    /// - Parameter credentialFilterEnabled: False passes through byte-identically.
    /// - Returns: Envelope whose messages are agent-visible.
    public func agentVisible(credentialFilterEnabled: Bool = true) -> EmailSearchEnvelope {
        EmailCredentialFilter.applyFilter(enabled: credentialFilterEnabled, original: self) {
            let visible = messages.map { $0.agentVisible(credentialFilterEnabled: credentialFilterEnabled) }
            return EmailSearchEnvelope(
                account: account,
                query: query,
                messages: visible,
                mailbox: mailbox,
                mailboxes: mailboxes,
                accounts: accounts,
                failedAccounts: failedAccounts
            )
        }
    }
}

extension EmailReadEnvelope {
    /// Returns the agent-visible read envelope with subject and body filtered.
    ///
    /// Only subject and body can change; every other header and the mailbox
    /// label pass through so the agent keeps full routing context.
    /// - Parameter credentialFilterEnabled: False passes through byte-identically.
    /// - Returns: Envelope whose subject and body are agent-visible.
    public func agentVisible(credentialFilterEnabled: Bool = true) -> EmailReadEnvelope {
        EmailCredentialFilter.applyFilter(enabled: credentialFilterEnabled, original: self) {
            let visibleBody = EmailCredentialFilter.agentVisibleBody(
                subject: subject,
                body: body,
                enabled: credentialFilterEnabled
            )
            let visibleSubject = EmailCredentialFilter.agentVisibleSubject(
                subject: subject,
                body: body,
                enabled: credentialFilterEnabled
            )
            let message = EmailFullMessage(
                id: id,
                subject: visibleSubject,
                from: from,
                to: to,
                date: date,
                body: visibleBody,
                attachments: attachments,
                attachmentsDeferred: attachmentsDeferred,
                attachmentsNote: attachmentsNote
            )
            return EmailReadEnvelope(account: account, message: message, mailbox: mailbox)
        }
    }
}

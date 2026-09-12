import Foundation

/// Shared mailbox-name normalization for email args and envelopes.
///
/// Centralizes trimming and the legacy `INBOX` default so arg structs
/// and envelope payloads stay consistent without triplicated logic.
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
    ///
    /// Trims surrounding whitespace and falls back to the legacy
    /// `INBOX` default when the value is nil, empty, or blank so
    /// legacy payloads without a mailbox keep decoding.
    /// - Parameter value: Raw mailbox value, if any.
    /// - Returns: Trimmed mailbox, or `INBOX` when blank.
    public static func normalizedMailbox(_ value: String?) -> String {
        guard let trimmed = trimmed(value), !trimmed.isEmpty else { return "INBOX" }
        return trimmed
    }
}

/// Search arguments for the `email.search` tool.
///
/// Decodes the raw `ToolInput.argumentsJSON` document. `limit` is
/// optional and clamped to `1...50` (defaulting to `10`) so the IMAP
/// bridge never fetches an unbounded mailbox slice. An empty,
/// whitespace-only, or lone `"*"` query lists the most-recent messages
/// via `SEARCH ALL` (newest first) instead of a literal text match.
/// `mailbox` is optional: omitted or blank searches every selectable
/// mailbox and merges hits newest-first; a value narrows to one folder.
public struct EmailSearchArgs: Sendable, Equatable, Decodable {
    /// Account nickname matching an `EmailAccount.name` entry.
    public let account: String
    /// Free-text query matched against subject, sender, and body (`"*"`/empty means most-recent via `ALL`).
    public let query: String
    /// Maximum hits to return, clamped to `1...50`.
    public let limit: Int
    /// Optional mailbox narrowing the search to one folder (nil means every selectable mailbox).
    public let mailbox: String?

    /// Default hit count when the caller omits `limit`.
    public static let defaultLimit = 10
    /// Upper bound for `limit` so searches stay bounded.
    public static let maxLimit = 50

    /// Memberwise initializer with limit clamping.
    /// - Parameters:
    ///   - account: Account nickname.
    ///   - query: Free-text query.
    ///   - limit: Maximum hits. Clamped to `1...50`.
    ///   - mailbox: Optional mailbox narrowing to one folder.
    public init(account: String, query: String, limit: Int = defaultLimit, mailbox: String? = nil) {
        self.account = account
        self.query = query
        self.limit = min(max(limit, 1), Self.maxLimit)
        self.mailbox = mailbox
    }

    private enum CodingKeys: String, CodingKey {
        case account
        case query
        case limit
        case mailbox
        case folder
    }

    /// Decodes arguments, trimming whitespace and clamping `limit`.
    /// - Parameter decoder: Decoder for the arguments document.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let account = try container.decode(String.self, forKey: .account)
        let query = try container.decode(String.self, forKey: .query)
        let rawLimit = try container.decodeIfPresent(Int.self, forKey: .limit) ?? Self.defaultLimit
        let mailbox = try container.decodeIfPresent(String.self, forKey: .mailbox)
            ?? container.decodeIfPresent(String.self, forKey: .folder)
        self.init(account: account, query: query, limit: rawLimit, mailbox: mailbox)
    }

    /// Trimmed account nickname.
    public var trimmedAccount: String {
        account.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Trimmed query text.
    public var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Trimmed mailbox narrowing, or nil when omitted or blank (meaning every selectable mailbox).
    public var trimmedMailbox: String? {
        EmailMailboxNormalization.trimmed(mailbox)
    }
}

/// Read arguments for the `email.read` tool.
///
/// Accepts the message identifier under `id` (canonical) plus the
/// `messageId`, `message_id`, and `uid` aliases so model-generated
/// calls keep working when the field name drifts. Accepts an optional
/// `mailbox` (plus the `folder` alias) reusing the mailbox labeled on
/// `email.search` hits so messages outside `INBOX` stay openable;
/// omitted or blank means `INBOX`.
public struct EmailReadArgs: Sendable, Equatable, Decodable {
    /// Account nickname matching an `EmailAccount.name` entry.
    public let account: String
    /// IMAP UID (falling back to sequence number) of the message.
    public let messageID: String
    /// Optional mailbox holding the message (nil means `INBOX`).
    public let mailbox: String?

    /// Memberwise initializer.
    /// - Parameters:
    ///   - account: Account nickname.
    ///   - messageID: IMAP UID of the message.
    ///   - mailbox: Optional mailbox holding the message.
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
    /// - Parameter decoder: Decoder for the arguments document.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        account = try container.decode(String.self, forKey: .account)
        if let direct = try container.decodeIfPresent(String.self, forKey: .id), !direct.isEmpty {
            messageID = direct
        } else if let alias = try container.decodeIfPresent(String.self, forKey: .messageId), !alias.isEmpty {
            messageID = alias
        } else if let snake = try container.decodeIfPresent(String.self, forKey: .messageID), !snake.isEmpty {
            messageID = snake
        } else if let uid = try container.decodeIfPresent(String.self, forKey: .uid), !uid.isEmpty {
            messageID = uid
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.id,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Missing message id (expected 'id', 'messageId', 'message_id', or 'uid')"
                )
            )
        }
        mailbox = try container.decodeIfPresent(String.self, forKey: .mailbox)
            ?? container.decodeIfPresent(String.self, forKey: .folder)
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
///
/// The snippet is the leading plain-text body collapsed to a single
/// line (at most 200 characters). It never contains attachment bytes.
/// `mailbox` labels the folder holding the message so `email.read`
/// and `email.attachment` can reopen it by passing the same mailbox.
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

    /// Creates a search hit.
    /// - Parameters:
    ///   - id: IMAP UID of the message.
    ///   - subject: Decoded subject.
    ///   - from: Decoded sender.
    ///   - date: Raw date header.
    ///   - snippet: Leading body text.
    ///   - mailbox: Mailbox holding the message. Defaults to `INBOX` for legacy payloads.
    public init(id: String, subject: String, from: String, date: String, snippet: String, mailbox: String = "INBOX") {
        self.id = id
        self.subject = subject
        self.from = from
        self.date = date
        self.snippet = snippet
        self.mailbox = EmailMailboxNormalization.normalizedMailbox(mailbox)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case subject
        case from
        case date
        case snippet
        case mailbox
    }

    /// Decodes a hit, defaulting legacy payloads without `mailbox` to `INBOX`.
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
    }

    /// Encodes a hit including its mailbox label.
    /// - Parameter encoder: Encoder for the hit document.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(subject, forKey: .subject)
        try container.encode(from, forKey: .from)
        try container.encode(date, forKey: .date)
        try container.encode(snippet, forKey: .snippet)
        try container.encode(mailbox, forKey: .mailbox)
    }
}

/// Attachment metadata for `email.read`.
///
/// `email.read` never downloads attachment bytes. Each part is listed
/// here by filename, MIME type, and decoded byte size so the model can
/// name what is available and `email.attachment` can fetch it by index.
public struct EmailAttachmentInfo: Sendable, Equatable, Codable {
    /// Original filename (or `unnamed-attachment` when absent).
    public let filename: String
    /// MIME type (e.g. `application/pdf`).
    public let contentType: String
    /// Decoded byte size of the attachment part (nil when unknown).
    public let sizeBytes: Int?

    /// Creates attachment metadata.
    /// - Parameters:
    ///   - filename: Original filename.
    ///   - contentType: MIME type.
    ///   - sizeBytes: Decoded byte size. Defaults to nil (unknown).
    public init(filename: String, contentType: String, sizeBytes: Int? = nil) {
        self.filename = filename
        self.contentType = contentType
        self.sizeBytes = sizeBytes
    }
}

/// Full message returned by `email.read`.
///
/// `body` holds decoded plain text (HTML is stripped to text when no
/// plain part exists). Attachment bytes are never included; listed
/// parts appear in `attachments` with `attachmentsDeferred` set and a
/// human-readable `attachmentsNote`. `attachmentsDeferred` keeps its
/// legacy wire name for compatibility but means "listed, fetchable via
/// `email.attachment`" rather than skipped-and-unavailable.
public struct EmailFullMessage: Sendable, Equatable, Codable {
    /// IMAP UID of the message.
    public let id: String
    /// Decoded `Subject` header.
    public let subject: String
    /// Decoded `From` header.
    public let from: String
    // Decoded `To` header.
    // swiftlint:disable:next identifier_name
    public let to: String
    /// Raw `Date` header.
    public let date: String
    /// Decoded plain-text body.
    public let body: String
    /// Listed attachment parts (empty when none).
    public let attachments: [EmailAttachmentInfo]
    /// Whether attachments are listed (true when `attachments` is non-empty). Legacy wire name kept for compatibility.
    public let attachmentsDeferred: Bool
    /// Human-readable listing note (nil when no attachments are listed).
    public let attachmentsNote: String?

    /// Creates a full message.
    /// - Parameters:
    ///   - id: IMAP UID.
    ///   - subject: Decoded subject.
    ///   - from: Decoded sender.
    ///   - to: Decoded recipients.
    ///   - date: Raw date header.
    ///   - body: Decoded plain-text body.
    ///   - attachments: Listed attachment parts.
    ///   - attachmentsDeferred: Whether attachments are listed (legacy wire name for listed state).
    ///   - attachmentsNote: Human-readable listing note.
    public init(
        id: String,
        subject: String,
        from: String,
        // swiftlint:disable:next identifier_name
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
///
/// Encoded as the `ToolOutput.content` JSON document so the model
/// receives the account, query, hit count, and hits together.
/// `mailbox` echoes the requested narrowing (nil means every selectable
/// mailbox); `mailboxes` lists the folders actually searched; each hit
/// carries its own `mailbox` so `email.read` can reopen it.
public struct EmailSearchEnvelope: Sendable, Equatable, Codable {
    /// Account nickname that was searched.
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

    /// Creates a search envelope.
    /// - Parameters:
    ///   - account: Account nickname.
    ///   - query: Query that was run.
    ///   - messages: Hits, newest first.
    ///   - mailbox: Requested mailbox narrowing. Defaults to nil (every selectable mailbox).
    ///   - mailboxes: Folders actually searched. Defaults to nil for legacy callers.
    public init(account: String, query: String, messages: [EmailSearchHit], mailbox: String? = nil, mailboxes: [String]? = nil) {
        self.account = account
        self.query = query
        self.messages = messages
        self.count = messages.count
        self.mailbox = mailbox
        self.mailboxes = mailboxes
    }
}

/// Envelope wrapping `email.read` tool output.
///
/// Encoded as the `ToolOutput.content` JSON document so the model
/// receives headers, the text body, and the attachment listing note
/// together. `mailbox` echoes the folder the message was read from so
/// `email.attachment` can reuse it.
public struct EmailReadEnvelope: Sendable, Equatable, Codable {
    /// Account nickname the message was read from.
    public let account: String
    /// IMAP UID of the message.
    public let id: String
    /// Decoded `Subject` header.
    public let subject: String
    /// Decoded `From` header.
    public let from: String
    // Decoded `To` header.
    // swiftlint:disable:next identifier_name
    public let to: String
    /// Raw `Date` header.
    public let date: String
    /// Decoded plain-text body.
    public let body: String
    /// Listed attachment parts.
    public let attachments: [EmailAttachmentInfo]
    /// Whether attachments are listed (legacy wire name for listed state).
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
        // swiftlint:disable:next identifier_name
        case to
        case date
        case body
        case attachments
        case attachmentsDeferred
        case attachmentsNote
        case mailbox
    }

    /// Creates a read envelope from a decoded message.
    /// - Parameters:
    ///   - account: Account nickname.
    ///   - message: Decoded message.
    ///   - mailbox: Mailbox the message was read from. Defaults to `INBOX` for legacy callers.
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

    /// Decodes a read envelope, defaulting legacy payloads without `mailbox` to `INBOX`.
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
///
/// Accepts the message identifier under `id` (canonical) plus the
/// `messageId`, `message_id`, and `uid` aliases so model-generated
/// calls keep working when the field name drifts. Accepts the part
/// position under `index` (canonical) plus `attachmentIndex` and
/// `attachment_index` so callers can name the field either way. The
/// index is zero-based into the `email.read` attachment list. Accepts
/// an optional `mailbox` (plus the `folder` alias) reusing the mailbox
/// labeled on `email.search` hits; omitted or blank means `INBOX`.
public struct EmailAttachmentArgs: Sendable, Equatable, Decodable {
    /// Account nickname matching an `EmailAccount.name` entry.
    public let account: String
    /// IMAP UID (falling back to sequence number) of the message.
    public let messageID: String
    /// Zero-based position in the `email.read` attachment list.
    public let attachmentIndex: Int
    /// Optional mailbox holding the message (nil means `INBOX`).
    public let mailbox: String?

    /// Memberwise initializer.
    /// - Parameters:
    ///   - account: Account nickname.
    ///   - messageID: IMAP UID of the message.
    ///   - attachmentIndex: Zero-based attachment position.
    ///   - mailbox: Optional mailbox holding the message.
    public init(account: String, messageID: String, attachmentIndex: Int, mailbox: String? = nil) {
        self.account = account
        self.messageID = messageID
        self.attachmentIndex = attachmentIndex
        self.mailbox = mailbox
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
    }

    /// Decodes arguments, accepting every documented id and index alias.
    /// - Parameter decoder: Decoder for the arguments document.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        account = try container.decode(String.self, forKey: .account)
        if let direct = try container.decodeIfPresent(String.self, forKey: .id), !direct.isEmpty {
            messageID = direct
        } else if let alias = try container.decodeIfPresent(String.self, forKey: .messageId), !alias.isEmpty {
            messageID = alias
        } else if let snake = try container.decodeIfPresent(String.self, forKey: .messageID), !snake.isEmpty {
            messageID = snake
        } else if let uid = try container.decodeIfPresent(String.self, forKey: .uid), !uid.isEmpty {
            messageID = uid
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.id,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Missing message id (expected 'id', 'messageId', 'message_id', or 'uid')"
                )
            )
        }
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
        mailbox = try container.decodeIfPresent(String.self, forKey: .mailbox)
            ?? container.decodeIfPresent(String.self, forKey: .folder)
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

/// One downloaded attachment with its bytes.
///
/// Returned by the IMAP gateway for `email.attachment`. The bytes are
/// held in memory only until the tool stages them under the sandbox
/// staging area; they are never logged and never sent to the LLM.
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
    /// - Parameters:
    ///   - filename: Original filename.
    ///   - contentType: MIME type.
    ///   - sizeBytes: Decoded byte size.
    ///   - data: Decoded attachment bytes.
    public init(filename: String, contentType: String, sizeBytes: Int, data: Data) {
        self.filename = filename
        self.contentType = contentType
        self.sizeBytes = sizeBytes
        self.data = data
    }
}

/// Envelope wrapping `email.attachment` tool output.
///
/// Encoded as the `ToolOutput.content` JSON document so the model
/// receives the staged sandbox path (or the skip note) together with
/// the attachment metadata. `path` is nil when the download was
/// skipped; `skipped` with a `note` explains oversized and dry-run
/// outcomes without writing outside the staging area. `mailbox`
/// echoes the folder the bytes were fetched from so follow-up reads
/// stay in the same folder.
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
    /// Sandbox staging path the bytes were written to (nil when skipped).
    public let path: String?
    /// Whether the download was skipped (oversized part or dry run).
    public let skipped: Bool
    /// Human-readable note for skipped downloads (nil when saved).
    public let note: String?
    /// Mailbox the attachment was fetched from.
    public let mailbox: String

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
    }

    /// Creates an attachment envelope.
    /// - Parameters:
    ///   - account: Account nickname.
    ///   - id: IMAP UID of the message.
    ///   - index: Zero-based attachment position.
    ///   - filename: Original filename.
    ///   - contentType: MIME type.
    ///   - sizeBytes: Decoded byte size.
    ///   - path: Sandbox staging path, or nil when skipped.
    ///   - skipped: Whether the download was skipped.
    ///   - note: Human-readable skip note, if any.
    ///   - mailbox: Mailbox the attachment was fetched from. Defaults to `INBOX` for legacy callers.
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
        mailbox: String = "INBOX"
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
    }

    /// Decodes an attachment envelope, defaulting legacy payloads without `mailbox` to `INBOX`.
    /// - Parameter decoder: Decoder for the envelope document.
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
    }

    /// Encodes an attachment envelope including its mailbox.
    /// - Parameter encoder: Encoder for the envelope document.
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
    }
}

/// Pure JSON parsing for the IMAP bridge payloads.
///
/// These helpers decode exactly what the `python3 imaplib` subprocess
/// prints on stdout, so fixture tests can cover the wire format
/// without a live mailbox. They never touch the network and never see
/// credentials.
public enum EmailBridgeParsing {
    /// Bridge `search` response shape.
    struct SearchResponse: Decodable {
        // Whether the operation succeeded.
        // swiftlint:disable:next identifier_name
        let ok: Bool
        /// Error detail when `ok` is false.
        let error: String?
        /// Hits when `ok` is true.
        let messages: [EmailSearchHit]?
    }

    /// Bridge `fetch` response shape.
    struct FetchResponse: Decodable {
        // Whether the operation succeeded.
        // swiftlint:disable:next identifier_name
        let ok: Bool
        /// Error detail when `ok` is false.
        let error: String?
        /// Message when `ok` is true.
        let message: EmailFullMessage?
    }

    /// Bridge `attachment` payload shape.
    struct BridgeAttachmentPayload: Decodable {
        /// Original filename.
        let filename: String
        /// MIME type.
        let contentType: String
        /// Decoded byte size.
        let sizeBytes: Int?
        /// Base64-encoded attachment bytes (nil for Python-enforced oversize skips).
        let contentBase64: String?
        /// Oversize marker set by the bridge when the part exceeds the download cap before base64 encoding.
        let oversize: Bool?
    }

    /// Bridge `attachment` response shape.
    struct AttachmentResponse: Decodable {
        // Whether the operation succeeded.
        // swiftlint:disable:next identifier_name
        let ok: Bool
        /// Error detail when `ok` is false.
        let error: String?
        /// Attachment payload when `ok` is true.
        let attachment: BridgeAttachmentPayload?
    }

    /// Bridge `list` response shape.
    struct ListResponse: Decodable {
        // Whether the operation succeeded.
        // swiftlint:disable:next identifier_name
        let ok: Bool
        /// Error detail when `ok` is false.
        let error: String?
        /// Selectable mailboxes when `ok` is true.
        let mailboxes: [String]?
    }

    /// Decodes a bridge `search` stdout payload.
    /// - Parameter data: Raw stdout bytes from the bridge.
    /// - Returns: Hits, newest first.
    /// - Throws: Decoding errors or bridge-reported failures.
    public static func parseSearchPayload(_ data: Data) throws -> [EmailSearchHit] {
        let response = try JSONDecoder().decode(SearchResponse.self, from: data)
        if !response.ok {
            throw EmailIMAPError.bridgeFailed(response.error ?? "IMAP search failed")
        }
        return response.messages ?? []
    }

    /// Decodes a bridge `fetch` stdout payload.
    /// - Parameter data: Raw stdout bytes from the bridge.
    /// - Returns: Decoded message.
    /// - Throws: Decoding errors or bridge-reported failures.
    public static func parseFetchPayload(_ data: Data) throws -> EmailFullMessage {
        let response = try JSONDecoder().decode(FetchResponse.self, from: data)
        if !response.ok {
            throw EmailIMAPError.bridgeFailed(response.error ?? "IMAP fetch failed")
        }
        guard let message = response.message else {
            throw EmailIMAPError.decodeFailed("IMAP bridge returned no message")
        }
        return message
    }

    /// Encodes search hits as the `email.search` tool output document.
    /// - Parameters:
    ///   - account: Account nickname.
    ///   - query: Query that was run.
    ///   - messages: Hits, newest first.
    ///   - mailbox: Requested mailbox narrowing. Defaults to nil (every selectable mailbox).
    ///   - mailboxes: Folders actually searched. Defaults to nil for legacy callers.
    /// - Returns: JSON document for `ToolOutput.content`.
    /// - Throws: Encoding errors.
    public static func encodeSearchEnvelope(account: String, query: String, messages: [EmailSearchHit], mailbox: String? = nil, mailboxes: [String]? = nil) throws -> String {
        let envelope = EmailSearchEnvelope(account: account, query: query, messages: messages, mailbox: mailbox, mailboxes: mailboxes)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(envelope)
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    /// Encodes a message as the `email.read` tool output document.
    /// - Parameters:
    ///   - account: Account nickname.
    ///   - message: Decoded message.
    ///   - mailbox: Mailbox the message was read from. Defaults to `INBOX` for legacy callers.
    /// - Returns: JSON document for `ToolOutput.content`.
    /// - Throws: Encoding errors.
    public static func encodeReadEnvelope(account: String, message: EmailFullMessage, mailbox: String = "INBOX") throws -> String {
        let envelope = EmailReadEnvelope(account: account, message: message, mailbox: mailbox)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(envelope)
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    /// Decodes a bridge `attachment` stdout payload.
    ///
    /// Decodes base64 strictly (no `ignoreUnknownCharacters`) so corrupt
    /// payloads fail instead of silently dropping bytes, and verifies a
    /// reported `sizeBytes` against the actual decoded length, failing on
    /// mismatch. Python-enforced oversize skips (no bytes with
    /// `oversize` set) decode to empty data with the reported size so the
    /// caller still reports the skip without ever materializing the bytes.
    /// - Parameter data: Raw stdout bytes from the bridge.
    /// - Returns: Downloaded attachment bytes.
    /// - Throws: Decoding errors or bridge-reported failures.
    public static func parseAttachmentPayload(_ data: Data) throws -> EmailAttachmentData {
        let response: AttachmentResponse
        do {
            response = try JSONDecoder().decode(AttachmentResponse.self, from: data)
        } catch {
            throw EmailIMAPError.decodeFailed(error.localizedDescription)
        }
        if !response.ok {
            throw EmailIMAPError.bridgeFailed(response.error ?? "IMAP attachment fetch failed")
        }
        guard let payload = response.attachment else {
            throw EmailIMAPError.decodeFailed("IMAP bridge returned no attachment")
        }
        if payload.contentBase64 == nil || payload.contentBase64?.isEmpty == true, payload.oversize == true {
            guard let reported = payload.sizeBytes else {
                throw EmailIMAPError.decodeFailed("IMAP bridge returned no attachment bytes")
            }
            return EmailAttachmentData(
                filename: payload.filename,
                contentType: payload.contentType,
                sizeBytes: reported,
                data: Data()
            )
        }
        guard let encoded = payload.contentBase64, !encoded.isEmpty else {
            throw EmailIMAPError.decodeFailed("IMAP bridge returned no attachment bytes")
        }
        guard let bytes = Data(base64Encoded: encoded) else {
            throw EmailIMAPError.decodeFailed("IMAP bridge returned invalid base64")
        }
        if let reported = payload.sizeBytes, reported != bytes.count {
            throw EmailIMAPError.decodeFailed(
                "IMAP bridge size mismatch: reported \(reported) bytes but decoded \(bytes.count) bytes"
            )
        }
        let size = payload.sizeBytes ?? bytes.count
        return EmailAttachmentData(
            filename: payload.filename,
            contentType: payload.contentType,
            sizeBytes: size,
            data: bytes
        )
    }

    /// Encodes an attachment result as the `email.attachment` tool output document.
    /// - Parameter envelope: Envelope to encode.
    /// - Returns: JSON document for `ToolOutput.content`.
    /// - Throws: Encoding errors.
    public static func encodeAttachmentEnvelope(_ envelope: EmailAttachmentEnvelope) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(envelope)
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    /// Decodes a bridge `list` stdout payload.
    /// - Parameter data: Raw stdout bytes from the bridge.
    /// - Returns: Selectable mailbox names in server order.
    /// - Throws: Decoding errors or bridge-reported failures.
    public static func parseListPayload(_ data: Data) throws -> [String] {
        let response = try JSONDecoder().decode(ListResponse.self, from: data)
        if !response.ok {
            throw EmailIMAPError.bridgeFailed(response.error ?? "IMAP list failed")
        }
        return response.mailboxes ?? []
    }

    /// Filters a raw `LIST` mailbox list to selectable folders.
    ///
    /// Mirrors the bridge exclusion (`is_selectable` in Python): entries whose flags contain
    /// `noselect` or `nonexistent` as case-insensitive substrings are dropped so
    /// namespace placeholders never enter the fan-out. Matching is
    /// case-insensitive substring matching, mirroring the Python bridge.
    /// - Parameter entries: Raw `(flags, mailbox)` pairs from the bridge or fixtures.
    /// - Returns: Selectable mailbox names in the given order.
    public static func selectableMailboxes(from entries: [(flags: String, mailbox: String)]) -> [String] {
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
    ///
    /// Exact matches win first so case-sensitive servers keep `Archive`
    /// and `archive` distinct; a case-insensitive fallback keeps `inbox`
    /// usable for `INBOX` per RFC 3501. Never logs or echoes secrets.
    /// - Parameters:
    ///   - requested: Trimmed requested mailbox.
    ///   - available: Selectable mailboxes in server order.
    /// - Returns: Canonical mailbox name, or nil when unknown.
    public static func resolveMailbox(_ requested: String, among available: [String]) -> String? {
        if available.contains(requested) {
            return requested
        }
        let lowered = requested.lowercased()
        return available.first { $0.lowercased() == lowered }
    }

    /// Resolves a requested mailbox against an already-listed selectable list.
    ///
    /// Centralizes `LIST` validation so every tool shares one path: folder names are never
    /// assumed, an empty list throws a no-selectable-mailboxes failure, and matching is
    /// exact-first with a case-insensitive fallback (see `resolveMailbox`). The legacy-default
    /// `INBOX` for omitted or blank mailboxes is also routed through this helper with
    /// `requested: "INBOX"` so defaults validate like explicit values.
    /// - Parameters:
    ///   - requested: Trimmed requested mailbox (`"INBOX"` for the legacy default).
    ///   - available: Selectable mailboxes in server order.
    /// - Returns: Canonical mailbox name.
    /// - Throws: Unknown-mailbox failure when the list is empty or has no match.
    public static func resolveMailboxAgainstList(requested: String, available: [String]) throws -> String {
        guard !available.isEmpty else {
            throw unknownMailboxError(requested: requested, available: available)
        }
        guard let canonical = resolveMailbox(requested, among: available) else {
            throw unknownMailboxError(requested: requested, available: available)
        }
        return canonical
    }

    /// Builds the unknown-mailbox failure without secrets.
    /// - Parameters:
    ///   - requested: Unknown requested mailbox.
    ///   - available: Selectable mailboxes in server order.
    /// - Returns: Human-readable failure naming the available folders.
    public static func unknownMailboxError(requested: String, available: [String]) -> EmailIMAPError {
        if available.isEmpty {
            return EmailIMAPError.bridgeFailed("Unknown mailbox '\(requested)' (no selectable mailboxes found)")
        }
        return EmailIMAPError.bridgeFailed("Unknown mailbox '\(requested)' (available: \(available.sorted().joined(separator: ", ")))")
    }
}

/// Merges per-mailbox search hits newest-first.
///
/// Each mailbox already returns hits newest-first by UID order; across
/// mailboxes UIDs are not comparable, so the merge sorts by the parsed
/// `Date` header descending (RFC 2822 plus ISO-8601 fallbacks) and
/// truncates to `limit`. Hits with unparseable or empty dates keep
/// their relative order after dated hits so the merge never drops
/// results. Mailbox labels are preserved for `email.read` reuse.
public enum EmailSearchMerge: Sendable {
    /// Lock-guarded cache of `Date` header formatters, built once.
    ///
    /// `DateFormatter` and `ISO8601DateFormatter` are not `Sendable` and
    /// are not thread-safe, so the cached instances live in this
    /// `@unchecked Sendable` box and every parse runs while holding the
    /// lock (which uses `defer` for unlock), keeping the shared
    /// `static let` data-race free under Swift 6 concurrency.
    private final class DateParserCache: @unchecked Sendable {
        /// Guards `formatters` and `isoFormatter`.
        private let lock = NSLock()
        /// Cached formatters for `Date` headers, built once.
        private let formatters: [DateFormatter]
        /// Cached ISO-8601 fallback formatter, built once.
        private let isoFormatter: ISO8601DateFormatter

        /// Builds the cached formatters once.
        init() {
            let formats = [
                "EEE, dd MMM yyyy HH:mm:ss Z",
                "EEE, d MMM yyyy HH:mm:ss Z",
                "EEE, dd MMM yyyy HH:mm:ss zzz",
                "dd MMM yyyy HH:mm:ss Z",
                "yyyy-MM-dd'T'HH:mm:ssZ",
                "yyyy-MM-dd'T'HH:mm:ssXXXXX",
                "yyyy-MM-dd HH:mm:ss Z"
            ]
            formatters = formats.map { format in
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = format
                return formatter
            }
            isoFormatter = ISO8601DateFormatter()
        }

        /// Parses an already-trimmed date string under the lock.
        /// - Parameter trimmed: Non-empty trimmed `Date` header value.
        /// - Returns: Parsed date, or nil when no formatter matches.
        func date(from trimmed: String) -> Date? {
            lock.lock()
            defer { lock.unlock() }
            for formatter in formatters {
                if let date = formatter.date(from: trimmed) {
                    return date
                }
            }
            return isoFormatter.date(from: trimmed)
        }
    }

    /// Shared formatter cache, built once.
    ///
    /// Immutable box; all parsing runs inside the box lock so no
    /// `nonisolated(unsafe)` mutable state is needed.
    private static let parserCache = DateParserCache()

    /// Shared RFC 2822 formatter for `Date` headers.
    private static func rfc2822Dates(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return parserCache.date(from: trimmed)
    }

    /// Parses a hit date for sorting.
    /// - Parameter hit: Hit whose `date` header is parsed.
    /// - Returns: Parsed date, or nil when absent or unparseable.
    public static func date(of hit: EmailSearchHit) -> Date? {
        rfc2822Dates(hit.date)
    }

    /// Merges per-mailbox hits newest-first, capped by `limit`.
    /// - Parameters:
    ///   - groups: Per-mailbox hits in search order (each newest-first).
    ///   - limit: Maximum hits to keep. Clamped to at least 1.
    /// - Returns: Merged hits newest-first, mailbox labels preserved.
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

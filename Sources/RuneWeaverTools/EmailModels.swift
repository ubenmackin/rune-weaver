// Rune Weaver Tools — Email arg/envelope models and bridge wire formats.
//
// Defines the `email.search`/`email.read`/`email.attachment` argument shapes,
// result envelopes, attachment lifecycle hints, and strict bridge payload
// parsing, keeping model-facing contracts and IMAP subprocess wire formats
// in one place so tools share decoding without touching the network.

import Foundation
import RuneWeaverCore

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
    /// Decoded `To` header.
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
    /// Decoded `To` header.
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
/// `preview` is optional (defaults to false): when true and the part is
/// a small text payload, the success envelope inlines the leading text.
/// `subpath` names one file inside a detonated archive for inspection
/// without staging anything to the host; `saveToPath` names the
/// workspace destination for an approval-gated export of that entry
/// (or the raw archive when no subpath is given). Both stay nil for
/// documents and images, which return inline payloads directly.
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
    /// - Parameters:
    ///   - account: Account nickname.
    ///   - messageID: IMAP UID of the message.
    ///   - attachmentIndex: Zero-based attachment position.
    ///   - mailbox: Optional mailbox holding the message.
    ///   - preview: Whether to inline a text preview.
    ///   - subpath: Relative entry path inside a detonated archive.
    ///   - saveToPath: Workspace destination for an approval-gated archive export.
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
        // Optional preview flag keeps legacy payloads decoding with no inline text.
        preview = try container.decodeIfPresent(Bool.self, forKey: .preview) ?? false
        // Archive follow-ups stay optional so legacy download-only payloads keep decoding;
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
///
/// Encoded as the `ToolOutput.content` JSON document so the model
/// receives the staged path, extracted text, multimodal image payload,
/// or archive session manifest together with attachment metadata.
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
///
/// Centralizes the coarse MIME bucket, the retention-window expiry, the
/// human follow-up hint, and the guarded inline text preview so the
/// tool and its tests share one definition of "previewable". Size caps
/// stay conservative: binaries are never inlined even when tiny, and
/// text is only inlined well below the 10 MB download cap so a preview
/// request cannot balloon the tool output.
public enum EmailAttachmentLifecycle: Sendable {
    /// Maximum bytes eligible for an inline preview (256 KB).
    public static let maxPreviewBytes = 256 * 1024
    /// Maximum chars inlined in `preview` before truncation.
    public static let maxPreviewChars = 2000
    /// Maximum entries returned in an archive manifest before truncation.
    public static let maxArchiveManifestEntries = 500
    /// Maximum characters accepted for an archive subpath.
    public static let maxArchiveSubpathChars = 1024

    /// Returns the coarse MIME bucket for a content type.
    ///
    /// Matching is case-insensitive on the bare type (parameters such as
    /// `; charset=utf-8` are stripped): exact `application/pdf` maps to
    /// `pdf`, any `image/*` to `image`, any `text/*` plus `application/json`
    /// to `text`, known archive types (ZIP/TAR/GZIP families) to `archive`,
    /// and everything else to `other` so follow-up hints stay predictable
    /// without an exhaustive type table.
    /// - Parameter contentType: Raw MIME type, possibly with parameters.
    /// - Returns: `pdf`, `image`, `text`, `archive`, or `other`.
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
    ///
    /// Content types missed by the sender (notably `application/octet-stream`
    /// for renamed ZIPs) still detonate when the filename carries an archive
    /// suffix, so a mislabeled archive can never slip into host staging.
    /// Matching is case-insensitive on both inputs.
    /// - Parameters:
    ///   - contentType: Raw MIME type, possibly with parameters.
    ///   - filename: Original attachment filename.
    /// - Returns: True for archive content types or archive filename suffixes.
    public static func isArchive(contentType: String, filename: String) -> Bool {
        if mimeCategory(for: contentType) == "archive" {
            return true
        }
        let lower = filename.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for suffix in [".zip", ".tar", ".tgz", ".tar.gz", ".tar.bz2", ".tbz", ".tbz2", ".gz", ".7z", ".rar"] where lower.hasSuffix(suffix) {
            return true
        }
        return false
    }

    /// Validates an archive subpath without touching any filesystem.
    ///
    /// Subpaths name entries inside the quarantined archive, never host
    /// files, so absolute paths and `..` segments fail closed even though
    /// the detonation VM would contain them: the check keeps traversal
    /// payloads from ever reaching the VM command line as ambiguous paths.
    /// Callers pass the result as a single argv element (never interpolated
    /// into shell text) with `--` separating flags from the name.
    /// - Parameter subpath: Raw caller-supplied entry path.
    /// - Returns: Trimmed entry path.
    /// - Throws: `EmailIMAPError.bridgeFailed` when empty, overlong, absolute, escaping, or holding control bytes.
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
    ///
    /// Extension-based so manifest entries carry a useful category without
    /// sniffing entry bytes on the host; unknown suffixes stay `other`.
    /// - Parameter path: Relative entry path inside the archive.
    /// - Returns: `pdf`, `image`, `text`, `archive`, or `other`.
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
    ///
    /// Only `text/*` (including `text/csv`) and `application/json` count
    /// as previewable, and only while both the reported size and the
    /// actual bytes stay under the 256 KB preview cap. Binaries (PDF,
    /// images, archives, office docs) are never previewable even when
    /// tiny, so their bytes never enter the model context.
    /// - Parameters:
    ///   - contentType: Raw MIME type.
    ///   - sizeBytes: Reported decoded size.
    ///   - dataCount: Actual byte count.
    /// - Returns: True when an inline preview is allowed.
    public static func isPreviewable(contentType: String, sizeBytes: Int, dataCount: Int) -> Bool {
        let base = contentType.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? ""
        let isTextType = base.hasPrefix("text/") || base == "application/json" || base == "text/csv"
        guard isTextType else { return false }
        return sizeBytes <= maxPreviewBytes && dataCount <= maxPreviewBytes
    }

    /// Builds the inline preview for an eligible payload.
    ///
    /// Decodes strictly as UTF-8 (returning nil when the bytes are not
    /// valid text) and truncates to the first 2000 chars. The truncation
    /// flag distinguishes a full inline body from a cut one so callers
    /// know when `files.read` holds more.
    /// - Parameter data: Decoded attachment bytes (already known previewable and under cap).
    /// - Returns: Preview text plus whether it was truncated, or nil when the bytes are not UTF-8 text.
    public static func inlinePreview(for data: Data) -> (text: String, truncated: Bool)? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        if text.count > maxPreviewChars {
            return (String(text.prefix(maxPreviewChars)), true)
        }
        return (text, false)
    }

    /// Returns the staged-file expiry for a retention window.
    ///
    /// Adds whole days (86400 s each) to `now` so expiry math stays a
    /// pure function of the configured window, keeping tests deterministic
    /// without touching the clock. Non-positive windows fall back to the
    /// shared staging default instead of expiring immediately.
    /// - Parameters:
    ///   - now: Reference date (defaults to now).
    ///   - retentionDays: Configured retention window in days.
    /// - Returns: Expiry date.
    public static func expiryDate(from now: Date = Date(), retentionDays: Int) -> Date {
        let days = retentionDays > 0 ? retentionDays : SandboxConfig.defaultRetentionDays
        return now.addingTimeInterval(TimeInterval(days * 86400))
    }

    /// Formats an expiry date as ISO-8601 for the envelope.
    /// - Parameter date: Expiry date.
    /// - Returns: ISO-8601 string (internet date-time, no fractional seconds).
    public static func expiryString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    /// Builds the human follow-up hint for an attachment outcome.
    /// - Parameters:
    ///   - path: Staged sandbox path, if any.
    ///   - expiresAt: ISO-8601 expiry string, if any.
    ///   - mimeCategory: Coarse bucket from `mimeCategory(for:)`.
    ///   - previewTruncated: Whether the inline preview was cut (nil when no preview).
    ///   - archiveSessionId: Session identifier for the ephemeral archive detonation microVM.
    /// - Returns: Human hint for model next steps.
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

/// Pure JSON parsing for the IMAP bridge payloads.
///
/// These helpers decode exactly what the `python3 imaplib` subprocess
/// prints on stdout, so fixture tests can cover the wire format
/// without a live mailbox. They never touch the network and never see
/// credentials.
public enum EmailBridgeParsing {
    /// Bridge `search` response shape.
    struct SearchResponse: Decodable {
        /// Whether the operation succeeded.
        let ok: Bool
        /// Error detail when `ok` is false.
        let error: String?
        /// Hits when `ok` is true.
        let messages: [EmailSearchHit]?
    }

    /// Bridge `fetch` response shape.
    struct FetchResponse: Decodable {
        /// Whether the operation succeeded.
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
        /// Whether the operation succeeded.
        let ok: Bool
        /// Error detail when `ok` is false.
        let error: String?
        /// Attachment payload when `ok` is true.
        let attachment: BridgeAttachmentPayload?
    }

    /// Bridge `list` response shape.
    struct ListResponse: Decodable {
        /// Whether the operation succeeded.
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
    ///
    /// Encodes the full post-download lifecycle (`path`, `expiresAt`,
    /// `mimeCategory`, `nextSteps`, plus the guarded inline `preview`)
    /// alongside the legacy metadata. Skipped envelopes omit the
    /// lifecycle keys so oversized and dry-run outcomes keep the legacy
    /// wire shape, while legacy payloads without lifecycle keys still
    /// decode with those fields as nil.
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

    /// Bridge `append` response shape.
    struct AppendResponse: Decodable {
        /// Whether the operation succeeded.
        let ok: Bool
        /// Error detail when `ok` is false.
        let error: String?
    }

    /// Decodes a bridge `append` stdout payload.
    ///
    /// Best-effort Sent copies surface failures as `bridgeFailed` so the
    /// send tool can warn without failing the send.
    /// - Parameter data: Raw stdout bytes from the bridge.
    /// - Throws: Decoding errors or bridge-reported failures.
    public static func parseAppendPayload(_ data: Data) throws {
        let response = try JSONDecoder().decode(AppendResponse.self, from: data)
        if !response.ok {
            throw EmailIMAPError.bridgeFailed(response.error ?? "IMAP append failed")
        }
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
    /// Parses an RFC 2822 or ISO-8601 `Date` header.
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
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }
        let isoFormatter = ISO8601DateFormatter()
        return isoFormatter.date(from: trimmed)
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

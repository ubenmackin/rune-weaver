import Foundation

/// Search arguments for the `email.search` tool.
///
/// Decodes the raw `ToolInput.argumentsJSON` document. `limit` is
/// optional and clamped to `1...50` (defaulting to `10`) so the IMAP
/// bridge never fetches an unbounded mailbox slice. An empty,
/// whitespace-only, or lone `"*"` query lists the most-recent messages
/// via `SEARCH ALL` (newest first) instead of a literal text match.
public struct EmailSearchArgs: Sendable, Equatable, Decodable {
    /// Account nickname matching an `EmailAccount.name` entry.
    public let account: String
    /// Free-text query matched against subject, sender, and body (`"*"`/empty means most-recent via `ALL`).
    public let query: String
    /// Maximum hits to return, clamped to `1...50`.
    public let limit: Int

    /// Default hit count when the caller omits `limit`.
    public static let defaultLimit = 10
    /// Upper bound for `limit` so searches stay bounded.
    public static let maxLimit = 50

    /// Memberwise initializer with limit clamping.
    /// - Parameters:
    ///   - account: Account nickname.
    ///   - query: Free-text query.
    ///   - limit: Maximum hits. Clamped to `1...50`.
    public init(account: String, query: String, limit: Int = defaultLimit) {
        self.account = account
        self.query = query
        self.limit = min(max(limit, 1), Self.maxLimit)
    }

    private enum CodingKeys: String, CodingKey {
        case account
        case query
        case limit
    }

    /// Decodes arguments, trimming whitespace and clamping `limit`.
    /// - Parameter decoder: Decoder for the arguments document.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let account = try container.decode(String.self, forKey: .account)
        let query = try container.decode(String.self, forKey: .query)
        let rawLimit = try container.decodeIfPresent(Int.self, forKey: .limit) ?? Self.defaultLimit
        self.init(account: account, query: query, limit: rawLimit)
    }

    /// Trimmed account nickname.
    public var trimmedAccount: String {
        account.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Trimmed query text.
    public var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Read arguments for the `email.read` tool.
///
/// Accepts the message identifier under `id` (canonical) plus the
/// `messageId`, `message_id`, and `uid` aliases so model-generated
/// calls keep working when the field name drifts.
public struct EmailReadArgs: Sendable, Equatable, Decodable {
    /// Account nickname matching an `EmailAccount.name` entry.
    public let account: String
    /// IMAP UID (falling back to sequence number) of the message.
    public let messageID: String

    /// Memberwise initializer.
    /// - Parameters:
    ///   - account: Account nickname.
    ///   - messageID: IMAP UID of the message.
    public init(account: String, messageID: String) {
        self.account = account
        self.messageID = messageID
    }

    private enum CodingKeys: String, CodingKey {
        case account
        case id
        case messageId
        case messageID = "message_id"
        case uid
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
    }

    /// Trimmed account nickname.
    public var trimmedAccount: String {
        account.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Trimmed message identifier.
    public var trimmedMessageID: String {
        messageID.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// One `email.search` hit: headers plus a short text snippet.
///
/// The snippet is the leading plain-text body collapsed to a single
/// line (at most 200 characters). It never contains attachment bytes.
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

    /// Creates a search hit.
    /// - Parameters:
    ///   - id: IMAP UID of the message.
    ///   - subject: Decoded subject.
    ///   - from: Decoded sender.
    ///   - date: Raw date header.
    ///   - snippet: Leading body text.
    public init(id: String, subject: String, from: String, date: String, snippet: String) {
        self.id = id
        self.subject = subject
        self.from = from
        self.date = date
        self.snippet = snippet
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
public struct EmailSearchEnvelope: Sendable, Equatable, Codable {
    /// Account nickname that was searched.
    public let account: String
    /// Query that was run.
    public let query: String
    /// Number of hits in `messages`.
    public let count: Int
    /// Hits, newest first.
    public let messages: [EmailSearchHit]

    /// Creates a search envelope.
    /// - Parameters:
    ///   - account: Account nickname.
    ///   - query: Query that was run.
    ///   - messages: Hits, newest first.
    public init(account: String, query: String, messages: [EmailSearchHit]) {
        self.account = account
        self.query = query
        self.messages = messages
        self.count = messages.count
    }
}

/// Envelope wrapping `email.read` tool output.
///
/// Encoded as the `ToolOutput.content` JSON document so the model
/// receives headers, the text body, and the attachment listing note
/// together.
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

    /// Creates a read envelope from a decoded message.
    /// - Parameters:
    ///   - account: Account nickname.
    ///   - message: Decoded message.
    public init(account: String, message: EmailFullMessage) {
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
    }
}

/// Arguments for the `email.attachment` tool.
///
/// Accepts the message identifier under `id` (canonical) plus the
/// `messageId`, `message_id`, and `uid` aliases so model-generated
/// calls keep working when the field name drifts. Accepts the part
/// position under `index` (canonical) plus `attachmentIndex` and
/// `attachment_index` so callers can name the field either way. The
/// index is zero-based into the `email.read` attachment list.
public struct EmailAttachmentArgs: Sendable, Equatable, Decodable {
    /// Account nickname matching an `EmailAccount.name` entry.
    public let account: String
    /// IMAP UID (falling back to sequence number) of the message.
    public let messageID: String
    /// Zero-based position in the `email.read` attachment list.
    public let attachmentIndex: Int

    /// Memberwise initializer.
    /// - Parameters:
    ///   - account: Account nickname.
    ///   - messageID: IMAP UID of the message.
    ///   - attachmentIndex: Zero-based attachment position.
    public init(account: String, messageID: String, attachmentIndex: Int) {
        self.account = account
        self.messageID = messageID
        self.attachmentIndex = attachmentIndex
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
    }

    /// Trimmed account nickname.
    public var trimmedAccount: String {
        account.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Trimmed message identifier.
    public var trimmedMessageID: String {
        messageID.trimmingCharacters(in: .whitespacesAndNewlines)
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
/// outcomes without writing outside the staging area.
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
    public init(
        account: String,
        id: String,
        index: Int,
        filename: String,
        contentType: String,
        sizeBytes: Int,
        path: String? = nil,
        skipped: Bool = false,
        note: String? = nil
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
    /// - Returns: JSON document for `ToolOutput.content`.
    /// - Throws: Encoding errors.
    public static func encodeSearchEnvelope(account: String, query: String, messages: [EmailSearchHit]) throws -> String {
        let envelope = EmailSearchEnvelope(account: account, query: query, messages: messages)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(envelope)
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    /// Encodes a message as the `email.read` tool output document.
    /// - Parameters:
    ///   - account: Account nickname.
    ///   - message: Decoded message.
    /// - Returns: JSON document for `ToolOutput.content`.
    /// - Throws: Encoding errors.
    public static func encodeReadEnvelope(account: String, message: EmailFullMessage) throws -> String {
        let envelope = EmailReadEnvelope(account: account, message: message)
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
}

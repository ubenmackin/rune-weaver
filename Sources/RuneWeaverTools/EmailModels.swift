import Foundation

/// Search arguments for the `email.search` tool.
///
/// Decodes the raw `ToolInput.argumentsJSON` document. `limit` is
/// optional and clamped to `1...50` (defaulting to `10`) so the IMAP
/// bridge never fetches an unbounded mailbox slice.
public struct EmailSearchArgs: Sendable, Equatable, Decodable {
    /// Account nickname matching an `EmailAccount.name` entry.
    public let account: String
    /// Free-text query matched against subject, sender, and body.
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

/// Attachment placeholder for `email.read`.
///
/// Phase one never downloads attachment bytes. Each skipped part is
/// listed here by filename and MIME type so the model can name what
/// was deferred.
public struct EmailAttachmentInfo: Sendable, Equatable, Codable {
    /// Original filename (or `unnamed-attachment` when absent).
    public let filename: String
    /// MIME type (e.g. `application/pdf`).
    public let contentType: String

    /// Creates an attachment placeholder.
    /// - Parameters:
    ///   - filename: Original filename.
    ///   - contentType: MIME type.
    public init(filename: String, contentType: String) {
        self.filename = filename
        self.contentType = contentType
    }
}

/// Full message returned by `email.read`.
///
/// `body` holds decoded plain text (HTML is stripped to text when no
/// plain part exists). Attachment bytes are never included; skipped
/// parts appear in `attachments` with `attachmentsDeferred` set and a
/// human-readable `attachmentsNote`.
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
    /// Skipped attachment parts (empty when none).
    public let attachments: [EmailAttachmentInfo]
    /// Whether attachments were skipped (true when `attachments` is non-empty).
    public let attachmentsDeferred: Bool
    /// Human-readable deferral note (nil when no attachments were skipped).
    public let attachmentsNote: String?

    /// Creates a full message.
    /// - Parameters:
    ///   - id: IMAP UID.
    ///   - subject: Decoded subject.
    ///   - from: Decoded sender.
    ///   - to: Decoded recipients.
    ///   - date: Raw date header.
    ///   - body: Decoded plain-text body.
    ///   - attachments: Skipped attachment parts.
    ///   - attachmentsDeferred: Whether attachments were skipped.
    ///   - attachmentsNote: Human-readable deferral note.
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

    /// Builds the phase-two deferral note for skipped attachments.
    /// - Parameter count: Number of skipped parts.
    /// - Returns: Human-readable note.
    public static func deferredNote(count: Int) -> String {
        if count == 1 {
            return "1 attachment skipped; attachment download is deferred to phase two."
        }
        return "\(count) attachments skipped; attachment download is deferred to phase two."
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
/// receives headers, the text body, and the attachment deferral note
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
    /// Skipped attachment parts.
    public let attachments: [EmailAttachmentInfo]
    /// Whether attachments were skipped.
    public let attachmentsDeferred: Bool
    /// Human-readable deferral note (nil when nothing was skipped).
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
}

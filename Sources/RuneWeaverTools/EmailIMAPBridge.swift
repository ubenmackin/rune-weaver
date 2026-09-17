// Rune Weaver Tools — IMAP mailbox access and validation over a subprocess bridge.

import Foundation
import RuneWeaverCore

/// Failures talking to an IMAP mailbox through the bridge.
public enum EmailIMAPError: Error, Sendable, Equatable {
    /// The named account is not in `EmailConfig`.
    case unknownAccount(name: String, available: [String])
    /// The bridge subprocess reported a failure.
    case bridgeFailed(String)
    /// The bridge output could not be decoded.
    case decodeFailed(String)
    /// `python3` could not be launched.
    case pythonUnavailable(String)
}

extension EmailIMAPError: LocalizedError {
    /// Human-readable message without any secret value.
    public var errorDescription: String? {
        switch self {
        case let .unknownAccount(name, available):
            if available.isEmpty {
                return "Unknown email account '\(name)' (no accounts configured in [email.accounts])"
            }
            return "Unknown email account '\(name)' (available: \(available.sorted().joined(separator: ", ")))"
        case let .bridgeFailed(detail):
            return detail
        case let .decodeFailed(detail):
            return "Could not decode IMAP response: \(detail)"
        case let .pythonUnavailable(detail):
            return detail
        }
    }
}

/// Fail-closed validation for IMAP bridge inputs.
public enum EmailIMAPValidation: Sendable {
    /// Validates a search query, rejecting CR/LF injection.
    /// - Parameter query: Free-text query to check.
    /// - Throws: `EmailIMAPError.bridgeFailed` when CR/LF is present.
    public static func validateSearchQuery(_ query: String) throws {
        if query.unicodeScalars.contains(where: { $0.value == 13 || $0.value == 10 }) {
            throw EmailIMAPError.bridgeFailed("Invalid search query: query must not contain CR or LF")
        }
    }

    /// Whether a search query requests every message (most-recent listing).
    public static func isAllQuery(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "*"
    }

    /// Whether raw tool arguments contain an unescaped JSON escape for CR/LF.
    public static func containsEncodedCRLF(in rawJSON: String) -> Bool {
        let chars = Array(rawJSON)
        var index = 0
        while index < chars.count {
            guard chars[index] == "\\" else {
                index += 1
                continue
            }
            var runEnd = index
            while runEnd < chars.count, chars[runEnd] == "\\" {
                runEnd += 1
            }
            let runLength = runEnd - index
            if runLength % 2 == 1, runEnd < chars.count {
                let next = chars[runEnd]
                if next == "r" || next == "n" {
                    return true
                }
                if next == "u" || next == "U" {
                    if runEnd + 4 < chars.count {
                        let hex = String(chars[(runEnd + 1) ... (runEnd + 4)]).lowercased()
                        if hex == "000d" || hex == "000a" {
                            return true
                        }
                    }
                }
            }
            index = runEnd
        }
        return false
    }

    /// Whether a message id matches strict UID syntax.
    /// - Parameter messageID: Trimmed candidate id.
    /// - Returns: True when it matches `^[0-9][0-9:,]*$`.
    public static func isValidMessageID(_ messageID: String) -> Bool {
        guard !messageID.isEmpty else { return false }
        guard let first = messageID.unicodeScalars.first,
              first.value >= 48, first.value <= 57
        else { return false }
        for scalar in messageID.unicodeScalars {
            let value = scalar.value
            let isDigit = value >= 48 && value <= 57
            let isComma = value == 44
            let isColon = value == 58
            if !isDigit, !isComma, !isColon {
                return false
            }
        }
        return true
    }

    /// Validates a message id against strict UID syntax.
    /// - Parameter messageID: Candidate id (trimmed before checking).
    /// - Throws: `EmailIMAPError.bridgeFailed` when the id is not UID syntax.
    public static func validateMessageID(_ messageID: String) throws {
        let trimmed = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidMessageID(trimmed) else {
            throw EmailIMAPError.bridgeFailed("Invalid message id")
        }
    }

    /// Validates an attachment index, rejecting negative positions.
    /// - Parameter index: Zero-based position into the attachment list.
    /// - Throws: `EmailIMAPError.bridgeFailed` when the index is negative.
    public static func validateAttachmentIndex(_ index: Int) throws {
        guard index >= 0 else {
            throw EmailIMAPError.bridgeFailed("Invalid attachment index")
        }
    }

    /// Validates a mailbox name, rejecting CR/LF injection and blank names.
    /// - Parameter mailbox: Trimmed candidate mailbox name.
    /// - Throws: `EmailIMAPError.bridgeFailed` when the name is empty or holds CR/LF.
    public static func validateMailbox(_ mailbox: String) throws {
        if mailbox.unicodeScalars.contains(where: { $0.value == 13 || $0.value == 10 }) {
            throw EmailIMAPError.bridgeFailed("Invalid mailbox: mailbox must not contain CR or LF")
        }
        let trimmed = mailbox.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw EmailIMAPError.bridgeFailed("Invalid mailbox: mailbox must not be empty")
        }
    }
}

/// IMAP gateway used by the email tools.
public protocol EmailIMAPGateway: Sendable {
    /// Lists selectable mailboxes with the shared hierarchy delimiter.
    /// - Parameter credentials: Resolved connection fields plus password.
    /// - Returns: Selectable mailbox names in server order plus the common delimiter.
    func mailboxListing(credentials: ResolvedEmailCredentials) async throws -> EmailMailboxListing

    /// Compatibility shim over `mailboxListing` for existing callers.
    /// - Parameter credentials: Resolved connection fields plus password.
    /// - Returns: Selectable mailbox names in server order.
    func listMailboxes(credentials: ResolvedEmailCredentials) async throws -> [String]

    /// Searches one mailbox for `query`.
    func search(credentials: ResolvedEmailCredentials, mailbox: String, query: String, limit: Int) async throws -> [EmailSearchHit]

    /// Fetches one message from one mailbox.
    func fetch(credentials: ResolvedEmailCredentials, mailbox: String, messageID: String) async throws -> EmailFullMessage

    /// Fetches one attachment part from one mailbox.
    func attachment(
        credentials: ResolvedEmailCredentials,
        mailbox: String,
        messageID: String,
        attachmentIndex: Int
    ) async throws -> EmailAttachmentData

    /// Appends one RFC822 message to a mailbox with `\Seen`.
    func append(credentials: ResolvedEmailCredentials, mailbox: String, rawMessage: Data) async throws

    /// Moves one message to another mailbox, optionally marking it read.
    /// - Parameters:
    ///   - credentials: Resolved connection fields plus password.
    ///   - mailbox: Source mailbox holding the message.
    ///   - messageID: UID of the message to move.
    ///   - destination: Destination mailbox.
    ///   - markAsRead: Whether to set `\Seen` on the moved message.
    /// - Returns: Source, destination, and whether the move and flag update applied.
    func move(
        credentials: ResolvedEmailCredentials,
        mailbox: String,
        messageID: String,
        destination: String,
        markAsRead: Bool
    ) async throws -> EmailMoveResult
}

public extension EmailIMAPGateway {
    /// Default compatibility shim over the single required `mailboxListing`.
    /// `mailboxListing` is the only required listing method so conformers cannot
    /// satisfy the protocol with neither method and recurse between defaults.
    func listMailboxes(credentials: ResolvedEmailCredentials) async throws -> [String] {
        try await mailboxListing(credentials: credentials).mailboxes
    }

    /// Default move that fails closed for gateways without move support.
    func move(
        credentials _: ResolvedEmailCredentials,
        mailbox _: String,
        messageID _: String,
        destination _: String,
        markAsRead _: Bool
    ) async throws -> EmailMoveResult {
        throw EmailIMAPError.bridgeFailed("IMAP move not supported")
    }
}

/// Resolves the best-effort Sent mailbox from a `LIST` result.
public enum EmailSentMailbox: Sendable {
    /// Ordered Sent candidates tried against `LIST`.
    public static let candidates = ["Sent", "Sent Items", "Sent Messages"]

    /// Resolves the Sent mailbox from selectable folders.
    /// - Parameter available: Selectable mailboxes in server order.
    /// - Returns: Canonical Sent name, or nil when none matches.
    public static func resolve(among available: [String]) -> String? {
        for candidate in candidates where available.contains(candidate) {
            return candidate
        }
        for candidate in candidates {
            if let match = available.first(where: { $0.lowercased() == candidate.lowercased() }) {
                return match
            }
        }
        return nil
    }
}

/// Result of moving one message between mailboxes.
public struct EmailMoveResult: Sendable, Equatable, Codable {
    /// Source mailbox the message was moved from.
    public let mailbox: String
    /// Destination mailbox the message was moved to.
    public let destination: String
    /// Whether the message was relocated (false for same-folder flag-only updates).
    public let moved: Bool
    /// Whether `\Seen` is set on the resulting message.
    public let markedAsRead: Bool

    /// Creates a move result.
    public init(mailbox: String, destination: String, moved: Bool, markedAsRead: Bool) {
        self.mailbox = mailbox
        self.destination = destination
        self.moved = moved
        self.markedAsRead = markedAsRead
    }

    private enum CodingKeys: String, CodingKey {
        case mailbox
        case destination
        case moved
        case markedAsRead
        case markedAsReadSnake = "marked_as_read"
        case markAsRead
    }

    /// Decodes a move result, accepting `markedAsRead` and snake-case aliases.
    /// All fields are required so malformed bridge payloads fail closed instead
    /// of reporting a silent no-op success.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let decodedMailbox = try container.decodeIfPresent(String.self, forKey: .mailbox),
              !decodedMailbox.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw EmailIMAPError.decodeFailed("IMAP bridge returned no mailbox")
        }
        mailbox = decodedMailbox
        guard let decodedDestination = try container.decodeIfPresent(String.self, forKey: .destination),
              !decodedDestination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw EmailIMAPError.decodeFailed("IMAP bridge returned no destination")
        }
        destination = decodedDestination
        guard let decodedMoved = try container.decodeIfPresent(Bool.self, forKey: .moved) else {
            throw EmailIMAPError.decodeFailed("IMAP bridge returned no moved flag")
        }
        moved = decodedMoved
        if let marked = try container.decodeIfPresent(Bool.self, forKey: .markedAsRead) {
            markedAsRead = marked
        } else if let snake = try container.decodeIfPresent(Bool.self, forKey: .markedAsReadSnake) {
            markedAsRead = snake
        } else if let echoed = try container.decodeIfPresent(Bool.self, forKey: .markAsRead) {
            markedAsRead = echoed
        } else {
            throw EmailIMAPError.decodeFailed("IMAP bridge returned no markedAsRead flag")
        }
    }

    /// Encodes the move result with the canonical `markedAsRead` key.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mailbox, forKey: .mailbox)
        try container.encode(destination, forKey: .destination)
        try container.encode(moved, forKey: .moved)
        try container.encode(markedAsRead, forKey: .markedAsRead)
    }
}

/// Bridge request document sent to the Python helper over stdin.
struct EmailIMAPBridgeRequest: Encodable {
    /// Operation: `"search"`, `"fetch"`, `"attachment"`, `"list"`, `"append"`, or `"move"`.
    let op: String
    /// IMAP hostname.
    let host: String
    /// IMAP port.
    let port: Int
    /// Login username.
    let username: String
    /// Runtime-resolved password. Never logged.
    let password: String
    /// Mailbox to open (`INBOX` by default; ignored for `list`).
    let mailbox: String
    /// Free-text query (search only).
    let query: String?
    /// Maximum hits (search only).
    let limit: Int?
    /// Message UID (fetch, attachment, and move only).
    let messageID: String?
    /// Zero-based attachment position (attachment only).
    let attachmentIndex: Int?
    /// Base64 RFC822 bytes for `append` only.
    let rawMessageBase64: String?
    /// Destination mailbox for `move` only.
    let destination: String?
    /// Whether `move` should set `\Seen` on the resulting message.
    let markAsRead: Bool?

    /// Creates a search request.
    static func search(credentials: ResolvedEmailCredentials, query: String, limit: Int, mailbox: String = "INBOX") -> Self {
        Self(
            op: "search",
            host: credentials.host,
            port: credentials.port,
            username: credentials.username,
            password: credentials.password,
            mailbox: mailbox,
            query: query,
            limit: limit,
            messageID: nil,
            attachmentIndex: nil,
            rawMessageBase64: nil,
            destination: nil,
            markAsRead: nil
        )
    }

    /// Creates a fetch request.
    static func fetch(credentials: ResolvedEmailCredentials, messageID: String, mailbox: String = "INBOX") -> Self {
        Self(
            op: "fetch",
            host: credentials.host,
            port: credentials.port,
            username: credentials.username,
            password: credentials.password,
            mailbox: mailbox,
            query: nil,
            limit: nil,
            messageID: messageID,
            attachmentIndex: nil,
            rawMessageBase64: nil,
            destination: nil,
            markAsRead: nil
        )
    }

    /// Creates an attachment request.
    static func attachment(
        credentials: ResolvedEmailCredentials,
        messageID: String,
        attachmentIndex: Int,
        mailbox: String = "INBOX"
    ) -> Self {
        Self(
            op: "attachment",
            host: credentials.host,
            port: credentials.port,
            username: credentials.username,
            password: credentials.password,
            mailbox: mailbox,
            query: nil,
            limit: nil,
            messageID: messageID,
            attachmentIndex: attachmentIndex,
            rawMessageBase64: nil,
            destination: nil,
            markAsRead: nil
        )
    }

    /// Creates a mailbox-listing request.
    /// - Parameter credentials: Resolved connection fields plus password.
    /// - Returns: `list` request reporting selectable mailboxes plus the common delimiter.
    static func listing(credentials: ResolvedEmailCredentials) -> Self {
        Self(
            op: "list",
            host: credentials.host,
            port: credentials.port,
            username: credentials.username,
            password: credentials.password,
            mailbox: "INBOX",
            query: nil,
            limit: nil,
            messageID: nil,
            attachmentIndex: nil,
            rawMessageBase64: nil,
            destination: nil,
            markAsRead: nil
        )
    }

    /// Compatibility shim over `listing` for existing callers.
    /// - Parameter credentials: Resolved connection fields plus password.
    /// - Returns: `list` request reporting selectable mailboxes plus the common delimiter.
    static func list(credentials: ResolvedEmailCredentials) -> Self {
        listing(credentials: credentials)
    }

    /// Creates a move request relocating one message between mailboxes.
    static func move(
        credentials: ResolvedEmailCredentials,
        mailbox: String,
        messageID: String,
        destination: String,
        markAsRead: Bool
    ) -> Self {
        Self(
            op: "move",
            host: credentials.host,
            port: credentials.port,
            username: credentials.username,
            password: credentials.password,
            mailbox: mailbox,
            query: nil,
            limit: nil,
            messageID: messageID,
            attachmentIndex: nil,
            rawMessageBase64: nil,
            destination: destination,
            markAsRead: markAsRead
        )
    }

    /// Creates a Sent-append request for a best-effort Sent copy.
    static func append(credentials: ResolvedEmailCredentials, mailbox: String, rawMessage: Data) -> Self {
        Self(
            op: "append",
            host: credentials.host,
            port: credentials.port,
            username: credentials.username,
            password: credentials.password,
            mailbox: mailbox,
            query: nil,
            limit: nil,
            messageID: nil,
            attachmentIndex: nil,
            rawMessageBase64: rawMessage.base64EncodedString(),
            destination: nil,
            markAsRead: nil
        )
    }
}

/// Subprocess gateway shelling out to `python3 imaplib`.
public struct SubprocessIMAPGateway: EmailIMAPGateway, Sendable {
    /// Environment variable overriding the Python executable.
    public static let pythonEnvVar = "RUNEWEAVER_PYTHON_BIN"

    /// Explicit Python executable path, if any.
    public let pythonExecutable: String?

    /// Creates a subprocess gateway.
    public init(pythonExecutable: String? = nil) {
        if let pythonExecutable, !pythonExecutable.isEmpty {
            self.pythonExecutable = pythonExecutable
        } else if let configured = ProcessInfo.processInfo.environment[Self.pythonEnvVar] {
            if configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.pythonExecutable = nil
            } else {
                self.pythonExecutable = configured
            }
        } else {
            self.pythonExecutable = nil
        }
    }

    /// Searches one mailbox via the Python helper.
    public func search(credentials: ResolvedEmailCredentials, mailbox: String, query: String, limit: Int) async throws -> [EmailSearchHit] {
        try EmailIMAPValidation.validateSearchQuery(query)
        try EmailIMAPValidation.validateMailbox(mailbox)
        let effectiveQuery = EmailIMAPValidation.isAllQuery(query) ? "" : query.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMailbox = mailbox.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = EmailIMAPBridgeRequest.search(credentials: credentials, query: effectiveQuery, limit: limit, mailbox: trimmedMailbox)
        let data = try await run(request: request)
        do {
            let hits = try EmailBridgeParsing.parseSearchPayload(data)
            return hits.map {
                EmailSearchHit(
                    id: $0.id,
                    subject: $0.subject,
                    from: $0.from,
                    date: $0.date,
                    snippet: $0.snippet,
                    mailbox: trimmedMailbox
                )
            }
        } catch let error as EmailIMAPError {
            throw error
        } catch {
            throw EmailIMAPError.decodeFailed(error.localizedDescription)
        }
    }

    /// Lists selectable mailboxes plus the common hierarchy delimiter.
    /// - Parameter credentials: Resolved connection fields plus password.
    /// - Returns: Selectable mailbox names in server order with the shared delimiter.
    public func mailboxListing(credentials: ResolvedEmailCredentials) async throws -> EmailMailboxListing {
        let request = EmailIMAPBridgeRequest.listing(credentials: credentials)
        let data = try await run(request: request)
        do {
            return try EmailBridgeParsing.parseMailboxListingPayload(data)
        } catch let error as EmailIMAPError {
            throw error
        } catch {
            throw EmailIMAPError.decodeFailed(error.localizedDescription)
        }
    }

    /// Compatibility shim over `mailboxListing` for existing callers.
    /// - Parameter credentials: Resolved connection fields plus password.
    /// - Returns: Selectable mailbox names in server order.
    public func listMailboxes(credentials: ResolvedEmailCredentials) async throws -> [String] {
        try await mailboxListing(credentials: credentials).mailboxes
    }

    /// Fetches one message from one mailbox via the Python helper.
    public func fetch(credentials: ResolvedEmailCredentials, mailbox: String, messageID: String) async throws -> EmailFullMessage {
        try EmailIMAPValidation.validateMessageID(messageID)
        try EmailIMAPValidation.validateMailbox(mailbox)
        let trimmedMailbox = mailbox.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = EmailIMAPBridgeRequest.fetch(credentials: credentials, messageID: messageID, mailbox: trimmedMailbox)
        let data = try await run(request: request)
        do {
            return try EmailBridgeParsing.parseFetchPayload(data)
        } catch let error as EmailIMAPError {
            throw error
        } catch {
            throw EmailIMAPError.decodeFailed(error.localizedDescription)
        }
    }

    /// Fetches one attachment part from one mailbox via the Python helper.
    public func attachment(
        credentials: ResolvedEmailCredentials,
        mailbox: String,
        messageID: String,
        attachmentIndex: Int
    ) async throws -> EmailAttachmentData {
        try EmailIMAPValidation.validateMessageID(messageID)
        try EmailIMAPValidation.validateAttachmentIndex(attachmentIndex)
        try EmailIMAPValidation.validateMailbox(mailbox)
        let trimmedMailbox = mailbox.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = EmailIMAPBridgeRequest.attachment(
            credentials: credentials,
            messageID: messageID,
            attachmentIndex: attachmentIndex,
            mailbox: trimmedMailbox
        )
        let data = try await run(request: request)
        do {
            return try EmailBridgeParsing.parseAttachmentPayload(data)
        } catch let error as EmailIMAPError {
            throw error
        } catch {
            throw EmailIMAPError.decodeFailed(error.localizedDescription)
        }
    }

    /// Appends one RFC822 message to a mailbox with `\Seen`.
    public func append(credentials: ResolvedEmailCredentials, mailbox: String, rawMessage: Data) async throws {
        try EmailIMAPValidation.validateMailbox(mailbox)
        guard !rawMessage.isEmpty else {
            throw EmailIMAPError.bridgeFailed("Invalid append message: message must not be empty")
        }
        let trimmedMailbox = mailbox.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = EmailIMAPBridgeRequest.append(credentials: credentials, mailbox: trimmedMailbox, rawMessage: rawMessage)
        let data = try await run(request: request)
        do {
            try EmailBridgeParsing.parseAppendPayload(data)
        } catch let error as EmailIMAPError {
            throw error
        } catch {
            throw EmailIMAPError.decodeFailed(error.localizedDescription)
        }
    }

    /// Moves one message between mailboxes, optionally marking it read.
    public func move(
        credentials: ResolvedEmailCredentials,
        mailbox: String,
        messageID: String,
        destination: String,
        markAsRead: Bool
    ) async throws -> EmailMoveResult {
        try EmailIMAPValidation.validateMessageID(messageID)
        try EmailIMAPValidation.validateMailbox(mailbox)
        try EmailIMAPValidation.validateMailbox(destination)
        let trimmedMailbox = mailbox.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDestination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        try EmailIMAPValidation.validateMessageID(trimmedMessageID)
        try EmailIMAPValidation.validateMailbox(trimmedMailbox)
        try EmailIMAPValidation.validateMailbox(trimmedDestination)
        guard !trimmedDestination.isEmpty else {
            throw EmailIMAPError.bridgeFailed("Invalid destination: destination must not be empty")
        }
        let request = EmailIMAPBridgeRequest.move(
            credentials: credentials,
            mailbox: trimmedMailbox,
            messageID: trimmedMessageID,
            destination: trimmedDestination,
            markAsRead: markAsRead
        )
        let data = try await run(request: request)
        do {
            return try EmailBridgeParsing.parseMoveResultPayload(data)
        } catch let error as EmailIMAPError {
            throw error
        } catch {
            throw EmailIMAPError.decodeFailed(error.localizedDescription)
        }
    }

    /// Runs the helper once with the given request.
    func run(request: EmailIMAPBridgeRequest) async throws -> Data {
        let payload: Data
        do {
            payload = try JSONEncoder().encode(request)
        } catch {
            throw EmailIMAPError.bridgeFailed("Could not encode IMAP request: \(error.localizedDescription)")
        }
        return try await EmailSubprocessIO.runBridgeIO(
            scriptSource: EmailIMAPBridgeScript.source,
            payload: payload,
            pythonExecutable: pythonExecutable,
            serviceName: "IMAP"
        )
    }
}

/// Bridge `move` response shape for the gateway minimal result.
private struct MoveResultResponse: Decodable {
    /// Whether the operation succeeded.
    let ok: Bool
    /// Error detail when `ok` is false.
    let error: String?
    /// Source mailbox.
    let mailbox: String?
    /// Destination mailbox.
    let destination: String?
    /// Whether the message was relocated.
    let moved: Bool?
    /// Whether `\Seen` is set on the resulting message.
    let markedAsRead: Bool?
    /// Snake-case alias for `markedAsRead`.
    let markedAsReadSnake: Bool?
    /// Request-echo alias for `markedAsRead`.
    let markAsRead: Bool?

    private enum CodingKeys: String, CodingKey {
        case ok
        case error
        case mailbox
        case destination
        case moved
        case markedAsRead
        case markedAsReadSnake = "marked_as_read"
        case markAsRead
    }
}

public extension EmailBridgeParsing {
    /// Decodes a bridge `move` stdout payload into the gateway minimal result.
    /// Requires `mailbox`, `destination`, `moved`, and a read flag so partial
    /// payloads fail closed instead of reporting a silent no-op success.
    static func parseMoveResultPayload(_ data: Data) throws -> EmailMoveResult {
        let response: MoveResultResponse
        do {
            response = try JSONDecoder().decode(MoveResultResponse.self, from: data)
        } catch {
            throw EmailIMAPError.decodeFailed(error.localizedDescription)
        }
        if !response.ok {
            throw EmailIMAPError.bridgeFailed(response.error ?? "IMAP move failed")
        }
        guard let mailbox = response.mailbox,
              !mailbox.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw EmailIMAPError.decodeFailed("IMAP bridge returned no mailbox")
        }
        guard let destination = response.destination,
              !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw EmailIMAPError.decodeFailed("IMAP bridge returned no destination")
        }
        guard let moved = response.moved else {
            throw EmailIMAPError.decodeFailed("IMAP bridge returned no moved flag")
        }
        guard let marked = response.markedAsRead ?? response.markedAsReadSnake ?? response.markAsRead else {
            throw EmailIMAPError.decodeFailed("IMAP bridge returned no markedAsRead flag")
        }
        return EmailMoveResult(
            mailbox: mailbox,
            destination: destination,
            moved: moved,
            markedAsRead: marked
        )
    }
}

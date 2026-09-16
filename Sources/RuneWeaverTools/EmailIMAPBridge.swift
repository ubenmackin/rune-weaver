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
    /// Lists selectable mailboxes via `IMAP LIST`, excluding non-selectable flags.
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

/// Bridge request document sent to the Python helper over stdin.
struct EmailIMAPBridgeRequest: Encodable {
    /// Operation: `"search"`, `"fetch"`, `"attachment"`, `"list"`, or `"append"`.
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
    /// Message UID (fetch and attachment only).
    let messageID: String?
    /// Zero-based attachment position (attachment only).
    let attachmentIndex: Int?
    /// Base64 RFC822 bytes for `append` only.
    let rawMessageBase64: String?

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
            rawMessageBase64: nil
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
            rawMessageBase64: nil
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
            rawMessageBase64: nil
        )
    }

    /// Creates a mailbox-listing request.
    /// - Parameter credentials: Resolved connection fields plus password.
    /// - Returns: `list` request reporting selectable mailboxes.
    static func list(credentials: ResolvedEmailCredentials) -> Self {
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
            rawMessageBase64: nil
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
            rawMessageBase64: rawMessage.base64EncodedString()
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

    /// Lists selectable mailboxes via the Python helper.
    /// - Parameter credentials: Resolved connection fields plus password.
    /// - Returns: Selectable mailbox names in server order.
    public func listMailboxes(credentials: ResolvedEmailCredentials) async throws -> [String] {
        let request = EmailIMAPBridgeRequest.list(credentials: credentials)
        let data = try await run(request: request)
        do {
            return try EmailBridgeParsing.parseListPayload(data)
        } catch let error as EmailIMAPError {
            throw error
        } catch {
            throw EmailIMAPError.decodeFailed(error.localizedDescription)
        }
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

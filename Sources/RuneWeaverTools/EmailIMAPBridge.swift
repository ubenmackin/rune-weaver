// Rune Weaver Tools — IMAP mailbox access and validation over a subprocess bridge.
//
// Reads and searches mailboxes through the `python3 imaplib` subprocess with
// strict payload decoding and fail-closed validation. Keeps credentials at
// execution time and secrets out of error messages so tool calls stay safe
// without touching the network directly.

import Foundation
import RuneWeaverCore

/// Failures talking to an IMAP mailbox through the bridge.
///
/// Messages echo only non-sensitive fields (account name, host, port,
/// username, mailbox, operation). Passwords and raw request documents
/// are never included.
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
///
/// Mirrors the embedded Python helper's allowlisting so Swift rejects
/// malicious input before spawning the subprocess. Search queries must
/// not contain CR/LF and message ids must match UID syntax
/// (`^[0-9][0-9:,]*$`) so crafted input cannot inject additional IMAP
/// commands. Errors never echo input values or secrets.
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
    ///
    /// A trimmed empty query, a whitespace-only query, or a lone `"*"`
    /// wildcard maps to `SEARCH ALL` so `email.search` with `"*"`,
    /// `""`, or `"   "` returns the most-recent messages instead of
    /// sending a literal `TEXT "*"` that matches nothing on iCloud
    /// (`imap.mail.me.com:993`) and some Volcrypt mailboxes. Mirrors the
    /// Python bridge check (`if not query or query == "*"`). Never logs
    /// or echoes input.
    /// - Parameter query: Raw or trimmed free-text query.
    /// - Returns: True when the query should list recent messages via `ALL`.
    public static func isAllQuery(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "*"
    }

    /// Whether raw tool arguments contain an unescaped JSON escape for CR/LF.
    ///
    /// Detects `\r`, `\n`, `\u000d`, `\u000a` (hex case-insensitive) with
    /// an odd backslash count so legitimate Windows paths (`C:\\new\\report`,
    /// double backslash decoding to literal backslash+r/n) pass while
    /// injection (`hello\r\nworld`, single backslash decoding to real
    /// CR/LF) fails. Decoded checks catch real CR/LF; this raw pre-check
    /// guarantees "Invalid search query" even when the password is missing.
    /// Never logs or echoes input.
    /// - Parameter rawJSON: Raw `ToolInput.argumentsJSON` document.
    /// - Returns: True when an unescaped CR/LF escape is present.
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
///
/// The production implementation shells out to `python3 imaplib`;
/// tests inject a stub. Search, fetch, and attachment paths stay
/// read-only: the mailbox is opened with `readonly=True` and only
/// `(BODY.PEEK[])` fetches are used so `\Seen` is never set even when
/// the server ignores the read-only open. `listMailboxes` plus the
/// `mailbox` overloads fan search out across every selectable folder;
/// the legacy `INBOX` overloads remain for single-folder callers.
/// `append` is the single write path, used best-effort for Sent copies
/// after SMTP success; it never fails a send.
public protocol EmailIMAPGateway: Sendable {
    /// Searches subject, sender, and body for `query`.
    /// - Parameters:
    ///   - credentials: Resolved connection fields plus password.
    ///   - query: Free-text query matched against subject/sender/body (`"*"`/empty means most-recent via `ALL`).
    ///   - limit: Maximum hits (already clamped to `1...50`).
    /// - Returns: Hits, newest first.
    func search(credentials: ResolvedEmailCredentials, query: String, limit: Int) async throws -> [EmailSearchHit]

    /// Fetches one message by UID (falling back to sequence number).
    /// - Parameters:
    ///   - credentials: Resolved connection fields plus password.
    ///   - messageID: IMAP UID of the message.
    /// - Returns: Headers plus text body with attachment metadata.
    func fetch(credentials: ResolvedEmailCredentials, messageID: String) async throws -> EmailFullMessage

    /// Fetches one attachment part by zero-based index.
    /// - Parameters:
    ///   - credentials: Resolved connection fields plus password.
    ///   - messageID: IMAP UID of the message.
    ///   - attachmentIndex: Zero-based position in the `fetch` attachment list.
    /// - Returns: Attachment bytes with filename, MIME type, and size.
    func attachment(
        credentials: ResolvedEmailCredentials,
        messageID: String,
        attachmentIndex: Int
    ) async throws -> EmailAttachmentData

    /// Lists selectable mailboxes via `IMAP LIST`, excluding non-selectable flags.
    /// - Parameter credentials: Resolved connection fields plus password.
    /// - Returns: Selectable mailbox names in server order.
    func listMailboxes(credentials: ResolvedEmailCredentials) async throws -> [String]

    /// Searches one mailbox for `query`.
    /// - Parameters:
    ///   - credentials: Resolved connection fields plus password.
    ///   - mailbox: Mailbox to open read-only.
    ///   - query: Free-text query (`"*"`/empty means most-recent via `ALL`).
    ///   - limit: Maximum hits (already clamped to `1...50`).
    /// - Returns: Hits newest-first labeled with `mailbox`.
    func search(credentials: ResolvedEmailCredentials, mailbox: String, query: String, limit: Int) async throws -> [EmailSearchHit]

    /// Fetches one message from one mailbox.
    /// - Parameters:
    ///   - credentials: Resolved connection fields plus password.
    ///   - mailbox: Mailbox to open read-only.
    ///   - messageID: IMAP UID of the message.
    /// - Returns: Headers plus text body with attachment metadata.
    func fetch(credentials: ResolvedEmailCredentials, mailbox: String, messageID: String) async throws -> EmailFullMessage

    /// Fetches one attachment part from one mailbox.
    /// - Parameters:
    ///   - credentials: Resolved connection fields plus password.
    ///   - mailbox: Mailbox to open read-only.
    ///   - messageID: IMAP UID of the message.
    ///   - attachmentIndex: Zero-based position in the `fetch` attachment list.
    /// - Returns: Attachment bytes with filename, MIME type, and size.
    func attachment(
        credentials: ResolvedEmailCredentials,
        mailbox: String,
        messageID: String,
        attachmentIndex: Int
    ) async throws -> EmailAttachmentData

    /// Appends one RFC822 message to a mailbox with `\Seen`.
    ///
    /// Best-effort Sent copy after SMTP success: callers warn but never
    /// fail the send when the mailbox is missing or the store rejects
    /// the bytes.
    /// - Parameters:
    ///   - credentials: Resolved connection fields plus password.
    ///   - mailbox: Destination mailbox (resolved Sent folder).
    ///   - rawMessage: Full RFC822 bytes to store.
    func append(credentials: ResolvedEmailCredentials, mailbox: String, rawMessage: Data) async throws
}

/// Backwards-compatible defaults so legacy stubs keep compiling.
///
/// Stubs that only implement the `INBOX` overloads fan out as a single
/// `INBOX` folder: `listMailboxes` reports `["INBOX"]` and the
/// `mailbox` overloads delegate when the mailbox is `INBOX`
/// (case-insensitive) and otherwise report an unknown mailbox without
/// secrets.
public extension EmailIMAPGateway {
    /// Defaults to a single `INBOX` folder for legacy stubs.
    /// - Parameter credentials: Ignored resolved credentials.
    /// - Returns: `["INBOX"]`.
    func listMailboxes(credentials _: ResolvedEmailCredentials) async throws -> [String] {
        ["INBOX"]
    }

    /// Delegates `INBOX` searches to the legacy overload.
    /// - Parameters:
    ///   - credentials: Resolved connection fields plus password.
    ///   - mailbox: Requested mailbox.
    ///   - query: Free-text query.
    ///   - limit: Maximum hits.
    /// - Returns: Hits newest-first labeled with `mailbox`.
    func search(credentials: ResolvedEmailCredentials, mailbox: String, query: String, limit: Int) async throws -> [EmailSearchHit] {
        guard mailbox.lowercased() == "inbox" else {
            throw EmailBridgeParsing.unknownMailboxError(requested: mailbox, available: ["INBOX"])
        }
        let hits = try await search(credentials: credentials, query: query, limit: limit)
        return hits.map { EmailSearchHit(id: $0.id, subject: $0.subject, from: $0.from, date: $0.date, snippet: $0.snippet, mailbox: "INBOX") }
    }

    /// Delegates `INBOX` fetches to the legacy overload.
    /// - Parameters:
    ///   - credentials: Resolved connection fields plus password.
    ///   - mailbox: Requested mailbox.
    ///   - messageID: IMAP UID of the message.
    /// - Returns: Headers plus text body.
    func fetch(credentials: ResolvedEmailCredentials, mailbox: String, messageID: String) async throws -> EmailFullMessage {
        guard mailbox.lowercased() == "inbox" else {
            throw EmailBridgeParsing.unknownMailboxError(requested: mailbox, available: ["INBOX"])
        }
        return try await fetch(credentials: credentials, messageID: messageID)
    }

    /// Delegates `INBOX` attachment fetches to the legacy overload.
    /// - Parameters:
    ///   - credentials: Resolved connection fields plus password.
    ///   - mailbox: Requested mailbox.
    ///   - messageID: IMAP UID of the message.
    ///   - attachmentIndex: Zero-based attachment position.
    /// - Returns: Attachment bytes.
    func attachment(
        credentials: ResolvedEmailCredentials,
        mailbox: String,
        messageID: String,
        attachmentIndex: Int
    ) async throws -> EmailAttachmentData {
        guard mailbox.lowercased() == "inbox" else {
            throw EmailBridgeParsing.unknownMailboxError(requested: mailbox, available: ["INBOX"])
        }
        return try await attachment(credentials: credentials, messageID: messageID, attachmentIndex: attachmentIndex)
    }

    /// Fails closed for legacy stubs without Sent-append support.
    ///
    /// Keeps older test doubles compiling while production and new stubs
    /// implement the write path; the send tool treats this as a
    /// best-effort warning, never a send failure.
    /// - Parameters:
    ///   - credentials: Ignored resolved credentials.
    ///   - mailbox: Requested destination mailbox.
    ///   - rawMessage: Ignored RFC822 bytes.
    func append(credentials _: ResolvedEmailCredentials, mailbox: String, rawMessage _: Data) async throws {
        throw EmailIMAPError.bridgeFailed("IMAP append to '\(mailbox)' is not supported by this gateway")
    }
}

/// Resolves the best-effort Sent mailbox from a `LIST` result.
///
/// Prefers `Sent`, then `Sent Items`, then `Sent Messages` with an
/// exact-first, case-insensitive fallback so provider folder spellings
/// keep working without assuming names. Returns nil when no candidate
/// matches so callers warn instead of failing the send.
/// Centralizes Sent resolution so the send tool and tests share one
/// candidate order.
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
///
/// Encoded as a single JSON object. The password travels only in this
/// in-memory document and the subprocess pipe — it is never logged
/// and never echoed in errors.
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
    /// - Parameters:
    ///   - credentials: Resolved connection fields plus password.
    ///   - query: Free-text query.
    ///   - limit: Maximum hits.
    ///   - mailbox: Mailbox to open read-only. Defaults to `INBOX`.
    /// - Returns: Search request for one mailbox.
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
    /// - Parameters:
    ///   - credentials: Resolved connection fields plus password.
    ///   - messageID: Message UID.
    ///   - mailbox: Mailbox to open read-only. Defaults to `INBOX`.
    /// - Returns: Fetch request for one mailbox.
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
    /// - Parameters:
    ///   - credentials: Resolved connection fields plus password.
    ///   - messageID: Message UID.
    ///   - attachmentIndex: Zero-based attachment position.
    ///   - mailbox: Mailbox to open read-only. Defaults to `INBOX`.
    /// - Returns: Attachment request for one mailbox.
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
    ///
    /// The raw RFC822 bytes are built by the caller (plain headers plus
    /// bodies) and stored with `\Seen` so the Sent copy never appears
    /// unread. Failures are best-effort and never fail the send.
    /// - Parameters:
    ///   - credentials: Resolved connection fields plus password.
    ///   - mailbox: Resolved Sent mailbox (e.g. `Sent`).
    ///   - rawMessage: Full RFC822 bytes to store.
    /// - Returns: `append` request for one mailbox.
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
///
/// Each call spawns one short-lived `python3 -c` process, writes the
/// JSON request to its stdin, and decodes the JSON response from its
/// stdout. No Swift IMAP dependency is needed, matching the
/// subprocess-IPC bridge the architecture prescribes for Python-first
/// integrations. The helper never logs credentials or request bodies.
public struct SubprocessIMAPGateway: EmailIMAPGateway, Sendable {
    /// Environment variable overriding the Python executable.
    public static let pythonEnvVar = "RUNEWEAVER_PYTHON_BIN"

    /// Explicit Python executable path, if any.
    public let pythonExecutable: String?

    /// Creates a subprocess gateway.
    /// - Parameter pythonExecutable: Explicit `python3` path. Defaults
    ///   to `RUNEWEAVER_PYTHON_BIN` when set, otherwise `python3` on
    ///   `PATH` via `/usr/bin/env`.
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

    /// Searches via the Python helper.
    /// - Parameters:
    ///   - credentials: Resolved connection fields plus password.
    ///   - query: Free-text query (`"*"`/empty lists most-recent via `ALL`).
    ///   - limit: Maximum hits.
    /// - Returns: Hits, newest first.
    public func search(credentials: ResolvedEmailCredentials, query: String, limit: Int) async throws -> [EmailSearchHit] {
        try await search(credentials: credentials, mailbox: "INBOX", query: query, limit: limit)
    }

    /// Searches one mailbox via the Python helper.
    /// - Parameters:
    ///   - credentials: Resolved connection fields plus password.
    ///   - mailbox: Mailbox to open read-only.
    ///   - query: Free-text query (`"*"`/empty lists most-recent via `ALL`).
    ///   - limit: Maximum hits.
    /// - Returns: Hits newest-first labeled with `mailbox`.
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

    /// Fetches via the Python helper.
    /// - Parameters:
    ///   - credentials: Resolved connection fields plus password.
    ///   - messageID: Message UID.
    /// - Returns: Headers plus text body with attachment metadata.
    public func fetch(credentials: ResolvedEmailCredentials, messageID: String) async throws -> EmailFullMessage {
        try await fetch(credentials: credentials, mailbox: "INBOX", messageID: messageID)
    }

    /// Fetches one message from one mailbox via the Python helper.
    /// - Parameters:
    ///   - credentials: Resolved connection fields plus password.
    ///   - mailbox: Mailbox to open read-only.
    ///   - messageID: Message UID.
    /// - Returns: Headers plus text body with attachment metadata.
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

    /// Fetches one attachment part via the Python helper.
    /// - Parameters:
    ///   - credentials: Resolved connection fields plus password.
    ///   - messageID: Message UID.
    ///   - attachmentIndex: Zero-based position in the `fetch` attachment list.
    /// - Returns: Attachment bytes with filename, MIME type, and size.
    public func attachment(
        credentials: ResolvedEmailCredentials,
        messageID: String,
        attachmentIndex: Int
    ) async throws -> EmailAttachmentData {
        try await attachment(credentials: credentials, mailbox: "INBOX", messageID: messageID, attachmentIndex: attachmentIndex)
    }

    /// Fetches one attachment part from one mailbox via the Python helper.
    /// - Parameters:
    ///   - credentials: Resolved connection fields plus password.
    ///   - mailbox: Mailbox to open read-only.
    ///   - messageID: Message UID.
    ///   - attachmentIndex: Zero-based position in the `fetch` attachment list.
    /// - Returns: Attachment bytes with filename, MIME type, and size.
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
    ///
    /// Best-effort Sent copy: validates the mailbox and non-empty bytes
    /// before spawning so empty appends fail without network use, then
    /// stores via `IMAP APPEND` with verified TLS. Callers warn but never
    /// fail the send when this throws.
    /// - Parameters:
    ///   - credentials: Resolved connection fields plus password.
    ///   - mailbox: Destination mailbox (resolved Sent folder).
    ///   - rawMessage: Full RFC822 bytes to store.
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
    ///
    /// Encoding runs on the caller; the blocking spawn, stdin write,
    /// wait, and pipe reads run off the async executor on a background
    /// queue via `runIMAPBridgeIO(payload:pythonExecutable:)` so the
    /// cooperative pool is never blocked.
    /// - Parameter request: Bridge request (holds the password in memory only).
    /// - Returns: Raw stdout bytes.
    /// - Throws: `EmailIMAPError` without any secret value.
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

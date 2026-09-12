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
        // Check the raw value before trimming so leading/trailing CR/LF
        // cannot hide behind `trimmingCharacters`, and compare at the
        // scalar level so an embedded CRLF pair (one `Character`) still
        // matches even though `contains("\r")` would miss it.
        if mailbox.unicodeScalars.contains(where: { $0.value == 13 || $0.value == 10 }) {
            throw EmailIMAPError.bridgeFailed("Invalid mailbox: mailbox must not contain CR or LF")
        }
        let trimmed = mailbox.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw EmailIMAPError.bridgeFailed("Invalid mailbox: mailbox must not be empty")
        }
    }
}

/// Read-only IMAP gateway used by the email tools.
///
/// The production implementation shells out to `python3 imaplib`;
/// tests inject a stub. Both paths stay read-only: the mailbox is
/// opened with `readonly=True` and only `(BODY.PEEK[])` fetches are
/// used so `\Seen` is never set even when the server ignores the
/// read-only open. `listMailboxes` plus the `mailbox` overloads fan
/// search out across every selectable folder; the legacy `INBOX`
/// overloads remain for single-folder callers.
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
}

/// Bridge request document sent to the Python helper over stdin.
///
/// Encoded as a single JSON object. The password travels only in this
/// in-memory document and the subprocess pipe — it is never logged
/// and never echoed in errors.
struct EmailIMAPBridgeRequest: Encodable {
    /// Operation: `"search"`, `"fetch"`, `"attachment"`, or `"list"`.
    let op: String // swiftlint:disable:this identifier_name
    /// IMAP hostname.
    let host: String
    /// IMAP port.
    let port: Int
    /// Login username.
    let username: String
    /// Runtime-resolved password. Never logged.
    let password: String
    /// Mailbox to open read-only (`INBOX` by default; ignored for `list`).
    let mailbox: String
    /// Free-text query (search only).
    let query: String?
    /// Maximum hits (search only).
    let limit: Int?
    /// Message UID (fetch and attachment only).
    let messageID: String?
    /// Zero-based attachment position (attachment only).
    let attachmentIndex: Int?

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
            attachmentIndex: nil
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
            attachmentIndex: nil
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
            attachmentIndex: attachmentIndex
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
            attachmentIndex: nil
        )
    }
}

/// Embedded `python3 imaplib` helper.
///
/// Reads one `EmailIMAPBridgeRequest` JSON object from stdin and
/// prints one JSON response to stdout (`{"ok":true,...}` or
/// `{"ok":false,"error":"..."}`). The mailbox is opened read-only and
/// every fetch uses `(BODY.PEEK[])` so messages stay unseen even when
/// the server ignores the read-only open. TLS is always verified via
/// `ssl.create_default_context()` (fail closed; private-CA homelab
/// hosts pin via `ctx.load_verify_locations()` instead of disabling
/// verification) with a 30-second connect timeout. Search rejects
/// CR/LF in the query and mailbox, fetch allowlists message ids to UID
/// syntax (`^[0-9][0-9:,]*$`) so crafted input cannot inject additional
/// IMAP commands, and attachment validates the part index as a
/// non-negative integer. The `list` op reports selectable mailboxes via
/// `IMAP LIST`, excluding `Noselect`/`NonExistent` flags so namespace
/// placeholders never enter the fan-out. Search uses `OR SUBJECT/FROM/BODY` (via
/// `CHARSET UTF-8` with a plain fallback for servers without `UTF-8`
/// search) so one query covers subject, sender, and body. An empty,
/// whitespace-only, or lone `"*"` query maps to `SEARCH ALL` and returns
/// the most-recent messages (UID order, newest first, capped by `limit`)
/// so `query: "*"` with `limit: 1` answers "last email subject" on iCloud
/// where a literal `TEXT "*"` matches nothing. MIME parsing
/// prefers `text/plain`, falls back to stripped `text/html`, and lists
/// attachment filename, MIME type, and decoded byte size. The
/// `attachment` op returns one part base64-encoded in walk order so the
/// Swift tool can stage it under the sandbox; both the bridge (pre-flight
/// abort before base64 encoding) and the Swift tool enforce the 10 MB
/// download size cap. iCloud accounts use the same IMAP path
/// (`imap.mail.me.com:993` with an app-specific password via
/// `EMAIL_ICLOUD_PASSWORD`), verified live read-only.
enum EmailIMAPBridgeScript {
    /// Python source executed via `python3 -c`.
    static let source = EmailIMAPBridgeScriptHead.text + EmailIMAPBridgeScriptTail.text
}

/// First half of the embedded `python3 imaplib` helper (imports through connect).
private enum EmailIMAPBridgeScriptHead {
    /// First half of the Python source.
    static let text = #"""
    import sys, json, imaplib, email, re, ssl, base64
    from email import policy
    from email.header import decode_header
    from email.utils import getaddresses

    def decode_value(raw):
        if raw is None:
            return ""
        parts = []
        for text, charset in decode_header(raw):
            if isinstance(text, bytes):
                try:
                    parts.append(text.decode(charset or "utf-8", errors="replace"))
                except Exception:
                    parts.append(text.decode("utf-8", errors="replace"))
            else:
                parts.append(text)
        return "".join(parts)

    def body_text(msg):
        plain = None
        html = None
        if msg.is_multipart():
            for part in msg.walk():
                if part.is_multipart():
                    continue
                disp = (part.get_content_disposition() or "").lower()
                filename = part.get_filename()
                if disp == "attachment" or filename:
                    continue
                ctype = (part.get_content_type() or "").lower()
                try:
                    payload = part.get_payload(decode=True) or b""
                    charset = part.get_content_charset() or "utf-8"
                    text = payload.decode(charset, errors="replace")
                except Exception:
                    continue
                if ctype == "text/plain" and plain is None:
                    plain = text
                elif ctype == "text/html" and html is None:
                    html = text
            if plain:
                return plain
            if html:
                text = re.sub(r"<[^>]+>", " ", html)
                text = re.sub(r"\s+", " ", text)
                return text.strip()
            return ""
        try:
            payload = msg.get_payload(decode=True)
            if payload is None:
                nested = msg.get_payload()
                return nested if isinstance(nested, str) else ""
            charset = msg.get_content_charset() or "utf-8"
            text = payload.decode(charset, errors="replace")
            if (msg.get_content_type() or "").lower() == "text/html":
                text = re.sub(r"<[^>]+>", " ", text)
                text = re.sub(r"\s+", " ", text)
                return text.strip()
            return text
        except Exception:
            return ""

    def attachment_parts(msg):
        parts = []
        if msg.is_multipart():
            for part in msg.walk():
                if part.is_multipart():
                    continue
                disp = (part.get_content_disposition() or "").lower()
                filename = part.get_filename()
                if disp == "attachment" or filename:
                    name = decode_value(filename) if filename else "unnamed-attachment"
                    if not name.strip():
                        name = "unnamed-attachment"
                    ctype = part.get_content_type() or "application/octet-stream"
                    try:
                        payload = part.get_payload(decode=True) or b""
                    except Exception:
                        payload = b""
                    parts.append((name, ctype, payload))
        return parts

    def attachments_of(msg):
        found = []
        for (name, ctype, payload) in attachment_parts(msg):
            found.append({"filename": name, "contentType": ctype, "sizeBytes": len(payload)})
        return found

    def attachment_index_of(req):
        raw = req.get("attachmentIndex")
        if raw is None:
            raw = req.get("attachment_index")
        if raw is None:
            raw = req.get("index")
        if isinstance(raw, bool):
            return None
        try:
            return int(raw)
        except Exception:
            return None

    def snippet_of(text, limit=200):
        single = re.sub(r"\s+", " ", text or "").strip()
        if len(single) > limit:
            return single[:limit]
        return single

    def parse_list_entry(line):
        if isinstance(line, bytes):
            try:
                text = line.decode("utf-8", errors="replace")
            except Exception:
                text = str(line)
        else:
            text = str(line)
        flags = ""
        m = re.search(r"\(([^)]*)\)", text)
        if m:
            flags = m.group(1) or ""
            rest = text[m.end():].strip()
        else:
            rest = text.strip()
        name = ""
        if rest.endswith('"'):
            quoted = re.findall(r'"([^"]*)"', rest)
            if quoted:
                name = quoted[-1]
            else:
                name = rest.strip().strip('"')
        else:
            parts = rest.split()
            if parts:
                name = parts[-1].strip().strip('"')
        return (flags, name.strip())

    def is_selectable(flags):
        lowered = (flags or "").lower()
        return ("noselect" not in lowered) and ("nonexistent" not in lowered)

    def fail(message):
        sys.stdout.write(json.dumps({"ok": False, "error": message}))
        sys.stdout.flush()

    def main():
        try:
            req = json.loads(sys.stdin.read() or "{}")
        except Exception:
            fail("Invalid IMAP bridge request JSON")
            return
        op = req.get("op") or ""
        if op == "search":
            early_query = req.get("query") or ""
            if "\r" in early_query or "\n" in early_query:
                fail("Invalid search query")
                return
            early_box = str(req.get("mailbox") or "INBOX")
            if "\r" in early_box or "\n" in early_box:
                fail("Invalid mailbox")
                return
        elif op == "fetch":
            early_mid = str(req.get("messageID") or req.get("messageId") or req.get("id") or req.get("uid") or "").strip()
            if not early_mid:
                fail("Missing message id")
                return
            if not re.fullmatch(r"[0-9][0-9:,]*", early_mid):
                fail("Invalid message id")
                return
            early_box = str(req.get("mailbox") or "INBOX")
            if "\r" in early_box or "\n" in early_box:
                fail("Invalid mailbox")
                return
        elif op == "attachment":
            early_mid = str(req.get("messageID") or req.get("messageId") or req.get("id") or req.get("uid") or "").strip()
            if not early_mid:
                fail("Missing message id")
                return
            if not re.fullmatch(r"[0-9][0-9:,]*", early_mid):
                fail("Invalid message id")
                return
            early_idx = attachment_index_of(req)
            if early_idx is None or early_idx < 0:
                fail("Invalid attachment index")
                return
            early_box = str(req.get("mailbox") or "INBOX")
            if "\r" in early_box or "\n" in early_box:
                fail("Invalid mailbox")
                return
        elif op == "list":
            pass
        host = req.get("host") or ""
        try:
            port = int(req.get("port") or 993)
        except Exception:
            port = 993
        username = req.get("username") or ""
        password = req.get("password") or ""
        mailbox = req.get("mailbox") or "INBOX"
        if not host or not username or not password:
            fail("Missing IMAP connection fields")
            return
        try:
            ctx = ssl.create_default_context()
            try:
                conn = imaplib.IMAP4_SSL(host, port, ssl_context=ctx, timeout=30)
            except TypeError:
                conn = imaplib.IMAP4_SSL(host, port, ssl_context=ctx)
        except Exception as exc:
            fail("Could not connect to %s@%s:%s: %s" % (username, host, port, exc))
            return
    """#
}

/// Second half of the embedded `python3 imaplib` helper (login through `main()`).
private enum EmailIMAPBridgeScriptTail {
    /// Second half of the Python source.
    static let text = #"""
        try:
            try:
                conn.login(username, password)
            except Exception as exc:
                fail("IMAP login failed for %s@%s:%s: %s" % (username, host, port, exc))
                return
            if op == "list":
                try:
                    ltyp, ldata = conn.list()
                except Exception as exc:
                    fail("IMAP list failed: %s" % exc)
                    return
                if ltyp != "OK":
                    fail("IMAP list failed")
                    return
                boxes = []
                for line in (ldata or []):
                    if line is None:
                        continue
                    flags, name = parse_list_entry(line)
                    if not name:
                        continue
                    if not is_selectable(flags):
                        continue
                    boxes.append(name)
                sys.stdout.write(json.dumps({"ok": True, "mailboxes": boxes}))
                sys.stdout.flush()
                return
            mailbox_check = str(mailbox or "INBOX")
            if "\r" in mailbox_check or "\n" in mailbox_check:
                fail("Invalid mailbox")
                return
            try:
                typ, _ = conn.select(mailbox, readonly=True)
            except Exception as exc:
                fail("Could not open mailbox %s: %s" % (mailbox, exc))
                return
            if typ != "OK":
                fail("Could not open mailbox %s" % mailbox)
                return
            if op == "search":
                raw_query = req.get("query") or ""
                if "\r" in raw_query or "\n" in raw_query:
                    fail("Invalid search query")
                    return
                if "\r" in mailbox or "\n" in mailbox:
                    fail("Invalid mailbox")
                    return
                query = raw_query.strip()
                try:
                    limit = int(req.get("limit") or 10)
                except Exception:
                    limit = 10
                limit = max(1, min(limit, 50))
                try:
                    if not query or query == "*":
                        typ, data = conn.uid("search", None, "ALL")
                    else:
                        esc = query.replace("\\", "\\\\").replace('"', '\\"')
                        criteria = 'OR OR SUBJECT "%s" FROM "%s" BODY "%s"' % (esc, esc, esc)
                        ctyp, cdata = None, None
                        try:
                            ctyp, cdata = conn.uid("search", "CHARSET", "UTF-8", criteria)
                        except Exception:
                            ctyp, cdata = None, None
                        if ctyp == "OK" and cdata is not None:
                            typ, data = ctyp, cdata
                        else:
                            typ, data = conn.uid("search", None, criteria)
                    if typ != "OK":
                        fail("IMAP search failed")
                        return
                    uids = (data[0] or b"").split() if data else []
                    wanted = [u.decode("utf-8", errors="replace") for u in uids[-limit:]]
                    wanted.reverse()
                    messages = []
                    for uid in wanted:
                        try:
                            ftyp, fdata = conn.uid("fetch", uid, "(BODY.PEEK[])")
                        except Exception:
                            continue
                        if ftyp != "OK" or not fdata:
                            continue
                        raw = None
                        for chunk in fdata:
                            if isinstance(chunk, tuple) and len(chunk) >= 2 and isinstance(chunk[1], bytes):
                                raw = chunk[1]
                                break
                        if not raw:
                            continue
                        msg = email.message_from_bytes(raw, policy=policy.default)
                        text = body_text(msg)
                        messages.append({
                            "id": uid,
                            "subject": decode_value(msg["Subject"]),
                            "from": decode_value(msg["From"]),
                            "date": str(msg["Date"] or ""),
                            "snippet": snippet_of(text),
                            "mailbox": mailbox,
                        })
                    sys.stdout.write(json.dumps({"ok": True, "messages": messages}))
                    sys.stdout.flush()
                except Exception as exc:
                    fail("IMAP search failed: %s" % exc)
                    return
            elif op == "fetch":
                mid = str(req.get("messageID") or req.get("messageId") or req.get("id") or req.get("uid") or "").strip()
                if not mid:
                    fail("Missing message id")
                    return
                if not re.fullmatch(r"[0-9][0-9:,]*", mid):
                    fail("Invalid message id")
                    return
                try:
                    raw = None
                    ftyp, fdata = conn.uid("fetch", mid, "(BODY.PEEK[])")
                    if ftyp != "OK" or not fdata or fdata == [None]:
                        ftyp, fdata = conn.fetch(mid, "(BODY.PEEK[])")
                    if ftyp == "OK" and fdata:
                        for chunk in fdata:
                            if isinstance(chunk, tuple) and len(chunk) >= 2 and isinstance(chunk[1], bytes):
                                raw = chunk[1]
                                break
                    if not raw:
                        fail("Message %s not found" % mid)
                        return
                    msg = email.message_from_bytes(raw, policy=policy.default)
                    text = body_text(msg)
                    listed = attachments_of(msg)
                    deferred = len(listed) > 0
                    note = None
                    if deferred:
                        if len(listed) == 1:
                            note = "1 attachment listed; use email.attachment to download."
                        else:
                            note = "%d attachments listed; use email.attachment to download." % len(listed)
                    sys.stdout.write(json.dumps({"ok": True, "message": {
                        "id": mid,
                        "subject": decode_value(msg["Subject"]),
                        "from": decode_value(msg["From"]),
                        "to": decode_value(msg["To"]),
                        "date": str(msg["Date"] or ""),
                        "body": text or "",
                        "attachments": listed,
                        "attachmentsDeferred": deferred,
                        "attachmentsNote": note,
                    }}))
                    sys.stdout.flush()
                except Exception as exc:
                    fail("IMAP fetch failed: %s" % exc)
                    return
            elif op == "attachment":
                mid = str(req.get("messageID") or req.get("messageId") or req.get("id") or req.get("uid") or "").strip()
                if not mid:
                    fail("Missing message id")
                    return
                if not re.fullmatch(r"[0-9][0-9:,]*", mid):
                    fail("Invalid message id")
                    return
                idx = attachment_index_of(req)
                if idx is None or idx < 0:
                    fail("Invalid attachment index")
                    return
                try:
                    raw = None
                    ftyp, fdata = conn.uid("fetch", mid, "(BODY.PEEK[])")
                    if ftyp != "OK" or not fdata or fdata == [None]:
                        ftyp, fdata = conn.fetch(mid, "(BODY.PEEK[])")
                    if ftyp == "OK" and fdata:
                        for chunk in fdata:
                            if isinstance(chunk, tuple) and len(chunk) >= 2 and isinstance(chunk[1], bytes):
                                raw = chunk[1]
                                break
                    if not raw:
                        fail("Message %s not found" % mid)
                        return
                    msg = email.message_from_bytes(raw, policy=policy.default)
                    parts = attachment_parts(msg)
                    if idx < 0 or idx >= len(parts):
                        fail("Invalid attachment index %d (message has %d attachments)" % (idx, len(parts)))
                        return
                    name, ctype, payload = parts[idx]
                    if len(payload) > 10485760:
                        sys.stdout.write(json.dumps({"ok": True, "attachment": {
                            "filename": name,
                            "contentType": ctype,
                            "sizeBytes": len(payload),
                            "contentBase64": None,
                            "oversize": True,
                        }}))
                        sys.stdout.flush()
                        return
                    sys.stdout.write(json.dumps({"ok": True, "attachment": {
                        "filename": name,
                        "contentType": ctype,
                        "sizeBytes": len(payload),
                        "contentBase64": base64.b64encode(payload).decode("ascii"),
                    }}))
                    sys.stdout.flush()
                except Exception as exc:
                    fail("IMAP attachment fetch failed: %s" % exc)
                    return
            else:
                fail("Unknown IMAP op '%s'" % op)
                return
        finally:
            try:
                conn.logout()
            except Exception:
                pass

    main()
    """#
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
        } else if let configured = ProcessInfo.processInfo.environment[Self.pythonEnvVar],
                  !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            self.pythonExecutable = configured
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
        // Normalize wildcard/empty to ALL here as well so direct gateway
        // callers get most-recent messages even before the Python `ALL`
        // branch runs. Read-only, verified TLS, and caps are unchanged.
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

    /// Runs the helper once with the given request.
    ///
    /// Encoding runs on the caller; the blocking spawn, stdin write,
    /// wait, and pipe reads run off the async executor on a background
    /// queue via `runIMAPBridgeIO(payload:pythonExecutable:)` (mirroring
    /// `ConversationManager.runSerializedIO` / `VectorStore.runStoreIO`)
    /// so the cooperative pool is never blocked.
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
        return try await runIMAPBridgeIO(payload: payload, pythonExecutable: pythonExecutable)
    }
}

/// Runs blocking IMAP bridge subprocess I/O off the async executor.
///
/// Suspends the caller until the spawn, stdin write, wait, and pipe
/// reads complete on a background queue, keeping blocking
/// `Process.waitUntilExit()` and `readDataToEndOfFile()` off the
/// cooperative pool. Shared by every `SubprocessIMAPGateway` call so
/// blocking subprocess work stays single-sourced like `runStoreIO`.
///
/// Cancellation is observed cooperatively: already-cancelled tasks throw
/// before dispatch, and in-flight helpers run to completion so the
/// pipes never observe a torn write. The continuation resumes exactly
/// once on the single background completion path.
/// - Parameters:
///   - payload: Encoded bridge request (holds the password in memory only).
///   - pythonExecutable: Explicit `python3` path, or nil for `/usr/bin/env`.
/// - Returns: Raw stdout bytes.
/// - Throws: Whatever the blocking helper throws, or `CancellationError` when already cancelled.
private func runIMAPBridgeIO(payload: Data, pythonExecutable: String?) async throws -> Data {
    try Task.checkCancellation()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    try continuation.resume(returning: runIMAPBridgeBlocking(
                        payload: payload,
                        pythonExecutable: pythonExecutable
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    } onCancel: {
        // Non-cancellable by design: in-flight helpers run to
        // completion so the pipes never observe a torn write.
    }
}

/// Spawns the Python helper and reads its output synchronously.
///
/// Blocking file helper for `runIMAPBridgeIO(payload:pythonExecutable:)`.
/// Must run on a background queue, never on the async executor: it calls
/// blocking `Process.waitUntilExit()` and `readDataToEndOfFile()`.
/// Stdout and stderr drain on background queues started before
/// `waitUntilExit` so a large attachment payload (base64 well beyond the
/// ~64 KB pipe buffer) cannot deadlock with the Python writer.
/// The password travels only in `payload` and the subprocess pipe — it
/// is never logged and never echoed in errors.
/// - Parameters:
///   - payload: Encoded bridge request (holds the password in memory only).
///   - pythonExecutable: Explicit `python3` path, or nil for `/usr/bin/env`.
/// - Returns: Raw stdout bytes.
/// - Throws: `EmailIMAPError` without any secret value.
private func runIMAPBridgeBlocking(payload: Data, pythonExecutable: String?) throws -> Data {
    final class PipeDrain: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func set(_ value: Data) {
            lock.lock()
            defer { lock.unlock() }
            data = value
        }

        func get() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }
    final class SendableHandle: @unchecked Sendable {
        let handle: FileHandle
        init(_ handle: FileHandle) {
            self.handle = handle
        }
    }
    let process = Process()
    if let pythonExecutable, !pythonExecutable.isEmpty {
        process.executableURL = URL(fileURLWithPath: pythonExecutable)
        process.arguments = ["-c", EmailIMAPBridgeScript.source]
    } else {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", EmailIMAPBridgeScript.source]
    }
    let inputPipe = Pipe()
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardInput = inputPipe
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    do {
        try process.run()
    } catch {
        throw EmailIMAPError.pythonUnavailable(
            "Could not launch python3 for IMAP access: \(error.localizedDescription)"
        )
    }
    // Drain both pipes concurrently before waiting: a 10 MB attachment
    // (~13 MB base64) would otherwise fill the pipe while Python blocks
    // on write and Swift blocks on wait.
    let stdoutDrain = PipeDrain()
    let stderrDrain = PipeDrain()
    let drainGroup = DispatchGroup()
    let outputHandle = SendableHandle(outputPipe.fileHandleForReading)
    let errorHandle = SendableHandle(errorPipe.fileHandleForReading)
    drainGroup.enter()
    DispatchQueue.global(qos: .utility).async {
        stdoutDrain.set(outputHandle.handle.readDataToEndOfFile())
        drainGroup.leave()
    }
    drainGroup.enter()
    DispatchQueue.global(qos: .utility).async {
        stderrDrain.set(errorHandle.handle.readDataToEndOfFile())
        drainGroup.leave()
    }
    do {
        try inputPipe.fileHandleForWriting.write(contentsOf: payload)
    } catch {
        process.terminate()
        drainGroup.wait()
        throw EmailIMAPError.bridgeFailed("Could not write IMAP request: \(error.localizedDescription)")
    }
    try? inputPipe.fileHandleForWriting.close()
    process.waitUntilExit()
    drainGroup.wait()
    let output = stdoutDrain.get()
    let stderr = stderrDrain.get()
    if process.terminationStatus != 0 {
        let detail = String(data: stderr, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let detail, !detail.isEmpty {
            throw EmailIMAPError.bridgeFailed("IMAP helper failed: \(detail)")
        }
        throw EmailIMAPError.bridgeFailed(
            "IMAP helper exited with status \(process.terminationStatus)"
        )
    }
    if output.isEmpty {
        let detail = String(data: stderr, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if detail.isEmpty {
            throw EmailIMAPError.decodeFailed("IMAP helper returned no output")
        }
        throw EmailIMAPError.bridgeFailed("IMAP helper failed: \(detail)")
    }
    return output
}

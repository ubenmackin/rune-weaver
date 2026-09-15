// Rune Weaver Tools — Email search, read, attachment, and send tools.
//
// Provides the `email.search`, `email.read`, `email.attachment`, and
// `email.send` plugin tools over the `python3 imaplib`/`smtplib` bridges
// with read-only fetches, staged sandbox downloads, approval-gated
// sending, and execution-time credential resolution.

import Foundation
import RuneWeaverCore

/// Read-only `email.search` tool over IMAP.
///
/// Searches subject, sender, and body through the `python3 imaplib`
/// bridge and returns headers plus a short text snippet per hit.
/// By default fans out across every selectable mailbox (via `IMAP LIST`,
/// excluding `Noselect`/`NonExistent` flags), merges hits newest-first
/// labeled with their mailbox, and caps at `limit`; pass `mailbox` to
/// narrow to one folder. An empty, whitespace-only, or lone `"*"`
/// query lists the most-recent messages via `SEARCH ALL` (newest first,
/// capped by `limit`) instead of sending a literal `TEXT "*"` that
/// matches nothing on iCloud.
/// Always `readOnly`: it opens each mailbox read-only with
/// `(BODY.PEEK[])` fetches and never mutates flags or messages.
/// Verified live against Volcrypt IMAP (`mail.volcrypt.com:993`)
/// and iCloud IMAP (`imap.mail.me.com:993` with an app-specific
/// password via `EMAIL_ICLOUD_PASSWORD`).
public struct EmailSearchTool: Tool, Sendable {
    /// Stable tool name referenced by the LLM and memory.
    public let name = "email.search"
    /// When the LLM should use this tool.
    public let description =
        "Searches IMAP mailboxes (subject, sender, and body) across every selectable folder by default. "
            + "Use when the user asks to find or summarize email. "
            + "Use query \"*\" or empty for the most-recent messages. "
            + "Pass mailbox to narrow to one folder; each hit labels its mailbox for email.read. "
            + "Returns matching message ids, headers, snippets, and mailboxes."
    /// Function-calling contract for `account`, `query`, `limit`, and `mailbox`.
    public let inputSchema =
        JSONSchema(
            rawValue: #"{"type":"object","properties":{"account":{"type":"string","description":"Account nickname "#
                + #"from [email.accounts] (e.g. volcrypt, icloud)"},"query":{"type":"string","description":"Free-text query "#
                + #"matched against subject, sender, and body; \"*\" or empty "#
                + #"lists most-recent messages"},"limit":{"type":"integer","description":"Maximum hits "#
                + #"(1-50, default 10)","minimum":1,"maximum":50},"mailbox":{"type":"string","description":"Optional folder "#
                + #"to search (e.g. INBOX, Sent); omitted or blank searches every selectable mailbox"},"#
                + #""folder":{"type":"string","description":"Alias for mailbox"}}"#
                + #","required":["account","query"],"additionalProperties":false}"#
        )
    /// Always allowed: search never changes mailbox state.
    public let permissionLevel = PermissionLevel.readOnly

    /// Configured mail accounts.
    private let emailConfig: EmailConfig
    /// IMAP gateway (subprocess bridge by default, stub in tests).
    private let gateway: any EmailIMAPGateway

    /// Creates a search tool.
    /// - Parameters:
    ///   - emailConfig: Decoded `[email]` section.
    ///   - gateway: IMAP gateway. Defaults to the `python3` subprocess bridge.
    public init(emailConfig: EmailConfig, gateway: (any EmailIMAPGateway)? = nil) {
        self.emailConfig = emailConfig
        self.gateway = gateway ?? SubprocessIMAPGateway()
    }

    /// Runs the search, resolving credentials at execution time.
    /// - Parameters:
    ///   - input: Invocation with `account`, `query`, optional `limit`, and optional `mailbox`.
    ///   - context: Ambient execution context.
    /// - Returns: JSON envelope with hits, or a failure without secrets.
    public func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        // Smart raw pre-check plus decoded CR/LF validation before ANY
        // account lookup or credential resolution so invalid input reports
        // "Invalid search query" even when the password is missing. The raw
        // check looks for unescaped JSON escapes (`\r`, `\n`, `\u000d`,
        // `\u000a` with an odd backslash count) so legitimate queries with
        // literal backslash+r/n (Windows paths like `C:\new\report` encoded
        // as double backslash in JSON) pass while injection with single
        // backslash escapes fails. Decoded checks below catch real CR/LF
        // characters (including `\u000d` escapes decoded by the JSON parser).
        // Never logs or echoes input values or secrets.
        if EmailIMAPValidation.containsEncodedCRLF(in: input.argumentsJSON) {
            return .failure(
                EmailIMAPError.bridgeFailed("Invalid search query: query must not contain CR or LF").localizedDescription,
                callID: input.callID
            )
        }
        let args: EmailSearchArgs
        do {
            args = try JSONDecoder().decode(EmailSearchArgs.self, from: Data(input.argumentsJSON.utf8))
        } catch {
            return .failure(
                "Invalid email.search arguments: expected {\"account\": \"<name>\", \"query\": \"<text>\", \"limit\": <1-50>}.",
                callID: input.callID
            )
        }
        // Fail fast on decoded injection before touching accounts or
        // credentials so invalid input reports "Invalid search query" even
        // when the password is missing. Checks the raw value first (before
        // trimming) to mirror the bridge, then the trimmed value. Catches
        // actual CR/LF characters (including "\\u000d" escapes decoded by
        // the JSON parser).
        do {
            try EmailIMAPValidation.validateSearchQuery(args.query)
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
        // Fail fast on mailbox injection before touching accounts or
        // credentials so invalid input reports "Invalid mailbox" even when
        // the password is missing.
        if let requestedMailbox = args.trimmedMailbox {
            do {
                try EmailIMAPValidation.validateMailbox(requestedMailbox)
            } catch {
                return .failure(error.localizedDescription, callID: input.callID)
            }
        }
        let accountName = args.trimmedAccount
        let query = args.trimmedQuery
        guard !accountName.isEmpty else {
            return .failure("Invalid email.search arguments: 'account' must not be empty.", callID: input.callID)
        }
        do {
            try EmailIMAPValidation.validateSearchQuery(query)
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
        // Wildcard/empty maps to ALL: a trimmed empty query or a lone "*"
        // lists the most-recent messages instead of sending a literal
        // TEXT "*" that matches nothing on iCloud (imap.mail.me.com:993).
        // The normalized empty string triggers SEARCH ALL in the Python
        // bridge; the envelope echoes the effective query so the audit
        // shows what IMAP actually ran. Read-only, verified TLS, capped
        // limit, and no secret logging are unchanged.
        let effectiveQuery = EmailIMAPValidation.isAllQuery(query) ? "" : query
        guard let account = emailConfig.account(matching: accountName) else {
            let available = emailConfig.accounts.map(\.name)
            return .failure(EmailIMAPError.unknownAccount(name: accountName, available: available).localizedDescription, callID: input.callID)
        }
        let credentials: ResolvedEmailCredentials
        do {
            credentials = try await EmailCredentialResolver.resolvedCredentials(for: account)
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
        do {
            if let requested = args.trimmedMailbox {
                return try await singleMailboxOutput(
                    account: account,
                    credentials: credentials,
                    requested: requested,
                    effectiveQuery: effectiveQuery,
                    limit: args.limit,
                    callID: input.callID
                )
            }
            return try await fanOutOutput(
                account: account,
                credentials: credentials,
                effectiveQuery: effectiveQuery,
                limit: args.limit,
                callID: input.callID
            )
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
    }
}

extension EmailSearchTool {
    /// Searches one explicit mailbox with a clear unknown-folder error.
    /// - Parameters:
    ///   - account: Matched account for the envelope.
    ///   - credentials: Resolved connection fields plus password.
    ///   - requested: Trimmed requested mailbox.
    ///   - effectiveQuery: Normalized query (`""` means `SEARCH ALL`).
    ///   - limit: Maximum hits.
    ///   - callID: Correlation identifier.
    /// - Returns: Success envelope, or an unknown-mailbox failure.
    private func singleMailboxOutput(
        account: EmailAccount,
        credentials: ResolvedEmailCredentials,
        requested: String,
        effectiveQuery: String,
        limit: Int,
        callID: String
    ) async throws -> ToolOutput {
        let listed = try await gateway.listMailboxes(credentials: credentials)
        let available = EmailBridgeParsing.selectableMailboxes(from: listed.map { name in (flags: "", mailbox: name) })
        let canonical: String
        do {
            canonical = try EmailBridgeParsing.resolveMailboxAgainstList(requested: requested, available: available)
        } catch {
            return .failure(error.localizedDescription, callID: callID)
        }
        let hits = try await gateway.search(credentials: credentials, mailbox: canonical, query: effectiveQuery, limit: limit)
        let labeled = hits.map {
            EmailSearchHit(id: $0.id, subject: $0.subject, from: $0.from, date: $0.date, snippet: $0.snippet, mailbox: canonical)
        }
        let capped = Array(labeled.prefix(limit))
        let content = try EmailBridgeParsing.encodeSearchEnvelope(
            account: account.name,
            query: effectiveQuery,
            messages: capped,
            mailbox: canonical,
            mailboxes: [canonical]
        )
        return .success(content, callID: callID)
    }

    /// Fans out across every selectable mailbox, merging newest-first.
    ///
    /// Per-mailbox failures are skipped so one unreadable folder never
    /// hides the rest; when every folder fails the last error surfaces.
    /// The envelope lists only the folders actually searched (succeeded
    /// boxes), never folders that failed. Folder names are never
    /// assumed: an empty `LIST` result throws a no-selectable-mailboxes
    /// failure instead of synthesizing `INBOX`.
    /// - Parameters:
    ///   - account: Matched account for the envelope.
    ///   - credentials: Resolved connection fields plus password.
    ///   - effectiveQuery: Normalized query (`""` means `SEARCH ALL`).
    ///   - limit: Maximum hits.
    ///   - callID: Correlation identifier.
    /// - Returns: Success envelope with merged hits.
    private func fanOutOutput(
        account: EmailAccount,
        credentials: ResolvedEmailCredentials,
        effectiveQuery: String,
        limit: Int,
        callID: String
    ) async throws -> ToolOutput {
        let listed = try await gateway.listMailboxes(credentials: credentials)
        let available = EmailBridgeParsing.selectableMailboxes(from: listed.map { name in (flags: "", mailbox: name) })
        guard !available.isEmpty else {
            throw EmailBridgeParsing.unknownMailboxError(requested: "*", available: available)
        }
        var groups: [[EmailSearchHit]] = []
        var succeeded: [String] = []
        var lastError: Error?
        for box in available {
            do {
                let hits = try await gateway.search(credentials: credentials, mailbox: box, query: effectiveQuery, limit: limit)
                let labeled = hits.map {
                    EmailSearchHit(id: $0.id, subject: $0.subject, from: $0.from, date: $0.date, snippet: $0.snippet, mailbox: box)
                }
                groups.append(labeled)
                succeeded.append(box)
            } catch {
                if error is CancellationError {
                    throw error
                }
                lastError = error
                continue
            }
        }
        if groups.isEmpty, let lastError {
            throw lastError
        }
        let merged = EmailSearchMerge.mergedNewestFirst(groups, limit: limit)
        let content = try EmailBridgeParsing.encodeSearchEnvelope(
            account: account.name,
            query: effectiveQuery,
            messages: merged,
            mailbox: nil,
            mailboxes: succeeded
        )
        return .success(content, callID: callID)
    }
}

/// Read-only `email.read` tool over IMAP.
///
/// Returns headers plus the decoded text body. Attachment bytes are
/// never returned: parts are listed by filename, MIME type, and byte
/// size with a note pointing at `email.attachment` for downloads.
/// Pass the `mailbox` labeled on the `email.search` hit to reopen
/// messages outside `INBOX`; omitted or blank means `INBOX`.
/// Always `readOnly`. Verified live against Volcrypt IMAP
/// (`mail.volcrypt.com:993`) and iCloud IMAP
/// (`imap.mail.me.com:993` with an app-specific password via
/// `EMAIL_ICLOUD_PASSWORD`).
public struct EmailReadTool: Tool, Sendable {
    /// Stable tool name referenced by the LLM and memory.
    public let name = "email.read"
    /// When the LLM should use this tool.
    public let description =
        "Reads one email by id from an IMAP mailbox. "
            + "Use when the user asks to open or summarize a specific message. "
            + "Pass the mailbox labeled on the email.search hit (omitted means INBOX). "
            + "Returns headers plus the text body; attachments are listed with filename, MIME type, and byte size (use email.attachment to download)."
    /// Function-calling contract for `account` and `id` (plus accepted aliases) and optional `mailbox`.
    public let inputSchema =
        JSONSchema(
            rawValue: #"{"type":"object","properties":{"account":{"type":"string","description":"Account nickname "#
                + #"from [email.accounts] (e.g. volcrypt, icloud)"},"id":{"type":"string","description":"IMAP message id "#
                + #"from email.search"},"messageId":{"type":"string","description":"Alias "#
                + #"for id"},"message_id":{"type":"string","description":"Alias for id"},"#
                + #""uid":{"type":"string","description":"Alias for id"},"mailbox":{"type":"string","description":"Mailbox "#
                + #"from the email.search hit (e.g. INBOX); omitted means INBOX"},"folder":{"type":"string","description":"Alias "#
                + #"for mailbox"}},"required":["account"],"anyOf":[{"required":["id"]},"#
                + #"{"required":["messageId"]},{"required":["message_id"]},{"required":["uid"]}],"additionalProperties":false}"#
        )
    /// Always allowed: reading never changes mailbox state.
    public let permissionLevel = PermissionLevel.readOnly

    /// Configured mail accounts.
    private let emailConfig: EmailConfig
    /// IMAP gateway (subprocess bridge by default, stub in tests).
    private let gateway: any EmailIMAPGateway

    /// Creates a read tool.
    /// - Parameters:
    ///   - emailConfig: Decoded `[email]` section.
    ///   - gateway: IMAP gateway. Defaults to the `python3` subprocess bridge.
    public init(emailConfig: EmailConfig, gateway: (any EmailIMAPGateway)? = nil) {
        self.emailConfig = emailConfig
        self.gateway = gateway ?? SubprocessIMAPGateway()
    }

    /// Reads one message, resolving credentials at execution time.
    /// - Parameters:
    ///   - input: Invocation with `account` and `id` (plus `messageId` aliases) and optional `mailbox`.
    ///   - context: Ambient execution context.
    /// - Returns: JSON envelope with headers and body, or a failure without secrets.
    public func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        // Decoded-only UID allowlisting happens after JSON decoding: the
        // strict `^[0-9][0-9:,]*$` check on the decoded id rejects real
        // CR/LF (including "\\u000d" escapes decoded by the JSON parser)
        // before ANY account lookup or credential resolution, so invalid
        // input reports "Invalid message id" even when the password is
        // missing. No raw-document pre-check: legitimate ids never contain
        // backslash escapes, and raw checks false-positive on them.
        let args: EmailReadArgs
        do {
            args = try JSONDecoder().decode(EmailReadArgs.self, from: Data(input.argumentsJSON.utf8))
        } catch {
            return .failure("Invalid email.read arguments: expected {\"account\": \"<name>\", \"id\": \"<message-id>\"}.", callID: input.callID)
        }
        // Fail fast on allowlist before touching accounts or credentials
        // so invalid input reports "Invalid message id" even when the
        // password is missing. Checks the raw value first, then trimmed.
        // Catches actual control characters (including "\\u000d" escapes
        // decoded by the JSON parser).
        do {
            try EmailIMAPValidation.validateMessageID(args.messageID)
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
        if let requestedMailbox = args.trimmedMailbox {
            do {
                try EmailIMAPValidation.validateMailbox(requestedMailbox)
            } catch {
                return .failure(error.localizedDescription, callID: input.callID)
            }
        }
        let accountName = args.trimmedAccount
        let messageID = args.trimmedMessageID
        guard !accountName.isEmpty else {
            return .failure("Invalid email.read arguments: 'account' must not be empty.", callID: input.callID)
        }
        guard !messageID.isEmpty else {
            return .failure("Invalid email.read arguments: 'id' must not be empty.", callID: input.callID)
        }
        do {
            try EmailIMAPValidation.validateMessageID(messageID)
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
        guard let account = emailConfig.account(matching: accountName) else {
            let available = emailConfig.accounts.map(\.name)
            return .failure(EmailIMAPError.unknownAccount(name: accountName, available: available).localizedDescription, callID: input.callID)
        }
        let credentials: ResolvedEmailCredentials
        do {
            credentials = try await EmailCredentialResolver.resolvedCredentials(for: account)
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
        do {
            // Reuse the found mailbox so fan-out hits stay openable. Every mailbox — explicit
            // or the legacy-default `INBOX` for omitted or blank — is validated against the
            // selectable list via `resolveMailboxAgainstList` with a clear unknown-folder error;
            // folder names are never assumed so an empty `LIST` result returns a
            // no-selectable-mailboxes failure instead of synthesizing `INBOX`.
            let requestedOrDefault = args.trimmedMailbox ?? "INBOX"
            let listed = try await gateway.listMailboxes(credentials: credentials)
            let available = EmailBridgeParsing.selectableMailboxes(from: listed.map { name in (flags: "", mailbox: name) })
            let effectiveMailbox: String
            do {
                effectiveMailbox = try EmailBridgeParsing.resolveMailboxAgainstList(requested: requestedOrDefault, available: available)
            } catch {
                return .failure(error.localizedDescription, callID: input.callID)
            }
            let message = try await gateway.fetch(credentials: credentials, mailbox: effectiveMailbox, messageID: messageID)
            let content = try EmailBridgeParsing.encodeReadEnvelope(account: account.name, message: message, mailbox: effectiveMailbox)
            return .success(content, callID: input.callID)
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
    }
}

/// `email.attachment` tool over IMAP.
///
/// Downloads one attachment part by zero-based index into the sandbox
/// staging area only (never to the real filesystem) and returns the
/// staged path with filename, MIME type, byte size, staged-file expiry,
/// coarse MIME bucket, and a follow-up hint. Parts over the size cap
/// are skipped without writing, returning a note instead. Pass
/// `preview: true` to inline the first 2000 chars for small text
/// payloads (`text/*`, `application/json` under 256 KB); binaries are
/// never inlined. Pass the `mailbox` labeled on the `email.search` hit
/// to fetch from folders outside `INBOX`; omitted or blank means `INBOX`.
/// Declared `requiresApproval` so the graduated-trust gate prompts
/// before any download. Reads only: it opens each mailbox read-only
/// with `(BODY.PEEK[])` fetches and never sends mail. Secrets are
/// resolved at execution time and never logged.
public struct EmailAttachmentTool: Tool, Sendable {
    /// Stable tool name referenced by the LLM and memory.
    public let name = "email.attachment"
    /// When the LLM should use this tool.
    public let description =
        "Downloads one email attachment by index into the sandbox staging area. "
            + "Use when the user asks to save or open an attachment listed by email.read. "
            + "Pass the mailbox labeled on the email.search hit (omitted means INBOX). "
            + "Writes only under the sandbox staging area; parts over the size cap are skipped with a note. "
            + "Pass preview true to inline the first 2000 chars for small text parts (binaries are never inlined); "
            + "the success envelope also reports the staged path expiry, MIME category, and a files.read follow-up hint."
    /// Function-calling contract for `account`, `id`, `index`, `mailbox` (plus accepted aliases), and `preview`.
    public let inputSchema =
        JSONSchema(
            rawValue: #"{"type":"object","properties":{"account":{"type":"string","description":"Account nickname "#
                + #"from [email.accounts] (e.g. volcrypt, icloud)"},"id":{"type":"string","description":"IMAP message "#
                + #"id from email.search"},"messageId":{"type":"string","description":"Alias for "#
                + #"id"},"message_id":{"type":"string","description":"Alias for id"},"uid":{"type":"string","description":"Alias "#
                + #"for id"},"index":{"type":"integer","description":"Zero-based attachment "#
                + #"position from email.read","minimum":0},"attachmentIndex":{"type":"integer","description":"Alias "#
                + #"for index","minimum":0},"attachment_index":{"type":"integer","description":"Alias for "#
                + #"index","minimum":0},"mailbox":{"type":"string","description":"Mailbox from the email.search hit "#
                + #"(e.g. INBOX); omitted means INBOX"},"folder":{"type":"string","description":"Alias for mailbox"}, "#
                + #""preview":{"type":"boolean","description":"When true, inline the first 2000 chars for small "#
                + #"text parts (text/*, application/json under 256 KB); binaries are never inlined"}}"#
                + #","required":["account"],"allOf":[{"anyOf":[{"required":["id"]},"#
                + #"{"required":["messageId"]},{"required":["message_id"]},{"required":["uid"]}]},"#
                + #"{"anyOf":[{"required":["index"]},{"required":["attachmentIndex"]},"#
                + #"{"required":["attachment_index"]}]} ],"additionalProperties":false}"#
        )
    /// Gated: downloads stage files and always prompt without a trust grant.
    public let permissionLevel = PermissionLevel.requiresApproval

    /// Maximum decoded bytes staged per attachment (10 MB).
    public static let maxAttachmentBytes = 10 * 1024 * 1024
    /// Subdirectory of the staging area holding downloaded attachments.
    public static let attachmentsSubdirectory = "attachments"

    /// Configured mail accounts.
    private let emailConfig: EmailConfig
    /// IMAP gateway (subprocess bridge by default, stub in tests).
    private let gateway: any EmailIMAPGateway
    /// Sandbox staging configuration. Writes stay under `stagingPath`.
    private let sandboxConfig: SandboxConfig

    /// Creates an attachment tool.
    /// - Parameters:
    ///   - emailConfig: Decoded `[email]` section.
    ///   - gateway: IMAP gateway. Defaults to the `python3` subprocess bridge.
    ///   - sandboxConfig: Sandbox staging configuration. Defaults to the built-in staging path.
    public init(
        emailConfig: EmailConfig,
        gateway: (any EmailIMAPGateway)? = nil,
        sandboxConfig: SandboxConfig = SandboxConfig()
    ) {
        self.emailConfig = emailConfig
        self.gateway = gateway ?? SubprocessIMAPGateway()
        self.sandboxConfig = sandboxConfig
    }

    /// Downloads one attachment part into the sandbox staging area.
    /// - Parameters:
    ///   - input: Invocation with `account`, `id` (plus `messageId` aliases), `index` aliases, optional `mailbox`, and optional `preview`.
    ///   - context: Ambient execution context. `dryRun` fetches but never writes.
    /// - Returns: JSON envelope with the staged path, lifecycle hints, and optional inline preview, or a skip note, or a failure without secrets.
    public func execute(input: ToolInput, context: ToolContext) async throws -> ToolOutput {
        do {
            let args = try decodedArgs(from: input)
            let target = try validatedTarget(from: args)
            let account = try resolvedAccount(named: target.accountName)
            let credentials = try await EmailCredentialResolver.resolvedCredentials(for: account)
            let effectiveMailbox = try await resolvedMailbox(credentials: credentials, requested: target.mailbox)
            let effectiveTarget = AttachmentTarget(
                accountName: target.accountName,
                messageID: target.messageID,
                attachmentIndex: target.attachmentIndex,
                mailbox: effectiveMailbox,
                preview: target.preview
            )
            let fetched = try await fetchedAttachment(
                credentials: credentials,
                mailbox: effectiveMailbox,
                messageID: effectiveTarget.messageID,
                index: effectiveTarget.attachmentIndex
            )
            if fetched.sizeBytes > Self.maxAttachmentBytes || fetched.data.count > Self.maxAttachmentBytes {
                return oversizedEnvelope(target: effectiveTarget, accountName: account.name, fetched: fetched, callID: input.callID)
            }
            let destination = try stagedDestinationURL(
                target: effectiveTarget,
                accountName: account.name,
                filename: fetched.filename
            )
            if context.dryRun {
                return dryRunEnvelope(
                    target: effectiveTarget,
                    accountName: account.name,
                    fetched: fetched,
                    destination: destination,
                    callID: input.callID
                )
            }
            return storedEnvelope(
                target: effectiveTarget,
                accountName: account.name,
                fetched: fetched,
                destination: destination,
                callID: input.callID
            )
        } catch let cancel as CancellationError {
            throw cancel
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
    }

    /// Builds the skip note for an oversized part.
    /// - Parameter sizeBytes: Decoded size of the skipped part.
    /// - Returns: Human-readable note naming the size cap.
    public static func oversizeNote(sizeBytes: Int) -> String {
        "Attachment skipped: \(sizeBytes) bytes exceeds the 10 MB download cap."
    }

    /// Resolves the sandbox-confined destination for a download.
    /// - Parameters:
    ///   - stagingPath: Configured staging directory (`~` is expanded).
    ///   - account: Account nickname used in the file prefix.
    ///   - messageID: Message UID used in the file prefix.
    ///   - index: Attachment position used in the file prefix.
    ///   - filename: Original attachment filename, sanitized to its base name.
    /// - Returns: Destination URL strictly under the staging area.
    /// - Throws: A failure when the staging path is empty or escapes the sandbox.
    public static func stagedDestination(
        stagingPath: String,
        account: String,
        messageID: String,
        index: Int,
        filename: String
    ) throws -> URL {
        let trimmed = stagingPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw EmailIMAPError.bridgeFailed("Invalid sandbox staging path")
        }
        let expanded = (trimmed as NSString).expandingTildeInPath
        // Resolve symlinks on both sides so a symlinked staging directory
        // cannot bypass confinement. The check runs before `createDirectory`
        // and `write` create anything; callers stage only under the
        // returned URL.
        let stagingURL = URL(fileURLWithPath: expanded, isDirectory: true).standardized
        let resolvedStaging = stagingURL.resolvingSymlinksInPath()
        let sanitized = sanitizedFilename(filename, fallback: "attachment-\(index)")
        let prefix = "\(safeSegment(account))-\(safeSegment(messageID))-\(index)-\(sanitized)"
        let destination = stagingURL
            .appendingPathComponent(attachmentsSubdirectory, isDirectory: true)
            .appendingPathComponent(prefix, isDirectory: false)
            .standardized
        let resolvedDestination = destination.resolvingSymlinksInPath()
        let stagingPrefix = resolvedStaging.path.hasSuffix("/") ? resolvedStaging.path : resolvedStaging.path + "/"
        guard resolvedDestination.path.hasPrefix(stagingPrefix) else {
            throw EmailIMAPError.bridgeFailed("Attachment path escapes the sandbox staging area")
        }
        return destination
    }

    /// Sanitizes a filename to its base name, falling back when empty.
    ///
    /// Strips path separators (`/` and `\`), NUL, colons, and ASCII
    /// control characters, drops leading dots and dashes so the result
    /// cannot hide as dotfiles or parse as a flag, and truncates to
    /// 255 characters (`NAME_MAX`) to stay within filesystem limits.
    /// - Parameters:
    ///   - filename: Original filename.
    ///   - fallback: Name used when the base name is empty.
    /// - Returns: Base name safe to append under the staging area.
    public static func sanitizedFilename(_ filename: String, fallback: String) -> String {
        let base = (filename as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var cleaned = base
            .replacingOccurrences(of: "\0", with: "_")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        cleaned = cleaned.unicodeScalars.map { scalar -> String in
            let value = scalar.value
            if value < 32 || value == 127 {
                return "_"
            }
            return String(scalar)
        }.joined()
        while cleaned.hasPrefix(".") || cleaned.hasPrefix("-") {
            cleaned.removeFirst()
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count > 255 {
            cleaned = String(cleaned.prefix(255))
        }
        guard !cleaned.isEmpty, cleaned != ".", cleaned != ".." else {
            return fallback
        }
        return cleaned
    }

    /// Maps an account or message segment to filesystem-safe text.
    /// - Parameter segment: Raw account or message identifier.
    /// - Returns: Text with only alphanumerics, dash, underscore, and dot.
    public static func safeSegment(_ segment: String) -> String {
        let mapped = segment.unicodeScalars.map { scalar -> String in
            let value = scalar.value
            let isDigit = value >= 48 && value <= 57
            let isUpper = value >= 65 && value <= 90
            let isLower = value >= 97 && value <= 122
            let isDash = value == 45
            let isUnderscore = value == 95
            let isDot = value == 46
            if isDigit || isUpper || isLower || isDash || isUnderscore || isDot {
                return String(scalar)
            }
            return "_"
        }.joined()
        return mapped.isEmpty ? "_" : mapped
    }
}

/// Trimmed attachment routing for `email.attachment`.
private struct AttachmentTarget {
    let accountName: String
    let messageID: String
    let attachmentIndex: Int
    let mailbox: String
    /// Whether the caller requested an inline text preview.
    let preview: Bool
}

extension EmailAttachmentTool {
    /// Decodes attachment arguments, rejecting bad ids and indexes early.
    /// - Parameter input: Raw tool invocation.
    /// - Returns: Decoded args.
    /// - Throws: Failure message when decoding or validation fails.
    private func decodedArgs(from input: ToolInput) throws -> EmailAttachmentArgs {
        let args: EmailAttachmentArgs
        do {
            args = try JSONDecoder().decode(EmailAttachmentArgs.self, from: Data(input.argumentsJSON.utf8))
        } catch {
            throw EmailIMAPError.bridgeFailed(
                "Invalid email.attachment arguments: expected {\"account\": \"<name>\", \"id\": \"<message-id>\", \"index\": <0-based>}."
            )
        }
        try EmailIMAPValidation.validateMessageID(args.messageID)
        try EmailIMAPValidation.validateAttachmentIndex(args.attachmentIndex)
        if let requestedMailbox = args.trimmedMailbox {
            try EmailIMAPValidation.validateMailbox(requestedMailbox)
        }
        return args
    }

    /// Trims and re-validates decoded attachment routing.
    ///
    /// Omitted or blank mailboxes fall back to the legacy-default `INBOX`
    /// string here but are validated against `LIST` downstream in `resolvedMailbox`
    /// via `resolveMailboxAgainstList` like explicit values; folder names are never
    /// assumed. The optional `preview` flag passes through untouched so text
    /// previews stay opt-in and legacy calls without it behave identically.
    /// - Parameter args: Decoded attachment arguments.
    /// - Returns: Trimmed routing.
    /// - Throws: Failure message when routing is empty or invalid.
    private func validatedTarget(from args: EmailAttachmentArgs) throws -> AttachmentTarget {
        let accountName = args.trimmedAccount
        let messageID = args.trimmedMessageID
        let attachmentIndex = args.attachmentIndex
        let mailbox = args.trimmedMailbox ?? "INBOX"
        guard !accountName.isEmpty else {
            throw EmailIMAPError.bridgeFailed("Invalid email.attachment arguments: 'account' must not be empty.")
        }
        guard !messageID.isEmpty else {
            throw EmailIMAPError.bridgeFailed("Invalid email.attachment arguments: 'id' must not be empty.")
        }
        try EmailIMAPValidation.validateMessageID(messageID)
        try EmailIMAPValidation.validateAttachmentIndex(attachmentIndex)
        try EmailIMAPValidation.validateMailbox(mailbox)
        return AttachmentTarget(accountName: accountName, messageID: messageID, attachmentIndex: attachmentIndex, mailbox: mailbox, preview: args.preview)
    }

    /// Resolves the configured account by exact then case-insensitive name.
    /// - Parameter accountName: Trimmed account nickname.
    /// - Returns: Matching account.
    /// - Throws: `EmailIMAPError.unknownAccount` when no account matches.
    private func resolvedAccount(named accountName: String) throws -> EmailAccount {
        if let account = emailConfig.account(matching: accountName) {
            return account
        }
        throw EmailIMAPError.unknownAccount(name: accountName, available: emailConfig.accounts.map(\.name))
    }

    /// Resolves the requested mailbox against the selectable list.
    ///
    /// Reuses the found mailbox so fan-out hits stay openable with a clear
    /// unknown-folder error; folder names are never assumed so an empty
    /// `LIST` result throws a no-selectable-mailboxes failure instead of
    /// synthesizing `INBOX`. Every value — explicit or the legacy-default `INBOX`
    /// for omitted or blank — is validated via `LIST` plus `resolveMailboxAgainstList`
    /// (exact-first with a case-insensitive fallback) so `INBOX` and `inbox`
    /// behave identically.
    /// - Parameters:
    ///   - credentials: Already-resolved credentials for the `LIST` lookup.
    ///   - requested: Trimmed requested mailbox (`INBOX` for the legacy default).
    /// - Returns: Canonical mailbox name.
    /// - Throws: Unknown-mailbox failure when the folder is not selectable.
    private func resolvedMailbox(credentials: ResolvedEmailCredentials, requested: String) async throws -> String {
        let listed = try await gateway.listMailboxes(credentials: credentials)
        let available = EmailBridgeParsing.selectableMailboxes(from: listed.map { name in (flags: "", mailbox: name) })
        return try EmailBridgeParsing.resolveMailboxAgainstList(requested: requested, available: available)
    }

    /// Fetches attachment bytes through the gateway with shared credentials.
    /// - Parameters:
    ///   - credentials: Already-resolved credentials shared with mailbox resolution.
    ///   - mailbox: Canonical mailbox holding the message.
    ///   - messageID: Trimmed message identifier.
    ///   - index: Zero-based attachment position.
    /// - Returns: Downloaded bytes.
    private func fetchedAttachment(
        credentials: ResolvedEmailCredentials,
        mailbox: String,
        messageID: String,
        index: Int
    ) async throws -> EmailAttachmentData {
        try await gateway.attachment(
            credentials: credentials,
            mailbox: mailbox,
            messageID: messageID,
            attachmentIndex: index
        )
    }

    /// Encodes an attachment envelope as a success result.
    /// - Parameters:
    ///   - envelope: Envelope to encode.
    ///   - callID: Correlation identifier.
    /// - Returns: Success result, or a failure when encoding fails.
    private func successEnvelope(_ envelope: EmailAttachmentEnvelope, callID: String) -> ToolOutput {
        do {
            let content = try EmailBridgeParsing.encodeAttachmentEnvelope(envelope)
            return .success(content, callID: callID)
        } catch {
            return .failure(error.localizedDescription, callID: callID)
        }
    }

    /// Builds the skip result for a part over the size cap.
    /// - Parameters:
    ///   - target: Trimmed routing.
    ///   - accountName: Resolved account name for the envelope.
    ///   - fetched: Downloaded metadata for the skipped part.
    ///   - callID: Correlation identifier.
    /// - Returns: Success envelope with the skip note.
    private func oversizedEnvelope(
        target: AttachmentTarget,
        accountName: String,
        fetched: EmailAttachmentData,
        callID: String
    ) -> ToolOutput {
        let note = Self.oversizeNote(sizeBytes: fetched.sizeBytes)
        let envelope = EmailAttachmentEnvelope(
            account: accountName,
            id: target.messageID,
            index: target.attachmentIndex,
            filename: fetched.filename,
            contentType: fetched.contentType,
            sizeBytes: fetched.sizeBytes,
            path: nil,
            skipped: true,
            note: note,
            mailbox: target.mailbox
        )
        return successEnvelope(envelope, callID: callID)
    }

    /// Resolves the sandbox-confined destination for a download.
    /// - Parameters:
    ///   - target: Trimmed routing.
    ///   - accountName: Resolved account name for the file prefix.
    ///   - filename: Original attachment filename.
    /// - Returns: Destination under the staging area.
    private func stagedDestinationURL(
        target: AttachmentTarget,
        accountName: String,
        filename: String
    ) throws -> URL {
        try Self.stagedDestination(
            stagingPath: sandboxConfig.stagingPath,
            account: accountName,
            messageID: target.messageID,
            index: target.attachmentIndex,
            filename: filename
        )
    }

    /// Builds the dry-run result without writing any bytes.
    ///
    /// Keeps `path` nil per the `EmailAttachmentEnvelope` contract (`path`
    /// is nil when skipped); the would-be staging path is reported in the
    /// note instead so no caller mistakes a dry run for a staged file.
    /// - Parameters:
    ///   - target: Trimmed routing.
    ///   - accountName: Resolved account name for the envelope.
    ///   - fetched: Downloaded metadata.
    ///   - destination: Staging path that would have been written.
    ///   - callID: Correlation identifier.
    /// - Returns: Success envelope with the dry-run note.
    private func dryRunEnvelope(
        target: AttachmentTarget,
        accountName: String,
        fetched: EmailAttachmentData,
        destination: URL,
        callID: String
    ) -> ToolOutput {
        let envelope = EmailAttachmentEnvelope(
            account: accountName,
            id: target.messageID,
            index: target.attachmentIndex,
            filename: fetched.filename,
            contentType: fetched.contentType,
            sizeBytes: fetched.sizeBytes,
            path: nil,
            skipped: true,
            note: "Dry run: would save to \(destination.path) without downloading.",
            mailbox: target.mailbox
        )
        return successEnvelope(envelope, callID: callID)
    }

    /// Stages bytes under the sandbox and builds the success result.
    ///
    /// Attaches the post-download lifecycle (expiry from the sandbox
    /// retention window, coarse MIME bucket, `files.read` follow-up hint,
    /// and the guarded inline preview) so the model can act on the staged
    /// file without a second round trip. Oversized and dry-run skips keep
    /// the legacy shape with no lifecycle keys.
    /// - Parameters:
    ///   - target: Trimmed routing (including the caller's `preview` request).
    ///   - accountName: Resolved account name for the envelope.
    ///   - fetched: Downloaded bytes to stage.
    ///   - destination: Sandbox-confined file URL.
    ///   - callID: Correlation identifier.
    /// - Returns: Success envelope with the staged path and lifecycle hints, or a staging failure.
    private func storedEnvelope(
        target: AttachmentTarget,
        accountName: String,
        fetched: EmailAttachmentData,
        destination: URL,
        callID: String
    ) -> ToolOutput {
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fetched.data.write(to: destination, options: .atomic)
        } catch {
            return .failure("Could not stage attachment: \(error.localizedDescription)", callID: callID)
        }
        let category = EmailAttachmentLifecycle.mimeCategory(for: fetched.contentType)
        let expiry = EmailAttachmentLifecycle.expiryString(
            from: EmailAttachmentLifecycle.expiryDate(retentionDays: sandboxConfig.retentionDays)
        )
        // Inline previews stay strictly opt-in and text-only: binaries never
        // inline even when the flag is set, and oversized text stays out so
        // a preview request cannot balloon the tool output.
        var previewText: String?
        var previewWasTruncated: Bool?
        if target.preview,
           EmailAttachmentLifecycle.isPreviewable(
               contentType: fetched.contentType,
               sizeBytes: fetched.sizeBytes,
               dataCount: fetched.data.count
           ),
           let inline = EmailAttachmentLifecycle.inlinePreview(for: fetched.data)
        {
            previewText = inline.text
            previewWasTruncated = inline.truncated ? true : false
        }
        let hint = EmailAttachmentLifecycle.nextStepsHint(
            path: destination.path,
            expiresAt: expiry,
            mimeCategory: category,
            previewTruncated: previewWasTruncated
        )
        let envelope = EmailAttachmentEnvelope(
            account: accountName,
            id: target.messageID,
            index: target.attachmentIndex,
            filename: fetched.filename,
            contentType: fetched.contentType,
            sizeBytes: fetched.sizeBytes,
            path: destination.path,
            skipped: false,
            note: nil,
            mailbox: target.mailbox,
            expiresAt: expiry,
            mimeCategory: category,
            nextSteps: hint,
            preview: previewText,
            previewTruncated: previewText == nil ? nil : previewWasTruncated
        )
        return successEnvelope(envelope, callID: callID)
    }
}

/// Factory registering the email tools on a `ToolBus`.
///
/// Search and read stay `readOnly` while attachment downloads and
/// sending are `requiresApproval` so the graduated-trust gate prompts
/// before any file is staged or message leaves the machine. All tools
/// integrate with `EmailCredentialResolver` (environment first, Keychain
/// service `com.runeweaver.secrets` second) so passwords never live in
/// `config.toml` and never reach the LLM prompt. Verified live against
/// Volcrypt IMAP (`mail.volcrypt.com:993`, account `volcrypt` via
/// `EMAIL_VOLCRYPT_PASSWORD`) and iCloud IMAP
/// (`imap.mail.me.com:993`, account `icloud` via the
/// `EMAIL_ICLOUD_PASSWORD` app-specific password) read-only with
/// verified TLS; attachment bytes stage under the sandbox staging
/// area only. Sending uses verified SMTP submission (explicit overrides
/// or 587 STARTTLS then 465 SSL) with the sender defaulting to the
/// account username, sandbox-confined attachments, threaded replies,
/// and a best-effort Sent copy.
public enum EmailTools {
    /// Tool names in registration order.
    public static let toolNames = ["email.search", "email.read", "email.attachment", "email.send"]

    /// Builds the email tools for an email config.
    /// - Parameters:
    ///   - emailConfig: Decoded `[email]` section.
    ///   - gateway: Shared IMAP gateway. Defaults to the `python3` subprocess bridge.
    ///   - smtpGateway: Shared SMTP gateway for `email.send`. Defaults to the `python3` subprocess bridge.
    ///   - sandboxConfig: Sandbox staging configuration for `email.attachment` downloads and `email.send` attachments.
    /// - Returns: Search, read, attachment, and send tools in registration order.
    public static func makeTools(
        emailConfig: EmailConfig,
        gateway: (any EmailIMAPGateway)? = nil,
        smtpGateway: (any EmailSMTPGateway)? = nil,
        sandboxConfig: SandboxConfig = SandboxConfig()
    ) -> [any Tool] {
        let shared: any EmailIMAPGateway = gateway ?? SubprocessIMAPGateway()
        let sharedSMTP: any EmailSMTPGateway = smtpGateway ?? SubprocessSMTPGateway()
        let search: any Tool = EmailSearchTool(emailConfig: emailConfig, gateway: shared)
        let read: any Tool = EmailReadTool(emailConfig: emailConfig, gateway: shared)
        let attachment: any Tool = EmailAttachmentTool(
            emailConfig: emailConfig,
            gateway: shared,
            sandboxConfig: sandboxConfig
        )
        let send: any Tool = EmailSendTool(
            emailConfig: emailConfig,
            smtpGateway: sharedSMTP,
            gateway: shared,
            sandboxConfig: sandboxConfig
        )
        return [search, read, attachment, send]
    }

    /// Registers the email tools, replacing same-named entries.
    /// - Parameters:
    ///   - bus: Bus receiving the tools (surfaced via `status`).
    ///   - emailConfig: Decoded `[email]` section.
    ///   - gateway: Shared IMAP gateway. Defaults to the `python3` subprocess bridge.
    ///   - smtpGateway: Shared SMTP gateway for `email.send`. Defaults to the `python3` subprocess bridge.
    ///   - sandboxConfig: Sandbox staging configuration for `email.attachment` downloads and `email.send` attachments.
    public static func register(
        on bus: ToolBus,
        emailConfig: EmailConfig,
        gateway: (any EmailIMAPGateway)? = nil,
        smtpGateway: (any EmailSMTPGateway)? = nil,
        sandboxConfig: SandboxConfig = SandboxConfig()
    ) async {
        for tool in makeTools(emailConfig: emailConfig, gateway: gateway, smtpGateway: smtpGateway, sandboxConfig: sandboxConfig) {
            await bus.register(tool: tool)
        }
    }
}

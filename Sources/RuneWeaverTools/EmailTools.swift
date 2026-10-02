// Rune Weaver Tools — Email search, read, attachment, send, mailbox listing, and move tools.

import Foundation
import RuneWeaverCore

/// Read-only `email.search` tool over IMAP.
public struct EmailSearchTool: Tool, Sendable {
    /// Stable tool name referenced by the LLM and memory.
    public let name = "email.search"
    /// When the LLM should use this tool.
    public let description =
        "Searches IMAP mailboxes (subject, sender, and body) across every selectable folder by default. "
            + "Use when the user asks to find or summarize email. "
            + "Use query \"*\" or empty for the most-recent messages. "
            + "Pass mailbox to narrow to one folder; each hit labels its mailbox for email.read. "
            + "Pass hasAttachment (true/false) to filter for messages with or without attachments. "
            + "Pass since/until as YYYY-MM-DD local-day or full ISO8601 datetimes to bound the window (since inclusive, until exclusive). "
            + "Attachment filtering scans the newest candidates first (up to five times the requested limit, minimum fifty per mailbox), "
            + "so older matches outside that newest window are not returned. "
            + "Returns matching message ids, headers, snippets, and mailboxes."
    /// Function-calling contract for `account`, `query`, `limit`, `mailbox`, `since`, and `until`.
    public let inputSchema =
        JSONSchema(
            rawValue: """
            {
              "type": "object",
              "properties": {
                "account": {
                  "type": "string",
                  "description": "Account nickname from [email.accounts] (e.g. volcrypt, icloud)"
                },
                "query": {
                  "type": "string",
                  "description": "Free-text query matched against subject, sender, and body; * or empty lists most-recent messages"
                },
                "limit": {
                  "type": "integer",
                  "description": "Maximum hits (1-50, default 10)",
                  "minimum": 1,
                  "maximum": 50
                },
                "mailbox": {
                  "type": "string",
                  "description": "Optional folder to search (e.g. INBOX, Sent); omitted or blank searches every selectable mailbox"
                },
                "hasAttachment": {
                  "type": "boolean",
                  "description": "Optional filter: true for messages with attachments, false for messages without"
                },
                "since": {
                  "type": "string",
                  "description": "Optional inclusive lower bound YYYY-MM-DD local-day or full ISO8601 datetime"
                },
                "until": {
                  "type": "string",
                  "description": "Optional exclusive upper bound YYYY-MM-DD local-day or full ISO8601 datetime"
                }
              },
              "required":["account","query"],
              "additionalProperties": false
            }
            """
        )
    /// Always allowed: search never changes mailbox state.
    public let permissionLevel = PermissionLevel.readOnly
    /// Network-derived bytes may carry injected directives, so results enter as labeled data.
    public var contentTrustLevel: ContentTrustLevel {
        .untrustedExternal
    }

    /// Configured mail accounts.
    private let emailConfig: EmailConfig
    /// IMAP gateway (subprocess bridge by default, stub in tests).
    private let gateway: any EmailIMAPGateway
    /// Defense policy gating agent-visible credential redaction. Defaults on
    /// so stock installs never expose one-time codes or magic links.
    private let securityConfig: SecurityConfig

    /// Creates a search tool.
    public init(
        emailConfig: EmailConfig,
        gateway: (any EmailIMAPGateway)? = nil,
        securityConfig: SecurityConfig = SecurityConfig()
    ) {
        self.emailConfig = emailConfig
        self.gateway = gateway ?? SubprocessIMAPGateway()
        self.securityConfig = securityConfig
    }

    /// Runs the search, resolving credentials at execution time.
    public func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        // Smart raw pre-check plus decoded CR/LF validation before ANY account lookup or credential
        // resolution so invalid input reports "Invalid search query" even when the password is
        // missing. The encoded pre-check uses the same validation case and copy as the decoded
        // path below so one condition never surfaces as two distinct errors. Gateway validation
        // may still surface as either the current validation case or a legacy bridge case with
        // identical copy, so the chat path below surfaces gateway failures by localized copy
        // rather than matching on case and stays compatible with both without branching.
        if EmailIMAPValidation.containsEncodedCRLF(in: input.argumentsJSON) {
            return .failure(
                EmailIMAPError.validationFailed("Invalid search query: query must not contain CR or LF").localizedDescription,
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
        // Fail fast on decoded injection before touching accounts or credentials so invalid input
        // reports "Invalid search query" even when the password is missing. Checks the raw value
        // first (before trimming) to mirror the bridge, then the trimmed value.
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
        // Parse the temporal window before any credential resolution so malformed
        // bounds fail closed with the parse copy even when the password is missing.
        // Blank behaves as omitted inside TemporalFilter, and inversion rejects.
        let temporalRange: TemporalRange
        do {
            temporalRange = try TemporalFilter.parse(since: args.trimmedSince, until: args.trimmedUntil)
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
        let sinceDate = temporalRange.since
        let untilDate = temporalRange.until
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
        // Wildcard/empty maps to ALL: a trimmed empty query or a lone "*" lists the most-recent
        // messages instead of sending a literal TEXT "*" that matches nothing on iCloud
        // (imap.mail.me.com:993).
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
        // Gateway validation surfaces by localized copy so both the current validation case and
        // any legacy bridge case with identical copy read the same here; no case matching needed.
        do {
            if let requested = args.trimmedMailbox {
                return try await singleMailboxOutput(
                    account: account,
                    credentials: credentials,
                    requested: requested,
                    effectiveQuery: effectiveQuery,
                    limit: args.limit,
                    hasAttachment: args.hasAttachment,
                    since: sinceDate,
                    until: untilDate,
                    callID: input.callID
                )
            }
            return try await fanOutOutput(
                account: account,
                credentials: credentials,
                effectiveQuery: effectiveQuery,
                limit: args.limit,
                hasAttachment: args.hasAttachment,
                since: sinceDate,
                until: untilDate,
                callID: input.callID
            )
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
    }
}

extension EmailSearchTool {
    /// Reapplies the attachment filter locally so gateways that ignore it still honor the request.
    private func filteredByAttachment(_ hits: [EmailSearchHit], hasAttachment: Bool?) -> [EmailSearchHit] {
        hits.filter { $0.matches(hasAttachment: hasAttachment) }
    }

    /// Reapplies the temporal window locally so gateways returning day-granular
    /// IMAP hits still honor exact datetimes. Undated hits only survive an
    /// unbounded window; any bound drops unparseable dates fail-closed.
    private func filteredByTemporal(_ hits: [EmailSearchHit], since: Date?, until: Date?) -> [EmailSearchHit] {
        guard since != nil || until != nil else { return hits }
        let range = TemporalRange(since: since, until: until)
        return hits.filter { TemporalFilter.matches(date: EmailSearchMerge.date(of: $0), in: range) }
    }

    /// Searches one explicit mailbox with a clear unknown-folder error.
    private func singleMailboxOutput(
        account: EmailAccount,
        credentials: ResolvedEmailCredentials,
        requested: String,
        effectiveQuery: String,
        limit: Int,
        hasAttachment: Bool? = nil,
        since: Date? = nil,
        until: Date? = nil,
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
        let hits = try await gateway.search(
            credentials: credentials,
            mailbox: canonical,
            query: effectiveQuery,
            limit: limit,
            hasAttachment: hasAttachment,
            since: since,
            until: until
        )
        let labeled = filteredByTemporal(filteredByAttachment(hits, hasAttachment: hasAttachment), since: since, until: until).map {
            EmailSearchHit(
                id: $0.id,
                subject: $0.subject,
                from: $0.from,
                date: $0.date,
                snippet: $0.snippet,
                mailbox: canonical,
                hasAttachments: $0.hasAttachments,
                attachmentCount: $0.attachmentCount
            )
        }
        // Credential filter runs at the envelope boundary where agent-visible
        // content is built: headers stay visible while snippets redact. The
        // human inbox is untouched; only this tool output carries the filter.
        let visible = labeled.map {
            $0.agentVisible(credentialFilterEnabled: securityConfig.emailCredentialFilter)
        }
        let capped = Array(visible.prefix(limit))
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
    private func fanOutOutput(
        account: EmailAccount,
        credentials: ResolvedEmailCredentials,
        effectiveQuery: String,
        limit: Int,
        hasAttachment: Bool? = nil,
        since: Date? = nil,
        until: Date? = nil,
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
                let hits = try await gateway.search(
                    credentials: credentials,
                    mailbox: box,
                    query: effectiveQuery,
                    limit: limit,
                    hasAttachment: hasAttachment,
                    since: since,
                    until: until
                )
                let labeled = filteredByTemporal(filteredByAttachment(hits, hasAttachment: hasAttachment), since: since, until: until).map {
                    EmailSearchHit(
                        id: $0.id,
                        subject: $0.subject,
                        from: $0.from,
                        date: $0.date,
                        snippet: $0.snippet,
                        mailbox: box,
                        hasAttachments: $0.hasAttachments,
                        attachmentCount: $0.attachmentCount
                    )
                }
                // Same envelope-boundary redaction as the single-mailbox path
                // so fan-out hits cannot bypass the filter.
                groups.append(
                    labeled.map {
                        $0.agentVisible(credentialFilterEnabled: securityConfig.emailCredentialFilter)
                    }
                )
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
public struct EmailReadTool: Tool, Sendable {
    /// Stable tool name referenced by the LLM and memory.
    public let name = "email.read"
    /// When the LLM should use this tool.
    public let description =
        "Reads one email by id from an IMAP mailbox. "
            + "Use when the user asks to open or summarize a specific message. "
            + "Pass the mailbox labeled on the email.search hit (omitted means INBOX). "
            + "Returns headers plus the text body; attachments are listed with filename, MIME type, and byte size (use email.attachment to download)."
    /// Function-calling contract for `account`, `id`, and optional `mailbox`.
    /// Schema advertises only canonical keys; decoder tolerance for retired
    /// spellings stays out of the schema as intentional compatibility so strict
    /// validators and the decoder agree on what is advertised.
    public let inputSchema =
        JSONSchema(
            rawValue: """
            {
              "type": "object",
              "properties": {
                "account": {
                  "type": "string",
                  "description": "Account nickname from [email.accounts] (e.g. volcrypt, icloud)"
                },
                "id": {
                  "type": "string",
                  "description": "IMAP message id from email.search"
                },
                "mailbox": {
                  "type": "string",
                  "description": "Mailbox from the email.search hit (e.g. INBOX); omitted means INBOX"
                }
              },
              "required":["account","id"],
              "additionalProperties": false
            }
            """
        )
    /// Always allowed: reading never changes mailbox state.
    public let permissionLevel = PermissionLevel.readOnly
    /// Network-derived bytes may carry injected directives, so results enter as labeled data.
    public var contentTrustLevel: ContentTrustLevel {
        .untrustedExternal
    }

    /// Configured mail accounts.
    private let emailConfig: EmailConfig
    /// IMAP gateway (subprocess bridge by default, stub in tests).
    private let gateway: any EmailIMAPGateway
    /// Defense policy gating agent-visible credential redaction. Defaults on
    /// so stock installs never expose one-time codes or magic links.
    private let securityConfig: SecurityConfig

    /// Creates a read tool.
    public init(
        emailConfig: EmailConfig,
        gateway: (any EmailIMAPGateway)? = nil,
        securityConfig: SecurityConfig = SecurityConfig()
    ) {
        self.emailConfig = emailConfig
        self.gateway = gateway ?? SubprocessIMAPGateway()
        self.securityConfig = securityConfig
    }

    /// Reads one message, resolving credentials at execution time.
    public func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        // Decoded-only UID allowlisting happens after JSON decoding: the strict `^[0-9][0-9:,]*$`
        // check on the decoded id rejects real CR/LF (including "\\u000d" escapes decoded by the
        // JSON parser) before ANY account lookup or credential resolution, so invalid input reports...
        let args: EmailReadArgs
        do {
            args = try JSONDecoder().decode(EmailReadArgs.self, from: Data(input.argumentsJSON.utf8))
        } catch {
            return .failure("Invalid email.read arguments: expected {\"account\": \"<name>\", \"id\": \"<message-id>\"}.", callID: input.callID)
        }
        // Fail fast on allowlist before touching accounts or credentials so invalid input reports
        // "Invalid message id" even when the password is missing. Checks the raw value first, then
        // trimmed.
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
            // Reuse the found mailbox so fan-out hits stay openable.
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
            // Credential filter runs at the envelope boundary where
            // agent-visible content is built: headers stay visible while the
            // body redacts. The human inbox is untouched.
            let visible = message.agentVisible(credentialFilterEnabled: securityConfig.emailCredentialFilter)
            let content = try EmailBridgeParsing.encodeReadEnvelope(account: account.name, message: visible, mailbox: effectiveMailbox)
            return .success(content, callID: input.callID)
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
    }
}

/// Factory registering the email tools on a `ToolBus`.
public enum EmailTools {
    /// Tool names in registration order.
    public static let toolNames = ["email.search", "email.read", "email.attachment", "email.send", "email.listMailboxes", "email.move"]

    /// Builds the email tools for an email config.
    public static func makeTools(
        emailConfig: EmailConfig,
        gateway: (any EmailIMAPGateway)? = nil,
        smtpGateway: (any EmailSMTPGateway)? = nil,
        sandboxConfig: SandboxConfig = SandboxConfig(),
        filesConfig: FilesConfig = FilesConfig(),
        homeDirectoryURL: URL? = nil,
        archiveDetonator: (any EmailArchiveDetonator)? = nil,
        securityConfig: SecurityConfig = SecurityConfig()
    ) -> [any Tool] {
        let shared: any EmailIMAPGateway = gateway ?? SubprocessIMAPGateway()
        let sharedSMTP: any EmailSMTPGateway = smtpGateway ?? SubprocessSMTPGateway()
        let search: any Tool = EmailSearchTool(emailConfig: emailConfig, gateway: shared, securityConfig: securityConfig)
        let read: any Tool = EmailReadTool(emailConfig: emailConfig, gateway: shared, securityConfig: securityConfig)
        let attachment: any Tool = EmailAttachmentTool(
            emailConfig: emailConfig,
            gateway: shared,
            sandboxConfig: sandboxConfig,
            filesConfig: filesConfig,
            homeDirectoryURL: homeDirectoryURL,
            archiveDetonator: archiveDetonator
        )
        let send: any Tool = EmailSendTool(
            emailConfig: emailConfig,
            smtpGateway: sharedSMTP,
            gateway: shared,
            sandboxConfig: sandboxConfig
        )
        let listMailboxes: any Tool = EmailListMailboxesTool(emailConfig: emailConfig, gateway: shared)
        let move: any Tool = EmailMoveTool(emailConfig: emailConfig, gateway: shared)
        return [search, read, attachment, send, listMailboxes, move]
    }

    /// Registers the email tools, replacing same-named entries.
    public static func register(
        on bus: ToolBus,
        emailConfig: EmailConfig,
        gateway: (any EmailIMAPGateway)? = nil,
        smtpGateway: (any EmailSMTPGateway)? = nil,
        sandboxConfig: SandboxConfig = SandboxConfig(),
        filesConfig: FilesConfig = FilesConfig(),
        homeDirectoryURL: URL? = nil,
        archiveDetonator: (any EmailArchiveDetonator)? = nil,
        securityConfig: SecurityConfig = SecurityConfig()
    ) async {
        for tool in makeTools(
            emailConfig: emailConfig,
            gateway: gateway,
            smtpGateway: smtpGateway,
            sandboxConfig: sandboxConfig,
            filesConfig: filesConfig,
            homeDirectoryURL: homeDirectoryURL,
            archiveDetonator: archiveDetonator,
            securityConfig: securityConfig
        ) {
            await bus.register(tool: tool)
        }
    }
}

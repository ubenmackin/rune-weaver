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
    public init(emailConfig: EmailConfig, gateway: (any EmailIMAPGateway)? = nil) {
        self.emailConfig = emailConfig
        self.gateway = gateway ?? SubprocessIMAPGateway()
    }

    /// Runs the search, resolving credentials at execution time.
    public func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        // Smart raw pre-check plus decoded CR/LF validation before ANY account lookup or credential
        // resolution so invalid input reports "Invalid search query" even when the password is
        // missing.
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
    public init(emailConfig: EmailConfig, gateway: (any EmailIMAPGateway)? = nil) {
        self.emailConfig = emailConfig
        self.gateway = gateway ?? SubprocessIMAPGateway()
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
            let content = try EmailBridgeParsing.encodeReadEnvelope(account: account.name, message: message, mailbox: effectiveMailbox)
            return .success(content, callID: input.callID)
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
    }
}

/// `email.attachment` tool over IMAP.
public struct EmailAttachmentTool: Tool, Sendable {
    /// Stable tool name referenced by the LLM and memory.
    public let name = "email.attachment"
    /// When the LLM should use this tool.
    public let description =
        "Downloads one email attachment by index. "
            + "Use when the user asks to save or open an attachment listed by email.read. "
            + "Pass the mailbox labeled on the email.search hit (omitted means INBOX). "
            + "Documents and images stage under isolated temp with inline extracted text or vision payloads; "
            + "archives detonate in a zero-host-mounts ephemeral microVM returning only a manifest. "
            + "Pass preview true to inline the first 2000 chars for small text parts (binaries are never inlined); "
            + "pass subpath to inspect one file inside a detonated archive, or saveToPath for an approval-gated workspace export."
    /// Function-calling contract for `account`, `id`, `index`, `mailbox` (plus accepted aliases), `preview`, `subpath`, and `saveToPath`.
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
                + #"text parts (text/*, application/json under 256 KB); binaries are never inlined"},"#
                + #""subpath":{"type":"string","description":"Relative entry path inside a detonated archive to inspect"}, "#
                + #""saveToPath":{"type":"string","description":"Workspace destination for an approval-gated archive export"}}"#
                + #","required":["account"],"allOf":[{"anyOf":[{"required":["id"]},"#
                + #"{"required":["messageId"]},{"required":["message_id"]},{"required":["uid"]}]},"#
                + #"{"anyOf":[{"required":["index"]},{"required":["attachmentIndex"]},"#
                + #"{"required":["attachment_index"]}]} ],"additionalProperties":false}"#
        )
    /// Gated: downloads stage files and always prompt without a trust grant.
    public let permissionLevel = PermissionLevel.requiresApproval

    /// Maximum decoded bytes staged per attachment (10 MB).
    public static let maxAttachmentBytes = 10 * 1024 * 1024
    /// Maximum raw image bytes delivered inline as vision Base64 (1 MiB). Larger images stay staged/export-only so model context stays bounded.
    static let maxVisionBytes = 1 * 1024 * 1024
    /// Subdirectory of the isolated temp area holding downloaded attachments.
    public static let attachmentsSubdirectory = "attachments"

    /// Configured mail accounts.
    private let emailConfig: EmailConfig
    /// IMAP gateway (subprocess bridge by default, stub in tests).
    private let gateway: any EmailIMAPGateway
    /// Detonation policy for archive isolation. Document previews stay inline with bounded caps.
    private let sandboxConfig: SandboxConfig
    /// `[files]` policy guarding approval-gated archive exports. Defaults to the built-in defaults.
    private let filesConfig: FilesConfig
    /// Home boundary override forwarded to the guard. Nil means the real home.
    private let homeDirectoryURL: URL?
    /// Archive detonator (live microVM by default, stub in tests).
    private let archiveDetonator: any EmailArchiveDetonator

    /// Creates an attachment tool.
    public init(
        emailConfig: EmailConfig,
        gateway: (any EmailIMAPGateway)? = nil,
        sandboxConfig: SandboxConfig = SandboxConfig(),
        filesConfig: FilesConfig = FilesConfig(),
        homeDirectoryURL: URL? = nil,
        archiveDetonator: (any EmailArchiveDetonator)? = nil
    ) {
        self.emailConfig = emailConfig
        self.gateway = gateway ?? SubprocessIMAPGateway()
        self.sandboxConfig = sandboxConfig
        self.filesConfig = filesConfig
        self.homeDirectoryURL = homeDirectoryURL
        self.archiveDetonator = archiveDetonator ?? LiveEmailArchiveDetonator(
            containerRuntime: sandboxConfig.containerRuntime,
            containerBaseImage: sandboxConfig.containerBaseImage,
            maxConcurrentMachines: sandboxConfig.maxConcurrentMachines
        )
    }

    /// Downloads one attachment part, detonating archives in isolation.
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
                preview: target.preview,
                subpath: target.subpath,
                saveToPath: target.saveToPath
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
            if EmailAttachmentLifecycle.isArchive(contentType: fetched.contentType, filename: fetched.filename) {
                if context.dryRun {
                    return archiveDryRunEnvelope(
                        target: effectiveTarget,
                        accountName: account.name,
                        fetched: fetched,
                        callID: input.callID
                    )
                }
                return try await detonatedArchiveEnvelope(
                    target: effectiveTarget,
                    accountName: account.name,
                    fetched: fetched,
                    callID: input.callID
                )
            }
            if effectiveTarget.subpath != nil || effectiveTarget.saveToPath != nil {
                throw EmailIMAPError.bridgeFailed("Invalid email.attachment arguments: 'subpath' and 'saveToPath' are only valid for archives.")
            }
            let destination = try stagedDestinationURL(
                target: effectiveTarget,
                accountName: account.name,
                filename: fetched.filename
            )
            if context.dryRun {
                // A dry run only names the would-be path, so the per-request
                // temp created above is removed before reporting.
                let requestTemp = destination.deletingLastPathComponent().deletingLastPathComponent()
                SeatbeltTempStaging.discardTemp(at: requestTemp)
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
}

/// Trimmed attachment routing for `email.attachment`.
private struct AttachmentTarget {
    let accountName: String
    let messageID: String
    let attachmentIndex: Int
    let mailbox: String
    /// Whether the caller requested an inline text preview.
    let preview: Bool
    /// Validated relative entry path inside a detonated archive, if any.
    let subpath: String?
    /// Validated workspace export destination for a detonated archive, if any.
    let saveToPath: String?
}

extension EmailAttachmentTool {
    /// Decodes attachment arguments, rejecting bad ids and indexes early.
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
        if let rawSubpath = args.trimmedSubpath {
            _ = try EmailAttachmentLifecycle.validateArchiveSubpath(rawSubpath)
        }
        if let rawSaveToPath = args.trimmedSaveToPath {
            try Self.validateSaveToPathSyntax(rawSaveToPath)
        }
        return args
    }

    /// Trims and re-validates decoded attachment routing.
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
        var validatedSubpath: String?
        if let rawSubpath = args.trimmedSubpath {
            validatedSubpath = try EmailAttachmentLifecycle.validateArchiveSubpath(rawSubpath)
        }
        var validatedSaveToPath: String?
        if let rawSaveToPath = args.trimmedSaveToPath {
            try Self.validateSaveToPathSyntax(rawSaveToPath)
            let decision = FilesAccessGuard.evaluate(path: rawSaveToPath, homeDirectoryURL: homeDirectoryURL, filesConfig: filesConfig)
            guard decision.allowed else {
                throw EmailIMAPError.bridgeFailed(decision.reason ?? "Invalid saveToPath: path is not in the permitted workspace")
            }
            validatedSaveToPath = decision.resolvedPath
        }
        return AttachmentTarget(
            accountName: accountName,
            messageID: messageID,
            attachmentIndex: attachmentIndex,
            mailbox: mailbox,
            preview: args.preview,
            subpath: validatedSubpath,
            saveToPath: validatedSaveToPath
        )
    }

    /// Resolves the configured account by exact then case-insensitive name.
    private func resolvedAccount(named accountName: String) throws -> EmailAccount {
        if let account = emailConfig.account(matching: accountName) {
            return account
        }
        throw EmailIMAPError.unknownAccount(name: accountName, available: emailConfig.accounts.map(\.name))
    }

    /// Resolves the requested mailbox against the selectable list.
    private func resolvedMailbox(credentials: ResolvedEmailCredentials, requested: String) async throws -> String {
        let listed = try await gateway.listMailboxes(credentials: credentials)
        let available = EmailBridgeParsing.selectableMailboxes(from: listed.map { name in (flags: "", mailbox: name) })
        return try EmailBridgeParsing.resolveMailboxAgainstList(requested: requested, available: available)
    }

    /// Fetches attachment bytes through the gateway with shared credentials.
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
    private func successEnvelope(_ envelope: EmailAttachmentEnvelope, callID: String) -> ToolOutput {
        do {
            let content = try EmailBridgeParsing.encodeAttachmentEnvelope(envelope)
            return .success(content, callID: callID)
        } catch {
            return .failure(error.localizedDescription, callID: callID)
        }
    }

    /// Builds the skip result for a part over the size cap.
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

    /// Resolves the isolated-temp destination for a download.
    private func stagedDestinationURL(
        target: AttachmentTarget,
        accountName: String,
        filename: String
    ) throws -> URL {
        let requestTemp = try SeatbeltTempStaging.makeTempDirectory(prefix: "runeweaver-attachments-")
        do {
            try requireSeatbeltTempAllow(requestTemp)
            let base = requestTemp.appendingPathComponent(Self.attachmentsSubdirectory, isDirectory: true)
            try FileManager.default.createDirectory(
                at: base,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            return try Self.stagedDestination(
                stagingPath: requestTemp.path,
                account: accountName,
                messageID: target.messageID,
                index: target.attachmentIndex,
                filename: filename
            )
        } catch {
            SeatbeltTempStaging.discardTemp(at: requestTemp)
            throw error
        }
    }

    /// Fails closed unless the Seatbelt profile allows the staging temp.
    private func requireSeatbeltTempAllow(_ tempDir: URL) throws {
        let profile = SeatbeltProfileBuilder(allowedTempPaths: [tempDir.path]).buildProfile()
        guard profile.contains(tempDir.path) else {
            throw EmailIMAPError.bridgeFailed("Attachment staging confined temp rejected by Seatbelt profile")
        }
    }

    /// Builds the dry-run result without writing any bytes.
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

    /// Stages document and image bytes under Seatbelt-confined isolated temp and builds the success result.
    /// Staged bytes arrive from the IMAP gateway into isolated temp, never from
    /// a workspace read, so no descriptor pinning applies; workspace exports
    /// take the guarded staging path instead.
    private func storedEnvelope(
        target: AttachmentTarget,
        accountName: String,
        fetched: EmailAttachmentData,
        destination: URL,
        callID: String
    ) -> ToolOutput {
        do {
            // The destination already sits inside a per-request temp from `stagedDestinationURL`;
            // re-assert the Seatbelt allow here so a relocated path fails closed instead of writing
            // outside cover. Staged bytes stay readable and writable but never executable.
            let requestTemp = destination.deletingLastPathComponent().deletingLastPathComponent()
            try requireSeatbeltTempAllow(requestTemp)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fetched.data.write(to: destination, options: .atomic)
        } catch {
            let requestTemp = destination.deletingLastPathComponent().deletingLastPathComponent()
            SeatbeltTempStaging.discardTemp(at: requestTemp)
            return .failure("Could not stage attachment: \(error.localizedDescription)", callID: callID)
        }
        let category = EmailAttachmentLifecycle.mimeCategory(for: fetched.contentType)
        let expiry = EmailAttachmentLifecycle.expiryString(
            from: EmailAttachmentLifecycle.expiryDate(retentionDays: EmailAttachmentLifecycle.defaultRetentionDays)
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
        var extractedText: String?
        var imageDataBase64: String?
        var inlineNote: String?
        if category == "text" {
            if let capped = Self.cappedExtractedText(for: fetched.data) {
                extractedText = capped.text
                if capped.truncated {
                    inlineNote = "Extracted text truncated to \(EmailAttachmentLifecycle.maxPreviewChars) chars; "
                        + "use files.read with path \"\(destination.path)\" for the full text."
                }
            }
        } else if category == "image" {
            if let vision = Self.cappedVisionBase64(for: fetched.data) {
                imageDataBase64 = vision
            } else {
                inlineNote = "Image omitted from inline vision payload (over \(Self.maxVisionBytes) bytes); "
                    + "use files.read with path \"\(destination.path)\" to inspect it."
            }
        }

        let hint = EmailAttachmentLifecycle.nextStepsHint(
            path: destination.path,
            expiresAt: expiry,
            mimeCategory: category,
            previewTruncated: previewWasTruncated,
            archiveSessionId: nil
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
            note: inlineNote,
            mailbox: target.mailbox,
            expiresAt: expiry,
            mimeCategory: category,
            nextSteps: hint,
            preview: previewText,
            previewTruncated: previewText == nil ? nil : previewWasTruncated,
            extractedText: extractedText,
            imageDataBase64: imageDataBase64,
            archiveSessionId: nil,
            archiveManifest: nil,
            subpath: nil
        )
        return successEnvelope(envelope, callID: callID)
    }

    /// Builds the dry-run result for an archive without spawning a machine.
    private func archiveDryRunEnvelope(
        target: AttachmentTarget,
        accountName: String,
        fetched: EmailAttachmentData,
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
            note: "Dry run: would detonate archive in an isolated microVM without staging to the host.",
            mailbox: target.mailbox
        )
        return successEnvelope(envelope, callID: callID)
    }

    /// Detonates an archive in an ephemeral microVM and builds the manifest result.
    private func detonatedArchiveEnvelope(
        target: AttachmentTarget,
        accountName: String,
        fetched: EmailAttachmentData,
        callID: String
    ) async throws -> ToolOutput {
        let result = try await archiveDetonator.detonate(
            filename: fetched.filename,
            contentType: fetched.contentType,
            data: fetched.data,
            subpath: target.subpath
        )
        var extractedText: String?
        var imageDataBase64: String?
        var inlineNote: String?
        if let subpath = target.subpath {
            guard let entryData = result.entryData else {
                throw EmailIMAPError.bridgeFailed("Invalid subpath: entry not found in archive")
            }
            guard entryData.count <= Self.maxAttachmentBytes else {
                throw EmailIMAPError.bridgeFailed(Self.oversizeNote(sizeBytes: entryData.count))
            }
            let entryCategory = EmailAttachmentLifecycle.archiveEntryCategory(forPath: subpath)
            if entryCategory == "image" {
                if let vision = Self.cappedVisionBase64(for: entryData) {
                    imageDataBase64 = vision
                } else {
                    inlineNote = "Image entry omitted from inline vision payload (over \(Self.maxVisionBytes) bytes); use 'saveToPath' to export it."
                }
            } else if let capped = Self.cappedExtractedText(for: entryData) {
                extractedText = capped.text
                if capped.truncated {
                    inlineNote = "Extracted text truncated to \(EmailAttachmentLifecycle.maxPreviewChars) chars; use 'saveToPath' to export the full entry."
                }
            }
        }
        var exportedPath: String?
        if let saveToPath = target.saveToPath {
            exportedPath = try exportArchiveBytes(
                for: target,
                fetched: fetched,
                entryData: result.entryData,
                saveToPath: saveToPath
            )
        }
        // Workspace exports carry no staging expiry, so the session hint is
        // built pathless (avoiding an empty "expires" tail) with the export
        // destination prepended when present.
        let sessionHint = EmailAttachmentLifecycle.nextStepsHint(
            path: nil,
            expiresAt: nil,
            mimeCategory: "archive",
            previewTruncated: nil,
            archiveSessionId: result.sessionId
        )
        let hint = exportedPath.map { "Exported to \"\($0)\". \(sessionHint)" } ?? sessionHint
        var notes: [String] = []
        if result.manifestTruncated {
            notes.append("Archive manifest truncated to \(EmailAttachmentLifecycle.maxArchiveManifestEntries) entries; narrow with 'subpath'.")
        }
        if let inlineNote {
            notes.append(inlineNote)
        }
        let envelope = EmailAttachmentEnvelope(
            account: accountName,
            id: target.messageID,
            index: target.attachmentIndex,
            filename: fetched.filename,
            contentType: fetched.contentType,
            sizeBytes: fetched.sizeBytes,
            path: exportedPath,
            skipped: false,
            note: notes.isEmpty ? nil : notes.joined(separator: " "),
            mailbox: target.mailbox,
            expiresAt: nil,
            mimeCategory: "archive",
            nextSteps: hint,
            preview: nil,
            previewTruncated: nil,
            extractedText: extractedText,
            imageDataBase64: imageDataBase64,
            archiveSessionId: result.sessionId,
            archiveManifest: result.manifest,
            subpath: target.subpath
        )
        return successEnvelope(envelope, callID: callID)
    }

    /// Exports detonated archive bytes through confined-temp staging.
    /// Bytes originate from the isolated detonation, not a workspace read, so
    /// no descriptor pinning applies on the source; the workspace contact is a
    /// guarded write that re-validates the destination before committing, while
    /// pinned workspace reads stay single-use in the file tools.
    private func exportArchiveBytes(
        for target: AttachmentTarget,
        fetched: EmailAttachmentData,
        entryData: Data?,
        saveToPath: String
    ) throws -> String {
        let bytesToWrite: Data
        if target.subpath != nil {
            guard let entryData else {
                throw EmailIMAPError.bridgeFailed("Invalid subpath: entry not found in archive")
            }
            bytesToWrite = entryData
        } else {
            bytesToWrite = fetched.data
        }
        guard bytesToWrite.count <= Self.maxAttachmentBytes else {
            throw EmailIMAPError.bridgeFailed(Self.oversizeNote(sizeBytes: bytesToWrite.count))
        }
        let stagingDir = try SeatbeltTempStaging.makeTempDirectory(prefix: "runeweaver-attachments-")
        defer { SeatbeltTempStaging.discardTemp(at: stagingDir) }
        try requireSeatbeltTempAllow(stagingDir)
        let staged: URL
        do {
            staged = try SeatbeltTempStaging.stageBytes(bytesToWrite, filename: fetched.filename, in: stagingDir)
        } catch {
            throw EmailIMAPError.bridgeFailed("Could not export archive entry: \(error.localizedDescription)")
        }
        do {
            return try SeatbeltTempStaging.atomicMoveTempFile(
                at: staged,
                to: saveToPath,
                homeDirectoryURL: homeDirectoryURL,
                filesConfig: filesConfig
            )
        } catch let staging as SeatbeltTempStaging.StagingError {
            throw EmailIMAPError.bridgeFailed(staging.message)
        } catch {
            throw EmailIMAPError.bridgeFailed("Could not export archive entry: \(error.localizedDescription)")
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
        archiveDetonator: (any EmailArchiveDetonator)? = nil
    ) -> [any Tool] {
        let shared: any EmailIMAPGateway = gateway ?? SubprocessIMAPGateway()
        let sharedSMTP: any EmailSMTPGateway = smtpGateway ?? SubprocessSMTPGateway()
        let search: any Tool = EmailSearchTool(emailConfig: emailConfig, gateway: shared)
        let read: any Tool = EmailReadTool(emailConfig: emailConfig, gateway: shared)
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
        archiveDetonator: (any EmailArchiveDetonator)? = nil
    ) async {
        for tool in makeTools(
            emailConfig: emailConfig,
            gateway: gateway,
            smtpGateway: smtpGateway,
            sandboxConfig: sandboxConfig,
            filesConfig: filesConfig,
            homeDirectoryURL: homeDirectoryURL,
            archiveDetonator: archiveDetonator
        ) {
            await bus.register(tool: tool)
        }
    }
}

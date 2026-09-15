// Rune Weaver Tools — Email search, read, attachment, and send tools.
//
// Provides the `email.search`, `email.read`, `email.attachment`, and
// `email.send` plugin tools over the `python3 imaplib`/`smtplib` bridges
// with read-only fetches, staged sandbox downloads for documents and
// images, zero-host-mounts microVM detonation for archives, approval-gated
// sending and archive exports, and execution-time credential resolution.

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

/// Result of detonating one archive inside an isolated microVM.
///
/// Carries only the session correlation id, the entry manifest, and the
/// raw bytes of a single inspected entry when requested. Archive bytes
/// themselves never cross back except through the single inspected entry
/// or an explicit approval-gated export handled by the tool.
public struct EmailArchiveDetonationResult: Sendable, Equatable {
    /// Ephemeral detonation correlation id (`runeweaver-session-<uuid>`).
    public let sessionId: String
    /// Entries listed inside the archive, truncated to the manifest cap.
    public let manifest: [EmailArchiveEntry]
    /// Whether the manifest was truncated at the entry cap.
    public let manifestTruncated: Bool
    /// Raw bytes of the inspected subpath entry, when requested.
    public let entryData: Data?

    /// Creates a detonation result.
    public init(sessionId: String, manifest: [EmailArchiveEntry], manifestTruncated: Bool = false, entryData: Data? = nil) {
        self.sessionId = sessionId
        self.manifest = manifest
        self.manifestTruncated = manifestTruncated
        self.entryData = entryData
    }
}

/// Isolates archive inspection inside a zero-host-mounts microVM.
///
/// Production spawns an ephemeral container machine per archive with no
/// filesystem mounts, unpacks and lists inside via `run`, and reaps the
/// machine immediately; the TTL sweeper remains the safety net for
/// crashes. Tests inject a stub so no container runtime is required.
public protocol EmailArchiveDetonator: Sendable {
    /// Detonates archive bytes and optionally extracts one entry.
    /// - Parameters:
    ///   - filename: Original attachment filename for format hints.
    ///   - contentType: Raw MIME type for format hints.
    ///   - data: Raw archive bytes (already capped at the attachment limit).
    ///   - subpath: Validated relative entry path to extract, if any.
    /// - Returns: Session id, manifest, and optional entry bytes.
    func detonate(filename: String, contentType: String, data: Data, subpath: String?) async throws -> EmailArchiveDetonationResult
}

/// Ephemeral microVM detonator backed by the container machine manager.
///
/// Each call owns its machine lifetime: create with the configured base
/// image and runtime (the manager exposes no mount options, so guests
/// start with zero host mounts on an internal virtual disk), stream the
/// archive bytes over stdin for listing and optional extraction, then
/// best-effort stop and delete. Sessions are never reused across calls:
/// every detonation is ephemeral and reaped immediately, with the TTL prune
/// as the safety net only for machines orphaned by crashes. Concurrency is
/// capped before spawn so a burst of archives fails closed instead of
/// oversubscribing the host. Failures fail closed without staging
/// anything to the host; cleanup errors are swallowed so the original
/// detonation failure (never archive bytes or secrets) is what surfaces.
public struct LiveEmailArchiveDetonator: EmailArchiveDetonator, Sendable {
    /// Container CLI runtime name or path.
    public let containerRuntime: String
    /// OCI base image for detonation guests.
    public let containerBaseImage: String
    /// Maximum concurrent detonation machines, enforced before spawn.
    public let maxConcurrentMachines: Int

    /// Creates a live detonator.
    /// - Parameters:
    ///   - containerRuntime: Container CLI runtime name or path.
    ///   - containerBaseImage: OCI base image for detonation guests.
    ///   - maxConcurrentMachines: Cap on concurrent detonation machines, enforced before spawn.
    public init(
        containerRuntime: String = SandboxConfig.defaultContainerRuntime,
        containerBaseImage: String = SandboxConfig.defaultContainerBaseImage,
        maxConcurrentMachines: Int = SandboxConfig.defaultMaxConcurrentMachines
    ) {
        self.containerRuntime = containerRuntime
        self.containerBaseImage = containerBaseImage
        self.maxConcurrentMachines = maxConcurrentMachines
    }

    /// Detonates archive bytes in a fresh ephemeral machine.
    /// - Parameters:
    ///   - filename: Original attachment filename for format hints.
    ///   - contentType: Raw MIME type (unused beyond hints; listing probes formats inside the guest).
    ///   - data: Raw archive bytes.
    ///   - subpath: Validated relative entry path to extract, if any.
    /// - Returns: Session id, manifest, and optional entry bytes.
    public func detonate(filename: String, contentType _: String, data: Data, subpath: String?) async throws -> EmailArchiveDetonationResult {
        let sessionId = "runeweaver-session-\(UUID().uuidString.lowercased())"
        try await enforceConcurrencyLimit()
        try await ContainerMachineManager.createMachine(name: sessionId, image: containerBaseImage, runtime: containerRuntime)
        do {
            let listing = try await ContainerMachineManager.run(
                machineName: sessionId,
                command: ["sh", "-c", Self.listScript],
                runtime: containerRuntime,
                inputData: data
            )
            guard listing.exitCode == 0 else {
                throw EmailIMAPError.bridgeFailed("Could not inspect archive '\(filename)': unsupported or corrupt archive")
            }
            let parsed = EmailArchiveListingParser.parseListOutput(listing.stdoutString, filename: filename)
            guard !parsed.isEmpty else {
                throw EmailIMAPError.bridgeFailed("Could not inspect archive '\(filename)': unsupported or corrupt archive")
            }
            let capped = Array(parsed.prefix(EmailAttachmentLifecycle.maxArchiveManifestEntries))
            let truncated = parsed.count > capped.count
            var entryData: Data?
            if let subpath {
                guard capped.contains(where: { $0.path == subpath }) || parsed.contains(where: { $0.path == subpath }) else {
                    throw EmailIMAPError.bridgeFailed("Invalid subpath: entry not found in archive")
                }
                if let known = (parsed.first(where: { $0.path == subpath }))?.sizeBytes, known > EmailAttachmentTool.maxAttachmentBytes {
                    throw EmailIMAPError.bridgeFailed(EmailAttachmentTool.oversizeNote(sizeBytes: known))
                }
                let extracted = try await ContainerMachineManager.run(
                    machineName: sessionId,
                    command: ["sh", "-c", Self.extractScript, "sh", subpath],
                    runtime: containerRuntime,
                    inputData: data
                )
                guard extracted.exitCode == 0 else {
                    throw EmailIMAPError.bridgeFailed("Invalid subpath: entry not found in archive")
                }
                guard extracted.stdout.count <= EmailAttachmentTool.maxAttachmentBytes else {
                    throw EmailIMAPError.bridgeFailed(EmailAttachmentTool.oversizeNote(sizeBytes: extracted.stdout.count))
                }
                entryData = extracted.stdout
            }
            await Self.bestEffortReap(name: sessionId, runtime: containerRuntime)
            return EmailArchiveDetonationResult(sessionId: sessionId, manifest: capped, manifestTruncated: truncated, entryData: entryData)
        } catch {
            await Self.bestEffortReap(name: sessionId, runtime: containerRuntime)
            throw error
        }
    }

    /// Guest script listing archive entries from stdin bytes.
    ///
    /// Streams stdin to a scratch file, then probes ZIP before TAR so a
    /// mislabeled archive still lists; every probe is quiet so only the
    /// successful listing reaches stdout. No caller input is interpolated:
    /// the script is fixed text, keeping subpath payloads out of shell parsing.
    private static var listScript: String {
        "cat > /tmp/payload.bin; "
            + "if command -v unzip >/dev/null 2>&1; then "
            + "if unzip -l /tmp/payload.bin 2>/dev/null; then exit 0; fi; fi; "
            + "if tar -tzvf /tmp/payload.bin 2>/dev/null; then exit 0; fi; "
            + "if tar -tvf /tmp/payload.bin 2>/dev/null; then exit 0; fi; "
            + "echo UNSUPPORTED_ARCHIVE >&2; exit 1"
    }

    /// Guest script extracting one argv-passed entry from stdin bytes.
    ///
    /// The entry arrives as `$1` (never interpolated into shell text) and is
    /// always referenced behind `--` so leading dashes cannot parse as flags.
    /// ZIP is probed before TAR for the same mislabeling reason as listing.
    private static var extractScript: String {
        "cat > /tmp/payload.bin; entry=\"$1\"; "
            + "if command -v unzip >/dev/null 2>&1; then "
            + "if unzip -p /tmp/payload.bin -- \"$entry\" 2>/dev/null; then exit 0; fi; fi; "
            + "if tar -xzOf /tmp/payload.bin -- \"$entry\" 2>/dev/null; then exit 0; fi; "
            + "if tar -xOf /tmp/payload.bin -- \"$entry\" 2>/dev/null; then exit 0; fi; "
            + "exit 1"
    }

    /// Stops and deletes a detonation machine without masking the caller error.
    ///
    /// Ephemeral machines are reaped immediately after listing/extraction so
    /// no detonation VM outlives its call; the periodic TTL prune stays
    /// the safety net only for crashes between create and reap. There is no
    /// warm-session reuse across calls.
    /// - Parameters:
    ///   - name: Machine to reap.
    ///   - runtime: Container CLI runtime.
    private static func bestEffortReap(name: String, runtime: String) async {
        try? await ContainerMachineManager.stopMachine(name: name, runtime: runtime)
        try? await ContainerMachineManager.deleteMachine(name: name, runtime: runtime)
    }

    /// Fails closed when the concurrent detonation cap is already reached.
    ///
    /// Counts live `runeweaver-`-prefixed machines before spawn so a burst of
    /// archives cannot oversubscribe the host; listing failures fall through
    /// to `createMachine` so a missing runtime still surfaces its own error.
    private func enforceConcurrencyLimit() async throws {
        let cap = max(1, maxConcurrentMachines)
        do {
            let live = try await ContainerMachineManager.listMachines(
                prefix: ContainerMachineManager.machinePrefix,
                runtime: containerRuntime
            )
            guard live.count < cap else {
                throw EmailIMAPError.bridgeFailed(
                    "Archive detonation limit reached (\(cap) concurrent sessions); try again after idle sessions are reclaimed."
                )
            }
        } catch let bridge as EmailIMAPError {
            throw bridge
        } catch {
            // Listing failed (for example runtime missing): let create surface it.
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
/// Archives (ZIP/TAR families by type or filename) never touch host
/// staging: they detonate in a zero-host-mounts ephemeral microVM with
/// only a manifest returned, plus `subpath` inspection and an
/// approval-gated `saveToPath` export guarded by `FilesAccessGuard`.
/// Declared `requiresApproval` so the graduated-trust gate prompts
/// before any download. Reads only: it opens each mailbox read-only
/// with `(BODY.PEEK[])` fetches and never sends mail. Secrets are
/// resolved at execution time and never logged.
public struct EmailAttachmentTool: Tool, Sendable {
    /// Stable tool name referenced by the LLM and memory.
    public let name = "email.attachment"
    /// When the LLM should use this tool.
    public let description =
        "Downloads one email attachment by index. "
            + "Use when the user asks to save or open an attachment listed by email.read. "
            + "Pass the mailbox labeled on the email.search hit (omitted means INBOX). "
            + "Documents and images stage under the sandbox staging area with inline extracted text or vision payloads; "
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
    /// Subdirectory of the staging area holding downloaded attachments.
    public static let attachmentsSubdirectory = "attachments"

    /// Configured mail accounts.
    private let emailConfig: EmailConfig
    /// IMAP gateway (subprocess bridge by default, stub in tests).
    private let gateway: any EmailIMAPGateway
    /// Sandbox staging configuration. Document and image writes stay under `stagingPath`.
    private let sandboxConfig: SandboxConfig
    /// `[files]` policy guarding approval-gated archive exports. Defaults to the built-in defaults.
    private let filesConfig: FilesConfig
    /// Home boundary override forwarded to the guard. Nil means the real home.
    private let homeDirectoryURL: URL?
    /// Archive detonator (live microVM by default, stub in tests).
    private let archiveDetonator: any EmailArchiveDetonator

    /// Creates an attachment tool.
    /// - Parameters:
    ///   - emailConfig: Decoded `[email]` section.
    ///   - gateway: IMAP gateway. Defaults to the `python3` subprocess bridge.
    ///   - sandboxConfig: Sandbox staging configuration. Defaults to the built-in staging path.
    ///   - filesConfig: `[files]` policy for archive exports. Defaults to the built-in defaults.
    ///   - homeDirectoryURL: Home boundary override forwarded to the guard. Defaults to nil (real home).
    ///   - archiveDetonator: Archive detonator. Defaults to the live microVM detonator.
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
    ///
    /// Documents and images keep the staged-download path with inline
    /// payloads; archives branch to the ephemeral microVM detonator and
    /// never touch host staging, so untrusted archive bytes cannot reach
    /// `files.read` through the sandbox. Dry runs fetch metadata but spawn
    /// no machines and write no files.
    /// - Parameters:
    ///   - input: Invocation with `account`, `id` (plus `messageId` aliases), `index` aliases, optional `mailbox`, `preview`, `subpath`, and `saveToPath`.
    ///   - context: Ambient execution context. `dryRun` fetches but never writes or detonates.
    /// - Returns: JSON envelope with the staged path or archive manifest, or a skip note, or a failure without secrets.
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
    /// Validated relative entry path inside a detonated archive, if any.
    let subpath: String?
    /// Validated workspace export destination for a detonated archive, if any.
    let saveToPath: String?
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
        if let rawSubpath = args.trimmedSubpath {
            _ = try EmailAttachmentLifecycle.validateArchiveSubpath(rawSubpath)
        }
        if let rawSaveToPath = args.trimmedSaveToPath {
            try Self.validateSaveToPathSyntax(rawSaveToPath)
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
    /// Archive follow-ups validate fail-closed before any network or VM use:
    /// `subpath` must be a relative in-archive path and `saveToPath` must
    /// already satisfy the workspace guard, so a denied export never fetches
    /// IMAP bytes or spawns a machine.
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

    /// Stages document and image bytes under the sandbox and builds the success result.
    ///
    /// Archives never reach here: `execute` routes them to the microVM
    /// detonator before any host write, so this path only handles inline
    /// payloads with a staged copy for `files.read` follow-ups. Attaches the
    /// post-download lifecycle (expiry from the sandbox retention window,
    /// coarse MIME bucket, follow-up hint, and the guarded inline preview)
    /// so the model can act on the staged file without a second round trip.
    /// Inline payloads stay bounded: `extractedText` truncates to the shared
    /// preview char cap with the truncation flagged in `note`, and vision
    /// Base64 is omitted over the vision byte cap in favor of the staged copy.
    /// Oversized and dry-run skips keep the legacy shape with no lifecycle keys.
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
    ///
    /// Keeps the legacy skip shape (no lifecycle keys, no manifest) so a
    /// preview never detonates untrusted bytes and never writes host files;
    /// the note names the would-be detonation instead of a staging path so
    /// no caller mistakes a dry run for an isolated session.
    /// - Parameters:
    ///   - target: Trimmed routing.
    ///   - accountName: Resolved account name for the envelope.
    ///   - fetched: Downloaded metadata.
    ///   - callID: Correlation identifier.
    /// - Returns: Success envelope with the dry-run note.
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
    ///
    /// Host staging is never touched on this path: the manifest, optional
    /// subpath inspection payload, and optional approval-gated export are the
    /// only data that cross back. The export destination is re-checked against
    /// the workspace guard at write time (covering policy edits between
    /// validation and detonation), and parent directories are created so the
    /// export lands atomically. Entry payloads decode like direct downloads but
    /// stay bounded: UTF-8 entries surface as `extractedText` truncated to the
    /// shared preview char cap with the truncation flagged in `note`, image
    /// entries surface as vision Base64 only under the vision byte cap, and
    /// other binaries stay export-only so opaque bytes never enter
    /// the model context. Failures carry only the filename and reason, never
    /// entry bytes or secrets.
    /// - Parameters:
    ///   - target: Trimmed routing with validated `subpath`/`saveToPath`.
    ///   - accountName: Resolved account name for the envelope.
    ///   - fetched: Downloaded archive bytes (already capped).
    ///   - callID: Correlation identifier.
    /// - Returns: Success envelope with the manifest-only result, or throws for `execute` to convert.
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
            let decision = FilesAccessGuard.evaluate(path: saveToPath, homeDirectoryURL: homeDirectoryURL, filesConfig: filesConfig)
            guard decision.allowed else {
                throw EmailIMAPError.bridgeFailed(decision.reason ?? "Invalid saveToPath: path is not in the permitted workspace")
            }
            let bytesToWrite: Data
            if target.subpath != nil {
                guard let entryData = result.entryData else {
                    throw EmailIMAPError.bridgeFailed("Invalid subpath: entry not found in archive")
                }
                bytesToWrite = entryData
            } else {
                bytesToWrite = fetched.data
            }
            guard bytesToWrite.count <= Self.maxAttachmentBytes else {
                throw EmailIMAPError.bridgeFailed(Self.oversizeNote(sizeBytes: bytesToWrite.count))
            }
            do {
                let destination = URL(fileURLWithPath: decision.resolvedPath, isDirectory: false)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytesToWrite.write(to: destination, options: .atomic)
                exportedPath = decision.resolvedPath
            } catch {
                throw EmailIMAPError.bridgeFailed("Could not export archive entry: \(error.localizedDescription)")
            }
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
/// verified TLS; document and image bytes stage under the sandbox staging
/// area only while archives detonate in zero-host-mounts ephemeral
/// microVMs with manifest-only returns. Sending uses verified SMTP submission (explicit overrides
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
    ///   - filesConfig: `[files]` policy for approval-gated archive exports. Defaults to the built-in defaults.
    ///   - homeDirectoryURL: Home boundary override forwarded to the export guard. Defaults to nil (real home).
    ///   - archiveDetonator: Archive detonator for `email.attachment`. Defaults to the live microVM detonator.
    /// - Returns: Search, read, attachment, and send tools in registration order.
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
        return [search, read, attachment, send]
    }

    /// Registers the email tools, replacing same-named entries.
    /// - Parameters:
    ///   - bus: Bus receiving the tools (surfaced via `status`).
    ///   - emailConfig: Decoded `[email]` section.
    ///   - gateway: Shared IMAP gateway. Defaults to the `python3` subprocess bridge.
    ///   - smtpGateway: Shared SMTP gateway for `email.send`. Defaults to the `python3` subprocess bridge.
    ///   - sandboxConfig: Sandbox staging configuration for `email.attachment` downloads and `email.send` attachments.
    ///   - filesConfig: `[files]` policy for approval-gated archive exports. Defaults to the built-in defaults.
    ///   - homeDirectoryURL: Home boundary override forwarded to the export guard. Defaults to nil (real home).
    ///   - archiveDetonator: Archive detonator for `email.attachment`. Defaults to the live microVM detonator.
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

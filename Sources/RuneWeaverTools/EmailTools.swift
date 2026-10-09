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
            + "Omit account (or pass \"*\") to search every configured account in config sequence. "
            + "Pass mailbox to narrow to one folder; each hit labels its account and mailbox for email.read. "
            + "Pass hasAttachment (true/false) to filter for messages with or without attachments. "
            + "Pass since/until as YYYY-MM-DD local-day or full ISO8601 datetimes to bound the window (since inclusive, until exclusive). "
            + "limit caps the merged total across every searched account and mailbox, not the count per source. "
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
                  "description": "Account nickname from [email.accounts]; omit or pass blank or * to search every configured account in config sequence"
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
              "required":["query"],
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
                "Invalid email.search arguments: expected {\"query\": \"<text>\", \"account\": \"<name, omitted for all>\"}.",
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
        let query = args.trimmedQuery
        do {
            try EmailIMAPValidation.validateSearchQuery(query)
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
        // Wildcard/empty maps to ALL: a trimmed empty query or a lone "*" lists the most-recent
        // messages instead of sending a literal TEXT "*" that matches nothing on iCloud
        // (imap.mail.me.com:993).
        let effectiveQuery = EmailIMAPValidation.isAllQuery(query) ? "" : query
        // Account selection happens only after every argument-validation gate has
        // passed, so invalid input never triggers an account lookup or a credential
        // read. An omitted/blank/"*" selector fans out over the stored config
        // sequence; any other name resolves through the single tolerant matcher.
        let resolvedAccounts: [EmailAccount]
        if args.isAllAccountsRequest {
            resolvedAccounts = emailConfig.accounts
        } else {
            let accountName = args.trimmedAccount ?? ""
            guard let account = emailConfig.account(matching: accountName) else {
                let available = emailConfig.accounts.map(\.name)
                return .failure(EmailIMAPError.unknownAccount(name: accountName, available: available).localizedDescription, callID: input.callID)
            }
            resolvedAccounts = [account]
        }
        guard !resolvedAccounts.isEmpty else {
            return .failure("No email accounts configured. Add an [[email.accounts]] entry to config.toml.", callID: input.callID)
        }
        // Gateway validation surfaces by localized copy so both the current validation case and
        // any legacy bridge case with identical copy read the same here; no case matching needed.
        do {
            if resolvedAccounts.count == 1 {
                return try await singleAccountOutput(
                    account: resolvedAccounts[0],
                    requestedMailbox: args.trimmedMailbox,
                    effectiveQuery: effectiveQuery,
                    limit: args.limit,
                    hasAttachment: args.hasAttachment,
                    since: sinceDate,
                    until: untilDate,
                    callID: input.callID
                )
            }
            return try await multiAccountOutput(
                accounts: resolvedAccounts,
                effectiveQuery: effectiveQuery,
                limit: args.limit,
                hasAttachment: args.hasAttachment,
                since: sinceDate,
                until: untilDate,
                requestedMailbox: args.trimmedMailbox,
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

    /// Applies the local attachment plus temporal re-filters and stamps the
    /// owning account and canonical mailbox onto one mailbox's raw hits.
    ///
    /// Every searched hit must carry a non-empty `account` so merged
    /// multi-account results stay routable back to the account for follow-up
    /// `email.read`/`email.move` calls.
    private func labeledHits(
        _ hits: [EmailSearchHit],
        accountName: String,
        mailbox canonical: String,
        hasAttachment: Bool? = nil,
        since: Date? = nil,
        until: Date? = nil
    ) -> [EmailSearchHit] {
        filteredByTemporal(filteredByAttachment(hits, hasAttachment: hasAttachment), since: since, until: until).map {
            EmailSearchHit(
                id: $0.id,
                subject: $0.subject,
                from: $0.from,
                date: $0.date,
                snippet: $0.snippet,
                mailbox: canonical,
                account: accountName,
                hasAttachments: $0.hasAttachments,
                attachmentCount: $0.attachmentCount,
                attachments: $0.attachments
            )
        }
    }

    /// Runs the single-account branch of a search: resolve credentials up
    /// front so credential failures surface as the whole-call failure rather
    /// than a partially-covered envelope, then route to the explicit-mailbox
    /// or every-mailbox output. The envelope always carries the account in
    /// `accounts` and an empty `failedAccounts`.
    private func singleAccountOutput(
        account: EmailAccount,
        requestedMailbox: String?,
        effectiveQuery: String,
        limit: Int,
        hasAttachment: Bool? = nil,
        since: Date? = nil,
        until: Date? = nil,
        callID: String
    ) async throws -> ToolOutput {
        let credentials: ResolvedEmailCredentials
        do {
            credentials = try await EmailCredentialResolver.resolvedCredentials(for: account)
        } catch {
            return .failure(error.localizedDescription, callID: callID)
        }
        if let requested = requestedMailbox {
            return try await singleMailboxOutput(
                account: account,
                credentials: credentials,
                requested: requested,
                effectiveQuery: effectiveQuery,
                limit: limit,
                hasAttachment: hasAttachment,
                since: since,
                until: until,
                accounts: [account.name],
                failedAccounts: [],
                callID: callID
            )
        }
        return try await fanOutOutput(
            account: account,
            credentials: credentials,
            effectiveQuery: effectiveQuery,
            limit: limit,
            hasAttachment: hasAttachment,
            since: since,
            until: until,
            accounts: [account.name],
            failedAccounts: [],
            callID: callID
        )
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
        accounts: [String]? = nil,
        failedAccounts: [String]? = nil,
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
        let labeled = labeledHits(
            hits,
            accountName: account.name,
            mailbox: canonical,
            hasAttachment: hasAttachment,
            since: since,
            until: until
        )
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
            mailboxes: [canonical],
            accounts: accounts,
            failedAccounts: failedAccounts
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
        accounts: [String]? = nil,
        failedAccounts: [String]? = nil,
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
                let labeled = labeledHits(
                    hits,
                    accountName: account.name,
                    mailbox: box,
                    hasAttachment: hasAttachment,
                    since: since,
                    until: until
                )
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
            mailboxes: succeeded,
            accounts: accounts,
            failedAccounts: failedAccounts
        )
        return .success(content, callID: callID)
    }

    /// What one multi-account fan-out child learned about its account.
    ///
    /// Carries both the classification (searched / silently skipped / failed)
    /// and the evidence the parent needs for honest envelope reporting: the
    /// folders it searched, the folders it saw while listing, and the failure
    /// text when the account could not be searched. The parent correlates
    /// outcomes by config-sequence index rather than nickname so duplicate
    /// account names never merge two accounts into one outcome.
    private struct AccountSearchOutcome: Sendable {
        /// Agent-visible hit groups from folders the account actually searched.
        let groups: [[EmailSearchHit]]
        /// Folders actually searched, in search order (empty when nothing was searched).
        ///
        /// Carries the canonical resolved spelling for a requested folder, so
        /// the parent can report the name the server actually holds rather
        /// than the caller's requested spelling.
        let searchedFolders: [String]
        /// Selectable folders discovered during listing (empty when listing never succeeded).
        let availableFolders: [String]
        /// Failure text when the account could not be searched (credential or gateway failure).
        let failureText: String?
        /// Whether the account contributed searched folders to the merged result.
        var succeeded: Bool {
            !searchedFolders.isEmpty
        }

        /// Whether the account was skipped silently because it lacks the requested folder.
        var skipped: Bool {
            !succeeded && failureText == nil
        }
    }

    /// One child outcome paired with its config-sequence position so the
    /// parent correlates results by identity rather than nickname when
    /// `[email.accounts]` repeats a name.
    private struct IndexedAccountSearchOutcome: Sendable {
        /// Position of the account inside the config sequence.
        let index: Int
        /// What the account's child learned.
        let outcome: AccountSearchOutcome
    }

    /// Every child outcome classified by one config-order walk, ready for
    /// envelope reporting.
    private struct MultiAccountClassification: Sendable {
        /// Nicknames of accounts that contributed searched folders, in config order.
        let succeeded: [String]
        /// Nicknames of accounts that failed, in config order.
        let failed: [String]
        /// Accounts silently skipped for lacking the requested folder.
        let skippedCount: Int
        /// Agent-visible hit groups contributed by every succeeding account.
        let groups: [[EmailSearchHit]]
        /// Canonical folders actually searched across accounts, first-seen order.
        let searchedFolders: [String]
        /// Selectable folders listed by any account, first-seen order.
        let listedFolders: [String]
        /// Failure text of the first failing account in config order.
        let firstFailure: String?
    }

    /// Runs one account's share of a multi-account search: credentials, listing,
    /// then either the resolved requested folder or a sequential fan-out across
    /// every selectable folder — the same per-mailbox pipeline the
    /// single-account path uses, with hits stamped with the owning account.
    ///
    /// Credential and gateway failures are reported inside the outcome rather
    /// than thrown so the parent stays fail-soft; only `CancellationError`
    /// escapes, because user cancellation outranks partial coverage.
    private func accountSearchOutcome(
        _ account: EmailAccount,
        effectiveQuery: String,
        limit: Int,
        hasAttachment: Bool? = nil,
        since: Date? = nil,
        until: Date? = nil,
        requestedMailbox: String? = nil
    ) async throws -> AccountSearchOutcome {
        // Catch cancellation that arrived before this child even started so a
        // cancelled call cannot keep dialing sibling accounts' credentials.
        try Task.checkCancellation()
        let failed = { (text: String?) in
            AccountSearchOutcome(groups: [], searchedFolders: [], availableFolders: [], failureText: text)
        }
        let credentials: ResolvedEmailCredentials
        do {
            credentials = try await EmailCredentialResolver.resolvedCredentials(for: account)
        } catch {
            if error is CancellationError {
                throw error
            }
            return failed(error.localizedDescription)
        }
        let available: [String]
        do {
            let listed = try await gateway.listMailboxes(credentials: credentials)
            available = EmailBridgeParsing.selectableMailboxes(from: listed.map { name in (flags: "", mailbox: name) })
        } catch {
            if error is CancellationError {
                throw error
            }
            return failed(error.localizedDescription)
        }
        func searched(groups: [[EmailSearchHit]], folders: [String]) -> AccountSearchOutcome {
            AccountSearchOutcome(groups: groups, searchedFolders: folders, availableFolders: available, failureText: nil)
        }
        func skipped() -> AccountSearchOutcome {
            AccountSearchOutcome(groups: [], searchedFolders: [], availableFolders: available, failureText: nil)
        }
        func failedSearch(_ text: String?) -> AccountSearchOutcome {
            AccountSearchOutcome(groups: [], searchedFolders: [], availableFolders: available, failureText: text)
        }
        if let requested = requestedMailbox {
            guard let canonical = EmailBridgeParsing.resolveMailbox(requested, among: available) else {
                // Skipped silently: the account enters neither `accounts` nor
                // `failedAccounts`, but `availableFolders` rides along so the
                // parent can name real folders when no account covers the request.
                return skipped()
            }
            do {
                let hits = try await gateway.search(
                    credentials: credentials,
                    mailbox: canonical,
                    query: effectiveQuery,
                    limit: limit,
                    hasAttachment: hasAttachment,
                    since: since,
                    until: until
                )
                let labeled = labeledHits(
                    hits,
                    accountName: account.name,
                    mailbox: canonical,
                    hasAttachment: hasAttachment,
                    since: since,
                    until: until
                )
                return searched(
                    groups: [labeled.map { $0.agentVisible(credentialFilterEnabled: securityConfig.emailCredentialFilter) }],
                    folders: [canonical]
                )
            } catch {
                if error is CancellationError {
                    throw error
                }
                return failedSearch(error.localizedDescription)
            }
        }
        return try await fanOutAccountOutcome(
            accountName: account.name,
            credentials: credentials,
            available: available,
            effectiveQuery: effectiveQuery,
            limit: limit,
            hasAttachment: hasAttachment,
            since: since,
            until: until
        )
    }

    /// Runs the every-mailbox fan-out share of one account's search: a
    /// sequential walk over every selectable folder whose per-folder failure
    /// only degrades coverage, reported as an outcome. A server listing no
    /// selectable folder mirrors the single-account fan-out failure copy.
    private func fanOutAccountOutcome(
        accountName: String,
        credentials: ResolvedEmailCredentials,
        available: [String],
        effectiveQuery: String,
        limit: Int,
        hasAttachment: Bool? = nil,
        since: Date? = nil,
        until: Date? = nil
    ) async throws -> AccountSearchOutcome {
        let nothingSearched = { (text: String) in
            AccountSearchOutcome(groups: [], searchedFolders: [], availableFolders: available, failureText: text)
        }
        guard !available.isEmpty else {
            // Mirror the single-account fan-out: a server with nothing to
            // search is a failure with the same unknown-mailbox copy.
            return nothingSearched(EmailBridgeParsing.unknownMailboxError(requested: "*", available: available).localizedDescription)
        }
        var groups: [[EmailSearchHit]] = []
        var searchedFolders: [String] = []
        var lastFailure: String?
        // Mailboxes inside one account stay sequential: they share one bridge
        // session's worth of server goodwill, and cross-account parallelism
        // already provides the wall-clock win.
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
                let labeled = labeledHits(
                    hits,
                    accountName: accountName,
                    mailbox: box,
                    hasAttachment: hasAttachment,
                    since: since,
                    until: until
                )
                groups.append(labeled.map { $0.agentVisible(credentialFilterEnabled: securityConfig.emailCredentialFilter) })
                searchedFolders.append(box)
            } catch {
                if error is CancellationError {
                    throw error
                }
                lastFailure = error.localizedDescription
                continue
            }
        }
        if searchedFolders.isEmpty, let lastFailure {
            return nothingSearched(lastFailure)
        }
        return AccountSearchOutcome(groups: groups, searchedFolders: searchedFolders, availableFolders: available, failureText: nil)
    }

    /// Stitches hits across multiple accounts: one concurrent child per
    /// account inside a throwing task group, then one merged newest-first
    /// envelope capped to `limit` — `limit` is the global total, so every
    /// mailbox in every account may return up to `limit` hits and the merge
    /// is what enforces the bound.
    ///
    /// Outcomes are correlated by config-sequence index rather than nickname:
    /// duplicate names in `[email.accounts]` are two distinct accounts, and
    /// keying by name would merge them into one outcome and double-report the
    /// survivor.
    ///
    /// Fail-soft: the call succeeds when at least one account succeeds and
    /// reports credential/gateway failures honestly in `failedAccounts`,
    /// while accounts missing the requested folder stay silent. The call
    /// fails only when no account contributes: the fully-enumerated
    /// missing-folder rule outranks failure copy so the user learns what to
    /// retry.
    private func multiAccountOutput(
        accounts: [EmailAccount],
        effectiveQuery: String,
        limit: Int,
        hasAttachment: Bool? = nil,
        since: Date? = nil,
        until: Date? = nil,
        requestedMailbox: String? = nil,
        callID: String
    ) async throws -> ToolOutput {
        var outcomes: [IndexedAccountSearchOutcome] = []
        try await withThrowingTaskGroup(of: IndexedAccountSearchOutcome.self) { group in
            for (index, account) in accounts.enumerated() {
                group.addTask {
                    let outcome = try await self.accountSearchOutcome(
                        account,
                        effectiveQuery: effectiveQuery,
                        limit: limit,
                        hasAttachment: hasAttachment,
                        since: since,
                        until: until,
                        requestedMailbox: requestedMailbox
                    )
                    return IndexedAccountSearchOutcome(index: index, outcome: outcome)
                }
            }
            // A child that throws (only CancellationError escapes a child)
            // cancels the group and rethrows here, aborting the full call.
            for try await indexed in group {
                outcomes.append(indexed)
            }
        }
        let classified = classifyAccountOutcomes(outcomes, accounts: accounts)
        if classified.succeeded.isEmpty {
            if let requested = requestedMailbox, classified.skippedCount > 0, classified.failed.isEmpty {
                // Every account answered the listing and none carries the
                // requested folder, so the set is fully enumerated and naming
                // real folders is the honest retry hint. When an account
                // failed before listing, its contents stay unknown and the
                // first failure copy is the truthful surface instead.
                throw EmailBridgeParsing.unknownMailboxError(requested: requested, available: classified.listedFolders)
            }
            if let firstFailure = classified.firstFailure {
                throw EmailIMAPError.bridgeFailed(firstFailure)
            }
            // Defensive: execute() rejects an empty config before fan-out, so
            // reaching here means nothing contributed and nothing reported a
            // reason.
            throw EmailIMAPError.bridgeFailed("No email accounts configured. Add an [[email.accounts]] entry to config.toml.")
        }
        let merged = EmailSearchMerge.mergedNewestFirst(classified.groups, limit: limit)
        // Report the canonical resolved folder, not the caller's spelling:
        // every succeeding account resolved its requested folder to one the
        // server actually holds, so its first searched folder is the same
        // name the per-hit labels and the `mailboxes` union already carry
        // (mirroring what a single-account envelope reports). Where accounts
        // hold different canonical spellings of the same request, the union
        // in `mailboxes` stays the complete record.
        let canonicalMailbox = requestedMailbox.flatMap { _ in classified.searchedFolders.first }
        let content = try EmailBridgeParsing.encodeSearchEnvelope(
            account: "all",
            query: effectiveQuery,
            messages: merged,
            mailbox: canonicalMailbox,
            mailboxes: classified.searchedFolders,
            accounts: classified.succeeded,
            failedAccounts: classified.failed
        )
        return .success(content, callID: callID)
    }

    /// Walks the config sequence over index-keyed child outcomes and
    /// classifies every account into searched / silently skipped / failed,
    /// deduplicating the searched- and listed-folder unions. Walking in
    /// config order keeps reporting deterministic despite the task group's
    /// nondeterministic completion order, and index-based correlation keeps
    /// duplicate account names counted as the distinct accounts they are.
    private func classifyAccountOutcomes(
        _ outcomes: [IndexedAccountSearchOutcome],
        accounts: [EmailAccount]
    ) -> MultiAccountClassification {
        var succeeded: [String] = []
        var failed: [String] = []
        var skippedCount = 0
        var groups: [[EmailSearchHit]] = []
        var searchedFolders: [String] = []
        var listedFolders: [String] = []
        var firstFailure: String?
        let outcomeByIndex = Dictionary(uniqueKeysWithValues: outcomes.map { ($0.index, $0.outcome) })
        for (index, account) in accounts.enumerated() {
            guard let outcome = outcomeByIndex[index] else { continue }
            if outcome.succeeded {
                succeeded.append(account.name)
                groups.append(contentsOf: outcome.groups)
                for folder in outcome.searchedFolders where !searchedFolders.contains(folder) {
                    searchedFolders.append(folder)
                }
            } else if outcome.skipped {
                skippedCount += 1
            } else {
                failed.append(account.name)
                if firstFailure == nil {
                    firstFailure = outcome.failureText
                }
            }
            for folder in outcome.availableFolders where !listedFolders.contains(folder) {
                listedFolders.append(folder)
            }
        }
        return MultiAccountClassification(
            succeeded: succeeded,
            failed: failed,
            skippedCount: skippedCount,
            groups: groups,
            searchedFolders: searchedFolders,
            listedFolders: listedFolders,
            firstFailure: firstFailure
        )
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
            + "Pass the mailbox labeled on the email.search hit. "
            + "Returns headers plus the text body; attachments are listed with filename, MIME type, and byte size (use email.attachment to download)."
    /// Function-calling contract for `account`, `id`, and mandatory `mailbox`.
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
                  "description": "Mailbox from the email.search hit (e.g. INBOX, Archive, Deleted Messages)"
                }
              },
              "required":["account","id","mailbox"],
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
            return .failure(
                "Invalid email.read arguments: expected {\"account\": \"<name>\", \"id\": \"<message-id>\", \"mailbox\": \"<mailbox>\"}.",
                callID: input.callID
            )
        }
        // Fail fast on allowlist before touching accounts or credentials so invalid input reports
        // "Invalid message id" even when the password is missing. Checks the raw value first, then
        // trimmed.
        do {
            try EmailIMAPValidation.validateMessageID(args.messageID)
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
        let requestedMailbox = args.trimmedMailbox
        do {
            try EmailIMAPValidation.validateMailbox(requestedMailbox)
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
        let accountName = args.trimmedAccount
        let messageID = args.trimmedMessageID
        guard !accountName.isEmpty else {
            return .failure("Invalid email.read arguments: 'account' must not be empty.", callID: input.callID)
        }
        guard !messageID.isEmpty else {
            return .failure("Invalid email.read arguments: 'id' must not be empty.", callID: input.callID)
        }
        guard !requestedMailbox.isEmpty else {
            return .failure("Invalid email.read arguments: 'mailbox' must not be empty.", callID: input.callID)
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
            let listed = try await gateway.listMailboxes(credentials: credentials)
            let available = EmailBridgeParsing.selectableMailboxes(from: listed.map { name in (flags: "", mailbox: name) })
            let effectiveMailbox: String
            do {
                effectiveMailbox = try EmailBridgeParsing.resolveMailboxAgainstList(requested: requestedMailbox, available: available)
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
        containersConfig: ContainersConfig = ContainersConfig(),
        filesConfig: FilesConfig = FilesConfig(),
        homeDirectoryURL: URL? = nil,
        archiveDetonator: (any EmailArchiveDetonator)? = nil,
        ephemeralLedger: EphemeralContainerLedger? = nil,
        securityConfig: SecurityConfig = SecurityConfig()
    ) -> [any Tool] {
        let shared: any EmailIMAPGateway = gateway ?? SubprocessIMAPGateway()
        let sharedSMTP: any EmailSMTPGateway = smtpGateway ?? SubprocessSMTPGateway()
        let search: any Tool = EmailSearchTool(emailConfig: emailConfig, gateway: shared, securityConfig: securityConfig)
        let read: any Tool = EmailReadTool(emailConfig: emailConfig, gateway: shared, securityConfig: securityConfig)
        let attachment: any Tool = EmailAttachmentTool(
            emailConfig: emailConfig,
            gateway: shared,
            containersConfig: containersConfig,
            filesConfig: filesConfig,
            homeDirectoryURL: homeDirectoryURL,
            archiveDetonator: archiveDetonator,
            ephemeralLedger: ephemeralLedger
        )
        let send: any Tool = EmailSendTool(
            emailConfig: emailConfig,
            smtpGateway: sharedSMTP,
            gateway: shared
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
        containersConfig: ContainersConfig = ContainersConfig(),
        filesConfig: FilesConfig = FilesConfig(),
        homeDirectoryURL: URL? = nil,
        archiveDetonator: (any EmailArchiveDetonator)? = nil,
        ephemeralLedger: EphemeralContainerLedger? = nil,
        securityConfig: SecurityConfig = SecurityConfig()
    ) async {
        let effectiveLedger: EphemeralContainerLedger? = if archiveDetonator == nil {
            if let ephemeralLedger {
                ephemeralLedger
            } else {
                await StrictTurnRegistry.shared.ephemeralLedger
            }
        } else {
            ephemeralLedger
        }
        for tool in makeTools(
            emailConfig: emailConfig,
            gateway: gateway,
            smtpGateway: smtpGateway,
            containersConfig: containersConfig,
            filesConfig: filesConfig,
            homeDirectoryURL: homeDirectoryURL,
            archiveDetonator: archiveDetonator,
            ephemeralLedger: effectiveLedger,
            securityConfig: securityConfig
        ) {
            await bus.register(tool: tool)
        }
    }
}

// Rune Weaver Tools — Adapter binding the shared IMAP gateway to the mail indexer seam.
//
// The core mail indexer enumerates mail through a read-only protocol seam so it
// stays free of the tool layer. This adapter maps that seam onto the existing
// `EmailIMAPGateway`, whose live implementation runs the `EmailIMAPBridge`
// subprocess: it lists selectable mailboxes, reads the newest message page,
// fetches each message for indexing, and reads attachment parts. Every read
// flows through the bridge's `BODY.PEEK` path, so indexing never marks mail as
// seen. Credentials are built only at execution time and are never logged.
//
// When the indexer brackets a mailbox with `openMailboxSession` the adapter
// keeps one `EmailIMAPSession` alive for that account plus mailbox and routes
// STATUS, SEARCH, and FETCH through it, so a whole backfill rides a single
// handshake; otherwise every call uses today's one-shot subprocess path.
// Mailbox listing and attachment fetches stay on the one-shot path by design:
// the pooled session speaks only open, status, search, fetch, and close, so
// attachments read the same one-shot bytes whether or not a session is open.
// Attachments stay one-shot on purpose: they are bounded and few (per-file
// and total caps, listing plus probe once per run), so a pooled attachment op
// would pay handshake and session complexity without saving a handshake per
// message. The per-mailbox handshake saving stays with search plus fetch,
// which ride the open session every time.

import Foundation
import RuneWeaverCore

/// Factory building a live session for resolved credentials.
///
/// The default builds the real piped actor; tests inject a factory returning
/// sessions fronted by in-memory transports so pooling asserts without dialing.
public typealias MailIndexSessionFactory = @Sendable (ResolvedEmailCredentials) -> EmailIMAPSession

/// Mailbox-scoped pool owning live session lifetime.
///
/// The adapter is the named owner for session lifetime: it starts pooled
/// sessions on open, evicts them on failure or close, and routes reads through
/// the pooled handle while one is open. One entry exists per account plus
/// mailbox so parallel mailboxes never share a connection.
actor MailIndexSessionPool {
    /// Live sessions keyed by account plus mailbox.
    private var sessions: [String: EmailIMAPSession] = [:]

    init() {}

    func existing(key: String) -> EmailIMAPSession? {
        sessions[key]
    }

    /// Atomically claims the pooled session, creating an unstarted one when absent.
    ///
    /// Creation plus storage happen without suspension so concurrent opens
    /// coalesce on one handle. The start stays idempotent on the session
    /// actor, so every opener calls `start()` and joins wait on the same
    /// handshake instead of redialing.
    /// - Parameters:
    ///   - credentials: Resolved fields for the fresh handle when absent.
    /// - Returns: Pooled handle, started by the caller via idempotent `start()`.
    func claim(
        key: String,
        credentials: ResolvedEmailCredentials,
        factory: MailIndexSessionFactory
    ) -> EmailIMAPSession {
        if let current = sessions[key] {
            return current
        }
        let created = factory(credentials)
        sessions[key] = created
        return created
    }

    /// Evicts the pooled session for a key without closing it.
    ///
    /// Callers close the returned handle outside isolation so teardown never
    /// holds the pool across an await.
    /// - Returns: Evicted handle, or nil when absent.
    func remove(key: String) -> EmailIMAPSession? {
        sessions.removeValue(forKey: key)
    }
}

/// Bridges an ``EmailIMAPGateway`` to the core mail indexer seam.
public struct EmailIMAPMailIndexGateway: MailIndexGateway, Sendable {
    /// Fixed UID window width bounding every backfill SEARCH.
    ///
    /// Behavioral owner for the window shape: every criterion stays within
    /// this width so per-page cost stays bounded without widening the limit.
    /// Stored once in Core so indexer stepping shares the value without
    /// duplicating the literal.
    public static let uidWindowWidth = MailIndexTiling.uidWindowWidth

    /// Underlying IMAP gateway (subprocess bridge by default).
    private let gateway: any EmailIMAPGateway
    /// Whether indexed bodies carry the redacted agent-visible form. Defaults
    /// on so search recall cannot resurrect a redacted link; false keeps the
    /// raw body for debugging parity checks.
    private let credentialFilterEnabled: Bool
    /// Mailbox-scoped pool owning live session lifetime.
    private let sessionPool: MailIndexSessionPool
    /// Injectable session builder defaulting to the live actor.
    private let sessionFactory: MailIndexSessionFactory
    /// JSONL event log for pool lifecycle lines.
    ///
    /// Always on with no knob; the same sink fronts pooled sessions built by
    /// the default factory so `session.spawn` plus `pool.open` share one pid.
    /// Only account, mailbox, pid, plus reason tokens ride pool lines so
    /// passwords and payload content never enter the log.
    private let eventLog: MailSessionEventLog

    /// Creates an adapter over an IMAP gateway.
    /// - Parameters:
    ///   - gateway: Gateway whose read-only operations back the seam.
    ///   - credentialFilterEnabled: False indexes raw bodies byte-identically.
    ///   - eventLog: Pool lifecycle sink, defaulting to the live file.
    ///   - sessionFactory: Builder for pooled sessions; nil builds the live actor fronted by `eventLog`.
    public init(
        gateway: any EmailIMAPGateway,
        credentialFilterEnabled: Bool = true,
        eventLog: MailSessionEventLog = .live,
        sessionFactory: MailIndexSessionFactory? = nil
    ) {
        self.gateway = gateway
        self.credentialFilterEnabled = credentialFilterEnabled
        self.sessionPool = MailIndexSessionPool()
        self.eventLog = eventLog
        if let sessionFactory {
            self.sessionFactory = sessionFactory
        } else {
            let captured = eventLog
            self.sessionFactory = { credentials in EmailIMAPSession(credentials: credentials, eventLog: captured) }
        }
    }

    /// Creates an adapter honoring the `[security]` defense policy.
    /// - Parameters:
    ///   - gateway: Gateway whose read-only operations back the seam.
    ///   - securityConfig: Defense policy carrying the filter toggle.
    ///   - eventLog: Pool lifecycle sink, defaulting to the live file.
    ///   - sessionFactory: Builder for pooled sessions; nil builds the live actor fronted by `eventLog`.
    public init(
        gateway: any EmailIMAPGateway,
        securityConfig: SecurityConfig,
        eventLog: MailSessionEventLog = .live,
        sessionFactory: MailIndexSessionFactory? = nil
    ) {
        self.init(
            gateway: gateway,
            credentialFilterEnabled: securityConfig.emailCredentialFilter,
            eventLog: eventLog,
            sessionFactory: sessionFactory
        )
    }

    /// Builds the pool key for one account plus mailbox.
    ///
    /// Delegates to the shared `mailboxKey` so padded spellings share one
    /// pooled handle with the checkpoint watermark instead of forking.
    /// - Parameters:
    ///   - account: Account nickname.
    ///   - mailbox: Mailbox name.
    /// - Returns: Stable opaque key.
    private static func sessionKey(account: String, mailbox: String) -> String {
        mailboxKey(account: account, mailbox: mailbox)
    }

    /// Starts or reuses the pooled session for one mailbox.
    ///
    /// The first opener spawns plus logs in; later openers join the same
    /// handle. The start stays idempotent so a join arriving mid-handshake
    /// waits on the session actor instead of redialing. An open failure
    /// evicts so a later open retries cleanly with no half-open leak. A
    /// successful start emits `pool.open` with the helper pid so the pool line
    /// correlates with the session `session.spawn` line via timestamp plus pid;
    /// an open failure emits `pool.evict` with an `open-failed` reason.
    /// - Parameters:
    ///   - credentials: Resolved connection fields plus password.
    ///   - mailbox: Mailbox the session will read.
    public func openMailboxSession(credentials: MailIndexCredentials, mailbox: String) async throws {
        try EmailIMAPValidation.validateMailbox(mailbox)
        let trimmed = mailbox.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = Self.sessionKey(account: credentials.accountName, mailbox: trimmed)
        let resolved = credentials.resolvedEmailCredentials()
        let session = await sessionPool.claim(key: key, credentials: resolved, factory: sessionFactory)
        do {
            // `start()` is idempotent: the first opener spawns plus logs in
            // while later openers join the same handshake without redialing.
            try await session.start()
        } catch {
            // Capture the pid before teardown closes the transport away; the
            // evict line keeps the failing helper identity even when the close
            // itself must run without it.
            let pid = await session.processIdentifier
            if let removed = await sessionPool.remove(key: key) {
                await removed.close()
            } else {
                await session.close()
            }
            // Only outcome tokens ride the pool line; the verbatim helper
            // detail already lives on `session.open.result` plus `session.stderr`.
            eventLog.emit(
                event: "pool.evict",
                account: credentials.accountName,
                pid: pid,
                fields: ["mailbox": trimmed, "reason": "open-failed"]
            )
            throw error
        }
        // The pid read after start matches the `session.spawn` pid because both
        // come from the same live transport; hermetic fakes stay pid-free on
        // both lines so correlation still holds as jointly absent.
        let pid = await session.processIdentifier
        eventLog.emit(
            event: "pool.open",
            account: credentials.accountName,
            pid: pid,
            fields: ["mailbox": trimmed]
        )
    }

    /// Closes plus evicts the pooled session for one mailbox, no-op when absent.
    ///
    /// Close stays non-throwing by design so the indexer bracket always
    /// terminates without masking the run outcome. A removed handle emits
    /// `pool.close` with its pre-close pid so the close line correlates with
    /// the matching `pool.open` line; an absent key stays silent.
    /// - Parameters:
    ///   - credentials: Resolved connection fields plus password.
    ///   - mailbox: Mailbox whose session ends.
    public func closeMailboxSession(credentials: MailIndexCredentials, mailbox: String) async {
        let trimmed = mailbox.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = Self.sessionKey(account: credentials.accountName, mailbox: trimmed)
        if let removed = await sessionPool.remove(key: key) {
            // Capture before close clears the transport; the close line then
            // carries the same pid the open line carried for this bracket.
            let pid = await removed.processIdentifier
            await removed.close()
            eventLog.emit(
                event: "pool.close",
                account: credentials.accountName,
                pid: pid,
                fields: ["mailbox": trimmed]
            )
        }
    }

    /// Evicts plus closes the pooled session for a key after a transport failure.
    ///
    /// Every session-routed read funnels through here on transport, timeout,
    /// or bridge failures so the next call opens fresh instead of reusing a
    /// broken handle. Validation plus decode failures never reach here: they
    /// leave a healthy connection pooled. The evict line carries the pre-close
    /// pid plus a short reason token so operators can tell open, status, and
    /// message failures apart without any payload content.
    /// - Parameters:
    ///   - key: Account plus mailbox key.
    ///   - account: Account nickname for the evict line.
    ///   - mailbox: Mailbox name for the evict line.
    ///   - reason: Short token naming the failing operation.
    private func evictSession(key: String, account: String, mailbox: String, reason: String) async {
        if let removed = await sessionPool.remove(key: key) {
            let pid = await removed.processIdentifier
            await removed.close()
            eventLog.emit(
                event: "pool.evict",
                account: account,
                pid: pid,
                fields: ["mailbox": mailbox, "reason": reason]
            )
        }
    }

    /// Whether a session-routed failure owns eviction.
    ///
    /// Typed validation plus decode failures leave a healthy connection
    /// behind, so they rethrow without evicting. A `bridgeFailed` evicts on
    /// generic transport closures plus any detail the shared
    /// `MailIndexer.isRetryableMailError` classifier deems retryable, so
    /// transport, timeout, plus `connection closed` details evict while
    /// auth-phrased plus unknown details never evict; `pythonUnavailable`
    /// always evicts so the next call opens fresh, as does any generic error
    /// the indexer classifies as retryable or naming a transport closure.
    /// Cancellation never evicts.
    /// - Parameter error: Session failure under test.
    /// - Returns: True when the pooled handle must be evicted.
    private static func shouldEvictSession(for error: Error) -> Bool {
        if error is CancellationError {
            return false
        }
        if let imapError = error as? EmailIMAPError {
            switch imapError {
            case .decodeFailed, .validationFailed, .unknownAccount:
                return false
            case let .bridgeFailed(detail):
                if isAuthDetail(detail) {
                    return false
                }
                if isTransportClosureDetail(detail) {
                    return true
                }
                return MailIndexer.isRetryableMailError(imapError)
            case .pythonUnavailable:
                return true
            }
        }
        // Shared ownership with the indexer retry classifier: a generic
        // retryable transport error evicts so the reopen after backoff starts
        // a fresh handshake instead of no-op restarting the broken handle.
        // Auth phrases already return false inside the classifier, preserving
        // the no-retry contract. Generic transport closures evict explicitly
        // so a dropped connection reopens fresh even when the classifier
        // treats the wording as unknown.
        let described: String = if let localized = (error as? LocalizedError)?.errorDescription {
            localized + " " + String(describing: error)
        } else {
            error.localizedDescription + " " + String(describing: error)
        }
        if isAuthDetail(described) {
            return false
        }
        if isTransportClosureDetail(described) {
            return true
        }
        return MailIndexer.isRetryableMailError(error)
    }

    /// Whether a bridge detail names an auth failure that must never evict.
    ///
    /// Single-source forwarding to `MailErrorClassification` so the eviction
    /// path shares one wording owner with the retry classifier; a detail
    /// carrying both auth plus transport signals still leaves the pool intact.
    /// - Parameter detail: Bridge error detail under test.
    /// - Returns: True when the detail carries an auth phrase.
    private static func isAuthDetail(_ detail: String) -> Bool {
        MailErrorClassification.isAuthFailureDetail(detail)
    }

    /// Whether a bridge detail names a generic transport closure that must evict.
    ///
    /// Single-source forwarding to `MailErrorClassification` so `connection
    /// closed` plus whole-word `closed` and `eof` evict while `disclosed`
    /// and `enclosed` never do. Callers check auth first so an auth-phrased
    /// detail never evicts even when it also names a transport phrase.
    /// - Parameter detail: Bridge error detail under test.
    /// - Returns: True when the detail names a transport closure.
    private static func isTransportClosureDetail(_ detail: String) -> Bool {
        MailErrorClassification.isTransportFailureDetail(detail)
    }

    /// Maps STATUS validation plus unknown-account failures to Core-owned errors.
    ///
    /// The indexer must skip those without matching this layer's concrete
    /// type by name, so the seam translates them where the type is visible.
    /// Every other failure returns nil so generic STATUS-unsupported servers
    /// keep propagating untouched into the unanchored fallback.
    /// - Parameter error: STATUS probe failure under test.
    /// - Returns: Core-owned error, or nil when the failure must propagate as-is.
    private static func mapStatusError(_ error: Error) -> Error? {
        if let imapError = error as? EmailIMAPError {
            switch imapError {
            case let .validationFailed(detail):
                return MailIndexError.validationFailed(detail)
            case .unknownAccount:
                return MailIndexError.unknownAccount(imapError.localizedDescription)
            case .bridgeFailed, .decodeFailed, .pythonUnavailable:
                return nil
            }
        }
        return nil
    }

    /// Lists selectable mailboxes for an account.
    /// - Parameter credentials: Resolved connection fields plus password.
    /// - Returns: Selectable mailbox names in server order.
    public func mailboxes(credentials: MailIndexCredentials) async throws -> [String] {
        try await gateway.mailboxListing(credentials: credentials.resolvedEmailCredentials()).mailboxes
    }

    /// Returns the mailbox status snapshot for backfill anchoring.
    ///
    /// While a session is open for the mailbox the probe rides that
    /// connection; otherwise today's one-shot STATUS path runs byte-identically.
    /// A transport, timeout, or bridge failure evicts before rethrowing so the
    /// next call opens fresh; validation plus decode failures rethrow without
    /// evicting so a healthy connection stays pooled. Validation plus
    /// unknown-account failures map to Core-owned `MailIndexError` cases so
    /// the indexer can match by type without importing this layer; every
    /// other failure propagates untouched so STATUS-unsupported servers still
    /// fall back to the unanchored path.
    /// - Parameters:
    ///   - credentials: Resolved connection fields plus password.
    ///   - mailbox: Mailbox to inspect.
    /// - Returns: Next UID plus validity token, with nils when unknown.
    public func mailboxStatus(credentials: MailIndexCredentials, mailbox: String) async throws -> MailIndexMailboxStatus {
        let trimmed = mailbox.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = Self.sessionKey(account: credentials.accountName, mailbox: trimmed)
        if let session = await sessionPool.existing(key: key) {
            do {
                let status = try await session.status(mailbox: mailbox)
                return MailIndexMailboxStatus(uidNext: status.uidNext, uidValidity: status.uidValidity)
            } catch {
                if let mapped = Self.mapStatusError(error) {
                    throw mapped
                }
                if Self.shouldEvictSession(for: error) {
                    await evictSession(key: key, account: credentials.accountName, mailbox: trimmed, reason: "status-transport")
                }
                throw error
            }
        }
        do {
            let status = try await gateway.status(
                credentials: credentials.resolvedEmailCredentials(),
                mailbox: mailbox
            )
            return MailIndexMailboxStatus(uidNext: status.uidNext, uidValidity: status.uidValidity)
        } catch {
            if let mapped = Self.mapStatusError(error) {
                throw mapped
            }
            throw error
        }
    }

    /// Returns the newest messages in one mailbox, newest first.
    ///
    /// The named owner for the backfill criterion shape is this adapter: every
    /// SEARCH carries an explicit fixed window `UID lo:hi` at most
    /// `uidWindowWidth` wide, built from integers only with no free text, so
    /// the bridge issues a bounded range and returns the newest page inside
    /// that window. The first window top anchors from the STATUS UIDNEXT probe
    /// so no open-ended SEARCH remains on any path; later pages pass a bound
    /// strictly below the lowest fetched UID. A bound at or below the mailbox
    /// start holds no UIDs and returns empty without dialing. The core indexer
    /// filters each page against its watermark and tiles strictly downward, so
    /// each call stays clamped to one bounded page. While a session is open the
    /// same shape rides that connection with identical clamp plus redaction;
    /// a transport, timeout, or bridge failure evicts before rethrowing so the
    /// retry loop reopens fresh, while validation plus decode failures rethrow
    /// without evicting so a healthy connection stays pooled.
    /// - Parameters:
    ///   - credentials: Resolved connection fields plus password.
    ///   - mailbox: Mailbox to read.
    ///   - limit: Maximum messages to return.
    ///   - mode: Fetch mode; the live bridge is always read-only.
    ///   - beforeUID: Exclusive upper bound for this page; only UIDs below the
    ///     bound are returned. Nil anchors the newest window from STATUS; a
    ///     threaded probe `uidNext` arrives here as a present bound so the
    ///     session path skips its anchor STATUS.
    /// - Returns: Messages in newest-first order.
    public func messages(
        credentials: MailIndexCredentials,
        mailbox: String,
        limit: Int,
        mode _: MailFetchMode,
        beforeUID: Int? = nil
    ) async throws -> [MailIndexMessage] {
        let trimmed = mailbox.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = Self.sessionKey(account: credentials.accountName, mailbox: trimmed)
        if let session = await sessionPool.existing(key: key) {
            do {
                return try await messagesViaSession(
                    session: session,
                    mailbox: mailbox,
                    limit: limit,
                    beforeUID: beforeUID
                )
            } catch {
                if Self.shouldEvictSession(for: error) {
                    await evictSession(key: key, account: credentials.accountName, mailbox: trimmed, reason: "messages-transport")
                }
                throw error
            }
        }
        return try await messagesViaOneShot(
            credentials: credentials,
            mailbox: mailbox,
            limit: limit,
            beforeUID: beforeUID
        )
    }

    /// Whether a STATUS probe failure means the server lacks STATUS support.
    ///
    /// Only this signal falls back to the legacy unanchored listing on the
    /// same connection; transport, timeout, and auth failures rethrow so the
    /// pooled caller evicts or surfaces them instead of silently paging
    /// unbounded. Matches the `not supported` wording owned by the gateway
    /// default plus helper failures carrying the same phrase.
    /// - Parameter error: STATUS probe failure under test.
    /// - Returns: True only for the unsupported-Server signal.
    private static func isStatusUnsupported(_ error: Error) -> Bool {
        let described: String = if let localized = (error as? LocalizedError)?.errorDescription {
            localized + " " + String(describing: error)
        } else {
            error.localizedDescription + " " + String(describing: error)
        }
        return described.range(of: "not supported", options: .caseInsensitive) != nil
    }

    /// Reads one page through the pooled session with identical criterion plus redaction.
    ///
    /// A present bound — including a threaded probe `uidNext` from the
    /// caller's STATUS — builds the window directly with no extra round trip.
    /// The anchor STATUS rides the same connection only when no bound was
    /// threaded, so the first window stays bounded without a second STATUS;
    /// a bound at the mailbox start still short-circuits without dialing.
    /// - Parameters:
    ///   - session: Pooled handle for the mailbox.
    ///   - mailbox: Mailbox to read.
    ///   - limit: Maximum messages to return.
    ///   - beforeUID: Exclusive upper bound for this page, or the threaded
    ///     probe `uidNext` for the first page.
    /// - Returns: Messages in newest-first order.
    private func messagesViaSession(
        session: EmailIMAPSession,
        mailbox: String,
        limit: Int,
        beforeUID: Int?
    ) async throws -> [MailIndexMessage] {
        let clamped = max(1, min(limit, EmailSearchArgs.maxLimit))
        let query: String
        if let beforeUID {
            // Integer-only construction keeps free text out of the IMAP
            // criterion; a bound at the mailbox start is already exhausted.
            // A threaded probe `uidNext` lands here, skipping the STATUS below.
            guard let criterion = Self.uidRangeCriterion(beforeUID: beforeUID) else {
                return []
            }
            query = criterion
        } else {
            // Anchor the first fixed window from the session STATUS only when
            // the caller threaded no probe, so the newest page stays bounded
            // on the same connection. An empty mailbox holds no UIDs and
            // returns without searching. Only servers without STATUS support
            // fall back to the legacy listing on the same connection so
            // session coverage matches the one-shot path; every other STATUS
            // failure rethrows so transport, timeout, and auth errors evict
            // or surface through the pooled caller instead of paging
            // unbounded on a broken connection.
            do {
                let status = try await session.status(mailbox: mailbox)
                guard let criterion = Self.newestWindowCriterion(uidNext: status.uidNext) else {
                    return []
                }
                query = criterion
            } catch let cancel as CancellationError {
                throw cancel
            } catch {
                guard Self.isStatusUnsupported(error) else { throw error }
                query = ""
            }
        }
        let hits = try await session.search(mailbox: mailbox, query: query, limit: clamped, since: nil, until: nil)
        return try await fetchIndexedMessages(hits: hits) { hitID in
            try await session.fetch(mailbox: mailbox, messageID: hitID)
        }
    }

    /// Reads one page through today's one-shot subprocess path.
    ///
    /// Kept byte-identical for callers without an open session, including the
    /// legacy empty-query fallback for doubles without STATUS support.
    /// - Parameters:
    ///   - credentials: Resolved connection fields plus password.
    ///   - mailbox: Mailbox to read.
    ///   - limit: Maximum messages to return.
    ///   - beforeUID: Exclusive upper bound for this page.
    /// - Returns: Messages in newest-first order.
    private func messagesViaOneShot(
        credentials: MailIndexCredentials,
        mailbox: String,
        limit: Int,
        beforeUID: Int?
    ) async throws -> [MailIndexMessage] {
        let resolved = credentials.resolvedEmailCredentials()
        let clamped = max(1, min(limit, EmailSearchArgs.maxLimit))
        let query: String
        if let beforeUID {
            // Integer-only construction keeps free text out of the IMAP
            // criterion; a bound at the mailbox start is already exhausted.
            guard let criterion = Self.uidRangeCriterion(beforeUID: beforeUID) else {
                return []
            }
            query = criterion
        } else {
            // Anchor the first fixed window from STATUS UIDNEXT so the newest
            // page is bounded without an open-ended SEARCH. An empty mailbox
            // holds no UIDs and returns without dialing. Gateways without
            // STATUS support fall back to the legacy listing so doubles
            // without the probe still index.
            do {
                let status = try await gateway.status(credentials: resolved, mailbox: mailbox)
                guard let criterion = Self.newestWindowCriterion(uidNext: status.uidNext) else {
                    return []
                }
                query = criterion
            } catch {
                query = ""
            }
        }
        let hits = try await gateway.search(credentials: resolved, mailbox: mailbox, query: query, limit: clamped, since: nil, until: nil)
        return try await fetchIndexedMessages(hits: hits) { hitID in
            try await gateway.fetch(credentials: resolved, mailbox: mailbox, messageID: hitID)
        }
    }
}

// MARK: - Message Mapping & Helpers

extension EmailIMAPMailIndexGateway {
    /// Builds the newest-window criterion from a STATUS `uidNext`.
    ///
    /// Shared by the session plus one-shot anchors so the window top cannot
    /// drift between paths: bounds come from the shared tiling helper, with
    /// `hi` equal to `uidNext - 1`. An empty mailbox holds no UIDs and yields
    /// nil so the caller returns without dialing.
    /// - Parameter uidNext: Next UID from STATUS.
    /// - Returns: `UID lo:hi` criterion, or nil when the mailbox is empty.
    private static func newestWindowCriterion(uidNext: Int) -> String? {
        guard let window = MailIndexTiling.newestWindow(uidNext: uidNext) else { return nil }
        return "UID \(window.lower):\(window.upper)"
    }

    /// Fetches plus maps one page of hits through a fetch closure.
    ///
    /// Shared by the session plus one-shot paths so hit-to-message mapping
    /// cannot drift: each hit fetches its full body read-only, then maps to
    /// the redacted indexed shape.
    /// - Parameters:
    ///   - hits: Search hits in newest-first order.
    ///   - fetch: Fetch closure returning the full body for a hit UID.
    /// - Returns: Indexed messages in newest-first order.
    private func fetchIndexedMessages(
        hits: [EmailSearchHit],
        fetch: (String) async throws -> EmailFullMessage
    ) async throws -> [MailIndexMessage] {
        var messages: [MailIndexMessage] = []
        messages.reserveCapacity(hits.count)
        for hit in hits {
            let full = try await fetch(hit.id)
            messages.append(indexedMessage(id: hit.id, full: full))
        }
        return messages
    }

    /// Maps one fetched body to the indexed message shape with agent-visible redaction.
    ///
    /// Shared by the session plus one-shot paths so recall parity cannot drift:
    /// the store keeps the redacted form so a later recall cannot resurrect a
    /// link or code the tools would hide. Senders stay visible; subject links
    /// and codes redact like body links and codes, and a disabled filter
    /// indexes byte-identically.
    /// - Parameters:
    ///   - id: IMAP UID of the message.
    ///   - full: Full fetched body.
    /// - Returns: Indexed message with visible subject plus body.
    private func indexedMessage(id: String, full: EmailFullMessage) -> MailIndexMessage {
        let visibleBody = EmailCredentialFilter.agentVisibleBody(
            subject: full.subject,
            body: full.body,
            enabled: credentialFilterEnabled
        )
        let visibleSubject = EmailCredentialFilter.agentVisibleSubject(
            subject: full.subject,
            body: full.body,
            enabled: credentialFilterEnabled
        )
        return MailIndexMessage(
            id: id,
            subject: visibleSubject,
            from: full.from,
            date: Self.date(from: full.date),
            body: visibleBody,
            attachments: full.attachments.map {
                MailIndexAttachmentInfo(
                    filename: $0.filename,
                    contentType: $0.contentType,
                    sizeBytes: $0.sizeBytes
                )
            }
        )
    }

    /// Builds the verbatim IMAP window for one downward backfill page.
    ///
    /// The named owner for the window shape is this builder: the criterion is
    /// always the exact shape `UID lo:hi` with bounds from the shared tiling
    /// helper, interpolated from integers only so no caller text can reach the
    /// wire. A bound at or below the mailbox start holds no UIDs and yields
    /// nil so the caller returns empty without dialing; bottom clamping keeps
    /// the first window inside the mailbox.
    /// - Parameter beforeUID: Exclusive upper bound for the page.
    /// - Returns: `UID lo:hi` criterion, or nil when the range is empty.
    public static func uidRangeCriterion(beforeUID: Int) -> String? {
        guard let window = MailIndexTiling.window(beforeUID: beforeUID) else { return nil }
        return "UID \(window.lower):\(window.upper)"
    }

    /// Fetches one attachment part read-only over the one-shot path.
    ///
    /// Stays on the one-shot gateway by design even while a mailbox session
    /// is open: the pooled session speaks only open, status, search, fetch,
    /// and close, so there is no pooled attachment op to ride. Attachments
    /// stay one-shot on purpose because they are bounded and few (per-file
    /// and total caps, listing plus probe once per run); adding a session
    /// attachment op would pay handshake and session complexity without the
    /// per-message saving that search plus fetch earn by riding the open
    /// session. Bytes stay identical to the standalone path.
    /// - Parameters:
    ///   - credentials: Resolved connection fields plus password.
    ///   - mailbox: Mailbox holding the message.
    ///   - messageID: IMAP UID of the message.
    ///   - attachmentIndex: Zero-based position in the message's attachment list.
    ///   - mode: Fetch mode; the live bridge is always read-only.
    /// - Returns: Decoded attachment bytes.
    public func attachment(
        credentials: MailIndexCredentials,
        mailbox: String,
        messageID: String,
        attachmentIndex: Int,
        mode _: MailFetchMode
    ) async throws -> MailIndexAttachmentData {
        let fetched = try await gateway.attachment(
            credentials: credentials.resolvedEmailCredentials(),
            mailbox: mailbox,
            messageID: messageID,
            attachmentIndex: attachmentIndex
        )
        return MailIndexAttachmentData(
            filename: fetched.filename,
            contentType: fetched.contentType,
            sizeBytes: fetched.sizeBytes,
            data: fetched.data
        )
    }

    /// Parses an RFC 2822 or ISO-8601 date header.
    /// - Parameter header: Raw `Date` header from the bridge.
    /// - Returns: Parsed date, or nil when absent or unparseable.
    private static func date(from header: String) -> Date? {
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "dd MMM yyyy HH:mm:ss Z",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd HH:mm:ss Z"
        ]
        for format in formats {
            if let parsed = SharedDateFormatters.posixDate(from: trimmed, format: format) {
                return parsed
            }
        }
        return SharedDateFormatters.isoDefaultDate(from: trimmed)
    }
}

private extension MailIndexCredentials {
    /// Builds the bridge credential shape from resolved indexing credentials.
    /// - Returns: Credentials for the shared IMAP gateway.
    func resolvedEmailCredentials() -> ResolvedEmailCredentials {
        ResolvedEmailCredentials(
            accountName: accountName,
            host: host,
            port: port,
            username: username,
            password: password
        )
    }
}

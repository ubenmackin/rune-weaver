// Rune Weaver Tools — Adapter binding the shared IMAP gateway to the mail indexer seam.
//
// The core mail indexer enumerates mail through a read-only protocol seam so it
// stays free of the tool layer. This adapter maps that seam onto the existing
// `EmailIMAPGateway`, whose live implementation runs the `EmailIMAPBridge`
// subprocess: it lists selectable mailboxes, reads the newest message page,
// fetches each message for indexing, and reads attachment parts. Every read
// flows through the bridge's `BODY.PEEK` path, so indexing never marks mail as
// seen. Credentials are built only at execution time and are never logged.

import Foundation
import RuneWeaverCore

/// Bridges an ``EmailIMAPGateway`` to the core mail indexer seam.
public struct EmailIMAPMailIndexGateway: MailIndexGateway, Sendable {
    /// Underlying IMAP gateway (subprocess bridge by default).
    private let gateway: any EmailIMAPGateway
    /// Whether indexed bodies carry the redacted agent-visible form. Defaults
    /// on so search recall cannot resurrect a redacted link; false keeps the
    /// raw body for debugging parity checks.
    private let credentialFilterEnabled: Bool

    /// Creates an adapter over an IMAP gateway.
    /// - Parameters:
    ///   - gateway: Gateway whose read-only operations back the seam.
    ///   - credentialFilterEnabled: False indexes raw bodies byte-identically.
    public init(gateway: any EmailIMAPGateway, credentialFilterEnabled: Bool = true) {
        self.gateway = gateway
        self.credentialFilterEnabled = credentialFilterEnabled
    }

    /// Creates an adapter honoring the `[security]` defense policy.
    /// - Parameters:
    ///   - gateway: Gateway whose read-only operations back the seam.
    ///   - securityConfig: Defense policy carrying the filter toggle.
    public init(gateway: any EmailIMAPGateway, securityConfig: SecurityConfig) {
        self.init(gateway: gateway, credentialFilterEnabled: securityConfig.emailCredentialFilter)
    }

    /// Lists selectable mailboxes for an account.
    /// - Parameter credentials: Resolved connection fields plus password.
    /// - Returns: Selectable mailbox names in server order.
    public func mailboxes(credentials: MailIndexCredentials) async throws -> [String] {
        try await gateway.mailboxListing(credentials: credentials.resolvedEmailCredentials()).mailboxes
    }

    /// Returns the newest messages in one mailbox, newest first.
    ///
    /// The owner for the backfill criterion shape is this adapter: a present
    /// bound is expressed as a verbatim `UID 1:N` range with `N` equal to the
    /// bound minus one, built from integers only with no free text, so the
    /// bridge issues `UID SEARCH UID 1:N` and returns the newest page inside
    /// that range. A bound at or below the mailbox start holds no UIDs and
    /// returns empty without dialing. The core indexer filters this page
    /// against its UID watermark and pages strictly downward, so each call
    /// stays clamped to one newest page.
    /// - Parameters:
    ///   - credentials: Resolved connection fields plus password.
    ///   - mailbox: Mailbox to read.
    ///   - limit: Maximum messages to return.
    ///   - mode: Fetch mode; the live bridge is always read-only.
    ///   - beforeUID: Exclusive upper bound for this page; only UIDs below the
    ///     bound are returned. Nil fetches the newest window.
    /// - Returns: Messages in newest-first order.
    public func messages(
        credentials: MailIndexCredentials,
        mailbox: String,
        limit: Int,
        mode _: MailFetchMode,
        beforeUID: Int? = nil
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
            query = ""
        }
        let hits = try await gateway.search(credentials: resolved, mailbox: mailbox, query: query, limit: clamped)
        var messages: [MailIndexMessage] = []
        messages.reserveCapacity(hits.count)
        for hit in hits {
            let full = try await gateway.fetch(credentials: resolved, mailbox: mailbox, messageID: hit.id)
            // Index parity: the store keeps the redacted agent-visible form so
            // a later recall cannot resurrect a link or code the tools would
            // hide. Senders stay visible; subject links and codes redact like
            // body links and codes, and a disabled filter indexes byte-identically.
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
            messages.append(
                MailIndexMessage(
                    id: hit.id,
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
            )
        }
        return messages
    }

    /// Builds the verbatim IMAP range for one downward backfill page.
    ///
    /// The criterion is always the exact shape `UID 1:N` with `N` equal to the
    /// bound minus one, interpolated from integers only so no caller text can
    /// reach the wire. A bound at or below the mailbox start holds no UIDs and
    /// yields nil so the caller returns empty without dialing.
    /// - Parameter beforeUID: Exclusive upper bound for the page.
    /// - Returns: `UID 1:N` criterion, or nil when the range is empty.
    public static func uidRangeCriterion(beforeUID: Int) -> String? {
        let upper = beforeUID - 1
        guard upper >= 1 else { return nil }
        return "UID 1:\(upper)"
    }

    /// Fetches one attachment part read-only.
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

// Rune Weaver Tools — Adapter binding the shared IMAP gateway to the mail indexer seam.
//
// The core mail indexer enumerates mail through a read-only protocol seam so it
// stays free of the tool layer. This adapter maps that seam onto the existing
// `EmailIMAPGateway`: it lists selectable mailboxes, reads the newest message page
// via batched one-shot fetch, and reads attachment parts. Every read flows through
// the bridge's `BODY.PEEK` path, so indexing never marks mail as seen.

import Foundation
import RuneWeaverCore

/// Bridges an ``EmailIMAPGateway`` to the core mail indexer seam.
public struct EmailIMAPMailIndexGateway: MailIndexGateway, Sendable {
    /// Fixed UID window width bounding every backfill SEARCH.
    public static let uidWindowWidth = MailIndexTiling.uidWindowWidth

    /// Underlying IMAP gateway (subprocess bridge by default).
    private let gateway: any EmailIMAPGateway
    /// Whether indexed bodies carry the redacted agent-visible form.
    private let credentialFilterEnabled: Bool
    /// Event log sink for diagnostic traceability.
    private let eventLog: MailSessionEventLog

    /// Creates an adapter over an IMAP gateway.
    public init(
        gateway: any EmailIMAPGateway,
        credentialFilterEnabled: Bool = true,
        eventLog: MailSessionEventLog? = nil
    ) {
        self.gateway = gateway
        self.credentialFilterEnabled = credentialFilterEnabled
        self.eventLog = eventLog ?? .live
    }

    /// Creates an adapter honoring the `[security]` defense policy.
    public init(
        gateway: any EmailIMAPGateway,
        securityConfig: SecurityConfig,
        eventLog: MailSessionEventLog? = nil
    ) {
        self.init(
            gateway: gateway,
            credentialFilterEnabled: securityConfig.emailCredentialFilter,
            eventLog: eventLog
        )
    }

    /// Default session open no-op fulfilling the MailIndexGateway protocol.
    public func openMailboxSession(credentials _: MailIndexCredentials, mailbox _: String) async throws {}

    /// Default session close no-op fulfilling the MailIndexGateway protocol.
    public func closeMailboxSession(credentials _: MailIndexCredentials, mailbox _: String) async {}

    /// Maps STATUS validation plus unknown-account failures to Core-owned errors.
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
    public func mailboxes(credentials: MailIndexCredentials) async throws -> [String] {
        let start = Date()
        let resolved = credentials.resolvedEmailCredentials()
        do {
            let listing = try await gateway.mailboxListing(credentials: resolved)
            let latencyMs = Date().timeIntervalSince(start) * 1000
            eventLog.emit(
                event: "mailboxes.list",
                account: credentials.accountName,
                pid: nil,
                fields: ["count": listing.mailboxes.count, "latencyMs": latencyMs, "ok": true]
            )
            return listing.mailboxes
        } catch {
            let latencyMs = Date().timeIntervalSince(start) * 1000
            eventLog.emit(
                event: "mailboxes.list",
                account: credentials.accountName,
                pid: nil,
                fields: ["latencyMs": latencyMs, "ok": false, "error": error.localizedDescription]
            )
            throw error
        }
    }

    /// Returns the mailbox status snapshot for backfill anchoring.
    public func mailboxStatus(credentials: MailIndexCredentials, mailbox: String) async throws -> MailIndexMailboxStatus {
        let start = Date()
        do {
            let status = try await gateway.status(
                credentials: credentials.resolvedEmailCredentials(),
                mailbox: mailbox
            )
            let latencyMs = Date().timeIntervalSince(start) * 1000
            eventLog.emit(
                event: "mailbox.status",
                account: credentials.accountName,
                pid: nil,
                fields: [
                    "mailbox": mailbox,
                    "uidNext": status.uidNext,
                    "uidValidity": status.uidValidity,
                    "latencyMs": latencyMs,
                    "ok": true
                ]
            )
            return MailIndexMailboxStatus(uidNext: status.uidNext, uidValidity: status.uidValidity)
        } catch {
            let latencyMs = Date().timeIntervalSince(start) * 1000
            eventLog.emit(
                event: "mailbox.status",
                account: credentials.accountName,
                pid: nil,
                fields: ["mailbox": mailbox, "latencyMs": latencyMs, "ok": false, "error": error.localizedDescription]
            )
            if let mapped = Self.mapStatusError(error) {
                throw mapped
            }
            throw error
        }
    }

    /// Returns the newest messages in one mailbox, newest first.
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
            guard let criterion = Self.uidRangeCriterion(beforeUID: beforeUID) else {
                return []
            }
            query = criterion
        } else {
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
        let start = Date()
        eventLog.emit(
            event: "messages.batch.start",
            account: credentials.accountName,
            pid: nil,
            fields: [
                "mailbox": mailbox,
                "query": query,
                "beforeUID": beforeUID ?? -1,
                "limit": clamped
            ]
        )
        do {
            let fullMessages = try await gateway.batchFetch(
                credentials: resolved,
                mailbox: mailbox,
                query: query,
                limit: clamped
            )
            let latencyMs = Date().timeIntervalSince(start) * 1000
            let uids = fullMessages.compactMap { Int($0.id) }
            eventLog.emit(
                event: "messages.batch.result",
                account: credentials.accountName,
                pid: nil,
                fields: [
                    "mailbox": mailbox,
                    "query": query,
                    "count": fullMessages.count,
                    "minUID": uids.min() ?? -1,
                    "maxUID": uids.max() ?? -1,
                    "latencyMs": latencyMs,
                    "ok": true
                ]
            )
            return fullMessages.map { indexedMessage(id: $0.id, full: $0) }
        } catch {
            let latencyMs = Date().timeIntervalSince(start) * 1000
            eventLog.emit(
                event: "messages.batch.result",
                account: credentials.accountName,
                pid: nil,
                fields: [
                    "mailbox": mailbox,
                    "query": query,
                    "latencyMs": latencyMs,
                    "ok": false,
                    "error": error.localizedDescription
                ]
            )
            throw error
        }
    }

    /// Fetches one attachment part read-only over the one-shot path.
    public func attachment(
        credentials: MailIndexCredentials,
        mailbox: String,
        messageID: String,
        attachmentIndex: Int,
        mode _: MailFetchMode
    ) async throws -> MailIndexAttachmentData {
        let resolved = credentials.resolvedEmailCredentials()
        let part = try await gateway.attachment(
            credentials: resolved,
            mailbox: mailbox,
            messageID: messageID,
            attachmentIndex: attachmentIndex
        )
        return MailIndexAttachmentData(
            filename: part.filename,
            contentType: part.contentType,
            sizeBytes: part.sizeBytes,
            data: part.data
        )
    }

    /// Builds the newest-window criterion from a STATUS `uidNext`.
    private static func newestWindowCriterion(uidNext: Int) -> String? {
        guard let window = MailIndexTiling.newestWindow(uidNext: uidNext) else { return nil }
        return "UID \(window.lower):\(window.upper)"
    }

    /// Maps one fetched body to the indexed message shape with agent-visible redaction.
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
    public static func uidRangeCriterion(beforeUID: Int) -> String? {
        guard let window = MailIndexTiling.window(beforeUID: beforeUID) else { return nil }
        return "UID \(window.lower):\(window.upper)"
    }

    /// Parses an RFC 2822 / 5322 date string into a Swift `Date`.
    /// Tries shared POSIX layouts first, then ISO-8601, so varied bridge date
    /// headers still match dated queries without per-message formatter setup.
    private static func date(from raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "dd MMM yyyy HH:mm:ss Z",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ssXXXXX",
            "yyyy-MM-dd HH:mm:ss Z"
        ]
        // One shared POSIX helper serves every layout; no per-message allocation.
        for format in formats {
            if let parsed = SharedDateFormatters.posixDate(from: trimmed, format: format) {
                return parsed
            }
        }
        return SharedDateFormatters.isoDefaultDate(from: trimmed)
    }
}

extension MailIndexCredentials {
    /// Builds the bridge credential shape from resolved indexing credentials.
    fileprivate func resolvedEmailCredentials() -> ResolvedEmailCredentials {
        ResolvedEmailCredentials(
            accountName: accountName,
            host: host,
            port: port,
            username: username,
            password: password
        )
    }
}

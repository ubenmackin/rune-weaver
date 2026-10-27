// Rune Weaver Tools — Default EmailIMAPGateway shims over minimal conformers.

import Foundation
import RuneWeaverCore

extension EmailIMAPGateway {
    /// Default batch fetch shim for gateways that only implement individual fetch.
    public func batchFetch(
        credentials: ResolvedEmailCredentials,
        mailbox: String,
        query: String,
        limit: Int
    ) async throws -> [EmailFullMessage] {
        let hits = try await search(credentials: credentials, mailbox: mailbox, query: query, limit: limit)
        var messages: [EmailFullMessage] = []
        for hit in hits {
            try await messages.append(fetch(credentials: credentials, mailbox: mailbox, messageID: hit.id))
        }
        return messages
    }

    /// Default attachment-filter shim for gateways that only implement base search.
    /// Applies the filter locally so filtered callers never silently receive unfiltered hits.
    public func search(
        credentials: ResolvedEmailCredentials,
        mailbox: String,
        query: String,
        limit: Int,
        hasAttachment: Bool?
    ) async throws -> [EmailSearchHit] {
        let hits = try await search(credentials: credentials, mailbox: mailbox, query: query, limit: limit)
        return hits.filter { $0.matches(hasAttachment: hasAttachment) }
    }

    /// Default temporal shim routing through the combined filter so stubs without
    /// IMAP date support still honor the window via local post-filtering.
    public func search(
        credentials: ResolvedEmailCredentials,
        mailbox: String,
        query: String,
        limit: Int,
        since: Date?,
        until: Date?
    ) async throws -> [EmailSearchHit] {
        try await search(
            credentials: credentials,
            mailbox: mailbox,
            query: query,
            limit: limit,
            hasAttachment: nil,
            range: (since != nil || until != nil) ? TemporalRange(since: since, until: until) : nil
        )
    }

    /// Default combined shim for gateways that only implement the older shapes.
    /// Reapplies the window locally with the shared date parser so day-granular
    /// bridges still honor exact datetimes; undated hits only survive unbounded windows.
    public func search(
        credentials: ResolvedEmailCredentials,
        mailbox: String,
        query: String,
        limit: Int,
        hasAttachment: Bool?,
        range: TemporalRange?
    ) async throws -> [EmailSearchHit] {
        let hits = try await search(
            credentials: credentials,
            mailbox: mailbox,
            query: query,
            limit: limit,
            hasAttachment: hasAttachment
        )
        guard let range, !range.isUnbounded else { return hits }
        return hits.filter { TemporalFilter.matches(date: EmailSearchMerge.date(of: $0), in: range) }
    }

    /// Default structured shim for gateways without native field-scoped search.
    /// Folds `sinceDays` into the window and enforces sender/subject locally; unread
    /// scoping has no local signal, so it fails closed instead of returning unfiltered hits.
    public func search(
        credentials: ResolvedEmailCredentials,
        mailbox: String,
        query: String,
        limit: Int,
        filters: EmailStructuredSearchFilters
    ) async throws -> [EmailSearchHit] {
        if filters.unreadOnly {
            throw EmailIMAPError.bridgeFailed("IMAP search with unreadOnly is not supported by this gateway")
        }
        if let days = filters.sinceDays {
            try EmailIMAPValidation.validateSinceDays(days)
        }
        let effectiveRange = StructuredSearchBounds.effectiveRange(filters.range, sinceDays: filters.sinceDays)
        let hits = try await search(
            credentials: credentials,
            mailbox: mailbox,
            query: query,
            limit: limit,
            hasAttachment: filters.hasAttachment,
            range: effectiveRange
        )
        return hits.filter { $0.matchesFieldScope(from: filters.from, subject: filters.subject) }
    }

    /// Default search overload accepting separate `since` and `until` date bounds.
    public func search(
        credentials: ResolvedEmailCredentials,
        mailbox: String,
        query: String,
        limit: Int,
        hasAttachment: Bool? = nil,
        since: Date? = nil,
        until: Date? = nil
    ) async throws -> [EmailSearchHit] {
        try await search(
            credentials: credentials,
            mailbox: mailbox,
            query: query,
            limit: limit,
            hasAttachment: hasAttachment,
            range: (since != nil || until != nil) ? TemporalRange(since: since, until: until) : nil
        )
    }

    /// Default compatibility shim over the single required `mailboxListing`.
    /// `mailboxListing` is the only required listing method so conformers cannot
    /// satisfy the protocol with neither method and recurse between defaults.
    public func listMailboxes(credentials: ResolvedEmailCredentials) async throws -> [String] {
        try await mailboxListing(credentials: credentials).mailboxes
    }

    /// Default move that fails closed for gateways without move support.
    public func move(
        credentials _: ResolvedEmailCredentials,
        mailbox _: String,
        messageID _: String,
        destination _: String,
        markAsRead _: Bool
    ) async throws -> EmailMoveResult {
        throw EmailIMAPError.bridgeFailed("IMAP move not supported")
    }

    /// Default status that fails closed for gateways without STATUS support.
    public func status(credentials _: ResolvedEmailCredentials, mailbox _: String) async throws -> EmailMailboxStatus {
        throw EmailIMAPError.bridgeFailed("IMAP status not supported")
    }
}

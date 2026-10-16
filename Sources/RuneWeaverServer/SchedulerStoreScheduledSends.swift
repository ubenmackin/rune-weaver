// Rune Weaver Server — Deterministic scheduled-send registry: immutable bytes, exactly-once claim, durable replay.

import Foundation
import RuneWeaverCore
import RuneWeaverTools
#if canImport(SQLite3)
    import SQLite3
#endif

/// One approved scheduled send: exact bytes, recipient, and fire time stored at approval.
public struct ScheduledSend: Sendable, Codable, Equatable, Identifiable {
    /// Delivery channel the stored bytes replay through.
    public enum Channel: String, Sendable, Codable, Equatable {
        /// `email.send` over the configured SMTP account.
        case email
        /// `messages.send` over Apple Messages.
        case messages
    }

    /// Lifecycle of a scheduled send.
    public enum Status: String, Sendable, Codable, Equatable {
        /// Approved and waiting for its fire time.
        case queued
        /// Claimed by the fire worker exactly once; settles next.
        case sending
        /// Stored bytes delivered.
        case sent
        /// Stopped by the owner before firing.
        case cancelled
        /// Refused at fire time or skipped past due.
        case failed

        /// Whether the send has not reached a terminal state.
        public var isPending: Bool {
            switch self {
            case .queued, .sending: true
            case .sent, .cancelled, .failed: false
            }
        }
    }

    /// Stable scheduled-send identifier.
    public let id: UUID
    /// Delivery channel.
    public let channel: Channel
    /// Lifecycle status; only the store transitions it.
    public var status: Status
    /// Account nickname the email channel dials; nil for messages.
    public let account: String?
    /// Recipient exactly as approved.
    public let recipient: String
    /// Subject exactly as approved; nil for the messages channel.
    public let subject: String?
    /// Stored plain-body bytes; nil when the approval carried HTML only.
    public let bodyText: String?
    /// Stored HTML bytes; nil when the approval carried text only.
    public let bodyHtml: String?
    /// Approved fire time, minute-aligned.
    public let fireAt: Date
    /// When the send was booked.
    public let createdAt: Date
    /// When the row last changed.
    public var updatedAt: Date
    /// When the row settled to a terminal status.
    public var settledAt: Date?
    /// Why the row failed, when it did.
    public var failureReason: String?

    /// Creates a scheduled-send row.
    public init(
        id: UUID = UUID(),
        channel: Channel,
        status: Status = .queued,
        account: String? = nil,
        recipient: String,
        subject: String? = nil,
        bodyText: String? = nil,
        bodyHtml: String? = nil,
        fireAt: Date,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        settledAt: Date? = nil,
        failureReason: String? = nil
    ) {
        self.id = id
        self.channel = channel
        self.status = status
        self.account = account
        self.recipient = recipient
        self.subject = subject
        self.bodyText = bodyText
        self.bodyHtml = bodyHtml
        self.fireAt = fireAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.settledAt = settledAt
        self.failureReason = failureReason
    }

    /// Transitions the lifecycle status, stamping the bookkeeping a terminal state needs. Kept on
    /// the model so every writer stores the same timestamp pair and a settled reason never survives
    /// beside a non-terminal status.
    mutating func transition(to status: Status, at now: Date, failureReason: String? = nil) {
        self.status = status
        updatedAt = now
        if status.isPending {
            settledAt = nil
            self.failureReason = nil
        } else {
            settledAt = now
            self.failureReason = failureReason
        }
    }
}

/// Payload booking one approved scheduled send.
public struct NewScheduledSend: Sendable, Equatable {
    /// Delivery channel.
    public let channel: ScheduledSend.Channel
    /// Account nickname for the email channel; required then, nil for messages.
    public let account: String?
    /// Recipient exactly as approved.
    public let recipient: String
    /// Subject exactly as approved; required for the email channel.
    public let subject: String?
    /// Stored plain-body bytes; at least one body is required.
    public let bodyText: String?
    /// Stored HTML bytes; at least one body is required.
    public let bodyHtml: String?
    /// Requested fire time.
    public let fireAt: Date

    /// Creates a booking payload.
    public init(
        channel: ScheduledSend.Channel,
        account: String? = nil,
        recipient: String,
        subject: String? = nil,
        bodyText: String? = nil,
        bodyHtml: String? = nil,
        fireAt: Date
    ) {
        self.channel = channel
        self.account = account
        self.recipient = recipient
        self.subject = subject
        self.bodyText = bodyText
        self.bodyHtml = bodyHtml
        self.fireAt = fireAt
    }
}

/// Fail-closed bounds for scheduled-send payloads.
private enum ScheduledSendBounds {
    /// Longest accepted recipient.
    static let maxRecipientChars = 254
    /// Longest accepted subject (RFC 5322 line limit).
    static let maxSubjectChars = 998
    /// Longest accepted stored text, in characters.
    static let maxTextChars = 10000
    /// Largest accepted stored HTML body, in bytes.
    static let maxHtmlBytes = 1_048_576
    /// How long a due send stays claimable after its fire time before it is
    /// skipped as past due, so downtime never stacks catch-up fires.
    static let dueGraceSeconds: TimeInterval = 5 * 60
}

// MARK: - Store surface

extension SchedulerStore {
    /// Books one approved scheduled send.
    @discardableResult
    public func scheduleSend(_ input: NewScheduledSend, now: Date = Date()) async throws -> ScheduledSend {
        let row = try Self.validatedSend(input, now: now)
        let pending = scheduledSends.values.filter(\.status.isPending).count
        guard pending < Self.maxPendingSends else {
            throw SchedulerStoreError.invalidField(
                "Pending scheduled send limit reached (\(Self.maxPendingSends)). Cancel or wait for existing sends before booking new ones."
            )
        }
        scheduledSends[row.id] = row
        await persist(row)
        return row
    }

    /// Claims every queued send due at `now`, transitioning each to `sending` exactly once.
    public func claimDueSends(now: Date = Date()) async -> [ScheduledSend] {
        var claimed: [ScheduledSend] = []
        // Snapshot the candidates before mutating: the claim writes a status
        // transition back into the same registry the scan reads.
        let due = scheduledSends.values.filter { $0.status == .queued && $0.fireAt <= now }
        for row in due where now.timeIntervalSince(row.fireAt) <= ScheduledSendBounds.dueGraceSeconds {
            var sending = row
            sending.transition(to: .sending, at: now)
            scheduledSends[sending.id] = sending
            await persist(sending)
            claimed.append(sending)
        }
        return claimed.sorted { lhs, rhs in
            lhs.fireAt == rhs.fireAt ? lhs.createdAt < rhs.createdAt : lhs.fireAt < rhs.fireAt
        }
    }

    /// Settles queued sends whose fire time passed beyond the grace window to `failed`.
    public func expirePastDueSends(now: Date = Date()) async -> [ScheduledSend] {
        var skipped: [ScheduledSend] = []
        // Snapshot before mutating for the same reason as the claim: each
        // settled row writes back into the registry being scanned.
        let queued = scheduledSends.values.filter { $0.status == .queued }
        for row in queued where now.timeIntervalSince(row.fireAt) > ScheduledSendBounds.dueGraceSeconds {
            var expired = row
            expired.transition(
                to: .failed,
                at: now,
                failureReason: "Skipped: the engine was offline past this send's fire time."
            )
            scheduledSends[expired.id] = expired
            await persist(expired)
            skipped.append(expired)
        }
        return skipped.sorted { lhs, rhs in
            lhs.fireAt == rhs.fireAt ? lhs.createdAt < rhs.createdAt : lhs.fireAt < rhs.fireAt
        }
    }

    /// Cancels one queued send so it never fires.
    @discardableResult
    public func cancelScheduledSend(id: UUID, now: Date = Date()) async -> ScheduledSend? {
        guard var row = scheduledSends[id], row.status == .queued else { return nil }
        row.transition(to: .cancelled, at: now)
        scheduledSends[id] = row
        await persist(row)
        return row
    }

    /// Marks a claimed send delivered.
    @discardableResult
    public func markScheduledSendSent(id: UUID, now: Date = Date()) async -> ScheduledSend? {
        await settle(id: id, to: .sent, at: now, failureReason: nil)
    }

    /// Marks a claimed send failed with the reason its replay reported.
    @discardableResult
    public func markScheduledSendFailed(id: UUID, reason: String, now: Date = Date()) async -> ScheduledSend? {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return await settle(
            id: id,
            to: .failed,
            at: now,
            failureReason: String(trimmed.prefix(500))
        )
    }

    /// Lists every scheduled send, earliest fire time first.
    public func listScheduledSends() async -> [ScheduledSend] {
        scheduledSends.values.sorted { lhs, rhs in
            lhs.fireAt == rhs.fireAt ? lhs.createdAt < rhs.createdAt : lhs.fireAt < rhs.fireAt
        }
    }

    /// Looks up one scheduled send.
    /// - Parameter id: Scheduled-send identifier.
    /// - Returns: The row, or nil when unknown.
    public func scheduledSend(id: UUID) async -> ScheduledSend? {
        scheduledSends[id]
    }

    /// Number of sends that have not settled (queued or sending).
    public func pendingScheduledSendCount() async -> Int {
        scheduledSends.values.filter(\.status.isPending).count
    }

    /// Settles a claimed send, never resurrecting a row that already settled.
    private func settle(
        id: UUID,
        to status: ScheduledSend.Status,
        at now: Date,
        failureReason: String?
    ) async -> ScheduledSend? {
        guard var row = scheduledSends[id], row.status == .sending else { return nil }
        row.transition(to: status, at: now, failureReason: failureReason)
        scheduledSends[id] = row
        await persist(row)
        return row
    }

    /// Validates one booking payload into a queued row, sharing the sending
    /// tools' semantics so a stored payload always decodes cleanly at replay.
    private static func validatedSend(_ input: NewScheduledSend, now: Date) throws -> ScheduledSend {
        let recipient = input.recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !recipient.isEmpty else {
            throw SchedulerStoreError.invalidField("recipient must not be empty")
        }
        guard recipient.count <= ScheduledSendBounds.maxRecipientChars else {
            throw SchedulerStoreError.invalidField("recipient must be at most \(ScheduledSendBounds.maxRecipientChars) characters")
        }
        // A null byte truncates the AppleScript string a Messages send rides on
        // and has no legitimate place in an address, so reject at booking.
        if recipient.contains("\0") {
            throw SchedulerStoreError.invalidField("recipient must not contain null bytes")
        }
        // Blank bodies read as absent exactly like the sending tools treat them, so an HTML-only
        // send never fails on an empty text companion.
        let textValue = input.bodyText.flatMap { raw -> String? in
            raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : raw
        }
        let htmlValue = input.bodyHtml.flatMap { raw -> String? in
            raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : raw
        }
        guard textValue != nil || htmlValue != nil else {
            throw SchedulerStoreError.invalidField("provide body text or body HTML")
        }
        if input.channel == .messages, textValue == nil {
            throw SchedulerStoreError.invalidField("body text is required for a messages scheduled send")
        }
        if let textValue, textValue.count > ScheduledSendBounds.maxTextChars {
            throw SchedulerStoreError.invalidField("body text must be at most \(ScheduledSendBounds.maxTextChars) characters")
        }
        if let htmlValue, htmlValue.utf8.count > ScheduledSendBounds.maxHtmlBytes {
            throw SchedulerStoreError.invalidField("body HTML exceeds the 1 MB size cap")
        }
        var account: String?
        var subject: String?
        if input.channel == .email {
            let trimmedAccount = input.account?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmedAccount.isEmpty else {
                throw SchedulerStoreError.invalidField("account must not be empty for an email scheduled send")
            }
            let trimmedSubject = input.subject?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmedSubject.isEmpty else {
                throw SchedulerStoreError.invalidField("subject must not be empty for an email scheduled send")
            }
            if trimmedSubject.unicodeScalars.contains(where: { $0.value == 13 || $0.value == 10 }) {
                throw SchedulerStoreError.invalidField("subject must not contain CR or LF")
            }
            guard trimmedSubject.count <= ScheduledSendBounds.maxSubjectChars else {
                throw SchedulerStoreError.invalidField("subject must be at most \(ScheduledSendBounds.maxSubjectChars) characters")
            }
            account = trimmedAccount
            subject = trimmedSubject
        }
        // Fire-time bounds are shared with the sending tools so a booked send can
        // never disagree with the validation its deterministic replay runs.
        let fireAt: Date
        do {
            fireAt = try ScheduledSendTimeValidation.validateScheduleAt(input.fireAt, now: now)
        } catch let error as EmailIMAPError {
            throw SchedulerStoreError.invalidField(error.errorDescription ?? "Invalid scheduleAt")
        }
        return ScheduledSend(
            channel: input.channel,
            account: account,
            recipient: recipient,
            subject: subject,
            bodyText: textValue,
            bodyHtml: htmlValue,
            fireAt: fireAt,
            createdAt: now
        )
    }

    /// Reloads scheduled sends from durable state, settling claims a crash interrupted.
    func bootstrapScheduledSends() async {
        guard let dbPath else { return }
        #if canImport(SQLite3)
            let loaded: [ScheduledSend]
            do {
                loaded = try await SQLiteSerialIO.run {
                    SQLiteScheduledSendStore.read(dbPath: dbPath)
                }
            } catch {
                RuneWeaverLog.stores.error("SchedulerStore: failed reading scheduled sends from SQLite: \(error.localizedDescription)")
                loaded = []
            }
            var reloaded: [UUID: ScheduledSend] = [:]
            for var row in loaded {
                if row.status == .sending {
                    row.transition(
                        to: .failed,
                        at: Date(),
                        failureReason: "Interrupted: the engine stopped while this send was firing."
                    )
                    await persist(row)
                }
                reloaded[row.id] = row
            }
            scheduledSends = reloaded
        #endif
    }

    /// Persists one row through the serialized SQLite lane.
    private func persist(_ row: ScheduledSend) async {
        guard let dbPath else { return }
        #if canImport(SQLite3)
            let stored = row
            await SQLiteSerialIO.runUncancellable {
                SQLiteScheduledSendStore.write(row: stored, dbPath: dbPath)
            }
        #endif
    }
}

#if canImport(SQLite3)
    /// Internal SQLite helper for durable scheduled-send persistence.
    enum SQLiteScheduledSendStore {
        private struct ScheduledSendDBError: Error {
            let message: String
        }

        private static func open(dbPath: String) throws -> OpaquePointer? {
            // Shared busy_timeout/WAL policy lives in `SQLiteHelpers.openHandle`.
            let handle = try SQLiteHelpers.openHandle(dbPath: dbPath, unavailable: { ScheduledSendDBError(message: $0) })
            try SQLiteHelpers.exec(
                handle: handle,
                sql: """
                CREATE TABLE IF NOT EXISTS scheduled_sends(
                    id TEXT PRIMARY KEY,
                    channel TEXT NOT NULL,
                    status TEXT NOT NULL,
                    account TEXT,
                    recipient TEXT NOT NULL,
                    subject TEXT,
                    body_text TEXT,
                    body_html TEXT,
                    fire_at REAL NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    settled_at REAL,
                    failure_reason TEXT
                );
                CREATE INDEX IF NOT EXISTS idx_scheduled_sends_fire_at ON scheduled_sends(fire_at);
                """,
                failure: { ScheduledSendDBError(message: $0) }
            )
            return handle
        }

        static func read(dbPath: String) -> [ScheduledSend] {
            guard let handle = SQLiteOpenHelper.openLogged(
                dbPath: dbPath,
                storeName: "SQLiteScheduledSendStore",
                fallbackNote: "read returning in-memory state only",
                open: { try open(dbPath: dbPath) }
            ) else {
                return []
            }
            defer { sqlite3_close(handle) }

            let sql = """
            SELECT id, channel, status, account, recipient, subject, body_text, body_html,
                   fire_at, created_at, updated_at, settled_at, failure_reason
            FROM scheduled_sends
            ORDER BY fire_at ASC;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                return []
            }
            defer { sqlite3_finalize(statement) }

            var loaded: [ScheduledSend] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                // Rows with an unreadable identifier, channel, or status are
                // skipped rather than defaulted: a half-known send must never
                // load as a different channel or a queued state it never held.
                guard let idStr = SQLiteHelpers.columnText(statement, index: 0),
                      let id = UUID(uuidString: idStr),
                      let channelRaw = SQLiteHelpers.columnText(statement, index: 1),
                      let channel = ScheduledSend.Channel(rawValue: channelRaw),
                      let statusRaw = SQLiteHelpers.columnText(statement, index: 2),
                      let status = ScheduledSend.Status(rawValue: statusRaw),
                      let recipient = SQLiteHelpers.columnText(statement, index: 4)
                else { continue }
                let settledAt: Date? = sqlite3_column_type(statement, 11) == SQLITE_NULL
                    ? nil
                    : Date(timeIntervalSince1970: SQLiteHelpers.columnDouble(statement, index: 11))
                loaded.append(ScheduledSend(
                    id: id,
                    channel: channel,
                    status: status,
                    account: SQLiteHelpers.columnText(statement, index: 3),
                    recipient: recipient,
                    subject: SQLiteHelpers.columnText(statement, index: 5),
                    bodyText: SQLiteHelpers.columnText(statement, index: 6),
                    bodyHtml: SQLiteHelpers.columnText(statement, index: 7),
                    fireAt: Date(timeIntervalSince1970: SQLiteHelpers.columnDouble(statement, index: 8)),
                    createdAt: Date(timeIntervalSince1970: SQLiteHelpers.columnDouble(statement, index: 9)),
                    updatedAt: Date(timeIntervalSince1970: SQLiteHelpers.columnDouble(statement, index: 10)),
                    settledAt: settledAt,
                    failureReason: SQLiteHelpers.columnText(statement, index: 12)
                ))
            }
            return loaded
        }

        static func write(row: ScheduledSend, dbPath: String) {
            guard let handle = SQLiteOpenHelper.openLogged(
                dbPath: dbPath,
                storeName: "SQLiteScheduledSendStore",
                fallbackNote: "send \(row.id) kept in memory only and will not survive restart",
                open: { try open(dbPath: dbPath) }
            ) else {
                return
            }
            defer { sqlite3_close(handle) }

            // The payload columns are deliberately absent from the update set:
            // the approved bytes are immutable, so only lifecycle bookkeeping
            // moves once a row exists.
            let sql = """
            INSERT INTO scheduled_sends(
                id, channel, status, account, recipient, subject, body_text, body_html,
                fire_at, created_at, updated_at, settled_at, failure_reason
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                status = excluded.status,
                updated_at = excluded.updated_at,
                settled_at = excluded.settled_at,
                failure_reason = excluded.failure_reason;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                let code = sqlite3_errcode(handle)
                RuneWeaverLog.stores.error("SQLiteScheduledSendStore: failed preparing send write (code \(code)); send \(row.id) kept in memory only.")
                return
            }
            defer { sqlite3_finalize(statement) }

            SQLiteHelpers.bindText(statement, index: 1, value: row.id.uuidString)
            SQLiteHelpers.bindText(statement, index: 2, value: row.channel.rawValue)
            SQLiteHelpers.bindText(statement, index: 3, value: row.status.rawValue)
            SQLiteHelpers.bindText(statement, index: 4, value: row.account)
            SQLiteHelpers.bindText(statement, index: 5, value: row.recipient)
            SQLiteHelpers.bindText(statement, index: 6, value: row.subject)
            SQLiteHelpers.bindText(statement, index: 7, value: row.bodyText)
            SQLiteHelpers.bindText(statement, index: 8, value: row.bodyHtml)
            SQLiteHelpers.bindDouble(statement, index: 9, value: row.fireAt.timeIntervalSince1970)
            SQLiteHelpers.bindDouble(statement, index: 10, value: row.createdAt.timeIntervalSince1970)
            SQLiteHelpers.bindDouble(statement, index: 11, value: row.updatedAt.timeIntervalSince1970)
            if let settledAt = row.settledAt {
                SQLiteHelpers.bindDouble(statement, index: 12, value: settledAt.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(statement, 12)
            }
            SQLiteHelpers.bindText(statement, index: 13, value: row.failureReason)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                let code = sqlite3_errcode(handle)
                RuneWeaverLog.stores.error("SQLiteScheduledSendStore: failed writing send \(row.id) (code \(code)); in-memory state is ahead of disk.")
                return
            }
        }
    }
#endif

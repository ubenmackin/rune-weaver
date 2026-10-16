// Rune Weaver Core — Supporting types and protocol seams for incremental mail indexing.

import Foundation

// MARK: - UID window tiling

/// Single-sourced fixed UID window width bounding every backfill SEARCH.
public enum MailIndexTiling {
    /// Fixed UID window width bounding every backfill SEARCH.
    public static let uidWindowWidth = 1000

    /// Bounds for one fixed window ending below an exclusive bound. Single-sourced floor math
    /// shared by the adapter criterion builder and the indexer empty-window stepping so tiling stays
    /// exact across layers.
    public static func window(beforeUID: Int) -> (lower: Int, upper: Int)? {
        let upper = beforeUID - 1
        guard upper >= 1 else { return nil }
        let lower = max(1, upper - uidWindowWidth + 1)
        return (lower: lower, upper: upper)
    }

    /// Bounds for the newest window anchored from a STATUS `uidNext`. - Returns: Inclusive lower
    /// plus upper bounds, or nil when the mailbox is empty.
    public static func newestWindow(uidNext: Int) -> (lower: Int, upper: Int)? {
        let upper = uidNext - 1
        guard upper >= 1 else { return nil }
        return window(beforeUID: upper + 1)
    }
}

// MARK: - Mailbox key

/// Single-sourced account plus mailbox key shared by the session pool and checkpoints.
public func mailboxKey(account: String, mailbox: String) -> String {
    "\(account)\u{1F}\(mailbox.trimmingCharacters(in: .whitespacesAndNewlines))"
}

// MARK: - Gateway seam

/// Resolved credentials for one mail indexing run. The password exists only between execution-time
/// resolution and the gateway call.
public struct MailIndexCredentials: Sendable, Equatable {
    /// Account nickname the credentials belong to.
    public let accountName: String
    /// IMAP hostname.
    public let host: String
    /// IMAP port.
    public let port: Int
    /// Login username.
    public let username: String
    /// Runtime-resolved password. Never log, print, or persist.
    public let password: String

    /// Creates resolved credentials. accountName: Account nickname the credentials
    /// belong to.
    public init(accountName: String, host: String, port: Int, username: String, password: String) {
        self.accountName = accountName
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }
}

extension MailIndexCredentials: CustomStringConvertible, CustomDebugStringConvertible {
    /// Redacted summary naming only the account, user, and host.
    public var description: String {
        "MailCredentials(\(accountName): \(username)@\(host):\(port))"
    }

    /// Redacted debug summary mirroring ``description``.
    public var debugDescription: String {
        description
    }
}

/// One attachment part discovered from a message body structure.
public struct MailIndexAttachmentInfo: Sendable, Equatable {
    /// Original filename reported by the body structure.
    public let filename: String
    /// MIME type reported by the body structure.
    public let contentType: String
    /// Decoded part size in bytes when the structure reports it.
    public let sizeBytes: Int?

    /// Creates attachment metadata. filename: Original filename reported by the
    /// body structure.
    public init(filename: String, contentType: String, sizeBytes: Int? = nil) {
        self.filename = filename
        self.contentType = contentType
        self.sizeBytes = sizeBytes
    }
}

/// Attachment bytes fetched for one staging pass.
public struct MailIndexAttachmentData: Sendable, Equatable {
    /// Original filename.
    public let filename: String
    /// MIME type.
    public let contentType: String
    /// Decoded byte size.
    public let sizeBytes: Int
    /// Decoded attachment bytes.
    public let data: Data

    /// Creates fetched attachment bytes. filename: Original filename.
    public init(filename: String, contentType: String, sizeBytes: Int, data: Data) {
        self.filename = filename
        self.contentType = contentType
        self.sizeBytes = sizeBytes
        self.data = data
    }
}

/// One message fetched for indexing.
public struct MailIndexMessage: Sendable, Equatable {
    /// IMAP UID (the incremental watermark cursor).
    public let id: String
    /// Decoded `Subject` header.
    public let subject: String
    /// Decoded `From` header.
    public let from: String
    /// Parsed message date, used for the vector window.
    public let date: Date?
    /// Decoded plain-text body.
    public let body: String
    /// Attachment parts reported by the body structure.
    public let attachments: [MailIndexAttachmentInfo]
    /// Whole-message size in bytes when known.
    public let sizeBytes: Int?

    /// Creates a message for indexing. id: IMAP UID.
    public init(
        id: String,
        subject: String,
        from: String,
        date: Date?,
        body: String,
        attachments: [MailIndexAttachmentInfo] = [],
        sizeBytes: Int? = nil
    ) {
        self.id = id
        self.subject = subject
        self.from = from
        self.date = date
        self.body = body
        self.attachments = attachments
        self.sizeBytes = sizeBytes
    }
}

/// Fetch mode for a read-only IMAP request. Only `.peek` is defined: the indexer must never set
/// `\Seen`, so the seam cannot express a mutating fetch.
public enum MailFetchMode: String, Sendable, Equatable {
    /// `BODY.PEEK` — reads the part without setting the `\Seen` flag.
    case peek
}

/// Mailbox status snapshot for incremental backfill anchoring.
public struct MailIndexMailboxStatus: Sendable, Equatable {
    /// Next UID the server will assign, when known.
    public let uidNext: Int?
    /// Server validity token for the mailbox, when known.
    public let uidValidity: Int?

    /// Creates a mailbox status snapshot. uidNext: Next UID the server will assign,
    /// when known.
    public init(uidNext: Int?, uidValidity: Int?) {
        self.uidNext = uidNext
        self.uidValidity = uidValidity
    }
}

/// Read-only IMAP gateway seam the indexer enumerates through. Implementations are expected to use
/// `BODY.PEEK` for every fetch so an index run never marks mail as read.
public protocol MailIndexGateway: Sendable {
    /// Lists selectable mailboxes for an account.
    /// - Parameter credentials: Resolved connection fields plus password.
    /// - Returns: Selectable mailbox names in server order.
    func mailboxes(credentials: MailIndexCredentials) async throws -> [String]

    /// Returns the mailbox status snapshot for backfill anchoring. credentials:
    /// Resolved connection fields plus password.
    func mailboxStatus(credentials: MailIndexCredentials, mailbox: String) async throws -> MailIndexMailboxStatus

    /// Returns the newest messages in a mailbox, newest first.
    func messages(
        credentials: MailIndexCredentials,
        mailbox: String,
        limit: Int,
        mode: MailFetchMode,
        beforeUID: Int?
    ) async throws -> [MailIndexMessage]

    /// Fetches one attachment part read-only. credentials: Resolved connection
    /// fields plus password.
    func attachment(
        credentials: MailIndexCredentials,
        mailbox: String,
        messageID: String,
        attachmentIndex: Int,
        mode: MailFetchMode
    ) async throws -> MailIndexAttachmentData

    /// Starts or reuses the pooled session for one mailbox.
    func openMailboxSession(credentials: MailIndexCredentials, mailbox: String) async throws

    /// Closes plus evicts the pooled session for one mailbox, no-op when absent. Never throws so
    /// the mailbox bracket always terminates without masking the run outcome.
    func closeMailboxSession(credentials: MailIndexCredentials, mailbox: String) async
}

extension MailIndexGateway {
    /// Default status reporting unknown tokens so doubles without STATUS stay usable.
    /// - Parameters:
    /// - credentials: Resolved connection fields plus password.
    public func mailboxStatus(credentials _: MailIndexCredentials, mailbox _: String) async throws -> MailIndexMailboxStatus {
        MailIndexMailboxStatus(uidNext: nil, uidValidity: nil)
    }

    /// Default session open that no-ops so existing doubles compile untouched.
    /// credentials: Resolved connection fields plus password.
    public func openMailboxSession(credentials _: MailIndexCredentials, mailbox _: String) async throws {}

    /// Default session close that no-ops so existing doubles compile untouched.
    /// credentials: Resolved connection fields plus password.
    public func closeMailboxSession(credentials _: MailIndexCredentials, mailbox _: String) async {}
}

// MARK: - Errors

/// Failures raised while indexing mail.
public enum MailIndexError: Error, Sendable, Equatable {
    /// Attachment staging could not be confined to the Seatbelt temp policy.
    case stagingFailed(String)
    /// STATUS probe rejected its arguments fail-closed before any dial. Mapped by the gateway
    /// adapter from its validation failure so the indexer can match by type without importing the
    /// tool layer.
    case validationFailed(String)
    /// STATUS probe named an account absent from configuration. Mapped by the gateway adapter from
    /// its unknown-account failure so the indexer can match by type without importing the tool
    /// layer.
    case unknownAccount(String)
}

extension MailIndexError: LocalizedError {
    /// Human-readable message without any secret value.
    public var errorDescription: String? {
        switch self {
        case let .stagingFailed(detail):
            detail
        case let .validationFailed(detail):
            detail
        case let .unknownAccount(detail):
            detail
        }
    }
}

// MARK: - Vector window

/// How far back mail is vectorized.
public enum MailVectorWindow: Sendable, Equatable {
    /// Every message is vector-eligible regardless of age.
    case all
    /// Only messages newer than a trailing day window are vector-eligible.
    case trailing(days: Int)

    /// Trailing day count for the two-year window. Shared by the explicit `"2y"` token and the
    /// unknown-token fallback so the closed set and the parser cannot drift apart.
    public static let twoYearTrailingDays = 730

    /// Parses a configured window token. Unknown tokens fall back to the engine default (two years)
    /// so a bad value can only narrow the window, never open it unbounded.
    public init(token: String) {
        switch token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "all":
            self = .all
        case "30d":
            self = .trailing(days: 30)
        case "6m":
            self = .trailing(days: 183)
        case "1y":
            self = .trailing(days: 365)
        case "2y":
            self = .trailing(days: Self.twoYearTrailingDays)
        default:
            self = .trailing(days: Self.twoYearTrailingDays)
        }
    }

    /// Oldest date still eligible for an embedding.
    /// - Parameter now: Reference time for the window.
    /// - Returns: The cutoff date, or nil when the window is unbounded.
    public func cutoff(now: Date) -> Date? {
        switch self {
        case .all:
            nil
        case let .trailing(days):
            now.addingTimeInterval(-Double(days) * 86400)
        }
    }

    /// Whether a message date falls inside the window.
    public func includes(date: Date?, now: Date) -> Bool {
        guard let cutoff = cutoff(now: now) else { return true }
        guard let date else { return true }
        return date >= cutoff
    }
}

// MARK: - Checkpoints

/// Persisted indexer progress: per-mailbox UID watermarks, backfill floors, and content hashes.
public struct MailIndexCheckpoint: Sendable, Equatable, Codable {
    /// Highest indexed IMAP UID per `account{1F}mailbox` key.
    public var watermarks: [String: Int]
    /// Content hashes already indexed, oldest first, for forwarded-duplicate dedupe.
    public var contentHashes: [String]
    /// Last observed UIDVALIDITY per `account{1F}mailbox` key.
    public var uidValidities: [String: Int]
    /// Lowest indexed IMAP UID reached during backfill per `account{1F}mailbox` key.
    public var backfillFloors: [String: Int]

    /// Creates a checkpoint. watermarks: Highest indexed UID per mailbox key.
    public init(
        watermarks: [String: Int] = [:],
        contentHashes: [String] = [],
        uidValidities: [String: Int] = [:],
        backfillFloors: [String: Int] = [:]
    ) {
        self.watermarks = watermarks
        self.contentHashes = contentHashes
        self.uidValidities = uidValidities
        self.backfillFloors = backfillFloors
    }

    /// Coding keys for the checkpoint sidecar.
    private enum CodingKeys: String, CodingKey {
        /// Watermark map key.
        case watermarks
        /// Content-hash list key.
        case contentHashes
        /// Validity map key.
        case uidValidities
        /// Backfill floor map key.
        case backfillFloors
    }

    /// Decodes a checkpoint, defaulting missing maps so older sidecars migrate forward.
    /// - Parameter decoder: Decoder for the checkpoint document.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        watermarks = try container.decodeIfPresent([String: Int].self, forKey: .watermarks) ?? [:]
        contentHashes = try container.decodeIfPresent([String].self, forKey: .contentHashes) ?? []
        uidValidities = try container.decodeIfPresent([String: Int].self, forKey: .uidValidities) ?? [:]
        backfillFloors = try container.decodeIfPresent([String: Int].self, forKey: .backfillFloors) ?? [:]
    }

    /// Encodes the checkpoint including the validity and backfill floor maps.
    /// - Parameter encoder: Encoder for the checkpoint document.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(watermarks, forKey: .watermarks)
        try container.encode(contentHashes, forKey: .contentHashes)
        try container.encode(uidValidities, forKey: .uidValidities)
        try container.encode(backfillFloors, forKey: .backfillFloors)
    }
}

// MARK: - Report

/// Outcome of one mail indexing run.
public struct MailIndexRunReport: Sendable, Equatable {
    /// Accounts whose credentials resolved and whose mailbox listing succeeded.
    public var accountsScanned = 0
    /// Mailboxes enumerated across all accounts.
    public var mailboxesScanned = 0
    /// Denied mailboxes skipped without dialing.
    public var mailboxesSkipped = 0
    /// New messages considered after the UID watermark filter.
    public var messagesSeen = 0
    /// Messages written to the index.
    public var messagesIndexed = 0
    /// Messages skipped because their stored body hash was already current.
    public var messagesUnchanged = 0
    /// Messages skipped because their content hash matched an earlier message.
    public var messagesDeduplicated = 0
    /// Attachments staged, extracted, and deleted this run.
    public var attachmentsStaged = 0
    /// Attachments skipped for exceeding the per-attachment size cap.
    public var attachmentsSkippedOversize = 0
    /// Attachments whose text layer was unavailable, marked for the vision path.
    public var attachmentsMetadataOnly = 0
    /// Text chunks written this run.
    public var chunksWritten = 0
    /// Chunks written carrying an embedding this run.
    public var vectorsWritten = 0
    /// Mail documents retired because their mailbox joined the denylist.
    public var retiredCount = 0
    /// Non-fatal account- or mailbox-level problems, without any secret value.
    public var warnings: [String] = []
    /// Set when the run did not execute because mail indexing is disabled.
    public var skippedReason: String?

    /// Creates a run report.
    /// - Parameter skippedReason: Set when the run was skipped.
    public init(skippedReason: String? = nil) {
        self.skippedReason = skippedReason
    }

    /// Whether the indexer actually ran.
    public var didRun: Bool {
        skippedReason == nil
    }
}

// MARK: - Mail error classification

/// Single-source auth plus transport classifiers for mail failures.
public enum MailErrorClassification: Sendable {
    /// Auth phrases requiring whole-phrase word-boundary match.
    public static let authPhrases = ["auth failed", "authentication failed", "login failed"]
    /// Auth stems requiring a leading word boundary, allowing plural suffixes.
    public static let authStems = ["credential", "password", "login"]
    /// Timeout phrases shared by the session timeout check and the transport set.
    public static let timeoutPhrases = ["timed out", "timeout"]
    /// Transport phrases matched with word boundaries, including the explicit extension. Timeout
    /// wording is not repeated here; `isTransportFailureDetail` reuses `isTimeoutDetail` instead.
    public static let transportPhrases = [
        "connection reset",
        "connection abort",
        "broken pipe",
        "connection refused",
        "network is unreachable",
        "service unavailable",
        "connection closed"
    ]
    /// Single-word transport signals requiring whole-word match.
    public static let boundedTransportWords = ["eof", "closed"]

    /// Whether a bridge detail names an auth failure that must never retry or evict.
    /// - Parameter detail: Bridge error detail under test.
    /// - Returns: True when the detail carries an auth phrase or stem.
    public static func isAuthFailureDetail(_ detail: String) -> Bool {
        let lowered = detail.lowercased()
        for phrase in authPhrases where containsBounded(lowered, phrase) {
            return true
        }
        for stem in authStems where containsPrefixed(lowered, stem) {
            return true
        }
        return false
    }

    /// Whether a bridge detail names a transport timeout owned by outer retries.
    public static func isTimeoutDetail(_ detail: String) -> Bool {
        let lowered = detail.lowercased()
        for phrase in timeoutPhrases {
            if phrase.contains(" ") {
                if containsBounded(lowered, phrase) {
                    return true
                }
            } else if containsPrefixed(lowered, phrase) {
                return true
            }
        }
        return false
    }

    /// Whether a bridge detail names a retryable transport failure that must evict.
    public static func isTransportFailureDetail(_ detail: String) -> Bool {
        if isTimeoutDetail(detail) {
            return true
        }
        let lowered = detail.lowercased()
        for phrase in transportPhrases where containsBounded(lowered, phrase) {
            return true
        }
        for word in boundedTransportWords where containsBounded(lowered, word) {
            return true
        }
        return false
    }

    /// Whether `phrase` occurs with non-word characters on both sides. haystack:
    /// Lowercased text under test.
    private static func containsBounded(_ haystack: String, _ phrase: String) -> Bool {
        var start = haystack.startIndex
        while let range = haystack.range(of: phrase, range: start ..< haystack.endIndex) {
            let beforeOK: Bool = {
                guard range.lowerBound != haystack.startIndex else { return true }
                return !isWordCharacter(haystack[haystack.index(before: range.lowerBound)])
            }()
            let afterOK: Bool = {
                guard range.upperBound != haystack.endIndex else { return true }
                return !isWordCharacter(haystack[range.upperBound])
            }()
            if beforeOK, afterOK {
                return true
            }
            start = haystack.index(after: range.lowerBound)
            guard start < haystack.endIndex else { break }
        }
        return false
    }

    /// Whether `prefix` occurs with a non-word character before it. The trailing side stays
    /// unchecked so plural suffixes (`credentials`, `passwords`, `timeouts`) still match while
    /// embedded words (`author`) never do.
    private static func containsPrefixed(_ haystack: String, _ prefix: String) -> Bool {
        var start = haystack.startIndex
        while let range = haystack.range(of: prefix, range: start ..< haystack.endIndex) {
            if range.lowerBound == haystack.startIndex {
                return true
            }
            if !isWordCharacter(haystack[haystack.index(before: range.lowerBound)]) {
                return true
            }
            start = haystack.index(after: range.lowerBound)
            guard start < haystack.endIndex else { break }
        }
        return false
    }

    /// Whether a character counts as a word character for boundary checks. Mirrors `\b` semantics
    /// over letters, digits, and underscore so punctuation, whitespace, and string edges all act as
    /// boundaries.
    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }
}

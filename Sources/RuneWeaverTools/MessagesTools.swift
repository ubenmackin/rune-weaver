// Rune Weaver Tools — Apple Messages search, read, send, and recipient-resolution tools.

import Foundation
import RuneWeaverCore

#if canImport(SQLite3)
    import SQLite3
#endif

// MARK: - Models

/// Error conditions raised by Messages operations.
public enum MessagesToolError: Error, Sendable, LocalizedError, Equatable {
    case emptyRecipient
    case emptyMessage
    case invalidInput(String)
    case missingTarget
    case permissionDenied(String)
    case databaseUnavailable(String)
    case scriptFailed(String)
    /// `osascript` cannot drive Messages because Automation permission was denied.
    /// The payload is the complete owner-facing explanation, including where to grant access.
    case automationDenied(String)
    /// Messages could not turn the recipient handle into a sendable participant.
    /// The payload is the complete owner-facing explanation.
    case recipientUnresolved(String)

    public var errorDescription: String? {
        switch self {
        case .emptyRecipient:
            "Recipient cannot be empty."
        case .emptyMessage:
            "Message text cannot be empty."
        case let .invalidInput(detail):
            "Invalid messages.send input: \(detail)"
        case .missingTarget:
            "At least one of 'chatId' or 'recipient' must be specified."
        case let .permissionDenied(detail):
            "Full Disk Access is required to search and read macOS Messages: \(detail)"
        case let .databaseUnavailable(detail):
            "The Messages database is unavailable: \(detail)"
        case let .scriptFailed(detail):
            "Failed to send message: \(detail)"
        case let .automationDenied(detail):
            detail
        case let .recipientUnresolved(detail):
            detail
        }
    }
}

/// One message item returned by search or read.
public struct MessagesMessageItem: Sendable, Equatable, Codable {
    /// Message identifier (external GUID or row ID).
    public let id: String
    /// Message GUID.
    public let guid: String?
    /// Message text content.
    public let text: String
    /// ISO8601 formatted date string.
    public let date: String
    /// True if sent by the current user.
    public let isFromMe: Bool
    /// Display name or handle of sender.
    public let sender: String
    /// Identifier of the owning chat.
    public let chatID: String?
    /// Display name of the chat, when group or custom named.
    public let chatDisplayName: String?
    /// Reaction or tapback description, if applicable.
    public let tapback: String?
    /// Names of joined attachments.
    public let attachments: [String]

    public init(
        id: String,
        guid: String? = nil,
        text: String,
        date: String,
        isFromMe: Bool,
        sender: String,
        chatID: String? = nil,
        chatDisplayName: String? = nil,
        tapback: String? = nil,
        attachments: [String] = []
    ) {
        self.id = id
        self.guid = guid
        self.text = text
        self.date = date
        self.isFromMe = isFromMe
        self.sender = sender
        self.chatID = chatID
        self.chatDisplayName = chatDisplayName
        self.tapback = tapback
        self.attachments = attachments
    }
}

/// Outcome of a message send operation.
public struct MessagesSendResult: Sendable, Equatable, Codable {
    public let success: Bool
    public let recipient: String
    public let text: String
    public let details: String?
    /// Service targeted for this send, when history identified one; nil when unknown.
    public let service: String?
    /// Whether the sent message was observed in outgoing history: true when
    /// confirmed, false when polling timed out, nil when history was unreadable.
    /// Confirmation is evidence, never a gate, so nil must not read as failure.
    public let confirmed: Bool?

    public init(
        success: Bool,
        recipient: String,
        text: String,
        details: String? = nil,
        service: String? = nil,
        confirmed: Bool? = nil
    ) {
        self.success = success
        self.recipient = recipient
        self.text = text
        self.details = details
        self.service = service
        self.confirmed = confirmed
    }
}

// MARK: - Gateway Protocol

/// Interface for executing Messages operations.
public protocol MessagesGateway: Sendable {
    /// Searches messages across all conversations.
    ///
    /// Bounds are already-resolved instants: `since` is inclusive and `until`
    /// is exclusive, with nil meaning unbounded on that side. Undated rows
    /// never match once either bound is present.
    func search(query: String?, recipient: String?, limit: Int, since: Date?, until: Date?) async throws -> [MessagesMessageItem]
    /// Reads conversation history for a given chat or recipient.
    ///
    /// Bounds follow the same inclusive-since, exclusive-until contract as
    /// search, with nil meaning unbounded on that side.
    func read(chatID: String?, recipient: String?, limit: Int, since: Date?, until: Date?) async throws -> [MessagesMessageItem]
    /// Sends a message to a recipient.
    func send(recipient: String, text: String) async throws -> MessagesSendResult
}

// MARK: - Production Gateway

/// Production implementation reading `chat.db` via isolated snapshot and sending via AppleScript.
public struct ProductionMessagesGateway: MessagesGateway {
    public let chatDatabasePath: String

    public init(chatDatabasePath: String = MessagesIndexer.defaultChatDatabasePath) {
        self.chatDatabasePath = chatDatabasePath
    }

    public func search(query: String?, recipient: String?, limit: Int, since: Date? = nil, until: Date? = nil) async throws -> [MessagesMessageItem] {
        #if canImport(SQLite3)
            let snapshotURL: URL
            do {
                snapshotURL = try MessagesIndexer.snapshotDatabase(chatDatabasePath: chatDatabasePath)
            } catch let error as MessagesIndexError {
                switch error {
                case let .permissionDenied(detail):
                    throw MessagesToolError.permissionDenied(detail)
                case let .databaseUnavailable(detail):
                    throw MessagesToolError.databaseUnavailable(detail)
                default:
                    throw MessagesToolError.databaseUnavailable(error.localizedDescription)
                }
            }
            defer { try? FileManager.default.removeItem(at: snapshotURL) }

            let dbFile = snapshotURL.appendingPathComponent("chat.db").path
            let handle: OpaquePointer
            do {
                handle = try MessagesIndexer.openHandle(snapshotPath: dbFile)
            } catch let error as MessagesIndexError {
                switch error {
                case let .permissionDenied(detail):
                    throw MessagesToolError.permissionDenied(detail)
                default:
                    throw MessagesToolError.databaseUnavailable(error.localizedDescription)
                }
            }
            defer { sqlite3_close(handle) }

            let rows = try MessagesDatabaseIO.searchMessages(
                handle: handle,
                query: query,
                recipient: recipient,
                limit: max(limit * 2, 20),
                since: since,
                until: until
            )

            let names = MessagesContactNameResolver().displayNames()
            let trimmedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let isoFormatter = ISO8601DateFormatter()
            var items: [MessagesMessageItem] = []

            for row in rows {
                let resolved = MessagesIndexer.resolveText(for: row).text ?? ""
                if !trimmedQuery.isEmpty && trimmedQuery != "*" {
                    if !resolved.localizedCaseInsensitiveContains(trimmedQuery) {
                        continue
                    }
                }
                let sender = row.isFromMe ? "Me" : MessagesIndexer.displayName(for: row, names: names)
                let dateStr = row.date.map { isoFormatter.string(from: TemporalFilter.date(fromMacEpoch: $0)) } ?? ""
                let atts = (try? MessagesDatabaseIO.attachments(handle: handle, messageID: row.rowID)) ?? []
                let attNames = atts.map { MessagesIndexer.attachmentName(for: $0) }
                let tapback = MessagesTapback.description(for: row.associatedMessageType)

                items.append(
                    MessagesMessageItem(
                        id: row.externalID,
                        guid: row.guid,
                        text: resolved,
                        date: dateStr,
                        isFromMe: row.isFromMe,
                        sender: sender,
                        chatID: row.chatIdentifier ?? (row.chatID.map(String.init)),
                        chatDisplayName: row.chatDisplayName,
                        tapback: tapback,
                        attachments: attNames
                    )
                )
                if items.count >= limit {
                    break
                }
            }
            return items
        #else
            throw MessagesToolError.databaseUnavailable("SQLite3 is not available on this platform.")
        #endif
    }

    public func read(chatID: String?, recipient: String?, limit: Int, since: Date? = nil, until: Date? = nil) async throws -> [MessagesMessageItem] {
        #if canImport(SQLite3)
            let snapshotURL: URL
            do {
                snapshotURL = try MessagesIndexer.snapshotDatabase(chatDatabasePath: chatDatabasePath)
            } catch let error as MessagesIndexError {
                switch error {
                case let .permissionDenied(detail):
                    throw MessagesToolError.permissionDenied(detail)
                case let .databaseUnavailable(detail):
                    throw MessagesToolError.databaseUnavailable(detail)
                default:
                    throw MessagesToolError.databaseUnavailable(error.localizedDescription)
                }
            }
            defer { try? FileManager.default.removeItem(at: snapshotURL) }

            let dbFile = snapshotURL.appendingPathComponent("chat.db").path
            let handle: OpaquePointer
            do {
                handle = try MessagesIndexer.openHandle(snapshotPath: dbFile)
            } catch let error as MessagesIndexError {
                switch error {
                case let .permissionDenied(detail):
                    throw MessagesToolError.permissionDenied(detail)
                default:
                    throw MessagesToolError.databaseUnavailable(error.localizedDescription)
                }
            }
            defer { sqlite3_close(handle) }

            let rows = try MessagesDatabaseIO.conversationMessages(
                handle: handle,
                chatID: chatID,
                recipient: recipient,
                limit: limit,
                since: since,
                until: until
            )

            let names = MessagesContactNameResolver().displayNames()
            let isoFormatter = ISO8601DateFormatter()
            var items: [MessagesMessageItem] = []

            for row in rows.reversed() {
                let resolved = MessagesIndexer.resolveText(for: row).text ?? ""
                let sender = row.isFromMe ? "Me" : MessagesIndexer.displayName(for: row, names: names)
                let dateStr = row.date.map { isoFormatter.string(from: TemporalFilter.date(fromMacEpoch: $0)) } ?? ""
                let atts = (try? MessagesDatabaseIO.attachments(handle: handle, messageID: row.rowID)) ?? []
                let attNames = atts.map { MessagesIndexer.attachmentName(for: $0) }
                let tapback = MessagesTapback.description(for: row.associatedMessageType)

                items.append(
                    MessagesMessageItem(
                        id: row.externalID,
                        guid: row.guid,
                        text: resolved,
                        date: dateStr,
                        isFromMe: row.isFromMe,
                        sender: sender,
                        chatID: row.chatIdentifier ?? (row.chatID.map(String.init)),
                        chatDisplayName: row.chatDisplayName,
                        tapback: tapback,
                        attachments: attNames
                    )
                )
            }
            return items
        #else
            throw MessagesToolError.databaseUnavailable("SQLite3 is not available on this platform.")
        #endif
    }

    public func send(recipient: String, text: String) async throws -> MessagesSendResult {
        let trimmedRecipient = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRecipient.isEmpty else {
            throw MessagesToolError.emptyRecipient
        }
        guard !trimmedText.isEmpty else {
            throw MessagesToolError.emptyMessage
        }
        // Embedded null bytes truncate the AppleScript string literal at the
        // `osascript` boundary, so reject them before escaping rather than
        // passing a silently truncated message.
        guard !trimmedRecipient.contains("\0") else {
            throw MessagesToolError.invalidInput("Recipient must not contain null bytes.")
        }
        guard !trimmedText.contains("\0") else {
            throw MessagesToolError.invalidInput("Message text must not contain null bytes.")
        }
        // Only exact-address handles are sendable here: a name would guess at a
        // contact, and a near-miss phone spelling could dial the wrong number.
        // Resolving a name to a handle belongs to the caller, which passes the
        // canonical handle it selected.
        guard let canonicalRecipient = MessageRecipientClassification.canonicalHandle(trimmedRecipient) else {
            throw MessagesToolError.invalidInput("Recipient must be a phone number or email handle.")
        }

        let service = await observedService(for: canonicalRecipient)
        let script = MessagesAppleScriptSend.script(handle: canonicalRecipient, text: trimmedText, service: service)
        let result = try BoundedProcessRunner.runSync(
            executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: ["-e", script],
            timeoutSeconds: 15
        )
        guard result.exitCode == 0 else {
            throw MessagesAppleScriptErrorMapping.map(exitCode: result.exitCode, stderr: result.stderrString)
        }

        let confirmed: Bool?
        #if canImport(SQLite3)
            confirmed = await MessagesSendConfirmation.confirm(
                chatDatabasePath: chatDatabasePath,
                recipient: canonicalRecipient,
                attempts: 3,
                intervalSeconds: 0.75
            )
        #else
            confirmed = nil
        #endif
        return MessagesSendResult(
            success: true,
            recipient: canonicalRecipient,
            text: trimmedText,
            service: service,
            confirmed: confirmed
        )
    }

    /// Reads the handle's most recent transport from direct-chat history.
    ///
    /// History is an optimization, never a gate: an unreadable database (no
    /// Full Disk Access, no Messages history) yields nil and the send keeps the
    /// recovery script. Rows are keyed by canonical handle so formatting cannot
    /// hide a match, and the newest matching row wins because
    /// ``MessagesChatHistorySource`` returns stats newest first — a number that
    /// recently moved between services is addressed on the one it now uses.
    private func observedService(for recipient: String) async -> String? {
        #if canImport(SQLite3)
            guard let recipientKey = MessageRecipientNameNormalizer.handleKey(recipient) else {
                return nil
            }
            let history = MessagesChatHistorySource(chatDatabasePath: chatDatabasePath)
            guard let stats = try? await history.recentDirectHandleStats(limit: 200) else {
                return nil
            }
            return stats.first { MessageRecipientNameNormalizer.handleKey($0.handle) == recipientKey }?.service
        #else
            return nil
        #endif
    }

    /// Escapes special characters for safe AppleScript string literals.
    /// Callers reject embedded null bytes before escaping: a null truncates
    /// the `osascript` string, so it can never be escaped into safety.
    public static func escapeAppleScriptString(_ str: String) -> String {
        var escaped = ""
        for char in str {
            switch char {
            case "\\": escaped.append("\\\\")
            case "\"": escaped.append("\\\"")
            case "\n": escaped.append("\\n")
            case "\r": escaped.append("\\r")
            case "\t": escaped.append("\\t")
            default: escaped.append(char)
            }
        }
        return escaped
    }
}

// MARK: - Envelopes & Args

public struct MessagesSearchArgs: Sendable, Equatable, Decodable {
    public let query: String?
    public let recipient: String?
    public let limit: Int
    public let since: String?
    public let until: String?

    public static let defaultLimit = 10
    public static let maxLimit = 50

    public init(query: String? = nil, recipient: String? = nil, limit: Int = defaultLimit, since: String? = nil, until: String? = nil) {
        self.query = query
        self.recipient = recipient
        self.limit = min(max(limit, 1), Self.maxLimit)
        self.since = Self.normalizedBound(since)
        self.until = Self.normalizedBound(until)
    }

    private enum CodingKeys: String, CodingKey {
        case query
        case recipient
        case limit
        case since
        case until
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let query = try container.decodeIfPresent(String.self, forKey: .query)
        let recipient = try container.decodeIfPresent(String.self, forKey: .recipient)
        let rawLimit = try container.decodeIfPresent(Int.self, forKey: .limit) ?? Self.defaultLimit
        let since = try container.decodeIfPresent(String.self, forKey: .since)
        let until = try container.decodeIfPresent(String.self, forKey: .until)
        self.init(query: query, recipient: recipient, limit: rawLimit, since: since, until: until)
    }

    /// Blank strings behave as omitted so whitespace-only bounds stay unbounded.
    private static func normalizedBound(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

public struct MessagesSearchEnvelope: Sendable, Equatable, Codable {
    public let query: String?
    public let recipient: String?
    /// Canonical handle chosen when a name-shaped recipient resolved to one
    /// identity; nil for handle/absent recipients and for ambiguous names, which
    /// search every candidate instead of guessing.
    public let resolvedRecipient: String?
    /// Owner-facing guidance; non-nil only when a name-shaped recipient resolved
    /// to zero handles, in which case `messages` is empty and no gateway ran.
    public let note: String?
    public let count: Int
    public let messages: [MessagesMessageItem]

    public init(
        query: String?,
        recipient: String?,
        resolvedRecipient: String? = nil,
        note: String? = nil,
        messages: [MessagesMessageItem]
    ) {
        self.query = query
        self.recipient = recipient
        self.resolvedRecipient = resolvedRecipient
        self.note = note
        self.count = messages.count
        self.messages = messages
    }
}

public struct MessagesReadArgs: Sendable, Equatable, Decodable {
    public let chatID: String?
    public let recipient: String?
    public let limit: Int
    public let since: String?
    public let until: String?

    public static let defaultLimit = 20
    public static let maxLimit = 100

    public init(chatID: String? = nil, recipient: String? = nil, limit: Int = defaultLimit, since: String? = nil, until: String? = nil) {
        self.chatID = chatID
        self.recipient = recipient
        self.limit = min(max(limit, 1), Self.maxLimit)
        self.since = Self.normalizedBound(since)
        self.until = Self.normalizedBound(until)
    }

    private enum CodingKeys: String, CodingKey {
        case chatID = "chatId"
        case chatIDUnderscore = "chat_id"
        case recipient
        case limit
        case since
        case until
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let chatID = try container.decodeIfPresent(String.self, forKey: .chatID)
            ?? container.decodeIfPresent(String.self, forKey: .chatIDUnderscore)
        let recipient = try container.decodeIfPresent(String.self, forKey: .recipient)
        let rawLimit = try container.decodeIfPresent(Int.self, forKey: .limit) ?? Self.defaultLimit
        let since = try container.decodeIfPresent(String.self, forKey: .since)
        let until = try container.decodeIfPresent(String.self, forKey: .until)
        self.init(chatID: chatID, recipient: recipient, limit: rawLimit, since: since, until: until)
    }

    /// Blank strings behave as omitted so whitespace-only bounds stay unbounded.
    private static func normalizedBound(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

public struct MessagesReadEnvelope: Sendable, Equatable, Codable {
    public let chatID: String?
    public let recipient: String?
    /// Canonical handle chosen when a name-shaped recipient resolved to one
    /// identity; nil for chatId/handle/absent recipients and for ambiguous names,
    /// which read every candidate instead of guessing.
    public let resolvedRecipient: String?
    /// Owner-facing guidance; non-nil only when a name-shaped recipient resolved
    /// to zero handles, in which case `messages` is empty and no gateway ran.
    public let note: String?
    public let count: Int
    public let messages: [MessagesMessageItem]

    public init(
        chatID: String?,
        recipient: String?,
        resolvedRecipient: String? = nil,
        note: String? = nil,
        messages: [MessagesMessageItem]
    ) {
        self.chatID = chatID
        self.recipient = recipient
        self.resolvedRecipient = resolvedRecipient
        self.note = note
        self.count = messages.count
        self.messages = messages
    }
}

public struct MessagesSendArgs: Sendable, Equatable, Decodable {
    public let recipient: String
    public let text: String
    /// Original display name the recipient handle was resolved from, when the
    /// caller resolved a name first; nil for a directly supplied handle.
    public let resolvedFrom: String?

    public init(recipient: String, text: String, resolvedFrom: String? = nil) {
        self.recipient = recipient
        self.text = text
        self.resolvedFrom = resolvedFrom
    }

    private enum CodingKeys: String, CodingKey {
        case recipient
        case to
        case text
        case message
        case resolvedFrom
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let recipientVal = try container.decodeIfPresent(String.self, forKey: .recipient)
            ?? container.decodeIfPresent(String.self, forKey: .to)
        guard let recipientVal, !recipientVal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.keyNotFound(
                CodingKeys.recipient,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing 'recipient' or 'to'")
            )
        }
        // Reject embedded null bytes at the decode boundary: a null truncates
        // the AppleScript string passed to `osascript`.
        if recipientVal.contains("\0") {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Recipient must not contain null bytes.")
            )
        }
        let textVal = try container.decodeIfPresent(String.self, forKey: .text)
            ?? container.decodeIfPresent(String.self, forKey: .message)
        guard let textVal, !textVal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.keyNotFound(
                CodingKeys.text,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing 'text' or 'message'")
            )
        }
        if textVal.contains("\0") {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Message text must not contain null bytes.")
            )
        }
        // The resolved display name is echoed in refusals and remembered for
        // future lookups, so trim it for a clean record and reject null bytes
        // for the same AppleScript-truncation reason as recipient and text.
        let rawResolvedFrom = try container.decodeIfPresent(String.self, forKey: .resolvedFrom)
        if let rawResolvedFrom, rawResolvedFrom.contains("\0") {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "resolvedFrom must not contain null bytes.")
            )
        }
        let resolvedFrom = rawResolvedFrom?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(
            recipient: recipientVal,
            text: textVal,
            resolvedFrom: (resolvedFrom?.isEmpty ?? true) ? nil : resolvedFrom
        )
    }
}

public struct MessagesSendEnvelope: Sendable, Equatable, Codable {
    public let success: Bool
    public let recipient: String
    public let text: String
    public let note: String?
    /// Service targeted for this send, when history identified one; nil when unknown.
    public let service: String?
    /// Delivery confirmation from outgoing history; nil when it could not be read.
    public let confirmed: Bool?

    public init(
        success: Bool,
        recipient: String,
        text: String,
        note: String? = nil,
        service: String? = nil,
        confirmed: Bool? = nil
    ) {
        self.success = success
        self.recipient = recipient
        self.text = text
        self.note = note
        self.service = service
        self.confirmed = confirmed
    }
}

/// Arguments for resolving a recipient name or handle to sendable candidates.
public struct MessagesResolveRecipientArgs: Sendable, Equatable, Decodable {
    /// Raw recipient text: a name, nickname, phone number, or email; nil when omitted.
    public let name: String?
    /// Candidate budget, already clamped to the supported range.
    public let limit: Int

    public static let defaultLimit = 5
    public static let maxLimit = 10
    /// Longest accepted recipient query. Classification has its own, much wider
    /// bound; this one is the tool-level budget so a runaway string is refused
    /// with guidance instead of traveling into every lookup surface.
    public static let maxNameLength = 200

    public init(name: String? = nil, limit: Int = defaultLimit) {
        self.name = name
        self.limit = min(max(limit, 1), Self.maxLimit)
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case query
        case limit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // `query` is the accepted alias; `name` wins when both arrive so one call
        // can never carry two different recipients.
        let name = try container.decodeIfPresent(String.self, forKey: .name)
            ?? container.decodeIfPresent(String.self, forKey: .query)
        let rawLimit = try container.decodeIfPresent(Int.self, forKey: .limit) ?? Self.defaultLimit
        self.init(name: name, limit: rawLimit)
    }
}

/// Resolved recipient candidates for one query.
public struct MessagesResolveRecipientEnvelope: Sendable, Equatable, Codable {
    /// Query the resolution answered, echoed for correlation.
    public let query: String
    /// True when distinct top-scored identities remain, so no single candidate was chosen.
    public let ambiguous: Bool
    /// Chosen candidate when one identity won outright; nil when ambiguous or empty.
    public let resolved: MessageRecipientCandidate?
    /// Ranked candidates, best first.
    public let candidates: [MessageRecipientCandidate]
    /// Owner-facing guidance for an empty result; nil when any candidate exists.
    public let note: String?

    public init(
        query: String,
        ambiguous: Bool,
        resolved: MessageRecipientCandidate? = nil,
        candidates: [MessageRecipientCandidate],
        note: String? = nil
    ) {
        self.query = query
        self.ambiguous = ambiguous
        self.resolved = resolved
        self.candidates = candidates
        self.note = note
    }
}

// MARK: - Name Routing

/// Shared name-to-recipient routing for the read-only Messages tools.
///
/// Search and read accept the same recipient inputs and must agree on how one
/// typed name becomes a set of gateway calls, so classification, resolution,
/// handle dedupe, and the merge pipeline live here once. Ambiguity deliberately
/// fans out across every candidate handle — reading cannot dial the wrong
/// number, so it should show what each candidate said rather than refuse — while
/// handle-shaped and absent recipients stay on the pre-existing single call.
private enum MessagesRecipientRouting {
    /// Candidate budget for name resolution: enough to cover a person's handles
    /// without turning one lookup into an unbounded fan-out.
    static let candidateLimit = 5

    /// Whether `raw` classifies as a name rather than a handle.
    ///
    /// Unclassifiable input (blank, over-long) is deliberately not a name so the
    /// tools keep their pre-existing pass-through behavior for it.
    static func isName(_ raw: String) -> Bool {
        guard let classified = MessageRecipientClassification.classify(raw) else { return false }
        if case .name = classified {
            return true
        }
        return false
    }

    /// Resolves a name to deduped handles in ranked order plus the chosen handle.
    ///
    /// Dedupe is by normalized handle key, matching the resolver's identity rule,
    /// and keeps the first (best-ranked) spelling. A nil resolver resolves
    /// nothing, so a name-shaped recipient fails closed with guidance instead of
    /// reaching the gateway unaddressed.
    static func handles(
        for name: String,
        resolver: (any MessagesRecipientResolving)?
    ) async -> (handles: [String], resolvedRecipient: String?) {
        let resolution: MessageRecipientResolution = if let resolver {
            await resolver.resolve(name: name, limit: candidateLimit)
        } else {
            MessageRecipientResolution(query: name, candidates: [])
        }
        var seen: Set<String> = []
        var handles: [String] = []
        for candidate in resolution.candidates {
            let key = MessageRecipientNameNormalizer.handleKey(candidate.handle) ?? candidate.handle
            guard seen.insert(key).inserted else { continue }
            handles.append(candidate.handle)
        }
        return (handles, resolution.selected?.handle)
    }

    /// Merges per-handle results into one newest-first, capped list.
    ///
    /// Duplicate ids collapse to the first occurrence so a message reachable
    /// through two handles is reported once. Ordering compares the ISO8601 `date`
    /// string, which is chronological for that fixed format; undated rows sort
    /// last and equal dates keep discovery order, so the merge stays
    /// reproducible. The cap runs after the sort because callers asked for the
    /// newest `limit` messages overall, not per handle.
    static func merged(_ batches: [[MessagesMessageItem]], limit: Int) -> [MessagesMessageItem] {
        var seenIDs: Set<String> = []
        var merged: [MessagesMessageItem] = []
        for batch in batches {
            for item in batch {
                guard seenIDs.insert(item.id).inserted else { continue }
                merged.append(item)
            }
        }
        return merged.enumerated().sorted { lhs, rhs in
            let left = lhs.element.date
            let right = rhs.element.date
            if left.isEmpty != right.isEmpty {
                return !left.isEmpty
            }
            if left != right {
                return left > right
            }
            return lhs.offset < rhs.offset
        }.prefix(limit).map(\.element)
    }

    /// Guidance for a name that resolved to no handles at all.
    ///
    /// The wording names the two repairs the owner can actually perform, so the
    /// model asks for an exact handle instead of retrying the same name.
    /// "Enable for Contacts" names the Contacts row's Enable button in the
    /// Permissions window (the literal button label is the generic Enable),
    /// so the guidance points at the row affordance without renaming it.
    static func noMatchesNote(for name: String) -> String {
        "No contact or recent conversation matches \"" + name + "\". Pass a phone number or email, "
            + "or open Rune Weaver menu -> Permissions… -> Enable for Contacts."
    }
}

// MARK: - Tools

/// Searches macOS Messages by query, participant handle, or recent history.
public struct MessagesSearchTool: Tool, Sendable {
    public let name = "messages.search"
    public let description =
        "Searches macOS Messages by text query, participant/recipient, or lists recent messages. "
            + "Use when the user asks about text messages, iMessages, chats, or message history. "
            + "Returns matching messages, senders, timestamps, conversation IDs, reactions, and attachments."

    public let inputSchema = JSONSchema(
        rawValue: #"{"type":"object","properties":{"query":{"type":"string","description":"Search term to match "#
            + #"against message text; omitted, empty, or \"*\" returns newest messages"},"#
            + #""recipient":{"type":"string","description":"Optional phone number, email, contact name, or nickname to filter by; "#
            + #"names are resolved through Contacts and recent conversations."},"#
            + #""limit":{"type":"integer","description":"Maximum messages to return (1-50, default 10)","minimum":1,"maximum":50},"#
            + #""since":{"type":"string","description":"Optional lower bound YYYY-MM-DD (00:00:00 local inclusive) or full ISO8601 datetime"},"#
            + #""until":{"type":"string","description":"Optional upper bound YYYY-MM-DD (00:00:00 local exclusive) or full ISO8601 datetime"}},"#
            + #""additionalProperties":false}"#
    )

    public let permissionLevel = PermissionLevel.readOnly
    public var contentTrustLevel: ContentTrustLevel {
        .untrustedExternal
    }

    private let gateway: any MessagesGateway
    /// Name resolver for name-shaped recipients; nil fails such recipients
    /// closed with guidance rather than passing a name to the gateway.
    private let resolver: (any MessagesRecipientResolving)?

    public init(gateway: any MessagesGateway, resolver: (any MessagesRecipientResolving)? = nil) {
        self.gateway = gateway
        self.resolver = resolver
    }

    public func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        let args: MessagesSearchArgs
        do {
            args = try JSONDecoder().decode(MessagesSearchArgs.self, from: Data(input.argumentsJSON.utf8))
        } catch {
            let errorMsg = "Invalid messages.search arguments: expected {\"query\": \"...\", \"recipient\": \"...\", \"limit\": <1-50>}."
            return .failure(errorMsg, callID: input.callID)
        }

        let range: TemporalRange
        do {
            range = try TemporalFilter.parse(since: args.since, until: args.until)
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return .failure(detail, callID: input.callID)
        }

        // A name is not an address the gateway can filter on, so resolve it to
        // concrete handles first and query each. Trimming only feeds
        // classification and resolution; the original spelling still rides the
        // envelope so the caller sees exactly what it passed.
        let recipient = args.recipient?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let messages: [MessagesMessageItem]
            var resolvedRecipient: String?
            var note: String?
            if let recipient, MessagesRecipientRouting.isName(recipient) {
                let routing = await MessagesRecipientRouting.handles(for: recipient, resolver: resolver)
                if routing.handles.isEmpty {
                    // No handle to query: fail closed with guidance rather than
                    // sending the name to a gateway that cannot match it.
                    messages = []
                    note = MessagesRecipientRouting.noMatchesNote(for: recipient)
                } else {
                    var batches: [[MessagesMessageItem]] = []
                    for handle in routing.handles {
                        let batch = try await gateway.search(
                            query: args.query,
                            recipient: handle,
                            limit: args.limit,
                            since: range.since,
                            until: range.until
                        )
                        batches.append(batch)
                    }
                    messages = MessagesRecipientRouting.merged(batches, limit: args.limit)
                    resolvedRecipient = routing.resolvedRecipient
                }
            } else {
                messages = try await gateway.search(query: args.query, recipient: args.recipient, limit: args.limit, since: range.since, until: range.until)
            }
            let envelope = MessagesSearchEnvelope(
                query: args.query,
                recipient: args.recipient,
                resolvedRecipient: resolvedRecipient,
                note: note,
                messages: messages
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            let json = try String(bytes: encoder.encode(envelope), encoding: .utf8) ?? "{}"
            return .success(json, callID: input.callID)
        } catch let error as CancellationError {
            throw error
        } catch {
            return .failure("messages.search failed: \(error.localizedDescription)", callID: input.callID)
        }
    }
}

/// Reads conversation history and thread messages for a chat ID or recipient.
public struct MessagesReadTool: Tool, Sendable {
    public let name = "messages.read"
    public let description =
        "Reads conversation history and thread messages from macOS Messages for a chat ID or recipient. "
            + "Use when the user asks to see a conversation thread, chat log, or recent messages with someone. "
            + "Pass chatId (from messages.search) or recipient phone number/email."

    public let inputSchema = JSONSchema(
        rawValue: #"{"type":"object","properties":{"chatId":{"type":"string","description":"Chat identifier or GUID from messages.search"},"#
            + #""chat_id":{"type":"string","description":"Alias for chatId"},"#
            + #""recipient":{"type":"string","description":"Optional phone number, email, contact name, or nickname to filter by; "#
            + #"names are resolved through Contacts and recent conversations."},"#
            + #""limit":{"type":"integer","description":"Maximum messages to return (1-100, default 20)","minimum":1,"maximum":100},"#
            + #""since":{"type":"string","description":"Optional lower bound YYYY-MM-DD (00:00:00 local inclusive) or full ISO8601 datetime"},"#
            + #""until":{"type":"string","description":"Optional upper bound YYYY-MM-DD (00:00:00 local exclusive) or full ISO8601 datetime"}},"#
            + #""additionalProperties":false}"#
    )

    public let permissionLevel = PermissionLevel.readOnly
    public var contentTrustLevel: ContentTrustLevel {
        .untrustedExternal
    }

    private let gateway: any MessagesGateway
    /// Name resolver for name-shaped recipients; nil fails such recipients
    /// closed with guidance rather than passing a name to the gateway.
    private let resolver: (any MessagesRecipientResolving)?

    public init(gateway: any MessagesGateway, resolver: (any MessagesRecipientResolving)? = nil) {
        self.gateway = gateway
        self.resolver = resolver
    }

    public func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        let args: MessagesReadArgs
        do {
            args = try JSONDecoder().decode(MessagesReadArgs.self, from: Data(input.argumentsJSON.utf8))
        } catch {
            let errorMsg = "Invalid messages.read arguments: expected {\"chatId\": \"...\", \"recipient\": \"...\", \"limit\": <1-100>}."
            return .failure(errorMsg, callID: input.callID)
        }

        let range: TemporalRange
        do {
            range = try TemporalFilter.parse(since: args.since, until: args.until)
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return .failure(detail, callID: input.callID)
        }

        let chatID = args.chatID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let recipient = args.recipient?.trimmingCharacters(in: .whitespacesAndNewlines)
        if chatID?.isEmpty ?? true, recipient?.isEmpty ?? true {
            let errorMsg = "Invalid messages.read arguments: either 'chatId' or 'recipient' must be specified."
            return .failure(errorMsg, callID: input.callID)
        }

        do {
            let messages: [MessagesMessageItem]
            var resolvedRecipient: String?
            var note: String?
            if let recipient, MessagesRecipientRouting.isName(recipient) {
                let routing = await MessagesRecipientRouting.handles(for: recipient, resolver: resolver)
                if routing.handles.isEmpty {
                    // No handle to read: fail closed with guidance rather than
                    // sending the name to a gateway that cannot match it.
                    messages = []
                    note = MessagesRecipientRouting.noMatchesNote(for: recipient)
                } else {
                    var batches: [[MessagesMessageItem]] = []
                    for handle in routing.handles {
                        let batch = try await gateway.read(
                            chatID: chatID,
                            recipient: handle,
                            limit: args.limit,
                            since: range.since,
                            until: range.until
                        )
                        batches.append(batch)
                    }
                    // Read's contract is chronological ascending, so the shared
                    // newest-first merge is reversed only after the cap; capping
                    // first keeps the newest `limit` rows, not the first handle's.
                    messages = Array(MessagesRecipientRouting.merged(batches, limit: args.limit).reversed())
                    resolvedRecipient = routing.resolvedRecipient
                }
            } else {
                messages = try await gateway.read(chatID: chatID, recipient: recipient, limit: args.limit, since: range.since, until: range.until)
            }
            let envelope = MessagesReadEnvelope(
                chatID: chatID,
                recipient: recipient,
                resolvedRecipient: resolvedRecipient,
                note: note,
                messages: messages
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            let json = try String(bytes: encoder.encode(envelope), encoding: .utf8) ?? "{}"
            return .success(json, callID: input.callID)
        } catch let error as CancellationError {
            throw error
        } catch {
            return .failure("messages.read failed: \(error.localizedDescription)", callID: input.callID)
        }
    }
}

/// Sends a message via macOS Messages.app to a recipient phone number or email.
public struct MessagesSendTool: Tool, Sendable {
    public let name = "messages.send"
    public let description =
        "Sends a text message or iMessage to a recipient phone number or email using macOS Messages. "
            + "Requires operator approval. Use when the user explicitly instructs to send or reply to a message."

    public let inputSchema = JSONSchema(
        rawValue: #"{"type":"object","properties":{"recipient":{"type":"string","description":"Recipient phone number or email handle. "#
            + #"Call messages.resolveRecipient first when you only have a name; never pass a display name."},"#
            + #""to":{"type":"string","description":"Alias for recipient"},"#
            + #""text":{"type":"string","description":"Message text to send"},"#
            + #""message":{"type":"string","description":"Alias for text"},"#
            + #""resolvedFrom":{"type":"string","description":"Optional original display name when recipient "#
            + #"was resolved from a name; remembered for future lookups."}},"#
            + #""required":["recipient","text"],"additionalProperties":false}"#
    )

    public let permissionLevel = PermissionLevel.requiresApproval

    /// Name-shaped refusals embed resolver candidates drawn from Contacts and
    /// chat history (`displayName`, `handle`, `service`, `lastMessageAt`), so the
    /// result channel carries attacker-influenceable fields even though the send
    /// itself is engine-authored; declaring the tool untrusted routes every
    /// result through the labeled data-only block at the model-context boundary.
    public var contentTrustLevel: ContentTrustLevel {
        .untrustedExternal
    }

    private let gateway: any MessagesGateway
    private let resolver: (any MessagesRecipientResolving)?
    private let recipientAliasStore: (any MessageAliasStoring)?

    public init(
        gateway: any MessagesGateway,
        resolver: (any MessagesRecipientResolving)? = nil,
        recipientAliasStore: (any MessageAliasStoring)? = nil
    ) {
        self.gateway = gateway
        self.resolver = resolver
        self.recipientAliasStore = recipientAliasStore
    }

    public func execute(input: ToolInput, context: ToolContext) async throws -> ToolOutput {
        let args: MessagesSendArgs
        do {
            args = try JSONDecoder().decode(MessagesSendArgs.self, from: Data(input.argumentsJSON.utf8))
        } catch {
            return .failure("Invalid messages.send arguments: expected {\"recipient\": \"...\", \"text\": \"...\"}.", callID: input.callID)
        }

        let recipient = args.recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = args.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !recipient.isEmpty else {
            return .failure("Invalid messages.send arguments: 'recipient' must not be empty.", callID: input.callID)
        }
        guard !text.isEmpty else {
            return .failure("Invalid messages.send arguments: 'text' must not be empty.", callID: input.callID)
        }
        // Reject embedded null bytes before any AppleScript escaping: a null
        // truncates the `osascript` string literal.
        guard !recipient.contains("\0") else {
            return .failure("Invalid messages.send arguments: 'recipient' must not contain null bytes.", callID: input.callID)
        }
        guard !text.contains("\0") else {
            return .failure("Invalid messages.send arguments: 'text' must not contain null bytes.", callID: input.callID)
        }

        let resolvedName = args.resolvedFrom
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }

        // Only exact-address handles reach the gateway: a display name would
        // guess at a contact, and a near-miss phone spelling could dial the
        // wrong number. A name is refused with the resolver's best candidate
        // (or the owner question when several match) before the dry-run branch,
        // so an approval preview is never filed for a name.
        guard let canonicalRecipient = MessageRecipientClassification.canonicalHandle(recipient) else {
            return await .failure(nameRefusal(for: recipient), callID: input.callID)
        }

        if context.dryRun {
            let envelope = MessagesSendEnvelope(
                success: true,
                recipient: canonicalRecipient,
                text: text,
                note: "Dry run: would send message to '\(canonicalRecipient)'."
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            let json = try String(bytes: encoder.encode(envelope), encoding: .utf8) ?? "{}"
            return .success(json, callID: input.callID)
        }

        do {
            let result = try await gateway.send(recipient: canonicalRecipient, text: text)
            let envelope = MessagesSendEnvelope(
                success: result.success,
                recipient: result.recipient,
                text: result.text,
                note: note(for: result),
                service: result.service,
                confirmed: result.confirmed
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            let json = try String(bytes: encoder.encode(envelope), encoding: .utf8) ?? "{}"
            // Alias learning is strictly additive and runs only after the
            // response is composed: a store hiccup can never change what the
            // send reports, and an exact-handle send teaches nothing.
            if result.success, let resolvedName, let recipientAliasStore {
                await recipientAliasStore.recordAlias(name: resolvedName, handle: canonicalRecipient, service: nil, displayName: nil)
            }
            return .success(json, callID: input.callID)
        } catch let error as CancellationError {
            throw error
        } catch {
            return .failure("messages.send failed: \(error.localizedDescription)", callID: input.callID)
        }
    }

    /// Composes the owner-facing note from a send result.
    ///
    /// A missing or positive confirmation leaves the gateway's own note
    /// untouched; an explicitly unconfirmed send must not read as an
    /// unqualified success, so the caveat is appended rather than replacing
    /// whatever the gateway already reported.
    private func note(for result: MessagesSendResult) -> String? {
        guard result.confirmed == false else {
            return result.details
        }
        let caveat = "Sent; delivery not yet visible in Messages history."
        guard let details = result.details, !details.isEmpty else {
            return caveat
        }
        return "\(details) \(caveat)"
    }

    /// Candidate budget for a name refusal: enough to show alternatives,
    /// small enough that the refusal stays one actionable paragraph.
    private static let candidateLimit = 5

    /// Refuses a name-shaped recipient with an exact handle to retry.
    ///
    /// The resolver is the only surface that knows who a name is, so its
    /// selected candidate becomes the retry instruction and its alternatives
    /// become the owner question. With no resolver wired nothing can be
    /// offered, which is the same honest refusal as a zero-match lookup.
    private func nameRefusal(for raw: String) async -> String {
        let resolution: MessageRecipientResolution = if let resolver {
            await resolver.resolve(name: raw, limit: Self.candidateLimit)
        } else {
            MessageRecipientResolution(query: raw, candidates: [])
        }
        if let selected = resolution.selected {
            return Self.bestMatchMessage(for: raw, selected: selected)
        }
        if resolution.isAmbiguous {
            return Self.ambiguousMessage(for: raw, candidates: resolution.candidates)
        }
        return Self.noMatchMessage(for: raw)
    }

    /// One-line refusal naming the best candidate and the exact retry call.
    private static func bestMatchMessage(for raw: String, selected: MessageRecipientCandidate) -> String {
        var message = "Recipient \"" + raw + "\" is a display name, not a phone number or email. Best match: "
        message += (selected.displayName ?? raw) + " <" + selected.handle + ">"
        if let service = selected.service {
            message += " (" + service + ")"
        }
        if let lastMessageAt = selected.lastMessageAt {
            message += ", last messaged " + relativeDayDescription(for: lastMessageAt)
        }
        message += ". Retry messages.send with recipient \"" + selected.handle + "\" and resolvedFrom \"" + raw + "\"."
        return message
    }

    /// Owner question listing the top alternatives instead of guessing one.
    private static func ambiguousMessage(for raw: String, candidates: [MessageRecipientCandidate]) -> String {
        var message = "Multiple contacts match \"" + raw + "\": "
        for (offset, candidate) in candidates.prefix(3).enumerated() {
            if offset > 0 {
                message += " "
            }
            message += "\(offset + 1). " + candidateSummary(candidate)
        }
        message += " Ask the user which one, then retry with the exact handle."
        return message
    }

    /// Numbered-candidate label: name, handle, then whatever detail exists.
    private static func candidateSummary(_ candidate: MessageRecipientCandidate) -> String {
        var summary = (candidate.displayName ?? candidate.handle) + " <" + candidate.handle + ">"
        var details: [String] = []
        if let service = candidate.service {
            details.append(service)
        }
        if let lastMessageAt = candidate.lastMessageAt {
            details.append("last messaged " + relativeDayDescription(for: lastMessageAt))
        }
        if !details.isEmpty {
            summary += " (" + details.joined(separator: ", ") + ")"
        }
        return summary
    }

    /// Guidance when no lookup surface produced a candidate.
    ///
    /// "Enable for Contacts" names the Contacts row's Enable button in the
    /// Permissions window (the literal button label is the generic Enable).
    private static func noMatchMessage(for raw: String) -> String {
        "No contact or recent conversation matches \"" + raw + "\". Ask the user for the exact phone number or email, "
            + "or open Rune Weaver menu -> Permissions… -> Enable for Contacts."
    }

    /// Whole-calendar-day age of an exchange, so "today" survives a clock that
    /// is minutes past midnight and a future timestamp degrades to today
    /// instead of a negative count.
    private static func relativeDayDescription(for date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: now)
        ).day ?? 0
        switch days {
        case ..<1: return "today"
        case 1: return "yesterday"
        default: return "\(days) days ago"
        }
    }
}

// MARK: - Pre-admission validation

/// Minimal recipient projection for `messages.send` pre-admission validation.
///
/// Admission must judge the recipient independently of its companion fields:
/// `MessagesSendArgs` requires a non-empty `text`, so a full decode lets a
/// name-shaped call with a missing, blank, or wrong-typed `text` reach the
/// permission gate and park for approval. Reading only the recipient keys keeps
/// `execute` as the owner of malformed-argument errors for nameless shapes,
/// while a wrong-typed recipient still fails this decode exactly as it fails the
/// full one.
private struct SendAdmissionRecipient: Decodable {
    /// Raw `recipient` when present, otherwise the `to` alias.
    let rawRecipient: String?

    private enum CodingKeys: String, CodingKey {
        case recipient
        case to
    }

    /// Mirrors `MessagesSendArgs` recipient resolution: `recipient` wins when it
    /// is a string, and `to` is read only when `recipient` is absent or JSON
    /// null, so a wrong-typed companion key cannot change which value admission
    /// judges.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let recipient = try container.decodeIfPresent(String.self, forKey: .recipient) {
            rawRecipient = recipient
        } else {
            rawRecipient = try container.decodeIfPresent(String.self, forKey: .to)
        }
    }
}

extension MessagesSendTool: ToolAdmissionValidating {
    /// Refuses a display-name recipient before the call can park for approval.
    ///
    /// The turn loop consults this before the permission gate and before any
    /// approval row is filed, so a name-shaped send is answered to the model
    /// with the resolver's candidates immediately and no durable grant is ever
    /// keyed on a name. The recipient is read straight from the argument JSON
    /// rather than through `MessagesSendArgs`, so a name is still refused when
    /// `text` is missing, blank, or wrong-typed. Malformed recipient keys, blank
    /// values, null bytes, and nameless shapes proceed so `execute` reports its
    /// existing argument errors unchanged, and canonical handles proceed to
    /// normal admission.
    /// - Parameter input: Raw `messages.send` invocation.
    /// - Returns: `.refuse` with the shared name-refusal text, or `.proceed`.
    public func admissionVerdict(for input: ToolInput) async -> ToolAdmissionVerdict {
        guard let projection = try? JSONDecoder().decode(SendAdmissionRecipient.self, from: Data(input.argumentsJSON.utf8)),
              let rawRecipient = projection.rawRecipient,
              !rawRecipient.contains("\0")
        else {
            return .proceed
        }
        let recipient = rawRecipient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !recipient.isEmpty,
              MessageRecipientClassification.canonicalHandle(recipient) == nil
        else {
            return .proceed
        }
        return await .refuse(reason: nameRefusal(for: recipient))
    }
}

/// Resolves a name, nickname, or partial name to candidate recipient handles.
public struct MessagesResolveRecipientTool: Tool, Sendable {
    public let name = "messages.resolveRecipient"
    public let description =
        "Resolves a contact name, nickname, or partial name to candidate phone numbers or email addresses using Contacts and recent conversations. "
            + "Read-only. Use before messages.send when you only have a name, and to disambiguate multiple matches."

    public let inputSchema = JSONSchema(
        rawValue: #"{"type":"object","properties":{"name":{"type":"string","description":"Contact name, nickname, "#
            + #"partial name, phone number, or email address to resolve"},"#
            + #""query":{"type":"string","description":"Alias for name"},"#
            + #""limit":{"type":"integer","description":"Maximum candidates to return (1-10, default 5)","minimum":1,"maximum":10}},"#
            + #""required":["name"],"additionalProperties":false}"#
    )

    public let permissionLevel = PermissionLevel.readOnly
    public var contentTrustLevel: ContentTrustLevel {
        .untrustedExternal
    }

    private let resolver: any MessagesRecipientResolving

    public init(resolver: any MessagesRecipientResolving) {
        self.resolver = resolver
    }

    public func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        let args: MessagesResolveRecipientArgs
        do {
            args = try JSONDecoder().decode(MessagesResolveRecipientArgs.self, from: Data(input.argumentsJSON.utf8))
        } catch {
            let errorMsg = "Invalid messages.resolveRecipient arguments: expected " + Self.expectedShape
                + " with an optional \"limit\"; \"query\" is accepted as an alias for \"name\"."
            return .failure(errorMsg, callID: input.callID)
        }

        let query = args.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !query.isEmpty else {
            let errorMsg = "Invalid messages.resolveRecipient arguments: \"name\" must not be blank. "
                + Self.expectedShapeHint
            return .failure(errorMsg, callID: input.callID)
        }
        guard query.count <= MessagesResolveRecipientArgs.maxNameLength else {
            let errorMsg = "Invalid messages.resolveRecipient arguments: \"name\" must be "
                + "\(MessagesResolveRecipientArgs.maxNameLength) characters or fewer. " + Self.expectedShapeHint
            return .failure(errorMsg, callID: input.callID)
        }

        // Resolution never fails and an empty candidate list is a value, so the
        // envelope always reports success; only argument shape can fail a call.
        let resolution = await resolver.resolve(name: query, limit: args.limit)
        let envelope = MessagesResolveRecipientEnvelope(
            query: resolution.query,
            ambiguous: resolution.isAmbiguous,
            resolved: resolution.selected,
            candidates: resolution.candidates,
            note: resolution.candidates.isEmpty ? Self.noMatchNote(for: query) : nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let json = try String(bytes: encoder.encode(envelope), encoding: .utf8) ?? "{}"
        return .success(json, callID: input.callID)
    }

    /// Expected argument shape and repair hint repeated in every rejection so the
    /// model can fix a malformed call without a second round trip.
    private static let expectedShape = #"{"name": "Rebecca"}"#
    private static let expectedShapeHint =
        "Expected \(expectedShape) with a contact name, nickname, phone number, or email address."

    /// Guidance for a zero-candidate result: the model must ask for an exact
    /// handle rather than guess at a name that matched nobody.
    ///
    /// "Enable for Contacts" names the Contacts row's Enable button in the
    /// Permissions window (the literal button label is the generic Enable).
    private static func noMatchNote(for query: String) -> String {
        "No match for \"\(query)\". Ask the user for the exact phone number or email, "
            + "or open Rune Weaver menu -> Permissions… -> Enable for Contacts."
    }
}

// MARK: - Factory

#if !canImport(SQLite3)
    /// Fail-empty resolver for platforms where SQLite3 is unavailable.
    ///
    /// The production resolver's history surface needs SQLite3, so resolution
    /// degrades to an empty result there. The tool stays registered and reports
    /// the same zero-match guidance, which keeps the advertised and registered
    /// tool set identical on every platform instead of shape-shifting.
    private struct UnavailableMessagesRecipientResolver: MessagesRecipientResolving {
        func resolve(name: String, limit _: Int) async -> MessageRecipientResolution {
            MessageRecipientResolution(query: name, candidates: [])
        }
    }
#endif

public enum MessagesTools {
    public static let toolNames = ["messages.search", "messages.read", "messages.send", "messages.resolveRecipient"]

    public static func makeTools(
        chatDatabasePath: String = MessagesIndexer.defaultChatDatabasePath,
        gateway: (any MessagesGateway)? = nil,
        resolver: (any MessagesRecipientResolving)? = nil,
        recipientAliasStore: (any MessageAliasStoring)? = nil
    ) -> [any Tool] {
        let effectiveGateway = gateway ?? ProductionMessagesGateway(chatDatabasePath: chatDatabasePath)
        // The default resolver reads contacts and chat history live per call, so
        // constructing it here performs no I/O; tests and callers that need a
        // hermetic lookup inject their own conformance instead. The alias store
        // is wired here as well as into the send tool so a learned mapping is
        // consulted by every resolution surface instead of only written.
        let effectiveResolver: any MessagesRecipientResolving
        if let resolver {
            effectiveResolver = resolver
        } else {
            #if canImport(SQLite3)
                effectiveResolver = MessagesRecipientResolver(
                    chatDatabasePath: chatDatabasePath,
                    aliasStore: recipientAliasStore
                )
            #else
                effectiveResolver = UnavailableMessagesRecipientResolver()
            #endif
        }
        return [
            MessagesSearchTool(gateway: effectiveGateway, resolver: effectiveResolver),
            MessagesReadTool(gateway: effectiveGateway, resolver: effectiveResolver),
            MessagesSendTool(
                gateway: effectiveGateway,
                resolver: effectiveResolver,
                recipientAliasStore: recipientAliasStore
            ),
            MessagesResolveRecipientTool(resolver: effectiveResolver)
        ]
    }

    public static func register(
        on bus: ToolBus,
        chatDatabasePath: String = MessagesIndexer.defaultChatDatabasePath,
        gateway: (any MessagesGateway)? = nil
    ) async {
        for tool in makeTools(chatDatabasePath: chatDatabasePath, gateway: gateway) {
            await bus.register(tool: tool)
        }
    }
}

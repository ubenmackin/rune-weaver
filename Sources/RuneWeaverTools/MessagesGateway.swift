// Rune Weaver Tools — Messages gateway models and production implementation.

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
    /// Searches messages across all conversations. Bounds are already-resolved instants: `since` is
    /// inclusive and `until` is exclusive, with nil meaning unbounded on that side.
    func search(query: String?, recipient: String?, limit: Int, since: Date?, until: Date?) async throws -> [MessagesMessageItem]
    /// Reads conversation history for a given chat or recipient. Bounds follow the same
    /// inclusive-since, exclusive-until contract as search, with nil meaning unbounded on that side.
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
                limit: limit,
                since: since,
                until: until
            )

            let names = MessagesContactNameResolver().displayNames()
            let trimmedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let isoFormatter = ISO8601DateFormatter()
            var items: [MessagesMessageItem] = []

            for row in rows {
                let resolved = MessagesIndexer.resolveText(for: row).text ?? ""
                if !trimmedQuery.isEmpty && trimmedQuery != "*", !resolved.localizedCaseInsensitiveContains(trimmedQuery) {
                    continue
                }
                let sender = row.isFromMe ? "Me" : MessagesIndexer.displayName(for: row, names: names)
                let dateStr = row.date.map { isoFormatter.string(from: TemporalFilter.date(fromMacEpoch: $0)) } ?? ""
                let atts: [MessagesAttachmentRow]
                do {
                    atts = try MessagesDatabaseIO.attachments(handle: handle, messageID: row.rowID)
                } catch {
                    RuneWeaverLog.tools.debug("MessagesGateway: failed to fetch attachments for message \(row.rowID): \(error.localizedDescription)")
                    atts = []
                }
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
                let atts: [MessagesAttachmentRow]
                do {
                    atts = try MessagesDatabaseIO.attachments(handle: handle, messageID: row.rowID)
                } catch {
                    RuneWeaverLog.tools.debug("MessagesGateway: failed to fetch attachments for message \(row.rowID): \(error.localizedDescription)")
                    atts = []
                }
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
        // Only exact-address handles are sendable here: a name would guess at a contact, and a
        // near-miss phone spelling could dial the wrong number.
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
    private func observedService(for recipient: String) async -> String? {
        #if canImport(SQLite3)
            guard let recipientKey = MessageRecipientNameNormalizer.handleKey(recipient) else {
                return nil
            }
            let history = MessagesChatHistorySource(chatDatabasePath: chatDatabasePath)
            let stats: [MessageHandleStats]
            do {
                stats = try await history.recentDirectHandleStats(limit: 200)
            } catch is CancellationError {
                return nil
            } catch {
                RuneWeaverLog.tools.debug("MessagesGateway: recentDirectHandleStats failed: \(error.localizedDescription)")
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

// Rune Weaver Tools — Apple Messages search, read, and send tools.

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

    public init(success: Bool, recipient: String, text: String, details: String? = nil) {
        self.success = success
        self.recipient = recipient
        self.text = text
        self.details = details
    }
}

// MARK: - Gateway Protocol

/// Interface for executing Messages operations.
public protocol MessagesGateway: Sendable {
    /// Searches messages across all conversations.
    func search(query: String?, recipient: String?, limit: Int) async throws -> [MessagesMessageItem]
    /// Reads conversation history for a given chat or recipient.
    func read(chatID: String?, recipient: String?, limit: Int) async throws -> [MessagesMessageItem]
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

    public func search(query: String?, recipient: String?, limit: Int) async throws -> [MessagesMessageItem] {
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
                limit: max(limit * 2, 20)
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
                let dateStr = row.date.map { isoFormatter.string(from: MessagesIndexer.date(fromMacEpoch: $0)) } ?? ""
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

    public func read(chatID: String?, recipient: String?, limit: Int) async throws -> [MessagesMessageItem] {
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
                limit: limit
            )

            let names = MessagesContactNameResolver().displayNames()
            let isoFormatter = ISO8601DateFormatter()
            var items: [MessagesMessageItem] = []

            for row in rows.reversed() {
                let resolved = MessagesIndexer.resolveText(for: row).text ?? ""
                let sender = row.isFromMe ? "Me" : MessagesIndexer.displayName(for: row, names: names)
                let dateStr = row.date.map { isoFormatter.string(from: MessagesIndexer.date(fromMacEpoch: $0)) } ?? ""
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

        let escapedRecipient = Self.escapeAppleScriptString(trimmedRecipient)
        let escapedText = Self.escapeAppleScriptString(trimmedText)
        let script = """
        tell application "Messages"
            set targetService to 1st account whose service type = iMessage
            try
                set targetBuddy to participant "\(escapedRecipient)" of targetService
                send "\(escapedText)" to targetBuddy
            on error
                send "\(escapedText)" to participant "\(escapedRecipient)"
            end try
        end tell
        """

        let result = try BoundedProcessRunner.runSync(
            executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: ["-e", script],
            timeoutSeconds: 15
        )
        guard result.exitCode == 0 else {
            let err = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MessagesToolError.scriptFailed(err.isEmpty ? "Exit code \(result.exitCode)" : err)
        }
        return MessagesSendResult(success: true, recipient: trimmedRecipient, text: trimmedText)
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

    public static let defaultLimit = 10
    public static let maxLimit = 50

    public init(query: String? = nil, recipient: String? = nil, limit: Int = defaultLimit) {
        self.query = query
        self.recipient = recipient
        self.limit = min(max(limit, 1), Self.maxLimit)
    }

    private enum CodingKeys: String, CodingKey {
        case query
        case recipient
        case limit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let query = try container.decodeIfPresent(String.self, forKey: .query)
        let recipient = try container.decodeIfPresent(String.self, forKey: .recipient)
        let rawLimit = try container.decodeIfPresent(Int.self, forKey: .limit) ?? Self.defaultLimit
        self.init(query: query, recipient: recipient, limit: rawLimit)
    }
}

public struct MessagesSearchEnvelope: Sendable, Equatable, Codable {
    public let query: String?
    public let recipient: String?
    public let count: Int
    public let messages: [MessagesMessageItem]

    public init(query: String?, recipient: String?, messages: [MessagesMessageItem]) {
        self.query = query
        self.recipient = recipient
        self.count = messages.count
        self.messages = messages
    }
}

public struct MessagesReadArgs: Sendable, Equatable, Decodable {
    public let chatID: String?
    public let recipient: String?
    public let limit: Int

    public static let defaultLimit = 20
    public static let maxLimit = 100

    public init(chatID: String? = nil, recipient: String? = nil, limit: Int = defaultLimit) {
        self.chatID = chatID
        self.recipient = recipient
        self.limit = min(max(limit, 1), Self.maxLimit)
    }

    private enum CodingKeys: String, CodingKey {
        case chatID = "chatId"
        case chatIDUnderscore = "chat_id"
        case recipient
        case limit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let chatID = try container.decodeIfPresent(String.self, forKey: .chatID)
            ?? container.decodeIfPresent(String.self, forKey: .chatIDUnderscore)
        let recipient = try container.decodeIfPresent(String.self, forKey: .recipient)
        let rawLimit = try container.decodeIfPresent(Int.self, forKey: .limit) ?? Self.defaultLimit
        self.init(chatID: chatID, recipient: recipient, limit: rawLimit)
    }
}

public struct MessagesReadEnvelope: Sendable, Equatable, Codable {
    public let chatID: String?
    public let recipient: String?
    public let count: Int
    public let messages: [MessagesMessageItem]

    public init(chatID: String?, recipient: String?, messages: [MessagesMessageItem]) {
        self.chatID = chatID
        self.recipient = recipient
        self.count = messages.count
        self.messages = messages
    }
}

public struct MessagesSendArgs: Sendable, Equatable, Decodable {
    public let recipient: String
    public let text: String

    public init(recipient: String, text: String) {
        self.recipient = recipient
        self.text = text
    }

    private enum CodingKeys: String, CodingKey {
        case recipient
        case to
        case text
        case message
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
        self.init(recipient: recipientVal, text: textVal)
    }
}

public struct MessagesSendEnvelope: Sendable, Equatable, Codable {
    public let success: Bool
    public let recipient: String
    public let text: String
    public let note: String?

    public init(success: Bool, recipient: String, text: String, note: String? = nil) {
        self.success = success
        self.recipient = recipient
        self.text = text
        self.note = note
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
            + #""recipient":{"type":"string","description":"Optional phone number, email address, or contact name to filter by"},"#
            + #""limit":{"type":"integer","description":"Maximum messages to return (1-50, default 10)","minimum":1,"maximum":50}},"#
            + #"additionalProperties":false}"#
    )

    public let permissionLevel = PermissionLevel.readOnly
    public var contentTrustLevel: ContentTrustLevel {
        .untrustedExternal
    }

    private let gateway: any MessagesGateway

    public init(gateway: any MessagesGateway) {
        self.gateway = gateway
    }

    public func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        let args: MessagesSearchArgs
        do {
            args = try JSONDecoder().decode(MessagesSearchArgs.self, from: Data(input.argumentsJSON.utf8))
        } catch {
            let errorMsg = "Invalid messages.search arguments: expected {\"query\": \"...\", \"recipient\": \"...\", \"limit\": <1-50>}."
            return .failure(errorMsg, callID: input.callID)
        }

        do {
            let messages = try await gateway.search(query: args.query, recipient: args.recipient, limit: args.limit)
            let envelope = MessagesSearchEnvelope(query: args.query, recipient: args.recipient, messages: messages)
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
            + #""recipient":{"type":"string","description":"Recipient phone number, email, or handle"},"#
            + #""limit":{"type":"integer","description":"Maximum messages to return (1-100, default 20)","minimum":1,"maximum":100}},"#
            + #"additionalProperties":false}"#
    )

    public let permissionLevel = PermissionLevel.readOnly
    public var contentTrustLevel: ContentTrustLevel {
        .untrustedExternal
    }

    private let gateway: any MessagesGateway

    public init(gateway: any MessagesGateway) {
        self.gateway = gateway
    }

    public func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        let args: MessagesReadArgs
        do {
            args = try JSONDecoder().decode(MessagesReadArgs.self, from: Data(input.argumentsJSON.utf8))
        } catch {
            let errorMsg = "Invalid messages.read arguments: expected {\"chatId\": \"...\", \"recipient\": \"...\", \"limit\": <1-100>}."
            return .failure(errorMsg, callID: input.callID)
        }

        let chatID = args.chatID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let recipient = args.recipient?.trimmingCharacters(in: .whitespacesAndNewlines)
        if chatID == nil || chatID!.isEmpty, recipient == nil || recipient!.isEmpty {
            let errorMsg = "Invalid messages.read arguments: either 'chatId' or 'recipient' must be specified."
            return .failure(errorMsg, callID: input.callID)
        }

        do {
            let messages = try await gateway.read(chatID: chatID, recipient: recipient, limit: args.limit)
            let envelope = MessagesReadEnvelope(chatID: chatID, recipient: recipient, messages: messages)
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
        rawValue: #"{"type":"object","properties":{"recipient":{"type":"string","description":"Recipient phone number or email address"},"#
            + #""to":{"type":"string","description":"Alias for recipient"},"#
            + #""text":{"type":"string","description":"Message text to send"},"#
            + #""message":{"type":"string","description":"Alias for text"}},"#
            + #"required":["recipient","text"],"additionalProperties":false}"#
    )

    public let permissionLevel = PermissionLevel.requiresApproval

    private let gateway: any MessagesGateway

    public init(gateway: any MessagesGateway) {
        self.gateway = gateway
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

        if context.dryRun {
            let envelope = MessagesSendEnvelope(
                success: true,
                recipient: recipient,
                text: text,
                note: "Dry run: would send message to '\(recipient)'."
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            let json = try String(bytes: encoder.encode(envelope), encoding: .utf8) ?? "{}"
            return .success(json, callID: input.callID)
        }

        do {
            let result = try await gateway.send(recipient: recipient, text: text)
            let envelope = MessagesSendEnvelope(
                success: result.success,
                recipient: result.recipient,
                text: result.text,
                note: result.details
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            let json = try String(bytes: encoder.encode(envelope), encoding: .utf8) ?? "{}"
            return .success(json, callID: input.callID)
        } catch let error as CancellationError {
            throw error
        } catch {
            return .failure("messages.send failed: \(error.localizedDescription)", callID: input.callID)
        }
    }
}

// MARK: - Factory

public enum MessagesTools {
    public static let toolNames = ["messages.search", "messages.read", "messages.send"]

    public static func makeTools(
        chatDatabasePath: String = MessagesIndexer.defaultChatDatabasePath,
        gateway: (any MessagesGateway)? = nil
    ) -> [any Tool] {
        let effectiveGateway = gateway ?? ProductionMessagesGateway(chatDatabasePath: chatDatabasePath)
        return [
            MessagesSearchTool(gateway: effectiveGateway),
            MessagesReadTool(gateway: effectiveGateway),
            MessagesSendTool(gateway: effectiveGateway)
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

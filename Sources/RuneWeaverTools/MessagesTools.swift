// Rune Weaver Tools — Apple Messages search, read, send, and recipient-resolution tools.

import Foundation
import RuneWeaverCore

#if canImport(SQLite3)
    import SQLite3
#endif

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

    /// Decodes read args; `chat_id` is a compatibility-only alias kept out of the strict schema,
    /// which advertises `chatId` only, so the wire stays fail-closed while older callers still decode.
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
    /// Optional fire time requesting a deterministic scheduled send; nil sends immediately.
    public let scheduleAt: Date?

    public init(recipient: String, text: String, resolvedFrom: String? = nil, scheduleAt: Date? = nil) {
        self.recipient = recipient
        self.text = text
        self.resolvedFrom = resolvedFrom
        self.scheduleAt = scheduleAt
    }

    private enum CodingKeys: String, CodingKey {
        case recipient
        case to
        case text
        case message
        case resolvedFrom
        case scheduleAt
    }

    /// Decodes send args; `to` and `message` are compatibility-only aliases kept out of the strict schema,
    /// which advertises `recipient` and `text` only, so the wire stays fail-closed while older callers still decode.
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
        let scheduleAt = try ScheduledSendTimeValidation.decodeScheduleAt(from: container, forKey: .scheduleAt)
        self.init(
            recipient: recipientVal,
            text: textVal,
            resolvedFrom: (resolvedFrom?.isEmpty ?? true) ? nil : resolvedFrom,
            scheduleAt: scheduleAt
        )
    }

    /// Validates the optional fire time and returns the minute-aligned instant to store.
    ///
    /// Bounds and alignment are shared with `email.send` and the scheduler
    /// store through ``ScheduledSendTimeValidation``, so a requested schedule
    /// can never disagree with the validation its deterministic replay runs.
    /// - Parameter now: Reference instant the bounds are measured from.
    /// - Returns: The validated fire time, or nil when the send is immediate.
    public func validateScheduleAt(now: Date = Date()) throws -> Date? {
        guard let scheduleAt else { return nil }
        return try ScheduledSendTimeValidation.validateScheduleAt(scheduleAt, now: now)
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

    /// Decodes resolve args; `query` is a compatibility-only alias kept out of the strict schema,
    /// which advertises `name` only, so the wire stays fail-closed while older callers still decode.
    /// `name` wins when both arrive so one call can never carry two different recipients.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decodeIfPresent(String.self, forKey: .name)
            ?? container.decodeIfPresent(String.self, forKey: .query)
        let rawLimit = try container.decodeIfPresent(Int.self, forKey: .limit) ?? Self.defaultLimit
        self.init(name: name, limit: rawLimit)
    }
}

/// Copy-pasteable handoff for `messages.send`, derived from a unique resolution.
///
/// `recipient` carries the selected candidate's handle verbatim so the send
/// call dials exactly the resolved identity, while `resolvedFrom` preserves
/// the trimmed name the handle was resolved from for audit and alias learning.
public struct MessagesResolveSendHint: Sendable, Equatable, Codable {
    public let recipient: String
    public let resolvedFrom: String

    public init(recipient: String, resolvedFrom: String) {
        self.recipient = recipient
        self.resolvedFrom = resolvedFrom
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
    /// Copy-pasteable send handoff; non-nil if and only if `resolved` is non-nil.
    /// Absent in older payloads, which still decode with this as nil.
    public let sendWith: MessagesResolveSendHint?

    public init(
        query: String,
        ambiguous: Bool,
        resolved: MessageRecipientCandidate? = nil,
        candidates: [MessageRecipientCandidate],
        note: String? = nil,
        sendWith: MessagesResolveSendHint? = nil
    ) {
        self.query = query
        self.ambiguous = ambiguous
        self.resolved = resolved
        self.candidates = candidates
        self.note = note
        self.sendWith = sendWith
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
            + #""required":[],"additionalProperties":false}"#
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
            + #""recipient":{"type":"string","description":"Optional phone number, email, contact name, or nickname to filter by; "#
            + #"names are resolved through Contacts and recent conversations."},"#
            + #""limit":{"type":"integer","description":"Maximum messages to return (1-100, default 20)","minimum":1,"maximum":100},"#
            + #""since":{"type":"string","description":"Optional lower bound YYYY-MM-DD (00:00:00 local inclusive) or full ISO8601 datetime"},"#
            + #""until":{"type":"string","description":"Optional upper bound YYYY-MM-DD (00:00:00 local exclusive) or full ISO8601 datetime"}},"#
            + #""required":[],"additionalProperties":false}"#
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
            + "Requires operator approval. Use when the user explicitly instructs to send or reply to a message. "
            + "Pass scheduleAt to book a scheduled send for that fire time: "
            + "approval stores the exact bytes and fires them once at the approved time."

    public let inputSchema = JSONSchema(
        rawValue: #"{"type":"object","properties":{"recipient":{"type":"string","description":"Recipient phone number or email handle. It MUST be a handle "#
            + #"from messages.resolveRecipient (copy its sendWith.recipient verbatim, with sendWith.resolvedFrom as "#
            + #"resolvedFrom); passing a display name always fails."},"#
            + #""text":{"type":"string","description":"Message text to send"},"#
            + #""resolvedFrom":{"type":"string","description":"Optional original display name when recipient "#
            + #"was resolved from a name; remembered for future lookups."},"#
            + #""scheduleAt":{"type":["number","string"],"description":"Optional fire time for a scheduled send as epoch seconds "#
            + #"or an ISO-8601 datetime (5 minutes to 365 days out, minute-aligned). Approval books the send for that "#
            + #"fire time; omit to send immediately on approval."}},"#
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
    /// Booking seam storing approved scheduled sends; nil fails closed with guidance.
    private let booking: (any ScheduledSendBooking)?

    public init(
        gateway: any MessagesGateway,
        resolver: (any MessagesRecipientResolving)? = nil,
        recipientAliasStore: (any MessageAliasStoring)? = nil,
        booking: (any ScheduledSendBooking)? = nil
    ) {
        self.gateway = gateway
        self.resolver = resolver
        self.recipientAliasStore = recipientAliasStore
        self.booking = booking
    }

    public func execute(input: ToolInput, context: ToolContext) async throws -> ToolOutput {
        let args: MessagesSendArgs
        do {
            args = try JSONDecoder().decode(MessagesSendArgs.self, from: Data(input.argumentsJSON.utf8))
        } catch {
            return .failure("Invalid messages.send arguments: expected {\"recipient\": \"...\", \"text\": \"...\"}.", callID: input.callID)
        }

        // A fire time makes this a scheduled send: validate the bounds first
        // so a past or out-of-horizon date is answered with its own reason,
        // then book the exact approved bytes through the seam once the
        // recipient and text below prove valid.
        let scheduledFireAt: Date?
        do {
            scheduledFireAt = try args.validateScheduleAt()
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
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

        if let scheduledFireAt {
            return await bookedSendOutput(recipient: canonicalRecipient, text: text, fireAt: scheduledFireAt, callID: input.callID, context: context)
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

    /// Books a validated scheduled send, or previews the booking under dry-run.
    ///
    /// Booking stores the exact approved bytes without dialing the gateway, so
    /// dry-run and unwired contexts write nothing. Booking errors stay
    /// caller-visible as failures, never silent.
    private func bookedSendOutput(recipient: String, text: String, fireAt: Date, callID: String, context: ToolContext) async -> ToolOutput {
        guard let booking else {
            return .failure(Self.bookingUnavailableNote, callID: callID)
        }
        if context.dryRun {
            return encodedEnvelope(MessagesSendEnvelope(
                success: true,
                recipient: recipient,
                text: text,
                note: "Dry run: would book a scheduled send to '\(recipient)' for "
                    + "\(ScheduledSendFireTimeText.describe(fireAt)) without writing."
            ), callID: callID)
        }
        let booked: BookedScheduledSend
        do {
            booked = try await booking.book(ScheduledSendDraft(
                channel: .messages,
                recipient: recipient,
                text: text,
                fireAt: fireAt
            ))
        } catch {
            return .failure(error.localizedDescription, callID: callID)
        }
        return encodedEnvelope(MessagesSendEnvelope(
            success: true,
            recipient: recipient,
            text: text,
            note: "Booked scheduled send \(booked.id.uuidString) to '\(recipient)' for "
                + "\(ScheduledSendFireTimeText.describe(booked.fireAt)). Approval stored the exact bytes; the send fires once at that time."
        ), callID: callID)
    }

    /// Encodes a send envelope, falling back to a failure when encoding throws.
    private func encodedEnvelope(_ envelope: MessagesSendEnvelope, callID: String) -> ToolOutput {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            let json = try String(bytes: encoder.encode(envelope), encoding: .utf8) ?? "{}"
            return .success(json, callID: callID)
        } catch {
            return .failure(error.localizedDescription, callID: callID)
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

    /// Fail-closed guidance when a delayed-send request arrives where no
    /// booking is wired: the approval cannot store the send, so it refuses
    /// rather than sending immediately and silently dropping the fire time.
    private static let bookingUnavailableNote =
        "A scheduleAt fire time requests a scheduled send, and scheduled-send booking is not wired in this context. "
            + "Book the send through the Schedules surface (`POST /scheduler/sends`) so the approved bytes are "
            + "stored and fired exactly once at the requested time."

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
            + " The envelope includes sendWith, a copy-pasteable recipient for messages.send."

    public let inputSchema = JSONSchema(
        rawValue: #"{"type":"object","properties":{"name":{"type":"string","description":"Contact name, nickname, "#
            + #"partial name, phone number, or email address to resolve"},"#
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
                + " with an optional \"limit\"."
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
        // The handoff exists exactly when a single identity won: the send call
        // must copy a resolved handle verbatim rather than retype a display
        // name, so ambiguous and empty results carry no handoff to copy.
        let sendWith = resolution.selected.map {
            MessagesResolveSendHint(recipient: $0.handle, resolvedFrom: query)
        }
        let envelope = MessagesResolveRecipientEnvelope(
            query: resolution.query,
            ambiguous: resolution.isAmbiguous,
            resolved: resolution.selected,
            candidates: resolution.candidates,
            note: resolution.candidates.isEmpty ? Self.noMatchNote(for: query) : nil,
            sendWith: sendWith
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
        recipientAliasStore: (any MessageAliasStoring)? = nil,
        booking: (any ScheduledSendBooking)? = nil
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
                recipientAliasStore: recipientAliasStore,
                booking: booking
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

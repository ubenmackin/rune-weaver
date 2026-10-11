// Rune Weaver Core — Event watcher rules and domain models.
//
// Purpose: evaluate event conditions deterministically in Swift and execute zero-token
// direct actions without LLM inference, keeping hot-path matching cheap and auditable.
// Scope: email/messages/calendar condition and action Codable models, deterministic
// matching predicates, and direct-tool wire shapes; polling and firing stay with callers.
// Architectural role: single allowlist owner for direct tools plus wire-tolerant decoding
// so older rows and newer dashboard payloads share one matching semantic.

import Foundation

/// The source of incoming events for an event watcher job.
public enum EventWatcherSource: String, Sendable, Codable, Equatable, CaseIterable {
    case email
    case messages
    case calendar
}

/// Filter for direct vs group chats in message event rules.
public enum GroupChatFilter: String, Sendable, Codable, Equatable, CaseIterable {
    case all
    case directOnly
    case groupOnly
}

/// Match conditions evaluated deterministically in Swift before invoking any tool or LLM turn.
public struct EventRuleCondition: Sendable, Codable, Equatable {
    /// --- Common & Messaging Fields ---
    /// Senders to match (substring, email address, phone number, or contact name).
    public var senderContains: [String]
    /// Subject keywords (Email only).
    public var subjectContains: [String]?
    /// Body, text, or notes keywords.
    public var contentContains: [String]?
    /// Filter for direct vs group chats (Messages only).
    public var groupChatFilter: GroupChatFilter

    /// --- Calendar Fields ---
    /// Title keywords (Calendar only, e.g. "1:1", "Sync", "Client").
    public var titleContains: [String]?
    /// Calendar names to match (e.g. "Work", "Personal").
    public var calendarNameContains: [String]?
    /// Location keywords (e.g. "Zoom", "Room 401").
    public var locationContains: [String]?
    /// Whether to ignore all-day events (default true for meeting prep).
    public var excludeAllDay: Bool

    /// Match strategy: if true, all configured criteria must match; if false, any criterion matches.
    public var matchAll: Bool

    private enum CodingKeys: String, CodingKey {
        case senderContains
        case senderContainsSnake = "sender_contains"
        case subjectContains
        case subjectContainsSnake = "subject_contains"
        case contentContains
        case contentContainsSnake = "content_contains"
        case groupChatFilter
        case groupChatFilterSnake = "group_chat_filter"
        case titleContains
        case titleContainsSnake = "title_contains"
        case calendarNameContains
        case calendarNameContainsSnake = "calendar_name_contains"
        case calendarNamesAlias = "calendarNames"
        case calendarNamesSnakeAlias = "calendar_names"
        case locationContains
        case locationContainsSnake = "location_contains"
        case excludeAllDay
        case excludeAllDaySnake = "exclude_all_day"
        case matchAll
        case matchAllSnake = "match_all"
    }

    public init(
        senderContains: [String] = [],
        subjectContains: [String]? = nil,
        contentContains: [String]? = nil,
        groupChatFilter: GroupChatFilter = .all,
        titleContains: [String]? = nil,
        calendarNameContains: [String]? = nil,
        locationContains: [String]? = nil,
        excludeAllDay: Bool = true,
        matchAll: Bool = false
    ) {
        self.senderContains = senderContains
        self.subjectContains = subjectContains
        self.contentContains = contentContains
        self.groupChatFilter = groupChatFilter
        self.titleContains = titleContains
        self.calendarNameContains = calendarNameContains
        self.locationContains = locationContains
        self.excludeAllDay = excludeAllDay
        self.matchAll = matchAll
    }

    /// Wire tolerance lives here so dashboard, config file, and durable rows agree:
    /// the canonical keys stay camelCase while snake_case and the legacy
    /// `calendarNames` alias still decode, so a renamed dashboard field or an
    /// older stored row never silently drops a filter.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        senderContains = try container.decodeIfPresent([String].self, forKey: .senderContains)
            ?? container.decodeIfPresent([String].self, forKey: .senderContainsSnake) ?? []
        subjectContains = try container.decodeIfPresent([String].self, forKey: .subjectContains)
            ?? container.decodeIfPresent([String].self, forKey: .subjectContainsSnake)
        contentContains = try container.decodeIfPresent([String].self, forKey: .contentContains)
            ?? container.decodeIfPresent([String].self, forKey: .contentContainsSnake)
        groupChatFilter = try container.decodeIfPresent(GroupChatFilter.self, forKey: .groupChatFilter)
            ?? container.decodeIfPresent(GroupChatFilter.self, forKey: .groupChatFilterSnake) ?? .all
        titleContains = try container.decodeIfPresent([String].self, forKey: .titleContains)
            ?? container.decodeIfPresent([String].self, forKey: .titleContainsSnake)
        calendarNameContains = try container.decodeIfPresent([String].self, forKey: .calendarNameContains)
            ?? container.decodeIfPresent([String].self, forKey: .calendarNameContainsSnake)
            ?? container.decodeIfPresent([String].self, forKey: .calendarNamesAlias)
            ?? container.decodeIfPresent([String].self, forKey: .calendarNamesSnakeAlias)
        locationContains = try container.decodeIfPresent([String].self, forKey: .locationContains)
            ?? container.decodeIfPresent([String].self, forKey: .locationContainsSnake)
        excludeAllDay = try container.decodeIfPresent(Bool.self, forKey: .excludeAllDay)
            ?? container.decodeIfPresent(Bool.self, forKey: .excludeAllDaySnake) ?? true
        matchAll = try container.decodeIfPresent(Bool.self, forKey: .matchAll)
            ?? container.decodeIfPresent(Bool.self, forKey: .matchAllSnake) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(senderContains, forKey: .senderContains)
        try container.encodeIfPresent(subjectContains, forKey: .subjectContains)
        try container.encodeIfPresent(contentContains, forKey: .contentContains)
        try container.encode(groupChatFilter, forKey: .groupChatFilter)
        try container.encodeIfPresent(titleContains, forKey: .titleContains)
        try container.encodeIfPresent(calendarNameContains, forKey: .calendarNameContains)
        try container.encodeIfPresent(locationContains, forKey: .locationContains)
        try container.encode(excludeAllDay, forKey: .excludeAllDay)
        try container.encode(matchAll, forKey: .matchAll)
    }

    /// Evaluates whether an email matches this rule condition.
    public func matches(emailSender: String, emailSubject: String, emailBody: String) -> Bool {
        var checks: [Bool] = []
        if !senderContains.isEmpty {
            checks.append(senderContains.contains { !$0.isEmpty && emailSender.localizedCaseInsensitiveContains($0) })
        }
        if let subjectContains, !subjectContains.isEmpty {
            checks.append(subjectContains.contains { !$0.isEmpty && emailSubject.localizedCaseInsensitiveContains($0) })
        }
        if let contentContains, !contentContains.isEmpty {
            checks.append(contentContains.contains { !$0.isEmpty && emailBody.localizedCaseInsensitiveContains($0) })
        }
        if checks.isEmpty {
            return true
        }
        return matchAll ? checks.allSatisfy(\.self) : checks.contains { $0 }
    }

    /// Evaluates whether an inbound message matches this rule condition.
    public func matches(messageSender: String, messageText: String, isGroupChat: Bool) -> Bool {
        switch groupChatFilter {
        case .all:
            break
        case .directOnly:
            if isGroupChat {
                return false
            }
        case .groupOnly:
            if !isGroupChat {
                return false
            }
        }

        var checks: [Bool] = []
        if !senderContains.isEmpty {
            checks.append(senderContains.contains { !$0.isEmpty && messageSender.localizedCaseInsensitiveContains($0) })
        }
        if let contentContains, !contentContains.isEmpty {
            checks.append(contentContains.contains { !$0.isEmpty && messageText.localizedCaseInsensitiveContains($0) })
        }
        if checks.isEmpty {
            return true
        }
        return matchAll ? checks.allSatisfy(\.self) : checks.contains { $0 }
    }

    /// Evaluates whether an upcoming calendar event matches this rule condition.
    public func matches(
        calendarTitle: String,
        calendarName: String?,
        calendarLocation: String?,
        calendarNotes: String?,
        isAllDay: Bool
    ) -> Bool {
        if excludeAllDay && isAllDay {
            return false
        }

        var checks: [Bool] = []
        if let titleContains, !titleContains.isEmpty {
            checks.append(titleContains.contains { !$0.isEmpty && calendarTitle.localizedCaseInsensitiveContains($0) })
        }
        if let calendarNameContains, !calendarNameContains.isEmpty {
            if let cal = calendarName {
                checks.append(calendarNameContains.contains { !$0.isEmpty && cal.localizedCaseInsensitiveContains($0) })
            } else {
                checks.append(false)
            }
        }
        if let locationContains, !locationContains.isEmpty {
            if let loc = calendarLocation {
                checks.append(locationContains.contains { !$0.isEmpty && loc.localizedCaseInsensitiveContains($0) })
            } else {
                checks.append(false)
            }
        }
        if let contentContains, !contentContains.isEmpty {
            if let notes = calendarNotes {
                checks.append(contentContains.contains { !$0.isEmpty && notes.localizedCaseInsensitiveContains($0) })
            } else {
                checks.append(false)
            }
        }
        if checks.isEmpty {
            return true
        }
        return matchAll ? checks.allSatisfy(\.self) : checks.contains { $0 }
    }
}

/// Action to execute when an event rule matches.
public enum EventRuleAction: Sendable, Codable, Equatable {
    /// Dispatches an agent turn with a scoped prompt.
    case agentPrompt(prompt: String)
    /// Direct tool invocation without LLM turn (e.g. moving email to folder).
    case directTool(toolName: String, argumentsJSON: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case prompt
        case toolName
        case toolNameSnake = "tool_name"
        case argumentsJSON
        case argumentsJSONSnake = "arguments_json"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "agentPrompt", "agent_prompt", "prompt":
            let prompt = try container.decode(String.self, forKey: .prompt)
            self = .agentPrompt(prompt: prompt)
        case "directTool", "direct_tool", "tool":
            // Accept both dashboard camelCase and durable snake_case so neither
            // wire shape silently drops the tool identity.
            guard let toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
                ?? container.decodeIfPresent(String.self, forKey: .toolNameSnake)
            else {
                throw DecodingError.keyNotFound(
                    CodingKeys.toolName,
                    DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing tool name")
                )
            }
            let argumentsJSON = try container.decodeIfPresent(String.self, forKey: .argumentsJSON)
                ?? container.decodeIfPresent(String.self, forKey: .argumentsJSONSnake) ?? "{}"
            self = .directTool(toolName: toolName, argumentsJSON: argumentsJSON)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown action type: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .agentPrompt(prompt):
            try container.encode("agentPrompt", forKey: .type)
            try container.encode(prompt, forKey: .prompt)
        case let .directTool(toolName, argumentsJSON):
            try container.encode("directTool", forKey: .type)
            try container.encode(toolName, forKey: .toolName)
            try container.encode(argumentsJSON, forKey: .argumentsJSON)
        }
    }
}

extension EventRuleAction {
    /// Direct tools permitted on the zero-token fast path.
    ///
    /// The fast path bypasses LLM inference, so only narrowly-scoped mailbox
    /// and calendar mutations stay eligible; anything else must run as a
    /// scoped agent turn where the permission gate and audit apply.
    public static let allowedDirectToolNames: Set<String> = [
        "email.move",
        "email.archive",
        "calendar.delete",
        "calendar.create"
    ]

    /// Whether a tool name is eligible for direct execution (trimmed exact match, fail-closed).
    public static func isAllowedDirectTool(_ name: String) -> Bool {
        allowedDirectToolNames.contains(name.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// A single rule in an event watcher job.
public struct EventRule: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var condition: EventRuleCondition
    public var action: EventRuleAction
    /// If true, subsequent rules are not evaluated for this message/event.
    public var stopProcessing: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        enabled: Bool = true,
        condition: EventRuleCondition,
        action: EventRuleAction,
        stopProcessing: Bool = true
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.condition = condition
        self.action = action
        self.stopProcessing = stopProcessing
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case enabled
        case condition
        case action
        case stopProcessing
        case stopProcessingSnake = "stop_processing"
    }

    /// Tolerates both dashboard camelCase and durable snake_case plus omitted
    /// owner defaults, so older rows and newer payloads decode without loss.
    /// An empty-string id still fails closed at UUID decode time.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        condition = try container.decode(EventRuleCondition.self, forKey: .condition)
        action = try container.decode(EventRuleAction.self, forKey: .action)
        stopProcessing = try container.decodeIfPresent(Bool.self, forKey: .stopProcessing)
            ?? container.decodeIfPresent(Bool.self, forKey: .stopProcessingSnake) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(condition, forKey: .condition)
        try container.encode(action, forKey: .action)
        try container.encode(stopProcessing, forKey: .stopProcessing)
    }
}

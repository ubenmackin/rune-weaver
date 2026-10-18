// Rune Weaver Tools — Reminders search, create, update, and delete tools.

import Foundation
import RuneWeaverCore

// MARK: - Arguments

public struct RemindersSearchArgs: Sendable, Equatable, Decodable {
    public let query: String?
    public let reminderID: String?
    public let listNames: [String]?
    public let includeCompleted: Bool
    public let since: String?
    public let until: String?
    public let limit: Int

    public static let defaultLimit = 20
    public static let maxLimit = 50
    public static let maxListNames = 10

    public init(
        query: String? = nil,
        reminderID: String? = nil,
        listNames: [String]? = nil,
        includeCompleted: Bool = false,
        since: String? = nil,
        until: String? = nil,
        limit: Int = defaultLimit
    ) {
        self.query = Self.normalized(query)
        self.reminderID = Self.normalized(reminderID)
        let cleaned = (listNames ?? []).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        let capped = Array(cleaned.prefix(Self.maxListNames))
        self.listNames = capped.isEmpty ? nil : capped
        self.includeCompleted = includeCompleted
        self.since = Self.normalized(since)
        self.until = Self.normalized(until)
        self.limit = min(max(limit, 1), Self.maxLimit)
    }

    private enum CodingKeys: String, CodingKey {
        case query
        case reminderID
        case reminderId
        case reminderIDUnderscore = "reminder_id"
        case id
        case listNames
        case listNamesUnderscore = "list_names"
        case includeCompleted
        case includeCompletedUnderscore = "include_completed"
        case since
        case until
        case limit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawQuery = try container.decodeIfPresent(String.self, forKey: .query)
        if let rawQuery, rawQuery.contains("\0") {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Query must not contain null bytes.")
            )
        }
        let rawReminderID = try container.decodeIfPresent(String.self, forKey: .reminderID)
        let rawReminderId = try container.decodeIfPresent(String.self, forKey: .reminderId)
        let rawReminderSnake = try container.decodeIfPresent(String.self, forKey: .reminderIDUnderscore)
        let rawID = try container.decodeIfPresent(String.self, forKey: .id)
        for candidate in [rawReminderID, rawReminderId, rawReminderSnake, rawID].compactMap(\.self) where candidate.contains("\0") {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "reminderID must not contain null bytes.")
            )
        }
        // Blank strings behave as omitted so a valid later alias still wins.
        let reminderID = [rawReminderID, rawReminderId, rawReminderSnake, rawID].compactMap(\.self).first {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let rawLists = try container.decodeIfPresent([String].self, forKey: .listNames)
            ?? container.decodeIfPresent([String].self, forKey: .listNamesUnderscore)
        if let rawLists, rawLists.contains(where: { $0.contains("\0") }) {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "List names must not contain null bytes.")
            )
        }
        let rawSince = try container.decodeIfPresent(String.self, forKey: .since)
        if let rawSince, rawSince.contains("\0") {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Since must not contain null bytes.")
            )
        }
        let rawUntil = try container.decodeIfPresent(String.self, forKey: .until)
        if let rawUntil, rawUntil.contains("\0") {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Until must not contain null bytes.")
            )
        }
        let rawLimit = try container.decodeIfPresent(Int.self, forKey: .limit) ?? Self.defaultLimit
        let includeCompleted = try container.decodeIfPresent(Bool.self, forKey: .includeCompleted)
            ?? container.decodeIfPresent(Bool.self, forKey: .includeCompletedUnderscore)
            ?? false
        self.init(
            query: rawQuery,
            reminderID: reminderID,
            listNames: rawLists,
            includeCompleted: includeCompleted,
            since: rawSince,
            until: rawUntil,
            limit: rawLimit
        )
    }

    private static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public struct RemindersCreateArgs: Sendable, Equatable, Decodable {
    public let title: String
    public let notes: String?
    public let due: String?
    public let listName: String?
    public let priority: Int?

    public init(
        title: String,
        notes: String? = nil,
        due: String? = nil,
        listName: String? = nil,
        priority: Int? = nil
    ) {
        self.title = title
        self.notes = Self.normalized(notes)
        self.due = Self.normalized(due)
        self.listName = Self.normalized(listName)
        self.priority = priority
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case notes
        case due
        case listName
        case listNameUnderscore = "list_name"
        case priority
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let rawTitle = try container.decodeIfPresent(String.self, forKey: .title) else {
            throw DecodingError.keyNotFound(
                CodingKeys.title,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing 'title'")
            )
        }
        if rawTitle.contains("\0") {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Title must not contain null bytes.")
            )
        }
        let rawNotes = try container.decodeIfPresent(String.self, forKey: .notes)
        if let rawNotes, rawNotes.contains("\0") {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Notes must not contain null bytes.")
            )
        }
        let rawDue = try container.decodeIfPresent(String.self, forKey: .due)
        if let rawDue, rawDue.contains("\0") {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Due must not contain null bytes.")
            )
        }
        let rawList = try container.decodeIfPresent(String.self, forKey: .listName)
            ?? container.decodeIfPresent(String.self, forKey: .listNameUnderscore)
        if let rawList, rawList.contains("\0") {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "List name must not contain null bytes.")
            )
        }
        let priority = try container.decodeIfPresent(Int.self, forKey: .priority)
        self.init(title: rawTitle, notes: rawNotes, due: rawDue, listName: rawList, priority: priority)
    }

    private static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public struct RemindersUpdateArgs: Sendable, Equatable, Decodable {
    public let reminderID: String
    public let title: String?
    public let notes: String?
    public let due: String?
    public let listName: String?
    public let priority: Int?
    public let completed: Bool?

    public init(
        reminderID: String,
        title: String? = nil,
        notes: String? = nil,
        due: String? = nil,
        listName: String? = nil,
        priority: Int? = nil,
        completed: Bool? = nil
    ) {
        self.reminderID = reminderID
        // Preserve an explicit empty/whitespace title so execute rejects it
        // instead of normalizing to nil (omitted). Nil stays omitted.
        if let title {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            self.title = trimmed.isEmpty ? title : trimmed
        } else {
            self.title = nil
        }
        // Preserve an explicit empty string so a notes clear reaches the
        // gateway (empty clears to nil there) instead of collapsing to nil
        // (omitted/preserve). Nil stays omitted.
        self.notes = Self.preservedForClear(notes)
        self.due = Self.normalized(due)
        self.listName = Self.normalized(listName)
        self.priority = priority
        self.completed = completed
    }

    private enum CodingKeys: String, CodingKey {
        case reminderID
        case reminderId
        case reminderIDUnderscore = "reminder_id"
        case id
        case title
        case notes
        case due
        case listName
        case listNameUnderscore = "list_name"
        case priority
        case completed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawReminderID = try container.decodeIfPresent(String.self, forKey: .reminderID)
        let rawReminderId = try container.decodeIfPresent(String.self, forKey: .reminderId)
        let rawReminderSnake = try container.decodeIfPresent(String.self, forKey: .reminderIDUnderscore)
        let rawIDAlias = try container.decodeIfPresent(String.self, forKey: .id)
        for candidate in [rawReminderID, rawReminderId, rawReminderSnake, rawIDAlias].compactMap(\.self) where candidate.contains("\0") {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Reminder identifier must not contain null bytes.")
            )
        }
        // Blank strings behave as omitted so a valid later alias still wins.
        guard let rawID = [rawReminderID, rawReminderId, rawReminderSnake, rawIDAlias].compactMap(\.self).first(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            throw DecodingError.keyNotFound(
                CodingKeys.reminderID,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing 'reminderID'")
            )
        }
        let rawTitle = try container.decodeIfPresent(String.self, forKey: .title)
        if let rawTitle, rawTitle.contains("\0") {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Title must not contain null bytes.")
            )
        }
        let rawNotes = try container.decodeIfPresent(String.self, forKey: .notes)
        if let rawNotes, rawNotes.contains("\0") {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Notes must not contain null bytes.")
            )
        }
        let rawDue = try container.decodeIfPresent(String.self, forKey: .due)
        if let rawDue, rawDue.contains("\0") {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Due must not contain null bytes.")
            )
        }
        let rawListCamel = try container.decodeIfPresent(String.self, forKey: .listName)
        let rawListSnake = try container.decodeIfPresent(String.self, forKey: .listNameUnderscore)
        // Blank strings behave as omitted so a valid later alias still wins.
        let rawList = [rawListCamel, rawListSnake].compactMap(\.self).first(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) ?? [rawListCamel, rawListSnake].compactMap(\.self).first
        if let rawList, rawList.contains("\0") {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "List name must not contain null bytes.")
            )
        }
        let priority = try container.decodeIfPresent(Int.self, forKey: .priority)
        let completed = try container.decodeIfPresent(Bool.self, forKey: .completed)
        self.init(
            reminderID: rawID,
            title: rawTitle,
            notes: rawNotes,
            due: rawDue,
            listName: rawList,
            priority: priority,
            completed: completed
        )
    }

    private static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func preservedForClear(_ raw: String?) -> String? {
        guard let raw else { return nil }
        if raw.isEmpty {
            return ""
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : trimmed
    }
}

public struct RemindersDeleteArgs: Sendable, Equatable, Decodable {
    public let reminderID: String

    public init(reminderID: String) {
        self.reminderID = reminderID
    }

    private enum CodingKeys: String, CodingKey {
        case reminderID
        case reminderId
        case reminderIDUnderscore = "reminder_id"
        case id
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawReminderID = try container.decodeIfPresent(String.self, forKey: .reminderID)
        let rawReminderId = try container.decodeIfPresent(String.self, forKey: .reminderId)
        let rawReminderSnake = try container.decodeIfPresent(String.self, forKey: .reminderIDUnderscore)
        let rawIDAlias = try container.decodeIfPresent(String.self, forKey: .id)
        for candidate in [rawReminderID, rawReminderId, rawReminderSnake, rawIDAlias].compactMap(\.self) where candidate.contains("\0") {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Reminder identifier must not contain null bytes.")
            )
        }
        // Blank strings behave as omitted so a valid later alias still wins.
        guard let rawID = [rawReminderID, rawReminderId, rawReminderSnake, rawIDAlias].compactMap(\.self).first(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            throw DecodingError.keyNotFound(
                CodingKeys.reminderID,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing 'reminderID'")
            )
        }
        self.init(reminderID: rawID)
    }
}

// MARK: - Envelopes

public struct RemindersSearchEnvelope: Sendable, Equatable, Codable {
    public let query: String?
    public let reminderID: String?
    public let listNames: [String]?
    public let includeCompleted: Bool
    public let count: Int
    public let reminders: [ReminderItem]

    public init(query: String?, reminderID: String? = nil, listNames: [String]?, includeCompleted: Bool, reminders: [ReminderItem]) {
        self.query = query
        self.reminderID = reminderID
        self.listNames = listNames
        self.includeCompleted = includeCompleted
        self.count = reminders.count
        self.reminders = reminders
    }
}

public struct RemindersDeleteEnvelope: Sendable, Equatable, Codable {
    public let success: Bool
    public let reminderID: String

    public init(success: Bool = true, reminderID: String) {
        self.success = success
        self.reminderID = reminderID
    }
}

// MARK: - Tools

public struct RemindersSearchTool: Tool, Sendable {
    public let name = "reminders.search"
    public let description =
        "Searches reminders by text query, list, and due window. "
            + "Use when the user asks about reminders, to-dos, or due items. "
            + "Empty or omitted query lists the window defined by since (inclusive) and until (exclusive) as YYYY-MM-DD or full ISO8601 datetimes. "
            + "With reminderID fetches one verbatim. "
            + "Returns matching reminders with opaque identifiers for update and delete. "
            + "For entity-plus-time questions about due items such as upcoming deadlines, reminders.search is decisive; do not keep searching after it answers."

    public let inputSchema = JSONSchema(
        rawValue: """
        {
          "type": "object",
          "properties": {
            "query": {
              "type": "string",
              "description": "Free-text query matched against title and notes; omitted, empty, or * lists reminders"
            },
            "reminderID": {
              "type": "string",
              "description": "Opaque reminder identifier for a direct lookup; passed verbatim"
            },
            "listNames": {
              "type": "array",
              "description": "Optional reminder list titles to search (up to 10); omitted searches all lists",
              "maxItems": 10,
              "items": {"type": "string"}
            },
            "includeCompleted": {
              "type": "boolean",
              "description": "When true, include completed reminders (default false)"
            },
            "since": {
              "type": "string",
              "description": "Optional inclusive lower bound YYYY-MM-DD local-day or full ISO8601 datetime"
            },
            "until": {
              "type": "string",
              "description": "Optional exclusive upper bound YYYY-MM-DD local-day or full ISO8601 datetime"
            },
            "limit": {
              "type": "integer",
              "description": "Maximum reminders to return (1-50, default 20)",
              "minimum": 1,
              "maximum": 50
            }
          },
          "required":[],
          "additionalProperties": false
        }
        """
    )

    public let permissionLevel = PermissionLevel.readOnly

    private let gateway: any RemindersGateway

    public init(gateway: any RemindersGateway) {
        self.gateway = gateway
    }

    public func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        let args: RemindersSearchArgs
        do {
            args = try JSONDecoder().decode(RemindersSearchArgs.self, from: Data(input.argumentsJSON.utf8))
        } catch {
            return .failure(
                "Invalid reminders.search arguments: expected {\"query\": \"...\", \"limit\": <1-50>} "
                    + "with optional \"reminderID\", \"listNames\", \"includeCompleted\", \"since\", \"until\".",
                callID: input.callID
            )
        }
        let range: TemporalRange
        do {
            range = try TemporalFilter.parse(since: args.since, until: args.until)
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return .failure(detail, callID: input.callID)
        }
        do {
            let items = try await gateway.search(
                query: args.query,
                reminderID: args.reminderID,
                listNames: args.listNames,
                includeCompleted: args.includeCompleted,
                range: range,
                limit: args.limit
            )
            let envelope = RemindersSearchEnvelope(
                query: args.query,
                reminderID: args.reminderID,
                listNames: args.listNames,
                includeCompleted: args.includeCompleted,
                reminders: items
            )
            let content = try ToolEnvelopeEncoding.encode(envelope)
            return .success(content, callID: input.callID)
        } catch let error as CancellationError {
            throw error
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
    }
}

public struct RemindersCreateTool: Tool, Sendable {
    public let name = "reminders.create"
    public let description =
        "Creates one reminder in a named list with optional notes, due date, and priority. "
            + "Use when the user asks to add a to-do or reminder."

    public let inputSchema = JSONSchema(
        rawValue: """
        {
          "type": "object",
          "properties": {
            "title": {
              "type": "string",
              "description": "Reminder title (1-300 chars)"
            },
            "notes": {
              "type": "string",
              "description": "Optional notes (up to 8000 chars)"
            },
            "due": {
              "type": "string",
              "description": "Optional due instant as YYYY-MM-DD local-day or full ISO8601 datetime"
            },
            "listName": {
              "type": "string",
              "description": "Optional reminder list title; omitted uses the default list"
            },
            "priority": {
              "type": "integer",
              "description": "Optional priority 0 through 9 (0 means none)",
              "minimum": 0,
              "maximum": 9
            }
          },
          "required":["title"],
          "additionalProperties": false
        }
        """
    )

    public let permissionLevel = PermissionLevel.requiresApproval

    private let gateway: any RemindersGateway

    public init(gateway: any RemindersGateway) {
        self.gateway = gateway
    }

    public func execute(input: ToolInput, context: ToolContext) async throws -> ToolOutput {
        let args: RemindersCreateArgs
        do {
            args = try JSONDecoder().decode(RemindersCreateArgs.self, from: Data(input.argumentsJSON.utf8))
        } catch {
            return .failure(
                "Invalid reminders.create arguments: expected {\"title\": \"<text>\"}.",
                callID: input.callID
            )
        }
        let trimmedTitle = args.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            return .failure("Invalid reminders.create arguments: 'title' must not be empty.", callID: input.callID)
        }
        // A null byte truncates downstream string bridges, so reject rather than truncate.
        guard !trimmedTitle.contains("\0") else {
            return .failure("Invalid reminders.create arguments: 'title' must not contain null bytes.", callID: input.callID)
        }
        guard trimmedTitle.count <= TemporalFilter.gatewayMaxTitleChars else {
            return .failure(
                "Invalid reminders.create arguments: 'title' must be \(TemporalFilter.gatewayMaxTitleChars) characters or fewer.",
                callID: input.callID
            )
        }
        if let notes = args.notes {
            guard !notes.contains("\0") else {
                return .failure("Invalid reminders.create arguments: 'notes' must not contain null bytes.", callID: input.callID)
            }
            guard notes.count <= TemporalFilter.gatewayMaxNotesChars else {
                return .failure(
                    "Invalid reminders.create arguments: 'notes' must be \(TemporalFilter.gatewayMaxNotesChars) characters or fewer.",
                    callID: input.callID
                )
            }
        }
        // Decode already rejects nulls; re-check here so direct initializers fail closed too.
        if let listName = args.listName, listName.contains("\0") {
            return .failure("Invalid reminders.create arguments: 'listName' must not contain null bytes.", callID: input.callID)
        }
        let dueDate: Date?
        if let dueRaw = args.due {
            do {
                dueDate = try TemporalFilter.parse(since: dueRaw, until: nil).since
            } catch {
                let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                return .failure(detail, callID: input.callID)
            }
        } else {
            dueDate = nil
        }
        if let priority = args.priority, !(0 ... 9).contains(priority) {
            return .failure("Invalid reminders.create arguments: 'priority' must be 0 through 9.", callID: input.callID)
        }
        if context.dryRun {
            return .success("Dry run: would create reminder '\(trimmedTitle)'.", callID: input.callID)
        }
        do {
            let item = try await gateway.create(
                title: trimmedTitle,
                notes: args.notes,
                due: dueDate,
                listName: args.listName,
                priority: args.priority
            )
            let content = try ToolEnvelopeEncoding.encode(item)
            return .success(content, callID: input.callID)
        } catch let error as CancellationError {
            throw error
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
    }
}

public struct RemindersUpdateTool: Tool, Sendable {
    public let name = "reminders.update"
    public let description =
        "Updates one reminder's title, notes, due date, list, priority, or completion. "
            + "This tool owns completion via the completed flag; there is no separate complete tool. "
            + "Pass the opaque reminderID from reminders.search verbatim."

    public let inputSchema = JSONSchema(
        rawValue: """
        {
          "type": "object",
          "properties": {
            "reminderID": {
              "type": "string",
              "description": "Opaque reminder identifier from reminders.search"
            },
            "title": {
              "type": "string",
              "description": "Replacement title (1-300 chars)"
            },
            "notes": {
              "type": "string",
              "description": "Replacement notes (up to 8000 chars)"
            },
            "due": {
              "type": "string",
              "description": "Replacement due instant as YYYY-MM-DD local-day or full ISO8601 datetime"
            },
            "listName": {
              "type": "string",
              "description": "Destination reminder list title"
            },
            "priority": {
              "type": "integer",
              "description": "Replacement priority 0 through 9",
              "minimum": 0,
              "maximum": 9
            },
            "completed": {
              "type": "boolean",
              "description": "True marks completed, false reopens; completion lives here, not in a separate tool"
            }
          },
          "required":["reminderID"],
          "additionalProperties": false
        }
        """
    )

    public let permissionLevel = PermissionLevel.requiresApproval

    private let gateway: any RemindersGateway

    public init(gateway: any RemindersGateway) {
        self.gateway = gateway
    }

    public func execute(input: ToolInput, context: ToolContext) async throws -> ToolOutput {
        let args: RemindersUpdateArgs
        do {
            args = try JSONDecoder().decode(RemindersUpdateArgs.self, from: Data(input.argumentsJSON.utf8))
        } catch {
            return .failure(
                "Invalid reminders.update arguments: expected {\"reminderID\": \"<id>\"}.",
                callID: input.callID
            )
        }
        let reminderID = args.reminderID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reminderID.isEmpty else {
            return .failure("Invalid reminders.update arguments: 'reminderID' must not be empty.", callID: input.callID)
        }
        guard !reminderID.contains("\0") else {
            return .failure("Invalid reminders.update arguments: 'reminderID' must not contain null bytes.", callID: input.callID)
        }
        if let title = args.title, title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .failure("Invalid reminders.update arguments: 'title' must not be empty.", callID: input.callID)
        }
        if let title = args.title {
            guard !title.contains("\0") else {
                return .failure("Invalid reminders.update arguments: 'title' must not contain null bytes.", callID: input.callID)
            }
            guard title.count <= TemporalFilter.gatewayMaxTitleChars else {
                return .failure(
                    "Invalid reminders.update arguments: 'title' must be \(TemporalFilter.gatewayMaxTitleChars) characters or fewer.",
                    callID: input.callID
                )
            }
        }
        if let notes = args.notes {
            guard !notes.contains("\0") else {
                return .failure("Invalid reminders.update arguments: 'notes' must not contain null bytes.", callID: input.callID)
            }
            guard notes.count <= TemporalFilter.gatewayMaxNotesChars else {
                return .failure(
                    "Invalid reminders.update arguments: 'notes' must be \(TemporalFilter.gatewayMaxNotesChars) characters or fewer.",
                    callID: input.callID
                )
            }
        }
        // Decode already rejects nulls; re-check here so direct initializers fail closed too.
        if let listName = args.listName, listName.contains("\0") {
            return .failure("Invalid reminders.update arguments: 'listName' must not contain null bytes.", callID: input.callID)
        }
        let dueDate: Date?
        if let dueRaw = args.due {
            do {
                dueDate = try TemporalFilter.parse(since: dueRaw, until: nil).since
            } catch {
                let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                return .failure(detail, callID: input.callID)
            }
        } else {
            dueDate = nil
        }
        if let priority = args.priority, !(0 ... 9).contains(priority) {
            return .failure("Invalid reminders.update arguments: 'priority' must be 0 through 9.", callID: input.callID)
        }
        if context.dryRun {
            return .success("Dry run: would update reminder '\(reminderID)'.", callID: input.callID)
        }
        do {
            let item = try await gateway.update(
                reminderID: reminderID,
                patch: ReminderUpdatePatch(
                    title: args.title,
                    notes: args.notes,
                    due: dueDate,
                    listName: args.listName,
                    priority: args.priority,
                    completed: args.completed
                )
            )
            let content = try ToolEnvelopeEncoding.encode(item)
            return .success(content, callID: input.callID)
        } catch let error as CancellationError {
            throw error
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
    }
}

public struct RemindersDeleteTool: Tool, Sendable {
    public let name = "reminders.delete"
    public let description =
        "Deletes one reminder by its opaque identifier. "
            + "Use when the user asks to remove or delete a to-do. Pass reminderID verbatim."

    public let inputSchema = JSONSchema(
        rawValue: """
        {
          "type": "object",
          "properties": {
            "reminderID": {
              "type": "string",
              "description": "Opaque reminder identifier from reminders.search"
            }
          },
          "required":["reminderID"],
          "additionalProperties": false
        }
        """
    )

    public let permissionLevel = PermissionLevel.requiresApproval

    private let gateway: any RemindersGateway

    public init(gateway: any RemindersGateway) {
        self.gateway = gateway
    }

    public func execute(input: ToolInput, context: ToolContext) async throws -> ToolOutput {
        let args: RemindersDeleteArgs
        do {
            args = try JSONDecoder().decode(RemindersDeleteArgs.self, from: Data(input.argumentsJSON.utf8))
        } catch {
            return .failure(
                "Invalid reminders.delete arguments: expected {\"reminderID\": \"<id>\"}.",
                callID: input.callID
            )
        }
        let reminderID = args.reminderID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reminderID.isEmpty else {
            return .failure("Invalid reminders.delete arguments: 'reminderID' must not be empty.", callID: input.callID)
        }
        guard !reminderID.contains("\0") else {
            return .failure("Invalid reminders.delete arguments: 'reminderID' must not contain null bytes.", callID: input.callID)
        }
        if context.dryRun {
            return .success("Dry run: would delete reminder '\(reminderID)'.", callID: input.callID)
        }
        do {
            try await gateway.delete(reminderID: reminderID)
            let envelope = RemindersDeleteEnvelope(reminderID: reminderID)
            let content = try ToolEnvelopeEncoding.encode(envelope)
            return .success(content, callID: input.callID)
        } catch let error as CancellationError {
            throw error
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
    }
}

// MARK: - Factory

public enum RemindersTools {
    public static let toolNames = ["reminders.search", "reminders.create", "reminders.update", "reminders.delete"]

    public static func makeTools(gateway: any RemindersGateway? = nil) -> [any Tool] {
        let effective: any RemindersGateway = gateway ?? ProductionRemindersGateway()
        let search: any Tool = RemindersSearchTool(gateway: effective)
        let create: any Tool = RemindersCreateTool(gateway: effective)
        let update: any Tool = RemindersUpdateTool(gateway: effective)
        let delete: any Tool = RemindersDeleteTool(gateway: effective)
        return [search, create, update, delete]
    }

    public static func register(on bus: ToolBus, gateway: any RemindersGateway? = nil) async {
        for tool in makeTools(gateway: gateway) {
            await bus.register(tool: tool)
        }
    }
}

// MARK: - Default production gateway

/// Unavailable path shares the single UnavailableEventKitStore defined in
/// CalendarTools.swift so calendar and reminders cannot drift.
extension ProductionRemindersGateway {
    public init() {
        self.init(store: UnavailableEventKitStore())
    }
}

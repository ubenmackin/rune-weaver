// Rune Weaver Tools — Calendar search, create, update, and delete tools.

import Foundation
import RuneWeaverCore

// MARK: - Args

public struct CalendarSearchArgs: Sendable, Equatable, Decodable {
    public let query: String?
    public let eventID: String?
    public let calendarNames: [String]?
    public let since: String?
    public let until: String?
    public let limit: Int

    public static let defaultLimit = 20
    public static let maxLimit = 50
    public static let maxCalendarNames = 10

    public init(
        query: String? = nil,
        eventID: String? = nil,
        calendarNames: [String]? = nil,
        since: String? = nil,
        until: String? = nil,
        limit: Int = defaultLimit
    ) {
        self.query = Self.normalized(query)
        self.eventID = Self.normalized(eventID)
        if let calendarNames {
            let cleaned = calendarNames.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
            self.calendarNames = cleaned.isEmpty ? nil : Array(cleaned.prefix(Self.maxCalendarNames))
        } else {
            self.calendarNames = nil
        }
        self.since = Self.normalized(since)
        self.until = Self.normalized(until)
        self.limit = min(max(limit, 1), Self.maxLimit)
    }

    private enum CodingKeys: String, CodingKey {
        case query
        case eventID
        case eventId
        case eventIDUnderscore = "event_id"
        case id
        case calendarNames
        case calendarNamesUnderscore = "calendar_names"
        case since
        case until
        case limit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawQuery = try container.decodeIfPresent(String.self, forKey: .query)
        if let rawQuery, rawQuery.contains("\0") {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "query must not contain null bytes.")
            )
        }
        let rawEventID = try container.decodeIfPresent(String.self, forKey: .eventID)
        let rawEventId = try container.decodeIfPresent(String.self, forKey: .eventId)
        let rawEventSnake = try container.decodeIfPresent(String.self, forKey: .eventIDUnderscore)
        let rawID = try container.decodeIfPresent(String.self, forKey: .id)
        for candidate in [rawEventID, rawEventId, rawEventSnake, rawID].compactMap(\.self) where candidate.contains("\0") {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "eventID must not contain null bytes.")
            )
        }
        // Blank strings behave as omitted so a valid later alias still wins.
        let eventID = [rawEventID, rawEventId, rawEventSnake, rawID].compactMap(\.self).first {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let rawNames = try container.decodeIfPresent([String].self, forKey: .calendarNames)
            ?? container.decodeIfPresent([String].self, forKey: .calendarNamesUnderscore)
        if let rawNames {
            for name in rawNames where name.contains("\0") {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "calendarNames must not contain null bytes.")
                )
            }
        }
        let rawSince = try container.decodeIfPresent(String.self, forKey: .since)
        if let rawSince, rawSince.contains("\0") {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "since must not contain null bytes.")
            )
        }
        let rawUntil = try container.decodeIfPresent(String.self, forKey: .until)
        if let rawUntil, rawUntil.contains("\0") {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "until must not contain null bytes.")
            )
        }
        let rawLimit = try container.decodeIfPresent(Int.self, forKey: .limit) ?? Self.defaultLimit
        self.init(query: rawQuery, eventID: eventID, calendarNames: rawNames, since: rawSince, until: rawUntil, limit: rawLimit)
    }

    private static func normalized(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

public struct CalendarCreateArgs: Sendable, Equatable, Decodable {
    public let title: String
    public let notes: String?
    public let start: String?
    public let end: String?
    public let isAllDay: Bool
    public let calendarName: String?
    public let location: String?

    public init(
        title: String,
        notes: String? = nil,
        start: String? = nil,
        end: String? = nil,
        isAllDay: Bool = false,
        calendarName: String? = nil,
        location: String? = nil
    ) {
        self.title = title
        self.notes = Self.normalized(notes)
        self.start = Self.normalized(start)
        self.end = Self.normalized(end)
        self.isAllDay = isAllDay
        self.calendarName = Self.normalized(calendarName)
        self.location = Self.normalized(location)
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case notes
        case start
        case end
        case isAllDay
        case isAllDayUnderscore = "is_all_day"
        case calendarName
        case calendarNameUnderscore = "calendar_name"
        case location
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let rawTitle = try container.decodeIfPresent(String.self, forKey: .title) else {
            throw DecodingError.keyNotFound(
                CodingKeys.title,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing 'title'")
            )
        }
        // Embedded nulls truncate the underlying store string, so reject at the decode boundary.
        if rawTitle.contains("\0") {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "title must not contain null bytes.")
            )
        }
        let rawNotes = try container.decodeIfPresent(String.self, forKey: .notes)
        if let rawNotes, rawNotes.contains("\0") {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "notes must not contain null bytes.")
            )
        }
        let rawStart = try container.decodeIfPresent(String.self, forKey: .start)
        if let rawStart, rawStart.contains("\0") {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "start must not contain null bytes.")
            )
        }
        let rawEnd = try container.decodeIfPresent(String.self, forKey: .end)
        if let rawEnd, rawEnd.contains("\0") {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "end must not contain null bytes.")
            )
        }
        let isAllDay = try container.decodeIfPresent(Bool.self, forKey: .isAllDay)
            ?? container.decodeIfPresent(Bool.self, forKey: .isAllDayUnderscore)
            ?? false
        let rawCalendarName = try container.decodeIfPresent(String.self, forKey: .calendarName)
            ?? container.decodeIfPresent(String.self, forKey: .calendarNameUnderscore)
        if let rawCalendarName, rawCalendarName.contains("\0") {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "calendarName must not contain null bytes.")
            )
        }
        let rawLocation = try container.decodeIfPresent(String.self, forKey: .location)
        if let rawLocation, rawLocation.contains("\0") {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "location must not contain null bytes.")
            )
        }
        self.init(title: rawTitle, notes: rawNotes, start: rawStart, end: rawEnd, isAllDay: isAllDay, calendarName: rawCalendarName, location: rawLocation)
    }

    private static func normalized(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

public struct CalendarUpdateArgs: Sendable, Equatable, Decodable {
    public let eventID: String
    public let title: String?
    public let notes: String?
    public let start: String?
    public let end: String?
    public let calendarName: String?
    public let location: String?

    public init(
        eventID: String,
        title: String? = nil,
        notes: String? = nil,
        start: String? = nil,
        end: String? = nil,
        calendarName: String? = nil,
        location: String? = nil
    ) {
        self.eventID = eventID
        // Preserve an explicit empty/whitespace title so execute rejects it
        // instead of normalizing to nil (omitted). Nil stays omitted.
        if let title {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            self.title = trimmed.isEmpty ? title : trimmed
        } else {
            self.title = nil
        }
        // Preserve an explicit empty string so a notes/location clear reaches
        // the gateway (empty clears to nil there) instead of collapsing to
        // nil (omitted/preserve). Nil stays omitted.
        self.notes = Self.preservedForClear(notes)
        self.start = Self.normalized(start)
        self.end = Self.normalized(end)
        self.calendarName = Self.normalized(calendarName)
        self.location = Self.preservedForClear(location)
    }

    private enum CodingKeys: String, CodingKey {
        case eventID
        case eventId
        case eventIDUnderscore = "event_id"
        case id
        case title
        case notes
        case start
        case end
        case calendarName
        case calendarNameUnderscore = "calendar_name"
        case location
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawEventID = try container.decodeIfPresent(String.self, forKey: .eventID)
        let rawEventId = try container.decodeIfPresent(String.self, forKey: .eventId)
        let rawEventSnake = try container.decodeIfPresent(String.self, forKey: .eventIDUnderscore)
        let rawID = try container.decodeIfPresent(String.self, forKey: .id)
        for candidate in [rawEventID, rawEventId, rawEventSnake, rawID].compactMap(\.self) where candidate.contains("\0") {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "eventID must not contain null bytes.")
            )
        }
        // Blank strings behave as omitted so a valid later alias still wins.
        guard let resolvedID = [rawEventID, rawEventId, rawEventSnake, rawID].compactMap(\.self).first(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            throw DecodingError.keyNotFound(
                CodingKeys.eventID,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing 'eventID'")
            )
        }
        let rawTitle = try container.decodeIfPresent(String.self, forKey: .title)
        if let rawTitle, rawTitle.contains("\0") {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "title must not contain null bytes.")
            )
        }
        let rawNotes = try container.decodeIfPresent(String.self, forKey: .notes)
        if let rawNotes, rawNotes.contains("\0") {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "notes must not contain null bytes.")
            )
        }
        let rawStart = try container.decodeIfPresent(String.self, forKey: .start)
        if let rawStart, rawStart.contains("\0") {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "start must not contain null bytes.")
            )
        }
        let rawEnd = try container.decodeIfPresent(String.self, forKey: .end)
        if let rawEnd, rawEnd.contains("\0") {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "end must not contain null bytes.")
            )
        }
        let rawCalendarCamel = try container.decodeIfPresent(String.self, forKey: .calendarName)
        let rawCalendarSnake = try container.decodeIfPresent(String.self, forKey: .calendarNameUnderscore)
        // Blank strings behave as omitted so a valid later alias still wins.
        let rawCalendarName = [rawCalendarCamel, rawCalendarSnake].compactMap(\.self).first(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) ?? [rawCalendarCamel, rawCalendarSnake].compactMap(\.self).first
        if let rawCalendarName, rawCalendarName.contains("\0") {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "calendarName must not contain null bytes.")
            )
        }
        let rawLocation = try container.decodeIfPresent(String.self, forKey: .location)
        if let rawLocation, rawLocation.contains("\0") {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "location must not contain null bytes.")
            )
        }
        self.init(eventID: resolvedID, title: rawTitle, notes: rawNotes, start: rawStart, end: rawEnd, calendarName: rawCalendarName, location: rawLocation)
    }

    private static func normalized(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
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

public struct CalendarDeleteArgs: Sendable, Equatable, Decodable {
    public let eventID: String

    public init(eventID: String) {
        self.eventID = eventID
    }

    private enum CodingKeys: String, CodingKey {
        case eventID
        case eventId
        case eventIDUnderscore = "event_id"
        case id
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawEventID = try container.decodeIfPresent(String.self, forKey: .eventID)
        let rawEventId = try container.decodeIfPresent(String.self, forKey: .eventId)
        let rawEventSnake = try container.decodeIfPresent(String.self, forKey: .eventIDUnderscore)
        let rawID = try container.decodeIfPresent(String.self, forKey: .id)
        for candidate in [rawEventID, rawEventId, rawEventSnake, rawID].compactMap(\.self) where candidate.contains("\0") {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "eventID must not contain null bytes.")
            )
        }
        // Blank strings behave as omitted so a valid later alias still wins.
        guard let resolvedID = [rawEventID, rawEventId, rawEventSnake, rawID].compactMap(\.self).first(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            throw DecodingError.keyNotFound(
                CodingKeys.eventID,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing 'eventID'")
            )
        }
        self.init(eventID: resolvedID)
    }
}

// MARK: - Envelopes

public struct CalendarSearchEnvelope: Sendable, Equatable, Codable {
    public let query: String?
    public let eventID: String?
    public let count: Int
    public let events: [CalendarEventItem]

    public init(query: String?, eventID: String?, events: [CalendarEventItem]) {
        self.query = query
        self.eventID = eventID
        self.events = events
        self.count = events.count
    }
}

public struct CalendarDeleteEnvelope: Sendable, Equatable, Codable {
    public let success: Bool
    public let eventID: String

    public init(success: Bool = true, eventID: String) {
        self.success = success
        self.eventID = eventID
    }
}

// MARK: - Tools

public struct CalendarSearchTool: Tool, Sendable {
    public let name = "calendar.search"
    public let description =
        "Searches calendar events as HTML-free plaintext (titles, notes, and locations contain no HTML). "
            + "Use when the user asks about schedule, meetings, or events. "
            + "Empty or omitted query lists the window defined by since (inclusive) and until (exclusive) as YYYY-MM-DD or full ISO8601 datetimes. "
            + "Each event carries device-timezone startDisplay and endDisplay strings alongside ISO Zulu startDateISO and endDateISO. "
            + "Present startDisplay and endDisplay to the user and use startDateISO and endDateISO for sorting only. "
            + "Returns matching events with opaque identifiers for follow-up update or delete. "
            + "For entity-plus-time questions about schedule such as next sessions, calendar.search is decisive; do not keep searching after it answers."

    public let inputSchema = JSONSchema(
        rawValue: """
        {
          "type": "object",
          "properties": {
            "query": {
              "type": "string",
              "description": "Free-text query matched against title, notes, and location; omitted or empty lists the window"
            },
            "eventID": {
              "type": "string",
              "description": "Opaque event identifier for a direct lookup; passed verbatim"
            },
            "calendarNames": {
              "type": "array",
              "description": "Calendar titles to search (up to 10, case-insensitive); omitted searches all",
              "maxItems": 10,
              "items": {"type": "string"}
            },
            "since": {
              "type": "string",
              "description": "Optional inclusive lower bound YYYY-MM-DD (local midnight inclusive) or full ISO8601 datetime"
            },
            "until": {
              "type": "string",
              "description": "Optional exclusive upper bound YYYY-MM-DD (local midnight exclusive) or full ISO8601 datetime"
            },
            "limit": {
              "type": "integer",
              "description": "Maximum events to return (1-50, default 20)",
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

    private let gateway: any CalendarGateway

    public init(gateway: any CalendarGateway) {
        self.gateway = gateway
    }

    public func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        let args: CalendarSearchArgs
        do {
            args = try JSONDecoder().decode(CalendarSearchArgs.self, from: Data(input.argumentsJSON.utf8))
        } catch {
            return .failure(
                "Invalid calendar.search arguments: expected {\"query\": \"...\", \"limit\": <1-50>} "
                    + "with optional \"eventID\", \"calendarNames\", \"since\", \"until\".",
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
                eventID: args.eventID,
                calendarNames: args.calendarNames,
                since: range.since,
                until: range.until,
                limit: args.limit
            )
            let envelope = CalendarSearchEnvelope(query: args.query, eventID: args.eventID, events: items)
            let json = try ToolEnvelopeEncoding.encode(envelope)
            return .success(json, callID: input.callID)
        } catch let error as CancellationError {
            throw error
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
    }
}

public struct CalendarCreateTool: Tool, Sendable {
    public let name = "calendar.create"
    public let description =
        "Creates a calendar event with HTML-free plaintext fields (titles, notes, and locations contain no HTML). "
            + "Use when the user asks to add, schedule, or create an event. "
            + "Requires approval. Pass title plus optional notes (up to 8000 chars), "
            + "start/end as YYYY-MM-DD or full ISO8601 datetimes, isAllDay, calendarName, and location. "
            + "Returns the created event with its opaque identifier."

    public let inputSchema = JSONSchema(
        rawValue: """
        {
          "type": "object",
          "properties": {
            "title": {
              "type": "string",
              "description": "Event title as HTML-free plaintext (1-300 chars)"
            },
            "notes": {
              "type": "string",
              "description": "Optional notes as HTML-free plaintext (up to 8000 chars)"
            },
            "start": {
              "type": "string",
              "description": "Optional start as YYYY-MM-DD or full ISO8601 datetime"
            },
            "end": {
              "type": "string",
              "description": "Optional end as YYYY-MM-DD or full ISO8601 datetime; must not precede start"
            },
            "isAllDay": {
              "type": "boolean",
              "description": "Whether the event is all-day (default false)"
            },
            "calendarName": {
              "type": "string",
              "description": "Optional calendar title; omitted uses the default calendar"
            },
            "location": {
              "type": "string",
              "description": "Optional location as HTML-free plaintext"
            }
          },
          "required":["title"],
          "additionalProperties": false
        }
        """
    )

    public let permissionLevel = PermissionLevel.requiresApproval

    private let gateway: any CalendarGateway

    public init(gateway: any CalendarGateway) {
        self.gateway = gateway
    }

    public func execute(input: ToolInput, context: ToolContext) async throws -> ToolOutput {
        let args: CalendarCreateArgs
        do {
            args = try JSONDecoder().decode(CalendarCreateArgs.self, from: Data(input.argumentsJSON.utf8))
        } catch {
            return .failure(
                "Invalid calendar.create arguments: expected {\"title\": \"...\"} "
                    + "with optional \"notes\", \"start\", \"end\", \"isAllDay\", \"calendarName\", \"location\".",
                callID: input.callID
            )
        }
        let title = args.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            return .failure("Invalid calendar.create arguments: 'title' must not be empty.", callID: input.callID)
        }
        // Decode already rejects nulls; re-check here so direct initializers fail closed too.
        if args.title.contains("\0") || (args.notes?.contains("\0") ?? false)
            || (args.calendarName?.contains("\0") ?? false) || (args.location?.contains("\0") ?? false)
        {
            return .failure("Invalid calendar.create arguments: fields must not contain null bytes.", callID: input.callID)
        }
        guard title.count <= TemporalFilter.gatewayMaxTitleChars else {
            return .failure(
                "Invalid calendar.create arguments: 'title' must be \(TemporalFilter.gatewayMaxTitleChars) characters or fewer.",
                callID: input.callID
            )
        }
        if let notes = args.notes, notes.count > TemporalFilter.gatewayMaxNotesChars {
            return .failure(
                "Invalid calendar.create arguments: 'notes' must be \(TemporalFilter.gatewayMaxNotesChars) characters or fewer.",
                callID: input.callID
            )
        }
        let range: TemporalRange
        do {
            range = try TemporalFilter.parse(since: args.start, until: args.end)
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return .failure(detail, callID: input.callID)
        }
        if context.dryRun {
            return .success("Dry run: would create event '\(title)'.", callID: input.callID)
        }
        do {
            let item = try await gateway.create(
                title: title,
                options: CalendarCreateOptions(
                    notes: args.notes,
                    start: range.since,
                    end: range.until,
                    isAllDay: args.isAllDay,
                    calendarName: args.calendarName,
                    location: args.location
                )
            )
            let json = try ToolEnvelopeEncoding.encode(item)
            return .success(json, callID: input.callID)
        } catch let error as CancellationError {
            throw error
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
    }
}

public struct CalendarUpdateTool: Tool, Sendable {
    public let name = "calendar.update"
    public let description =
        "Updates a calendar event by its opaque identifier with HTML-free plaintext fields (titles, notes, and locations contain no HTML). "
            + "Use when the user asks to rename, reschedule, or move an event. "
            + "Requires approval. Omitted fields leave the event unchanged. "
            + "Returns the updated event."

    public let inputSchema = JSONSchema(
        rawValue: """
        {
          "type": "object",
          "properties": {
            "eventID": {
              "type": "string",
              "description": "Opaque event identifier from calendar.search; passed verbatim"
            },
            "title": {
              "type": "string",
              "description": "New title as HTML-free plaintext (1-300 chars)"
            },
            "notes": {
              "type": "string",
              "description": "New notes as HTML-free plaintext (up to 8000 chars)"
            },
            "start": {
              "type": "string",
              "description": "New start as YYYY-MM-DD or full ISO8601 datetime"
            },
            "end": {
              "type": "string",
              "description": "New end as YYYY-MM-DD or full ISO8601 datetime; must not precede start"
            },
            "calendarName": {
              "type": "string",
              "description": "Destination calendar title"
            },
            "location": {
              "type": "string",
              "description": "New location as HTML-free plaintext"
            }
          },
          "required":["eventID"],
          "additionalProperties": false
        }
        """
    )

    public let permissionLevel = PermissionLevel.requiresApproval

    private let gateway: any CalendarGateway

    public init(gateway: any CalendarGateway) {
        self.gateway = gateway
    }

    public func execute(input: ToolInput, context: ToolContext) async throws -> ToolOutput {
        let args: CalendarUpdateArgs
        do {
            args = try JSONDecoder().decode(CalendarUpdateArgs.self, from: Data(input.argumentsJSON.utf8))
        } catch {
            return .failure(
                "Invalid calendar.update arguments: expected {\"eventID\": \"...\"} "
                    + "with optional \"title\", \"notes\", \"start\", \"end\", \"calendarName\", \"location\".",
                callID: input.callID
            )
        }
        let eventID = args.eventID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !eventID.isEmpty else {
            return .failure("Invalid calendar.update arguments: 'eventID' must not be empty.", callID: input.callID)
        }
        if eventID.contains("\0") {
            return .failure("Invalid calendar.update arguments: 'eventID' must not contain null bytes.", callID: input.callID)
        }
        if let title = args.title, title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .failure("Invalid calendar.update arguments: 'title' must not be empty.", callID: input.callID)
        }
        // Decode already rejects nulls; re-check here so direct initializers fail closed too.
        if (args.title?.contains("\0") ?? false) || (args.notes?.contains("\0") ?? false)
            || (args.calendarName?.contains("\0") ?? false) || (args.location?.contains("\0") ?? false)
        {
            return .failure("Invalid calendar.update arguments: fields must not contain null bytes.", callID: input.callID)
        }
        if let title = args.title, title.count > TemporalFilter.gatewayMaxTitleChars {
            return .failure(
                "Invalid calendar.update arguments: 'title' must be \(TemporalFilter.gatewayMaxTitleChars) characters or fewer.",
                callID: input.callID
            )
        }
        if let notes = args.notes, notes.count > TemporalFilter.gatewayMaxNotesChars {
            return .failure(
                "Invalid calendar.update arguments: 'notes' must be \(TemporalFilter.gatewayMaxNotesChars) characters or fewer.",
                callID: input.callID
            )
        }
        let range: TemporalRange
        do {
            range = try TemporalFilter.parse(since: args.start, until: args.end)
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return .failure(detail, callID: input.callID)
        }
        if context.dryRun {
            return .success("Dry run: would update event '\(eventID)'.", callID: input.callID)
        }
        do {
            let item = try await gateway.update(
                eventID: eventID,
                patch: CalendarUpdatePatch(
                    title: args.title,
                    notes: args.notes,
                    start: range.since,
                    end: range.until,
                    calendarName: args.calendarName,
                    location: args.location
                )
            )
            let json = try ToolEnvelopeEncoding.encode(item)
            return .success(json, callID: input.callID)
        } catch let error as CancellationError {
            throw error
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
    }
}

public struct CalendarDeleteTool: Tool, Sendable {
    public let name = "calendar.delete"
    public let description =
        "Deletes a calendar event by its opaque identifier. Calendar content is HTML-free plaintext. "
            + "Use when the user asks to remove or cancel an event. "
            + "Requires approval. The identifier is passed verbatim and never parsed."

    public let inputSchema = JSONSchema(
        rawValue: """
        {
          "type": "object",
          "properties": {
            "eventID": {
              "type": "string",
              "description": "Opaque event identifier from calendar.search; passed verbatim"
            }
          },
          "required":["eventID"],
          "additionalProperties": false
        }
        """
    )

    public let permissionLevel = PermissionLevel.requiresApproval

    private let gateway: any CalendarGateway

    public init(gateway: any CalendarGateway) {
        self.gateway = gateway
    }

    public func execute(input: ToolInput, context: ToolContext) async throws -> ToolOutput {
        let args: CalendarDeleteArgs
        do {
            args = try JSONDecoder().decode(CalendarDeleteArgs.self, from: Data(input.argumentsJSON.utf8))
        } catch {
            return .failure(
                "Invalid calendar.delete arguments: expected {\"eventID\": \"...\"}.",
                callID: input.callID
            )
        }
        let eventID = args.eventID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !eventID.isEmpty else {
            return .failure("Invalid calendar.delete arguments: 'eventID' must not be empty.", callID: input.callID)
        }
        if eventID.contains("\0") {
            return .failure("Invalid calendar.delete arguments: 'eventID' must not contain null bytes.", callID: input.callID)
        }
        if context.dryRun {
            return .success("Dry run: would delete event '\(eventID)'.", callID: input.callID)
        }
        do {
            // Identifiers stay opaque: this event only is removed, never a series.
            try await gateway.delete(eventID: eventID, span: .thisEvent)
            let envelope = CalendarDeleteEnvelope(eventID: eventID)
            let json = try ToolEnvelopeEncoding.encode(envelope)
            return .success(json, callID: input.callID)
        } catch let error as CancellationError {
            throw error
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
    }
}

// MARK: - Default gateway

/// Shared fail-closed store backing the production defaults until a live
/// store is injected via the gateway parameters. One definition serves both
/// calendar and reminders so the unavailable path cannot drift.
struct UnavailableEventKitStore: EventKitStore, Sendable {
    func authorizationStatus() -> CalendarAuthorizationStatus {
        .denied
    }

    func requestAccess() async throws -> Bool {
        false
    }

    func calendars() throws -> [StoreCalendar] {
        throw CalendarToolError.permissionDenied("Access has not been granted.")
    }

    func predicateForEvents(start: Date, end: Date, calendars: [StoreCalendar]) -> CalendarFetchPredicate {
        CalendarFetchPredicate(start: start, end: end, calendars: calendars)
    }

    func events(matching _: CalendarFetchPredicate) throws -> [StoreEvent] {
        throw CalendarToolError.permissionDenied("Access has not been granted.")
    }

    func event(withIdentifier _: String) throws -> StoreEvent? {
        throw CalendarToolError.permissionDenied("Access has not been granted.")
    }

    func save(_: StoreEvent) throws -> StoreEvent {
        throw CalendarToolError.permissionDenied("Access has not been granted.")
    }

    func remove(_: StoreEvent, span _: CalendarSpan) throws {
        throw CalendarToolError.permissionDenied("Access has not been granted.")
    }

    func reminderAuthorizationStatus() -> EventKitReminderAuthorization {
        .denied
    }

    func requestReminderAccess() async throws -> Bool {
        false
    }

    func reminderCalendars() throws -> [EventKitReminderCalendar] {
        throw ReminderToolError.permissionDenied("Access was not granted.")
    }

    func fetchReminders(
        matching _: EventKitReminderPredicate,
        completion: @escaping @Sendable ([EventKitReminder]?) -> Void
    ) {
        completion(nil)
    }

    func reminder(withIdentifier _: String) -> EventKitReminder? {
        nil
    }

    func save(_: EventKitReminder) throws -> EventKitReminder {
        throw ReminderToolError.permissionDenied("Access was not granted.")
    }

    func removeReminder(withIdentifier _: String) throws {
        throw ReminderToolError.permissionDenied("Access was not granted.")
    }
}

extension ProductionCalendarGateway {
    public init() {
        self.init(store: UnavailableEventKitStore())
    }
}

// MARK: - Factory

public enum CalendarTools {
    public static let toolNames = ["calendar.search", "calendar.create", "calendar.update", "calendar.delete"]

    public static func makeTools(gateway: (any CalendarGateway)? = nil) -> [any Tool] {
        let effectiveGateway = gateway ?? ProductionCalendarGateway()
        return [
            CalendarSearchTool(gateway: effectiveGateway),
            CalendarCreateTool(gateway: effectiveGateway),
            CalendarUpdateTool(gateway: effectiveGateway),
            CalendarDeleteTool(gateway: effectiveGateway)
        ]
    }

    public static func register(on bus: ToolBus, gateway: (any CalendarGateway)? = nil) async {
        for tool in makeTools(gateway: gateway) {
            await bus.register(tool: tool)
        }
    }
}

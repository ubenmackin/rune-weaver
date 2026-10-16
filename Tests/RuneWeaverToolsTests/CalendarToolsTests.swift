// Rune Weaver Tools Tests — Calendar tool contract and mock round-trip tests.

import Foundation
import os
@testable import RuneWeaverCore
@testable import RuneWeaverTools
import Testing

final class MockCalendarGateway: CalendarGateway, Sendable {
    private struct State: Sendable {
        var items: [String: CalendarEventItem]
        var nextID: Int
    }

    private let state: OSAllocatedUnfairLock<State>

    init(items: [CalendarEventItem] = []) {
        var dict: [String: CalendarEventItem] = [:]
        for item in items {
            dict[item.id] = item
        }
        self.state = OSAllocatedUnfairLock(initialState: State(items: dict, nextID: dict.count + 1))
    }

    func search(
        query: String?,
        eventID: String?,
        calendarNames: [String]?,
        since _: Date?,
        until _: Date?,
        limit: Int
    ) async throws -> [CalendarEventItem] {
        let capped = min(max(limit, 1), 50)
        return state.withLock { s in
            if let eventID {
                let trimmed = eventID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, let item = s.items[trimmed] else { return [] }
                return [item]
            }
            var all = Array(s.items.values)
            if let raw = query?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
                all = all.filter {
                    $0.title.localizedCaseInsensitiveContains(raw)
                        || ($0.notes?.localizedCaseInsensitiveContains(raw) ?? false)
                        || ($0.location?.localizedCaseInsensitiveContains(raw) ?? false)
                }
            }
            if let names = calendarNames, !names.isEmpty {
                let wanted = Set(
                    names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
                )
                if !wanted.isEmpty {
                    all = all.filter {
                        guard let cal = $0.calendarName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return false }
                        return wanted.contains(cal)
                    }
                }
            }
            all.sort { $0.id < $1.id }
            return Array(all.prefix(capped))
        }
    }

    func create(
        title: String,
        options: CalendarCreateOptions
    ) async throws -> CalendarEventItem {
        let notes = options.notes
        let start = options.start
        let end = options.end
        let isAllDay = options.isAllDay
        let calendarName = options.calendarName
        let location = options.location
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CalendarToolError.emptyTitle }
        if title.contains("\0") {
            throw CalendarToolError.invalidInput("Title must not contain null bytes.")
        }
        guard trimmed.count <= 300 else {
            throw CalendarToolError.invalidInput("Title must be 300 characters or fewer.")
        }
        if let notes {
            if notes.contains("\0") {
                throw CalendarToolError.invalidInput("Notes must not contain null bytes.")
            }
            guard notes.count <= 8000 else {
                throw CalendarToolError.invalidInput("Notes must be 8000 characters or fewer.")
            }
        }
        if let start, let end, end < start {
            throw CalendarToolError.invalidInput("End must not precede start.")
        }
        return state.withLock { s in
            let id = "mock-\(s.nextID)"
            s.nextID += 1
            let startISO = start.map {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime]
                return formatter.string(from: $0)
            }
            let endISO = end.map {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime]
                return formatter.string(from: $0)
            }
            let item = CalendarEventItem(
                id: id,
                calendarName: calendarName,
                sourceTitle: nil,
                title: trimmed,
                notes: notes,
                startDateISO: startISO,
                endDateISO: endISO,
                startDisplay: CalendarEventDisplay.string(for: start, isoFallback: startISO, isAllDay: isAllDay),
                endDisplay: CalendarEventDisplay.string(for: end, isoFallback: endISO, isAllDay: isAllDay),
                isAllDay: isAllDay,
                location: location,
                hasRecurrence: false
            )
            s.items[id] = item
            return item
        }
    }

    func update(
        eventID: String,
        patch: CalendarUpdatePatch
    ) async throws -> CalendarEventItem {
        let title = patch.title
        let notes = patch.notes
        let start = patch.start
        let end = patch.end
        let calendarName = patch.calendarName
        let location = patch.location
        let trimmedID = eventID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { throw CalendarToolError.notFound(eventID) }
        if let title {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw CalendarToolError.emptyTitle }
            guard trimmed.count <= 300 else {
                throw CalendarToolError.invalidInput("Title must be 300 characters or fewer.")
            }
        }
        if let notes, notes.count > 8000 {
            throw CalendarToolError.invalidInput("Notes must be 8000 characters or fewer.")
        }
        return try state.withLock { s in
            guard var current = s.items[trimmedID] else { throw CalendarToolError.notFound(trimmedID) }
            if let title {
                current = CalendarEventItem(
                    id: current.id,
                    calendarName: current.calendarName,
                    sourceTitle: current.sourceTitle,
                    title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                    notes: current.notes,
                    startDateISO: current.startDateISO,
                    endDateISO: current.endDateISO,
                    startDisplay: current.startDisplay,
                    endDisplay: current.endDisplay,
                    isAllDay: current.isAllDay,
                    location: current.location,
                    hasRecurrence: current.hasRecurrence
                )
            }
            if notes != nil || start != nil || end != nil || calendarName != nil || location != nil {
                let nextStartISO = start.map {
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime]
                    return formatter.string(from: $0)
                } ?? current.startDateISO
                let nextEndISO = end.map {
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime]
                    return formatter.string(from: $0)
                } ?? current.endDateISO
                current = CalendarEventItem(
                    id: current.id,
                    calendarName: calendarName ?? current.calendarName,
                    sourceTitle: current.sourceTitle,
                    title: current.title,
                    notes: notes ?? current.notes,
                    startDateISO: nextStartISO,
                    endDateISO: nextEndISO,
                    startDisplay: start.map {
                        CalendarEventDisplay.string(for: $0, isoFallback: nextStartISO, isAllDay: current.isAllDay)
                    } ?? current.startDisplay,
                    endDisplay: end.map {
                        CalendarEventDisplay.string(for: $0, isoFallback: nextEndISO, isAllDay: current.isAllDay)
                    } ?? current.endDisplay,
                    isAllDay: current.isAllDay,
                    location: location ?? current.location,
                    hasRecurrence: current.hasRecurrence
                )
            }
            s.items[trimmedID] = current
            return current
        }
    }

    func delete(eventID: String, span _: CalendarSpan) async throws {
        let trimmed = eventID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CalendarToolError.notFound(eventID) }
        let removed: Bool = state.withLock { s in
            s.items.removeValue(forKey: trimmed) != nil
        }
        guard removed else { throw CalendarToolError.notFound(trimmed) }
    }
}

@Suite("Calendar Tools")
struct CalendarToolsTests {
    @Test
    func `Tool names and permission levels`() {
        let mock = MockCalendarGateway()
        let tools = CalendarTools.makeTools(gateway: mock)
        #expect(CalendarTools.toolNames == ["calendar.search", "calendar.create", "calendar.update", "calendar.delete"])
        #expect(tools.map(\.name) == CalendarTools.toolNames)
        #expect(tools.first { $0.name == "calendar.search" }?.permissionLevel == .readOnly)
        #expect(tools.first { $0.name == "calendar.create" }?.permissionLevel == .requiresApproval)
        #expect(tools.first { $0.name == "calendar.update" }?.permissionLevel == .requiresApproval)
        #expect(tools.first { $0.name == "calendar.delete" }?.permissionLevel == .requiresApproval)
        for tool in tools {
            #expect(tool.inputSchema.rawValue.contains("\"type\""))
            #expect(tool.inputSchema.rawValue.contains("\"additionalProperties\""))
        }
        let search = tools.first { $0.name == "calendar.search" }
        #expect(search?.description.contains("HTML-free") ?? false)
        #expect(search?.description.contains("Empty") ?? search?.description.contains("empty") ?? false)
    }

    @Test
    func `Search description directs display-first`() {
        let tool = CalendarSearchTool(gateway: MockCalendarGateway())
        #expect(tool.description.contains("startDisplay"))
        #expect(tool.description.contains("endDisplay"))
        #expect(tool.description.contains("startDateISO"))
        #expect(tool.description.contains("endDateISO"))
        #expect(tool.description.lowercased().contains("sorting only"))
    }

    @Test
    func `Search description names calendar.search decisive for entity-plus-time questions`() {
        let tool = CalendarSearchTool(gateway: MockCalendarGateway())
        #expect(
            tool.description.contains(
                "For entity-plus-time questions about schedule such as next sessions, "
                    + "calendar.search is decisive; do not keep searching after it answers."
            )
        )
    }

    @Test
    func `Search decodes defaults and clamps`() throws {
        let defaults = try JSONDecoder().decode(CalendarSearchArgs.self, from: Data("{}".utf8))
        #expect(defaults.limit == CalendarSearchArgs.defaultLimit)
        #expect(defaults.limit == 20)
        #expect(defaults.query == nil)
        #expect(defaults.eventID == nil)
        #expect(defaults.calendarNames == nil)
        #expect(defaults.since == nil)
        #expect(defaults.until == nil)
        let high = try JSONDecoder().decode(CalendarSearchArgs.self, from: Data(#"{"limit":100}"#.utf8))
        #expect(high.limit == 50)
        let low = try JSONDecoder().decode(CalendarSearchArgs.self, from: Data(#"{"limit":0}"#.utf8))
        #expect(low.limit == 1)
        let blanks = try JSONDecoder().decode(
            CalendarSearchArgs.self,
            from: Data(#"{"query":"   ","since":"   ","calendarNames":["  ","Home"]}"#.utf8)
        )
        #expect(blanks.query == nil)
        #expect(blanks.since == nil)
        #expect(blanks.calendarNames == ["Home"])
        let many = try JSONDecoder().decode(
            CalendarSearchArgs.self,
            from: Data(#"{"calendarNames":["a","b","c","d","e","f","g","h","i","j","k","l"]}"#.utf8)
        )
        #expect(many.calendarNames?.count == 10)
    }

    @Test
    func `Create rejects empty title and null bytes`() async throws {
        do {
            _ = try JSONDecoder().decode(CalendarCreateArgs.self, from: Data("{\"title\":\"a\\u0000b\"}".utf8))
            #expect(Bool(false), "Null bytes must throw at the decode boundary")
        } catch {
            #expect(Bool(true))
        }
        let mock = MockCalendarGateway()
        let tool = CalendarCreateTool(gateway: mock)
        let empty = try await tool.execute(
            input: ToolInput(toolName: "calendar.create", argumentsJSON: #"{"title":"   "}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(empty.isError)
        #expect(empty.content.lowercased().contains("empty") || empty.content.lowercased().contains("title"))
        let missing = try await tool.execute(
            input: ToolInput(toolName: "calendar.create", argumentsJSON: #"{}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(missing.isError)
    }

    @Test
    func `Update requires eventID`() async throws {
        let mock = MockCalendarGateway()
        let tool = CalendarUpdateTool(gateway: mock)
        let missing = try await tool.execute(
            input: ToolInput(toolName: "calendar.update", argumentsJSON: #"{"title":"New"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(missing.isError)
        #expect(missing.content.lowercased().contains("event"))
        let blank = try await tool.execute(
            input: ToolInput(toolName: "calendar.update", argumentsJSON: #"{"eventID":"   ","title":"New"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(blank.isError)
    }

    @Test
    func `Delete requires eventID`() async throws {
        let mock = MockCalendarGateway()
        let tool = CalendarDeleteTool(gateway: mock)
        let missing = try await tool.execute(
            input: ToolInput(toolName: "calendar.delete", argumentsJSON: #"{}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(missing.isError)
        #expect(missing.content.lowercased().contains("event"))
        let blank = try await tool.execute(
            input: ToolInput(toolName: "calendar.delete", argumentsJSON: #"{"eventID":"  "}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(blank.isError)
    }

    @Test
    func `Search round-trips through mock gateway`() async throws {
        let mock = MockCalendarGateway(items: [
            CalendarEventItem(
                id: "e1",
                calendarName: "Home",
                title: "Dentist appointment",
                notes: "teeth",
                startDisplay: "Mon, Sep 29, 2026 9:00 AM PDT",
                endDisplay: "Mon, Sep 29, 2026 10:00 AM PDT",
                isAllDay: false
            ),
            CalendarEventItem(
                id: "e2",
                calendarName: "Home",
                title: "Lunch with Sam",
                startDisplay: "Mon, Sep 29, 2026 12:00 PM PDT",
                endDisplay: "Mon, Sep 29, 2026 1:00 PM PDT",
                isAllDay: false
            )
        ])
        let tool = CalendarSearchTool(gateway: mock)
        let output = try await tool.execute(
            input: ToolInput(toolName: "calendar.search", argumentsJSON: #"{"query":"dentist"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(!output.isError)
        let envelope = try JSONDecoder().decode(CalendarSearchEnvelope.self, from: Data(output.content.utf8))
        #expect(envelope.count == 1)
        #expect(envelope.events.first?.title == "Dentist appointment")
        let emptyQuery = try await tool.execute(
            input: ToolInput(toolName: "calendar.search", argumentsJSON: #"{}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(!emptyQuery.isError)
        let listed = try JSONDecoder().decode(CalendarSearchEnvelope.self, from: Data(emptyQuery.content.utf8))
        #expect(listed.count == 2)
    }

    @Test
    func `Create round-trips through mock gateway`() async throws {
        let mock = MockCalendarGateway()
        let tool = CalendarCreateTool(gateway: mock)
        let output = try await tool.execute(
            input: ToolInput(toolName: "calendar.create", argumentsJSON: #"{"title":"Team sync","notes":"weekly"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(!output.isError)
        let item = try JSONDecoder().decode(CalendarEventItem.self, from: Data(output.content.utf8))
        #expect(item.title == "Team sync")
        #expect(!item.id.isEmpty)
    }

    @Test
    func `Update round-trips through mock gateway`() async throws {
        let mock = MockCalendarGateway()
        let create = CalendarCreateTool(gateway: mock)
        let createdOutput = try await create.execute(
            input: ToolInput(toolName: "calendar.create", argumentsJSON: #"{"title":"Standup"}"#),
            context: ToolContext(conversationID: UUID())
        )
        let created = try JSONDecoder().decode(CalendarEventItem.self, from: Data(createdOutput.content.utf8))
        let update = CalendarUpdateTool(gateway: mock)
        let updatedOutput = try await update.execute(
            input: ToolInput(
                toolName: "calendar.update",
                argumentsJSON: "{\"eventID\":\"\(created.id)\",\"title\":\"Standup renamed\"}"
            ),
            context: ToolContext(conversationID: UUID())
        )
        #expect(!updatedOutput.isError)
        let updated = try JSONDecoder().decode(CalendarEventItem.self, from: Data(updatedOutput.content.utf8))
        #expect(updated.title == "Standup renamed")
        let miss = try await update.execute(
            input: ToolInput(toolName: "calendar.update", argumentsJSON: #"{"eventID":"missing-123","title":"X"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(miss.isError)
        #expect(miss.content.contains("missing-123"))
    }

    @Test
    func `Delete round-trips through mock gateway`() async throws {
        let mock = MockCalendarGateway()
        let create = CalendarCreateTool(gateway: mock)
        let createdOutput = try await create.execute(
            input: ToolInput(toolName: "calendar.create", argumentsJSON: #"{"title":"Temp event"}"#),
            context: ToolContext(conversationID: UUID())
        )
        let created = try JSONDecoder().decode(CalendarEventItem.self, from: Data(createdOutput.content.utf8))
        let search = CalendarSearchTool(gateway: mock)
        let found = try await search.execute(
            input: ToolInput(toolName: "calendar.search", argumentsJSON: #"{"query":"Temp"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(found.content.contains("Temp event"))
        let delete = CalendarDeleteTool(gateway: mock)
        let deleted = try await delete.execute(
            input: ToolInput(toolName: "calendar.delete", argumentsJSON: "{\"eventID\":\"\(created.id)\"}"),
            context: ToolContext(conversationID: UUID())
        )
        #expect(!deleted.isError)
        let gone = try await search.execute(
            input: ToolInput(toolName: "calendar.search", argumentsJSON: #"{"query":"Temp"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(!gone.content.contains("Temp event"))
        let miss = try await delete.execute(
            input: ToolInput(toolName: "calendar.delete", argumentsJSON: #"{"eventID":"missing-456"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(miss.isError)
        #expect(miss.content.contains("missing-456"))
    }

    @Test
    func `Calendar tools round-trip through ToolBus`() async {
        let mock = MockCalendarGateway(items: [
            CalendarEventItem(
                id: "bus-1",
                calendarName: "Work",
                title: "Planning review",
                startDisplay: "Mon, Sep 29, 2026 2:00 PM PDT",
                endDisplay: "Mon, Sep 29, 2026 3:00 PM PDT",
                isAllDay: false
            )
        ])
        let bus = ToolBus()
        await CalendarTools.register(on: bus, gateway: mock)
        let names = await bus.toolNames()
        #expect(Set(names).isSuperset(of: Set(CalendarTools.toolNames)))
        for name in CalendarTools.toolNames {
            #expect(await bus.isToolEnabled(named: name))
        }
        let result = await bus.execute(
            toolCall: ToolInput(toolName: "calendar.search", argumentsJSON: #"{"query":"Planning"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(!result.isError)
        #expect(result.content.contains("Planning review"))
    }
}

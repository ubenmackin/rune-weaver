// Rune Weaver Tools Tests — Reminders user-facing tool tests.
//
// Purpose: pin reminders tool names, levels, arg validation, and gateway delegation.
// Scope: hermetic mock gateway only; no live EventKit access.
// Architectural role: guards the ToolBus surface while gateway tests own persistence.

import Foundation
import os
@testable import RuneWeaverCore
@testable import RuneWeaverTools
import Testing

final class StubRemindersGateway: RemindersGateway, Sendable {
    private struct State: Sendable {
        var items: [String: ReminderItem] = [:]
        var nextID: Int = 1
        var lastCompleted: Bool?
        var didSeeCompleted: Bool = false
    }

    private let state: OSAllocatedUnfairLock<State>

    init(items: [ReminderItem] = []) {
        var initial = State()
        for item in items {
            initial.items[item.id] = item
        }
        self.state = OSAllocatedUnfairLock(initialState: initial)
    }

    var lastCompleted: Bool? {
        state.withLock { $0.lastCompleted }
    }

    var didSeeCompleted: Bool {
        state.withLock { $0.didSeeCompleted }
    }

    func search(
        query: String?,
        listNames: [String]?,
        includeCompleted: Bool,
        since _: Date?,
        until _: Date?,
        limit: Int
    ) async throws -> [ReminderItem] {
        let all = state.withLock { Array($0.items.values) }
        var filtered = includeCompleted ? all : all.filter { !$0.isCompleted }
        if let listNames, !listNames.isEmpty {
            let lowered = Set(listNames.map { $0.lowercased() })
            filtered = filtered.filter { lowered.contains($0.listName.lowercased()) }
        }
        if let query {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed != "*" {
                filtered = filtered.filter {
                    $0.title.localizedCaseInsensitiveContains(trimmed)
                        || ($0.notes?.localizedCaseInsensitiveContains(trimmed) ?? false)
                }
            }
        }
        let capped = min(max(limit, 1), 50)
        return Array(filtered.prefix(capped))
    }

    func create(
        title: String,
        notes: String?,
        due: Date?,
        listName: String?,
        priority: Int?
    ) async throws -> ReminderItem {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ReminderToolError.emptyTitle }
        let id = state.withLock { s -> String in
            let next = "stub-\(s.nextID)"
            s.nextID += 1
            return next
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let item = ReminderItem(
            id: id,
            listName: listName ?? "Personal",
            sourceTitle: "Local",
            title: trimmed,
            notes: notes,
            dueDateISO: due.map { formatter.string(from: $0) },
            isCompleted: false,
            priority: priority ?? 0,
            creationDateISO: nil
        )
        state.withLock { $0.items[id] = item }
        return item
    }

    func update(
        reminderID: String,
        patch: ReminderUpdatePatch
    ) async throws -> ReminderItem {
        guard let existing = state.withLock({ $0.items[reminderID] }) else {
            throw ReminderToolError.notFound(reminderID)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let updated = ReminderItem(
            id: existing.id,
            listName: patch.listName ?? existing.listName,
            sourceTitle: existing.sourceTitle,
            title: patch.title ?? existing.title,
            notes: patch.notes ?? existing.notes,
            dueDateISO: patch.due.map { formatter.string(from: $0) } ?? existing.dueDateISO,
            isCompleted: patch.completed ?? existing.isCompleted,
            priority: patch.priority ?? existing.priority,
            creationDateISO: existing.creationDateISO
        )
        state.withLock { s in
            s.items[reminderID] = updated
            if let completed = patch.completed {
                s.lastCompleted = completed
                s.didSeeCompleted = true
            }
        }
        return updated
    }

    func delete(reminderID: String) async throws {
        let removed = state.withLock { $0.items.removeValue(forKey: reminderID) }
        guard removed != nil else {
            throw ReminderToolError.notFound(reminderID)
        }
    }
}

struct FailingRemindersGateway: RemindersGateway, Sendable {
    let error: ReminderToolError

    func search(
        query _: String?,
        listNames _: [String]?,
        includeCompleted _: Bool,
        since _: Date?,
        until _: Date?,
        limit _: Int
    ) async throws -> [ReminderItem] {
        throw error
    }

    func create(
        title _: String,
        notes _: String?,
        due _: Date?,
        listName _: String?,
        priority _: Int?
    ) async throws -> ReminderItem {
        throw error
    }

    func update(
        reminderID _: String,
        patch _: ReminderUpdatePatch
    ) async throws -> ReminderItem {
        throw error
    }

    func delete(reminderID _: String) async throws {
        throw error
    }
}

@Suite("Reminders Tools")
struct RemindersToolsTests {
    @Test
    func `Schema names and permission levels`() {
        #expect(RemindersTools.toolNames == ["reminders.search", "reminders.create", "reminders.update", "reminders.delete"])
        let tools = RemindersTools.makeTools(gateway: StubRemindersGateway())
        #expect(tools.count == 4)
        #expect(tools.map(\.name) == RemindersTools.toolNames)
        let byName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        #expect(byName["reminders.search"]?.permissionLevel == .readOnly)
        #expect(byName["reminders.create"]?.permissionLevel == .requiresApproval)
        #expect(byName["reminders.update"]?.permissionLevel == .requiresApproval)
        #expect(byName["reminders.delete"]?.permissionLevel == .requiresApproval)
    }

    @Test
    func `Search description names reminders.search decisive for entity-plus-time questions`() {
        let tool = RemindersSearchTool(gateway: StubRemindersGateway())
        #expect(
            tool.description.contains(
                "For entity-plus-time questions about due items such as upcoming deadlines, "
                    + "reminders.search is decisive; do not keep searching after it answers."
            )
        )
    }

    @Test
    func `Search decodes defaults and clamps`() throws {
        let defaults = try JSONDecoder().decode(RemindersSearchArgs.self, from: Data("{}".utf8))
        #expect(defaults.query == nil)
        #expect(defaults.listNames == nil)
        #expect(defaults.includeCompleted == false)
        #expect(defaults.since == nil)
        #expect(defaults.until == nil)
        #expect(defaults.limit == 20)
        let floored = try JSONDecoder().decode(RemindersSearchArgs.self, from: Data(#"{"limit":0}"#.utf8))
        #expect(floored.limit == 1)
        let capped = try JSONDecoder().decode(RemindersSearchArgs.self, from: Data(#"{"limit":500}"#.utf8))
        #expect(capped.limit == 50)
        let blanked = try JSONDecoder().decode(
            RemindersSearchArgs.self,
            from: Data(#"{"query":"   ","since":"  ","until":""}"#.utf8)
        )
        #expect(blanked.query == nil)
        #expect(blanked.since == nil)
        #expect(blanked.until == nil)
        let many = Array(repeating: "L", count: 12)
        let manyData = try JSONEncoder().encode(["listNames": many])
        let trimmedLists = try JSONDecoder().decode(RemindersSearchArgs.self, from: manyData)
        #expect(trimmedLists.listNames?.count == 10)
    }

    @Test
    func `Create rejects empty title and null bytes`() async throws {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RemindersCreateArgs.self, from: Data("{\"title\":\"a\\u0000b\"}".utf8))
        }
        let tool = RemindersCreateTool(gateway: StubRemindersGateway())
        let empty = try await tool.execute(
            input: ToolInput(toolName: "reminders.create", argumentsJSON: #"{"title":"   "}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(empty.isError == true)
        #expect(empty.content.lowercased().contains("title"))
        let nullArg = try await tool.execute(
            input: ToolInput(toolName: "reminders.create", argumentsJSON: "{\"title\":\"a\\u0000b\"}"),
            context: ToolContext(conversationID: UUID())
        )
        #expect(nullArg.isError == true)
    }

    @Test
    func `Update requires reminderID and passes completed through`() async throws {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RemindersUpdateArgs.self, from: Data(#"{"title":"New"}"#.utf8))
        }
        let gateway = StubRemindersGateway()
        let created = try await gateway.create(title: "Water plants", notes: nil, due: nil, listName: nil, priority: nil)
        let tool = RemindersUpdateTool(gateway: gateway)
        let missing = try await tool.execute(
            input: ToolInput(toolName: "reminders.update", argumentsJSON: #"{"title":"New"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(missing.isError == true)
        let output = try await tool.execute(
            input: ToolInput(
                toolName: "reminders.update",
                argumentsJSON: #"{"reminderID":"\#(created.id)","completed":true}"#
            ),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == false)
        let item = try JSONDecoder().decode(ReminderItem.self, from: Data(output.content.utf8))
        #expect(item.isCompleted == true)
        #expect(gateway.didSeeCompleted == true)
        #expect(gateway.lastCompleted == true)
    }

    @Test
    func `Delete requires reminderID`() async throws {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RemindersDeleteArgs.self, from: Data("{}".utf8))
        }
        let tool = RemindersDeleteTool(gateway: StubRemindersGateway())
        let missing = try await tool.execute(
            input: ToolInput(toolName: "reminders.delete", argumentsJSON: "{}"),
            context: ToolContext(conversationID: UUID())
        )
        #expect(missing.isError == true)
    }

    @Test
    func `Search round-trip through mock gateway`() async throws {
        let gateway = StubRemindersGateway(items: [
            ReminderItem(id: "r-1", listName: "Personal", sourceTitle: "Local", title: "Buy oat milk", isCompleted: false),
            ReminderItem(id: "r-2", listName: "Work", sourceTitle: "Local", title: "File taxes", isCompleted: false)
        ])
        let tool = RemindersSearchTool(gateway: gateway)
        let output = try await tool.execute(
            input: ToolInput(toolName: "reminders.search", argumentsJSON: #"{"query":"oat"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == false)
        let envelope = try JSONDecoder().decode(RemindersSearchEnvelope.self, from: Data(output.content.utf8))
        #expect(envelope.count == 1)
        #expect(envelope.reminders.first?.id == "r-1")
    }

    @Test
    func `Create round-trip through mock gateway`() async throws {
        let tool = RemindersCreateTool(gateway: StubRemindersGateway())
        let output = try await tool.execute(
            input: ToolInput(toolName: "reminders.create", argumentsJSON: #"{"title":"File taxes","listName":"Work"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == false)
        let item = try JSONDecoder().decode(ReminderItem.self, from: Data(output.content.utf8))
        #expect(item.title == "File taxes")
        #expect(item.listName == "Work")
    }

    @Test
    func `Update round-trip through mock gateway`() async throws {
        let gateway = StubRemindersGateway()
        let created = try await gateway.create(title: "Draft", notes: nil, due: nil, listName: nil, priority: nil)
        let tool = RemindersUpdateTool(gateway: gateway)
        let output = try await tool.execute(
            input: ToolInput(
                toolName: "reminders.update",
                argumentsJSON: #"{"reminderID":"\#(created.id)","title":"Renamed"}"#
            ),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == false)
        let item = try JSONDecoder().decode(ReminderItem.self, from: Data(output.content.utf8))
        #expect(item.title == "Renamed")
    }

    @Test
    func `Delete round-trip through mock gateway`() async throws {
        let gateway = StubRemindersGateway()
        let created = try await gateway.create(title: "Temporary", notes: nil, due: nil, listName: nil, priority: nil)
        let tool = RemindersDeleteTool(gateway: gateway)
        let output = try await tool.execute(
            input: ToolInput(toolName: "reminders.delete", argumentsJSON: #"{"reminderID":"\#(created.id)"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == false)
        let envelope = try JSONDecoder().decode(RemindersDeleteEnvelope.self, from: Data(output.content.utf8))
        #expect(envelope.success == true)
        #expect(envelope.reminderID == created.id)
    }

    @Test
    func `Gateway errors surface verbatim`() async throws {
        let missing = "missing-id-verb"
        let gateway = FailingRemindersGateway(error: .notFound(missing))
        let search = RemindersSearchTool(gateway: gateway)
        let searchOut = try await search.execute(
            input: ToolInput(toolName: "reminders.search", argumentsJSON: "{}"),
            context: ToolContext(conversationID: UUID())
        )
        #expect(searchOut.isError == true)
        #expect(searchOut.content.contains(missing))
        let update = RemindersUpdateTool(gateway: gateway)
        let updateOut = try await update.execute(
            input: ToolInput(toolName: "reminders.update", argumentsJSON: #"{"reminderID":"\#(missing)"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(updateOut.isError == true)
        #expect(updateOut.content.contains(missing))
        #expect(updateOut.content == ReminderToolError.notFound(missing).localizedDescription)
    }

    @Test
    func `Invalid temporal bounds fail closed`() async throws {
        let tool = RemindersSearchTool(gateway: StubRemindersGateway())
        let output = try await tool.execute(
            input: ToolInput(toolName: "reminders.search", argumentsJSON: #"{"since":"not-a-date"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == true)
    }

    @Test
    func `Bus exposes reminders tools`() async {
        let gateway = StubRemindersGateway(items: [
            ReminderItem(id: "r-bus", listName: "Personal", sourceTitle: "Local", title: "Bus check", isCompleted: false)
        ])
        let bus = ToolBus()
        await RemindersTools.register(on: bus, gateway: gateway)
        let names = await bus.toolNames()
        #expect(Set(names).isSuperset(of: Set(RemindersTools.toolNames)))
        let searched = await bus.execute(
            toolCall: ToolInput(toolName: "reminders.search", argumentsJSON: #"{"query":"Bus"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(searched.isError == false)
        #expect(searched.content.contains("Bus check"))
    }
}

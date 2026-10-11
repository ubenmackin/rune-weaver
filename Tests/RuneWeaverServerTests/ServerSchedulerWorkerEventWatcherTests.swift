// Rune Weaver Tests — ServerSchedulerWorker Event Watcher multi-source and rule execution tests.
//
// Purpose: pins ordered event-rule evaluation across email, messages, and calendar watchers,
// including the zero-token direct-tool fast path, scoped agent turns, stopProcessing ordering,
// and poll dedupe that prevents duplicate fires.
// Scope: hermetic worker harness with stub ToolBus tools, stub LLM, and isolated temporary
// episodes.db only; no live mail, Messages, calendar, or network access.
// Architectural role: guards the watcher polling engine while validation tests own the
// allowlist and interval bounds, so a polling regression surfaces here instead of in production.

import Foundation
@testable import RuneWeaverCore
@testable import RuneWeaverServer
import Testing

private actor SafeBox<T> {
    var value: T
    init(_ value: T) {
        self.value = value
    }

    func append(_ element: T.Element) where T: RangeReplaceableCollection {
        value.append(element)
    }

    func set(_ value: T) {
        self.value = value
    }

    func get() -> T {
        value
    }
}

private final class EventWatcherStubLLM: LLMProvider, Sendable {
    let modelInfo = ModelInfo(name: "stub", provider: "stub", contextLength: 8192)
    private let responseGenerator: @Sendable (String) async -> String

    init(responseGenerator: @escaping @Sendable (String) async -> String = { _ in "task done" }) {
        self.responseGenerator = responseGenerator
    }

    func chat(messages: [Message], tools _: [any Tool]) -> AsyncStream<LLMResponse> {
        let lastUserMessage = messages.last(where: { $0.role == .user })?.content ?? ""
        let generator = responseGenerator
        return AsyncStream { continuation in
            Task {
                let answer = await generator(lastUserMessage)
                continuation.yield(LLMResponse(delta: answer))
                continuation.yield(LLMResponse(delta: "", isFinished: true, totalTokens: 10))
                continuation.finish()
            }
        }
    }

    func embeddings(text: [String]) async throws -> [[Float]] {
        Array(repeating: [Float](), count: text.count)
    }
}

private struct CustomStubTool: Tool, Sendable {
    let name: String
    let description: String
    let permissionLevel = PermissionLevel.readOnly
    let inputSchema = JSONSchema(rawValue: #"{"type":"object"}"#)
    let handler: @Sendable (ToolInput) async -> ToolOutput

    init(name: String, description: String = "Stub", handler: @escaping @Sendable (ToolInput) async -> ToolOutput) {
        self.name = name
        self.description = description
        self.handler = handler
    }

    func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        await handler(input)
    }
}

@Suite("Event Watcher Worker Execution")
struct ServerSchedulerWorkerEventWatcherTests {
    struct WorkerHarness {
        let worker: ServerSchedulerWorker
        let scheduler: SchedulerStore
        let runs: RunLogStore
        let tempDir: URL
    }

    private func makeWorker(
        toolBus: ToolBus,
        llm: (any LLMProvider)? = nil
    ) async throws -> WorkerHarness {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("event_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbPath = tempDir.appendingPathComponent("episodes.db").path
        let memoryEngine = MemoryEngine(
            episodesDBPath: dbPath,
            vectorDBPath: tempDir.appendingPathComponent("vectors").path,
            profilePath: tempDir.appendingPathComponent("profile.json").path
        )
        let conversations = ConversationManager(episodesDBPath: dbPath)
        let orchestrator = Orchestrator(
            conversations: conversations,
            toolBus: toolBus,
            llm: llm ?? EventWatcherStubLLM(),
            memoryEngine: memoryEngine
        )
        let scheduler = await SchedulerStore.load(dbPath: dbPath)
        let runs = await RunLogStore.load(dbPath: dbPath)
        let hub = WSHub()
        let runLock = SchedulerRunLock()

        let worker = ServerSchedulerWorker(
            scheduler: scheduler,
            runs: runs,
            hub: hub,
            runLock: runLock,
            orchestrator: orchestrator,
            conversations: conversations,
            toolBus: toolBus,
            intervalSeconds: 1
        )
        return WorkerHarness(worker: worker, scheduler: scheduler, runs: runs, tempDir: tempDir)
    }

    @Test
    func `Email watcher evaluates multi-rules with direct tool and agent action`() async throws {
        let toolBus = ToolBus()

        // 1. Stub email.search tool
        let rawEmailJSON = """
        {"messages":[{"id":"email-0","subject":"Welcome","from":"hello@site.com","snippet":"Welcome to site","mailbox":"INBOX","date":"2026-10-10"}]}
        """
        let emailDataBox = SafeBox<String>(rawEmailJSON)
        let emailSearchTool = CustomStubTool(name: "email.search") { _ in
            let json = await emailDataBox.get()
            return .success(json)
        }
        await toolBus.register(tool: emailSearchTool)

        // 2. Stub email.move direct tool
        let movedBox = SafeBox<[String]>([])
        let emailMoveTool = CustomStubTool(name: "email.move") { input in
            await movedBox.append(input.argumentsJSON)
            return .success(#"{"success":true}"#)
        }
        await toolBus.register(tool: emailMoveTool)

        let receivedPrompts = SafeBox<[String]>([])
        let llm = EventWatcherStubLLM { prompt in
            await receivedPrompts.append(prompt)
            return "Analyzed email"
        }

        let harness = try await makeWorker(toolBus: toolBus, llm: llm)
        let worker = harness.worker
        let scheduler = harness.scheduler
        let runs = harness.runs
        let tempDir = harness.tempDir
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Configure rules
        let ruleReceipt = EventRule(
            name: "Receipt Filer",
            condition: EventRuleCondition(subjectContains: ["Receipt"]),
            action: .directTool(toolName: "email.move", argumentsJSON: #"{"destination":"Receipts"}"#),
            stopProcessing: true
        )
        let ruleUrgent = EventRule(
            name: "Urgent Assistant",
            condition: EventRuleCondition(subjectContains: ["Urgent"]),
            action: .agentPrompt(prompt: "Handle urgent request"),
            stopProcessing: true
        )

        let job = try await scheduler.create(NewSchedulerJob(
            name: "Smart Email Watcher",
            schedule: "",
            prompt: "",
            pollAccount: "personal",
            pollIntervalSeconds: 60,
            watcherSource: EventWatcherSource.email,
            rules: [ruleReceipt, ruleUrgent]
        ))
        #expect(job.watcherSource == EventWatcherSource.email)

        // First tick: establishes baseline (email-0 seen, does not fire)
        let baselineResults = await worker.tick(now: Date())
        #expect(baselineResults.isEmpty)

        // Now new emails arrive
        await emailDataBox.set("""
        {
          "messages": [
            {"id":"email-0","subject":"Welcome","from":"hello@site.com","snippet":"Welcome to site","mailbox":"INBOX","date":"2026-10-10"},
            {"id":"email-1","subject":"Store Receipt","from":"store@retail.com","snippet":"Thank you for shopping","mailbox":"INBOX","date":"2026-10-10"},
            {"id":"email-2","subject":"Urgent issue","from":"lead@work.com","snippet":"Server down","mailbox":"INBOX","date":"2026-10-10"}
          ]
        }
        """)

        let tickResults = await worker.tick(now: Date().addingTimeInterval(65))
        #expect(tickResults.count == 2)

        // Verify Direct Tool was called with injected event id
        let moves = await movedBox.get()
        #expect(moves.count == 1)
        #expect(moves.first?.contains("email-1") == true)
        #expect(moves.first?.contains("Receipts") == true)

        // Verify Agent Prompt was called with injected context
        let prompts = await receivedPrompts.get()
        #expect(prompts.count == 1)
        #expect(prompts.first?.contains("[Event Trigger: Email Arrival]") == true)
        #expect(prompts.first?.contains("lead@work.com") == true)
        #expect(prompts.first?.contains("Handle urgent request") == true)

        // Verify RunLog recorded direct tool with 0 tokens
        let loggedRuns = await runs.list(limit: 10)
        let directRun = loggedRuns.first { $0.message.contains("Direct action: email.move") }
        #expect(directRun != nil)
        #expect(directRun?.totalTokens == 0)
        #expect(directRun?.status == "ok")
    }

    @Test
    func `Messages watcher matches direct chat vs group chat rules`() async throws {
        let toolBus = ToolBus()

        let messagesDataBox = SafeBox<String>(#"{"messages":[{"id":"msg-0","text":"initial","isFromMe":true}]}"#)
        let messagesSearchTool = CustomStubTool(name: "messages.search") { _ in
            let json = await messagesDataBox.get()
            return .success(json)
        }
        await toolBus.register(tool: messagesSearchTool)

        let receivedPrompts = SafeBox<[String]>([])
        let llm = EventWatcherStubLLM { prompt in
            await receivedPrompts.append(prompt)
            return "Handled message"
        }

        let harness = try await makeWorker(toolBus: toolBus, llm: llm)
        let worker = harness.worker
        let scheduler = harness.scheduler
        let tempDir = harness.tempDir
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let directRule = EventRule(
            name: "Family Direct",
            condition: EventRuleCondition(senderContains: ["Mom"], groupChatFilter: .directOnly),
            action: .agentPrompt(prompt: "Draft reply to Mom"),
            stopProcessing: true
        )
        let groupRule = EventRule(
            name: "Project Group Alert",
            condition: EventRuleCondition(contentContains: ["deadline"], groupChatFilter: .groupOnly),
            action: .agentPrompt(prompt: "Track deadline in notes"),
            stopProcessing: true
        )

        _ = try await scheduler.create(NewSchedulerJob(
            name: "Messages Dispatcher",
            schedule: "",
            prompt: "",
            pollIntervalSeconds: 60,
            watcherSource: EventWatcherSource.messages,
            rules: [directRule, groupRule]
        ))

        // First tick baselines
        _ = await worker.tick(now: Date())

        // New messages arrive:
        // 1. Direct message from Mom
        // 2. Group message from Mom in family group (should NOT match directRule!)
        // 3. Group chat message with 'deadline' (should match groupRule!)
        await messagesDataBox.set("""
        {
          "messages": [
            {"id":"msg-0","text":"initial","isFromMe":true},
            {"id":"msg-1","text":"Are you coming to dinner?","sender":"Mom","chatId":"direct-mom","isFromMe":false},
            {"id":"msg-2","text":"Family picnic update","sender":"Mom","chatId":"chat1001","chatDisplayName":"Family Group","isFromMe":false},
            {"id":"msg-3","text":"New deadline is Friday","sender":"Bob","chatId":"chat2002","chatDisplayName":"Dev Team","isFromMe":false}
          ]
        }
        """)

        let results = await worker.tick(now: Date().addingTimeInterval(65))
        #expect(results.count == 2)

        let prompts = await receivedPrompts.get()
        #expect(prompts.count == 2)
        #expect(prompts.contains { $0.contains("Draft reply to Mom") && $0.contains("Are you coming to dinner?") })
        #expect(prompts.contains { $0.contains("Track deadline in notes") && $0.contains("Dev Team") })
    }

    @Test
    func `Calendar watcher triggers meeting prep and avoids duplicate fires`() async throws {
        let toolBus = ToolBus()

        let calendarEventsJSON = """
        {
          "events": [
            {
              "id": "event-1",
              "title": "1:1 with Manager",
              "calendarName": "Work",
              "startDateISO": "2026-10-10T15:00:00Z",
              "startDisplay": "3:00 PM",
              "location": "Zoom",
              "notes": "Agenda: promotion discussion",
              "isAllDay": false
            }
          ]
        }
        """
        let calendarSearchTool = CustomStubTool(name: "calendar.search") { _ in
            .success(calendarEventsJSON)
        }
        await toolBus.register(tool: calendarSearchTool)

        let receivedPrompts = SafeBox<[String]>([])
        let llm = EventWatcherStubLLM { prompt in
            await receivedPrompts.append(prompt)
            return "Prepared meeting brief"
        }

        let harness = try await makeWorker(toolBus: toolBus, llm: llm)
        let worker = harness.worker
        let scheduler = harness.scheduler
        let tempDir = harness.tempDir
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let prepRule = EventRule(
            name: "Pre-Meeting Prep",
            condition: EventRuleCondition(titleContains: ["1:1"], excludeAllDay: true),
            action: .agentPrompt(prompt: "Generate prep brief for 1:1"),
            stopProcessing: true
        )

        _ = try await scheduler.create(NewSchedulerJob(
            name: "Calendar Watcher",
            schedule: "",
            prompt: "",
            pollIntervalSeconds: 60,
            watcherSource: EventWatcherSource.calendar,
            rules: [prepRule],
            calendarLeadTimeMinutes: 15
        ))

        // Tick 1: detects upcoming event and runs rule
        let results1 = await worker.tick(now: Date())
        #expect(results1.count == 1)

        let prompts = await receivedPrompts.get()
        #expect(prompts.count == 1)
        #expect(prompts.first?.contains("[Event Trigger: Upcoming Calendar Event]") == true)
        #expect(prompts.first?.contains("1:1 with Manager") == true)
        #expect(prompts.first?.contains("Agenda: promotion discussion") == true)

        // Tick 2: same event is still in window, but should NOT fire again (deduplicated by instance key)
        let results2 = await worker.tick(now: Date().addingTimeInterval(65))
        #expect(results2.isEmpty)
        let finalPrompts = await receivedPrompts.get()
        #expect(finalPrompts.count == 1)
    }
}

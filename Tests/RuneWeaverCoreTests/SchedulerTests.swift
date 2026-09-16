// Rune Weaver Tests — Scheduler engine, cron parsing, and poll rule tests.

import Foundation
@testable import RuneWeaverCore
import Testing

/// Captures scheduler log lines for assertions.
private actor TestLog {
    /// Captured lines in order.
    private var lines: [String] = []

    /// Appends a line.
    /// - Parameter message: Log line.
    func append(_ message: String) {
        lines.append(message)
    }

    /// All captured lines.
    /// - Returns: Lines in order.
    func all() -> [String] {
        lines
    }

    /// Log handler writing into this recorder.
    /// - Returns: Handler for engine wiring.
    func handler() -> SchedulerLogHandler {
        { [recorder = self] message in
            await recorder.append(message)
        }
    }
}

/// Counts headless turn invocations without data races.
private actor TurnCounter {
    /// Number of recorded calls.
    private var calls = 0

    /// Records one call.
    func record() {
        calls += 1
    }

    /// Number of recorded calls.
    /// - Returns: Call count.
    func count() -> Int {
        calls
    }
}

/// Serves canned poll batches in order without data races.
private actor BatchProvider {
    /// Remaining batches.
    private var batches: [[String]]

    /// Creates a provider.
    /// - Parameter batches: Batches served in order.
    init(batches: [[String]]) {
        self.batches = batches
    }

    /// Pops the next batch, or empty when exhausted.
    /// - Returns: Next batch.
    func next() -> [String] {
        guard !batches.isEmpty else { return [] }
        return batches.removeFirst()
    }
}

/// Read-only stub for headless approval tests.
private struct SchedulerReadStub: Tool, Sendable {
    /// Stable stub name.
    let name = "stub.read"
    /// Human-readable description.
    let description = "Read-only stub."
    /// Empty-object schema.
    let inputSchema = JSONSchema(rawValue: #"{"type":"object"}"#)
    /// Always allowed.
    let permissionLevel = PermissionLevel.readOnly

    /// Returns a canned success.
    func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        .success("read-ok", callID: input.callID)
    }
}

/// Approval-gated stub for headless approval tests.
private struct SchedulerWriteStub: Tool, Sendable {
    /// Stable stub name.
    let name = "stub.write"
    /// Human-readable description.
    let description = "Approval-gated stub."
    /// Empty-object schema.
    let inputSchema = JSONSchema(rawValue: #"{"type":"object"}"#)
    /// Requires approval.
    let permissionLevel = PermissionLevel.requiresApproval

    /// Returns a canned success when approved.
    func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        .success("write-ok", callID: input.callID)
    }
}

/// UTC Gregorian calendar for deterministic fire calculations.
/// - Returns: Fixed calendar.
private func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
    return calendar
}

/// Builds a UTC date from components.
private func utcDate(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    components.second = 0
    components.nanosecond = 0
    return utcCalendar().date(from: components) ?? Date()
}

@Suite("Cron Parsing")
struct CronParsingTests {
    @Test
    func `Five-field daily parses and matches`() throws {
        let schedule = try CronSchedule.parse("0 8 * * *")
        #expect(schedule.minutes == [0])
        #expect(schedule.hours == [8])
        #expect(CronSchedule.isValid("0 8 * * *") == true)
        #expect(schedule.matches(utcDate(year: 2026, month: 3, day: 4, hour: 8, minute: 0), calendar: utcCalendar()) == true)
        #expect(schedule.matches(utcDate(year: 2026, month: 3, day: 4, hour: 9, minute: 0), calendar: utcCalendar()) == false)
    }

    @Test
    func `Shortcuts expand`() throws {
        #expect(try CronSchedule.parse("@hourly").minutes == [0])
        #expect(try CronSchedule.parse("@daily").hours == [0])
        #expect(try CronSchedule.parse("@weekly").weekdays == [0])
        #expect(try CronSchedule.parse("@monthly").days == [1])
        #expect(try CronSchedule.parse("@yearly").months == [1])
        #expect(CronSchedule.isValid("@daily") == true)
    }

    @Test
    func `Lists ranges and steps parse`() throws {
        let schedule = try CronSchedule.parse("0,15,30,45 * * * *")
        #expect(schedule.minutes == [0, 15, 30, 45])
        let stepped = try CronSchedule.parse("*/15 * * * *")
        #expect(stepped.minutes == [0, 15, 30, 45])
        let ranged = try CronSchedule.parse("9-17 * * * *")
        #expect(ranged.minutes == Set(9 ... 17))
        let rangeStepped = try CronSchedule.parse("0 9-17/2 * * *")
        #expect(rangeStepped.hours == [9, 11, 13, 15, 17])
    }

    @Test
    func `Weekday seven folds to Sunday`() throws {
        let schedule = try CronSchedule.parse("0 0 * * 7")
        #expect(schedule.weekdays == [0])
        #expect(schedule.matches(utcDate(year: 2026, month: 3, day: 1, hour: 0, minute: 0), calendar: utcCalendar()) == true)
    }

    @Test
    func `Malformed expressions throw`() {
        #expect(CronSchedule.isValid("") == false)
        #expect(CronSchedule.isValid("0 8 * *") == false)
        #expect(CronSchedule.isValid("0 8 * * * *") == false)
        #expect(CronSchedule.isValid("@fortnightly") == false)
        #expect(CronSchedule.isValid("61 * * * *") == false)
        #expect(CronSchedule.isValid("0 24 * * *") == false)
        #expect(CronSchedule.isValid("0 0 0 * *") == false)
        #expect(CronSchedule.isValid("0 0 * 13 *") == false)
    }
}

@Suite("Cron Next Fire")
struct CronNextFireTests {
    @Test
    func `Daily fires same day before time and next day after`() throws {
        let schedule = try CronSchedule.parse("0 8 * * *")
        let calendar = utcCalendar()
        let before = utcDate(year: 2026, month: 3, day: 4, hour: 7, minute: 30)
        let expectedSame = utcDate(year: 2026, month: 3, day: 4, hour: 8, minute: 0)
        #expect(schedule.nextFire(after: before, calendar: calendar) == expectedSame)
        let after = utcDate(year: 2026, month: 3, day: 4, hour: 9, minute: 0)
        let expectedNext = utcDate(year: 2026, month: 3, day: 5, hour: 8, minute: 0)
        #expect(schedule.nextFire(after: after, calendar: calendar) == expectedNext)
    }

    @Test
    func `Minutely fires the next minute`() throws {
        let schedule = try CronSchedule.parse("* * * * *")
        let calendar = utcCalendar()
        let at = utcDate(year: 2026, month: 3, day: 4, hour: 8, minute: 0)
        let expected = utcCalendar().date(byAdding: .minute, value: 1, to: at)
        #expect(schedule.nextFire(after: at, calendar: calendar) == expected)
    }

    @Test
    func `Weekly fires on Monday only`() throws {
        let schedule = try CronSchedule.parse("0 9 * * 1")
        let calendar = utcCalendar()
        // 2026-03-02 is a Monday.
        let monday = utcDate(year: 2026, month: 3, day: 2, hour: 8, minute: 0)
        let expected = utcDate(year: 2026, month: 3, day: 2, hour: 9, minute: 0)
        #expect(schedule.nextFire(after: monday, calendar: calendar) == expected)
        let tuesday = utcDate(year: 2026, month: 3, day: 3, hour: 10, minute: 0)
        let nextMonday = utcDate(year: 2026, month: 3, day: 9, hour: 9, minute: 0)
        #expect(schedule.nextFire(after: tuesday, calendar: calendar) == nextMonday)
    }

    @Test
    func `Due window catches fires between checks`() throws {
        let schedule = try CronSchedule.parse("0 8 * * *")
        let calendar = utcCalendar()
        let lastCheck = utcDate(year: 2026, month: 3, day: 4, hour: 7, minute: 0)
        let now = utcDate(year: 2026, month: 3, day: 4, hour: 9, minute: 0)
        #expect(schedule.isDue(at: now, lastCheck: lastCheck, calendar: calendar) == true)
        let early = utcDate(year: 2026, month: 3, day: 4, hour: 7, minute: 30)
        let beforeFire = utcDate(year: 2026, month: 3, day: 4, hour: 7, minute: 45)
        #expect(schedule.isDue(at: beforeFire, lastCheck: early, calendar: calendar) == false)
    }
}

@Suite("Scheduler Firing and Locking")
struct SchedulerFiringTests {
    @Test
    func `Cron due jobs report in window`() async {
        let job = SchedulerJobConfig(name: "morning", prompt: "Summarize", enabled: true, schedule: "0 8 * * *")
        let engine = SchedulerEngine(jobs: [job])
        let calendar = utcCalendar()
        let lastCheck = utcDate(year: 2026, month: 3, day: 4, hour: 7, minute: 0)
        let now = utcDate(year: 2026, month: 3, day: 4, hour: 9, minute: 0)
        let due = await engine.cronDueJobs(at: now, lastCheck: lastCheck, calendar: calendar)
        #expect(due.count == 1)
        #expect(due.first?.job.name == "morning")
        let idle = await engine.cronDueJobs(at: lastCheck, lastCheck: lastCheck, calendar: calendar)
        #expect(idle.isEmpty == true)
    }

    @Test
    func `Disabled jobs never report due`() async {
        let job = SchedulerJobConfig(name: "quiet", prompt: "Summarize", enabled: false, schedule: "* * * * *")
        let engine = SchedulerEngine(jobs: [job])
        let now = Date()
        let lastCheck = now.addingTimeInterval(-3600)
        #expect(await engine.cronDueJobs(at: now, lastCheck: lastCheck).isEmpty == true)
    }

    @Test
    func `Single-flight second acquire fails until released`() async {
        let engine = SchedulerEngine()
        #expect(await engine.tryBegin(named: "job") == true)
        #expect(await engine.tryBegin(named: "job") == false)
        #expect(await engine.isRunning(named: "job") == true)
        await engine.end(named: "job")
        #expect(await engine.isRunning(named: "job") == false)
        #expect(await engine.tryBegin(named: "job") == true)
        await engine.end(named: "job")
    }

    @Test
    func `Run skips with log when already running`() async {
        let log = TestLog()
        let counter = TurnCounter()
        let engine = await SchedulerEngine(
            jobs: [],
            turnRunner: { _, _, _ in
                await counter.record()
                return "done"
            },
            logger: log.handler()
        )
        let job = SchedulerJobConfig(name: "digest", prompt: "Summarize", enabled: true, schedule: "* * * * *")
        await engine.upsert(job)
        #expect(await engine.tryBegin(named: "digest") == true)
        let skipped = await engine.run(job: job, reason: .cron)
        #expect(skipped.fired == false)
        #expect(skipped.skippedReason == "already running")
        #expect(await counter.count() == 0)
        await engine.end(named: "digest")
        let fired = await engine.run(job: job, reason: .cron)
        #expect(fired.fired == true)
        #expect(fired.responseText == "done")
        #expect(await counter.count() == 1)
        let lines = await log.all()
        #expect(lines.contains { $0.contains("already running") } == true)
        #expect(lines.contains { $0.contains("fired") } == true)
    }

    @Test
    func `Run uses stable job sessions`() async {
        let engine = SchedulerEngine()
        let first = engine.sessionID(forJobNamed: "morning digest")
        let second = engine.sessionID(forJobNamed: "morning digest")
        #expect(first == second)
        #expect(engine.sessionID(forJobNamed: "other") != first)
        let job = SchedulerJobConfig(name: "morning digest", prompt: "Hi", enabled: true, schedule: "* * * * *")
        let result = await engine.run(job: job, reason: .cron)
        #expect(result.sessionID == first)
        #expect(result.fired == true)
    }

    @Test
    func `Poll first observation baselines then fires on new ids`() async {
        let rule = EmailPollRule(account: "personal", query: "invoice", pollIntervalSeconds: 60)
        let job = SchedulerJobConfig(name: "invoices", prompt: "Summarize", enabled: true, poll: rule)
        let provider = BatchProvider(batches: [["1", "2"], ["1", "2"], ["1", "2", "3"]])
        let engine = SchedulerEngine(
            jobs: [job],
            pollChecker: { _ in
                await SchedulerPollCheck(ids: provider.next())
            }
        )
        let first = await engine.pollDueJobs(at: Date())
        #expect(first.isEmpty == true)
        // Respect the poll interval: advance past it before the next check.
        let second = await engine.pollDueJobs(at: Date().addingTimeInterval(61))
        #expect(second.isEmpty == true)
        let third = await engine.pollDueJobs(at: Date().addingTimeInterval(122))
        #expect(third.count == 1)
        #expect(third.first?.reason == .emailArrived(account: "personal", count: 1))
    }
}

@Suite("Headless Approvals")
struct HeadlessApprovalTests {
    @Test
    func `Read-only runs without filing, gated files and denies`() async {
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let handler = await queue.headlessApprovalHandler()
        let bus = ToolBus(permissionGate: gate)
        await bus.register(tool: SchedulerReadStub())
        await bus.register(tool: SchedulerWriteStub())
        await bus.setApprovalHandler(handler)
        let read = await bus.execute(
            toolCall: ToolInput(toolName: "stub.read", argumentsJSON: "{}"),
            context: ToolContext(conversationID: UUID())
        )
        #expect(read.isError == false)
        #expect(await queue.count() == 0)
        let write = await bus.execute(
            toolCall: ToolInput(toolName: "stub.write", argumentsJSON: "{}"),
            context: ToolContext(conversationID: UUID())
        )
        #expect(write.isError == true)
        #expect(await queue.count() == 1)
        #expect(await queue.list().first?.toolName == "stub.write")
    }

    @Test
    func `Decide with duration records trust`() async {
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let request = await queue.enqueue(
            toolName: "stub.write",
            description: "Write stub.",
            input: ToolInput(toolName: "stub.write", argumentsJSON: #"{"path":"/tmp/a"}"#)
        )
        #expect(await queue.decide(id: request.id, approved: true, duration: .oneHour) == true)
        #expect(await gate.isTrusted(ActionDescriptor(toolName: "stub.write", target: "/tmp/a")) == true)
        #expect(await queue.count() == 0)
    }

    @Test
    func `ThisTime approval records no trust and unknown denies`() async {
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)
        let request = await queue.enqueue(
            toolName: "stub.write",
            description: "Write stub.",
            input: ToolInput(toolName: "stub.write", argumentsJSON: #"{"path":"/tmp/b"}"#)
        )
        #expect(await queue.decide(id: request.id, approved: true, duration: .thisTime) == true)
        #expect(await gate.isTrusted(ActionDescriptor(toolName: "stub.write", target: "/tmp/b")) == false)
        #expect(await queue.decide(id: UUID(), approved: true) == false)
        #expect(await queue.waitForDecision(id: UUID()).approved == false)
    }

    @Test
    func `Cancelled waiter cleans up pending request and non-positive timeout delegates`() async {
        let gate = PermissionGate()
        let queue = ApprovalQueue(permissionGate: gate)

        // 1. Cancelled before waitForDecision(id:) begins
        let request1 = await queue.enqueue(
            toolName: "stub.write",
            description: "Write stub.",
            input: ToolInput(toolName: "stub.write", argumentsJSON: #"{"path":"/tmp/c"}"#)
        )
        #expect(await queue.count() == 1)
        let task1 = Task { () -> ApprovalQueueDecision in
            withUnsafeCurrentTask { $0?.cancel() }
            return await queue.waitForDecision(id: request1.id)
        }
        let decision1 = await task1.value
        #expect(decision1.approved == false)
        #expect(await queue.count() == 0)
        #expect(await queue.list().isEmpty)

        // 2. Cancelled before waitForDecision(id:timeoutSeconds:) begins
        let request2 = await queue.enqueue(
            toolName: "stub.write",
            description: "Write stub 2.",
            input: ToolInput(toolName: "stub.write", argumentsJSON: #"{"path":"/tmp/d"}"#)
        )
        #expect(await queue.count() == 1)
        let task2 = Task { () -> ApprovalQueueDecision in
            withUnsafeCurrentTask { $0?.cancel() }
            return await queue.waitForDecision(id: request2.id, timeoutSeconds: 5.0)
        }
        let decision2 = await task2.value
        #expect(decision2.approved == false)
        #expect(await queue.count() == 0)
        #expect(await queue.list().isEmpty)

        // 3. Non-positive timeout delegates to indefinite waitForDecision
        let request3 = await queue.enqueue(
            toolName: "stub.write",
            description: "Write stub 3.",
            input: ToolInput(toolName: "stub.write", argumentsJSON: #"{"path":"/tmp/e"}"#)
        )
        let task3 = Task { () -> ApprovalQueueDecision in
            await queue.waitForDecision(id: request3.id, timeoutSeconds: 0)
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(await queue.decide(id: request3.id, approved: true) == true)
        let decision3 = await task3.value
        #expect(decision3.approved == true)
        #expect(await queue.count() == 0)
    }
}

@Suite("Scheduler Config Tables")
struct SchedulerConfigTests {
    @Test
    func `Cron and poll jobs decode from TOML`() throws {
        let text = """
        [[scheduler.jobs]]
        name = "morning digest"
        schedule = "0 8 * * *"
        prompt = "Summarize overnight mail"
        enabled = true

        [[scheduler.jobs]]
        name = "invoice watcher"
        prompt = "Summarize new invoices"
        poll_account = "personal"
        poll_query = "invoice"
        poll_interval_seconds = 300
        """
        let root = try TOMLParser.parse(text)
        let config = try RuneWeaverConfig(decoding: root)
        #expect(config.scheduler.jobs.count == 2)
        #expect(config.scheduler.jobs[0].schedule == "0 8 * * *")
        #expect(config.scheduler.jobs[1].poll?.account == "personal")
        #expect(config.scheduler.jobs[1].poll?.query == "invoice")
        try config.validate()
    }

    @Test
    func `Missing trigger fails validation`() throws {
        let text = """
        [[scheduler.jobs]]
        name = "broken"
        prompt = "Do something"
        """
        let root = try TOMLParser.parse(text)
        let config = try RuneWeaverConfig(decoding: root)
        do {
            try config.validate()
            Issue.record("Expected validation failure for missing trigger")
        } catch let error as ConfigError {
            guard case let .validationError(field, _) = error else {
                Issue.record("Expected validationError, got \(error)")
                return
            }
            #expect(field.contains("scheduler.jobs") == true)
        }
    }

    @Test
    func `Invalid cron fails validation`() throws {
        let text = """
        [[scheduler.jobs]]
        name = "broken"
        schedule = "not a cron"
        prompt = "Do something"
        """
        let root = try TOMLParser.parse(text)
        let config = try RuneWeaverConfig(decoding: root)
        do {
            try config.validate()
            Issue.record("Expected validation failure for invalid cron")
        } catch let error as ConfigError {
            guard case let .validationError(field, _) = error else {
                Issue.record("Expected validationError, got \(error)")
                return
            }
            #expect(field.contains("schedule") == true)
        }
    }
}

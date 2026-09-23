// Rune Weaver Core Tests — Goal model persistence, due advancement, and audit trail.
//
// Exercises the SQLite-backed goal store end to end against isolated
// temporary databases: creation with ordered steps, filtered listing,
// plan replacement that preserves finished history, lifecycle transitions
// with their audit events, inclusive due-date math, actionable-step
// selection, cascading deletes, and additive migration over databases that
// already carry conversation and scheduler rows. Tests never touch the real
// `~/.runeweaver/memory` store.

import Foundation
@testable import RuneWeaverCore
import Testing

#if canImport(SQLite3)
    import SQLite3
#endif

/// Creates an isolated temporary database path and its parent directory.
/// - Returns: The `episodes.db` path plus the base directory to remove on teardown.
private func makeGoalPath() -> (path: String, base: URL) {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("runeweaver-goals-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return (base.appendingPathComponent("episodes.db").path, base)
}

/// Builds a goal with sane defaults for tests.
private func makeGoal(
    id: UUID = UUID(),
    title: String = "Learn drums",
    statement: String = "Practice rudiments daily",
    status: GoalStatus = .active,
    stepIntervalMinutes: Int = 1440,
    nextDueAt: Date? = nil,
    originSessionID: UUID? = nil
) -> Goal {
    let now = Date()
    return Goal(
        id: id,
        title: title,
        statement: statement,
        status: status,
        stepIntervalMinutes: stepIntervalMinutes,
        nextDueAt: nextDueAt,
        originSessionID: originSessionID,
        createdAt: now,
        updatedAt: now
    )
}

/// Builds one step anchored to a goal.
private func makeStep(
    goalID: UUID,
    ordinal: Int,
    title: String,
    status: StepStatus = .pending
) -> GoalStep {
    let now = Date()
    return GoalStep(
        goalID: goalID,
        ordinal: ordinal,
        title: title,
        status: status,
        createdAt: now,
        updatedAt: now
    )
}

@Suite("GoalStore")
struct GoalStoreTests {
    @Test
    func `Status raw values stay stable for persisted rows`() {
        // Raw strings are the on-disk contract; a rename here would orphan
        // every existing goals table, so pin them explicitly.
        #expect(GoalStatus.active.rawValue == "active")
        #expect(GoalStatus.paused.rawValue == "paused")
        #expect(GoalStatus.needsInput.rawValue == "needs_input")
        #expect(GoalStatus.achieved.rawValue == "achieved")
        #expect(GoalStatus.abandoned.rawValue == "abandoned")
        #expect(StepStatus.inProgress.rawValue == "in_progress")
        #expect(GoalEventKind.planReady.rawValue == "plan_ready")
        #expect(GoalEventKind.stepStarted.rawValue == "step_started")
        #expect(GoalEventKind.stepDone.rawValue == "step_done")
        #expect(GoalEventKind.stepBlocked.rawValue == "step_blocked")
    }

    @Test
    func `Create persists goal steps and a creation event`() async throws {
        let (path, base) = makeGoalPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = GoalStore(dbPath: path)
        let goal = makeGoal(title: "Run daily", statement: "Run every morning")
        let steps = [
            makeStep(goalID: goal.id, ordinal: 0, title: "Shoes on"),
            makeStep(goalID: goal.id, ordinal: 1, title: "Out the door"),
            makeStep(goalID: goal.id, ordinal: 2, title: "Cool down")
        ]

        try await store.create(goal: goal, steps: steps)

        let loaded = try await store.goal(id: goal.id)
        #expect(loaded?.title == "Run daily")
        #expect(loaded?.status == .active)
        let loadedSteps = try await store.steps(goalID: goal.id)
        #expect(loadedSteps.count == 3)
        #expect(loadedSteps.map(\.title) == ["Shoes on", "Out the door", "Cool down"])
        #expect(loadedSteps.map(\.ordinal) == [0, 1, 2])
        let events = try await store.events(goalID: goal.id)
        #expect(events.count == 1)
        #expect(events.first?.kind == .created)
    }

    @Test
    func `List filters by status and active count matches`() async throws {
        let (path, base) = makeGoalPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = GoalStore(dbPath: path)

        let active = makeGoal(title: "Active one", status: .active)
        let paused = makeGoal(title: "Paused one", status: .paused)
        let achieved = makeGoal(title: "Done one", status: .achieved)
        try await store.create(goal: active, steps: [])
        try await store.create(goal: paused, steps: [])
        try await store.create(goal: achieved, steps: [])

        #expect(try await store.list(status: nil).count == 3)
        #expect(try await store.list(status: .active).map(\.id) == [active.id])
        #expect(try await store.list(status: .paused).map(\.id) == [paused.id])
        #expect(try await store.activeGoalCount() == 1)
        #expect(try await store.goal(id: UUID()) == nil)
    }

    @Test
    func `ReplacePlan swaps pending rows and keeps finished history`() async throws {
        let (path, base) = makeGoalPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = GoalStore(dbPath: path)
        let goal = makeGoal()
        let done = makeStep(goalID: goal.id, ordinal: 0, title: "Done", status: .done)
        let active = makeStep(goalID: goal.id, ordinal: 1, title: "Doing", status: .inProgress)
        let staleA = makeStep(goalID: goal.id, ordinal: 2, title: "Stale A")
        let staleB = makeStep(goalID: goal.id, ordinal: 3, title: "Stale B")
        try await store.create(goal: goal, steps: [done, active, staleA, staleB])

        let fresh = [
            makeStep(goalID: goal.id, ordinal: 2, title: "Fresh A"),
            makeStep(goalID: goal.id, ordinal: 3, title: "Fresh B")
        ]
        try await store.replacePlan(goalID: goal.id, steps: fresh)

        let steps = try await store.steps(goalID: goal.id)
        #expect(steps.count == 4)
        #expect(steps.map(\.title) == ["Done", "Doing", "Fresh A", "Fresh B"])
        #expect(steps.map(\.ordinal) == [0, 1, 2, 3])
        // Finished and in-flight rows survive; stale pending titles are gone.
        #expect(steps.contains { $0.title == "Stale A" } == false)
        let kinds = try await store.events(goalID: goal.id).map(\.kind)
        #expect(kinds.contains(.created))
        #expect(kinds.contains(.planReady))
    }

    @Test
    func `Step and goal transitions append matching events`() async throws {
        let (path, base) = makeGoalPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = GoalStore(dbPath: path)
        let goal = makeGoal()
        let step = makeStep(goalID: goal.id, ordinal: 0, title: "First")
        try await store.create(goal: goal, steps: [step])

        try await store.setStepStatus(goalID: goal.id, stepID: step.id, status: .inProgress, notes: "started", lastRunID: nil)
        try await store.setStepStatus(goalID: goal.id, stepID: step.id, status: .blocked, notes: "stuck", lastRunID: nil)
        try await store.setStepStatus(goalID: goal.id, stepID: step.id, status: .done, notes: "finished", lastRunID: nil)
        try await store.setStatus(goalID: goal.id, status: .paused)
        try await store.setStatus(goalID: goal.id, status: .active)
        try await store.setStatus(goalID: goal.id, status: .needsInput)
        try await store.setStatus(goalID: goal.id, status: .achieved)

        let kinds = try await store.events(goalID: goal.id).map(\.kind)
        #expect(kinds == [.created, .stepStarted, .stepBlocked, .stepDone, .paused, .resumed, .needsInput, .completed])
        let finished = try await store.steps(goalID: goal.id).first
        #expect(finished?.status == .done)
        #expect(finished?.notes == "finished")
    }

    @Test
    func `Step status persists notes and run linkage`() async throws {
        let (path, base) = makeGoalPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = GoalStore(dbPath: path)
        let goal = makeGoal()
        let step = makeStep(goalID: goal.id, ordinal: 0, title: "Linked")
        try await store.create(goal: goal, steps: [step])
        let runID = UUID()

        try await store.setStepStatus(goalID: goal.id, stepID: step.id, status: .inProgress, notes: "halfway", lastRunID: runID)

        let loaded = try await store.steps(goalID: goal.id).first
        #expect(loaded?.notes == "halfway")
        #expect(loaded?.lastRunID == runID)
        #expect(loaded?.status == .inProgress)
    }

    @Test
    func `AdvanceDue is inclusive and markAdvanced pushes forward`() async throws {
        let (path, base) = makeGoalPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = GoalStore(dbPath: path)
        let now = Date()
        let overdue = makeGoal(title: "Overdue", status: .active, nextDueAt: now.addingTimeInterval(-60))
        let boundary = makeGoal(title: "Boundary", status: .active, nextDueAt: now)
        let future = makeGoal(title: "Future", status: .active, nextDueAt: now.addingTimeInterval(60))
        let parked = makeGoal(title: "Parked", status: .paused, nextDueAt: now)
        let unscheduled = makeGoal(title: "No schedule", status: .active, nextDueAt: nil)
        for goal in [overdue, boundary, future, parked, unscheduled] {
            try await store.create(goal: goal, steps: [])
        }

        // The boundary row fires: due-at-now counts as due, not early.
        let due = try await store.advanceDue(now: now)
        #expect(Set(due.map(\.id)) == Set([overdue.id, boundary.id]))

        try await store.markAdvanced(goalID: overdue.id, nextDueAt: now.addingTimeInterval(3600))
        let dueAfter = try await store.advanceDue(now: now)
        #expect(Set(dueAfter.map(\.id)) == Set([boundary.id]))
        #expect(try await store.goal(id: overdue.id)?.nextDueAt != nil)
    }

    @Test
    func `NextActionableStep favors lowest pending and empties when finished`() async throws {
        let (path, base) = makeGoalPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = GoalStore(dbPath: path)
        let goal = makeGoal()
        let steps = [
            makeStep(goalID: goal.id, ordinal: 0, title: "Done", status: .done),
            makeStep(goalID: goal.id, ordinal: 1, title: "Blocked", status: .blocked),
            makeStep(goalID: goal.id, ordinal: 2, title: "Skipped", status: .skipped),
            makeStep(goalID: goal.id, ordinal: 3, title: "Next", status: .pending),
            makeStep(goalID: goal.id, ordinal: 4, title: "Later", status: .inProgress)
        ]
        try await store.create(goal: goal, steps: steps)

        // Blocked, done, and skipped rows are looked past, not returned.
        #expect(try await store.nextActionableStep(goalID: goal.id)?.title == "Next")

        try await store.setStepStatus(goalID: goal.id, stepID: steps[3].id, status: .done, notes: nil, lastRunID: nil)
        #expect(try await store.nextActionableStep(goalID: goal.id)?.title == "Later")

        try await store.setStepStatus(goalID: goal.id, stepID: steps[4].id, status: .skipped, notes: nil, lastRunID: nil)
        #expect(try await store.nextActionableStep(goalID: goal.id) == nil)
    }

    @Test
    func `NextActionableStep is nil for empty and blocked-only plans`() async throws {
        let (path, base) = makeGoalPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = GoalStore(dbPath: path)
        let empty = makeGoal(title: "Empty")
        try await store.create(goal: empty, steps: [])
        #expect(try await store.nextActionableStep(goalID: empty.id) == nil)

        let stuck = makeGoal(title: "Stuck")
        try await store.create(
            goal: stuck,
            steps: [makeStep(goalID: stuck.id, ordinal: 0, title: "Walled", status: .blocked)]
        )
        #expect(try await store.nextActionableStep(goalID: stuck.id) == nil)
    }

    @Test
    func `Delete cascades steps and events but spares neighbors`() async throws {
        let (path, base) = makeGoalPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = GoalStore(dbPath: path)
        let condemned = makeGoal(title: "Condemned")
        let survivor = makeGoal(title: "Survivor")
        try await store.create(goal: condemned, steps: [makeStep(goalID: condemned.id, ordinal: 0, title: "Doomed")])
        try await store.create(goal: survivor, steps: [makeStep(goalID: survivor.id, ordinal: 0, title: "Kept")])
        try await store.appendEvent(goalID: condemned.id, kind: .note, message: "extra")

        try await store.delete(goalID: condemned.id)

        #expect(try await store.goal(id: condemned.id) == nil)
        #expect(try await store.steps(goalID: condemned.id).isEmpty)
        #expect(try await store.events(goalID: condemned.id).isEmpty)
        #expect(try await store.goal(id: survivor.id)?.title == "Survivor")
        #expect(try await store.steps(goalID: survivor.id).count == 1)
        // Deleting an unknown goal is a quiet no-op, not a throw.
        try await store.delete(goalID: UUID())
    }

    @Test
    func `Events honor limits and reject non-positive bounds`() async throws {
        let (path, base) = makeGoalPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = GoalStore(dbPath: path)
        let goal = makeGoal()
        try await store.create(goal: goal, steps: [])
        for index in 0 ..< 5 {
            try await store.appendEvent(goalID: goal.id, kind: .note, message: "note \(index)")
        }

        // Six rows total (creation plus five notes), oldest first.
        let all = try await store.events(goalID: goal.id)
        #expect(all.count == 6)
        #expect(all.first?.kind == .created)
        // A bounded read quotes the most-recent tail, returned oldest first.
        let capped = try await store.events(goalID: goal.id, limit: 2)
        #expect(capped.count == 2)
        #expect(capped.map(\.id) == Array(all.suffix(2).map(\.id)))
        #expect(try await store.events(goalID: goal.id, limit: 0).isEmpty)
        #expect(try await store.events(goalID: goal.id, limit: -3).isEmpty)
    }

    @Test
    func `Goal tables migrate additively over sessions and run logs`() async throws {
        let (path, base) = makeGoalPath()
        defer { try? FileManager.default.removeItem(at: base) }
        #if canImport(SQLite3)
            // Seed a database that already carries conversation and scheduler
            // rows, proving goal migration never disturbs neighboring tables.
            let expanded = (path as NSString).expandingTildeInPath
            try? FileManager.default.removeItem(atPath: expanded)
            if let parent = (expanded as NSString).deletingLastPathComponent as String?, !parent.isEmpty {
                try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
            }
            var seed: OpaquePointer?
            guard expanded.withCString({ sqlite3_open($0, &seed) }) == SQLITE_OK, let seed else {
                Issue.record("Could not seed legacy database")
                return
            }
            defer { sqlite3_close(seed) }
            let seedSQL = """
            CREATE TABLE sessions(id TEXT PRIMARY KEY, title TEXT, summary TEXT, created_at REAL NOT NULL, updated_at REAL NOT NULL, source TEXT);
            INSERT INTO sessions(id, title, summary, created_at, updated_at, source) VALUES('11111111-1111-1111-1111-111111111111', 'seed', NULL, 0, 0, NULL);
            CREATE TABLE run_logs(id TEXT PRIMARY KEY, job_name TEXT NOT NULL);
            INSERT INTO run_logs(id, job_name) VALUES('run-1', 'morning digest');
            """
            guard sqlite3_exec(seed, seedSQL, nil, nil, nil) == SQLITE_OK else {
                Issue.record("Could not seed sessions and run logs")
                return
            }
        #endif

        let store = GoalStore(dbPath: path)
        let goal = makeGoal(title: "Coexists")
        try await store.create(goal: goal, steps: [makeStep(goalID: goal.id, ordinal: 0, title: "Step")])

        #expect(try await store.goal(id: goal.id)?.title == "Coexists")
        #expect(try await store.steps(goalID: goal.id).count == 1)

        #if canImport(SQLite3)
            let reopenedPath = (path as NSString).expandingTildeInPath
            var probe: OpaquePointer?
            guard reopenedPath.withCString({ sqlite3_open($0, &probe) }) == SQLITE_OK, let probe else {
                Issue.record("Could not reopen seeded database")
                return
            }
            defer { sqlite3_close(probe) }
            func scalar(_ sql: String) -> Int {
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(probe, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return -1 }
                defer { sqlite3_finalize(statement) }
                guard sqlite3_step(statement) == SQLITE_ROW else { return -1 }
                return Int(sqlite3_column_int(statement, 0))
            }
            // Neighbor rows survive the additive goal migration untouched.
            #expect(scalar("SELECT COUNT(*) FROM sessions;") == 1)
            #expect(scalar("SELECT COUNT(*) FROM run_logs;") == 1)
            #expect(scalar("SELECT COUNT(*) FROM goals;") == 1)
            #expect(scalar("SELECT COUNT(*) FROM goal_steps;") == 1)
        #endif
    }
}

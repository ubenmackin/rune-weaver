// Rune Weaver Core Tests — Fan-out owner cancellation surface.

import Foundation
import os
@testable import RuneWeaverCore
import Testing

/// Cancellable orchestrator stub: each turn counts itself in flight, sleeps its per-prompt budget,
/// and lets a cancellation end it, so owner cancels and whole-call cancellation are observable
/// end-to-end.
private final class CancellableFanOutOrchestrator: OrchestratorFanOutSeam {
    /// Guarded in-flight count.
    private struct State: Sendable {
        /// Turns currently in flight.
        var inFlight = 0
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())
    /// Sleep budget per prompt in seconds; a prompt with no entry finishes
    /// immediately.
    private let delays: [String: Double]
    /// Error reasons thrown per prompt; a prompt with no entry succeeds.
    private let failures: [String: String]

    /// Creates a cancellable stub. delays: Sleep budget per prompt in seconds.
    init(delays: [String: Double] = [:], failures: [String: String] = [:]) {
        self.delays = delays
        self.failures = failures
    }

    /// Number of turns currently in flight.
    var inFlight: Int {
        state.withLock { $0.inFlight }
    }

    /// Runs one canned turn, discarding its output.
    func process(_ input: UserInput) async throws {
        _ = try await processCollecting(input)
    }

    /// Runs one canned turn: counts itself in flight, sleeps its budget, and
    /// throws the canned reason or returns real output. `Task.sleep` throws on
    /// cancellation, so a stopped worker surfaces as a cancellation error.
    func processCollecting(_ input: UserInput) async throws -> FanOutWorkerOutput {
        state.withLock { probe in
            probe.inFlight += 1
        }
        defer {
            state.withLock { probe in
                probe.inFlight -= 1
            }
        }
        if let reason = failures[input.text] {
            throw FanOutStubError(reason: reason)
        }
        let delay = delays[input.text] ?? 0
        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        return FanOutWorkerOutput(text: "Output for \(input.text)", isParked: false)
    }
}

/// Capturing run logger with a first-child-row observer hook.
private final class CancellingFanOutRunLogger: FanOutRunLogging {
    /// One recorded run row with its latest settled outcome.
    struct Row: Sendable {
        let id: UUID
        let kind: String
        let message: String
        let sessionID: UUID
        var status: String
        var response: String?
        var durationMs: Int?
    }

    private let rows = OSAllocatedUnfairLock<[Row]>(initialState: [])
    private let firstChildObserver = OSAllocatedUnfairLock<(@Sendable (UUID) async -> Void)?>(initialState: nil)
    private let firstChildObserved = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// Rows in append order with their latest settled outcome.
    var recordedRows: [Row] {
        rows.withLock { $0 }
    }

    /// The parent swarm row, when one has been appended.
    var parentRow: Row? {
        recordedRows.first { $0.kind == FanOutEngine.parentRowKind }
    }

    /// Child worker rows in append order.
    var workerRows: [Row] {
        recordedRows.filter { $0.kind == FanOutEngine.workerRowKind }
    }

    /// One row by its exact message, which is the subtask title for a child.
    /// - Parameter message: Row message to match.
    /// - Returns: The matching row, or nil.
    func row(message: String) -> Row? {
        recordedRows.first { $0.message == message }
    }

    /// Registers an observer invoked once, after the first child row appends
    /// and before the worker tasks are created.
    /// - Parameter observer: Invoked with the first child row id.
    func observeFirstChildRow(_ observer: @escaping @Sendable (UUID) async -> Void) {
        firstChildObserver.withLock { $0 = observer }
    }

    @discardableResult
    func appendFanOutRow(kind: String, status: String, message: String, sessionID: UUID) async -> UUID {
        let id = UUID()
        rows.withLock { captured in
            captured.append(Row(id: id, kind: kind, message: message, sessionID: sessionID, status: status))
        }
        if kind == FanOutEngine.workerRowKind, let observer = firstChildObserver.withLock({ $0 }) {
            let isFirst = firstChildObserved.withLock { observed -> Bool in
                guard !observed else { return false }
                observed = true
                return true
            }
            if isFirst {
                await observer(id)
            }
        }
        return id
    }

    func updateFanOutRow(id: UUID, status: String) async {
        await updateFanOutRow(id: id, status: status, response: nil, durationMs: nil)
    }

    func updateFanOutRow(id: UUID, status: String, response: String?, durationMs: Int?) async {
        rows.withLock { captured in
            guard let index = captured.firstIndex(where: { $0.id == id }) else { return }
            captured[index].status = status
            if let response {
                captured[index].response = response
            }
            if let durationMs {
                captured[index].durationMs = durationMs
            }
        }
    }
}

/// Reviewer LLM that counts its chat calls so a test can prove an
/// all-cancelled run never spends a review round.
private final class CountingReviewLLM: LLMProvider {
    /// Stable placeholder model metadata.
    let modelInfo = ModelInfo(name: "counting-reviewer", provider: "stub", contextLength: 2048)
    private let calls = OSAllocatedUnfairLock<Int>(initialState: 0)

    /// Number of chat calls observed.
    var chatCallCount: Int {
        calls.withLock { $0 }
    }

    /// Counts the call and yields a parseable review.
    func chat(messages _: [Message], tools _: [any Tool]) -> AsyncStream<LLMResponse> {
        calls.withLock { $0 += 1 }
        return AsyncStream { continuation in
            continuation.yield(LLMResponse(delta: #"{"summary":"merged","verdicts":[]}"#, isFinished: true))
            continuation.finish()
        }
    }

    /// Unused embeddings stub.
    func embeddings(text _: [String]) async throws -> [[Float]] {
        []
    }
}

/// Creates a fan-out engine over the given stubs.
private func makeCancelEngine(
    orchestrator: OrchestratorFanOutSeam,
    runLogger: FanOutRunLogging,
    reviewer: any LLMProvider? = nil,
    configure: (inout FanOutConfig) -> Void = { _ in }
) -> FanOutEngine {
    var config = FanOutConfig()
    configure(&config)
    return FanOutEngine(orchestrator: orchestrator, runLogs: runLogger, config: config, reviewer: reviewer)
}

/// Builds one subtask for the cancellation tests.
private func cancelSubtask(title: String, prompt: String? = nil) -> FanOutSubtask {
    FanOutSubtask(title: title, prompt: prompt ?? "Prompt for \(title)")
}

/// Polls a condition until it holds or the deadline passes, so tests order themselves against real
/// worker state instead of racing fixed sleeps.
private func waitUntil(
    timeoutSeconds: Double = 5,
    _ condition: @escaping @Sendable () async -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if await condition() {
            return
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

@Suite("FanOutCancel")
struct FanOutCancelTests {
    @Test
    func `Cancelling one worker flips only its subtask and row while siblings keep running`() async throws {
        let orchestrator = CancellableFanOutOrchestrator(delays: ["Prompt for A": 0.4, "Prompt for B": 5])
        let runLogger = CancellingFanOutRunLogger()
        let engine = makeCancelEngine(orchestrator: orchestrator, runLogger: runLogger)
        let runTask = Task {
            try await engine.runFanOut(
                subtasks: [cancelSubtask(title: "A"), cancelSubtask(title: "B")],
                originSessionID: UUID()
            )
        }

        await waitUntil { orchestrator.inFlight == 2 }
        let childRow = try #require(runLogger.row(message: "B"))
        #expect(await engine.cancel(rowID: childRow.id) == .workerCancelled)

        let run = try await runTask.value
        // Only the stopped worker flips cancelled; its sibling finished with
        // real output and keeps its done status and ok row.
        #expect(run.status == .cancelled)
        #expect(run.subtasks.first { $0.title == "A" }?.status == .done)
        #expect(run.subtasks.first { $0.title == "B" }?.status == .cancelled)
        #expect(runLogger.row(message: "A")?.status == "ok")
        #expect(runLogger.row(message: "B")?.status == "cancelled")
        #expect(runLogger.parentRow?.status == "cancelled")
        #expect(run.summary?.contains("Cancelled subtasks: B (cancelled by owner)") == true)
    }

    @Test
    func `Cancelling the parent stops every in-flight worker`() async throws {
        let orchestrator = CancellableFanOutOrchestrator(delays: ["Prompt for A": 5, "Prompt for B": 5])
        let runLogger = CancellingFanOutRunLogger()
        let engine = makeCancelEngine(orchestrator: orchestrator, runLogger: runLogger)
        let runTask = Task {
            try await engine.runFanOut(
                subtasks: [cancelSubtask(title: "A"), cancelSubtask(title: "B")],
                originSessionID: UUID()
            )
        }

        await waitUntil { orchestrator.inFlight == 2 }
        let parentRow = try #require(runLogger.parentRow)
        #expect(await engine.cancel(rowID: parentRow.id) == .runCancelled(workerCount: 2))

        let run = try await runTask.value
        // A cancelled swarm reads cancelled, not error: every subtask and
        // both audit rows carry the stop, and the digest states it plainly.
        #expect(run.status == .cancelled)
        #expect(run.subtasks.allSatisfy { $0.status == .cancelled })
        #expect(run.summary == FanOutEngine.allCancelledSummary(for: run.subtasks))
        #expect(runLogger.parentRow?.status == "cancelled")
        #expect(runLogger.workerRows.count == 2)
        #expect(runLogger.workerRows.allSatisfy { $0.status == "cancelled" })
    }

    @Test
    func `A cancel racing startup lands before any worker registers`() async throws {
        let orchestrator = CancellableFanOutOrchestrator(delays: ["Prompt for A": 5, "Prompt for B": 5])
        let runLogger = CancellingFanOutRunLogger()
        let engine = makeCancelEngine(orchestrator: orchestrator, runLogger: runLogger)
        let outcomeBox = OSAllocatedUnfairLock<FanOutCancelOutcome?>(initialState: nil)
        runLogger.observeFirstChildRow { [weak engine] _ in
            guard let engine, let parentRowID = runLogger.parentRow?.id else { return }
            let outcome = await engine.cancel(rowID: parentRowID)
            outcomeBox.withLock { $0 = outcome }
        }

        let run = try await engine.runFanOut(
            subtasks: [cancelSubtask(title: "A"), cancelSubtask(title: "B")],
            originSessionID: UUID()
        )

        // The cancel landed after the run registered but before any worker task existed, so the
        // honest count is zero — yet every subtask still settles cancelled because the mark precedes
        // the worker start and cancels it on arrival.
        #expect(outcomeBox.withLock { $0 } == .runCancelled(workerCount: 0))
        #expect(run.status == .cancelled)
        #expect(run.subtasks.allSatisfy { $0.status == .cancelled })
        #expect(run.summary == FanOutEngine.allCancelledSummary(for: run.subtasks))
        #expect(runLogger.parentRow?.status == "cancelled")
        #expect(runLogger.workerRows.count == 2)
        #expect(runLogger.workerRows.allSatisfy { $0.status == "cancelled" })
        // The startup stop never lets worker output leak into the digest.
        #expect(run.summary?.contains("Output for") == false)
    }

    @Test
    func `Settled and unknown rows report notRunning`() async throws {
        let orchestrator = CancellableFanOutOrchestrator(delays: ["Prompt for A": 0.1, "Prompt for B": 5])
        let runLogger = CancellingFanOutRunLogger()
        let engine = makeCancelEngine(orchestrator: orchestrator, runLogger: runLogger)
        let runTask = Task {
            try await engine.runFanOut(
                subtasks: [cancelSubtask(title: "A"), cancelSubtask(title: "B")],
                originSessionID: UUID()
            )
        }

        // Worker A settles while B is still running: a settled child row
        // accepts no cancel, and neither does an unknown identifier.
        await waitUntil { runLogger.row(message: "A")?.status == "ok" }
        let settledChildRow = try #require(runLogger.row(message: "A"))
        #expect(await engine.cancel(rowID: settledChildRow.id) == .notRunning)
        #expect(await engine.cancel(rowID: UUID()) == .notRunning)

        let runningChildRow = try #require(runLogger.row(message: "B"))
        #expect(await engine.cancel(rowID: runningChildRow.id) == .workerCancelled)
        _ = try await runTask.value

        // Once the swarm settles, its rows deregister: both the parent row
        // and the already-stopped child row answer notRunning.
        let parentRow = try #require(runLogger.parentRow)
        #expect(await engine.cancel(rowID: parentRow.id) == .notRunning)
        #expect(await engine.cancel(rowID: runningChildRow.id) == .notRunning)
    }

    @Test
    func `Cancelled outranks failed in the parent digest and row`() async throws {
        let orchestrator = CancellableFanOutOrchestrator(
            delays: ["Prompt for B": 5],
            failures: ["Prompt for A": "boom"]
        )
        let runLogger = CancellingFanOutRunLogger()
        let engine = makeCancelEngine(orchestrator: orchestrator, runLogger: runLogger)
        let runTask = Task {
            try await engine.runFanOut(
                subtasks: [cancelSubtask(title: "A"), cancelSubtask(title: "B")],
                originSessionID: UUID()
            )
        }

        // Wait until the fast failure settles so the parent cancel targets
        // exactly the one worker still in flight.
        await waitUntil { runLogger.row(message: "A")?.status == "failed" }
        let parentRow = try #require(runLogger.parentRow)
        #expect(await engine.cancel(rowID: parentRow.id) == .runCancelled(workerCount: 1))

        let run = try await runTask.value
        // A deliberate owner stop outranks a lost worker: the run and its
        // parent row read cancelled, while the genuinely failed subtask stays
        // failed in the digest.
        #expect(run.status == .cancelled)
        #expect(run.subtasks.first { $0.title == "A" }?.status == .failed)
        #expect(run.subtasks.first { $0.title == "B" }?.status == .cancelled)
        #expect(runLogger.parentRow?.status == "cancelled")
        #expect(run.summary?.contains("0/2 subtasks completed") == true)
        #expect(run.summary?.contains("failed: A (boom)") == true)
        #expect(run.summary?.contains("Cancelled subtasks: B (cancelled by owner)") == true)
    }

    @Test
    func `An all-cancelled run skips the reviewer call`() async throws {
        let orchestrator = CancellableFanOutOrchestrator(delays: ["Prompt for A": 5, "Prompt for B": 5])
        let runLogger = CancellingFanOutRunLogger()
        let reviewer = CountingReviewLLM()
        let engine = makeCancelEngine(orchestrator: orchestrator, runLogger: runLogger, reviewer: reviewer)
        let runTask = Task {
            try await engine.runFanOut(
                subtasks: [cancelSubtask(title: "A"), cancelSubtask(title: "B")],
                originSessionID: UUID()
            )
        }

        await waitUntil { orchestrator.inFlight == 2 }
        let parentRow = try #require(runLogger.parentRow)
        #expect(await engine.cancel(rowID: parentRow.id) == .runCancelled(workerCount: 2))

        let run = try await runTask.value
        // Nothing survived to merge, so the review call is skipped and the
        // digest states the stop instead of a fabricated merge.
        #expect(run.status == .cancelled)
        #expect(run.summary == FanOutEngine.allCancelledSummary(for: run.subtasks))
        #expect(reviewer.chatCallCount == 0)
    }

    @Test
    func `Whole-call cancellation settles cancelled statuses instead of failed`() async throws {
        let orchestrator = CancellableFanOutOrchestrator(delays: ["Prompt for A": 30, "Prompt for B": 30])
        let runLogger = CancellingFanOutRunLogger()
        let engine = makeCancelEngine(orchestrator: orchestrator, runLogger: runLogger)
        let runTask = Task {
            try await engine.runFanOut(
                subtasks: [cancelSubtask(title: "A"), cancelSubtask(title: "B")],
                originSessionID: UUID()
            )
        }

        await waitUntil { orchestrator.inFlight == 2 }
        // The chat per-tool cancel cancels the caller's turn task; the swarm
        // must surface the stop as cancelled, never as worker failures.
        runTask.cancel()
        let run = try await runTask.value
        #expect(run.status == .cancelled)
        #expect(run.subtasks.allSatisfy { $0.status == .cancelled })
        #expect(run.summary == FanOutEngine.allCancelledSummary(for: run.subtasks))
        #expect(runLogger.parentRow?.status == "cancelled")
        #expect(runLogger.workerRows.allSatisfy { $0.status == "cancelled" })
        #expect(run.summary?.contains("failed") == false)
    }

    @Test
    func `Cancelled statuses round-trip through Codable`() throws {
        let subtask = FanOutSubtask(title: "A", prompt: "p", status: .cancelled)
        let subtaskData = try JSONEncoder().encode(subtask)
        let subtaskText = try #require(String(bytes: subtaskData, encoding: .utf8))
        #expect(subtaskText.contains("\"cancelled\""))
        let decodedSubtask = try JSONDecoder().decode(FanOutSubtask.self, from: subtaskData)
        #expect(decodedSubtask == subtask)

        let run = FanOutRun(
            parentSessionID: UUID(),
            subtasks: [subtask],
            status: .cancelled,
            summary: "Cancelled by owner."
        )
        let runData = try JSONEncoder().encode(run)
        let runText = try #require(String(bytes: runData, encoding: .utf8))
        #expect(runText.contains("\"cancelled\""))
        let decoded = try JSONDecoder().decode(FanOutRun.self, from: runData)
        #expect(decoded == run)
        #expect(decoded.subtasks.first?.status == .cancelled)

        // Payloads written before the terminal state existed still decode:
        // a missing status keeps its historical default.
        let legacy = #"{"id":"00000000-0000-0000-0000-000000000002","title":"A","prompt":"p"}"#
        let legacyData = try #require(legacy.data(using: .utf8))
        let legacyDecoded = try JSONDecoder().decode(FanOutSubtask.self, from: legacyData)
        #expect(legacyDecoded.status == .pending)
    }
}

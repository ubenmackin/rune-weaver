// Rune Weaver Core Tests — Fan-out merge pass, background reviewer, and the
// run settle surface.
//
// Exercises the merge pass with a collecting orchestrator stub (real worker
// output), a stub reviewer LLM (canned JSON review or an error chunk), and a
// capturing run logger that mirrors the store's kind filter: the
// deterministic overlap conflict flagging (identical file paths across
// subtasks, outranking reviewer verdicts), the reviewer success path (merged
// summary plus per-subtask verdicts stored on the run and its parent row),
// the fail-open path (a wired reviewer that flakes degrades to the raw
// concatenation with an honest note, never losing worker output), the parent
// row settling into the executeJob vocabulary (ok, awaiting_approval, error)
// with a parked worker, the fanout.run permission-level assertion via
// PermissionGate, the disabled fail-closed message, and the kind filter
// end-to-end through the seam. Tests never touch the real run-log store or
// the live orchestrator.

import Foundation
import os
@testable import RuneWeaverCore
import RuneWeaverTools
import Testing

/// Shared stub error for the fan-out suites: one typed reason a stub turn can
/// throw so the failure note and the fail-open paths stay exercisable.
/// Internal to the test target so every fan-out suite shares one stub type.
struct FanOutStubError: Error, Equatable {
    /// Canned failure reason.
    let reason: String
}

/// Stub seam whose turns finish with canned output text so the merge pass has
/// real worker output to review. The collecting witness returns the canned
/// text and parked flag; the plain seam runs the same turn and discards it.
private final class CollectingFanOutOrchestrator: OrchestratorFanOutSeam, @unchecked Sendable {
    /// Guarded captured inputs in arrival order.
    private let inputs = OSAllocatedUnfairLock<[UserInput]>(initialState: [])
    /// Output text per prompt; a prompt with no entry produces no output.
    private let outputs: [String: String]
    /// Error reasons thrown per prompt; a prompt with no entry succeeds.
    private let failures: [String: String]
    /// Prompts whose turns park awaiting approval.
    private let parks: Set<String>

    /// Creates a collecting stub.
    /// - Parameters:
    ///   - outputs: Output text per prompt.
    ///   - failures: Error reasons thrown per prompt.
    ///   - parks: Prompts whose turns park awaiting approval.
    init(outputs: [String: String] = [:], failures: [String: String] = [:], parks: Set<String> = []) {
        self.outputs = outputs
        self.failures = failures
        self.parks = parks
    }

    /// Inputs observed so far, oldest first.
    var capturedInputs: [UserInput] {
        inputs.withLock { $0 }
    }

    /// Runs one canned turn, discarding the output.
    func process(_ input: UserInput) async throws {
        _ = try await run(input)
    }

    /// Runs one canned turn and returns the canned output with the parked
    /// flag so the merge pass reviews real worker text.
    func processCollecting(_ input: UserInput) async throws -> FanOutWorkerOutput {
        let text = try await run(input)
        return FanOutWorkerOutput(text: text, isParked: parks.contains(input.text))
    }

    /// Runs one canned turn: records the input, then succeeds with the canned
    /// output or throws the canned reason.
    private func run(_ input: UserInput) async throws -> String {
        inputs.withLock { $0.append(input) }
        if let reason = failures[input.text] {
            throw FanOutStubError(reason: reason)
        }
        return outputs[input.text] ?? ""
    }
}

/// Stub reviewer LLM returning a canned JSON review, or an error chunk when
/// the review should flake so the fail-open path is exercisable.
private struct StubReviewLLM: LLMProvider {
    /// Stable placeholder model metadata.
    let modelInfo = ModelInfo(name: "stub-reviewer", provider: "stub", contextLength: 2048)
    /// Canned review text, or nil when the review should flake.
    let reply: String?

    /// Creates a stub reviewer.
    /// - Parameter reply: Canned review text, or nil to flake.
    init(reply: String? = nil) {
        self.reply = reply
    }

    /// Yields the canned reply, or an error chunk when the review flakes.
    func chat(messages _: [Message], tools _: [any Tool]) -> AsyncStream<LLMResponse> {
        AsyncStream { continuation in
            if let reply {
                continuation.yield(LLMResponse(delta: reply, isFinished: true))
            } else {
                continuation.yield(LLMResponse(delta: "", isFinished: true, errorMessage: "review unavailable"))
            }
            continuation.finish()
        }
    }

    /// Unused embeddings stub.
    func embeddings(text _: [String]) async throws -> [[Float]] {
        []
    }
}

/// Stub run logger recording rows and updates so tests can pin the audit
/// trail the engine actually wrote, with a kind-filtered read mirroring the
/// store's list semantics so the dashboard's fanout fetch is exercisable
/// end-to-end through the seam.
private final class CapturingMergeRunLogger: FanOutRunLogging, @unchecked Sendable {
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

    /// Guarded rows in append order.
    private let rows = OSAllocatedUnfairLock<[Row]>(initialState: [])

    /// Rows in append order with their latest settled outcome.
    var recordedRows: [Row] {
        rows.withLock { $0 }
    }

    @discardableResult
    func appendFanOutRow(kind: String, status: String, message: String, sessionID: UUID) async -> UUID {
        let id = UUID()
        rows.withLock { captured in
            captured.append(Row(id: id, kind: kind, message: message, sessionID: sessionID, status: status))
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

    /// Kind-filtered read mirroring the store's list: the filter applies
    /// before the limit so sparse kinds are not dropped by a newest-N window,
    /// and rows return newest first.
    /// - Parameters:
    ///   - kind: Row kind to fetch.
    ///   - limit: Newest-N window.
    /// - Returns: Matching rows, newest first.
    func rowsMatching(kind: String, limit: Int = 50) -> [Row] {
        let matching = recordedRows.filter { $0.kind == kind }
        return Array(matching.suffix(limit).reversed())
    }
}

/// Creates an enabled fan-out engine over the given stubs.
private func makeMergeEngine(
    orchestrator: OrchestratorFanOutSeam,
    runLogger: FanOutRunLogging,
    reviewer: (any LLMProvider)? = nil,
    configure: (inout FanOutConfig) -> Void = { _ in }
) -> FanOutEngine {
    var config = FanOutConfig()
    config.enabled = true
    configure(&config)
    return FanOutEngine(orchestrator: orchestrator, runLogs: runLogger, config: config, reviewer: reviewer)
}

/// Builds one subtask for merge tests.
private func makeSubtask(title: String, prompt: String? = nil) -> FanOutSubtask {
    FanOutSubtask(title: title, prompt: prompt ?? "Prompt for \(title)")
}

@Suite("FanOutMerge")
struct FanOutMergeTests {
    @Test
    func `Overlap conflict flags identical paths across subtasks and outranks reviewer verdicts`() async throws {
        let orchestrator = CollectingFanOutOrchestrator(outputs: [
            "Prompt for A": "Wrote /tmp/report.md with findings.",
            "Prompt for B": "Wrote /tmp/report.md with a second pass."
        ])
        let runLogger = CapturingMergeRunLogger()
        let reviewer = StubReviewLLM(reply: #"{"summary":"Merged findings.","verdicts":[{"title":"A","verdict":"keep"},{"title":"B","verdict":"keep"}]}"#)
        let engine = makeMergeEngine(orchestrator: orchestrator, runLogger: runLogger, reviewer: reviewer)

        let run = try await engine.runFanOut(
            subtasks: [makeSubtask(title: "A"), makeSubtask(title: "B")],
            originSessionID: UUID()
        )

        // The deterministic conflict outranks the reviewer's keep verdicts:
        // duplicate targets are the overlap check's own finding.
        #expect(run.summary?.contains("A: conflict") == true)
        #expect(run.summary?.contains("B: conflict") == true)
        #expect(run.summary?.contains("Merged findings.") == true)
        #expect(run.summary?.contains("identical file paths or URLs") == true)
    }

    @Test
    func `Reviewer fail-open degrades to the raw concatenation with an honest note`() async throws {
        let orchestrator = CollectingFanOutOrchestrator(outputs: [
            "Prompt for A": "Found three leads in mail.",
            "Prompt for B": "Found two leads on the web."
        ])
        let runLogger = CapturingMergeRunLogger()
        let reviewer = StubReviewLLM(reply: nil)
        let engine = makeMergeEngine(orchestrator: orchestrator, runLogger: runLogger, reviewer: reviewer)

        let run = try await engine.runFanOut(
            subtasks: [makeSubtask(title: "A"), makeSubtask(title: "B")],
            originSessionID: UUID()
        )

        // Fail-open: the raw concatenation carries every worker output with
        // an honest note, and nothing reads as merged when it is not.
        #expect(run.summary?.contains("Found three leads in mail.") == true)
        #expect(run.summary?.contains("Found two leads on the web.") == true)
        #expect(run.summary?.contains("Background review was unavailable; worker output is shown unmerged.") == true)
        #expect(run.summary?.contains("Merged:") == false)
        // The parent row keeps the fail-open summary as its response so the
        // audit trail renders the same honest text the caller saw.
        let parent = try #require(runLogger.recordedRows.first { $0.kind == FanOutEngine.parentRowKind })
        #expect(parent.response == run.summary)
    }

    @Test
    func `Reviewer success stores the merged summary plus per-subtask verdicts`() async throws {
        let orchestrator = CollectingFanOutOrchestrator(outputs: [
            "Prompt for A": "Lead one.",
            "Prompt for B": "Lead two."
        ])
        let runLogger = CapturingMergeRunLogger()
        let reviewer = StubReviewLLM(reply: #"{"summary":"Merged: two leads.","verdicts":[{"title":"A","verdict":"keep"},{"title":"B","verdict":"drop"}]}"#)
        let engine = makeMergeEngine(orchestrator: orchestrator, runLogger: runLogger, reviewer: reviewer)

        let run = try await engine.runFanOut(
            subtasks: [makeSubtask(title: "A"), makeSubtask(title: "B")],
            originSessionID: UUID()
        )

        // The reviewer output is stored on the run summary with verdict lines.
        #expect(run.summary?.contains("Merged: two leads.") == true)
        #expect(run.summary?.contains("A: keep") == true)
        #expect(run.summary?.contains("B: drop") == true)
        // The parent row renders the merged summary as its response with an
        // honest duration.
        let parent = try #require(runLogger.recordedRows.first { $0.kind == FanOutEngine.parentRowKind })
        #expect(parent.response == run.summary)
        #expect(parent.durationMs != nil)
    }

    @Test
    func `Parent row settles into the executeJob vocabulary`() async throws {
        // A parked worker persists as awaiting_approval on both the child row
        // and the parent row, resolving through the same inbox resume path in
        // its own session.
        let orchestrator = CollectingFanOutOrchestrator(
            outputs: ["Prompt for A": "Done.", "Prompt for B": "Done."],
            parks: ["Prompt for B"]
        )
        let runLogger = CapturingMergeRunLogger()
        let engine = makeMergeEngine(orchestrator: orchestrator, runLogger: runLogger)

        let run = try await engine.runFanOut(
            subtasks: [makeSubtask(title: "A"), makeSubtask(title: "B")],
            originSessionID: UUID()
        )

        #expect(run.status == .completed)
        let parent = try #require(runLogger.recordedRows.first { $0.kind == FanOutEngine.parentRowKind })
        #expect(parent.status == "awaiting_approval")
        let parkedChild = try #require(runLogger.recordedRows.first { $0.message == "B" })
        #expect(parkedChild.status == "awaiting_approval")
        let okChild = try #require(runLogger.recordedRows.first { $0.message == "A" })
        #expect(okChild.status == "ok")

        // A failed worker settles the parent row error, outranking a park.
        let failing = CollectingFanOutOrchestrator(
            outputs: ["Prompt for A": "Done.", "Prompt for B": "Done."],
            failures: ["Prompt for B": "boom"],
            parks: ["Prompt for A"]
        )
        let failureLogger = CapturingMergeRunLogger()
        let failingEngine = makeMergeEngine(orchestrator: failing, runLogger: failureLogger)
        _ = try await failingEngine.runFanOut(
            subtasks: [makeSubtask(title: "A"), makeSubtask(title: "B")],
            originSessionID: UUID()
        )
        let failedParent = try #require(failureLogger.recordedRows.first { $0.kind == FanOutEngine.parentRowKind })
        #expect(failedParent.status == "error")
        // Separate loggers stay isolated: the first run's parked parent keeps
        // awaiting_approval while the second run's parent reads error.
        #expect(parent.status == "awaiting_approval")
    }

    @Test
    func `Unwired reviewer keeps the pre-existing outcome digest`() async throws {
        let orchestrator = CollectingFanOutOrchestrator(outputs: ["Prompt for A": "Done."])
        let runLogger = CapturingMergeRunLogger()
        let engine = makeMergeEngine(orchestrator: orchestrator, runLogger: runLogger)

        let run = try await engine.runFanOut(subtasks: [makeSubtask(title: "A")], originSessionID: UUID())

        // No reviewer wired: the pre-existing digest stands so callers without
        // review wiring see no summary shape change, and the parent row keeps
        // that digest as its response.
        #expect(run.summary == "All 1 subtasks completed.")
        let parent = try #require(runLogger.recordedRows.first { $0.kind == FanOutEngine.parentRowKind })
        #expect(parent.status == "ok")
        #expect(parent.response == run.summary)
    }

    @Test
    func `fanout.run parks for approval via PermissionGate`() async throws {
        let engine = makeMergeEngine(orchestrator: CollectingFanOutOrchestrator(), runLogger: CapturingMergeRunLogger())
        let gate = PermissionGate()
        let tool = try #require(FanOutTools.makeTools(engine: engine).first)
        let call = ToolInput(toolName: "fanout.run", argumentsJSON: #"{"subtasks":[{"title":"A","prompt":"p"}]}"#)

        // Spawning autonomous work spends concurrent model rounds, so the
        // graduated-trust gate parks the call instead of allowing it.
        let verdict = await gate.checkPermission(toolCall: call, tool: tool)
        guard case .requiresApproval = verdict else {
            Issue.record("fanout.run must park for approval")
            return
        }
    }

    @Test
    func `Disabled fanout fails closed with the honest message`() async throws {
        let orchestrator = CollectingFanOutOrchestrator()
        let runLogger = CapturingMergeRunLogger()
        // Hand-built config keeps the disabled default, unlike the helper.
        let engine = FanOutEngine(orchestrator: orchestrator, runLogs: runLogger, config: FanOutConfig())
        #expect(await engine.isEnabled == false)
        let tool = try #require(FanOutTools.makeTools(engine: engine).first)

        let output = try await tool.execute(
            input: ToolInput(toolName: "fanout.run", argumentsJSON: #"{"subtasks":[{"title":"A","prompt":"p"}]}"#),
            context: ToolContext(conversationID: UUID())
        )

        // The honest disabled copy names the [fanout] opt-in so the rejection
        // reads as its own guidance; no worker turn or audit row was spent.
        #expect(output.isError)
        #expect(output.content.contains("Fan-out is disabled. Enable [fanout] to run parallel worker subtasks."))
        #expect(orchestrator.capturedInputs.isEmpty)
        #expect(runLogger.recordedRows.isEmpty)
    }

    @Test
    func `Kind filter surfaces the fanout worker rows end-to-end`() async throws {
        let orchestrator = CollectingFanOutOrchestrator(outputs: [
            "Prompt for A": "Done.",
            "Prompt for B": "Done."
        ])
        let runLogger = CapturingMergeRunLogger()
        let engine = makeMergeEngine(orchestrator: orchestrator, runLogger: runLogger)

        _ = try await engine.runFanOut(
            subtasks: [makeSubtask(title: "A"), makeSubtask(title: "B")],
            originSessionID: UUID()
        )

        // The kind filter applies before the limit so the fanout worker rows
        // are fetchable regardless of interleaving; the parent row rides its
        // own kind and settles ok beside them.
        let workers = runLogger.rowsMatching(kind: FanOutEngine.workerRowKind)
        #expect(workers.map(\.message) == ["B", "A"])
        #expect(workers.allSatisfy { $0.status == "ok" })
        let parent = runLogger.rowsMatching(kind: FanOutEngine.parentRowKind)
        #expect(parent.count == 1)
        #expect(parent.first?.status == "ok")
    }
}

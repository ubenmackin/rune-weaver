// Rune Weaver Core Tests — Parallel worker fan-out engine and config.
//
// Exercises the fan-out stack with a stub orchestrator seam and a stub run
// logger: concurrent worker turns on fresh sessions carrying the
// fanout_worker source, the parent plus child run rows with their terminal
// status flips, the cap and empty-list rejections, the bounded wall-clock
// timeout marking a worker failed with an honest note, the allowedTools
// subset carried verbatim to workers plus the deterministic registry filter,
// and the parent settling when every subtask settles. Configuration coverage
// pins the additive `[fanout]` section defaults, decoding, round-trips,
// bounds, and the clamped posture. Tests never touch the real run-log store
// or the live orchestrator.

import Foundation
import os
@testable import RuneWeaverCore
import Testing

/// Stub seam recording every worker input it receives so tests can pin what
/// the engine actually handed to the orchestrator.
private final class CapturingFanOutOrchestrator: OrchestratorFanOutSeam {
    /// Guarded captured inputs in arrival order.
    private let inputs = OSAllocatedUnfairLock<[UserInput]>(initialState: [])
    /// Artificial turn delay so concurrency and timeouts stay exercisable.
    private let delaySeconds: Double
    /// Error reasons thrown per prompt; a prompt with no entry succeeds.
    private let failures: [String: String]

    /// Creates a capturing stub.
    /// - Parameters:
    ///   - delaySeconds: Artificial delay per turn.
    ///   - failures: Error reasons thrown per prompt.
    init(delaySeconds: Double = 0, failures: [String: String] = [:]) {
        self.delaySeconds = delaySeconds
        self.failures = failures
    }

    /// Inputs observed so far, oldest first.
    var capturedInputs: [UserInput] {
        inputs.withLock { $0 }
    }

    /// Records the input, delays, then succeeds or throws the canned reason.
    func process(_ input: UserInput) async throws {
        inputs.withLock { $0.append(input) }
        if delaySeconds > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
        }
        if let reason = failures[input.text] {
            throw FanOutStubError(reason: reason)
        }
    }
}

/// Probe seam recording the widest in-flight turn count so tests can pin
/// concurrent execution structurally instead of with wall-clock assertions.
private final class ConcurrentProbeOrchestrator: OrchestratorFanOutSeam {
    /// Guarded probe counters.
    private struct ProbeState: Sendable {
        var inFlight = 0
        var maxInFlight = 0
    }

    private let state = OSAllocatedUnfairLock<ProbeState>(initialState: ProbeState())
    /// Artificial turn delay so the first worker is still in flight while its
    /// siblings start.
    private let delaySeconds: Double

    /// Creates a probe stub.
    /// - Parameter delaySeconds: Artificial delay per turn.
    init(delaySeconds: Double) {
        self.delaySeconds = delaySeconds
    }

    /// Widest in-flight turn count observed.
    var maxInFlight: Int {
        state.withLock { $0.maxInFlight }
    }

    /// Bumps the in-flight counter, delays, then drops it again.
    func process(_: UserInput) async throws {
        state.withLock { probe in
            probe.inFlight += 1
            probe.maxInFlight = max(probe.maxInFlight, probe.inFlight)
        }
        try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
        state.withLock { probe in
            probe.inFlight -= 1
        }
    }
}

/// Stub seam whose turn never yields, finishes, or reacts to cancellation, so
/// only the timeout side of the race can settle a worker.
private final class HangingFanOutOrchestrator: OrchestratorFanOutSeam {
    /// Awaits a stream that never yields, so the turn never returns and the
    /// timeout alone can settle the worker.
    func process(_: UserInput) async throws {
        let stream = AsyncStream<Void> { _ in }
        for await _ in stream {}
    }
}

/// Stub run logger recording rows and updates so tests can pin the audit
/// trail the engine actually wrote.
private final class CapturingFanOutRunLogger: FanOutRunLogging {
    /// One recorded run row with its latest status.
    struct Row: Sendable {
        let id: UUID
        let kind: String
        let message: String
        let sessionID: UUID
        var status: String
    }

    /// Guarded rows in append order.
    private let rows = OSAllocatedUnfairLock<[Row]>(initialState: [])

    /// Rows in append order with their latest status.
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
        rows.withLock { captured in
            guard let index = captured.firstIndex(where: { $0.id == id }) else { return }
            captured[index].status = status
        }
    }
}

/// Minimal tool doubles for the registry filter test, carrying distinct
/// permission tiers so the read-only derivation is observable.
private struct FakeFanOutTool: Tool {
    let name: String
    let description: String
    let inputSchema: JSONSchema
    let permissionLevel: PermissionLevel

    /// Runs nothing; the filter tests never execute a tool.
    func execute(input _: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        ToolOutput(content: "ok")
    }
}

/// Creates a fan-out engine over the given stubs with the default behavior
/// knobs (workers=2, unlimited timeout, read-only subset) unless the caller
/// widens them.
private func makeFanOutEngine(
    orchestrator: OrchestratorFanOutSeam,
    runLogger: FanOutRunLogging,
    configure: (inout FanOutConfig) -> Void = { _ in }
) -> FanOutEngine {
    var config = FanOutConfig()
    configure(&config)
    return FanOutEngine(orchestrator: orchestrator, runLogs: runLogger, config: config)
}

/// Builds one subtask for engine tests.
private func makeSubtask(title: String, prompt: String? = nil) -> FanOutSubtask {
    FanOutSubtask(title: title, prompt: prompt ?? "Prompt for \(title)")
}

@Suite("FanOutEngine")
struct FanOutEngineTests {
    @Test
    func `FanOutConfig defaults carry behavior knobs only with a bounded worker cap`() {
        let config = FanOutConfig()
        #expect(config.maxWorkers == 2)
        #expect(config.workerTimeoutSeconds == 0)
        #expect(config.fullTools == false)
        #expect(RuneWeaverConfig.default.fanOut == FanOutConfig())
    }

    @Test
    func `Absent fanout section decodes to defaults`() throws {
        let text = """
        [llm]
        default_provider = "mlx"
        [llm.providers.mlx]
        enabled = true
        model = "gemma-4-9b"
        server_url = "http://localhost:8080"
        """
        let config = try RuneWeaverConfig(decoding: TOMLParser.parse(text))
        #expect(config.fanOut == FanOutConfig())
        try config.validate()
    }

    @Test
    func `Explicit fanout section decodes and round-trips`() throws {
        let text = """
        [llm]
        default_provider = "mlx"
        [llm.providers.mlx]
        enabled = true
        model = "gemma-4-9b"
        server_url = "http://localhost:8080"
        [fanout]
        max_workers = 6
        worker_timeout_seconds = 120
        full_tools = true
        """
        let config = try RuneWeaverConfig(decoding: TOMLParser.parse(text))
        #expect(config.fanOut.maxWorkers == 6)
        #expect(config.fanOut.workerTimeoutSeconds == 120)
        #expect(config.fanOut.fullTools == true)
        try config.validate()

        var roundTrip = RuneWeaverConfig.default
        roundTrip.fanOut = config.fanOut
        let rendered = roundTrip.renderTOML()
        #expect(rendered.contains("[fanout]"))
        #expect(rendered.contains("max_workers = 6"))
        #expect(rendered.contains("worker_timeout_seconds = 120"))
        #expect(rendered.contains("full_tools = true"))
        let reparsed = try RuneWeaverConfig(decoding: TOMLParser.parse(rendered))
        #expect(reparsed.fanOut == config.fanOut)
        try reparsed.validate()
    }

    @Test
    func `Fanout validation bounds the worker cap and timeout`() {
        expectFanOutValidationFailure({ $0.maxWorkers = 0 }, field: "fanout.max_workers")
        expectFanOutValidationFailure({ $0.maxWorkers = FanOutConfig.maxMaxWorkers + 1 }, field: "fanout.max_workers")
        expectFanOutValidationFailure({ $0.workerTimeoutSeconds = -5 }, field: "fanout.worker_timeout_seconds")
        expectFanOutValidationFailure(
            { $0.workerTimeoutSeconds = FanOutConfig.maxWorkerTimeoutSeconds + 1 },
            field: "fanout.worker_timeout_seconds"
        )
    }

    @Test
    func `Fanout clamped pulls hand-built values inside bounds`() {
        let clamped = FanOutConfig(maxWorkers: 99, workerTimeoutSeconds: 0, fullTools: true).clamped()
        #expect(clamped.maxWorkers == FanOutConfig.maxMaxWorkers)
        #expect(clamped.workerTimeoutSeconds == FanOutConfig.unlimitedWorkerTimeoutSeconds)
        #expect(clamped.fullTools == true)
    }

    @Test
    func `Fan-out spawns worker turns on fresh sessions with the fanout_worker source and run rows`() async throws {
        let orchestrator = CapturingFanOutOrchestrator()
        let runLogger = CapturingFanOutRunLogger()
        let engine = makeFanOutEngine(orchestrator: orchestrator, runLogger: runLogger) {
            $0.maxWorkers = 3
        }
        let origin = UUID()
        let subtasks = [
            makeSubtask(title: "Research A"),
            makeSubtask(title: "Research B"),
            makeSubtask(title: "Research C")
        ]

        let run = try await engine.runFanOut(subtasks: subtasks, originSessionID: origin)

        // Worker turns: one per subtask, each on its own fresh session so
        // histories never interleave, and each carrying the worker source.
        let captured = orchestrator.capturedInputs
        #expect(captured.count == 3)
        #expect(Set(captured.map(\.text)) == Set(subtasks.map(\.prompt)))
        #expect(Set(captured.map(\.sessionID)).count == 3)
        #expect(captured.allSatisfy { $0.sessionID != origin })
        #expect(captured.allSatisfy { $0.source == FanOutEngine.workerSource })

        // Parent run: the origin link rides the parent session field.
        #expect(run.parentSessionID == origin)

        // Audit trail: one parent row plus one child row per worker, each
        // flipped to a terminal status, and the parent row carries the joined
        // titles while child rows carry their own title.
        let rows = runLogger.recordedRows
        #expect(rows.count == 4)
        #expect(rows.first?.kind == FanOutEngine.parentRowKind)
        #expect(rows.first?.message == "Research A; Research B; Research C")
        #expect(rows.first?.sessionID == origin)
        #expect(rows.dropFirst().map(\.kind) == Array(repeating: FanOutEngine.workerRowKind, count: 3))
        #expect(rows.dropFirst().map(\.message) == ["Research A", "Research B", "Research C"])
        #expect(rows.dropFirst().allSatisfy { $0.status == "ok" })
        #expect(Set(rows.dropFirst().map(\.sessionID)) == Set(captured.map(\.sessionID)))
    }

    @Test
    func `Parent completes when all subtasks settle`() async throws {
        let orchestrator = CapturingFanOutOrchestrator()
        let runLogger = CapturingFanOutRunLogger()
        let engine = makeFanOutEngine(orchestrator: orchestrator, runLogger: runLogger)

        let run = try await engine.runFanOut(
            subtasks: [makeSubtask(title: "A"), makeSubtask(title: "B")],
            originSessionID: UUID()
        )

        #expect(run.status == .completed)
        #expect(run.subtasks.allSatisfy { $0.status == .done })
        #expect(run.summary == "All 2 subtasks completed.")
    }

    @Test
    func `A failed worker settles the parent failed with an honest digest`() async throws {
        let orchestrator = CapturingFanOutOrchestrator(failures: ["Prompt for B": "boom"])
        let runLogger = CapturingFanOutRunLogger()
        let engine = makeFanOutEngine(orchestrator: orchestrator, runLogger: runLogger)

        let run = try await engine.runFanOut(
            subtasks: [makeSubtask(title: "A"), makeSubtask(title: "B")],
            originSessionID: UUID()
        )

        #expect(run.status == .failed)
        #expect(run.subtasks.first { $0.title == "A" }?.status == .done)
        #expect(run.subtasks.first { $0.title == "B" }?.status == .failed)
        // The digest names the count and the failure cause so the caller
        // renders an honest summary instead of a bare failure.
        #expect(run.summary?.contains("1/2 subtasks completed") == true)
        #expect(run.summary?.contains("boom") == true)
    }

    @Test
    func `Cap rejects a list over the configured workers before any turn`() async throws {
        let orchestrator = CapturingFanOutOrchestrator()
        let runLogger = CapturingFanOutRunLogger()
        let engine = makeFanOutEngine(orchestrator: orchestrator, runLogger: runLogger) {
            $0.maxWorkers = 2
        }

        do {
            _ = try await engine.runFanOut(
                subtasks: [makeSubtask(title: "A"), makeSubtask(title: "B"), makeSubtask(title: "C")],
                originSessionID: UUID()
            )
            Issue.record("Expected maxWorkersReached rejection")
        } catch let error as FanOutError {
            #expect(error == .maxWorkersReached(limit: 2))
        }
        #expect(orchestrator.capturedInputs.isEmpty)
        #expect(runLogger.recordedRows.isEmpty)
    }

    @Test
    func `Default config runs without an availability gate`() async throws {
        let orchestrator = CapturingFanOutOrchestrator()
        let runLogger = CapturingFanOutRunLogger()
        // Single-gate contract: availability flows through tool registration
        // alone, so a default-config engine always runs its subtasks.
        let engine = FanOutEngine(orchestrator: orchestrator, runLogs: runLogger, config: FanOutConfig())

        let run = try await engine.runFanOut(
            subtasks: [makeSubtask(title: "A")],
            originSessionID: UUID()
        )

        #expect(run.status == .completed)
        #expect(orchestrator.capturedInputs.count == 1)
        #expect(runLogger.recordedRows.count == 2)
    }

    @Test
    func `Empty subtask list is rejected before any worker turn`() async throws {
        let orchestrator = CapturingFanOutOrchestrator()
        let runLogger = CapturingFanOutRunLogger()
        let engine = makeFanOutEngine(orchestrator: orchestrator, runLogger: runLogger)

        do {
            _ = try await engine.runFanOut(subtasks: [], originSessionID: UUID())
            Issue.record("Expected emptySubtasks rejection")
        } catch let error as FanOutError {
            #expect(error == .emptySubtasks)
        }
        #expect(orchestrator.capturedInputs.isEmpty)
    }

    @Test
    func `Timeout marks a worker failed with an honest note`() async throws {
        let runLogger = CapturingFanOutRunLogger()
        var config = FanOutConfig()
        config.workerTimeoutSeconds = 1
        let engine = FanOutEngine(orchestrator: HangingFanOutOrchestrator(), runLogs: runLogger, config: config)

        let run = try await engine.runFanOut(
            subtasks: [makeSubtask(title: "Slow research")],
            originSessionID: UUID()
        )

        // The timed-out worker reads failed and the digest names the timeout
        // honestly; the parent settles (never stays running) once it lands.
        #expect(run.subtasks.first?.status == .failed)
        #expect(run.status != .running)
        #expect(run.summary?.contains("timed out after 1s") == true)
        let rows = runLogger.recordedRows
        #expect(rows.count == 2)
        #expect(rows.dropFirst().allSatisfy { $0.status == "failed" })
    }

    @Test
    func `Workers run concurrently under the worker cap`() async throws {
        let orchestrator = ConcurrentProbeOrchestrator(delaySeconds: 0.15)
        let runLogger = CapturingFanOutRunLogger()
        let engine = makeFanOutEngine(orchestrator: orchestrator, runLogger: runLogger) {
            $0.maxWorkers = 3
        }

        _ = try await engine.runFanOut(
            subtasks: [makeSubtask(title: "A"), makeSubtask(title: "B"), makeSubtask(title: "C")],
            originSessionID: UUID()
        )

        // Workers overlap on the group so a slow worker never delays its
        // siblings; the probe records the widest in-flight turn count.
        #expect(orchestrator.maxInFlight >= 2)
    }

    @Test
    func `allowedTools travels verbatim to workers and the filter keeps only allowed names`() async throws {
        let orchestrator = CapturingFanOutOrchestrator()
        let runLogger = CapturingFanOutRunLogger()
        let engine = makeFanOutEngine(orchestrator: orchestrator, runLogger: runLogger)
        let allowed = ["web.search", "files.read"]

        _ = try await engine.runFanOut(
            subtasks: [makeSubtask(title: "Research")],
            originSessionID: UUID(),
            allowedTools: allowed
        )

        // The subset travels verbatim so the orchestrator's tool loop filters
        // its registry to the caller's subset before the loop.
        #expect(orchestrator.capturedInputs.first?.allowedTools == allowed)

        // The deterministic filter: an explicit subset keeps only matching
        // registry names in snapshot order; nil keeps the full registry.
        let snapshot = [
            FakeFanOutTool(name: "web.search", description: "s", inputSchema: .emptyObject, permissionLevel: .readOnly),
            FakeFanOutTool(name: "email.send", description: "s", inputSchema: .emptyObject, permissionLevel: .requiresApproval),
            FakeFanOutTool(name: "files.read", description: "s", inputSchema: .emptyObject, permissionLevel: .readOnly)
        ]
        let filtered = UserInput.filteredTools(snapshot, allowed: allowed)
        #expect(filtered.map(\.name) == ["web.search", "files.read"])
        #expect(UserInput.filteredTools(snapshot, allowed: nil).count == snapshot.count)
    }

    @Test
    func `Read-only derivation sorts the readOnly subset and omits mutating tiers`() {
        let snapshot = [
            FakeFanOutTool(name: "memories.store", description: "s", inputSchema: .emptyObject, permissionLevel: .trusted),
            FakeFanOutTool(name: "web.fetch", description: "s", inputSchema: .emptyObject, permissionLevel: .readOnly),
            FakeFanOutTool(name: "browser.act", description: "s", inputSchema: .emptyObject, permissionLevel: .requiresApproval),
            FakeFanOutTool(name: "files.read", description: "s", inputSchema: .emptyObject, permissionLevel: .readOnly)
        ]
        // Only readOnly tools travel; trusted tiers can still mutate, so
        // research fan-out must not carry them.
        #expect(FanOutEngine.readOnlyToolNames(in: snapshot) == ["files.read", "web.fetch"])
    }

    @Test
    func `UserInput tool subset round-trips through Codable`() throws {
        let input = UserInput(
            text: "research",
            sessionID: UUID(),
            source: "fanout_worker",
            allowedTools: ["web.search", "files.read"]
        )
        let encoded = try JSONEncoder().encode(input)
        let decoded = try JSONDecoder().decode(UserInput.self, from: encoded)
        #expect(decoded.allowedTools == ["web.search", "files.read"])

        // Inputs encoded before the subset existed decode with the full
        // registry instead of throwing.
        let legacy = #"{"text":"research","sessionID":"00000000-0000-0000-0000-000000000001","source":"text"}"#
        let legacyData = try #require(legacy.data(using: .utf8))
        let legacyDecoded = try JSONDecoder().decode(UserInput.self, from: legacyData)
        #expect(legacyDecoded.allowedTools == nil)
    }
}

/// Mutates one fanout field on a default config and asserts validation fails
/// with the expected dotted field name.
private func expectFanOutValidationFailure(
    _ mutate: (inout FanOutConfig) -> Void,
    field: String
) {
    var config = RuneWeaverConfig.default
    mutate(&config.fanOut)
    do {
        try config.validate()
        Issue.record("Expected ConfigError for \(field)")
    } catch let error as ConfigError {
        guard case let .validationError(failedField, _) = error else {
            Issue.record("Expected validationError, got \(error)")
            return
        }
        #expect(failedField == field)
    } catch {
        Issue.record("Expected ConfigError, got \(error)")
    }
}

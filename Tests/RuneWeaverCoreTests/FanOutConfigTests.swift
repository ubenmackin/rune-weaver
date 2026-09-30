// Rune Weaver Core Tests — Single-gate fan-out policy and unlimited timeout.
//
// Covers the `[fanout]` tuning section after availability moved to tool
// registration alone: stock defaults, TOML decode plus canonical render
// round-trip, tolerance of the retired `enabled` key, clamped bounds for
// hand-built configs, load-time validation of the timeout range, the
// zero-timeout worker path that awaits without a timeout race, and live
// policy swaps through the engine's config update. Tests run against stub
// orchestrator and run-log seams so no real model round or store is spent.

import Foundation
import os
@testable import RuneWeaverCore
import Testing

/// Stub seam delaying one canned turn so the timeout posture is observable.
private final class FanOutConfigStubOrchestrator: OrchestratorFanOutSeam {
    /// Artificial turn delay in seconds.
    private let delaySeconds: Double

    /// Creates a stub with one fixed delay.
    /// - Parameter delaySeconds: Delay applied to every turn.
    init(delaySeconds: Double = 0) {
        self.delaySeconds = delaySeconds
    }

    /// Records nothing and succeeds after the delay.
    func process(_: UserInput) async throws {
        if delaySeconds > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
        }
    }

    /// Succeeds after the delay with canned output text.
    func processCollecting(_ input: UserInput) async throws -> FanOutWorkerOutput {
        if delaySeconds > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
        }
        return FanOutWorkerOutput(text: "output for \(input.text)", isParked: false)
    }
}

/// Stub run logger recording rows so the audit trail stays observable.
private final class FanOutConfigStubLogger: FanOutRunLogging {
    /// One recorded row with its latest status.
    struct Row: Sendable {
        let id: UUID
        let kind: String
        var status: String
    }

    /// Guarded rows in append order.
    private let rows = OSAllocatedUnfairLock<[Row]>(initialState: [])

    /// Rows observed so far.
    var recordedRows: [Row] {
        rows.withLock { $0 }
    }

    @discardableResult
    func appendFanOutRow(kind: String, status: String, message _: String, sessionID _: UUID) async -> UUID {
        let id = UUID()
        rows.withLock { $0.append(Row(id: id, kind: kind, status: status)) }
        return id
    }

    func updateFanOutRow(id: UUID, status: String) async {
        rows.withLock { captured in
            guard let index = captured.firstIndex(where: { $0.id == id }) else { return }
            captured[index].status = status
        }
    }
}

/// Builds one subtask for config-suite engine runs.
private func makeConfigSubtask(title: String) -> FanOutSubtask {
    FanOutSubtask(title: title, prompt: "Prompt for \(title)")
}

/// Minimal `[llm]` prefix keeping config documents loadable in tests.
private let fanOutConfigTestLLMPrefix = """
[llm]
default_provider = "mlx"
[llm.providers.mlx]
enabled = true
model = "gemma-4-9b"
server_url = "http://localhost:8080"
"""

@Suite("FanOutConfig")
struct FanOutConfigTests {
    @Test
    func `Defaults tune a quiet swarm with no timeout`() {
        let config = FanOutConfig()
        #expect(config.maxWorkers == 2)
        #expect(config.workerTimeoutSeconds == 0)
        #expect(config.fullTools == false)
        #expect(FanOutConfig.defaultMaxWorkers == 2)
        #expect(FanOutConfig.defaultWorkerTimeoutSeconds == 0)
        #expect(FanOutConfig.unlimitedWorkerTimeoutSeconds == 0)
        #expect(FanOutConfig.maxWorkerTimeoutSeconds == 86400)
        #expect(RuneWeaverConfig.default.fanOut == FanOutConfig())
    }

    @Test
    func `Absent fanout table decodes to defaults`() throws {
        let config = try RuneWeaverConfig(decoding: TOMLParser.parse(fanOutConfigTestLLMPrefix))
        #expect(config.fanOut.maxWorkers == 2)
        #expect(config.fanOut.workerTimeoutSeconds == 0)
        #expect(config.fanOut.fullTools == false)
        try config.validate()
    }

    @Test
    func `Explicit knobs decode and round-trip without an enablement line`() throws {
        let text = fanOutConfigTestLLMPrefix + """
        \n[fanout]\nmax_workers = 6\nworker_timeout_seconds = 120\nfull_tools = true\n
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
        // The enablement line no longer renders; the section opens straight
        // onto the first tuning knob.
        #expect(!rendered.contains("[fanout]\nenabled"))
        let reparsed = try RuneWeaverConfig(decoding: TOMLParser.parse(rendered))
        #expect(reparsed.fanOut == config.fanOut)
        try reparsed.validate()
    }

    @Test
    func `Legacy enabled key loads and is ignored`() throws {
        // Older files still carry `enabled = true`; named-key reads skip it
        // so the file loads with the surviving knobs intact.
        let text = fanOutConfigTestLLMPrefix + """
        \n[fanout]\nenabled = true\nmax_workers = 3\nworker_timeout_seconds = 60\nfull_tools = false\n
        """
        let config = try RuneWeaverConfig(decoding: TOMLParser.parse(text))
        #expect(config.fanOut.maxWorkers == 3)
        #expect(config.fanOut.workerTimeoutSeconds == 60)
        #expect(config.fanOut.fullTools == false)
        try config.validate()
    }

    @Test
    func `Clamped folds caps and timeouts into bounds`() {
        // A non-positive timeout folds to unlimited instead of a one-second
        // floor, so slow local models are never cut off by a stale bound.
        let floored = FanOutConfig(maxWorkers: 0, workerTimeoutSeconds: -5, fullTools: false).clamped()
        #expect(floored.maxWorkers == FanOutConfig.minMaxWorkers)
        #expect(floored.workerTimeoutSeconds == FanOutConfig.unlimitedWorkerTimeoutSeconds)

        let zeroStays = FanOutConfig(maxWorkers: 2, workerTimeoutSeconds: 0, fullTools: false).clamped()
        #expect(zeroStays.workerTimeoutSeconds == 0)

        let capped = FanOutConfig(maxWorkers: 99, workerTimeoutSeconds: 100_000, fullTools: true).clamped()
        #expect(capped.maxWorkers == FanOutConfig.maxMaxWorkers)
        #expect(capped.workerTimeoutSeconds == FanOutConfig.maxWorkerTimeoutSeconds)
        #expect(capped.fullTools == true)

        let kept = FanOutConfig(maxWorkers: 4, workerTimeoutSeconds: 120, fullTools: false).clamped()
        #expect(kept.maxWorkers == 4)
        #expect(kept.workerTimeoutSeconds == 120)
    }

    @Test
    func `Validation accepts unlimited and rejects out-of-range timeouts`() throws {
        var unlimited = RuneWeaverConfig.default
        unlimited.fanOut.workerTimeoutSeconds = 0
        try unlimited.validate()

        var capped = RuneWeaverConfig.default
        capped.fanOut.workerTimeoutSeconds = FanOutConfig.maxWorkerTimeoutSeconds
        try capped.validate()

        var negative = RuneWeaverConfig.default
        negative.fanOut.workerTimeoutSeconds = -1
        do {
            try negative.validate()
            Issue.record("Expected validation failure for negative timeout")
        } catch let error as ConfigError {
            guard case let .validationError(field, _) = error else {
                Issue.record("Expected validationError, got \(error)")
                return
            }
            #expect(field == "fanout.worker_timeout_seconds")
        }

        var overlong = RuneWeaverConfig.default
        overlong.fanOut.workerTimeoutSeconds = FanOutConfig.maxWorkerTimeoutSeconds + 1
        do {
            try overlong.validate()
            Issue.record("Expected validation failure for overlong timeout")
        } catch let error as ConfigError {
            guard case let .validationError(field, _) = error else {
                Issue.record("Expected validationError, got \(error)")
                return
            }
            #expect(field == "fanout.worker_timeout_seconds")
        }
    }

    @Test
    func `Zero timeout awaits a slow worker without a timeout race`() async throws {
        // A 1.2s turn would lose a one-second race, so settling proves the
        // unlimited path awaits instead of racing a sleep task.
        let orchestrator = FanOutConfigStubOrchestrator(delaySeconds: 1.2)
        let runLogger = FanOutConfigStubLogger()
        let engine = FanOutEngine(
            orchestrator: orchestrator,
            runLogs: runLogger,
            config: FanOutConfig(maxWorkers: 2, workerTimeoutSeconds: 0)
        )

        let run = try await engine.runFanOut(
            subtasks: [makeConfigSubtask(title: "Slow research")],
            originSessionID: UUID()
        )

        #expect(run.status == .completed)
        #expect(run.subtasks.first?.status == .done)
    }

    @Test
    func `Engine applies hand-built config live through updateConfig`() async throws {
        let runLogger = FanOutConfigStubLogger()
        let engine = FanOutEngine(
            orchestrator: FanOutConfigStubOrchestrator(),
            runLogs: runLogger,
            config: FanOutConfig(maxWorkers: 2, workerTimeoutSeconds: 0, fullTools: false)
        )
        #expect(await engine.fullTools == false)

        await engine.updateConfig(FanOutConfig(maxWorkers: 2, workerTimeoutSeconds: 60, fullTools: true))
        #expect(await engine.fullTools == true)

        // A run still settles after the live swap, proving the stored policy
        // took effect without rebuilding the engine.
        let run = try await engine.runFanOut(
            subtasks: [makeConfigSubtask(title: "A")],
            originSessionID: UUID()
        )
        #expect(run.status == .completed)
    }
}

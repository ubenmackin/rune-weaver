// Rune Weaver Tools Tests — Fan-out tool ships-disabled registration and single-gate execution.
//
// Covers the fanout.run boot posture shared by every registration site: fresh
// installs list the tool disabled with the tool-state toggle as the sole
// authority, enabling through the toggle makes it visible in the enabled-only
// snapshot and runnable with no second gate, and workers keep the read-only
// subset unless the fanout tool settings widen them. Tests run against a stub
// orchestrator seam and a capturing run logger, never the live stack.

import Foundation
import os
@testable import RuneWeaverCore
@testable import RuneWeaverTools
import Testing

// MARK: - Test Doubles

/// Stub worker seam returning canned output text per prompt so the tool has a
/// real settled run to wrap in its envelope without spending model rounds.
private final class StubFanOutWorkerSeam: OrchestratorFanOutSeam {
    /// Guarded worker inputs in arrival order.
    private let inputs = OSAllocatedUnfairLock<[UserInput]>(initialState: [])
    /// Output text per prompt; a prompt with no entry produces no output.
    private let outputs: [String: String]

    /// Creates a stub seam.
    /// - Parameter outputs: Output text per worker prompt.
    init(outputs: [String: String] = [:]) {
        self.outputs = outputs
    }

    /// Inputs observed so far, oldest first.
    var capturedInputs: [UserInput] {
        inputs.withLock { $0 }
    }

    /// Runs one canned turn, discarding the output.
    func process(_ input: UserInput) async throws {
        _ = try await run(input)
    }

    /// Runs one canned turn and returns its output for the merge pass.
    func processCollecting(_ input: UserInput) async throws -> FanOutWorkerOutput {
        let text = try await run(input)
        return FanOutWorkerOutput(text: text, isParked: false)
    }

    /// Records the input and returns the canned output for its prompt.
    private func run(_ input: UserInput) async throws -> String {
        inputs.withLock { $0.append(input) }
        return outputs[input.text] ?? ""
    }
}

/// Stub run logger recording rows so the engine settles without the real store.
private final class StubFanOutRunLog: FanOutRunLogging {
    /// Guarded row statuses by identifier.
    private let statuses = OSAllocatedUnfairLock<[UUID: String]>(initialState: [:])

    @discardableResult
    func appendFanOutRow(kind _: String, status: String, message _: String, sessionID _: UUID) async -> UUID {
        let id = UUID()
        statuses.withLock { $0[id] = status }
        return id
    }

    func updateFanOutRow(id: UUID, status: String) async {
        statuses.withLock { $0[id] = status }
    }

    func updateFanOutRow(id: UUID, status: String, response _: String?, durationMs _: Int?) async {
        statuses.withLock { $0[id] = status }
    }
}

/// Builds a fan-out engine over stub collaborators with stock configuration.
private func makeStubFanOutEngine(seam: StubFanOutWorkerSeam, logs: StubFanOutRunLog) -> FanOutEngine {
    FanOutEngine(orchestrator: seam, runLogs: logs, config: FanOutConfig())
}

/// Registers the full built-in suite over a stub fan-out engine on a fresh bus.
private func makeFreshBus(seam: StubFanOutWorkerSeam, logs: StubFanOutRunLog) async throws -> ToolBus {
    let policyStore = await ToolsTestSupport.makeTestPolicyStore()
    let engine = makeStubFanOutEngine(seam: seam, logs: logs)
    let bus = ToolBus()
    try await BuiltinToolPlugins.registerAll(on: bus, fanOutEngine: engine, policyStore: policyStore)
    return bus
}

@Suite("FanOutTool")
struct FanOutToolTests {
    @Test
    func `Ships-disabled set pins the desktop, fanout, and agent tools`() {
        // Single-source contract: every fresh-registration site consumes this
        // set, so the boot paths cannot drift on which tools ship disabled.
        #expect(BuiltinToolPlugins.shipsDisabledToolNames == ["desktop.screenshot", "desktop.action", "fanout.run", "tool.promote", "tool.run"])
    }

    @Test
    func `Fresh registration ships fanout.run disabled`() async throws {
        // Fresh-boot contract: the tool is listed but not live, matching the
        // desktop posture — visible in `GET /tools` while absent from the
        // model's enabled-only snapshot.
        let bus = try await makeFreshBus(seam: StubFanOutWorkerSeam(), logs: StubFanOutRunLog())

        #expect(await bus.tool(named: "fanout.run") != nil)
        #expect(await bus.isToolEnabled(named: "fanout.run") == false)
        #expect(await bus.availableTools().contains { $0.name == "fanout.run" } == false)
        #expect(await bus.allTools().contains { $0.name == "fanout.run" })
        // Desktop parity: the same registration pass keeps the older members
        // of the set disabled alongside the fan-out tool.
        #expect(await bus.isToolEnabled(named: "desktop.screenshot") == false)
        #expect(await bus.isToolEnabled(named: "desktop.action") == false)
    }

    @Test
    func `Enabling via the tool-state toggle makes fanout.run callable with no second gate`() async throws {
        // Single-gate contract: one operator enable is the only step before the
        // tool runs — no config-shaped rejection follows the toggle.
        let seam = StubFanOutWorkerSeam(outputs: ["Prompt for A": "Done A."])
        let bus = try await makeFreshBus(seam: seam, logs: StubFanOutRunLog())

        await bus.enableTool(named: "fanout.run")
        #expect(await bus.isToolEnabled(named: "fanout.run") == true)
        #expect(await bus.availableTools().contains { $0.name == "fanout.run" })

        let tool = try #require(await bus.tool(named: "fanout.run"))
        let output = try await tool.execute(
            input: ToolInput(toolName: "fanout.run", argumentsJSON: #"{"subtasks":[{"title":"A","prompt":"Prompt for A"}]}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(!output.isError)
        #expect(!output.content.contains("Fan-out is disabled"))
        let data = try #require(output.content.data(using: .utf8))
        let envelope = try JSONDecoder().decode(FanOutRunEnvelope.self, from: data)
        #expect(envelope.status == "completed")
        #expect(!envelope.runID.isEmpty)
        // The worker turn actually ran exactly once behind the enabled tool.
        #expect(seam.capturedInputs.count == 1)
    }

    @Test
    func `Disabled fanout.run never appears in the enabled-only snapshot`() async throws {
        // Snapshot contract: the model only sees enabled tools, so a disabled
        // fan-out install contributes no worker entry point to the prompt while
        // staying inspectable in the full listing.
        let bus = try await makeFreshBus(seam: StubFanOutWorkerSeam(), logs: StubFanOutRunLog())

        let enabledNames = await bus.availableTools().map(\.name)
        #expect(!enabledNames.contains("fanout.run"))
        let allNames = await bus.allTools().map(\.name)
        #expect(allNames.contains("fanout.run"))
    }

    @Test
    func `Fanout tool documents the fanout tool settings and stays approval-gated`() {
        // Copy contract: the model-facing text points at the tool settings
        // surface rather than a config section, while the approval bargain and
        // the read-only worker subset stay exactly as before.
        let engine = makeStubFanOutEngine(seam: StubFanOutWorkerSeam(), logs: StubFanOutRunLog())
        let tool = FanOutTool(engine: engine, allowedToolNames: ["files.read"])

        #expect(tool.permissionLevel == .requiresApproval)
        #expect(tool.description.contains("fanout tool settings"))
        #expect(!tool.description.contains("[fanout]"))
    }

    @Test
    func `Workers receive the read-only subset the tool was built with`() async throws {
        // Subset contract: the tool carries its registration-time read-only
        // names verbatim into each worker turn, so research fan-out cannot
        // mutate state through a widened worker.
        let seam = StubFanOutWorkerSeam(outputs: ["Prompt for A": "Done A."])
        let logs = StubFanOutRunLog()
        let engine = makeStubFanOutEngine(seam: seam, logs: logs)
        let tool = try #require(FanOutTools.makeTools(engine: engine, allowedToolNames: ["files.read"]).first)

        let output = try await tool.execute(
            input: ToolInput(toolName: "fanout.run", argumentsJSON: #"{"subtasks":[{"title":"A","prompt":"Prompt for A"}]}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(!output.isError)
        #expect(seam.capturedInputs.count == 1)
        #expect(seam.capturedInputs.first?.allowedTools == ["files.read"])
    }
}

// Rune Weaver Core Tests — CPU and memory bounds for shell execution.

import Foundation
@testable import RuneWeaverCore
@testable import RuneWeaverTools
import Testing

/// Minimal `[llm]` prefix keeping config documents loadable in tests.
private let bashBoundsTestLLMPrefix = """
[llm]
default_provider = "mlx"
[llm.providers.mlx]
enabled = true
model = "gemma-4-9b"
server_url = "http://localhost:8080"
"""

/// Creates an isolated temporary directory for one shell fixture.
private func makeBashBoundsTempBase() throws -> URL {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("runeweaver-bash-bounds-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
}

/// Removes a temporary directory without failing the test on cleanup errors.
private func removeBashBoundsTempBase(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

/// Builds a shell tool rooted in an isolated workspace so fixtures never
/// touch the operator's real scratch directory.
private func makeBashBoundsTool(bashConfig: BashConfig, base: URL) -> BashTool {
    let root = base.appendingPathComponent("ws", isDirectory: true)
    let store = WorkspaceStore(config: WorkspaceConfig(), rootURL: root)
    return BashTool(
        bashConfig: bashConfig,
        filesConfig: FilesConfig(),
        allowUnsandboxedFallback: true,
        workspaceConfig: WorkspaceConfig(),
        workspaceStore: store
    )
}

/// Shell policy allowing every command so fixtures exercise limits, not gates.
private func allowAllBashConfig(
    timeoutSeconds: Int = 30,
    cpuSeconds: Int = 120,
    memoryMB: Int = 1024
) -> BashConfig {
    BashConfig(
        defaultAction: .allow,
        rules: [BashRule(pattern: "*", action: .allow)],
        timeoutSeconds: timeoutSeconds,
        cpuSeconds: cpuSeconds,
        memoryMB: memoryMB
    )
}

/// Decodes a shell envelope from tool output content.
private func decodeBashBoundsEnvelope(_ content: String) throws -> BashResultEnvelope {
    try JSONDecoder().decode(BashResultEnvelope.self, from: Data(content.utf8))
}

@Suite("BashBoundsConfig")
struct BashBoundsConfigTests {
    @Test
    func `Stock config carries documented resource defaults`() {
        let config = BashConfig()
        #expect(config.cpuSeconds == 120)
        #expect(config.memoryMB == 1024)
        #expect(BashConfig.defaultCPUSeconds == 120)
        #expect(BashConfig.defaultMemoryMB == 1024)
        #expect(BashConfig.minCPUSeconds == 1)
        #expect(BashConfig.maxCPUSeconds == 3600)
        #expect(BashConfig.minMemoryMB == 64)
        #expect(BashConfig.maxMemoryMB == 8192)
        // The wall-clock default stays untouched beside the new bounds.
        #expect(config.timeoutSeconds == 30)
        #expect(RuneWeaverConfig.default.bash == BashConfig())
    }

    @Test
    func `Absent bash keys decode to defaults`() throws {
        let config = try RuneWeaverConfig(decoding: TOMLParser.parse(bashBoundsTestLLMPrefix))
        #expect(config.bash.cpuSeconds == 120)
        #expect(config.bash.memoryMB == 1024)
        #expect(config.bash.timeoutSeconds == 30)
        try config.validate()
    }

    @Test
    func `Explicit bounds decode and round-trip`() throws {
        let text = bashBoundsTestLLMPrefix + """
        \n[bash]\nenabled = true\ndefault_action = "allow"\ntimeout_seconds = 45\nallow_network = false\ncpu_seconds = 60\nmemory_mb = 512\n
        """
        let config = try RuneWeaverConfig(decoding: TOMLParser.parse(text))
        #expect(config.bash.cpuSeconds == 60)
        #expect(config.bash.memoryMB == 512)
        #expect(config.bash.timeoutSeconds == 45)
        try config.validate()

        var roundTrip = RuneWeaverConfig.default
        roundTrip.bash = config.bash
        let rendered = roundTrip.renderTOML()
        #expect(rendered.contains("cpu_seconds = 60"))
        #expect(rendered.contains("memory_mb = 512"))
        #expect(rendered.contains("timeout_seconds = 45"))
        let reparsed = try RuneWeaverConfig(decoding: TOMLParser.parse(rendered))
        #expect(reparsed.bash == config.bash)
        try reparsed.validate()
    }

    @Test
    func `Clamped folds resource bounds into range`() {
        let floored = BashConfig(cpuSeconds: 0, memoryMB: 1).clamped()
        #expect(floored.cpuSeconds == BashConfig.minCPUSeconds)
        #expect(floored.memoryMB == BashConfig.minMemoryMB)

        let capped = BashConfig(cpuSeconds: 99999, memoryMB: 99999).clamped()
        #expect(capped.cpuSeconds == BashConfig.maxCPUSeconds)
        #expect(capped.memoryMB == BashConfig.maxMemoryMB)

        let kept = BashConfig(cpuSeconds: 60, memoryMB: 512).clamped()
        #expect(kept.cpuSeconds == 60)
        #expect(kept.memoryMB == 512)
    }

    @Test
    func `Validation rejects out-of-range bounds`() throws {
        var smallCPU = RuneWeaverConfig.default
        smallCPU.bash.cpuSeconds = BashConfig.minCPUSeconds - 1
        do {
            try smallCPU.validate()
            Issue.record("Expected validation failure for small cpu_seconds")
        } catch let error as ConfigError {
            guard case let .validationError(field, _) = error else {
                Issue.record("Expected validationError, got \(error)")
                return
            }
            #expect(field == "bash.cpu_seconds")
        }

        var largeCPU = RuneWeaverConfig.default
        largeCPU.bash.cpuSeconds = BashConfig.maxCPUSeconds + 1
        do {
            try largeCPU.validate()
            Issue.record("Expected validation failure for large cpu_seconds")
        } catch let error as ConfigError {
            guard case let .validationError(field, _) = error else {
                Issue.record("Expected validationError, got \(error)")
                return
            }
            #expect(field == "bash.cpu_seconds")
        }

        var smallMemory = RuneWeaverConfig.default
        smallMemory.bash.memoryMB = BashConfig.minMemoryMB - 1
        do {
            try smallMemory.validate()
            Issue.record("Expected validation failure for small memory_mb")
        } catch let error as ConfigError {
            guard case let .validationError(field, _) = error else {
                Issue.record("Expected validationError, got \(error)")
                return
            }
            #expect(field == "bash.memory_mb")
        }

        var largeMemory = RuneWeaverConfig.default
        largeMemory.bash.memoryMB = BashConfig.maxMemoryMB + 1
        do {
            try largeMemory.validate()
            Issue.record("Expected validation failure for large memory_mb")
        } catch let error as ConfigError {
            guard case let .validationError(field, _) = error else {
                Issue.record("Expected validationError, got \(error)")
                return
            }
            #expect(field == "bash.memory_mb")
        }
    }

    @Test
    func `Wrong-typed bounds throw instead of defaulting`() {
        let text = bashBoundsTestLLMPrefix + "\n[bash]\ncpu_seconds = \"fast\"\n"
        do {
            _ = try RuneWeaverConfig(decoding: TOMLParser.parse(text))
            Issue.record("Expected validation failure for string cpu_seconds")
        } catch let error as ConfigError {
            guard case let .validationError(field, _) = error else {
                Issue.record("Expected validationError, got \(error)")
                return
            }
            #expect(field == "bash.cpu_seconds")
        } catch {
            Issue.record("Expected ConfigError, got \(error)")
        }
    }
}

@Suite("BashBoundsPrefix")
struct BashBoundsPrefixTests {
    @Test
    func `Prefix carries configured values with kilobyte conversion`() {
        // 256 MB lands as kilobytes for `ulimit -v`, which counts 1024-byte blocks.
        let prefixed = BashTool.resourceLimitedCommand("echo hi", cpuSeconds: 5, memoryMB: 256, tier: .strictContainer)
        #expect(prefixed == "ulimit -t 5; ulimit -v 262144; echo hi")
        #expect(prefixed.hasPrefix("ulimit -t 5; ulimit -v 262144; "))
    }

    @Test
    func `Prefix clamps hand-built bounds instead of trapping`() {
        let floored = BashTool.resourceLimitedCommand("echo hi", cpuSeconds: 0, memoryMB: 1, tier: .strictContainer)
        #expect(floored == "ulimit -t 1; ulimit -v 65536; echo hi")

        let capped = BashTool.resourceLimitedCommand("echo hi", cpuSeconds: 99999, memoryMB: 99999, tier: .strictContainer)
        #expect(capped == "ulimit -t 3600; ulimit -v 8388608; echo hi")
    }

    @Test
    func `Host tier carries CPU time only`() {
        // Shared-library accounting over-reports address space on the host,
        // so the host prefix omits the memory bound that guests keep.
        let prefixed = BashTool.resourceLimitedCommand("echo hi", cpuSeconds: 5, memoryMB: 256, tier: .hostSeatbelt)
        #expect(prefixed == "ulimit -t 5; echo hi")
    }

    @Test
    func `Machine tier keeps both bounds`() {
        let prefixed = BashTool.resourceLimitedCommand("echo hi", cpuSeconds: 5, memoryMB: 256, tier: .machineScoped)
        #expect(prefixed == "ulimit -t 5; ulimit -v 262144; echo hi")
    }

    @Test
    func `Allowed echo still runs under the prefix`() async throws {
        let base = try makeBashBoundsTempBase()
        defer { removeBashBoundsTempBase(base) }
        let tool = makeBashBoundsTool(bashConfig: allowAllBashConfig(), base: base)
        let input = ToolInput(toolName: "bash.exec", argumentsJSON: #"{"command":"echo bound-ok"}"#)
        let output = try await tool.execute(input: input, context: ToolContext(conversationID: UUID()))
        #expect(!output.isError)
        #expect(output.content.contains("bound-ok"))
        let envelope = try decodeBashBoundsEnvelope(output.content)
        #expect(envelope.killReason == .clean)
        #expect(output.content.contains("\"kill_reason\":\"clean\""))
    }
}

@Suite("BashBoundsKillReason")
struct BashBoundsKillReasonTests {
    @Test
    func `Timeout flag outranks signal status`() {
        #expect(
            BashTool.killReason(
                didTimeOut: true,
                terminationReason: .uncaughtSignal,
                terminationStatus: 9
            ) == .wallTimeout
        )
        #expect(
            BashTool.killReason(
                didTimeOut: true,
                terminationReason: .exit,
                terminationStatus: 152
            ) == .wallTimeout
        )
    }

    @Test
    func `CPU-limit signals map to the resource bound`() {
        // Only the CPU-limit signal death counts outright: SIGKILL shares
        // its status with OOM, manual, and sandbox kills, so it stays
        // clean without CPU-limit corroboration.
        #expect(
            BashTool.killReason(
                didTimeOut: false,
                terminationReason: .uncaughtSignal,
                terminationStatus: 24
            ) == .resourceLimit
        )
        // A bare 152 stays clean: wrappers report signals as 128 + signal,
        // so a voluntary `exit 152` must not read as a limiter kill.
        #expect(
            BashTool.killReason(didTimeOut: false, terminationReason: .exit, terminationStatus: 152)
                == .clean
        )
        // The shell names the CPU bound on stderr even when the wrapper
        // normalizes the wait status, so 152 plus the diagnostic counts
        // without broadening every non-zero exit into a resource kill.
        #expect(
            BashTool.killReason(
                didTimeOut: false,
                terminationReason: .exit,
                terminationStatus: 152,
                stderr: "CPU time limit exceeded"
            ) == .resourceLimit
        )
        // The diagnostic alone is not enough: the same phrase with any
        // other exit (for example `exit 1`) stays clean.
        #expect(
            BashTool.killReason(
                didTimeOut: false,
                terminationReason: .exit,
                terminationStatus: 1,
                stderr: "CPU time limit exceeded"
            ) == .clean
        )
    }

    @Test
    func `SIGKILL stays clean without CPU-limit corroboration`() {
        // The contract is CPU-only: SIGKILL shares its status across OOM,
        // manual, and sandbox kills, so it stays clean even with a
        // memory-flavored diagnostic on stderr.
        #expect(
            BashTool.killReason(
                didTimeOut: false,
                terminationReason: .uncaughtSignal,
                terminationStatus: 9
            ) == .clean
        )
        #expect(
            BashTool.killReason(didTimeOut: false, terminationReason: .exit, terminationStatus: 137)
                == .clean
        )
        #expect(
            BashTool.killReason(
                didTimeOut: false,
                terminationReason: .uncaughtSignal,
                terminationStatus: 9,
                stderr: "Out of memory: Killed process"
            ) == .clean
        )
        #expect(
            BashTool.killReason(
                didTimeOut: false,
                terminationReason: .exit,
                terminationStatus: 137,
                stderr: "Killed"
            ) == .clean
        )
    }

    @Test
    func `Memory-limit deaths stay clean`() {
        // `ulimit -v` malloc failures surface as ordinary non-zero exits, so
        // they stay clean rather than reading as the CPU resource bound.
        #expect(
            BashTool.killReason(
                didTimeOut: false,
                terminationReason: .exit,
                terminationStatus: 1,
                stderr: "cannot allocate memory"
            ) == .clean
        )
        #expect(
            BashTool.killReason(
                didTimeOut: false,
                terminationReason: .exit,
                terminationStatus: 1,
                stderr: "malloc: Cannot allocate memory"
            ) == .clean
        )
    }

    @Test
    func `Ordinary exits stay clean`() {
        #expect(
            BashTool.killReason(didTimeOut: false, terminationReason: .exit, terminationStatus: 0)
                == .clean
        )
        #expect(
            BashTool.killReason(didTimeOut: false, terminationReason: .exit, terminationStatus: 1)
                == .clean
        )
    }

    @Test
    func `Self SIGXCPU kill reports the resource bound`() async throws {
        let base = try makeBashBoundsTempBase()
        defer { removeBashBoundsTempBase(base) }
        // The shell kills itself with SIGXCPU, exercising the same wait
        // status a CPU-limit death produces.
        let tool = makeBashBoundsTool(bashConfig: allowAllBashConfig(), base: base)
        let input = ToolInput(
            toolName: "bash.exec",
            argumentsJSON: #"{"command":"kill -XCPU $$"}"#
        )
        let output = try await tool.execute(input: input, context: ToolContext(conversationID: UUID()))
        #expect(output.isError)
        #expect(output.content.contains("\"kill_reason\":\"resource_limit\""))
        let envelope = try decodeBashBoundsEnvelope(output.content)
        #expect(envelope.killReason == .resourceLimit)
    }

    @Test
    func `Sleep past the wall watchdog reports a wall timeout`() async throws {
        let base = try makeBashBoundsTempBase()
        defer { removeBashBoundsTempBase(base) }
        // Sleep accrues almost no CPU time, so the one-second wall watchdog
        // ends it while the generous CPU budget stays untouched.
        let tool = makeBashBoundsTool(bashConfig: allowAllBashConfig(), base: base)
        let input = ToolInput(
            toolName: "bash.exec",
            argumentsJSON: #"{"command":"sleep 5","timeoutSeconds":1}"#
        )
        let output = try await tool.execute(input: input, context: ToolContext(conversationID: UUID()))
        #expect(output.isError)
        #expect(output.content.contains("\"kill_reason\":\"wall_timeout\""))
        let envelope = try decodeBashBoundsEnvelope(output.content)
        #expect(envelope.killReason == .wallTimeout)
    }

    @Test
    func `Spinning loop dies by CPU limit, not the wall watchdog`() async throws {
        let base = try makeBashBoundsTempBase()
        defer { removeBashBoundsTempBase(base) }
        // One CPU-second against a ten-second wall proves the limit kills
        // first; a wall death here would mean the prefix never applied.
        let tool = makeBashBoundsTool(
            bashConfig: allowAllBashConfig(timeoutSeconds: 10, cpuSeconds: 1),
            base: base
        )
        let input = ToolInput(
            toolName: "bash.exec",
            argumentsJSON: #"{"command":"while true; do :; done"}"#
        )
        let output = try await tool.execute(
            input: input,
            context: ToolContext(conversationID: UUID(), approved: true)
        )
        #expect(output.isError)
        #expect(output.content.contains("\"kill_reason\":\"resource_limit\""))
        #expect(!output.content.contains("\"kill_reason\":\"wall_timeout\""))
        let envelope = try decodeBashBoundsEnvelope(output.content)
        #expect(envelope.killReason == .resourceLimit)
    }

    @Test
    func `Denied spawns report denied without executing`() async throws {
        let base = try makeBashBoundsTempBase()
        defer { removeBashBoundsTempBase(base) }
        let denied = BashConfig(
            defaultAction: .deny,
            rules: [
                BashRule(pattern: "*", action: .ask),
                BashRule(pattern: "rm", action: .deny)
            ]
        )
        let tool = makeBashBoundsTool(bashConfig: denied, base: base)
        let input = ToolInput(
            toolName: "bash.exec",
            argumentsJSON: #"{"command":"rm -rf /tmp/bounds-denied"}"#
        )
        let output = try await tool.execute(
            input: input,
            context: ToolContext(conversationID: UUID(), approved: true)
        )
        #expect(output.isError)
        #expect(output.content.contains("\"kill_reason\":\"denied\""))
        let envelope = try decodeBashBoundsEnvelope(output.content)
        #expect(envelope.killReason == .denied)
        #expect(envelope.denied)
    }

    @Test
    func `Per-call wall timeout still bounds beside the CPU budget`() async throws {
        let base = try makeBashBoundsTempBase()
        defer { removeBashBoundsTempBase(base) }
        // An out-of-range per-call timeout fails closed with the same bounds
        // the stored policy enforces, so model input cannot trap the watchdog.
        let tool = makeBashBoundsTool(bashConfig: allowAllBashConfig(), base: base)
        let badInput = ToolInput(
            toolName: "bash.exec",
            argumentsJSON: #"{"command":"echo hi","timeoutSeconds":0}"#
        )
        let badOutput = try await tool.execute(
            input: badInput,
            context: ToolContext(conversationID: UUID())
        )
        #expect(badOutput.isError)
        #expect(badOutput.content.contains("timeoutSeconds"))

        // A valid per-call timeout still wins over the stored default.
        let sleepInput = ToolInput(
            toolName: "bash.exec",
            argumentsJSON: #"{"command":"sleep 5","timeoutSeconds":1}"#
        )
        let sleepOutput = try await tool.execute(
            input: sleepInput,
            context: ToolContext(conversationID: UUID())
        )
        let envelope = try decodeBashBoundsEnvelope(sleepOutput.content)
        #expect(envelope.killReason == .wallTimeout)
    }
}

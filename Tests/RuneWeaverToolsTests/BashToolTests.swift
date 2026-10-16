// Rune Weaver Tools Tests — Sandboxed bash.exec tool, chaining detection, and fine-grained permissions.

import Foundation
@testable import RuneWeaverCore
@testable import RuneWeaverTools
import Testing

/// Builds an isolated workspace base under system temp for one hermetic test.
private func makeHermeticWorkspaceBase(label: String) throws -> URL {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("runeweaver-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
}

/// Removes an isolated workspace base without failing the test on cleanup errors.
private func removeHermeticWorkspaceBase(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

/// Builds a hermetic bash tool rooted in isolated scratch with a stubbed seam. The isolated root
/// forces the host fallback so turns never create containers, while the stubbed seam keeps any
/// isolated-tier probe hermetic.
private func makeHermeticBashTool(
    bashConfig: BashConfig,
    filesConfig: FilesConfig = FilesConfig(),
    egressSupervisor: OutboundEgressSupervisor? = nil,
    base: URL
) -> BashTool {
    let root = base.appendingPathComponent("ws", isDirectory: true)
    let store = WorkspaceStore(config: WorkspaceConfig(), rootURL: root)
    let (seam, _) = ContainerSeam.hermetic()
    return BashTool(
        bashConfig: bashConfig,
        filesConfig: filesConfig,
        allowUnsandboxedFallback: true,
        egressSupervisor: egressSupervisor,
        workspaceConfig: WorkspaceConfig(),
        workspaceStore: store,
        containers: seam
    )
}

@Suite("BashSecurity Chaining Detection")
struct BashChainingDetectionTests {
    @Test
    func `Simple single command is not chained`() {
        #expect(!BashSecurity.detectChaining(in: "echo hello"))
        #expect(!BashSecurity.detectChaining(in: "ls -la /tmp"))
        #expect(!BashSecurity.detectChaining(in: "git status --short"))
    }

    @Test
    func `Single-quoted strings preserve literal operators`() {
        #expect(!BashSecurity.detectChaining(in: "echo 'hello && world; test | pipe'"))
        #expect(!BashSecurity.detectChaining(in: "grep 'foo|bar' file.txt"))
    }

    @Test
    func `AND operator triggers chaining`() {
        #expect(BashSecurity.detectChaining(in: "echo hello && rm -rf /tmp/foo"))
    }

    @Test
    func `OR operator triggers chaining`() {
        #expect(BashSecurity.detectChaining(in: "grep needle file || echo fallback"))
    }

    @Test
    func `Semicolon triggers chaining`() {
        #expect(BashSecurity.detectChaining(in: "echo first; echo second"))
    }

    @Test
    func `Pipe triggers chaining`() {
        #expect(BashSecurity.detectChaining(in: "cat file.txt | grep secret"))
    }

    @Test
    func `Background execution triggers chaining`() {
        #expect(BashSecurity.detectChaining(in: "sleep 10 &"))
        #expect(BashSecurity.detectChaining(in: "echo background & echo foreground"))
    }

    @Test
    func `Redirection 2>&1 is not mistaken for background chaining`() {
        #expect(!BashSecurity.detectChaining(in: "echo message > /dev/null 2>&1"))
    }

    @Test
    func `Newline triggers chaining`() {
        #expect(BashSecurity.detectChaining(in: "echo line1\necho line2"))
        #expect(BashSecurity.detectChaining(in: "echo line1\r\necho line2"))
    }

    @Test
    func `Command substitution $(...) triggers chaining`() {
        #expect(BashSecurity.detectChaining(in: "echo $(whoami)"))
        #expect(BashSecurity.detectChaining(in: "echo \"User is $(whoami)\""))
    }

    @Test
    func `Backtick command substitution triggers chaining`() {
        #expect(BashSecurity.detectChaining(in: "echo `id`"))
        #expect(BashSecurity.detectChaining(in: "echo \"Result: `uname -a`\""))
    }

    @Test
    func `Subshell parentheses trigger chaining`() {
        #expect(BashSecurity.detectChaining(in: "(cd /tmp && pwd)"))
    }
}

@Suite("BashSecurity Pattern Matching")
struct BashPatternMatchingTests {
    @Test
    func `Star pattern matches anything`() {
        #expect(BashSecurity.matches(command: "echo hello", pattern: "*"))
        #expect(BashSecurity.matches(command: "rm -rf /", pattern: "*"))
        #expect(BashSecurity.matches(command: "git status", pattern: "*"))
    }

    @Test
    func `Exact command match with arguments`() {
        #expect(BashSecurity.matches(command: "git status", pattern: "git status"))
        #expect(BashSecurity.matches(command: "git status --short", pattern: "git status"))
        #expect(!BashSecurity.matches(command: "git commit -m msg", pattern: "git status"))
    }

    @Test
    func `Command prefix pattern matches binary and arguments`() {
        #expect(BashSecurity.matches(command: "echo", pattern: "echo"))
        #expect(BashSecurity.matches(command: "echo hello world", pattern: "echo"))
        #expect(!BashSecurity.matches(command: "echogram test", pattern: "echo"))
    }

    @Test
    func `Wildcard glob matching`() {
        #expect(BashSecurity.matches(command: "rm file.txt", pattern: "rm *"))
        #expect(BashSecurity.matches(command: "echo hello", pattern: "echo *"))
        #expect(BashSecurity.matches(command: "echo", pattern: "echo *"))
    }
}

@Suite("BashSecurity Policy Evaluation")
struct BashPolicyEvaluationTests {
    @Test
    func `Allow rule executes directly without asking`() {
        let config = BashConfig(
            rules: [
                BashRule(pattern: "*", action: .ask),
                BashRule(pattern: "echo", action: .allow)
            ]
        )
        let decision = BashSecurity.evaluate(command: "echo hello", config: config)
        #expect(decision.action == .allow)
        #expect(!decision.isChained)
        #expect(decision.isAllowed)
    }

    @Test
    func `Deny rule fails closed immediately`() {
        let config = BashConfig(
            rules: [
                BashRule(pattern: "*", action: .ask),
                BashRule(pattern: "rm*", action: .deny)
            ]
        )
        let decision = BashSecurity.evaluate(command: "rm -rf /tmp/test", config: config)
        #expect(decision.action == .deny)
        #expect(decision.isDenied)
    }

    @Test
    func `Chained command demotes allow to ask`() {
        let config = BashConfig(
            rules: [
                BashRule(pattern: "*", action: .deny),
                BashRule(pattern: "echo", action: .allow)
            ]
        )
        let decision = BashSecurity.evaluate(command: "echo hello && rm -rf /", config: config)
        #expect(decision.isChained)
        #expect(decision.action == .ask)
        #expect(decision.requiresApproval)
        #expect(decision.reason.contains("demoted to 'ask'"))
    }

    @Test
    func `Command substitution demotes allow to ask`() {
        let config = BashConfig(
            rules: [
                BashRule(pattern: "*", action: .deny),
                BashRule(pattern: "echo", action: .allow)
            ]
        )
        let decision = BashSecurity.evaluate(command: "echo $(cat /etc/passwd)", config: config)
        #expect(decision.isChained)
        #expect(decision.action == .ask)
    }

    @Test
    func `Deny rule on chained command stays denied`() {
        let config = BashConfig(
            rules: [
                BashRule(pattern: "*", action: .ask),
                BashRule(pattern: "rm*", action: .deny)
            ]
        )
        let decision = BashSecurity.evaluate(command: "rm -rf / && echo done", config: config)
        #expect(decision.isChained)
        #expect(decision.action == .deny)
        #expect(decision.isDenied)
    }

    @Test
    func `Default action is used when no rule matches`() {
        let config = BashConfig(
            defaultAction: .ask,
            rules: [
                BashRule(pattern: "echo", action: .allow)
            ]
        )
        let decision = BashSecurity.evaluate(command: "uname -a", config: config)
        #expect(decision.action == .ask)
        #expect(decision.matchedPattern == nil)
    }
}

@Suite("BashSecurity Last-Match Wins")
struct BashLastMatchWinsTests {
    @Test
    func `Catch-all deny first plus specific allow later allows`() {
        let config = BashConfig(
            defaultAction: .deny,
            rules: [
                BashRule(pattern: "*", action: .deny),
                BashRule(pattern: "swiftformat *", action: .allow)
            ]
        )
        let decision = BashSecurity.evaluate(command: "swiftformat .", config: config)
        #expect(decision.action == .allow)
        #expect(decision.isAllowed)
        #expect(!decision.isChained)
        #expect(decision.matchedPattern == "swiftformat *")
    }

    @Test
    func `Reversed order denies`() {
        let config = BashConfig(
            defaultAction: .allow,
            rules: [
                BashRule(pattern: "swiftformat *", action: .allow),
                BashRule(pattern: "*", action: .deny)
            ]
        )
        let decision = BashSecurity.evaluate(command: "swiftformat .", config: config)
        #expect(decision.action == .deny)
        #expect(decision.isDenied)
        #expect(decision.matchedPattern == "*")
    }

    @Test
    func `No match falls back to defaultAction`() {
        let askConfig = BashConfig(
            defaultAction: .ask,
            rules: [
                BashRule(pattern: "swiftformat *", action: .allow)
            ]
        )
        let askDecision = BashSecurity.evaluate(command: "echo hello", config: askConfig)
        #expect(askDecision.action == .ask)
        #expect(askDecision.matchedPattern == nil)

        let denyConfig = BashConfig(
            defaultAction: .deny,
            rules: [
                BashRule(pattern: "swiftformat *", action: .allow)
            ]
        )
        let denyDecision = BashSecurity.evaluate(command: "echo hello", config: denyConfig)
        #expect(denyDecision.action == .deny)
        #expect(denyDecision.matchedPattern == nil)
    }
}

@Suite("BashTool Execution")
struct BashToolExecutionTests {
    @Test
    func `Allowed command executes successfully and captures stdout`() async throws {
        let config = BashConfig(
            rules: [
                BashRule(pattern: "*", action: .ask),
                BashRule(pattern: "echo", action: .allow)
            ]
        )
        // Hermetic execution stays on the host fallback under isolated
        // scratch so the full suite creates zero containers.
        let base = try makeHermeticWorkspaceBase(label: "bash-exec")
        defer { removeHermeticWorkspaceBase(base) }
        let tool = makeHermeticBashTool(bashConfig: config, base: base)
        let sessionID = UUID()
        let input = ToolInput(
            toolName: "bash.exec",
            argumentsJSON: #"{"command":"echo Hello Rune Weaver"}"#
        )
        let context = ToolContext(conversationID: sessionID)
        let output = try await tool.execute(input: input, context: context)

        #expect(!output.isError)
        #expect(output.content.contains("Hello Rune Weaver"))
        #expect(output.content.contains("\"exitCode\":0"))
    }

    @Test
    func `Denied command returns failure without executing`() async throws {
        let config = BashConfig(
            rules: [
                BashRule(pattern: "*", action: .ask),
                BashRule(pattern: "rm*", action: .deny)
            ]
        )
        // Hermetic stub keeps the suite container-free; the deny parks before any spawn.
        let (hermeticSeam, _) = ContainerSeam.hermetic()
        let tool = BashTool(bashConfig: config, allowUnsandboxedFallback: true, containers: hermeticSeam)
        let input = ToolInput(
            toolName: "bash.exec",
            argumentsJSON: #"{"command":"rm -rf /tmp/testfile"}"#
        )
        let context = ToolContext(conversationID: UUID())
        let output = try await tool.execute(input: input, context: context)

        #expect(output.isError)
        #expect(output.content.contains("\"denied\":true"))
        #expect(output.content.contains("Command denied by security policy"))
    }

    @Test
    func `Ask command without confirmed returns approvalRequired`() async throws {
        let config = BashConfig(
            rules: [
                BashRule(pattern: "*", action: .ask)
            ]
        )
        // Hermetic stub keeps the suite container-free; the ask parks before any spawn.
        let (hermeticSeam, _) = ContainerSeam.hermetic()
        let tool = BashTool(bashConfig: config, allowUnsandboxedFallback: true, containers: hermeticSeam)
        let input = ToolInput(
            toolName: "bash.exec",
            argumentsJSON: #"{"command":"echo test ask"}"#
        )
        let context = ToolContext(conversationID: UUID())
        let output = try await tool.execute(input: input, context: context)

        // Ask decisions park in the approvals inbox via the permission gate;
        // no model-supplied argument can approve the command.
        #expect(output.isError)
        #expect(output.content.contains("\"approvalRequired\":true"))
        #expect(output.content.contains("Command requires approval"))
    }

    @Test
    func `Ask command with confirmed flag still requires approval`() async throws {
        let config = BashConfig(
            rules: [
                BashRule(pattern: "*", action: .ask)
            ]
        )
        // Hermetic stub keeps the suite container-free; the ask parks before any spawn.
        let (hermeticSeam, _) = ContainerSeam.hermetic()
        let tool = BashTool(bashConfig: config, allowUnsandboxedFallback: true, containers: hermeticSeam)
        let input = ToolInput(
            toolName: "bash.exec",
            argumentsJSON: #"{"command":"echo test confirmed","confirmed":true}"#
        )
        let context = ToolContext(conversationID: UUID())
        let output = try await tool.execute(input: input, context: context)

        // Model-supplied flags never self-approve; ask decisions park in the
        // approvals inbox via the permission gate.
        #expect(output.isError)
        #expect(output.content.contains("\"approvalRequired\":true"))
        #expect(output.content.contains("Command requires approval"))
    }

    @Test
    func `Chained command with allow rule requires approval`() async throws {
        let config = BashConfig(
            rules: [
                BashRule(pattern: "*", action: .ask),
                BashRule(pattern: "echo", action: .allow)
            ]
        )
        // Hermetic stub keeps the suite container-free; chaining parks before any spawn.
        let (hermeticSeam, _) = ContainerSeam.hermetic()
        let tool = BashTool(bashConfig: config, allowUnsandboxedFallback: true, containers: hermeticSeam)
        let input = ToolInput(
            toolName: "bash.exec",
            argumentsJSON: #"{"command":"echo one && echo two"}"#
        )
        let context = ToolContext(conversationID: UUID())
        let output = try await tool.execute(input: input, context: context)

        // Chained commands demote allow to ask so compound shell stays
        // fail-closed until a human approves via the inbox.
        #expect(output.isError)
        #expect(output.content.contains("\"approvalRequired\":true"))
        #expect(output.content.contains("\"isChained\":true"))
    }

    @Test
    func `Working directory cwd is respected`() async throws {
        let config = BashConfig(
            rules: [
                BashRule(pattern: "pwd", action: .allow)
            ]
        )
        let filesConfig = FilesConfig(allowRoots: ["~", "/tmp", "/private/tmp"])
        // Hermetic execution stays on the host fallback under isolated
        // scratch so the full suite creates zero containers.
        let base = try makeHermeticWorkspaceBase(label: "bash-cwd")
        defer { removeHermeticWorkspaceBase(base) }
        let tool = makeHermeticBashTool(bashConfig: config, filesConfig: filesConfig, base: base)
        let input = ToolInput(
            toolName: "bash.exec",
            argumentsJSON: #"{"command":"pwd","cwd":"/private/tmp"}"#
        )
        let context = ToolContext(conversationID: UUID())
        let output = try await tool.execute(input: input, context: context)

        #expect(!output.isError)
        #expect(output.content.contains("/private/tmp") || output.content.contains("/tmp"))
    }

    @Test
    func `Dry run preview returns decision without executing`() async throws {
        let config = BashConfig(
            rules: [
                BashRule(pattern: "echo", action: .allow)
            ]
        )
        // Hermetic stub keeps the suite container-free; dry run never spawns.
        let (hermeticSeam, _) = ContainerSeam.hermetic()
        let tool = BashTool(bashConfig: config, allowUnsandboxedFallback: true, containers: hermeticSeam)
        let input = ToolInput(
            toolName: "bash.exec",
            argumentsJSON: #"{"command":"echo dry run"}"#
        )
        let context = ToolContext(conversationID: UUID(), dryRun: true)
        let output = try await tool.execute(input: input, context: context)

        #expect(!output.isError)
        #expect(output.content.contains("Dry run preview"))
    }
}

/// Smoke-test contract for `bash.exec`: echo runs free, touch prompts then runs, rm never runs.
@Suite("Bash Smoke Contract")
struct BashSmokeContractTests {
    /// Allowed echo executes with no approval envelope.
    @Test
    func `echo Hello World executes without approval`() async throws {
        // Hermetic execution stays on the host fallback under isolated
        // scratch so the full suite creates zero containers.
        let base = try makeHermeticWorkspaceBase(label: "bash-smoke-echo")
        defer { removeHermeticWorkspaceBase(base) }
        let tool = makeHermeticBashTool(bashConfig: ToolsTestSupport.smokeBashConfig(), base: base)
        let sessionID = UUID()
        let input = ToolInput(
            toolName: "bash.exec",
            argumentsJSON: #"{"command":"echo Hello World"}"#
        )
        let output = try await tool.execute(input: input, context: ToolContext(conversationID: sessionID))

        #expect(!output.isError)
        #expect(output.content.contains("Hello World"))
        #expect(output.content.contains("\"exitCode\":0"))
        #expect(!output.content.contains("\"approvalRequired\":true"))
    }

    /// Touch parks until approved, then executes instead of enveloping.
    @Test
    func `approved touch executes instead of enveloping`() async throws {
        // Hermetic execution stays on the host fallback under isolated
        // scratch so the full suite creates zero containers.
        let base = try makeHermeticWorkspaceBase(label: "bash-smoke-touch")
        defer { removeHermeticWorkspaceBase(base) }
        let tool = makeHermeticBashTool(bashConfig: ToolsTestSupport.smokeBashConfig(), base: base)
        let sessionID = UUID()
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("runeweaver-smoke-touch-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: target) }
        let input = ToolInput(
            toolName: "bash.exec",
            argumentsJSON: #"{"command":"touch \#(target.path)"}"#
        )

        // Without approval the ask rule parks in the approvals inbox envelope.
        let parked = try await tool.execute(input: input, context: ToolContext(conversationID: sessionID))
        #expect(parked.isError)
        #expect(parked.content.contains("\"approvalRequired\":true"))
        #expect(parked.content.contains("Command requires approval"))
        #expect(!FileManager.default.fileExists(atPath: target.path))

        // An approved ask-rule command carries the gate authorization and runs.
        let approved = try await tool.execute(
            input: input,
            context: ToolContext(conversationID: sessionID, approved: true)
        )
        #expect(!approved.isError)
        #expect(!approved.content.contains("\"approvalRequired\":true"))
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    /// Denied rm refuses even when an approval flag is present.
    @Test
    func `rm denies even when approved`() async throws {
        // Hermetic stub keeps the suite container-free; the deny parks before any spawn.
        let (hermeticSeam, _) = ContainerSeam.hermetic()
        let tool = BashTool(bashConfig: ToolsTestSupport.smokeBashConfig(), allowUnsandboxedFallback: true, containers: hermeticSeam)
        let input = ToolInput(
            toolName: "bash.exec",
            argumentsJSON: #"{"command":"rm ~/helloWorld.txt"}"#
        )
        let output = try await tool.execute(
            input: input,
            context: ToolContext(conversationID: UUID(), approved: true)
        )

        #expect(output.isError)
        #expect(output.content.contains("\"denied\":true"))
        #expect(output.content.contains("Command denied by security policy"))
        #expect(!output.content.contains("\"approvalRequired\":true"))
    }
}

@Suite("Strict Container Memory")
struct StrictContainerMemoryTests {
    private func memoryValue(in args: [String]) -> String? {
        guard let flag = args.firstIndex(of: "--memory"), flag + 1 < args.count else { return nil }
        return args[flag + 1]
    }

    @Test
    func `Default creation carries the production cap`() {
        let args = StrictContainerRunner.containerCreateArguments(
            name: "n",
            hostPath: "/h",
            guestPath: "/g",
            workdir: "/g",
            networkDenied: true
        )
        #expect(memoryValue(in: args) == StrictContainerRunner.defaultMemory)
        #expect(memoryValue(in: args) == "512M")
    }

    @Test
    func `Machine creation carries the production cap`() {
        let root = URL(fileURLWithPath: "/tmp/rw-memory-probe")
        let capped = MachineScopedRunner.createArguments(workspaceRoot: root, networkDenied: true)
        #expect(memoryValue(in: capped) == StrictContainerRunner.defaultMemory)
        #expect(memoryValue(in: capped) == "512M")
        #expect(MachineScopedRunner.sharedMemoryCap == StrictContainerRunner.defaultMemory)
    }

    @Test
    func `Seams carry the production cap`() {
        #expect(ContainerSeam.live.memory == StrictContainerRunner.defaultMemory)
        #expect(ContainerSeam.live.memory == "512M")
        let (hermeticSeam, _) = ContainerSeam.hermetic()
        #expect(hermeticSeam.memory == StrictContainerRunner.defaultMemory)
        #expect(hermeticSeam.memory == "512M")
    }
}

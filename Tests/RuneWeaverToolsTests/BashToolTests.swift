// Rune Weaver Tools Tests — Sandboxed bash.exec tool, chaining detection, and fine-grained permissions.

import Foundation
@testable import RuneWeaverCore
@testable import RuneWeaverTools
import Testing

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
                BashRule(pattern: "echo", action: .allow),
                BashRule(pattern: "*", action: .ask)
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
                BashRule(pattern: "rm*", action: .deny),
                BashRule(pattern: "*", action: .ask)
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
                BashRule(pattern: "echo", action: .allow),
                BashRule(pattern: "*", action: .deny)
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
                BashRule(pattern: "echo", action: .allow),
                BashRule(pattern: "*", action: .deny)
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
                BashRule(pattern: "rm*", action: .deny),
                BashRule(pattern: "*", action: .ask)
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

@Suite("BashTool Execution")
struct BashToolExecutionTests {
    @Test
    func `Allowed command executes successfully and captures stdout`() async throws {
        let config = BashConfig(
            rules: [
                BashRule(pattern: "echo", action: .allow),
                BashRule(pattern: "*", action: .ask)
            ]
        )
        let tool = BashTool(bashConfig: config, allowUnsandboxedFallback: true)
        let input = ToolInput(
            toolName: "bash.exec",
            argumentsJSON: #"{"command":"echo Hello Rune Weaver"}"#
        )
        let context = ToolContext(conversationID: UUID())
        let output = try await tool.execute(input: input, context: context)

        #expect(!output.isError)
        #expect(output.content.contains("Hello Rune Weaver"))
        #expect(output.content.contains("\"exitCode\":0"))
    }

    @Test
    func `Denied command returns failure without executing`() async throws {
        let config = BashConfig(
            rules: [
                BashRule(pattern: "rm*", action: .deny),
                BashRule(pattern: "*", action: .ask)
            ]
        )
        let tool = BashTool(bashConfig: config, allowUnsandboxedFallback: true)
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
        let tool = BashTool(bashConfig: config, allowUnsandboxedFallback: true)
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
        let tool = BashTool(bashConfig: config, allowUnsandboxedFallback: true)
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
                BashRule(pattern: "echo", action: .allow),
                BashRule(pattern: "*", action: .ask)
            ]
        )
        let tool = BashTool(bashConfig: config, allowUnsandboxedFallback: true)
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
        let tool = BashTool(bashConfig: config, filesConfig: filesConfig, allowUnsandboxedFallback: true)
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
        let tool = BashTool(bashConfig: config, allowUnsandboxedFallback: true)
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

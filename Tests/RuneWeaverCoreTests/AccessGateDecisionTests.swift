// Rune Weaver Tests — PermissionGate decision order, deny-outranks, write posture, and ephemeral visibility.
//
// Pins the live half of the rule model, decided in `checkPermission`: the
// evaluation order where a durable deny outranks every allow decision, protected
// engine paths refuse before any trust is consulted, the shell policy decides
// before grants, the files write posture resolves, and grants only then release
// the call; the deny-outranks contract in every mint order and over every
// permission level; the files write posture matrix, where stage and live run
// with no approval request filed while ask and a missing or unreadable path
// park; and the ephemeral grants a session holds, surfaced by session with
// their task or session kind. Durable administration and persistence of the
// same rules live in `PermissionGatePersistenceTests`.

import Foundation
@testable import RuneWeaverCore
import Testing

/// Probe tool standing in for a gated tool on the decision path.
private struct GateProbeTool: Tool, Sendable {
    /// Tool name the gate branches and scopes on.
    let name: String
    /// Trust level the probe declares; approval-gated by default.
    var permissionLevel: PermissionLevel = .requiresApproval

    /// Summary shown in approval prompts.
    var description: String {
        "Probe for \(name)."
    }

    /// Accepts any object; the gate reads only the fields it names.
    var inputSchema: JSONSchema {
        .emptyObject
    }

    /// The probe never executes; the verdict is the assertion target.
    func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        .success("probe-ok", callID: input.callID)
    }
}

/// Isolated filesystem fixtures for the posture suites.
private enum GateFixtureSupport {
    /// Creates a fresh temporary base with symlinks resolved.
    static func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("runeweaver-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Removes a temporary base best-effort.
    static func cleanup(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
    }
}

/// Verdict readers shared by the decision assertions.
private enum GateVerdictSupport {
    /// Whether a verdict parks the call for approval.
    static func parks(_ verdict: PermissionDecision) -> Bool {
        if case .requiresApproval = verdict {
            return true
        }
        return false
    }

    /// The approval request a verdict parks, or nil when the call was not parked.
    static func parkedRequest(_ verdict: PermissionDecision) -> PermissionRequest? {
        guard case let .requiresApproval(request) = verdict else { return nil }
        return request
    }

    /// The refusal a verdict carries, or nil when the call was not denied.
    static func denialReason(_ verdict: PermissionDecision) -> String? {
        guard case let .denied(reason) = verdict else { return nil }
        return reason
    }
}

/// Verdict shape one posture matrix case must produce.
private enum ExpectedWriteVerdict: Equatable {
    /// The call runs with no approval request filed.
    case allowed
    /// The call is refused by policy.
    case denied
    /// The call parks an approval request.
    case parks
}

/// One row of the `files.write` posture matrix.
private struct WritePostureCase {
    /// Label naming the case in a failure message.
    let label: String
    /// Files policy the gate classifies under.
    let filesConfig: FilesConfig
    /// Raw `files.write` arguments under test.
    let argumentsJSON: String
    /// Verdict the gate must return.
    let expected: ExpectedWriteVerdict
}

@Suite("Access Gate Decisions")
struct AccessGateDecisionTests {
    // MARK: - Permission level and grant coverage

    @Test
    func `readOnly and trusted tools run with no rule installed`() async {
        let gate = PermissionGate()
        let read = ToolInput(toolName: "files.read", argumentsJSON: #"{"path":"/tmp/notes.md"}"#)
        #expect(await gate.checkPermission(toolCall: read, tool: GateProbeTool(name: "files.read", permissionLevel: .readOnly)) == .allowed)
        let trusted = ToolInput(toolName: "memories.store", argumentsJSON: #"{"key":"value"}"#)
        #expect(await gate.checkPermission(toolCall: trusted, tool: GateProbeTool(name: "memories.store", permissionLevel: .trusted)) == .allowed)
    }

    @Test
    func `an uncovered approval-level call parks carrying its session`() async throws {
        let gate = PermissionGate()
        let sessionID = UUID()
        let call = ToolInput(toolName: "email.send", argumentsJSON: #"{"to":"a@x.com"}"#)
        let verdict = await gate.checkPermission(toolCall: call, tool: GateProbeTool(name: "email.send"), sessionID: sessionID)
        let request = try #require(GateVerdictSupport.parkedRequest(verdict))
        #expect(request.toolName == "email.send")
        #expect(request.sessionID == sessionID)
        #expect(request.input == call)
        #expect(request.suggestedDurations == TrustDuration.allCases)
    }

    @Test
    func `a durable allow rule releases a call the level would park`() async {
        let gate = PermissionGate()
        #expect(await gate.grant(.exactTarget("a@x.com"), toolName: "email.send", duration: .forever))

        let covered = ToolInput(toolName: "email.send", argumentsJSON: #"{"to":"a@x.com"}"#)
        #expect(await gate.checkPermission(toolCall: covered, tool: GateProbeTool(name: "email.send")) == .allowed)

        // The narrow rule never reaches a different target.
        let outside = ToolInput(toolName: "email.send", argumentsJSON: #"{"to":"b@x.com"}"#)
        #expect(await GateVerdictSupport.parks(gate.checkPermission(toolCall: outside, tool: GateProbeTool(name: "email.send"))))

        // A tool-wide rule does, and also covers a call whose arguments never parse.
        #expect(await gate.grant(.toolWide, toolName: "email.send", duration: .forever))
        #expect(await gate.checkPermission(toolCall: outside, tool: GateProbeTool(name: "email.send")) == .allowed)
        let malformed = ToolInput(toolName: "email.send", argumentsJSON: "not json")
        #expect(await gate.checkPermission(toolCall: malformed, tool: GateProbeTool(name: "email.send")) == .allowed)
    }

    @Test
    func `a narrow rule never rides on a call whose arguments do not parse`() async {
        let gate = PermissionGate()
        #expect(await gate.grant(.exactTarget("a@x.com"), toolName: "email.send", duration: .forever))

        // Only a tool-wide scope matches without reading arguments, so a
        // malformed call stays on the ask path instead of riding a narrow rule.
        for argumentsJSON in ["not json", "[]", "", #"{"to":123}"#] {
            let malformed = ToolInput(toolName: "email.send", argumentsJSON: argumentsJSON)
            #expect(await GateVerdictSupport.parks(gate.checkPermission(toolCall: malformed, tool: GateProbeTool(name: "email.send"))))
        }
    }

    // MARK: - Deny outranks

    @Test
    func `a durable deny outranks a tool-wide allow in either mint order`() async throws {
        let gate = PermissionGate()
        let blocked = ToolInput(toolName: "email.send", argumentsJSON: #"{"to":"blocked@example.com"}"#)
        let allowed = ToolInput(toolName: "email.send", argumentsJSON: #"{"to":"friend@example.com"}"#)

        // Allow minted first, deny second: the refusal still wins and names the
        // scope it owns, while every other target stays trusted.
        #expect(await gate.grant(.toolWide, toolName: "email.send", duration: .forever))
        await gate.denyRule(.exactTarget("blocked@example.com"), toolName: "email.send", reason: "owner refused this recipient")

        let refusal = await gate.checkPermission(toolCall: blocked, tool: GateProbeTool(name: "email.send"))
        let reason = try #require(GateVerdictSupport.denialReason(refusal))
        #expect(reason.contains("Denied by rule"))
        #expect(reason.contains("blocked@example.com"))
        #expect(reason.contains("owner refused this recipient"))
        #expect(await gate.checkPermission(toolCall: allowed, tool: GateProbeTool(name: "email.send")) == .allowed)

        // Deny minted first, an allow second: the allow mint cannot evict it.
        #expect(await gate.grant(.exactTarget("blocked@example.com"), toolName: "email.send", duration: .oneHour))
        #expect(await gate.activeRules().count == 3)
        #expect(await gate.checkPermission(toolCall: blocked, tool: GateProbeTool(name: "email.send")) == .denied(reason))
    }

    @Test
    func `a deny rule refuses a read-only call too`() async throws {
        let gate = PermissionGate()
        await gate.denyRule(.domain(host: "example.com", subdomains: true), toolName: "web.fetch", reason: "owner refused this host")

        // The refusal is evaluated before the permission level, so no level
        // shortens it: a denied read never runs at all.
        let call = ToolInput(toolName: "web.fetch", argumentsJSON: #"{"url":"https://sub.example.com/notes"}"#)
        let verdict = await gate.checkPermission(
            toolCall: call,
            tool: GateProbeTool(name: "web.fetch", permissionLevel: .readOnly)
        )
        let reason = try #require(GateVerdictSupport.denialReason(verdict))
        #expect(reason.contains("Denied by rule"))
        #expect(reason.contains("domain example.com and its subdomains"))
    }

    @Test
    func `a deny rule outranks an ephemeral grant`() async {
        let gate = PermissionGate()
        let sessionID = UUID()
        #expect(await gate.grant(.toolWide, toolName: "stub.write", duration: .forTask, sessionID: sessionID))
        #expect(await gate.ephemeralGrants(sessionID: sessionID).count == 1)
        await gate.denyRule(.toolWide, toolName: "stub.write", reason: "owner refused writes")

        // The refusal is evaluated before any grant coverage, ephemeral
        // included, so a task-scoped approval cannot ride past it.
        let call = ToolInput(toolName: "stub.write", argumentsJSON: #"{"path":"/tmp/notes.md"}"#)
        let verdict = await gate.checkPermission(toolCall: call, tool: GateProbeTool(name: "stub.write"), sessionID: sessionID)
        #expect(GateVerdictSupport.denialReason(verdict) != nil)
    }

    // MARK: - Ordering around other policies

    @Test
    func `protected engine paths refuse before trust is consulted`() async throws {
        let gate = PermissionGate()
        #expect(await gate.grantTrust(for: ActionDescriptor(toolName: "files.write"), duration: .forever))
        #expect(await gate.isTrusted(ActionDescriptor(toolName: "files.write")))
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        // A tool-wide grant covers every target for its tool, but protected
        // engine state is refused before trust is consulted, so approved or
        // widened files.write still cannot replace the egress policy.
        let call = ToolInput(
            toolName: "files.write",
            argumentsJSON: #"{"path":"\#(home)/.runeweaver/policy.toml","content":"[network]"}"#
        )
        let reason = try #require(await GateVerdictSupport.denialReason(gate.checkPermission(toolCall: call, tool: GateProbeTool(name: "files.write"))))
        #expect(reason.contains("protected Rune Weaver engine files"))
    }

    // MARK: - Ephemeral grants

    @Test
    func `ephemeral grants surface by session with their task or session kind`() async {
        let gate = PermissionGate()
        let session = UUID()
        let other = UUID()
        #expect(await gate.grant(.recipientSet(["a@x.com", "b@x.com"]), toolName: "email.send", duration: .forTask, sessionID: session))
        #expect(await gate.grant(.toolWide, toolName: "bash.exec", duration: .forSession, sessionID: session))

        let grants = await gate.ephemeralGrants(sessionID: session)
        #expect(grants.count == 2)
        // Task grants read first so a caller can tell a turn-scoped approval
        // from a conversation-scoped one through the kind alone.
        #expect(grants[0].kind == .task)
        #expect(grants[0].toolName == "email.send")
        #expect(grants[0].scope == .recipientSet(["a@x.com", "b@x.com"]))
        #expect(grants[1].kind == .session)
        #expect(grants[1].toolName == "bash.exec")
        #expect(grants[1].scope == .toolWide)

        // Ephemeral trust belongs to one session; another reads none.
        #expect(await gate.ephemeralGrants(sessionID: other).isEmpty)
        #expect(await gate.ephemeralGrants(sessionID: UUID()).isEmpty)
    }

    @Test
    func `an ephemeral grant covers only its own session and scope`() async {
        let gate = PermissionGate()
        let session = UUID()
        let other = UUID()
        #expect(await gate.grant(.recipientSet(["a@x.com", "b@x.com"]), toolName: "email.send", duration: .forSession, sessionID: session))

        // The single scope matcher judges the call, so casing and the array
        // spelling agree with the stored member set.
        let covered = ToolInput(toolName: "email.send", argumentsJSON: #"{"to":["B@X.com"]}"#)
        #expect(await gate.checkPermission(toolCall: covered, tool: GateProbeTool(name: "email.send"), sessionID: session) == .allowed)
        #expect(await GateVerdictSupport.parks(gate.checkPermission(toolCall: covered, tool: GateProbeTool(name: "email.send"), sessionID: other)))

        // A recipient outside the set never rides the grant, even in session.
        let outside = ToolInput(toolName: "email.send", argumentsJSON: #"{"to":"z@x.com"}"#)
        #expect(await GateVerdictSupport.parks(gate.checkPermission(toolCall: outside, tool: GateProbeTool(name: "email.send"), sessionID: session)))
    }

    // MARK: - Files write posture

    @Test
    func `files write posture matrix decides deny, ask, stage, and live`() async throws {
        let root = try GateFixtureSupport.makeRoot()
        defer { GateFixtureSupport.cleanup(root) }
        let notes = root.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let cases: [WritePostureCase] = [
            WritePostureCase(
                label: "a deny pattern refuses before any posture is resolved",
                filesConfig: FilesConfig(denyPatterns: ["*.secret"], allowRoots: [root.path], writeMode: .live, writePathRules: []),
                argumentsJSON: #"{"path":"\#(notes.path)/token.secret","content":"notes"}"#,
                expected: .denied
            ),
            WritePostureCase(
                label: "the longest write-path rule outranks the global mode",
                filesConfig: FilesConfig(
                    allowRoots: [root.path],
                    writeMode: .live,
                    writePathRules: [FilesWritePathRule(path: notes.path, posture: .ask)]
                ),
                argumentsJSON: #"{"path":"\#(notes.path)/private.md","content":"notes"}"#,
                expected: .parks
            ),
            WritePostureCase(
                label: "the staged mode hands the write to the tool's review flow",
                filesConfig: FilesConfig(allowRoots: [root.path], writeMode: .staged, writePathRules: []),
                argumentsJSON: #"{"path":"\#(root.path)/report.md","content":"notes"}"#,
                expected: .allowed
            ),
            WritePostureCase(
                label: "the live mode hands the write to the tool's review flow",
                filesConfig: FilesConfig(allowRoots: [root.path], writeMode: .live, writePathRules: []),
                argumentsJSON: #"{"path":"\#(root.path)/report.md","content":"notes"}"#,
                expected: .allowed
            ),
            WritePostureCase(
                label: "a path outside every allow root asks even under a forced live mode",
                filesConfig: FilesConfig(allowRoots: [notes.path], writeMode: .live, writePathRules: []),
                argumentsJSON: #"{"path":"\#(root.path)/outside.md","content":"notes"}"#,
                expected: .parks
            )
        ]

        for testCase in cases {
            let gate = PermissionGate()
            await gate.updateFilesConfig(testCase.filesConfig)
            let verdict = await gate.checkPermission(
                toolCall: ToolInput(toolName: "files.write", argumentsJSON: testCase.argumentsJSON),
                tool: GateProbeTool(name: "files.write")
            )
            let matches: Bool = switch testCase.expected {
            case .allowed:
                verdict == .allowed
            case .denied:
                GateVerdictSupport.denialReason(verdict) != nil
            case .parks:
                GateVerdictSupport.parks(verdict)
            }
            #expect(matches, "\(testCase.label): expected \(testCase.expected), got \(verdict)")
        }
    }

    @Test
    func `model write mode stages by default and goes live on an explicit live mode`() async throws {
        let root = try GateFixtureSupport.makeRoot()
        defer { GateFixtureSupport.cleanup(root) }
        let filesConfig = FilesConfig(allowRoots: [root.path], writeMode: .model, writePathRules: [])
        let path = root.appendingPathComponent("report.md").path

        for argumentsJSON in [
            #"{"path":"\#(path)"}"#,
            #"{"path":"\#(path)","mode":"live"}"#,
            #"{"path":"\#(path)","mode":"staged"}"#
        ] {
            // Stage and live both hand the call to the tool with no approval
            // request filed, so the gate verdict is identical for every mode.
            let gate = PermissionGate()
            await gate.updateFilesConfig(filesConfig)
            #expect(await gate.checkPermission(
                toolCall: ToolInput(toolName: "files.write", argumentsJSON: argumentsJSON),
                tool: GateProbeTool(name: "files.write")
            ) == .allowed)
        }

        // The posture the tool applies differs per call: only an explicit live
        // request leaves the staged default, and the tool owns that difference.
        #expect(WritePathPolicy.classify(path: path, filesConfig: filesConfig).posture == .stage)
        #expect(WritePathPolicy.classify(path: path, filesConfig: filesConfig, requestedMode: "staged").posture == .stage)
        #expect(WritePathPolicy.classify(path: path, filesConfig: filesConfig, requestedMode: "live").posture == .live)
    }

    @Test
    func `a files write with no usable path parks`() async throws {
        let root = try GateFixtureSupport.makeRoot()
        defer { GateFixtureSupport.cleanup(root) }
        let gate = PermissionGate()
        await gate.updateFilesConfig(FilesConfig(allowRoots: [root.path], writeMode: .live, writePathRules: []))

        // A policy that never saw a target cannot trust the write, so a blank,
        // missing, or unreadable path parks instead of executing under a posture
        // nobody resolved.
        for argumentsJSON in [
            #"{"content":"notes"}"#,
            #"{"path":"   ","content":"notes"}"#,
            #"{"path":123,"content":"notes"}"#,
            #"{"path":null,"content":"notes"}"#,
            "not json",
            "[]",
            "{}"
        ] {
            let call = ToolInput(toolName: "files.write", argumentsJSON: argumentsJSON)
            #expect(await GateVerdictSupport.parks(gate.checkPermission(toolCall: call, tool: GateProbeTool(name: "files.write"))))
        }
    }

    // MARK: - Per-recipient send trust

    @Test
    func `messages.send trust stays on the approved handle and widening refuses`() async throws {
        let gate = PermissionGate()
        let canonical = ActionDescriptor(toolName: "messages.send", target: "+15551234567")
        #expect(await gate.grantTrust(for: canonical, duration: .forever))

        // The canonical handle covers the respelled recipient and nothing else.
        let approved = ToolInput(toolName: "messages.send", argumentsJSON: #"{"recipient":"+1 (555) 123-4567","text":"hi"}"#)
        #expect(await gate.checkPermission(toolCall: approved, tool: GateProbeTool(name: "messages.send")) == .allowed)
        let otherHandle = ToolInput(toolName: "messages.send", argumentsJSON: #"{"recipient":"+15559999999","text":"hi"}"#)
        #expect(await GateVerdictSupport.parks(gate.checkPermission(toolCall: otherHandle, tool: GateProbeTool(name: "messages.send"))))

        // A name-shaped send mints no durable rule at all.
        #expect(await gate.grantTrust(for: ActionDescriptor(toolName: "messages.send", target: "Rebecca Mackin"), duration: .forever) == false)
        #expect(await gate.activeRules().count == 1)

        // There is no tool-wide send scope, so widening keeps the approved
        // handle and reports the honest refusal.
        let rule = try #require(await gate.activeRules().first)
        #expect(
            await gate.widenGrant(id: rule.id)
                == .notWidenable(reason: GrantWidenOutcome.messagesSendRefusal)
        )
        #expect(await gate.activeRules().first?.scope == .exactTarget("+15551234567"))
    }

    @Test
    func `display-name send scopes mint nothing through grant or denyRule`() async {
        let gate = PermissionGate()

        // A display-name exact target can never match an honest send, so both
        // mint paths refuse it and store nothing.
        #expect(await gate.grant(.exactTarget("Display Name"), toolName: "messages.send", duration: .forever) == false)
        #expect(await gate.grant(.exactTarget("Display Name"), toolName: "messages.send", duration: .forTask, sessionID: UUID()) == false)
        await gate.denyRule(.exactTarget("Display Name"), toolName: "messages.send", reason: "owner refused")
        #expect(await gate.activeRules().isEmpty)

        // A canonical-handle exact target and a recipient set still mint.
        #expect(await gate.grant(.exactTarget("+15551234567"), toolName: "messages.send", duration: .forever) == true)
        #expect(await gate.grant(.recipientSet(["a@x.com"]), toolName: "messages.send", duration: .forever) == true)
        #expect(await gate.activeRules().count == 2)
    }
}

/// Smoke-test contract for the permission gate consulting shell rules before parking.
@Suite("Bash Smoke Gate Contract")
struct BashSmokeGateContractTests {
    /// Allowed echo runs with no prompt.
    @Test
    func `echo Hello World is allowed without prompting`() async {
        let gate = await makeSmokeGate()
        let call = ToolInput(toolName: "bash.exec", argumentsJSON: #"{"command":"echo Hello World"}"#)
        let verdict = await gate.checkPermission(toolCall: call, tool: GateProbeTool(name: "bash.exec"))
        guard case .allowed = verdict else {
            Issue.record("Expected echo Hello World to be allowed, got \(verdict)")
            return
        }
    }

    /// Unlisted touch parks for approval.
    @Test
    func `touch parks for approval`() async {
        let gate = await makeSmokeGate()
        let call = ToolInput(toolName: "bash.exec", argumentsJSON: #"{"command":"touch ~/helloWorld.txt"}"#)
        let verdict = await gate.checkPermission(toolCall: call, tool: GateProbeTool(name: "bash.exec"))
        guard case .requiresApproval = verdict else {
            Issue.record("Expected touch ~/helloWorld.txt to require approval, got \(verdict)")
            return
        }
    }

    /// Denied rm refuses without prompting.
    @Test
    func `rm is denied without prompting`() async {
        let gate = await makeSmokeGate()
        let call = ToolInput(toolName: "bash.exec", argumentsJSON: #"{"command":"rm ~/helloWorld.txt"}"#)
        let verdict = await gate.checkPermission(toolCall: call, tool: GateProbeTool(name: "bash.exec"))
        guard case let .denied(reason) = verdict else {
            Issue.record("Expected rm ~/helloWorld.txt to be denied, got \(verdict)")
            return
        }
        #expect(!reason.isEmpty)
    }

    /// A durable allow rule cannot override the shell policy's refusal.
    @Test
    func `a durable allow rule cannot ride past the shell policy`() async {
        let gate = await makeSmokeGate()
        #expect(await gate.grant(.toolWide, toolName: "bash.exec", duration: .forever))

        // The shell policy is evaluated before grant coverage, so a rule that
        // trusts every bash.exec call cannot execute the command it refuses.
        let call = ToolInput(toolName: "bash.exec", argumentsJSON: #"{"command":"rm ~/helloWorld.txt"}"#)
        #expect(await GateVerdictSupport.denialReason(gate.checkPermission(toolCall: call, tool: GateProbeTool(name: "bash.exec"))) != nil)
        let allowedCall = ToolInput(toolName: "bash.exec", argumentsJSON: #"{"command":"echo Hello World"}"#)
        #expect(await gate.checkPermission(toolCall: allowedCall, tool: GateProbeTool(name: "bash.exec")) == .allowed)
    }

    /// Gate wired to the smoke-test shell policy.
    private func makeSmokeGate() async -> PermissionGate {
        let gate = PermissionGate()
        await gate.updateBashConfig(BashGateTestSupport.smokeBashConfig())
        return gate
    }
}
